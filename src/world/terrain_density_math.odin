package world

import world_async "async:world"
import "core:log"
import math "core:math"
import biomes "world:biomes"

//////////////////////////////////////
// Terrain Density Math Types
/////////////////////////////////////

TerrainDensityRowRange :: struct {
	min_x, max_x: i32,
}

TerrainCarveableRowMask :: [CHUNK_BLOCK_LENGTH * CHUNK_BLOCK_LENGTH]u64

TerrainValueNoise3RowCache :: struct {
	corner_hash: u64,
	salt:        u64,
	cell_size:   i32,
	cell_y:      i32,
	cell_z:      i32,
	origin_y:    i32,
	origin_z:    i32,
	t_y:         f32,
	t_z:         f32,
	cell_x:      i32,
	v000:        f32,
	v100:        f32,
	v010:        f32,
	v110:        f32,
	v001:        f32,
	v101:        f32,
	v011:        f32,
	v111:        f32,
	valid:       bool,
}


//////////////////////////////////////
// Terrain Density Math Methods
/////////////////////////////////////

terrain_density_delta_3 :: proc(
	from_x, from_y, from_z, to_x, to_y, to_z: f32,
) -> (
	dir_x, dir_y, dir_z: f32,
) {
	dir_x = to_x - from_x
	dir_y = to_y - from_y
	dir_z = to_z - from_z
	return
}

terrain_density_closest_segment_point_3 :: proc(
	x, y, z, from_x, from_y, from_z, to_x, to_y, to_z: f32,
) -> (
	nearest_x, nearest_y, nearest_z, distance: f32,
) {
	seg_x := to_x - from_x
	seg_y := to_y - from_y
	seg_z := to_z - from_z
	length_sq := seg_x * seg_x + seg_y * seg_y + seg_z * seg_z
	if length_sq <= 0.001 {
		return from_x, from_y, from_z, terrain_density_distance_3(x, y, z, from_x, from_y, from_z)
	}
	t := ((x - from_x) * seg_x + (y - from_y) * seg_y + (z - from_z) * seg_z) / length_sq
	t = math.clamp(t, f32(0), f32(1))
	nearest_x = from_x + seg_x * t
	nearest_y = from_y + seg_y * t
	nearest_z = from_z + seg_z * t
	distance = terrain_density_distance_3(x, y, z, nearest_x, nearest_y, nearest_z)
	return
}

terrain_density_distance_3 :: proc(x, y, z, target_x, target_y, target_z: f32) -> f32 {
	dx := x - target_x
	dy := y - target_y
	dz := z - target_z
	return math.sqrt_f32(dx * dx + dy * dy + dz * dz)
}

terrain_density_chunk_aabb_intersects :: proc(
	chunk_origin: world_async.BlockCoord,
	min_world_x, max_world_x, min_world_y, max_world_y, min_world_z, max_world_z: f32,
) -> bool {
	_, _, _, _, _, _, intersects := terrain_density_carve_bounds_from_extents(
		chunk_origin,
		min_world_x,
		max_world_x,
		min_world_y,
		max_world_y,
		min_world_z,
		max_world_z,
	)
	return intersects
}

terrain_density_feature_segment_aabb_intersects_chunk :: proc(
	chunk_origin: world_async.BlockCoord,
	from_x, from_y, from_z, to_x, to_y, to_z, margin: f32,
) -> bool {
	return terrain_density_chunk_aabb_intersects(
		chunk_origin,
		math.min(from_x, to_x) - margin,
		math.max(from_x, to_x) + margin,
		math.min(from_y, to_y) - margin,
		math.max(from_y, to_y) + margin,
		math.min(from_z, to_z) - margin,
		math.max(from_z, to_z) + margin,
	)
}

