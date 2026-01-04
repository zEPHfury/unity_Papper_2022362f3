Shader "zEPH/Standard Unlit Shader"
{
    // ---------------------------------------------------------------------------
    // Properties 属性块
    // ---------------------------------------------------------------------------
    // 定义了材质面板 (Inspector) 中所有可调节的参数。
    Properties
    {
        [Header(Main Maps)] // 在Inspector中显示一个标题，用于分组
        [MainTexture] _BaseMap("基础贴图 (RGB)", 2D) = "white" {} // 主贴图，通常是颜色贴图
        [MainColor]   _BaseColor("基础颜色 (Tint)", Color) = (1, 1, 1, 1) // 用于给贴图上色的颜色

        [Header(Alpha Clipping)] // 透明裁剪分组
        [Toggle(_ALPHACLIP_ON)] _UseAlphaClip("开启Alpha裁剪", Float) = 0 // 一个开关，用于启用或禁用Alpha裁剪
        _Cutoff("Alpha裁剪阈值", Range(0.0, 1.0)) = 0.5 // Alpha值低于此阈值的像素将被丢弃

        // Unity内置的渲染设置，通常保持默认即可
        [HideInInspector] _Cull ("Culling", Int) = 2 // 剔除模式 (2 = Back, 1 = Front, 0 = Off)
    }

    // ---------------------------------------------------------------------------
    // SubShader 子着色器
    // ---------------------------------------------------------------------------
    // 一个Shader可以有多个SubShader，Unity会从上到下选择第一个能在目标硬件上运行的。
    SubShader
    {
        // Tags 标签: 告诉渲染管线如何以及何时渲染这个Shader。
        // "RenderPipeline" = "UniversalPipeline" -> 明确指定此SubShader用于URP。
        // "RenderType" = "Opaque" -> 将物体归类为不透明物体。如果开启Alpha裁剪，通常会改为"TransparentCutout"。
        // "Queue" = "Geometry" -> 决定渲染顺序，"Geometry"是默认值，用于大部分不透明物体。
        Tags 
        { 
            "RenderPipeline" = "UniversalPipeline" 
            "RenderType" = "Opaque" 
            "Queue" = "Geometry" 
        }

        // ---------------------------------------------------------------------------
        // Pass 通道
        // ---------------------------------------------------------------------------
        // SubShader包含一个或多个Pass。每个Pass代表一次完整的绘制调用。
        HLSLINCLUDE
        #include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/Core.hlsl" // URP 核心库
        #include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/SurfaceData.hlsl"
        #include "Packages/com.unity.render-pipelines.core/ShaderLibrary/CommonMaterial.hlsl"
        ENDHLSL
        Pass
        {
            // Pass的名称，便于调试和识别。
            Name "ForwardLit"

            // Pass的标签，"LightMode" 告诉URP这个Pass在哪个渲染阶段起作用。
            // "UniversalForward" 是URP前向渲染的主Pass。Unlit Shader也在这里渲染。
            Tags { "LightMode" = "UniversalForward" }

            // 设置渲染状态
            Cull [_Cull]    // 设置剔除模式，由材质的_Cull属性控制

// >>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>

            // ================== HLSL代码开始 ==================
            HLSLPROGRAM
            // 目标Shader模型，3.5是URP的推荐值，功能和性能较好。
            #pragma target 3.5

            // 定义顶点着色器和片元着色器的函数名。
            #pragma vertex vert
            #pragma fragment frag

            // --------------------- 关键字 ---------------------
            // #pragma shader_feature_local <关键字名>
            // 定义一个本地关键字。这会创建两个Shader变体：一个定义了_ALPHACLIP_ON，一个没有。
            // Unity会根据材质上_UseAlphaClip属性的值来选择使用哪个变体。
            #pragma shader_feature_local_fragment _ALPHACLIP_ON

            // --------------------- 包含文件 ---------------------
            // 引入URP的核心库，里面包含了许多有用的函数和定义，如坐标转换函数。
            #include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/Core.hlsl"

            // --------------------- CBUFFER ---------------------
            // CBUFFER_START/END 是URP提供的宏，用于定义材质属性缓冲区。
            // 这对于SRP Batcher合批优化至关重要。
            // 这里定义的变量必须与Properties块中的变量名完全一致。
            CBUFFER_START(UnityPerMaterial)
                float4 _BaseMap_ST;     // "_ST"后缀是Unity的约定，ST代表Scale(缩放)和Translate(平移)。
                                        // .xy是缩放值(Tiling)，.zw是偏移值(Offset)。
                half4 _BaseColor;       // 对应 _BaseColor 属性
                half _Cutoff;           // 对应 _Cutoff 属性
            CBUFFER_END

            // 声明纹理。这些变量名也必须与Properties块中的一致。
            TEXTURE2D(_BaseMap);
            SAMPLER(sampler_BaseMap); // 定义_BaseMap纹理对应的采样器

             // --------------------- 结构体 ---------------------
            // Attributes: 顶点着色器的输入结构体。
            // 它定义了从模型网格(Mesh)中读取哪些顶点数据。
            // 顶点着色器 (Vertex Shader)需要的、且来源是3D模型网格 (Mesh) 的数据，以 struct Attributes 定义的结构，从顶点缓冲区 (Vertex Buffer) 传入顶点着色器
            struct Attributes
            {
                float4 positionOS   : POSITION;     // 顶点在模型空间(Object Space)的位置
                float2 texcoord0    : TEXCOORD0;    // 顶点的第一套UV坐标
            };

            // Varyings: 顶点着色器的输出，同时也是片元着色器的输入。
            // 它负责将数据从顶点着色器“传递”到片元着色器。
            // GPU会对这些数据进行插值。
            struct Varyings
            {
                float4 positionHCS  : SV_POSITION;  // 顶点在齐次裁剪空间(Homogeneous Clip Space)的位置，这是必须的输出
                float2 uv           : TEXCOORD0;    // 传递给片元着色器的UV坐标
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
                Varyings OUT; // 创建一个输出结构体实例

                // GetVertexPositionInputs是URP推荐的函数，用于获取顶点在不同空间下的位置。
                // 它比旧的 TransformObjectToHClip 更健壮，尤其是在处理VR/XR时。
                VertexPositionInputs positionInputs = GetVertexPositionInputs(IN.positionOS.xyz);
                OUT.positionHCS = positionInputs.positionCS; // 将计算好的裁剪空间位置存入输出

                // TRANSFORM_TEX 是一个Unity内置宏，用于处理UV的缩放和偏移。
                // 它等价于: OUT.uv = IN.texcoord0 * _BaseMap_ST.xy + _BaseMap_ST.zw;
                OUT.uv = TRANSFORM_TEX(IN.texcoord0, _BaseMap);

                return OUT; // 返回填充好的输出结构体
            }

            // ---------------------------------------------------------------------------
            // Fragment Shader 片元着色器
            // ---------------------------------------------------------------------------
            // : SV_Target 语义告诉GPU，这个函数的返回值将作为渲染目标(屏幕)的颜色。
            half4 frag(Varyings IN) : SV_Target
            {
                // SAMPLE_TEXTURE2D 是URP提供的宏，用于对纹理进行采样。
                half4 baseMapColor = SAMPLE_TEXTURE2D(_BaseMap, sampler_BaseMap, IN.uv);

                // 将贴图颜色与我们设置的颜色属性相乘，实现Tint效果。
                half3 finalColor = baseMapColor.rgb * _BaseColor.rgb;
                half finalAlpha = baseMapColor.a * _BaseColor.a;

                // 如果 _ALPHACLIP_ON 关键字被启用...
                #ifdef _ALPHACLIP_ON
                    // AlphaTest是URP在Core.hlsl中定义的辅助函数。
                    // 如果最终的alpha值小于_Cutoff，它会调用clip(-1)，丢弃这个片元(像素)。
                    AlphaTest(finalAlpha, _Cutoff);
                #endif

                // 返回最终的颜色和Alpha值。
                return half4(finalColor, finalAlpha);
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