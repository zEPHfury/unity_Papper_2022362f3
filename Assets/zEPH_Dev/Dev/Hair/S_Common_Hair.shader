Shader "Custom/S_Common_Hair"
{
    Properties
    {
        [Header(Base Textures)]
        _BaseMap("Base Color (A: Alpha)", 2D) = "white" {}
        _DepthMap("Depth Map (AO)", 2D) = "white" {}
        _IDMap("ID Map (Variation)", 2D) = "white" {}
        _RootMap("Root Map (Root to Tip)", 2D) = "white" {}
        
        [Header(Specular 1 (Primary))]
        _SpecularColor1("Color", Color) = (1, 1, 1, 1)
        _SpecularExponent1("Exponent", Range(1, 512)) = 100
        _SpecularShift1("Shift", Range(-1, 1)) = 0
        
        [Header(Specular 2 (Secondary))]
        _SpecularColor2("Color", Color) = (1, 1, 1, 1)
        _SpecularExponent2("Exponent", Range(1, 512)) = 50
        _SpecularShift2("Shift", Range(-1, 1)) = 0.1
        
        [Header(Specular Settings)]
        _ShiftMap("Shift Map (R)", 2D) = "black" {}
        _ShiftScale("Shift Scale", Range(-1, 1)) = 0.1
        
        [Header(Lighting and Variation)]
        _RootColor("Root Tint", Color) = (0.5, 0.5, 0.5, 1)
        _TipColor("Tip Tint", Color) = (1, 1, 1, 1)
        _IDVariation("ID Color Variation", Range(0, 1)) = 0.2
        
        [Header(Rendering)]
        _Cutoff("Alpha Cutoff", Range(0, 1)) = 0.5
        [Enum(UnityEngine.Rendering.CullMode)] _Cull("Cull Mode", Float) = 0
    }

    SubShader
    {
        Tags { "RenderType"="TransparentCutout" "Queue"="AlphaTest" "RenderPipeline" = "UniversalPipeline" }
        LOD 100
        Cull [_Cull]

        Pass
        {
            Name "ForwardLit"
            Tags { "LightMode" = "UniversalForward" }

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
                UNITY_FOG_COORDS(8)
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
            float4 _RootColor;
            float4 _TipColor;
            float _IDVariation;
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
                output.viewDirWS = GetWorldSpaceViewDir(vertexInput.positionWS);
                output.positionWS = vertexInput.positionWS;
                output.shadowCoord = GetShadowCoord(vertexInput);
                
                UNITY_TRANSFER_FOG(output, output.positionCS);
                return output;
            }

            float3 ShiftTangent(float3 T, float3 N, float shift)
            {
                return normalize(T + shift * N);
            }

            float StrandSpecular(float3 T, float3 V, float3 L, float exponent)
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
                clip(baseColor.a - _Cutoff);

                float depth = SAMPLE_TEXTURE2D(_DepthMap, sampler_DepthMap, input.uv).r;
                float id = SAMPLE_TEXTURE2D(_IDMap, sampler_IDMap, input.uv).r;
                float rootTip = SAMPLE_TEXTURE2D(_RootMap, sampler_RootMap, input.uv).r;

                // Apply Root-Tip gradient and ID variation
                float3 tint = lerp(_RootColor.rgb, _TipColor.rgb, rootTip);
                float3 idVar = (id - 0.5) * _IDVariation;
                baseColor.rgb *= (tint + idVar);
                baseColor.rgb *= depth; // Use depth map as AO

                float3 V = normalize(input.viewDirWS);
                float3 N = normalize(input.normalWS);
                
                // Use bitangent as the strand direction (assuming vertical UV layout)
                float3 T = normalize(input.bitangentWS); 

                float shiftTex = SAMPLE_TEXTURE2D(_ShiftMap, sampler_ShiftMap, input.uv).r;
                float shift = (shiftTex - 0.5) * _ShiftScale;

                Light mainLight = GetMainLight(input.shadowCoord);
                float3 L = mainLight.direction;
                float3 lightColor = mainLight.color * (mainLight.distanceAttenuation * mainLight.shadowAttenuation);

                // Kajiya-Kay Specular
                float3 t1 = ShiftTangent(T, N, _SpecularShift1 + shift);
                float3 t2 = ShiftTangent(T, N, _SpecularShift2 + shift);

                float spec1 = StrandSpecular(t1, V, L, _SpecularExponent1);
                float spec2 = StrandSpecular(t2, V, L, _SpecularExponent2);

                float3 finalSpec = spec1 * _SpecularColor1.rgb + spec2 * _SpecularColor2.rgb;
                
                // Simple Diffuse
                float diffuse = saturate(lerp(0.25, 1.0, dot(N, L)));
                
                float3 ambient = SampleSH(N);
                
                float3 finalColor = baseColor.rgb * (diffuse * lightColor + ambient) + finalSpec * lightColor;

                UNITY_APPLY_FOG(input.fogCoord, finalColor);
                return half4(finalColor, baseColor.a);
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
            float4 _BaseMap_ST;
            float _Cutoff;

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
            float4 _BaseMap_ST;
            float _Cutoff;

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