terrain_density_segment_chunk_overlap :: proc(
	chunk_origin: world_async.BlockCoord,
	from_x, from_y, from_z, to_x, to_y, to_z, radius: f32,
) -> (
	t_min, t_max: f32,
	intersects: bool,
) {
	min_x := f32(chunk_origin.x) - radius
	min_y := f32(chunk_origin.y) - radius
	min_z := f32(chunk_origin.z) - radius
	max_x := f32(chunk_origin.x + CHUNK_BLOCK_LENGTH) + radius
	max_y := f32(chunk_origin.y + CHUNK_BLOCK_LENGTH) + radius
	max_z := f32(chunk_origin.z + CHUNK_BLOCK_LENGTH) + radius

	t_min = f32(0)
	t_max = f32(1)
	if !terrain_density_segment_axis_intersects_slab(
		from_x,
		to_x - from_x,
		min_x,
		max_x,
		&t_min,
		&t_max,
	) {
		return 0, 0, false
	}
	if !terrain_density_segment_axis_intersects_slab(
		from_y,
		to_y - from_y,
		min_y,
		max_y,
		&t_min,
		&t_max,
	) {
		return 0, 0, false
	}
	if !terrain_density_segment_axis_intersects_slab(
		from_z,
		to_z - from_z,
		min_z,
		max_z,
		&t_min,
		&t_max,
	) {
		return 0, 0, false
	}
	return t_min, t_max, true
}

terrain_density_segment_axis_intersects_slab :: proc(
	start, delta, slab_min, slab_max: f32,
	t_min, t_max: ^f32,
) -> bool {
	if math.abs(delta) <= 0.00001 {
		return start >= slab_min && start <= slab_max
	}

	inv_delta := 1.0 / delta
	t1 := (slab_min - start) * inv_delta
	t2 := (slab_max - start) * inv_delta
	if t1 > t2 {
		t1, t2 = t2, t1
	}
	t_min^ = math.max(t_min^, t1)
	t_max^ = math.min(t_max^, t2)
	return t_min^ <= t_max^
}

terrain_density_carve_bounds_from_extents :: proc(
	chunk_origin: world_async.BlockCoord,
	min_world_x, max_world_x, min_world_y, max_world_y, min_world_z, max_world_z: f32,
) -> (
	local_min_x, local_max_x, local_min_y, local_max_y, local_min_z, local_max_z: i32,
	intersects: bool,
) {
	min_x := i32(math.floor_f32(min_world_x)) - chunk_origin.x
	max_x := i32(math.floor_f32(max_world_x)) - chunk_origin.x
	min_y := i32(math.floor_f32(min_world_y)) - chunk_origin.y
	max_y := i32(math.floor_f32(max_world_y)) - chunk_origin.y
	min_z := i32(math.floor_f32(min_world_z)) - chunk_origin.z
	max_z := i32(math.floor_f32(max_world_z)) - chunk_origin.z

	if max_x < 0 ||
	   max_y < 0 ||
	   max_z < 0 ||
	   min_x >= CHUNK_BLOCK_LENGTH ||
	   min_y >= CHUNK_BLOCK_LENGTH ||
	   min_z >= CHUNK_BLOCK_LENGTH {
		return 0, 0, 0, 0, 0, 0, false
	}

	local_min_x = math.clamp(min_x, 0, CHUNK_BLOCK_LENGTH - 1)
	local_max_x = math.clamp(max_x, 0, CHUNK_BLOCK_LENGTH - 1)
	local_min_y = math.clamp(min_y, 0, CHUNK_BLOCK_LENGTH - 1)
	local_max_y = math.clamp(max_y, 0, CHUNK_BLOCK_LENGTH - 1)
	local_min_z = math.clamp(min_z, 0, CHUNK_BLOCK_LENGTH - 1)
	local_max_z = math.clamp(max_z, 0, CHUNK_BLOCK_LENGTH - 1)
	intersects = true
	return
}

terrain_value_noise3_row_cache_make :: proc(
	key: biomes.FeatureGridKey,
	salt: u64,
	cell_size: i32,
	block_y, block_z: i32,
) -> TerrainValueNoise3RowCache {
	log.assert(cell_size > 0, "terrain 3D noise row cache cell size must be positive")
	cell_y := math.floor_div(block_y, cell_size)
	cell_z := math.floor_div(block_z, cell_size)
	origin_y := cell_y * cell_size
	origin_z := cell_z * cell_size
	unit_y := f32(block_y - origin_y) / f32(cell_size)
	unit_z := f32(block_z - origin_z) / f32(cell_size)
	return TerrainValueNoise3RowCache {
		corner_hash = biomes.regional_terrain_field_corner_hash_base(key, salt),
		salt = salt,
		cell_size = cell_size,
		cell_y = cell_y,
		cell_z = cell_z,
		origin_y = origin_y,
		origin_z = origin_z,
		t_y = math.smoothstep(f32(0), f32(1), unit_y),
		t_z = math.smoothstep(f32(0), f32(1), unit_z),
		cell_x = 0,
		valid = false,
	}
}

