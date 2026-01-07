#ifndef ZEPH_OPTIMIZED_SURFACE_HLSL
#define ZEPH_OPTIMIZED_SURFACE_HLSL

#include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/Core.hlsl"
#include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/SurfaceData.hlsl"
#include "Packages/com.unity.render-pipelines.core/ShaderLibrary/CommonMaterial.hlsl"

// ---------------------------------------------------------------------------
// CBUFFER: 材质属性定义
// 必须与 Shader 中的 Properties 顺序和名称保持一致以支持 SRP Batcher
// ---------------------------------------------------------------------------
CBUFFER_START(UnityPerMaterial)
    float4 _BaseMap_ST;
    half4 _BaseColor;
    half _BaseColorBrightness;
    half _BaseColorSaturation;
    
    half _Metallic;
    half _SmoothnessMin;
    half _SmoothnessMax;
    half _OcclusionStrength;
    
    half _UseNormalMap;
    half _BumpScale;
    
    half _UseParallaxMap;
    half _ParallaxScale;
    half _ParallaxSteps;
    float4 _NoiseMap_ST;
    half4 _InternalCrackColor;
    half _InternalCrackScale;
    half _InternalCrackDistortion;

    half4 _FresnelColor;
    half _FresnelPower;
    half4 _SSSColor;
    half _SSSIntensity;
    half _SSSPower;

    half _Cull;
    half _SpecularHighlights;
    half _EnvironmentReflections;
    half _ZWrite;
CBUFFER_END

// ---------------------------------------------------------------------------
// 纹理采样器定义
// ---------------------------------------------------------------------------
TEXTURE2D(_BaseMap);            SAMPLER(sampler_BaseMap);
TEXTURE2D(_BumpMap);            SAMPLER(sampler_BumpMap);
TEXTURE2D(_ORMAMap);             SAMPLER(sampler_ORMAMap);
TEXTURE2D(_ParallaxMap);        SAMPLER(sampler_ParallaxMap);
TEXTURE2D(_NoiseMap);           SAMPLER(sampler_NoiseMap);

// ---------------------------------------------------------------------------
// 辅助函数：视差映射 (Volumetric Internal Cracks)
// ---------------------------------------------------------------------------
float2 GetParallaxUV(float2 uv, half3 viewDirTS, out half crackIntensity)
{
    crackIntensity = 0;
// #if defined(_PARALLAXMAP)
    half numSteps = _ParallaxSteps;
    float layerDepth = 1.0 / numSteps;
    
    // 视差偏移向量 (应用 Offset Limiting)
    float2 p = viewDirTS.xy * _ParallaxScale / (viewDirTS.z + 0.42);
    float2 deltaUV = p / numSteps;

    float2 currentUV = uv;
    float currentLayerDepth = 0;
    
    float2 surfaceUV = uv;
    bool surfaceFound = false;
    float accumulatedCracks = 0;

    // 采样噪声图来决定该位置裂隙的最大深度
    // 使用 _NoiseMap_ST 来控制噪声的缩放
    float2 noiseUV = uv * _NoiseMap_ST.xy + _NoiseMap_ST.zw;
    half crackNoise = SAMPLE_TEXTURE2D(_NoiseMap, sampler_NoiseMap, noiseUV).r;

    [loop]
    for (int i = 0; i < numSteps; i++)
    {
        // 采样当前层的深度(R)和裂隙(G)
        half4 parallaxSample = SAMPLE_TEXTURE2D(_ParallaxMap, sampler_ParallaxMap, currentUV);
        
        // 1. 寻找主表面深度 (用于基础贴图采样)
        if (!surfaceFound && currentLayerDepth >= parallaxSample.r)
        {
            // 线性插值优化主表面 UV
            float2 prevUV = currentUV + deltaUV;
            float nextH = parallaxSample.r - currentLayerDepth;
            float prevH = SAMPLE_TEXTURE2D(_ParallaxMap, sampler_ParallaxMap, prevUV).r - (currentLayerDepth - layerDepth);
            float weight = nextH / (nextH - prevH + 0.0001);
            surfaceUV = prevUV * weight + currentUV * (1.0 - weight);
            surfaceFound = true;
        }

        // 2. 累加内部裂隙体积感
        // 使用 uv 作为基准，_InternalCrackDistortion 控制裂隙随深度的位移量
        float2 internalUV = uv - (viewDirTS.xy / (viewDirTS.z + 0.42)) * _InternalCrackDistortion * currentLayerDepth;
        half crackSample = SAMPLE_TEXTURE2D(_ParallaxMap, sampler_ParallaxMap, internalUV).g;
        
        // 优化：引入噪声控制的深度感，让裂隙有深有浅
        // depthLimit 决定了该位置裂隙能达到的最大深度 (0.2 ~ 1.0)
        float depthLimit = 0.2 + crackNoise * 0.8; 
        float depthFade = saturate(1.0 - currentLayerDepth / depthLimit);
        
        // 模拟光线在冰内部的吸收，深处衰减
        depthFade *= saturate(1.0 - currentLayerDepth);
        
        accumulatedCracks += crackSample * depthFade;

        currentUV -= deltaUV;
        currentLayerDepth += layerDepth;
    }

    // 最终裂隙强度
    crackIntensity = saturate(accumulatedCracks * _InternalCrackScale / numSteps);
    
    // 返回主表面 UV
    return surfaceFound ? surfaceUV : currentUV;
// Parallax mapping disabled
// #else
//     return uv;
// #endif
}

