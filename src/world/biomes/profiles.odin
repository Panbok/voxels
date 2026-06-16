package biomes

import "core:log"
import math "core:math"

//////////////////////////////////////
// Regional Terrain Field Types
/////////////////////////////////////

RegionalTerrainFields :: struct {
	continentalness:       f32,
	regional_elevation:    f32,
	erosion:               f32,
	ruggedness:            f32,
	local_relief:          f32,
	magic_affinity:        f32,
	corruption_affinity:   f32,
	heat_affinity:         f32,
	cold_affinity:         f32,
	subterranean_pressure: f32,
}

//////////////////////////////////////
// Biome Profile Types
/////////////////////////////////////

BiomeProfile :: struct {
	biome_id:                      BiomeID,
	base_height_blocks:            f32,
	continental_height_blocks:     f32,
	elevation_height_blocks:       f32,
	erosion_height_blocks:         f32,
	relief_height_blocks:          f32,
	relief_amplitude_blocks:       f32,
	ruggedness_response:           f32,
	cliff_bias:                    f32,
	terrace_strength:              f32,
	cave_openness:                 f32,
	surface_layer_depth_blocks:    f32,
	local_detail_amplitude_blocks: f32,
	fantasy_affinity_bias:         f32,
	magic_affinity_weight:         f32,
	corruption_affinity_weight:    f32,
	heat_affinity_weight:          f32,
	cold_affinity_weight:          f32,
	subterranean_pressure_weight:  f32,
}

BiomeShapeTarget :: struct {
	biome_id:                      BiomeID,
	surface_height_blocks:         f32,
	relief_amplitude_blocks:       f32,
	ruggedness_response:           f32,
	cliff_bias:                    f32,
	terrace_strength:              f32,
	cave_openness:                 f32,
	surface_layer_depth_blocks:    f32,
	local_detail_amplitude_blocks: f32,
	fantasy_affinity:              f32,
}

SurfaceBiomeProfileEvaluation :: struct {
	fields:         RegionalTerrainFields,
	targets:        [BIOME_FIELD_NEAREST_CELL_COUNT]BiomeShapeTarget,
	blended_target: BiomeShapeTarget,
	cell_count:     u32,
}

SubterraneanBiomeProfileEvaluation :: struct {
	fields:         RegionalTerrainFields,
	targets:        [BIOME_FIELD_NEAREST_CELL_COUNT]BiomeShapeTarget,
	blended_target: BiomeShapeTarget,
	cell_count:     u32,
}

//////////////////////////////////////
// Regional Terrain Field Constants
/////////////////////////////////////

REGIONAL_TERRAIN_FIELD_DOMAIN_SALT :: u64(0x91e10da5c79e7b1d)

REGIONAL_TERRAIN_CONTINENTAL_CELL_BLOCKS :: 2048
REGIONAL_TERRAIN_ELEVATION_CELL_BLOCKS :: 1024
REGIONAL_TERRAIN_EROSION_CELL_BLOCKS :: 768
REGIONAL_TERRAIN_RUGGEDNESS_CELL_BLOCKS :: 640
REGIONAL_TERRAIN_LOCAL_RELIEF_CELL_BLOCKS :: 192
REGIONAL_TERRAIN_AFFINITY_CELL_BLOCKS :: 1536
REGIONAL_TERRAIN_PRESSURE_DEPTH_BLOCKS :: f32(512.0)

REGIONAL_TERRAIN_CONTINENTAL_SALT :: u64(0xf6a88d24303098a2)
REGIONAL_TERRAIN_ELEVATION_SALT :: u64(0xa2bfe8a14cf10364)
REGIONAL_TERRAIN_EROSION_SALT :: u64(0x9c4f1d2f76a71299)
REGIONAL_TERRAIN_RUGGEDNESS_SALT :: u64(0xd3e2b0f593a91d4f)
REGIONAL_TERRAIN_LOCAL_RELIEF_SALT :: u64(0x7345b1f7a4d31921)
REGIONAL_TERRAIN_MAGIC_SALT :: u64(0x510e527fade682d1)
REGIONAL_TERRAIN_CORRUPTION_SALT :: u64(0xc0ffee3175ad43b1)
REGIONAL_TERRAIN_HEAT_SALT :: u64(0x2f8a7bd152946e33)
REGIONAL_TERRAIN_COLD_SALT :: u64(0x9b879d623e4c11af)
REGIONAL_TERRAIN_PRESSURE_SALT :: u64(0x47c1b7e93d524a05)

