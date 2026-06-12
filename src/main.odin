package main

import sdl "vendor:sdl3"

import "base:runtime"
import "core:c"
import "core:log"
import math "core:math"
import la "core:math/linalg"
import "core:mem"
import mem_tlsf "core:mem/tlsf"
import "core:os"
import "core:strings"
import "core:thread"

//////////////////////////////////////
// Constants
/////////////////////////////////////

WINDOW_DEFAULT_HEIGHT :: 720
WINDOW_DEFAULT_WIDTH :: 1280
RENDERER_DEFAULT_DRIVER :: "direct3d12"
DEPTH_CLEAR_VALUE :: f32(1.0)
ANGLE :: f32(0.6)
FOV :: f32(70.0)
ASPECT_RATIO :: f32(16.0 / 9.0)
DEFAULT_ACCELERATION :: f32(1.5)
MAX_ACCELERATION :: f32(20.0)
MOUSE_SENSITIVITY :: f32(0.0025)
CAMERA_TERRAIN_CLEARANCE :: f32(18.05)
AUTO_MOVE_STRESS_TEST :: #config(AUTO_MOVE_STRESS_TEST, false)

//////////////////////////////////////
// State
/////////////////////////////////////

Memory :: struct {
	// Main
	persistent_slab:              [64 * mem.Megabyte]u8,
	transient_slab:               [16 * mem.Megabyte]u8,
	persistent_arena:             mem.Arena,
	transient_arena:              mem.Arena,
	persistent_allocator:         mem.Allocator,
	transient_allocator:          mem.Allocator,

	// Chunk Block Storage Memory
	chunk_block_storage_buffer:   []u8,
	chunk_block_storage_tlsf:     mem_tlsf.Allocator,
	chunk_block_storage_allocator: mem.Allocator,

	// Workers (Chunk Mesh)
	chunk_mesh_worker_arena_pool: ArenaPool,
}

Graphics :: struct {
	window:                  ^sdl.Window,
	device:                  ^sdl.GPUDevice,
	depth_texture:           ^sdl.GPUTexture,
	prototype_fill_pipeline: ^sdl.GPUGraphicsPipeline,
	prototype_line_pipeline: ^sdl.GPUGraphicsPipeline,
	terrain_fill_pipeline:   ^sdl.GPUGraphicsPipeline,
	terrain_line_pipeline:   ^sdl.GPUGraphicsPipeline,
	mvp:                     matrix[4, 4]f32,
	view_projection:         matrix[4, 4]f32,
	camera:                  Camera,
}

Metrics :: struct {
	// Current frame stats
	chunks_total:                      u32,
	chunks_without_geometry:           u32,
	chunks_frustum_culled:             u32,
	chunks_drawn:                      u32,
	terrain_faces_drawn:               u32,
	terrain_indices_drawn:             u32,
	chunks_generated:                  u32,
	chunk_mesh_jobs_submitted:         u32,
	chunk_mesh_results_committed:      u32,
	chunk_mesh_results_uploaded:       u32,
	chunks_dirty_remaining:            u32,

	// Previous frame stats
	prev_chunks_total:                 u32,
	prev_chunks_without_geometry:      u32,
	prev_chunks_frustum_culled:        u32,
	prev_chunks_drawn:                 u32,
	prev_terrain_faces_drawn:          u32,
	prev_terrain_indices_drawn:        u32,
	prev_chunks_generated:             u32,
	prev_chunk_mesh_jobs_submitted:    u32,
	prev_chunk_mesh_results_committed: u32,
	prev_chunk_mesh_results_uploaded:  u32,
	prev_chunks_dirty_remaining:       u32,
	prev_chunks_evicted:               u32,
	chunks_evicted:                    u32,
}

Streaming :: struct {
	streaming_center_coord:      ChunkCoord,
	streaming_targets:           [CHUNK_STREAMING_TARGET_CAPACITY]ChunkCoord,
	streaming_target_count:      u32,
	next_streaming_target_index: u32,
	next_mesh_scan_index:        u32,
}

ChunkStore :: struct {
	chunks:      []Chunk,
	chunk_count: u32,
}

state := struct {
	// Memory
	using memory:              Memory,

	// Geometry
	geometry_pool:             GeometryPool,

	// Storage
	chunk_store:               ChunkStore,

	// Graphics & Window
	using graphics:            Graphics,

	// Metrics & Frame debug stats
	using metrics:             Metrics,

	// Streaming
	using streaming:           Streaming,

	// Startup data
	startup_target_count:      u32,
	next_startup_target_index: u32,

	// Player
	auto_move_on:              bool,
	sprint_on:                 bool,

	// State variables
	debug_mode:                bool,
	enable_vsync:              bool,
	is_window_open:            bool,
	use_wireframe_mode:        bool,
} {
	camera = {
		position = {0.0, 0.0, -5.0},
		forward = {0.0, 0.0, 1.0},
		up = {0.0, 1.0, 0.0},
		right = {1.0, 0.0, 0.0},
		world_up = {0.0, 1.0, 0.0},
		yaw = 0.0,
		pitch = 0.0,
		near_plane = 0.1,
		far_plane = 100.0,
	},
	startup_target_count = STARTUP_CHUNK_COUNT,
	next_startup_target_index = 0,
	next_mesh_scan_index = 0,
	auto_move_on = AUTO_MOVE_STRESS_TEST,
	sprint_on = AUTO_MOVE_STRESS_TEST,
	debug_mode = true,
	enable_vsync = true,
	is_window_open = true,
	use_wireframe_mode = false,
}

//////////////////////////////////////
// Memory
/////////////////////////////////////

ArenaPoolElement :: struct {
	arena:     mem.Arena,
	allocator: mem.Allocator,
	buffer:    []u8,
}

ArenaPool :: struct {
	elements: []ArenaPoolElement,
}

arena_pool_init :: proc(arena_count: u32, buffer_size: u32) -> ArenaPool {
	pool := ArenaPool {
		elements = make([]ArenaPoolElement, arena_count, state.persistent_allocator),
	}

	for idx in 0 ..< arena_count {
		pool.elements[idx] = ArenaPoolElement {
			arena     = mem.Arena{},
			allocator = mem.Allocator{},
			buffer    = make([]u8, buffer_size, state.persistent_allocator),
		}

		mem.arena_init(&pool.elements[idx].arena, pool.elements[idx].buffer)
		pool.elements[idx].allocator = mem.arena_allocator(&pool.elements[idx].arena)
	}

	return pool
}

arena_pool_reset :: proc(pool: ArenaPool) {
	for idx in 0 ..< len(pool.elements) {
		mem.arena_free_all(&pool.elements[idx].arena)
	}
}

memory_init :: proc() {
	mem.arena_init(&state.persistent_arena, state.persistent_slab[:])
	mem.arena_init(&state.transient_arena, state.transient_slab[:])

	state.transient_allocator = mem.arena_allocator(&state.transient_arena)
	state.persistent_allocator = mem.arena_allocator(&state.persistent_arena)

	buffer, buffer_err := mem.make_aligned(
		[]u8,
		CHUNK_BLOCK_STORAGE_POOL_BYTES,
		mem_tlsf.ALIGN_SIZE,
		state.persistent_allocator,
	)
	log.assertf(buffer_err == nil, "chunk block storage backing allocation failed: %v", buffer_err)
	state.chunk_block_storage_buffer = buffer

	tlsf_err := mem_tlsf.init(&state.chunk_block_storage_tlsf, state.chunk_block_storage_buffer)
	log.assertf(
		tlsf_err == .None,
		"chunk block storage TLSF init failed: %v",
		tlsf_err,
	)
	state.chunk_block_storage_allocator = mem_tlsf.allocator(&state.chunk_block_storage_tlsf)
}

///////////////////////////////////////////
// Math
///////////////////////////////////////////

UVec2 :: [2]u32

Vec3 :: [3]f32
Vec4 :: [4]f32

Camera :: struct {
	position:   Vec3,
	forward:    Vec3,
	up:         Vec3,
	right:      Vec3,
	world_up:   Vec3,
	yaw:        f32,
	pitch:      f32,
	near_plane: f32,
	far_plane:  f32,
}

WorldAABB :: struct {
	min, max: Vec3,
}

Plane :: struct {
	normal:   Vec3,
	distance: f32,
}

FrustumPlane :: enum u32 {
	Left,
	Right,
	Top,
	Bottom,
	Near,
	Far,
}

Frustum :: struct {
	planes: [FrustumPlane]Plane,
}

frustum_plane_from_point_normal :: proc(point, normal: Vec3) -> Plane {
	n := la.normalize(normal)
	return {normal = n, distance = -la.dot(n, point)}
}

frustum_from_camera :: proc(camera: Camera, vertical_fov_radians, aspect: f32) -> Frustum {
	position := camera.position
	forward := la.normalize(camera.forward)
	up := la.normalize(camera.up)
	right := la.normalize(camera.right)

	near_center := position + forward * camera.near_plane
	far_center := position + forward * camera.far_plane

	tan_vertical := math.tan_f32(vertical_fov_radians * 0.5)
	tan_horizontal := aspect * tan_vertical

	frustum := Frustum{}
	frustum.planes[.Left] = frustum_plane_from_point_normal(
		position,
		forward * tan_horizontal + right,
	)
	frustum.planes[.Right] = frustum_plane_from_point_normal(
		position,
		forward * tan_horizontal - right,
	)
	frustum.planes[.Top] = frustum_plane_from_point_normal(position, forward * tan_vertical - up)
	frustum.planes[.Bottom] = frustum_plane_from_point_normal(
		position,
		forward * tan_vertical + up,
	)
	frustum.planes[.Near] = frustum_plane_from_point_normal(near_center, forward)
	frustum.planes[.Far] = frustum_plane_from_point_normal(far_center, -forward)

	return frustum
}

frustum_test_aabb :: proc(frustum: Frustum, aabb: WorldAABB) -> bool {
	center := Vec3 {
		(aabb.min[0] + aabb.max[0]) * 0.5,
		(aabb.min[1] + aabb.max[1]) * 0.5,
		(aabb.min[2] + aabb.max[2]) * 0.5,
	}
	extent := Vec3 {
		(aabb.max[0] - aabb.min[0]) * 0.5,
		(aabb.max[1] - aabb.min[1]) * 0.5,
		(aabb.max[2] - aabb.min[2]) * 0.5,
	}

	for plane in frustum.planes {
		half_distance :=
			extent[0] * math.abs(plane.normal[0]) +
			extent[1] * math.abs(plane.normal[1]) +
			extent[2] * math.abs(plane.normal[2])

		signed_dist := la.dot(plane.normal, center) + plane.distance
		if signed_dist + half_distance < 0 {
			return false
		}
	}

	return true
}

camera_move_above_block :: proc(camera: ^Camera, block: BlockCoord) {
	camera.position[1] = world_y_from_block_top(block.y) + CAMERA_TERRAIN_CLEARANCE
}

camera_resolve_terrain_intersection :: proc(camera: ^Camera) -> bool {
	moved := false

	for push_count := 0; push_count < CHUNK_BLOCK_LENGTH + 1; push_count += 1 {
		block, intersects := chunk_store_solid_block_at_world_position(camera.position).?
		if !intersects {
			return moved
		}

		camera_move_above_block(camera, block)
		moved = true
	}

	log.assertf(false, "camera remained inside solid terrain after repeated upward pushes")
	return moved
}


when ODIN_DEBUG {
	debug_frustum_contract_checks_run :: proc() {
		test_camera := Camera {
			position   = {0, 0, 0},
			forward    = {0, 0, 1},
			up         = {0, 1, 0},
			right      = {1, 0, 0},
			world_up   = {0, 1, 0},
			near_plane = 1,
			far_plane  = 10,
		}
		frustum := frustum_from_camera(test_camera, math.to_radians_f32(90), 1)

		log.assertf(
			frustum_test_aabb(frustum, WorldAABB{min = {-0.5, -0.5, 4}, max = {0.5, 0.5, 5}}),
			"frustum check: expected centered box to be visible",
		)
		log.assertf(
			!frustum_test_aabb(frustum, WorldAABB{min = {-0.5, -0.5, -3}, max = {0.5, 0.5, -2}}),
			"frustum check: expected box behind camera to be culled",
		)
		log.assertf(
			!frustum_test_aabb(frustum, WorldAABB{min = {-0.5, -0.5, 12}, max = {0.5, 0.5, 13}}),
			"frustum check: expected box beyond far plane to be culled",
		)
		log.assertf(
			!frustum_test_aabb(frustum, WorldAABB{min = {12, -0.5, 4}, max = {13, 0.5, 5}}),
			"frustum check: expected right-side box to be culled",
		)

		aabb := chunk_world_get_aabb(ChunkCoord{1, 0, -1})
		log.assertf(
			aabb.min == Vec3{32, 0, -32},
			"chunk world AABB: min mismatch, got %v",
			aabb.min,
		)
		log.assertf(
			aabb.max == Vec3{64, 32, 0},
			"chunk world AABB: max mismatch, got %v",
			aabb.max,
		)
	}
}

///////////////////////////////////////////
// Chunks
///////////////////////////////////////////

