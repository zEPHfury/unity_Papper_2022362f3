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

    half _UseSparkle;
    half _SparkleScale;
    half _SparkleIntensity;
    half _SparkleThreshold;

    half _UseBakedSparkle;
    half4 _BakedSparkleColor;
    
    half _ZWrite; // Added this as it was in the shader properties but missing here or just to be safe
CBUFFER_END

// ---------------------------------------------------------------------------
// 纹理采样器定义
// ---------------------------------------------------------------------------
TEXTURE2D(_BaseMap);            SAMPLER(sampler_BaseMap);
TEXTURE2D(_BumpMap);            SAMPLER(sampler_BumpMap);
TEXTURE2D(_ORMAMap);             SAMPLER(sampler_ORMAMap);

// ---------------------------------------------------------------------------
// 闪烁噪声函数 (Cellular/Voronoi based Sparkles)
// ---------------------------------------------------------------------------
float3 SparkleHash33(float3 p)
{
    p = frac(p * float3(0.1031, 0.1030, 0.0973));
    p += dot(p, p.yxz + 33.33);
    return frac((p.xxy + p.yxx) * p.zyx);
}

float SparkleNoise(float3 p, float3 viewDir, float scale, float3 seed)
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
    float3 randomDir = normalize(hash - 0.5);
    // 降低幂次到 10.0，并增加基础可见度，让闪烁更频繁且更亮
    float viewFactor = pow(saturate(dot(randomDir, viewDir)), 10.0);
    
    // 6. 形状控制
    float dist = distance(f, center);
    // 让点更尖锐（更小但中心更亮），模拟极小的冰晶反射
    float dotShape = smoothstep(0.4, 0.0, dist);
    
    // 7. 输出亮度：大幅提升倍率，使其能产生过曝感（触发 Bloom）
    return dotShape * viewFactor * (hash.z + 0.2) * 80.0; 
}

// ---------------------------------------------------------------------------
// 核心函数：初始化 SurfaceData
// ---------------------------------------------------------------------------
void InitializeSurfaceData(float2 uv, out SurfaceData outSurfaceData)
{
    outSurfaceData = (SurfaceData)0;

    // 1. 基础色 (Albedo)
    half4 albedoSample = SAMPLE_TEXTURE2D(_BaseMap, sampler_BaseMap, uv);
    half3 albedo = albedoSample.rgb * _BaseColor.rgb * _BaseColorBrightness;
    
    // 饱和度处理
    half luminance = dot(albedo, half3(0.2126h, 0.7152h, 0.0722h));
    outSurfaceData.albedo = lerp(luminance.xxx, albedo, _BaseColorSaturation);

    // 2. ORM 采样 (R=Occlusion, G=Smoothness, B=Metallic/Alpha)
    half4 ormSample = SAMPLE_TEXTURE2D(_ORMAMap, sampler_BaseMap, uv);

    // 3. Alpha 计算
    outSurfaceData.alpha = 1.0h;

    // 4. 物理属性
    outSurfaceData.metallic = ormSample.b * _Metallic;
    outSurfaceData.specular = 0.0h; // 绝缘体 specular 默认为 0，金属由 metallic 控制
    
    // 光滑度重映射
    outSurfaceData.smoothness = lerp(_SmoothnessMin, _SmoothnessMax, ormSample.g);
    
    // 环境光遮蔽
    outSurfaceData.occlusion = lerp(1.0h, ormSample.r, _OcclusionStrength);

    // 5. 法线
#if defined(_NORMALMAP)
    half4 normalSample = SAMPLE_TEXTURE2D(_BumpMap, sampler_BumpMap, uv);
    outSurfaceData.normalTS = UnpackNormalScale(normalSample, _BumpScale);
#else
    outSurfaceData.normalTS = half3(0.0h, 0.0h, 1.0h);
#endif

    // 6. 自发光
    outSurfaceData.emission = 0.0h;
}

// ---------------------------------------------------------------------------
// 兼容性函数：供 DepthNormalsPass 使用
// ---------------------------------------------------------------------------
half4 SampleAlbedoAlpha(float2 uv, TEXTURE2D_PARAM(albedoAlphaMap, sampler_albedoAlphaMap))
{
    half4 result = SAMPLE_TEXTURE2D(albedoAlphaMap, sampler_albedoAlphaMap, uv);
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
    return 1.0h;
}

#endif
