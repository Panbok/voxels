package world

import world_async "async:world"
import "base:runtime"
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
// Streaming Types
/////////////////////////////////////

StreamingState :: struct {
	streaming_center_coord:              world_async.ChunkCoord,
	streaming_targets:                   [CHUNK_STREAMING_TARGET_CAPACITY]world_async.ChunkCoord,
	streaming_target_count:              u32,
	streaming_prewarm_targets:           [CHUNK_STREAMING_PREWARM_TARGET_CAPACITY]world_async.ChunkCoord,
	streaming_prewarm_target_count:      u32,
	streaming_prewarm_inflight_coords:   [CHUNK_STREAMING_PREWARM_INFLIGHT_CAPACITY]world_async.ChunkCoord,
	streaming_prewarm_inflight_count:    u32,
	streaming_radius_y_down:             u32,
	streaming_radius_y_up:               u32,
	next_streaming_target_index:         u32,
	next_streaming_prewarm_target_index: u32,
	next_mesh_scan_index:                u32,
}

//////////////////////////////////////
// Streaming Update Types
/////////////////////////////////////

StreamingUpdateStats :: struct {
	chunks_generated:             u32,
	chunks_generated_full:        u32,
	chunks_generated_proxy:       u32,
	chunks_refined_full:          u32,
	chunks_prewarmed:             u32,
	generation_full_us:           u64,
	generation_proxy_us:          u64,
	generation_refined_full_us:   u64,
	generation_prewarm_us:        u64,
	chunks_evicted:               u32,
	chunk_mesh_jobs_submitted:    u32,
	chunk_mesh_results_committed: u32,
	chunk_mesh_results_uploaded:  u32,
	chunks_dirty_remaining:       u32,
}

GenerationResultsPollStats :: struct {
	chunks_generated:           u32,
	chunks_generated_full:      u32,
	chunks_generated_proxy:     u32,
	chunks_refined_full:        u32,
	chunks_prewarmed:           u32,
	generation_full_us:         u64,
	generation_proxy_us:        u64,
	generation_refined_full_us: u64,
	generation_prewarm_us:      u64,
}

ChunkWorkBudget :: struct {
	generation_requests_per_frame: u32,
	generation_results_per_frame:  u32,
	mesh_requests_per_frame:       u32,
	mesh_results_per_frame:        u32,
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
	chunk_work_budget:       ChunkWorkBudget,
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
	persistent_allocator:                  mem.Allocator,
	chunk_block_storage_buffer:            []u8,
	chunk_block_storage_tlsf:              mem_tlsf.Allocator,
	chunk_block_storage_allocator:         mem.Allocator,
	chunk_mesh_row_cache_buffer:           []u8,
	chunk_mesh_row_cache_tlsf:             mem_tlsf.Allocator,
	chunk_mesh_row_cache_allocator:        mem.Allocator,

	// Callbacks
	generation_request:                    GenerationRequestProc,
	generation_poll_results:               GenerationPollResultsProc,
	mesh_request:                          MeshRequestProc,
	mesh_poll_results:                     MeshPollResultsProc,
	mesh_release_result:                   MeshReleaseResultProc,
	chunk_mesh_upload:                     ChunkMeshUploadProc,
	chunk_geometry_release:                ChunkGeometryReleaseProc,

	// Storage
	chunk_store:                           ChunkStore,

	// Streaming
	using streaming:                       StreamingState,
	chunk_work_budget:                     ChunkWorkBudget,
	generation_result_buffer:              []world_async.ChunkGenerationJobResult,
	mesh_result_buffer:                    []world_async.ChunkMeshJobResult,
	terrain_generation_region_cache:       TerrainGenerationRegionCache,
	terrain_generation_cave_overlay_cache: TerrainGenerationCaveOverlayCache,
	terrain_generation_chunk_cache:        TerrainGenerationChunkCache,
	terrain_generation_column_cache:       TerrainGenerationColumnCache,

	// State
	initialized:                           bool,
}{}


//////////////////////////////////////
// Lifecycle Methods
/////////////////////////////////////

chunk_work_budget_default :: proc() -> ChunkWorkBudget {
	return {
		generation_requests_per_frame = CHUNK_GENERATION_REQUEST_BUDGET_PER_FRAME_DEFAULT,
		generation_results_per_frame = CHUNK_GENERATION_RESULT_BUDGET_PER_FRAME_DEFAULT,
		mesh_requests_per_frame = CHUNK_MESH_REQUEST_BUDGET_PER_FRAME_DEFAULT,
		mesh_results_per_frame = CHUNK_MESH_RESULT_BUDGET_PER_FRAME_DEFAULT,
	}
}

chunk_work_budget_resolve :: proc(budget: ChunkWorkBudget) -> ChunkWorkBudget {
	resolved := budget
	default_budget := chunk_work_budget_default()
	if resolved.generation_requests_per_frame == 0 {
		resolved.generation_requests_per_frame = default_budget.generation_requests_per_frame
	}
	if resolved.generation_results_per_frame == 0 {
		resolved.generation_results_per_frame = default_budget.generation_results_per_frame
	}
	if resolved.mesh_requests_per_frame == 0 {
		resolved.mesh_requests_per_frame = default_budget.mesh_requests_per_frame
	}
	if resolved.mesh_results_per_frame == 0 {
		resolved.mesh_results_per_frame = default_budget.mesh_results_per_frame
	}
	return resolved
}

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
	state.chunk_work_budget = chunk_work_budget_resolve(config.chunk_work_budget)
	state.generation_result_buffer = make(
		[]world_async.ChunkGenerationJobResult,
		int(state.chunk_work_budget.generation_results_per_frame),
		state.persistent_allocator,
	)
	state.mesh_result_buffer = make(
		[]world_async.ChunkMeshJobResult,
		int(state.chunk_work_budget.mesh_results_per_frame),
		state.persistent_allocator,
	)
	state.generation_request = config.generation_request
	state.generation_poll_results = config.generation_poll_results
	state.mesh_request = config.mesh_request
	state.mesh_poll_results = config.mesh_poll_results
	state.mesh_release_result = config.mesh_release_result
	state.chunk_mesh_upload = config.chunk_mesh_upload
	state.chunk_geometry_release = config.chunk_geometry_release
	state.terrain_generation_region_cache = {}
	terrain_generation_chunk_cache_init(state.persistent_allocator)
	terrain_generation_chunk_cache_clear()
	terrain_generation_cave_overlay_cache_init(state.persistent_allocator)
	terrain_generation_cave_overlay_cache_clear()
	terrain_generation_column_cache_clear()

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
	terrain_generation_cave_overlay_cache_destroy()
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

streaming_prewarm_target_count :: proc() -> u32 {
	return state.streaming_prewarm_target_count
}

streaming_prewarm_inflight_count :: proc() -> u32 {
	return state.streaming_prewarm_inflight_count
}

streaming_radius_y_down :: proc() -> u32 {
	return state.streaming_radius_y_down
}

streaming_radius_y_up :: proc() -> u32 {
	return state.streaming_radius_y_up
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

CHUNK_GENERATION_REQUEST_BUDGET_PER_FRAME_DEFAULT :: 1
CHUNK_GENERATION_RESULT_BUDGET_PER_FRAME_DEFAULT :: 1
CHUNK_MESH_REQUEST_BUDGET_PER_FRAME_DEFAULT :: 2
CHUNK_MESH_RESULT_BUDGET_PER_FRAME_DEFAULT :: 2

//////////////////////////////////////
// Streaming Constants
/////////////////////////////////////

CHUNK_STREAMING_RADIUS_XZ :: 3
CHUNK_STREAMING_NARROW_LAYER_RADIUS_XZ :: 2
CHUNK_STREAMING_RADIUS_Y_DOWN :: 2
CHUNK_STREAMING_RADIUS_Y_UP :: 1
TERRAIN_STREAMING_UNDERGROUND_PREWARM_ENABLED :: #config(
	TERRAIN_STREAMING_UNDERGROUND_PREWARM_ENABLED,
	true,
)
TERRAIN_STREAMING_UNDERGROUND_PREWARM_RADIUS_XZ :: #config(
	TERRAIN_STREAMING_UNDERGROUND_PREWARM_RADIUS_XZ,
	u32(1),
)
TERRAIN_STREAMING_UNDERGROUND_PREWARM_LAYERS_DOWN :: #config(
	TERRAIN_STREAMING_UNDERGROUND_PREWARM_LAYERS_DOWN,
	u32(1),
)
TERRAIN_STREAMING_UNDERGROUND_PREWARM_REQUESTS_PER_FRAME :: #config(
	TERRAIN_STREAMING_UNDERGROUND_PREWARM_REQUESTS_PER_FRAME,
	u32(1),
)
TERRAIN_STREAMING_UNDERGROUND_PROXY_LOD_ENABLED :: #config(
	TERRAIN_STREAMING_UNDERGROUND_PROXY_LOD_ENABLED,
	true,
)
CHUNK_STREAMING_PREWARM_TARGET_CAPACITY ::
	TERRAIN_STREAMING_UNDERGROUND_PREWARM_LAYERS_DOWN *
	(TERRAIN_STREAMING_UNDERGROUND_PREWARM_RADIUS_XZ * 2 + 1) *
	(TERRAIN_STREAMING_UNDERGROUND_PREWARM_RADIUS_XZ * 2 + 1)
CHUNK_STREAMING_PREWARM_INFLIGHT_CAPACITY :: CHUNK_STREAMING_PREWARM_TARGET_CAPACITY
#assert(CHUNK_STREAMING_PREWARM_TARGET_CAPACITY > 0)
#assert(CHUNK_STREAMING_PREWARM_INFLIGHT_CAPACITY > 0)
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
TERRAIN_GENERATION_CAVE_OVERLAY_CACHE_ENABLED :: #config(
	TERRAIN_GENERATION_CAVE_OVERLAY_CACHE_ENABLED,
	true,
)
TERRAIN_GENERATION_CAVE_OVERLAY_CACHE_CAPACITY :: #config(
	TERRAIN_GENERATION_CAVE_OVERLAY_CACHE_CAPACITY,
	8,
)
#assert(TERRAIN_GENERATION_CAVE_OVERLAY_CACHE_CAPACITY > 0)
TERRAIN_GENERATION_CHUNK_CACHE_ENABLED :: #config(TERRAIN_GENERATION_CHUNK_CACHE_ENABLED, true)
TERRAIN_GENERATION_CHUNK_CACHE_CAPACITY :: #config(
	TERRAIN_GENERATION_CHUNK_CACHE_CAPACITY,
	CHUNK_STREAMING_TARGET_CAPACITY,
)
#assert(TERRAIN_GENERATION_CHUNK_CACHE_CAPACITY > 0)
TERRAIN_GENERATION_COLUMN_CACHE_ENABLED :: #config(TERRAIN_GENERATION_COLUMN_CACHE_ENABLED, true)
TERRAIN_GENERATION_COLUMN_CACHE_CAPACITY :: #config(
	TERRAIN_GENERATION_COLUMN_CACHE_CAPACITY,
	CHUNK_STREAMING_TARGET_CAPACITY,
)
#assert(TERRAIN_GENERATION_COLUMN_CACHE_CAPACITY > 0)
TERRAIN_GENERATION_PROFILE_PHASES :: #config(TERRAIN_GENERATION_PROFILE_PHASES, false)
TERRAIN_CAVE_NETWORK_CHUNK_QUERY_ENABLED :: #config(TERRAIN_CAVE_NETWORK_CHUNK_QUERY_ENABLED, true)
TERRAIN_CAVE_NETWORK_CHUNK_QUERY_MARGIN_BLOCKS :: #config(
	TERRAIN_CAVE_NETWORK_CHUNK_QUERY_MARGIN_BLOCKS,
	320,
)
#assert(TERRAIN_CAVE_NETWORK_CHUNK_QUERY_MARGIN_BLOCKS >= biomes.CAVE_NETWORK_SAMPLE_MARGIN_BLOCKS)
TERRAIN_CAVE_FIELD_NETWORK_ROUTE_BOUNDS_ENABLED :: #config(
	TERRAIN_CAVE_FIELD_NETWORK_ROUTE_BOUNDS_ENABLED,
	true,
)
TERRAIN_CAVE_ROUTE_POCKET_CORE_BYPASS :: #config(TERRAIN_CAVE_ROUTE_POCKET_CORE_BYPASS, true)
TERRAIN_CAVE_ROUTE_POCKET_CORE_BYPASS_SHAPE_MAX :: #config(
	TERRAIN_CAVE_ROUTE_POCKET_CORE_BYPASS_SHAPE_MAX,
	f32(0.77),
)
TERRAIN_CAVE_WALL_MATERIAL_BUFFER_WORD_COUNT :: CHUNK_BLOCK_COUNT / 64
#assert(CHUNK_BLOCK_COUNT % 64 == 0)
TERRAIN_CAVE_CHUNK_OVERLAY_WORD_COUNT :: CHUNK_BLOCK_COUNT / 64
#assert(CHUNK_BLOCK_COUNT % 64 == 0)
TERRAIN_CAVE_EDGE_CHUNK_INTERSECT_FEATURE_RADIUS_SCALE :: #config(
	TERRAIN_CAVE_EDGE_CHUNK_INTERSECT_FEATURE_RADIUS_SCALE,
	f32(8.0),
)
TERRAIN_CAVE_EDGE_CHUNK_INTERSECT_FEATURE_PADDING_BLOCKS :: #config(
	TERRAIN_CAVE_EDGE_CHUNK_INTERSECT_FEATURE_PADDING_BLOCKS,
	f32(72),
)
TERRAIN_CAVE_EDGE_CHUNK_INTERSECT_BASE_PADDING_BLOCKS :: #config(
	TERRAIN_CAVE_EDGE_CHUNK_INTERSECT_BASE_PADDING_BLOCKS,
	f32(96),
)
TERRAIN_CAVE_EDGE_CHUNK_INTERSECT_SEAM_PADDING_BLOCKS :: #config(
	TERRAIN_CAVE_EDGE_CHUNK_INTERSECT_SEAM_PADDING_BLOCKS,
	f32(220),
)

when TERRAIN_GENERATION_PROFILE_PHASES {
	TerrainGenerationProfileStats :: struct {
		chunk_count:                                 u64,
		total:                                       time.Duration,
		clear:                                       time.Duration,
		region:                                      time.Duration,
		columns:                                     time.Duration,
		column_cache:                                time.Duration,
		base_fill:                                   time.Duration,
		cave_field:                                  time.Duration,
		cave_field_scan:                             time.Duration,
		cave_field_network:                          time.Duration,
		cave_field_path:                             time.Duration,
		cave_field_pocket_throat:                    time.Duration,
		cave_field_pocket_cluster:                   time.Duration,
		cave_field_chamber:                          time.Duration,
		cave_field_bridge:                           time.Duration,
		route_pocket_cluster_rows_scanned:           u64,
		route_pocket_cluster_rows_box:               u64,
		route_pocket_cluster_voxel_candidates:       u64,
		route_pocket_cluster_carveable_candidates:   u64,
		route_pocket_cluster_shape_candidates:       u64,
		route_pocket_cluster_worley_candidates:      u64,
		cave_network:                                time.Duration,
		water:                                       time.Duration,
		decoration:                                  time.Duration,
		network_connectivity:                        time.Duration,
		network_nodes:                               time.Duration,
		network_edges:                               time.Duration,
		network_bridges:                             time.Duration,
		network_anchors:                             time.Duration,
		node_rooms:                                  time.Duration,
		node_perimeter:                              time.Duration,
		node_satellites:                             time.Duration,
		node_portals:                                time.Duration,
		node_satellite_direct:                       time.Duration,
		node_satellite_apron:                        time.Duration,
		node_satellite_cluster:                      time.Duration,
		edge_core:                                   time.Duration,
		edge_approach:                               time.Duration,
		edge_braids:                                 time.Duration,
		edge_bypasses:                               time.Duration,
		edge_alcoves:                                time.Duration,
		edge_chamberlets:                            time.Duration,
		edge_seams:                                  time.Duration,
		edge_core_segment_calls:                     u64,
		edge_core_segment_bounds_hits:               u64,
		edge_core_rows_scanned:                      u64,
		edge_core_rows_projected:                    u64,
		edge_core_rows_capsule:                      u64,
		edge_core_voxel_candidates:                  u64,
		edge_core_carveable_candidates:              u64,
		edge_core_shape_candidates:                  u64,
		edge_core_noise_candidates:                  u64,
		edge_core_threshold_candidates:              u64,
		carve_attempts:                              u64,
		carve_successes:                             u64,
		wall_neighbor_checks:                        u64,
		wall_neighbor_writes:                        u64,
		decoration_surface_candidates:               u64,
		decoration_surface_accepted:                 u64,
		decoration_surface_tree_instances_attempted: u64,
		decoration_surface_tree_instances_accepted:  u64,
		decoration_surface_tree_root_rejected:       u64,
		decoration_surface_tree_shape_rejected:      u64,
		decoration_cave_candidates:                  u64,
		decoration_cave_accepted:                    u64,
		decoration_blocks_written:                   u64,
		decoration_family_candidates:                [biomes.DECORATION_FAMILY_COUNT]u64,
		decoration_family_accepted:                  [biomes.DECORATION_FAMILY_COUNT]u64,
		decoration_family_blocks:                    [biomes.DECORATION_FAMILY_COUNT]u64,
		surface_morphology_chunks:                   u64,
		surface_heightfield_chunks:                  u64,
		surface_morphology_features:                 u64,
		surface_morphology_feature_columns:          u64,
	}

	terrain_generation_profile_stats: TerrainGenerationProfileStats
	terrain_generation_profile_edge_core_active: bool

	terrain_generation_profile_reset :: proc() {
		terrain_generation_profile_stats = {}
		terrain_generation_profile_edge_core_active = false
	}

	terrain_generation_profile_avg_us :: proc(duration: time.Duration, chunk_count: u64) -> f64 {
		if chunk_count == 0 {
			return 0
		}
		return time.duration_microseconds(duration) / f64(chunk_count)
	}

	terrain_generation_profile_log :: proc(phase: string) {
		stats := terrain_generation_profile_stats
		log.infof(
			"TERRAIN_GENERATION_PROFILE phase=%s chunks=%d total_ms=%.3f avg_us_per_chunk=%.3f clear_ms=%.3f region_ms=%.3f columns_ms=%.3f cave_field_ms=%.3f cave_network_ms=%.3f water_ms=%.3f decoration_ms=%.3f network_connectivity_ms=%.3f network_nodes_ms=%.3f network_edges_ms=%.3f network_bridges_ms=%.3f network_anchors_ms=%.3f",
			phase,
			stats.chunk_count,
			time.duration_milliseconds(stats.total),
			terrain_generation_profile_avg_us(stats.total, stats.chunk_count),
			time.duration_milliseconds(stats.clear),
			time.duration_milliseconds(stats.region),
			time.duration_milliseconds(stats.columns),
			time.duration_milliseconds(stats.cave_field),
			time.duration_milliseconds(stats.cave_network),
			time.duration_milliseconds(stats.water),
			time.duration_milliseconds(stats.decoration),
			time.duration_milliseconds(stats.network_connectivity),
			time.duration_milliseconds(stats.network_nodes),
			time.duration_milliseconds(stats.network_edges),
			time.duration_milliseconds(stats.network_bridges),
			time.duration_milliseconds(stats.network_anchors),
		)
		log.infof(
			"TERRAIN_GENERATION_PROFILE_SURFACE_FILL phase=%s column_cache_ms=%.3f base_fill_ms=%.3f morphology_chunks=%d heightfield_chunks=%d morphology_features=%d morphology_feature_columns=%d",
			phase,
			time.duration_milliseconds(stats.column_cache),
			time.duration_milliseconds(stats.base_fill),
			stats.surface_morphology_chunks,
			stats.surface_heightfield_chunks,
			stats.surface_morphology_features,
			stats.surface_morphology_feature_columns,
		)
		log.infof(
			"TERRAIN_GENERATION_PROFILE_NODE phase=%s node_rooms_ms=%.3f node_perimeter_ms=%.3f node_satellites_ms=%.3f node_portals_ms=%.3f",
			phase,
			time.duration_milliseconds(stats.node_rooms),
			time.duration_milliseconds(stats.node_perimeter),
			time.duration_milliseconds(stats.node_satellites),
			time.duration_milliseconds(stats.node_portals),
		)
		log.infof(
			"TERRAIN_GENERATION_PROFILE_CAVE_FIELD phase=%s scan_ms=%.3f network_ms=%.3f path_ms=%.3f pocket_throat_ms=%.3f pocket_cluster_ms=%.3f chamber_ms=%.3f bridge_ms=%.3f",
			phase,
			time.duration_milliseconds(stats.cave_field_scan),
			time.duration_milliseconds(stats.cave_field_network),
			time.duration_milliseconds(stats.cave_field_path),
			time.duration_milliseconds(stats.cave_field_pocket_throat),
			time.duration_milliseconds(stats.cave_field_pocket_cluster),
			time.duration_milliseconds(stats.cave_field_chamber),
			time.duration_milliseconds(stats.cave_field_bridge),
		)
		log.infof(
			"TERRAIN_GENERATION_PROFILE_ROUTE_POCKET_CLUSTER phase=%s rows_scanned=%d rows_box=%d voxel_candidates=%d carveable_candidates=%d shape_candidates=%d worley_candidates=%d",
			phase,
			stats.route_pocket_cluster_rows_scanned,
			stats.route_pocket_cluster_rows_box,
			stats.route_pocket_cluster_voxel_candidates,
			stats.route_pocket_cluster_carveable_candidates,
			stats.route_pocket_cluster_shape_candidates,
			stats.route_pocket_cluster_worley_candidates,
		)
		log.infof(
			"TERRAIN_GENERATION_PROFILE_NODE_DETAIL phase=%s satellite_direct_ms=%.3f satellite_apron_ms=%.3f satellite_cluster_ms=%.3f",
			phase,
			time.duration_milliseconds(stats.node_satellite_direct),
			time.duration_milliseconds(stats.node_satellite_apron),
			time.duration_milliseconds(stats.node_satellite_cluster),
		)
		log.infof(
			"TERRAIN_GENERATION_PROFILE_EDGE phase=%s edge_core_ms=%.3f edge_approach_ms=%.3f edge_braids_ms=%.3f edge_bypasses_ms=%.3f edge_alcoves_ms=%.3f edge_chamberlets_ms=%.3f edge_seams_ms=%.3f",
			phase,
			time.duration_milliseconds(stats.edge_core),
			time.duration_milliseconds(stats.edge_approach),
			time.duration_milliseconds(stats.edge_braids),
			time.duration_milliseconds(stats.edge_bypasses),
			time.duration_milliseconds(stats.edge_alcoves),
			time.duration_milliseconds(stats.edge_chamberlets),
			time.duration_milliseconds(stats.edge_seams),
		)
		log.infof(
			"TERRAIN_GENERATION_PROFILE_EDGE_CORE_DETAIL phase=%s segment_calls=%d segment_bounds_hits=%d rows_scanned=%d rows_projected=%d rows_capsule=%d voxel_candidates=%d carveable_candidates=%d shape_candidates=%d noise_candidates=%d threshold_candidates=%d",
			phase,
			stats.edge_core_segment_calls,
			stats.edge_core_segment_bounds_hits,
			stats.edge_core_rows_scanned,
			stats.edge_core_rows_projected,
			stats.edge_core_rows_capsule,
			stats.edge_core_voxel_candidates,
			stats.edge_core_carveable_candidates,
			stats.edge_core_shape_candidates,
			stats.edge_core_noise_candidates,
			stats.edge_core_threshold_candidates,
		)
		log.infof(
			"TERRAIN_GENERATION_PROFILE_CARVE phase=%s carve_attempts=%d carve_successes=%d wall_neighbor_checks=%d wall_neighbor_writes=%d",
			phase,
			stats.carve_attempts,
			stats.carve_successes,
			stats.wall_neighbor_checks,
			stats.wall_neighbor_writes,
		)
		log.infof(
			"TERRAIN_GENERATION_PROFILE_DECORATION phase=%s surface_candidates=%d surface_accepted=%d cave_candidates=%d cave_accepted=%d blocks_written=%d",
			phase,
			stats.decoration_surface_candidates,
			stats.decoration_surface_accepted,
			stats.decoration_cave_candidates,
			stats.decoration_cave_accepted,
			stats.decoration_blocks_written,
		)
		log.infof(
			"TERRAIN_GENERATION_PROFILE_DECORATION_TREE phase=%s attempted=%d accepted=%d root_rejected=%d shape_rejected=%d",
			phase,
			stats.decoration_surface_tree_instances_attempted,
			stats.decoration_surface_tree_instances_accepted,
			stats.decoration_surface_tree_root_rejected,
			stats.decoration_surface_tree_shape_rejected,
		)
		log.infof(
			"TERRAIN_GENERATION_PROFILE_DECORATION_FAMILY phase=%s baseline_candidates=%d baseline_accepted=%d baseline_blocks=%d dead_ash_candidates=%d dead_ash_accepted=%d dead_ash_blocks=%d fungal_candidates=%d fungal_accepted=%d fungal_blocks=%d stone_candidates=%d stone_accepted=%d stone_blocks=%d crystal_candidates=%d crystal_accepted=%d crystal_blocks=%d",
			phase,
			stats.decoration_family_candidates[u32(biomes.DecorationFamilyID.Baseline_Tree)],
			stats.decoration_family_accepted[u32(biomes.DecorationFamilyID.Baseline_Tree)],
			stats.decoration_family_blocks[u32(biomes.DecorationFamilyID.Baseline_Tree)],
			stats.decoration_family_candidates[u32(biomes.DecorationFamilyID.Dead_Ash_Tree)],
			stats.decoration_family_accepted[u32(biomes.DecorationFamilyID.Dead_Ash_Tree)],
			stats.decoration_family_blocks[u32(biomes.DecorationFamilyID.Dead_Ash_Tree)],
			stats.decoration_family_candidates[u32(biomes.DecorationFamilyID.Fungal_Tree)],
			stats.decoration_family_accepted[u32(biomes.DecorationFamilyID.Fungal_Tree)],
			stats.decoration_family_blocks[u32(biomes.DecorationFamilyID.Fungal_Tree)],
			stats.decoration_family_candidates[u32(biomes.DecorationFamilyID.Stone_Tree)],
			stats.decoration_family_accepted[u32(biomes.DecorationFamilyID.Stone_Tree)],
			stats.decoration_family_blocks[u32(biomes.DecorationFamilyID.Stone_Tree)],
			stats.decoration_family_candidates[u32(biomes.DecorationFamilyID.Crystal_Growth_Cluster)],
			stats.decoration_family_accepted[u32(biomes.DecorationFamilyID.Crystal_Growth_Cluster)],
			stats.decoration_family_blocks[u32(biomes.DecorationFamilyID.Crystal_Growth_Cluster)],
		)
		log.infof(
			"TERRAIN_GENERATION_PROFILE_DECORATION_FAMILY_EXTRA phase=%s fern=%d/%d/%d bramble=%d/%d/%d root=%d/%d/%d coral=%d/%d/%d ruin=%d/%d/%d hamlet=%d/%d/%d tower=%d/%d/%d fort=%d/%d/%d cave_hall=%d/%d/%d basalt=%d/%d/%d lava=%d/%d/%d",
			phase,
			stats.decoration_family_candidates[u32(biomes.DecorationFamilyID.Fern_Thicket)],
			stats.decoration_family_accepted[u32(biomes.DecorationFamilyID.Fern_Thicket)],
			stats.decoration_family_blocks[u32(biomes.DecorationFamilyID.Fern_Thicket)],
			stats.decoration_family_candidates[u32(biomes.DecorationFamilyID.Ash_Bramble)],
			stats.decoration_family_accepted[u32(biomes.DecorationFamilyID.Ash_Bramble)],
			stats.decoration_family_blocks[u32(biomes.DecorationFamilyID.Ash_Bramble)],
			stats.decoration_family_candidates[u32(biomes.DecorationFamilyID.Root_Cluster)],
			stats.decoration_family_accepted[u32(biomes.DecorationFamilyID.Root_Cluster)],
			stats.decoration_family_blocks[u32(biomes.DecorationFamilyID.Root_Cluster)],
			stats.decoration_family_candidates[u32(biomes.DecorationFamilyID.Coral_DLA_Cluster)],
			stats.decoration_family_accepted[u32(biomes.DecorationFamilyID.Coral_DLA_Cluster)],
			stats.decoration_family_blocks[u32(biomes.DecorationFamilyID.Coral_DLA_Cluster)],
			stats.decoration_family_candidates[u32(biomes.DecorationFamilyID.Ruin_Pillar_Set)],
			stats.decoration_family_accepted[u32(biomes.DecorationFamilyID.Ruin_Pillar_Set)],
			stats.decoration_family_blocks[u32(biomes.DecorationFamilyID.Ruin_Pillar_Set)],
			stats.decoration_family_candidates[u32(biomes.DecorationFamilyID.Ruin_Hamlet)],
			stats.decoration_family_accepted[u32(biomes.DecorationFamilyID.Ruin_Hamlet)],
			stats.decoration_family_blocks[u32(biomes.DecorationFamilyID.Ruin_Hamlet)],
			stats.decoration_family_candidates[u32(biomes.DecorationFamilyID.Watchtower_Ruin)],
			stats.decoration_family_accepted[u32(biomes.DecorationFamilyID.Watchtower_Ruin)],
			stats.decoration_family_blocks[u32(biomes.DecorationFamilyID.Watchtower_Ruin)],
			stats.decoration_family_candidates[u32(biomes.DecorationFamilyID.Palisade_Fort)],
			stats.decoration_family_accepted[u32(biomes.DecorationFamilyID.Palisade_Fort)],
			stats.decoration_family_blocks[u32(biomes.DecorationFamilyID.Palisade_Fort)],
			stats.decoration_family_candidates[u32(biomes.DecorationFamilyID.Cave_Ruin_Hall)],
			stats.decoration_family_accepted[u32(biomes.DecorationFamilyID.Cave_Ruin_Hall)],
			stats.decoration_family_blocks[u32(biomes.DecorationFamilyID.Cave_Ruin_Hall)],
			stats.decoration_family_candidates[u32(biomes.DecorationFamilyID.Basalt_Column_Cluster)],
			stats.decoration_family_accepted[u32(biomes.DecorationFamilyID.Basalt_Column_Cluster)],
			stats.decoration_family_blocks[u32(biomes.DecorationFamilyID.Basalt_Column_Cluster)],
			stats.decoration_family_candidates[u32(biomes.DecorationFamilyID.Lava_Vent)],
			stats.decoration_family_accepted[u32(biomes.DecorationFamilyID.Lava_Vent)],
			stats.decoration_family_blocks[u32(biomes.DecorationFamilyID.Lava_Vent)],
		)
	}
}

