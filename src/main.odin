package main

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
// Terrain
///////////////////////////////////////////

TerrainPackedVertex :: distinct u32
#assert(size_of(TerrainPackedVertex) == 4)

TerrainDrawParams :: struct {
	vertex_byte_offset:  u32,
	vertex_stride_bytes: u32,
	_padding:            [2]u32,
	chunk_origin:        [4]f32, // xyz used, w = block_world_size
}

TerrainGridPoint :: struct {
	x, y, z: u32,
}

terrain_pack_vertex :: proc(
	local_x, local_y, local_z: u32,
	normal_id, material_id, corner_id: u32,
) -> TerrainPackedVertex {
	log.assertf(local_x <= 63, "terrain local_x out of range: %d", local_x)
	log.assertf(local_y <= 63, "terrain local_y out of range: %d", local_y)
	log.assertf(local_z <= 63, "terrain local_z out of range: %d", local_z)
	log.assertf(normal_id < 6, "terrain normal_id out of range: %d", normal_id)
	log.assertf(material_id <= 255, "terrain material_id out of range: %d", material_id)
	log.assertf(corner_id < 4, "terrain corner_id out of range: %d", corner_id)
	return TerrainPackedVertex(
		(local_x << 0) |
		(local_y << 6) |
		(local_z << 12) |
		(normal_id << 18) |
		(material_id << 21) |
		(corner_id << 29),
	)
}

emit_terrain_quad :: proc(
	verticies: []TerrainPackedVertex,
	indicies: []u32,
	p0, p1, p2, p3: TerrainGridPoint,
	normal_id: u32,
	material_id: u32,
	vertex_count: ^u32,
	index_count: ^u32,
) {
	log.assertf(int(vertex_count^) + 4 <= len(verticies), "debug terrain vertex capacity exceeded")
	log.assertf(int(index_count^) + 6 <= len(indicies), "debug terrain index capacity exceeded")

	base := vertex_count^
	v := int(vertex_count^)
	i := int(index_count^)

	verticies[v + 0] = terrain_pack_vertex(p0.x, p0.y, p0.z, normal_id, material_id, 0)
	verticies[v + 1] = terrain_pack_vertex(p1.x, p1.y, p1.z, normal_id, material_id, 1)
	verticies[v + 2] = terrain_pack_vertex(p2.x, p2.y, p2.z, normal_id, material_id, 2)
	verticies[v + 3] = terrain_pack_vertex(p3.x, p3.y, p3.z, normal_id, material_id, 3)

	indicies[i + 0] = base + 0
	indicies[i + 1] = base + 1
	indicies[i + 2] = base + 2
	indicies[i + 3] = base + 0
	indicies[i + 4] = base + 2
	indicies[i + 5] = base + 3

	vertex_count^ += 4
	index_count^ += 6
}

emit_terrain_box :: proc(
	verticies: []TerrainPackedVertex,
	indicies: []u32,
	x0, y0, z0, x1, y1, z1: u32,
	material_id: u32,
	vertex_count: ^u32,
	index_count: ^u32,
) {
	emit_terrain_quad(
		verticies,
		indicies,
		TerrainGridPoint{x1, y0, z0},
		TerrainGridPoint{x1, y1, z0},
		TerrainGridPoint{x1, y1, z1},
		TerrainGridPoint{x1, y0, z1},
		0,
		material_id,
		vertex_count,
		index_count,
	)
	emit_terrain_quad(
		verticies,
		indicies,
		TerrainGridPoint{x0, y0, z0},
		TerrainGridPoint{x0, y0, z1},
		TerrainGridPoint{x0, y1, z1},
		TerrainGridPoint{x0, y1, z0},
		1,
		material_id,
		vertex_count,
		index_count,
	)
	emit_terrain_quad(
		verticies,
		indicies,
		TerrainGridPoint{x0, y1, z0},
		TerrainGridPoint{x0, y1, z1},
		TerrainGridPoint{x1, y1, z1},
		TerrainGridPoint{x1, y1, z0},
		2,
		material_id,
		vertex_count,
		index_count,
	)
	emit_terrain_quad(
		verticies,
		indicies,
		TerrainGridPoint{x0, y0, z0},
		TerrainGridPoint{x1, y0, z0},
		TerrainGridPoint{x1, y0, z1},
		TerrainGridPoint{x0, y0, z1},
		3,
		material_id,
		vertex_count,
		index_count,
	)
	emit_terrain_quad(
		verticies,
		indicies,
		TerrainGridPoint{x0, y0, z1},
		TerrainGridPoint{x1, y0, z1},
		TerrainGridPoint{x1, y1, z1},
		TerrainGridPoint{x0, y1, z1},
		4,
		material_id,
		vertex_count,
		index_count,
	)
	emit_terrain_quad(
		verticies,
		indicies,
		TerrainGridPoint{x0, y0, z0},
		TerrainGridPoint{x0, y1, z0},
		TerrainGridPoint{x1, y1, z0},
		TerrainGridPoint{x1, y0, z0},
		5,
		material_id,
		vertex_count,
		index_count,
	)
}

