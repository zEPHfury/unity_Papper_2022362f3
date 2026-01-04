Shader "Shader/Template"
{
    Properties
    {
        // -----------------------------------------------------------------------
        // 属性定义区域 (Properties)
        // 暴露给 Unity 编辑器材质面板的变量
        // -----------------------------------------------------------------------
        _MainTex ("Main Texture", 2D) = "white" {}              // 主纹理，默认白色
        _Color ("Color", Color) = (1,1,1,1)                     // 颜色属性，默认白色
    }

    SubShader
    {
        // -----------------------------------------------------------------------
        // SubShader 标签 (Tags)
        // 设置渲染管线、渲染类型和队列
        // -----------------------------------------------------------------------
        Tags
        {
            "RenderPipeline" = "UniversalPipeline"      // 指定渲染管线为 URP (Universal Render Pipeline)
            "RenderType" = "Opaque"                     // 渲染类型: Opaque (不透明) / Transparent (透明)
            "Queue" = "Geometry"                        // 渲染队列: Geometry (2000, 不透明物体默认)
        }

        LOD 100 // Shader 的细节等级 (Level of Detail)

        // -----------------------------------------------------------------------
        // Pass: 主渲染通道
        // -----------------------------------------------------------------------
        Pass
        {
            Name "UniversalForward"     // Pass 名称，用于 Frame Debugger 调试
            Tags 
            { 
                "LightMode" = "UniversalForward"    // 光照模式: URP 的主光照 Pass
            }

            // -----------------------------------------------------------------------
            // 渲染状态 (Render State)
            // -----------------------------------------------------------------------
            Cull Back           // 剔除模式: Back (剔除背面), Front (剔除正面), Off (不剔除)
            ZWrite On           // 深度写入: On (开启), Off (关闭 - 通常用于半透明)
            ZTest LEqual        // 深度测试: LEqual (小于等于), Always (总是通过) 等

            HLSLPROGRAM // 开始 HLSL 代码块

            // -----------------------------------------------------------------------
            // 编译指令 (Pragmas)
            // -----------------------------------------------------------------------
            #pragma vertex vert             // 指定顶点着色器函数名为 vert
            #pragma fragment frag           // 指定片元着色器函数名为 frag
            
            // -----------------------------------------------------------------------
            // 包含文件 (Includes)
            // 引入 URP 提供的核心库文件
            // -----------------------------------------------------------------------
            #include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/Core.hlsl" // 核心库: 包含变换矩阵、常用数学函数等
            #include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/Lighting.hlsl" // 光照库: 包含光照计算函数

            // -----------------------------------------------------------------------
            // 变量声明 (Variables)
            // 必须与 Properties 中的名称一致
            // -----------------------------------------------------------------------
            
            // 纹理和采样器
            TEXTURE2D(_MainTex);                // 声明 2D 纹理资源宏
            SAMPLER(sampler_MainTex);           // 声明对应的采样器宏

            // 常量缓冲区 (CBUFFER)
            // 为了支持 SRP Batcher (合批优化)，材质属性必须定义在 CBUFFER 中
            CBUFFER_START(UnityPerMaterial)
                float4 _MainTex_ST;             // 纹理的 Tiling (XY) 和 Offset (ZW) - Unity 自动传入
                float4 _Color;                  // 颜色属性
            CBUFFER_END

            // -----------------------------------------------------------------------
            // 结构体定义 (Structs)
            // -----------------------------------------------------------------------
            
            // 顶点着色器输入结构体 (Attributes)
            // 从模型网格 (Mesh) 获取的数据
            struct Attributes
            {
                float4 positionOS   : POSITION;     // 顶点位置 (对象空间 Object Space)
                float2 uv           : TEXCOORD0;    // 第一套纹理坐标
                float3 normalOS     : NORMAL;       // 顶点法线 (对象空间) - 可选，用于光照计算
            };

            // 顶点着色器输出 / 片元着色器输入结构体 (Varyings)
            // 从顶点着色器传递给片元着色器的数据
            struct Varyings
            {
                float4 positionCS   : SV_POSITION;  // 顶点位置 (裁剪空间 Clip Space) - 系统必须
                float2 uv           : TEXCOORD0;    // 纹理坐标
                float3 normalWS     : TEXCOORD1;    // 顶点法线 (世界空间 World Space) - 可选
            };

            // -----------------------------------------------------------------------
            // 顶点着色器 (Vertex Shader)
            // 处理每个顶点，主要负责坐标变换
            // -----------------------------------------------------------------------
            Varyings vert(Attributes input)
            {
                Varyings output = (Varyings)0;  // 初始化输出结构体

                // 1. 顶点位置变换: 对象空间 (Object Space) -> 裁剪空间 (Clip Space)
                // GetVertexPositionInputs 是 Core.hlsl 提供的辅助函数，计算各种空间的坐标
                VertexPositionInputs vertexInput = GetVertexPositionInputs(input.positionOS.xyz);
                output.positionCS = vertexInput.positionCS;

                // 2. 纹理坐标变换
                // TRANSFORM_TEX 宏计算: input.uv * _MainTex_ST.xy + _MainTex_ST.zw
                output.uv = TRANSFORM_TEX(input.uv, _MainTex);

                // 3. 法线变换: 对象空间 -> 世界空间
                output.normalWS = TransformObjectToWorldNormal(input.normalOS);

                return output; // 返回处理后的数据
            }

            // -----------------------------------------------------------------------
            // 片元着色器 (Fragment Shader)
            // 处理每个像素 (片元)，计算最终颜色
            // -----------------------------------------------------------------------
            half4 frag(Varyings input) : SV_Target // SV_Target: 输出到渲染目标
            {
                // 1. 纹理采样
                // SAMPLE_TEXTURE2D 宏: 使用采样器 sampler_MainTex 对纹理 _MainTex 在 input.uv 处进行采样
                half4 texColor = SAMPLE_TEXTURE2D(_MainTex, sampler_MainTex, input.uv);

                // 2. 光照计算 (Lambert 漫反射)
                half3 normalWS = normalize(input.normalWS); // 归一化法线
                Light mainLight = GetMainLight();           // 获取主光源 (需包含 Lighting.hlsl)
                
                // 计算漫反射强度: 法线与光照方向的点积 (N dot L)
                // saturate 确保结果在 [0, 1] 之间，避免背光面变黑
                half NdotL = saturate(dot(normalWS, mainLight.direction));
                
                // 漫反射颜色 = 光源颜色 * 强度
                half3 diffuse = mainLight.color * NdotL;

                // 新增: 环境光计算
                // SampleSH 函数采样球谐光照 (Spherical Harmonics)，获取环境光
                // 这会根据法线方向获取来自天空盒或环境设置的颜色
                half3 ambient = SampleSH(normalWS);

                // 3. 颜色混合
                // 最终光照 = 漫反射 (直接光) + 环境光 (间接光)
                half3 lighting = diffuse + ambient;

                // 最终颜色 = 纹理颜色 * 材质颜色 * 最终光照
                half4 finalColor = texColor * _Color * half4(lighting, 1.0);

                return finalColor; // 输出最终颜色 (RGBA)
            }

            ENDHLSL // 结束 HLSL 代码块
        }
    }
    
    // -----------------------------------------------------------------------
    // Fallback
    // 如果上述 SubShader 都不支持，使用该 Shader (通常用于阴影投射等)
    // -----------------------------------------------------------------------
    FallBack "Hidden/Universal Render Pipeline/FallbackError"
}
