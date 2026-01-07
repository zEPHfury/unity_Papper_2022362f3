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
    float _FixedDepth;

    half _UseFoam;
    half4 _FoamColor;
    float _FoamDistance;
    float4 _FoamNoise_ST;
    float _FoamNoiseScale;
    float4 _FoamNoiseSpeed;
    float _FoamNoiseMul;
    float _FoamNoisePow;
    float _FoamNoiseCutoff;
    float _FoamSmoothness;
    float _FoamShoreSmoothness;

    float4 _BumpMap_ST;
    half _BumpScale;
    float _DistortionStrength;
    float4 _Speed;

    half _ReflectionStrength;
    half _FresnelPower;
    half _Smoothness;

    half _UseRefraction;
    half _RefractionStrength;
    
    // half _UseEmission;
    // float4 _EmissionMap_ST;
    // half4 _EmissionColor;
    // half _EmissionScale;
CBUFFER_END

// ---------------------------------------------------------------------------
// 纹理采样器定义
// ---------------------------------------------------------------------------
TEXTURE2D(_BumpMap);            SAMPLER(sampler_BumpMap);
TEXTURE2D(_FoamNoise);          SAMPLER(sampler_FoamNoise);
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
    float shoreDepth = 0;       // 用于岸边淡出的深度（不带扰动，消除硬边）
    float realWaterDepth = 0;
    float fixedVerticalDepth = 0; // 新增：垂直深度，用于固定泡沫范围
    float floorFlatness = 1.0;  // 默认为平地
    float2 screenUV = 0;
    
    if (screenPos.w > 0)
    {
        screenUV = screenPos.xy / screenPos.w;
        float surfaceDepth = screenPos.w;

        // --- A. 计算稳定的岸边深度 (不带扰动) ---
        float rawShoreDepth = SampleSceneDepth(screenUV);
        float sceneShoreDepth = LinearEyeDepth(rawShoreDepth, _ZBufferParams);
        // 增加微小的 Depth Bias 消除深度缓冲区精度导致的边缘锯齿/闪烁 (Z-Fighting)
        float eyeShoreDepthDiff = max(0.0, sceneShoreDepth - surfaceDepth - 0.0005);

        // --- B. 计算带扰动的水深 (用于颜色和折射) ---
        // 为了消除岸边交接处的硬边，扰动强度也需要根据深度进行衰减
        float distortionShoreFade = saturate(eyeShoreDepthDiff * 10.0);
        float2 distortionOffset = normalTS.xy * _DistortionStrength * _RefractionStrength * distortionShoreFade;
        float2 distortedScreenUV = screenUV + distortionOffset;
        
        float rawDepth = SampleSceneDepth(distortedScreenUV);
        float sceneDepth = LinearEyeDepth(rawDepth, _ZBufferParams);
        
        // 【平滑修复】：不再使用硬切，而是为了防止采样到水面以上物体，在 Color 阶段也参考深度
        // 这里先保留原始计算，后续在颜色混合时处理
        float eyeWaterDepthDiff = max(0.0, sceneDepth - surfaceDepth - 0.0005);
        
        // --- C. 固定深度计算 (视角无关稳定性优化) ---
        // 采用相似三角形投影法：垂直深度 = 视线深度差 * (相机到水面垂直距离 / 视线深度)
        // 这种方法不依赖逆矩阵重建，能完美解决视角旋转、拉近拉远导致的水深抖动
        float3 wsAbs = GetAbsolutePositionWS(positionWS);
        float camHeightDiff = abs(_WorldSpaceCameraPos.y - wsAbs.y);
        float perspectiveCorrection = camHeightDiff / max(surfaceDepth, 0.0001);
        
        fixedVerticalDepth = eyeShoreDepthDiff * perspectiveCorrection;
        float fixedDistortedDepth = eyeWaterDepthDiff * perspectiveCorrection;

        #if defined(_FIXED_DEPTH)
            realWaterDepth = fixedDistortedDepth;
            shoreDepth = fixedVerticalDepth; // 使用固定深度，使透明度不随视角变化而改变
        #else
            // 非固定模式下使用原始 Eye Depth
            realWaterDepth = eyeWaterDepthDiff;
            shoreDepth = eyeShoreDepthDiff;
        #endif
    }

    // 3. 基础色 (Albedo) - 基于深度
    float colorDepthT = saturate(realWaterDepth / max(_DepthMaxDistance, 0.01));
    float colorGradient = pow(colorDepthT, _DepthExp);
    
    // RGB 颜色插值
    half3 waterBaseColor = lerp(_ShallowColor.rgb, _DeepColor.rgb, colorGradient);

    // 4. 泡沫计算 (Foam) - 基于固定的垂直深度
    float foamMask = 0;
#if defined(_FOAM)
    float foamDepth = fixedVerticalDepth; // 强制使用固定深度计算泡沫
    float foamFactor = saturate(1.0 - foamDepth / max(_FoamDistance, 0.001));
    
    // 采样两层噪声进行混合以获得更生动的泡沫
    float2 foamUV1 = uv * _FoamNoiseScale + _Time.y * _FoamNoiseSpeed.xy;
    float2 foamUV2 = uv * _FoamNoiseScale * 0.8 + _Time.y * _FoamNoiseSpeed.xy * -0.7;
    half noise1 = SAMPLE_TEXTURE2D(_FoamNoise, sampler_FoamNoise, foamUV1).r;
    half noise2 = SAMPLE_TEXTURE2D(_FoamNoise, sampler_FoamNoise, foamUV2).r;
    half combinedNoise = (noise1 + noise2) * 0.5;
    
    // 应用 Pow 处理噪声
    combinedNoise = pow(max(combinedNoise, 0.0), _FoamNoisePow);

    // 采用常见的泡沫阈值算法：saturate(foamFactor * Mul - noise - Cutoff)
    foamMask = saturate(foamFactor * _FoamNoiseMul - combinedNoise - _FoamNoiseCutoff);
    
    // 边缘过渡调整：使用属性控制 smoothstep 的上限
    // 范围越小越生硬，范围越大越平滑
    foamMask = smoothstep(0.0, max(_FoamSmoothness, 0.001), foamMask);

    // 【新增】：岸边交界平滑处理
    // 使泡沫在接触物体时有一个渐淡的过渡，消除交接处的硬边
    float foamShoreFade = smoothstep(0.0, max(_FoamShoreSmoothness, 0.0001), fixedVerticalDepth);
    foamMask *= foamShoreFade;
#endif
    
    half3 finalAlbedo = lerp(waterBaseColor, _FoamColor.rgb, foamMask);

    outSurfaceData.albedo = finalAlbedo;

    // 5. Alpha 计算 - 基于稳定的岸边深度 (shoreDepth)
    // 这样即使水面有巨大波动，岸边的接触线也是平滑且固定的
    float opacityDepthT = saturate(shoreDepth / max(_OpacityDepthDistance, 0.01));
    float opacityGradient = pow(opacityDepthT, _OpacityExp);
    
    // 使用独立的 float 属性控制不透明度
    float baseAlpha = lerp(_ShallowOpacity, _DeepOpacity, opacityGradient);
    
    // 泡沫应该增加不透明度
    outSurfaceData.alpha = saturate(baseAlpha + foamMask);

    // 6. 物理属性
    outSurfaceData.metallic = 0.0h;
    outSurfaceData.specular = half3(0.0h, 0.0h, 0.0h); 
    outSurfaceData.smoothness = _Smoothness;
    outSurfaceData.occlusion = foamMask; // 存储泡沫掩码，供 Lighting 阶段使用
    outSurfaceData.emission = 0.0h;
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
