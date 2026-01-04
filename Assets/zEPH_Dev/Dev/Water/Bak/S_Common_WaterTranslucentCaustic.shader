Shader "Custom/Common Water Translucent Caustic BAK"
{
    // ---------------------------------------------------------------------------
    // 属性定义
    // ---------------------------------------------------------------------------
    Properties
    {
        [Header(Water Depth Settings)]
        _ShallowColor ("浅水颜色", Color) = (0.0, 0.45, 0.45, 1)
        _DeepColor ("深水颜色", Color) = (0.0, 0.25, 0.25, 1)
        _ShallowOpacity ("浅水不透明度", Range(0, 1)) = 0.0
        _DeepOpacity ("深水不透明度", Range(0, 1)) = 1.0
        _DepthMaxDistance ("颜色渐变最大距离", Range(0.01, 1)) = 0.2
        _DepthExp ("颜色渐变指数", Range(0.01, 10)) = 1.0
        _OpacityDepthDistance ("透明过渡最大距离", Range(0.01, 1)) = 0.06
        _OpacityExp ("透明过渡指数", Range(0.01, 10)) = 1.0
        _ViewCorrection ("视角角度修正", Range(0, 1)) = 0.5

        [Space(15)]
        [Header(Normal Map)]
        [Space(5)]
        _BumpMap("法线贴图", 2D) = "bump" {}
        _BumpScale("法线强度", Range(0.0, 2.0)) = 1.0
        _DistortionStrength ("折射扰动强度", Range(0, 0.2)) = 0.05
        _Speed ("流速 (层1 XY, 层2 XY)", Vector) = (0.005, 0.005, -0.005, -0.005)

        [Space(15)]
        [Header(Reflection)]
        _ReflectionStrength ("反射强度", Range(0, 1)) = 1
        _FresnelPower ("菲涅尔指数", Range(0.1, 10)) = 6
        _Smoothness ("光滑度", Range(0, 1)) = 0.9

        [Space(15)]
        [Header(Translucent Refraction)]
        [Space(5)]
        [Toggle(_REFRACTION)] _UseRefraction("启用折射 (需开启 URP Opaque Texture)", Float) = 0
        _RefractionStrength("折射强度", Range(0.0, 1.0)) = 0.327

        [Header(Advanced)]
        [Enum(UnityEngine.Rendering.CullMode)] _Cull("剔除模式", Float) = 2
    }

    // ---------------------------------------------------------------------------
    // SubShader
    // ---------------------------------------------------------------------------
    SubShader
    {
        // RenderPipeline = UniversalPipeline: 仅在 URP 管线下工作
        // Queue = Transparent: 渲染队列，3000，在不透明物体之后渲染
        Tags { "RenderType" = "Transparent" "RenderPipeline" = "UniversalPipeline" "Queue" = "Transparent" }
        
        LOD 300 // 细节级别，用于性能分级

        // -----------------------------------------------------------------------
        // 全局 HLSL 包含
        // -----------------------------------------------------------------------
        HLSLINCLUDE
        #include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/Core.hlsl" // URP 核心库

        // User-Define HLSL >>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>
        #include "H_Common_WaterTranslucentCaustic_Surface.hlsl"
        // User-Define HLSL >>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>
        ENDHLSL

        // =======================================================================
        // Pass 1: ForwardLit (主光照 Pass)
        // 负责计算物体的主要光照、颜色和纹理
        // =======================================================================
        Pass
        {
            Name "ForwardLit"                           // Pass 的名称，用于调试
            Tags { "LightMode" = "UniversalForward" }   // 前向渲染的主 Pass

            Blend SrcAlpha OneMinusSrcAlpha // 恢复标准半透明混合
            ZWrite Off                      // 关闭深度写入，防止遮挡背景
            Cull [_Cull]    // 使用属性面板设置的剔除模式

            HLSLPROGRAM
            #pragma target 4.5                  // 编译目标：DX11 / OpenGL ES 3.1 等现代 GPU
            #pragma vertex LitPassVertex        // 指定顶点着色器函数名
            #pragma fragment LitPassFragment    // 指定片元着色器函数名

            // -------------------------------------
            // 关键字定义 (Keywords)
            // 用于控制 Shader 的变体，根据材质设置开启或关闭特定功能
            // -------------------------------------
            #pragma shader_feature_local _EMISSION          // 是否有自发光
            #pragma shader_feature_local _REFRACTION        // 是否开启折射
            
            // URP 系统关键字：处理阴影、光照、雾效等
            #pragma multi_compile _ _MAIN_LIGHT_SHADOWS _MAIN_LIGHT_SHADOWS_CASCADE _MAIN_LIGHT_SHADOWS_SCREEN // 主光源阴影
            #pragma multi_compile _ _ADDITIONAL_LIGHTS_VERTEX _ADDITIONAL_LIGHTS    // 额外光源
            #pragma multi_compile_fragment _ _ADDITIONAL_LIGHT_SHADOWS              // 额外光源阴影
            #pragma multi_compile_fragment _ _SHADOWS_SOFT                          // 软阴影
            #pragma multi_compile_fragment _ _SHADOWS_SHADOWMASK                    // 阴影遮罩 (Shadowmask)
            // #pragma multi_compile_fragment _ _SCREEN_SPACE_OCCLUSION                // 屏幕空间环境光遮蔽 (SSAO)
            #pragma multi_compile_fragment _ _DBUFFER_MRT1 _DBUFFER_MRT2 _DBUFFER_MRT3 // 贴花 (Decals) 支持
            #pragma multi_compile_fragment _ _LIGHT_LAYERS      // 光照层
            #pragma multi_compile_fragment _ _LIGHT_COOKIES     // 光照 Cookie
            #pragma multi_compile _ _CLUSTERED_RENDERING        // 集群渲染 (Forward+)
            #pragma multi_compile_fog                   // 雾效
            #pragma multi_compile _ LIGHTMAP_ON         // 光照贴图
            #pragma multi_compile _ DYNAMICLIGHTMAP_ON  // 动态光照贴图 (Realtime GI)
            #pragma multi_compile_fragment _ _PROBE_VOLUMES_L1 _PROBE_VOLUMES_L2    // 自适应探针体积 (APV)
            #pragma multi_compile_instancing            // GPU 实例化
            #pragma instancing_options renderinglayer   // 渲染层支持

            // 必须先包含 Lighting.hlsl 以获取 DECLARE_LIGHTMAP_OR_SH 等宏定义
            #include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/Lighting.hlsl"

            // 顶点着色器输入结构体
            struct Attributes
            {
                float4 positionOS   : POSITION; // 模型空间顶点位置
                float3 normalOS     : NORMAL;   // 模型空间法线
                float4 tangentOS    : TANGENT;  // 模型空间切线
                float2 uv           : TEXCOORD0; // 第一套 UV 坐标
                float2 lightmapUV   : TEXCOORD1; // 第二套 UV (用于光照贴图)
                UNITY_VERTEX_INPUT_INSTANCE_ID // 实例化 ID
            };

            // 顶点着色器输出 / 片元着色器输入结构体
            struct Varyings
            {
                float4 positionCS   : SV_POSITION; // 裁剪空间位置 (屏幕位置)
                float3 positionWS   : TEXCOORD0;   // 世界空间位置
                half3  normalWS     : TEXCOORD1;   // 世界空间法线
                half4  tangentWS    : TEXCOORD2;   // 世界空间切线
                float2 uv           : TEXCOORD3;   // UV 坐标
                float4 screenPos    : TEXCOORD4;   // 屏幕空间位置 (用于深度采样)
                
                #if defined(REQUIRES_VERTEX_SHADOW_COORD_INTERPOLATOR)
                    float4 shadowCoord : TEXCOORD5; // 阴影坐标 (如果需要插值)
                #endif

                DECLARE_LIGHTMAP_OR_SH(lightmapUV, vertexSH, 6); // 光照贴图 UV 或 球谐光照数据
                
                #if defined(FOG_FRAGMENT)
                    float fogCoord : TEXCOORD7; // 雾效坐标
                #endif

                #if defined(_EMISSION)
                    float2 uvEmission : TEXCOORD8; // 自发光 UV
                #endif

                UNITY_VERTEX_INPUT_INSTANCE_ID  // 实例化 ID
                UNITY_VERTEX_OUTPUT_STEREO      // VR 立体渲染支持
            };

            // User-Define HLSL >>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>
            #include "H_Common_WaterTranslucentCaustic_Lighting.hlsl"
            // User-Define HLSL >>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>

            // 顶点着色器函数
            Varyings LitPassVertex(Attributes IN)
            {
                Varyings OUT = (Varyings)0;
                UNITY_SETUP_INSTANCE_ID(IN);                // 设置实例化 ID
                UNITY_TRANSFER_INSTANCE_ID(IN, OUT);        // 传递实例化 ID 到输出
                UNITY_INITIALIZE_VERTEX_OUTPUT_STEREO(OUT); // 初始化 VR 输出

                // 获取顶点位置信息 (世界空间、裁剪空间等)
                VertexPositionInputs posInputs = GetVertexPositionInputs(IN.positionOS.xyz);
                OUT.positionCS = posInputs.positionCS;
                OUT.positionWS = posInputs.positionWS;

                // 获取法线和切线信息 (转换到世界空间)
                VertexNormalInputs normalInputs = GetVertexNormalInputs(IN.normalOS, IN.tangentOS);
                OUT.normalWS = normalInputs.normalWS;
                // 存储切线，w 分量用于确定副切线方向
                OUT.tangentWS = half4(normalInputs.tangentWS, IN.tangentOS.w * GetOddNegativeScale());
                
                // 变换 UV 坐标
                OUT.uv = TRANSFORM_TEX(IN.uv, _BumpMap);
                
                // 计算屏幕空间坐标 (用于片元阶段采样深度)
                OUT.screenPos = ComputeScreenPos(OUT.positionCS);
                
                // #if defined(_EMISSION)
                //     OUT.uvEmission = TRANSFORM_TEX(IN.uv, _EmissionMap);
                // #endif

                // 输出光照贴图 UV 或 SH 数据
                OUTPUT_LIGHTMAP_UV(IN.lightmapUV, unity_LightmapST, OUT.lightmapUV);
                OUTPUT_SH(OUT.normalWS, OUT.vertexSH);

                // 计算阴影坐标
                #if defined(REQUIRES_VERTEX_SHADOW_COORD_INTERPOLATOR)
                    OUT.shadowCoord = GetShadowCoord(posInputs);
                #endif
                
                // 计算雾效因子
                #if defined(FOG_FRAGMENT)
                    OUT.fogCoord = ComputeFogFactor(OUT.positionCS.z);
                #endif

                return OUT;
            }

            // 片元着色器函数
            half4 LitPassFragment(Varyings IN) : SV_Target
            // half4 LitPassFragment(Varyings IN, float facing : VFACE) : SV_Target
            {
                // // 双面渲染处理：如果是背面，反转法线和切线
                // if (facing < 0)
                // {
                //     IN.normalWS = -IN.normalWS;
                //     IN.tangentWS.xyz = -IN.tangentWS.xyz;
                // }

                UNITY_SETUP_INSTANCE_ID(IN); // 设置实例化 ID
                
                SurfaceData surfaceData;
                float2 emissionUV = IN.uv;
                // #if defined(_EMISSION)
                //     emissionUV = IN.uvEmission;
                // #endif

                // 初始化表面数据 (读取贴图、计算属性) - 定义在 zEPH_Optimized_Surface.hlsl
                InitializeSurfaceData(IN.uv, IN.screenPos, IN.positionWS, emissionUV, surfaceData);
                
                // 计算最终光照颜色 - 定义在 zEPH_Optimized_Lighting.hlsl
                return CalculateLitColor(IN, surfaceData);
            }
            ENDHLSL
        }

        // =======================================================================
        // Pass 2: ShadowCaster (阴影投射 Pass)
        // 负责将物体渲染到阴影贴图中，使其能产生阴影
        // =======================================================================
        Pass
        {
            Name "ShadowCaster"
            Tags { "LightMode" = "ShadowCaster" } // 告诉 URP 这是阴影投射 Pass

            ZWrite On       // 必须开启深度写入
            ZTest LEqual    // 深度测试模式
            ColorMask 0     // 不输出颜色，只写深度
            Cull [_Cull]    // 跟随剔除设置

            HLSLPROGRAM
            #pragma target 4.5
            #pragma vertex ShadowPassVertex
            #pragma fragment ShadowPassFragment

            #pragma multi_compile_instancing

            // 必须包含 Lighting.hlsl 以获取 GetMainLight()
            #include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/Lighting.hlsl"
            #include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/Shadows.hlsl"

            struct Attributes
            {
                float4 positionOS   : POSITION;
                float3 normalOS     : NORMAL;
                float2 uv           : TEXCOORD0;
                UNITY_VERTEX_INPUT_INSTANCE_ID
            };

            struct Varyings
            {
                float4 positionCS   : SV_POSITION;
                float2 uv           : TEXCOORD0;
                UNITY_VERTEX_INPUT_INSTANCE_ID
                UNITY_VERTEX_OUTPUT_STEREO
            };

            // 阴影 Pass 顶点着色器
            Varyings ShadowPassVertex(Attributes input)
            {
                Varyings output;
                UNITY_SETUP_INSTANCE_ID(input);
                UNITY_TRANSFER_INSTANCE_ID(input, output);
                UNITY_INITIALIZE_VERTEX_OUTPUT_STEREO(output);

                float3 positionWS = TransformObjectToWorld(input.positionOS.xyz);
                float3 normalWS = TransformObjectToWorldNormal(input.normalOS);

                // 计算在光源视角下的裁剪空间位置，并应用阴影偏移 (Bias) 以防止自阴影伪影
                output.positionCS = TransformWorldToHClip(ApplyShadowBias(positionWS, normalWS, GetMainLight().direction));
                
                // 处理不同平台的深度反转问题
                #if UNITY_REVERSED_Z
                    output.positionCS.z = min(output.positionCS.z, output.positionCS.w * UNITY_NEAR_CLIP_VALUE);
                #else
                    output.positionCS.z = max(output.positionCS.z, output.positionCS.w * UNITY_NEAR_CLIP_VALUE);
                #endif

                output.uv = input.uv;
                return output;
            }

            // 阴影 Pass 片元着色器
            half4 ShadowPassFragment(Varyings input) : SV_TARGET
            {
                UNITY_SETUP_INSTANCE_ID(input);
                
                // 获取 Alpha 值并进行裁剪
                #if defined(_ALPHATEST_ON)
                    half alpha = GetAlpha(input.uv);
                    DoAlphaClip(alpha);
                #endif
                
                return 0; // 不需要输出颜色
            }
            ENDHLSL
        }

        // =======================================================================
        // Pass 3: DepthOnly (深度预渲染 Pass)
        // 负责将物体渲染到 _CameraDepthTexture，用于后期处理等
        // =======================================================================
        Pass
        {
            Name "DepthOnly"
            Tags { "LightMode" = "DepthOnly" } // 告诉 URP 这是深度预渲染 Pass

            ZWrite On
            ZTest LEqual
            ColorMask 0 // 不输出颜色
            Cull [_Cull]

            HLSLPROGRAM
            #pragma target 4.5
            #pragma vertex DepthOnlyVertex
            #pragma fragment DepthOnlyFragment

            #pragma multi_compile_instancing

            struct Attributes
            {
                float4 positionOS   : POSITION;
                float2 uv           : TEXCOORD0;
                UNITY_VERTEX_INPUT_INSTANCE_ID
            };

            struct Varyings
            {
                float4 positionCS   : SV_POSITION;
                float2 uv           : TEXCOORD0;
                UNITY_VERTEX_INPUT_INSTANCE_ID
                UNITY_VERTEX_OUTPUT_STEREO
            };

            Varyings DepthOnlyVertex(Attributes input)
            {
                Varyings output = (Varyings)0;
                UNITY_SETUP_INSTANCE_ID(input);
                UNITY_TRANSFER_INSTANCE_ID(input, output);
                UNITY_INITIALIZE_VERTEX_OUTPUT_STEREO(output);

                // 直接转换到裁剪空间
                output.positionCS = TransformObjectToHClip(input.positionOS.xyz);
                output.uv = input.uv;
                return output;
            }

            half4 DepthOnlyFragment(Varyings input) : SV_TARGET
            {
                UNITY_SETUP_INSTANCE_ID(input);
                
                // 同样需要处理 Alpha 裁剪，保证深度图形状正确
                #if defined(_ALPHATEST_ON)
                    half alpha = GetAlpha(input.uv);
                    DoAlphaClip(alpha);
                #endif
                
                return 0;
            }
            ENDHLSL
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

            #pragma multi_compile_instancing

            // 包含 URP 标准 DepthNormalsPass 实现
            // 注意：它会调用我们在 _Surface.hlsl 中定义的 SampleAlbedoAlpha, SampleNormal, Alpha 函数
            #include "Packages/com.unity.render-pipelines.universal/Shaders/DepthNormalsPass.hlsl"
            
            ENDHLSL
        }

        // =======================================================================
        // Pass 5: Meta (光照烘焙 Pass)
        // 负责为 Unity 的光照烘焙系统提供材质数据 (Albedo, Emission)
        // =======================================================================
        Pass
        {
            Name "Meta"
            Tags { "LightMode" = "Meta" } // 告诉 Unity 这是用于提取烘焙数据的 Pass

            Cull Off // 烘焙时通常不剔除

            HLSLPROGRAM
            #pragma target 4.5
            #pragma vertex VertexMeta
            #pragma fragment FragmentMeta

            #pragma shader_feature_local _EMISSION
            #pragma shader_feature_local _ALPHATEST_ON
            #pragma shader_feature_local _ALPHASOURCE_A

            // 以下可写入HLSL头文件,
            #include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/MetaInput.hlsl"

            struct Attributes
            {
                float4 positionOS   : POSITION;
                float2 uv           : TEXCOORD0;
                float2 lightmapUV   : TEXCOORD1;
                UNITY_VERTEX_INPUT_INSTANCE_ID
            };

            struct Varyings
            {
                float4 positionCS   : SV_POSITION;
                float2 uv           : TEXCOORD0;
                #if defined(_EMISSION)
                    float2 uvEmission : TEXCOORD1;
                #endif
            };

            Varyings VertexMeta(Attributes input)
            {
                Varyings OUT = (Varyings)0;
                UNITY_SETUP_INSTANCE_ID(input);
                
                // 使用 UnityMetaVertexPosition 计算烘焙所需的特殊位置
                OUT.positionCS = UnityMetaVertexPosition(input.positionOS.xyz, input.lightmapUV, input.lightmapUV, unity_LightmapST, unity_DynamicLightmapST);
                OUT.uv = input.uv;
                // #if defined(_EMISSION)
                //     OUT.uvEmission = TRANSFORM_TEX(input.uv, _EmissionMap);
                // #endif
                return OUT;
            }

            half4 FragmentMeta(Varyings IN) : SV_Target
            {
                SurfaceData surfaceData;
                float2 emissionUV = IN.uv;
                // #if defined(_EMISSION)
                //     emissionUV = IN.uvEmission;
                // #endif
                InitializeSurfaceData(IN.uv, 0, 0, emissionUV, surfaceData);

                MetaInput metaInput = (MetaInput)0;
                metaInput.Albedo = surfaceData.albedo;
                metaInput.Emission = surfaceData.emission;
                
                // 输出烘焙数据
                return UnityMetaFragment(metaInput);
            }
             // 以上可写入HLSL头文件,
             
            ENDHLSL
        }
    }
    
    FallBack "Universal Render Pipeline/Lit"
}
