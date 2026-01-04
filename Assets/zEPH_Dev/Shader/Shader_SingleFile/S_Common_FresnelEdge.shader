Shader "zEPH/Fresnel Edge"
{
    Properties
    {
        _FresnelColor ("Fresnel Color", Color) = (1,1,1,1)
        _FresnelPower ("Fresnel Power", Range(0.1,10)) = 1.0
        _FresnelIntensity ("Fresnel Intensity", Range(0,5)) = 1.0
    }

    SubShader
    {
        Tags 
        { 
            "RenderPipeline" = "UniversalPipeline" 
            "RenderType" = "Opaque" 
            "Queue" = "Geometry" 
        }
        Pass
        {
            Name "ForwardLit"
            Tags { "LightMode" = "UniversalForward" }

            // 设置渲染状态
            Cull [_Cull]    // 设置剔除模式，由材质的_Cull属性控制
            ZWrite On       // 启用深度写入

            HLSLPROGRAM
            // 目标Shader模型，3.5是URP的推荐值，功能和性能较好。
            #pragma target 3.5

            // 定义顶点着色器和片元着色器的函数名。
            #pragma vertex vert
            #pragma fragment frag

            // --------------------- 包含文件 ---------------------
            // 引入URP的核心库，里面包含了许多有用的函数和定义，如坐标转换函数。
            #include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/Core.hlsl"

            CBUFFER_START(UnityPerMaterial)
                half4 _FresnelColor;
                half _FresnelPower;
                half _FresnelIntensity;
            CBUFFER_END

            struct Attributes
            {
                float4 vertPositionOS : POSITION;
                float3 normalOS : NORMAL;
            };

            struct Varyings
            {
                float4 vertPositionH : SV_POSITION;
                float3 vertPositionWS : TEXCOORD0;
                float3 normalWS : TEXCOORD1;
            };

            // ---------------------------------------------------------------------------
            // Vertex Shader 顶点着色器
            // ---------------------------------------------------------------------------
            // *************** struct Attributes{} 是顶点着色器的输入结构， struct Varyings{}是顶点着色器的输出结构 ***************
            //                          返回值类型   函数名(参数类型 参数名)
            //                              ↓           ↓      ↓         ↓
            //                          Varyings     vert  (Attributes IN)

            Varyings vert(Attributes IN)
            {
                Varyings OUT;
                // 将对象空间的顶点位置转换为裁剪空间位置
                OUT.vertPositionH = TransformObjectToHClip(IN.vertPositionOS.xyz);
                
                // 获取世界空间位置
                OUT.vertPositionWS = TransformObjectToWorld(IN.vertPositionOS.xyz);
                
                // 获取世界空间法线
                OUT.normalWS = TransformObjectToWorldNormal(IN.normalOS);
                
                return OUT;
            }

            // ---------------------------------------------------------------------------
            // Fragment Shader 片元着色器
            // ---------------------------------------------------------------------------
            // : SV_Target 语义告诉GPU，这个函数的返回值将作为渲染目标(屏幕)的颜色。
            half4 frag(Varyings IN) : SV_Target
            {
                // 准备向量
                float3 normalWS = normalize(IN.normalWS);
                float3 viewDirWS = GetWorldSpaceViewDir(IN.vertPositionWS);
                viewDirWS = normalize(viewDirWS);

                // UE 算法实现:
                // 1. Dot(Camera Vector, PixelNormalWS)
                float NdotV = dot(normalWS, viewDirWS);

                // 2. 1 - x
                float fresnelBase = 1.0 - NdotV;

                // 3. Saturate
                fresnelBase = saturate(fresnelBase);

                // 4. Power (EdgePow) -> _FresnelPower
                float fresnel = pow(fresnelBase, _FresnelPower);

                // 5. Multiply (EdgeMul) -> _FresnelIntensity
                fresnel = fresnel * _FresnelIntensity;

                // 应用颜色
                float3 emission = _FresnelColor.rgb * fresnel;

                // 其余(Albedo, Metallic, Smoothness)为0。
                // 直接输出 Emission 颜色。
                return half4(emission, 1.0);
            }

             ENDHLSL
            // ================== HLSL代码结束 ==================

// >>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>
        }

                // =======================================================================
        // Pass 4: DepthNormals (深度法线 Pass)
        // 负责渲染深度和法线到 _CameraDepthNormalsTexture，用于 SSAO 等效果
        // =======================================================================
        Pass
        {
            Name "DepthNormals"
            Tags { "LightMode" = "DepthNormals" }

            ZWrite On
            ZTest LEqual
            Cull [_Cull]

            HLSLPROGRAM
            #pragma target 4.5
            #pragma vertex DepthNormalsVertex
            #pragma fragment DepthNormalsFragment

            #pragma shader_feature_local _NORMALMAP
            #pragma shader_feature_local _ALPHATEST_ON
            #pragma shader_feature_local _ALPHASOURCE_A
            #pragma multi_compile_instancing

            #include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/Core.hlsl"
            #include "Packages/com.unity.render-pipelines.core/ShaderLibrary/CommonMaterial.hlsl"

            // 包含 URP 标准 DepthNormalsPass 实现
            // 注意：它会调用我们在 _Surface.hlsl 中定义的 SampleAlbedoAlpha, SampleNormal, Alpha 函数
            #include "Packages/com.unity.render-pipelines.universal/Shaders/DepthNormalsPass.hlsl"
            
            ENDHLSL
        }

        
    }

    // Fallback: 如果以上所有SubShader都无法在目标硬件上运行，则使用这个内置的Fallback Shader。
    // 这对于保证在旧设备上不出错很重要。
    Fallback "Universal Render Pipeline/Unlit"
}