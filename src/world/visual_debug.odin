package world

import vdebug "app:vdebug"
import world_async "async:world"
import json "core:encoding/json"
import "core:fmt"
import "core:mem"
import "core:strings"

WORLD_VISUAL_DEBUG_VERSION :: "1"
WORLD_VISUAL_DEBUG_DEFAULT_WIDTH :: u32(128)
WORLD_VISUAL_DEBUG_DEFAULT_HEIGHT :: u32(128)

WorldVisualFixture :: struct {
	seed:          u32,
	coord:         world_async.ChunkCoord,
	quality:       world_async.ChunkGenerationQuality,
	cache_mode:    string,
	default_layer: string,
	debug_tweak:   i32,
}

visual_debug_register :: proc(registry: ^vdebug.VisualDebugRegistry) {
	world_visual_register_case(
		registry,
		"world.surface_morphology.feature",
		world_visual_surface_configure,
	)
	world_visual_register_case(registry, "world.cave.slice", world_visual_cave_configure)
	world_visual_register_case(registry, "world.cave.view", world_visual_cave_configure)
	world_visual_register_case(registry, "world.water.volume_fill", world_visual_water_configure)
	world_visual_register_case(
		registry,
		"world.decoration.delta",
		world_visual_decoration_configure,
	)
	world_visual_register_case(registry, "world.mesh.face_masks", world_visual_mesh_configure)
}

world_visual_register_case :: proc(
	registry: ^vdebug.VisualDebugRegistry,
	name: string,
	configure: vdebug.VisualDebugConfigureProc,
) {
	vdebug.register(
		registry,
		name,
		configure,
		world_visual_run,
		{
			data_size = size_of(WorldVisualFixture),
			data_align = align_of(WorldVisualFixture),
			flags = {.Serial_Only, .Uses_Shared_Caches, .Emits_Artifacts, .Snapshot_Comparable},
			category = "world.visual_debug",
			version = WORLD_VISUAL_DEBUG_VERSION,
			write_fixture = world_visual_fixture_write,
		},
	)
}

world_visual_surface_configure :: proc(
	ctx: ^vdebug.VisualDebugConfigContext,
	request: json.Object,
	data: rawptr,
) -> vdebug.VisualDebugStatus {
	return world_visual_configure_common(
		ctx,
		request,
		data,
		world_async.ChunkCoord{x = 11, y = 0, z = 9},
		"surface_height",
	)
}

world_visual_cave_configure :: proc(
	ctx: ^vdebug.VisualDebugConfigContext,
	request: json.Object,
	data: rawptr,
) -> vdebug.VisualDebugStatus {
	return world_visual_configure_common(
		ctx,
		request,
		data,
		world_async.ChunkCoord{x = 0, y = -2, z = 0},
		"material",
	)
}

world_visual_water_configure :: proc(
	ctx: ^vdebug.VisualDebugConfigContext,
	request: json.Object,
	data: rawptr,
) -> vdebug.VisualDebugStatus {
	return world_visual_configure_common(
		ctx,
		request,
		data,
		world_async.ChunkCoord{x = 3, y = 0, z = 4},
		"water_fill",
	)
}

world_visual_decoration_configure :: proc(
	ctx: ^vdebug.VisualDebugConfigContext,
	request: json.Object,
	data: rawptr,
) -> vdebug.VisualDebugStatus {
	return world_visual_configure_common(
		ctx,
		request,
		data,
		world_async.ChunkCoord{x = 8, y = 0, z = 8},
		"decoration_delta",
	)
}

world_visual_mesh_configure :: proc(
	ctx: ^vdebug.VisualDebugConfigContext,
	request: json.Object,
	data: rawptr,
) -> vdebug.VisualDebugStatus {
	return world_visual_configure_common(
		ctx,
		request,
		data,
		world_async.ChunkCoord{x = 0, y = 0, z = 0},
		"mesh_face_mask",
	)
}

