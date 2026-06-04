package main

// todo: we have several things we need to do before starting to work on voxel part:
// - do we want to use PVP (yes)
// - do we want to utilize instanced rendering
// - do we want to utlize indirect rendering

import sdl "vendor:sdl3"

import "base:runtime"
import "core:c"
import "core:log"
import "core:math"
import la "core:math/linalg"
import "core:mem"
import "core:os"
import "core:strings"

//////////////////////////////////////
// Memory
//////////////////////////////////////

persistent_slab: [64 * mem.Megabyte]u8
transient_slab: [16 * mem.Megabyte]u8
persistent_arena: mem.Arena
transient_arena: mem.Arena
persistent_allocator: mem.Allocator
transient_allocator: mem.Allocator

//////////////////////////////////////
// Window & GPU
//////////////////////////////////////

window: ^sdl.Window
device: ^sdl.GPUDevice

//////////////////////////////////////
// Types
/////////////////////////////////////

ShaderType :: enum {
	Vertex,
	Fragment,
}

Camera :: struct {
	position:   [3]f32,
	forward:    [3]f32,
	up:         [3]f32,
	right:      [3]f32,
	world_up:   [3]f32,
	yaw:        f32,
	pitch:      f32,
	near_plane: f32,
	far_plane:  f32,
}

///////////////////////////////////////////
// Geometry
///////////////////////////////////////////

GeometryID :: distinct u32

GeometryVertex :: struct {
	position: [4]f32,
	color:    [4]f32,
}

Geometry :: struct {
	vertex_offset: u32, // GeometryVertex elements
	vertex_count:  u32,
	index_offset:  u32, // u32 elements
	index_count:   u32,
}

GeometryDrawParams :: struct {
	vertex_offset: u32, // GeometryVertex elements; added in shader after indexed SV_VertexID
	_padding:      [3]u32, // extra padding for alignment
}

GeometryPool :: struct {
	geometries:             []Geometry,
	geometry_count:         u32,
	vertex_buffer:          ^sdl.GPUBuffer,
	index_buffer:           ^sdl.GPUBuffer,
	vertex_upload_buffer:   ^sdl.GPUTransferBuffer,
	index_upload_buffer:    ^sdl.GPUTransferBuffer,
	vertex_capacity:        u32,
	vertex_count:           u32,
	index_capacity:         u32,
	index_count:            u32,
	vertex_upload_capacity: u32, // bytes
	index_upload_capacity:  u32, // bytes
}

INVALID_GEOMETRY_ID :: GeometryID(0)
GEOMETRY_MAX_GEOMETRIES :: 1024
GEOMETRY_MAX_VERTICES :: 1_000_000
GEOMETRY_MAX_INDICES :: 3_000_000
GEOMETRY_MAX_UPLOAD_VERTICES :: 65_536
GEOMETRY_MAX_UPLOAD_INDICES :: 196_608

