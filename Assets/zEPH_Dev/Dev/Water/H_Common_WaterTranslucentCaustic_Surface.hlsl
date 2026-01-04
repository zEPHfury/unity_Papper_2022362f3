#ifndef ZEPH_OPTIMIZED_SURFACE_HLSL
#define ZEPH_OPTIMIZED_SURFACE_HLSL

#include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/Core.hlsl"
#include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/SurfaceData.hlsl"
#include "Packages/com.unity.render-pipelines.core/ShaderLibrary/CommonMaterial.hlsl"
#include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/DeclareDepthTexture.hlsl"

// ---------------------------------------------------------------------------
// CBUFFER: 材质属性定义
// 必须与 Shader 中的 Properties 顺序 and 名称保持一致以支持 SRP Batcher
// ---------------------------------------------------------------------------
CBUFFER_START(UnityPerMaterial)
    half4 _ShallowColor;
    half4 _DeepColor;
    half _ShallowOpacity;
    half _DeepOpacity;
    float _DepthMaxDistance;
    float _DepthExp;
    float _OpacityDepthDistance;
    float _OpacityExp;
    float _ViewCorrection;

    float4 _BumpMap_ST;
    half _BumpScale;
    float _DistortionStrength;
    float4 _Speed;

    half _ReflectionStrength;
    half _FresnelPower;
    half _Smoothness;

    half _UseRefraction;
    half _RefractionStrength;

    half _UseCaustics;
    float4 _CausticTex_ST;
    float _CausticScale;
    float _CausticSpeed;
    float _CausticIntensity;
    float _CausticRGBSplit;
    
    // half _UseEmission;
    // float4 _EmissionMap_ST;
    // half4 _EmissionColor;
    // half _EmissionScale;
CBUFFER_END

// ---------------------------------------------------------------------------
// 纹理采样器定义
// ---------------------------------------------------------------------------
TEXTURE2D(_BumpMap);            SAMPLER(sampler_BumpMap);
TEXTURE2D(_CausticTex);         SAMPLER(sampler_CausticTex);
// TEXTURE2D(_EmissionMap);        SAMPLER(sampler_EmissionMap);

// ---------------------------------------------------------------------------
// 辅助函数：统一获取 Alpha 值
// ---------------------------------------------------------------------------
half GetAlpha(float2 uv)
{
    return 1.0;
}

// ---------------------------------------------------------------------------
// 辅助函数：执行 Alpha 裁剪
// ---------------------------------------------------------------------------
void DoAlphaClip(half alpha)
{
}

