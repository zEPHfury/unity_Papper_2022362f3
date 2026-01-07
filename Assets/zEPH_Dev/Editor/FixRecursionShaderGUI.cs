using UnityEditor;
using UnityEngine;

public class FixRecursionShaderGUI : ShaderGUI
{
    public override void OnGUI(MaterialEditor materialEditor, MaterialProperty[] properties)
    {
        // This calls the default property renderer, avoiding the recursion loop
        // that happens if you call materialEditor.PropertiesGUI() here.
        materialEditor.PropertiesDefaultGUI(properties);
    }
}