append_debug_terrain_patch :: proc(pool: ^GeometryPool) -> GeometryID {
	vertices: [1024]TerrainPackedVertex
	indices: [2048]u32
	vertex_count: u32
	index_count: u32

	// One merged +Y quad.
	emit_terrain_quad(
		vertices[:],
		indices[:],
		TerrainGridPoint{0, 0, 0},
		TerrainGridPoint{0, 0, 4},
		TerrainGridPoint{4, 0, 4},
		TerrainGridPoint{4, 0, 0},
		2,
		0,
		&vertex_count,
		&index_count,
	)

	// 8x8 tiled +Y floor, offset so it does not z-fight the merged quad.
	for z in 0 ..< 8 {
		for x in 0 ..< 8 {
			material_id := u32(1 + ((x + z) & 1))
			x0 := u32(x + 6)
			z0 := u32(z)

			emit_terrain_quad(
				vertices[:],
				indices[:],
				TerrainGridPoint{x0, 0, z0},
				TerrainGridPoint{x0, 0, z0 + 1},
				TerrainGridPoint{x0 + 1, 0, z0 + 1},
				TerrainGridPoint{x0 + 1, 0, z0},
				2,
				material_id,
				&vertex_count,
				&index_count,
			)
		}
	}

	emit_terrain_box(vertices[:], indices[:], 0, 1, 6, 1, 2, 7, 3, &vertex_count, &index_count)
	emit_terrain_box(vertices[:], indices[:], 9, 1, 2, 10, 3, 3, 4, &vertex_count, &index_count)
	emit_terrain_box(vertices[:], indices[:], 12, 1, 5, 13, 2, 6, 5, &vertex_count, &index_count)

	stride := geometry_layout_stride_bytes(.Terrain_Packed_U32)
	vertex_byte_count := vertex_count * stride

	return geometry_append_bytes(
		pool,
		.Terrain_Packed_U32,
		raw_data(vertices[:int(vertex_count)]),
		vertex_byte_count,
		vertex_count,
		stride,
		indices[:int(index_count)],
	)
}

///////////////////////////////////////////
// Geometry
///////////////////////////////////////////

GeometryID :: distinct u32

GeometryLayoutKind :: enum u32 {
	Invalid,
	Position_Color_F32x4,
	Terrain_Packed_U32,
}

// Mesh.vert.hlsl decodes this layout by byte offsets.
PositionColorVertex :: struct {
	position: [4]f32,
	color:    [4]f32,
}
#assert(size_of(PositionColorVertex) == 32)

Geometry :: struct {
	layout_kind:         GeometryLayoutKind,
	vertex_byte_offset:  u32,
	vertex_stride_bytes: u32,
	vertex_count:        u32,
	first_index:         u32,
	index_count:         u32,
}

GeometryDrawParams :: struct {
	vertex_byte_offset:  u32,
	vertex_stride_bytes: u32,
	_padding:            [2]u32, // extra padding for alignment
}

