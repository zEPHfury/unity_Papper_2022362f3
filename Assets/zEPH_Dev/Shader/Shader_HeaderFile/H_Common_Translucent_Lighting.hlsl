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

    // 3. 折射处理
    // 目前是屏幕空间折射方案，如果遇到性能瓶颈 或者 VR 中屏幕空间折射导致不适（立体视觉不一致），改用 Cubemap 方案
#if defined(_REFRACTION)
    // 计算折射 UV 偏移：基于视图空间法线
    // 注意：这里简化处理，使用世界空间法线投影到屏幕空间
    // 更精确的做法是将法线转换到视图空间
    
    // 简单的折射模拟：使用法线的 XY 分量作为偏移
    // 乘以 _RefractionStrength 和 (1 - dot(view, normal)) 可以模拟菲涅尔效应（边缘折射更强）
    // 但通常直接用强度即可
    float2 screenUV = inputData.normalizedScreenSpaceUV;
    
    // 优化：使用 View Space Normal 计算偏移，更符合物理直觉
    // 将世界空间法线转换到视图空间
    float3 normalVS = TransformWorldToViewDir(inputData.normalWS, true); // 第二个参数 true 表示这是一个方向向量
    
    // 使用视图空间法线的 XY 分量作为偏移
    // 乘以 _RefractionStrength
    float2 offset = normalVS.xy * _RefractionStrength * 0.5; // 0.5 是经验值，调整灵敏度
    
    // 采样场景颜色 (Opaque Texture)
    half3 sceneColor = SampleSceneColor(screenUV + offset);
    
    // 混合：
    // 如果开启折射，我们通常希望用折射后的背景替换原始背景
    // 但由于我们处于 Transparent 队列，且 Blend SrcAlpha OneMinusSrcAlpha
    // 最终颜色 = ShaderColor * Alpha + Background * (1 - Alpha)
    // 
    // 为了显示折射效果，我们需要手动混合 SceneColor 和 LitColor
    // 然后将 Alpha 设为 1，以覆盖掉默认的背景混合
    
    // 按照不透明度混合：
    // 表面越不透明，显示越多 LitColor；越透明，显示越多 Refracted SceneColor
    color.rgb = lerp(sceneColor, color.rgb, surfaceData.alpha);
    
    // 强制 Alpha 为 1，防止再次与未折射的背景混合
    color.a = 1.0;
#endif

    // 4. 雾效
#if defined(FOG_FRAGMENT)
    color.rgb = MixFog(color.rgb, IN.fogCoord);
#endif

    return color;
}

#endif
