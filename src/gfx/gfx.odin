package gfx

import world "app:world"
import world_async "async:world"
import camera "gfx:camera"
import sdl "vendor:sdl3"

import "base:runtime"
import "core:c"
import "core:log"
import math "core:math"
import la "core:math/linalg"
import "core:mem"
import mem_tlsf "core:mem/tlsf"
import "core:os"
import "core:slice"
import "core:strings"

//////////////////////////////////////
// Constants
/////////////////////////////////////

WINDOW_DEFAULT_HEIGHT :: 720
WINDOW_DEFAULT_WIDTH :: 1280
RENDERER_DEFAULT_DRIVER ::
	"direct3d12" when ODIN_OS == .Windows else "metal" when ODIN_OS == .Darwin else nil
RENDERER_SHADER_FORMAT ::
	sdl.GPUShaderFormat{.DXIL} when ODIN_OS ==
	.Windows else sdl.GPUShaderFormat{.MSL} when ODIN_OS ==
	.Darwin else sdl.GPUShaderFormat{.DXIL}
MESH_VERT_SHADER_PATH ::
	"assets/shaders/Mesh.vert.dxil" when ODIN_OS ==
	.Windows else "assets/shaders/Mesh.vert.msl" when ODIN_OS ==
	.Darwin else "assets/shaders/Mesh.vert.dxil"
SOLID_COLOR_FRAG_SHADER_PATH ::
	"assets/shaders/SolidColor.frag.dxil" when ODIN_OS ==
	.Windows else "assets/shaders/SolidColor.frag.msl" when ODIN_OS ==
	.Darwin else "assets/shaders/SolidColor.frag.dxil"
TERRAIN_VERT_SHADER_PATH ::
	"assets/shaders/Terrain.vert.dxil" when ODIN_OS ==
	.Windows else "assets/shaders/Terrain.vert.msl" when ODIN_OS ==
	.Darwin else "assets/shaders/Terrain.vert.dxil"
TERRAIN_FRAG_SHADER_PATH ::
	"assets/shaders/Terrain.frag.dxil" when ODIN_OS ==
	.Windows else "assets/shaders/Terrain.frag.msl" when ODIN_OS ==
	.Darwin else "assets/shaders/Terrain.frag.dxil"
DEPTH_CLEAR_VALUE :: f32(1.0)
ANGLE :: f32(0.6)
FOV :: f32(70.0)
ASPECT_RATIO :: f32(16.0 / 9.0)

//////////////////////////////////////
// Types
/////////////////////////////////////

UVec2 :: [2]u32

InitConfig :: struct {
	persistent_allocator: mem.Allocator,
	transient_allocator:  mem.Allocator,
	transient_arena:      ^mem.Arena,
	debug_mode:           bool,
	enable_vsync:         bool,
	window_width:         i32,
	window_height:        i32,
	capture_mode:         bool,
}

RenderStats :: struct {
	chunks_total:                        u32,
	chunks_without_geometry:             u32,
	chunks_frustum_culled:               u32,
	chunks_drawn:                        u32,
	terrain_draw_units_tested:           u32,
	terrain_draw_units_frustum_culled:   u32,
	terrain_draw_units_occlusion_culled: u32,
	terrain_draw_units_drawn:            u32,
	terrain_faces_drawn:                 u32,
	terrain_triangles_drawn:             u32,
	terrain_indices_drawn:               u32,
	deferred_geometry_count:             u32,
	deferred_release_enqueued_total:     u64,
	deferred_release_completed_total:    u64,
}

GraphicsState :: struct {
	window:                  ^sdl.Window,
	device:                  ^sdl.GPUDevice,
	depth_texture:           ^sdl.GPUTexture,
	prototype_fill_pipeline: ^sdl.GPUGraphicsPipeline,
	prototype_line_pipeline: ^sdl.GPUGraphicsPipeline,
	terrain_fill_pipeline:   ^sdl.GPUGraphicsPipeline,
	terrain_line_pipeline:   ^sdl.GPUGraphicsPipeline,
	mvp:                     matrix[4, 4]f32,
	view_projection:         matrix[4, 4]f32,
	camera:                  camera.Camera,
}

