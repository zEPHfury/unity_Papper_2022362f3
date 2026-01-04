Shader "Custom/URP_Water_Depth_Debug"
{
    // 属性定义：暴露给材质面板的变量
    Properties
    {
        _BaseColor ("Base Color", Color) = (1, 1, 1, 1) // 基础颜色
        _MainTex ("Base Map", 2D) = "white" {}          // 基础纹理

        [Header(Water Settings)]
        _ShallowColor ("Shallow Color", Color) = (0.5, 0.9, 1, 1)
        _DeepColor ("Deep Color", Color) = (0.0, 0.2, 0.5, 1)
        _DepthMaxDistance ("Depth Max Distance", Float) = 1.0
        _DepthExp ("Depth Exponential", Range(0.01, 10)) = 1.0
        _OpacityDepthDistance ("Opacity Depth Distance", Float) = 1.0
        _OpacityExp ("Opacity Exponential", Range(0.01, 10)) = 1.0
        _ViewCorrection ("View Angle Correction", Range(0, 1)) = 0.5
        _BaseOpacity ("Base Opacity", Range(0, 1)) = 1.0
        
        [Header(Distortion)]
        _BumpMap ("Normal Map", 2D) = "bump" {}
        _BumpScale ("Normal Scale", Float) = 1.0
        _DistortionStrength ("Distortion Strength", Range(0, 0.2)) = 0.05
        _Speed ("Speed (Layer1 XY, Layer2 XY)", Vector) = (0.1, 0.1, -0.05, 0.05)
        
        [Header(Reflection)]
        _ReflectionStrength ("Reflection Strength", Range(0, 1)) = 0.5
        _FresnelPower ("Fresnel Power", Range(0.1, 10)) = 5.0
    }

    SubShader
    {
        // 渲染标签设置
        Tags 
        { 
            "RenderType" = "Transparent"        // 渲染类型：透明
            "RenderPipeline" = "UniversalPipeline" // 管线：URP
            "Queue" = "Transparent"             // 渲染队列：透明（在不透明物体之后渲染）
        }

        Pass
        {
            Name "ForwardLit"
            Tags { "LightMode" = "UniversalForward" } // 光照模式：前向渲染

            // 渲染状态设置
            // Blend SrcAlpha OneMinusSrcAlpha // 关闭传统透明混合，改为手动混合背景以实现折射
            Blend One Zero                  // 输出最终颜色，不进行混合
            ZWrite Off                      // 关闭深度写入（半透明物体通常不写入深度）

            HLSLPROGRAM
            
            // 注册着色器函数
            #pragma vertex vert
            #pragma fragment frag

            // 包含库文件
            #include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/Core.hlsl"              // URP核心库
            #include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/DeclareDepthTexture.hlsl" // 深度纹理库
            #include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/DeclareOpaqueTexture.hlsl" // 场景颜色库(用于折射)
            #include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/Lighting.hlsl"            // 光照库(用于反射)

            // 材质属性缓冲区 (SRP Batcher 兼容)
            CBUFFER_START(UnityPerMaterial)
                float4 _BaseColor;
                float4 _MainTex_ST; // 纹理缩放偏移
                float4 _ShallowColor;
                float4 _DeepColor;
                float4 _Speed;
                float _DepthMaxDistance;
                float _DepthExp;
                float _OpacityDepthDistance;
                float _OpacityExp;
                float _ViewCorrection;
                float _BaseOpacity;
                float _BumpScale;
                float _DistortionStrength;
                float _ReflectionStrength;
                float _FresnelPower;
            CBUFFER_END

            // 纹理与采样器定义
            TEXTURE2D(_MainTex);
            SAMPLER(sampler_MainTex);
            TEXTURE2D(_BumpMap);
            SAMPLER(sampler_BumpMap);

            // 顶点着色器输入结构体
            struct Attributes
            {
                float4 positionOS : POSITION; // 模型空间顶点位置
                float2 uv         : TEXCOORD0;// UV坐标
                float3 normalOS   : NORMAL;   // 模型空间法线
                float4 tangentOS  : TANGENT;  // 模型空间切线
            };

            // 顶点到片元传递结构体
            struct Varyings
            {
                float4 positionHCS : SV_POSITION; // 裁剪空间位置
                float2 uv          : TEXCOORD0;   // UV坐标
                float4 screenPos   : TEXCOORD1;   // 屏幕空间位置（用于深度采样）
                float3 positionWS  : TEXCOORD3;   // 世界空间位置
                float3 normalWS    : TEXCOORD4;   // 世界空间法线
                float3 tangentWS   : TEXCOORD5;   // 世界空间切线
                float3 bitangentWS : TEXCOORD6;   // 世界空间副切线
            };

            // 顶点着色器
            Varyings vert(Attributes IN)
            {   
                Varyings OUT;

                // 坐标变换：模型空间 -> 裁剪空间
                OUT.positionHCS = TransformObjectToHClip(IN.positionOS.xyz);
                
                // 世界空间位置
                OUT.positionWS = TransformObjectToWorld(IN.positionOS.xyz);

                // UV变换：应用Tiling/Offset
                OUT.uv = TRANSFORM_TEX(IN.uv, _MainTex);
                
                // 计算屏幕空间坐标 (用于片元阶段采样深度)
                OUT.screenPos = ComputeScreenPos(OUT.positionHCS);

                // 计算世界空间法线、切线、副切线 (用于法线贴图和反射)
                VertexNormalInputs normalInput = GetVertexNormalInputs(IN.normalOS, IN.tangentOS);
                OUT.normalWS = normalInput.normalWS;
                OUT.tangentWS = normalInput.tangentWS;
                OUT.bitangentWS = normalInput.bitangentWS;

                return OUT;
            }

            // 片元着色器
            half4 frag(Varyings IN) : SV_Target
            {
                // 1. 计算屏幕UV (透视除法)
                float2 screenUV = IN.screenPos.xy / IN.screenPos.w;

                // --- 法线扰动计算 ---
                // 第一层波纹
                float2 uvOffset1 = _Time.y * _Speed.xy;
                float2 uv1 = IN.uv + uvOffset1;
                half4 bump1 = SAMPLE_TEXTURE2D(_BumpMap, sampler_BumpMap, uv1);
                float3 normalTS1 = UnpackNormalScale(bump1, _BumpScale);

                // 第二层波纹 (使用 _Speed.zw 控制速度，通常设为反向或不同速度)
                float2 uvOffset2 = _Time.y * _Speed.zw;
                float2 uv2 = IN.uv * 0.82 + uvOffset2; // 稍微缩放UV以减少重复感(0.82是一个随机数)
                half4 bump2 = SAMPLE_TEXTURE2D(_BumpMap, sampler_BumpMap, uv2);
                float3 normalTS2 = UnpackNormalScale(bump2, _BumpScale);

                // 混合两层法线
                // 将两个法线的 XY 偏移叠加，Z 保持不变(或者取平均)，然后归一化
                float3 normalTS = normalize(float3(normalTS1.xy + normalTS2.xy, max(normalTS1.z, normalTS2.z)));
                
                // 使用法线扰动屏幕UV (模拟折射/水面波动)
                float2 distortedScreenUV = screenUV + normalTS.xy * _DistortionStrength;

                // 2. 采样场景深度 (使用扰动后的UV)
                float rawDepth = SampleSceneDepth(distortedScreenUV);

                // 3. 转换为线性深度 (单位：米)
                float sceneDepth = LinearEyeDepth(rawDepth, _ZBufferParams);

                // 4. 获取当前像素(水面)的线性深度
                float surfaceDepth = IN.screenPos.w;

                // --- 深度检测与伪影修复 ---
                // 如果采样点的深度小于水面深度(说明采样到了水面之前的物体)，则取消扰动
                // 避免将水面上的物体(如船、荷叶)错误地扭曲到水面下
                if (sceneDepth < surfaceDepth)
                {
                    distortedScreenUV = screenUV;
                    rawDepth = SampleSceneDepth(distortedScreenUV);
                    sceneDepth = LinearEyeDepth(rawDepth, _ZBufferParams);
                }

                // 5. 计算水深 (场景深度 - 水面深度)
                float waterDepth = sceneDepth - surfaceDepth;

                // --- 视线角度修正 (基于水面法线) ---
                // 计算世界空间视线方向
                float3 viewDirWS = normalize(_WorldSpaceCameraPos - IN.positionWS);
                
                // 计算视线与水面法线(Y轴)的夹角余弦值
                // abs(viewDirWS.y) 越小，说明视线越平行于水面
                float NdotV = abs(viewDirWS.y);
                
                // 需求：视角移动变化的时候，水面深度不变
                // 原始 waterDepth 是沿视线方向的深度 (View Space Z difference)
                // 它的值大约等于: 垂直深度 / NdotV
                // 当视线倾斜时(NdotV变小)，waterDepth 会变大，导致水看起来更深。
                // 如果希望水深看起来不随视角变化（即基于垂直深度），需要乘以 NdotV 进行补偿。
                
                // 使用 _ViewCorrection 控制修正程度
                // 0.0: 保持原始计算 (视线越斜，深度值越大，水越深)
                // 1.0: 完全修正为垂直深度 (视线倾斜不影响深度值)
                float depthCorrection = lerp(1.0, NdotV, _ViewCorrection);
                
                // 修正后的真实水深
                float realWaterDepth = waterDepth * depthCorrection;

                // --- 反射计算 ---
                // 1. 重构世界空间法线 (基于法线贴图扰动)
                // 构建 TBN 矩阵
                half3x3 TBN = half3x3(IN.tangentWS, IN.bitangentWS, IN.normalWS);
                // 将切线空间法线转换到世界空间
                float3 normalWS = TransformTangentToWorld(normalTS, TBN);
                normalWS = normalize(normalWS);

                // 2. 计算反射向量
                float3 reflectVector = reflect(-viewDirWS, normalWS);

                // 3. 采样反射探针 (Reflection Probe)
                // 使用 URP 内置函数 GlossyEnvironmentReflection
                // roughness = 0 (完全光滑), occlusion = 1 (无遮挡)
                half3 reflectionColor = GlossyEnvironmentReflection(reflectVector, 0.0, 1.0);

                // 4. 计算菲涅尔效应 (Fresnel Effect)
                // 视线越平行于水面，反射越强
                float fresnel = pow(1.0 - saturate(dot(normalWS, viewDirWS)), _FresnelPower);
                
                // 6. 颜色混合
                // 计算颜色深度系数
                float colorDepthT = saturate(realWaterDepth / _DepthMaxDistance);
                float colorGradient = pow(colorDepthT, _DepthExp);

                // 计算透明度深度系数 (独立控制)
                float opacityDepthT = saturate(realWaterDepth / max(_OpacityDepthDistance, 0.001));
                float opacityGradient = pow(opacityDepthT, _OpacityExp);

                // 根据深度在浅水和深水颜色之间插值 (RGB)
                float3 waterBaseColor = lerp(_ShallowColor.rgb, _DeepColor.rgb, colorGradient);
                
                // 混合反射颜色和水体颜色
                // 使用菲涅尔项和反射强度来控制混合比例
                float3 finalColor = lerp(waterBaseColor, reflectionColor, fresnel * _ReflectionStrength);
                
                // 根据深度在浅水和深水Alpha之间插值 (A)
                // 修改：不再额外乘以 opacityGradient，避免Alpha值非线性下降导致整体过透。
                // 只要 _DeepColor.a 设置为 1，深水处就会完全不透。
                // 岸边的透明度现在完全由 _ShallowColor.a 控制（建议设为0）。
                float finalAlpha = lerp(_ShallowColor.a, _DeepColor.a, opacityGradient);
                
                // 增强反射处的不透明度 (可选：如果反射很强，水面应该看起来更不透明)
                finalAlpha = max(finalAlpha, fresnel * _ReflectionStrength);

                // --- 折射背景采样 ---
                // 采样场景颜色 (Opaque Texture)，使用扭曲后的UV
                half3 sceneColor = SampleSceneColor(distortedScreenUV);

                // 手动混合： 背景 * (1 - alpha) + 水颜色 * alpha
                // finalColor 是水体本身的颜色(包含反射)
                float finalOpacity = finalAlpha * _BaseOpacity;
                float3 finalPixelColor = lerp(sceneColor, finalColor, finalOpacity);
                
                // 输出最终颜色，Alpha设为1.0 (因为我们已经手动混合了背景)
                return half4(finalPixelColor, 1.0);
            }

            ENDHLSL
        }
    }
}