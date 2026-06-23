package biomes

import "core:log"
import math "core:math"

//////////////////////////////////////
// Hydrology Types
/////////////////////////////////////

// WaterFeatureKind identifies the persistent hydrology feature that shapes terrain and later water fill.
WaterFeatureKind :: enum u8 {
	// Global/coastal water reference used for shorelines and sea compression, not sampled as a local graph node.
	Sea,
	// Surface basin feature that depresses land into a lakebed and broad wet margin.
	Surface_Lake,
	// Surface channel feature that carves river corridors between water graph nodes.
	Surface_River,
	// Subterranean water-bearing volume that biases caves toward aquifer-like chambers.
	Aquifer,
	// Subterranean channel feature that connects underground water graph nodes.
	Underground_River,
	// Broad subterranean flooded zone that biases caves toward larger wet or submerged regions.
	Flooded_Region,
}

// WaterFeatureAnchorKind marks intentional contact points between water features and terrain/cave systems.
WaterFeatureAnchorKind :: enum u8 {
	// Surface/coastal contact point where terrain should reason about sea adjacency.
	Shoreline,
	// Surface lake contact point intended for cave or terrain breaches through a lakebed.
	Lakebed_Breach,
	// Surface river contact point intended for bank shaping or possible cave/terrain connections.
	River_Bank,
	// Underground aquifer contact point intended for cave breaches into water-bearing terrain.
	Aquifer_Breach,
	// Underground river contact point intended for tunnel or cave-network linkage.
	Underground_River_Link,
	// Flooded-region contact point intended for cave-network linkage into submerged spaces.
	Flooded_Cave_Link,
}

WaterFeatureNode :: struct {
	id:                      FeatureID,
	owner:                   FeatureGridCoord3,
	kind:                    WaterFeatureKind,
	source_biome_id:         BiomeID,
	x, y, z:                 f32,
	water_level_blocks:      f32,
	influence_radius_blocks: f32,
	floor_depression_blocks: f32,
	channel_width_blocks:    f32,
}

WaterFeatureSegment :: struct {
	id:                      FeatureID,
	owner:                   FeatureGridCoord3,
	kind:                    WaterFeatureKind,
	from_node_id:            FeatureID,
	to_node_id:              FeatureID,
	source_biome_id:         BiomeID,
	from_x, from_y, from_z:  f32,
	bend_x, bend_y, bend_z:  f32,
	to_x, to_y, to_z:        f32,
	water_level_blocks:      f32,
	influence_radius_blocks: f32,
	floor_depression_blocks: f32,
}

WaterFeatureAnchor :: struct {
	id:                      FeatureID,
	owner:                   FeatureGridCoord3,
	feature_id:              FeatureID,
	kind:                    WaterFeatureAnchorKind,
	x, y, z:                 f32,
	influence_radius_blocks: f32,
}

HydrologyLayerSurfaceSample :: struct {
	nearest_feature_id:                FeatureID,
	nearest_feature_kind:              WaterFeatureKind,
	nearest_distance_blocks:           f32,
	feature_count:                     u32,
	anchor_count:                      u32,
	water_level_blocks:                f32,
	water_level_influence:             f32,
	water_biome_id:                    BiomeID,
	water_material_conflict_influence: f32,
	basin_influence:                   f32,
	channel_influence:                 f32,
	floor_depression_blocks:           f32,
	bank_smoothing_strength:           f32,
	anchor_connection_weight:          f32,
}

HydrologyLayerSubterraneanSample :: struct {
	nearest_feature_id:                FeatureID,
	nearest_feature_kind:              WaterFeatureKind,
	nearest_distance_blocks:           f32,
	feature_count:                     u32,
	anchor_count:                      u32,
	water_level_blocks:                f32,
	water_level_influence:             f32,
	water_biome_id:                    BiomeID,
	water_material_conflict_influence: f32,
	aquifer_influence:                 f32,
	channel_influence:                 f32,
	flooded_region_influence:          f32,
	floor_depression_blocks:           f32,
	cave_connection_weight:            f32,
}

//////////////////////////////////////
// Hydrology Constants
/////////////////////////////////////

HYDROLOGY_SURFACE_GRAPH_GRID_CONFIG :: FeatureGridConfig {
	domain           = .Surface,
	level            = .Micro,
	cell_size_blocks = 768,
	jitter_fraction  = 0.70,
}

HYDROLOGY_SUBTERRANEAN_GRAPH_GRID_CONFIG :: FeatureGridConfig {
	domain           = .Subterranean,
	level            = .Micro,
	cell_size_blocks = 768,
	jitter_fraction  = 0.65,
}

HYDROLOGY_SURFACE_DOMAIN_SALT :: u64(0x8b0f5a812d4c6e37)
HYDROLOGY_SUBTERRANEAN_DOMAIN_SALT :: u64(0xb471c9e3206df85a)
HYDROLOGY_NODE_KIND_SALT :: u64(0x6f1d2c3b4a596877)
HYDROLOGY_SEGMENT_ID_SALT :: u64(0xa5159f2edc0b4763)
HYDROLOGY_SEGMENT_EXISTENCE_SALT :: u64(0xe284bf615d0c7a39)
HYDROLOGY_NODE_ACCEPTANCE_SALT :: u64(0x94c2a6db35815d0c)
HYDROLOGY_SEGMENT_BEND_X_SALT :: u64(0x7d3a519c842ef06b)
HYDROLOGY_SEGMENT_BEND_Y_SALT :: u64(0x1c9f62b85e37a4d0)
HYDROLOGY_SEGMENT_BEND_Z_SALT :: u64(0xbd47e19305ac628f)
HYDROLOGY_ANCHOR_ID_SALT :: u64(0x3c79e14a682fd5b0)
HYDROLOGY_JITTER_X_SALT :: u64(0x2bbf35d1275a41ce)
HYDROLOGY_JITTER_Y_SALT :: u64(0x9f06c4eb43d127a8)
HYDROLOGY_JITTER_Z_SALT :: u64(0xd6751a39b48ec20f)
HYDROLOGY_LEVEL_SALT :: u64(0x40f3b91e2c756a8d)
HYDROLOGY_RADIUS_SALT :: u64(0x15d0c7a39e284bf6)
HYDROLOGY_DEPTH_SALT :: u64(0x7ae39b15c602f4d8)

HYDROLOGY_SURFACE_SAMPLE_MARGIN_BLOCKS :: 128
HYDROLOGY_SUBTERRANEAN_SAMPLE_MARGIN_BLOCKS :: 192
HYDROLOGY_SURFACE_BANK_FALLOFF_BLOCKS :: f32(24)
HYDROLOGY_SUBTERRANEAN_FALLOFF_BLOCKS :: f32(36)

//////////////////////////////////////
// Hydrology Feature Methods
/////////////////////////////////////

water_feature_kind_is_surface :: proc(kind: WaterFeatureKind) -> bool {
	#partial switch kind {
	case .Sea, .Surface_Lake, .Surface_River:
		return true
	}
	return false
}

water_feature_kind_is_subterranean :: proc(kind: WaterFeatureKind) -> bool {
	#partial switch kind {
	case .Aquifer, .Underground_River, .Flooded_Region:
		return true
	}
	return false
}

