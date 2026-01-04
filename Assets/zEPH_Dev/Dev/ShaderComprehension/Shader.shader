Shader "Shader/Template"
{
    Properties
    {
        _MainTex ("Texture", 2D) = "white" {}
        _Color ("Color", Color) = (0.5,0.5,0.5,1)
    }
    SubShader
    {
        // 设置渲染状态
        Tags
        {
            "RenderPipeline" = "UniversalPipeline"      // 使用URP渲染管线，仅在URP管线下生效
            "RenderType"="Opaque"                       // 渲染类型: 不透明
            "Queue"="Geometry"                          // 渲染队列: 几何体（默认不透明物体队列）
        }     

        Pass
        {
            LOD 200     // 细节等级

            // -----------------------------------------------------------------------
            // 全局共享 HLSL 代码块
            // -----------------------------------------------------------------------
            HLSLINCLUDE

            #pragma vertex vert       // 顶点着色器入口函数
            #pragma fragment frag     // 片元着色器入口函数

            #include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/Core.hlsl"        // 引入URP核心库
            #include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/Lighting.hlsl"    // 引入URP光照库
            #include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/SurfaceData.hlsl" // 引入URP表面数据库
            #include "Packages/com.unity.render-pipelines.core/ShaderLibrary/CommonMaterial.hlsl"   // 引入通用材质库

            // 声明属性变量
            CBUFFER_START(UnityPerMaterial)
                float4 _Color;          // 颜色属性
            CBUFFER_END

            // 声明纹理采
            TEXTURE2D(_MainTex);    SAMPLER(sampler_MainTex);    // 纹理属性

            ENDHLSL
        }

    }
}
