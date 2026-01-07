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

    // 2. 准备原始水体颜色
    half3 waterBodyColor = surfaceData.albedo;
    
    // 【核心优化】为了让水面还原材质球颜色且不受 N.L 衰减影响：
    // 我们将 albedo 设为 0，让 PBR 阶段只处理高光 (Specular) 和环境反射 (Reflection)
    surfaceData.albedo = 0; 

    // 计算 PBR 光照 (此时 color.rgb 主要包含 Specular 和 泡沫的自发光权重)
    half4 color = UniversalFragmentPBR(inputData, surfaceData);

    // 获取主光源阴影数据以应用到水体颜色上
    Light mainLight = GetMainLight(inputData.shadowCoord, inputData.positionWS, inputData.shadowMask);
    
    // 计算受环境光和主灯光影响的水体色（不含 N.L，保证颜色鲜艳度）
    half3 lightingTint = mainLight.color * mainLight.shadowAttenuation + inputData.bakedGI;
    half3 finalBodyColor = waterBodyColor * lightingTint;

    // 获取泡沫掩码（从 occlusion 中读取）
    float foamMask = surfaceData.occlusion;

    // --- 物理增强的反射计算 ---
    // 1. 计算反射向量
    float3 reflectVector = reflect(-viewDirWS, inputData.normalWS);
    // 防止反射向量指向水下
    reflectVector.y = max(reflectVector.y, 0.0);
    reflectVector = normalize(reflectVector);

    // 2. 采样反射探针
    half3 reflectionColor = GlossyEnvironmentReflection(reflectVector, surfaceData.smoothness, 1.0);

    // 3. 计算菲涅尔效应
    float fresnel = pow(1.0 - saturate(dot(inputData.normalWS, viewDirWS)), _FresnelPower);
    
    // 4. 准备混合参数
    // 【优化】泡沫是不透明且多孔的粗糙物质，不应像镜面一样反射环境
    float finalReflectionStrength = _ReflectionStrength * (1.0 - foamMask);
    
    // 3. 混合背景与折射处理
    float2 screenUV = inputData.normalizedScreenSpaceUV;

#if defined(_REFRACTION)
    // 1. 统一扰动计算：使用与 Surface 阶段相同的 normalTS 和强度
    float2 offset = surfaceData.normalTS.xy * _DistortionStrength * _RefractionStrength;
    
    // 2. 岸边淡出优化
    float rawBackDepth = SampleSceneDepth(screenUV);
    float sceneBackDepth = LinearEyeDepth(rawBackDepth, _ZBufferParams);
    float eyeDepthDiff = max(0.0, sceneBackDepth - IN.screenPos.w);
    offset *= saturate(eyeDepthDiff * 10.0); 

    float2 distortedUV = screenUV + offset;
    
    // 3. 深度检查与平滑处理
    float rawDepth = SampleSceneDepth(distortedUV);
    float sceneDepth = LinearEyeDepth(rawDepth, _ZBufferParams);
    float surfaceDepth = IN.screenPos.w;
    
    // 【核心修复】：将硬切 (if) 改为平滑遮罩 (lerp)
    // 增加平滑度系数 (10.0 instead of 25.0)，防止折射采样的跳变产生硬边
    float distortionMask = saturate((sceneDepth - surfaceDepth) * 10.0); 
    distortedUV = lerp(screenUV, distortedUV, distortionMask);

    // 重新采样背景色（使用平滑后的 UV）
    half3 sceneColor = SampleSceneColor(distortedUV);
    
    // 【核心修复】：将“背景”与“受光照的水体主色”进行混合
    // surfaceData.alpha 已经包含了岸边深度淡出和泡沫
    half3 finalWaterColor = lerp(sceneColor, finalBodyColor, surfaceData.alpha);

    // 【核心修复】：把“PBR 结果（高光+泡沫）”和“反射”叠加。
    // 注意：高光和反射也应该随 Alpha 淡出，否则岸边交接处会有残留的白边/亮边
    half3 finalAddColor = (color.rgb + (reflectionColor * fresnel * finalReflectionStrength)) * surfaceData.alpha;
    color.rgb = finalWaterColor + finalAddColor;
    
    // 强制 Alpha 为 1，因为已经手动混合了背景
    color.a = 1.0;
#else
    // 如果未开启折射，使用硬件混合
    // 将受光照的水体色作为基础色
    color.rgb = finalBodyColor + color.rgb + (reflectionColor * fresnel * finalReflectionStrength);
    color.a = surfaceData.alpha;
#endif

    // 4. 雾效
    color.rgb = MixFog(color.rgb, IN.fogCoord);

    return color;
}

#endif
