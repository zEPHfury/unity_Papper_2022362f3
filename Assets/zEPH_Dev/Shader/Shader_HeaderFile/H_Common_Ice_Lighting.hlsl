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

    // 3. 次表面散射 (SSS Hack) - 模拟冰的透光感
    Light mainLight = GetMainLight(inputData.shadowCoord, inputData.positionWS, inputData.shadowMask);
    // 使用背光方向计算透射
    half backLit = pow(saturate(dot(mainLight.direction, -inputData.normalWS)), _SSSPower);
    // 结合阴影，避免阴影区也有过强的透射（可选，冰块内部通常会有散射）
    half3 sssTerm = backLit * _SSSColor.rgb * _SSSIntensity * mainLight.color * mainLight.distanceAttenuation;
    color.rgb += sssTerm * surfaceData.albedo; // 与基础色结合

    // 4. 雾效
#if defined(FOG_FRAGMENT)
    color.rgb = MixFog(color.rgb, IN.fogCoord);
#endif

    return color;
}

#endif
