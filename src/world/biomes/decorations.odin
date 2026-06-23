package biomes

import "core:log"
import math "core:math"

//////////////////////////////////////
// Decoration Types
/////////////////////////////////////

DecorationFamilyID :: enum u8 {
	Baseline_Tree,
	Dead_Ash_Tree,
	Fungal_Tree,
	Stone_Tree,
	Crystal_Growth_Cluster,
	Fern_Thicket,
	Ash_Bramble,
	Root_Cluster,
	Coral_DLA_Cluster,
	Ruin_Pillar_Set,
	Ruin_Hamlet,
	Watchtower_Ruin,
	Palisade_Fort,
	Cave_Ruin_Hall,
	Basalt_Column_Cluster,
	Lava_Vent,
}

DecorationPlacementKind :: enum u8 {
	Surface,
	Subterranean,
	Surface_And_Subterranean,
}

DecorationSurfaceDensityClass :: enum u8 {
	Sparse,
	Mixed,
	Grove,
}

DecorationFamilyProfile :: struct {
	placement_kind: DecorationPlacementKind,
	trunk_material: BiomeMaterialID,
	cap_material:   BiomeMaterialID,
	min_height:     u8,
	max_height:     u8,
	radius_blocks:  u8,
}

DecorationFeature :: struct {
	id:                  FeatureID,
	owner:               FeatureGridCoord2,
	slot_index:          u8,
	x, z:                f32,
	biome_id:            BiomeID,
	family_id:           DecorationFamilyID,
	height_blocks:       u8,
	radius_blocks:       u8,
	shape_variant:       u8,
	rotation_quarters:   u8,
	density_class:       DecorationSurfaceDensityClass,
	stand_count:         u8,
	stand_radius_blocks: u8,
	material_variant:    u8,
}

DecorationSurfacePlacementProfile :: struct {
	family_id:                       DecorationFamilyID,
	chance:                          f32,
	sparse_chance:                   f32,
	grove_chance:                    f32,
	slot_count:                      u8,
	max_stand_count:                 u8,
	stand_radius_blocks:             u8,
	wet_root_allowed:                bool,
	min_root_water_clearance_blocks: u8,
}

DecorationTreeBlockRole :: enum u8 {
	Trunk,
	Branch,
	Cap,
}

DecorationTreeSegment :: struct {
	from: IVec3,
	to:   IVec3,
	role: DecorationTreeBlockRole,
}

DecorationTreeCrown :: struct {
	center:    IVec3,
	radius_xz: u8,
	radius_y:  u8,
}

DecorationTreeShape :: struct {
	biome_id:      BiomeID,
	family_id:     DecorationFamilyID,
	variant_index: u8,
	height_blocks: u8,
	radius_blocks: u8,
	min_bound:     IVec3,
	max_bound:     IVec3,
	segment_count: u8,
	crown_count:   u8,
	segments:      [DECORATION_TREE_SHAPE_SEGMENT_CAPACITY]DecorationTreeSegment,
	crowns:        [DECORATION_TREE_SHAPE_CROWN_CAPACITY]DecorationTreeCrown,
}

//////////////////////////////////////
// Decoration Constants
/////////////////////////////////////

DECORATION_SURFACE_GRID_CONFIG :: FeatureGridConfig {
	domain           = .Surface,
	level            = .Micro,
	cell_size_blocks = 96,
	jitter_fraction  = 0.70,
}

DECORATION_SURFACE_INFLUENCE_MARGIN_BLOCKS :: 96
DECORATION_FAMILY_COUNT :: 16
DECORATION_SURFACE_SLOT_COUNT_MAX :: u8(3)
DECORATION_TREE_SHAPE_VARIANT_COUNT :: u8(6)
DECORATION_TREE_SHAPE_SEGMENT_CAPACITY :: 18
DECORATION_TREE_SHAPE_CROWN_CAPACITY :: 10
DECORATION_SURFACE_PATCH_CELL_SIZE_BLOCKS :: i32(256)
DECORATION_SURFACE_FEATURE_SALT :: u64(0x91a7c5d3e42f68b0)
DECORATION_SURFACE_ROLL_SALT :: u64(0x67c8b4319ad205ef)
DECORATION_SURFACE_FAMILY_ROLL_SALT :: u64(0x92d7b6814c3ef05a)
DECORATION_SURFACE_SLOT_SALT :: u64(0xb4f23a8971d6e05c)
DECORATION_SURFACE_SLOT_JITTER_X_SALT :: u64(0x3278d5ec019ab46f)
DECORATION_SURFACE_SLOT_JITTER_Z_SALT :: u64(0x8d35a19fc47062be)
DECORATION_SURFACE_PATCH_NOISE_SALT :: u64(0x31b6d4079efc8a52)
DECORATION_SURFACE_STAND_COUNT_SALT :: u64(0x75c4e9a12d6f830b)
DECORATION_MATERIAL_VARIANT_SALT :: u64(0x9f2b4160d8c75e3a)
DECORATION_HEIGHT_SALT :: u64(0x2c41a8f73d96e50b)
DECORATION_SHAPE_VARIANT_SALT :: u64(0x54f7cb2d8319a06e)
DECORATION_ROTATION_SALT :: u64(0xdd31b8a4720cef59)
DECORATION_CAVE_ROLL_SALT :: u64(0x7d5a0c3e91b6842f)
#assert(u32(DecorationFamilyID.Lava_Vent) + 1 == DECORATION_FAMILY_COUNT)

//////////////////////////////////////
// Decoration Methods
/////////////////////////////////////

decoration_family_profile_for :: proc(family_id: DecorationFamilyID) -> DecorationFamilyProfile {
	switch family_id {
	case .Baseline_Tree:
		return {
			placement_kind = .Surface,
			trunk_material = .Dirt,
			cap_material = .Grass,
			min_height = 5,
			max_height = 8,
			radius_blocks = 2,
		}
	case .Dead_Ash_Tree:
		return {
			placement_kind = .Surface,
			trunk_material = .Corrupted_Ash,
			cap_material = .Stone,
			min_height = 4,
			max_height = 7,
			radius_blocks = 1,
		}
	case .Fungal_Tree:
		return {
			placement_kind = .Subterranean,
			trunk_material = .Dirt,
			cap_material = .Wet_Marsh,
			min_height = 4,
			max_height = 7,
			radius_blocks = 2,
		}
	case .Stone_Tree:
		return {
			placement_kind = .Surface,
			trunk_material = .Stone,
			cap_material = .Crystal,
			min_height = 6,
			max_height = 10,
			radius_blocks = 2,
		}
	case .Crystal_Growth_Cluster:
		return {
			placement_kind = .Surface_And_Subterranean,
			trunk_material = .Crystal,
			cap_material = .Crystal,
			min_height = 3,
			max_height = 6,
			radius_blocks = 1,
		}
	case .Fern_Thicket:
		return {
			placement_kind = .Surface,
			trunk_material = .Dirt,
			cap_material = .Moss,
			min_height = 2,
			max_height = 4,
			radius_blocks = 4,
		}
	case .Ash_Bramble:
		return {
			placement_kind = .Surface_And_Subterranean,
			trunk_material = .Corrupt_Mud,
			cap_material = .Corrupted_Ash,
			min_height = 2,
			max_height = 5,
			radius_blocks = 5,
		}
	case .Root_Cluster:
		return {
			placement_kind = .Subterranean,
			trunk_material = .Forest_Litter,
			cap_material = .Moss,
			min_height = 3,
			max_height = 7,
			radius_blocks = 5,
		}
	case .Coral_DLA_Cluster:
		return {
			placement_kind = .Subterranean,
			trunk_material = .Aquifer_Wall,
			cap_material = .Crystal,
			min_height = 3,
			max_height = 6,
			radius_blocks = 4,
		}
	case .Ruin_Pillar_Set:
		return {
			placement_kind = .Surface_And_Subterranean,
			trunk_material = .Stone,
			cap_material = .Aquifer_Wall,
			min_height = 5,
			max_height = 9,
			radius_blocks = 8,
		}
	case .Ruin_Hamlet:
		return {
			placement_kind = .Surface,
			trunk_material = .Stone,
			cap_material = .Dirt,
			min_height = 5,
			max_height = 8,
			radius_blocks = 18,
		}
	case .Watchtower_Ruin:
		return {
			placement_kind = .Surface_And_Subterranean,
			trunk_material = .Stone,
			cap_material = .Aquifer_Wall,
			min_height = 7,
			max_height = 11,
			radius_blocks = 20,
		}
	case .Palisade_Fort:
		return {
			placement_kind = .Surface,
			trunk_material = .Forest_Litter,
			cap_material = .Stone,
			min_height = 7,
			max_height = 11,
			radius_blocks = 18,
		}
	case .Cave_Ruin_Hall:
		return {
			placement_kind = .Subterranean,
			trunk_material = .Stone,
			cap_material = .Aquifer_Wall,
			min_height = 5,
			max_height = 9,
			radius_blocks = 8,
		}
	case .Basalt_Column_Cluster:
		return {
			placement_kind = .Surface_And_Subterranean,
			trunk_material = .Basalt,
			cap_material = .Stone,
			min_height = 4,
			max_height = 9,
			radius_blocks = 5,
		}
	case .Lava_Vent:
		return {
			placement_kind = .Surface_And_Subterranean,
			trunk_material = .Basalt,
			cap_material = .Lava,
			min_height = 2,
			max_height = 4,
			radius_blocks = 4,
		}
	}

	log.assertf(false, "unhandled Decoration Family Profile: %v", family_id)
	return {
		placement_kind = .Surface,
		trunk_material = .Stone,
		cap_material = .Stone,
		min_height = 1,
		max_height = 1,
		radius_blocks = 1,
	}
}