//////////////////////////////////////
// Streaming Pipeline Methods
/////////////////////////////////////

streaming_prewarm_inflight_contains :: proc(coord: world_async.ChunkCoord) -> bool {
	for i := u32(0); i < state.streaming_prewarm_inflight_count; i += 1 {
		if state.streaming_prewarm_inflight_coords[i] == coord {
			return true
		}
	}
	return false
}

streaming_prewarm_inflight_add :: proc(coord: world_async.ChunkCoord) -> bool {
	if streaming_prewarm_inflight_contains(coord) {
		return true
	}
	if state.streaming_prewarm_inflight_count >= CHUNK_STREAMING_PREWARM_INFLIGHT_CAPACITY {
		return false
	}
	state.streaming_prewarm_inflight_coords[state.streaming_prewarm_inflight_count] = coord
	state.streaming_prewarm_inflight_count += 1
	return true
}

streaming_prewarm_inflight_remove :: proc(coord: world_async.ChunkCoord) {
	for i := u32(0); i < state.streaming_prewarm_inflight_count; i += 1 {
		if state.streaming_prewarm_inflight_coords[i] != coord {
			continue
		}
		last_index := state.streaming_prewarm_inflight_count - 1
		state.streaming_prewarm_inflight_coords[i] =
			state.streaming_prewarm_inflight_coords[last_index]
		state.streaming_prewarm_inflight_coords[last_index] = {}
		state.streaming_prewarm_inflight_count -= 1
		return
	}
}

streaming_coord_should_generate_proxy :: proc(coord: world_async.ChunkCoord) -> bool {
	when !TERRAIN_STREAMING_UNDERGROUND_PROXY_LOD_ENABLED {
		_ = coord
		return false
	}
	return coord.y < state.streaming_center_coord.y
}

streaming_missing_proxy_target_exists :: proc() -> bool {
	when !TERRAIN_STREAMING_UNDERGROUND_PROXY_LOD_ENABLED {
		return false
	}
	for i := u32(0); i < state.streaming_target_count; i += 1 {
		coord := state.streaming_targets[i]
		if !streaming_coord_should_generate_proxy(coord) {
			continue
		}
		chunk_index, ok := chunk_store_find_index_by_coord(coord).?
		if !ok {
			return true
		}
		chunk := chunk_store_get_by_index(chunk_index)
		if chunk.generation_state == .Missing {
			return true
		}
	}
	return false
}

generation_request_budgeted :: proc() -> u32 {
	if state.streaming_target_count == 0 {
		return 0
	}

	generation_request_count: u32
	missing_proxy_target_exists := streaming_missing_proxy_target_exists()

	scanned_count: u32
	for generation_request_count < state.chunk_work_budget.generation_requests_per_frame &&
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

		if chunk.generation_state == .Generated && chunk.generation_quality == .Proxy {
			if missing_proxy_target_exists ||
			   chunk.full_generation_queued ||
			   chunk.mesh_state != .Ready ||
			   chunk.mesh_snapshot_ref_count > 0 {
				continue
			}

			block_storage := chunk_block_storage_alloc_for_store()
			job := world_async.ChunkGenerationJob {
				coord         = coord,
				seed          = 0,
				block_storage = block_storage,
				quality       = .Full,
			}
			if !state.generation_request(job) {
				chunk_block_storage_release(&job.block_storage)
				break
			}
			chunk.full_generation_queued = true
			generation_request_count += 1
			continue
		}

		if chunk.generation_state != .Missing {
			continue
		}
		if streaming_prewarm_inflight_contains(coord) {
			continue
		}

		quality := world_async.ChunkGenerationQuality.Full
		if streaming_coord_should_generate_proxy(coord) {
			quality = .Proxy
		}

		block_storage := chunk_block_storage_alloc_for_store()
		if terrain_generation_chunk_cache_try_read(
			&block_storage.voxel_view,
			terrain_generation_key_make(0),
			coord,
		) {
			if block_storage.binary_greedy_row_cache != nil {
				terrain_binary_row_cache_fill(
					block_storage.binary_greedy_row_cache,
					block_storage.voxel_view,
					0,
				)
			}
			chunk_mark_generated(chunk, block_storage, .Full)
			chunk_store_mark_generated_neighbors_boundary_dirty(coord)
			generation_request_count += 1
			continue
		}

		job := world_async.ChunkGenerationJob {
			coord         = coord,
			seed          = 0,
			block_storage = block_storage,
			quality       = quality,
		}
		if !state.generation_request(job) {
			chunk_block_storage_release(&job.block_storage)
			break
		}

		chunk.block_storage = job.block_storage
		chunk.generation_state = .Queued
		chunk.generation_quality = quality
		generation_request_count += 1
	}

	return generation_request_count
}

generation_prewarm_request_budgeted :: proc() -> u32 {
	when !TERRAIN_STREAMING_UNDERGROUND_PREWARM_ENABLED {
		return 0
	}
	if state.streaming_prewarm_target_count == 0 {
		return 0
	}

	key := terrain_generation_key_make(0)
	request_count: u32
	scanned_count: u32
	for request_count < TERRAIN_STREAMING_UNDERGROUND_PREWARM_REQUESTS_PER_FRAME &&
	    scanned_count < state.streaming_prewarm_target_count {
		target_index := state.next_streaming_prewarm_target_index
		state.next_streaming_prewarm_target_index =
			(state.next_streaming_prewarm_target_index + 1) % state.streaming_prewarm_target_count
		scanned_count += 1

		coord := state.streaming_prewarm_targets[target_index]
		if chunk_store_find_index_by_coord(coord) != nil {
			continue
		}
		if streaming_prewarm_inflight_contains(coord) {
			continue
		}
		if terrain_generation_chunk_cache_contains(key, coord) {
			continue
		}
		if !streaming_prewarm_inflight_add(coord) {
			break
		}

		block_storage := chunk_block_storage_alloc_for_store()
		job := world_async.ChunkGenerationJob {
			coord         = coord,
			seed          = 0,
			block_storage = block_storage,
			prewarm       = true,
		}
		if !state.generation_request(job) {
			streaming_prewarm_inflight_remove(coord)
			chunk_block_storage_release(&job.block_storage)
			break
		}
		request_count += 1
	}
	return request_count
}

