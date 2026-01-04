using UnityEngine;
using UnityEditor;
using System.IO;

public class SkinLutTool : EditorWindow
{
    [MenuItem("Tools/Skin LUT Generator")]
    public static void ShowWindow()
    {
        GetWindow<SkinLutTool>("Skin LUT Gen");
    }

    public Gradient gradientTop;    // High Curvature (Soft, Wide Scatter)
    public Gradient gradientBottom; // Low Curvature (Sharp, Narrow Scatter)
    public int width = 256;
    public int height = 256;
    public string savePath = "Assets/zEPH_Dev/Pre-IntegratedSkinShading/T_Pre-Integrated_Lut.exr";
    
    // Physics Based Parameters
    public bool usePhysicsBased = true;
    
    [Tooltip("Base softness of the shadow (affects all channels). Keep low for sharp shadows.")]
    [Range(0.0f, 2.0f)]
    public float baseSoftness = 0.05f; 

    [Tooltip("The color of the subsurface scattering (e.g., blood red).")]
    public Color scatterColor = new Color(0.597f, 0.266f, 0.0182f);

    [Tooltip("How far the scatter color spreads beyond the shadow boundary.")]
    [Range(0.0f, 4.0f)]
    public float scatterSpread = 1.5f;

    [Tooltip("Reduces the scattering of secondary channels to eliminate mixed color artifacts at the shadow edge.")]
    [Range(0.0f, 1.0f)]
    public float reduceYellowing = 1.0f;

    [Tooltip("Controls the curve of the blur radius along the Y axis. 1.0 = Linear, <1.0 = Convex, >1.0 = Concave.")]
    [Range(0.1f, 3.0f)]
    public float curvatureFalloff = 1.0f;

    private void OnEnable()
    {
        if (gradientTop == null || gradientBottom == null)
        {
            ResetDefaults();
        }
    }

    private void ResetPhysicsDefaults()
    {
        baseSoftness = 0.05f;
        scatterColor = new Color(0.597f, 0.266f, 0.0182f);
        scatterSpread = 1.5f;
        reduceYellowing = 1.0f;
        curvatureFalloff = 1.0f;
    }

    private void ResetDefaults()
    {
        // Top Gradient: High Curvature (Soft, Wide Scatter)
        // Matches the reference: Smooth transition with deep red bleeding into shadow
        gradientTop = new Gradient();
        gradientTop.mode = GradientMode.Blend;
        gradientTop.SetKeys(
            new GradientColorKey[] {
                new GradientColorKey(Color.black, 0.0f),
                new GradientColorKey(new Color(0.15f, 0.0f, 0.0f), 0.2f),   // Deep dark red bleed
                new GradientColorKey(new Color(0.65f, 0.15f, 0.05f), 0.45f), // Rich scatter red
                new GradientColorKey(new Color(0.85f, 0.65f, 0.55f), 0.65f), // Soft skin tone transition
                new GradientColorKey(new Color(0.95f, 0.95f, 0.95f), 1.0f)   // Fully lit
            },
            new GradientAlphaKey[] { new GradientAlphaKey(1.0f, 0.0f), new GradientAlphaKey(1.0f, 1.0f) }
        );

        // Bottom Gradient: Low Curvature (Sharp, Narrow Scatter)
        // Matches the reference: Sharper but not hard-edged, retaining the red band
        gradientBottom = new Gradient();
        gradientBottom.mode = GradientMode.Blend;
        gradientBottom.SetKeys(
            new GradientColorKey[] {
                new GradientColorKey(Color.black, 0.0f),
                new GradientColorKey(Color.black, 0.42f),                    // Shadow stays dark
                new GradientColorKey(new Color(0.55f, 0.05f, 0.02f), 0.48f), // Sharp red band
                new GradientColorKey(new Color(0.85f, 0.75f, 0.7f), 0.55f),  // Quick transition to lit
                new GradientColorKey(new Color(0.95f, 0.95f, 0.95f), 1.0f)   // Fully lit
            },
            new GradientAlphaKey[] { new GradientAlphaKey(1.0f, 0.0f), new GradientAlphaKey(1.0f, 1.0f) }
        );
    }