// ---------------------------------------------------------------------------
// 核心函数：初始化 SurfaceData
// ---------------------------------------------------------------------------
void InitializeSurfaceData(float2 uv, half3 viewDirTS, half3 viewDirWS, out SurfaceData outSurfaceData)
{
    outSurfaceData = (SurfaceData)0;

    // 0. 视差映射处理
    half crackIntensity = 0;
    float2 parallaxUV = GetParallaxUV(uv, viewDirTS, crackIntensity);
    float2 finalUV = parallaxUV;
    
    // 1. 基础色 (Albedo)
    half4 albedoSample = SAMPLE_TEXTURE2D(_BaseMap, sampler_BaseMap, finalUV);
    half3 albedo = albedoSample.rgb * _BaseColor.rgb * _BaseColorBrightness;
    
    // 混合内部裂隙颜色
    albedo += crackIntensity * _InternalCrackColor.rgb * _InternalCrackColor.a;

    // 菲涅尔效应 (Fresnel) - 让边缘更亮
    half fresnel = pow(1.0 - saturate(dot(half3(0,0,1), viewDirTS)), _FresnelPower); // 在切线空间计算简单的边缘效果
    // 或者使用世界空间法线，但这里我们还没计算最终 normalWS。
    // 我们可以先用切线空间的 Z (0,0,1) 作为近似，或者在后面应用。
    // 更好的做法是在 CalculateLitColor 中应用，或者在这里使用 viewDirWS 和默认法线。
    
    // 饱和度处理
    half luminance = dot(albedo, half3(0.2126h, 0.7152h, 0.0722h));
    outSurfaceData.albedo = lerp(luminance.xxx, albedo, _BaseColorSaturation);

    // 2. ORM 采样 (R=Occlusion, G=Smoothness, B=Metallic/Alpha)
    half4 ormSample = SAMPLE_TEXTURE2D(_ORMAMap, sampler_BaseMap, finalUV);

    // 3. Alpha 计算
    outSurfaceData.alpha = _BaseColor.a;
    
    // 菲涅尔增加不透明度
    half fresnelAlpha = pow(1.0 - saturate(dot(half3(0,0,1), viewDirTS)), _FresnelPower);
    outSurfaceData.alpha = saturate(outSurfaceData.alpha + fresnelAlpha * _FresnelColor.a);

    // 强制将 Alpha 设为 1 (对于不透明物体)
    outSurfaceData.alpha = 1.0h;

    // 4. 物理属性
    outSurfaceData.metallic = ormSample.b * _Metallic;
    outSurfaceData.specular = 0.0h; // 绝缘体 specular 默认为 0，金属由 metallic 控制
    
    // 光滑度重映射
    outSurfaceData.smoothness = lerp(_SmoothnessMin, _SmoothnessMax, ormSample.g);
    
    // 环境光遮蔽
    outSurfaceData.occlusion = lerp(1.0h, ormSample.r, _OcclusionStrength);

    // 5. 法线
#if defined(_NORMALMAP)
    half4 normalSample = SAMPLE_TEXTURE2D(_BumpMap, sampler_BumpMap, finalUV);
    outSurfaceData.normalTS = UnpackNormalScale(normalSample, _BumpScale);
#else
    outSurfaceData.normalTS = half3(0.0h, 0.0h, 1.0h);
#endif

    // 应用菲涅尔颜色到自发光，模拟边缘发光
    // 结合裂隙强度，让内部裂隙也有边缘亮光感
    half fresnelRim = pow(1.0 - saturate(dot(outSurfaceData.normalTS, viewDirTS)), _FresnelPower);
    half3 rimColor = fresnelRim * _FresnelColor.rgb + (crackIntensity * _FresnelColor.rgb * 0.5);

    // 6. 自发光 (仅保留边缘发光效果)
    outSurfaceData.emission = rimColor;
}

// ---------------------------------------------------------------------------
// 兼容性函数：供 DepthNormalsPass 使用
// ---------------------------------------------------------------------------
half4 SampleAlbedoAlpha(float2 uv, TEXTURE2D_PARAM(albedoAlphaMap, sampler_albedoAlphaMap))
{
    half4 result = SAMPLE_TEXTURE2D(albedoAlphaMap, sampler_albedoAlphaMap, uv);
    result.a = 1.0h;
    return result;
}

half3 SampleNormal(float2 uv, TEXTURE2D_PARAM(bumpMap, sampler_bumpMap), half scale = 1.0h)
{
#ifdef _NORMALMAP
    half4 n = SAMPLE_TEXTURE2D(bumpMap, sampler_bumpMap, uv);
    return UnpackNormalScale(n, scale);
#else
    return half3(0.0h, 0.0h, 1.0h);
#endif
}

half Alpha(half albedoAlpha, half4 color, half cutoff)
{
    return 1.0h;
}

#endif