generation_results_poll_budgeted :: proc() -> GenerationResultsPollStats {
	result_count := state.generation_poll_results(state.generation_result_buffer)
	if result_count == 0 {
		return {}
	}

	stats := GenerationResultsPollStats {
		chunks_generated = result_count,
	}
	for i := 0; i < int(result_count); i += 1 {
		generation_result := &state.generation_result_buffer[i]
		log.assertf(
			len(generation_result.block_storage.voxel_view.blocks) == CHUNK_BLOCK_COUNT,
			"generated chunk storage has wrong block count",
		)

		if generation_result.prewarm {
			stats.chunks_prewarmed += 1
			stats.generation_prewarm_us += generation_result.generation_duration_us
			streaming_prewarm_inflight_remove(generation_result.coord)
			index, ok := chunk_store_find_index_by_coord(generation_result.coord).?
			if ok {
				chunk := chunk_store_get_by_index(index)
				if chunk.generation_state == .Missing {
					chunk_mark_generated(
						chunk,
						generation_result.block_storage,
						generation_result.quality,
					)
					if generation_result.quality == .Proxy {
						stats.chunks_generated_proxy += 1
						stats.generation_proxy_us += generation_result.generation_duration_us
					} else {
						stats.chunks_generated_full += 1
						stats.generation_full_us += generation_result.generation_duration_us
					}
					chunk_store_mark_generated_neighbors_boundary_dirty(generation_result.coord)
					continue
				}
			}
			chunk_block_storage_release(&generation_result.block_storage)
			continue
		}

		index, ok := chunk_store_find_index_by_coord(generation_result.coord).?
		if !ok {
			chunk_block_storage_release(&generation_result.block_storage)
			continue
		}

		chunk := chunk_store_get_by_index(index)
		if chunk.generation_state == .Generated {
			if generation_result.quality == .Full &&
			   chunk.generation_quality == .Proxy &&
			   chunk.full_generation_queued {
				if chunk.mesh_snapshot_ref_count > 0 {
					chunk.full_generation_queued = false
					chunk_block_storage_release(&generation_result.block_storage)
					continue
				}
				old_storage := chunk.block_storage
				chunk_mark_generated(chunk, generation_result.block_storage, .Full)
				chunk_store_mark_generated_neighbors_boundary_dirty(generation_result.coord)
				chunk_block_storage_release(&old_storage)
				stats.chunks_generated_full += 1
				stats.chunks_refined_full += 1
				stats.generation_full_us += generation_result.generation_duration_us
				stats.generation_refined_full_us += generation_result.generation_duration_us
				continue
			}
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
		chunk_mark_generated(chunk, generation_result.block_storage, generation_result.quality)
		if generation_result.quality == .Proxy {
			stats.chunks_generated_proxy += 1
			stats.generation_proxy_us += generation_result.generation_duration_us
		} else {
			stats.chunks_generated_full += 1
			stats.generation_full_us += generation_result.generation_duration_us
		}
		chunk_store_mark_generated_neighbors_boundary_dirty(generation_result.coord)
	}

	return stats
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
	    mesh_request_count < state.chunk_work_budget.mesh_requests_per_frame;
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
	result_count := state.mesh_poll_results(state.mesh_result_buffer)
	if result_count == 0 {
		return {}
	}

	return chunk_store_commit_mesh_results(state.mesh_result_buffer[:int(result_count)])
}

streaming_update_budgeted :: proc(observer_world_position: Vec3) -> StreamingUpdateStats {
	stats := StreamingUpdateStats{}

	mesh_stats := mesh_results_poll_budgeted()
	generation_stats := generation_results_poll_budgeted()
	stats.chunks_generated = generation_stats.chunks_generated
	stats.chunks_generated_full = generation_stats.chunks_generated_full
	stats.chunks_generated_proxy = generation_stats.chunks_generated_proxy
	stats.chunks_refined_full = generation_stats.chunks_refined_full
	stats.chunks_prewarmed = generation_stats.chunks_prewarmed
	stats.generation_full_us = generation_stats.generation_full_us
	stats.generation_proxy_us = generation_stats.generation_proxy_us
	stats.generation_refined_full_us = generation_stats.generation_refined_full_us
	stats.generation_prewarm_us = generation_stats.generation_prewarm_us
	stats.chunks_evicted = streaming_update_for_observer(observer_world_position)
	generation_request_budgeted()
	generation_prewarm_request_budgeted()

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
	radius_y_down, radius_y_up := streaming_vertical_radii_from_observer()
	if state.streaming_target_count == 0 ||
	   center != state.streaming_center_coord ||
	   radius_y_down != state.streaming_radius_y_down ||
	   radius_y_up != state.streaming_radius_y_up {
		streaming_window_rebuild_targets(center, radius_y_down, radius_y_up)
	}
	return streaming_evict_outside_unload_radius()
}

streaming_center_from_observer :: proc(observer_world_position: Vec3) -> world_async.ChunkCoord {
	return chunk_coord_from_block_coord(block_coord_from_world_position(observer_world_position))
}

streaming_vertical_radii_from_observer :: proc() -> (radius_y_down, radius_y_up: u32) {
	radius_y_down = CHUNK_STREAMING_RADIUS_Y_DOWN
	radius_y_up = CHUNK_STREAMING_RADIUS_Y_UP
	return
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
	if dy < -i32(state.streaming_radius_y_down) || dy > i32(state.streaming_radius_y_up) {
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

	ad := adx * adx + ady * ady + adz * adz
	bd := bdx * bdx + bdy * bdy + bdz * bdz
	if ad != bd {return ad < bd}
	if abs(ady) != abs(bdy) {return abs(ady) < abs(bdy)}
	ah := adx * adx + adz * adz
	bh := bdx * bdx + bdz * bdz
	if ah != bh {return ah < bh}
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

streaming_window_rebuild_targets :: proc(
	center: world_async.ChunkCoord,
	radius_y_down, radius_y_up: u32,
) {
	state.streaming_center_coord = center
	state.streaming_radius_y_down = radius_y_down
	state.streaming_radius_y_up = radius_y_up
	state.streaming_target_count = 0

	for dy := -i32(radius_y_down); dy <= i32(radius_y_up); dy += 1 {
		radius := streaming_layer_radius_xz_from_dy(dy)
		for dz := -radius; dz <= radius; dz += 1 {
			for dx := -radius; dx <= radius; dx += 1 {
				log.assert(
					state.streaming_target_count < CHUNK_STREAMING_TARGET_CAPACITY,
					"streaming target capacity exceeded",
				)
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
	streaming_prewarm_window_rebuild_targets(center, radius_y_down == 0)
}

streaming_prewarm_window_rebuild_targets :: proc(center: world_async.ChunkCoord, active: bool) {
	state.streaming_prewarm_target_count = 0
	state.next_streaming_prewarm_target_index = 0

	when !TERRAIN_STREAMING_UNDERGROUND_PREWARM_ENABLED {
		_ = center
		_ = active
		return
	}

	if !active {
		return
	}

	for layer := u32(1); layer <= TERRAIN_STREAMING_UNDERGROUND_PREWARM_LAYERS_DOWN; layer += 1 {
		dy := -i32(layer)
		radius := i32(TERRAIN_STREAMING_UNDERGROUND_PREWARM_RADIUS_XZ)
		for dz := -radius; dz <= radius; dz += 1 {
			for dx := -radius; dx <= radius; dx += 1 {
				log.assert(
					state.streaming_prewarm_target_count < CHUNK_STREAMING_PREWARM_TARGET_CAPACITY,
					"streaming prewarm target capacity exceeded",
				)
				state.streaming_prewarm_targets[state.streaming_prewarm_target_count] = {
					center.x + dx,
					center.y + dy,
					center.z + dz,
				}
				state.streaming_prewarm_target_count += 1
			}
		}
	}

	for i := u32(0); i < state.streaming_prewarm_target_count; i += 1 {
		best := i
		for j := i + 1; j < state.streaming_prewarm_target_count; j += 1 {
			if streaming_target_less(
				center,
				state.streaming_prewarm_targets[j],
				state.streaming_prewarm_targets[best],
			) {
				best = j
			}
		}
		if best != i {
			state.streaming_prewarm_targets[i], state.streaming_prewarm_targets[best] =
				state.streaming_prewarm_targets[best], state.streaming_prewarm_targets[i]
		}
	}
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
TERRAIN_DECORATION_DEBUG_MATERIAL_FLAG ::
	TERRAIN_HYDROLOGY_DEBUG_MATERIAL_FLAG | TERRAIN_CAVE_NETWORK_DEBUG_MATERIAL_FLAG
TERRAIN_MATERIAL_COLOR_VARIANT_SHIFT :: u8(5)
TERRAIN_MATERIAL_COLOR_VARIANT_COUNT :: u32(4)
TERRAIN_MATERIAL_COLOR_VARIANT_MASK :: u8(0x60)
TERRAIN_DEBUG_MATERIAL_FLAG_COMBO_HYDROLOGY :: u32(0x1)
TERRAIN_DEBUG_MATERIAL_FLAG_COMBO_CAVE_NETWORK :: u32(0x2)
TERRAIN_DEBUG_MATERIAL_FLAG_COMBO_COUNT :: u32(4)
TERRAIN_MATERIAL_PALETTE_COUNT :: 8
TERRAIN_MATERIAL_COLOR_COUNT ::
	TERRAIN_MATERIAL_PALETTE_COUNT * TERRAIN_MATERIAL_COLOR_VARIANT_COUNT
TERRAIN_BAKE_DEBUG_MATERIAL_FLAGS :: #config(TERRAIN_BAKE_DEBUG_MATERIAL_FLAGS, false)
TERRAIN_MATERIAL_FACE_DEBUG_VARIANTS_ENABLED :: ODIN_DEBUG || TERRAIN_BAKE_DEBUG_MATERIAL_FLAGS
when TERRAIN_MATERIAL_FACE_DEBUG_VARIANTS_ENABLED {
	TERRAIN_MATERIAL_FACE_VARIANT_COUNT ::
		TERRAIN_MATERIAL_COLOR_COUNT * TERRAIN_DEBUG_MATERIAL_FLAG_COMBO_COUNT
} else {
	TERRAIN_MATERIAL_FACE_VARIANT_COUNT :: TERRAIN_MATERIAL_COLOR_COUNT
}
TERRAIN_MATERIAL_FACE_VARIANT_MASK_WORD_COUNT :: (TERRAIN_MATERIAL_FACE_VARIANT_COUNT + 63) / 64
#assert(TERRAIN_MATERIAL_PALETTE_COUNT == 8)
#assert(TERRAIN_MATERIAL_PALETTE_COUNT == world_async.TERRAIN_MATERIAL_PALETTE_COUNT)
#assert(TERRAIN_MATERIAL_COLOR_COUNT == 32)
when TERRAIN_MATERIAL_FACE_DEBUG_VARIANTS_ENABLED {
	#assert(TERRAIN_MATERIAL_FACE_VARIANT_COUNT == 128)
	#assert(TERRAIN_MATERIAL_FACE_VARIANT_MASK_WORD_COUNT == 2)
} else {
	#assert(TERRAIN_MATERIAL_FACE_VARIANT_COUNT == 32)
	#assert(TERRAIN_MATERIAL_FACE_VARIANT_MASK_WORD_COUNT == 1)
}
TERRAIN_GENERATOR_VERSION :: #config(TERRAIN_GENERATOR_VERSION, u32(13))
TERRAIN_GRASS_CAP_BLOCK_DEPTH :: 4
TERRAIN_DIRT_LAYER_BLOCK_DEPTH :: 4
TERRAIN_SURFACE_MATERIAL_BLEND_SALT :: u64(0x475c91d2e03af86b)
TERRAIN_SURFACE_MATERIAL_BLEND_CELL_BLOCKS :: 48
TERRAIN_SURFACE_MATERIAL_BLEND_NOISE_AMPLITUDE :: f32(0.24)
TERRAIN_SHORE_MATERIAL_BLEND_SALT :: u64(0xa65f9d2c8b7140e3)
TERRAIN_SURFACE_MORPHOLOGY_WARP_X_SALT :: u64(0x5c8ec1a76d4932bf)
TERRAIN_SURFACE_MORPHOLOGY_WARP_Y_SALT :: u64(0xaef37d148b6c5091)
TERRAIN_SURFACE_MORPHOLOGY_WARP_Z_SALT :: u64(0x39bf4d207ae158c6)
TERRAIN_SURFACE_MORPHOLOGY_BROAD_SALT :: u64(0xd2476f9a31b80e54)
TERRAIN_SURFACE_MORPHOLOGY_FINE_SALT :: u64(0x7ea9c32158f4bd06)
TERRAIN_SURFACE_MORPHOLOGY_RIDGE_SALT :: u64(0x91b68f0cd24735ae)
TERRAIN_SURFACE_MORPHOLOGY_SPIRE_SALT :: u64(0xc42d87a59f3016be)
TERRAIN_SURFACE_MORPHOLOGY_SHELF_SALT :: u64(0x164fd73a8c9e250b)
TERRAIN_SHORE_MATERIAL_DITHER_AMPLITUDE :: f32(0.25)
TERRAIN_SHORE_CAP_THIN_BAND_FRACTION :: f32(0.56)
TERRAIN_LOCAL_WATER_FILL_INFLUENCE_MIN :: f32(0.50)
TERRAIN_WATER_VOLUME_SURFACE_ADJACENT_DEPTH_BLOCKS :: i32(24)
TERRAIN_WATER_SEPARATOR_RADIUS_BLOCKS :: i32(8)
TERRAIN_WATER_SEPARATOR_PADDING_BLOCKS :: TERRAIN_WATER_SEPARATOR_RADIUS_BLOCKS + 1
TERRAIN_WATER_SEPARATOR_GRID_LENGTH ::
	CHUNK_BLOCK_LENGTH + TERRAIN_WATER_SEPARATOR_PADDING_BLOCKS * 2
TERRAIN_WATER_SEPARATOR_GRID_COUNT ::
	TERRAIN_WATER_SEPARATOR_GRID_LENGTH * TERRAIN_WATER_SEPARATOR_GRID_LENGTH
TERRAIN_WATER_SEPARATOR_MIN_RISE_BLOCKS :: f32(2.5)
TERRAIN_WATER_SEPARATOR_RISE_VARIATION_BLOCKS :: f32(5.5)
TERRAIN_WATER_SEPARATOR_WIDTH_NOISE_SALT :: u64(0x95c4f2a6db13708e)
TERRAIN_WATER_SEPARATOR_HEIGHT_NOISE_SALT :: u64(0x3da97b8e451c6f20)
TERRAIN_WATER_SEPARATOR_NOISE_CELL_BLOCKS :: 23
TERRAIN_WATER_SEPARATOR_CONFLICT_INFLUENCE_MIN :: f32(0.30)
#assert(TERRAIN_SHORE_MATERIAL_DITHER_AMPLITUDE >= 0)
#assert(TERRAIN_SHORE_MATERIAL_DITHER_AMPLITUDE <= 0.35)
#assert(TERRAIN_SHORE_CAP_THIN_BAND_FRACTION > 0)
#assert(TERRAIN_SHORE_CAP_THIN_BAND_FRACTION <= 1)
#assert(TERRAIN_LOCAL_WATER_FILL_INFLUENCE_MIN > 0)
#assert(TERRAIN_LOCAL_WATER_FILL_INFLUENCE_MIN < 0.75)
#assert(TERRAIN_WATER_VOLUME_SURFACE_ADJACENT_DEPTH_BLOCKS > 0)
#assert(TERRAIN_WATER_VOLUME_SURFACE_ADJACENT_DEPTH_BLOCKS <= CHUNK_BLOCK_LENGTH)
#assert(TERRAIN_WATER_SEPARATOR_RADIUS_BLOCKS >= 4)
#assert(TERRAIN_WATER_SEPARATOR_RADIUS_BLOCKS <= 12)
#assert(TERRAIN_WATER_SEPARATOR_GRID_LENGTH > CHUNK_BLOCK_LENGTH)
#assert(TERRAIN_WATER_SEPARATOR_CONFLICT_INFLUENCE_MIN > 0)
#assert(TERRAIN_WATER_SEPARATOR_CONFLICT_INFLUENCE_MIN < 1)
#assert(TERRAIN_SURFACE_MATERIAL_BLEND_CELL_BLOCKS > 1)
#assert(TERRAIN_SURFACE_MATERIAL_BLEND_NOISE_AMPLITUDE >= 0)
#assert(TERRAIN_SURFACE_MATERIAL_BLEND_NOISE_AMPLITUDE <= 0.35)
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
TERRAIN_CAVE_FIELD_OPEN_STRENGTH_MIN :: f32(0.46)
TERRAIN_CAVE_FIELD_PATH_OPEN_STRENGTH_MIN :: f32(0.30)
TERRAIN_CAVE_FIELD_PATH_LONG_AXIS_SCALE :: f32(1.28)
TERRAIN_CAVE_FIELD_PATH_CROSS_AXIS_SCALE :: f32(0.58)
TERRAIN_CAVE_FIELD_PATH_Y_SCALE :: f32(0.48)
TERRAIN_CAVE_FIELD_PATH_SEGMENT_RADIUS_SCALE :: f32(0.36)
TERRAIN_CAVE_FIELD_PATH_SEGMENT_HALF_LENGTH_SCALE :: f32(1.24)
TERRAIN_CAVE_FIELD_PATH_ROUTE_VERTICAL_SCALE :: f32(0.55)
TERRAIN_CAVE_FIELD_PATH_SELECTION_BIAS :: f32(1.08)
TERRAIN_CAVE_FIELD_ROUTE_PATH_OPEN_STRENGTH_MIN :: f32(0.22)
TERRAIN_CAVE_FIELD_ROUTE_PATH_DISTANCE_MARGIN_BLOCKS :: f32(6)
TERRAIN_CAVE_FIELD_ROUTE_POCKET_DISTANCE_MARGIN_BLOCKS :: f32(16)
TERRAIN_CAVE_FIELD_ROUTE_POCKET_ROOM_SCALE :: f32(0.72)
TERRAIN_CAVE_FIELD_ROUTE_POCKET_THROAT_RADIUS_SCALE :: f32(0.46)
TERRAIN_CAVE_FIELD_ROUTE_POCKET_FIELD_BLEND_RADIUS :: f32(0.16)
TERRAIN_CAVE_FIELD_ROUTE_POCKET_FIELD_SIDE_OFFSET_SCALE :: f32(0.56)
TERRAIN_CAVE_FIELD_ROUTE_POCKET_FIELD_OUTWARD_OFFSET_SCALE :: f32(0.46)
TERRAIN_CAVE_FIELD_ROUTE_POCKET_FIELD_INWARD_OFFSET_SCALE :: f32(0.34)
TERRAIN_CAVE_FIELD_ROUTE_POCKET_FIELD_BRANCH_OFFSET_SCALE :: f32(0.72)
TERRAIN_CAVE_FIELD_ROUTE_POCKET_FIELD_BRANCH_AWAY_SCALE :: f32(0.58)
TERRAIN_CAVE_FIELD_ROUTE_POCKET_FIELD_CELL_SCALE :: f32(0.48)
TERRAIN_CAVE_FIELD_CHAMBER_XZ_SCALE :: f32(1.12)
TERRAIN_CAVE_FIELD_CHAMBER_Y_MIN_SCALE :: f32(0.62)
TERRAIN_CAVE_FIELD_CHAMBER_Y_MAX_SCALE :: f32(1.08)
TERRAIN_CAVE_FIELD_NETWORK_CONNECTED_MARGIN_BLOCKS :: f32(8)
TERRAIN_CAVE_FIELD_NETWORK_PATH_MARGIN_BLOCKS :: f32(14)
TERRAIN_CAVE_FIELD_NETWORK_BRIDGE_MARGIN_BLOCKS :: f32(34)
TERRAIN_CAVE_FIELD_NETWORK_BRIDGE_MIN_RADIUS :: f32(6)
TERRAIN_CAVE_FIELD_NETWORK_BRIDGE_RADIUS_SCALE :: f32(0.42)
TERRAIN_CAVE_FIELD_DOMAIN_WARP_SCALE_BLOCKS :: f32(18)
TERRAIN_CAVE_FIELD_DOMAIN_WARP_Y_SCALE :: f32(0.42)
TERRAIN_CAVE_FIELD_DOMAIN_WARP_DETAIL_SCALE :: f32(0.35)
TERRAIN_CAVE_EDGE_ROUTE_SEGMENT_COUNT :: #config(TERRAIN_CAVE_EDGE_ROUTE_SEGMENT_COUNT, u32(16))
#assert(TERRAIN_CAVE_EDGE_ROUTE_SEGMENT_COUNT <= 64)
TERRAIN_CAVE_EDGE_ROUTE_SIDE_WARP_SCALE :: f32(0.82)
TERRAIN_CAVE_EDGE_ROUTE_LIFT_WARP_SCALE :: f32(0.36)
TERRAIN_CAVE_EDGE_ROUTE_RADIUS_NECK_MIN :: f32(0.30)
TERRAIN_CAVE_EDGE_ROUTE_RADIUS_SWELL_MAX :: f32(1.12)
TERRAIN_CAVE_EDGE_RADIUS_SOFT_CAP_BLEND :: f32(0.16)
TERRAIN_CAVE_EDGE_RADIUS_CAP_DEFAULT_BLOCKS :: f32(15)
TERRAIN_CAVE_EDGE_RADIUS_CAP_CANYON_BLOCKS :: f32(19)
TERRAIN_CAVE_EDGE_RADIUS_CAP_FLOODED_BLOCKS :: f32(18)
TERRAIN_CAVE_EDGE_RADIUS_CAP_FRACTURE_BLOCKS :: f32(11)
TERRAIN_CAVE_EDGE_RADIUS_CAP_VERTICAL_BLOCKS :: f32(13)
TERRAIN_CAVE_EDGE_RADIUS_CAP_COLLAPSED_BLOCKS :: f32(12)
TERRAIN_CAVE_EDGE_RADIUS_CAP_WORM_BLOCKS :: f32(15)
TERRAIN_CAVE_EDGE_RADIUS_CAP_SEAM_BLOCKS :: f32(23)
TERRAIN_CAVE_EDGE_CORE_RADIUS_SCALE_DEFAULT :: f32(0.74)
TERRAIN_CAVE_EDGE_CORE_RADIUS_SCALE_CANYON :: f32(0.86)
TERRAIN_CAVE_EDGE_CORE_RADIUS_SCALE_FLOODED :: f32(0.78)
TERRAIN_CAVE_EDGE_CORE_RADIUS_SCALE_FRACTURE :: f32(0.70)
TERRAIN_CAVE_EDGE_CORE_RADIUS_SCALE_COLLAPSED :: f32(0.66)
TERRAIN_CAVE_EDGE_CORE_RADIUS_SCALE_WORM :: f32(0.62)
TERRAIN_CAVE_EDGE_SEAM_BASE_RADIUS_SCALE :: f32(1.04)
TERRAIN_CAVE_EDGE_SEAM_CORE_RADIUS_SCALE :: f32(1.03)
TERRAIN_CAVE_EDGE_SEAM_INTERIOR_RADIUS_SCALE :: f32(0.09)
TERRAIN_CAVE_EDGE_SEAM_RADIUS_NECK_MIN :: f32(0.78)
TERRAIN_CAVE_EDGE_SEAM_RADIUS_SWELL_MAX :: f32(1.14)
TERRAIN_CAVE_EDGE_SEAM_WALL_SCALLOP_MIN :: f32(0.18)
TERRAIN_CAVE_EDGE_SEAM_WALL_RIB_MIN :: f32(0.15)
TERRAIN_CAVE_EDGE_SEAM_LIP_RELIEF_SCALE :: f32(0.09)
TERRAIN_CAVE_EDGE_APPROACH_WIDEN_START_T :: f32(0.24)
TERRAIN_CAVE_EDGE_APPROACH_WIDEN_FULL_T :: f32(0.07)
TERRAIN_CAVE_EDGE_APPROACH_WIDEN_SCALE :: f32(0.42)
TERRAIN_CAVE_EDGE_APPROACH_VESTIBULE_ROUTE_T :: f32(0.20)
TERRAIN_CAVE_EDGE_APPROACH_VESTIBULE_MIN_ROUTE_RADIUS_BLOCKS :: f32(8.0)
TERRAIN_CAVE_EDGE_APPROACH_VESTIBULE_SIDE_OFFSET_SCALE :: f32(0.52)
TERRAIN_CAVE_EDGE_APPROACH_VESTIBULE_VERTICAL_OFFSET_SCALE :: f32(0.24)
TERRAIN_CAVE_EDGE_APPROACH_VESTIBULE_RADIUS_SCALE :: f32(0.74)
TERRAIN_CAVE_EDGE_APPROACH_VESTIBULE_RADIUS_MIN_BLOCKS :: f32(3.75)
TERRAIN_CAVE_EDGE_APPROACH_VESTIBULE_RADIUS_MAX_BLOCKS :: f32(16)
TERRAIN_CAVE_EDGE_APPROACH_VESTIBULE_THROAT_SCALE :: f32(0.52)
TERRAIN_CAVE_EDGE_BRAID_COUNT :: u32(2)
TERRAIN_CAVE_EDGE_BRAID_ROUTE_MARGIN :: f32(0.16)
TERRAIN_CAVE_EDGE_BRAID_SPAN_T_MIN :: f32(0.20)
TERRAIN_CAVE_EDGE_BRAID_SPAN_T_MAX :: f32(0.34)
TERRAIN_CAVE_EDGE_BRAID_SIDE_OFFSET_SCALE :: f32(0.78)
TERRAIN_CAVE_EDGE_BRAID_VERTICAL_OFFSET_SCALE :: f32(0.34)
TERRAIN_CAVE_EDGE_BRAID_RADIUS_SCALE :: f32(0.34)
TERRAIN_CAVE_EDGE_BRAID_RADIUS_THRESHOLD_BLOCKS :: f32(14)
TERRAIN_CAVE_EDGE_BRAID_RADIUS_MIN_BLOCKS :: f32(2.4)
TERRAIN_CAVE_EDGE_BRAID_RADIUS_MAX_BLOCKS :: f32(8.0)
TERRAIN_CAVE_EDGE_BRAID_POCKET_RADIUS_SCALE :: f32(1.24)
TERRAIN_CAVE_EDGE_ROUTE_BYPASS_COUNT :: u32(2)
TERRAIN_CAVE_EDGE_ROUTE_BYPASS_ROUTE_MARGIN :: f32(0.15)
TERRAIN_CAVE_EDGE_ROUTE_BYPASS_SPAN_T_MIN :: f32(0.26)
TERRAIN_CAVE_EDGE_ROUTE_BYPASS_SPAN_T_MAX :: f32(0.42)
TERRAIN_CAVE_EDGE_ROUTE_BYPASS_MIN_ROUTE_RADIUS_BLOCKS :: f32(10.5)
TERRAIN_CAVE_EDGE_ROUTE_BYPASS_MIN_ROUTE_LENGTH_BLOCKS :: f32(96)
TERRAIN_CAVE_EDGE_ROUTE_BYPASS_SIDE_OFFSET_SCALE :: f32(1.08)
TERRAIN_CAVE_EDGE_ROUTE_BYPASS_VERTICAL_OFFSET_SCALE :: f32(0.48)
TERRAIN_CAVE_EDGE_ROUTE_BYPASS_RELAY_OFFSET_SCALE :: f32(0.28)
TERRAIN_CAVE_EDGE_ROUTE_BYPASS_RADIUS_SCALE :: f32(0.46)
TERRAIN_CAVE_EDGE_ROUTE_BYPASS_RADIUS_MIN_BLOCKS :: f32(4.2)
TERRAIN_CAVE_EDGE_ROUTE_BYPASS_RADIUS_MAX_BLOCKS :: f32(12.5)
TERRAIN_CAVE_EDGE_ROUTE_BYPASS_THROAT_SCALE :: f32(0.32)
TERRAIN_CAVE_EDGE_ROUTE_BYPASS_POCKET_RADIUS_SCALE :: f32(1.28)
TERRAIN_CAVE_EDGE_ALCOVE_COUNT :: u32(2)
TERRAIN_CAVE_EDGE_ALCOVE_ROUTE_MARGIN :: f32(0.18)
TERRAIN_CAVE_EDGE_ALCOVE_SIDE_OFFSET_SCALE :: f32(1.05)
TERRAIN_CAVE_EDGE_ALCOVE_RADIUS_MIN_BLOCKS :: f32(3.5)
TERRAIN_CAVE_EDGE_ALCOVE_RADIUS_MAX_BLOCKS :: f32(16)
TERRAIN_CAVE_EDGE_CHAMBERLET_COUNT :: u32(7)
TERRAIN_CAVE_EDGE_CHAMBERLET_ROUTE_MARGIN :: f32(0.12)
TERRAIN_CAVE_EDGE_CHAMBERLET_SIDE_OFFSET_SCALE :: f32(0.60)
TERRAIN_CAVE_EDGE_CHAMBERLET_RADIUS_MIN_BLOCKS :: f32(3.25)
TERRAIN_CAVE_EDGE_CHAMBERLET_RADIUS_MAX_BLOCKS :: f32(13)
TERRAIN_CAVE_EDGE_CHAMBERLET_DETAIL_COUNT :: u32(3)
TERRAIN_CAVE_EDGE_CHAMBERLET_DETAIL_OFFSET_SCALE :: f32(1.10)
TERRAIN_CAVE_EDGE_CHAMBERLET_DETAIL_RADIUS_MIN_BLOCKS :: f32(2.25)
TERRAIN_CAVE_EDGE_CHAMBERLET_DETAIL_RADIUS_MAX_BLOCKS :: f32(8.5)
TERRAIN_CAVE_EDGE_CHAMBERLET_DETAIL_THROAT_SCALE :: f32(0.24)
TERRAIN_CAVE_EDGE_CHAMBERLET_DETAIL_LOOP_RADIUS_SCALE :: f32(0.58)
TERRAIN_CAVE_EDGE_CHAMBERLET_DETAIL_LOOP_ROUTE_CAP_SCALE :: f32(0.22)
TERRAIN_CAVE_EDGE_CHAMBERLET_DETAIL_LOOP_POCKET_RADIUS_SCALE :: f32(1.55)
TERRAIN_CAVE_EDGE_CHAMBERLET_GALLERY_RADIUS_SCALE :: f32(0.44)
TERRAIN_CAVE_EDGE_CHAMBERLET_GALLERY_ROUTE_CAP_SCALE :: f32(0.32)
TERRAIN_CAVE_EDGE_CHAMBERLET_GALLERY_POCKET_RADIUS_SCALE :: f32(1.38)
TERRAIN_CAVE_EDGE_CHAMBERLET_GALLERY_RELAY_OFFSET_SCALE :: f32(0.32)
TERRAIN_CAVE_EDGE_CHAMBERLET_GALLERY_RELAY_VERTICAL_OFFSET_SCALE :: f32(0.18)
TERRAIN_CAVE_EDGE_CHAMBERLET_GALLERY_RELAY_POCKET_RADIUS_SCALE :: f32(1.55)
TERRAIN_CAVE_EDGE_SEAM_BAY_COUNT :: u32(3)
TERRAIN_CAVE_EDGE_SEAM_BAY_ROUTE_MARGIN :: f32(0.18)
TERRAIN_CAVE_EDGE_SEAM_BAY_SIDE_OFFSET_SCALE :: f32(0.24)
TERRAIN_CAVE_EDGE_SEAM_BAY_VERTICAL_OFFSET_SCALE :: f32(0.62)
TERRAIN_CAVE_EDGE_SEAM_BAY_RADIUS_MIN_BLOCKS :: f32(8.0)
TERRAIN_CAVE_EDGE_SEAM_BAY_RADIUS_MAX_BLOCKS :: f32(20)
TERRAIN_CAVE_EDGE_SEAM_BAY_THROAT_SCALE :: f32(0.50)
TERRAIN_CAVE_EDGE_SEAM_BYPASS_COUNT :: u32(2)
TERRAIN_CAVE_EDGE_SEAM_BYPASS_ROUTE_MARGIN :: f32(0.14)
TERRAIN_CAVE_EDGE_SEAM_BYPASS_SPAN_T_MIN :: f32(0.18)
TERRAIN_CAVE_EDGE_SEAM_BYPASS_SPAN_T_MAX :: f32(0.27)
TERRAIN_CAVE_EDGE_SEAM_BYPASS_SIDE_OFFSET_SCALE :: f32(0.86)
TERRAIN_CAVE_EDGE_SEAM_BYPASS_VERTICAL_OFFSET_SCALE :: f32(0.78)
TERRAIN_CAVE_EDGE_SEAM_BYPASS_RADIUS_MIN_BLOCKS :: f32(6.5)
TERRAIN_CAVE_EDGE_SEAM_BYPASS_RADIUS_MAX_BLOCKS :: f32(18.5)
TERRAIN_CAVE_EDGE_SEAM_BYPASS_THROAT_SCALE :: f32(0.30)
TERRAIN_CAVE_EDGE_SEAM_BYPASS_ROOM_RADIUS_SCALE :: f32(1.28)
TERRAIN_CAVE_EDGE_SEAM_BYPASS_RELAY_OFFSET_SCALE :: f32(0.24)
TERRAIN_CAVE_EDGE_SEAM_CROSSCUT_COUNT :: u32(5)
TERRAIN_CAVE_EDGE_SEAM_CROSSCUT_ROUTE_MARGIN :: f32(0.13)
TERRAIN_CAVE_EDGE_SEAM_CROSSCUT_SPAN_T :: f32(0.17)
TERRAIN_CAVE_EDGE_SEAM_CROSSCUT_SIDE_OFFSET_SCALE :: f32(0.84)
TERRAIN_CAVE_EDGE_SEAM_CROSSCUT_VERTICAL_OFFSET_SCALE :: f32(0.70)
TERRAIN_CAVE_EDGE_SEAM_CROSSCUT_RADIUS_MIN_BLOCKS :: f32(6.2)
TERRAIN_CAVE_EDGE_SEAM_CROSSCUT_RADIUS_MAX_BLOCKS :: f32(18.0)
TERRAIN_CAVE_EDGE_SEAM_CROSSCUT_MOUTH_RADIUS_SCALE :: f32(0.98)
TERRAIN_CAVE_EDGE_SEAM_CROSSCUT_BRANCH_RADIUS_SCALE :: f32(0.98)
TERRAIN_CAVE_EDGE_SEAM_CROSSCUT_NODE_RADIUS_SCALE :: f32(1.56)
TERRAIN_CAVE_EDGE_SEAM_CROSSCUT_NODE_SIDE_SCALE :: f32(0.98)
TERRAIN_CAVE_EDGE_SEAM_CROSSCUT_NODE_VERTICAL_SCALE :: f32(0.44)
TERRAIN_CAVE_EDGE_SEAM_SHOULDER_COUNT :: u32(4)
TERRAIN_CAVE_EDGE_SEAM_SHOULDER_ROUTE_MARGIN :: f32(0.13)
TERRAIN_CAVE_EDGE_SEAM_SHOULDER_SPAN_T :: f32(0.13)
TERRAIN_CAVE_EDGE_SEAM_SHOULDER_SIDE_OFFSET_SCALE :: f32(0.34)
TERRAIN_CAVE_EDGE_SEAM_SHOULDER_VERTICAL_OFFSET_SCALE :: f32(0.36)
TERRAIN_CAVE_EDGE_SEAM_SHOULDER_RADIUS_MIN_BLOCKS :: f32(5.5)
TERRAIN_CAVE_EDGE_SEAM_SHOULDER_RADIUS_MAX_BLOCKS :: f32(16)
TERRAIN_CAVE_EDGE_SEAM_SHOULDER_THROAT_SCALE :: f32(0.38)
TERRAIN_CAVE_EDGE_SEAM_SHOULDER_POCKET_RADIUS_SCALE :: f32(1.08)
TERRAIN_CAVE_EDGE_SEAM_VERTICAL_RELIEF_COUNT :: u32(5)
TERRAIN_CAVE_EDGE_SEAM_VERTICAL_RELIEF_ROUTE_MARGIN :: f32(0.11)
TERRAIN_CAVE_EDGE_SEAM_VERTICAL_RELIEF_SPAN_T :: f32(0.10)
TERRAIN_CAVE_EDGE_SEAM_VERTICAL_RELIEF_OFFSET_SCALE :: f32(1.24)
TERRAIN_CAVE_EDGE_SEAM_VERTICAL_RELIEF_SIDE_DRIFT_SCALE :: f32(0.12)
TERRAIN_CAVE_EDGE_SEAM_VERTICAL_RELIEF_RADIUS_MIN_BLOCKS :: f32(6.0)
TERRAIN_CAVE_EDGE_SEAM_VERTICAL_RELIEF_RADIUS_MAX_BLOCKS :: f32(16.5)
TERRAIN_CAVE_EDGE_SEAM_VERTICAL_RELIEF_RIB_RADIUS_SCALE :: f32(0.78)
TERRAIN_CAVE_EDGE_SEAM_VERTICAL_RELIEF_THROAT_SCALE :: f32(0.44)
TERRAIN_CAVE_EDGE_SEAM_VERTICAL_RELIEF_POCKET_RADIUS_SCALE :: f32(1.12)
TERRAIN_CAVE_EDGE_SEAM_GALLERY_COUNT :: u32(3)
TERRAIN_CAVE_EDGE_SEAM_GALLERY_ROUTE_MARGIN :: f32(0.16)
TERRAIN_CAVE_EDGE_SEAM_GALLERY_SIDE_OFFSET_SCALE :: f32(0.48)
TERRAIN_CAVE_EDGE_SEAM_GALLERY_VERTICAL_OFFSET_SCALE :: f32(0.42)
TERRAIN_CAVE_EDGE_SEAM_GALLERY_RADIUS_MIN_BLOCKS :: f32(4.5)
TERRAIN_CAVE_EDGE_SEAM_GALLERY_RADIUS_MAX_BLOCKS :: f32(15)
TERRAIN_CAVE_EDGE_SEAM_GALLERY_THROAT_SCALE :: f32(0.34)
TERRAIN_CAVE_NODE_ISOLATED_CULL_RADIUS_BLOCKS :: f32(14)
TERRAIN_CAVE_NODE_BRIDGE_MAX_DISTANCE_BLOCKS :: f32(150)
TERRAIN_CAVE_NODE_BRIDGE_RADIUS_SCALE :: f32(0.36)
TERRAIN_CAVE_NODE_PROFILE_ROOM_MIN_RADIUS_BLOCKS :: f32(9)
TERRAIN_CAVE_NODE_PROFILE_ROOM_MINOR_SCALE :: f32(0.72)
TERRAIN_CAVE_NODE_PROFILE_ROOM_MAJOR_MAX_XZ :: f32(18)
TERRAIN_CAVE_NODE_PROFILE_ROOM_MAJOR_MAX_Y :: f32(14)
TERRAIN_CAVE_NODE_PROFILE_ROOM_MINOR_MAX_XZ :: f32(13)
TERRAIN_CAVE_NODE_PROFILE_ROOM_MINOR_MAX_Y :: f32(10)
TERRAIN_CAVE_NODE_MAJOR_ROOM_FIELD_EXTENT_SCALE :: f32(1.48)
TERRAIN_CAVE_NODE_MAJOR_ROOM_FIELD_SIDE_CENTER_SCALE :: f32(0.74)
TERRAIN_CAVE_NODE_MAJOR_ROOM_FIELD_SIDE_ACROSS_SCALE :: f32(0.56)
TERRAIN_CAVE_NODE_MAJOR_ROOM_FIELD_SIDE_RADIUS_SCALE :: f32(0.46)
TERRAIN_CAVE_NODE_MAJOR_ROOM_FIELD_CONNECTOR_RADIUS_SCALE :: f32(0.28)
TERRAIN_CAVE_NODE_MAJOR_ROOM_FIELD_BLEND_RADIUS :: f32(0.22)
TERRAIN_CAVE_NODE_MAJOR_ROOM_FIELD_CELL_SCALE :: f32(0.42)
TERRAIN_CAVE_NODE_EDGE_PORTAL_MAX_COUNT :: u32(6)
TERRAIN_CAVE_NODE_EDGE_PORTAL_ROUTE_T :: f32(0.16)
TERRAIN_CAVE_NODE_EDGE_PORTAL_OFFSET_SCALE :: f32(1.18)
TERRAIN_CAVE_NODE_EDGE_PORTAL_SIDE_OFFSET_SCALE :: f32(0.34)
TERRAIN_CAVE_NODE_EDGE_PORTAL_VERTICAL_OFFSET_SCALE :: f32(0.26)
TERRAIN_CAVE_NODE_EDGE_PORTAL_RADIUS_SCALE :: f32(0.64)
TERRAIN_CAVE_NODE_EDGE_PORTAL_RADIUS_MIN_BLOCKS :: f32(3.25)
TERRAIN_CAVE_NODE_EDGE_PORTAL_RADIUS_MAX_BLOCKS :: f32(14)
TERRAIN_CAVE_NODE_EDGE_PORTAL_THROAT_SCALE :: f32(0.50)
TERRAIN_CAVE_NODE_EDGE_PORTAL_CRYSTAL_SPLINTER_SIDE_SCALE :: f32(1.04)
TERRAIN_CAVE_NODE_EDGE_PORTAL_CRYSTAL_SPLINTER_FORWARD_SCALE :: f32(0.20)
TERRAIN_CAVE_NODE_EDGE_PORTAL_CRYSTAL_SPLINTER_VERTICAL_SCALE :: f32(0.08)
TERRAIN_CAVE_NODE_EDGE_PORTAL_CRYSTAL_SPLINTER_RADIUS_SCALE :: f32(0.62)
TERRAIN_CAVE_NODE_EDGE_PORTAL_CRYSTAL_SPLINTER_THROAT_SCALE :: f32(0.28)
TERRAIN_CAVE_NODE_MACRO_SATELLITE_COUNT :: u32(4)
TERRAIN_CAVE_NODE_MACRO_SATELLITE_OFFSET_SCALE :: f32(1.12)
TERRAIN_CAVE_NODE_MACRO_SATELLITE_RADIUS_XZ_SCALE :: f32(0.64)
TERRAIN_CAVE_NODE_MACRO_SATELLITE_RADIUS_Y_SCALE :: f32(0.52)
TERRAIN_CAVE_NODE_MACRO_SATELLITE_VERTICAL_OFFSET_SCALE :: f32(0.26)
TERRAIN_CAVE_NODE_MACRO_SATELLITE_THROAT_SCALE :: f32(0.32)
TERRAIN_CAVE_NODE_MACRO_SATELLITE_APRON_INNER_SCALE :: f32(0.48)
TERRAIN_CAVE_NODE_MACRO_SATELLITE_APRON_END_SCALE :: f32(0.94)
TERRAIN_CAVE_NODE_MACRO_SATELLITE_APRON_RADIUS_SCALE :: f32(0.62)
TERRAIN_CAVE_NODE_MACRO_SATELLITE_APRON_VERTICAL_RADIUS_SCALE :: f32(0.58)
TERRAIN_CAVE_NODE_MACRO_SATELLITE_APRON_SIDE_RADIUS_SCALE :: f32(0.78)
TERRAIN_CAVE_NODE_MACRO_SATELLITE_APRON_BRANCH_OFFSET_SCALE :: f32(0.72)
TERRAIN_CAVE_NODE_MACRO_SATELLITE_APRON_BRANCH_RADIUS_SCALE :: f32(0.52)
TERRAIN_CAVE_NODE_MACRO_SATELLITE_APRON_BLEND_RADIUS :: f32(0.28)
TERRAIN_CAVE_NODE_MACRO_SATELLITE_APRON_CELL_SCALE :: f32(0.52)
TERRAIN_CAVE_NODE_MACRO_SATELLITE_CLUSTER_BRIDGE_RADIUS_SCALE :: f32(0.36)
TERRAIN_CAVE_NODE_MACRO_SATELLITE_CLUSTER_BRIDGE_MIN_BLOCKS :: f32(2.4)
TERRAIN_CAVE_NODE_MACRO_SATELLITE_CLUSTER_OUTER_OFFSET_SCALE :: f32(1.36)
TERRAIN_CAVE_NODE_MACRO_SATELLITE_CLUSTER_POCKET_RADIUS_SCALE :: f32(0.52)
TERRAIN_CAVE_NODE_MACRO_SATELLITE_CLUSTER_POCKET_MIN_BLOCKS :: f32(3.25)
TERRAIN_CAVE_NODE_MACRO_SATELLITE_CLUSTER_POCKET_MAX_BLOCKS :: f32(9.5)
TERRAIN_CAVE_NODE_MACRO_SATELLITE_CLUSTER_ALCOVE_OFFSET_SCALE :: f32(1.18)
TERRAIN_CAVE_NODE_MACRO_SATELLITE_CLUSTER_ALCOVE_RADIUS_SCALE :: f32(0.82)
TERRAIN_CAVE_NODE_MACRO_SATELLITE_CLUSTER_ALCOVE_THROAT_SCALE :: f32(0.70)
TERRAIN_CAVE_NODE_MACRO_SATELLITE_CLUSTER_FIELD_RADIUS_SCALE :: f32(1.58)
TERRAIN_CAVE_NODE_MACRO_SATELLITE_CLUSTER_FIELD_SIDE_OFFSET_SCALE :: f32(1.18)
TERRAIN_CAVE_NODE_MACRO_SATELLITE_CLUSTER_FIELD_SIDE_RADIUS_SCALE :: f32(0.94)
TERRAIN_CAVE_NODE_MACRO_SATELLITE_CLUSTER_FIELD_OUTWARD_OFFSET_SCALE :: f32(0.72)
TERRAIN_CAVE_NODE_MACRO_SATELLITE_CLUSTER_FIELD_BRANCH_OFFSET_SCALE :: f32(0.74)
TERRAIN_CAVE_NODE_MACRO_SATELLITE_CLUSTER_FIELD_BRANCH_OUTWARD_SCALE :: f32(0.56)
TERRAIN_CAVE_NODE_MACRO_SATELLITE_CLUSTER_FIELD_BRANCH_RADIUS_SCALE :: f32(0.78)
TERRAIN_CAVE_NODE_MACRO_SATELLITE_CLUSTER_FIELD_BRANCH_NECK_RADIUS_SCALE :: f32(0.46)
TERRAIN_CAVE_NODE_MACRO_SATELLITE_CLUSTER_FIELD_BLEND_RADIUS :: f32(0.32)
TERRAIN_CAVE_NODE_MACRO_SATELLITE_CLUSTER_FIELD_CELL_SCALE :: f32(0.58)
TERRAIN_CAVE_NODE_MACRO_SATELLITE_MIN_RADIUS_BLOCKS :: f32(4.5)
TERRAIN_CAVE_NODE_MACRO_SATELLITE_MAX_RADIUS_BLOCKS :: f32(13)
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
TERRAIN_CAVE_MOUTH_EXTERIOR_APRON_REACH_SCALE :: f32(0.96)
TERRAIN_CAVE_MOUTH_EXTERIOR_APRON_SIDE_SCALE :: f32(1.68)
TERRAIN_CAVE_MOUTH_EXTERIOR_APRON_DEPTH_SCALE :: f32(0.64)
TERRAIN_CAVE_MOUTH_EXTERIOR_APRON_RELIEF_STRENGTH :: f32(0.32)
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
TERRAIN_CAVE_MOUTH_STAGING_NICHE_COUNT :: u32(3)
TERRAIN_CAVE_MOUTH_STAGING_ROUTE_MIN_T :: f32(0.28)
TERRAIN_CAVE_MOUTH_STAGING_ROUTE_MAX_T :: f32(0.72)
TERRAIN_CAVE_MOUTH_STAGING_SIDE_OFFSET_SCALE :: f32(0.82)
TERRAIN_CAVE_MOUTH_STAGING_RADIUS_MIN_BLOCKS :: f32(2.5)
TERRAIN_CAVE_MOUTH_STAGING_RADIUS_MAX_BLOCKS :: f32(8.5)
TERRAIN_CAVE_MOUTH_STAGING_THROAT_SCALE :: f32(0.32)
TERRAIN_SINKHOLE_SIDE_LEDGE_RELIEF_STRENGTH :: f32(0.13)
TERRAIN_SINKHOLE_RIM_LIP_STRENGTH :: f32(0.08)
TERRAIN_SINKHOLE_SPIRAL_OFFSET_SCALE :: f32(0.42)
TERRAIN_CAVE_ROUGH_ELLIPSOID_EDGE_SCALE :: f32(0.24)
TERRAIN_CAVE_ROUGH_ELLIPSOID_CORE_SCALE :: f32(0.08)
TERRAIN_CAVE_ROUGH_ELLIPSOID_PRE_NOISE_SHAPE_MAX ::
	f32(1.0) + TERRAIN_CAVE_ROUGH_ELLIPSOID_EDGE_SCALE
TERRAIN_CAVE_ROOM_LOBE_SWELL_SCALE :: f32(0.08)
TERRAIN_CAVE_ROOM_LOBE_BACK_SWELL_SCALE :: f32(0.04)
TERRAIN_CAVE_ROOM_SIDE_NOTCH_SCALE :: f32(0.30)
TERRAIN_CAVE_ROOM_CEILING_RIB_SCALE :: f32(0.14)
TERRAIN_CAVE_ROOM_PRE_NOISE_OUTER_SHAPE_MAX :: f32(2.05)
TERRAIN_CAVE_ROOM_COORD_WARP_SCALE :: f32(0.22)
TERRAIN_CAVE_ROOM_VERTICAL_WARP_SCALE :: f32(0.10)
TERRAIN_CAVE_ROOM_SCALLOP_SCALE :: f32(0.12)
TERRAIN_CAVE_ROOM_INTERNAL_STRUCTURE_MIN_RADIUS :: f32(4.5)
TERRAIN_CAVE_ROOM_COMPOUND_MIN_RADIUS :: f32(3.25)
TERRAIN_CAVE_ROOM_COMPOUND_CORE_CONTRACTION :: f32(0.18)
TERRAIN_CAVE_ROOM_COMPOUND_BLEND_RADIUS :: f32(0.16)
TERRAIN_CAVE_ROOM_COMPOUND_PRIMARY_LOBE_BIAS :: f32(0.94)
TERRAIN_CAVE_ROOM_COMPOUND_SECONDARY_LOBE_BIAS :: f32(0.98)
TERRAIN_CAVE_ROOM_COMPOUND_BACK_LOBE_BIAS :: f32(1.06)
TERRAIN_CAVE_ROOM_COMPOUND_SIDE_GALLERY_BIAS :: f32(0.90)
TERRAIN_CAVE_ROOM_COMPOUND_REAR_ALCOVE_BIAS :: f32(0.96)
TERRAIN_CAVE_ROOM_CELLULAR_CELL_SCALE :: f32(0.34)
TERRAIN_CAVE_ROOM_CELLULAR_CELL_MIN_BLOCKS :: f32(4.0)
TERRAIN_CAVE_ROOM_CELLULAR_RIDGE_SCALE :: f32(0.18)
TERRAIN_CAVE_ROOM_CELLULAR_POCKET_SCALE :: f32(0.16)
TERRAIN_CAVE_ROOM_STRATA_FLOOR_MOUND_SCALE :: f32(0.13)
TERRAIN_CAVE_ROOM_STRATA_FLOOR_TERRACE_SCALE :: f32(0.08)
TERRAIN_CAVE_ROOM_STRATA_CEILING_CHIMNEY_SCALE :: f32(0.12)
TERRAIN_CAVE_ROOM_STRATA_CEILING_RIB_SCALE :: f32(0.10)
#assert(TERRAIN_CAVE_MOUTH_LOWER_WIDTH_BOOST > 0.22)
#assert(TERRAIN_CAVE_MOUTH_SIDE_SHOULDER_START < 0.38)
#assert(TERRAIN_CAVE_MOUTH_CENTER_RELIEF_STRENGTH < 0.18)
#assert(TERRAIN_CAVE_MOUTH_LOWER_JAW_RELIEF_STRENGTH < TERRAIN_CAVE_MOUTH_SIDE_SHOULDER_STRENGTH)
#assert(TERRAIN_CAVE_MOUTH_UPPER_LIP_RIB_STRENGTH < TERRAIN_CAVE_MOUTH_CENTER_RELIEF_STRENGTH)
#assert(TERRAIN_CAVE_MOUTH_SIDE_ALCOVE_RELIEF_STRENGTH < TERRAIN_CAVE_MOUTH_SIDE_SHOULDER_STRENGTH)
#assert(TERRAIN_CAVE_MOUTH_SIDE_ALCOVE_SMALL_SCALE < 1.0)
#assert(TERRAIN_CAVE_MOUTH_SIDE_ALCOVE_LARGE_SCALE > 1.0)
#assert(TERRAIN_CAVE_MOUTH_EXTERIOR_APRON_REACH_SCALE > 0.45)
#assert(TERRAIN_CAVE_MOUTH_EXTERIOR_APRON_REACH_SCALE < 1.0)
#assert(TERRAIN_CAVE_MOUTH_EXTERIOR_APRON_SIDE_SCALE > 1.0)
#assert(TERRAIN_CAVE_MOUTH_EXTERIOR_APRON_SIDE_SCALE < 1.8)
#assert(TERRAIN_CAVE_MOUTH_EXTERIOR_APRON_DEPTH_SCALE > 0.25)
#assert(TERRAIN_CAVE_MOUTH_EXTERIOR_APRON_DEPTH_SCALE < 0.70)
#assert(
	TERRAIN_CAVE_MOUTH_EXTERIOR_APRON_RELIEF_STRENGTH > TERRAIN_CAVE_MOUTH_UPPER_LIP_RIB_STRENGTH,
)
#assert(
	TERRAIN_CAVE_MOUTH_EXTERIOR_APRON_RELIEF_STRENGTH < TERRAIN_CAVE_MOUTH_SIDE_SHOULDER_STRENGTH,
)
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
#assert(TERRAIN_CAVE_MOUTH_STAGING_NICHE_COUNT >= 2)
#assert(TERRAIN_CAVE_MOUTH_STAGING_ROUTE_MIN_T > 0)
#assert(TERRAIN_CAVE_MOUTH_STAGING_ROUTE_MIN_T < TERRAIN_CAVE_MOUTH_STAGING_ROUTE_MAX_T)
#assert(TERRAIN_CAVE_MOUTH_STAGING_ROUTE_MAX_T < 1)
#assert(TERRAIN_CAVE_MOUTH_STAGING_SIDE_OFFSET_SCALE > 0.5)
#assert(
	TERRAIN_CAVE_MOUTH_STAGING_RADIUS_MIN_BLOCKS < TERRAIN_CAVE_MOUTH_STAGING_RADIUS_MAX_BLOCKS,
)
#assert(TERRAIN_CAVE_MOUTH_STAGING_THROAT_SCALE > 0.2)
#assert(TERRAIN_CAVE_MOUTH_STAGING_THROAT_SCALE < 0.45)
#assert(TERRAIN_SINKHOLE_SIDE_LEDGE_RELIEF_STRENGTH > TERRAIN_SINKHOLE_RIM_LIP_STRENGTH)
#assert(TERRAIN_SINKHOLE_SIDE_LEDGE_RELIEF_STRENGTH < 0.14)
#assert(TERRAIN_SINKHOLE_SPIRAL_OFFSET_SCALE < 0.5)
#assert(TERRAIN_CAVE_ROUGH_ELLIPSOID_EDGE_SCALE > TERRAIN_CAVE_ROUGH_ELLIPSOID_CORE_SCALE)
#assert(TERRAIN_CAVE_ROUGH_ELLIPSOID_EDGE_SCALE < 0.35)
#assert(TERRAIN_CAVE_ROUGH_ELLIPSOID_PRE_NOISE_SHAPE_MAX > 1.0)
#assert(TERRAIN_CAVE_ROOM_PRE_NOISE_OUTER_SHAPE_MAX > 2.0)
#assert(TERRAIN_CAVE_ROOM_SIDE_NOTCH_SCALE > TERRAIN_CAVE_ROOM_LOBE_SWELL_SCALE)
#assert(TERRAIN_CAVE_ROOM_CEILING_RIB_SCALE < TERRAIN_CAVE_ROOM_SIDE_NOTCH_SCALE)
#assert(TERRAIN_CAVE_ROOM_COORD_WARP_SCALE < TERRAIN_CAVE_ROOM_SIDE_NOTCH_SCALE)
#assert(TERRAIN_CAVE_ROOM_VERTICAL_WARP_SCALE < TERRAIN_CAVE_ROOM_COORD_WARP_SCALE)
#assert(TERRAIN_CAVE_ROOM_SCALLOP_SCALE < TERRAIN_CAVE_ROOM_COORD_WARP_SCALE)
#assert(TERRAIN_CAVE_ROOM_INTERNAL_STRUCTURE_MIN_RADIUS > 3)
#assert(TERRAIN_CAVE_ROOM_COMPOUND_MIN_RADIUS > 2)
#assert(TERRAIN_CAVE_ROOM_COMPOUND_CORE_CONTRACTION > 0)
#assert(TERRAIN_CAVE_ROOM_COMPOUND_CORE_CONTRACTION < 0.35)
#assert(TERRAIN_CAVE_ROOM_COMPOUND_BLEND_RADIUS > 0)
#assert(TERRAIN_CAVE_ROOM_COMPOUND_BLEND_RADIUS < TERRAIN_CAVE_ROOM_COMPOUND_CORE_CONTRACTION)
#assert(TERRAIN_CAVE_ROOM_COMPOUND_PRIMARY_LOBE_BIAS < 1)
#assert(TERRAIN_CAVE_ROOM_COMPOUND_BACK_LOBE_BIAS > 1)
#assert(
	TERRAIN_CAVE_ROOM_COMPOUND_SIDE_GALLERY_BIAS < TERRAIN_CAVE_ROOM_COMPOUND_PRIMARY_LOBE_BIAS,
)
#assert(TERRAIN_CAVE_ROOM_COMPOUND_REAR_ALCOVE_BIAS < TERRAIN_CAVE_ROOM_COMPOUND_BACK_LOBE_BIAS)
#assert(TERRAIN_CAVE_ROOM_CELLULAR_CELL_SCALE > 0.2)
#assert(TERRAIN_CAVE_ROOM_CELLULAR_CELL_SCALE < 0.5)
#assert(TERRAIN_CAVE_ROOM_CELLULAR_CELL_MIN_BLOCKS >= 3)
#assert(TERRAIN_CAVE_ROOM_CELLULAR_RIDGE_SCALE > TERRAIN_CAVE_ROOM_SCALLOP_SCALE)
#assert(TERRAIN_CAVE_ROOM_CELLULAR_POCKET_SCALE < TERRAIN_CAVE_ROOM_COORD_WARP_SCALE)
#assert(TERRAIN_CAVE_ROOM_STRATA_FLOOR_MOUND_SCALE > TERRAIN_CAVE_ROOM_STRATA_FLOOR_TERRACE_SCALE)
#assert(TERRAIN_CAVE_ROOM_STRATA_FLOOR_MOUND_SCALE < TERRAIN_CAVE_ROOM_SIDE_NOTCH_SCALE)
#assert(
	TERRAIN_CAVE_ROOM_STRATA_CEILING_CHIMNEY_SCALE > TERRAIN_CAVE_ROOM_STRATA_FLOOR_TERRACE_SCALE,
)
#assert(TERRAIN_CAVE_ROOM_STRATA_CEILING_RIB_SCALE < TERRAIN_CAVE_ROOM_CEILING_RIB_SCALE)
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
#assert(TERRAIN_CAVE_NODE_MACRO_SATELLITE_APRON_INNER_SCALE > 0.30)
#assert(TERRAIN_CAVE_NODE_MACRO_SATELLITE_APRON_INNER_SCALE < 0.70)
#assert(TERRAIN_CAVE_NODE_MACRO_SATELLITE_APRON_END_SCALE > 0.80)
#assert(TERRAIN_CAVE_NODE_MACRO_SATELLITE_APRON_END_SCALE <= 1.0)
#assert(
	TERRAIN_CAVE_NODE_MACRO_SATELLITE_APRON_RADIUS_SCALE >
	TERRAIN_CAVE_NODE_MACRO_SATELLITE_THROAT_SCALE,
)
#assert(TERRAIN_CAVE_NODE_MACRO_SATELLITE_APRON_RADIUS_SCALE < 0.85)
#assert(TERRAIN_CAVE_NODE_MACRO_SATELLITE_APRON_VERTICAL_RADIUS_SCALE > 0.35)
#assert(TERRAIN_CAVE_NODE_MACRO_SATELLITE_APRON_VERTICAL_RADIUS_SCALE < 0.85)
#assert(TERRAIN_CAVE_NODE_MACRO_SATELLITE_APRON_SIDE_RADIUS_SCALE > 0.55)
#assert(TERRAIN_CAVE_NODE_MACRO_SATELLITE_APRON_SIDE_RADIUS_SCALE < 1.0)
#assert(TERRAIN_CAVE_NODE_MACRO_SATELLITE_APRON_BRANCH_OFFSET_SCALE > 0.45)
#assert(TERRAIN_CAVE_NODE_MACRO_SATELLITE_APRON_BRANCH_OFFSET_SCALE < 0.95)
#assert(TERRAIN_CAVE_NODE_MACRO_SATELLITE_APRON_BRANCH_RADIUS_SCALE > 0.35)
#assert(TERRAIN_CAVE_NODE_MACRO_SATELLITE_APRON_BRANCH_RADIUS_SCALE < 0.75)
#assert(TERRAIN_CAVE_NODE_MACRO_SATELLITE_APRON_BLEND_RADIUS > 0)
#assert(TERRAIN_CAVE_NODE_MACRO_SATELLITE_APRON_BLEND_RADIUS < 0.5)
#assert(TERRAIN_CAVE_NODE_MACRO_SATELLITE_APRON_CELL_SCALE > 0.30)
#assert(TERRAIN_CAVE_NODE_MACRO_SATELLITE_APRON_CELL_SCALE < 0.75)
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
#assert(TERRAIN_CAVE_FIELD_ROUTE_POCKET_FIELD_BLEND_RADIUS > 0)
#assert(TERRAIN_CAVE_FIELD_ROUTE_POCKET_FIELD_BLEND_RADIUS < 0.5)
#assert(TERRAIN_CAVE_FIELD_ROUTE_POCKET_FIELD_SIDE_OFFSET_SCALE > 0.3)
#assert(TERRAIN_CAVE_FIELD_ROUTE_POCKET_FIELD_SIDE_OFFSET_SCALE < 0.9)
#assert(TERRAIN_CAVE_FIELD_ROUTE_POCKET_FIELD_OUTWARD_OFFSET_SCALE > 0.25)
#assert(TERRAIN_CAVE_FIELD_ROUTE_POCKET_FIELD_OUTWARD_OFFSET_SCALE < 0.75)
#assert(TERRAIN_CAVE_FIELD_ROUTE_POCKET_FIELD_INWARD_OFFSET_SCALE > 0.15)
#assert(TERRAIN_CAVE_FIELD_ROUTE_POCKET_FIELD_INWARD_OFFSET_SCALE < 0.6)
#assert(TERRAIN_CAVE_FIELD_ROUTE_POCKET_FIELD_BRANCH_OFFSET_SCALE > 0.2)
#assert(TERRAIN_CAVE_FIELD_ROUTE_POCKET_FIELD_BRANCH_OFFSET_SCALE < 0.95)
#assert(TERRAIN_CAVE_FIELD_ROUTE_POCKET_FIELD_BRANCH_AWAY_SCALE > 0.15)
#assert(TERRAIN_CAVE_FIELD_ROUTE_POCKET_FIELD_BRANCH_AWAY_SCALE < 0.85)
#assert(TERRAIN_CAVE_FIELD_ROUTE_POCKET_FIELD_CELL_SCALE > 0.25)
#assert(TERRAIN_CAVE_FIELD_ROUTE_POCKET_FIELD_CELL_SCALE < 0.75)
#assert(
	TERRAIN_CAVE_FIELD_NETWORK_CONNECTED_MARGIN_BLOCKS <
	TERRAIN_CAVE_FIELD_NETWORK_BRIDGE_MARGIN_BLOCKS,
)
#assert(
	TERRAIN_CAVE_FIELD_NETWORK_PATH_MARGIN_BLOCKS <
	TERRAIN_CAVE_FIELD_NETWORK_BRIDGE_MARGIN_BLOCKS,
)
#assert(TERRAIN_CAVE_FIELD_NETWORK_BRIDGE_RADIUS_SCALE < 0.5)
#assert(TERRAIN_CAVE_FIELD_DOMAIN_WARP_SCALE_BLOCKS > f32(TERRAIN_CAVE_FIELD_SAMPLE_STEP_BLOCKS))
#assert(TERRAIN_CAVE_FIELD_DOMAIN_WARP_Y_SCALE > 0)
#assert(TERRAIN_CAVE_FIELD_DOMAIN_WARP_Y_SCALE < 0.75)
#assert(TERRAIN_CAVE_FIELD_DOMAIN_WARP_DETAIL_SCALE > 0)
#assert(TERRAIN_CAVE_FIELD_DOMAIN_WARP_DETAIL_SCALE < 0.5)
#assert(TERRAIN_CAVE_EDGE_ROUTE_SEGMENT_COUNT >= 3)
#assert(TERRAIN_CAVE_EDGE_ROUTE_SEGMENT_COUNT >= TERRAIN_CAVE_EDGE_CHAMBERLET_COUNT)
#assert(TERRAIN_CAVE_EDGE_ROUTE_SIDE_WARP_SCALE > TERRAIN_CAVE_EDGE_ROUTE_LIFT_WARP_SCALE)
#assert(TERRAIN_CAVE_EDGE_ROUTE_SIDE_WARP_SCALE < 1.0)
#assert(TERRAIN_CAVE_EDGE_ROUTE_LIFT_WARP_SCALE < 0.5)
#assert(TERRAIN_CAVE_EDGE_ROUTE_RADIUS_NECK_MIN > 0.24)
#assert(TERRAIN_CAVE_EDGE_ROUTE_RADIUS_NECK_MIN < 0.55)
#assert(TERRAIN_CAVE_EDGE_ROUTE_RADIUS_SWELL_MAX > 1.0)
#assert(TERRAIN_CAVE_EDGE_ROUTE_RADIUS_SWELL_MAX < 1.25)
#assert(TERRAIN_CAVE_EDGE_RADIUS_SOFT_CAP_BLEND > 0)
#assert(TERRAIN_CAVE_EDGE_RADIUS_SOFT_CAP_BLEND < 0.5)
#assert(TERRAIN_CAVE_EDGE_RADIUS_CAP_FRACTURE_BLOCKS < TERRAIN_CAVE_EDGE_RADIUS_CAP_DEFAULT_BLOCKS)
#assert(
	TERRAIN_CAVE_EDGE_RADIUS_CAP_COLLAPSED_BLOCKS < TERRAIN_CAVE_EDGE_RADIUS_CAP_DEFAULT_BLOCKS,
)
#assert(TERRAIN_CAVE_EDGE_RADIUS_CAP_WORM_BLOCKS <= TERRAIN_CAVE_EDGE_RADIUS_CAP_FLOODED_BLOCKS)
#assert(TERRAIN_CAVE_EDGE_RADIUS_CAP_CANYON_BLOCKS > TERRAIN_CAVE_EDGE_RADIUS_CAP_FLOODED_BLOCKS)
#assert(TERRAIN_CAVE_EDGE_RADIUS_CAP_SEAM_BLOCKS > TERRAIN_CAVE_EDGE_RADIUS_CAP_CANYON_BLOCKS)
#assert(TERRAIN_CAVE_EDGE_CORE_RADIUS_SCALE_WORM < TERRAIN_CAVE_EDGE_CORE_RADIUS_SCALE_DEFAULT)
#assert(
	TERRAIN_CAVE_EDGE_CORE_RADIUS_SCALE_COLLAPSED < TERRAIN_CAVE_EDGE_CORE_RADIUS_SCALE_DEFAULT,
)
#assert(TERRAIN_CAVE_EDGE_CORE_RADIUS_SCALE_CANYON > TERRAIN_CAVE_EDGE_CORE_RADIUS_SCALE_DEFAULT)
#assert(TERRAIN_CAVE_EDGE_CORE_RADIUS_SCALE_FLOODED > TERRAIN_CAVE_EDGE_CORE_RADIUS_SCALE_WORM)
#assert(TERRAIN_CAVE_EDGE_SEAM_BASE_RADIUS_SCALE > 1.0)
#assert(TERRAIN_CAVE_EDGE_SEAM_CORE_RADIUS_SCALE > 0.88)
#assert(TERRAIN_CAVE_EDGE_SEAM_CORE_RADIUS_SCALE < 1.10)
#assert(TERRAIN_CAVE_EDGE_SEAM_INTERIOR_RADIUS_SCALE > 0.04)
#assert(TERRAIN_CAVE_EDGE_SEAM_INTERIOR_RADIUS_SCALE < 0.16)
#assert(TERRAIN_CAVE_EDGE_SEAM_RADIUS_NECK_MIN > TERRAIN_CAVE_EDGE_ROUTE_RADIUS_NECK_MIN)
#assert(TERRAIN_CAVE_EDGE_SEAM_RADIUS_SWELL_MAX > TERRAIN_CAVE_EDGE_ROUTE_RADIUS_SWELL_MAX)
#assert(TERRAIN_CAVE_EDGE_SEAM_WALL_SCALLOP_MIN > 0.12)
#assert(TERRAIN_CAVE_EDGE_SEAM_WALL_RIB_MIN > 0.12)
#assert(TERRAIN_CAVE_EDGE_SEAM_LIP_RELIEF_SCALE > 0.05)
#assert(TERRAIN_CAVE_EDGE_SEAM_LIP_RELIEF_SCALE < 0.14)
#assert(TERRAIN_CAVE_EDGE_APPROACH_WIDEN_FULL_T > 0)
#assert(TERRAIN_CAVE_EDGE_APPROACH_WIDEN_FULL_T < TERRAIN_CAVE_EDGE_APPROACH_WIDEN_START_T)
#assert(TERRAIN_CAVE_EDGE_APPROACH_WIDEN_START_T < 0.35)
#assert(TERRAIN_CAVE_EDGE_APPROACH_WIDEN_SCALE > 0.25)
#assert(TERRAIN_CAVE_EDGE_APPROACH_WIDEN_SCALE < 0.55)
#assert(TERRAIN_CAVE_EDGE_APPROACH_VESTIBULE_ROUTE_T > TERRAIN_CAVE_EDGE_APPROACH_WIDEN_FULL_T)
#assert(TERRAIN_CAVE_EDGE_APPROACH_VESTIBULE_ROUTE_T < TERRAIN_CAVE_EDGE_APPROACH_WIDEN_START_T)
#assert(TERRAIN_CAVE_EDGE_APPROACH_VESTIBULE_MIN_ROUTE_RADIUS_BLOCKS > 6)
#assert(TERRAIN_CAVE_EDGE_APPROACH_VESTIBULE_SIDE_OFFSET_SCALE > 0.25)
#assert(
	TERRAIN_CAVE_EDGE_APPROACH_VESTIBULE_SIDE_OFFSET_SCALE <
	TERRAIN_CAVE_EDGE_BRAID_SIDE_OFFSET_SCALE,
)
#assert(TERRAIN_CAVE_EDGE_APPROACH_VESTIBULE_VERTICAL_OFFSET_SCALE > 0.15)
#assert(
	TERRAIN_CAVE_EDGE_APPROACH_VESTIBULE_VERTICAL_OFFSET_SCALE <
	TERRAIN_CAVE_EDGE_BRAID_VERTICAL_OFFSET_SCALE,
)
#assert(TERRAIN_CAVE_EDGE_APPROACH_VESTIBULE_RADIUS_SCALE > 0.40)
#assert(TERRAIN_CAVE_EDGE_APPROACH_VESTIBULE_RADIUS_SCALE < 0.90)
#assert(
	TERRAIN_CAVE_EDGE_APPROACH_VESTIBULE_RADIUS_MIN_BLOCKS <
	TERRAIN_CAVE_EDGE_APPROACH_VESTIBULE_RADIUS_MAX_BLOCKS,
)
#assert(TERRAIN_CAVE_EDGE_APPROACH_VESTIBULE_THROAT_SCALE > 0.30)
#assert(TERRAIN_CAVE_EDGE_APPROACH_VESTIBULE_THROAT_SCALE < 0.62)
#assert(TERRAIN_CAVE_EDGE_BRAID_COUNT > 0)
#assert(TERRAIN_CAVE_EDGE_BRAID_ROUTE_MARGIN > 0.08)
#assert(TERRAIN_CAVE_EDGE_BRAID_ROUTE_MARGIN < 0.25)
#assert(TERRAIN_CAVE_EDGE_BRAID_SPAN_T_MIN > 0.12)
#assert(TERRAIN_CAVE_EDGE_BRAID_SPAN_T_MIN < TERRAIN_CAVE_EDGE_BRAID_SPAN_T_MAX)
#assert(TERRAIN_CAVE_EDGE_BRAID_SPAN_T_MAX < 0.45)
#assert(TERRAIN_CAVE_EDGE_BRAID_SIDE_OFFSET_SCALE > 0.45)
#assert(TERRAIN_CAVE_EDGE_BRAID_SIDE_OFFSET_SCALE < TERRAIN_CAVE_EDGE_ALCOVE_SIDE_OFFSET_SCALE)
#assert(TERRAIN_CAVE_EDGE_BRAID_VERTICAL_OFFSET_SCALE > 0.20)
#assert(TERRAIN_CAVE_EDGE_BRAID_VERTICAL_OFFSET_SCALE < 0.50)
#assert(TERRAIN_CAVE_EDGE_BRAID_RADIUS_SCALE > 0.20)
#assert(TERRAIN_CAVE_EDGE_BRAID_RADIUS_SCALE < 0.50)
#assert(
	TERRAIN_CAVE_EDGE_BRAID_RADIUS_THRESHOLD_BLOCKS > TERRAIN_CAVE_EDGE_RADIUS_CAP_FRACTURE_BLOCKS,
)
#assert(TERRAIN_CAVE_EDGE_BRAID_RADIUS_MIN_BLOCKS < TERRAIN_CAVE_EDGE_BRAID_RADIUS_MAX_BLOCKS)
#assert(TERRAIN_CAVE_EDGE_BRAID_POCKET_RADIUS_SCALE > 1.0)
#assert(TERRAIN_CAVE_EDGE_BRAID_POCKET_RADIUS_SCALE < 1.6)
#assert(TERRAIN_CAVE_EDGE_ROUTE_BYPASS_COUNT > 0)
#assert(TERRAIN_CAVE_EDGE_ROUTE_BYPASS_ROUTE_MARGIN > TERRAIN_CAVE_EDGE_BRAID_ROUTE_MARGIN * 0.8)
#assert(TERRAIN_CAVE_EDGE_ROUTE_BYPASS_ROUTE_MARGIN < 0.25)
#assert(TERRAIN_CAVE_EDGE_ROUTE_BYPASS_SPAN_T_MIN > TERRAIN_CAVE_EDGE_BRAID_SPAN_T_MIN)
#assert(TERRAIN_CAVE_EDGE_ROUTE_BYPASS_SPAN_T_MAX > TERRAIN_CAVE_EDGE_ROUTE_BYPASS_SPAN_T_MIN)
#assert(TERRAIN_CAVE_EDGE_ROUTE_BYPASS_SPAN_T_MAX < 0.50)
#assert(
	TERRAIN_CAVE_EDGE_ROUTE_BYPASS_MIN_ROUTE_RADIUS_BLOCKS <
	TERRAIN_CAVE_EDGE_BRAID_RADIUS_THRESHOLD_BLOCKS,
)
#assert(TERRAIN_CAVE_EDGE_ROUTE_BYPASS_MIN_ROUTE_LENGTH_BLOCKS > CHUNK_BLOCK_LENGTH)
#assert(
	TERRAIN_CAVE_EDGE_ROUTE_BYPASS_SIDE_OFFSET_SCALE > TERRAIN_CAVE_EDGE_ALCOVE_SIDE_OFFSET_SCALE,
)
#assert(
	TERRAIN_CAVE_EDGE_ROUTE_BYPASS_VERTICAL_OFFSET_SCALE >
	TERRAIN_CAVE_EDGE_BRAID_VERTICAL_OFFSET_SCALE,
)
#assert(TERRAIN_CAVE_EDGE_ROUTE_BYPASS_VERTICAL_OFFSET_SCALE < 0.70)
#assert(TERRAIN_CAVE_EDGE_ROUTE_BYPASS_RELAY_OFFSET_SCALE > 0.12)
#assert(TERRAIN_CAVE_EDGE_ROUTE_BYPASS_RELAY_OFFSET_SCALE < 0.42)
#assert(TERRAIN_CAVE_EDGE_ROUTE_BYPASS_RADIUS_SCALE > TERRAIN_CAVE_EDGE_BRAID_RADIUS_SCALE)
#assert(TERRAIN_CAVE_EDGE_ROUTE_BYPASS_RADIUS_SCALE < 0.62)
#assert(
	TERRAIN_CAVE_EDGE_ROUTE_BYPASS_RADIUS_MIN_BLOCKS <
	TERRAIN_CAVE_EDGE_ROUTE_BYPASS_RADIUS_MAX_BLOCKS,
)
#assert(TERRAIN_CAVE_EDGE_ROUTE_BYPASS_THROAT_SCALE > 0.20)
#assert(TERRAIN_CAVE_EDGE_ROUTE_BYPASS_THROAT_SCALE < TERRAIN_CAVE_EDGE_BRAID_RADIUS_SCALE)
#assert(TERRAIN_CAVE_EDGE_ROUTE_BYPASS_POCKET_RADIUS_SCALE > 1.0)
#assert(TERRAIN_CAVE_EDGE_ROUTE_BYPASS_POCKET_RADIUS_SCALE < 1.6)
#assert(TERRAIN_CAVE_EDGE_ALCOVE_COUNT > 0)
#assert(TERRAIN_CAVE_EDGE_ALCOVE_ROUTE_MARGIN > 0.05)
#assert(TERRAIN_CAVE_EDGE_ALCOVE_ROUTE_MARGIN < 0.35)
#assert(TERRAIN_CAVE_EDGE_ALCOVE_SIDE_OFFSET_SCALE > 0.75)
#assert(TERRAIN_CAVE_EDGE_ALCOVE_RADIUS_MIN_BLOCKS > 2)
#assert(TERRAIN_CAVE_EDGE_ALCOVE_RADIUS_MAX_BLOCKS > TERRAIN_CAVE_EDGE_ALCOVE_RADIUS_MIN_BLOCKS)
#assert(TERRAIN_CAVE_EDGE_CHAMBERLET_COUNT > 1)
#assert(TERRAIN_CAVE_EDGE_CHAMBERLET_ROUTE_MARGIN > 0.05)
#assert(TERRAIN_CAVE_EDGE_CHAMBERLET_ROUTE_MARGIN < TERRAIN_CAVE_EDGE_ALCOVE_ROUTE_MARGIN)
#assert(
	TERRAIN_CAVE_EDGE_CHAMBERLET_SIDE_OFFSET_SCALE < TERRAIN_CAVE_EDGE_ALCOVE_SIDE_OFFSET_SCALE,
)
#assert(TERRAIN_CAVE_EDGE_CHAMBERLET_RADIUS_MIN_BLOCKS > 2)
#assert(
	TERRAIN_CAVE_EDGE_CHAMBERLET_RADIUS_MAX_BLOCKS >
	TERRAIN_CAVE_EDGE_CHAMBERLET_RADIUS_MIN_BLOCKS,
)
#assert(TERRAIN_CAVE_EDGE_CHAMBERLET_DETAIL_COUNT > 0)
#assert(
	TERRAIN_CAVE_EDGE_CHAMBERLET_DETAIL_OFFSET_SCALE >
	TERRAIN_CAVE_EDGE_CHAMBERLET_SIDE_OFFSET_SCALE,
)
#assert(
	TERRAIN_CAVE_EDGE_CHAMBERLET_DETAIL_RADIUS_MIN_BLOCKS <
	TERRAIN_CAVE_EDGE_CHAMBERLET_DETAIL_RADIUS_MAX_BLOCKS,
)
#assert(
	TERRAIN_CAVE_EDGE_CHAMBERLET_DETAIL_RADIUS_MAX_BLOCKS <
	TERRAIN_CAVE_EDGE_CHAMBERLET_RADIUS_MAX_BLOCKS,
)
#assert(TERRAIN_CAVE_EDGE_CHAMBERLET_DETAIL_THROAT_SCALE > 0.12)
#assert(TERRAIN_CAVE_EDGE_CHAMBERLET_DETAIL_THROAT_SCALE < 0.40)
#assert(TERRAIN_CAVE_EDGE_CHAMBERLET_DETAIL_COUNT >= 2)
#assert(
	TERRAIN_CAVE_EDGE_CHAMBERLET_DETAIL_LOOP_RADIUS_SCALE >
	TERRAIN_CAVE_EDGE_CHAMBERLET_DETAIL_THROAT_SCALE,
)
#assert(
	TERRAIN_CAVE_EDGE_CHAMBERLET_DETAIL_LOOP_ROUTE_CAP_SCALE <
	TERRAIN_CAVE_EDGE_CHAMBERLET_DETAIL_THROAT_SCALE,
)
#assert(TERRAIN_CAVE_EDGE_CHAMBERLET_DETAIL_LOOP_POCKET_RADIUS_SCALE > 1.0)
#assert(TERRAIN_CAVE_EDGE_CHAMBERLET_DETAIL_LOOP_POCKET_RADIUS_SCALE < 2.2)
#assert(
	TERRAIN_CAVE_EDGE_CHAMBERLET_GALLERY_RADIUS_SCALE >
	TERRAIN_CAVE_EDGE_CHAMBERLET_DETAIL_THROAT_SCALE,
)
#assert(TERRAIN_CAVE_EDGE_CHAMBERLET_GALLERY_RADIUS_SCALE < 0.60)
#assert(
	TERRAIN_CAVE_EDGE_CHAMBERLET_GALLERY_ROUTE_CAP_SCALE >
	TERRAIN_CAVE_EDGE_CHAMBERLET_DETAIL_LOOP_ROUTE_CAP_SCALE,
)
#assert(TERRAIN_CAVE_EDGE_CHAMBERLET_GALLERY_ROUTE_CAP_SCALE < 0.42)
#assert(TERRAIN_CAVE_EDGE_CHAMBERLET_GALLERY_POCKET_RADIUS_SCALE > 1.0)
#assert(TERRAIN_CAVE_EDGE_CHAMBERLET_GALLERY_POCKET_RADIUS_SCALE < 1.8)
#assert(TERRAIN_CAVE_EDGE_CHAMBERLET_GALLERY_RELAY_OFFSET_SCALE > 0.12)
#assert(TERRAIN_CAVE_EDGE_CHAMBERLET_GALLERY_RELAY_OFFSET_SCALE < 0.48)
#assert(TERRAIN_CAVE_EDGE_CHAMBERLET_GALLERY_RELAY_VERTICAL_OFFSET_SCALE > 0.08)
#assert(TERRAIN_CAVE_EDGE_CHAMBERLET_GALLERY_RELAY_VERTICAL_OFFSET_SCALE < 0.30)
#assert(TERRAIN_CAVE_EDGE_CHAMBERLET_GALLERY_RELAY_POCKET_RADIUS_SCALE > 1.0)
#assert(TERRAIN_CAVE_EDGE_CHAMBERLET_GALLERY_RELAY_POCKET_RADIUS_SCALE < 1.9)
#assert(TERRAIN_CAVE_EDGE_SEAM_BAY_COUNT > 1)
#assert(TERRAIN_CAVE_EDGE_SEAM_BAY_ROUTE_MARGIN > 0.12)
#assert(TERRAIN_CAVE_EDGE_SEAM_BAY_ROUTE_MARGIN < 0.26)
#assert(TERRAIN_CAVE_EDGE_SEAM_BAY_SIDE_OFFSET_SCALE > 0.16)
#assert(
	TERRAIN_CAVE_EDGE_SEAM_BAY_SIDE_OFFSET_SCALE <
	TERRAIN_CAVE_EDGE_SEAM_GALLERY_SIDE_OFFSET_SCALE,
)
#assert(
	TERRAIN_CAVE_EDGE_SEAM_BAY_VERTICAL_OFFSET_SCALE >
	TERRAIN_CAVE_EDGE_SEAM_GALLERY_VERTICAL_OFFSET_SCALE,
)
#assert(TERRAIN_CAVE_EDGE_SEAM_BAY_VERTICAL_OFFSET_SCALE < 0.80)
#assert(
	TERRAIN_CAVE_EDGE_SEAM_BAY_RADIUS_MIN_BLOCKS < TERRAIN_CAVE_EDGE_SEAM_BAY_RADIUS_MAX_BLOCKS,
)
#assert(TERRAIN_CAVE_EDGE_SEAM_BAY_THROAT_SCALE > TERRAIN_CAVE_EDGE_SEAM_GALLERY_THROAT_SCALE)
#assert(TERRAIN_CAVE_EDGE_SEAM_BAY_THROAT_SCALE < 0.65)
#assert(TERRAIN_CAVE_EDGE_SEAM_BYPASS_COUNT > 1)
#assert(TERRAIN_CAVE_EDGE_SEAM_BYPASS_ROUTE_MARGIN > 0.08)
#assert(TERRAIN_CAVE_EDGE_SEAM_BYPASS_ROUTE_MARGIN < TERRAIN_CAVE_EDGE_SEAM_BAY_ROUTE_MARGIN)
#assert(TERRAIN_CAVE_EDGE_SEAM_BYPASS_SPAN_T_MIN > TERRAIN_CAVE_EDGE_SEAM_SHOULDER_SPAN_T)
#assert(TERRAIN_CAVE_EDGE_SEAM_BYPASS_SPAN_T_MAX > TERRAIN_CAVE_EDGE_SEAM_BYPASS_SPAN_T_MIN)
#assert(TERRAIN_CAVE_EDGE_SEAM_BYPASS_SPAN_T_MAX < 0.34)
#assert(
	TERRAIN_CAVE_EDGE_SEAM_BYPASS_SIDE_OFFSET_SCALE >
	TERRAIN_CAVE_EDGE_SEAM_GALLERY_SIDE_OFFSET_SCALE,
)
#assert(TERRAIN_CAVE_EDGE_SEAM_BYPASS_VERTICAL_OFFSET_SCALE > 0.55)
#assert(TERRAIN_CAVE_EDGE_SEAM_BYPASS_VERTICAL_OFFSET_SCALE < 1.05)
#assert(
	TERRAIN_CAVE_EDGE_SEAM_BYPASS_RADIUS_MIN_BLOCKS <
	TERRAIN_CAVE_EDGE_SEAM_BYPASS_RADIUS_MAX_BLOCKS,
)
#assert(TERRAIN_CAVE_EDGE_SEAM_BYPASS_THROAT_SCALE < TERRAIN_CAVE_EDGE_SEAM_GALLERY_THROAT_SCALE)
#assert(TERRAIN_CAVE_EDGE_SEAM_BYPASS_ROOM_RADIUS_SCALE > 1.0)
#assert(TERRAIN_CAVE_EDGE_SEAM_BYPASS_ROOM_RADIUS_SCALE < 1.55)
#assert(TERRAIN_CAVE_EDGE_SEAM_BYPASS_RELAY_OFFSET_SCALE > 0.12)
#assert(TERRAIN_CAVE_EDGE_SEAM_BYPASS_RELAY_OFFSET_SCALE < 0.40)
#assert(TERRAIN_CAVE_EDGE_SEAM_CROSSCUT_COUNT > 1)
#assert(TERRAIN_CAVE_EDGE_SEAM_CROSSCUT_ROUTE_MARGIN > 0.10)
#assert(TERRAIN_CAVE_EDGE_SEAM_CROSSCUT_ROUTE_MARGIN < TERRAIN_CAVE_EDGE_SEAM_BAY_ROUTE_MARGIN)
#assert(TERRAIN_CAVE_EDGE_SEAM_CROSSCUT_SPAN_T > TERRAIN_CAVE_EDGE_SEAM_SHOULDER_SPAN_T)
#assert(TERRAIN_CAVE_EDGE_SEAM_CROSSCUT_SPAN_T < TERRAIN_CAVE_EDGE_SEAM_BYPASS_SPAN_T_MIN)
#assert(
	TERRAIN_CAVE_EDGE_SEAM_CROSSCUT_SIDE_OFFSET_SCALE >
	TERRAIN_CAVE_EDGE_SEAM_GALLERY_SIDE_OFFSET_SCALE,
)
#assert(
	TERRAIN_CAVE_EDGE_SEAM_CROSSCUT_SIDE_OFFSET_SCALE <
	TERRAIN_CAVE_EDGE_SEAM_BYPASS_SIDE_OFFSET_SCALE,
)
#assert(TERRAIN_CAVE_EDGE_SEAM_CROSSCUT_VERTICAL_OFFSET_SCALE > 0.42)
#assert(
	TERRAIN_CAVE_EDGE_SEAM_CROSSCUT_VERTICAL_OFFSET_SCALE <
	TERRAIN_CAVE_EDGE_SEAM_BYPASS_VERTICAL_OFFSET_SCALE,
)
#assert(
	TERRAIN_CAVE_EDGE_SEAM_CROSSCUT_RADIUS_MIN_BLOCKS <
	TERRAIN_CAVE_EDGE_SEAM_CROSSCUT_RADIUS_MAX_BLOCKS,
)
#assert(TERRAIN_CAVE_EDGE_SEAM_CROSSCUT_MOUTH_RADIUS_SCALE > 0.70)
#assert(TERRAIN_CAVE_EDGE_SEAM_CROSSCUT_MOUTH_RADIUS_SCALE < 1.00)
#assert(TERRAIN_CAVE_EDGE_SEAM_CROSSCUT_BRANCH_RADIUS_SCALE > 0.70)
#assert(TERRAIN_CAVE_EDGE_SEAM_CROSSCUT_BRANCH_RADIUS_SCALE < 1.00)
#assert(TERRAIN_CAVE_EDGE_SEAM_CROSSCUT_NODE_RADIUS_SCALE > 1.0)
#assert(TERRAIN_CAVE_EDGE_SEAM_CROSSCUT_NODE_RADIUS_SCALE < 1.60)
#assert(TERRAIN_CAVE_EDGE_SEAM_CROSSCUT_NODE_SIDE_SCALE > 0.70)
#assert(TERRAIN_CAVE_EDGE_SEAM_CROSSCUT_NODE_SIDE_SCALE < 1.05)
#assert(TERRAIN_CAVE_EDGE_SEAM_CROSSCUT_NODE_VERTICAL_SCALE > 0.25)
#assert(TERRAIN_CAVE_EDGE_SEAM_CROSSCUT_NODE_VERTICAL_SCALE < 0.55)
#assert(TERRAIN_CAVE_EDGE_SEAM_SHOULDER_COUNT > 1)
#assert(TERRAIN_CAVE_EDGE_SEAM_SHOULDER_ROUTE_MARGIN > 0.08)
#assert(TERRAIN_CAVE_EDGE_SEAM_SHOULDER_ROUTE_MARGIN < TERRAIN_CAVE_EDGE_SEAM_BAY_ROUTE_MARGIN)
#assert(TERRAIN_CAVE_EDGE_SEAM_SHOULDER_SPAN_T > 0.08)
#assert(TERRAIN_CAVE_EDGE_SEAM_SHOULDER_SPAN_T < 0.20)
#assert(
	TERRAIN_CAVE_EDGE_SEAM_SHOULDER_SIDE_OFFSET_SCALE >
	TERRAIN_CAVE_EDGE_SEAM_BAY_SIDE_OFFSET_SCALE,
)
#assert(
	TERRAIN_CAVE_EDGE_SEAM_SHOULDER_SIDE_OFFSET_SCALE <
	TERRAIN_CAVE_EDGE_SEAM_GALLERY_SIDE_OFFSET_SCALE,
)
#assert(TERRAIN_CAVE_EDGE_SEAM_SHOULDER_VERTICAL_OFFSET_SCALE > 0.20)
#assert(
	TERRAIN_CAVE_EDGE_SEAM_SHOULDER_VERTICAL_OFFSET_SCALE <
	TERRAIN_CAVE_EDGE_SEAM_BAY_VERTICAL_OFFSET_SCALE,
)
#assert(
	TERRAIN_CAVE_EDGE_SEAM_SHOULDER_RADIUS_MIN_BLOCKS <
	TERRAIN_CAVE_EDGE_SEAM_SHOULDER_RADIUS_MAX_BLOCKS,
)
#assert(TERRAIN_CAVE_EDGE_SEAM_SHOULDER_THROAT_SCALE > 0.25)
#assert(TERRAIN_CAVE_EDGE_SEAM_SHOULDER_THROAT_SCALE < TERRAIN_CAVE_EDGE_SEAM_BAY_THROAT_SCALE)
#assert(TERRAIN_CAVE_EDGE_SEAM_SHOULDER_POCKET_RADIUS_SCALE > 1.0)
#assert(TERRAIN_CAVE_EDGE_SEAM_SHOULDER_POCKET_RADIUS_SCALE < 1.35)
#assert(TERRAIN_CAVE_EDGE_SEAM_VERTICAL_RELIEF_COUNT > TERRAIN_CAVE_EDGE_SEAM_SHOULDER_COUNT)
#assert(
	TERRAIN_CAVE_EDGE_SEAM_VERTICAL_RELIEF_ROUTE_MARGIN <
	TERRAIN_CAVE_EDGE_SEAM_SHOULDER_ROUTE_MARGIN,
)
#assert(TERRAIN_CAVE_EDGE_SEAM_VERTICAL_RELIEF_SPAN_T > 0.06)
#assert(TERRAIN_CAVE_EDGE_SEAM_VERTICAL_RELIEF_SPAN_T < TERRAIN_CAVE_EDGE_SEAM_SHOULDER_SPAN_T)
#assert(TERRAIN_CAVE_EDGE_SEAM_VERTICAL_RELIEF_OFFSET_SCALE > 0.95)
#assert(TERRAIN_CAVE_EDGE_SEAM_VERTICAL_RELIEF_OFFSET_SCALE < 1.45)
#assert(
	TERRAIN_CAVE_EDGE_SEAM_VERTICAL_RELIEF_SIDE_DRIFT_SCALE <
	TERRAIN_CAVE_EDGE_SEAM_BAY_SIDE_OFFSET_SCALE,
)
#assert(
	TERRAIN_CAVE_EDGE_SEAM_VERTICAL_RELIEF_RADIUS_MIN_BLOCKS <
	TERRAIN_CAVE_EDGE_SEAM_VERTICAL_RELIEF_RADIUS_MAX_BLOCKS,
)
#assert(TERRAIN_CAVE_EDGE_SEAM_VERTICAL_RELIEF_RIB_RADIUS_SCALE > 0.45)
#assert(TERRAIN_CAVE_EDGE_SEAM_VERTICAL_RELIEF_RIB_RADIUS_SCALE < 0.82)
#assert(TERRAIN_CAVE_EDGE_SEAM_VERTICAL_RELIEF_THROAT_SCALE > 0.24)
#assert(
	TERRAIN_CAVE_EDGE_SEAM_VERTICAL_RELIEF_THROAT_SCALE < TERRAIN_CAVE_EDGE_SEAM_BAY_THROAT_SCALE,
)
#assert(TERRAIN_CAVE_EDGE_SEAM_VERTICAL_RELIEF_POCKET_RADIUS_SCALE > 0.90)
#assert(TERRAIN_CAVE_EDGE_SEAM_VERTICAL_RELIEF_POCKET_RADIUS_SCALE < 1.25)
#assert(TERRAIN_CAVE_EDGE_SEAM_GALLERY_COUNT > 1)
#assert(TERRAIN_CAVE_EDGE_SEAM_GALLERY_ROUTE_MARGIN > 0.08)
#assert(TERRAIN_CAVE_EDGE_SEAM_GALLERY_ROUTE_MARGIN < 0.25)
#assert(TERRAIN_CAVE_EDGE_SEAM_GALLERY_SIDE_OFFSET_SCALE > 0.30)
#assert(TERRAIN_CAVE_EDGE_SEAM_GALLERY_SIDE_OFFSET_SCALE < 0.70)
#assert(TERRAIN_CAVE_EDGE_SEAM_GALLERY_VERTICAL_OFFSET_SCALE > 0.25)
#assert(TERRAIN_CAVE_EDGE_SEAM_GALLERY_VERTICAL_OFFSET_SCALE < 0.60)
#assert(
	TERRAIN_CAVE_EDGE_SEAM_GALLERY_RADIUS_MIN_BLOCKS <
	TERRAIN_CAVE_EDGE_SEAM_GALLERY_RADIUS_MAX_BLOCKS,
)
#assert(TERRAIN_CAVE_EDGE_SEAM_GALLERY_THROAT_SCALE > 0.22)
#assert(TERRAIN_CAVE_EDGE_SEAM_GALLERY_THROAT_SCALE < 0.45)
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
#assert(TERRAIN_CAVE_NODE_MAJOR_ROOM_FIELD_EXTENT_SCALE > 1.2)
#assert(TERRAIN_CAVE_NODE_MAJOR_ROOM_FIELD_EXTENT_SCALE < 1.8)
#assert(TERRAIN_CAVE_NODE_MAJOR_ROOM_FIELD_SIDE_CENTER_SCALE > 0.45)
#assert(TERRAIN_CAVE_NODE_MAJOR_ROOM_FIELD_SIDE_CENTER_SCALE < 0.95)
#assert(TERRAIN_CAVE_NODE_MAJOR_ROOM_FIELD_SIDE_ACROSS_SCALE > 0.35)
#assert(TERRAIN_CAVE_NODE_MAJOR_ROOM_FIELD_SIDE_ACROSS_SCALE < 0.85)
#assert(TERRAIN_CAVE_NODE_MAJOR_ROOM_FIELD_SIDE_RADIUS_SCALE > 0.30)
#assert(TERRAIN_CAVE_NODE_MAJOR_ROOM_FIELD_SIDE_RADIUS_SCALE < 0.70)
#assert(TERRAIN_CAVE_NODE_MAJOR_ROOM_FIELD_CONNECTOR_RADIUS_SCALE > 0.18)
#assert(TERRAIN_CAVE_NODE_MAJOR_ROOM_FIELD_CONNECTOR_RADIUS_SCALE < 0.45)
#assert(TERRAIN_CAVE_NODE_MAJOR_ROOM_FIELD_BLEND_RADIUS > 0)
#assert(TERRAIN_CAVE_NODE_MAJOR_ROOM_FIELD_BLEND_RADIUS < 0.35)
#assert(TERRAIN_CAVE_NODE_MAJOR_ROOM_FIELD_CELL_SCALE > 0.25)
#assert(TERRAIN_CAVE_NODE_MAJOR_ROOM_FIELD_CELL_SCALE < 0.65)
#assert(TERRAIN_CAVE_NODE_EDGE_PORTAL_MAX_COUNT >= 3)
#assert(TERRAIN_CAVE_NODE_EDGE_PORTAL_ROUTE_T > 0.08)
#assert(TERRAIN_CAVE_NODE_EDGE_PORTAL_ROUTE_T < TERRAIN_CAVE_EDGE_APPROACH_WIDEN_START_T)
#assert(TERRAIN_CAVE_NODE_EDGE_PORTAL_OFFSET_SCALE > 0.70)
#assert(TERRAIN_CAVE_NODE_EDGE_PORTAL_OFFSET_SCALE < 1.35)
#assert(TERRAIN_CAVE_NODE_EDGE_PORTAL_SIDE_OFFSET_SCALE > 0.12)
#assert(TERRAIN_CAVE_NODE_EDGE_PORTAL_SIDE_OFFSET_SCALE < 0.40)
#assert(TERRAIN_CAVE_NODE_EDGE_PORTAL_VERTICAL_OFFSET_SCALE > 0.10)
#assert(TERRAIN_CAVE_NODE_EDGE_PORTAL_VERTICAL_OFFSET_SCALE < 0.35)
#assert(TERRAIN_CAVE_NODE_EDGE_PORTAL_RADIUS_SCALE > 0.30)
#assert(TERRAIN_CAVE_NODE_EDGE_PORTAL_RADIUS_SCALE < 0.80)
#assert(
	TERRAIN_CAVE_NODE_EDGE_PORTAL_RADIUS_MIN_BLOCKS <
	TERRAIN_CAVE_NODE_EDGE_PORTAL_RADIUS_MAX_BLOCKS,
)
#assert(TERRAIN_CAVE_NODE_EDGE_PORTAL_THROAT_SCALE > 0.25)
#assert(TERRAIN_CAVE_NODE_EDGE_PORTAL_THROAT_SCALE < 0.58)
#assert(TERRAIN_CAVE_NODE_EDGE_PORTAL_CRYSTAL_SPLINTER_SIDE_SCALE > 0.75)
#assert(TERRAIN_CAVE_NODE_EDGE_PORTAL_CRYSTAL_SPLINTER_SIDE_SCALE < 1.35)
#assert(TERRAIN_CAVE_NODE_EDGE_PORTAL_CRYSTAL_SPLINTER_FORWARD_SCALE > 0)
#assert(TERRAIN_CAVE_NODE_EDGE_PORTAL_CRYSTAL_SPLINTER_FORWARD_SCALE < 0.35)
#assert(TERRAIN_CAVE_NODE_EDGE_PORTAL_CRYSTAL_SPLINTER_VERTICAL_SCALE >= 0)
#assert(TERRAIN_CAVE_NODE_EDGE_PORTAL_CRYSTAL_SPLINTER_VERTICAL_SCALE < 0.28)
#assert(TERRAIN_CAVE_NODE_EDGE_PORTAL_CRYSTAL_SPLINTER_RADIUS_SCALE > 0.35)
#assert(TERRAIN_CAVE_NODE_EDGE_PORTAL_CRYSTAL_SPLINTER_RADIUS_SCALE < 0.80)
#assert(TERRAIN_CAVE_NODE_EDGE_PORTAL_CRYSTAL_SPLINTER_THROAT_SCALE > 0.15)
#assert(TERRAIN_CAVE_NODE_EDGE_PORTAL_CRYSTAL_SPLINTER_THROAT_SCALE < 0.40)
#assert(TERRAIN_CAVE_NODE_MACRO_SATELLITE_COUNT > 1)
#assert(TERRAIN_CAVE_NODE_MACRO_SATELLITE_COUNT >= 3)
#assert(TERRAIN_CAVE_NODE_MACRO_SATELLITE_OFFSET_SCALE > 0.75)
#assert(TERRAIN_CAVE_NODE_MACRO_SATELLITE_OFFSET_SCALE < 1.35)
#assert(TERRAIN_CAVE_NODE_MACRO_SATELLITE_RADIUS_XZ_SCALE > 0.45)
#assert(TERRAIN_CAVE_NODE_MACRO_SATELLITE_RADIUS_XZ_SCALE < 0.85)
#assert(TERRAIN_CAVE_NODE_MACRO_SATELLITE_RADIUS_Y_SCALE > 0.35)
#assert(TERRAIN_CAVE_NODE_MACRO_SATELLITE_RADIUS_Y_SCALE < 0.75)
#assert(TERRAIN_CAVE_NODE_MACRO_SATELLITE_VERTICAL_OFFSET_SCALE > 0.10)
#assert(TERRAIN_CAVE_NODE_MACRO_SATELLITE_VERTICAL_OFFSET_SCALE < 0.45)
#assert(TERRAIN_CAVE_NODE_MACRO_SATELLITE_THROAT_SCALE > 0.20)
#assert(TERRAIN_CAVE_NODE_MACRO_SATELLITE_THROAT_SCALE < 0.45)
#assert(TERRAIN_CAVE_NODE_MACRO_SATELLITE_CLUSTER_BRIDGE_RADIUS_SCALE > 0.18)
#assert(TERRAIN_CAVE_NODE_MACRO_SATELLITE_CLUSTER_BRIDGE_RADIUS_SCALE < 0.42)
#assert(TERRAIN_CAVE_NODE_MACRO_SATELLITE_CLUSTER_BRIDGE_MIN_BLOCKS >= 1.5)
#assert(
	TERRAIN_CAVE_NODE_MACRO_SATELLITE_CLUSTER_OUTER_OFFSET_SCALE >
	TERRAIN_CAVE_NODE_MACRO_SATELLITE_OFFSET_SCALE,
)
#assert(TERRAIN_CAVE_NODE_MACRO_SATELLITE_CLUSTER_OUTER_OFFSET_SCALE < 1.65)
#assert(
	TERRAIN_CAVE_NODE_MACRO_SATELLITE_CLUSTER_POCKET_RADIUS_SCALE >
	TERRAIN_CAVE_NODE_MACRO_SATELLITE_CLUSTER_BRIDGE_RADIUS_SCALE,
)
#assert(
	TERRAIN_CAVE_NODE_MACRO_SATELLITE_CLUSTER_POCKET_MIN_BLOCKS <
	TERRAIN_CAVE_NODE_MACRO_SATELLITE_CLUSTER_POCKET_MAX_BLOCKS,
)
#assert(TERRAIN_CAVE_NODE_MACRO_SATELLITE_CLUSTER_ALCOVE_OFFSET_SCALE > 0.5)
#assert(TERRAIN_CAVE_NODE_MACRO_SATELLITE_CLUSTER_ALCOVE_OFFSET_SCALE < 1.4)
#assert(TERRAIN_CAVE_NODE_MACRO_SATELLITE_CLUSTER_ALCOVE_RADIUS_SCALE > 0.4)
#assert(TERRAIN_CAVE_NODE_MACRO_SATELLITE_CLUSTER_ALCOVE_RADIUS_SCALE < 1.0)
#assert(TERRAIN_CAVE_NODE_MACRO_SATELLITE_CLUSTER_ALCOVE_THROAT_SCALE > 0.35)
#assert(TERRAIN_CAVE_NODE_MACRO_SATELLITE_CLUSTER_ALCOVE_THROAT_SCALE < 0.9)
#assert(TERRAIN_CAVE_NODE_MACRO_SATELLITE_CLUSTER_FIELD_RADIUS_SCALE > 1.0)
#assert(TERRAIN_CAVE_NODE_MACRO_SATELLITE_CLUSTER_FIELD_RADIUS_SCALE < 1.8)
#assert(TERRAIN_CAVE_NODE_MACRO_SATELLITE_CLUSTER_FIELD_SIDE_OFFSET_SCALE > 0.6)
#assert(TERRAIN_CAVE_NODE_MACRO_SATELLITE_CLUSTER_FIELD_SIDE_OFFSET_SCALE < 1.4)
#assert(TERRAIN_CAVE_NODE_MACRO_SATELLITE_CLUSTER_FIELD_SIDE_RADIUS_SCALE > 0.5)
#assert(TERRAIN_CAVE_NODE_MACRO_SATELLITE_CLUSTER_FIELD_SIDE_RADIUS_SCALE < 1.2)
#assert(TERRAIN_CAVE_NODE_MACRO_SATELLITE_CLUSTER_FIELD_OUTWARD_OFFSET_SCALE > 0.3)
#assert(TERRAIN_CAVE_NODE_MACRO_SATELLITE_CLUSTER_FIELD_OUTWARD_OFFSET_SCALE < 1.0)
#assert(TERRAIN_CAVE_NODE_MACRO_SATELLITE_CLUSTER_FIELD_BRANCH_OFFSET_SCALE > 0.35)
#assert(TERRAIN_CAVE_NODE_MACRO_SATELLITE_CLUSTER_FIELD_BRANCH_OFFSET_SCALE < 1.05)
#assert(TERRAIN_CAVE_NODE_MACRO_SATELLITE_CLUSTER_FIELD_BRANCH_OUTWARD_SCALE > 0.25)
#assert(TERRAIN_CAVE_NODE_MACRO_SATELLITE_CLUSTER_FIELD_BRANCH_OUTWARD_SCALE < 0.85)
#assert(TERRAIN_CAVE_NODE_MACRO_SATELLITE_CLUSTER_FIELD_BRANCH_RADIUS_SCALE > 0.45)
#assert(TERRAIN_CAVE_NODE_MACRO_SATELLITE_CLUSTER_FIELD_BRANCH_RADIUS_SCALE < 1.0)
#assert(TERRAIN_CAVE_NODE_MACRO_SATELLITE_CLUSTER_FIELD_BRANCH_NECK_RADIUS_SCALE > 0.25)
#assert(TERRAIN_CAVE_NODE_MACRO_SATELLITE_CLUSTER_FIELD_BRANCH_NECK_RADIUS_SCALE < 0.7)
#assert(TERRAIN_CAVE_NODE_MACRO_SATELLITE_CLUSTER_FIELD_BLEND_RADIUS > 0)
#assert(TERRAIN_CAVE_NODE_MACRO_SATELLITE_CLUSTER_FIELD_BLEND_RADIUS < 0.5)
#assert(TERRAIN_CAVE_NODE_MACRO_SATELLITE_CLUSTER_FIELD_CELL_SCALE > 0.3)
#assert(TERRAIN_CAVE_NODE_MACRO_SATELLITE_CLUSTER_FIELD_CELL_SCALE < 0.8)
#assert(
	TERRAIN_CAVE_NODE_MACRO_SATELLITE_MIN_RADIUS_BLOCKS <
	TERRAIN_CAVE_NODE_MACRO_SATELLITE_MAX_RADIUS_BLOCKS,
)
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
TERRAIN_AQUIFER_ROOM_MIRROR_SHELF_OFFSET_SCALE :: f32(0.54)
TERRAIN_AQUIFER_ROOM_MIRROR_SHELF_XZ_SCALE :: f32(0.44)
TERRAIN_AQUIFER_ROOM_MIRROR_SHELF_Y_SCALE :: f32(0.28)
TERRAIN_AQUIFER_ROOM_MIRROR_SHELF_Y_OFFSET_SCALE :: f32(0.08)
TERRAIN_AQUIFER_ROOM_SIDE_SHELF_OFFSET_SCALE :: f32(1.18)
TERRAIN_AQUIFER_ROOM_SIDE_SHELF_XZ_SCALE :: f32(0.38)
TERRAIN_AQUIFER_ROOM_SIDE_SHELF_Y_SCALE :: f32(0.24)
TERRAIN_AQUIFER_ROOM_SIDE_SHELF_Y_OFFSET_SCALE :: f32(0.06)
TERRAIN_AQUIFER_ROOM_CRESCENT_FORWARD_SCALE :: f32(0.74)
TERRAIN_AQUIFER_ROOM_CRESCENT_SIDE_OFFSET_SCALE :: f32(1.04)
TERRAIN_AQUIFER_ROOM_CRESCENT_Y_OFFSET_SCALE :: f32(0.04)
TERRAIN_AQUIFER_ROOM_CRESCENT_RADIUS_SCALE :: f32(0.30)
TERRAIN_AQUIFER_ROOM_CRESCENT_RADIUS_MIN_BLOCKS :: f32(2.1)
TERRAIN_AQUIFER_ROOM_CRESCENT_RADIUS_MAX_BLOCKS :: f32(6.75)
TERRAIN_AQUIFER_ROOM_CRESCENT_Y_SCALE :: f32(0.48)
TERRAIN_AQUIFER_ROOM_WATER_XZ_SCALE :: f32(0.92)
TERRAIN_AQUIFER_ROOM_WATER_Y_SCALE :: f32(0.16)
TERRAIN_AQUIFER_ROOM_WATER_Y_OFFSET_SCALE :: f32(-0.46)
#assert(TERRAIN_AQUIFER_ROOM_BASIN_XZ_SCALE > 1)
#assert(TERRAIN_AQUIFER_ROOM_BASIN_Y_SCALE < 0.5)
#assert(TERRAIN_AQUIFER_ROOM_MIRROR_SHELF_OFFSET_SCALE > TERRAIN_AQUIFER_ROOM_SHELF_OFFSET_SCALE)
#assert(TERRAIN_AQUIFER_ROOM_SIDE_SHELF_OFFSET_SCALE > TERRAIN_AQUIFER_ROOM_BASIN_XZ_SCALE)
#assert(TERRAIN_AQUIFER_ROOM_CRESCENT_SIDE_OFFSET_SCALE > TERRAIN_AQUIFER_ROOM_SHELF_OFFSET_SCALE)
#assert(
	TERRAIN_AQUIFER_ROOM_CRESCENT_SIDE_OFFSET_SCALE < TERRAIN_AQUIFER_ROOM_SIDE_SHELF_OFFSET_SCALE,
)
#assert(
	TERRAIN_AQUIFER_ROOM_CRESCENT_RADIUS_MAX_BLOCKS >
	TERRAIN_AQUIFER_ROOM_CRESCENT_RADIUS_MIN_BLOCKS,
)
#assert(TERRAIN_AQUIFER_ROOM_CRESCENT_Y_SCALE < TERRAIN_AQUIFER_ROOM_BASIN_Y_SCALE + 0.12)
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
	// Variant 0: canonical base colors.
	{0.30, 0.62, 0.27, 1.0}, // Grass
	{0.43, 0.28, 0.15, 1.0}, // Dirt
	{0.40, 0.41, 0.45, 1.0}, // Stone
	{0.66, 0.63, 0.49, 1.0}, // Wet marsh / sand
	{0.18, 0.37, 0.72, 1.0}, // Water
	{0.20, 0.18, 0.20, 1.0}, // Corrupted ash
	{0.48, 0.56, 0.46, 1.0}, // Aquifer wall
	{0.58, 0.82, 0.92, 1.0}, // Crystal

	// Variant 1: moss, litter, basalt, swamp water, and aquifer algae.
	{0.22, 0.49, 0.23, 1.0},
	{0.36, 0.24, 0.12, 1.0},
	{0.30, 0.32, 0.36, 1.0},
	{0.40, 0.47, 0.34, 1.0},
	{0.14, 0.31, 0.28, 1.0},
	{0.25, 0.20, 0.16, 1.0},
	{0.38, 0.52, 0.42, 1.0},
	{0.46, 0.72, 0.84, 1.0},

	// Variant 2: dry grass, loam, ember ash, corrupted water, and mineral stains.
	{0.45, 0.58, 0.25, 1.0},
	{0.30, 0.19, 0.12, 1.0},
	{0.24, 0.23, 0.26, 1.0},
	{0.52, 0.44, 0.32, 1.0},
	{0.28, 0.18, 0.43, 1.0},
	{0.31, 0.12, 0.20, 1.0},
	{0.42, 0.48, 0.50, 1.0},
	{0.64, 0.54, 0.94, 1.0},

	// Variant 3: flowered grass, root-rich dirt, hot stone, lava, and bright crystal.
	{0.36, 0.66, 0.34, 1.0},
	{0.50, 0.34, 0.18, 1.0},
	{0.46, 0.27, 0.18, 1.0},
	{0.58, 0.34, 0.22, 1.0},
	{0.96, 0.28, 0.06, 1.0},
	{0.42, 0.16, 0.10, 1.0},
	{0.54, 0.48, 0.36, 1.0},
	{0.86, 0.92, 1.00, 1.0},
}