geometry_init :: proc(
	pool: ^GeometryPool,
	max_geometries, max_vertices, max_indices, max_upload_vertices, max_upload_indices: u32,
) {
	log.assertf(
		max_geometries > 0 && max_geometries <= GEOMETRY_MAX_GEOMETRIES,
		"max_geometries must be in range 1..%d (got %d)",
		GEOMETRY_MAX_GEOMETRIES,
		max_geometries,
	)
	log.assertf(
		max_vertices > 0 && max_vertices <= GEOMETRY_MAX_VERTICES,
		"max_vertices must be in range 1..%d (got %d)",
		GEOMETRY_MAX_VERTICES,
		max_vertices,
	)
	log.assertf(
		max_indices > 0 && max_indices <= GEOMETRY_MAX_INDICES,
		"max_indices must be in range 1..%d (got %d)",
		GEOMETRY_MAX_INDICES,
		max_indices,
	)
	log.assertf(
		max_upload_vertices > 0 && max_upload_vertices <= GEOMETRY_MAX_UPLOAD_VERTICES,
		"max_upload_vertices must be in range 1..%d (got %d)",
		GEOMETRY_MAX_UPLOAD_VERTICES,
		max_upload_vertices,
	)
	log.assertf(
		max_upload_indices > 0 && max_upload_indices <= GEOMETRY_MAX_UPLOAD_INDICES,
		"max_upload_indices must be in range 1..%d (got %d)",
		GEOMETRY_MAX_UPLOAD_INDICES,
		max_upload_indices,
	)
	log.assertf(
		max_upload_vertices <= max_vertices,
		"max_upload_vertices must fit inside max_vertices",
	)
	log.assertf(
		max_upload_indices <= max_indices,
		"max_upload_indices must fit inside max_indices",
	)

	vertex_buffer_size_wide := u64(max_vertices) * u64(size_of(GeometryVertex))
	index_buffer_size_wide := u64(max_indices) * u64(size_of(u32))
	vertex_upload_size_wide := u64(max_upload_vertices) * u64(size_of(GeometryVertex))
	index_upload_size_wide := u64(max_upload_indices) * u64(size_of(u32))

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
	log.assertf(
		vertex_upload_size_wide <= u64(max(u32)),
		"vertex upload buffer size exceeds u32: %d",
		vertex_upload_size_wide,
	)
	log.assertf(
		index_upload_size_wide <= u64(max(u32)),
		"index upload buffer size exceeds u32: %d",
		index_upload_size_wide,
	)

	vertex_buffer_size := u32(vertex_buffer_size_wide)
	index_buffer_size := u32(index_buffer_size_wide)
	vertex_upload_size := u32(vertex_upload_size_wide)
	index_upload_size := u32(index_upload_size_wide)

	pool^ = GeometryPool{}
	pool.geometries = make([]Geometry, max_geometries)
	pool.vertex_capacity = max_vertices
	pool.index_capacity = max_indices
	pool.vertex_upload_capacity = vertex_upload_size
	pool.index_upload_capacity = index_upload_size

	pool.vertex_buffer = sdl.CreateGPUBuffer(
		device,
		sdl.GPUBufferCreateInfo {
			// Read by Mesh.vert as ByteAddressBuffer for programmable vertex pulling.
			usage = {.GRAPHICS_STORAGE_READ},
			size  = vertex_buffer_size,
		},
	)
	log.assertf(pool.vertex_buffer != nil, "CreateGPUBuffer vertex failed: %s", sdl.GetError())

	pool.index_buffer = sdl.CreateGPUBuffer(
	device,
	sdl.GPUBufferCreateInfo {
		// Keep this as a real SDL index buffer so indexed draws and vertex reuse still work.
		usage = {.INDEX},
		size  = index_buffer_size,
	},
	)
	log.assertf(pool.index_buffer != nil, "CreateGPUBuffer index failed: %s", sdl.GetError())


	pool.vertex_upload_buffer = sdl.CreateGPUTransferBuffer(
		device,
		sdl.GPUTransferBufferCreateInfo {
			usage = sdl.GPUTransferBufferUsage.UPLOAD,
			size = pool.vertex_upload_capacity,
		},
	)
	log.assertf(
		pool.vertex_upload_buffer != nil,
		"CreateGPUTransferBuffer for vertex upload failed: %s",
		sdl.GetError(),
	)

	pool.index_upload_buffer = sdl.CreateGPUTransferBuffer(
		device,
		sdl.GPUTransferBufferCreateInfo {
			usage = sdl.GPUTransferBufferUsage.UPLOAD,
			size = pool.index_upload_capacity,
		},
	)
	log.assertf(
		pool.index_upload_buffer != nil,
		"CreateGPUTransferBuffer for index upload failed: %s",
		sdl.GetError(),
	)

	log.debugf(
		"GeometryPool initialized: vertex_capacity=%d index_capacity=%d vertex_upload_capacity=%d index_upload_capacity=%d",
		pool.vertex_capacity,
		pool.index_capacity,
		pool.vertex_upload_capacity,
		pool.index_upload_capacity,
	)
}

