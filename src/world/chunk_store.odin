package world

import world_async "async:world"
import "core:log"
import math "core:math"
import "core:mem"

import biomes "world:biomes"

//////////////////////////////////////
// Chunk Store Types
/////////////////////////////////////

ChunkStore :: struct {
	chunks:                  []Chunk,
	chunk_count:             u32,
	subchunk_geometry_count: u32,
}

//////////////////////////////////////
// Chunk Store Accessor Methods
/////////////////////////////////////

chunk_store_chunks :: proc() -> []Chunk {
	return state.chunk_store.chunks[:state.chunk_store.chunk_count]
}

chunk_store_subchunk_geometry_has_any :: proc() -> bool {
	return state.chunk_store.subchunk_geometry_count > 0
}

chunk_store_subchunk_geometry_count :: proc() -> u32 {
	return state.chunk_store.subchunk_geometry_count
}

//////////////////////////////////////
// Block Query Types
/////////////////////////////////////

ChunkBlockSample :: struct {
	block:       world_async.BlockCoord,
	chunk_coord: world_async.ChunkCoord,
	local:       world_async.BlockCoord,
	occupancy:   world_async.BlockOccupancy,
	material_id: world_async.BlockMaterialID,
}

//////////////////////////////////////
// Chunk Types
/////////////////////////////////////

ChunkBounds :: struct {
	min, max: world_async.BlockCoord,
}

ChunkID :: struct {
	index:      u32,
	generation: u32,
}

INVALID_CHUNK_ID :: ChunkID {
	index      = max(u32),
	generation = 0,
}

ChunkGenerationState :: enum {
	Missing,
	Queued,
	Generated,
}
ChunkMeshState :: enum {
	Missing,
	Dirty,
	Queued,
	Ready,
}

ChunkDirtyFlag :: enum u8 {
	Blocks,
	Boundary,
}

ChunkDirtyFlags :: bit_set[ChunkDirtyFlag]

Chunk :: struct {
	block_storage:             world_async.ChunkBlockStorage,
	coord:                     world_async.ChunkCoord,
	geometry_id:               ChunkGeometryID,
	subchunk_geometry_ids:     [CHUNK_SUBCHUNK_COUNT]ChunkGeometryID,
	subchunk_geometry_count:   u32,
	subchunk_geometry_mask:    u64,
	subchunk_dirty_mask:       u64,
	subchunk_ready_mask:       u64,
	queued_subchunk_index:     u32,
	generation_state:          ChunkGenerationState,
	generation_quality:        world_async.ChunkGenerationQuality,
	full_generation_queued:    bool,
	mesh_state:                ChunkMeshState,
	dirty_flags:               ChunkDirtyFlags,
	dirty_region:              world_async.ChunkDirtyRegion,
	visibility_graph:          ChunkVisibilityGraph,
	mesh_snapshot_ref_count:   u32,
	queued_mesh_snapshot_refs: ChunkMeshSnapshotRefSet,
	slot_generation:           u32,
	block_version:             u32,
	mesh_version:              u32,
}

//////////////////////////////////////
// Chunk Methods
/////////////////////////////////////

chunk_create :: proc(coord: world_async.ChunkCoord) -> Chunk {
	return {
		coord = coord,
		geometry_id = INVALID_CHUNK_GEOMETRY_ID,
		queued_subchunk_index = CHUNK_SUBCHUNK_INVALID_INDEX,
		generation_state = .Missing,
		generation_quality = .Full,
		mesh_state = .Missing,
		dirty_flags = {},
		slot_generation = 1,
		block_version = 0,
		mesh_version = 0,
	}
}

//////////////////////////////////////
// Chunk Dirty Region Methods
/////////////////////////////////////

chunk_dirty_region_clear :: proc(chunk: ^Chunk) {
	chunk.dirty_region = {}
}

chunk_dirty_region_include_local_bounds :: proc(
	chunk: ^Chunk,
	min_x, min_y, min_z, max_x, max_y, max_z: i32,
) {
	clamped_min_x := math.clamp(min_x, 0, CHUNK_BLOCK_LENGTH)
	clamped_min_y := math.clamp(min_y, 0, CHUNK_BLOCK_LENGTH)
	clamped_min_z := math.clamp(min_z, 0, CHUNK_BLOCK_LENGTH)
	clamped_max_x := math.clamp(max_x, 0, CHUNK_BLOCK_LENGTH)
	clamped_max_y := math.clamp(max_y, 0, CHUNK_BLOCK_LENGTH)
	clamped_max_z := math.clamp(max_z, 0, CHUNK_BLOCK_LENGTH)
	if clamped_min_x >= clamped_max_x ||
	   clamped_min_y >= clamped_max_y ||
	   clamped_min_z >= clamped_max_z {
		return
	}

	if !chunk.dirty_region.valid {
		chunk.dirty_region = {
			valid = true,
			min   = {clamped_min_x, clamped_min_y, clamped_min_z},
			max   = {clamped_max_x, clamped_max_y, clamped_max_z},
		}
		return
	}

	chunk.dirty_region.min.x = min(chunk.dirty_region.min.x, clamped_min_x)
	chunk.dirty_region.min.y = min(chunk.dirty_region.min.y, clamped_min_y)
	chunk.dirty_region.min.z = min(chunk.dirty_region.min.z, clamped_min_z)
	chunk.dirty_region.max.x = max(chunk.dirty_region.max.x, clamped_max_x)
	chunk.dirty_region.max.y = max(chunk.dirty_region.max.y, clamped_max_y)
	chunk.dirty_region.max.z = max(chunk.dirty_region.max.z, clamped_max_z)
}

chunk_dirty_region_include_local_block :: proc(chunk: ^Chunk, local: world_async.BlockCoord) {
	if !chunk_block_coord_is_inside(local.x, local.y, local.z) {
		return
	}

	chunk_dirty_region_include_local_bounds(
		chunk,
		local.x,
		local.y,
		local.z,
		local.x + 1,
		local.y + 1,
		local.z + 1,
	)
}

chunk_dirty_region_include_full :: proc(chunk: ^Chunk) {
	chunk_dirty_region_include_local_bounds(
		chunk,
		0,
		0,
		0,
		CHUNK_BLOCK_LENGTH,
		CHUNK_BLOCK_LENGTH,
		CHUNK_BLOCK_LENGTH,
	)
}

//////////////////////////////////////
// Chunk Subchunk Methods
/////////////////////////////////////

chunk_subchunk_mask_from_index :: proc(index: u32) -> u64 {
	log.assertf(index < CHUNK_SUBCHUNK_COUNT, "subchunk index out of range: %d", index)
	return u64(1) << index
}

