package world

import world_async "async:world"
import "core:log"
import math "core:math"
import "core:mem"
import mem_tlsf "core:mem/tlsf"

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
// Storage Types
/////////////////////////////////////

ChunkStore :: struct {
	chunks:      []Chunk,
	chunk_count: u32,
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
	persistent_allocator:          mem.Allocator,
	chunk_block_storage_buffer:    []u8,
	chunk_block_storage_tlsf:      mem_tlsf.Allocator,
	chunk_block_storage_allocator: mem.Allocator,

	// Callbacks
	generation_request:            GenerationRequestProc,
	generation_poll_results:       GenerationPollResultsProc,
	mesh_request:                  MeshRequestProc,
	mesh_poll_results:             MeshPollResultsProc,
	mesh_release_result:           MeshReleaseResultProc,
	chunk_mesh_upload:             ChunkMeshUploadProc,
	chunk_geometry_release:        ChunkGeometryReleaseProc,

	// Storage
	chunk_store:                   ChunkStore,

	// Streaming
	using streaming:               StreamingState,

	// State
	initialized:                   bool,
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

//////////////////////////////////////
// Chunk Constants
/////////////////////////////////////

CHUNK_BLOCK_LENGTH :: 64
CHUNK_BLOCK_LENGTH_LOG2 :: 6
CHUNK_BLOCK_LOCAL_MAX :: CHUNK_BLOCK_LENGTH - 1
CHUNK_BLOCK_COUNT :: CHUNK_BLOCK_LENGTH * CHUNK_BLOCK_LENGTH * CHUNK_BLOCK_LENGTH
TERRAIN_BLOCK_WORLD_SIZE :: f32(0.5)
#assert(CHUNK_BLOCK_LENGTH == 1 << CHUNK_BLOCK_LENGTH_LOG2)
#assert(CHUNK_BLOCK_LOCAL_MAX <= 0x3F)

//////////////////////////////////////
// Chunk Debug Constants
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
// Storage Constants
/////////////////////////////////////

CHUNK_BLOCK_STORAGE_POOL_BYTES :: 48 * mem.Megabyte

//////////////////////////////////////
// Streaming Budget Constants
/////////////////////////////////////

CHUNK_GENERATION_BUDGET_PER_FRAME :: 1
CHUNK_MESH_BUDGET_PER_FRAME :: 2

//////////////////////////////////////
// Streaming Constants
/////////////////////////////////////

CHUNK_STREAMING_RADIUS_XZ :: 3
CHUNK_UNLOAD_RADIUS_XZ :: CHUNK_STREAMING_RADIUS_XZ + 1
CHUNK_STREAMING_TARGET_CAPACITY ::
	(CHUNK_STREAMING_RADIUS_XZ * 2 + 1) * (CHUNK_STREAMING_RADIUS_XZ * 2 + 1)
CHUNK_UNLOAD_CAPACITY :: (CHUNK_UNLOAD_RADIUS_XZ * 2 + 1) * (CHUNK_UNLOAD_RADIUS_XZ * 2 + 1)
#assert(CHUNK_UNLOAD_RADIUS_XZ >= CHUNK_STREAMING_RADIUS_XZ)

// Until chunk/geometry eviction exists, store capacity must stay within the fixed arenas.
CHUNK_STORE_CAPACITY :: 128
#assert(CHUNK_STREAMING_TARGET_CAPACITY > 0)
#assert(CHUNK_STORE_CAPACITY >= CHUNK_UNLOAD_CAPACITY)

//////////////////////////////////////
// Meshing Constants
/////////////////////////////////////

LOG_CHUNK_MESH_COMMITS :: #config(LOG_CHUNK_MESH_COMMITS, false)


//////////////////////////////////////
// Meshing Types
/////////////////////////////////////

ChunkMeshBatchStats :: struct {
	chunks_attempted: u32,
	chunks_committed: u32,
	chunks_uploaded:  u32,
	chunks_empty:     u32,
	chunks_stale:     u32,
	total_faces:      u32,
}

ChunkMeshFacePlan :: struct {
	face_masks:   []u8,
	face_offsets: []u32,
	face_count:   u32,
}

ChunkMeshSnapshotRefSet :: struct {
	coords: [7]world_async.ChunkCoord,
	count:  u32,
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
	generation_state:          ChunkGenerationState,
	mesh_state:                ChunkMeshState,
	dirty_flags:               ChunkDirtyFlags,
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
		generation_state = .Missing,
		mesh_state = .Missing,
		dirty_flags = {},
		slot_generation = 1,
		block_version = 0,
		mesh_version = 0,
	}
}