//////////////////////////////////////
// Terrain Types
/////////////////////////////////////

TerrainMaterialColorPalette :: [TERRAIN_MATERIAL_COLOR_COUNT]Vec4

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
	surface_height:                  i32,
	surface_height_blocks:           f32,
	surface_layer_depth:             i32,
	water_level_blocks:              f32,
	surface_morphology_profile:      biomes.SurfaceMorphologyProfile,
	dominant_biome_id:               biomes.BiomeID,
	water_biome_id:                  biomes.BiomeID,
	surface_material_id:             world_async.BlockMaterialID,
	subsurface_material_id:          world_async.BlockMaterialID,
	hydrology_debug_material_active: bool,
	water_fill_active:               bool,
}

TerrainWaterSeparatorSeed :: struct {
	active:             bool,
	water_level_blocks: f32,
}

TerrainWaterSeparatorSample :: struct {
	flooded:            bool,
	conflict_active:    bool,
	water_material_id:  world_async.BlockMaterialID,
	water_level_blocks: f32,
}

TerrainWaterSeparatorPaddingNeeds :: struct {
	left, right, top, bottom: bool,
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
	terrain_heightfield_voxel_view_fill_quality(view, chunk, seed, .Full)
}

terrain_heightfield_voxel_view_fill_quality :: proc(
	view: ^world_async.ChunkVoxelView,
	chunk: world_async.ChunkCoord,
	seed: u32,
	quality: world_async.ChunkGenerationQuality,
) {
	profile_total_start: time.Tick
	profile_stage_start: time.Tick
	when TERRAIN_GENERATION_PROFILE_PHASES {
		profile_total_start = time.tick_now()
		profile_stage_start = profile_total_start
	}
	when !TERRAIN_GENERATION_PROFILE_PHASES {
		_ = profile_total_start
		_ = profile_stage_start
	}
	log.assertf(
		len(view.blocks) == CHUNK_BLOCK_COUNT,
		"heightfield fill expects %d blocks, got %d",
		CHUNK_BLOCK_COUNT,
		len(view.blocks),
	)
	origin := chunk_origin_from_coord(chunk)
	key := terrain_generation_key_make(seed)
	if quality == .Full && terrain_generation_chunk_cache_try_read(view, key, chunk) {
		when TERRAIN_GENERATION_PROFILE_PHASES {
			terrain_generation_profile_stats.total += time.tick_since(profile_total_start)
			terrain_generation_profile_stats.chunk_count += 1
		}
		return
	}

	chunk_voxel_view_fill_empty(view)
	when TERRAIN_GENERATION_PROFILE_PHASES {
		terrain_generation_profile_stats.clear += time.tick_since(profile_stage_start)
		profile_stage_start = time.tick_now()
	}

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
	when TERRAIN_GENERATION_PROFILE_PHASES {
		terrain_generation_profile_stats.region += time.tick_since(profile_stage_start)
		profile_stage_start = time.tick_now()
	}
	profile_column_cache_start: time.Tick
	profile_base_fill_start: time.Tick
	when TERRAIN_GENERATION_PROFILE_PHASES {
		profile_column_cache_start = time.tick_now()
	}
	when !TERRAIN_GENERATION_PROFILE_PHASES {
		_ = profile_column_cache_start
		_ = profile_base_fill_start
	}

	column_targets: [CHUNK_BLOCK_LENGTH * CHUNK_BLOCK_LENGTH]TerrainBiomeColumn
	if !terrain_generation_column_cache_try_read(column_targets[:], key, chunk) {
		water_separator_samples: [CHUNK_BLOCK_LENGTH *
		CHUNK_BLOCK_LENGTH]TerrainWaterSeparatorSample
		for z in 0 ..< CHUNK_BLOCK_LENGTH {
			world_z := origin.z + i32(z)
			profile_row_cache := biomes.surface_biome_profile_row_cache_make(key, world_z)
			for x in 0 ..< CHUNK_BLOCK_LENGTH {
				world_x := origin.x + i32(x)
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
				evaluation := biomes.surface_biome_profile_evaluate_with_hydrology(
					key,
					surface_sample,
					hydrology_sample,
					world_x,
					world_z,
					&profile_row_cache,
				)
				evaluation = terrain_surface_morphology_apply_feature_envelopes(
					evaluation,
					generation_region.surface_morphology_features[:],
					generation_region.surface_morphology_feature_count,
					world_x,
					world_z,
				)
				column_index := x + z * CHUNK_BLOCK_LENGTH
				column := terrain_biome_column_from_profile_evaluation(
					key,
					evaluation,
					world_x,
					world_z,
				)
				column_targets[column_index] = column
				water_separator_samples[column_index] =
					terrain_water_separator_sample_from_column_and_hydrology(
						column,
						evaluation.hydrology_sample,
					)
			}
		}
		terrain_surface_water_separators_apply(
			key,
			&generation_region,
			origin,
			column_targets[:],
			water_separator_samples[:],
		)
		terrain_generation_column_cache_store(column_targets[:], key, chunk)
	}
	terrain_decoration_surface_structure_pads_apply(&generation_region, origin, column_targets[:])
	block_fill_done := false
	chunk_bottom_world_y := origin.y
	chunk_top_world_y := origin.y + CHUNK_BLOCK_LENGTH - 1
	surface_morphology_enabled := chunk_top_world_y >= 0
	surface_morphology_features: [biomes.GENERATION_REGION_SURFACE_MORPHOLOGY_FEATURE_CAPACITY]biomes.SurfaceMorphologyFeature
	surface_morphology_feature_count: u32
	if surface_morphology_enabled {
		chunk_bounds := biomes.BlockBounds3 {
				min = {x = origin.x, y = origin.y, z = origin.z},
				max = {
					x = origin.x + CHUNK_BLOCK_LENGTH,
					y = origin.y + CHUNK_BLOCK_LENGTH,
					z = origin.z + CHUNK_BLOCK_LENGTH,
				},
			}
		query := biomes.generation_region_query_make_default(chunk_bounds)
		surface_morphology_feature_count =
			biomes.generation_region_surface_morphology_features_write(
				&generation_region,
				query,
				surface_morphology_features[:],
			)
		when TERRAIN_GENERATION_PROFILE_PHASES {
			terrain_generation_profile_stats.surface_morphology_features += u64(
				surface_morphology_feature_count,
			)
		}
	}
	when TERRAIN_GENERATION_PROFILE_PHASES {
		terrain_generation_profile_stats.column_cache += time.tick_since(
			profile_column_cache_start,
		)
		profile_base_fill_start = time.tick_now()
		if surface_morphology_enabled {
			terrain_generation_profile_stats.surface_morphology_chunks += 1
		} else {
			terrain_generation_profile_stats.surface_heightfield_chunks += 1
		}
	}
	if !TERRAIN_BAKE_DEBUG_MATERIAL_FLAGS {
		all_deep_stone := true
		for i in 0 ..< CHUNK_BLOCK_LENGTH * CHUNK_BLOCK_LENGTH {
			column := column_targets[i]
			if surface_morphology_enabled {
				if !terrain_surface_density_column_is_deep_stone_chunk(column, chunk_top_world_y) {
					all_deep_stone = false
					break
				}
			} else {
				if !terrain_density_surface_is_solid(column, chunk_top_world_y) ||
				   column.surface_height - chunk_top_world_y <
					   column.surface_layer_depth + TERRAIN_DIRT_LAYER_BLOCK_DEPTH {
					all_deep_stone = false
					break
				}
			}
		}
		if all_deep_stone {
			mem.set(
				rawptr(view.blocks.occupancy),
				u8(world_async.BlockOccupancy.Solid),
				CHUNK_BLOCK_COUNT,
			)
			mem.set(
				rawptr(view.blocks.material_id),
				u8(world_async.BlockMaterialID(TERRAIN_STONE_MAT_ID)),
				CHUNK_BLOCK_COUNT,
			)
			block_fill_done = true
		}
	}
	if !block_fill_done {
		for z in 0 ..< CHUNK_BLOCK_LENGTH {
			for x in 0 ..< CHUNK_BLOCK_LENGTH {
				column := column_targets[x + z * CHUNK_BLOCK_LENGTH]
				cave_debug_material_active := false
				if TERRAIN_BAKE_DEBUG_MATERIAL_FLAGS {
					cave_debug_material_active = (cave_debug_columns[z] & (u64(1) << u32(x))) != 0
				}
				deep_stone_column := false
				if surface_morphology_enabled {
					deep_stone_column = terrain_surface_density_column_is_deep_stone_chunk(
						column,
						chunk_top_world_y,
					)
				} else {
					deep_stone_column =
						terrain_density_surface_is_solid(column, chunk_top_world_y) &&
						column.surface_height - chunk_top_world_y >=
							column.surface_layer_depth + TERRAIN_DIRT_LAYER_BLOCK_DEPTH
				}
				if deep_stone_column {
					material_id := world_async.BlockMaterialID(TERRAIN_STONE_MAT_ID)
					if TERRAIN_BAKE_DEBUG_MATERIAL_FLAGS {
						if column.hydrology_debug_material_active {
							material_id = terrain_hydrology_debug_material_id(material_id)
						}
						if cave_debug_material_active && !column.hydrology_debug_material_active {
							material_id = terrain_cave_anchor_debug_material_id(material_id)
						}
					}
					for y in 0 ..< CHUNK_BLOCK_LENGTH {
						index := chunk_block_index(u32(x), u32(y), u32(z))
						view.blocks.occupancy[index] = .Solid
						view.blocks.material_id[index] = material_id
					}
					continue
				}

				feature_plan := TerrainSurfaceMorphologyColumnFeaturePlan{}
				if surface_morphology_enabled {
					world_x := origin.x + i32(x)
					world_z := origin.z + i32(z)
					terrain_surface_morphology_column_feature_plan_write(
						surface_morphology_features[:],
						surface_morphology_feature_count,
						world_x,
						world_z,
						&feature_plan,
					)
					when TERRAIN_GENERATION_PROFILE_PHASES {
						if feature_plan.active {
							terrain_generation_profile_stats.surface_morphology_feature_columns += 1
						}
					}
					column_may_intersect := terrain_surface_density_column_may_intersect_chunk(
						column,
						chunk_bottom_world_y,
						chunk_top_world_y,
					)
					if feature_plan.active {
						column_may_intersect =
							column_may_intersect ||
							(f32(chunk_bottom_world_y) <=
										column.surface_height_blocks + feature_plan.band_above &&
									f32(chunk_top_world_y) >=
										column.surface_height_blocks - feature_plan.band_below)
					}
					if !column_may_intersect {
						continue
					}
				} else {
					if !terrain_density_surface_is_solid(column, chunk_bottom_world_y) {
						continue
					}
				}

				if surface_morphology_enabled {
					world_x := origin.x + i32(x)
					world_z := origin.z + i32(z)
					surface_shape := terrain_surface_morphology_column_shape_make(
						key,
						column,
						world_x,
						world_z,
					)
					if surface_shape.strength <= 0.001 && !feature_plan.active {
						heightfield_top_y := math.min(
							CHUNK_BLOCK_LENGTH - 1,
							column.surface_height - origin.y,
						)
						if heightfield_top_y >= 0 {
							for y in 0 ..= heightfield_top_y {
								world_y := origin.y + i32(y)
								blocks_below_surface := column.surface_height - world_y
								material_id := terrain_biome_block_material_id(
									column,
									blocks_below_surface,
								)
								if TERRAIN_BAKE_DEBUG_MATERIAL_FLAGS {
									if column.hydrology_debug_material_active {
										material_id = terrain_hydrology_debug_material_id(
											material_id,
										)
									}
									if cave_debug_material_active &&
									   !column.hydrology_debug_material_active {
										material_id = terrain_cave_anchor_debug_material_id(
											material_id,
										)
									}
								}

								index := chunk_block_index(u32(x), u32(y), u32(z))
								view.blocks.occupancy[index] = .Solid
								view.blocks.material_id[index] = material_id
							}
						}
						continue
					}

					sample_above := surface_shape.band_above
					if feature_plan.active {
						sample_above = math.max(sample_above, feature_plan.band_above)
					}
					sample_below := f32(0)
					if feature_plan.active {
						sample_below = feature_plan.band_below
					}
					sample_min_world_y := i32(
						math.floor_f32(column.surface_height_blocks - sample_below),
					)
					sample_max_world_y := i32(
						math.floor_f32(column.surface_height_blocks + sample_above),
					)
					prefill_top_y := math.min(
						CHUNK_BLOCK_LENGTH - 1,
						sample_min_world_y - origin.y - 1,
					)
					heightfield_top_y := math.min(
						CHUNK_BLOCK_LENGTH - 1,
						column.surface_height - origin.y,
					)
					if !feature_plan.active {
						prefill_top_y = heightfield_top_y
					}
					if prefill_top_y >= 0 {
						for y in 0 ..= prefill_top_y {
							world_y := origin.y + i32(y)
							blocks_below_surface := column.surface_height - world_y
							material_id := terrain_biome_block_material_id(
								column,
								blocks_below_surface,
							)
							if TERRAIN_BAKE_DEBUG_MATERIAL_FLAGS {
								if column.hydrology_debug_material_active {
									material_id = terrain_hydrology_debug_material_id(material_id)
								}
								if cave_debug_material_active &&
								   !column.hydrology_debug_material_active {
									material_id = terrain_cave_anchor_debug_material_id(
										material_id,
									)
								}
							}

							index := chunk_block_index(u32(x), u32(y), u32(z))
							view.blocks.occupancy[index] = .Solid
							view.blocks.material_id[index] = material_id
						}
					}

					sample_min_y := math.clamp(prefill_top_y + 1, 0, CHUNK_BLOCK_LENGTH)
					sample_max_y := math.clamp(
						sample_max_world_y - origin.y,
						-1,
						CHUNK_BLOCK_LENGTH - 1,
					)
					if sample_min_y <= sample_max_y {
						for y := sample_min_y; y <= sample_max_y; y += 1 {
							world_y := origin.y + i32(y)
							density := terrain_surface_density_sample_with_feature_plan(
								column,
								surface_shape,
								&feature_plan,
								world_x,
								world_y,
								world_z,
							)
							if density < 0 {
								continue
							}

							blocks_below_surface := column.surface_height - world_y
							material_id := terrain_biome_block_material_id(
								column,
								blocks_below_surface,
							)
							if TERRAIN_BAKE_DEBUG_MATERIAL_FLAGS {
								if column.hydrology_debug_material_active {
									material_id = terrain_hydrology_debug_material_id(material_id)
								}
								if cave_debug_material_active &&
								   !column.hydrology_debug_material_active {
									material_id = terrain_cave_anchor_debug_material_id(
										material_id,
									)
								}
							}

							index := chunk_block_index(u32(x), u32(y), u32(z))
							view.blocks.occupancy[index] = .Solid
							view.blocks.material_id[index] = material_id
						}
					}
					continue
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
						if cave_debug_material_active && !column.hydrology_debug_material_active {
							material_id = terrain_cave_anchor_debug_material_id(material_id)
						}
					}

					index := chunk_block_index(u32(x), u32(y), u32(z))
					view.blocks.occupancy[index] = .Solid
					view.blocks.material_id[index] = material_id
				}
			}
		}
	}
	when TERRAIN_GENERATION_PROFILE_PHASES {
		terrain_generation_profile_stats.base_fill += time.tick_since(profile_base_fill_start)
		terrain_generation_profile_stats.columns += time.tick_since(profile_stage_start)
		profile_stage_start = time.tick_now()
	}
	if quality == .Proxy {
		terrain_density_cave_proxy_anchors_apply(
			view,
			&generation_region,
			origin,
			column_targets[:],
		)
		when TERRAIN_GENERATION_PROFILE_PHASES {
			terrain_generation_profile_stats.cave_network += time.tick_since(profile_stage_start)
			profile_stage_start = time.tick_now()
		}
		terrain_water_volume_fill(view, origin, column_targets[:])
		when TERRAIN_GENERATION_PROFILE_PHASES {
			terrain_generation_profile_stats.water += time.tick_since(profile_stage_start)
			terrain_generation_profile_stats.total += time.tick_since(profile_total_start)
			terrain_generation_profile_stats.chunk_count += 1
		}
		return
	}

	if terrain_generation_cave_overlay_cache_try_apply(view, key, chunk) {
		when TERRAIN_GENERATION_PROFILE_PHASES {
			terrain_generation_profile_stats.cave_network += time.tick_since(profile_stage_start)
			profile_stage_start = time.tick_now()
		}
	} else {
		overlay_capture := terrain_generation_cave_overlay_cache_capture_enabled()
		overlay_base: ^TerrainCaveChunkOverlayBaseSnapshot
		overlay_scratch_allocator := runtime.heap_allocator()
		if overlay_capture {
			overlay_base = new(TerrainCaveChunkOverlayBaseSnapshot, overlay_scratch_allocator)
			terrain_cave_chunk_overlay_base_snapshot_capture(overlay_base, view)
		}

		terrain_density_subterranean_biome_caves_apply(
			view,
			&generation_region,
			origin,
			column_targets[:],
		)
		when TERRAIN_GENERATION_PROFILE_PHASES {
			terrain_generation_profile_stats.cave_field += time.tick_since(profile_stage_start)
			profile_stage_start = time.tick_now()
		}
		terrain_density_cave_network_apply(view, &generation_region, origin, column_targets[:])
		if overlay_capture {
			terrain_generation_cave_overlay_cache_store_from_base(view, key, chunk, overlay_base)
			_ = mem.free(rawptr(overlay_base), overlay_scratch_allocator)
			overlay_base = nil
		}
		when TERRAIN_GENERATION_PROFILE_PHASES {
			terrain_generation_profile_stats.cave_network += time.tick_since(profile_stage_start)
			profile_stage_start = time.tick_now()
		}
	}
	terrain_water_volume_fill(view, origin, column_targets[:])
	when TERRAIN_GENERATION_PROFILE_PHASES {
		terrain_generation_profile_stats.water += time.tick_since(profile_stage_start)
		profile_stage_start = time.tick_now()
	}
	decoration_stats := terrain_decoration_pass_apply(
		view,
		&generation_region,
		origin,
		column_targets[:],
	)
	when TERRAIN_GENERATION_PROFILE_PHASES {
		terrain_generation_profile_stats.decoration += time.tick_since(profile_stage_start)
		terrain_generation_profile_stats.decoration_surface_candidates += u64(
			decoration_stats.surface_candidates,
		)
		terrain_generation_profile_stats.decoration_surface_accepted += u64(
			decoration_stats.surface_accepted,
		)
		terrain_generation_profile_stats.decoration_surface_tree_instances_attempted += u64(
			decoration_stats.surface_tree_instances_attempted,
		)
		terrain_generation_profile_stats.decoration_surface_tree_instances_accepted += u64(
			decoration_stats.surface_tree_instances_accepted,
		)
		terrain_generation_profile_stats.decoration_surface_tree_root_rejected += u64(
			decoration_stats.surface_tree_root_rejected,
		)
		terrain_generation_profile_stats.decoration_surface_tree_shape_rejected += u64(
			decoration_stats.surface_tree_shape_rejected,
		)
		terrain_generation_profile_stats.decoration_cave_candidates += u64(
			decoration_stats.cave_candidates,
		)
		terrain_generation_profile_stats.decoration_cave_accepted += u64(
			decoration_stats.cave_accepted,
		)
		terrain_generation_profile_stats.decoration_blocks_written += u64(
			decoration_stats.blocks_written,
		)
		for family_index := 0; family_index < biomes.DECORATION_FAMILY_COUNT; family_index += 1 {
			terrain_generation_profile_stats.decoration_family_candidates[family_index] += u64(
				decoration_stats.family_candidates[family_index],
			)
			terrain_generation_profile_stats.decoration_family_accepted[family_index] += u64(
				decoration_stats.family_accepted[family_index],
			)
			terrain_generation_profile_stats.decoration_family_blocks[family_index] += u64(
				decoration_stats.family_blocks[family_index],
			)
		}
	}
	when !TERRAIN_GENERATION_PROFILE_PHASES {
		_ = decoration_stats
	}
	terrain_generation_chunk_cache_store(view, key, chunk)
	when TERRAIN_GENERATION_PROFILE_PHASES {
		terrain_generation_profile_stats.total += time.tick_since(profile_total_start)
		terrain_generation_profile_stats.chunk_count += 1
	}
}

