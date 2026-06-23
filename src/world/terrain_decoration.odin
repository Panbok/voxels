package world

import world_async "async:world"
import biomes "world:biomes"

import "core:log"
import math "core:math"

//////////////////////////////////////
// Terrain Decoration Types
/////////////////////////////////////

TerrainDecorationApplyStats :: struct {
	surface_candidates:               u32,
	surface_accepted:                 u32,
	surface_tree_instances_attempted: u32,
	surface_tree_instances_accepted:  u32,
	surface_tree_root_rejected:       u32,
	surface_tree_shape_rejected:      u32,
	cave_candidates:                  u32,
	cave_accepted:                    u32,
	blocks_written:                   u32,
	family_candidates:                [biomes.DECORATION_FAMILY_COUNT]u32,
	family_accepted:                  [biomes.DECORATION_FAMILY_COUNT]u32,
	family_blocks:                    [biomes.DECORATION_FAMILY_COUNT]u32,
}

TerrainDecorationSurfaceApplyResult :: struct {
	blocks_written:           u32,
	tree_instances_attempted: u32,
	tree_instances_accepted:  u32,
	tree_root_rejected:       u32,
	tree_shape_rejected:      u32,
}

TerrainDecorationTreeMaterials :: struct {
	trunk:             world_async.BlockMaterialID,
	branch:            world_async.BlockMaterialID,
	cap:               world_async.BlockMaterialID,
	cap_accent:        world_async.BlockMaterialID,
	cap_accent_chance: f32,
}

TerrainDecorationStampMaterials :: struct {
	primary:   world_async.BlockMaterialID,
	secondary: world_async.BlockMaterialID,
	accent:    world_async.BlockMaterialID,
}

TerrainDecorationStampContext :: struct {
	surface:        bool,
	chunk_origin_y: i32,
	columns:        []TerrainBiomeColumn,
}

TerrainDecorationSurfaceReservation :: struct {
	x, z:          f32,
	radius_blocks: f32,
	family_id:     biomes.DecorationFamilyID,
}

//////////////////////////////////////
// Terrain Decoration Constants
/////////////////////////////////////

TERRAIN_DECORATION_ENABLED :: #config(TERRAIN_DECORATION_ENABLED, true)
TERRAIN_DECORATION_SURFACE_EDGE_MARGIN_BLOCKS :: i32(3)
TERRAIN_DECORATION_CAVE_EDGE_MARGIN_BLOCKS :: i32(3)
TERRAIN_DECORATION_CAVE_FLOOR_SEARCH_EXTRA_BLOCKS :: i32(20)
TERRAIN_DECORATION_TREE_MEMBER_SALT :: u64(0x864d3f12a5c907eb)
TERRAIN_DECORATION_TREE_MEMBER_OFFSET_X_SALT :: u64(0x4b73e0c91d2f865a)
TERRAIN_DECORATION_TREE_MEMBER_OFFSET_Z_SALT :: u64(0x28f6b40de751a9c3)
TERRAIN_DECORATION_TREE_MEMBER_VARIANT_SALT :: u64(0xc5197ba48ed6032f)
TERRAIN_DECORATION_TREE_MEMBER_ROTATION_SALT :: u64(0x70f3a51bc84d2e69)
TERRAIN_DECORATION_TREE_MEMBER_MATERIAL_SALT :: u64(0xad25c8e73b96140f)
TERRAIN_DECORATION_TREE_CROWN_ACCENT_SALT :: u64(0x6e97310fb4c825da)
TERRAIN_DECORATION_TREE_ROOT_SEARCH_RADIUS_BLOCKS :: i32(6)
TERRAIN_DECORATION_TREE_ROOT_CORE_RADIUS_BLOCKS :: i32(1)
TERRAIN_DECORATION_TREE_ROOT_SLOPE_TOLERANCE_BLOCKS :: i32(3)
TERRAIN_DECORATION_TREE_SEGMENT_SHELL_RADIUS_BLOCKS :: i32(1)
TERRAIN_DECORATION_TREE_BRANCH_SHELL_TAPER_PERCENT :: i32(80)
TERRAIN_DECORATION_TREE_TRUNK_SHELL_TAPER_PERCENT :: i32(70)
TERRAIN_DECORATION_STAMP_MEMBER_SALT :: u64(0x2d4c8b7e61a5903f)
TERRAIN_DECORATION_STAMP_STEP_SALT :: u64(0x83e9d14f7c2056ab)
TERRAIN_DECORATION_STAMP_OFFSET_X_SALT :: u64(0x9a610fd34e7c28b5)
TERRAIN_DECORATION_STAMP_OFFSET_Z_SALT :: u64(0x41f6b9d82705eca3)
TERRAIN_DECORATION_STAMP_DIRECTION_SALT :: u64(0xc7a536e1b94d208f)
TERRAIN_DECORATION_SURFACE_STRUCTURE_RESERVATION_CAPACITY :: 128
TERRAIN_DECORATION_STRUCTURE_PAD_FALLOFF_BLOCKS :: f32(10)

//////////////////////////////////////
// Terrain Decoration Methods
/////////////////////////////////////

