package world

import world_async "async:world"
import biomes "world:biomes"

//////////////////////////////////////
// Cave Material Types
/////////////////////////////////////

TerrainCaveWallMaterialBuffer :: struct {
	stamp:               [CHUNK_BLOCK_COUNT]u32,
	wall_material_id:    [CHUNK_BLOCK_COUNT]world_async.BlockMaterialID,
	floor_material_id:   [CHUNK_BLOCK_COUNT]world_async.BlockMaterialID,
	ceiling_material_id: [CHUNK_BLOCK_COUNT]world_async.BlockMaterialID,
	next_stamp:          u32,
}


//////////////////////////////////////
// Cave Material Methods
/////////////////////////////////////

terrain_binary_cave_face_material_index :: proc(normal_id, material_idx: u32) -> u32 {
	if material_idx == TERRAIN_AQUIFER_WALL_MAT_ID {
		if normal_id == 2 {
			return TERRAIN_WET_MARSH_MAT_ID
		}
		if normal_id == 3 {
			return TERRAIN_STONE_MAT_ID
		}
	}
	if material_idx == TERRAIN_CRYSTAL_MAT_ID && normal_id == 2 {
		return TERRAIN_STONE_MAT_ID
	}
	return material_idx
}

when TERRAIN_CAVE_DEFER_WALL_MATERIAL_BUFFER {
	terrain_cave_wall_material_buffer_clear :: proc(buffer: ^TerrainCaveWallMaterialBuffer) {
		for i := 0; i < CHUNK_BLOCK_COUNT; i += 1 {
			buffer.stamp[i] = 0
		}
		buffer.next_stamp = 0
	}

	terrain_cave_wall_material_buffer_mark_source :: proc(
		buffer: ^TerrainCaveWallMaterialBuffer,
		index: u32,
		wall_material_id: world_async.BlockMaterialID,
		floor_material_id: world_async.BlockMaterialID,
		ceiling_material_id: world_async.BlockMaterialID,
	) {
		if buffer.next_stamp == max(u32) {
			terrain_cave_wall_material_buffer_clear(buffer)
		}
		buffer.next_stamp += 1
		buffer.stamp[index] = buffer.next_stamp
		buffer.wall_material_id[index] = wall_material_id
		buffer.floor_material_id[index] = floor_material_id
		buffer.ceiling_material_id[index] = ceiling_material_id
	}

	terrain_cave_wall_material_buffer_best_source :: proc(
		buffer: ^TerrainCaveWallMaterialBuffer,
		source_index: u32,
		material_id: world_async.BlockMaterialID,
		best_stamp: ^u32,
		best_material_id: ^world_async.BlockMaterialID,
	) {
		stamp := buffer.stamp[source_index]
		if stamp > best_stamp^ {
			best_stamp^ = stamp
			best_material_id^ = material_id
		}
	}

	terrain_cave_wall_material_buffer_flush :: proc(
		view: ^world_async.ChunkVoxelView,
		buffer: ^TerrainCaveWallMaterialBuffer,
	) {
		for z := u32(0); z < CHUNK_BLOCK_LENGTH; z += 1 {
			for y := u32(0); y < CHUNK_BLOCK_LENGTH; y += 1 {
				for x := u32(0); x < CHUNK_BLOCK_LENGTH; x += 1 {
					index := chunk_block_index(x, y, z)
					if view.blocks.occupancy[index] != .Solid {
						continue
					}
					if terrain_material_palette_index(view.blocks.material_id[index]) ==
					   TERRAIN_WATER_MAT_ID {
						continue
					}

					best_stamp: u32
					best_material_id := view.blocks.material_id[index]
					when TERRAIN_GENERATION_PROFILE_PHASES {
						terrain_generation_profile_stats.wall_neighbor_checks += 6
					}
					if x > 0 {
						source_index := index - 1
						terrain_cave_wall_material_buffer_best_source(
							buffer,
							source_index,
							buffer.wall_material_id[source_index],
							&best_stamp,
							&best_material_id,
						)
					}
					if x < CHUNK_BLOCK_LOCAL_MAX {
						source_index := index + 1
						terrain_cave_wall_material_buffer_best_source(
							buffer,
							source_index,
							buffer.wall_material_id[source_index],
							&best_stamp,
							&best_material_id,
						)
					}
					if y > 0 {
						source_index := index - u32(CHUNK_BLOCK_LENGTH)
						terrain_cave_wall_material_buffer_best_source(
							buffer,
							source_index,
							buffer.ceiling_material_id[source_index],
							&best_stamp,
							&best_material_id,
						)
					}
					if y < CHUNK_BLOCK_LOCAL_MAX {
						source_index := index + u32(CHUNK_BLOCK_LENGTH)
						terrain_cave_wall_material_buffer_best_source(
							buffer,
							source_index,
							buffer.floor_material_id[source_index],
							&best_stamp,
							&best_material_id,
						)
					}
					if z > 0 {
						source_index := index - u32(CHUNK_BLOCK_LENGTH * CHUNK_BLOCK_LENGTH)
						terrain_cave_wall_material_buffer_best_source(
							buffer,
							source_index,
							buffer.wall_material_id[source_index],
							&best_stamp,
							&best_material_id,
						)
					}
					if z < CHUNK_BLOCK_LOCAL_MAX {
						source_index := index + u32(CHUNK_BLOCK_LENGTH * CHUNK_BLOCK_LENGTH)
						terrain_cave_wall_material_buffer_best_source(
							buffer,
							source_index,
							buffer.wall_material_id[source_index],
							&best_stamp,
							&best_material_id,
						)
					}

					if best_stamp == 0 {
						continue
					}
					view.blocks.material_id[index] = best_material_id
					when TERRAIN_GENERATION_PROFILE_PHASES {
						terrain_generation_profile_stats.wall_neighbor_writes += 1
					}
				}
			}
		}
	}
}

