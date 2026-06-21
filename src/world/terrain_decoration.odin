package world

import world_async "async:world"
import biomes "world:biomes"

import "core:log"
import math "core:math"

//////////////////////////////////////
// Terrain Decoration Types
/////////////////////////////////////

TerrainDecorationApplyStats :: struct {
	surface_candidates: u32,
	surface_accepted:   u32,
	cave_candidates:    u32,
	cave_accepted:      u32,
	blocks_written:     u32,
	family_candidates:  [biomes.DECORATION_FAMILY_COUNT]u32,
	family_accepted:    [biomes.DECORATION_FAMILY_COUNT]u32,
	family_blocks:      [biomes.DECORATION_FAMILY_COUNT]u32,
}

//////////////////////////////////////
// Terrain Decoration Constants
/////////////////////////////////////

TERRAIN_DECORATION_ENABLED :: #config(TERRAIN_DECORATION_ENABLED, true)
TERRAIN_DECORATION_SURFACE_EDGE_MARGIN_BLOCKS :: i32(3)
TERRAIN_DECORATION_CAVE_EDGE_MARGIN_BLOCKS :: i32(3)
TERRAIN_DECORATION_CAVE_FLOOR_SEARCH_EXTRA_BLOCKS :: i32(8)

//////////////////////////////////////
// Terrain Decoration Methods
/////////////////////////////////////

terrain_decoration_pass_apply :: proc(
	view: ^world_async.ChunkVoxelView,
	generation_region: ^biomes.GenerationRegion,
	chunk_origin: world_async.BlockCoord,
	columns: []TerrainBiomeColumn,
) -> TerrainDecorationApplyStats {
	stats := TerrainDecorationApplyStats{}
	when !TERRAIN_DECORATION_ENABLED {
		_ = view
		_ = generation_region
		_ = chunk_origin
		_ = columns
		return stats
	}

	log.assertf(
		len(columns) == CHUNK_BLOCK_LENGTH * CHUNK_BLOCK_LENGTH,
		"terrain decoration column target count mismatch: %d",
		len(columns),
	)
	chunk_bounds := biomes.BlockBounds3 {
		min = {x = chunk_origin.x, y = chunk_origin.y, z = chunk_origin.z},
		max = {
			x = chunk_origin.x + CHUNK_BLOCK_LENGTH,
			y = chunk_origin.y + CHUNK_BLOCK_LENGTH,
			z = chunk_origin.z + CHUNK_BLOCK_LENGTH,
		},
	}
	query := biomes.generation_region_query_make_default(chunk_bounds)

	surface_features: [biomes.GENERATION_REGION_SURFACE_DECORATION_FEATURE_CAPACITY]biomes.DecorationFeature
	surface_feature_count := biomes.generation_region_surface_decoration_features_write(
		generation_region,
		query,
		surface_features[:],
	)
	stats.surface_candidates = surface_feature_count
	for i := u32(0); i < surface_feature_count; i += 1 {
		terrain_decoration_stats_family_candidate_add(&stats, surface_features[i].family_id)
		written := terrain_decoration_surface_feature_apply(
			view,
			surface_features[i],
			chunk_origin,
			columns,
		)
		if written > 0 {
			stats.surface_accepted += 1
			stats.blocks_written += written
			terrain_decoration_stats_family_accepted_add(&stats, surface_features[i].family_id, written)
		}
	}

	for i := u32(0); i < generation_region.cave_network_node_count; i += 1 {
		node := generation_region.cave_network_nodes[i]
		family_id, chance, found := biomes.decoration_cave_family_for_node(node)
		if !found {
			continue
		}
		stats.cave_candidates += 1
		terrain_decoration_stats_family_candidate_add(&stats, family_id)
		when TERRAIN_BAKE_DEBUG_MATERIAL_FLAGS {
			terrain_decoration_cave_node_candidate_mark(view, node, chunk_origin)
		}
		if !biomes.decoration_cave_feature_roll_accepts(node, chance) {
			continue
		}
		written := terrain_decoration_cave_node_apply(view, node, family_id, chunk_origin)
		if written > 0 {
			stats.cave_accepted += 1
			stats.blocks_written += written
			terrain_decoration_stats_family_accepted_add(&stats, family_id, written)
		}
	}
	return stats
}

