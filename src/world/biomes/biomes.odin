package biomes

import "core:log"
import math "core:math"

//////////////////////////////////////
// Feature Grid Types
/////////////////////////////////////

// FeatureID is the stable deterministic identity for one Generation Feature.
FeatureID :: distinct u64

// FeatureGridKey is the deterministic root key for generated feature grids.
FeatureGridKey :: struct {
	world_seed:        u64,
	generator_version: u32,
}

// IVec2 is the signed integer pair used by horizontal X/Z feature-grid code.
IVec2 :: struct {
	x, z: i32,
}

IVec3 :: struct {
	x, y, z: i32,
}

// FeatureGridDomain separates feature spaces that answer different generation questions.
FeatureGridDomain :: enum u8 {
	// Surface owns horizontal biome identity for above-ground and near-surface terrain.
	Surface,
	// Subterranean owns 3D underground biome identity independent from surface cells.
	Subterranean,
}

// FeatureGridLevel identifies the hierarchy layer that owns a feature point.
FeatureGridLevel :: enum u8 {
	// Macro owns broad climate, continent, and fantasy-zone bias.
	Macro,
	// Biome owns the local biome cells sampled by terrain generation.
	Biome,
	// Micro owns optional small patches, anomalies, and local transition details.
	Micro,
}

// FeatureGridCoord2 is a canonical 2D Generation Feature owner coordinate.
FeatureGridCoord2 :: IVec2

// FeatureGridCoord3 is a canonical 3D Generation Feature owner coordinate.
FeatureGridCoord3 :: IVec3

FeatureGridConfig :: struct {
	domain:           FeatureGridDomain,
	level:            FeatureGridLevel,
	cell_size_blocks: i32,
	jitter_fraction:  f32,
}

// BlockBounds2 is a half-open X/Z block range: min included, max excluded.
BlockBounds2 :: struct {
	min, max: IVec2,
}

// BlockBounds3 is a half-open X/Y/Z block range: min included, max excluded.
BlockBounds3 :: struct {
	min, max: IVec3,
}

// FeatureGridOwnerRange2 is an inclusive range of 2D feature-grid owner cells.
FeatureGridOwnerRange2 :: struct {
	min, max: FeatureGridCoord2,
}

// FeatureGridOwnerRange3 is an inclusive range of 3D feature-grid owner cells.
FeatureGridOwnerRange3 :: struct {
	min, max: FeatureGridCoord3,
}

FeaturePoint2 :: struct {
	id:    FeatureID,
	owner: FeatureGridCoord2,
	x, z:  f32,
}

FeaturePoint3 :: struct {
	id:      FeatureID,
	owner:   FeatureGridCoord3,
	x, y, z: f32,
}

//////////////////////////////////////
// Biome Field Types
/////////////////////////////////////

// BiomeID names the starter biome catalog used by biome field samples.
BiomeID :: enum u8 {
	// Surface baseline for ordinary hills, grass, dirt, stone, and default soft borders.
	Temperate_Hills,
	// Surface high-relief fantasy biome for cliffs, spires, hard borders, and stone-heavy terrain.
	Basalt_Spire_Highlands,
	// Surface lowland biome for shorelines, shallow water, marsh shelves, and soft wet borders.
	Wet_Lowland_Marsh,
	// Surface hostile biome for ash layers, dead terrain, and structured corrupted borders.
	Corrupted_Ash_Forest,
	// Subterranean major-region biome for broad chambers and fungal terrain identity.
	Fungal_Vaults,
	// Subterranean pocket-or-major biome for crystal shells, geodes, and mineral networks.
	Crystal_Geode_Network,
	// Subterranean water-linked biome for aquifers, flooded passages, and buried water routes.
	Buried_Aquifer_Caves,
}

// SurfaceMacroZone biases local surface Biome Cell identity at a coarse world scale.
SurfaceMacroZone :: enum u8 {
	// Ordinary broad climate zone biased toward temperate hills with compatible neighbors.
	Temperate,
	// Fantasy volcanic zone biased toward basalt spires and rugged stone terrain.
	Volcanic,
	// Wet broad zone biased toward marshes, shores, and shallow-water terrain.
	Wetland,
	// Hostile broad zone biased toward corrupted ash terrain and deliberate border clashes.
	Corrupted,
}

// SubterraneanMacroZone biases underground Biome Cell identity independently from the surface.
SubterraneanMacroZone :: enum u8 {
	// Organic/rooted underground bias for fungal vaults and living cave forms.
	Rooted,
	// Stone and mineral bias for crystal networks, geodes, and harder cave structure.
	Mineral,
	// Water-bearing underground bias for aquifers, flooded caves, and buried water links.
	Aquifer,
}

// SubterraneanDepthBand biases underground biome identity without forcing strict layers.
SubterraneanDepthBand :: enum u8 {
	// Near-surface underground range where entrances and mixed cave identities are common.
	Shallow,
	// Mid-depth range where major fungal, crystal, and aquifer regions become likely.
	Mid,
	// Deep range biased toward larger mineral or water-linked underground structures.
	Deep,
}

SurfaceBiomeCell :: struct {
	feature:          FeaturePoint2,
	biome_id:         BiomeID,
	macro_zone:       SurfaceMacroZone,
	macro_feature_id: FeatureID,
	distance:         f32,
	distance_sq:      f32,
}

SubterraneanBiomeCell :: struct {
	feature:          FeaturePoint3,
	biome_id:         BiomeID,
	macro_zone:       SubterraneanMacroZone,
	depth_band:       SubterraneanDepthBand,
	macro_feature_id: FeatureID,
	distance:         f32,
	distance_sq:      f32,
}

SurfaceBiomeFieldSample :: struct {
	cells:          [BIOME_FIELD_NEAREST_CELL_COUNT]SurfaceBiomeCell,
	blend_weights:  [BIOME_FIELD_NEAREST_CELL_COUNT]f32,
	cell_count:     u32,
	dominant_index: u32,
	distance_gap:   f32,
	boundary_blend: f32,
}

SubterraneanBiomeFieldSample :: struct {
	cells:          [BIOME_FIELD_NEAREST_CELL_COUNT]SubterraneanBiomeCell,
	blend_weights:  [BIOME_FIELD_NEAREST_CELL_COUNT]f32,
	cell_count:     u32,
	dominant_index: u32,
	distance_gap:   f32,
	boundary_blend: f32,
}

//////////////////////////////////////
// Feature Grid Constants
/////////////////////////////////////

SURFACE_MACRO_GRID_CONFIG :: FeatureGridConfig {
	domain           = .Surface,
	level            = .Macro,
	cell_size_blocks = 4096,
	jitter_fraction  = 0.65,
}
SURFACE_BIOME_GRID_CONFIG :: FeatureGridConfig {
	domain           = .Surface,
	level            = .Biome,
	cell_size_blocks = 512,
	jitter_fraction  = 0.85,
}
SURFACE_MICRO_GRID_CONFIG :: FeatureGridConfig {
	domain           = .Surface,
	level            = .Micro,
	cell_size_blocks = 128,
	jitter_fraction  = 0.90,
}
SUBTERRANEAN_MACRO_GRID_CONFIG :: FeatureGridConfig {
	domain           = .Subterranean,
	level            = .Macro,
	cell_size_blocks = 2048,
	jitter_fraction  = 0.60,
}
SUBTERRANEAN_BIOME_GRID_CONFIG :: FeatureGridConfig {
	domain           = .Subterranean,
	level            = .Biome,
	cell_size_blocks = 384,
	jitter_fraction  = 0.80,
}
SUBTERRANEAN_MICRO_GRID_CONFIG :: FeatureGridConfig {
	domain           = .Subterranean,
	level            = .Micro,
	cell_size_blocks = 96,
	jitter_fraction  = 0.90,
}

FEATURE_GRID_WORLEY_NEIGHBOR_RADIUS :: i32(1)
FEATURE_GRID_WORLEY_NEIGHBOR_COUNT_2 :: 9
FEATURE_GRID_WORLEY_NEIGHBOR_COUNT_3 :: 27
FEATURE_GRID_HASH_OFFSET :: u64(0x9e3779b97f4a7c15)
FEATURE_GRID_HASH_MIX_A :: u64(0xbf58476d1ce4e5b9)
FEATURE_GRID_HASH_MIX_B :: u64(0x94d049bb133111eb)
FEATURE_GRID_UNIT_MASK :: u64(0xffffff)
FEATURE_GRID_UNIT_DENOMINATOR :: f32(16777216.0)