decoration_surface_placement_profile_for_biome :: proc(
	biome_id: BiomeID,
) -> (
	profile: DecorationSurfacePlacementProfile,
	found: bool,
) {
	switch biome_id {
	case .Temperate_Hills:
		return {
				family_id = .Baseline_Tree,
				chance = 0.34,
				sparse_chance = 0.10,
				grove_chance = 0.66,
				slot_count = 3,
				max_stand_count = 7,
				stand_radius_blocks = 19,
				wet_root_allowed = false,
				min_root_water_clearance_blocks = 7,
			},
			true
	case .Old_Growth_Forest:
		return {
				family_id = .Baseline_Tree,
				chance = 0.46,
				sparse_chance = 0.16,
				grove_chance = 0.78,
				slot_count = 3,
				max_stand_count = 12,
				stand_radius_blocks = 26,
				wet_root_allowed = false,
				min_root_water_clearance_blocks = 7,
			},
			true
	case .Wet_Lowland_Marsh:
		return {
				family_id = .Baseline_Tree,
				chance = 0.26,
				sparse_chance = 0.08,
				grove_chance = 0.52,
				slot_count = 3,
				max_stand_count = 5,
				stand_radius_blocks = 17,
				wet_root_allowed = true,
				min_root_water_clearance_blocks = 8,
			},
			true
	case .Corrupted_Ash_Forest:
		return {
				family_id = .Dead_Ash_Tree,
				chance = 0.28,
				sparse_chance = 0.08,
				grove_chance = 0.58,
				slot_count = 3,
				max_stand_count = 5,
				stand_radius_blocks = 18,
				wet_root_allowed = false,
				min_root_water_clearance_blocks = 7,
			},
			true
	case .Corrupted_Fen:
		return {
				family_id = .Dead_Ash_Tree,
				chance = 0.30,
				sparse_chance = 0.10,
				grove_chance = 0.60,
				slot_count = 3,
				max_stand_count = 6,
				stand_radius_blocks = 19,
				wet_root_allowed = true,
				min_root_water_clearance_blocks = 8,
			},
			true
	case .Basalt_Spire_Highlands:
		return {
				family_id = .Stone_Tree,
				chance = 0.22,
				sparse_chance = 0.06,
				grove_chance = 0.44,
				slot_count = 3,
				max_stand_count = 3,
				stand_radius_blocks = 14,
				wet_root_allowed = false,
				min_root_water_clearance_blocks = 10,
			},
			true
	case .Emberglass_Badlands:
		return {
				family_id = .Stone_Tree,
				chance = 0.20,
				sparse_chance = 0.05,
				grove_chance = 0.42,
				slot_count = 3,
				max_stand_count = 3,
				stand_radius_blocks = 14,
				wet_root_allowed = false,
				min_root_water_clearance_blocks = 12,
			},
			true
	case .Fungal_Vaults, .Crystal_Geode_Network, .Buried_Aquifer_Caves:
		return {}, false
	}
	return {}, false
}

decoration_surface_family_for_biome :: proc(
	biome_id: BiomeID,
) -> (
	family_id: DecorationFamilyID,
	chance: f32,
	found: bool,
) {
	profile, profile_found := decoration_surface_placement_profile_for_biome(biome_id)
	if !profile_found {
		return {}, 0, false
	}
	return profile.family_id, profile.chance, true
}

decoration_cave_family_for_node :: proc(
	node: CaveNetworkNode,
) -> (
	family_id: DecorationFamilyID,
	chance: f32,
	found: bool,
) {
	switch node.biome_id {
	case .Fungal_Vaults:
		if node.major_region ||
		   node.role == .Resource_Chamber ||
		   node.role == .Water_Linked_Region {
			roll := feature_grid_unit_f32(u64(node.id), DECORATION_SURFACE_FAMILY_ROLL_SALT)
			if roll < 0.30 {
				return .Root_Cluster, 1.00, true
			}
			if roll < 0.58 {
				return .Fungal_Tree, 0.42, true
			}
			if roll < 0.86 {
				return .Coral_DLA_Cluster, 1.00, true
			}
			return .Cave_Ruin_Hall, 0.32, true
		}
	case .Crystal_Geode_Network:
		if node.kind == .Geode_Chamber || node.role == .Resource_Chamber || node.major_region {
			roll := feature_grid_unit_f32(u64(node.id), DECORATION_SURFACE_FAMILY_ROLL_SALT)
			if roll < 0.50 {
				return .Crystal_Growth_Cluster, 0.42, true
			}
			if roll < 0.62 {
				return .Ruin_Pillar_Set, 0.34, true
			}
			if roll < 0.70 {
				return .Cave_Ruin_Hall, 0.28, true
			}
			return .Coral_DLA_Cluster, 1.00, true
		}
	case .Buried_Aquifer_Caves:
		if node.kind == .Underground_Lake || node.role == .Water_Linked_Region {
			roll := feature_grid_unit_f32(u64(node.id), DECORATION_SURFACE_FAMILY_ROLL_SALT)
			if roll < 0.38 {
				return .Coral_DLA_Cluster, 1.00, true
			}
			if roll < 0.64 {
				return .Root_Cluster, 1.00, true
			}
			if roll < 0.86 {
				return .Fungal_Tree, 0.28, true
			}
			return .Cave_Ruin_Hall, 0.24, true
		}
	case .Temperate_Hills,
	     .Old_Growth_Forest,
	     .Basalt_Spire_Highlands,
	     .Emberglass_Badlands,
	     .Wet_Lowland_Marsh,
	     .Corrupted_Ash_Forest,
	     .Corrupted_Fen:
		return {}, 0, false
	}
	return {}, 0, false
}

decoration_feature_height_from_id :: proc(id: FeatureID, profile: DecorationFamilyProfile) -> u8 {
	if profile.max_height <= profile.min_height {
		return profile.min_height
	}
	height_range := u32(profile.max_height - profile.min_height)
	roll := feature_grid_unit_f32(u64(id), DECORATION_HEIGHT_SALT)
	offset := u8(math.floor_f32(roll * f32(height_range + 1)))
	if offset > u8(height_range) {
		offset = u8(height_range)
	}
	return profile.min_height + offset
}

decoration_surface_slot_point_from_owner :: proc(
	key: FeatureGridKey,
	owner: FeatureGridCoord2,
	slot_index: u8,
) -> FeaturePoint2 {
	feature_grid_config_validate(DECORATION_SURFACE_GRID_CONFIG)

	base_id := feature_id_from_grid_coord(key, DECORATION_SURFACE_GRID_CONFIG, owner)
	hash := feature_grid_hash_combine(u64(base_id), DECORATION_SURFACE_SLOT_SALT)
	hash = feature_grid_hash_combine(hash, u64(slot_index))
	cell_size := f32(DECORATION_SURFACE_GRID_CONFIG.cell_size_blocks)
	jitter_radius := cell_size * 0.5 * DECORATION_SURFACE_GRID_CONFIG.jitter_fraction

	return {
		id = FeatureID(feature_grid_hash_combine(hash, DECORATION_SURFACE_FEATURE_SALT)),
		owner = owner,
		x = feature_grid_cell_center(owner.x, cell_size) +
		feature_grid_signed_unit_f32(hash, DECORATION_SURFACE_SLOT_JITTER_X_SALT) * jitter_radius,
		z = feature_grid_cell_center(owner.z, cell_size) +
		feature_grid_signed_unit_f32(hash, DECORATION_SURFACE_SLOT_JITTER_Z_SALT) * jitter_radius,
	}
}

decoration_tree_shape_count_for :: proc(biome_id: BiomeID, family_id: DecorationFamilyID) -> u8 {
	switch biome_id {
	case .Temperate_Hills, .Old_Growth_Forest:
		if family_id == .Baseline_Tree {
			return DECORATION_TREE_SHAPE_VARIANT_COUNT
		}
	case .Wet_Lowland_Marsh:
		if family_id == .Baseline_Tree {
			return DECORATION_TREE_SHAPE_VARIANT_COUNT
		}
	case .Corrupted_Ash_Forest, .Corrupted_Fen:
		if family_id == .Dead_Ash_Tree {
			return DECORATION_TREE_SHAPE_VARIANT_COUNT
		}
	case .Basalt_Spire_Highlands, .Emberglass_Badlands:
		if family_id == .Stone_Tree {
			return DECORATION_TREE_SHAPE_VARIANT_COUNT
		}
	case .Fungal_Vaults, .Buried_Aquifer_Caves:
		if family_id == .Fungal_Tree {
			return DECORATION_TREE_SHAPE_VARIANT_COUNT
		}
	case .Crystal_Geode_Network:
	}
	return 0
}

decoration_tree_shape_variant_from_id :: proc(
	id: FeatureID,
	biome_id: BiomeID,
	family_id: DecorationFamilyID,
) -> u8 {
	count := decoration_tree_shape_count_for(biome_id, family_id)
	if count == 0 {
		return 0
	}
	roll := feature_grid_unit_f32(u64(id), DECORATION_SHAPE_VARIANT_SALT)
	index := u8(math.floor_f32(roll * f32(count)))
	if index >= count {
		index = count - 1
	}
	return index
}

decoration_tree_rotation_from_id :: proc(id: FeatureID) -> u8 {
	roll := feature_grid_unit_f32(u64(id), DECORATION_ROTATION_SALT)
	rotation := u8(math.floor_f32(roll * 4.0))
	if rotation > 3 {
		rotation = 3
	}
	return rotation
}

