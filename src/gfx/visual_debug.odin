package gfx

import vdebug "app:vdebug"
import world "app:world"
import sdl "vendor:sdl3"

import json "core:encoding/json"
import "core:fmt"
import la "core:math/linalg"
import "core:mem"
import slice "core:slice"
import "core:strings"

GPU_VISUAL_PALETTE :: "gpu_object_pipeline.v1"

visual_debug_register :: proc(registry: ^vdebug.VisualDebugRegistry) {
	gpu_visual_case_register(registry, "gfx.capture.terrain_window")
	gpu_visual_case_register(registry, "gfx.capture.object_turntable")
	gpu_visual_case_register(registry, "gfx.capture.debug_overlay")
}

gpu_visual_case_register :: proc(registry: ^vdebug.VisualDebugRegistry, name: string) {
	vdebug.register(
		registry,
		name,
		gpu_visual_configure,
		gpu_visual_run,
		{
			data_size = 0,
			data_align = mem.DEFAULT_ALIGNMENT,
			flags = {
				.Serial_Only,
				.Mutates_Global_State,
				.Requires_Gfx,
				.Runtime_Owns_Main_Loop,
				.Emits_Artifacts,
			},
			category = "gfx.capture",
			version = "1",
		},
	)
}

gpu_visual_configure :: proc(
	ctx: ^vdebug.VisualDebugConfigContext,
	request: json.Object,
	data: rawptr,
) -> vdebug.VisualDebugStatus {
	_ = ctx
	_ = request
	_ = data
	return vdebug.status_pass()
}

