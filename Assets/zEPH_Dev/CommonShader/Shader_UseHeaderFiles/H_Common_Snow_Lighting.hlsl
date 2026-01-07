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
    half3 normalWS = IN.normalWS;
#if defined(_NORMALMAP)
    normalWS = TransformTangentToWorld(surfaceData.normalTS, half3x3(IN.tangentWS.xyz, cross(IN.normalWS, IN.tangentWS.xyz) * IN.tangentWS.w, IN.normalWS));
#endif
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
    // 每一层使用不同的缩放比例（非整数倍）和随机偏移
    float noise1 = SparkleNoise(inputData.positionWS, inputData.viewDirectionWS, _SparkleScale, 0.0);
    float noise2 = SparkleNoise(inputData.positionWS, inputData.viewDirectionWS, _SparkleScale * 1.732, float3(12.3, 45.6, 78.9));
    float noise3 = SparkleNoise(inputData.positionWS, inputData.viewDirectionWS, _SparkleScale * 2.414, float3(-31.7, 19.2, 5.4));
    
    // 叠加噪声，并应用全局阈值控制
    float combinedNoise = noise1 + noise2 + noise3;
    // 使用更直接的线性映射，增强对比度，让闪烁点“跳”出来
    half sparkle = saturate((combinedNoise - _SparkleThreshold) * 5.0);
    
    // --- 第4种方案：基于最终光照结果的亮度遮罩 (Diffuse Result Masking) ---
    // 提取 PBR 计算后的表面亮度。
    half rawLuminance = saturate(Luminance(color.rgb));
    
    // 优化：使用非线性映射（smoothstep 或 pow）来增强遮罩的对比度。
    // 这样可以确保在亮度较低的阴影区，遮罩值迅速降为 0，从而彻底消除暗部闪烁。
    // 这里使用 smoothstep(0.2, 0.5, ...) 表示亮度低于 0.2 的区域将完全没有闪烁。
    half diffuseMask = smoothstep(0.35, 0.5, rawLuminance);
    
    half3 sparkleRGB = 0;

#if defined(_BAKED_SPARKLE)
    // 烘焙模式：使用自定义颜色
    // 闪烁强度不再硬编码 GI 偏移，而是完全依赖最终颜色的亮度遮罩
    sparkleRGB = sparkle * _SparkleIntensity * _BakedSparkleColor.rgb;
#else
    // 实时模式：受主光源颜色影响
    Light mainLight = GetMainLight(inputData.shadowCoord, inputData.positionWS, inputData.shadowMask);
    sparkleRGB = sparkle * _SparkleIntensity * mainLight.color;
#endif
    
    // 将闪烁点叠加到最终颜色上，并应用亮度遮罩
    // 这样可以确保在阴影、背光面或环境光极弱的区域没有高光点
    color.rgb += sparkleRGB * diffuseMask;
#endif

    // 4. 雾效
    color.rgb = MixFog(color.rgb, IN.fogCoord);

    return color;
}

#endif
