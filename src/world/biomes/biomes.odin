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
// Debug Methods
/////////////////////////////////////

when ODIN_DEBUG {

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

		log.debug("Biome feature grid contract checks passed")
	}

}