decoration_surface_patch_strength_for_point :: proc(
	key: FeatureGridKey,
	point: FeaturePoint2,
	biome_id: BiomeID,
) -> f32 {
	block_x := i32(math.floor_f32(point.x))
	block_z := i32(math.floor_f32(point.z))
	noise := regional_terrain_field_value_noise_2(
		key,
		block_x,
		block_z,
		DECORATION_SURFACE_PATCH_CELL_SIZE_BLOCKS,
		DECORATION_SURFACE_PATCH_NOISE_SALT,
	)
	bias: f32
	switch biome_id {
	case .Temperate_Hills:
		bias = 0.08
	case .Old_Growth_Forest:
		bias = 0.18
	case .Wet_Lowland_Marsh:
		bias = -0.02
	case .Corrupted_Ash_Forest:
		bias = 0.04
	case .Corrupted_Fen:
		bias = 0.06
	case .Basalt_Spire_Highlands:
		bias = -0.10
	case .Emberglass_Badlands:
		bias = -0.14
	case .Fungal_Vaults, .Crystal_Geode_Network, .Buried_Aquifer_Caves:
		bias = 0
	}
	return math.clamp(noise * 0.5 + 0.5 + bias, f32(0), f32(1))
}

decoration_surface_density_class_from_strength :: proc(
	strength: f32,
) -> DecorationSurfaceDensityClass {
	if strength >= 0.55 {
		return .Grove
	}
	if strength <= 0.20 {
		return .Sparse
	}
	return .Mixed
}

decoration_surface_acceptance_chance :: proc(
	profile: DecorationSurfacePlacementProfile,
	density_class: DecorationSurfaceDensityClass,
) -> f32 {
	switch density_class {
	case .Sparse:
		return profile.sparse_chance
	case .Mixed:
		return profile.chance
	case .Grove:
		return profile.grove_chance
	}
	return profile.chance
}

decoration_surface_stand_count_from_id :: proc(
	id: FeatureID,
	profile: DecorationSurfacePlacementProfile,
	density_class: DecorationSurfaceDensityClass,
) -> u8 {
	if profile.max_stand_count <= 1 {
		return 1
	}
	roll := feature_grid_unit_f32(u64(id), DECORATION_SURFACE_STAND_COUNT_SALT)
	switch density_class {
	case .Sparse:
		return 1
	case .Mixed:
		count := u8(2)
		if profile.max_stand_count >= 4 && roll >= 0.78 {
			count = 3
		}
		if count > profile.max_stand_count {
			return profile.max_stand_count
		}
		return count
	case .Grove:
		min_count := u8(2)
		if profile.max_stand_count >= 4 {
			min_count = 3
		}
		if profile.max_stand_count <= min_count {
			return profile.max_stand_count
		}
		count_range := u32(profile.max_stand_count - min_count)
		offset := u8(math.floor_f32(roll * f32(count_range + 1)))
		if offset > u8(count_range) {
			offset = u8(count_range)
		}
		return min_count + offset
	}
	return 1
}

decoration_material_variant_from_id :: proc(id: FeatureID) -> u8 {
	roll := feature_grid_unit_f32(u64(id), DECORATION_MATERIAL_VARIANT_SALT)
	index := u8(math.floor_f32(roll * 8.0))
	if index > 7 {
		index = 7
	}
	return index
}

decoration_surface_family_select :: proc(
	id: FeatureID,
	biome_id: BiomeID,
	default_family_id: DecorationFamilyID,
	density_class: DecorationSurfaceDensityClass,
	slot_index: u8,
) -> DecorationFamilyID {
	roll := feature_grid_unit_f32(u64(id), DECORATION_SURFACE_FAMILY_ROLL_SALT)
	grove_bonus := f32(0)
	if density_class == .Grove {
		grove_bonus = 0.10
	} else if density_class == .Sparse {
		grove_bonus = -0.06
	}

	if slot_index == 0 {
		switch biome_id {
		case .Temperate_Hills:
			if roll < 0.08 {
				return .Fern_Thicket
			}
		case .Old_Growth_Forest:
			if roll < 0.14 + grove_bonus {
				return .Fern_Thicket
			}
			if roll < 0.20 + grove_bonus {
				return .Root_Cluster
			}
		case .Wet_Lowland_Marsh:
			if roll < 0.24 {
				return .Fern_Thicket
			}
		case .Corrupted_Ash_Forest:
			if roll < 0.20 + grove_bonus {
				return .Ash_Bramble
			}
		case .Corrupted_Fen:
			if roll < 0.38 {
				return .Ash_Bramble
			}
		case .Basalt_Spire_Highlands:
			if roll < 0.18 {
				return .Basalt_Column_Cluster
			}
			if roll < 0.28 {
				return .Crystal_Growth_Cluster
			}
		case .Emberglass_Badlands:
			if roll < 0.24 {
				return .Lava_Vent
			}
			if roll < 0.44 {
				return .Basalt_Column_Cluster
			}
		case .Fungal_Vaults, .Crystal_Geode_Network, .Buried_Aquifer_Caves:
		}
		return default_family_id
	}

	if slot_index == 1 {
		switch biome_id {
		case .Temperate_Hills:
			if roll < 0.72 + grove_bonus {
				return .Fern_Thicket
			}
		case .Old_Growth_Forest:
			if roll < 0.52 + grove_bonus {
				return .Fern_Thicket
			}
			if roll < 0.84 + grove_bonus {
				return .Root_Cluster
			}
		case .Wet_Lowland_Marsh:
			if roll < 0.72 {
				return .Fern_Thicket
			}
		case .Corrupted_Ash_Forest:
			if roll < 0.82 + grove_bonus {
				return .Ash_Bramble
			}
		case .Corrupted_Fen:
			if roll < 0.88 {
				return .Ash_Bramble
			}
		case .Basalt_Spire_Highlands:
			if roll < 0.58 {
				return .Basalt_Column_Cluster
			}
			if roll < 0.78 {
				return .Crystal_Growth_Cluster
			}
		case .Emberglass_Badlands:
			if roll < 0.44 {
				return .Lava_Vent
			}
			if roll < 0.82 {
				return .Basalt_Column_Cluster
			}
		case .Fungal_Vaults, .Crystal_Geode_Network, .Buried_Aquifer_Caves:
		}
		return default_family_id
	}

	switch biome_id {
	case .Temperate_Hills:
		if density_class == .Grove && roll < 0.025 {
			return .Ruin_Hamlet
		}
		if roll >= 0.025 && roll < 0.050 {
			return .Watchtower_Ruin
		}
		if roll >= 0.050 && roll < 0.075 {
			return .Ruin_Pillar_Set
		}
	case .Old_Growth_Forest:
		if density_class == .Grove && roll < 0.020 {
			return .Ruin_Hamlet
		}
		if roll >= 0.020 && roll < 0.045 {
			return .Watchtower_Ruin
		}
		if roll >= 0.045 && roll < 0.070 {
			return .Ruin_Pillar_Set
		}
		if roll < 0.24 {
			return .Root_Cluster
		}
	case .Wet_Lowland_Marsh:
		if density_class == .Grove && roll < 0.018 {
			return .Ruin_Hamlet
		}
		if roll >= 0.018 && roll < 0.045 {
			return .Ruin_Pillar_Set
		}
		if roll < 0.28 {
			return .Fern_Thicket
		}
	case .Corrupted_Ash_Forest:
		if roll < 0.035 {
			return .Palisade_Fort
		}
		if roll < 0.080 {
			return .Ruin_Pillar_Set
		}
		if roll < 0.24 {
			return .Ash_Bramble
		}
	case .Corrupted_Fen:
		if roll < 0.028 {
			return .Palisade_Fort
		}
		if roll < 0.070 {
			return .Ruin_Pillar_Set
		}
		if roll < 0.36 {
			return .Ash_Bramble
		}
	case .Basalt_Spire_Highlands:
		if roll < 0.045 {
			return .Palisade_Fort
		}
		if roll < 0.095 {
			return .Ruin_Pillar_Set
		}
		if roll < 0.52 {
			return .Basalt_Column_Cluster
		}
		if roll < 0.68 {
			return .Crystal_Growth_Cluster
		}
	case .Emberglass_Badlands:
		if roll < 0.040 {
			return .Palisade_Fort
		}
		if roll < 0.090 {
			return .Ruin_Pillar_Set
		}
		if roll < 0.34 {
			return .Lava_Vent
		}
		if roll < 0.66 {
			return .Basalt_Column_Cluster
		}
	case .Fungal_Vaults, .Crystal_Geode_Network, .Buried_Aquifer_Caves:
	}
	return default_family_id
}

decoration_surface_feature_make :: proc(
	point: FeaturePoint2,
	owner: FeatureGridCoord2,
	slot_index: u8,
	biome_id: BiomeID,
	placement: DecorationSurfacePlacementProfile,
	density_class: DecorationSurfaceDensityClass,
) -> DecorationFeature {
	family_id := decoration_surface_family_select(
		point.id,
		biome_id,
		placement.family_id,
		density_class,
		slot_index,
	)
	profile := decoration_family_profile_for(family_id)
	stand_count := decoration_surface_stand_count_from_id(point.id, placement, density_class)
	if family_id != .Baseline_Tree && family_id != .Dead_Ash_Tree && family_id != .Stone_Tree {
		stand_count = 1
	}
	return {
		id = point.id,
		owner = owner,
		slot_index = slot_index,
		x = point.x,
		z = point.z,
		biome_id = biome_id,
		family_id = family_id,
		height_blocks = decoration_feature_height_from_id(point.id, profile),
		radius_blocks = profile.radius_blocks,
		shape_variant = decoration_tree_shape_variant_from_id(point.id, biome_id, family_id),
		rotation_quarters = decoration_tree_rotation_from_id(point.id),
		density_class = density_class,
		stand_count = stand_count,
		stand_radius_blocks = placement.stand_radius_blocks,
		material_variant = decoration_material_variant_from_id(point.id),
	}
}

