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

RegionalTerrainValueNoise2RowCache :: struct {
	corner_hash: u64,
	salt:        u64,
	cell_size:   i32,
	cell_z:      i32,
	origin_z:    i32,
	t_z:         f32,
	cell_x:      i32,
	v00:         f32,
	v10:         f32,
	v01:         f32,
	v11:         f32,
	valid:       bool,
}

RegionalTerrainFieldsRowCache :: struct {
	continental_low:     RegionalTerrainValueNoise2RowCache,
	continental_mid:     RegionalTerrainValueNoise2RowCache,
	elevation_low:       RegionalTerrainValueNoise2RowCache,
	elevation_mid:       RegionalTerrainValueNoise2RowCache,
	erosion_low:         RegionalTerrainValueNoise2RowCache,
	ruggedness_low:      RegionalTerrainValueNoise2RowCache,
	local_relief:        RegionalTerrainValueNoise2RowCache,
	pressure_noise:      RegionalTerrainValueNoise2RowCache,
	magic_affinity:      RegionalTerrainValueNoise2RowCache,
	corruption_affinity: RegionalTerrainValueNoise2RowCache,
	heat_affinity:       RegionalTerrainValueNoise2RowCache,
	cold_affinity:       RegionalTerrainValueNoise2RowCache,
}

SurfaceBiomeProfileRowCache :: struct {
	fields:       RegionalTerrainFieldsRowCache,
	relief_low:   RegionalTerrainValueNoise2RowCache,
	relief_mid:   RegionalTerrainValueNoise2RowCache,
	relief_high:  RegionalTerrainValueNoise2RowCache,
	relief_ridge: RegionalTerrainValueNoise2RowCache,
}

//////////////////////////////////////
// Biome Profile Types
/////////////////////////////////////

BiomeProfile :: struct {
	biome_id:                           BiomeID,
	base_height_blocks:                 f32,
	continental_height_blocks:          f32,
	elevation_height_blocks:            f32,
	erosion_height_blocks:              f32,
	relief_height_blocks:               f32,
	relief_amplitude_blocks:            f32,
	ruggedness_response:                f32,
	cliff_bias:                         f32,
	terrace_strength:                   f32,
	cave_openness:                      f32,
	surface_layer_depth_blocks:         f32,
	local_detail_amplitude_blocks:      f32,
	shoreline_width_blocks:             f32,
	shoreline_slope:                    f32,
	underwater_floor_depression_blocks: f32,
	cliff_coast_bias:                   f32,
	swamp_shallowness:                  f32,
	seabed_roughness_blocks:            f32,
	fantasy_affinity_bias:              f32,
	magic_affinity_weight:              f32,
	corruption_affinity_weight:         f32,
	heat_affinity_weight:               f32,
	cold_affinity_weight:               f32,
	subterranean_pressure_weight:       f32,
}

BiomeShapeTarget :: struct {
	biome_id:                           BiomeID,
	surface_height_blocks:              f32,
	relief_amplitude_blocks:            f32,
	ruggedness_response:                f32,
	cliff_bias:                         f32,
	terrace_strength:                   f32,
	cave_openness:                      f32,
	surface_layer_depth_blocks:         f32,
	local_detail_amplitude_blocks:      f32,
	shoreline_width_blocks:             f32,
	shoreline_slope:                    f32,
	underwater_floor_depression_blocks: f32,
	cliff_coast_bias:                   f32,
	swamp_shallowness:                  f32,
	seabed_roughness_blocks:            f32,
	fantasy_affinity:                   f32,
}

// BiomeTransitionStyle describes whether a boundary should reconcile terrain smoothly
// or preserve a deliberate shaped edge.
BiomeTransitionStyle :: enum u8 {
	// Soft transitions blend neighboring Biome Shape Targets without a strong border feature.
	Soft,
	// Hard transitions keep a structured boundary such as a cliff, shell, or corruption band.
	Hard,
}

// BiomeTransitionRuleKind identifies the selected pair rule for a biome boundary.
BiomeTransitionRuleKind :: enum u8 {
	// Generic_Smooth is the fallback for compatible or unspecified biome pairs.
	Generic_Smooth,
	// Temperate_Marsh_Shelf creates a broad, shallow soft edge between ordinary hills and marsh.
	Temperate_Marsh_Shelf,
	// Basalt_Marsh_Cliff creates a hard volcanic-to-wetland boundary with stronger cliff shaping.
	Basalt_Marsh_Cliff,
	// Corrupted_Border_Band creates a structured hostile boundary around corrupted terrain.
	Corrupted_Border_Band,
	// Fungal_Aquifer_Connector creates an open, water-friendly underground transition.
	Fungal_Aquifer_Connector,
	// Crystal_Geode_Shell creates a harder subterranean boundary around crystal geode regions.
	Crystal_Geode_Shell,
}

BiomeTransitionRule :: struct {
	kind:                                BiomeTransitionRuleKind,
	style:                               BiomeTransitionStyle,
	band_width_blocks:                   f32,
	dominant_bias:                       f32,
	height_bias_blocks:                  f32,
	cliff_bias_boost:                    f32,
	terrace_strength_boost:              f32,
	cave_openness_boost:                 f32,
	local_detail_amplitude_boost_blocks: f32,
	fantasy_affinity_boost:              f32,
	shoreline_width_scale:               f32,
	underwater_depression_boost_blocks:  f32,
}

SurfaceBiomeProfileEvaluation :: struct {
	fields:                   RegionalTerrainFields,
	targets:                  [BIOME_FIELD_NEAREST_CELL_COUNT]BiomeShapeTarget,
	blend_weights:            [BIOME_FIELD_NEAREST_CELL_COUNT]f32,
	blended_target:           BiomeShapeTarget,
	transition_rule:          BiomeTransitionRule,
	transition_strength:      f32,
	transitioned_target:      BiomeShapeTarget,
	sea_compression_strength: f32,
	hydrology_sample:         HydrologyLayerSurfaceSample,
	hydrology_target:         BiomeShapeTarget,
	final_target:             BiomeShapeTarget,
	cell_count:               u32,
}

