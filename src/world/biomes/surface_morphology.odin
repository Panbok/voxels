package biomes

import math "core:math"

//////////////////////////////////////
// Surface Morphology Feature Types
/////////////////////////////////////

SurfaceMorphologyFeatureKind :: enum u8 {
	Basalt_Spire_Field,
}

SurfaceMorphologyFeatureSource :: enum u8 {
	Owner_Grid,
	Anchor_Linked,
}

SurfaceMorphologyDensityTemplateID :: enum u8 {
	Crown_Spires,
	DLA_Rootweb,
	Colonized_Rib_Arc,
	Needle_Rake,
}

SurfaceMorphologyDensityBranch :: struct {
	angle_turns:        f32,
	start_radius_scale: f32,
	end_radius_scale:   f32,
	width_blocks:       f32,
	height_scale:       f32,
	strength:           f32,
}

SurfaceMorphologyDensityTemplate :: struct {
	id:                    SurfaceMorphologyDensityTemplateID,
	spire_radius_scale:    f32,
	spire_height_scale:    f32,
	shelf_step_scale:      f32,
	shelf_strength_scale:  f32,
	rib_frequency:         f32,
	rib_radial_phase:      f32,
	rib_strength_scale:    f32,
	branch_strength_scale: f32,
	branch_count:          u8,
	branches:              [SURFACE_MORPHOLOGY_DENSITY_TEMPLATE_BRANCH_CAPACITY]SurfaceMorphologyDensityBranch,
}

SurfaceMorphologyFeature :: struct {
	id:                      FeatureID,
	owner:                   FeatureGridCoord2,
	source:                  SurfaceMorphologyFeatureSource,
	kind:                    SurfaceMorphologyFeatureKind,
	x, z:                    f32,
	biome_id:                BiomeID,
	biome_weight:            f32,
	radius_blocks:           f32,
	influence_radius_blocks: f32,
	height_blocks:           f32,
	cut_depth_blocks:        f32,
	envelope_lift_blocks:    f32,
	envelope_cut_blocks:     f32,
	rotation_radians:        f32,
	template_variant:        u8,
	spire_count:             u8,
	arch_strength:           f32,
	shelf_strength:          f32,
	support_bias:            f32,
}

//////////////////////////////////////
// Surface Morphology Feature Constants
/////////////////////////////////////

SURFACE_MORPHOLOGY_OWNER_GRID_CONFIG :: FeatureGridConfig {
	domain           = .Surface,
	level            = .Micro,
	cell_size_blocks = 192,
	jitter_fraction  = 0.72,
}

SURFACE_MORPHOLOGY_INFLUENCE_MARGIN_BLOCKS :: 192
GENERATION_REGION_SURFACE_MORPHOLOGY_FEATURE_CAPACITY :: 64
SURFACE_MORPHOLOGY_DENSITY_TEMPLATE_BRANCH_CAPACITY :: 4
SURFACE_MORPHOLOGY_DENSITY_TEMPLATE_COUNT :: 4
SURFACE_MORPHOLOGY_TEMPLATE_VARIANT_COUNT :: u8(SURFACE_MORPHOLOGY_DENSITY_TEMPLATE_COUNT)

SURFACE_MORPHOLOGY_FEATURE_ID_SALT :: u64(0x45b6c7d8123a9f0e)
SURFACE_MORPHOLOGY_ROLL_SALT :: u64(0xe6a9d21f348c70b5)
SURFACE_MORPHOLOGY_RADIUS_SALT :: u64(0x8d2f41b67c90ae35)
SURFACE_MORPHOLOGY_HEIGHT_SALT :: u64(0x2fa8b3d79e104c65)
SURFACE_MORPHOLOGY_ROTATION_SALT :: u64(0xa31d6c84e9f2570b)
SURFACE_MORPHOLOGY_TEMPLATE_SALT :: u64(0x7c198e52d6a4b03f)
SURFACE_MORPHOLOGY_SPIRE_COUNT_SALT :: u64(0x9ea3f6152b7c408d)
SURFACE_MORPHOLOGY_ARCH_SALT :: u64(0xb7d4e10983fa6c25)
SURFACE_MORPHOLOGY_SHELF_SALT :: u64(0x53c1a7d94f268be0)