CHUNK_BLOCK_LENGTH :: 64
CHUNK_BLOCK_LENGTH_LOG2 :: 6
CHUNK_BLOCK_LOCAL_MAX :: CHUNK_BLOCK_LENGTH - 1
CHUNK_BLOCK_COUNT :: CHUNK_BLOCK_LENGTH * CHUNK_BLOCK_LENGTH * CHUNK_BLOCK_LENGTH
TERRAIN_BLOCK_WORLD_SIZE :: f32(0.5)
#assert(CHUNK_BLOCK_LENGTH == 1 << CHUNK_BLOCK_LENGTH_LOG2)
#assert(CHUNK_BLOCK_LOCAL_MAX <= 0x3F)

DEBUG_CHUNK_SOLID_X0 :: 8
DEBUG_CHUNK_SOLID_X1 :: 24
DEBUG_CHUNK_SOLID_Y0 :: 0
DEBUG_CHUNK_SOLID_Y1 :: 8
DEBUG_CHUNK_SOLID_Z0 :: 8
DEBUG_CHUNK_SOLID_Z1 :: 24
#assert(DEBUG_CHUNK_SOLID_X0 < DEBUG_CHUNK_SOLID_X1 && DEBUG_CHUNK_SOLID_X1 <= CHUNK_BLOCK_LENGTH)
#assert(DEBUG_CHUNK_SOLID_Y0 < DEBUG_CHUNK_SOLID_Y1 && DEBUG_CHUNK_SOLID_Y1 <= CHUNK_BLOCK_LENGTH)
#assert(DEBUG_CHUNK_SOLID_Z0 < DEBUG_CHUNK_SOLID_Z1 && DEBUG_CHUNK_SOLID_Z1 <= CHUNK_BLOCK_LENGTH)

STARTUP_CHUNK_GRID_X :: 5
STARTUP_CHUNK_GRID_Z :: 5
STARTUP_CHUNK_COUNT :: STARTUP_CHUNK_GRID_X * STARTUP_CHUNK_GRID_Z
EAGER_STARTUP_GRID :: #config(EAGER_STARTUP_GRID, false)
#assert(STARTUP_CHUNK_COUNT > 0)

CHUNK_MESH_WORKER_COUNT :: 4
CHUNK_MESH_WORKER_ARENA_BYTES :: 8 * mem.Megabyte // or larger if current chunks assert
CHUNK_BLOCK_STORAGE_POOL_BYTES :: 24 * mem.Megabyte

CHUNK_GENERATION_BUDGET_PER_FRAME :: 1
CHUNK_MESH_BUDGET_PER_FRAME :: 2

CHUNK_STREAMING_RADIUS_XZ :: 2
CHUNK_UNLOAD_RADIUS_XZ :: CHUNK_STREAMING_RADIUS_XZ + 1
CHUNK_STREAMING_TARGET_CAPACITY ::
	(CHUNK_STREAMING_RADIUS_XZ * 2 + 1) * (CHUNK_STREAMING_RADIUS_XZ * 2 + 1)
CHUNK_UNLOAD_CAPACITY ::
	(CHUNK_UNLOAD_RADIUS_XZ * 2 + 1) * (CHUNK_UNLOAD_RADIUS_XZ * 2 + 1)
#assert(CHUNK_UNLOAD_RADIUS_XZ >= CHUNK_STREAMING_RADIUS_XZ)

// Until chunk/geometry eviction exists, store capacity must stay within the fixed arenas.
CHUNK_STORE_CAPACITY :: 128
#assert(CHUNK_STREAMING_TARGET_CAPACITY > 0)
#assert(CHUNK_STORE_CAPACITY >= CHUNK_UNLOAD_CAPACITY)

VERIFY_CHUNK_MESH_WORKER_OUTPUTS :: #config(VERIFY_CHUNK_MESH_WORKER_OUTPUTS, false)
LOG_CHUNK_MESH_COMMITS :: #config(LOG_CHUNK_MESH_COMMITS, false)

BlockOccupancy :: enum u8 {
	Empty,
	Solid,
}

BlockMaterialID :: distinct u8

ChunkMeshBoundaryPolicy :: enum {
	Treat_Out_Of_Chunk_As_Empty,
	Sample_Neighbor_Snapshots,
}

ChunkVoxelViewElement :: struct {
	occupancy:   BlockOccupancy,
	material_id: BlockMaterialID,
}

ChunkVoxelView :: struct {
	blocks: #soa[]ChunkVoxelViewElement,
}

ChunkCoord :: struct {
	x, y, z: i32,
}

BlockCoord :: struct {
	x, y, z: i32,
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

ChunkGenerationJob :: struct {
	coord:            ChunkCoord,
	seed:             u32,
	output_allocator: mem.Allocator,
}

ChunkGenerationJobResult :: struct {
	coord:         ChunkCoord,
	block_storage: ChunkBlockStorage,
}

ChunkMeshJob :: struct {
	snapshot:         ChunkSnapshot,
	neighbors:        ChunkMeshNeighborSnapshots,
	boundary_policy:  ChunkMeshBoundaryPolicy,
	output_allocator: mem.Allocator,
}

ChunkMeshJobResult :: struct {
	coord:  ChunkCoord,
	output: ChunkMeshOutput,
}

ChunkMeshBatchStats :: struct {
	chunks_attempted: u32,
	chunks_committed: u32,
	chunks_uploaded:  u32,
	chunks_empty:     u32,
	chunks_stale:     u32,
	total_faces:      u32,
}

ChunkMeshWorkerContext :: struct {
	worker_index: u32,
	worker_count: u32,
	jobs:         []ChunkMeshJob,
	results:      []ChunkMeshJobResult,
}

ChunkBounds :: struct {
	min, max: BlockCoord,
}

ChunkMeshOutput :: struct {
	vertices:   []TerrainPackedVertex,
	indices:    []u32,
	face_count: u32,
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
	Generated,
}
ChunkMeshState :: enum {
	Missing,
	Dirty,
	Ready,
}

ChunkDirtyFlag :: enum u8 {
	Blocks,
	Boundary,
}

ChunkDirtyFlags :: bit_set[ChunkDirtyFlag]

ChunkBlockStorage :: struct {
	voxel_view: ChunkVoxelView,
}

Chunk :: struct {
	block_storage:    ChunkBlockStorage,
	coord:            ChunkCoord,
	geometry_id:      GeometryID,
	generation_state: ChunkGenerationState,
	mesh_state:       ChunkMeshState,
	dirty_flags:      ChunkDirtyFlags,
	slot_generation:  u32,
	block_version:    u32,
	mesh_version:     u32,
}

chunk_create :: proc(coord: ChunkCoord) -> Chunk {
	return {
		coord = coord,
		geometry_id = INVALID_GEOMETRY_ID,
		generation_state = .Missing,
		mesh_state = .Missing,
		dirty_flags = {},
		slot_generation = 1,
		block_version = 0,
		mesh_version = 0,
	}
}

chunk_mark_generated :: proc(chunk: ^Chunk, block_storage: ChunkBlockStorage) {
	chunk.block_storage = block_storage
	chunk.generation_state = .Generated
	chunk.mesh_state = .Dirty
	chunk.dirty_flags = {.Blocks, .Boundary}
	chunk.block_version += 1
}

chunk_origin_from_coord :: proc(coord: ChunkCoord) -> BlockCoord {
	return {
		x = coord.x * CHUNK_BLOCK_LENGTH,
		y = coord.y * CHUNK_BLOCK_LENGTH,
		z = coord.z * CHUNK_BLOCK_LENGTH,
	}
}

chunk_world_get_aabb :: proc(coord: ChunkCoord) -> WorldAABB {
	origin := terrain_chunk_origin_world_from_coord(coord)
	length := f32(CHUNK_BLOCK_LENGTH) * TERRAIN_BLOCK_WORLD_SIZE
	min := Vec3{origin[0], origin[1], origin[2]}

	return {min = min, max = min + Vec3{length, length, length}}
}

block_coord_local_from_chunk_coord :: proc(block: BlockCoord, chunk_coord: ChunkCoord) -> BlockCoord {
	origin := chunk_origin_from_coord(chunk_coord)
	return {
		x = block.x - origin.x,
		y = block.y - origin.y,
		z = block.z - origin.z,
	}
}

block_coord_from_world_position :: proc(position: Vec3) -> BlockCoord {
	return {
		x = i32(math.floor_f32(position[0] / TERRAIN_BLOCK_WORLD_SIZE)),
		y = i32(math.floor_f32(position[1] / TERRAIN_BLOCK_WORLD_SIZE)),
		z = i32(math.floor_f32(position[2] / TERRAIN_BLOCK_WORLD_SIZE)),
	}
}

world_y_from_block_top :: proc(block_y: i32) -> f32 {
	return f32(block_y + 1) * TERRAIN_BLOCK_WORLD_SIZE
}

chunk_coord_from_block_coord :: proc(coord: BlockCoord) -> ChunkCoord {
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

chunk_voxel_view_alloc :: proc(voxel_view: ^ChunkVoxelView, allocator: mem.Allocator) {
	voxel_view.blocks = make(#soa[]ChunkVoxelViewElement, CHUNK_BLOCK_COUNT, allocator)
	chunk_voxel_view_fill_empty(voxel_view)
}

chunk_voxel_view_is_solid_local :: proc(view: ChunkVoxelView, x, y, z: u32) -> bool {
	return view.blocks.occupancy[chunk_block_index(x, y, z)] == .Solid
}


chunk_voxel_view_is_solid_for_meshing :: proc(
	view: ChunkVoxelView,
	x, y, z: i32,
	boundary_policy: ChunkMeshBoundaryPolicy,
	neighbor_snapshots: Maybe(ChunkMeshNeighborSnapshots) = nil,
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

		neighbor: Maybe(ChunkSnapshot)
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

chunk_voxel_view_material_id :: proc(view: ChunkVoxelView, x, y, z: u32) -> BlockMaterialID {
	return view.blocks.material_id[chunk_block_index(x, y, z)]
}

chunk_voxel_view_fill_empty :: proc(view: ^ChunkVoxelView) {
	log.assertf(
		len(view.blocks) == CHUNK_BLOCK_COUNT,
		"chunk voxel view must have %d blocks, got %d",
		CHUNK_BLOCK_COUNT,
		len(view.blocks),
	)

	for _, i in view.blocks {
		view.blocks.occupancy[i] = .Empty
		view.blocks.material_id[i] = BlockMaterialID(0)
	}
}

chunk_voxel_debug_rect_view_builder :: proc(view: ^ChunkVoxelView) {
	chunk_voxel_view_alloc(view, state.transient_allocator)

	for z in DEBUG_CHUNK_SOLID_Z0 ..< DEBUG_CHUNK_SOLID_Z1 {
		for y in DEBUG_CHUNK_SOLID_Y0 ..< DEBUG_CHUNK_SOLID_Y1 {
			for x in DEBUG_CHUNK_SOLID_X0 ..< DEBUG_CHUNK_SOLID_X1 {
				index := chunk_block_index(u32(x), u32(y), u32(z))
				view.blocks.occupancy[index] = .Solid
				view.blocks.material_id[index] = BlockMaterialID(0)
			}
		}
	}
}

chunk_voxel_view_count_exposed_faces :: proc(
	view: ChunkVoxelView,
	boundary_policy: ChunkMeshBoundaryPolicy,
	neighbor_snapshots: Maybe(ChunkMeshNeighborSnapshots) = nil,
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
				if !chunk_voxel_view_is_solid_for_meshing(
					view,
					i32(x),
					i32(y),
					i32(z),
					boundary_policy,
					neighbor_snapshots,
				) {
					continue
				}

				for face in TERRAIN_FACE_DESCS {
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
						face_count += 1
					}
				}
			}
		}
	}

	return face_count
}