GeometryPool :: struct {
	geometries:                  []Geometry,
	geometry_count:              u32,
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

INVALID_GEOMETRY_ID :: GeometryID(0)
GEOMETRY_MAX_GEOMETRIES :: 1024
GEOMETRY_MAX_POSITION_COLOR_VERTICES :: 1_000_000
GEOMETRY_MAX_VERTEX_BYTES :: GEOMETRY_MAX_POSITION_COLOR_VERTICES * size_of(PositionColorVertex)
GEOMETRY_MAX_INDEX_ELEMENTS :: 3_000_000
GEOMETRY_MAX_UPLOAD_POSITION_COLOR_VERTICES :: 65_536
GEOMETRY_MAX_VERTEX_UPLOAD_BYTES ::
	GEOMETRY_MAX_UPLOAD_POSITION_COLOR_VERTICES * size_of(PositionColorVertex)
GEOMETRY_MAX_UPLOAD_INDEX_ELEMENTS :: 196_608
GEOMETRY_VERTEX_BYTE_ALIGNMENT :: 4


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

geometry_align_vertex_byte_offset :: proc(offset: u64) -> u64 {
	alignment := u64(GEOMETRY_VERTEX_BYTE_ALIGNMENT)
	return (offset + alignment - 1) & ~(alignment - 1)
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

	index_buffer_size_wide := u64(max_indices_elements) * u64(size_of(u32))
	index_upload_size_wide := u64(max_upload_indices_elements) * u64(size_of(u32))

	log.assertf(
		index_buffer_size_wide <= u64(max(u32)),
		"index buffer size exceeds u32: %d",
		index_buffer_size_wide,
	)
	log.assertf(
		index_upload_size_wide <= u64(max(u32)),
		"index upload buffer size exceeds u32: %d",
		index_upload_size_wide,
	)

	vertex_buffer_size := max_vertices_bytes
	index_buffer_size := u32(index_buffer_size_wide)
	vertex_upload_size := max_upload_vertices_bytes
	index_upload_size := u32(index_upload_size_wide)

	pool^ = GeometryPool{}
	pool.geometries = make([]Geometry, max_geometries)
	pool.vertex_byte_capacity = max_vertices_bytes
	pool.index_element_capacity = max_indices_elements
	pool.vertex_upload_byte_capacity = vertex_upload_size
	pool.index_upload_byte_capacity = index_upload_size

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
			size = pool.vertex_upload_byte_capacity,
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
	pool.vertex_byte_capacity = 0
	pool.vertex_byte_count = 0
	pool.index_element_capacity = 0
	pool.index_element_count = 0
	pool.vertex_upload_byte_capacity = 0
	pool.index_upload_byte_capacity = 0
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
	log.assertf(layout_kind != .Invalid, "layout_kind must be valid")
	log.assertf(vertex_count > 0, "vertex_count must not be zero")
	log.assertf(vertex_stride_bytes > 0, "vertex_stride_bytes must not be zero")
	log.assertf(
		vertex_stride_bytes % GEOMETRY_VERTEX_BYTE_ALIGNMENT == 0,
		"vertex_stride_bytes must be aligned to %d bytes",
		GEOMETRY_VERTEX_BYTE_ALIGNMENT,
	)
	log.assertf(len(indices) > 0, "indices must not be empty")
	log.assertf(u64(len(indices)) <= u64(max(u32)), "index count exceeds u32: %d", len(indices))
	log.assertf(u64(pool.geometry_count) < u64(len(pool.geometries)), "geometry pool is full")
	log.assertf(
		geometry_layout_stride_bytes(layout_kind) == vertex_stride_bytes,
		"vertex_stride_bytes must match layout kind",
	)

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
	log.assertf(
		vertex_bytes_wide == u64(vertex_byte_count),
		"vertex_byte_count must match vertex_count and vertex_stride_bytes",
	)

	vertex_bytes := u32(vertex_bytes_wide)
	index_bytes := u32(index_bytes_wide)

	vertex_byte_offset_wide := geometry_align_vertex_byte_offset(u64(pool.vertex_byte_count))
	vertex_byte_end_wide := vertex_byte_offset_wide + u64(vertex_byte_count)
	index_element_end_wide := u64(pool.index_element_count) + u64(index_count)

	log.assertf(
		vertex_byte_offset_wide <= u64(max(u32)),
		"vertex destination offset exceeds u32: %d",
		vertex_byte_offset_wide,
	)
	log.assertf(
		vertex_byte_end_wide <= u64(pool.vertex_byte_capacity),
		"geometry vertex capacity exceeded",
	)
	log.assertf(
		index_element_end_wide <= u64(pool.index_element_capacity),
		"geometry index capacity exceeded",
	)
	log.assertf(
		vertex_bytes <= pool.vertex_upload_byte_capacity,
		"geometry vertex append exceeds upload buffer capacity",
	)
	log.assertf(
		index_bytes <= pool.index_upload_byte_capacity,
		"geometry index append exceeds upload buffer capacity",
	)

	geometry := Geometry {
		layout_kind         = layout_kind,
		vertex_count        = vertex_count,
		index_count         = index_count,
		vertex_byte_offset  = u32(vertex_byte_offset_wide),
		vertex_stride_bytes = vertex_stride_bytes,
		first_index         = pool.index_element_count,
	}

	geometry_index := pool.geometry_count
	id := GeometryID(geometry_index + 1)

	vertex_dst_offset_wide := u64(geometry.vertex_byte_offset)
	index_dst_offset_wide := u64(geometry.first_index) * u64(size_of(u32))
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
	mem.copy(mapped_data, vertex_data, int(vertex_bytes))
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
	pool.vertex_byte_count = geometry.vertex_byte_offset + vertex_byte_count
	pool.index_element_count += index_count

	return id
}

geometry_append :: proc(
	pool: ^GeometryPool,
	vertices: []PositionColorVertex,
	indices: []u32,
) -> GeometryID {
	log.assertf(len(vertices) > 0, "vertices must not be empty")
	log.assertf(u64(len(vertices)) <= u64(max(u32)), "vertex count exceeds u32: %d", len(vertices))

	vertex_count := u32(len(vertices))
	vertex_stride_bytes := geometry_layout_stride_bytes(.Position_Color_F32x4)
	vertex_byte_count_wide := u64(vertex_count) * u64(vertex_stride_bytes)
	log.assertf(
		vertex_byte_count_wide <= u64(max(u32)),
		"vertex append size exceeds u32: %d",
		vertex_byte_count_wide,
	)
	vertex_byte_count := u32(vertex_byte_count_wide)

	return geometry_append_bytes(
		pool,
		.Position_Color_F32x4,
		raw_data(vertices),
		vertex_byte_count,
		vertex_count,
		vertex_stride_bytes,
		indices,
	)
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

cube_vertices := [?]PositionColorVertex {
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
prototype_fill_pipeline: ^sdl.GPUGraphicsPipeline
prototype_line_pipeline: ^sdl.GPUGraphicsPipeline
terrain_fill_pipeline: ^sdl.GPUGraphicsPipeline
terrain_line_pipeline: ^sdl.GPUGraphicsPipeline

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
is_window_open := true
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

create_pipelines_fill_and_line :: proc(
	vert_shader: ^sdl.GPUShader,
	frag_shader: ^sdl.GPUShader,
	fill_pipeline: ^^sdl.GPUGraphicsPipeline,
	line_pipeline: ^^sdl.GPUGraphicsPipeline,
) {
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
	fill_pipeline^ = sdl.CreateGPUGraphicsPipeline(device, pipeline_create_info)
	log.assertf(fill_pipeline^ != nil, "Failed to create fill pipeline: %s", sdl.GetError())

	pipeline_create_info.rasterizer_state.fill_mode = sdl.GPUFillMode.LINE
	line_pipeline^ = sdl.CreateGPUGraphicsPipeline(device, pipeline_create_info)
	log.assertf(line_pipeline^ != nil, "Failed to create line pipeline: %s", sdl.GetError())
}

setup_resources :: proc() {
	log.debug("Setting resources")

	geometry_init(
		&geometry_pool,
		GEOMETRY_MAX_GEOMETRIES,
		GEOMETRY_MAX_VERTEX_BYTES,
		GEOMETRY_MAX_INDEX_ELEMENTS,
		GEOMETRY_MAX_VERTEX_UPLOAD_BYTES,
		GEOMETRY_MAX_UPLOAD_INDEX_ELEMENTS,
	)

	// todo: this should be removed later after testing is done
	// Mesh.vert uses one vertex storage buffer for PVP geometry bytes.
	// Indices are bound through SDL's hardware index-buffer path, not as shader storage.
	vert_shader, _ := load_shader("assets/shaders/Mesh.vert.dxil", 0, 2, 1, 0)
	frag_shader, _ := load_shader("assets/shaders/SolidColor.frag.dxil", 0, 0, 0, 0)

	// new shaders for terrain rendering, will be the primary rendering pipeline for terrain geometry
	terrain_vert_shader, _ := load_shader("assets/shaders/Terrain.vert.dxil", 0, 2, 1, 0)
	terrain_frag_shader, _ := load_shader("assets/shaders/Terrain.frag.dxil", 0, 0, 0, 0)

	// Create the pipelines
	create_pipelines_fill_and_line(
		vert_shader,
		frag_shader,
		&prototype_fill_pipeline,
		&prototype_line_pipeline,
	)
	create_pipelines_fill_and_line(
		terrain_vert_shader,
		terrain_frag_shader,
		&terrain_fill_pipeline,
		&terrain_line_pipeline,
	)

	sdl.ReleaseGPUShader(device, frag_shader)
	sdl.ReleaseGPUShader(device, vert_shader)
	sdl.ReleaseGPUShader(device, terrain_frag_shader)
	sdl.ReleaseGPUShader(device, terrain_vert_shader)

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

	_ = geometry_append(&geometry_pool, cube_vertices[:], cube_indices[:])
	_ = append_debug_terrain_patch(&geometry_pool)

	log.debug("Resources initialized")
}

destroy_resources :: proc() {
	log.debug("Destroying resources")
	log.assertf(sdl.WaitForGPUIdle(device), "WaitForGPUIdle failed: %s", sdl.GetError())
	geometry_destroy(&geometry_pool)
	sdl.ReleaseGPUTexture(device, depth_texture)
	sdl.ReleaseGPUGraphicsPipeline(device, prototype_fill_pipeline)
	sdl.ReleaseGPUGraphicsPipeline(device, prototype_line_pipeline)
	sdl.ReleaseGPUGraphicsPipeline(device, terrain_fill_pipeline)
	sdl.ReleaseGPUGraphicsPipeline(device, terrain_line_pipeline)
	log.debug("Resources destroyed")
}

render :: proc() {
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

		sdl.PushGPUVertexUniformData(cmdbuf, 0, &mvp, cast(u32)size_of(matrix[4, 4]f32))

		render_pass := sdl.BeginGPURenderPass(cmdbuf, &colorTargetInfo, 1, &depthTargetInfo)

		// Hardware indexed PVP: SDL applies the index buffer, then the selected vertex
		// shader pulls bytes from the shared geometry storage buffer.
		storage_buffers := [?]^sdl.GPUBuffer{geometry_pool.vertex_buffer}
		sdl.BindGPUVertexStorageBuffers(render_pass, 0, raw_data(storage_buffers[:]), 1)
		sdl.BindGPUIndexBuffer(
			render_pass,
			sdl.GPUBufferBinding{buffer = geometry_pool.index_buffer, offset = 0},
			sdl.GPUIndexElementSize._32BIT,
		)

		for geometry in geometry_pool.geometries[:int(geometry_pool.geometry_count)] {
			pipeline: ^sdl.GPUGraphicsPipeline

			switch geometry.layout_kind {
			case .Invalid:
				log.assertf(false, "unsupported geometry layout: %v", geometry.layout_kind)
			case .Position_Color_F32x4:
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
				pipeline = use_wireframe_mode ? prototype_line_pipeline : prototype_fill_pipeline
			case .Terrain_Packed_U32:
				draw_params := TerrainDrawParams {
					vertex_byte_offset  = geometry.vertex_byte_offset,
					vertex_stride_bytes = geometry.vertex_stride_bytes,
					chunk_origin        = {-3.25, -1.0, 1.0, 0.5},
				}
				sdl.PushGPUVertexUniformData(
					cmdbuf,
					1,
					&draw_params,
					cast(u32)size_of(TerrainDrawParams),
				)
				pipeline = use_wireframe_mode ? terrain_line_pipeline : terrain_fill_pipeline
			}

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

		sdl.EndGPURenderPass(render_pass)
	}

	log.assertf(sdl.SubmitGPUCommandBuffer(cmdbuf), "SubmitGPUCommandBuffer: %s", sdl.GetError())
}

process_events :: proc() {
	for event: sdl.Event; sdl.PollEvent(&event); {
		#partial switch event.type {
		case .QUIT:
			log.debug("Quit event received")
			is_window_open = false
		case .KEY_DOWN:
			{
				if event.key.scancode == sdl.Scancode.ESCAPE {
					log.debug("Escape key pressed")
					is_window_open = false
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

handle_input :: proc(dt: f32) {
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
	for is_window_open {
		now := sdl.GetTicks()
		dt := cast(f32)(now - current_time) / 1000.0
		current_time = now

		process_events()
		update_camera_vectors()
		handle_input(dt)
		update()
		render()
	}
}
