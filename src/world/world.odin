package world

//////////////////////////////////////
// Coordinate Types
/////////////////////////////////////

ChunkCoord :: struct {
	x, y, z: i32,
}

BlockCoord :: struct {
	x, y, z: i32,
}

//////////////////////////////////////
// Block Types
/////////////////////////////////////

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

ChunkBlockStorage :: struct {
	voxel_view: ChunkVoxelView,
}

//////////////////////////////////////
// Chunk Meshing Types
/////////////////////////////////////

ChunkMeshBoundaryPolicy :: enum {
	Treat_Out_Of_Chunk_As_Empty,
	Sample_Neighbor_Snapshots,
}

ChunkSnapshot :: struct {
	coord:         ChunkCoord,
	voxel_view:    ChunkVoxelView,
	block_version: u32,
}

ChunkMeshNeighborSnapshots :: struct {
	plus_x, minus_x: Maybe(ChunkSnapshot),
	plus_y, minus_y: Maybe(ChunkSnapshot),
	plus_z, minus_z: Maybe(ChunkSnapshot),
}

//////////////////////////////////////
// Terrain Geometry Types
/////////////////////////////////////

TerrainPackedVertex :: distinct u32
#assert(size_of(TerrainPackedVertex) == 4)

ChunkMeshOutput :: struct {
	vertices:   []TerrainPackedVertex,
	indices:    []u32,
	face_count: u32,
}