world_visual_configure_common :: proc(
	ctx: ^vdebug.VisualDebugConfigContext,
	request: json.Object,
	data: rawptr,
	default_coord: world_async.ChunkCoord,
	default_layer: string,
) -> vdebug.VisualDebugStatus {
	fixture := (^WorldVisualFixture)(data)
	fixture^ = {
		seed          = ctx.defaults.seed,
		coord         = default_coord,
		quality       = .Full,
		cache_mode    = "cold",
		default_layer = default_layer,
	}
	fixture.seed = u32(vdebug.json_i64_default(request, "seed", i64(fixture.seed)))
	quality := vdebug.json_string_default(request, "quality", ctx.defaults.quality)
	if quality == "Proxy" || quality == "proxy" {
		fixture.quality = .Proxy
	} else if quality == "Full" || quality == "full" {
		fixture.quality = .Full
	} else {
		return vdebug.status_fail("quality must be Full or Proxy")
	}

	params_value, params_ok := request["params"]
	if params_ok {
		params, params_obj_ok := vdebug.json_value_object(params_value)
		if !params_obj_ok {
			return vdebug.status_fail("params must be an object")
		}
		fixture.cache_mode = vdebug.json_string_default(params, "cache_mode", fixture.cache_mode)
		fixture.default_layer = vdebug.json_string_default(params, "layer", fixture.default_layer)
		fixture.debug_tweak = i32(vdebug.json_i64_default(params, "debug_tweak", 0))
		fixture.coord.x = i32(vdebug.json_i64_default(params, "chunk_x", i64(fixture.coord.x)))
		fixture.coord.y = i32(vdebug.json_i64_default(params, "chunk_y", i64(fixture.coord.y)))
		fixture.coord.z = i32(vdebug.json_i64_default(params, "chunk_z", i64(fixture.coord.z)))
		if chunk_value, chunk_ok := params["chunk"]; chunk_ok {
			if chunk_obj, chunk_obj_ok := vdebug.json_value_object(chunk_value); chunk_obj_ok {
				fixture.coord.x = i32(
					vdebug.json_i64_default(chunk_obj, "x", i64(fixture.coord.x)),
				)
				fixture.coord.y = i32(
					vdebug.json_i64_default(chunk_obj, "y", i64(fixture.coord.y)),
				)
				fixture.coord.z = i32(
					vdebug.json_i64_default(chunk_obj, "z", i64(fixture.coord.z)),
				)
			}
		}
	}
	switch fixture.cache_mode {
	case "disabled", "cold", "warm", "require_hit", "contention":
	case:
		return vdebug.status_fail(
			"cache_mode must be disabled, cold, warm, require_hit, or contention",
		)
	}
	return vdebug.status_pass()
}

world_visual_fixture_write :: proc(
	ctx: ^vdebug.VisualDebugContext,
	data: rawptr,
	writer: ^vdebug.VisualDebugMetadataWriter,
) -> vdebug.VisualDebugStatus {
	fixture := (^WorldVisualFixture)(data)
	vdebug.metadata_u64(writer, "seed", u64(fixture.seed))
	vdebug.metadata_i64(writer, "chunk_x", i64(fixture.coord.x))
	vdebug.metadata_i64(writer, "chunk_y", i64(fixture.coord.y))
	vdebug.metadata_i64(writer, "chunk_z", i64(fixture.coord.z))
	vdebug.metadata_string(writer, "quality", world_visual_quality_string(fixture.quality))
	vdebug.metadata_string(writer, "cache_mode", fixture.cache_mode)
	vdebug.metadata_string(writer, "default_layer", fixture.default_layer)
	vdebug.metadata_i64(writer, "debug_tweak", i64(fixture.debug_tweak))
	vdebug.metadata_u64(writer, "terrain_generator_version", u64(TERRAIN_GENERATOR_VERSION))
	vdebug.metadata_bool(writer, "terrain_decoration_enabled", TERRAIN_DECORATION_ENABLED)
	_ = ctx
	return vdebug.status_pass()
}

