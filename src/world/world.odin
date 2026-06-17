package world

import world_async "async:world"
import "core:log"
import math "core:math"
import bits "core:math/bits"
import "core:mem"
import mem_tlsf "core:mem/tlsf"
import "core:sync"
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

TerrainGenerationRegionCacheSlot :: struct {
	valid:     bool,
	key:       biomes.FeatureGridKey,
	coord:     biomes.GenerationRegionCoord,
	region:    biomes.GenerationRegion,
	last_used: u64,
}

TerrainGenerationRegionCache :: struct {
	mutex: sync.Mutex,
	slots: [TERRAIN_GENERATION_REGION_CACHE_CAPACITY]TerrainGenerationRegionCacheSlot,
	clock: u64,
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
	persistent_allocator:            mem.Allocator,
	chunk_block_storage_buffer:      []u8,
	chunk_block_storage_tlsf:        mem_tlsf.Allocator,
	chunk_block_storage_allocator:   mem.Allocator,
	chunk_mesh_row_cache_buffer:     []u8,
	chunk_mesh_row_cache_tlsf:       mem_tlsf.Allocator,
	chunk_mesh_row_cache_allocator:  mem.Allocator,

	// Callbacks
	generation_request:              GenerationRequestProc,
	generation_poll_results:         GenerationPollResultsProc,
	mesh_request:                    MeshRequestProc,
	mesh_poll_results:               MeshPollResultsProc,
	mesh_release_result:             MeshReleaseResultProc,
	chunk_mesh_upload:               ChunkMeshUploadProc,
	chunk_geometry_release:          ChunkGeometryReleaseProc,

	// Storage
	chunk_store:                     ChunkStore,

	// Streaming
	using streaming:                 StreamingState,
	terrain_generation_region_cache: TerrainGenerationRegionCache,

	// State
	initialized:                     bool,
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
	state.terrain_generation_region_cache = {}

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
CHUNK_BLOCK_STORAGE_POOL_BYTES :: 320 * mem.Megabyte
CHUNK_MESH_ROW_CACHE_POOL_BYTES :: 128 * mem.Megabyte

//////////////////////////////////////
// Streaming Budget Constants
/////////////////////////////////////

CHUNK_GENERATION_BUDGET_PER_FRAME :: 1
CHUNK_MESH_BUDGET_PER_FRAME :: 2

//////////////////////////////////////
// Streaming Constants
/////////////////////////////////////

CHUNK_STREAMING_RADIUS_XZ :: 3
CHUNK_STREAMING_NARROW_LAYER_RADIUS_XZ :: 2
CHUNK_STREAMING_RADIUS_Y_DOWN :: 2
CHUNK_STREAMING_RADIUS_Y_UP :: 1
CHUNK_UNLOAD_RADIUS_XZ :: CHUNK_STREAMING_RADIUS_XZ + 1
CHUNK_UNLOAD_RADIUS_Y_DOWN :: CHUNK_STREAMING_RADIUS_Y_DOWN
CHUNK_UNLOAD_RADIUS_Y_UP :: CHUNK_STREAMING_RADIUS_Y_UP
CHUNK_STREAMING_LAYER_COUNT :: CHUNK_STREAMING_RADIUS_Y_DOWN + CHUNK_STREAMING_RADIUS_Y_UP + 1
CHUNK_STREAMING_TARGET_CAPACITY ::
	(CHUNK_STREAMING_RADIUS_XZ * 2 + 1) *
	(CHUNK_STREAMING_RADIUS_XZ * 2 + 1) *
	CHUNK_STREAMING_LAYER_COUNT
CHUNK_UNLOAD_CAPACITY ::
	(CHUNK_UNLOAD_RADIUS_XZ * 2 + 1) *
	(CHUNK_UNLOAD_RADIUS_XZ * 2 + 1) *
	(CHUNK_UNLOAD_RADIUS_Y_DOWN + CHUNK_UNLOAD_RADIUS_Y_UP + 1)
#assert(CHUNK_UNLOAD_RADIUS_XZ >= CHUNK_STREAMING_RADIUS_XZ)
#assert(CHUNK_UNLOAD_RADIUS_Y_DOWN >= CHUNK_STREAMING_RADIUS_Y_DOWN)
#assert(CHUNK_UNLOAD_RADIUS_Y_UP >= CHUNK_STREAMING_RADIUS_Y_UP)

// Until chunk/geometry eviction exists, store capacity must stay within the fixed arenas.
CHUNK_STORE_CAPACITY :: 384
#assert(CHUNK_STREAMING_TARGET_CAPACITY > 0)
#assert(CHUNK_STORE_CAPACITY >= CHUNK_UNLOAD_CAPACITY)

TERRAIN_GENERATION_REGION_CACHE_CAPACITY :: 16

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
	solid_rows:              [TERRAIN_BINARY_AXIS_COUNT][TERRAIN_BINARY_AXIS_ROW_COUNT]u64,
	material_masks:          [TERRAIN_BINARY_AXIS_COUNT][TERRAIN_BINARY_AXIS_ROW_COUNT]u8,
	material_rows:           [TERRAIN_BINARY_AXIS_COUNT][TERRAIN_MATERIAL_PALETTE_COUNT][TERRAIN_BINARY_AXIS_ROW_COUNT]u64,
	hydrology_debug_rows:    [TERRAIN_BINARY_AXIS_COUNT][TERRAIN_BINARY_AXIS_ROW_COUNT]u64,
	cave_network_debug_rows: [TERRAIN_BINARY_AXIS_COUNT][TERRAIN_BINARY_AXIS_ROW_COUNT]u64,
	face_material_masks:     [CHUNK_BLOCK_LENGTH]u64,
	face_masks:              [CHUNK_BLOCK_LENGTH][TERRAIN_MATERIAL_FACE_VARIANT_COUNT][CHUNK_BLOCK_LENGTH]u64,
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
		mem.zero_slice(scratch.hydrology_debug_rows[axis][:])
		mem.zero_slice(scratch.cave_network_debug_rows[axis][:])
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

				material_id := view.blocks.material_id[block_index]
				material_idx := terrain_material_palette_index(
					view.blocks.material_id[block_index],
				)
				is_hydrology_debug :=
					(u8(material_id) & TERRAIN_HYDROLOGY_DEBUG_MATERIAL_FLAG) != 0
				is_cave_network_debug :=
					(u8(material_id) & TERRAIN_CAVE_NETWORK_DEBUG_MATERIAL_FLAG) != 0
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
				if is_hydrology_debug {
					scratch.hydrology_debug_rows[0][x_row] |= x_bit
					scratch.hydrology_debug_rows[1][y_row] |= y_bit
					scratch.hydrology_debug_rows[2][z_row] |= z_bit
				}
				if is_cave_network_debug {
					scratch.cave_network_debug_rows[0][x_row] |= x_bit
					scratch.cave_network_debug_rows[1][y_row] |= y_bit
					scratch.cave_network_debug_rows[2][z_row] |= z_bit
				}
				block_index += 1
			}
		}
	}
}

terrain_binary_debug_rows_build :: proc(
	scratch: ^TerrainBinaryGreedyScratch,
	view: world_async.ChunkVoxelView,
) {
	for axis := u32(0); axis < TERRAIN_BINARY_AXIS_COUNT; axis += 1 {
		mem.zero_slice(scratch.hydrology_debug_rows[axis][:])
		mem.zero_slice(scratch.cave_network_debug_rows[axis][:])
	}

	block_index: u32
	for z := u32(0); z < CHUNK_BLOCK_LENGTH; z += 1 {
		for y := u32(0); y < CHUNK_BLOCK_LENGTH; y += 1 {
			for x := u32(0); x < CHUNK_BLOCK_LENGTH; x += 1 {
				material_id := view.blocks.material_id[block_index]
				if view.blocks.occupancy[block_index] != .Solid {
					block_index += 1
					continue
				}

				x_row := y + z * CHUNK_BLOCK_LENGTH
				y_row := x + z * CHUNK_BLOCK_LENGTH
				z_row := x + y * CHUNK_BLOCK_LENGTH
				x_bit := u64(1) << x
				y_bit := u64(1) << y
				z_bit := u64(1) << z
				if (u8(material_id) & TERRAIN_HYDROLOGY_DEBUG_MATERIAL_FLAG) != 0 {
					scratch.hydrology_debug_rows[0][x_row] |= x_bit
					scratch.hydrology_debug_rows[1][y_row] |= y_bit
					scratch.hydrology_debug_rows[2][z_row] |= z_bit
				}
				if (u8(material_id) & TERRAIN_CAVE_NETWORK_DEBUG_MATERIAL_FLAG) != 0 {
					scratch.cave_network_debug_rows[0][x_row] |= x_bit
					scratch.cave_network_debug_rows[1][y_row] |= y_bit
					scratch.cave_network_debug_rows[2][z_row] |= z_bit
				}
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
			return true
		}

		return chunk_voxel_view_is_solid_local(neighbor_snapshot.voxel_view, x, y, z)
	}

	log.assertf(false, "unhandled chunk mesher boundary policy: %v", boundary_policy)
	return false
}

terrain_binary_face_mask_bits_add :: proc(
	scratch: ^TerrainBinaryGreedyScratch,
	material_idx, v, u: u32,
	face_bits: u64,
) {
	log.assertf(
		material_idx < TERRAIN_MATERIAL_FACE_VARIANT_COUNT,
		"face material index out of range: %d",
		material_idx,
	)
	remaining_bits := face_bits
	for remaining_bits != 0 {
		slice := u32(bits.trailing_zeros(remaining_bits))
		scratch.face_material_masks[slice] |= u64(1) << material_idx
		scratch.face_masks[slice][material_idx][v] |= u64(1) << u
		remaining_bits &~= u64(1) << slice
	}
}

terrain_binary_face_mask_debug_variants_add :: proc(
	scratch: ^TerrainBinaryGreedyScratch,
	axis, row_index, material_idx, v, u: u32,
	exposed_material_bits: u64,
) {
	hydrology_row := scratch.hydrology_debug_rows[axis][row_index]
	cave_network_row := scratch.cave_network_debug_rows[axis][row_index]
	for combo := u32(0); combo < TERRAIN_DEBUG_MATERIAL_FLAG_COMBO_COUNT; combo += 1 {
		variant_bits := exposed_material_bits
		if (combo & TERRAIN_DEBUG_MATERIAL_FLAG_COMBO_HYDROLOGY) != 0 {
			variant_bits &= hydrology_row
		} else {
			variant_bits &~= hydrology_row
		}
		if (combo & TERRAIN_DEBUG_MATERIAL_FLAG_COMBO_CAVE_NETWORK) != 0 {
			variant_bits &= cave_network_row
		} else {
			variant_bits &~= cave_network_row
		}
		if variant_bits == 0 {
			continue
		}

		debug_material_idx := material_idx | terrain_debug_material_flags_from_combo(combo)
		terrain_binary_face_mask_bits_add(scratch, debug_material_idx, v, u, variant_bits)
	}
}

terrain_binary_face_block_coord :: proc(axis, row_index, axis_coord: u32) -> (x, y, z: u32) {
	switch axis {
	case 0:
		return axis_coord, row_index % CHUNK_BLOCK_LENGTH, row_index / CHUNK_BLOCK_LENGTH
	case 1:
		return row_index % CHUNK_BLOCK_LENGTH, axis_coord, row_index / CHUNK_BLOCK_LENGTH
	case 2:
		return row_index % CHUNK_BLOCK_LENGTH, row_index / CHUNK_BLOCK_LENGTH, axis_coord
	}

	log.assertf(false, "unhandled binary greedy axis: %d", axis)
	return
}

terrain_binary_cave_face_material_index :: proc(normal_id, material_idx: u32) -> u32 {
	if material_idx == TERRAIN_AQUIFER_WALL_MAT_ID {
		if normal_id == 2 {
			return TERRAIN_WET_MARSH_MAT_ID
		}
		if normal_id == 3 {
			return TERRAIN_STONE_MAT_ID
		}
	}
	if material_idx == TERRAIN_CRYSTAL_MAT_ID && normal_id == 2 {
		return TERRAIN_STONE_MAT_ID
	}
	return material_idx
}

terrain_binary_shoreline_cap_face_material_index :: proc(
	view: world_async.ChunkVoxelView,
	neighbor_snapshots: Maybe(world_async.ChunkMeshNeighborSnapshots),
	normal_id, axis, row_index, axis_coord, material_idx: u32,
) -> u32 {
	if material_idx != TERRAIN_GRASS_MAT_ID || normal_id == 3 {
		return material_idx
	}

	x, y, z := terrain_binary_face_block_coord(axis, row_index, axis_coord)
	below_material_idx := material_idx
	if y > 0 {
		below_index := chunk_block_index(x, y - 1, z)
		if view.blocks.occupancy[below_index] != .Solid {
			return material_idx
		}
		below_material_idx = terrain_material_palette_index(view.blocks.material_id[below_index])
	} else {
		neighbors, neighbors_ok := neighbor_snapshots.?
		if !neighbors_ok {
			return material_idx
		}
		minus_y, minus_y_ok := neighbors.minus_y.?
		if !minus_y_ok {
			return material_idx
		}
		below_index := chunk_block_index(x, CHUNK_BLOCK_LOCAL_MAX, z)
		if minus_y.voxel_view.blocks.occupancy[below_index] != .Solid {
			return material_idx
		}
		below_material_idx = terrain_material_palette_index(
			minus_y.voxel_view.blocks.material_id[below_index],
		)
	}

	if below_material_idx == TERRAIN_WET_MARSH_MAT_ID {
		return below_material_idx
	}
	return material_idx
}

terrain_binary_face_mask_material_variants_add :: proc(
	scratch: ^TerrainBinaryGreedyScratch,
	view: world_async.ChunkVoxelView,
	neighbor_snapshots: Maybe(world_async.ChunkMeshNeighborSnapshots),
	normal_id, axis, row_index, material_idx, v, u: u32,
	exposed_material_bits: u64,
) {
	if exposed_material_bits == 0 {
		return
	}
	cave_material_idx := terrain_binary_cave_face_material_index(normal_id, material_idx)
	if cave_material_idx != material_idx {
		terrain_binary_face_mask_debug_variants_add(
			scratch,
			axis,
			row_index,
			cave_material_idx,
			v,
			u,
			exposed_material_bits,
		)
		return
	}
	if material_idx != TERRAIN_GRASS_MAT_ID || normal_id == 3 {
		terrain_binary_face_mask_debug_variants_add(
			scratch,
			axis,
			row_index,
			material_idx,
			v,
			u,
			exposed_material_bits,
		)
		return
	}

	if normal_id == 2 && axis == 1 {
		wet_below_bits :=
			(scratch.material_rows[1][TERRAIN_WET_MARSH_MAT_ID][row_index] << 1) &
			exposed_material_bits
		if wet_below_bits == 0 {
			terrain_binary_face_mask_debug_variants_add(
				scratch,
				axis,
				row_index,
				material_idx,
				v,
				u,
				exposed_material_bits,
			)
			return
		}
		grass_bits := exposed_material_bits & ~wet_below_bits
		terrain_binary_face_mask_debug_variants_add(
			scratch,
			axis,
			row_index,
			material_idx,
			v,
			u,
			grass_bits,
		)
		terrain_binary_face_mask_debug_variants_add(
			scratch,
			axis,
			row_index,
			TERRAIN_WET_MARSH_MAT_ID,
			v,
			u,
			wet_below_bits,
		)
		return
	}

	remaining_bits := exposed_material_bits
	for remaining_bits != 0 {
		axis_coord := u32(bits.trailing_zeros(remaining_bits))
		face_bit := u64(1) << axis_coord
		face_material_idx := terrain_binary_shoreline_cap_face_material_index(
			view,
			neighbor_snapshots,
			normal_id,
			axis,
			row_index,
			axis_coord,
			material_idx,
		)
		terrain_binary_face_mask_debug_variants_add(
			scratch,
			axis,
			row_index,
			face_material_idx,
			v,
			u,
			face_bit,
		)
		remaining_bits &~= face_bit
	}
}

terrain_binary_face_masks_build :: proc(
	scratch: ^TerrainBinaryGreedyScratch,
	view: world_async.ChunkVoxelView,
	normal_id: u32,
	boundary_policy: world_async.ChunkMeshBoundaryPolicy,
	neighbor_snapshots: Maybe(world_async.ChunkMeshNeighborSnapshots) = nil,
) {
	mem.zero_slice(scratch.face_material_masks[:])
	for slice := u32(0); slice < CHUNK_BLOCK_LENGTH; slice += 1 {
		for material_idx := u32(0);
		    material_idx < TERRAIN_MATERIAL_FACE_VARIANT_COUNT;
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
				terrain_binary_face_mask_material_variants_add(
					scratch,
					view,
					neighbor_snapshots,
					normal_id,
					axis,
					row_index,
					material_idx,
					v,
					u,
					exposed_material_bits,
				)
				material_mask &~= u32(1) << material_idx
			}
		}
	}
}