//////////////////////////////////////
// Regional Terrain Field Methods
/////////////////////////////////////

regional_terrain_fields_sample :: proc(
	key: FeatureGridKey,
	block_x, block_y, block_z: i32,
) -> RegionalTerrainFields {
	continental_low := regional_terrain_field_value_noise_2(
		key,
		block_x,
		block_z,
		REGIONAL_TERRAIN_CONTINENTAL_CELL_BLOCKS,
		REGIONAL_TERRAIN_CONTINENTAL_SALT,
	)
	continental_mid := regional_terrain_field_value_noise_2(
		key,
		block_x,
		block_z,
		REGIONAL_TERRAIN_ELEVATION_CELL_BLOCKS,
		REGIONAL_TERRAIN_CONTINENTAL_SALT,
	)
	elevation_low := regional_terrain_field_value_noise_2(
		key,
		block_x,
		block_z,
		REGIONAL_TERRAIN_ELEVATION_CELL_BLOCKS,
		REGIONAL_TERRAIN_ELEVATION_SALT,
	)
	elevation_mid := regional_terrain_field_value_noise_2(
		key,
		block_x,
		block_z,
		REGIONAL_TERRAIN_EROSION_CELL_BLOCKS,
		REGIONAL_TERRAIN_ELEVATION_SALT,
	)
	erosion_low := regional_terrain_field_value_noise_2(
		key,
		block_x,
		block_z,
		REGIONAL_TERRAIN_EROSION_CELL_BLOCKS,
		REGIONAL_TERRAIN_EROSION_SALT,
	)
	ruggedness_low := regional_terrain_field_value_noise_2(
		key,
		block_x,
		block_z,
		REGIONAL_TERRAIN_RUGGEDNESS_CELL_BLOCKS,
		REGIONAL_TERRAIN_RUGGEDNESS_SALT,
	)
	local_relief := regional_terrain_field_value_noise_2(
		key,
		block_x,
		block_z,
		REGIONAL_TERRAIN_LOCAL_RELIEF_CELL_BLOCKS,
		REGIONAL_TERRAIN_LOCAL_RELIEF_SALT,
	)
	pressure_noise := regional_terrain_field_value_noise_2(
		key,
		block_x,
		block_z,
		REGIONAL_TERRAIN_AFFINITY_CELL_BLOCKS,
		REGIONAL_TERRAIN_PRESSURE_SALT,
	)
	depth_pressure := regional_terrain_field_saturate(
		f32(-block_y) / REGIONAL_TERRAIN_PRESSURE_DEPTH_BLOCKS,
	)

	fields := RegionalTerrainFields {
		continentalness       = regional_terrain_field_saturate(
			0.5 + continental_low * 0.35 + continental_mid * 0.15,
		),
		regional_elevation    = regional_terrain_field_signed_clamp(
			elevation_low * 0.75 + elevation_mid * 0.25,
		),
		erosion               = regional_terrain_field_saturate(0.5 + erosion_low * 0.5),
		ruggedness            = regional_terrain_field_saturate(0.5 + ruggedness_low * 0.5),
		local_relief          = regional_terrain_field_signed_clamp(local_relief),
		magic_affinity        = regional_terrain_field_saturate(
			0.5 +
			regional_terrain_field_value_noise_2(
				key,
				block_x,
				block_z,
				REGIONAL_TERRAIN_AFFINITY_CELL_BLOCKS,
				REGIONAL_TERRAIN_MAGIC_SALT,
			) *
				0.5,
		),
		corruption_affinity   = regional_terrain_field_saturate(
			0.5 +
			regional_terrain_field_value_noise_2(
				key,
				block_x,
				block_z,
				REGIONAL_TERRAIN_AFFINITY_CELL_BLOCKS,
				REGIONAL_TERRAIN_CORRUPTION_SALT,
			) *
				0.5,
		),
		heat_affinity         = regional_terrain_field_saturate(
			0.5 +
			regional_terrain_field_value_noise_2(
				key,
				block_x,
				block_z,
				REGIONAL_TERRAIN_AFFINITY_CELL_BLOCKS,
				REGIONAL_TERRAIN_HEAT_SALT,
			) *
				0.5,
		),
		cold_affinity         = regional_terrain_field_saturate(
			0.5 +
			regional_terrain_field_value_noise_2(
				key,
				block_x,
				block_z,
				REGIONAL_TERRAIN_AFFINITY_CELL_BLOCKS,
				REGIONAL_TERRAIN_COLD_SALT,
			) *
				0.5,
		),
		subterranean_pressure = regional_terrain_field_saturate(
			depth_pressure * 0.65 + (0.5 + pressure_noise * 0.5) * 0.35,
		),
	}
	regional_terrain_fields_validate(fields)
	return fields
}