water_feature_surface_node_from_owner :: proc(
	key: FeatureGridKey,
	owner: FeatureGridCoord2,
) -> WaterFeatureNode {
	feature_id := water_feature_id_from_owner(key, owner, HYDROLOGY_SURFACE_DOMAIN_SALT)
	hash := u64(feature_id)
	config := HYDROLOGY_SURFACE_GRAPH_GRID_CONFIG
	cell_size := f32(config.cell_size_blocks)
	jitter_radius := cell_size * 0.5 * config.jitter_fraction
	x :=
		feature_grid_cell_center(owner.x, cell_size) +
		feature_grid_signed_unit_f32(hash, HYDROLOGY_JITTER_X_SALT) * jitter_radius
	z :=
		feature_grid_cell_center(owner.z, cell_size) +
		feature_grid_signed_unit_f32(hash, HYDROLOGY_JITTER_Z_SALT) * jitter_radius
	macro_zone, _ := surface_macro_zone_sample(key, i32(math.floor_f32(x)), i32(math.floor_f32(z)))
	source_biome_id := water_feature_surface_source_biome_id(key, x, z, macro_zone)
	kind := water_feature_surface_kind_from_macro_roll(
		macro_zone,
		feature_grid_unit_f32(hash, HYDROLOGY_NODE_KIND_SALT),
	)
	level_variation := feature_grid_signed_unit_f32(hash, HYDROLOGY_LEVEL_SALT)
	radius_roll := feature_grid_unit_f32(hash, HYDROLOGY_RADIUS_SALT)
	depth_roll := feature_grid_unit_f32(hash, HYDROLOGY_DEPTH_SALT)

	radius := regional_terrain_field_lerp(22, 54, radius_roll)
	depression := regional_terrain_field_lerp(1.5, 4.5, depth_roll)
	channel_width := regional_terrain_field_lerp(10, 22, radius_roll)
	if kind == .Surface_River {
		radius = channel_width * 0.60
		depression = regional_terrain_field_lerp(1.0, 3.0, depth_roll)
	}
	if macro_zone == .Wetland {
		radius *= 1.12
		depression *= 0.70
	}

	return {
		id = feature_id,
		owner = {x = owner.x, y = 0, z = owner.z},
		kind = kind,
		source_biome_id = source_biome_id,
		x = x,
		y = SEA_LEVEL_BLOCKS,
		z = z,
		water_level_blocks = SEA_LEVEL_BLOCKS + level_variation * 5.0,
		influence_radius_blocks = radius,
		floor_depression_blocks = depression,
		channel_width_blocks = channel_width,
	}
}

water_feature_subterranean_node_from_owner :: proc(
	key: FeatureGridKey,
	owner: FeatureGridCoord3,
) -> WaterFeatureNode {
	feature_id := water_feature_id_from_owner(key, owner, HYDROLOGY_SUBTERRANEAN_DOMAIN_SALT)
	hash := u64(feature_id)
	config := HYDROLOGY_SUBTERRANEAN_GRAPH_GRID_CONFIG
	cell_size := f32(config.cell_size_blocks)
	jitter_radius := cell_size * 0.5 * config.jitter_fraction
	x :=
		feature_grid_cell_center(owner.x, cell_size) +
		feature_grid_signed_unit_f32(hash, HYDROLOGY_JITTER_X_SALT) * jitter_radius
	y :=
		feature_grid_cell_center(owner.y, cell_size) +
		feature_grid_signed_unit_f32(hash, HYDROLOGY_JITTER_Y_SALT) * jitter_radius
	z :=
		feature_grid_cell_center(owner.z, cell_size) +
		feature_grid_signed_unit_f32(hash, HYDROLOGY_JITTER_Z_SALT) * jitter_radius
	macro_zone, _ := subterranean_macro_zone_sample(
		key,
		i32(math.floor_f32(x)),
		i32(math.floor_f32(y)),
		i32(math.floor_f32(z)),
	)
	source_biome_id := water_feature_subterranean_source_biome_id(macro_zone)
	depth_band := subterranean_depth_band_from_y(i32(math.floor_f32(y)))
	kind := water_feature_subterranean_kind_from_macro_depth_roll(
		macro_zone,
		depth_band,
		feature_grid_unit_f32(hash, HYDROLOGY_NODE_KIND_SALT),
	)
	radius_roll := feature_grid_unit_f32(hash, HYDROLOGY_RADIUS_SALT)
	depth_roll := feature_grid_unit_f32(hash, HYDROLOGY_DEPTH_SALT)

	radius := regional_terrain_field_lerp(42, 110, radius_roll)
	depression := regional_terrain_field_lerp(3, 9, depth_roll)
	channel_width := regional_terrain_field_lerp(18, 42, radius_roll)
	if kind == .Underground_River {
		radius = channel_width
	}
	if kind == .Flooded_Region {
		radius *= 1.35
		depression *= 1.20
	}

	return {
		id = feature_id,
		owner = owner,
		kind = kind,
		source_biome_id = source_biome_id,
		x = x,
		y = y,
		z = z,
		water_level_blocks = y + feature_grid_signed_unit_f32(hash, HYDROLOGY_LEVEL_SALT) * 18,
		influence_radius_blocks = radius,
		floor_depression_blocks = depression,
		channel_width_blocks = channel_width,
	}
}

water_feature_surface_segment_from_owners :: proc(
	key: FeatureGridKey,
	owner, neighbor_owner: FeatureGridCoord2,
) -> (
	segment: WaterFeatureSegment,
	exists: bool,
) {
	from_node := water_feature_surface_node_from_owner(key, owner)
	to_node := water_feature_surface_node_from_owner(key, neighbor_owner)
	if !water_feature_surface_node_should_emit(key, from_node) ||
	   !water_feature_surface_node_should_emit(key, to_node) {
		return
	}
	segment = water_feature_segment_from_nodes(
		key,
		from_node,
		to_node,
		.Surface_River,
		{x = owner.x, y = 0, z = owner.z},
	)
	exists = water_feature_surface_segment_should_exist(segment, from_node, to_node)
	return
}

water_feature_subterranean_segment_from_owners :: proc(
	key: FeatureGridKey,
	owner, neighbor_owner: FeatureGridCoord3,
) -> (
	segment: WaterFeatureSegment,
	exists: bool,
) {
	from_node := water_feature_subterranean_node_from_owner(key, owner)
	to_node := water_feature_subterranean_node_from_owner(key, neighbor_owner)
	if !water_feature_subterranean_node_should_emit(from_node) ||
	   !water_feature_subterranean_node_should_emit(to_node) {
		return
	}
	segment = water_feature_segment_from_nodes(key, from_node, to_node, .Underground_River, owner)
	exists = water_feature_subterranean_segment_should_exist(segment, from_node, to_node)
	return
}

water_feature_surface_node_should_emit :: proc(
	key: FeatureGridKey,
	node: WaterFeatureNode,
) -> bool {
	if !water_feature_kind_is_surface(node.kind) || node.kind == .Sea {
		return false
	}
	block_x := i32(math.floor_f32(node.x))
	block_z := i32(math.floor_f32(node.z))
	surface_height_blocks := water_feature_surface_dry_height_estimate(key, block_x, block_z)
	if surface_height_blocks < SEA_LEVEL_BLOCKS + 6 {
		return false
	}
	roll := feature_grid_unit_f32(u64(node.id), HYDROLOGY_NODE_ACCEPTANCE_SALT)
	chance: f32
	switch node.source_biome_id {
	case .Wet_Lowland_Marsh:
		chance = 0.18
	case .Corrupted_Fen:
		chance = 0.12
	case .Temperate_Hills, .Old_Growth_Forest:
		chance = 0.08
	case .Corrupted_Ash_Forest:
		chance = 0.06
	case .Basalt_Spire_Highlands, .Emberglass_Badlands:
		chance = 0.05
	case .Fungal_Vaults, .Crystal_Geode_Network, .Buried_Aquifer_Caves:
		chance = 0.04
	}
	if node.kind == .Surface_River {
		chance += 0.02
	}
	if surface_height_blocks > SEA_LEVEL_BLOCKS + 64 {
		chance *= 0.35
	}
	return roll < math.clamp(chance, f32(0.02), f32(0.26))
}

water_feature_surface_dry_height_estimate :: proc(
	key: FeatureGridKey,
	block_x, block_z: i32,
) -> f32 {
	sample := surface_biome_field_sample(key, block_x, block_z)
	if sample.cell_count == 0 {
		return SEA_LEVEL_BLOCKS + 8
	}
	fields := regional_terrain_fields_sample(key, block_x, 0, block_z)
	biome_id := sample.cells[sample.dominant_index].biome_id
	target := biome_shape_target_evaluate(biome_profile_for(biome_id), fields)
	return target.surface_height_blocks
}