chunk_mark_generated :: proc(chunk: ^Chunk, block_storage: world_async.ChunkBlockStorage) {
	chunk.block_storage = block_storage
	chunk.generation_state = .Generated
	chunk.mesh_state = .Dirty
	chunk.dirty_flags = {.Blocks, .Boundary}
	chunk.block_version += 1
}

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
	chunk_voxel_view_fill_empty(voxel_view)
}

chunk_voxel_view_is_solid_local :: proc(view: world_async.ChunkVoxelView, x, y, z: u32) -> bool {
	return view.blocks.occupancy[chunk_block_index(x, y, z)] == .Solid
}


chunk_voxel_view_is_solid_for_meshing :: proc(
	view: world_async.ChunkVoxelView,
	x, y, z: i32,
	boundary_policy: world_async.ChunkMeshBoundaryPolicy,
	neighbor_snapshots: Maybe(world_async.ChunkMeshNeighborSnapshots) = nil,
) -> bool {
	if chunk_block_coord_is_inside(x, y, z) {
		return chunk_voxel_view_is_solid_local(view, u32(x), u32(y), u32(z))
	}

	#partial switch boundary_policy {
	case .Treat_Out_Of_Chunk_As_Empty:
		return false
	case .Sample_Neighbor_Snapshots:
		neighbors, ok := neighbor_snapshots.?
		log.assert(
			ok,
			"neighbors must be provided when boundary policy is Sample_Neighbor_Snapshots",
		)

		out_of_chunk_axis_count := 0
		if x < 0 || x >= CHUNK_BLOCK_LENGTH {out_of_chunk_axis_count += 1}
		if y < 0 || y >= CHUNK_BLOCK_LENGTH {out_of_chunk_axis_count += 1}
		if z < 0 || z >= CHUNK_BLOCK_LENGTH {out_of_chunk_axis_count += 1}
		log.assertf(
			out_of_chunk_axis_count == 1,
			"neighbor snapshot sampling expects exactly one out-of-chunk axis, got %d",
			out_of_chunk_axis_count,
		)

		neighbor: Maybe(world_async.ChunkSnapshot)
		neighbor_x, neighbor_y, neighbor_z := x, y, z

		if x < 0 {
			neighbor = neighbors.minus_x
			neighbor_x = CHUNK_BLOCK_LOCAL_MAX
		} else if x >= CHUNK_BLOCK_LENGTH {
			neighbor = neighbors.plus_x
			neighbor_x = 0
		} else if y < 0 {
			neighbor = neighbors.minus_y
			neighbor_y = CHUNK_BLOCK_LOCAL_MAX
		} else if y >= CHUNK_BLOCK_LENGTH {
			neighbor = neighbors.plus_y
			neighbor_y = 0
		} else if z < 0 {
			neighbor = neighbors.minus_z
			neighbor_z = CHUNK_BLOCK_LOCAL_MAX
		} else if z >= CHUNK_BLOCK_LENGTH {
			neighbor = neighbors.plus_z
			neighbor_z = 0
		}

		neighbor_snapshot, neighbor_ok := neighbor.?
		if !neighbor_ok {
			return false
		}

		return chunk_voxel_view_is_solid_local(
			neighbor_snapshot.voxel_view,
			u32(neighbor_x),
			u32(neighbor_y),
			u32(neighbor_z),
		)
	}

	log.assertf(false, "unhandled chunk mesher boundary policy: %v", boundary_policy)
	return false
}

chunk_voxel_view_material_id :: proc(
	view: world_async.ChunkVoxelView,
	x, y, z: u32,
) -> world_async.BlockMaterialID {
	return view.blocks.material_id[chunk_block_index(x, y, z)]
}

//////////////////////////////////////
// Meshing Methods
/////////////////////////////////////