regional_terrain_fields_validate :: proc(fields: RegionalTerrainFields) {
	log.assert(
		fields.continentalness >= 0 && fields.continentalness <= 1,
		"continentalness must be in [0, 1]",
	)
	log.assert(
		fields.regional_elevation >= -1 && fields.regional_elevation <= 1,
		"regional elevation must be in [-1, 1]",
	)
	log.assert(fields.erosion >= 0 && fields.erosion <= 1, "erosion must be in [0, 1]")
	log.assert(fields.ruggedness >= 0 && fields.ruggedness <= 1, "ruggedness must be in [0, 1]")
	log.assert(
		fields.local_relief >= -1 && fields.local_relief <= 1,
		"local relief must be in [-1, 1]",
	)
	log.assert(
		fields.magic_affinity >= 0 && fields.magic_affinity <= 1,
		"magic affinity must be in [0, 1]",
	)
	log.assert(
		fields.corruption_affinity >= 0 && fields.corruption_affinity <= 1,
		"corruption affinity must be in [0, 1]",
	)
	log.assert(
		fields.heat_affinity >= 0 && fields.heat_affinity <= 1,
		"heat affinity must be in [0, 1]",
	)
	log.assert(
		fields.cold_affinity >= 0 && fields.cold_affinity <= 1,
		"cold affinity must be in [0, 1]",
	)
	log.assert(
		fields.subterranean_pressure >= 0 && fields.subterranean_pressure <= 1,
		"subterranean pressure must be in [0, 1]",
	)
}

regional_terrain_field_value_noise_2 :: proc(
	key: FeatureGridKey,
	block_x, block_z: i32,
	cell_size_blocks: i32,
	salt: u64,
) -> f32 {
	log.assert(cell_size_blocks > 0, "regional field cell size must be positive")

	cell_x := math.floor_div(block_x, cell_size_blocks)
	cell_z := math.floor_div(block_z, cell_size_blocks)
	origin_x := cell_x * cell_size_blocks
	origin_z := cell_z * cell_size_blocks
	unit_x := f32(block_x - origin_x) / f32(cell_size_blocks)
	unit_z := f32(block_z - origin_z) / f32(cell_size_blocks)
	t_x := math.smoothstep(f32(0), f32(1), unit_x)
	t_z := math.smoothstep(f32(0), f32(1), unit_z)

	v00 := regional_terrain_field_corner_value(key, salt, cell_x, cell_z)
	v10 := regional_terrain_field_corner_value(key, salt, cell_x + 1, cell_z)
	v01 := regional_terrain_field_corner_value(key, salt, cell_x, cell_z + 1)
	v11 := regional_terrain_field_corner_value(key, salt, cell_x + 1, cell_z + 1)

	return regional_terrain_field_lerp(
		regional_terrain_field_lerp(v00, v10, t_x),
		regional_terrain_field_lerp(v01, v11, t_x),
		t_z,
	)
}