world_visual_run :: proc(
	ctx: ^vdebug.VisualDebugContext,
	data: rawptr,
	mode: json.Object,
) -> vdebug.VisualDebugStatus {
	fixture := (^WorldVisualFixture)(data)
	width := u32(vdebug.json_i64_default(mode, "width", i64(WORLD_VISUAL_DEBUG_DEFAULT_WIDTH)))
	height := u32(vdebug.json_i64_default(mode, "height", i64(WORLD_VISUAL_DEBUG_DEFAULT_HEIGHT)))
	layer := vdebug.json_string_default(mode, "layer", fixture.default_layer)
	kind := vdebug.json_string_default(mode, "kind", "orthographic_pixels")

	view := world_async.ChunkVoxelView{}
	chunk_voxel_view_alloc(&view, ctx.allocator)
	defer delete(view.blocks, ctx.allocator)
	cache_outcome := world_visual_generate_view(&view, fixture, ctx.allocator)
	counts := world_visual_counts(view)

	switch kind {
	case "orthographic_pixels":
		plane := vdebug.json_string_default(mode, "plane", "xz")
		pixels := make([]vdebug.PixelRGBA8, int(width * height), ctx.allocator)
		defer delete(pixels, ctx.allocator)
		world_visual_render_orthographic(
			pixels,
			width,
			height,
			view,
			plane,
			layer,
			fixture.debug_tweak,
		)
		vdebug.artifact_write_bmp(ctx, "actual", pixels, width, height, "terrain_debug.v1")
		sidecar := world_visual_sidecar_make(ctx, fixture, layer, plane, cache_outcome, counts)
		vdebug.artifact_write_json_text(ctx, "metadata", sidecar)
	case "cpu_raycast":
		pixels := make([]vdebug.PixelRGBA8, int(width * height), ctx.allocator)
		defer delete(pixels, ctx.allocator)
		world_visual_render_raycast(pixels, width, height, view, layer, fixture.debug_tweak)
		vdebug.artifact_write_bmp(ctx, "actual", pixels, width, height, "terrain_debug.v1")
		sidecar := world_visual_sidecar_make(
			ctx,
			fixture,
			layer,
			"cpu_raycast",
			cache_outcome,
			counts,
		)
		vdebug.artifact_write_json_text(ctx, "metadata", sidecar)
	case "frame_sequence":
		frames := u32(vdebug.json_i64_default(mode, "frames", 8))
		if frames == 0 || frames > vdebug.VISUAL_DEBUG_MAX_FRAME_COUNT {
			return vdebug.status_fail("frame_sequence frames out of bounds")
		}
		for frame := u32(0); frame < frames; frame += 1 {
			pixels := make([]vdebug.PixelRGBA8, int(width * height), ctx.allocator)
			world_visual_render_orthographic(
				pixels,
				width,
				height,
				view,
				(frame & 1) == 0 ? "xz" : "xy",
				layer,
				fixture.debug_tweak + i32(frame * 5),
			)
			label := "actual"
			if frame > 0 {
				label = fmt.aprintf("frame_%03d", frame, allocator = ctx.allocator)
			}
			vdebug.artifact_write_bmp(ctx, label, pixels, width, height, "terrain_debug.v1")
			delete(pixels, ctx.allocator)
		}
		if ctx.ffmpeg != nil && ctx.ffmpeg.available {
			_ = vdebug.ffmpeg_contact_sheet_make(ctx, 4, 4)
		}
		sidecar := world_visual_sidecar_make(
			ctx,
			fixture,
			layer,
			"frame_sequence",
			cache_outcome,
			counts,
		)
		vdebug.artifact_write_json_text(ctx, "metadata", sidecar)
	case:
		return vdebug.status_fail(fmt.aprintf("unsupported world visual mode kind: %s", kind))
	}
	return vdebug.status_pass()
}

