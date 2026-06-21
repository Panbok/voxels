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

//////////////////////////////////////
// Terrain Decoration Constants
/////////////////////////////////////

TERRAIN_DECORATION_ENABLED :: #config(TERRAIN_DECORATION_ENABLED, true)
TERRAIN_DECORATION_SURFACE_EDGE_MARGIN_BLOCKS :: i32(3)
TERRAIN_DECORATION_CAVE_EDGE_MARGIN_BLOCKS :: i32(3)
TERRAIN_DECORATION_CAVE_FLOOR_SEARCH_EXTRA_BLOCKS :: i32(8)
TERRAIN_DECORATION_TREE_MEMBER_SALT :: u64(0x864d3f12a5c907eb)
TERRAIN_DECORATION_TREE_MEMBER_OFFSET_X_SALT :: u64(0x4b73e0c91d2f865a)
TERRAIN_DECORATION_TREE_MEMBER_OFFSET_Z_SALT :: u64(0x28f6b40de751a9c3)
TERRAIN_DECORATION_TREE_MEMBER_VARIANT_SALT :: u64(0xc5197ba48ed6032f)
TERRAIN_DECORATION_TREE_MEMBER_ROTATION_SALT :: u64(0x70f3a51bc84d2e69)
TERRAIN_DECORATION_TREE_MEMBER_MATERIAL_SALT :: u64(0xad25c8e73b96140f)
TERRAIN_DECORATION_TREE_CROWN_ACCENT_SALT :: u64(0x6e97310fb4c825da)
TERRAIN_DECORATION_TREE_SEGMENT_SHELL_RADIUS_BLOCKS :: i32(1)
TERRAIN_DECORATION_TREE_BRANCH_SHELL_TAPER_PERCENT :: i32(80)
TERRAIN_DECORATION_TREE_TRUNK_SHELL_TAPER_PERCENT :: i32(70)

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
		result := terrain_decoration_surface_feature_apply(
			view,
			surface_features[i],
			chunk_origin,
			columns,
		)
		stats.surface_tree_instances_attempted += result.tree_instances_attempted
		stats.surface_tree_instances_accepted += result.tree_instances_accepted
		stats.surface_tree_root_rejected += result.tree_root_rejected
		stats.surface_tree_shape_rejected += result.tree_shape_rejected
		if result.blocks_written > 0 {
			stats.surface_accepted += result.tree_instances_accepted
			stats.blocks_written += result.blocks_written
			terrain_decoration_stats_family_accepted_add_many(
				&stats,
				surface_features[i].family_id,
				result.blocks_written,
				result.tree_instances_accepted,
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
	if column.water_fill_active {
		return
	}
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

terrain_decoration_surface_root_supports :: proc(
	feature: biomes.DecorationFeature,
	column: TerrainBiomeColumn,
	material_id: world_async.BlockMaterialID,
) -> bool {
	palette := terrain_material_palette_index(material_id)
	if palette == TERRAIN_WATER_MAT_ID {
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
	case .Fungal_Tree:
		return false
	}
	return false
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
		result.tree_instances_attempted += 1
		offset_x, offset_z := terrain_decoration_tree_member_offset(feature, member_index)
		local_x := root_x + offset_x - chunk_origin.x
		local_z := root_z + offset_z - chunk_origin.z
		base_y, root_found := terrain_decoration_surface_root_find(
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
			local_x,
			base_y,
			local_z,
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
	distance := radius - i32(member_index % 2) * i32(2)
	if distance < 8 {
		distance = 8
	}
	half := distance / 2
	selector_roll := biomes.feature_grid_unit_f32(
		hash,
		TERRAIN_DECORATION_TREE_MEMBER_OFFSET_X_SALT,
	)
	selector := i32(math.floor_f32(selector_roll * 8.0))
	if selector > 7 {
		selector = 7
	}
	switch selector {
	case 0:
		offset_x = distance
		offset_z = half
	case 1:
		offset_x = -distance
		offset_z = half
	case 2:
		offset_x = half
		offset_z = -distance
	case 3:
		offset_x = -half
		offset_z = -distance
	case 4:
		offset_x = distance
		offset_z = -half
	case 5:
		offset_x = -distance
		offset_z = -half
	case 6:
		offset_x = half
		offset_z = distance
	case:
		offset_x = -half
		offset_z = distance
	}
	offset_x += i32(
		math.floor_f32(
			biomes.feature_grid_signed_unit_f32(
				hash,
				TERRAIN_DECORATION_TREE_MEMBER_OFFSET_Z_SALT,
			) *
			2.0,
		),
	)
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
		return 0
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
		return 0
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
	case .Stone_Tree:
		materials.trunk = terrain_block_material_id_from_biome_material(.Stone)
		materials.branch = terrain_block_material_id_from_biome_material(.Aquifer_Wall)
		if (material_variant & 1) == 0 {
			materials.branch = terrain_block_material_id_from_biome_material(.Stone)
		}
		materials.cap = terrain_block_material_id_from_biome_material(.Crystal)
		materials.cap_accent = terrain_block_material_id_from_biome_material(.Stone)
		materials.cap_accent_chance = 0.22
	case .Fungal_Tree:
		materials.trunk = terrain_block_material_id_from_biome_material(.Dirt)
		materials.branch = terrain_block_material_id_from_biome_material(.Wet_Marsh)
		materials.cap = terrain_block_material_id_from_biome_material(.Wet_Marsh)
		materials.cap_accent = terrain_block_material_id_from_biome_material(.Crystal)
		materials.cap_accent_chance = 0.08
	case .Crystal_Growth_Cluster:
	}
	return materials
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