geometry_destroy :: proc(pool: ^GeometryPool) {
	if pool.vertex_upload_buffer != nil {
		sdl.ReleaseGPUTransferBuffer(device, pool.vertex_upload_buffer)
	}

	if pool.index_upload_buffer != nil {
		sdl.ReleaseGPUTransferBuffer(device, pool.index_upload_buffer)
	}

	if pool.vertex_buffer != nil {
		sdl.ReleaseGPUBuffer(device, pool.vertex_buffer)
	}

	if pool.index_buffer != nil {
		sdl.ReleaseGPUBuffer(device, pool.index_buffer)
	}

	pool.geometry_count = 0
	pool.vertex_capacity = 0
	pool.index_capacity = 0
	pool.vertex_upload_capacity = 0
	pool.index_upload_capacity = 0
}

geometry_append :: proc(
	pool: ^GeometryPool,
	vertices: []GeometryVertex,
	indices: []u32,
) -> GeometryID {
	log.assertf(len(vertices) > 0, "vertices must not be empty")
	log.assertf(len(indices) > 0, "indices must not be empty")
	log.assertf(u64(len(vertices)) <= u64(max(u32)), "vertex count exceeds u32: %d", len(vertices))
	log.assertf(u64(len(indices)) <= u64(max(u32)), "index count exceeds u32: %d", len(indices))
	log.assertf(u64(pool.geometry_count) < u64(len(pool.geometries)), "geometry pool is full")

	vertex_count := u32(len(vertices))
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

	vertex_bytes_wide := u64(vertex_count) * u64(size_of(GeometryVertex))
	index_bytes_wide := u64(index_count) * u64(size_of(u32))
	log.assertf(
		vertex_bytes_wide <= u64(max(u32)),
		"vertex append size exceeds u32: %d",
		vertex_bytes_wide,
	)
	log.assertf(
		index_bytes_wide <= u64(max(u32)),
		"index append size exceeds u32: %d",
		index_bytes_wide,
	)

	vertex_bytes := u32(vertex_bytes_wide)
	index_bytes := u32(index_bytes_wide)

	log.assertf(
		u64(pool.vertex_count) + u64(vertex_count) <= u64(pool.vertex_capacity),
		"geometry vertex capacity exceeded",
	)
	log.assertf(
		u64(pool.index_count) + u64(index_count) <= u64(pool.index_capacity),
		"geometry index capacity exceeded",
	)
	log.assertf(
		vertex_bytes <= pool.vertex_upload_capacity,
		"geometry vertex append exceeds upload buffer capacity",
	)
	log.assertf(
		index_bytes <= pool.index_upload_capacity,
		"geometry index append exceeds upload buffer capacity",
	)

	geometry := Geometry {
		vertex_count  = vertex_count,
		index_count   = index_count,
		vertex_offset = pool.vertex_count,
		index_offset  = pool.index_count,
	}

	geometry_index := pool.geometry_count
	id := GeometryID(geometry_index + 1)

	vertex_dst_offset_wide := u64(geometry.vertex_offset) * u64(size_of(GeometryVertex))
	index_dst_offset_wide := u64(geometry.index_offset) * u64(size_of(u32))
	log.assertf(
		vertex_dst_offset_wide <= u64(max(u32)),
		"vertex destination offset exceeds u32: %d",
		vertex_dst_offset_wide,
	)
	log.assertf(
		index_dst_offset_wide <= u64(max(u32)),
		"index destination offset exceeds u32: %d",
		index_dst_offset_wide,
	)

	vertex_dst_offset := u32(vertex_dst_offset_wide)
	index_dst_offset := u32(index_dst_offset_wide)

	mapped_data := sdl.MapGPUTransferBuffer(device, pool.vertex_upload_buffer, false)
	log.assertf(mapped_data != nil, "MapGPUTransferBuffer vertex failed: %s", sdl.GetError())
	mem.copy(mapped_data, raw_data(vertices), int(vertex_bytes))
	sdl.UnmapGPUTransferBuffer(device, pool.vertex_upload_buffer)

	mapped_data = sdl.MapGPUTransferBuffer(device, pool.index_upload_buffer, false)
	log.assertf(mapped_data != nil, "MapGPUTransferBuffer index failed: %s", sdl.GetError())
	mem.copy(mapped_data, raw_data(indices), int(index_bytes))
	sdl.UnmapGPUTransferBuffer(device, pool.index_upload_buffer)

	upload_cmd_buf := sdl.AcquireGPUCommandBuffer(device)
	log.assertf(upload_cmd_buf != nil, "AcquireGPUCommandBuffer failed: %s", sdl.GetError())
	copy_pass := sdl.BeginGPUCopyPass(upload_cmd_buf)

	sdl.UploadToGPUBuffer(
		copy_pass,
		sdl.GPUTransferBufferLocation{transfer_buffer = pool.vertex_upload_buffer, offset = 0},
		sdl.GPUBufferRegion {
			buffer = pool.vertex_buffer,
			offset = vertex_dst_offset,
			size = vertex_bytes,
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

	pool.geometries[geometry_index] = geometry
	pool.geometry_count += 1
	pool.vertex_count += vertex_count
	pool.index_count += index_count

	return id
}

geometry_get :: proc(pool: ^GeometryPool, id: GeometryID) -> Geometry {
	log.assertf(id != INVALID_GEOMETRY_ID, "Invalid geometry ID: %d", u32(id))
	geometry_index := u32(id) - 1
	log.assertf(geometry_index < pool.geometry_count, "Geometry ID out of bounds: %d", u32(id))
	return pool.geometries[geometry_index]
}

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
VELOCITY :: f32(1.5)
MOUSE_SENSITIVITY :: f32(0.0025)

cube_vertices := [?]GeometryVertex {
	{position = {-0.5, -0.5, -0.5, 0.0}, color = {1.0, 0.1, 0.1, 1.0}},
	{position = {0.5, -0.5, -0.5, 0.0}, color = {0.1, 1.0, 0.1, 1.0}},
	{position = {0.5, 0.5, -0.5, 0.0}, color = {0.1, 0.1, 1.0, 1.0}},
	{position = {-0.5, 0.5, -0.5, 0.0}, color = {1.0, 1.0, 0.1, 1.0}},
	{position = {-0.5, -0.5, 0.5, 0.0}, color = {1.0, 0.1, 1.0, 1.0}},
	{position = {0.5, -0.5, 0.5, 0.0}, color = {0.1, 1.0, 1.0, 1.0}},
	{position = {0.5, 0.5, 0.5, 0.0}, color = {1.0, 1.0, 1.0, 1.0}},
	{position = {-0.5, 0.5, 0.5, 0.0}, color = {0.2, 0.6, 1.0, 1.0}},
}

cube_indices := [?]u32 {
	0,
	2,
	1,
	2,
	0,
	3,
	1,
	6,
	5,
	6,
	1,
	2,
	5,
	7,
	4,
	7,
	5,
	6,
	4,
	3,
	0,
	3,
	4,
	7,
	3,
	6,
	2,
	6,
	3,
	7,
	4,
	1,
	5,
	1,
	4,
	0,
}

//////////////////////////////////////
// State
/////////////////////////////////////

geometry_pool: GeometryPool

depth_texture: ^sdl.GPUTexture
fill_pipeline: ^sdl.GPUGraphicsPipeline
line_pipeline: ^sdl.GPUGraphicsPipeline

test_cube_geometry_id: GeometryID
mvp: matrix[4, 4]f32
camera := Camera {
	position   = {0.0, 0.0, -5.0},
	forward    = {0.0, 0.0, 1.0},
	up         = {0.0, 1.0, 0.0},
	right      = {1.0, 0.0, 0.0},
	world_up   = {0.0, 1.0, 0.0},
	yaw        = 0.0,
	pitch      = 0.0,
	near_plane = 0.1,
	far_plane  = 100.0,
}


debug_mode := true
enable_vsync := true
use_wireframe_mode := false


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
// Systems
/////////////////////////////////////

init :: proc() {
	log.debug("Init application")

	log.assertf(sdl.Init({.VIDEO}), "Failed to initialize SDL: %s", sdl.GetError())

	device = sdl.CreateGPUDevice({.DXIL}, debug_mode, nil)
	log.assertf(device != nil, "Failed to create GPU device: %s", sdl.GetError())

	window = sdl.CreateWindow(
		"Voxels Engine",
		WINDOW_DEFAULT_WIDTH,
		WINDOW_DEFAULT_HEIGHT,
		{.RESIZABLE},
	)
	log.assertf(window != nil, "Failed to create window: %s", sdl.GetError())
	log.assertf(
		sdl.SetWindowRelativeMouseMode(window, true),
		"Failed to enable relative mouse mode: %s",
		sdl.GetError(),
	)

	log.assertf(
		sdl.ClaimWindowForGPUDevice(device, window),
		"Failed to claim window for GPU device: %s",
		sdl.GetError(),
	)

	log.assertf(
		sdl.SetGPUSwapchainParameters(
			device,
			window,
			sdl.GPUSwapchainComposition.SDR,
			enable_vsync ? sdl.GPUPresentMode.VSYNC : sdl.GPUPresentMode.IMMEDIATE,
		),
		"Failed to set GPU swapchain parameters: %s",
		sdl.GetError(),
	)

	sdl.SetLogOutputFunction(sdl_log_output, nil)
	sdl.SetLogPriority(.GPU, .DEBUG)

	log.debug("Application initialized")
}

shutdown :: proc() {
	log.debug("Application shutdown")
	sdl.ReleaseWindowFromGPUDevice(device, window)
	sdl.DestroyGPUDevice(device)
	sdl.DestroyWindow(window)
	sdl.Quit()
	log.debug("Shutdown complete")
}

setup_resources :: proc() {
	log.debug("Setting resources")

	geometry_init(
		&geometry_pool,
		GEOMETRY_MAX_GEOMETRIES,
		GEOMETRY_MAX_VERTICES,
		GEOMETRY_MAX_INDICES,
		GEOMETRY_MAX_UPLOAD_VERTICES,
		GEOMETRY_MAX_UPLOAD_INDICES,
	)

	// Mesh.vert uses one vertex storage buffer for PVP geometry bytes.
	// Indices are bound through SDL's hardware index-buffer path, not as shader storage.
	vert_shader, _ := load_shader("assets/shaders/Mesh.vert.dxil", 0, 2, 1, 0)
	frag_shader, _ := load_shader("assets/shaders/SolidColor.frag.dxil", 0, 0, 0, 0)

	// Create the pipelines
	color_target_descriptions := [?]sdl.GPUColorTargetDescription {
		{format = sdl.GetGPUSwapchainTextureFormat(device, window)},
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
	fill_pipeline = sdl.CreateGPUGraphicsPipeline(device, pipeline_create_info)
	log.assert(fill_pipeline != nil, "Failed to create fill pipeline!")

	pipeline_create_info.rasterizer_state.fill_mode = sdl.GPUFillMode.LINE
	line_pipeline = sdl.CreateGPUGraphicsPipeline(device, pipeline_create_info)
	log.assert(line_pipeline != nil, "Failed to create line pipeline!")

	sdl.ReleaseGPUShader(device, frag_shader)
	sdl.ReleaseGPUShader(device, vert_shader)

	w, h: c.int
	sdl.GetWindowSizeInPixels(window, &w, &h)

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

	depth_texture = sdl.CreateGPUTexture(
		device,
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
	log.assert(depth_texture != nil, "Failed to create depth texture!")

	test_cube_geometry_id = geometry_append(&geometry_pool, cube_vertices[:], cube_indices[:])

	log.debug("Resources initialized")
}

destroy_resources :: proc() {
	log.debug("Destroying resources")
	log.assertf(sdl.WaitForGPUIdle(device), "WaitForGPUIdle failed: %s", sdl.GetError())
	geometry_destroy(&geometry_pool)
	sdl.ReleaseGPUTexture(device, depth_texture)
	sdl.ReleaseGPUGraphicsPipeline(device, fill_pipeline)
	sdl.ReleaseGPUGraphicsPipeline(device, line_pipeline)
	log.debug("Resources destroyed")
}

render :: proc() {
	log.assertf(test_cube_geometry_id != INVALID_GEOMETRY_ID, "Test cube geometry ID is invalid")
	geometry := geometry_get(&geometry_pool, test_cube_geometry_id)

	cmdbuf := sdl.AcquireGPUCommandBuffer(device)
	log.assertf(cmdbuf != nil, "AcquireGPUCommandBuffer failed: %s", sdl.GetError())

	swapchain_texture: ^sdl.GPUTexture
	log.assertf(
		sdl.WaitAndAcquireGPUSwapchainTexture(cmdbuf, window, &swapchain_texture, nil, nil),
		"WaitAndAcquireGPUSwapchainTexture failed: %s",
		sdl.GetError(),
	)

	if (swapchain_texture != nil) {
		colorTargetInfo := sdl.GPUColorTargetInfo{}
		colorTargetInfo.texture = swapchain_texture
		colorTargetInfo.clear_color = sdl.FColor{0.05, 0.10, 0.20, 1.0}
		colorTargetInfo.load_op = sdl.GPULoadOp.CLEAR
		colorTargetInfo.store_op = sdl.GPUStoreOp.STORE

		depthTargetInfo := sdl.GPUDepthStencilTargetInfo{}
		depthTargetInfo.texture = depth_texture
		depthTargetInfo.clear_depth = DEPTH_CLEAR_VALUE
		depthTargetInfo.load_op = sdl.GPULoadOp.CLEAR
		depthTargetInfo.store_op = sdl.GPUStoreOp.DONT_CARE
		depthTargetInfo.stencil_load_op = sdl.GPULoadOp.DONT_CARE
		depthTargetInfo.stencil_store_op = sdl.GPUStoreOp.DONT_CARE

		draw_params := GeometryDrawParams {
			vertex_offset = geometry.vertex_offset,
		}
		sdl.PushGPUVertexUniformData(cmdbuf, 0, &mvp, cast(u32)size_of(matrix[4, 4]f32))
		sdl.PushGPUVertexUniformData(cmdbuf, 1, &draw_params, cast(u32)size_of(GeometryDrawParams))

		render_pass := sdl.BeginGPURenderPass(cmdbuf, &colorTargetInfo, 1, &depthTargetInfo)
		sdl.BindGPUGraphicsPipeline(
			render_pass,
			use_wireframe_mode ? line_pipeline : fill_pipeline,
		)

		// Hardware indexed PVP: SDL applies the index buffer, then Mesh.vert
		// pulls the selected vertex from the geometry storage buffer.
		storage_buffers := [?]^sdl.GPUBuffer{geometry_pool.vertex_buffer}
		sdl.BindGPUVertexStorageBuffers(render_pass, 0, raw_data(storage_buffers[:]), 1)
		sdl.BindGPUIndexBuffer(
			render_pass,
			sdl.GPUBufferBinding{buffer = geometry_pool.index_buffer, offset = 0},
			sdl.GPUIndexElementSize._32BIT,
		)
		sdl.DrawGPUIndexedPrimitives(
			render_pass,
			geometry.index_count,
			1,
			geometry.index_offset,
			0,
			0,
		)
		sdl.EndGPURenderPass(render_pass)
	}

	log.assertf(sdl.SubmitGPUCommandBuffer(cmdbuf), "SubmitGPUCommandBuffer: %s", sdl.GetError())
}

update_camera_vectors :: proc() {
	camera.forward = la.normalize(
		la.Vector3f32 {
			math.sin(camera.yaw) * math.cos(camera.pitch),
			math.sin(camera.pitch),
			math.cos(camera.yaw) * math.cos(camera.pitch),
		},
	)

	camera.right = la.normalize(la.cross(camera.world_up, camera.forward))
	camera.up = la.normalize(la.cross(camera.forward, camera.right))
}

update :: proc() {
	model := la.matrix4_rotate_f32(ANGLE, la.Vector3f32{0, 1, 0})
	view := la.matrix4_look_at_f32(camera.position, camera.position + camera.forward, camera.up)
	proj := la.matrix4_perspective_f32(math.to_radians_f32(FOV), ASPECT_RATIO, 0.1, 100.0)
	mvp = proj * view * model
}

move_camera :: proc(dt: f32) {
	key_count: c.int
	keys := sdl.GetKeyboardState(&key_count)
	speed := VELOCITY * dt

	if keys[cast(int)sdl.Scancode.W] {camera.position += camera.forward * speed}
	if keys[cast(int)sdl.Scancode.S] {camera.position -= camera.forward * speed}
	if keys[cast(int)sdl.Scancode.D] {camera.position -= camera.right * speed}
	if keys[cast(int)sdl.Scancode.A] {camera.position += camera.right * speed}
}

load_shader :: proc(
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

	temp := mem.begin_arena_temp_memory(&transient_arena)
	defer mem.end_arena_temp_memory(temp)

	code, err := os.read_entire_file_from_path(filename, transient_allocator)
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
	shader := sdl.CreateGPUShader(device, shader_info)
	log.assertf(shader != nil, "Failed to create shader: %s", sdl.GetError())

	log.debugf("Shader %s created: %s", shader_type, filename)

	return shader, shader_type
}

//////////////////////////////////////
// Main
/////////////////////////////////////

main :: proc() {
	context.logger = log.create_console_logger(.Debug)
	defer log.destroy_console_logger(context.logger)

	mem.arena_init(&persistent_arena, persistent_slab[:])
	mem.arena_init(&transient_arena, transient_slab[:])

	transient_allocator = mem.arena_allocator(&transient_arena)
	persistent_allocator = mem.arena_allocator(&persistent_arena)

	context.allocator = persistent_allocator

	init()
	defer shutdown()

	setup_resources()
	defer destroy_resources()

	current_time := sdl.GetTicks()
	loop: for {
		now := sdl.GetTicks()
		dt := cast(f32)(now - current_time) / 1000.0
		current_time = now

		for event: sdl.Event; sdl.PollEvent(&event); {
			#partial switch event.type {
			case .QUIT:
				log.debug("Quit event received")
				break loop
			case .KEY_DOWN:
				{
					if event.key.scancode == sdl.Scancode.ESCAPE {
						log.debug("Escape key pressed")
						break loop
					}

					if event.key.scancode == sdl.Scancode.G && !event.key.repeat {
						use_wireframe_mode = !use_wireframe_mode
					}
				}
			case .MOUSE_MOTION:
				{
					camera.yaw -= event.motion.xrel * MOUSE_SENSITIVITY
					camera.pitch -= event.motion.yrel * MOUSE_SENSITIVITY
					camera.pitch = math.clamp(
						camera.pitch,
						math.to_radians_f32(-89.0),
						math.to_radians_f32(89.0),
					)
				}
			}
		}

		update_camera_vectors()
		move_camera(dt)
		update()
		render()
	}
}
