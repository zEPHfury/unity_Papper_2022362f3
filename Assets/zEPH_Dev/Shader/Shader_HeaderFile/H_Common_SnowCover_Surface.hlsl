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
    float4 _BaseMap_ST;
    half4 _BaseColor;
    half _BaseColorBrightness;
    half _BaseColorSaturation;
    
    half _Metallic;
    half _SmoothnessMin;
    half _SmoothnessMax;
    half _OcclusionStrength;
    
    half _UseNormalMap;
    half _BumpScale;
    
    half4 _SnowColor;
    float4 _SnowBaseMap_ST;
    half _SnowSmoothnessMin;
    half _SnowSmoothnessMax;
    half _SnowOcclusionStrength;
    half _SnowBumpScale;

    half _SnowPixelNormal;
    half4 _SnowDirection;
    half _SnowOffset;

    half _UseSparkle;
    half _SparkleScale;
    half _SparkleIntensity;
    half _SparkleThreshold;

    half _UseBakedSparkle;
    half4 _BakedSparkleColor;

    half _UseSnowVertexOffset;
    half _SnowLevel;
    half _SnowHeight;
CBUFFER_END

// ---------------------------------------------------------------------------
// 闪烁噪声函数 (Cellular/Voronoi based Sparkles)
// ---------------------------------------------------------------------------
float3 SparkleHash33(float3 p)
{
    p = frac(p * float3(0.1031, 0.1030, 0.0973));
    p += dot(p, p.yxz + 33.33);
    return frac((p.xxy + p.yxx) * p.zyx);
}

float SparkleNoise(float3 p, float3 viewDir, float3 normal, float scale, float3 seed)
{
    // 1. 基础网格坐标
    float3 gridP = p * scale;
    
    float3 i = floor(gridP);
    float3 f = frac(gridP);
    
    // 2. 获取随机哈希值
    float3 hash = SparkleHash33(i + seed);
    
    // 3. 随机密度控制：恢复到较合理的分布
    if (hash.y > 0.4) return 0.0; 
    
    // 4. 随机中心点偏移 (Jitter)
    float3 center = 0.1 + hash.xyz * 0.8; 
    
    // 5. 视角相关闪烁 (增强版)
    // 模拟晶体反射：使用视角方向与随机向量的对齐程度
    // 修改：让随机方向受法线影响，使闪烁点看起来附着在模型表面
    // 乘以 5.0 是为了扩大随机向量的范围，避免因范围过小导致在 NdotV 较大时出现明显的截断（规则条纹）
    float3 randomDir = normalize(normal + (hash - 0.5) * 5.0);
    // 降低幂次到 10.0，并增加基础可见度，让闪烁更频繁且更亮
    float viewFactor = pow(saturate(dot(randomDir, viewDir)), 10.0);
    
    // 6. 形状控制
    float dist = distance(f, center);
    // 让点更尖锐（更小但中心更亮），模拟极小的冰晶反射
    // 随机化点的大小，打破均一感
    float radius = 0.3 + hash.x * 0.2; 
    float dotShape = smoothstep(radius, 0.0, dist);
    
    // 7. 输出亮度：大幅提升倍率，使其能产生过曝感（触发 Bloom）
    // 增加亮度随机性
    return dotShape * viewFactor * (hash.z * 0.5 + 0.5) * 80.0; 
}

// ---------------------------------------------------------------------------
// 积雪辅助函数
// ---------------------------------------------------------------------------
void ApplySnowVertexOffset(inout float3 positionWS, float3 normalWS, out float snowFactor)
{
    // 1. 积雪覆盖因子 (控制颜色和材质混合)
    // 只要法线方向与积雪方向一致（dot > 0），就判定为有积雪覆盖
    // 使用 * 5.0 并 saturate 来实现边缘的平滑过渡
    snowFactor = saturate((dot(normalWS, _SnowDirection.xyz) - _SnowOffset) * 5.0);
    
    // 2. 顶点偏移 (控制积雪厚度)
    // 偏移量受 _SnowLevel (积雪程度) 和 _SnowHeight (积雪厚度) 共同控制
    // 当 _SnowLevel 为 0 时，没有偏移，但 snowFactor 依然有效，保持表面覆盖雪
#if defined(_SNOW_VERTEX_OFFSET)
    positionWS += _SnowDirection.xyz * _SnowHeight * _SnowLevel * snowFactor;
#endif
}

// ---------------------------------------------------------------------------
// 纹理采样器定义
// ---------------------------------------------------------------------------
TEXTURE2D(_BaseMap);            SAMPLER(sampler_BaseMap);
TEXTURE2D(_BumpMap);            SAMPLER(sampler_BumpMap);
TEXTURE2D(_ORMAMap);             SAMPLER(sampler_ORMAMap);

TEXTURE2D(_SnowBaseMap);        SAMPLER(sampler_SnowBaseMap);
TEXTURE2D(_SnowBumpMap);        SAMPLER(sampler_SnowBumpMap);
TEXTURE2D(_SnowORMAMap);        SAMPLER(sampler_SnowORMAMap);

// ---------------------------------------------------------------------------
// 辅助函数：统一获取 Alpha 值
// ---------------------------------------------------------------------------
half GetAlpha(float2 uv)
{
    return 1.0h;
}