    private void OnGUI()
    {
        GUILayout.Label("Skin LUT Generator", EditorStyles.boldLabel);
        
        usePhysicsBased = EditorGUILayout.Toggle("Use Physics Based", usePhysicsBased);

        if (usePhysicsBased)
        {
            GUILayout.Label("Physics Parameters", EditorStyles.boldLabel);
            if (GUILayout.Button("Reset Physics Parameters")) ResetPhysicsDefaults();
            
            baseSoftness = EditorGUILayout.Slider("Base Softness", baseSoftness, 0.0f, 2.0f);
            scatterColor = EditorGUILayout.ColorField("Scatter Color", scatterColor);
            scatterSpread = EditorGUILayout.Slider("Scatter Spread", scatterSpread, 0.0f, 4.0f);
            reduceYellowing = EditorGUILayout.Slider("Reduce Yellowing", reduceYellowing, 0.0f, 1.0f);
            curvatureFalloff = EditorGUILayout.Slider("Curvature Falloff", curvatureFalloff, 0.1f, 3.0f);
            
            EditorGUILayout.HelpBox("Generates a LUT by convolving Lambert with a Gaussian kernel.\n" +
                                    "Base Softness: Controls the sharpness of the main shadow edge.\n" +
                                    "Scatter Color: The tint of the subsurface scattering.\n" +
                                    "Scatter Spread: How wide the colored scattering extends into the shadow.\n" +
                                    "Reduce Yellowing: Suppresses secondary channel scattering to keep the shadow edge pure to the Scatter Color.\n" +
                                    "Curvature Falloff: Adjusts the shape of the blur curve along the Y axis.", MessageType.Info);
        }
        else
        {
            GUILayout.Label("Gradient Parameters (Artistic)", EditorStyles.boldLabel);
            if (GUILayout.Button("Reset to Defaults")) ResetDefaults();
            gradientTop = EditorGUILayout.GradientField("Top (High Curv)", gradientTop);
            gradientBottom = EditorGUILayout.GradientField("Bottom (Low Curv)", gradientBottom);
        }

        GUILayout.Space(10);
        width = EditorGUILayout.IntField("Width", width);
        height = EditorGUILayout.IntField("Height", height);
        savePath = EditorGUILayout.TextField("Save Path", savePath);

        GUILayout.Space(10);

        if (GUILayout.Button("Generate Texture"))
        {
            if (usePhysicsBased)
                GeneratePhysicsLUT();
            else
                GenerateGradientLUT();
        }
    }

    private float Gaussian(float x, float sigma)
    {
        if (sigma <= 0.0001f) return x == 0 ? 1.0f : 0.0f;
        return (1.0f / (Mathf.Sqrt(2 * Mathf.PI) * sigma)) * Mathf.Exp(-(x * x) / (2 * sigma * sigma));
    }

    private float IntegrateDiffuse(float angle, float sigma)
    {
        if (sigma < 0.001f)
        {
            return Mathf.Max(0, Mathf.Cos(angle));
        }

        float sum = 0.0f;
        float weightSum = 0.0f;
        
        // 积分范围：-3 sigma 到 +3 sigma
        int samples = 64; // 采样数
        float range = 3.0f * sigma;
        float step = (range * 2.0f) / samples;

        for (float offset = -range; offset <= range; offset += step)
        {
            float sampleAngle = angle + offset;
            // Diffuse = max(0, cos(theta))
            float diffuse = Mathf.Max(0, Mathf.Cos(sampleAngle));
            float weight = Gaussian(offset, sigma);

            sum += diffuse * weight;
            weightSum += weight;
        }

        return sum / weightSum;
    }

