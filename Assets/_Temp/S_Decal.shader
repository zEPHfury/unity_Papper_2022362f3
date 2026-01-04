Shader "Custom/URPDecalProjector"
{
    Properties
    {
        [Header(Basic Surface)]
        [Space(5)]
        [MainTexture] _BaseMap("基础贴图 (Albedo)", 2D) = "white" {}
        [MainColor]   _BaseColor("基础颜色 (Tint)", Color) = (1, 1, 1, 1)
        _BaseColorBrightness("基础颜色亮度", Range(0.0, 2.0)) = 1.0
        _BaseColorSaturation("基础颜色饱和度", Range(0.0, 2.0)) = 1.0
        _AlbedoIntensity("颜色强度补偿", Range(1.0, 5.0)) = 1.0
        
        [Space(10)]
        _Smoothness("光滑度", Range(0.0, 1.0)) = 0.5
        _Metallic("金属度", Range(0.0, 1.0)) = 0.0
        
        [Space(15)]
        [Header(Normal Map)]
        [Space(5)]
        [Toggle(_NORMALMAP)] _UseNormalMap("启用法线贴图", Float) = 0
        [NoScaleOffset] _BumpMap("法线贴图", 2D) = "bump" {}
        _BumpScale("法线强度", Range(0.0, 2.0)) = 1.0

        [Space(15)]
        [Header(Emission)]
        [Space(5)]
        [Toggle(_EMISSION)] _UseEmission("启用自发光", Float) = 0
        _EmissionMap("自发光贴图", 2D) = "white" {}
        [HDR] _EmissionColor("自发光颜色", Color) = (0,0,0)

        [Space(15)]
        [Header(Advanced)]
        [Space(5)]
        [Enum(UnityEngine.Rendering.CullMode)] _Cull("剔除模式", Float) = 1 // Front for Decal Projector
        
        // Decal Projector 内部属性
        [HideInInspector] _DecalMeshBiasType("Mesh Bias Type", Float) = 0
        [HideInInspector] _DecalMeshBiasValue("Mesh Bias Value", Float) = 0
    }

    SubShader
    {
        Tags 
        { 
            "RenderPipeline" = "UniversalPipeline"
            "Queue" = "Transparent"
            "RenderType" = "Transparent"
        }

        HLSLINCLUDE
        #include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/Core.hlsl"
        #include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/DeclareDepthTexture.hlsl"
        #include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/DeclareNormalsTexture.hlsl"
        #include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/Lighting.hlsl"
        #include "Packages/com.unity.render-pipelines.core/ShaderLibrary/CommonMaterial.hlsl"

        CBUFFER_START(UnityPerMaterial)
            float4 _BaseMap_ST;
            half4 _BaseColor;
            half _BaseColorBrightness;
            half _BaseColorSaturation;
            half _AlbedoIntensity;
            half _Smoothness;
            half _Metallic;
            half _BumpScale;
            half4 _EmissionColor;
        CBUFFER_END

        TEXTURE2D(_BaseMap);    SAMPLER(sampler_BaseMap);
        TEXTURE2D(_BumpMap);    SAMPLER(sampler_BumpMap);
        TEXTURE2D(_EmissionMap); SAMPLER(sampler_EmissionMap);

        struct DBufferOutput
        {
            half4 outDBuffer0 : SV_Target0; // Albedo (RGB), Alpha (A)
            half4 outDBuffer1 : SV_Target1; // Normal (RGB), Alpha (A)
            half4 outDBuffer2 : SV_Target2; // Metallic (R), Occlusion (G), Smoothness (B), Alpha (A)
        };

        // 从深度重建对象空间位置
        float3 GetPositionOS(float2 screenUV)
        {
            float depth = SampleSceneDepth(screenUV);
            // 重建世界空间位置
            float3 positionWS = ComputeWorldSpacePosition(screenUV, depth, UNITY_MATRIX_I_VP);
            // 转换到对象空间 (投影盒空间)
            float3 positionOS = TransformWorldToObject(positionWS);
            return positionOS;
        }
        ENDHLSL

        // -----------------------------------------------------------------------
        // Pass 1: DBufferProjector (DBuffer 模式)
        // -----------------------------------------------------------------------
        Pass
        {
            Name "DBufferProjector"
            Tags { "LightMode" = "DBufferProjector" }

            ZWrite Off
            ZTest Greater
            Cull [_Cull]

            // DBuffer 混合状态
            Blend 0 SrcAlpha OneMinusSrcAlpha, One OneMinusSrcAlpha
            Blend 1 SrcAlpha OneMinusSrcAlpha, One OneMinusSrcAlpha
            Blend 2 SrcAlpha OneMinusSrcAlpha, One OneMinusSrcAlpha

            HLSLPROGRAM
            #pragma vertex vert
            #pragma fragment frag
            #pragma shader_feature_local _NORMALMAP
            #pragma multi_compile_instancing

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
            };

            Varyings vert(Attributes input)
            {
                Varyings output;
                UNITY_SETUP_INSTANCE_ID(input);
                UNITY_TRANSFER_INSTANCE_ID(input, output);
                output.positionCS = TransformObjectToHClip(input.positionOS.xyz);
                output.screenPos = ComputeScreenPos(output.positionCS);
                return output;
            }

            DBufferOutput frag(Varyings input)
            {
                UNITY_SETUP_INSTANCE_ID(input);
                float2 screenUV = input.screenPos.xy / input.screenPos.w;
                float3 positionOS = GetPositionOS(screenUV);
                
                // 裁剪掉投影盒外的像素 (单位立方体 [-0.5, 0.5])
                clip(0.5 - abs(positionOS));

                // 生成 UV (使用 XZ 平面投影)
                float2 uv = positionOS.xz + 0.5;
                uv = TRANSFORM_TEX(uv, _BaseMap);

                half4 albedoSample = SAMPLE_TEXTURE2D(_BaseMap, sampler_BaseMap, uv);
                half3 albedo = albedoSample.rgb * _BaseColor.rgb * _BaseColorBrightness * _AlbedoIntensity;
                
                // 饱和度处理
                half luminance = dot(albedo, half3(0.2126h, 0.7152h, 0.0722h));
                albedo = lerp(luminance.xxx, albedo, _BaseColorSaturation);
                
                half alpha = albedoSample.a * _BaseColor.a;

                DBufferOutput output;
                output.outDBuffer0 = half4(albedo, alpha);
                
                #if defined(_NORMALMAP)
                    half3 normalTS = UnpackNormalScale(SAMPLE_TEXTURE2D(_BumpMap, sampler_BumpMap, uv), _BumpScale);
                    output.outDBuffer1 = half4(normalTS * 0.5 + 0.5, alpha);
                #else
                    output.outDBuffer1 = half4(0.5, 0.5, 1, 0);
                #endif

                output.outDBuffer2 = half4(_Metallic, 1.0, _Smoothness, alpha);
                
                return output;
            }
            ENDHLSL
        }

        // -----------------------------------------------------------------------
        // Pass 2: DecalProjector (Screen Space 模式)
        // -----------------------------------------------------------------------
        Pass
        {
            Name "DecalProjector"
            Tags { "LightMode" = "DecalProjector" }

            ZWrite Off
            ZTest Greater
            Cull [_Cull]
            Blend SrcAlpha OneMinusSrcAlpha

            HLSLPROGRAM
            #pragma vertex vert
            #pragma fragment frag
            #pragma shader_feature_local _NORMALMAP
            #pragma shader_feature_local _EMISSION
            
            #pragma multi_compile _ _MAIN_LIGHT_SHADOWS _MAIN_LIGHT_SHADOWS_CASCADE _MAIN_LIGHT_SHADOWS_SCREEN
            #pragma multi_compile _ _ADDITIONAL_LIGHTS
            #pragma multi_compile_fragment _ _ADDITIONAL_LIGHT_SHADOWS
            #pragma multi_compile_fragment _ _SHADOWS_SOFT
            #pragma multi_compile_fog
            #pragma multi_compile_instancing

            struct Attributes
            {
                float4 positionOS : POSITION;
                UNITY_VERTEX_INPUT_INSTANCE_ID
            };

            struct Varyings
            {
                float4 positionCS : SV_POSITION;
                float4 screenPos : TEXCOORD0;
                float fogCoord : TEXCOORD1;
                UNITY_VERTEX_INPUT_INSTANCE_ID
            };

            Varyings vert(Attributes input)
            {
                Varyings output;
                UNITY_SETUP_INSTANCE_ID(input);
                UNITY_TRANSFER_INSTANCE_ID(input, output);
                output.positionCS = TransformObjectToHClip(input.positionOS.xyz);
                output.screenPos = ComputeScreenPos(output.positionCS);
                output.fogCoord = ComputeFogFactor(output.positionCS.z);
                return output;
            }

            half4 frag(Varyings input) : SV_Target
            {
                UNITY_SETUP_INSTANCE_ID(input);
                float2 screenUV = input.screenPos.xy / input.screenPos.w;
                float3 positionOS = GetPositionOS(screenUV);
                
                clip(0.5 - abs(positionOS));

                float2 uv = positionOS.xz + 0.5;
                uv = TRANSFORM_TEX(uv, _BaseMap);

                half4 albedoSample = SAMPLE_TEXTURE2D(_BaseMap, sampler_BaseMap, uv);
                half3 albedo = albedoSample.rgb * _BaseColor.rgb * _BaseColorBrightness * _AlbedoIntensity;
                half luminance = dot(albedo, half3(0.2126h, 0.7152h, 0.0722h));
                albedo = lerp(luminance.xxx, albedo, _BaseColorSaturation);
                half alpha = albedoSample.a * _BaseColor.a;

                // 准备 SurfaceData
                SurfaceData surfaceData = (SurfaceData)0;
                surfaceData.albedo = albedo;
                surfaceData.metallic = _Metallic;
                surfaceData.smoothness = _Smoothness;
                surfaceData.alpha = alpha;
                surfaceData.occlusion = 1.0;
                
                #if defined(_NORMALMAP)
                    surfaceData.normalTS = UnpackNormalScale(SAMPLE_TEXTURE2D(_BumpMap, sampler_BumpMap, uv), _BumpScale);
                #else
                    surfaceData.normalTS = half3(0, 0, 1);
                #endif

                #if defined(_EMISSION)
                    surfaceData.emission = SAMPLE_TEXTURE2D(_EmissionMap, sampler_EmissionMap, uv).rgb * _EmissionColor.rgb;
                #endif

                // 准备 InputData
                InputData inputData = (InputData)0;
                float3 positionWS = TransformObjectToWorld(positionOS);
                inputData.positionWS = positionWS;
                
                // 从场景法线贴图获取表面法线
                half3 normalWS = SampleSceneNormals(screenUV);
                
                // 计算切线空间到世界空间的变换 (简单投影)
                half3 tangentWS = TransformObjectToWorldDir(half3(1, 0, 0));
                half3 bitangentWS = TransformObjectToWorldDir(half3(0, 0, 1));
                half3 normalWS_Decal = TransformObjectToWorldDir(half3(0, 1, 0));
                half3x3 tangentToWorld = half3x3(tangentWS, bitangentWS, normalWS_Decal);
                
                inputData.normalWS = TransformTangentToWorld(surfaceData.normalTS, tangentToWorld);
                inputData.normalWS = NormalizeNormalPerPixel(inputData.normalWS);
                inputData.viewDirectionWS = GetWorldSpaceNormalizeViewDir(positionWS);
                inputData.shadowCoord = TransformWorldToShadowCoord(positionWS);
                inputData.bakedGI = SampleSH(inputData.normalWS);
                inputData.normalizedScreenSpaceUV = screenUV;

                half4 color = UniversalFragmentPBR(inputData, surfaceData);
                color.rgb = MixFog(color.rgb, input.fogCoord);
                color.a = alpha;

                return color;
            }
            ENDHLSL
        }
    }
    FallBack "Hidden/Universal Render Pipeline/FallbackError"
}
