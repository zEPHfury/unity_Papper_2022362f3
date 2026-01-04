Shader "zEPH/Pre-Integrated_Jade_Bak"
{
    Properties
    {
        [Header(Surface)]
        [Space(5)]
        [MainTexture] [NoScaleOffset] _BaseMap("Albedo", 2D) = "white" {}
        [MainColor] _BaseColor("Color", Color) = (1,1,1,1)
        _BaseColorBrightness("ColorBrightness", Range(0.0, 2.0)) = 1.0
        _BaseColorSaturation("ColorSaturation", Range(0.0, 2.0)) = 1.0
        _BaseColorContrast("ColorContrast", Range(0.0, 2.0)) = 1.0
        
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
        
        [Space(10)]
        [Header(Subsurface Scattering)]
        [Space(5)]
        [NoScaleOffset] _SkinLut("Pre-Integrated LUT", 2D) = "white" {}
        _CurvatureScale("Curvature Scale", Range(0.3, 1.5)) = 0.8
        _NormalSSSBlur("Normal Blur Strength", Range(0, 5)) = 2.6
        
        [Header(Transmission)]
        [Space(5)]
        _ThicknessRemap("Thickness Remap (Min, Max)", Vector) = (0, 1, 0, 0)
        // 对应代码中的 _ShapeParamsAndMaxScatterDists.rgb (即 1/d)
        // 修正默认值：(10,30,50) 太大了，导致默认全黑。改为 (3, 6, 10) 或更小，让光能透过来
        _ShapeParams("Shape Params (RGB = 1/ScatterDistance)", Vector) = (2, 5, 10, 1) 
        _WorldScale("World Scale", Float) = 0.1
        _TransmissionTint("Transmission Tint", Color) = (1,0.2,0.1,1)

        [Header(Fake Lighting)]
        [Space(5)]
        [NoScaleOffset] _FakeLightRamp("Fake Light Ramp", 2D) = "white" {}
        _FakeLightCenterBrightness("伪光照中心明暗", Float) = 1.0
        _FakeLightEdgeBrightness("伪光照首尾端明暗", Float) = 0.8
        _FakeLightCenterRangeOffset("伪光照中心范围偏移", Float) = 2.0

        [Header( Custom Specular)]
        [Space(5)]
        _SpecularEdgeHardness("高光边缘硬度", Range(0.0, 1.0)) = 0.9
        _SpecularRange("高光范围", Range(0.0, 9.0)) = 1.25
        _SpecularIntensity("高光强度", Float) = 1.0

        [Space(20)]
        [Header( Switches )]
        [Space(5)]
        [ToggleOff] _SpecularHighlights("Specular Highlights", Float) = 1.0
        [ToggleOff] _EnvironmentReflections("Environment Reflections", Float) = 1.0
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
            half _BaseColorContrast;
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
            
            half _FakeLightCenterBrightness;
            half _FakeLightEdgeBrightness;
            half _FakeLightCenterRangeOffset;

            half _SpecularEdgeHardness;
            half _SpecularRange;
            half _SpecularIntensity;
        CBUFFER_END

        TEXTURE2D(_BaseMap);            SAMPLER(sampler_BaseMap);
        TEXTURE2D(_FakeLightRamp);      SAMPLER(sampler_FakeLightRamp);
        TEXTURE2D(_BumpMap);            SAMPLER(sampler_BumpMap);
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
            #pragma multi_compile _ _ADDITIONAL_LIGHTS_VERTEX _ADDITIONAL_LIGHTS
            #pragma multi_compile _ _ADDITIONAL_LIGHT_SHADOWS
            #pragma multi_compile _ LIGHTMAP_ON
            #pragma shader_feature_local _SPECULARHIGHLIGHTS_OFF
            #pragma shader_feature_local _ENVIRONMENTREFLECTIONS_OFF
            
            // Includes and CBUFFER are now in HLSLINCLUDE

            struct Attributes
            {
                float4 positionOS   : POSITION;
                float3 normalOS     : NORMAL;
                float4 tangentOS    : TANGENT;
                float2 uv           : TEXCOORD0;
                float2 lightmapUV   : TEXCOORD1;
            };

            struct Varyings
            {
                float4 positionCS   : SV_POSITION;
                float3 positionWS   : TEXCOORD0;
                float3 normalWS     : TEXCOORD1;
                float4 tangentWS    : TEXCOORD3; // w stores sign
                float2 uv           : TEXCOORD4;
                float2 lightmapUV   : TEXCOORD5;
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

            half3 CalculateSkinLighting(
                Light light,
                half3 normalWS,
                half3 normalWS_Geo,
                half3 viewDirWS,
                half3 albedo,
                half curvature,
                half thickness,
                half smoothness,
                half ao,
                half3 f0
            )
            {
                half3 lightDir = light.direction;
                // light.shadowAttenuation is already computed in light.
                
                half NdotL = dot(normalWS, lightDir);
                half NdotL_Geo = dot(normalWS_Geo, lightDir);

                // SSS Diffuse
                float2 lutUV = float2(clamp(NdotL * 0.5 + 0.5, 0.01, 0.99), clamp(curvature, 0.01, 0.99));
                half3 lutColor = SAMPLE_TEXTURE2D_LOD(_SkinLut, sampler_SkinLut, lutUV, 0).rgb;

                // Shadow Relief
                float scatterWidth = clamp(curvature * 4.0, 0.15, 2.0); 
                float coreZone = scatterWidth * 0.5;
                float reliefWeight = 1.0 - smoothstep(coreZone, scatterWidth, abs(NdotL_Geo));
                
                // Effective Shadow for SSS
                half effectiveShadow = lerp(light.shadowAttenuation, 1.0, reliefWeight);
                
                half3 lightColor_Diffuse = light.color * light.distanceAttenuation * effectiveShadow;
                half3 diffR = albedo * lutColor * lightColor_Diffuse;

                // Transmission
                half3 diffT = 0;
                {
                    float3 backLight = CustomWrappedDiffuseLighting(-NdotL, 0.5) * light.color * light.distanceAttenuation;
                    backLight *= (1.0 - smoothstep(-0.2, 0.3, NdotL)); 
                    float thicknessInMillimeters = thickness * _WorldScale; 
                    float3 transmittance = ComputeTransmittanceDisney(_ShapeParams.rgb, _TransmissionTint.rgb * 0.25, thicknessInMillimeters);
                    diffT = backLight * transmittance * albedo;
                }

                // Specular
                half3 specular = 0;
                #ifndef _SPECULARHIGHLIGHTS_OFF
                {
                    // -----------------------------------------------------------
                    // UE 自定义高光实现 (优化版)
                    // -----------------------------------------------------------
                    
                    // 1. 向量准备 (强制 float 精度以保证高光中心计算稳定)
                    float3 viewDirFloat = float3(viewDirWS);
                    float3 halfDir = SafeNormalize(lightDir + viewDirFloat);
                    float NdotH = saturate(dot(float3(normalWS), halfDir));
                    
                    // 2. 粗糙度与中间变量
                    // 限制最小粗糙度，确保 a^2 >= 1e-12，防止分母过小导致黑斑
                    float ueRoughness = max(0.001, float(_SpecularRange) * 0.1);
                    float a = ueRoughness * ueRoughness;
                    
                    // 3. 高光分布计算 (GGX 变体)
                    // 使用 (1-x)(1+x) 计算 1-NdotH^2 以保持 NdotH 接近 1 时的精度
                    // 相比 1-NdotH*NdotH，这种写法在 NdotH~1 时能避免精度丢失
                    float OneMinusNoHSqr = (1.0 - NdotH) * (1.0 + NdotH);
                    float n = NdotH * a;
                    
                    // 分母 = (1-NdotH^2) + NdotH^2 * a^2
                    // 理论最小值 (当 NdotH=1 时) 为 a^2 >= 1e-12
                    float denom = OneMinusNoHSqr + n * n;
                    
                    // 计算 D 项，使用 max 保护防止除以 0 (虽然理论上不会发生)
                    float p = a / max(denom, 1e-12);
                    float d = p * p;
                    
                    // 4. 后处理
                    float customD = min(d, 2048.0);
                    
                    // 边缘硬度映射到 smoothstep 的 min 值
                    float edgeMin = clamp(float(_SpecularEdgeHardness), 0.0, 0.98);
                    float specularTerm = smoothstep(edgeMin, 0.99, customD);
                    
                    specularTerm = saturate(specularTerm);
                    specularTerm *= max(0.0, float(_SpecularIntensity));
                    
                    // 5. 最终合成
                    half3 lightColor_Specular = light.color * light.distanceAttenuation * light.shadowAttenuation;
                    specular = half3(specularTerm * lightColor_Specular * ao);
                }
                #endif
                
                return diffR + diffT + specular;
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
                output.lightmapUV = input.lightmapUV * unity_LightmapST.xy + unity_LightmapST.zw;
                return output;
            }

            // -------------------------------------------------------------------------
            // Fragment Shader
            // -------------------------------------------------------------------------
            half4 Frag(Varyings input) : SV_Target
            {
                // 1. 基础数据准备
                float3 viewDirWS = GetWorldSpaceNormalizeViewDir(input.positionWS);
                float3 normalWS_Geo = normalize(input.normalWS);
                float curvature = _CurvatureScale;

                // 3. 法线模糊 (Normal Blur)
                float blurLevel = curvature * _NormalSSSBlur;
                half4 packedNormal = SAMPLE_TEXTURE2D_LOD(_BumpMap, sampler_BumpMap, input.uv, blurLevel);
                float3 normalTS = UnpackNormalScale(packedNormal, _BumpScale);

                float3 tangentWS = normalize(input.tangentWS.xyz);
                float3 bitangentWS = cross(normalWS_Geo, tangentWS) * input.tangentWS.w;
                float3 normalWS = TransformTangentToWorld(normalTS, half3x3(tangentWS, bitangentWS, normalWS_Geo));
                normalWS = normalize(normalWS);

                // Albedo & ORMA
                half4 albedoSample = SAMPLE_TEXTURE2D(_BaseMap, sampler_BaseMap, input.uv);
                half3 albedoRGB = albedoSample.rgb * _BaseColor.rgb * _BaseColorBrightness;
                half luminance = dot(albedoRGB, half3(0.2126h, 0.7152h, 0.0722h));
                half4 albedo = half4(lerp(luminance.xxx, albedoRGB, _BaseColorSaturation), albedoSample.a * _BaseColor.a);
                
                // Apply Contrast
                albedo.rgb = (albedo.rgb - 0.5) * _BaseColorContrast + 0.5;

                half4 orma = SAMPLE_TEXTURE2D(_ORMAMap, sampler_ORMAMap, input.uv);
                half ao = lerp(1.0, orma.r, _OcclusionStrength);
                half smoothness = lerp(_SmoothnessMin, _SmoothnessMax, orma.g);
                half thickness = lerp(_ThicknessRemap.x, _ThicknessRemap.y, orma.b);

                // F0
                half3 f0 = half3(0.04, 0.04, 0.04);

                // -----------------------------------------------------------
                // 伪光照计算 (直接应用到 Albedo 颜色上)
                // -----------------------------------------------------------
                float4 shadowCoord = TransformWorldToShadowCoord(input.positionWS);
                Light mainLight = GetMainLight(shadowCoord);
                
                // 1. 计算法线与光照方向的点积 (NdotL)，范围 [-1, 1]
                float NdotL_Fake = dot(normalWS, mainLight.direction);
                
                // 2. 将 NdotL 映射到 [0, 1] 区间，作为采样 UV 的 U 坐标
                // -1 (背光) -> 0, 1 (受光) -> 1
                float fakeUV = NdotL_Fake * 0.5 + 0.5;
                
                // 3. 采样伪光照渐变贴图 (Ramp Texture)
                // 使用映射后的 UV 采样，通常这张图定义了光照随角度变化的衰减曲线
                half4 fakeRamp = SAMPLE_TEXTURE2D(_FakeLightRamp, sampler_FakeLightRamp, float2(fakeUV, 0.5));
                
                // 4. 计算伪光照强度项
                // 使用贴图的 R 通道作为权重，在 "中心亮度" 和 "边缘亮度" 之间插值
                // 当 fakeRamp.r 为 0 时使用 CenterBrightness，为 1 时使用 EdgeBrightness (取决于贴图绘制)
                half fakeLightTerm = lerp(_FakeLightCenterBrightness, _FakeLightEdgeBrightness, fakeRamp.r);
                
                // 5. 应用范围偏移 (Power 操作)
                // 控制光照衰减的对比度/锐利度
                fakeLightTerm = pow(fakeLightTerm, _FakeLightCenterRangeOffset);
                
                // 6. 将伪光照效果叠加到材质的基础颜色 (Albedo) 上
                // 这不是物理正确的光照，而是为了模拟某种风格化或次表面效果
                albedo.rgb *= fakeLightTerm;

                // 4. Lighting Calculation
                half3 finalColor = 0;

                // Main Light (Already fetched above)
                finalColor += CalculateSkinLighting(mainLight, normalWS, normalWS_Geo, viewDirWS, albedo.rgb, curvature, thickness, smoothness, ao, f0);

                // Additional Lights
                #ifdef _ADDITIONAL_LIGHTS
                    uint pixelLightCount = GetAdditionalLightsCount();
                    for (uint lightIndex = 0u; lightIndex < pixelLightCount; ++lightIndex)
                    {
                        Light light = GetAdditionalLight(lightIndex, input.positionWS); // Handles shadows if enabled
                        finalColor += CalculateSkinLighting(light, normalWS, normalWS_Geo, viewDirWS, albedo.rgb, curvature, thickness, smoothness, ao, f0);
                    }
                #endif

                // GI (Supports Area Light Baking via Lightmap or LightProbe)
                half3 bakedGI;
                #ifdef LIGHTMAP_ON
                    bakedGI = SampleLightmap(input.lightmapUV, normalWS);
                #else
                    bakedGI = SampleSH(normalWS);
                #endif
                
                half3 ambient = bakedGI * albedo.rgb * ao;
                
                // Indirect Specular (IBL)
                half3 envSpecular = 0;
                #ifndef _ENVIRONMENTREFLECTIONS_OFF
                {
                    half roughness = 1.0 - smoothness;
                    half3 reflectVector = reflect(-viewDirWS, normalWS);
                    half3 envColor = GlossyEnvironmentReflection(reflectVector, input.positionWS, roughness, ao);
                    half NdotV = saturate(dot(normalWS, viewDirWS));
                    half3 envFresnel = f0 + (max(half3(1.0 - roughness, 1.0 - roughness, 1.0 - roughness), f0) - f0) * pow(1.0 - NdotV, 5.0);
                    envSpecular = envColor * envFresnel;
                }
                #endif

                finalColor += ambient + envSpecular;

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