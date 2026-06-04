// Hardware indexed PVP:
// SDL's index buffer drives SV_VertexID, then the shader pulls vertex bytes
// from this storage buffer instead of using fixed vertex attributes.
// Keep these byte offsets in sync with GeometryVertex in src/main.odin.
ByteAddressBuffer GeometryVertices : register(t0, space0);

static const uint GEOMETRY_VERTEX_STRIDE_BYTES = 32;
static const uint GEOMETRY_VERTEX_POSITION_OFFSET_BYTES = 0;
static const uint GEOMETRY_VERTEX_COLOR_OFFSET_BYTES = 16;

struct VSOutput
{
    float4 Color : TEXCOORD0;
    float4 Position : SV_POSITION;
};

cbuffer Frame : register(b0, space1)
{
    float4x4 MVP;
};

cbuffer Draw : register(b1, space1)
{
    uint VertexOffset;
    uint3 _Padding;
};

VSOutput main(uint vertexIndex : SV_VertexID)
{
    uint vertexByteOffset = (VertexOffset + vertexIndex) * GEOMETRY_VERTEX_STRIDE_BYTES;

    float4 position = asfloat(GeometryVertices.Load4(vertexByteOffset + GEOMETRY_VERTEX_POSITION_OFFSET_BYTES));
    float4 color = asfloat(GeometryVertices.Load4(vertexByteOffset + GEOMETRY_VERTEX_COLOR_OFFSET_BYTES));

    VSOutput output;
    output.Position = mul(MVP, float4(position.xyz, 1.0f));
    output.Color = color;
    return output;
}