FEATURE_GRID_DIMENSION_2 :: u64(2)
FEATURE_GRID_DIMENSION_3 :: u64(3)
FEATURE_GRID_JITTER_X_SALT :: u64(0x58f38ded2cb2f381)
FEATURE_GRID_JITTER_Y_SALT :: u64(0xbadad4f8142c1a49)
FEATURE_GRID_JITTER_Z_SALT :: u64(0xd1b54a32d192ed03)

//////////////////////////////////////
// Biome Field Constants
/////////////////////////////////////

BIOME_FIELD_NEAREST_CELL_COUNT :: 3
BIOME_FIELD_NO_DISTANCE :: f32(1.0e30)

SURFACE_BIOME_BLEND_BAND_BLOCKS :: f32(96.0)
SURFACE_BIOME_JUNCTION_BAND_BLOCKS :: f32(32.0)
SUBTERRANEAN_BIOME_BLEND_BAND_BLOCKS :: f32(72.0)
SUBTERRANEAN_BIOME_JUNCTION_BAND_BLOCKS :: f32(28.0)

SURFACE_MACRO_ZONE_SALT :: u64(0x7f4a7c159e3779b9)
SUBTERRANEAN_MACRO_ZONE_SALT :: u64(0xc2b2ae3d27d4eb4f)
SURFACE_BIOME_IDENTITY_SALT :: u64(0x243f6a8885a308d3)
SUBTERRANEAN_BIOME_IDENTITY_SALT :: u64(0x13198a2e03707344)
BIOME_ADJACENCY_CLASH_SALT :: u64(0xa4093822299f31d0)

SURFACE_BIOME_RARE_CLASH_CHANCE :: f32(0.08)
SUBTERRANEAN_BIOME_RARE_CLASH_CHANCE :: f32(0.10)

//////////////////////////////////////
// Feature Grid Config Methods
/////////////////////////////////////

feature_grid_key_make :: proc(world_seed: u64, generator_version: u32) -> FeatureGridKey {
	return {world_seed = world_seed, generator_version = generator_version}
}

feature_grid_config_for :: proc(
	domain: FeatureGridDomain,
	level: FeatureGridLevel,
) -> FeatureGridConfig {
	switch domain {
	case .Surface:
		switch level {
		case .Macro:
			return SURFACE_MACRO_GRID_CONFIG
		case .Biome:
			return SURFACE_BIOME_GRID_CONFIG
		case .Micro:
			return SURFACE_MICRO_GRID_CONFIG
		}
	case .Subterranean:
		switch level {
		case .Macro:
			return SUBTERRANEAN_MACRO_GRID_CONFIG
		case .Biome:
			return SUBTERRANEAN_BIOME_GRID_CONFIG
		case .Micro:
			return SUBTERRANEAN_MICRO_GRID_CONFIG
		}
	}

	log.assertf(false, "unhandled feature grid config: domain=%v level=%v", domain, level)
	return {}
}

feature_grid_config_validate :: proc(config: FeatureGridConfig) {
	log.assert(config.cell_size_blocks > 0, "feature grid cell size must be positive")
	log.assert(
		config.jitter_fraction >= 0 && config.jitter_fraction <= 1,
		"feature grid jitter fraction must be in [0, 1]",
	)
}

//////////////////////////////////////
// Feature Grid Bounds Methods
/////////////////////////////////////

feature_grid_block_bounds_validate :: proc {
	feature_grid_block_bounds_validate_2,
	feature_grid_block_bounds_validate_3,
}

feature_grid_block_bounds_validate_2 :: proc(bounds: BlockBounds2) {
	log.assert(bounds.min.x < bounds.max.x, "2D block bounds must have positive x length")
	log.assert(bounds.min.z < bounds.max.z, "2D block bounds must have positive z length")
}

feature_grid_block_bounds_validate_3 :: proc(bounds: BlockBounds3) {
	log.assert(bounds.min.x < bounds.max.x, "3D block bounds must have positive x length")
	log.assert(bounds.min.y < bounds.max.y, "3D block bounds must have positive y length")
	log.assert(bounds.min.z < bounds.max.z, "3D block bounds must have positive z length")
}

feature_grid_owner_range_validate :: proc {
	feature_grid_owner_range_validate_2,
	feature_grid_owner_range_validate_3,
}

feature_grid_owner_range_validate_2 :: proc(owner_range: FeatureGridOwnerRange2) {
	log.assert(owner_range.min.x <= owner_range.max.x, "2D owner range x is inverted")
	log.assert(owner_range.min.z <= owner_range.max.z, "2D owner range z is inverted")
}

feature_grid_owner_range_validate_3 :: proc(owner_range: FeatureGridOwnerRange3) {
	log.assert(owner_range.min.x <= owner_range.max.x, "3D owner range x is inverted")
	log.assert(owner_range.min.y <= owner_range.max.y, "3D owner range y is inverted")
	log.assert(owner_range.min.z <= owner_range.max.z, "3D owner range z is inverted")
}

feature_grid_owner_range_from_block_bounds :: proc {
	feature_grid_owner_range_from_block_bounds_2,
	feature_grid_owner_range_from_block_bounds_3,
}

feature_grid_owner_range_from_block_bounds_2 :: proc(
	bounds: BlockBounds2,
	influence_margin_blocks: i32,
	config: FeatureGridConfig,
) -> FeatureGridOwnerRange2 {
	feature_grid_config_validate(config)
	feature_grid_block_bounds_validate(bounds)
	log.assert(influence_margin_blocks >= 0, "2D influence margin must not be negative")

	return {
		min = feature_grid_owner_from_block(
			bounds.min.x - influence_margin_blocks,
			bounds.min.z - influence_margin_blocks,
			config,
		),
		max = feature_grid_owner_from_block(
			bounds.max.x + influence_margin_blocks - 1,
			bounds.max.z + influence_margin_blocks - 1,
			config,
		),
	}
}

feature_grid_owner_range_from_block_bounds_3 :: proc(
	bounds: BlockBounds3,
	influence_margin_blocks: i32,
	config: FeatureGridConfig,
) -> FeatureGridOwnerRange3 {
	feature_grid_config_validate(config)
	feature_grid_block_bounds_validate(bounds)
	log.assert(influence_margin_blocks >= 0, "3D influence margin must not be negative")

	return {
		min = feature_grid_owner_from_block(
			bounds.min.x - influence_margin_blocks,
			bounds.min.y - influence_margin_blocks,
			bounds.min.z - influence_margin_blocks,
			config,
		),
		max = feature_grid_owner_from_block(
			bounds.max.x + influence_margin_blocks - 1,
			bounds.max.y + influence_margin_blocks - 1,
			bounds.max.z + influence_margin_blocks - 1,
			config,
		),
	}
}

feature_grid_owner_range_count :: proc {
	feature_grid_owner_range_count_2,
	feature_grid_owner_range_count_3,
}

feature_grid_owner_range_count_2 :: proc(owner_range: FeatureGridOwnerRange2) -> u32 {
	feature_grid_owner_range_validate(owner_range)
	width := owner_range.max.x - owner_range.min.x + 1
	depth := owner_range.max.z - owner_range.min.z + 1
	return u32(width * depth)
}

feature_grid_owner_range_count_3 :: proc(owner_range: FeatureGridOwnerRange3) -> u32 {
	feature_grid_owner_range_validate(owner_range)
	width := owner_range.max.x - owner_range.min.x + 1
	height := owner_range.max.y - owner_range.min.y + 1
	depth := owner_range.max.z - owner_range.min.z + 1
	return u32(width * height * depth)
}

feature_grid_owner_range_write :: proc {
	feature_grid_owner_range_write_2,
	feature_grid_owner_range_write_3,
}

feature_grid_owner_range_write_2 :: proc(
	owner_range: FeatureGridOwnerRange2,
	owners: []FeatureGridCoord2,
) -> u32 {
	count_required := feature_grid_owner_range_count(owner_range)
	log.assertf(
		u32(len(owners)) >= count_required,
		"2D owner output too small: required=%d got=%d",
		count_required,
		len(owners),
	)

	count: u32
	for z := owner_range.min.z; z <= owner_range.max.z; z += 1 {
		for x := owner_range.min.x; x <= owner_range.max.x; x += 1 {
			owners[count] = {
				x = x,
				z = z,
			}
			count += 1
		}
	}
	return count
}

feature_grid_owner_range_write_3 :: proc(
	owner_range: FeatureGridOwnerRange3,
	owners: []FeatureGridCoord3,
) -> u32 {
	count_required := feature_grid_owner_range_count(owner_range)
	log.assertf(
		u32(len(owners)) >= count_required,
		"3D owner output too small: required=%d got=%d",
		count_required,
		len(owners),
	)

	count: u32
	for z := owner_range.min.z; z <= owner_range.max.z; z += 1 {
		for y := owner_range.min.y; y <= owner_range.max.y; y += 1 {
			for x := owner_range.min.x; x <= owner_range.max.x; x += 1 {
				owners[count] = {
					x = x,
					y = y,
					z = z,
				}
				count += 1
			}
		}
	}
	return count
}

