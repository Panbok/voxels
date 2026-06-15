package main

import async "async"
import world_async "async:world"
import sdl "vendor:sdl3"
import world "world"

import "base:runtime"
import "core:c"
import "core:log"
import math "core:math"
import la "core:math/linalg"
import "core:mem"
import mem_tlsf "core:mem/tlsf"
import "core:os"
import "core:strings"

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
AUTO_TEST_FRAME_LIMIT :: #config(AUTO_TEST_FRAME_LIMIT, 0)
AUTO_TEST_DURATION_MS :: #config(AUTO_TEST_DURATION_MS, 0)
LOG_FRAME_METRICS :: #config(LOG_FRAME_METRICS, false)
FRAME_METRICS_LOG_INTERVAL_MS :: #config(FRAME_METRICS_LOG_INTERVAL_MS, 1000)
AUTO_TEST_DISABLE_VSYNC :: #config(AUTO_TEST_DISABLE_VSYNC, false)
RUN_MESH_BENCHMARK :: #config(RUN_MESH_BENCHMARK, false)
MESH_BENCHMARK_ITERATIONS :: #config(MESH_BENCHMARK_ITERATIONS, 8)

//////////////////////////////////////
// State
/////////////////////////////////////

Memory :: struct {
	// Main
	persistent_slab:      [192 * mem.Megabyte]u8,
	transient_slab:       [16 * mem.Megabyte]u8,
	persistent_arena:     mem.Arena,
	transient_arena:      mem.Arena,
	persistent_allocator: mem.Allocator,
	transient_allocator:  mem.Allocator,
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
	// General frame stats
	frame_count:                       u64,
	current_frame_ms:                  f32,
	current_fps:                       f32,
	auto_test_elapsed_ms:              f32,
	frame_metrics_accum_ms:            f32,
	frame_metrics_elapsed_ms:          f32,
	frame_metrics_min_ms:              f32,
	frame_metrics_max_ms:              f32,
	frame_metrics_sample_count:        u32,
	frame_metrics_chunks_generated:    u32,
	frame_metrics_chunks_evicted:      u32,
	frame_metrics_mesh_submitted:      u32,
	frame_metrics_mesh_committed:      u32,
	frame_metrics_mesh_uploaded:       u32,
	frame_metrics_dirty_remaining_max: u32,

	// World frame stats
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


state := struct {
	// Memory
	using memory:       Memory,

	// Geometry
	geometry_pool:      GeometryPool,

	// Graphics & Window
	using graphics:     Graphics,

	// Metrics & Frame debug stats
	using metrics:      Metrics,

	// Player
	auto_move_on:       bool,
	sprint_on:          bool,

	// State variables
	debug_mode:         bool,
	enable_vsync:       bool,
	is_window_open:     bool,
	use_wireframe_mode: bool,
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
	auto_move_on = AUTO_MOVE_STRESS_TEST,
	sprint_on = AUTO_MOVE_STRESS_TEST,
	debug_mode = true,
	enable_vsync = !AUTO_TEST_DISABLE_VSYNC,
	is_window_open = true,
	use_wireframe_mode = false,
}

//////////////////////////////////////
// Memory
/////////////////////////////////////

memory_init :: proc() {
	mem.arena_init(&state.persistent_arena, state.persistent_slab[:])
	mem.arena_init(&state.transient_arena, state.transient_slab[:])

	state.transient_allocator = mem.arena_allocator(&state.transient_arena)
	state.persistent_allocator = mem.arena_allocator(&state.persistent_arena)

}

///////////////////////////////////////////
// Math
///////////////////////////////////////////

UVec2 :: [2]u32

Camera :: struct {
	position:   world.Vec3,
	forward:    world.Vec3,
	up:         world.Vec3,
	right:      world.Vec3,
	world_up:   world.Vec3,
	yaw:        f32,
	pitch:      f32,
	near_plane: f32,
	far_plane:  f32,
}


Plane :: struct {
	normal:   world.Vec3,
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

frustum_plane_from_point_normal :: proc(point, normal: world.Vec3) -> Plane {
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

frustum_test_aabb :: proc(frustum: Frustum, aabb: world.WorldAABB) -> bool {
	center := world.Vec3 {
		(aabb.min[0] + aabb.max[0]) * 0.5,
		(aabb.min[1] + aabb.max[1]) * 0.5,
		(aabb.min[2] + aabb.max[2]) * 0.5,
	}
	extent := world.Vec3 {
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

camera_move_above_block :: proc(camera: ^Camera, block: world_async.BlockCoord) {
	camera.position[1] = world.terrain_block_top_world_y(block.y) + CAMERA_TERRAIN_CLEARANCE
}

camera_resolve_terrain_intersection :: proc(camera: ^Camera) -> bool {
	moved := false

	for push_count := 0; push_count < world.CHUNK_BLOCK_LENGTH + 1; push_count += 1 {
		block, intersects := world.chunk_store_solid_block_at_world_position(camera.position).?
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
			frustum_test_aabb(
				frustum,
				world.WorldAABB{min = {-0.5, -0.5, 4}, max = {0.5, 0.5, 5}},
			),
			"frustum check: expected centered box to be visible",
		)
		log.assertf(
			!frustum_test_aabb(
				frustum,
				world.WorldAABB{min = {-0.5, -0.5, -3}, max = {0.5, 0.5, -2}},
			),
			"frustum check: expected box behind camera to be culled",
		)
		log.assertf(
			!frustum_test_aabb(
				frustum,
				world.WorldAABB{min = {-0.5, -0.5, 12}, max = {0.5, 0.5, 13}},
			),
			"frustum check: expected box beyond far plane to be culled",
		)
		log.assertf(
			!frustum_test_aabb(frustum, world.WorldAABB{min = {12, -0.5, 4}, max = {13, 0.5, 5}}),
			"frustum check: expected right-side box to be culled",
		)

		aabb := world.chunk_world_get_aabb(world_async.ChunkCoord{1, 0, -1})
		log.assertf(
			aabb.min == world.Vec3{32, 0, -32},
			"chunk world AABB: min mismatch, got %v",
			aabb.min,
		)
		log.assertf(
			aabb.max == world.Vec3{64, 32, 0},
			"chunk world AABB: max mismatch, got %v",
			aabb.max,
		)
	}

	debug_camera_terrain_collision_checks_run :: proc() {
		temp := mem.begin_arena_temp_memory(&state.transient_arena)
		defer mem.end_arena_temp_memory(temp)

		chunk := world.chunk_create(world_async.ChunkCoord{0, 0, 0})
		storage := world.chunk_block_storage_alloc(state.transient_allocator)
		index := world.chunk_block_index(0, 0, 0)
		storage.voxel_view.blocks.occupancy[index] = .Solid
		storage.voxel_view.blocks.material_id[index] = world_async.BlockMaterialID(1)
		world.chunk_mark_generated(&chunk, storage)

		hit_block, hit := world.chunk_solid_block_at_world_block(
			&chunk,
			world_async.BlockCoord{0, 0, 0},
		).?
		log.assert(hit, "camera terrain collision check: expected solid block hit")
		log.assertf(
			hit_block == world_async.BlockCoord{0, 0, 0},
			"camera terrain collision check: wrong hit block %v",
			hit_block,
		)

		test_camera := Camera {
			position = {0.25, 0.25, 0.25},
		}
		camera_move_above_block(&test_camera, hit_block)
		log.assertf(
			test_camera.position[1] > world.terrain_block_top_world_y(hit_block.y),
			"camera terrain collision check: camera was not lifted above block",
		)

		lifted_block := world.block_coord_from_world_position(test_camera.position)
		_, lifted_hit := world.chunk_solid_block_at_world_block(&chunk, lifted_block).?
		log.assert(!lifted_hit, "camera terrain collision check: lifted camera still intersects")

		negative_chunk := world.chunk_create(world_async.ChunkCoord{-1, 0, -1})
		negative_storage := world.chunk_block_storage_alloc(state.transient_allocator)
		negative_index := world.chunk_block_index(
			world.CHUNK_BLOCK_LOCAL_MAX,
			0,
			world.CHUNK_BLOCK_LOCAL_MAX,
		)
		negative_storage.voxel_view.blocks.occupancy[negative_index] = .Solid
		negative_storage.voxel_view.blocks.material_id[negative_index] =
			world_async.BlockMaterialID(1)
		world.chunk_mark_generated(&negative_chunk, negative_storage)

		negative_hit_block, negative_hit := world.chunk_solid_block_at_world_block(
			&negative_chunk,
			world_async.BlockCoord{-1, 0, -1},
		).?
		log.assert(negative_hit, "camera terrain collision check: expected negative block hit")
		log.assertf(
			negative_hit_block == world_async.BlockCoord{-1, 0, -1},
			"camera terrain collision check: wrong negative hit block %v",
			negative_hit_block,
		)

		log.debug("Camera terrain collision checks passed")
	}
}

///////////////////////////////////////////
// Geometry
///////////////////////////////////////////

INVALID_GEOMETRY_ID :: GeometryID(0)
GEOMETRY_MAX_GEOMETRIES :: 16384
GEOMETRY_MAX_POSITION_COLOR_VERTICES :: 2_000_000
GEOMETRY_MAX_VERTEX_BYTES :: GEOMETRY_MAX_POSITION_COLOR_VERTICES * size_of(PositionColorVertex)
GEOMETRY_MAX_INDEX_ELEMENTS :: 24_000_000
GEOMETRY_MAX_UPLOAD_POSITION_COLOR_VERTICES :: 65_536
GEOMETRY_MAX_VERTEX_UPLOAD_BYTES ::
	GEOMETRY_MAX_UPLOAD_POSITION_COLOR_VERTICES * size_of(PositionColorVertex)
GEOMETRY_MAX_UPLOAD_INDEX_ELEMENTS :: 196_608
GEOMETRY_DEFERRED_RELEASE_CAPACITY :: GEOMETRY_MAX_GEOMETRIES
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
	position: world.Vec4,
	color:    world.Vec4,
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

GeometryDeferredRelease :: struct {
	geometry: Geometry,
	fence:    ^sdl.GPUFence,
}

GeometryDrawParams :: struct {
	vertex_byte_offset:  u32,
	vertex_stride_bytes: u32,
	_padding:            UVec2, // extra padding for alignment
}

GeometryPool :: struct {
	geometry_slots:                   []GeometrySlot,
	geometry_count:                   u32,
	vertex_range_tlsf:                mem_tlsf.Allocator,
	index_range_tlsf:                 mem_tlsf.Allocator,
	vertex_range_allocator:           mem.Allocator,
	index_range_allocator:            mem.Allocator,
	vertex_buffer:                    ^sdl.GPUBuffer,
	index_buffer:                     ^sdl.GPUBuffer,
	vertex_upload_buffer:             ^sdl.GPUTransferBuffer,
	index_upload_buffer:              ^sdl.GPUTransferBuffer,
	deferred_releases:                [GEOMETRY_DEFERRED_RELEASE_CAPACITY]GeometryDeferredRelease,
	deferred_release_count:           u32,
	deferred_release_enqueued_total:  u64,
	deferred_release_completed_total: u64,
	vertex_byte_capacity:             u32,
	vertex_byte_count:                u32,
	index_element_capacity:           u32,
	index_element_count:              u32,
	vertex_upload_byte_capacity:      u32,
	index_upload_byte_capacity:       u32,
}

geometry_layout_stride_bytes :: proc(layout_kind: GeometryLayoutKind) -> u32 {
	switch layout_kind {
	case GeometryLayoutKind.Position_Color_F32x4:
		return u32(size_of(PositionColorVertex))
	case GeometryLayoutKind.Terrain_Packed_U32:
		return u32(size_of(world_async.TerrainPackedVertex))
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
	geometry_deferred_releases_flush_after_idle(pool)

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
	pool.deferred_releases = {}
	pool.deferred_release_count = 0
	pool.deferred_release_enqueued_total = 0
	pool.deferred_release_completed_total = 0
	pool.vertex_byte_capacity = 0
	pool.vertex_byte_count = 0
	pool.index_element_capacity = 0
	pool.index_element_count = 0
	pool.vertex_upload_byte_capacity = 0
	pool.index_upload_byte_capacity = 0
}

geometry_id_from_slot :: proc(slot_index, generation: u32) -> GeometryID {
	log.assertf(
		slot_index < GEOMETRY_ID_SLOT_MASK,
		"geometry slot index exceeds ID range: %d",
		slot_index,
	)
	log.assertf(
		generation > 0 && generation <= GEOMETRY_ID_GENERATION_MASK,
		"invalid geometry generation: %d",
		generation,
	)
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
	log.assertf(
		slot_index < u32(len(pool.geometry_slots)),
		"Geometry ID out of bounds: %d",
		u32(id),
	)

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

geometry_free_ranges :: proc(pool: ^GeometryPool, geometry: Geometry) {
	vertex_free_err := mem.free_bytes(geometry.vertex_allocation, pool.vertex_range_allocator)
	index_free_err := mem.free_bytes(geometry.index_allocation, pool.index_range_allocator)
	log.assertf(
		vertex_free_err == nil,
		"geometry vertex range release failed: %v",
		vertex_free_err,
	)
	log.assertf(index_free_err == nil, "geometry index range release failed: %v", index_free_err)
}

geometry_deferred_release_remove_at :: proc(pool: ^GeometryPool, index: u32) {
	log.assertf(
		index < pool.deferred_release_count,
		"deferred geometry release index out of bounds: %d",
		index,
	)

	last_index := pool.deferred_release_count - 1
	if index != last_index {
		pool.deferred_releases[index] = pool.deferred_releases[last_index]
	}
	pool.deferred_releases[last_index] = {}
	pool.deferred_release_count -= 1
	pool.deferred_release_completed_total += 1
}

geometry_deferred_release_records_for_fence :: proc(pool: ^GeometryPool, fence: ^sdl.GPUFence) {
	log.assertf(fence != nil, "deferred geometry release fence must not be nil")

	for i := u32(0); i < pool.deferred_release_count; {
		record := pool.deferred_releases[i]
		if record.fence != fence {
			i += 1
			continue
		}

		geometry_free_ranges(pool, record.geometry)
		geometry_deferred_release_remove_at(pool, i)
	}

	sdl.ReleaseGPUFence(state.device, fence)
}

geometry_deferred_releases_flush_after_idle :: proc(pool: ^GeometryPool) {
	for pool.deferred_release_count > 0 {
		record := pool.deferred_releases[0]
		if record.fence != nil {
			geometry_deferred_release_records_for_fence(pool, record.fence)
			continue
		}

		geometry_free_ranges(pool, record.geometry)
		geometry_deferred_release_remove_at(pool, 0)
	}
}

geometry_deferred_releases_poll :: proc(pool: ^GeometryPool) {
	if state.device == nil {
		geometry_deferred_releases_flush_after_idle(pool)
		return
	}

	for i := u32(0); i < pool.deferred_release_count; {
		fence := pool.deferred_releases[i].fence
		if fence == nil || !sdl.QueryGPUFence(state.device, fence) {
			i += 1
			continue
		}

		geometry_deferred_release_records_for_fence(pool, fence)
		i = 0
	}
}

geometry_deferred_releases_has_pending_fence :: proc(pool: ^GeometryPool) -> bool {
	for i := u32(0); i < pool.deferred_release_count; i += 1 {
		if pool.deferred_releases[i].fence == nil {
			return true
		}
	}
	return false
}

geometry_deferred_releases_attach_pending_to_fence :: proc(
	pool: ^GeometryPool,
	fence: ^sdl.GPUFence,
) {
	log.assertf(fence != nil, "deferred geometry release fence must not be nil")

	attached := false
	for i := u32(0); i < pool.deferred_release_count; i += 1 {
		if pool.deferred_releases[i].fence != nil {
			continue
		}
		pool.deferred_releases[i].fence = fence
		attached = true
	}

	if !attached {
		sdl.ReleaseGPUFence(state.device, fence)
	}
}

geometry_deferred_release_enqueue :: proc(pool: ^GeometryPool, geometry: Geometry) {
	if state.device == nil {
		geometry_free_ranges(pool, geometry)
		return
	}

	if pool.deferred_release_count >= GEOMETRY_DEFERRED_RELEASE_CAPACITY {
		log.assertf(
			sdl.WaitForGPUIdle(state.device),
			"WaitForGPUIdle before deferred geometry release flush failed: %s",
			sdl.GetError(),
		)
		geometry_deferred_releases_flush_after_idle(pool)
	}

	log.assertf(
		pool.deferred_release_count < GEOMETRY_DEFERRED_RELEASE_CAPACITY,
		"deferred geometry release capacity exceeded",
	)
	pool.deferred_releases[pool.deferred_release_count] = {
		geometry = geometry,
	}
	pool.deferred_release_count += 1
	pool.deferred_release_enqueued_total += 1
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
	log.assertf(
		index_bytes_wide <= u64(max(int)),
		"index allocation size exceeds int: %d",
		index_bytes_wide,
	)

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
		log.assertf(
			vertex_free_err == nil,
			"geometry vertex range rollback failed: %v",
			vertex_free_err,
		)
		log.assertf(
			index_free_err == nil,
			"geometry index range rollback failed: %v",
			index_free_err,
		)
		log.assertf(false, "geometry pool is full")
	}

	vertex_byte_offset := geometry_range_byte_offset(
		vertex_allocation,
		pool.vertex_range_tlsf.pool.data,
	)
	index_byte_offset := geometry_range_byte_offset(
		index_allocation,
		pool.index_range_tlsf.pool.data,
	)
	log.assertf(
		index_byte_offset % u32(size_of(u32)) == 0,
		"index range offset must be u32-aligned",
	)

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

	log.assertf(
		pool.vertex_byte_count >= u32(len(geometry.vertex_allocation)),
		"geometry vertex byte count underflow",
	)
	log.assertf(pool.index_element_count >= geometry.index_count, "geometry index count underflow")
	log.assertf(pool.geometry_count > 0, "geometry count underflow")

	pool.vertex_byte_count -= u32(len(geometry.vertex_allocation))
	pool.index_element_count -= geometry.index_count
	pool.geometry_count -= 1

	slot.geometry = {}
	slot.occupied = false
	geometry_slot_generation_advance(slot)

	geometry_deferred_release_enqueue(pool, geometry)
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
	log.assertf(
		index_bytes_wide <= u64(max(u32)),
		"index upload size exceeds u32: %d",
		index_bytes_wide,
	)
	index_bytes := u32(index_bytes_wide)

	log.assertf(
		vertex_byte_count == u32(len(geometry.vertex_allocation)),
		"vertex upload size mismatch",
	)
	log.assertf(index_bytes == u32(len(geometry.index_allocation)), "index upload size mismatch")
	log.assertf(
		vertex_byte_count <= pool.vertex_upload_byte_capacity,
		"geometry vertex append exceeds upload buffer capacity",
	)
	log.assertf(
		index_bytes <= pool.index_upload_byte_capacity,
		"geometry index append exceeds upload buffer capacity",
	)

	vertex_dst_offset := geometry.vertex_byte_offset
	index_dst_offset_wide := u64(geometry.first_index) * u64(size_of(u32))
	log.assertf(
		index_dst_offset_wide <= u64(max(u32)),
		"index destination offset exceeds u32: %d",
		index_dst_offset_wide,
	)
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
	output: world_async.ChunkMeshOutput,
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

geometry_replace :: proc(
	pool: ^GeometryPool,
	old_id: GeometryID,
	output: world_async.ChunkMeshOutput,
) -> GeometryID {
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

		for chunk in world.chunk_store_chunks() {
			state.chunks_total += 1

			has_full_geometry := chunk.geometry_id != world.INVALID_CHUNK_GEOMETRY_ID
			has_subchunk_geometry := world.chunk_subchunk_geometry_has_any(chunk)
			if !has_full_geometry && !has_subchunk_geometry {
				state.chunks_without_geometry += 1
				continue
			}

			aabb := world.chunk_world_get_aabb(chunk.coord)
			if !frustum_test_aabb(frustum, aabb) {
				state.chunks_frustum_culled += 1
				continue
			}

			sdl.PushGPUVertexUniformData(
				cmdbuf,
				0,
				&state.view_projection,
				cast(u32)size_of(matrix[4, 4]f32),
			)
			chunk_origin_world := world.terrain_chunk_origin_world_from_coord(chunk.coord)
			draw_params := world.TerrainDrawParams {
				chunk_origin = chunk_origin_world,
			}
			sdl.PushGPUFragmentUniformData(
				cmdbuf,
				0,
				&world.TERRAIN_MATERIAL_COLORS,
				cast(u32)size_of(world.TerrainMaterialColorPalette),
			)

			pipeline :=
				state.use_wireframe_mode ? state.terrain_line_pipeline : state.terrain_fill_pipeline
			sdl.BindGPUGraphicsPipeline(render_pass, pipeline)

			if has_full_geometry {
				geometry := geometry_get(&state.geometry_pool, GeometryID(chunk.geometry_id))
				log.assertf(
					geometry.layout_kind == .Terrain_Packed_U32,
					"chunk geometry must use terrain layout: %v",
					geometry.layout_kind,
				)

				draw_params.vertex_byte_offset = geometry.vertex_byte_offset
				draw_params.vertex_stride_bytes = geometry.vertex_stride_bytes
				sdl.PushGPUVertexUniformData(
					cmdbuf,
					1,
					&draw_params,
					cast(u32)size_of(world.TerrainDrawParams),
				)
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
			} else {
				for subchunk_geometry_id in chunk.subchunk_geometry_ids {
					if subchunk_geometry_id == world.INVALID_CHUNK_GEOMETRY_ID {
						continue
					}

					geometry := geometry_get(
						&state.geometry_pool,
						GeometryID(subchunk_geometry_id),
					)
					log.assertf(
						geometry.layout_kind == .Terrain_Packed_U32,
						"chunk subchunk geometry must use terrain layout: %v",
						geometry.layout_kind,
					)

					draw_params.vertex_byte_offset = geometry.vertex_byte_offset
					draw_params.vertex_stride_bytes = geometry.vertex_stride_bytes
					sdl.PushGPUVertexUniformData(
						cmdbuf,
						1,
						&draw_params,
						cast(u32)size_of(world.TerrainDrawParams),
					)
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
				}
			}

			state.chunks_drawn += 1
		}

		sdl.EndGPURenderPass(render_pass)
	}

	if geometry_deferred_releases_has_pending_fence(&state.geometry_pool) {
		fence := sdl.SubmitGPUCommandBufferAndAcquireFence(cmdbuf)
		log.assertf(fence != nil, "SubmitGPUCommandBufferAndAcquireFence: %s", sdl.GetError())
		geometry_deferred_releases_attach_pending_to_fence(&state.geometry_pool, fence)
	} else {
		log.assertf(
			sdl.SubmitGPUCommandBuffer(cmdbuf),
			"SubmitGPUCommandBuffer: %s",
			sdl.GetError(),
		)
	}
	geometry_deferred_releases_poll(&state.geometry_pool)
}

metrics_record_frame :: proc(dt: f32) {
	state.frame_count += 1
	state.current_frame_ms = dt * 1000.0
	state.current_fps = dt > 0 ? 1.0 / dt : 0.0
	state.auto_test_elapsed_ms += state.current_frame_ms
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

	if state.frame_metrics_sample_count == 0 {
		state.frame_metrics_min_ms = state.current_frame_ms
		state.frame_metrics_max_ms = state.current_frame_ms
	} else {
		state.frame_metrics_min_ms = math.min(state.frame_metrics_min_ms, state.current_frame_ms)
		state.frame_metrics_max_ms = math.max(state.frame_metrics_max_ms, state.current_frame_ms)
	}

	state.frame_metrics_accum_ms += state.current_frame_ms
	state.frame_metrics_elapsed_ms += state.current_frame_ms
	state.frame_metrics_sample_count += 1
	state.frame_metrics_chunks_generated += state.prev_chunks_generated
	state.frame_metrics_chunks_evicted += state.prev_chunks_evicted
	state.frame_metrics_mesh_submitted += state.prev_chunk_mesh_jobs_submitted
	state.frame_metrics_mesh_committed += state.prev_chunk_mesh_results_committed
	state.frame_metrics_mesh_uploaded += state.prev_chunk_mesh_results_uploaded
	state.frame_metrics_dirty_remaining_max = math.max(
		state.frame_metrics_dirty_remaining_max,
		state.prev_chunks_dirty_remaining,
	)

	when LOG_FRAME_METRICS {
		if state.frame_metrics_elapsed_ms >= f32(FRAME_METRICS_LOG_INTERVAL_MS) {
			avg_ms := state.frame_metrics_accum_ms / f32(state.frame_metrics_sample_count)
			avg_fps := avg_ms > 0 ? 1000.0 / avg_ms : 0.0
			log.infof(
				"Frame metrics: frame=%d samples=%d avg_ms=%.3f min_ms=%.3f max_ms=%.3f avg_fps=%.1f chunks_generated=%d chunks_evicted=%d mesh_submitted=%d mesh_committed=%d mesh_uploaded=%d dirty_remaining_max=%d deferred_geometry=%d deferred_enqueued=%d deferred_completed=%d",
				state.frame_count,
				state.frame_metrics_sample_count,
				avg_ms,
				state.frame_metrics_min_ms,
				state.frame_metrics_max_ms,
				avg_fps,
				state.frame_metrics_chunks_generated,
				state.frame_metrics_chunks_evicted,
				state.frame_metrics_mesh_submitted,
				state.frame_metrics_mesh_committed,
				state.frame_metrics_mesh_uploaded,
				state.frame_metrics_dirty_remaining_max,
				state.geometry_pool.deferred_release_count,
				state.geometry_pool.deferred_release_enqueued_total,
				state.geometry_pool.deferred_release_completed_total,
			)

			state.frame_metrics_accum_ms = 0
			state.frame_metrics_elapsed_ms = 0
			state.frame_metrics_sample_count = 0
			state.frame_metrics_min_ms = 0
			state.frame_metrics_max_ms = 0
			state.frame_metrics_chunks_generated = 0
			state.frame_metrics_chunks_evicted = 0
			state.frame_metrics_mesh_submitted = 0
			state.frame_metrics_mesh_committed = 0
			state.frame_metrics_mesh_uploaded = 0
			state.frame_metrics_dirty_remaining_max = 0
		}
	}

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


world_chunk_mesh_upload :: proc(
	old_id: world.ChunkGeometryID,
	output: world_async.ChunkMeshOutput,
) -> world.ChunkGeometryID {
	new_id := geometry_replace(&state.geometry_pool, GeometryID(old_id), output)
	return world.ChunkGeometryID(new_id)
}

world_chunk_geometry_release :: proc(id: world.ChunkGeometryID) {
	geometry_release(&state.geometry_pool, GeometryID(id))
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

	async.init(
		{
			allocator = state.persistent_allocator,
			generation_execute = world.generation_job_execute_sync,
			mesh_execute = world.mesh_job_execute_sync,
		},
	)

	log.debug("Application initialized")
}

shutdown :: proc() {
	log.debug("Application shutdown")
	async.shutdown()
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
	terrain_frag_shader, _ := gfx_load_shader("assets/shaders/Terrain.frag.dxil", 0, 1, 0, 0)

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

	world.init(
		{
			persistent_allocator = state.persistent_allocator,
			generation_request = async.generation_request,
			generation_poll_results = async.generation_results_poll,
			mesh_request = async.mesh_request,
			mesh_poll_results = async.mesh_results_poll,
			mesh_release_result = async.mesh_result_release,
			chunk_mesh_upload = world_chunk_mesh_upload,
			chunk_geometry_release = world_chunk_geometry_release,
		},
	)
	when ODIN_DEBUG {
		world.debug_chunk_edit_contract_checks_run(&state.transient_arena)
	}
	world.streaming_update_for_observer(state.camera.position)

	log.debug("Resources initialized")
}

destroy_resources :: proc() {
	log.debug("Destroying resources")
	async.shutdown()
	log.assertf(sdl.WaitForGPUIdle(state.device), "WaitForGPUIdle failed: %s", sdl.GetError())
	world.shutdown()
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
						world.streaming_center_coord().x,
						world.streaming_center_coord().y,
						world.streaming_center_coord().z,
						world.streaming_target_count(),
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
	geometry_deferred_releases_poll(&state.geometry_pool)
	streaming_stats := world.streaming_update_budgeted(state.camera.position)
	state.chunks_evicted = streaming_stats.chunks_evicted
	state.chunks_generated = streaming_stats.chunks_generated
	state.chunk_mesh_jobs_submitted = streaming_stats.chunk_mesh_jobs_submitted
	state.chunk_mesh_results_committed = streaming_stats.chunk_mesh_results_committed
	state.chunk_mesh_results_uploaded = streaming_stats.chunk_mesh_results_uploaded
	state.chunks_dirty_remaining = streaming_stats.chunks_dirty_remaining
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
		world.debug_chunk_mesher_contract_checks_run(&state.transient_arena)
	}

	when RUN_MESH_BENCHMARK {
		world.chunk_mesher_benchmark_runs_run(&state.transient_arena, MESH_BENCHMARK_ITERATIONS)
		return
	}

	init()
	defer shutdown()

	setup_resources()
	defer destroy_resources()

	performance_frequency := f64(sdl.GetPerformanceFrequency())
	current_time := sdl.GetPerformanceCounter()
	for state.is_window_open {
		now := sdl.GetPerformanceCounter()
		dt := f32(f64(now - current_time) / performance_frequency)
		current_time = now

		process_events()
		update_camera_vectors()
		handle_input(dt)
		update()
		gfx_render()
		metrics_record_frame(dt)

		when AUTO_TEST_DURATION_MS > 0 {
			if state.auto_test_elapsed_ms >= f32(AUTO_TEST_DURATION_MS) {
				log.infof(
					"Auto test duration reached: frame=%d elapsed_ms=%.3f",
					state.frame_count,
					state.auto_test_elapsed_ms,
				)
				state.is_window_open = false
			}
		} else {
			when AUTO_TEST_FRAME_LIMIT > 0 {
				if state.frame_count >= AUTO_TEST_FRAME_LIMIT {
					log.infof("Auto test frame limit reached: frame=%d", state.frame_count)
					state.is_window_open = false
				}
			}
		}
	}
}
