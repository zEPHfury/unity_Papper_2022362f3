Shader "Hidden/SkinLut"
{
    SubShader
    {
        Pass
        {
            Cull   Off
            ZTest  Always
            ZWrite Off
            Blend  Off

            HLSLPROGRAM
            #pragma editor_sync_compilation
            #pragma target 4.5
            #pragma only_renderers d3d11 playstation xboxone xboxseries vulkan metal switch

            #pragma vertex Vert
            #pragma fragment Frag


            #include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/Core.hlsl"
            #include "SkinCommon.hlsl"


            float4 _ShapeParam;
            float _MaxRadius; // See 'DiffusionProfile'

            struct Attributes
            {
                float4 vertex   : POSITION;
                float2 texcoord : TEXCOORD0;
            };

            struct Varyings
            {
                float4 vertex   : SV_POSITION;
                float2 texcoord : TEXCOORD0;
            };

            Varyings Vert(Attributes input)
            {
                Varyings output;
                output.vertex = TransformObjectToHClip(input.vertex.xyz);
                output.texcoord = input.texcoord.xy;
                return output;
            }
        

            float4 Frag(Varyings input) : SV_Target
            {
                float4 reslut = 1;
                float2 uv = input.texcoord;
                float cosTheta = uv.x *2 -1;
                float r = 1.0/(max(0.00001,uv.y));
                float rad2deg = 57.29578;
                float theta = acos(cosTheta) * rad2deg;
                float3 totalWeights = 0.0;
                float3 totalLight = 0.0;
                int sampleCount = 128;
                float sampleAngle = (theta - 90.0);
                int stepSize = 180.0 / sampleCount;
                float3 S = _ShapeParam.rgb;
                float deg2rad = (PI / 180.0);
                for (int i = 0; i < sampleCount; i++) 
                {
                    float diffuse = saturate(cos(sampleAngle * deg2rad));
                    float dAngle = abs(theta - sampleAngle);
                    float sampleDist = abs(2.0f * r * sin(dAngle * 0.5f * deg2rad));
                    float3 weights = EvalBurleyDiffusionProfile(sampleDist, S);
                    totalWeights += weights;
                    totalLight += diffuse * weights;
                    sampleAngle += stepSize;
                }
                reslut.xyz = totalLight.xyz / totalWeights.xyz;
                return reslut;
            }
            ENDHLSL
        }
    }
    Fallback Off
}