//////////////////////////////////////
// State
/////////////////////////////////////

state := struct {
	// Memory
	persistent_allocator:               mem.Allocator,
	transient_allocator:                mem.Allocator,
	transient_arena:                    ^mem.Arena,

	// Geometry
	geometry_pool:                      GeometryPool,

	// Graphics
	using graphics:                     GraphicsState,

	// Metrics
	render_stats:                       RenderStats,

	// State
	initialized:                        bool,
	resources_ready:                    bool,
	debug_mode:                         bool,
	enable_vsync:                       bool,
	use_wireframe_mode:                 bool,
	use_hydrology_debug_visualization:  bool,
	use_cave_debug_visualization:       bool,
	use_decoration_debug_visualization: bool,
}{}

//////////////////////////////////////
// Lifecycle Methods
/////////////////////////////////////

init :: proc(config: InitConfig) {
	if state.initialized {
		return
	}

	state.persistent_allocator = config.persistent_allocator
	state.transient_allocator = config.transient_allocator
	state.transient_arena = config.transient_arena
	state.debug_mode = config.debug_mode
	state.enable_vsync = config.enable_vsync
	state.camera = camera.default_create()

	window_width := config.window_width
	if window_width <= 0 {
		window_width = WINDOW_DEFAULT_WIDTH
	}
	window_height := config.window_height
	if window_height <= 0 {
		window_height = WINDOW_DEFAULT_HEIGHT
	}

	sdl_init_ok := sdl.Init({.VIDEO})
	log.assertf(sdl_init_ok, "Failed to initialize SDL: %s", sdl.GetError())

	state.device = sdl.CreateGPUDevice(
		RENDERER_SHADER_FORMAT,
		state.debug_mode,
		RENDERER_DEFAULT_DRIVER,
	)
	log.assertf(state.device != nil, "Failed to create GPU device: %s", sdl.GetError())
	log.debugf("SDL GPU driver: %s", sdl.GetGPUDeviceDriver(state.device))

	window_flags := sdl.WindowFlags{.RESIZABLE}
	if config.capture_mode {
		window_flags = {.HIDDEN}
	}
	if config.capture_mode {
		state.window = sdl.CreateWindow(
			"Voxels Visual Capture",
			window_width,
			window_height,
			window_flags,
		)
	} else {
		state.window = sdl.CreateWindow("Voxels Engine", window_width, window_height, window_flags)
	}
	log.assertf(state.window != nil, "Failed to create window: %s", sdl.GetError())
	if !config.capture_mode {
		relative_mouse_mode_set := sdl.SetWindowRelativeMouseMode(state.window, true)
		log.assertf(
			relative_mouse_mode_set,
			"Failed to enable relative mouse mode: %s",
			sdl.GetError(),
		)
	}

	window_claimed := sdl.ClaimWindowForGPUDevice(state.device, state.window)
	log.assertf(window_claimed, "Failed to claim window for GPU device: %s", sdl.GetError())

	swapchain_parameters_set := sdl.SetGPUSwapchainParameters(
		state.device,
		state.window,
		sdl.GPUSwapchainComposition.SDR,
		state.enable_vsync ? sdl.GPUPresentMode.VSYNC : sdl.GPUPresentMode.IMMEDIATE,
	)
	log.assertf(
		swapchain_parameters_set,
		"Failed to set GPU swapchain parameters: %s",
		sdl.GetError(),
	)

	sdl.SetLogOutputFunction(sdl_log_output, nil)
	sdl.SetLogPriority(.GPU, .DEBUG)
	state.initialized = true
}