terrain_density_surface_is_solid :: proc(column: TerrainBiomeColumn, world_y: i32) -> bool {
	return column.surface_height_blocks - f32(world_y) >= 0
}

terrain_generation_region_contains_block_xz :: proc(
	region: ^biomes.GenerationRegion,
	world_x, world_z: i32,
) -> bool {
	return(
		world_x >= region.bounds.min.x &&
		world_x < region.bounds.max.x &&
		world_z >= region.bounds.min.z &&
		world_z < region.bounds.max.z \
	)
}

terrain_water_separator_column_sample :: proc(
	key: biomes.FeatureGridKey,
	region: ^biomes.GenerationRegion,
	world_x, world_z: i32,
	row_cache: ^biomes.SurfaceBiomeProfileRowCache = nil,
) -> (
	TerrainBiomeColumn,
	biomes.HydrologyLayerSurfaceSample,
) {
	if terrain_generation_region_contains_block_xz(region, world_x, world_z) {
		surface_sample := biomes.surface_biome_field_sample_from_region(region, world_x, world_z)
		hydrology_sample := biomes.hydrology_layer_surface_sample_from_region(
			region,
			world_x,
			world_z,
		)
		evaluation := biomes.surface_biome_profile_evaluate_with_hydrology(
			key,
			surface_sample,
			hydrology_sample,
			world_x,
			world_z,
			row_cache,
		)
		evaluation = terrain_surface_morphology_apply_feature_envelopes(
			evaluation,
			region.surface_morphology_features[:],
			region.surface_morphology_feature_count,
			world_x,
			world_z,
		)
		return terrain_biome_column_from_profile_evaluation(key, evaluation, world_x, world_z),
			hydrology_sample
	}

	surface_sample := biomes.surface_biome_field_sample(key, world_x, world_z)
	hydrology_sample := biomes.hydrology_layer_surface_sample(key, world_x, world_z)
	evaluation := biomes.surface_biome_profile_evaluate_with_hydrology(
		key,
		surface_sample,
		hydrology_sample,
		world_x,
		world_z,
		row_cache,
	)
	evaluation = terrain_surface_morphology_apply_feature_envelopes_direct(
		evaluation,
		key,
		world_x,
		world_z,
	)
	return terrain_biome_column_from_profile_evaluation(key, evaluation, world_x, world_z),
		hydrology_sample
}

