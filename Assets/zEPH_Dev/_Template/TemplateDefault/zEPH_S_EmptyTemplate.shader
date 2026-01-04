Shader "Custom/URP_Basic_Template"
{
    // 1. 属性块：这里定义的变量会显示在 Unity 的材质面板 Inspector 中
    Properties
    {
        _BaseColor ("Base Color", Color) = (1, 1, 1, 1)
        _MainTex ("Base Map", 2D) = "white" {}
    }

    SubShader
    {
        // 2. 标签：告诉 Unity 这个 Shader 属于 URP 管线，并且是不透明物体
        Tags 
        { 
            "RenderType" = "Opaque" 
            "RenderPipeline" = "UniversalPipeline" 
            "Queue" = "Geometry"
        }

        Pass
        {
            Name "ForwardLit"
            Tags { "LightMode" = "UniversalForward" } // 指定这是主渲染 Pass

            HLSLPROGRAM
            
            // 定义顶点和片元着色器的函数名
            #pragma vertex vert
            #pragma fragment frag

            // 3. 引用 URP 核心库
            // Core.hlsl 包含了常用的变换矩阵、数学函数等
            #include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/Core.hlsl"

            // 5. 声明变量与 SRP Batcher 兼容
            // 为了让 SRP Batcher 生效，所有材质属性必须包裹在 CBUFFER 中
            CBUFFER_START(UnityPerMaterial)
                float4 _BaseColor;
                float4 _MainTex_ST; // 纹理的 Tiling 和 Offset 数据
            CBUFFER_END

            // 纹理采样器通常定义在 CBUFFER 之外
            TEXTURE2D(_MainTex);
            SAMPLER(sampler_MainTex);

            // 4. 定义结构体
            
            // Attributes: 从模型网格(Mesh)获取的数据（输入给顶点着色器）
            struct Attributes
            {
                float4 positionOS : POSITION; // Object Space (模型空间) 顶点位置
                float2 uv         : TEXCOORD0;// UV 坐标
            };

            // Varyings: 从顶点着色器传递给片元着色器的数据
            struct Varyings
            {
                float4 positionHCS : SV_POSITION; // Homogeneous Clip Space (裁剪空间) 位置，必须有！
                float2 uv          : TEXCOORD0;
            };

            // 6. 顶点着色器 (Vertex Shader)
            // 任务：将顶点从模型空间转换到裁剪空间 (MVP 变换)
            Varyings vert(Attributes IN)
            {   
                Varyings OUT;

                // TransformObjectToHClip 是 URP Core.hlsl 提供的函数
                // 等同于 mul(GetWorldToHClipMatrix(), mul(GetObjectToWorldMatrix(), positionOS))
                OUT.positionHCS = TransformObjectToHClip(IN.positionOS.xyz);
                
                // 应用纹理的 Tiling 和 Offset
                OUT.uv = TRANSFORM_TEX(IN.uv, _MainTex);

                return OUT;
            }

            // 7. 片元着色器 (Fragment Shader)
            // 任务：计算最终像素颜色
            half4 frag(Varyings IN) : SV_Target
            {
                // 采样纹理颜色
                // SAMPLE_TEXTURE2D 是 URP 推荐的采样宏
                half4 texColor = SAMPLE_TEXTURE2D(_MainTex, sampler_MainTex, IN.uv);

                // 混合基础颜色
                return texColor * _BaseColor;
            }

            ENDHLSL
        }
    }
}