terrain_decoration_surface_feature_apply :: proc(
	view: ^world_async.ChunkVoxelView,
	feature: biomes.DecorationFeature,
	chunk_origin: world_async.BlockCoord,
	columns: []TerrainBiomeColumn,
) -> u32 {
	local_x := i32(math.floor_f32(feature.x)) - chunk_origin.x
	local_z := i32(math.floor_f32(feature.z)) - chunk_origin.z
	if !terrain_decoration_local_xz_inside(local_x, local_z, TERRAIN_DECORATION_SURFACE_EDGE_MARGIN_BLOCKS) {
		return 0
	}

	column := columns[local_x + local_z * CHUNK_BLOCK_LENGTH]
	if column.water_fill_active {
		return 0
	}
	base_y := column.surface_height - chunk_origin.y
	if base_y < 0 || base_y >= CHUNK_BLOCK_LOCAL_MAX {
		return 0
	}
	base_index := chunk_block_index(u32(local_x), u32(base_y), u32(local_z))
	if view.blocks.occupancy[base_index] != .Solid {
		return 0
	}
	if terrain_material_palette_index(view.blocks.material_id[base_index]) == TERRAIN_WATER_MAT_ID {
		return 0
	}
	when TERRAIN_BAKE_DEBUG_MATERIAL_FLAGS {
		terrain_decoration_block_mark_debug(view, local_x, base_y, local_z)
	}

	switch feature.family_id {
	case .Baseline_Tree, .Dead_Ash_Tree:
		return terrain_decoration_tree_apply(view, feature.family_id, local_x, base_y, local_z, feature.height_blocks)
	case .Crystal_Growth_Cluster:
		return terrain_decoration_crystal_cluster_apply(
			view,
			local_x,
			base_y,
			local_z,
			feature.height_blocks,
			true,
		)
	case .Fungal_Tree:
		return 0
	}
	return 0
}

when TERRAIN_BAKE_DEBUG_MATERIAL_FLAGS {
	terrain_decoration_cave_node_candidate_mark :: proc(
		view: ^world_async.ChunkVoxelView,
		node: biomes.CaveNetworkNode,
		chunk_origin: world_async.BlockCoord,
	) {
		local_x := i32(math.floor_f32(node.x)) - chunk_origin.x
		local_y := i32(math.floor_f32(node.y)) - chunk_origin.y
		local_z := i32(math.floor_f32(node.z)) - chunk_origin.z
		if !terrain_decoration_local_xz_inside(
			local_x,
			local_z,
			TERRAIN_DECORATION_CAVE_EDGE_MARGIN_BLOCKS,
		) {
			return
		}

		search_extra := TERRAIN_DECORATION_CAVE_FLOOR_SEARCH_EXTRA_BLOCKS
		radius := i32(math.ceil_f32(node.radius_blocks))
		search_top := math.min(local_y + radius / 2, CHUNK_BLOCK_LOCAL_MAX - 1)
		search_bottom := math.max(local_y - radius - search_extra, 1)
		base_y, found_floor :=
			terrain_decoration_cave_floor_find(view, local_x, local_z, search_top, search_bottom)
		if found_floor {
			terrain_decoration_block_mark_debug(view, local_x, base_y, local_z)
		}
	}
}

terrain_decoration_cave_node_apply :: proc(
	view: ^world_async.ChunkVoxelView,
	node: biomes.CaveNetworkNode,
	family_id: biomes.DecorationFamilyID,
	chunk_origin: world_async.BlockCoord,
) -> u32 {
	local_x := i32(math.floor_f32(node.x)) - chunk_origin.x
	local_y := i32(math.floor_f32(node.y)) - chunk_origin.y
	local_z := i32(math.floor_f32(node.z)) - chunk_origin.z
	if !terrain_decoration_local_xz_inside(local_x, local_z, TERRAIN_DECORATION_CAVE_EDGE_MARGIN_BLOCKS) {
		return 0
	}

	search_extra := TERRAIN_DECORATION_CAVE_FLOOR_SEARCH_EXTRA_BLOCKS
	radius := i32(math.ceil_f32(node.radius_blocks))
	search_top := math.min(local_y + radius / 2, CHUNK_BLOCK_LOCAL_MAX - 1)
	search_bottom := math.max(local_y - radius - search_extra, 1)
	base_y, found_floor := terrain_decoration_cave_floor_find(view, local_x, local_z, search_top, search_bottom)
	if !found_floor {
		return 0
	}

	profile := biomes.decoration_family_profile_for(family_id)
	height := biomes.decoration_feature_height_from_id(node.id, profile)
	switch family_id {
	case .Fungal_Tree:
		return terrain_decoration_tree_apply(view, family_id, local_x, base_y, local_z, height)
	case .Crystal_Growth_Cluster:
		return terrain_decoration_crystal_cluster_apply(view, local_x, base_y, local_z, height, false)
	case .Baseline_Tree, .Dead_Ash_Tree:
		return 0
	}
	return 0
}

