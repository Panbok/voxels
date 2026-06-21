package world

import biomes "world:biomes"

import math "core:math"

//////////////////////////////////////
// Surface Morphology Methods
/////////////////////////////////////

TerrainSurfaceMorphologyColumnShape :: struct {
	profile:     biomes.SurfaceMorphologyProfile,
	strength:    f32,
	band_above:  f32,
	band_below:  f32,
	broad:       f32,
	fine:        f32,
	ridge:       f32,
	shelf_noise: f32,
	spire_core:  f32,
	cell_size:   i32,
}

terrain_surface_base_density_sample :: proc(column: TerrainBiomeColumn, world_y: i32) -> f32 {
	return column.surface_height_blocks - f32(world_y)
}

terrain_surface_density_column_lower_influence_blocks :: proc(column: TerrainBiomeColumn) -> f32 {
	material_depth := f32(column.surface_layer_depth + TERRAIN_DIRT_LAYER_BLOCK_DEPTH)
	return material_depth
}

terrain_surface_density_column_may_intersect_chunk :: proc(
	column: TerrainBiomeColumn,
	chunk_bottom_world_y, chunk_top_world_y: i32,
) -> bool {
	profile := biomes.surface_morphology_profile_for_biome(column.dominant_biome_id)
	strength := terrain_surface_morphology_effective_strength(column, profile)
	lower_influence := terrain_surface_density_column_lower_influence_blocks(column)
	upper_influence := f32(0)
	if strength > 0.001 {
		upper_influence = math.max(f32(0), profile.band_above_blocks)
	}
	return(
		f32(chunk_bottom_world_y) <= column.surface_height_blocks + upper_influence &&
		f32(chunk_top_world_y) >= column.surface_height_blocks - lower_influence \
	)
}

terrain_surface_density_column_is_deep_stone_chunk :: proc(
	column: TerrainBiomeColumn,
	chunk_top_world_y: i32,
) -> bool {
	if chunk_top_world_y < 0 {
		material_depth := column.surface_layer_depth + TERRAIN_DIRT_LAYER_BLOCK_DEPTH
		return column.surface_height - chunk_top_world_y >= material_depth
	}
	lower_influence := terrain_surface_density_column_lower_influence_blocks(column)
	return column.surface_height_blocks - f32(chunk_top_world_y) >= lower_influence
}

terrain_surface_morphology_column_shape_make :: proc(
	key: biomes.FeatureGridKey,
	column: TerrainBiomeColumn,
	world_x, world_z: i32,
) -> TerrainSurfaceMorphologyColumnShape {
	profile := biomes.surface_morphology_profile_for_biome(column.dominant_biome_id)
	strength := terrain_surface_morphology_effective_strength(column, profile)
	band_above := math.max(f32(0), profile.band_above_blocks)
	band_below := math.max(f32(1), profile.band_below_blocks)
	cell_size := terrain_surface_morphology_cell_size(column)

	shape := TerrainSurfaceMorphologyColumnShape {
		profile    = profile,
		strength   = strength,
		band_above = band_above,
		band_below = band_below,
		cell_size  = cell_size,
	}
	if strength <= 0.001 {
		return shape
	}

	shape.broad = biomes.regional_terrain_field_value_noise_2(
		key,
		world_x,
		world_z,
		cell_size,
		TERRAIN_SURFACE_MORPHOLOGY_BROAD_SALT,
	)
	shape.fine = biomes.regional_terrain_field_value_noise_2(
		key,
		world_x,
		world_z,
		math.max(cell_size / 2, 7),
		TERRAIN_SURFACE_MORPHOLOGY_FINE_SALT,
	)
	ridge_noise := biomes.regional_terrain_field_value_noise_2(
		key,
		world_x,
		world_z,
		math.max((cell_size * 3) / 4, 9),
		TERRAIN_SURFACE_MORPHOLOGY_RIDGE_SALT,
	)
	shape.ridge = 1.0 - math.abs(ridge_noise)
	shape.ridge *= shape.ridge

	shape.shelf_noise = shape.broad * 0.65 + shape.fine * 0.35
	spire_seed :=
		shape.ridge * 0.66 +
		math.max(f32(0), shape.broad) * 0.22 +
		math.max(f32(0), shape.fine) * 0.12
	shape.spire_core = math.smoothstep(f32(0.48), f32(0.84), spire_seed)
	return shape
}

