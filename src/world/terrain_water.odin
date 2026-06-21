package world

import world_async "async:world"
import "core:log"
import math "core:math"

//////////////////////////////////////
// Terrain Water Methods
/////////////////////////////////////

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

			// Surface water has no cross-chunk flood-fill state, so keep it near the
			// terrain surface and leave deep cave water to cave/aquifer features.
			chunk_top_world_y := chunk_origin.y + CHUNK_BLOCK_LENGTH - 1
			surface_gate_y :=
				i32(math.floor_f32(column.surface_height_blocks)) -
				TERRAIN_WATER_VOLUME_SURFACE_ADJACENT_DEPTH_BLOCKS
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
			for y := top_y; y >= 0; y -= 1 {
				index := chunk_block_index(u32(x), u32(y), u32(z))
				if view.blocks.occupancy[index] == .Solid {
					if terrain_material_palette_index(view.blocks.material_id[index]) ==
					   TERRAIN_WATER_MAT_ID {
						continue
					}
					break
				}

				view.blocks.occupancy[index] = .Solid
				view.blocks.material_id[index] = world_async.BlockMaterialID(TERRAIN_WATER_MAT_ID)
			}
		}
	}
}