chunk_subchunk_index_from_coord :: proc(x, y, z: u32) -> u32 {
	log.assertf(x < CHUNK_SUBCHUNK_COUNT_PER_AXIS, "subchunk x out of range: %d", x)
	log.assertf(y < CHUNK_SUBCHUNK_COUNT_PER_AXIS, "subchunk y out of range: %d", y)
	log.assertf(z < CHUNK_SUBCHUNK_COUNT_PER_AXIS, "subchunk z out of range: %d", z)
	return(
		x +
		y * CHUNK_SUBCHUNK_COUNT_PER_AXIS +
		z * CHUNK_SUBCHUNK_COUNT_PER_AXIS * CHUNK_SUBCHUNK_COUNT_PER_AXIS \
	)
}

chunk_subchunk_bounds_from_index :: proc(index: u32) -> (min, max: world_async.BlockCoord) {
	log.assertf(index < CHUNK_SUBCHUNK_COUNT, "subchunk index out of range: %d", index)
	sx := index % CHUNK_SUBCHUNK_COUNT_PER_AXIS
	sy := (index / CHUNK_SUBCHUNK_COUNT_PER_AXIS) % CHUNK_SUBCHUNK_COUNT_PER_AXIS
	sz := index / (CHUNK_SUBCHUNK_COUNT_PER_AXIS * CHUNK_SUBCHUNK_COUNT_PER_AXIS)

	min = {
		i32(sx * CHUNK_SUBCHUNK_LENGTH),
		i32(sy * CHUNK_SUBCHUNK_LENGTH),
		i32(sz * CHUNK_SUBCHUNK_LENGTH),
	}
	max = {
		min.x + CHUNK_SUBCHUNK_LENGTH,
		min.y + CHUNK_SUBCHUNK_LENGTH,
		min.z + CHUNK_SUBCHUNK_LENGTH,
	}
	return
}

chunk_dirty_region_subchunk_mask :: proc(region: world_async.ChunkDirtyRegion) -> u64 {
	if !region.valid {
		return 0
	}

	max_x_exclusive := region.max.x - 1
	max_y_exclusive := region.max.y - 1
	max_z_exclusive := region.max.z - 1
	min_sx := math.clamp(
		region.min.x / CHUNK_SUBCHUNK_LENGTH,
		0,
		CHUNK_SUBCHUNK_COUNT_PER_AXIS - 1,
	)
	min_sy := math.clamp(
		region.min.y / CHUNK_SUBCHUNK_LENGTH,
		0,
		CHUNK_SUBCHUNK_COUNT_PER_AXIS - 1,
	)
	min_sz := math.clamp(
		region.min.z / CHUNK_SUBCHUNK_LENGTH,
		0,
		CHUNK_SUBCHUNK_COUNT_PER_AXIS - 1,
	)
	max_sx := math.clamp(
		max_x_exclusive / CHUNK_SUBCHUNK_LENGTH,
		0,
		CHUNK_SUBCHUNK_COUNT_PER_AXIS - 1,
	)
	max_sy := math.clamp(
		max_y_exclusive / CHUNK_SUBCHUNK_LENGTH,
		0,
		CHUNK_SUBCHUNK_COUNT_PER_AXIS - 1,
	)
	max_sz := math.clamp(
		max_z_exclusive / CHUNK_SUBCHUNK_LENGTH,
		0,
		CHUNK_SUBCHUNK_COUNT_PER_AXIS - 1,
	)

	mask: u64
	for sz := u32(min_sz); sz <= u32(max_sz); sz += 1 {
		for sy := u32(min_sy); sy <= u32(max_sy); sy += 1 {
			for sx := u32(min_sx); sx <= u32(max_sx); sx += 1 {
				index := chunk_subchunk_index_from_coord(sx, sy, sz)
				mask |= chunk_subchunk_mask_from_index(index)
			}
		}
	}
	return mask
}

//////////////////////////////////////
// Chunk Subchunk Geometry Methods
/////////////////////////////////////

chunk_subchunk_dirty_mask_include_region :: proc(chunk: ^Chunk) {
	mask := chunk_dirty_region_subchunk_mask(chunk.dirty_region)
	if mask == 0 {
		return
	}

	if chunk.geometry_id == INVALID_CHUNK_GEOMETRY_ID && chunk.subchunk_ready_mask == 0 {
		return
	}

	// While a full Chunk Geometry is still active, a transition needs every
	// subchunk ready before the renderer can stop drawing the stale full Geometry.
	if chunk.geometry_id != INVALID_CHUNK_GEOMETRY_ID &&
	   chunk.subchunk_ready_mask != CHUNK_SUBCHUNK_ALL_MASK {
		mask = CHUNK_SUBCHUNK_ALL_MASK
	}

	chunk.subchunk_dirty_mask |= mask
	if chunk.mesh_state != .Queued {
		chunk.mesh_state = .Dirty
	}
}

chunk_subchunk_geometry_release_all :: proc(chunk: ^Chunk) {
	released_count: u32
	released_mask: u64
	for i := u32(0); i < CHUNK_SUBCHUNK_COUNT; i += 1 {
		if chunk.subchunk_geometry_ids[i] == INVALID_CHUNK_GEOMETRY_ID {
			continue
		}
		state.chunk_geometry_release(chunk.subchunk_geometry_ids[i])
		chunk.subchunk_geometry_ids[i] = INVALID_CHUNK_GEOMETRY_ID
		released_count += 1
		released_mask |= chunk_subchunk_mask_from_index(i)
	}
	log.assertf(
		chunk.subchunk_geometry_count == released_count,
		"subchunk geometry count mismatch during release: tracked=%d actual=%d",
		chunk.subchunk_geometry_count,
		released_count,
	)
	log.assertf(
		chunk.subchunk_geometry_mask == released_mask,
		"subchunk geometry mask mismatch during release: tracked=%#x actual=%#x",
		chunk.subchunk_geometry_mask,
		released_mask,
	)
	if released_count > 0 {
		log.assert(
			state.chunk_store.subchunk_geometry_count >= released_count,
			"subchunk geometry count underflow",
		)
		state.chunk_store.subchunk_geometry_count -= released_count
	}
	chunk.subchunk_geometry_count = 0
	chunk.subchunk_geometry_mask = 0
	chunk.subchunk_dirty_mask = 0
	chunk.subchunk_ready_mask = 0
	chunk.queued_subchunk_index = CHUNK_SUBCHUNK_INVALID_INDEX
}