terrain_binary_face_masks_build_from_cache :: proc(
	scratch: ^TerrainBinaryGreedyScratch,
	cache: ^world_async.ChunkBinaryGreedyRowCache,
	view: world_async.ChunkVoxelView,
	normal_id: u32,
	boundary_policy: world_async.ChunkMeshBoundaryPolicy,
	neighbor_snapshots: Maybe(world_async.ChunkMeshNeighborSnapshots) = nil,
) {
	mem.zero_slice(scratch.face_material_masks[:])
	for slice := u32(0); slice < CHUNK_BLOCK_LENGTH; slice += 1 {
		for material_idx := u32(0);
		    material_idx < TERRAIN_MATERIAL_FACE_VARIANT_COUNT;
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
				terrain_binary_face_mask_material_variants_add(
					scratch,
					view,
					neighbor_snapshots,
					normal_id,
					axis,
					row_index,
					material_idx,
					v,
					u,
					exposed_material_bits,
				)
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
		material_mask := scratch.face_material_masks[slice]
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
			material_mask &~= u64(1) << material_idx
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
		material_mask := scratch.face_material_masks[slice]
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
			material_mask &~= u64(1) << material_idx
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
		terrain_binary_face_masks_build(
			scratch,
			view,
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
		terrain_binary_face_masks_build(
			scratch,
			view,
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
		terrain_binary_face_masks_build(
			scratch,
			view,
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
		terrain_binary_face_masks_build(
			scratch,
			view,
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
		terrain_binary_face_masks_build(
			scratch,
			view,
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

chunk_binary_row_cache_build_binary_greedy_mesh :: proc(
	cache: ^world_async.ChunkBinaryGreedyRowCache,
	view: world_async.ChunkVoxelView,
	boundary_policy: world_async.ChunkMeshBoundaryPolicy,
	allocator: mem.Allocator,
	scratch: ^TerrainBinaryGreedyScratch,
	neighbor_snapshots: Maybe(world_async.ChunkMeshNeighborSnapshots) = nil,
) -> world_async.ChunkMeshOutput {
	terrain_binary_debug_rows_build(scratch, view)
	vertices: []world_async.TerrainPackedVertex
	indices: []u32
	face_count: u32
	for normal_id := u32(0); normal_id < 6; normal_id += 1 {
		terrain_binary_face_masks_build_from_cache(
			scratch,
			cache,
			view,
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
			view,
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
	view: world_async.ChunkVoxelView,
	min_bound, max_bound: world_async.BlockCoord,
	boundary_policy: world_async.ChunkMeshBoundaryPolicy,
	scratch: ^TerrainBinaryGreedyScratch,
	neighbor_snapshots: Maybe(world_async.ChunkMeshNeighborSnapshots) = nil,
) -> u32 {
	terrain_binary_debug_rows_build(scratch, view)
	vertices: []world_async.TerrainPackedVertex
	indices: []u32
	face_count: u32
	for normal_id := u32(0); normal_id < 6; normal_id += 1 {
		terrain_binary_face_masks_build_from_cache(
			scratch,
			cache,
			view,
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
	view: world_async.ChunkVoxelView,
	min_bound, max_bound: world_async.BlockCoord,
	boundary_policy: world_async.ChunkMeshBoundaryPolicy,
	allocator: mem.Allocator,
	scratch: ^TerrainBinaryGreedyScratch,
	neighbor_snapshots: Maybe(world_async.ChunkMeshNeighborSnapshots) = nil,
) -> world_async.ChunkMeshOutput {
	face_count := chunk_binary_row_cache_count_binary_greedy_faces_in_bounds(
		cache,
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

	face_cursor: u32
	for normal_id := u32(0); normal_id < 6; normal_id += 1 {
		terrain_binary_face_masks_build_from_cache(
			scratch,
			cache,
			view,
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
			snapshot.voxel_view,
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
			snapshot.voxel_view,
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
		   !streaming_coord_inside_window(state.streaming_center_coord, chunk.coord, 0) {
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

streaming_layer_radius_xz_from_dy :: proc(dy: i32) -> i32 {
	if dy == 0 || dy == -1 {
		return i32(CHUNK_STREAMING_RADIUS_XZ)
	}
	return i32(CHUNK_STREAMING_NARROW_LAYER_RADIUS_XZ)
}

streaming_coord_inside_window :: proc(
	center, coord: world_async.ChunkCoord,
	unload_padding: i32,
) -> bool {
	dx := coord.x - center.x
	dy := coord.y - center.y
	dz := coord.z - center.z
	if dy < -i32(CHUNK_STREAMING_RADIUS_Y_DOWN) || dy > i32(CHUNK_STREAMING_RADIUS_Y_UP) {
		return false
	}
	radius := streaming_layer_radius_xz_from_dy(dy) + unload_padding
	return abs(dx) <= radius && abs(dz) <= radius
}

streaming_target_less :: proc(center, a, b: world_async.ChunkCoord) -> bool {
	adx := a.x - center.x
	ady := a.y - center.y
	adz := a.z - center.z
	bdx := b.x - center.x
	bdy := b.y - center.y
	bdz := b.z - center.z

	if abs(ady) != abs(bdy) {return abs(ady) < abs(bdy)}
	ad := adx * adx + adz * adz
	bd := bdx * bdx + bdz * bdz
	if ad != bd {return ad < bd}
	if a.y != b.y {return a.y < b.y}
	if a.z != b.z {return a.z < b.z}
	return a.x < b.x
}

streaming_evict_outside_unload_radius :: proc() -> u32 {
	evicted_count: u32
	for i := u32(0); i < state.chunk_store.chunk_count; {
		chunk := chunk_store_get_by_index(i)
		if streaming_coord_inside_window(state.streaming_center_coord, chunk.coord, 1) {
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
	if !streaming_coord_inside_window(state.streaming_center_coord, coord, 0) {
		return true
	}
	return chunk_store_coord_is_generated(coord)
}

streaming_mesh_dependencies_ready :: proc(coord: world_async.ChunkCoord) -> bool {
	if !streaming_mesh_dependency_ready(world_async.ChunkCoord{coord.x + 1, coord.y, coord.z}) ||
	   !streaming_mesh_dependency_ready(world_async.ChunkCoord{coord.x - 1, coord.y, coord.z}) ||
	   !streaming_mesh_dependency_ready(world_async.ChunkCoord{coord.x, coord.y, coord.z + 1}) ||
	   !streaming_mesh_dependency_ready(world_async.ChunkCoord{coord.x, coord.y, coord.z - 1}) {
		return false
	}

	if coord.y < state.streaming_center_coord.y &&
	   !streaming_mesh_dependency_ready(world_async.ChunkCoord{coord.x, coord.y + 1, coord.z}) {
		return false
	}
	if coord.y > state.streaming_center_coord.y &&
	   !streaming_mesh_dependency_ready(world_async.ChunkCoord{coord.x, coord.y - 1, coord.z}) {
		return false
	}
	return true
}

streaming_window_rebuild_targets :: proc(center: world_async.ChunkCoord) {
	state.streaming_center_coord = center
	state.streaming_target_count = 0

	for dy := -i32(CHUNK_STREAMING_RADIUS_Y_DOWN);
	    dy <= i32(CHUNK_STREAMING_RADIUS_Y_UP);
	    dy += 1 {
		radius := streaming_layer_radius_xz_from_dy(dy)
		for dz := -radius; dz <= radius; dz += 1 {
			for dx := -radius; dx <= radius; dx += 1 {
				state.streaming_targets[state.streaming_target_count] = {
					center.x + dx,
					center.y + dy,
					center.z + dz,
				}
				state.streaming_target_count += 1
			}
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
TERRAIN_WET_MARSH_MAT_ID :: 3
TERRAIN_WATER_MAT_ID :: 4
TERRAIN_CORRUPTED_ASH_MAT_ID :: 5
TERRAIN_AQUIFER_WALL_MAT_ID :: 6
TERRAIN_CRYSTAL_MAT_ID :: 7
TERRAIN_HYDROLOGY_DEBUG_MATERIAL_FLAG :: u8(0x08)
TERRAIN_CAVE_NETWORK_DEBUG_MATERIAL_FLAG :: u8(0x10)
TERRAIN_DEBUG_MATERIAL_FLAG_COMBO_HYDROLOGY :: u32(0x1)
TERRAIN_DEBUG_MATERIAL_FLAG_COMBO_CAVE_NETWORK :: u32(0x2)
TERRAIN_DEBUG_MATERIAL_FLAG_COMBO_COUNT :: u32(4)
TERRAIN_MATERIAL_PALETTE_COUNT :: 8
TERRAIN_MATERIAL_FACE_VARIANT_COUNT :: 32
#assert(TERRAIN_MATERIAL_PALETTE_COUNT == 8)
#assert(TERRAIN_MATERIAL_PALETTE_COUNT == world_async.TERRAIN_MATERIAL_PALETTE_COUNT)
#assert(TERRAIN_MATERIAL_FACE_VARIANT_COUNT == 32)
TERRAIN_GENERATOR_VERSION :: u32(2)
TERRAIN_GRASS_CAP_BLOCK_DEPTH :: 4
TERRAIN_DIRT_LAYER_BLOCK_DEPTH :: 4
TERRAIN_SURFACE_MATERIAL_BLEND_SALT :: u64(0x475c91d2e03af86b)
TERRAIN_SHORE_MATERIAL_BLEND_SALT :: u64(0xa65f9d2c8b7140e3)
TERRAIN_SHORE_MATERIAL_DITHER_AMPLITUDE :: f32(0.25)
TERRAIN_SHORE_CAP_THIN_BAND_FRACTION :: f32(0.56)
TERRAIN_LOCAL_WATER_FILL_INFLUENCE_MIN :: f32(0.30)
#assert(TERRAIN_SHORE_MATERIAL_DITHER_AMPLITUDE >= 0)
#assert(TERRAIN_SHORE_MATERIAL_DITHER_AMPLITUDE <= 0.35)
#assert(TERRAIN_SHORE_CAP_THIN_BAND_FRACTION > 0)
#assert(TERRAIN_SHORE_CAP_THIN_BAND_FRACTION <= 1)
#assert(TERRAIN_LOCAL_WATER_FILL_INFLUENCE_MIN > 0)
#assert(TERRAIN_LOCAL_WATER_FILL_INFLUENCE_MIN < 0.35)
TERRAIN_CAVE_ROUGHNESS_SALT :: u64(0x96b17e2d4c5f803a)
TERRAIN_CAVE_DETAIL_SALT :: u64(0x2f68a915c7d34e0b)
TERRAIN_CAVE_FIELD_SPAGHETTI_A_SALT :: u64(0x5b8124f7c90e63da)
TERRAIN_CAVE_FIELD_SPAGHETTI_B_SALT :: u64(0x91c4ad6e2f58b037)
TERRAIN_CAVE_FIELD_CHAMBER_SALT :: u64(0x3e74b6c15a9280fd)
TERRAIN_CAVE_FIELD_DETAIL_SALT :: u64(0xce58f10ab739462d)
TERRAIN_CAVE_VERTICAL_CUSHION_SALT :: u64(0x7a1df4836bc905e2)
TERRAIN_CAVE_ROOM_DETAIL_SALT :: u64(0x29f6c14a87b35d02)
TERRAIN_CAVE_PASSAGE_RIB_SALT :: u64(0x83d14f70ca56e92b)
TERRAIN_CAVE_BRANCH_SALT :: u64(0xf2306de74a9c58b1)
TERRAIN_CAVE_CURVE_SALT :: u64(0x4d9b7a52e168c03f)
TERRAIN_BAKE_DEBUG_MATERIAL_FLAGS :: #config(TERRAIN_BAKE_DEBUG_MATERIAL_FLAGS, false)
TERRAIN_SURFACE_HEIGHT_TOP_SOFT_START_BLOCKS :: f32(94)
TERRAIN_SURFACE_HEIGHT_TOP_LIMIT_BLOCKS :: f32(118)
TERRAIN_SURFACE_HEIGHT_BOTTOM_SOFT_START_BLOCKS :: f32(-78)
TERRAIN_SURFACE_HEIGHT_BOTTOM_LIMIT_BLOCKS :: f32(-116)
TERRAIN_CAVE_BOTTOM_CUSHION_START_BLOCKS :: f32(-124)
TERRAIN_CAVE_BOTTOM_CUSHION_END_BLOCKS :: f32(-100)
TERRAIN_CAVE_TOP_CUSHION_START_BLOCKS :: f32(106)
TERRAIN_CAVE_TOP_CUSHION_END_BLOCKS :: f32(126)
TERRAIN_CAVE_FIELD_SAMPLE_STEP_BLOCKS :: i32(12)
TERRAIN_CAVE_FIELD_STAMP_CAPACITY_PER_CHUNK :: u32(18)
TERRAIN_CAVE_FIELD_PATH_STAMP_RESERVE_PER_CHUNK :: u32(3)
TERRAIN_CAVE_FIELD_OPEN_STRENGTH_MIN :: f32(0.54)
TERRAIN_CAVE_FIELD_PATH_OPEN_STRENGTH_MIN :: f32(0.30)
TERRAIN_CAVE_FIELD_PATH_LONG_AXIS_SCALE :: f32(1.28)
TERRAIN_CAVE_FIELD_PATH_CROSS_AXIS_SCALE :: f32(0.78)
TERRAIN_CAVE_FIELD_PATH_Y_SCALE :: f32(0.54)
TERRAIN_CAVE_FIELD_PATH_SEGMENT_RADIUS_SCALE :: f32(0.62)
TERRAIN_CAVE_FIELD_PATH_SEGMENT_HALF_LENGTH_SCALE :: f32(1.24)
TERRAIN_CAVE_FIELD_PATH_ROUTE_VERTICAL_SCALE :: f32(0.55)
TERRAIN_CAVE_FIELD_PATH_SELECTION_BIAS :: f32(1.18)
TERRAIN_CAVE_FIELD_ROUTE_PATH_OPEN_STRENGTH_MIN :: f32(0.22)
TERRAIN_CAVE_FIELD_ROUTE_PATH_DISTANCE_MARGIN_BLOCKS :: f32(6)
TERRAIN_CAVE_FIELD_ROUTE_POCKET_DISTANCE_MARGIN_BLOCKS :: f32(16)
TERRAIN_CAVE_FIELD_ROUTE_POCKET_ROOM_SCALE :: f32(0.64)
TERRAIN_CAVE_FIELD_ROUTE_POCKET_THROAT_RADIUS_SCALE :: f32(0.46)
TERRAIN_CAVE_FIELD_CHAMBER_XZ_SCALE :: f32(1.12)
TERRAIN_CAVE_FIELD_CHAMBER_Y_MIN_SCALE :: f32(0.62)
TERRAIN_CAVE_FIELD_CHAMBER_Y_MAX_SCALE :: f32(1.08)
TERRAIN_CAVE_FIELD_NETWORK_CONNECTED_MARGIN_BLOCKS :: f32(8)
TERRAIN_CAVE_FIELD_NETWORK_PATH_MARGIN_BLOCKS :: f32(14)
TERRAIN_CAVE_FIELD_NETWORK_BRIDGE_MARGIN_BLOCKS :: f32(34)
TERRAIN_CAVE_FIELD_NETWORK_BRIDGE_MIN_RADIUS :: f32(6)
TERRAIN_CAVE_FIELD_NETWORK_BRIDGE_RADIUS_SCALE :: f32(0.42)
TERRAIN_CAVE_NODE_ISOLATED_CULL_RADIUS_BLOCKS :: f32(14)
TERRAIN_CAVE_NODE_BRIDGE_MAX_DISTANCE_BLOCKS :: f32(150)
TERRAIN_CAVE_NODE_BRIDGE_RADIUS_SCALE :: f32(0.36)
TERRAIN_CAVE_NODE_PROFILE_ROOM_MIN_RADIUS_BLOCKS :: f32(9)
TERRAIN_CAVE_NODE_PROFILE_ROOM_MINOR_SCALE :: f32(0.72)
TERRAIN_CAVE_NODE_PROFILE_ROOM_MAJOR_MAX_XZ :: f32(18)
TERRAIN_CAVE_NODE_PROFILE_ROOM_MAJOR_MAX_Y :: f32(14)
TERRAIN_CAVE_NODE_PROFILE_ROOM_MINOR_MAX_XZ :: f32(13)
TERRAIN_CAVE_NODE_PROFILE_ROOM_MINOR_MAX_Y :: f32(10)
TERRAIN_CAVE_MOUTH_LOWER_WIDTH_BOOST :: f32(0.30)
TERRAIN_CAVE_MOUTH_SIDE_SHOULDER_START :: f32(0.34)
TERRAIN_CAVE_MOUTH_SIDE_SHOULDER_INV_RANGE :: f32(1.852)
TERRAIN_CAVE_MOUTH_SIDE_SHOULDER_STRENGTH :: f32(0.36)
TERRAIN_CAVE_MOUTH_CENTER_RELIEF_STRENGTH :: f32(0.14)
TERRAIN_CAVE_MOUTH_LOWER_JAW_RELIEF_STRENGTH :: f32(0.10)
TERRAIN_CAVE_MOUTH_UPPER_LIP_RIB_STRENGTH :: f32(0.08)
TERRAIN_CAVE_MOUTH_SIDE_ALCOVE_RELIEF_STRENGTH :: f32(0.13)
TERRAIN_CAVE_MOUTH_SIDE_ALCOVE_SMALL_SCALE :: f32(0.50)
TERRAIN_CAVE_MOUTH_SIDE_ALCOVE_LARGE_SCALE :: f32(1.36)
TERRAIN_CAVE_MOUTH_SMALL_RADIUS_BLOCKS :: f32(7.0)
TERRAIN_CAVE_MOUTH_LARGE_RADIUS_BLOCKS :: f32(12.0)
TERRAIN_CAVE_MOUTH_SMALL_REACH_SCALE :: f32(1.55)
TERRAIN_CAVE_MOUTH_LARGE_REACH_SCALE :: f32(2.35)
TERRAIN_CAVE_MOUTH_SMALL_WIDTH_SCALE :: f32(0.86)
TERRAIN_CAVE_MOUTH_LARGE_WIDTH_SCALE :: f32(1.18)
TERRAIN_CAVE_MOUTH_TRANSITION_RUN_SCALE :: f32(2.25)
TERRAIN_CAVE_MOUTH_TRANSITION_DROP_SCALE :: f32(1.45)
TERRAIN_CAVE_MOUTH_TRANSITION_SIDE_SCALE :: f32(0.55)
TERRAIN_CAVE_MOUTH_SMALL_SLOPED_BEND_EXTENSION_SCALE :: f32(0.95)
TERRAIN_CAVE_MOUTH_SLOPED_BEND_EXTENSION_SCALE :: f32(0.12)
TERRAIN_CAVE_MOUTH_CURVED_BEND_EXTENSION_SCALE :: f32(0.42)
TERRAIN_CAVE_MOUTH_SPIRAL_BEND_EXTENSION_SCALE :: f32(0.46)
TERRAIN_CAVE_MOUTH_VESTIBULE_MIN_SUPPORT :: f32(0.25)
TERRAIN_SINKHOLE_SIDE_LEDGE_RELIEF_STRENGTH :: f32(0.13)
TERRAIN_SINKHOLE_RIM_LIP_STRENGTH :: f32(0.08)
TERRAIN_SINKHOLE_SPIRAL_OFFSET_SCALE :: f32(0.42)
TERRAIN_CAVE_ROUGH_ELLIPSOID_EDGE_SCALE :: f32(0.24)
TERRAIN_CAVE_ROUGH_ELLIPSOID_CORE_SCALE :: f32(0.08)
TERRAIN_CAVE_ROOM_LOBE_SWELL_SCALE :: f32(0.08)
TERRAIN_CAVE_ROOM_LOBE_BACK_SWELL_SCALE :: f32(0.04)
TERRAIN_CAVE_ROOM_SIDE_NOTCH_SCALE :: f32(0.30)
TERRAIN_CAVE_ROOM_CEILING_RIB_SCALE :: f32(0.14)
TERRAIN_CAVE_ROOM_COORD_WARP_SCALE :: f32(0.22)
TERRAIN_CAVE_ROOM_VERTICAL_WARP_SCALE :: f32(0.10)
TERRAIN_CAVE_ROOM_SCALLOP_SCALE :: f32(0.12)
TERRAIN_CAVE_ROOM_INTERNAL_STRUCTURE_MIN_RADIUS :: f32(4.5)
#assert(TERRAIN_CAVE_MOUTH_LOWER_WIDTH_BOOST > 0.22)
#assert(TERRAIN_CAVE_MOUTH_SIDE_SHOULDER_START < 0.38)
#assert(TERRAIN_CAVE_MOUTH_CENTER_RELIEF_STRENGTH < 0.18)
#assert(TERRAIN_CAVE_MOUTH_LOWER_JAW_RELIEF_STRENGTH < TERRAIN_CAVE_MOUTH_SIDE_SHOULDER_STRENGTH)
#assert(TERRAIN_CAVE_MOUTH_UPPER_LIP_RIB_STRENGTH < TERRAIN_CAVE_MOUTH_CENTER_RELIEF_STRENGTH)
#assert(TERRAIN_CAVE_MOUTH_SIDE_ALCOVE_RELIEF_STRENGTH < TERRAIN_CAVE_MOUTH_SIDE_SHOULDER_STRENGTH)
#assert(TERRAIN_CAVE_MOUTH_SIDE_ALCOVE_SMALL_SCALE < 1.0)
#assert(TERRAIN_CAVE_MOUTH_SIDE_ALCOVE_LARGE_SCALE > 1.0)
#assert(TERRAIN_CAVE_MOUTH_SMALL_REACH_SCALE < TERRAIN_CAVE_MOUTH_LARGE_REACH_SCALE)
#assert(TERRAIN_CAVE_MOUTH_SMALL_WIDTH_SCALE < TERRAIN_CAVE_MOUTH_LARGE_WIDTH_SCALE)
#assert(
	TERRAIN_CAVE_MOUTH_SLOPED_BEND_EXTENSION_SCALE <
	TERRAIN_CAVE_MOUTH_SMALL_SLOPED_BEND_EXTENSION_SCALE,
)
#assert(
	TERRAIN_CAVE_MOUTH_SLOPED_BEND_EXTENSION_SCALE <
	TERRAIN_CAVE_MOUTH_CURVED_BEND_EXTENSION_SCALE,
)
#assert(
	TERRAIN_CAVE_MOUTH_CURVED_BEND_EXTENSION_SCALE <
	TERRAIN_CAVE_MOUTH_SPIRAL_BEND_EXTENSION_SCALE,
)
#assert(TERRAIN_CAVE_MOUTH_VESTIBULE_MIN_SUPPORT > 0)
#assert(TERRAIN_SINKHOLE_SIDE_LEDGE_RELIEF_STRENGTH > TERRAIN_SINKHOLE_RIM_LIP_STRENGTH)
#assert(TERRAIN_SINKHOLE_SIDE_LEDGE_RELIEF_STRENGTH < 0.14)
#assert(TERRAIN_SINKHOLE_SPIRAL_OFFSET_SCALE < 0.5)
#assert(TERRAIN_CAVE_ROUGH_ELLIPSOID_EDGE_SCALE > TERRAIN_CAVE_ROUGH_ELLIPSOID_CORE_SCALE)
#assert(TERRAIN_CAVE_ROUGH_ELLIPSOID_EDGE_SCALE < 0.35)
#assert(TERRAIN_CAVE_ROOM_SIDE_NOTCH_SCALE > TERRAIN_CAVE_ROOM_LOBE_SWELL_SCALE)
#assert(TERRAIN_CAVE_ROOM_CEILING_RIB_SCALE < TERRAIN_CAVE_ROOM_SIDE_NOTCH_SCALE)
#assert(TERRAIN_CAVE_ROOM_COORD_WARP_SCALE < TERRAIN_CAVE_ROOM_SIDE_NOTCH_SCALE)
#assert(TERRAIN_CAVE_ROOM_VERTICAL_WARP_SCALE < TERRAIN_CAVE_ROOM_COORD_WARP_SCALE)
#assert(TERRAIN_CAVE_ROOM_SCALLOP_SCALE < TERRAIN_CAVE_ROOM_COORD_WARP_SCALE)
#assert(TERRAIN_CAVE_ROOM_INTERNAL_STRUCTURE_MIN_RADIUS > 3)
#assert(TERRAIN_CAVE_FIELD_PATH_STAMP_RESERVE_PER_CHUNK > 0)
#assert(
	TERRAIN_CAVE_FIELD_PATH_STAMP_RESERVE_PER_CHUNK < TERRAIN_CAVE_FIELD_STAMP_CAPACITY_PER_CHUNK,
)
#assert(TERRAIN_CAVE_FIELD_PATH_LONG_AXIS_SCALE > TERRAIN_CAVE_FIELD_CHAMBER_XZ_SCALE)
#assert(TERRAIN_CAVE_FIELD_PATH_CROSS_AXIS_SCALE < TERRAIN_CAVE_FIELD_CHAMBER_XZ_SCALE)
#assert(TERRAIN_CAVE_FIELD_PATH_Y_SCALE < TERRAIN_CAVE_FIELD_CHAMBER_Y_MIN_SCALE)
#assert(TERRAIN_CAVE_FIELD_PATH_SEGMENT_RADIUS_SCALE < TERRAIN_CAVE_FIELD_PATH_CROSS_AXIS_SCALE)
#assert(
	TERRAIN_CAVE_FIELD_PATH_SEGMENT_HALF_LENGTH_SCALE < TERRAIN_CAVE_FIELD_PATH_LONG_AXIS_SCALE,
)
#assert(TERRAIN_CAVE_FIELD_PATH_ROUTE_VERTICAL_SCALE > 0)
#assert(TERRAIN_CAVE_FIELD_PATH_ROUTE_VERTICAL_SCALE < 0.75)
#assert(TERRAIN_CAVE_FIELD_PATH_SELECTION_BIAS > 1.0)
#assert(TERRAIN_CAVE_FIELD_PATH_SELECTION_BIAS < 1.35)
#assert(TERRAIN_CAVE_FIELD_PATH_OPEN_STRENGTH_MIN < TERRAIN_CAVE_FIELD_OPEN_STRENGTH_MIN)
#assert(TERRAIN_CAVE_FIELD_PATH_OPEN_STRENGTH_MIN > 0.25)
#assert(
	TERRAIN_CAVE_FIELD_ROUTE_PATH_OPEN_STRENGTH_MIN < TERRAIN_CAVE_FIELD_PATH_OPEN_STRENGTH_MIN,
)
#assert(TERRAIN_CAVE_FIELD_ROUTE_PATH_OPEN_STRENGTH_MIN > 0.15)
#assert(
	TERRAIN_CAVE_FIELD_ROUTE_PATH_DISTANCE_MARGIN_BLOCKS <
	TERRAIN_CAVE_FIELD_NETWORK_CONNECTED_MARGIN_BLOCKS,
)
#assert(
	TERRAIN_CAVE_FIELD_ROUTE_POCKET_DISTANCE_MARGIN_BLOCKS >
	TERRAIN_CAVE_FIELD_ROUTE_PATH_DISTANCE_MARGIN_BLOCKS,
)
#assert(
	TERRAIN_CAVE_FIELD_ROUTE_POCKET_DISTANCE_MARGIN_BLOCKS <
	TERRAIN_CAVE_FIELD_NETWORK_BRIDGE_MARGIN_BLOCKS,
)
#assert(TERRAIN_CAVE_FIELD_ROUTE_POCKET_ROOM_SCALE > 0.5)
#assert(TERRAIN_CAVE_FIELD_ROUTE_POCKET_ROOM_SCALE < 0.8)
#assert(TERRAIN_CAVE_FIELD_ROUTE_POCKET_THROAT_RADIUS_SCALE > 0.3)
#assert(TERRAIN_CAVE_FIELD_ROUTE_POCKET_THROAT_RADIUS_SCALE < 0.6)
#assert(
	TERRAIN_CAVE_FIELD_NETWORK_CONNECTED_MARGIN_BLOCKS <
	TERRAIN_CAVE_FIELD_NETWORK_BRIDGE_MARGIN_BLOCKS,
)
#assert(
	TERRAIN_CAVE_FIELD_NETWORK_PATH_MARGIN_BLOCKS <
	TERRAIN_CAVE_FIELD_NETWORK_BRIDGE_MARGIN_BLOCKS,
)
#assert(TERRAIN_CAVE_FIELD_NETWORK_BRIDGE_RADIUS_SCALE < 0.5)
#assert(
	TERRAIN_CAVE_NODE_ISOLATED_CULL_RADIUS_BLOCKS > TERRAIN_CAVE_FIELD_NETWORK_BRIDGE_MIN_RADIUS,
)
#assert(TERRAIN_CAVE_NODE_BRIDGE_RADIUS_SCALE < 0.5)
#assert(
	TERRAIN_CAVE_NODE_PROFILE_ROOM_MIN_RADIUS_BLOCKS >
	TERRAIN_CAVE_FIELD_NETWORK_BRIDGE_MIN_RADIUS,
)
#assert(TERRAIN_CAVE_NODE_PROFILE_ROOM_MINOR_SCALE < 1)
#assert(TERRAIN_CAVE_NODE_PROFILE_ROOM_MINOR_MAX_XZ < TERRAIN_CAVE_NODE_PROFILE_ROOM_MAJOR_MAX_XZ)
#assert(TERRAIN_CAVE_NODE_PROFILE_ROOM_MINOR_MAX_Y < TERRAIN_CAVE_NODE_PROFILE_ROOM_MAJOR_MAX_Y)
TERRAIN_FUNGAL_ROOM_LOWER_XZ_SCALE :: f32(1.12)
TERRAIN_FUNGAL_ROOM_LOWER_Y_SCALE :: f32(0.58)
TERRAIN_FUNGAL_ROOM_LOWER_Y_OFFSET_SCALE :: f32(-0.10)
TERRAIN_FUNGAL_ROOM_DOME_XZ_SCALE :: f32(0.78)
TERRAIN_FUNGAL_ROOM_DOME_Y_SCALE :: f32(0.68)
TERRAIN_FUNGAL_ROOM_DOME_Y_OFFSET_SCALE :: f32(0.42)
TERRAIN_FUNGAL_ROOM_ALCOVE_OFFSET_SCALE :: f32(0.62)
TERRAIN_FUNGAL_ROOM_ALCOVE_XZ_SCALE :: f32(0.44)
TERRAIN_FUNGAL_ROOM_ALCOVE_Y_SCALE :: f32(0.36)
TERRAIN_FUNGAL_ROOM_ALCOVE_Y_OFFSET_SCALE :: f32(0.02)
#assert(TERRAIN_FUNGAL_ROOM_LOWER_XZ_SCALE > 1)
#assert(TERRAIN_FUNGAL_ROOM_LOWER_Y_SCALE < TERRAIN_FUNGAL_ROOM_DOME_Y_SCALE)
#assert(TERRAIN_FUNGAL_ROOM_ALCOVE_OFFSET_SCALE > 0.5)
TERRAIN_CRYSTAL_ROOM_MAIN_XZ_SCALE :: f32(0.72)
TERRAIN_CRYSTAL_ROOM_MAIN_Y_SCALE :: f32(1.12)
TERRAIN_CRYSTAL_ROOM_FISSURE_RADIUS_SCALE :: f32(0.30)
TERRAIN_CRYSTAL_ROOM_FISSURE_LOWER_Y_SCALE :: f32(0.26)
TERRAIN_CRYSTAL_ROOM_FISSURE_UPPER_Y_SCALE :: f32(0.34)
#assert(TERRAIN_CRYSTAL_ROOM_MAIN_XZ_SCALE < 1)
#assert(TERRAIN_CRYSTAL_ROOM_MAIN_Y_SCALE > 1)
#assert(TERRAIN_CRYSTAL_ROOM_FISSURE_RADIUS_SCALE > 0)
TERRAIN_AQUIFER_ROOM_BASIN_XZ_SCALE :: f32(1.10)
TERRAIN_AQUIFER_ROOM_BASIN_Y_SCALE :: f32(0.38)
TERRAIN_AQUIFER_ROOM_BASIN_Y_OFFSET_SCALE :: f32(-0.22)
TERRAIN_AQUIFER_ROOM_SHELF_OFFSET_SCALE :: f32(0.42)
TERRAIN_AQUIFER_ROOM_SHELF_XZ_SCALE :: f32(0.66)
TERRAIN_AQUIFER_ROOM_SHELF_Y_SCALE :: f32(0.36)
TERRAIN_AQUIFER_ROOM_SHELF_Y_OFFSET_SCALE :: f32(0.20)
TERRAIN_AQUIFER_ROOM_WATER_XZ_SCALE :: f32(0.92)
TERRAIN_AQUIFER_ROOM_WATER_Y_SCALE :: f32(0.16)
TERRAIN_AQUIFER_ROOM_WATER_Y_OFFSET_SCALE :: f32(-0.46)
#assert(TERRAIN_AQUIFER_ROOM_BASIN_XZ_SCALE > 1)
#assert(TERRAIN_AQUIFER_ROOM_BASIN_Y_SCALE < 0.5)
#assert(TERRAIN_AQUIFER_ROOM_WATER_Y_OFFSET_SCALE < TERRAIN_AQUIFER_ROOM_BASIN_Y_OFFSET_SCALE)
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
	{0.24, 0.22, 0.24, 1.0}, // Corrupted Ash
	{0.85, 0.78, 0.36, 1.0}, // Aquifer wall
	{0.85, 0.85, 0.85, 1.0}, // Crystal
}

//////////////////////////////////////
// Terrain Types
/////////////////////////////////////

TerrainMaterialColorPalette :: [8]Vec4

TerrainCaveMouthTransitionStyle :: enum {
	Sloped_Tube,
	Curved_Ramp,
	Spiral_Ramp,
}

TerrainCaveMouthTransitionScales :: struct {
	run_scale:          f32,
	drop_scale:         f32,
	side_scale:         f32,
	vestibule_scale:    f32,
	bend_t:             f32,
	bend_return_scale:  f32,
	deep_radius_scale:  f32,
	near_curve_boost:   f32,
	near_meander_boost: f32,
	deep_curve_boost:   f32,
	deep_meander_boost: f32,
	deep_lift_boost:    f32,
}

TerrainCaveMouthTransitionPlan :: struct {
	style:                           TerrainCaveMouthTransitionStyle,
	size_support:                    f32,
	dir_x, dir_z:                    f32,
	side_x, side_z:                  f32,
	transition_run:                  f32,
	transition_drop:                 f32,
	near_radius:                     f32,
	side_offset:                     f32,
	landing_x, landing_y, landing_z: f32,
	bend_x, bend_y, bend_z:          f32,
	near_run_blocks:                 f32,
	near_drop_blocks:                f32,
	bend_run_blocks:                 f32,
	bend_drop_blocks:                f32,
	handoff_run_blocks:              f32,
	handoff_drop_blocks:             f32,
}

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

TerrainCaveSegmentShape :: struct {
	radius_x_scale:        f32,
	radius_y_scale:        f32,
	radius_z_scale:        f32,
	radius_noise_scale:    f32,
	radius_neck_scale:     f32,
	radius_swell_scale:    f32,
	radius_endpoint_scale: f32,
	meander_scale:         f32,
	lift_scale:            f32,
	curve_scale:           f32,
}

TerrainCaveFieldSample :: struct {
	open_strength:         f32,
	path_open_strength:    f32,
	chamber_open_strength: f32,
	spaghetti_strength:    f32,
	chamber_strength:      f32,
	path_axis_x:           bool,
}

TerrainCaveFieldNetworkSample :: struct {
	found:        bool,
	connected:    bool,
	bridgeable:   bool,
	distance:     f32,
	route_radius: f32,
	nearest_x:    f32,
	nearest_y:    f32,
	nearest_z:    f32,
	route_dir_x:  f32,
	route_dir_y:  f32,
	route_dir_z:  f32,
}

TerrainCaveNodeConnectivity :: struct {
	has_edge:               bool,
	has_anchor:             bool,
	should_carve:           bool,
	should_bridge:          bool,
	nearest_route_found:    bool,
	nearest_route_distance: f32,
	nearest_route_radius:   f32,
	nearest_x:              f32,
	nearest_y:              f32,
	nearest_z:              f32,
}

TerrainGridPoint :: struct {
	x, y, z: u32,
}

TerrainBiomeColumn :: struct {
	surface_height:                  i32,
	surface_height_blocks:           f32,
	surface_layer_depth:             i32,
	dominant_biome_id:               biomes.BiomeID,
	surface_material_id:             world_async.BlockMaterialID,
	subsurface_material_id:          world_async.BlockMaterialID,
	hydrology_debug_material_active: bool,
	water_fill_active:               bool,
	water_level_blocks:              f32,
}

TerrainCaveDebugColumnMask :: [CHUNK_BLOCK_LENGTH]u64

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
	generation_region_coord := biomes.generation_region_coord_from_block(
		origin.x,
		origin.y,
		origin.z,
	)
	generation_region := terrain_generation_region_for_fill(key, generation_region_coord)
	cave_debug_columns: TerrainCaveDebugColumnMask
	if TERRAIN_BAKE_DEBUG_MATERIAL_FLAGS {
		terrain_cave_debug_column_mask_build(&cave_debug_columns, &generation_region, origin)
	}
	column_targets: [CHUNK_BLOCK_LENGTH * CHUNK_BLOCK_LENGTH]TerrainBiomeColumn
	for z in 0 ..< CHUNK_BLOCK_LENGTH {
		for x in 0 ..< CHUNK_BLOCK_LENGTH {
			world_x := origin.x + i32(x)
			world_z := origin.z + i32(z)
			surface_sample := biomes.surface_biome_field_sample_from_region(
				&generation_region,
				world_x,
				world_z,
			)
			hydrology_sample := biomes.hydrology_layer_surface_sample_from_region(
				&generation_region,
				world_x,
				world_z,
			)
			column := terrain_biome_column_sample_with_hydrology(
				key,
				surface_sample,
				hydrology_sample,
				world_x,
				world_z,
			)
			column_targets[x + z * CHUNK_BLOCK_LENGTH] = column
			cave_debug_material_active := false
			if TERRAIN_BAKE_DEBUG_MATERIAL_FLAGS {
				cave_debug_material_active = (cave_debug_columns[z] & (u64(1) << u32(x))) != 0
			}

			for y in 0 ..< CHUNK_BLOCK_LENGTH {
				world_y := origin.y + i32(y)

				if !terrain_density_surface_is_solid(column, world_y) {
					continue
				}

				blocks_below_surface := column.surface_height - world_y
				material_id := terrain_biome_block_material_id(column, blocks_below_surface)
				if TERRAIN_BAKE_DEBUG_MATERIAL_FLAGS {
					if column.hydrology_debug_material_active {
						material_id = terrain_hydrology_debug_material_id(material_id)
					}
					if cave_debug_material_active {
						material_id = terrain_cave_anchor_debug_material_id(material_id)
					}
				}

				index := chunk_block_index(u32(x), u32(y), u32(z))
				view.blocks.occupancy[index] = .Solid
				view.blocks.material_id[index] = material_id
			}
		}
	}
	terrain_density_subterranean_biome_caves_apply(
		view,
		&generation_region,
		origin,
		column_targets[:],
	)
	terrain_density_cave_network_apply(view, &generation_region, origin, column_targets[:])
	terrain_water_volume_fill(view, origin, column_targets[:])
}

terrain_density_surface_is_solid :: proc(column: TerrainBiomeColumn, world_y: i32) -> bool {
	return column.surface_height_blocks - f32(world_y) >= 0
}

terrain_density_subterranean_biome_caves_apply :: proc(
	view: ^world_async.ChunkVoxelView,
	region: ^biomes.GenerationRegion,
	chunk_origin: world_async.BlockCoord,
	columns: []TerrainBiomeColumn,
) {
	key := region.key
	log.assertf(
		len(columns) == CHUNK_BLOCK_LENGTH * CHUNK_BLOCK_LENGTH,
		"terrain density column target count mismatch: %d",
		len(columns),
	)
	if f32(chunk_origin.y) > TERRAIN_CAVE_TOP_CUSHION_END_BLOCKS ||
	   f32(chunk_origin.y + CHUNK_BLOCK_LENGTH) < TERRAIN_CAVE_BOTTOM_CUSHION_START_BLOCKS {
		return
	}
	if chunk_origin.y >= 0 {
		return
	}

	stamp_count: u32
	for z := TERRAIN_CAVE_FIELD_SAMPLE_STEP_BLOCKS / 2;
	    z < CHUNK_BLOCK_LENGTH && stamp_count < TERRAIN_CAVE_FIELD_STAMP_CAPACITY_PER_CHUNK;
	    z += TERRAIN_CAVE_FIELD_SAMPLE_STEP_BLOCKS {
		world_z := chunk_origin.z + z
		for y := TERRAIN_CAVE_FIELD_SAMPLE_STEP_BLOCKS / 2;
		    y < CHUNK_BLOCK_LENGTH && stamp_count < TERRAIN_CAVE_FIELD_STAMP_CAPACITY_PER_CHUNK;
		    y += TERRAIN_CAVE_FIELD_SAMPLE_STEP_BLOCKS {
			world_y := chunk_origin.y + y
			vertical_support := terrain_density_cave_vertical_support(f32(world_y))
			if vertical_support <= 0 {
				continue
			}
			for x := TERRAIN_CAVE_FIELD_SAMPLE_STEP_BLOCKS / 2;
			    x < CHUNK_BLOCK_LENGTH &&
			    stamp_count < TERRAIN_CAVE_FIELD_STAMP_CAPACITY_PER_CHUNK;
			    x += TERRAIN_CAVE_FIELD_SAMPLE_STEP_BLOCKS {
				column := columns[x + z * CHUNK_BLOCK_LENGTH]
				depth_below_surface := column.surface_height_blocks - f32(world_y)
				if depth_below_surface < 18 {
					continue
				}

				world_x := chunk_origin.x + x
				field_sample := terrain_density_subterranean_cave_field_sample(
					key,
					world_x,
					world_y,
					world_z,
					depth_below_surface,
				)
				if !terrain_density_cave_field_sample_is_candidate(
					field_sample,
					vertical_support,
				) {
					continue
				}
				open_strength := field_sample.open_strength * vertical_support
				path_candidate := terrain_density_cave_field_sample_prefers_path(
					field_sample,
					vertical_support,
				)

				subterranean_sample := biomes.subterranean_biome_field_sample(
					key,
					world_x,
					world_y,
					world_z,
				)
				biome_id := subterranean_sample.cells[0].biome_id
				radius := biomes.regional_terrain_field_lerp(f32(3.5), f32(10.5), open_strength)
				if biome_id == .Fungal_Vaults {
					radius *= 1.25
				} else if biome_id == .Crystal_Geode_Network {
					radius *= 0.82
				} else if biome_id == .Buried_Aquifer_Caves {
					radius *= 1.05
				}
				radius_x := radius * TERRAIN_CAVE_FIELD_CHAMBER_XZ_SCALE
				radius_y :=
					radius *
					biomes.regional_terrain_field_lerp(
						TERRAIN_CAVE_FIELD_CHAMBER_Y_MIN_SCALE,
						TERRAIN_CAVE_FIELD_CHAMBER_Y_MAX_SCALE,
						open_strength,
					)
				radius_z := radius * TERRAIN_CAVE_FIELD_CHAMBER_XZ_SCALE
				network_sample := terrain_density_cave_field_network_sample(
					region,
					f32(world_x) + 0.5,
					f32(world_y) + 0.5,
					f32(world_z) + 0.5,
					radius,
					path_candidate,
				)
				if !network_sample.found ||
				   (!network_sample.connected && !network_sample.bridgeable) {
					continue
				}
				if !path_candidate &&
				   terrain_density_cave_field_sample_prefers_route_path(
					   field_sample,
					   vertical_support,
					   network_sample,
				   ) {
					path_candidate = true
				}
				if !path_candidate &&
				   stamp_count >=
					   TERRAIN_CAVE_FIELD_STAMP_CAPACITY_PER_CHUNK -
						   TERRAIN_CAVE_FIELD_PATH_STAMP_RESERVE_PER_CHUNK {
					continue
				}
				route_pocket_candidate :=
					!path_candidate &&
					terrain_density_cave_field_sample_prefers_route_pocket(
						field_sample,
						vertical_support,
						network_sample,
					)
				if path_candidate {
					path_shape := terrain_density_cave_field_path_shape()
					path_half_length := radius * TERRAIN_CAVE_FIELD_PATH_SEGMENT_HALF_LENGTH_SCALE
					path_radius := radius * TERRAIN_CAVE_FIELD_PATH_SEGMENT_RADIUS_SCALE
					center_x := f32(world_x) + 0.5
					center_y := f32(world_y) + 0.5
					center_z := f32(world_z) + 0.5
					dir_x, dir_y, dir_z, _ := terrain_density_cave_field_path_direction(
						field_sample,
						network_sample,
					)
					terrain_density_carve_rough_segment_shaped(
						view,
						key,
						chunk_origin,
						columns,
						center_x - dir_x * path_half_length,
						center_y - dir_y * path_half_length,
						center_z - dir_z * path_half_length,
						center_x + dir_x * path_half_length,
						center_y + dir_y * path_half_length,
						center_z + dir_z * path_half_length,
						path_radius,
						path_shape,
						TERRAIN_CAVE_FIELD_DETAIL_SALT,
						biome_id,
					)
					stamp_count += 1
					continue
				}
				if route_pocket_candidate {
					center_x := f32(world_x) + 0.5
					center_y := f32(world_y) + 0.5
					center_z := f32(world_z) + 0.5
					pocket_shape := terrain_density_cave_passage_shape(.Collapsed_Corridor)
					if biome_id == .Fungal_Vaults {
						pocket_shape = terrain_density_cave_passage_shape(.Worm_Path)
						pocket_shape.radius_y_scale = math.min(
							pocket_shape.radius_y_scale,
							f32(0.70),
						)
					} else if biome_id == .Crystal_Geode_Network {
						pocket_shape = terrain_density_cave_passage_shape(.Fracture)
					}
					throat_radius := math.max(
						f32(1.75),
						math.min(
							radius * TERRAIN_CAVE_FIELD_ROUTE_POCKET_THROAT_RADIUS_SCALE,
							network_sample.route_radius * f32(0.76),
						),
					)
					terrain_density_carve_rough_segment_shaped(
						view,
						key,
						chunk_origin,
						columns,
						network_sample.nearest_x,
						network_sample.nearest_y,
						network_sample.nearest_z,
						center_x,
						center_y,
						center_z,
						throat_radius,
						pocket_shape,
						TERRAIN_CAVE_BRANCH_SALT,
						biome_id,
					)
					terrain_density_carve_cave_room_lobed_ellipsoid(
						view,
						key,
						chunk_origin,
						columns,
						center_x,
						center_y,
						center_z,
						radius_x * TERRAIN_CAVE_FIELD_ROUTE_POCKET_ROOM_SCALE,
						radius_y * TERRAIN_CAVE_FIELD_ROUTE_POCKET_ROOM_SCALE,
						radius_z * TERRAIN_CAVE_FIELD_ROUTE_POCKET_ROOM_SCALE,
						TERRAIN_CAVE_FIELD_DETAIL_SALT,
						biome_id,
						true,
					)
					stamp_count += 1
					continue
				}
				terrain_density_carve_cave_room_lobed_ellipsoid(
					view,
					key,
					chunk_origin,
					columns,
					f32(world_x) + 0.5,
					f32(world_y) + 0.5,
					f32(world_z) + 0.5,
					radius_x,
					radius_y,
					radius_z,
					TERRAIN_CAVE_FIELD_DETAIL_SALT,
					biome_id,
					true,
				)
				if network_sample.bridgeable && !network_sample.connected {
					bridge_shape := terrain_density_cave_passage_shape(.Collapsed_Corridor)
					bridge_shape.radius_y_scale = math.min(bridge_shape.radius_y_scale, f32(0.64))
					bridge_shape.radius_neck_scale = math.max(
						bridge_shape.radius_neck_scale,
						f32(0.34),
					)
					bridge_radius := math.max(
						f32(2),
						math.min(
							radius * TERRAIN_CAVE_FIELD_NETWORK_BRIDGE_RADIUS_SCALE,
							network_sample.route_radius * f32(0.82),
						),
					)
					terrain_density_carve_rough_segment_shaped(
						view,
						key,
						chunk_origin,
						columns,
						f32(world_x) + 0.5,
						f32(world_y) + 0.5,
						f32(world_z) + 0.5,
						network_sample.nearest_x,
						network_sample.nearest_y,
						network_sample.nearest_z,
						bridge_radius,
						bridge_shape,
						TERRAIN_CAVE_BRANCH_SALT,
						biome_id,
					)
				}
				stamp_count += 1
			}
		}
	}
}

terrain_density_subterranean_cave_field_sample :: proc(
	key: biomes.FeatureGridKey,
	world_x, world_y, world_z: i32,
	depth_below_surface: f32,
) -> TerrainCaveFieldSample {
	depth_support := math.smoothstep(f32(18), f32(56), depth_below_surface)
	if depth_support <= 0 {
		return {}
	}

	spaghetti_a := biomes.regional_terrain_field_value_noise_3(
		key,
		world_x,
		world_y,
		world_z,
		42,
		TERRAIN_CAVE_FIELD_SPAGHETTI_A_SALT,
	)
	spaghetti_b := biomes.regional_terrain_field_value_noise_3(
		key,
		world_x,
		world_y,
		world_z,
		48,
		TERRAIN_CAVE_FIELD_SPAGHETTI_B_SALT,
	)
	spaghetti_width := 0.055 + depth_support * 0.045
	spaghetti_distance := math.max(math.abs(spaghetti_a), math.abs(spaghetti_b))
	spaghetti_strength := math.clamp(
		(spaghetti_width - spaghetti_distance) / spaghetti_width,
		f32(0),
		f32(1),
	)

	chamber := biomes.regional_terrain_field_value_noise_3(
		key,
		world_x,
		world_y,
		world_z,
		118,
		TERRAIN_CAVE_FIELD_CHAMBER_SALT,
	)
	chamber_detail := biomes.regional_terrain_field_value_noise_3(
		key,
		world_x,
		world_y,
		world_z,
		34,
		TERRAIN_CAVE_FIELD_DETAIL_SALT,
	)
	chamber_strength := math.smoothstep(
		f32(0.54),
		f32(0.84),
		chamber + chamber_detail * 0.18 + depth_support * 0.10,
	)
	path_open_strength := spaghetti_strength * depth_support
	chamber_open_strength := chamber_strength * depth_support

	return {
		open_strength = math.max(path_open_strength * 0.90, chamber_open_strength),
		path_open_strength = path_open_strength,
		chamber_open_strength = chamber_open_strength,
		spaghetti_strength = spaghetti_strength,
		chamber_strength = chamber_strength,
		path_axis_x = math.abs(spaghetti_a) < math.abs(spaghetti_b),
	}
}

terrain_density_cave_field_sample_prefers_path :: proc(
	field_sample: TerrainCaveFieldSample,
	vertical_support: f32,
) -> bool {
	path_strength := field_sample.path_open_strength * vertical_support
	chamber_strength := field_sample.chamber_open_strength * vertical_support
	return(
		path_strength >= TERRAIN_CAVE_FIELD_PATH_OPEN_STRENGTH_MIN &&
		(chamber_strength < TERRAIN_CAVE_FIELD_OPEN_STRENGTH_MIN ||
				path_strength * TERRAIN_CAVE_FIELD_PATH_SELECTION_BIAS > chamber_strength) \
	)
}

terrain_density_cave_field_sample_prefers_route_path :: proc(
	field_sample: TerrainCaveFieldSample,
	vertical_support: f32,
	network_sample: TerrainCaveFieldNetworkSample,
) -> bool {
	if !network_sample.connected {
		return false
	}
	path_strength := field_sample.path_open_strength * vertical_support
	if path_strength < TERRAIN_CAVE_FIELD_ROUTE_PATH_OPEN_STRENGTH_MIN {
		return false
	}
	return(
		network_sample.distance <=
		network_sample.route_radius + TERRAIN_CAVE_FIELD_ROUTE_PATH_DISTANCE_MARGIN_BLOCKS \
	)
}

terrain_density_cave_field_sample_prefers_route_pocket :: proc(
	field_sample: TerrainCaveFieldSample,
	vertical_support: f32,
	network_sample: TerrainCaveFieldNetworkSample,
) -> bool {
	if !network_sample.connected {
		return false
	}
	chamber_strength := field_sample.chamber_open_strength * vertical_support
	if chamber_strength < TERRAIN_CAVE_FIELD_OPEN_STRENGTH_MIN {
		return false
	}
	return(
		network_sample.distance <=
		network_sample.route_radius + TERRAIN_CAVE_FIELD_ROUTE_POCKET_DISTANCE_MARGIN_BLOCKS \
	)
}

terrain_density_cave_field_sample_is_candidate :: proc(
	field_sample: TerrainCaveFieldSample,
	vertical_support: f32,
) -> bool {
	path_strength := field_sample.path_open_strength * vertical_support
	chamber_strength := field_sample.chamber_open_strength * vertical_support
	return(
		path_strength >= TERRAIN_CAVE_FIELD_PATH_OPEN_STRENGTH_MIN ||
		chamber_strength >= TERRAIN_CAVE_FIELD_OPEN_STRENGTH_MIN \
	)
}

terrain_density_cave_field_network_sample :: proc(
	region: ^biomes.GenerationRegion,
	world_x, world_y, world_z, radius: f32,
	path_candidate: bool,
) -> TerrainCaveFieldNetworkSample {
	sample := TerrainCaveFieldNetworkSample {
		distance = biomes.BIOME_FIELD_NO_DISTANCE,
	}

	for i := u32(0); i < region.cave_network_edge_count; i += 1 {
		edge := region.cave_network_edges[i]
		route_dir_x, route_dir_y, route_dir_z := terrain_density_delta_3(
			edge.from_x,
			edge.from_y,
			edge.from_z,
			edge.bend_x,
			edge.bend_y,
			edge.bend_z,
		)
		px, py, pz, distance := terrain_density_closest_segment_point_3(
			world_x,
			world_y,
			world_z,
			edge.from_x,
			edge.from_y,
			edge.from_z,
			edge.bend_x,
			edge.bend_y,
			edge.bend_z,
		)
		terrain_density_cave_field_network_sample_note(
			&sample,
			distance,
			math.max(f32(3), edge.radius_blocks),
			px,
			py,
			pz,
			route_dir_x,
			route_dir_y,
			route_dir_z,
		)
		route_dir_x, route_dir_y, route_dir_z = terrain_density_delta_3(
			edge.bend_x,
			edge.bend_y,
			edge.bend_z,
			edge.to_x,
			edge.to_y,
			edge.to_z,
		)
		px, py, pz, distance = terrain_density_closest_segment_point_3(
			world_x,
			world_y,
			world_z,
			edge.bend_x,
			edge.bend_y,
			edge.bend_z,
			edge.to_x,
			edge.to_y,
			edge.to_z,
		)
		terrain_density_cave_field_network_sample_note(
			&sample,
			distance,
			math.max(f32(3), edge.radius_blocks),
			px,
			py,
			pz,
			route_dir_x,
			route_dir_y,
			route_dir_z,
		)
	}

	if !sample.found {
		return sample
	}

	connected_margin := TERRAIN_CAVE_FIELD_NETWORK_CONNECTED_MARGIN_BLOCKS
	if path_candidate {
		connected_margin = TERRAIN_CAVE_FIELD_NETWORK_PATH_MARGIN_BLOCKS
	}
	connected_distance := radius + sample.route_radius + connected_margin
	bridge_distance :=
		radius + sample.route_radius + TERRAIN_CAVE_FIELD_NETWORK_BRIDGE_MARGIN_BLOCKS
	sample.connected = sample.distance <= connected_distance
	sample.bridgeable =
		!path_candidate &&
		radius >= TERRAIN_CAVE_FIELD_NETWORK_BRIDGE_MIN_RADIUS &&
		sample.distance > connected_distance &&
		sample.distance <= bridge_distance
	return sample
}

terrain_density_cave_field_path_direction :: proc(
	field_sample: TerrainCaveFieldSample,
	network_sample: TerrainCaveFieldNetworkSample,
) -> (
	dir_x, dir_y, dir_z: f32,
	route_follow: bool,
) {
	route_len_sq :=
		network_sample.route_dir_x * network_sample.route_dir_x +
		network_sample.route_dir_y * network_sample.route_dir_y +
		network_sample.route_dir_z * network_sample.route_dir_z
	route_xz_len_sq :=
		network_sample.route_dir_x * network_sample.route_dir_x +
		network_sample.route_dir_z * network_sample.route_dir_z
	if network_sample.found && route_len_sq > 0.001 && route_xz_len_sq > 0.001 {
		route_xz_len := math.sqrt_f32(route_xz_len_sq)
		route_len := math.sqrt_f32(route_len_sq)
		dir_x = network_sample.route_dir_x / route_xz_len
		dir_y =
			math.clamp(network_sample.route_dir_y / route_len, f32(-0.85), f32(0.85)) *
			TERRAIN_CAVE_FIELD_PATH_ROUTE_VERTICAL_SCALE
		dir_z = network_sample.route_dir_z / route_xz_len
		route_follow = true
		return
	}

	if field_sample.path_axis_x {
		return 1, 0, 0, false
	}
	return 0, 0, 1, false
}

terrain_density_cave_field_network_sample_note :: proc(
	sample: ^TerrainCaveFieldNetworkSample,
	distance,
	route_radius,
	nearest_x,
	nearest_y,
	nearest_z,
	route_dir_x,
	route_dir_y,
	route_dir_z: f32,
) {
	if !sample.found || distance < sample.distance {
		sample.found = true
		sample.distance = distance
		sample.route_radius = route_radius
		sample.nearest_x = nearest_x
		sample.nearest_y = nearest_y
		sample.nearest_z = nearest_z
		sample.route_dir_x = route_dir_x
		sample.route_dir_y = route_dir_y
		sample.route_dir_z = route_dir_z
	}
}

terrain_density_delta_3 :: proc(
	from_x, from_y, from_z, to_x, to_y, to_z: f32,
) -> (
	dir_x, dir_y, dir_z: f32,
) {
	dir_x = to_x - from_x
	dir_y = to_y - from_y
	dir_z = to_z - from_z
	return
}

terrain_density_closest_segment_point_3 :: proc(
	x, y, z, from_x, from_y, from_z, to_x, to_y, to_z: f32,
) -> (
	nearest_x, nearest_y, nearest_z, distance: f32,
) {
	seg_x := to_x - from_x
	seg_y := to_y - from_y
	seg_z := to_z - from_z
	length_sq := seg_x * seg_x + seg_y * seg_y + seg_z * seg_z
	if length_sq <= 0.001 {
		return from_x, from_y, from_z, terrain_density_distance_3(x, y, z, from_x, from_y, from_z)
	}
	t := ((x - from_x) * seg_x + (y - from_y) * seg_y + (z - from_z) * seg_z) / length_sq
	t = math.clamp(t, f32(0), f32(1))
	nearest_x = from_x + seg_x * t
	nearest_y = from_y + seg_y * t
	nearest_z = from_z + seg_z * t
	distance = terrain_density_distance_3(x, y, z, nearest_x, nearest_y, nearest_z)
	return
}

terrain_density_distance_3 :: proc(x, y, z, target_x, target_y, target_z: f32) -> f32 {
	dx := x - target_x
	dy := y - target_y
	dz := z - target_z
	return math.sqrt_f32(dx * dx + dy * dy + dz * dz)
}

terrain_density_cave_node_connectivity :: proc(
	region: ^biomes.GenerationRegion,
	node: biomes.CaveNetworkNode,
) -> TerrainCaveNodeConnectivity {
	connectivity := TerrainCaveNodeConnectivity {
		nearest_route_distance = biomes.BIOME_FIELD_NO_DISTANCE,
	}

	for i := u32(0); i < region.cave_network_edge_count; i += 1 {
		edge := region.cave_network_edges[i]
		if edge.from_node_id == node.id || edge.to_node_id == node.id {
			connectivity.has_edge = true
			continue
		}
		px, py, pz, distance := terrain_density_closest_segment_point_3(
			node.x,
			node.y,
			node.z,
			edge.from_x,
			edge.from_y,
			edge.from_z,
			edge.bend_x,
			edge.bend_y,
			edge.bend_z,
		)
		terrain_density_cave_node_connectivity_note_route(
			&connectivity,
			distance,
			math.max(f32(3), edge.radius_blocks),
			px,
			py,
			pz,
		)
		px, py, pz, distance = terrain_density_closest_segment_point_3(
			node.x,
			node.y,
			node.z,
			edge.bend_x,
			edge.bend_y,
			edge.bend_z,
			edge.to_x,
			edge.to_y,
			edge.to_z,
		)
		terrain_density_cave_node_connectivity_note_route(
			&connectivity,
			distance,
			math.max(f32(3), edge.radius_blocks),
			px,
			py,
			pz,
		)
	}

	for i := u32(0); i < region.cave_anchor_count; i += 1 {
		anchor := region.cave_anchors[i]
		if anchor.feature_id == node.id || anchor.target_feature_id == node.id {
			connectivity.has_anchor = true
			break
		}
	}

	requires_connection :=
		node.role == .Major_Region ||
		node.role == .Water_Linked_Region ||
		node.role == .Connector ||
		connectivity.has_anchor
	large_chamber := node.radius_blocks >= TERRAIN_CAVE_NODE_ISOLATED_CULL_RADIUS_BLOCKS
	connectivity.should_bridge =
		!connectivity.has_edge &&
		connectivity.nearest_route_found &&
		(requires_connection || large_chamber) &&
		connectivity.nearest_route_distance <= TERRAIN_CAVE_NODE_BRIDGE_MAX_DISTANCE_BLOCKS
	connectivity.should_carve = connectivity.has_edge || connectivity.should_bridge
	if node.role == .Sealed_Secret && !connectivity.has_edge && !connectivity.has_anchor {
		connectivity.should_carve = false
		connectivity.should_bridge = false
	}
	return connectivity
}

terrain_density_cave_node_connectivity_note_route :: proc(
	connectivity: ^TerrainCaveNodeConnectivity,
	distance, route_radius, nearest_x, nearest_y, nearest_z: f32,
) {
	if !connectivity.nearest_route_found || distance < connectivity.nearest_route_distance {
		connectivity.nearest_route_found = true
		connectivity.nearest_route_distance = distance
		connectivity.nearest_route_radius = route_radius
		connectivity.nearest_x = nearest_x
		connectivity.nearest_y = nearest_y
		connectivity.nearest_z = nearest_z
	}
}

terrain_density_cave_network_apply :: proc(
	view: ^world_async.ChunkVoxelView,
	region: ^biomes.GenerationRegion,
	chunk_origin: world_async.BlockCoord,
	columns: []TerrainBiomeColumn,
) {
	log.assertf(
		len(columns) == CHUNK_BLOCK_LENGTH * CHUNK_BLOCK_LENGTH,
		"terrain density column target count mismatch: %d",
		len(columns),
	)

	node_connectivity: [biomes.GENERATION_REGION_CAVE_NETWORK_NODE_CAPACITY]TerrainCaveNodeConnectivity
	for i := u32(0); i < region.cave_network_node_count; i += 1 {
		node_connectivity[i] = terrain_density_cave_node_connectivity(
			region,
			region.cave_network_nodes[i],
		)
	}

	for i := u32(0); i < region.cave_network_node_count; i += 1 {
		node := region.cave_network_nodes[i]
		connectivity := node_connectivity[i]
		if !connectivity.should_carve {
			continue
		}
		terrain_density_carve_cave_node(view, region.key, chunk_origin, columns, node)
	}

	for i := u32(0); i < region.cave_network_edge_count; i += 1 {
		edge := region.cave_network_edges[i]
		terrain_density_carve_cave_edge(view, region, chunk_origin, columns, edge)
	}

	for i := u32(0); i < region.cave_network_node_count; i += 1 {
		node := region.cave_network_nodes[i]
		connectivity := node_connectivity[i]
		if !connectivity.should_bridge {
			continue
		}
		bridge_shape := terrain_density_cave_passage_shape(.Collapsed_Corridor)
		if node.kind == .Geode_Chamber || node.biome_id == .Crystal_Geode_Network {
			bridge_shape = terrain_density_cave_passage_shape(.Fracture)
		} else if node.biome_id == .Fungal_Vaults {
			bridge_shape = terrain_density_cave_passage_shape(.Worm_Path)
			bridge_shape.radius_y_scale = math.min(bridge_shape.radius_y_scale, f32(0.72))
		}
		bridge_radius := math.max(
			f32(2),
			math.min(
				node.connection_radius_blocks,
				connectivity.nearest_route_radius * f32(0.88),
			) *
			TERRAIN_CAVE_NODE_BRIDGE_RADIUS_SCALE,
		)
		terrain_density_carve_rough_segment_shaped(
			view,
			region.key,
			chunk_origin,
			columns,
			node.x,
			node.y,
			node.z,
			connectivity.nearest_x,
			connectivity.nearest_y,
			connectivity.nearest_z,
			bridge_radius,
			bridge_shape,
			TERRAIN_CAVE_BRANCH_SALT,
			node.biome_id,
		)
	}

	for i := u32(0); i < region.cave_anchor_count; i += 1 {
		anchor := region.cave_anchors[i]
		terrain_density_cave_anchor_apply(
			view,
			region,
			chunk_origin,
			columns,
			anchor,
			&node_connectivity,
		)
	}
}

terrain_density_cave_anchor_apply :: proc(
	view: ^world_async.ChunkVoxelView,
	region: ^biomes.GenerationRegion,
	chunk_origin: world_async.BlockCoord,
	columns: []TerrainBiomeColumn,
	anchor: biomes.CaveAnchor,
	node_connectivity: ^[biomes.GENERATION_REGION_CAVE_NETWORK_NODE_CAPACITY]TerrainCaveNodeConnectivity,
) {
	anchor_radius := math.max(f32(3), anchor.influence_radius_blocks * 0.55)
	node, node_index, found := terrain_density_cave_anchor_node_find(region, anchor)
	if !found {
		return
	}

	link_radius := math.max(f32(3), math.min(anchor_radius * 0.75, node.connection_radius_blocks))
	if !node_connectivity[node_index].should_carve {
		return
	}
	terrain_density_carve_cave_entrance(
		view,
		region.key,
		chunk_origin,
		columns,
		anchor,
		node,
		link_radius,
	)
}

terrain_density_cave_anchor_node_find :: proc(
	region: ^biomes.GenerationRegion,
	anchor: biomes.CaveAnchor,
) -> (
	node: biomes.CaveNetworkNode,
	node_index: u32,
	found: bool,
) {
	for i := u32(0); i < region.cave_network_node_count; i += 1 {
		candidate := region.cave_network_nodes[i]
		if candidate.id == anchor.feature_id {
			return candidate, i, true
		}
	}

	if !anchor.guaranteed_connection {
		return
	}

	#partial switch anchor.kind {
	case .Cave_Mouth,
	     .Sinkhole,
	     .Vertical_Shaft,
	     .Lakebed_Breach,
	     .Seabed_Breach,
	     .Underground_River_Source,
	     .Underground_River_Sink,
	     .Magma_Vent,
	     .Subterranean_Biome_Gateway:
		break
	case .Ravine_Breach:
		return
	}

	best_distance_sq := f32(192 * 192)
	for i := u32(0); i < region.cave_network_node_count; i += 1 {
		candidate := region.cave_network_nodes[i]
		dx := candidate.x - anchor.x
		dy := candidate.y - anchor.y
		dz := candidate.z - anchor.z
		distance_sq := dx * dx + dy * dy + dz * dz
		if distance_sq < best_distance_sq {
			best_distance_sq = distance_sq
			node = candidate
			node_index = i
			found = true
		}
	}
	return
}

terrain_density_carve_cave_node :: proc(
	view: ^world_async.ChunkVoxelView,
	key: biomes.FeatureGridKey,
	chunk_origin: world_async.BlockCoord,
	columns: []TerrainBiomeColumn,
	node: biomes.CaveNetworkNode,
) {
	radius_x := node.radius_blocks
	radius_y := node.radius_blocks * 0.85
	radius_z := node.radius_blocks

	#partial switch node.kind {
	case .Biome_Hub:
		radius_x *= 1.35
		radius_y *= 0.78
		radius_z *= 1.20
	case .Underground_Lake:
		radius_x *= 1.45
		radius_y *= 0.55
		radius_z *= 1.35
	case .River_Junction:
		radius_x *= 1.15
		radius_y *= 0.72
		radius_z *= 1.15
	case .Vertical_Shaft:
		radius_x *= 0.55
		radius_y *= 1.75
		radius_z *= 0.55
	case .Geode_Chamber:
		radius_x *= 1.05
		radius_y *= 1.05
		radius_z *= 1.05
	case .Magma_Pocket:
		radius_x *= 1.15
		radius_y *= 0.70
		radius_z *= 1.15
	}

	if terrain_density_cave_node_uses_profile_room(node) {
		radius_scale := f32(1)
		max_radius_xz := TERRAIN_CAVE_NODE_PROFILE_ROOM_MAJOR_MAX_XZ
		max_radius_y := TERRAIN_CAVE_NODE_PROFILE_ROOM_MAJOR_MAX_Y
		if !node.major_region {
			radius_scale = TERRAIN_CAVE_NODE_PROFILE_ROOM_MINOR_SCALE
			max_radius_xz = TERRAIN_CAVE_NODE_PROFILE_ROOM_MINOR_MAX_XZ
			max_radius_y = TERRAIN_CAVE_NODE_PROFILE_ROOM_MINOR_MAX_Y
		}
		terrain_density_carve_cave_room(
			view,
			key,
			chunk_origin,
			columns,
			node.x,
			node.y,
			node.z,
			math.min(radius_x * radius_scale, max_radius_xz),
			math.min(radius_y * radius_scale, max_radius_y),
			math.min(radius_z * radius_scale, max_radius_xz),
			node.kind,
			node.biome_id,
		)
		return
	}

	terrain_density_carve_rough_ellipsoid(
		view,
		key,
		chunk_origin,
		columns,
		node.x,
		node.y,
		node.z,
		radius_x,
		radius_y,
		radius_z,
		TERRAIN_CAVE_ROUGHNESS_SALT,
		node.biome_id,
	)
}

terrain_density_cave_node_uses_profile_room :: proc(node: biomes.CaveNetworkNode) -> bool {
	if node.major_region {
		return true
	}
	if node.radius_blocks < TERRAIN_CAVE_NODE_PROFILE_ROOM_MIN_RADIUS_BLOCKS {
		return false
	}
	return(
		node.role == .Water_Linked_Region ||
		node.role == .Resource_Chamber ||
		node.kind == .Underground_Lake ||
		node.kind == .Geode_Chamber ||
		node.kind == .Magma_Pocket ||
		(node.kind == .Chamber &&
				node.radius_blocks >= TERRAIN_CAVE_NODE_ISOLATED_CULL_RADIUS_BLOCKS) \
	)
}

terrain_density_carve_cave_room :: proc(
	view: ^world_async.ChunkVoxelView,
	key: biomes.FeatureGridKey,
	chunk_origin: world_async.BlockCoord,
	columns: []TerrainBiomeColumn,
	center_x, center_y, center_z, radius_x, radius_y, radius_z: f32,
	kind: biomes.CaveNetworkNodeKind,
	biome_id: biomes.BiomeID,
) {
	rx := math.max(f32(2), radius_x)
	ry := math.max(f32(2), radius_y)
	rz := math.max(f32(2), radius_z)
	offset_x := biomes.regional_terrain_field_value_noise_3(
		key,
		i32(math.floor_f32(center_x)),
		i32(math.floor_f32(center_y)),
		i32(math.floor_f32(center_z)),
		56,
		TERRAIN_CAVE_BRANCH_SALT,
	)
	offset_z := biomes.regional_terrain_field_value_noise_3(
		key,
		i32(math.floor_f32(center_x)) + 11,
		i32(math.floor_f32(center_y)),
		i32(math.floor_f32(center_z)) - 7,
		56,
		TERRAIN_CAVE_BRANCH_SALT,
	)
	offset_len := math.sqrt_f32(offset_x * offset_x + offset_z * offset_z)
	if offset_len <= 0.001 {
		offset_x, offset_z = 1, 0
	} else {
		offset_x /= offset_len
		offset_z /= offset_len
	}

	#partial switch biome_id {
	case .Fungal_Vaults:
		terrain_density_carve_cave_room_lobed_ellipsoid(
			view,
			key,
			chunk_origin,
			columns,
			center_x,
			center_y + ry * TERRAIN_FUNGAL_ROOM_LOWER_Y_OFFSET_SCALE,
			center_z,
			rx * TERRAIN_FUNGAL_ROOM_LOWER_XZ_SCALE,
			ry * TERRAIN_FUNGAL_ROOM_LOWER_Y_SCALE,
			rz * TERRAIN_FUNGAL_ROOM_LOWER_XZ_SCALE,
			TERRAIN_CAVE_ROOM_DETAIL_SALT,
			biome_id,
			true,
		)
		terrain_density_carve_cave_room_lobed_ellipsoid(
			view,
			key,
			chunk_origin,
			columns,
			center_x,
			center_y + ry * TERRAIN_FUNGAL_ROOM_DOME_Y_OFFSET_SCALE,
			center_z,
			rx * TERRAIN_FUNGAL_ROOM_DOME_XZ_SCALE,
			ry * TERRAIN_FUNGAL_ROOM_DOME_Y_SCALE,
			rz * TERRAIN_FUNGAL_ROOM_DOME_XZ_SCALE,
			TERRAIN_CAVE_ROOM_DETAIL_SALT,
			biome_id,
			true,
		)
		terrain_density_carve_cave_room_lobed_ellipsoid(
			view,
			key,
			chunk_origin,
			columns,
			center_x + offset_x * rx * TERRAIN_FUNGAL_ROOM_ALCOVE_OFFSET_SCALE,
			center_y + ry * TERRAIN_FUNGAL_ROOM_ALCOVE_Y_OFFSET_SCALE,
			center_z + offset_z * rz * TERRAIN_FUNGAL_ROOM_ALCOVE_OFFSET_SCALE,
			rx * TERRAIN_FUNGAL_ROOM_ALCOVE_XZ_SCALE,
			ry * TERRAIN_FUNGAL_ROOM_ALCOVE_Y_SCALE,
			rz * TERRAIN_FUNGAL_ROOM_ALCOVE_XZ_SCALE,
			TERRAIN_CAVE_DETAIL_SALT,
			biome_id,
			true,
		)
		return
	case .Crystal_Geode_Network:
		terrain_density_carve_cave_room_lobed_ellipsoid(
			view,
			key,
			chunk_origin,
			columns,
			center_x,
			center_y,
			center_z,
			rx * TERRAIN_CRYSTAL_ROOM_MAIN_XZ_SCALE,
			ry * TERRAIN_CRYSTAL_ROOM_MAIN_Y_SCALE,
			rz * TERRAIN_CRYSTAL_ROOM_MAIN_XZ_SCALE,
			TERRAIN_CAVE_PASSAGE_RIB_SALT,
			biome_id,
			true,
		)
		terrain_density_carve_rough_segment_shaped(
			view,
			key,
			chunk_origin,
			columns,
			center_x - offset_x * rx * 0.72,
			center_y - ry * TERRAIN_CRYSTAL_ROOM_FISSURE_LOWER_Y_SCALE,
			center_z - offset_z * rz * 0.72,
			center_x + offset_x * rx * 0.84,
			center_y + ry * TERRAIN_CRYSTAL_ROOM_FISSURE_UPPER_Y_SCALE,
			center_z + offset_z * rz * 0.84,
			math.max(f32(2.5), math.min(rx, rz) * TERRAIN_CRYSTAL_ROOM_FISSURE_RADIUS_SCALE),
			terrain_density_cave_passage_shape(.Fracture),
			TERRAIN_CAVE_PASSAGE_RIB_SALT,
			biome_id,
			true,
		)
		return
	case .Buried_Aquifer_Caves:
		terrain_density_carve_cave_room_lobed_ellipsoid(
			view,
			key,
			chunk_origin,
			columns,
			center_x,
			center_y + ry * TERRAIN_AQUIFER_ROOM_BASIN_Y_OFFSET_SCALE,
			center_z,
			rx * TERRAIN_AQUIFER_ROOM_BASIN_XZ_SCALE,
			ry * TERRAIN_AQUIFER_ROOM_BASIN_Y_SCALE,
			rz * TERRAIN_AQUIFER_ROOM_BASIN_XZ_SCALE,
			TERRAIN_CAVE_FIELD_DETAIL_SALT,
			biome_id,
			true,
		)
		terrain_density_carve_cave_room_lobed_ellipsoid(
			view,
			key,
			chunk_origin,
			columns,
			center_x + offset_x * rx * TERRAIN_AQUIFER_ROOM_SHELF_OFFSET_SCALE,
			center_y + ry * TERRAIN_AQUIFER_ROOM_SHELF_Y_OFFSET_SCALE,
			center_z + offset_z * rz * TERRAIN_AQUIFER_ROOM_SHELF_OFFSET_SCALE,
			rx * TERRAIN_AQUIFER_ROOM_SHELF_XZ_SCALE,
			ry * TERRAIN_AQUIFER_ROOM_SHELF_Y_SCALE,
			rz * TERRAIN_AQUIFER_ROOM_SHELF_XZ_SCALE,
			TERRAIN_CAVE_ROOM_DETAIL_SALT,
			biome_id,
			true,
		)
		terrain_density_fill_water_ellipsoid(
			view,
			chunk_origin,
			center_x,
			center_y + ry * TERRAIN_AQUIFER_ROOM_WATER_Y_OFFSET_SCALE,
			center_z,
			rx * TERRAIN_AQUIFER_ROOM_WATER_XZ_SCALE,
			math.max(f32(1.5), ry * TERRAIN_AQUIFER_ROOM_WATER_Y_SCALE),
			rz * TERRAIN_AQUIFER_ROOM_WATER_XZ_SCALE,
		)
		return
	}

	if kind == .Vertical_Shaft {
		terrain_density_carve_cave_room_lobed_ellipsoid(
			view,
			key,
			chunk_origin,
			columns,
			center_x,
			center_y,
			center_z,
			rx * 0.55,
			ry,
			rz * 0.55,
			TERRAIN_CAVE_ROUGHNESS_SALT,
			biome_id,
			true,
		)
		return
	}
	terrain_density_carve_cave_room_lobed_ellipsoid(
		view,
		key,
		chunk_origin,
		columns,
		center_x,
		center_y,
		center_z,
		rx,
		ry,
		rz,
		TERRAIN_CAVE_ROUGHNESS_SALT,
		biome_id,
		true,
	)
}

terrain_density_carve_cave_room_lobed_ellipsoid :: proc(
	view: ^world_async.ChunkVoxelView,
	key: biomes.FeatureGridKey,
	chunk_origin: world_async.BlockCoord,
	columns: []TerrainBiomeColumn,
	center_x, center_y, center_z, radius_x, radius_y, radius_z: f32,
	noise_salt: u64,
	biome_id: biomes.BiomeID,
	directional_material_profile: bool = false,
) {
	rx := math.max(f32(1), radius_x)
	ry := math.max(f32(1), radius_y)
	rz := math.max(f32(1), radius_z)
	padding := math.max(rx, math.max(ry, rz)) * 0.26 + 2
	local_min_x, local_max_x, local_min_y, local_max_y, local_min_z, local_max_z, intersects :=
		terrain_density_carve_bounds_from_extents(
			chunk_origin,
			center_x - rx - padding,
			center_x + rx + padding,
			center_y - ry - padding,
			center_y + ry + padding,
			center_z - rz - padding,
			center_z + rz + padding,
		)
	if !intersects {
		return
	}

	internal_structure_active :=
		math.min(rx, math.min(ry, rz)) >= TERRAIN_CAVE_ROOM_INTERNAL_STRUCTURE_MIN_RADIUS
	axis_x := biomes.regional_terrain_field_value_noise_3(
		key,
		i32(math.floor_f32(center_x)),
		i32(math.floor_f32(center_y)),
		i32(math.floor_f32(center_z)),
		64,
		TERRAIN_CAVE_BRANCH_SALT,
	)
	axis_z := biomes.regional_terrain_field_value_noise_3(
		key,
		i32(math.floor_f32(center_x)) + 17,
		i32(math.floor_f32(center_y)) - 5,
		i32(math.floor_f32(center_z)) + 23,
		64,
		TERRAIN_CAVE_ROOM_DETAIL_SALT,
	)
	axis_len := math.sqrt_f32(axis_x * axis_x + axis_z * axis_z)
	if axis_len <= 0.001 {
		axis_x, axis_z = 1, 0
	} else {
		axis_x /= axis_len
		axis_z /= axis_len
	}

	for z := local_min_z; z <= local_max_z; z += 1 {
		world_z := f32(chunk_origin.z + z) + 0.5
		for y := local_min_y; y <= local_max_y; y += 1 {
			world_y := f32(chunk_origin.y + y) + 0.5
			for x := local_min_x; x <= local_max_x; x += 1 {
				world_x := f32(chunk_origin.x + x) + 0.5
				nx := (world_x - center_x) / rx
				ny := (world_y - center_y) / ry
				nz := (world_z - center_z) / rz
				rough := biomes.regional_terrain_field_value_noise_3(
					key,
					chunk_origin.x + x,
					chunk_origin.y + y,
					chunk_origin.z + z,
					24,
					noise_salt,
				)
				detail := biomes.regional_terrain_field_value_noise_3(
					key,
					chunk_origin.x + x,
					chunk_origin.y + y,
					chunk_origin.z + z,
					10,
					noise_salt ~ TERRAIN_CAVE_PASSAGE_RIB_SALT,
				)
				along := nx * axis_x + nz * axis_z
				across := nx * -axis_z + nz * axis_x
				radial := math.sqrt_f32(along * along + across * across)
				wall_support :=
					math.smoothstep(f32(0.18), f32(1.08), radial) *
					(1.0 - math.smoothstep(f32(0.76), f32(1.12), math.abs(ny)))
				core_shelf := 1.0 - math.smoothstep(f32(0.62), f32(1.02), radial)
				warped_along :=
					along +
					detail *
						TERRAIN_CAVE_ROOM_COORD_WARP_SCALE *
						wall_support *
						(0.80 + math.abs(across) * 0.28)
				warped_across :=
					across -
					rough *
						TERRAIN_CAVE_ROOM_COORD_WARP_SCALE *
						wall_support *
						(0.72 + math.abs(along) * 0.24)
				warped_y := ny + detail * TERRAIN_CAVE_ROOM_VERTICAL_WARP_SCALE * core_shelf
				shape :=
					warped_along * warped_along +
					warped_y * warped_y +
					warped_across * warped_across
				core_support := math.clamp((f32(1.0) - shape) * 1.389, f32(0), f32(1))
				rough_scale :=
					TERRAIN_CAVE_ROUGH_ELLIPSOID_EDGE_SCALE -
					(TERRAIN_CAVE_ROUGH_ELLIPSOID_EDGE_SCALE -
							TERRAIN_CAVE_ROUGH_ELLIPSOID_CORE_SCALE) *
						core_support
				threshold :=
					1.0 +
					(rough * 0.68 + detail * 0.32) * rough_scale +
					detail * TERRAIN_CAVE_ROOM_SCALLOP_SCALE * wall_support +
					terrain_density_cave_room_lobe_threshold_adjust(nx, ny, nz, axis_x, axis_z)
				if shape <= threshold {
					if internal_structure_active &&
					   terrain_density_cave_room_internal_structure_preserves(
						   nx,
						   ny,
						   nz,
						   rx,
						   ry,
						   rz,
						   axis_x,
						   axis_z,
						   rough,
						   biome_id,
					   ) {
						continue
					}
					terrain_density_carve_local_block_with_material(
						view,
						key,
						chunk_origin,
						columns,
						x,
						y,
						z,
						biome_id,
						directional_material_profile,
					)
				}
			}
		}
	}
}

terrain_density_cave_room_internal_structure_preserves :: proc(
	nx, ny, nz, rx, ry, rz, axis_x, axis_z, rough: f32,
	biome_id: biomes.BiomeID,
) -> bool {
	min_radius := math.min(rx, math.min(ry, rz))
	if min_radius < TERRAIN_CAVE_ROOM_INTERNAL_STRUCTURE_MIN_RADIUS {
		return false
	}

	shape := nx * nx + ny * ny + nz * nz
	if shape < 0.08 || shape > 0.88 {
		return false
	}

	along := nx * axis_x + nz * axis_z
	across := nx * -axis_z + nz * axis_x
	along_abs := math.abs(along)
	across_abs := math.abs(across)
	vertical_column := 1.0 - math.smoothstep(f32(0.72), f32(0.98), math.abs(ny))
	positive_rough := math.smoothstep(f32(0.02), f32(0.48), rough)
	if vertical_column <= 0 || positive_rough <= 0 {
		return false
	}

	strength := f32(0)
	#partial switch biome_id {
	case .Fungal_Vaults:
		side_root :=
			math.clamp(1.0 - math.abs(across_abs - f32(0.42)) * f32(5.0), f32(0), f32(1)) *
			(1.0 - math.smoothstep(f32(0.62), f32(0.94), along_abs))
		strength = side_root * vertical_column * positive_rough
		return strength > 0.42
	case .Crystal_Geode_Network:
		crystal_blade :=
			math.clamp(1.0 - math.abs(across_abs - f32(0.26)) * f32(7.0), f32(0), f32(1)) *
			(1.0 - math.smoothstep(f32(0.70), f32(0.96), along_abs))
		strength = crystal_blade * vertical_column * positive_rough
		return strength > 0.46
	case .Buried_Aquifer_Caves:
		lower_island := math.smoothstep(f32(0.12), f32(0.58), -ny)
		island_band :=
			math.clamp(1.0 - math.abs(across_abs - f32(0.32)) * f32(5.2), f32(0), f32(1)) *
			(1.0 - math.smoothstep(f32(0.50), f32(0.88), along_abs))
		strength = island_band * lower_island * positive_rough
		return strength > 0.36
	case .Temperate_Hills, .Basalt_Spire_Highlands, .Wet_Lowland_Marsh, .Corrupted_Ash_Forest:
		side_rib :=
			math.clamp(1.0 - math.abs(across_abs - f32(0.36)) * f32(5.6), f32(0), f32(1)) *
			(1.0 - math.smoothstep(f32(0.62), f32(0.92), along_abs))
		strength = side_rib * vertical_column * positive_rough
		return strength > 0.48
	}
	return false
}

terrain_density_cave_room_lobe_threshold_adjust :: proc(nx, ny, nz, axis_x, axis_z: f32) -> f32 {
	shape := nx * nx + ny * ny + nz * nz
	core_support := math.clamp((f32(1.0) - shape) * 1.389, f32(0), f32(1))
	edge_support := 1.0 - core_support
	along := nx * axis_x + nz * axis_z
	across := nx * -axis_z + nz * axis_x
	along_abs := math.abs(along)
	across_abs := math.abs(across)
	forward_lobe := math.smoothstep(f32(0.08), f32(0.86), along)
	back_lobe := math.smoothstep(f32(0.18), f32(0.82), -along)
	side_notch :=
		math.smoothstep(f32(0.32), f32(0.92), across_abs) *
		(1.0 - math.smoothstep(f32(0.70), f32(1.05), along_abs))
	ceiling_rib :=
		math.smoothstep(f32(0.18), f32(0.85), ny) *
		math.smoothstep(f32(0.38), f32(0.96), across_abs)
	return(
		edge_support *
		(forward_lobe * TERRAIN_CAVE_ROOM_LOBE_SWELL_SCALE +
				back_lobe * TERRAIN_CAVE_ROOM_LOBE_BACK_SWELL_SCALE -
				side_notch * TERRAIN_CAVE_ROOM_SIDE_NOTCH_SCALE -
				ceiling_rib * TERRAIN_CAVE_ROOM_CEILING_RIB_SCALE) \
	)
}

terrain_density_fill_water_ellipsoid :: proc(
	view: ^world_async.ChunkVoxelView,
	chunk_origin: world_async.BlockCoord,
	center_x, center_y, center_z, radius_x, radius_y, radius_z: f32,
) {
	rx := math.max(f32(1), radius_x)
	ry := math.max(f32(1), radius_y)
	rz := math.max(f32(1), radius_z)
	local_min_x, local_max_x, local_min_y, local_max_y, local_min_z, local_max_z, intersects :=
		terrain_density_carve_bounds_from_extents(
			chunk_origin,
			center_x - rx,
			center_x + rx,
			center_y - ry,
			center_y + ry,
			center_z - rz,
			center_z + rz,
		)
	if !intersects {
		return
	}

	for z := local_min_z; z <= local_max_z; z += 1 {
		world_z := f32(chunk_origin.z + z) + 0.5
		for y := local_min_y; y <= local_max_y; y += 1 {
			world_y := f32(chunk_origin.y + y) + 0.5
			for x := local_min_x; x <= local_max_x; x += 1 {
				world_x := f32(chunk_origin.x + x) + 0.5
				nx := (world_x - center_x) / rx
				ny := (world_y - center_y) / ry
				nz := (world_z - center_z) / rz
				if nx * nx + ny * ny + nz * nz > 1.0 {
					continue
				}
				terrain_density_fill_local_water_block(view, x, y, z)
			}
		}
	}
}

terrain_density_carve_cave_edge :: proc(
	view: ^world_async.ChunkVoxelView,
	region: ^biomes.GenerationRegion,
	chunk_origin: world_async.BlockCoord,
	columns: []TerrainBiomeColumn,
	edge: biomes.CaveNetworkEdge,
) {
	radius := edge.radius_blocks
	#partial switch edge.kind {
	case .Canyon:
		radius *= 1.18
	case .Fracture:
		radius *= 0.72
	case .Flooded_Passage:
		radius *= 1.10
	case .Vertical_Shaft:
		radius *= 0.92
	case .Collapsed_Corridor:
		radius *= 0.82
	case .Worm_Path:
		radius *= 0.92
	}
	terrain_density_carve_cave_passage_segment(
		view,
		region.key,
		chunk_origin,
		columns,
		edge.from_x,
		edge.from_y,
		edge.from_z,
		edge.bend_x,
		edge.bend_y,
		edge.bend_z,
		radius,
		edge.kind,
		edge.from_biome_id,
	)
	terrain_density_carve_cave_passage_segment(
		view,
		region.key,
		chunk_origin,
		columns,
		edge.bend_x,
		edge.bend_y,
		edge.bend_z,
		edge.to_x,
		edge.to_y,
		edge.to_z,
		radius * 0.94,
		edge.kind,
		edge.to_biome_id,
	)
}

terrain_density_carve_cave_passage_segment :: proc(
	view: ^world_async.ChunkVoxelView,
	key: biomes.FeatureGridKey,
	chunk_origin: world_async.BlockCoord,
	columns: []TerrainBiomeColumn,
	from_x, from_y, from_z, to_x, to_y, to_z, radius_blocks: f32,
	kind: biomes.CaveNetworkEdgeKind,
	biome_id: biomes.BiomeID,
) {
	radius := math.max(f32(1), radius_blocks)
	salt := TERRAIN_CAVE_ROUGHNESS_SALT
	#partial switch kind {
	case .Canyon:
		radius *= 1.10
		salt = TERRAIN_CAVE_ROOM_DETAIL_SALT
	case .Fracture:
		radius *= 0.68
		salt = TERRAIN_CAVE_PASSAGE_RIB_SALT
	case .Flooded_Passage:
		radius *= 1.06
		salt = TERRAIN_CAVE_FIELD_DETAIL_SALT
	case .Vertical_Shaft:
		radius *= 0.86
	case .Collapsed_Corridor:
		radius *= 0.72
		salt = TERRAIN_CAVE_PASSAGE_RIB_SALT
	case .Worm_Path:
		radius *= 0.90
		salt = TERRAIN_CAVE_BRANCH_SALT
	}
	terrain_density_carve_rough_segment_shaped(
		view,
		key,
		chunk_origin,
		columns,
		from_x,
		from_y,
		from_z,
		to_x,
		to_y,
		to_z,
		radius,
		terrain_density_cave_passage_shape(kind),
		salt,
		biome_id,
	)
}