// ---------------------------------------------------------------------------
// 辅助函数：执行 Alpha 裁剪
// ---------------------------------------------------------------------------
void DoAlphaClip(half alpha)
{
    // No alpha clipping
}

// ---------------------------------------------------------------------------
// 核心函数：初始化 SurfaceData
// ---------------------------------------------------------------------------
void InitializeSurfaceData(float2 uv, float3 normalWS, float4 tangentWS, inout float snowFactor, out SurfaceData outSurfaceData)
{
    outSurfaceData = (SurfaceData)0;

    // 1. 基础色 (Albedo)
    half4 albedoSample = SAMPLE_TEXTURE2D(_BaseMap, sampler_BaseMap, uv);
    half3 albedo = albedoSample.rgb * _BaseColor.rgb * _BaseColorBrightness;
    
    // 饱和度处理
    half luminance = dot(albedo, half3(0.2126h, 0.7152h, 0.0722h));
    albedo = lerp(luminance.xxx, albedo, _BaseColorSaturation);

    // 2. ORM 采样 (R=Occlusion, G=Smoothness, B=Metallic/Alpha)
    half4 ormSample = SAMPLE_TEXTURE2D(_ORMAMap, sampler_BaseMap, uv);

    // 3. Alpha 计算与裁剪
    // 优化：直接使用已采样的 ormSample 计算 Alpha，避免重复采样
    outSurfaceData.alpha = 1.0h;

    // 4. 物理属性
    half metallic = ormSample.b * _Metallic;
    
    // 光滑度重映射
    half smoothness = lerp(_SmoothnessMin, _SmoothnessMax, ormSample.g);
    
    // 环境光遮蔽
    half occlusion = lerp(1.0h, ormSample.r, _OcclusionStrength);

    // 5. 法线
    half3 normalTS;
#if defined(_NORMALMAP)
    half4 normalSample = SAMPLE_TEXTURE2D(_BumpMap, sampler_BumpMap, uv);
    normalTS = UnpackNormalScale(normalSample, _BumpScale);
#else
    normalTS = half3(0.0h, 0.0h, 1.0h);
#endif

    // -----------------------------------------------------------------------
    // Pixel Normal Snow Calculation
    // -----------------------------------------------------------------------
#if defined(_SNOW_PIXEL_NORMAL)
    // Reconstruct World Space Normal from Tangent Space Normal
    half3 bitangentWS = cross(normalWS, tangentWS.xyz) * tangentWS.w;
    half3x3 tangentToWorld = half3x3(tangentWS.xyz, bitangentWS, normalWS);
    half3 pixelNormalWS = TransformTangentToWorld(normalTS, tangentToWorld);
    pixelNormalWS = normalize(pixelNormalWS);
    
    // Recalculate Snow Factor using Pixel Normal
    // Logic matches ApplySnowVertexOffset: saturate(dot(N, Dir) * 5.0)
    snowFactor = saturate((dot(pixelNormalWS, _SnowDirection.xyz) - _SnowOffset) * 5.0);
#endif

    // 6. 自发光
    half3 emission = 0.0h;

    // 7. 积雪混合
    // 采样积雪贴图
    float2 snowUV = uv * _SnowBaseMap_ST.xy + _SnowBaseMap_ST.zw;
    half4 snowAlbedoSample = SAMPLE_TEXTURE2D(_SnowBaseMap, sampler_SnowBaseMap, snowUV);
    half4 snowORMSample = SAMPLE_TEXTURE2D(_SnowORMAMap, sampler_SnowORMAMap, snowUV);
    half4 snowNormalSample = SAMPLE_TEXTURE2D(_SnowBumpMap, sampler_SnowBumpMap, snowUV);
    half3 snowNormalTS = UnpackNormalScale(snowNormalSample, _SnowBumpScale);

    // 积雪物理属性计算
    half snowSmoothness = lerp(_SnowSmoothnessMin, _SnowSmoothnessMax, snowORMSample.g);
    half snowOcclusion = lerp(1.0h, snowORMSample.r, _SnowOcclusionStrength);

    // 混合基础材质与积雪材质
    outSurfaceData.albedo = lerp(albedo, snowAlbedoSample.rgb * _SnowColor.rgb, snowFactor);
    outSurfaceData.metallic = lerp(metallic, 0.0h, snowFactor); // 积雪金属度固定为 0
    outSurfaceData.smoothness = lerp(smoothness, snowSmoothness, snowFactor);
    outSurfaceData.occlusion = lerp(occlusion, snowOcclusion, snowFactor);
    outSurfaceData.normalTS = lerp(normalTS, snowNormalTS, snowFactor);
    outSurfaceData.emission = lerp(emission, 0.0h, snowFactor);
    outSurfaceData.specular = 0.0h;
}

// ---------------------------------------------------------------------------
// 兼容性函数：供 DepthNormalsPass 使用
// ---------------------------------------------------------------------------
half4 SampleAlbedoAlpha(float2 uv, TEXTURE2D_PARAM(albedoAlphaMap, sampler_albedoAlphaMap))
{
    half4 result = SAMPLE_TEXTURE2D(albedoAlphaMap, sampler_albedoAlphaMap, uv);
    // 强制替换 Alpha 以匹配我们的逻辑
    result.a = 1.0h;
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
    // DoAlphaClip(alpha);
    return alpha;
}

#endif