terrain_density_mark_cave_wall_neighbors :: proc(
	view: ^world_async.ChunkVoxelView,
	local_x, local_y, local_z: i32,
	biome_id: biomes.BiomeID,
	directional_material_profile: bool = false,
	wall_buffer: ^TerrainCaveWallMaterialBuffer = nil,
) {
	wall_material_id: world_async.BlockMaterialID
	floor_material_id: world_async.BlockMaterialID
	ceiling_material_id: world_async.BlockMaterialID
	if directional_material_profile {
		wall_material_id, floor_material_id, ceiling_material_id = terrain_cave_material_profile(
			biome_id,
		)
	} else {
		wall_material_id = terrain_cave_wall_material_id(biome_id)
		floor_material_id = wall_material_id
		ceiling_material_id = wall_material_id
	}
	when TERRAIN_CAVE_DEFER_WALL_MATERIAL_BUFFER {
		if wall_buffer != nil {
			index := chunk_block_index(u32(local_x), u32(local_y), u32(local_z))
			terrain_cave_wall_material_buffer_mark_source(
				wall_buffer,
				index,
				wall_material_id,
				floor_material_id,
				ceiling_material_id,
			)
			return
		}
	}
	if local_x > 0 &&
	   local_x < CHUNK_BLOCK_LOCAL_MAX &&
	   local_y > 0 &&
	   local_y < CHUNK_BLOCK_LOCAL_MAX &&
	   local_z > 0 &&
	   local_z < CHUNK_BLOCK_LOCAL_MAX {
		base_index := chunk_block_index(u32(local_x), u32(local_y), u32(local_z))
		y_stride := u32(CHUNK_BLOCK_LENGTH)
		z_stride := u32(CHUNK_BLOCK_LENGTH * CHUNK_BLOCK_LENGTH)
		when TERRAIN_GENERATION_PROFILE_PHASES {
			terrain_generation_profile_stats.wall_neighbor_checks += 6
		}
		terrain_density_mark_cave_wall_neighbor_index(view, base_index + 1, wall_material_id)
		terrain_density_mark_cave_wall_neighbor_index(view, base_index - 1, wall_material_id)
		terrain_density_mark_cave_wall_neighbor_index(
			view,
			base_index + y_stride,
			ceiling_material_id,
		)
		terrain_density_mark_cave_wall_neighbor_index(
			view,
			base_index - y_stride,
			floor_material_id,
		)
		terrain_density_mark_cave_wall_neighbor_index(
			view,
			base_index + z_stride,
			wall_material_id,
		)
		terrain_density_mark_cave_wall_neighbor_index(
			view,
			base_index - z_stride,
			wall_material_id,
		)
		return
	}
	terrain_density_mark_cave_wall_neighbor(view, local_x + 1, local_y, local_z, wall_material_id)
	terrain_density_mark_cave_wall_neighbor(view, local_x - 1, local_y, local_z, wall_material_id)
	terrain_density_mark_cave_wall_neighbor(
		view,
		local_x,
		local_y + 1,
		local_z,
		ceiling_material_id,
	)
	terrain_density_mark_cave_wall_neighbor(view, local_x, local_y - 1, local_z, floor_material_id)
	terrain_density_mark_cave_wall_neighbor(view, local_x, local_y, local_z + 1, wall_material_id)
	terrain_density_mark_cave_wall_neighbor(view, local_x, local_y, local_z - 1, wall_material_id)
}

