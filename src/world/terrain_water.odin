package world

import world_async "async:world"
import "core:log"
import math "core:math"

//////////////////////////////////////
// Terrain Water Methods
/////////////////////////////////////

terrain_water_volume_surface_gate_world_y :: proc(column: TerrainBiomeColumn) -> i32 {
	morphology_depth := i32(math.ceil_f32(column.surface_morphology_profile.band_below_blocks + 8))
	surface_adjacent_depth := math.max(
		TERRAIN_WATER_VOLUME_SURFACE_ADJACENT_DEPTH_BLOCKS,
		morphology_depth,
	)
	surface_adjacent_depth = math.clamp(surface_adjacent_depth, 1, CHUNK_BLOCK_LENGTH)
	return i32(math.floor_f32(column.surface_height_blocks)) - surface_adjacent_depth
}

terrain_water_column_is_flooded :: proc(column: TerrainBiomeColumn) -> bool {
	return column.water_fill_active && column.surface_height_blocks < column.water_level_blocks
}

terrain_water_surface_material_conflicts_neighbor :: proc(
	columns: []TerrainBiomeColumn,
	x, z: i32,
	material_id: world_async.BlockMaterialID,
) -> bool {
	neighbor_offsets := [?]world_async.BlockCoord {
		{x = 1, y = 0, z = 0},
		{x = -1, y = 0, z = 0},
		{x = 0, y = 0, z = 1},
		{x = 0, y = 0, z = -1},
	}
	for offset in neighbor_offsets {
		neighbor_x := x + offset.x
		neighbor_z := z + offset.z
		if neighbor_x < 0 ||
		   neighbor_z < 0 ||
		   neighbor_x >= CHUNK_BLOCK_LENGTH ||
		   neighbor_z >= CHUNK_BLOCK_LENGTH {
			continue
		}
		neighbor := columns[neighbor_x + neighbor_z * CHUNK_BLOCK_LENGTH]
		if !terrain_water_column_is_flooded(neighbor) {
			continue
		}
		neighbor_material_id := terrain_water_material_id_for_biome(neighbor.water_biome_id, false)
		if neighbor_material_id != material_id {
			return true
		}
	}
	return false
}

terrain_water_volume_fill :: proc(
	view: ^world_async.ChunkVoxelView,
	chunk_origin: world_async.BlockCoord,
	columns: []TerrainBiomeColumn,
) {
	log.assertf(
		len(columns) == CHUNK_BLOCK_LENGTH * CHUNK_BLOCK_LENGTH,
		"terrain water column target count mismatch: %d",
		len(columns),
	)

	for z in 0 ..< CHUNK_BLOCK_LENGTH {
		for x in 0 ..< CHUNK_BLOCK_LENGTH {
			column := columns[x + z * CHUNK_BLOCK_LENGTH]
			if !column.water_fill_active {
				continue
			}
			water_material_id := terrain_water_material_id_for_biome(column.water_biome_id, false)
			if terrain_water_surface_material_conflicts_neighbor(
				columns,
				i32(x),
				i32(z),
				water_material_id,
			) {
				continue
			}

			// Surface water has no cross-chunk flood-fill state, so keep it near the
			// terrain surface and leave deep cave water to cave/aquifer features.
			chunk_top_world_y := chunk_origin.y + CHUNK_BLOCK_LENGTH - 1
			surface_gate_y := terrain_water_volume_surface_gate_world_y(column)
			if chunk_top_world_y < surface_gate_y {
				continue
			}

			water_level := i32(math.floor_f32(column.water_level_blocks))
			if water_level < chunk_origin.y {
				continue
			}

			top_y := math.min(CHUNK_BLOCK_LENGTH - 1, water_level - chunk_origin.y)
			if top_y < 0 {
				continue
			}
			bottom_y := math.max(0, surface_gate_y - chunk_origin.y)
			if top_y < bottom_y {
				continue
			}
			for y := top_y; y >= bottom_y; y -= 1 {
				index := chunk_block_index(u32(x), u32(y), u32(z))
				if view.blocks.occupancy[index] == .Solid {
					if terrain_material_palette_index(view.blocks.material_id[index]) ==
					   TERRAIN_WATER_MAT_ID {
						continue
					}
					break
				}

				view.blocks.occupancy[index] = .Solid
				view.blocks.material_id[index] = water_material_id
			}
		}
	}
}
