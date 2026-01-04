#ifndef ZEPH_OPTIMIZED_LIGHTING_HLSL
#define ZEPH_OPTIMIZED_LIGHTING_HLSL

#include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/Lighting.hlsl"

// ---------------------------------------------------------------------------
// 光照计算函数
// ---------------------------------------------------------------------------
half4 CalculateLitColor(Varyings IN, SurfaceData surfaceData)
{
    InputData inputData = (InputData)0;

    // 1. 准备 InputData
    inputData.positionWS = IN.positionWS;
    
    // 视线方向
    half3 viewDirWS = GetWorldSpaceNormalizeViewDir(IN.positionWS);
    inputData.viewDirectionWS = viewDirWS;

    // 法线处理 (切线空间 -> 世界空间)
    // 无论是否开启基础法线贴图，都进行转换，以支持积雪法线
    half3 normalWS = TransformTangentToWorld(surfaceData.normalTS, half3x3(IN.tangentWS.xyz, cross(IN.normalWS, IN.tangentWS.xyz) * IN.tangentWS.w, IN.normalWS));
    inputData.normalWS = NormalizeNormalPerPixel(normalWS);

    // 阴影坐标
#if defined(REQUIRES_VERTEX_SHADOW_COORD_INTERPOLATOR)
    inputData.shadowCoord = IN.shadowCoord;
#elif defined(MAIN_LIGHT_CALCULATE_SHADOWS)
    inputData.shadowCoord = TransformWorldToShadowCoord(inputData.positionWS);
#else
    inputData.shadowCoord = float4(0, 0, 0, 0);
#endif

    // 全局光照 (GI)
    inputData.bakedGI = SAMPLE_GI(IN.lightmapUV, IN.vertexSH, inputData.normalWS);
    
    // 阴影遮罩
    inputData.shadowMask = SAMPLE_SHADOWMASK(IN.lightmapUV);
    
    // 屏幕空间 UV (用于 SSAO 等)
    inputData.normalizedScreenSpaceUV = GetNormalizedScreenSpaceUV(IN.positionCS);

    // 2. 计算 PBR 光照
    // UniversalFragmentPBR 处理了直接光、间接光和自发光
    half4 color = UniversalFragmentPBR(inputData, surfaceData);

    // 3. 雪地闪烁 (Snow Sparkles)
#if defined(_SPARKLE)
    // 使用多层噪声叠加来彻底打乱规则的网格感
    // Layer 1: 基础层
    float noise1 = SparkleNoise(inputData.positionWS, inputData.viewDirectionWS, inputData.normalWS, _SparkleScale, 0.0);
    
    // Layer 2: 旋转 45 度，打破网格对齐
    float3 pos2 = inputData.positionWS;
    float s2, c2;
    sincos(0.785, s2, c2); // ~45 degrees
    pos2.xz = float2(pos2.x * c2 - pos2.z * s2, pos2.x * s2 + pos2.z * c2);
    float noise2 = SparkleNoise(pos2, inputData.viewDirectionWS, inputData.normalWS, _SparkleScale * 1.732, float3(12.3, 45.6, 78.9));
    
    // Layer 3: 旋转 -30 度，进一步打乱
    float3 pos3 = inputData.positionWS;
    float s3, c3;
    sincos(-0.523, s3, c3); // ~-30 degrees
    pos3.xz = float2(pos3.x * c3 - pos3.z * s3, pos3.x * s3 + pos3.z * c3);
    float noise3 = SparkleNoise(pos3, inputData.viewDirectionWS, inputData.normalWS, _SparkleScale * 2.414, float3(-31.7, 19.2, 5.4));
    
    float combinedNoise = noise1 + noise2 + noise3;
    half sparkle = saturate((combinedNoise - _SparkleThreshold) * 5.0);
    
    half rawLuminance = saturate(Luminance(color.rgb));
    half diffuseMask = smoothstep(0.35, 0.5, rawLuminance);
    
    half3 sparkleRGB = 0;

#if defined(_BAKED_SPARKLE)
    sparkleRGB = sparkle * _SparkleIntensity * _BakedSparkleColor.rgb;
#else
    Light mainLight = GetMainLight(inputData.shadowCoord, inputData.positionWS, inputData.shadowMask);
    sparkleRGB = sparkle * _SparkleIntensity * mainLight.color;
#endif
    
    // 只有在积雪区域才显示闪烁
    // 我们需要从某处获取 snowFactor。
    // 既然 CalculateLitColor 接收 Varyings IN，我们可以把 snowFactor 存在 IN 里。
    color.rgb += sparkleRGB * diffuseMask * IN.snowFactor;
#endif

    // 4. 雾效
#if defined(FOG_FRAGMENT)
    color.rgb = MixFog(color.rgb, IN.fogCoord);
#endif

    return color;
}

#endif