terrain_density_mark_cave_wall_neighbor_index :: proc(
	view: ^world_async.ChunkVoxelView,
	index: u32,
	material_id: world_async.BlockMaterialID,
) {
	if view.blocks.occupancy[index] != .Solid {
		return
	}
	if terrain_material_palette_index(view.blocks.material_id[index]) == TERRAIN_WATER_MAT_ID {
		return
	}
	view.blocks.material_id[index] = material_id
	when TERRAIN_GENERATION_PROFILE_PHASES {
		terrain_generation_profile_stats.wall_neighbor_writes += 1
	}
}

terrain_density_mark_cave_wall_neighbor :: proc(
	view: ^world_async.ChunkVoxelView,
	local_x, local_y, local_z: i32,
	material_id: world_async.BlockMaterialID,
) {
	when TERRAIN_GENERATION_PROFILE_PHASES {
		terrain_generation_profile_stats.wall_neighbor_checks += 1
	}
	if !chunk_block_coord_is_inside(local_x, local_y, local_z) {
		return
	}
	index := chunk_block_index(u32(local_x), u32(local_y), u32(local_z))
	terrain_density_mark_cave_wall_neighbor_index(view, index, material_id)
}

terrain_cave_material_profile :: proc(
	biome_id: biomes.BiomeID,
) -> (
	wall_material_id, floor_material_id, ceiling_material_id: world_async.BlockMaterialID,
) {
	profile := biomes.biome_material_profile_for(biome_id)
	return terrain_block_material_id_from_biome_material(
		profile.cave_wall,
	), terrain_block_material_id_from_biome_material(profile.cave_floor), terrain_block_material_id_from_biome_material(profile.cave_ceiling)
}

terrain_cave_wall_material_id :: proc(biome_id: biomes.BiomeID) -> world_async.BlockMaterialID {
	profile := biomes.biome_material_profile_for(biome_id)
	return terrain_block_material_id_from_biome_material(profile.cave_wall)
}

terrain_cave_wall_material_id_for_neighbor :: proc(
	biome_id: biomes.BiomeID,
	offset: world_async.BlockCoord,
) -> world_async.BlockMaterialID {
	if offset.y < 0 {
		return terrain_cave_floor_material_id(biome_id)
	}
	if offset.y > 0 {
		return terrain_cave_ceiling_material_id(biome_id)
	}
	return terrain_cave_wall_material_id(biome_id)
}

terrain_cave_floor_material_id :: proc(biome_id: biomes.BiomeID) -> world_async.BlockMaterialID {
	_, floor_material_id, _ := terrain_cave_material_profile(biome_id)
	return floor_material_id
}

terrain_cave_ceiling_material_id :: proc(biome_id: biomes.BiomeID) -> world_async.BlockMaterialID {
	_, _, ceiling_material_id := terrain_cave_material_profile(biome_id)
	return ceiling_material_id
}