terrain_water_separator_sample_from_column :: proc(
	column: TerrainBiomeColumn,
) -> TerrainWaterSeparatorSample {
	sample := TerrainWaterSeparatorSample {
		water_level_blocks = column.water_level_blocks,
	}
	if !terrain_water_column_is_flooded(column) {
		return sample
	}
	sample.flooded = true
	sample.water_material_id = terrain_water_material_id_for_biome(column.water_biome_id, false)
	return sample
}

terrain_surface_water_material_id_for_biome :: proc(
	biome_id: biomes.BiomeID,
) -> world_async.BlockMaterialID {
	return terrain_water_material_id_for_biome(biome_id, false)
}

terrain_surface_water_source_allowed_for_biome :: proc(
	biome_id, water_biome_id: biomes.BiomeID,
) -> bool {
	return(
		terrain_surface_water_material_id_for_biome(biome_id) ==
		terrain_surface_water_material_id_for_biome(water_biome_id) \
	)
}

terrain_water_separator_sample_apply_hydrology :: proc(
	sample: ^TerrainWaterSeparatorSample,
	column: TerrainBiomeColumn,
	hydrology_sample: biomes.HydrologyLayerSurfaceSample,
) {
	water_influence := math.max(
		hydrology_sample.basin_influence,
		hydrology_sample.channel_influence,
	)
	if water_influence > 0 {
		sample.water_level_blocks = math.max(
			sample.water_level_blocks,
			hydrology_sample.water_level_blocks,
		)
	}
	water_crosses_restricted_biome :=
		water_influence > TERRAIN_LOCAL_WATER_FILL_INFLUENCE_MIN &&
		column.surface_height_blocks < hydrology_sample.water_level_blocks &&
		!terrain_surface_water_source_allowed_for_biome(
				column.dominant_biome_id,
				hydrology_sample.water_biome_id,
			)
	if hydrology_sample.water_material_conflict_influence >=
		   TERRAIN_WATER_SEPARATOR_CONFLICT_INFLUENCE_MIN ||
	   water_crosses_restricted_biome {
		sample.conflict_active = true
	}
}

