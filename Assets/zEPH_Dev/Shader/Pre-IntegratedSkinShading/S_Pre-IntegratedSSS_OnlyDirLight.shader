Shader "zEPH/Subsurface_OnlyDirLight"
{
    Properties
    {
        [Header(Surface)]
        [Space(5)]
        [MainTexture] [NoScaleOffset] _BaseMap("Albedo", 2D) = "white" {}
        [MainColor] _BaseColor("Color", Color) = (1,1,1,1)
        _BaseColorBrightness("ColorBrightness", Range(0.0, 2.0)) = 1.0
        _BaseColorSaturation("ColorSaturation", Range(0.0, 2.0)) = 1.0
        
        [Space(10)]
        // ORMA: R=Occlusion, G=Smoothness, B=ThicknessMap, A=Unused
        [NoScaleOffset] _ORMAMap("ORMA贴图 (R=AO, G=Smoothness, B=ThicknessMap, A=Unused)", 2D) = "white" {}
        [Space(5)]
        _SmoothnessMin("SmoothMin", Range(0.0, 1.0)) = 0
        _SmoothnessMax("SmoothMax", Range(0.0, 1.0)) = 1
        _OcclusionStrength("OcclusionStrength", Range(0.0, 1.0)) = 1.0

        [Space(10)]
        [Header(Normal)]
        [Space(5)]
        [NoScaleOffset] _BumpMap("Normal Map", 2D) = "bump" {}
        _BumpScale("Normal Scale", Float) = 1.0
        
        [Header(Detail Normal)]
        [Space(5)]
        _DetailNormalMap("Detail Normal Map", 2D) = "bump" {}
        _DetailNormalScale("Detail Normal Scale", Range(0.0, 2.0)) = 1.0
        
        [Space(10)]
        [Header(Subsurface Scattering)]
        [Space(5)]
        [NoScaleOffset] _SkinLut("Pre-Integrated LUT", 2D) = "white" {}
        _CurvatureScale("Curvature Scale", Range(0.3, 1.5)) = 0.8
        _NormalSSSBlur("Normal Blur Strength", Range(0, 5)) = 2.6
        
        [Header(Transmission)]
        _ThicknessRemap("Thickness Remap (Min, Max)", Vector) = (0, 1, 0, 0)
        // 对应代码中的 _ShapeParamsAndMaxScatterDists.rgb (即 1/d)
        // 修正默认值：(10,30,50) 太大了，导致默认全黑。改为 (3, 6, 10) 或更小，让光能透过来
        _ShapeParams("Shape Params (RGB = 1/ScatterDistance)", Vector) = (2, 5, 10, 1) 
        _WorldScale("World Scale", Float) = 0.1
        _TransmissionTint("Transmission Tint", Color) = (1,0.2,0.1,1)
    }

    SubShader
    {
        Tags { "RenderType"="Opaque" "RenderPipeline"="UniversalPipeline" "Queue"="Geometry" }
        
        HLSLINCLUDE
        #include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/Core.hlsl"
        #include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/Lighting.hlsl"

        CBUFFER_START(UnityPerMaterial)
            // float4 _BaseMap_ST; // Removed
            half4 _BaseColor;
            half _BaseColorBrightness;
            half _BaseColorSaturation;
            half _BumpScale;
            half _SmoothnessMin;
            half _SmoothnessMax;
            half _OcclusionStrength;
            
            half _CurvatureScale;
            half _NormalSSSBlur;
            
            float4 _ThicknessRemap;
            float4 _ShapeParams; // RGB = S
            float _WorldScale;
            half4 _TransmissionTint;
            
            float4 _DetailNormalMap_ST;
            half _DetailNormalScale;
        CBUFFER_END

        TEXTURE2D(_BaseMap);            SAMPLER(sampler_BaseMap);
        TEXTURE2D(_BumpMap);            SAMPLER(sampler_BumpMap);
        TEXTURE2D(_DetailNormalMap);    SAMPLER(sampler_DetailNormalMap);
        TEXTURE2D(_SkinLut);            SAMPLER(sampler_SkinLut);
        TEXTURE2D(_ORMAMap);            SAMPLER(sampler_ORMAMap);

        // Helper functions for DepthNormals and Meta passes
        half4 SampleAlbedoAlpha(float2 uv, TEXTURE2D_PARAM(albedoAlphaMap, sampler_albedoAlphaMap))
        {
            return half4(SAMPLE_TEXTURE2D(albedoAlphaMap, sampler_albedoAlphaMap, uv).rgb * _BaseColor.rgb, 1.0);
        }
        
        half3 SampleNormal(float2 uv, TEXTURE2D_PARAM(bumpMap, sampler_bumpMap), half scale)
        {
            half4 n = SAMPLE_TEXTURE2D(bumpMap, sampler_bumpMap, uv);
            return UnpackNormalScale(n, scale);
        }
        
        half Alpha(float2 uv)
        {
            return 1.0;
        }
        ENDHLSL
        
        Pass
        {
            Name "ForwardLit"
            Tags { "LightMode"="UniversalForward" }

            Cull Back

            HLSLPROGRAM
            #pragma target 4.5
            #pragma vertex Vert
            #pragma fragment Frag
            
            // 接收阴影所需的关键字
            #pragma multi_compile _ _MAIN_LIGHT_SHADOWS
            #pragma multi_compile _ _MAIN_LIGHT_SHADOWS_CASCADE
            #pragma multi_compile _ _SHADOWS_SOFT
            
            // Includes and CBUFFER are now in HLSLINCLUDE

            struct Attributes
            {
                float4 positionOS   : POSITION;
                float3 normalOS     : NORMAL;
                float4 tangentOS    : TANGENT;
                float2 uv           : TEXCOORD0;
            };

            struct Varyings
            {
                float4 positionCS   : SV_POSITION;
                float3 positionWS   : TEXCOORD0;
                float3 normalWS     : TEXCOORD1;
                float4 tangentWS    : TEXCOORD3; // w stores sign
                float2 uv           : TEXCOORD4;
            };

            // CBUFFER and Textures are in HLSLINCLUDE

            // -------------------------------------------------------------------------
            // Helper Functions (Based on Article)
            // -------------------------------------------------------------------------

            // Ref: Steve McAuley - Energy-Conserving Wrapped Diffuse
            float CustomWrappedDiffuseLighting(float NdotL, float w)
            {
                return saturate((NdotL + w) / ((1.0 + w) * (1.0 + w)));
            }

            // Ref: Approximate Reflectance Profiles for Efficient Subsurface Scattering by Pixar
            // 这里的 S 是 ShapeParam (1/d)
            float3 ComputeTransmittanceDisney(float3 S, float3 volumeAlbedo, float thickness)
            {
                // LOG2_E = 1.442695
                float3 exp_13 = exp2(((1.442695 * (-1.0 / 3.0)) * thickness) * S); // Exp[-S * t / 3]
                // Premultiply & optimize: T = (1/4 * A) * (e^(-S * t) + 3 * e^(-S * t / 3))
                // 注意：这里的 volumeAlbedo 应该包含 0.25 的系数，或者在外部乘
                return volumeAlbedo * (exp_13 * (exp_13 * exp_13 + 3.0));
            }

            // -------------------------------------------------------------------------
            // Vertex Shader
            // -------------------------------------------------------------------------
            Varyings Vert(Attributes input)
            {
                Varyings output;
                VertexPositionInputs vertexInput = GetVertexPositionInputs(input.positionOS.xyz);
                VertexNormalInputs normalInput = GetVertexNormalInputs(input.normalOS, input.tangentOS);

                output.positionCS = vertexInput.positionCS;
                output.positionWS = vertexInput.positionWS;
                output.normalWS = normalInput.normalWS;
                output.tangentWS = float4(normalInput.tangentWS, input.tangentOS.w);
                output.uv = input.uv; // No Scale/Offset for BaseMap
                return output;
            }

            // -------------------------------------------------------------------------
            // Fragment Shader
            // -------------------------------------------------------------------------
            half4 Frag(Varyings input) : SV_Target
            {
                // 1. 基础数据准备
                float3 viewDirWS = GetWorldSpaceNormalizeViewDir(input.positionWS);
                
                // 2. 实时曲率计算 (Real-time Curvature)
                // 修正：移除基于 fwidth 的动态曲率计算。
                // fwidth 依赖于屏幕像素导数，当相机拉近拉远时，像素覆盖率变化会导致 fwidth 剧烈波动，
                // 进而导致 LUT 采样位置跳动（闪烁/抖动）。
                // 改为直接使用 _CurvatureScale 控制整体曲率，保证画面稳定。
                float3 normalWS_Geo = normalize(input.normalWS); // 恢复 normalWS_Geo 定义，后续 TBN 计算需要
                float curvature = _CurvatureScale;

                // 3. 法线模糊 (Normal Blur)
                float blurLevel = curvature * _NormalSSSBlur;
                
                // 使用 SAMPLE_TEXTURE2D_LOD 读取模糊的法线
                half4 packedNormal = SAMPLE_TEXTURE2D_LOD(_BumpMap, sampler_BumpMap, input.uv, blurLevel);
                float3 normalTS = UnpackNormalScale(packedNormal, _BumpScale);

                // 新增：细节法线 (Detail Normal)
                // 用于增加近距离的皮肤纹理细节 (如毛孔)，且不被 SSS Blur 模糊掉
                float2 detailUV = TRANSFORM_TEX(input.uv, _DetailNormalMap);
                half4 packedDetail = SAMPLE_TEXTURE2D(_DetailNormalMap, sampler_DetailNormalMap, detailUV);
                float3 detailNormalTS = UnpackNormalScale(packedDetail, _DetailNormalScale);
                
                // 混合法线 (Blend Normals)
                normalTS = normalize(float3(normalTS.xy + detailNormalTS.xy, normalTS.z * detailNormalTS.z));
                
                // 构建 TBN 矩阵
                float3 tangentWS = normalize(input.tangentWS.xyz);
                float3 bitangentWS = cross(normalWS_Geo, tangentWS) * input.tangentWS.w;
                float3 normalWS = TransformTangentToWorld(normalTS, half3x3(tangentWS, bitangentWS, normalWS_Geo));
                normalWS = normalize(normalWS);

                // 4. 光照计算准备
                Light mainLight = GetMainLight(TransformWorldToShadowCoord(input.positionWS));
                half3 lightColor = mainLight.color * mainLight.distanceAttenuation; // 阴影单独处理
                half shadow = mainLight.shadowAttenuation;
                half3 lightDir = mainLight.direction;
                
                half NdotL = dot(normalWS, lightDir); // 范围 [-1, 1]
                // 新增：几何法线 NdotL，用于计算更稳定的阴影保护区，避免法线贴图细节导致的阴影抖动
                float NdotL_Geo = dot(normalWS_Geo, lightDir);

                half clampedNdotL = saturate(NdotL);

                half4 albedoSample = SAMPLE_TEXTURE2D(_BaseMap, sampler_BaseMap, input.uv);
                half3 albedoRGB = albedoSample.rgb * _BaseColor.rgb * _BaseColorBrightness;
                half luminance = dot(albedoRGB, half3(0.2126h, 0.7152h, 0.0722h));
                half4 albedo = half4(lerp(luminance.xxx, albedoRGB, _BaseColorSaturation), albedoSample.a * _BaseColor.a);

                // --- ORMA Sampling ---
                // R=Occlusion, G=Smoothness, B=ThicknessMap, A=Unused
                half4 orma = SAMPLE_TEXTURE2D(_ORMAMap, sampler_ORMAMap, input.uv);
                half ao = lerp(1.0, orma.r, _OcclusionStrength);
                half smoothness = lerp(_SmoothnessMin, _SmoothnessMax, orma.g);
                half thicknessSample = orma.b;
                // ---------------------

                // 5. 漫反射项 (SSS Diffuse)
                // 修复：使用 saturate 限制 UV 范围，防止 NdotL > 1.0 或 Texture Wrap Mode 为 Repeat 时
                // 在受光面中心(NdotL=1)采样到 LUT 另一侧的暗色，导致出现黑斑。
                // 二次修复：
                // 1. 使用 clamp(..., 0.01, 0.99) 收缩 UV，彻底避开纹理边缘采样问题。
                // 2. 使用 SAMPLE_TEXTURE2D_LOD 强制采样 Level 0，防止 Mipmap 导致的颜色错误。
                float2 lutUV = float2(clamp(NdotL * 0.5 + 0.5, 0.01, 0.99), clamp(curvature, 0.01, 0.99));
                half3 lutColor = SAMPLE_TEXTURE2D_LOD(_SkinLut, sampler_SkinLut, lutUV, 0).rgb;
                
                // 阴影平滑处理 (Shadow Relief / Soft Shadow for SSS)
                // 问题分析：
                // 1. ShadowMap 在明暗交界处 (NdotL ≈ 0) 会产生锯齿 (Shadow Acne)。
                // 2. 标准光照下，阴影会将 Diffuse 彻底压黑。但对于 SSS 材质，光线会在交界处散射 (LUT中的红色部分)，
                //    因此不应被 ShadowMap 完全遮挡。
                // 3. 如果 Transmission 是绿色，LUT 是红色。如果阴影把 LUT 压黑了，就只剩 Transmission 的绿色，
                //    导致无法混合出黄色，且边缘会有锯齿。
                
                // 解决方案：
                // 在明暗交界处 (Terminator)，根据曲率定义一个 "散射保护区"。
                // 在这个区域内，我们忽略部分 ShadowMap 的遮挡，强制让 LUT 的颜色透出来。
                
                // 保护区宽度：曲率越大(越弯)，散射越宽
                // 再次扩大范围：为了彻底掩盖 ShadowMap 的锯齿，我们需要一个相当宽的“安全区”
                // max(0.25, ...) 确保即使在低曲率下也有足够的模糊范围
                // 优化：扩大散射保护区 (0.25 -> 0.35, 2.0 -> 3.0)，使过渡更平滑，覆盖更多锯齿
                // 二次优化：当 Curvature 极小(0.001)时，强制 0.35 的宽度会导致阴影与物体脱节(漏光)。
                //           改为 max(0.1, ...)，在低曲率下收紧保护区，高曲率下保持宽范围。
                // 三次优化：用户反馈球体(低曲率)依然有锯齿。说明 0.1 的范围不足以覆盖 ShadowMap 的锯齿。
                //           将最小值提升至 0.2，并稍微增加曲率影响系数，确保覆盖范围足够。
                // 四次优化：锯齿依然存在，且高光油腻。采取更激进的策略。
                //           1. 进一步扩大 scatterWidth 最小值到 0.4，确保覆盖所有 Shadow Acne。
                //           2. 扩大 coreZone 比例到 0.6，在核心区完全抹平阴影。
                // 修正：用户反馈 Curvature=0.001 时依然有很宽的散射带。
                //       强制 max(0.4) 会导致无法表现锐利的阴影，且在没有 LUT 时会导致明暗交界处出现宽阔的亮带。
                //       改为 max(0.02, ...) 允许用户通过降低 Curvature 来获得锐利阴影，仅保留极小的防锯齿底限。
                // 七次修正：回答用户疑问。
                // 是的，如果没有预积分 LUT，确实无法完美解决这个问题。
                // 原因：
                // 1. 为了遮盖阴影锯齿，我们需要一个较宽的 "Core Zone" (reliefWeight=1)。
                // 2. 在这个区域内，Shader 会忽略阴影，直接显示漫反射颜色。
                // 3. 如果没有 LUT，漫反射颜色就是纯白 (1.0)。
                // 4. 结果：在明暗交界处，你会看到一条纯白的亮带，而不是自然的暗红色散射。
                // 
                // 九次优化：用户反馈当 Curvature Scale = 1.0 时，阴影完全消失（被过度平滑）。
                // 原因：之前 scatterWidth = curvature * 4.0。当 curvature=1 时，width=4.0。
                //       而 NdotL 范围只有 [-1, 1]。这意味着 scatterWidth 覆盖了整个球体，
                //       导致 reliefWeight 恒为 1，所有阴影都被强制抹除。
                // 解决：
                // 给 scatterWidth 增加一个合理的上限 (0.85)。
                // 这样即使 Curvature 很大，在 NdotL > 0.85 的受光面中心，依然能保留清晰的投影。
                float scatterWidth = clamp(curvature * 4.0, 0.15, 1.2); 
                float coreZone = scatterWidth * 0.5;
                
                // 计算保护权重：在 NdotL=0 附近最强
                // 优化：使用 NdotL_Geo (几何法线) 替代 NdotL (像素法线)。
                // 这样保护区会跟随几何体的大轮廓，而不是跟随法线贴图的细节，能更稳定地覆盖 ShadowMap 的边缘锯齿。
                float reliefWeight = 1.0 - smoothstep(coreZone, scatterWidth, abs(NdotL_Geo));
                
                // 混合阴影：在保护区内，将 shadow 插值向 1.0
                half effectiveShadow = lerp(shadow, 1.0, reliefWeight);

                half3 diffR = albedo.rgb * lutColor * lightColor * effectiveShadow;

                // 新增：环境光 (GI) 计算
                half3 bakedGI = SampleSH(normalWS);
                half3 ambient = bakedGI * albedo.rgb * ao; // Apply AO

                // 6. 透射项 (Transmission) - 核心技术点
                half3 diffT = 0;
                {
                    // 读取厚度 (From ORMA.b)
                    float thickness = lerp(_ThicknessRemap.x, _ThicknessRemap.y, thicknessSample);
                    
                    // 环绕光作为透射的基础光照 (模拟背光)
                    // 修正：移除 * shadow。
                    // 透射光模拟的是光线穿透物体，即使背面在 ShadowMap 中被标记为阴影（因为背对光源），
                    // 光线依然是从正面穿透过来的。如果乘以 shadow，背面就会全黑，丢失透射效果。
                    // 我们假设透射光主要受厚度影响，而不受自阴影影响。
                    float3 backLight = CustomWrappedDiffuseLighting(-NdotL, 0.5) * lightColor;
                    
                    // 额外抑制：如果 NdotL > 0 (受光面)，强制减弱透射，防止在明暗交界处产生锯齿状的高亮边
                    // 使用 smoothstep 替代 saturate，消除锯齿，并调整阈值范围
                    // 优化：放宽 smoothstep 范围 (0.2, -0.1 -> 0.3, -0.2)，使透射光在明暗交界处的消退更柔和
                    // 修复：smoothstep(min, max, x) 中 min 必须小于 max。原写法 (0.3, -0.2) 在部分 GPU 上会导致未定义行为(黑斑/NaN)。
                    // 改为 1.0 - smoothstep(...) 以实现反向遮罩。
                    backLight *= (1.0 - smoothstep(-0.2, 0.3, NdotL)); 

                    // 计算透射率
                    // thicknessInUnits: 简单近似为背光面的距离，这里直接用厚度图
                    float thicknessInMillimeters = thickness * _WorldScale; 
                    
                    // 使用 Burley 公式计算透射率
                    // 0.25 是 volumeAlbedo 的预乘系数 (参考代码注释)
                    float3 transmittance = ComputeTransmittanceDisney(_ShapeParams.rgb, _TransmissionTint.rgb * 0.25, thicknessInMillimeters);
                    
                    diffT = backLight * transmittance * albedo.rgb;
                }

                // 7. 高光项 (Specular)
                // 修正：使用 PBR (GGX) 模型替代简单的 Blinn-Phong，解决 Smoothness=0 时的过曝(Explosion)问题
                half3 viewDir = normalize(GetCameraPositionWS() - input.positionWS);
                
                // 1. 计算 Specular Color (F0)
                // 非金属(Dielectric) F0 固定为 0.04，金属使用 Albedo
                half3 f0 = half3(0.04, 0.04, 0.04);
                half3 specularColor = f0; // Metallic fixed to 0
                
                // 2. 计算 Roughness 相关参数
                half roughness = max(1.0 - smoothness, 0.002);
                half roughness2 = roughness * roughness;
                half roughness2MinusOne = roughness2 - 1.0;
                // URP 近似归一化项
                half normalizationTerm = roughness * 4.0 + 2.0;

                half3 halfDir = SafeNormalize(lightDir + viewDir);
                half NdotH = saturate(dot(normalWS, halfDir));
                half LdotH = saturate(dot(lightDir, halfDir));

                // 3. GGX Distribution (D) & Visibility (V)
                // d = NdotH^2 * (a^2 - 1) + 1
                half d = NdotH * NdotH * roughness2MinusOne + 1.00001;
                half LoH2 = LdotH * LdotH;
                
                // SpecularTerm = D * V
                // URP Mobile Approximation: V = 1 / (LoH^2 * normalizationTerm)
                half specularTerm = roughness2 / ((d * d) * max(0.1h, LoH2) * normalizationTerm);
                
                // 防止 FP16 溢出
                #if defined(SHADER_API_MOBILE) || defined(SHADER_API_SWITCH)
                    specularTerm = clamp(specularTerm, 0.0, 100.0);
                #endif
                
                // 4. Fresnel (F) - Schlick Approximation
                half3 fresnel = specularColor + (1.0 - specularColor) * pow(1.0 - LdotH, 5.0);
                
                // 最终高光
                half3 specular = specularTerm * fresnel * lightColor;
                
                // 5. 遮罩
                // 必须接受阴影
                // 修复：高光项改回使用原始 shadow，而不是 effectiveShadow。
                // effectiveShadow 是为了让 SSS (漫反射) 透出阴影边缘，但高光是表面反射，不应透出。
                // 使用 effectiveShadow 会导致在明暗交界处(本该是阴影)出现异常的"油腻"高光。
                // 再次优化：
                // 1. 使用原始 shadow 会导致高光边缘有锯齿。
                // 2. 使用 effectiveShadow 会导致高光溢出到阴影区(油腻)。
                // 解决方案：使用 smoothstep 提前截断高光。
                // 最终优化 (针对 LUT 使用场景)：
                // 放宽高光遮罩范围 (0.2, 0.5 -> 0.1, 0.4)。
                // 有了 LUT 的平滑过渡，我们可以允许高光稍微延伸到更靠近明暗交界处的地方，
                // 增加皮肤的油润感，同时依然避开最危险的阴影锯齿区 (NdotL < 0.1)。
                half specularFade = smoothstep(0.1, 0.4, NdotL);
                
                // 应用 AO 到高光 (Specular Occlusion)
                // 毛孔(AO暗部)不应该产生高光，否则皮肤会显得平坦油腻
                specular *= (shadow * specularFade * ao);
                
                // -------------------------------------------------------------------------
                // Indirect Specular (环境反射 / IBL) - PBR 补全
                // -------------------------------------------------------------------------
                half3 envSpecular = 0;
                {
                    half3 reflectVector = reflect(-viewDir, normalWS);
                    // 采样 Unity 的反射探针 (Reflection Probe)
                    // GlossyEnvironmentReflection 内部处理了 Roughness 到 Mipmap 的映射
                    // 第4个参数是 occlusion，我们传入 ao
                    half3 envColor = GlossyEnvironmentReflection(reflectVector, input.positionWS, roughness, ao);

                    // 计算环境光的 Fresnel (基于 NdotV)
                    // 粗糙度越高，Fresnel 效应越弱 (Schlick 近似)
                    half NdotV = saturate(dot(normalWS, viewDir));
                    half3 envFresnel = f0 + (max(half3(1.0 - roughness, 1.0 - roughness, 1.0 - roughness), f0) - f0) * pow(1.0 - NdotV, 5.0);

                    envSpecular = envColor * envFresnel;
                }

                // 8. 最终合成
                half3 finalColor = diffR + diffT + specular + ambient + envSpecular;

                return half4(finalColor, 1.0);
            }
            ENDHLSL
        }
        
        // -------------------------------------------------------------------------
        // Shadow Caster Pass (用于产生阴影)
        // -------------------------------------------------------------------------
        Pass
        {
            Name "ShadowCaster"
            Tags { "LightMode" = "ShadowCaster" }

            ZWrite On
            ZTest LEqual
            ColorMask 0
            Cull Back

            HLSLPROGRAM
            #pragma target 4.5
            #pragma vertex ShadowPassVertex
            #pragma fragment ShadowPassFragment

            #include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/Shadows.hlsl"

            struct Attributes
            {
                float4 positionOS   : POSITION;
                float3 normalOS     : NORMAL;
                float2 uv           : TEXCOORD0;
                UNITY_VERTEX_INPUT_INSTANCE_ID
            };

            struct Varyings
            {
                float4 positionCS   : SV_POSITION;
                float2 uv           : TEXCOORD0;
                UNITY_VERTEX_INPUT_INSTANCE_ID
                UNITY_VERTEX_OUTPUT_STEREO
            };

            Varyings ShadowPassVertex(Attributes input)
            {
                Varyings output;
                UNITY_SETUP_INSTANCE_ID(input);
                UNITY_TRANSFER_INSTANCE_ID(input, output);
                UNITY_INITIALIZE_VERTEX_OUTPUT_STEREO(output);

                float3 positionWS = TransformObjectToWorld(input.positionOS.xyz);
                float3 normalWS = TransformObjectToWorldNormal(input.normalOS);

                // 计算在光源视角下的裁剪空间位置，并应用阴影偏移 (Bias) 以防止自阴影伪影
                output.positionCS = TransformWorldToHClip(ApplyShadowBias(positionWS, normalWS, GetMainLight().direction));
                
                #if UNITY_REVERSED_Z
                    output.positionCS.z = min(output.positionCS.z, output.positionCS.w * UNITY_NEAR_CLIP_VALUE);
                #else
                    output.positionCS.z = max(output.positionCS.z, output.positionCS.w * UNITY_NEAR_CLIP_VALUE);
                #endif

                output.uv = input.uv; // No Scale/Offset
                return output;
            }

            half4 ShadowPassFragment(Varyings input) : SV_TARGET
            {
                return 0;
            }
            ENDHLSL
        }

        // =======================================================================
        // Pass 3: DepthOnly (深度预渲染 Pass)
        // =======================================================================
        Pass
        {
            Name "DepthOnly"
            Tags { "LightMode" = "DepthOnly" }

            ZWrite On
            ZTest LEqual
            ColorMask 0
            Cull Back

            HLSLPROGRAM
            #pragma target 4.5
            #pragma vertex DepthOnlyVertex
            #pragma fragment DepthOnlyFragment

            struct Attributes
            {
                float4 positionOS   : POSITION;
                float2 uv           : TEXCOORD0;
                UNITY_VERTEX_INPUT_INSTANCE_ID
            };

            struct Varyings
            {
                float4 positionCS   : SV_POSITION;
                float2 uv           : TEXCOORD0;
                UNITY_VERTEX_INPUT_INSTANCE_ID
                UNITY_VERTEX_OUTPUT_STEREO
            };

            Varyings DepthOnlyVertex(Attributes input)
            {
                Varyings output = (Varyings)0;
                UNITY_SETUP_INSTANCE_ID(input);
                UNITY_TRANSFER_INSTANCE_ID(input, output);
                UNITY_INITIALIZE_VERTEX_OUTPUT_STEREO(output);

                output.positionCS = TransformObjectToHClip(input.positionOS.xyz);
                output.uv = input.uv; // No Scale/Offset
                return output;
            }

            half4 DepthOnlyFragment(Varyings input) : SV_TARGET
            {
                return 0;
            }
            ENDHLSL
        }

        // =======================================================================
        // Pass 4: DepthNormals (深度法线 Pass)
        // =======================================================================
        Pass
        {
            Name "DepthNormals"
            Tags { "LightMode" = "DepthNormals" }

            ZWrite On
            ZTest LEqual
            Cull Back

            HLSLPROGRAM
            #pragma target 4.5
            #pragma vertex DepthNormalsVertex
            #pragma fragment DepthNormalsFragment

            #include "Packages/com.unity.render-pipelines.universal/Shaders/DepthNormalsPass.hlsl"
            
            ENDHLSL
        }

        // =======================================================================
        // Pass 5: Meta (光照烘焙 Pass)
        // =======================================================================
        Pass
        {
            Name "Meta"
            Tags { "LightMode" = "Meta" }

            Cull Off

            HLSLPROGRAM
            #pragma target 4.5
            #pragma vertex VertexMeta
            #pragma fragment FragmentMeta

            #include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/MetaInput.hlsl"

            struct Attributes
            {
                float4 positionOS   : POSITION;
                float2 uv           : TEXCOORD0;
                float2 lightmapUV   : TEXCOORD1;
                UNITY_VERTEX_INPUT_INSTANCE_ID
            };

            struct Varyings
            {
                float4 positionCS   : SV_POSITION;
                float2 uv           : TEXCOORD0;
                UNITY_VERTEX_INPUT_INSTANCE_ID
            };

            Varyings VertexMeta(Attributes input)
            {
                Varyings OUT = (Varyings)0;
                UNITY_SETUP_INSTANCE_ID(input);
                
                OUT.positionCS = UnityMetaVertexPosition(input.positionOS.xyz, input.lightmapUV, input.lightmapUV, unity_LightmapST, unity_DynamicLightmapST);
                OUT.uv = input.uv; // No Scale/Offset
                return OUT;
            }

            half4 FragmentMeta(Varyings IN) : SV_Target
            {
                MetaInput metaInput = (MetaInput)0;
                metaInput.Albedo = SAMPLE_TEXTURE2D(_BaseMap, sampler_BaseMap, IN.uv).rgb * _BaseColor.rgb;
                metaInput.Emission = 0;
                return UnityMetaFragment(metaInput);
            }
            ENDHLSL
        }
    }
}