gpu_visual_run :: proc(
	ctx: ^vdebug.VisualDebugContext,
	data: rawptr,
	mode: json.Object,
) -> vdebug.VisualDebugStatus {
	_ = data

	width := u32(vdebug.json_i64_default(mode, "width", 64))
	height := u32(vdebug.json_i64_default(mode, "height", 64))
	if width == 0 ||
	   height == 0 ||
	   width > vdebug.VISUAL_DEBUG_MAX_IMAGE_DIMENSION ||
	   height > vdebug.VISUAL_DEBUG_MAX_IMAGE_DIMENSION {
		return vdebug.status_fail("GPU capture dimensions are out of bounds")
	}
	if ctx.case_name != "gfx.capture.object_turntable" {
		return vdebug.status_fail(
			"this GPU visual case is registered but does not have an isolated fixture yet; use gfx.capture.object_turntable",
		)
	}

	if state.initialized {
		return vdebug.status_fail("GPU visual capture requires exclusive gfx state")
	}

	scratch := make([]u8, 16 * mem.Megabyte, ctx.allocator)
	defer delete(scratch, ctx.allocator)
	capture_arena := mem.Arena{}
	mem.arena_init(&capture_arena, scratch)
	capture_allocator := mem.arena_allocator(&capture_arena)

	init(
		{
			persistent_allocator = ctx.allocator,
			transient_allocator = capture_allocator,
			transient_arena = &capture_arena,
			debug_mode = false,
			enable_vsync = false,
			window_width = i32(width),
			window_height = i32(height),
			capture_mode = true,
		},
	)
	setup_resources()
	defer {
		if state.resources_ready {
			destroy_resources()
		}
		shutdown()
	}

	format := sdl.GetGPUSwapchainTextureFormat(state.device, state.window)

	texture := sdl.CreateGPUTexture(
		state.device,
		sdl.GPUTextureCreateInfo {
			type = sdl.GPUTextureType.D2,
			width = width,
			height = height,
			layer_count_or_depth = 1,
			num_levels = 1,
			sample_count = sdl.GPUSampleCount._1,
			format = format,
			usage = {.COLOR_TARGET},
		},
	)
	if texture == nil {
		return vdebug.status_fail(
			fmt.aprintf("GPU capture texture creation failed: %s", sdl.GetError()),
		)
	}
	defer sdl.ReleaseGPUTexture(state.device, texture)

	readback_size := width * height * 4
	transfer := sdl.CreateGPUTransferBuffer(
		state.device,
		sdl.GPUTransferBufferCreateInfo {
			usage = sdl.GPUTransferBufferUsage.DOWNLOAD,
			size = readback_size,
		},
	)
	if transfer == nil {
		return vdebug.status_fail(
			fmt.aprintf("GPU transfer buffer creation failed: %s", sdl.GetError()),
		)
	}
	defer sdl.ReleaseGPUTransferBuffer(state.device, transfer)

	geometry_id := gpu_visual_object_upload()
	if geometry_id == INVALID_GEOMETRY_ID {
		return vdebug.status_fail("GPU visual object fixture produced no geometry")
	}
	geometry := geometry_get(&state.geometry_pool, geometry_id)
	upload_idle := sdl.WaitForGPUIdle(state.device)
	if !upload_idle {
		return vdebug.status_fail(fmt.aprintf("GPU object upload wait failed: %s", sdl.GetError()))
	}

	cmdbuf := sdl.AcquireGPUCommandBuffer(state.device)
	if cmdbuf == nil {
		return vdebug.status_fail(
			fmt.aprintf("GPU command buffer acquisition failed: %s", sdl.GetError()),
		)
	}

	clear := gpu_visual_clear_color(ctx.case_name)
	color_target := sdl.GPUColorTargetInfo {
		texture     = texture,
		clear_color = clear,
		load_op     = sdl.GPULoadOp.CLEAR,
		store_op    = sdl.GPUStoreOp.STORE,
	}
	depth_target := sdl.GPUDepthStencilTargetInfo {
		texture          = state.depth_texture,
		clear_depth      = DEPTH_CLEAR_VALUE,
		load_op          = sdl.GPULoadOp.CLEAR,
		store_op         = sdl.GPUStoreOp.DONT_CARE,
		stencil_load_op  = sdl.GPULoadOp.DONT_CARE,
		stencil_store_op = sdl.GPUStoreOp.DONT_CARE,
	}
	render_pass := sdl.BeginGPURenderPass(cmdbuf, &color_target, 1, &depth_target)
	if render_pass == nil {
		return vdebug.status_fail(
			fmt.aprintf("GPU render pass creation failed: %s", sdl.GetError()),
		)
	}
	viewport := sdl.GPUViewport {
		x         = 0,
		y         = 0,
		w         = f32(width),
		h         = f32(height),
		min_depth = 0,
		max_depth = 1,
	}
	sdl.SetGPUViewport(render_pass, viewport)
	storage_buffers := [?]^sdl.GPUBuffer{state.geometry_pool.vertex_buffer}
	sdl.BindGPUVertexStorageBuffers(render_pass, 0, raw_data(storage_buffers[:]), 1)
	sdl.BindGPUIndexBuffer(
		render_pass,
		sdl.GPUBufferBinding{buffer = state.geometry_pool.index_buffer, offset = 0},
		sdl.GPUIndexElementSize._32BIT,
	)
	state.mvp = la.identity(matrix[4, 4]f32)
	sdl.PushGPUVertexUniformData(cmdbuf, 0, &state.mvp, cast(u32)size_of(matrix[4, 4]f32))
	draw_params := GeometryDrawParams {
		vertex_byte_offset  = geometry.vertex_byte_offset,
		vertex_stride_bytes = geometry.vertex_stride_bytes,
	}
	sdl.PushGPUVertexUniformData(cmdbuf, 1, &draw_params, cast(u32)size_of(GeometryDrawParams))
	sdl.BindGPUGraphicsPipeline(render_pass, state.prototype_fill_pipeline)
	sdl.DrawGPUIndexedPrimitives(render_pass, geometry.index_count, 1, geometry.first_index, 0, 0)
	sdl.EndGPURenderPass(render_pass)

	copy_pass := sdl.BeginGPUCopyPass(cmdbuf)
	if copy_pass == nil {
		return vdebug.status_fail(fmt.aprintf("GPU copy pass creation failed: %s", sdl.GetError()))
	}
	source := sdl.GPUTextureRegion {
		texture = texture,
		w       = width,
		h       = height,
		d       = 1,
	}
	destination := sdl.GPUTextureTransferInfo {
		transfer_buffer = transfer,
		pixels_per_row  = width,
		rows_per_layer  = height,
	}
	sdl.DownloadFromGPUTexture(copy_pass, source, destination)
	sdl.EndGPUCopyPass(copy_pass)

	fence := sdl.SubmitGPUCommandBufferAndAcquireFence(cmdbuf)
	if fence == nil {
		return vdebug.status_fail(fmt.aprintf("GPU command submission failed: %s", sdl.GetError()))
	}
	fences := [?]^sdl.GPUFence{fence}
	if !sdl.WaitForGPUFences(state.device, true, raw_data(fences[:]), 1) {
		sdl.ReleaseGPUFence(state.device, fence)
		return vdebug.status_fail(
			fmt.aprintf("GPU readback fence wait failed: %s", sdl.GetError()),
		)
	}
	sdl.ReleaseGPUFence(state.device, fence)

	mapped := sdl.MapGPUTransferBuffer(state.device, transfer, false)
	if mapped == nil {
		return vdebug.status_fail(
			fmt.aprintf("GPU transfer buffer map failed: %s", sdl.GetError()),
		)
	}
	defer sdl.UnmapGPUTransferBuffer(state.device, transfer)

	readback := slice.bytes_from_ptr(mapped, int(readback_size))
	pixels := make([]vdebug.PixelRGBA8, int(width * height), ctx.allocator)
	defer delete(pixels, ctx.allocator)
	for i := 0; i < len(pixels); i += 1 {
		offset := i * 4
		pixels[i] = gpu_visual_readback_pixel(readback[offset:offset + 4], format)
	}
	non_clear_pixels := gpu_visual_non_clear_pixel_count(pixels, clear)
	if non_clear_pixels == 0 {
		return vdebug.status_fail("GPU object fixture rendered only clear color")
	}
	vdebug.artifact_write_bmp(ctx, "actual", pixels, width, height, GPU_VISUAL_PALETTE)
	sidecar := gpu_visual_sidecar_make(ctx, width, height, clear, format, non_clear_pixels)
	vdebug.artifact_write_json_text(ctx, "metadata", sidecar)
	return vdebug.status_pass()
}