feature_grid_neighbor_owner_count_2 :: proc(neighbor_radius: i32) -> u32 {
	log.assert(neighbor_radius >= 0, "2D neighbor radius must not be negative")
	diameter := neighbor_radius * 2 + 1
	return u32(diameter * diameter)
}

feature_grid_neighbor_owner_count_3 :: proc(neighbor_radius: i32) -> u32 {
	log.assert(neighbor_radius >= 0, "3D neighbor radius must not be negative")
	diameter := neighbor_radius * 2 + 1
	return u32(diameter * diameter * diameter)
}

feature_grid_neighbor_owners_from_block :: proc {
	feature_grid_neighbor_owners_from_block_2,
	feature_grid_neighbor_owners_from_block_3,
}

feature_grid_neighbor_owners_from_block_2 :: proc(
	block_x, block_z: i32,
	neighbor_radius: i32,
	config: FeatureGridConfig,
	owners: []FeatureGridCoord2,
) -> u32 {
	log.assert(neighbor_radius >= 0, "2D neighbor radius must not be negative")
	center := feature_grid_owner_from_block(block_x, block_z, config)
	owner_range := FeatureGridOwnerRange2 {
		min = {x = center.x - neighbor_radius, z = center.z - neighbor_radius},
		max = {x = center.x + neighbor_radius, z = center.z + neighbor_radius},
	}
	return feature_grid_owner_range_write(owner_range, owners)
}

feature_grid_neighbor_owners_from_block_3 :: proc(
	block_x, block_y, block_z: i32,
	neighbor_radius: i32,
	config: FeatureGridConfig,
	owners: []FeatureGridCoord3,
) -> u32 {
	log.assert(neighbor_radius >= 0, "3D neighbor radius must not be negative")
	center := feature_grid_owner_from_block(block_x, block_y, block_z, config)
	owner_range := FeatureGridOwnerRange3 {
		min = {
			x = center.x - neighbor_radius,
			y = center.y - neighbor_radius,
			z = center.z - neighbor_radius,
		},
		max = {
			x = center.x + neighbor_radius,
			y = center.y + neighbor_radius,
			z = center.z + neighbor_radius,
		},
	}
	return feature_grid_owner_range_write(owner_range, owners)
}

//////////////////////////////////////
// Feature Grid Methods
/////////////////////////////////////

feature_id_from_grid_coord :: proc {
	feature_id_from_grid_coord_2,
	feature_id_from_grid_coord_3,
}

feature_id_from_grid_coord_2 :: proc(
	key: FeatureGridKey,
	config: FeatureGridConfig,
	coord: FeatureGridCoord2,
) -> FeatureID {
	h := feature_grid_hash_base(key, config, FEATURE_GRID_DIMENSION_2)
	h = feature_grid_hash_combine(h, feature_grid_hash_i32(coord.x))
	h = feature_grid_hash_combine(h, feature_grid_hash_i32(coord.z))
	return FeatureID(h)
}

feature_id_from_grid_coord_3 :: proc(
	key: FeatureGridKey,
	config: FeatureGridConfig,
	coord: FeatureGridCoord3,
) -> FeatureID {
	h := feature_grid_hash_base(key, config, FEATURE_GRID_DIMENSION_3)
	h = feature_grid_hash_combine(h, feature_grid_hash_i32(coord.x))
	h = feature_grid_hash_combine(h, feature_grid_hash_i32(coord.y))
	h = feature_grid_hash_combine(h, feature_grid_hash_i32(coord.z))
	return FeatureID(h)
}

feature_grid_owner_from_block :: proc {
	feature_grid_owner_from_block_2,
	feature_grid_owner_from_block_3,
}

feature_grid_owner_from_block_2 :: proc(
	block_x, block_z: i32,
	config: FeatureGridConfig,
) -> FeatureGridCoord2 {
	feature_grid_config_validate(config)
	return {
		x = math.floor_div(block_x, config.cell_size_blocks),
		z = math.floor_div(block_z, config.cell_size_blocks),
	}
}

feature_grid_owner_from_block_3 :: proc(
	block_x, block_y, block_z: i32,
	config: FeatureGridConfig,
) -> FeatureGridCoord3 {
	feature_grid_config_validate(config)
	return {
		x = math.floor_div(block_x, config.cell_size_blocks),
		y = math.floor_div(block_y, config.cell_size_blocks),
		z = math.floor_div(block_z, config.cell_size_blocks),
	}
}

feature_grid_point_from_owner :: proc {
	feature_grid_point_from_owner_2,
	feature_grid_point_from_owner_3,
}

feature_grid_point_from_owner_2 :: proc(
	key: FeatureGridKey,
	config: FeatureGridConfig,
	owner: FeatureGridCoord2,
) -> FeaturePoint2 {
	feature_grid_config_validate(config)

	id := feature_id_from_grid_coord(key, config, owner)
	hash := u64(id)
	cell_size := f32(config.cell_size_blocks)
	jitter_radius := cell_size * 0.5 * config.jitter_fraction

	return {
		id = id,
		owner = owner,
		x = feature_grid_cell_center(owner.x, cell_size) +
		feature_grid_signed_unit_f32(hash, FEATURE_GRID_JITTER_X_SALT) * jitter_radius,
		z = feature_grid_cell_center(owner.z, cell_size) +
		feature_grid_signed_unit_f32(hash, FEATURE_GRID_JITTER_Z_SALT) * jitter_radius,
	}
}

feature_grid_point_from_owner_3 :: proc(
	key: FeatureGridKey,
	config: FeatureGridConfig,
	owner: FeatureGridCoord3,
) -> FeaturePoint3 {
	feature_grid_config_validate(config)

	id := feature_id_from_grid_coord(key, config, owner)
	hash := u64(id)
	cell_size := f32(config.cell_size_blocks)
	jitter_radius := cell_size * 0.5 * config.jitter_fraction

	return {
		id = id,
		owner = owner,
		x = feature_grid_cell_center(owner.x, cell_size) +
		feature_grid_signed_unit_f32(hash, FEATURE_GRID_JITTER_X_SALT) * jitter_radius,
		y = feature_grid_cell_center(owner.y, cell_size) +
		feature_grid_signed_unit_f32(hash, FEATURE_GRID_JITTER_Y_SALT) * jitter_radius,
		z = feature_grid_cell_center(owner.z, cell_size) +
		feature_grid_signed_unit_f32(hash, FEATURE_GRID_JITTER_Z_SALT) * jitter_radius,
	}
}

feature_grid_cell_center :: proc(cell_coord: i32, cell_size: f32) -> f32 {
	return f32(cell_coord) * cell_size + cell_size * 0.5
}

feature_grid_key_hash :: proc(key: FeatureGridKey) -> u64 {
	h := feature_grid_hash_mix(key.world_seed)
	h = feature_grid_hash_combine(h, u64(key.generator_version))
	return h
}

feature_grid_hash_base :: proc(
	key: FeatureGridKey,
	config: FeatureGridConfig,
	dimension: u64,
) -> u64 {
	feature_grid_config_validate(config)

	h := feature_grid_key_hash(key)
	h = feature_grid_hash_combine(h, dimension)
	h = feature_grid_hash_combine(h, u64(u8(config.domain)))
	h = feature_grid_hash_combine(h, u64(u8(config.level)))
	return h
}

feature_grid_hash_i32 :: proc(value: i32) -> u64 {
	return u64(u32(value))
}

feature_grid_hash_combine :: proc(hash, value: u64) -> u64 {
	return feature_grid_hash_mix(
		hash ~ (value + FEATURE_GRID_HASH_OFFSET + (hash << 6) + (hash >> 2)),
	)
}

feature_grid_hash_mix :: proc(value: u64) -> u64 {
	x := value
	x = (x ~ (x >> 30)) * FEATURE_GRID_HASH_MIX_A
	x = (x ~ (x >> 27)) * FEATURE_GRID_HASH_MIX_B
	x = x ~ (x >> 31)
	return x
}

feature_grid_unit_f32 :: proc(hash, salt: u64) -> f32 {
	mixed := feature_grid_hash_combine(hash, salt)
	unit_bits := (mixed >> 40) & FEATURE_GRID_UNIT_MASK
	return f32(unit_bits) / FEATURE_GRID_UNIT_DENOMINATOR
}

