ByteAddressBuffer GeometryVertices : register(t0, space0);

static const uint LOCAL_X_SHIFT = 0;
static const uint LOCAL_Y_SHIFT = 7;
static const uint LOCAL_Z_SHIFT = 14;
static const uint NORMAL_SHIFT = 21;
static const uint MATERIAL_SHIFT = 24;

static const uint LOCAL_MASK = 0x7Fu;
static const uint NORMAL_MASK = 0x7u;
static const uint MATERIAL_MASK = 0xFFu;

struct VSOutput
{
    float3 LocalPosition : TEXCOORD0;
    nointerpolation uint MaterialID : TEXCOORD1;
    nointerpolation uint NormalID : TEXCOORD2;
    float4 Position : SV_POSITION;
};

cbuffer Frame : register(b0, space1)
{
    float4x4 MVP;
};

cbuffer Draw : register(b1, space1)
{
    uint VertexByteOffset;
    uint VertexStrideBytes;
    uint2 _Padding0;
    float4 ChunkOrigin_BlockSize; // xyz = origin, w = block_world_size
};

VSOutput main(uint vertexIndex: SV_VertexID)
{
    uint vertexByteOffset = VertexByteOffset + vertexIndex * VertexStrideBytes;
    uint packed = GeometryVertices.Load(vertexByteOffset);

    uint blockX = (packed >> LOCAL_X_SHIFT) & LOCAL_MASK;
    uint blockY = (packed >> LOCAL_Y_SHIFT) & LOCAL_MASK;
    uint blockZ = (packed >> LOCAL_Z_SHIFT) & LOCAL_MASK;
    uint normalID = (packed >> NORMAL_SHIFT) & NORMAL_MASK;
    uint materialID = (packed >> MATERIAL_SHIFT) & MATERIAL_MASK;

    float3 blockCellPosition = float3(blockX, blockY, blockZ);
    float3 worldPosition = ChunkOrigin_BlockSize.xyz + blockCellPosition * ChunkOrigin_BlockSize.w;

    VSOutput output;
    output.Position = mul(MVP, float4(worldPosition, 1.0));
    output.LocalPosition = blockCellPosition;
    output.MaterialID = materialID;
    output.NormalID = normalID;
    return output;
}