terrain_density_cave_passage_shape :: proc(
	kind: biomes.CaveNetworkEdgeKind,
) -> TerrainCaveSegmentShape {
	shape := terrain_density_cave_segment_shape_default()
	#partial switch kind {
	case .Canyon:
		shape.radius_x_scale = 1.12
		shape.radius_y_scale = 1.10
		shape.radius_z_scale = 1.06
		shape.radius_noise_scale = 0.20
		shape.radius_neck_scale = 0.10
		shape.radius_swell_scale = 0.28
		shape.radius_endpoint_scale = 0.08
		shape.meander_scale = 0.82
		shape.lift_scale = 0.42
		shape.curve_scale = 0.18
	case .Flooded_Passage:
		shape.radius_x_scale = 1.12
		shape.radius_y_scale = 0.58
		shape.radius_z_scale = 1.10
		shape.radius_noise_scale = 0.12
		shape.radius_neck_scale = 0.08
		shape.radius_swell_scale = 0.18
		shape.radius_endpoint_scale = 0.05
		shape.meander_scale = 0.62
		shape.lift_scale = 0.18
		shape.curve_scale = 0.14
	case .Fracture:
		shape.radius_x_scale = 0.68
		shape.radius_y_scale = 1.12
		shape.radius_z_scale = 0.82
		shape.radius_noise_scale = 0.24
		shape.radius_neck_scale = 0.26
		shape.radius_swell_scale = 0.14
		shape.radius_endpoint_scale = 0.08
		shape.meander_scale = 0.96
		shape.lift_scale = 0.52
		shape.curve_scale = 0.30
	case .Vertical_Shaft:
		shape.radius_x_scale = 0.70
		shape.radius_y_scale = 1.12
		shape.radius_z_scale = 0.70
		shape.radius_noise_scale = 0.12
		shape.radius_neck_scale = 0.12
		shape.radius_swell_scale = 0.12
		shape.radius_endpoint_scale = 0.05
		shape.meander_scale = 0.34
		shape.lift_scale = 0.64
		shape.curve_scale = 0.10
	case .Collapsed_Corridor:
		shape.radius_x_scale = 0.82
		shape.radius_y_scale = 0.58
		shape.radius_z_scale = 1.00
		shape.radius_noise_scale = 0.26
		shape.radius_neck_scale = 0.30
		shape.radius_swell_scale = 0.10
		shape.radius_endpoint_scale = 0.06
		shape.meander_scale = 0.70
		shape.lift_scale = 0.22
		shape.curve_scale = 0.22
	case .Worm_Path:
		shape.radius_x_scale = 0.82
		shape.radius_y_scale = 0.78
		shape.radius_z_scale = 1.18
		shape.radius_noise_scale = 0.30
		shape.radius_neck_scale = 0.18
		shape.radius_swell_scale = 0.24
		shape.radius_endpoint_scale = 0.07
		shape.meander_scale = 1.08
		shape.lift_scale = 0.50
		shape.curve_scale = 0.42
	case .Tunnel:
		shape.radius_y_scale = 0.78
		shape.radius_noise_scale = 0.24
		shape.radius_neck_scale = 0.22
		shape.radius_swell_scale = 0.18
		shape.radius_endpoint_scale = 0.06
		shape.meander_scale = 0.88
		shape.lift_scale = 0.42
		shape.curve_scale = 0.24
	}
	return shape
}

