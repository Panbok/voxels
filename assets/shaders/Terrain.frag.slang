struct TerrainMaterials
{
    float4 colors[8];
};

struct FragmentInput
{
    float3 local_position : TEXCOORD0;
    nointerpolation uint material_id : TEXCOORD1;
    nointerpolation uint normal_id : TEXCOORD2;
};

ConstantBuffer<TerrainMaterials> terrain_materials : register(b0, space3);

float face_shade(uint normal_id)
{
    switch (normal_id)
    {
    case 0:
        return 0.85f;
    case 1:
        return 0.65f;
    case 2:
        return 1.00f;
    case 3:
        return 0.50f;
    case 4:
        return 0.78f;
    case 5:
        return 0.70f;
    default:
        return 1.0f;
    }
}

[shader("fragment")]
float4 main(FragmentInput input) : SV_Target0
{
    uint palette_index = input.material_id & 7u;
    float3 color = terrain_materials.colors[palette_index].rgb * face_shade(input.normal_id);

    if (input.normal_id >= 6u)
    {
        color = float3(1.0f, 0.0f, 1.0f);
    }

    return float4(color, 1.0f);
}