water_feature_subterranean_node_should_emit :: proc(node: WaterFeatureNode) -> bool {
	if !water_feature_kind_is_subterranean(node.kind) {
		return false
	}
	roll := feature_grid_unit_f32(u64(node.id), HYDROLOGY_NODE_ACCEPTANCE_SALT)
	chance: f32
	switch node.source_biome_id {
	case .Buried_Aquifer_Caves:
		chance = 0.24
	case .Fungal_Vaults:
		chance = 0.14
	case .Crystal_Geode_Network:
		chance = 0.12
	case .Temperate_Hills,
	     .Old_Growth_Forest,
	     .Basalt_Spire_Highlands,
	     .Emberglass_Badlands,
	     .Wet_Lowland_Marsh,
	     .Corrupted_Ash_Forest,
	     .Corrupted_Fen:
		chance = 0.08
	}
	#partial switch node.kind {
	case .Aquifer:
		chance += 0.06
	case .Underground_River:
		chance += 0.02
	case .Flooded_Region:
		chance -= 0.04
	}
	return roll < math.clamp(chance, f32(0.04), f32(0.34))
}

water_feature_node_anchor :: proc(node: WaterFeatureNode) -> WaterFeatureAnchor {
	kind := WaterFeatureAnchorKind.Shoreline
	#partial switch node.kind {
	case .Sea:
		kind = .Shoreline
	case .Surface_Lake:
		kind = .Lakebed_Breach
	case .Surface_River:
		kind = .River_Bank
	case .Aquifer:
		kind = .Aquifer_Breach
	case .Underground_River:
		kind = .Underground_River_Link
	case .Flooded_Region:
		kind = .Flooded_Cave_Link
	}
	return {
		id = water_feature_anchor_id_from_feature(node.id, HYDROLOGY_ANCHOR_ID_SALT),
		owner = node.owner,
		feature_id = node.id,
		kind = kind,
		x = node.x,
		y = node.y,
		z = node.z,
		influence_radius_blocks = math.max(f32(12), node.influence_radius_blocks * 0.45),
	}
}

water_feature_segment_anchor :: proc(segment: WaterFeatureSegment) -> WaterFeatureAnchor {
	kind := WaterFeatureAnchorKind.River_Bank
	if water_feature_kind_is_subterranean(segment.kind) {
		kind = .Underground_River_Link
	}
	return {
		id = water_feature_anchor_id_from_feature(segment.id, HYDROLOGY_ANCHOR_ID_SALT),
		owner = segment.owner,
		feature_id = segment.id,
		kind = kind,
		x = (segment.from_x + segment.to_x) * 0.5,
		y = (segment.from_y + segment.to_y) * 0.5,
		z = (segment.from_z + segment.to_z) * 0.5,
		influence_radius_blocks = math.max(f32(10), segment.influence_radius_blocks * 0.65),
	}
}

water_feature_surface_kind_from_macro_roll :: proc(
	macro_zone: SurfaceMacroZone,
	roll: f32,
) -> WaterFeatureKind {
	switch macro_zone {
	case .Wetland:
		if roll < 0.72 {
			return .Surface_Lake
		}
		return .Surface_River
	case .Volcanic:
		if roll < 0.30 {
			return .Surface_Lake
		}
		return .Surface_River
	case .Corrupted:
		if roll < 0.38 {
			return .Surface_Lake
		}
		return .Surface_River
	case .Temperate:
		if roll < 0.48 {
			return .Surface_Lake
		}
		return .Surface_River
	}
	return .Surface_River
}

water_feature_surface_source_biome_id :: proc(
	key: FeatureGridKey,
	x, z: f32,
	macro_zone: SurfaceMacroZone,
) -> BiomeID {
	sample := surface_biome_field_sample(key, i32(math.floor_f32(x)), i32(math.floor_f32(z)))
	if sample.cell_count > 0 {
		return sample.cells[sample.dominant_index].biome_id
	}
	switch macro_zone {
	case .Wetland:
		return .Wet_Lowland_Marsh
	case .Volcanic:
		return .Emberglass_Badlands
	case .Corrupted:
		return .Corrupted_Fen
	case .Temperate:
		return .Temperate_Hills
	}
	return .Temperate_Hills
}

water_feature_subterranean_source_biome_id :: proc(macro_zone: SubterraneanMacroZone) -> BiomeID {
	switch macro_zone {
	case .Aquifer:
		return .Buried_Aquifer_Caves
	case .Rooted:
		return .Fungal_Vaults
	case .Mineral:
		return .Crystal_Geode_Network
	}
	return .Buried_Aquifer_Caves
}

water_feature_source_water_group :: proc(biome_id: BiomeID) -> u8 {
	switch biome_id {
	case .Wet_Lowland_Marsh, .Fungal_Vaults, .Buried_Aquifer_Caves:
		return 1
	case .Corrupted_Ash_Forest, .Corrupted_Fen:
		return 2
	case .Basalt_Spire_Highlands, .Emberglass_Badlands:
		return 3
	case .Crystal_Geode_Network:
		return 4
	case .Temperate_Hills, .Old_Growth_Forest:
		return 0
	}
	return 0
}

water_feature_segment_source_biome_id :: proc(from_node, to_node: WaterFeatureNode) -> BiomeID {
	from_group := water_feature_source_water_group(from_node.source_biome_id)
	to_group := water_feature_source_water_group(to_node.source_biome_id)
	if from_group == to_group {
		return from_node.source_biome_id
	}
	if from_node.kind == .Surface_River || from_node.kind == .Underground_River {
		return from_node.source_biome_id
	}
	if to_node.kind == .Surface_River || to_node.kind == .Underground_River {
		return to_node.source_biome_id
	}
	return from_node.source_biome_id
}

water_feature_subterranean_kind_from_macro_depth_roll :: proc(
	macro_zone: SubterraneanMacroZone,
	depth_band: SubterraneanDepthBand,
	roll: f32,
) -> WaterFeatureKind {
	switch macro_zone {
	case .Aquifer:
		if roll < 0.55 {
			return .Aquifer
		}
		if roll < 0.84 {
			return .Underground_River
		}
		return .Flooded_Region
	case .Rooted:
		if depth_band == .Shallow && roll < 0.45 {
			return .Aquifer
		}
		if roll < 0.70 {
			return .Underground_River
		}
		return .Flooded_Region
	case .Mineral:
		if depth_band == .Deep && roll > 0.70 {
			return .Flooded_Region
		}
		if roll < 0.32 {
			return .Aquifer
		}
		return .Underground_River
	}
	return .Underground_River
}

water_feature_segment_from_nodes :: proc(
	key: FeatureGridKey,
	from_node, to_node: WaterFeatureNode,
	kind: WaterFeatureKind,
	owner: FeatureGridCoord3,
) -> WaterFeatureSegment {
	_ = key
	width := (from_node.channel_width_blocks + to_node.channel_width_blocks) * 0.5
	id := water_feature_segment_id_from_nodes(from_node.id, to_node.id, kind)
	dx := to_node.x - from_node.x
	dy := to_node.y - from_node.y
	dz := to_node.z - from_node.z
	length_xz := math.sqrt_f32(dx * dx + dz * dz)
	length_3 := math.sqrt_f32(dx * dx + dy * dy + dz * dz)
	bend_scale := math.min(math.max(length_3 * 0.18, f32(12)), f32(92))
	normal_x := f32(0)
	normal_z := f32(0)
	if length_xz > 0.001 {
		normal_x = -dz / length_xz
		normal_z = dx / length_xz
	}
	bend_x :=
		(from_node.x + to_node.x) * 0.5 +
		normal_x *
			feature_grid_signed_unit_f32(u64(id), HYDROLOGY_SEGMENT_BEND_X_SALT) *
			bend_scale
	bend_y :=
		(from_node.y + to_node.y) * 0.5 +
		feature_grid_signed_unit_f32(u64(id), HYDROLOGY_SEGMENT_BEND_Y_SALT) * bend_scale * 0.28
	bend_z :=
		(from_node.z + to_node.z) * 0.5 +
		normal_z *
			feature_grid_signed_unit_f32(u64(id), HYDROLOGY_SEGMENT_BEND_Z_SALT) *
			bend_scale
	return {
		id = id,
		owner = owner,
		kind = kind,
		from_node_id = from_node.id,
		to_node_id = to_node.id,
		source_biome_id = water_feature_segment_source_biome_id(from_node, to_node),
		from_x = from_node.x,
		from_y = from_node.y,
		from_z = from_node.z,
		bend_x = bend_x,
		bend_y = bend_y,
		bend_z = bend_z,
		to_x = to_node.x,
		to_y = to_node.y,
		to_z = to_node.z,
		water_level_blocks = (from_node.water_level_blocks + to_node.water_level_blocks) * 0.5,
		influence_radius_blocks = math.max(f32(6), width * 0.5),
		floor_depression_blocks = (from_node.floor_depression_blocks +
			to_node.floor_depression_blocks) *
		0.45,
	}
}