SubterraneanBiomeProfileEvaluation :: struct {
	fields:              RegionalTerrainFields,
	targets:             [BIOME_FIELD_NEAREST_CELL_COUNT]BiomeShapeTarget,
	blend_weights:       [BIOME_FIELD_NEAREST_CELL_COUNT]f32,
	blended_target:      BiomeShapeTarget,
	transition_rule:     BiomeTransitionRule,
	transition_strength: f32,
	transitioned_target: BiomeShapeTarget,
	hydrology_sample:    HydrologyLayerSubterraneanSample,
	hydrology_target:    BiomeShapeTarget,
	final_target:        BiomeShapeTarget,
	cell_count:          u32,
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

SURFACE_TERRAIN_RELIEF_LOW_CELL_BLOCKS :: 384
SURFACE_TERRAIN_RELIEF_MID_CELL_BLOCKS :: 128
SURFACE_TERRAIN_RELIEF_HIGH_CELL_BLOCKS :: 48
SURFACE_TERRAIN_RELIEF_RIDGE_CELL_BLOCKS :: 160
SURFACE_TERRAIN_TERRACE_STEP_BLOCKS :: f32(5.0)
SURFACE_TERRAIN_RELIEF_LOW_SALT :: u64(0x2d7a9f4b13568ce1)
SURFACE_TERRAIN_RELIEF_MID_SALT :: u64(0x83c1b6dfe927405a)
SURFACE_TERRAIN_RELIEF_HIGH_SALT :: u64(0xf04e672a39dc815b)
SURFACE_TERRAIN_RELIEF_RIDGE_SALT :: u64(0x6a5bd190e7382cf4)

//////////////////////////////////////
// Sea Compression Constants
/////////////////////////////////////

SEA_LEVEL_BLOCKS :: f32(20.0)
SEA_COMPRESSION_MIN_SHORELINE_WIDTH_BLOCKS :: f32(1.0)

//////////////////////////////////////
// Regional Terrain Field Methods
/////////////////////////////////////

regional_terrain_value_noise_2_row_cache_make :: proc(
	key: FeatureGridKey,
	salt: u64,
	cell_size_blocks: i32,
	block_z: i32,
) -> RegionalTerrainValueNoise2RowCache {
	log.assert(cell_size_blocks > 0, "regional field row cache cell size must be positive")

	cell_z := math.floor_div(block_z, cell_size_blocks)
	origin_z := cell_z * cell_size_blocks
	unit_z := f32(block_z - origin_z) / f32(cell_size_blocks)
	return {
		corner_hash = regional_terrain_field_corner_hash_base(key, salt),
		salt = salt,
		cell_size = cell_size_blocks,
		cell_z = cell_z,
		origin_z = origin_z,
		t_z = math.smoothstep(f32(0), f32(1), unit_z),
	}
}

regional_terrain_value_noise_2_row_cache_update_x_cell :: proc(
	cache: ^RegionalTerrainValueNoise2RowCache,
	cell_x: i32,
) {
	if cache.valid && cache.cell_x == cell_x {
		return
	}
	cache.cell_x = cell_x
	cache.v00 = regional_terrain_field_corner_value_from_hash(
		cache.corner_hash,
		cache.salt,
		cell_x,
		cache.cell_z,
	)
	cache.v10 = regional_terrain_field_corner_value_from_hash(
		cache.corner_hash,
		cache.salt,
		cell_x + 1,
		cache.cell_z,
	)
	cache.v01 = regional_terrain_field_corner_value_from_hash(
		cache.corner_hash,
		cache.salt,
		cell_x,
		cache.cell_z + 1,
	)
	cache.v11 = regional_terrain_field_corner_value_from_hash(
		cache.corner_hash,
		cache.salt,
		cell_x + 1,
		cache.cell_z + 1,
	)
	cache.valid = true
}

regional_terrain_value_noise_2_row_cache_sample :: proc(
	cache: ^RegionalTerrainValueNoise2RowCache,
	block_x: i32,
) -> f32 {
	cell_x := math.floor_div(block_x, cache.cell_size)
	origin_x := cell_x * cache.cell_size
	unit_x := f32(block_x - origin_x) / f32(cache.cell_size)
	t_x := math.smoothstep(f32(0), f32(1), unit_x)
	regional_terrain_value_noise_2_row_cache_update_x_cell(cache, cell_x)

	return regional_terrain_field_lerp(
		regional_terrain_field_lerp(cache.v00, cache.v10, t_x),
		regional_terrain_field_lerp(cache.v01, cache.v11, t_x),
		cache.t_z,
	)
}

regional_terrain_fields_row_cache_make :: proc(
	key: FeatureGridKey,
	block_z: i32,
) -> RegionalTerrainFieldsRowCache {
	return {
		continental_low = regional_terrain_value_noise_2_row_cache_make(
			key,
			REGIONAL_TERRAIN_CONTINENTAL_SALT,
			REGIONAL_TERRAIN_CONTINENTAL_CELL_BLOCKS,
			block_z,
		),
		continental_mid = regional_terrain_value_noise_2_row_cache_make(
			key,
			REGIONAL_TERRAIN_CONTINENTAL_SALT,
			REGIONAL_TERRAIN_ELEVATION_CELL_BLOCKS,
			block_z,
		),
		elevation_low = regional_terrain_value_noise_2_row_cache_make(
			key,
			REGIONAL_TERRAIN_ELEVATION_SALT,
			REGIONAL_TERRAIN_ELEVATION_CELL_BLOCKS,
			block_z,
		),
		elevation_mid = regional_terrain_value_noise_2_row_cache_make(
			key,
			REGIONAL_TERRAIN_ELEVATION_SALT,
			REGIONAL_TERRAIN_EROSION_CELL_BLOCKS,
			block_z,
		),
		erosion_low = regional_terrain_value_noise_2_row_cache_make(
			key,
			REGIONAL_TERRAIN_EROSION_SALT,
			REGIONAL_TERRAIN_EROSION_CELL_BLOCKS,
			block_z,
		),
		ruggedness_low = regional_terrain_value_noise_2_row_cache_make(
			key,
			REGIONAL_TERRAIN_RUGGEDNESS_SALT,
			REGIONAL_TERRAIN_RUGGEDNESS_CELL_BLOCKS,
			block_z,
		),
		local_relief = regional_terrain_value_noise_2_row_cache_make(
			key,
			REGIONAL_TERRAIN_LOCAL_RELIEF_SALT,
			REGIONAL_TERRAIN_LOCAL_RELIEF_CELL_BLOCKS,
			block_z,
		),
		pressure_noise = regional_terrain_value_noise_2_row_cache_make(
			key,
			REGIONAL_TERRAIN_PRESSURE_SALT,
			REGIONAL_TERRAIN_AFFINITY_CELL_BLOCKS,
			block_z,
		),
		magic_affinity = regional_terrain_value_noise_2_row_cache_make(
			key,
			REGIONAL_TERRAIN_MAGIC_SALT,
			REGIONAL_TERRAIN_AFFINITY_CELL_BLOCKS,
			block_z,
		),
		corruption_affinity = regional_terrain_value_noise_2_row_cache_make(
			key,
			REGIONAL_TERRAIN_CORRUPTION_SALT,
			REGIONAL_TERRAIN_AFFINITY_CELL_BLOCKS,
			block_z,
		),
		heat_affinity = regional_terrain_value_noise_2_row_cache_make(
			key,
			REGIONAL_TERRAIN_HEAT_SALT,
			REGIONAL_TERRAIN_AFFINITY_CELL_BLOCKS,
			block_z,
		),
		cold_affinity = regional_terrain_value_noise_2_row_cache_make(
			key,
			REGIONAL_TERRAIN_COLD_SALT,
			REGIONAL_TERRAIN_AFFINITY_CELL_BLOCKS,
			block_z,
		),
	}
}

surface_biome_profile_row_cache_make :: proc(
	key: FeatureGridKey,
	block_z: i32,
) -> SurfaceBiomeProfileRowCache {
	return {
		fields = regional_terrain_fields_row_cache_make(key, block_z),
		relief_low = regional_terrain_value_noise_2_row_cache_make(
			key,
			SURFACE_TERRAIN_RELIEF_LOW_SALT,
			SURFACE_TERRAIN_RELIEF_LOW_CELL_BLOCKS,
			block_z,
		),
		relief_mid = regional_terrain_value_noise_2_row_cache_make(
			key,
			SURFACE_TERRAIN_RELIEF_MID_SALT,
			SURFACE_TERRAIN_RELIEF_MID_CELL_BLOCKS,
			block_z,
		),
		relief_high = regional_terrain_value_noise_2_row_cache_make(
			key,
			SURFACE_TERRAIN_RELIEF_HIGH_SALT,
			SURFACE_TERRAIN_RELIEF_HIGH_CELL_BLOCKS,
			block_z,
		),
		relief_ridge = regional_terrain_value_noise_2_row_cache_make(
			key,
			SURFACE_TERRAIN_RELIEF_RIDGE_SALT,
			SURFACE_TERRAIN_RELIEF_RIDGE_CELL_BLOCKS,
			block_z,
		),
	}
}

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

regional_terrain_fields_sample_row :: proc(
	cache: ^RegionalTerrainFieldsRowCache,
	block_x, block_y: i32,
) -> RegionalTerrainFields {
	continental_low := regional_terrain_value_noise_2_row_cache_sample(
		&cache.continental_low,
		block_x,
	)
	continental_mid := regional_terrain_value_noise_2_row_cache_sample(
		&cache.continental_mid,
		block_x,
	)
	elevation_low := regional_terrain_value_noise_2_row_cache_sample(&cache.elevation_low, block_x)
	elevation_mid := regional_terrain_value_noise_2_row_cache_sample(&cache.elevation_mid, block_x)
	erosion_low := regional_terrain_value_noise_2_row_cache_sample(&cache.erosion_low, block_x)
	ruggedness_low := regional_terrain_value_noise_2_row_cache_sample(
		&cache.ruggedness_low,
		block_x,
	)
	local_relief := regional_terrain_value_noise_2_row_cache_sample(&cache.local_relief, block_x)
	pressure_noise := regional_terrain_value_noise_2_row_cache_sample(
		&cache.pressure_noise,
		block_x,
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
			regional_terrain_value_noise_2_row_cache_sample(&cache.magic_affinity, block_x) * 0.5,
		),
		corruption_affinity   = regional_terrain_field_saturate(
			0.5 +
			regional_terrain_value_noise_2_row_cache_sample(&cache.corruption_affinity, block_x) *
				0.5,
		),
		heat_affinity         = regional_terrain_field_saturate(
			0.5 +
			regional_terrain_value_noise_2_row_cache_sample(&cache.heat_affinity, block_x) * 0.5,
		),
		cold_affinity         = regional_terrain_field_saturate(
			0.5 +
			regional_terrain_value_noise_2_row_cache_sample(&cache.cold_affinity, block_x) * 0.5,
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

	corner_hash := regional_terrain_field_corner_hash_base(key, salt)
	v00 := regional_terrain_field_corner_value_from_hash(corner_hash, salt, cell_x, cell_z)
	v10 := regional_terrain_field_corner_value_from_hash(corner_hash, salt, cell_x + 1, cell_z)
	v01 := regional_terrain_field_corner_value_from_hash(corner_hash, salt, cell_x, cell_z + 1)
	v11 := regional_terrain_field_corner_value_from_hash(corner_hash, salt, cell_x + 1, cell_z + 1)

	return regional_terrain_field_lerp(
		regional_terrain_field_lerp(v00, v10, t_x),
		regional_terrain_field_lerp(v01, v11, t_x),
		t_z,
	)
}

regional_terrain_field_value_noise_3 :: proc(
	key: FeatureGridKey,
	block_x, block_y, block_z: i32,
	cell_size_blocks: i32,
	salt: u64,
) -> f32 {
	log.assert(cell_size_blocks > 0, "regional 3D field cell size must be positive")

	cell_x := math.floor_div(block_x, cell_size_blocks)
	cell_y := math.floor_div(block_y, cell_size_blocks)
	cell_z := math.floor_div(block_z, cell_size_blocks)
	origin_x := cell_x * cell_size_blocks
	origin_y := cell_y * cell_size_blocks
	origin_z := cell_z * cell_size_blocks
	unit_x := f32(block_x - origin_x) / f32(cell_size_blocks)
	unit_y := f32(block_y - origin_y) / f32(cell_size_blocks)
	unit_z := f32(block_z - origin_z) / f32(cell_size_blocks)
	t_x := math.smoothstep(f32(0), f32(1), unit_x)
	t_y := math.smoothstep(f32(0), f32(1), unit_y)
	t_z := math.smoothstep(f32(0), f32(1), unit_z)

	corner_hash := regional_terrain_field_corner_hash_base(key, salt)
	v000 := regional_terrain_field_corner_value_from_hash_3(
		corner_hash,
		salt,
		cell_x,
		cell_y,
		cell_z,
	)
	v100 := regional_terrain_field_corner_value_from_hash_3(
		corner_hash,
		salt,
		cell_x + 1,
		cell_y,
		cell_z,
	)
	v010 := regional_terrain_field_corner_value_from_hash_3(
		corner_hash,
		salt,
		cell_x,
		cell_y + 1,
		cell_z,
	)
	v110 := regional_terrain_field_corner_value_from_hash_3(
		corner_hash,
		salt,
		cell_x + 1,
		cell_y + 1,
		cell_z,
	)
	v001 := regional_terrain_field_corner_value_from_hash_3(
		corner_hash,
		salt,
		cell_x,
		cell_y,
		cell_z + 1,
	)
	v101 := regional_terrain_field_corner_value_from_hash_3(
		corner_hash,
		salt,
		cell_x + 1,
		cell_y,
		cell_z + 1,
	)
	v011 := regional_terrain_field_corner_value_from_hash_3(
		corner_hash,
		salt,
		cell_x,
		cell_y + 1,
		cell_z + 1,
	)
	v111 := regional_terrain_field_corner_value_from_hash_3(
		corner_hash,
		salt,
		cell_x + 1,
		cell_y + 1,
		cell_z + 1,
	)

	x00 := regional_terrain_field_lerp(v000, v100, t_x)
	x10 := regional_terrain_field_lerp(v010, v110, t_x)
	x01 := regional_terrain_field_lerp(v001, v101, t_x)
	x11 := regional_terrain_field_lerp(v011, v111, t_x)
	y0 := regional_terrain_field_lerp(x00, x10, t_y)
	y1 := regional_terrain_field_lerp(x01, x11, t_y)
	return regional_terrain_field_lerp(y0, y1, t_z)
}

regional_terrain_field_corner_hash_base :: proc(key: FeatureGridKey, salt: u64) -> u64 {
	h := feature_grid_key_hash(key)
	h = feature_grid_hash_combine(h, REGIONAL_TERRAIN_FIELD_DOMAIN_SALT)
	h = feature_grid_hash_combine(h, salt)
	return h
}

regional_terrain_field_corner_value_from_hash :: proc(
	corner_hash: u64,
	salt: u64,
	cell_x, cell_z: i32,
) -> f32 {
	h := feature_grid_hash_combine(corner_hash, feature_grid_hash_i32(cell_x))
	h = feature_grid_hash_combine(h, feature_grid_hash_i32(cell_z))
	return feature_grid_signed_unit_f32(h, salt)
}

regional_terrain_field_corner_value_from_hash_3 :: proc(
	corner_hash: u64,
	salt: u64,
	cell_x, cell_y, cell_z: i32,
) -> f32 {
	h := feature_grid_hash_combine(corner_hash, feature_grid_hash_i32(cell_x))
	h = feature_grid_hash_combine(h, feature_grid_hash_i32(cell_y))
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
			base_height_blocks = 38,
			continental_height_blocks = 52,
			elevation_height_blocks = 36,
			erosion_height_blocks = -8,
			relief_height_blocks = 24,
			relief_amplitude_blocks = 18,
			ruggedness_response = 0.65,
			cliff_bias = 0.10,
			terrace_strength = 0.05,
			cave_openness = 0.20,
			surface_layer_depth_blocks = 4,
			local_detail_amplitude_blocks = 5,
			shoreline_width_blocks = 14,
			shoreline_slope = 0.45,
			underwater_floor_depression_blocks = 2,
			cliff_coast_bias = 0.08,
			swamp_shallowness = 0.10,
			seabed_roughness_blocks = 1,
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
			base_height_blocks = 66,
			continental_height_blocks = 76,
			elevation_height_blocks = 70,
			erosion_height_blocks = -6,
			relief_height_blocks = 48,
			relief_amplitude_blocks = 36,
			ruggedness_response = 1.75,
			cliff_bias = 0.72,
			terrace_strength = 0.42,
			cave_openness = 0.24,
			surface_layer_depth_blocks = 2,
			local_detail_amplitude_blocks = 12,
			shoreline_width_blocks = 8,
			shoreline_slope = 0.72,
			underwater_floor_depression_blocks = 5,
			cliff_coast_bias = 0.50,
			swamp_shallowness = 0.00,
			seabed_roughness_blocks = 4,
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
			shoreline_width_blocks = 26,
			shoreline_slope = 0.18,
			underwater_floor_depression_blocks = 1,
			cliff_coast_bias = 0.00,
			swamp_shallowness = 0.88,
			seabed_roughness_blocks = 0.5,
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
			base_height_blocks = 38,
			continental_height_blocks = 48,
			elevation_height_blocks = 40,
			erosion_height_blocks = -4,
			relief_height_blocks = 28,
			relief_amplitude_blocks = 22,
			ruggedness_response = 0.95,
			cliff_bias = 0.32,
			terrace_strength = 0.18,
			cave_openness = 0.34,
			surface_layer_depth_blocks = 3,
			local_detail_amplitude_blocks = 7,
			shoreline_width_blocks = 14,
			shoreline_slope = 0.34,
			underwater_floor_depression_blocks = 3,
			cliff_coast_bias = 0.18,
			swamp_shallowness = 0.20,
			seabed_roughness_blocks = 2,
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
			shoreline_width_blocks = 10,
			shoreline_slope = 0.35,
			underwater_floor_depression_blocks = 2,
			cliff_coast_bias = 0.05,
			swamp_shallowness = 0.35,
			seabed_roughness_blocks = 1,
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
			shoreline_width_blocks = 7,
			shoreline_slope = 0.70,
			underwater_floor_depression_blocks = 3,
			cliff_coast_bias = 0.40,
			swamp_shallowness = 0.00,
			seabed_roughness_blocks = 3,
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
			shoreline_width_blocks = 22,
			shoreline_slope = 0.22,
			underwater_floor_depression_blocks = 2,
			cliff_coast_bias = 0.02,
			swamp_shallowness = 0.72,
			seabed_roughness_blocks = 1,
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
		shoreline_width_blocks = math.max(f32(1), profile.shoreline_width_blocks),
		shoreline_slope = regional_terrain_field_saturate(profile.shoreline_slope),
		underwater_floor_depression_blocks = math.max(
			f32(0),
			profile.underwater_floor_depression_blocks,
		),
		cliff_coast_bias = regional_terrain_field_saturate(profile.cliff_coast_bias),
		swamp_shallowness = regional_terrain_field_saturate(profile.swamp_shallowness),
		seabed_roughness_blocks = math.max(f32(0), profile.seabed_roughness_blocks),
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
	hydrology_sample := hydrology_layer_surface_sample(key, block_x, block_z)
	return surface_biome_profile_evaluate_with_hydrology(
		key,
		sample,
		hydrology_sample,
		block_x,
		block_z,
	)
}

surface_biome_profile_evaluate_with_hydrology :: proc(
	key: FeatureGridKey,
	sample: SurfaceBiomeFieldSample,
	hydrology_sample: HydrologyLayerSurfaceSample,
	block_x, block_z: i32,
	row_cache: ^SurfaceBiomeProfileRowCache = nil,
) -> SurfaceBiomeProfileEvaluation {
	fields: RegionalTerrainFields
	if row_cache != nil {
		fields = regional_terrain_fields_sample_row(&row_cache.fields, block_x, 0)
	} else {
		fields = regional_terrain_fields_sample(key, block_x, 0, block_z)
	}
	evaluation := SurfaceBiomeProfileEvaluation {
		fields           = fields,
		hydrology_sample = hydrology_sample,
		cell_count       = sample.cell_count,
	}

	for i := u32(0); i < sample.cell_count; i += 1 {
		profile := biome_profile_for(sample.cells[i].biome_id)
		evaluation.targets[i] = biome_shape_target_evaluate(profile, fields)
	}
	evaluation.transition_rule = surface_biome_transition_rule_select(sample)
	evaluation.transition_strength = biome_transition_strength(
		sample.distance_gap,
		evaluation.transition_rule,
	)
	distances: [BIOME_FIELD_NEAREST_CELL_COUNT]f32
	for i := u32(0); i < sample.cell_count; i += 1 {
		distances[i] = sample.cells[i].distance
	}
	biome_transition_blend_weights_write(
		distances[:],
		sample.cell_count,
		SURFACE_BIOME_JUNCTION_BAND_BLOCKS,
		evaluation.transition_rule,
		evaluation.transition_strength,
		evaluation.blend_weights[:],
	)
	evaluation.blended_target = biome_shape_target_blend(
		evaluation.targets[:],
		evaluation.blend_weights[:],
		sample.cell_count,
	)
	evaluation.transitioned_target = biome_transition_rule_apply(
		evaluation.blended_target,
		evaluation.targets[0],
		evaluation.targets[1],
		evaluation.transition_rule,
		evaluation.transition_strength,
		sample.cell_count,
	)
	if row_cache != nil {
		evaluation.transitioned_target = biome_shape_target_apply_surface_relief_row(
			row_cache,
			evaluation.transitioned_target,
			fields,
			block_x,
		)
	} else {
		evaluation.transitioned_target = biome_shape_target_apply_surface_relief(
			key,
			evaluation.transitioned_target,
			fields,
			block_x,
			block_z,
		)
	}
	evaluation.final_target, evaluation.sea_compression_strength =
		biome_shape_target_apply_sea_compression(evaluation.transitioned_target)
	evaluation.hydrology_target = hydrology_layer_apply_surface(
		evaluation.final_target,
		evaluation.hydrology_sample,
	)
	evaluation.final_target = evaluation.hydrology_target
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
	hydrology_sample := hydrology_layer_subterranean_sample(key, block_x, block_y, block_z)
	return subterranean_biome_profile_evaluate_with_hydrology(
		key,
		sample,
		hydrology_sample,
		block_x,
		block_y,
		block_z,
	)
}

subterranean_biome_profile_evaluate_with_hydrology :: proc(
	key: FeatureGridKey,
	sample: SubterraneanBiomeFieldSample,
	hydrology_sample: HydrologyLayerSubterraneanSample,
	block_x, block_y, block_z: i32,
) -> SubterraneanBiomeProfileEvaluation {
	fields := regional_terrain_fields_sample(key, block_x, block_y, block_z)
	evaluation := SubterraneanBiomeProfileEvaluation {
		fields           = fields,
		hydrology_sample = hydrology_sample,
		cell_count       = sample.cell_count,
	}

	for i := u32(0); i < sample.cell_count; i += 1 {
		profile := biome_profile_for(sample.cells[i].biome_id)
		evaluation.targets[i] = biome_shape_target_evaluate(profile, fields)
	}
	evaluation.transition_rule = subterranean_biome_transition_rule_select(sample)
	evaluation.transition_strength = biome_transition_strength(
		sample.distance_gap,
		evaluation.transition_rule,
	)
	distances: [BIOME_FIELD_NEAREST_CELL_COUNT]f32
	for i := u32(0); i < sample.cell_count; i += 1 {
		distances[i] = sample.cells[i].distance
	}
	biome_transition_blend_weights_write(
		distances[:],
		sample.cell_count,
		SUBTERRANEAN_BIOME_JUNCTION_BAND_BLOCKS,
		evaluation.transition_rule,
		evaluation.transition_strength,
		evaluation.blend_weights[:],
	)
	evaluation.blended_target = biome_shape_target_blend(
		evaluation.targets[:],
		evaluation.blend_weights[:],
		sample.cell_count,
	)
	evaluation.transitioned_target = biome_transition_rule_apply(
		evaluation.blended_target,
		evaluation.targets[0],
		evaluation.targets[1],
		evaluation.transition_rule,
		evaluation.transition_strength,
		sample.cell_count,
	)
	evaluation.hydrology_target = hydrology_layer_apply_subterranean(
		evaluation.transitioned_target,
		evaluation.hydrology_sample,
	)
	evaluation.final_target = evaluation.hydrology_target
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
		blended.shoreline_width_blocks += targets[i].shoreline_width_blocks * weight
		blended.shoreline_slope += targets[i].shoreline_slope * weight
		blended.underwater_floor_depression_blocks +=
			targets[i].underwater_floor_depression_blocks * weight
		blended.cliff_coast_bias += targets[i].cliff_coast_bias * weight
		blended.swamp_shallowness += targets[i].swamp_shallowness * weight
		blended.seabed_roughness_blocks += targets[i].seabed_roughness_blocks * weight
		blended.fantasy_affinity += targets[i].fantasy_affinity * weight
	}
	return blended
}

//////////////////////////////////////
// Biome Transition Methods
/////////////////////////////////////

surface_biome_transition_rule_select :: proc(
	sample: SurfaceBiomeFieldSample,
) -> BiomeTransitionRule {
	if sample.cell_count < 2 {
		return biome_transition_rule_generic(SURFACE_BIOME_BLEND_BAND_BLOCKS)
	}
	return biome_transition_rule_for(
		sample.cells[0].biome_id,
		sample.cells[1].biome_id,
		SURFACE_BIOME_BLEND_BAND_BLOCKS,
	)
}

subterranean_biome_transition_rule_select :: proc(
	sample: SubterraneanBiomeFieldSample,
) -> BiomeTransitionRule {
	if sample.cell_count < 2 {
		return biome_transition_rule_generic(SUBTERRANEAN_BIOME_BLEND_BAND_BLOCKS)
	}
	return biome_transition_rule_for(
		sample.cells[0].biome_id,
		sample.cells[1].biome_id,
		SUBTERRANEAN_BIOME_BLEND_BAND_BLOCKS,
	)
}

biome_transition_rule_for :: proc(
	a, b: BiomeID,
	fallback_band_width_blocks: f32,
) -> BiomeTransitionRule {
	if a == b {
		return biome_transition_rule_generic(fallback_band_width_blocks)
	}

	if biome_transition_pair_matches(a, b, .Temperate_Hills, .Wet_Lowland_Marsh) {
		return {
			kind = .Temperate_Marsh_Shelf,
			style = .Soft,
			band_width_blocks = 128,
			dominant_bias = 0.00,
			height_bias_blocks = -1,
			cliff_bias_boost = 0.00,
			terrace_strength_boost = 0.02,
			cave_openness_boost = 0.00,
			local_detail_amplitude_boost_blocks = 0.5,
			fantasy_affinity_boost = 0.02,
			shoreline_width_scale = 1.20,
			underwater_depression_boost_blocks = 0.5,
		}
	}

	if biome_transition_pair_matches(a, b, .Basalt_Spire_Highlands, .Wet_Lowland_Marsh) {
		return {
			kind = .Basalt_Marsh_Cliff,
			style = .Hard,
			band_width_blocks = 72,
			dominant_bias = 0.45,
			height_bias_blocks = 4,
			cliff_bias_boost = 0.30,
			terrace_strength_boost = 0.18,
			cave_openness_boost = 0.00,
			local_detail_amplitude_boost_blocks = 2,
			fantasy_affinity_boost = 0.06,
			shoreline_width_scale = 0.85,
			underwater_depression_boost_blocks = 2,
		}
	}

	if biome_transition_pair_matches(a, b, .Corrupted_Ash_Forest, .Temperate_Hills) {
		return {
			kind = .Corrupted_Border_Band,
			style = .Hard,
			band_width_blocks = 104,
			dominant_bias = 0.30,
			height_bias_blocks = 1,
			cliff_bias_boost = 0.12,
			terrace_strength_boost = 0.08,
			cave_openness_boost = 0.06,
			local_detail_amplitude_boost_blocks = 1.5,
			fantasy_affinity_boost = 0.20,
			shoreline_width_scale = 1.00,
			underwater_depression_boost_blocks = 1,
		}
	}

	if biome_transition_pair_matches(a, b, .Fungal_Vaults, .Buried_Aquifer_Caves) {
		return {
			kind = .Fungal_Aquifer_Connector,
			style = .Soft,
			band_width_blocks = 96,
			dominant_bias = 0.00,
			height_bias_blocks = -2,
			cliff_bias_boost = 0.00,
			terrace_strength_boost = 0.04,
			cave_openness_boost = 0.16,
			local_detail_amplitude_boost_blocks = 1,
			fantasy_affinity_boost = 0.08,
			shoreline_width_scale = 1.15,
			underwater_depression_boost_blocks = 1,
		}
	}

	if biome_transition_pair_matches(a, b, .Crystal_Geode_Network, .Fungal_Vaults) {
		return {
			kind = .Crystal_Geode_Shell,
			style = .Hard,
			band_width_blocks = 60,
			dominant_bias = 0.38,
			height_bias_blocks = 2,
			cliff_bias_boost = 0.22,
			terrace_strength_boost = 0.20,
			cave_openness_boost = -0.08,
			local_detail_amplitude_boost_blocks = 2,
			fantasy_affinity_boost = 0.12,
			shoreline_width_scale = 0.90,
			underwater_depression_boost_blocks = 0,
		}
	}

	return biome_transition_rule_generic(fallback_band_width_blocks)
}

biome_transition_rule_generic :: proc(band_width_blocks: f32) -> BiomeTransitionRule {
	return {
		kind = .Generic_Smooth,
		style = .Soft,
		band_width_blocks = band_width_blocks,
		dominant_bias = 0,
		height_bias_blocks = 0,
		cliff_bias_boost = 0,
		terrace_strength_boost = 0,
		cave_openness_boost = 0,
		local_detail_amplitude_boost_blocks = 0,
		fantasy_affinity_boost = 0,
		shoreline_width_scale = 1,
		underwater_depression_boost_blocks = 0,
	}
}

biome_transition_pair_matches :: proc(a, b, expected_a, expected_b: BiomeID) -> bool {
	return a == expected_a && b == expected_b || a == expected_b && b == expected_a
}

biome_transition_strength :: proc(distance_gap: f32, rule: BiomeTransitionRule) -> f32 {
	return biome_field_boundary_strength(distance_gap, rule.band_width_blocks)
}

biome_transition_blend_weights_write :: proc(
	distances: []f32,
	cell_count: u32,
	junction_band_blocks: f32,
	rule: BiomeTransitionRule,
	transition_strength: f32,
	weights: []f32,
) {
	_, _ = biome_field_blend_weights_write(
		distances,
		cell_count,
		rule.band_width_blocks,
		junction_band_blocks,
		weights,
	)

	if cell_count < 2 || rule.dominant_bias <= 0 || transition_strength <= 0 {
		return
	}

	dominant_push := math.clamp(rule.dominant_bias * transition_strength, f32(0), f32(0.95))
	neighbor_total := f32(0)
	for i := u32(1); i < cell_count; i += 1 {
		neighbor_total += weights[i]
	}
	if neighbor_total <= 0 {
		return
	}

	weights[0] += neighbor_total * dominant_push
	remaining_neighbor_total := math.max(f32(0), 1.0 - weights[0])
	neighbor_scale := remaining_neighbor_total / neighbor_total
	for i := u32(1); i < cell_count; i += 1 {
		weights[i] *= neighbor_scale
	}
}

biome_transition_rule_apply :: proc(
	target, dominant_target, neighbor_target: BiomeShapeTarget,
	rule: BiomeTransitionRule,
	transition_strength: f32,
	cell_count: u32,
) -> BiomeShapeTarget {
	if cell_count < 2 || transition_strength <= 0 {
		return target
	}

	result := target
	if rule.style == .Hard {
		higher_height := math.max(
			dominant_target.surface_height_blocks,
			neighbor_target.surface_height_blocks,
		)
		result.surface_height_blocks +=
			(higher_height - result.surface_height_blocks) *
			rule.dominant_bias *
			transition_strength
	}

	result.surface_height_blocks += rule.height_bias_blocks * transition_strength
	result.cliff_bias = regional_terrain_field_saturate(
		result.cliff_bias + rule.cliff_bias_boost * transition_strength,
	)
	result.terrace_strength = regional_terrain_field_saturate(
		result.terrace_strength + rule.terrace_strength_boost * transition_strength,
	)
	result.cave_openness = regional_terrain_field_saturate(
		result.cave_openness + rule.cave_openness_boost * transition_strength,
	)
	result.local_detail_amplitude_blocks = math.max(
		f32(0),
		result.local_detail_amplitude_blocks +
		rule.local_detail_amplitude_boost_blocks * transition_strength,
	)
	result.fantasy_affinity = regional_terrain_field_saturate(
		result.fantasy_affinity + rule.fantasy_affinity_boost * transition_strength,
	)
	result.shoreline_width_blocks = math.max(
		SEA_COMPRESSION_MIN_SHORELINE_WIDTH_BLOCKS,
		result.shoreline_width_blocks *
		regional_terrain_field_lerp(1, rule.shoreline_width_scale, transition_strength),
	)
	result.underwater_floor_depression_blocks = math.max(
		f32(0),
		result.underwater_floor_depression_blocks +
		rule.underwater_depression_boost_blocks * transition_strength,
	)
	return result
}

biome_shape_target_apply_surface_relief :: proc(
	key: FeatureGridKey,
	target: BiomeShapeTarget,
	fields: RegionalTerrainFields,
	block_x, block_z: i32,
) -> BiomeShapeTarget {
	low := regional_terrain_field_value_noise_2(
		key,
		block_x,
		block_z,
		SURFACE_TERRAIN_RELIEF_LOW_CELL_BLOCKS,
		SURFACE_TERRAIN_RELIEF_LOW_SALT,
	)
	mid := regional_terrain_field_value_noise_2(
		key,
		block_x,
		block_z,
		SURFACE_TERRAIN_RELIEF_MID_CELL_BLOCKS,
		SURFACE_TERRAIN_RELIEF_MID_SALT,
	)
	high := regional_terrain_field_value_noise_2(
		key,
		block_x,
		block_z,
		SURFACE_TERRAIN_RELIEF_HIGH_CELL_BLOCKS,
		SURFACE_TERRAIN_RELIEF_HIGH_SALT,
	)
	ridge_noise := regional_terrain_field_value_noise_2(
		key,
		block_x,
		block_z,
		SURFACE_TERRAIN_RELIEF_RIDGE_CELL_BLOCKS,
		SURFACE_TERRAIN_RELIEF_RIDGE_SALT,
	)
	return biome_shape_target_apply_surface_relief_values(
		target,
		fields,
		low,
		mid,
		high,
		ridge_noise,
	)
}

biome_shape_target_apply_surface_relief_row :: proc(
	cache: ^SurfaceBiomeProfileRowCache,
	target: BiomeShapeTarget,
	fields: RegionalTerrainFields,
	block_x: i32,
) -> BiomeShapeTarget {
	low := regional_terrain_value_noise_2_row_cache_sample(&cache.relief_low, block_x)
	mid := regional_terrain_value_noise_2_row_cache_sample(&cache.relief_mid, block_x)
	high := regional_terrain_value_noise_2_row_cache_sample(&cache.relief_high, block_x)
	ridge_noise := regional_terrain_value_noise_2_row_cache_sample(&cache.relief_ridge, block_x)
	return biome_shape_target_apply_surface_relief_values(
		target,
		fields,
		low,
		mid,
		high,
		ridge_noise,
	)
}

biome_shape_target_apply_surface_relief_values :: proc(
	target: BiomeShapeTarget,
	fields: RegionalTerrainFields,
	low, mid, high, ridge_noise: f32,
) -> BiomeShapeTarget {
	result := target
	ridge := 1.0 - math.abs(ridge_noise)
	ridge_peak := ridge * ridge
	erosion_damp := 1.0 - fields.erosion * 0.35
	relief_signal := low * 0.55 + mid * 0.30 + high * 0.15
	local_signal := high * (0.35 + target.ruggedness_response * 0.35)
	ridge_lift :=
		ridge_peak *
		target.relief_amplitude_blocks *
		(0.45 + target.ruggedness_response) *
		(0.35 + target.cliff_bias * 2.40)

	result.surface_height_blocks +=
		target.relief_amplitude_blocks * relief_signal * erosion_damp +
		target.local_detail_amplitude_blocks * local_signal +
		ridge_lift

	if result.terrace_strength > 0.01 {
		step := SURFACE_TERRAIN_TERRACE_STEP_BLOCKS
		stepped_height := math.floor_f32(result.surface_height_blocks / step + 0.5) * step
		result.surface_height_blocks = regional_terrain_field_lerp(
			result.surface_height_blocks,
			stepped_height,
			math.clamp(result.terrace_strength * 0.55, f32(0), f32(0.85)),
		)
	}
	return result
}

//////////////////////////////////////
// Sea Compression Methods
/////////////////////////////////////

biome_shape_target_apply_sea_compression :: proc(
	target: BiomeShapeTarget,
) -> (
	result: BiomeShapeTarget,
	compression_strength: f32,
) {
	result = target
	shoreline_width := math.max(
		SEA_COMPRESSION_MIN_SHORELINE_WIDTH_BLOCKS,
		target.shoreline_width_blocks,
	)
	height_delta := target.surface_height_blocks - SEA_LEVEL_BLOCKS
	compression_strength = biome_field_boundary_strength(math.abs(height_delta), shoreline_width)
	shoreline_slope := math.clamp(target.shoreline_slope, f32(0.05), f32(1.0))
	result.surface_height_blocks =
		SEA_LEVEL_BLOCKS +
		height_delta * regional_terrain_field_lerp(1.0, shoreline_slope, compression_strength)

	if height_delta < 0 {
		depth := -height_delta
		depth_factor := math.clamp(depth / shoreline_width, f32(0), f32(1))
		depression_scale := regional_terrain_field_lerp(1.0, 0.35, target.swamp_shallowness)
		result.surface_height_blocks -=
			target.underwater_floor_depression_blocks * depth_factor * depression_scale
		result.local_detail_amplitude_blocks += target.seabed_roughness_blocks * depth_factor
	}

	result.cliff_bias = regional_terrain_field_saturate(
		result.cliff_bias +
		target.cliff_coast_bias * compression_strength * (1.0 - target.swamp_shallowness),
	)
	return
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
		fields_row_cache := regional_terrain_fields_row_cache_make(key, -33)
		fields_from_row_cache := regional_terrain_fields_sample_row(&fields_row_cache, 17, -96)
		debug_regional_terrain_fields_assert_equal(fields, fields_from_row_cache)
		next_row_fields := regional_terrain_fields_sample(key, 18, -96, -33)
		next_row_fields_from_cache := regional_terrain_fields_sample_row(
			&fields_row_cache,
			18,
			-96,
		)
		debug_regional_terrain_fields_assert_equal(next_row_fields, next_row_fields_from_cache)

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

		soft_rule := biome_transition_rule_for(
			.Temperate_Hills,
			.Wet_Lowland_Marsh,
			SURFACE_BIOME_BLEND_BAND_BLOCKS,
		)
		hard_rule := biome_transition_rule_for(
			.Basalt_Spire_Highlands,
			.Wet_Lowland_Marsh,
			SURFACE_BIOME_BLEND_BAND_BLOCKS,
		)
		log.assert(
			soft_rule.style == .Soft && soft_rule.kind == .Temperate_Marsh_Shelf,
			"temperate-marsh transition should use a soft shelf rule",
		)
		log.assert(
			hard_rule.style == .Hard && hard_rule.kind == .Basalt_Marsh_Cliff,
			"basalt-marsh transition should use a hard cliff rule",
		)

		boundary_distances := [BIOME_FIELD_NEAREST_CELL_COUNT]f32{10, 10, 220}
		soft_weights: [BIOME_FIELD_NEAREST_CELL_COUNT]f32
		biome_transition_blend_weights_write(
			boundary_distances[:],
			BIOME_FIELD_NEAREST_CELL_COUNT,
			SURFACE_BIOME_JUNCTION_BAND_BLOCKS,
			soft_rule,
			1,
			soft_weights[:],
		)
		hard_weights: [BIOME_FIELD_NEAREST_CELL_COUNT]f32
		biome_transition_blend_weights_write(
			boundary_distances[:],
			BIOME_FIELD_NEAREST_CELL_COUNT,
			SURFACE_BIOME_JUNCTION_BAND_BLOCKS,
			hard_rule,
			1,
			hard_weights[:],
		)
		log.assert(
			hard_weights[0] > soft_weights[0],
			"hard transition should bias blend weights toward the dominant cell",
		)

		hard_applied := biome_transition_rule_apply(
			blended,
			basalt_target,
			marsh_target,
			hard_rule,
			1,
			2,
		)
		log.assert(
			hard_applied.cliff_bias > blended.cliff_bias &&
			hard_applied.terrace_strength > blended.terrace_strength,
			"hard transition should strengthen cliff and terrace shape parameters",
		)

		shore_target := temperate_target
		shore_target.surface_height_blocks = SEA_LEVEL_BLOCKS + 4
		shore_target.shoreline_width_blocks = 16
		shore_target.shoreline_slope = 0.25
		compressed_shore, shore_strength := biome_shape_target_apply_sea_compression(shore_target)
		log.assert(
			shore_strength > 0 &&
			compressed_shore.surface_height_blocks < shore_target.surface_height_blocks,
			"sea compression should flatten terrain near sea level",
		)

		underwater_target := marsh_target
		underwater_target.surface_height_blocks =
			SEA_LEVEL_BLOCKS - underwater_target.shoreline_width_blocks - 8
		compressed_underwater, _ := biome_shape_target_apply_sea_compression(underwater_target)
		log.assert(
			compressed_underwater.surface_height_blocks < underwater_target.surface_height_blocks,
			"sea compression should depress underwater floors",
		)

		surface_evaluation := surface_biome_profile_sample(key, 17, -33)
		log.assert(
			surface_evaluation.cell_count == BIOME_FIELD_NEAREST_CELL_COUNT,
			"surface biome profile evaluation should keep nearest-cell count",
		)
		debug_biome_shape_target_assert_valid(surface_evaluation.blended_target)
		debug_biome_shape_target_assert_valid(surface_evaluation.transitioned_target)
		debug_biome_shape_target_assert_valid(surface_evaluation.hydrology_target)
		debug_biome_shape_target_assert_valid(surface_evaluation.final_target)
		log.assert(
			surface_evaluation.sea_compression_strength >= 0 &&
			surface_evaluation.sea_compression_strength <= 1,
			"surface sea compression strength must be normalized",
		)
		log.assert(
			surface_evaluation.hydrology_sample.nearest_distance_blocks >= 0,
			"surface Hydrology Layer sample should track nearest feature distance",
		)

		subterranean_evaluation := subterranean_biome_profile_sample(key, -45, -96, 130)
		log.assert(
			subterranean_evaluation.cell_count == BIOME_FIELD_NEAREST_CELL_COUNT,
			"subterranean biome profile evaluation should keep nearest-cell count",
		)
		debug_biome_shape_target_assert_valid(subterranean_evaluation.blended_target)
		debug_biome_shape_target_assert_valid(subterranean_evaluation.transitioned_target)
		debug_biome_shape_target_assert_valid(subterranean_evaluation.hydrology_target)
		debug_biome_shape_target_assert_valid(subterranean_evaluation.final_target)
		log.assert(
			subterranean_evaluation.hydrology_sample.nearest_distance_blocks >= 0,
			"subterranean Hydrology Layer sample should track nearest feature distance",
		)

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
		log.assert(target.shoreline_width_blocks >= 1, "shoreline width must be positive")
		log.assert(
			target.shoreline_slope >= 0 && target.shoreline_slope <= 1,
			"shoreline slope range mismatch",
		)
		log.assert(
			target.underwater_floor_depression_blocks >= 0,
			"underwater floor depression must not be negative",
		)
		log.assert(
			target.cliff_coast_bias >= 0 && target.cliff_coast_bias <= 1,
			"cliff coast bias range mismatch",
		)
		log.assert(
			target.swamp_shallowness >= 0 && target.swamp_shallowness <= 1,
			"swamp shallowness range mismatch",
		)
		log.assert(target.seabed_roughness_blocks >= 0, "seabed roughness must not be negative")
		log.assert(
			target.fantasy_affinity >= 0 && target.fantasy_affinity <= 1,
			"fantasy affinity range mismatch",
		)
	}

}