    private void GeneratePhysicsLUT()
    {
        Texture2D texture = new Texture2D(width, height, TextureFormat.RGBAFloat, false);
        texture.wrapMode = TextureWrapMode.Clamp;

        // Find the maximum component value to determine dominant channels
        float maxVal = Mathf.Max(scatterColor.r, Mathf.Max(scatterColor.g, scatterColor.b));

        for (int y = 0; y < height; y++)
        {
            // Y轴 = Curvature (0 = Flat, 1 = Curved)
            float curvature = Mathf.Pow((float)y / (height - 1), curvatureFalloff);
            
            // Pre-calculate normalization factors
            float[] normFactors = new float[3];
            
            // Store parameters for each channel to reuse in the X loop
            float[] directSigmas = new float[3];
            float[] scatterSigmas = new float[3];
            float[] blendWeights = new float[3];

            for (int c = 0; c < 3; c++)
            {
                float channelColor = c == 0 ? scatterColor.r : (c == 1 ? scatterColor.g : scatterColor.b);
                
                // Determine dominance
                float ratio = (maxVal > 0.0001f) ? (channelColor / maxVal) : 0.0f;
                float dominance = Mathf.Clamp01((ratio - 0.6f) / (0.9f - 0.6f));
                float purityMult = Mathf.Lerp(1.0f - reduceYellowing, 1.0f, dominance);

                // Dual Lobe Model:
                // 1. Direct Lobe (Sharp): Controlled by Base Softness
                // 2. Scatter Lobe (Soft): Controlled by Scatter Spread * Color
                
                float directRadius = baseSoftness;
                // Scatter radius scales with color intensity (brighter = further scatter)
                float scatterRadius = baseSoftness + (scatterSpread * channelColor * purityMult);
                
                directSigmas[c] = curvature * directRadius;
                scatterSigmas[c] = curvature * scatterRadius;
                
                // Blend weight determines how much of the light is scattered vs direct.
                // Brighter channels scatter more.
                blendWeights[c] = Mathf.Clamp01(channelColor * purityMult);

                // Calculate peak value for normalization (at angle 0)
                float peakDirect = IntegrateDiffuse(0.0f, directSigmas[c]);
                float peakScatter = IntegrateDiffuse(0.0f, scatterSigmas[c]);
                float peakMix = Mathf.Lerp(peakDirect, peakScatter, blendWeights[c]);
                
                normFactors[c] = peakMix > 0.0001f ? 1.0f / peakMix : 1.0f;
            }

            for (int x = 0; x < width; x++)
            {
                // X轴 = NdotL (-1 to 1)
                float NdotL = ((float)x / (width - 1)) * 2.0f - 1.0f;
                float angle = Mathf.Acos(Mathf.Clamp(NdotL, -1f, 1f));

                Color pixelColor = Color.black;

                for (int c = 0; c < 3; c++)
                {
                    float valDirect = IntegrateDiffuse(angle, directSigmas[c]);
                    float valScatter = IntegrateDiffuse(angle, scatterSigmas[c]);
                    
                    float valMix = Mathf.Lerp(valDirect, valScatter, blendWeights[c]);
                    
                    pixelColor[c] = valMix * normFactors[c];
                }
                
                texture.SetPixel(x, y, pixelColor);
            }
        }
        
        SaveTexture(texture);
    }

    private void GenerateGradientLUT()
    {
        Texture2D texture = new Texture2D(width, height, TextureFormat.RGBAFloat, false);
        texture.wrapMode = TextureWrapMode.Clamp;

        for (int y = 0; y < height; y++)
        {
            float tY = (float)y / (height - 1);
            for (int x = 0; x < width; x++)
            {
                float tX = (float)x / (width - 1);
                Color colTop = gradientTop.Evaluate(tX);
                Color colBottom = gradientBottom.Evaluate(tX);
                Color finalCol = Color.Lerp(colBottom, colTop, tY);
                texture.SetPixel(x, y, finalCol);
            }
        }
        SaveTexture(texture);
    }

    private void SaveTexture(Texture2D texture)
    {
        texture.Apply();
        
        string dir = Path.GetDirectoryName(savePath);
        if (!Directory.Exists(dir)) Directory.CreateDirectory(dir);

        byte[] bytes;
        if (savePath.EndsWith(".exr", System.StringComparison.OrdinalIgnoreCase))
        {
            bytes = texture.EncodeToEXR(Texture2D.EXRFlags.CompressZIP);
        }
        else
        {
            bytes = texture.EncodeToPNG();
        }

        File.WriteAllBytes(savePath, bytes);
        
        AssetDatabase.Refresh();

        TextureImporter importer = AssetImporter.GetAtPath(savePath) as TextureImporter;
        if (importer != null)
        {
            // LUT 存储的是线性数据，不应被视为 sRGB
            importer.sRGBTexture = false; 
            importer.wrapMode = TextureWrapMode.Clamp;
            importer.mipmapEnabled = false;
            importer.textureCompression = TextureImporterCompression.Uncompressed;
            importer.SaveAndReimport();
        }

        Debug.Log($"Skin LUT generated at: {savePath}");
        
        Object obj = AssetDatabase.LoadAssetAtPath<Object>(savePath);
        if (obj != null) Selection.activeObject = obj;
    }
}
