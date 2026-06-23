package world

import world_async "async:world"
import "core:log"
import bits "core:math/bits"
import "core:mem"

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

TerrainUnpackedVertex :: struct {
	block_x, block_y, block_z: u32,
	normal_id, material_id:    u32,
}
#assert(size_of(TerrainUnpackedVertex) == 20)

TerrainBinaryGreedyScratch :: struct {
	solid_rows:              [TERRAIN_BINARY_AXIS_COUNT][TERRAIN_BINARY_AXIS_ROW_COUNT]u64,
	material_masks:          [TERRAIN_BINARY_AXIS_COUNT][TERRAIN_BINARY_AXIS_ROW_COUNT]u8,
	material_rows:           [TERRAIN_BINARY_AXIS_COUNT][TERRAIN_MATERIAL_PALETTE_COUNT][TERRAIN_BINARY_AXIS_ROW_COUNT]u64,
	hydrology_debug_rows:    [TERRAIN_BINARY_AXIS_COUNT][TERRAIN_BINARY_AXIS_ROW_COUNT]u64,
	cave_network_debug_rows: [TERRAIN_BINARY_AXIS_COUNT][TERRAIN_BINARY_AXIS_ROW_COUNT]u64,
	face_material_masks:     [CHUNK_BLOCK_LENGTH][TERRAIN_MATERIAL_FACE_VARIANT_MASK_WORD_COUNT]u64,
	face_masks:              [CHUNK_BLOCK_LENGTH][TERRAIN_MATERIAL_FACE_VARIANT_COUNT][CHUNK_BLOCK_LENGTH]u64,
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

terrain_binary_greedy_scratch_alloc :: proc(arena: ^mem.Arena) -> ^TerrainBinaryGreedyScratch {
	scratch_ptr, scratch_err := mem.arena_alloc(
		arena,
		size_of(TerrainBinaryGreedyScratch),
		align_of(TerrainBinaryGreedyScratch),
	)
	scratch := (^TerrainBinaryGreedyScratch)(scratch_ptr)
	log.assertf(
		scratch_err == nil && scratch != nil,
		"binary greedy scratch allocation failed: bytes=%d err=%v",
		size_of(TerrainBinaryGreedyScratch),
		scratch_err,
	)
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
	face_variant_idx, v, u: u32,
	face_bits: u64,
) {
	log.assertf(
		face_variant_idx < TERRAIN_MATERIAL_FACE_VARIANT_COUNT,
		"face material index out of range: %d",
		face_variant_idx,
	)
	remaining_bits := face_bits
	for remaining_bits != 0 {
		slice := u32(bits.trailing_zeros(remaining_bits))
		mask_word := face_variant_idx / 64
		mask_bit := face_variant_idx % 64
		scratch.face_material_masks[slice][mask_word] |= u64(1) << mask_bit
		scratch.face_masks[slice][face_variant_idx][v] |= u64(1) << u
		remaining_bits &~= u64(1) << slice
	}
}

terrain_binary_face_variant_index_make :: proc(
	material_idx, color_variant, debug_combo: u32,
) -> u32 {
	log.assertf(
		material_idx < TERRAIN_MATERIAL_PALETTE_COUNT,
		"face material out of range: %d",
		material_idx,
	)
	log.assertf(
		color_variant < TERRAIN_MATERIAL_COLOR_VARIANT_COUNT,
		"face color variant out of range: %d",
		color_variant,
	)
	when TERRAIN_MATERIAL_FACE_DEBUG_VARIANTS_ENABLED {
		log.assertf(
			debug_combo < TERRAIN_DEBUG_MATERIAL_FLAG_COMBO_COUNT,
			"face debug combo out of range: %d",
			debug_combo,
		)
	} else {
		log.assertf(debug_combo == 0, "face debug combo out of range: %d", debug_combo)
	}
	return(
		material_idx +
		color_variant * TERRAIN_MATERIAL_PALETTE_COUNT +
		debug_combo * TERRAIN_MATERIAL_COLOR_COUNT \
	)
}

terrain_binary_face_variant_material_id :: proc(face_variant_idx: u32) -> u32 {
	log.assertf(
		face_variant_idx < TERRAIN_MATERIAL_FACE_VARIANT_COUNT,
		"face variant index out of range: %d",
		face_variant_idx,
	)
	color_index := face_variant_idx % TERRAIN_MATERIAL_COLOR_COUNT
	debug_combo := face_variant_idx / TERRAIN_MATERIAL_COLOR_COUNT
	material_idx := color_index % TERRAIN_MATERIAL_PALETTE_COUNT
	color_variant := color_index / TERRAIN_MATERIAL_PALETTE_COUNT
	return(
		material_idx |
		(color_variant << u32(TERRAIN_MATERIAL_COLOR_VARIANT_SHIFT)) |
		terrain_debug_material_flags_from_combo(debug_combo) \
	)
}

terrain_binary_face_mask_debug_variants_add :: proc(
	scratch: ^TerrainBinaryGreedyScratch,
	axis, row_index, material_idx, color_variant, v, u: u32,
	exposed_material_bits: u64,
) {
	when TERRAIN_MATERIAL_FACE_DEBUG_VARIANTS_ENABLED {
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

			face_variant_idx := terrain_binary_face_variant_index_make(
				material_idx,
				color_variant,
				combo,
			)
			terrain_binary_face_mask_bits_add(scratch, face_variant_idx, v, u, variant_bits)
		}
		return
	}

	face_variant_idx := terrain_binary_face_variant_index_make(material_idx, color_variant, 0)
	terrain_binary_face_mask_bits_add(scratch, face_variant_idx, v, u, exposed_material_bits)
}

