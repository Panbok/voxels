ByteAddressBuffer GeometryVertices : register(t0, space0);

static const uint LOCAL_X_SHIFT = 0;
static const uint LOCAL_Y_SHIFT = 6;
static const uint LOCAL_Z_SHIFT = 12;
static const uint NORMAL_SHIFT = 18;
static const uint MATERIAL_SHIFT = 21;
static const uint CORNER_SHIFT = 29;

static const uint LOCAL_MASK = 0x3Fu;
static const uint NORMAL_MASK = 0x7u;
static const uint MATERIAL_MASK = 0xFFu;
static const uint CORNER_MASK = 0x3u;

static const float3 TERRAIN_FACE_CORNER_OFFSETS[24] = {
	// +X
	float3(1.0f, 0.0f, 0.0f),
	float3(1.0f, 1.0f, 0.0f),
	float3(1.0f, 1.0f, 1.0f),
	float3(1.0f, 0.0f, 1.0f),

	// -X
	float3(0.0f, 0.0f, 0.0f),
	float3(0.0f, 0.0f, 1.0f),
	float3(0.0f, 1.0f, 1.0f),
	float3(0.0f, 1.0f, 0.0f),

	// +Y
	float3(0.0f, 1.0f, 0.0f),
	float3(0.0f, 1.0f, 1.0f),
	float3(1.0f, 1.0f, 1.0f),
	float3(1.0f, 1.0f, 0.0f),

	// -Y
	float3(0.0f, 0.0f, 0.0f),
	float3(1.0f, 0.0f, 0.0f),
	float3(1.0f, 0.0f, 1.0f),
	float3(0.0f, 0.0f, 1.0f),

	// +Z
	float3(0.0f, 0.0f, 1.0f),
	float3(1.0f, 0.0f, 1.0f),
	float3(1.0f, 1.0f, 1.0f),
	float3(0.0f, 1.0f, 1.0f),

	// -Z
	float3(0.0f, 0.0f, 0.0f),
	float3(0.0f, 1.0f, 0.0f),
	float3(1.0f, 1.0f, 0.0f),
	float3(1.0f, 0.0f, 0.0f),
};

struct VSOutput {
	float3 LocalPosition : TEXCOORD0;
	nointerpolation uint MaterialID : TEXCOORD1;
	nointerpolation uint NormalID : TEXCOORD2;
	nointerpolation uint CornerID : TEXCOORD3;
	float4 Position : SV_POSITION;
};

cbuffer Frame : register(b0, space1) {
	float4x4 MVP;
};

cbuffer Draw : register(b1, space1) {
	uint VertexByteOffset;
	uint VertexStrideBytes;
	uint2 _Padding0;
	float4 ChunkOrigin_BlockSize; // xyz = origin, w = block_world_size
};

float3 terrain_face_corner_offset(uint normalID, uint cornerID)
{
	return normalID < 6u
		? TERRAIN_FACE_CORNER_OFFSETS[normalID * 4u + cornerID]
		: float3(0.0f, 0.0f, 0.0f);
}

VSOutput main(uint vertexIndex : SV_VertexID) {
	uint vertexByteOffset = VertexByteOffset + vertexIndex * VertexStrideBytes;
    uint packed = GeometryVertices.Load(vertexByteOffset);

    uint blockX = (packed >> LOCAL_X_SHIFT) & LOCAL_MASK;
    uint blockY = (packed >> LOCAL_Y_SHIFT) & LOCAL_MASK;
    uint blockZ = (packed >> LOCAL_Z_SHIFT) & LOCAL_MASK;
    uint normalID = (packed >> NORMAL_SHIFT) & NORMAL_MASK;
    uint materialID = (packed >> MATERIAL_SHIFT) & MATERIAL_MASK;
    uint cornerID = (packed >> CORNER_SHIFT) & CORNER_MASK;

    float3 blockCellPosition = float3(blockX, blockY, blockZ);
    float3 localPosition = blockCellPosition + terrain_face_corner_offset(normalID, cornerID);
    float3 worldPosition = ChunkOrigin_BlockSize.xyz + localPosition * ChunkOrigin_BlockSize.w;

    VSOutput output;
    output.Position = mul(MVP, float4(worldPosition, 1.0));
    output.LocalPosition = localPosition;
    output.MaterialID = materialID;
    output.NormalID = normalID;
    output.CornerID = cornerID;
    return output;
}