SURFACE_MORPHOLOGY_DENSITY_TEMPLATES :=
	[SURFACE_MORPHOLOGY_DENSITY_TEMPLATE_COUNT]SurfaceMorphologyDensityTemplate {
		{
			id = .Crown_Spires,
			spire_radius_scale = 1.05,
			spire_height_scale = 1.08,
			shelf_step_scale = 0.92,
			shelf_strength_scale = 1.08,
			rib_frequency = 4.0,
			rib_radial_phase = 1.35,
			rib_strength_scale = 0.86,
			branch_strength_scale = 0.36,
			branch_count = 1,
			branches = {
				{
					angle_turns = 0.08,
					start_radius_scale = 0.18,
					end_radius_scale = 0.52,
					width_blocks = 5.5,
					height_scale = 0.18,
					strength = 0.56,
				},
				{},
				{},
				{},
			},
		},
		{
			id = .DLA_Rootweb,
			spire_radius_scale = 0.90,
			spire_height_scale = 0.96,
			shelf_step_scale = 1.14,
			shelf_strength_scale = 0.94,
			rib_frequency = 6.0,
			rib_radial_phase = 2.15,
			rib_strength_scale = 1.18,
			branch_strength_scale = 1.22,
			branch_count = 4,
			branches = {
				{
					angle_turns = 0.03,
					start_radius_scale = 0.10,
					end_radius_scale = 0.70,
					width_blocks = 6.5,
					height_scale = 0.21,
					strength = 0.82,
				},
				{
					angle_turns = 0.21,
					start_radius_scale = 0.22,
					end_radius_scale = 0.82,
					width_blocks = 4.8,
					height_scale = 0.16,
					strength = 0.74,
				},
				{
					angle_turns = 0.49,
					start_radius_scale = 0.14,
					end_radius_scale = 0.64,
					width_blocks = 5.6,
					height_scale = 0.19,
					strength = 0.78,
				},
				{
					angle_turns = 0.76,
					start_radius_scale = 0.30,
					end_radius_scale = 0.92,
					width_blocks = 4.2,
					height_scale = 0.14,
					strength = 0.66,
				},
			},
		},
		{
			id = .Colonized_Rib_Arc,
			spire_radius_scale = 1.12,
			spire_height_scale = 0.88,
			shelf_step_scale = 1.02,
			shelf_strength_scale = 1.16,
			rib_frequency = 5.0,
			rib_radial_phase = 1.72,
			rib_strength_scale = 1.04,
			branch_strength_scale = 0.92,
			branch_count = 3,
			branches = {
				{
					angle_turns = 0.12,
					start_radius_scale = 0.18,
					end_radius_scale = 0.88,
					width_blocks = 7.2,
					height_scale = 0.24,
					strength = 0.72,
				},
				{
					angle_turns = 0.36,
					start_radius_scale = 0.24,
					end_radius_scale = 0.78,
					width_blocks = 6.0,
					height_scale = 0.27,
					strength = 0.68,
				},
				{
					angle_turns = 0.67,
					start_radius_scale = 0.20,
					end_radius_scale = 0.86,
					width_blocks = 6.8,
					height_scale = 0.22,
					strength = 0.70,
				},
				{},
			},
		},
		{
			id = .Needle_Rake,
			spire_radius_scale = 0.78,
			spire_height_scale = 1.20,
			shelf_step_scale = 0.82,
			shelf_strength_scale = 0.82,
			rib_frequency = 7.5,
			rib_radial_phase = 2.65,
			rib_strength_scale = 0.96,
			branch_strength_scale = 0.64,
			branch_count = 2,
			branches = {
				{
					angle_turns = 0.18,
					start_radius_scale = 0.16,
					end_radius_scale = 0.76,
					width_blocks = 4.0,
					height_scale = 0.17,
					strength = 0.72,
				},
				{
					angle_turns = 0.58,
					start_radius_scale = 0.28,
					end_radius_scale = 0.94,
					width_blocks = 3.8,
					height_scale = 0.15,
					strength = 0.66,
				},
				{},
				{},
			},
		},
	}

//////////////////////////////////////
// Surface Morphology Feature Methods
/////////////////////////////////////