decoration_surface_feature_from_owner :: proc(
	key: FeatureGridKey,
	owner: FeatureGridCoord2,
) -> (
	feature: DecorationFeature,
	found: bool,
) {
	for slot_index := u8(0); slot_index < DECORATION_SURFACE_SLOT_COUNT_MAX; slot_index += 1 {
		point := decoration_surface_slot_point_from_owner(key, owner, slot_index)
		block_x := i32(math.floor_f32(point.x))
		block_z := i32(math.floor_f32(point.z))
		surface_sample := surface_biome_field_sample(key, block_x, block_z)
		if surface_sample.cell_count == 0 {
			continue
		}

		biome_id := surface_sample.cells[surface_sample.dominant_index].biome_id
		placement, placement_found := decoration_surface_placement_profile_for_biome(biome_id)
		if !placement_found || slot_index >= placement.slot_count {
			continue
		}
		patch_strength := decoration_surface_patch_strength_for_point(key, point, biome_id)
		density_class := decoration_surface_density_class_from_strength(patch_strength)
		chance := decoration_surface_acceptance_chance(placement, density_class)
		roll := feature_grid_unit_f32(u64(point.id), DECORATION_SURFACE_ROLL_SALT)
		if roll > chance {
			continue
		}

		feature = decoration_surface_feature_make(
			point,
			owner,
			slot_index,
			biome_id,
			placement,
			density_class,
		)
		found = true
		return
	}
	return
}

decoration_cave_feature_roll_accepts :: proc(node: CaveNetworkNode, chance: f32) -> bool {
	if chance <= 0 {
		return false
	}
	return feature_grid_unit_f32(u64(node.id), DECORATION_CAVE_ROLL_SALT) <= chance
}

decoration_tree_shape_make :: proc(
	biome_id: BiomeID,
	family_id: DecorationFamilyID,
	variant_index: u8,
	height_blocks: u8,
	radius_blocks: u8,
	min_bound, max_bound: IVec3,
) -> DecorationTreeShape {
	return {
		biome_id = biome_id,
		family_id = family_id,
		variant_index = variant_index,
		height_blocks = height_blocks,
		radius_blocks = radius_blocks,
		min_bound = min_bound,
		max_bound = max_bound,
	}
}

decoration_tree_shape_segment_add :: proc(
	shape: ^DecorationTreeShape,
	from, to: IVec3,
	role: DecorationTreeBlockRole,
) {
	log.assert(
		shape.segment_count < DECORATION_TREE_SHAPE_SEGMENT_CAPACITY,
		"Decoration Tree Shape segment capacity exceeded",
	)
	shape.segments[shape.segment_count] = {
		from = from,
		to   = to,
		role = role,
	}
	shape.segment_count += 1
}

decoration_tree_shape_crown_add :: proc(
	shape: ^DecorationTreeShape,
	center: IVec3,
	radius_xz, radius_y: u8,
) {
	log.assert(
		shape.crown_count < DECORATION_TREE_SHAPE_CROWN_CAPACITY,
		"Decoration Tree Shape crown capacity exceeded",
	)
	shape.crowns[shape.crown_count] = {
		center    = center,
		radius_xz = radius_xz,
		radius_y  = radius_y,
	}
	shape.crown_count += 1
}

decoration_tree_shape_for :: proc(
	biome_id: BiomeID,
	family_id: DecorationFamilyID,
	variant_index: u8,
) -> DecorationTreeShape {
	variant := variant_index % DECORATION_TREE_SHAPE_VARIANT_COUNT
	switch biome_id {
	case .Temperate_Hills, .Old_Growth_Forest:
		if family_id == .Baseline_Tree {
			return decoration_tree_shape_temperate(variant)
		}
	case .Wet_Lowland_Marsh:
		if family_id == .Baseline_Tree {
			return decoration_tree_shape_marsh(variant)
		}
	case .Corrupted_Ash_Forest, .Corrupted_Fen:
		if family_id == .Dead_Ash_Tree {
			return decoration_tree_shape_dead_ash(variant)
		}
	case .Basalt_Spire_Highlands, .Emberglass_Badlands:
		if family_id == .Stone_Tree {
			return decoration_tree_shape_stone(variant)
		}
	case .Fungal_Vaults, .Buried_Aquifer_Caves:
		if family_id == .Fungal_Tree {
			return decoration_tree_shape_fungal(biome_id, variant)
		}
	case .Crystal_Geode_Network:
	}
	return decoration_tree_shape_temperate(variant)
}