feature_grid_signed_unit_f32 :: proc(hash, salt: u64) -> f32 {
	return feature_grid_unit_f32(hash, salt) * 2.0 - 1.0
}

//////////////////////////////////////
// Biome Identity Methods
/////////////////////////////////////

biome_id_is_surface :: proc(biome_id: BiomeID) -> bool {
	#partial switch biome_id {
	case .Temperate_Hills, .Basalt_Spire_Highlands, .Wet_Lowland_Marsh, .Corrupted_Ash_Forest:
		return true
	}
	return false
}

biome_id_is_subterranean :: proc(biome_id: BiomeID) -> bool {
	#partial switch biome_id {
	case .Fungal_Vaults, .Crystal_Geode_Network, .Buried_Aquifer_Caves:
		return true
	}
	return false
}

surface_macro_zone_from_feature_id :: proc(feature_id: FeatureID) -> SurfaceMacroZone {
	roll := feature_grid_unit_f32(u64(feature_id), SURFACE_MACRO_ZONE_SALT)
	if roll < 0.45 {
		return .Temperate
	}
	if roll < 0.65 {
		return .Wetland
	}
	if roll < 0.85 {
		return .Volcanic
	}
	return .Corrupted
}

subterranean_macro_zone_from_feature_id :: proc(feature_id: FeatureID) -> SubterraneanMacroZone {
	roll := feature_grid_unit_f32(u64(feature_id), SUBTERRANEAN_MACRO_ZONE_SALT)
	if roll < 0.36 {
		return .Rooted
	}
	if roll < 0.70 {
		return .Mineral
	}
	return .Aquifer
}

surface_biome_identity_from_macro_roll :: proc(
	macro_zone: SurfaceMacroZone,
	roll: f32,
) -> BiomeID {
	switch macro_zone {
	case .Temperate:
		if roll < 0.70 {
			return .Temperate_Hills
		}
		if roll < 0.84 {
			return .Wet_Lowland_Marsh
		}
		if roll < 0.94 {
			return .Basalt_Spire_Highlands
		}
		return .Corrupted_Ash_Forest
	case .Wetland:
		if roll < 0.68 {
			return .Wet_Lowland_Marsh
		}
		if roll < 0.86 {
			return .Temperate_Hills
		}
		if roll < 0.95 {
			return .Corrupted_Ash_Forest
		}
		return .Basalt_Spire_Highlands
	case .Volcanic:
		if roll < 0.68 {
			return .Basalt_Spire_Highlands
		}
		if roll < 0.84 {
			return .Temperate_Hills
		}
		if roll < 0.96 {
			return .Corrupted_Ash_Forest
		}
		return .Wet_Lowland_Marsh
	case .Corrupted:
		if roll < 0.70 {
			return .Corrupted_Ash_Forest
		}
		if roll < 0.84 {
			return .Basalt_Spire_Highlands
		}
		if roll < 0.93 {
			return .Wet_Lowland_Marsh
		}
		return .Temperate_Hills
	}

	log.assertf(false, "unhandled surface macro zone: %v", macro_zone)
	return .Temperate_Hills
}

subterranean_depth_band_from_y :: proc(block_y: i32) -> SubterraneanDepthBand {
	if block_y > -128 {
		return .Shallow
	}
	if block_y > -512 {
		return .Mid
	}
	return .Deep
}

subterranean_biome_identity_from_macro_depth_roll :: proc(
	macro_zone: SubterraneanMacroZone,
	depth_band: SubterraneanDepthBand,
	roll: f32,
) -> BiomeID {
	switch macro_zone {
	case .Rooted:
		switch depth_band {
		case .Shallow:
			if roll < 0.52 {
				return .Fungal_Vaults
			}
			if roll < 0.78 {
				return .Buried_Aquifer_Caves
			}
			return .Crystal_Geode_Network
		case .Mid:
			if roll < 0.66 {
				return .Fungal_Vaults
			}
			if roll < 0.84 {
				return .Crystal_Geode_Network
			}
			return .Buried_Aquifer_Caves
		case .Deep:
			if roll < 0.44 {
				return .Fungal_Vaults
			}
			if roll < 0.78 {
				return .Crystal_Geode_Network
			}
			return .Buried_Aquifer_Caves
		}
	case .Mineral:
		switch depth_band {
		case .Shallow:
			if roll < 0.48 {
				return .Crystal_Geode_Network
			}
			if roll < 0.78 {
				return .Buried_Aquifer_Caves
			}
			return .Fungal_Vaults
		case .Mid:
			if roll < 0.68 {
				return .Crystal_Geode_Network
			}
			if roll < 0.84 {
				return .Fungal_Vaults
			}
			return .Buried_Aquifer_Caves
		case .Deep:
			if roll < 0.78 {
				return .Crystal_Geode_Network
			}
			if roll < 0.90 {
				return .Buried_Aquifer_Caves
			}
			return .Fungal_Vaults
		}
	case .Aquifer:
		switch depth_band {
		case .Shallow:
			if roll < 0.62 {
				return .Buried_Aquifer_Caves
			}
			if roll < 0.84 {
				return .Fungal_Vaults
			}
			return .Crystal_Geode_Network
		case .Mid:
			if roll < 0.58 {
				return .Buried_Aquifer_Caves
			}
			if roll < 0.80 {
				return .Fungal_Vaults
			}
			return .Crystal_Geode_Network
		case .Deep:
			if roll < 0.52 {
				return .Buried_Aquifer_Caves
			}
			if roll < 0.82 {
				return .Crystal_Geode_Network
			}
			return .Fungal_Vaults
		}
	}

	log.assertf(false, "unhandled subterranean macro zone: %v", macro_zone)
	return .Buried_Aquifer_Caves
}

surface_biome_identities_are_compatible :: proc(a, b: BiomeID) -> bool {
	log.assert(biome_id_is_surface(a), "surface compatibility requires a surface biome")
	log.assert(biome_id_is_surface(b), "surface compatibility requires a surface biome")

	if a == b {
		return true
	}
	if (a == .Basalt_Spire_Highlands && b == .Wet_Lowland_Marsh) ||
	   (a == .Wet_Lowland_Marsh && b == .Basalt_Spire_Highlands) {
		return false
	}
	if (a == .Corrupted_Ash_Forest && b == .Temperate_Hills) ||
	   (a == .Temperate_Hills && b == .Corrupted_Ash_Forest) {
		return false
	}
	return true
}

subterranean_biome_identities_are_compatible :: proc(a, b: BiomeID) -> bool {
	log.assert(
		biome_id_is_subterranean(a),
		"subterranean compatibility requires a subterranean biome",
	)
	log.assert(
		biome_id_is_subterranean(b),
		"subterranean compatibility requires a subterranean biome",
	)

	if a == b {
		return true
	}
	if a == .Buried_Aquifer_Caves || b == .Buried_Aquifer_Caves {
		return true
	}
	return false
}

//////////////////////////////////////
// Biome Field Sampling Methods
/////////////////////////////////////

surface_biome_field_sample :: proc(
	key: FeatureGridKey,
	block_x, block_z: i32,
) -> SurfaceBiomeFieldSample {
	config := feature_grid_config_for(.Surface, .Biome)
	owners: [FEATURE_GRID_WORLEY_NEIGHBOR_COUNT_2]FeatureGridCoord2
	owner_count := feature_grid_neighbor_owners_from_block(
		block_x,
		block_z,
		FEATURE_GRID_WORLEY_NEIGHBOR_RADIUS,
		config,
		owners[:],
	)

	sample := SurfaceBiomeFieldSample{}
	sample_x := f32(block_x) + 0.5
	sample_z := f32(block_z) + 0.5

	for i := u32(0); i < owner_count; i += 1 {
		point := feature_grid_point_from_owner(key, config, owners[i])
		cell := surface_biome_cell_from_feature_point(key, point, sample_x, sample_z)
		surface_biome_field_sample_insert_cell(&sample, cell)
	}

	surface_biome_field_sample_finalize(&sample)
	return sample
}

subterranean_biome_field_sample :: proc(
	key: FeatureGridKey,
	block_x, block_y, block_z: i32,
) -> SubterraneanBiomeFieldSample {
	config := feature_grid_config_for(.Subterranean, .Biome)
	owners: [FEATURE_GRID_WORLEY_NEIGHBOR_COUNT_3]FeatureGridCoord3
	owner_count := feature_grid_neighbor_owners_from_block(
		block_x,
		block_y,
		block_z,
		FEATURE_GRID_WORLEY_NEIGHBOR_RADIUS,
		config,
		owners[:],
	)

	sample := SubterraneanBiomeFieldSample{}
	sample_x := f32(block_x) + 0.5
	sample_y := f32(block_y) + 0.5
	sample_z := f32(block_z) + 0.5

	for i := u32(0); i < owner_count; i += 1 {
		point := feature_grid_point_from_owner(key, config, owners[i])
		cell := subterranean_biome_cell_from_feature_point(
			key,
			point,
			sample_x,
			sample_y,
			sample_z,
		)
		subterranean_biome_field_sample_insert_cell(&sample, cell)
	}

	subterranean_biome_field_sample_finalize(&sample)
	return sample
}

