Shader "Custom/Common Hair"
{
    Properties
    {
        [Header(Base Textures)]
        _BaseMap("基础颜色 (A: 透明度)", 2D) = "white" {}
        _DepthMap("深度图 (AO)", 2D) = "white" {}
        _IDMap("ID图 (差异变化)", 2D) = "white" {}
        _RootMap("发根图 (根部到梢部)", 2D) = "white" {}
        
        [Header(Specular 1 (Primary))]
        _SpecularColor1("高光颜色", Color) = (0.4, 0.4, 0.4, 1)
        _SpecularExponent1("高光指数", Range(1, 1024)) = 100
        _SpecularShift1("偏移", Range(-1, 1)) = 0
        
        [Header(Specular 2 (Secondary))]
        _SpecularColor2("高光颜色", Color) = (0.25, 0.25, 0.25, 1)
        _SpecularExponent2("高光指数", Range(1, 512)) = 50
        _SpecularShift2("偏移", Range(-1, 1)) = 0.1
        
        [Header(Specular Settings)]
        _ShiftMap("偏移图 (R通道)", 2D) = "black" {}
        _ShiftScale("偏移缩放", Range(-1, 1)) = 0.1
        
        [Header(Lighting and Variation)]
        _RootColor("发根变化", Color) = (0.5, 0.5, 0.5, 1)
        _TipColor("发梢变化", Color) = (1, 1, 1, 1)
        _IDVariation("ID颜色变化", Range(0, 1)) = 0.2
        
        [Header(Sphere Normal Trick)]
        _HeadCenter("头部中心 (世界空间)", Vector) = (0, 0, 0, 0)
        _SphereNormalSmoothness("球形法线平滑度", Range(0, 1)) = 0.5

        [Header(ID Tangent Perturbation)]
        _TangentA("切线 A (偏移)", Vector) = (0, 0, 0.15, 0)
        _TangentB("切线 B (偏移)", Vector) = (0, 0, -0.15, 0)

        [Header(Transmission (TT))]
        _TransmissionColor("透射颜色", Color) = (1, 1, 1, 1)
        _TransmissionIntensity("透射强度", Range(0, 5)) = 0.1
        _TransmissionExponent("透射指数", Range(1, 128)) = 20

        [Header(Rendering)]
        _Cutoff("Alpha 裁剪 (核心)", Range(0, 1)) = 0.65
        _EdgeSoftness("边缘柔和度", Range(0, 1)) = 0.5
        [Enum(UnityEngine.Rendering.CullMode)] _Cull("剔除模式", Float) = 0
    }

    SubShader
    {
        Tags { "RenderType"="TransparentCutout" "Queue"="AlphaTest" "RenderPipeline" = "UniversalPipeline" }
        LOD 100
        Cull [_Cull]

        Pass
        {
            Name "ForwardLit_Cutout"
            Tags { "LightMode" = "UniversalForward" }

            ZWrite On
            Cull [_Cull]

            HLSLPROGRAM
            #pragma vertex vert
            #pragma fragment frag
            
            // URP Keywords
            #pragma multi_compile _ _MAIN_LIGHT_SHADOWS _MAIN_LIGHT_SHADOWS_CASCADE
            #pragma multi_compile _ _ADDITIONAL_LIGHTS_VERTEX _ADDITIONAL_LIGHTS
            #pragma multi_compile_fragment _ _ADDITIONAL_LIGHT_SHADOWS
            #pragma multi_compile_fragment _ _SHADOWS_SOFT
            #pragma multi_compile_fog
            #pragma multi_compile _ LIGHTMAP_ON

            #include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/Core.hlsl"
            #include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/Lighting.hlsl"

            struct Attributes
            {
                float4 positionOS : POSITION;
                float2 uv : TEXCOORD0;
                float3 normalOS : NORMAL;
                float4 tangentOS : TANGENT;
                float2 lightmapUV : TEXCOORD1;
            };

            struct Varyings
            {
                float4 positionCS : SV_POSITION;
                float2 uv : TEXCOORD0;
                float3 normalWS : TEXCOORD1;
                float3 tangentWS : TEXCOORD3;
                float3 bitangentWS : TEXCOORD4;
                float3 viewDirWS : TEXCOORD5;
                float3 positionWS : TEXCOORD6;
                float4 shadowCoord : TEXCOORD7;
                float fogFactor : TEXCOORD8;
                DECLARE_LIGHTMAP_OR_SH(lightmapUV, vertexSH, 9);
            };

            CBUFFER_START(UnityPerMaterial)
            float4 _BaseMap_ST;
            float4 _SpecularColor1;
            float _SpecularExponent1;
            float _SpecularShift1;
            float4 _SpecularColor2;
            float _SpecularExponent2;
            float _SpecularShift2;
            float _ShiftScale;
            float _Cutoff;
            float _EdgeSoftness;
            float4 _RootColor;
            float4 _TipColor;
            float _IDVariation;
            float4 _HeadCenter;
            float _SphereNormalSmoothness;
            float4 _TangentA;
            float4 _TangentB;
            float4 _TransmissionColor;
            float _TransmissionIntensity;
            float _TransmissionExponent;
            CBUFFER_END

            TEXTURE2D(_BaseMap); SAMPLER(sampler_BaseMap);
            TEXTURE2D(_DepthMap); SAMPLER(sampler_DepthMap);
            TEXTURE2D(_IDMap); SAMPLER(sampler_IDMap);
            TEXTURE2D(_RootMap); SAMPLER(sampler_RootMap);
            TEXTURE2D(_ShiftMap); SAMPLER(sampler_ShiftMap);

            Varyings vert(Attributes input)
            {
                Varyings output = (Varyings)0;
                VertexPositionInputs vertexInput = GetVertexPositionInputs(input.positionOS.xyz);
                VertexNormalInputs normalInput = GetVertexNormalInputs(input.normalOS, input.tangentOS);

                output.positionCS = vertexInput.positionCS;
                output.uv = TRANSFORM_TEX(input.uv, _BaseMap);
                output.normalWS = normalInput.normalWS;
                output.tangentWS = normalInput.tangentWS;
                output.bitangentWS = normalInput.bitangentWS;
                output.viewDirWS = GetCameraPositionWS() - vertexInput.positionWS;
                output.positionWS = vertexInput.positionWS;
                output.shadowCoord = GetShadowCoord(vertexInput);
                
                output.fogFactor = ComputeFogFactor(output.positionCS.z);
                OUTPUT_LIGHTMAP_UV(input.lightmapUV, unity_LightmapST, output.lightmapUV);
                OUTPUT_SH(output.normalWS, output.vertexSH);
                return output;
            }

            float3 KajiyaShiftTangent(float3 T, float3 N, float shift)
            {
                return normalize(T + shift * N);
            }

            float KajiyaStrandSpecular(float3 T, float3 V, float3 L, float exponent)
            {
                float3 H = normalize(L + V);
                float dotTH = dot(T, H);
                float sinTH = sqrt(max(0.0, 1.0 - dotTH * dotTH));
                float dirAtten = smoothstep(-1.0, 0.0, dotTH);
                return pow(sinTH, exponent) * dirAtten;
            }

            half4 frag(Varyings input) : SV_Target
            {
                half4 baseColor = SAMPLE_TEXTURE2D(_BaseMap, sampler_BaseMap, input.uv);
                
                // Alpha to Coverage / Smoothing logic
                float alpha = baseColor.a;
                clip(alpha - _Cutoff);

                float depth = SAMPLE_TEXTURE2D(_DepthMap, sampler_DepthMap, input.uv).r;
                float id = SAMPLE_TEXTURE2D(_IDMap, sampler_IDMap, input.uv).r;
                float rootTip = SAMPLE_TEXTURE2D(_RootMap, sampler_RootMap, input.uv).r;

                // Apply Root-Tip gradient and ID variation
                float3 tint = lerp(_RootColor.rgb, _TipColor.rgb, rootTip);
                float3 idVar = (id - 0.5) * _IDVariation;
                baseColor.rgb *= (tint + idVar);
                baseColor.rgb *= depth; // Use depth map as AO

                float3 V = normalize(input.viewDirWS);
                float3 N_mesh = normalize(input.normalWS);
                
                // Sphere Normal Trick
                float3 N_sphere = normalize(input.positionWS - _HeadCenter.xyz);
                float3 N = normalize(lerp(N_mesh, N_sphere, _SphereNormalSmoothness));
                
                // Improved strand direction: use tangent-dominant blend for stable visibility
                float3 tangentWS = normalize(input.tangentWS);
                float3 bitangentWS = normalize(input.bitangentWS);
                float3 normalWS = normalize(input.normalWS);
                
                // Use Bitangent as base direction (assuming V-axis alignment for vertical hair strands)
                float3 T_base = bitangentWS;
                float3 B_base = tangentWS;
                
                // UE Style ID Tangent Perturbation
                // Fix: Apply in local space (TBN) to avoid view-dependent artifacts
                float3 perturbVec = lerp(_TangentA, _TangentB, id).xyz;
                
                // Interpret perturbVec as (Strand, Cross-Strand, Normal) offsets
                // x: along Strand (T_base), y: across Strand (B_base), z: along Normal (shift)
                float3 T = normalize(T_base + perturbVec.x * T_base + perturbVec.y * B_base + perturbVec.z * normalWS);

                float shiftTex = SAMPLE_TEXTURE2D(_ShiftMap, sampler_ShiftMap, input.uv).r;
                float shift = (shiftTex - 0.5) * _ShiftScale;

                // --- Main Light ---
                Light mainLight = GetMainLight(input.shadowCoord);
                float3 L = mainLight.direction;
                float3 lightColor = mainLight.color * (mainLight.distanceAttenuation * mainLight.shadowAttenuation);
                float3 transLightColor = mainLight.color * mainLight.distanceAttenuation;

                // Kajiya-Kay Specular
                float3 t1 = KajiyaShiftTangent(T, N, _SpecularShift1 + shift);
                float3 t2 = KajiyaShiftTangent(T, N, _SpecularShift2 + shift);

                float spec1 = KajiyaStrandSpecular(t1, V, L, _SpecularExponent1);
                float spec2 = KajiyaStrandSpecular(t2, V, L, _SpecularExponent2);
                float3 finalSpec = spec1 * _SpecularColor1.rgb + spec2 * _SpecularColor2.rgb;
                
                // Diffuse
                float diffuse = saturate(lerp(0.25, 1.0, dot(N, L)));
                
                // Transmission
                float3 TT = pow(saturate(dot(-V, L)), _TransmissionExponent) * _TransmissionColor.rgb * _TransmissionIntensity;

                float3 diffuseLighting = diffuse * lightColor + TT * transLightColor;
                float3 specularLighting = finalSpec * lightColor;

                // --- Additional Lights ---
                #ifdef _ADDITIONAL_LIGHTS
                uint pixelLightCount = GetAdditionalLightsCount();
                for (uint lightIndex = 0u; lightIndex < pixelLightCount; ++lightIndex)
                {
                    Light light = GetAdditionalLight(lightIndex, input.positionWS);
                    float3 L_add = light.direction;
                    float3 lightColor_add = light.color * (light.distanceAttenuation * light.shadowAttenuation);
                    float3 transLightColor_add = light.color * light.distanceAttenuation;

                    float3 t1_add = KajiyaShiftTangent(T, N, _SpecularShift1 + shift);
                    float3 t2_add = KajiyaShiftTangent(T, N, _SpecularShift2 + shift);

                    float spec1_add = KajiyaStrandSpecular(t1_add, V, L_add, _SpecularExponent1);
                    float spec2_add = KajiyaStrandSpecular(t2_add, V, L_add, _SpecularExponent2);
                    float3 finalSpec_add = spec1_add * _SpecularColor1.rgb + spec2_add * _SpecularColor2.rgb;

                    float diffuse_add = saturate(lerp(0.25, 1.0, dot(N, L_add)));
                    float3 TT_add = pow(saturate(dot(-V, L_add)), _TransmissionExponent) * _TransmissionColor.rgb * _TransmissionIntensity;

                    diffuseLighting += diffuse_add * lightColor_add + TT_add * transLightColor_add;
                    specularLighting += finalSpec_add * lightColor_add;
                }
                #endif

                float3 ambient = float3(0, 0, 0);
                #if defined(LIGHTMAP_ON)
                    ambient = SampleLightmap(input.lightmapUV, N);
                #else
                    ambient = SampleSH(N);
                #endif
                
                float3 finalColor = baseColor.rgb * (diffuseLighting + ambient) + specularLighting;

                finalColor = MixFog(finalColor, input.fogFactor);
                return half4(finalColor, 1.0); // Fully opaque for cutout pass
            }
            ENDHLSL
        }

        Pass
        {
            Name "ForwardLit_Blended"
            Tags { "LightMode" = "HairTransparent" }

            ZWrite Off
            Blend SrcAlpha OneMinusSrcAlpha
            Cull [_Cull]
            HLSLPROGRAM
            #pragma vertex vert
            #pragma fragment frag
            
            // URP Keywords
            #pragma multi_compile _ _MAIN_LIGHT_SHADOWS _MAIN_LIGHT_SHADOWS_CASCADE
            #pragma multi_compile _ _ADDITIONAL_LIGHTS_VERTEX _ADDITIONAL_LIGHTS
            #pragma multi_compile_fragment _ _ADDITIONAL_LIGHT_SHADOWS
            #pragma multi_compile_fragment _ _SHADOWS_SOFT
            #pragma multi_compile_fog
            #pragma multi_compile _ LIGHTMAP_ON

            #include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/Core.hlsl"
            #include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/Lighting.hlsl"

            struct Attributes
            {
                float4 positionOS : POSITION;
                float2 uv : TEXCOORD0;
                float3 normalOS : NORMAL;
                float4 tangentOS : TANGENT;
                float2 lightmapUV : TEXCOORD1;
            };

            struct Varyings
            {
                float4 positionCS : SV_POSITION;
                float2 uv : TEXCOORD0;
                float3 normalWS : TEXCOORD1;
                float3 tangentWS : TEXCOORD3;
                float3 bitangentWS : TEXCOORD4;
                float3 viewDirWS : TEXCOORD5;
                float3 positionWS : TEXCOORD6;
                float4 shadowCoord : TEXCOORD7;
                float fogFactor : TEXCOORD8;
                DECLARE_LIGHTMAP_OR_SH(lightmapUV, vertexSH, 9);
            };

            CBUFFER_START(UnityPerMaterial)
            float4 _BaseMap_ST;
            float4 _SpecularColor1;
            float _SpecularExponent1;
            float _SpecularShift1;
            float4 _SpecularColor2;
            float _SpecularExponent2;
            float _SpecularShift2;
            float _ShiftScale;
            float _Cutoff;
            float _EdgeSoftness;
            float4 _RootColor;
            float4 _TipColor;
            float _IDVariation;
            float4 _HeadCenter;
            float _SphereNormalSmoothness;
            float4 _TangentA;
            float4 _TangentB;
            float4 _TransmissionColor;
            float _TransmissionIntensity;
            float _TransmissionExponent;
            CBUFFER_END

            TEXTURE2D(_BaseMap); SAMPLER(sampler_BaseMap);
            TEXTURE2D(_DepthMap); SAMPLER(sampler_DepthMap);
            TEXTURE2D(_IDMap); SAMPLER(sampler_IDMap);
            TEXTURE2D(_RootMap); SAMPLER(sampler_RootMap);
            TEXTURE2D(_ShiftMap); SAMPLER(sampler_ShiftMap);

            Varyings vert(Attributes input)
            {
                Varyings output = (Varyings)0;
                VertexPositionInputs vertexInput = GetVertexPositionInputs(input.positionOS.xyz);
                VertexNormalInputs normalInput = GetVertexNormalInputs(input.normalOS, input.tangentOS);

                output.positionCS = vertexInput.positionCS;
                output.uv = TRANSFORM_TEX(input.uv, _BaseMap);
                output.normalWS = normalInput.normalWS;
                output.tangentWS = normalInput.tangentWS;
                output.bitangentWS = normalInput.bitangentWS;
                output.viewDirWS = GetCameraPositionWS() - vertexInput.positionWS;
                output.positionWS = vertexInput.positionWS;
                output.shadowCoord = GetShadowCoord(vertexInput);
                
                output.fogFactor = ComputeFogFactor(output.positionCS.z);
                OUTPUT_LIGHTMAP_UV(input.lightmapUV, unity_LightmapST, output.lightmapUV);
                OUTPUT_SH(output.normalWS, output.vertexSH);
                return output;
            }

            float3 KajiyaShiftTangent(float3 T, float3 N, float shift)
            {
                return normalize(T + shift * N);
            }

            float KajiyaStrandSpecular(float3 T, float3 V, float3 L, float exponent)
            {
                float3 H = normalize(L + V);
                float dotTH = dot(T, H);
                float sinTH = sqrt(max(0.0, 1.0 - dotTH * dotTH));
                float dirAtten = smoothstep(-1.0, 0.0, dotTH);
                return pow(sinTH, exponent) * dirAtten;
            }

            half4 frag(Varyings input) : SV_Target
            {
                half4 baseColor = SAMPLE_TEXTURE2D(_BaseMap, sampler_BaseMap, input.uv);
                
                // 改进半透明逻辑：
                // 第一个 Pass 已经处理了 alpha > _Cutoff 的部分（ZWrite On）
                // 第二个 Pass 处理边缘平滑（ZWrite Off）
                // 让 alpha 在 _Cutoff 范围内平滑过渡，避免右图那种生硬的重叠感
                float alpha = saturate(baseColor.a / max(0.001, _Cutoff));
                // 使用 _EdgeSoftness 调节边缘的柔和程度
                alpha = pow(alpha, 1.0 / max(0.01, _EdgeSoftness * 2.0));
                
                clip(alpha - 0.001);

                float depth = SAMPLE_TEXTURE2D(_DepthMap, sampler_DepthMap, input.uv).r;
                float id = SAMPLE_TEXTURE2D(_IDMap, sampler_IDMap, input.uv).r;
                float rootTip = SAMPLE_TEXTURE2D(_RootMap, sampler_RootMap, input.uv).r;

                // Apply Root-Tip gradient and ID variation
                float3 tint = lerp(_RootColor.rgb, _TipColor.rgb, rootTip);
                float3 idVar = (id - 0.5) * _IDVariation;
                baseColor.rgb *= (tint + idVar);
                baseColor.rgb *= depth; // Use depth map as AO

                float3 V = normalize(input.viewDirWS);
                float3 N_mesh = normalize(input.normalWS);
                
                // Sphere Normal Trick
                float3 N_sphere = normalize(input.positionWS - _HeadCenter.xyz);
                float3 N = normalize(lerp(N_mesh, N_sphere, _SphereNormalSmoothness));
                
                // Improved strand direction: use tangent-dominant blend for stable visibility
                float3 tangentWS = normalize(input.tangentWS);
                float3 bitangentWS = normalize(input.bitangentWS);
                float3 normalWS = normalize(input.normalWS);
                
                // Use Bitangent as base direction (assuming V-axis alignment for vertical hair strands)
                float3 T_base = bitangentWS;
                float3 B_base = tangentWS;
                
                // UE Style ID Tangent Perturbation
                // Fix: Apply in local space (TBN) to avoid view-dependent artifacts
                float3 perturbVec = lerp(_TangentA, _TangentB, id).xyz;
                
                // Interpret perturbVec as (Strand, Cross-Strand, Normal) offsets
                // x: along Strand (T_base), y: across Strand (B_base), z: along Normal (shift)
                float3 T = normalize(T_base + perturbVec.x * T_base + perturbVec.y * B_base + perturbVec.z * normalWS);

                float shiftTex = SAMPLE_TEXTURE2D(_ShiftMap, sampler_ShiftMap, input.uv).r;
                float shift = (shiftTex - 0.5) * _ShiftScale;

                // --- Main Light ---
                Light mainLight = GetMainLight(input.shadowCoord);
                float3 L = mainLight.direction;
                float3 lightColor = mainLight.color * (mainLight.distanceAttenuation * mainLight.shadowAttenuation);
                float3 transLightColor = mainLight.color * mainLight.distanceAttenuation;

                // Kajiya-Kay Specular
                float3 t1 = KajiyaShiftTangent(T, N, _SpecularShift1 + shift);
                float3 t2 = KajiyaShiftTangent(T, N, _SpecularShift2 + shift);

                float spec1 = KajiyaStrandSpecular(t1, V, L, _SpecularExponent1);
                float spec2 = KajiyaStrandSpecular(t2, V, L, _SpecularExponent2);
                float3 finalSpec = spec1 * _SpecularColor1.rgb + spec2 * _SpecularColor2.rgb;
                
                // Diffuse
                float diffuse = saturate(lerp(0.25, 1.0, dot(N, L)));
                
                // Transmission
                float3 TT = pow(saturate(dot(-V, L)), _TransmissionExponent) * _TransmissionColor.rgb * _TransmissionIntensity;

                float3 diffuseLighting = diffuse * lightColor + TT * transLightColor;
                float3 specularLighting = finalSpec * lightColor;

                // --- Additional Lights ---
                #ifdef _ADDITIONAL_LIGHTS
                uint pixelLightCount = GetAdditionalLightsCount();
                for (uint lightIndex = 0u; lightIndex < pixelLightCount; ++lightIndex)
                {
                    Light light = GetAdditionalLight(lightIndex, input.positionWS);
                    float3 L_add = light.direction;
                    float3 lightColor_add = light.color * (light.distanceAttenuation * light.shadowAttenuation);
                    float3 transLightColor_add = light.color * light.distanceAttenuation;

                    float3 t1_add = KajiyaShiftTangent(T, N, _SpecularShift1 + shift);
                    float3 t2_add = KajiyaShiftTangent(T, N, _SpecularShift2 + shift);

                    float spec1_add = KajiyaStrandSpecular(t1_add, V, L_add, _SpecularExponent1);
                    float spec2_add = KajiyaStrandSpecular(t2_add, V, L_add, _SpecularExponent2);
                    float3 finalSpec_add = spec1_add * _SpecularColor1.rgb + spec2_add * _SpecularColor2.rgb;

                    float diffuse_add = saturate(lerp(0.25, 1.0, dot(N, L_add)));
                    float3 TT_add = pow(saturate(dot(-V, L_add)), _TransmissionExponent) * _TransmissionColor.rgb * _TransmissionIntensity;

                    diffuseLighting += diffuse_add * lightColor_add + TT_add * transLightColor_add;
                    specularLighting += finalSpec_add * lightColor_add;
                }
                #endif

                float3 ambient = float3(0, 0, 0);
                #if defined(LIGHTMAP_ON)
                    ambient = SampleLightmap(input.lightmapUV, N);
                #else
                    ambient = SampleSH(N);
                #endif
                
                float3 finalColor = baseColor.rgb * (diffuseLighting + ambient) + specularLighting;

                finalColor = MixFog(finalColor, input.fogFactor);
                
                return half4(finalColor, alpha);
            }
            ENDHLSL
        }

        // Shadow Caster Pass
        Pass
        {
            Name "ShadowCaster"
            Tags { "LightMode" = "ShadowCaster" }

            ZWrite On
            ZTest LEqual
            ColorMask 0
            Cull [_Cull]

            HLSLPROGRAM
            #pragma vertex vert
            #pragma fragment frag
            #pragma multi_compile_instancing
            
            #include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/Core.hlsl"
            #include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/Lighting.hlsl"
            #include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/Shadows.hlsl"

            struct Attributes
            {
                float4 positionOS : POSITION;
                float3 normalOS : NORMAL;
                float2 uv : TEXCOORD0;
                UNITY_VERTEX_INPUT_INSTANCE_ID
            };

            struct Varyings
            {
                float4 positionCS : SV_POSITION;
                float2 uv : TEXCOORD0;
                UNITY_VERTEX_INPUT_INSTANCE_ID
                UNITY_VERTEX_OUTPUT_STEREO
            };

            TEXTURE2D(_BaseMap); SAMPLER(sampler_BaseMap);
            
            CBUFFER_START(UnityPerMaterial)
            float4 _BaseMap_ST;
            float _Cutoff;
            CBUFFER_END

            Varyings vert(Attributes input)
            {
                Varyings output;
                UNITY_SETUP_INSTANCE_ID(input);
                UNITY_TRANSFER_INSTANCE_ID(input, output);
                UNITY_INITIALIZE_VERTEX_OUTPUT_STEREO(output);

                float3 positionWS = TransformObjectToWorld(input.positionOS.xyz);
                float3 normalWS = TransformObjectToWorldNormal(input.normalOS);

                output.positionCS = TransformWorldToHClip(ApplyShadowBias(positionWS, normalWS, GetMainLight().direction));
                #if UNITY_REVERSED_Z
                    output.positionCS.z = min(output.positionCS.z, output.positionCS.w * UNITY_NEAR_CLIP_VALUE);
                #else
                    output.positionCS.z = max(output.positionCS.z, output.positionCS.w * UNITY_NEAR_CLIP_VALUE);
                #endif

                output.uv = TRANSFORM_TEX(input.uv, _BaseMap);
                return output;
            }

            half4 frag(Varyings input) : SV_Target
            {
                UNITY_SETUP_INSTANCE_ID(input);
                half alpha = SAMPLE_TEXTURE2D(_BaseMap, sampler_BaseMap, input.uv).a;
                clip(alpha - _Cutoff);
                return 0;
            }
            ENDHLSL
        }

        // Depth Only Pass
        Pass
        {
            Name "DepthOnly"
            Tags { "LightMode" = "DepthOnly" }

            ZWrite On
            ColorMask 0
            Cull [_Cull]

            HLSLPROGRAM
            #pragma vertex vert
            #pragma fragment frag
            #pragma multi_compile_instancing
            
            #include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/Core.hlsl"

            struct Attributes
            {
                float4 positionOS : POSITION;
                float2 uv : TEXCOORD0;
                UNITY_VERTEX_INPUT_INSTANCE_ID
            };

            struct Varyings
            {
                float4 positionCS : SV_POSITION;
                float2 uv : TEXCOORD0;
                UNITY_VERTEX_INPUT_INSTANCE_ID
                UNITY_VERTEX_OUTPUT_STEREO
            };

            TEXTURE2D(_BaseMap); SAMPLER(sampler_BaseMap);
            
            CBUFFER_START(UnityPerMaterial)
            float4 _BaseMap_ST;
            float _Cutoff;
            CBUFFER_END

            Varyings vert(Attributes input)
            {
                Varyings output;
                UNITY_SETUP_INSTANCE_ID(input);
                UNITY_TRANSFER_INSTANCE_ID(input, output);
                UNITY_INITIALIZE_VERTEX_OUTPUT_STEREO(output);

                output.positionCS = TransformObjectToHClip(input.positionOS.xyz);
                output.uv = TRANSFORM_TEX(input.uv, _BaseMap);
                return output;
            }

            half4 frag(Varyings input) : SV_Target
            {
                UNITY_SETUP_INSTANCE_ID(input);
                half alpha = SAMPLE_TEXTURE2D(_BaseMap, sampler_BaseMap, input.uv).a;
                clip(alpha - _Cutoff);
                return 0;
            }
            ENDHLSL
        }

        // Depth Normals Pass
        Pass
        {
            Name "DepthNormals"
            Tags { "LightMode" = "DepthNormals" }

            ZWrite On
            ZTest LEqual
            Cull [_Cull]

            HLSLPROGRAM
            #pragma vertex vert
            #pragma fragment frag
            #pragma multi_compile_instancing
            
            #include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/Core.hlsl"

            struct Attributes
            {
                float4 positionOS : POSITION;
                float3 normalOS : NORMAL;
                float2 uv : TEXCOORD0;
                UNITY_VERTEX_INPUT_INSTANCE_ID
            };

            struct Varyings
            {
                float4 positionCS : SV_POSITION;
                float2 uv : TEXCOORD0;
                float3 normalWS : TEXCOORD1;
                UNITY_VERTEX_INPUT_INSTANCE_ID
                UNITY_VERTEX_OUTPUT_STEREO
            };

            TEXTURE2D(_BaseMap); SAMPLER(sampler_BaseMap);
            
            CBUFFER_START(UnityPerMaterial)
            float4 _BaseMap_ST;
            float _Cutoff;
            CBUFFER_END

            Varyings vert(Attributes input)
            {
                Varyings output;
                UNITY_SETUP_INSTANCE_ID(input);
                UNITY_TRANSFER_INSTANCE_ID(input, output);
                UNITY_INITIALIZE_VERTEX_OUTPUT_STEREO(output);

                output.positionCS = TransformObjectToHClip(input.positionOS.xyz);
                output.normalWS = TransformObjectToWorldNormal(input.normalOS);
                output.uv = TRANSFORM_TEX(input.uv, _BaseMap);
                return output;
            }

            half4 frag(Varyings input) : SV_Target
            {
                UNITY_SETUP_INSTANCE_ID(input);
                half alpha = SAMPLE_TEXTURE2D(_BaseMap, sampler_BaseMap, input.uv).a;
                clip(alpha - _Cutoff);
                
                float3 normalWS = normalize(input.normalWS);
                return half4(PackNormalOctRectEncode(TransformWorldToViewDir(normalWS, true)), 0.0, 0.0);
            }
            ENDHLSL
        }

        // Meta Pass
        Pass
        {
            Name "Meta"
            Tags { "LightMode" = "Meta" }
            Cull Off

            HLSLPROGRAM
            #pragma vertex VertexMeta
            #pragma fragment FragmentMeta
            
            #include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/Core.hlsl"
            #include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/MetaInput.hlsl"

            struct Attributes
            {
                float4 positionOS : POSITION;
                float2 uv : TEXCOORD0;
                float2 lightmapUV : TEXCOORD1;
            };

            struct Varyings
            {
                float4 positionCS : SV_POSITION;
                float2 uv : TEXCOORD0;
            };

            TEXTURE2D(_BaseMap); SAMPLER(sampler_BaseMap);
            TEXTURE2D(_RootMap); SAMPLER(sampler_RootMap);
            
            CBUFFER_START(UnityPerMaterial)
            float4 _BaseMap_ST;
            float4 _RootColor;
            float4 _TipColor;
            float _Cutoff;
            CBUFFER_END

            Varyings VertexMeta(Attributes input)
            {
                Varyings output;
                output.positionCS = UnityMetaVertexPosition(input.positionOS.xyz, input.lightmapUV, input.lightmapUV, unity_LightmapST, unity_DynamicLightmapST);
                output.uv = TRANSFORM_TEX(input.uv, _BaseMap);
                return output;
            }

            half4 FragmentMeta(Varyings input) : SV_Target
            {
                half4 baseColor = SAMPLE_TEXTURE2D(_BaseMap, sampler_BaseMap, input.uv);
                float rootTip = SAMPLE_TEXTURE2D(_RootMap, sampler_RootMap, input.uv).r;
                float3 tint = lerp(_RootColor.rgb, _TipColor.rgb, rootTip);
                baseColor.rgb *= tint;

                MetaInput metaInput = (MetaInput)0;
                metaInput.Albedo = baseColor.rgb;
                metaInput.Emission = 0;
                return UnityMetaFragment(metaInput);
            }
            ENDHLSL
        }
    }
}