terrain_water_separator_sample_from_column_and_hydrology :: proc(
	column: TerrainBiomeColumn,
	hydrology_sample: biomes.HydrologyLayerSurfaceSample,
) -> TerrainWaterSeparatorSample {
	sample := terrain_water_separator_sample_from_column(column)
	terrain_water_separator_sample_apply_hydrology(&sample, column, hydrology_sample)
	return sample
}

terrain_water_separator_samples_conflict :: proc(a, b: TerrainWaterSeparatorSample) -> bool {
	return a.flooded && b.flooded && a.water_material_id != b.water_material_id
}

terrain_water_separator_sample_can_conflict :: proc(sample: TerrainWaterSeparatorSample) -> bool {
	return sample.flooded || sample.conflict_active
}

terrain_water_separator_padding_needs_from_samples :: proc(
	samples: []TerrainWaterSeparatorSample,
	radius: i32,
) -> TerrainWaterSeparatorPaddingNeeds {
	log.assertf(
		len(samples) == CHUNK_BLOCK_LENGTH * CHUNK_BLOCK_LENGTH,
		"terrain water separator sample count mismatch: %d",
		len(samples),
	)
	needs := TerrainWaterSeparatorPaddingNeeds{}
	for z := i32(0); z < CHUNK_BLOCK_LENGTH; z += 1 {
		for x := i32(0); x < CHUNK_BLOCK_LENGTH; x += 1 {
			sample := samples[x + z * CHUNK_BLOCK_LENGTH]
			if !terrain_water_separator_sample_can_conflict(sample) {
				continue
			}
			if x < radius {
				needs.left = true
			}
			if x >= CHUNK_BLOCK_LENGTH - radius {
				needs.right = true
			}
			if z < radius {
				needs.top = true
			}
			if z >= CHUNK_BLOCK_LENGTH - radius {
				needs.bottom = true
			}
		}
	}
	return needs
}