shutdown :: proc() {
	if !state.initialized {
		return
	}
	log.assert(!state.resources_ready, "gfx resources must be destroyed before gfx shutdown")
	sdl.ReleaseWindowFromGPUDevice(state.device, state.window)
	sdl.DestroyGPUDevice(state.device)
	sdl.DestroyWindow(state.window)
	sdl.Quit()

	// Do not assign the whole state here; GeometryPool contains a large fixed array.
	state.persistent_allocator = {}
	state.transient_allocator = {}
	state.transient_arena = nil
	state.graphics = {
		camera = camera.default_create(),
	}
	state.render_stats = {}
	state.initialized = false
	state.resources_ready = false
	state.debug_mode = false
	state.enable_vsync = false
	state.use_wireframe_mode = false
	state.use_hydrology_debug_visualization = false
	state.use_cave_debug_visualization = false
	state.use_decoration_debug_visualization = false
}

setup_resources :: proc() {
	if state.resources_ready {
		return
	}
	log.debug("Setting gfx resources")

	geometry_init(
		&state.geometry_pool,
		GEOMETRY_MAX_GEOMETRIES,
		GEOMETRY_MAX_VERTEX_BYTES,
		GEOMETRY_MAX_INDEX_ELEMENTS,
		GEOMETRY_MAX_VERTEX_UPLOAD_BYTES,
		GEOMETRY_MAX_UPLOAD_INDEX_ELEMENTS,
	)

	// Mesh.vert uses one vertex storage buffer for PVP geometry bytes.
	// Indices are bound through SDL's hardware index-buffer path, not as shader storage.
	vert_shader, _ := gfx_load_shader(MESH_VERT_SHADER_PATH, 0, 2, 1, 0)
	frag_shader, _ := gfx_load_shader(SOLID_COLOR_FRAG_SHADER_PATH, 0, 0, 0, 0)

	terrain_vert_shader, _ := gfx_load_shader(TERRAIN_VERT_SHADER_PATH, 0, 2, 1, 0)
	terrain_frag_shader, _ := gfx_load_shader(TERRAIN_FRAG_SHADER_PATH, 0, 1, 0, 0)

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

	depth_texture_props := sdl.PropertiesID(0)
	when ODIN_OS == .Windows {
		depth_texture_props = sdl.CreateProperties()
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
	}

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
	state.resources_ready = true
	log.debug("Gfx resources initialized")
}

destroy_resources :: proc() {
	if !state.resources_ready {
		return
	}
	log.debug("Destroying gfx resources")
	gpu_idle := sdl.WaitForGPUIdle(state.device)
	log.assertf(gpu_idle, "WaitForGPUIdle failed: %s", sdl.GetError())
	geometry_destroy(&state.geometry_pool)
	sdl.ReleaseGPUTexture(state.device, state.depth_texture)
	sdl.ReleaseGPUGraphicsPipeline(state.device, state.prototype_fill_pipeline)
	sdl.ReleaseGPUGraphicsPipeline(state.device, state.prototype_line_pipeline)
	sdl.ReleaseGPUGraphicsPipeline(state.device, state.terrain_fill_pipeline)
	sdl.ReleaseGPUGraphicsPipeline(state.device, state.terrain_line_pipeline)
	state.depth_texture = nil
	state.prototype_fill_pipeline = nil
	state.prototype_line_pipeline = nil
	state.terrain_fill_pipeline = nil
	state.terrain_line_pipeline = nil
	state.resources_ready = false
	log.debug("Gfx resources destroyed")
}

camera_get :: proc() -> ^camera.Camera {
	return &state.camera
}

wireframe_toggle :: proc() {
	state.use_wireframe_mode = !state.use_wireframe_mode
}

hydrology_debug_visualization_toggle :: proc() {
	state.use_hydrology_debug_visualization = !state.use_hydrology_debug_visualization
	log.debugf("Hydrology debug visualization: %v", state.use_hydrology_debug_visualization)
}

cave_debug_visualization_toggle :: proc() {
	state.use_cave_debug_visualization = !state.use_cave_debug_visualization
	log.debugf("Cave debug visualization: %v", state.use_cave_debug_visualization)
}

decoration_debug_visualization_toggle :: proc() {
	state.use_decoration_debug_visualization = !state.use_decoration_debug_visualization
	log.debugf("Decoration debug visualization: %v", state.use_decoration_debug_visualization)
}

