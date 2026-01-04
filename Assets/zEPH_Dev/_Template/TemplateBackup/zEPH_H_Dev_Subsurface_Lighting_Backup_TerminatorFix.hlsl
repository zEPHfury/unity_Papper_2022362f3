#ifndef ZEPH_OPTIMIZED_LIGHTING_HLSL
#define ZEPH_OPTIMIZED_LIGHTING_HLSL

#include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/Lighting.hlsl"

// ---------------------------------------------------------------------------
// 辅助函数：计算曲率
// ---------------------------------------------------------------------------
float GetCurvature(float3 normalWS)
{
    // [修改说明] 移除了 fwidth(normalWS)。
    // fwidth 在低模或未抗锯齿的表面上会产生极大的噪点和锯齿（Terminator Artifacts）。
    // 除非你有专门的曲率贴图，否则直接用参数控制整体软度效果更好、更平滑。
    return _SSSCurvatureScale;
}

// ---------------------------------------------------------------------------
// 核心算法：Wrapped Diffuse + Gaussian SSS (环绕光照 + 高斯散射带)
// ---------------------------------------------------------------------------
// 这种算法专门用于模拟右图那种平滑的、带有红边的次表面散射效果。
// 它比纯 SG 更稳定，完全消除了低模上的锯齿 (Terminator Artifacts)。
// ---------------------------------------------------------------------------
half3 CalculateSG_SSS(float3 lightColor, float3 lightDir, float3 normalWS, float3 viewDirWS, float3 albedo, float curvature, float shadowAttenuation)
{
    half NdotL = dot(normalWS, lightDir);

    // -----------------------------------------------------------------------
    // 1. 基础光照：Wrapped Diffuse (环绕漫反射)
    // -----------------------------------------------------------------------
    // 传统的 saturate(NdotL) 在 0 处截断，导致明暗交界生硬。
    // Wrapped Diffuse 将光照“包裹”到背面，形成极其柔和的基底。
    // wrapAmount: 0.5 是一个经验值，表示光线能绕射到背面 90 度。
    half wrapAmount = 0.5;
    half wrappedNdotL = saturate((NdotL + wrapAmount) / (1.0 + wrapAmount));
    
    // -----------------------------------------------------------------------
    // 2. 散射带模拟：Gaussian SSS Band (高斯红边)
    // -----------------------------------------------------------------------
    // 我们需要在明暗交界处 (NdotL ≈ 0) 叠加一层高饱和度的散射色。
    // 使用高斯函数 exp(-x^2) 来模拟这个“凸起”的红色光带。
    // x 越接近 0，函数值越大。
    
    // 偏移量：控制红边出现的位置。
    // -0.1 表示红边稍微向暗部偏移一点点，效果更自然。
    half shift = -0.1; 
    
    // 宽度：由 _SSSScale 控制。值越小，红边越窄；值越大，红边越宽。
    // 我们取倒数作为“锐度”参数。
    half width = max(_SSSScale, 0.01);
    half sharpness = 1.0 / (width * width);
    
    // 计算高斯分布：在 (NdotL - shift) == 0 处达到峰值 1.0
    half scatterTerm = exp(-sharpness * (NdotL - shift) * (NdotL - shift));
    
    // 限制散射强度：防止红边过曝
    scatterTerm *= _SSSScale;

    // -----------------------------------------------------------------------
    // 3. 阴影柔化 (Shadow Blur)
    // -----------------------------------------------------------------------
    // SSS 的物理特性决定了它会模糊阴影。
    // 我们根据散射强度，混合“硬阴影”和“无阴影(1.0)”。
    // 散射越强 (scatterTerm 大) 或 基础光照越弱 (进入暗部)，阴影越应该模糊。
    
    // [Fix] 增加 Terminator 修复因子
    // 当 NdotL 接近 0 或为负时，极易出现阴影锯齿。我们在此区域强制增加模糊度。
    // 使用 smoothstep 在明暗交界处平滑过渡，隐藏 Shadow Map 的精度问题。
    half terminatorFix = 1.0 - smoothstep(-0.05, 0.1, NdotL);
    
    half shadowBlur = saturate(scatterTerm + (1.0 - wrappedNdotL) * 0.5 + terminatorFix * 0.5);
    
    // [Fix] 允许更高的模糊上限 (从 0.8 提升到 0.95)，以便在交界处更好地隐藏锯齿
    half softShadow = lerp(shadowAttenuation, 1.0, shadowBlur * 0.95);

    // -----------------------------------------------------------------------
    // 4. 最终合成
    // -----------------------------------------------------------------------
    // 层1：漫反射 (受软阴影影响)
    // 使用 wrappedNdotL 使得暗部不是死黑，而是有淡淡的层次
    half3 diffuseLayer = wrappedNdotL * lightColor * softShadow;
    
    // 层2：散射带 (受软阴影影响)
    // 这是叠加在明暗交界处的颜色
    half3 scatterLayer = scatterTerm * _SSSColor.rgb * lightColor * softShadow;
    
    // 组合：Albedo * (漫反射 + 散射带)
    // 注意：这里是加法叠加，模拟光线在皮肤内部散射后溢出的能量
    return (diffuseLayer + scatterLayer) * albedo;
}