terrain_density_carve_cave_entrance :: proc(
	view: ^world_async.ChunkVoxelView,
	key: biomes.FeatureGridKey,
	chunk_origin: world_async.BlockCoord,
	columns: []TerrainBiomeColumn,
	anchor: biomes.CaveAnchor,
	node: biomes.CaveNetworkNode,
	link_radius: f32,
) {
	opening_radius := math.max(f32(4), anchor.influence_radius_blocks)
	opening_y := opening_radius * 0.45
	if anchor.kind == .Sinkhole || anchor.kind == .Vertical_Shaft {
		opening_y = opening_radius * 1.30
	}

	if anchor.kind == .Cave_Mouth || anchor.kind == .Ravine_Breach {
		terrain_density_carve_cave_mouth(
			view,
			key,
			chunk_origin,
			columns,
			anchor,
			node,
			opening_radius,
		)
		terrain_density_carve_cave_mouth_transition(
			view,
			key,
			chunk_origin,
			columns,
			anchor,
			node,
			opening_radius,
			link_radius,
		)
		return
	} else if anchor.kind == .Sinkhole || anchor.kind == .Vertical_Shaft {
		terrain_density_carve_sinkhole_throat(
			view,
			key,
			chunk_origin,
			columns,
			anchor,
			node,
			opening_radius,
			link_radius,
		)
	} else {
		terrain_density_carve_rough_ellipsoid(
			view,
			key,
			chunk_origin,
			columns,
			anchor.x,
			anchor.y - opening_y * 0.25,
			anchor.z,
			opening_radius * 1.20,
			opening_y,
			opening_radius,
			TERRAIN_CAVE_DETAIL_SALT,
			node.biome_id,
		)
	}

	mid_x := (anchor.x + node.x) * 0.5
	mid_y := (anchor.y + node.y) * 0.5
	mid_z := (anchor.z + node.z) * 0.5
	terrain_density_carve_rough_segment_shaped(
		view,
		key,
		chunk_origin,
		columns,
		anchor.x,
		anchor.y,
		anchor.z,
		mid_x,
		mid_y,
		mid_z,
		math.max(opening_radius * 0.42, link_radius),
		terrain_density_cave_entrance_link_shape(anchor.kind, true),
		TERRAIN_CAVE_DETAIL_SALT,
		node.biome_id,
	)
	terrain_density_carve_rough_segment_shaped(
		view,
		key,
		chunk_origin,
		columns,
		mid_x,
		mid_y,
		mid_z,
		node.x,
		node.y,
		node.z,
		link_radius,
		terrain_density_cave_entrance_link_shape(anchor.kind, false),
		TERRAIN_CAVE_ROUGHNESS_SALT,
		node.biome_id,
	)
}

terrain_density_cave_entrance_link_shape :: proc(
	kind: biomes.CaveAnchorKind,
	near_surface: bool,
) -> TerrainCaveSegmentShape {
	shape := terrain_density_cave_passage_shape(.Tunnel)
	#partial switch kind {
	case .Cave_Mouth, .Ravine_Breach:
		if near_surface {
			shape = terrain_density_cave_passage_shape(.Collapsed_Corridor)
			shape.radius_y_scale = 0.54
			shape.radius_neck_scale = 0.34
			shape.curve_scale = 0.26
		} else {
			shape.radius_y_scale = 0.70
			shape.radius_neck_scale = 0.26
			shape.curve_scale = 0.30
		}
	case .Sinkhole, .Vertical_Shaft:
		if near_surface {
			shape = terrain_density_cave_passage_shape(.Vertical_Shaft)
			shape.radius_x_scale = 0.64
			shape.radius_z_scale = 0.64
			shape.radius_neck_scale = 0.18
			shape.curve_scale = 0.14
		} else {
			shape = terrain_density_cave_passage_shape(.Fracture)
			shape.radius_x_scale = 0.72
			shape.radius_z_scale = 0.78
			shape.curve_scale = 0.24
		}
	case .Lakebed_Breach, .Seabed_Breach, .Underground_River_Source, .Underground_River_Sink:
		shape = terrain_density_cave_passage_shape(.Flooded_Passage)
		shape.radius_neck_scale = 0.14
	}
	return shape
}

terrain_density_cave_entrance_planar_direction :: proc(
	anchor: biomes.CaveAnchor,
	node: biomes.CaveNetworkNode,
) -> (
	dir_x, dir_z: f32,
) {
	dir_x = node.x - anchor.x
	dir_z = node.z - anchor.z
	dir_len := math.sqrt_f32(dir_x * dir_x + dir_z * dir_z)
	if dir_len > 0.001 && anchor.kind != .Cave_Mouth && anchor.kind != .Ravine_Breach {
		return dir_x / dir_len, dir_z / dir_len
	}

	hash := biomes.feature_grid_hash_combine(u64(anchor.id), TERRAIN_CAVE_CURVE_SALT)
	dir_x = biomes.feature_grid_signed_unit_f32(hash, TERRAIN_CAVE_BRANCH_SALT)
	dir_z = biomes.feature_grid_signed_unit_f32(hash, TERRAIN_CAVE_PASSAGE_RIB_SALT)
	dir_len = math.sqrt_f32(dir_x * dir_x + dir_z * dir_z)
	if dir_len <= 0.001 {
		return 0, 1
	}
	return dir_x / dir_len, dir_z / dir_len
}

terrain_density_cave_mouth_size_support :: proc(opening_radius: f32) -> f32 {
	return math.smoothstep(
		TERRAIN_CAVE_MOUTH_SMALL_RADIUS_BLOCKS,
		TERRAIN_CAVE_MOUTH_LARGE_RADIUS_BLOCKS,
		opening_radius,
	)
}

terrain_density_cave_mouth_reach_blocks :: proc(opening_radius: f32) -> f32 {
	size_support := terrain_density_cave_mouth_size_support(opening_radius)
	return(
		opening_radius *
		biomes.regional_terrain_field_lerp(
			TERRAIN_CAVE_MOUTH_SMALL_REACH_SCALE,
			TERRAIN_CAVE_MOUTH_LARGE_REACH_SCALE,
			size_support,
		) \
	)
}

terrain_density_cave_mouth_surface_width_scale :: proc(opening_radius: f32) -> f32 {
	size_support := terrain_density_cave_mouth_size_support(opening_radius)
	return biomes.regional_terrain_field_lerp(
		TERRAIN_CAVE_MOUTH_SMALL_WIDTH_SCALE,
		TERRAIN_CAVE_MOUTH_LARGE_WIDTH_SCALE,
		size_support,
	)
}

terrain_density_cave_mouth_transition_run_blocks :: proc(opening_radius: f32) -> f32 {
	size_support := terrain_density_cave_mouth_size_support(opening_radius)
	return(
		opening_radius *
		biomes.regional_terrain_field_lerp(
			f32(1.70),
			TERRAIN_CAVE_MOUTH_TRANSITION_RUN_SCALE,
			size_support,
		) \
	)
}

terrain_density_cave_mouth_transition_drop_blocks :: proc(opening_radius, total_drop: f32) -> f32 {
	size_support := terrain_density_cave_mouth_size_support(opening_radius)
	drop_limit :=
		opening_radius *
		biomes.regional_terrain_field_lerp(
			f32(1.05),
			TERRAIN_CAVE_MOUTH_TRANSITION_DROP_SCALE,
			size_support,
		)
	return math.min(math.max(f32(3.0), total_drop * 0.32), drop_limit)
}

terrain_density_cave_mouth_near_link_radius :: proc(opening_radius, link_radius: f32) -> f32 {
	size_support := terrain_density_cave_mouth_size_support(opening_radius)
	opening_scaled :=
		opening_radius * biomes.regional_terrain_field_lerp(f32(0.30), f32(0.46), size_support)
	return math.max(f32(1.65), math.min(link_radius, opening_scaled))
}

terrain_density_cave_mouth_transition_style :: proc(
	anchor: biomes.CaveAnchor,
	opening_radius: f32,
) -> TerrainCaveMouthTransitionStyle {
	size_support := terrain_density_cave_mouth_size_support(opening_radius)
	hash := biomes.feature_grid_hash_combine(u64(anchor.id), TERRAIN_CAVE_PASSAGE_RIB_SALT)
	roll := biomes.feature_grid_unit_f32(hash, TERRAIN_CAVE_CURVE_SALT)
	if roll < 0.34 {
		return .Sloped_Tube
	}
	if roll < 0.72 || size_support < TERRAIN_CAVE_MOUTH_VESTIBULE_MIN_SUPPORT {
		return .Curved_Ramp
	}
	return .Spiral_Ramp
}

terrain_density_cave_mouth_transition_scales :: proc(
	style: TerrainCaveMouthTransitionStyle,
) -> TerrainCaveMouthTransitionScales {
	scales := TerrainCaveMouthTransitionScales {
			run_scale          = 1,
			drop_scale         = 1,
			side_scale         = 1,
			vestibule_scale    = 1,
			bend_t             = 0.58,
			bend_return_scale  = 0.55,
			deep_radius_scale  = 0.90,
			near_curve_boost   = 0,
			near_meander_boost = 0,
			deep_curve_boost   = 0.16,
			deep_meander_boost = 0.18,
			deep_lift_boost    = 0,
		}
	switch style {
	case .Sloped_Tube:
		scales.run_scale = 0.92
		scales.side_scale = 0.42
		scales.vestibule_scale = 0.78
		scales.bend_t = 0.64
		scales.bend_return_scale = 0.24
		scales.deep_radius_scale = 0.82
		scales.deep_curve_boost = 0.08
		scales.deep_meander_boost = 0.06
	case .Curved_Ramp:
		scales.drop_scale = 0.94
		scales.side_scale = 1.04
		scales.bend_t = 0.54
		scales.bend_return_scale = 0.68
		scales.near_curve_boost = 0.06
		scales.near_meander_boost = 0.08
		scales.deep_curve_boost = 0.22
		scales.deep_meander_boost = 0.22
	case .Spiral_Ramp:
		scales.run_scale = 1.16
		scales.drop_scale = 0.82
		scales.side_scale = 1.48
		scales.vestibule_scale = 1.16
		scales.bend_t = 0.46
		scales.bend_return_scale = 1.18
		scales.deep_radius_scale = 0.96
		scales.near_curve_boost = 0.14
		scales.near_meander_boost = 0.16
		scales.deep_curve_boost = 0.34
		scales.deep_meander_boost = 0.32
		scales.deep_lift_boost = 0.10
	}
	return scales
}

terrain_density_cave_mouth_transition_bend_extension :: proc(
	style: TerrainCaveMouthTransitionStyle,
	size_support, transition_run: f32,
) -> f32 {
	extension_support := math.smoothstep(
		TERRAIN_CAVE_MOUTH_VESTIBULE_MIN_SUPPORT,
		f32(1),
		size_support,
	)
	switch style {
	case .Curved_Ramp:
		return transition_run * TERRAIN_CAVE_MOUTH_CURVED_BEND_EXTENSION_SCALE * extension_support
	case .Spiral_Ramp:
		return transition_run * TERRAIN_CAVE_MOUTH_SPIRAL_BEND_EXTENSION_SCALE * extension_support
	case .Sloped_Tube:
		small_extension_support :=
			1.0 - math.smoothstep(f32(0), TERRAIN_CAVE_MOUTH_VESTIBULE_MIN_SUPPORT, size_support)
		return(
			transition_run *
			(TERRAIN_CAVE_MOUTH_SMALL_SLOPED_BEND_EXTENSION_SCALE * small_extension_support +
					TERRAIN_CAVE_MOUTH_SLOPED_BEND_EXTENSION_SCALE * extension_support) \
		)
	}
	return 0
}

