cbuffer TerrainMaterials : register(b0, space3)
{
    float4 TerrainMaterialColors[8];
};

float face_shade(uint normalID)
{
    switch (normalID)
    {
    case 0:
        return 0.85f; // +X
    case 1:
        return 0.65f; // -X
    case 2:
        return 1.00f; // +Y
    case 3:
        return 0.50f; // -Y
    case 4:
        return 0.78f; // +Z
    case 5:
        return 0.70f; // -Z
    default:
        return 1.0f;
    }
}

float4 main(float3 LocalPosition: TEXCOORD0,
            nointerpolation uint MaterialID: TEXCOORD1,
            nointerpolation uint NormalID: TEXCOORD2) : SV_Target0
{
    uint paletteIndex = MaterialID & 7u;
    float3 color = TerrainMaterialColors[paletteIndex].rgb * face_shade(NormalID);

    if (NormalID >= 6u)
        color = float3(1.0f, 0.0f, 1.0f);

    return float4(color, 1.0f);
}
