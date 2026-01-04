Shader "Custom/Common DecalCaustic"
{
    Properties
    {
        [Header(Decal Settings)]
        [Space(5)]
        [Enum(X_Axis, 0, Y_Axis, 1, Z_Axis, 2)] _ProjectionAxis("Axis", Float) = 1
        _DecalOpacity("焦散不透明度", Range(0, 1)) = 1.0

        [Space(15)]
        [Header(Base Color)]
        [Space(5)]
        _BaseMap("焦散纹理", 2D) = "white" {}
        _BaseColor("基础颜色", Color) = (1,1,1,1)
        _Brightness("亮度", Float) = 1.0
        _Saturation("饱和度", Float) = 1.0
        _Contrast("对比度", Float) = 1.0
        [Space(15)]
        [Header(Caustic Animation)]
        [Space(5)]
        _CausticSpeed("速度", Float) = 0.1
        _CausticScale("缩放", Float) = 1.0
        _CausticRGBOffset("RGB 偏移", Range(0, 0.05)) = 0.01
        _EdgeSoftness("边缘柔化", Range(0, 0.5)) = 0.1
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

            HLSLPROGRAM
            #pragma vertex vert
            #pragma fragment frag
            
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
                float _CausticSpeed;
                float _CausticScale;
                float _CausticRGBOffset;
                float _EdgeSoftness;
            CBUFFER_END

            TEXTURE2D(_BaseMap); SAMPLER(sampler_BaseMap);

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
                float3 edgeDist = 0.5 - abs(positionOS);
                clip(edgeDist);

                // Edge Mask for smooth transition
                float edgeMask = smoothstep(0, _EdgeSoftness, edgeDist.x) * 
                                 smoothstep(0, _EdgeSoftness, edgeDist.y) * 
                                 smoothstep(0, _EdgeSoftness, edgeDist.z);

                // Normal Clipping (Fixes "negative axis" / back-side projection)
                // Reconstruct normal from depth derivatives
                float3 normalWS = normalize(cross(ddy(positionWS), ddx(positionWS)));
                float3 normalOS = TransformWorldToObjectDir(normalWS);

                // UVs and Basis based on Projection Axis
                float2 decalUV = 0;

                if (_ProjectionAxis < 0.5) // X Axis
                {
                    decalUV = positionOS.zy + 0.5;
                    clip(normalOS.x - 0.1);
                }
                else if (_ProjectionAxis < 1.5) // Y Axis
                {
                    decalUV = positionOS.xz + 0.5;
                    clip(normalOS.y - 0.1);
                }
                else // Z Axis
                {
                    decalUV.x = 0.5 - positionOS.x;
                    decalUV.y = positionOS.y + 0.5;
                    clip(normalOS.z - 0.1);
                }

                decalUV = decalUV * _BaseMap_ST.xy + _BaseMap_ST.zw;

                // Animated Caustics
                float time = _Time.y * _CausticSpeed;
                float2 uv1 = decalUV * _CausticScale + float2(time, time * 0.6);
                float2 uv2 = decalUV * _CausticScale * 0.9 - float2(time * 0.4, time * 0.8);

                // Sample with Chromatic Aberration
                float3 c1, c2;
                c1.r = SAMPLE_TEXTURE2D(_BaseMap, sampler_BaseMap, uv1 + float2(_CausticRGBOffset, 0)).r;
                c1.g = SAMPLE_TEXTURE2D(_BaseMap, sampler_BaseMap, uv1).g;
                c1.b = SAMPLE_TEXTURE2D(_BaseMap, sampler_BaseMap, uv1 - float2(_CausticRGBOffset, 0)).b;

                c2.r = SAMPLE_TEXTURE2D(_BaseMap, sampler_BaseMap, uv2 + float2(_CausticRGBOffset, 0)).r;
                c2.g = SAMPLE_TEXTURE2D(_BaseMap, sampler_BaseMap, uv2).g;
                c2.b = SAMPLE_TEXTURE2D(_BaseMap, sampler_BaseMap, uv2 - float2(_CausticRGBOffset, 0)).b;

                // Combine layers using min for sharp caustic lines
                float3 caustic = min(c1, c2);
                
                // Color Adjustments
                float3 color = caustic * _BaseColor.rgb;
                
                // Brightness
                color *= _Brightness;
                
                // Saturation
                float luma = dot(color, float3(0.2126, 0.7152, 0.0722));
                color = lerp(luma.xxx, color, _Saturation);
                
                // Contrast
                color = pow(max(color, 0.0), _Contrast);

                float alpha = (caustic.r + caustic.g + caustic.b) / 3.0;
                alpha *= _DecalOpacity * edgeMask;

                // Output to DBuffer
                output.outDBuffer0 = float4(color, alpha);

                return output;
            }
            ENDHLSL
        }
    }
    FallBack "Hidden/Universal Render Pipeline/FallbackError"
}