world_visual_generate_view :: proc(
	view: ^world_async.ChunkVoxelView,
	fixture: ^WorldVisualFixture,
	allocator: mem.Allocator,
) -> string {
	terrain_generation_chunk_cache_init(context.allocator)
	terrain_generation_cave_overlay_cache_init(context.allocator)
	key := terrain_generation_key_make(fixture.seed)
	switch fixture.cache_mode {
	case "disabled", "cold":
		terrain_generation_chunk_cache_clear()
		terrain_generation_cave_overlay_cache_clear()
		terrain_generation_column_cache_clear()
		terrain_heightfield_voxel_view_fill_quality(
			view,
			fixture.coord,
			fixture.seed,
			fixture.quality,
		)
		return "generated"
	case "warm":
		warm := world_async.ChunkVoxelView{}
		chunk_voxel_view_alloc(&warm, allocator)
		defer delete(warm.blocks, allocator)
		terrain_heightfield_voxel_view_fill_quality(
			&warm,
			fixture.coord,
			fixture.seed,
			fixture.quality,
		)
		hit := terrain_generation_chunk_cache_contains(key, fixture.coord)
		terrain_heightfield_voxel_view_fill_quality(
			view,
			fixture.coord,
			fixture.seed,
			fixture.quality,
		)
		return hit ? "cache_hit" : "generated"
	case "require_hit":
		hit := terrain_generation_chunk_cache_contains(key, fixture.coord)
		terrain_heightfield_voxel_view_fill_quality(
			view,
			fixture.coord,
			fixture.seed,
			fixture.quality,
		)
		return hit ? "cache_hit" : "required_cache_missing"
	case:
		terrain_heightfield_voxel_view_fill_quality(
			view,
			fixture.coord,
			fixture.seed,
			fixture.quality,
		)
		return "contention_single_process"
	}
}

WorldVisualCounts :: struct {
	solid:         u64,
	empty:         u64,
	water:         u64,
	exposed_faces: u64,
	materials:     [TERRAIN_MATERIAL_PALETTE_COUNT]u64,
}

world_visual_counts :: proc(view: world_async.ChunkVoxelView) -> WorldVisualCounts {
	counts := WorldVisualCounts{}
	for z := u32(0); z < CHUNK_BLOCK_LENGTH; z += 1 {
		for y := u32(0); y < CHUNK_BLOCK_LENGTH; y += 1 {
			for x := u32(0); x < CHUNK_BLOCK_LENGTH; x += 1 {
				index := chunk_block_index(x, y, z)
				if view.blocks.occupancy[index] == .Solid {
					counts.solid += 1
					mat := terrain_material_palette_index(view.blocks.material_id[index])
					counts.materials[mat] += 1
					if mat == TERRAIN_WATER_MAT_ID {
						counts.water += 1
					}
					counts.exposed_faces += u64(world_visual_exposed_face_count(view, x, y, z))
				} else {
					counts.empty += 1
				}
			}
		}
	}
	return counts
}

world_visual_render_orthographic :: proc(
	pixels: []vdebug.PixelRGBA8,
	width, height: u32,
	view: world_async.ChunkVoxelView,
	plane: string,
	layer: string,
	tweak: i32,
) {
	for py := u32(0); py < height; py += 1 {
		for px := u32(0); px < width; px += 1 {
			lx := u32((u64(px) * u64(CHUNK_BLOCK_LENGTH)) / u64(width))
			ly := u32((u64(py) * u64(CHUNK_BLOCK_LENGTH)) / u64(height))
			lz := u32((u64(py) * u64(CHUNK_BLOCK_LENGTH)) / u64(height))
			if plane == "xy" {
				ly = CHUNK_BLOCK_LENGTH - 1 - ly
				lz = CHUNK_BLOCK_LENGTH / 2
			} else if plane == "yz" {
				lx = CHUNK_BLOCK_LENGTH / 2
				ly = CHUNK_BLOCK_LENGTH - 1 - ly
				lz = u32((u64(px) * u64(CHUNK_BLOCK_LENGTH)) / u64(width))
			} else {
				lz = u32((u64(py) * u64(CHUNK_BLOCK_LENGTH)) / u64(height))
				ly = world_visual_top_solid_y(view, lx, lz)
			}
			pixels[px + py * width] = world_visual_sample_color(view, lx, ly, lz, layer, tweak)
		}
	}
}