// ---------------------------------------------------------------------------
// 核心函数：初始化 SurfaceData
// ---------------------------------------------------------------------------
void InitializeSurfaceData(float2 uv, float4 screenPos, float3 positionWS, float2 emissionUV, out SurfaceData outSurfaceData)
{
    outSurfaceData = (SurfaceData)0;

    // 1. 法线采样 (用于扰动深度采样)
    // 第一层波纹
    float2 uvOffset1 = _Time.y * _Speed.xy;
    float2 uv1 = uv + uvOffset1;
    half4 bump1 = SAMPLE_TEXTURE2D(_BumpMap, sampler_BumpMap, uv1);
    float3 normalTS1 = UnpackNormalScale(bump1, _BumpScale);

    // 第二层波纹
    float2 uvOffset2 = _Time.y * _Speed.zw;
    float2 uv2 = uv * 0.82 + uvOffset2;
    half4 bump2 = SAMPLE_TEXTURE2D(_BumpMap, sampler_BumpMap, uv2);
    float3 normalTS2 = UnpackNormalScale(bump2, _BumpScale);

    // 混合两层法线
    float3 normalTS = normalize(float3(normalTS1.xy + normalTS2.xy, normalTS1.z + normalTS2.z));
    outSurfaceData.normalTS = normalTS;

    // 2. 深度计算
    float waterDepth = 0;       // 用于颜色的深度（带扰动）
    float shoreDepth = 0;       // 用于岸边淡出的深度（不带扰动，消除硬边）
    float realWaterDepth = 0;
    float2 screenUV = 0;
    
    if (screenPos.w > 0)
    {
        screenUV = screenPos.xy / screenPos.w;
        float surfaceDepth = screenPos.w;

        // --- A. 计算稳定的岸边深度 (不带扰动) ---
        float rawShoreDepth = SampleSceneDepth(screenUV);
        float sceneShoreDepth = LinearEyeDepth(rawShoreDepth, _ZBufferParams);
        shoreDepth = max(0.0, sceneShoreDepth - surfaceDepth);

        // --- B. 计算带扰动的水深 (用于颜色和折射) ---
        float2 distortedScreenUV = screenUV + normalTS.xy * _DistortionStrength * _RefractionStrength;
        float rawDepth = SampleSceneDepth(distortedScreenUV);
        float sceneDepth = LinearEyeDepth(rawDepth, _ZBufferParams);
        
        // 伪影修复：如果采样到的深度比水面还近，说明采样到了水面上的物体，取消扰动
        if (sceneDepth < surfaceDepth)
        {
            distortedScreenUV = screenUV;
            rawDepth = SampleSceneDepth(distortedScreenUV);
            sceneDepth = LinearEyeDepth(rawDepth, _ZBufferParams);
        }
        
        waterDepth = max(0.0, sceneDepth - surfaceDepth);
        
        // 视线角度修正 (基于水面法线)
        float3 viewDirWS = normalize(_WorldSpaceCameraPos - positionWS);
        float NdotV = saturate(abs(viewDirWS.y)); // 确保在 0-1 范围
        float depthCorrection = lerp(1.0, NdotV, _ViewCorrection);
        
        realWaterDepth = waterDepth * depthCorrection;
        // 岸边深度也应用同样的修正
        shoreDepth *= depthCorrection;
    }

    // 3. 基础色 (Albedo) - 基于带扰动的深度
    float colorDepthT = saturate(realWaterDepth / max(_DepthMaxDistance, 0.01));
    float colorGradient = pow(colorDepthT, _DepthExp);
    
    // RGB 颜色插值
    half3 waterBaseColor = lerp(_ShallowColor.rgb, _DeepColor.rgb, colorGradient);
    outSurfaceData.albedo = waterBaseColor;

    // 4. Alpha 计算 - 基于稳定的岸边深度 (shoreDepth)
    // 这样即使水面有巨大波动，岸边的接触线也是平滑且固定的
    float opacityDepthT = saturate(shoreDepth / max(_OpacityDepthDistance, 0.01));
    float opacityGradient = pow(opacityDepthT, _OpacityExp);
    
    // 使用独立的 float 属性控制不透明度
    outSurfaceData.alpha = lerp(_ShallowOpacity, _DeepOpacity, opacityGradient);

    // 5. 物理属性
    outSurfaceData.metallic = 0.0h;
    outSurfaceData.specular = half3(0.0h, 0.0h, 0.0h); 
    outSurfaceData.smoothness = _Smoothness;
    outSurfaceData.occlusion = 1.0h;
    outSurfaceData.emission = 0.0h;

    // 6. 焦散计算 (Caustics)
    #if defined(_CAUSTICS)
    if (screenPos.w > 0)
    {
        // 使用带扰动的深度采样点来重建世界坐标，使焦散随波纹扭曲
        float2 causticScreenUV = screenUV + normalTS.xy * _DistortionStrength * _RefractionStrength;
        float deviceDepth = SampleSceneDepth(causticScreenUV);
        
        // 重建水底物体的世界空间坐标
        float3 floorWS = ComputeWorldSpacePosition(causticScreenUV, deviceDepth, UNITY_MATRIX_I_VP);
        
        // 计算焦散 UV：使用世界坐标的 XZ 平面，并随时间滚动
        float2 uvCaustic = floorWS.xz * _CausticScale;
        float time = _Time.y * _CausticSpeed;
        
        // 采样两层焦散并进行偏移，模拟光线交织效果
        float2 uv1 = uvCaustic + float2(time, time * 0.5);
        float2 uv2 = uvCaustic * 0.9 - float2(time * 0.8, time);
        
        // RGB 分离效果 (色散)
        half3 caustic;
        caustic.r = SAMPLE_TEXTURE2D(_CausticTex, sampler_CausticTex, uv1 + _CausticRGBSplit).r;
        caustic.g = SAMPLE_TEXTURE2D(_CausticTex, sampler_CausticTex, uv1).g;
        caustic.b = SAMPLE_TEXTURE2D(_CausticTex, sampler_CausticTex, uv1 - _CausticRGBSplit).b;
        
        half3 caustic2;
        caustic2.r = SAMPLE_TEXTURE2D(_CausticTex, sampler_CausticTex, uv2 + _CausticRGBSplit).r;
        caustic2.g = SAMPLE_TEXTURE2D(_CausticTex, sampler_CausticTex, uv2).g;
        caustic2.b = SAMPLE_TEXTURE2D(_CausticTex, sampler_CausticTex, uv2 - _CausticRGBSplit).b;
        
        // 混合两层焦散，取最小值或相乘可以得到更锐利的线条
        caustic = min(caustic, caustic2);
        
        // 焦散强度衰减：随深度增加而变暗，且在接近水面时淡出以减少伪影
        float causticFade = saturate(realWaterDepth * 10.0) * saturate(1.0 - realWaterDepth / _DepthMaxDistance);
        
        // 将焦散结果存入 emission，稍后在 Lighting 阶段应用
        outSurfaceData.emission = caustic * _CausticIntensity * causticFade;
    }
    #endif
}

// ---------------------------------------------------------------------------
// 兼容性函数：供 DepthNormalsPass 使用
// ---------------------------------------------------------------------------
half4 SampleAlbedoAlpha(float2 uv, TEXTURE2D_PARAM(albedoAlphaMap, sampler_albedoAlphaMap))
{
    half4 result = SAMPLE_TEXTURE2D(albedoAlphaMap, sampler_albedoAlphaMap, uv);
    // 强制替换 Alpha 以匹配我们的逻辑
#if defined(_ALPHATEST_ON)
    result.a = GetAlpha(uv); 
#else
    result.a = 1.0h;
#endif
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
    // 注意：这里的 albedoAlpha 已经是通过 SampleAlbedoAlpha 修改过的
    half alpha = albedoAlpha; // * color.a; // color.a 已经在 GetAlpha 中乘过了
    return alpha;
}

#endif