view_projection_update :: proc() {
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

chunk_mesh_upload :: proc(
	old_id: world.ChunkGeometryID,
	output: world_async.ChunkMeshOutput,
) -> world.ChunkGeometryID {
	new_id := geometry_replace(&state.geometry_pool, GeometryID(old_id), output)
	return world.ChunkGeometryID(new_id)
}

chunk_geometry_release :: proc(id: world.ChunkGeometryID) {
	geometry_release(&state.geometry_pool, GeometryID(id))
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

// Mesh.vert.slang decodes this layout by byte offsets.
PositionColorVertex :: struct {
	position: world.Vec4,
	color:    world.Vec4,
}
#assert(size_of(PositionColorVertex) == 32)

Geometry :: struct {
	layout_kind:         GeometryLayoutKind,
	vertex_allocation:   []byte,
	index_allocation:    []byte,
	vertex_byte_count:   u32,
	index_byte_count:    u32,
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
		index_bytes_wide <= u64(max(u32)),
		"index allocation size exceeds u32: %d",
		index_bytes_wide,
	)
	index_byte_count := u32(index_bytes_wide)

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
		vertex_byte_count   = vertex_byte_count,
		index_byte_count    = index_byte_count,
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
		pool.vertex_byte_count >= geometry.vertex_byte_count,
		"geometry vertex byte count underflow",
	)
	log.assertf(pool.index_element_count >= geometry.index_count, "geometry index count underflow")
	log.assertf(pool.geometry_count > 0, "geometry count underflow")

	pool.vertex_byte_count -= geometry.vertex_byte_count
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

	log.assertf(vertex_byte_count == geometry.vertex_byte_count, "vertex upload size mismatch")
	log.assertf(index_bytes == geometry.index_byte_count, "index upload size mismatch")
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
	upload_submitted := sdl.SubmitGPUCommandBuffer(upload_cmd_buf)
	log.assertf(upload_submitted, "SubmitGPUCommandBuffer failed: %s", sdl.GetError())
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
	if strings.has_suffix(filename, ".vert.dxil") || strings.has_suffix(filename, ".vert.msl") {
		shader_type = ShaderType.Vertex
	} else if strings.has_suffix(filename, ".frag.dxil") ||
	   strings.has_suffix(filename, ".frag.msl") {
		shader_type = ShaderType.Fragment
	} else {
		log.assertf(false, "Unknown shader type: %s", filename)
	}

	temp := mem.begin_arena_temp_memory(state.transient_arena)
	defer mem.end_arena_temp_memory(temp)

	code, err := os.read_entire_file_from_path(filename, state.transient_allocator)
	log.assertf(err == nil, "Failed to read shader: %s", err)
	log.assertf(len(code) > 0, "Shader file is empty: %s", filename)

	code_size: uint = len(code)
	code_data := ([^]sdl.Uint8)(raw_data(code))

	stage: sdl.GPUShaderStage
	entrypoint := cstring("main")
	if shader_type == ShaderType.Fragment {
		stage = sdl.GPUShaderStage.FRAGMENT
		when ODIN_OS == .Darwin {
			entrypoint = "fragment_main"
		}
	} else if shader_type == ShaderType.Vertex {
		stage = sdl.GPUShaderStage.VERTEX
		when ODIN_OS == .Darwin {
			entrypoint = "vertex_main"
		}
	} else {
		log.assertf(false, "Unknown shader type: %s", filename)
	}

	shader_info := sdl.GPUShaderCreateInfo {
		code                 = code_data,
		code_size            = code_size,
		entrypoint           = entrypoint,
		format               = RENDERER_SHADER_FORMAT,
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


//////////////////////////////////////
// Terrain Rendering Types
/////////////////////////////////////

TerrainSubmitContext :: struct {
	cmdbuf:      ^sdl.GPUCommandBuffer,
	render_pass: ^sdl.GPURenderPass,
}

//////////////////////////////////////
// Terrain Rendering Methods
/////////////////////////////////////

terrain_draw_item_submit :: proc(item: camera.TerrainDrawItem, userdata: rawptr) {
	ctx := (^TerrainSubmitContext)(userdata)
	terrain_geometry_draw(ctx.cmdbuf, ctx.render_pass, item.chunk_coord, item.geometry_id)
}

terrain_culling_stats_apply :: proc(stats: camera.TerrainCullingStats) {
	state.render_stats.chunks_total = stats.chunks_total
	state.render_stats.chunks_without_geometry = stats.chunks_without_geometry
	state.render_stats.chunks_frustum_culled = stats.chunks_frustum_culled
	state.render_stats.chunks_drawn = stats.chunks_drawn
	state.render_stats.terrain_draw_units_tested = stats.draw_units_tested
	state.render_stats.terrain_draw_units_frustum_culled = stats.draw_units_frustum_culled
	state.render_stats.terrain_draw_units_occlusion_culled = stats.draw_units_occlusion_culled
	state.render_stats.terrain_draw_units_drawn = stats.draw_units_drawn
}

terrain_draw_items :: proc(
	cmdbuf: ^sdl.GPUCommandBuffer,
	render_pass: ^sdl.GPURenderPass,
	items: []camera.TerrainDrawItem,
) {
	if len(items) == 0 {
		return
	}

	terrain_draw_begin(cmdbuf, render_pass)
	for item in items {
		terrain_geometry_draw(cmdbuf, render_pass, item.chunk_coord, item.geometry_id)
	}
}

terrain_draw_begin :: proc(cmdbuf: ^sdl.GPUCommandBuffer, render_pass: ^sdl.GPURenderPass) {
	sdl.PushGPUVertexUniformData(
		cmdbuf,
		0,
		&state.view_projection,
		cast(u32)size_of(matrix[4, 4]f32),
	)
	materials := world.TERRAIN_MATERIAL_COLORS
	materials[5][3] = state.use_decoration_debug_visualization ? f32(1) : f32(0)
	materials[6][3] = state.use_cave_debug_visualization ? f32(1) : f32(0)
	materials[7][3] = state.use_hydrology_debug_visualization ? f32(1) : f32(0)
	sdl.PushGPUFragmentUniformData(
		cmdbuf,
		0,
		&materials,
		cast(u32)size_of(world.TerrainMaterialColorPalette),
	)

	pipeline :=
		state.use_wireframe_mode ? state.terrain_line_pipeline : state.terrain_fill_pipeline
	sdl.BindGPUGraphicsPipeline(render_pass, pipeline)
}

terrain_geometry_draw :: proc(
	cmdbuf: ^sdl.GPUCommandBuffer,
	render_pass: ^sdl.GPURenderPass,
	chunk_coord: world_async.ChunkCoord,
	geometry_id: world.ChunkGeometryID,
) {
	geometry := geometry_get(&state.geometry_pool, GeometryID(geometry_id))
	log.assertf(
		geometry.layout_kind == .Terrain_Packed_U32,
		"terrain geometry must use terrain layout: %v",
		geometry.layout_kind,
	)

	draw_params := world.TerrainDrawParams {
		vertex_byte_offset  = geometry.vertex_byte_offset,
		vertex_stride_bytes = geometry.vertex_stride_bytes,
		chunk_origin        = world.terrain_chunk_origin_world_from_coord(chunk_coord),
	}
	sdl.PushGPUVertexUniformData(
		cmdbuf,
		1,
		&draw_params,
		cast(u32)size_of(world.TerrainDrawParams),
	)
	sdl.DrawGPUIndexedPrimitives(render_pass, geometry.index_count, 1, geometry.first_index, 0, 0)

	state.render_stats.terrain_faces_drawn += geometry.index_count / 6
	state.render_stats.terrain_triangles_drawn += geometry.index_count / 3
	state.render_stats.terrain_indices_drawn += geometry.index_count
}

terrain_draw_visible :: proc(
	cmdbuf: ^sdl.GPUCommandBuffer,
	render_pass: ^sdl.GPURenderPass,
	frustum: camera.Frustum,
) {
	culling_stats := camera.TerrainCullingStats{}
	observer := world.chunk_visibility_observer_from_world_position(state.camera.position)

	if !world.chunk_store_subchunk_geometry_has_any() {
		ctx := TerrainSubmitContext {
			cmdbuf      = cmdbuf,
			render_pass = render_pass,
		}
		terrain_draw_begin(cmdbuf, render_pass)
		camera.terrain_visible_unsorted_walk(
			frustum,
			observer,
			&culling_stats,
			terrain_draw_item_submit,
			rawptr(&ctx),
		)
		terrain_culling_stats_apply(culling_stats)
		return
	}

	chunks := world.chunk_store_chunks()
	draw_item_capacity := len(chunks) + int(world.chunk_store_subchunk_geometry_count())
	sort_visible := camera.terrain_visible_items_should_sort(draw_item_capacity)
	if !sort_visible {
		ctx := TerrainSubmitContext {
			cmdbuf      = cmdbuf,
			render_pass = render_pass,
		}
		terrain_draw_begin(cmdbuf, render_pass)
		camera.terrain_visible_unsorted_walk(
			frustum,
			observer,
			&culling_stats,
			terrain_draw_item_submit,
			rawptr(&ctx),
		)
		terrain_culling_stats_apply(culling_stats)
		return
	}

	draw_items := make([]camera.TerrainDrawItem, draw_item_capacity, state.transient_allocator)
	draw_count := camera.terrain_visible_items_gather(
		frustum,
		observer,
		state.camera.position,
		draw_items,
		&culling_stats,
		sort_visible,
	)
	visible_items := draw_items[:draw_count]
	if sort_visible && len(visible_items) > 1 {
		slice.sort_by(visible_items, camera.terrain_draw_item_less)
	}
	culling_stats.draw_units_drawn = u32(draw_count)
	terrain_draw_items(cmdbuf, render_pass, visible_items)
	terrain_culling_stats_apply(culling_stats)
}

//////////////////////////////////////
// Rendering Methods
/////////////////////////////////////

render :: proc() -> RenderStats {
	state.render_stats = {}
	cmdbuf := sdl.AcquireGPUCommandBuffer(state.device)
	log.assertf(cmdbuf != nil, "AcquireGPUCommandBuffer failed: %s", sdl.GetError())

	swapchain_texture: ^sdl.GPUTexture
	swapchain_acquired := sdl.WaitAndAcquireGPUSwapchainTexture(
		cmdbuf,
		state.window,
		&swapchain_texture,
		nil,
		nil,
	)
	log.assertf(swapchain_acquired, "WaitAndAcquireGPUSwapchainTexture failed: %s", sdl.GetError())

	if (swapchain_texture != nil) {
		frustum := camera.frustum_from_camera(state.camera, math.to_radians_f32(FOV), ASPECT_RATIO)

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

		terrain_draw_visible(cmdbuf, render_pass, frustum)

		sdl.EndGPURenderPass(render_pass)
	}

	if geometry_deferred_releases_has_pending_fence(&state.geometry_pool) {
		fence := sdl.SubmitGPUCommandBufferAndAcquireFence(cmdbuf)
		log.assertf(fence != nil, "SubmitGPUCommandBufferAndAcquireFence: %s", sdl.GetError())
		geometry_deferred_releases_attach_pending_to_fence(&state.geometry_pool, fence)
	} else {
		submitted := sdl.SubmitGPUCommandBuffer(cmdbuf)
		log.assertf(submitted, "SubmitGPUCommandBuffer: %s", sdl.GetError())
	}
	geometry_deferred_releases_poll(&state.geometry_pool)
	state.render_stats.deferred_geometry_count = state.geometry_pool.deferred_release_count
	state.render_stats.deferred_release_enqueued_total =
		state.geometry_pool.deferred_release_enqueued_total
	state.render_stats.deferred_release_completed_total =
		state.geometry_pool.deferred_release_completed_total
	return state.render_stats
}