surface_biome_cell_from_feature_point :: proc(
	key: FeatureGridKey,
	point: FeaturePoint2,
	sample_x, sample_z: f32,
) -> SurfaceBiomeCell {
	biome_id, macro_zone, macro_feature_id := surface_biome_identity_select(key, point.owner)
	dx := point.x - sample_x
	dz := point.z - sample_z
	distance_sq := dx * dx + dz * dz

	return {
		feature = point,
		biome_id = biome_id,
		macro_zone = macro_zone,
		macro_feature_id = macro_feature_id,
		distance = math.sqrt_f32(distance_sq),
		distance_sq = distance_sq,
	}
}

subterranean_biome_cell_from_feature_point :: proc(
	key: FeatureGridKey,
	point: FeaturePoint3,
	sample_x, sample_y, sample_z: f32,
) -> SubterraneanBiomeCell {
	biome_id, macro_zone, depth_band, macro_feature_id := subterranean_biome_identity_select(
		key,
		point.owner,
	)
	dx := point.x - sample_x
	dy := point.y - sample_y
	dz := point.z - sample_z
	distance_sq := dx * dx + dy * dy + dz * dz

	return {
		feature = point,
		biome_id = biome_id,
		macro_zone = macro_zone,
		depth_band = depth_band,
		macro_feature_id = macro_feature_id,
		distance = math.sqrt_f32(distance_sq),
		distance_sq = distance_sq,
	}
}

surface_biome_field_sample_insert_cell :: proc(
	sample: ^SurfaceBiomeFieldSample,
	cell: SurfaceBiomeCell,
) {
	insert_at := sample.cell_count
	for insert_at > 0 {
		prev := insert_at - 1
		if cell.distance >= sample.cells[prev].distance {
			break
		}
		insert_at = prev
	}

	if insert_at >= BIOME_FIELD_NEAREST_CELL_COUNT {
		return
	}

	if sample.cell_count < BIOME_FIELD_NEAREST_CELL_COUNT {
		sample.cell_count += 1
	}

	i := sample.cell_count - 1
	for i > insert_at {
		sample.cells[i] = sample.cells[i - 1]
		i -= 1
	}
	sample.cells[insert_at] = cell
}

subterranean_biome_field_sample_insert_cell :: proc(
	sample: ^SubterraneanBiomeFieldSample,
	cell: SubterraneanBiomeCell,
) {
	insert_at := sample.cell_count
	for insert_at > 0 {
		prev := insert_at - 1
		if cell.distance >= sample.cells[prev].distance {
			break
		}
		insert_at = prev
	}

	if insert_at >= BIOME_FIELD_NEAREST_CELL_COUNT {
		return
	}

	if sample.cell_count < BIOME_FIELD_NEAREST_CELL_COUNT {
		sample.cell_count += 1
	}

	i := sample.cell_count - 1
	for i > insert_at {
		sample.cells[i] = sample.cells[i - 1]
		i -= 1
	}
	sample.cells[insert_at] = cell
}

surface_biome_field_sample_finalize :: proc(sample: ^SurfaceBiomeFieldSample) {
	distances: [BIOME_FIELD_NEAREST_CELL_COUNT]f32
	for i := u32(0); i < sample.cell_count; i += 1 {
		distances[i] = sample.cells[i].distance
	}
	sample.distance_gap, sample.boundary_blend = biome_field_blend_weights_write(
		distances[:],
		sample.cell_count,
		SURFACE_BIOME_BLEND_BAND_BLOCKS,
		SURFACE_BIOME_JUNCTION_BAND_BLOCKS,
		sample.blend_weights[:],
	)
	sample.dominant_index = 0
}

subterranean_biome_field_sample_finalize :: proc(sample: ^SubterraneanBiomeFieldSample) {
	distances: [BIOME_FIELD_NEAREST_CELL_COUNT]f32
	for i := u32(0); i < sample.cell_count; i += 1 {
		distances[i] = sample.cells[i].distance
	}
	sample.distance_gap, sample.boundary_blend = biome_field_blend_weights_write(
		distances[:],
		sample.cell_count,
		SUBTERRANEAN_BIOME_BLEND_BAND_BLOCKS,
		SUBTERRANEAN_BIOME_JUNCTION_BAND_BLOCKS,
		sample.blend_weights[:],
	)
	sample.dominant_index = 0
}

biome_field_blend_weights_write :: proc(
	distances: []f32,
	cell_count: u32,
	blend_band_blocks, junction_band_blocks: f32,
	weights: []f32,
) -> (
	distance_gap, boundary_blend: f32,
) {
	log.assert(
		u32(len(distances)) >= BIOME_FIELD_NEAREST_CELL_COUNT,
		"biome field blend distance input too small",
	)
	log.assert(
		u32(len(weights)) >= BIOME_FIELD_NEAREST_CELL_COUNT,
		"biome field blend weight output too small",
	)
	log.assert(
		cell_count <= BIOME_FIELD_NEAREST_CELL_COUNT,
		"biome field blend cell count exceeds nearest-cell capacity",
	)

	for i in 0 ..< len(weights) {
		weights[i] = 0
	}

	if cell_count == 0 {
		return 0, 0
	}

	strengths: [BIOME_FIELD_NEAREST_CELL_COUNT]f32
	strengths[0] = 1.0
	distance_gap = BIOME_FIELD_NO_DISTANCE

	if cell_count > 1 {
		gap := math.max(distances[1] - distances[0], f32(0))
		distance_gap = gap
		boundary_blend = biome_field_boundary_strength(gap, blend_band_blocks)
		strengths[1] = boundary_blend
	}

	if cell_count > 2 {
		junction_gap := math.max(distances[2] - distances[0], f32(0))
		strengths[2] = biome_field_boundary_strength(junction_gap, junction_band_blocks)
	}

	total_strength := f32(0)
	for i := u32(0); i < cell_count; i += 1 {
		total_strength += strengths[i]
	}
	log.assert(total_strength > 0, "biome field blend strengths must not sum to zero")

	for i := u32(0); i < cell_count; i += 1 {
		weights[i] = strengths[i] / total_strength
	}
	return
}

biome_field_boundary_strength :: proc(distance_gap, blend_band_blocks: f32) -> f32 {
	if blend_band_blocks <= 0 {
		return 0
	}
	return math.smoothstep(f32(0), blend_band_blocks, blend_band_blocks - distance_gap)
}

surface_macro_zone_sample :: proc(
	key: FeatureGridKey,
	block_x, block_z: i32,
) -> (
	zone: SurfaceMacroZone,
	feature_id: FeatureID,
) {
	config := feature_grid_config_for(.Surface, .Macro)
	owners: [FEATURE_GRID_WORLEY_NEIGHBOR_COUNT_2]FeatureGridCoord2
	owner_count := feature_grid_neighbor_owners_from_block(
		block_x,
		block_z,
		FEATURE_GRID_WORLEY_NEIGHBOR_RADIUS,
		config,
		owners[:],
	)

	sample_x := f32(block_x) + 0.5
	sample_z := f32(block_z) + 0.5
	best_distance_sq := BIOME_FIELD_NO_DISTANCE
	for i := u32(0); i < owner_count; i += 1 {
		point := feature_grid_point_from_owner(key, config, owners[i])
		dx := point.x - sample_x
		dz := point.z - sample_z
		distance_sq := dx * dx + dz * dz
		if distance_sq >= best_distance_sq {
			continue
		}
		best_distance_sq = distance_sq
		feature_id = point.id
	}

	zone = surface_macro_zone_from_feature_id(feature_id)
	return
}