chunk_subchunk_geometry_set :: proc(chunk: ^Chunk, subchunk_index: u32, new_id: ChunkGeometryID) {
	log.assertf(
		subchunk_index < CHUNK_SUBCHUNK_COUNT,
		"subchunk index out of range: %d",
		subchunk_index,
	)

	old_id := chunk.subchunk_geometry_ids[subchunk_index]
	subchunk_bit := chunk_subchunk_mask_from_index(subchunk_index)
	old_has_geometry := old_id != INVALID_CHUNK_GEOMETRY_ID
	log.assertf(
		((chunk.subchunk_geometry_mask & subchunk_bit) != 0) == old_has_geometry,
		"subchunk geometry mask mismatch before set: index=%d",
		subchunk_index,
	)
	if old_id == INVALID_CHUNK_GEOMETRY_ID && new_id != INVALID_CHUNK_GEOMETRY_ID {
		state.chunk_store.subchunk_geometry_count += 1
		chunk.subchunk_geometry_count += 1
		chunk.subchunk_geometry_mask |= subchunk_bit
	} else if old_id != INVALID_CHUNK_GEOMETRY_ID && new_id == INVALID_CHUNK_GEOMETRY_ID {
		log.assert(
			state.chunk_store.subchunk_geometry_count > 0,
			"subchunk geometry count underflow",
		)
		state.chunk_store.subchunk_geometry_count -= 1
		log.assert(chunk.subchunk_geometry_count > 0, "chunk subchunk geometry count underflow")
		chunk.subchunk_geometry_count -= 1
		chunk.subchunk_geometry_mask &~= subchunk_bit
	}
	chunk.subchunk_geometry_ids[subchunk_index] = new_id
}

chunk_subchunk_geometry_has_any :: proc(chunk: Chunk) -> bool {
	return chunk.subchunk_geometry_count > 0
}

//////////////////////////////////////
// Chunk Binary Greedy Row Cache Methods
/////////////////////////////////////

chunk_binary_greedy_row_cache_alloc :: proc() -> ^world_async.ChunkBinaryGreedyRowCache {
	cache_ptr, cache_err := mem.alloc(
		size_of(world_async.ChunkBinaryGreedyRowCache),
		align_of(world_async.ChunkBinaryGreedyRowCache),
		state.chunk_mesh_row_cache_allocator,
	)
	if cache_err != nil {
		return nil
	}

	cache := (^world_async.ChunkBinaryGreedyRowCache)(cache_ptr)
	cache^ = {}
	return cache
}

chunk_binary_greedy_row_cache_release :: proc(storage: ^world_async.ChunkBlockStorage) {
	if storage.binary_greedy_row_cache == nil {
		return
	}

	err := mem.free(rawptr(storage.binary_greedy_row_cache), state.chunk_mesh_row_cache_allocator)
	log.assertf(err == nil, "chunk binary greedy row cache release failed: %v", err)
	storage.binary_greedy_row_cache = nil
}

//////////////////////////////////////
// Chunk Methods
/////////////////////////////////////

chunk_mark_generated :: proc(
	chunk: ^Chunk,
	block_storage: world_async.ChunkBlockStorage,
	quality: world_async.ChunkGenerationQuality = .Full,
) {
	chunk.block_storage = block_storage
	chunk.generation_state = .Generated
	chunk.generation_quality = quality
	if quality == .Full {
		chunk.full_generation_queued = false
	}
	chunk.mesh_state = .Dirty
	chunk.dirty_flags = {.Blocks, .Boundary}
	chunk_dirty_region_include_full(chunk)
	chunk.block_version += 1
	if chunk.block_storage.binary_greedy_row_cache != nil {
		chunk.block_storage.binary_greedy_row_cache.block_version = chunk.block_version
	}
	chunk_visibility_graph_rebuild(chunk)
}

//////////////////////////////////////
// Chunk Coordinate Methods
/////////////////////////////////////

chunk_origin_from_coord :: proc(coord: world_async.ChunkCoord) -> world_async.BlockCoord {
	return {
		x = coord.x * CHUNK_BLOCK_LENGTH,
		y = coord.y * CHUNK_BLOCK_LENGTH,
		z = coord.z * CHUNK_BLOCK_LENGTH,
	}
}

chunk_block_bounds_from_origin :: proc(origin: world_async.BlockCoord) -> biomes.BlockBounds3 {
	return {
		min = {x = origin.x, y = origin.y, z = origin.z},
		max = {
			x = origin.x + CHUNK_BLOCK_LENGTH,
			y = origin.y + CHUNK_BLOCK_LENGTH,
			z = origin.z + CHUNK_BLOCK_LENGTH,
		},
	}
}

chunk_world_get_aabb :: proc(coord: world_async.ChunkCoord) -> WorldAABB {
	origin := terrain_chunk_origin_world_from_coord(coord)
	length := f32(CHUNK_BLOCK_LENGTH) * TERRAIN_BLOCK_WORLD_SIZE
	min := Vec3{origin[0], origin[1], origin[2]}

	return {min = min, max = min + Vec3{length, length, length}}
}

block_coord_local_from_chunk_coord :: proc(
	block: world_async.BlockCoord,
	chunk_coord: world_async.ChunkCoord,
) -> world_async.BlockCoord {
	origin := chunk_origin_from_coord(chunk_coord)
	return {x = block.x - origin.x, y = block.y - origin.y, z = block.z - origin.z}
}

block_coord_from_world_position :: proc(position: Vec3) -> world_async.BlockCoord {
	return {
		x = i32(math.floor_f32(position[0] / TERRAIN_BLOCK_WORLD_SIZE)),
		y = i32(math.floor_f32(position[1] / TERRAIN_BLOCK_WORLD_SIZE)),
		z = i32(math.floor_f32(position[2] / TERRAIN_BLOCK_WORLD_SIZE)),
	}
}

terrain_block_top_world_y :: proc(block_y: i32) -> f32 {
	return f32(block_y + 1) * TERRAIN_BLOCK_WORLD_SIZE
}

chunk_coord_from_block_coord :: proc(coord: world_async.BlockCoord) -> world_async.ChunkCoord {
	return {
		x = math.floor_div(coord.x, i32(CHUNK_BLOCK_LENGTH)),
		y = math.floor_div(coord.y, i32(CHUNK_BLOCK_LENGTH)),
		z = math.floor_div(coord.z, i32(CHUNK_BLOCK_LENGTH)),
	}
}

chunk_block_index :: proc(x, y, z: u32) -> u32 {
	log.assertf(x < CHUNK_BLOCK_LENGTH, "x out of bounds: %d", x)
	log.assertf(y < CHUNK_BLOCK_LENGTH, "y out of bounds: %d", y)
	log.assertf(z < CHUNK_BLOCK_LENGTH, "z out of bounds: %d", z)
	return x + y * CHUNK_BLOCK_LENGTH + z * CHUNK_BLOCK_LENGTH * CHUNK_BLOCK_LENGTH
}

chunk_block_coord_is_inside :: proc(x, y, z: i32) -> bool {
	return(
		x >= 0 &&
		y >= 0 &&
		z >= 0 &&
		x < CHUNK_BLOCK_LENGTH &&
		y < CHUNK_BLOCK_LENGTH &&
		z < CHUNK_BLOCK_LENGTH \
	)
}

//////////////////////////////////////
// Voxel View Methods
/////////////////////////////////////

