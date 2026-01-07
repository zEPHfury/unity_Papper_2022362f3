#ifndef ZEPH_OPTIMIZED_LIGHTING_HLSL
#define ZEPH_OPTIMIZED_LIGHTING_HLSL

#include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/Lighting.hlsl"

// ---------------------------------------------------------------------------
// UE GGX Anisotropic Lighting Model
// ---------------------------------------------------------------------------
float GGXAniso(float3 L, float3 N, float3 V, float3 X, float3 Y, float strength, float offset)
{
    float ax = saturate(dot(N, L));
    float ay = saturate(dot(N, V));
    float3 H = normalize(V + L);
    float NoH = dot(N, H);
    float XoH = dot(X, H);
    float YoH = dot(Y, H) + offset;
    float a2 = ax * ay;
    float3 V1 = float3(ay * XoH, ax * YoH, a2 * NoH);
    float S = dot(V1, V1);
    
    // Prevent division by zero
    S = max(S, 1e-4);
    
    // Input PI in the screenshot is strength * 0.1
    float param = strength * 0.1;
    param = max(param, 1e-3);
    
    float term = a2 / S;
    float result = saturate((1.0 / param) * a2 * term * term);
    
    // Optimization: Fade out artifacts at grazing angles (where a2 is small)
    // This helps reduce the "strong start point" or hard edges at the silhouette
    result *= smoothstep(0.0, 0.2, a2);
    
    return result;
}

// ---------------------------------------------------------------------------
// Custom Lighting Function
// ---------------------------------------------------------------------------
half3 LightingSilkMetal(Light light, InputData inputData, SurfaceData surfaceData, BRDFData brdfData, float3 tangentWS, float3 bitangentWS)
{
    // --- 1. Silk Lighting (GGX Aniso) ---
    half3 lightColor = light.color * light.distanceAttenuation * light.shadowAttenuation;
    half3 L = light.direction;
    half3 N = inputData.normalWS;
    half3 V = inputData.viewDirectionWS;
    
    // Diffuse (Lambert)
    half NoL = saturate(dot(N, L));
    half3 silkDiffuse = surfaceData.albedo * lightColor * NoL;
    
    // Specular (GGX Aniso)
    // Apply direction scaling from properties
    // NOTE: The UE model requires the scale vectors to be >= 1.0 to avoid inversion artifacts at grazing angles.
    float scaleX = max(_AnisoDirX, 1.0);
    float scaleY = max(_AnisoDirY, 1.0);
    
    float3 X = tangentWS * scaleX;
    float3 Y = bitangentWS * scaleY;
    
    // Use _AnisoSpread for the shape calculation (matches UE Param(8))
    float aniso = GGXAniso(L, N, V, X, Y, _AnisoSpread, _AnisoOffset);
    
    // Apply specular color and intensity multiplier
    half3 silkSpecular = _AnisoColor.rgb * aniso * lightColor * _AnisoStrength;
    
    half3 silkColor = silkDiffuse + silkSpecular;

    // --- 2. Metal Lighting (Standard PBR) ---
    // 使用 URP 标准 PBR 光照模型
    half3 metalColor = LightingPhysicallyBased(brdfData, light, inputData.normalWS, inputData.viewDirectionWS);
    
    // Apply AO to Metal Direct Lighting
    metalColor *= surfaceData.occlusion;

    // --- 3. Blend ---
    // 使用 metallic (ORMA.b) 作为遮罩混合
    // 0 = Silk (GGX Aniso), 1 = Metal (Standard PBR)
    return lerp(silkColor, metalColor, surfaceData.metallic);
}

