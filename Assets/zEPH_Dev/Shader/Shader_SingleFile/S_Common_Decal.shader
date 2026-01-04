Shader "Custom/Common PBRDecal"
{
    Properties
    {
        [Header(Decal Settings)]
        [Space(5)]
        [Enum(X_Axis, 0, Y_Axis, 1, Z_Axis, 2)] _ProjectionAxis("Axis", Float) = 1
        _DecalOpacity("Decal Opacity", Range(0, 1)) = 1.0

        [Space(15)]
        [Header(Base Color)]
        [Space(5)]
        _BaseMap("Base Map", 2D) = "white" {}
        _BaseColor("Base Color", Color) = (1,1,1,1)
        _Brightness("Brightness", Float) = 1.0
        _Saturation("Saturation", Float) = 1.0
        _Contrast("Contrast", Float) = 1.0

        [Space(15)]
        [Header(ORMA Map)]
        [Space(5)]
        [Enum(B_Channel, 0, A_Channel, 1)] _OpacitySource("Opacity Source", Float) = 1
        [Enum(NonMetal, 0, Metal, 1, Mask, 2)] _MetallicMode("Metallic", Float) = 2
        [NoScaleOffset] _ORMAMap("ORMA Map (R:AO, G:Smooth, B:Metal, A:Opacity)", 2D) = "white" {}
        _SmoothMin("Smoothness Min", Range(0, 1)) = 0.0
        _SmoothMax("Smoothness Max", Range(0, 1)) = 1.0
        _AOIntensity("AO Intensity", Range(0, 1)) = 1.0
        
        [Space(15)]
        [Header(Normal)]
        [Space(5)]
        [Toggle(_USE_NORMAL)] _UseNormal("Use Normal Map", Float) = 0
        [NoScaleOffset] [Normal] _NormalMap("Normal Map", 2D) = "bump" {}
        _NormalScale("Normal Scale", Float) = 1.0
    }

    SubShader
    {
        Tags 
        { 
            "RenderPipeline" = "UniversalPipeline"
            "Queue" = "Transparent"
            "RenderType" = "Transparent"
        }

        Pass
        {
            Name "DBufferProjector"
            Tags { "LightMode" = "DBufferProjector" }

            // Decal Projector specific settings
            Cull Front
            ZWrite Off
            ZTest Greater
            
            // Standard DBuffer blending
            Blend 0 SrcAlpha OneMinusSrcAlpha, Zero OneMinusSrcAlpha
            Blend 1 SrcAlpha OneMinusSrcAlpha, Zero OneMinusSrcAlpha
            Blend 2 SrcAlpha OneMinusSrcAlpha, Zero OneMinusSrcAlpha

            HLSLPROGRAM
            #pragma vertex vert
            #pragma fragment frag
            #pragma shader_feature_local _USE_NORMAL
            
            // URP Decal keywords for MRT support
            #pragma multi_compile_fragment _ _DBUFFER_MRT1 _DBUFFER_MRT2 _DBUFFER_MRT3

            #include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/Core.hlsl"
            #include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/DeclareDepthTexture.hlsl"

            struct Attributes
            {
                float4 positionOS : POSITION;
                UNITY_VERTEX_INPUT_INSTANCE_ID
            };

            struct Varyings
            {
                float4 positionCS : SV_POSITION;
                float4 screenPos : TEXCOORD0;
                UNITY_VERTEX_INPUT_INSTANCE_ID
                UNITY_VERTEX_OUTPUT_STEREO
            };

            CBUFFER_START(UnityPerMaterial)
                float4 _BaseMap_ST;
                float4 _BaseColor;
                float _ProjectionAxis;
                float _DecalOpacity;
                float _Brightness;
                float _Saturation;
                float _Contrast;
                float _OpacitySource;
                float _MetallicMode;
                float _SmoothMin;
                float _SmoothMax;
                float _AOIntensity;
                float _UseNormal;
                float _NormalScale;
            CBUFFER_END

            TEXTURE2D(_BaseMap); SAMPLER(sampler_BaseMap);
            TEXTURE2D(_ORMAMap); SAMPLER(sampler_ORMAMap);
            TEXTURE2D(_NormalMap); SAMPLER(sampler_NormalMap);

            Varyings vert(Attributes input)
            {
                Varyings output;
                UNITY_SETUP_INSTANCE_ID(input);
                UNITY_TRANSFER_INSTANCE_ID(input, output);
                UNITY_INITIALIZE_VERTEX_OUTPUT_STEREO(output);

                output.positionCS = TransformObjectToHClip(input.positionOS.xyz);
                output.screenPos = ComputeScreenPos(output.positionCS);
                return output;
            }

            struct FragmentOutput
            {
                float4 outDBuffer0 : SV_Target0;
                #if defined(_DBUFFER_MRT2) || defined(_DBUFFER_MRT3)
                float4 outDBuffer1 : SV_Target1;
                #endif
                #if defined(_DBUFFER_MRT3)
                float4 outDBuffer2 : SV_Target2;
                #endif
            };

            FragmentOutput frag(Varyings input)
            {
                UNITY_SETUP_INSTANCE_ID(input);
                UNITY_SETUP_STEREO_EYE_INDEX_POST_VERTEX(input);

                FragmentOutput output = (FragmentOutput)0;

                float2 screenUV = input.screenPos.xy / input.screenPos.w;
                
                // Get World Space Position from Depth
                float depth = SampleSceneDepth(screenUV);
                float3 positionWS = ComputeWorldSpacePosition(screenUV, depth, UNITY_MATRIX_I_VP);
                float3 positionOS = TransformWorldToObject(positionWS);

                // Clipping: Projector box is -0.5 to 0.5 in all axes
                clip(0.5 - abs(positionOS));

                // Normal Clipping (Fixes "negative axis" / back-side projection)
                // Reconstruct normal from depth derivatives
                float3 normalWS = normalize(cross(ddy(positionWS), ddx(positionWS)));
                float3 normalOS = TransformWorldToObjectDir(normalWS);

                // UVs and Basis based on Projection Axis
                float2 decalUV = 0;
                float3 tOS = float3(1, 0, 0);
                float3 bOS = float3(0, 1, 0);
                float3 nOS = float3(0, 0, 1);

                if (_ProjectionAxis < 0.5) // X Axis
                {
                    decalUV = positionOS.zy + 0.5;
                    tOS = float3(0, 0, 1);
                    bOS = float3(0, 1, 0);
                    nOS = float3(1, 0, 0);
                    clip(normalOS.x - 0.1);
                }
                else if (_ProjectionAxis < 1.5) // Y Axis
                {
                    decalUV = positionOS.xz + 0.5;
                    tOS = float3(1, 0, 0);
                    bOS = float3(0, 0, 1);
                    nOS = float3(0, 1, 0);
                    clip(normalOS.y - 0.1);
                }
                else // Z Axis
                {
                    decalUV.x = 0.5 - positionOS.x;
                    decalUV.y = positionOS.y + 0.5;
                    tOS = float3(-1, 0, 0);
                    bOS = float3(0, 1, 0);
                    nOS = float3(0, 0, 1);
                    clip(normalOS.z - 0.1);
                }

                decalUV = decalUV * _BaseMap_ST.xy + _BaseMap_ST.zw;

                // Sample Maps
                float4 baseColorMap = SAMPLE_TEXTURE2D(_BaseMap, sampler_BaseMap, decalUV);
                float4 ormaMap = SAMPLE_TEXTURE2D(_ORMAMap, sampler_ORMAMap, decalUV);
                
                // Color Adjustments
                float3 color = baseColorMap.rgb * _BaseColor.rgb;
                
                // Brightness
                color *= _Brightness;
                
                // Saturation (1 is original, >1 higher, <1 lower)
                float luma = dot(color, float3(0.2126, 0.7152, 0.0722));
                color = lerp(luma.xxx, color, _Saturation);
                
                // Contrast (using pow as requested)
                color = pow(max(color, 0.0), _Contrast);

                // ORMA: R:AO, G:Smooth, B:Metal, A:Opacity
                float ao = lerp(1.0, ormaMap.r, _AOIntensity);
                float smoothness = lerp(_SmoothMin, _SmoothMax, ormaMap.g);
                
                float metallic = 0;
                if (_MetallicMode < 0.5) metallic = 0;
                else if (_MetallicMode < 1.5) metallic = 1;
                else metallic = ormaMap.b;
                
                float alpha = (_OpacitySource < 0.5) ? ormaMap.b : ormaMap.a;
                alpha *= _DecalOpacity;

                // Output to DBuffer
                output.outDBuffer0 = float4(color, alpha);

                #if defined(_DBUFFER_MRT2) || defined(_DBUFFER_MRT3)
                    #if _USE_NORMAL
                        float3 normalTS = UnpackNormalScale(SAMPLE_TEXTURE2D(_NormalMap, sampler_NormalMap, decalUV), _NormalScale);
                        
                        // Transform Tangent Normal to World Space using Projector Basis
                        float3 tangentWS = TransformObjectToWorldDir(tOS);
                        float3 bitangentWS = TransformObjectToWorldDir(bOS);
                        float3 normalProjectorWS = TransformObjectToWorldDir(nOS);
                        
                        float3 combinedNormalWS = normalTS.x * tangentWS + normalTS.y * bitangentWS + normalTS.z * normalProjectorWS;
                        output.outDBuffer1 = float4(combinedNormalWS * 0.5 + 0.5, alpha);
                    #else
                        output.outDBuffer1 = float4(0.5, 0.5, 0.5, 0); // No normal change
                    #endif
                #endif

                #if defined(_DBUFFER_MRT3)
                    // DBuffer2: R:Metallic, G:Occlusion, B:Smoothness, A:Alpha
                    output.outDBuffer2 = float4(metallic, ao, smoothness, alpha);
                #endif

                return output;
            }
            ENDHLSL
        }
    }
    FallBack "Hidden/Universal Render Pipeline/FallbackError"
}