chunk_voxel_view_exposed_face_mask :: proc(
	view: world_async.ChunkVoxelView,
	x, y, z: u32,
	boundary_policy: world_async.ChunkMeshBoundaryPolicy,
	neighbor_snapshots: Maybe(world_async.ChunkMeshNeighborSnapshots) = nil,
) -> u8 {
	if !chunk_voxel_view_is_solid_for_meshing(
		view,
		i32(x),
		i32(y),
		i32(z),
		boundary_policy,
		neighbor_snapshots,
	) {
		return 0
	}

	mask: u8
	for face, face_index in TERRAIN_FACE_DESCS {
		neighbor_x := i32(x) + face.neighbor_dx
		neighbor_y := i32(y) + face.neighbor_dy
		neighbor_z := i32(z) + face.neighbor_dz

		if !chunk_voxel_view_is_solid_for_meshing(
			view,
			neighbor_x,
			neighbor_y,
			neighbor_z,
			boundary_policy,
			neighbor_snapshots,
		) {
			mask |= TERRAIN_FACE_MASKS[face_index]
		}
	}
	return mask
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

chunk_voxel_debug_rect_view_builder :: proc(
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

chunk_voxel_view_count_exposed_faces :: proc(
	view: world_async.ChunkVoxelView,
	boundary_policy: world_async.ChunkMeshBoundaryPolicy,
	neighbor_snapshots: Maybe(world_async.ChunkMeshNeighborSnapshots) = nil,
) -> u32 {
	log.assertf(
		len(view.blocks) == CHUNK_BLOCK_COUNT,
		"chunk voxel view must have %d blocks",
		CHUNK_BLOCK_COUNT,
	)

	face_count: u32
	for z in 0 ..< CHUNK_BLOCK_LENGTH {
		for y in 0 ..< CHUNK_BLOCK_LENGTH {
			for x in 0 ..< CHUNK_BLOCK_LENGTH {
				mask := chunk_voxel_view_exposed_face_mask(
					view,
					u32(x),
					u32(y),
					u32(z),
					boundary_policy,
					neighbor_snapshots,
				)
				face_count += terrain_face_mask_count(mask)
			}
		}
	}

	return face_count
}

chunk_voxel_view_build_face_plan :: proc(
	view: world_async.ChunkVoxelView,
	boundary_policy: world_async.ChunkMeshBoundaryPolicy,
	allocator: mem.Allocator,
	neighbor_snapshots: Maybe(world_async.ChunkMeshNeighborSnapshots) = nil,
) -> ChunkMeshFacePlan {
	log.assertf(
		len(view.blocks) == CHUNK_BLOCK_COUNT,
		"chunk voxel view must have %d blocks",
		CHUNK_BLOCK_COUNT,
	)

	plan := ChunkMeshFacePlan {
		face_masks   = make([]u8, CHUNK_BLOCK_COUNT, allocator),
		face_offsets = make([]u32, CHUNK_BLOCK_COUNT + 1, allocator),
	}
	log.assertf(len(plan.face_masks) == CHUNK_BLOCK_COUNT, "chunk face mask allocation failed")
	log.assertf(
		len(plan.face_offsets) == CHUNK_BLOCK_COUNT + 1,
		"chunk face offset allocation failed",
	)

	face_count: u32
	for z in 0 ..< CHUNK_BLOCK_LENGTH {
		for y in 0 ..< CHUNK_BLOCK_LENGTH {
			for x in 0 ..< CHUNK_BLOCK_LENGTH {
				block_index := chunk_block_index(u32(x), u32(y), u32(z))
				plan.face_offsets[block_index] = face_count

				mask := chunk_voxel_view_exposed_face_mask(
					view,
					u32(x),
					u32(y),
					u32(z),
					boundary_policy,
					neighbor_snapshots,
				)
				plan.face_masks[block_index] = mask
				face_count += terrain_face_mask_count(mask)
			}
		}
	}

	plan.face_offsets[CHUNK_BLOCK_COUNT] = face_count
	plan.face_count = face_count
	return plan
}

chunk_voxel_view_build_naive_mesh :: proc(
	view: world_async.ChunkVoxelView,
	boundary_policy: world_async.ChunkMeshBoundaryPolicy,
	allocator: mem.Allocator,
	neighbor_snapshots: Maybe(world_async.ChunkMeshNeighborSnapshots) = nil,
) -> world_async.ChunkMeshOutput {
	face_plan := chunk_voxel_view_build_face_plan(
		view,
		boundary_policy,
		allocator,
		neighbor_snapshots,
	)
	face_count := face_plan.face_count

	if face_count == 0 {
		return {}
	}

	log.assertf(
		face_count <= max(u32) / 4,
		"chunk mesh vertex count would overflow: %d faces",
		face_count,
	)
	log.assertf(
		face_count <= max(u32) / 6,
		"chunk mesh index count would overflow: %d faces",
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
		"chunk mesh vertex allocation failed: expected=%d got=%d faces=%d",
		expected_vertex_count,
		len(output.vertices),
		face_count,
	)
	log.assertf(
		len(output.indices) == expected_index_count,
		"chunk mesh index allocation failed: expected=%d got=%d faces=%d",
		expected_index_count,
		len(output.indices),
		face_count,
	)

	for z in 0 ..< CHUNK_BLOCK_LENGTH {
		for y in 0 ..< CHUNK_BLOCK_LENGTH {
			for x in 0 ..< CHUNK_BLOCK_LENGTH {
				block_index := chunk_block_index(u32(x), u32(y), u32(z))
				mask := face_plan.face_masks[block_index]
				if mask == 0 {
					continue
				}

				material_id := u32(u8(chunk_voxel_view_material_id(view, u32(x), u32(y), u32(z))))
				face_cursor := face_plan.face_offsets[block_index]

				for face, face_index in TERRAIN_FACE_DESCS {
					if (mask & TERRAIN_FACE_MASKS[face_index]) == 0 {
						continue
					}

					terrain_emit_face(
						output.vertices,
						output.indices,
						face_cursor,
						u32(x),
						u32(y),
						u32(z),
						face.normal_id,
						material_id,
					)
					face_cursor += 1
				}
				log.assertf(
					face_cursor == face_plan.face_offsets[block_index + 1],
					"chunk face plan offset mismatch: block_index=%d",
					block_index,
				)
			}
		}
	}

	return output
}

mesh_job_execute_sync :: proc(
	job: world_async.ChunkMeshJob,
	output_allocator: mem.Allocator,
) -> world_async.ChunkMeshOutput {
	log.assertf(
		len(job.snapshot.voxel_view.blocks) == CHUNK_BLOCK_COUNT,
		"chunk mesh job snapshot must have %d blocks, got %d",
		CHUNK_BLOCK_COUNT,
		len(job.snapshot.voxel_view.blocks),
	)

	return chunk_voxel_view_build_naive_mesh(
		job.snapshot.voxel_view,
		job.boundary_policy,
		output_allocator,
		job.neighbors,
	)
}

//////////////////////////////////////
// Storage Methods
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

	chunk_block_storage_release(&chunk.block_storage)
	chunk.generation_state = .Missing
	chunk.mesh_state = .Missing
	chunk.dirty_flags = {}
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

		result_is_stale :=
			chunk.generation_state != .Generated ||
			chunk.mesh_state != .Queued ||
			chunk.block_version != result.block_version ||
			chunk.dirty_flags != {}
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

chunk_store_get_or_append_reserved :: proc(coord: world_async.ChunkCoord) -> ChunkID {
	if index, ok := chunk_store_find_index_by_coord(coord).?; ok {
		return chunk_store_id_from_index(index)
	}

	return chunk_store_append_reserved(coord)
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
	return chunk_block_storage_alloc(state.chunk_block_storage_allocator)
}

chunk_block_storage_release :: proc(storage: ^world_async.ChunkBlockStorage) {
	if len(storage.voxel_view.blocks) == 0 {
		return
	}

	err := delete(storage.voxel_view.blocks, state.chunk_block_storage_allocator)
	log.assertf(err == nil, "chunk block storage release failed: %v", err)
	storage^ = {}
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
	return {
		coord = chunk.coord,
		voxel_view = chunk.block_storage.voxel_view,
		block_version = chunk.block_version,
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
	terrain_heightfield_voxel_view_fill(&block_storage.voxel_view, job.coord)
	return {coord = job.coord, block_storage = block_storage}
}

chunk_store_mark_generated_chunk_boundary_dirty :: proc(coord: world_async.ChunkCoord) {
	index, ok := chunk_store_find_index_by_coord(coord).?
	if !ok {
		return
	}

	chunk := chunk_store_get_by_index(index)
	if chunk.generation_state != .Generated {
		return
	}

	chunk.dirty_flags += {.Boundary}
	if chunk.mesh_state != .Queued {
		chunk.mesh_state = .Dirty
	}
}

chunk_store_mark_generated_neighbors_boundary_dirty :: proc(coord: world_async.ChunkCoord) {
	chunk_store_mark_generated_chunk_boundary_dirty(
		world_async.ChunkCoord{coord.x + 1, coord.y, coord.z},
	)
	chunk_store_mark_generated_chunk_boundary_dirty(
		world_async.ChunkCoord{coord.x - 1, coord.y, coord.z},
	)
	chunk_store_mark_generated_chunk_boundary_dirty(
		world_async.ChunkCoord{coord.x, coord.y + 1, coord.z},
	)
	chunk_store_mark_generated_chunk_boundary_dirty(
		world_async.ChunkCoord{coord.x, coord.y - 1, coord.z},
	)
	chunk_store_mark_generated_chunk_boundary_dirty(
		world_async.ChunkCoord{coord.x, coord.y, coord.z + 1},
	)
	chunk_store_mark_generated_chunk_boundary_dirty(
		world_async.ChunkCoord{coord.x, coord.y, coord.z - 1},
	)
}

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
		chunk_id := chunk_store_get_or_append_reserved(coord)
		chunk := chunk_store_get_by_id(chunk_id)

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
		if !streaming_mesh_dependencies_ready(chunk.coord) {
			continue
		}

		snapshot := chunk_snapshot_from_chunk(chunk)
		job := world_async.ChunkMeshJob {
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
		chunk.dirty_flags = {}
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
	stats.chunks_evicted = streaming_update_for_observer(observer_world_position)

	stats.chunks_generated = generation_results_poll_budgeted()
	generation_request_budgeted()

	mesh_stats := mesh_results_poll_budgeted()
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
// Debug Methods
/////////////////////////////////////

when ODIN_DEBUG {

	debug_chunk_mesher_contract_checks_run :: proc(transient_arena: ^mem.Arena) {
		temp := mem.begin_arena_temp_memory(transient_arena)
		defer mem.end_arena_temp_memory(temp)
		allocator := mem.arena_allocator(transient_arena)

		view := world_async.ChunkVoxelView {
			blocks = make(#soa[]world_async.ChunkVoxelViewElement, CHUNK_BLOCK_COUNT, allocator),
		}

		packed_fields := terrain_unpack_vertex(terrain_pack_vertex(2, 3, 4, 5, 6, 1))
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
		log.assertf(
			packed_fields.corner_id == 1,
			"terrain pack/unpack: expected corner 1, got %d",
			packed_fields.corner_id,
		)

		chunk_voxel_view_fill_empty(&view)
		empty_output := chunk_voxel_view_build_naive_mesh(
			view,
			.Treat_Out_Of_Chunk_As_Empty,
			allocator,
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

		edge_output := chunk_voxel_view_build_naive_mesh(
			view,
			.Treat_Out_Of_Chunk_As_Empty,
			allocator,
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


		output := chunk_voxel_view_build_naive_mesh(view, .Treat_Out_Of_Chunk_As_Empty, allocator)
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
		for face_index in 0 ..< 6 {
			expected_normal := expected_normals[face_index]
			for corner_id in 0 ..< 4 {
				corner_index := face_index * 4 + corner_id
				unpacked_vertex := terrain_unpack_vertex(output.vertices[corner_index])

				log.assertf(
					unpacked_vertex.block_x == 2,
					"single block vertex %d: expected block_x 2, got %d",
					corner_index,
					unpacked_vertex.block_x,
				)
				log.assertf(
					unpacked_vertex.block_y == 3,
					"single block vertex %d: expected block_y 3, got %d",
					corner_index,
					unpacked_vertex.block_y,
				)
				log.assertf(
					unpacked_vertex.block_z == 4,
					"single block vertex %d: expected block_z 4, got %d",
					corner_index,
					unpacked_vertex.block_z,
				)
				log.assertf(
					unpacked_vertex.normal_id == expected_normal,
					"single block vertex %d: expected normal %d, got %d",
					corner_index,
					expected_normal,
					unpacked_vertex.normal_id,
				)
				log.assertf(
					unpacked_vertex.material_id == 5,
					"single block vertex %d: expected material 5, got %d",
					corner_index,
					unpacked_vertex.material_id,
				)
				log.assertf(
					unpacked_vertex.corner_id == u32(corner_id),
					"single block vertex %d: expected corner %d, got %d",
					corner_index,
					corner_id,
					unpacked_vertex.corner_id,
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

		// adjacent X/Y/Z: each pair should remove one shared face from each block
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

			count := chunk_voxel_view_count_exposed_faces(view, .Treat_Out_Of_Chunk_As_Empty)
			log.assertf(
				count == 10,
				"adjacent pair %d: expected 10 faces, got %d",
				pair_index,
				count,
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
				snapshot = left_snapshot,
				neighbors = chunk_mesh_neighbors_find(
					neighbor_test_snapshots[:],
					left_snapshot.coord,
				),
				boundary_policy = .Sample_Neighbor_Snapshots,
			},
			allocator,
		)
		log.assertf(
			left_neighbor_output.face_count == 5,
			"left boundary block: expected 5 faces with +X neighbor, got %d",
			left_neighbor_output.face_count,
		)

		right_neighbor_output := mesh_job_execute_sync(
			{
				snapshot = right_snapshot,
				neighbors = chunk_mesh_neighbors_find(
					neighbor_test_snapshots[:],
					right_snapshot.coord,
				),
				boundary_policy = .Sample_Neighbor_Snapshots,
			},
			allocator,
		)
		log.assertf(
			right_neighbor_output.face_count == 5,
			"right boundary block: expected 5 faces with -X neighbor, got %d",
			right_neighbor_output.face_count,
		)

		// 2x2x2 solid cube: surface area is 6 * 2 * 2 = 24 faces.
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

		output = chunk_voxel_view_build_naive_mesh(view, .Treat_Out_Of_Chunk_As_Empty, allocator)
		log.assertf(output.face_count == 24, "2x2x2: expected 24 faces, got %d", output.face_count)
		log.assertf(
			len(output.vertices) == 96,
			"2x2x2: expected 96 vertices, got %d",
			len(output.vertices),
		)
		log.assertf(
			len(output.indices) == 144,
			"2x2x2: expected 144 indices, got %d",
			len(output.indices),
		)

		// current rectangular debug fixture: 16 x 8 x 16 => 2*(16*8 + 16*16 + 8*16) = 1024.
		chunk_voxel_debug_rect_view_builder(&view, allocator)

		rect_count := chunk_voxel_view_count_exposed_faces(view, .Treat_Out_Of_Chunk_As_Empty)
		log.assertf(rect_count == 1024, "debug rect: expected 1024 faces, got %d", rect_count)

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

		output = chunk_voxel_view_build_naive_mesh(view, .Treat_Out_Of_Chunk_As_Empty, allocator)
		log.assertf(
			output.face_count == 24576,
			"full chunk: expected 24576 faces, got %d",
			output.face_count,
		)
		log.assertf(
			len(output.vertices) == 98304,
			"full chunk: expected 98304 vertices, got %d",
			len(output.vertices),
		)
		log.assertf(
			len(output.indices) == 147456,
			"full chunk: expected 147456 indices, got %d",
			len(output.indices),
		)

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

		checker_count := chunk_voxel_view_count_exposed_faces(view, .Treat_Out_Of_Chunk_As_Empty)
		log.assertf(
			checker_count == 786432,
			"checkerboard: expected 786432 faces, got %d",
			checker_count,
		)

		terrain_heightfield_voxel_view_fill(&view, world_async.ChunkCoord{0, 0, 0})
		heightfield_top_y: [CHUNK_BLOCK_LENGTH * CHUNK_BLOCK_LENGTH]i32
		for z in 0 ..< CHUNK_BLOCK_LENGTH {
			for x in 0 ..< CHUNK_BLOCK_LENGTH {
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

				top_index := chunk_block_index(u32(x), u32(top_y), u32(z))
				top_material_id := u32(u8(view.blocks.material_id[top_index]))
				log.assertf(
					top_material_id == TERRAIN_GRASS_MAT_ID,
					"heightfield column %d,%d: expected top material %d, got %d",
					x,
					z,
					TERRAIN_GRASS_MAT_ID,
					top_material_id,
				)

				for y in 0 ..< CHUNK_BLOCK_LENGTH {
					blocks_below_surface := top_y - i32(y)
					if blocks_below_surface < 0 ||
					   blocks_below_surface >= TERRAIN_GRASS_CAP_BLOCK_DEPTH {
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
						material_id == TERRAIN_GRASS_MAT_ID,
						"heightfield column %d,%d: expected grass-cap material %d, got %d",
						x,
						z,
						TERRAIN_GRASS_MAT_ID,
						material_id,
					)
				}
			}
		}

		heightfield_output := chunk_voxel_view_build_naive_mesh(
			view,
			.Treat_Out_Of_Chunk_As_Empty,
			allocator,
		)
		for face_index in 0 ..< heightfield_output.face_count {
			vertex := terrain_unpack_vertex(heightfield_output.vertices[face_index * 4])
			top_y := heightfield_top_y[vertex.block_x + vertex.block_z * CHUNK_BLOCK_LENGTH]

			if i32(vertex.block_y) != top_y {
				continue
			}

			log.assertf(
				vertex.material_id == TERRAIN_GRASS_MAT_ID,
				"heightfield face %d: expected top block material %d, got %d",
				face_index,
				TERRAIN_GRASS_MAT_ID,
				vertex.material_id,
			)
		}

		log.debug("Chunk mesher contract checks passed")
	}
}


//////////////////////////////////////
// Terrain Constants
/////////////////////////////////////

TERRAIN_PACK_LOCAL_X_SHIFT :: 0
TERRAIN_PACK_LOCAL_Y_SHIFT :: 6
TERRAIN_PACK_LOCAL_Z_SHIFT :: 12
TERRAIN_PACK_NORMAL_SHIFT :: 18
TERRAIN_PACK_MATERIAL_SHIFT :: 21
TERRAIN_PACK_CORNER_SHIFT :: 29
TERRAIN_PACK_LOCAL_MASK :: 0x3F
TERRAIN_PACK_NORMAL_MASK :: 0x7
TERRAIN_PACK_MATERIAL_MASK :: 0xFF
TERRAIN_PACK_CORNER_MASK :: 0x3

TERRAIN_GRASS_MAT_ID :: 0
TERRAIN_DIRT_MAT_ID :: 1
TERRAIN_STONE_MAT_ID :: 2
TERRAIN_GRASS_CAP_BLOCK_DEPTH :: 4
TERRAIN_DIRT_LAYER_BLOCK_DEPTH :: 4

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

TERRAIN_FACE_MASKS := [?]u8{1, 2, 4, 8, 16, 32}

//////////////////////////////////////
// Terrain Types
/////////////////////////////////////

TerrainUnpackedVertex :: struct {
	block_x, block_y, block_z:         u32,
	normal_id, material_id, corner_id: u32,
}
#assert(size_of(TerrainUnpackedVertex) == 24)

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

terrain_face_mask_count :: proc(mask: u8) -> u32 {
	count: u32
	for face_mask in TERRAIN_FACE_MASKS {
		if (mask & face_mask) != 0 {
			count += 1
		}
	}
	return count
}

terrain_pack_vertex :: proc(
	block_x, block_y, block_z: u32,
	normal_id, material_id, corner_id: u32,
) -> world_async.TerrainPackedVertex {
	log.assertf(block_x <= CHUNK_BLOCK_LOCAL_MAX, "terrain block_x out of range: %d", block_x)
	log.assertf(block_y <= CHUNK_BLOCK_LOCAL_MAX, "terrain block_y out of range: %d", block_y)
	log.assertf(block_z <= CHUNK_BLOCK_LOCAL_MAX, "terrain block_z out of range: %d", block_z)
	log.assertf(normal_id < 6, "terrain normal_id out of range: %d", normal_id)
	log.assertf(material_id <= 255, "terrain material_id out of range: %d", material_id)
	log.assertf(corner_id < 4, "terrain corner_id out of range: %d", corner_id)
	return world_async.TerrainPackedVertex(
		(block_x << TERRAIN_PACK_LOCAL_X_SHIFT) |
		(block_y << TERRAIN_PACK_LOCAL_Y_SHIFT) |
		(block_z << TERRAIN_PACK_LOCAL_Z_SHIFT) |
		(normal_id << TERRAIN_PACK_NORMAL_SHIFT) |
		(material_id << TERRAIN_PACK_MATERIAL_SHIFT) |
		(corner_id << TERRAIN_PACK_CORNER_SHIFT),
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
		corner_id = (packed >> TERRAIN_PACK_CORNER_SHIFT) & TERRAIN_PACK_CORNER_MASK,
	}
}

terrain_emit_face :: proc(
	vertices: []world_async.TerrainPackedVertex,
	indices: []u32,
	face_index: u32,
	block_x, block_y, block_z: u32,
	normal_id: u32,
	material_id: u32,
) {
	vertex_index := face_index * 4
	index_index := face_index * 6
	log.assertf(int(vertex_index) + 4 <= len(vertices), "terrain mesh vertex capacity exceeded")
	log.assertf(int(index_index) + 6 <= len(indices), "terrain mesh index capacity exceeded")

	base := vertex_index
	v := int(vertex_index)
	i := int(index_index)

	vertices[v + 0] = terrain_pack_vertex(block_x, block_y, block_z, normal_id, material_id, 0)
	vertices[v + 1] = terrain_pack_vertex(block_x, block_y, block_z, normal_id, material_id, 1)
	vertices[v + 2] = terrain_pack_vertex(block_x, block_y, block_z, normal_id, material_id, 2)
	vertices[v + 3] = terrain_pack_vertex(block_x, block_y, block_z, normal_id, material_id, 3)

	indices[i + 0] = base + 0
	indices[i + 1] = base + 1
	indices[i + 2] = base + 2
	indices[i + 3] = base + 0
	indices[i + 4] = base + 2
	indices[i + 5] = base + 3
}

terrain_heightfield_voxel_view_fill :: proc(
	view: ^world_async.ChunkVoxelView,
	chunk: world_async.ChunkCoord,
) {
	log.assertf(
		len(view.blocks) == CHUNK_BLOCK_COUNT,
		"heightfield fill expects %d blocks, got %d",
		CHUNK_BLOCK_COUNT,
		len(view.blocks),
	)
	chunk_voxel_view_fill_empty(view)

	origin := chunk_origin_from_coord(chunk)
	for z in 0 ..< CHUNK_BLOCK_LENGTH {
		for x in 0 ..< CHUNK_BLOCK_LENGTH {
			world_x := origin.x + i32(x)
			world_z := origin.z + i32(z)

			// Sample in world block coordinates so neighboring chunks use the same
			// heightfield instead of repeating the same local 64x64 tile.
			//
			// The base height keeps terrain above the chunk floor. The three waves
			// use different axes/frequencies so the heightfield terrain has broad hills
			// instead of a single obvious stripe pattern.
			height_f :=
				18.0 +
				math.sin_f32(f32(world_x) * 0.13) * 7.0 +
				math.cos_f32(f32(world_z) * 0.11) * 5.0 +
				math.sin_f32(f32(world_x + world_z) * 0.07) * 4.0

			// Clamp to the vertical block range this first heightfield chunk can represent.
			// Later multi-height terrain can decide whether to generate stacked chunks.
			height := i32(height_f)
			height = math.clamp(height, 0, CHUNK_BLOCK_LENGTH - 1)

			for y in 0 ..< CHUNK_BLOCK_LENGTH {
				world_y := origin.y + i32(y)

				// Heightfield terrain is solid at and below the sampled surface.
				if world_y > height {
					continue
				}

				// Material is still block-level. A shallow grass cap keeps ordinary
				// slope side faces green; otherwise just-below-top dirt blocks show as
				// brown speckles wherever neighboring columns are lower.
				blocks_below_surface := height - world_y
				material_id := world_async.BlockMaterialID(TERRAIN_STONE_MAT_ID)
				if blocks_below_surface < TERRAIN_GRASS_CAP_BLOCK_DEPTH {
					material_id = world_async.BlockMaterialID(TERRAIN_GRASS_MAT_ID)
				} else if blocks_below_surface <
				   TERRAIN_GRASS_CAP_BLOCK_DEPTH + TERRAIN_DIRT_LAYER_BLOCK_DEPTH {
					material_id = world_async.BlockMaterialID(TERRAIN_DIRT_MAT_ID)
				}

				index := chunk_block_index(u32(x), u32(y), u32(z))
				view.blocks.occupancy[index] = .Solid
				view.blocks.material_id[index] = material_id
			}
		}
	}
}
