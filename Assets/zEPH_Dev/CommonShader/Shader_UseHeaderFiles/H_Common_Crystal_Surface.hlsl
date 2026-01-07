#ifndef ZEPH_OPTIMIZED_SURFACE_HLSL
#define ZEPH_OPTIMIZED_SURFACE_HLSL

#include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/Core.hlsl"
#include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/SurfaceData.hlsl"
#include "Packages/com.unity.render-pipelines.core/ShaderLibrary/CommonMaterial.hlsl"

// ---------------------------------------------------------------------------
// CBUFFER: 材质属性定义
// 必须与 Shader 中的 Properties 顺序和名称保持一致以支持 SRP Batcher
// ---------------------------------------------------------------------------
CBUFFER_START(UnityPerMaterial)
    // [Impurity] 杂质相关属性
    float4 _ImpurityScale;
    float4 _ImpurityOffset;
    float4 _InnerImpurityOffset;
    float _ImpurityDepthInterval;
    float _ImpurityDepthOffset;
    half _CenterImpurityRange;
    half _CenterImpurityIntensity;
    half4 _ImpurityColorDark;
    half4 _ImpurityColorBright;
    half _EmissionScale;
    
    float _HeightMapScale;
    float4 _HeightMapOffset;
    float _HeightRatio;

    float4 _BaseMap_ST;
    half4 _BaseColor;
    half _BaseColorBrightness;
    half _BaseColorSaturation;
    
    half _UseNormalMap;
    half _BumpScale;
    
    half _DebugMode;
CBUFFER_END

// ---------------------------------------------------------------------------
// 纹理采样器定义
// ---------------------------------------------------------------------------
TEXTURE2D(_BaseMap);            SAMPLER(sampler_BaseMap);
TEXTURE2D(_BumpMap);            SAMPLER(sampler_BumpMap);
TEXTURE2D(_ImpurityMap);        SAMPLER(sampler_ImpurityMap); // 杂质贴图

// ---------------------------------------------------------------------------
// 辅助函数：统一获取 Alpha 值
// ---------------------------------------------------------------------------
half GetAlpha(float2 uv)
{
    // 既然已经移除了 Alpha Clipping，这里直接返回 BaseColor 的 Alpha 即可
    // 或者如果需要保留某种逻辑，可以根据需求修改
    return _BaseColor.a;
}

// ---------------------------------------------------------------------------
// 辅助函数：执行 Alpha 裁剪
// ---------------------------------------------------------------------------
void DoAlphaClip(half alpha)
{
    // 已移除 Alpha Clipping
}

