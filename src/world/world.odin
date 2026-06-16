package world

import world_async "async:world"
import "core:log"
import math "core:math"
import bits "core:math/bits"
import "core:mem"
import mem_tlsf "core:mem/tlsf"
import time "core:time"
import biomes "world:biomes"

//////////////////////////////////////
// Types
/////////////////////////////////////

UVec2 :: [2]u32

Vec3 :: [3]f32
Vec4 :: [4]f32

WorldAABB :: struct {
	min, max: Vec3,
}

ChunkGeometryID :: distinct u32
INVALID_CHUNK_GEOMETRY_ID :: ChunkGeometryID(0)

//////////////////////////////////////
// Chunk Store Types
/////////////////////////////////////

ChunkStore :: struct {
	chunks:                  []Chunk,
	chunk_count:             u32,
	subchunk_geometry_count: u32,
}

//////////////////////////////////////
// Streaming Types
/////////////////////////////////////

StreamingState :: struct {
	streaming_center_coord:      world_async.ChunkCoord,
	streaming_targets:           [CHUNK_STREAMING_TARGET_CAPACITY]world_async.ChunkCoord,
	streaming_target_count:      u32,
	next_streaming_target_index: u32,
	next_mesh_scan_index:        u32,
}

//////////////////////////////////////
// Streaming Update Types
/////////////////////////////////////

StreamingUpdateStats :: struct {
	chunks_generated:             u32,
	chunks_evicted:               u32,
	chunk_mesh_jobs_submitted:    u32,
	chunk_mesh_results_committed: u32,
	chunk_mesh_results_uploaded:  u32,
	chunks_dirty_remaining:       u32,
}

//////////////////////////////////////
// Callback Types
/////////////////////////////////////

GenerationRequestProc :: #type proc(job: world_async.ChunkGenerationJob) -> bool
GenerationPollResultsProc :: #type proc(results: []world_async.ChunkGenerationJobResult) -> u32
MeshRequestProc :: #type proc(job: world_async.ChunkMeshJob) -> bool
MeshPollResultsProc :: #type proc(results: []world_async.ChunkMeshJobResult) -> u32
MeshReleaseResultProc :: #type proc(result: world_async.ChunkMeshJobResult)
ChunkMeshUploadProc :: #type proc(
	old_id: ChunkGeometryID,
	output: world_async.ChunkMeshOutput,
) -> ChunkGeometryID
ChunkGeometryReleaseProc :: #type proc(id: ChunkGeometryID)

InitConfig :: struct {
	persistent_allocator:    mem.Allocator,
	generation_request:      GenerationRequestProc,
	generation_poll_results: GenerationPollResultsProc,
	mesh_request:            MeshRequestProc,
	mesh_poll_results:       MeshPollResultsProc,
	mesh_release_result:     MeshReleaseResultProc,
	chunk_mesh_upload:       ChunkMeshUploadProc,
	chunk_geometry_release:  ChunkGeometryReleaseProc,
}

//////////////////////////////////////
// State
/////////////////////////////////////

state := struct {
	// Memory
	persistent_allocator:           mem.Allocator,
	chunk_block_storage_buffer:     []u8,
	chunk_block_storage_tlsf:       mem_tlsf.Allocator,
	chunk_block_storage_allocator:  mem.Allocator,
	chunk_mesh_row_cache_buffer:    []u8,
	chunk_mesh_row_cache_tlsf:      mem_tlsf.Allocator,
	chunk_mesh_row_cache_allocator: mem.Allocator,

	// Callbacks
	generation_request:             GenerationRequestProc,
	generation_poll_results:        GenerationPollResultsProc,
	mesh_request:                   MeshRequestProc,
	mesh_poll_results:              MeshPollResultsProc,
	mesh_release_result:            MeshReleaseResultProc,
	chunk_mesh_upload:              ChunkMeshUploadProc,
	chunk_geometry_release:         ChunkGeometryReleaseProc,

	// Storage
	chunk_store:                    ChunkStore,

	// Streaming
	using streaming:                StreamingState,

	// State
	initialized:                    bool,
}{}


//////////////////////////////////////
// Lifecycle Methods
/////////////////////////////////////

init :: proc(config: InitConfig) {
	if state.initialized {
		return
	}

	log.assert(config.generation_request != nil, "world generation request callback is required")
	log.assert(config.generation_poll_results != nil, "world generation poll callback is required")
	log.assert(config.mesh_request != nil, "world mesh request callback is required")
	log.assert(config.mesh_poll_results != nil, "world mesh poll callback is required")
	log.assert(config.mesh_release_result != nil, "world mesh result release callback is required")
	log.assert(config.chunk_mesh_upload != nil, "world chunk mesh upload callback is required")
	log.assert(
		config.chunk_geometry_release != nil,
		"world chunk geometry release callback is required",
	)

	state.persistent_allocator = config.persistent_allocator
	state.generation_request = config.generation_request
	state.generation_poll_results = config.generation_poll_results
	state.mesh_request = config.mesh_request
	state.mesh_poll_results = config.mesh_poll_results
	state.mesh_release_result = config.mesh_release_result
	state.chunk_mesh_upload = config.chunk_mesh_upload
	state.chunk_geometry_release = config.chunk_geometry_release

	when ODIN_DEBUG {
		biomes.debug_contract_checks_run()
	}

	buffer, buffer_err := mem.make_aligned(
		[]u8,
		CHUNK_BLOCK_STORAGE_POOL_BYTES,
		mem_tlsf.ALIGN_SIZE,
		state.persistent_allocator,
	)
	log.assertf(buffer_err == nil, "chunk block storage backing allocation failed: %v", buffer_err)
	state.chunk_block_storage_buffer = buffer

	tlsf_err := mem_tlsf.init(&state.chunk_block_storage_tlsf, state.chunk_block_storage_buffer)
	log.assertf(tlsf_err == .None, "chunk block storage TLSF init failed: %v", tlsf_err)
	state.chunk_block_storage_allocator = mem_tlsf.allocator(&state.chunk_block_storage_tlsf)

	row_cache_buffer, row_cache_buffer_err := mem.make_aligned(
		[]u8,
		CHUNK_MESH_ROW_CACHE_POOL_BYTES,
		mem_tlsf.ALIGN_SIZE,
		state.persistent_allocator,
	)
	log.assertf(
		row_cache_buffer_err == nil,
		"chunk mesh row cache backing allocation failed: %v",
		row_cache_buffer_err,
	)
	state.chunk_mesh_row_cache_buffer = row_cache_buffer

	row_cache_tlsf_err := mem_tlsf.init(
		&state.chunk_mesh_row_cache_tlsf,
		state.chunk_mesh_row_cache_buffer,
	)
	log.assertf(
		row_cache_tlsf_err == .None,
		"chunk mesh row cache TLSF init failed: %v",
		row_cache_tlsf_err,
	)
	state.chunk_mesh_row_cache_allocator = mem_tlsf.allocator(&state.chunk_mesh_row_cache_tlsf)

	when ODIN_DEBUG {
		debug_chunk_block_storage_pool_contract_checks_run()
	}

	chunk_store_init(CHUNK_STORE_CAPACITY)
	streaming_reset()
	state.initialized = true
}

shutdown :: proc() {
	if !state.initialized {
		return
	}

	chunk_store_queued_mesh_snapshot_refs_release_all_for_shutdown()
	chunk_store_clear()
	mem_tlsf.destroy(&state.chunk_mesh_row_cache_tlsf)
	mem_tlsf.destroy(&state.chunk_block_storage_tlsf)
	state = {}
}

streaming_reset :: proc() {
	state.streaming = {}
}

streaming_center_coord :: proc() -> world_async.ChunkCoord {
	return state.streaming_center_coord
}

streaming_target_count :: proc() -> u32 {
	return state.streaming_target_count
}

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
// Chunk Constants
/////////////////////////////////////

CHUNK_BLOCK_LENGTH :: 64
CHUNK_BLOCK_LENGTH_LOG2 :: 6
CHUNK_BLOCK_LOCAL_MAX :: CHUNK_BLOCK_LENGTH - 1
CHUNK_BLOCK_COUNT :: CHUNK_BLOCK_LENGTH * CHUNK_BLOCK_LENGTH * CHUNK_BLOCK_LENGTH
CHUNK_SUBCHUNK_LENGTH :: 16
CHUNK_SUBCHUNK_COUNT_PER_AXIS :: CHUNK_BLOCK_LENGTH / CHUNK_SUBCHUNK_LENGTH
CHUNK_SUBCHUNK_COUNT ::
	CHUNK_SUBCHUNK_COUNT_PER_AXIS * CHUNK_SUBCHUNK_COUNT_PER_AXIS * CHUNK_SUBCHUNK_COUNT_PER_AXIS
CHUNK_SUBCHUNK_INVALID_INDEX :: max(u32)
CHUNK_SUBCHUNK_ALL_MASK :: ~u64(0)
#assert(CHUNK_BLOCK_LENGTH == 1 << CHUNK_BLOCK_LENGTH_LOG2)
#assert(CHUNK_BLOCK_LOCAL_MAX <= 0x3F)
#assert(CHUNK_BLOCK_LENGTH == world_async.CHUNK_BLOCK_LENGTH)
#assert(CHUNK_SUBCHUNK_LENGTH == world_async.CHUNK_SUBCHUNK_LENGTH)
#assert(CHUNK_SUBCHUNK_COUNT == world_async.CHUNK_SUBCHUNK_COUNT)
#assert(CHUNK_SUBCHUNK_COUNT == 64)

//////////////////////////////////////
// Chunk Voxel View Fixture Constants
/////////////////////////////////////

DEBUG_CHUNK_SOLID_X0 :: 8
DEBUG_CHUNK_SOLID_X1 :: 24
DEBUG_CHUNK_SOLID_Y0 :: 0
DEBUG_CHUNK_SOLID_Y1 :: 8
DEBUG_CHUNK_SOLID_Z0 :: 8
DEBUG_CHUNK_SOLID_Z1 :: 24
#assert(DEBUG_CHUNK_SOLID_X0 < DEBUG_CHUNK_SOLID_X1 && DEBUG_CHUNK_SOLID_X1 <= CHUNK_BLOCK_LENGTH)
#assert(DEBUG_CHUNK_SOLID_Y0 < DEBUG_CHUNK_SOLID_Y1 && DEBUG_CHUNK_SOLID_Y1 <= CHUNK_BLOCK_LENGTH)
#assert(DEBUG_CHUNK_SOLID_Z0 < DEBUG_CHUNK_SOLID_Z1 && DEBUG_CHUNK_SOLID_Z1 <= CHUNK_BLOCK_LENGTH)

//////////////////////////////////////
// Chunk Storage Constants
/////////////////////////////////////

// This must exceed raw block bytes for CHUNK_STORE_CAPACITY because TLSF and #soa
// allocations need their own bookkeeping/alignment headroom.
CHUNK_BLOCK_STORAGE_POOL_BYTES :: 192 * mem.Megabyte
CHUNK_MESH_ROW_CACHE_POOL_BYTES :: 128 * mem.Megabyte

//////////////////////////////////////
// Streaming Budget Constants
/////////////////////////////////////

CHUNK_GENERATION_BUDGET_PER_FRAME :: 1
CHUNK_MESH_BUDGET_PER_FRAME :: 2

//////////////////////////////////////
// Streaming Constants
/////////////////////////////////////

CHUNK_STREAMING_RADIUS_XZ :: 5
CHUNK_UNLOAD_RADIUS_XZ :: CHUNK_STREAMING_RADIUS_XZ + 1
CHUNK_STREAMING_TARGET_CAPACITY ::
	(CHUNK_STREAMING_RADIUS_XZ * 2 + 1) * (CHUNK_STREAMING_RADIUS_XZ * 2 + 1)
CHUNK_UNLOAD_CAPACITY :: (CHUNK_UNLOAD_RADIUS_XZ * 2 + 1) * (CHUNK_UNLOAD_RADIUS_XZ * 2 + 1)
#assert(CHUNK_UNLOAD_RADIUS_XZ >= CHUNK_STREAMING_RADIUS_XZ)

// Until chunk/geometry eviction exists, store capacity must stay within the fixed arenas.
CHUNK_STORE_CAPACITY :: 256
#assert(CHUNK_STREAMING_TARGET_CAPACITY > 0)
#assert(CHUNK_STORE_CAPACITY >= CHUNK_UNLOAD_CAPACITY)

//////////////////////////////////////
// Chunk Mesh Job Constants
/////////////////////////////////////

LOG_CHUNK_MESH_COMMITS :: #config(LOG_CHUNK_MESH_COMMITS, false)

//////////////////////////////////////
// Chunk Mesh Job Types
/////////////////////////////////////

ChunkMeshBatchStats :: struct {
	chunks_attempted: u32,
	chunks_committed: u32,
	chunks_uploaded:  u32,
	chunks_empty:     u32,
	chunks_stale:     u32,
	total_faces:      u32,
}

ChunkMeshSnapshotRefSet :: struct {
	coords: [7]world_async.ChunkCoord,
	count:  u32,
}

//////////////////////////////////////
// Terrain Binary Greedy Meshing Types
/////////////////////////////////////