decoration_tree_shape_temperate :: proc(variant: u8) -> DecorationTreeShape {
	switch variant {
	case 0:
		shape := decoration_tree_shape_make(
			.Temperate_Hills,
			.Baseline_Tree,
			variant,
			16,
			7,
			{x = -7, y = 1, z = -7},
			{x = 7, y = 18, z = 7},
		)
		decoration_tree_shape_segment_add(
			&shape,
			{x = 0, y = 1, z = 0},
			{x = 0, y = 11, z = 0},
			.Trunk,
		)
		decoration_tree_shape_segment_add(
			&shape,
			{x = 0, y = 1, z = 0},
			{x = 1, y = 3, z = 0},
			.Trunk,
		)
		decoration_tree_shape_segment_add(
			&shape,
			{x = 0, y = 1, z = 0},
			{x = -1, y = 3, z = 0},
			.Trunk,
		)
		decoration_tree_shape_segment_add(
			&shape,
			{x = 0, y = 1, z = 0},
			{x = 0, y = 3, z = 1},
			.Trunk,
		)
		decoration_tree_shape_segment_add(
			&shape,
			{x = 0, y = 6, z = 0},
			{x = 5, y = 9, z = 1},
			.Branch,
		)
		decoration_tree_shape_segment_add(
			&shape,
			{x = 0, y = 7, z = 0},
			{x = -5, y = 10, z = -2},
			.Branch,
		)
		decoration_tree_shape_segment_add(
			&shape,
			{x = 0, y = 8, z = 0},
			{x = 2, y = 11, z = -5},
			.Branch,
		)
		decoration_tree_shape_segment_add(
			&shape,
			{x = 0, y = 9, z = 0},
			{x = -2, y = 12, z = 4},
			.Branch,
		)
		decoration_tree_shape_segment_add(
			&shape,
			{x = 0, y = 10, z = 0},
			{x = 4, y = 13, z = 4},
			.Branch,
		)
		decoration_tree_shape_crown_add(&shape, {x = 0, y = 14, z = 0}, 5, 2)
		decoration_tree_shape_crown_add(&shape, {x = 5, y = 10, z = 1}, 3, 2)
		decoration_tree_shape_crown_add(&shape, {x = -5, y = 11, z = -2}, 3, 2)
		decoration_tree_shape_crown_add(&shape, {x = 2, y = 12, z = -5}, 3, 1)
		decoration_tree_shape_crown_add(&shape, {x = -2, y = 13, z = 4}, 3, 1)
		decoration_tree_shape_crown_add(&shape, {x = 4, y = 14, z = 4}, 2, 1)
		return shape
	case 1:
		shape := decoration_tree_shape_make(
			.Temperate_Hills,
			.Baseline_Tree,
			variant,
			15,
			7,
			{x = -7, y = 1, z = -6},
			{x = 7, y = 17, z = 7},
		)
		decoration_tree_shape_segment_add(
			&shape,
			{x = 0, y = 1, z = 0},
			{x = 0, y = 7, z = 0},
			.Trunk,
		)
		decoration_tree_shape_segment_add(
			&shape,
			{x = 0, y = 7, z = 0},
			{x = -3, y = 12, z = -1},
			.Trunk,
		)
		decoration_tree_shape_segment_add(
			&shape,
			{x = 0, y = 7, z = 0},
			{x = 3, y = 12, z = 2},
			.Trunk,
		)
		decoration_tree_shape_segment_add(
			&shape,
			{x = -1, y = 8, z = 0},
			{x = -6, y = 10, z = -3},
			.Branch,
		)
		decoration_tree_shape_segment_add(
			&shape,
			{x = 1, y = 8, z = 1},
			{x = 6, y = 10, z = 4},
			.Branch,
		)
		decoration_tree_shape_segment_add(
			&shape,
			{x = -2, y = 10, z = -1},
			{x = -4, y = 13, z = 3},
			.Branch,
		)
		decoration_tree_shape_segment_add(
			&shape,
			{x = 2, y = 10, z = 1},
			{x = 4, y = 13, z = -3},
			.Branch,
		)
		decoration_tree_shape_crown_add(&shape, {x = -3, y = 13, z = -1}, 4, 2)
		decoration_tree_shape_crown_add(&shape, {x = 3, y = 13, z = 2}, 4, 2)
		decoration_tree_shape_crown_add(&shape, {x = -6, y = 11, z = -3}, 3, 1)
		decoration_tree_shape_crown_add(&shape, {x = 6, y = 11, z = 4}, 3, 1)
		decoration_tree_shape_crown_add(&shape, {x = 0, y = 15, z = 1}, 3, 1)
		return shape
	case 2:
		shape := decoration_tree_shape_make(
			.Temperate_Hills,
			.Baseline_Tree,
			variant,
			17,
			6,
			{x = -6, y = 1, z = -7},
			{x = 7, y = 19, z = 6},
		)
		decoration_tree_shape_segment_add(
			&shape,
			{x = 0, y = 1, z = 0},
			{x = 1, y = 12, z = -1},
			.Trunk,
		)
		decoration_tree_shape_segment_add(
			&shape,
			{x = 1, y = 6, z = -1},
			{x = 6, y = 9, z = -4},
			.Branch,
		)
		decoration_tree_shape_segment_add(
			&shape,
			{x = 1, y = 7, z = -1},
			{x = -4, y = 10, z = 3},
			.Branch,
		)
		decoration_tree_shape_segment_add(
			&shape,
			{x = 1, y = 9, z = -1},
			{x = 3, y = 12, z = 5},
			.Branch,
		)
		decoration_tree_shape_segment_add(
			&shape,
			{x = 1, y = 10, z = -1},
			{x = -2, y = 14, z = -6},
			.Branch,
		)
		decoration_tree_shape_segment_add(
			&shape,
			{x = 1, y = 12, z = -1},
			{x = 4, y = 15, z = 0},
			.Branch,
		)
		decoration_tree_shape_crown_add(&shape, {x = 1, y = 15, z = -1}, 4, 2)
		decoration_tree_shape_crown_add(&shape, {x = 6, y = 10, z = -4}, 3, 1)
		decoration_tree_shape_crown_add(&shape, {x = -4, y = 11, z = 3}, 3, 1)
		decoration_tree_shape_crown_add(&shape, {x = 3, y = 13, z = 5}, 3, 1)
		decoration_tree_shape_crown_add(&shape, {x = -2, y = 15, z = -6}, 2, 1)
		decoration_tree_shape_crown_add(&shape, {x = 4, y = 16, z = 0}, 2, 1)
		return shape
	case 3:
		shape := decoration_tree_shape_make(
			.Temperate_Hills,
			.Baseline_Tree,
			variant,
			13,
			8,
			{x = -8, y = 1, z = -7},
			{x = 8, y = 16, z = 7},
		)
		decoration_tree_shape_segment_add(
			&shape,
			{x = 0, y = 1, z = 0},
			{x = 0, y = 8, z = 0},
			.Trunk,
		)
		decoration_tree_shape_segment_add(
			&shape,
			{x = 0, y = 4, z = 0},
			{x = 7, y = 8, z = -1},
			.Branch,
		)
		decoration_tree_shape_segment_add(
			&shape,
			{x = 0, y = 5, z = 0},
			{x = -7, y = 9, z = 1},
			.Branch,
		)
		decoration_tree_shape_segment_add(
			&shape,
			{x = 0, y = 6, z = 0},
			{x = 3, y = 10, z = 6},
			.Branch,
		)
		decoration_tree_shape_segment_add(
			&shape,
			{x = 0, y = 7, z = 0},
			{x = -4, y = 11, z = -5},
			.Branch,
		)
		decoration_tree_shape_segment_add(
			&shape,
			{x = 0, y = 8, z = 0},
			{x = 1, y = 13, z = 0},
			.Branch,
		)
		decoration_tree_shape_crown_add(&shape, {x = 0, y = 12, z = 0}, 4, 2)
		decoration_tree_shape_crown_add(&shape, {x = 7, y = 9, z = -1}, 3, 1)
		decoration_tree_shape_crown_add(&shape, {x = -7, y = 10, z = 1}, 3, 1)
		decoration_tree_shape_crown_add(&shape, {x = 3, y = 11, z = 6}, 3, 1)
		decoration_tree_shape_crown_add(&shape, {x = -4, y = 12, z = -5}, 3, 1)
		return shape
	case 4:
		shape := decoration_tree_shape_make(
			.Temperate_Hills,
			.Baseline_Tree,
			variant,
			18,
			8,
			{x = -8, y = 1, z = -8},
			{x = 8, y = 20, z = 8},
		)
		decoration_tree_shape_segment_add(
			&shape,
			{x = 0, y = 1, z = 0},
			{x = 0, y = 13, z = 0},
			.Trunk,
		)
		decoration_tree_shape_segment_add(
			&shape,
			{x = 0, y = 1, z = 0},
			{x = 2, y = 4, z = 1},
			.Trunk,
		)
		decoration_tree_shape_segment_add(
			&shape,
			{x = 0, y = 1, z = 0},
			{x = -2, y = 4, z = -1},
			.Trunk,
		)
		decoration_tree_shape_segment_add(
			&shape,
			{x = 0, y = 1, z = 0},
			{x = -1, y = 4, z = 2},
			.Trunk,
		)
		decoration_tree_shape_segment_add(
			&shape,
			{x = 0, y = 7, z = 0},
			{x = 6, y = 10, z = 3},
			.Branch,
		)
		decoration_tree_shape_segment_add(
			&shape,
			{x = 0, y = 8, z = 0},
			{x = -6, y = 11, z = -4},
			.Branch,
		)
		decoration_tree_shape_segment_add(
			&shape,
			{x = 0, y = 9, z = 0},
			{x = 5, y = 13, z = -5},
			.Branch,
		)
		decoration_tree_shape_segment_add(
			&shape,
			{x = 0, y = 10, z = 0},
			{x = -4, y = 14, z = 5},
			.Branch,
		)
		decoration_tree_shape_segment_add(
			&shape,
			{x = 0, y = 12, z = 0},
			{x = 2, y = 16, z = 2},
			.Branch,
		)
		decoration_tree_shape_crown_add(&shape, {x = 0, y = 16, z = 0}, 5, 2)
		decoration_tree_shape_crown_add(&shape, {x = 6, y = 11, z = 3}, 3, 2)
		decoration_tree_shape_crown_add(&shape, {x = -6, y = 12, z = -4}, 3, 2)
		decoration_tree_shape_crown_add(&shape, {x = 5, y = 14, z = -5}, 3, 1)
		decoration_tree_shape_crown_add(&shape, {x = -4, y = 15, z = 5}, 3, 1)
		decoration_tree_shape_crown_add(&shape, {x = 2, y = 17, z = 2}, 3, 1)
		return shape
	case:
		shape := decoration_tree_shape_make(
			.Temperate_Hills,
			.Baseline_Tree,
			variant,
			14,
			6,
			{x = -6, y = 1, z = -6},
			{x = 6, y = 17, z = 6},
		)
		decoration_tree_shape_segment_add(
			&shape,
			{x = 0, y = 1, z = 0},
			{x = -1, y = 10, z = 1},
			.Trunk,
		)
		decoration_tree_shape_segment_add(
			&shape,
			{x = -1, y = 5, z = 1},
			{x = -5, y = 8, z = 4},
			.Branch,
		)
		decoration_tree_shape_segment_add(
			&shape,
			{x = -1, y = 6, z = 1},
			{x = 4, y = 9, z = 3},
			.Branch,
		)
		decoration_tree_shape_segment_add(
			&shape,
			{x = -1, y = 8, z = 1},
			{x = -3, y = 11, z = -4},
			.Branch,
		)
		decoration_tree_shape_segment_add(
			&shape,
			{x = -1, y = 9, z = 1},
			{x = 3, y = 12, z = -2},
			.Branch,
		)
		decoration_tree_shape_crown_add(&shape, {x = -1, y = 13, z = 1}, 4, 2)
		decoration_tree_shape_crown_add(&shape, {x = -5, y = 9, z = 4}, 3, 1)
		decoration_tree_shape_crown_add(&shape, {x = 4, y = 10, z = 3}, 3, 1)
		decoration_tree_shape_crown_add(&shape, {x = -3, y = 12, z = -4}, 3, 1)
		decoration_tree_shape_crown_add(&shape, {x = 3, y = 13, z = -2}, 2, 1)
		return shape
	}
}