terrain_decoration_tree_apply :: proc(
	view: ^world_async.ChunkVoxelView,
	family_id: biomes.DecorationFamilyID,
	local_x, base_y, local_z: i32,
	height_blocks: u8,
) -> u32 {
	profile := biomes.decoration_family_profile_for(family_id)
	height := i32(height_blocks)
	radius := i32(profile.radius_blocks)
	top_y := base_y + height
	if top_y + radius >= CHUNK_BLOCK_LENGTH || base_y + 1 <= 0 {
		return 0
	}
	if !terrain_decoration_vertical_empty(view, local_x, base_y + 1, top_y + radius, local_z) {
		return 0
	}

	trunk_material := terrain_block_material_id_from_biome_material(profile.trunk_material)
	cap_material := terrain_block_material_id_from_biome_material(profile.cap_material)
	written: u32
	for y := base_y + 1; y <= top_y; y += 1 {
		if terrain_decoration_block_try_write(view, local_x, y, local_z, trunk_material) {
			written += 1
		}
	}

	switch family_id {
	case .Baseline_Tree, .Fungal_Tree:
		for dz := -radius; dz <= radius; dz += 1 {
			for dx := -radius; dx <= radius; dx += 1 {
				distance := math.abs(dx) + math.abs(dz)
				if distance > radius + 1 {
					continue
				}
				for dy := i32(-1); dy <= radius - distance / 2; dy += 1 {
					if terrain_decoration_block_try_write(
						view,
						local_x + dx,
						top_y + dy,
						local_z + dz,
						cap_material,
					) {
						written += 1
					}
				}
			}
		}
	case .Dead_Ash_Tree:
		branch_y := math.max(base_y + 2, top_y - 1)
		branch_material := cap_material
		for offset := i32(1); offset <= radius + 2; offset += 1 {
			if terrain_decoration_block_try_write(view, local_x + offset, branch_y, local_z, branch_material) {
				written += 1
			}
			if terrain_decoration_block_try_write(view, local_x - offset, branch_y, local_z, branch_material) {
				written += 1
			}
			if offset <= radius + 1 &&
			   terrain_decoration_block_try_write(
					   view,
					   local_x,
					   branch_y + 1,
					   local_z + offset,
					   branch_material,
				   ) {
				written += 1
			}
		}
	case .Crystal_Growth_Cluster:
	}
	return written
}

terrain_decoration_crystal_cluster_apply :: proc(
	view: ^world_async.ChunkVoxelView,
	local_x, base_y, local_z: i32,
	height_blocks: u8,
	surface: bool,
) -> u32 {
	height := i32(height_blocks)
	if height <= 0 || base_y + height >= CHUNK_BLOCK_LENGTH {
		return 0
	}
	if !terrain_decoration_vertical_empty(view, local_x, base_y + 1, base_y + height, local_z) {
		return 0
	}
	material := terrain_block_material_id_from_biome_material(.Crystal)
	written: u32
	for y := base_y + 1; y <= base_y + height; y += 1 {
		if terrain_decoration_block_try_write(view, local_x, y, local_z, material) {
			written += 1
		}
	}

	side_height := math.max(i32(1), height / 2)
	side_offsets := [?]world_async.BlockCoord {
		{x = 1, y = 0, z = 0},
		{x = -1, y = 0, z = 0},
		{x = 0, y = 0, z = 1},
		{x = 0, y = 0, z = -1},
	}
	for offset, offset_index in side_offsets {
		if surface && (offset_index & 1) != 0 {
			continue
		}
		side_base_y := base_y
		if terrain_decoration_floor_supports(view, local_x + offset.x, side_base_y, local_z + offset.z) {
			for y := side_base_y + 1; y <= side_base_y + side_height; y += 1 {
				if terrain_decoration_block_try_write(
					view,
					local_x + offset.x,
					y,
					local_z + offset.z,
					material,
				) {
					written += 1
				}
			}
		}
	}
	return written
}