terrain_density_cave_mouth_transition_plan :: proc(
	anchor: biomes.CaveAnchor,
	node: biomes.CaveNetworkNode,
	opening_radius, link_radius: f32,
) -> TerrainCaveMouthTransitionPlan {
	dir_x, dir_z := terrain_density_cave_entrance_planar_direction(anchor, node)
	side_x := -dir_z
	side_z := dir_x
	size_support := terrain_density_cave_mouth_size_support(opening_radius)
	total_drop := math.max(f32(0), anchor.y - node.y)
	style := terrain_density_cave_mouth_transition_style(anchor, opening_radius)
	scales := terrain_density_cave_mouth_transition_scales(style)
	transition_run :=
		terrain_density_cave_mouth_transition_run_blocks(opening_radius) * scales.run_scale
	transition_drop := math.max(
		f32(3),
		terrain_density_cave_mouth_transition_drop_blocks(opening_radius, total_drop) *
		scales.drop_scale,
	)
	near_radius := terrain_density_cave_mouth_near_link_radius(opening_radius, link_radius)

	hash := biomes.feature_grid_hash_combine(u64(anchor.id), TERRAIN_CAVE_BRANCH_SALT)
	side_sign := biomes.feature_grid_signed_unit_f32(hash, TERRAIN_CAVE_CURVE_SALT)
	if side_sign >= 0 {
		side_sign = 1
	} else {
		side_sign = -1
	}
	side_offset :=
		side_sign *
		opening_radius *
		TERRAIN_CAVE_MOUTH_TRANSITION_SIDE_SCALE *
		biomes.regional_terrain_field_lerp(f32(0.28), f32(1.0), size_support) *
		scales.side_scale

	landing_x := anchor.x + dir_x * transition_run + side_x * side_offset
	landing_y := anchor.y - transition_drop
	landing_z := anchor.z + dir_z * transition_run + side_z * side_offset
	bend_extension := terrain_density_cave_mouth_transition_bend_extension(
		style,
		size_support,
		transition_run,
	)
	bend_x :=
		landing_x +
		(node.x - landing_x) * scales.bend_t -
		side_x * side_offset * scales.bend_return_scale
	bend_z :=
		landing_z +
		(node.z - landing_z) * scales.bend_t -
		side_z * side_offset * scales.bend_return_scale
	bend_y := landing_y + (node.y - landing_y) * scales.bend_t
	if bend_extension > 0 {
		if style == .Curved_Ramp ||
		   (style == .Sloped_Tube && size_support < TERRAIN_CAVE_MOUTH_VESTIBULE_MIN_SUPPORT) {
			bend_x =
				landing_x +
				dir_x * bend_extension -
				side_x * side_offset * scales.bend_return_scale
			bend_z =
				landing_z +
				dir_z * bend_extension -
				side_z * side_offset * scales.bend_return_scale
		} else {
			bend_x += dir_x * bend_extension
			bend_z += dir_z * bend_extension
		}
		bend_run := math.sqrt_f32(
			(bend_x - landing_x) * (bend_x - landing_x) +
			(bend_z - landing_z) * (bend_z - landing_z),
		)
		handoff_run := math.sqrt_f32(
			(node.x - bend_x) * (node.x - bend_x) + (node.z - bend_z) * (node.z - bend_z),
		)
		total_deep_run := math.max(f32(1), bend_run + handoff_run)
		total_deep_drop := math.max(f32(0), landing_y - node.y)
		bend_y = landing_y - total_deep_drop * (bend_run / total_deep_run)
	}
	bend_run_blocks := math.sqrt_f32(
		(bend_x - landing_x) * (bend_x - landing_x) + (bend_z - landing_z) * (bend_z - landing_z),
	)
	handoff_run_blocks := math.sqrt_f32(
		(node.x - bend_x) * (node.x - bend_x) + (node.z - bend_z) * (node.z - bend_z),
	)

	return TerrainCaveMouthTransitionPlan {
		style = style,
		size_support = size_support,
		dir_x = dir_x,
		dir_z = dir_z,
		side_x = side_x,
		side_z = side_z,
		transition_run = transition_run,
		transition_drop = transition_drop,
		near_radius = near_radius,
		side_offset = side_offset,
		landing_x = landing_x,
		landing_y = landing_y,
		landing_z = landing_z,
		bend_x = bend_x,
		bend_y = bend_y,
		bend_z = bend_z,
		near_run_blocks = math.sqrt_f32(
			transition_run * transition_run + side_offset * side_offset,
		),
		near_drop_blocks = math.max(f32(0), anchor.y - landing_y),
		bend_run_blocks = bend_run_blocks,
		bend_drop_blocks = math.max(f32(0), landing_y - bend_y),
		handoff_run_blocks = handoff_run_blocks,
		handoff_drop_blocks = math.max(f32(0), bend_y - node.y),
	}
}

terrain_density_carve_cave_mouth_transition :: proc(
	view: ^world_async.ChunkVoxelView,
	key: biomes.FeatureGridKey,
	chunk_origin: world_async.BlockCoord,
	columns: []TerrainBiomeColumn,
	anchor: biomes.CaveAnchor,
	node: biomes.CaveNetworkNode,
	opening_radius, link_radius: f32,
) {
	plan := terrain_density_cave_mouth_transition_plan(anchor, node, opening_radius, link_radius)
	scales := terrain_density_cave_mouth_transition_scales(plan.style)

	if plan.size_support >= TERRAIN_CAVE_MOUTH_VESTIBULE_MIN_SUPPORT {
		vestibule_radius :=
			opening_radius *
			biomes.regional_terrain_field_lerp(f32(0.36), f32(0.58), plan.size_support) *
			scales.vestibule_scale
		terrain_density_carve_cave_room_lobed_ellipsoid(
			view,
			key,
			chunk_origin,
			columns,
			anchor.x +
			plan.dir_x * plan.transition_run * 0.58 +
			plan.side_x * plan.side_offset * 0.35,
			anchor.y - plan.transition_drop * 0.62,
			anchor.z +
			plan.dir_z * plan.transition_run * 0.58 +
			plan.side_z * plan.side_offset * 0.35,
			vestibule_radius * 1.05,
			math.max(f32(2.0), vestibule_radius * 0.42),
			vestibule_radius * 0.82,
			TERRAIN_CAVE_ROOM_DETAIL_SALT,
			node.biome_id,
			true,
		)
	}

	near_shape := terrain_density_cave_entrance_link_shape(anchor.kind, true)
	near_shape.radius_y_scale *= 0.86
	near_shape.radius_neck_scale += 0.08
	near_shape.curve_scale += scales.near_curve_boost
	near_shape.meander_scale += scales.near_meander_boost
	terrain_density_carve_rough_segment_shaped(
		view,
		key,
		chunk_origin,
		columns,
		anchor.x,
		anchor.y,
		anchor.z,
		plan.landing_x,
		plan.landing_y,
		plan.landing_z,
		plan.near_radius,
		near_shape,
		TERRAIN_CAVE_DETAIL_SALT,
		node.biome_id,
	)

	deep_shape := terrain_density_cave_entrance_link_shape(anchor.kind, false)
	deep_shape.curve_scale += scales.deep_curve_boost
	deep_shape.meander_scale += scales.deep_meander_boost
	deep_shape.lift_scale += scales.deep_lift_boost
	terrain_density_carve_rough_segment_shaped(
		view,
		key,
		chunk_origin,
		columns,
		plan.landing_x,
		plan.landing_y,
		plan.landing_z,
		plan.bend_x,
		plan.bend_y,
		plan.bend_z,
		math.max(plan.near_radius, link_radius * scales.deep_radius_scale),
		deep_shape,
		TERRAIN_CAVE_ROUGHNESS_SALT,
		node.biome_id,
	)
	terrain_density_carve_rough_segment_shaped(
		view,
		key,
		chunk_origin,
		columns,
		plan.bend_x,
		plan.bend_y,
		plan.bend_z,
		node.x,
		node.y,
		node.z,
		link_radius,
		deep_shape,
		TERRAIN_CAVE_BRANCH_SALT,
		node.biome_id,
	)
}

terrain_density_carve_cave_mouth :: proc(
	view: ^world_async.ChunkVoxelView,
	key: biomes.FeatureGridKey,
	chunk_origin: world_async.BlockCoord,
	columns: []TerrainBiomeColumn,
	anchor: biomes.CaveAnchor,
	node: biomes.CaveNetworkNode,
	opening_radius: f32,
) {
	dir_x, dir_z := terrain_density_cave_entrance_planar_direction(anchor, node)
	side_x := -dir_z
	side_z := dir_x
	size_support := terrain_density_cave_mouth_size_support(opening_radius)
	reach := terrain_density_cave_mouth_reach_blocks(opening_radius)
	height := math.max(
		f32(4),
		opening_radius * biomes.regional_terrain_field_lerp(f32(0.70), f32(0.95), size_support),
	)
	mouth_skew := biomes.regional_terrain_field_value_noise_3(
		key,
		i32(math.floor_f32(anchor.x)),
		i32(math.floor_f32(anchor.y)),
		i32(math.floor_f32(anchor.z)),
		28,
		TERRAIN_CAVE_BRANCH_SALT,
	)
	local_min_x, local_max_x, local_min_y, local_max_y, local_min_z, local_max_z, intersects :=
		terrain_density_carve_bounds_from_extents(
			chunk_origin,
			anchor.x - reach - opening_radius * 1.45,
			anchor.x + reach + opening_radius * 1.45,
			anchor.y - height * 1.60,
			anchor.y + 3,
			anchor.z - reach - opening_radius * 1.45,
			anchor.z + reach + opening_radius * 1.45,
		)
	if !intersects {
		return
	}

	for z := local_min_z; z <= local_max_z; z += 1 {
		world_z := f32(chunk_origin.z + z) + 0.5
		for y := local_min_y; y <= local_max_y; y += 1 {
			world_y := f32(chunk_origin.y + y) + 0.5
			for x := local_min_x; x <= local_max_x; x += 1 {
				world_x := f32(chunk_origin.x + x) + 0.5
				column := columns[x + z * CHUNK_BLOCK_LENGTH]
				below_surface := column.surface_height_blocks - world_y
				if below_surface < -1 || below_surface > height * 1.75 {
					continue
				}

				rel_x := world_x - anchor.x
				rel_z := world_z - anchor.z
				forward := rel_x * dir_x + rel_z * dir_z
				if forward < -opening_radius * 0.35 || forward > reach {
					continue
				}
				side := rel_x * side_x + rel_z * side_z
				t := math.clamp(forward / reach, f32(0), f32(1))
				width_base :=
					opening_radius *
					biomes.regional_terrain_field_lerp(
						terrain_density_cave_mouth_surface_width_scale(opening_radius),
						f32(0.42),
						t,
					)
				arch_height := height * biomes.regional_terrain_field_lerp(1.05, 0.46, t)
				lower_arch_support := math.smoothstep(
					arch_height * 0.34,
					arch_height * 0.92,
					below_surface,
				)
				width :=
					width_base *
					terrain_density_cave_mouth_lower_width_scale(t, lower_arch_support)
				side_bias := mouth_skew * opening_radius * 0.14 * (1.0 - t)
				height_unit := below_surface / arch_height
				vertical := height_unit - 0.32
				if vertical > 0 {
					vertical *= 0.78
				} else {
					vertical *= 1.12
				}
				side_normalized := (side - side_bias) / width
				side_abs := math.abs(side_normalized)
				upper_lip_support := math.clamp(
					(f32(0.42) - height_unit) * f32(3.125),
					f32(0),
					f32(1),
				)
				side_shoulder := math.clamp(
					(side_abs - TERRAIN_CAVE_MOUTH_SIDE_SHOULDER_START) *
					TERRAIN_CAVE_MOUTH_SIDE_SHOULDER_INV_RANGE,
					f32(0),
					f32(1),
				)
				center_support := math.clamp(1.0 - side_abs * f32(2.381), f32(0), f32(1))
				jaw_band := math.clamp(
					1.0 - math.abs(side_abs - f32(0.56)) * f32(3.125),
					f32(0),
					f32(1),
				)
				jaw_side_direction := f32(0)
				if side_normalized > 0 {
					jaw_side_direction = 1
				} else if side_normalized < 0 {
					jaw_side_direction = -1
				}
				jaw_asymmetry := math.clamp(
					1.0 + jaw_side_direction * mouth_skew * f32(0.22),
					f32(0.78),
					f32(1.22),
				)
				lower_jaw_relief :=
					lower_arch_support *
					(1.0 - t * 0.78) *
					jaw_band *
					jaw_asymmetry *
					TERRAIN_CAVE_MOUTH_LOWER_JAW_RELIEF_STRENGTH
				upper_center_lip :=
					upper_lip_support *
					(1.0 - t * 0.62) *
					center_support *
					TERRAIN_CAVE_MOUTH_UPPER_LIP_RIB_STRENGTH
				side_alcove_relief :=
					terrain_density_cave_mouth_side_alcove_relief(
						t,
						side_abs,
						lower_arch_support,
						size_support,
					) *
					jaw_asymmetry
				shape :=
					side_normalized * side_normalized +
					vertical * vertical +
					upper_lip_support *
						(1.0 - t * 0.55) *
						side_shoulder *
						TERRAIN_CAVE_MOUTH_SIDE_SHOULDER_STRENGTH -
					lower_arch_support *
						(1.0 - t) *
						center_support *
						TERRAIN_CAVE_MOUTH_CENTER_RELIEF_STRENGTH -
					lower_jaw_relief +
					upper_center_lip -
					side_alcove_relief
				if shape > 1.18 {
					continue
				}
				rough := biomes.regional_terrain_field_value_noise_3(
					key,
					chunk_origin.x + x,
					chunk_origin.y + y,
					chunk_origin.z + z,
					14,
					TERRAIN_CAVE_DETAIL_SALT,
				)
				if shape <= 1.0 + rough * 0.18 {
					terrain_density_carve_local_block_with_material(
						view,
						key,
						chunk_origin,
						columns,
						x,
						y,
						z,
						node.biome_id,
					)
				}
			}
		}
	}
}

terrain_density_cave_mouth_lower_width_scale :: proc(forward_t, lower_arch_support: f32) -> f32 {
	return 1.0 + lower_arch_support * (1.0 - forward_t) * TERRAIN_CAVE_MOUTH_LOWER_WIDTH_BOOST
}

terrain_density_cave_mouth_side_shoulder_penalty :: proc(
	forward_t, side_abs, upper_lip_support: f32,
) -> f32 {
	side_shoulder := math.clamp(
		(side_abs - TERRAIN_CAVE_MOUTH_SIDE_SHOULDER_START) *
		TERRAIN_CAVE_MOUTH_SIDE_SHOULDER_INV_RANGE,
		f32(0),
		f32(1),
	)
	return(
		upper_lip_support *
		(1.0 - forward_t * 0.55) *
		side_shoulder *
		TERRAIN_CAVE_MOUTH_SIDE_SHOULDER_STRENGTH \
	)
}

terrain_density_cave_mouth_lower_center_relief :: proc(
	forward_t, side_abs, lower_arch_support: f32,
) -> f32 {
	center_support := math.clamp(1.0 - side_abs * f32(2.381), f32(0), f32(1))
	return(
		lower_arch_support *
		(1.0 - forward_t) *
		center_support *
		TERRAIN_CAVE_MOUTH_CENTER_RELIEF_STRENGTH \
	)
}

terrain_density_cave_mouth_lower_jaw_relief :: proc(
	forward_t, side_abs, lower_arch_support: f32,
) -> f32 {
	jaw_band := math.clamp(1.0 - math.abs(side_abs - f32(0.56)) * f32(3.125), f32(0), f32(1))
	return(
		lower_arch_support *
		(1.0 - forward_t * 0.78) *
		jaw_band *
		TERRAIN_CAVE_MOUTH_LOWER_JAW_RELIEF_STRENGTH \
	)
}

terrain_density_cave_mouth_upper_lip_rib :: proc(
	forward_t, side_abs, upper_lip_support: f32,
) -> f32 {
	center_support := math.clamp(1.0 - side_abs * f32(2.381), f32(0), f32(1))
	return(
		upper_lip_support *
		(1.0 - forward_t * 0.62) *
		center_support *
		TERRAIN_CAVE_MOUTH_UPPER_LIP_RIB_STRENGTH \
	)
}

terrain_density_cave_mouth_side_alcove_relief :: proc(
	forward_t, side_abs, lower_arch_support, size_support: f32,
) -> f32 {
	forward_band :=
		math.smoothstep(f32(0.08), f32(0.36), forward_t) *
		(1.0 - math.smoothstep(f32(0.70), f32(0.96), forward_t))
	side_band := math.clamp(1.0 - math.abs(side_abs - f32(0.72)) * f32(3.85), f32(0), f32(1))
	size_scale := biomes.regional_terrain_field_lerp(
		TERRAIN_CAVE_MOUTH_SIDE_ALCOVE_SMALL_SCALE,
		TERRAIN_CAVE_MOUTH_SIDE_ALCOVE_LARGE_SCALE,
		size_support,
	)
	return(
		lower_arch_support *
		forward_band *
		side_band *
		TERRAIN_CAVE_MOUTH_SIDE_ALCOVE_RELIEF_STRENGTH *
		size_scale \
	)
}

terrain_density_carve_sinkhole_throat :: proc(
	view: ^world_async.ChunkVoxelView,
	key: biomes.FeatureGridKey,
	chunk_origin: world_async.BlockCoord,
	columns: []TerrainBiomeColumn,
	anchor: biomes.CaveAnchor,
	node: biomes.CaveNetworkNode,
	opening_radius, link_radius: f32,
) {
	depth := math.max(opening_radius * 2.2, anchor.y - node.y)
	dir_x, dir_z := terrain_density_cave_entrance_planar_direction(anchor, node)
	side_x := -dir_z
	side_z := dir_x
	rim_skew := biomes.regional_terrain_field_value_noise_3(
		key,
		i32(math.floor_f32(anchor.x)),
		i32(math.floor_f32(anchor.y)),
		i32(math.floor_f32(anchor.z)),
		31,
		TERRAIN_CAVE_BRANCH_SALT,
	)
	spiral_hash := biomes.feature_grid_hash_combine(u64(anchor.id), TERRAIN_CAVE_CURVE_SALT)
	spiral_roll := biomes.feature_grid_unit_f32(spiral_hash, TERRAIN_CAVE_BRANCH_SALT)
	spiral_strength := math.smoothstep(f32(0.24), f32(0.96), spiral_roll)
	spiral_turn := f32(1)
	if biomes.feature_grid_signed_unit_f32(spiral_hash, TERRAIN_CAVE_PASSAGE_RIB_SALT) < 0 {
		spiral_turn = -1
	}
	spiral_phase :=
		biomes.feature_grid_unit_f32(spiral_hash, TERRAIN_CAVE_DETAIL_SALT) * f32(6.2831855)
	spiral_extent := opening_radius * TERRAIN_SINKHOLE_SPIRAL_OFFSET_SCALE * spiral_strength
	local_min_x, local_max_x, local_min_y, local_max_y, local_min_z, local_max_z, intersects :=
		terrain_density_carve_bounds_from_extents(
			chunk_origin,
			anchor.x - opening_radius * 1.48 - spiral_extent,
			anchor.x + opening_radius * 1.48 + spiral_extent,
			anchor.y - depth - 2,
			anchor.y + 2,
			anchor.z - opening_radius * 1.48 - spiral_extent,
			anchor.z + opening_radius * 1.48 + spiral_extent,
		)
	if !intersects {
		return
	}

	for z := local_min_z; z <= local_max_z; z += 1 {
		world_z := f32(chunk_origin.z + z) + 0.5
		for y := local_min_y; y <= local_max_y; y += 1 {
			world_y := f32(chunk_origin.y + y) + 0.5
			drop := anchor.y - world_y
			if drop < -1 || drop > depth {
				continue
			}
			t := math.clamp(drop / depth, f32(0), f32(1))
			radius := biomes.regional_terrain_field_lerp(opening_radius * 1.18, link_radius, t)
			spiral_support :=
				math.smoothstep(f32(0.08), f32(0.72), t) *
				(1.0 - math.smoothstep(f32(0.82), f32(1.0), t))
			spiral_angle := spiral_phase + spiral_turn * t * f32(5.15)
			spiral_x := dir_x * math.cos(spiral_angle) + side_x * math.sin(spiral_angle)
			spiral_z := dir_z * math.cos(spiral_angle) + side_z * math.sin(spiral_angle)
			center_x :=
				anchor.x +
				dir_x * opening_radius * 0.12 * t +
				spiral_x * spiral_extent * spiral_support
			center_z :=
				anchor.z +
				dir_z * opening_radius * 0.12 * t +
				spiral_z * spiral_extent * spiral_support
			major_radius := radius * terrain_density_sinkhole_major_radius_scale(t)
			minor_radius := radius * terrain_density_sinkhole_minor_radius_scale(t)
			for x := local_min_x; x <= local_max_x; x += 1 {
				world_x := f32(chunk_origin.x + x) + 0.5
				dx := world_x - center_x
				dz := world_z - center_z
				forward := dx * dir_x + dz * dir_z
				side := dx * side_x + dz * side_z
				forward_unit := forward / major_radius
				side_unit := side / minor_radius
				side_abs := math.abs(side_unit)
				forward_abs := math.abs(forward_unit)
				side_direction := f32(0)
				if side_unit > 0 {
					side_direction = 1
				} else if side_unit < 0 {
					side_direction = -1
				}
				ledge_asymmetry := math.clamp(
					1.0 + side_direction * rim_skew * f32(0.20),
					f32(0.82),
					f32(1.18),
				)
				shape :=
					forward_unit * forward_unit +
					side_unit * side_unit +
					terrain_density_sinkhole_rim_lip_penalty(t, forward_abs, side_abs) -
					terrain_density_sinkhole_side_ledge_relief(t, side_abs) * ledge_asymmetry
				if shape > 1.22 {
					continue
				}
				rough := biomes.regional_terrain_field_value_noise_3(
					key,
					chunk_origin.x + x,
					chunk_origin.y + y,
					chunk_origin.z + z,
					12,
					TERRAIN_CAVE_DETAIL_SALT,
				)
				if shape <= 1.0 + rough * 0.22 {
					terrain_density_carve_local_block_with_material(
						view,
						key,
						chunk_origin,
						columns,
						x,
						y,
						z,
						node.biome_id,
					)
				}
			}
		}
	}
}

terrain_density_sinkhole_major_radius_scale :: proc(depth_t: f32) -> f32 {
	return biomes.regional_terrain_field_lerp(f32(1.12), f32(0.92), depth_t)
}

terrain_density_sinkhole_minor_radius_scale :: proc(depth_t: f32) -> f32 {
	return biomes.regional_terrain_field_lerp(f32(0.78), f32(1.02), depth_t)
}

terrain_density_sinkhole_side_ledge_relief :: proc(depth_t, side_abs: f32) -> f32 {
	upper_support := math.clamp(1.0 - depth_t * f32(2.2), f32(0), f32(1))
	side_band := math.clamp(1.0 - math.abs(side_abs - f32(0.56)) * f32(3.125), f32(0), f32(1))
	return upper_support * side_band * TERRAIN_SINKHOLE_SIDE_LEDGE_RELIEF_STRENGTH
}

terrain_density_sinkhole_rim_lip_penalty :: proc(depth_t, forward_abs, side_abs: f32) -> f32 {
	rim_support := math.clamp(1.0 - depth_t * f32(3.4), f32(0), f32(1))
	center_support := math.clamp(1.0 - (forward_abs + side_abs) * f32(0.95), f32(0), f32(1))
	return rim_support * center_support * TERRAIN_SINKHOLE_RIM_LIP_STRENGTH
}

terrain_density_carve_rough_ellipsoid :: proc(
	view: ^world_async.ChunkVoxelView,
	key: biomes.FeatureGridKey,
	chunk_origin: world_async.BlockCoord,
	columns: []TerrainBiomeColumn,
	center_x, center_y, center_z, radius_x, radius_y, radius_z: f32,
	noise_salt: u64,
	biome_id: biomes.BiomeID,
	directional_material_profile: bool = false,
) {
	rx := math.max(f32(1), radius_x)
	ry := math.max(f32(1), radius_y)
	rz := math.max(f32(1), radius_z)
	padding := math.max(rx, math.max(ry, rz)) * 0.18 + 2
	local_min_x, local_max_x, local_min_y, local_max_y, local_min_z, local_max_z, intersects :=
		terrain_density_carve_bounds_from_extents(
			chunk_origin,
			center_x - rx - padding,
			center_x + rx + padding,
			center_y - ry - padding,
			center_y + ry + padding,
			center_z - rz - padding,
			center_z + rz + padding,
		)
	if !intersects {
		return
	}

	for z := local_min_z; z <= local_max_z; z += 1 {
		world_z := f32(chunk_origin.z + z) + 0.5
		for y := local_min_y; y <= local_max_y; y += 1 {
			world_y := f32(chunk_origin.y + y) + 0.5
			for x := local_min_x; x <= local_max_x; x += 1 {
				world_x := f32(chunk_origin.x + x) + 0.5
				nx := (world_x - center_x) / rx
				ny := (world_y - center_y) / ry
				nz := (world_z - center_z) / rz
				shape := nx * nx + ny * ny + nz * nz
				rough := biomes.regional_terrain_field_value_noise_3(
					key,
					chunk_origin.x + x,
					chunk_origin.y + y,
					chunk_origin.z + z,
					24,
					noise_salt,
				)
				core_support := math.clamp((f32(1.0) - shape) * 1.389, f32(0), f32(1))
				rough_scale :=
					TERRAIN_CAVE_ROUGH_ELLIPSOID_EDGE_SCALE -
					(TERRAIN_CAVE_ROUGH_ELLIPSOID_EDGE_SCALE -
							TERRAIN_CAVE_ROUGH_ELLIPSOID_CORE_SCALE) *
						core_support
				threshold := 1.0 + rough * rough_scale
				if shape <= threshold {
					terrain_density_carve_local_block_with_material(
						view,
						key,
						chunk_origin,
						columns,
						x,
						y,
						z,
						biome_id,
						directional_material_profile,
					)
				}
			}
		}
	}
}

terrain_density_cave_segment_shape_default :: proc() -> TerrainCaveSegmentShape {
	return {
		radius_x_scale = 1.10,
		radius_y_scale = 0.88,
		radius_z_scale = 1.05,
		radius_noise_scale = 0.18,
		radius_neck_scale = 0.16,
		radius_swell_scale = 0.20,
		radius_endpoint_scale = 0.0,
		meander_scale = 0.72,
		lift_scale = 0.36,
		curve_scale = 0.0,
	}
}

terrain_density_cave_field_path_shape :: proc() -> TerrainCaveSegmentShape {
	shape := terrain_density_cave_passage_shape(.Worm_Path)
	shape.radius_x_scale = TERRAIN_CAVE_FIELD_PATH_CROSS_AXIS_SCALE
	shape.radius_y_scale = TERRAIN_CAVE_FIELD_PATH_Y_SCALE
	shape.radius_z_scale = TERRAIN_CAVE_FIELD_PATH_CROSS_AXIS_SCALE
	shape.radius_noise_scale = 0.20
	shape.radius_neck_scale = 0.18
	shape.radius_swell_scale = 0.16
	shape.radius_endpoint_scale = 0.03
	shape.meander_scale = 0.46
	shape.lift_scale = 0.20
	shape.curve_scale = 0.18
	return shape
}

terrain_density_cave_passage_radius_profile_scale :: proc(
	shape: TerrainCaveSegmentShape,
	rough, center_bulge: f32,
) -> f32 {
	neck := math.smoothstep(f32(0.18), f32(0.92), -rough)
	swell := math.smoothstep(f32(0.22), f32(0.95), rough)
	scale :=
		1.0 +
		center_bulge * shape.radius_swell_scale * 0.18 +
		swell * shape.radius_swell_scale -
		neck * shape.radius_neck_scale
	return math.clamp(scale, f32(0.72), f32(1.34))
}

terrain_density_cave_segment_triangle_wave :: proc(value: f32) -> f32 {
	phase := value - math.floor_f32(value)
	return 1.0 - math.abs(phase * 2.0 - 1.0)
}