water_feature_surface_segment_should_exist :: proc(
	segment: WaterFeatureSegment,
	from_node, to_node: WaterFeatureNode,
) -> bool {
	if water_feature_source_water_group(from_node.source_biome_id) !=
	   water_feature_source_water_group(to_node.source_biome_id) {
		return false
	}
	roll := feature_grid_unit_f32(u64(segment.id), HYDROLOGY_SEGMENT_EXISTENCE_SALT)
	chance := f32(0.10)
	if from_node.kind == .Surface_River || to_node.kind == .Surface_River {
		chance += 0.16
	}
	if from_node.kind == .Surface_Lake && to_node.kind == .Surface_Lake {
		chance -= 0.08
	}
	level_delta := math.abs(from_node.water_level_blocks - to_node.water_level_blocks)
	if level_delta < 4 {
		chance += 0.08
	}
	if from_node.influence_radius_blocks > 50 || to_node.influence_radius_blocks > 50 {
		chance += 0.04
	}
	return roll < math.clamp(chance, f32(0.04), f32(0.38))
}

water_feature_subterranean_segment_should_exist :: proc(
	segment: WaterFeatureSegment,
	from_node, to_node: WaterFeatureNode,
) -> bool {
	if water_feature_source_water_group(from_node.source_biome_id) !=
	   water_feature_source_water_group(to_node.source_biome_id) {
		return false
	}
	roll := feature_grid_unit_f32(u64(segment.id), HYDROLOGY_SEGMENT_EXISTENCE_SALT)
	chance := f32(0.28)
	if from_node.kind == .Underground_River || to_node.kind == .Underground_River {
		chance += 0.10
	}
	if from_node.kind == .Aquifer && to_node.kind == .Aquifer {
		chance -= 0.12
	}
	if from_node.kind == .Flooded_Region || to_node.kind == .Flooded_Region {
		chance += 0.12
	}
	return roll < math.clamp(chance, f32(0.08), f32(0.54))
}

water_feature_id_from_owner :: proc {
	water_feature_id_from_owner_2,
	water_feature_id_from_owner_3,
}

water_feature_id_from_owner_2 :: proc(
	key: FeatureGridKey,
	owner: FeatureGridCoord2,
	domain_salt: u64,
) -> FeatureID {
	h := feature_grid_key_hash(key)
	h = feature_grid_hash_combine(h, domain_salt)
	h = feature_grid_hash_combine(h, FEATURE_GRID_DIMENSION_2)
	h = feature_grid_hash_combine(h, feature_grid_hash_i32(owner.x))
	h = feature_grid_hash_combine(h, feature_grid_hash_i32(owner.z))
	return FeatureID(h)
}

water_feature_id_from_owner_3 :: proc(
	key: FeatureGridKey,
	owner: FeatureGridCoord3,
	domain_salt: u64,
) -> FeatureID {
	h := feature_grid_key_hash(key)
	h = feature_grid_hash_combine(h, domain_salt)
	h = feature_grid_hash_combine(h, FEATURE_GRID_DIMENSION_3)
	h = feature_grid_hash_combine(h, feature_grid_hash_i32(owner.x))
	h = feature_grid_hash_combine(h, feature_grid_hash_i32(owner.y))
	h = feature_grid_hash_combine(h, feature_grid_hash_i32(owner.z))
	return FeatureID(h)
}

water_feature_segment_id_from_nodes :: proc(
	from_node_id, to_node_id: FeatureID,
	kind: WaterFeatureKind,
) -> FeatureID {
	h := feature_grid_hash_combine(u64(from_node_id), HYDROLOGY_SEGMENT_ID_SALT)
	h = feature_grid_hash_combine(h, u64(to_node_id))
	h = feature_grid_hash_combine(h, u64(u8(kind)))
	return FeatureID(h)
}

water_feature_anchor_id_from_feature :: proc(feature_id: FeatureID, salt: u64) -> FeatureID {
	return FeatureID(feature_grid_hash_combine(u64(feature_id), salt))
}

//////////////////////////////////////
// Hydrology Sampling Methods
/////////////////////////////////////

hydrology_layer_surface_sample :: proc(
	key: FeatureGridKey,
	block_x, block_z: i32,
) -> HydrologyLayerSurfaceSample {
	sample := HydrologyLayerSurfaceSample {
		nearest_feature_kind    = .Sea,
		nearest_distance_blocks = BIOME_FIELD_NO_DISTANCE,
		water_level_blocks      = SEA_LEVEL_BLOCKS,
		water_biome_id          = .Temperate_Hills,
	}
	bounds := BlockBounds2 {
		min = {x = block_x, z = block_z},
		max = {x = block_x + 1, z = block_z + 1},
	}
	owner_range := feature_grid_owner_range_from_block_bounds(
		bounds,
		HYDROLOGY_SURFACE_SAMPLE_MARGIN_BLOCKS,
		HYDROLOGY_SURFACE_GRAPH_GRID_CONFIG,
	)

	for z := owner_range.min.z; z <= owner_range.max.z; z += 1 {
		for x := owner_range.min.x; x <= owner_range.max.x; x += 1 {
			owner := FeatureGridCoord2 {
				x = x,
				z = z,
			}
			node := water_feature_surface_node_from_owner(key, owner)
			if !water_feature_surface_node_should_emit(key, node) {
				continue
			}
			hydrology_layer_surface_sample_accumulate_node(&sample, node, block_x, block_z)
			hydrology_layer_surface_sample_accumulate_anchor(
				&sample,
				water_feature_node_anchor(node),
				block_x,
				block_z,
			)

			x_neighbor := FeatureGridCoord2 {
				x = x + 1,
				z = z,
			}
			z_neighbor := FeatureGridCoord2 {
				x = x,
				z = z + 1,
			}
			x_segment, x_segment_exists := water_feature_surface_segment_from_owners(
				key,
				owner,
				x_neighbor,
			)
			if x_segment_exists {
				hydrology_layer_surface_sample_accumulate_segment(
					&sample,
					x_segment,
					block_x,
					block_z,
				)
			}
			z_segment, z_segment_exists := water_feature_surface_segment_from_owners(
				key,
				owner,
				z_neighbor,
			)
			if z_segment_exists {
				hydrology_layer_surface_sample_accumulate_segment(
					&sample,
					z_segment,
					block_x,
					block_z,
				)
			}
		}
	}
	return sample
}