decoration_tree_shape_marsh :: proc(variant: u8) -> DecorationTreeShape {
	shape := decoration_tree_shape_make(
		.Wet_Lowland_Marsh,
		.Baseline_Tree,
		variant,
		11,
		7,
		{x = -7, y = 1, z = -7},
		{x = 7, y = 14, z = 7},
	)
	switch variant {
	case 0:
		decoration_tree_shape_segment_add(
			&shape,
			{x = 0, y = 1, z = 0},
			{x = -1, y = 7, z = 0},
			.Trunk,
		)
		decoration_tree_shape_segment_add(
			&shape,
			{x = -1, y = 4, z = 0},
			{x = -6, y = 7, z = 3},
			.Branch,
		)
		decoration_tree_shape_segment_add(
			&shape,
			{x = -1, y = 5, z = 0},
			{x = 5, y = 8, z = -2},
			.Branch,
		)
		decoration_tree_shape_segment_add(
			&shape,
			{x = -1, y = 6, z = 0},
			{x = 0, y = 10, z = 5},
			.Branch,
		)
		decoration_tree_shape_crown_add(&shape, {x = -1, y = 10, z = 0}, 5, 1)
		decoration_tree_shape_crown_add(&shape, {x = -6, y = 8, z = 3}, 3, 1)
		decoration_tree_shape_crown_add(&shape, {x = 5, y = 9, z = -2}, 3, 1)
		decoration_tree_shape_crown_add(&shape, {x = 0, y = 11, z = 5}, 2, 1)
	case 1:
		decoration_tree_shape_segment_add(
			&shape,
			{x = 0, y = 1, z = 0},
			{x = 0, y = 5, z = 0},
			.Trunk,
		)
		decoration_tree_shape_segment_add(
			&shape,
			{x = 0, y = 5, z = 0},
			{x = 3, y = 9, z = 4},
			.Trunk,
		)
		decoration_tree_shape_segment_add(
			&shape,
			{x = 0, y = 5, z = 0},
			{x = -4, y = 9, z = -3},
			.Trunk,
		)
		decoration_tree_shape_segment_add(
			&shape,
			{x = 1, y = 6, z = 1},
			{x = 6, y = 8, z = 1},
			.Branch,
		)
		decoration_tree_shape_segment_add(
			&shape,
			{x = -1, y = 6, z = -1},
			{x = -6, y = 8, z = 2},
			.Branch,
		)
		decoration_tree_shape_crown_add(&shape, {x = 3, y = 10, z = 4}, 4, 1)
		decoration_tree_shape_crown_add(&shape, {x = -4, y = 10, z = -3}, 4, 1)
		decoration_tree_shape_crown_add(&shape, {x = 6, y = 9, z = 1}, 2, 1)
		decoration_tree_shape_crown_add(&shape, {x = -6, y = 9, z = 2}, 2, 1)
	case 2:
		decoration_tree_shape_segment_add(
			&shape,
			{x = 0, y = 1, z = 0},
			{x = 1, y = 7, z = 1},
			.Trunk,
		)
		decoration_tree_shape_segment_add(
			&shape,
			{x = 1, y = 4, z = 1},
			{x = 6, y = 6, z = -1},
			.Branch,
		)
		decoration_tree_shape_segment_add(
			&shape,
			{x = 1, y = 5, z = 1},
			{x = -3, y = 8, z = 6},
			.Branch,
		)
		decoration_tree_shape_segment_add(
			&shape,
			{x = 1, y = 7, z = 1},
			{x = 2, y = 10, z = -4},
			.Branch,
		)
		decoration_tree_shape_crown_add(&shape, {x = 1, y = 10, z = 1}, 5, 1)
		decoration_tree_shape_crown_add(&shape, {x = 6, y = 7, z = -1}, 2, 1)
		decoration_tree_shape_crown_add(&shape, {x = -3, y = 9, z = 6}, 3, 1)
		decoration_tree_shape_crown_add(&shape, {x = 2, y = 11, z = -4}, 2, 1)
	case 3:
		decoration_tree_shape_segment_add(
			&shape,
			{x = 0, y = 1, z = 0},
			{x = 0, y = 8, z = -1},
			.Trunk,
		)
		decoration_tree_shape_segment_add(
			&shape,
			{x = 0, y = 4, z = 0},
			{x = -6, y = 7, z = 0},
			.Branch,
		)
		decoration_tree_shape_segment_add(
			&shape,
			{x = 0, y = 5, z = 0},
			{x = 6, y = 7, z = 3},
			.Branch,
		)
		decoration_tree_shape_segment_add(
			&shape,
			{x = 0, y = 6, z = -1},
			{x = -2, y = 9, z = -6},
			.Branch,
		)
		decoration_tree_shape_crown_add(&shape, {x = 0, y = 11, z = -1}, 4, 1)
		decoration_tree_shape_crown_add(&shape, {x = -6, y = 8, z = 0}, 3, 1)
		decoration_tree_shape_crown_add(&shape, {x = 6, y = 8, z = 3}, 3, 1)
		decoration_tree_shape_crown_add(&shape, {x = -2, y = 10, z = -6}, 2, 1)
	case 4:
		decoration_tree_shape_segment_add(
			&shape,
			{x = 0, y = 1, z = 0},
			{x = -1, y = 6, z = 1},
			.Trunk,
		)
		decoration_tree_shape_segment_add(
			&shape,
			{x = -1, y = 3, z = 1},
			{x = -5, y = 5, z = -4},
			.Branch,
		)
		decoration_tree_shape_segment_add(
			&shape,
			{x = -1, y = 4, z = 1},
			{x = 4, y = 7, z = -5},
			.Branch,
		)
		decoration_tree_shape_segment_add(
			&shape,
			{x = -1, y = 5, z = 1},
			{x = -3, y = 9, z = 5},
			.Branch,
		)
		decoration_tree_shape_segment_add(
			&shape,
			{x = -1, y = 6, z = 1},
			{x = 3, y = 10, z = 2},
			.Branch,
		)
		decoration_tree_shape_crown_add(&shape, {x = -1, y = 10, z = 1}, 4, 1)
		decoration_tree_shape_crown_add(&shape, {x = -5, y = 6, z = -4}, 3, 1)
		decoration_tree_shape_crown_add(&shape, {x = 4, y = 8, z = -5}, 3, 1)
		decoration_tree_shape_crown_add(&shape, {x = -3, y = 10, z = 5}, 2, 1)
	case:
		decoration_tree_shape_segment_add(
			&shape,
			{x = 0, y = 1, z = 0},
			{x = 0, y = 6, z = 0},
			.Trunk,
		)
		decoration_tree_shape_segment_add(
			&shape,
			{x = 0, y = 3, z = 0},
			{x = -6, y = 6, z = 1},
			.Branch,
		)
		decoration_tree_shape_segment_add(
			&shape,
			{x = 0, y = 4, z = 0},
			{x = 5, y = 7, z = 3},
			.Branch,
		)
		decoration_tree_shape_segment_add(
			&shape,
			{x = 0, y = 5, z = 0},
			{x = 1, y = 9, z = -5},
			.Branch,
		)
		decoration_tree_shape_crown_add(&shape, {x = 0, y = 10, z = 0}, 5, 1)
		decoration_tree_shape_crown_add(&shape, {x = -6, y = 7, z = 1}, 3, 1)
		decoration_tree_shape_crown_add(&shape, {x = 5, y = 8, z = 3}, 3, 1)
		decoration_tree_shape_crown_add(&shape, {x = 1, y = 10, z = -5}, 2, 1)
	}
	return shape
}

decoration_tree_shape_dead_ash :: proc(variant: u8) -> DecorationTreeShape {
	shape := decoration_tree_shape_make(
		.Corrupted_Ash_Forest,
		.Dead_Ash_Tree,
		variant,
		15,
		7,
		{x = -8, y = 1, z = -8},
		{x = 8, y = 18, z = 8},
	)
	switch variant {
	case 0:
		decoration_tree_shape_segment_add(
			&shape,
			{x = 0, y = 1, z = 0},
			{x = 0, y = 12, z = 0},
			.Trunk,
		)
		decoration_tree_shape_segment_add(
			&shape,
			{x = 0, y = 4, z = 0},
			{x = 6, y = 7, z = 0},
			.Branch,
		)
		decoration_tree_shape_segment_add(
			&shape,
			{x = 0, y = 5, z = 0},
			{x = -5, y = 8, z = -3},
			.Branch,
		)
		decoration_tree_shape_segment_add(
			&shape,
			{x = 0, y = 7, z = 0},
			{x = 3, y = 11, z = 4},
			.Branch,
		)
		decoration_tree_shape_segment_add(
			&shape,
			{x = 0, y = 8, z = 0},
			{x = -2, y = 13, z = 5},
			.Branch,
		)
		decoration_tree_shape_segment_add(
			&shape,
			{x = 0, y = 10, z = 0},
			{x = 4, y = 15, z = -3},
			.Branch,
		)
		decoration_tree_shape_crown_add(&shape, {x = 6, y = 8, z = 0}, 1, 1)
		decoration_tree_shape_crown_add(&shape, {x = -5, y = 9, z = -3}, 1, 1)
		decoration_tree_shape_crown_add(&shape, {x = 3, y = 12, z = 4}, 1, 1)
	case 1:
		decoration_tree_shape_segment_add(
			&shape,
			{x = 0, y = 1, z = 0},
			{x = 1, y = 11, z = 0},
			.Trunk,
		)
		decoration_tree_shape_segment_add(
			&shape,
			{x = 1, y = 4, z = 0},
			{x = -7, y = 6, z = 2},
			.Branch,
		)
		decoration_tree_shape_segment_add(
			&shape,
			{x = 1, y = 5, z = 0},
			{x = 6, y = 8, z = -4},
			.Branch,
		)
		decoration_tree_shape_segment_add(
			&shape,
			{x = 1, y = 7, z = 0},
			{x = 0, y = 13, z = 5},
			.Branch,
		)
		decoration_tree_shape_segment_add(
			&shape,
			{x = 1, y = 8, z = 0},
			{x = -3, y = 12, z = -6},
			.Branch,
		)
		decoration_tree_shape_crown_add(&shape, {x = -7, y = 7, z = 2}, 1, 1)
		decoration_tree_shape_crown_add(&shape, {x = 6, y = 9, z = -4}, 1, 1)
		decoration_tree_shape_crown_add(&shape, {x = 0, y = 14, z = 5}, 1, 1)
	case 2:
		decoration_tree_shape_segment_add(
			&shape,
			{x = 0, y = 1, z = 0},
			{x = -1, y = 12, z = 1},
			.Trunk,
		)
		decoration_tree_shape_segment_add(
			&shape,
			{x = -1, y = 5, z = 1},
			{x = -7, y = 8, z = 4},
			.Branch,
		)
		decoration_tree_shape_segment_add(
			&shape,
			{x = -1, y = 6, z = 1},
			{x = 5, y = 8, z = -5},
			.Branch,
		)
		decoration_tree_shape_segment_add(
			&shape,
			{x = -1, y = 8, z = 1},
			{x = -4, y = 13, z = -4},
			.Branch,
		)
		decoration_tree_shape_segment_add(
			&shape,
			{x = -1, y = 9, z = 1},
			{x = 3, y = 14, z = 3},
			.Branch,
		)
		decoration_tree_shape_crown_add(&shape, {x = -7, y = 9, z = 4}, 1, 1)
		decoration_tree_shape_crown_add(&shape, {x = 5, y = 9, z = -5}, 1, 1)
		decoration_tree_shape_crown_add(&shape, {x = 3, y = 15, z = 3}, 1, 1)
	case 3:
		decoration_tree_shape_segment_add(
			&shape,
			{x = 0, y = 1, z = 0},
			{x = 0, y = 9, z = 0},
			.Trunk,
		)
		decoration_tree_shape_segment_add(
			&shape,
			{x = 0, y = 3, z = 0},
			{x = 7, y = 5, z = 4},
			.Branch,
		)
		decoration_tree_shape_segment_add(
			&shape,
			{x = 0, y = 4, z = 0},
			{x = -7, y = 7, z = 0},
			.Branch,
		)
		decoration_tree_shape_segment_add(
			&shape,
			{x = 0, y = 6, z = 0},
			{x = 2, y = 12, z = -6},
			.Branch,
		)
		decoration_tree_shape_segment_add(
			&shape,
			{x = 0, y = 7, z = 0},
			{x = -3, y = 12, z = 4},
			.Branch,
		)
		decoration_tree_shape_crown_add(&shape, {x = 7, y = 6, z = 4}, 1, 1)
		decoration_tree_shape_crown_add(&shape, {x = -7, y = 8, z = 0}, 1, 1)
	case 4:
		decoration_tree_shape_segment_add(
			&shape,
			{x = 0, y = 1, z = 0},
			{x = -1, y = 10, z = -1},
			.Trunk,
		)
		decoration_tree_shape_segment_add(
			&shape,
			{x = -1, y = 4, z = -1},
			{x = -6, y = 7, z = -5},
			.Branch,
		)
		decoration_tree_shape_segment_add(
			&shape,
			{x = -1, y = 5, z = -1},
			{x = 6, y = 7, z = 2},
			.Branch,
		)
		decoration_tree_shape_segment_add(
			&shape,
			{x = -1, y = 7, z = -1},
			{x = 3, y = 12, z = -3},
			.Branch,
		)
		decoration_tree_shape_segment_add(
			&shape,
			{x = -1, y = 8, z = -1},
			{x = -4, y = 13, z = 4},
			.Branch,
		)
		decoration_tree_shape_segment_add(
			&shape,
			{x = -1, y = 10, z = -1},
			{x = 0, y = 15, z = 0},
			.Branch,
		)
		decoration_tree_shape_crown_add(&shape, {x = -6, y = 8, z = -5}, 1, 1)
		decoration_tree_shape_crown_add(&shape, {x = 6, y = 8, z = 2}, 1, 1)
	case:
		decoration_tree_shape_segment_add(
			&shape,
			{x = 0, y = 1, z = 0},
			{x = 0, y = 11, z = 1},
			.Trunk,
		)
		decoration_tree_shape_segment_add(
			&shape,
			{x = 0, y = 4, z = 0},
			{x = 5, y = 7, z = 5},
			.Branch,
		)
		decoration_tree_shape_segment_add(
			&shape,
			{x = 0, y = 5, z = 0},
			{x = -6, y = 8, z = -2},
			.Branch,
		)
		decoration_tree_shape_segment_add(
			&shape,
			{x = 0, y = 7, z = 1},
			{x = 4, y = 12, z = -5},
			.Branch,
		)
		decoration_tree_shape_segment_add(
			&shape,
			{x = 0, y = 9, z = 1},
			{x = -2, y = 14, z = 3},
			.Branch,
		)
		decoration_tree_shape_crown_add(&shape, {x = 5, y = 8, z = 5}, 1, 1)
		decoration_tree_shape_crown_add(&shape, {x = -6, y = 9, z = -2}, 1, 1)
	}
	return shape
}