chunk_voxel_view_build_naive_mesh :: proc(
	view: ChunkVoxelView,
	boundary_policy: ChunkMeshBoundaryPolicy,
	allocator: mem.Allocator,
	neighbor_snapshots: Maybe(ChunkMeshNeighborSnapshots) = nil,
) -> ChunkMeshOutput {
	face_count := chunk_voxel_view_count_exposed_faces(view, boundary_policy, neighbor_snapshots)

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

	output := ChunkMeshOutput {
		vertices   = make([]TerrainPackedVertex, expected_vertex_count, allocator),
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

	vertex_count: u32
	index_count: u32
	for z in 0 ..< CHUNK_BLOCK_LENGTH {
		for y in 0 ..< CHUNK_BLOCK_LENGTH {
			for x in 0 ..< CHUNK_BLOCK_LENGTH {
				if !chunk_voxel_view_is_solid_for_meshing(
					view,
					i32(x),
					i32(y),
					i32(z),
					boundary_policy,
					neighbor_snapshots,
				) {
					continue
				}

				material_id := u32(u8(chunk_voxel_view_material_id(view, u32(x), u32(y), u32(z))))

				for face in TERRAIN_FACE_DESCS {
					neighbor_x := i32(x) + face.neighbor_dx
					neighbor_y := i32(y) + face.neighbor_dy
					neighbor_z := i32(z) + face.neighbor_dz

					if chunk_voxel_view_is_solid_for_meshing(
						view,
						neighbor_x,
						neighbor_y,
						neighbor_z,
						boundary_policy,
						neighbor_snapshots,
					) {
						continue
					}

					terrain_emit_face(
						output.vertices,
						output.indices,
						u32(x),
						u32(y),
						u32(z),
						face.normal_id,
						material_id,
						&vertex_count,
						&index_count,
					)
				}
			}
		}
	}

	log.assertf(vertex_count == face_count * 4, "chunk mesh vertex count mismatch")
	log.assertf(index_count == face_count * 6, "chunk mesh index count mismatch")

	return output
}

chunk_mesh_job_execute_sync :: proc(job: ChunkMeshJob) -> ChunkMeshOutput {
	log.assertf(
		len(job.snapshot.voxel_view.blocks) == CHUNK_BLOCK_COUNT,
		"chunk mesh job snapshot must have %d blocks, got %d",
		CHUNK_BLOCK_COUNT,
		len(job.snapshot.voxel_view.blocks),
	)

	return chunk_voxel_view_build_naive_mesh(
		job.snapshot.voxel_view,
		job.boundary_policy,
		job.output_allocator,
		job.neighbors,
	)
}

chunk_mesh_worker_proc :: proc(data: rawptr) {
	ctx := (^ChunkMeshWorkerContext)(data)

	pool_element := &state.chunk_mesh_worker_arena_pool.elements[ctx.worker_index]
	allocator := pool_element.allocator

	for job_index := ctx.worker_index;
	    job_index < u32(len(ctx.jobs));
	    job_index += ctx.worker_count {
		job := ctx.jobs[job_index]
		job.output_allocator = allocator

		output := chunk_mesh_job_execute_sync(job)

		ctx.results[job_index] = {
			coord  = job.snapshot.coord,
			output = output,
		}
	}

}

chunk_mesh_jobs_execute_workers :: proc(jobs: []ChunkMeshJob, results: []ChunkMeshJobResult) {
	log.assertf(len(results) >= len(jobs), "chunk mesh results slice too small")

	arena_pool_reset(state.chunk_mesh_worker_arena_pool)

	worker_count := math.min(CHUNK_MESH_WORKER_COUNT, len(jobs))
	if worker_count == 0 {
		return
	}

	worker_contexts: [CHUNK_MESH_WORKER_COUNT]ChunkMeshWorkerContext
	worker_threads: [CHUNK_MESH_WORKER_COUNT]^thread.Thread

	for worker_index in 0 ..< worker_count {
		worker_contexts[worker_index] = {
			worker_index = u32(worker_index),
			worker_count = u32(worker_count),
			jobs         = jobs,
			results      = results,
		}
		worker_threads[worker_index] = thread.create_and_start_with_data(
			rawptr(&worker_contexts[worker_index]),
			chunk_mesh_worker_proc,
		)
		log.assertf(worker_threads[worker_index] != nil, "failed to create chunk mesh worker")
	}

	for worker_index in 0 ..< worker_count {
		thread.join(worker_threads[worker_index])
		thread.destroy(worker_threads[worker_index])
	}
}

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
	if chunk.geometry_id != INVALID_GEOMETRY_ID {
		geometry_release(&state.geometry_pool, chunk.geometry_id)
		chunk.geometry_id = INVALID_GEOMETRY_ID
	}

	chunk_block_storage_release(&chunk.block_storage)
	chunk.generation_state = .Missing
	chunk.mesh_state = .Missing
	chunk.dirty_flags = {}
}

chunk_store_remove_at :: proc(index: u32) {
	log.assertf(index < state.chunk_store.chunk_count, "chunk remove index out of bounds: %d", index)

	chunk_store_release_chunk_resources(&state.chunk_store.chunks[index])

	last_index := state.chunk_store.chunk_count - 1
	if index != last_index {
		state.chunk_store.chunks[index] = state.chunk_store.chunks[last_index]
	}

	state.chunk_store.chunks[last_index] = {}
	state.chunk_store.chunk_count -= 1

	if state.chunk_store.chunk_count == 0 || state.next_mesh_scan_index >= state.chunk_store.chunk_count {
		state.next_mesh_scan_index = 0
	}
}

chunk_store_find_index_by_coord :: proc(coord: ChunkCoord) -> Maybe(u32) {
	for i in 0 ..< state.chunk_store.chunk_count {
		if state.chunk_store.chunks[i].coord == coord {
			return i
		}
	}

	return nil
}