// ---------------------------------------------------------------------------
// 核心函数：初始化 SurfaceData
// ---------------------------------------------------------------------------
void InitializeSurfaceData(float2 uv, float3 viewDirTS, out SurfaceData outSurfaceData)
{
    outSurfaceData = (SurfaceData)0;

    // 1. 基础色 (Albedo)
    half4 albedoSample = SAMPLE_TEXTURE2D(_BaseMap, sampler_BaseMap, uv);
    half3 albedo = albedoSample.rgb * _BaseColor.rgb * _BaseColorBrightness;
    
    // 饱和度处理
    half luminance = dot(albedo, half3(0.2126h, 0.7152h, 0.0722h));
    outSurfaceData.albedo = lerp(luminance.xxx, albedo, _BaseColorSaturation);

    // 3. Alpha 计算与裁剪
    // 既然移除了 Alpha Clipping，这里不再需要复杂的 AlphaSource 判断
    outSurfaceData.alpha = _BaseColor.a;
    DoAlphaClip(outSurfaceData.alpha);
    
    // 裁剪后，为了避免混合问题，通常将 Alpha 设为 1 (对于不透明/Cutout物体)
    // 如果需要半透明效果，请注释掉下面这行
    outSurfaceData.alpha = 1.0h;

    // 4. 物理属性
    outSurfaceData.metallic = 0.9h; // 固定值
    outSurfaceData.specular = 0.0h; 
    
    // 光滑度
    outSurfaceData.smoothness = 0.4h; // 固定值
    
    // 环境光遮蔽
    outSurfaceData.occlusion = 1.0h; // 固定值

    // 5. 法线
#if defined(_NORMALMAP)
    half4 normalSample = SAMPLE_TEXTURE2D(_BumpMap, sampler_BumpMap, uv);
    outSurfaceData.normalTS = UnpackNormalScale(normalSample, _BumpScale);
#else
    outSurfaceData.normalTS = half3(0.0h, 0.0h, 1.0h);
#endif

    outSurfaceData.emission = 0.0h;
    
    // Graph: TexCoord[0] * Impurity Scale + Impurity Offset
    float2 baseUV = uv * _ImpurityScale.xy + _ImpurityOffset.xy;

    // 2. 获取切线空间视差向量 (对应图中左下角 Camera Vector -> TransformVector 逻辑)
    // viewDirTS 现在是标准的切线空间视线向量 (指向相机)
    float2 parallaxDir = viewDirTS.xy * -0.5; 

    // 3. 计算公共的基础偏移 UV (对应图中 VertexInterpolator + 内部杂质偏移)
    // Graph: BaseUV + Inner Impurity Offset
    float2 commonUV = baseUV + _InnerImpurityOffset.xy;

    // 4. 第一层采样
    // Graph: UV1 = CommonUV + ParallaxDir * ImpurityDepthInterval
    float2 layer1UV = commonUV + parallaxDir * _ImpurityDepthInterval;
    half4 layer1Color = SAMPLE_TEXTURE2D(_ImpurityMap, sampler_ImpurityMap, layer1UV);

    // 5. 第二层采样
    // Graph: UV2 = CommonUV + ParallaxDir * (ImpurityDepthOffset * 0.1)
    float2 layer2UV = commonUV + parallaxDir * (_ImpurityDepthOffset * 0.1);
    half4 layer2Color = SAMPLE_TEXTURE2D(_ImpurityMap, sampler_ImpurityMap, layer2UV);

    half3 doubleLayer1Color = (layer1Color * layer1Color).rgb;
    half3 doubleLayer2Color = (layer2Color * layer2Color).rgb;

    // 6. 混合计算
    // Graph: Multiply (RGB * RGB) -> 改为只取 B 通道 (.bbb) 以获得灰度结果
    // half3 mixedColor = doubleLayer1Color + doubleLayer2Color;

    // Graph: Add (B + B) -> Power -> Multiply
    half maskBase = doubleLayer1Color.b + doubleLayer2Color.b;
    
    half centerMask = pow(maskBase, _CenterImpurityRange) * _CenterImpurityIntensity;

    // 最终杂质颜色 (使用 Lerp 在暗部和亮部之间插值)
    // Graph: Lerp(DarkColor, BrightColor, Alpha=centerMask)
    half3 finalImpurity = lerp(_ImpurityColorDark.rgb, _ImpurityColorBright.rgb, saturate(centerMask));
    
    outSurfaceData.albedo += finalImpurity;

    // Bump Offset 
    // 1. UV Calculation
    // Graph: TexCoord[0] * Scale + Offset
    float2 bumpBaseUV = uv * _HeightMapScale + _HeightMapOffset.xy;

    // 2. BumpOffset (Parallax)
    // Height comes from T_Noise (ImpurityMap)
    // 注意：这里假设 ImpurityMap 的 R 通道包含高度信息
    half heightSample = SAMPLE_TEXTURE2D(_ImpurityMap, sampler_ImpurityMap, bumpBaseUV).r; 
    
    // UE BumpOffset 完整算法: UV + (Height - ReferencePlane) * HeightRatio * ViewDir
    // UE 默认 ReferencePlane 为 0.5
    half referencePlane = 0.5;
    float2 bumpParallaxUV = bumpBaseUV + (heightSample - referencePlane) * _HeightRatio * viewDirTS.xy;

    // 3. Texture Sample with Parallax UV
    half4 bumpTextureSample = SAMPLE_TEXTURE2D(_ImpurityMap, sampler_ImpurityMap, bumpParallaxUV);

    // Graph: Desaturation (Fraction 默认为 1，即完全去色)
    half bumpLuminance = dot(bumpTextureSample.rgb, half3(0.3, 0.59, 0.11)); 
    
    // 5. Multiply with Bright Color
    // Graph: Multiply
    half3 bumpOut = bumpLuminance * _ImpurityColorBright.rgb;

    // 混合到 Albedo
    outSurfaceData.albedo += bumpOut;

    // 7. 新的自发光计算
    // 使用 max(finalImpurity, bumpOut) * _EmissionScale
    outSurfaceData.emission = max(finalImpurity, bumpOut) * _EmissionScale;

#if defined(_DEBUG_MODE_ON)
    // [Debug 模式] 强制覆盖所有属性，只显示杂质颜色
    outSurfaceData.albedo     = 0;
    outSurfaceData.metallic   = 0;
    outSurfaceData.smoothness = 1;
    outSurfaceData.occlusion  = 1;
    outSurfaceData.specular   = 0;
    outSurfaceData.alpha      = 1;
    outSurfaceData.normalTS   = half3(0, 0, 1);
    
    // 输出最终计算的杂质颜色 (包含两部分)
    outSurfaceData.emission   = max(finalImpurity, bumpOut);
#endif
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
    DoAlphaClip(alpha);
    return alpha;
}

#endif
