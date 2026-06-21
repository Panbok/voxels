package biomes

import "core:log"

//////////////////////////////////////
// Biome Material Types
/////////////////////////////////////

// BiomeMaterialID is generation-side material intent. The world package maps it
// to the renderer-facing Block Material ID palette.
BiomeMaterialID :: enum u8 {
	Grass,
	Dirt,
	Stone,
	Wet_Marsh,
	Water,
	Corrupted_Ash,
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
	case .Basalt_Spire_Highlands:
		return {
			surface = .Stone,
			subsurface = .Stone,
			cave_wall = .Stone,
			cave_floor = .Stone,
			cave_ceiling = .Stone,
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
	case .Fungal_Vaults:
		return {
			surface = .Stone,
			subsurface = .Stone,
			cave_wall = .Wet_Marsh,
			cave_floor = .Grass,
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
			.Basalt_Spire_Highlands,
			.Wet_Lowland_Marsh,
			.Corrupted_Ash_Forest,
			.Fungal_Vaults,
			.Crystal_Geode_Network,
			.Buried_Aquifer_Caves,
		}
		for biome_id in biome_ids {
			profile := biome_material_profile_for(biome_id)
			log.assert(
				profile.surface != .Water &&
				profile.subsurface != .Water &&
				profile.cave_wall != .Water &&
				profile.cave_floor != .Water &&
				profile.cave_ceiling != .Water,
				"Biome Material Profiles should not use water as a base terrain material",
			)
		}
	}
}