terrain_value_noise3_row_cache_update_x_cell :: proc(
	cache: ^TerrainValueNoise3RowCache,
	cell_x: i32,
) {
	cache.cell_x = cell_x
	cache.v000 = biomes.regional_terrain_field_corner_value_from_hash_3(
		cache.corner_hash,
		cache.salt,
		cell_x,
		cache.cell_y,
		cache.cell_z,
	)
	cache.v100 = biomes.regional_terrain_field_corner_value_from_hash_3(
		cache.corner_hash,
		cache.salt,
		cell_x + 1,
		cache.cell_y,
		cache.cell_z,
	)
	cache.v010 = biomes.regional_terrain_field_corner_value_from_hash_3(
		cache.corner_hash,
		cache.salt,
		cell_x,
		cache.cell_y + 1,
		cache.cell_z,
	)
	cache.v110 = biomes.regional_terrain_field_corner_value_from_hash_3(
		cache.corner_hash,
		cache.salt,
		cell_x + 1,
		cache.cell_y + 1,
		cache.cell_z,
	)
	cache.v001 = biomes.regional_terrain_field_corner_value_from_hash_3(
		cache.corner_hash,
		cache.salt,
		cell_x,
		cache.cell_y,
		cache.cell_z + 1,
	)
	cache.v101 = biomes.regional_terrain_field_corner_value_from_hash_3(
		cache.corner_hash,
		cache.salt,
		cell_x + 1,
		cache.cell_y,
		cache.cell_z + 1,
	)
	cache.v011 = biomes.regional_terrain_field_corner_value_from_hash_3(
		cache.corner_hash,
		cache.salt,
		cell_x,
		cache.cell_y + 1,
		cache.cell_z + 1,
	)
	cache.v111 = biomes.regional_terrain_field_corner_value_from_hash_3(
		cache.corner_hash,
		cache.salt,
		cell_x + 1,
		cache.cell_y + 1,
		cache.cell_z + 1,
	)
	cache.valid = true
}

terrain_value_noise3_row_cache_sample :: proc(
	cache: ^TerrainValueNoise3RowCache,
	block_x: i32,
) -> f32 {
	cell_x := math.floor_div(block_x, cache.cell_size)
	if !cache.valid || cache.cell_x != cell_x {
		terrain_value_noise3_row_cache_update_x_cell(cache, cell_x)
	}
	origin_x := cell_x * cache.cell_size
	unit_x := f32(block_x - origin_x) / f32(cache.cell_size)
	t_x := math.smoothstep(f32(0), f32(1), unit_x)

	x00 := biomes.regional_terrain_field_lerp(cache.v000, cache.v100, t_x)
	x10 := biomes.regional_terrain_field_lerp(cache.v010, cache.v110, t_x)
	x01 := biomes.regional_terrain_field_lerp(cache.v001, cache.v101, t_x)
	x11 := biomes.regional_terrain_field_lerp(cache.v011, cache.v111, t_x)
	y0 := biomes.regional_terrain_field_lerp(x00, x10, cache.t_y)
	y1 := biomes.regional_terrain_field_lerp(x01, x11, cache.t_y)
	return biomes.regional_terrain_field_lerp(y0, y1, cache.t_z)
}

terrain_density_ellipsoid_row_x_bounds :: proc(
	chunk_origin: world_async.BlockCoord,
	local_min_x, local_max_x: i32,
	center_x, radius_x, row_shape_without_x, outer_shape_max: f32,
) -> (
	row_min_x, row_max_x: i32,
	intersects: bool,
) {
	if row_shape_without_x > outer_shape_max {
		return 0, 0, false
	}

	span_x := radius_x * math.sqrt_f32(math.max(f32(0), outer_shape_max - row_shape_without_x))
	min_x := i32(math.floor_f32(center_x - span_x)) - chunk_origin.x - 1
	max_x := i32(math.floor_f32(center_x + span_x)) - chunk_origin.x + 1
	row_min_x = math.clamp(min_x, local_min_x, local_max_x)
	row_max_x = math.clamp(max_x, local_min_x, local_max_x)
	intersects = row_min_x <= row_max_x
	return
}

