using System.IO;
using UnityEditor;
using UnityEngine;

public static class CreateMaterialsFromShaders
{
    [MenuItem("Assets/Create Materials From Shaders", true)]
    private static bool Validate()
    {
        // 只有当选中对象里包含 Shader 时才显示/可用
        foreach (var obj in Selection.objects)
            if (obj is Shader) return true;
        return false;
    }

    [MenuItem("Assets/Create Materials From Shaders")]
    private static void Create()
    {
        // 生成到当前选中资源所在文件夹；如果没法取到则用 Assets/
        var folder = GetTargetFolder();
        Directory.CreateDirectory(folder);

        var shaders = Selection.GetFiltered<Shader>(SelectionMode.Assets);
        if (shaders == null || shaders.Length == 0) return;

        AssetDatabase.StartAssetEditing();
        try
        {
            foreach (var shader in shaders)
            {
                var mat = new Material(shader);

                // 材质名 = shader 名的最后一段（不含路径）
                var shaderName = shader.name;
                var shortName = shaderName.Contains("/")
                    ? shaderName.Substring(shaderName.LastIndexOf('/') + 1)
                    : shaderName;

                var path = AssetDatabase.GenerateUniqueAssetPath(
                    Path.Combine(folder, shortName + ".mat")
                );

                AssetDatabase.CreateAsset(mat, path);
            }
        }
        finally
        {
            AssetDatabase.StopAssetEditing();
            AssetDatabase.SaveAssets();
            AssetDatabase.Refresh();
        }

        Debug.Log($"Created {shaders.Length} materials in: {folder}");
    }

    private static string GetTargetFolder()
    {
        // 优先取“当前选中对象”的路径所在文件夹
        var obj = Selection.activeObject;
        if (obj == null) return "Assets";

        var path = AssetDatabase.GetAssetPath(obj);
        if (string.IsNullOrEmpty(path)) return "Assets";

        // 如果选中的是文件，取它的目录；如果选中的是文件夹就用它
        if (AssetDatabase.IsValidFolder(path)) return path;
        return Path.GetDirectoryName(path)?.Replace('\\', '/') ?? "Assets";
    }
}