terrain_surface_density_sample_from_shape :: proc(
	column: TerrainBiomeColumn,
	shape: TerrainSurfaceMorphologyColumnShape,
	world_y: i32,
) -> f32 {
	base_density := terrain_surface_base_density_sample(column, world_y)
	if world_y < 0 || shape.strength <= 0.001 {
		return base_density
	}
	if base_density >= 0 {
		return base_density
	}

	if base_density < -shape.band_above || base_density > shape.band_below {
		return base_density
	}

	band_fade := terrain_surface_morphology_band_fade(
		base_density,
		shape.band_above,
		shape.band_below,
	)
	if band_fade <= 0.001 {
		return base_density
	}

	density := base_density
	above_surface_unit := f32(0)
	if base_density < 0 && shape.band_above > 0 {
		above_surface_unit = math.clamp(-base_density / shape.band_above, f32(0), f32(1))
	}
	surface_attachment := 1.0 - math.smoothstep(f32(0.42), f32(0.82), above_surface_unit)
	mass_signal := shape.broad * 0.42 + shape.fine * 0.18 + (shape.ridge - 0.32) * 0.70
	additive_mass :=
		math.max(f32(0), mass_signal) *
		shape.strength *
		band_fade *
		biomes.regional_terrain_field_lerp(f32(2.20), f32(1.15), above_surface_unit)
	subtractive_mass := math.max(f32(0), -mass_signal) * shape.strength * band_fade * 2.55
	density += additive_mass - subtractive_mass

	shelf := terrain_surface_morphology_shelf_signal(shape, world_y)
	density +=
		shelf *
		shape.profile.shelf_strength *
		shape.strength *
		band_fade *
		surface_attachment *
		2.35

	undercut_band := terrain_surface_morphology_undercut_band(base_density, shape.band_below)
	undercut_signal := math.smoothstep(
		f32(0.10),
		f32(0.78),
		shape.broad * 0.72 + shape.fine * 0.28,
	)
	undercut_support_scale :=
		1.0 - math.clamp(shape.profile.support_bias * 0.72, f32(0), f32(0.88))
	density -=
		undercut_signal *
		shape.profile.overhang_strength *
		shape.strength *
		undercut_band *
		undercut_support_scale *
		8.25

	spire_vertical_fade := terrain_surface_morphology_spire_vertical_fade(
		base_density,
		shape.band_above,
		shape.band_below,
	)
	spire_height_unit := f32(0)
	if shape.band_above > 0 && base_density < 0 {
		spire_height_unit = math.clamp(-base_density / shape.band_above, f32(0), f32(1))
	}
	spire_tip_taper := 1.0 - math.smoothstep(f32(0.72), f32(1), spire_height_unit)
	density +=
		shape.spire_core *
		shape.profile.spire_strength *
		shape.strength *
		spire_vertical_fade *
		spire_tip_taper *
		shape.band_above *
		0.90

	support_density :=
		shape.profile.support_bias *
		shape.strength *
		band_fade *
		math.smoothstep(f32(0), math.max(f32(1), shape.band_below * 0.55), base_density) *
		1.50
	density += support_density

	return density
}

terrain_surface_morphology_effective_strength :: proc(
	column: TerrainBiomeColumn,
	profile: biomes.SurfaceMorphologyProfile,
) -> f32 {
	strength := math.clamp(profile.strength, f32(0), f32(1))
	if column.water_fill_active {
		return 0
	}
	if strength <= 0.18 {
		return 0
	}
	return strength
}

terrain_surface_morphology_cell_size :: proc(column: TerrainBiomeColumn) -> i32 {
	profile := biomes.surface_morphology_profile_for_biome(column.dominant_biome_id)
	cell_size := i32(math.floor_f32(profile.cell_blocks + 0.5))
	return math.clamp(cell_size, 8, 64)
}

terrain_surface_morphology_band_fade :: proc(base_density, band_above, band_below: f32) -> f32 {
	if base_density < 0 {
		if band_above <= 0 {
			return 0
		}
		return math.smoothstep(-band_above, f32(-1), base_density)
	}
	return 1.0 - math.smoothstep(band_below * 0.45, band_below, base_density)
}

terrain_surface_morphology_undercut_band :: proc(base_density, band_below: f32) -> f32 {
	if base_density < 0 {
		return 0
	}
	near_surface := math.smoothstep(f32(0), f32(3.5), base_density)
	deep_fade := 1.0 - math.smoothstep(band_below * 0.35, band_below * 0.86, base_density)
	return near_surface * deep_fade
}

terrain_surface_morphology_spire_vertical_fade :: proc(
	base_density, band_above, band_below: f32,
) -> f32 {
	if base_density < 0 {
		if band_above <= 0 {
			return 0
		}
		return math.smoothstep(-band_above, f32(-2), base_density)
	}
	return 1.0 - math.smoothstep(band_below * 0.45, band_below, base_density)
}

terrain_surface_morphology_shelf_signal :: proc(
	shape: TerrainSurfaceMorphologyColumnShape,
	world_y: i32,
) -> f32 {
	shelf_step := biomes.regional_terrain_field_lerp(
		f32(8.5),
		f32(4.5),
		math.clamp(shape.profile.shelf_strength, f32(0), f32(1)),
	)
	shelf_coord := (f32(world_y) + shape.shelf_noise * shelf_step * 0.35) / shelf_step
	shelf_phase := shelf_coord - math.floor_f32(shelf_coord)
	shelf_center := 1.0 - math.abs(shelf_phase * 2.0 - 1.0)
	return math.smoothstep(f32(0.60), f32(0.96), shelf_center)
}