chunk_voxel_view_alloc :: proc(voxel_view: ^world_async.ChunkVoxelView, allocator: mem.Allocator) {
	voxel_view.blocks = make(#soa[]world_async.ChunkVoxelViewElement, CHUNK_BLOCK_COUNT, allocator)
	log.assertf(
		len(voxel_view.blocks) == CHUNK_BLOCK_COUNT,
		"chunk voxel view allocation failed: expected=%d got=%d",
		CHUNK_BLOCK_COUNT,
		len(voxel_view.blocks),
	)
	chunk_voxel_view_fill_empty(voxel_view)
}

chunk_voxel_view_is_solid_local :: proc(view: world_async.ChunkVoxelView, x, y, z: u32) -> bool {
	return view.blocks.occupancy[chunk_block_index(x, y, z)] == .Solid
}

chunk_voxel_view_fill_empty :: proc(view: ^world_async.ChunkVoxelView) {
	log.assertf(
		len(view.blocks) == CHUNK_BLOCK_COUNT,
		"chunk voxel view must have %d blocks, got %d",
		CHUNK_BLOCK_COUNT,
		len(view.blocks),
	)

	mem.set(rawptr(view.blocks.occupancy), u8(world_async.BlockOccupancy.Empty), CHUNK_BLOCK_COUNT)
	mem.set(rawptr(view.blocks.material_id), u8(world_async.BlockMaterialID(0)), CHUNK_BLOCK_COUNT)
}

chunk_voxel_view_copy :: proc(dst: ^world_async.ChunkVoxelView, src: ^world_async.ChunkVoxelView) {
	log.assertf(
		len(dst.blocks) == CHUNK_BLOCK_COUNT,
		"destination chunk voxel view must have %d blocks, got %d",
		CHUNK_BLOCK_COUNT,
		len(dst.blocks),
	)
	log.assertf(
		len(src.blocks) == CHUNK_BLOCK_COUNT,
		"source chunk voxel view must have %d blocks, got %d",
		CHUNK_BLOCK_COUNT,
		len(src.blocks),
	)
	mem.copy(
		dst.blocks.occupancy,
		src.blocks.occupancy,
		int(CHUNK_BLOCK_COUNT * size_of(world_async.BlockOccupancy)),
	)
	mem.copy(
		dst.blocks.material_id,
		src.blocks.material_id,
		int(CHUNK_BLOCK_COUNT * size_of(world_async.BlockMaterialID)),
	)
}

//////////////////////////////////////
// Chunk Voxel View Fixture Methods
/////////////////////////////////////

chunk_voxel_view_debug_rect_build :: proc(
	view: ^world_async.ChunkVoxelView,
	allocator: mem.Allocator,
) {
	chunk_voxel_view_alloc(view, allocator)

	for z in DEBUG_CHUNK_SOLID_Z0 ..< DEBUG_CHUNK_SOLID_Z1 {
		for y in DEBUG_CHUNK_SOLID_Y0 ..< DEBUG_CHUNK_SOLID_Y1 {
			for x in DEBUG_CHUNK_SOLID_X0 ..< DEBUG_CHUNK_SOLID_X1 {
				index := chunk_block_index(u32(x), u32(y), u32(z))
				view.blocks.occupancy[index] = .Solid
				view.blocks.material_id[index] = world_async.BlockMaterialID(0)
			}
		}
	}
}

//////////////////////////////////////
// Chunk Store Methods
/////////////////////////////////////

chunk_store_init :: proc(capacity: u32) {
	state.chunk_store.chunks = make([]Chunk, int(capacity), state.persistent_allocator)
	state.chunk_store.chunk_count = 0
}

chunk_store_clear :: proc() {
	for i in 0 ..< state.chunk_store.chunk_count {
		chunk_store_release_chunk_resources(&state.chunk_store.chunks[i])
		state.chunk_store.chunks[i] = {}
	}
	state.chunk_store.chunk_count = 0
	log.assertf(
		state.chunk_store.subchunk_geometry_count == 0,
		"chunk store clear leaked subchunk geometry count: %d",
		state.chunk_store.subchunk_geometry_count,
	)
	state.chunk_store.subchunk_geometry_count = 0
}

chunk_store_append :: proc(chunk: Chunk) {
	log.assertf(
		state.chunk_store.chunk_count < u32(len(state.chunk_store.chunks)),
		"chunk store capacity exceeded: count=%d capacity=%d",
		state.chunk_store.chunk_count,
		len(state.chunk_store.chunks),
	)
	log.assertf(
		chunk_store_find_index_by_coord(chunk.coord) == nil,
		"duplicate chunk coordinate: %v",
		chunk.coord,
	)

	state.chunk_store.chunks[state.chunk_store.chunk_count] = chunk
	state.chunk_store.chunk_count += 1
}

chunk_store_release_chunk_resources :: proc(chunk: ^Chunk) {
	log.assertf(
		chunk.mesh_snapshot_ref_count == 0,
		"cannot release chunk while mesh snapshots still reference it: coord=%v refs=%d",
		chunk.coord,
		chunk.mesh_snapshot_ref_count,
	)

	if chunk.geometry_id != INVALID_CHUNK_GEOMETRY_ID {
		state.chunk_geometry_release(chunk.geometry_id)
		chunk.geometry_id = INVALID_CHUNK_GEOMETRY_ID
	}
	chunk_subchunk_geometry_release_all(chunk)

	chunk_block_storage_release(&chunk.block_storage)
	chunk.visibility_graph = {}
	chunk.generation_state = .Missing
	chunk.generation_quality = .Full
	chunk.full_generation_queued = false
	chunk.mesh_state = .Missing
	chunk.dirty_flags = {}
	chunk_dirty_region_clear(chunk)
	chunk.queued_mesh_snapshot_refs = {}
}

chunk_store_remove_at :: proc(index: u32) {
	log.assertf(
		index < state.chunk_store.chunk_count,
		"chunk remove index out of bounds: %d",
		index,
	)

	chunk_store_release_chunk_resources(&state.chunk_store.chunks[index])

	last_index := state.chunk_store.chunk_count - 1
	if index != last_index {
		state.chunk_store.chunks[index] = state.chunk_store.chunks[last_index]
	}

	state.chunk_store.chunks[last_index] = {}
	state.chunk_store.chunk_count -= 1

	if state.chunk_store.chunk_count == 0 ||
	   state.next_mesh_scan_index >= state.chunk_store.chunk_count {
		state.next_mesh_scan_index = 0
	}
}

chunk_store_find_index_by_coord :: proc(coord: world_async.ChunkCoord) -> Maybe(u32) {
	for i in 0 ..< state.chunk_store.chunk_count {
		if state.chunk_store.chunks[i].coord == coord {
			return i
		}
	}

	return nil
}

chunk_store_commit_mesh_results :: proc(
	results: []world_async.ChunkMeshJobResult,
) -> ChunkMeshBatchStats {
	stats := ChunkMeshBatchStats{}
	for result in results {
		stats.chunks_attempted += 1
		stats.mesh_duration_us += result.mesh_duration_us

		index, ok := chunk_store_find_index_by_coord(result.coord).?
		if !ok {
			stats.chunks_stale += 1
			state.mesh_release_result(result)
			continue
		}

		chunk := chunk_store_get_by_index(index)
		chunk_store_queued_mesh_snapshot_refs_release(chunk)

		if result.scope_kind == .Subchunk {
			result_subchunk_bit := chunk_subchunk_mask_from_index(result.subchunk_index)
			result_is_stale :=
				chunk.generation_state != .Generated ||
				chunk.block_version != result.block_version ||
				chunk.queued_subchunk_index != result.subchunk_index ||
				chunk.dirty_flags != {}
			if result_is_stale {
				stats.chunks_stale += 1
				chunk_was_generated := chunk.generation_state == .Generated
				if chunk_was_generated {
					chunk.subchunk_dirty_mask |= result_subchunk_bit
					chunk.queued_subchunk_index = CHUNK_SUBCHUNK_INVALID_INDEX
					chunk.mesh_state = .Dirty
				}
				if chunk_was_generated && chunk.dirty_flags == {} {
					chunk.dirty_flags += {.Blocks}
				}
				state.mesh_release_result(result)
				continue
			}

			stats.chunks_committed += 1
			stats.total_faces += result.output.face_count
			if result.output.face_count == 0 {
				stats.chunks_empty += 1
			} else {
				stats.chunks_uploaded += 1
			}

			old_id := chunk.subchunk_geometry_ids[result.subchunk_index]
			new_id := state.chunk_mesh_upload(old_id, result.output)
			chunk_subchunk_geometry_set(chunk, result.subchunk_index, new_id)
			chunk.subchunk_ready_mask |= result_subchunk_bit
			chunk.queued_subchunk_index = CHUNK_SUBCHUNK_INVALID_INDEX
			chunk.mesh_version = result.block_version
			chunk.dirty_flags = {}

			if chunk.geometry_id != INVALID_CHUNK_GEOMETRY_ID &&
			   chunk.subchunk_ready_mask == CHUNK_SUBCHUNK_ALL_MASK {
				state.chunk_geometry_release(chunk.geometry_id)
				chunk.geometry_id = INVALID_CHUNK_GEOMETRY_ID
			}

			chunk.mesh_state = chunk.subchunk_dirty_mask != 0 ? .Dirty : .Ready
			state.mesh_release_result(result)

			when LOG_CHUNK_MESH_COMMITS {
				log.debugf(
					"Chunk subchunk mesh: coord=%v subchunk=%d faces=%d vertices=%d indices=%d",
					chunk.coord,
					result.subchunk_index,
					result.output.face_count,
					result.output.face_count * 4,
					result.output.face_count * 6,
				)
			}
			continue
		}

		result_is_stale :=
			chunk.generation_state != .Generated ||
			chunk.mesh_state != .Queued ||
			chunk.block_version != result.block_version ||
			chunk.dirty_flags != {} ||
			chunk.queued_subchunk_index != CHUNK_SUBCHUNK_INVALID_INDEX ||
			chunk.subchunk_dirty_mask != 0
		if result_is_stale {
			stats.chunks_stale += 1
			chunk_was_generated := chunk.generation_state == .Generated
			if chunk_was_generated {
				chunk.mesh_state = .Dirty
			}
			if chunk_was_generated && chunk.dirty_flags == {} {
				chunk.dirty_flags += {.Blocks}
			}
			state.mesh_release_result(result)
			continue
		}

		stats.chunks_committed += 1
		stats.total_faces += result.output.face_count
		if result.output.face_count == 0 {
			stats.chunks_empty += 1
		} else {
			stats.chunks_uploaded += 1
		}

		chunk.geometry_id = state.chunk_mesh_upload(chunk.geometry_id, result.output)
		chunk_subchunk_geometry_release_all(chunk)
		chunk.mesh_state = .Ready
		chunk.mesh_version = result.block_version
		chunk.dirty_flags = {}
		state.mesh_release_result(result)

		when LOG_CHUNK_MESH_COMMITS {
			log.debugf(
				"Chunk mesh: coord=%v faces=%d vertices=%d indices=%d",
				chunk.coord,
				result.output.face_count,
				result.output.face_count * 4,
				result.output.face_count * 6,
			)
		}
	}

	return stats
}

chunk_id_is_valid :: proc(id: ChunkID) -> bool {
	return id != INVALID_CHUNK_ID
}

chunk_store_id_from_index :: proc(index: u32) -> ChunkID {
	log.assertf(index < state.chunk_store.chunk_count, "chunk index out of bounds: %d", index)
	chunk := &state.chunk_store.chunks[index]
	return {index = index, generation = chunk.slot_generation}
}

chunk_store_validate_id :: proc(id: ChunkID) -> bool {
	if !chunk_id_is_valid(id) || id.index >= state.chunk_store.chunk_count {
		return false
	}

	return state.chunk_store.chunks[id.index].slot_generation == id.generation
}

chunk_store_get_by_id :: proc(id: ChunkID) -> ^Chunk {
	log.assertf(chunk_store_validate_id(id), "invalid chunk id: %v", id)
	return &state.chunk_store.chunks[id.index]
}

chunk_store_get_by_index :: proc(index: u32) -> ^Chunk {
	log.assertf(index < state.chunk_store.chunk_count, "chunk index out of bounds: %d", index)
	return &state.chunk_store.chunks[index]
}

chunk_store_append_reserved :: proc(coord: world_async.ChunkCoord) -> ChunkID {
	chunk := chunk_create(coord)
	chunk_store_append(chunk)

	return chunk_store_id_from_index(state.chunk_store.chunk_count - 1)
}

chunk_store_snapshot_find_by_coord :: proc(
	coord: world_async.ChunkCoord,
) -> Maybe(world_async.ChunkSnapshot) {
	index, ok := chunk_store_find_index_by_coord(coord).?
	if !ok {
		return nil
	}

	chunk := chunk_store_get_by_index(index)
	if chunk.generation_state != .Generated {
		return nil
	}

	return chunk_snapshot_from_chunk(chunk)
}

chunk_store_mesh_neighbors_find :: proc(
	coord: world_async.ChunkCoord,
) -> world_async.ChunkMeshNeighborSnapshots {
	return {
		plus_x = chunk_store_snapshot_find_by_coord(
			world_async.ChunkCoord{coord.x + 1, coord.y, coord.z},
		),
		minus_x = chunk_store_snapshot_find_by_coord(
			world_async.ChunkCoord{coord.x - 1, coord.y, coord.z},
		),
		plus_y = chunk_store_snapshot_find_by_coord(
			world_async.ChunkCoord{coord.x, coord.y + 1, coord.z},
		),
		minus_y = chunk_store_snapshot_find_by_coord(
			world_async.ChunkCoord{coord.x, coord.y - 1, coord.z},
		),
		plus_z = chunk_store_snapshot_find_by_coord(
			world_async.ChunkCoord{coord.x, coord.y, coord.z + 1},
		),
		minus_z = chunk_store_snapshot_find_by_coord(
			world_async.ChunkCoord{coord.x, coord.y, coord.z - 1},
		),
	}
}

chunk_mesh_snapshot_ref_set_add :: proc(
	refs: ^ChunkMeshSnapshotRefSet,
	coord: world_async.ChunkCoord,
) {
	for i := u32(0); i < refs.count; i += 1 {
		if refs.coords[i] == coord {
			return
		}
	}

	log.assertf(
		refs.count < u32(len(refs.coords)),
		"chunk mesh snapshot ref set capacity exceeded",
	)
	refs.coords[refs.count] = coord
	refs.count += 1
}

chunk_mesh_snapshot_ref_set_add_snapshot :: proc(
	refs: ^ChunkMeshSnapshotRefSet,
	snapshot: Maybe(world_async.ChunkSnapshot),
) {
	snapshot_value, ok := snapshot.?
	if !ok {
		return
	}
	chunk_mesh_snapshot_ref_set_add(refs, snapshot_value.coord)
}

chunk_mesh_snapshot_refs_from_job :: proc(
	job: world_async.ChunkMeshJob,
) -> ChunkMeshSnapshotRefSet {
	refs := ChunkMeshSnapshotRefSet{}
	chunk_mesh_snapshot_ref_set_add(&refs, job.snapshot.coord)
	chunk_mesh_snapshot_ref_set_add_snapshot(&refs, job.neighbors.plus_x)
	chunk_mesh_snapshot_ref_set_add_snapshot(&refs, job.neighbors.minus_x)
	chunk_mesh_snapshot_ref_set_add_snapshot(&refs, job.neighbors.plus_y)
	chunk_mesh_snapshot_ref_set_add_snapshot(&refs, job.neighbors.minus_y)
	chunk_mesh_snapshot_ref_set_add_snapshot(&refs, job.neighbors.plus_z)
	chunk_mesh_snapshot_ref_set_add_snapshot(&refs, job.neighbors.minus_z)
	return refs
}

chunk_store_mesh_snapshot_refs_acquire :: proc(refs: ChunkMeshSnapshotRefSet) {
	for i := u32(0); i < refs.count; i += 1 {
		index, ok := chunk_store_find_index_by_coord(refs.coords[i]).?
		log.assertf(ok, "mesh snapshot ref target chunk missing: coord=%v", refs.coords[i])

		chunk := chunk_store_get_by_index(index)
		chunk.mesh_snapshot_ref_count += 1
	}
}

chunk_store_mesh_snapshot_refs_release :: proc(refs: ChunkMeshSnapshotRefSet) {
	for i := u32(0); i < refs.count; i += 1 {
		index, ok := chunk_store_find_index_by_coord(refs.coords[i]).?
		log.assertf(
			ok,
			"mesh snapshot ref target chunk missing during release: coord=%v",
			refs.coords[i],
		)

		chunk := chunk_store_get_by_index(index)
		log.assertf(
			chunk.mesh_snapshot_ref_count > 0,
			"mesh snapshot ref count underflow: coord=%v",
			refs.coords[i],
		)
		chunk.mesh_snapshot_ref_count -= 1
	}
}

chunk_store_queued_mesh_snapshot_refs_release :: proc(chunk: ^Chunk) {
	if chunk.queued_mesh_snapshot_refs.count == 0 {
		return
	}

	chunk_store_mesh_snapshot_refs_release(chunk.queued_mesh_snapshot_refs)
	chunk.queued_mesh_snapshot_refs = {}
}

chunk_store_queued_mesh_snapshot_refs_release_all_for_shutdown :: proc() {
	for i in 0 ..< state.chunk_store.chunk_count {
		chunk_store_queued_mesh_snapshot_refs_release(&state.chunk_store.chunks[i])
	}

	for chunk in state.chunk_store.chunks[:state.chunk_store.chunk_count] {
		log.assertf(
			chunk.mesh_snapshot_ref_count == 0,
			"shutdown left mesh snapshot refs unreleased: coord=%v refs=%d",
			chunk.coord,
			chunk.mesh_snapshot_ref_count,
		)
	}
}

chunk_snapshot_find_by_coord :: proc(
	snapshots: []world_async.ChunkSnapshot,
	coord: world_async.ChunkCoord,
) -> Maybe(world_async.ChunkSnapshot) {
	for i in 0 ..< len(snapshots) {
		if snapshots[i].coord == coord {
			return snapshots[i]
		}
	}
	return nil
}

chunk_mesh_neighbors_find :: proc(
	snapshots: []world_async.ChunkSnapshot,
	coord: world_async.ChunkCoord,
) -> world_async.ChunkMeshNeighborSnapshots {
	return {
		plus_x = chunk_snapshot_find_by_coord(
			snapshots,
			world_async.ChunkCoord{coord.x + 1, coord.y, coord.z},
		),
		minus_x = chunk_snapshot_find_by_coord(
			snapshots,
			world_async.ChunkCoord{coord.x - 1, coord.y, coord.z},
		),
		plus_y = chunk_snapshot_find_by_coord(
			snapshots,
			world_async.ChunkCoord{coord.x, coord.y + 1, coord.z},
		),
		minus_y = chunk_snapshot_find_by_coord(
			snapshots,
			world_async.ChunkCoord{coord.x, coord.y - 1, coord.z},
		),
		plus_z = chunk_snapshot_find_by_coord(
			snapshots,
			world_async.ChunkCoord{coord.x, coord.y, coord.z + 1},
		),
		minus_z = chunk_snapshot_find_by_coord(
			snapshots,
			world_async.ChunkCoord{coord.x, coord.y, coord.z - 1},
		),
	}
}

chunk_block_storage_alloc :: proc {
	chunk_block_storage_alloc_with_allocator,
	chunk_block_storage_alloc_for_store,
}

chunk_block_storage_alloc_with_allocator :: proc(
	allocator: mem.Allocator,
) -> world_async.ChunkBlockStorage {
	storage := world_async.ChunkBlockStorage{}
	chunk_voxel_view_alloc(&storage.voxel_view, allocator)
	return storage
}

chunk_block_storage_alloc_for_store :: proc() -> world_async.ChunkBlockStorage {
	storage := chunk_block_storage_alloc(state.chunk_block_storage_allocator)
	storage.binary_greedy_row_cache = chunk_binary_greedy_row_cache_alloc()
	return storage
}

chunk_block_storage_release :: proc(storage: ^world_async.ChunkBlockStorage) {
	if len(storage.voxel_view.blocks) == 0 {
		chunk_binary_greedy_row_cache_release(storage)
		return
	}

	chunk_binary_greedy_row_cache_release(storage)
	err := delete(storage.voxel_view.blocks, state.chunk_block_storage_allocator)
	log.assertf(err == nil, "chunk block storage release failed: %v", err)
	storage^ = {}
}

when ODIN_DEBUG {
	debug_chunk_block_storage_pool_contract_checks_run :: proc() {
		storages: [CHUNK_STORE_CAPACITY]world_async.ChunkBlockStorage
		for i in 0 ..< CHUNK_STORE_CAPACITY {
			storages[i] = chunk_block_storage_alloc_for_store()
		}
		for i in 0 ..< CHUNK_STORE_CAPACITY {
			chunk_block_storage_release(&storages[i])
		}
		log.debug("Chunk block storage pool contract checks passed")
	}
}

chunk_snapshot_from_chunk :: proc(chunk: ^Chunk) -> world_async.ChunkSnapshot {
	log.assertf(
		chunk.generation_state == .Generated,
		"chunk must be generated before creating a snapshot",
	)
	log.assertf(
		len(chunk.block_storage.voxel_view.blocks) == CHUNK_BLOCK_COUNT,
		"chunk must have the correct number of blocks",
	)
	log.assertf(chunk.block_version > 0, "chunk block version must be greater than 0")
	binary_greedy_row_cache := chunk.block_storage.binary_greedy_row_cache
	if binary_greedy_row_cache != nil &&
	   binary_greedy_row_cache.block_version != chunk.block_version {
		binary_greedy_row_cache = nil
	}
	return {
		coord = chunk.coord,
		voxel_view = chunk.block_storage.voxel_view,
		block_version = chunk.block_version,
		dirty_region = chunk.dirty_region,
		binary_greedy_row_cache = binary_greedy_row_cache,
	}
}

//////////////////////////////////////
// Generation Methods
/////////////////////////////////////

generation_job_execute_sync :: proc(
	job: world_async.ChunkGenerationJob,
) -> world_async.ChunkGenerationJobResult {
	block_storage := job.block_storage
	log.assertf(
		len(block_storage.voxel_view.blocks) == CHUNK_BLOCK_COUNT,
		"generation job output storage has wrong block count",
	)
	terrain_heightfield_voxel_view_fill_quality(
		&block_storage.voxel_view,
		job.coord,
		job.seed,
		job.quality,
	)
	if block_storage.binary_greedy_row_cache != nil {
		terrain_binary_row_cache_fill(
			block_storage.binary_greedy_row_cache,
			block_storage.voxel_view,
			0,
		)
	}
	return {
		coord = job.coord,
		block_storage = block_storage,
		prewarm = job.prewarm,
		quality = job.quality,
	}
}

//////////////////////////////////////
// Chunk Store Dirty Region Methods
/////////////////////////////////////

chunk_store_mark_generated_chunk_local_dirty :: proc(
	coord: world_async.ChunkCoord,
	local_min, local_max: world_async.BlockCoord,
	flags: ChunkDirtyFlags,
) {
	index, ok := chunk_store_find_index_by_coord(coord).?
	if !ok {
		return
	}

	chunk := chunk_store_get_by_index(index)
	if chunk.generation_state != .Generated {
		return
	}

	chunk.dirty_flags += flags
	chunk_dirty_region_include_local_bounds(
		chunk,
		local_min.x,
		local_min.y,
		local_min.z,
		local_max.x,
		local_max.y,
		local_max.z,
	)
	if chunk.mesh_state != .Queued {
		chunk.mesh_state = .Dirty
	}
}

chunk_store_mark_generated_neighbors_boundary_dirty :: proc(coord: world_async.ChunkCoord) {
	chunk_store_mark_generated_chunk_local_dirty(
		world_async.ChunkCoord{coord.x + 1, coord.y, coord.z},
		{0, 0, 0},
		{1, CHUNK_BLOCK_LENGTH, CHUNK_BLOCK_LENGTH},
		{.Boundary},
	)
	chunk_store_mark_generated_chunk_local_dirty(
		world_async.ChunkCoord{coord.x - 1, coord.y, coord.z},
		{CHUNK_BLOCK_LENGTH - 1, 0, 0},
		{CHUNK_BLOCK_LENGTH, CHUNK_BLOCK_LENGTH, CHUNK_BLOCK_LENGTH},
		{.Boundary},
	)
	chunk_store_mark_generated_chunk_local_dirty(
		world_async.ChunkCoord{coord.x, coord.y + 1, coord.z},
		{0, 0, 0},
		{CHUNK_BLOCK_LENGTH, 1, CHUNK_BLOCK_LENGTH},
		{.Boundary},
	)
	chunk_store_mark_generated_chunk_local_dirty(
		world_async.ChunkCoord{coord.x, coord.y - 1, coord.z},
		{0, CHUNK_BLOCK_LENGTH - 1, 0},
		{CHUNK_BLOCK_LENGTH, CHUNK_BLOCK_LENGTH, CHUNK_BLOCK_LENGTH},
		{.Boundary},
	)
	chunk_store_mark_generated_chunk_local_dirty(
		world_async.ChunkCoord{coord.x, coord.y, coord.z + 1},
		{0, 0, 0},
		{CHUNK_BLOCK_LENGTH, CHUNK_BLOCK_LENGTH, 1},
		{.Boundary},
	)
	chunk_store_mark_generated_chunk_local_dirty(
		world_async.ChunkCoord{coord.x, coord.y, coord.z - 1},
		{0, 0, CHUNK_BLOCK_LENGTH - 1},
		{CHUNK_BLOCK_LENGTH, CHUNK_BLOCK_LENGTH, CHUNK_BLOCK_LENGTH},
		{.Boundary},
	)
}

//////////////////////////////////////
// Chunk Store Query Methods
/////////////////////////////////////

chunk_solid_block_at_world_block :: proc(
	chunk: ^Chunk,
	block: world_async.BlockCoord,
) -> Maybe(world_async.BlockCoord) {
	if chunk.generation_state != .Generated {
		return nil
	}
	log.assertf(
		len(chunk.block_storage.voxel_view.blocks) == CHUNK_BLOCK_COUNT,
		"generated chunk must have %d blocks, got %d",
		CHUNK_BLOCK_COUNT,
		len(chunk.block_storage.voxel_view.blocks),
	)

	local := block_coord_local_from_chunk_coord(block, chunk.coord)
	if !chunk_block_coord_is_inside(local.x, local.y, local.z) {
		return nil
	}

	if !chunk_voxel_view_is_solid_local(
		chunk.block_storage.voxel_view,
		u32(local.x),
		u32(local.y),
		u32(local.z),
	) {
		return nil
	}

	return block
}

chunk_store_block_get :: proc(block: world_async.BlockCoord) -> Maybe(ChunkBlockSample) {
	chunk_coord := chunk_coord_from_block_coord(block)
	index, ok := chunk_store_find_index_by_coord(chunk_coord).?
	if !ok {
		return nil
	}

	chunk := chunk_store_get_by_index(index)
	if chunk.generation_state != .Generated {
		return nil
	}
	log.assertf(
		len(chunk.block_storage.voxel_view.blocks) == CHUNK_BLOCK_COUNT,
		"generated chunk must have %d blocks, got %d",
		CHUNK_BLOCK_COUNT,
		len(chunk.block_storage.voxel_view.blocks),
	)

	local := block_coord_local_from_chunk_coord(block, chunk.coord)
	if !chunk_block_coord_is_inside(local.x, local.y, local.z) {
		return nil
	}

	block_index := chunk_block_index(u32(local.x), u32(local.y), u32(local.z))
	return ChunkBlockSample {
		block = block,
		chunk_coord = chunk_coord,
		local = local,
		occupancy = chunk.block_storage.voxel_view.blocks.occupancy[block_index],
		material_id = chunk.block_storage.voxel_view.blocks.material_id[block_index],
	}
}

chunk_store_solid_block_at_world_position :: proc(
	position: Vec3,
) -> Maybe(world_async.BlockCoord) {
	block := block_coord_from_world_position(position)
	chunk_coord := chunk_coord_from_block_coord(block)
	index, ok := chunk_store_find_index_by_coord(chunk_coord).?
	if !ok {
		return nil
	}

	chunk := chunk_store_get_by_index(index)
	return chunk_solid_block_at_world_block(chunk, block)
}

chunk_store_coord_is_generated :: proc(coord: world_async.ChunkCoord) -> bool {
	index, ok := chunk_store_find_index_by_coord(coord).?
	if !ok {
		return false
	}

	chunk := chunk_store_get_by_index(index)
	return chunk.generation_state == .Generated
}

//////////////////////////////////////
// Block Edit Dirty Region Methods
/////////////////////////////////////

chunk_store_mark_neighbor_block_dirty :: proc(
	coord: world_async.ChunkCoord,
	local: world_async.BlockCoord,
) {
	chunk_store_mark_generated_chunk_local_dirty(
		coord,
		local,
		{local.x + 1, local.y + 1, local.z + 1},
		{.Boundary},
	)

	index, ok := chunk_store_find_index_by_coord(coord).?
	if !ok {
		return
	}
	chunk := chunk_store_get_by_index(index)
	chunk_subchunk_dirty_mask_include_region(chunk)
}

chunk_store_mark_edit_neighbors_dirty :: proc(chunk: ^Chunk, local: world_async.BlockCoord) {
	neighbors := [?]struct {
		coord: world_async.ChunkCoord,
		local: world_async.BlockCoord,
	} {
		{
			coord = {chunk.coord.x - 1, chunk.coord.y, chunk.coord.z},
			local = {CHUNK_BLOCK_LENGTH - 1, local.y, local.z},
		},
		{coord = {chunk.coord.x + 1, chunk.coord.y, chunk.coord.z}, local = {0, local.y, local.z}},
		{
			coord = {chunk.coord.x, chunk.coord.y - 1, chunk.coord.z},
			local = {local.x, CHUNK_BLOCK_LENGTH - 1, local.z},
		},
		{coord = {chunk.coord.x, chunk.coord.y + 1, chunk.coord.z}, local = {local.x, 0, local.z}},
		{
			coord = {chunk.coord.x, chunk.coord.y, chunk.coord.z - 1},
			local = {local.x, local.y, CHUNK_BLOCK_LENGTH - 1},
		},
		{coord = {chunk.coord.x, chunk.coord.y, chunk.coord.z + 1}, local = {local.x, local.y, 0}},
	}

	for neighbor, neighbor_index in neighbors {
		switch neighbor_index {
		case 0:
			if local.x != 0 {continue}
		case 1:
			if local.x != CHUNK_BLOCK_LOCAL_MAX {continue}
		case 2:
			if local.y != 0 {continue}
		case 3:
			if local.y != CHUNK_BLOCK_LOCAL_MAX {continue}
		case 4:
			if local.z != 0 {continue}
		case 5:
			if local.z != CHUNK_BLOCK_LOCAL_MAX {continue}
		}
		chunk_store_mark_neighbor_block_dirty(neighbor.coord, neighbor.local)
	}
}

chunk_store_mark_edited_block_dirty :: proc(chunk: ^Chunk, local: world_async.BlockCoord) {
	chunk.dirty_flags += {.Blocks}
	for dz := i32(-1); dz <= 1; dz += 1 {
		for dy := i32(-1); dy <= 1; dy += 1 {
			for dx := i32(-1); dx <= 1; dx += 1 {
				if abs(dx) + abs(dy) + abs(dz) > 1 {
					continue
				}
				chunk_dirty_region_include_local_block(
					chunk,
					{local.x + dx, local.y + dy, local.z + dz},
				)
			}
		}
	}
	if chunk.mesh_state != .Queued {
		chunk.mesh_state = .Dirty
	}
	chunk_subchunk_dirty_mask_include_region(chunk)
	chunk_store_mark_edit_neighbors_dirty(chunk, local)
}

//////////////////////////////////////
// Block Edit Methods
/////////////////////////////////////

chunk_store_block_edit_apply :: proc(
	block: world_async.BlockCoord,
	occupancy: world_async.BlockOccupancy,
	material_id: world_async.BlockMaterialID,
) -> bool {
	chunk_coord := chunk_coord_from_block_coord(block)
	index, ok := chunk_store_find_index_by_coord(chunk_coord).?
	if !ok {
		return false
	}

	chunk := chunk_store_get_by_index(index)
	if chunk.generation_state != .Generated {
		return false
	}
	if chunk.generation_quality != .Full {
		return false
	}
	local := block_coord_local_from_chunk_coord(block, chunk.coord)
	if !chunk_block_coord_is_inside(local.x, local.y, local.z) {
		return false
	}

	block_index := chunk_block_index(u32(local.x), u32(local.y), u32(local.z))
	old_occupancy := chunk.block_storage.voxel_view.blocks.occupancy[block_index]
	old_material_id := chunk.block_storage.voxel_view.blocks.material_id[block_index]
	if old_occupancy == occupancy && old_material_id == material_id {
		return false
	}

	chunk.block_storage.voxel_view.blocks.occupancy[block_index] = occupancy
	chunk.block_storage.voxel_view.blocks.material_id[block_index] = material_id
	chunk.block_version += 1

	if chunk.block_storage.binary_greedy_row_cache != nil {
		terrain_binary_row_cache_apply_block_edit(
			chunk.block_storage.binary_greedy_row_cache,
			u32(local.x),
			u32(local.y),
			u32(local.z),
			old_occupancy,
			old_material_id,
			occupancy,
			material_id,
			chunk.block_version,
		)
	}

	chunk_visibility_graph_rebuild(chunk)
	chunk_store_mark_edited_block_dirty(chunk, local)
	return true
}