terrain_density_segment_projection_row_x_bounds :: proc(
	chunk_origin: world_async.BlockCoord,
	local_min_x, local_max_x: i32,
	world_y, world_z: f32,
	from_x, from_y, from_z: f32,
	dx, dy, dz, length_sq: f32,
	raw_t_min, raw_t_max: f32,
) -> (
	row_min_x, row_max_x: i32,
	intersects: bool,
) {
	x_coeff := dx / length_sq
	raw_t_at_local_zero :=
		((f32(chunk_origin.x) + 0.5 - from_x) * dx +
			(world_y - from_y) * dy +
			(world_z - from_z) * dz) /
		length_sq

	if math.abs(x_coeff) <= 0.000001 {
		if raw_t_at_local_zero < raw_t_min || raw_t_at_local_zero > raw_t_max {
			return 0, 0, false
		}
		return local_min_x, local_max_x, true
	}

	row_min_f := (raw_t_min - raw_t_at_local_zero) / x_coeff
	row_max_f := (raw_t_max - raw_t_at_local_zero) / x_coeff
	if row_min_f > row_max_f {
		row_min_f, row_max_f = row_max_f, row_min_f
	}
	min_x := i32(math.floor_f32(row_min_f)) - 1
	max_x := i32(math.floor_f32(row_max_f)) + 1
	row_min_x = math.clamp(min_x, local_min_x, local_max_x)
	row_max_x = math.clamp(max_x, local_min_x, local_max_x)
	intersects = row_min_x <= row_max_x
	return
}

terrain_density_segment_capsule_row_x_bounds :: proc(
	chunk_origin: world_async.BlockCoord,
	local_min_x, local_max_x: i32,
	world_y, world_z: f32,
	from_x, from_y, from_z: f32,
	tangent_x, tangent_y, tangent_z, radius: f32,
) -> (
	row_min_x, row_max_x: i32,
	intersects: bool,
) {
	row_y := world_y - from_y
	row_z := world_z - from_z
	row_dot_without_x := row_y * tangent_y + row_z * tangent_z
	row_len_sq_without_x := row_y * row_y + row_z * row_z
	radius_sq := radius * radius

	a := 1.0 - tangent_x * tangent_x
	if math.abs(a) <= 0.000001 {
		distance_sq := row_len_sq_without_x - row_dot_without_x * row_dot_without_x
		if distance_sq > radius_sq {
			return 0, 0, false
		}
		return local_min_x, local_max_x, true
	}

	world_x_at_local_zero := f32(chunk_origin.x) + 0.5
	x0 := world_x_at_local_zero - from_x
	b := 2.0 * (x0 * a - tangent_x * row_dot_without_x)
	c :=
		x0 * x0 +
		row_len_sq_without_x -
		(x0 * tangent_x + row_dot_without_x) * (x0 * tangent_x + row_dot_without_x) -
		radius_sq
	discriminant := b * b - 4.0 * a * c
	if discriminant < 0 {
		return 0, 0, false
	}

	sqrt_discriminant := math.sqrt_f32(discriminant)
	inv_2a := 1.0 / (2.0 * a)
	min_f := (-b - sqrt_discriminant) * inv_2a
	max_f := (-b + sqrt_discriminant) * inv_2a
	if min_f > max_f {
		min_f, max_f = max_f, min_f
	}

	min_x := i32(math.floor_f32(min_f)) - 1
	max_x := i32(math.floor_f32(max_f)) + 1
	row_min_x = math.clamp(min_x, local_min_x, local_max_x)
	row_max_x = math.clamp(max_x, local_min_x, local_max_x)
	intersects = row_min_x <= row_max_x
	return
}