hydrology_layer_subterranean_sample :: proc(
	key: FeatureGridKey,
	block_x, block_y, block_z: i32,
) -> HydrologyLayerSubterraneanSample {
	sample := HydrologyLayerSubterraneanSample {
		nearest_feature_kind    = .Aquifer,
		nearest_distance_blocks = BIOME_FIELD_NO_DISTANCE,
		water_level_blocks      = f32(block_y),
		water_biome_id          = .Buried_Aquifer_Caves,
	}
	bounds := BlockBounds3 {
		min = {x = block_x, y = block_y, z = block_z},
		max = {x = block_x + 1, y = block_y + 1, z = block_z + 1},
	}
	owner_range := feature_grid_owner_range_from_block_bounds(
		bounds,
		HYDROLOGY_SUBTERRANEAN_SAMPLE_MARGIN_BLOCKS,
		HYDROLOGY_SUBTERRANEAN_GRAPH_GRID_CONFIG,
	)

	for z := owner_range.min.z; z <= owner_range.max.z; z += 1 {
		for y := owner_range.min.y; y <= owner_range.max.y; y += 1 {
			for x := owner_range.min.x; x <= owner_range.max.x; x += 1 {
				owner := FeatureGridCoord3 {
					x = x,
					y = y,
					z = z,
				}
				node := water_feature_subterranean_node_from_owner(key, owner)
				if !water_feature_subterranean_node_should_emit(node) {
					continue
				}
				hydrology_layer_subterranean_sample_accumulate_node(
					&sample,
					node,
					block_x,
					block_y,
					block_z,
				)
				hydrology_layer_subterranean_sample_accumulate_anchor(
					&sample,
					water_feature_node_anchor(node),
					block_x,
					block_y,
					block_z,
				)

				x_neighbor := FeatureGridCoord3 {
					x = x + 1,
					y = y,
					z = z,
				}
				y_neighbor := FeatureGridCoord3 {
					x = x,
					y = y + 1,
					z = z,
				}
				z_neighbor := FeatureGridCoord3 {
					x = x,
					y = y,
					z = z + 1,
				}
				x_segment, x_segment_exists := water_feature_subterranean_segment_from_owners(
					key,
					owner,
					x_neighbor,
				)
				if x_segment_exists {
					hydrology_layer_subterranean_sample_accumulate_segment(
						&sample,
						x_segment,
						block_x,
						block_y,
						block_z,
					)
				}
				y_segment, y_segment_exists := water_feature_subterranean_segment_from_owners(
					key,
					owner,
					y_neighbor,
				)
				if y_segment_exists {
					hydrology_layer_subterranean_sample_accumulate_segment(
						&sample,
						y_segment,
						block_x,
						block_y,
						block_z,
					)
				}
				z_segment, z_segment_exists := water_feature_subterranean_segment_from_owners(
					key,
					owner,
					z_neighbor,
				)
				if z_segment_exists {
					hydrology_layer_subterranean_sample_accumulate_segment(
						&sample,
						z_segment,
						block_x,
						block_y,
						block_z,
					)
				}
			}
		}
	}
	return sample
}

hydrology_layer_surface_sample_from_region :: proc(
	region: ^GenerationRegion,
	block_x, block_z: i32,
) -> HydrologyLayerSurfaceSample {
	log.assert(
		generation_region_bounds_contains_block_xz(region.bounds, block_x, block_z),
		"surface hydrology region sample must be inside the Generation Region X/Z bounds",
	)
	sample := HydrologyLayerSurfaceSample {
		nearest_feature_kind    = .Sea,
		nearest_distance_blocks = BIOME_FIELD_NO_DISTANCE,
		water_level_blocks      = SEA_LEVEL_BLOCKS,
		water_biome_id          = .Temperate_Hills,
	}
	bounds := BlockBounds2 {
		min = {x = block_x, z = block_z},
		max = {x = block_x + 1, z = block_z + 1},
	}
	owner_range := feature_grid_owner_range_from_block_bounds(
		bounds,
		HYDROLOGY_SURFACE_SAMPLE_MARGIN_BLOCKS,
		HYDROLOGY_SURFACE_GRAPH_GRID_CONFIG,
	)
	for i := u32(0); i < region.water_feature_node_count; i += 1 {
		node := region.water_feature_nodes[i]
		if !water_feature_kind_is_surface(node.kind) ||
		   !generation_region_owner_range_contains_owner_2(
				   owner_range,
				   {x = node.owner.x, z = node.owner.z},
			   ) {
			continue
		}
		hydrology_layer_surface_sample_accumulate_node(&sample, node, block_x, block_z)
	}
	for i := u32(0); i < region.water_feature_segment_count; i += 1 {
		segment := region.water_feature_segments[i]
		if !water_feature_kind_is_surface(segment.kind) ||
		   !generation_region_owner_range_contains_owner_2(
				   owner_range,
				   {x = segment.owner.x, z = segment.owner.z},
			   ) {
			continue
		}
		hydrology_layer_surface_sample_accumulate_segment(&sample, segment, block_x, block_z)
	}
	for i := u32(0); i < region.water_feature_anchor_count; i += 1 {
		anchor := region.water_feature_anchors[i]
		if anchor.kind == .Aquifer_Breach ||
		   anchor.kind == .Underground_River_Link ||
		   anchor.kind == .Flooded_Cave_Link ||
		   !generation_region_owner_range_contains_owner_2(
				   owner_range,
				   {x = anchor.owner.x, z = anchor.owner.z},
			   ) {
			continue
		}
		hydrology_layer_surface_sample_accumulate_anchor(&sample, anchor, block_x, block_z)
	}
	return sample
}

hydrology_layer_subterranean_sample_from_region :: proc(
	region: ^GenerationRegion,
	block_x, block_y, block_z: i32,
) -> HydrologyLayerSubterraneanSample {
	log.assert(
		generation_region_bounds_contains_block(region.bounds, block_x, block_y, block_z),
		"subterranean hydrology region sample must be inside the Generation Region bounds",
	)
	sample := HydrologyLayerSubterraneanSample {
		nearest_feature_kind    = .Aquifer,
		nearest_distance_blocks = BIOME_FIELD_NO_DISTANCE,
		water_level_blocks      = f32(block_y),
		water_biome_id          = .Buried_Aquifer_Caves,
	}
	bounds := BlockBounds3 {
		min = {x = block_x, y = block_y, z = block_z},
		max = {x = block_x + 1, y = block_y + 1, z = block_z + 1},
	}
	owner_range := feature_grid_owner_range_from_block_bounds(
		bounds,
		HYDROLOGY_SUBTERRANEAN_SAMPLE_MARGIN_BLOCKS,
		HYDROLOGY_SUBTERRANEAN_GRAPH_GRID_CONFIG,
	)
	for i := u32(0); i < region.water_feature_node_count; i += 1 {
		node := region.water_feature_nodes[i]
		if !water_feature_kind_is_subterranean(node.kind) ||
		   !generation_region_owner_range_contains_owner_3(owner_range, node.owner) {
			continue
		}
		hydrology_layer_subterranean_sample_accumulate_node(
			&sample,
			node,
			block_x,
			block_y,
			block_z,
		)
	}
	for i := u32(0); i < region.water_feature_segment_count; i += 1 {
		segment := region.water_feature_segments[i]
		if !water_feature_kind_is_subterranean(segment.kind) ||
		   !generation_region_owner_range_contains_owner_3(owner_range, segment.owner) {
			continue
		}
		hydrology_layer_subterranean_sample_accumulate_segment(
			&sample,
			segment,
			block_x,
			block_y,
			block_z,
		)
	}
	for i := u32(0); i < region.water_feature_anchor_count; i += 1 {
		anchor := region.water_feature_anchors[i]
		if anchor.kind == .Shoreline ||
		   anchor.kind == .Lakebed_Breach ||
		   anchor.kind == .River_Bank ||
		   !generation_region_owner_range_contains_owner_3(owner_range, anchor.owner) {
			continue
		}
		hydrology_layer_subterranean_sample_accumulate_anchor(
			&sample,
			anchor,
			block_x,
			block_y,
			block_z,
		)
	}
	return sample
}

hydrology_layer_surface_sample_accumulate_node :: proc(
	sample: ^HydrologyLayerSurfaceSample,
	node: WaterFeatureNode,
	block_x, block_z: i32,
) {
	if !water_feature_kind_is_surface(node.kind) || node.kind == .Sea {
		return
	}
	distance := hydrology_distance_2(f32(block_x) + 0.5, f32(block_z) + 0.5, node.x, node.z)
	influence := hydrology_feature_influence(
		distance,
		node.influence_radius_blocks,
		HYDROLOGY_SURFACE_BANK_FALLOFF_BLOCKS,
	)
	if influence <= 0 {
		return
	}
	sample.feature_count += 1
	hydrology_layer_surface_sample_note_nearest(
		sample,
		node.id,
		node.kind,
		node.water_level_blocks,
		distance,
	)
	if node.kind == .Surface_Lake {
		sample.basin_influence = math.max(sample.basin_influence, influence)
	} else {
		sample.channel_influence = math.max(sample.channel_influence, influence)
	}
	hydrology_layer_surface_sample_note_water_level(
		sample,
		node.water_level_blocks,
		node.source_biome_id,
		influence,
	)
	sample.floor_depression_blocks = math.max(
		sample.floor_depression_blocks,
		node.floor_depression_blocks * influence,
	)
	sample.bank_smoothing_strength = math.max(sample.bank_smoothing_strength, influence)
}

