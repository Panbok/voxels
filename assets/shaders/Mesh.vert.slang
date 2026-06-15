static const uint POSITION_COLOR_POSITION_OFFSET_BYTES = 0;
static const uint POSITION_COLOR_COLOR_OFFSET_BYTES = 16;

struct Frame
{
    float4x4 mvp;
};

struct Draw
{
    uint vertex_byte_offset;
    uint vertex_stride_bytes;
    uint2 _padding;
};

struct VertexOutput
{
    float4 color : TEXCOORD0;
    float4 position : SV_POSITION;
};

ByteAddressBuffer geometry_vertices : register(t0, space0);
ConstantBuffer<Frame> frame : register(b0, space1);
ConstantBuffer<Draw> draw : register(b1, space1);

[shader("vertex")]
VertexOutput main(uint vertex_index: SV_VertexID)
{
    uint vertex_byte_offset = draw.vertex_byte_offset + vertex_index * draw.vertex_stride_bytes;
    float4 position =
        asfloat(geometry_vertices.Load4(vertex_byte_offset + POSITION_COLOR_POSITION_OFFSET_BYTES));
    float4 color = asfloat(geometry_vertices.Load4(vertex_byte_offset + POSITION_COLOR_COLOR_OFFSET_BYTES));

    VertexOutput output;
    output.position = mul(frame.mvp, float4(position.xyz, 1.0f));
    output.color = color;
    return output;
}