regional_terrain_field_corner_value :: proc(
	key: FeatureGridKey,
	salt: u64,
	cell_x, cell_z: i32,
) -> f32 {
	h := feature_grid_key_hash(key)
	h = feature_grid_hash_combine(h, REGIONAL_TERRAIN_FIELD_DOMAIN_SALT)
	h = feature_grid_hash_combine(h, salt)
	h = feature_grid_hash_combine(h, feature_grid_hash_i32(cell_x))
	h = feature_grid_hash_combine(h, feature_grid_hash_i32(cell_z))
	return feature_grid_signed_unit_f32(h, salt)
}

regional_terrain_field_lerp :: proc(a, b, t: f32) -> f32 {
	return a + (b - a) * t
}

regional_terrain_field_saturate :: proc(value: f32) -> f32 {
	return math.clamp(value, f32(0), f32(1))
}

regional_terrain_field_signed_clamp :: proc(value: f32) -> f32 {
	return math.clamp(value, f32(-1), f32(1))
}

//////////////////////////////////////
// Biome Profile Methods
/////////////////////////////////////

biome_profile_for :: proc(biome_id: BiomeID) -> BiomeProfile {
	switch biome_id {
	case .Temperate_Hills:
		return {
			biome_id = biome_id,
			base_height_blocks = 26,
			continental_height_blocks = 30,
			elevation_height_blocks = 18,
			erosion_height_blocks = -8,
			relief_height_blocks = 8,
			relief_amplitude_blocks = 6,
			ruggedness_response = 0.65,
			cliff_bias = 0.10,
			terrace_strength = 0.05,
			cave_openness = 0.20,
			surface_layer_depth_blocks = 4,
			local_detail_amplitude_blocks = 3,
			fantasy_affinity_bias = 0.00,
			magic_affinity_weight = 0.10,
			corruption_affinity_weight = -0.15,
			heat_affinity_weight = 0.00,
			cold_affinity_weight = 0.00,
			subterranean_pressure_weight = 0.05,
		}
	case .Basalt_Spire_Highlands:
		return {
			biome_id = biome_id,
			base_height_blocks = 38,
			continental_height_blocks = 42,
			elevation_height_blocks = 34,
			erosion_height_blocks = -6,
			relief_height_blocks = 18,
			relief_amplitude_blocks = 14,
			ruggedness_response = 1.75,
			cliff_bias = 0.72,
			terrace_strength = 0.42,
			cave_openness = 0.24,
			surface_layer_depth_blocks = 2,
			local_detail_amplitude_blocks = 7,
			fantasy_affinity_bias = 0.10,
			magic_affinity_weight = 0.10,
			corruption_affinity_weight = 0.05,
			heat_affinity_weight = 0.55,
			cold_affinity_weight = -0.20,
			subterranean_pressure_weight = 0.10,
		}
	case .Wet_Lowland_Marsh:
		return {
			biome_id = biome_id,
			base_height_blocks = 14,
			continental_height_blocks = 16,
			elevation_height_blocks = 8,
			erosion_height_blocks = -10,
			relief_height_blocks = 3,
			relief_amplitude_blocks = 3,
			ruggedness_response = 0.25,
			cliff_bias = 0.02,
			terrace_strength = 0.02,
			cave_openness = 0.26,
			surface_layer_depth_blocks = 5,
			local_detail_amplitude_blocks = 2,
			fantasy_affinity_bias = 0.05,
			magic_affinity_weight = 0.10,
			corruption_affinity_weight = 0.00,
			heat_affinity_weight = -0.10,
			cold_affinity_weight = 0.00,
			subterranean_pressure_weight = 0.15,
		}
	case .Corrupted_Ash_Forest:
		return {
			biome_id = biome_id,
			base_height_blocks = 24,
			continental_height_blocks = 24,
			elevation_height_blocks = 16,
			erosion_height_blocks = -4,
			relief_height_blocks = 9,
			relief_amplitude_blocks = 7,
			ruggedness_response = 0.95,
			cliff_bias = 0.32,
			terrace_strength = 0.18,
			cave_openness = 0.34,
			surface_layer_depth_blocks = 3,
			local_detail_amplitude_blocks = 5,
			fantasy_affinity_bias = 0.18,
			magic_affinity_weight = 0.15,
			corruption_affinity_weight = 0.65,
			heat_affinity_weight = 0.10,
			cold_affinity_weight = -0.05,
			subterranean_pressure_weight = 0.16,
		}
	case .Fungal_Vaults:
		return {
			biome_id = biome_id,
			base_height_blocks = 0,
			continental_height_blocks = 4,
			elevation_height_blocks = 6,
			erosion_height_blocks = 2,
			relief_height_blocks = 10,
			relief_amplitude_blocks = 10,
			ruggedness_response = 0.55,
			cliff_bias = 0.10,
			terrace_strength = 0.24,
			cave_openness = 0.72,
			surface_layer_depth_blocks = 4,
			local_detail_amplitude_blocks = 5,
			fantasy_affinity_bias = 0.22,
			magic_affinity_weight = 0.35,
			corruption_affinity_weight = -0.10,
			heat_affinity_weight = 0.00,
			cold_affinity_weight = 0.00,
			subterranean_pressure_weight = 0.45,
		}
	case .Crystal_Geode_Network:
		return {
			biome_id = biome_id,
			base_height_blocks = 0,
			continental_height_blocks = 2,
			elevation_height_blocks = 5,
			erosion_height_blocks = -2,
			relief_height_blocks = 14,
			relief_amplitude_blocks = 8,
			ruggedness_response = 1.20,
			cliff_bias = 0.48,
			terrace_strength = 0.55,
			cave_openness = 0.48,
			surface_layer_depth_blocks = 2,
			local_detail_amplitude_blocks = 6,
			fantasy_affinity_bias = 0.28,
			magic_affinity_weight = 0.42,
			corruption_affinity_weight = 0.00,
			heat_affinity_weight = -0.05,
			cold_affinity_weight = 0.18,
			subterranean_pressure_weight = 0.34,
		}
	case .Buried_Aquifer_Caves:
		return {
			biome_id = biome_id,
			base_height_blocks = 0,
			continental_height_blocks = -2,
			elevation_height_blocks = -6,
			erosion_height_blocks = -8,
			relief_height_blocks = 4,
			relief_amplitude_blocks = 5,
			ruggedness_response = 0.35,
			cliff_bias = 0.04,
			terrace_strength = 0.08,
			cave_openness = 0.62,
			surface_layer_depth_blocks = 5,
			local_detail_amplitude_blocks = 3,
			fantasy_affinity_bias = 0.14,
			magic_affinity_weight = 0.12,
			corruption_affinity_weight = -0.08,
			heat_affinity_weight = -0.10,
			cold_affinity_weight = 0.05,
			subterranean_pressure_weight = 0.52,
		}
	}

	log.assertf(false, "unhandled biome profile: %v", biome_id)
	return {}
}

