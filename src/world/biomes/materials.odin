package biomes

import "core:log"

//////////////////////////////////////
// Biome Material Types
/////////////////////////////////////

// BiomeMaterialID is generation-side material intent. The world package maps it
// to the renderer-facing Block Material ID palette.
BiomeMaterialID :: enum u8 {
	Grass,
	Moss,
	Dirt,
	Forest_Litter,
	Stone,
	Basalt,
	Wet_Marsh,
	Water,
	Swamp_Water,
	Corrupted_Water,
	Lava,
	Corrupted_Ash,
	Corrupt_Mud,
	Ember_Ash,
	Aquifer_Wall,
	Crystal,
}

BiomeMaterialProfile :: struct {
	surface:      BiomeMaterialID,
	subsurface:   BiomeMaterialID,
	cave_wall:    BiomeMaterialID,
	cave_floor:   BiomeMaterialID,
	cave_ceiling: BiomeMaterialID,
}

//////////////////////////////////////
// Biome Material Methods
/////////////////////////////////////

biome_material_profile_for :: proc(biome_id: BiomeID) -> BiomeMaterialProfile {
	switch biome_id {
	case .Temperate_Hills:
		return {
			surface = .Grass,
			subsurface = .Dirt,
			cave_wall = .Stone,
			cave_floor = .Stone,
			cave_ceiling = .Stone,
		}
	case .Old_Growth_Forest:
		return {
			surface = .Moss,
			subsurface = .Forest_Litter,
			cave_wall = .Stone,
			cave_floor = .Moss,
			cave_ceiling = .Dirt,
		}
	case .Basalt_Spire_Highlands:
		return {
			surface = .Basalt,
			subsurface = .Basalt,
			cave_wall = .Basalt,
			cave_floor = .Stone,
			cave_ceiling = .Basalt,
		}
	case .Emberglass_Badlands:
		return {
			surface = .Ember_Ash,
			subsurface = .Basalt,
			cave_wall = .Basalt,
			cave_floor = .Ember_Ash,
			cave_ceiling = .Basalt,
		}
	case .Wet_Lowland_Marsh:
		return {
			surface = .Wet_Marsh,
			subsurface = .Dirt,
			cave_wall = .Stone,
			cave_floor = .Stone,
			cave_ceiling = .Stone,
		}
	case .Corrupted_Ash_Forest:
		return {
			surface = .Corrupted_Ash,
			subsurface = .Corrupted_Ash,
			cave_wall = .Stone,
			cave_floor = .Stone,
			cave_ceiling = .Stone,
		}
	case .Corrupted_Fen:
		return {
			surface = .Corrupt_Mud,
			subsurface = .Corrupted_Ash,
			cave_wall = .Corrupted_Ash,
			cave_floor = .Corrupt_Mud,
			cave_ceiling = .Stone,
		}
	case .Fungal_Vaults:
		return {
			surface = .Moss,
			subsurface = .Dirt,
			cave_wall = .Wet_Marsh,
			cave_floor = .Moss,
			cave_ceiling = .Dirt,
		}
	case .Crystal_Geode_Network:
		return {
			surface = .Stone,
			subsurface = .Stone,
			cave_wall = .Crystal,
			cave_floor = .Stone,
			cave_ceiling = .Crystal,
		}
	case .Buried_Aquifer_Caves:
		return {
			surface = .Stone,
			subsurface = .Stone,
			cave_wall = .Aquifer_Wall,
			cave_floor = .Wet_Marsh,
			cave_ceiling = .Stone,
		}
	}

	log.assertf(false, "unhandled biome material profile: %v", biome_id)
	return {
		surface = .Stone,
		subsurface = .Stone,
		cave_wall = .Stone,
		cave_floor = .Stone,
		cave_ceiling = .Stone,
	}
}

when ODIN_DEBUG {
	biome_material_debug_contract_checks_run :: proc() {
		biome_ids := [?]BiomeID {
			.Temperate_Hills,
			.Old_Growth_Forest,
			.Basalt_Spire_Highlands,
			.Emberglass_Badlands,
			.Wet_Lowland_Marsh,
			.Corrupted_Ash_Forest,
			.Corrupted_Fen,
			.Fungal_Vaults,
			.Crystal_Geode_Network,
			.Buried_Aquifer_Caves,
		}
		for biome_id in biome_ids {
			profile := biome_material_profile_for(biome_id)
			log.assert(
				profile.surface != .Water &&
				profile.surface != .Swamp_Water &&
				profile.surface != .Corrupted_Water &&
				profile.surface != .Lava &&
				profile.subsurface != .Water &&
				profile.subsurface != .Swamp_Water &&
				profile.subsurface != .Corrupted_Water &&
				profile.subsurface != .Lava &&
				profile.cave_wall != .Water &&
				profile.cave_wall != .Swamp_Water &&
				profile.cave_wall != .Corrupted_Water &&
				profile.cave_wall != .Lava &&
				profile.cave_floor != .Water &&
				profile.cave_floor != .Swamp_Water &&
				profile.cave_floor != .Corrupted_Water &&
				profile.cave_floor != .Lava &&
				profile.cave_ceiling != .Water &&
				profile.cave_ceiling != .Swamp_Water &&
				profile.cave_ceiling != .Corrupted_Water &&
				profile.cave_ceiling != .Lava,
				"Biome Material Profiles should not use water as a base terrain material",
			)
		}
	}
}