// ---------------------------------------------------------------------------
// 自定义光照循环函数 (替代 UniversalFragmentPBR)
// ---------------------------------------------------------------------------
half4 CalculateLitColor(Varyings IN, SurfaceData surfaceData)
{
    // 1. 准备数据
    InputData inputData = (InputData)0;
    inputData.positionWS = IN.positionWS;
    inputData.viewDirectionWS = GetWorldSpaceNormalizeViewDir(IN.positionWS);
    
    // 法线处理
    half3 normalWS = IN.normalWS;
#if defined(_NORMALMAP)
    normalWS = TransformTangentToWorld(surfaceData.normalTS, half3x3(IN.tangentWS.xyz, cross(IN.normalWS, IN.tangentWS.xyz) * IN.tangentWS.w, IN.normalWS));
#endif
    inputData.normalWS = NormalizeNormalPerPixel(normalWS);
    
    // 阴影
#if defined(REQUIRES_VERTEX_SHADOW_COORD_INTERPOLATOR)
    inputData.shadowCoord = IN.shadowCoord;
#elif defined(MAIN_LIGHT_CALCULATE_SHADOWS)
    inputData.shadowCoord = TransformWorldToShadowCoord(inputData.positionWS);
#else
    inputData.shadowCoord = float4(0, 0, 0, 0);
#endif

    inputData.bakedGI = SAMPLE_GI(IN.lightmapUV, IN.vertexSH, inputData.normalWS);
    inputData.shadowMask = SAMPLE_SHADOWMASK(IN.lightmapUV);
    inputData.normalizedScreenSpaceUV = GetNormalizedScreenSpaceUV(IN.positionCS);

    // 初始化 BRDF
    BRDFData brdfData;
    InitializeBRDFData(surfaceData, brdfData);

    // -----------------------------------------------------------------------
    // 开始光照计算
    // -----------------------------------------------------------------------
    half3 color = GlobalIllumination(brdfData, inputData.bakedGI, surfaceData.occlusion, inputData.normalWS, inputData.viewDirectionWS);
    
    // 计算曲率 (仅当开启 SSS 时)
    float curvature = 0;
#if defined(_SSS_ON)
    curvature = GetCurvature(inputData.normalWS);
#endif

    // --- 主光源 ---
    Light mainLight = GetMainLight(inputData.shadowCoord, inputData.positionWS, inputData.shadowMask);
    
    // [修改] 不再将 shadowAttenuation 乘入 lightColor，而是单独传递
    half3 mainLightColor = mainLight.color * mainLight.distanceAttenuation;
    
    // 1. Specular (高光) - 保持 PBR 标准 (受阴影影响)
    half3 mainSpecular = DirectBDRF(brdfData, inputData.normalWS, mainLight.direction, inputData.viewDirectionWS);
    // [Fix] 增加 NdotL 项以符合 PBR 能量守恒，同时有助于隐藏背光面的阴影锯齿
    mainSpecular *= mainLight.shadowAttenuation * saturate(dot(inputData.normalWS, mainLight.direction));
    
    // 2. Diffuse (漫反射) - 替换为 SG SSS
    half3 mainDiffuse = 0;
#if defined(_SSS_ON)
    // 使用 SG SSS 算法 (传入 shadowAttenuation)
    mainDiffuse = CalculateSG_SSS(mainLightColor, mainLight.direction, inputData.normalWS, inputData.viewDirectionWS, surfaceData.albedo, curvature, mainLight.shadowAttenuation);
#else
    // 标准 PBR 漫反射
    // [Fix] 增加 Terminator Fix (终结线修复)，消除低模阴影锯齿
    half NdotL = dot(inputData.normalWS, mainLight.direction);
    half lightTerm = saturate(NdotL);
    
    // 使用 smoothstep 提前压暗光照，隐藏阴影贴图在明暗交界处的锯齿
    // 0.05 是一个经验值，表示在 NdotL < 0.05 的区域强制变黑
    lightTerm *= smoothstep(0.05, 0.1, NdotL);
    
    mainDiffuse = mainLightColor * lightTerm * surfaceData.albedo * mainLight.shadowAttenuation;
#endif

    color += mainDiffuse + mainSpecular * mainLightColor;

    // --- 额外光源 ---
#ifdef _ADDITIONAL_LIGHTS
    uint pixelLightCount = GetAdditionalLightsCount();
    for (uint lightIndex = 0u; lightIndex < pixelLightCount; ++lightIndex)
    {
        Light light = GetAdditionalLight(lightIndex, inputData.positionWS, inputData.shadowMask);
        half3 lightColor = light.color * light.distanceAttenuation; // 分离阴影
        
        half3 specular = DirectBDRF(brdfData, inputData.normalWS, light.direction, inputData.viewDirectionWS);
        specular *= light.shadowAttenuation * saturate(dot(inputData.normalWS, light.direction));
        
        half3 diffuse = 0;
        
    #if defined(_SSS_ON)
        diffuse = CalculateSG_SSS(lightColor, light.direction, inputData.normalWS, inputData.viewDirectionWS, surfaceData.albedo, curvature, light.shadowAttenuation);
    #else
        // diffuse = LightingLambert(lightColor, light.direction, inputData.normalWS) * surfaceData.albedo * light.shadowAttenuation;
        half NdotL = dot(inputData.normalWS, light.direction);
        half lightTerm = saturate(NdotL);
        lightTerm *= smoothstep(0.05, 0.1, NdotL);
        diffuse = lightColor * lightTerm * surfaceData.albedo * light.shadowAttenuation;
    #endif
        
        color += diffuse + specular * lightColor;
    }
#endif

    // --- 雾效 ---
#if defined(FOG_FRAGMENT)
    color = MixFog(color, inputData.fogCoord);
#endif

    // --- 自发光 ---
    color += surfaceData.emission;

    return half4(color, surfaceData.alpha);
}

#endif