biome_shape_target_evaluate :: proc(
	profile: BiomeProfile,
	fields: RegionalTerrainFields,
) -> BiomeShapeTarget {
	regional_terrain_fields_validate(fields)

	fantasy_affinity := regional_terrain_field_saturate(
		profile.fantasy_affinity_bias +
		fields.magic_affinity * profile.magic_affinity_weight +
		fields.corruption_affinity * profile.corruption_affinity_weight +
		fields.heat_affinity * profile.heat_affinity_weight +
		fields.cold_affinity * profile.cold_affinity_weight +
		fields.subterranean_pressure * profile.subterranean_pressure_weight,
	)

	return {
		biome_id = profile.biome_id,
		surface_height_blocks = profile.base_height_blocks +
		(fields.continentalness - 0.5) * profile.continental_height_blocks +
		fields.regional_elevation * profile.elevation_height_blocks +
		(fields.erosion - 0.5) * profile.erosion_height_blocks +
		fields.local_relief * profile.relief_height_blocks,
		relief_amplitude_blocks = math.max(
			f32(0),
			profile.relief_amplitude_blocks * (0.65 + fields.ruggedness * 0.55) +
			math.abs(fields.local_relief) * profile.local_detail_amplitude_blocks,
		),
		ruggedness_response = math.max(f32(0), profile.ruggedness_response * fields.ruggedness),
		cliff_bias = regional_terrain_field_saturate(
			profile.cliff_bias + (fields.ruggedness - fields.erosion) * 0.35,
		),
		terrace_strength = regional_terrain_field_saturate(
			profile.terrace_strength + math.max(fields.regional_elevation, f32(0)) * 0.25,
		),
		cave_openness = regional_terrain_field_saturate(
			profile.cave_openness + fields.subterranean_pressure * 0.35 - fields.erosion * 0.08,
		),
		surface_layer_depth_blocks = math.max(f32(1), profile.surface_layer_depth_blocks),
		local_detail_amplitude_blocks = math.max(
			f32(0),
			profile.local_detail_amplitude_blocks * (0.5 + fields.ruggedness),
		),
		fantasy_affinity = fantasy_affinity,
	}
}

