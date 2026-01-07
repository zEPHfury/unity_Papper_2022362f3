#ifndef ZEPH_OPTIMIZED_LIGHTING_HLSL
#define ZEPH_OPTIMIZED_LIGHTING_HLSL

#include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/Lighting.hlsl"

// ---------------------------------------------------------------------------
// Oren Nayar 光照模型实现
// ---------------------------------------------------------------------------
half3 OrenNayarDiffuse(half3 normalWS, half3 viewDirWS, half3 lightDirWS, half3 albedo, half roughness)
{
    half NoV = dot(normalWS, viewDirWS);
    half NoL = dot(normalWS, lightDirWS);
    
    // 钳制到 [0, 1]
    half cosThetaI = max(0.0h, NoL);
    half cosThetaR = max(0.0h, NoV);
    
    // Oren Nayar 参数计算
    half sigma2 = roughness * roughness;
    half A = 1.0h - 0.5h * (sigma2 / (sigma2 + 0.33h));
    half B = 0.45h * (sigma2 / (sigma2 + 0.09h));
    
    // 计算 sin
    half sinThetaI = sqrt(max(0.0h, 1.0h - cosThetaI * cosThetaI));
    half sinThetaR = sqrt(max(0.0h, 1.0h - cosThetaR * cosThetaR));
    
    // 计算 cos(phi_i - phi_r)
    // 使用更鲁棒的方法：(L·V - (N·L)(N·V)) / (sinThetaI * sinThetaR)
    half cosPhiDiff = 0;
    half denom = sinThetaI * sinThetaR;
    if (denom > 0.0001h)
    {
        cosPhiDiff = max(0.0h, (dot(lightDirWS, viewDirWS) - cosThetaI * cosThetaR) / denom);
    }
    
    // alpha = max(theta_i, theta_r), beta = min(theta_i, theta_r)
    // 对应 cosAlpha = min(cosThetaI, cosThetaR), cosBeta = max(cosThetaI, cosThetaR)
    half sinAlpha, tanBeta;
    if (cosThetaI < cosThetaR) // theta_i > theta_r
    {
        sinAlpha = sinThetaI;
        tanBeta = sinThetaR / max(cosThetaR, 0.0001h);
    }
    else
    {
        sinAlpha = sinThetaR;
        tanBeta = sinThetaI / max(cosThetaI, 0.0001h);
    }
    
    // Oren Nayar 公式
    half orenNayar = A + B * cosPhiDiff * sinAlpha * tanBeta;
    
    return albedo * cosThetaI * orenNayar;
}

// ---------------------------------------------------------------------------
// Rim Light (边缘光) 计算
// ---------------------------------------------------------------------------
half3 RimLighting(half3 normalWS, half3 viewDirWS, half3 rimColor, half rimExponent)
{
    half NoV = dot(normalWS, viewDirWS);
    half rimIntensity = pow(max(0.0h, 1.0h - abs(NoV)), rimExponent);
    return rimColor * rimIntensity;
}

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

    // 1. 计算 Oren Nayar + Rim (当金属度为 0 时的主导效果)
    half3 orenNayarRGB = 0;
    {
        // 获取主光源
        Light mainLight = GetMainLight(inputData.shadowCoord);
        half3 mainLightDiffuse = OrenNayarDiffuse(inputData.normalWS, viewDirWS, mainLight.direction, 
                                                  surfaceData.albedo, _OrenNayarRoughness);
        orenNayarRGB = mainLightDiffuse * mainLight.color * mainLight.distanceAttenuation * mainLight.shadowAttenuation;
        
        // 添加环境光照 (应用 AO)
        orenNayarRGB += inputData.bakedGI * surfaceData.albedo * surfaceData.occlusion;
        
        // 添加边缘光
        half3 rimLight = RimLighting(inputData.normalWS, viewDirWS, 
                                      mainLight.color * _RimIntensity, _RimExponent);
        orenNayarRGB += rimLight * _RimRange;
        
        // 额外光源
    #if defined(_ADDITIONAL_LIGHTS)
        uint pixelLightCount = GetAdditionalLightsCount();
        for (uint lightIndex = 0u; lightIndex < pixelLightCount; ++lightIndex)
        {
            Light light = GetAdditionalLight(lightIndex, inputData.positionWS, inputData.shadowMask);
            half3 additionalDiffuse = OrenNayarDiffuse(inputData.normalWS, viewDirWS, light.direction,
                                                        surfaceData.albedo, _OrenNayarRoughness);
            orenNayarRGB += additionalDiffuse * light.color * light.distanceAttenuation * light.shadowAttenuation;
        }
    #endif
    }

    // 2. 计算 PBR 光照 (当金属度为 1 时的主导效果)
    half4 pbrColor = UniversalFragmentPBR(inputData, surfaceData);

    // 3. 根据金属度进行插值
    // 金属度为 1 时走 PBR，金属度为 0 时走 Oren Nayar
    half3 finalRGB = lerp(orenNayarRGB, pbrColor.rgb, surfaceData.metallic);
    
    half4 color = half4(finalRGB, surfaceData.alpha);

    // 5. 雾效
    color.rgb = MixFog(color.rgb, IN.fogCoord);

    return color;
}

#endif