decoration_tree_shape_stone :: proc(variant: u8) -> DecorationTreeShape {
	shape := decoration_tree_shape_make(
		.Basalt_Spire_Highlands,
		.Stone_Tree,
		variant,
		16,
		6,
		{x = -7, y = 1, z = -7},
		{x = 7, y = 19, z = 7},
	)
	switch variant {
	case 0:
		decoration_tree_shape_segment_add(
			&shape,
			{x = 0, y = 1, z = 0},
			{x = 0, y = 13, z = 0},
			.Trunk,
		)
		decoration_tree_shape_segment_add(
			&shape,
			{x = 0, y = 5, z = 0},
			{x = 5, y = 10, z = 0},
			.Branch,
		)
		decoration_tree_shape_segment_add(
			&shape,
			{x = 0, y = 7, z = 0},
			{x = -4, y = 12, z = -3},
			.Branch,
		)
		decoration_tree_shape_segment_add(
			&shape,
			{x = 0, y = 9, z = 0},
			{x = 3, y = 15, z = 4},
			.Branch,
		)
		decoration_tree_shape_crown_add(&shape, {x = 0, y = 16, z = 0}, 2, 2)
		decoration_tree_shape_crown_add(&shape, {x = 5, y = 11, z = 0}, 1, 2)
		decoration_tree_shape_crown_add(&shape, {x = -4, y = 13, z = -3}, 1, 2)
		decoration_tree_shape_crown_add(&shape, {x = 3, y = 16, z = 4}, 1, 1)
	case 1:
		decoration_tree_shape_segment_add(
			&shape,
			{x = 0, y = 1, z = 0},
			{x = -1, y = 12, z = 0},
			.Trunk,
		)
		decoration_tree_shape_segment_add(
			&shape,
			{x = -1, y = 5, z = 0},
			{x = -6, y = 10, z = 2},
			.Branch,
		)
		decoration_tree_shape_segment_add(
			&shape,
			{x = -1, y = 7, z = 0},
			{x = 3, y = 14, z = -2},
			.Branch,
		)
		decoration_tree_shape_segment_add(
			&shape,
			{x = -1, y = 9, z = 0},
			{x = 4, y = 12, z = 5},
			.Branch,
		)
		decoration_tree_shape_crown_add(&shape, {x = -6, y = 11, z = 2}, 1, 2)
		decoration_tree_shape_crown_add(&shape, {x = 3, y = 15, z = -2}, 1, 2)
		decoration_tree_shape_crown_add(&shape, {x = 4, y = 13, z = 5}, 1, 1)
	case 2:
		decoration_tree_shape_segment_add(
			&shape,
			{x = 0, y = 1, z = 0},
			{x = 0, y = 10, z = 0},
			.Trunk,
		)
		decoration_tree_shape_segment_add(
			&shape,
			{x = 0, y = 4, z = 0},
			{x = 6, y = 8, z = 4},
			.Branch,
		)
		decoration_tree_shape_segment_add(
			&shape,
			{x = 0, y = 5, z = 0},
			{x = -5, y = 9, z = 3},
			.Branch,
		)
		decoration_tree_shape_segment_add(
			&shape,
			{x = 0, y = 7, z = 0},
			{x = 1, y = 14, z = -5},
			.Branch,
		)
		decoration_tree_shape_crown_add(&shape, {x = 6, y = 9, z = 4}, 1, 2)
		decoration_tree_shape_crown_add(&shape, {x = -5, y = 10, z = 3}, 1, 2)
		decoration_tree_shape_crown_add(&shape, {x = 1, y = 15, z = -5}, 1, 2)
	case 3:
		decoration_tree_shape_segment_add(
			&shape,
			{x = 0, y = 1, z = 0},
			{x = 1, y = 13, z = 1},
			.Trunk,
		)
		decoration_tree_shape_segment_add(
			&shape,
			{x = 1, y = 5, z = 1},
			{x = 5, y = 11, z = -2},
			.Branch,
		)
		decoration_tree_shape_segment_add(
			&shape,
			{x = 1, y = 7, z = 1},
			{x = -3, y = 13, z = 5},
			.Branch,
		)
		decoration_tree_shape_segment_add(
			&shape,
			{x = 1, y = 10, z = 1},
			{x = -4, y = 15, z = -4},
			.Branch,
		)
		decoration_tree_shape_crown_add(&shape, {x = 1, y = 16, z = 1}, 1, 2)
		decoration_tree_shape_crown_add(&shape, {x = 5, y = 12, z = -2}, 1, 1)
		decoration_tree_shape_crown_add(&shape, {x = -3, y = 14, z = 5}, 1, 2)
	case 4:
		decoration_tree_shape_segment_add(
			&shape,
			{x = 0, y = 1, z = 0},
			{x = -1, y = 11, z = -1},
			.Trunk,
		)
		decoration_tree_shape_segment_add(
			&shape,
			{x = -1, y = 4, z = -1},
			{x = -6, y = 8, z = -5},
			.Branch,
		)
		decoration_tree_shape_segment_add(
			&shape,
			{x = -1, y = 6, z = -1},
			{x = 5, y = 11, z = -3},
			.Branch,
		)
		decoration_tree_shape_segment_add(
			&shape,
			{x = -1, y = 8, z = -1},
			{x = -2, y = 15, z = 3},
			.Branch,
		)
		decoration_tree_shape_crown_add(&shape, {x = -6, y = 9, z = -5}, 1, 2)
		decoration_tree_shape_crown_add(&shape, {x = 5, y = 12, z = -3}, 1, 2)
		decoration_tree_shape_crown_add(&shape, {x = -2, y = 16, z = 3}, 1, 1)
	case:
		decoration_tree_shape_segment_add(
			&shape,
			{x = 0, y = 1, z = 0},
			{x = 0, y = 14, z = 0},
			.Trunk,
		)
		decoration_tree_shape_segment_add(
			&shape,
			{x = 0, y = 6, z = 0},
			{x = 4, y = 12, z = 4},
			.Branch,
		)
		decoration_tree_shape_segment_add(
			&shape,
			{x = 0, y = 8, z = 0},
			{x = -5, y = 12, z = -1},
			.Branch,
		)
		decoration_tree_shape_segment_add(
			&shape,
			{x = 0, y = 11, z = 0},
			{x = 2, y = 16, z = -3},
			.Branch,
		)
		decoration_tree_shape_crown_add(&shape, {x = 0, y = 17, z = 0}, 2, 2)
		decoration_tree_shape_crown_add(&shape, {x = 4, y = 13, z = 4}, 1, 1)
		decoration_tree_shape_crown_add(&shape, {x = -5, y = 13, z = -1}, 1, 2)
	}
	return shape
}

