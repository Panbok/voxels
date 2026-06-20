package world_async

//////////////////////////////////////
// Types
/////////////////////////////////////

CHUNK_BLOCK_LENGTH :: 64
CHUNK_SUBCHUNK_LENGTH :: 16
CHUNK_SUBCHUNK_COUNT_PER_AXIS :: CHUNK_BLOCK_LENGTH / CHUNK_SUBCHUNK_LENGTH
CHUNK_SUBCHUNK_COUNT ::
	CHUNK_SUBCHUNK_COUNT_PER_AXIS * CHUNK_SUBCHUNK_COUNT_PER_AXIS * CHUNK_SUBCHUNK_COUNT_PER_AXIS
TERRAIN_BINARY_AXIS_COUNT :: 3
TERRAIN_BINARY_AXIS_ROW_COUNT :: CHUNK_BLOCK_LENGTH * CHUNK_BLOCK_LENGTH
TERRAIN_MATERIAL_PALETTE_COUNT :: 8
#assert(CHUNK_BLOCK_LENGTH % CHUNK_SUBCHUNK_LENGTH == 0)
#assert(CHUNK_SUBCHUNK_COUNT == 64)

ChunkCoord :: struct {
	x, y, z: i32,
}

BlockCoord :: struct {
	x, y, z: i32,
}

BlockOccupancy :: enum u8 {
	Empty,
	Solid,
}

BlockMaterialID :: distinct u8

ChunkVoxelViewElement :: struct {
	occupancy:   BlockOccupancy,
	material_id: BlockMaterialID,
}

ChunkVoxelView :: struct {
	blocks: #soa[]ChunkVoxelViewElement,
}

ChunkBinaryGreedyRowCache :: struct {
	block_version:  u32,
	solid_rows:     [TERRAIN_BINARY_AXIS_COUNT][TERRAIN_BINARY_AXIS_ROW_COUNT]u64,
	material_masks: [TERRAIN_BINARY_AXIS_COUNT][TERRAIN_BINARY_AXIS_ROW_COUNT]u8,
	material_rows:  [TERRAIN_BINARY_AXIS_COUNT][TERRAIN_MATERIAL_PALETTE_COUNT][TERRAIN_BINARY_AXIS_ROW_COUNT]u64,
}

ChunkBlockStorage :: struct {
	voxel_view:              ChunkVoxelView,
	binary_greedy_row_cache: ^ChunkBinaryGreedyRowCache,
}

ChunkDirtyRegion :: struct {
	valid: bool,
	min:   BlockCoord,
	max:   BlockCoord,
}

ChunkMeshBoundaryPolicy :: enum {
	Treat_Out_Of_Chunk_As_Empty,
	Sample_Neighbor_Snapshots,
}

ChunkSnapshot :: struct {
	coord:                   ChunkCoord,
	voxel_view:              ChunkVoxelView,
	block_version:           u32,
	dirty_region:            ChunkDirtyRegion,
	binary_greedy_row_cache: ^ChunkBinaryGreedyRowCache,
}

ChunkMeshNeighborSnapshots :: struct {
	plus_x, minus_x: Maybe(ChunkSnapshot),
	plus_y, minus_y: Maybe(ChunkSnapshot),
	plus_z, minus_z: Maybe(ChunkSnapshot),
}

TerrainPackedVertex :: distinct u32
#assert(size_of(TerrainPackedVertex) == 4)

ChunkMeshOutput :: struct {
	vertices:   []TerrainPackedVertex,
	indices:    []u32,
	face_count: u32,
}

//////////////////////////////////////
// Generation Types
/////////////////////////////////////

ChunkGenerationQuality :: enum u8 {
	Full,
	Proxy,
}

ChunkGenerationJob :: struct {
	coord:         ChunkCoord,
	seed:          u32,
	block_storage: ChunkBlockStorage,
	prewarm:       bool,
	quality:       ChunkGenerationQuality,
}

ChunkGenerationJobResult :: struct {
	coord:                  ChunkCoord,
	block_storage:          ChunkBlockStorage,
	prewarm:                bool,
	quality:                ChunkGenerationQuality,
	generation_duration_us: u64,
}

//////////////////////////////////////
// Meshing Types
/////////////////////////////////////

ChunkMeshing :: enum {
	Greedy_Binary,
}

ChunkMeshScopeKind :: enum {
	Full_Chunk,
	Subchunk,
}

ChunkMeshJob :: struct {
	mesher:          ChunkMeshing,
	scope_kind:      ChunkMeshScopeKind,
	subchunk_index:  u32,
	snapshot:        ChunkSnapshot,
	neighbors:       ChunkMeshNeighborSnapshots,
	boundary_policy: ChunkMeshBoundaryPolicy,
}

ChunkMeshJobResult :: struct {
	coord:          ChunkCoord,
	block_version:  u32,
	scope_kind:     ChunkMeshScopeKind,
	subchunk_index: u32,
	worker_index:   u32,
	output:         ChunkMeshOutput,
}