chunk_store_commit_mesh_results :: proc(
	jobs: []ChunkMeshJob,
	results: []ChunkMeshJobResult,
) -> ChunkMeshBatchStats {
	log.assertf(
		len(jobs) == len(results),
		"chunk mesh commit requires matching job/result counts: jobs=%d results=%d",
		len(jobs),
		len(results),
	)

	stats := ChunkMeshBatchStats{}
	for result, i in results {
		job := jobs[i]

		stats.chunks_attempted += 1

		log.assertf(
			result.coord == job.snapshot.coord,
			"mesh result coord mismatch: job=%v result=%v",
			job.snapshot.coord,
			result.coord,
		)

		index, ok := chunk_store_find_index_by_coord(job.snapshot.coord).?
		log.assertf(ok, "mesh result has no matching chunk: coord=%v", job.snapshot.coord)

		chunk := chunk_store_get_by_index(index)
		log.assertf(
			chunk.generation_state == .Generated,
			"mesh result target chunk must be generated: coord=%v",
			chunk.coord,
		)

		if chunk.block_version != job.snapshot.block_version {
			stats.chunks_stale += 1
			continue
		}

		stats.chunks_committed += 1
		stats.total_faces += result.output.face_count
		if result.output.face_count == 0 {
			stats.chunks_empty += 1
		} else {
			stats.chunks_uploaded += 1
		}

		chunk.geometry_id = geometry_replace(&state.geometry_pool, chunk.geometry_id, result.output)
		chunk.mesh_state = .Ready
		chunk.mesh_version = job.snapshot.block_version
		chunk.dirty_flags = {}

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

chunk_store_append_reserved :: proc(coord: ChunkCoord) -> ChunkID {
	chunk := chunk_create(coord)
	chunk_store_append(chunk)

	return chunk_store_id_from_index(state.chunk_store.chunk_count - 1)
}

chunk_store_get_or_append_reserved :: proc(coord: ChunkCoord) -> ChunkID {
	if index, ok := chunk_store_find_index_by_coord(coord).?; ok {
		return chunk_store_id_from_index(index)
	}

	return chunk_store_append_reserved(coord)
}

chunk_store_snapshot_find_by_coord :: proc(coord: ChunkCoord) -> Maybe(ChunkSnapshot) {
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

chunk_store_mesh_neighbors_find :: proc(coord: ChunkCoord) -> ChunkMeshNeighborSnapshots {
	return {
		plus_x = chunk_store_snapshot_find_by_coord(ChunkCoord{coord.x + 1, coord.y, coord.z}),
		minus_x = chunk_store_snapshot_find_by_coord(ChunkCoord{coord.x - 1, coord.y, coord.z}),
		plus_y = chunk_store_snapshot_find_by_coord(ChunkCoord{coord.x, coord.y + 1, coord.z}),
		minus_y = chunk_store_snapshot_find_by_coord(ChunkCoord{coord.x, coord.y - 1, coord.z}),
		plus_z = chunk_store_snapshot_find_by_coord(ChunkCoord{coord.x, coord.y, coord.z + 1}),
		minus_z = chunk_store_snapshot_find_by_coord(ChunkCoord{coord.x, coord.y, coord.z - 1}),
	}
}

chunk_snapshot_find_by_coord :: proc(
	snapshots: []ChunkSnapshot,
	coord: ChunkCoord,
) -> Maybe(ChunkSnapshot) {
	for i in 0 ..< len(snapshots) {
		if snapshots[i].coord == coord {
			return snapshots[i]
		}
	}
	return nil
}

chunk_mesh_neighbors_find :: proc(
	snapshots: []ChunkSnapshot,
	coord: ChunkCoord,
) -> ChunkMeshNeighborSnapshots {
	return {
		plus_x = chunk_snapshot_find_by_coord(
			snapshots,
			ChunkCoord{coord.x + 1, coord.y, coord.z},
		),
		minus_x = chunk_snapshot_find_by_coord(
			snapshots,
			ChunkCoord{coord.x - 1, coord.y, coord.z},
		),
		plus_y = chunk_snapshot_find_by_coord(
			snapshots,
			ChunkCoord{coord.x, coord.y + 1, coord.z},
		),
		minus_y = chunk_snapshot_find_by_coord(
			snapshots,
			ChunkCoord{coord.x, coord.y - 1, coord.z},
		),
		plus_z = chunk_snapshot_find_by_coord(
			snapshots,
			ChunkCoord{coord.x, coord.y, coord.z + 1},
		),
		minus_z = chunk_snapshot_find_by_coord(
			snapshots,
			ChunkCoord{coord.x, coord.y, coord.z - 1},
		),
	}
}

chunk_block_storage_alloc :: proc {
	chunk_block_storage_alloc_with_allocator,
	chunk_block_storage_alloc_for_store,
}

chunk_block_storage_alloc_with_allocator :: proc(allocator: mem.Allocator) -> ChunkBlockStorage {
	storage := ChunkBlockStorage{}
	chunk_voxel_view_alloc(&storage.voxel_view, allocator)
	return storage
}

chunk_block_storage_alloc_for_store :: proc() -> ChunkBlockStorage {
	return chunk_block_storage_alloc(state.chunk_block_storage_allocator)
}

chunk_block_storage_release :: proc(storage: ^ChunkBlockStorage) {
	if len(storage.voxel_view.blocks) == 0 {
		return
	}

	err := delete(storage.voxel_view.blocks, state.chunk_block_storage_allocator)
	log.assertf(err == nil, "chunk block storage release failed: %v", err)
	storage^ = {}
}

chunk_snapshot_from_chunk :: proc(chunk: ^Chunk) -> ChunkSnapshot {
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

chunk_generation_job_execute_sync :: proc(job: ChunkGenerationJob) -> ChunkGenerationJobResult {
	block_storage := chunk_block_storage_alloc(job.output_allocator)
	terrain_heightfield_voxel_view_fill(&block_storage.voxel_view, job.coord)
	return {coord = job.coord, block_storage = block_storage}
}

chunk_store_mark_generated_chunk_boundary_dirty :: proc(coord: ChunkCoord) {
	index, ok := chunk_store_find_index_by_coord(coord).?
	if !ok {
		return
	}

	chunk := chunk_store_get_by_index(index)
	if chunk.generation_state != .Generated {
		return
	}

	chunk.mesh_state = .Dirty
	chunk.dirty_flags += {.Boundary}
}

chunk_store_mark_generated_neighbors_boundary_dirty :: proc(coord: ChunkCoord) {
	chunk_store_mark_generated_chunk_boundary_dirty(ChunkCoord{coord.x + 1, coord.y, coord.z})
	chunk_store_mark_generated_chunk_boundary_dirty(ChunkCoord{coord.x - 1, coord.y, coord.z})
	chunk_store_mark_generated_chunk_boundary_dirty(ChunkCoord{coord.x, coord.y + 1, coord.z})
	chunk_store_mark_generated_chunk_boundary_dirty(ChunkCoord{coord.x, coord.y - 1, coord.z})
	chunk_store_mark_generated_chunk_boundary_dirty(ChunkCoord{coord.x, coord.y, coord.z + 1})
	chunk_store_mark_generated_chunk_boundary_dirty(ChunkCoord{coord.x, coord.y, coord.z - 1})
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

chunk_solid_block_at_world_block :: proc(chunk: ^Chunk, block: BlockCoord) -> Maybe(BlockCoord) {
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

chunk_store_solid_block_at_world_position :: proc(position: Vec3) -> Maybe(BlockCoord) {
	block := block_coord_from_world_position(position)
	chunk_coord := chunk_coord_from_block_coord(block)
	index, ok := chunk_store_find_index_by_coord(chunk_coord).?
	if !ok {
		return nil
	}

	chunk := chunk_store_get_by_index(index)
	return chunk_solid_block_at_world_block(chunk, block)
}

chunk_store_coord_is_generated :: proc(coord: ChunkCoord) -> bool {
	index, ok := chunk_store_find_index_by_coord(coord).?
	if !ok {
		return false
	}

	chunk := chunk_store_get_by_index(index)
	return chunk.generation_state == .Generated
}

chunk_work_generate_budgeted :: proc() -> u32 {
	generated_count: u32
	if state.streaming_target_count == 0 {
		return 0
	}

	scanned_count: u32
	for generated_count < CHUNK_GENERATION_BUDGET_PER_FRAME &&
	    scanned_count < state.streaming_target_count {
		target_index := state.next_streaming_target_index
		state.next_streaming_target_index =
			(state.next_streaming_target_index + 1) % state.streaming_target_count
		scanned_count += 1

		coord := state.streaming_targets[target_index]
		chunk_id := chunk_store_get_or_append_reserved(coord)
		chunk := chunk_store_get_by_id(chunk_id)

		if chunk.generation_state == .Generated {
			continue
		}

		log.assertf(
			chunk.generation_state == .Missing,
			"streaming target chunk has unexpected generation state: coord=%v state=%v",
			coord,
			chunk.generation_state,
		)

		generation_job := ChunkGenerationJob {
			coord            = coord,
			seed             = 0,
			output_allocator = state.chunk_block_storage_allocator,
		}
		generation_result := chunk_generation_job_execute_sync(generation_job)
		log.assertf(generation_result.coord == coord, "Chunk generation job result coord mismatch")
		log.assertf(
			len(generation_result.block_storage.voxel_view.blocks) == CHUNK_BLOCK_COUNT,
			"generated chunk storage has wrong block count",
		)

		chunk_mark_generated(chunk, generation_result.block_storage)
		chunk_store_mark_generated_neighbors_boundary_dirty(coord)
		generated_count += 1
	}

	return generated_count
}

chunk_work_mesh_and_commit_budgeted :: proc() -> ChunkMeshBatchStats {
	stats := ChunkMeshBatchStats{}
	if state.chunk_store.chunk_count == 0 {
		return stats
	}

	if state.next_mesh_scan_index >= state.chunk_store.chunk_count {
		state.next_mesh_scan_index = 0
	}

	chunk_mesh_jobs: [CHUNK_MESH_BUDGET_PER_FRAME]ChunkMeshJob
	chunk_mesh_results: [CHUNK_MESH_BUDGET_PER_FRAME]ChunkMeshJobResult

	mesh_job_count: u32
	for scanned := u32(0);
	    scanned < state.chunk_store.chunk_count && mesh_job_count < CHUNK_MESH_BUDGET_PER_FRAME;
	    scanned += 1 {
		index := state.next_mesh_scan_index
		state.next_mesh_scan_index =
			(state.next_mesh_scan_index + 1) % state.chunk_store.chunk_count

		chunk := chunk_store_get_by_index(index)
		if chunk.generation_state != .Generated || chunk.mesh_state != .Dirty {
			continue
		}
		if !chunk_streaming_mesh_dependencies_ready(chunk.coord) {
			continue
		}

		snapshot := chunk_snapshot_from_chunk(chunk)
		chunk_mesh_jobs[mesh_job_count] = {
			snapshot         = snapshot,
			boundary_policy  = .Sample_Neighbor_Snapshots,
			output_allocator = state.transient_allocator,
			neighbors        = chunk_store_mesh_neighbors_find(snapshot.coord),
		}
		mesh_job_count += 1
	}

	if mesh_job_count == 0 {
		return stats
	}

	job_slice := chunk_mesh_jobs[:int(mesh_job_count)]
	result_slice := chunk_mesh_results[:len(job_slice)]
	chunk_mesh_jobs_execute_workers(job_slice, result_slice)

	when ODIN_DEBUG && VERIFY_CHUNK_MESH_WORKER_OUTPUTS {
		chunk_mesh_output_matches :: proc(a, b: ChunkMeshOutput) -> bool {
			if a.face_count != b.face_count {
				return false
			}

			if len(a.vertices) != len(b.vertices) || len(a.indices) != len(b.indices) {
				return false
			}

			if mem.compare(mem.slice_to_bytes(a.vertices), mem.slice_to_bytes(b.vertices)) != 0 {
				return false
			}

			if mem.compare(mem.slice_to_bytes(a.indices), mem.slice_to_bytes(b.indices)) != 0 {
				return false
			}

			return true
		}

		for job, i in job_slice {
			sync_temp := mem.begin_arena_temp_memory(&state.transient_arena)
			sync_output := chunk_mesh_job_execute_sync(job)
			output_matches := chunk_mesh_output_matches(result_slice[i].output, sync_output)
			mem.end_arena_temp_memory(sync_temp)

			log.assertf(
				output_matches,
				"threaded chunk mesh result mismatch: job_index=%d coord=%v",
				i,
				job.snapshot.coord,
			)
			log.assertf(
				result_slice[i].coord == job.snapshot.coord,
				"threaded chunk mesh coord mismatch: job_index=%d expected=%v got=%v",
				i,
				job.snapshot.coord,
				result_slice[i].coord,
			)
		}
	}

	return chunk_store_commit_mesh_results(job_slice, result_slice)
}

chunk_work_update_budgeted :: proc() {
	state.chunks_evicted = chunk_streaming_update_for_observer(state.camera.position)

	state.chunks_generated = chunk_work_generate_budgeted()
	mesh_stats := chunk_work_mesh_and_commit_budgeted()
	state.chunk_mesh_jobs_submitted = mesh_stats.chunks_attempted
	state.chunk_mesh_results_committed = mesh_stats.chunks_committed
	state.chunk_mesh_results_uploaded = mesh_stats.chunks_uploaded
	state.chunks_dirty_remaining = chunk_store_count_dirty_generated()
}

chunk_streaming_update_for_observer :: proc(observer_world_position: Vec3) -> u32 {
	center := chunk_streaming_center_from_observer(observer_world_position)
	if state.streaming_target_count == 0 || center != state.streaming_center_coord {
		chunk_streaming_window_rebuild_targets(center)
	}
	return chunk_streaming_evict_outside_unload_radius()
}

chunk_streaming_center_from_observer :: proc(observer_world_position: Vec3) -> ChunkCoord {
	center := chunk_coord_from_block_coord(
		block_coord_from_world_position(observer_world_position),
	)
	center.y = 0
	return center
}

chunk_streaming_coord_inside_square_radius :: proc(center, coord: ChunkCoord, radius: u32) -> bool {
	dx := coord.x - center.x
	dz := coord.z - center.z
	r := i32(radius)

	return coord.y == center.y &&
	       dx >= -r && dx <= r &&
	       dz >= -r && dz <= r
}

chunk_streaming_target_less :: proc(center, a, b: ChunkCoord) -> bool {
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

chunk_streaming_evict_outside_unload_radius :: proc() -> u32 {
	evicted_count: u32
	for i := u32(0); i < state.chunk_store.chunk_count; {
		chunk := chunk_store_get_by_index(i)
		if chunk_streaming_coord_inside_square_radius(
			state.streaming_center_coord,
			chunk.coord,
			CHUNK_UNLOAD_RADIUS_XZ,
		) {
			i += 1
			continue
		}

		chunk_store_mark_generated_neighbors_boundary_dirty(chunk.coord)
		chunk_store_remove_at(i)
		evicted_count += 1
	}
	return evicted_count
}

chunk_streaming_mesh_dependency_ready :: proc(coord: ChunkCoord) -> bool {
	if !chunk_streaming_coord_inside_square_radius(
		state.streaming_center_coord,
		coord,
		CHUNK_STREAMING_RADIUS_XZ,
	) {
		return true
	}
	return chunk_store_coord_is_generated(coord)
}

chunk_streaming_mesh_dependencies_ready :: proc(coord: ChunkCoord) -> bool {
	return (
		chunk_streaming_mesh_dependency_ready(ChunkCoord{coord.x + 1, coord.y, coord.z}) &&
		chunk_streaming_mesh_dependency_ready(ChunkCoord{coord.x - 1, coord.y, coord.z}) &&
		chunk_streaming_mesh_dependency_ready(ChunkCoord{coord.x, coord.y, coord.z + 1}) &&
		chunk_streaming_mesh_dependency_ready(ChunkCoord{coord.x, coord.y, coord.z - 1})
	)
}

chunk_streaming_window_rebuild_targets :: proc(center: ChunkCoord) {
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
			if chunk_streaming_target_less(
				center,
				state.streaming_targets[j],
				state.streaming_targets[best],
			) {
				best = j
			}
		}
		if best != i {
			state.streaming_targets[i], state.streaming_targets[best] = state.streaming_targets[best], state.streaming_targets[i]
		}
	}

	state.next_streaming_target_index = 0
}

when ODIN_DEBUG {
	debug_camera_terrain_collision_checks_run :: proc() {
		temp := mem.begin_arena_temp_memory(&state.transient_arena)
		defer mem.end_arena_temp_memory(temp)

		chunk := chunk_create(ChunkCoord{0, 0, 0})
		storage := chunk_block_storage_alloc(state.transient_allocator)
		index := chunk_block_index(0, 0, 0)
		storage.voxel_view.blocks.occupancy[index] = .Solid
		storage.voxel_view.blocks.material_id[index] = BlockMaterialID(1)
		chunk_mark_generated(&chunk, storage)

		hit_block, hit := chunk_solid_block_at_world_block(&chunk, BlockCoord{0, 0, 0}).?
		log.assert(hit, "camera terrain collision check: expected solid block hit")
		log.assertf(
			hit_block == BlockCoord{0, 0, 0},
			"camera terrain collision check: wrong hit block %v",
			hit_block,
		)

		test_camera := Camera{position = {0.25, 0.25, 0.25}}
		camera_move_above_block(&test_camera, hit_block)
		log.assertf(
			test_camera.position[1] > world_y_from_block_top(hit_block.y),
			"camera terrain collision check: camera was not lifted above block",
		)

		lifted_block := block_coord_from_world_position(test_camera.position)
		_, lifted_hit := chunk_solid_block_at_world_block(&chunk, lifted_block).?
		log.assert(!lifted_hit, "camera terrain collision check: lifted camera still intersects")

		negative_chunk := chunk_create(ChunkCoord{-1, 0, -1})
		negative_storage := chunk_block_storage_alloc(state.transient_allocator)
		negative_index := chunk_block_index(CHUNK_BLOCK_LOCAL_MAX, 0, CHUNK_BLOCK_LOCAL_MAX)
		negative_storage.voxel_view.blocks.occupancy[negative_index] = .Solid
		negative_storage.voxel_view.blocks.material_id[negative_index] = BlockMaterialID(1)
		chunk_mark_generated(&negative_chunk, negative_storage)

		negative_hit_block, negative_hit := chunk_solid_block_at_world_block(
			&negative_chunk,
			BlockCoord{-1, 0, -1},
		).?
		log.assert(negative_hit, "camera terrain collision check: expected negative block hit")
		log.assertf(
			negative_hit_block == BlockCoord{-1, 0, -1},
			"camera terrain collision check: wrong negative hit block %v",
			negative_hit_block,
		)

		log.debug("Camera terrain collision checks passed")
	}

	debug_chunk_mesher_contract_checks_run :: proc() {
		temp := mem.begin_arena_temp_memory(&state.transient_arena)
		defer mem.end_arena_temp_memory(temp)

		view := ChunkVoxelView {
			blocks = make(
				#soa[]ChunkVoxelViewElement,
				CHUNK_BLOCK_COUNT,
				state.transient_allocator,
			),
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
			state.transient_allocator,
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
		view.blocks.material_id[index] = BlockMaterialID(5)

		edge_output := chunk_voxel_view_build_naive_mesh(
			view,
			.Treat_Out_Of_Chunk_As_Empty,
			state.transient_allocator,
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
		view.blocks.material_id[index] = BlockMaterialID(5)


		output := chunk_voxel_view_build_naive_mesh(
			view,
			.Treat_Out_Of_Chunk_As_Empty,
			state.transient_allocator,
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
		adjacent_pairs := [?][2]BlockCoord {
			{{1, 1, 1}, {2, 1, 1}},
			{{1, 1, 1}, {1, 2, 1}},
			{{1, 1, 1}, {1, 1, 2}},
		}

		for pair, pair_index in adjacent_pairs {
			chunk_voxel_view_fill_empty(&view)

			for block in pair {
				index = chunk_block_index(u32(block.x), u32(block.y), u32(block.z))
				view.blocks.occupancy[index] = .Solid
				view.blocks.material_id[index] = BlockMaterialID(1)
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
		left_view := ChunkVoxelView {
			blocks = make(
				#soa[]ChunkVoxelViewElement,
				CHUNK_BLOCK_COUNT,
				state.transient_allocator,
			),
		}
		right_view := ChunkVoxelView {
			blocks = make(
				#soa[]ChunkVoxelViewElement,
				CHUNK_BLOCK_COUNT,
				state.transient_allocator,
			),
		}
		chunk_voxel_view_fill_empty(&left_view)
		chunk_voxel_view_fill_empty(&right_view)

		left_index := chunk_block_index(CHUNK_BLOCK_LOCAL_MAX, 1, 1)
		left_view.blocks.occupancy[left_index] = .Solid
		left_view.blocks.material_id[left_index] = BlockMaterialID(7)

		right_index := chunk_block_index(0, 1, 1)
		right_view.blocks.occupancy[right_index] = .Solid
		right_view.blocks.material_id[right_index] = BlockMaterialID(7)

		left_snapshot := ChunkSnapshot {
			coord      = {0, 0, 0},
			voxel_view = left_view,
		}
		right_snapshot := ChunkSnapshot {
			coord      = {1, 0, 0},
			voxel_view = right_view,
		}
		neighbor_test_snapshots := [?]ChunkSnapshot{left_snapshot, right_snapshot}

		left_neighbor_output := chunk_mesh_job_execute_sync(
			{
				snapshot = left_snapshot,
				neighbors = chunk_mesh_neighbors_find(
					neighbor_test_snapshots[:],
					left_snapshot.coord,
				),
				boundary_policy = .Sample_Neighbor_Snapshots,
				output_allocator = state.transient_allocator,
			},
		)
		log.assertf(
			left_neighbor_output.face_count == 5,
			"left boundary block: expected 5 faces with +X neighbor, got %d",
			left_neighbor_output.face_count,
		)

		right_neighbor_output := chunk_mesh_job_execute_sync(
			{
				snapshot = right_snapshot,
				neighbors = chunk_mesh_neighbors_find(
					neighbor_test_snapshots[:],
					right_snapshot.coord,
				),
				boundary_policy = .Sample_Neighbor_Snapshots,
				output_allocator = state.transient_allocator,
			},
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
					view.blocks.material_id[index] = BlockMaterialID(2)
				}
			}
		}

		output = chunk_voxel_view_build_naive_mesh(
			view,
			.Treat_Out_Of_Chunk_As_Empty,
			state.transient_allocator,
		)
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
		chunk_voxel_debug_rect_view_builder(&view)

		rect_count := chunk_voxel_view_count_exposed_faces(view, .Treat_Out_Of_Chunk_As_Empty)
		log.assertf(rect_count == 1024, "debug rect: expected 1024 faces, got %d", rect_count)

		// full chunk: only six outer surfaces emit.
		chunk_voxel_view_fill_empty(&view)
		for z in 0 ..< CHUNK_BLOCK_LENGTH {
			for y in 0 ..< CHUNK_BLOCK_LENGTH {
				for x in 0 ..< CHUNK_BLOCK_LENGTH {
					index = chunk_block_index(u32(x), u32(y), u32(z))
					view.blocks.occupancy[index] = .Solid
					view.blocks.material_id[index] = BlockMaterialID(3)
				}
			}
		}

		output = chunk_voxel_view_build_naive_mesh(
			view,
			.Treat_Out_Of_Chunk_As_Empty,
			state.transient_allocator,
		)
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
						view.blocks.material_id[index] = BlockMaterialID(4)
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

		terrain_heightfield_voxel_view_fill(&view, ChunkCoord{0, 0, 0})
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
			state.transient_allocator,
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


///////////////////////////////////////////
// Terrain
///////////////////////////////////////////\

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

TerrainPackedVertex :: distinct u32
#assert(size_of(TerrainPackedVertex) == 4)

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

terrain_chunk_origin_world_from_coord :: proc(coord: ChunkCoord) -> Vec4 {
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
	normal_id, material_id, corner_id: u32,
) -> TerrainPackedVertex {
	log.assertf(block_x <= CHUNK_BLOCK_LOCAL_MAX, "terrain block_x out of range: %d", block_x)
	log.assertf(block_y <= CHUNK_BLOCK_LOCAL_MAX, "terrain block_y out of range: %d", block_y)
	log.assertf(block_z <= CHUNK_BLOCK_LOCAL_MAX, "terrain block_z out of range: %d", block_z)
	log.assertf(normal_id < 6, "terrain normal_id out of range: %d", normal_id)
	log.assertf(material_id <= 255, "terrain material_id out of range: %d", material_id)
	log.assertf(corner_id < 4, "terrain corner_id out of range: %d", corner_id)
	return TerrainPackedVertex(
		(block_x << TERRAIN_PACK_LOCAL_X_SHIFT) |
		(block_y << TERRAIN_PACK_LOCAL_Y_SHIFT) |
		(block_z << TERRAIN_PACK_LOCAL_Z_SHIFT) |
		(normal_id << TERRAIN_PACK_NORMAL_SHIFT) |
		(material_id << TERRAIN_PACK_MATERIAL_SHIFT) |
		(corner_id << TERRAIN_PACK_CORNER_SHIFT),
	)
}

terrain_unpack_vertex :: proc(vertex: TerrainPackedVertex) -> TerrainUnpackedVertex {
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
	vertices: []TerrainPackedVertex,
	indices: []u32,
	block_x, block_y, block_z: u32,
	normal_id: u32,
	material_id: u32,
	vertex_count: ^u32,
	index_count: ^u32,
) {
	log.assertf(int(vertex_count^) + 4 <= len(vertices), "terrain mesh vertex capacity exceeded")
	log.assertf(int(index_count^) + 6 <= len(indices), "terrain mesh index capacity exceeded")

	base := vertex_count^
	v := int(vertex_count^)
	i := int(index_count^)

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

	vertex_count^ += 4
	index_count^ += 6
}

terrain_heightfield_voxel_view_fill :: proc(view: ^ChunkVoxelView, chunk: ChunkCoord) {
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
				material_id := BlockMaterialID(TERRAIN_STONE_MAT_ID)
				if blocks_below_surface < TERRAIN_GRASS_CAP_BLOCK_DEPTH {
					material_id = BlockMaterialID(TERRAIN_GRASS_MAT_ID)
				} else if blocks_below_surface <
				   TERRAIN_GRASS_CAP_BLOCK_DEPTH + TERRAIN_DIRT_LAYER_BLOCK_DEPTH {
					material_id = BlockMaterialID(TERRAIN_DIRT_MAT_ID)
				}

				index := chunk_block_index(u32(x), u32(y), u32(z))
				view.blocks.occupancy[index] = .Solid
				view.blocks.material_id[index] = material_id
			}
		}
	}
}

///////////////////////////////////////////
// Geometry
///////////////////////////////////////////

INVALID_GEOMETRY_ID :: GeometryID(0)
GEOMETRY_MAX_GEOMETRIES :: 1024
GEOMETRY_MAX_POSITION_COLOR_VERTICES :: 2_000_000
GEOMETRY_MAX_VERTEX_BYTES :: GEOMETRY_MAX_POSITION_COLOR_VERTICES * size_of(PositionColorVertex)
GEOMETRY_MAX_INDEX_ELEMENTS :: 24_000_000
GEOMETRY_MAX_UPLOAD_POSITION_COLOR_VERTICES :: 65_536
GEOMETRY_MAX_VERTEX_UPLOAD_BYTES ::
	GEOMETRY_MAX_UPLOAD_POSITION_COLOR_VERTICES * size_of(PositionColorVertex)
GEOMETRY_MAX_UPLOAD_INDEX_ELEMENTS :: 196_608
GEOMETRY_VERTEX_BYTE_ALIGNMENT :: 4
GEOMETRY_ID_SLOT_BITS :: 16
GEOMETRY_ID_SLOT_MASK :: u32((1 << GEOMETRY_ID_SLOT_BITS) - 1)
GEOMETRY_ID_GENERATION_MASK :: u32(0xFFFF)
#assert(GEOMETRY_MAX_GEOMETRIES < 65535)

GeometryID :: distinct u32

GeometryLayoutKind :: enum u32 {
	Invalid,
	Position_Color_F32x4,
	Terrain_Packed_U32,
}

// Mesh.vert.hlsl decodes this layout by byte offsets.
PositionColorVertex :: struct {
	position: Vec4,
	color:    Vec4,
}
#assert(size_of(PositionColorVertex) == 32)

Geometry :: struct {
	layout_kind:         GeometryLayoutKind,
	vertex_allocation:   []byte,
	index_allocation:    []byte,
	vertex_byte_offset:  u32,
	vertex_stride_bytes: u32,
	vertex_count:        u32,
	first_index:         u32,
	index_count:         u32,
}

GeometrySlot :: struct {
	geometry:   Geometry,
	generation: u32,
	occupied:   bool,
}

GeometryDrawParams :: struct {
	vertex_byte_offset:  u32,
	vertex_stride_bytes: u32,
	_padding:            UVec2, // extra padding for alignment
}

GeometryPool :: struct {
	geometry_slots:              []GeometrySlot,
	geometry_count:              u32,
	vertex_range_tlsf:           mem_tlsf.Allocator,
	index_range_tlsf:            mem_tlsf.Allocator,
	vertex_range_allocator:      mem.Allocator,
	index_range_allocator:       mem.Allocator,
	vertex_buffer:               ^sdl.GPUBuffer,
	index_buffer:                ^sdl.GPUBuffer,
	vertex_upload_buffer:        ^sdl.GPUTransferBuffer,
	index_upload_buffer:         ^sdl.GPUTransferBuffer,
	vertex_byte_capacity:        u32,
	vertex_byte_count:           u32,
	index_element_capacity:      u32,
	index_element_count:         u32,
	vertex_upload_byte_capacity: u32,
	index_upload_byte_capacity:  u32,
}

geometry_layout_stride_bytes :: proc(layout_kind: GeometryLayoutKind) -> u32 {
	switch layout_kind {
	case GeometryLayoutKind.Position_Color_F32x4:
		return u32(size_of(PositionColorVertex))
	case GeometryLayoutKind.Terrain_Packed_U32:
		return u32(size_of(TerrainPackedVertex))
	case GeometryLayoutKind.Invalid:
		log.assertf(false, "unknown layout kind: %v", layout_kind)
	}
	return 0
}

geometry_init :: proc(
	pool: ^GeometryPool,
	max_geometries,
	max_vertices_bytes,
	max_indices_elements,
	max_upload_vertices_bytes,
	max_upload_indices_elements: u32,
) {
	log.assertf(
		max_geometries > 0 && max_geometries <= GEOMETRY_MAX_GEOMETRIES,
		"max_geometries must be in range 1..%d (got %d)",
		GEOMETRY_MAX_GEOMETRIES,
		max_geometries,
	)
	log.assertf(
		max_vertices_bytes > 0 && max_vertices_bytes <= GEOMETRY_MAX_VERTEX_BYTES,
		"max_vertex_bytes must be in range 1..%d (got %d)",
		GEOMETRY_MAX_VERTEX_BYTES,
		max_vertices_bytes,
	)
	log.assertf(
		max_indices_elements > 0 && max_indices_elements <= GEOMETRY_MAX_INDEX_ELEMENTS,
		"max_index_elements must be in range 1..%d (got %d)",
		GEOMETRY_MAX_INDEX_ELEMENTS,
		max_indices_elements,
	)
	log.assertf(
		max_upload_vertices_bytes > 0 &&
		max_upload_vertices_bytes <= GEOMETRY_MAX_VERTEX_UPLOAD_BYTES,
		"max_upload_vertex_bytes must be in range 1..%d (got %d)",
		GEOMETRY_MAX_VERTEX_UPLOAD_BYTES,
		max_upload_vertices_bytes,
	)
	log.assertf(
		max_upload_indices_elements > 0 &&
		max_upload_indices_elements <= GEOMETRY_MAX_UPLOAD_INDEX_ELEMENTS,
		"max_upload_index_elements must be in range 1..%d (got %d)",
		GEOMETRY_MAX_UPLOAD_INDEX_ELEMENTS,
		max_upload_indices_elements,
	)
	log.assertf(
		max_upload_vertices_bytes <= max_vertices_bytes,
		"max_upload_vertex_bytes must fit inside max_vertex_bytes",
	)
	log.assertf(
		max_upload_indices_elements <= max_indices_elements,
		"max_upload_index_elements must fit inside max_index_elements",
	)

	index_upload_size_wide := u64(max_upload_indices_elements) * u64(size_of(u32))
	index_range_size_wide := u64(max_indices_elements) * u64(size_of(u32))

	log.assertf(
		index_range_size_wide <= u64(max(int)),
		"index buffer size exceeds u32: %d",
		index_range_size_wide,
	)
	log.assertf(
		index_upload_size_wide <= u64(max(u32)),
		"index upload buffer size exceeds u32: %d",
		index_upload_size_wide,
	)

	pool^ = GeometryPool{}
	pool.geometry_slots = make([]GeometrySlot, max_geometries)
	for idx in 0 ..< len(pool.geometry_slots) {
		pool.geometry_slots[idx].generation = 1
	}

	tlsf_err := mem_tlsf.init(
		&pool.vertex_range_tlsf,
		runtime.default_allocator(),
		int(max_vertices_bytes),
		0,
	)
	log.assertf(tlsf_err == .None, "vertex range TLSF init failed: %v", tlsf_err)
	tlsf_err = mem_tlsf.init(
		&pool.index_range_tlsf,
		runtime.default_allocator(),
		int(index_range_size_wide),
		0,
	)
	log.assertf(tlsf_err == .None, "index range TLSF init failed: %v", tlsf_err)

	pool.vertex_range_allocator = mem_tlsf.allocator(&pool.vertex_range_tlsf)
	pool.index_range_allocator = mem_tlsf.allocator(&pool.index_range_tlsf)

	vertex_buffer_size_wide := u64(len(pool.vertex_range_tlsf.pool.data))
	index_buffer_size_wide := u64(len(pool.index_range_tlsf.pool.data))
	log.assertf(
		vertex_buffer_size_wide <= u64(max(u32)),
		"vertex buffer size exceeds u32: %d",
		vertex_buffer_size_wide,
	)
	log.assertf(
		index_buffer_size_wide <= u64(max(u32)),
		"index buffer size exceeds u32: %d",
		index_buffer_size_wide,
	)

	vertex_buffer_size := u32(vertex_buffer_size_wide)
	index_buffer_size := u32(index_buffer_size_wide)
	vertex_upload_size := max_upload_vertices_bytes
	index_upload_size := u32(index_upload_size_wide)

	pool.vertex_byte_capacity = vertex_buffer_size
	pool.index_element_capacity = index_buffer_size / u32(size_of(u32))
	pool.vertex_upload_byte_capacity = vertex_upload_size
	pool.index_upload_byte_capacity = index_upload_size

	pool.vertex_buffer = sdl.CreateGPUBuffer(
		state.device,
		sdl.GPUBufferCreateInfo {
			// Read by Mesh.vert as ByteAddressBuffer for programmable vertex pulling.
			usage = {.GRAPHICS_STORAGE_READ},
			size  = vertex_buffer_size,
		},
	)
	log.assertf(pool.vertex_buffer != nil, "CreateGPUBuffer vertex failed: %s", sdl.GetError())

	pool.index_buffer = sdl.CreateGPUBuffer(
	state.device,
	sdl.GPUBufferCreateInfo {
		// Keep this as a real SDL index buffer so indexed draws and vertex reuse still work.
		usage = {.INDEX},
		size  = index_buffer_size,
	},
	)
	log.assertf(pool.index_buffer != nil, "CreateGPUBuffer index failed: %s", sdl.GetError())


	pool.vertex_upload_buffer = sdl.CreateGPUTransferBuffer(
		state.device,
		sdl.GPUTransferBufferCreateInfo {
			usage = sdl.GPUTransferBufferUsage.UPLOAD,
			size = pool.vertex_upload_byte_capacity,
		},
	)
	log.assertf(
		pool.vertex_upload_buffer != nil,
		"CreateGPUTransferBuffer for vertex upload failed: %s",
		sdl.GetError(),
	)

	pool.index_upload_buffer = sdl.CreateGPUTransferBuffer(
		state.device,
		sdl.GPUTransferBufferCreateInfo {
			usage = sdl.GPUTransferBufferUsage.UPLOAD,
			size = pool.index_upload_byte_capacity,
		},
	)
	log.assertf(
		pool.index_upload_buffer != nil,
		"CreateGPUTransferBuffer for index upload failed: %s",
		sdl.GetError(),
	)

	log.debugf(
		"GeometryPool initialized: vertex_byte_capacity=%d index_element_capacity=%d vertex_upload_byte_capacity=%d index_upload_byte_capacity=%d",
		pool.vertex_byte_capacity,
		pool.index_element_capacity,
		pool.vertex_upload_byte_capacity,
		pool.index_upload_byte_capacity,
	)
}

geometry_destroy :: proc(pool: ^GeometryPool) {
	if pool.vertex_upload_buffer != nil {
		sdl.ReleaseGPUTransferBuffer(state.device, pool.vertex_upload_buffer)
	}

	if pool.index_upload_buffer != nil {
		sdl.ReleaseGPUTransferBuffer(state.device, pool.index_upload_buffer)
	}

	if pool.vertex_buffer != nil {
		sdl.ReleaseGPUBuffer(state.device, pool.vertex_buffer)
	}

	if pool.index_buffer != nil {
		sdl.ReleaseGPUBuffer(state.device, pool.index_buffer)
	}

	mem_tlsf.destroy(&pool.vertex_range_tlsf)
	mem_tlsf.destroy(&pool.index_range_tlsf)

	pool.geometry_slots = nil
	pool.geometry_count = 0
	pool.vertex_byte_capacity = 0
	pool.vertex_byte_count = 0
	pool.index_element_capacity = 0
	pool.index_element_count = 0
	pool.vertex_upload_byte_capacity = 0
	pool.index_upload_byte_capacity = 0
}

geometry_id_from_slot :: proc(slot_index, generation: u32) -> GeometryID {
	log.assertf(slot_index < GEOMETRY_ID_SLOT_MASK, "geometry slot index exceeds ID range: %d", slot_index)
	log.assertf(generation > 0 && generation <= GEOMETRY_ID_GENERATION_MASK, "invalid geometry generation: %d", generation)
	return GeometryID((generation << GEOMETRY_ID_SLOT_BITS) | (slot_index + 1))
}

geometry_id_slot_index :: proc(id: GeometryID) -> u32 {
	slot_number := u32(id) & GEOMETRY_ID_SLOT_MASK
	log.assertf(slot_number > 0, "Invalid geometry ID: %d", u32(id))
	return slot_number - 1
}

geometry_id_generation :: proc(id: GeometryID) -> u32 {
	return u32(id) >> GEOMETRY_ID_SLOT_BITS
}

geometry_slot_generation_advance :: proc(slot: ^GeometrySlot) {
	slot.generation = (slot.generation + 1) & GEOMETRY_ID_GENERATION_MASK
	if slot.generation == 0 {
		slot.generation = 1
	}
}

geometry_slot_get :: proc(pool: ^GeometryPool, id: GeometryID) -> ^GeometrySlot {
	log.assertf(id != INVALID_GEOMETRY_ID, "Invalid geometry ID: %d", u32(id))

	slot_index := geometry_id_slot_index(id)
	log.assertf(slot_index < u32(len(pool.geometry_slots)), "Geometry ID out of bounds: %d", u32(id))

	slot := &pool.geometry_slots[slot_index]
	log.assertf(slot.occupied, "Geometry ID refers to a free slot: %d", u32(id))
	log.assertf(
		slot.generation == geometry_id_generation(id),
		"Geometry ID generation mismatch: id=%d slot_generation=%d",
		geometry_id_generation(id),
		slot.generation,
	)
	return slot
}

geometry_find_free_slot :: proc(pool: ^GeometryPool) -> (slot_index: u32, ok: bool) {
	for idx in 0 ..< len(pool.geometry_slots) {
		if !pool.geometry_slots[idx].occupied {
			return u32(idx), true
		}
	}
	return 0, false
}

geometry_range_byte_offset :: proc(range, backing: []byte) -> u32 {
	log.assertf(len(range) > 0, "geometry range must not be empty")
	range_start := uintptr(raw_data(range))
	backing_start := uintptr(raw_data(backing))
	log.assertf(range_start >= backing_start, "geometry range starts before backing storage")

	offset_wide := u64(range_start - backing_start)
	end_wide := offset_wide + u64(len(range))
	log.assertf(end_wide <= u64(len(backing)), "geometry range exceeds backing storage")
	log.assertf(offset_wide <= u64(max(u32)), "geometry range offset exceeds u32: %d", offset_wide)
	return u32(offset_wide)
}

geometry_alloc :: proc(
	pool: ^GeometryPool,
	layout_kind: GeometryLayoutKind,
	vertex_byte_count: u32,
	vertex_count: u32,
	vertex_stride_bytes: u32,
	index_count: u32,
) -> GeometryID {
	log.assertf(pool != nil, "pool is nil")
	log.assertf(layout_kind != .Invalid, "layout_kind must be valid")
	log.assertf(vertex_byte_count > 0, "vertex_byte_count must not be zero")
	log.assertf(vertex_count > 0, "vertex_count must not be zero")
	log.assertf(vertex_stride_bytes > 0, "vertex_stride_bytes must not be zero")
	log.assertf(index_count > 0, "index_count must not be zero")
	log.assertf(
		vertex_stride_bytes % GEOMETRY_VERTEX_BYTE_ALIGNMENT == 0,
		"vertex_stride_bytes must be aligned to %d bytes",
		GEOMETRY_VERTEX_BYTE_ALIGNMENT,
	)
	log.assertf(
		geometry_layout_stride_bytes(layout_kind) == vertex_stride_bytes,
		"vertex_stride_bytes must match layout kind",
	)

	index_bytes_wide := u64(index_count) * u64(size_of(u32))
	log.assertf(index_bytes_wide <= u64(max(int)), "index allocation size exceeds int: %d", index_bytes_wide)

	vertex_allocation, vertex_err := mem.alloc_bytes_non_zeroed(
		int(vertex_byte_count),
		GEOMETRY_VERTEX_BYTE_ALIGNMENT,
		pool.vertex_range_allocator,
	)
	log.assertf(vertex_err == nil, "geometry vertex range allocation failed: %v", vertex_err)

	index_allocation, index_err := mem.alloc_bytes_non_zeroed(
		int(index_bytes_wide),
		align_of(u32),
		pool.index_range_allocator,
	)
	if index_err != nil {
		free_err := mem.free_bytes(vertex_allocation, pool.vertex_range_allocator)
		log.assertf(free_err == nil, "geometry vertex range rollback failed: %v", free_err)
		log.assertf(false, "geometry index range allocation failed: %v", index_err)
	}

	slot_index, slot_ok := geometry_find_free_slot(pool)
	if !slot_ok {
		vertex_free_err := mem.free_bytes(vertex_allocation, pool.vertex_range_allocator)
		index_free_err := mem.free_bytes(index_allocation, pool.index_range_allocator)
		log.assertf(vertex_free_err == nil, "geometry vertex range rollback failed: %v", vertex_free_err)
		log.assertf(index_free_err == nil, "geometry index range rollback failed: %v", index_free_err)
		log.assertf(false, "geometry pool is full")
	}

	vertex_byte_offset := geometry_range_byte_offset(vertex_allocation, pool.vertex_range_tlsf.pool.data)
	index_byte_offset := geometry_range_byte_offset(index_allocation, pool.index_range_tlsf.pool.data)
	log.assertf(index_byte_offset % u32(size_of(u32)) == 0, "index range offset must be u32-aligned")

	slot := &pool.geometry_slots[slot_index]
	id := geometry_id_from_slot(slot_index, slot.generation)
	slot.geometry = Geometry {
		layout_kind         = layout_kind,
		vertex_allocation   = vertex_allocation,
		index_allocation    = index_allocation,
		vertex_byte_offset  = vertex_byte_offset,
		vertex_stride_bytes = vertex_stride_bytes,
		vertex_count        = vertex_count,
		first_index         = index_byte_offset / u32(size_of(u32)),
		index_count         = index_count,
	}
	slot.occupied = true

	pool.geometry_count += 1
	pool.vertex_byte_count += vertex_byte_count
	pool.index_element_count += index_count

	return id
}

geometry_release :: proc(pool: ^GeometryPool, id: GeometryID) {
	if id == INVALID_GEOMETRY_ID {
		return
	}

	slot := geometry_slot_get(pool, id)
	geometry := slot.geometry

	if state.device != nil {
		log.assertf(sdl.WaitForGPUIdle(state.device), "WaitForGPUIdle before geometry release failed: %s", sdl.GetError())
	}

	vertex_free_err := mem.free_bytes(geometry.vertex_allocation, pool.vertex_range_allocator)
	index_free_err := mem.free_bytes(geometry.index_allocation, pool.index_range_allocator)
	log.assertf(vertex_free_err == nil, "geometry vertex range release failed: %v", vertex_free_err)
	log.assertf(index_free_err == nil, "geometry index range release failed: %v", index_free_err)
	log.assertf(pool.vertex_byte_count >= u32(len(geometry.vertex_allocation)), "geometry vertex byte count underflow")
	log.assertf(pool.index_element_count >= geometry.index_count, "geometry index count underflow")
	log.assertf(pool.geometry_count > 0, "geometry count underflow")

	pool.vertex_byte_count -= u32(len(geometry.vertex_allocation))
	pool.index_element_count -= geometry.index_count
	pool.geometry_count -= 1

	slot.geometry = {}
	slot.occupied = false
	geometry_slot_generation_advance(slot)
}

geometry_upload_bytes :: proc(
	pool: ^GeometryPool,
	id: GeometryID,
	vertex_data: rawptr,
	vertex_byte_count: u32,
	indices: []u32,
) {
	geometry := geometry_get(pool, id)

	index_count := u32(len(indices))
	index_bytes_wide := u64(index_count) * u64(size_of(u32))
	log.assertf(index_bytes_wide <= u64(max(u32)), "index upload size exceeds u32: %d", index_bytes_wide)
	index_bytes := u32(index_bytes_wide)

	log.assertf(vertex_byte_count == u32(len(geometry.vertex_allocation)), "vertex upload size mismatch")
	log.assertf(index_bytes == u32(len(geometry.index_allocation)), "index upload size mismatch")
	log.assertf(vertex_byte_count <= pool.vertex_upload_byte_capacity, "geometry vertex append exceeds upload buffer capacity")
	log.assertf(index_bytes <= pool.index_upload_byte_capacity, "geometry index append exceeds upload buffer capacity")

	vertex_dst_offset := geometry.vertex_byte_offset
	index_dst_offset_wide := u64(geometry.first_index) * u64(size_of(u32))
	log.assertf(index_dst_offset_wide <= u64(max(u32)), "index destination offset exceeds u32: %d", index_dst_offset_wide)
	index_dst_offset := u32(index_dst_offset_wide)

	// Upload command buffers execute asynchronously; cycle the reused staging buffer
	// so a later chunk upload cannot overwrite source bytes still in flight.
	mapped_data := sdl.MapGPUTransferBuffer(state.device, pool.vertex_upload_buffer, true)
	log.assertf(mapped_data != nil, "MapGPUTransferBuffer vertex failed: %s", sdl.GetError())
	mem.copy(mapped_data, vertex_data, int(vertex_byte_count))
	sdl.UnmapGPUTransferBuffer(state.device, pool.vertex_upload_buffer)

	mapped_data = sdl.MapGPUTransferBuffer(state.device, pool.index_upload_buffer, true)
	log.assertf(mapped_data != nil, "MapGPUTransferBuffer index failed: %s", sdl.GetError())
	mem.copy(mapped_data, raw_data(indices), int(index_bytes))
	sdl.UnmapGPUTransferBuffer(state.device, pool.index_upload_buffer)

	upload_cmd_buf := sdl.AcquireGPUCommandBuffer(state.device)
	log.assertf(upload_cmd_buf != nil, "AcquireGPUCommandBuffer failed: %s", sdl.GetError())
	copy_pass := sdl.BeginGPUCopyPass(upload_cmd_buf)

	sdl.UploadToGPUBuffer(
		copy_pass,
		sdl.GPUTransferBufferLocation{transfer_buffer = pool.vertex_upload_buffer, offset = 0},
		sdl.GPUBufferRegion {
			buffer = pool.vertex_buffer,
			offset = vertex_dst_offset,
			size = vertex_byte_count,
		},
		false,
	)

	sdl.UploadToGPUBuffer(
		copy_pass,
		sdl.GPUTransferBufferLocation{transfer_buffer = pool.index_upload_buffer, offset = 0},
		sdl.GPUBufferRegion {
			buffer = pool.index_buffer,
			offset = index_dst_offset,
			size = index_bytes,
		},
		false,
	)

	sdl.EndGPUCopyPass(copy_pass)
	log.assertf(
		sdl.SubmitGPUCommandBuffer(upload_cmd_buf),
		"SubmitGPUCommandBuffer failed: %s",
		sdl.GetError(),
	)
}

geometry_append_bytes :: proc(
	pool: ^GeometryPool,
	layout_kind: GeometryLayoutKind,
	vertex_data: rawptr,
	vertex_byte_count: u32,
	vertex_count: u32,
	vertex_stride_bytes: u32,
	indices: []u32,
) -> GeometryID {
	log.assertf(vertex_data != nil, "vertex_data must not be nil")
	log.assertf(len(indices) > 0, "indices must not be empty")
	log.assertf(u64(len(indices)) <= u64(max(u32)), "index count exceeds u32: %d", len(indices))

	index_count := u32(len(indices))
	when ODIN_DEBUG {
		for vertex_index, index_index in indices {
			log.assertf(
				vertex_index < vertex_count,
				"geometry index out of range: indices[%d]=%d vertex_count=%d",
				index_index,
				vertex_index,
				vertex_count,
			)
		}
	}

	vertex_bytes_wide := u64(vertex_count) * u64(vertex_stride_bytes)
	log.assertf(
		vertex_bytes_wide <= u64(max(u32)),
		"vertex append size exceeds u32: %d",
		vertex_bytes_wide,
	)
	log.assertf(
		vertex_bytes_wide == u64(vertex_byte_count),
		"vertex_byte_count must match vertex_count and vertex_stride_bytes",
	)

	id := geometry_alloc(
		pool,
		layout_kind,
		vertex_byte_count,
		vertex_count,
		vertex_stride_bytes,
		index_count,
	)
	geometry_upload_bytes(pool, id, vertex_data, vertex_byte_count, indices)

	return id
}

geometry_append_chunk_mesh_output :: proc(
	pool: ^GeometryPool,
	output: ChunkMeshOutput,
) -> GeometryID {
	log.assertf(pool != nil, "pool is nil")

	if output.face_count == 0 {
		return INVALID_GEOMETRY_ID
	}

	log.assertf(
		output.face_count <= max(u32) / 4,
		"chunk mesh output vertex count would overflow: %d faces",
		output.face_count,
	)
	log.assertf(
		output.face_count <= max(u32) / 6,
		"chunk mesh output index count would overflow: %d faces",
		output.face_count,
	)

	vertex_count := output.face_count * 4
	index_count := output.face_count * 6

	log.assertf(
		len(output.vertices) == int(vertex_count),
		"chunk mesh output vertex count mismatch",
	)
	log.assertf(len(output.indices) == int(index_count), "chunk mesh output index count mismatch")

	stride := geometry_layout_stride_bytes(.Terrain_Packed_U32)
	vertex_byte_count := vertex_count * stride

	return geometry_append_bytes(
		pool,
		.Terrain_Packed_U32,
		raw_data(output.vertices),
		vertex_byte_count,
		vertex_count,
		stride,
		output.indices,
	)
}

geometry_replace :: proc(pool: ^GeometryPool, old_id: GeometryID, output: ChunkMeshOutput) -> GeometryID {
	if output.face_count == 0 {
		geometry_release(pool, old_id)
		return INVALID_GEOMETRY_ID
	}

	new_id := geometry_append_chunk_mesh_output(pool, output)
	geometry_release(pool, old_id)
	return new_id
}

geometry_get :: proc(pool: ^GeometryPool, id: GeometryID) -> Geometry {
	return geometry_slot_get(pool, id).geometry
}

//////////////////////////////////////
// Helpers
/////////////////////////////////////

sdl_log_output :: proc "c" (
	userdata: rawptr,
	category: sdl.LogCategory,
	priority: sdl.LogPriority,
	message: cstring,
) {
	context = runtime.default_context()

	level := log.Level.Debug
	#partial switch priority {
	case .INFO:
		level = .Info
	case .WARN:
		level = .Warning
	case .ERROR:
		level = .Error
	case .CRITICAL:
		level = .Fatal
	}

	log.logf(level, "[SDL:%s] %s", category, cast(string)message)
}

//////////////////////////////////////
// Graphics
/////////////////////////////////////

ShaderType :: enum {
	Vertex,
	Fragment,
}

gfx_load_shader :: proc(
	filename: string,
	sampler_count: u32,
	uniform_buffer_count: u32,
	storage_buffer_count: u32,
	storage_texture_count: u32,
) -> (
	^sdl.GPUShader,
	ShaderType,
) {
	log.debugf("Loading shader: %s", filename)

	shader_type: ShaderType
	if strings.contains(
		filename,
		".vert.dxil",
	) {shader_type = ShaderType.Vertex} else if strings.contains(filename, ".frag.dxil") {shader_type = ShaderType.Fragment} else {
		log.assertf(false, "Unknown shader type: %s", filename)
	}

	temp := mem.begin_arena_temp_memory(&state.transient_arena)
	defer mem.end_arena_temp_memory(temp)

	code, err := os.read_entire_file_from_path(filename, state.transient_allocator)
	log.assertf(err == nil, "Failed to read shader: %s", err)
	log.assertf(len(code) > 0, "Shader file is empty: %s", filename)

	code_size: uint = len(code)
	code_data := ([^]sdl.Uint8)(raw_data(code))

	stage: sdl.GPUShaderStage
	if shader_type == ShaderType.Fragment {
		stage = sdl.GPUShaderStage.FRAGMENT
	} else if shader_type == ShaderType.Vertex {
		stage = sdl.GPUShaderStage.VERTEX
	} else {
		log.assertf(false, "Unknown shader type: %s", filename)
	}

	shader_info := sdl.GPUShaderCreateInfo {
		code                 = code_data,
		code_size            = code_size,
		entrypoint           = "main",
		format               = {.DXIL},
		stage                = stage,
		num_samplers         = sampler_count,
		num_uniform_buffers  = uniform_buffer_count,
		num_storage_buffers  = storage_buffer_count,
		num_storage_textures = storage_texture_count,
	}
	shader := sdl.CreateGPUShader(state.device, shader_info)
	log.assertf(shader != nil, "Failed to create shader: %s", sdl.GetError())

	log.debugf("Shader %s created: %s", shader_type, filename)

	return shader, shader_type
}

gfx_create_pipelines_fill_and_line :: proc(
	vert_shader: ^sdl.GPUShader,
	frag_shader: ^sdl.GPUShader,
	fill_pipeline: ^^sdl.GPUGraphicsPipeline,
	line_pipeline: ^^sdl.GPUGraphicsPipeline,
) {
	color_target_descriptions := [?]sdl.GPUColorTargetDescription {
		{format = sdl.GetGPUSwapchainTextureFormat(state.device, state.window)},
	}

	pipeline_create_info := sdl.GPUGraphicsPipelineCreateInfo {
		target_info = {
			num_color_targets = 1,
			color_target_descriptions = raw_data(color_target_descriptions[:]),
			has_depth_stencil_target = true,
			depth_stencil_format = sdl.GPUTextureFormat.D16_UNORM,
		},
		depth_stencil_state = sdl.GPUDepthStencilState {
			enable_depth_test = true,
			enable_depth_write = true,
			enable_stencil_test = false,
			compare_op = sdl.GPUCompareOp.LESS,
			write_mask = 0xFF,
		},
		rasterizer_state = sdl.GPURasterizerState {
			cull_mode = sdl.GPUCullMode.BACK,
			fill_mode = sdl.GPUFillMode.FILL,
			front_face = sdl.GPUFrontFace.COUNTER_CLOCKWISE,
		},
		primitive_type = sdl.GPUPrimitiveType.TRIANGLELIST,
		vertex_shader = vert_shader,
		fragment_shader = frag_shader,
	}

	pipeline_create_info.rasterizer_state.fill_mode = sdl.GPUFillMode.FILL
	fill_pipeline^ = sdl.CreateGPUGraphicsPipeline(state.device, pipeline_create_info)
	log.assertf(fill_pipeline^ != nil, "Failed to create fill pipeline: %s", sdl.GetError())

	pipeline_create_info.rasterizer_state.fill_mode = sdl.GPUFillMode.LINE
	line_pipeline^ = sdl.CreateGPUGraphicsPipeline(state.device, pipeline_create_info)
	log.assertf(line_pipeline^ != nil, "Failed to create line pipeline: %s", sdl.GetError())
}

gfx_render :: proc() {
	cmdbuf := sdl.AcquireGPUCommandBuffer(state.device)
	log.assertf(cmdbuf != nil, "AcquireGPUCommandBuffer failed: %s", sdl.GetError())

	swapchain_texture: ^sdl.GPUTexture
	log.assertf(
		sdl.WaitAndAcquireGPUSwapchainTexture(cmdbuf, state.window, &swapchain_texture, nil, nil),
		"WaitAndAcquireGPUSwapchainTexture failed: %s",
		sdl.GetError(),
	)

	if (swapchain_texture != nil) {
		frustum := frustum_from_camera(state.camera, math.to_radians_f32(FOV), ASPECT_RATIO)

		colorTargetInfo := sdl.GPUColorTargetInfo{}
		colorTargetInfo.texture = swapchain_texture
		colorTargetInfo.clear_color = sdl.FColor{0.05, 0.10, 0.20, 1.0}
		colorTargetInfo.load_op = sdl.GPULoadOp.CLEAR
		colorTargetInfo.store_op = sdl.GPUStoreOp.STORE

		depthTargetInfo := sdl.GPUDepthStencilTargetInfo{}
		depthTargetInfo.texture = state.depth_texture
		depthTargetInfo.clear_depth = DEPTH_CLEAR_VALUE
		depthTargetInfo.load_op = sdl.GPULoadOp.CLEAR
		depthTargetInfo.store_op = sdl.GPUStoreOp.DONT_CARE
		depthTargetInfo.stencil_load_op = sdl.GPULoadOp.DONT_CARE
		depthTargetInfo.stencil_store_op = sdl.GPUStoreOp.DONT_CARE

		render_pass := sdl.BeginGPURenderPass(cmdbuf, &colorTargetInfo, 1, &depthTargetInfo)

		// Hardware indexed PVP: SDL applies the index buffer, then the selected vertex
		// shader pulls bytes from the shared geometry storage buffer.
		storage_buffers := [?]^sdl.GPUBuffer{state.geometry_pool.vertex_buffer}
		sdl.BindGPUVertexStorageBuffers(render_pass, 0, raw_data(storage_buffers[:]), 1)
		sdl.BindGPUIndexBuffer(
			render_pass,
			sdl.GPUBufferBinding{buffer = state.geometry_pool.index_buffer, offset = 0},
			sdl.GPUIndexElementSize._32BIT,
		)

		for slot in state.geometry_pool.geometry_slots {
			if !slot.occupied {
				continue
			}

			geometry := slot.geometry
			if geometry.layout_kind != .Position_Color_F32x4 {
				continue
			}

			sdl.PushGPUVertexUniformData(cmdbuf, 0, &state.mvp, cast(u32)size_of(matrix[4, 4]f32))
			draw_params := GeometryDrawParams {
				vertex_byte_offset  = geometry.vertex_byte_offset,
				vertex_stride_bytes = geometry.vertex_stride_bytes,
			}
			sdl.PushGPUVertexUniformData(
				cmdbuf,
				1,
				&draw_params,
				cast(u32)size_of(GeometryDrawParams),
			)

			pipeline :=
				state.use_wireframe_mode ? state.prototype_line_pipeline : state.prototype_fill_pipeline
			sdl.BindGPUGraphicsPipeline(render_pass, pipeline)
			sdl.DrawGPUIndexedPrimitives(
				render_pass,
				geometry.index_count,
				1,
				geometry.first_index,
				0,
				0,
			)
		}

		for chunk in state.chunk_store.chunks[:state.chunk_store.chunk_count] {
			state.chunks_total += 1

			if chunk.geometry_id == INVALID_GEOMETRY_ID {
				state.chunks_without_geometry += 1
				continue
			}

			aabb := chunk_world_get_aabb(chunk.coord)
			if !frustum_test_aabb(frustum, aabb) {
				state.chunks_frustum_culled += 1
				continue
			}

			geometry := geometry_get(&state.geometry_pool, chunk.geometry_id)
			log.assertf(
				geometry.layout_kind == .Terrain_Packed_U32,
				"chunk geometry must use terrain layout: %v",
				geometry.layout_kind,
			)

			sdl.PushGPUVertexUniformData(
				cmdbuf,
				0,
				&state.view_projection,
				cast(u32)size_of(matrix[4, 4]f32),
			)
			chunk_origin_world := terrain_chunk_origin_world_from_coord(chunk.coord)
			draw_params := TerrainDrawParams {
				vertex_byte_offset  = geometry.vertex_byte_offset,
				vertex_stride_bytes = geometry.vertex_stride_bytes,
				chunk_origin        = chunk_origin_world,
			}
			sdl.PushGPUVertexUniformData(
				cmdbuf,
				1,
				&draw_params,
				cast(u32)size_of(TerrainDrawParams),
			)

			pipeline :=
				state.use_wireframe_mode ? state.terrain_line_pipeline : state.terrain_fill_pipeline
			sdl.BindGPUGraphicsPipeline(render_pass, pipeline)
			sdl.DrawGPUIndexedPrimitives(
				render_pass,
				geometry.index_count,
				1,
				geometry.first_index,
				0,
				0,
			)

			state.terrain_faces_drawn += geometry.index_count / 6
			state.terrain_indices_drawn += geometry.index_count

			state.chunks_drawn += 1
		}

		sdl.EndGPURenderPass(render_pass)
	}

	log.assertf(sdl.SubmitGPUCommandBuffer(cmdbuf), "SubmitGPUCommandBuffer: %s", sdl.GetError())

	state.prev_chunks_total = state.chunks_total
	state.prev_chunks_without_geometry = state.chunks_without_geometry
	state.prev_chunks_frustum_culled = state.chunks_frustum_culled
	state.prev_chunks_drawn = state.chunks_drawn
	state.prev_terrain_faces_drawn = state.terrain_faces_drawn
	state.prev_terrain_indices_drawn = state.terrain_indices_drawn
	state.prev_chunks_generated = state.chunks_generated
	state.prev_chunk_mesh_jobs_submitted = state.chunk_mesh_jobs_submitted
	state.prev_chunk_mesh_results_committed = state.chunk_mesh_results_committed
	state.prev_chunk_mesh_results_uploaded = state.chunk_mesh_results_uploaded
	state.prev_chunks_dirty_remaining = state.chunks_dirty_remaining
	state.prev_chunks_evicted = state.chunks_evicted

	state.chunks_total = 0
	state.chunks_without_geometry = 0
	state.chunks_frustum_culled = 0
	state.chunks_drawn = 0
	state.terrain_faces_drawn = 0
	state.terrain_indices_drawn = 0
	state.chunks_generated = 0
	state.chunk_mesh_jobs_submitted = 0
	state.chunk_mesh_results_committed = 0
	state.chunk_mesh_results_uploaded = 0
	state.chunks_dirty_remaining = 0
	state.chunks_evicted = 0
}

//////////////////////////////////////
// Systems
/////////////////////////////////////

init :: proc() {
	log.debug("Init application")

	log.assertf(sdl.Init({.VIDEO}), "Failed to initialize SDL: %s", sdl.GetError())

	state.device = sdl.CreateGPUDevice({.DXIL}, state.debug_mode, nil)
	log.assertf(state.device != nil, "Failed to create GPU device: %s", sdl.GetError())

	state.window = sdl.CreateWindow(
		"Voxels Engine",
		WINDOW_DEFAULT_WIDTH,
		WINDOW_DEFAULT_HEIGHT,
		{.RESIZABLE},
	)
	log.assertf(state.window != nil, "Failed to create window: %s", sdl.GetError())
	log.assertf(
		sdl.SetWindowRelativeMouseMode(state.window, true),
		"Failed to enable relative mouse mode: %s",
		sdl.GetError(),
	)

	log.assertf(
		sdl.ClaimWindowForGPUDevice(state.device, state.window),
		"Failed to claim window for GPU device: %s",
		sdl.GetError(),
	)

	log.assertf(
		sdl.SetGPUSwapchainParameters(
			state.device,
			state.window,
			sdl.GPUSwapchainComposition.SDR,
			state.enable_vsync ? sdl.GPUPresentMode.VSYNC : sdl.GPUPresentMode.IMMEDIATE,
		),
		"Failed to set GPU swapchain parameters: %s",
		sdl.GetError(),
	)

	sdl.SetLogOutputFunction(sdl_log_output, nil)
	sdl.SetLogPriority(.GPU, .DEBUG)

	state.chunk_mesh_worker_arena_pool = arena_pool_init(
		CHUNK_MESH_WORKER_COUNT,
		CHUNK_MESH_WORKER_ARENA_BYTES,
	)

	log.debug("Application initialized")
}

shutdown :: proc() {
	log.debug("Application shutdown")
	sdl.ReleaseWindowFromGPUDevice(state.device, state.window)
	sdl.DestroyGPUDevice(state.device)
	sdl.DestroyWindow(state.window)
	sdl.Quit()
	log.debug("Shutdown complete")
}

setup_resources :: proc() {
	log.debug("Setting resources")

	geometry_init(
		&state.geometry_pool,
		GEOMETRY_MAX_GEOMETRIES,
		GEOMETRY_MAX_VERTEX_BYTES,
		GEOMETRY_MAX_INDEX_ELEMENTS,
		GEOMETRY_MAX_VERTEX_UPLOAD_BYTES,
		GEOMETRY_MAX_UPLOAD_INDEX_ELEMENTS,
	)

	// todo: this should be removed later after testing is done
	// Mesh.vert uses one vertex storage buffer for PVP geometry bytes.
	// Indices are bound through SDL's hardware index-buffer path, not as shader storage.
	vert_shader, _ := gfx_load_shader("assets/shaders/Mesh.vert.dxil", 0, 2, 1, 0)
	frag_shader, _ := gfx_load_shader("assets/shaders/SolidColor.frag.dxil", 0, 0, 0, 0)

	// new shaders for terrain rendering, will be the primary rendering pipeline for terrain geometry
	terrain_vert_shader, _ := gfx_load_shader("assets/shaders/Terrain.vert.dxil", 0, 2, 1, 0)
	terrain_frag_shader, _ := gfx_load_shader("assets/shaders/Terrain.frag.dxil", 0, 0, 0, 0)

	// Create the pipelines
	gfx_create_pipelines_fill_and_line(
		vert_shader,
		frag_shader,
		&state.prototype_fill_pipeline,
		&state.prototype_line_pipeline,
	)
	gfx_create_pipelines_fill_and_line(
		terrain_vert_shader,
		terrain_frag_shader,
		&state.terrain_fill_pipeline,
		&state.terrain_line_pipeline,
	)

	sdl.ReleaseGPUShader(state.device, frag_shader)
	sdl.ReleaseGPUShader(state.device, vert_shader)
	sdl.ReleaseGPUShader(state.device, terrain_frag_shader)
	sdl.ReleaseGPUShader(state.device, terrain_vert_shader)

	w, h: c.int
	sdl.GetWindowSizeInPixels(state.window, &w, &h)

	depth_texture_props := sdl.CreateProperties()
	log.assertf(
		depth_texture_props != 0,
		"CreateProperties depth texture failed: %s",
		sdl.GetError(),
	)
	defer sdl.DestroyProperties(depth_texture_props)
	log.assertf(
		sdl.SetFloatProperty(
			depth_texture_props,
			sdl.PROP_GPU_TEXTURE_CREATE_D3D12_CLEAR_DEPTH_FLOAT,
			DEPTH_CLEAR_VALUE,
		),
		"SetFloatProperty depth clear value failed: %s",
		sdl.GetError(),
	)

	state.depth_texture = sdl.CreateGPUTexture(
		state.device,
		sdl.GPUTextureCreateInfo {
			type = sdl.GPUTextureType.D2,
			width = cast(u32)(w),
			height = cast(u32)(h),
			layer_count_or_depth = 1,
			num_levels = 1,
			sample_count = sdl.GPUSampleCount._1,
			format = sdl.GPUTextureFormat.D16_UNORM,
			usage = {.DEPTH_STENCIL_TARGET},
			props = depth_texture_props,
		},
	)
	log.assert(state.depth_texture != nil, "Failed to create depth texture!")

	temp := mem.begin_arena_temp_memory(&state.transient_arena)
	defer mem.end_arena_temp_memory(temp)

	chunk_store_init(CHUNK_STORE_CAPACITY)
	chunk_store_clear()

	state.streaming_target_count = 0
	state.next_streaming_target_index = 0
	state.next_mesh_scan_index = 0
	chunk_streaming_update_for_observer(state.camera.position)

	log.debug("Resources initialized")
}

destroy_resources :: proc() {
	log.debug("Destroying resources")
	log.assertf(sdl.WaitForGPUIdle(state.device), "WaitForGPUIdle failed: %s", sdl.GetError())
	geometry_destroy(&state.geometry_pool)
	sdl.ReleaseGPUTexture(state.device, state.depth_texture)
	sdl.ReleaseGPUGraphicsPipeline(state.device, state.prototype_fill_pipeline)
	sdl.ReleaseGPUGraphicsPipeline(state.device, state.prototype_line_pipeline)
	sdl.ReleaseGPUGraphicsPipeline(state.device, state.terrain_fill_pipeline)
	sdl.ReleaseGPUGraphicsPipeline(state.device, state.terrain_line_pipeline)
	log.debug("Resources destroyed")
}

process_events :: proc() {
	for event: sdl.Event; sdl.PollEvent(&event); {
		#partial switch event.type {
		case .QUIT:
			log.debug("Quit event received")
			state.is_window_open = false
		case .KEY_DOWN:
			{
				if event.key.scancode == sdl.Scancode.ESCAPE {
					log.debug("Escape key pressed")
					state.is_window_open = false
				}

				if event.key.scancode == sdl.Scancode.G && !event.key.repeat {
					state.use_wireframe_mode = !state.use_wireframe_mode
				}

				if event.key.scancode == sdl.Scancode.L && !event.key.repeat {
					state.auto_move_on = !state.auto_move_on
				}

				if event.key.scancode == sdl.Scancode.LCTRL && !event.key.repeat {
					state.sprint_on = !state.sprint_on
				}

				if event.key.scancode == sdl.Scancode.I && !event.key.repeat {
					log.debugf(
						"Debug info: streaming_center=(%d,%d,%d), streaming_targets=%d, chunks_total=%d, chunks_without_geometry=%d, chunks_frustum_culled=%d, chunks_drawn=%d, terrain_faces_drawn=%d, terrain_indices_drawn=%d, chunks_generated=%d, chunks_evicted=%d, chunk_mesh_jobs_submitted=%d, chunk_mesh_results_committed=%d, chunk_mesh_results_uploaded=%d, chunks_dirty_remaining=%d",
						state.streaming_center_coord.x,
						state.streaming_center_coord.y,
						state.streaming_center_coord.z,
						state.streaming_target_count,
						state.prev_chunks_total,
						state.prev_chunks_without_geometry,
						state.prev_chunks_frustum_culled,
						state.prev_chunks_drawn,
						state.prev_terrain_faces_drawn,
						state.prev_terrain_indices_drawn,
						state.prev_chunks_generated,
						state.prev_chunks_evicted,
						state.prev_chunk_mesh_jobs_submitted,
						state.prev_chunk_mesh_results_committed,
						state.prev_chunk_mesh_results_uploaded,
						state.prev_chunks_dirty_remaining,
					)
				}
			}
		case .MOUSE_MOTION:
			{
				state.camera.yaw -= event.motion.xrel * MOUSE_SENSITIVITY
				state.camera.pitch -= event.motion.yrel * MOUSE_SENSITIVITY
				state.camera.pitch = math.clamp(
					state.camera.pitch,
					math.to_radians_f32(-89.0),
					math.to_radians_f32(89.0),
				)
			}
		}
	}
}

update_camera_vectors :: proc() {
	state.camera.forward = la.normalize(
		la.Vector3f32 {
			math.sin(state.camera.yaw) * math.cos(state.camera.pitch),
			math.sin(state.camera.pitch),
			math.cos(state.camera.yaw) * math.cos(state.camera.pitch),
		},
	)

	state.camera.right = la.normalize(la.cross(state.camera.world_up, state.camera.forward))
	state.camera.up = la.normalize(la.cross(state.camera.forward, state.camera.right))
}

update :: proc() {
	chunk_work_update_budgeted()
	camera_resolve_terrain_intersection(&state.camera)

	view := la.matrix4_look_at_f32(
		state.camera.position,
		state.camera.position + state.camera.forward,
		state.camera.up,
	)
	proj := la.matrix4_perspective_f32(
		math.to_radians_f32(FOV),
		ASPECT_RATIO,
		state.camera.near_plane,
		state.camera.far_plane,
	)
	state.view_projection = proj * view
	model := la.matrix4_rotate_f32(ANGLE, la.Vector3f32{0, 1, 0})
	state.mvp = state.view_projection * model
}

handle_input :: proc(dt: f32) {
	key_count: c.int
	keys := sdl.GetKeyboardState(&key_count)

	velocity := DEFAULT_ACCELERATION
	if keys[cast(int)sdl.Scancode.LSHIFT] || state.sprint_on {velocity = MAX_ACCELERATION}

	velocity = velocity * dt
	if keys[cast(int)sdl.Scancode.W] {state.camera.position += state.camera.forward * velocity}
	if keys[cast(int)sdl.Scancode.S] {state.camera.position -= state.camera.forward * velocity}
	if keys[cast(int)sdl.Scancode.D] {state.camera.position -= state.camera.right * velocity}
	if keys[cast(int)sdl.Scancode.A] {state.camera.position += state.camera.right * velocity}

	if state.auto_move_on {
		state.camera.position += state.camera.forward * velocity
	}
}

//////////////////////////////////////
// Main
/////////////////////////////////////

main :: proc() {
	context.logger = log.create_console_logger(.Debug)
	defer log.destroy_console_logger(context.logger)

	memory_init()

	context.allocator = state.persistent_allocator
	context.temp_allocator = state.transient_allocator

	when ODIN_DEBUG {
		debug_frustum_contract_checks_run()
		debug_camera_terrain_collision_checks_run()
		debug_chunk_mesher_contract_checks_run()
	}

	init()
	defer shutdown()

	setup_resources()
	defer destroy_resources()

	current_time := sdl.GetTicks()
	for state.is_window_open {
		now := sdl.GetTicks()
		dt := cast(f32)(now - current_time) / 1000.0
		current_time = now

		process_events()
		update_camera_vectors()
		handle_input(dt)
		update()
		gfx_render()
	}
}