gpu_visual_object_upload :: proc() -> GeometryID {
	vertices := [?]PositionColorVertex {
		{position = world.Vec4{-0.72, -0.64, 0.0, 1.0}, color = world.Vec4{0.95, 0.18, 0.12, 1.0}},
		{position = world.Vec4{0.72, -0.64, 0.0, 1.0}, color = world.Vec4{0.12, 0.85, 0.28, 1.0}},
		{position = world.Vec4{0.0, 0.76, 0.0, 1.0}, color = world.Vec4{0.16, 0.28, 0.96, 1.0}},
	}
	indices := [?]u32{0, 1, 2}
	return geometry_append_bytes(
		&state.geometry_pool,
		.Position_Color_F32x4,
		raw_data(vertices[:]),
		u32(len(vertices) * size_of(PositionColorVertex)),
		u32(len(vertices)),
		u32(size_of(PositionColorVertex)),
		indices[:],
	)
}

gpu_visual_readback_pixel :: proc(
	bytes: []byte,
	format: sdl.GPUTextureFormat,
) -> vdebug.PixelRGBA8 {
	if format == sdl.GPUTextureFormat.B8G8R8A8_UNORM ||
	   format == sdl.GPUTextureFormat.B8G8R8A8_UNORM_SRGB {
		return {r = bytes[2], g = bytes[1], b = bytes[0], a = bytes[3]}
	}
	return {r = bytes[0], g = bytes[1], b = bytes[2], a = bytes[3]}
}

gpu_visual_non_clear_pixel_count :: proc(pixels: []vdebug.PixelRGBA8, clear: sdl.FColor) -> u64 {
	clear_pixel := vdebug.PixelRGBA8 {
		r = u8(clear.r * 255.0),
		g = u8(clear.g * 255.0),
		b = u8(clear.b * 255.0),
		a = u8(clear.a * 255.0),
	}
	count: u64
	for pixel in pixels {
		dr := abs(i32(pixel.r) - i32(clear_pixel.r))
		dg := abs(i32(pixel.g) - i32(clear_pixel.g))
		db := abs(i32(pixel.b) - i32(clear_pixel.b))
		da := abs(i32(pixel.a) - i32(clear_pixel.a))
		if dr > 2 || dg > 2 || db > 2 || da > 2 {
			count += 1
		}
	}
	return count
}