terrain_water_separator_noise_01 :: proc(
	key: biomes.FeatureGridKey,
	world_x, world_z: i32,
	cell_blocks: i32,
	salt: u64,
) -> f32 {
	noise := biomes.regional_terrain_field_value_noise_2(key, world_x, world_z, cell_blocks, salt)
	return math.clamp(noise * 0.5 + 0.5, f32(0), f32(1))
}

terrain_water_separator_column_materials_apply :: proc(
	key: biomes.FeatureGridKey,
	column: ^TerrainBiomeColumn,
	world_x, world_z: i32,
) {
	material_biome_id := column.dominant_biome_id
	column.surface_material_id = terrain_biome_surface_material_id(material_biome_id)
	column.surface_material_id = terrain_material_apply_surface_color_variant(
		key,
		column.surface_material_id,
		material_biome_id,
		world_x,
		world_z,
		0,
	)
	column.subsurface_material_id = terrain_biome_subsurface_material_id(material_biome_id)
	column.subsurface_material_id = terrain_material_apply_surface_color_variant(
		key,
		column.subsurface_material_id,
		material_biome_id,
		world_x,
		world_z,
		1,
	)
}

terrain_surface_water_separators_apply :: proc(
	key: biomes.FeatureGridKey,
	region: ^biomes.GenerationRegion,
	chunk_origin: world_async.BlockCoord,
	columns: []TerrainBiomeColumn,
	column_samples: []TerrainWaterSeparatorSample,
) {
	log.assertf(
		len(columns) == CHUNK_BLOCK_LENGTH * CHUNK_BLOCK_LENGTH,
		"terrain water separator column target count mismatch: %d",
		len(columns),
	)
	log.assertf(
		len(column_samples) == CHUNK_BLOCK_LENGTH * CHUNK_BLOCK_LENGTH,
		"terrain water separator sample count mismatch: %d",
		len(column_samples),
	)

	pad := i32(TERRAIN_WATER_SEPARATOR_PADDING_BLOCKS)
	radius := i32(TERRAIN_WATER_SEPARATOR_RADIUS_BLOCKS)
	grid_length := i32(TERRAIN_WATER_SEPARATOR_GRID_LENGTH)
	padding_needs := terrain_water_separator_padding_needs_from_samples(column_samples, radius)
	padded_samples: [TERRAIN_WATER_SEPARATOR_GRID_COUNT]TerrainWaterSeparatorSample
	seeds: [TERRAIN_WATER_SEPARATOR_GRID_COUNT]TerrainWaterSeparatorSeed

	for pz := i32(0); pz < grid_length; pz += 1 {
		world_z := chunk_origin.z + pz - pad
		profile_row_cache := biomes.surface_biome_profile_row_cache_make(key, world_z)
		for px := i32(0); px < grid_length; px += 1 {
			world_x := chunk_origin.x + px - pad
			grid_index := px + pz * grid_length
			local_x := px - pad
			local_z := pz - pad
			if local_x >= 0 &&
			   local_z >= 0 &&
			   local_x < CHUNK_BLOCK_LENGTH &&
			   local_z < CHUNK_BLOCK_LENGTH {
				padded_samples[grid_index] = column_samples[local_x + local_z * CHUNK_BLOCK_LENGTH]
			} else {
				padding_needed :=
					(local_x < 0 && padding_needs.left) ||
					(local_x >= CHUNK_BLOCK_LENGTH && padding_needs.right) ||
					(local_z < 0 && padding_needs.top) ||
					(local_z >= CHUNK_BLOCK_LENGTH && padding_needs.bottom)
				if !padding_needed {
					continue
				}
				column, hydrology_sample := terrain_water_separator_column_sample(
					key,
					region,
					world_x,
					world_z,
					&profile_row_cache,
				)
				padded_samples[grid_index] =
					terrain_water_separator_sample_from_column_and_hydrology(
						column,
						hydrology_sample,
					)
			}
		}
	}

	for pz := i32(1); pz < grid_length - 1; pz += 1 {
		for px := i32(1); px < grid_length - 1; px += 1 {
			grid_index := px + pz * grid_length
			sample := padded_samples[grid_index]
			if sample.conflict_active {
				seed := &seeds[grid_index]
				seed.active = true
				seed.water_level_blocks = math.max(
					seed.water_level_blocks,
					sample.water_level_blocks,
				)
			}
			neighbor_offsets := [?]world_async.BlockCoord {
				{x = 1, y = 0, z = 0},
				{x = -1, y = 0, z = 0},
				{x = 0, y = 0, z = 1},
				{x = 0, y = 0, z = -1},
			}
			for offset in neighbor_offsets {
				neighbor_index := px + offset.x + (pz + offset.z) * grid_length
				neighbor := padded_samples[neighbor_index]
				if !terrain_water_separator_samples_conflict(sample, neighbor) {
					continue
				}
				seed := &seeds[grid_index]
				seed.active = true
				seed.water_level_blocks = math.max(
					seed.water_level_blocks,
					math.max(sample.water_level_blocks, neighbor.water_level_blocks),
				)
			}
		}
	}

	for z := i32(0); z < CHUNK_BLOCK_LENGTH; z += 1 {
		world_z := chunk_origin.z + z
		for x := i32(0); x < CHUNK_BLOCK_LENGTH; x += 1 {
			world_x := chunk_origin.x + x
			column_index := x + z * CHUNK_BLOCK_LENGTH
			column := &columns[column_index]
			center_px := x + pad
			center_pz := z + pad
			nearest_distance := f32(radius + 1)
			separator_water_level := f32(0)
			found_separator := false

			for dz := -radius; dz <= radius; dz += 1 {
				for dx := -radius; dx <= radius; dx += 1 {
					distance_sq := dx * dx + dz * dz
					if distance_sq > radius * radius {
						continue
					}
					seed_index := center_px + dx + (center_pz + dz) * grid_length
					seed := seeds[seed_index]
					if !seed.active {
						continue
					}
					distance := math.sqrt_f32(f32(distance_sq))
					if distance < nearest_distance {
						nearest_distance = distance
					}
					separator_water_level = math.max(
						separator_water_level,
						seed.water_level_blocks,
					)
					found_separator = true
				}
			}

			if !found_separator {
				continue
			}
			separator_eligible :=
				terrain_water_column_is_flooded(column^) ||
				column_samples[column_index].conflict_active ||
				column.surface_height_blocks < separator_water_level
			if !separator_eligible {
				continue
			}

			width_noise := terrain_water_separator_noise_01(
				key,
				world_x,
				world_z,
				TERRAIN_WATER_SEPARATOR_NOISE_CELL_BLOCKS,
				TERRAIN_WATER_SEPARATOR_WIDTH_NOISE_SALT,
			)
			effective_radius := f32(radius - 2) + width_noise * 2.0
			if nearest_distance > effective_radius {
				continue
			}
			edge_start := math.max(f32(1), effective_radius - 3.0)
			strength := f32(1.0) - math.smoothstep(edge_start, effective_radius, nearest_distance)
			if strength <= 0 {
				continue
			}

			height_noise := terrain_water_separator_noise_01(
				key,
				world_x,
				world_z,
				TERRAIN_WATER_SEPARATOR_NOISE_CELL_BLOCKS,
				TERRAIN_WATER_SEPARATOR_HEIGHT_NOISE_SALT,
			)
			target_height :=
				separator_water_level +
				TERRAIN_WATER_SEPARATOR_MIN_RISE_BLOCKS +
				TERRAIN_WATER_SEPARATOR_RISE_VARIATION_BLOCKS * height_noise

			if column.surface_height_blocks < target_height {
				column.surface_height_blocks = biomes.regional_terrain_field_lerp(
					column.surface_height_blocks,
					target_height,
					strength,
				)
				column.surface_height = i32(math.floor_f32(column.surface_height_blocks))
			}
			column.surface_morphology_profile.strength *= 1.0 - strength * 0.35
			if column.surface_height_blocks >= column.water_level_blocks {
				column.water_fill_active = false
				column.hydrology_debug_material_active = false
			}
			terrain_water_separator_column_materials_apply(key, column, world_x, world_z)
		}
	}
}

terrain_biome_column_sample :: proc(
	key: biomes.FeatureGridKey,
	surface_sample: biomes.SurfaceBiomeFieldSample,
	world_x, world_z: i32,
) -> TerrainBiomeColumn {
	hydrology_sample := biomes.hydrology_layer_surface_sample(key, world_x, world_z)
	return terrain_biome_column_sample_with_hydrology(
		key,
		surface_sample,
		hydrology_sample,
		world_x,
		world_z,
	)
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
	evaluation = terrain_surface_morphology_apply_feature_envelopes_direct(
		evaluation,
		key,
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
	water_source_conflict :=
		evaluation.hydrology_sample.water_material_conflict_influence >= 0.35 &&
		evaluation.hydrology_sample.water_material_conflict_influence >= water_influence * 0.58
	local_water_allowed := terrain_surface_water_source_allowed_for_biome(
		target.biome_id,
		evaluation.hydrology_sample.water_biome_id,
	)
	local_water_fill_active :=
		water_influence > TERRAIN_LOCAL_WATER_FILL_INFLUENCE_MIN &&
		water_surface_below_level &&
		!water_source_conflict &&
		local_water_allowed
	water_level := biomes.SEA_LEVEL_BLOCKS
	water_biome_id := target.biome_id
	if local_water_fill_active {
		water_level = math.max(biomes.SEA_LEVEL_BLOCKS, local_water_level)
		water_biome_id = evaluation.hydrology_sample.water_biome_id
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
	surface_material_id = terrain_material_apply_surface_color_variant(
		key,
		surface_material_id,
		material_biome_id,
		world_x,
		world_z,
		0,
	)
	subsurface_material_id := terrain_biome_subsurface_material_id(material_biome_id)
	subsurface_material_id = terrain_subsurface_material_apply_shoreline(
		evaluation,
		subsurface_material_id,
		surface_height_blocks,
		water_level,
	)
	if terrain_material_palette_index(surface_material_id) == TERRAIN_WET_MARSH_MAT_ID {
		subsurface_material_id = surface_material_id
	}
	subsurface_material_id = terrain_material_apply_surface_color_variant(
		key,
		subsurface_material_id,
		material_biome_id,
		world_x,
		world_z,
		1,
	)
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
		surface_morphology_profile = target.surface_morphology_profile,
		surface_material_id = surface_material_id,
		subsurface_material_id = subsurface_material_id,
		hydrology_debug_material_active = local_water_fill_active,
		water_fill_active = sea_fill_active || local_water_fill_active,
		water_biome_id = water_biome_id,
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

	blend_noise_scale :=
		TERRAIN_SURFACE_MATERIAL_BLEND_NOISE_AMPLITUDE *
		math.clamp(evaluation.transition_strength, f32(0), f32(1))
	selected_biome_id := evaluation.final_target.biome_id
	selected_score := f32(-2)

	for i := u32(0); i < evaluation.cell_count; i += 1 {
		biome_id := evaluation.targets[i].biome_id
		already_scored := false
		for j := u32(0); j < i; j += 1 {
			if evaluation.targets[j].biome_id == biome_id {
				already_scored = true
				break
			}
		}
		if already_scored {
			continue
		}

		weight := f32(0)
		for j := i; j < evaluation.cell_count; j += 1 {
			if evaluation.targets[j].biome_id == biome_id {
				weight += evaluation.blend_weights[j]
			}
		}
		if weight <= 0.001 {
			continue
		}

		material_salt := biomes.feature_grid_hash_combine(
			TERRAIN_SURFACE_MATERIAL_BLEND_SALT,
			u64(biome_id),
		)
		coherent_bias :=
			biomes.regional_terrain_field_value_noise_2(
				key,
				world_x,
				world_z,
				TERRAIN_SURFACE_MATERIAL_BLEND_CELL_BLOCKS,
				material_salt,
			) *
			blend_noise_scale
		score := weight + coherent_bias
		if score > selected_score {
			selected_score = score
			selected_biome_id = biome_id
		}
	}
	return selected_biome_id
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

terrain_material_id_with_color_variant :: proc(
	material_id: world_async.BlockMaterialID,
	variant_index: u32,
) -> world_async.BlockMaterialID {
	variant :=
		(variant_index & (TERRAIN_MATERIAL_COLOR_VARIANT_COUNT - 1)) <<
		u32(TERRAIN_MATERIAL_COLOR_VARIANT_SHIFT)
	base_and_debug := u8(material_id) & ~TERRAIN_MATERIAL_COLOR_VARIANT_MASK
	return world_async.BlockMaterialID(base_and_debug | u8(variant))
}

terrain_material_color_variant_from_noise :: proc(
	key: biomes.FeatureGridKey,
	world_x, world_z: i32,
	salt: u64,
) -> u32 {
	noise := biomes.regional_terrain_field_value_noise_2(
		key,
		world_x,
		world_z,
		TERRAIN_SURFACE_MATERIAL_BLEND_CELL_BLOCKS,
		salt,
	)
	value := math.clamp(noise * 0.5 + 0.5, f32(0), f32(0.999))
	return u32(math.floor_f32(value * f32(TERRAIN_MATERIAL_COLOR_VARIANT_COUNT)))
}

terrain_material_apply_surface_color_variant :: proc(
	key: biomes.FeatureGridKey,
	material_id: world_async.BlockMaterialID,
	biome_id: biomes.BiomeID,
	world_x, world_z: i32,
	layer_index: u32,
) -> world_async.BlockMaterialID {
	palette := terrain_material_palette_index(material_id)
	salt := biomes.feature_grid_hash_combine(
		TERRAIN_SURFACE_MATERIAL_BLEND_SALT,
		u64(biome_id) + u64(layer_index) * 31,
	)
	noise_variant := terrain_material_color_variant_from_noise(key, world_x, world_z, salt)
	variant := noise_variant
	switch palette {
	case TERRAIN_GRASS_MAT_ID:
		#partial switch biome_id {
		case .Old_Growth_Forest:
			variant = 1
		case .Wet_Lowland_Marsh, .Corrupted_Fen:
			variant = 1 + noise_variant % 2
		case .Temperate_Hills:
			variant = noise_variant
		}
	case TERRAIN_DIRT_MAT_ID:
		if biome_id == .Old_Growth_Forest {
			variant = 3
		} else if biome_id == .Wet_Lowland_Marsh || biome_id == .Corrupted_Fen {
			variant = 1
		}
	case TERRAIN_STONE_MAT_ID:
		if biome_id == .Basalt_Spire_Highlands {
			variant = 1 + noise_variant % 2
		} else if biome_id == .Emberglass_Badlands {
			variant = 2 + noise_variant % 2
		}
	case TERRAIN_WET_MARSH_MAT_ID:
		if biome_id == .Corrupted_Fen {
			variant = 2
		} else if biome_id == .Emberglass_Badlands {
			variant = 3
		} else {
			variant = 1
		}
	case TERRAIN_CORRUPTED_ASH_MAT_ID:
		if biome_id == .Emberglass_Badlands {
			variant = 3
		} else if biome_id == .Corrupted_Fen {
			variant = 2
		}
	case TERRAIN_AQUIFER_WALL_MAT_ID:
		if biome_id == .Old_Growth_Forest || biome_id == .Wet_Lowland_Marsh {
			variant = 1
		}
	case TERRAIN_CRYSTAL_MAT_ID:
		variant = noise_variant
	case:
	}
	return terrain_material_id_with_color_variant(material_id, variant)
}

terrain_water_material_id_for_biome :: proc(
	biome_id: biomes.BiomeID,
	subterranean: bool,
) -> world_async.BlockMaterialID {
	_ = subterranean
	switch biome_id {
	case .Wet_Lowland_Marsh, .Fungal_Vaults:
		return terrain_block_material_id_from_biome_material(.Swamp_Water)
	case .Corrupted_Ash_Forest, .Corrupted_Fen:
		return terrain_block_material_id_from_biome_material(.Corrupted_Water)
	case .Basalt_Spire_Highlands, .Emberglass_Badlands:
		return terrain_block_material_id_from_biome_material(.Lava)
	case .Buried_Aquifer_Caves:
		return terrain_block_material_id_from_biome_material(.Swamp_Water)
	case .Crystal_Geode_Network:
		return terrain_material_id_with_color_variant(
			world_async.BlockMaterialID(TERRAIN_WATER_MAT_ID),
			2,
		)
	case .Temperate_Hills, .Old_Growth_Forest:
		return world_async.BlockMaterialID(TERRAIN_WATER_MAT_ID)
	}
	return world_async.BlockMaterialID(TERRAIN_WATER_MAT_ID)
}

when TERRAIN_BAKE_DEBUG_MATERIAL_FLAGS {
	terrain_decoration_debug_material_id :: proc(
		material_id: world_async.BlockMaterialID,
	) -> world_async.BlockMaterialID {
		return world_async.BlockMaterialID(
			u8(material_id) | TERRAIN_DECORATION_DEBUG_MATERIAL_FLAG,
		)
	}
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

terrain_block_material_id_from_biome_material :: proc(
	material_id: biomes.BiomeMaterialID,
) -> world_async.BlockMaterialID {
	switch material_id {
	case .Grass:
		return world_async.BlockMaterialID(TERRAIN_GRASS_MAT_ID)
	case .Moss:
		return terrain_material_id_with_color_variant(
			world_async.BlockMaterialID(TERRAIN_GRASS_MAT_ID),
			1,
		)
	case .Dirt:
		return world_async.BlockMaterialID(TERRAIN_DIRT_MAT_ID)
	case .Forest_Litter:
		return terrain_material_id_with_color_variant(
			world_async.BlockMaterialID(TERRAIN_DIRT_MAT_ID),
			3,
		)
	case .Stone:
		return world_async.BlockMaterialID(TERRAIN_STONE_MAT_ID)
	case .Basalt:
		return terrain_material_id_with_color_variant(
			world_async.BlockMaterialID(TERRAIN_STONE_MAT_ID),
			1,
		)
	case .Wet_Marsh:
		return world_async.BlockMaterialID(TERRAIN_WET_MARSH_MAT_ID)
	case .Water:
		return world_async.BlockMaterialID(TERRAIN_WATER_MAT_ID)
	case .Swamp_Water:
		return terrain_material_id_with_color_variant(
			world_async.BlockMaterialID(TERRAIN_WATER_MAT_ID),
			1,
		)
	case .Corrupted_Water:
		return terrain_material_id_with_color_variant(
			world_async.BlockMaterialID(TERRAIN_WATER_MAT_ID),
			2,
		)
	case .Lava:
		return terrain_material_id_with_color_variant(
			world_async.BlockMaterialID(TERRAIN_WATER_MAT_ID),
			3,
		)
	case .Corrupted_Ash:
		return world_async.BlockMaterialID(TERRAIN_CORRUPTED_ASH_MAT_ID)
	case .Corrupt_Mud:
		return terrain_material_id_with_color_variant(
			world_async.BlockMaterialID(TERRAIN_CORRUPTED_ASH_MAT_ID),
			2,
		)
	case .Ember_Ash:
		return terrain_material_id_with_color_variant(
			world_async.BlockMaterialID(TERRAIN_CORRUPTED_ASH_MAT_ID),
			3,
		)
	case .Aquifer_Wall:
		return world_async.BlockMaterialID(TERRAIN_AQUIFER_WALL_MAT_ID)
	case .Crystal:
		return world_async.BlockMaterialID(TERRAIN_CRYSTAL_MAT_ID)
	}

	log.assertf(false, "unhandled Biome Material ID: %v", material_id)
	return world_async.BlockMaterialID(TERRAIN_STONE_MAT_ID)
}

terrain_biome_surface_material_id :: proc(
	biome_id: biomes.BiomeID,
) -> world_async.BlockMaterialID {
	switch biome_id {
	case .Fungal_Vaults, .Crystal_Geode_Network, .Buried_Aquifer_Caves:
		log.assert(false, "surface terrain fill received subterranean biome identity")
		return world_async.BlockMaterialID(TERRAIN_STONE_MAT_ID)
	case .Temperate_Hills,
	     .Old_Growth_Forest,
	     .Basalt_Spire_Highlands,
	     .Emberglass_Badlands,
	     .Wet_Lowland_Marsh,
	     .Corrupted_Ash_Forest,
	     .Corrupted_Fen:
		profile := biomes.biome_material_profile_for(biome_id)
		return terrain_block_material_id_from_biome_material(profile.surface)
	}

	log.assertf(false, "unhandled terrain biome surface material: %v", biome_id)
	return world_async.BlockMaterialID(TERRAIN_STONE_MAT_ID)
}

terrain_biome_subsurface_material_id :: proc(
	biome_id: biomes.BiomeID,
) -> world_async.BlockMaterialID {
	switch biome_id {
	case .Fungal_Vaults, .Crystal_Geode_Network, .Buried_Aquifer_Caves:
		log.assert(false, "surface terrain fill received subterranean biome identity")
		return world_async.BlockMaterialID(TERRAIN_STONE_MAT_ID)
	case .Temperate_Hills,
	     .Old_Growth_Forest,
	     .Basalt_Spire_Highlands,
	     .Emberglass_Badlands,
	     .Wet_Lowland_Marsh,
	     .Corrupted_Ash_Forest,
	     .Corrupted_Fen:
		profile := biomes.biome_material_profile_for(biome_id)
		return terrain_block_material_id_from_biome_material(profile.subsurface)
	}

	log.assertf(false, "unhandled terrain biome subsurface material: %v", biome_id)
	return world_async.BlockMaterialID(TERRAIN_STONE_MAT_ID)
}