world_visual_render_raycast :: proc(
	pixels: []vdebug.PixelRGBA8,
	width, height: u32,
	view: world_async.ChunkVoxelView,
	layer: string,
	tweak: i32,
) {
	for py := u32(0); py < height; py += 1 {
		for px := u32(0); px < width; px += 1 {
			lx := u32((u64(px) * u64(CHUNK_BLOCK_LENGTH)) / u64(width))
			ly := CHUNK_BLOCK_LENGTH - 1 - u32((u64(py) * u64(CHUNK_BLOCK_LENGTH)) / u64(height))
			color := vdebug.PixelRGBA8 {
				r = 12,
				g = 16,
				b = 22,
				a = 255,
			}
			for z := u32(0); z < CHUNK_BLOCK_LENGTH; z += 1 {
				index := chunk_block_index(lx, ly, z)
				if view.blocks.occupancy[index] == .Solid {
					color = world_visual_sample_color(view, lx, ly, z, layer, tweak)
					depth_shade := i32(255 - (z * 160 / CHUNK_BLOCK_LENGTH))
					color.r = u8(world_visual_clamp_i32(i32(color.r) * depth_shade / 255, 0, 255))
					color.g = u8(world_visual_clamp_i32(i32(color.g) * depth_shade / 255, 0, 255))
					color.b = u8(world_visual_clamp_i32(i32(color.b) * depth_shade / 255, 0, 255))
					break
				}
			}
			pixels[px + py * width] = color
		}
	}
}

world_visual_sample_color :: proc(
	view: world_async.ChunkVoxelView,
	x, y, z: u32,
	layer: string,
	tweak: i32,
) -> vdebug.PixelRGBA8 {
	index := chunk_block_index(x, y, z)
	if view.blocks.occupancy[index] != .Solid {
		return {r = 10, g = 13, b = 18, a = 255}
	}
	material := view.blocks.material_id[index]
	material_index := terrain_material_palette_index(material)
	if layer == "water_fill" {
		if material_index == TERRAIN_WATER_MAT_ID {
			return {r = 40, g = 130, b = 230, a = 255}
		}
		return {r = 36, g = 42, b = 48, a = 255}
	}
	if layer == "surface_height" {
		v := u8(world_visual_clamp_i32(i32(y) * 255 / i32(CHUNK_BLOCK_LENGTH - 1) + tweak, 0, 255))
		return {r = v, g = u8(world_visual_clamp_i32(i32(v) + 24, 0, 255)), b = 64, a = 255}
	}
	if layer == "mesh_face_mask" {
		faces := world_visual_exposed_face_count(view, x, y, z)
		v := u8(world_visual_clamp_i32(i32(faces) * 42 + tweak, 0, 255))
		return {r = v, g = 64, b = u8(255 - v / 2), a = 255}
	}
	if layer == "decoration_delta" && y > CHUNK_BLOCK_LENGTH / 2 {
		base := world_visual_material_color(material, tweak)
		base.r = u8(world_visual_clamp_i32(i32(base.r) + 48, 0, 255))
		return base
	}
	return world_visual_material_color(material, tweak)
}

world_visual_material_color :: proc(
	material: world_async.BlockMaterialID,
	tweak: i32,
) -> vdebug.PixelRGBA8 {
	index := u32(u8(material)) & (TERRAIN_MATERIAL_COLOR_COUNT - 1)
	color := TERRAIN_MATERIAL_COLORS[index]
	return {
		r = u8(world_visual_clamp_i32(i32(color[0] * 255.0) + tweak, 0, 255)),
		g = u8(world_visual_clamp_i32(i32(color[1] * 255.0) + tweak, 0, 255)),
		b = u8(world_visual_clamp_i32(i32(color[2] * 255.0) + tweak, 0, 255)),
		a = 255,
	}
}

world_visual_top_solid_y :: proc(view: world_async.ChunkVoxelView, x, z: u32) -> u32 {
	for y := i32(CHUNK_BLOCK_LENGTH) - 1; y >= 0; y -= 1 {
		index := chunk_block_index(x, u32(y), z)
		if view.blocks.occupancy[index] == .Solid {
			return u32(y)
		}
	}
	return 0
}