// ---------------------------------------------------------------------------
// Main Fragment Function
// ---------------------------------------------------------------------------
half4 SilkFragmentPBR(InputData inputData, SurfaceData surfaceData, float3 tangentWS, float3 bitangentWS)
{
    // 初始化 BRDFData (用于标准 PBR 计算)
    BRDFData brdfData;
    InitializeBRDFData(surfaceData, brdfData);

    // 1. Main Light
    Light mainLight = GetMainLight(inputData.shadowCoord, inputData.positionWS, inputData.shadowMask);
    MixRealtimeAndBakedGI(mainLight, inputData.normalWS, inputData.bakedGI);
    
    // Apply Ambient Occlusion to GI
    inputData.bakedGI *= surfaceData.occlusion;
    
    // GI (Ambient) Calculation
    // Silk 部分使用简单的 Diffuse GI
    half3 silkGI = inputData.bakedGI * surfaceData.albedo;
    // Metal 部分使用完整的 PBR GI (包含环境反射)
    half3 metalGI = GlobalIllumination(brdfData, inputData.bakedGI, surfaceData.occlusion, inputData.normalWS, inputData.viewDirectionWS);
    
    half3 color = lerp(silkGI, metalGI, surfaceData.metallic);
    
    // Main Light Contribution
    color += LightingSilkMetal(mainLight, inputData, surfaceData, brdfData, tangentWS, bitangentWS);
    
    // 2. Additional Lights
#ifdef _ADDITIONAL_LIGHTS
    uint pixelLightCount = GetAdditionalLightsCount();
    for (uint lightIndex = 0u; lightIndex < pixelLightCount; ++lightIndex)
    {
        Light light = GetAdditionalLight(lightIndex, inputData.positionWS, inputData.shadowMask);
        color += LightingSilkMetal(light, inputData, surfaceData, brdfData, tangentWS, bitangentWS);
    }
#endif

    // 3. Emission
    // color += surfaceData.emission;

    // 4. Baked Specular Compensation (Fake Specular)
    #if defined(_USE_BAKED_SPECULAR)
        // 使用 float3 进行高精度计算，避免 half 精度导致的断裂和伪影
        float3 fakeLightDir = normalize(_BakedLightDir.xyz);
        float3 fakeLightColor = _BakedLightColor.rgb;
        
        // 直接计算高光，不经过 Light 结构体 (避免被截断为 half)
        float3 L = fakeLightDir;
        // 重新计算高精度 View Direction
        float3 V = SafeNormalize(GetCameraPositionWS() - inputData.positionWS);
        // 使用 float3 转换 Normal (虽然 inputData.normalWS 可能是 half，但后续计算保持 float)
        float3 N = float3(inputData.normalWS);
        
        // 准备各向异性参数
        float scaleX = max(_AnisoDirX, 1.0);
        float scaleY = max(_AnisoDirY, 1.0);
        float3 X = tangentWS * scaleX;
        float3 Y = bitangentWS * scaleY;
        
        // 计算 GGX Aniso
        float aniso = GGXAniso(L, N, V, X, Y, _AnisoSpread, _AnisoOffset);
        
        // 计算高光颜色
        half3 fakeSpecular = _AnisoColor.rgb * aniso * fakeLightColor * _AnisoStrength;

        // 只应用到 Silk 部分 (非金属部分)
        // 混合因子: 0 = Silk, 1 = Metal. 所以我们要乘以 (1 - metallic)
        color += fakeSpecular * (1.0 - surfaceData.metallic);
    #endif

    return half4(color, surfaceData.alpha);
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

    // 2. 计算 PBR 光照 (使用自定义 Silk Lighting)
    // 准备切线和副切线 (世界空间)
    // 优化：使用 Gram-Schmidt 正交化修正切线，减少插值导致的非正交误差
    // 这有助于减轻球体极点处的 UV 奇点伪影，并确保各向异性方向与法线垂直
    float3 tangentWS = normalize(IN.tangentWS.xyz);
    // 强制切线垂直于当前法线 (Re-orthogonalize)
    tangentWS = normalize(tangentWS - dot(tangentWS, inputData.normalWS) * inputData.normalWS);
    float3 bitangentWS = cross(inputData.normalWS, tangentWS) * IN.tangentWS.w;
    
    half4 color = SilkFragmentPBR(inputData, surfaceData, tangentWS, bitangentWS);

    // 3. 雾效
    color.rgb = MixFog(color.rgb, IN.fogCoord);

    return color;
}

#endif
