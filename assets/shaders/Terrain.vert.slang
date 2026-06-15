static const uint LOCAL_X_SHIFT = 0;
static const uint LOCAL_Y_SHIFT = 7;
static const uint LOCAL_Z_SHIFT = 14;
static const uint NORMAL_SHIFT = 21;
static const uint MATERIAL_SHIFT = 24;

static const uint LOCAL_MASK = 0x7Fu;
static const uint NORMAL_MASK = 0x7u;
static const uint MATERIAL_MASK = 0xFFu;

struct Frame
{
    float4x4 mvp;
};

struct Draw
{
    uint vertex_byte_offset;
    uint vertex_stride_bytes;
    uint2 _padding0;
    float4 chunk_origin_block_size;
};

struct VertexOutput
{
    float3 local_position : TEXCOORD0;
    nointerpolation uint material_id : TEXCOORD1;
    nointerpolation uint normal_id : TEXCOORD2;
    float4 position : SV_POSITION;
};

ByteAddressBuffer geometry_vertices : register(t0, space0);
ConstantBuffer<Frame> frame : register(b0, space1);
ConstantBuffer<Draw> draw : register(b1, space1);

[shader("vertex")]
VertexOutput main(uint vertex_index: SV_VertexID)
{
    uint vertex_byte_offset = draw.vertex_byte_offset + vertex_index * draw.vertex_stride_bytes;
    uint packed = geometry_vertices.Load(vertex_byte_offset);

    uint block_x = (packed >> LOCAL_X_SHIFT) & LOCAL_MASK;
    uint block_y = (packed >> LOCAL_Y_SHIFT) & LOCAL_MASK;
    uint block_z = (packed >> LOCAL_Z_SHIFT) & LOCAL_MASK;
    uint normal_id = (packed >> NORMAL_SHIFT) & NORMAL_MASK;
    uint material_id = (packed >> MATERIAL_SHIFT) & MATERIAL_MASK;

    float3 block_cell_position = float3(block_x, block_y, block_z);
    float3 world_position =
        draw.chunk_origin_block_size.xyz + block_cell_position * draw.chunk_origin_block_size.w;

    VertexOutput output;
    output.position = mul(frame.mvp, float4(world_position, 1.0f));
    output.local_position = block_cell_position;
    output.material_id = material_id;
    output.normal_id = normal_id;
    return output;
}