world_visual_exposed_face_count :: proc(view: world_async.ChunkVoxelView, x, y, z: u32) -> u32 {
	count: u32
	if x == 0 || !chunk_voxel_view_is_solid_local(view, x - 1, y, z) {count += 1}
	if x + 1 >= CHUNK_BLOCK_LENGTH ||
	   !chunk_voxel_view_is_solid_local(view, x + 1, y, z) {count += 1}
	if y == 0 || !chunk_voxel_view_is_solid_local(view, x, y - 1, z) {count += 1}
	if y + 1 >= CHUNK_BLOCK_LENGTH ||
	   !chunk_voxel_view_is_solid_local(view, x, y + 1, z) {count += 1}
	if z == 0 || !chunk_voxel_view_is_solid_local(view, x, y, z - 1) {count += 1}
	if z + 1 >= CHUNK_BLOCK_LENGTH ||
	   !chunk_voxel_view_is_solid_local(view, x, y, z + 1) {count += 1}
	return count
}

world_visual_sidecar_make :: proc(
	ctx: ^vdebug.VisualDebugContext,
	fixture: ^WorldVisualFixture,
	layer: string,
	plane: string,
	cache_outcome: string,
	counts: WorldVisualCounts,
) -> string {
	builder, _ := strings.builder_make(allocator = ctx.allocator)
	defer strings.builder_destroy(&builder)
	strings.write_string(&builder, "{\n")
	vdebug.json_write_named_string(&builder, "schema", "voxels.visual_debug.sidecar.v1", 1, true)
	vdebug.json_write_named_string(&builder, "request_id", ctx.request_id, 1, true)
	vdebug.json_write_named_string(&builder, "mode_id", ctx.mode_id, 1, true)
	vdebug.json_write_named_string(&builder, "layer", layer, 1, true)
	vdebug.json_write_named_string(&builder, "plane", plane, 1, true)
	vdebug.json_write_named_u64(&builder, "seed", u64(fixture.seed), 1, true)
	vdebug.json_write_named_i64(&builder, "chunk_x", i64(fixture.coord.x), 1, true)
	vdebug.json_write_named_i64(&builder, "chunk_y", i64(fixture.coord.y), 1, true)
	vdebug.json_write_named_i64(&builder, "chunk_z", i64(fixture.coord.z), 1, true)
	vdebug.json_write_named_string(
		&builder,
		"quality",
		world_visual_quality_string(fixture.quality),
		1,
		true,
	)
	vdebug.json_write_named_string(&builder, "cache_mode", fixture.cache_mode, 1, true)
	vdebug.json_write_named_string(&builder, "cache_outcome", cache_outcome, 1, true)
	vdebug.json_write_named_u64(&builder, "solid_blocks", counts.solid, 1, true)
	vdebug.json_write_named_u64(&builder, "empty_blocks", counts.empty, 1, true)
	vdebug.json_write_named_u64(&builder, "water_blocks", counts.water, 1, true)
	vdebug.json_write_named_u64(&builder, "exposed_faces", counts.exposed_faces, 1, true)
	vdebug.json_indent(&builder, 1)
	strings.write_string(&builder, "\"materials\": [")
	for i := 0; i < len(counts.materials); i += 1 {
		if i > 0 {
			strings.write_string(&builder, ", ")
		}
		fmt.sbprintf(&builder, "%d", counts.materials[i])
	}
	strings.write_string(&builder, "]\n")
	strings.write_string(&builder, "}\n")
	return strings.clone(strings.to_string(builder), ctx.allocator)
}

world_visual_quality_string :: proc(quality: world_async.ChunkGenerationQuality) -> string {
	switch quality {
	case .Proxy:
		return "Proxy"
	case .Full:
		return "Full"
	}
	return "Full"
}

world_visual_clamp_i32 :: proc(value, min_value, max_value: i32) -> i32 {
	if value < min_value {
		return min_value
	}
	if value > max_value {
		return max_value
	}
	return value
}
