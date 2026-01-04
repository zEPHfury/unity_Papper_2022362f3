using UnityEngine;

[ExecuteAlways]
[RequireComponent(typeof(Renderer))]
public class ModelBoundsToMaterial : MonoBehaviour
{
    public string minProperty = "_BoundsMin";
    public string maxProperty = "_BoundsMax";

    void Update()
    {
        var renderer = GetComponent<Renderer>();
        if (renderer == null || renderer.sharedMaterial == null) return;
        var meshFilter = GetComponent<MeshFilter>();
        if (meshFilter == null || meshFilter.sharedMesh == null) return;

        var bounds = meshFilter.sharedMesh.bounds;
        Vector3 min = bounds.min;
        Vector3 max = bounds.max;

        // 变换到世界空间再转回本地空间（如果有缩放/旋转）
        min = transform.TransformPoint(min);
        max = transform.TransformPoint(max);
        min = transform.InverseTransformPoint(min);
        max = transform.InverseTransformPoint(max);

        renderer.sharedMaterial.SetVector(minProperty, min);
        renderer.sharedMaterial.SetVector(maxProperty, max);
    }
}
