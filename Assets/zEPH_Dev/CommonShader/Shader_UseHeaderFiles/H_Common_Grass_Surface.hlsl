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
    
    half _SmoothnessMin;
    half _SmoothnessMax;
    half _OcclusionStrength;
    half _EmissionStrength;
    
    half _UseNormalMap;
    half _BumpScale;
    
    half _AlphaClip;
    half _AlphaSource;
    half _Cutoff;
    
    float _WindIntensity;
    float _WindSpeed;
    float _WindWeightScale;
    float _WindWeightPower;
    
    // float3 _BoundsMin;
    // float3 _BoundsMax;
CBUFFER_END

// ---------------------------------------------------------------------------
// 纹理采样器定义
// ---------------------------------------------------------------------------
TEXTURE2D(_BaseMap);            SAMPLER(sampler_BaseMap);
TEXTURE2D(_BumpMap);            SAMPLER(sampler_BumpMap);
TEXTURE2D(_ORMAMap);             SAMPLER(sampler_ORMAMap);

// ---------------------------------------------------------------------------
// 辅助函数：统一获取 Alpha 值
// ---------------------------------------------------------------------------
half GetAlpha(float2 uv)
{
    half4 ormSample = SAMPLE_TEXTURE2D(_ORMAMap, sampler_ORMAMap, uv);
    
    half alpha;
    
    // 逻辑：根据 _AlphaSource 选择源
#if defined(_ALPHASOURCE_A)
    alpha = ormSample.a;
#else
    if (_AlphaSource > 0.5h)
        alpha = ormSample.a;
    else
        alpha = ormSample.b;
#endif

    return alpha * _BaseColor.a;
}

// ---------------------------------------------------------------------------
// 辅助函数：执行 Alpha 裁剪
// ---------------------------------------------------------------------------
void DoAlphaClip(half alpha)
{
#if defined(_ALPHATEST_ON)
    clip(alpha - _Cutoff);
#endif
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

    // 3. Alpha 计算与裁剪
    // 优化：直接使用已采样的 ormSample 计算 Alpha，避免重复采样
    half alpha;
#if defined(_ALPHASOURCE_A)
    alpha = ormSample.a;
#else
    if (_AlphaSource > 0.5h)
        alpha = ormSample.a;
    else
        alpha = ormSample.b;
#endif
    outSurfaceData.alpha = alpha * _BaseColor.a;
    DoAlphaClip(outSurfaceData.alpha);
    
    // 裁剪后，为了避免混合问题，通常将 Alpha 设为 1 (对于不透明/Cutout物体)
    // 如果需要半透明效果，请注释掉下面这行
    outSurfaceData.alpha = 1.0h;

    // 4. 物理属性
    outSurfaceData.metallic = 0.0h;
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
    outSurfaceData.emission = outSurfaceData.albedo * _EmissionStrength;
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

// ---------------------------------------------------------------------------
// 辅助函数：计算基于包围盒的 UVW
// ---------------------------------------------------------------------------
void BoundingBoxBasedUVW_float(float3 PositionOS, float3 BoundsMin, float3 BoundsMax, out float3 Out)
{
    float3 size = BoundsMax - BoundsMin;
    // Avoid division by zero
    size = max(size, 0.00001);
    Out = (PositionOS - BoundsMin) / size;
}

// ---------------------------------------------------------------------------
// 风动函数 (UE SimpleGrassWind 复刻 - 优化版)
// ---------------------------------------------------------------------------
float3 SimpleGrassWind(float3 positionWS, float intensity, float weight, float speed)
{
    // 1. 增加空间频率 (Spatial Frequency)
    // 之前是 * 0.5，导致波长很大(约12米)，看起来像整片草在动。
    // 改为 * 2.0 左右，波长约3米，草的运动会更细碎、独立。
    float phase = dot(positionWS.xz, float2(2.0, 1.3)); 

    // 2. 时间变量
    float t = _Time.y * speed;

    // 3. 计算波形
    // 使用 sin 和 cos 组合，让草做类似"画圈"的运动，而不是单纯的左右摆动。
    // 这样可以保持运动的连续性，不会出现"减速-停止-反向"的明显停顿感。
    float2 wave;
    wave.x = sin(t + phase);
    wave.y = cos(t * 0.85 + phase); // Z轴频率稍慢，产生非重复的李萨如(Lissajous)图形轨迹

    // 4. 添加高频扰动 (Detail Noise)
    // 模拟风吹过时的微小颤动
    float jitter = sin(t * 3.0 + phase * 5.0) * 0.15;
    wave += jitter;

    // 5. 应用强度和权重
    return float3(wave.x, 0, wave.y) * intensity * 0.05 * pow(abs(weight), _WindWeightPower) * _WindWeightScale;
}

#endif
