Shader "Custom/Common_Hair Bak"
{
    Properties
    {
        [Header(Base Textures)]
        _BaseMap("Base Color (A: Alpha)", 2D) = "white" {}
        _DepthMap("Depth Map (AO)", 2D) = "white" {}
        _IDMap("ID Map (Variation)", 2D) = "white" {}
        _RootMap("Root Map (Root to Tip)", 2D) = "white" {}
        
        [Header(Specular 1 (Primary))]
        _SpecularColor1("Color", Color) = (0.4, 0.4, 0.4, 1)
        _SpecularExponent1("Exponent", Range(1, 1024)) = 100
        _SpecularShift1("Shift", Range(-1, 1)) = 0
        
        [Header(Specular 2 (Secondary))]
        _SpecularColor2("Color", Color) = (0.25, 0.25, 0.25, 1)
        _SpecularExponent2("Exponent", Range(1, 512)) = 50
        _SpecularShift2("Shift", Range(-1, 1)) = 0.1
        
        [Header(Specular Settings)]
        _ShiftMap("Shift Map (R)", 2D) = "black" {}
        _ShiftScale("Shift Scale", Range(-1, 1)) = 0.1
        
        [Header(Lighting and Variation)]
        _RootColor("Root Tint", Color) = (0.5, 0.5, 0.5, 1)
        _TipColor("Tip Tint", Color) = (1, 1, 1, 1)
        _IDVariation("ID Color Variation", Range(0, 1)) = 0.2
        
        [Header(Sphere Normal Trick)]
        _HeadCenter("Head Center (WS)", Vector) = (0, 0, 0, 0)
        _SphereNormalSmoothness("Sphere Normal Smoothness", Range(0, 1)) = 0.5

        [Header(ID Tangent Perturbation)]
        _TangentA("Tangent A (Offset)", Vector) = (0, 0, 0.3, 0)
        _TangentB("Tangent B (Offset)", Vector) = (0, 0, -0.3, 0)

        [Header(Transmission (TT))]
        _TransmissionColor("Transmission Color", Color) = (1, 1, 1, 1)
        _TransmissionIntensity("Transmission Intensity", Range(0, 5)) = 0.1
        _TransmissionExponent("Transmission Exponent", Range(1, 128)) = 20

        [Header(Rendering)]
        _Cutoff("Alpha Cutoff (Core)", Range(0, 1)) = 0.65
        _EdgeSoftness("Edge Softness", Range(0, 1)) = 0.5
        [Enum(UnityEngine.Rendering.CullMode)] _Cull("Cull Mode", Float) = 0
    }

    SubShader
    {
        Tags { "RenderType"="Transparent" "Queue"="Transparent" "RenderPipeline" = "UniversalPipeline" }
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

            #include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/Core.hlsl"
            #include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/Lighting.hlsl"

            struct Attributes
            {
                float4 positionOS : POSITION;
                float2 uv : TEXCOORD0;
                float3 normalOS : NORMAL;
                float4 tangentOS : TANGENT;
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

                Light mainLight = GetMainLight(input.shadowCoord);
                float3 L = mainLight.direction;
                float3 lightColor = mainLight.color * (mainLight.distanceAttenuation * mainLight.shadowAttenuation);
                // Transmission should not be occluded by shadows (it simulates light passing through)
                float3 transLightColor = mainLight.color * mainLight.distanceAttenuation;

                // Kajiya-Kay Specular - Use blended normal to reduce noise
                float3 t1 = KajiyaShiftTangent(T, N, _SpecularShift1 + shift);
                float3 t2 = KajiyaShiftTangent(T, N, _SpecularShift2 + shift);

                float spec1 = KajiyaStrandSpecular(t1, V, L, _SpecularExponent1);
                float spec2 = KajiyaStrandSpecular(t2, V, L, _SpecularExponent2);

                float3 finalSpec = spec1 * _SpecularColor1.rgb + spec2 * _SpecularColor2.rgb;
                
                // Simple Diffuse
                float diffuse = saturate(lerp(0.25, 1.0, dot(N, L)));
                
                // Transmission (TT)
                float3 TT = pow(saturate(dot(-V, L)), _TransmissionExponent) * _TransmissionColor.rgb * _TransmissionIntensity;

                float3 ambient = SampleSH(N);
                
                float3 finalColor = baseColor.rgb * (diffuse * lightColor + ambient + TT * transLightColor) + finalSpec * lightColor;

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

            #include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/Core.hlsl"
            #include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/Lighting.hlsl"

            struct Attributes
            {
                float4 positionOS : POSITION;
                float2 uv : TEXCOORD0;
                float3 normalOS : NORMAL;
                float4 tangentOS : TANGENT;
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

                Light mainLight = GetMainLight(input.shadowCoord);
                float3 L = mainLight.direction;
                float3 lightColor = mainLight.color * (mainLight.distanceAttenuation * mainLight.shadowAttenuation);
                // Transmission should not be occluded by shadows (it simulates light passing through)
                float3 transLightColor = mainLight.color * mainLight.distanceAttenuation;

                // Kajiya-Kay Specular - Use blended normal to reduce noise
                float3 t1 = KajiyaShiftTangent(T, N, _SpecularShift1 + shift);
                float3 t2 = KajiyaShiftTangent(T, N, _SpecularShift2 + shift);

                float spec1 = KajiyaStrandSpecular(t1, V, L, _SpecularExponent1);
                float spec2 = KajiyaStrandSpecular(t2, V, L, _SpecularExponent2);

                float3 finalSpec = spec1 * _SpecularColor1.rgb + spec2 * _SpecularColor2.rgb;
                
                // Simple Diffuse
                float diffuse = saturate(lerp(0.25, 1.0, dot(N, L)));
                
                // Transmission (TT)
                float3 TT = pow(saturate(dot(-V, L)), _TransmissionExponent) * _TransmissionColor.rgb * _TransmissionIntensity;

                float3 ambient = SampleSH(N);
                
                float3 finalColor = baseColor.rgb * (diffuse * lightColor + ambient + TT * transLightColor) + finalSpec * lightColor;

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

            HLSLPROGRAM
            #pragma vertex vert
            #pragma fragment frag
            #include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/Core.hlsl"

            struct Attributes
            {
                float4 positionOS : POSITION;
                float2 uv : TEXCOORD0;
            };

            struct Varyings
            {
                float4 positionCS : SV_POSITION;
                float2 uv : TEXCOORD0;
            };

            TEXTURE2D(_BaseMap); SAMPLER(sampler_BaseMap);
            
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

            Varyings vert(Attributes input)
            {
                Varyings output;
                output.positionCS = TransformObjectToHClip(input.positionOS.xyz);
                output.uv = TRANSFORM_TEX(input.uv, _BaseMap);
                return output;
            }

            half4 frag(Varyings input) : SV_Target
            {
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

            HLSLPROGRAM
            #pragma vertex vert
            #pragma fragment frag
            #include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/Core.hlsl"

            struct Attributes
            {
                float4 positionOS : POSITION;
                float2 uv : TEXCOORD0;
            };

            struct Varyings
            {
                float4 positionCS : SV_POSITION;
                float2 uv : TEXCOORD0;
            };

            TEXTURE2D(_BaseMap); SAMPLER(sampler_BaseMap);
            
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

            Varyings vert(Attributes input)
            {
                Varyings output;
                output.positionCS = TransformObjectToHClip(input.positionOS.xyz);
                output.uv = TRANSFORM_TEX(input.uv, _BaseMap);
                return output;
            }

            half4 frag(Varyings input) : SV_Target
            {
                half alpha = SAMPLE_TEXTURE2D(_BaseMap, sampler_BaseMap, input.uv).a;
                clip(alpha - _Cutoff);
                return 0;
            }
            ENDHLSL
        }
    }
}