TerrainBinaryGreedyScratch :: struct {
	solid_rows:          [TERRAIN_BINARY_AXIS_COUNT][TERRAIN_BINARY_AXIS_ROW_COUNT]u64,
	material_masks:      [TERRAIN_BINARY_AXIS_COUNT][TERRAIN_BINARY_AXIS_ROW_COUNT]u8,
	material_rows:       [TERRAIN_BINARY_AXIS_COUNT][TERRAIN_MATERIAL_PALETTE_COUNT][TERRAIN_BINARY_AXIS_ROW_COUNT]u64,
	face_material_masks: [CHUNK_BLOCK_LENGTH]u8,
	face_masks:          [CHUNK_BLOCK_LENGTH][TERRAIN_MATERIAL_PALETTE_COUNT][CHUNK_BLOCK_LENGTH]u64,
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

chunk_mark_generated :: proc(chunk: ^Chunk, block_storage: world_async.ChunkBlockStorage) {
	chunk.block_storage = block_storage
	chunk.generation_state = .Generated
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

	for _, i in view.blocks {
		view.blocks.occupancy[i] = .Empty
		view.blocks.material_id[i] = world_async.BlockMaterialID(0)
	}
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
// Terrain Binary Greedy Meshing Methods
/////////////////////////////////////

terrain_binary_greedy_rect_bounds_from_axes :: proc(
	normal_id, slice, u0, v0, u1, v1: u32,
) -> (
	min_x, min_y, min_z, max_x, max_y, max_z: u32,
) {
	log.assertf(normal_id < 6, "greedy normal_id out of range: %d", normal_id)
	log.assertf(slice < CHUNK_BLOCK_LENGTH, "greedy slice out of range: %d", slice)
	log.assertf(u0 <= u1 && v0 <= v1, "greedy rect bounds are inverted")
	log.assertf(u1 <= CHUNK_BLOCK_LENGTH, "greedy rect u1 out of range: %d", u1)
	log.assertf(v1 <= CHUNK_BLOCK_LENGTH, "greedy rect v1 out of range: %d", v1)

	switch normal_id {
	case 0, 1:
		return slice, u0, v0, slice + 1, u1, v1
	case 2, 3:
		return u0, slice, v0, u1, slice + 1, v1
	case 4, 5:
		return u0, v0, slice, u1, v1, slice + 1
	}

	log.assertf(false, "unhandled greedy normal_id: %d", normal_id)
	return
}

terrain_emit_quad :: proc(
	vertices: []world_async.TerrainPackedVertex,
	indices: []u32,
	face_index: u32,
	min_x, min_y, min_z, max_x, max_y, max_z: u32,
	normal_id: u32,
	material_id: u32,
) {
	vertex_index := face_index * 4
	index_index := face_index * 6
	log.assertf(int(vertex_index) + 4 <= len(vertices), "terrain mesh vertex capacity exceeded")
	log.assertf(int(index_index) + 6 <= len(indices), "terrain mesh index capacity exceeded")
	log.assertf(normal_id < 6, "terrain face normal_id out of range: %d", normal_id)

	corners: [4]TerrainGridPoint
	switch normal_id {
	case 0:
		// +X
		corners = {
			{max_x, min_y, min_z},
			{max_x, max_y, min_z},
			{max_x, max_y, max_z},
			{max_x, min_y, max_z},
		}
	case 1:
		// -X
		corners = {
			{min_x, min_y, min_z},
			{min_x, min_y, max_z},
			{min_x, max_y, max_z},
			{min_x, max_y, min_z},
		}
	case 2:
		// +Y
		corners = {
			{min_x, max_y, min_z},
			{min_x, max_y, max_z},
			{max_x, max_y, max_z},
			{max_x, max_y, min_z},
		}
	case 3:
		// -Y
		corners = {
			{min_x, min_y, min_z},
			{max_x, min_y, min_z},
			{max_x, min_y, max_z},
			{min_x, min_y, max_z},
		}
	case 4:
		// +Z
		corners = {
			{min_x, min_y, max_z},
			{max_x, min_y, max_z},
			{max_x, max_y, max_z},
			{min_x, max_y, max_z},
		}
	case 5:
		// -Z
		corners = {
			{min_x, min_y, min_z},
			{min_x, max_y, min_z},
			{max_x, max_y, min_z},
			{max_x, min_y, min_z},
		}
	}

	base := vertex_index
	v := int(vertex_index)
	i := int(index_index)

	for corner, corner_idx in corners {
		vertices[v + corner_idx] = terrain_pack_vertex(
			corner.x,
			corner.y,
			corner.z,
			normal_id,
			material_id,
		)
	}

	indices[i + 0] = base + 0
	indices[i + 1] = base + 1
	indices[i + 2] = base + 2
	indices[i + 3] = base + 0
	indices[i + 4] = base + 2
	indices[i + 5] = base + 3
}

terrain_binary_greedy_emit_rect :: proc(
	vertices: []world_async.TerrainPackedVertex,
	indices: []u32,
	face_index: u32,
	normal_id, slice, u0, v0, u1, v1: u32,
	material_id: u32,
) {
	min_x, min_y, min_z, max_x, max_y, max_z := terrain_binary_greedy_rect_bounds_from_axes(
		normal_id,
		slice,
		u0,
		v0,
		u1,
		v1,
	)
	terrain_emit_quad(
		vertices,
		indices,
		face_index,
		min_x,
		min_y,
		min_z,
		max_x,
		max_y,
		max_z,
		normal_id,
		material_id,
	)
}

terrain_material_palette_index :: proc(material_id: world_async.BlockMaterialID) -> u32 {
	return u32(u8(material_id)) & (TERRAIN_MATERIAL_PALETTE_COUNT - 1)
}

terrain_binary_row_run_width :: proc(row: u64, u: u32) -> u32 {
	log.assertf(row != 0, "binary greedy row must not be zero")
	log.assertf(u < CHUNK_BLOCK_LENGTH, "binary greedy u out of range: %d", u)
	log.assertf((row & (u64(1) << u)) != 0, "binary greedy run must start on a set bit")

	run := row >> u
	remaining := CHUNK_BLOCK_LENGTH - u
	if run == ~u64(0) {
		return remaining
	}

	width := u32(bits.trailing_zeros(~run))
	if width > remaining {
		return remaining
	}
	return width
}

terrain_binary_rect_mask :: proc(u, width: u32) -> u64 {
	log.assertf(u < CHUNK_BLOCK_LENGTH, "binary greedy rect u out of range: %d", u)
	log.assertf(width > 0, "binary greedy rect width must be positive")
	log.assertf(u + width <= CHUNK_BLOCK_LENGTH, "binary greedy rect exceeds row")

	if width == CHUNK_BLOCK_LENGTH {
		return ~u64(0)
	}
	return ((u64(1) << width) - 1) << u
}

terrain_binary_greedy_scratch_alloc :: proc(
	allocator: mem.Allocator,
) -> ^TerrainBinaryGreedyScratch {
	scratch := new(TerrainBinaryGreedyScratch, allocator)
	log.assert(scratch != nil, "binary greedy scratch allocation failed")
	return scratch
}

terrain_binary_axis_rows_build_all :: proc(
	scratch: ^TerrainBinaryGreedyScratch,
	view: world_async.ChunkVoxelView,
) {
	for axis := u32(0); axis < TERRAIN_BINARY_AXIS_COUNT; axis += 1 {
		mem.zero_slice(scratch.solid_rows[axis][:])
		mem.zero_slice(scratch.material_masks[axis][:])
		for material_idx := u32(0);
		    material_idx < TERRAIN_MATERIAL_PALETTE_COUNT;
		    material_idx += 1 {
			mem.zero_slice(scratch.material_rows[axis][material_idx][:])
		}
	}

	block_index: u32
	for z := u32(0); z < CHUNK_BLOCK_LENGTH; z += 1 {
		for y := u32(0); y < CHUNK_BLOCK_LENGTH; y += 1 {
			for x := u32(0); x < CHUNK_BLOCK_LENGTH; x += 1 {
				if view.blocks.occupancy[block_index] != .Solid {
					block_index += 1
					continue
				}

				material_idx := terrain_material_palette_index(
					view.blocks.material_id[block_index],
				)
				x_row := y + z * CHUNK_BLOCK_LENGTH
				y_row := x + z * CHUNK_BLOCK_LENGTH
				z_row := x + y * CHUNK_BLOCK_LENGTH
				x_bit := u64(1) << x
				y_bit := u64(1) << y
				z_bit := u64(1) << z

				scratch.solid_rows[0][x_row] |= x_bit
				scratch.material_masks[0][x_row] |= u8(1) << material_idx
				scratch.material_rows[0][material_idx][x_row] |= x_bit

				scratch.solid_rows[1][y_row] |= y_bit
				scratch.material_masks[1][y_row] |= u8(1) << material_idx
				scratch.material_rows[1][material_idx][y_row] |= y_bit

				scratch.solid_rows[2][z_row] |= z_bit
				scratch.material_masks[2][z_row] |= u8(1) << material_idx
				scratch.material_rows[2][material_idx][z_row] |= z_bit
				block_index += 1
			}
		}
	}
}

//////////////////////////////////////
// Terrain Binary Greedy Row Cache Methods
/////////////////////////////////////

terrain_binary_row_cache_fill :: proc(
	cache: ^world_async.ChunkBinaryGreedyRowCache,
	view: world_async.ChunkVoxelView,
	block_version: u32,
) {
	for axis := u32(0); axis < TERRAIN_BINARY_AXIS_COUNT; axis += 1 {
		mem.zero_slice(cache.solid_rows[axis][:])
		mem.zero_slice(cache.material_masks[axis][:])
		for material_idx := u32(0);
		    material_idx < TERRAIN_MATERIAL_PALETTE_COUNT;
		    material_idx += 1 {
			mem.zero_slice(cache.material_rows[axis][material_idx][:])
		}
	}

	block_index: u32
	for z := u32(0); z < CHUNK_BLOCK_LENGTH; z += 1 {
		for y := u32(0); y < CHUNK_BLOCK_LENGTH; y += 1 {
			for x := u32(0); x < CHUNK_BLOCK_LENGTH; x += 1 {
				if view.blocks.occupancy[block_index] != .Solid {
					block_index += 1
					continue
				}

				material_idx := terrain_material_palette_index(
					view.blocks.material_id[block_index],
				)
				x_row := y + z * CHUNK_BLOCK_LENGTH
				y_row := x + z * CHUNK_BLOCK_LENGTH
				z_row := x + y * CHUNK_BLOCK_LENGTH
				x_bit := u64(1) << x
				y_bit := u64(1) << y
				z_bit := u64(1) << z

				cache.solid_rows[0][x_row] |= x_bit
				cache.material_masks[0][x_row] |= u8(1) << material_idx
				cache.material_rows[0][material_idx][x_row] |= x_bit

				cache.solid_rows[1][y_row] |= y_bit
				cache.material_masks[1][y_row] |= u8(1) << material_idx
				cache.material_rows[1][material_idx][y_row] |= y_bit

				cache.solid_rows[2][z_row] |= z_bit
				cache.material_masks[2][z_row] |= u8(1) << material_idx
				cache.material_rows[2][material_idx][z_row] |= z_bit
				block_index += 1
			}
		}
	}

	cache.block_version = block_version
}

terrain_binary_row_cache_clear_block :: proc(
	cache: ^world_async.ChunkBinaryGreedyRowCache,
	x, y, z, material_idx: u32,
) {
	x_row := y + z * CHUNK_BLOCK_LENGTH
	y_row := x + z * CHUNK_BLOCK_LENGTH
	z_row := x + y * CHUNK_BLOCK_LENGTH
	x_bit := u64(1) << x
	y_bit := u64(1) << y
	z_bit := u64(1) << z
	material_bit := u8(1) << material_idx

	cache.solid_rows[0][x_row] &~= x_bit
	cache.material_rows[0][material_idx][x_row] &~= x_bit
	if cache.material_rows[0][material_idx][x_row] == 0 {
		cache.material_masks[0][x_row] &~= material_bit
	}

	cache.solid_rows[1][y_row] &~= y_bit
	cache.material_rows[1][material_idx][y_row] &~= y_bit
	if cache.material_rows[1][material_idx][y_row] == 0 {
		cache.material_masks[1][y_row] &~= material_bit
	}

	cache.solid_rows[2][z_row] &~= z_bit
	cache.material_rows[2][material_idx][z_row] &~= z_bit
	if cache.material_rows[2][material_idx][z_row] == 0 {
		cache.material_masks[2][z_row] &~= material_bit
	}
}

terrain_binary_row_cache_set_block :: proc(
	cache: ^world_async.ChunkBinaryGreedyRowCache,
	x, y, z, material_idx: u32,
) {
	x_row := y + z * CHUNK_BLOCK_LENGTH
	y_row := x + z * CHUNK_BLOCK_LENGTH
	z_row := x + y * CHUNK_BLOCK_LENGTH
	x_bit := u64(1) << x
	y_bit := u64(1) << y
	z_bit := u64(1) << z
	material_bit := u8(1) << material_idx

	cache.solid_rows[0][x_row] |= x_bit
	cache.material_masks[0][x_row] |= material_bit
	cache.material_rows[0][material_idx][x_row] |= x_bit

	cache.solid_rows[1][y_row] |= y_bit
	cache.material_masks[1][y_row] |= material_bit
	cache.material_rows[1][material_idx][y_row] |= y_bit

	cache.solid_rows[2][z_row] |= z_bit
	cache.material_masks[2][z_row] |= material_bit
	cache.material_rows[2][material_idx][z_row] |= z_bit
}

terrain_binary_row_cache_apply_block_edit :: proc(
	cache: ^world_async.ChunkBinaryGreedyRowCache,
	x, y, z: u32,
	old_occupancy: world_async.BlockOccupancy,
	old_material_id: world_async.BlockMaterialID,
	new_occupancy: world_async.BlockOccupancy,
	new_material_id: world_async.BlockMaterialID,
	block_version: u32,
) {
	if old_occupancy == .Solid {
		terrain_binary_row_cache_clear_block(
			cache,
			x,
			y,
			z,
			terrain_material_palette_index(old_material_id),
		)
	}
	if new_occupancy == .Solid {
		terrain_binary_row_cache_set_block(
			cache,
			x,
			y,
			z,
			terrain_material_palette_index(new_material_id),
		)
	}
	cache.block_version = block_version
}

terrain_binary_neighbor_boundary_solid :: proc(
	normal_id, u, v: u32,
	boundary_policy: world_async.ChunkMeshBoundaryPolicy,
	neighbor_snapshots: Maybe(world_async.ChunkMeshNeighborSnapshots) = nil,
) -> bool {
	#partial switch boundary_policy {
	case .Treat_Out_Of_Chunk_As_Empty:
		return false
	case .Sample_Neighbor_Snapshots:
		neighbors, ok := neighbor_snapshots.?
		log.assert(
			ok,
			"neighbors must be provided when boundary policy is Sample_Neighbor_Snapshots",
		)

		neighbor: Maybe(world_async.ChunkSnapshot)
		x, y, z: u32
		switch normal_id {
		case 0:
			neighbor = neighbors.plus_x
			x, y, z = 0, u, v
		case 1:
			neighbor = neighbors.minus_x
			x, y, z = CHUNK_BLOCK_LOCAL_MAX, u, v
		case 2:
			neighbor = neighbors.plus_y
			x, y, z = u, 0, v
		case 3:
			neighbor = neighbors.minus_y
			x, y, z = u, CHUNK_BLOCK_LOCAL_MAX, v
		case 4:
			neighbor = neighbors.plus_z
			x, y, z = u, v, 0
		case 5:
			neighbor = neighbors.minus_z
			x, y, z = u, v, CHUNK_BLOCK_LOCAL_MAX
		}

		neighbor_snapshot, neighbor_ok := neighbor.?
		if !neighbor_ok {
			return false
		}

		return chunk_voxel_view_is_solid_local(neighbor_snapshot.voxel_view, x, y, z)
	}

	log.assertf(false, "unhandled chunk mesher boundary policy: %v", boundary_policy)
	return false
}

terrain_binary_face_masks_build :: proc(
	scratch: ^TerrainBinaryGreedyScratch,
	normal_id: u32,
	boundary_policy: world_async.ChunkMeshBoundaryPolicy,
	neighbor_snapshots: Maybe(world_async.ChunkMeshNeighborSnapshots) = nil,
) {
	mem.zero_slice(scratch.face_material_masks[:])
	for slice := u32(0); slice < CHUNK_BLOCK_LENGTH; slice += 1 {
		for material_idx := u32(0);
		    material_idx < TERRAIN_MATERIAL_PALETTE_COUNT;
		    material_idx += 1 {
			mem.zero_slice(scratch.face_masks[slice][material_idx][:])
		}
	}

	axis := normal_id / 2
	positive := (normal_id & 1) == 0
	sample_boundary := boundary_policy == .Sample_Neighbor_Snapshots
	for v := u32(0); v < CHUNK_BLOCK_LENGTH; v += 1 {
		for u := u32(0); u < CHUNK_BLOCK_LENGTH; u += 1 {
			row_index := u + v * CHUNK_BLOCK_LENGTH
			solid_row := scratch.solid_rows[axis][row_index]
			if solid_row == 0 {
				continue
			}

			neighbor_row := solid_row >> 1 if positive else solid_row << 1
			if sample_boundary &&
			   terrain_binary_neighbor_boundary_solid(
				   normal_id,
				   u,
				   v,
				   boundary_policy,
				   neighbor_snapshots,
			   ) {
				neighbor_row |= (u64(1) << CHUNK_BLOCK_LOCAL_MAX) if positive else u64(1)
			}

			exposed_row := solid_row & ~neighbor_row
			if exposed_row == 0 {
				continue
			}

			material_mask := u32(scratch.material_masks[axis][row_index])
			for material_mask != 0 {
				material_idx := u32(bits.trailing_zeros(material_mask))
				material_row := scratch.material_rows[axis][material_idx][row_index]
				exposed_material_bits := exposed_row & material_row
				for exposed_material_bits != 0 {
					slice := u32(bits.trailing_zeros(exposed_material_bits))
					scratch.face_material_masks[slice] |= u8(1) << material_idx
					scratch.face_masks[slice][material_idx][v] |= u64(1) << u
					exposed_material_bits &~= u64(1) << slice
				}
				material_mask &~= u32(1) << material_idx
			}
		}
	}
}

terrain_binary_face_masks_build_from_cache :: proc(
	scratch: ^TerrainBinaryGreedyScratch,
	cache: ^world_async.ChunkBinaryGreedyRowCache,
	normal_id: u32,
	boundary_policy: world_async.ChunkMeshBoundaryPolicy,
	neighbor_snapshots: Maybe(world_async.ChunkMeshNeighborSnapshots) = nil,
) {
	mem.zero_slice(scratch.face_material_masks[:])
	for slice := u32(0); slice < CHUNK_BLOCK_LENGTH; slice += 1 {
		for material_idx := u32(0);
		    material_idx < TERRAIN_MATERIAL_PALETTE_COUNT;
		    material_idx += 1 {
			mem.zero_slice(scratch.face_masks[slice][material_idx][:])
		}
	}

	axis := normal_id / 2
	positive := (normal_id & 1) == 0
	sample_boundary := boundary_policy == .Sample_Neighbor_Snapshots
	for v := u32(0); v < CHUNK_BLOCK_LENGTH; v += 1 {
		for u := u32(0); u < CHUNK_BLOCK_LENGTH; u += 1 {
			row_index := u + v * CHUNK_BLOCK_LENGTH
			solid_row := cache.solid_rows[axis][row_index]
			if solid_row == 0 {
				continue
			}

			neighbor_row := solid_row >> 1 if positive else solid_row << 1
			if sample_boundary &&
			   terrain_binary_neighbor_boundary_solid(
				   normal_id,
				   u,
				   v,
				   boundary_policy,
				   neighbor_snapshots,
			   ) {
				neighbor_row |= (u64(1) << CHUNK_BLOCK_LOCAL_MAX) if positive else u64(1)
			}

			exposed_row := solid_row & ~neighbor_row
			if exposed_row == 0 {
				continue
			}

			material_mask := u32(cache.material_masks[axis][row_index])
			for material_mask != 0 {
				material_idx := u32(bits.trailing_zeros(material_mask))
				material_row := cache.material_rows[axis][material_idx][row_index]
				exposed_material_bits := exposed_row & material_row
				for exposed_material_bits != 0 {
					slice := u32(bits.trailing_zeros(exposed_material_bits))
					scratch.face_material_masks[slice] |= u8(1) << material_idx
					scratch.face_masks[slice][material_idx][v] |= u64(1) << u
					exposed_material_bits &~= u64(1) << slice
				}
				material_mask &~= u32(1) << material_idx
			}
		}
	}
}

terrain_binary_greedy_material_process :: proc(
	rows: []u64,
	normal_id, slice: u32,
	material_id: u32,
	vertices: []world_async.TerrainPackedVertex,
	indices: []u32,
	face_cursor: ^u32,
	emit: bool,
) {
	log.assertf(
		len(rows) == CHUNK_BLOCK_LENGTH,
		"binary greedy material rows must have %d rows, got %d",
		CHUNK_BLOCK_LENGTH,
		len(rows),
	)
	for v := u32(0); v < CHUNK_BLOCK_LENGTH; v += 1 {
		for rows[v] != 0 {
			row := rows[v]
			u := u32(bits.trailing_zeros(row))
			width := terrain_binary_row_run_width(row, u)
			rect_mask := terrain_binary_rect_mask(u, width)

			height := u32(1)
			for v + height < CHUNK_BLOCK_LENGTH {
				next_row := rows[v + height]
				if (next_row & rect_mask) != rect_mask {
					break
				}
				height += 1
			}

			if emit {
				terrain_binary_greedy_emit_rect(
					vertices,
					indices,
					face_cursor^,
					normal_id,
					slice,
					u,
					v,
					u + width,
					v + height,
					material_id,
				)
			}
			face_cursor^ += 1

			for clear_v := v; clear_v < v + height; clear_v += 1 {
				rows[clear_v] &~= rect_mask
			}
		}
	}
}

terrain_binary_face_masks_process :: proc(
	scratch: ^TerrainBinaryGreedyScratch,
	normal_id: u32,
	vertices: []world_async.TerrainPackedVertex,
	indices: []u32,
	face_cursor: ^u32,
	emit: bool,
) {
	for slice := u32(0); slice < CHUNK_BLOCK_LENGTH; slice += 1 {
		material_mask := u32(scratch.face_material_masks[slice])
		for material_mask != 0 {
			material_idx := u32(bits.trailing_zeros(material_mask))
			terrain_binary_greedy_material_process(
				scratch.face_masks[slice][material_idx][:],
				normal_id,
				slice,
				material_idx,
				vertices,
				indices,
				face_cursor,
				emit,
			)
			material_mask &~= u32(1) << material_idx
		}
	}
}

terrain_binary_axis_bounds_from_chunk_bounds :: proc(
	normal_id: u32,
	min_bound, max_bound: world_async.BlockCoord,
) -> (
	slice_min, slice_max, u_min, u_max, v_min, v_max: u32,
) {
	log.assertf(normal_id < 6, "binary greedy normal_id out of range: %d", normal_id)
	log.assertf(
		chunk_block_coord_is_inside(min_bound.x, min_bound.y, min_bound.z),
		"subchunk min bound out of chunk: %v",
		min_bound,
	)
	log.assertf(
		max_bound.x > min_bound.x &&
		max_bound.y > min_bound.y &&
		max_bound.z > min_bound.z &&
		max_bound.x <= CHUNK_BLOCK_LENGTH &&
		max_bound.y <= CHUNK_BLOCK_LENGTH &&
		max_bound.z <= CHUNK_BLOCK_LENGTH,
		"subchunk bounds invalid: min=%v max=%v",
		min_bound,
		max_bound,
	)

	switch normal_id {
	case 0, 1:
		return u32(
			min_bound.x,
		), u32(max_bound.x), u32(min_bound.y), u32(max_bound.y), u32(min_bound.z), u32(max_bound.z)
	case 2, 3:
		return u32(
			min_bound.y,
		), u32(max_bound.y), u32(min_bound.x), u32(max_bound.x), u32(min_bound.z), u32(max_bound.z)
	case 4, 5:
		return u32(
			min_bound.z,
		), u32(max_bound.z), u32(min_bound.x), u32(max_bound.x), u32(min_bound.y), u32(max_bound.y)
	}

	log.assertf(false, "unhandled binary greedy normal_id: %d", normal_id)
	return
}

terrain_binary_greedy_material_process_bounds :: proc(
	rows: []u64,
	normal_id, slice: u32,
	material_id: u32,
	u_min, u_max, v_min, v_max: u32,
	vertices: []world_async.TerrainPackedVertex,
	indices: []u32,
	face_cursor: ^u32,
	emit: bool,
) {
	log.assertf(
		len(rows) == CHUNK_BLOCK_LENGTH,
		"binary greedy material rows must have %d rows, got %d",
		CHUNK_BLOCK_LENGTH,
		len(rows),
	)
	log.assertf(u_min < u_max && u_max <= CHUNK_BLOCK_LENGTH, "binary greedy u bounds invalid")
	log.assertf(v_min < v_max && v_max <= CHUNK_BLOCK_LENGTH, "binary greedy v bounds invalid")

	u_mask := terrain_binary_rect_mask(u_min, u_max - u_min)
	for v := v_min; v < v_max; v += 1 {
		for {
			row := rows[v] & u_mask
			if row == 0 {
				break
			}

			u := u32(bits.trailing_zeros(row))
			width := terrain_binary_row_run_width(row, u)
			rect_mask := terrain_binary_rect_mask(u, width)

			height := u32(1)
			for v + height < v_max {
				next_row := rows[v + height] & u_mask
				if (next_row & rect_mask) != rect_mask {
					break
				}
				height += 1
			}

			if emit {
				terrain_binary_greedy_emit_rect(
					vertices,
					indices,
					face_cursor^,
					normal_id,
					slice,
					u,
					v,
					u + width,
					v + height,
					material_id,
				)
			}
			face_cursor^ += 1

			for clear_v := v; clear_v < v + height; clear_v += 1 {
				rows[clear_v] &~= rect_mask
			}
		}
	}
}

terrain_binary_face_masks_process_bounds :: proc(
	scratch: ^TerrainBinaryGreedyScratch,
	normal_id: u32,
	min_bound, max_bound: world_async.BlockCoord,
	vertices: []world_async.TerrainPackedVertex,
	indices: []u32,
	face_cursor: ^u32,
	emit: bool,
) {
	slice_min, slice_max, u_min, u_max, v_min, v_max :=
		terrain_binary_axis_bounds_from_chunk_bounds(normal_id, min_bound, max_bound)
	for slice := slice_min; slice < slice_max; slice += 1 {
		material_mask := u32(scratch.face_material_masks[slice])
		for material_mask != 0 {
			material_idx := u32(bits.trailing_zeros(material_mask))
			terrain_binary_greedy_material_process_bounds(
				scratch.face_masks[slice][material_idx][:],
				normal_id,
				slice,
				material_idx,
				u_min,
				u_max,
				v_min,
				v_max,
				vertices,
				indices,
				face_cursor,
				emit,
			)
			material_mask &~= u32(1) << material_idx
		}
	}
}

chunk_voxel_view_count_binary_greedy_faces :: proc(
	view: world_async.ChunkVoxelView,
	boundary_policy: world_async.ChunkMeshBoundaryPolicy,
	scratch: ^TerrainBinaryGreedyScratch,
	neighbor_snapshots: Maybe(world_async.ChunkMeshNeighborSnapshots) = nil,
) -> u32 {
	terrain_binary_axis_rows_build_all(scratch, view)
	vertices: []world_async.TerrainPackedVertex
	indices: []u32
	face_count: u32

	for normal_id := u32(0); normal_id < 6; normal_id += 1 {
		terrain_binary_face_masks_build(scratch, normal_id, boundary_policy, neighbor_snapshots)
		terrain_binary_face_masks_process(
			scratch,
			normal_id,
			vertices,
			indices,
			&face_count,
			false,
		)
	}

	return face_count
}

chunk_voxel_view_build_binary_greedy_mesh :: proc(
	view: world_async.ChunkVoxelView,
	boundary_policy: world_async.ChunkMeshBoundaryPolicy,
	allocator: mem.Allocator,
	scratch: ^TerrainBinaryGreedyScratch,
	neighbor_snapshots: Maybe(world_async.ChunkMeshNeighborSnapshots) = nil,
) -> world_async.ChunkMeshOutput {
	terrain_binary_axis_rows_build_all(scratch, view)
	vertices: []world_async.TerrainPackedVertex
	indices: []u32
	face_count: u32
	for normal_id := u32(0); normal_id < 6; normal_id += 1 {
		terrain_binary_face_masks_build(scratch, normal_id, boundary_policy, neighbor_snapshots)
		terrain_binary_face_masks_process(
			scratch,
			normal_id,
			vertices,
			indices,
			&face_count,
			false,
		)
	}
	if face_count == 0 {
		return {}
	}

	log.assertf(
		face_count <= max(u32) / 4,
		"chunk binary greedy mesh vertex count would overflow: %d faces",
		face_count,
	)
	log.assertf(
		face_count <= max(u32) / 6,
		"chunk binary greedy mesh index count would overflow: %d faces",
		face_count,
	)

	expected_vertex_count := int(face_count) * 4
	expected_index_count := int(face_count) * 6
	output := world_async.ChunkMeshOutput {
			vertices   = make([]world_async.TerrainPackedVertex, expected_vertex_count, allocator),
			indices    = make([]u32, expected_index_count, allocator),
			face_count = face_count,
		}
	log.assertf(
		len(output.vertices) == expected_vertex_count,
		"chunk binary greedy mesh vertex allocation failed: expected=%d got=%d faces=%d",
		expected_vertex_count,
		len(output.vertices),
		face_count,
	)
	log.assertf(
		len(output.indices) == expected_index_count,
		"chunk binary greedy mesh index allocation failed: expected=%d got=%d faces=%d",
		expected_index_count,
		len(output.indices),
		face_count,
	)

	face_cursor: u32
	for normal_id := u32(0); normal_id < 6; normal_id += 1 {
		terrain_binary_face_masks_build(scratch, normal_id, boundary_policy, neighbor_snapshots)
		terrain_binary_face_masks_process(
			scratch,
			normal_id,
			output.vertices,
			output.indices,
			&face_cursor,
			true,
		)
	}
	log.assertf(
		face_cursor == face_count,
		"binary greedy face count mismatch: count=%d emit=%d",
		face_count,
		face_cursor,
	)

	return output
}

chunk_voxel_view_count_binary_greedy_faces_in_bounds :: proc(
	view: world_async.ChunkVoxelView,
	min_bound, max_bound: world_async.BlockCoord,
	boundary_policy: world_async.ChunkMeshBoundaryPolicy,
	scratch: ^TerrainBinaryGreedyScratch,
	neighbor_snapshots: Maybe(world_async.ChunkMeshNeighborSnapshots) = nil,
) -> u32 {
	terrain_binary_axis_rows_build_all(scratch, view)
	vertices: []world_async.TerrainPackedVertex
	indices: []u32
	face_count: u32

	for normal_id := u32(0); normal_id < 6; normal_id += 1 {
		terrain_binary_face_masks_build(scratch, normal_id, boundary_policy, neighbor_snapshots)
		terrain_binary_face_masks_process_bounds(
			scratch,
			normal_id,
			min_bound,
			max_bound,
			vertices,
			indices,
			&face_count,
			false,
		)
	}

	return face_count
}

chunk_voxel_view_build_binary_greedy_mesh_in_bounds :: proc(
	view: world_async.ChunkVoxelView,
	min_bound, max_bound: world_async.BlockCoord,
	boundary_policy: world_async.ChunkMeshBoundaryPolicy,
	allocator: mem.Allocator,
	scratch: ^TerrainBinaryGreedyScratch,
	neighbor_snapshots: Maybe(world_async.ChunkMeshNeighborSnapshots) = nil,
) -> world_async.ChunkMeshOutput {
	face_count := chunk_voxel_view_count_binary_greedy_faces_in_bounds(
		view,
		min_bound,
		max_bound,
		boundary_policy,
		scratch,
		neighbor_snapshots,
	)
	if face_count == 0 {
		return {}
	}

	log.assertf(
		face_count <= max(u32) / 4,
		"subchunk binary greedy mesh vertex count would overflow: %d faces",
		face_count,
	)
	log.assertf(
		face_count <= max(u32) / 6,
		"subchunk binary greedy mesh index count would overflow: %d faces",
		face_count,
	)

	expected_vertex_count := int(face_count) * 4
	expected_index_count := int(face_count) * 6
	output := world_async.ChunkMeshOutput {
		vertices   = make([]world_async.TerrainPackedVertex, expected_vertex_count, allocator),
		indices    = make([]u32, expected_index_count, allocator),
		face_count = face_count,
	}
	log.assertf(
		len(output.vertices) == expected_vertex_count,
		"subchunk binary greedy mesh vertex allocation failed: expected=%d got=%d faces=%d",
		expected_vertex_count,
		len(output.vertices),
		face_count,
	)
	log.assertf(
		len(output.indices) == expected_index_count,
		"subchunk binary greedy mesh index allocation failed: expected=%d got=%d faces=%d",
		expected_index_count,
		len(output.indices),
		face_count,
	)

	terrain_binary_axis_rows_build_all(scratch, view)
	face_cursor: u32
	for normal_id := u32(0); normal_id < 6; normal_id += 1 {
		terrain_binary_face_masks_build(scratch, normal_id, boundary_policy, neighbor_snapshots)
		terrain_binary_face_masks_process_bounds(
			scratch,
			normal_id,
			min_bound,
			max_bound,
			output.vertices,
			output.indices,
			&face_cursor,
			true,
		)
	}
	log.assertf(
		face_cursor == face_count,
		"subchunk binary greedy face count mismatch: count=%d emit=%d",
		face_count,
		face_cursor,
	)
	return output
}

chunk_binary_row_cache_build_binary_greedy_mesh :: proc(
	cache: ^world_async.ChunkBinaryGreedyRowCache,
	boundary_policy: world_async.ChunkMeshBoundaryPolicy,
	allocator: mem.Allocator,
	scratch: ^TerrainBinaryGreedyScratch,
	neighbor_snapshots: Maybe(world_async.ChunkMeshNeighborSnapshots) = nil,
) -> world_async.ChunkMeshOutput {
	vertices: []world_async.TerrainPackedVertex
	indices: []u32
	face_count: u32
	for normal_id := u32(0); normal_id < 6; normal_id += 1 {
		terrain_binary_face_masks_build_from_cache(
			scratch,
			cache,
			normal_id,
			boundary_policy,
			neighbor_snapshots,
		)
		terrain_binary_face_masks_process(
			scratch,
			normal_id,
			vertices,
			indices,
			&face_count,
			false,
		)
	}
	if face_count == 0 {
		return {}
	}

	log.assertf(
		face_count <= max(u32) / 4,
		"chunk binary greedy mesh vertex count would overflow: %d faces",
		face_count,
	)
	log.assertf(
		face_count <= max(u32) / 6,
		"chunk binary greedy mesh index count would overflow: %d faces",
		face_count,
	)

	expected_vertex_count := int(face_count) * 4
	expected_index_count := int(face_count) * 6
	output := world_async.ChunkMeshOutput {
		vertices   = make([]world_async.TerrainPackedVertex, expected_vertex_count, allocator),
		indices    = make([]u32, expected_index_count, allocator),
		face_count = face_count,
	}
	log.assertf(
		len(output.vertices) == expected_vertex_count,
		"chunk binary greedy mesh vertex allocation failed: expected=%d got=%d faces=%d",
		expected_vertex_count,
		len(output.vertices),
		face_count,
	)
	log.assertf(
		len(output.indices) == expected_index_count,
		"chunk binary greedy mesh index allocation failed: expected=%d got=%d faces=%d",
		expected_index_count,
		len(output.indices),
		face_count,
	)

	face_cursor: u32
	for normal_id := u32(0); normal_id < 6; normal_id += 1 {
		terrain_binary_face_masks_build_from_cache(
			scratch,
			cache,
			normal_id,
			boundary_policy,
			neighbor_snapshots,
		)
		terrain_binary_face_masks_process(
			scratch,
			normal_id,
			output.vertices,
			output.indices,
			&face_cursor,
			true,
		)
	}
	log.assertf(
		face_cursor == face_count,
		"binary greedy face count mismatch: count=%d emit=%d",
		face_count,
		face_cursor,
	)

	return output
}

chunk_binary_row_cache_count_binary_greedy_faces_in_bounds :: proc(
	cache: ^world_async.ChunkBinaryGreedyRowCache,
	min_bound, max_bound: world_async.BlockCoord,
	boundary_policy: world_async.ChunkMeshBoundaryPolicy,
	scratch: ^TerrainBinaryGreedyScratch,
	neighbor_snapshots: Maybe(world_async.ChunkMeshNeighborSnapshots) = nil,
) -> u32 {
	vertices: []world_async.TerrainPackedVertex
	indices: []u32
	face_count: u32
	for normal_id := u32(0); normal_id < 6; normal_id += 1 {
		terrain_binary_face_masks_build_from_cache(
			scratch,
			cache,
			normal_id,
			boundary_policy,
			neighbor_snapshots,
		)
		terrain_binary_face_masks_process_bounds(
			scratch,
			normal_id,
			min_bound,
			max_bound,
			vertices,
			indices,
			&face_count,
			false,
		)
	}
	return face_count
}

chunk_binary_row_cache_build_binary_greedy_mesh_in_bounds :: proc(
	cache: ^world_async.ChunkBinaryGreedyRowCache,
	min_bound, max_bound: world_async.BlockCoord,
	boundary_policy: world_async.ChunkMeshBoundaryPolicy,
	allocator: mem.Allocator,
	scratch: ^TerrainBinaryGreedyScratch,
	neighbor_snapshots: Maybe(world_async.ChunkMeshNeighborSnapshots) = nil,
) -> world_async.ChunkMeshOutput {
	face_count := chunk_binary_row_cache_count_binary_greedy_faces_in_bounds(
		cache,
		min_bound,
		max_bound,
		boundary_policy,
		scratch,
		neighbor_snapshots,
	)
	if face_count == 0 {
		return {}
	}

	log.assertf(
		face_count <= max(u32) / 4,
		"subchunk binary greedy mesh vertex count would overflow: %d faces",
		face_count,
	)
	log.assertf(
		face_count <= max(u32) / 6,
		"subchunk binary greedy mesh index count would overflow: %d faces",
		face_count,
	)

	expected_vertex_count := int(face_count) * 4
	expected_index_count := int(face_count) * 6
	output := world_async.ChunkMeshOutput {
		vertices   = make([]world_async.TerrainPackedVertex, expected_vertex_count, allocator),
		indices    = make([]u32, expected_index_count, allocator),
		face_count = face_count,
	}
	log.assertf(
		len(output.vertices) == expected_vertex_count,
		"subchunk binary greedy mesh vertex allocation failed: expected=%d got=%d faces=%d",
		expected_vertex_count,
		len(output.vertices),
		face_count,
	)
	log.assertf(
		len(output.indices) == expected_index_count,
		"subchunk binary greedy mesh index allocation failed: expected=%d got=%d faces=%d",
		expected_index_count,
		len(output.indices),
		face_count,
	)

	face_cursor: u32
	for normal_id := u32(0); normal_id < 6; normal_id += 1 {
		terrain_binary_face_masks_build_from_cache(
			scratch,
			cache,
			normal_id,
			boundary_policy,
			neighbor_snapshots,
		)
		terrain_binary_face_masks_process_bounds(
			scratch,
			normal_id,
			min_bound,
			max_bound,
			output.vertices,
			output.indices,
			&face_cursor,
			true,
		)
	}
	log.assertf(
		face_cursor == face_count,
		"subchunk binary greedy face count mismatch: count=%d emit=%d",
		face_count,
		face_cursor,
	)
	return output
}

chunk_snapshot_build_binary_greedy_mesh :: proc(
	snapshot: world_async.ChunkSnapshot,
	boundary_policy: world_async.ChunkMeshBoundaryPolicy,
	allocator: mem.Allocator,
	scratch: ^TerrainBinaryGreedyScratch,
	neighbor_snapshots: Maybe(world_async.ChunkMeshNeighborSnapshots) = nil,
) -> world_async.ChunkMeshOutput {
	if snapshot.binary_greedy_row_cache != nil &&
	   snapshot.binary_greedy_row_cache.block_version == snapshot.block_version {
		return chunk_binary_row_cache_build_binary_greedy_mesh(
			snapshot.binary_greedy_row_cache,
			boundary_policy,
			allocator,
			scratch,
			neighbor_snapshots,
		)
	}

	return chunk_voxel_view_build_binary_greedy_mesh(
		snapshot.voxel_view,
		boundary_policy,
		allocator,
		scratch,
		neighbor_snapshots,
	)
}

chunk_snapshot_build_subchunk_mesh :: proc(
	snapshot: world_async.ChunkSnapshot,
	subchunk_index: u32,
	boundary_policy: world_async.ChunkMeshBoundaryPolicy,
	allocator: mem.Allocator,
	scratch: ^TerrainBinaryGreedyScratch,
	neighbor_snapshots: Maybe(world_async.ChunkMeshNeighborSnapshots) = nil,
) -> world_async.ChunkMeshOutput {
	min_bound, max_bound := chunk_subchunk_bounds_from_index(subchunk_index)
	if snapshot.binary_greedy_row_cache != nil &&
	   snapshot.binary_greedy_row_cache.block_version == snapshot.block_version {
		return chunk_binary_row_cache_build_binary_greedy_mesh_in_bounds(
			snapshot.binary_greedy_row_cache,
			min_bound,
			max_bound,
			boundary_policy,
			allocator,
			scratch,
			neighbor_snapshots,
		)
	}

	return chunk_voxel_view_build_binary_greedy_mesh_in_bounds(
		snapshot.voxel_view,
		min_bound,
		max_bound,
		boundary_policy,
		allocator,
		scratch,
		neighbor_snapshots,
	)
}

mesh_job_execute_sync :: proc(
	job: world_async.ChunkMeshJob,
	output_allocator: mem.Allocator,
	scratch_allocator: mem.Allocator,
) -> world_async.ChunkMeshOutput {
	log.assertf(
		len(job.snapshot.voxel_view.blocks) == CHUNK_BLOCK_COUNT,
		"chunk mesh job snapshot must have %d blocks, got %d",
		CHUNK_BLOCK_COUNT,
		len(job.snapshot.voxel_view.blocks),
	)

	scratch := terrain_binary_greedy_scratch_alloc(scratch_allocator)

	switch job.scope_kind {
	case .Subchunk:
		return chunk_snapshot_build_subchunk_mesh(
			job.snapshot,
			job.subchunk_index,
			job.boundary_policy,
			output_allocator,
			scratch,
			job.neighbors,
		)
	case .Full_Chunk:
		break
	}

	switch job.mesher {
	case .Greedy_Binary:
		return chunk_snapshot_build_binary_greedy_mesh(
			job.snapshot,
			job.boundary_policy,
			output_allocator,
			scratch,
			job.neighbors,
		)
	}

	log.assertf(false, "unhandled chunk mesher: %v", job.mesher)
	return {}
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
	terrain_heightfield_voxel_view_fill(&block_storage.voxel_view, job.coord, job.seed)
	if block_storage.binary_greedy_row_cache != nil {
		terrain_binary_row_cache_fill(
			block_storage.binary_greedy_row_cache,
			block_storage.voxel_view,
			0,
		)
	}
	return {coord = job.coord, block_storage = block_storage}
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

chunk_store_count_dirty_generated :: proc() -> u32 {
	count: u32
	for chunk in state.chunk_store.chunks[:state.chunk_store.chunk_count] {
		if chunk.generation_state == .Generated && chunk.mesh_state == .Dirty {
			count += 1
		}
	}
	return count
}

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

//////////////////////////////////////
// Streaming Pipeline Methods
/////////////////////////////////////

generation_request_budgeted :: proc() -> u32 {
	if state.streaming_target_count == 0 {
		return 0
	}

	generation_request_count: u32

	scanned_count: u32
	for generation_request_count < CHUNK_GENERATION_BUDGET_PER_FRAME &&
	    scanned_count < state.streaming_target_count {
		target_index := state.next_streaming_target_index
		state.next_streaming_target_index =
			(state.next_streaming_target_index + 1) % state.streaming_target_count
		scanned_count += 1

		coord := state.streaming_targets[target_index]
		chunk: ^Chunk
		if chunk_index, ok := chunk_store_find_index_by_coord(coord).?; ok {
			chunk = chunk_store_get_by_index(chunk_index)
		} else {
			if state.chunk_store.chunk_count >= u32(len(state.chunk_store.chunks)) {
				break
			}
			chunk_id := chunk_store_append_reserved(coord)
			chunk = chunk_store_get_by_id(chunk_id)
		}

		if chunk.generation_state != .Missing {
			continue
		}

		job := world_async.ChunkGenerationJob {
			coord         = coord,
			seed          = 0,
			block_storage = chunk_block_storage_alloc_for_store(),
		}
		if !state.generation_request(job) {
			chunk_block_storage_release(&job.block_storage)
			break
		}

		chunk.block_storage = job.block_storage
		chunk.generation_state = .Queued
		generation_request_count += 1
	}

	return generation_request_count
}

generation_results_poll_budgeted :: proc() -> u32 {
	generation_results: [CHUNK_GENERATION_BUDGET_PER_FRAME]world_async.ChunkGenerationJobResult
	result_count := state.generation_poll_results(generation_results[:])
	if result_count == 0 {
		return 0
	}

	for i := 0; i < int(result_count); i += 1 {
		generation_result := &generation_results[i]
		log.assertf(
			len(generation_result.block_storage.voxel_view.blocks) == CHUNK_BLOCK_COUNT,
			"generated chunk storage has wrong block count",
		)

		index, ok := chunk_store_find_index_by_coord(generation_result.coord).?
		if !ok {
			chunk_block_storage_release(&generation_result.block_storage)
			continue
		}

		chunk := chunk_store_get_by_index(index)
		if chunk.generation_state == .Generated {
			if generation_result.block_storage.voxel_view.blocks.occupancy !=
			   chunk.block_storage.voxel_view.blocks.occupancy {
				chunk_block_storage_release(&generation_result.block_storage)
			}
			continue
		}
		if chunk.generation_state != .Queued {
			if generation_result.block_storage.voxel_view.blocks.occupancy !=
			   chunk.block_storage.voxel_view.blocks.occupancy {
				chunk_block_storage_release(&generation_result.block_storage)
			}
			continue
		}

		log.assertf(
			generation_result.block_storage.voxel_view.blocks.occupancy ==
			chunk.block_storage.voxel_view.blocks.occupancy,
			"generated storage must match queued chunk storage: coord=%v",
			generation_result.coord,
		)
		chunk_mark_generated(chunk, generation_result.block_storage)
		chunk_store_mark_generated_neighbors_boundary_dirty(generation_result.coord)
	}

	return result_count
}

mesh_request_budgeted :: proc() -> u32 {
	if state.chunk_store.chunk_count == 0 {
		return 0
	}

	if state.next_mesh_scan_index >= state.chunk_store.chunk_count {
		state.next_mesh_scan_index = 0
	}

	mesh_request_count: u32
	for scanned := u32(0);
	    scanned < state.chunk_store.chunk_count &&
	    mesh_request_count < CHUNK_MESH_BUDGET_PER_FRAME;
	    scanned += 1 {
		index := state.next_mesh_scan_index
		state.next_mesh_scan_index =
			(state.next_mesh_scan_index + 1) % state.chunk_store.chunk_count

		chunk := chunk_store_get_by_index(index)
		if chunk.generation_state != .Generated || chunk.mesh_state != .Dirty {
			continue
		}
		if state.streaming_target_count > 0 &&
		   !streaming_coord_inside_square_radius(
				   state.streaming_center_coord,
				   chunk.coord,
				   CHUNK_STREAMING_RADIUS_XZ,
			   ) {
			continue
		}
		if !streaming_mesh_dependencies_ready(chunk.coord) {
			continue
		}

		snapshot := chunk_snapshot_from_chunk(chunk)
		if chunk.subchunk_dirty_mask != 0 {
			subchunk_index := u32(bits.trailing_zeros(chunk.subchunk_dirty_mask))
			subchunk_bit := chunk_subchunk_mask_from_index(subchunk_index)
			job := world_async.ChunkMeshJob {
				mesher          = .Greedy_Binary,
				scope_kind      = .Subchunk,
				subchunk_index  = subchunk_index,
				snapshot        = snapshot,
				boundary_policy = .Sample_Neighbor_Snapshots,
				neighbors       = chunk_store_mesh_neighbors_find(snapshot.coord),
			}
			refs := chunk_mesh_snapshot_refs_from_job(job)
			chunk_store_mesh_snapshot_refs_acquire(refs)

			if !state.mesh_request(job) {
				chunk_store_mesh_snapshot_refs_release(refs)
				break
			}

			chunk.subchunk_dirty_mask &~= subchunk_bit
			chunk.queued_subchunk_index = subchunk_index
			chunk.mesh_state = .Queued
			chunk.dirty_flags = {}
			chunk_dirty_region_clear(chunk)
			chunk.queued_mesh_snapshot_refs = refs
			mesh_request_count += 1
			continue
		}

		job := world_async.ChunkMeshJob {
			mesher          = .Greedy_Binary,
			scope_kind      = .Full_Chunk,
			snapshot        = snapshot,
			boundary_policy = .Sample_Neighbor_Snapshots,
			neighbors       = chunk_store_mesh_neighbors_find(snapshot.coord),
		}
		refs := chunk_mesh_snapshot_refs_from_job(job)
		chunk_store_mesh_snapshot_refs_acquire(refs)

		if !state.mesh_request(job) {
			chunk_store_mesh_snapshot_refs_release(refs)
			break
		}

		chunk.mesh_state = .Queued
		chunk.queued_subchunk_index = CHUNK_SUBCHUNK_INVALID_INDEX
		chunk.dirty_flags = {}
		chunk_dirty_region_clear(chunk)
		chunk.queued_mesh_snapshot_refs = refs
		mesh_request_count += 1
	}

	return mesh_request_count
}

mesh_results_poll_budgeted :: proc() -> ChunkMeshBatchStats {
	chunk_mesh_results: [CHUNK_MESH_BUDGET_PER_FRAME]world_async.ChunkMeshJobResult
	result_count := state.mesh_poll_results(chunk_mesh_results[:])
	if result_count == 0 {
		return {}
	}

	return chunk_store_commit_mesh_results(chunk_mesh_results[:int(result_count)])
}

streaming_update_budgeted :: proc(observer_world_position: Vec3) -> StreamingUpdateStats {
	stats := StreamingUpdateStats{}

	mesh_stats := mesh_results_poll_budgeted()
	stats.chunks_generated = generation_results_poll_budgeted()
	stats.chunks_evicted = streaming_update_for_observer(observer_world_position)
	generation_request_budgeted()

	stats.chunk_mesh_jobs_submitted = mesh_request_budgeted()
	stats.chunk_mesh_results_committed = mesh_stats.chunks_committed
	stats.chunk_mesh_results_uploaded = mesh_stats.chunks_uploaded
	stats.chunks_dirty_remaining = chunk_store_count_dirty_generated()
	return stats
}

//////////////////////////////////////
// Streaming Methods
/////////////////////////////////////

streaming_update_for_observer :: proc(observer_world_position: Vec3) -> u32 {
	center := streaming_center_from_observer(observer_world_position)
	if state.streaming_target_count == 0 || center != state.streaming_center_coord {
		streaming_window_rebuild_targets(center)
	}
	return streaming_evict_outside_unload_radius()
}

streaming_center_from_observer :: proc(observer_world_position: Vec3) -> world_async.ChunkCoord {
	center := chunk_coord_from_block_coord(
		block_coord_from_world_position(observer_world_position),
	)
	center.y = 0
	return center
}

streaming_coord_inside_square_radius :: proc(
	center, coord: world_async.ChunkCoord,
	radius: u32,
) -> bool {
	dx := coord.x - center.x
	dz := coord.z - center.z
	r := i32(radius)

	return coord.y == center.y && dx >= -r && dx <= r && dz >= -r && dz <= r
}

streaming_target_less :: proc(center, a, b: world_async.ChunkCoord) -> bool {
	adx := a.x - center.x
	adz := a.z - center.z
	bdx := b.x - center.x
	bdz := b.z - center.z

	ad := adx * adx + adz * adz
	bd := bdx * bdx + bdz * bdz
	if ad != bd {return ad < bd}
	if a.z != b.z {return a.z < b.z}
	return a.x < b.x
}

streaming_evict_outside_unload_radius :: proc() -> u32 {
	evicted_count: u32
	for i := u32(0); i < state.chunk_store.chunk_count; {
		chunk := chunk_store_get_by_index(i)
		if streaming_coord_inside_square_radius(
			state.streaming_center_coord,
			chunk.coord,
			CHUNK_UNLOAD_RADIUS_XZ,
		) {
			i += 1
			continue
		}
		if chunk.generation_state == .Queued {
			i += 1
			continue
		}
		if chunk.mesh_snapshot_ref_count > 0 {
			i += 1
			continue
		}

		chunk_store_mark_generated_neighbors_boundary_dirty(chunk.coord)
		chunk_store_remove_at(i)
		evicted_count += 1
	}
	return evicted_count
}

streaming_mesh_dependency_ready :: proc(coord: world_async.ChunkCoord) -> bool {
	if !streaming_coord_inside_square_radius(
		state.streaming_center_coord,
		coord,
		CHUNK_STREAMING_RADIUS_XZ,
	) {
		return true
	}
	return chunk_store_coord_is_generated(coord)
}

streaming_mesh_dependencies_ready :: proc(coord: world_async.ChunkCoord) -> bool {
	return(
		streaming_mesh_dependency_ready(world_async.ChunkCoord{coord.x + 1, coord.y, coord.z}) &&
		streaming_mesh_dependency_ready(world_async.ChunkCoord{coord.x - 1, coord.y, coord.z}) &&
		streaming_mesh_dependency_ready(world_async.ChunkCoord{coord.x, coord.y, coord.z + 1}) &&
		streaming_mesh_dependency_ready(world_async.ChunkCoord{coord.x, coord.y, coord.z - 1}) \
	)
}

streaming_window_rebuild_targets :: proc(center: world_async.ChunkCoord) {
	state.streaming_center_coord = center
	state.streaming_target_count = 0

	radius := i32(CHUNK_STREAMING_RADIUS_XZ)
	for dz := -radius; dz <= radius; dz += 1 {
		for dx := -radius; dx <= radius; dx += 1 {
			state.streaming_targets[state.streaming_target_count] = {
				center.x + dx,
				0,
				center.z + dz,
			}
			state.streaming_target_count += 1
		}
	}

	for i := u32(0); i < state.streaming_target_count; i += 1 {
		best := i
		for j := i + 1; j < state.streaming_target_count; j += 1 {
			if streaming_target_less(
				center,
				state.streaming_targets[j],
				state.streaming_targets[best],
			) {
				best = j
			}
		}
		if best != i {
			state.streaming_targets[i], state.streaming_targets[best] =
				state.streaming_targets[best], state.streaming_targets[i]
		}
	}

	state.next_streaming_target_index = 0
}

//////////////////////////////////////
// Terrain Constants
/////////////////////////////////////

TERRAIN_BLOCK_WORLD_SIZE :: f32(0.5)
TERRAIN_PACK_LOCAL_X_SHIFT :: 0
TERRAIN_PACK_LOCAL_Y_SHIFT :: 7
TERRAIN_PACK_LOCAL_Z_SHIFT :: 14
TERRAIN_PACK_NORMAL_SHIFT :: 21
TERRAIN_PACK_MATERIAL_SHIFT :: 24
TERRAIN_PACK_LOCAL_MASK :: 0x7F
TERRAIN_PACK_NORMAL_MASK :: 0x7
TERRAIN_PACK_MATERIAL_MASK :: 0xFF

TERRAIN_GRASS_MAT_ID :: 0
TERRAIN_DIRT_MAT_ID :: 1
TERRAIN_STONE_MAT_ID :: 2
TERRAIN_WET_MARSH_MAT_ID :: 4
TERRAIN_CORRUPTED_ASH_MAT_ID :: 5
TERRAIN_MATERIAL_PALETTE_COUNT :: 8
#assert(TERRAIN_MATERIAL_PALETTE_COUNT == 8)
#assert(TERRAIN_MATERIAL_PALETTE_COUNT == world_async.TERRAIN_MATERIAL_PALETTE_COUNT)
TERRAIN_GENERATOR_VERSION :: u32(1)
TERRAIN_GRASS_CAP_BLOCK_DEPTH :: 4
TERRAIN_DIRT_LAYER_BLOCK_DEPTH :: 4
TERRAIN_BINARY_AXIS_COUNT :: 3
TERRAIN_BINARY_AXIS_ROW_COUNT :: CHUNK_BLOCK_LENGTH * CHUNK_BLOCK_LENGTH
#assert(TERRAIN_BINARY_AXIS_COUNT == world_async.TERRAIN_BINARY_AXIS_COUNT)
#assert(TERRAIN_BINARY_AXIS_ROW_COUNT == world_async.TERRAIN_BINARY_AXIS_ROW_COUNT)

TERRAIN_FACE_DESCS := [?]TerrainFaceDesc {
	// +X
	{neighbor_dx = 1, neighbor_dy = 0, neighbor_dz = 0, normal_id = 0},

	// -X
	{neighbor_dx = -1, neighbor_dy = 0, neighbor_dz = 0, normal_id = 1},

	// +Y
	{neighbor_dx = 0, neighbor_dy = 1, neighbor_dz = 0, normal_id = 2},

	// -Y
	{neighbor_dx = 0, neighbor_dy = -1, neighbor_dz = 0, normal_id = 3},

	// +Z
	{neighbor_dx = 0, neighbor_dy = 0, neighbor_dz = 1, normal_id = 4},

	// -Z
	{neighbor_dx = 0, neighbor_dy = 0, neighbor_dz = -1, normal_id = 5},
}

TERRAIN_MATERIAL_COLORS := TerrainMaterialColorPalette {
	{0.38, 0.75, 0.34, 1.0}, // Grass
	{0.55, 0.38, 0.22, 1.0}, // Dirt
	{0.45, 0.45, 0.48, 1.0}, // Stone
	{0.70, 0.68, 0.55, 1.0}, // Sand
	{0.25, 0.45, 0.85, 1.0}, // Water
	{0.80, 0.35, 0.25, 1.0}, // Lava / Red Sand / Terracotta
	{0.85, 0.78, 0.36, 1.0}, // Gold / Sandstone / Hay
	{0.85, 0.85, 0.85, 1.0}, // Snow / Ice / White Concrete
}

//////////////////////////////////////
// Terrain Types
/////////////////////////////////////

TerrainMaterialColorPalette :: [8]Vec4

TerrainUnpackedVertex :: struct {
	block_x, block_y, block_z: u32,
	normal_id, material_id:    u32,
}
#assert(size_of(TerrainUnpackedVertex) == 20)

TerrainDrawParams :: struct {
	vertex_byte_offset:  u32,
	vertex_stride_bytes: u32,
	_padding:            UVec2,
	chunk_origin:        Vec4, // xyz used, w = block_world_size
}

TerrainFaceDesc :: struct {
	neighbor_dx, neighbor_dy, neighbor_dz: i32,
	normal_id:                             u32,
}

TerrainGridPoint :: struct {
	x, y, z: u32,
}

TerrainBiomeColumn :: struct {
	surface_height:      i32,
	surface_layer_depth: i32,
	dominant_biome_id:   biomes.BiomeID,
}

//////////////////////////////////////
// Terrain Methods
/////////////////////////////////////

terrain_chunk_origin_world_from_coord :: proc(coord: world_async.ChunkCoord) -> Vec4 {
	origin := chunk_origin_from_coord(coord)
	return {
		f32(origin.x) * TERRAIN_BLOCK_WORLD_SIZE,
		f32(origin.y) * TERRAIN_BLOCK_WORLD_SIZE,
		f32(origin.z) * TERRAIN_BLOCK_WORLD_SIZE,
		TERRAIN_BLOCK_WORLD_SIZE,
	}
}

terrain_pack_vertex :: proc(
	block_x, block_y, block_z: u32,
	normal_id, material_id: u32,
) -> world_async.TerrainPackedVertex {
	log.assertf(block_x <= CHUNK_BLOCK_LENGTH, "terrain block_x out of range: %d", block_x)
	log.assertf(block_y <= CHUNK_BLOCK_LENGTH, "terrain block_y out of range: %d", block_y)
	log.assertf(block_z <= CHUNK_BLOCK_LENGTH, "terrain block_z out of range: %d", block_z)
	log.assertf(normal_id < 6, "terrain normal_id out of range: %d", normal_id)
	log.assertf(material_id <= 255, "terrain material_id out of range: %d", material_id)
	return world_async.TerrainPackedVertex(
		(block_x << TERRAIN_PACK_LOCAL_X_SHIFT) |
		(block_y << TERRAIN_PACK_LOCAL_Y_SHIFT) |
		(block_z << TERRAIN_PACK_LOCAL_Z_SHIFT) |
		(normal_id << TERRAIN_PACK_NORMAL_SHIFT) |
		(material_id << TERRAIN_PACK_MATERIAL_SHIFT),
	)
}

terrain_unpack_vertex :: proc(vertex: world_async.TerrainPackedVertex) -> TerrainUnpackedVertex {
	packed := u32(vertex)
	return {
		block_x = (packed >> TERRAIN_PACK_LOCAL_X_SHIFT) & TERRAIN_PACK_LOCAL_MASK,
		block_y = (packed >> TERRAIN_PACK_LOCAL_Y_SHIFT) & TERRAIN_PACK_LOCAL_MASK,
		block_z = (packed >> TERRAIN_PACK_LOCAL_Z_SHIFT) & TERRAIN_PACK_LOCAL_MASK,
		normal_id = (packed >> TERRAIN_PACK_NORMAL_SHIFT) & TERRAIN_PACK_NORMAL_MASK,
		material_id = (packed >> TERRAIN_PACK_MATERIAL_SHIFT) & TERRAIN_PACK_MATERIAL_MASK,
	}
}

terrain_heightfield_voxel_view_fill :: proc(
	view: ^world_async.ChunkVoxelView,
	chunk: world_async.ChunkCoord,
	seed: u32,
) {
	log.assertf(
		len(view.blocks) == CHUNK_BLOCK_COUNT,
		"heightfield fill expects %d blocks, got %d",
		CHUNK_BLOCK_COUNT,
		len(view.blocks),
	)
	chunk_voxel_view_fill_empty(view)

	origin := chunk_origin_from_coord(chunk)
	key := terrain_generation_key_make(seed)
	generation_region := biomes.generation_region_build(
		key,
		biomes.generation_region_coord_from_block(origin.x, origin.y, origin.z),
	)
	for z in 0 ..< CHUNK_BLOCK_LENGTH {
		for x in 0 ..< CHUNK_BLOCK_LENGTH {
			world_x := origin.x + i32(x)
			world_z := origin.z + i32(z)
			surface_sample := biomes.surface_biome_field_sample_from_region(
				&generation_region,
				world_x,
				world_z,
			)
			column := terrain_biome_column_sample(key, surface_sample, world_x, world_z)

			for y in 0 ..< CHUNK_BLOCK_LENGTH {
				world_y := origin.y + i32(y)

				if world_y > column.surface_height {
					continue
				}

				blocks_below_surface := column.surface_height - world_y
				material_id := terrain_biome_block_material_id(
					column.dominant_biome_id,
					blocks_below_surface,
					column.surface_layer_depth,
				)

				index := chunk_block_index(u32(x), u32(y), u32(z))
				view.blocks.occupancy[index] = .Solid
				view.blocks.material_id[index] = material_id
			}
		}
	}
}

terrain_generation_key_make :: proc(seed: u32) -> biomes.FeatureGridKey {
	return biomes.feature_grid_key_make(u64(seed), TERRAIN_GENERATOR_VERSION)
}

terrain_biome_column_sample :: proc(
	key: biomes.FeatureGridKey,
	surface_sample: biomes.SurfaceBiomeFieldSample,
	world_x, world_z: i32,
) -> TerrainBiomeColumn {
	evaluation := biomes.surface_biome_profile_evaluate(key, surface_sample, world_x, world_z)
	target := evaluation.final_target

	height := i32(math.floor_f32(target.surface_height_blocks))
	height = math.clamp(height, 0, CHUNK_BLOCK_LENGTH - 1)

	surface_layer_depth := terrain_biome_layer_depth_ceil(target.surface_layer_depth_blocks)
	surface_layer_depth = math.clamp(surface_layer_depth, 1, CHUNK_BLOCK_LENGTH)

	return {
		surface_height = height,
		surface_layer_depth = surface_layer_depth,
		dominant_biome_id = target.biome_id,
	}
}

terrain_biome_column_sample_direct :: proc(
	key: biomes.FeatureGridKey,
	world_x, world_z: i32,
) -> TerrainBiomeColumn {
	surface_sample := biomes.surface_biome_field_sample(key, world_x, world_z)
	return terrain_biome_column_sample(key, surface_sample, world_x, world_z)
}

terrain_biome_layer_depth_ceil :: proc(depth: f32) -> i32 {
	whole := i32(depth)
	if f32(whole) < depth {
		whole += 1
	}
	return whole
}

terrain_biome_block_material_id :: proc(
	biome_id: biomes.BiomeID,
	blocks_below_surface, surface_layer_depth: i32,
) -> world_async.BlockMaterialID {
	if blocks_below_surface < surface_layer_depth {
		return terrain_biome_surface_material_id(biome_id)
	}
	if blocks_below_surface < surface_layer_depth + TERRAIN_DIRT_LAYER_BLOCK_DEPTH {
		return terrain_biome_subsurface_material_id(biome_id)
	}
	return world_async.BlockMaterialID(TERRAIN_STONE_MAT_ID)
}

terrain_biome_surface_material_id :: proc(
	biome_id: biomes.BiomeID,
) -> world_async.BlockMaterialID {
	switch biome_id {
	case .Temperate_Hills:
		return world_async.BlockMaterialID(TERRAIN_GRASS_MAT_ID)
	case .Basalt_Spire_Highlands:
		return world_async.BlockMaterialID(TERRAIN_STONE_MAT_ID)
	case .Wet_Lowland_Marsh:
		return world_async.BlockMaterialID(TERRAIN_WET_MARSH_MAT_ID)
	case .Corrupted_Ash_Forest:
		return world_async.BlockMaterialID(TERRAIN_CORRUPTED_ASH_MAT_ID)
	case .Fungal_Vaults, .Crystal_Geode_Network, .Buried_Aquifer_Caves:
		log.assert(false, "surface terrain fill received subterranean biome identity")
		return world_async.BlockMaterialID(TERRAIN_STONE_MAT_ID)
	}

	log.assertf(false, "unhandled terrain biome surface material: %v", biome_id)
	return world_async.BlockMaterialID(TERRAIN_STONE_MAT_ID)
}

terrain_biome_subsurface_material_id :: proc(
	biome_id: biomes.BiomeID,
) -> world_async.BlockMaterialID {
	switch biome_id {
	case .Basalt_Spire_Highlands:
		return world_async.BlockMaterialID(TERRAIN_STONE_MAT_ID)
	case .Corrupted_Ash_Forest:
		return world_async.BlockMaterialID(TERRAIN_CORRUPTED_ASH_MAT_ID)
	case .Temperate_Hills, .Wet_Lowland_Marsh:
		return world_async.BlockMaterialID(TERRAIN_DIRT_MAT_ID)
	case .Fungal_Vaults, .Crystal_Geode_Network, .Buried_Aquifer_Caves:
		log.assert(false, "surface terrain fill received subterranean biome identity")
		return world_async.BlockMaterialID(TERRAIN_STONE_MAT_ID)
	}

	log.assertf(false, "unhandled terrain biome subsurface material: %v", biome_id)
	return world_async.BlockMaterialID(TERRAIN_STONE_MAT_ID)
}

//////////////////////////////////////
// Debug Methods
/////////////////////////////////////

when ODIN_DEBUG {

	debug_chunk_mesher_contract_checks_run :: proc(transient_arena: ^mem.Arena) {
		temp := mem.begin_arena_temp_memory(transient_arena)
		defer mem.end_arena_temp_memory(temp)
		allocator := mem.arena_allocator(transient_arena)
		scratch := terrain_binary_greedy_scratch_alloc(allocator)

		view := world_async.ChunkVoxelView {
			blocks = make(#soa[]world_async.ChunkVoxelViewElement, CHUNK_BLOCK_COUNT, allocator),
		}

		packed_fields := terrain_unpack_vertex(terrain_pack_vertex(2, 3, 4, 5, 6))
		log.assertf(
			packed_fields.block_x == 2,
			"terrain pack/unpack: expected block_x 2, got %d",
			packed_fields.block_x,
		)
		log.assertf(
			packed_fields.block_y == 3,
			"terrain pack/unpack: expected block_y 3, got %d",
			packed_fields.block_y,
		)
		log.assertf(
			packed_fields.block_z == 4,
			"terrain pack/unpack: expected block_z 4, got %d",
			packed_fields.block_z,
		)
		log.assertf(
			packed_fields.normal_id == 5,
			"terrain pack/unpack: expected normal 5, got %d",
			packed_fields.normal_id,
		)
		log.assertf(
			packed_fields.material_id == 6,
			"terrain pack/unpack: expected material 6, got %d",
			packed_fields.material_id,
		)
		chunk_voxel_view_fill_empty(&view)
		empty_output := chunk_voxel_view_build_binary_greedy_mesh(
			view,
			.Treat_Out_Of_Chunk_As_Empty,
			allocator,
			scratch,
		)
		log.assertf(
			empty_output.face_count == 0,
			"empty chunk: expected 0 faces, got %d",
			empty_output.face_count,
		)
		log.assertf(
			len(empty_output.vertices) == 0,
			"empty chunk: expected 0 vertices, got %d",
			len(empty_output.vertices),
		)
		log.assertf(
			len(empty_output.indices) == 0,
			"empty chunk: expected 0 indices, got %d",
			len(empty_output.indices),
		)

		// one edge block proves boundary policy at local 0
		chunk_voxel_view_fill_empty(&view)
		index := chunk_block_index(0, 0, 0)
		view.blocks.occupancy[index] = .Solid
		view.blocks.material_id[index] = world_async.BlockMaterialID(5)

		edge_output := chunk_voxel_view_build_binary_greedy_mesh(
			view,
			.Treat_Out_Of_Chunk_As_Empty,
			allocator,
			scratch,
		)
		log.assertf(
			edge_output.face_count == 6,
			"edge chunk: expected 6 face, got %d",
			edge_output.face_count,
		)

		// one interior block exact payload
		chunk_voxel_view_fill_empty(&view)
		index = chunk_block_index(2, 3, 4)
		view.blocks.occupancy[index] = .Solid
		view.blocks.material_id[index] = world_async.BlockMaterialID(5)


		output := chunk_voxel_view_build_binary_greedy_mesh(
			view,
			.Treat_Out_Of_Chunk_As_Empty,
			allocator,
			scratch,
		)
		log.assertf(
			output.face_count == 6,
			"edge chunk: expected 6 face, got %d",
			output.face_count,
		)
		log.assertf(
			len(output.vertices) == 24,
			"edge chunk: expected 24 vertices, got %d",
			len(output.vertices),
		)
		log.assertf(
			len(output.indices) == 36,
			"edge chunk: expected 36 indices, got %d",
			len(output.indices),
		)

		expected_normals := [?]u32{0, 1, 2, 3, 4, 5}
		expected_single_block_corners := [?]TerrainGridPoint {
			// +X
			{3, 3, 4},
			{3, 4, 4},
			{3, 4, 5},
			{3, 3, 5},

			// -X
			{2, 3, 4},
			{2, 3, 5},
			{2, 4, 5},
			{2, 4, 4},

			// +Y
			{2, 4, 4},
			{2, 4, 5},
			{3, 4, 5},
			{3, 4, 4},

			// -Y
			{2, 3, 4},
			{3, 3, 4},
			{3, 3, 5},
			{2, 3, 5},

			// +Z
			{2, 3, 5},
			{3, 3, 5},
			{3, 4, 5},
			{2, 4, 5},

			// -Z
			{2, 3, 4},
			{2, 4, 4},
			{3, 4, 4},
			{3, 3, 4},
		}
		for face_index in 0 ..< 6 {
			expected_normal := expected_normals[face_index]
			for corner_index in 0 ..< 4 {
				vertex_index := face_index * 4 + corner_index
				expected_corner := expected_single_block_corners[vertex_index]
				unpacked_vertex := terrain_unpack_vertex(output.vertices[vertex_index])

				log.assertf(
					unpacked_vertex.block_x == expected_corner.x,
					"single block vertex %d: expected local_x %d, got %d",
					vertex_index,
					expected_corner.x,
					unpacked_vertex.block_x,
				)
				log.assertf(
					unpacked_vertex.block_y == expected_corner.y,
					"single block vertex %d: expected local_y %d, got %d",
					vertex_index,
					expected_corner.y,
					unpacked_vertex.block_y,
				)
				log.assertf(
					unpacked_vertex.block_z == expected_corner.z,
					"single block vertex %d: expected local_z %d, got %d",
					vertex_index,
					expected_corner.z,
					unpacked_vertex.block_z,
				)
				log.assertf(
					unpacked_vertex.normal_id == expected_normal,
					"single block vertex %d: expected normal %d, got %d",
					vertex_index,
					expected_normal,
					unpacked_vertex.normal_id,
				)
				log.assertf(
					unpacked_vertex.material_id == 5,
					"single block vertex %d: expected material 5, got %d",
					vertex_index,
					unpacked_vertex.material_id,
				)
			}
		}

		for face_index in 0 ..< 6 {
			base := u32(face_index * 4)
			i := face_index * 6
			log.assertf(output.indices[i + 0] == base + 0, "single block index %d mismatch", i + 0)
			log.assertf(output.indices[i + 1] == base + 1, "single block index %d mismatch", i + 1)
			log.assertf(output.indices[i + 2] == base + 2, "single block index %d mismatch", i + 2)
			log.assertf(output.indices[i + 3] == base + 0, "single block index %d mismatch", i + 3)
			log.assertf(output.indices[i + 4] == base + 2, "single block index %d mismatch", i + 4)
			log.assertf(output.indices[i + 5] == base + 3, "single block index %d mismatch", i + 5)
		}

		{
			binary_temp := mem.begin_arena_temp_memory(transient_arena)
			defer mem.end_arena_temp_memory(binary_temp)
			greedy_single_output := mesh_job_execute_sync(
				{
					mesher = .Greedy_Binary,
					snapshot = {coord = {0, 0, 0}, voxel_view = view},
					boundary_policy = .Treat_Out_Of_Chunk_As_Empty,
				},
				allocator,
				allocator,
			)
			log.assertf(
				greedy_single_output.face_count == 6,
				"greedy single block: expected 6 faces, got %d",
				greedy_single_output.face_count,
			)
			log.assertf(
				len(greedy_single_output.vertices) == 24,
				"greedy single block: expected 24 vertices, got %d",
				len(greedy_single_output.vertices),
			)
			log.assertf(
				len(greedy_single_output.indices) == 36,
				"greedy single block: expected 36 indices, got %d",
				len(greedy_single_output.indices),
			)
			subchunk_single_output := mesh_job_execute_sync(
				{
					mesher = .Greedy_Binary,
					scope_kind = .Subchunk,
					subchunk_index = chunk_subchunk_index_from_coord(0, 0, 0),
					snapshot = {coord = {0, 0, 0}, voxel_view = view},
					boundary_policy = .Treat_Out_Of_Chunk_As_Empty,
				},
				allocator,
				allocator,
			)
			log.assertf(
				subchunk_single_output.face_count == 6,
				"subchunk single block: expected 6 faces, got %d",
				subchunk_single_output.face_count,
			)
			subchunk_empty_output := mesh_job_execute_sync(
				{
					mesher = .Greedy_Binary,
					scope_kind = .Subchunk,
					subchunk_index = chunk_subchunk_index_from_coord(1, 0, 0),
					snapshot = {coord = {0, 0, 0}, voxel_view = view},
					boundary_policy = .Treat_Out_Of_Chunk_As_Empty,
				},
				allocator,
				allocator,
			)
			log.assertf(
				subchunk_empty_output.face_count == 0,
				"empty subchunk: expected 0 faces, got %d",
				subchunk_empty_output.face_count,
			)
			for face_index in 0 ..< 6 {
				expected_normal := expected_normals[face_index]
				for corner_index in 0 ..< 4 {
					vertex_index := face_index * 4 + corner_index
					expected_corner := expected_single_block_corners[vertex_index]
					unpacked_vertex := terrain_unpack_vertex(
						greedy_single_output.vertices[vertex_index],
					)

					log.assertf(
						unpacked_vertex.block_x == expected_corner.x,
						"greedy single block vertex %d: expected local_x %d, got %d",
						vertex_index,
						expected_corner.x,
						unpacked_vertex.block_x,
					)
					log.assertf(
						unpacked_vertex.block_y == expected_corner.y,
						"greedy single block vertex %d: expected local_y %d, got %d",
						vertex_index,
						expected_corner.y,
						unpacked_vertex.block_y,
					)
					log.assertf(
						unpacked_vertex.block_z == expected_corner.z,
						"greedy single block vertex %d: expected local_z %d, got %d",
						vertex_index,
						expected_corner.z,
						unpacked_vertex.block_z,
					)
					log.assertf(
						unpacked_vertex.normal_id == expected_normal,
						"greedy single block vertex %d: expected normal %d, got %d",
						vertex_index,
						expected_normal,
						unpacked_vertex.normal_id,
					)
					log.assertf(
						unpacked_vertex.material_id == 5,
						"greedy single block vertex %d: expected material 5, got %d",
						vertex_index,
						unpacked_vertex.material_id,
					)
				}
			}
		}

		// adjacent X/Y/Z: each pair becomes one rectangular prism with six merged faces.
		adjacent_pairs := [?][2]world_async.BlockCoord {
			{{1, 1, 1}, {2, 1, 1}},
			{{1, 1, 1}, {1, 2, 1}},
			{{1, 1, 1}, {1, 1, 2}},
		}

		for pair, pair_index in adjacent_pairs {
			chunk_voxel_view_fill_empty(&view)

			for block in pair {
				index = chunk_block_index(u32(block.x), u32(block.y), u32(block.z))
				view.blocks.occupancy[index] = .Solid
				view.blocks.material_id[index] = world_async.BlockMaterialID(1)
			}

			adjacent_output := chunk_voxel_view_build_binary_greedy_mesh(
				view,
				.Treat_Out_Of_Chunk_As_Empty,
				allocator,
				scratch,
			)
			log.assertf(
				adjacent_output.face_count == 6,
				"adjacent pair %d: expected 6 merged faces, got %d",
				pair_index,
				adjacent_output.face_count,
			)
		}

		// adjacent chunks: touching boundary blocks suppress their shared faces.
		left_view := world_async.ChunkVoxelView {
			blocks = make(#soa[]world_async.ChunkVoxelViewElement, CHUNK_BLOCK_COUNT, allocator),
		}
		right_view := world_async.ChunkVoxelView {
			blocks = make(#soa[]world_async.ChunkVoxelViewElement, CHUNK_BLOCK_COUNT, allocator),
		}
		chunk_voxel_view_fill_empty(&left_view)
		chunk_voxel_view_fill_empty(&right_view)

		left_index := chunk_block_index(CHUNK_BLOCK_LOCAL_MAX, 1, 1)
		left_view.blocks.occupancy[left_index] = .Solid
		left_view.blocks.material_id[left_index] = world_async.BlockMaterialID(7)

		right_index := chunk_block_index(0, 1, 1)
		right_view.blocks.occupancy[right_index] = .Solid
		right_view.blocks.material_id[right_index] = world_async.BlockMaterialID(7)

		left_snapshot := world_async.ChunkSnapshot {
			coord      = {0, 0, 0},
			voxel_view = left_view,
		}
		right_snapshot := world_async.ChunkSnapshot {
			coord      = {1, 0, 0},
			voxel_view = right_view,
		}
		neighbor_test_snapshots := [?]world_async.ChunkSnapshot{left_snapshot, right_snapshot}

		left_neighbor_output := mesh_job_execute_sync(
			{
				mesher = .Greedy_Binary,
				snapshot = left_snapshot,
				neighbors = chunk_mesh_neighbors_find(
					neighbor_test_snapshots[:],
					left_snapshot.coord,
				),
				boundary_policy = .Sample_Neighbor_Snapshots,
			},
			allocator,
			allocator,
		)
		log.assertf(
			left_neighbor_output.face_count == 5,
			"left boundary block: expected 5 faces with +X neighbor, got %d",
			left_neighbor_output.face_count,
		)

		right_neighbor_output := mesh_job_execute_sync(
			{
				mesher = .Greedy_Binary,
				snapshot = right_snapshot,
				neighbors = chunk_mesh_neighbors_find(
					neighbor_test_snapshots[:],
					right_snapshot.coord,
				),
				boundary_policy = .Sample_Neighbor_Snapshots,
			},
			allocator,
			allocator,
		)
		log.assertf(
			right_neighbor_output.face_count == 5,
			"right boundary block: expected 5 faces with -X neighbor, got %d",
			right_neighbor_output.face_count,
		)

		{
			binary_temp := mem.begin_arena_temp_memory(transient_arena)
			defer mem.end_arena_temp_memory(binary_temp)
			left_greedy_neighbor_output := mesh_job_execute_sync(
				{
					mesher = .Greedy_Binary,
					snapshot = left_snapshot,
					neighbors = chunk_mesh_neighbors_find(
						neighbor_test_snapshots[:],
						left_snapshot.coord,
					),
					boundary_policy = .Sample_Neighbor_Snapshots,
				},
				allocator,
				allocator,
			)
			log.assertf(
				left_greedy_neighbor_output.face_count == 5,
				"greedy left boundary block: expected 5 faces with +X neighbor, got %d",
				left_greedy_neighbor_output.face_count,
			)

			right_greedy_neighbor_output := mesh_job_execute_sync(
				{
					mesher = .Greedy_Binary,
					snapshot = right_snapshot,
					neighbors = chunk_mesh_neighbors_find(
						neighbor_test_snapshots[:],
						right_snapshot.coord,
					),
					boundary_policy = .Sample_Neighbor_Snapshots,
				},
				allocator,
				allocator,
			)
			log.assertf(
				right_greedy_neighbor_output.face_count == 5,
				"greedy right boundary block: expected 5 faces with -X neighbor, got %d",
				right_greedy_neighbor_output.face_count,
			)
		}

		// 2x2x2 solid cube: binary greedy merges each side into one quad.
		chunk_voxel_view_fill_empty(&view)
		for z in 1 ..< 3 {
			for y in 1 ..< 3 {
				for x in 1 ..< 3 {
					index = chunk_block_index(u32(x), u32(y), u32(z))
					view.blocks.occupancy[index] = .Solid
					view.blocks.material_id[index] = world_async.BlockMaterialID(2)
				}
			}
		}

		{
			binary_temp := mem.begin_arena_temp_memory(transient_arena)
			defer mem.end_arena_temp_memory(binary_temp)
			greedy_output := chunk_voxel_view_build_binary_greedy_mesh(
				view,
				.Treat_Out_Of_Chunk_As_Empty,
				allocator,
				scratch,
			)
			log.assertf(
				greedy_output.face_count == 6,
				"greedy 2x2x2: expected 6 faces, got %d",
				greedy_output.face_count,
			)
			log.assertf(
				len(greedy_output.vertices) == 24,
				"greedy 2x2x2: expected 24 vertices, got %d",
				len(greedy_output.vertices),
			)
			log.assertf(
				len(greedy_output.indices) == 36,
				"greedy 2x2x2: expected 36 indices, got %d",
				len(greedy_output.indices),
			)
		}

		// current rectangular debug fixture: one cuboid should merge to six quads.
		chunk_voxel_view_debug_rect_build(&view, allocator)

		{
			binary_temp := mem.begin_arena_temp_memory(transient_arena)
			defer mem.end_arena_temp_memory(binary_temp)
			greedy_rect_output := chunk_voxel_view_build_binary_greedy_mesh(
				view,
				.Treat_Out_Of_Chunk_As_Empty,
				allocator,
				scratch,
			)
			log.assertf(
				greedy_rect_output.face_count == 6,
				"greedy debug rect: expected 6 faces, got %d",
				greedy_rect_output.face_count,
			)
		}

		// full chunk: only six outer surfaces emit.
		chunk_voxel_view_fill_empty(&view)
		for z in 0 ..< CHUNK_BLOCK_LENGTH {
			for y in 0 ..< CHUNK_BLOCK_LENGTH {
				for x in 0 ..< CHUNK_BLOCK_LENGTH {
					index = chunk_block_index(u32(x), u32(y), u32(z))
					view.blocks.occupancy[index] = .Solid
					view.blocks.material_id[index] = world_async.BlockMaterialID(3)
				}
			}
		}

		{
			binary_temp := mem.begin_arena_temp_memory(transient_arena)
			defer mem.end_arena_temp_memory(binary_temp)
			greedy_full_output := chunk_voxel_view_build_binary_greedy_mesh(
				view,
				.Treat_Out_Of_Chunk_As_Empty,
				allocator,
				scratch,
			)
			log.assertf(
				greedy_full_output.face_count == 6,
				"greedy full chunk: expected 6 faces, got %d",
				greedy_full_output.face_count,
			)
			log.assertf(
				len(greedy_full_output.vertices) == 24,
				"greedy full chunk: expected 24 vertices, got %d",
				len(greedy_full_output.vertices),
			)
			log.assertf(
				len(greedy_full_output.indices) == 36,
				"greedy full chunk: expected 36 indices, got %d",
				len(greedy_full_output.indices),
			)
		}

		// checkerboard: count-only, do not build mesh output.
		chunk_voxel_view_fill_empty(&view)
		for z in 0 ..< CHUNK_BLOCK_LENGTH {
			for y in 0 ..< CHUNK_BLOCK_LENGTH {
				for x in 0 ..< CHUNK_BLOCK_LENGTH {
					if ((x + y + z) & 1) == 0 {
						index = chunk_block_index(u32(x), u32(y), u32(z))
						view.blocks.occupancy[index] = .Solid
						view.blocks.material_id[index] = world_async.BlockMaterialID(4)
					}
				}
			}
		}

		expected_checker_faces := u32(786432)
		{
			binary_temp := mem.begin_arena_temp_memory(transient_arena)
			defer mem.end_arena_temp_memory(binary_temp)
			greedy_checker_count := chunk_voxel_view_count_binary_greedy_faces(
				view,
				.Treat_Out_Of_Chunk_As_Empty,
				scratch,
			)
			log.assertf(
				greedy_checker_count == expected_checker_faces,
				"greedy checkerboard: expected %d faces, got %d",
				expected_checker_faces,
				greedy_checker_count,
			)
		}

		heightfield_coord := world_async.ChunkCoord{0, 0, 0}
		heightfield_seed := u32(0)
		heightfield_origin := chunk_origin_from_coord(heightfield_coord)
		heightfield_key := terrain_generation_key_make(heightfield_seed)
		terrain_heightfield_voxel_view_fill(&view, heightfield_coord, heightfield_seed)
		heightfield_top_y: [CHUNK_BLOCK_LENGTH * CHUNK_BLOCK_LENGTH]i32
		for z in 0 ..< CHUNK_BLOCK_LENGTH {
			for x in 0 ..< CHUNK_BLOCK_LENGTH {
				column := terrain_biome_column_sample_direct(
					heightfield_key,
					heightfield_origin.x + i32(x),
					heightfield_origin.z + i32(z),
				)
				top_y: i32 = -1
				for y in 0 ..< CHUNK_BLOCK_LENGTH {
					index = chunk_block_index(u32(x), u32(y), u32(z))
					if view.blocks.occupancy[index] == .Solid {
						top_y = i32(y)
					}
				}

				log.assertf(
					top_y >= 0,
					"heightfield column %d,%d: expected at least one solid block",
					x,
					z,
				)
				heightfield_top_y[x + z * CHUNK_BLOCK_LENGTH] = top_y

				log.assertf(
					top_y == column.surface_height,
					"biome heightfield column %d,%d: expected top y %d, got %d",
					x,
					z,
					column.surface_height,
					top_y,
				)

				top_index := chunk_block_index(u32(x), u32(top_y), u32(z))
				top_material_id := u32(u8(view.blocks.material_id[top_index]))
				expected_top_material_id := u32(
					u8(terrain_biome_surface_material_id(column.dominant_biome_id)),
				)
				log.assertf(
					top_material_id == expected_top_material_id,
					"biome heightfield column %d,%d: expected top material %d, got %d",
					x,
					z,
					expected_top_material_id,
					top_material_id,
				)

				for y in 0 ..< CHUNK_BLOCK_LENGTH {
					blocks_below_surface := top_y - i32(y)
					if blocks_below_surface < 0 ||
					   blocks_below_surface >= column.surface_layer_depth {
						continue
					}

					index = chunk_block_index(u32(x), u32(y), u32(z))
					log.assertf(
						view.blocks.occupancy[index] == .Solid,
						"heightfield column %d,%d: expected grass-cap block %d to be solid",
						x,
						z,
						y,
					)

					material_id := u32(u8(view.blocks.material_id[index]))
					log.assertf(
						material_id == expected_top_material_id,
						"biome heightfield column %d,%d: expected surface material %d, got %d",
						x,
						z,
						expected_top_material_id,
						material_id,
					)
				}
			}
		}

		heightfield_output := chunk_voxel_view_build_binary_greedy_mesh(
			view,
			.Treat_Out_Of_Chunk_As_Empty,
			allocator,
			scratch,
		)
		log.assertf(
			heightfield_output.face_count > 0,
			"greedy heightfield: expected non-empty output",
		)
		top_face_count: u32
		for face_index in 0 ..< heightfield_output.face_count {
			vertex := terrain_unpack_vertex(heightfield_output.vertices[face_index * 4])

			if vertex.normal_id != 2 {
				continue
			}
			top_face_count += 1

			log.assertf(
				vertex.block_x < CHUNK_BLOCK_LENGTH && vertex.block_z < CHUNK_BLOCK_LENGTH,
				"heightfield top face %d: local x/z out of column range: %d,%d",
				face_index,
				vertex.block_x,
				vertex.block_z,
			)

			top_y := heightfield_top_y[vertex.block_x + vertex.block_z * CHUNK_BLOCK_LENGTH]
			surface_block_y := i32(vertex.block_y) - 1
			log.assertf(
				surface_block_y == top_y,
				"heightfield top face %d: expected surface block y %d, got %d",
				face_index,
				top_y,
				surface_block_y,
			)

			column := terrain_biome_column_sample_direct(
				heightfield_key,
				heightfield_origin.x + i32(vertex.block_x),
				heightfield_origin.z + i32(vertex.block_z),
			)
			expected_top_material_id := u32(
				u8(terrain_biome_surface_material_id(column.dominant_biome_id)),
			)
			log.assertf(
				vertex.material_id == expected_top_material_id,
				"heightfield face %d: expected top block material %d, got %d",
				face_index,
				expected_top_material_id,
				vertex.material_id,
			)
		}
		log.assert(top_face_count > 0, "greedy heightfield: expected at least one top face")

		log.debug("Chunk mesher contract checks passed")
	}

	debug_chunk_edit_contract_checks_run :: proc(transient_arena: ^mem.Arena) {
		log.assert(state.initialized, "chunk edit checks require initialized world state")
		log.assertf(
			state.chunk_store.chunk_count == 0,
			"chunk edit checks expect an empty chunk store, got %d chunks",
			state.chunk_store.chunk_count,
		)

		left_id := chunk_store_append_reserved({0, 0, 0})
		left := chunk_store_get_by_id(left_id)
		left_storage := chunk_block_storage_alloc_for_store()
		chunk_mark_generated(left, left_storage)
		left.mesh_state = .Ready
		left.dirty_flags = {}
		chunk_dirty_region_clear(left)
		{
			temp := mem.begin_arena_temp_memory(transient_arena)
			allocator := mem.arena_allocator(transient_arena)
			scratch := terrain_binary_greedy_scratch_alloc(allocator)
			seed_index := chunk_block_index(8, 8, 8)
			left.block_storage.voxel_view.blocks.occupancy[seed_index] = .Solid
			left.block_storage.voxel_view.blocks.material_id[seed_index] =
				world_async.BlockMaterialID(TERRAIN_STONE_MAT_ID)
			if left.block_storage.binary_greedy_row_cache != nil {
				terrain_binary_row_cache_fill(
					left.block_storage.binary_greedy_row_cache,
					left.block_storage.voxel_view,
					left.block_version,
				)
			}
			full_output := chunk_voxel_view_build_binary_greedy_mesh(
				left.block_storage.voxel_view,
				.Treat_Out_Of_Chunk_As_Empty,
				allocator,
				scratch,
			)
			left.geometry_id = state.chunk_mesh_upload(left.geometry_id, full_output)
			mem.end_arena_temp_memory(temp)
		}
		log.assert(
			left.geometry_id != INVALID_CHUNK_GEOMETRY_ID,
			"edit contract should start with drawable full chunk geometry",
		)

		right_id := chunk_store_append_reserved({1, 0, 0})
		right := chunk_store_get_by_id(right_id)
		right_storage := chunk_block_storage_alloc_for_store()
		chunk_mark_generated(right, right_storage)
		right.mesh_state = .Ready
		right.dirty_flags = {}
		chunk_dirty_region_clear(right)

		interior_block := world_async.BlockCoord{1, 2, 3}
		applied := chunk_store_block_edit_apply(
			interior_block,
			.Solid,
			world_async.BlockMaterialID(5),
		)
		log.assert(applied, "interior block edit should apply")

		sample, sample_ok := chunk_store_block_get(interior_block).?
		log.assert(sample_ok, "edited interior block should be readable")
		log.assert(sample.occupancy == .Solid, "edited interior block should be solid")
		log.assert(
			sample.material_id == world_async.BlockMaterialID(5),
			"edited interior block material mismatch",
		)
		log.assert(left.mesh_state == .Dirty, "interior edit should dirty owning chunk")
		log.assert(.Blocks in left.dirty_flags, "interior edit should set Blocks dirty flag")
		log.assert(left.dirty_region.valid, "interior edit should create dirty region")
		log.assert(
			left.dirty_region.min == world_async.BlockCoord{0, 1, 2} &&
			left.dirty_region.max == world_async.BlockCoord{3, 4, 5},
			"interior edit dirty region mismatch",
		)
		interior_dirty_mask := chunk_dirty_region_subchunk_mask(left.dirty_region)
		log.assertf(
			interior_dirty_mask ==
			chunk_subchunk_mask_from_index(chunk_subchunk_index_from_coord(0, 0, 0)),
			"interior edit subchunk mask mismatch: %x",
			interior_dirty_mask,
		)
		log.assertf(
			left.subchunk_dirty_mask == CHUNK_SUBCHUNK_ALL_MASK,
			"first edit of full chunk should queue all subchunks for transition, got %x",
			left.subchunk_dirty_mask,
		)
		log.assert(
			left.block_storage.binary_greedy_row_cache != nil &&
			left.block_storage.binary_greedy_row_cache.block_version == left.block_version,
			"interior edit should keep binary row cache version current",
		)

		state.streaming_center_coord = {999, 0, 999}
		submitted := mesh_request_budgeted()
		log.assertf(submitted == 1, "expected one subchunk mesh job, got %d", submitted)
		queued_subchunk_index := left.queued_subchunk_index
		log.assertf(
			queued_subchunk_index == chunk_subchunk_index_from_coord(0, 0, 0),
			"expected first queued subchunk 0, got %d",
			queued_subchunk_index,
		)
		commit_stats := ChunkMeshBatchStats{}
		for attempt := 0; attempt < 1000 && commit_stats.chunks_committed == 0; attempt += 1 {
			commit_stats = mesh_results_poll_budgeted()
			if commit_stats.chunks_committed == 0 {
				time.sleep(time.Millisecond)
			}
		}
		log.assertf(
			commit_stats.chunks_committed == 1,
			"expected one committed subchunk result, got %d",
			commit_stats.chunks_committed,
		)
		log.assert(
			(left.subchunk_ready_mask & chunk_subchunk_mask_from_index(queued_subchunk_index)) !=
			0,
			"committed subchunk should be marked ready",
		)
		log.assert(
			left.geometry_id != INVALID_CHUNK_GEOMETRY_ID,
			"full chunk geometry should stay active until all subchunks are ready",
		)

		left.mesh_state = .Ready
		left.dirty_flags = {}
		chunk_dirty_region_clear(left)
		chunk_subchunk_geometry_release_all(left)
		right.mesh_state = .Ready
		right.dirty_flags = {}
		chunk_dirty_region_clear(right)

		boundary_block := world_async.BlockCoord{CHUNK_BLOCK_LOCAL_MAX, 2, 3}
		boundary_applied := chunk_store_block_edit_apply(
			boundary_block,
			.Solid,
			world_async.BlockMaterialID(6),
		)
		log.assert(boundary_applied, "boundary block edit should apply")
		log.assert(left.mesh_state == .Dirty, "boundary edit should dirty owning chunk")
		log.assert(right.mesh_state == .Dirty, "boundary edit should dirty neighboring chunk")
		log.assert(
			.Boundary in right.dirty_flags,
			"boundary edit should set neighbor Boundary flag",
		)
		log.assert(
			right.dirty_region.valid &&
			right.dirty_region.min == world_async.BlockCoord{0, 2, 3} &&
			right.dirty_region.max == world_async.BlockCoord{1, 3, 4},
			"neighbor boundary dirty region mismatch",
		)
		left_boundary_mask := chunk_dirty_region_subchunk_mask(left.dirty_region)
		right_boundary_mask := chunk_dirty_region_subchunk_mask(right.dirty_region)
		log.assertf(
			left_boundary_mask ==
			chunk_subchunk_mask_from_index(chunk_subchunk_index_from_coord(3, 0, 0)),
			"owner boundary edit subchunk mask mismatch: %x",
			left_boundary_mask,
		)
		log.assertf(
			right_boundary_mask ==
			chunk_subchunk_mask_from_index(chunk_subchunk_index_from_coord(0, 0, 0)),
			"neighbor boundary edit subchunk mask mismatch: %x",
			right_boundary_mask,
		)

		snapshot := chunk_snapshot_from_chunk(left)
		log.assert(snapshot.dirty_region.valid, "snapshot should carry dirty region")
		log.assert(
			snapshot.binary_greedy_row_cache != nil &&
			snapshot.binary_greedy_row_cache.block_version == snapshot.block_version,
			"snapshot should carry current binary row cache",
		)

		chunk_store_clear()
		streaming_reset()
		log.debug("Chunk edit contract checks passed")
	}
}
