#ifndef ZEPH_OPTIMIZED_LIGHTING_HLSL
#define ZEPH_OPTIMIZED_LIGHTING_HLSL

#include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/Lighting.hlsl"
#include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/DeclareOpaqueTexture.hlsl"

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
    // 【焦散处理】：我们将焦散存放在 emission 中，但我们希望它作用在水底而非水面
    // 所以先提取焦散颜色，然后清空 emission，防止 PBR 函数将其加到水面反射上
    half3 causticColor = surfaceData.emission;
    surfaceData.emission = 0;

    half4 color = UniversalFragmentPBR(inputData, surfaceData);

    // --- 手动反射计算 (移植自模板) ---
    // 1. 计算反射向量
    float3 reflectVector = reflect(-viewDirWS, inputData.normalWS);
    // 【修正】防止反射向量指向水下导致黑斑。水面反射通常不应该采样地平线以下的内容。
    reflectVector.y = max(reflectVector.y, 0.0);
    reflectVector = normalize(reflectVector);

    // 2. 采样反射探针
    half3 reflectionColor = GlossyEnvironmentReflection(reflectVector, 0.0, 1.0);

    // 3. 计算菲涅尔效应
    float fresnel = pow(1.0 - saturate(dot(inputData.normalWS, viewDirWS)), _FresnelPower);
    // 4. 混合反射颜色
    color.rgb = lerp(color.rgb, reflectionColor, fresnel * _ReflectionStrength);
    
    // 5. 增强反射处的不透明度
    // 【关键优化】：反射引起的不透明度增强也必须在岸边淡出，否则会导致接触面出现硬边
    // 我们让反射强度随原本的 Alpha（即深度）同步淡出
    float reflectionAlpha = fresnel * _ReflectionStrength;
    surfaceData.alpha = max(surfaceData.alpha, reflectionAlpha * saturate(surfaceData.alpha * 5.0));

    // 3. 混合背景与折射处理
    float2 screenUV = inputData.normalizedScreenSpaceUV;

#if defined(_REFRACTION)
    // 1. 统一扰动计算：使用与 Surface 阶段相同的 normalTS 和强度
    float2 offset = surfaceData.normalTS.xy * _DistortionStrength * _RefractionStrength;
    
    // 2. 岸边淡出优化：当 Alpha 趋于 0（岸边）时，强制减弱扰动，防止采样到水面以上的物体
    // 使用 saturate(surfaceData.alpha * 2.0) 让扰动在岸边快速消失
    offset *= saturate(surfaceData.alpha * 2.0); 

    float2 distortedUV = screenUV + offset;
    
    // 3. 深度检查：如果扰动后的采样点在水面之前，则取消扰动
    float rawDepth = SampleSceneDepth(distortedUV);
    float sceneDepth = LinearEyeDepth(rawDepth, _ZBufferParams);
    float surfaceDepth = IN.screenPos.w;
    
    if (sceneDepth < surfaceDepth) {
        distortedUV = screenUV;
    }

    // 采样场景颜色
    half3 sceneColor = SampleSceneColor(distortedUV);
    
    // 【应用焦散】：将焦散颜色叠加到水底背景色上
    #if defined(_CAUSTICS)
    sceneColor += causticColor;
    #endif

    // 手动混合：最终颜色 = 场景背景 * (1 - Alpha) + 水面颜色 * Alpha
    color.rgb = lerp(sceneColor, color.rgb, surfaceData.alpha);
    
    // 强制 Alpha 为 1，因为已经手动混合了背景
    color.a = 1.0;
#else
    // 如果未开启折射，使用硬件混合 (SrcAlpha OneMinusSrcAlpha)
    // 此时 Alpha 值直接决定了透明度
    color.a = surfaceData.alpha;
#endif

    // 4. 雾效
    color.rgb = MixFog(color.rgb, IN.fogCoord);

    return color;
}

#endif