subterranean_macro_zone_sample :: proc(
	key: FeatureGridKey,
	block_x, block_y, block_z: i32,
) -> (
	zone: SubterraneanMacroZone,
	feature_id: FeatureID,
) {
	config := feature_grid_config_for(.Subterranean, .Macro)
	owners: [FEATURE_GRID_WORLEY_NEIGHBOR_COUNT_3]FeatureGridCoord3
	owner_count := feature_grid_neighbor_owners_from_block(
		block_x,
		block_y,
		block_z,
		FEATURE_GRID_WORLEY_NEIGHBOR_RADIUS,
		config,
		owners[:],
	)

	sample_x := f32(block_x) + 0.5
	sample_y := f32(block_y) + 0.5
	sample_z := f32(block_z) + 0.5
	best_distance_sq := BIOME_FIELD_NO_DISTANCE
	for i := u32(0); i < owner_count; i += 1 {
		point := feature_grid_point_from_owner(key, config, owners[i])
		dx := point.x - sample_x
		dy := point.y - sample_y
		dz := point.z - sample_z
		distance_sq := dx * dx + dy * dy + dz * dz
		if distance_sq >= best_distance_sq {
			continue
		}
		best_distance_sq = distance_sq
		feature_id = point.id
	}

	zone = subterranean_macro_zone_from_feature_id(feature_id)
	return
}

surface_biome_identity_raw :: proc(
	key: FeatureGridKey,
	owner: FeatureGridCoord2,
) -> (
	biome_id: BiomeID,
	macro_zone: SurfaceMacroZone,
	macro_feature_id: FeatureID,
) {
	config := feature_grid_config_for(.Surface, .Biome)
	point := feature_grid_point_from_owner(key, config, owner)
	macro_zone, macro_feature_id = surface_macro_zone_sample(
		key,
		i32(math.floor_f32(point.x)),
		i32(math.floor_f32(point.z)),
	)
	feature_id := feature_id_from_grid_coord(key, config, owner)
	roll := feature_grid_unit_f32(u64(feature_id), SURFACE_BIOME_IDENTITY_SALT)
	biome_id = surface_biome_identity_from_macro_roll(macro_zone, roll)
	return
}

subterranean_biome_identity_raw :: proc(
	key: FeatureGridKey,
	owner: FeatureGridCoord3,
) -> (
	biome_id: BiomeID,
	macro_zone: SubterraneanMacroZone,
	depth_band: SubterraneanDepthBand,
	macro_feature_id: FeatureID,
) {
	config := feature_grid_config_for(.Subterranean, .Biome)
	point := feature_grid_point_from_owner(key, config, owner)
	macro_zone, macro_feature_id = subterranean_macro_zone_sample(
		key,
		i32(math.floor_f32(point.x)),
		i32(math.floor_f32(point.y)),
		i32(math.floor_f32(point.z)),
	)
	depth_band = subterranean_depth_band_from_y(i32(math.floor_f32(point.y)))
	feature_id := feature_id_from_grid_coord(key, config, owner)
	roll := feature_grid_unit_f32(u64(feature_id), SUBTERRANEAN_BIOME_IDENTITY_SALT)
	biome_id = subterranean_biome_identity_from_macro_depth_roll(macro_zone, depth_band, roll)
	return
}

surface_biome_identity_select :: proc(
	key: FeatureGridKey,
	owner: FeatureGridCoord2,
) -> (
	biome_id: BiomeID,
	macro_zone: SurfaceMacroZone,
	macro_feature_id: FeatureID,
) {
	biome_id, macro_zone, macro_feature_id = surface_biome_identity_raw(key, owner)
	if surface_biome_identity_adjacency_allowed(key, owner, biome_id) {
		return
	}

	config := feature_grid_config_for(.Surface, .Biome)
	feature_id := feature_id_from_grid_coord(key, config, owner)
	clash_roll := feature_grid_unit_f32(u64(feature_id), BIOME_ADJACENCY_CLASH_SALT)
	if clash_roll < SURFACE_BIOME_RARE_CLASH_CHANCE {
		return
	}

	biome_id = surface_biome_identity_constrained_fallback(key, owner, macro_zone)
	return
}

subterranean_biome_identity_select :: proc(
	key: FeatureGridKey,
	owner: FeatureGridCoord3,
) -> (
	biome_id: BiomeID,
	macro_zone: SubterraneanMacroZone,
	depth_band: SubterraneanDepthBand,
	macro_feature_id: FeatureID,
) {
	biome_id, macro_zone, depth_band, macro_feature_id = subterranean_biome_identity_raw(
		key,
		owner,
	)
	if subterranean_biome_identity_adjacency_allowed(key, owner, biome_id) {
		return
	}

	config := feature_grid_config_for(.Subterranean, .Biome)
	feature_id := feature_id_from_grid_coord(key, config, owner)
	clash_roll := feature_grid_unit_f32(u64(feature_id), BIOME_ADJACENCY_CLASH_SALT)
	if clash_roll < SUBTERRANEAN_BIOME_RARE_CLASH_CHANCE {
		return
	}

	biome_id = subterranean_biome_identity_constrained_fallback(key, owner, macro_zone, depth_band)
	return
}

surface_biome_identity_adjacency_allowed :: proc(
	key: FeatureGridKey,
	owner: FeatureGridCoord2,
	candidate: BiomeID,
) -> bool {
	offsets := [?]FeatureGridCoord2 {
		{x = -1, z = 0},
		{x = 1, z = 0},
		{x = 0, z = -1},
		{x = 0, z = 1},
	}

	for offset in offsets {
		neighbor_owner := FeatureGridCoord2 {
			x = owner.x + offset.x,
			z = owner.z + offset.z,
		}
		neighbor_biome, _, _ := surface_biome_identity_raw(key, neighbor_owner)
		if !surface_biome_identities_are_compatible(candidate, neighbor_biome) {
			return false
		}
	}

	return true
}

subterranean_biome_identity_adjacency_allowed :: proc(
	key: FeatureGridKey,
	owner: FeatureGridCoord3,
	candidate: BiomeID,
) -> bool {
	offsets := [?]FeatureGridCoord3 {
		{x = -1, y = 0, z = 0},
		{x = 1, y = 0, z = 0},
		{x = 0, y = -1, z = 0},
		{x = 0, y = 1, z = 0},
		{x = 0, y = 0, z = -1},
		{x = 0, y = 0, z = 1},
	}

	for offset in offsets {
		neighbor_owner := FeatureGridCoord3 {
			x = owner.x + offset.x,
			y = owner.y + offset.y,
			z = owner.z + offset.z,
		}
		neighbor_biome, _, _, _ := subterranean_biome_identity_raw(key, neighbor_owner)
		if !subterranean_biome_identities_are_compatible(candidate, neighbor_biome) {
			return false
		}
	}

	return true
}

surface_biome_identity_constrained_fallback :: proc(
	key: FeatureGridKey,
	owner: FeatureGridCoord2,
	macro_zone: SurfaceMacroZone,
) -> BiomeID {
	candidates := surface_biome_identity_priority_for_macro_zone(macro_zone)
	for candidate in candidates {
		if surface_biome_identity_adjacency_allowed(key, owner, candidate) {
			return candidate
		}
	}
	return surface_biome_identity_default_for_macro_zone(macro_zone)
}

subterranean_biome_identity_constrained_fallback :: proc(
	key: FeatureGridKey,
	owner: FeatureGridCoord3,
	macro_zone: SubterraneanMacroZone,
	depth_band: SubterraneanDepthBand,
) -> BiomeID {
	candidates := subterranean_biome_identity_priority_for_macro_depth(macro_zone, depth_band)
	for candidate in candidates {
		if subterranean_biome_identity_adjacency_allowed(key, owner, candidate) {
			return candidate
		}
	}
	return .Buried_Aquifer_Caves
}

surface_biome_identity_default_for_macro_zone :: proc(macro_zone: SurfaceMacroZone) -> BiomeID {
	switch macro_zone {
	case .Temperate:
		return .Temperate_Hills
	case .Wetland:
		return .Wet_Lowland_Marsh
	case .Volcanic:
		return .Basalt_Spire_Highlands
	case .Corrupted:
		return .Corrupted_Ash_Forest
	}

	log.assertf(false, "unhandled surface macro zone: %v", macro_zone)
	return .Temperate_Hills
}

surface_biome_identity_priority_for_macro_zone :: proc(
	macro_zone: SurfaceMacroZone,
) -> [4]BiomeID {
	switch macro_zone {
	case .Temperate:
		return {
			.Temperate_Hills,
			.Wet_Lowland_Marsh,
			.Basalt_Spire_Highlands,
			.Corrupted_Ash_Forest,
		}
	case .Wetland:
		return {
			.Wet_Lowland_Marsh,
			.Temperate_Hills,
			.Corrupted_Ash_Forest,
			.Basalt_Spire_Highlands,
		}
	case .Volcanic:
		return {
			.Basalt_Spire_Highlands,
			.Corrupted_Ash_Forest,
			.Temperate_Hills,
			.Wet_Lowland_Marsh,
		}
	case .Corrupted:
		return {
			.Corrupted_Ash_Forest,
			.Basalt_Spire_Highlands,
			.Wet_Lowland_Marsh,
			.Temperate_Hills,
		}
	}

	log.assertf(false, "unhandled surface macro zone: %v", macro_zone)
	return {.Temperate_Hills, .Wet_Lowland_Marsh, .Basalt_Spire_Highlands, .Corrupted_Ash_Forest}
}