gpu_visual_format_string :: proc(format: sdl.GPUTextureFormat) -> string {
	#partial switch format {
	case .R8G8B8A8_UNORM:
		return "R8G8B8A8_UNORM"
	case .R8G8B8A8_UNORM_SRGB:
		return "R8G8B8A8_UNORM_SRGB"
	case .B8G8R8A8_UNORM:
		return "B8G8R8A8_UNORM"
	case .B8G8R8A8_UNORM_SRGB:
		return "B8G8R8A8_UNORM_SRGB"
	case:
		return "unknown"
	}
}

gpu_visual_clear_color :: proc(case_name: string) -> sdl.FColor {
	if strings.contains(case_name, "object") {
		return sdl.FColor{0.20, 0.34, 0.72, 1.0}
	}
	if strings.contains(case_name, "overlay") {
		return sdl.FColor{0.72, 0.24, 0.18, 1.0}
	}
	return sdl.FColor{0.10, 0.46, 0.30, 1.0}
}

gpu_visual_sidecar_make :: proc(
	ctx: ^vdebug.VisualDebugContext,
	width, height: u32,
	clear: sdl.FColor,
	format: sdl.GPUTextureFormat,
	non_clear_pixels: u64,
) -> string {
	builder, _ := strings.builder_make(allocator = ctx.allocator)
	defer strings.builder_destroy(&builder)
	strings.write_string(&builder, "{\n")
	vdebug.json_write_named_string(
		&builder,
		"schema",
		"voxels.visual_debug.gpu_sidecar.v1",
		1,
		true,
	)
	vdebug.json_write_named_string(&builder, "request_id", ctx.request_id, 1, true)
	vdebug.json_write_named_string(&builder, "mode_id", ctx.mode_id, 1, true)
	vdebug.json_write_named_string(
		&builder,
		"backend",
		"sdl_gpu_offscreen_object_pipeline",
		1,
		true,
	)
	vdebug.json_write_named_string(&builder, "pipeline", "prototype_fill", 1, true)
	vdebug.json_write_named_string(&builder, "vertex_shader", "Mesh.vert", 1, true)
	vdebug.json_write_named_string(&builder, "fragment_shader", "SolidColor.frag", 1, true)
	vdebug.json_write_named_u64(&builder, "width", u64(width), 1, true)
	vdebug.json_write_named_u64(&builder, "height", u64(height), 1, true)
	vdebug.json_write_named_string(&builder, "format", gpu_visual_format_string(format), 1, true)
	vdebug.json_write_named_string(&builder, "color_space", "linear", 1, true)
	vdebug.json_write_named_string(&builder, "orientation", "top_left", 1, true)
	vdebug.json_write_named_string(&builder, "projection", "identity_clip_space", 1, true)
	vdebug.json_write_named_u64(&builder, "sample_count", 1, 1, true)
	vdebug.json_write_named_u64(&builder, "pixels_per_row", u64(width), 1, true)
	vdebug.json_write_named_string(&builder, "readback_wait", "WaitForGPUFences", 1, true)
	vdebug.json_write_named_u64(&builder, "fixture_vertex_count", 3, 1, true)
	vdebug.json_write_named_u64(&builder, "fixture_index_count", 3, 1, true)
	vdebug.json_write_named_u64(&builder, "non_clear_pixels", non_clear_pixels, 1, true)
	vdebug.json_write_named_f64(&builder, "clear_r", f64(clear.r), 1, true)
	vdebug.json_write_named_f64(&builder, "clear_g", f64(clear.g), 1, true)
	vdebug.json_write_named_f64(&builder, "clear_b", f64(clear.b), 1, true)
	vdebug.json_write_named_f64(&builder, "clear_a", f64(clear.a), 1, false)
	strings.write_string(&builder, "}\n")
	return strings.clone(strings.to_string(builder), ctx.allocator)
}