terrain_density_carve_rough_segment_shaped :: proc(
	view: ^world_async.ChunkVoxelView,
	key: biomes.FeatureGridKey,
	chunk_origin: world_async.BlockCoord,
	columns: []TerrainBiomeColumn,
	from_x, from_y, from_z, to_x, to_y, to_z, radius_blocks: f32,
	shape: TerrainCaveSegmentShape,
	noise_salt: u64,
	biome_id: biomes.BiomeID,
	directional_material_profile: bool = false,
) {
	radius := math.max(f32(1), radius_blocks)
	max_radius := radius * 1.45 + 2
	t_min, t_max, intersects := terrain_density_segment_chunk_overlap(
		chunk_origin,
		from_x,
		from_y,
		from_z,
		to_x,
		to_y,
		to_z,
		max_radius,
	)
	if !intersects {
		return
	}

	dx := to_x - from_x
	dy := to_y - from_y
	dz := to_z - from_z
	length := math.sqrt_f32(dx * dx + dy * dy + dz * dz)
	if length <= 0.001 {
		terrain_density_carve_rough_ellipsoid(
			view,
			key,
			chunk_origin,
			columns,
			from_x,
			from_y,
			from_z,
			radius * shape.radius_x_scale,
			radius * shape.radius_y_scale,
			radius * shape.radius_z_scale,
			noise_salt,
			biome_id,
			directional_material_profile,
		)
		return
	}

	length_sq := length * length
	tangent_x := dx / length
	tangent_y := dy / length
	tangent_z := dz / length
	length_xz := math.sqrt_f32(dx * dx + dz * dz)
	side_x := f32(1)
	side_y := f32(0)
	side_z := f32(0)
	if length_xz > 0.001 {
		side_x = -dz / length_xz
		side_z = dx / length_xz
	}
	up_x := side_y * tangent_z - side_z * tangent_y
	up_y := side_z * tangent_x - side_x * tangent_z
	up_z := side_x * tangent_y - side_y * tangent_x

	curve_hash := biomes.feature_grid_hash_mix(key.world_seed)
	curve_hash = biomes.feature_grid_hash_combine(curve_hash, u64(key.generator_version))
	curve_hash = biomes.feature_grid_hash_combine(curve_hash, TERRAIN_CAVE_CURVE_SALT)
	curve_hash = biomes.feature_grid_hash_combine(
		curve_hash,
		biomes.feature_grid_hash_i32(i32(math.floor_f32(from_x))),
	)
	curve_hash = biomes.feature_grid_hash_combine(
		curve_hash,
		biomes.feature_grid_hash_i32(i32(math.floor_f32(from_y))),
	)
	curve_hash = biomes.feature_grid_hash_combine(
		curve_hash,
		biomes.feature_grid_hash_i32(i32(math.floor_f32(from_z))),
	)
	curve_hash = biomes.feature_grid_hash_combine(
		curve_hash,
		biomes.feature_grid_hash_i32(i32(math.floor_f32(to_x))),
	)
	curve_hash = biomes.feature_grid_hash_combine(
		curve_hash,
		biomes.feature_grid_hash_i32(i32(math.floor_f32(to_y))),
	)
	curve_hash = biomes.feature_grid_hash_combine(
		curve_hash,
		biomes.feature_grid_hash_i32(i32(math.floor_f32(to_z))),
	)
	curve_side := biomes.feature_grid_signed_unit_f32(curve_hash, TERRAIN_CAVE_CURVE_SALT)
	curve_lift := biomes.feature_grid_signed_unit_f32(curve_hash, TERRAIN_CAVE_BRANCH_SALT)
	branch_side := biomes.feature_grid_signed_unit_f32(
		curve_hash,
		TERRAIN_CAVE_FIELD_SPAGHETTI_A_SALT,
	)
	branch_lift := biomes.feature_grid_signed_unit_f32(
		curve_hash,
		TERRAIN_CAVE_FIELD_SPAGHETTI_B_SALT,
	)
	neck_phase := biomes.feature_grid_unit_f32(curve_hash, TERRAIN_CAVE_PASSAGE_RIB_SALT)

	max_shape_scale := math.max(
		shape.radius_y_scale,
		math.max(shape.radius_x_scale, shape.radius_z_scale),
	)
	max_curve_extent :=
		radius * (shape.curve_scale + shape.meander_scale * 0.42 + shape.lift_scale * 0.28)
	max_carve_radius := radius * max_shape_scale * 1.46 + max_curve_extent + 2
	seg_min_x := math.min(from_x + dx * t_min, from_x + dx * t_max) - max_carve_radius
	seg_max_x := math.max(from_x + dx * t_min, from_x + dx * t_max) + max_carve_radius
	seg_min_y := math.min(from_y + dy * t_min, from_y + dy * t_max) - max_carve_radius
	seg_max_y := math.max(from_y + dy * t_min, from_y + dy * t_max) + max_carve_radius
	seg_min_z := math.min(from_z + dz * t_min, from_z + dz * t_max) - max_carve_radius
	seg_max_z := math.max(from_z + dz * t_min, from_z + dz * t_max) + max_carve_radius
	local_min_x, local_max_x, local_min_y, local_max_y, local_min_z, local_max_z, bounds_intersects :=
		terrain_density_carve_bounds_from_extents(
			chunk_origin,
			seg_min_x,
			seg_max_x,
			seg_min_y,
			seg_max_y,
			seg_min_z,
			seg_max_z,
		)
	if !bounds_intersects {
		return
	}

	horizontal_radius_scale := (shape.radius_x_scale + shape.radius_z_scale) * 0.5
	for z := local_min_z; z <= local_max_z; z += 1 {
		world_z := f32(chunk_origin.z + z) + 0.5
		for y := local_min_y; y <= local_max_y; y += 1 {
			world_y := f32(chunk_origin.y + y) + 0.5
			for x := local_min_x; x <= local_max_x; x += 1 {
				world_x := f32(chunk_origin.x + x) + 0.5
				rel_from_x := world_x - from_x
				rel_from_y := world_y - from_y
				rel_from_z := world_z - from_z
				raw_t := (rel_from_x * dx + rel_from_y * dy + rel_from_z * dz) / length_sq
				if raw_t < -max_carve_radius / length || raw_t > 1.0 + max_carve_radius / length {
					continue
				}
				t := math.clamp(raw_t, f32(0), f32(1))
				center_bulge := 1.0 - math.abs(t * 2.0 - 1.0)
				s_curve :=
					center_bulge *
					(curve_side * shape.curve_scale +
							branch_side * shape.meander_scale * (t * 2.0 - 1.0) * 0.42)
				u_curve :=
					center_bulge *
					(curve_lift * shape.curve_scale * 0.45 +
							branch_lift * shape.lift_scale * (t * 2.0 - 1.0) * 0.28)
				cx := from_x + dx * t + side_x * s_curve * radius + up_x * u_curve * radius
				cy := from_y + dy * t + side_y * s_curve * radius + up_y * u_curve * radius
				cz := from_z + dz * t + side_z * s_curve * radius + up_z * u_curve * radius
				rel_x := world_x - cx
				rel_y := world_y - cy
				rel_z := world_z - cz
				side_dist := rel_x * side_x + rel_y * side_y + rel_z * side_z
				up_dist := rel_x * up_x + rel_y * up_y + rel_z * up_z
				along_dist := rel_x * tangent_x + rel_y * tangent_y + rel_z * tangent_z
				neck_wave := terrain_density_cave_segment_triangle_wave(t * 2.35 + neck_phase)
				profile_scale := math.clamp(
					0.90 +
					center_bulge * 0.10 +
					(1.0 - center_bulge) * shape.radius_endpoint_scale +
					(1.0 - neck_wave) * shape.radius_swell_scale * 0.12 -
					neck_wave * shape.radius_neck_scale * 0.16,
					f32(0.66),
					f32(1.30),
				)
				base_radius := radius * profile_scale
				side_radius := math.max(f32(0.75), base_radius * horizontal_radius_scale)
				up_radius := math.max(f32(0.75), base_radius * shape.radius_y_scale)
				along_radius := math.max(f32(0.75), base_radius * 1.10)
				shape_value :=
					(side_dist * side_dist) / (side_radius * side_radius) +
					(up_dist * up_dist) / (up_radius * up_radius) +
					(along_dist * along_dist) / (along_radius * along_radius)
				if shape_value > 1.30 {
					continue
				}
				rough := biomes.regional_terrain_field_value_noise_3(
					key,
					chunk_origin.x + x,
					chunk_origin.y + y,
					chunk_origin.z + z,
					18,
					noise_salt,
				)
				core_support := math.clamp((f32(1.0) - shape_value) * 1.389, f32(0), f32(1))
				rough_scale :=
					shape.radius_noise_scale *
					biomes.regional_terrain_field_lerp(f32(0.58), f32(0.22), core_support)
				threshold :=
					1.0 +
					rough *
						rough_scale *
						terrain_density_cave_passage_radius_profile_scale(
							shape,
							rough,
							center_bulge,
						)
				if shape_value <= threshold {
					terrain_density_carve_local_block_with_material(
						view,
						key,
						chunk_origin,
						columns,
						x,
						y,
						z,
						biome_id,
						directional_material_profile,
					)
				}
			}
		}
	}
}

terrain_density_carve_local_block_with_material :: proc(
	view: ^world_async.ChunkVoxelView,
	key: biomes.FeatureGridKey,
	chunk_origin: world_async.BlockCoord,
	columns: []TerrainBiomeColumn,
	local_x, local_y, local_z: i32,
	biome_id: biomes.BiomeID,
	directional_material_profile: bool = false,
) {
	_ = terrain_density_carve_local_block_with_material_result(
		view,
		key,
		chunk_origin,
		columns,
		local_x,
		local_y,
		local_z,
		biome_id,
		directional_material_profile,
	)
}

terrain_density_carve_local_block_with_material_result :: proc(
	view: ^world_async.ChunkVoxelView,
	key: biomes.FeatureGridKey,
	chunk_origin: world_async.BlockCoord,
	columns: []TerrainBiomeColumn,
	local_x, local_y, local_z: i32,
	biome_id: biomes.BiomeID,
	directional_material_profile: bool = false,
) -> bool {
	world_y := chunk_origin.y + local_y
	vertical_support := terrain_density_cave_vertical_support(f32(world_y))
	if vertical_support <= 0 {
		return false
	}
	if vertical_support < 0.98 {
		edge_roll := biomes.regional_terrain_field_value_noise_3(
			key,
			chunk_origin.x + local_x,
			world_y,
			chunk_origin.z + local_z,
			9,
			TERRAIN_CAVE_VERTICAL_CUSHION_SALT,
		)
		if math.clamp(0.5 + edge_roll * 0.5, f32(0), f32(1)) > vertical_support {
			return false
		}
	}

	column := columns[local_x + local_z * CHUNK_BLOCK_LENGTH]
	if !terrain_density_surface_is_solid(column, world_y) {
		return false
	}

	index := chunk_block_index(u32(local_x), u32(local_y), u32(local_z))
	if view.blocks.occupancy[index] != .Solid {
		return false
	}
	if terrain_material_palette_index(view.blocks.material_id[index]) == TERRAIN_WATER_MAT_ID {
		return false
	}

	view.blocks.occupancy[index] = .Empty
	view.blocks.material_id[index] = world_async.BlockMaterialID(0)
	terrain_density_mark_cave_wall_neighbors(
		view,
		local_x,
		local_y,
		local_z,
		biome_id,
		directional_material_profile,
	)
	return true
}

terrain_density_fill_local_water_block :: proc(
	view: ^world_async.ChunkVoxelView,
	local_x, local_y, local_z: i32,
) {
	index := chunk_block_index(u32(local_x), u32(local_y), u32(local_z))
	if view.blocks.occupancy[index] != .Empty {
		return
	}
	view.blocks.occupancy[index] = .Solid
	view.blocks.material_id[index] = world_async.BlockMaterialID(TERRAIN_WATER_MAT_ID)
}

terrain_density_cave_vertical_support :: proc(world_y: f32) -> f32 {
	bottom_support := math.smoothstep(
		TERRAIN_CAVE_BOTTOM_CUSHION_START_BLOCKS,
		TERRAIN_CAVE_BOTTOM_CUSHION_END_BLOCKS,
		world_y,
	)
	top_support :=
		1.0 -
		math.smoothstep(
			TERRAIN_CAVE_TOP_CUSHION_START_BLOCKS,
			TERRAIN_CAVE_TOP_CUSHION_END_BLOCKS,
			world_y,
		)
	return math.clamp(bottom_support * top_support, f32(0), f32(1))
}

terrain_density_mark_cave_wall_neighbors :: proc(
	view: ^world_async.ChunkVoxelView,
	local_x, local_y, local_z: i32,
	biome_id: biomes.BiomeID,
	directional_material_profile: bool = false,
) {
	wall_material_id: world_async.BlockMaterialID
	floor_material_id: world_async.BlockMaterialID
	ceiling_material_id: world_async.BlockMaterialID
	if directional_material_profile {
		wall_material_id, floor_material_id, ceiling_material_id = terrain_cave_material_profile(
			biome_id,
		)
	} else {
		wall_material_id = terrain_cave_wall_material_id(biome_id)
		floor_material_id = wall_material_id
		ceiling_material_id = wall_material_id
	}
	offsets := [?]world_async.BlockCoord {
		{x = 1, y = 0, z = 0},
		{x = -1, y = 0, z = 0},
		{x = 0, y = 1, z = 0},
		{x = 0, y = -1, z = 0},
		{x = 0, y = 0, z = 1},
		{x = 0, y = 0, z = -1},
	}
	for offset in offsets {
		x := local_x + offset.x
		y := local_y + offset.y
		z := local_z + offset.z
		if !chunk_block_coord_is_inside(x, y, z) {
			continue
		}
		index := chunk_block_index(u32(x), u32(y), u32(z))
		if view.blocks.occupancy[index] != .Solid {
			continue
		}
		if terrain_material_palette_index(view.blocks.material_id[index]) == TERRAIN_WATER_MAT_ID {
			continue
		}
		material_id := wall_material_id
		if offset.y < 0 {
			material_id = floor_material_id
		} else if offset.y > 0 {
			material_id = ceiling_material_id
		}
		view.blocks.material_id[index] = material_id
	}
}

terrain_cave_material_profile :: proc(
	biome_id: biomes.BiomeID,
) -> (
	wall_material_id, floor_material_id, ceiling_material_id: world_async.BlockMaterialID,
) {
	switch biome_id {
	case .Fungal_Vaults:
		return world_async.BlockMaterialID(
			TERRAIN_WET_MARSH_MAT_ID,
		), world_async.BlockMaterialID(TERRAIN_GRASS_MAT_ID), world_async.BlockMaterialID(TERRAIN_DIRT_MAT_ID)
	case .Crystal_Geode_Network:
		return world_async.BlockMaterialID(
			TERRAIN_CRYSTAL_MAT_ID,
		), world_async.BlockMaterialID(TERRAIN_STONE_MAT_ID), world_async.BlockMaterialID(TERRAIN_CRYSTAL_MAT_ID)
	case .Buried_Aquifer_Caves:
		return world_async.BlockMaterialID(
			TERRAIN_AQUIFER_WALL_MAT_ID,
		), world_async.BlockMaterialID(TERRAIN_WET_MARSH_MAT_ID), world_async.BlockMaterialID(TERRAIN_STONE_MAT_ID)
	case .Temperate_Hills, .Basalt_Spire_Highlands, .Wet_Lowland_Marsh, .Corrupted_Ash_Forest:
		return world_async.BlockMaterialID(
			TERRAIN_STONE_MAT_ID,
		), world_async.BlockMaterialID(TERRAIN_STONE_MAT_ID), world_async.BlockMaterialID(TERRAIN_STONE_MAT_ID)
	}
	return world_async.BlockMaterialID(
		TERRAIN_STONE_MAT_ID,
	), world_async.BlockMaterialID(TERRAIN_STONE_MAT_ID), world_async.BlockMaterialID(TERRAIN_STONE_MAT_ID)
}

terrain_cave_wall_material_id :: proc(biome_id: biomes.BiomeID) -> world_async.BlockMaterialID {
	switch biome_id {
	case .Fungal_Vaults:
		return world_async.BlockMaterialID(TERRAIN_WET_MARSH_MAT_ID)
	case .Crystal_Geode_Network:
		return world_async.BlockMaterialID(TERRAIN_CRYSTAL_MAT_ID)
	case .Buried_Aquifer_Caves:
		return world_async.BlockMaterialID(TERRAIN_AQUIFER_WALL_MAT_ID)
	case .Temperate_Hills, .Basalt_Spire_Highlands, .Wet_Lowland_Marsh, .Corrupted_Ash_Forest:
		return world_async.BlockMaterialID(TERRAIN_STONE_MAT_ID)
	}
	return world_async.BlockMaterialID(TERRAIN_STONE_MAT_ID)
}

terrain_cave_wall_material_id_for_neighbor :: proc(
	biome_id: biomes.BiomeID,
	offset: world_async.BlockCoord,
) -> world_async.BlockMaterialID {
	if offset.y < 0 {
		return terrain_cave_floor_material_id(biome_id)
	}
	if offset.y > 0 {
		return terrain_cave_ceiling_material_id(biome_id)
	}
	return terrain_cave_wall_material_id(biome_id)
}

terrain_cave_floor_material_id :: proc(biome_id: biomes.BiomeID) -> world_async.BlockMaterialID {
	_, floor_material_id, _ := terrain_cave_material_profile(biome_id)
	return floor_material_id
}

terrain_cave_ceiling_material_id :: proc(biome_id: biomes.BiomeID) -> world_async.BlockMaterialID {
	_, _, ceiling_material_id := terrain_cave_material_profile(biome_id)
	return ceiling_material_id
}

terrain_density_segment_chunk_overlap :: proc(
	chunk_origin: world_async.BlockCoord,
	from_x, from_y, from_z, to_x, to_y, to_z, radius: f32,
) -> (
	t_min, t_max: f32,
	intersects: bool,
) {
	min_x := f32(chunk_origin.x) - radius
	min_y := f32(chunk_origin.y) - radius
	min_z := f32(chunk_origin.z) - radius
	max_x := f32(chunk_origin.x + CHUNK_BLOCK_LENGTH) + radius
	max_y := f32(chunk_origin.y + CHUNK_BLOCK_LENGTH) + radius
	max_z := f32(chunk_origin.z + CHUNK_BLOCK_LENGTH) + radius

	t_min = f32(0)
	t_max = f32(1)
	if !terrain_density_segment_axis_intersects_slab(
		from_x,
		to_x - from_x,
		min_x,
		max_x,
		&t_min,
		&t_max,
	) {
		return 0, 0, false
	}
	if !terrain_density_segment_axis_intersects_slab(
		from_y,
		to_y - from_y,
		min_y,
		max_y,
		&t_min,
		&t_max,
	) {
		return 0, 0, false
	}
	if !terrain_density_segment_axis_intersects_slab(
		from_z,
		to_z - from_z,
		min_z,
		max_z,
		&t_min,
		&t_max,
	) {
		return 0, 0, false
	}
	return t_min, t_max, true
}

terrain_density_segment_axis_intersects_slab :: proc(
	start, delta, slab_min, slab_max: f32,
	t_min, t_max: ^f32,
) -> bool {
	if math.abs(delta) <= 0.00001 {
		return start >= slab_min && start <= slab_max
	}

	inv_delta := 1.0 / delta
	t1 := (slab_min - start) * inv_delta
	t2 := (slab_max - start) * inv_delta
	if t1 > t2 {
		t1, t2 = t2, t1
	}
	t_min^ = math.max(t_min^, t1)
	t_max^ = math.min(t_max^, t2)
	return t_min^ <= t_max^
}

terrain_water_volume_fill :: proc(
	view: ^world_async.ChunkVoxelView,
	chunk_origin: world_async.BlockCoord,
	columns: []TerrainBiomeColumn,
) {
	log.assertf(
		len(columns) == CHUNK_BLOCK_LENGTH * CHUNK_BLOCK_LENGTH,
		"terrain water column target count mismatch: %d",
		len(columns),
	)

	for z in 0 ..< CHUNK_BLOCK_LENGTH {
		for x in 0 ..< CHUNK_BLOCK_LENGTH {
			column := columns[x + z * CHUNK_BLOCK_LENGTH]
			if !column.water_fill_active {
				continue
			}

			water_level := i32(math.floor_f32(column.water_level_blocks))
			if water_level < chunk_origin.y {
				continue
			}

			for y in 0 ..< CHUNK_BLOCK_LENGTH {
				world_y := chunk_origin.y + i32(y)
				if world_y > water_level {
					break
				}

				index := chunk_block_index(u32(x), u32(y), u32(z))
				if view.blocks.occupancy[index] == .Solid {
					continue
				}

				view.blocks.occupancy[index] = .Solid
				view.blocks.material_id[index] = world_async.BlockMaterialID(TERRAIN_WATER_MAT_ID)
			}
		}
	}
}

terrain_density_carve_bounds_from_extents :: proc(
	chunk_origin: world_async.BlockCoord,
	min_world_x, max_world_x, min_world_y, max_world_y, min_world_z, max_world_z: f32,
) -> (
	local_min_x, local_max_x, local_min_y, local_max_y, local_min_z, local_max_z: i32,
	intersects: bool,
) {
	min_x := i32(math.floor_f32(min_world_x)) - chunk_origin.x
	max_x := i32(math.floor_f32(max_world_x)) - chunk_origin.x
	min_y := i32(math.floor_f32(min_world_y)) - chunk_origin.y
	max_y := i32(math.floor_f32(max_world_y)) - chunk_origin.y
	min_z := i32(math.floor_f32(min_world_z)) - chunk_origin.z
	max_z := i32(math.floor_f32(max_world_z)) - chunk_origin.z

	if max_x < 0 ||
	   max_y < 0 ||
	   max_z < 0 ||
	   min_x >= CHUNK_BLOCK_LENGTH ||
	   min_y >= CHUNK_BLOCK_LENGTH ||
	   min_z >= CHUNK_BLOCK_LENGTH {
		return 0, 0, 0, 0, 0, 0, false
	}

	local_min_x = math.clamp(min_x, 0, CHUNK_BLOCK_LENGTH - 1)
	local_max_x = math.clamp(max_x, 0, CHUNK_BLOCK_LENGTH - 1)
	local_min_y = math.clamp(min_y, 0, CHUNK_BLOCK_LENGTH - 1)
	local_max_y = math.clamp(max_y, 0, CHUNK_BLOCK_LENGTH - 1)
	local_min_z = math.clamp(min_z, 0, CHUNK_BLOCK_LENGTH - 1)
	local_max_z = math.clamp(max_z, 0, CHUNK_BLOCK_LENGTH - 1)
	intersects = true
	return
}

terrain_cave_debug_column_mask_build :: proc(
	mask: ^TerrainCaveDebugColumnMask,
	region: ^biomes.GenerationRegion,
	chunk_origin: world_async.BlockCoord,
) {
	for z := u32(0); z < CHUNK_BLOCK_LENGTH; z += 1 {
		mask[z] = 0
	}

	for i := u32(0); i < region.cave_network_node_count; i += 1 {
		node := region.cave_network_nodes[i]
		terrain_cave_debug_column_mask_add_circle(
			mask,
			chunk_origin,
			node.x,
			node.z,
			node.radius_blocks * 0.32 + biomes.CAVE_NETWORK_DEBUG_SURFACE_FALLOFF_BLOCKS,
		)
	}

	for i := u32(0); i < region.cave_network_edge_count; i += 1 {
		edge := region.cave_network_edges[i]
		terrain_cave_debug_column_mask_add_segment(
			mask,
			chunk_origin,
			edge.from_x,
			edge.from_z,
			edge.bend_x,
			edge.bend_z,
			math.max(f32(3), edge.radius_blocks * 0.24) +
			biomes.CAVE_NETWORK_DEBUG_SURFACE_FALLOFF_BLOCKS,
		)
		terrain_cave_debug_column_mask_add_segment(
			mask,
			chunk_origin,
			edge.bend_x,
			edge.bend_z,
			edge.to_x,
			edge.to_z,
			math.max(f32(3), edge.radius_blocks * 0.24) +
			biomes.CAVE_NETWORK_DEBUG_SURFACE_FALLOFF_BLOCKS,
		)
	}

	for i := u32(0); i < region.cave_anchor_count; i += 1 {
		anchor := region.cave_anchors[i]
		terrain_cave_debug_column_mask_add_circle(
			mask,
			chunk_origin,
			anchor.x,
			anchor.z,
			math.max(f32(4), anchor.influence_radius_blocks * 0.45) +
			biomes.CAVE_NETWORK_DEBUG_SURFACE_FALLOFF_BLOCKS,
		)
	}
}

terrain_cave_debug_column_mask_add_circle :: proc(
	mask: ^TerrainCaveDebugColumnMask,
	chunk_origin: world_async.BlockCoord,
	center_x, center_z, radius_blocks: f32,
) {
	radius := math.max(f32(0), radius_blocks)
	local_min_x, local_max_x, local_min_z, local_max_z, intersects :=
		terrain_cave_debug_column_bounds(chunk_origin, center_x, center_z, radius)
	if !intersects {
		return
	}

	radius_sq := radius * radius
	for z := local_min_z; z <= local_max_z; z += 1 {
		world_z := f32(chunk_origin.z + z) + 0.5
		for x := local_min_x; x <= local_max_x; x += 1 {
			world_x := f32(chunk_origin.x + x) + 0.5
			dx := world_x - center_x
			dz := world_z - center_z
			if dx * dx + dz * dz <= radius_sq {
				mask[z] |= u64(1) << u32(x)
			}
		}
	}
}

terrain_cave_debug_column_mask_add_segment :: proc(
	mask: ^TerrainCaveDebugColumnMask,
	chunk_origin: world_async.BlockCoord,
	from_x, from_z, to_x, to_z, radius_blocks: f32,
) {
	radius := math.max(f32(0), radius_blocks)
	local_min_x, local_max_x, local_min_z, local_max_z, intersects :=
		terrain_cave_debug_column_bounds_from_extents(
			chunk_origin,
			math.min(from_x, to_x) - radius,
			math.max(from_x, to_x) + radius,
			math.min(from_z, to_z) - radius,
			math.max(from_z, to_z) + radius,
		)
	if !intersects {
		return
	}

	radius_sq := radius * radius
	for z := local_min_z; z <= local_max_z; z += 1 {
		world_z := f32(chunk_origin.z + z) + 0.5
		for x := local_min_x; x <= local_max_x; x += 1 {
			world_x := f32(chunk_origin.x + x) + 0.5
			if terrain_cave_debug_distance_sq_to_segment_2(
				   world_x,
				   world_z,
				   from_x,
				   from_z,
				   to_x,
				   to_z,
			   ) <=
			   radius_sq {
				mask[z] |= u64(1) << u32(x)
			}
		}
	}
}

terrain_cave_debug_column_bounds :: proc(
	chunk_origin: world_async.BlockCoord,
	center_x, center_z, radius_blocks: f32,
) -> (
	local_min_x, local_max_x, local_min_z, local_max_z: i32,
	intersects: bool,
) {
	return terrain_cave_debug_column_bounds_from_extents(
		chunk_origin,
		center_x - radius_blocks,
		center_x + radius_blocks,
		center_z - radius_blocks,
		center_z + radius_blocks,
	)
}

terrain_cave_debug_column_bounds_from_extents :: proc(
	chunk_origin: world_async.BlockCoord,
	min_world_x, max_world_x, min_world_z, max_world_z: f32,
) -> (
	local_min_x, local_max_x, local_min_z, local_max_z: i32,
	intersects: bool,
) {
	min_x := i32(math.floor_f32(min_world_x)) - chunk_origin.x
	max_x := i32(math.floor_f32(max_world_x)) - chunk_origin.x
	min_z := i32(math.floor_f32(min_world_z)) - chunk_origin.z
	max_z := i32(math.floor_f32(max_world_z)) - chunk_origin.z

	if max_x < 0 || max_z < 0 || min_x >= CHUNK_BLOCK_LENGTH || min_z >= CHUNK_BLOCK_LENGTH {
		return 0, 0, 0, 0, false
	}

	local_min_x = math.clamp(min_x, 0, CHUNK_BLOCK_LENGTH - 1)
	local_max_x = math.clamp(max_x, 0, CHUNK_BLOCK_LENGTH - 1)
	local_min_z = math.clamp(min_z, 0, CHUNK_BLOCK_LENGTH - 1)
	local_max_z = math.clamp(max_z, 0, CHUNK_BLOCK_LENGTH - 1)
	intersects = true
	return
}

terrain_cave_debug_distance_sq_to_segment_2 :: proc(x, z, from_x, from_z, to_x, to_z: f32) -> f32 {
	seg_x := to_x - from_x
	seg_z := to_z - from_z
	len_sq := seg_x * seg_x + seg_z * seg_z
	if len_sq <= 0 {
		dx := x - from_x
		dz := z - from_z
		return dx * dx + dz * dz
	}
	t := math.clamp(((x - from_x) * seg_x + (z - from_z) * seg_z) / len_sq, f32(0), f32(1))
	nearest_x := from_x + seg_x * t
	nearest_z := from_z + seg_z * t
	dx := x - nearest_x
	dz := z - nearest_z
	return dx * dx + dz * dz
}

terrain_generation_key_make :: proc(seed: u32) -> biomes.FeatureGridKey {
	return biomes.feature_grid_key_make(u64(seed), TERRAIN_GENERATOR_VERSION)
}

terrain_generation_region_for_fill :: proc(
	key: biomes.FeatureGridKey,
	coord: biomes.GenerationRegionCoord,
) -> biomes.GenerationRegion {
	cache := &state.terrain_generation_region_cache

	sync.lock(&cache.mutex)
	cache.clock += 1
	stamp := cache.clock
	lru_index := u32(0)
	lru_stamp := max(u64)
	empty_index: i32 = -1
	for i := u32(0); i < TERRAIN_GENERATION_REGION_CACHE_CAPACITY; i += 1 {
		slot := &cache.slots[i]
		if slot.valid {
			if slot.key == key && slot.coord == coord {
				slot.last_used = stamp
				region := slot.region
				sync.unlock(&cache.mutex)
				return region
			}
			if slot.last_used < lru_stamp {
				lru_stamp = slot.last_used
				lru_index = i
			}
		} else if empty_index < 0 {
			empty_index = i32(i)
		}
	}
	sync.unlock(&cache.mutex)

	region := biomes.generation_region_build_for_terrain_fill(key, coord)

	sync.lock(&cache.mutex)
	cache.clock += 1
	target_index := lru_index
	if empty_index >= 0 {
		target_index = u32(empty_index)
	}
	cache.slots[target_index] = {
			valid     = true,
			key       = key,
			coord     = coord,
			region    = region,
			last_used = cache.clock,
		}
	sync.unlock(&cache.mutex)

	return region
}

terrain_biome_column_sample :: proc(
	key: biomes.FeatureGridKey,
	surface_sample: biomes.SurfaceBiomeFieldSample,
	world_x, world_z: i32,
) -> TerrainBiomeColumn {
	evaluation := biomes.surface_biome_profile_evaluate(key, surface_sample, world_x, world_z)
	return terrain_biome_column_from_profile_evaluation(key, evaluation, world_x, world_z)
}

terrain_biome_column_sample_with_hydrology :: proc(
	key: biomes.FeatureGridKey,
	surface_sample: biomes.SurfaceBiomeFieldSample,
	hydrology_sample: biomes.HydrologyLayerSurfaceSample,
	world_x, world_z: i32,
) -> TerrainBiomeColumn {
	evaluation := biomes.surface_biome_profile_evaluate_with_hydrology(
		key,
		surface_sample,
		hydrology_sample,
		world_x,
		world_z,
	)
	return terrain_biome_column_from_profile_evaluation(key, evaluation, world_x, world_z)
}

terrain_biome_column_from_profile_evaluation :: proc(
	key: biomes.FeatureGridKey,
	evaluation: biomes.SurfaceBiomeProfileEvaluation,
	world_x, world_z: i32,
) -> TerrainBiomeColumn {
	target := evaluation.final_target
	material_biome_id := terrain_biome_material_biome_pick(key, evaluation, world_x, world_z)
	surface_height_blocks := terrain_surface_height_apply_vertical_cushion(
		target.surface_height_blocks,
	)
	height := i32(math.floor_f32(surface_height_blocks))

	surface_layer_depth := terrain_biome_layer_depth_ceil(target.surface_layer_depth_blocks)
	surface_layer_depth = math.clamp(surface_layer_depth, 1, CHUNK_BLOCK_LENGTH)
	water_influence := math.max(
		evaluation.hydrology_sample.basin_influence,
		evaluation.hydrology_sample.channel_influence,
	)
	sea_fill_active := surface_height_blocks < biomes.SEA_LEVEL_BLOCKS
	local_water_level := evaluation.hydrology_sample.water_level_blocks
	water_surface_below_level := surface_height_blocks < local_water_level
	local_water_fill_active :=
		water_influence > TERRAIN_LOCAL_WATER_FILL_INFLUENCE_MIN && water_surface_below_level
	water_level := biomes.SEA_LEVEL_BLOCKS
	if local_water_fill_active {
		water_level = math.max(biomes.SEA_LEVEL_BLOCKS, local_water_level)
	}
	surface_material_id := terrain_biome_surface_material_id(material_biome_id)
	surface_material_id = terrain_surface_material_apply_shoreline(
		key,
		evaluation,
		surface_material_id,
		surface_height_blocks,
		water_level,
		world_x,
		world_z,
	)
	subsurface_material_id := terrain_biome_subsurface_material_id(material_biome_id)
	subsurface_material_id = terrain_subsurface_material_apply_shoreline(
		evaluation,
		subsurface_material_id,
		surface_height_blocks,
		water_level,
	)
	if surface_material_id == world_async.BlockMaterialID(TERRAIN_WET_MARSH_MAT_ID) {
		subsurface_material_id = surface_material_id
	}
	surface_layer_depth = terrain_surface_layer_depth_apply_shoreline(
		evaluation,
		surface_layer_depth,
		surface_height_blocks,
		water_level,
	)

	return {
		surface_height = height,
		surface_height_blocks = surface_height_blocks,
		surface_layer_depth = surface_layer_depth,
		dominant_biome_id = target.biome_id,
		surface_material_id = surface_material_id,
		subsurface_material_id = subsurface_material_id,
		hydrology_debug_material_active = local_water_fill_active,
		water_fill_active = sea_fill_active || local_water_fill_active,
		water_level_blocks = water_level,
	}
}

terrain_biome_column_sample_direct :: proc(
	key: biomes.FeatureGridKey,
	world_x, world_z: i32,
) -> TerrainBiomeColumn {
	surface_sample := biomes.surface_biome_field_sample(key, world_x, world_z)
	return terrain_biome_column_sample(key, surface_sample, world_x, world_z)
}

terrain_surface_height_apply_vertical_cushion :: proc(height_blocks: f32) -> f32 {
	height := height_blocks
	if height > TERRAIN_SURFACE_HEIGHT_TOP_SOFT_START_BLOCKS {
		range_blocks :=
			TERRAIN_SURFACE_HEIGHT_TOP_LIMIT_BLOCKS - TERRAIN_SURFACE_HEIGHT_TOP_SOFT_START_BLOCKS
		overshoot := height - TERRAIN_SURFACE_HEIGHT_TOP_SOFT_START_BLOCKS
		height =
			TERRAIN_SURFACE_HEIGHT_TOP_SOFT_START_BLOCKS +
			range_blocks * overshoot / (overshoot + range_blocks)
	}
	if height < TERRAIN_SURFACE_HEIGHT_BOTTOM_SOFT_START_BLOCKS {
		range_blocks :=
			TERRAIN_SURFACE_HEIGHT_BOTTOM_SOFT_START_BLOCKS -
			TERRAIN_SURFACE_HEIGHT_BOTTOM_LIMIT_BLOCKS
		overshoot := TERRAIN_SURFACE_HEIGHT_BOTTOM_SOFT_START_BLOCKS - height
		height =
			TERRAIN_SURFACE_HEIGHT_BOTTOM_SOFT_START_BLOCKS -
			range_blocks * overshoot / (overshoot + range_blocks)
	}
	return height
}

