static const float3 DEBUG_MATERIAL_COLORS[8] = {
    float3(0.38f, 0.75f, 0.34f),     // Grass
    float3(0.55f, 0.38f, 0.22f),     // Dirt
    float3(0.45f, 0.45f, 0.48f),     // Stone
    float3(0.70f, 0.68f, 0.55f),     // Sand
    float3(0.25f, 0.45f, 0.85f),     // Water
    float3(0.80f, 0.35f, 0.25f),     // Lava / Red Sand / Terracotta
    float3(0.85f, 0.78f, 0.36f),     // Gold / Sandstone / Hay
    float3(0.85f, 0.85f, 0.85f),     // Snow / Ice / White Concrete
};

float face_shade(uint normalID)
{
    switch (normalID)
    {
    case 0: return 0.85f; // +X
    case 1: return 0.65f; // -X
    case 2: return 1.00f; // +Y
    case 3: return 0.50f; // -Y
    case 4: return 0.78f; // +Z
    case 5: return 0.70f; // -Z
    default: return 1.0f;
    }
}

float4 main(float3 LocalPosition : TEXCOORD0,
	nointerpolation uint MaterialID : TEXCOORD1,
	nointerpolation uint NormalID : TEXCOORD2,
	nointerpolation uint CornerID : TEXCOORD3) : SV_Target0
{
    uint paletteIndex = MaterialID & 7u;
    float3 color = DEBUG_MATERIAL_COLORS[paletteIndex] * face_shade(NormalID);

    if (NormalID >= 6u)
        color = float3(1.0f, 0.0f, 1.0f);

    return float4(color, 1.0f);
}