terrain_decoration_cave_floor_find :: proc(
	view: ^world_async.ChunkVoxelView,
	local_x, local_z, search_top, search_bottom: i32,
) -> (
	base_y: i32,
	found: bool,
) {
	if search_top < search_bottom {
		return
	}
	for y := search_top; y >= search_bottom; y -= 1 {
		if !terrain_decoration_block_is_empty(view, local_x, y, local_z) {
			continue
		}
		floor_y := y - 1
		if terrain_decoration_floor_supports(view, local_x, floor_y, local_z) {
			return floor_y, true
		}
	}
	return
}

terrain_decoration_floor_supports :: proc(
	view: ^world_async.ChunkVoxelView,
	local_x, local_y, local_z: i32,
) -> bool {
	if !chunk_block_coord_is_inside(local_x, local_y, local_z) {
		return false
	}
	index := chunk_block_index(u32(local_x), u32(local_y), u32(local_z))
	if view.blocks.occupancy[index] != .Solid {
		return false
	}
	return terrain_material_palette_index(view.blocks.material_id[index]) != TERRAIN_WATER_MAT_ID
}

terrain_decoration_vertical_empty :: proc(
	view: ^world_async.ChunkVoxelView,
	local_x, min_y, max_y, local_z: i32,
) -> bool {
	if min_y > max_y {
		return true
	}
	if !chunk_block_coord_is_inside(local_x, min_y, local_z) ||
	   !chunk_block_coord_is_inside(local_x, max_y, local_z) {
		return false
	}
	for y := min_y; y <= max_y; y += 1 {
		if !terrain_decoration_block_is_empty(view, local_x, y, local_z) {
			return false
		}
	}
	return true
}

terrain_decoration_block_is_empty :: proc(
	view: ^world_async.ChunkVoxelView,
	local_x, local_y, local_z: i32,
) -> bool {
	if !chunk_block_coord_is_inside(local_x, local_y, local_z) {
		return false
	}
	index := chunk_block_index(u32(local_x), u32(local_y), u32(local_z))
	return view.blocks.occupancy[index] == .Empty
}

terrain_decoration_block_try_write :: proc(
	view: ^world_async.ChunkVoxelView,
	local_x, local_y, local_z: i32,
	material_id: world_async.BlockMaterialID,
) -> bool {
	if !terrain_decoration_block_is_empty(view, local_x, local_y, local_z) {
		return false
	}
	index := chunk_block_index(u32(local_x), u32(local_y), u32(local_z))
	view.blocks.occupancy[index] = .Solid
	when TERRAIN_BAKE_DEBUG_MATERIAL_FLAGS {
		view.blocks.material_id[index] = terrain_decoration_debug_material_id(material_id)
	}
	when !TERRAIN_BAKE_DEBUG_MATERIAL_FLAGS {
		view.blocks.material_id[index] = material_id
	}
	return true
}

when TERRAIN_BAKE_DEBUG_MATERIAL_FLAGS {
	terrain_decoration_block_mark_debug :: proc(
		view: ^world_async.ChunkVoxelView,
		local_x, local_y, local_z: i32,
	) {
		if !chunk_block_coord_is_inside(local_x, local_y, local_z) {
			return
		}
		index := chunk_block_index(u32(local_x), u32(local_y), u32(local_z))
		if view.blocks.occupancy[index] != .Solid {
			return
		}
		view.blocks.material_id[index] = terrain_decoration_debug_material_id(
			view.blocks.material_id[index],
		)
	}
}

terrain_decoration_stats_family_candidate_add :: proc(
	stats: ^TerrainDecorationApplyStats,
	family_id: biomes.DecorationFamilyID,
) {
	stats.family_candidates[u32(family_id)] += 1
}

terrain_decoration_stats_family_accepted_add :: proc(
	stats: ^TerrainDecorationApplyStats,
	family_id: biomes.DecorationFamilyID,
	blocks_written: u32,
) {
	index := u32(family_id)
	stats.family_accepted[index] += 1
	stats.family_blocks[index] += blocks_written
}

terrain_decoration_local_xz_inside :: proc(local_x, local_z, margin: i32) -> bool {
	return(
		local_x >= margin &&
		local_z >= margin &&
		local_x < CHUNK_BLOCK_LENGTH - margin &&
		local_z < CHUNK_BLOCK_LENGTH - margin \
	)
}