terrain_biome_material_biome_pick :: proc(
	key: biomes.FeatureGridKey,
	evaluation: biomes.SurfaceBiomeProfileEvaluation,
	world_x, world_z: i32,
) -> biomes.BiomeID {
	if evaluation.cell_count <= 1 || evaluation.transition_strength <= 0.02 {
		return evaluation.final_target.biome_id
	}

	h := biomes.feature_grid_key_hash(key)
	h = biomes.feature_grid_hash_combine(h, TERRAIN_SURFACE_MATERIAL_BLEND_SALT)
	h = biomes.feature_grid_hash_combine(h, biomes.feature_grid_hash_i32(world_x))
	h = biomes.feature_grid_hash_combine(h, biomes.feature_grid_hash_i32(world_z))
	roll := biomes.feature_grid_unit_f32(h, TERRAIN_SURFACE_MATERIAL_BLEND_SALT)
	cumulative := f32(0)
	for i := u32(0); i < evaluation.cell_count; i += 1 {
		cumulative += evaluation.blend_weights[i]
		if roll <= cumulative {
			return evaluation.targets[i].biome_id
		}
	}
	return evaluation.final_target.biome_id
}

terrain_shoreline_material_width :: proc(evaluation: biomes.SurfaceBiomeProfileEvaluation) -> f32 {
	return math.max(f32(6), evaluation.final_target.shoreline_width_blocks * 0.85)
}

terrain_shoreline_height_delta :: proc(surface_height_blocks, water_level_blocks: f32) -> f32 {
	water_level := math.max(biomes.SEA_LEVEL_BLOCKS, water_level_blocks)
	return surface_height_blocks - water_level
}

terrain_surface_material_apply_shoreline :: proc(
	key: biomes.FeatureGridKey,
	evaluation: biomes.SurfaceBiomeProfileEvaluation,
	base_material_id: world_async.BlockMaterialID,
	surface_height_blocks, water_level_blocks: f32,
	world_x, world_z: i32,
) -> world_async.BlockMaterialID {
	shore_width := terrain_shoreline_material_width(evaluation)
	height_delta := terrain_shoreline_height_delta(surface_height_blocks, water_level_blocks)
	if height_delta > shore_width {
		return base_material_id
	}
	if height_delta < -4 {
		return world_async.BlockMaterialID(TERRAIN_WET_MARSH_MAT_ID)
	}

	lower_beach_limit := shore_width * 0.42
	upper_beach_limit := shore_width * 0.94
	if height_delta <= lower_beach_limit {
		return world_async.BlockMaterialID(TERRAIN_WET_MARSH_MAT_ID)
	}
	if height_delta >= upper_beach_limit {
		return base_material_id
	}

	sand_strength := 1.0 - math.smoothstep(lower_beach_limit, upper_beach_limit, height_delta)
	dither := biomes.regional_terrain_field_value_noise_2(
		key,
		world_x,
		world_z,
		17,
		TERRAIN_SHORE_MATERIAL_BLEND_SALT,
	)
	roll := math.clamp(0.5 + dither * TERRAIN_SHORE_MATERIAL_DITHER_AMPLITUDE, f32(0), f32(1))
	if roll < sand_strength {
		return world_async.BlockMaterialID(TERRAIN_WET_MARSH_MAT_ID)
	}
	return base_material_id
}

terrain_surface_layer_depth_apply_shoreline :: proc(
	evaluation: biomes.SurfaceBiomeProfileEvaluation,
	surface_layer_depth: i32,
	surface_height_blocks, water_level_blocks: f32,
) -> i32 {
	if surface_layer_depth <= 1 {
		return surface_layer_depth
	}
	shore_width := terrain_shoreline_material_width(evaluation)
	height_delta := terrain_shoreline_height_delta(surface_height_blocks, water_level_blocks)
	if height_delta < -4 || height_delta > shore_width * TERRAIN_SHORE_CAP_THIN_BAND_FRACTION {
		return surface_layer_depth
	}
	return 1
}

terrain_subsurface_material_apply_shoreline :: proc(
	evaluation: biomes.SurfaceBiomeProfileEvaluation,
	base_material_id: world_async.BlockMaterialID,
	surface_height_blocks, water_level_blocks: f32,
) -> world_async.BlockMaterialID {
	shore_width := terrain_shoreline_material_width(evaluation)
	height_delta := terrain_shoreline_height_delta(surface_height_blocks, water_level_blocks)
	if height_delta <= shore_width * TERRAIN_SHORE_CAP_THIN_BAND_FRACTION {
		return world_async.BlockMaterialID(TERRAIN_WET_MARSH_MAT_ID)
	}
	return base_material_id
}

terrain_biome_layer_depth_ceil :: proc(depth: f32) -> i32 {
	whole := i32(depth)
	if f32(whole) < depth {
		whole += 1
	}
	return whole
}

terrain_hydrology_debug_material_id :: proc(
	material_id: world_async.BlockMaterialID,
) -> world_async.BlockMaterialID {
	return world_async.BlockMaterialID(u8(material_id) | TERRAIN_HYDROLOGY_DEBUG_MATERIAL_FLAG)
}

terrain_cave_network_debug_material_id :: proc(
	material_id: world_async.BlockMaterialID,
) -> world_async.BlockMaterialID {
	return world_async.BlockMaterialID(u8(material_id) | TERRAIN_CAVE_NETWORK_DEBUG_MATERIAL_FLAG)
}

terrain_cave_anchor_debug_material_id :: proc(
	material_id: world_async.BlockMaterialID,
) -> world_async.BlockMaterialID {
	return terrain_cave_network_debug_material_id(material_id)
}

terrain_debug_material_flags_from_combo :: proc(combo: u32) -> u32 {
	flags := u32(0)
	if (combo & TERRAIN_DEBUG_MATERIAL_FLAG_COMBO_HYDROLOGY) != 0 {
		flags |= u32(TERRAIN_HYDROLOGY_DEBUG_MATERIAL_FLAG)
	}
	if (combo & TERRAIN_DEBUG_MATERIAL_FLAG_COMBO_CAVE_NETWORK) != 0 {
		flags |= u32(TERRAIN_CAVE_NETWORK_DEBUG_MATERIAL_FLAG)
	}
	return flags
}