terrain_decoration_surface_structure_pads_apply :: proc(
	generation_region: ^biomes.GenerationRegion,
	chunk_origin: world_async.BlockCoord,
	columns: []TerrainBiomeColumn,
) {
	when !TERRAIN_DECORATION_ENABLED {
		_ = generation_region
		_ = chunk_origin
		_ = columns
		return
	}
	log.assertf(
		len(columns) == CHUNK_BLOCK_LENGTH * CHUNK_BLOCK_LENGTH,
		"terrain decoration pad column target count mismatch: %d",
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
	for i := u32(0); i < surface_feature_count; i += 1 {
		feature := surface_features[i]
		if !terrain_decoration_surface_family_is_structure(feature.family_id) {
			continue
		}
		terrain_decoration_surface_structure_pad_apply(
			generation_region.key,
			feature,
			chunk_origin,
			columns,
		)
	}
}

terrain_decoration_surface_structure_pad_apply :: proc(
	key: biomes.FeatureGridKey,
	feature: biomes.DecorationFeature,
	chunk_origin: world_async.BlockCoord,
	columns: []TerrainBiomeColumn,
) {
	center_world_x := i32(math.floor_f32(feature.x))
	center_world_z := i32(math.floor_f32(feature.z))
	center_column := terrain_decoration_surface_structure_reference_column(
		key,
		chunk_origin,
		columns,
		center_world_x,
		center_world_z,
	)
	if !terrain_decoration_surface_structure_column_allowed(feature, center_column) {
		return
	}

	pad_radius := f32(terrain_decoration_surface_structure_pad_radius(feature.family_id))
	pad_influence_radius := pad_radius + TERRAIN_DECORATION_STRUCTURE_PAD_FALLOFF_BLOCKS
	chunk_min_x := f32(chunk_origin.x)
	chunk_max_x := f32(chunk_origin.x + CHUNK_BLOCK_LENGTH - 1)
	chunk_min_z := f32(chunk_origin.z)
	chunk_max_z := f32(chunk_origin.z + CHUNK_BLOCK_LENGTH - 1)
	if feature.x + pad_influence_radius < chunk_min_x ||
	   feature.x - pad_influence_radius > chunk_max_x ||
	   feature.z + pad_influence_radius < chunk_min_z ||
	   feature.z - pad_influence_radius > chunk_max_z {
		return
	}

	target_height := center_column.surface_height_blocks
	for z in 0 ..< CHUNK_BLOCK_LENGTH {
		world_z := chunk_origin.z + i32(z)
		for x in 0 ..< CHUNK_BLOCK_LENGTH {
			world_x := chunk_origin.x + i32(x)
			dx := f32(world_x) + 0.5 - feature.x
			dz := f32(world_z) + 0.5 - feature.z
			distance := math.sqrt_f32(dx * dx + dz * dz)
			if distance > pad_influence_radius {
				continue
			}
			column_index := x + z * CHUNK_BLOCK_LENGTH
			column := &columns[column_index]
			if !terrain_decoration_surface_structure_column_allowed(feature, column^) {
				continue
			}
			influence := f32(1.0)
			if distance > pad_radius {
				influence = f32(1.0) - math.smoothstep(pad_radius, pad_influence_radius, distance)
			}
			if influence <= 0 {
				continue
			}
			column.surface_height_blocks = biomes.regional_terrain_field_lerp(
				column.surface_height_blocks,
				target_height,
				math.clamp(influence, f32(0), f32(1)),
			)
			column.surface_height = i32(math.floor_f32(column.surface_height_blocks))
			column.surface_morphology_profile.strength *= 1.0 - influence * 0.85
			column.surface_morphology_profile.heightfield_shape_strength *= 1.0 - influence * 0.80
			if column.surface_height_blocks >= column.water_level_blocks {
				column.water_fill_active = false
			}
		}
	}
}

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
	reservations: [TERRAIN_DECORATION_SURFACE_STRUCTURE_RESERVATION_CAPACITY]TerrainDecorationSurfaceReservation
	reservation_count: u32
	for i := u32(0); i < surface_feature_count; i += 1 {
		feature := surface_features[i]
		if !terrain_decoration_surface_family_is_structure(feature.family_id) {
			continue
		}
		terrain_decoration_stats_family_candidate_add(&stats, feature.family_id)
		if terrain_decoration_surface_feature_overlaps_reservations(
			feature,
			reservations[:reservation_count],
		) {
			continue
		}
		result := terrain_decoration_surface_feature_apply(
			view,
			generation_region.key,
			feature,
			chunk_origin,
			columns,
		)
		stats.surface_tree_instances_attempted += result.tree_instances_attempted
		stats.surface_tree_instances_accepted += result.tree_instances_accepted
		stats.surface_tree_root_rejected += result.tree_root_rejected
		stats.surface_tree_shape_rejected += result.tree_shape_rejected
		if result.blocks_written > 0 {
			accepted_count := result.tree_instances_accepted
			if accepted_count == 0 {
				accepted_count = 1
			}
			stats.surface_accepted += accepted_count
			stats.blocks_written += result.blocks_written
			terrain_decoration_stats_family_accepted_add_many(
				&stats,
				feature.family_id,
				result.blocks_written,
				accepted_count,
			)
			terrain_decoration_surface_reservation_add(
				reservations[:],
				&reservation_count,
				feature,
			)
		}
	}
	for i := u32(0); i < surface_feature_count; i += 1 {
		feature := surface_features[i]
		if terrain_decoration_surface_family_is_structure(feature.family_id) {
			continue
		}
		if terrain_decoration_surface_feature_overlaps_reservations(
			feature,
			reservations[:reservation_count],
		) {
			continue
		}
		terrain_decoration_stats_family_candidate_add(&stats, feature.family_id)
		result := terrain_decoration_surface_feature_apply(
			view,
			generation_region.key,
			feature,
			chunk_origin,
			columns,
		)
		stats.surface_tree_instances_attempted += result.tree_instances_attempted
		stats.surface_tree_instances_accepted += result.tree_instances_accepted
		stats.surface_tree_root_rejected += result.tree_root_rejected
		stats.surface_tree_shape_rejected += result.tree_shape_rejected
		if result.blocks_written > 0 {
			accepted_count := result.tree_instances_accepted
			if accepted_count == 0 {
				accepted_count = 1
			}
			stats.surface_accepted += accepted_count
			stats.blocks_written += result.blocks_written
			terrain_decoration_stats_family_accepted_add_many(
				&stats,
				feature.family_id,
				result.blocks_written,
				accepted_count,
			)
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
	key: biomes.FeatureGridKey,
	feature: biomes.DecorationFeature,
	chunk_origin: world_async.BlockCoord,
	columns: []TerrainBiomeColumn,
) -> TerrainDecorationSurfaceApplyResult {
	switch feature.family_id {
	case .Baseline_Tree, .Dead_Ash_Tree, .Stone_Tree:
		return terrain_decoration_tree_stand_apply(view, feature, chunk_origin, columns)
	case .Crystal_Growth_Cluster:
		local_x := i32(math.floor_f32(feature.x)) - chunk_origin.x
		local_z := i32(math.floor_f32(feature.z)) - chunk_origin.z
		base_y, found := terrain_decoration_surface_root_find(
			view,
			feature,
			chunk_origin.y,
			local_x,
			local_z,
			columns,
		)
		if !found {
			return {}
		}
		written := terrain_decoration_crystal_cluster_apply(
			view,
			local_x,
			base_y,
			local_z,
			feature.height_blocks,
			true,
		)
		return {blocks_written = written}
	case .Fern_Thicket,
	     .Ash_Bramble,
	     .Root_Cluster,
	     .Coral_DLA_Cluster,
	     .Ruin_Pillar_Set,
	     .Ruin_Hamlet,
	     .Watchtower_Ruin,
	     .Palisade_Fort,
	     .Cave_Ruin_Hall,
	     .Basalt_Column_Cluster,
	     .Lava_Vent:
		local_x := i32(math.floor_f32(feature.x)) - chunk_origin.x
		local_z := i32(math.floor_f32(feature.z)) - chunk_origin.z
		base_y: i32
		found: bool
		if terrain_decoration_surface_family_is_structure(feature.family_id) {
			local_x, base_y, local_z, found = terrain_decoration_surface_structure_anchor_prepare(
				view,
				key,
				feature,
				chunk_origin,
				local_x,
				local_z,
				columns,
			)
		} else {
			base_y, found = terrain_decoration_surface_root_find(
				view,
				feature,
				chunk_origin.y,
				local_x,
				local_z,
				columns,
			)
		}
		if !found {
			return {}
		}
		written := terrain_decoration_family_stamp_apply(
			view,
			feature.family_id,
			feature.biome_id,
			feature.id,
			feature.height_blocks,
			feature.radius_blocks,
			feature.material_variant,
			feature.shape_variant,
			feature.rotation_quarters,
			local_x,
			base_y,
			local_z,
			{surface = true, chunk_origin_y = chunk_origin.y, columns = columns},
		)
		return {blocks_written = written}
	case .Fungal_Tree:
		return {}
	}
	return {}
}

terrain_decoration_surface_root_find :: proc(
	view: ^world_async.ChunkVoxelView,
	feature: biomes.DecorationFeature,
	chunk_origin_y: i32,
	local_x, local_z: i32,
	columns: []TerrainBiomeColumn,
) -> (
	base_y: i32,
	found: bool,
) {
	if !terrain_decoration_local_xz_inside(
		local_x,
		local_z,
		TERRAIN_DECORATION_SURFACE_EDGE_MARGIN_BLOCKS,
	) {
		return
	}

	column := columns[local_x + local_z * CHUNK_BLOCK_LENGTH]
	base_y = column.surface_height - chunk_origin_y
	if base_y < 0 || base_y >= CHUNK_BLOCK_LOCAL_MAX {
		return
	}
	base_index := chunk_block_index(u32(local_x), u32(base_y), u32(local_z))
	if view.blocks.occupancy[base_index] != .Solid {
		return
	}
	if !terrain_decoration_surface_root_supports(
		feature,
		column,
		view.blocks.material_id[base_index],
	) {
		return
	}
	when TERRAIN_BAKE_DEBUG_MATERIAL_FLAGS {
		terrain_decoration_block_mark_debug(view, local_x, base_y, local_z)
	}
	found = true
	return
}

terrain_decoration_tree_root_search_may_enter_chunk :: proc(local_x, local_z: i32) -> bool {
	search_radius := TERRAIN_DECORATION_TREE_ROOT_SEARCH_RADIUS_BLOCKS
	return(
		local_x >= -search_radius &&
		local_z >= -search_radius &&
		local_x < CHUNK_BLOCK_LENGTH + search_radius &&
		local_z < CHUNK_BLOCK_LENGTH + search_radius \
	)
}

terrain_decoration_tree_root_candidate_find :: proc(
	view: ^world_async.ChunkVoxelView,
	feature: biomes.DecorationFeature,
	chunk_origin_y: i32,
	local_x, local_z: i32,
	columns: []TerrainBiomeColumn,
) -> (
	base_y: i32,
	found: bool,
) {
	if !terrain_decoration_local_xz_inside(
		local_x,
		local_z,
		TERRAIN_DECORATION_SURFACE_EDGE_MARGIN_BLOCKS,
	) {
		return
	}

	column := columns[local_x + local_z * CHUNK_BLOCK_LENGTH]
	base_y = column.surface_height - chunk_origin_y
	if base_y < 0 || base_y >= CHUNK_BLOCK_LOCAL_MAX {
		return
	}
	index := chunk_block_index(u32(local_x), u32(base_y), u32(local_z))
	if view.blocks.occupancy[index] != .Solid {
		return
	}
	if !terrain_decoration_surface_root_supports(feature, column, view.blocks.material_id[index]) {
		return
	}

	for dz := -TERRAIN_DECORATION_TREE_ROOT_CORE_RADIUS_BLOCKS;
	    dz <= TERRAIN_DECORATION_TREE_ROOT_CORE_RADIUS_BLOCKS;
	    dz += 1 {
		for dx := -TERRAIN_DECORATION_TREE_ROOT_CORE_RADIUS_BLOCKS;
		    dx <= TERRAIN_DECORATION_TREE_ROOT_CORE_RADIUS_BLOCKS;
		    dx += 1 {
			if !terrain_decoration_surface_structure_sample_suitable(
				view,
				feature,
				chunk_origin_y,
				local_x + dx,
				local_z + dz,
				base_y,
				columns,
				TERRAIN_DECORATION_TREE_ROOT_SLOPE_TOLERANCE_BLOCKS,
			) {
				return
			}
		}
	}

	found = true
	return
}

terrain_decoration_tree_root_find :: proc(
	view: ^world_async.ChunkVoxelView,
	feature: biomes.DecorationFeature,
	chunk_origin_y: i32,
	root_local_x, root_local_z: i32,
	columns: []TerrainBiomeColumn,
) -> (
	local_x: i32,
	base_y: i32,
	local_z: i32,
	found: bool,
) {
	if !terrain_decoration_tree_root_search_may_enter_chunk(root_local_x, root_local_z) {
		return
	}

	search_radius := TERRAIN_DECORATION_TREE_ROOT_SEARCH_RADIUS_BLOCKS
	for ring := i32(0); ring <= search_radius; ring += 1 {
		for dz := -ring; dz <= ring; dz += 1 {
			for dx := -ring; dx <= ring; dx += 1 {
				if ring != 0 && math.abs(dx) != ring && math.abs(dz) != ring {
					continue
				}
				candidate_x := root_local_x + dx
				candidate_z := root_local_z + dz
				candidate_base_y, candidate_found := terrain_decoration_tree_root_candidate_find(
					view,
					feature,
					chunk_origin_y,
					candidate_x,
					candidate_z,
					columns,
				)
				if candidate_found {
					when TERRAIN_BAKE_DEBUG_MATERIAL_FLAGS {
						terrain_decoration_block_mark_debug(
							view,
							candidate_x,
							candidate_base_y,
							candidate_z,
						)
					}
					return candidate_x, candidate_base_y, candidate_z, true
				}
			}
		}
	}

	return
}

terrain_decoration_surface_root_supports :: proc(
	feature: biomes.DecorationFeature,
	column: TerrainBiomeColumn,
	material_id: world_async.BlockMaterialID,
) -> bool {
	palette := terrain_material_palette_index(material_id)
	if palette == TERRAIN_WATER_MAT_ID {
		return false
	}
	if terrain_decoration_surface_column_is_water_covered(column) {
		return false
	}
	if terrain_decoration_surface_family_is_structure(feature.family_id) &&
	   !terrain_decoration_surface_structure_column_allowed(feature, column) {
		return false
	}
	switch feature.family_id {
	case .Baseline_Tree, .Dead_Ash_Tree, .Stone_Tree:
		if palette != TERRAIN_WET_MARSH_MAT_ID {
			return true
		}
		placement, found := biomes.decoration_surface_placement_profile_for_biome(feature.biome_id)
		if !found || !placement.wet_root_allowed {
			return false
		}
		clearance := column.surface_height_blocks - column.water_level_blocks
		return clearance >= f32(placement.min_root_water_clearance_blocks)
	case .Crystal_Growth_Cluster:
		return palette != TERRAIN_WET_MARSH_MAT_ID
	case .Fern_Thicket:
		return palette != TERRAIN_WATER_MAT_ID
	case .Ash_Bramble:
		return palette != TERRAIN_WATER_MAT_ID
	case .Root_Cluster:
		return palette != TERRAIN_WATER_MAT_ID
	case .Coral_DLA_Cluster:
		return(
			palette == TERRAIN_WET_MARSH_MAT_ID ||
			palette == TERRAIN_AQUIFER_WALL_MAT_ID ||
			palette == TERRAIN_STONE_MAT_ID \
		)
	case .Ruin_Pillar_Set:
		return palette != TERRAIN_WET_MARSH_MAT_ID
	case .Ruin_Hamlet:
		return palette != TERRAIN_WET_MARSH_MAT_ID
	case .Watchtower_Ruin:
		return palette != TERRAIN_WET_MARSH_MAT_ID
	case .Palisade_Fort:
		return(
			palette == TERRAIN_STONE_MAT_ID ||
			palette == TERRAIN_CORRUPTED_ASH_MAT_ID ||
			palette == TERRAIN_AQUIFER_WALL_MAT_ID \
		)
	case .Cave_Ruin_Hall:
		return false
	case .Basalt_Column_Cluster:
		return palette == TERRAIN_STONE_MAT_ID || palette == TERRAIN_CORRUPTED_ASH_MAT_ID
	case .Lava_Vent:
		return palette == TERRAIN_STONE_MAT_ID || palette == TERRAIN_CORRUPTED_ASH_MAT_ID
	case .Fungal_Tree:
		return false
	}
	return false
}

terrain_decoration_surface_column_is_water_covered :: proc(column: TerrainBiomeColumn) -> bool {
	return column.water_fill_active && column.surface_height_blocks < column.water_level_blocks
}

terrain_decoration_surface_family_is_structure :: proc(
	family_id: biomes.DecorationFamilyID,
) -> bool {
	switch family_id {
	case .Ruin_Pillar_Set, .Ruin_Hamlet, .Watchtower_Ruin, .Palisade_Fort:
		return true
	case .Baseline_Tree,
	     .Dead_Ash_Tree,
	     .Fungal_Tree,
	     .Stone_Tree,
	     .Crystal_Growth_Cluster,
	     .Fern_Thicket,
	     .Ash_Bramble,
	     .Root_Cluster,
	     .Coral_DLA_Cluster,
	     .Cave_Ruin_Hall,
	     .Basalt_Column_Cluster,
	     .Lava_Vent:
		return false
	}
	return false
}

terrain_decoration_surface_structure_family_allows_biome :: proc(
	family_id: biomes.DecorationFamilyID,
	biome_id: biomes.BiomeID,
) -> bool {
	switch family_id {
	case .Ruin_Hamlet, .Watchtower_Ruin:
		return(
			biome_id == .Temperate_Hills ||
			biome_id == .Old_Growth_Forest ||
			biome_id == .Wet_Lowland_Marsh \
		)
	case .Palisade_Fort:
		return(
			biome_id == .Corrupted_Ash_Forest ||
			biome_id == .Corrupted_Fen ||
			biome_id == .Basalt_Spire_Highlands ||
			biome_id == .Emberglass_Badlands \
		)
	case .Ruin_Pillar_Set:
		return true
	case .Baseline_Tree,
	     .Dead_Ash_Tree,
	     .Fungal_Tree,
	     .Stone_Tree,
	     .Crystal_Growth_Cluster,
	     .Fern_Thicket,
	     .Ash_Bramble,
	     .Root_Cluster,
	     .Coral_DLA_Cluster,
	     .Cave_Ruin_Hall,
	     .Basalt_Column_Cluster,
	     .Lava_Vent:
		return false
	}
	return false
}

terrain_decoration_surface_structure_column_allowed :: proc(
	feature: biomes.DecorationFeature,
	column: TerrainBiomeColumn,
) -> bool {
	if !terrain_decoration_surface_structure_family_allows_biome(
		feature.family_id,
		feature.biome_id,
	) {
		return false
	}
	if !terrain_decoration_surface_structure_family_allows_biome(
		feature.family_id,
		column.dominant_biome_id,
	) {
		return false
	}
	if terrain_decoration_surface_column_is_water_covered(column) {
		return false
	}
	return true
}

terrain_decoration_surface_structure_reference_column :: proc(
	key: biomes.FeatureGridKey,
	chunk_origin: world_async.BlockCoord,
	columns: []TerrainBiomeColumn,
	world_x, world_z: i32,
) -> TerrainBiomeColumn {
	local_x := world_x - chunk_origin.x
	local_z := world_z - chunk_origin.z
	if local_x >= 0 &&
	   local_z >= 0 &&
	   local_x < CHUNK_BLOCK_LENGTH &&
	   local_z < CHUNK_BLOCK_LENGTH &&
	   len(columns) == CHUNK_BLOCK_LENGTH * CHUNK_BLOCK_LENGTH {
		return columns[local_x + local_z * CHUNK_BLOCK_LENGTH]
	}
	return terrain_biome_column_sample_direct(key, world_x, world_z)
}

terrain_decoration_surface_structure_pad_radius :: proc(
	family_id: biomes.DecorationFamilyID,
) -> i32 {
	switch family_id {
	case .Ruin_Hamlet:
		return 25
	case .Watchtower_Ruin:
		return 23
	case .Palisade_Fort:
		return 26
	case .Ruin_Pillar_Set:
		return 11
	case .Baseline_Tree,
	     .Dead_Ash_Tree,
	     .Fungal_Tree,
	     .Stone_Tree,
	     .Crystal_Growth_Cluster,
	     .Fern_Thicket,
	     .Ash_Bramble,
	     .Root_Cluster,
	     .Coral_DLA_Cluster,
	     .Cave_Ruin_Hall,
	     .Basalt_Column_Cluster,
	     .Lava_Vent:
		return 0
	}
	return 0
}

terrain_decoration_surface_structure_anchor_prepare :: proc(
	view: ^world_async.ChunkVoxelView,
	key: biomes.FeatureGridKey,
	feature: biomes.DecorationFeature,
	chunk_origin: world_async.BlockCoord,
	root_local_x, root_local_z: i32,
	columns: []TerrainBiomeColumn,
) -> (
	local_x: i32,
	base_y: i32,
	local_z: i32,
	found: bool,
) {
	center_world_x := i32(math.floor_f32(feature.x))
	center_world_z := i32(math.floor_f32(feature.z))
	center_column := terrain_decoration_surface_structure_reference_column(
		key,
		chunk_origin,
		columns,
		center_world_x,
		center_world_z,
	)
	if !terrain_decoration_surface_structure_column_allowed(feature, center_column) {
		return root_local_x, 0, root_local_z, false
	}

	radius := terrain_decoration_surface_structure_footprint_radius(
		feature.family_id,
		feature.radius_blocks,
	)
	chunk_min_x := chunk_origin.x
	chunk_max_x := chunk_origin.x + CHUNK_BLOCK_LENGTH - 1
	chunk_min_z := chunk_origin.z
	chunk_max_z := chunk_origin.z + CHUNK_BLOCK_LENGTH - 1
	if center_world_x + radius < chunk_min_x ||
	   center_world_x - radius > chunk_max_x ||
	   center_world_z + radius < chunk_min_z ||
	   center_world_z - radius > chunk_max_z {
		return root_local_x, 0, root_local_z, false
	}

	if terrain_decoration_local_xz_inside(root_local_x, root_local_z, radius + 2) {
		_, _, _, center_valid := terrain_decoration_surface_structure_center_find(
			view,
			feature,
			chunk_origin.y,
			root_local_x,
			root_local_z,
			columns,
		)
		if !center_valid {
			return root_local_x, 0, root_local_z, false
		}
	}

	return root_local_x, center_column.surface_height - chunk_origin.y, root_local_z, true
}

terrain_decoration_surface_reservation_add :: proc(
	reservations: []TerrainDecorationSurfaceReservation,
	reservation_count: ^u32,
	feature: biomes.DecorationFeature,
) {
	if reservation_count^ >= u32(len(reservations)) {
		return
	}
	radius :=
		f32(
			terrain_decoration_surface_structure_footprint_radius(
				feature.family_id,
				feature.radius_blocks,
			),
		) +
		5
	reservations[reservation_count^] = {
		x             = feature.x,
		z             = feature.z,
		radius_blocks = radius,
		family_id     = feature.family_id,
	}
	reservation_count^ += 1
}

terrain_decoration_surface_feature_overlaps_reservations :: proc(
	feature: biomes.DecorationFeature,
	reservations: []TerrainDecorationSurfaceReservation,
) -> bool {
	if len(reservations) == 0 {
		return false
	}
	feature_radius := terrain_decoration_surface_feature_clearance_radius(feature)
	for reservation in reservations {
		dx := feature.x - reservation.x
		dz := feature.z - reservation.z
		clearance := feature_radius + reservation.radius_blocks
		if dx * dx + dz * dz <= clearance * clearance {
			return true
		}
	}
	return false
}

terrain_decoration_surface_feature_clearance_radius :: proc(
	feature: biomes.DecorationFeature,
) -> f32 {
	switch feature.family_id {
	case .Baseline_Tree, .Dead_Ash_Tree, .Stone_Tree:
		return f32(math.max(i32(feature.stand_radius_blocks), 10))
	case .Fern_Thicket, .Ash_Bramble, .Root_Cluster, .Coral_DLA_Cluster:
		return f32(math.max(i32(feature.radius_blocks), 6))
	case .Crystal_Growth_Cluster, .Basalt_Column_Cluster, .Lava_Vent:
		return f32(math.max(i32(feature.radius_blocks), 5))
	case .Ruin_Pillar_Set, .Ruin_Hamlet, .Watchtower_Ruin, .Palisade_Fort:
		return f32(
			terrain_decoration_surface_structure_footprint_radius(
				feature.family_id,
				feature.radius_blocks,
			),
		)
	case .Cave_Ruin_Hall, .Fungal_Tree:
		return f32(feature.radius_blocks)
	}
	return f32(feature.radius_blocks)
}

terrain_decoration_surface_structure_center_find :: proc(
	view: ^world_async.ChunkVoxelView,
	feature: biomes.DecorationFeature,
	chunk_origin_y: i32,
	root_local_x, root_local_z: i32,
	columns: []TerrainBiomeColumn,
) -> (
	local_x: i32,
	base_y: i32,
	local_z: i32,
	found: bool,
) {
	radius := terrain_decoration_surface_structure_footprint_radius(
		feature.family_id,
		feature.radius_blocks,
	)
	search_radius := math.max(radius / 2, 10)
	fallback_x := root_local_x
	fallback_z := root_local_z
	fallback_base_y := i32(0)
	fallback_found := false
	for ring := i32(0); ring <= search_radius; ring += 3 {
		for dz := -ring; dz <= ring; dz += 3 {
			for dx := -ring; dx <= ring; dx += 3 {
				if ring != 0 && math.abs(dx) != ring && math.abs(dz) != ring {
					continue
				}
				candidate_x := root_local_x + dx
				candidate_z := root_local_z + dz
				if !terrain_decoration_local_xz_inside(candidate_x, candidate_z, radius + 2) {
					continue
				}
				column := columns[candidate_x + candidate_z * CHUNK_BLOCK_LENGTH]
				candidate_base_y := column.surface_height - chunk_origin_y
				if candidate_base_y < 0 || candidate_base_y >= CHUNK_BLOCK_LOCAL_MAX {
					continue
				}
				index := chunk_block_index(
					u32(candidate_x),
					u32(candidate_base_y),
					u32(candidate_z),
				)
				if view.blocks.occupancy[index] != .Solid {
					continue
				}
				if !terrain_decoration_surface_root_supports(
					feature,
					column,
					view.blocks.material_id[index],
				) {
					continue
				}
				if !fallback_found &&
				   terrain_decoration_surface_structure_core_suitable(
					   view,
					   feature,
					   chunk_origin_y,
					   candidate_x,
					   candidate_base_y,
					   candidate_z,
					   columns,
				   ) {
					fallback_x = candidate_x
					fallback_z = candidate_z
					fallback_base_y = candidate_base_y
					fallback_found = true
				}
				if !terrain_decoration_surface_structure_footprint_suitable(
					view,
					feature,
					chunk_origin_y,
					candidate_x,
					candidate_base_y,
					candidate_z,
					columns,
				) {
					continue
				}
				return candidate_x, candidate_base_y, candidate_z, true
			}
		}
	}
	if fallback_found {
		return fallback_x, fallback_base_y, fallback_z, true
	}
	return root_local_x, 0, root_local_z, false
}

terrain_decoration_surface_structure_core_suitable :: proc(
	view: ^world_async.ChunkVoxelView,
	feature: biomes.DecorationFeature,
	chunk_origin_y: i32,
	local_x, base_y, local_z: i32,
	columns: []TerrainBiomeColumn,
) -> bool {
	core_radius := i32(2)
	tolerance := terrain_decoration_surface_structure_flatness_tolerance(feature.family_id)
	for dz := -core_radius; dz <= core_radius; dz += 1 {
		for dx := -core_radius; dx <= core_radius; dx += 1 {
			if !terrain_decoration_surface_structure_sample_suitable(
				view,
				feature,
				chunk_origin_y,
				local_x + dx,
				local_z + dz,
				base_y,
				columns,
				tolerance,
			) {
				return false
			}
		}
	}
	return true
}

terrain_decoration_surface_structure_footprint_radius :: proc(
	family_id: biomes.DecorationFamilyID,
	radius_blocks: u8,
) -> i32 {
	switch family_id {
	case .Ruin_Hamlet:
		return math.max(i32(radius_blocks), 24)
	case .Palisade_Fort:
		return math.max(i32(radius_blocks), 24)
	case .Watchtower_Ruin:
		return math.max(i32(radius_blocks), 22)
	case .Ruin_Pillar_Set:
		return math.max(i32(radius_blocks), 10)
	case .Baseline_Tree,
	     .Dead_Ash_Tree,
	     .Fungal_Tree,
	     .Stone_Tree,
	     .Crystal_Growth_Cluster,
	     .Fern_Thicket,
	     .Ash_Bramble,
	     .Root_Cluster,
	     .Coral_DLA_Cluster,
	     .Cave_Ruin_Hall,
	     .Basalt_Column_Cluster,
	     .Lava_Vent:
		return i32(radius_blocks)
	}
	return i32(radius_blocks)
}

terrain_decoration_surface_structure_flatness_tolerance :: proc(
	family_id: biomes.DecorationFamilyID,
) -> i32 {
	switch family_id {
	case .Ruin_Hamlet:
		return 1
	case .Palisade_Fort:
		return 1
	case .Watchtower_Ruin:
		return 1
	case .Ruin_Pillar_Set:
		return 2
	case .Baseline_Tree,
	     .Dead_Ash_Tree,
	     .Fungal_Tree,
	     .Stone_Tree,
	     .Crystal_Growth_Cluster,
	     .Fern_Thicket,
	     .Ash_Bramble,
	     .Root_Cluster,
	     .Coral_DLA_Cluster,
	     .Cave_Ruin_Hall,
	     .Basalt_Column_Cluster,
	     .Lava_Vent:
		return 0
	}
	return 0
}

terrain_decoration_surface_structure_sample_suitable :: proc(
	view: ^world_async.ChunkVoxelView,
	feature: biomes.DecorationFeature,
	chunk_origin_y: i32,
	local_x, local_z: i32,
	root_base_y: i32,
	columns: []TerrainBiomeColumn,
	tolerance: i32,
) -> bool {
	if !terrain_decoration_local_xz_inside(local_x, local_z, 1) {
		return false
	}
	column := columns[local_x + local_z * CHUNK_BLOCK_LENGTH]
	if terrain_decoration_surface_column_is_water_covered(column) {
		return false
	}
	base_y := column.surface_height - chunk_origin_y
	if base_y < 0 || base_y >= CHUNK_BLOCK_LOCAL_MAX {
		return false
	}
	if math.abs(base_y - root_base_y) > tolerance {
		return false
	}
	index := chunk_block_index(u32(local_x), u32(base_y), u32(local_z))
	if view.blocks.occupancy[index] != .Solid {
		return false
	}
	return terrain_decoration_surface_root_supports(
		feature,
		column,
		view.blocks.material_id[index],
	)
}

terrain_decoration_surface_structure_footprint_suitable :: proc(
	view: ^world_async.ChunkVoxelView,
	feature: biomes.DecorationFeature,
	chunk_origin_y: i32,
	local_x, base_y, local_z: i32,
	columns: []TerrainBiomeColumn,
) -> bool {
	radius := terrain_decoration_surface_structure_footprint_radius(
		feature.family_id,
		feature.radius_blocks,
	)
	if !terrain_decoration_local_xz_inside(local_x, local_z, radius + 2) {
		return false
	}
	tolerance := terrain_decoration_surface_structure_flatness_tolerance(feature.family_id)
	step := i32(1)
	for dz := -radius; dz <= radius; dz += step {
		for dx := -radius; dx <= radius; dx += step {
			if !terrain_decoration_surface_structure_sample_suitable(
				view,
				feature,
				chunk_origin_y,
				local_x + dx,
				local_z + dz,
				base_y,
				columns,
				tolerance,
			) {
				return false
			}
		}
	}

	corners := [?]biomes.IVec2 {
		{x = -radius, z = -radius},
		{x = radius, z = -radius},
		{x = -radius, z = radius},
		{x = radius, z = radius},
		{x = 0, z = 0},
	}
	for corner in corners {
		if !terrain_decoration_surface_structure_sample_suitable(
			view,
			feature,
			chunk_origin_y,
			local_x + corner.x,
			local_z + corner.z,
			base_y,
			columns,
			tolerance,
		) {
			return false
		}
	}
	return true
}

terrain_decoration_tree_stand_apply :: proc(
	view: ^world_async.ChunkVoxelView,
	feature: biomes.DecorationFeature,
	chunk_origin: world_async.BlockCoord,
	columns: []TerrainBiomeColumn,
) -> TerrainDecorationSurfaceApplyResult {
	result := TerrainDecorationSurfaceApplyResult{}
	root_x := i32(math.floor_f32(feature.x))
	root_z := i32(math.floor_f32(feature.z))
	stand_count := feature.stand_count
	if stand_count == 0 {
		stand_count = 1
	}

	for member_index := u8(0); member_index < stand_count; member_index += 1 {
		offset_x, offset_z := terrain_decoration_tree_member_offset(feature, member_index)
		local_x := root_x + offset_x - chunk_origin.x
		local_z := root_z + offset_z - chunk_origin.z
		if !terrain_decoration_tree_root_search_may_enter_chunk(local_x, local_z) {
			continue
		}
		result.tree_instances_attempted += 1

		base_x, base_y, base_z, root_found := terrain_decoration_tree_root_find(
			view,
			feature,
			chunk_origin.y,
			local_x,
			local_z,
			columns,
		)
		if !root_found {
			result.tree_root_rejected += 1
			continue
		}

		shape_variant := terrain_decoration_tree_member_shape_variant(feature, member_index)
		rotation := terrain_decoration_tree_member_rotation(feature, member_index)
		material_variant := terrain_decoration_tree_member_material_variant(feature, member_index)
		written := terrain_decoration_tree_apply(
			view,
			feature.family_id,
			feature.biome_id,
			shape_variant,
			rotation,
			material_variant,
			base_x,
			base_y,
			base_z,
		)
		if written == 0 {
			result.tree_shape_rejected += 1
			continue
		}
		result.tree_instances_accepted += 1
		result.blocks_written += written
	}
	return result
}

terrain_decoration_tree_member_hash :: proc(
	feature: biomes.DecorationFeature,
	member_index: u8,
	salt: u64,
) -> u64 {
	h := biomes.feature_grid_hash_combine(u64(feature.id), TERRAIN_DECORATION_TREE_MEMBER_SALT)
	h = biomes.feature_grid_hash_combine(h, u64(member_index))
	return biomes.feature_grid_hash_combine(h, salt)
}

terrain_decoration_tree_member_offset :: proc(
	feature: biomes.DecorationFeature,
	member_index: u8,
) -> (
	offset_x, offset_z: i32,
) {
	if member_index == 0 {
		return 0, 0
	}
	radius := i32(feature.stand_radius_blocks)
	if radius <= 0 {
		return 0, 0
	}
	hash := terrain_decoration_tree_member_hash(
		feature,
		member_index,
		TERRAIN_DECORATION_TREE_MEMBER_SALT,
	)
	angle_roll := biomes.feature_grid_unit_f32(hash, TERRAIN_DECORATION_TREE_MEMBER_OFFSET_X_SALT)
	distance_roll := biomes.feature_grid_unit_f32(
		hash,
		TERRAIN_DECORATION_TREE_MEMBER_OFFSET_Z_SALT,
	)
	angle := angle_roll * math.TAU
	min_distance_blocks := i32(3)
	if radius < 8 {
		min_distance_blocks = 2
	}
	min_distance := f32(min_distance_blocks)
	distance :=
		min_distance +
		math.sqrt_f32(distance_roll) * f32(math.max(radius - min_distance_blocks, 1))
	offset_x = i32(math.floor_f32(math.cos_f32(angle) * distance))
	offset_z = i32(math.floor_f32(math.sin_f32(angle) * distance))
	if offset_x == 0 && offset_z == 0 {
		offset_x = i32(member_index % 3) - 1
		offset_z = i32(member_index / 3) + 2
	}
	return
}

terrain_decoration_tree_member_shape_variant :: proc(
	feature: biomes.DecorationFeature,
	member_index: u8,
) -> u8 {
	if member_index == 0 {
		return feature.shape_variant
	}
	hash := terrain_decoration_tree_member_hash(
		feature,
		member_index,
		TERRAIN_DECORATION_TREE_MEMBER_VARIANT_SALT,
	)
	return biomes.decoration_tree_shape_variant_from_id(
		biomes.FeatureID(hash),
		feature.biome_id,
		feature.family_id,
	)
}

terrain_decoration_tree_member_rotation :: proc(
	feature: biomes.DecorationFeature,
	member_index: u8,
) -> u8 {
	if member_index == 0 {
		return feature.rotation_quarters
	}
	hash := terrain_decoration_tree_member_hash(
		feature,
		member_index,
		TERRAIN_DECORATION_TREE_MEMBER_ROTATION_SALT,
	)
	roll := biomes.feature_grid_unit_f32(hash, TERRAIN_DECORATION_TREE_MEMBER_ROTATION_SALT)
	rotation := u8(math.floor_f32(roll * 4.0))
	if rotation > 3 {
		rotation = 3
	}
	return rotation
}

terrain_decoration_tree_member_material_variant :: proc(
	feature: biomes.DecorationFeature,
	member_index: u8,
) -> u8 {
	if member_index == 0 {
		return feature.material_variant
	}
	hash := terrain_decoration_tree_member_hash(
		feature,
		member_index,
		TERRAIN_DECORATION_TREE_MEMBER_MATERIAL_SALT,
	)
	roll := biomes.feature_grid_unit_f32(hash, TERRAIN_DECORATION_TREE_MEMBER_MATERIAL_SALT)
	variant := u8(math.floor_f32(roll * 8.0))
	if variant > 7 {
		variant = 7
	}
	return variant
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
		base_y, found_floor := terrain_decoration_cave_floor_find(
			view,
			local_x,
			local_z,
			search_top,
			search_bottom,
		)
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
	if !terrain_decoration_local_xz_inside(
		local_x,
		local_z,
		TERRAIN_DECORATION_CAVE_EDGE_MARGIN_BLOCKS,
	) {
		return 0
	}

	search_extra := TERRAIN_DECORATION_CAVE_FLOOR_SEARCH_EXTRA_BLOCKS
	radius := i32(math.ceil_f32(node.radius_blocks))
	search_top := math.min(local_y + radius / 2, CHUNK_BLOCK_LOCAL_MAX - 1)
	search_bottom := math.max(local_y - radius - search_extra, 1)
	base_y, found_floor := terrain_decoration_cave_floor_find(
		view,
		local_x,
		local_z,
		search_top,
		search_bottom,
	)
	if !found_floor {
		local_x, base_y, local_z, found_floor = terrain_decoration_cave_floor_find_nearby(
			view,
			local_x,
			local_z,
			search_top,
			search_bottom,
			radius,
		)
		if !found_floor {
			return 0
		}
	}

	profile := biomes.decoration_family_profile_for(family_id)
	height := biomes.decoration_feature_height_from_id(node.id, profile)
	switch family_id {
	case .Fungal_Tree:
		return terrain_decoration_tree_apply(
			view,
			family_id,
			node.biome_id,
			biomes.decoration_tree_shape_variant_from_id(node.id, node.biome_id, family_id),
			biomes.decoration_tree_rotation_from_id(node.id),
			biomes.decoration_material_variant_from_id(node.id),
			local_x,
			base_y,
			local_z,
		)
	case .Crystal_Growth_Cluster:
		return terrain_decoration_crystal_cluster_apply(
			view,
			local_x,
			base_y,
			local_z,
			height,
			false,
		)
	case .Root_Cluster,
	     .Coral_DLA_Cluster,
	     .Ash_Bramble,
	     .Ruin_Pillar_Set,
	     .Ruin_Hamlet,
	     .Watchtower_Ruin,
	     .Palisade_Fort,
	     .Cave_Ruin_Hall,
	     .Basalt_Column_Cluster,
	     .Lava_Vent,
	     .Fern_Thicket:
		return terrain_decoration_family_stamp_apply(
			view,
			family_id,
			node.biome_id,
			node.id,
			height,
			profile.radius_blocks,
			biomes.decoration_material_variant_from_id(node.id),
			biomes.decoration_tree_shape_variant_from_id(node.id, node.biome_id, family_id),
			biomes.decoration_tree_rotation_from_id(node.id),
			local_x,
			base_y,
			local_z,
			{},
		)
	case .Baseline_Tree, .Dead_Ash_Tree, .Stone_Tree:
		return 0
	}
	return 0
}

terrain_decoration_tree_apply :: proc(
	view: ^world_async.ChunkVoxelView,
	family_id: biomes.DecorationFamilyID,
	biome_id: biomes.BiomeID,
	shape_variant: u8,
	rotation_quarters: u8,
	material_variant: u8,
	local_x, base_y, local_z: i32,
) -> u32 {
	shape := biomes.decoration_tree_shape_for(biome_id, family_id, shape_variant)
	if shape.segment_count == 0 {
		return 0
	}
	if !terrain_decoration_tree_shape_can_place(
		view,
		shape,
		rotation_quarters,
		local_x,
		base_y,
		local_z,
	) {
		return terrain_decoration_tree_compact_apply(
			view,
			shape,
			family_id,
			biome_id,
			material_variant,
			local_x,
			base_y,
			local_z,
		)
	}

	materials := terrain_decoration_tree_materials_for(family_id, biome_id, material_variant)
	return terrain_decoration_tree_shape_write(
		view,
		shape,
		rotation_quarters,
		material_variant,
		local_x,
		base_y,
		local_z,
		materials,
	)
}

terrain_decoration_tree_compact_apply :: proc(
	view: ^world_async.ChunkVoxelView,
	shape: biomes.DecorationTreeShape,
	family_id: biomes.DecorationFamilyID,
	biome_id: biomes.BiomeID,
	material_variant: u8,
	local_x, base_y, local_z: i32,
) -> u32 {
	available_height := CHUNK_BLOCK_LOCAL_MAX - base_y
	if available_height < 6 {
		return 0
	}

	trunk_height := math.min(i32(shape.height_blocks), i32(7))
	trunk_height = math.min(trunk_height, available_height - 3)
	if trunk_height < 4 {
		return 0
	}
	crown_radius := i32(2)
	if trunk_height >= 6 {
		crown_radius = 3
	}
	crown_y := trunk_height + 1
	crown := biomes.DecorationTreeCrown {
		center = {x = 0, y = crown_y, z = 0},
		radius_xz = u8(crown_radius),
		radius_y = 1,
	}

	for y := i32(1); y <= trunk_height; y += 1 {
		if !terrain_decoration_tree_offset_can_place(
			view,
			{x = 0, y = y, z = 0},
			local_x,
			base_y,
			local_z,
		) {
			return 0
		}
	}
	for dz := -crown_radius; dz <= crown_radius; dz += 1 {
		for dx := -crown_radius; dx <= crown_radius; dx += 1 {
			for dy := -i32(crown.radius_y); dy <= i32(crown.radius_y); dy += 1 {
				if !terrain_decoration_tree_crown_contains(dx, dy, dz, crown) {
					continue
				}
				if !terrain_decoration_tree_offset_can_place(
					view,
					{x = dx, y = crown_y + dy, z = dz},
					local_x,
					base_y,
					local_z,
				) {
					return 0
				}
			}
		}
	}

	materials := terrain_decoration_tree_materials_for(family_id, biome_id, material_variant)
	written: u32
	for y := i32(1); y <= trunk_height; y += 1 {
		if terrain_decoration_tree_offset_write(
			view,
			{x = 0, y = y, z = 0},
			local_x,
			base_y,
			local_z,
			materials.trunk,
		) {
			written += 1
		}
	}
	for dz := -crown_radius; dz <= crown_radius; dz += 1 {
		for dx := -crown_radius; dx <= crown_radius; dx += 1 {
			for dy := -i32(crown.radius_y); dy <= i32(crown.radius_y); dy += 1 {
				if !terrain_decoration_tree_crown_contains(dx, dy, dz, crown) {
					continue
				}
				offset := biomes.IVec3 {
					x = dx,
					y = crown_y + dy,
					z = dz,
				}
				material := terrain_decoration_tree_crown_material(
					materials,
					material_variant,
					offset,
				)
				if terrain_decoration_tree_offset_write(
					view,
					offset,
					local_x,
					base_y,
					local_z,
					material,
				) {
					written += 1
				}
			}
		}
	}
	return written
}

terrain_decoration_tree_shape_can_place :: proc(
	view: ^world_async.ChunkVoxelView,
	shape: biomes.DecorationTreeShape,
	rotation_quarters: u8,
	local_x, base_y, local_z: i32,
) -> bool {
	for i := u8(0); i < shape.segment_count; i += 1 {
		if !terrain_decoration_tree_segment_can_place(
			view,
			shape.segments[i],
			rotation_quarters,
			local_x,
			base_y,
			local_z,
		) {
			return false
		}
	}
	for i := u8(0); i < shape.crown_count; i += 1 {
		if !terrain_decoration_tree_crown_can_place(
			view,
			shape.crowns[i],
			rotation_quarters,
			local_x,
			base_y,
			local_z,
		) {
			return false
		}
	}
	return true
}

terrain_decoration_tree_shape_write :: proc(
	view: ^world_async.ChunkVoxelView,
	shape: biomes.DecorationTreeShape,
	rotation_quarters: u8,
	material_variant: u8,
	local_x, base_y, local_z: i32,
	materials: TerrainDecorationTreeMaterials,
) -> u32 {
	written: u32
	for i := u8(0); i < shape.segment_count; i += 1 {
		written += terrain_decoration_tree_segment_write(
			view,
			shape.segments[i],
			rotation_quarters,
			local_x,
			base_y,
			local_z,
			materials,
		)
	}
	for i := u8(0); i < shape.crown_count; i += 1 {
		written += terrain_decoration_tree_crown_write(
			view,
			shape.crowns[i],
			rotation_quarters,
			material_variant,
			local_x,
			base_y,
			local_z,
			materials,
		)
	}
	for i := u8(0); i < shape.segment_count; i += 1 {
		written += terrain_decoration_tree_segment_shell_write(
			view,
			shape,
			shape.segments[i],
			rotation_quarters,
			local_x,
			base_y,
			local_z,
			materials,
		)
	}
	return written
}

terrain_decoration_tree_segment_can_place :: proc(
	view: ^world_async.ChunkVoxelView,
	segment: biomes.DecorationTreeSegment,
	rotation_quarters: u8,
	local_x, base_y, local_z: i32,
) -> bool {
	from := terrain_decoration_shape_offset_rotate(segment.from, rotation_quarters)
	to := terrain_decoration_shape_offset_rotate(segment.to, rotation_quarters)
	dx := to.x - from.x
	dy := to.y - from.y
	dz := to.z - from.z
	steps := math.max(math.max(math.abs(dx), math.abs(dy)), math.abs(dz))
	if steps == 0 {
		return terrain_decoration_tree_offset_can_place(view, from, local_x, base_y, local_z)
	}
	for step := i32(0); step <= steps; step += 1 {
		offset := biomes.IVec3 {
			x = from.x + dx * step / steps,
			y = from.y + dy * step / steps,
			z = from.z + dz * step / steps,
		}
		if !terrain_decoration_tree_offset_can_place(view, offset, local_x, base_y, local_z) {
			return false
		}
	}
	return true
}

terrain_decoration_tree_segment_write :: proc(
	view: ^world_async.ChunkVoxelView,
	segment: biomes.DecorationTreeSegment,
	rotation_quarters: u8,
	local_x, base_y, local_z: i32,
	materials: TerrainDecorationTreeMaterials,
) -> u32 {
	from := terrain_decoration_shape_offset_rotate(segment.from, rotation_quarters)
	to := terrain_decoration_shape_offset_rotate(segment.to, rotation_quarters)
	dx := to.x - from.x
	dy := to.y - from.y
	dz := to.z - from.z
	steps := math.max(math.max(math.abs(dx), math.abs(dy)), math.abs(dz))
	material := terrain_decoration_tree_role_material(segment.role, materials)
	written: u32
	if steps == 0 {
		if terrain_decoration_tree_offset_write(view, from, local_x, base_y, local_z, material) {
			written += 1
		}
		return written
	}
	for step := i32(0); step <= steps; step += 1 {
		offset := biomes.IVec3 {
			x = from.x + dx * step / steps,
			y = from.y + dy * step / steps,
			z = from.z + dz * step / steps,
		}
		if terrain_decoration_tree_offset_write(view, offset, local_x, base_y, local_z, material) {
			written += 1
		}
	}
	return written
}

terrain_decoration_tree_segment_shell_write :: proc(
	view: ^world_async.ChunkVoxelView,
	shape: biomes.DecorationTreeShape,
	segment: biomes.DecorationTreeSegment,
	rotation_quarters: u8,
	local_x, base_y, local_z: i32,
	materials: TerrainDecorationTreeMaterials,
) -> u32 {
	from := segment.from
	to := segment.to
	dx := to.x - from.x
	dy := to.y - from.y
	dz := to.z - from.z
	steps := math.max(math.max(math.abs(dx), math.abs(dy)), math.abs(dz))
	if steps == 0 {
		return 0
	}
	material := terrain_decoration_tree_role_material(segment.role, materials)
	written: u32
	for step := i32(0); step <= steps; step += 1 {
		radius := terrain_decoration_tree_segment_shell_radius(segment, dx, dz, step, steps)
		if radius <= 0 {
			continue
		}
		offset := biomes.IVec3 {
			x = from.x + dx * step / steps,
			y = from.y + dy * step / steps,
			z = from.z + dz * step / steps,
		}
		for shell_dy := -radius; shell_dy <= radius; shell_dy += 1 {
			for shell_dz := -radius; shell_dz <= radius; shell_dz += 1 {
				for shell_dx := -radius; shell_dx <= radius; shell_dx += 1 {
					if shell_dx == 0 && shell_dy == 0 && shell_dz == 0 {
						continue
					}
					if math.abs(shell_dx) + math.abs(shell_dy) + math.abs(shell_dz) > radius {
						continue
					}
					shell_offset := biomes.IVec3 {
						x = offset.x + shell_dx,
						y = offset.y + shell_dy,
						z = offset.z + shell_dz,
					}
					if !terrain_decoration_tree_offset_inside_shape_bounds(shell_offset, shape) {
						continue
					}
					rotated_offset := terrain_decoration_shape_offset_rotate(
						shell_offset,
						rotation_quarters,
					)
					if terrain_decoration_tree_offset_write(
						view,
						rotated_offset,
						local_x,
						base_y,
						local_z,
						material,
					) {
						written += 1
					}
				}
			}
		}
	}
	return written
}

terrain_decoration_tree_segment_shell_radius :: proc(
	segment: biomes.DecorationTreeSegment,
	dx, dz: i32,
	step, steps: i32,
) -> i32 {
	if steps <= 0 {
		return 0
	}
	switch segment.role {
	case .Branch:
		if step * 100 <= steps * TERRAIN_DECORATION_TREE_BRANCH_SHELL_TAPER_PERCENT {
			return TERRAIN_DECORATION_TREE_SEGMENT_SHELL_RADIUS_BLOCKS
		}
	case .Trunk:
		if dx != 0 || dz != 0 {
			if step * 100 <= steps * TERRAIN_DECORATION_TREE_BRANCH_SHELL_TAPER_PERCENT {
				return TERRAIN_DECORATION_TREE_SEGMENT_SHELL_RADIUS_BLOCKS
			}
			return 0
		}
		if step * 100 <= steps * TERRAIN_DECORATION_TREE_TRUNK_SHELL_TAPER_PERCENT {
			return TERRAIN_DECORATION_TREE_SEGMENT_SHELL_RADIUS_BLOCKS
		}
	case .Cap:
	}
	return 0
}

terrain_decoration_tree_offset_inside_shape_bounds :: proc(
	offset: biomes.IVec3,
	shape: biomes.DecorationTreeShape,
) -> bool {
	return(
		offset.x >= shape.min_bound.x &&
		offset.y >= shape.min_bound.y &&
		offset.z >= shape.min_bound.z &&
		offset.x <= shape.max_bound.x &&
		offset.y <= shape.max_bound.y &&
		offset.z <= shape.max_bound.z \
	)
}

terrain_decoration_tree_crown_can_place :: proc(
	view: ^world_async.ChunkVoxelView,
	crown: biomes.DecorationTreeCrown,
	rotation_quarters: u8,
	local_x, base_y, local_z: i32,
) -> bool {
	radius_xz := i32(crown.radius_xz)
	radius_y := i32(crown.radius_y)
	for dz := -radius_xz; dz <= radius_xz; dz += 1 {
		for dx := -radius_xz; dx <= radius_xz; dx += 1 {
			for dy := -radius_y; dy <= radius_y; dy += 1 {
				if !terrain_decoration_tree_crown_contains(dx, dy, dz, crown) {
					continue
				}
				offset := terrain_decoration_shape_offset_rotate(
					{x = crown.center.x + dx, y = crown.center.y + dy, z = crown.center.z + dz},
					rotation_quarters,
				)
				if !terrain_decoration_tree_offset_can_place(
					view,
					offset,
					local_x,
					base_y,
					local_z,
				) {
					return false
				}
			}
		}
	}
	return true
}

terrain_decoration_tree_crown_write :: proc(
	view: ^world_async.ChunkVoxelView,
	crown: biomes.DecorationTreeCrown,
	rotation_quarters: u8,
	material_variant: u8,
	local_x, base_y, local_z: i32,
	materials: TerrainDecorationTreeMaterials,
) -> u32 {
	radius_xz := i32(crown.radius_xz)
	radius_y := i32(crown.radius_y)
	written: u32
	for dz := -radius_xz; dz <= radius_xz; dz += 1 {
		for dx := -radius_xz; dx <= radius_xz; dx += 1 {
			for dy := -radius_y; dy <= radius_y; dy += 1 {
				if !terrain_decoration_tree_crown_contains(dx, dy, dz, crown) {
					continue
				}
				offset := terrain_decoration_shape_offset_rotate(
					{x = crown.center.x + dx, y = crown.center.y + dy, z = crown.center.z + dz},
					rotation_quarters,
				)
				material := terrain_decoration_tree_crown_material(
					materials,
					material_variant,
					offset,
				)
				if terrain_decoration_tree_offset_write(
					view,
					offset,
					local_x,
					base_y,
					local_z,
					material,
				) {
					written += 1
				}
			}
		}
	}
	return written
}

terrain_decoration_tree_crown_contains :: proc(
	dx, dy, dz: i32,
	crown: biomes.DecorationTreeCrown,
) -> bool {
	radius_xz := i32(crown.radius_xz)
	radius_y := i32(crown.radius_y)
	horizontal := math.abs(dx) + math.abs(dz)
	vertical := math.abs(dy)
	return horizontal <= radius_xz + 1 && horizontal + vertical * 2 <= radius_xz + radius_y + 1
}

terrain_decoration_shape_offset_rotate :: proc(
	offset: biomes.IVec3,
	rotation_quarters: u8,
) -> biomes.IVec3 {
	switch rotation_quarters & 3 {
	case 0:
		return offset
	case 1:
		return {x = -offset.z, y = offset.y, z = offset.x}
	case 2:
		return {x = -offset.x, y = offset.y, z = -offset.z}
	case:
		return {x = offset.z, y = offset.y, z = -offset.x}
	}
}

terrain_decoration_structure_offset_rotate :: proc(
	dx, dz: i32,
	rotation_quarters: u8,
) -> (
	rotated_dx: i32,
	rotated_dz: i32,
) {
	rotated := terrain_decoration_shape_offset_rotate({x = dx, y = 0, z = dz}, rotation_quarters)
	return rotated.x, rotated.z
}

terrain_decoration_grounded_column_write_rotated :: proc(
	view: ^world_async.ChunkVoxelView,
	ctx: TerrainDecorationStampContext,
	local_x, base_y, local_z: i32,
	dx, dz: i32,
	rotation_quarters: u8,
	height: i32,
	max_delta: i32,
	primary, cap: world_async.BlockMaterialID,
) -> u32 {
	rotated_dx, rotated_dz := terrain_decoration_structure_offset_rotate(dx, dz, rotation_quarters)
	return terrain_decoration_grounded_column_write(
		view,
		ctx,
		local_x + rotated_dx,
		base_y,
		local_z + rotated_dz,
		height,
		max_delta,
		primary,
		cap,
	)
}

terrain_decoration_ground_cover_write_rotated :: proc(
	view: ^world_async.ChunkVoxelView,
	ctx: TerrainDecorationStampContext,
	local_x, base_y, local_z: i32,
	dx, dz: i32,
	rotation_quarters: u8,
	max_delta: i32,
	material: world_async.BlockMaterialID,
) -> u32 {
	rotated_dx, rotated_dz := terrain_decoration_structure_offset_rotate(dx, dz, rotation_quarters)
	return terrain_decoration_ground_cover_write(
		view,
		ctx,
		local_x + rotated_dx,
		base_y,
		local_z + rotated_dz,
		max_delta,
		material,
	)
}

terrain_decoration_tree_offset_can_place :: proc(
	view: ^world_async.ChunkVoxelView,
	offset: biomes.IVec3,
	local_x, base_y, local_z: i32,
) -> bool {
	x := local_x + offset.x
	y := base_y + offset.y
	z := local_z + offset.z
	if !chunk_block_coord_is_inside(x, y, z) {
		return false
	}
	return terrain_decoration_block_is_empty(view, x, y, z)
}

terrain_decoration_tree_offset_write :: proc(
	view: ^world_async.ChunkVoxelView,
	offset: biomes.IVec3,
	local_x, base_y, local_z: i32,
	material: world_async.BlockMaterialID,
) -> bool {
	return terrain_decoration_block_try_write(
		view,
		local_x + offset.x,
		base_y + offset.y,
		local_z + offset.z,
		material,
	)
}

terrain_decoration_tree_role_material :: proc(
	role: biomes.DecorationTreeBlockRole,
	materials: TerrainDecorationTreeMaterials,
) -> world_async.BlockMaterialID {
	switch role {
	case .Trunk:
		return materials.trunk
	case .Branch:
		return materials.branch
	case .Cap:
		return materials.cap
	}
	return materials.trunk
}

terrain_decoration_tree_crown_material :: proc(
	materials: TerrainDecorationTreeMaterials,
	material_variant: u8,
	offset: biomes.IVec3,
) -> world_async.BlockMaterialID {
	if materials.cap_accent_chance <= 0 || materials.cap_accent == materials.cap {
		return materials.cap
	}
	h := biomes.feature_grid_hash_combine(
		u64(material_variant),
		TERRAIN_DECORATION_TREE_CROWN_ACCENT_SALT,
	)
	h = biomes.feature_grid_hash_combine(h, biomes.feature_grid_hash_i32(offset.x))
	h = biomes.feature_grid_hash_combine(h, biomes.feature_grid_hash_i32(offset.y))
	h = biomes.feature_grid_hash_combine(h, biomes.feature_grid_hash_i32(offset.z))
	accent_roll := biomes.feature_grid_unit_f32(h, TERRAIN_DECORATION_TREE_CROWN_ACCENT_SALT)
	if accent_roll < materials.cap_accent_chance {
		return materials.cap_accent
	}
	return materials.cap
}

terrain_decoration_tree_materials_for :: proc(
	family_id: biomes.DecorationFamilyID,
	biome_id: biomes.BiomeID,
	material_variant: u8,
) -> TerrainDecorationTreeMaterials {
	profile := biomes.decoration_family_profile_for(family_id)
	trunk := terrain_block_material_id_from_biome_material(profile.trunk_material)
	cap := terrain_block_material_id_from_biome_material(profile.cap_material)
	materials := TerrainDecorationTreeMaterials {
		trunk             = trunk,
		branch            = trunk,
		cap               = cap,
		cap_accent        = cap,
		cap_accent_chance = 0,
	}
	switch family_id {
	case .Baseline_Tree:
		materials.branch = terrain_block_material_id_from_biome_material(.Dirt)
		materials.cap = terrain_block_material_id_from_biome_material(.Grass)
		materials.cap_accent = terrain_block_material_id_from_biome_material(.Aquifer_Wall)
		materials.cap_accent_chance = 0.10
		if biome_id == .Old_Growth_Forest {
			materials.trunk = terrain_block_material_id_from_biome_material(.Forest_Litter)
			materials.branch = terrain_block_material_id_from_biome_material(.Dirt)
			materials.cap = terrain_block_material_id_from_biome_material(.Moss)
			materials.cap_accent = terrain_block_material_id_from_biome_material(.Grass)
			materials.cap_accent_chance = 0.18
		}
		if biome_id == .Wet_Lowland_Marsh && (material_variant & 1) != 0 {
			materials.trunk = terrain_block_material_id_from_biome_material(.Wet_Marsh)
			materials.branch = terrain_block_material_id_from_biome_material(.Dirt)
			materials.cap_accent_chance = 0.16
		}
	case .Dead_Ash_Tree:
		materials.trunk = terrain_block_material_id_from_biome_material(.Corrupted_Ash)
		materials.branch = terrain_block_material_id_from_biome_material(.Stone)
		if (material_variant & 1) == 0 {
			materials.branch = terrain_block_material_id_from_biome_material(.Corrupted_Ash)
		}
		materials.cap = terrain_block_material_id_from_biome_material(.Stone)
		materials.cap_accent = terrain_block_material_id_from_biome_material(.Corrupted_Ash)
		materials.cap_accent_chance = 0.34
		if biome_id == .Corrupted_Fen {
			materials.trunk = terrain_block_material_id_from_biome_material(.Corrupt_Mud)
			materials.cap_accent_chance = 0.42
		}
	case .Stone_Tree:
		materials.trunk = terrain_block_material_id_from_biome_material(.Stone)
		materials.branch = terrain_block_material_id_from_biome_material(.Aquifer_Wall)
		if (material_variant & 1) == 0 {
			materials.branch = terrain_block_material_id_from_biome_material(.Stone)
		}
		materials.cap = terrain_block_material_id_from_biome_material(.Crystal)
		materials.cap_accent = terrain_block_material_id_from_biome_material(.Stone)
		materials.cap_accent_chance = 0.22
		if biome_id == .Emberglass_Badlands {
			materials.trunk = terrain_block_material_id_from_biome_material(.Basalt)
			materials.branch = terrain_block_material_id_from_biome_material(.Ember_Ash)
			materials.cap = terrain_block_material_id_from_biome_material(.Lava)
			materials.cap_accent = terrain_block_material_id_from_biome_material(.Crystal)
			materials.cap_accent_chance = 0.16
		}
	case .Fungal_Tree:
		materials.trunk = terrain_block_material_id_from_biome_material(.Dirt)
		materials.branch = terrain_block_material_id_from_biome_material(.Wet_Marsh)
		materials.cap = terrain_block_material_id_from_biome_material(.Wet_Marsh)
		materials.cap_accent = terrain_block_material_id_from_biome_material(.Crystal)
		materials.cap_accent_chance = 0.08
	case .Crystal_Growth_Cluster,
	     .Fern_Thicket,
	     .Ash_Bramble,
	     .Root_Cluster,
	     .Coral_DLA_Cluster,
	     .Ruin_Pillar_Set,
	     .Ruin_Hamlet,
	     .Watchtower_Ruin,
	     .Palisade_Fort,
	     .Cave_Ruin_Hall,
	     .Basalt_Column_Cluster,
	     .Lava_Vent:
	}
	return materials
}

terrain_decoration_family_stamp_apply :: proc(
	view: ^world_async.ChunkVoxelView,
	family_id: biomes.DecorationFamilyID,
	biome_id: biomes.BiomeID,
	id: biomes.FeatureID,
	height_blocks, radius_blocks, material_variant, shape_variant, rotation_quarters: u8,
	local_x, base_y, local_z: i32,
	ctx: TerrainDecorationStampContext,
) -> u32 {
	switch family_id {
	case .Fern_Thicket:
		return terrain_decoration_lsystem_thicket_apply(
			view,
			biome_id,
			id,
			height_blocks,
			radius_blocks,
			material_variant,
			local_x,
			base_y,
			local_z,
			ctx,
		)
	case .Ash_Bramble, .Root_Cluster, .Coral_DLA_Cluster:
		return terrain_decoration_dla_cluster_apply(
			view,
			family_id,
			biome_id,
			id,
			height_blocks,
			radius_blocks,
			material_variant,
			local_x,
			base_y,
			local_z,
		)
	case .Ruin_Pillar_Set:
		return terrain_decoration_wfc_ruin_apply(
			view,
			biome_id,
			id,
			height_blocks,
			radius_blocks,
			material_variant,
			shape_variant,
			rotation_quarters,
			local_x,
			base_y,
			local_z,
			ctx,
		)
	case .Ruin_Hamlet:
		return terrain_decoration_ruin_hamlet_apply(
			view,
			biome_id,
			id,
			height_blocks,
			radius_blocks,
			material_variant,
			shape_variant,
			rotation_quarters,
			local_x,
			base_y,
			local_z,
			ctx,
		)
	case .Watchtower_Ruin:
		return terrain_decoration_watchtower_ruin_apply(
			view,
			biome_id,
			id,
			height_blocks,
			radius_blocks,
			material_variant,
			shape_variant,
			rotation_quarters,
			local_x,
			base_y,
			local_z,
			ctx,
		)
	case .Palisade_Fort:
		return terrain_decoration_palisade_fort_apply(
			view,
			biome_id,
			id,
			height_blocks,
			radius_blocks,
			material_variant,
			shape_variant,
			rotation_quarters,
			local_x,
			base_y,
			local_z,
			ctx,
		)
	case .Cave_Ruin_Hall:
		return terrain_decoration_cave_ruin_hall_apply(
			view,
			biome_id,
			id,
			height_blocks,
			radius_blocks,
			material_variant,
			shape_variant,
			rotation_quarters,
			local_x,
			base_y,
			local_z,
			ctx,
		)
	case .Basalt_Column_Cluster:
		return terrain_decoration_cellular_columns_apply(
			view,
			biome_id,
			id,
			height_blocks,
			radius_blocks,
			material_variant,
			local_x,
			base_y,
			local_z,
			ctx,
		)
	case .Lava_Vent:
		return terrain_decoration_lava_vent_apply(
			view,
			biome_id,
			id,
			height_blocks,
			radius_blocks,
			material_variant,
			local_x,
			base_y,
			local_z,
			ctx,
		)
	case .Crystal_Growth_Cluster:
		return terrain_decoration_crystal_cluster_apply(
			view,
			local_x,
			base_y,
			local_z,
			height_blocks,
			ctx.surface,
		)
	case .Baseline_Tree, .Dead_Ash_Tree, .Fungal_Tree, .Stone_Tree:
		return 0
	}
	return 0
}

terrain_decoration_stamp_hash :: proc(
	id: biomes.FeatureID,
	member_index: u32,
	step_index: u32,
	salt: u64,
) -> u64 {
	h := biomes.feature_grid_hash_combine(u64(id), TERRAIN_DECORATION_STAMP_MEMBER_SALT)
	h = biomes.feature_grid_hash_combine(h, u64(member_index))
	h = biomes.feature_grid_hash_combine(h, u64(step_index))
	return biomes.feature_grid_hash_combine(h, salt)
}

terrain_decoration_stamp_materials_for :: proc(
	family_id: biomes.DecorationFamilyID,
	biome_id: biomes.BiomeID,
	material_variant: u8,
) -> TerrainDecorationStampMaterials {
	_ = material_variant
	materials := TerrainDecorationStampMaterials {
		primary   = terrain_block_material_id_from_biome_material(.Stone),
		secondary = terrain_block_material_id_from_biome_material(.Dirt),
		accent    = terrain_block_material_id_from_biome_material(.Crystal),
	}
	switch family_id {
	case .Fern_Thicket:
		materials.primary = terrain_block_material_id_from_biome_material(.Forest_Litter)
		materials.secondary = terrain_block_material_id_from_biome_material(.Moss)
		materials.accent = terrain_block_material_id_from_biome_material(.Grass)
		if biome_id == .Wet_Lowland_Marsh || biome_id == .Corrupted_Fen {
			materials.primary = terrain_block_material_id_from_biome_material(.Wet_Marsh)
		}
	case .Ash_Bramble:
		materials.primary = terrain_block_material_id_from_biome_material(.Corrupt_Mud)
		materials.secondary = terrain_block_material_id_from_biome_material(.Corrupted_Ash)
		materials.accent = terrain_block_material_id_from_biome_material(.Crystal)
	case .Root_Cluster:
		materials.primary = terrain_block_material_id_from_biome_material(.Forest_Litter)
		materials.secondary = terrain_block_material_id_from_biome_material(.Moss)
		materials.accent = terrain_block_material_id_from_biome_material(.Dirt)
	case .Coral_DLA_Cluster:
		materials.primary = terrain_block_material_id_from_biome_material(.Aquifer_Wall)
		materials.secondary = terrain_block_material_id_from_biome_material(.Crystal)
		materials.accent = terrain_block_material_id_from_biome_material(.Wet_Marsh)
	case .Ruin_Pillar_Set:
		materials.primary = terrain_block_material_id_from_biome_material(.Stone)
		materials.secondary = terrain_block_material_id_from_biome_material(.Aquifer_Wall)
		materials.accent = terrain_block_material_id_from_biome_material(.Crystal)
		if biome_id == .Corrupted_Ash_Forest || biome_id == .Corrupted_Fen {
			materials.secondary = terrain_block_material_id_from_biome_material(.Corrupted_Ash)
		}
	case .Ruin_Hamlet:
		materials.primary = terrain_block_material_id_from_biome_material(.Forest_Litter)
		materials.secondary = terrain_block_material_id_from_biome_material(.Stone)
		materials.accent = terrain_block_material_id_from_biome_material(.Dirt)
		if biome_id == .Wet_Lowland_Marsh || biome_id == .Corrupted_Fen {
			materials.secondary = terrain_block_material_id_from_biome_material(.Wet_Marsh)
		}
		if biome_id == .Corrupted_Ash_Forest || biome_id == .Corrupted_Fen {
			materials.accent = terrain_block_material_id_from_biome_material(.Corrupted_Ash)
		}
	case .Watchtower_Ruin:
		materials.primary = terrain_block_material_id_from_biome_material(.Forest_Litter)
		materials.secondary = terrain_block_material_id_from_biome_material(.Stone)
		materials.accent = terrain_block_material_id_from_biome_material(.Dirt)
		if biome_id == .Basalt_Spire_Highlands || biome_id == .Emberglass_Badlands {
			materials.primary = terrain_block_material_id_from_biome_material(.Basalt)
			materials.secondary = terrain_block_material_id_from_biome_material(.Stone)
			materials.accent = terrain_block_material_id_from_biome_material(.Ember_Ash)
		}
		if biome_id == .Corrupted_Ash_Forest || biome_id == .Corrupted_Fen {
			materials.primary = terrain_block_material_id_from_biome_material(.Corrupt_Mud)
			materials.secondary = terrain_block_material_id_from_biome_material(.Corrupted_Ash)
			materials.accent = terrain_block_material_id_from_biome_material(.Crystal)
		}
	case .Palisade_Fort:
		materials.primary = terrain_block_material_id_from_biome_material(.Stone)
		materials.secondary = terrain_block_material_id_from_biome_material(.Aquifer_Wall)
		materials.accent = terrain_block_material_id_from_biome_material(.Forest_Litter)
		if biome_id == .Basalt_Spire_Highlands || biome_id == .Emberglass_Badlands {
			materials.primary = terrain_block_material_id_from_biome_material(.Basalt)
			materials.secondary = terrain_block_material_id_from_biome_material(.Stone)
			materials.accent = terrain_block_material_id_from_biome_material(.Ember_Ash)
		}
		if biome_id == .Corrupted_Ash_Forest || biome_id == .Corrupted_Fen {
			materials.primary = terrain_block_material_id_from_biome_material(.Corrupted_Ash)
			materials.secondary = terrain_block_material_id_from_biome_material(.Stone)
			materials.accent = terrain_block_material_id_from_biome_material(.Corrupt_Mud)
		}
	case .Cave_Ruin_Hall:
		materials.primary = terrain_block_material_id_from_biome_material(.Stone)
		materials.secondary = terrain_block_material_id_from_biome_material(.Aquifer_Wall)
		materials.accent = terrain_block_material_id_from_biome_material(.Crystal)
		if biome_id == .Fungal_Vaults {
			materials.secondary = terrain_block_material_id_from_biome_material(.Moss)
			materials.accent = terrain_block_material_id_from_biome_material(.Wet_Marsh)
		}
	case .Basalt_Column_Cluster:
		materials.primary = terrain_block_material_id_from_biome_material(.Basalt)
		materials.secondary = terrain_block_material_id_from_biome_material(.Stone)
		materials.accent = terrain_block_material_id_from_biome_material(.Crystal)
	case .Lava_Vent:
		materials.primary = terrain_block_material_id_from_biome_material(.Basalt)
		materials.secondary = terrain_block_material_id_from_biome_material(.Ember_Ash)
		materials.accent = terrain_water_material_id_for_biome(biome_id, false)
	case .Baseline_Tree, .Dead_Ash_Tree, .Fungal_Tree, .Stone_Tree, .Crystal_Growth_Cluster:
	}
	return materials
}

terrain_decoration_stamp_floor_find :: proc(
	view: ^world_async.ChunkVoxelView,
	ctx: TerrainDecorationStampContext,
	local_x, base_y, local_z: i32,
	max_delta: i32,
) -> (
	floor_y: i32,
	found: bool,
) {
	if !terrain_decoration_local_xz_inside(local_x, local_z, 1) {
		return
	}
	delta := math.max(max_delta, 1)
	if ctx.surface {
		if len(ctx.columns) != CHUNK_BLOCK_LENGTH * CHUNK_BLOCK_LENGTH {
			return
		}
		column := ctx.columns[local_x + local_z * CHUNK_BLOCK_LENGTH]
		if terrain_decoration_surface_column_is_water_covered(column) {
			return
		}
		candidate_y := column.surface_height - ctx.chunk_origin_y
		if math.abs(candidate_y - base_y) > delta {
			return
		}
		if terrain_decoration_floor_supports(view, local_x, candidate_y, local_z) {
			return candidate_y, true
		}
		return
	}

	search_top := math.min(base_y + delta + 1, CHUNK_BLOCK_LOCAL_MAX - 1)
	search_bottom := math.max(base_y - delta, 1)
	candidate_y, candidate_found := terrain_decoration_cave_floor_find(
		view,
		local_x,
		local_z,
		search_top,
		search_bottom,
	)
	if candidate_found && math.abs(candidate_y - base_y) <= delta {
		return candidate_y, true
	}
	return
}

terrain_decoration_grounded_column_write :: proc(
	view: ^world_async.ChunkVoxelView,
	ctx: TerrainDecorationStampContext,
	local_x, base_y, local_z: i32,
	height: i32,
	max_delta: i32,
	primary, cap: world_async.BlockMaterialID,
) -> u32 {
	if height <= 0 {
		return 0
	}
	floor_y, found := terrain_decoration_stamp_floor_find(
		view,
		ctx,
		local_x,
		base_y,
		local_z,
		max_delta,
	)
	if !found {
		return 0
	}

	written: u32
	for y_offset := i32(1); y_offset <= height; y_offset += 1 {
		material := primary
		if y_offset == height {
			material = cap
		}
		if terrain_decoration_block_try_write(
			view,
			local_x,
			floor_y + y_offset,
			local_z,
			material,
		) {
			written += 1
		}
	}
	return written
}

terrain_decoration_ground_cover_write :: proc(
	view: ^world_async.ChunkVoxelView,
	ctx: TerrainDecorationStampContext,
	local_x, base_y, local_z: i32,
	max_delta: i32,
	material: world_async.BlockMaterialID,
) -> u32 {
	floor_y, found := terrain_decoration_stamp_floor_find(
		view,
		ctx,
		local_x,
		base_y,
		local_z,
		max_delta,
	)
	if !found {
		return 0
	}
	if terrain_decoration_block_try_write(view, local_x, floor_y + 1, local_z, material) {
		return 1
	}
	return 0
}

terrain_decoration_lsystem_thicket_apply :: proc(
	view: ^world_async.ChunkVoxelView,
	biome_id: biomes.BiomeID,
	id: biomes.FeatureID,
	height_blocks, radius_blocks, material_variant: u8,
	local_x, base_y, local_z: i32,
	ctx: TerrainDecorationStampContext,
) -> u32 {
	materials := terrain_decoration_stamp_materials_for(.Fern_Thicket, biome_id, material_variant)
	radius := math.max(i32(radius_blocks), 4)
	max_height := math.max(i32(height_blocks) + 2, 4)
	stem_count := u32(14 + material_variant % 7)
	written: u32
	for stem_index := u32(0); stem_index < stem_count; stem_index += 1 {
		hash := terrain_decoration_stamp_hash(
			id,
			stem_index,
			0,
			TERRAIN_DECORATION_STAMP_OFFSET_X_SALT,
		)
		offset_x := i32(
			math.floor_f32(
				biomes.feature_grid_signed_unit_f32(hash, TERRAIN_DECORATION_STAMP_OFFSET_X_SALT) *
				f32(radius),
			),
		)
		offset_z := i32(
			math.floor_f32(
				biomes.feature_grid_signed_unit_f32(hash, TERRAIN_DECORATION_STAMP_OFFSET_Z_SALT) *
				f32(radius),
			),
		)
		x := local_x + offset_x
		z := local_z + offset_z
		stem_base_y, found_floor := terrain_decoration_stamp_floor_find(view, ctx, x, base_y, z, 6)
		if !found_floor {
			continue
		}
		height_roll := biomes.feature_grid_unit_f32(hash, TERRAIN_DECORATION_STAMP_STEP_SALT)
		stem_height := 1 + i32(math.floor_f32(height_roll * f32(max_height)))
		if stem_height > max_height {
			stem_height = max_height
		}
		if terrain_decoration_block_try_write(view, x, stem_base_y + 1, z, materials.secondary) {
			written += 1
		}
		for y_offset := i32(1); y_offset <= stem_height; y_offset += 1 {
			material := materials.primary
			if y_offset == stem_height {
				material = materials.secondary
			}
			if terrain_decoration_block_try_write(view, x, stem_base_y + y_offset, z, material) {
				written += 1
			}
		}

		branch_dirs := [?]biomes.IVec3 {
			{x = 1, y = 0, z = 0},
			{x = -1, y = 0, z = 0},
			{x = 0, y = 0, z = 1},
			{x = 0, y = 0, z = -1},
		}
		for dir, dir_index in branch_dirs {
			if ((stem_index + u32(dir_index)) & 1) != 0 {
				continue
			}
			if terrain_decoration_block_try_write(
				view,
				x + dir.x,
				stem_base_y + stem_height,
				z + dir.z,
				materials.accent,
			) {
				written += 1
			}
		}
	}
	return written
}

terrain_decoration_dla_cluster_apply :: proc(
	view: ^world_async.ChunkVoxelView,
	family_id: biomes.DecorationFamilyID,
	biome_id: biomes.BiomeID,
	id: biomes.FeatureID,
	height_blocks, radius_blocks, material_variant: u8,
	local_x, base_y, local_z: i32,
) -> u32 {
	materials := terrain_decoration_stamp_materials_for(family_id, biome_id, material_variant)
	branch_count := u32(10 + material_variant % 6)
	max_steps := u32(math.max(i32(height_blocks) * 2 + 8, 14))
	radius := math.max(i32(radius_blocks) + 2, 5)
	written: u32
	for branch_index := u32(0); branch_index < branch_count; branch_index += 1 {
		pos := biomes.IVec3 {
			x = 0,
			y = 1,
			z = 0,
		}
		for step := u32(0); step < max_steps; step += 1 {
			material := materials.primary
			if step > max_steps / 2 {
				material = materials.secondary
			}
			if step == max_steps - 1 {
				material = materials.accent
			}
			if terrain_decoration_cluster_block_try_write(
				view,
				local_x + pos.x,
				base_y + pos.y,
				local_z + pos.z,
				material,
				family_id == .Coral_DLA_Cluster || family_id == .Root_Cluster,
			) {
				written += 1
			}

			hash := terrain_decoration_stamp_hash(
				id,
				branch_index,
				step,
				TERRAIN_DECORATION_STAMP_DIRECTION_SALT,
			)
			choice := u32(
				math.floor_f32(
					biomes.feature_grid_unit_f32(hash, TERRAIN_DECORATION_STAMP_DIRECTION_SALT) *
					6.0,
				),
			)
			if choice > 5 {
				choice = 5
			}
			switch choice {
			case 0:
				pos.x += 1
			case 1:
				pos.x -= 1
			case 2:
				pos.z += 1
			case 3:
				pos.z -= 1
			case 4:
				pos.y += 1
			case:
				if family_id == .Root_Cluster {
					pos.y += 1
				} else if pos.y > 1 {
					pos.y -= 1
				}
			}
			pos.x = math.clamp(pos.x, -radius, radius)
			pos.z = math.clamp(pos.z, -radius, radius)
			pos.y = math.clamp(pos.y, 1, i32(height_blocks) + 3)
		}
	}
	return written
}

terrain_decoration_wfc_ruin_apply :: proc(
	view: ^world_async.ChunkVoxelView,
	biome_id: biomes.BiomeID,
	id: biomes.FeatureID,
	height_blocks, radius_blocks, material_variant, shape_variant, rotation_quarters: u8,
	local_x, base_y, local_z: i32,
	ctx: TerrainDecorationStampContext,
) -> u32 {
	materials := terrain_decoration_stamp_materials_for(
		.Ruin_Pillar_Set,
		biome_id,
		material_variant,
	)
	radius := math.clamp(i32(radius_blocks) + 2, 8, 12)
	height := math.clamp(i32(height_blocks) + 2, 6, 11)
	written: u32
	written += terrain_decoration_structure_rect_cover_write(
		view,
		ctx,
		local_x,
		base_y,
		local_z,
		-radius + 1,
		radius - 1,
		-radius + 1,
		radius - 1,
		3,
		materials.secondary,
	)

	for dz := -radius; dz <= radius; dz += 1 {
		for dx := -radius; dx <= radius; dx += 1 {
			abs_x := math.abs(dx)
			abs_z := math.abs(dz)
			perimeter := abs_x == radius || abs_z == radius
			inner_wall :=
				(abs_x == 2 && dz > -radius + 2 && dz < radius - 2) ||
				(abs_z == 2 && dx > -radius + 2 && dx < radius - 2)
			corner_pillar := abs_x >= radius - 1 && abs_z >= radius - 1
			debris :=
				!perimeter && !inner_wall && ((dx * 3 + dz * 5 + i32(material_variant)) % 7) == 0
			if !perimeter && !inner_wall && !corner_pillar && !debris {
				continue
			}
			cell_base_y, floor_found := terrain_decoration_stamp_floor_find(
				view,
				ctx,
				local_x + dx,
				base_y,
				local_z + dz,
				5,
			)
			if !floor_found {
				continue
			}
			hash := terrain_decoration_stamp_hash(
				id,
				u32((dx + radius) + (dz + radius) * 11),
				0,
				TERRAIN_DECORATION_STAMP_STEP_SALT,
			)
			damage := biomes.feature_grid_unit_f32(hash, TERRAIN_DECORATION_STAMP_STEP_SALT)
			block_height := i32(1)
			if perimeter || inner_wall || corner_pillar {
				block_height = height
				if !corner_pillar {
					block_height = math.max(2, height - 2 - i32(math.floor_f32(damage * 4.0)))
				}
				if damage < 0.18 && !corner_pillar {
					block_height = 1
				}
			}
			for y_offset := i32(1); y_offset <= block_height; y_offset += 1 {
				material := materials.primary
				if debris {
					material = materials.secondary
				} else if y_offset == block_height {
					material = materials.secondary
				}
				if terrain_decoration_block_try_write(
					view,
					local_x + dx,
					cell_base_y + y_offset,
					local_z + dz,
					material,
				) {
					written += 1
				}
			}
		}
	}

	beam_y := height - 1
	for beam_z := -radius + 2; beam_z <= radius - 2; beam_z += 4 {
		for beam_x := -radius + 1; beam_x <= radius - 1; beam_x += 1 {
			cell_base_y, floor_found := terrain_decoration_stamp_floor_find(
				view,
				ctx,
				local_x + beam_x,
				base_y,
				local_z + beam_z,
				3,
			)
			if !floor_found || ((beam_x + beam_z + i32(material_variant)) % 5) == 0 {
				continue
			}
			if terrain_decoration_block_try_write(
				view,
				local_x + beam_x,
				cell_base_y + beam_y,
				local_z + beam_z,
				materials.accent,
			) {
				written += 1
			}
		}
	}
	written += terrain_decoration_grounded_column_write(
		view,
		ctx,
		local_x - radius + 2,
		base_y,
		local_z + radius - 2,
		height + 2,
		3,
		materials.primary,
		materials.accent,
	)

	ruin_mode := shape_variant % 3
	switch ruin_mode {
	case 0:
		for tower_index := i32(0); tower_index < 4; tower_index += 1 {
			dx := radius - 2
			if (tower_index & 1) == 0 {
				dx = -radius + 2
			}
			dz := radius - 2
			if tower_index < 2 {
				dz = -radius + 2
			}
			written += terrain_decoration_grounded_column_write_rotated(
				view,
				ctx,
				local_x,
				base_y,
				local_z,
				dx,
				dz,
				rotation_quarters,
				height + 3 - (tower_index % 2),
				3,
				materials.primary,
				materials.secondary,
			)
		}
	case 1:
		for house_index := i32(0); house_index < 3; house_index += 1 {
			dx := (house_index - 1) * 6
			dz := i32(-4)
			if house_index == 1 {
				dz = 5
			}
			written += terrain_decoration_structure_room_apply(
				view,
				ctx,
				id,
				materials,
				local_x,
				base_y,
				local_z,
				dx,
				dz,
				3,
				2,
				math.max(3, height - 3 - house_index),
				1500 + u32(house_index) * 80,
			)
		}
	case:
		for row := i32(-3); row <= 3; row += 2 {
			for step := i32(-radius + 3); step <= radius - 3; step += 1 {
				written += terrain_decoration_ground_cover_write_rotated(
					view,
					ctx,
					local_x,
					base_y,
					local_z,
					step,
					row,
					rotation_quarters,
					3,
					materials.secondary,
				)
			}
		}
		written += terrain_decoration_grounded_column_write_rotated(
			view,
			ctx,
			local_x,
			base_y,
			local_z,
			radius - 3,
			-radius + 3,
			rotation_quarters,
			height + 4,
			3,
			materials.primary,
			materials.accent,
		)
	}
	return written
}

terrain_decoration_structure_room_apply :: proc(
	view: ^world_async.ChunkVoxelView,
	ctx: TerrainDecorationStampContext,
	id: biomes.FeatureID,
	materials: TerrainDecorationStampMaterials,
	local_x, base_y, local_z: i32,
	center_dx, center_dz: i32,
	half_x, half_z, wall_height: i32,
	member_base: u32,
) -> u32 {
	written: u32
	for dz := -half_z; dz <= half_z; dz += 1 {
		for dx := -half_x; dx <= half_x; dx += 1 {
			x := local_x + center_dx + dx
			z := local_z + center_dz + dz
			abs_x := math.abs(dx)
			abs_z := math.abs(dz)
			perimeter := abs_x == half_x || abs_z == half_z
			if !perimeter {
				if ((dx + dz + center_dx) & 1) == 0 {
					written += terrain_decoration_ground_cover_write(
						view,
						ctx,
						x,
						base_y,
						z,
						6,
						materials.secondary,
					)
				}
				continue
			}

			doorway := dz == -half_z && abs_x <= 1
			if doorway {
				continue
			}

			hash := terrain_decoration_stamp_hash(
				id,
				member_base + u32((dx + half_x) + (dz + half_z) * (half_x * 2 + 1)),
				0,
				TERRAIN_DECORATION_STAMP_STEP_SALT,
			)
			damage := biomes.feature_grid_unit_f32(hash, TERRAIN_DECORATION_STAMP_STEP_SALT)
			column_height := wall_height
			if damage < 0.10 {
				column_height = math.max(2, wall_height - 1)
			}
			cap_material := materials.primary
			if damage > 0.78 {
				cap_material = materials.accent
			}
			written += terrain_decoration_grounded_column_write(
				view,
				ctx,
				x,
				base_y,
				z,
				column_height,
				6,
				materials.primary,
				cap_material,
			)
		}
	}
	return written
}

terrain_decoration_structure_rect_cover_write :: proc(
	view: ^world_async.ChunkVoxelView,
	ctx: TerrainDecorationStampContext,
	local_x, base_y, local_z: i32,
	min_dx, max_dx, min_dz, max_dz: i32,
	max_delta: i32,
	material: world_async.BlockMaterialID,
) -> u32 {
	written: u32
	for dz := min_dz; dz <= max_dz; dz += 1 {
		for dx := min_dx; dx <= max_dx; dx += 1 {
			written += terrain_decoration_ground_cover_write(
				view,
				ctx,
				local_x + dx,
				base_y,
				local_z + dz,
				max_delta,
				material,
			)
		}
	}
	return written
}

terrain_decoration_structure_fence_rect_apply :: proc(
	view: ^world_async.ChunkVoxelView,
	ctx: TerrainDecorationStampContext,
	local_x, base_y, local_z: i32,
	min_dx, max_dx, min_dz, max_dz: i32,
	post_height: i32,
	materials: TerrainDecorationStampMaterials,
) -> u32 {
	written: u32
	for dz := min_dz; dz <= max_dz; dz += 1 {
		for dx := min_dx; dx <= max_dx; dx += 1 {
			perimeter := dx == min_dx || dx == max_dx || dz == min_dz || dz == max_dz
			if !perimeter {
				continue
			}
			gate := dz == min_dz && dx >= -1 && dx <= 1
			if gate {
				continue
			}
			height := i32(1)
			if ((dx - min_dx) % 3) == 0 || ((dz - min_dz) % 3) == 0 {
				height = post_height
			}
			written += terrain_decoration_grounded_column_write(
				view,
				ctx,
				local_x + dx,
				base_y,
				local_z + dz,
				height,
				2,
				materials.primary,
				materials.secondary,
			)
		}
	}
	return written
}

terrain_decoration_village_well_apply :: proc(
	view: ^world_async.ChunkVoxelView,
	ctx: TerrainDecorationStampContext,
	materials: TerrainDecorationStampMaterials,
	local_x, base_y, local_z: i32,
	center_dx, center_dz: i32,
) -> u32 {
	written: u32
	for dz := i32(-2); dz <= 2; dz += 1 {
		for dx := i32(-2); dx <= 2; dx += 1 {
			abs_x := math.abs(dx)
			abs_z := math.abs(dz)
			if abs_x == 2 || abs_z == 2 {
				written += terrain_decoration_grounded_column_write(
					view,
					ctx,
					local_x + center_dx + dx,
					base_y,
					local_z + center_dz + dz,
					1,
					2,
					materials.secondary,
					materials.secondary,
				)
			} else if abs_x <= 1 && abs_z <= 1 {
				written += terrain_decoration_ground_cover_write(
					view,
					ctx,
					local_x + center_dx + dx,
					base_y,
					local_z + center_dz + dz,
					2,
					terrain_block_material_id_from_biome_material(.Water),
				)
			}
		}
	}
	for dx := i32(-1); dx <= 1; dx += 2 {
		written += terrain_decoration_grounded_column_write(
			view,
			ctx,
			local_x + center_dx + dx,
			base_y,
			local_z + center_dz,
			4,
			2,
			materials.primary,
			materials.secondary,
		)
	}
	floor_y, found := terrain_decoration_stamp_floor_find(
		view,
		ctx,
		local_x + center_dx,
		base_y,
		local_z + center_dz,
		2,
	)
	if found {
		for dx := i32(-1); dx <= 1; dx += 1 {
			if terrain_decoration_block_try_write(
				view,
				local_x + center_dx + dx,
				floor_y + 5,
				local_z + center_dz,
				materials.accent,
			) {
				written += 1
			}
		}
	}
	return written
}

terrain_decoration_village_house_apply :: proc(
	view: ^world_async.ChunkVoxelView,
	ctx: TerrainDecorationStampContext,
	id: biomes.FeatureID,
	materials: TerrainDecorationStampMaterials,
	local_x, base_y, local_z: i32,
	center_dx, center_dz: i32,
	half_x, half_z, wall_height: i32,
	member_base: u32,
) -> u32 {
	written: u32
	for dz := -half_z; dz <= half_z; dz += 1 {
		for dx := -half_x; dx <= half_x; dx += 1 {
			x := local_x + center_dx + dx
			z := local_z + center_dz + dz
			abs_x := math.abs(dx)
			abs_z := math.abs(dz)
			perimeter := abs_x == half_x || abs_z == half_z
			if !perimeter {
				written += terrain_decoration_ground_cover_write(
					view,
					ctx,
					x,
					base_y,
					z,
					2,
					materials.secondary,
				)
				continue
			}

			doorway := dz == -half_z && abs_x <= 1
			cell_base_y, floor_found := terrain_decoration_stamp_floor_find(
				view,
				ctx,
				x,
				base_y,
				z,
				2,
			)
			if !floor_found {
				continue
			}
			hash := terrain_decoration_stamp_hash(
				id,
				member_base + u32((dx + half_x) + (dz + half_z) * (half_x * 2 + 1)),
				0,
				TERRAIN_DECORATION_STAMP_STEP_SALT,
			)
			for y_offset := i32(1); y_offset <= wall_height; y_offset += 1 {
				if doorway && y_offset <= 2 {
					continue
				}
				material := materials.primary
				window :=
					y_offset == 2 &&
					!doorway &&
					((abs_x == half_x && abs_z <= half_z - 2) ||
							(abs_z == half_z && abs_x <= half_x - 2)) &&
					biomes.feature_grid_unit_f32(hash, TERRAIN_DECORATION_STAMP_OFFSET_Z_SALT) >
						0.55
				if window {
					material = materials.secondary
				}
				if terrain_decoration_block_try_write(
					view,
					x,
					cell_base_y + y_offset,
					z,
					material,
				) {
					written += 1
				}
			}
		}
	}

	roof_half_x := half_x + 1
	for layer := i32(0); layer <= roof_half_x; layer += 1 {
		roof_x := roof_half_x - layer
		roof_y_offset := wall_height + 1 + layer / 2
		for dz := -half_z - 1; dz <= half_z + 1; dz += 1 {
			if roof_x == 0 {
				x := local_x + center_dx
				z := local_z + center_dz + dz
				cell_base_y, floor_found := terrain_decoration_stamp_floor_find(
					view,
					ctx,
					x,
					base_y,
					z,
					2,
				)
				if !floor_found {
					continue
				}
				if terrain_decoration_block_try_write(
					view,
					x,
					cell_base_y + roof_y_offset,
					z,
					materials.accent,
				) {
					written += 1
				}
				continue
			}
			for side := i32(-1); side <= 1; side += 2 {
				x := local_x + center_dx + roof_x * side
				z := local_z + center_dz + dz
				cell_base_y, floor_found := terrain_decoration_stamp_floor_find(
					view,
					ctx,
					x,
					base_y,
					z,
					2,
				)
				if !floor_found {
					continue
				}
				if terrain_decoration_block_try_write(
					view,
					x,
					cell_base_y + roof_y_offset,
					z,
					materials.accent,
				) {
					written += 1
				}
			}
		}
	}

	chimney_x := local_x + center_dx + half_x - 1
	chimney_z := local_z + center_dz + half_z - 1
	written += terrain_decoration_grounded_column_write(
		view,
		ctx,
		chimney_x,
		base_y,
		chimney_z,
		wall_height + 3,
		2,
		materials.secondary,
		materials.secondary,
	)
	return written
}

terrain_decoration_ruin_hamlet_apply :: proc(
	view: ^world_async.ChunkVoxelView,
	biome_id: biomes.BiomeID,
	id: biomes.FeatureID,
	height_blocks, radius_blocks, material_variant, shape_variant, rotation_quarters: u8,
	local_x, base_y, local_z: i32,
	ctx: TerrainDecorationStampContext,
) -> u32 {
	_ = radius_blocks
	_ = shape_variant
	materials := terrain_decoration_stamp_materials_for(.Ruin_Hamlet, biome_id, material_variant)
	wall_height := math.clamp(i32(height_blocks), 5, 6)
	written: u32

	for path_step := i32(-20); path_step <= 20; path_step += 1 {
		written += terrain_decoration_ground_cover_write(
			view,
			ctx,
			local_x + path_step,
			base_y,
			local_z,
			2,
			materials.secondary,
		)
		written += terrain_decoration_ground_cover_write(
			view,
			ctx,
			local_x,
			base_y,
			local_z + path_step,
			2,
			materials.secondary,
		)
	}

	written += terrain_decoration_village_house_apply(
		view,
		ctx,
		id,
		materials,
		local_x,
		base_y,
		local_z,
		0,
		2,
		5,
		4,
		wall_height + 1,
		100,
	)
	written += terrain_decoration_grounded_column_write(
		view,
		ctx,
		local_x,
		base_y,
		local_z + 2,
		wall_height + 5,
		2,
		materials.secondary,
		materials.accent,
	)

	written += terrain_decoration_village_house_apply(
		view,
		ctx,
		id,
		materials,
		local_x,
		base_y,
		local_z,
		-13,
		-8,
		4,
		3,
		wall_height,
		300,
	)
	forge_material := terrain_block_material_id_from_biome_material(.Lava)
	written += terrain_decoration_ground_cover_write(
		view,
		ctx,
		local_x - 9,
		base_y,
		local_z - 7,
		2,
		forge_material,
	)
	written += terrain_decoration_grounded_column_write(
		view,
		ctx,
		local_x - 9,
		base_y,
		local_z - 8,
		wall_height + 5,
		2,
		materials.secondary,
		materials.secondary,
	)

	written += terrain_decoration_village_house_apply(
		view,
		ctx,
		id,
		materials,
		local_x,
		base_y,
		local_z,
		13,
		-8,
		3,
		3,
		wall_height,
		500,
	)
	crystal_material := terrain_block_material_id_from_biome_material(.Crystal)
	crystal_offsets := [?]biomes.IVec2 {
		{x = 9, z = -12},
		{x = 17, z = -12},
		{x = 9, z = -4},
		{x = 17, z = -4},
	}
	for crystal_offset, crystal_index in crystal_offsets {
		written += terrain_decoration_grounded_column_write(
			view,
			ctx,
			local_x + crystal_offset.x,
			base_y,
			local_z + crystal_offset.z,
			3 + i32(crystal_index % 2),
			2,
			crystal_material,
			crystal_material,
		)
	}

	house_offsets := [?]biomes.IVec2 {
		{x = -16, z = 6},
		{x = -9, z = 16},
		{x = 9, z = 16},
		{x = 16, z = 5},
	}
	for house_offset, house_index in house_offsets {
		half_x := i32(3 + (u32(house_index) + u32(material_variant)) % 2)
		half_z := i32(3 + u32(house_index) % 2)
		written += terrain_decoration_village_house_apply(
			view,
			ctx,
			id,
			materials,
			local_x,
			base_y,
			local_z,
			house_offset.x,
			house_offset.z,
			half_x,
			half_z,
			wall_height,
			700 + u32(house_index) * 160,
		)
	}

	written += terrain_decoration_village_well_apply(
		view,
		ctx,
		materials,
		local_x,
		base_y,
		local_z,
		0,
		-15,
	)
	for plaza_step := i32(-6); plaza_step <= 6; plaza_step += 1 {
		written += terrain_decoration_ground_cover_write_rotated(
			view,
			ctx,
			local_x,
			base_y,
			local_z,
			plaza_step,
			-2,
			rotation_quarters,
			2,
			materials.secondary,
		)
		written += terrain_decoration_ground_cover_write_rotated(
			view,
			ctx,
			local_x,
			base_y,
			local_z,
			-6,
			plaza_step,
			rotation_quarters,
			2,
			materials.secondary,
		)
	}
	written += terrain_decoration_grounded_column_write_rotated(
		view,
		ctx,
		local_x,
		base_y,
		local_z,
		0,
		-1,
		rotation_quarters,
		wall_height + 8,
		2,
		materials.secondary,
		materials.accent,
	)
	written += terrain_decoration_grounded_column_write_rotated(
		view,
		ctx,
		local_x,
		base_y,
		local_z,
		0,
		-2,
		rotation_quarters,
		wall_height + 7,
		2,
		materials.secondary,
		materials.accent,
	)
	return written
}

terrain_decoration_watchtower_ruin_apply :: proc(
	view: ^world_async.ChunkVoxelView,
	biome_id: biomes.BiomeID,
	id: biomes.FeatureID,
	height_blocks, radius_blocks, material_variant, shape_variant, rotation_quarters: u8,
	local_x, base_y, local_z: i32,
	ctx: TerrainDecorationStampContext,
) -> u32 {
	materials := terrain_decoration_stamp_materials_for(
		.Watchtower_Ruin,
		biome_id,
		material_variant,
	)
	_ = radius_blocks
	_ = material_variant
	_ = shape_variant
	wall_height := math.clamp(i32(height_blocks), 5, 7)
	written: u32

	written += terrain_decoration_village_house_apply(
		view,
		ctx,
		id,
		materials,
		local_x,
		base_y,
		local_z,
		-8,
		0,
		6,
		4,
		wall_height,
		1000,
	)
	written += terrain_decoration_grounded_column_write(
		view,
		ctx,
		local_x - 17,
		base_y,
		local_z - 4,
		wall_height + 5,
		2,
		materials.primary,
		materials.secondary,
	)

	written += terrain_decoration_structure_fence_rect_apply(
		view,
		ctx,
		local_x,
		base_y,
		local_z,
		2,
		20,
		-10,
		11,
		2,
		materials,
	)
	field_material := terrain_block_material_id_from_biome_material(.Dirt)
	crop_material := terrain_block_material_id_from_biome_material(.Grass)
	if biome_id == .Corrupted_Ash_Forest || biome_id == .Corrupted_Fen {
		crop_material = terrain_block_material_id_from_biome_material(.Corrupt_Mud)
	}
	for dz := i32(-8); dz <= 9; dz += 3 {
		for dx := i32(4); dx <= 18; dx += 1 {
			row_material := crop_material
			if ((dx + dz) & 1) == 0 {
				row_material = field_material
			}
			written += terrain_decoration_ground_cover_write(
				view,
				ctx,
				local_x + dx,
				base_y,
				local_z + dz,
				2,
				row_material,
			)
		}
	}
	for yard_step := i32(-16); yard_step <= 20; yard_step += 1 {
		written += terrain_decoration_ground_cover_write(
			view,
			ctx,
			local_x + yard_step,
			base_y,
			local_z + 12,
			2,
			materials.secondary,
		)
	}
	windmill_x := i32(17)
	windmill_z := i32(-13)
	written += terrain_decoration_grounded_column_write_rotated(
		view,
		ctx,
		local_x,
		base_y,
		local_z,
		windmill_x,
		windmill_z,
		rotation_quarters,
		wall_height + 7,
		2,
		materials.primary,
		materials.secondary,
	)
	for arm := i32(-3); arm <= 3; arm += 1 {
		rotated_dx, rotated_dz := terrain_decoration_structure_offset_rotate(
			windmill_x + arm,
			windmill_z,
			rotation_quarters,
		)
		floor_y, found := terrain_decoration_stamp_floor_find(
			view,
			ctx,
			local_x + rotated_dx,
			base_y,
			local_z + rotated_dz,
			2,
		)
		if found &&
		   terrain_decoration_block_try_write(
			   view,
			   local_x + rotated_dx,
			   floor_y + wall_height + 5,
			   local_z + rotated_dz,
			   materials.accent,
		   ) {
			written += 1
		}
		rotated_dx, rotated_dz = terrain_decoration_structure_offset_rotate(
			windmill_x,
			windmill_z + arm,
			rotation_quarters,
		)
		floor_y, found = terrain_decoration_stamp_floor_find(
			view,
			ctx,
			local_x + rotated_dx,
			base_y,
			local_z + rotated_dz,
			2,
		)
		if found &&
		   terrain_decoration_block_try_write(
			   view,
			   local_x + rotated_dx,
			   floor_y + wall_height + 5 + arm,
			   local_z + rotated_dz,
			   materials.accent,
		   ) {
			written += 1
		}
	}
	return written
}

terrain_decoration_palisade_fort_apply :: proc(
	view: ^world_async.ChunkVoxelView,
	biome_id: biomes.BiomeID,
	id: biomes.FeatureID,
	height_blocks, radius_blocks, material_variant, shape_variant, rotation_quarters: u8,
	local_x, base_y, local_z: i32,
	ctx: TerrainDecorationStampContext,
) -> u32 {
	_ = shape_variant
	materials := terrain_decoration_stamp_materials_for(.Palisade_Fort, biome_id, material_variant)
	radius := math.clamp(i32(radius_blocks), 16, 20)
	wall_height := math.clamp(i32(height_blocks), 7, 10)
	written: u32

	written += terrain_decoration_structure_rect_cover_write(
		view,
		ctx,
		local_x,
		base_y,
		local_z,
		-radius + 2,
		radius - 2,
		-radius + 2,
		radius - 2,
		2,
		materials.accent,
	)
	for dz := -radius; dz <= radius; dz += 1 {
		for dx := -radius; dx <= radius; dx += 1 {
			abs_x := math.abs(dx)
			abs_z := math.abs(dz)
			perimeter := abs_x == radius || abs_z == radius
			corner_tower := abs_x >= radius - 2 && abs_z >= radius - 2
			gatehouse := dz == -radius && abs_x >= 3 && abs_x <= 6
			if !perimeter && !corner_tower && !gatehouse {
				continue
			}
			gate := dz == -radius && abs_x <= 2
			if gate && !corner_tower {
				continue
			}
			height := wall_height
			if corner_tower {
				height = wall_height + 5
			} else if gatehouse {
				height = wall_height + 2
			} else if ((dx + dz + i32(material_variant)) % 3) == 0 {
				height = wall_height + 1
			}
			written += terrain_decoration_grounded_column_write(
				view,
				ctx,
				local_x + dx,
				base_y,
				local_z + dz,
				height,
				3,
				materials.primary,
				materials.secondary,
			)
		}
	}

	for gate_x := i32(-2); gate_x <= 2; gate_x += 1 {
		cell_base_y, floor_found := terrain_decoration_stamp_floor_find(
			view,
			ctx,
			local_x + gate_x,
			base_y,
			local_z - radius,
			3,
		)
		if !floor_found {
			continue
		}
		if terrain_decoration_block_try_write(
			view,
			local_x + gate_x,
			cell_base_y + wall_height + 2,
			local_z - radius,
			materials.secondary,
		) {
			written += 1
		}
	}

	for walk_step := i32(-radius + 3); walk_step <= radius - 3; walk_step += 1 {
		written += terrain_decoration_ground_cover_write(
			view,
			ctx,
			local_x + walk_step,
			base_y,
			local_z - radius + 3,
			2,
			materials.secondary,
		)
		written += terrain_decoration_ground_cover_write(
			view,
			ctx,
			local_x,
			base_y,
			local_z + walk_step,
			2,
			materials.secondary,
		)
	}

	written += terrain_decoration_structure_room_apply(
		view,
		ctx,
		id,
		materials,
		local_x,
		base_y,
		local_z,
		0,
		2,
		6,
		5,
		math.max(5, wall_height - 2),
		500,
	)
	written += terrain_decoration_structure_room_apply(
		view,
		ctx,
		id,
		materials,
		local_x,
		base_y,
		local_z,
		-9,
		8,
		3,
		3,
		math.max(4, wall_height - 3),
		900,
	)
	written += terrain_decoration_structure_room_apply(
		view,
		ctx,
		id,
		materials,
		local_x,
		base_y,
		local_z,
		9,
		8,
		3,
		3,
		math.max(4, wall_height - 3),
		1200,
	)
	keep_height := wall_height + 8
	written += terrain_decoration_structure_room_apply(
		view,
		ctx,
		id,
		materials,
		local_x,
		base_y,
		local_z,
		0,
		0,
		4,
		4,
		keep_height,
		1600,
	)
	for spike_index := i32(0); spike_index < 4; spike_index += 1 {
		dx := i32(4)
		if (spike_index & 1) == 0 {
			dx = -4
		}
		dz := i32(4)
		if spike_index < 2 {
			dz = -4
		}
		spike_height := keep_height + 4
		if biome_id == .Corrupted_Ash_Forest || biome_id == .Corrupted_Fen {
			spike_height += 3 + spike_index
		}
		written += terrain_decoration_grounded_column_write_rotated(
			view,
			ctx,
			local_x,
			base_y,
			local_z,
			dx,
			dz,
			rotation_quarters,
			spike_height,
			3,
			materials.primary,
			materials.secondary,
		)
	}
	if biome_id == .Corrupted_Ash_Forest || biome_id == .Corrupted_Fen {
		for breach := i32(-radius + 6); breach <= -radius + 10; breach += 1 {
			written += terrain_decoration_ground_cover_write_rotated(
				view,
				ctx,
				local_x,
				base_y,
				local_z,
				breach,
				radius - 1,
				rotation_quarters,
				2,
				materials.accent,
			)
		}
	}
	return written
}

terrain_decoration_cave_ruin_hall_apply :: proc(
	view: ^world_async.ChunkVoxelView,
	biome_id: biomes.BiomeID,
	id: biomes.FeatureID,
	height_blocks, radius_blocks, material_variant, shape_variant, rotation_quarters: u8,
	local_x, base_y, local_z: i32,
	ctx: TerrainDecorationStampContext,
) -> u32 {
	_ = shape_variant
	_ = rotation_quarters
	if ctx.surface {
		return 0
	}
	materials := terrain_decoration_stamp_materials_for(
		.Cave_Ruin_Hall,
		biome_id,
		material_variant,
	)
	radius := math.clamp(i32(radius_blocks), 6, 9)
	height := math.clamp(i32(height_blocks), 5, 9)
	written: u32
	for dz := -radius; dz <= radius; dz += 1 {
		for dx := -radius; dx <= radius; dx += 1 {
			abs_x := math.abs(dx)
			abs_z := math.abs(dz)
			in_hall := abs_x <= radius && abs_z <= radius / 2
			if !in_hall {
				continue
			}
			pillar :=
				(abs_x == radius || abs_x == radius - 3) && (abs_z == radius / 2 || abs_z == 0)
			wall := abs_z == radius / 2 && abs_x > 1
			if pillar {
				written += terrain_decoration_grounded_column_write(
					view,
					ctx,
					local_x + dx,
					base_y,
					local_z + dz,
					height,
					8,
					materials.primary,
					materials.accent,
				)
			} else if wall {
				written += terrain_decoration_grounded_column_write(
					view,
					ctx,
					local_x + dx,
					base_y,
					local_z + dz,
					math.max(2, height / 2),
					8,
					materials.secondary,
					materials.primary,
				)
			} else if (dx + dz) % 3 == 0 {
				written += terrain_decoration_ground_cover_write(
					view,
					ctx,
					local_x + dx,
					base_y,
					local_z + dz,
					8,
					materials.secondary,
				)
			}
		}
	}
	return written
}

terrain_decoration_cellular_columns_apply :: proc(
	view: ^world_async.ChunkVoxelView,
	biome_id: biomes.BiomeID,
	id: biomes.FeatureID,
	height_blocks, radius_blocks, material_variant: u8,
	local_x, base_y, local_z: i32,
	ctx: TerrainDecorationStampContext,
) -> u32 {
	materials := terrain_decoration_stamp_materials_for(
		.Basalt_Column_Cluster,
		biome_id,
		material_variant,
	)
	radius := math.clamp(i32(radius_blocks) + 1, 4, 7)
	height := math.clamp(i32(height_blocks) + 3, 7, 14)
	written: u32
	for dz := -radius; dz <= radius; dz += 1 {
		for dx := -radius; dx <= radius; dx += 1 {
			distance := math.abs(dx) + math.abs(dz)
			if distance > radius + 1 {
				continue
			}
			hash := terrain_decoration_stamp_hash(
				id,
				u32((dx + radius) + (dz + radius) * 13),
				0,
				TERRAIN_DECORATION_STAMP_STEP_SALT,
			)
			cell := biomes.feature_grid_unit_f32(hash, TERRAIN_DECORATION_STAMP_STEP_SALT)
			if cell < 0.36 && distance > 1 {
				continue
			}
			cell_base_y, floor_found := terrain_decoration_stamp_floor_find(
				view,
				ctx,
				local_x + dx,
				base_y,
				local_z + dz,
				7,
			)
			if !floor_found {
				continue
			}
			column_height := height - distance / 2
			column_height += i32(math.floor_f32(cell * 4.0)) - 1
			column_height = math.clamp(column_height, 2, height)
			for y_offset := i32(1); y_offset <= column_height; y_offset += 1 {
				material := materials.primary
				if y_offset == column_height && (dx + dz + i32(material_variant)) % 3 == 0 {
					material = materials.secondary
				}
				if terrain_decoration_block_try_write(
					view,
					local_x + dx,
					cell_base_y + y_offset,
					local_z + dz,
					material,
				) {
					written += 1
				}
			}
		}
	}
	return written
}

terrain_decoration_lava_vent_apply :: proc(
	view: ^world_async.ChunkVoxelView,
	biome_id: biomes.BiomeID,
	id: biomes.FeatureID,
	height_blocks, radius_blocks, material_variant: u8,
	local_x, base_y, local_z: i32,
	ctx: TerrainDecorationStampContext,
) -> u32 {
	_ = id
	_ = height_blocks
	_ = radius_blocks
	materials := terrain_decoration_stamp_materials_for(.Lava_Vent, biome_id, material_variant)
	written: u32
	for dz := i32(-2); dz <= 2; dz += 1 {
		for dx := i32(-2); dx <= 2; dx += 1 {
			distance := math.abs(dx) + math.abs(dz)
			if distance > 3 {
				continue
			}
			x := local_x + dx
			z := local_z + dz
			cell_base_y, floor_found := terrain_decoration_stamp_floor_find(
				view,
				ctx,
				x,
				base_y,
				z,
				5,
			)
			if !floor_found {
				continue
			}
			material := materials.primary
			if distance <= 1 {
				material = materials.accent
			} else if distance == 2 {
				material = materials.secondary
			}
			if terrain_decoration_block_try_write(view, x, cell_base_y + 1, z, material) {
				written += 1
			}
		}
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
		if terrain_decoration_floor_supports(
			view,
			local_x + offset.x,
			side_base_y,
			local_z + offset.z,
		) {
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

terrain_decoration_cave_floor_find_nearby :: proc(
	view: ^world_async.ChunkVoxelView,
	local_x, local_z, search_top, search_bottom, radius: i32,
) -> (
	found_x, base_y, found_z: i32,
	found: bool,
) {
	offset_radius := math.clamp(radius, 4, 24)
	offset_step := math.max(4, offset_radius / 3)
	for dz := -offset_radius; dz <= offset_radius; dz += offset_step {
		for dx := -offset_radius; dx <= offset_radius; dx += offset_step {
			if math.abs(dx) + math.abs(dz) > offset_radius * 2 {
				continue
			}
			x := local_x + dx
			z := local_z + dz
			if !terrain_decoration_local_xz_inside(
				x,
				z,
				TERRAIN_DECORATION_CAVE_EDGE_MARGIN_BLOCKS,
			) {
				continue
			}
			y, floor_found := terrain_decoration_cave_floor_find(
				view,
				x,
				z,
				search_top,
				search_bottom,
			)
			if floor_found {
				return x, y, z, true
			}
		}
	}
	return local_x, 0, local_z, false
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

terrain_decoration_cluster_block_try_write :: proc(
	view: ^world_async.ChunkVoxelView,
	local_x, local_y, local_z: i32,
	material_id: world_async.BlockMaterialID,
	replace_water: bool,
) -> bool {
	if !chunk_block_coord_is_inside(local_x, local_y, local_z) {
		return false
	}
	index := chunk_block_index(u32(local_x), u32(local_y), u32(local_z))
	if view.blocks.occupancy[index] != .Empty {
		if !replace_water ||
		   terrain_material_palette_index(view.blocks.material_id[index]) != TERRAIN_WATER_MAT_ID {
			return false
		}
	}
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
	terrain_decoration_stats_family_accepted_add_many(stats, family_id, blocks_written, 1)
}

terrain_decoration_stats_family_accepted_add_many :: proc(
	stats: ^TerrainDecorationApplyStats,
	family_id: biomes.DecorationFamilyID,
	blocks_written: u32,
	accepted_count: u32,
) {
	index := u32(family_id)
	stats.family_accepted[index] += accepted_count
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