surface_biome_profile_sample :: proc(
	key: FeatureGridKey,
	block_x, block_z: i32,
) -> SurfaceBiomeProfileEvaluation {
	sample := surface_biome_field_sample(key, block_x, block_z)
	return surface_biome_profile_evaluate(key, sample, block_x, block_z)
}

surface_biome_profile_evaluate :: proc(
	key: FeatureGridKey,
	sample: SurfaceBiomeFieldSample,
	block_x, block_z: i32,
) -> SurfaceBiomeProfileEvaluation {
	fields := regional_terrain_fields_sample(key, block_x, 0, block_z)
	evaluation := SurfaceBiomeProfileEvaluation {
		fields     = fields,
		cell_count = sample.cell_count,
	}

	for i := u32(0); i < sample.cell_count; i += 1 {
		profile := biome_profile_for(sample.cells[i].biome_id)
		evaluation.targets[i] = biome_shape_target_evaluate(profile, fields)
	}
	blend_weights := sample.blend_weights
	evaluation.blended_target = biome_shape_target_blend(
		evaluation.targets[:],
		blend_weights[:],
		sample.cell_count,
	)
	return evaluation
}

subterranean_biome_profile_sample :: proc(
	key: FeatureGridKey,
	block_x, block_y, block_z: i32,
) -> SubterraneanBiomeProfileEvaluation {
	sample := subterranean_biome_field_sample(key, block_x, block_y, block_z)
	return subterranean_biome_profile_evaluate(key, sample, block_x, block_y, block_z)
}

subterranean_biome_profile_evaluate :: proc(
	key: FeatureGridKey,
	sample: SubterraneanBiomeFieldSample,
	block_x, block_y, block_z: i32,
) -> SubterraneanBiomeProfileEvaluation {
	fields := regional_terrain_fields_sample(key, block_x, block_y, block_z)
	evaluation := SubterraneanBiomeProfileEvaluation {
		fields     = fields,
		cell_count = sample.cell_count,
	}

	for i := u32(0); i < sample.cell_count; i += 1 {
		profile := biome_profile_for(sample.cells[i].biome_id)
		evaluation.targets[i] = biome_shape_target_evaluate(profile, fields)
	}
	blend_weights := sample.blend_weights
	evaluation.blended_target = biome_shape_target_blend(
		evaluation.targets[:],
		blend_weights[:],
		sample.cell_count,
	)
	return evaluation
}