hydrology_layer_surface_sample_accumulate_segment :: proc(
	sample: ^HydrologyLayerSurfaceSample,
	segment: WaterFeatureSegment,
	block_x, block_z: i32,
) {
	if !water_feature_kind_is_surface(segment.kind) || segment.kind == .Sea {
		return
	}
	distance := hydrology_distance_to_water_segment_2(
		segment,
		f32(block_x) + 0.5,
		f32(block_z) + 0.5,
	)
	influence := hydrology_feature_influence(
		distance,
		segment.influence_radius_blocks,
		HYDROLOGY_SURFACE_BANK_FALLOFF_BLOCKS,
	)
	if influence <= 0 {
		return
	}
	sample.feature_count += 1
	hydrology_layer_surface_sample_note_nearest(
		sample,
		segment.id,
		segment.kind,
		segment.water_level_blocks,
		distance,
	)
	sample.channel_influence = math.max(sample.channel_influence, influence)
	hydrology_layer_surface_sample_note_water_level(
		sample,
		segment.water_level_blocks,
		segment.source_biome_id,
		influence,
	)
	sample.floor_depression_blocks = math.max(
		sample.floor_depression_blocks,
		segment.floor_depression_blocks * influence,
	)
	sample.bank_smoothing_strength = math.max(sample.bank_smoothing_strength, influence)
}

hydrology_layer_surface_sample_accumulate_anchor :: proc(
	sample: ^HydrologyLayerSurfaceSample,
	anchor: WaterFeatureAnchor,
	block_x, block_z: i32,
) {
	if anchor.kind == .Aquifer_Breach ||
	   anchor.kind == .Underground_River_Link ||
	   anchor.kind == .Flooded_Cave_Link {
		return
	}
	distance := hydrology_distance_2(f32(block_x) + 0.5, f32(block_z) + 0.5, anchor.x, anchor.z)
	influence := hydrology_feature_influence(distance, anchor.influence_radius_blocks, 12)
	if influence <= 0 {
		return
	}
	sample.anchor_count += 1
	sample.anchor_connection_weight = math.max(sample.anchor_connection_weight, influence)
}

hydrology_layer_subterranean_sample_accumulate_node :: proc(
	sample: ^HydrologyLayerSubterraneanSample,
	node: WaterFeatureNode,
	block_x, block_y, block_z: i32,
) {
	if !water_feature_kind_is_subterranean(node.kind) {
		return
	}
	distance := hydrology_distance_3(
		f32(block_x) + 0.5,
		f32(block_y) + 0.5,
		f32(block_z) + 0.5,
		node.x,
		node.y,
		node.z,
	)
	influence := hydrology_feature_influence(
		distance,
		node.influence_radius_blocks,
		HYDROLOGY_SUBTERRANEAN_FALLOFF_BLOCKS,
	)
	if influence <= 0 {
		return
	}
	sample.feature_count += 1
	hydrology_layer_subterranean_sample_note_nearest(
		sample,
		node.id,
		node.kind,
		node.water_level_blocks,
		distance,
	)
	#partial switch node.kind {
	case .Aquifer:
		sample.aquifer_influence = math.max(sample.aquifer_influence, influence)
	case .Underground_River:
		sample.channel_influence = math.max(sample.channel_influence, influence)
	case .Flooded_Region:
		sample.flooded_region_influence = math.max(sample.flooded_region_influence, influence)
	}
	hydrology_layer_subterranean_sample_note_water_level(
		sample,
		node.water_level_blocks,
		node.source_biome_id,
		influence,
	)
	sample.floor_depression_blocks = math.max(
		sample.floor_depression_blocks,
		node.floor_depression_blocks * influence,
	)
}

hydrology_layer_subterranean_sample_accumulate_segment :: proc(
	sample: ^HydrologyLayerSubterraneanSample,
	segment: WaterFeatureSegment,
	block_x, block_y, block_z: i32,
) {
	if !water_feature_kind_is_subterranean(segment.kind) {
		return
	}
	distance := hydrology_distance_to_water_segment_3(
		segment,
		f32(block_x) + 0.5,
		f32(block_y) + 0.5,
		f32(block_z) + 0.5,
	)
	influence := hydrology_feature_influence(
		distance,
		segment.influence_radius_blocks,
		HYDROLOGY_SUBTERRANEAN_FALLOFF_BLOCKS,
	)
	if influence <= 0 {
		return
	}
	sample.feature_count += 1
	hydrology_layer_subterranean_sample_note_nearest(
		sample,
		segment.id,
		segment.kind,
		segment.water_level_blocks,
		distance,
	)
	sample.channel_influence = math.max(sample.channel_influence, influence)
	hydrology_layer_subterranean_sample_note_water_level(
		sample,
		segment.water_level_blocks,
		segment.source_biome_id,
		influence,
	)
	sample.floor_depression_blocks = math.max(
		sample.floor_depression_blocks,
		segment.floor_depression_blocks * influence,
	)
}

hydrology_layer_subterranean_sample_accumulate_anchor :: proc(
	sample: ^HydrologyLayerSubterraneanSample,
	anchor: WaterFeatureAnchor,
	block_x, block_y, block_z: i32,
) {
	if anchor.kind == .Shoreline || anchor.kind == .Lakebed_Breach || anchor.kind == .River_Bank {
		return
	}
	distance := hydrology_distance_3(
		f32(block_x) + 0.5,
		f32(block_y) + 0.5,
		f32(block_z) + 0.5,
		anchor.x,
		anchor.y,
		anchor.z,
	)
	influence := hydrology_feature_influence(distance, anchor.influence_radius_blocks, 18)
	if influence <= 0 {
		return
	}
	sample.anchor_count += 1
	sample.cave_connection_weight = math.max(sample.cave_connection_weight, influence)
}

hydrology_layer_surface_sample_note_nearest :: proc(
	sample: ^HydrologyLayerSurfaceSample,
	feature_id: FeatureID,
	kind: WaterFeatureKind,
	water_level_blocks: f32,
	distance: f32,
) {
	if sample.nearest_feature_id == FeatureID(0) || distance < sample.nearest_distance_blocks {
		sample.nearest_feature_id = feature_id
		sample.nearest_feature_kind = kind
		sample.nearest_distance_blocks = distance
		sample.water_level_blocks = water_level_blocks
	}
}

hydrology_layer_surface_sample_note_water_level :: proc(
	sample: ^HydrologyLayerSurfaceSample,
	water_level_blocks: f32,
	water_biome_id: BiomeID,
	influence: f32,
) {
	if influence <= 0 {
		return
	}
	if sample.water_level_influence <= 0 {
		sample.water_level_influence = influence
		sample.water_level_blocks = water_level_blocks
		sample.water_biome_id = water_biome_id
		return
	}
	if water_feature_source_water_group(water_biome_id) !=
	   water_feature_source_water_group(sample.water_biome_id) {
		sample.water_material_conflict_influence = math.max(
			sample.water_material_conflict_influence,
			math.min(sample.water_level_influence, influence),
		)
	}
	if influence > sample.water_level_influence {
		sample.water_level_influence = influence
		sample.water_level_blocks = water_level_blocks
		sample.water_biome_id = water_biome_id
	}
}

hydrology_layer_subterranean_sample_note_nearest :: proc(
	sample: ^HydrologyLayerSubterraneanSample,
	feature_id: FeatureID,
	kind: WaterFeatureKind,
	water_level_blocks: f32,
	distance: f32,
) {
	if sample.nearest_feature_id == FeatureID(0) || distance < sample.nearest_distance_blocks {
		sample.nearest_feature_id = feature_id
		sample.nearest_feature_kind = kind
		sample.nearest_distance_blocks = distance
		sample.water_level_blocks = water_level_blocks
	}
}

hydrology_layer_subterranean_sample_note_water_level :: proc(
	sample: ^HydrologyLayerSubterraneanSample,
	water_level_blocks: f32,
	water_biome_id: BiomeID,
	influence: f32,
) {
	if influence <= 0 {
		return
	}
	if sample.water_level_influence <= 0 {
		sample.water_level_influence = influence
		sample.water_level_blocks = water_level_blocks
		sample.water_biome_id = water_biome_id
		return
	}
	if water_feature_source_water_group(water_biome_id) !=
	   water_feature_source_water_group(sample.water_biome_id) {
		sample.water_material_conflict_influence = math.max(
			sample.water_material_conflict_influence,
			math.min(sample.water_level_influence, influence),
		)
	}
	if influence > sample.water_level_influence {
		sample.water_level_influence = influence
		sample.water_level_blocks = water_level_blocks
		sample.water_biome_id = water_biome_id
	}
}

