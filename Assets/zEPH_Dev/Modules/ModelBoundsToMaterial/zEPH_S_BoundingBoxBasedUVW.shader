Shader "zEPH/BoundingBoxBasedUVW_Dev"
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
        _BoundsMin("Bounds Min", Vector) = (0, 0, 0, 0)
        _BoundsMax("Bounds Max", Vector) = (1, 1, 1, 1)

        // [Header(Alpha Clipping)] // 透明裁剪分组
        // [Toggle(_ALPHACLIP_ON)] _UseAlphaClip("开启Alpha裁剪", Float) = 0 // 一个开关，用于启用或禁用Alpha裁剪
        // _Cutoff("Alpha裁剪阈值", Range(0.0, 1.0)) = 0.5 // Alpha值低于此阈值的像素将被丢弃

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

        Pass
        {
            // Pass的名称，便于调试和识别。
            Name "ForwardLit"

            // Pass的标签，"LightMode" 告诉URP这个Pass在哪个渲染阶段起作用。
            // "UniversalForward" 是URP前向渲染的主Pass。Unlit Shader也在这里渲染。
            Tags { "LightMode" = "UniversalForward" }

            // 设置渲染状态
            Cull Off    // 设置剔除模式，由材质的_Cull属性控制

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
                float4 _BoundsMin;
                float4 _BoundsMax;
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
                float3 positionOS   : TEXCOORD1;    // 传递模型空间坐标用于遮罩
            };

            // ---------------------------------------------------------------------------
            // Wind function from user
            float3 Wind(float3 additionalWPO, float3 worldVertPos, float windIntensity, float windSpeed)
            {
                float speed = _Time.y * 0.1 * windSpeed * -0.5;
                float3 speedX = float3(1.0, 0.0, 0.0) * speed;
                speedX = (worldVertPos / 1024) + speedX;
                speedX = abs(frac(speedX + 0.5) * 2.0 -1.0);
                speedX = (3.0 - (2.0 * speedX)) * speedX * speedX;
                float d = dot(float3(1.0, 0.0, 0.0), speedX);

                float3 speedY = (worldVertPos / 200) + speed;
                speedY = abs(frac(speedY + 0.5) * 2.0 -1.0);
                speedY = (3.0 - (2.0 * speedY)) * speedY * speedY;
                float distanceY = distance(speedY, float3(0.0, 0.0, 0.0));
                float angle = d + distanceY;
                float3 point0 = additionalWPO + float3(0.0, -10.0, 0.0);
                float3 rotatePos = additionalWPO - point0;
                rotatePos = mul(float3x3(cos(angle), -sin(angle), 0.0,
                sin(angle), cos(angle), 0.0, 
                0.0, 0.0, 1.0), rotatePos);
                rotatePos += point0;
                return (rotatePos * windIntensity * 0.01) + additionalWPO;
            }

            // Example function to use Wind
            void ExampleWindUsage_float(float3 additionalWPO, float3 worldVertPos, float windIntensity, float windSpeed, out float3 Out)
            {
                Out = Wind(additionalWPO, worldVertPos, windIntensity, windSpeed);
            }
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
                VertexPositionInputs positionInputs = GetVertexPositionInputs(IN.positionOS.xyz);
                OUT.positionHCS = positionInputs.positionCS;
                OUT.uv = TRANSFORM_TEX(IN.texcoord0, _BaseMap);
                OUT.positionOS = IN.positionOS.xyz;
                return OUT;
            }

            void BoundingBoxBasedUVW_float(float3 PositionOS, float3 BoundsMin, float3 BoundsMax, out float3 Out)
            {
                float3 size = BoundsMax - BoundsMin;
                // Avoid division by zero
                size = max(size, 0.00001);
                Out = (PositionOS - BoundsMin) / size;
            }
            // ---------------------------------------------------------------------------
            // Fragment Shader 片元着色器
            // ---------------------------------------------------------------------------
            // : SV_Target 语义告诉GPU，这个函数的返回值将作为渲染目标(屏幕)的颜色。
            half4 frag(Varyings IN) : SV_Target
            {
                // 直接输出模型本地空间的垂直0-1遮罩（z方向）
                float3 uvw;
                BoundingBoxBasedUVW_float(IN.positionOS.xyz, _BoundsMin.xyz, _BoundsMax.xyz, uvw);
                float mask = saturate(uvw.y);

                // 颜色做0-1-0-1平滑循环（正弦波）
                float t = 0.5 * (sin(_Time.y * 1.0 * 3.1415926) + 1.0); // t在0-1之间平滑循环
                float3 color = lerp(float3(0,0,0), float3(1,1,1), t); // 黑到白渐变
                // return half4(mask * color, 1.0);
                return half4 (mask, mask,mask,1.0);
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

            // 包含 URP 标准 DepthNormalsPass 实现
            // 注意：它会调用我们在 _Surface.hlsl 中定义的 SampleAlbedoAlpha, SampleNormal, Alpha 函数
            #include "Packages/com.unity.render-pipelines.core/ShaderLibrary/CommonMaterial.hlsl"
            #include "Packages/com.unity.render-pipelines.universal/Shaders/DepthNormalsPass.hlsl"
            
            ENDHLSL
        }
        
    }

    // Fallback: 如果以上所有SubShader都无法在目标硬件上运行，则使用这个内置的Fallback Shader。
    // 这对于保证在旧设备上不出错很重要。
    Fallback "Universal Render Pipeline/Unlit"
}