terrain_binary_face_color_variant_for_block :: proc(
	view: world_async.ChunkVoxelView,
	axis, row_index, axis_coord, face_material_idx: u32,
) -> u32 {
	x, y, z := terrain_binary_face_block_coord(axis, row_index, axis_coord)
	index := chunk_block_index(x, y, z)
	block_material_id := view.blocks.material_id[index]
	if terrain_material_palette_index(block_material_id) != (face_material_idx & 7) {
		return 0
	}
	return(
		(u32(u8(block_material_id) & TERRAIN_MATERIAL_COLOR_VARIANT_MASK) >>
			u32(TERRAIN_MATERIAL_COLOR_VARIANT_SHIFT)) &
		(TERRAIN_MATERIAL_COLOR_VARIANT_COUNT - 1) \
	)
}

terrain_binary_face_mask_debug_color_variants_add :: proc(
	scratch: ^TerrainBinaryGreedyScratch,
	view: world_async.ChunkVoxelView,
	axis, row_index, material_idx, v, u: u32,
	exposed_material_bits: u64,
) {
	remaining_bits := exposed_material_bits
	for remaining_bits != 0 {
		axis_coord := u32(bits.trailing_zeros(remaining_bits))
		face_bit := u64(1) << axis_coord
		color_variant := terrain_binary_face_color_variant_for_block(
			view,
			axis,
			row_index,
			axis_coord,
			material_idx,
		)
		terrain_binary_face_mask_debug_variants_add(
			scratch,
			axis,
			row_index,
			material_idx,
			color_variant,
			v,
			u,
			face_bit,
		)
		remaining_bits &~= face_bit
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
		terrain_binary_face_mask_debug_color_variants_add(
			scratch,
			view,
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
		terrain_binary_face_mask_debug_color_variants_add(
			scratch,
			view,
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
			terrain_binary_face_mask_debug_color_variants_add(
				scratch,
				view,
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
		terrain_binary_face_mask_debug_color_variants_add(
			scratch,
			view,
			axis,
			row_index,
			material_idx,
			v,
			u,
			grass_bits,
		)
		terrain_binary_face_mask_debug_color_variants_add(
			scratch,
			view,
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
		color_variant := terrain_binary_face_color_variant_for_block(
			view,
			axis,
			row_index,
			axis_coord,
			face_material_idx,
		)
		terrain_binary_face_mask_debug_variants_add(
			scratch,
			axis,
			row_index,
			face_material_idx,
			color_variant,
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
		for mask_word := u32(0);
		    mask_word < TERRAIN_MATERIAL_FACE_VARIANT_MASK_WORD_COUNT;
		    mask_word += 1 {
			material_mask := scratch.face_material_masks[slice][mask_word]
			for material_mask != 0 {
				material_bit := u32(bits.trailing_zeros(material_mask))
				face_variant_idx := mask_word * 64 + material_bit
				material_id := terrain_binary_face_variant_material_id(face_variant_idx)
				terrain_binary_greedy_material_process(
					scratch.face_masks[slice][face_variant_idx][:],
					normal_id,
					slice,
					material_id,
					vertices,
					indices,
					face_cursor,
					emit,
				)
				material_mask &~= u64(1) << material_bit
			}
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
		for mask_word := u32(0);
		    mask_word < TERRAIN_MATERIAL_FACE_VARIANT_MASK_WORD_COUNT;
		    mask_word += 1 {
			material_mask := scratch.face_material_masks[slice][mask_word]
			for material_mask != 0 {
				material_bit := u32(bits.trailing_zeros(material_mask))
				face_variant_idx := mask_word * 64 + material_bit
				material_id := terrain_binary_face_variant_material_id(face_variant_idx)
				terrain_binary_greedy_material_process_bounds(
					scratch.face_masks[slice][face_variant_idx][:],
					normal_id,
					slice,
					material_id,
					u_min,
					u_max,
					v_min,
					v_max,
					vertices,
					indices,
					face_cursor,
					emit,
				)
				material_mask &~= u64(1) << material_bit
			}
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
	scratch_arena: ^mem.Arena,
) -> world_async.ChunkMeshOutput {
	log.assertf(
		len(job.snapshot.voxel_view.blocks) == CHUNK_BLOCK_COUNT,
		"chunk mesh job snapshot must have %d blocks, got %d",
		CHUNK_BLOCK_COUNT,
		len(job.snapshot.voxel_view.blocks),
	)

	scratch := terrain_binary_greedy_scratch_alloc(scratch_arena)

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