decoration_tree_shape_fungal :: proc(biome_id: BiomeID, variant: u8) -> DecorationTreeShape {
	shape := decoration_tree_shape_make(
		biome_id,
		.Fungal_Tree,
		variant,
		9,
		6,
		{x = -6, y = 1, z = -6},
		{x = 6, y = 12, z = 6},
	)
	switch variant {
	case 0:
		decoration_tree_shape_segment_add(
			&shape,
			{x = 0, y = 1, z = 0},
			{x = 0, y = 7, z = 0},
			.Trunk,
		)
		decoration_tree_shape_segment_add(
			&shape,
			{x = 0, y = 4, z = 0},
			{x = 3, y = 6, z = 2},
			.Branch,
		)
		decoration_tree_shape_crown_add(&shape, {x = 0, y = 8, z = 0}, 6, 1)
		decoration_tree_shape_crown_add(&shape, {x = 3, y = 7, z = 2}, 2, 1)
	case 1:
		decoration_tree_shape_segment_add(
			&shape,
			{x = 0, y = 1, z = 0},
			{x = 1, y = 7, z = 0},
			.Trunk,
		)
		decoration_tree_shape_segment_add(
			&shape,
			{x = 1, y = 4, z = 0},
			{x = -4, y = 6, z = 2},
			.Branch,
		)
		decoration_tree_shape_segment_add(
			&shape,
			{x = 1, y = 5, z = 0},
			{x = 4, y = 7, z = -3},
			.Branch,
		)
		decoration_tree_shape_crown_add(&shape, {x = 1, y = 8, z = 0}, 5, 1)
		decoration_tree_shape_crown_add(&shape, {x = -4, y = 7, z = 2}, 2, 1)
		decoration_tree_shape_crown_add(&shape, {x = 4, y = 8, z = -3}, 2, 1)
	case 2:
		decoration_tree_shape_segment_add(
			&shape,
			{x = 0, y = 1, z = 0},
			{x = -1, y = 6, z = 1},
			.Trunk,
		)
		decoration_tree_shape_segment_add(
			&shape,
			{x = -1, y = 5, z = 1},
			{x = 4, y = 7, z = -4},
			.Branch,
		)
		decoration_tree_shape_segment_add(
			&shape,
			{x = -1, y = 4, z = 1},
			{x = -5, y = 6, z = -2},
			.Branch,
		)
		decoration_tree_shape_crown_add(&shape, {x = -1, y = 8, z = 1}, 5, 1)
		decoration_tree_shape_crown_add(&shape, {x = 4, y = 8, z = -4}, 2, 1)
	case 3:
		decoration_tree_shape_segment_add(
			&shape,
			{x = 0, y = 1, z = 0},
			{x = 0, y = 8, z = 0},
			.Trunk,
		)
		decoration_tree_shape_segment_add(
			&shape,
			{x = 0, y = 5, z = 0},
			{x = -3, y = 7, z = 4},
			.Branch,
		)
		decoration_tree_shape_segment_add(
			&shape,
			{x = 0, y = 5, z = 0},
			{x = 4, y = 7, z = 3},
			.Branch,
		)
		decoration_tree_shape_crown_add(&shape, {x = 0, y = 9, z = 0}, 4, 1)
		decoration_tree_shape_crown_add(&shape, {x = -3, y = 8, z = 4}, 3, 1)
		decoration_tree_shape_crown_add(&shape, {x = 4, y = 8, z = 3}, 3, 1)
	case 4:
		decoration_tree_shape_segment_add(
			&shape,
			{x = 0, y = 1, z = 0},
			{x = 2, y = 6, z = 1},
			.Trunk,
		)
		decoration_tree_shape_segment_add(
			&shape,
			{x = 2, y = 4, z = 1},
			{x = 5, y = 7, z = -2},
			.Branch,
		)
		decoration_tree_shape_segment_add(
			&shape,
			{x = 2, y = 5, z = 1},
			{x = -3, y = 7, z = -4},
			.Branch,
		)
		decoration_tree_shape_crown_add(&shape, {x = 2, y = 8, z = 1}, 5, 1)
		decoration_tree_shape_crown_add(&shape, {x = 5, y = 8, z = -2}, 2, 1)
	case:
		decoration_tree_shape_segment_add(
			&shape,
			{x = 0, y = 1, z = 0},
			{x = -2, y = 7, z = -1},
			.Trunk,
		)
		decoration_tree_shape_segment_add(
			&shape,
			{x = -2, y = 5, z = -1},
			{x = -5, y = 7, z = 3},
			.Branch,
		)
		decoration_tree_shape_segment_add(
			&shape,
			{x = -2, y = 5, z = -1},
			{x = 3, y = 8, z = 4},
			.Branch,
		)
		decoration_tree_shape_crown_add(&shape, {x = -2, y = 9, z = -1}, 4, 1)
		decoration_tree_shape_crown_add(&shape, {x = -5, y = 8, z = 3}, 2, 1)
		decoration_tree_shape_crown_add(&shape, {x = 3, y = 9, z = 4}, 2, 1)
	}
	return shape
}

when ODIN_DEBUG {
	decoration_debug_contract_checks_run :: proc() {
		log.assert(
			DECORATION_SURFACE_SLOT_COUNT_MAX >= 3,
			"surface decoration catalog should keep separate tree, organic, and structure slots",
		)

		key := feature_grid_key_make(0xdec0de, 1)
		owner := FeatureGridCoord2 {
			x = 0,
			z = 0,
		}
		feature, _ := decoration_surface_feature_from_owner(key, owner)
		if feature.id != 0 {
			profile := decoration_family_profile_for(feature.family_id)
			log.assert(
				feature.height_blocks >= profile.min_height &&
				feature.height_blocks <= profile.max_height,
				"Decoration Feature height must stay inside its family profile",
			)
		}

		fungal_node := CaveNetworkNode {
			id           = FeatureID(123),
			biome_id     = .Fungal_Vaults,
			role         = .Major_Region,
			major_region = true,
		}
		family_id, _, found := decoration_cave_family_for_node(fungal_node)
		log.assert(
			found &&
			(family_id == .Fungal_Tree ||
					family_id == .Root_Cluster ||
					family_id == .Coral_DLA_Cluster ||
					family_id == .Cave_Ruin_Hall),
			"fungal major cave nodes should produce organic decoration candidates",
		)

		crystal_profile := decoration_family_profile_for(.Crystal_Growth_Cluster)
		log.assert(
			crystal_profile.placement_kind == .Surface_And_Subterranean,
			"crystal decoration clusters are shared between surface basalt and geode caves",
		)
		basalt_family_id, basalt_chance, basalt_found := decoration_surface_family_for_biome(
			.Basalt_Spire_Highlands,
		)
		log.assert(
			basalt_found && basalt_family_id == .Stone_Tree && basalt_chance > 0,
			"basalt highlands should produce sparse stone tree decoration candidates",
		)

		tree_profiles := [?]struct {
			biome_id:  BiomeID,
			family_id: DecorationFamilyID,
		} {
			{.Temperate_Hills, .Baseline_Tree},
			{.Old_Growth_Forest, .Baseline_Tree},
			{.Wet_Lowland_Marsh, .Baseline_Tree},
			{.Corrupted_Ash_Forest, .Dead_Ash_Tree},
			{.Corrupted_Fen, .Dead_Ash_Tree},
			{.Basalt_Spire_Highlands, .Stone_Tree},
			{.Emberglass_Badlands, .Stone_Tree},
			{.Fungal_Vaults, .Fungal_Tree},
		}
		for tree_profile in tree_profiles {
			count := decoration_tree_shape_count_for(tree_profile.biome_id, tree_profile.family_id)
			log.assert(count >= 4, "tree-capable biomes must expose at least four shapes")
			for variant := u8(0); variant < count; variant += 1 {
				shape := decoration_tree_shape_for(
					tree_profile.biome_id,
					tree_profile.family_id,
					variant,
				)
				log.assert(shape.segment_count > 0, "tree shapes must have trunk/branch segments")
				log.assert(
					shape.max_bound.y > shape.min_bound.y,
					"tree shape bounds must have positive height",
				)
			}
		}

		structure_families := [?]DecorationFamilyID {
			.Ruin_Hamlet,
			.Watchtower_Ruin,
			.Palisade_Fort,
			.Cave_Ruin_Hall,
		}
		for structure_family in structure_families {
			profile := decoration_family_profile_for(structure_family)
			log.assert(
				profile.radius_blocks >= 7 && profile.max_height >= 7,
				"structure decoration families must be large enough to read as structures",
			)
		}

		structure_found := false
		for owner_z := i32(-8); owner_z <= 8 && !structure_found; owner_z += 1 {
			for owner_x := i32(-8); owner_x <= 8 && !structure_found; owner_x += 1 {
				point := decoration_surface_slot_point_from_owner(
					key,
					FeatureGridCoord2{x = owner_x, z = owner_z},
					2,
				)
				density_class := decoration_surface_density_class_from_strength(
					decoration_surface_patch_strength_for_point(key, point, .Temperate_Hills),
				)
				family := decoration_surface_family_select(
					point.id,
					.Temperate_Hills,
					.Baseline_Tree,
					density_class,
					2,
				)
				if family == .Ruin_Hamlet ||
				   family == .Watchtower_Ruin ||
				   family == .Palisade_Fort ||
				   family == .Ruin_Pillar_Set {
					structure_found = true
				}
			}
		}
		log.assert(structure_found, "surface slot 2 should produce visible structure families")
	}
}