subterranean_biome_identity_priority_for_macro_depth :: proc(
	macro_zone: SubterraneanMacroZone,
	depth_band: SubterraneanDepthBand,
) -> [3]BiomeID {
	switch macro_zone {
	case .Rooted:
		switch depth_band {
		case .Shallow, .Mid:
			return {.Fungal_Vaults, .Buried_Aquifer_Caves, .Crystal_Geode_Network}
		case .Deep:
			return {.Fungal_Vaults, .Crystal_Geode_Network, .Buried_Aquifer_Caves}
		}
	case .Mineral:
		switch depth_band {
		case .Shallow:
			return {.Crystal_Geode_Network, .Buried_Aquifer_Caves, .Fungal_Vaults}
		case .Mid, .Deep:
			return {.Crystal_Geode_Network, .Fungal_Vaults, .Buried_Aquifer_Caves}
		}
	case .Aquifer:
		switch depth_band {
		case .Shallow, .Mid:
			return {.Buried_Aquifer_Caves, .Fungal_Vaults, .Crystal_Geode_Network}
		case .Deep:
			return {.Buried_Aquifer_Caves, .Crystal_Geode_Network, .Fungal_Vaults}
		}
	}

	log.assertf(false, "unhandled subterranean macro zone: %v", macro_zone)
	return {.Buried_Aquifer_Caves, .Fungal_Vaults, .Crystal_Geode_Network}
}

//////////////////////////////////////
// Debug Methods
/////////////////////////////////////