terrain_biome_block_material_id :: proc(
	column: TerrainBiomeColumn,
	blocks_below_surface: i32,
) -> world_async.BlockMaterialID {
	if blocks_below_surface < column.surface_layer_depth {
		return column.surface_material_id
	}
	if blocks_below_surface < column.surface_layer_depth + TERRAIN_DIRT_LAYER_BLOCK_DEPTH {
		return column.subsurface_material_id
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

	DEBUG_TERRAIN_QUALITY_GRID_STEPS :: 17
	DEBUG_TERRAIN_QUALITY_GRID_STEP_BLOCKS :: 64
	DEBUG_TERRAIN_QUALITY_GRID_MIN_BLOCK :: -512

	debug_terrain_generation_quality_contract_checks_run :: proc(key: biomes.FeatureGridKey) {
		log.assert(
			CHUNK_STREAMING_RADIUS_Y_UP >= 1,
			"terrain streaming must include an upper layer so mountains are visible",
		)
		log.assert(
			CHUNK_STREAMING_RADIUS_Y_DOWN >= 2,
			"terrain streaming must include at least two lower layers for subterranean depth",
		)

		min_height := max(f32)
		max_height := -max(f32)
		same_biome_pairs: u32
		biome_pair_count: u32
		water_debug_columns: u32
		previous_row: [DEBUG_TERRAIN_QUALITY_GRID_STEPS]biomes.BiomeID

		for z_index := 0; z_index < DEBUG_TERRAIN_QUALITY_GRID_STEPS; z_index += 1 {
			prev_x_valid := false
			prev_x_biome := biomes.BiomeID.Temperate_Hills
			world_z := i32(
				DEBUG_TERRAIN_QUALITY_GRID_MIN_BLOCK +
				z_index * DEBUG_TERRAIN_QUALITY_GRID_STEP_BLOCKS,
			)

			for x_index := 0; x_index < DEBUG_TERRAIN_QUALITY_GRID_STEPS; x_index += 1 {
				world_x := i32(
					DEBUG_TERRAIN_QUALITY_GRID_MIN_BLOCK +
					x_index * DEBUG_TERRAIN_QUALITY_GRID_STEP_BLOCKS,
				)
				column := terrain_biome_column_sample_direct(key, world_x, world_z)

				min_height = math.min(min_height, column.surface_height_blocks)
				max_height = math.max(max_height, column.surface_height_blocks)

				if prev_x_valid {
					biome_pair_count += 1
					if prev_x_biome == column.dominant_biome_id {
						same_biome_pairs += 1
					}
				}
				if z_index > 0 {
					biome_pair_count += 1
					if previous_row[x_index] == column.dominant_biome_id {
						same_biome_pairs += 1
					}
				}
				previous_row[x_index] = column.dominant_biome_id
				prev_x_biome = column.dominant_biome_id
				prev_x_valid = true

				if column.hydrology_debug_material_active {
					water_debug_columns += 1
					log.assert(
						column.water_fill_active,
						"hydrology debug columns must correspond to actual local water fill",
					)
				}
			}
		}

		height_range := max_height - min_height
		same_biome_ratio := f32(same_biome_pairs) / f32(biome_pair_count)
		log.assertf(
			height_range >= 55,
			"surface terrain should have meaningful elevation range: min=%.2f max=%.2f range=%.2f",
			min_height,
			max_height,
			height_range,
		)
		log.assertf(
			max_height >= 78,
			"surface terrain should generate visible highland/mountain heights, max=%.2f",
			max_height,
		)
		log.assertf(
			same_biome_ratio >= 0.48,
			"surface biome field should have coherent neighboring samples, ratio=%.3f",
			same_biome_ratio,
		)
		log.assert(
			water_debug_columns > 0,
			"terrain quality sample should include local water-fill debug columns",
		)
		shore_eval := biomes.SurfaceBiomeProfileEvaluation {
			final_target = {shoreline_width_blocks = 18},
		}
		shore_material := terrain_surface_material_apply_shoreline(
			key,
			shore_eval,
			world_async.BlockMaterialID(TERRAIN_GRASS_MAT_ID),
			biomes.SEA_LEVEL_BLOCKS + 1,
			biomes.SEA_LEVEL_BLOCKS,
			11,
			23,
		)
		log.assert(
			shore_material == world_async.BlockMaterialID(TERRAIN_WET_MARSH_MAT_ID),
			"shoreline material rule should turn low beach surface to sand/wet material",
		)
		lower_middle_shore_material := terrain_surface_material_apply_shoreline(
			key,
			shore_eval,
			world_async.BlockMaterialID(TERRAIN_GRASS_MAT_ID),
			biomes.SEA_LEVEL_BLOCKS + 8,
			biomes.SEA_LEVEL_BLOCKS,
			11,
			23,
		)
		log.assert(
			lower_middle_shore_material == world_async.BlockMaterialID(TERRAIN_WET_MARSH_MAT_ID),
			"shoreline material dither should keep lower-middle beach surface sand/wet",
		)
		upland_material := terrain_surface_material_apply_shoreline(
			key,
			shore_eval,
			world_async.BlockMaterialID(TERRAIN_GRASS_MAT_ID),
			biomes.SEA_LEVEL_BLOCKS + 48,
			biomes.SEA_LEVEL_BLOCKS,
			11,
			23,
		)
		log.assert(
			upland_material == world_async.BlockMaterialID(TERRAIN_GRASS_MAT_ID),
			"shoreline material rule should leave upland grass material alone",
		)
		shore_cap_depth := terrain_surface_layer_depth_apply_shoreline(
			shore_eval,
			TERRAIN_GRASS_CAP_BLOCK_DEPTH,
			biomes.SEA_LEVEL_BLOCKS + 8,
			biomes.SEA_LEVEL_BLOCKS,
		)
		log.assert(
			shore_cap_depth == 1,
			"shoreline material layering should thin grass caps over middle beach sand",
		)
		shore_subsurface_material := terrain_subsurface_material_apply_shoreline(
			shore_eval,
			world_async.BlockMaterialID(TERRAIN_DIRT_MAT_ID),
			biomes.SEA_LEVEL_BLOCKS + 8,
			biomes.SEA_LEVEL_BLOCKS,
		)
		log.assert(
			shore_subsurface_material == world_async.BlockMaterialID(TERRAIN_WET_MARSH_MAT_ID),
			"shoreline material layering should expose sand/wet material under the beach cap",
		)
		upland_cap_depth := terrain_surface_layer_depth_apply_shoreline(
			shore_eval,
			TERRAIN_GRASS_CAP_BLOCK_DEPTH,
			biomes.SEA_LEVEL_BLOCKS + 48,
			biomes.SEA_LEVEL_BLOCKS,
		)
		upland_subsurface_material := terrain_subsurface_material_apply_shoreline(
			shore_eval,
			world_async.BlockMaterialID(TERRAIN_DIRT_MAT_ID),
			biomes.SEA_LEVEL_BLOCKS + 48,
			biomes.SEA_LEVEL_BLOCKS,
		)
		log.assert(
			upland_cap_depth == TERRAIN_GRASS_CAP_BLOCK_DEPTH &&
			upland_subsurface_material == world_async.BlockMaterialID(TERRAIN_DIRT_MAT_ID),
			"shoreline material layering should leave upland caps and subsurface material alone",
		)
		log.assert(
			terrain_surface_height_apply_vertical_cushion(200) <
			TERRAIN_SURFACE_HEIGHT_TOP_LIMIT_BLOCKS,
			"surface height top cushion should keep generated terrain below the hard top support",
		)
		log.assert(
			terrain_surface_height_apply_vertical_cushion(-220) >
			TERRAIN_SURFACE_HEIGHT_BOTTOM_LIMIT_BLOCKS,
			"surface height bottom cushion should keep generated terrain above the hard lower support",
		)
		tunnel_passage_shape := terrain_density_cave_passage_shape(.Tunnel)
		generic_segment_shape := terrain_density_cave_segment_shape_default()
		canyon_passage_shape := terrain_density_cave_passage_shape(.Canyon)
		fracture_passage_shape := terrain_density_cave_passage_shape(.Fracture)
		flooded_passage_shape := terrain_density_cave_passage_shape(.Flooded_Passage)
		worm_passage_shape := terrain_density_cave_passage_shape(.Worm_Path)
		collapsed_passage_shape := terrain_density_cave_passage_shape(.Collapsed_Corridor)
		log.assert(
			canyon_passage_shape.radius_x_scale > tunnel_passage_shape.radius_x_scale &&
			canyon_passage_shape.radius_y_scale > tunnel_passage_shape.radius_y_scale,
			"canyon cave passage profile should be broader than a tunnel",
		)
		log.assert(
			fracture_passage_shape.radius_x_scale < tunnel_passage_shape.radius_x_scale &&
			fracture_passage_shape.radius_y_scale > tunnel_passage_shape.radius_y_scale,
			"fracture cave passage profile should be narrow and tall",
		)
		log.assert(
			fracture_passage_shape.radius_neck_scale > tunnel_passage_shape.radius_neck_scale,
			"fracture cave passage profile should pinch more strongly than a tunnel",
		)
		log.assert(
			canyon_passage_shape.radius_swell_scale > tunnel_passage_shape.radius_swell_scale,
			"canyon cave passage profile should support wider local chambers",
		)
		log.assert(
			flooded_passage_shape.radius_y_scale < tunnel_passage_shape.radius_y_scale,
			"flooded cave passage profile should be vertically flattened",
		)
		log.assert(
			worm_passage_shape.meander_scale > tunnel_passage_shape.meander_scale &&
			worm_passage_shape.radius_z_scale > tunnel_passage_shape.radius_z_scale,
			"worm cave passage profile should be more sinuous than a tunnel",
		)
		log.assert(
			worm_passage_shape.curve_scale > tunnel_passage_shape.curve_scale &&
			tunnel_passage_shape.curve_scale > generic_segment_shape.curve_scale,
			"cave passage profiles should add coherent centerline curvature over generic segments",
		)
		log.assert(
			collapsed_passage_shape.radius_y_scale < tunnel_passage_shape.radius_y_scale &&
			collapsed_passage_shape.radius_neck_scale > tunnel_passage_shape.radius_neck_scale,
			"collapsed cave passage profile should be flatter and more pinched than a tunnel",
		)
		log.assert(
			tunnel_passage_shape.radius_neck_scale > generic_segment_shape.radius_neck_scale &&
			tunnel_passage_shape.meander_scale > generic_segment_shape.meander_scale,
			"ordinary tunnel cave passage profile should be more pinched and wandering than a generic segment",
		)
		log.assert(
			tunnel_passage_shape.radius_endpoint_scale >
				generic_segment_shape.radius_endpoint_scale &&
			fracture_passage_shape.radius_endpoint_scale >=
				tunnel_passage_shape.radius_endpoint_scale,
			"cave passage profiles should keep endpoint sockets wider than generic segments",
		)
		log.assert(
			terrain_density_cave_passage_radius_profile_scale(tunnel_passage_shape, -1.0, 0.0) <
			terrain_density_cave_passage_radius_profile_scale(tunnel_passage_shape, 1.0, 0.0),
			"cave passage radius profile should create deterministic necks and swells",
		)
		log.assert(
			TERRAIN_FUNGAL_ROOM_LOWER_XZ_SCALE > 1.0 &&
			TERRAIN_FUNGAL_ROOM_LOWER_Y_SCALE < TERRAIN_FUNGAL_ROOM_DOME_Y_SCALE,
			"fungal cave room profile should favor broad lower vaults with taller domes",
		)
		log.assert(
			TERRAIN_FUNGAL_ROOM_ALCOVE_OFFSET_SCALE > TERRAIN_FUNGAL_ROOM_ALCOVE_XZ_SCALE,
			"fungal cave room profile should push side alcoves away from the room center",
		)
		log.assert(
			TERRAIN_CRYSTAL_ROOM_MAIN_Y_SCALE > 1.0 && TERRAIN_CRYSTAL_ROOM_MAIN_XZ_SCALE < 0.85,
			"crystal cave room profile should favor tall narrow geode volumes",
		)
		log.assert(
			TERRAIN_CRYSTAL_ROOM_FISSURE_UPPER_Y_SCALE >
			TERRAIN_CRYSTAL_ROOM_FISSURE_LOWER_Y_SCALE,
			"crystal cave room fissure should rise through the geode room",
		)
		log.assert(
			TERRAIN_AQUIFER_ROOM_BASIN_XZ_SCALE > 1.0 &&
			TERRAIN_AQUIFER_ROOM_BASIN_Y_SCALE < TERRAIN_AQUIFER_ROOM_SHELF_Y_SCALE + 0.08,
			"aquifer cave room profile should favor a broad low flooded basin",
		)
		log.assert(
			TERRAIN_AQUIFER_ROOM_SHELF_OFFSET_SCALE > TERRAIN_AQUIFER_ROOM_SHELF_XZ_SCALE * 0.5,
			"aquifer cave room profile should offset the dry shelf away from the basin center",
		)
		log.assert(
			TERRAIN_AQUIFER_ROOM_WATER_Y_OFFSET_SCALE <
				TERRAIN_AQUIFER_ROOM_BASIN_Y_OFFSET_SCALE &&
			TERRAIN_AQUIFER_ROOM_WATER_Y_SCALE < TERRAIN_AQUIFER_ROOM_BASIN_Y_SCALE,
			"aquifer cave room water profile should stay lower and shallower than the basin",
		)
		log.assert(
			terrain_density_cave_node_uses_profile_room(
				{role = .Pocket, kind = .Chamber, radius_blocks = 5, major_region = true},
			),
			"major cave nodes should always use biome-specific profile rooms",
		)
		log.assert(
			terrain_density_cave_node_uses_profile_room(
				{
					role = .Resource_Chamber,
					kind = .Geode_Chamber,
					radius_blocks = TERRAIN_CAVE_NODE_PROFILE_ROOM_MIN_RADIUS_BLOCKS,
				},
			),
			"medium resource chambers should use biome-specific profile rooms",
		)
		log.assert(
			terrain_density_cave_node_uses_profile_room(
				{
					role = .Water_Linked_Region,
					kind = .Underground_Lake,
					radius_blocks = TERRAIN_CAVE_NODE_PROFILE_ROOM_MIN_RADIUS_BLOCKS,
				},
			),
			"medium water-linked chambers should use biome-specific profile rooms",
		)
		log.assert(
			terrain_density_cave_node_uses_profile_room(
				{
					role = .Pocket,
					kind = .Chamber,
					radius_blocks = TERRAIN_CAVE_NODE_ISOLATED_CULL_RADIUS_BLOCKS,
				},
			),
			"large ordinary chambers should use profile rooms instead of plain ellipsoids",
		)
		log.assert(
			!terrain_density_cave_node_uses_profile_room(
				{
					role = .Pocket,
					kind = .Chamber,
					radius_blocks = TERRAIN_CAVE_NODE_PROFILE_ROOM_MIN_RADIUS_BLOCKS - 1,
				},
			),
			"small ordinary pockets should remain cheap or be culled by connectivity",
		)
		log.assert(
			terrain_density_cave_room_lobe_threshold_adjust(0.92, 0, 0, 1, 0) > 0,
			"cave room lobe profile should expand at least one deterministic side",
		)
		log.assert(
			terrain_density_cave_room_lobe_threshold_adjust(0, 0, 0.92, 1, 0) < 0,
			"cave room lobe profile should notch the perpendicular room edge",
		)
		log.assert(
			math.abs(terrain_density_cave_room_lobe_threshold_adjust(0, 0, 0, 1, 0)) < 0.001,
			"cave room lobe profile should leave the core room connection intact",
		)
		log.assert(
			!terrain_density_cave_room_internal_structure_preserves(
				0,
				0,
				0,
				8,
				8,
				8,
				1,
				0,
				1,
				.Fungal_Vaults,
			),
			"cave room internal structure should leave the connected core open",
		)
		log.assert(
			terrain_density_cave_room_internal_structure_preserves(
				0,
				0,
				0.42,
				8,
				8,
				8,
				1,
				0,
				1,
				.Fungal_Vaults,
			),
			"fungal cave rooms should preserve off-center root-like internal columns",
		)
		log.assert(
			terrain_density_cave_room_internal_structure_preserves(
				0,
				0,
				0.32,
				8,
				8,
				8,
				1,
				0,
				1,
				.Crystal_Geode_Network,
			),
			"crystal cave rooms should preserve narrow off-center blade-like structure",
		)
		log.assert(
			terrain_density_cave_room_internal_structure_preserves(
				0,
				-0.45,
				0.32,
				8,
				8,
				8,
				1,
				0,
				1,
				.Buried_Aquifer_Caves,
			),
			"aquifer cave rooms should preserve low island-like structure",
		)
		log.assert(
			terrain_density_cave_mouth_lower_width_scale(0.0, 1.0) >
			terrain_density_cave_mouth_lower_width_scale(1.0, 1.0),
			"cave mouth profile should keep the surface opening wider than the back throat",
		)
		log.assert(
			terrain_density_cave_mouth_lower_width_scale(0.0, 1.0) >= 1.25,
			"cave mouth profile should keep a broad lower surface arch",
		)
		log.assert(
			terrain_density_cave_mouth_side_shoulder_penalty(0.0, 0.9, 1.0) >
			terrain_density_cave_mouth_side_shoulder_penalty(0.0, 0.1, 1.0),
			"cave mouth profile should leave stronger upper side shoulders than the center",
		)
		log.assert(
			terrain_density_cave_mouth_side_shoulder_penalty(0.0, 0.36, 1.0) > 0,
			"cave mouth profile should start preserving upper side shoulders before the far edge",
		)
		log.assert(
			terrain_density_cave_mouth_lower_center_relief(0.0, 0.1, 1.0) >
			terrain_density_cave_mouth_lower_center_relief(0.0, 0.9, 1.0),
			"cave mouth profile should open the lower center more than side edges",
		)
		log.assert(
			terrain_density_cave_mouth_lower_center_relief(0.0, 0.1, 1.0) > 0.10,
			"cave mouth profile should cut a stronger lower-center opening",
		)
		log.assert(
			terrain_density_cave_mouth_lower_jaw_relief(0.0, 0.52, 1.0) >
			terrain_density_cave_mouth_lower_jaw_relief(0.0, 0.05, 1.0),
			"cave mouth profile should carve lower side jaw pockets away from the center",
		)
		log.assert(
			terrain_density_cave_mouth_lower_jaw_relief(1.0, 0.52, 1.0) <
			terrain_density_cave_mouth_lower_jaw_relief(0.0, 0.52, 1.0),
			"cave mouth lower jaw relief should fade into the back throat",
		)
		log.assert(
			terrain_density_cave_mouth_side_alcove_relief(0.42, 0.72, 1.0, 1.0) >
			terrain_density_cave_mouth_side_alcove_relief(0.42, 0.10, 1.0, 1.0),
			"cave mouth side alcove relief should target off-center side pockets",
		)
		log.assert(
			terrain_density_cave_mouth_side_alcove_relief(0.95, 0.72, 1.0, 1.0) <
			terrain_density_cave_mouth_side_alcove_relief(0.42, 0.72, 1.0, 1.0),
			"cave mouth side alcove relief should fade before the back throat",
		)
		log.assert(
			terrain_density_cave_mouth_side_alcove_relief(0.42, 0.72, 1.0, 0.0) <
			terrain_density_cave_mouth_side_alcove_relief(0.42, 0.72, 1.0, 1.0),
			"small cave mouths should keep side alcove relief smaller than large mouths",
		)
		log.assert(
			terrain_density_cave_mouth_upper_lip_rib(0.0, 0.05, 1.0) >
			terrain_density_cave_mouth_upper_lip_rib(0.0, 0.9, 1.0),
			"cave mouth profile should preserve a small upper-center lip",
		)
		log.assert(
			terrain_density_sinkhole_major_radius_scale(0.0) >
			terrain_density_sinkhole_minor_radius_scale(0.0),
			"sinkhole throat profile should start as an asymmetric oval at the surface",
		)
		log.assert(
			terrain_density_sinkhole_minor_radius_scale(1.0) >
			terrain_density_sinkhole_major_radius_scale(1.0),
			"sinkhole throat profile should twist toward a narrower lower connector",
		)
		log.assert(
			terrain_density_sinkhole_side_ledge_relief(0.0, 0.56) >
			terrain_density_sinkhole_side_ledge_relief(0.0, 0.05),
			"sinkhole throat profile should carve upper side ledges away from the center",
		)
		log.assert(
			terrain_density_sinkhole_side_ledge_relief(1.0, 0.56) <
			terrain_density_sinkhole_side_ledge_relief(0.0, 0.56),
			"sinkhole side ledge relief should fade with depth",
		)
		log.assert(
			terrain_density_sinkhole_rim_lip_penalty(0.0, 0.05, 0.05) >
			terrain_density_sinkhole_rim_lip_penalty(0.0, 0.9, 0.9),
			"sinkhole throat profile should preserve a small upper-center rim lip",
		)
		mouth_entrance_shape := terrain_density_cave_entrance_link_shape(.Cave_Mouth, true)
		mouth_deep_shape := terrain_density_cave_entrance_link_shape(.Cave_Mouth, false)
		sinkhole_entrance_shape := terrain_density_cave_entrance_link_shape(.Sinkhole, true)
		log.assert(
			mouth_entrance_shape.radius_y_scale < tunnel_passage_shape.radius_y_scale &&
			mouth_entrance_shape.radius_neck_scale > tunnel_passage_shape.radius_neck_scale,
			"cave mouth entrance link should flatten and pinch before joining the graph",
		)
		log.assert(
			mouth_deep_shape.curve_scale > tunnel_passage_shape.curve_scale,
			"deep cave mouth link should keep coherent curvature into the graph",
		)
		log.assert(
			terrain_density_cave_mouth_reach_blocks(6) <
			terrain_density_cave_mouth_reach_blocks(12),
			"small cave mouths should have shorter surface carving reach than large mouths",
		)
		log.assert(
			terrain_density_cave_mouth_near_link_radius(6, 3) < 3,
			"small cave mouths should keep the near-surface connector narrower than the graph link",
		)
		log.assert(
			terrain_density_cave_mouth_transition_drop_blocks(12, 120) /
				terrain_density_cave_mouth_transition_run_blocks(12) <
			0.8,
			"cave mouth transition should slope before dropping into the deep graph",
		)
		small_mouth_anchor := biomes.CaveAnchor {
			id = 1,
		}
		log.assert(
			terrain_density_cave_mouth_transition_style(small_mouth_anchor, 6) != .Spiral_Ramp,
			"small cave mouths should not choose the semi-chamber spiral ramp profile",
		)
		log.assert(
			sinkhole_entrance_shape.radius_y_scale > mouth_entrance_shape.radius_y_scale &&
			sinkhole_entrance_shape.radius_x_scale < tunnel_passage_shape.radius_x_scale,
			"sinkhole entrance link should remain vertical and narrower than ordinary tunnels",
		)
		cave_field_path_shape := terrain_density_cave_field_path_shape()
		log.assert(
			cave_field_path_shape.radius_y_scale < tunnel_passage_shape.radius_y_scale &&
			cave_field_path_shape.radius_x_scale < tunnel_passage_shape.radius_x_scale,
			"stochastic cave-field paths should use a narrow flattened profile",
		)
		log.assert(
			TERRAIN_CAVE_FIELD_PATH_SEGMENT_HALF_LENGTH_SCALE >
			TERRAIN_CAVE_FIELD_PATH_SEGMENT_RADIUS_SCALE,
			"stochastic cave-field path segments should be longer than they are wide",
		)
		path_direction_field_sample := TerrainCaveFieldSample {
			path_axis_x = false,
		}
		path_direction_network_sample := TerrainCaveFieldNetworkSample {
			found       = true,
			route_dir_x = 0.6,
			route_dir_y = 0.4,
			route_dir_z = 0.8,
		}
		path_dir_x, path_dir_y, path_dir_z, path_route_follow :=
			terrain_density_cave_field_path_direction(
				path_direction_field_sample,
				path_direction_network_sample,
			)
		path_horizontal_len := math.sqrt_f32(path_dir_x * path_dir_x + path_dir_z * path_dir_z)
		log.assert(
			path_route_follow &&
			math.abs(path_horizontal_len - 1.0) < 0.001 &&
			path_dir_y > 0 &&
			path_dir_y <= TERRAIN_CAVE_FIELD_PATH_ROUTE_VERTICAL_SCALE,
			"stochastic cave-field path segments should follow nearby route tangents with bounded pitch",
		)
		fallback_dir_x, fallback_dir_y, fallback_dir_z, fallback_route_follow :=
			terrain_density_cave_field_path_direction(path_direction_field_sample, {})
		log.assert(
			!fallback_route_follow &&
			fallback_dir_x == 0 &&
			fallback_dir_y == 0 &&
			fallback_dir_z == 1,
			"stochastic cave-field path direction should retain deterministic axis fallback",
		)
		route_pocket_field_sample := TerrainCaveFieldSample {
				chamber_open_strength = TERRAIN_CAVE_FIELD_OPEN_STRENGTH_MIN + 0.08,
				path_open_strength    = 0.08,
			}
		route_pocket_network_sample := TerrainCaveFieldNetworkSample {
				connected    = true,
				distance     = 10,
				route_radius = 4,
			}
		log.assert(
			terrain_density_cave_field_sample_prefers_route_pocket(
				route_pocket_field_sample,
				1.0,
				route_pocket_network_sample,
			),
			"route-adjacent chamber samples should become connected cave-field side pockets",
		)
		route_pocket_network_sample.connected = false
		log.assert(
			!terrain_density_cave_field_sample_prefers_route_pocket(
				route_pocket_field_sample,
				1.0,
				route_pocket_network_sample,
			),
			"route-pocket cave-field samples should require actual network connectivity",
		)
		cave_field_candidates: u32
		cave_field_path_candidates: u32
		cave_field_chamber_candidates: u32
		for sample_z := i32(-128); sample_z <= 128; sample_z += 16 {
			for sample_y := i32(-112); sample_y <= -32; sample_y += 16 {
				for sample_x := i32(-128); sample_x <= 128; sample_x += 16 {
					sample_column := terrain_biome_column_sample_direct(key, sample_x, sample_z)
					depth_below_surface := sample_column.surface_height_blocks - f32(sample_y)
					field_sample := terrain_density_subterranean_cave_field_sample(
						key,
						sample_x,
						sample_y,
						sample_z,
						depth_below_surface,
					)
					if terrain_density_cave_field_sample_is_candidate(
						field_sample,
						terrain_density_cave_vertical_support(f32(sample_y)),
					) {
						cave_field_candidates += 1
						if terrain_density_cave_field_sample_prefers_path(
							field_sample,
							terrain_density_cave_vertical_support(f32(sample_y)),
						) {
							cave_field_path_candidates += 1
						} else {
							cave_field_chamber_candidates += 1
						}
					}
				}
			}
		}
		log.assert(
			cave_field_candidates > 0,
			"subterranean cave field should produce narrow/cavern candidate samples",
		)
		log.assert(
			cave_field_path_candidates > 0 && cave_field_chamber_candidates > 0,
			"subterranean cave field should produce both path and chamber shaped candidates",
		)

		cave_connectivity_route_edge := biomes.CaveNetworkEdge {
			id            = biomes.FeatureID(0x701),
			kind          = .Canyon,
			from_node_id  = biomes.FeatureID(0x702),
			to_node_id    = biomes.FeatureID(0x703),
			from_biome_id = .Fungal_Vaults,
			to_biome_id   = .Fungal_Vaults,
			from_x        = 48,
			from_y        = -80,
			from_z        = 0,
			bend_x        = 72,
			bend_y        = -76,
			bend_z        = 12,
			to_x          = 96,
			to_y          = -80,
			to_z          = 0,
			radius_blocks = 6,
		}
		cave_connectivity_small_node := biomes.CaveNetworkNode {
			id                       = biomes.FeatureID(0x711),
			kind                     = .Chamber,
			role                     = .Pocket,
			biome_id                 = .Fungal_Vaults,
			x                        = 0,
			y                        = -80,
			z                        = 0,
			radius_blocks            = 6,
			connection_radius_blocks = 3,
		}
		cave_connectivity_small_region := biomes.GenerationRegion {
			key = key,
		}
		cave_connectivity_small_region.cave_network_node_count = 1
		cave_connectivity_small_region.cave_network_nodes[0] = cave_connectivity_small_node
		cave_connectivity_small := terrain_density_cave_node_connectivity(
			&cave_connectivity_small_region,
			cave_connectivity_small_node,
		)
		log.assert(
			!cave_connectivity_small.should_carve,
			"small isolated cave network pockets should be culled before voxel carving",
		)

		cave_connectivity_large_node := biomes.CaveNetworkNode {
			id                       = biomes.FeatureID(0x721),
			kind                     = .Biome_Hub,
			role                     = .Major_Region,
			biome_id                 = .Fungal_Vaults,
			x                        = 0,
			y                        = -80,
			z                        = 0,
			radius_blocks            = 24,
			connection_radius_blocks = 8,
			major_region             = true,
		}
		cave_connectivity_large_region := biomes.GenerationRegion {
			key = key,
		}
		cave_connectivity_large_region.cave_network_node_count = 1
		cave_connectivity_large_region.cave_network_nodes[0] = cave_connectivity_large_node
		cave_connectivity_large := terrain_density_cave_node_connectivity(
			&cave_connectivity_large_region,
			cave_connectivity_large_node,
		)
		log.assert(
			!cave_connectivity_large.should_carve,
			"large cave network chambers without an edge or bridge route should not carve isolated rooms",
		)

		cave_connectivity_large_region.cave_network_edge_count = 1
		cave_connectivity_large_region.cave_network_edges[0] = cave_connectivity_route_edge
		cave_connectivity_large = terrain_density_cave_node_connectivity(
			&cave_connectivity_large_region,
			cave_connectivity_large_node,
		)
		log.assert(
			cave_connectivity_large.should_carve && cave_connectivity_large.should_bridge,
			"large cave network chambers near a route should bridge into the network",
		)

		cave_connectivity_anchor_node := biomes.CaveNetworkNode {
			id                       = biomes.FeatureID(0x731),
			kind                     = .Entrance,
			role                     = .Pocket,
			biome_id                 = .Buried_Aquifer_Caves,
			x                        = 0,
			y                        = -80,
			z                        = 0,
			radius_blocks            = 8,
			connection_radius_blocks = 4,
		}
		cave_connectivity_anchor := biomes.CaveAnchor {
			id                      = biomes.FeatureID(0x732),
			feature_id              = cave_connectivity_anchor_node.id,
			target_feature_id       = cave_connectivity_anchor_node.id,
			kind                    = .Cave_Mouth,
			x                       = 0,
			y                       = 64,
			z                       = 0,
			influence_radius_blocks = 8,
			guaranteed_connection   = true,
		}
		cave_connectivity_anchor_region := biomes.GenerationRegion {
			key = key,
		}
		cave_connectivity_anchor_region.cave_network_node_count = 1
		cave_connectivity_anchor_region.cave_network_nodes[0] = cave_connectivity_anchor_node
		cave_connectivity_anchor_region.cave_anchor_count = 1
		cave_connectivity_anchor_region.cave_anchors[0] = cave_connectivity_anchor
		cave_connectivity_anchor_sample := terrain_density_cave_node_connectivity(
			&cave_connectivity_anchor_region,
			cave_connectivity_anchor_node,
		)
		log.assert(
			cave_connectivity_anchor_sample.has_anchor &&
			!cave_connectivity_anchor_sample.should_carve,
			"anchored cave mouths without an edge or bridge route should not become dead-end entrances",
		)
		cave_connectivity_anchor_region.cave_network_edge_count = 1
		cave_connectivity_anchor_region.cave_network_edges[0] = cave_connectivity_route_edge
		cave_connectivity_anchor_sample = terrain_density_cave_node_connectivity(
			&cave_connectivity_anchor_region,
			cave_connectivity_anchor_node,
		)
		log.assert(
			cave_connectivity_anchor_sample.should_carve &&
			cave_connectivity_anchor_sample.should_bridge,
			"anchored cave mouths near a route should carve only when they can bridge into the network",
		)

		surface_node := biomes.cave_network_node_from_owner(
			key,
			biomes.FeatureGridCoord3{x = 0, y = 0, z = 0},
		)
		surface_column := terrain_biome_column_sample_direct(
			key,
			i32(math.floor_f32(surface_node.x)),
			i32(math.floor_f32(surface_node.z)),
		)
		surface_node_depth := surface_column.surface_height_blocks - surface_node.y
		log.assertf(
			surface_node_depth >= 60,
			"surface-adjacent cave node should have meaningful depth, depth=%.2f",
			surface_node_depth,
		)
		log.assertf(
			surface_node.radius_blocks <= 45,
			"surface-adjacent cave node radius should not create a broad crater, radius=%.2f",
			surface_node.radius_blocks,
		)

		deep_node := biomes.cave_network_node_from_owner(
			key,
			biomes.FeatureGridCoord3{x = 0, y = -1, z = 0},
		)
		log.assertf(
			deep_node.y < surface_node.y - 64,
			"deep cave owner should produce a lower subterranean node: surface_y=%.2f deep_y=%.2f",
			surface_node.y,
			deep_node.y,
		)
		log.assertf(
			deep_node.y < -96,
			"deep cave owner should reach mid-depth terrain, deep_y=%.2f",
			deep_node.y,
		)
	}

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

		chunk_voxel_view_fill_empty(&view)
		index = chunk_block_index(5, 6, 7)
		hydrology_debug_material_id := terrain_hydrology_debug_material_id(
			world_async.BlockMaterialID(TERRAIN_DIRT_MAT_ID),
		)
		view.blocks.occupancy[index] = .Solid
		view.blocks.material_id[index] = hydrology_debug_material_id

		debug_output := chunk_voxel_view_build_binary_greedy_mesh(
			view,
			.Treat_Out_Of_Chunk_As_Empty,
			allocator,
			scratch,
		)
		log.assertf(
			debug_output.face_count == 6,
			"hydrology debug block: expected 6 faces, got %d",
			debug_output.face_count,
		)
		for vertex in debug_output.vertices {
			unpacked_vertex := terrain_unpack_vertex(vertex)
			log.assertf(
				unpacked_vertex.material_id == u32(u8(hydrology_debug_material_id)),
				"hydrology debug block: expected material %d, got %d",
				u8(hydrology_debug_material_id),
				unpacked_vertex.material_id,
			)
		}

		row_cache := new(world_async.ChunkBinaryGreedyRowCache, allocator)
		log.assert(row_cache != nil, "hydrology debug row cache allocation failed")
		terrain_binary_row_cache_fill(row_cache, view, 1)
		debug_cache_output := chunk_binary_row_cache_build_binary_greedy_mesh(
			row_cache,
			view,
			.Treat_Out_Of_Chunk_As_Empty,
			allocator,
			scratch,
		)
		log.assertf(
			debug_cache_output.face_count == 6,
			"hydrology debug cached block: expected 6 faces, got %d",
			debug_cache_output.face_count,
		)
		for vertex in debug_cache_output.vertices {
			unpacked_vertex := terrain_unpack_vertex(vertex)
			log.assertf(
				unpacked_vertex.material_id == u32(u8(hydrology_debug_material_id)),
				"hydrology debug cached block: expected material %d, got %d",
				u8(hydrology_debug_material_id),
				unpacked_vertex.material_id,
			)
		}

		chunk_voxel_view_fill_empty(&view)
		shore_below_index := chunk_block_index(4, 4, 4)
		shore_grass_index := chunk_block_index(4, 5, 4)
		view.blocks.occupancy[shore_below_index] = .Solid
		view.blocks.material_id[shore_below_index] = world_async.BlockMaterialID(
			TERRAIN_WET_MARSH_MAT_ID,
		)
		view.blocks.occupancy[shore_grass_index] = .Solid
		view.blocks.material_id[shore_grass_index] = world_async.BlockMaterialID(
			TERRAIN_GRASS_MAT_ID,
		)
		shore_output := chunk_voxel_view_build_binary_greedy_mesh(
			view,
			.Treat_Out_Of_Chunk_As_Empty,
			allocator,
			scratch,
		)
		log.assertf(
			shore_output.face_count == 6,
			"shore grass cap: expected visible cap faces to merge as wet material, got %d faces",
			shore_output.face_count,
		)
		for vertex in shore_output.vertices {
			unpacked_vertex := terrain_unpack_vertex(vertex)
			log.assertf(
				unpacked_vertex.material_id == TERRAIN_WET_MARSH_MAT_ID,
				"shore grass cap: normal=%d expected wet material, got %d",
				unpacked_vertex.normal_id,
				unpacked_vertex.material_id,
			)
		}

		shore_row_cache := new(world_async.ChunkBinaryGreedyRowCache, allocator)
		log.assert(shore_row_cache != nil, "shore row cache allocation failed")
		terrain_binary_row_cache_fill(shore_row_cache, view, 1)
		shore_cache_output := chunk_binary_row_cache_build_binary_greedy_mesh(
			shore_row_cache,
			view,
			.Treat_Out_Of_Chunk_As_Empty,
			allocator,
			scratch,
		)
		log.assertf(
			shore_cache_output.face_count == 6,
			"shore cached grass cap: expected visible cap faces to merge as wet material, got %d faces",
			shore_cache_output.face_count,
		)
		for vertex in shore_cache_output.vertices {
			unpacked_vertex := terrain_unpack_vertex(vertex)
			log.assertf(
				unpacked_vertex.material_id == TERRAIN_WET_MARSH_MAT_ID,
				"shore cached grass cap: normal=%d expected wet material, got %d",
				unpacked_vertex.normal_id,
				unpacked_vertex.material_id,
			)
		}
		log.assert(
			terrain_binary_cave_face_material_index(2, TERRAIN_AQUIFER_WALL_MAT_ID) ==
			TERRAIN_WET_MARSH_MAT_ID,
			"aquifer cave top faces should render as wet floor material",
		)
		log.assert(
			terrain_binary_cave_face_material_index(3, TERRAIN_AQUIFER_WALL_MAT_ID) ==
			TERRAIN_STONE_MAT_ID,
			"aquifer cave bottom faces should render as stone ceiling material",
		)
		log.assert(
			terrain_binary_cave_face_material_index(0, TERRAIN_AQUIFER_WALL_MAT_ID) ==
			TERRAIN_AQUIFER_WALL_MAT_ID,
			"aquifer cave side faces should keep aquifer wall material",
		)
		log.assert(
			terrain_binary_cave_face_material_index(2, TERRAIN_CRYSTAL_MAT_ID) ==
			TERRAIN_STONE_MAT_ID,
			"crystal cave top faces should render as stone floor material",
		)
		log.assert(
			terrain_binary_cave_face_material_index(3, TERRAIN_CRYSTAL_MAT_ID) ==
			TERRAIN_CRYSTAL_MAT_ID,
			"crystal cave bottom faces should keep crystal ceiling material",
		)

		chunk_voxel_view_fill_empty(&view)
		index = chunk_block_index(8, 9, 10)
		cave_debug_material_id := terrain_cave_anchor_debug_material_id(
			terrain_cave_network_debug_material_id(
				world_async.BlockMaterialID(TERRAIN_STONE_MAT_ID),
			),
		)
		view.blocks.occupancy[index] = .Solid
		view.blocks.material_id[index] = cave_debug_material_id

		cave_debug_output := chunk_voxel_view_build_binary_greedy_mesh(
			view,
			.Treat_Out_Of_Chunk_As_Empty,
			allocator,
			scratch,
		)
		log.assertf(
			cave_debug_output.face_count == 6,
			"cave debug block: expected 6 faces, got %d",
			cave_debug_output.face_count,
		)
		for vertex in cave_debug_output.vertices {
			unpacked_vertex := terrain_unpack_vertex(vertex)
			log.assertf(
				unpacked_vertex.material_id == u32(u8(cave_debug_material_id)),
				"cave debug block: expected material %d, got %d",
				u8(cave_debug_material_id),
				unpacked_vertex.material_id,
			)
		}

		chunk_voxel_view_fill_empty(&view)
		index = chunk_block_index(2, 3, 4)
		view.blocks.occupancy[index] = .Solid
		view.blocks.material_id[index] = world_async.BlockMaterialID(5)

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

		missing_neighbor_output := mesh_job_execute_sync(
			{
				mesher = .Greedy_Binary,
				snapshot = left_snapshot,
				neighbors = chunk_mesh_neighbors_find(
					neighbor_test_snapshots[:1],
					left_snapshot.coord,
				),
				boundary_policy = .Sample_Neighbor_Snapshots,
			},
			allocator,
			allocator,
		)
		log.assertf(
			missing_neighbor_output.face_count == 5,
			"left boundary block: expected missing sampled neighbor to suppress perimeter face, got %d",
			missing_neighbor_output.face_count,
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

		heightfield_seed := u32(0)
		heightfield_key := terrain_generation_key_make(heightfield_seed)

		heightfield_coord := world_async.ChunkCoord{0, 0, 0}
		heightfield_origin := chunk_origin_from_coord(heightfield_coord)
		terrain_heightfield_voxel_view_fill(&view, heightfield_coord, heightfield_seed)
		heightfield_solid_count: u32
		heightfield_surface_column_count: u32
		heightfield_surface_material_column_count: u32
		for z in 0 ..< CHUNK_BLOCK_LENGTH {
			for x in 0 ..< CHUNK_BLOCK_LENGTH {
				column := terrain_biome_column_sample_direct(
					heightfield_key,
					heightfield_origin.x + i32(x),
					heightfield_origin.z + i32(z),
				)
				surface_local_y := column.surface_height - heightfield_origin.y
				if surface_local_y >= 0 && surface_local_y < CHUNK_BLOCK_LENGTH {
					heightfield_surface_column_count += 1
					surface_index := chunk_block_index(u32(x), u32(surface_local_y), u32(z))
					if view.blocks.occupancy[surface_index] == .Solid {
						surface_material_id := terrain_material_palette_index(
							view.blocks.material_id[surface_index],
						)
						expected_surface_material_id := u32(u8(column.surface_material_id))
						if surface_material_id == expected_surface_material_id {
							heightfield_surface_material_column_count += 1
						}
					}
				}

				for y in 0 ..< CHUNK_BLOCK_LENGTH {
					index = chunk_block_index(u32(x), u32(y), u32(z))
					if view.blocks.occupancy[index] == .Solid {
						heightfield_solid_count += 1
					}
				}
			}
		}
		log.assert(heightfield_solid_count > 0, "heightfield chunk: expected solid terrain")
		log.assert(
			heightfield_surface_column_count > 0,
			"heightfield chunk: expected at least one surface column in chunk",
		)
		log.assert(
			heightfield_surface_material_column_count > 0,
			"heightfield chunk: expected at least one uncarved biome surface material",
		)

		lower_heightfield_coord := world_async.ChunkCoord{0, -1, 0}
		terrain_heightfield_voxel_view_fill(&view, lower_heightfield_coord, heightfield_seed)
		lower_solid_count: u32
		for z in 0 ..< CHUNK_BLOCK_LENGTH {
			for y in 0 ..< CHUNK_BLOCK_LENGTH {
				for x in 0 ..< CHUNK_BLOCK_LENGTH {
					index = chunk_block_index(u32(x), u32(y), u32(z))
					if view.blocks.occupancy[index] == .Solid {
						lower_solid_count += 1
					}
				}
			}
		}
		log.assertf(
			lower_solid_count > CHUNK_BLOCK_COUNT / 4,
			"lower heightfield chunk: expected substantial solid terrain, got %d blocks",
			lower_solid_count,
		)

		cave_floor_offset := world_async.BlockCoord {
			x = 0,
			y = -1,
			z = 0,
		}
		cave_ceiling_offset := world_async.BlockCoord {
			x = 0,
			y = 1,
			z = 0,
		}
		cave_wall_offset := world_async.BlockCoord {
			x = 1,
			y = 0,
			z = 0,
		}
		log.assert(
			terrain_cave_wall_material_id_for_neighbor(.Fungal_Vaults, cave_floor_offset) ==
			world_async.BlockMaterialID(TERRAIN_GRASS_MAT_ID),
			"fungal cave profile should use mossy floor material",
		)
		log.assert(
			terrain_cave_wall_material_id_for_neighbor(.Fungal_Vaults, cave_ceiling_offset) ==
			world_async.BlockMaterialID(TERRAIN_DIRT_MAT_ID),
			"fungal cave profile should use earth ceiling material",
		)
		log.assert(
			terrain_cave_wall_material_id_for_neighbor(
				.Crystal_Geode_Network,
				cave_floor_offset,
			) ==
			world_async.BlockMaterialID(TERRAIN_STONE_MAT_ID),
			"crystal cave profile should use stone floor material",
		)
		log.assert(
			terrain_cave_wall_material_id_for_neighbor(
				.Crystal_Geode_Network,
				cave_ceiling_offset,
			) ==
			world_async.BlockMaterialID(TERRAIN_CRYSTAL_MAT_ID),
			"crystal cave profile should use crystal ceiling material",
		)
		log.assert(
			terrain_cave_wall_material_id_for_neighbor(.Buried_Aquifer_Caves, cave_wall_offset) ==
			world_async.BlockMaterialID(TERRAIN_AQUIFER_WALL_MAT_ID),
			"aquifer cave profile should use distinct side wall material",
		)

		chunk_voxel_view_fill_empty(&view)
		test_columns: [CHUNK_BLOCK_LENGTH * CHUNK_BLOCK_LENGTH]TerrainBiomeColumn
		for z in 0 ..< CHUNK_BLOCK_LENGTH {
			for x in 0 ..< CHUNK_BLOCK_LENGTH {
				test_columns[x + z * CHUNK_BLOCK_LENGTH] = {
					surface_height         = 64,
					surface_height_blocks  = 64,
					surface_material_id    = world_async.BlockMaterialID(TERRAIN_GRASS_MAT_ID),
					subsurface_material_id = world_async.BlockMaterialID(TERRAIN_STONE_MAT_ID),
				}
				for y in 0 ..< CHUNK_BLOCK_LENGTH {
					index = chunk_block_index(u32(x), u32(y), u32(z))
					view.blocks.occupancy[index] = .Solid
					view.blocks.material_id[index] = world_async.BlockMaterialID(
						TERRAIN_CORRUPTED_ASH_MAT_ID,
					)
				}
			}
		}
		aquifer_origin := world_async.BlockCoord {
			x = 0,
			y = -CHUNK_BLOCK_LENGTH,
			z = 0,
		}
		terrain_density_carve_cave_room(
			&view,
			heightfield_key,
			aquifer_origin,
			test_columns[:],
			16,
			-16,
			16,
			9,
			6,
			9,
			.Underground_Lake,
			.Buried_Aquifer_Caves,
		)
		aquifer_open_count: u32
		aquifer_water_count: u32
		aquifer_wall_count: u32
		aquifer_floor_count: u32
		aquifer_ceiling_count: u32
		aquifer_wall_material := terrain_cave_wall_material_id(.Buried_Aquifer_Caves)
		aquifer_floor_material := terrain_cave_floor_material_id(.Buried_Aquifer_Caves)
		aquifer_ceiling_material := terrain_cave_ceiling_material_id(.Buried_Aquifer_Caves)
		for z in 0 ..< CHUNK_BLOCK_LENGTH {
			for y in 0 ..< CHUNK_BLOCK_LENGTH {
				for x in 0 ..< CHUNK_BLOCK_LENGTH {
					index = chunk_block_index(u32(x), u32(y), u32(z))
					palette := terrain_material_palette_index(view.blocks.material_id[index])
					if view.blocks.occupancy[index] == .Empty {
						aquifer_open_count += 1
					}
					if palette == TERRAIN_WATER_MAT_ID {
						aquifer_water_count += 1
					}
					if palette == terrain_material_palette_index(aquifer_wall_material) {
						aquifer_wall_count += 1
					}
					if palette == terrain_material_palette_index(aquifer_floor_material) {
						aquifer_floor_count += 1
					}
					if palette == terrain_material_palette_index(aquifer_ceiling_material) {
						aquifer_ceiling_count += 1
					}
				}
			}
		}
		log.assertf(
			aquifer_open_count > 64,
			"aquifer cave room should carve explorable open volume, got %d",
			aquifer_open_count,
		)
		log.assert(
			aquifer_water_count > 0,
			"aquifer cave room should fill lower pockets with water",
		)
		log.assert(
			aquifer_wall_count > 0,
			"aquifer cave room should expose subterranean biome wall material",
		)
		log.assert(aquifer_floor_count > 0, "aquifer cave room should expose wet floor material")
		log.assert(
			aquifer_ceiling_count > 0,
			"aquifer cave room should expose stone ceiling material",
		)

		chunk_voxel_view_fill_empty(&view)
		for z in 0 ..< CHUNK_BLOCK_LENGTH {
			for x in 0 ..< CHUNK_BLOCK_LENGTH {
				test_columns[x + z * CHUNK_BLOCK_LENGTH] = {
					surface_height         = 64,
					surface_height_blocks  = 64,
					surface_material_id    = world_async.BlockMaterialID(TERRAIN_GRASS_MAT_ID),
					subsurface_material_id = world_async.BlockMaterialID(TERRAIN_STONE_MAT_ID),
				}
				for y in 0 ..< CHUNK_BLOCK_LENGTH {
					index = chunk_block_index(u32(x), u32(y), u32(z))
					view.blocks.occupancy[index] = .Solid
					view.blocks.material_id[index] = world_async.BlockMaterialID(
						TERRAIN_STONE_MAT_ID,
					)
				}
			}
		}
		passage_region := new(biomes.GenerationRegion)
		passage_region.key = heightfield_key
		passage_from_id := biomes.FeatureID(0x101)
		passage_to_id := biomes.FeatureID(0x202)
		passage_region.cave_network_node_count = 2
		passage_region.cave_network_nodes[0] = {
			id                       = passage_from_id,
			kind                     = .Chamber,
			role                     = .Major_Region,
			biome_id                 = .Fungal_Vaults,
			x                        = 4,
			y                        = -16,
			z                        = 16,
			radius_blocks            = 7,
			connection_radius_blocks = 4,
			major_region             = true,
		}
		passage_region.cave_network_nodes[1] = {
			id                       = passage_to_id,
			kind                     = .Geode_Chamber,
			role                     = .Resource_Chamber,
			biome_id                 = .Crystal_Geode_Network,
			x                        = 28,
			y                        = -15,
			z                        = 16,
			radius_blocks            = 6,
			connection_radius_blocks = 4,
		}
		passage_edge := biomes.CaveNetworkEdge {
			id            = biomes.FeatureID(0x303),
			kind          = .Canyon,
			from_node_id  = passage_from_id,
			to_node_id    = passage_to_id,
			from_biome_id = .Fungal_Vaults,
			to_biome_id   = .Crystal_Geode_Network,
			from_x        = 4,
			from_y        = -16,
			from_z        = 16,
			bend_x        = 16,
			bend_y        = -15,
			bend_z        = 16,
			to_x          = 28,
			to_y          = -15,
			to_z          = 16,
			radius_blocks = 3.4,
		}
		terrain_density_carve_cave_edge(
			&view,
			passage_region,
			aquifer_origin,
			test_columns[:],
			passage_edge,
		)
		passage_fungal_wall_count: u32
		passage_crystal_wall_count: u32
		passage_fungal_wall_material := terrain_cave_wall_material_id(.Fungal_Vaults)
		passage_crystal_wall_material := terrain_cave_wall_material_id(.Crystal_Geode_Network)
		for z in 0 ..< CHUNK_BLOCK_LENGTH {
			for y in 0 ..< CHUNK_BLOCK_LENGTH {
				for x in 0 ..< CHUNK_BLOCK_LENGTH {
					index = chunk_block_index(u32(x), u32(y), u32(z))
					palette := terrain_material_palette_index(view.blocks.material_id[index])
					if palette == terrain_material_palette_index(passage_fungal_wall_material) {
						passage_fungal_wall_count += 1
					}
					if palette == terrain_material_palette_index(passage_crystal_wall_material) {
						passage_crystal_wall_count += 1
					}
				}
			}
		}
		log.assert(
			passage_fungal_wall_count > 0,
			"cave edge should inherit the from-node subterranean biome material",
		)
		log.assert(
			passage_crystal_wall_count > 0,
			"cave edge should inherit the to-node subterranean biome material",
		)

		cave_node := biomes.cave_network_node_from_owner(
			heightfield_key,
			biomes.FeatureGridCoord3{x = 0, y = 0, z = 0},
		)
		cave_center_block := world_async.BlockCoord {
			x = i32(math.floor_f32(cave_node.x)),
			y = i32(math.floor_f32(cave_node.y)),
			z = i32(math.floor_f32(cave_node.z)),
		}
		cave_chunk_coord := chunk_coord_from_block_coord(cave_center_block)
		terrain_heightfield_voxel_view_fill(&view, cave_chunk_coord, heightfield_seed)
		cave_local := block_coord_local_from_chunk_coord(cave_center_block, cave_chunk_coord)
		log.assert(
			chunk_block_coord_is_inside(cave_local.x, cave_local.y, cave_local.z),
			"cave node center should map inside its generated chunk",
		)
		cave_index := chunk_block_index(u32(cave_local.x), u32(cave_local.y), u32(cave_local.z))
		cave_palette := terrain_material_palette_index(view.blocks.material_id[cave_index])
		log.assertf(
			view.blocks.occupancy[cave_index] == .Empty || cave_palette == TERRAIN_WATER_MAT_ID,
			"cave node center should be carved or water-filled, occupancy=%v material=%d",
			view.blocks.occupancy[cave_index],
			cave_palette,
		)
		cave_open_count: u32
		for dz := i32(-4); dz <= 4; dz += 1 {
			for dy := i32(-4); dy <= 4; dy += 1 {
				for dx := i32(-4); dx <= 4; dx += 1 {
					lx := cave_local.x + dx
					ly := cave_local.y + dy
					lz := cave_local.z + dz
					if !chunk_block_coord_is_inside(lx, ly, lz) {
						continue
					}
					local_index := chunk_block_index(u32(lx), u32(ly), u32(lz))
					local_palette := terrain_material_palette_index(
						view.blocks.material_id[local_index],
					)
					if view.blocks.occupancy[local_index] == .Empty ||
					   local_palette == TERRAIN_WATER_MAT_ID {
						cave_open_count += 1
					}
				}
			}
		}
		log.assertf(
			cave_open_count > 12,
			"cave node room should carve a local volume, got %d open/water blocks",
			cave_open_count,
		)

		water_found := false
		for owner_z := i32(-2); owner_z <= 2 && !water_found; owner_z += 1 {
			for owner_x := i32(-2); owner_x <= 2 && !water_found; owner_x += 1 {
				water_node := biomes.water_feature_surface_node_from_owner(
					heightfield_key,
					biomes.FeatureGridCoord2{x = owner_x, z = owner_z},
				)
				water_block := world_async.BlockCoord {
					x = i32(math.floor_f32(water_node.x)),
					y = i32(math.floor_f32(water_node.water_level_blocks)),
					z = i32(math.floor_f32(water_node.z)),
				}
				water_chunk_coord := chunk_coord_from_block_coord(water_block)
				terrain_heightfield_voxel_view_fill(&view, water_chunk_coord, heightfield_seed)
				for z in 0 ..< CHUNK_BLOCK_LENGTH {
					for y in 0 ..< CHUNK_BLOCK_LENGTH {
						for x in 0 ..< CHUNK_BLOCK_LENGTH {
							index = chunk_block_index(u32(x), u32(y), u32(z))
							if view.blocks.occupancy[index] != .Solid {
								continue
							}
							if terrain_material_palette_index(view.blocks.material_id[index]) ==
							   TERRAIN_WATER_MAT_ID {
								water_found = true
								break
							}
						}
						if water_found {
							break
						}
					}
					if water_found {
						break
					}
				}
			}
		}
		log.assert(water_found, "surface hydrology should generate visible water blocks")
		debug_terrain_generation_quality_contract_checks_run(heightfield_key)

		terrain_heightfield_voxel_view_fill(&view, heightfield_coord, heightfield_seed)

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

			log.assertf(
				(vertex.material_id & (TERRAIN_MATERIAL_PALETTE_COUNT - 1)) <
				TERRAIN_MATERIAL_PALETTE_COUNT,
				"heightfield face %d: material out of palette range: %d",
				face_index,
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