biome_shape_target_blend :: proc(
	targets: []BiomeShapeTarget,
	weights: []f32,
	cell_count: u32,
) -> BiomeShapeTarget {
	log.assert(
		u32(len(targets)) >= BIOME_FIELD_NEAREST_CELL_COUNT,
		"biome shape target input too small",
	)
	log.assert(
		u32(len(weights)) >= BIOME_FIELD_NEAREST_CELL_COUNT,
		"biome shape target blend weights input too small",
	)
	log.assert(cell_count > 0, "biome shape target blend needs at least one target")
	log.assert(
		cell_count <= BIOME_FIELD_NEAREST_CELL_COUNT,
		"biome shape target blend cell count exceeds capacity",
	)

	blended := BiomeShapeTarget {
		biome_id = targets[0].biome_id,
	}
	for i := u32(0); i < cell_count; i += 1 {
		weight := weights[i]
		blended.surface_height_blocks += targets[i].surface_height_blocks * weight
		blended.relief_amplitude_blocks += targets[i].relief_amplitude_blocks * weight
		blended.ruggedness_response += targets[i].ruggedness_response * weight
		blended.cliff_bias += targets[i].cliff_bias * weight
		blended.terrace_strength += targets[i].terrace_strength * weight
		blended.cave_openness += targets[i].cave_openness * weight
		blended.surface_layer_depth_blocks += targets[i].surface_layer_depth_blocks * weight
		blended.local_detail_amplitude_blocks += targets[i].local_detail_amplitude_blocks * weight
		blended.fantasy_affinity += targets[i].fantasy_affinity * weight
	}
	return blended
}

//////////////////////////////////////
// Debug Methods
/////////////////////////////////////

