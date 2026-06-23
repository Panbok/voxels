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

TerrainSurfaceMorphologyColumnFeatureBounds :: struct {
	active:       bool,
	band_above:   f32,
	band_below:   f32,
	feature_hits: u32,
}

TerrainSurfaceMorphologyFeatureColumnBands :: struct {
	active:                 bool,
	influence:              f32,
	radial:                 f32,
	band_above:             f32,
	band_below:             f32,
	subtractive_band_below: f32,
}

TerrainSurfaceMorphologyColumnFeaturePlan :: struct {
	active:                 bool,
	count:                  u32,
	band_above:             f32,
	band_below:             f32,
	subtractive_band_below: f32,
	features:               [biomes.GENERATION_REGION_SURFACE_MORPHOLOGY_FEATURE_CAPACITY]biomes.SurfaceMorphologyFeature,
	bands:                  [biomes.GENERATION_REGION_SURFACE_MORPHOLOGY_FEATURE_CAPACITY]TerrainSurfaceMorphologyFeatureColumnBands,
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
	profile := column.surface_morphology_profile
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
	profile := column.surface_morphology_profile
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

terrain_surface_density_sample_with_feature_plan :: proc(
	column: TerrainBiomeColumn,
	shape: TerrainSurfaceMorphologyColumnShape,
	plan: ^TerrainSurfaceMorphologyColumnFeaturePlan,
	world_x, world_y, world_z: i32,
) -> f32 {
	density := terrain_surface_density_sample_from_shape(column, shape, world_y)
	if world_y < 0 || !plan.active {
		return density
	}

	density += terrain_surface_morphology_feature_plan_density_delta(
		column,
		plan,
		world_x,
		world_y,
		world_z,
	)
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
	profile := column.surface_morphology_profile
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

terrain_surface_morphology_apply_feature_envelopes :: proc(
	evaluation: biomes.SurfaceBiomeProfileEvaluation,
	features: []biomes.SurfaceMorphologyFeature,
	feature_count: u32,
	world_x, world_z: i32,
) -> biomes.SurfaceBiomeProfileEvaluation {
	result := evaluation
	if feature_count == 0 {
		return result
	}

	sample_x := f32(world_x) + 0.5
	sample_z := f32(world_z) + 0.5
	for i := u32(0); i < feature_count; i += 1 {
		feature := features[i]
		planar_influence, radial := terrain_surface_morphology_feature_planar_influence(
			feature,
			sample_x,
			sample_z,
		)
		if planar_influence <= 0.001 {
			continue
		}
		core := 1.0 - math.smoothstep(f32(0.05), f32(0.46), radial)
		shoulder :=
			math.smoothstep(f32(0.26), f32(0.58), radial) *
			(1.0 - math.smoothstep(f32(0.72), f32(1.04), radial))
		moat :=
			math.smoothstep(f32(0.48), f32(0.72), radial) *
			(1.0 - math.smoothstep(f32(0.82), f32(1.10), radial))
		template := biomes.surface_morphology_density_template_for_variant(
			feature.template_variant,
		)
		ridge :=
			terrain_surface_morphology_feature_rib_signal(feature, template, sample_x, sample_z) *
			planar_influence
		lift := feature.envelope_lift_blocks * (core * 0.64 + shoulder * 0.34 + ridge * 0.42)
		cut := feature.envelope_cut_blocks * (moat * 0.82 + (1.0 - ridge) * shoulder * 0.18)
		result.final_target.surface_height_blocks += (lift - cut) * planar_influence
		result.final_target.cliff_bias = biomes.regional_terrain_field_saturate(
			result.final_target.cliff_bias + planar_influence * (shoulder * 0.08 + ridge * 0.06),
		)
		result.final_target.terrace_strength = biomes.regional_terrain_field_saturate(
			result.final_target.terrace_strength +
			planar_influence * feature.shelf_strength * 0.035,
		)
		result.final_target.relief_amplitude_blocks +=
			feature.height_blocks * planar_influence * (ridge * 0.035 + shoulder * 0.018)
	}
	return result
}

terrain_surface_morphology_apply_feature_envelopes_direct :: proc(
	evaluation: biomes.SurfaceBiomeProfileEvaluation,
	key: biomes.FeatureGridKey,
	world_x, world_z: i32,
) -> biomes.SurfaceBiomeProfileEvaluation {
	features: [biomes.FEATURE_GRID_WORLEY_NEIGHBOR_COUNT_2]biomes.SurfaceMorphologyFeature
	feature_count := terrain_surface_morphology_features_for_block_direct(
		key,
		world_x,
		world_z,
		features[:],
	)
	return terrain_surface_morphology_apply_feature_envelopes(
		evaluation,
		features[:],
		feature_count,
		world_x,
		world_z,
	)
}

terrain_surface_morphology_features_for_block_direct :: proc(
	key: biomes.FeatureGridKey,
	world_x, world_z: i32,
	features: []biomes.SurfaceMorphologyFeature,
) -> u32 {
	owners: [biomes.FEATURE_GRID_WORLEY_NEIGHBOR_COUNT_2]biomes.FeatureGridCoord2
	owner_count := biomes.feature_grid_neighbor_owners_from_block(
		world_x,
		world_z,
		biomes.FEATURE_GRID_WORLEY_NEIGHBOR_RADIUS,
		biomes.SURFACE_MORPHOLOGY_OWNER_GRID_CONFIG,
		owners[:],
	)
	count: u32
	for i := u32(0); i < owner_count; i += 1 {
		feature, found := biomes.surface_morphology_feature_from_owner(key, owners[i])
		if !found {
			continue
		}
		influence, _ := terrain_surface_morphology_feature_planar_influence(
			feature,
			f32(world_x) + 0.5,
			f32(world_z) + 0.5,
		)
		if influence <= 0.001 {
			continue
		}
		if count >= u32(len(features)) {
			break
		}
		features[count] = feature
		count += 1
	}
	return count
}

terrain_surface_morphology_column_feature_plan_write :: proc(
	features: []biomes.SurfaceMorphologyFeature,
	feature_count: u32,
	world_x, world_z: i32,
	plan: ^TerrainSurfaceMorphologyColumnFeaturePlan,
) {
	plan^ = {}
	if feature_count == 0 {
		return
	}

	sample_x := f32(world_x) + 0.5
	sample_z := f32(world_z) + 0.5
	for i := u32(0); i < feature_count; i += 1 {
		if plan.count >= u32(len(plan.features)) {
			break
		}

		feature := features[i]
		bands := terrain_surface_morphology_feature_column_bands(feature, sample_x, sample_z)
		if !bands.active {
			continue
		}

		plan.active = true
		plan.features[plan.count] = feature
		plan.bands[plan.count] = bands
		plan.count += 1
		plan.band_above = math.max(plan.band_above, bands.band_above)
		plan.band_below = math.max(plan.band_below, bands.band_below)
		plan.subtractive_band_below = math.max(
			plan.subtractive_band_below,
			bands.subtractive_band_below,
		)
	}
}

terrain_surface_morphology_feature_column_bands :: proc(
	feature: biomes.SurfaceMorphologyFeature,
	sample_x, sample_z: f32,
) -> TerrainSurfaceMorphologyFeatureColumnBands {
	bands := TerrainSurfaceMorphologyFeatureColumnBands{}
	bands.influence, bands.radial = terrain_surface_morphology_feature_planar_influence(
		feature,
		sample_x,
		sample_z,
	)
	if bands.influence <= 0.001 {
		return bands
	}

	bands.active = true
	bands.band_above = 6
	template := biomes.surface_morphology_density_template_for_variant(feature.template_variant)
	for spire_index := u8(0); spire_index < feature.spire_count; spire_index += 1 {
		center_x, center_z, spire_radius, spire_height := terrain_surface_morphology_spire_member(
			feature,
			template,
			spire_index,
		)
		dx := sample_x - center_x
		dz := sample_z - center_z
		spire_outer_radius := spire_radius * 1.85 + 3
		if math.abs(dx) > spire_outer_radius || math.abs(dz) > spire_outer_radius {
			continue
		}
		distance := math.sqrt_f32(dx * dx + dz * dz)
		if distance > spire_outer_radius {
			continue
		}
		lateral := 1.0 - math.smoothstep(spire_radius * 1.05, spire_outer_radius, distance)
		bands.band_above = math.max(
			bands.band_above,
			spire_height * biomes.regional_terrain_field_lerp(f32(0.34), f32(1.0), lateral) + 4,
		)
		bands.band_below = math.max(bands.band_below, feature.cut_depth_blocks * lateral + 2)
	}
	if feature.arch_strength > 0.001 {
		arch_distance := terrain_surface_morphology_feature_arch_plan_distance(
			feature,
			sample_x,
			sample_z,
		)
		arch_radius := math.max(f32(5), feature.radius_blocks * 0.15)
		if arch_distance <= arch_radius {
			arch_lateral := 1.0 - math.smoothstep(arch_radius * 0.55, arch_radius, arch_distance)
			bands.band_above = math.max(
				bands.band_above,
				feature.height_blocks *
					biomes.regional_terrain_field_lerp(f32(0.32), f32(0.55), arch_lateral) +
				4,
			)
			bands.band_below = math.max(
				bands.band_below,
				feature.cut_depth_blocks * arch_lateral + 2,
			)
			bands.subtractive_band_below = math.max(
				bands.subtractive_band_below,
				feature.cut_depth_blocks * arch_lateral + 2,
			)
		}
	}
	if bands.radial >= 0.34 && bands.radial <= 1.0 {
		bands.band_above = math.max(
			bands.band_above,
			math.min(feature.height_blocks * 0.22, f32(18)),
		)
	}
	for branch_index := u8(0); branch_index < template.branch_count; branch_index += 1 {
		branch := template.branches[branch_index]
		width := math.max(f32(2), branch.width_blocks)
		distance, _ := terrain_surface_morphology_feature_template_branch_distance(
			feature,
			branch,
			sample_x,
			sample_z,
		)
		if distance > width * 1.75 {
			continue
		}
		lateral := 1.0 - math.smoothstep(width * 0.55, width * 1.75, distance)
		bands.band_above = math.max(
			bands.band_above,
			feature.height_blocks * branch.height_scale * lateral + 4,
		)
		bands.band_below = math.max(bands.band_below, f32(2) * lateral)
	}
	return bands
}

terrain_surface_morphology_feature_plan_density_delta :: proc(
	column: TerrainBiomeColumn,
	plan: ^TerrainSurfaceMorphologyColumnFeaturePlan,
	world_x, world_y, world_z: i32,
) -> f32 {
	density_delta := f32(0)
	sample_x := f32(world_x) + 0.5
	sample_y := f32(world_y) + 0.5
	sample_z := f32(world_z) + 0.5
	relative_y := sample_y - column.surface_height_blocks
	for i := u32(0); i < plan.count; i += 1 {
		bands := plan.bands[i]
		if relative_y < -bands.band_below - 1 || relative_y > bands.band_above + 1 {
			continue
		}

		feature_delta := terrain_surface_morphology_basalt_spire_field_density(
			plan.features[i],
			column,
			sample_x,
			sample_y,
			sample_z,
			relative_y,
			bands.radial,
		)
		density_delta += feature_delta * bands.influence
	}
	return density_delta
}

terrain_surface_morphology_basalt_spire_field_density :: proc(
	feature: biomes.SurfaceMorphologyFeature,
	column: TerrainBiomeColumn,
	sample_x, sample_y, sample_z, relative_y, radial: f32,
) -> f32 {
	density := f32(0)
	template := biomes.surface_morphology_density_template_for_variant(feature.template_variant)
	for spire_index := u8(0); spire_index < feature.spire_count; spire_index += 1 {
		center_x, center_z, spire_radius, spire_height := terrain_surface_morphology_spire_member(
			feature,
			template,
			spire_index,
		)
		dx := sample_x - center_x
		dz := sample_z - center_z
		height_unit := math.clamp(relative_y / math.max(f32(1), spire_height), f32(0), f32(1))
		taper := biomes.regional_terrain_field_lerp(f32(1), f32(0.24), height_unit)
		radius := math.max(f32(2), spire_radius * taper)
		max_distance := radius * 2.22
		if math.abs(dx) > max_distance || math.abs(dz) > max_distance {
			continue
		}
		distance := math.sqrt_f32(dx * dx + dz * dz)
		if distance > max_distance {
			continue
		}
		lateral := distance / radius
		core := 1.0 - math.smoothstep(f32(0.72), f32(1.08), lateral)
		vertical :=
			1.0 - math.smoothstep(spire_height * 0.78, spire_height, math.max(relative_y, f32(0)))
		root := 1.0 - math.smoothstep(-feature.cut_depth_blocks, f32(2), -relative_y)
		mass := core * vertical * feature.height_blocks * 0.62
		density += mass
		density += root * core * feature.support_bias * 4.0

		shelf := terrain_surface_morphology_feature_shelf_signal(
			feature,
			template,
			relative_y,
			distance,
			radius,
		)
		density += shelf * feature.shelf_strength * template.shelf_strength_scale * core * 5.5
	}

	if template.branch_count > 0 && radial <= 1.0 {
		density += terrain_surface_morphology_feature_template_branch_density(
			feature,
			template,
			sample_x,
			sample_z,
			relative_y,
		)
	}

	if feature.arch_strength > 0.001 {
		arch_distance := terrain_surface_morphology_feature_arch_plan_distance(
			feature,
			sample_x,
			sample_z,
		)
		arch_radius := math.max(f32(5), feature.radius_blocks * 0.15)
		if arch_distance <= arch_radius {
			density += terrain_surface_morphology_feature_arch_density(
				feature,
				column,
				sample_x,
				sample_y,
				sample_z,
				relative_y,
			)
		}
	}

	if radial >= 0.34 && radial <= 1.0 {
		outer_rib := terrain_surface_morphology_feature_rib_signal(
			feature,
			template,
			sample_x,
			sample_z,
		)
		outer_band :=
			math.smoothstep(f32(0.38), f32(0.78), radial) *
			(1.0 - math.smoothstep(f32(0.82), f32(1.12), radial))
		vertical_fade :=
			1.0 -
			math.smoothstep(
				feature.height_blocks * 0.32,
				feature.height_blocks * 0.72,
				math.max(relative_y, f32(0)),
			)
		density +=
			outer_rib *
			outer_band *
			vertical_fade *
			feature.shelf_strength *
			template.rib_strength_scale *
			4.0
	}
	return density
}

terrain_surface_morphology_spire_member :: proc(
	feature: biomes.SurfaceMorphologyFeature,
	template: biomes.SurfaceMorphologyDensityTemplate,
	spire_index: u8,
) -> (
	center_x, center_z, radius, height: f32,
) {
	count := math.max(i32(feature.spire_count), 1)
	index_hash := biomes.feature_grid_hash_combine(u64(feature.id), u64(spire_index) + 1)
	angle :=
		feature.rotation_radians +
		(f32(spire_index) / f32(count)) * f32(6.28318530718) +
		biomes.feature_grid_signed_unit_f32(index_hash, biomes.SURFACE_MORPHOLOGY_ROTATION_SALT) *
			0.42
	ring :=
		feature.radius_blocks *
		biomes.regional_terrain_field_lerp(
			f32(0.12),
			f32(0.58),
			biomes.feature_grid_unit_f32(index_hash, biomes.SURFACE_MORPHOLOGY_RADIUS_SALT),
		)
	if spire_index == 0 {
		ring *= 0.22
	}
	center_x = feature.x + math.cos(angle) * ring
	center_z = feature.z + math.sin(angle) * ring
	radius =
		feature.radius_blocks *
		biomes.regional_terrain_field_lerp(
			f32(0.11),
			f32(0.21),
			biomes.feature_grid_unit_f32(index_hash, biomes.SURFACE_MORPHOLOGY_SHELF_SALT),
		)
	if spire_index == 0 {
		radius *= 1.28
	}
	radius *= template.spire_radius_scale
	height =
		feature.height_blocks *
		biomes.regional_terrain_field_lerp(
			f32(0.58),
			f32(1.08),
			biomes.feature_grid_unit_f32(index_hash, biomes.SURFACE_MORPHOLOGY_HEIGHT_SALT),
		)
	height *= template.spire_height_scale
	return
}

terrain_surface_morphology_feature_arch_plan_distance :: proc(
	feature: biomes.SurfaceMorphologyFeature,
	sample_x, sample_z: f32,
) -> f32 {
	dir_x := math.cos(feature.rotation_radians)
	dir_z := math.sin(feature.rotation_radians)
	half_span := feature.radius_blocks * 0.38
	ax := feature.x - dir_x * half_span
	az := feature.z - dir_z * half_span
	bx := feature.x + dir_x * half_span
	bz := feature.z + dir_z * half_span
	seg_x := bx - ax
	seg_z := bz - az
	seg_len_sq := math.max(seg_x * seg_x + seg_z * seg_z, f32(0.001))
	t := math.clamp(
		((sample_x - ax) * seg_x + (sample_z - az) * seg_z) / seg_len_sq,
		f32(0),
		f32(1),
	)
	nearest_x := ax + seg_x * t
	nearest_z := az + seg_z * t
	dx := sample_x - nearest_x
	dz := sample_z - nearest_z
	return math.sqrt_f32(dx * dx + dz * dz)
}

terrain_surface_morphology_feature_arch_density :: proc(
	feature: biomes.SurfaceMorphologyFeature,
	column: TerrainBiomeColumn,
	sample_x, sample_y, sample_z, relative_y: f32,
) -> f32 {
	_ = column
	dir_x := math.cos(feature.rotation_radians)
	dir_z := math.sin(feature.rotation_radians)
	half_span := feature.radius_blocks * 0.38
	ax := feature.x - dir_x * half_span
	az := feature.z - dir_z * half_span
	bx := feature.x + dir_x * half_span
	bz := feature.z + dir_z * half_span
	seg_x := bx - ax
	seg_z := bz - az
	seg_len_sq := math.max(seg_x * seg_x + seg_z * seg_z, f32(0.001))
	t := math.clamp(
		((sample_x - ax) * seg_x + (sample_z - az) * seg_z) / seg_len_sq,
		f32(0),
		f32(1),
	)
	nearest_x := ax + seg_x * t
	nearest_z := az + seg_z * t
	dx := sample_x - nearest_x
	dz := sample_z - nearest_z
	span_distance := math.sqrt_f32(dx * dx + dz * dz)
	arch_center_y := feature.height_blocks * 0.30
	arch_rise := math.sin(t * f32(3.14159265359)) * feature.height_blocks * 0.16
	bridge_y := arch_center_y + arch_rise
	bridge_shape :=
		(span_distance / math.max(f32(3), feature.radius_blocks * 0.085)) *
			(span_distance / math.max(f32(3), feature.radius_blocks * 0.085)) +
		((relative_y - bridge_y) / math.max(f32(2.5), feature.height_blocks * 0.055)) *
			((relative_y - bridge_y) / math.max(f32(2.5), feature.height_blocks * 0.055))
	bridge :=
		(1.0 - math.smoothstep(f32(0.78), f32(1.12), bridge_shape)) *
		feature.arch_strength *
		feature.height_blocks *
		0.34

	opening_y := bridge_y - feature.height_blocks * 0.16
	opening_shape :=
		(span_distance / math.max(f32(4), feature.radius_blocks * 0.11)) *
			(span_distance / math.max(f32(4), feature.radius_blocks * 0.11)) +
		((relative_y - opening_y) / math.max(f32(3), feature.height_blocks * 0.11)) *
			((relative_y - opening_y) / math.max(f32(3), feature.height_blocks * 0.11))
	opening :=
		(1.0 - math.smoothstep(f32(0.62), f32(1.00), opening_shape)) *
		feature.arch_strength *
		feature.cut_depth_blocks *
		1.10
	if relative_y < -feature.cut_depth_blocks || relative_y > bridge_y {
		opening = 0
	}
	return bridge - opening
}

terrain_surface_morphology_feature_template_branch_distance :: proc(
	feature: biomes.SurfaceMorphologyFeature,
	branch: biomes.SurfaceMorphologyDensityBranch,
	sample_x, sample_z: f32,
) -> (
	distance: f32,
	t: f32,
) {
	angle := feature.rotation_radians + branch.angle_turns * f32(6.28318530718)
	dir_x := math.cos(angle)
	dir_z := math.sin(angle)
	ax := feature.x + dir_x * feature.radius_blocks * branch.start_radius_scale
	az := feature.z + dir_z * feature.radius_blocks * branch.start_radius_scale
	bx := feature.x + dir_x * feature.radius_blocks * branch.end_radius_scale
	bz := feature.z + dir_z * feature.radius_blocks * branch.end_radius_scale
	seg_x := bx - ax
	seg_z := bz - az
	seg_len_sq := math.max(seg_x * seg_x + seg_z * seg_z, f32(0.001))
	t = math.clamp(
		((sample_x - ax) * seg_x + (sample_z - az) * seg_z) / seg_len_sq,
		f32(0),
		f32(1),
	)
	nearest_x := ax + seg_x * t
	nearest_z := az + seg_z * t
	dx := sample_x - nearest_x
	dz := sample_z - nearest_z
	distance = math.sqrt_f32(dx * dx + dz * dz)
	return
}

terrain_surface_morphology_feature_template_branch_density :: proc(
	feature: biomes.SurfaceMorphologyFeature,
	template: biomes.SurfaceMorphologyDensityTemplate,
	sample_x, sample_z, relative_y: f32,
) -> f32 {
	density := f32(0)
	for branch_index := u8(0); branch_index < template.branch_count; branch_index += 1 {
		branch := template.branches[branch_index]
		width := math.max(f32(2), branch.width_blocks)
		distance, t := terrain_surface_morphology_feature_template_branch_distance(
			feature,
			branch,
			sample_x,
			sample_z,
		)
		if distance > width * 1.75 {
			continue
		}

		lateral := 1.0 - math.smoothstep(width * 0.55, width * 1.75, distance)
		height_band := math.max(f32(4), feature.height_blocks * branch.height_scale)
		vertical :=
			1.0 - math.smoothstep(height_band * 0.45, height_band, math.max(relative_y, f32(0)))
		if relative_y < -feature.cut_depth_blocks * 0.25 {
			vertical *=
				1.0 -
				math.smoothstep(
					feature.cut_depth_blocks * 0.25,
					feature.cut_depth_blocks,
					-relative_y,
				)
		}

		taper := biomes.regional_terrain_field_lerp(f32(1.0), f32(0.66), t)
		density +=
			lateral * vertical * taper * branch.strength * template.branch_strength_scale * 5.0
	}
	return density
}

terrain_surface_morphology_feature_shelf_signal :: proc(
	feature: biomes.SurfaceMorphologyFeature,
	template: biomes.SurfaceMorphologyDensityTemplate,
	relative_y, distance, radius: f32,
) -> f32 {
	if relative_y < -1 || relative_y > feature.height_blocks * 0.78 {
		return 0
	}
	shelf_step :=
		biomes.regional_terrain_field_lerp(f32(7.5), f32(4.8), feature.shelf_strength) *
		template.shelf_step_scale
	coord := (relative_y + f32(feature.template_variant) * 1.37) / shelf_step
	phase := coord - math.floor_f32(coord)
	wave := 1.0 - math.abs(phase * 2.0 - 1.0)
	edge := math.smoothstep(f32(0.62), f32(1.12), distance / math.max(f32(1), radius))
	edge *= 1.0 - math.smoothstep(f32(1.36), f32(2.18), distance / math.max(f32(1), radius))
	return math.smoothstep(f32(0.76), f32(0.98), wave) * edge
}

terrain_surface_morphology_feature_rib_signal :: proc(
	feature: biomes.SurfaceMorphologyFeature,
	template: biomes.SurfaceMorphologyDensityTemplate,
	sample_x, sample_z: f32,
) -> f32 {
	dx := sample_x - feature.x
	dz := sample_z - feature.z
	angle := math.atan2(dz, dx) + feature.rotation_radians
	radial := math.sqrt_f32(dx * dx + dz * dz) / math.max(f32(1), feature.radius_blocks)
	wave := terrain_surface_morphology_triangle_wave(
		angle * f32(0.15915494309) * template.rib_frequency + radial * template.rib_radial_phase,
	)
	return math.smoothstep(f32(0.70), f32(0.96), wave)
}

terrain_surface_morphology_feature_planar_influence :: proc(
	feature: biomes.SurfaceMorphologyFeature,
	sample_x, sample_z: f32,
) -> (
	influence, radial: f32,
) {
	dx := sample_x - feature.x
	dz := sample_z - feature.z
	influence_radius := math.max(f32(1), feature.influence_radius_blocks)
	if math.abs(dx) > influence_radius || math.abs(dz) > influence_radius {
		radial = f32(2)
		return
	}
	distance := math.sqrt_f32(dx * dx + dz * dz)
	radial = distance / influence_radius
	influence = 1.0 - math.smoothstep(f32(0.72), f32(1.0), radial)
	return
}

terrain_surface_morphology_triangle_wave :: proc(value: f32) -> f32 {
	phase := value - math.floor_f32(value)
	return 1.0 - math.abs(phase * 2.0 - 1.0)
}