when ODIN_DEBUG {

	debug_f32_approx_equal :: proc(a, b, epsilon: f32) -> bool {
		return math.abs(a - b) <= epsilon
	}

	debug_blend_weights_assert_valid :: proc(weights: []f32, cell_count: u32) {
		log.assert(
			cell_count <= BIOME_FIELD_NEAREST_CELL_COUNT,
			"debug blend weight cell count exceeds capacity",
		)
		sum := f32(0)
		for i := u32(0); i < cell_count; i += 1 {
			log.assert(weights[i] >= 0, "biome blend weights must not be negative")
			sum += weights[i]
		}
		log.assert(debug_f32_approx_equal(sum, 1.0, 0.001), "biome blend weights must sum to 1")
		for i := cell_count; i < BIOME_FIELD_NEAREST_CELL_COUNT; i += 1 {
			log.assert(
				debug_f32_approx_equal(weights[i], 0, 0.001),
				"unused biome blend weights must stay zero",
			)
		}
	}

	debug_contract_checks_run :: proc() {
		key := feature_grid_key_make(0x123456789abcdef0, 1)
		next_version_key := feature_grid_key_make(key.world_seed, key.generator_version + 1)
		surface_config := feature_grid_config_for(.Surface, .Biome)
		log.assert(
			surface_config == SURFACE_BIOME_GRID_CONFIG,
			"surface biome grid config lookup mismatch",
		)
		log.assert(
			feature_grid_config_for(.Surface, .Macro).cell_size_blocks >
			surface_config.cell_size_blocks,
			"surface macro grid must be coarser than surface biome grid",
		)
		log.assert(
			feature_grid_config_for(.Surface, .Micro).cell_size_blocks <
			surface_config.cell_size_blocks,
			"surface micro grid must be finer than surface biome grid",
		)

		owner := FeatureGridCoord2 {
			x = -2,
			z = 3,
		}
		id_a := feature_id_from_grid_coord(key, surface_config, owner)
		id_b := feature_id_from_grid_coord(key, surface_config, owner)
		log.assert(id_a == id_b, "feature ID must be stable for the same key and owner")

		id_next_version := feature_id_from_grid_coord(next_version_key, surface_config, owner)
		log.assert(
			id_a != id_next_version,
			"feature ID must include generator version in the deterministic key",
		)

		other_owner := FeatureGridCoord2 {
			x = -1,
			z = 3,
		}
		other_id := feature_id_from_grid_coord(key, surface_config, other_owner)
		log.assert(id_a != other_id, "neighboring feature owners must not share an ID")

		macro_config := feature_grid_config_for(.Surface, .Macro)
		macro_id := feature_id_from_grid_coord(key, macro_config, owner)
		log.assert(id_a != macro_id, "feature grid levels must have separate ID spaces")

		owner_from_negative_block := feature_grid_owner_from_block(-1, -512, surface_config)
		log.assert(
			owner_from_negative_block == FeatureGridCoord2{x = -1, z = -1},
			"negative block coordinates must use floor division",
		)

		owner_from_negative_edge := feature_grid_owner_from_block(-513, 0, surface_config)
		log.assert(
			owner_from_negative_edge == FeatureGridCoord2{x = -2, z = 0},
			"negative block coordinates must cross owner boundaries by floor division",
		)

		point := feature_grid_point_from_owner(key, surface_config, owner)
		min_x := f32(owner.x) * f32(surface_config.cell_size_blocks)
		max_x := min_x + f32(surface_config.cell_size_blocks)
		min_z := f32(owner.z) * f32(surface_config.cell_size_blocks)
		max_z := min_z + f32(surface_config.cell_size_blocks)
		log.assert(point.x >= min_x && point.x <= max_x, "2D feature point x left owner cell")
		log.assert(point.z >= min_z && point.z <= max_z, "2D feature point z left owner cell")

		chunk_bounds := BlockBounds2 {
			min = {x = 0, z = 0},
			max = {x = 64, z = 64},
		}
		chunk_owner_range := feature_grid_owner_range_from_block_bounds(
			chunk_bounds,
			128,
			surface_config,
		)
		log.assert(
			chunk_owner_range ==
			FeatureGridOwnerRange2{min = {x = -1, z = -1}, max = {x = 0, z = 0}},
			"2D influence margin owner range mismatch",
		)
		log.assert(
			feature_grid_owner_range_count(chunk_owner_range) == 4,
			"2D influence margin owner count mismatch",
		)

		margin_owners: [4]FeatureGridCoord2
		margin_count := feature_grid_owner_range_write(chunk_owner_range, margin_owners[:])
		log.assert(margin_count == 4, "2D influence margin owner write count mismatch")
		log.assert(
			margin_owners[0] == FeatureGridCoord2{x = -1, z = -1} &&
			margin_owners[1] == FeatureGridCoord2{x = 0, z = -1} &&
			margin_owners[2] == FeatureGridCoord2{x = -1, z = 0} &&
			margin_owners[3] == FeatureGridCoord2{x = 0, z = 0},
			"2D owner range write order mismatch",
		)

		neighbor_owners: [9]FeatureGridCoord2
		log.assert(
			feature_grid_neighbor_owner_count_2(FEATURE_GRID_WORLEY_NEIGHBOR_RADIUS) ==
			u32(len(neighbor_owners)),
			"2D Worley neighbor count helper mismatch",
		)
		neighbor_count := feature_grid_neighbor_owners_from_block(
			0,
			0,
			FEATURE_GRID_WORLEY_NEIGHBOR_RADIUS,
			surface_config,
			neighbor_owners[:],
		)
		log.assert(neighbor_count == 9, "2D Worley neighbor owner count mismatch")
		log.assert(
			neighbor_owners[0] == FeatureGridCoord2{x = -1, z = -1} &&
			neighbor_owners[4] == FeatureGridCoord2{x = 0, z = 0} &&
			neighbor_owners[8] == FeatureGridCoord2{x = 1, z = 1},
			"2D Worley neighbor owner order mismatch",
		)

		subterranean_config := feature_grid_config_for(.Subterranean, .Biome)
		log.assert(
			subterranean_config == SUBTERRANEAN_BIOME_GRID_CONFIG,
			"subterranean biome grid config lookup mismatch",
		)
		owner_3 := FeatureGridCoord3 {
			x = -2,
			y = -1,
			z = 3,
		}
		id_3 := feature_id_from_grid_coord(key, subterranean_config, owner_3)
		log.assert(id_3 != id_a, "2D and 3D feature grids must have separate ID spaces")

		owner_from_block_3 := feature_grid_owner_from_block(-385, -1, 384, subterranean_config)
		log.assert(
			owner_from_block_3 == FeatureGridCoord3{x = -2, y = -1, z = 1},
			"3D negative block coordinates must use floor division",
		)

		point_3 := feature_grid_point_from_owner(key, subterranean_config, owner_3)
		min_y := f32(owner_3.y) * f32(subterranean_config.cell_size_blocks)
		max_y := min_y + f32(subterranean_config.cell_size_blocks)
		log.assert(point_3.y >= min_y && point_3.y <= max_y, "3D feature point y left owner cell")

		bounds_3 := BlockBounds3 {
			min = {x = 0, y = -64, z = 0},
			max = {x = 64, y = 64, z = 64},
		}
		owner_range_3 := feature_grid_owner_range_from_block_bounds(
			bounds_3,
			0,
			subterranean_config,
		)
		log.assert(
			owner_range_3 ==
			FeatureGridOwnerRange3{min = {x = 0, y = -1, z = 0}, max = {x = 0, y = 0, z = 0}},
			"3D block bounds owner range mismatch",
		)

		neighbor_owners_3: [27]FeatureGridCoord3
		log.assert(
			feature_grid_neighbor_owner_count_3(FEATURE_GRID_WORLEY_NEIGHBOR_RADIUS) ==
			u32(len(neighbor_owners_3)),
			"3D Worley neighbor count helper mismatch",
		)
		neighbor_count_3 := feature_grid_neighbor_owners_from_block(
			0,
			0,
			0,
			FEATURE_GRID_WORLEY_NEIGHBOR_RADIUS,
			subterranean_config,
			neighbor_owners_3[:],
		)
		log.assert(neighbor_count_3 == 27, "3D Worley neighbor owner count mismatch")
		log.assert(
			neighbor_owners_3[0] == FeatureGridCoord3{x = -1, y = -1, z = -1} &&
			neighbor_owners_3[13] == FeatureGridCoord3{x = 0, y = 0, z = 0} &&
			neighbor_owners_3[26] == FeatureGridCoord3{x = 1, y = 1, z = 1},
			"3D Worley neighbor owner order mismatch",
		)

		log.assert(
			biome_id_is_surface(.Temperate_Hills) &&
			biome_id_is_surface(.Basalt_Spire_Highlands) &&
			!biome_id_is_surface(.Fungal_Vaults),
			"surface biome identity classifier mismatch",
		)
		log.assert(
			biome_id_is_subterranean(.Fungal_Vaults) &&
			biome_id_is_subterranean(.Buried_Aquifer_Caves) &&
			!biome_id_is_subterranean(.Wet_Lowland_Marsh),
			"subterranean biome identity classifier mismatch",
		)
		log.assert(
			surface_biome_identity_from_macro_roll(.Volcanic, 0.10) == .Basalt_Spire_Highlands,
			"volcanic macro zone should bias toward basalt terrain",
		)
		log.assert(
			surface_biome_identity_from_macro_roll(.Wetland, 0.10) == .Wet_Lowland_Marsh,
			"wetland macro zone should bias toward marsh terrain",
		)
		log.assert(
			subterranean_biome_identity_from_macro_depth_roll(.Mineral, .Deep, 0.10) ==
			.Crystal_Geode_Network,
			"deep mineral subterranean zone should bias toward crystal geodes",
		)
		log.assert(
			!surface_biome_identities_are_compatible(.Basalt_Spire_Highlands, .Wet_Lowland_Marsh),
			"surface adjacency constraints should reject basalt-marsh by default",
		)
		log.assert(
			subterranean_biome_identities_are_compatible(.Fungal_Vaults, .Buried_Aquifer_Caves),
			"aquifer subterranean regions should act as compatible connectors",
		)

		{
			boundary_distances := [?]f32{10, 10, 220}
			weights: [BIOME_FIELD_NEAREST_CELL_COUNT]f32
			gap, boundary_blend := biome_field_blend_weights_write(
				boundary_distances[:],
				BIOME_FIELD_NEAREST_CELL_COUNT,
				96,
				32,
				weights[:],
			)
			log.assert(debug_f32_approx_equal(gap, 0, 0.001), "boundary gap mismatch")
			log.assert(
				debug_f32_approx_equal(boundary_blend, 1, 0.001),
				"boundary blend should be full when nearest distances match",
			)
			log.assert(
				debug_f32_approx_equal(weights[0], 0.5, 0.001) &&
				debug_f32_approx_equal(weights[1], 0.5, 0.001) &&
				debug_f32_approx_equal(weights[2], 0, 0.001),
				"two-cell boundary blend weights mismatch",
			)
		}

		{
			interior_distances := [?]f32{10, 200, 240}
			weights: [BIOME_FIELD_NEAREST_CELL_COUNT]f32
			_, boundary_blend := biome_field_blend_weights_write(
				interior_distances[:],
				BIOME_FIELD_NEAREST_CELL_COUNT,
				96,
				32,
				weights[:],
			)
			log.assert(
				debug_f32_approx_equal(boundary_blend, 0, 0.001),
				"interior boundary blend should be zero outside the band",
			)
			log.assert(
				debug_f32_approx_equal(weights[0], 1, 0.001) &&
				debug_f32_approx_equal(weights[1], 0, 0.001) &&
				debug_f32_approx_equal(weights[2], 0, 0.001),
				"interior blend weights should keep dominant biome only",
			)
		}

		{
			junction_distances := [?]f32{10, 10, 10}
			weights: [BIOME_FIELD_NEAREST_CELL_COUNT]f32
			_, _ = biome_field_blend_weights_write(
				junction_distances[:],
				BIOME_FIELD_NEAREST_CELL_COUNT,
				96,
				32,
				weights[:],
			)
			log.assert(
				debug_f32_approx_equal(weights[0], 1.0 / 3.0, 0.001) &&
				debug_f32_approx_equal(weights[1], 1.0 / 3.0, 0.001) &&
				debug_f32_approx_equal(weights[2], 1.0 / 3.0, 0.001),
				"three-cell junction blend weights mismatch",
			)
		}

		surface_sample := surface_biome_field_sample(key, 17, -33)
		surface_sample_again := surface_biome_field_sample(key, 17, -33)
		log.assert(
			surface_sample.cell_count == BIOME_FIELD_NEAREST_CELL_COUNT,
			"surface biome field should return three nearby cells",
		)
		log.assert(
			surface_sample.cells[0].distance <= surface_sample.cells[1].distance &&
			surface_sample.cells[1].distance <= surface_sample.cells[2].distance,
			"surface biome cells must be sorted by distance",
		)
		log.assert(
			surface_sample.cells[0].feature.id == surface_sample_again.cells[0].feature.id &&
			surface_sample.cells[0].biome_id == surface_sample_again.cells[0].biome_id &&
			debug_f32_approx_equal(
				surface_sample.cells[0].distance,
				surface_sample_again.cells[0].distance,
				0.001,
			),
			"surface biome sampling must be deterministic",
		)
		log.assert(
			biome_id_is_surface(surface_sample.cells[0].biome_id),
			"surface biome field returned a non-surface biome",
		)
		log.assert(
			surface_sample.cells[0].feature.id != surface_sample.cells[1].feature.id,
			"surface biome sample returned duplicate nearest cells",
		)
		debug_blend_weights_assert_valid(
			surface_sample.blend_weights[:],
			surface_sample.cell_count,
		)

		subterranean_sample := subterranean_biome_field_sample(key, -45, -96, 130)
		subterranean_sample_again := subterranean_biome_field_sample(key, -45, -96, 130)
		log.assert(
			subterranean_sample.cell_count == BIOME_FIELD_NEAREST_CELL_COUNT,
			"subterranean biome field should return three nearby cells",
		)
		log.assert(
			subterranean_sample.cells[0].distance <= subterranean_sample.cells[1].distance &&
			subterranean_sample.cells[1].distance <= subterranean_sample.cells[2].distance,
			"subterranean biome cells must be sorted by distance",
		)
		log.assert(
			subterranean_sample.cells[0].feature.id ==
				subterranean_sample_again.cells[0].feature.id &&
			subterranean_sample.cells[0].biome_id == subterranean_sample_again.cells[0].biome_id &&
			debug_f32_approx_equal(
				subterranean_sample.cells[0].distance,
				subterranean_sample_again.cells[0].distance,
				0.001,
			),
			"subterranean biome sampling must be deterministic",
		)
		log.assert(
			biome_id_is_subterranean(subterranean_sample.cells[0].biome_id),
			"subterranean biome field returned a non-subterranean biome",
		)
		log.assert(
			subterranean_sample.cells[0].feature.id != subterranean_sample.cells[1].feature.id,
			"subterranean biome sample returned duplicate nearest cells",
		)
		debug_blend_weights_assert_valid(
			subterranean_sample.blend_weights[:],
			subterranean_sample.cell_count,
		)

		log.debug("Biome feature grid and field contract checks passed")
	}

}