when ODIN_DEBUG {

	profile_debug_contract_checks_run :: proc() {
		key := feature_grid_key_make(0x123456789abcdef0, 1)
		next_version_key := feature_grid_key_make(key.world_seed, key.generator_version + 1)

		fields := regional_terrain_fields_sample(key, 17, -96, -33)
		fields_again := regional_terrain_fields_sample(key, 17, -96, -33)
		debug_regional_terrain_fields_assert_equal(fields, fields_again)

		next_version_fields := regional_terrain_fields_sample(next_version_key, 17, -96, -33)
		log.assert(
			!debug_regional_terrain_fields_approx_equal(fields, next_version_fields),
			"regional terrain fields must include generator version",
		)

		synthetic_fields := RegionalTerrainFields {
			continentalness       = 0.75,
			regional_elevation    = 0.70,
			erosion               = 0.20,
			ruggedness            = 0.90,
			local_relief          = 0.40,
			magic_affinity        = 0.55,
			corruption_affinity   = 0.30,
			heat_affinity         = 0.85,
			cold_affinity         = 0.10,
			subterranean_pressure = 0.65,
		}
		temperate_target := biome_shape_target_evaluate(
			biome_profile_for(.Temperate_Hills),
			synthetic_fields,
		)
		basalt_target := biome_shape_target_evaluate(
			biome_profile_for(.Basalt_Spire_Highlands),
			synthetic_fields,
		)
		marsh_target := biome_shape_target_evaluate(
			biome_profile_for(.Wet_Lowland_Marsh),
			synthetic_fields,
		)
		fungal_target := biome_shape_target_evaluate(
			biome_profile_for(.Fungal_Vaults),
			synthetic_fields,
		)
		log.assert(
			basalt_target.surface_height_blocks > temperate_target.surface_height_blocks,
			"basalt profile should transform shared fields into higher terrain than temperate",
		)
		log.assert(
			basalt_target.cliff_bias > marsh_target.cliff_bias,
			"basalt profile should respond with stronger cliff bias than marsh",
		)
		log.assert(
			fungal_target.cave_openness > temperate_target.cave_openness,
			"fungal profile should produce more open subterranean shape targets",
		)

		blend_targets := [BIOME_FIELD_NEAREST_CELL_COUNT]BiomeShapeTarget {
			{biome_id = .Temperate_Hills, surface_height_blocks = 10, cliff_bias = 0.20},
			{biome_id = .Wet_Lowland_Marsh, surface_height_blocks = 20, cliff_bias = 0.40},
			{},
		}
		blend_weights := [BIOME_FIELD_NEAREST_CELL_COUNT]f32{0.25, 0.75, 0}
		blended := biome_shape_target_blend(blend_targets[:], blend_weights[:], 2)
		log.assert(
			debug_f32_approx_equal(blended.surface_height_blocks, 17.5, 0.001),
			"biome shape target height blend mismatch",
		)
		log.assert(
			debug_f32_approx_equal(blended.cliff_bias, 0.35, 0.001),
			"biome shape target cliff blend mismatch",
		)
		log.assert(
			blended.biome_id == .Temperate_Hills,
			"blended shape target should retain dominant biome identity",
		)

		surface_evaluation := surface_biome_profile_sample(key, 17, -33)
		log.assert(
			surface_evaluation.cell_count == BIOME_FIELD_NEAREST_CELL_COUNT,
			"surface biome profile evaluation should keep nearest-cell count",
		)
		debug_biome_shape_target_assert_valid(surface_evaluation.blended_target)

		subterranean_evaluation := subterranean_biome_profile_sample(key, -45, -96, 130)
		log.assert(
			subterranean_evaluation.cell_count == BIOME_FIELD_NEAREST_CELL_COUNT,
			"subterranean biome profile evaluation should keep nearest-cell count",
		)
		debug_biome_shape_target_assert_valid(subterranean_evaluation.blended_target)

		log.debug("Biome profile and regional field contract checks passed")
	}

	debug_regional_terrain_fields_assert_equal :: proc(a, b: RegionalTerrainFields) {
		log.assert(
			debug_regional_terrain_fields_approx_equal(a, b),
			"regional terrain fields mismatch",
		)
	}

	debug_regional_terrain_fields_approx_equal :: proc(a, b: RegionalTerrainFields) -> bool {
		return(
			debug_f32_approx_equal(a.continentalness, b.continentalness, 0.001) &&
			debug_f32_approx_equal(a.regional_elevation, b.regional_elevation, 0.001) &&
			debug_f32_approx_equal(a.erosion, b.erosion, 0.001) &&
			debug_f32_approx_equal(a.ruggedness, b.ruggedness, 0.001) &&
			debug_f32_approx_equal(a.local_relief, b.local_relief, 0.001) &&
			debug_f32_approx_equal(a.magic_affinity, b.magic_affinity, 0.001) &&
			debug_f32_approx_equal(a.corruption_affinity, b.corruption_affinity, 0.001) &&
			debug_f32_approx_equal(a.heat_affinity, b.heat_affinity, 0.001) &&
			debug_f32_approx_equal(a.cold_affinity, b.cold_affinity, 0.001) &&
			debug_f32_approx_equal(a.subterranean_pressure, b.subterranean_pressure, 0.001) \
		)
	}

	debug_biome_shape_target_assert_valid :: proc(target: BiomeShapeTarget) {
		log.assert(target.surface_layer_depth_blocks >= 1, "surface layer depth must be positive")
		log.assert(target.relief_amplitude_blocks >= 0, "relief amplitude must not be negative")
		log.assert(target.ruggedness_response >= 0, "ruggedness response must not be negative")
		log.assert(target.cliff_bias >= 0 && target.cliff_bias <= 1, "cliff bias range mismatch")
		log.assert(
			target.terrace_strength >= 0 && target.terrace_strength <= 1,
			"terrace strength range mismatch",
		)
		log.assert(
			target.cave_openness >= 0 && target.cave_openness <= 1,
			"cave openness range mismatch",
		)
		log.assert(
			target.local_detail_amplitude_blocks >= 0,
			"local detail amplitude must not be negative",
		)
		log.assert(
			target.fantasy_affinity >= 0 && target.fantasy_affinity <= 1,
			"fantasy affinity range mismatch",
		)
	}

}