surface_morphology_feature_from_owner :: proc(
	key: FeatureGridKey,
	owner: FeatureGridCoord2,
) -> (
	feature: SurfaceMorphologyFeature,
	found: bool,
) {
	point := surface_morphology_owner_point_from_owner(key, owner)
	sample := surface_biome_field_sample(
		key,
		i32(math.floor_f32(point.x)),
		i32(math.floor_f32(point.z)),
	)
	basalt_weight := surface_morphology_biome_weight(sample, .Basalt_Spire_Highlands)
	if basalt_weight < 0.30 {
		return
	}

	chance := regional_terrain_field_lerp(f32(0.18), f32(0.72), basalt_weight)
	roll := feature_grid_unit_f32(u64(point.id), SURFACE_MORPHOLOGY_ROLL_SALT)
	if roll > chance {
		return
	}

	radius_roll := feature_grid_unit_f32(u64(point.id), SURFACE_MORPHOLOGY_RADIUS_SALT)
	height_roll := feature_grid_unit_f32(u64(point.id), SURFACE_MORPHOLOGY_HEIGHT_SALT)
	shelf_roll := feature_grid_unit_f32(u64(point.id), SURFACE_MORPHOLOGY_SHELF_SALT)
	arch_roll := feature_grid_unit_f32(u64(point.id), SURFACE_MORPHOLOGY_ARCH_SALT)
	radius := regional_terrain_field_lerp(f32(78), f32(136), radius_roll)
	height :=
		regional_terrain_field_lerp(f32(26), f32(58), height_roll) *
		regional_terrain_field_lerp(f32(0.86), f32(1.16), basalt_weight)
	template_roll := feature_grid_unit_f32(u64(point.id), SURFACE_MORPHOLOGY_TEMPLATE_SALT)
	template_variant := u8(
		math.floor_f32(template_roll * f32(SURFACE_MORPHOLOGY_TEMPLATE_VARIANT_COUNT)),
	)
	if template_variant >= SURFACE_MORPHOLOGY_TEMPLATE_VARIANT_COUNT {
		template_variant = SURFACE_MORPHOLOGY_TEMPLATE_VARIANT_COUNT - 1
	}

	spire_roll := feature_grid_unit_f32(u64(point.id), SURFACE_MORPHOLOGY_SPIRE_COUNT_SALT)
	spire_count := u8(3 + math.floor_f32(spire_roll * 4))
	if spire_count > 6 {
		spire_count = 6
	}

	arch_strength := f32(0)
	if arch_roll > 0.58 {
		arch_strength = math.smoothstep(f32(0.58), f32(0.96), arch_roll)
	}

	feature = {
		id                      = point.id,
		owner                   = owner,
		source                  = .Owner_Grid,
		kind                    = .Basalt_Spire_Field,
		x                       = point.x,
		z                       = point.z,
		biome_id                = .Basalt_Spire_Highlands,
		biome_weight            = basalt_weight,
		radius_blocks           = radius,
		influence_radius_blocks = radius + 28,
		height_blocks           = height,
		cut_depth_blocks        = regional_terrain_field_lerp(f32(7), f32(15), arch_strength),
		envelope_lift_blocks    = height * regional_terrain_field_lerp(
			f32(0.24),
			f32(0.46),
			basalt_weight,
		),
		envelope_cut_blocks     = regional_terrain_field_lerp(f32(5), f32(13), height_roll),
		rotation_radians        = feature_grid_unit_f32(
			u64(point.id),
			SURFACE_MORPHOLOGY_ROTATION_SALT,
		) * f32(6.28318530718),
		template_variant        = template_variant,
		spire_count             = spire_count,
		arch_strength           = arch_strength,
		shelf_strength          = regional_terrain_field_lerp(f32(0.58), f32(0.96), shelf_roll),
		support_bias            = regional_terrain_field_lerp(f32(0.52), f32(0.78), basalt_weight),
	}
	found = true
	return
}

surface_morphology_density_template_for_variant :: proc(
	template_variant: u8,
) -> SurfaceMorphologyDensityTemplate {
	index := i32(template_variant)
	if index < 0 || index >= SURFACE_MORPHOLOGY_DENSITY_TEMPLATE_COUNT {
		index = 0
	}
	return SURFACE_MORPHOLOGY_DENSITY_TEMPLATES[index]
}

surface_morphology_owner_point_from_owner :: proc(
	key: FeatureGridKey,
	owner: FeatureGridCoord2,
) -> FeaturePoint2 {
	feature_grid_config_validate(SURFACE_MORPHOLOGY_OWNER_GRID_CONFIG)

	base_id := feature_id_from_grid_coord(key, SURFACE_MORPHOLOGY_OWNER_GRID_CONFIG, owner)
	hash := feature_grid_hash_combine(u64(base_id), SURFACE_MORPHOLOGY_FEATURE_ID_SALT)
	cell_size := f32(SURFACE_MORPHOLOGY_OWNER_GRID_CONFIG.cell_size_blocks)
	jitter_radius := cell_size * 0.5 * SURFACE_MORPHOLOGY_OWNER_GRID_CONFIG.jitter_fraction
	return {
		id = FeatureID(hash),
		owner = owner,
		x = feature_grid_cell_center(owner.x, cell_size) +
		feature_grid_signed_unit_f32(hash, FEATURE_GRID_JITTER_X_SALT) * jitter_radius,
		z = feature_grid_cell_center(owner.z, cell_size) +
		feature_grid_signed_unit_f32(hash, FEATURE_GRID_JITTER_Z_SALT) * jitter_radius,
	}
}

surface_morphology_biome_weight :: proc(
	sample: SurfaceBiomeFieldSample,
	biome_id: BiomeID,
) -> f32 {
	weight := f32(0)
	for i := u32(0); i < sample.cell_count; i += 1 {
		if sample.cells[i].biome_id == biome_id {
			weight += sample.blend_weights[i]
		}
	}
	return math.clamp(weight, f32(0), f32(1))
}