terrain_density_linear_coord_row_x_bounds :: proc(
	local_min_x, local_max_x: i32,
	coord_at_local_zero, coord_x_coeff, coord_min, coord_max: f32,
) -> (
	row_min_x, row_max_x: i32,
	intersects: bool,
) {
	coord_min_local := coord_min
	coord_max_local := coord_max
	if coord_min_local > coord_max_local {
		coord_min_local, coord_max_local = coord_max_local, coord_min_local
	}

	if math.abs(coord_x_coeff) <= 0.000001 {
		if coord_at_local_zero < coord_min_local || coord_at_local_zero > coord_max_local {
			return 0, 0, false
		}
		return local_min_x, local_max_x, true
	}

	row_min_f := (coord_min_local - coord_at_local_zero) / coord_x_coeff
	row_max_f := (coord_max_local - coord_at_local_zero) / coord_x_coeff
	if row_min_f > row_max_f {
		row_min_f, row_max_f = row_max_f, row_min_f
	}
	min_x := i32(math.floor_f32(row_min_f)) - 1
	max_x := i32(math.floor_f32(row_max_f)) + 1
	row_min_x = math.clamp(min_x, local_min_x, local_max_x)
	row_max_x = math.clamp(max_x, local_min_x, local_max_x)
	intersects = row_min_x <= row_max_x
	return
}

terrain_density_axis_row_x_bounds :: proc(
	chunk_origin: world_async.BlockCoord,
	local_min_x, local_max_x: i32,
	world_y, world_z: f32,
	base_x, base_y, base_z: f32,
	axis_x, axis_y, axis_z: f32,
	min_coord, max_coord: f32,
) -> (
	row_min_x, row_max_x: i32,
	intersects: bool,
) {
	world_x_at_local_zero := f32(chunk_origin.x) + 0.5
	coord_at_local_zero :=
		(world_x_at_local_zero - base_x) * axis_x +
		(world_y - base_y) * axis_y +
		(world_z - base_z) * axis_z
	return terrain_density_linear_coord_row_x_bounds(
		local_min_x,
		local_max_x,
		coord_at_local_zero,
		axis_x,
		min_coord,
		max_coord,
	)
}

terrain_density_dual_axis_ellipse_row_x_bounds :: proc(
	chunk_origin: world_async.BlockCoord,
	local_min_x, local_max_x: i32,
	world_y, world_z: f32,
	base_x, base_y, base_z: f32,
	axis_a_x, axis_a_y, axis_a_z: f32,
	axis_b_x, axis_b_y, axis_b_z: f32,
	radius_a, radius_b, shape_limit: f32,
) -> (
	row_min_x, row_max_x: i32,
	intersects: bool,
) {
	ra := math.max(radius_a, f32(0.0001))
	rb := math.max(radius_b, f32(0.0001))
	world_x_at_local_zero := f32(chunk_origin.x) + 0.5
	rel_zero_x := world_x_at_local_zero - base_x
	rel_y := world_y - base_y
	rel_z := world_z - base_z
	coord_a_zero := (rel_zero_x * axis_a_x + rel_y * axis_a_y + rel_z * axis_a_z) / ra
	coord_b_zero := (rel_zero_x * axis_b_x + rel_y * axis_b_y + rel_z * axis_b_z) / rb
	coord_a_x := axis_a_x / ra
	coord_b_x := axis_b_x / rb

	a := coord_a_x * coord_a_x + coord_b_x * coord_b_x
	b := 2 * (coord_a_zero * coord_a_x + coord_b_zero * coord_b_x)
	c := coord_a_zero * coord_a_zero + coord_b_zero * coord_b_zero - shape_limit
	if math.abs(a) <= 0.000001 {
		if c > 0 {
			return 0, 0, false
		}
		return local_min_x, local_max_x, true
	}

	discriminant := b * b - 4 * a * c
	if discriminant < 0 {
		return 0, 0, false
	}
	sqrt_discriminant := math.sqrt_f32(discriminant)
	inv_2a := 1 / (2 * a)
	min_f := (-b - sqrt_discriminant) * inv_2a
	max_f := (-b + sqrt_discriminant) * inv_2a
	if min_f > max_f {
		min_f, max_f = max_f, min_f
	}

	min_x := i32(math.floor_f32(min_f)) - 1
	max_x := i32(math.floor_f32(max_f)) + 1
	row_min_x = math.clamp(min_x, local_min_x, local_max_x)
	row_max_x = math.clamp(max_x, local_min_x, local_max_x)
	intersects = row_min_x <= row_max_x
	return
}