//////////////////////////////////////
// Hydrology Shaping Methods
/////////////////////////////////////

hydrology_layer_apply_surface :: proc(
	target: BiomeShapeTarget,
	sample: HydrologyLayerSurfaceSample,
) -> BiomeShapeTarget {
	result := target
	water_influence := math.max(sample.basin_influence, sample.channel_influence)
	if water_influence <= 0 {
		return result
	}
	conflict_gate :=
		f32(1.0) - math.smoothstep(f32(0.18), f32(0.55), sample.water_material_conflict_influence)
	if conflict_gate <= 0 {
		return result
	}

	height_above_water := result.surface_height_blocks - sample.water_level_blocks
	basin_support := 1.0 - math.smoothstep(f32(18), f32(54), math.max(height_above_water, f32(0)))
	channel_support :=
		1.0 - math.smoothstep(f32(42), f32(96), math.max(height_above_water, f32(0)))
	basin_influence := sample.basin_influence * basin_support * conflict_gate
	channel_influence := sample.channel_influence * channel_support * conflict_gate
	shaping_influence := math.max(basin_influence, channel_influence)
	if shaping_influence <= 0 {
		return result
	}

	water_floor_height :=
		sample.water_level_blocks -
		math.max(f32(1.0), sample.floor_depression_blocks * 0.35 + 0.75)
	if result.surface_height_blocks > water_floor_height {
		max_cut :=
			sample.floor_depression_blocks * (1.35 + shaping_influence * 1.75) +
			channel_influence * 4.0
		target_floor := math.max(water_floor_height, result.surface_height_blocks - max_cut)
		carve_strength := math.clamp(shaping_influence * 0.82, f32(0), f32(0.82))
		result.surface_height_blocks = regional_terrain_field_lerp(
			result.surface_height_blocks,
			target_floor,
			carve_strength,
		)
	} else {
		result.surface_height_blocks -= sample.floor_depression_blocks * 0.28 * shaping_influence
	}
	result.local_detail_amplitude_blocks = math.max(
		f32(0),
		result.local_detail_amplitude_blocks *
		(1.0 - sample.bank_smoothing_strength * shaping_influence * 0.35),
	)
	result.cliff_bias = regional_terrain_field_saturate(
		result.cliff_bias * (1.0 - sample.bank_smoothing_strength * shaping_influence * 0.45),
	)
	result.terrace_strength = regional_terrain_field_saturate(
		result.terrace_strength * (1.0 - basin_influence * 0.25),
	)
	result.shoreline_width_blocks = math.max(
		SEA_COMPRESSION_MIN_SHORELINE_WIDTH_BLOCKS,
		result.shoreline_width_blocks + shaping_influence * 8.0,
	)
	result.underwater_floor_depression_blocks +=
		sample.floor_depression_blocks * shaping_influence * 0.25
	result.swamp_shallowness = regional_terrain_field_saturate(
		result.swamp_shallowness + basin_influence * 0.25,
	)
	return result
}

hydrology_layer_apply_subterranean :: proc(
	target: BiomeShapeTarget,
	sample: HydrologyLayerSubterraneanSample,
) -> BiomeShapeTarget {
	result := target
	water_influence := math.max(
		sample.aquifer_influence,
		math.max(sample.channel_influence, sample.flooded_region_influence),
	)
	if water_influence <= 0 {
		return result
	}

	result.surface_height_blocks -= sample.floor_depression_blocks * 0.35
	result.cave_openness = regional_terrain_field_saturate(
		result.cave_openness +
		sample.aquifer_influence * 0.10 +
		sample.channel_influence * 0.16 +
		sample.flooded_region_influence * 0.22,
	)
	result.local_detail_amplitude_blocks = math.max(
		f32(0),
		result.local_detail_amplitude_blocks * (1.0 - water_influence * 0.25),
	)
	result.underwater_floor_depression_blocks += sample.floor_depression_blocks * 0.35
	result.swamp_shallowness = regional_terrain_field_saturate(
		result.swamp_shallowness + water_influence * 0.20,
	)
	return result
}

//////////////////////////////////////
// Hydrology Math Methods
/////////////////////////////////////

hydrology_feature_influence :: proc(distance, radius, falloff_blocks: f32) -> f32 {
	if radius <= 0 {
		return 0
	}
	if distance <= radius {
		return 1
	}
	falloff := math.max(f32(1), falloff_blocks)
	if distance >= radius + falloff {
		return 0
	}
	return math.smoothstep(f32(0), f32(1), (radius + falloff - distance) / falloff)
}

hydrology_distance_2 :: proc(x, z, target_x, target_z: f32) -> f32 {
	dx := x - target_x
	dz := z - target_z
	return math.sqrt_f32(dx * dx + dz * dz)
}

hydrology_distance_3 :: proc(x, y, z, target_x, target_y, target_z: f32) -> f32 {
	dx := x - target_x
	dy := y - target_y
	dz := z - target_z
	return math.sqrt_f32(dx * dx + dy * dy + dz * dz)
}

hydrology_distance_to_water_segment_2 :: proc(segment: WaterFeatureSegment, x, z: f32) -> f32 {
	return math.min(
		hydrology_distance_to_segment_2(
			x,
			z,
			segment.from_x,
			segment.from_z,
			segment.bend_x,
			segment.bend_z,
		),
		hydrology_distance_to_segment_2(
			x,
			z,
			segment.bend_x,
			segment.bend_z,
			segment.to_x,
			segment.to_z,
		),
	)
}

hydrology_distance_to_water_segment_3 :: proc(segment: WaterFeatureSegment, x, y, z: f32) -> f32 {
	return math.min(
		hydrology_distance_to_segment_3(
			x,
			y,
			z,
			segment.from_x,
			segment.from_y,
			segment.from_z,
			segment.bend_x,
			segment.bend_y,
			segment.bend_z,
		),
		hydrology_distance_to_segment_3(
			x,
			y,
			z,
			segment.bend_x,
			segment.bend_y,
			segment.bend_z,
			segment.to_x,
			segment.to_y,
			segment.to_z,
		),
	)
}

hydrology_distance_to_segment_2 :: proc(x, z, from_x, from_z, to_x, to_z: f32) -> f32 {
	seg_x := to_x - from_x
	seg_z := to_z - from_z
	len_sq := seg_x * seg_x + seg_z * seg_z
	if len_sq <= 0 {
		return hydrology_distance_2(x, z, from_x, from_z)
	}
	t := math.clamp(((x - from_x) * seg_x + (z - from_z) * seg_z) / len_sq, f32(0), f32(1))
	nearest_x := from_x + seg_x * t
	nearest_z := from_z + seg_z * t
	return hydrology_distance_2(x, z, nearest_x, nearest_z)
}

hydrology_distance_to_segment_3 :: proc(
	x, y, z, from_x, from_y, from_z, to_x, to_y, to_z: f32,
) -> f32 {
	seg_x := to_x - from_x
	seg_y := to_y - from_y
	seg_z := to_z - from_z
	len_sq := seg_x * seg_x + seg_y * seg_y + seg_z * seg_z
	if len_sq <= 0 {
		return hydrology_distance_3(x, y, z, from_x, from_y, from_z)
	}
	t := math.clamp(
		((x - from_x) * seg_x + (y - from_y) * seg_y + (z - from_z) * seg_z) / len_sq,
		f32(0),
		f32(1),
	)
	nearest_x := from_x + seg_x * t
	nearest_y := from_y + seg_y * t
	nearest_z := from_z + seg_z * t
	return hydrology_distance_3(x, y, z, nearest_x, nearest_y, nearest_z)
}

//////////////////////////////////////
// Debug Methods
/////////////////////////////////////

