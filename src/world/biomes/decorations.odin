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
	Crystal_Growth_Cluster,
}

DecorationPlacementKind :: enum u8 {
	Surface,
	Subterranean,
	Surface_And_Subterranean,
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
	id:            FeatureID,
	owner:         FeatureGridCoord2,
	x, z:          f32,
	biome_id:      BiomeID,
	family_id:     DecorationFamilyID,
	height_blocks: u8,
	radius_blocks: u8,
}

//////////////////////////////////////
// Decoration Constants
/////////////////////////////////////

DECORATION_SURFACE_GRID_CONFIG :: FeatureGridConfig {
	domain           = .Surface,
	level            = .Micro,
	cell_size_blocks = 64,
	jitter_fraction  = 0.70,
}

DECORATION_SURFACE_INFLUENCE_MARGIN_BLOCKS :: 8
DECORATION_FAMILY_COUNT :: 4
DECORATION_SURFACE_FEATURE_SALT :: u64(0x91a7c5d3e42f68b0)
DECORATION_SURFACE_ROLL_SALT :: u64(0x67c8b4319ad205ef)
DECORATION_HEIGHT_SALT :: u64(0x2c41a8f73d96e50b)
DECORATION_CAVE_ROLL_SALT :: u64(0x7d5a0c3e91b6842f)
#assert(u32(DecorationFamilyID.Crystal_Growth_Cluster) + 1 == DECORATION_FAMILY_COUNT)

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
	case .Crystal_Growth_Cluster:
		return {
			placement_kind = .Surface_And_Subterranean,
			trunk_material = .Crystal,
			cap_material = .Crystal,
			min_height = 3,
			max_height = 6,
			radius_blocks = 1,
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

decoration_surface_family_for_biome :: proc(
	biome_id: BiomeID,
) -> (
	family_id: DecorationFamilyID,
	chance: f32,
	found: bool,
) {
	switch biome_id {
	case .Temperate_Hills:
		return .Baseline_Tree, 0.34, true
	case .Wet_Lowland_Marsh:
		return .Baseline_Tree, 0.18, true
	case .Corrupted_Ash_Forest:
		return .Dead_Ash_Tree, 0.30, true
	case .Basalt_Spire_Highlands:
		return .Crystal_Growth_Cluster, 0.10, true
	case .Fungal_Vaults, .Crystal_Geode_Network, .Buried_Aquifer_Caves:
		return {}, 0, false
	}
	return {}, 0, false
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
			return .Fungal_Tree, 0.22, true
		}
	case .Crystal_Geode_Network:
		if node.kind == .Geode_Chamber || node.role == .Resource_Chamber || node.major_region {
			return .Crystal_Growth_Cluster, 0.30, true
		}
	case .Buried_Aquifer_Caves:
		if node.kind == .Underground_Lake || node.role == .Water_Linked_Region {
			return .Fungal_Tree, 0.10, true
		}
	case .Temperate_Hills, .Basalt_Spire_Highlands, .Wet_Lowland_Marsh, .Corrupted_Ash_Forest:
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

decoration_surface_feature_from_owner :: proc(
	key: FeatureGridKey,
	owner: FeatureGridCoord2,
) -> (
	feature: DecorationFeature,
	found: bool,
) {
	point := feature_grid_point_from_owner(key, DECORATION_SURFACE_GRID_CONFIG, owner)
	feature_id := FeatureID(
		feature_grid_hash_combine(u64(point.id), DECORATION_SURFACE_FEATURE_SALT),
	)
	block_x := i32(math.floor_f32(point.x))
	block_z := i32(math.floor_f32(point.z))
	surface_sample := surface_biome_field_sample(key, block_x, block_z)
	if surface_sample.cell_count == 0 {
		return
	}

	biome_id := surface_sample.cells[surface_sample.dominant_index].biome_id
	family_id, chance, family_found := decoration_surface_family_for_biome(biome_id)
	if !family_found {
		return
	}
	roll := feature_grid_unit_f32(u64(feature_id), DECORATION_SURFACE_ROLL_SALT)
	if roll > chance {
		return
	}

	profile := decoration_family_profile_for(family_id)
	feature = {
		id            = feature_id,
		owner         = owner,
		x             = point.x,
		z             = point.z,
		biome_id      = biome_id,
		family_id     = family_id,
		height_blocks = decoration_feature_height_from_id(feature_id, profile),
		radius_blocks = profile.radius_blocks,
	}
	found = true
	return
}

decoration_cave_feature_roll_accepts :: proc(node: CaveNetworkNode, chance: f32) -> bool {
	if chance <= 0 {
		return false
	}
	return feature_grid_unit_f32(u64(node.id), DECORATION_CAVE_ROLL_SALT) <= chance
}

when ODIN_DEBUG {
	decoration_debug_contract_checks_run :: proc() {
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
			found && family_id == .Fungal_Tree,
			"fungal major cave nodes should produce fungal decoration candidates",
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
			basalt_found && basalt_family_id == .Crystal_Growth_Cluster && basalt_chance > 0,
			"basalt highlands should produce sparse surface crystal decoration candidates",
		)
	}
}