terrain_density_row_range_add_merged :: proc(
	ranges: ^[8]TerrainDensityRowRange,
	range_count: ^u32,
	min_x, max_x: i32,
) {
	if min_x > max_x {
		return
	}

	new_min := min_x
	new_max := max_x
	insert_index := range_count^
	for i := u32(0); i < range_count^; {
		range := ranges[i]
		if new_max + 1 < range.min_x {
			insert_index = i
			break
		}
		if new_min > range.max_x + 1 {
			i += 1
			continue
		}

		new_min = math.min(new_min, range.min_x)
		new_max = math.max(new_max, range.max_x)
		for j := i; j + 1 < range_count^; j += 1 {
			ranges[j] = ranges[j + 1]
		}
		range_count^ -= 1
		insert_index = i
	}

	log.assertf(range_count^ < u32(len(ranges[:])), "terrain row range capacity exceeded")
	for i := range_count^; i > insert_index; i -= 1 {
		ranges[i] = ranges[i - 1]
	}
	ranges[insert_index] = TerrainDensityRowRange {
		min_x = new_min,
		max_x = new_max,
	}
	range_count^ += 1
}

terrain_density_route_pocket_row_range_add_component :: proc(
	ranges: ^[8]TerrainDensityRowRange,
	range_count: ^u32,
	local_min_x, local_max_x: i32,
	along_at_local_zero, along_x_coeff: f32,
	height: f32,
	away_at_local_zero, away_x_coeff: f32,
	center_along, center_height, center_away: f32,
	radius_along, radius_height, radius_away: f32,
	shape_span: f32,
) {
	height_min := center_height - radius_height * shape_span
	height_max := center_height + radius_height * shape_span
	if height < height_min || height > height_max {
		return
	}

	row_min_x, row_max_x, row_intersects := terrain_density_linear_coord_row_x_bounds(
		local_min_x,
		local_max_x,
		along_at_local_zero,
		along_x_coeff,
		center_along - radius_along * shape_span,
		center_along + radius_along * shape_span,
	)
	if !row_intersects {
		return
	}
	away_min_x, away_max_x, away_intersects := terrain_density_linear_coord_row_x_bounds(
		local_min_x,
		local_max_x,
		away_at_local_zero,
		away_x_coeff,
		center_away - radius_away * shape_span,
		center_away + radius_away * shape_span,
	)
	if !away_intersects {
		return
	}
	if away_min_x > row_min_x {
		row_min_x = away_min_x
	}
	if away_max_x < row_max_x {
		row_max_x = away_max_x
	}
	if row_min_x > row_max_x {
		return
	}
	terrain_density_row_range_add_merged(ranges, range_count, row_min_x, row_max_x)
}

terrain_density_local_box_row_x_bounds :: proc(
	chunk_origin: world_async.BlockCoord,
	local_min_x, local_max_x: i32,
	world_y, world_z: f32,
	base_x, base_y, base_z: f32,
	along_x_coeff, along_z_coeff: f32,
	height_y_coeff: f32,
	across_x_coeff, across_z_coeff: f32,
	min_along, max_along: f32,
	min_height, max_height: f32,
	min_across, max_across: f32,
) -> (
	row_min_x, row_max_x: i32,
	intersects: bool,
) {
	height := (world_y - base_y) * height_y_coeff
	if height < min_height || height > max_height {
		return 0, 0, false
	}

	world_x_at_local_zero := f32(chunk_origin.x) + 0.5
	dx0 := world_x_at_local_zero - base_x
	dz := world_z - base_z
	along_at_local_zero := dx0 * along_x_coeff + dz * along_z_coeff
	across_at_local_zero := dx0 * across_x_coeff + dz * across_z_coeff

	row_min_x, row_max_x, intersects = terrain_density_linear_coord_row_x_bounds(
		local_min_x,
		local_max_x,
		along_at_local_zero,
		along_x_coeff,
		min_along,
		max_along,
	)
	if !intersects {
		return
	}

	across_min_x, across_max_x, across_intersects := terrain_density_linear_coord_row_x_bounds(
		local_min_x,
		local_max_x,
		across_at_local_zero,
		across_x_coeff,
		min_across,
		max_across,
	)
	if !across_intersects {
		return 0, 0, false
	}
	if across_min_x > row_min_x {
		row_min_x = across_min_x
	}
	if across_max_x < row_max_x {
		row_max_x = across_max_x
	}
	intersects = row_min_x <= row_max_x
	return
}