when ODIN_DEBUG {

	hydrology_debug_contract_checks_run :: proc() {
		key := feature_grid_key_make(0x123456789abcdef0, 1)
		next_version_key := feature_grid_key_make(key.world_seed, key.generator_version + 1)

		owner := FeatureGridCoord2 {
			x = -1,
			z = 2,
		}
		node := water_feature_surface_node_from_owner(key, owner)
		node_again := water_feature_surface_node_from_owner(key, owner)
		next_version_node := water_feature_surface_node_from_owner(next_version_key, owner)
		log.assert(node.id == node_again.id, "surface water feature IDs must be stable")
		log.assert(
			node.id != next_version_node.id,
			"surface water feature IDs must include generator version",
		)
		log.assert(
			water_feature_kind_is_surface(node.kind),
			"surface water owner returned a non-surface Water Feature",
		)

		underground_owner := FeatureGridCoord3 {
			x = 0,
			y = -1,
			z = 1,
		}
		underground_node := water_feature_subterranean_node_from_owner(key, underground_owner)
		log.assert(
			water_feature_kind_is_subterranean(underground_node.kind),
			"subterranean water owner returned a non-subterranean Water Feature",
		)

		segment, segment_exists := water_feature_surface_segment_from_owners(
			key,
			owner,
			{x = owner.x + 1, z = owner.z},
		)
		_ = segment_exists
		log.assert(
			segment.from_node_id == node.id,
			"surface Water Feature Graph segment must retain its source node",
		)
		incompatible_segment_checked := false
		for test_z := i32(-3); test_z <= 3 && !incompatible_segment_checked; test_z += 1 {
			for test_x := i32(-3); test_x <= 3 && !incompatible_segment_checked; test_x += 1 {
				test_owner := FeatureGridCoord2 {
					x = test_x,
					z = test_z,
				}
				test_neighbor := FeatureGridCoord2 {
					x = test_x + 1,
					z = test_z,
				}
				from_node := water_feature_surface_node_from_owner(key, test_owner)
				to_node := water_feature_surface_node_from_owner(key, test_neighbor)
				if water_feature_source_water_group(from_node.source_biome_id) ==
				   water_feature_source_water_group(to_node.source_biome_id) {
					continue
				}
				_, incompatible_exists := water_feature_surface_segment_from_owners(
					key,
					test_owner,
					test_neighbor,
				)
				log.assert(
					!incompatible_exists,
					"incompatible surface water source groups must not be connected by a river segment",
				)
				incompatible_segment_checked = true
			}
		}
		anchor := water_feature_node_anchor(underground_node)
		log.assert(
			anchor.kind == .Aquifer_Breach ||
			anchor.kind == .Underground_River_Link ||
			anchor.kind == .Flooded_Cave_Link,
			"subterranean Water Feature anchor kind mismatch",
		)

		surface_sample := hydrology_layer_surface_sample(
			key,
			i32(math.floor_f32(node.x)),
			i32(math.floor_f32(node.z)),
		)
		log.assert(
			surface_sample.feature_count > 0 && surface_sample.floor_depression_blocks > 0,
			"surface Hydrology Layer sample should find nearby water shaping input",
		)

		subterranean_sample := hydrology_layer_subterranean_sample(
			key,
			i32(math.floor_f32(underground_node.x)),
			i32(math.floor_f32(underground_node.y)),
			i32(math.floor_f32(underground_node.z)),
		)
		log.assert(
			subterranean_sample.feature_count > 0 &&
			subterranean_sample.floor_depression_blocks > 0,
			"subterranean Hydrology Layer sample should find nearby water shaping input",
		)

		synthetic_target := BiomeShapeTarget {
			biome_id                           = .Wet_Lowland_Marsh,
			surface_height_blocks              = SEA_LEVEL_BLOCKS + 4,
			relief_amplitude_blocks            = 4,
			ruggedness_response                = 0.2,
			cliff_bias                         = 0.4,
			terrace_strength                   = 0.2,
			cave_openness                      = 0.25,
			surface_layer_depth_blocks         = 4,
			local_detail_amplitude_blocks      = 4,
			shoreline_width_blocks             = 16,
			shoreline_slope                    = 0.3,
			underwater_floor_depression_blocks = 1,
			cliff_coast_bias                   = 0.1,
			swamp_shallowness                  = 0.2,
			seabed_roughness_blocks            = 1,
			fantasy_affinity                   = 0.1,
		}
		shaped := hydrology_layer_apply_surface(synthetic_target, surface_sample)
		log.assert(
			shaped.surface_height_blocks < synthetic_target.surface_height_blocks,
			"surface hydrology should depress terrain floors",
		)
		subterranean_shaped := hydrology_layer_apply_subterranean(
			synthetic_target,
			subterranean_sample,
		)
		log.assert(
			subterranean_shaped.cave_openness >= synthetic_target.cave_openness,
			"subterranean hydrology should open water-bearing cave shape targets",
		)

		log.debug("Hydrology Layer contract checks passed")
	}

	debug_hydrology_surface_samples_assert_equal :: proc(a, b: HydrologyLayerSurfaceSample) {
		log.assert(a.feature_count == b.feature_count, "surface hydrology feature count mismatch")
		log.assert(a.anchor_count == b.anchor_count, "surface hydrology anchor count mismatch")
		log.assert(
			a.nearest_feature_id == b.nearest_feature_id,
			"surface hydrology nearest feature ID mismatch",
		)
		log.assert(
			a.nearest_feature_kind == b.nearest_feature_kind,
			"surface hydrology nearest feature kind mismatch",
		)
		log.assert(
			debug_f32_approx_equal(a.floor_depression_blocks, b.floor_depression_blocks, 0.001),
			"surface hydrology floor depression mismatch",
		)
		log.assert(
			debug_f32_approx_equal(a.water_level_blocks, b.water_level_blocks, 0.001),
			"surface hydrology water level mismatch",
		)
		log.assert(a.water_biome_id == b.water_biome_id, "surface hydrology water biome mismatch")
		log.assert(
			debug_f32_approx_equal(
				a.water_material_conflict_influence,
				b.water_material_conflict_influence,
				0.001,
			),
			"surface hydrology water material conflict mismatch",
		)
		log.assert(
			debug_f32_approx_equal(a.basin_influence, b.basin_influence, 0.001),
			"surface hydrology basin influence mismatch",
		)
		log.assert(
			debug_f32_approx_equal(a.channel_influence, b.channel_influence, 0.001),
			"surface hydrology channel influence mismatch",
		)
	}

	debug_hydrology_subterranean_samples_assert_equal :: proc(
		a, b: HydrologyLayerSubterraneanSample,
	) {
		log.assert(
			a.feature_count == b.feature_count,
			"subterranean hydrology feature count mismatch",
		)
		log.assert(
			a.anchor_count == b.anchor_count,
			"subterranean hydrology anchor count mismatch",
		)
		log.assert(
			a.nearest_feature_id == b.nearest_feature_id,
			"subterranean hydrology nearest feature ID mismatch",
		)
		log.assert(
			a.nearest_feature_kind == b.nearest_feature_kind,
			"subterranean hydrology nearest feature kind mismatch",
		)
		log.assert(
			debug_f32_approx_equal(a.floor_depression_blocks, b.floor_depression_blocks, 0.001),
			"subterranean hydrology floor depression mismatch",
		)
		log.assert(
			debug_f32_approx_equal(a.water_level_blocks, b.water_level_blocks, 0.001),
			"subterranean hydrology water level mismatch",
		)
		log.assert(
			a.water_biome_id == b.water_biome_id,
			"subterranean hydrology water biome mismatch",
		)
		log.assert(
			debug_f32_approx_equal(
				a.water_material_conflict_influence,
				b.water_material_conflict_influence,
				0.001,
			),
			"subterranean hydrology water material conflict mismatch",
		)
		log.assert(
			debug_f32_approx_equal(a.aquifer_influence, b.aquifer_influence, 0.001),
			"subterranean hydrology aquifer influence mismatch",
		)
		log.assert(
			debug_f32_approx_equal(a.channel_influence, b.channel_influence, 0.001),
			"subterranean hydrology channel influence mismatch",
		)
		log.assert(
			debug_f32_approx_equal(a.flooded_region_influence, b.flooded_region_influence, 0.001),
			"subterranean hydrology flooded region influence mismatch",
		)
	}

}
