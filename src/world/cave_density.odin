package world

import world_async "async:world"
import "core:log"
import math "core:math"
import time "core:time"

import biomes "world:biomes"

//////////////////////////////////////
// Cave Density Types
/////////////////////////////////////

TerrainCaveMouthTransitionStyle :: enum {
	Sloped_Tube,
	Curved_Ramp,
	Spiral_Ramp,
}

TerrainCaveMouthTransitionScales :: struct {
	run_scale:          f32,
	drop_scale:         f32,
	side_scale:         f32,
	vestibule_scale:    f32,
	bend_t:             f32,
	bend_return_scale:  f32,
	deep_radius_scale:  f32,
	near_curve_boost:   f32,
	near_meander_boost: f32,
	deep_curve_boost:   f32,
	deep_meander_boost: f32,
	deep_lift_boost:    f32,
}

TerrainCaveMouthTransitionPlan :: struct {
	style:                           TerrainCaveMouthTransitionStyle,
	size_support:                    f32,
	dir_x, dir_z:                    f32,
	side_x, side_z:                  f32,
	transition_run:                  f32,
	transition_drop:                 f32,
	near_radius:                     f32,
	side_offset:                     f32,
	landing_x, landing_y, landing_z: f32,
	bend_x, bend_y, bend_z:          f32,
	near_run_blocks:                 f32,
	near_drop_blocks:                f32,
	bend_run_blocks:                 f32,
	bend_drop_blocks:                f32,
	handoff_run_blocks:              f32,
	handoff_drop_blocks:             f32,
}

TerrainCaveSegmentShape :: struct {
	radius_x_scale:        f32,
	radius_y_scale:        f32,
	radius_z_scale:        f32,
	radius_noise_scale:    f32,
	radius_neck_scale:     f32,
	radius_swell_scale:    f32,
	radius_endpoint_scale: f32,
	meander_scale:         f32,
	lift_scale:            f32,
	curve_scale:           f32,
	wall_scallop_scale:    f32,
	wall_notch_scale:      f32,
	wall_rib_scale:        f32,
	wall_lip_relief_scale: f32,
}

TerrainCaveFieldSample :: struct {
	open_strength:         f32,
	path_open_strength:    f32,
	chamber_open_strength: f32,
	spaghetti_strength:    f32,
	chamber_strength:      f32,
	path_axis_x:           bool,
}

TerrainCaveFieldNetworkSample :: struct {
	found:        bool,
	connected:    bool,
	bridgeable:   bool,
	distance:     f32,
	route_radius: f32,
	nearest_x:    f32,
	nearest_y:    f32,
	nearest_z:    f32,
	route_dir_x:  f32,
	route_dir_y:  f32,
	route_dir_z:  f32,
}

TerrainCaveEdgeRouteBounds :: struct {
	min_x, max_x: f32,
	min_y, max_y: f32,
	min_z, max_z: f32,
}

TerrainCaveNodeConnectivity :: struct {
	has_edge:               bool,
	has_anchor:             bool,
	should_carve:           bool,
	should_bridge:          bool,
	nearest_route_found:    bool,
	nearest_route_distance: f32,
	nearest_route_radius:   f32,
	nearest_x:              f32,
	nearest_y:              f32,
	nearest_z:              f32,
}

TerrainCaveChunkFeatureBucket :: struct {
	node_indices:            [biomes.GENERATION_REGION_CAVE_NETWORK_NODE_CAPACITY]u32,
	node_count:              u32,
	bridge_node_indices:     [biomes.GENERATION_REGION_CAVE_NETWORK_NODE_CAPACITY]u32,
	bridge_node_count:       u32,
	edge_indices:            [biomes.GENERATION_REGION_CAVE_NETWORK_EDGE_CAPACITY]u32,
	edge_core_segment_masks: [biomes.GENERATION_REGION_CAVE_NETWORK_EDGE_CAPACITY]u64,
	edge_count:              u32,
	anchor_indices:          [biomes.GENERATION_REGION_CAVE_ANCHOR_CAPACITY]u32,
	anchor_count:            u32,
}

//////////////////////////////////////
// Cave Density Methods
/////////////////////////////////////

terrain_density_subterranean_biome_caves_apply :: proc(
	view: ^world_async.ChunkVoxelView,
	region: ^biomes.GenerationRegion,
	chunk_origin: world_async.BlockCoord,
	columns: []TerrainBiomeColumn,
	wall_buffer: ^TerrainCaveWallMaterialBuffer = nil,
) {
	when TERRAIN_CAVE_FAST_SKELETON {
		_ = view
		_ = region
		_ = chunk_origin
		_ = columns
		_ = wall_buffer
		return
	}

	key := region.key
	log.assertf(
		len(columns) == CHUNK_BLOCK_LENGTH * CHUNK_BLOCK_LENGTH,
		"terrain density column target count mismatch: %d",
		len(columns),
	)
	if f32(chunk_origin.y) > TERRAIN_CAVE_TOP_CUSHION_END_BLOCKS ||
	   f32(chunk_origin.y + CHUNK_BLOCK_LENGTH) < TERRAIN_CAVE_BOTTOM_CUSHION_START_BLOCKS {
		return
	}
	if chunk_origin.y >= 0 {
		return
	}

	edge_route_bounds: [biomes.GENERATION_REGION_CAVE_NETWORK_EDGE_CAPACITY]TerrainCaveEdgeRouteBounds
	terrain_density_cave_edge_route_bounds_fill(region, edge_route_bounds[:])

	stamp_count: u32
	for z := TERRAIN_CAVE_FIELD_SAMPLE_STEP_BLOCKS / 2;
	    z < CHUNK_BLOCK_LENGTH && stamp_count < TERRAIN_CAVE_FIELD_STAMP_CAPACITY_PER_CHUNK;
	    z += TERRAIN_CAVE_FIELD_SAMPLE_STEP_BLOCKS {
		world_z := chunk_origin.z + z
		for y := TERRAIN_CAVE_FIELD_SAMPLE_STEP_BLOCKS / 2;
		    y < CHUNK_BLOCK_LENGTH && stamp_count < TERRAIN_CAVE_FIELD_STAMP_CAPACITY_PER_CHUNK;
		    y += TERRAIN_CAVE_FIELD_SAMPLE_STEP_BLOCKS {
			world_y := chunk_origin.y + y
			vertical_support := terrain_density_cave_vertical_support(f32(world_y))
			if vertical_support <= 0 {
				continue
			}
			for x := TERRAIN_CAVE_FIELD_SAMPLE_STEP_BLOCKS / 2;
			    x < CHUNK_BLOCK_LENGTH &&
			    stamp_count < TERRAIN_CAVE_FIELD_STAMP_CAPACITY_PER_CHUNK;
			    x += TERRAIN_CAVE_FIELD_SAMPLE_STEP_BLOCKS {
				column := columns[x + z * CHUNK_BLOCK_LENGTH]
				depth_below_surface := column.surface_height_blocks - f32(world_y)
				if depth_below_surface < 18 {
					continue
				}

				world_x := chunk_origin.x + x
				cave_field_profile_start: time.Tick
				when TERRAIN_GENERATION_PROFILE_PHASES {
					cave_field_profile_start = time.tick_now()
				}
				when !TERRAIN_GENERATION_PROFILE_PHASES {
					_ = cave_field_profile_start
				}
				field_sample := terrain_density_subterranean_cave_field_sample(
					key,
					world_x,
					world_y,
					world_z,
					depth_below_surface,
				)
				if !terrain_density_cave_field_sample_is_candidate(
					field_sample,
					vertical_support,
				) {
					when TERRAIN_GENERATION_PROFILE_PHASES {
						terrain_generation_profile_stats.cave_field_scan += time.tick_since(
							cave_field_profile_start,
						)
					}
					continue
				}
				open_strength := field_sample.open_strength * vertical_support
				path_candidate := terrain_density_cave_field_sample_prefers_path(
					field_sample,
					vertical_support,
				)

				subterranean_sample := biomes.subterranean_biome_field_sample(
					key,
					world_x,
					world_y,
					world_z,
				)
				biome_id := subterranean_sample.cells[0].biome_id
				radius := biomes.regional_terrain_field_lerp(f32(3.5), f32(10.5), open_strength)
				if biome_id == .Fungal_Vaults {
					radius *= 1.25
				} else if biome_id == .Crystal_Geode_Network {
					radius *= 0.82
				} else if biome_id == .Buried_Aquifer_Caves {
					radius *= 1.05
				}
				when TERRAIN_GENERATION_PROFILE_PHASES {
					terrain_generation_profile_stats.cave_field_scan += time.tick_since(
						cave_field_profile_start,
					)
					cave_field_profile_start = time.tick_now()
				}
				radius_x := radius * TERRAIN_CAVE_FIELD_CHAMBER_XZ_SCALE
				radius_y :=
					radius *
					biomes.regional_terrain_field_lerp(
						TERRAIN_CAVE_FIELD_CHAMBER_Y_MIN_SCALE,
						TERRAIN_CAVE_FIELD_CHAMBER_Y_MAX_SCALE,
						open_strength,
					)
				radius_z := radius * TERRAIN_CAVE_FIELD_CHAMBER_XZ_SCALE
				network_sample := terrain_density_cave_field_network_sample(
					region,
					f32(world_x) + 0.5,
					f32(world_y) + 0.5,
					f32(world_z) + 0.5,
					radius,
					path_candidate,
					edge_route_bounds[:],
				)
				when TERRAIN_GENERATION_PROFILE_PHASES {
					terrain_generation_profile_stats.cave_field_network += time.tick_since(
						cave_field_profile_start,
					)
				}
				if !network_sample.found ||
				   (!network_sample.connected && !network_sample.bridgeable) {
					continue
				}
				if !path_candidate &&
				   terrain_density_cave_field_sample_prefers_route_path(
					   field_sample,
					   vertical_support,
					   network_sample,
				   ) {
					path_candidate = true
				}
				route_pocket_candidate :=
					!path_candidate &&
					terrain_density_cave_field_sample_prefers_route_pocket(
						field_sample,
						vertical_support,
						network_sample,
					)
				if !path_candidate &&
				   !route_pocket_candidate &&
				   stamp_count >=
					   TERRAIN_CAVE_FIELD_STAMP_CAPACITY_PER_CHUNK -
						   TERRAIN_CAVE_FIELD_PATH_STAMP_RESERVE_PER_CHUNK {
					continue
				}
				if path_candidate {
					path_shape := terrain_density_cave_field_path_shape()
					terrain_density_cave_passage_shape_apply_biome(&path_shape, biome_id)
					path_half_length := radius * TERRAIN_CAVE_FIELD_PATH_SEGMENT_HALF_LENGTH_SCALE
					path_radius := radius * TERRAIN_CAVE_FIELD_PATH_SEGMENT_RADIUS_SCALE
					center_x := f32(world_x) + 0.5
					center_y := f32(world_y) + 0.5
					center_z := f32(world_z) + 0.5
					dir_x, dir_y, dir_z, _ := terrain_density_cave_field_path_direction(
						field_sample,
						network_sample,
					)
					when TERRAIN_GENERATION_PROFILE_PHASES {
						cave_field_profile_start = time.tick_now()
					}
					terrain_density_carve_rough_segment_shaped(
						view,
						key,
						chunk_origin,
						columns,
						center_x - dir_x * path_half_length,
						center_y - dir_y * path_half_length,
						center_z - dir_z * path_half_length,
						center_x + dir_x * path_half_length,
						center_y + dir_y * path_half_length,
						center_z + dir_z * path_half_length,
						path_radius,
						path_shape,
						TERRAIN_CAVE_FIELD_DETAIL_SALT,
						biome_id,
						false,
						wall_buffer,
					)
					when TERRAIN_GENERATION_PROFILE_PHASES {
						terrain_generation_profile_stats.cave_field_path += time.tick_since(
							cave_field_profile_start,
						)
					}
					stamp_count += 1
					continue
				}
				if route_pocket_candidate {
					center_x := f32(world_x) + 0.5
					center_y := f32(world_y) + 0.5
					center_z := f32(world_z) + 0.5
					pocket_shape := terrain_density_cave_passage_shape(.Collapsed_Corridor)
					if biome_id == .Fungal_Vaults {
						pocket_shape = terrain_density_cave_passage_shape(.Worm_Path)
						pocket_shape.radius_y_scale = math.min(
							pocket_shape.radius_y_scale,
							f32(0.70),
						)
					} else if biome_id == .Crystal_Geode_Network {
						pocket_shape = terrain_density_cave_passage_shape(.Fracture)
					}
					terrain_density_cave_passage_shape_apply_biome(&pocket_shape, biome_id)
					throat_radius := math.max(
						f32(1.75),
						math.min(
							radius * TERRAIN_CAVE_FIELD_ROUTE_POCKET_THROAT_RADIUS_SCALE,
							network_sample.route_radius * f32(0.76),
						),
					)
					when TERRAIN_GENERATION_PROFILE_PHASES {
						cave_field_profile_start = time.tick_now()
					}
					terrain_density_carve_rough_segment_shaped(
						view,
						key,
						chunk_origin,
						columns,
						network_sample.nearest_x,
						network_sample.nearest_y,
						network_sample.nearest_z,
						center_x,
						center_y,
						center_z,
						throat_radius,
						pocket_shape,
						TERRAIN_CAVE_BRANCH_SALT,
						biome_id,
						false,
						wall_buffer,
					)
					when TERRAIN_GENERATION_PROFILE_PHASES {
						terrain_generation_profile_stats.cave_field_pocket_throat +=
							time.tick_since(cave_field_profile_start)
						cave_field_profile_start = time.tick_now()
					}
					terrain_density_carve_cave_field_route_pocket_cluster(
						view,
						key,
						chunk_origin,
						columns,
						center_x,
						center_y,
						center_z,
						network_sample.nearest_x,
						network_sample.nearest_y,
						network_sample.nearest_z,
						network_sample.route_dir_x,
						network_sample.route_dir_z,
						radius_x * TERRAIN_CAVE_FIELD_ROUTE_POCKET_ROOM_SCALE,
						radius_y * TERRAIN_CAVE_FIELD_ROUTE_POCKET_ROOM_SCALE,
						radius_z * TERRAIN_CAVE_FIELD_ROUTE_POCKET_ROOM_SCALE,
						TERRAIN_CAVE_FIELD_DETAIL_SALT,
						biome_id,
						wall_buffer,
					)
					when TERRAIN_GENERATION_PROFILE_PHASES {
						terrain_generation_profile_stats.cave_field_pocket_cluster +=
							time.tick_since(cave_field_profile_start)
					}
					stamp_count += 1
					continue
				}
				when TERRAIN_GENERATION_PROFILE_PHASES {
					cave_field_profile_start = time.tick_now()
				}
				terrain_density_carve_cave_room_lobed_ellipsoid(
					view,
					key,
					chunk_origin,
					columns,
					f32(world_x) + 0.5,
					f32(world_y) + 0.5,
					f32(world_z) + 0.5,
					radius_x,
					radius_y,
					radius_z,
					TERRAIN_CAVE_FIELD_DETAIL_SALT,
					biome_id,
					true,
					wall_buffer,
				)
				when TERRAIN_GENERATION_PROFILE_PHASES {
					terrain_generation_profile_stats.cave_field_chamber += time.tick_since(
						cave_field_profile_start,
					)
				}
				if network_sample.bridgeable && !network_sample.connected {
					bridge_shape := terrain_density_cave_passage_shape(.Collapsed_Corridor)
					bridge_shape.radius_y_scale = math.min(bridge_shape.radius_y_scale, f32(0.64))
					bridge_shape.radius_neck_scale = math.max(
						bridge_shape.radius_neck_scale,
						f32(0.34),
					)
					terrain_density_cave_passage_shape_apply_biome(&bridge_shape, biome_id)
					bridge_radius := math.max(
						f32(2),
						math.min(
							radius * TERRAIN_CAVE_FIELD_NETWORK_BRIDGE_RADIUS_SCALE,
							network_sample.route_radius * f32(0.82),
						),
					)
					when TERRAIN_GENERATION_PROFILE_PHASES {
						cave_field_profile_start = time.tick_now()
					}
					terrain_density_carve_rough_segment_shaped(
						view,
						key,
						chunk_origin,
						columns,
						f32(world_x) + 0.5,
						f32(world_y) + 0.5,
						f32(world_z) + 0.5,
						network_sample.nearest_x,
						network_sample.nearest_y,
						network_sample.nearest_z,
						bridge_radius,
						bridge_shape,
						TERRAIN_CAVE_BRANCH_SALT,
						biome_id,
						false,
						wall_buffer,
					)
					when TERRAIN_GENERATION_PROFILE_PHASES {
						terrain_generation_profile_stats.cave_field_bridge += time.tick_since(
							cave_field_profile_start,
						)
					}
				}
				stamp_count += 1
			}
		}
	}
}

terrain_density_cave_field_route_pocket_compound_shape :: proc(
	along, height, away, route_height: f32,
	biome_id: biomes.BiomeID,
) -> f32 {
	side_offset := TERRAIN_CAVE_FIELD_ROUTE_POCKET_FIELD_SIDE_OFFSET_SCALE
	outward_offset := TERRAIN_CAVE_FIELD_ROUTE_POCKET_FIELD_OUTWARD_OFFSET_SCALE
	inward_offset := TERRAIN_CAVE_FIELD_ROUTE_POCKET_FIELD_INWARD_OFFSET_SCALE
	branch_offset := TERRAIN_CAVE_FIELD_ROUTE_POCKET_FIELD_BRANCH_OFFSET_SCALE
	branch_away := TERRAIN_CAVE_FIELD_ROUTE_POCKET_FIELD_BRANCH_AWAY_SCALE
	blend_radius := TERRAIN_CAVE_FIELD_ROUTE_POCKET_FIELD_BLEND_RADIUS
	side_radius_along := f32(0.48)
	side_radius_height := f32(0.62)
	side_radius_away := f32(0.46)
	outward_radius_along := f32(0.56)
	outward_radius_height := f32(0.70)
	outward_radius_away := f32(0.54)
	inward_radius_along := f32(0.66)
	inward_radius_height := f32(0.64)
	inward_radius_away := f32(0.46)
	branch_radius_along := f32(0.36)
	branch_radius_height := f32(0.48)
	branch_radius_away := f32(0.34)
	inward_height := math.clamp(route_height * f32(0.24), f32(-0.24), f32(0.24))

	#partial switch biome_id {
	case .Fungal_Vaults:
		side_radius_along *= 1.16
		side_radius_height *= 0.92
		side_radius_away *= 1.12
		outward_radius_along *= 1.08
		outward_radius_away *= 1.12
		branch_radius_along *= 1.20
		branch_radius_height *= 0.92
		branch_radius_away *= 1.16
	case .Crystal_Geode_Network:
		side_offset *= 0.82
		branch_offset *= 0.78
		branch_away *= 0.82
		side_radius_along *= 0.72
		side_radius_height *= 1.24
		side_radius_away *= 0.70
		outward_radius_height *= 1.18
		outward_radius_away *= 0.78
		inward_radius_height *= 1.12
		branch_radius_along *= 0.74
		branch_radius_height *= 1.28
		branch_radius_away *= 0.70
	case .Buried_Aquifer_Caves:
		side_radius_along *= 1.12
		side_radius_height *= 0.62
		side_radius_away *= 1.18
		outward_radius_along *= 1.16
		outward_radius_height *= 0.58
		outward_radius_away *= 1.28
		inward_radius_height *= 0.70
		branch_radius_along *= 1.18
		branch_radius_height *= 0.68
		branch_radius_away *= 1.18
	case .Temperate_Hills, .Basalt_Spire_Highlands, .Wet_Lowland_Marsh, .Corrupted_Ash_Forest:
	}

	core_shape := along * along + height * height + away * away
	side_a_shape := terrain_density_cave_room_ellipsoid_shape(
		along,
		height,
		away,
		side_offset,
		0,
		outward_offset * f32(0.18),
		side_radius_along,
		side_radius_height,
		side_radius_away,
	)
	side_b_shape := terrain_density_cave_room_ellipsoid_shape(
		along,
		height,
		away,
		-side_offset,
		0,
		outward_offset * f32(0.18),
		side_radius_along,
		side_radius_height,
		side_radius_away,
	)
	outward_shape := terrain_density_cave_room_ellipsoid_shape(
		along,
		height,
		away,
		0,
		0,
		outward_offset,
		outward_radius_along,
		outward_radius_height,
		outward_radius_away,
	)
	inward_shape := terrain_density_cave_room_ellipsoid_shape(
		along,
		height,
		away,
		0,
		inward_height,
		-inward_offset,
		inward_radius_along,
		inward_radius_height,
		inward_radius_away,
	)
	branch_shape := terrain_density_cave_room_ellipsoid_shape(
		along,
		height,
		away,
		side_offset + branch_offset * f32(0.38),
		inward_height * f32(0.35),
		outward_offset + branch_away * f32(0.34),
		branch_radius_along * f32(1.18),
		branch_radius_height,
		branch_radius_away * f32(1.12),
	)

	shape := terrain_density_cave_room_smooth_min(core_shape, side_a_shape, blend_radius)
	shape = terrain_density_cave_room_smooth_min(shape, side_b_shape, blend_radius)
	shape = terrain_density_cave_room_smooth_min(shape, outward_shape, blend_radius)
	shape = terrain_density_cave_room_smooth_min(shape, inward_shape, blend_radius)
	shape = terrain_density_cave_room_smooth_min(shape, branch_shape, blend_radius)
	return shape
}

terrain_density_carve_cave_field_route_pocket_cluster :: proc(
	view: ^world_async.ChunkVoxelView,
	key: biomes.FeatureGridKey,
	chunk_origin: world_async.BlockCoord,
	columns: []TerrainBiomeColumn,
	center_x, center_y, center_z: f32,
	nearest_x, nearest_y, nearest_z: f32,
	route_dir_x, route_dir_z: f32,
	radius_x, radius_y, radius_z: f32,
	noise_salt: u64,
	biome_id: biomes.BiomeID,
	wall_buffer: ^TerrainCaveWallMaterialBuffer = nil,
) {
	rx := math.max(f32(1), radius_x)
	ry := math.max(f32(1), radius_y)
	rz := math.max(f32(1), radius_z)
	outward_x := center_x - nearest_x
	outward_z := center_z - nearest_z
	outward_len := math.sqrt_f32(outward_x * outward_x + outward_z * outward_z)
	if outward_len <= 0.001 {
		route_len := math.sqrt_f32(route_dir_x * route_dir_x + route_dir_z * route_dir_z)
		if route_len > 0.001 {
			outward_x = -route_dir_z / route_len
			outward_z = route_dir_x / route_len
		} else {
			outward_x = 1
			outward_z = 0
		}
	} else {
		outward_x /= outward_len
		outward_z /= outward_len
	}

	tangent_x := route_dir_x
	tangent_z := route_dir_z
	tangent_len := math.sqrt_f32(tangent_x * tangent_x + tangent_z * tangent_z)
	if tangent_len > 0.001 {
		tangent_x /= tangent_len
		tangent_z /= tangent_len
		dot := tangent_x * outward_x + tangent_z * outward_z
		tangent_x -= outward_x * dot
		tangent_z -= outward_z * dot
		tangent_len = math.sqrt_f32(tangent_x * tangent_x + tangent_z * tangent_z)
	}
	if tangent_len <= 0.001 {
		tangent_x = -outward_z
		tangent_z = outward_x
	} else {
		tangent_x /= tangent_len
		tangent_z /= tangent_len
	}

	max_radius := math.max(rx, math.max(ry, rz))
	padding := max_radius * 0.74 + 2
	local_min_x, local_max_x, local_min_y, local_max_y, local_min_z, local_max_z, intersects :=
		terrain_density_carve_bounds_from_extents(
			chunk_origin,
			center_x - rx - padding,
			center_x + rx + padding,
			center_y - ry - padding,
			center_y + ry + padding,
			center_z - rz - padding,
			center_z + rz + padding,
		)
	if !intersects {
		return
	}

	route_height := math.clamp((nearest_y - center_y) / ry, f32(-1), f32(1))
	cell_size := math.max(
		f32(3),
		math.max(rx, rz) * TERRAIN_CAVE_FIELD_ROUTE_POCKET_FIELD_CELL_SCALE,
	)
	along_x_coeff := tangent_x / rx
	along_z_coeff := tangent_z / rx
	height_y_coeff := f32(1) / ry
	away_x_coeff := outward_x / rz
	away_z_coeff := outward_z / rz
	route_pocket_side_offset := TERRAIN_CAVE_FIELD_ROUTE_POCKET_FIELD_SIDE_OFFSET_SCALE
	route_pocket_outward_offset := TERRAIN_CAVE_FIELD_ROUTE_POCKET_FIELD_OUTWARD_OFFSET_SCALE
	route_pocket_inward_offset := TERRAIN_CAVE_FIELD_ROUTE_POCKET_FIELD_INWARD_OFFSET_SCALE
	route_pocket_branch_offset := TERRAIN_CAVE_FIELD_ROUTE_POCKET_FIELD_BRANCH_OFFSET_SCALE
	route_pocket_branch_away := TERRAIN_CAVE_FIELD_ROUTE_POCKET_FIELD_BRANCH_AWAY_SCALE
	route_pocket_side_radius_along := f32(0.48)
	route_pocket_side_radius_height := f32(0.62)
	route_pocket_side_radius_away := f32(0.46)
	route_pocket_outward_radius_along := f32(0.56)
	route_pocket_outward_radius_height := f32(0.70)
	route_pocket_outward_radius_away := f32(0.54)
	route_pocket_inward_radius_along := f32(0.66)
	route_pocket_inward_radius_height := f32(0.64)
	route_pocket_inward_radius_away := f32(0.46)
	route_pocket_branch_radius_along := f32(0.36)
	route_pocket_branch_radius_height := f32(0.48)
	route_pocket_branch_radius_away := f32(0.34)
	route_pocket_inward_height := math.clamp(route_height * f32(0.24), f32(-0.24), f32(0.24))
	#partial switch biome_id {
	case .Fungal_Vaults:
		route_pocket_side_radius_along *= 1.16
		route_pocket_side_radius_height *= 0.92
		route_pocket_side_radius_away *= 1.12
		route_pocket_outward_radius_along *= 1.08
		route_pocket_outward_radius_away *= 1.12
		route_pocket_branch_radius_along *= 1.20
		route_pocket_branch_radius_height *= 0.92
		route_pocket_branch_radius_away *= 1.16
	case .Crystal_Geode_Network:
		route_pocket_side_offset *= 0.82
		route_pocket_branch_offset *= 0.78
		route_pocket_branch_away *= 0.82
		route_pocket_side_radius_along *= 0.72
		route_pocket_side_radius_height *= 1.24
		route_pocket_side_radius_away *= 0.70
		route_pocket_outward_radius_height *= 1.18
		route_pocket_outward_radius_away *= 0.78
		route_pocket_inward_radius_height *= 1.12
		route_pocket_branch_radius_along *= 0.74
		route_pocket_branch_radius_height *= 1.28
		route_pocket_branch_radius_away *= 0.70
	case .Buried_Aquifer_Caves:
		route_pocket_side_radius_along *= 1.12
		route_pocket_side_radius_height *= 0.62
		route_pocket_side_radius_away *= 1.18
		route_pocket_outward_radius_along *= 1.16
		route_pocket_outward_radius_height *= 0.58
		route_pocket_outward_radius_away *= 1.28
		route_pocket_inward_radius_height *= 0.70
		route_pocket_branch_radius_along *= 1.18
		route_pocket_branch_radius_height *= 0.68
		route_pocket_branch_radius_away *= 1.18
	case .Temperate_Hills, .Basalt_Spire_Highlands, .Wet_Lowland_Marsh, .Corrupted_Ash_Forest:
	}
	route_pocket_shape_span := math.sqrt_f32(
		f32(1.240001) + TERRAIN_CAVE_FIELD_ROUTE_POCKET_FIELD_BLEND_RADIUS,
	)
	route_pocket_max_along_radius := math.max(
		f32(1),
		math.max(
			route_pocket_side_radius_along,
			math.max(
				route_pocket_outward_radius_along,
				math.max(
					route_pocket_inward_radius_along,
					route_pocket_branch_radius_along * f32(1.18),
				),
			),
		),
	)
	route_pocket_max_height_radius := math.max(
		f32(1),
		math.max(
			route_pocket_side_radius_height,
			math.max(
				route_pocket_outward_radius_height,
				math.max(route_pocket_inward_radius_height, route_pocket_branch_radius_height),
			),
		),
	)
	route_pocket_max_away_radius := math.max(
		f32(1),
		math.max(
			route_pocket_side_radius_away,
			math.max(
				route_pocket_outward_radius_away,
				math.max(
					route_pocket_inward_radius_away,
					route_pocket_branch_radius_away * f32(1.12),
				),
			),
		),
	)
	route_pocket_min_along_center := math.min(-route_pocket_side_offset, f32(0))
	route_pocket_max_along_center := math.max(
		route_pocket_side_offset,
		route_pocket_side_offset + route_pocket_branch_offset * f32(0.38),
	)
	route_pocket_min_height_center := math.min(
		f32(0),
		math.min(route_pocket_inward_height, route_pocket_inward_height * f32(0.35)),
	)
	route_pocket_max_height_center := math.max(
		f32(0),
		math.max(route_pocket_inward_height, route_pocket_inward_height * f32(0.35)),
	)
	route_pocket_min_away_center := math.min(-route_pocket_inward_offset, f32(0))
	route_pocket_max_away_center := math.max(
		route_pocket_outward_offset,
		route_pocket_outward_offset + route_pocket_branch_away * f32(0.34),
	)
	route_pocket_min_along :=
		route_pocket_min_along_center -
		route_pocket_max_along_radius * route_pocket_shape_span -
		0.25
	route_pocket_max_along :=
		route_pocket_max_along_center +
		route_pocket_max_along_radius * route_pocket_shape_span +
		0.25
	route_pocket_min_height :=
		route_pocket_min_height_center -
		route_pocket_max_height_radius * route_pocket_shape_span -
		0.25
	route_pocket_max_height :=
		route_pocket_max_height_center +
		route_pocket_max_height_radius * route_pocket_shape_span +
		0.25
	route_pocket_min_away :=
		route_pocket_min_away_center -
		route_pocket_max_away_radius * route_pocket_shape_span -
		0.25
	route_pocket_max_away :=
		route_pocket_max_away_center +
		route_pocket_max_away_radius * route_pocket_shape_span +
		0.25

	for z := local_min_z; z <= local_max_z; z += 1 {
		world_z := f32(chunk_origin.z + z) + 0.5
		for y := local_min_y; y <= local_max_y; y += 1 {
			world_y := f32(chunk_origin.y + y) + 0.5
			when TERRAIN_GENERATION_PROFILE_PHASES {
				terrain_generation_profile_stats.route_pocket_cluster_rows_scanned += 1
			}
			row_min_x, row_max_x, row_intersects := terrain_density_local_box_row_x_bounds(
				chunk_origin,
				local_min_x,
				local_max_x,
				world_y,
				world_z,
				center_x,
				center_y,
				center_z,
				along_x_coeff,
				along_z_coeff,
				height_y_coeff,
				away_x_coeff,
				away_z_coeff,
				route_pocket_min_along,
				route_pocket_max_along,
				route_pocket_min_height,
				route_pocket_max_height,
				route_pocket_min_away,
				route_pocket_max_away,
			)
			if !row_intersects {
				continue
			}
			when TERRAIN_GENERATION_PROFILE_PHASES {
				terrain_generation_profile_stats.route_pocket_cluster_rows_box += 1
			}
			row_ranges: [8]TerrainDensityRowRange
			row_range_count: u32
			world_x_at_local_zero := f32(chunk_origin.x) + 0.5
			row_dx0 := world_x_at_local_zero - center_x
			row_dz := world_z - center_z
			row_along_at_local_zero := row_dx0 * along_x_coeff + row_dz * along_z_coeff
			row_away_at_local_zero := row_dx0 * away_x_coeff + row_dz * away_z_coeff
			row_height := (world_y - center_y) * height_y_coeff
			terrain_density_route_pocket_row_range_add_component(
				&row_ranges,
				&row_range_count,
				row_min_x,
				row_max_x,
				row_along_at_local_zero,
				along_x_coeff,
				row_height,
				row_away_at_local_zero,
				away_x_coeff,
				0,
				0,
				0,
				1,
				1,
				1,
				route_pocket_shape_span,
			)
			terrain_density_route_pocket_row_range_add_component(
				&row_ranges,
				&row_range_count,
				row_min_x,
				row_max_x,
				row_along_at_local_zero,
				along_x_coeff,
				row_height,
				row_away_at_local_zero,
				away_x_coeff,
				route_pocket_side_offset,
				0,
				route_pocket_outward_offset * f32(0.18),
				route_pocket_side_radius_along,
				route_pocket_side_radius_height,
				route_pocket_side_radius_away,
				route_pocket_shape_span,
			)
			terrain_density_route_pocket_row_range_add_component(
				&row_ranges,
				&row_range_count,
				row_min_x,
				row_max_x,
				row_along_at_local_zero,
				along_x_coeff,
				row_height,
				row_away_at_local_zero,
				away_x_coeff,
				-route_pocket_side_offset,
				0,
				route_pocket_outward_offset * f32(0.18),
				route_pocket_side_radius_along,
				route_pocket_side_radius_height,
				route_pocket_side_radius_away,
				route_pocket_shape_span,
			)
			terrain_density_route_pocket_row_range_add_component(
				&row_ranges,
				&row_range_count,
				row_min_x,
				row_max_x,
				row_along_at_local_zero,
				along_x_coeff,
				row_height,
				row_away_at_local_zero,
				away_x_coeff,
				0,
				0,
				route_pocket_outward_offset,
				route_pocket_outward_radius_along,
				route_pocket_outward_radius_height,
				route_pocket_outward_radius_away,
				route_pocket_shape_span,
			)
			terrain_density_route_pocket_row_range_add_component(
				&row_ranges,
				&row_range_count,
				row_min_x,
				row_max_x,
				row_along_at_local_zero,
				along_x_coeff,
				row_height,
				row_away_at_local_zero,
				away_x_coeff,
				0,
				route_pocket_inward_height,
				-route_pocket_inward_offset,
				route_pocket_inward_radius_along,
				route_pocket_inward_radius_height,
				route_pocket_inward_radius_away,
				route_pocket_shape_span,
			)
			terrain_density_route_pocket_row_range_add_component(
				&row_ranges,
				&row_range_count,
				row_min_x,
				row_max_x,
				row_along_at_local_zero,
				along_x_coeff,
				row_height,
				row_away_at_local_zero,
				away_x_coeff,
				route_pocket_side_offset + route_pocket_branch_offset * f32(0.38),
				route_pocket_inward_height * f32(0.35),
				route_pocket_outward_offset + route_pocket_branch_away * f32(0.34),
				route_pocket_branch_radius_along * f32(1.18),
				route_pocket_branch_radius_height,
				route_pocket_branch_radius_away * f32(1.12),
				route_pocket_shape_span,
			)
			if row_range_count == 0 {
				continue
			}
			rough_noise_row_cache: TerrainValueNoise3RowCache
			rough_noise_row_cache_ready := false
			detail_noise_row_cache: TerrainValueNoise3RowCache
			detail_noise_row_cache_ready := false
			for row_range_i := u32(0); row_range_i < row_range_count; row_range_i += 1 {
				row_range := row_ranges[row_range_i]
				for x := row_range.min_x; x <= row_range.max_x; x += 1 {
					when TERRAIN_GENERATION_PROFILE_PHASES {
						terrain_generation_profile_stats.route_pocket_cluster_voxel_candidates += 1
					}
					if !terrain_density_local_block_can_carve(view, x, y, z) {
						continue
					}
					when TERRAIN_GENERATION_PROFILE_PHASES {
						terrain_generation_profile_stats.route_pocket_cluster_carveable_candidates += 1
					}
					world_x := f32(chunk_origin.x + x) + 0.5
					dx := world_x - center_x
					dy := world_y - center_y
					dz := world_z - center_z
					along := (dx * tangent_x + dz * tangent_z) / rx
					height := dy / ry
					away := (dx * outward_x + dz * outward_z) / rz
					shape := terrain_density_cave_field_route_pocket_compound_shape(
						along,
						height,
						away,
						route_height,
						biome_id,
					)
					if shape > f32(1.240001) {
						continue
					}
					when TERRAIN_GENERATION_PROFILE_PHASES {
						terrain_generation_profile_stats.route_pocket_cluster_shape_candidates += 1
					}

					when TERRAIN_CAVE_ROUTE_POCKET_CORE_BYPASS {
						if shape <= TERRAIN_CAVE_ROUTE_POCKET_CORE_BYPASS_SHAPE_MAX {
							terrain_density_carve_checked_local_block_with_material(
								view,
								key,
								chunk_origin,
								columns,
								x,
								y,
								z,
								biome_id,
								false,
								wall_buffer,
							)
							continue
						}
					}

					if !rough_noise_row_cache_ready {
						rough_noise_row_cache = terrain_value_noise3_row_cache_make(
							key,
							noise_salt,
							17,
							chunk_origin.y + y,
							chunk_origin.z + z,
						)
						rough_noise_row_cache_ready = true
					}
					rough := terrain_value_noise3_row_cache_sample(
						&rough_noise_row_cache,
						chunk_origin.x + x,
					)
					if !detail_noise_row_cache_ready {
						detail_noise_row_cache = terrain_value_noise3_row_cache_make(
							key,
							noise_salt ~ TERRAIN_CAVE_PASSAGE_RIB_SALT,
							8,
							chunk_origin.y + y,
							chunk_origin.z + z,
						)
						detail_noise_row_cache_ready = true
					}
					detail := terrain_value_noise3_row_cache_sample(
						&detail_noise_row_cache,
						chunk_origin.x + x,
					)
					threshold_without_cellular := 1.0 + rough * f32(0.11) + detail * f32(0.07)
					if shape > threshold_without_cellular + f32(0.060001) {
						continue
					}
					when TERRAIN_GENERATION_PROFILE_PHASES {
						terrain_generation_profile_stats.route_pocket_cluster_worley_candidates += 1
					}
					cell_gap := terrain_density_cave_room_worley_gap(
						key,
						world_x,
						world_y,
						world_z,
						cell_size,
						noise_salt,
					)
					cellular_pocket := math.smoothstep(f32(0.36), f32(0.78), cell_gap)
					cellular_ridge := 1.0 - math.smoothstep(f32(0.08), f32(0.28), cell_gap)
					threshold :=
						threshold_without_cellular +
						cellular_pocket * f32(0.06) -
						cellular_ridge * f32(0.05)
					if shape <= threshold {
						terrain_density_carve_checked_local_block_with_material(
							view,
							key,
							chunk_origin,
							columns,
							x,
							y,
							z,
							biome_id,
							true,
							wall_buffer,
						)
					}
				}
			}
		}
	}
}

terrain_density_cave_field_domain_warp_sample_coord :: proc(
	key: biomes.FeatureGridKey,
	world_x, world_y, world_z: i32,
	depth_support: f32,
) -> (
	sample_x, sample_y, sample_z: i32,
) {
	warp_support := math.smoothstep(f32(0.18), f32(0.82), depth_support)
	if warp_support <= 0 {
		return world_x, world_y, world_z
	}

	warp_x := biomes.regional_terrain_field_value_noise_3(
		key,
		world_x,
		world_y,
		world_z,
		96,
		TERRAIN_CAVE_FIELD_DETAIL_SALT ~ TERRAIN_CAVE_FIELD_SPAGHETTI_A_SALT,
	)
	warp_y := biomes.regional_terrain_field_value_noise_3(
		key,
		world_x,
		world_y,
		world_z,
		112,
		TERRAIN_CAVE_FIELD_CHAMBER_SALT ~ TERRAIN_CAVE_FIELD_DETAIL_SALT,
	)
	warp_z := biomes.regional_terrain_field_value_noise_3(
		key,
		world_x,
		world_y,
		world_z,
		104,
		TERRAIN_CAVE_FIELD_DETAIL_SALT ~ TERRAIN_CAVE_FIELD_SPAGHETTI_B_SALT,
	)
	detail_x := biomes.regional_terrain_field_value_noise_3(
		key,
		world_x,
		world_y,
		world_z,
		37,
		TERRAIN_CAVE_FIELD_SPAGHETTI_A_SALT ~ TERRAIN_CAVE_FIELD_CHAMBER_SALT,
	)
	detail_y := biomes.regional_terrain_field_value_noise_3(
		key,
		world_x,
		world_y,
		world_z,
		43,
		TERRAIN_CAVE_FIELD_SPAGHETTI_B_SALT ~ TERRAIN_CAVE_FIELD_CHAMBER_SALT,
	)
	detail_z := biomes.regional_terrain_field_value_noise_3(
		key,
		world_x,
		world_y,
		world_z,
		41,
		TERRAIN_CAVE_FIELD_SPAGHETTI_A_SALT ~ TERRAIN_CAVE_FIELD_SPAGHETTI_B_SALT,
	)

	warp_scale := TERRAIN_CAVE_FIELD_DOMAIN_WARP_SCALE_BLOCKS * warp_support
	sample_x = i32(
		math.floor_f32(
			f32(world_x) +
			(warp_x + detail_x * TERRAIN_CAVE_FIELD_DOMAIN_WARP_DETAIL_SCALE) * warp_scale,
		),
	)
	sample_y = i32(
		math.floor_f32(
			f32(world_y) +
			(warp_y + detail_y * TERRAIN_CAVE_FIELD_DOMAIN_WARP_DETAIL_SCALE) *
				warp_scale *
				TERRAIN_CAVE_FIELD_DOMAIN_WARP_Y_SCALE,
		),
	)
	sample_z = i32(
		math.floor_f32(
			f32(world_z) +
			(warp_z + detail_z * TERRAIN_CAVE_FIELD_DOMAIN_WARP_DETAIL_SCALE) * warp_scale,
		),
	)
	return
}

terrain_density_subterranean_cave_field_sample :: proc(
	key: biomes.FeatureGridKey,
	world_x, world_y, world_z: i32,
	depth_below_surface: f32,
) -> TerrainCaveFieldSample {
	depth_support := math.smoothstep(f32(18), f32(56), depth_below_surface)
	if depth_support <= 0 {
		return {}
	}

	sample_x, sample_y, sample_z := terrain_density_cave_field_domain_warp_sample_coord(
		key,
		world_x,
		world_y,
		world_z,
		depth_support,
	)

	spaghetti_a := biomes.regional_terrain_field_value_noise_3(
		key,
		sample_x,
		sample_y,
		sample_z,
		42,
		TERRAIN_CAVE_FIELD_SPAGHETTI_A_SALT,
	)
	spaghetti_b := biomes.regional_terrain_field_value_noise_3(
		key,
		sample_x,
		sample_y,
		sample_z,
		48,
		TERRAIN_CAVE_FIELD_SPAGHETTI_B_SALT,
	)
	spaghetti_width := 0.055 + depth_support * 0.045
	spaghetti_distance := math.max(math.abs(spaghetti_a), math.abs(spaghetti_b))
	spaghetti_strength := math.clamp(
		(spaghetti_width - spaghetti_distance) / spaghetti_width,
		f32(0),
		f32(1),
	)

	chamber := biomes.regional_terrain_field_value_noise_3(
		key,
		sample_x,
		sample_y,
		sample_z,
		118,
		TERRAIN_CAVE_FIELD_CHAMBER_SALT,
	)
	chamber_detail := biomes.regional_terrain_field_value_noise_3(
		key,
		sample_x,
		sample_y,
		sample_z,
		34,
		TERRAIN_CAVE_FIELD_DETAIL_SALT,
	)
	chamber_strength := math.smoothstep(
		f32(0.46),
		f32(0.78),
		chamber + chamber_detail * 0.24 + depth_support * 0.14,
	)
	path_open_strength := spaghetti_strength * depth_support
	chamber_open_strength := chamber_strength * depth_support

	return {
		open_strength = math.max(path_open_strength * 0.90, chamber_open_strength),
		path_open_strength = path_open_strength,
		chamber_open_strength = chamber_open_strength,
		spaghetti_strength = spaghetti_strength,
		chamber_strength = chamber_strength,
		path_axis_x = math.abs(spaghetti_a) < math.abs(spaghetti_b),
	}
}

terrain_density_cave_field_sample_prefers_path :: proc(
	field_sample: TerrainCaveFieldSample,
	vertical_support: f32,
) -> bool {
	path_strength := field_sample.path_open_strength * vertical_support
	chamber_strength := field_sample.chamber_open_strength * vertical_support
	return(
		path_strength >= TERRAIN_CAVE_FIELD_PATH_OPEN_STRENGTH_MIN &&
		(chamber_strength < TERRAIN_CAVE_FIELD_OPEN_STRENGTH_MIN ||
				path_strength * TERRAIN_CAVE_FIELD_PATH_SELECTION_BIAS > chamber_strength) \
	)
}

terrain_density_cave_field_sample_prefers_route_path :: proc(
	field_sample: TerrainCaveFieldSample,
	vertical_support: f32,
	network_sample: TerrainCaveFieldNetworkSample,
) -> bool {
	if !network_sample.connected {
		return false
	}
	path_strength := field_sample.path_open_strength * vertical_support
	if path_strength < TERRAIN_CAVE_FIELD_ROUTE_PATH_OPEN_STRENGTH_MIN {
		return false
	}
	chamber_strength := field_sample.chamber_open_strength * vertical_support
	if chamber_strength >= TERRAIN_CAVE_FIELD_OPEN_STRENGTH_MIN {
		return false
	}
	return(
		network_sample.distance <=
		network_sample.route_radius + TERRAIN_CAVE_FIELD_ROUTE_PATH_DISTANCE_MARGIN_BLOCKS \
	)
}

terrain_density_cave_field_sample_prefers_route_pocket :: proc(
	field_sample: TerrainCaveFieldSample,
	vertical_support: f32,
	network_sample: TerrainCaveFieldNetworkSample,
) -> bool {
	if !network_sample.connected {
		return false
	}
	chamber_strength := field_sample.chamber_open_strength * vertical_support
	if chamber_strength < TERRAIN_CAVE_FIELD_OPEN_STRENGTH_MIN {
		return false
	}
	return(
		network_sample.distance <=
		network_sample.route_radius + TERRAIN_CAVE_FIELD_ROUTE_POCKET_DISTANCE_MARGIN_BLOCKS \
	)
}

terrain_density_cave_field_sample_is_candidate :: proc(
	field_sample: TerrainCaveFieldSample,
	vertical_support: f32,
) -> bool {
	path_strength := field_sample.path_open_strength * vertical_support
	chamber_strength := field_sample.chamber_open_strength * vertical_support
	return(
		path_strength >= TERRAIN_CAVE_FIELD_PATH_OPEN_STRENGTH_MIN ||
		chamber_strength >= TERRAIN_CAVE_FIELD_OPEN_STRENGTH_MIN \
	)
}

terrain_density_cave_field_network_sample :: proc(
	region: ^biomes.GenerationRegion,
	world_x, world_y, world_z, radius: f32,
	path_candidate: bool,
	edge_route_bounds: []TerrainCaveEdgeRouteBounds,
) -> TerrainCaveFieldNetworkSample {
	sample := TerrainCaveFieldNetworkSample {
		distance = biomes.BIOME_FIELD_NO_DISTANCE,
	}
	when !TERRAIN_CAVE_FIELD_NETWORK_ROUTE_BOUNDS_ENABLED {
		_ = edge_route_bounds
	}

	for i := u32(0); i < region.cave_network_edge_count; i += 1 {
		edge := region.cave_network_edges[i]
		when TERRAIN_CAVE_FIELD_NETWORK_ROUTE_BOUNDS_ENABLED {
			if !terrain_density_cave_edge_route_bounds_may_reach_sample(
				edge_route_bounds[i],
				edge,
				world_x,
				world_y,
				world_z,
				radius,
			) {
				continue
			}
		}
		prev_x, prev_y, prev_z := terrain_density_cave_edge_route_point(edge, 0)
		for segment_index := u32(1);
		    segment_index <= TERRAIN_CAVE_EDGE_ROUTE_SEGMENT_COUNT;
		    segment_index += 1 {
			t := f32(segment_index) / f32(TERRAIN_CAVE_EDGE_ROUTE_SEGMENT_COUNT)
			next_x, next_y, next_z := terrain_density_cave_edge_route_point(edge, t)
			route_dir_x, route_dir_y, route_dir_z := terrain_density_delta_3(
				prev_x,
				prev_y,
				prev_z,
				next_x,
				next_y,
				next_z,
			)
			px, py, pz, distance := terrain_density_closest_segment_point_3(
				world_x,
				world_y,
				world_z,
				prev_x,
				prev_y,
				prev_z,
				next_x,
				next_y,
				next_z,
			)
			terrain_density_cave_field_network_sample_note(
				&sample,
				distance,
				math.max(f32(3), edge.radius_blocks),
				px,
				py,
				pz,
				route_dir_x,
				route_dir_y,
				route_dir_z,
			)
			prev_x = next_x
			prev_y = next_y
			prev_z = next_z
		}
	}

	if !sample.found {
		return sample
	}

	connected_margin := TERRAIN_CAVE_FIELD_NETWORK_CONNECTED_MARGIN_BLOCKS
	if path_candidate {
		connected_margin = TERRAIN_CAVE_FIELD_NETWORK_PATH_MARGIN_BLOCKS
	}
	connected_distance := radius + sample.route_radius + connected_margin
	bridge_distance :=
		radius + sample.route_radius + TERRAIN_CAVE_FIELD_NETWORK_BRIDGE_MARGIN_BLOCKS
	sample.connected = sample.distance <= connected_distance
	sample.bridgeable =
		!path_candidate &&
		radius >= TERRAIN_CAVE_FIELD_NETWORK_BRIDGE_MIN_RADIUS &&
		sample.distance > connected_distance &&
		sample.distance <= bridge_distance
	return sample
}

terrain_density_cave_edge_route_bounds :: proc(
	edge: biomes.CaveNetworkEdge,
) -> TerrainCaveEdgeRouteBounds {
	route_x, route_y, route_z := terrain_density_cave_edge_route_point(edge, 0)
	bounds := TerrainCaveEdgeRouteBounds {
		min_x = route_x,
		max_x = route_x,
		min_y = route_y,
		max_y = route_y,
		min_z = route_z,
		max_z = route_z,
	}
	for segment_index := u32(1);
	    segment_index <= TERRAIN_CAVE_EDGE_ROUTE_SEGMENT_COUNT;
	    segment_index += 1 {
		t := f32(segment_index) / f32(TERRAIN_CAVE_EDGE_ROUTE_SEGMENT_COUNT)
		route_x, route_y, route_z = terrain_density_cave_edge_route_point(edge, t)
		bounds.min_x = math.min(bounds.min_x, route_x)
		bounds.max_x = math.max(bounds.max_x, route_x)
		bounds.min_y = math.min(bounds.min_y, route_y)
		bounds.max_y = math.max(bounds.max_y, route_y)
		bounds.min_z = math.min(bounds.min_z, route_z)
		bounds.max_z = math.max(bounds.max_z, route_z)
	}
	return bounds
}

terrain_density_cave_edge_route_bounds_fill :: proc(
	region: ^biomes.GenerationRegion,
	bounds: []TerrainCaveEdgeRouteBounds,
) {
	log.assertf(
		len(bounds) >= int(region.cave_network_edge_count),
		"cave edge route bounds buffer too small: required=%d got=%d",
		region.cave_network_edge_count,
		len(bounds),
	)
	when TERRAIN_CAVE_FIELD_NETWORK_ROUTE_BOUNDS_ENABLED {
		for i := u32(0); i < region.cave_network_edge_count; i += 1 {
			bounds[i] = terrain_density_cave_edge_route_bounds(region.cave_network_edges[i])
		}
	}
}

terrain_density_cave_edge_route_bounds_may_reach_sample :: proc(
	bounds: TerrainCaveEdgeRouteBounds,
	edge: biomes.CaveNetworkEdge,
	world_x, world_y, world_z, radius: f32,
) -> bool {
	route_radius := math.max(f32(3), edge.radius_blocks)
	reach_margin := radius + route_radius + TERRAIN_CAVE_FIELD_NETWORK_BRIDGE_MARGIN_BLOCKS
	return(
		world_x >= bounds.min_x - reach_margin &&
		world_x <= bounds.max_x + reach_margin &&
		world_y >= bounds.min_y - reach_margin &&
		world_y <= bounds.max_y + reach_margin &&
		world_z >= bounds.min_z - reach_margin &&
		world_z <= bounds.max_z + reach_margin \
	)
}

terrain_density_cave_field_path_direction :: proc(
	field_sample: TerrainCaveFieldSample,
	network_sample: TerrainCaveFieldNetworkSample,
) -> (
	dir_x, dir_y, dir_z: f32,
	route_follow: bool,
) {
	route_len_sq :=
		network_sample.route_dir_x * network_sample.route_dir_x +
		network_sample.route_dir_y * network_sample.route_dir_y +
		network_sample.route_dir_z * network_sample.route_dir_z
	route_xz_len_sq :=
		network_sample.route_dir_x * network_sample.route_dir_x +
		network_sample.route_dir_z * network_sample.route_dir_z
	if network_sample.found && route_len_sq > 0.001 && route_xz_len_sq > 0.001 {
		route_xz_len := math.sqrt_f32(route_xz_len_sq)
		route_len := math.sqrt_f32(route_len_sq)
		dir_x = network_sample.route_dir_x / route_xz_len
		dir_y =
			math.clamp(network_sample.route_dir_y / route_len, f32(-0.85), f32(0.85)) *
			TERRAIN_CAVE_FIELD_PATH_ROUTE_VERTICAL_SCALE
		dir_z = network_sample.route_dir_z / route_xz_len
		route_follow = true
		return
	}

	if field_sample.path_axis_x {
		return 1, 0, 0, false
	}
	return 0, 0, 1, false
}

terrain_density_cave_field_network_sample_note :: proc(
	sample: ^TerrainCaveFieldNetworkSample,
	distance,
	route_radius,
	nearest_x,
	nearest_y,
	nearest_z,
	route_dir_x,
	route_dir_y,
	route_dir_z: f32,
) {
	if !sample.found || distance < sample.distance {
		sample.found = true
		sample.distance = distance
		sample.route_radius = route_radius
		sample.nearest_x = nearest_x
		sample.nearest_y = nearest_y
		sample.nearest_z = nearest_z
		sample.route_dir_x = route_dir_x
		sample.route_dir_y = route_dir_y
		sample.route_dir_z = route_dir_z
	}
}

terrain_density_cave_node_connectivity :: proc(
	region: ^biomes.GenerationRegion,
	node: biomes.CaveNetworkNode,
) -> TerrainCaveNodeConnectivity {
	connectivity := TerrainCaveNodeConnectivity {
		nearest_route_distance = biomes.BIOME_FIELD_NO_DISTANCE,
	}

	for i := u32(0); i < region.cave_network_edge_count; i += 1 {
		edge := region.cave_network_edges[i]
		if edge.from_node_id == node.id || edge.to_node_id == node.id {
			connectivity.has_edge = true
			continue
		}
		px, py, pz, distance := terrain_density_closest_segment_point_3(
			node.x,
			node.y,
			node.z,
			edge.from_x,
			edge.from_y,
			edge.from_z,
			edge.bend_x,
			edge.bend_y,
			edge.bend_z,
		)
		terrain_density_cave_node_connectivity_note_route(
			&connectivity,
			distance,
			math.max(f32(3), edge.radius_blocks),
			px,
			py,
			pz,
		)
		px, py, pz, distance = terrain_density_closest_segment_point_3(
			node.x,
			node.y,
			node.z,
			edge.bend_x,
			edge.bend_y,
			edge.bend_z,
			edge.to_x,
			edge.to_y,
			edge.to_z,
		)
		terrain_density_cave_node_connectivity_note_route(
			&connectivity,
			distance,
			math.max(f32(3), edge.radius_blocks),
			px,
			py,
			pz,
		)
	}

	for i := u32(0); i < region.cave_anchor_count; i += 1 {
		anchor := region.cave_anchors[i]
		if anchor.feature_id == node.id || anchor.target_feature_id == node.id {
			connectivity.has_anchor = true
			break
		}
	}

	requires_connection :=
		node.role == .Major_Region ||
		node.role == .Water_Linked_Region ||
		node.role == .Connector ||
		connectivity.has_anchor
	large_chamber := node.radius_blocks >= TERRAIN_CAVE_NODE_ISOLATED_CULL_RADIUS_BLOCKS
	connectivity.should_bridge =
		!connectivity.has_edge &&
		connectivity.nearest_route_found &&
		(requires_connection || large_chamber) &&
		connectivity.nearest_route_distance <= TERRAIN_CAVE_NODE_BRIDGE_MAX_DISTANCE_BLOCKS
	connectivity.should_carve = connectivity.has_edge || connectivity.should_bridge
	if node.role == .Sealed_Secret && !connectivity.has_edge && !connectivity.has_anchor {
		connectivity.should_carve = false
		connectivity.should_bridge = false
	}
	return connectivity
}

terrain_density_cave_node_connectivity_note_route :: proc(
	connectivity: ^TerrainCaveNodeConnectivity,
	distance, route_radius, nearest_x, nearest_y, nearest_z: f32,
) {
	if !connectivity.nearest_route_found || distance < connectivity.nearest_route_distance {
		connectivity.nearest_route_found = true
		connectivity.nearest_route_distance = distance
		connectivity.nearest_route_radius = route_radius
		connectivity.nearest_x = nearest_x
		connectivity.nearest_y = nearest_y
		connectivity.nearest_z = nearest_z
	}
}

terrain_density_cave_node_base_radii :: proc(
	node: biomes.CaveNetworkNode,
) -> (
	radius_x, radius_y, radius_z: f32,
) {
	radius_x = node.radius_blocks
	radius_y = node.radius_blocks * 0.85
	radius_z = node.radius_blocks

	#partial switch node.kind {
	case .Biome_Hub:
		radius_x *= 1.35
		radius_y *= 0.78
		radius_z *= 1.20
	case .Underground_Lake:
		radius_x *= 1.45
		radius_y *= 0.55
		radius_z *= 1.35
	case .River_Junction:
		radius_x *= 1.15
		radius_y *= 0.72
		radius_z *= 1.15
	case .Vertical_Shaft:
		radius_x *= 0.55
		radius_y *= 1.75
		radius_z *= 0.55
	case .Geode_Chamber:
		radius_x *= 1.05
		radius_y *= 1.05
		radius_z *= 1.05
	case .Magma_Pocket:
		radius_x *= 1.15
		radius_y *= 0.70
		radius_z *= 1.15
	}
	return
}

terrain_density_cave_node_profile_radii :: proc(
	node: biomes.CaveNetworkNode,
) -> (
	room_radius_x, room_radius_y, room_radius_z: f32,
	uses_profile_room: bool,
) {
	uses_profile_room = terrain_density_cave_node_uses_profile_room(node)
	if !uses_profile_room {
		return
	}

	radius_x, radius_y, radius_z := terrain_density_cave_node_base_radii(node)
	radius_scale := f32(1)
	max_radius_xz := TERRAIN_CAVE_NODE_PROFILE_ROOM_MAJOR_MAX_XZ
	max_radius_y := TERRAIN_CAVE_NODE_PROFILE_ROOM_MAJOR_MAX_Y
	if !node.major_region {
		radius_scale = TERRAIN_CAVE_NODE_PROFILE_ROOM_MINOR_SCALE
		max_radius_xz = TERRAIN_CAVE_NODE_PROFILE_ROOM_MINOR_MAX_XZ
		max_radius_y = TERRAIN_CAVE_NODE_PROFILE_ROOM_MINOR_MAX_Y
	}
	room_radius_x = math.min(radius_x * radius_scale, max_radius_xz)
	room_radius_y = math.min(radius_y * radius_scale, max_radius_y)
	room_radius_z = math.min(radius_z * radius_scale, max_radius_xz)
	return
}

terrain_density_cave_node_chunk_may_intersect :: proc(
	node: biomes.CaveNetworkNode,
	chunk_origin: world_async.BlockCoord,
) -> bool {
	room_radius_x, room_radius_y, room_radius_z, uses_profile_room :=
		terrain_density_cave_node_profile_radii(node)
	if uses_profile_room {
		extent_x := room_radius_x * f32(1.30) + 6
		extent_y := room_radius_y * f32(1.30) + 6
		extent_z := room_radius_z * f32(1.30) + 6
		if node.major_region {
			room_radius_xz := math.max(room_radius_x, room_radius_z)
			major_extent_xz := room_radius_xz * f32(4.0) + 48
			extent_x = math.max(extent_x, major_extent_xz)
			extent_y = math.max(extent_y, room_radius_y * f32(3.20) + 42)
			extent_z = math.max(extent_z, major_extent_xz)
		}
		return terrain_density_chunk_aabb_intersects(
			chunk_origin,
			node.x - extent_x,
			node.x + extent_x,
			node.y - extent_y,
			node.y + extent_y,
			node.z - extent_z,
			node.z + extent_z,
		)
	}

	radius_x, radius_y, radius_z := terrain_density_cave_node_base_radii(node)
	extent_x := radius_x * f32(1.22) + 6
	extent_y := radius_y * f32(1.22) + 6
	extent_z := radius_z * f32(1.22) + 6
	return terrain_density_chunk_aabb_intersects(
		chunk_origin,
		node.x - extent_x,
		node.x + extent_x,
		node.y - extent_y,
		node.y + extent_y,
		node.z - extent_z,
		node.z + extent_z,
	)
}

terrain_density_cave_edge_feature_radius :: proc(edge: biomes.CaveNetworkEdge) -> f32 {
	radius := edge.radius_blocks
	radius_cap := TERRAIN_CAVE_EDGE_RADIUS_CAP_DEFAULT_BLOCKS
	#partial switch edge.kind {
	case .Canyon:
		radius *= 1.18
		radius_cap = TERRAIN_CAVE_EDGE_RADIUS_CAP_CANYON_BLOCKS
	case .Fracture:
		radius *= 0.72
		radius_cap = TERRAIN_CAVE_EDGE_RADIUS_CAP_FRACTURE_BLOCKS
	case .Flooded_Passage:
		radius *= 1.10
		radius_cap = TERRAIN_CAVE_EDGE_RADIUS_CAP_FLOODED_BLOCKS
	case .Vertical_Shaft:
		radius *= 0.92
		radius_cap = TERRAIN_CAVE_EDGE_RADIUS_CAP_VERTICAL_BLOCKS
	case .Collapsed_Corridor:
		radius *= 0.82
		radius_cap = TERRAIN_CAVE_EDGE_RADIUS_CAP_COLLAPSED_BLOCKS
	case .Worm_Path:
		radius *= 0.92
		radius_cap = TERRAIN_CAVE_EDGE_RADIUS_CAP_WORM_BLOCKS
	}
	if edge.regional_seam_connection && edge.kind == .Canyon {
		radius *= TERRAIN_CAVE_EDGE_SEAM_BASE_RADIUS_SCALE
		radius_cap = math.max(radius_cap, TERRAIN_CAVE_EDGE_RADIUS_CAP_SEAM_BLOCKS)
	}
	return terrain_density_cave_passage_radius_soft_cap(radius, radius_cap)
}

terrain_density_cave_edge_core_radius :: proc(
	edge: biomes.CaveNetworkEdge,
	feature_radius: f32,
) -> f32 {
	core_radius := math.max(
		f32(2.25),
		feature_radius * terrain_density_cave_edge_core_radius_scale(edge.kind),
	)
	if edge.regional_seam_connection && edge.kind == .Canyon {
		core_radius *= TERRAIN_CAVE_EDGE_SEAM_CORE_RADIUS_SCALE
	}
	return core_radius
}

terrain_density_cave_edge_core_segment_radius :: proc(
	edge: biomes.CaveNetworkEdge,
	core_radius, segment_radius_scale, t, mid_t: f32,
) -> f32 {
	segment_radius :=
		core_radius *
		biomes.regional_terrain_field_lerp(f32(1.03), f32(0.94), t) *
		terrain_density_cave_edge_radius_modulation(edge, mid_t) *
		terrain_density_cave_edge_seam_radius_scale(edge, mid_t) *
		terrain_density_cave_edge_approach_radius_scale(edge.kind, mid_t)
	return math.max(f32(1), segment_radius) * segment_radius_scale
}

terrain_density_cave_edge_core_segment_mask :: proc(
	edge: biomes.CaveNetworkEdge,
	chunk_origin: world_async.BlockCoord,
) -> u64 {
	feature_radius := terrain_density_cave_edge_feature_radius(edge)
	core_radius := terrain_density_cave_edge_core_radius(edge, feature_radius)
	segment_radius_scale, _ := terrain_density_cave_passage_segment_setup(edge.kind)
	mask: u64

	prev_x, prev_y, prev_z := terrain_density_cave_edge_route_point(edge, 0)
	for segment_index := u32(1);
	    segment_index <= TERRAIN_CAVE_EDGE_ROUTE_SEGMENT_COUNT;
	    segment_index += 1 {
		t := f32(segment_index) / f32(TERRAIN_CAVE_EDGE_ROUTE_SEGMENT_COUNT)
		next_x, next_y, next_z := terrain_density_cave_edge_route_point(edge, t)
		mid_t := (f32(segment_index) - 0.5) / f32(TERRAIN_CAVE_EDGE_ROUTE_SEGMENT_COUNT)
		segment_radius := terrain_density_cave_edge_core_segment_radius(
			edge,
			core_radius,
			segment_radius_scale,
			t,
			mid_t,
		)
		_, _, intersects := terrain_density_segment_chunk_overlap(
			chunk_origin,
			prev_x,
			prev_y,
			prev_z,
			next_x,
			next_y,
			next_z,
			math.max(f32(1), segment_radius) * 1.45 + 2,
		)
		if intersects {
			mask |= u64(1) << (segment_index - 1)
		}
		prev_x = next_x
		prev_y = next_y
		prev_z = next_z
	}
	return mask
}

terrain_density_cave_edge_chunk_may_intersect :: proc(
	edge: biomes.CaveNetworkEdge,
	chunk_origin: world_async.BlockCoord,
) -> bool {
	route_x, route_y, route_z := terrain_density_cave_edge_route_point(edge, 0)
	min_x, max_x := route_x, route_x
	min_y, max_y := route_y, route_y
	min_z, max_z := route_z, route_z
	for segment_index := u32(1);
	    segment_index <= TERRAIN_CAVE_EDGE_ROUTE_SEGMENT_COUNT;
	    segment_index += 1 {
		t := f32(segment_index) / f32(TERRAIN_CAVE_EDGE_ROUTE_SEGMENT_COUNT)
		route_x, route_y, route_z = terrain_density_cave_edge_route_point(edge, t)
		min_x = math.min(min_x, route_x)
		max_x = math.max(max_x, route_x)
		min_y = math.min(min_y, route_y)
		max_y = math.max(max_y, route_y)
		min_z = math.min(min_z, route_z)
		max_z = math.max(max_z, route_z)
	}

	feature_radius := terrain_density_cave_edge_feature_radius(edge)
	margin := math.max(
		feature_radius * TERRAIN_CAVE_EDGE_CHUNK_INTERSECT_FEATURE_RADIUS_SCALE +
		TERRAIN_CAVE_EDGE_CHUNK_INTERSECT_FEATURE_PADDING_BLOCKS,
		edge.radius_blocks * f32(1.35) + TERRAIN_CAVE_EDGE_CHUNK_INTERSECT_BASE_PADDING_BLOCKS,
	)
	if edge.regional_seam_connection && edge.kind == .Canyon {
		margin = math.max(margin, TERRAIN_CAVE_EDGE_CHUNK_INTERSECT_SEAM_PADDING_BLOCKS)
	}
	return terrain_density_chunk_aabb_intersects(
		chunk_origin,
		min_x - margin,
		max_x + margin,
		min_y - margin,
		max_y + margin,
		min_z - margin,
		max_z + margin,
	)
}

terrain_density_cave_network_apply :: proc(
	view: ^world_async.ChunkVoxelView,
	region: ^biomes.GenerationRegion,
	chunk_origin: world_async.BlockCoord,
	columns: []TerrainBiomeColumn,
	wall_buffer: ^TerrainCaveWallMaterialBuffer = nil,
) {
	profile_stage_start: time.Tick
	when TERRAIN_GENERATION_PROFILE_PHASES {
		profile_stage_start = time.tick_now()
	}
	when !TERRAIN_GENERATION_PROFILE_PHASES {
		_ = profile_stage_start
	}
	log.assertf(
		len(columns) == CHUNK_BLOCK_LENGTH * CHUNK_BLOCK_LENGTH,
		"terrain density column target count mismatch: %d",
		len(columns),
	)

	chunk_query := biomes.GenerationRegionQuery{}
	when TERRAIN_CAVE_NETWORK_CHUNK_QUERY_ENABLED {
		chunk_query = terrain_density_cave_network_chunk_query_make(chunk_origin)
	}

	node_connectivity: [biomes.GENERATION_REGION_CAVE_NETWORK_NODE_CAPACITY]TerrainCaveNodeConnectivity
	for i := u32(0); i < region.cave_network_node_count; i += 1 {
		node_connectivity[i] = terrain_density_cave_node_connectivity(
			region,
			region.cave_network_nodes[i],
		)
	}

	chunk_features: TerrainCaveChunkFeatureBucket
	terrain_density_cave_chunk_feature_bucket_build(
		&chunk_features,
		region,
		chunk_origin,
		chunk_query,
		&node_connectivity,
	)
	when TERRAIN_GENERATION_PROFILE_PHASES {
		terrain_generation_profile_stats.network_connectivity += time.tick_since(
			profile_stage_start,
		)
		profile_stage_start = time.tick_now()
	}

	carveable_row_mask: TerrainCarveableRowMask
	terrain_density_carveable_row_mask_build(&carveable_row_mask, view)

	for bucket_i := u32(0); bucket_i < chunk_features.edge_count; bucket_i += 1 {
		i := chunk_features.edge_indices[bucket_i]
		edge := region.cave_network_edges[i]
		terrain_density_carve_cave_edge(
			view,
			region,
			chunk_origin,
			columns,
			edge,
			wall_buffer,
			chunk_features.edge_core_segment_masks[bucket_i],
			&carveable_row_mask,
		)
	}
	when TERRAIN_GENERATION_PROFILE_PHASES {
		terrain_generation_profile_stats.network_edges += time.tick_since(profile_stage_start)
		profile_stage_start = time.tick_now()
	}

	for bucket_i := u32(0); bucket_i < chunk_features.node_count; bucket_i += 1 {
		i := chunk_features.node_indices[bucket_i]
		node := region.cave_network_nodes[i]
		terrain_density_carve_cave_node(view, region.key, chunk_origin, columns, node, wall_buffer)
		node_portal_profile_start: time.Tick
		when TERRAIN_GENERATION_PROFILE_PHASES {
			node_portal_profile_start = time.tick_now()
		}
		when !TERRAIN_GENERATION_PROFILE_PHASES {
			_ = node_portal_profile_start
		}
		when !TERRAIN_CAVE_FAST_SKELETON {
			terrain_density_carve_cave_node_edge_portals(view, region, chunk_origin, columns, node)
		}
		when TERRAIN_GENERATION_PROFILE_PHASES {
			terrain_generation_profile_stats.node_portals += time.tick_since(
				node_portal_profile_start,
			)
		}
	}
	when TERRAIN_GENERATION_PROFILE_PHASES {
		terrain_generation_profile_stats.network_nodes += time.tick_since(profile_stage_start)
		profile_stage_start = time.tick_now()
	}

	for bucket_i := u32(0); bucket_i < chunk_features.bridge_node_count; bucket_i += 1 {
		i := chunk_features.bridge_node_indices[bucket_i]
		node := region.cave_network_nodes[i]
		connectivity := node_connectivity[i]
		bridge_shape := terrain_density_cave_passage_shape(.Collapsed_Corridor)
		if node.kind == .Geode_Chamber || node.biome_id == .Crystal_Geode_Network {
			bridge_shape = terrain_density_cave_passage_shape(.Fracture)
		} else if node.biome_id == .Fungal_Vaults {
			bridge_shape = terrain_density_cave_passage_shape(.Worm_Path)
			bridge_shape.radius_y_scale = math.min(bridge_shape.radius_y_scale, f32(0.72))
		}
		terrain_density_cave_passage_shape_apply_biome(&bridge_shape, node.biome_id)
		bridge_radius := math.max(
			f32(2),
			math.min(
				node.connection_radius_blocks,
				connectivity.nearest_route_radius * f32(0.88),
			) *
			TERRAIN_CAVE_NODE_BRIDGE_RADIUS_SCALE,
		)
		terrain_density_carve_rough_segment_shaped(
			view,
			region.key,
			chunk_origin,
			columns,
			node.x,
			node.y,
			node.z,
			connectivity.nearest_x,
			connectivity.nearest_y,
			connectivity.nearest_z,
			bridge_radius,
			bridge_shape,
			TERRAIN_CAVE_BRANCH_SALT,
			node.biome_id,
			false,
			wall_buffer,
		)
	}
	when TERRAIN_GENERATION_PROFILE_PHASES {
		terrain_generation_profile_stats.network_bridges += time.tick_since(profile_stage_start)
		profile_stage_start = time.tick_now()
	}

	for bucket_i := u32(0); bucket_i < chunk_features.anchor_count; bucket_i += 1 {
		i := chunk_features.anchor_indices[bucket_i]
		anchor := region.cave_anchors[i]
		terrain_density_cave_anchor_apply(
			view,
			region,
			chunk_origin,
			columns,
			anchor,
			&node_connectivity,
			wall_buffer,
		)
	}
	when TERRAIN_GENERATION_PROFILE_PHASES {
		terrain_generation_profile_stats.network_anchors += time.tick_since(profile_stage_start)
	}
}

terrain_density_cave_proxy_anchor_kind_enabled :: proc(kind: biomes.CaveAnchorKind) -> bool {
	#partial switch kind {
	case .Cave_Mouth, .Sinkhole, .Ravine_Breach, .Vertical_Shaft:
		return true
	}
	return false
}

terrain_density_cave_proxy_anchor_chunk_may_intersect :: proc(
	anchor: biomes.CaveAnchor,
	node: biomes.CaveNetworkNode,
	chunk_origin: world_async.BlockCoord,
	link_radius: f32,
) -> bool {
	margin := math.max(
		anchor.influence_radius_blocks * f32(3.4),
		math.max(link_radius * f32(3.0), node.connection_radius_blocks * f32(2.0)),
	)
	return terrain_density_chunk_aabb_intersects(
		chunk_origin,
		math.min(anchor.x, node.x) - margin,
		math.max(anchor.x, node.x) + margin,
		math.min(anchor.y, node.y) - margin,
		math.max(anchor.y, node.y) + margin,
		math.min(anchor.z, node.z) - margin,
		math.max(anchor.z, node.z) + margin,
	)
}

terrain_density_proxy_carve_local_block :: proc(
	view: ^world_async.ChunkVoxelView,
	local_x, local_y, local_z: i32,
) -> bool {
	when TERRAIN_GENERATION_PROFILE_PHASES {
		terrain_generation_profile_stats.carve_attempts += 1
	}
	if !terrain_density_local_block_can_carve(view, local_x, local_y, local_z) {
		return false
	}
	index := chunk_block_index(u32(local_x), u32(local_y), u32(local_z))
	view.blocks.occupancy[index] = .Empty
	view.blocks.material_id[index] = world_async.BlockMaterialID(0)
	when TERRAIN_GENERATION_PROFILE_PHASES {
		terrain_generation_profile_stats.carve_successes += 1
	}
	return true
}

terrain_density_proxy_carve_ellipsoid :: proc(
	view: ^world_async.ChunkVoxelView,
	chunk_origin: world_async.BlockCoord,
	center_x, center_y, center_z, radius_x, radius_y, radius_z: f32,
) {
	local_min_x, local_max_x, local_min_y, local_max_y, local_min_z, local_max_z, intersects :=
		terrain_density_carve_bounds_from_extents(
			chunk_origin,
			center_x - radius_x,
			center_x + radius_x,
			center_y - radius_y,
			center_y + radius_y,
			center_z - radius_z,
			center_z + radius_z,
		)
	if !intersects {
		return
	}

	for z := local_min_z; z <= local_max_z; z += 1 {
		world_z := f32(chunk_origin.z + z) + 0.5
		z_unit := (world_z - center_z) / radius_z
		z_shape := z_unit * z_unit
		for y := local_min_y; y <= local_max_y; y += 1 {
			world_y := f32(chunk_origin.y + y) + 0.5
			y_unit := (world_y - center_y) / radius_y
			row_shape := z_shape + y_unit * y_unit
			row_min_x, row_max_x, row_intersects := terrain_density_ellipsoid_row_x_bounds(
				chunk_origin,
				local_min_x,
				local_max_x,
				center_x,
				radius_x,
				row_shape,
				1,
			)
			if !row_intersects {
				continue
			}
			for x := row_min_x; x <= row_max_x; x += 1 {
				world_x := f32(chunk_origin.x + x) + 0.5
				x_unit := (world_x - center_x) / radius_x
				if row_shape + x_unit * x_unit <= 1 {
					terrain_density_proxy_carve_local_block(view, x, y, z)
				}
			}
		}
	}
}

terrain_density_proxy_carve_segment :: proc(
	view: ^world_async.ChunkVoxelView,
	chunk_origin: world_async.BlockCoord,
	from_x, from_y, from_z, to_x, to_y, to_z, radius: f32,
) {
	dx := to_x - from_x
	dy := to_y - from_y
	dz := to_z - from_z
	length_sq := dx * dx + dy * dy + dz * dz
	if length_sq <= 0.0001 {
		terrain_density_proxy_carve_ellipsoid(
			view,
			chunk_origin,
			from_x,
			from_y,
			from_z,
			radius,
			radius,
			radius,
		)
		return
	}

	length := math.sqrt_f32(length_sq)
	tangent_x := dx / length
	tangent_y := dy / length
	tangent_z := dz / length
	local_min_x, local_max_x, local_min_y, local_max_y, local_min_z, local_max_z, intersects :=
		terrain_density_carve_bounds_from_extents(
			chunk_origin,
			math.min(from_x, to_x) - radius,
			math.max(from_x, to_x) + radius,
			math.min(from_y, to_y) - radius,
			math.max(from_y, to_y) + radius,
			math.min(from_z, to_z) - radius,
			math.max(from_z, to_z) + radius,
		)
	if !intersects {
		return
	}

	radius_sq := radius * radius
	for z := local_min_z; z <= local_max_z; z += 1 {
		world_z := f32(chunk_origin.z + z) + 0.5
		for y := local_min_y; y <= local_max_y; y += 1 {
			world_y := f32(chunk_origin.y + y) + 0.5
			row_min_x, row_max_x, row_intersects := terrain_density_segment_capsule_row_x_bounds(
				chunk_origin,
				local_min_x,
				local_max_x,
				world_y,
				world_z,
				from_x,
				from_y,
				from_z,
				tangent_x,
				tangent_y,
				tangent_z,
				radius,
			)
			if !row_intersects {
				continue
			}
			for x := row_min_x; x <= row_max_x; x += 1 {
				world_x := f32(chunk_origin.x + x) + 0.5
				rel_x := world_x - from_x
				rel_y := world_y - from_y
				rel_z := world_z - from_z
				t := math.clamp((rel_x * dx + rel_y * dy + rel_z * dz) / length_sq, f32(0), f32(1))
				near_x := from_x + dx * t
				near_y := from_y + dy * t
				near_z := from_z + dz * t
				dist_x := world_x - near_x
				dist_y := world_y - near_y
				dist_z := world_z - near_z
				if dist_x * dist_x + dist_y * dist_y + dist_z * dist_z <= radius_sq {
					terrain_density_proxy_carve_local_block(view, x, y, z)
				}
			}
		}
	}
}

terrain_density_cave_proxy_entrance_carve :: proc(
	view: ^world_async.ChunkVoxelView,
	chunk_origin: world_async.BlockCoord,
	anchor: biomes.CaveAnchor,
	node: biomes.CaveNetworkNode,
	link_radius: f32,
) {
	opening_radius := math.max(f32(4), anchor.influence_radius_blocks)
	#partial switch anchor.kind {
	case .Cave_Mouth, .Ravine_Breach:
		terrain_density_proxy_carve_ellipsoid(
			view,
			chunk_origin,
			anchor.x,
			anchor.y - opening_radius * 0.18,
			anchor.z,
			opening_radius * 1.18,
			math.max(f32(3), opening_radius * 0.58),
			opening_radius,
		)
		terrain_density_proxy_carve_segment(
			view,
			chunk_origin,
			anchor.x,
			anchor.y,
			anchor.z,
			node.x,
			node.y,
			node.z,
			math.max(f32(3), math.min(opening_radius * 0.42, link_radius)),
		)
	case .Sinkhole, .Vertical_Shaft:
		depth := math.max(opening_radius * 2.2, anchor.y - node.y)
		bottom_x := biomes.regional_terrain_field_lerp(anchor.x, node.x, f32(0.35))
		bottom_y := anchor.y - depth
		bottom_z := biomes.regional_terrain_field_lerp(anchor.z, node.z, f32(0.35))
		terrain_density_proxy_carve_ellipsoid(
			view,
			chunk_origin,
			anchor.x,
			anchor.y - opening_radius * 0.16,
			anchor.z,
			opening_radius * 1.10,
			opening_radius * 0.88,
			opening_radius * 1.10,
		)
		terrain_density_proxy_carve_segment(
			view,
			chunk_origin,
			anchor.x,
			anchor.y,
			anchor.z,
			bottom_x,
			bottom_y,
			bottom_z,
			math.max(f32(3), math.min(opening_radius * 0.54, link_radius)),
		)
	}
}

terrain_density_cave_proxy_anchors_apply :: proc(
	view: ^world_async.ChunkVoxelView,
	region: ^biomes.GenerationRegion,
	chunk_origin: world_async.BlockCoord,
	columns: []TerrainBiomeColumn,
	wall_buffer: ^TerrainCaveWallMaterialBuffer = nil,
) {
	log.assertf(
		len(columns) == CHUNK_BLOCK_LENGTH * CHUNK_BLOCK_LENGTH,
		"terrain density column target count mismatch: %d",
		len(columns),
	)

	chunk_query := biomes.GenerationRegionQuery{}
	when TERRAIN_CAVE_NETWORK_CHUNK_QUERY_ENABLED {
		chunk_query = terrain_density_cave_network_chunk_query_make(chunk_origin)
	}

	node_connectivity: [biomes.GENERATION_REGION_CAVE_NETWORK_NODE_CAPACITY]TerrainCaveNodeConnectivity
	for i := u32(0); i < region.cave_network_node_count; i += 1 {
		node_connectivity[i] = terrain_density_cave_node_connectivity(
			region,
			region.cave_network_nodes[i],
		)
	}

	for i := u32(0); i < region.cave_anchor_count; i += 1 {
		anchor := region.cave_anchors[i]
		if !terrain_density_cave_proxy_anchor_kind_enabled(anchor.kind) {
			continue
		}
		if !terrain_density_cave_network_query_contains_owner(chunk_query, anchor.owner) {
			continue
		}

		anchor_radius := math.max(f32(3), anchor.influence_radius_blocks * 0.55)
		node, node_index, found := terrain_density_cave_anchor_node_find(region, anchor)
		if !found {
			continue
		}
		if !node_connectivity[node_index].should_carve {
			continue
		}
		link_radius := math.max(
			f32(3),
			math.min(anchor_radius * 0.75, node.connection_radius_blocks),
		)
		if !terrain_density_cave_proxy_anchor_chunk_may_intersect(
			anchor,
			node,
			chunk_origin,
			link_radius,
		) {
			continue
		}

		terrain_density_cave_proxy_entrance_carve(view, chunk_origin, anchor, node, link_radius)
	}
	_ = wall_buffer
}

terrain_density_cave_chunk_feature_bucket_build :: proc(
	bucket: ^TerrainCaveChunkFeatureBucket,
	region: ^biomes.GenerationRegion,
	chunk_origin: world_async.BlockCoord,
	chunk_query: biomes.GenerationRegionQuery,
	node_connectivity: ^[biomes.GENERATION_REGION_CAVE_NETWORK_NODE_CAPACITY]TerrainCaveNodeConnectivity,
) {
	bucket^ = {}

	for i := u32(0); i < region.cave_network_node_count; i += 1 {
		node := region.cave_network_nodes[i]
		if !terrain_density_cave_network_query_contains_owner(chunk_query, node.owner) {
			continue
		}
		connectivity := node_connectivity[i]
		if connectivity.should_carve &&
		   terrain_density_cave_node_chunk_may_intersect(node, chunk_origin) {
			bucket.node_indices[bucket.node_count] = i
			bucket.node_count += 1
		}
		if connectivity.should_bridge {
			bucket.bridge_node_indices[bucket.bridge_node_count] = i
			bucket.bridge_node_count += 1
		}
	}

	for i := u32(0); i < region.cave_network_edge_count; i += 1 {
		edge := region.cave_network_edges[i]
		if !terrain_density_cave_network_query_contains_owner(chunk_query, edge.owner) {
			continue
		}
		if !terrain_density_cave_edge_chunk_may_intersect(edge, chunk_origin) {
			continue
		}
		bucket.edge_indices[bucket.edge_count] = i
		bucket.edge_core_segment_masks[bucket.edge_count] =
			terrain_density_cave_edge_core_segment_mask(edge, chunk_origin)
		bucket.edge_count += 1
	}

	for i := u32(0); i < region.cave_anchor_count; i += 1 {
		anchor := region.cave_anchors[i]
		if !terrain_density_cave_network_query_contains_owner(chunk_query, anchor.owner) {
			continue
		}
		bucket.anchor_indices[bucket.anchor_count] = i
		bucket.anchor_count += 1
	}
}

terrain_density_cave_network_chunk_query_make :: proc(
	chunk_origin: world_async.BlockCoord,
) -> biomes.GenerationRegionQuery {
	margins := biomes.GENERATION_REGION_DEFAULT_INFLUENCE_MARGINS
	margins.cave_network_blocks = TERRAIN_CAVE_NETWORK_CHUNK_QUERY_MARGIN_BLOCKS
	return biomes.generation_region_query_make(
		chunk_block_bounds_from_origin(chunk_origin),
		margins,
	)
}

terrain_density_cave_network_query_contains_owner :: proc(
	query: biomes.GenerationRegionQuery,
	owner: biomes.FeatureGridCoord3,
) -> bool {
	when TERRAIN_CAVE_NETWORK_CHUNK_QUERY_ENABLED {
		return biomes.generation_region_owner_range_contains_owner_3(
			query.cave_network_owner_range,
			owner,
		)
	}
	_ = query
	_ = owner
	return true
}

terrain_density_cave_anchor_apply :: proc(
	view: ^world_async.ChunkVoxelView,
	region: ^biomes.GenerationRegion,
	chunk_origin: world_async.BlockCoord,
	columns: []TerrainBiomeColumn,
	anchor: biomes.CaveAnchor,
	node_connectivity: ^[biomes.GENERATION_REGION_CAVE_NETWORK_NODE_CAPACITY]TerrainCaveNodeConnectivity,
	wall_buffer: ^TerrainCaveWallMaterialBuffer = nil,
) {
	anchor_radius := math.max(f32(3), anchor.influence_radius_blocks * 0.55)
	node, node_index, found := terrain_density_cave_anchor_node_find(region, anchor)
	if !found {
		return
	}

	link_radius := math.max(f32(3), math.min(anchor_radius * 0.75, node.connection_radius_blocks))
	if !node_connectivity[node_index].should_carve {
		return
	}
	terrain_density_carve_cave_entrance(
		view,
		region.key,
		chunk_origin,
		columns,
		anchor,
		node,
		link_radius,
		wall_buffer,
	)
}

terrain_density_cave_anchor_node_find :: proc(
	region: ^biomes.GenerationRegion,
	anchor: biomes.CaveAnchor,
) -> (
	node: biomes.CaveNetworkNode,
	node_index: u32,
	found: bool,
) {
	for i := u32(0); i < region.cave_network_node_count; i += 1 {
		candidate := region.cave_network_nodes[i]
		if candidate.id == anchor.feature_id {
			return candidate, i, true
		}
	}

	if !anchor.guaranteed_connection {
		return
	}

	#partial switch anchor.kind {
	case .Cave_Mouth,
	     .Sinkhole,
	     .Vertical_Shaft,
	     .Lakebed_Breach,
	     .Seabed_Breach,
	     .Underground_River_Source,
	     .Underground_River_Sink,
	     .Magma_Vent,
	     .Subterranean_Biome_Gateway:
		break
	case .Ravine_Breach:
		return
	}

	best_distance_sq := f32(192 * 192)
	for i := u32(0); i < region.cave_network_node_count; i += 1 {
		candidate := region.cave_network_nodes[i]
		dx := candidate.x - anchor.x
		dy := candidate.y - anchor.y
		dz := candidate.z - anchor.z
		distance_sq := dx * dx + dy * dy + dz * dz
		if distance_sq < best_distance_sq {
			best_distance_sq = distance_sq
			node = candidate
			node_index = i
			found = true
		}
	}
	return
}

terrain_density_carve_cave_node :: proc(
	view: ^world_async.ChunkVoxelView,
	key: biomes.FeatureGridKey,
	chunk_origin: world_async.BlockCoord,
	columns: []TerrainBiomeColumn,
	node: biomes.CaveNetworkNode,
	wall_buffer: ^TerrainCaveWallMaterialBuffer = nil,
) {
	radius_x, radius_y, radius_z := terrain_density_cave_node_base_radii(node)

	if terrain_density_cave_node_uses_profile_room(node) {
		room_radius_x, room_radius_y, room_radius_z, _ := terrain_density_cave_node_profile_radii(
			node,
		)
		profile_stage_start: time.Tick
		when TERRAIN_GENERATION_PROFILE_PHASES {
			profile_stage_start = time.tick_now()
		}
		when !TERRAIN_GENERATION_PROFILE_PHASES {
			_ = profile_stage_start
		}
		terrain_density_carve_cave_room(
			view,
			key,
			chunk_origin,
			columns,
			node.x,
			node.y,
			node.z,
			room_radius_x,
			room_radius_y,
			room_radius_z,
			node.kind,
			node.biome_id,
			wall_buffer,
		)
		when TERRAIN_GENERATION_PROFILE_PHASES {
			terrain_generation_profile_stats.node_rooms += time.tick_since(profile_stage_start)
			profile_stage_start = time.tick_now()
		}
		if node.major_region {
			when !TERRAIN_CAVE_FAST_SKELETON {
				terrain_density_carve_cave_node_major_room_perimeter_field(
					view,
					key,
					chunk_origin,
					columns,
					node,
					room_radius_x,
					room_radius_y,
					room_radius_z,
					wall_buffer,
				)
			}
			when TERRAIN_GENERATION_PROFILE_PHASES {
				terrain_generation_profile_stats.node_perimeter += time.tick_since(
					profile_stage_start,
				)
				profile_stage_start = time.tick_now()
			}
			when !TERRAIN_CAVE_FAST_SKELETON {
				terrain_density_carve_cave_node_macro_satellites(
					view,
					key,
					chunk_origin,
					columns,
					node,
					room_radius_x,
					room_radius_y,
					room_radius_z,
					wall_buffer,
				)
			}
			when TERRAIN_GENERATION_PROFILE_PHASES {
				terrain_generation_profile_stats.node_satellites += time.tick_since(
					profile_stage_start,
				)
			}
		}
		return
	}

	profile_stage_start: time.Tick
	when TERRAIN_GENERATION_PROFILE_PHASES {
		profile_stage_start = time.tick_now()
	}
	when !TERRAIN_GENERATION_PROFILE_PHASES {
		_ = profile_stage_start
	}
	terrain_density_carve_rough_ellipsoid(
		view,
		key,
		chunk_origin,
		columns,
		node.x,
		node.y,
		node.z,
		radius_x,
		radius_y,
		radius_z,
		TERRAIN_CAVE_ROUGHNESS_SALT,
		node.biome_id,
		false,
		wall_buffer,
	)
	when TERRAIN_GENERATION_PROFILE_PHASES {
		terrain_generation_profile_stats.node_rooms += time.tick_since(profile_stage_start)
	}
}

terrain_density_cave_node_uses_profile_room :: proc(node: biomes.CaveNetworkNode) -> bool {
	if node.major_region {
		return true
	}
	if node.radius_blocks < TERRAIN_CAVE_NODE_PROFILE_ROOM_MIN_RADIUS_BLOCKS {
		return false
	}
	return(
		node.role == .Water_Linked_Region ||
		node.role == .Resource_Chamber ||
		node.kind == .Underground_Lake ||
		node.kind == .Geode_Chamber ||
		node.kind == .Magma_Pocket ||
		(node.kind == .Chamber &&
				node.radius_blocks >= TERRAIN_CAVE_NODE_ISOLATED_CULL_RADIUS_BLOCKS) \
	)
}

terrain_density_cave_node_edge_portals_enabled :: proc(node: biomes.CaveNetworkNode) -> bool {
	if !node.major_region || node.kind == .Vertical_Shaft {
		return false
	}
	return terrain_density_cave_node_uses_profile_room(node)
}

terrain_density_carve_cave_node_edge_portals :: proc(
	view: ^world_async.ChunkVoxelView,
	region: ^biomes.GenerationRegion,
	chunk_origin: world_async.BlockCoord,
	columns: []TerrainBiomeColumn,
	node: biomes.CaveNetworkNode,
) {
	if !terrain_density_cave_node_edge_portals_enabled(node) {
		return
	}

	room_radius_x, room_radius_y, room_radius_z, _ := terrain_density_cave_node_profile_radii(node)
	room_radius_xz := math.min(room_radius_x, room_radius_z)

	portal_count := u32(0)
	for i := u32(0);
	    i < region.cave_network_edge_count &&
	    portal_count < TERRAIN_CAVE_NODE_EDGE_PORTAL_MAX_COUNT;
	    i += 1 {
		edge := region.cave_network_edges[i]
		from_endpoint := edge.from_node_id == node.id
		to_endpoint := edge.to_node_id == node.id
		if !from_endpoint && !to_endpoint {
			continue
		}
		if edge.kind == .Vertical_Shaft {
			continue
		}
		edge_radius := math.max(f32(3), edge.radius_blocks)
		if !edge.guaranteed_connection &&
		   edge_radius < TERRAIN_CAVE_FIELD_NETWORK_BRIDGE_MIN_RADIUS {
			continue
		}

		route_t := TERRAIN_CAVE_NODE_EDGE_PORTAL_ROUTE_T
		if to_endpoint {
			route_t = 1.0 - TERRAIN_CAVE_NODE_EDGE_PORTAL_ROUTE_T
		}
		route_x, route_y, route_z := terrain_density_cave_edge_route_point(edge, route_t)
		dir_x := route_x - node.x
		dir_y := route_y - node.y
		dir_z := route_z - node.z
		dir_len := math.sqrt_f32(dir_x * dir_x + dir_y * dir_y + dir_z * dir_z)
		if dir_len <= 0.001 {
			continue
		}
		dir_x /= dir_len
		dir_y /= dir_len
		dir_z /= dir_len

		horizontal_len := math.sqrt_f32(dir_x * dir_x + dir_z * dir_z)
		side_x := f32(1)
		side_z := f32(0)
		if horizontal_len > 0.001 {
			side_x = -dir_z / horizontal_len
			side_z = dir_x / horizontal_len
		}

		hash := biomes.feature_grid_hash_combine(u64(edge.id), TERRAIN_CAVE_ROOM_DETAIL_SALT)
		hash = biomes.feature_grid_hash_combine(hash, u64(node.id))
		hash = biomes.feature_grid_hash_combine(hash, u64(portal_count + 1217))
		side_sign := f32(1)
		if biomes.feature_grid_signed_unit_f32(hash, TERRAIN_CAVE_BRANCH_SALT) < 0 {
			side_sign = -1
		}
		vertical_sign := f32(1)
		if biomes.feature_grid_signed_unit_f32(hash, TERRAIN_CAVE_PASSAGE_RIB_SALT) < 0 {
			vertical_sign = -1
		}

		portal_radius := math.clamp(
			room_radius_xz *
			TERRAIN_CAVE_NODE_EDGE_PORTAL_RADIUS_SCALE *
			biomes.regional_terrain_field_lerp(
				f32(0.78),
				f32(1.16),
				biomes.feature_grid_unit_f32(hash, TERRAIN_CAVE_FIELD_CHAMBER_SALT),
			),
			TERRAIN_CAVE_NODE_EDGE_PORTAL_RADIUS_MIN_BLOCKS,
			TERRAIN_CAVE_NODE_EDGE_PORTAL_RADIUS_MAX_BLOCKS,
		)
		side_offset :=
			portal_radius *
			TERRAIN_CAVE_NODE_EDGE_PORTAL_SIDE_OFFSET_SCALE *
			side_sign *
			biomes.regional_terrain_field_lerp(
				f32(0.45),
				f32(1.10),
				biomes.feature_grid_unit_f32(hash, TERRAIN_CAVE_FIELD_DETAIL_SALT),
			)
		vertical_offset :=
			room_radius_y *
			TERRAIN_CAVE_NODE_EDGE_PORTAL_VERTICAL_OFFSET_SCALE *
			vertical_sign *
			biomes.regional_terrain_field_lerp(
				f32(0.35),
				f32(1.05),
				biomes.feature_grid_unit_f32(hash, TERRAIN_CAVE_ROUGHNESS_SALT),
			)
		center_x :=
			node.x +
			dir_x * room_radius_xz * TERRAIN_CAVE_NODE_EDGE_PORTAL_OFFSET_SCALE +
			side_x * side_offset
		center_y := node.y + dir_y * room_radius_y * f32(0.65) + vertical_offset
		center_z :=
			node.z +
			dir_z * room_radius_xz * TERRAIN_CAVE_NODE_EDGE_PORTAL_OFFSET_SCALE +
			side_z * side_offset

		portal_radius_x := portal_radius
		portal_radius_y := portal_radius * f32(0.58)
		portal_radius_z := portal_radius * f32(0.88)
		shape_kind := edge.kind
		#partial switch node.biome_id {
		case .Fungal_Vaults:
			portal_radius_x *= 1.18
			portal_radius_y *= 0.92
			portal_radius_z *= 1.08
			shape_kind = .Worm_Path
		case .Crystal_Geode_Network:
			portal_radius_x *= 0.62
			portal_radius_y *= 1.32
			portal_radius_z *= 0.74
			shape_kind = .Fracture
		case .Buried_Aquifer_Caves:
			portal_radius_x *= 1.22
			portal_radius_y *= 0.48
			portal_radius_z *= 1.10
			shape_kind = .Flooded_Passage
		case .Temperate_Hills, .Basalt_Spire_Highlands, .Wet_Lowland_Marsh, .Corrupted_Ash_Forest:
		}

		portal_shape := terrain_density_cave_passage_shape(shape_kind)
		terrain_density_cave_passage_shape_apply_biome(&portal_shape, node.biome_id)
		if edge.regional_seam_connection && edge.kind == .Canyon {
			terrain_density_cave_passage_shape_apply_regional_seam(&portal_shape)
		}
		throat_radius := math.max(
			f32(2.0),
			math.min(
				portal_radius * TERRAIN_CAVE_NODE_EDGE_PORTAL_THROAT_SCALE,
				edge_radius * f32(0.58),
			),
		)
		start_x := node.x + dir_x * room_radius_xz * f32(0.24)
		start_y := node.y + dir_y * room_radius_y * f32(0.24)
		start_z := node.z + dir_z * room_radius_xz * f32(0.24)
		terrain_density_carve_rough_segment_shaped(
			view,
			region.key,
			chunk_origin,
			columns,
			start_x,
			start_y,
			start_z,
			center_x,
			center_y,
			center_z,
			throat_radius,
			portal_shape,
			TERRAIN_CAVE_ROOM_DETAIL_SALT ~ u64(portal_count + 1237),
			node.biome_id,
			true,
		)
		terrain_density_carve_cave_room_lobed_ellipsoid(
			view,
			region.key,
			chunk_origin,
			columns,
			center_x,
			center_y,
			center_z,
			portal_radius_x,
			portal_radius_y,
			portal_radius_z,
			TERRAIN_CAVE_FIELD_CHAMBER_SALT ~ u64(portal_count + 1279),
			node.biome_id,
			true,
		)
		if node.biome_id == .Crystal_Geode_Network {
			splinter_shape := terrain_density_cave_passage_shape(.Fracture)
			terrain_density_cave_passage_shape_apply_biome(&splinter_shape, node.biome_id)
			for splinter_index := u32(0); splinter_index < 2; splinter_index += 1 {
				splinter_side_sign := side_sign
				splinter_scale := f32(1)
				if splinter_index == 1 {
					splinter_side_sign = -side_sign
					splinter_scale = 0.72
				}
				splinter_side_offset :=
					splinter_side_sign *
					portal_radius *
					TERRAIN_CAVE_NODE_EDGE_PORTAL_CRYSTAL_SPLINTER_SIDE_SCALE
				splinter_forward_offset :=
					portal_radius *
					TERRAIN_CAVE_NODE_EDGE_PORTAL_CRYSTAL_SPLINTER_FORWARD_SCALE *
					(f32(1) - f32(0.18) * f32(splinter_index))
				splinter_vertical_offset :=
					math.abs(portal_radius_y) *
					TERRAIN_CAVE_NODE_EDGE_PORTAL_CRYSTAL_SPLINTER_VERTICAL_SCALE
				splinter_center_x :=
					center_x + side_x * splinter_side_offset + dir_x * splinter_forward_offset
				splinter_center_y := center_y + splinter_vertical_offset
				splinter_center_z :=
					center_z + side_z * splinter_side_offset + dir_z * splinter_forward_offset
				splinter_radius := math.clamp(
					portal_radius *
					TERRAIN_CAVE_NODE_EDGE_PORTAL_CRYSTAL_SPLINTER_RADIUS_SCALE *
					splinter_scale,
					TERRAIN_CAVE_NODE_EDGE_PORTAL_RADIUS_MIN_BLOCKS,
					TERRAIN_CAVE_NODE_EDGE_PORTAL_RADIUS_MAX_BLOCKS * f32(0.70),
				)
				terrain_density_carve_rough_segment_shaped(
					view,
					region.key,
					chunk_origin,
					columns,
					center_x,
					center_y,
					center_z,
					splinter_center_x,
					splinter_center_y,
					splinter_center_z,
					math.max(
						f32(1.75),
						splinter_radius *
						TERRAIN_CAVE_NODE_EDGE_PORTAL_CRYSTAL_SPLINTER_THROAT_SCALE,
					),
					splinter_shape,
					TERRAIN_CAVE_ROOM_DETAIL_SALT ~ u64(portal_count + 1291 + splinter_index * 23),
					node.biome_id,
					true,
				)
				terrain_density_carve_cave_room_lobed_ellipsoid(
					view,
					region.key,
					chunk_origin,
					columns,
					splinter_center_x,
					splinter_center_y,
					splinter_center_z,
					splinter_radius * f32(0.56),
					splinter_radius * f32(1.08),
					splinter_radius * f32(0.68),
					TERRAIN_CAVE_FIELD_CHAMBER_SALT ~
					u64(portal_count + 1301 + splinter_index * 23),
					node.biome_id,
					true,
				)
			}
		}
		portal_count += 1
	}
}

terrain_density_carve_cave_node_major_room_perimeter_field :: proc(
	view: ^world_async.ChunkVoxelView,
	key: biomes.FeatureGridKey,
	chunk_origin: world_async.BlockCoord,
	columns: []TerrainBiomeColumn,
	node: biomes.CaveNetworkNode,
	radius_x, radius_y, radius_z: f32,
	wall_buffer: ^TerrainCaveWallMaterialBuffer = nil,
) {
	log.assert(node.major_region, "major cave room perimeter fields are only for major cave rooms")

	min_radius := math.min(radius_x, math.min(radius_y, radius_z))
	if min_radius < TERRAIN_CAVE_ROOM_COMPOUND_MIN_RADIUS {
		return
	}

	bounds_radius_xz :=
		math.max(radius_x, radius_z) * TERRAIN_CAVE_NODE_MAJOR_ROOM_FIELD_EXTENT_SCALE + 2
	bounds_radius_y := radius_y * f32(1.32) + 2
	local_min_x, local_max_x, local_min_y, local_max_y, local_min_z, local_max_z, intersects :=
		terrain_density_carve_bounds_from_extents(
			chunk_origin,
			node.x - bounds_radius_xz,
			node.x + bounds_radius_xz,
			node.y - bounds_radius_y,
			node.y + bounds_radius_y,
			node.z - bounds_radius_xz,
			node.z + bounds_radius_xz,
		)
	if !intersects {
		return
	}

	axis_x := biomes.regional_terrain_field_value_noise_3(
		key,
		i32(math.floor_f32(node.x)),
		i32(math.floor_f32(node.y)),
		i32(math.floor_f32(node.z)),
		64,
		TERRAIN_CAVE_BRANCH_SALT,
	)
	axis_z := biomes.regional_terrain_field_value_noise_3(
		key,
		i32(math.floor_f32(node.x)) + 17,
		i32(math.floor_f32(node.y)) - 5,
		i32(math.floor_f32(node.z)) + 23,
		64,
		TERRAIN_CAVE_ROOM_DETAIL_SALT,
	)
	axis_len := math.sqrt_f32(axis_x * axis_x + axis_z * axis_z)
	if axis_len <= 0.001 {
		axis_x, axis_z = 1, 0
	} else {
		axis_x /= axis_len
		axis_z /= axis_len
	}

	internal_structure_active := min_radius >= TERRAIN_CAVE_ROOM_INTERNAL_STRUCTURE_MIN_RADIUS
	along_x_coeff := axis_x / radius_x
	along_z_coeff := axis_z / radius_z
	height_y_coeff := f32(1) / radius_y
	across_x_coeff := -axis_z / radius_x
	across_z_coeff := axis_x / radius_z
	for z := local_min_z; z <= local_max_z; z += 1 {
		world_z := f32(chunk_origin.z + z) + 0.5
		for y := local_min_y; y <= local_max_y; y += 1 {
			world_y := f32(chunk_origin.y + y) + 0.5
			row_min_x, row_max_x, row_intersects := terrain_density_local_box_row_x_bounds(
				chunk_origin,
				local_min_x,
				local_max_x,
				world_y,
				world_z,
				node.x,
				node.y,
				node.z,
				along_x_coeff,
				along_z_coeff,
				height_y_coeff,
				across_x_coeff,
				across_z_coeff,
				-2.0,
				2.0,
				-2.0,
				2.0,
				-2.0,
				2.0,
			)
			if !row_intersects {
				continue
			}
			rough_noise_row_cache: TerrainValueNoise3RowCache
			rough_noise_row_cache_ready := false
			detail_noise_row_cache: TerrainValueNoise3RowCache
			detail_noise_row_cache_ready := false
			for x := row_min_x; x <= row_max_x; x += 1 {
				if !terrain_density_local_block_can_carve(view, x, y, z) {
					continue
				}
				world_x := f32(chunk_origin.x + x) + 0.5
				nx := (world_x - node.x) / radius_x
				ny := (world_y - node.y) / radius_y
				nz := (world_z - node.z) / radius_z
				along := nx * axis_x + nz * axis_z
				across := nx * -axis_z + nz * axis_x
				shape := terrain_density_cave_major_room_perimeter_shape(
					along,
					ny,
					across,
					node.biome_id,
				)
				if shape > f32(1.220001) {
					continue
				}

				if !rough_noise_row_cache_ready {
					rough_noise_row_cache = terrain_value_noise3_row_cache_make(
						key,
						TERRAIN_CAVE_FIELD_CHAMBER_SALT ~ u64(node.id),
						18,
						chunk_origin.y + y,
						chunk_origin.z + z,
					)
					rough_noise_row_cache_ready = true
				}
				rough := terrain_value_noise3_row_cache_sample(
					&rough_noise_row_cache,
					chunk_origin.x + x,
				)
				if !detail_noise_row_cache_ready {
					detail_noise_row_cache = terrain_value_noise3_row_cache_make(
						key,
						TERRAIN_CAVE_ROOM_DETAIL_SALT ~ u64(node.id),
						9,
						chunk_origin.y + y,
						chunk_origin.z + z,
					)
					detail_noise_row_cache_ready = true
				}
				detail := terrain_value_noise3_row_cache_sample(
					&detail_noise_row_cache,
					chunk_origin.x + x,
				)
				threshold_without_cellular := 1.0 + rough * f32(0.08) + detail * f32(0.06)
				if shape > threshold_without_cellular + f32(0.080001) {
					continue
				}
				cell_size := math.max(
					TERRAIN_CAVE_ROOM_CELLULAR_CELL_MIN_BLOCKS,
					min_radius * TERRAIN_CAVE_NODE_MAJOR_ROOM_FIELD_CELL_SCALE,
				)
				cell_gap := terrain_density_cave_room_worley_gap(
					key,
					world_x,
					world_y,
					world_z,
					cell_size,
					TERRAIN_CAVE_FIELD_DETAIL_SALT ~ u64(node.id),
				)
				cellular_pocket := math.smoothstep(f32(0.36), f32(0.82), cell_gap)
				cellular_ridge := 1.0 - math.smoothstep(f32(0.08), f32(0.28), cell_gap)
				threshold :=
					threshold_without_cellular +
					cellular_pocket * f32(0.08) -
					cellular_ridge * f32(0.04)
				if shape <= threshold {
					if internal_structure_active &&
					   terrain_density_cave_room_internal_structure_preserves(
						   nx,
						   ny,
						   nz,
						   radius_x,
						   radius_y,
						   radius_z,
						   axis_x,
						   axis_z,
						   rough,
						   node.biome_id,
					   ) {
						continue
					}
					terrain_density_carve_checked_local_block_with_material(
						view,
						key,
						chunk_origin,
						columns,
						x,
						y,
						z,
						node.biome_id,
						true,
						wall_buffer,
					)
				}
			}
		}
	}
}

terrain_density_carve_cave_node_macro_satellites :: proc(
	view: ^world_async.ChunkVoxelView,
	key: biomes.FeatureGridKey,
	chunk_origin: world_async.BlockCoord,
	columns: []TerrainBiomeColumn,
	node: biomes.CaveNetworkNode,
	radius_x, radius_y, radius_z: f32,
	wall_buffer: ^TerrainCaveWallMaterialBuffer = nil,
) {
	log.assert(node.major_region, "macro cave satellites are only for major cave rooms")

	base_radius := math.max(
		TERRAIN_CAVE_NODE_MACRO_SATELLITE_MIN_RADIUS_BLOCKS,
		math.min(radius_x, radius_z) * TERRAIN_CAVE_NODE_MACRO_SATELLITE_RADIUS_XZ_SCALE,
	)

	cluster_shape := terrain_density_cave_passage_shape(.Tunnel)
	#partial switch node.biome_id {
	case .Fungal_Vaults:
		cluster_shape = terrain_density_cave_passage_shape(.Worm_Path)
	case .Crystal_Geode_Network:
		cluster_shape = terrain_density_cave_passage_shape(.Fracture)
	case .Buried_Aquifer_Caves:
		cluster_shape = terrain_density_cave_passage_shape(.Flooded_Passage)
		cluster_shape.radius_y_scale = math.min(cluster_shape.radius_y_scale, f32(0.48))
	case .Temperate_Hills, .Basalt_Spire_Highlands, .Wet_Lowland_Marsh, .Corrupted_Ash_Forest:
	}
	terrain_density_cave_passage_shape_apply_biome(&cluster_shape, node.biome_id)

	satellite_center_x: [TERRAIN_CAVE_NODE_MACRO_SATELLITE_COUNT]f32
	satellite_center_y: [TERRAIN_CAVE_NODE_MACRO_SATELLITE_COUNT]f32
	satellite_center_z: [TERRAIN_CAVE_NODE_MACRO_SATELLITE_COUNT]f32
	satellite_plan_radius_x: [TERRAIN_CAVE_NODE_MACRO_SATELLITE_COUNT]f32
	satellite_plan_radius_y: [TERRAIN_CAVE_NODE_MACRO_SATELLITE_COUNT]f32
	satellite_plan_radius_z: [TERRAIN_CAVE_NODE_MACRO_SATELLITE_COUNT]f32
	satellite_plan_radius_xz_min: [TERRAIN_CAVE_NODE_MACRO_SATELLITE_COUNT]f32
	satellite_dir_x: [TERRAIN_CAVE_NODE_MACRO_SATELLITE_COUNT]f32
	satellite_dir_z: [TERRAIN_CAVE_NODE_MACRO_SATELLITE_COUNT]f32

	for satellite_index := u32(0);
	    satellite_index < TERRAIN_CAVE_NODE_MACRO_SATELLITE_COUNT;
	    satellite_index += 1 {
		hash := biomes.feature_grid_hash_combine(u64(node.id), TERRAIN_CAVE_FIELD_CHAMBER_SALT)
		hash = biomes.feature_grid_hash_combine(hash, u64(satellite_index + 811))
		angle :=
			(f32(satellite_index) / f32(TERRAIN_CAVE_NODE_MACRO_SATELLITE_COUNT) +
				biomes.feature_grid_unit_f32(hash, TERRAIN_CAVE_CURVE_SALT) * f32(0.19)) *
			f32(6.2831855)
		dir_x := math.cos_f32(angle)
		dir_z := math.sin_f32(angle)
		forward_bias := biomes.regional_terrain_field_lerp(
			f32(0.78),
			f32(1.18),
			biomes.feature_grid_unit_f32(hash, TERRAIN_CAVE_BRANCH_SALT),
		)
		offset_x := radius_x * TERRAIN_CAVE_NODE_MACRO_SATELLITE_OFFSET_SCALE * forward_bias
		offset_z := radius_z * TERRAIN_CAVE_NODE_MACRO_SATELLITE_OFFSET_SCALE * forward_bias
		vertical_sign := f32(1)
		if (satellite_index & 1) != 0 {
			vertical_sign = -1
		}
		if biomes.feature_grid_signed_unit_f32(hash, TERRAIN_CAVE_PASSAGE_RIB_SALT) < 0 {
			vertical_sign = -vertical_sign
		}
		center_x := node.x + dir_x * offset_x
		center_y :=
			node.y +
			radius_y *
				TERRAIN_CAVE_NODE_MACRO_SATELLITE_VERTICAL_OFFSET_SCALE *
				vertical_sign *
				biomes.regional_terrain_field_lerp(
					f32(0.44),
					f32(1.08),
					biomes.feature_grid_unit_f32(hash, TERRAIN_CAVE_DETAIL_SALT),
				)
		center_z := node.z + dir_z * offset_z

		satellite_radius := math.clamp(
			base_radius *
			biomes.regional_terrain_field_lerp(
				f32(0.78),
				f32(1.24),
				biomes.feature_grid_unit_f32(hash, TERRAIN_CAVE_ROUGHNESS_SALT),
			),
			TERRAIN_CAVE_NODE_MACRO_SATELLITE_MIN_RADIUS_BLOCKS,
			TERRAIN_CAVE_NODE_MACRO_SATELLITE_MAX_RADIUS_BLOCKS,
		)
		satellite_radius_x := satellite_radius
		satellite_radius_y := math.max(
			TERRAIN_CAVE_NODE_MACRO_SATELLITE_MIN_RADIUS_BLOCKS * f32(0.65),
			satellite_radius * TERRAIN_CAVE_NODE_MACRO_SATELLITE_RADIUS_Y_SCALE,
		)
		satellite_radius_z := satellite_radius * f32(0.92)
		#partial switch node.biome_id {
		case .Fungal_Vaults:
			satellite_radius_x *= 1.18
			satellite_radius_z *= 1.08
			satellite_radius_y *= 1.05
		case .Crystal_Geode_Network:
			satellite_radius_x *= 0.72
			satellite_radius_y *= 1.42
			satellite_radius_z *= 0.82
		case .Buried_Aquifer_Caves:
			satellite_radius_x *= 1.20
			satellite_radius_y *= 0.62
			satellite_radius_z *= 1.08
		case .Temperate_Hills, .Basalt_Spire_Highlands, .Wet_Lowland_Marsh, .Corrupted_Ash_Forest:
		}

		satellite_center_x[satellite_index] = center_x
		satellite_center_y[satellite_index] = center_y
		satellite_center_z[satellite_index] = center_z
		satellite_plan_radius_x[satellite_index] = satellite_radius_x
		satellite_plan_radius_y[satellite_index] = satellite_radius_y
		satellite_plan_radius_z[satellite_index] = satellite_radius_z
		satellite_plan_radius_xz_min[satellite_index] = math.min(
			satellite_radius_x,
			satellite_radius_z,
		)
		satellite_dir_x[satellite_index] = dir_x
		satellite_dir_z[satellite_index] = dir_z
	}

	for satellite_index := u32(0);
	    satellite_index < TERRAIN_CAVE_NODE_MACRO_SATELLITE_COUNT;
	    satellite_index += 1 {
		satellite_profile_start: time.Tick
		when TERRAIN_GENERATION_PROFILE_PHASES {
			satellite_profile_start = time.tick_now()
		}
		when !TERRAIN_GENERATION_PROFILE_PHASES {
			_ = satellite_profile_start
		}
		dir_x := satellite_dir_x[satellite_index]
		dir_z := satellite_dir_z[satellite_index]
		throat_radius := math.max(
			f32(2.2),
			math.min(
				math.min(
					satellite_plan_radius_x[satellite_index],
					satellite_plan_radius_z[satellite_index],
				) *
				f32(0.58),
				math.min(radius_x, radius_z) * TERRAIN_CAVE_NODE_MACRO_SATELLITE_THROAT_SCALE,
			),
		)
		terrain_density_carve_rough_segment_shaped(
			view,
			key,
			chunk_origin,
			columns,
			node.x + dir_x * radius_x * f32(0.32),
			node.y,
			node.z + dir_z * radius_z * f32(0.32),
			satellite_center_x[satellite_index],
			satellite_center_y[satellite_index],
			satellite_center_z[satellite_index],
			throat_radius,
			cluster_shape,
			TERRAIN_CAVE_FIELD_CHAMBER_SALT ~ u64(satellite_index + 857),
			node.biome_id,
			true,
			wall_buffer,
		)
		terrain_density_carve_cave_room_lobed_ellipsoid(
			view,
			key,
			chunk_origin,
			columns,
			satellite_center_x[satellite_index],
			satellite_center_y[satellite_index],
			satellite_center_z[satellite_index],
			satellite_plan_radius_x[satellite_index],
			satellite_plan_radius_y[satellite_index],
			satellite_plan_radius_z[satellite_index],
			TERRAIN_CAVE_FIELD_CHAMBER_SALT ~ u64(satellite_index + 907),
			node.biome_id,
			true,
			wall_buffer,
		)
		when TERRAIN_GENERATION_PROFILE_PHASES {
			terrain_generation_profile_stats.node_satellite_direct += time.tick_since(
				satellite_profile_start,
			)
			satellite_profile_start = time.tick_now()
		}
		terrain_density_carve_cave_node_macro_satellite_apron_field(
			view,
			key,
			chunk_origin,
			columns,
			node,
			radius_x,
			radius_y,
			radius_z,
			satellite_center_x[satellite_index],
			satellite_center_y[satellite_index],
			satellite_center_z[satellite_index],
			satellite_plan_radius_xz_min[satellite_index],
			dir_x,
			dir_z,
			TERRAIN_CAVE_FIELD_CHAMBER_SALT ~ u64(satellite_index + 919),
			satellite_index,
			wall_buffer,
		)
		when TERRAIN_GENERATION_PROFILE_PHASES {
			terrain_generation_profile_stats.node_satellite_apron += time.tick_since(
				satellite_profile_start,
			)
		}
	}

	for satellite_index := u32(0);
	    satellite_index < TERRAIN_CAVE_NODE_MACRO_SATELLITE_COUNT;
	    satellite_index += 1 {
		satellite_cluster_profile_start: time.Tick
		when TERRAIN_GENERATION_PROFILE_PHASES {
			satellite_cluster_profile_start = time.tick_now()
		}
		when !TERRAIN_GENERATION_PROFILE_PHASES {
			_ = satellite_cluster_profile_start
		}
		next_index := (satellite_index + 1) % TERRAIN_CAVE_NODE_MACRO_SATELLITE_COUNT
		bridge_source_radius := math.min(
			satellite_plan_radius_xz_min[satellite_index],
			satellite_plan_radius_xz_min[next_index],
		)
		bridge_radius := math.max(
			TERRAIN_CAVE_NODE_MACRO_SATELLITE_CLUSTER_BRIDGE_MIN_BLOCKS,
			bridge_source_radius * TERRAIN_CAVE_NODE_MACRO_SATELLITE_CLUSTER_BRIDGE_RADIUS_SCALE,
		)
		outward_dir_x := satellite_dir_x[satellite_index] + satellite_dir_x[next_index]
		outward_dir_z := satellite_dir_z[satellite_index] + satellite_dir_z[next_index]
		outward_dir_len := math.sqrt_f32(
			outward_dir_x * outward_dir_x + outward_dir_z * outward_dir_z,
		)
		if outward_dir_len <= 0.001 {
			outward_dir_x = satellite_dir_x[satellite_index]
			outward_dir_z = satellite_dir_z[satellite_index]
		} else {
			outward_dir_x /= outward_dir_len
			outward_dir_z /= outward_dir_len
		}
		directional_radius_inv_sq :=
			(outward_dir_x * outward_dir_x) / (radius_x * radius_x) +
			(outward_dir_z * outward_dir_z) / (radius_z * radius_z)
		directional_room_radius := math.min(radius_x, radius_z)
		if directional_radius_inv_sq > 0.0001 {
			directional_room_radius = f32(1) / math.sqrt_f32(directional_radius_inv_sq)
		}
		tangent_x := satellite_center_x[next_index] - satellite_center_x[satellite_index]
		tangent_z := satellite_center_z[next_index] - satellite_center_z[satellite_index]
		tangent_len := math.sqrt_f32(tangent_x * tangent_x + tangent_z * tangent_z)
		if tangent_len <= 0.001 {
			tangent_x = -outward_dir_z
			tangent_z = outward_dir_x
		} else {
			tangent_x /= tangent_len
			tangent_z /= tangent_len
		}
		outer_hash := biomes.feature_grid_hash_combine(u64(node.id), TERRAIN_CAVE_ROOM_DETAIL_SALT)
		outer_hash = biomes.feature_grid_hash_combine(outer_hash, u64(satellite_index + 943))
		outer_center_x :=
			node.x +
			outward_dir_x *
				directional_room_radius *
				TERRAIN_CAVE_NODE_MACRO_SATELLITE_CLUSTER_OUTER_OFFSET_SCALE
		outer_center_y :=
			(satellite_center_y[satellite_index] + satellite_center_y[next_index]) * f32(0.5) +
			radius_y *
				f32(0.12) *
				biomes.feature_grid_signed_unit_f32(outer_hash, TERRAIN_CAVE_PASSAGE_RIB_SALT)
		outer_center_z :=
			node.z +
			outward_dir_z *
				directional_room_radius *
				TERRAIN_CAVE_NODE_MACRO_SATELLITE_CLUSTER_OUTER_OFFSET_SCALE

		terrain_density_carve_rough_segment_shaped(
			view,
			key,
			chunk_origin,
			columns,
			satellite_center_x[satellite_index],
			satellite_center_y[satellite_index],
			satellite_center_z[satellite_index],
			outer_center_x,
			outer_center_y,
			outer_center_z,
			bridge_radius,
			cluster_shape,
			TERRAIN_CAVE_ROOM_DETAIL_SALT ~ u64(satellite_index + 941),
			node.biome_id,
			true,
			wall_buffer,
		)
		terrain_density_carve_rough_segment_shaped(
			view,
			key,
			chunk_origin,
			columns,
			outer_center_x,
			outer_center_y,
			outer_center_z,
			satellite_center_x[next_index],
			satellite_center_y[next_index],
			satellite_center_z[next_index],
			bridge_radius,
			cluster_shape,
			TERRAIN_CAVE_ROOM_DETAIL_SALT ~ u64(satellite_index + 953),
			node.biome_id,
			true,
			wall_buffer,
		)

		pocket_radius := math.clamp(
			bridge_source_radius * TERRAIN_CAVE_NODE_MACRO_SATELLITE_CLUSTER_POCKET_RADIUS_SCALE,
			TERRAIN_CAVE_NODE_MACRO_SATELLITE_CLUSTER_POCKET_MIN_BLOCKS,
			TERRAIN_CAVE_NODE_MACRO_SATELLITE_CLUSTER_POCKET_MAX_BLOCKS,
		)
		pocket_radius_x := pocket_radius
		pocket_radius_y := pocket_radius * f32(0.58)
		pocket_radius_z := pocket_radius * f32(0.86)
		#partial switch node.biome_id {
		case .Fungal_Vaults:
			pocket_radius_x *= 1.16
			pocket_radius_y *= 0.92
			pocket_radius_z *= 1.08
		case .Crystal_Geode_Network:
			pocket_radius_x *= 0.58
			pocket_radius_y *= 1.24
			pocket_radius_z *= 0.64
		case .Buried_Aquifer_Caves:
			pocket_radius_x *= 1.18
			pocket_radius_y *= 0.44
			pocket_radius_z *= 1.06
		case .Temperate_Hills, .Basalt_Spire_Highlands, .Wet_Lowland_Marsh, .Corrupted_Ash_Forest:
		}
		terrain_density_carve_cave_room_lobed_ellipsoid(
			view,
			key,
			chunk_origin,
			columns,
			outer_center_x,
			outer_center_y,
			outer_center_z,
			pocket_radius_x,
			pocket_radius_y,
			pocket_radius_z,
			TERRAIN_CAVE_FIELD_CHAMBER_SALT ~ u64(satellite_index + 967),
			node.biome_id,
			true,
			wall_buffer,
		)

		alcove_sign := f32(1)
		if biomes.feature_grid_signed_unit_f32(outer_hash, TERRAIN_CAVE_BRANCH_SALT) < 0 {
			alcove_sign = -1
		}
		alcove_radius :=
			pocket_radius * TERRAIN_CAVE_NODE_MACRO_SATELLITE_CLUSTER_ALCOVE_RADIUS_SCALE
		alcove_offset :=
			pocket_radius * TERRAIN_CAVE_NODE_MACRO_SATELLITE_CLUSTER_ALCOVE_OFFSET_SCALE
		alcove_center_x :=
			outer_center_x +
			tangent_x * alcove_sign * alcove_offset +
			outward_dir_x * bridge_radius * f32(0.35)
		alcove_center_y :=
			outer_center_y +
			radius_y *
				f32(0.08) *
				biomes.feature_grid_signed_unit_f32(outer_hash, TERRAIN_CAVE_DETAIL_SALT)
		alcove_center_z :=
			outer_center_z +
			tangent_z * alcove_sign * alcove_offset +
			outward_dir_z * bridge_radius * f32(0.35)
		alcove_throat_radius := math.max(
			f32(1.6),
			bridge_radius * TERRAIN_CAVE_NODE_MACRO_SATELLITE_CLUSTER_ALCOVE_THROAT_SCALE,
		)
		terrain_density_carve_rough_segment_shaped(
			view,
			key,
			chunk_origin,
			columns,
			outer_center_x,
			outer_center_y,
			outer_center_z,
			alcove_center_x,
			alcove_center_y,
			alcove_center_z,
			alcove_throat_radius,
			cluster_shape,
			TERRAIN_CAVE_ROOM_DETAIL_SALT ~ u64(satellite_index + 983),
			node.biome_id,
			true,
			wall_buffer,
		)
		alcove_radius_x := alcove_radius
		alcove_radius_y := alcove_radius * f32(0.54)
		alcove_radius_z := alcove_radius * f32(0.78)
		#partial switch node.biome_id {
		case .Fungal_Vaults:
			alcove_radius_x *= 1.22
			alcove_radius_y *= 0.96
			alcove_radius_z *= 1.10
		case .Crystal_Geode_Network:
			alcove_radius_x *= 0.54
			alcove_radius_y *= 1.34
			alcove_radius_z *= 0.62
		case .Buried_Aquifer_Caves:
			alcove_radius_x *= 1.26
			alcove_radius_y *= 0.42
			alcove_radius_z *= 1.08
		case .Temperate_Hills, .Basalt_Spire_Highlands, .Wet_Lowland_Marsh, .Corrupted_Ash_Forest:
		}
		terrain_density_carve_cave_room_lobed_ellipsoid(
			view,
			key,
			chunk_origin,
			columns,
			alcove_center_x,
			alcove_center_y,
			alcove_center_z,
			alcove_radius_x,
			alcove_radius_y,
			alcove_radius_z,
			TERRAIN_CAVE_FIELD_CHAMBER_SALT ~ u64(satellite_index + 991),
			node.biome_id,
			true,
			wall_buffer,
		)
		terrain_density_carve_cave_node_macro_cluster_field(
			view,
			key,
			chunk_origin,
			columns,
			outer_center_x,
			outer_center_y,
			outer_center_z,
			tangent_x,
			tangent_z,
			outward_dir_x,
			outward_dir_z,
			pocket_radius,
			bridge_radius,
			TERRAIN_CAVE_FIELD_CHAMBER_SALT ~ u64(satellite_index + 1009),
			node.biome_id,
			wall_buffer,
		)
		when TERRAIN_GENERATION_PROFILE_PHASES {
			terrain_generation_profile_stats.node_satellite_cluster += time.tick_since(
				satellite_cluster_profile_start,
			)
		}
	}
}

terrain_density_carve_cave_node_macro_satellite_apron_field :: proc(
	view: ^world_async.ChunkVoxelView,
	key: biomes.FeatureGridKey,
	chunk_origin: world_async.BlockCoord,
	columns: []TerrainBiomeColumn,
	node: biomes.CaveNetworkNode,
	radius_x, radius_y, radius_z: f32,
	satellite_x, satellite_y, satellite_z: f32,
	satellite_radius_xz: f32,
	dir_x, dir_z: f32,
	noise_salt: u64,
	satellite_index: u32,
	wall_buffer: ^TerrainCaveWallMaterialBuffer = nil,
) {
	directional_radius_inv_sq :=
		(dir_x * dir_x) / (radius_x * radius_x) + (dir_z * dir_z) / (radius_z * radius_z)
	directional_room_radius := math.min(radius_x, radius_z)
	if directional_radius_inv_sq > 0.0001 {
		directional_room_radius = f32(1) / math.sqrt_f32(directional_radius_inv_sq)
	}
	satellite_along := (satellite_x - node.x) * dir_x + (satellite_z - node.z) * dir_z
	from_along := directional_room_radius * TERRAIN_CAVE_NODE_MACRO_SATELLITE_APRON_INNER_SCALE
	to_along := satellite_along * TERRAIN_CAVE_NODE_MACRO_SATELLITE_APRON_END_SCALE
	if to_along <= from_along + 1.0 {
		return
	}

	apron_radius := math.max(
		f32(3.0),
		math.min(
			satellite_radius_xz * TERRAIN_CAVE_NODE_MACRO_SATELLITE_APRON_RADIUS_SCALE,
			directional_room_radius * f32(0.42),
		),
	)
	radius_along := apron_radius
	radius_y_apron := apron_radius * TERRAIN_CAVE_NODE_MACRO_SATELLITE_APRON_VERTICAL_RADIUS_SCALE
	radius_across := apron_radius * TERRAIN_CAVE_NODE_MACRO_SATELLITE_APRON_SIDE_RADIUS_SCALE
	branch_radius_scale := TERRAIN_CAVE_NODE_MACRO_SATELLITE_APRON_BRANCH_RADIUS_SCALE
	branch_offset := apron_radius * TERRAIN_CAVE_NODE_MACRO_SATELLITE_APRON_BRANCH_OFFSET_SCALE
	#partial switch node.biome_id {
	case .Fungal_Vaults:
		radius_along *= 1.12
		radius_across *= 1.22
		radius_y_apron *= 0.96
		branch_radius_scale *= 1.10
		branch_offset *= 1.12
	case .Crystal_Geode_Network:
		radius_along *= 0.72
		radius_across *= 0.72
		radius_y_apron *= 1.42
		branch_radius_scale *= 0.82
	case .Buried_Aquifer_Caves:
		radius_along *= 1.08
		radius_across *= 1.36
		radius_y_apron *= 0.54
		branch_radius_scale *= 1.12
		branch_offset *= 1.08
	case .Temperate_Hills, .Basalt_Spire_Highlands, .Wet_Lowland_Marsh, .Corrupted_Ash_Forest:
	}

	padding := math.max(radius_along, math.max(radius_y_apron, radius_across)) * f32(2.25) + 2
	local_min_x, local_max_x, local_min_y, local_max_y, local_min_z, local_max_z, intersects :=
		terrain_density_carve_bounds_from_extents(
			chunk_origin,
			math.min(node.x, satellite_x) - padding,
			math.max(node.x, satellite_x) + padding,
			math.min(node.y, satellite_y) - padding,
			math.max(node.y, satellite_y) + padding,
			math.min(node.z, satellite_z) - padding,
			math.max(node.z, satellite_z) + padding,
		)
	if !intersects {
		return
	}

	side_x := -dir_z
	side_z := dir_x
	branch_sign := f32(1)
	if (satellite_index & 1) != 0 {
		branch_sign = -1
	}
	if biomes.feature_grid_signed_unit_f32(noise_salt, TERRAIN_CAVE_BRANCH_SALT) < -0.15 {
		branch_sign = -branch_sign
	}
	to_y := (satellite_y - node.y) * f32(0.86)
	branch_along := biomes.regional_terrain_field_lerp(from_along, to_along, f32(0.62))
	branch_y :=
		to_y * f32(0.45) +
		radius_y *
			f32(0.08) *
			biomes.feature_grid_signed_unit_f32(noise_salt, TERRAIN_CAVE_DETAIL_SALT)
	branch_across := branch_offset * branch_sign
	secondary_branch_across := -branch_across * f32(0.62)
	secondary_branch_along := biomes.regional_terrain_field_lerp(from_along, to_along, f32(0.42))
	apron_shape_span := math.sqrt_f32(
		f32(1.240001) + TERRAIN_CAVE_NODE_MACRO_SATELLITE_APRON_BLEND_RADIUS,
	)
	apron_max_along_radius := math.max(
		radius_along * f32(1.16),
		math.max(
			radius_along * branch_radius_scale,
			math.max(radius_along * f32(0.46), radius_along * branch_radius_scale * f32(0.78)),
		),
	)
	apron_max_y_radius := radius_y_apron
	apron_max_across_radius := math.max(
		radius_across * f32(1.12),
		math.max(
			radius_across * branch_radius_scale,
			math.max(radius_across * f32(0.42), radius_across * branch_radius_scale * f32(0.70)),
		),
	)
	apron_min_along_center := math.min(
		math.min(from_along, to_along),
		math.min(
			branch_along,
			math.min(branch_along - radius_along * f32(0.48), secondary_branch_along),
		),
	)
	apron_max_along_center := math.max(
		math.max(from_along, to_along),
		math.max(branch_along, secondary_branch_along),
	)
	apron_min_y_center := math.min(
		math.min(f32(0), to_y),
		math.min(branch_y, math.min(branch_y * f32(0.42), -branch_y * f32(0.38))),
	)
	apron_max_y_center := math.max(
		math.max(f32(0), to_y),
		math.max(branch_y, math.max(branch_y * f32(0.42), -branch_y * f32(0.38))),
	)
	apron_min_across_center := math.min(
		f32(0),
		math.min(branch_across, math.min(branch_across * f32(0.28), secondary_branch_across)),
	)
	apron_max_across_center := math.max(
		f32(0),
		math.max(branch_across, math.max(branch_across * f32(0.28), secondary_branch_across)),
	)
	apron_min_along := apron_min_along_center - apron_max_along_radius * apron_shape_span - 1
	apron_max_along := apron_max_along_center + apron_max_along_radius * apron_shape_span + 1
	apron_min_y := apron_min_y_center - apron_max_y_radius * apron_shape_span - 1
	apron_max_y := apron_max_y_center + apron_max_y_radius * apron_shape_span + 1
	apron_min_across := apron_min_across_center - apron_max_across_radius * apron_shape_span - 1
	apron_max_across := apron_max_across_center + apron_max_across_radius * apron_shape_span + 1

	for z := local_min_z; z <= local_max_z; z += 1 {
		world_z := f32(chunk_origin.z + z) + 0.5
		for y := local_min_y; y <= local_max_y; y += 1 {
			world_y := f32(chunk_origin.y + y) + 0.5
			row_min_x, row_max_x, row_intersects := terrain_density_local_box_row_x_bounds(
				chunk_origin,
				local_min_x,
				local_max_x,
				world_y,
				world_z,
				node.x,
				node.y,
				node.z,
				dir_x,
				dir_z,
				1,
				side_x,
				side_z,
				apron_min_along,
				apron_max_along,
				apron_min_y,
				apron_max_y,
				apron_min_across,
				apron_max_across,
			)
			if !row_intersects {
				continue
			}
			rough_noise_row_cache: TerrainValueNoise3RowCache
			rough_noise_row_cache_ready := false
			detail_noise_row_cache: TerrainValueNoise3RowCache
			detail_noise_row_cache_ready := false
			for x := row_min_x; x <= row_max_x; x += 1 {
				if !terrain_density_local_block_can_carve(view, x, y, z) {
					continue
				}
				world_x := f32(chunk_origin.x + x) + 0.5
				dx := world_x - node.x
				dy := world_y - node.y
				dz := world_z - node.z
				along := dx * dir_x + dz * dir_z
				across := dx * side_x + dz * side_z

				core_shape := terrain_density_cave_room_segment_shape(
					along,
					dy,
					across,
					from_along,
					0,
					0,
					to_along,
					to_y,
					0,
					radius_along,
					radius_y_apron,
					radius_across,
				)
				mouth_shape := terrain_density_cave_room_ellipsoid_shape(
					along,
					dy,
					across,
					from_along,
					0,
					0,
					radius_along * f32(1.16),
					radius_y_apron * f32(0.92),
					radius_across * f32(1.12),
				)
				branch_shape := terrain_density_cave_room_ellipsoid_shape(
					along,
					dy,
					across,
					branch_along,
					branch_y,
					branch_across,
					radius_along * branch_radius_scale,
					radius_y_apron * f32(0.86),
					radius_across * branch_radius_scale,
				)
				branch_neck_shape := terrain_density_cave_room_segment_shape(
					along,
					dy,
					across,
					branch_along - radius_along * f32(0.48),
					branch_y * f32(0.42),
					branch_across * f32(0.28),
					branch_along,
					branch_y,
					branch_across,
					radius_along * f32(0.46),
					radius_y_apron * f32(0.58),
					radius_across * f32(0.42),
				)
				secondary_shape := terrain_density_cave_room_ellipsoid_shape(
					along,
					dy,
					across,
					secondary_branch_along,
					-branch_y * f32(0.38),
					secondary_branch_across,
					radius_along * branch_radius_scale * f32(0.78),
					radius_y_apron * f32(0.74),
					radius_across * branch_radius_scale * f32(0.70),
				)
				shape := terrain_density_cave_room_smooth_min(
					core_shape,
					mouth_shape,
					TERRAIN_CAVE_NODE_MACRO_SATELLITE_APRON_BLEND_RADIUS,
				)
				shape = terrain_density_cave_room_smooth_min(
					shape,
					branch_shape,
					TERRAIN_CAVE_NODE_MACRO_SATELLITE_APRON_BLEND_RADIUS,
				)
				shape = terrain_density_cave_room_smooth_min(
					shape,
					branch_neck_shape,
					TERRAIN_CAVE_NODE_MACRO_SATELLITE_APRON_BLEND_RADIUS,
				)
				shape = terrain_density_cave_room_smooth_min(
					shape,
					secondary_shape,
					TERRAIN_CAVE_NODE_MACRO_SATELLITE_APRON_BLEND_RADIUS,
				)
				if shape > f32(1.240001) {
					continue
				}

				if !rough_noise_row_cache_ready {
					rough_noise_row_cache = terrain_value_noise3_row_cache_make(
						key,
						noise_salt,
						18,
						chunk_origin.y + y,
						chunk_origin.z + z,
					)
					rough_noise_row_cache_ready = true
				}
				rough := terrain_value_noise3_row_cache_sample(
					&rough_noise_row_cache,
					chunk_origin.x + x,
				)
				if !detail_noise_row_cache_ready {
					detail_noise_row_cache = terrain_value_noise3_row_cache_make(
						key,
						noise_salt ~ TERRAIN_CAVE_PASSAGE_RIB_SALT,
						9,
						chunk_origin.y + y,
						chunk_origin.z + z,
					)
					detail_noise_row_cache_ready = true
				}
				detail := terrain_value_noise3_row_cache_sample(
					&detail_noise_row_cache,
					chunk_origin.x + x,
				)
				threshold_without_cellular := 1.0 + rough * f32(0.09) + detail * f32(0.07)
				if shape > threshold_without_cellular + f32(0.080001) {
					continue
				}
				cell_size := math.max(
					f32(3.5),
					apron_radius * TERRAIN_CAVE_NODE_MACRO_SATELLITE_APRON_CELL_SCALE,
				)
				cell_gap := terrain_density_cave_room_worley_gap(
					key,
					world_x,
					world_y,
					world_z,
					cell_size,
					noise_salt,
				)
				cellular_pocket := math.smoothstep(f32(0.36), f32(0.82), cell_gap)
				cellular_ridge := 1.0 - math.smoothstep(f32(0.08), f32(0.28), cell_gap)
				threshold :=
					threshold_without_cellular +
					cellular_pocket * f32(0.08) -
					cellular_ridge * f32(0.05)
				if shape <= threshold {
					terrain_density_carve_checked_local_block_with_material(
						view,
						key,
						chunk_origin,
						columns,
						x,
						y,
						z,
						node.biome_id,
						true,
						wall_buffer,
					)
				}
			}
		}
	}
}

terrain_density_carve_cave_node_macro_cluster_field :: proc(
	view: ^world_async.ChunkVoxelView,
	key: biomes.FeatureGridKey,
	chunk_origin: world_async.BlockCoord,
	columns: []TerrainBiomeColumn,
	center_x, center_y, center_z: f32,
	tangent_x, tangent_z: f32,
	outward_x, outward_z: f32,
	pocket_radius, bridge_radius: f32,
	noise_salt: u64,
	biome_id: biomes.BiomeID,
	wall_buffer: ^TerrainCaveWallMaterialBuffer = nil,
) {
	base_radius := math.max(pocket_radius, bridge_radius * f32(1.35))
	along_radius := base_radius * TERRAIN_CAVE_NODE_MACRO_SATELLITE_CLUSTER_FIELD_RADIUS_SCALE
	outward_radius := base_radius * f32(0.92)
	vertical_radius := base_radius * f32(0.56)
	side_radius_scale := TERRAIN_CAVE_NODE_MACRO_SATELLITE_CLUSTER_FIELD_SIDE_RADIUS_SCALE
	#partial switch biome_id {
	case .Fungal_Vaults:
		along_radius *= 1.18
		outward_radius *= 1.08
		vertical_radius *= 0.94
		side_radius_scale *= 1.08
	case .Crystal_Geode_Network:
		along_radius *= 0.76
		outward_radius *= 0.82
		vertical_radius *= 1.34
		side_radius_scale *= 0.72
	case .Buried_Aquifer_Caves:
		along_radius *= 1.16
		outward_radius *= 1.48
		vertical_radius *= 0.48
		side_radius_scale *= 1.12
	case .Temperate_Hills, .Basalt_Spire_Highlands, .Wet_Lowland_Marsh, .Corrupted_Ash_Forest:
	}

	bounds_radius :=
		math.max(along_radius, math.max(outward_radius, vertical_radius)) +
		base_radius * f32(1.35) +
		2
	local_min_x, local_max_x, local_min_y, local_max_y, local_min_z, local_max_z, intersects :=
		terrain_density_carve_bounds_from_extents(
			chunk_origin,
			center_x - bounds_radius,
			center_x + bounds_radius,
			center_y - bounds_radius,
			center_y + bounds_radius,
			center_z - bounds_radius,
			center_z + bounds_radius,
		)
	if !intersects {
		return
	}

	side_center := base_radius * TERRAIN_CAVE_NODE_MACRO_SATELLITE_CLUSTER_FIELD_SIDE_OFFSET_SCALE
	side_radius_along := base_radius * side_radius_scale
	side_radius_y := vertical_radius * f32(0.84)
	side_radius_outward := outward_radius * f32(0.72)
	outward_center :=
		base_radius * TERRAIN_CAVE_NODE_MACRO_SATELLITE_CLUSTER_FIELD_OUTWARD_OFFSET_SCALE
	inward_center := -base_radius * f32(0.52)
	branch_center :=
		base_radius * TERRAIN_CAVE_NODE_MACRO_SATELLITE_CLUSTER_FIELD_BRANCH_OFFSET_SCALE
	branch_outward :=
		outward_center +
		base_radius * TERRAIN_CAVE_NODE_MACRO_SATELLITE_CLUSTER_FIELD_BRANCH_OUTWARD_SCALE
	branch_radius_along :=
		base_radius * TERRAIN_CAVE_NODE_MACRO_SATELLITE_CLUSTER_FIELD_BRANCH_RADIUS_SCALE
	branch_radius_y := vertical_radius * f32(0.72)
	branch_radius_outward := outward_radius * f32(0.62)
	branch_neck_radius_along :=
		base_radius * TERRAIN_CAVE_NODE_MACRO_SATELLITE_CLUSTER_FIELD_BRANCH_NECK_RADIUS_SCALE
	branch_neck_radius_y := vertical_radius * f32(0.56)
	branch_neck_radius_outward := outward_radius * f32(0.38)
	cluster_shape_span := math.sqrt_f32(
		f32(1.260001) + TERRAIN_CAVE_NODE_MACRO_SATELLITE_CLUSTER_FIELD_BLEND_RADIUS * f32(1.75),
	)
	cluster_max_along_radius := math.max(
		along_radius,
		math.max(
			side_radius_along,
			math.max(
				branch_radius_along,
				math.max(branch_radius_along * f32(0.88), branch_neck_radius_along),
			),
		),
	)
	cluster_max_y_radius := math.max(
		vertical_radius,
		math.max(side_radius_y, math.max(branch_radius_y, branch_neck_radius_y)),
	)
	cluster_max_outward_radius := math.max(
		outward_radius,
		math.max(side_radius_outward, math.max(branch_radius_outward, branch_neck_radius_outward)),
	)
	cluster_min_along_center := math.min(
		-side_center,
		math.min(-branch_center, math.min(-branch_center * f32(0.26), -branch_center * f32(0.92))),
	)
	cluster_max_along_center := math.max(
		side_center,
		math.max(branch_center, branch_center * f32(0.94)),
	)
	cluster_min_y_center := math.min(-vertical_radius * f32(0.06), -vertical_radius * f32(0.05))
	cluster_max_y_center := math.max(vertical_radius * f32(0.04), vertical_radius * f32(0.03))
	cluster_min_outward_center := math.min(f32(0), inward_center)
	cluster_max_outward_center := math.max(
		outward_center,
		math.max(branch_outward, math.max(branch_outward * f32(0.94), branch_outward * f32(0.82))),
	)
	cluster_min_along :=
		cluster_min_along_center - cluster_max_along_radius * cluster_shape_span - 1
	cluster_max_along :=
		cluster_max_along_center + cluster_max_along_radius * cluster_shape_span + 1
	cluster_min_y := cluster_min_y_center - cluster_max_y_radius * cluster_shape_span - 1
	cluster_max_y := cluster_max_y_center + cluster_max_y_radius * cluster_shape_span + 1
	cluster_min_outward :=
		cluster_min_outward_center - cluster_max_outward_radius * cluster_shape_span - 1
	cluster_max_outward :=
		cluster_max_outward_center + cluster_max_outward_radius * cluster_shape_span + 1

	for z := local_min_z; z <= local_max_z; z += 1 {
		world_z := f32(chunk_origin.z + z) + 0.5
		for y := local_min_y; y <= local_max_y; y += 1 {
			world_y := f32(chunk_origin.y + y) + 0.5
			row_min_x, row_max_x, row_intersects := terrain_density_local_box_row_x_bounds(
				chunk_origin,
				local_min_x,
				local_max_x,
				world_y,
				world_z,
				center_x,
				center_y,
				center_z,
				tangent_x,
				tangent_z,
				1,
				outward_x,
				outward_z,
				cluster_min_along,
				cluster_max_along,
				cluster_min_y,
				cluster_max_y,
				cluster_min_outward,
				cluster_max_outward,
			)
			if !row_intersects {
				continue
			}
			rough_noise_row_cache: TerrainValueNoise3RowCache
			rough_noise_row_cache_ready := false
			detail_noise_row_cache: TerrainValueNoise3RowCache
			detail_noise_row_cache_ready := false
			for x := row_min_x; x <= row_max_x; x += 1 {
				if !terrain_density_local_block_can_carve(view, x, y, z) {
					continue
				}
				world_x := f32(chunk_origin.x + x) + 0.5
				dx := world_x - center_x
				dy := world_y - center_y
				dz := world_z - center_z
				along := dx * tangent_x + dz * tangent_z
				outward := dx * outward_x + dz * outward_z

				core_shape := terrain_density_cave_room_ellipsoid_shape(
					along,
					dy,
					outward,
					0,
					0,
					0,
					along_radius,
					vertical_radius,
					outward_radius,
				)
				side_a_shape := terrain_density_cave_room_ellipsoid_shape(
					along,
					dy,
					outward,
					side_center,
					0,
					outward_center * f32(0.25),
					side_radius_along,
					side_radius_y,
					side_radius_outward,
				)
				side_b_shape := terrain_density_cave_room_ellipsoid_shape(
					along,
					dy,
					outward,
					-side_center,
					0,
					outward_center * f32(0.25),
					side_radius_along,
					side_radius_y,
					side_radius_outward,
				)
				outward_shape := terrain_density_cave_room_ellipsoid_shape(
					along,
					dy,
					outward,
					0,
					0,
					outward_center,
					along_radius * f32(0.68),
					vertical_radius * f32(0.82),
					outward_radius * f32(0.84),
				)
				inward_shape := terrain_density_cave_room_ellipsoid_shape(
					along,
					dy,
					outward,
					0,
					0,
					inward_center,
					along_radius * f32(0.74),
					vertical_radius * f32(0.86),
					outward_radius * f32(0.72),
				)
				branch_a_shape := terrain_density_cave_room_ellipsoid_shape(
					along,
					dy,
					outward,
					branch_center,
					vertical_radius * f32(0.04),
					branch_outward,
					branch_radius_along,
					branch_radius_y,
					branch_radius_outward,
				)
				branch_b_shape := terrain_density_cave_room_ellipsoid_shape(
					along,
					dy,
					outward,
					-branch_center,
					-vertical_radius * f32(0.06),
					branch_outward * f32(0.82),
					branch_radius_along * f32(0.88),
					branch_radius_y * f32(0.92),
					branch_radius_outward,
				)
				branch_a_neck_shape := terrain_density_cave_room_segment_shape(
					along,
					dy,
					outward,
					branch_center * f32(0.26),
					0,
					outward_center * f32(0.86),
					branch_center * f32(0.94),
					vertical_radius * f32(0.03),
					branch_outward * f32(0.94),
					branch_neck_radius_along,
					branch_neck_radius_y,
					branch_neck_radius_outward,
				)
				branch_b_neck_shape := terrain_density_cave_room_segment_shape(
					along,
					dy,
					outward,
					-branch_center * f32(0.26),
					0,
					outward_center * f32(0.72),
					-branch_center * f32(0.92),
					-vertical_radius * f32(0.05),
					branch_outward * f32(0.78),
					branch_neck_radius_along * f32(0.92),
					branch_neck_radius_y * f32(0.92),
					branch_neck_radius_outward,
				)
				shape := terrain_density_cave_room_smooth_min(
					core_shape,
					side_a_shape,
					TERRAIN_CAVE_NODE_MACRO_SATELLITE_CLUSTER_FIELD_BLEND_RADIUS,
				)
				shape = terrain_density_cave_room_smooth_min(
					shape,
					side_b_shape,
					TERRAIN_CAVE_NODE_MACRO_SATELLITE_CLUSTER_FIELD_BLEND_RADIUS,
				)
				shape = terrain_density_cave_room_smooth_min(
					shape,
					outward_shape,
					TERRAIN_CAVE_NODE_MACRO_SATELLITE_CLUSTER_FIELD_BLEND_RADIUS,
				)
				shape = terrain_density_cave_room_smooth_min(
					shape,
					inward_shape,
					TERRAIN_CAVE_NODE_MACRO_SATELLITE_CLUSTER_FIELD_BLEND_RADIUS,
				)
				shape = terrain_density_cave_room_smooth_min(
					shape,
					branch_a_shape,
					TERRAIN_CAVE_NODE_MACRO_SATELLITE_CLUSTER_FIELD_BLEND_RADIUS,
				)
				shape = terrain_density_cave_room_smooth_min(
					shape,
					branch_b_shape,
					TERRAIN_CAVE_NODE_MACRO_SATELLITE_CLUSTER_FIELD_BLEND_RADIUS,
				)
				shape = terrain_density_cave_room_smooth_min(
					shape,
					branch_a_neck_shape,
					TERRAIN_CAVE_NODE_MACRO_SATELLITE_CLUSTER_FIELD_BLEND_RADIUS,
				)
				shape = terrain_density_cave_room_smooth_min(
					shape,
					branch_b_neck_shape,
					TERRAIN_CAVE_NODE_MACRO_SATELLITE_CLUSTER_FIELD_BLEND_RADIUS,
				)
				if shape > f32(1.260001) {
					continue
				}

				if !rough_noise_row_cache_ready {
					rough_noise_row_cache = terrain_value_noise3_row_cache_make(
						key,
						noise_salt,
						18,
						chunk_origin.y + y,
						chunk_origin.z + z,
					)
					rough_noise_row_cache_ready = true
				}
				rough := terrain_value_noise3_row_cache_sample(
					&rough_noise_row_cache,
					chunk_origin.x + x,
				)
				if !detail_noise_row_cache_ready {
					detail_noise_row_cache = terrain_value_noise3_row_cache_make(
						key,
						noise_salt ~ TERRAIN_CAVE_PASSAGE_RIB_SALT,
						9,
						chunk_origin.y + y,
						chunk_origin.z + z,
					)
					detail_noise_row_cache_ready = true
				}
				detail := terrain_value_noise3_row_cache_sample(
					&detail_noise_row_cache,
					chunk_origin.x + x,
				)
				threshold_without_cellular := 1.0 + rough * f32(0.10) + detail * f32(0.08)
				if shape > threshold_without_cellular + f32(0.080001) {
					continue
				}
				cell_size := math.max(
					f32(3.5),
					base_radius * TERRAIN_CAVE_NODE_MACRO_SATELLITE_CLUSTER_FIELD_CELL_SCALE,
				)
				cell_gap := terrain_density_cave_room_worley_gap(
					key,
					world_x,
					world_y,
					world_z,
					cell_size,
					noise_salt,
				)
				cellular_pocket := math.smoothstep(f32(0.36), f32(0.82), cell_gap)
				cellular_ridge := 1.0 - math.smoothstep(f32(0.08), f32(0.28), cell_gap)
				threshold :=
					threshold_without_cellular +
					cellular_pocket * f32(0.08) -
					cellular_ridge * f32(0.06)
				if shape <= threshold {
					terrain_density_carve_checked_local_block_with_material(
						view,
						key,
						chunk_origin,
						columns,
						x,
						y,
						z,
						biome_id,
						true,
						wall_buffer,
					)
				}
			}
		}
	}
}

terrain_density_carve_cave_room :: proc(
	view: ^world_async.ChunkVoxelView,
	key: biomes.FeatureGridKey,
	chunk_origin: world_async.BlockCoord,
	columns: []TerrainBiomeColumn,
	center_x, center_y, center_z, radius_x, radius_y, radius_z: f32,
	kind: biomes.CaveNetworkNodeKind,
	biome_id: biomes.BiomeID,
	wall_buffer: ^TerrainCaveWallMaterialBuffer = nil,
) {
	rx := math.max(f32(2), radius_x)
	ry := math.max(f32(2), radius_y)
	rz := math.max(f32(2), radius_z)
	offset_x := biomes.regional_terrain_field_value_noise_3(
		key,
		i32(math.floor_f32(center_x)),
		i32(math.floor_f32(center_y)),
		i32(math.floor_f32(center_z)),
		56,
		TERRAIN_CAVE_BRANCH_SALT,
	)
	offset_z := biomes.regional_terrain_field_value_noise_3(
		key,
		i32(math.floor_f32(center_x)) + 11,
		i32(math.floor_f32(center_y)),
		i32(math.floor_f32(center_z)) - 7,
		56,
		TERRAIN_CAVE_BRANCH_SALT,
	)
	offset_len := math.sqrt_f32(offset_x * offset_x + offset_z * offset_z)
	if offset_len <= 0.001 {
		offset_x, offset_z = 1, 0
	} else {
		offset_x /= offset_len
		offset_z /= offset_len
	}

	#partial switch biome_id {
	case .Fungal_Vaults:
		terrain_density_carve_cave_room_lobed_ellipsoid(
			view,
			key,
			chunk_origin,
			columns,
			center_x,
			center_y + ry * TERRAIN_FUNGAL_ROOM_LOWER_Y_OFFSET_SCALE,
			center_z,
			rx * TERRAIN_FUNGAL_ROOM_LOWER_XZ_SCALE,
			ry * TERRAIN_FUNGAL_ROOM_LOWER_Y_SCALE,
			rz * TERRAIN_FUNGAL_ROOM_LOWER_XZ_SCALE,
			TERRAIN_CAVE_ROOM_DETAIL_SALT,
			biome_id,
			true,
			wall_buffer,
		)
		terrain_density_carve_cave_room_lobed_ellipsoid(
			view,
			key,
			chunk_origin,
			columns,
			center_x,
			center_y + ry * TERRAIN_FUNGAL_ROOM_DOME_Y_OFFSET_SCALE,
			center_z,
			rx * TERRAIN_FUNGAL_ROOM_DOME_XZ_SCALE,
			ry * TERRAIN_FUNGAL_ROOM_DOME_Y_SCALE,
			rz * TERRAIN_FUNGAL_ROOM_DOME_XZ_SCALE,
			TERRAIN_CAVE_ROOM_DETAIL_SALT,
			biome_id,
			true,
			wall_buffer,
		)
		terrain_density_carve_cave_room_lobed_ellipsoid(
			view,
			key,
			chunk_origin,
			columns,
			center_x + offset_x * rx * TERRAIN_FUNGAL_ROOM_ALCOVE_OFFSET_SCALE,
			center_y + ry * TERRAIN_FUNGAL_ROOM_ALCOVE_Y_OFFSET_SCALE,
			center_z + offset_z * rz * TERRAIN_FUNGAL_ROOM_ALCOVE_OFFSET_SCALE,
			rx * TERRAIN_FUNGAL_ROOM_ALCOVE_XZ_SCALE,
			ry * TERRAIN_FUNGAL_ROOM_ALCOVE_Y_SCALE,
			rz * TERRAIN_FUNGAL_ROOM_ALCOVE_XZ_SCALE,
			TERRAIN_CAVE_DETAIL_SALT,
			biome_id,
			true,
			wall_buffer,
		)
		return
	case .Crystal_Geode_Network:
		terrain_density_carve_cave_room_lobed_ellipsoid(
			view,
			key,
			chunk_origin,
			columns,
			center_x,
			center_y,
			center_z,
			rx * TERRAIN_CRYSTAL_ROOM_MAIN_XZ_SCALE,
			ry * TERRAIN_CRYSTAL_ROOM_MAIN_Y_SCALE,
			rz * TERRAIN_CRYSTAL_ROOM_MAIN_XZ_SCALE,
			TERRAIN_CAVE_PASSAGE_RIB_SALT,
			biome_id,
			true,
			wall_buffer,
		)
		terrain_density_carve_rough_segment_shaped(
			view,
			key,
			chunk_origin,
			columns,
			center_x - offset_x * rx * 0.72,
			center_y - ry * TERRAIN_CRYSTAL_ROOM_FISSURE_LOWER_Y_SCALE,
			center_z - offset_z * rz * 0.72,
			center_x + offset_x * rx * 0.84,
			center_y + ry * TERRAIN_CRYSTAL_ROOM_FISSURE_UPPER_Y_SCALE,
			center_z + offset_z * rz * 0.84,
			math.max(f32(2.5), math.min(rx, rz) * TERRAIN_CRYSTAL_ROOM_FISSURE_RADIUS_SCALE),
			terrain_density_cave_passage_shape(.Fracture),
			TERRAIN_CAVE_PASSAGE_RIB_SALT,
			biome_id,
			true,
			wall_buffer,
		)
		return
	case .Buried_Aquifer_Caves:
		terrain_density_carve_cave_room_lobed_ellipsoid(
			view,
			key,
			chunk_origin,
			columns,
			center_x,
			center_y + ry * TERRAIN_AQUIFER_ROOM_BASIN_Y_OFFSET_SCALE,
			center_z,
			rx * TERRAIN_AQUIFER_ROOM_BASIN_XZ_SCALE,
			ry * TERRAIN_AQUIFER_ROOM_BASIN_Y_SCALE,
			rz * TERRAIN_AQUIFER_ROOM_BASIN_XZ_SCALE,
			TERRAIN_CAVE_FIELD_DETAIL_SALT,
			biome_id,
			true,
			wall_buffer,
		)
		terrain_density_carve_cave_room_lobed_ellipsoid(
			view,
			key,
			chunk_origin,
			columns,
			center_x + offset_x * rx * TERRAIN_AQUIFER_ROOM_SHELF_OFFSET_SCALE,
			center_y + ry * TERRAIN_AQUIFER_ROOM_SHELF_Y_OFFSET_SCALE,
			center_z + offset_z * rz * TERRAIN_AQUIFER_ROOM_SHELF_OFFSET_SCALE,
			rx * TERRAIN_AQUIFER_ROOM_SHELF_XZ_SCALE,
			ry * TERRAIN_AQUIFER_ROOM_SHELF_Y_SCALE,
			rz * TERRAIN_AQUIFER_ROOM_SHELF_XZ_SCALE,
			TERRAIN_CAVE_ROOM_DETAIL_SALT,
			biome_id,
			true,
			wall_buffer,
		)
		terrain_density_carve_cave_room_lobed_ellipsoid(
			view,
			key,
			chunk_origin,
			columns,
			center_x - offset_x * rx * TERRAIN_AQUIFER_ROOM_MIRROR_SHELF_OFFSET_SCALE,
			center_y + ry * TERRAIN_AQUIFER_ROOM_MIRROR_SHELF_Y_OFFSET_SCALE,
			center_z - offset_z * rz * TERRAIN_AQUIFER_ROOM_MIRROR_SHELF_OFFSET_SCALE,
			rx * TERRAIN_AQUIFER_ROOM_MIRROR_SHELF_XZ_SCALE,
			ry * TERRAIN_AQUIFER_ROOM_MIRROR_SHELF_Y_SCALE,
			rz * TERRAIN_AQUIFER_ROOM_MIRROR_SHELF_XZ_SCALE,
			TERRAIN_CAVE_PASSAGE_RIB_SALT,
			biome_id,
			true,
			wall_buffer,
		)
		side_x := -offset_z
		side_z := offset_x
		crescent_shape := terrain_density_cave_passage_shape(.Flooded_Passage)
		crescent_shape.radius_y_scale = math.min(
			crescent_shape.radius_y_scale,
			TERRAIN_AQUIFER_ROOM_CRESCENT_Y_SCALE,
		)
		crescent_shape.radius_neck_scale = math.max(crescent_shape.radius_neck_scale, f32(0.18))
		crescent_shape.radius_endpoint_scale = math.max(
			crescent_shape.radius_endpoint_scale,
			f32(0.08),
		)
		terrain_density_cave_passage_shape_apply_biome(&crescent_shape, biome_id)
		crescent_radius := math.clamp(
			math.min(rx, rz) * TERRAIN_AQUIFER_ROOM_CRESCENT_RADIUS_SCALE,
			TERRAIN_AQUIFER_ROOM_CRESCENT_RADIUS_MIN_BLOCKS,
			TERRAIN_AQUIFER_ROOM_CRESCENT_RADIUS_MAX_BLOCKS,
		)
		crescent_y := center_y + ry * TERRAIN_AQUIFER_ROOM_CRESCENT_Y_OFFSET_SCALE
		crescent_forward_x := offset_x * rx * TERRAIN_AQUIFER_ROOM_CRESCENT_FORWARD_SCALE
		crescent_forward_z := offset_z * rz * TERRAIN_AQUIFER_ROOM_CRESCENT_FORWARD_SCALE
		crescent_side_x := side_x * rx * TERRAIN_AQUIFER_ROOM_CRESCENT_SIDE_OFFSET_SCALE
		crescent_side_z := side_z * rz * TERRAIN_AQUIFER_ROOM_CRESCENT_SIDE_OFFSET_SCALE
		side_shelf_radius := math.clamp(
			math.min(rx, rz) * TERRAIN_AQUIFER_ROOM_SIDE_SHELF_XZ_SCALE,
			f32(2.4),
			TERRAIN_AQUIFER_ROOM_CRESCENT_RADIUS_MAX_BLOCKS,
		)
		side_shelf_y := center_y + ry * TERRAIN_AQUIFER_ROOM_SIDE_SHELF_Y_OFFSET_SCALE
		side_shelf_shape := crescent_shape
		side_shelf_shape.radius_y_scale = math.min(
			side_shelf_shape.radius_y_scale,
			TERRAIN_AQUIFER_ROOM_SIDE_SHELF_Y_SCALE,
		)
		terrain_density_carve_rough_segment_shaped(
			view,
			key,
			chunk_origin,
			columns,
			center_x - side_x * rx * TERRAIN_AQUIFER_ROOM_SIDE_SHELF_OFFSET_SCALE,
			side_shelf_y,
			center_z - side_z * rz * TERRAIN_AQUIFER_ROOM_SIDE_SHELF_OFFSET_SCALE,
			center_x + side_x * rx * TERRAIN_AQUIFER_ROOM_SIDE_SHELF_OFFSET_SCALE,
			side_shelf_y + ry * f32(0.02),
			center_z + side_z * rz * TERRAIN_AQUIFER_ROOM_SIDE_SHELF_OFFSET_SCALE,
			side_shelf_radius,
			side_shelf_shape,
			TERRAIN_CAVE_DETAIL_SALT,
			biome_id,
			true,
			wall_buffer,
		)
		terrain_density_carve_rough_segment_shaped(
			view,
			key,
			chunk_origin,
			columns,
			center_x - crescent_forward_x + crescent_side_x,
			crescent_y,
			center_z - crescent_forward_z + crescent_side_z,
			center_x + crescent_forward_x + crescent_side_x,
			crescent_y + ry * f32(0.04),
			center_z + crescent_forward_z + crescent_side_z,
			crescent_radius,
			crescent_shape,
			TERRAIN_CAVE_FIELD_DETAIL_SALT,
			biome_id,
			true,
			wall_buffer,
		)
		terrain_density_carve_rough_segment_shaped(
			view,
			key,
			chunk_origin,
			columns,
			center_x + crescent_forward_x - crescent_side_x,
			crescent_y - ry * f32(0.03),
			center_z + crescent_forward_z - crescent_side_z,
			center_x - crescent_forward_x - crescent_side_x,
			crescent_y + ry * f32(0.02),
			center_z - crescent_forward_z - crescent_side_z,
			crescent_radius * f32(0.86),
			crescent_shape,
			TERRAIN_CAVE_ROOM_DETAIL_SALT,
			biome_id,
			true,
			wall_buffer,
		)
		terrain_density_fill_water_ellipsoid(
			view,
			chunk_origin,
			center_x,
			center_y + ry * TERRAIN_AQUIFER_ROOM_WATER_Y_OFFSET_SCALE,
			center_z,
			rx * TERRAIN_AQUIFER_ROOM_WATER_XZ_SCALE,
			math.max(f32(1.5), ry * TERRAIN_AQUIFER_ROOM_WATER_Y_SCALE),
			rz * TERRAIN_AQUIFER_ROOM_WATER_XZ_SCALE,
		)
		return
	}

	if kind == .Vertical_Shaft {
		terrain_density_carve_cave_room_lobed_ellipsoid(
			view,
			key,
			chunk_origin,
			columns,
			center_x,
			center_y,
			center_z,
			rx * 0.55,
			ry,
			rz * 0.55,
			TERRAIN_CAVE_ROUGHNESS_SALT,
			biome_id,
			true,
			wall_buffer,
		)
		return
	}
	terrain_density_carve_cave_room_lobed_ellipsoid(
		view,
		key,
		chunk_origin,
		columns,
		center_x,
		center_y,
		center_z,
		rx,
		ry,
		rz,
		TERRAIN_CAVE_ROUGHNESS_SALT,
		biome_id,
		true,
		wall_buffer,
	)
}

terrain_density_cave_room_ellipsoid_shape :: proc(
	along, y, across: f32,
	center_along, center_y, center_across: f32,
	radius_along, radius_y, radius_across: f32,
) -> f32 {
	da := (along - center_along) / radius_along
	dy := (y - center_y) / radius_y
	dc := (across - center_across) / radius_across
	return da * da + dy * dy + dc * dc
}

terrain_density_cave_room_segment_shape :: proc(
	along, y, across: f32,
	from_along, from_y, from_across: f32,
	to_along, to_y, to_across: f32,
	radius_along, radius_y, radius_across: f32,
) -> f32 {
	segment_along := to_along - from_along
	segment_y := to_y - from_y
	segment_across := to_across - from_across
	segment_length_sq :=
		segment_along * segment_along + segment_y * segment_y + segment_across * segment_across
	t := f32(0)
	if segment_length_sq > 0.0001 {
		rel_along := along - from_along
		rel_y := y - from_y
		rel_across := across - from_across
		t =
			(rel_along * segment_along + rel_y * segment_y + rel_across * segment_across) /
			segment_length_sq
		t = math.clamp(t, f32(0), f32(1))
	}
	center_along := biomes.regional_terrain_field_lerp(from_along, to_along, t)
	center_y := biomes.regional_terrain_field_lerp(from_y, to_y, t)
	center_across := biomes.regional_terrain_field_lerp(from_across, to_across, t)
	return terrain_density_cave_room_ellipsoid_shape(
		along,
		y,
		across,
		center_along,
		center_y,
		center_across,
		radius_along,
		radius_y,
		radius_across,
	)
}

terrain_density_cave_room_smooth_min :: proc(a, b, blend_radius: f32) -> f32 {
	if blend_radius <= 0 {
		return math.min(a, b)
	}
	h := math.clamp(f32(0.5) + f32(0.5) * (b - a) / blend_radius, f32(0), f32(1))
	return biomes.regional_terrain_field_lerp(b, a, h) - blend_radius * h * (1.0 - h)
}

terrain_density_cave_major_room_perimeter_shape :: proc(
	along, y, across: f32,
	biome_id: biomes.BiomeID,
) -> f32 {
	side_center := TERRAIN_CAVE_NODE_MAJOR_ROOM_FIELD_SIDE_CENTER_SCALE
	side_across := TERRAIN_CAVE_NODE_MAJOR_ROOM_FIELD_SIDE_ACROSS_SCALE
	side_radius_along := TERRAIN_CAVE_NODE_MAJOR_ROOM_FIELD_SIDE_RADIUS_SCALE
	side_radius_y := f32(0.38)
	side_radius_across := f32(0.34)
	connector_radius := TERRAIN_CAVE_NODE_MAJOR_ROOM_FIELD_CONNECTOR_RADIUS_SCALE
	lower_center_y := f32(-0.56)
	lower_radius_along := f32(0.52)
	lower_radius_y := f32(0.28)
	lower_radius_across := f32(0.40)
	upper_center_y := f32(0.66)
	upper_radius_along := f32(0.36)
	upper_radius_y := f32(0.36)
	upper_radius_across := f32(0.28)

	#partial switch biome_id {
	case .Fungal_Vaults:
		side_radius_along *= 1.16
		side_radius_y *= 0.96
		side_radius_across *= 1.14
		connector_radius *= 1.06
		lower_center_y = -0.50
		lower_radius_along *= 1.18
		lower_radius_y *= 1.08
		lower_radius_across *= 1.16
		upper_radius_y *= 0.82
	case .Crystal_Geode_Network:
		side_radius_along *= 0.72
		side_radius_y *= 1.42
		side_radius_across *= 0.74
		connector_radius *= 0.86
		lower_radius_along *= 0.76
		lower_radius_y *= 0.82
		lower_radius_across *= 0.72
		upper_center_y = 0.74
		upper_radius_along *= 0.86
		upper_radius_y *= 1.54
		upper_radius_across *= 0.76
	case .Buried_Aquifer_Caves:
		side_radius_along *= 1.28
		side_radius_y *= 0.62
		side_radius_across *= 1.24
		connector_radius *= 1.10
		lower_center_y = -0.44
		lower_radius_along *= 1.32
		lower_radius_y *= 0.74
		lower_radius_across *= 1.26
		upper_radius_along *= 0.72
		upper_radius_y *= 0.66
		upper_radius_across *= 0.72
	case .Temperate_Hills, .Basalt_Spire_Highlands, .Wet_Lowland_Marsh, .Corrupted_Ash_Forest:
	}

	side_a_shape :=
		terrain_density_cave_room_ellipsoid_shape(
			along,
			y,
			across,
			side_center,
			-0.04,
			side_across,
			side_radius_along,
			side_radius_y,
			side_radius_across,
		) *
		f32(0.94)
	side_b_shape :=
		terrain_density_cave_room_ellipsoid_shape(
			along,
			y,
			across,
			-side_center * f32(0.88),
			0.05,
			-side_across * f32(0.82),
			side_radius_along * f32(0.92),
			side_radius_y,
			side_radius_across * f32(0.94),
		) *
		f32(0.98)
	connector_a_shape := terrain_density_cave_room_segment_shape(
		along,
		y,
		across,
		side_center * f32(0.44),
		-0.02,
		side_across * f32(0.36),
		side_center * f32(0.92),
		-0.04,
		side_across * f32(0.92),
		connector_radius,
		connector_radius * f32(1.08),
		connector_radius * f32(0.88),
	)
	connector_b_shape := terrain_density_cave_room_segment_shape(
		along,
		y,
		across,
		-side_center * f32(0.38),
		0.02,
		-side_across * f32(0.30),
		-side_center * f32(0.78),
		0.05,
		-side_across * f32(0.76),
		connector_radius * f32(0.92),
		connector_radius,
		connector_radius * f32(0.82),
	)
	lower_shape :=
		terrain_density_cave_room_ellipsoid_shape(
			along,
			y,
			across,
			-side_center * f32(0.18),
			lower_center_y,
			side_across * f32(0.54),
			lower_radius_along,
			lower_radius_y,
			lower_radius_across,
		) *
		f32(0.98)
	upper_shape :=
		terrain_density_cave_room_ellipsoid_shape(
			along,
			y,
			across,
			side_center * f32(0.22),
			upper_center_y,
			-side_across * f32(0.24),
			upper_radius_along,
			upper_radius_y,
			upper_radius_across,
		) *
		f32(1.02)

	shape := terrain_density_cave_room_smooth_min(
		side_a_shape,
		connector_a_shape,
		TERRAIN_CAVE_NODE_MAJOR_ROOM_FIELD_BLEND_RADIUS,
	)
	shape = terrain_density_cave_room_smooth_min(
		shape,
		side_b_shape,
		TERRAIN_CAVE_NODE_MAJOR_ROOM_FIELD_BLEND_RADIUS,
	)
	shape = terrain_density_cave_room_smooth_min(
		shape,
		connector_b_shape,
		TERRAIN_CAVE_NODE_MAJOR_ROOM_FIELD_BLEND_RADIUS,
	)
	shape = terrain_density_cave_room_smooth_min(
		shape,
		lower_shape,
		TERRAIN_CAVE_NODE_MAJOR_ROOM_FIELD_BLEND_RADIUS,
	)
	return terrain_density_cave_room_smooth_min(
		shape,
		upper_shape,
		TERRAIN_CAVE_NODE_MAJOR_ROOM_FIELD_BLEND_RADIUS,
	)
}

terrain_density_cave_room_compound_shape :: proc(
	along, y, across: f32,
	biome_id: biomes.BiomeID,
) -> f32 {
	base_shape := along * along + y * y + across * across
	base_radius := math.sqrt_f32(base_shape)
	edge_support := math.smoothstep(f32(0.46), f32(0.98), base_radius)
	core_contraction := TERRAIN_CAVE_ROOM_COMPOUND_CORE_CONTRACTION
	if biome_id == .Buried_Aquifer_Caves {
		core_contraction *= 0.55
	}
	compound_shape := base_shape + edge_support * core_contraction

	primary_center_along := f32(0.42)
	primary_center_y := f32(-0.04)
	primary_center_across := f32(-0.20)
	primary_radius_along := f32(0.68)
	primary_radius_y := f32(0.72)
	primary_radius_across := f32(0.50)
	secondary_center_along := f32(-0.18)
	secondary_center_y := f32(0.06)
	secondary_center_across := f32(0.42)
	secondary_radius_along := f32(0.56)
	secondary_radius_y := f32(0.62)
	secondary_radius_across := f32(0.44)
	back_center_along := f32(-0.48)
	back_center_y := f32(-0.02)
	back_center_across := f32(-0.18)
	back_radius_along := f32(0.46)
	back_radius_y := f32(0.52)
	back_radius_across := f32(0.34)
	side_gallery_center_along := f32(0.58)
	side_gallery_center_y := f32(-0.06)
	side_gallery_center_across := f32(0.54)
	side_gallery_radius_along := f32(0.38)
	side_gallery_radius_y := f32(0.50)
	side_gallery_radius_across := f32(0.30)
	rear_alcove_center_along := f32(-0.58)
	rear_alcove_center_y := f32(0.02)
	rear_alcove_center_across := f32(-0.50)
	rear_alcove_radius_along := f32(0.32)
	rear_alcove_radius_y := f32(0.44)
	rear_alcove_radius_across := f32(0.28)

	#partial switch biome_id {
	case .Fungal_Vaults:
		primary_center_y = -0.10
		primary_radius_along = 0.78
		primary_radius_y = 0.66
		primary_radius_across = 0.60
		secondary_center_across = 0.48
		secondary_radius_along = 0.62
		secondary_radius_y = 0.58
		secondary_radius_across = 0.54
		side_gallery_radius_along = 0.46
		side_gallery_radius_y = 0.44
		side_gallery_radius_across = 0.38
		rear_alcove_center_y = -0.08
		rear_alcove_radius_across = 0.34
	case .Crystal_Geode_Network:
		primary_center_y = 0.08
		primary_radius_along = 0.56
		primary_radius_y = 0.88
		primary_radius_across = 0.32
		secondary_center_along = -0.10
		secondary_center_across = 0.34
		secondary_radius_along = 0.46
		secondary_radius_y = 0.82
		secondary_radius_across = 0.30
		back_radius_across = 0.26
		side_gallery_center_y = 0.12
		side_gallery_radius_along = 0.30
		side_gallery_radius_y = 0.74
		side_gallery_radius_across = 0.22
		rear_alcove_radius_along = 0.24
		rear_alcove_radius_y = 0.66
		rear_alcove_radius_across = 0.20
	case .Buried_Aquifer_Caves:
		primary_center_along = 0.30
		primary_center_y = -0.20
		primary_center_across = -0.26
		primary_radius_along = 0.82
		primary_radius_y = 0.42
		primary_radius_across = 0.60
		secondary_center_y = -0.10
		secondary_radius_along = 0.66
		secondary_radius_y = 0.38
		secondary_radius_across = 0.54
		side_gallery_center_y = -0.24
		side_gallery_radius_along = 0.52
		side_gallery_radius_y = 0.28
		side_gallery_radius_across = 0.40
		rear_alcove_center_y = -0.18
		rear_alcove_radius_y = 0.30
		rear_alcove_radius_across = 0.36
	case .Temperate_Hills, .Basalt_Spire_Highlands, .Wet_Lowland_Marsh, .Corrupted_Ash_Forest:
	}

	primary_shape :=
		terrain_density_cave_room_ellipsoid_shape(
			along,
			y,
			across,
			primary_center_along,
			primary_center_y,
			primary_center_across,
			primary_radius_along,
			primary_radius_y,
			primary_radius_across,
		) *
		TERRAIN_CAVE_ROOM_COMPOUND_PRIMARY_LOBE_BIAS
	secondary_shape :=
		terrain_density_cave_room_ellipsoid_shape(
			along,
			y,
			across,
			secondary_center_along,
			secondary_center_y,
			secondary_center_across,
			secondary_radius_along,
			secondary_radius_y,
			secondary_radius_across,
		) *
		TERRAIN_CAVE_ROOM_COMPOUND_SECONDARY_LOBE_BIAS
	back_shape :=
		terrain_density_cave_room_ellipsoid_shape(
			along,
			y,
			across,
			back_center_along,
			back_center_y,
			back_center_across,
			back_radius_along,
			back_radius_y,
			back_radius_across,
		) *
		TERRAIN_CAVE_ROOM_COMPOUND_BACK_LOBE_BIAS
	side_gallery_shape :=
		terrain_density_cave_room_ellipsoid_shape(
			along,
			y,
			across,
			side_gallery_center_along,
			side_gallery_center_y,
			side_gallery_center_across,
			side_gallery_radius_along,
			side_gallery_radius_y,
			side_gallery_radius_across,
		) *
		TERRAIN_CAVE_ROOM_COMPOUND_SIDE_GALLERY_BIAS
	rear_alcove_shape :=
		terrain_density_cave_room_ellipsoid_shape(
			along,
			y,
			across,
			rear_alcove_center_along,
			rear_alcove_center_y,
			rear_alcove_center_across,
			rear_alcove_radius_along,
			rear_alcove_radius_y,
			rear_alcove_radius_across,
		) *
		TERRAIN_CAVE_ROOM_COMPOUND_REAR_ALCOVE_BIAS
	compound_shape = terrain_density_cave_room_smooth_min(
		compound_shape,
		primary_shape,
		TERRAIN_CAVE_ROOM_COMPOUND_BLEND_RADIUS,
	)
	compound_shape = terrain_density_cave_room_smooth_min(
		compound_shape,
		secondary_shape,
		TERRAIN_CAVE_ROOM_COMPOUND_BLEND_RADIUS,
	)
	compound_shape = terrain_density_cave_room_smooth_min(
		compound_shape,
		side_gallery_shape,
		TERRAIN_CAVE_ROOM_COMPOUND_BLEND_RADIUS,
	)
	compound_shape = terrain_density_cave_room_smooth_min(
		compound_shape,
		rear_alcove_shape,
		TERRAIN_CAVE_ROOM_COMPOUND_BLEND_RADIUS,
	)
	return terrain_density_cave_room_smooth_min(
		compound_shape,
		back_shape,
		TERRAIN_CAVE_ROOM_COMPOUND_BLEND_RADIUS,
	)
}

terrain_density_carve_cave_room_lobed_ellipsoid :: proc(
	view: ^world_async.ChunkVoxelView,
	key: biomes.FeatureGridKey,
	chunk_origin: world_async.BlockCoord,
	columns: []TerrainBiomeColumn,
	center_x, center_y, center_z, radius_x, radius_y, radius_z: f32,
	noise_salt: u64,
	biome_id: biomes.BiomeID,
	directional_material_profile: bool = false,
	wall_buffer: ^TerrainCaveWallMaterialBuffer = nil,
) {
	rx := math.max(f32(1), radius_x)
	ry := math.max(f32(1), radius_y)
	rz := math.max(f32(1), radius_z)
	padding := math.max(rx, math.max(ry, rz)) * 0.26 + 2
	local_min_x, local_max_x, local_min_y, local_max_y, local_min_z, local_max_z, intersects :=
		terrain_density_carve_bounds_from_extents(
			chunk_origin,
			center_x - rx - padding,
			center_x + rx + padding,
			center_y - ry - padding,
			center_y + ry + padding,
			center_z - rz - padding,
			center_z + rz + padding,
		)
	if !intersects {
		return
	}

	internal_structure_active :=
		math.min(rx, math.min(ry, rz)) >= TERRAIN_CAVE_ROOM_INTERNAL_STRUCTURE_MIN_RADIUS
	compound_room_active := math.min(rx, math.min(ry, rz)) >= TERRAIN_CAVE_ROOM_COMPOUND_MIN_RADIUS
	axis_x := biomes.regional_terrain_field_value_noise_3(
		key,
		i32(math.floor_f32(center_x)),
		i32(math.floor_f32(center_y)),
		i32(math.floor_f32(center_z)),
		64,
		TERRAIN_CAVE_BRANCH_SALT,
	)
	axis_z := biomes.regional_terrain_field_value_noise_3(
		key,
		i32(math.floor_f32(center_x)) + 17,
		i32(math.floor_f32(center_y)) - 5,
		i32(math.floor_f32(center_z)) + 23,
		64,
		TERRAIN_CAVE_ROOM_DETAIL_SALT,
	)
	axis_len := math.sqrt_f32(axis_x * axis_x + axis_z * axis_z)
	if axis_len <= 0.001 {
		axis_x, axis_z = 1, 0
	} else {
		axis_x /= axis_len
		axis_z /= axis_len
	}

	for z := local_min_z; z <= local_max_z; z += 1 {
		world_z := f32(chunk_origin.z + z) + 0.5
		nz := (world_z - center_z) / rz
		nz_sq := nz * nz
		for y := local_min_y; y <= local_max_y; y += 1 {
			world_y := f32(chunk_origin.y + y) + 0.5
			ny := (world_y - center_y) / ry
			ny_sq := ny * ny
			row_min_x, row_max_x, row_intersects := terrain_density_ellipsoid_row_x_bounds(
				chunk_origin,
				local_min_x,
				local_max_x,
				center_x,
				rx,
				ny_sq + nz_sq,
				TERRAIN_CAVE_ROOM_PRE_NOISE_OUTER_SHAPE_MAX,
			)
			if !row_intersects {
				continue
			}
			rough_noise_row_cache: TerrainValueNoise3RowCache
			rough_noise_row_cache_ready := false
			detail_noise_row_cache: TerrainValueNoise3RowCache
			detail_noise_row_cache_ready := false
			for x := row_min_x; x <= row_max_x; x += 1 {
				if !terrain_density_local_block_can_carve(view, x, y, z) {
					continue
				}
				world_x := f32(chunk_origin.x + x) + 0.5
				nx := (world_x - center_x) / rx
				outer_shape := nx * nx + ny * ny + nz * nz
				if outer_shape > TERRAIN_CAVE_ROOM_PRE_NOISE_OUTER_SHAPE_MAX {
					continue
				}
				if !rough_noise_row_cache_ready {
					rough_noise_row_cache = terrain_value_noise3_row_cache_make(
						key,
						noise_salt,
						24,
						chunk_origin.y + y,
						chunk_origin.z + z,
					)
					rough_noise_row_cache_ready = true
				}
				rough := terrain_value_noise3_row_cache_sample(
					&rough_noise_row_cache,
					chunk_origin.x + x,
				)
				if !detail_noise_row_cache_ready {
					detail_noise_row_cache = terrain_value_noise3_row_cache_make(
						key,
						noise_salt ~ TERRAIN_CAVE_PASSAGE_RIB_SALT,
						10,
						chunk_origin.y + y,
						chunk_origin.z + z,
					)
					detail_noise_row_cache_ready = true
				}
				detail := terrain_value_noise3_row_cache_sample(
					&detail_noise_row_cache,
					chunk_origin.x + x,
				)
				along := nx * axis_x + nz * axis_z
				across := nx * -axis_z + nz * axis_x
				radial := math.sqrt_f32(along * along + across * across)
				wall_support :=
					math.smoothstep(f32(0.18), f32(1.08), radial) *
					(1.0 - math.smoothstep(f32(0.76), f32(1.12), math.abs(ny)))
				core_shelf := 1.0 - math.smoothstep(f32(0.62), f32(1.02), radial)
				warped_along :=
					along +
					detail *
						TERRAIN_CAVE_ROOM_COORD_WARP_SCALE *
						wall_support *
						(0.80 + math.abs(across) * 0.28)
				warped_across :=
					across -
					rough *
						TERRAIN_CAVE_ROOM_COORD_WARP_SCALE *
						wall_support *
						(0.72 + math.abs(along) * 0.24)
				warped_y := ny + detail * TERRAIN_CAVE_ROOM_VERTICAL_WARP_SCALE * core_shelf
				base_shape :=
					warped_along * warped_along +
					warped_y * warped_y +
					warped_across * warped_across
				shape := base_shape
				if compound_room_active {
					shape = terrain_density_cave_room_compound_shape(
						warped_along,
						warped_y,
						warped_across,
						biome_id,
					)
				}
				core_support := math.clamp((f32(1.0) - shape) * 1.389, f32(0), f32(1))
				rough_scale :=
					TERRAIN_CAVE_ROUGH_ELLIPSOID_EDGE_SCALE -
					(TERRAIN_CAVE_ROUGH_ELLIPSOID_EDGE_SCALE -
							TERRAIN_CAVE_ROUGH_ELLIPSOID_CORE_SCALE) *
						core_support
				lobe_adjust := terrain_density_cave_room_lobe_threshold_adjust(
					nx,
					ny,
					nz,
					axis_x,
					axis_z,
				)
				strata_adjust := terrain_density_cave_room_strata_threshold_adjust(
					warped_y,
					radial,
					warped_along,
					warped_across,
					rough,
					detail,
					biome_id,
				)
				threshold_without_cellular :=
					1.0 +
					(rough * 0.68 + detail * 0.32) * rough_scale +
					detail * TERRAIN_CAVE_ROOM_SCALLOP_SCALE * wall_support +
					lobe_adjust +
					strata_adjust
				if shape >
				   threshold_without_cellular +
					   TERRAIN_CAVE_ROOM_CELLULAR_POCKET_SCALE * wall_support +
					   f32(0.000001) {
					continue
				}
				cellular_ridge := f32(0)
				cellular_pocket := f32(0)
				if wall_support > 0.001 {
					cell_size := math.max(
						TERRAIN_CAVE_ROOM_CELLULAR_CELL_MIN_BLOCKS,
						math.min(rx, rz) * TERRAIN_CAVE_ROOM_CELLULAR_CELL_SCALE,
					)
					cellular_gap := terrain_density_cave_room_worley_gap(
						key,
						world_x,
						world_y,
						world_z,
						cell_size,
						noise_salt,
					)
					cellular_ridge =
						(1.0 - math.smoothstep(f32(0.08), f32(0.30), cellular_gap)) * wall_support
					cellular_pocket =
						math.smoothstep(f32(0.38), f32(0.78), cellular_gap) * wall_support
				}
				threshold :=
					threshold_without_cellular +
					cellular_pocket * TERRAIN_CAVE_ROOM_CELLULAR_POCKET_SCALE -
					cellular_ridge * TERRAIN_CAVE_ROOM_CELLULAR_RIDGE_SCALE
				if shape <= threshold {
					if internal_structure_active &&
					   terrain_density_cave_room_internal_structure_preserves(
						   nx,
						   ny,
						   nz,
						   rx,
						   ry,
						   rz,
						   axis_x,
						   axis_z,
						   rough,
						   biome_id,
					   ) {
						continue
					}
					terrain_density_carve_checked_local_block_with_material(
						view,
						key,
						chunk_origin,
						columns,
						x,
						y,
						z,
						biome_id,
						directional_material_profile,
						wall_buffer,
					)
				}
			}
		}
	}
}

terrain_density_cave_room_worley_gap :: proc(
	key: biomes.FeatureGridKey,
	world_x, world_y, world_z, cell_size: f32,
	noise_salt: u64,
) -> f32 {
	cell_x := i32(math.floor_f32(world_x / cell_size))
	cell_y := i32(math.floor_f32(world_y / cell_size))
	cell_z := i32(math.floor_f32(world_z / cell_size))
	nearest_sq := max(f32)
	second_sq := max(f32)

	for oz := i32(-1); oz <= 1; oz += 1 {
		for oy := i32(-1); oy <= 1; oy += 1 {
			for ox := i32(-1); ox <= 1; ox += 1 {
				feature_cell_x := cell_x + ox
				feature_cell_y := cell_y + oy
				feature_cell_z := cell_z + oz
				hash := biomes.feature_grid_hash_mix(key.world_seed)
				hash = biomes.feature_grid_hash_combine(hash, u64(key.generator_version))
				hash = biomes.feature_grid_hash_combine(hash, noise_salt)
				hash = biomes.feature_grid_hash_combine(
					hash,
					biomes.feature_grid_hash_i32(feature_cell_x),
				)
				hash = biomes.feature_grid_hash_combine(
					hash,
					biomes.feature_grid_hash_i32(feature_cell_y),
				)
				hash = biomes.feature_grid_hash_combine(
					hash,
					biomes.feature_grid_hash_i32(feature_cell_z),
				)
				feature_x :=
					(f32(feature_cell_x) +
						biomes.feature_grid_unit_f32(hash, TERRAIN_CAVE_BRANCH_SALT)) *
					cell_size
				feature_y :=
					(f32(feature_cell_y) +
						biomes.feature_grid_unit_f32(hash, TERRAIN_CAVE_ROOM_DETAIL_SALT)) *
					cell_size
				feature_z :=
					(f32(feature_cell_z) +
						biomes.feature_grid_unit_f32(hash, TERRAIN_CAVE_PASSAGE_RIB_SALT)) *
					cell_size
				dx := world_x - feature_x
				dy := world_y - feature_y
				dz := world_z - feature_z
				distance_sq := dx * dx + dy * dy + dz * dz
				if distance_sq < nearest_sq {
					second_sq = nearest_sq
					nearest_sq = distance_sq
				} else if distance_sq < second_sq {
					second_sq = distance_sq
				}
			}
		}
	}

	if second_sq <= nearest_sq {
		return 1
	}
	gap := (math.sqrt_f32(second_sq) - math.sqrt_f32(nearest_sq)) / cell_size
	return math.clamp(gap, f32(0), f32(1))
}

terrain_density_cave_room_internal_structure_preserves :: proc(
	nx, ny, nz, rx, ry, rz, axis_x, axis_z, rough: f32,
	biome_id: biomes.BiomeID,
) -> bool {
	min_radius := math.min(rx, math.min(ry, rz))
	if min_radius < TERRAIN_CAVE_ROOM_INTERNAL_STRUCTURE_MIN_RADIUS {
		return false
	}

	shape := nx * nx + ny * ny + nz * nz
	if shape < 0.05 || shape > 0.94 {
		return false
	}

	along := nx * axis_x + nz * axis_z
	across := nx * -axis_z + nz * axis_x
	along_abs := math.abs(along)
	across_abs := math.abs(across)
	vertical_column := 1.0 - math.smoothstep(f32(0.72), f32(0.98), math.abs(ny))
	positive_rough := math.smoothstep(f32(0.02), f32(0.48), rough)
	if vertical_column <= 0 || positive_rough <= 0 {
		return false
	}

	strength := f32(0)
	#partial switch biome_id {
	case .Fungal_Vaults:
		side_root :=
			math.clamp(1.0 - math.abs(across_abs - f32(0.42)) * f32(5.0), f32(0), f32(1)) *
			(1.0 - math.smoothstep(f32(0.62), f32(0.94), along_abs))
		center_root :=
			math.clamp(1.0 - math.abs(across_abs - f32(0.14)) * f32(6.4), f32(0), f32(1)) *
			(1.0 - math.smoothstep(f32(0.34), f32(0.86), along_abs))
		inner_curtain :=
			math.clamp(1.0 - math.abs(across_abs - f32(0.07)) * f32(8.0), f32(0), f32(1)) *
			(1.0 - math.smoothstep(f32(0.22), f32(0.76), along_abs))
		outer_curtain :=
			math.clamp(1.0 - math.abs(across_abs - f32(0.58)) * f32(4.2), f32(0), f32(1)) *
			(1.0 - math.smoothstep(f32(0.50), f32(0.96), along_abs))
		strength =
			math.max(
				math.max(side_root, center_root * f32(1.05)),
				math.max(inner_curtain * f32(0.84), outer_curtain * f32(0.58)),
			) *
			vertical_column *
			positive_rough
		return strength > 0.28
	case .Crystal_Geode_Network:
		crystal_blade :=
			math.clamp(1.0 - math.abs(across_abs - f32(0.26)) * f32(7.0), f32(0), f32(1)) *
			(1.0 - math.smoothstep(f32(0.70), f32(0.96), along_abs))
		inner_splinter :=
			math.clamp(1.0 - math.abs(across_abs - f32(0.12)) * f32(9.4), f32(0), f32(1)) *
			(1.0 - math.smoothstep(f32(0.42), f32(0.88), along_abs))
		outer_splinter :=
			math.clamp(1.0 - math.abs(across_abs - f32(0.46)) * f32(4.8), f32(0), f32(1)) *
			(1.0 - math.smoothstep(f32(0.58), f32(0.96), along_abs))
		strength =
			math.max(
				crystal_blade * f32(1.12),
				math.max(inner_splinter * f32(1.02), outer_splinter * f32(0.82)),
			) *
			vertical_column *
			positive_rough
		return strength > 0.26
	case .Buried_Aquifer_Caves:
		lower_island := math.smoothstep(f32(0.12), f32(0.58), -ny)
		island_band :=
			math.clamp(1.0 - math.abs(across_abs - f32(0.32)) * f32(5.2), f32(0), f32(1)) *
			(1.0 - math.smoothstep(f32(0.50), f32(0.88), along_abs))
		strength = island_band * lower_island * positive_rough
		return strength > 0.32
	case .Temperate_Hills, .Basalt_Spire_Highlands, .Wet_Lowland_Marsh, .Corrupted_Ash_Forest:
		side_rib :=
			math.clamp(1.0 - math.abs(across_abs - f32(0.36)) * f32(5.6), f32(0), f32(1)) *
			(1.0 - math.smoothstep(f32(0.62), f32(0.92), along_abs))
		strength = side_rib * vertical_column * positive_rough
		return strength > 0.48
	}
	return false
}

terrain_density_cave_room_strata_threshold_adjust :: proc(
	y, radial, along, across, rough, detail: f32,
	biome_id: biomes.BiomeID,
) -> f32 {
	core_open_support := 1.0 - math.smoothstep(f32(0.0), f32(0.34), radial)
	floor_band :=
		math.smoothstep(f32(0.18), f32(0.74), -y) *
		(1.0 - math.smoothstep(f32(0.94), f32(1.24), radial))
	ceiling_band :=
		math.smoothstep(f32(0.18), f32(0.82), y) *
		(1.0 - math.smoothstep(f32(1.00), f32(1.30), radial))
	edge_terrace_band :=
		math.smoothstep(f32(0.34), f32(0.88), radial) *
		(1.0 - math.smoothstep(f32(0.92), f32(1.22), radial))
	floor_noise := math.smoothstep(f32(-0.12), f32(0.54), rough * 0.68 + detail * 0.32)
	terrace_noise := 1.0 - math.smoothstep(f32(0.18), f32(0.74), detail)
	ceiling_noise := math.smoothstep(f32(0.04), f32(0.62), detail)
	ceiling_rib_band :=
		math.clamp(1.0 - math.abs(math.abs(across) - f32(0.36)) * f32(4.4), f32(0), f32(1)) *
		(1.0 - math.smoothstep(f32(0.72), f32(1.04), math.abs(along)))

	floor_mound_scale := TERRAIN_CAVE_ROOM_STRATA_FLOOR_MOUND_SCALE
	floor_terrace_scale := TERRAIN_CAVE_ROOM_STRATA_FLOOR_TERRACE_SCALE
	ceiling_chimney_scale := TERRAIN_CAVE_ROOM_STRATA_CEILING_CHIMNEY_SCALE
	ceiling_rib_scale := TERRAIN_CAVE_ROOM_STRATA_CEILING_RIB_SCALE
	#partial switch biome_id {
	case .Fungal_Vaults:
		floor_mound_scale *= 1.24
		floor_terrace_scale *= 1.12
		ceiling_chimney_scale *= 0.84
	case .Crystal_Geode_Network:
		floor_mound_scale *= 0.78
		ceiling_chimney_scale *= 1.34
		ceiling_rib_scale *= 1.18
	case .Buried_Aquifer_Caves:
		floor_mound_scale *= 0.72
		floor_terrace_scale *= 1.36
		ceiling_chimney_scale *= 0.76
	case .Temperate_Hills, .Basalt_Spire_Highlands, .Wet_Lowland_Marsh, .Corrupted_Ash_Forest:
	}

	floor_mound := floor_band * (1.0 - core_open_support * 0.72) * floor_noise * floor_mound_scale
	floor_terrace := floor_band * edge_terrace_band * terrace_noise * floor_terrace_scale
	ceiling_chimney :=
		ceiling_band *
		(1.0 - math.smoothstep(f32(0.46), f32(0.94), radial)) *
		ceiling_noise *
		ceiling_chimney_scale
	ceiling_rib :=
		ceiling_band *
		ceiling_rib_band *
		math.smoothstep(f32(-0.18), f32(0.46), rough) *
		ceiling_rib_scale

	return ceiling_chimney + floor_terrace - floor_mound - ceiling_rib
}

terrain_density_cave_room_lobe_threshold_adjust :: proc(nx, ny, nz, axis_x, axis_z: f32) -> f32 {
	shape := nx * nx + ny * ny + nz * nz
	core_support := math.clamp((f32(1.0) - shape) * 1.389, f32(0), f32(1))
	edge_support := 1.0 - core_support
	along := nx * axis_x + nz * axis_z
	across := nx * -axis_z + nz * axis_x
	along_abs := math.abs(along)
	across_abs := math.abs(across)
	forward_lobe := math.smoothstep(f32(0.08), f32(0.86), along)
	back_lobe := math.smoothstep(f32(0.18), f32(0.82), -along)
	side_notch :=
		math.smoothstep(f32(0.32), f32(0.92), across_abs) *
		(1.0 - math.smoothstep(f32(0.70), f32(1.05), along_abs))
	ceiling_rib :=
		math.smoothstep(f32(0.18), f32(0.85), ny) *
		math.smoothstep(f32(0.38), f32(0.96), across_abs)
	return(
		edge_support *
		(forward_lobe * TERRAIN_CAVE_ROOM_LOBE_SWELL_SCALE +
				back_lobe * TERRAIN_CAVE_ROOM_LOBE_BACK_SWELL_SCALE -
				side_notch * TERRAIN_CAVE_ROOM_SIDE_NOTCH_SCALE -
				ceiling_rib * TERRAIN_CAVE_ROOM_CEILING_RIB_SCALE) \
	)
}

terrain_density_fill_water_ellipsoid :: proc(
	view: ^world_async.ChunkVoxelView,
	chunk_origin: world_async.BlockCoord,
	center_x, center_y, center_z, radius_x, radius_y, radius_z: f32,
) {
	rx := math.max(f32(1), radius_x)
	ry := math.max(f32(1), radius_y)
	rz := math.max(f32(1), radius_z)
	local_min_x, local_max_x, local_min_y, local_max_y, local_min_z, local_max_z, intersects :=
		terrain_density_carve_bounds_from_extents(
			chunk_origin,
			center_x - rx,
			center_x + rx,
			center_y - ry,
			center_y + ry,
			center_z - rz,
			center_z + rz,
		)
	if !intersects {
		return
	}

	for z := local_min_z; z <= local_max_z; z += 1 {
		world_z := f32(chunk_origin.z + z) + 0.5
		for y := local_min_y; y <= local_max_y; y += 1 {
			world_y := f32(chunk_origin.y + y) + 0.5
			for x := local_min_x; x <= local_max_x; x += 1 {
				world_x := f32(chunk_origin.x + x) + 0.5
				nx := (world_x - center_x) / rx
				ny := (world_y - center_y) / ry
				nz := (world_z - center_z) / rz
				if nx * nx + ny * ny + nz * nz > 1.0 {
					continue
				}
				terrain_density_fill_local_water_block(view, x, y, z)
			}
		}
	}
}

terrain_density_carve_cave_edge :: proc(
	view: ^world_async.ChunkVoxelView,
	region: ^biomes.GenerationRegion,
	chunk_origin: world_async.BlockCoord,
	columns: []TerrainBiomeColumn,
	edge: biomes.CaveNetworkEdge,
	wall_buffer: ^TerrainCaveWallMaterialBuffer = nil,
	core_segment_mask: u64 = max(u64),
	carveable_row_mask: ^TerrainCarveableRowMask = nil,
) {
	radius := terrain_density_cave_edge_feature_radius(edge)
	core_radius := terrain_density_cave_edge_core_radius(edge, radius)
	segment_radius_scale, segment_salt := terrain_density_cave_passage_segment_setup(edge.kind)
	from_shape := terrain_density_cave_passage_shape(edge.kind)
	terrain_density_cave_passage_shape_apply_biome(&from_shape, edge.from_biome_id)
	to_shape := terrain_density_cave_passage_shape(edge.kind)
	terrain_density_cave_passage_shape_apply_biome(&to_shape, edge.to_biome_id)
	if edge.regional_seam_connection && edge.kind == .Canyon {
		terrain_density_cave_passage_shape_apply_regional_seam(&from_shape)
		terrain_density_cave_passage_shape_apply_regional_seam(&to_shape)
	}
	edge_profile_start: time.Tick
	when TERRAIN_GENERATION_PROFILE_PHASES {
		edge_profile_start = time.tick_now()
	}
	when !TERRAIN_GENERATION_PROFILE_PHASES {
		_ = edge_profile_start
	}
	prev_x, prev_y, prev_z := terrain_density_cave_edge_route_point(edge, 0)
	when TERRAIN_GENERATION_PROFILE_PHASES {
		terrain_generation_profile_edge_core_active = true
	}
	for segment_index := u32(1);
	    segment_index <= TERRAIN_CAVE_EDGE_ROUTE_SEGMENT_COUNT;
	    segment_index += 1 {
		t := f32(segment_index) / f32(TERRAIN_CAVE_EDGE_ROUTE_SEGMENT_COUNT)
		next_x, next_y, next_z := terrain_density_cave_edge_route_point(edge, t)
		mid_t := (f32(segment_index) - 0.5) / f32(TERRAIN_CAVE_EDGE_ROUTE_SEGMENT_COUNT)
		segment_bit := u64(1) << (segment_index - 1)
		if (core_segment_mask & segment_bit) != 0 {
			biome_id := edge.from_biome_id
			if mid_t >= 0.5 {
				biome_id = edge.to_biome_id
			}
			segment_radius := terrain_density_cave_edge_core_segment_radius(
				edge,
				core_radius,
				segment_radius_scale,
				t,
				mid_t,
			)
			segment_shape := from_shape
			if mid_t >= 0.5 {
				segment_shape = to_shape
			}
			terrain_density_carve_rough_segment_shaped(
				view,
				region.key,
				chunk_origin,
				columns,
				prev_x,
				prev_y,
				prev_z,
				next_x,
				next_y,
				next_z,
				segment_radius,
				segment_shape,
				segment_salt,
				biome_id,
				false,
				wall_buffer,
				carveable_row_mask,
			)
		}
		prev_x = next_x
		prev_y = next_y
		prev_z = next_z
	}
	when TERRAIN_GENERATION_PROFILE_PHASES {
		terrain_generation_profile_edge_core_active = false
	}
	when TERRAIN_GENERATION_PROFILE_PHASES {
		terrain_generation_profile_stats.edge_core += time.tick_since(edge_profile_start)
		edge_profile_start = time.tick_now()
	}
	when TERRAIN_CAVE_FAST_SKELETON {
		return
	}

	feature_radius := radius
	terrain_density_carve_cave_edge_approach_vestibules(
		view,
		region.key,
		chunk_origin,
		columns,
		edge,
		feature_radius,
	)
	when TERRAIN_GENERATION_PROFILE_PHASES {
		terrain_generation_profile_stats.edge_approach += time.tick_since(edge_profile_start)
		edge_profile_start = time.tick_now()
	}
	terrain_density_carve_cave_edge_braids(
		view,
		region.key,
		chunk_origin,
		columns,
		edge,
		feature_radius,
		wall_buffer,
	)
	when TERRAIN_GENERATION_PROFILE_PHASES {
		terrain_generation_profile_stats.edge_braids += time.tick_since(edge_profile_start)
		edge_profile_start = time.tick_now()
	}
	terrain_density_carve_cave_edge_route_bypasses(
		view,
		region.key,
		chunk_origin,
		columns,
		edge,
		feature_radius,
		wall_buffer,
	)
	when TERRAIN_GENERATION_PROFILE_PHASES {
		terrain_generation_profile_stats.edge_bypasses += time.tick_since(edge_profile_start)
		edge_profile_start = time.tick_now()
	}
	terrain_density_carve_cave_edge_alcoves(
		view,
		region.key,
		chunk_origin,
		columns,
		edge,
		feature_radius,
		wall_buffer,
	)
	when TERRAIN_GENERATION_PROFILE_PHASES {
		terrain_generation_profile_stats.edge_alcoves += time.tick_since(edge_profile_start)
		edge_profile_start = time.tick_now()
	}
	terrain_density_carve_cave_edge_chamberlets(
		view,
		region.key,
		chunk_origin,
		columns,
		edge,
		feature_radius,
		wall_buffer,
	)
	when TERRAIN_GENERATION_PROFILE_PHASES {
		terrain_generation_profile_stats.edge_chamberlets += time.tick_since(edge_profile_start)
		edge_profile_start = time.tick_now()
	}
	terrain_density_carve_cave_edge_seam_bays(
		view,
		region.key,
		chunk_origin,
		columns,
		edge,
		feature_radius,
		wall_buffer,
	)
	terrain_density_carve_cave_edge_seam_bypasses(
		view,
		region.key,
		chunk_origin,
		columns,
		edge,
		feature_radius,
		wall_buffer,
	)
	terrain_density_carve_cave_edge_seam_crosscuts(
		view,
		region.key,
		chunk_origin,
		columns,
		edge,
		feature_radius,
		wall_buffer,
	)
	terrain_density_carve_cave_edge_seam_shoulders(
		view,
		region.key,
		chunk_origin,
		columns,
		edge,
		feature_radius,
		wall_buffer,
	)
	terrain_density_carve_cave_edge_seam_vertical_relief(
		view,
		region.key,
		chunk_origin,
		columns,
		edge,
		feature_radius,
		wall_buffer,
	)
	terrain_density_carve_cave_edge_seam_galleries(
		view,
		region.key,
		chunk_origin,
		columns,
		edge,
		feature_radius,
		wall_buffer,
	)
	when TERRAIN_GENERATION_PROFILE_PHASES {
		terrain_generation_profile_stats.edge_seams += time.tick_since(edge_profile_start)
	}
}

terrain_density_cave_edge_core_radius_scale :: proc(kind: biomes.CaveNetworkEdgeKind) -> f32 {
	#partial switch kind {
	case .Canyon:
		return TERRAIN_CAVE_EDGE_CORE_RADIUS_SCALE_CANYON
	case .Flooded_Passage:
		return TERRAIN_CAVE_EDGE_CORE_RADIUS_SCALE_FLOODED
	case .Fracture:
		return TERRAIN_CAVE_EDGE_CORE_RADIUS_SCALE_FRACTURE
	case .Collapsed_Corridor:
		return TERRAIN_CAVE_EDGE_CORE_RADIUS_SCALE_COLLAPSED
	case .Worm_Path:
		return TERRAIN_CAVE_EDGE_CORE_RADIUS_SCALE_WORM
	}
	return TERRAIN_CAVE_EDGE_CORE_RADIUS_SCALE_DEFAULT
}

terrain_density_cave_edge_radius_modulation :: proc(edge: biomes.CaveNetworkEdge, t: f32) -> f32 {
	route_t := math.clamp(t, f32(0), f32(1))
	hash := biomes.feature_grid_hash_combine(u64(edge.id), TERRAIN_CAVE_PASSAGE_RIB_SALT)
	phase_a := biomes.feature_grid_unit_f32(hash, TERRAIN_CAVE_CURVE_SALT)
	phase_b := biomes.feature_grid_unit_f32(hash, TERRAIN_CAVE_FIELD_DETAIL_SALT)
	neck_wave :=
		terrain_density_cave_segment_triangle_wave(route_t * 3.0 + phase_a * 0.21) * 0.62 +
		terrain_density_cave_segment_triangle_wave(route_t * 6.5 + phase_b * 0.17) * 0.38
	neck_wave *= neck_wave
	min_scale := TERRAIN_CAVE_EDGE_ROUTE_RADIUS_NECK_MIN
	max_scale := TERRAIN_CAVE_EDGE_ROUTE_RADIUS_SWELL_MAX
	#partial switch edge.kind {
	case .Canyon:
		min_scale = math.max(min_scale, f32(0.70))
		max_scale = math.min(max_scale, f32(1.12))
	case .Flooded_Passage:
		min_scale = math.max(min_scale, f32(0.62))
		max_scale = math.min(max_scale, f32(1.08))
	case .Fracture:
		min_scale = math.max(min_scale, f32(0.48))
		max_scale = math.min(max_scale, f32(0.98))
	case .Collapsed_Corridor:
		min_scale = math.max(min_scale, f32(0.46))
		max_scale = math.min(max_scale, f32(1.02))
	case .Worm_Path:
		min_scale = TERRAIN_CAVE_EDGE_ROUTE_RADIUS_NECK_MIN
		max_scale = math.min(max_scale, f32(0.82))
	}
	if edge.regional_seam_connection && edge.kind == .Canyon {
		min_scale = math.max(min_scale, TERRAIN_CAVE_EDGE_SEAM_RADIUS_NECK_MIN)
		max_scale = math.max(max_scale, TERRAIN_CAVE_EDGE_SEAM_RADIUS_SWELL_MAX)
	}
	scale := biomes.regional_terrain_field_lerp(min_scale, max_scale, neck_wave)
	end_support := math.clamp(math.min(route_t, 1.0 - route_t) / f32(0.11), f32(0), f32(1))
	return biomes.regional_terrain_field_lerp(f32(0.92), scale, end_support)
}

terrain_density_cave_edge_seam_radius_scale :: proc(edge: biomes.CaveNetworkEdge, t: f32) -> f32 {
	if !edge.regional_seam_connection || edge.kind != .Canyon {
		return 1.0
	}
	route_t := math.clamp(t, f32(0), f32(1))
	end_distance := math.min(route_t, 1.0 - route_t)
	interior_support := math.smoothstep(f32(0.08), f32(0.30), end_distance)
	return 1.0 + interior_support * TERRAIN_CAVE_EDGE_SEAM_INTERIOR_RADIUS_SCALE
}

terrain_density_cave_edge_approach_radius_scale :: proc(
	kind: biomes.CaveNetworkEdgeKind,
	t: f32,
) -> f32 {
	route_t := math.clamp(t, f32(0), f32(1))
	end_distance := math.min(route_t, 1.0 - route_t)
	end_support :=
		1.0 -
		math.smoothstep(
			TERRAIN_CAVE_EDGE_APPROACH_WIDEN_FULL_T,
			TERRAIN_CAVE_EDGE_APPROACH_WIDEN_START_T,
			end_distance,
		)
	scale := TERRAIN_CAVE_EDGE_APPROACH_WIDEN_SCALE
	#partial switch kind {
	case .Fracture:
		scale *= 0.68
	case .Collapsed_Corridor:
		scale *= 0.78
	case .Flooded_Passage:
		scale *= 0.86
	case .Canyon:
		scale *= 0.92
	case .Worm_Path:
		scale *= 1.05
	case .Vertical_Shaft:
		scale *= 0.62
	}
	return 1.0 + end_support * scale
}

terrain_density_cave_edge_approach_vestibules_enabled :: proc(
	edge: biomes.CaveNetworkEdge,
	route_radius: f32,
) -> bool {
	if !edge.guaranteed_connection || edge.regional_seam_connection {
		return false
	}
	if route_radius < TERRAIN_CAVE_EDGE_APPROACH_VESTIBULE_MIN_ROUTE_RADIUS_BLOCKS {
		return false
	}
	return edge.kind != .Vertical_Shaft
}

terrain_density_carve_cave_edge_approach_vestibules :: proc(
	view: ^world_async.ChunkVoxelView,
	key: biomes.FeatureGridKey,
	chunk_origin: world_async.BlockCoord,
	columns: []TerrainBiomeColumn,
	edge: biomes.CaveNetworkEdge,
	route_radius: f32,
) {
	if !terrain_density_cave_edge_approach_vestibules_enabled(edge, route_radius) {
		return
	}

	for endpoint_index := u32(0); endpoint_index < 2; endpoint_index += 1 {
		hash := biomes.feature_grid_hash_combine(u64(edge.id), TERRAIN_CAVE_ROOM_DETAIL_SALT)
		hash = biomes.feature_grid_hash_combine(hash, u64(endpoint_index + 977))

		route_t := TERRAIN_CAVE_EDGE_APPROACH_VESTIBULE_ROUTE_T
		end_x := edge.from_x
		end_y := edge.from_y
		end_z := edge.from_z
		biome_id := edge.from_biome_id
		if endpoint_index == 1 {
			route_t = 1.0 - TERRAIN_CAVE_EDGE_APPROACH_VESTIBULE_ROUTE_T
			end_x = edge.to_x
			end_y = edge.to_y
			end_z = edge.to_z
			biome_id = edge.to_biome_id
		}

		route_x, route_y, route_z := terrain_density_cave_edge_route_point(edge, route_t)
		tangent_x, tangent_y, tangent_z := terrain_density_delta_3(
			end_x,
			end_y,
			end_z,
			route_x,
			route_y,
			route_z,
		)
		horizontal_length := math.sqrt_f32(tangent_x * tangent_x + tangent_z * tangent_z)
		side_x := f32(1)
		side_z := f32(0)
		if horizontal_length > 0.001 {
			side_x = -tangent_z / horizontal_length
			side_z = tangent_x / horizontal_length
		} else {
			angle :=
				biomes.feature_grid_unit_f32(hash, TERRAIN_CAVE_PASSAGE_RIB_SALT) * f32(6.2831855)
			side_x = math.cos_f32(angle)
			side_z = math.sin_f32(angle)
		}
		side_sign := f32(1)
		if endpoint_index == 1 {
			side_sign = -1
		}
		if biomes.feature_grid_signed_unit_f32(hash, TERRAIN_CAVE_BRANCH_SALT) < 0 {
			side_sign = -side_sign
		}
		side_x *= side_sign
		side_z *= side_sign
		vertical_sign := f32(1)
		if biomes.feature_grid_signed_unit_f32(hash, TERRAIN_CAVE_DETAIL_SALT) < 0 {
			vertical_sign = -1
		}

		side_offset :=
			route_radius *
			TERRAIN_CAVE_EDGE_APPROACH_VESTIBULE_SIDE_OFFSET_SCALE *
			biomes.regional_terrain_field_lerp(
				f32(0.62),
				f32(1.12),
				biomes.feature_grid_unit_f32(hash, TERRAIN_CAVE_FIELD_DETAIL_SALT),
			)
		vertical_offset :=
			route_radius *
			TERRAIN_CAVE_EDGE_APPROACH_VESTIBULE_VERTICAL_OFFSET_SCALE *
			vertical_sign *
			biomes.regional_terrain_field_lerp(
				f32(0.46),
				f32(1.04),
				biomes.feature_grid_unit_f32(hash, TERRAIN_CAVE_ROUGHNESS_SALT),
			)
		center_x := route_x + side_x * side_offset
		center_y := route_y + vertical_offset + tangent_y * route_radius * f32(0.08)
		center_z := route_z + side_z * side_offset

		vestibule_radius := math.clamp(
			route_radius *
			TERRAIN_CAVE_EDGE_APPROACH_VESTIBULE_RADIUS_SCALE *
			biomes.regional_terrain_field_lerp(
				f32(0.80),
				f32(1.18),
				biomes.feature_grid_unit_f32(hash, TERRAIN_CAVE_FIELD_CHAMBER_SALT),
			),
			TERRAIN_CAVE_EDGE_APPROACH_VESTIBULE_RADIUS_MIN_BLOCKS,
			TERRAIN_CAVE_EDGE_APPROACH_VESTIBULE_RADIUS_MAX_BLOCKS,
		)
		radius_x := vestibule_radius
		radius_y := vestibule_radius * f32(0.62)
		radius_z := vestibule_radius * f32(0.92)
		shape_kind := edge.kind
		#partial switch biome_id {
		case .Fungal_Vaults:
			radius_x *= 1.16
			radius_y *= 0.92
			radius_z *= 1.08
			shape_kind = .Worm_Path
		case .Crystal_Geode_Network:
			radius_x *= 0.72
			radius_y *= 1.28
			radius_z *= 0.84
			shape_kind = .Fracture
		case .Buried_Aquifer_Caves:
			radius_x *= 1.18
			radius_y *= 0.54
			radius_z *= 1.06
			shape_kind = .Flooded_Passage
		case .Temperate_Hills, .Basalt_Spire_Highlands, .Wet_Lowland_Marsh, .Corrupted_Ash_Forest:
		}

		throat_shape := terrain_density_cave_passage_shape(shape_kind)
		terrain_density_cave_passage_shape_apply_biome(&throat_shape, biome_id)
		throat_radius := math.max(
			f32(2.4),
			math.min(
				vestibule_radius * TERRAIN_CAVE_EDGE_APPROACH_VESTIBULE_THROAT_SCALE,
				route_radius * f32(0.52),
			),
		)
		terrain_density_carve_rough_segment_shaped(
			view,
			key,
			chunk_origin,
			columns,
			route_x,
			route_y,
			route_z,
			center_x,
			center_y,
			center_z,
			throat_radius,
			throat_shape,
			TERRAIN_CAVE_ROOM_DETAIL_SALT ~ u64(endpoint_index + 1009),
			biome_id,
			true,
		)
		terrain_density_carve_cave_room_lobed_ellipsoid(
			view,
			key,
			chunk_origin,
			columns,
			center_x,
			center_y,
			center_z,
			radius_x,
			radius_y,
			radius_z,
			TERRAIN_CAVE_FIELD_CHAMBER_SALT ~ u64(endpoint_index + 1031),
			biome_id,
			true,
		)
	}
}

terrain_density_cave_edge_braid_enabled :: proc(edge: biomes.CaveNetworkEdge) -> bool {
	#partial switch edge.kind {
	case .Vertical_Shaft, .Fracture:
		return false
	}
	if edge.regional_seam_connection || edge.guaranteed_connection {
		return true
	}
	#partial switch edge.kind {
	case .Canyon, .Worm_Path, .Tunnel:
		return edge.radius_blocks >= TERRAIN_CAVE_EDGE_BRAID_RADIUS_THRESHOLD_BLOCKS
	}
	return false
}

terrain_density_carve_cave_edge_braids :: proc(
	view: ^world_async.ChunkVoxelView,
	key: biomes.FeatureGridKey,
	chunk_origin: world_async.BlockCoord,
	columns: []TerrainBiomeColumn,
	edge: biomes.CaveNetworkEdge,
	route_radius: f32,
	wall_buffer: ^TerrainCaveWallMaterialBuffer = nil,
) {
	if !terrain_density_cave_edge_braid_enabled(edge) {
		return
	}

	for braid_index := u32(0); braid_index < TERRAIN_CAVE_EDGE_BRAID_COUNT; braid_index += 1 {
		hash := biomes.feature_grid_hash_combine(u64(edge.id), TERRAIN_CAVE_CURVE_SALT)
		hash = biomes.feature_grid_hash_combine(hash, u64(braid_index + 503))
		step_t := (f32(braid_index) + 0.5) / f32(TERRAIN_CAVE_EDGE_BRAID_COUNT)
		center_t := biomes.regional_terrain_field_lerp(
			TERRAIN_CAVE_EDGE_BRAID_ROUTE_MARGIN,
			1.0 - TERRAIN_CAVE_EDGE_BRAID_ROUTE_MARGIN,
			step_t,
		)
		center_t +=
			biomes.feature_grid_signed_unit_f32(hash, TERRAIN_CAVE_FIELD_DETAIL_SALT) * f32(0.035)
		center_t = math.clamp(
			center_t,
			TERRAIN_CAVE_EDGE_BRAID_ROUTE_MARGIN,
			1.0 - TERRAIN_CAVE_EDGE_BRAID_ROUTE_MARGIN,
		)
		span_t := biomes.regional_terrain_field_lerp(
			TERRAIN_CAVE_EDGE_BRAID_SPAN_T_MIN,
			TERRAIN_CAVE_EDGE_BRAID_SPAN_T_MAX,
			biomes.feature_grid_unit_f32(hash, TERRAIN_CAVE_BRANCH_SALT),
		)
		from_t := math.max(TERRAIN_CAVE_EDGE_BRAID_ROUTE_MARGIN * 0.5, center_t - span_t * 0.5)
		to_t := math.min(1.0 - TERRAIN_CAVE_EDGE_BRAID_ROUTE_MARGIN * 0.5, center_t + span_t * 0.5)
		if to_t <= from_t + 0.05 {
			continue
		}

		from_x, from_y, from_z := terrain_density_cave_edge_route_point(edge, from_t)
		route_x, route_y, route_z := terrain_density_cave_edge_route_point(edge, center_t)
		to_x, to_y, to_z := terrain_density_cave_edge_route_point(edge, to_t)
		tangent_x, _, tangent_z := terrain_density_delta_3(
			from_x,
			from_y,
			from_z,
			to_x,
			to_y,
			to_z,
		)
		horizontal_length := math.sqrt_f32(tangent_x * tangent_x + tangent_z * tangent_z)
		side_x := f32(1)
		side_z := f32(0)
		if horizontal_length > 0.001 {
			side_x = -tangent_z / horizontal_length
			side_z = tangent_x / horizontal_length
		}
		side_sign := f32(1)
		if (braid_index & 1) != 0 {
			side_sign = -1
		}
		if biomes.feature_grid_signed_unit_f32(hash, TERRAIN_CAVE_PASSAGE_RIB_SALT) < 0 {
			side_sign = -side_sign
		}
		side_x *= side_sign
		side_z *= side_sign
		vertical_sign := f32(1)
		if biomes.feature_grid_signed_unit_f32(hash, TERRAIN_CAVE_ROOM_DETAIL_SALT) < 0 {
			vertical_sign = -1
		}

		side_offset :=
			route_radius *
			TERRAIN_CAVE_EDGE_BRAID_SIDE_OFFSET_SCALE *
			biomes.regional_terrain_field_lerp(
				f32(0.74),
				f32(1.18),
				biomes.feature_grid_unit_f32(hash, TERRAIN_CAVE_FIELD_CHAMBER_SALT),
			)
		vertical_offset :=
			route_radius *
			TERRAIN_CAVE_EDGE_BRAID_VERTICAL_OFFSET_SCALE *
			vertical_sign *
			biomes.regional_terrain_field_lerp(
				f32(0.42),
				f32(1.12),
				biomes.feature_grid_unit_f32(hash, TERRAIN_CAVE_DETAIL_SALT),
			)
		mid_x := route_x + side_x * side_offset
		mid_y := route_y + vertical_offset
		mid_z := route_z + side_z * side_offset

		biome_id := edge.from_biome_id
		if center_t >= 0.5 {
			biome_id = edge.to_biome_id
		}
		braid_radius := math.clamp(
			route_radius *
			TERRAIN_CAVE_EDGE_BRAID_RADIUS_SCALE *
			biomes.regional_terrain_field_lerp(
				f32(0.76),
				f32(1.16),
				biomes.feature_grid_unit_f32(hash, TERRAIN_CAVE_ROUGHNESS_SALT),
			),
			TERRAIN_CAVE_EDGE_BRAID_RADIUS_MIN_BLOCKS,
			TERRAIN_CAVE_EDGE_BRAID_RADIUS_MAX_BLOCKS,
		)
		braid_margin := math.max(route_radius * f32(1.35), braid_radius * f32(3.25)) + 4
		if !terrain_density_chunk_aabb_intersects(
			chunk_origin,
			math.min(from_x, math.min(mid_x, to_x)) - braid_margin,
			math.max(from_x, math.max(mid_x, to_x)) + braid_margin,
			math.min(from_y, math.min(mid_y, to_y)) - braid_margin,
			math.max(from_y, math.max(mid_y, to_y)) + braid_margin,
			math.min(from_z, math.min(mid_z, to_z)) - braid_margin,
			math.max(from_z, math.max(mid_z, to_z)) + braid_margin,
		) {
			continue
		}

		shape_kind := edge.kind
		if edge.kind == .Canyon {
			shape_kind = .Worm_Path
		}
		braid_shape := terrain_density_cave_passage_shape(shape_kind)
		terrain_density_cave_passage_shape_apply_biome(&braid_shape, biome_id)
		if edge.regional_seam_connection && edge.kind == .Canyon {
			terrain_density_cave_passage_shape_apply_regional_seam(&braid_shape)
		}
		terrain_density_carve_rough_segment_shaped(
			view,
			key,
			chunk_origin,
			columns,
			from_x,
			from_y,
			from_z,
			mid_x,
			mid_y,
			mid_z,
			braid_radius,
			braid_shape,
			TERRAIN_CAVE_CURVE_SALT ~ u64(braid_index + 547),
			biome_id,
			true,
		)
		terrain_density_carve_rough_segment_shaped(
			view,
			key,
			chunk_origin,
			columns,
			mid_x,
			mid_y,
			mid_z,
			to_x,
			to_y,
			to_z,
			braid_radius,
			braid_shape,
			TERRAIN_CAVE_CURVE_SALT ~ u64(braid_index + 587),
			biome_id,
			true,
		)

		pocket_radius := braid_radius * TERRAIN_CAVE_EDGE_BRAID_POCKET_RADIUS_SCALE
		terrain_density_carve_cave_room_lobed_ellipsoid(
			view,
			key,
			chunk_origin,
			columns,
			mid_x,
			mid_y,
			mid_z,
			pocket_radius * f32(1.08),
			pocket_radius * f32(0.72),
			pocket_radius,
			TERRAIN_CAVE_CURVE_SALT ~ u64(braid_index + 631),
			biome_id,
			true,
		)
	}
}

terrain_density_cave_edge_route_bypass_enabled :: proc(
	edge: biomes.CaveNetworkEdge,
	route_radius, route_length: f32,
) -> bool {
	if edge.regional_seam_connection {
		return false
	}
	if route_radius < TERRAIN_CAVE_EDGE_ROUTE_BYPASS_MIN_ROUTE_RADIUS_BLOCKS ||
	   route_length < TERRAIN_CAVE_EDGE_ROUTE_BYPASS_MIN_ROUTE_LENGTH_BLOCKS {
		return false
	}
	#partial switch edge.kind {
	case .Vertical_Shaft, .Fracture, .Collapsed_Corridor:
		return false
	}
	return true
}

terrain_density_carve_cave_edge_route_bypasses :: proc(
	view: ^world_async.ChunkVoxelView,
	key: biomes.FeatureGridKey,
	chunk_origin: world_async.BlockCoord,
	columns: []TerrainBiomeColumn,
	edge: biomes.CaveNetworkEdge,
	route_radius: f32,
	wall_buffer: ^TerrainCaveWallMaterialBuffer = nil,
) {
	route_dx := edge.to_x - edge.from_x
	route_dy := edge.to_y - edge.from_y
	route_dz := edge.to_z - edge.from_z
	route_length := math.sqrt_f32(route_dx * route_dx + route_dy * route_dy + route_dz * route_dz)
	if !terrain_density_cave_edge_route_bypass_enabled(edge, route_radius, route_length) {
		return
	}

	for bypass_index := u32(0);
	    bypass_index < TERRAIN_CAVE_EDGE_ROUTE_BYPASS_COUNT;
	    bypass_index += 1 {
		hash := biomes.feature_grid_hash_combine(u64(edge.id), TERRAIN_CAVE_FIELD_CHAMBER_SALT)
		hash = biomes.feature_grid_hash_combine(hash, u64(bypass_index + 1229))
		step_t := (f32(bypass_index) + 0.5) / f32(TERRAIN_CAVE_EDGE_ROUTE_BYPASS_COUNT)
		jitter := biomes.feature_grid_signed_unit_f32(hash, TERRAIN_CAVE_CURVE_SALT) * f32(0.050)
		center_t := math.clamp(
			biomes.regional_terrain_field_lerp(
				TERRAIN_CAVE_EDGE_ROUTE_BYPASS_ROUTE_MARGIN,
				1.0 - TERRAIN_CAVE_EDGE_ROUTE_BYPASS_ROUTE_MARGIN,
				step_t,
			) +
			jitter,
			TERRAIN_CAVE_EDGE_ROUTE_BYPASS_ROUTE_MARGIN,
			1.0 - TERRAIN_CAVE_EDGE_ROUTE_BYPASS_ROUTE_MARGIN,
		)
		span_t := biomes.regional_terrain_field_lerp(
			TERRAIN_CAVE_EDGE_ROUTE_BYPASS_SPAN_T_MIN,
			TERRAIN_CAVE_EDGE_ROUTE_BYPASS_SPAN_T_MAX,
			biomes.feature_grid_unit_f32(hash, TERRAIN_CAVE_BRANCH_SALT),
		)
		half_span := span_t * f32(0.5)
		from_t := math.max(
			TERRAIN_CAVE_EDGE_ROUTE_BYPASS_ROUTE_MARGIN * f32(0.5),
			center_t - half_span,
		)
		to_t := math.min(
			1.0 - TERRAIN_CAVE_EDGE_ROUTE_BYPASS_ROUTE_MARGIN * f32(0.5),
			center_t + half_span,
		)
		if to_t <= from_t + 0.080 {
			continue
		}

		from_x, from_y, from_z := terrain_density_cave_edge_route_point(edge, from_t)
		route_x, route_y, route_z := terrain_density_cave_edge_route_point(edge, center_t)
		to_x, to_y, to_z := terrain_density_cave_edge_route_point(edge, to_t)
		tangent_x, _, tangent_z := terrain_density_delta_3(
			from_x,
			from_y,
			from_z,
			to_x,
			to_y,
			to_z,
		)
		horizontal_length := math.sqrt_f32(tangent_x * tangent_x + tangent_z * tangent_z)
		side_x := f32(1)
		side_z := f32(0)
		if horizontal_length > 0.001 {
			side_x = -tangent_z / horizontal_length
			side_z = tangent_x / horizontal_length
		}
		side_sign := f32(1)
		if (bypass_index & 1) != 0 {
			side_sign = -1
		}
		if biomes.feature_grid_signed_unit_f32(hash, TERRAIN_CAVE_PASSAGE_RIB_SALT) < 0 {
			side_sign = -side_sign
		}
		side_x *= side_sign
		side_z *= side_sign
		vertical_sign := f32(1)
		if (bypass_index & 1) != 0 {
			vertical_sign = -1
		}
		if biomes.feature_grid_signed_unit_f32(hash, TERRAIN_CAVE_ROOM_DETAIL_SALT) < -0.15 {
			vertical_sign = -vertical_sign
		}

		side_offset :=
			route_radius *
			TERRAIN_CAVE_EDGE_ROUTE_BYPASS_SIDE_OFFSET_SCALE *
			biomes.regional_terrain_field_lerp(
				f32(0.82),
				f32(1.18),
				biomes.feature_grid_unit_f32(hash, TERRAIN_CAVE_FIELD_DETAIL_SALT),
			)
		vertical_offset :=
			route_radius *
			TERRAIN_CAVE_EDGE_ROUTE_BYPASS_VERTICAL_OFFSET_SCALE *
			vertical_sign *
			biomes.regional_terrain_field_lerp(
				f32(0.68),
				f32(1.10),
				biomes.feature_grid_unit_f32(hash, TERRAIN_CAVE_DETAIL_SALT),
			)
		relay_offset :=
			route_radius *
			TERRAIN_CAVE_EDGE_ROUTE_BYPASS_RELAY_OFFSET_SCALE *
			biomes.feature_grid_signed_unit_f32(hash, TERRAIN_CAVE_ROUGHNESS_SALT)

		from_bypass_x := from_x + side_x * side_offset * f32(0.60)
		from_bypass_y := from_y + vertical_offset * f32(0.42)
		from_bypass_z := from_z + side_z * side_offset * f32(0.60)
		relay_a_x := route_x + side_x * (side_offset + relay_offset)
		relay_a_y := route_y + vertical_offset
		relay_a_z := route_z + side_z * (side_offset + relay_offset)
		relay_b_x := route_x + side_x * (side_offset - relay_offset * f32(0.52))
		relay_b_y := route_y + vertical_offset * f32(0.78)
		relay_b_z := route_z + side_z * (side_offset - relay_offset * f32(0.52))
		to_bypass_x := to_x + side_x * side_offset * f32(0.60)
		to_bypass_y := to_y + vertical_offset * f32(0.42)
		to_bypass_z := to_z + side_z * side_offset * f32(0.60)

		biome_id := edge.from_biome_id
		if center_t >= 0.5 {
			biome_id = edge.to_biome_id
		}
		bypass_radius := math.clamp(
			route_radius *
			TERRAIN_CAVE_EDGE_ROUTE_BYPASS_RADIUS_SCALE *
			biomes.regional_terrain_field_lerp(
				f32(0.82),
				f32(1.18),
				biomes.feature_grid_unit_f32(hash, TERRAIN_CAVE_ROUGHNESS_SALT),
			),
			TERRAIN_CAVE_EDGE_ROUTE_BYPASS_RADIUS_MIN_BLOCKS,
			TERRAIN_CAVE_EDGE_ROUTE_BYPASS_RADIUS_MAX_BLOCKS,
		)
		bypass_feature_margin :=
			math.max(
				route_radius * f32(1.65),
				bypass_radius * TERRAIN_CAVE_EDGE_ROUTE_BYPASS_POCKET_RADIUS_SCALE * f32(2.40),
			) +
			8
		if !terrain_density_chunk_aabb_intersects(
			chunk_origin,
			math.min(
				math.min(math.min(from_x, route_x), math.min(to_x, from_bypass_x)),
				math.min(math.min(relay_a_x, relay_b_x), to_bypass_x),
			) -
			bypass_feature_margin,
			math.max(
				math.max(math.max(from_x, route_x), math.max(to_x, from_bypass_x)),
				math.max(math.max(relay_a_x, relay_b_x), to_bypass_x),
			) +
			bypass_feature_margin,
			math.min(
				math.min(math.min(from_y, route_y), math.min(to_y, from_bypass_y)),
				math.min(math.min(relay_a_y, relay_b_y), to_bypass_y),
			) -
			bypass_feature_margin,
			math.max(
				math.max(math.max(from_y, route_y), math.max(to_y, from_bypass_y)),
				math.max(math.max(relay_a_y, relay_b_y), to_bypass_y),
			) +
			bypass_feature_margin,
			math.min(
				math.min(math.min(from_z, route_z), math.min(to_z, from_bypass_z)),
				math.min(math.min(relay_a_z, relay_b_z), to_bypass_z),
			) -
			bypass_feature_margin,
			math.max(
				math.max(math.max(from_z, route_z), math.max(to_z, from_bypass_z)),
				math.max(math.max(relay_a_z, relay_b_z), to_bypass_z),
			) +
			bypass_feature_margin,
		) {
			continue
		}

		shape_kind := edge.kind
		#partial switch biome_id {
		case .Fungal_Vaults:
			shape_kind = .Worm_Path
		case .Crystal_Geode_Network:
			shape_kind = .Fracture
		case .Buried_Aquifer_Caves:
			shape_kind = .Flooded_Passage
		case .Temperate_Hills, .Basalt_Spire_Highlands, .Wet_Lowland_Marsh, .Corrupted_Ash_Forest:
		}
		bypass_shape := terrain_density_cave_passage_shape(shape_kind)
		terrain_density_cave_passage_shape_apply_biome(&bypass_shape, biome_id)
		bypass_shape.radius_neck_scale = math.max(bypass_shape.radius_neck_scale, f32(0.12))
		bypass_shape.radius_swell_scale = math.max(bypass_shape.radius_swell_scale, f32(0.30))
		bypass_shape.meander_scale = math.max(bypass_shape.meander_scale, f32(0.70))
		bypass_shape.curve_scale = math.max(bypass_shape.curve_scale, f32(0.18))
		if vertical_sign > 0 {
			bypass_shape.radius_y_scale = math.max(bypass_shape.radius_y_scale, f32(1.08))
			bypass_shape.radius_x_scale *= 0.96
			bypass_shape.radius_z_scale *= 0.96
		} else {
			bypass_shape.radius_y_scale = math.min(bypass_shape.radius_y_scale, f32(0.80))
			bypass_shape.radius_x_scale = math.max(bypass_shape.radius_x_scale, f32(1.14))
			bypass_shape.radius_z_scale = math.max(bypass_shape.radius_z_scale, f32(1.12))
		}
		throat_radius := math.max(
			f32(2.25),
			math.min(
				bypass_radius * TERRAIN_CAVE_EDGE_ROUTE_BYPASS_THROAT_SCALE,
				route_radius * f32(0.26),
			),
		)

		terrain_density_carve_rough_segment_shaped(
			view,
			key,
			chunk_origin,
			columns,
			from_x,
			from_y,
			from_z,
			from_bypass_x,
			from_bypass_y,
			from_bypass_z,
			throat_radius,
			bypass_shape,
			TERRAIN_CAVE_FIELD_CHAMBER_SALT ~ u64(bypass_index + 1249),
			biome_id,
			true,
		)
		terrain_density_carve_rough_segment_shaped(
			view,
			key,
			chunk_origin,
			columns,
			to_x,
			to_y,
			to_z,
			to_bypass_x,
			to_bypass_y,
			to_bypass_z,
			throat_radius,
			bypass_shape,
			TERRAIN_CAVE_FIELD_CHAMBER_SALT ~ u64(bypass_index + 1277),
			biome_id,
			true,
		)
		terrain_density_carve_rough_segment_shaped(
			view,
			key,
			chunk_origin,
			columns,
			from_bypass_x,
			from_bypass_y,
			from_bypass_z,
			relay_a_x,
			relay_a_y,
			relay_a_z,
			bypass_radius,
			bypass_shape,
			TERRAIN_CAVE_BRANCH_SALT ~ u64(bypass_index + 1301),
			biome_id,
			true,
		)
		terrain_density_carve_rough_segment_shaped(
			view,
			key,
			chunk_origin,
			columns,
			relay_a_x,
			relay_a_y,
			relay_a_z,
			relay_b_x,
			relay_b_y,
			relay_b_z,
			bypass_radius,
			bypass_shape,
			TERRAIN_CAVE_BRANCH_SALT ~ u64(bypass_index + 1327),
			biome_id,
			true,
		)
		terrain_density_carve_rough_segment_shaped(
			view,
			key,
			chunk_origin,
			columns,
			relay_b_x,
			relay_b_y,
			relay_b_z,
			to_bypass_x,
			to_bypass_y,
			to_bypass_z,
			bypass_radius,
			bypass_shape,
			TERRAIN_CAVE_BRANCH_SALT ~ u64(bypass_index + 1361),
			biome_id,
			true,
		)

		pocket_radius := bypass_radius * TERRAIN_CAVE_EDGE_ROUTE_BYPASS_POCKET_RADIUS_SCALE
		radius_x := pocket_radius * f32(1.20)
		radius_y := pocket_radius * f32(0.74)
		radius_z := pocket_radius * f32(1.08)
		if vertical_sign > 0 {
			radius_y *= 1.16
			radius_x *= 0.94
			radius_z *= 0.96
		} else {
			radius_x *= 1.10
			radius_y *= 0.78
			radius_z *= 1.08
		}
		#partial switch biome_id {
		case .Fungal_Vaults:
			radius_x *= 1.14
			radius_z *= 1.10
			radius_y *= 0.96
		case .Crystal_Geode_Network:
			radius_x *= 0.76
			radius_y *= 1.30
			radius_z *= 0.82
		case .Buried_Aquifer_Caves:
			radius_x *= 1.16
			radius_y *= 0.62
			radius_z *= 1.14
		case .Temperate_Hills, .Basalt_Spire_Highlands, .Wet_Lowland_Marsh, .Corrupted_Ash_Forest:
		}
		terrain_density_carve_cave_room_lobed_ellipsoid(
			view,
			key,
			chunk_origin,
			columns,
			(relay_a_x + relay_b_x) * f32(0.5),
			(relay_a_y + relay_b_y) * f32(0.5),
			(relay_a_z + relay_b_z) * f32(0.5),
			radius_x,
			radius_y,
			radius_z,
			TERRAIN_CAVE_FIELD_CHAMBER_SALT ~ u64(bypass_index + 1399),
			biome_id,
			true,
		)
	}
}

terrain_density_carve_cave_edge_alcoves :: proc(
	view: ^world_async.ChunkVoxelView,
	key: biomes.FeatureGridKey,
	chunk_origin: world_async.BlockCoord,
	columns: []TerrainBiomeColumn,
	edge: biomes.CaveNetworkEdge,
	route_radius: f32,
	wall_buffer: ^TerrainCaveWallMaterialBuffer = nil,
) {
	for alcove_index := u32(0); alcove_index < TERRAIN_CAVE_EDGE_ALCOVE_COUNT; alcove_index += 1 {
		hash := biomes.feature_grid_hash_combine(u64(edge.id), TERRAIN_CAVE_BRANCH_SALT)
		hash = biomes.feature_grid_hash_combine(hash, u64(alcove_index))
		route_roll := biomes.feature_grid_unit_f32(hash, TERRAIN_CAVE_CURVE_SALT)
		t := biomes.regional_terrain_field_lerp(
			TERRAIN_CAVE_EDGE_ALCOVE_ROUTE_MARGIN,
			1.0 - TERRAIN_CAVE_EDGE_ALCOVE_ROUTE_MARGIN,
			route_roll,
		)
		center_x, center_y, center_z := terrain_density_cave_edge_route_point(edge, t)
		prev_x, prev_y, prev_z := terrain_density_cave_edge_route_point(
			edge,
			math.max(f32(0), t - 0.08),
		)
		next_x, next_y, next_z := terrain_density_cave_edge_route_point(
			edge,
			math.min(f32(1), t + 0.08),
		)
		tangent_x, _, tangent_z := terrain_density_delta_3(
			prev_x,
			prev_y,
			prev_z,
			next_x,
			next_y,
			next_z,
		)
		horizontal_length := math.sqrt_f32(tangent_x * tangent_x + tangent_z * tangent_z)
		side_x := f32(1)
		side_z := f32(0)
		route_x := center_x
		route_y := center_y
		route_z := center_z
		if horizontal_length > 0.001 {
			side_x = -tangent_z / horizontal_length
			side_z = tangent_x / horizontal_length
		} else {
			angle :=
				biomes.feature_grid_unit_f32(hash, TERRAIN_CAVE_PASSAGE_RIB_SALT) * f32(6.2831855)
			side_x = math.cos_f32(angle)
			side_z = math.sin_f32(angle)
		}
		side_sign := biomes.feature_grid_signed_unit_f32(hash, TERRAIN_CAVE_DETAIL_SALT)
		if side_sign < 0 {
			side_x = -side_x
			side_z = -side_z
		}
		side_offset :=
			route_radius *
			TERRAIN_CAVE_EDGE_ALCOVE_SIDE_OFFSET_SCALE *
			biomes.regional_terrain_field_lerp(
				f32(0.88),
				f32(1.28),
				biomes.feature_grid_unit_f32(hash, TERRAIN_CAVE_FIELD_DETAIL_SALT),
			)
		center_x += side_x * side_offset
		center_z += side_z * side_offset
		center_y +=
			biomes.feature_grid_signed_unit_f32(hash, TERRAIN_CAVE_ROOM_DETAIL_SALT) *
			route_radius *
			0.22

		radius_base := math.clamp(
			route_radius *
			biomes.regional_terrain_field_lerp(
				f32(0.42),
				f32(0.70),
				biomes.feature_grid_unit_f32(hash, TERRAIN_CAVE_ROUGHNESS_SALT),
			),
			TERRAIN_CAVE_EDGE_ALCOVE_RADIUS_MIN_BLOCKS,
			TERRAIN_CAVE_EDGE_ALCOVE_RADIUS_MAX_BLOCKS,
		)
		biome_id := edge.from_biome_id
		if t >= 0.5 {
			biome_id = edge.to_biome_id
		}
		radius_x := radius_base
		radius_y := radius_base * 0.58
		radius_z := radius_base * 0.86
		#partial switch biome_id {
		case .Fungal_Vaults:
			radius_x *= 1.18
			radius_z *= 1.08
			radius_y *= 0.92
		case .Crystal_Geode_Network:
			radius_x *= 0.74
			radius_y *= 0.72
			radius_z *= 1.12
		case .Buried_Aquifer_Caves:
			radius_x *= 1.06
			radius_y *= 0.58
			radius_z *= 1.02
		}
		throat_shape := terrain_density_cave_passage_shape(.Collapsed_Corridor)
		if biome_id == .Fungal_Vaults {
			throat_shape = terrain_density_cave_passage_shape(.Worm_Path)
		} else if biome_id == .Crystal_Geode_Network {
			throat_shape = terrain_density_cave_passage_shape(.Fracture)
		}
		throat_radius := math.max(f32(2.25), math.min(radius_base * 0.42, route_radius * 0.48))
		if !terrain_density_feature_segment_aabb_intersects_chunk(
			chunk_origin,
			route_x,
			route_y,
			route_z,
			center_x,
			center_y,
			center_z,
			math.max(math.max(radius_x, math.max(radius_y, radius_z)), throat_radius * f32(2.25)) +
			4,
		) {
			continue
		}
		terrain_density_cave_passage_shape_apply_biome(&throat_shape, biome_id)
		terrain_density_carve_rough_segment_shaped(
			view,
			key,
			chunk_origin,
			columns,
			route_x,
			route_y,
			route_z,
			center_x,
			center_y,
			center_z,
			throat_radius,
			throat_shape,
			TERRAIN_CAVE_BRANCH_SALT ~ u64(alcove_index + 17),
			biome_id,
		)
		terrain_density_carve_cave_room_lobed_ellipsoid(
			view,
			key,
			chunk_origin,
			columns,
			center_x,
			center_y,
			center_z,
			radius_x,
			radius_y,
			radius_z,
			TERRAIN_CAVE_BRANCH_SALT ~ u64(alcove_index + 1),
			biome_id,
			true,
		)
	}
}

terrain_density_carve_cave_edge_chamberlet_gallery_pocket :: proc(
	view: ^world_async.ChunkVoxelView,
	key: biomes.FeatureGridKey,
	chunk_origin: world_async.BlockCoord,
	columns: []TerrainBiomeColumn,
	center_x, center_y, center_z: f32,
	pocket_radius: f32,
	biome_id: biomes.BiomeID,
	salt: u64,
) {
	pocket_radius_x := pocket_radius * f32(1.18)
	pocket_radius_y := pocket_radius * f32(0.70)
	pocket_radius_z := pocket_radius * f32(1.02)
	#partial switch biome_id {
	case .Fungal_Vaults:
		pocket_radius_x *= 1.18
		pocket_radius_y *= 0.95
		pocket_radius_z *= 1.12
	case .Crystal_Geode_Network:
		pocket_radius_x *= 0.70
		pocket_radius_y *= 1.34
		pocket_radius_z *= 0.82
	case .Buried_Aquifer_Caves:
		pocket_radius_x *= 1.16
		pocket_radius_y *= 0.56
		pocket_radius_z *= 1.18
	}
	terrain_density_carve_cave_room_lobed_ellipsoid(
		view,
		key,
		chunk_origin,
		columns,
		center_x,
		center_y,
		center_z,
		pocket_radius_x,
		pocket_radius_y,
		pocket_radius_z,
		salt,
		biome_id,
		true,
	)
	terrain_density_carve_rough_ellipsoid(
		view,
		key,
		chunk_origin,
		columns,
		center_x,
		center_y,
		center_z,
		pocket_radius_x * f32(0.72),
		pocket_radius_y * f32(0.88),
		pocket_radius_z * f32(0.72),
		salt ~ TERRAIN_CAVE_FIELD_DETAIL_SALT,
		biome_id,
		true,
	)
}

terrain_density_carve_cave_edge_chamberlet_gallery :: proc(
	view: ^world_async.ChunkVoxelView,
	key: biomes.FeatureGridKey,
	chunk_origin: world_async.BlockCoord,
	columns: []TerrainBiomeColumn,
	from_x, from_y, from_z: f32,
	to_x, to_y, to_z: f32,
	from_radius, to_radius, route_radius: f32,
	biome_id: biomes.BiomeID,
	salt: u64,
) {
	gallery_radius := math.max(
		f32(2.0),
		math.min(
			math.min(from_radius, to_radius) * TERRAIN_CAVE_EDGE_CHAMBERLET_GALLERY_RADIUS_SCALE,
			route_radius * TERRAIN_CAVE_EDGE_CHAMBERLET_GALLERY_ROUTE_CAP_SCALE,
		),
	)
	shape := terrain_density_cave_passage_shape(.Collapsed_Corridor)
	#partial switch biome_id {
	case .Fungal_Vaults:
		shape = terrain_density_cave_passage_shape(.Worm_Path)
		shape.radius_y_scale = math.min(shape.radius_y_scale, f32(0.70))
	case .Crystal_Geode_Network:
		shape = terrain_density_cave_passage_shape(.Fracture)
	case .Buried_Aquifer_Caves:
		shape = terrain_density_cave_passage_shape(.Flooded_Passage)
		shape.radius_y_scale = math.min(shape.radius_y_scale, f32(0.48))
	}
	terrain_density_cave_passage_shape_apply_biome(&shape, biome_id)
	gallery_dx := to_x - from_x
	gallery_dy := to_y - from_y
	gallery_dz := to_z - from_z
	gallery_length := math.sqrt_f32(
		gallery_dx * gallery_dx + gallery_dy * gallery_dy + gallery_dz * gallery_dz,
	)
	if gallery_length <= 0.001 {
		return
	}
	horizontal_length := math.sqrt_f32(gallery_dx * gallery_dx + gallery_dz * gallery_dz)
	bend_side_x := f32(1)
	bend_side_z := f32(0)
	if horizontal_length > 0.001 {
		bend_side_x = -gallery_dz / horizontal_length
		bend_side_z = gallery_dx / horizontal_length
	}
	bend_sign := f32(1)
	if biomes.feature_grid_signed_unit_f32(salt, TERRAIN_CAVE_PASSAGE_RIB_SALT) < 0 {
		bend_sign = -1
	}
	bend_side_x *= bend_sign
	bend_side_z *= bend_sign
	vertical_sign := f32(1)
	if biomes.feature_grid_signed_unit_f32(salt, TERRAIN_CAVE_DETAIL_SALT) < 0 {
		vertical_sign = -1
	}
	bend_offset := math.min(
		route_radius * TERRAIN_CAVE_EDGE_CHAMBERLET_GALLERY_RELAY_OFFSET_SCALE,
		gallery_length * f32(0.10),
	)
	vertical_offset := math.min(
		route_radius * TERRAIN_CAVE_EDGE_CHAMBERLET_GALLERY_RELAY_VERTICAL_OFFSET_SCALE,
		gallery_length * f32(0.06),
	)
	#partial switch biome_id {
	case .Fungal_Vaults:
		bend_offset *= 1.12
		vertical_offset *= 0.86
	case .Crystal_Geode_Network:
		bend_offset *= 0.72
		vertical_offset *= 1.28
	case .Buried_Aquifer_Caves:
		bend_offset *= 1.08
		vertical_offset *= 0.62
	}
	relay_a_x := from_x + gallery_dx * f32(0.34) + bend_side_x * bend_offset
	relay_a_y := from_y + gallery_dy * f32(0.34) + vertical_sign * vertical_offset
	relay_a_z := from_z + gallery_dz * f32(0.34) + bend_side_z * bend_offset
	relay_b_x := from_x + gallery_dx * f32(0.67) - bend_side_x * bend_offset * f32(0.58)
	relay_b_y := from_y + gallery_dy * f32(0.67) - vertical_sign * vertical_offset * f32(0.46)
	relay_b_z := from_z + gallery_dz * f32(0.67) - bend_side_z * bend_offset * f32(0.58)

	terrain_density_carve_rough_segment_shaped(
		view,
		key,
		chunk_origin,
		columns,
		from_x,
		from_y,
		from_z,
		relay_a_x,
		relay_a_y,
		relay_a_z,
		gallery_radius,
		shape,
		salt,
		biome_id,
		true,
	)
	terrain_density_carve_rough_segment_shaped(
		view,
		key,
		chunk_origin,
		columns,
		relay_a_x,
		relay_a_y,
		relay_a_z,
		relay_b_x,
		relay_b_y,
		relay_b_z,
		gallery_radius,
		shape,
		salt ~ TERRAIN_CAVE_FIELD_DETAIL_SALT,
		biome_id,
		true,
	)
	terrain_density_carve_rough_segment_shaped(
		view,
		key,
		chunk_origin,
		columns,
		relay_b_x,
		relay_b_y,
		relay_b_z,
		to_x,
		to_y,
		to_z,
		gallery_radius,
		shape,
		salt ~ TERRAIN_CAVE_FIELD_CHAMBER_SALT,
		biome_id,
		true,
	)

	relay_pocket_radius :=
		gallery_radius * TERRAIN_CAVE_EDGE_CHAMBERLET_GALLERY_RELAY_POCKET_RADIUS_SCALE
	terrain_density_carve_cave_edge_chamberlet_gallery_pocket(
		view,
		key,
		chunk_origin,
		columns,
		relay_a_x,
		relay_a_y,
		relay_a_z,
		relay_pocket_radius,
		biome_id,
		salt ~ u64(313),
	)
	terrain_density_carve_cave_edge_chamberlet_gallery_pocket(
		view,
		key,
		chunk_origin,
		columns,
		relay_b_x,
		relay_b_y,
		relay_b_z,
		relay_pocket_radius,
		biome_id,
		salt ~ u64(347),
	)
	terrain_density_carve_cave_edge_chamberlet_gallery_pocket(
		view,
		key,
		chunk_origin,
		columns,
		(relay_a_x + relay_b_x) * f32(0.5),
		(relay_a_y + relay_b_y) * f32(0.5),
		(relay_a_z + relay_b_z) * f32(0.5),
		gallery_radius * TERRAIN_CAVE_EDGE_CHAMBERLET_GALLERY_POCKET_RADIUS_SCALE,
		biome_id,
		salt ~ TERRAIN_CAVE_BRANCH_SALT,
	)
}

terrain_density_carve_cave_edge_chamberlets :: proc(
	view: ^world_async.ChunkVoxelView,
	key: biomes.FeatureGridKey,
	chunk_origin: world_async.BlockCoord,
	columns: []TerrainBiomeColumn,
	edge: biomes.CaveNetworkEdge,
	route_radius: f32,
	wall_buffer: ^TerrainCaveWallMaterialBuffer = nil,
) {
	positive_gallery_found := false
	positive_gallery_x := f32(0)
	positive_gallery_y := f32(0)
	positive_gallery_z := f32(0)
	positive_gallery_radius := f32(0)
	negative_gallery_found := false
	negative_gallery_x := f32(0)
	negative_gallery_y := f32(0)
	negative_gallery_z := f32(0)
	negative_gallery_radius := f32(0)
	for chamberlet_index := u32(0);
	    chamberlet_index < TERRAIN_CAVE_EDGE_CHAMBERLET_COUNT;
	    chamberlet_index += 1 {
		hash := biomes.feature_grid_hash_combine(u64(edge.id), TERRAIN_CAVE_ROOM_DETAIL_SALT)
		hash = biomes.feature_grid_hash_combine(hash, u64(chamberlet_index))
		step_t := (f32(chamberlet_index) + 0.5) / f32(TERRAIN_CAVE_EDGE_CHAMBERLET_COUNT)
		jitter := biomes.feature_grid_signed_unit_f32(hash, TERRAIN_CAVE_CURVE_SALT) * f32(0.055)
		t := math.clamp(
			biomes.regional_terrain_field_lerp(
				TERRAIN_CAVE_EDGE_CHAMBERLET_ROUTE_MARGIN,
				1.0 - TERRAIN_CAVE_EDGE_CHAMBERLET_ROUTE_MARGIN,
				step_t,
			) +
			jitter,
			TERRAIN_CAVE_EDGE_CHAMBERLET_ROUTE_MARGIN,
			1.0 - TERRAIN_CAVE_EDGE_CHAMBERLET_ROUTE_MARGIN,
		)
		route_x, route_y, route_z := terrain_density_cave_edge_route_point(edge, t)
		prev_x, prev_y, prev_z := terrain_density_cave_edge_route_point(
			edge,
			math.max(f32(0), t - 0.06),
		)
		next_x, next_y, next_z := terrain_density_cave_edge_route_point(
			edge,
			math.min(f32(1), t + 0.06),
		)
		tangent_x, _, tangent_z := terrain_density_delta_3(
			prev_x,
			prev_y,
			prev_z,
			next_x,
			next_y,
			next_z,
		)
		horizontal_length := math.sqrt_f32(tangent_x * tangent_x + tangent_z * tangent_z)
		side_x := f32(1)
		side_z := f32(0)
		if horizontal_length > 0.001 {
			side_x = -tangent_z / horizontal_length
			side_z = tangent_x / horizontal_length
		}
		side_sign := f32(1)
		if (chamberlet_index & 1) != 0 {
			side_sign = -1
		}
		if biomes.feature_grid_signed_unit_f32(hash, TERRAIN_CAVE_PASSAGE_RIB_SALT) < 0 {
			side_sign = -side_sign
		}
		side_x *= side_sign
		side_z *= side_sign

		radius_base := math.clamp(
			route_radius *
			biomes.regional_terrain_field_lerp(
				f32(0.34),
				f32(0.56),
				biomes.feature_grid_unit_f32(hash, TERRAIN_CAVE_ROUGHNESS_SALT),
			),
			TERRAIN_CAVE_EDGE_CHAMBERLET_RADIUS_MIN_BLOCKS,
			TERRAIN_CAVE_EDGE_CHAMBERLET_RADIUS_MAX_BLOCKS,
		)
		center_x :=
			route_x +
			side_x *
				route_radius *
				TERRAIN_CAVE_EDGE_CHAMBERLET_SIDE_OFFSET_SCALE *
				biomes.regional_terrain_field_lerp(
					f32(0.72),
					f32(1.14),
					biomes.feature_grid_unit_f32(hash, TERRAIN_CAVE_FIELD_DETAIL_SALT),
				)
		center_y :=
			route_y +
			biomes.feature_grid_signed_unit_f32(hash, TERRAIN_CAVE_BRANCH_SALT) *
				route_radius *
				f32(0.16)
		center_z :=
			route_z +
			side_z *
				route_radius *
				TERRAIN_CAVE_EDGE_CHAMBERLET_SIDE_OFFSET_SCALE *
				biomes.regional_terrain_field_lerp(
					f32(0.72),
					f32(1.14),
					biomes.feature_grid_unit_f32(hash, TERRAIN_CAVE_FIELD_DETAIL_SALT),
				)

		biome_id := edge.from_biome_id
		if t >= 0.5 {
			biome_id = edge.to_biome_id
		}
		radius_x := radius_base
		radius_y := radius_base * 0.56
		radius_z := radius_base * 0.88
		#partial switch biome_id {
		case .Fungal_Vaults:
			radius_x *= 1.16
			radius_z *= 1.06
			radius_y *= 0.90
		case .Crystal_Geode_Network:
			radius_x *= 0.70
			radius_y *= 0.82
			radius_z *= 1.12
		case .Buried_Aquifer_Caves:
			radius_x *= 1.08
			radius_y *= 0.48
			radius_z *= 1.08
		}
		throat_shape := terrain_density_cave_passage_shape(.Collapsed_Corridor)
		if biome_id == .Fungal_Vaults {
			throat_shape = terrain_density_cave_passage_shape(.Worm_Path)
			throat_shape.radius_y_scale = math.min(throat_shape.radius_y_scale, f32(0.66))
		} else if biome_id == .Crystal_Geode_Network {
			throat_shape = terrain_density_cave_passage_shape(.Fracture)
		}
		terrain_density_cave_passage_shape_apply_biome(&throat_shape, biome_id)
		throat_radius := math.max(
			f32(1.75),
			math.min(radius_base * f32(0.36), route_radius * f32(0.24)),
		)
		terrain_density_carve_rough_segment_shaped(
			view,
			key,
			chunk_origin,
			columns,
			route_x,
			route_y,
			route_z,
			center_x,
			center_y,
			center_z,
			throat_radius,
			throat_shape,
			TERRAIN_CAVE_ROOM_DETAIL_SALT ~ u64(chamberlet_index + 31),
			biome_id,
		)
		terrain_density_carve_cave_room_lobed_ellipsoid(
			view,
			key,
			chunk_origin,
			columns,
			center_x,
			center_y,
			center_z,
			radius_x,
			radius_y,
			radius_z,
			TERRAIN_CAVE_ROOM_DETAIL_SALT ~ u64(chamberlet_index + 47),
			biome_id,
			true,
		)
		if side_sign >= 0 {
			if positive_gallery_found {
				terrain_density_carve_cave_edge_chamberlet_gallery(
					view,
					key,
					chunk_origin,
					columns,
					positive_gallery_x,
					positive_gallery_y,
					positive_gallery_z,
					center_x,
					center_y,
					center_z,
					positive_gallery_radius,
					radius_base,
					route_radius,
					biome_id,
					TERRAIN_CAVE_ROOM_DETAIL_SALT ~ u64(chamberlet_index * 67 + 719),
				)
			}
			positive_gallery_found = true
			positive_gallery_x = center_x
			positive_gallery_y = center_y
			positive_gallery_z = center_z
			positive_gallery_radius = radius_base
		} else {
			if negative_gallery_found {
				terrain_density_carve_cave_edge_chamberlet_gallery(
					view,
					key,
					chunk_origin,
					columns,
					negative_gallery_x,
					negative_gallery_y,
					negative_gallery_z,
					center_x,
					center_y,
					center_z,
					negative_gallery_radius,
					radius_base,
					route_radius,
					biome_id,
					TERRAIN_CAVE_ROOM_DETAIL_SALT ~ u64(chamberlet_index * 67 + 769),
				)
			}
			negative_gallery_found = true
			negative_gallery_x = center_x
			negative_gallery_y = center_y
			negative_gallery_z = center_z
			negative_gallery_radius = radius_base
		}
		terrain_density_carve_cave_edge_chamberlet_biome_detail(
			view,
			key,
			chunk_origin,
			columns,
			route_x,
			route_y,
			route_z,
			center_x,
			center_y,
			center_z,
			side_x,
			side_z,
			radius_base,
			route_radius,
			biome_id,
			hash,
			chamberlet_index,
		)
	}
}

terrain_density_carve_cave_edge_seam_bays :: proc(
	view: ^world_async.ChunkVoxelView,
	key: biomes.FeatureGridKey,
	chunk_origin: world_async.BlockCoord,
	columns: []TerrainBiomeColumn,
	edge: biomes.CaveNetworkEdge,
	route_radius: f32,
	wall_buffer: ^TerrainCaveWallMaterialBuffer = nil,
) {
	if !edge.regional_seam_connection || edge.kind != .Canyon {
		return
	}
	for bay_index := u32(0); bay_index < TERRAIN_CAVE_EDGE_SEAM_BAY_COUNT; bay_index += 1 {
		hash := biomes.feature_grid_hash_combine(u64(edge.id), TERRAIN_CAVE_FIELD_DETAIL_SALT)
		hash = biomes.feature_grid_hash_combine(hash, u64(bay_index + 271))
		step_t := (f32(bay_index) + 0.5) / f32(TERRAIN_CAVE_EDGE_SEAM_BAY_COUNT)
		jitter := biomes.feature_grid_signed_unit_f32(hash, TERRAIN_CAVE_CURVE_SALT) * f32(0.055)
		t := math.clamp(
			biomes.regional_terrain_field_lerp(
				TERRAIN_CAVE_EDGE_SEAM_BAY_ROUTE_MARGIN,
				1.0 - TERRAIN_CAVE_EDGE_SEAM_BAY_ROUTE_MARGIN,
				step_t,
			) +
			jitter,
			TERRAIN_CAVE_EDGE_SEAM_BAY_ROUTE_MARGIN,
			1.0 - TERRAIN_CAVE_EDGE_SEAM_BAY_ROUTE_MARGIN,
		)
		route_x, route_y, route_z := terrain_density_cave_edge_route_point(edge, t)
		prev_x, prev_y, prev_z := terrain_density_cave_edge_route_point(
			edge,
			math.max(f32(0), t - 0.08),
		)
		next_x, next_y, next_z := terrain_density_cave_edge_route_point(
			edge,
			math.min(f32(1), t + 0.08),
		)
		tangent_x, _, tangent_z := terrain_density_delta_3(
			prev_x,
			prev_y,
			prev_z,
			next_x,
			next_y,
			next_z,
		)
		horizontal_length := math.sqrt_f32(tangent_x * tangent_x + tangent_z * tangent_z)
		side_x := f32(1)
		side_z := f32(0)
		if horizontal_length > 0.001 {
			side_x = -tangent_z / horizontal_length
			side_z = tangent_x / horizontal_length
		}
		side_sign := f32(1)
		if (bay_index & 1) != 0 {
			side_sign = -1
		}
		if biomes.feature_grid_signed_unit_f32(hash, TERRAIN_CAVE_PASSAGE_RIB_SALT) < 0 {
			side_sign = -side_sign
		}
		side_x *= side_sign
		side_z *= side_sign

		vertical_sign := f32(1)
		if biomes.feature_grid_signed_unit_f32(hash, TERRAIN_CAVE_BRANCH_SALT) < 0 {
			vertical_sign = -1
		}
		side_offset :=
			route_radius *
			TERRAIN_CAVE_EDGE_SEAM_BAY_SIDE_OFFSET_SCALE *
			biomes.regional_terrain_field_lerp(
				f32(0.78),
				f32(1.22),
				biomes.feature_grid_unit_f32(hash, TERRAIN_CAVE_FIELD_CHAMBER_SALT),
			)
		vertical_offset :=
			route_radius *
			TERRAIN_CAVE_EDGE_SEAM_BAY_VERTICAL_OFFSET_SCALE *
			vertical_sign *
			biomes.regional_terrain_field_lerp(
				f32(0.45),
				f32(1.0),
				biomes.feature_grid_unit_f32(hash, TERRAIN_CAVE_DETAIL_SALT),
			)
		center_x := route_x + side_x * side_offset
		center_y := route_y + vertical_offset
		center_z := route_z + side_z * side_offset

		biome_id := edge.from_biome_id
		if t >= 0.5 {
			biome_id = edge.to_biome_id
		}
		radius_base := math.clamp(
			route_radius *
			biomes.regional_terrain_field_lerp(
				f32(0.72),
				f32(1.04),
				biomes.feature_grid_unit_f32(hash, TERRAIN_CAVE_ROUGHNESS_SALT),
			),
			TERRAIN_CAVE_EDGE_SEAM_BAY_RADIUS_MIN_BLOCKS,
			TERRAIN_CAVE_EDGE_SEAM_BAY_RADIUS_MAX_BLOCKS,
		)
		radius_x := radius_base * 1.10
		radius_y := radius_base * 0.94
		radius_z := radius_base * 1.08
		if vertical_sign > 0 {
			radius_y *= 1.16
		} else {
			radius_x *= 1.08
			radius_z *= 1.08
		}
		#partial switch biome_id {
		case .Fungal_Vaults:
			radius_x *= 1.14
			radius_z *= 1.10
			radius_y *= 1.04
		case .Crystal_Geode_Network:
			radius_x *= 0.82
			radius_y *= 1.18
			radius_z *= 0.92
		case .Buried_Aquifer_Caves:
			radius_x *= 1.12
			radius_y *= 0.72
			radius_z *= 1.12
		}

		bay_shape := terrain_density_cave_passage_shape(.Canyon)
		terrain_density_cave_passage_shape_apply_regional_seam(&bay_shape)
		terrain_density_cave_passage_shape_apply_biome(&bay_shape, biome_id)
		throat_radius := math.max(
			f32(3.0),
			math.min(
				radius_base * f32(0.58),
				route_radius * TERRAIN_CAVE_EDGE_SEAM_BAY_THROAT_SCALE,
			),
		)
		terrain_density_carve_rough_segment_shaped(
			view,
			key,
			chunk_origin,
			columns,
			route_x,
			route_y,
			route_z,
			center_x,
			center_y,
			center_z,
			throat_radius,
			bay_shape,
			TERRAIN_CAVE_FIELD_DETAIL_SALT ~ u64(bay_index + 401),
			biome_id,
			true,
		)
		terrain_density_carve_cave_room_lobed_ellipsoid(
			view,
			key,
			chunk_origin,
			columns,
			center_x,
			center_y,
			center_z,
			radius_x,
			radius_y,
			radius_z,
			TERRAIN_CAVE_FIELD_DETAIL_SALT ~ u64(bay_index + 443),
			biome_id,
			true,
		)
	}
}

terrain_density_carve_cave_edge_seam_bypasses :: proc(
	view: ^world_async.ChunkVoxelView,
	key: biomes.FeatureGridKey,
	chunk_origin: world_async.BlockCoord,
	columns: []TerrainBiomeColumn,
	edge: biomes.CaveNetworkEdge,
	route_radius: f32,
	wall_buffer: ^TerrainCaveWallMaterialBuffer = nil,
) {
	if !edge.regional_seam_connection || edge.kind != .Canyon {
		return
	}
	for bypass_index := u32(0);
	    bypass_index < TERRAIN_CAVE_EDGE_SEAM_BYPASS_COUNT;
	    bypass_index += 1 {
		hash := biomes.feature_grid_hash_combine(u64(edge.id), TERRAIN_CAVE_ROOM_DETAIL_SALT)
		hash = biomes.feature_grid_hash_combine(hash, u64(bypass_index + 931))
		step_t := (f32(bypass_index) + 0.5) / f32(TERRAIN_CAVE_EDGE_SEAM_BYPASS_COUNT)
		jitter := biomes.feature_grid_signed_unit_f32(hash, TERRAIN_CAVE_CURVE_SALT) * f32(0.050)
		center_t := math.clamp(
			biomes.regional_terrain_field_lerp(
				TERRAIN_CAVE_EDGE_SEAM_BYPASS_ROUTE_MARGIN,
				1.0 - TERRAIN_CAVE_EDGE_SEAM_BYPASS_ROUTE_MARGIN,
				step_t,
			) +
			jitter,
			TERRAIN_CAVE_EDGE_SEAM_BYPASS_ROUTE_MARGIN,
			1.0 - TERRAIN_CAVE_EDGE_SEAM_BYPASS_ROUTE_MARGIN,
		)
		span_t := biomes.regional_terrain_field_lerp(
			TERRAIN_CAVE_EDGE_SEAM_BYPASS_SPAN_T_MIN,
			TERRAIN_CAVE_EDGE_SEAM_BYPASS_SPAN_T_MAX,
			biomes.feature_grid_unit_f32(hash, TERRAIN_CAVE_FIELD_DETAIL_SALT),
		)
		half_span := span_t * f32(0.5)
		from_t := math.max(
			TERRAIN_CAVE_EDGE_SEAM_BYPASS_ROUTE_MARGIN * f32(0.5),
			center_t - half_span,
		)
		to_t := math.min(
			1.0 - TERRAIN_CAVE_EDGE_SEAM_BYPASS_ROUTE_MARGIN * f32(0.5),
			center_t + half_span,
		)
		if to_t <= from_t + 0.070 {
			continue
		}

		from_x, from_y, from_z := terrain_density_cave_edge_route_point(edge, from_t)
		route_x, route_y, route_z := terrain_density_cave_edge_route_point(edge, center_t)
		to_x, to_y, to_z := terrain_density_cave_edge_route_point(edge, to_t)
		tangent_x, _, tangent_z := terrain_density_delta_3(
			from_x,
			from_y,
			from_z,
			to_x,
			to_y,
			to_z,
		)
		horizontal_length := math.sqrt_f32(tangent_x * tangent_x + tangent_z * tangent_z)
		side_x := f32(1)
		side_z := f32(0)
		if horizontal_length > 0.001 {
			side_x = -tangent_z / horizontal_length
			side_z = tangent_x / horizontal_length
		}
		side_sign := f32(1)
		if (bypass_index & 1) != 0 {
			side_sign = -1
		}
		if biomes.feature_grid_signed_unit_f32(hash, TERRAIN_CAVE_PASSAGE_RIB_SALT) < -0.15 {
			side_sign = -side_sign
		}
		side_x *= side_sign
		side_z *= side_sign

		vertical_sign := side_sign
		side_offset :=
			route_radius *
			TERRAIN_CAVE_EDGE_SEAM_BYPASS_SIDE_OFFSET_SCALE *
			biomes.regional_terrain_field_lerp(
				f32(0.82),
				f32(1.24),
				biomes.feature_grid_unit_f32(hash, TERRAIN_CAVE_FIELD_CHAMBER_SALT),
			)
		vertical_offset :=
			route_radius *
			TERRAIN_CAVE_EDGE_SEAM_BYPASS_VERTICAL_OFFSET_SCALE *
			vertical_sign *
			biomes.regional_terrain_field_lerp(
				f32(0.66),
				f32(1.12),
				biomes.feature_grid_unit_f32(hash, TERRAIN_CAVE_DETAIL_SALT),
			)
		relay_offset :=
			route_radius *
			TERRAIN_CAVE_EDGE_SEAM_BYPASS_RELAY_OFFSET_SCALE *
			biomes.feature_grid_signed_unit_f32(hash, TERRAIN_CAVE_ROUGHNESS_SALT)

		from_bypass_x := from_x + side_x * side_offset * f32(0.72)
		from_bypass_y := from_y + vertical_offset * f32(0.58)
		from_bypass_z := from_z + side_z * side_offset * f32(0.72)
		center_bypass_x := route_x + side_x * (side_offset + relay_offset)
		center_bypass_y := route_y + vertical_offset
		center_bypass_z := route_z + side_z * (side_offset + relay_offset)
		to_bypass_x := to_x + side_x * side_offset * f32(0.72)
		to_bypass_y := to_y + vertical_offset * f32(0.58)
		to_bypass_z := to_z + side_z * side_offset * f32(0.72)

		biome_id := edge.from_biome_id
		if center_t >= 0.5 {
			biome_id = edge.to_biome_id
		}
		bypass_radius := math.clamp(
			route_radius *
			biomes.regional_terrain_field_lerp(
				f32(0.48),
				f32(0.68),
				biomes.feature_grid_unit_f32(hash, TERRAIN_CAVE_ROUGHNESS_SALT),
			),
			TERRAIN_CAVE_EDGE_SEAM_BYPASS_RADIUS_MIN_BLOCKS,
			TERRAIN_CAVE_EDGE_SEAM_BYPASS_RADIUS_MAX_BLOCKS,
		)
		bypass_shape := terrain_density_cave_passage_shape(.Canyon)
		terrain_density_cave_passage_shape_apply_regional_seam(&bypass_shape)
		terrain_density_cave_passage_shape_apply_biome(&bypass_shape, biome_id)
		bypass_shape.radius_neck_scale = math.max(bypass_shape.radius_neck_scale, f32(0.14))
		bypass_shape.radius_swell_scale = math.max(bypass_shape.radius_swell_scale, f32(0.34))
		bypass_shape.meander_scale = math.max(bypass_shape.meander_scale, f32(0.82))
		bypass_shape.curve_scale = math.max(bypass_shape.curve_scale, f32(0.22))
		if vertical_sign > 0 {
			bypass_shape.radius_y_scale = math.max(bypass_shape.radius_y_scale, f32(1.18))
			bypass_shape.radius_x_scale *= 0.94
			bypass_shape.radius_z_scale *= 0.94
		} else {
			bypass_shape.radius_y_scale = math.min(bypass_shape.radius_y_scale, f32(0.78))
			bypass_shape.radius_x_scale = math.max(bypass_shape.radius_x_scale, f32(1.26))
			bypass_shape.radius_z_scale = math.max(bypass_shape.radius_z_scale, f32(1.20))
		}
		throat_radius := math.max(
			f32(2.25),
			math.min(
				bypass_radius * TERRAIN_CAVE_EDGE_SEAM_BYPASS_THROAT_SCALE,
				route_radius * f32(0.30),
			),
		)
		terrain_density_carve_rough_segment_shaped(
			view,
			key,
			chunk_origin,
			columns,
			from_x,
			from_y,
			from_z,
			from_bypass_x,
			from_bypass_y,
			from_bypass_z,
			throat_radius,
			bypass_shape,
			TERRAIN_CAVE_ROOM_DETAIL_SALT ~ u64(bypass_index + 967),
			biome_id,
			true,
		)
		terrain_density_carve_rough_segment_shaped(
			view,
			key,
			chunk_origin,
			columns,
			to_x,
			to_y,
			to_z,
			to_bypass_x,
			to_bypass_y,
			to_bypass_z,
			throat_radius,
			bypass_shape,
			TERRAIN_CAVE_ROOM_DETAIL_SALT ~ u64(bypass_index + 991),
			biome_id,
			true,
		)
		terrain_density_carve_rough_segment_shaped(
			view,
			key,
			chunk_origin,
			columns,
			from_bypass_x,
			from_bypass_y,
			from_bypass_z,
			center_bypass_x,
			center_bypass_y,
			center_bypass_z,
			bypass_radius,
			bypass_shape,
			TERRAIN_CAVE_BRANCH_SALT ~ u64(bypass_index + 1013),
			biome_id,
			true,
		)
		terrain_density_carve_rough_segment_shaped(
			view,
			key,
			chunk_origin,
			columns,
			center_bypass_x,
			center_bypass_y,
			center_bypass_z,
			to_bypass_x,
			to_bypass_y,
			to_bypass_z,
			bypass_radius,
			bypass_shape,
			TERRAIN_CAVE_BRANCH_SALT ~ u64(bypass_index + 1031),
			biome_id,
			true,
		)

		room_radius := bypass_radius * TERRAIN_CAVE_EDGE_SEAM_BYPASS_ROOM_RADIUS_SCALE
		radius_x := room_radius * f32(1.18)
		radius_y := room_radius * f32(0.82)
		radius_z := room_radius * f32(1.08)
		if vertical_sign > 0 {
			radius_y *= 1.18
			radius_x *= 0.92
			radius_z *= 0.94
		} else {
			radius_x *= 1.12
			radius_y *= 0.70
			radius_z *= 1.10
		}
		#partial switch biome_id {
		case .Fungal_Vaults:
			radius_x *= 1.16
			radius_z *= 1.10
			radius_y *= 1.04
		case .Crystal_Geode_Network:
			radius_x *= 0.74
			radius_y *= 1.26
			radius_z *= 0.82
		case .Buried_Aquifer_Caves:
			radius_x *= 1.14
			radius_y *= 0.68
			radius_z *= 1.16
		case .Temperate_Hills, .Basalt_Spire_Highlands, .Wet_Lowland_Marsh, .Corrupted_Ash_Forest:
		}
		terrain_density_carve_cave_room_lobed_ellipsoid(
			view,
			key,
			chunk_origin,
			columns,
			center_bypass_x,
			center_bypass_y,
			center_bypass_z,
			radius_x,
			radius_y,
			radius_z,
			TERRAIN_CAVE_ROOM_DETAIL_SALT ~ u64(bypass_index + 1051),
			biome_id,
			true,
		)
	}
}

terrain_density_carve_cave_edge_seam_crosscuts :: proc(
	view: ^world_async.ChunkVoxelView,
	key: biomes.FeatureGridKey,
	chunk_origin: world_async.BlockCoord,
	columns: []TerrainBiomeColumn,
	edge: biomes.CaveNetworkEdge,
	route_radius: f32,
	wall_buffer: ^TerrainCaveWallMaterialBuffer = nil,
) {
	if !edge.regional_seam_connection || edge.kind != .Canyon {
		return
	}
	for crosscut_index := u32(0);
	    crosscut_index < TERRAIN_CAVE_EDGE_SEAM_CROSSCUT_COUNT;
	    crosscut_index += 1 {
		hash := biomes.feature_grid_hash_combine(u64(edge.id), TERRAIN_CAVE_PASSAGE_RIB_SALT)
		hash = biomes.feature_grid_hash_combine(hash, u64(crosscut_index + 1129))
		step_t := (f32(crosscut_index) + 0.5) / f32(TERRAIN_CAVE_EDGE_SEAM_CROSSCUT_COUNT)
		jitter := biomes.feature_grid_signed_unit_f32(hash, TERRAIN_CAVE_CURVE_SALT) * f32(0.045)
		center_t := math.clamp(
			biomes.regional_terrain_field_lerp(
				TERRAIN_CAVE_EDGE_SEAM_CROSSCUT_ROUTE_MARGIN,
				1.0 - TERRAIN_CAVE_EDGE_SEAM_CROSSCUT_ROUTE_MARGIN,
				step_t,
			) +
			jitter,
			TERRAIN_CAVE_EDGE_SEAM_CROSSCUT_ROUTE_MARGIN,
			1.0 - TERRAIN_CAVE_EDGE_SEAM_CROSSCUT_ROUTE_MARGIN,
		)
		half_span := TERRAIN_CAVE_EDGE_SEAM_CROSSCUT_SPAN_T * f32(0.5)
		from_t := math.max(
			TERRAIN_CAVE_EDGE_SEAM_CROSSCUT_ROUTE_MARGIN * f32(0.5),
			center_t - half_span,
		)
		to_t := math.min(
			1.0 - TERRAIN_CAVE_EDGE_SEAM_CROSSCUT_ROUTE_MARGIN * f32(0.5),
			center_t + half_span,
		)
		if to_t <= from_t + 0.045 {
			continue
		}

		from_x, from_y, from_z := terrain_density_cave_edge_route_point(edge, from_t)
		route_x, route_y, route_z := terrain_density_cave_edge_route_point(edge, center_t)
		to_x, to_y, to_z := terrain_density_cave_edge_route_point(edge, to_t)
		tangent_x, _, tangent_z := terrain_density_delta_3(
			from_x,
			from_y,
			from_z,
			to_x,
			to_y,
			to_z,
		)
		horizontal_length := math.sqrt_f32(tangent_x * tangent_x + tangent_z * tangent_z)
		side_x := f32(1)
		side_z := f32(0)
		if horizontal_length > 0.001 {
			side_x = -tangent_z / horizontal_length
			side_z = tangent_x / horizontal_length
		}
		side_sign := f32(1)
		if (crosscut_index & 1) != 0 {
			side_sign = -1
		}
		if biomes.feature_grid_signed_unit_f32(hash, TERRAIN_CAVE_BRANCH_SALT) < -0.15 {
			side_sign = -side_sign
		}
		side_x *= side_sign
		side_z *= side_sign
		vertical_sign := f32(1)
		if (crosscut_index & 2) != 0 {
			vertical_sign = -1
		}
		if biomes.feature_grid_signed_unit_f32(hash, TERRAIN_CAVE_DETAIL_SALT) < -0.30 {
			vertical_sign = -vertical_sign
		}

		side_offset :=
			route_radius *
			TERRAIN_CAVE_EDGE_SEAM_CROSSCUT_SIDE_OFFSET_SCALE *
			biomes.regional_terrain_field_lerp(
				f32(0.80),
				f32(1.18),
				biomes.feature_grid_unit_f32(hash, TERRAIN_CAVE_FIELD_CHAMBER_SALT),
			)
		vertical_offset :=
			route_radius *
			TERRAIN_CAVE_EDGE_SEAM_CROSSCUT_VERTICAL_OFFSET_SCALE *
			vertical_sign *
			biomes.regional_terrain_field_lerp(
				f32(0.74),
				f32(1.16),
				biomes.feature_grid_unit_f32(hash, TERRAIN_CAVE_ROUGHNESS_SALT),
			)
		from_cut_x := from_x + side_x * side_offset
		from_cut_y := from_y + vertical_offset
		from_cut_z := from_z + side_z * side_offset
		to_cut_x := to_x - side_x * side_offset
		to_cut_y := to_y - vertical_offset * f32(0.72)
		to_cut_z := to_z - side_z * side_offset

		biome_id := edge.from_biome_id
		if center_t >= 0.5 {
			biome_id = edge.to_biome_id
		}
		crosscut_radius := math.clamp(
			route_radius *
			biomes.regional_terrain_field_lerp(
				f32(0.52),
				f32(0.72),
				biomes.feature_grid_unit_f32(hash, TERRAIN_CAVE_FIELD_DETAIL_SALT),
			),
			TERRAIN_CAVE_EDGE_SEAM_CROSSCUT_RADIUS_MIN_BLOCKS,
			TERRAIN_CAVE_EDGE_SEAM_CROSSCUT_RADIUS_MAX_BLOCKS,
		)
		crosscut_shape := terrain_density_cave_passage_shape(.Canyon)
		terrain_density_cave_passage_shape_apply_regional_seam(&crosscut_shape)
		terrain_density_cave_passage_shape_apply_biome(&crosscut_shape, biome_id)
		crosscut_shape.radius_neck_scale = math.max(crosscut_shape.radius_neck_scale, f32(0.16))
		crosscut_shape.radius_swell_scale = math.max(crosscut_shape.radius_swell_scale, f32(0.32))
		crosscut_shape.meander_scale = math.max(crosscut_shape.meander_scale, f32(0.74))
		crosscut_shape.curve_scale = math.max(crosscut_shape.curve_scale, f32(0.18))
		branch_x :=
			route_x + side_x * side_offset * TERRAIN_CAVE_EDGE_SEAM_CROSSCUT_NODE_SIDE_SCALE
		branch_y := route_y + vertical_offset * TERRAIN_CAVE_EDGE_SEAM_CROSSCUT_NODE_VERTICAL_SCALE
		branch_z :=
			route_z + side_z * side_offset * TERRAIN_CAVE_EDGE_SEAM_CROSSCUT_NODE_SIDE_SCALE
		from_branch_x := from_x + side_x * side_offset * f32(0.96)
		from_branch_y := from_y + vertical_offset * f32(0.58)
		from_branch_z := from_z + side_z * side_offset * f32(0.96)
		to_branch_x := to_x + side_x * side_offset * f32(0.96)
		to_branch_y := to_y + vertical_offset * f32(0.32)
		to_branch_z := to_z + side_z * side_offset * f32(0.96)
		mouth_radius := math.max(
			f32(3.75),
			math.min(
				crosscut_radius * TERRAIN_CAVE_EDGE_SEAM_CROSSCUT_MOUTH_RADIUS_SCALE,
				route_radius * f32(0.68),
			),
		)
		branch_radius := math.max(
			f32(3.25),
			math.min(
				crosscut_radius * TERRAIN_CAVE_EDGE_SEAM_CROSSCUT_BRANCH_RADIUS_SCALE,
				route_radius * f32(0.62),
			),
		)
		terrain_density_carve_rough_segment_shaped(
			view,
			key,
			chunk_origin,
			columns,
			route_x,
			route_y,
			route_z,
			branch_x,
			branch_y,
			branch_z,
			mouth_radius,
			crosscut_shape,
			TERRAIN_CAVE_PASSAGE_RIB_SALT ~ u64(crosscut_index + 1133),
			biome_id,
			true,
		)
		terrain_density_carve_rough_segment_shaped(
			view,
			key,
			chunk_origin,
			columns,
			branch_x,
			branch_y,
			branch_z,
			from_branch_x,
			from_branch_y,
			from_branch_z,
			branch_radius,
			crosscut_shape,
			TERRAIN_CAVE_PASSAGE_RIB_SALT ~ u64(crosscut_index + 1147),
			biome_id,
			true,
		)
		terrain_density_carve_rough_segment_shaped(
			view,
			key,
			chunk_origin,
			columns,
			branch_x,
			branch_y,
			branch_z,
			to_branch_x,
			to_branch_y,
			to_branch_z,
			branch_radius,
			crosscut_shape,
			TERRAIN_CAVE_PASSAGE_RIB_SALT ~ u64(crosscut_index + 1151),
			biome_id,
			true,
		)
		terrain_density_carve_rough_segment_shaped(
			view,
			key,
			chunk_origin,
			columns,
			from_cut_x,
			from_cut_y,
			from_cut_z,
			to_cut_x,
			to_cut_y,
			to_cut_z,
			crosscut_radius,
			crosscut_shape,
			TERRAIN_CAVE_PASSAGE_RIB_SALT ~ u64(crosscut_index + 1163),
			biome_id,
			true,
		)

		node_radius := crosscut_radius * TERRAIN_CAVE_EDGE_SEAM_CROSSCUT_NODE_RADIUS_SCALE
		radius_x := node_radius * f32(1.08)
		radius_y := node_radius * f32(0.78)
		radius_z := node_radius * f32(1.00)
		if vertical_sign > 0 {
			radius_y *= 1.14
		} else {
			radius_x *= 1.12
			radius_z *= 1.08
			radius_y *= 0.78
		}
		#partial switch biome_id {
		case .Fungal_Vaults:
			radius_x *= 1.12
			radius_z *= 1.08
			radius_y *= 1.02
		case .Crystal_Geode_Network:
			radius_x *= 0.78
			radius_y *= 1.24
			radius_z *= 0.86
		case .Buried_Aquifer_Caves:
			radius_x *= 1.12
			radius_y *= 0.68
			radius_z *= 1.12
		case .Temperate_Hills, .Basalt_Spire_Highlands, .Wet_Lowland_Marsh, .Corrupted_Ash_Forest:
		}
		terrain_density_carve_cave_room_lobed_ellipsoid(
			view,
			key,
			chunk_origin,
			columns,
			branch_x,
			branch_y,
			branch_z,
			radius_x,
			radius_y,
			radius_z,
			TERRAIN_CAVE_PASSAGE_RIB_SALT ~ u64(crosscut_index + 1199),
			biome_id,
			true,
		)
	}
}

terrain_density_carve_cave_edge_seam_shoulders :: proc(
	view: ^world_async.ChunkVoxelView,
	key: biomes.FeatureGridKey,
	chunk_origin: world_async.BlockCoord,
	columns: []TerrainBiomeColumn,
	edge: biomes.CaveNetworkEdge,
	route_radius: f32,
	wall_buffer: ^TerrainCaveWallMaterialBuffer = nil,
) {
	if !edge.regional_seam_connection || edge.kind != .Canyon {
		return
	}
	for shoulder_index := u32(0);
	    shoulder_index < TERRAIN_CAVE_EDGE_SEAM_SHOULDER_COUNT;
	    shoulder_index += 1 {
		hash := biomes.feature_grid_hash_combine(u64(edge.id), TERRAIN_CAVE_FIELD_DETAIL_SALT)
		hash = biomes.feature_grid_hash_combine(hash, u64(shoulder_index + 601))
		step_t := (f32(shoulder_index) + 0.5) / f32(TERRAIN_CAVE_EDGE_SEAM_SHOULDER_COUNT)
		jitter := biomes.feature_grid_signed_unit_f32(hash, TERRAIN_CAVE_CURVE_SALT) * f32(0.045)
		center_t := math.clamp(
			biomes.regional_terrain_field_lerp(
				TERRAIN_CAVE_EDGE_SEAM_SHOULDER_ROUTE_MARGIN,
				1.0 - TERRAIN_CAVE_EDGE_SEAM_SHOULDER_ROUTE_MARGIN,
				step_t,
			) +
			jitter,
			TERRAIN_CAVE_EDGE_SEAM_SHOULDER_ROUTE_MARGIN,
			1.0 - TERRAIN_CAVE_EDGE_SEAM_SHOULDER_ROUTE_MARGIN,
		)
		half_span := TERRAIN_CAVE_EDGE_SEAM_SHOULDER_SPAN_T * f32(0.5)
		from_t := math.max(
			TERRAIN_CAVE_EDGE_SEAM_SHOULDER_ROUTE_MARGIN * f32(0.5),
			center_t - half_span,
		)
		to_t := math.min(
			1.0 - TERRAIN_CAVE_EDGE_SEAM_SHOULDER_ROUTE_MARGIN * f32(0.5),
			center_t + half_span,
		)
		if to_t <= from_t + 0.035 {
			continue
		}

		from_x, from_y, from_z := terrain_density_cave_edge_route_point(edge, from_t)
		route_x, route_y, route_z := terrain_density_cave_edge_route_point(edge, center_t)
		to_x, to_y, to_z := terrain_density_cave_edge_route_point(edge, to_t)
		tangent_x, _, tangent_z := terrain_density_delta_3(
			from_x,
			from_y,
			from_z,
			to_x,
			to_y,
			to_z,
		)
		horizontal_length := math.sqrt_f32(tangent_x * tangent_x + tangent_z * tangent_z)
		side_x := f32(1)
		side_z := f32(0)
		if horizontal_length > 0.001 {
			side_x = -tangent_z / horizontal_length
			side_z = tangent_x / horizontal_length
		}
		side_sign := f32(1)
		if (shoulder_index & 1) != 0 {
			side_sign = -1
		}
		if biomes.feature_grid_signed_unit_f32(hash, TERRAIN_CAVE_PASSAGE_RIB_SALT) < 0 {
			side_sign = -side_sign
		}
		side_x *= side_sign
		side_z *= side_sign

		vertical_sign := f32(1)
		if (shoulder_index & 2) != 0 {
			vertical_sign = -1
		}
		if biomes.feature_grid_signed_unit_f32(hash, TERRAIN_CAVE_BRANCH_SALT) < -0.25 {
			vertical_sign = -vertical_sign
		}
		side_offset :=
			route_radius *
			TERRAIN_CAVE_EDGE_SEAM_SHOULDER_SIDE_OFFSET_SCALE *
			biomes.regional_terrain_field_lerp(
				f32(0.72),
				f32(1.18),
				biomes.feature_grid_unit_f32(hash, TERRAIN_CAVE_FIELD_CHAMBER_SALT),
			)
		vertical_offset :=
			route_radius *
			TERRAIN_CAVE_EDGE_SEAM_SHOULDER_VERTICAL_OFFSET_SCALE *
			vertical_sign *
			biomes.regional_terrain_field_lerp(
				f32(0.48),
				f32(1.05),
				biomes.feature_grid_unit_f32(hash, TERRAIN_CAVE_DETAIL_SALT),
			)
		from_shoulder_x := from_x + side_x * side_offset
		from_shoulder_y := from_y + vertical_offset
		from_shoulder_z := from_z + side_z * side_offset
		center_x := route_x + side_x * side_offset
		center_y := route_y + vertical_offset
		center_z := route_z + side_z * side_offset
		to_shoulder_x := to_x + side_x * side_offset
		to_shoulder_y := to_y + vertical_offset
		to_shoulder_z := to_z + side_z * side_offset

		biome_id := edge.from_biome_id
		if center_t >= 0.5 {
			biome_id = edge.to_biome_id
		}
		shoulder_radius := math.clamp(
			route_radius *
			biomes.regional_terrain_field_lerp(
				f32(0.46),
				f32(0.70),
				biomes.feature_grid_unit_f32(hash, TERRAIN_CAVE_ROUGHNESS_SALT),
			),
			TERRAIN_CAVE_EDGE_SEAM_SHOULDER_RADIUS_MIN_BLOCKS,
			TERRAIN_CAVE_EDGE_SEAM_SHOULDER_RADIUS_MAX_BLOCKS,
		)
		shoulder_shape := terrain_density_cave_passage_shape(.Canyon)
		terrain_density_cave_passage_shape_apply_regional_seam(&shoulder_shape)
		terrain_density_cave_passage_shape_apply_biome(&shoulder_shape, biome_id)
		terrain_density_carve_rough_segment_shaped(
			view,
			key,
			chunk_origin,
			columns,
			from_shoulder_x,
			from_shoulder_y,
			from_shoulder_z,
			to_shoulder_x,
			to_shoulder_y,
			to_shoulder_z,
			shoulder_radius,
			shoulder_shape,
			TERRAIN_CAVE_FIELD_DETAIL_SALT ~ u64(shoulder_index + 641),
			biome_id,
			true,
		)
		throat_radius := math.max(
			f32(2.5),
			math.min(
				shoulder_radius * TERRAIN_CAVE_EDGE_SEAM_SHOULDER_THROAT_SCALE,
				route_radius * f32(0.34),
			),
		)
		terrain_density_carve_rough_segment_shaped(
			view,
			key,
			chunk_origin,
			columns,
			route_x,
			route_y,
			route_z,
			center_x,
			center_y,
			center_z,
			throat_radius,
			shoulder_shape,
			TERRAIN_CAVE_FIELD_DETAIL_SALT ~ u64(shoulder_index + 683),
			biome_id,
			true,
		)
		pocket_radius := shoulder_radius * TERRAIN_CAVE_EDGE_SEAM_SHOULDER_POCKET_RADIUS_SCALE
		radius_x := pocket_radius * f32(1.16)
		radius_y := pocket_radius * f32(0.70)
		radius_z := pocket_radius * f32(1.06)
		if vertical_sign > 0 {
			radius_y *= 1.18
		}
		#partial switch biome_id {
		case .Fungal_Vaults:
			radius_x *= 1.12
			radius_z *= 1.08
			radius_y *= 1.06
		case .Crystal_Geode_Network:
			radius_x *= 0.82
			radius_y *= 1.22
			radius_z *= 0.88
		case .Buried_Aquifer_Caves:
			radius_x *= 1.12
			radius_y *= 0.72
			radius_z *= 1.12
		}
		terrain_density_carve_cave_room_lobed_ellipsoid(
			view,
			key,
			chunk_origin,
			columns,
			center_x,
			center_y,
			center_z,
			radius_x,
			radius_y,
			radius_z,
			TERRAIN_CAVE_FIELD_DETAIL_SALT ~ u64(shoulder_index + 719),
			biome_id,
			true,
		)
	}
}

terrain_density_carve_cave_edge_seam_vertical_relief :: proc(
	view: ^world_async.ChunkVoxelView,
	key: biomes.FeatureGridKey,
	chunk_origin: world_async.BlockCoord,
	columns: []TerrainBiomeColumn,
	edge: biomes.CaveNetworkEdge,
	route_radius: f32,
	wall_buffer: ^TerrainCaveWallMaterialBuffer = nil,
) {
	if !edge.regional_seam_connection || edge.kind != .Canyon {
		return
	}
	for relief_index := u32(0);
	    relief_index < TERRAIN_CAVE_EDGE_SEAM_VERTICAL_RELIEF_COUNT;
	    relief_index += 1 {
		hash := biomes.feature_grid_hash_combine(u64(edge.id), TERRAIN_CAVE_BRANCH_SALT)
		hash = biomes.feature_grid_hash_combine(hash, u64(relief_index + 811))
		step_t := (f32(relief_index) + 0.5) / f32(TERRAIN_CAVE_EDGE_SEAM_VERTICAL_RELIEF_COUNT)
		jitter := biomes.feature_grid_signed_unit_f32(hash, TERRAIN_CAVE_CURVE_SALT) * f32(0.040)
		center_t := math.clamp(
			biomes.regional_terrain_field_lerp(
				TERRAIN_CAVE_EDGE_SEAM_VERTICAL_RELIEF_ROUTE_MARGIN,
				1.0 - TERRAIN_CAVE_EDGE_SEAM_VERTICAL_RELIEF_ROUTE_MARGIN,
				step_t,
			) +
			jitter,
			TERRAIN_CAVE_EDGE_SEAM_VERTICAL_RELIEF_ROUTE_MARGIN,
			1.0 - TERRAIN_CAVE_EDGE_SEAM_VERTICAL_RELIEF_ROUTE_MARGIN,
		)
		half_span := TERRAIN_CAVE_EDGE_SEAM_VERTICAL_RELIEF_SPAN_T * f32(0.5)
		from_t := math.max(
			TERRAIN_CAVE_EDGE_SEAM_VERTICAL_RELIEF_ROUTE_MARGIN * f32(0.5),
			center_t - half_span,
		)
		to_t := math.min(
			1.0 - TERRAIN_CAVE_EDGE_SEAM_VERTICAL_RELIEF_ROUTE_MARGIN * f32(0.5),
			center_t + half_span,
		)
		if to_t <= from_t + 0.030 {
			continue
		}

		from_x, from_y, from_z := terrain_density_cave_edge_route_point(edge, from_t)
		route_x, route_y, route_z := terrain_density_cave_edge_route_point(edge, center_t)
		to_x, to_y, to_z := terrain_density_cave_edge_route_point(edge, to_t)
		tangent_x, _, tangent_z := terrain_density_delta_3(
			from_x,
			from_y,
			from_z,
			to_x,
			to_y,
			to_z,
		)
		horizontal_length := math.sqrt_f32(tangent_x * tangent_x + tangent_z * tangent_z)
		side_x := f32(1)
		side_z := f32(0)
		if horizontal_length > 0.001 {
			side_x = -tangent_z / horizontal_length
			side_z = tangent_x / horizontal_length
		}

		biome_id := edge.from_biome_id
		if center_t >= 0.5 {
			biome_id = edge.to_biome_id
		}
		vertical_sign := f32(1)
		if (relief_index & 1) != 0 {
			vertical_sign = -1
		}
		if biomes.feature_grid_signed_unit_f32(hash, TERRAIN_CAVE_DETAIL_SALT) < -0.20 {
			vertical_sign = -vertical_sign
		}
		vertical_offset :=
			route_radius *
			TERRAIN_CAVE_EDGE_SEAM_VERTICAL_RELIEF_OFFSET_SCALE *
			vertical_sign *
			biomes.regional_terrain_field_lerp(
				f32(0.90),
				f32(1.28),
				biomes.feature_grid_unit_f32(hash, TERRAIN_CAVE_FIELD_CHAMBER_SALT),
			)
		#partial switch biome_id {
		case .Fungal_Vaults:
			vertical_offset *= 0.94
		case .Crystal_Geode_Network:
			if vertical_sign > 0 {
				vertical_offset *= 1.12
			}
		case .Buried_Aquifer_Caves:
			if vertical_sign > 0 {
				vertical_offset *= 0.82
			}
		case .Temperate_Hills, .Basalt_Spire_Highlands, .Wet_Lowland_Marsh, .Corrupted_Ash_Forest:
		}
		side_drift :=
			route_radius *
			TERRAIN_CAVE_EDGE_SEAM_VERTICAL_RELIEF_SIDE_DRIFT_SCALE *
			biomes.feature_grid_signed_unit_f32(hash, TERRAIN_CAVE_PASSAGE_RIB_SALT) *
			biomes.regional_terrain_field_lerp(
				f32(0.35),
				f32(1.0),
				biomes.feature_grid_unit_f32(hash, TERRAIN_CAVE_ROUGHNESS_SALT),
			)
		from_relief_x := from_x + side_x * side_drift * f32(0.50)
		from_relief_y := from_y + vertical_offset * f32(0.62)
		from_relief_z := from_z + side_z * side_drift * f32(0.50)
		center_x := route_x + side_x * side_drift
		center_y := route_y + vertical_offset
		center_z := route_z + side_z * side_drift
		to_relief_x := to_x + side_x * side_drift * f32(0.50)
		to_relief_y := to_y + vertical_offset * f32(0.62)
		to_relief_z := to_z + side_z * side_drift * f32(0.50)

		relief_radius := math.clamp(
			route_radius *
			biomes.regional_terrain_field_lerp(
				f32(0.52),
				f32(0.82),
				biomes.feature_grid_unit_f32(hash, TERRAIN_CAVE_ROUGHNESS_SALT),
			),
			TERRAIN_CAVE_EDGE_SEAM_VERTICAL_RELIEF_RADIUS_MIN_BLOCKS,
			TERRAIN_CAVE_EDGE_SEAM_VERTICAL_RELIEF_RADIUS_MAX_BLOCKS,
		)
		relief_shape := terrain_density_cave_passage_shape(.Canyon)
		terrain_density_cave_passage_shape_apply_regional_seam(&relief_shape)
		terrain_density_cave_passage_shape_apply_biome(&relief_shape, biome_id)
		if vertical_sign > 0 {
			relief_shape.radius_y_scale = math.max(relief_shape.radius_y_scale, f32(1.24))
			relief_shape.radius_x_scale *= 0.92
			relief_shape.radius_z_scale *= 0.92
		} else {
			relief_shape.radius_y_scale = math.min(relief_shape.radius_y_scale, f32(0.78))
			relief_shape.radius_x_scale = math.max(relief_shape.radius_x_scale, f32(1.24))
			relief_shape.radius_z_scale = math.max(relief_shape.radius_z_scale, f32(1.18))
		}
		rib_radius := math.max(
			f32(2.5),
			relief_radius * TERRAIN_CAVE_EDGE_SEAM_VERTICAL_RELIEF_RIB_RADIUS_SCALE,
		)
		terrain_density_carve_rough_segment_shaped(
			view,
			key,
			chunk_origin,
			columns,
			from_relief_x,
			from_relief_y,
			from_relief_z,
			to_relief_x,
			to_relief_y,
			to_relief_z,
			rib_radius,
			relief_shape,
			TERRAIN_CAVE_BRANCH_SALT ~ u64(relief_index + 853),
			biome_id,
			true,
		)
		throat_radius := math.max(
			f32(2.2),
			math.min(
				relief_radius * TERRAIN_CAVE_EDGE_SEAM_VERTICAL_RELIEF_THROAT_SCALE,
				route_radius * f32(0.42),
			),
		)
		terrain_density_carve_rough_segment_shaped(
			view,
			key,
			chunk_origin,
			columns,
			route_x,
			route_y,
			route_z,
			center_x,
			center_y,
			center_z,
			throat_radius,
			relief_shape,
			TERRAIN_CAVE_BRANCH_SALT ~ u64(relief_index + 887),
			biome_id,
			true,
		)

		pocket_radius := relief_radius * TERRAIN_CAVE_EDGE_SEAM_VERTICAL_RELIEF_POCKET_RADIUS_SCALE
		radius_x := pocket_radius * f32(0.90)
		radius_y := pocket_radius * f32(1.18)
		radius_z := pocket_radius * f32(0.86)
		if vertical_sign < 0 {
			radius_x = pocket_radius * f32(1.22)
			radius_y = pocket_radius * f32(0.54)
			radius_z = pocket_radius * f32(1.08)
		}
		#partial switch biome_id {
		case .Fungal_Vaults:
			radius_x *= 1.10
			radius_z *= 1.06
			radius_y *= 0.96
		case .Crystal_Geode_Network:
			if vertical_sign > 0 {
				radius_y *= 1.22
				radius_x *= 0.76
				radius_z *= 0.82
			}
		case .Buried_Aquifer_Caves:
			if vertical_sign < 0 {
				radius_x *= 1.18
				radius_z *= 1.12
				radius_y *= 0.78
			} else {
				radius_y *= 0.72
			}
		case .Temperate_Hills, .Basalt_Spire_Highlands, .Wet_Lowland_Marsh, .Corrupted_Ash_Forest:
		}
		terrain_density_carve_cave_room_lobed_ellipsoid(
			view,
			key,
			chunk_origin,
			columns,
			center_x,
			center_y,
			center_z,
			radius_x,
			radius_y,
			radius_z,
			TERRAIN_CAVE_BRANCH_SALT ~ u64(relief_index + 919),
			biome_id,
			true,
		)
	}
}

terrain_density_carve_cave_edge_seam_galleries :: proc(
	view: ^world_async.ChunkVoxelView,
	key: biomes.FeatureGridKey,
	chunk_origin: world_async.BlockCoord,
	columns: []TerrainBiomeColumn,
	edge: biomes.CaveNetworkEdge,
	route_radius: f32,
	wall_buffer: ^TerrainCaveWallMaterialBuffer = nil,
) {
	if !edge.regional_seam_connection || edge.kind != .Canyon {
		return
	}
	for gallery_index := u32(0);
	    gallery_index < TERRAIN_CAVE_EDGE_SEAM_GALLERY_COUNT;
	    gallery_index += 1 {
		hash := biomes.feature_grid_hash_combine(u64(edge.id), TERRAIN_CAVE_FIELD_CHAMBER_SALT)
		hash = biomes.feature_grid_hash_combine(hash, u64(gallery_index))
		step_t := (f32(gallery_index) + 0.5) / f32(TERRAIN_CAVE_EDGE_SEAM_GALLERY_COUNT)
		jitter := biomes.feature_grid_signed_unit_f32(hash, TERRAIN_CAVE_CURVE_SALT) * f32(0.075)
		t := math.clamp(
			biomes.regional_terrain_field_lerp(
				TERRAIN_CAVE_EDGE_SEAM_GALLERY_ROUTE_MARGIN,
				1.0 - TERRAIN_CAVE_EDGE_SEAM_GALLERY_ROUTE_MARGIN,
				step_t,
			) +
			jitter,
			TERRAIN_CAVE_EDGE_SEAM_GALLERY_ROUTE_MARGIN,
			1.0 - TERRAIN_CAVE_EDGE_SEAM_GALLERY_ROUTE_MARGIN,
		)
		route_x, route_y, route_z := terrain_density_cave_edge_route_point(edge, t)
		prev_x, prev_y, prev_z := terrain_density_cave_edge_route_point(
			edge,
			math.max(f32(0), t - 0.07),
		)
		next_x, next_y, next_z := terrain_density_cave_edge_route_point(
			edge,
			math.min(f32(1), t + 0.07),
		)
		tangent_x, _, tangent_z := terrain_density_delta_3(
			prev_x,
			prev_y,
			prev_z,
			next_x,
			next_y,
			next_z,
		)
		horizontal_length := math.sqrt_f32(tangent_x * tangent_x + tangent_z * tangent_z)
		side_x := f32(1)
		side_z := f32(0)
		if horizontal_length > 0.001 {
			side_x = -tangent_z / horizontal_length
			side_z = tangent_x / horizontal_length
		}
		side_sign := f32(1)
		if (gallery_index & 1) != 0 {
			side_sign = -1
		}
		if biomes.feature_grid_signed_unit_f32(hash, TERRAIN_CAVE_PASSAGE_RIB_SALT) < 0 {
			side_sign = -side_sign
		}
		side_x *= side_sign
		side_z *= side_sign

		vertical_sign := f32(1)
		if (gallery_index & 1) != 0 {
			vertical_sign = -1
		}
		if biomes.feature_grid_signed_unit_f32(hash, TERRAIN_CAVE_BRANCH_SALT) < -0.35 {
			vertical_sign = -vertical_sign
		}
		side_offset :=
			route_radius *
			TERRAIN_CAVE_EDGE_SEAM_GALLERY_SIDE_OFFSET_SCALE *
			biomes.regional_terrain_field_lerp(
				f32(0.72),
				f32(1.18),
				biomes.feature_grid_unit_f32(hash, TERRAIN_CAVE_FIELD_DETAIL_SALT),
			)
		vertical_offset :=
			route_radius *
			TERRAIN_CAVE_EDGE_SEAM_GALLERY_VERTICAL_OFFSET_SCALE *
			vertical_sign *
			biomes.regional_terrain_field_lerp(
				f32(0.62),
				f32(1.12),
				biomes.feature_grid_unit_f32(hash, TERRAIN_CAVE_DETAIL_SALT),
			)
		center_x := route_x + side_x * side_offset
		center_y := route_y + vertical_offset
		center_z := route_z + side_z * side_offset

		biome_id := edge.from_biome_id
		if t >= 0.5 {
			biome_id = edge.to_biome_id
		}
		radius_base := math.clamp(
			route_radius *
			biomes.regional_terrain_field_lerp(
				f32(0.42),
				f32(0.66),
				biomes.feature_grid_unit_f32(hash, TERRAIN_CAVE_ROUGHNESS_SALT),
			),
			TERRAIN_CAVE_EDGE_SEAM_GALLERY_RADIUS_MIN_BLOCKS,
			TERRAIN_CAVE_EDGE_SEAM_GALLERY_RADIUS_MAX_BLOCKS,
		)
		radius_x := radius_base * 1.18
		radius_y := radius_base * 0.74
		radius_z := radius_base * 1.04
		if vertical_sign > 0 {
			radius_y *= 1.18
		} else {
			radius_y *= 0.82
			radius_x *= 1.08
			radius_z *= 1.08
		}
		#partial switch biome_id {
		case .Fungal_Vaults:
			radius_x *= 1.16
			radius_z *= 1.08
			radius_y *= 1.10
		case .Crystal_Geode_Network:
			radius_x *= 0.78
			radius_y *= 1.22
			radius_z *= 0.90
		case .Buried_Aquifer_Caves:
			radius_x *= 1.12
			radius_y *= 0.74
			radius_z *= 1.12
		}

		throat_shape := terrain_density_cave_passage_shape(.Canyon)
		terrain_density_cave_passage_shape_apply_regional_seam(&throat_shape)
		terrain_density_cave_passage_shape_apply_biome(&throat_shape, biome_id)
		throat_radius := math.max(
			f32(2.25),
			math.min(
				radius_base * f32(0.42),
				route_radius * TERRAIN_CAVE_EDGE_SEAM_GALLERY_THROAT_SCALE,
			),
		)
		terrain_density_carve_rough_segment_shaped(
			view,
			key,
			chunk_origin,
			columns,
			route_x,
			route_y,
			route_z,
			center_x,
			center_y,
			center_z,
			throat_radius,
			throat_shape,
			TERRAIN_CAVE_FIELD_CHAMBER_SALT ~ u64(gallery_index + 301),
			biome_id,
			true,
		)
		terrain_density_carve_cave_room_lobed_ellipsoid(
			view,
			key,
			chunk_origin,
			columns,
			center_x,
			center_y,
			center_z,
			radius_x,
			radius_y,
			radius_z,
			TERRAIN_CAVE_FIELD_CHAMBER_SALT ~ u64(gallery_index + 347),
			biome_id,
			true,
		)
	}
}

terrain_density_carve_cave_edge_chamberlet_biome_detail :: proc(
	view: ^world_async.ChunkVoxelView,
	key: biomes.FeatureGridKey,
	chunk_origin: world_async.BlockCoord,
	columns: []TerrainBiomeColumn,
	route_x, route_y, route_z: f32,
	center_x, center_y, center_z: f32,
	side_x, side_z: f32,
	radius_base, route_radius: f32,
	biome_id: biomes.BiomeID,
	hash: u64,
	chamberlet_index: u32,
) {
	previous_detail_found := false
	previous_detail_center_x := f32(0)
	previous_detail_center_y := f32(0)
	previous_detail_center_z := f32(0)
	previous_detail_radius := f32(0)
	for detail_index := u32(0);
	    detail_index < TERRAIN_CAVE_EDGE_CHAMBERLET_DETAIL_COUNT;
	    detail_index += 1 {
		detail_hash := biomes.feature_grid_hash_combine(hash, u64(detail_index + 113))
		forward_x := side_z
		forward_z := -side_x
		forward_sign := f32(1)
		if (detail_index & 1) != 0 {
			forward_sign = -1
		}
		if biomes.feature_grid_signed_unit_f32(detail_hash, TERRAIN_CAVE_CURVE_SALT) < 0 {
			forward_sign = -forward_sign
		}
		dir_x :=
			side_x *
				biomes.regional_terrain_field_lerp(
					f32(0.62),
					f32(0.92),
					biomes.feature_grid_unit_f32(detail_hash, TERRAIN_CAVE_FIELD_DETAIL_SALT),
				) +
			forward_x * forward_sign * f32(0.38)
		dir_z :=
			side_z *
				biomes.regional_terrain_field_lerp(
					f32(0.62),
					f32(0.92),
					biomes.feature_grid_unit_f32(detail_hash, TERRAIN_CAVE_FIELD_DETAIL_SALT),
				) +
			forward_z * forward_sign * f32(0.38)
		dir_len := math.sqrt_f32(dir_x * dir_x + dir_z * dir_z)
		if dir_len <= 0.001 {
			dir_x, dir_z = side_x, side_z
		} else {
			dir_x /= dir_len
			dir_z /= dir_len
		}

		detail_radius := math.clamp(
			radius_base *
			biomes.regional_terrain_field_lerp(
				f32(0.26),
				f32(0.48),
				biomes.feature_grid_unit_f32(detail_hash, TERRAIN_CAVE_ROUGHNESS_SALT),
			),
			TERRAIN_CAVE_EDGE_CHAMBERLET_DETAIL_RADIUS_MIN_BLOCKS,
			TERRAIN_CAVE_EDGE_CHAMBERLET_DETAIL_RADIUS_MAX_BLOCKS,
		)
		offset :=
			route_radius *
			TERRAIN_CAVE_EDGE_CHAMBERLET_DETAIL_OFFSET_SCALE *
			biomes.regional_terrain_field_lerp(
				f32(0.68),
				f32(1.10),
				biomes.feature_grid_unit_f32(detail_hash, TERRAIN_CAVE_PASSAGE_RIB_SALT),
			)
		detail_center_x := center_x + dir_x * offset
		detail_center_y :=
			center_y +
			biomes.feature_grid_signed_unit_f32(detail_hash, TERRAIN_CAVE_BRANCH_SALT) *
				radius_base *
				f32(0.22)
		detail_center_z := center_z + dir_z * offset
		throat_radius := math.max(
			f32(1.35),
			math.min(
				detail_radius * f32(0.52),
				route_radius * TERRAIN_CAVE_EDGE_CHAMBERLET_DETAIL_THROAT_SCALE,
			),
		)

		shape := terrain_density_cave_passage_shape(.Collapsed_Corridor)
		#partial switch biome_id {
		case .Fungal_Vaults:
			shape = terrain_density_cave_passage_shape(.Worm_Path)
			shape.radius_y_scale = math.min(shape.radius_y_scale, f32(0.72))
		case .Crystal_Geode_Network:
			shape = terrain_density_cave_passage_shape(.Fracture)
		case .Buried_Aquifer_Caves:
			shape = terrain_density_cave_passage_shape(.Flooded_Passage)
			shape.radius_y_scale = math.min(shape.radius_y_scale, f32(0.46))
		}
		terrain_density_cave_passage_shape_apply_biome(&shape, biome_id)
		terrain_density_carve_rough_segment_shaped(
			view,
			key,
			chunk_origin,
			columns,
			center_x,
			center_y,
			center_z,
			detail_center_x,
			detail_center_y,
			detail_center_z,
			throat_radius,
			shape,
			TERRAIN_CAVE_ROOM_DETAIL_SALT ~ u64(chamberlet_index * 17 + detail_index + 101),
			biome_id,
			true,
		)
		if previous_detail_found {
			loop_radius := math.max(
				f32(1.20),
				math.min(
					math.min(previous_detail_radius, detail_radius) *
					TERRAIN_CAVE_EDGE_CHAMBERLET_DETAIL_LOOP_RADIUS_SCALE,
					route_radius * TERRAIN_CAVE_EDGE_CHAMBERLET_DETAIL_LOOP_ROUTE_CAP_SCALE,
				),
			)
			terrain_density_carve_rough_segment_shaped(
				view,
				key,
				chunk_origin,
				columns,
				previous_detail_center_x,
				previous_detail_center_y,
				previous_detail_center_z,
				detail_center_x,
				detail_center_y,
				detail_center_z,
				loop_radius,
				shape,
				TERRAIN_CAVE_ROOM_DETAIL_SALT ~ u64(chamberlet_index * 41 + detail_index + 251),
				biome_id,
				true,
			)
			loop_pocket_radius :=
				loop_radius * TERRAIN_CAVE_EDGE_CHAMBERLET_DETAIL_LOOP_POCKET_RADIUS_SCALE
			loop_pocket_x := (previous_detail_center_x + detail_center_x) * f32(0.5)
			loop_pocket_y := (previous_detail_center_y + detail_center_y) * f32(0.5)
			loop_pocket_z := (previous_detail_center_z + detail_center_z) * f32(0.5)
			loop_radius_x := loop_pocket_radius * f32(1.12)
			loop_radius_y := loop_pocket_radius * f32(0.68)
			loop_radius_z := loop_pocket_radius
			#partial switch biome_id {
			case .Fungal_Vaults:
				loop_radius_x *= 1.14
				loop_radius_y *= 0.92
				loop_radius_z *= 1.08
			case .Crystal_Geode_Network:
				loop_radius_x *= 0.72
				loop_radius_y *= 1.28
				loop_radius_z *= 0.82
			case .Buried_Aquifer_Caves:
				loop_radius_x *= 1.18
				loop_radius_y *= 0.50
				loop_radius_z *= 1.12
			}
			terrain_density_carve_cave_room_lobed_ellipsoid(
				view,
				key,
				chunk_origin,
				columns,
				loop_pocket_x,
				loop_pocket_y,
				loop_pocket_z,
				loop_radius_x,
				loop_radius_y,
				loop_radius_z,
				TERRAIN_CAVE_ROOM_DETAIL_SALT ~ u64(chamberlet_index * 43 + detail_index + 283),
				biome_id,
				true,
			)
		}

		#partial switch biome_id {
		case .Fungal_Vaults:
			terrain_density_carve_cave_room_lobed_ellipsoid(
				view,
				key,
				chunk_origin,
				columns,
				detail_center_x,
				detail_center_y + detail_radius * f32(0.18),
				detail_center_z,
				detail_radius * f32(0.86),
				detail_radius * f32(1.18),
				detail_radius * f32(0.74),
				TERRAIN_CAVE_ROOM_DETAIL_SALT ~ u64(chamberlet_index * 19 + detail_index + 149),
				biome_id,
				true,
			)
			tendril_radius := math.max(f32(1.2), detail_radius * f32(0.22))
			terrain_density_carve_rough_segment_shaped(
				view,
				key,
				chunk_origin,
				columns,
				detail_center_x,
				detail_center_y - detail_radius * f32(0.84),
				detail_center_z,
				detail_center_x + dir_x * detail_radius * f32(0.32),
				detail_center_y + detail_radius * f32(1.04),
				detail_center_z + dir_z * detail_radius * f32(0.32),
				tendril_radius,
				shape,
				TERRAIN_CAVE_BRANCH_SALT ~ u64(chamberlet_index * 23 + detail_index + 173),
				biome_id,
				true,
			)
		case .Crystal_Geode_Network:
			terrain_density_carve_rough_segment_shaped(
				view,
				key,
				chunk_origin,
				columns,
				detail_center_x - dir_x * detail_radius * f32(0.72),
				detail_center_y - detail_radius * f32(1.12),
				detail_center_z - dir_z * detail_radius * f32(0.72),
				detail_center_x + dir_x * detail_radius * f32(0.82),
				detail_center_y + detail_radius * f32(1.18),
				detail_center_z + dir_z * detail_radius * f32(0.82),
				math.max(f32(1.35), detail_radius * f32(0.30)),
				shape,
				TERRAIN_CAVE_PASSAGE_RIB_SALT ~ u64(chamberlet_index * 29 + detail_index + 197),
				biome_id,
				true,
			)
			terrain_density_carve_cave_room_lobed_ellipsoid(
				view,
				key,
				chunk_origin,
				columns,
				detail_center_x,
				detail_center_y + detail_radius * f32(0.26),
				detail_center_z,
				detail_radius * f32(0.48),
				detail_radius * f32(0.94),
				detail_radius * f32(0.56),
				TERRAIN_CAVE_ROOM_DETAIL_SALT ~ u64(chamberlet_index * 31 + detail_index + 211),
				biome_id,
				true,
			)
		case .Buried_Aquifer_Caves:
			terrain_density_carve_cave_room_lobed_ellipsoid(
				view,
				key,
				chunk_origin,
				columns,
				detail_center_x,
				detail_center_y - detail_radius * f32(0.18),
				detail_center_z,
				detail_radius * f32(1.18),
				detail_radius * f32(0.34),
				detail_radius * f32(0.96),
				TERRAIN_CAVE_ROOM_DETAIL_SALT ~ u64(chamberlet_index * 37 + detail_index + 229),
				biome_id,
				true,
			)
			terrain_density_fill_water_ellipsoid(
				view,
				chunk_origin,
				detail_center_x,
				detail_center_y - detail_radius * f32(0.40),
				detail_center_z,
				detail_radius * f32(0.86),
				math.max(f32(1.0), detail_radius * f32(0.14)),
				detail_radius * f32(0.76),
			)
		}
		previous_detail_found = true
		previous_detail_center_x = detail_center_x
		previous_detail_center_y = detail_center_y
		previous_detail_center_z = detail_center_z
		previous_detail_radius = detail_radius
	}
}

terrain_density_cave_edge_route_point :: proc(
	edge: biomes.CaveNetworkEdge,
	t: f32,
) -> (
	x, y, z: f32,
) {
	route_t := math.clamp(t, f32(0), f32(1))
	ab_x := biomes.regional_terrain_field_lerp(edge.from_x, edge.bend_x, route_t)
	ab_y := biomes.regional_terrain_field_lerp(edge.from_y, edge.bend_y, route_t)
	ab_z := biomes.regional_terrain_field_lerp(edge.from_z, edge.bend_z, route_t)
	bc_x := biomes.regional_terrain_field_lerp(edge.bend_x, edge.to_x, route_t)
	bc_y := biomes.regional_terrain_field_lerp(edge.bend_y, edge.to_y, route_t)
	bc_z := biomes.regional_terrain_field_lerp(edge.bend_z, edge.to_z, route_t)
	x = biomes.regional_terrain_field_lerp(ab_x, bc_x, route_t)
	y = biomes.regional_terrain_field_lerp(ab_y, bc_y, route_t)
	z = biomes.regional_terrain_field_lerp(ab_z, bc_z, route_t)

	center_support := route_t * (1.0 - route_t) * 4.0
	if center_support <= 0 {
		return
	}

	dx := edge.to_x - edge.from_x
	dy := edge.to_y - edge.from_y
	dz := edge.to_z - edge.from_z
	length_xz := math.sqrt_f32(dx * dx + dz * dz)
	side_x := f32(1)
	side_y := f32(0)
	side_z := f32(0)
	if length_xz > 0.001 {
		side_x = -dz / length_xz
		side_z = dx / length_xz
	}
	length := math.sqrt_f32(dx * dx + dy * dy + dz * dz)
	tangent_x := f32(0)
	tangent_y := f32(1)
	tangent_z := f32(0)
	if length > 0.001 {
		tangent_x = dx / length
		tangent_y = dy / length
		tangent_z = dz / length
	}
	up_x := side_y * tangent_z - side_z * tangent_y
	up_y := side_z * tangent_x - side_x * tangent_z
	up_z := side_x * tangent_y - side_y * tangent_x

	hash := biomes.feature_grid_hash_combine(u64(edge.id), TERRAIN_CAVE_CURVE_SALT)
	side_bias := biomes.feature_grid_signed_unit_f32(hash, TERRAIN_CAVE_BRANCH_SALT)
	lift_bias := biomes.feature_grid_signed_unit_f32(hash, TERRAIN_CAVE_PASSAGE_RIB_SALT)
	phase := biomes.feature_grid_unit_f32(hash, TERRAIN_CAVE_FIELD_DETAIL_SALT)
	side_wave := terrain_density_cave_segment_triangle_wave(route_t * 2.0 + phase) * 2.0 - 1.0
	lift_wave :=
		terrain_density_cave_segment_triangle_wave(route_t * 1.35 + phase * 0.5) * 2.0 - 1.0
	side_offset :=
		(side_wave + side_bias * 0.35) *
		center_support *
		edge.radius_blocks *
		TERRAIN_CAVE_EDGE_ROUTE_SIDE_WARP_SCALE
	lift_offset :=
		(lift_wave + lift_bias * 0.28) *
		center_support *
		edge.radius_blocks *
		TERRAIN_CAVE_EDGE_ROUTE_LIFT_WARP_SCALE
	x += side_x * side_offset + up_x * lift_offset
	y += side_y * side_offset + up_y * lift_offset
	z += side_z * side_offset + up_z * lift_offset
	return
}

terrain_density_cave_passage_segment_setup :: proc(
	kind: biomes.CaveNetworkEdgeKind,
) -> (
	radius_scale: f32,
	salt: u64,
) {
	radius_scale = 1
	salt = TERRAIN_CAVE_ROUGHNESS_SALT
	#partial switch kind {
	case .Canyon:
		radius_scale = 1.10
		salt = TERRAIN_CAVE_ROOM_DETAIL_SALT
	case .Fracture:
		radius_scale = 0.68
		salt = TERRAIN_CAVE_PASSAGE_RIB_SALT
	case .Flooded_Passage:
		radius_scale = 1.06
		salt = TERRAIN_CAVE_FIELD_DETAIL_SALT
	case .Vertical_Shaft:
		radius_scale = 0.86
	case .Collapsed_Corridor:
		radius_scale = 0.72
		salt = TERRAIN_CAVE_PASSAGE_RIB_SALT
	case .Worm_Path:
		radius_scale = 0.90
		salt = TERRAIN_CAVE_BRANCH_SALT
	}
	return
}

terrain_density_cave_passage_shape :: proc(
	kind: biomes.CaveNetworkEdgeKind,
) -> TerrainCaveSegmentShape {
	shape := terrain_density_cave_segment_shape_default()
	#partial switch kind {
	case .Canyon:
		shape.radius_x_scale = 1.12
		shape.radius_y_scale = 1.10
		shape.radius_z_scale = 1.06
		shape.radius_noise_scale = 0.20
		shape.radius_neck_scale = 0.10
		shape.radius_swell_scale = 0.28
		shape.radius_endpoint_scale = 0.08
		shape.meander_scale = 0.82
		shape.lift_scale = 0.42
		shape.curve_scale = 0.18
		shape.wall_scallop_scale = 0.12
		shape.wall_notch_scale = 0.18
		shape.wall_rib_scale = 0.10
	case .Flooded_Passage:
		shape.radius_x_scale = 1.12
		shape.radius_y_scale = 0.58
		shape.radius_z_scale = 1.10
		shape.radius_noise_scale = 0.12
		shape.radius_neck_scale = 0.08
		shape.radius_swell_scale = 0.18
		shape.radius_endpoint_scale = 0.05
		shape.meander_scale = 0.62
		shape.lift_scale = 0.18
		shape.curve_scale = 0.14
		shape.wall_scallop_scale = 0.06
		shape.wall_notch_scale = 0.12
		shape.wall_rib_scale = 0.07
	case .Fracture:
		shape.radius_x_scale = 0.68
		shape.radius_y_scale = 1.12
		shape.radius_z_scale = 0.82
		shape.radius_noise_scale = 0.24
		shape.radius_neck_scale = 0.26
		shape.radius_swell_scale = 0.14
		shape.radius_endpoint_scale = 0.08
		shape.meander_scale = 0.96
		shape.lift_scale = 0.52
		shape.curve_scale = 0.30
		shape.wall_scallop_scale = 0.12
		shape.wall_notch_scale = 0.08
		shape.wall_rib_scale = 0.28
	case .Vertical_Shaft:
		shape.radius_x_scale = 0.70
		shape.radius_y_scale = 1.12
		shape.radius_z_scale = 0.70
		shape.radius_noise_scale = 0.12
		shape.radius_neck_scale = 0.12
		shape.radius_swell_scale = 0.12
		shape.radius_endpoint_scale = 0.05
		shape.meander_scale = 0.34
		shape.lift_scale = 0.64
		shape.curve_scale = 0.10
		shape.wall_scallop_scale = 0.08
		shape.wall_notch_scale = 0.07
		shape.wall_rib_scale = 0.18
	case .Collapsed_Corridor:
		shape.radius_x_scale = 0.82
		shape.radius_y_scale = 0.58
		shape.radius_z_scale = 1.00
		shape.radius_noise_scale = 0.26
		shape.radius_neck_scale = 0.30
		shape.radius_swell_scale = 0.10
		shape.radius_endpoint_scale = 0.06
		shape.meander_scale = 0.70
		shape.lift_scale = 0.22
		shape.curve_scale = 0.22
		shape.wall_scallop_scale = 0.16
		shape.wall_notch_scale = 0.14
		shape.wall_rib_scale = 0.24
	case .Worm_Path:
		shape.radius_x_scale = 0.82
		shape.radius_y_scale = 0.78
		shape.radius_z_scale = 1.18
		shape.radius_noise_scale = 0.30
		shape.radius_neck_scale = 0.18
		shape.radius_swell_scale = 0.24
		shape.radius_endpoint_scale = 0.07
		shape.meander_scale = 1.08
		shape.lift_scale = 0.50
		shape.curve_scale = 0.42
		shape.wall_scallop_scale = 0.24
		shape.wall_notch_scale = 0.20
		shape.wall_rib_scale = 0.14
	case .Tunnel:
		shape.radius_y_scale = 0.78
		shape.radius_noise_scale = 0.24
		shape.radius_neck_scale = 0.22
		shape.radius_swell_scale = 0.18
		shape.radius_endpoint_scale = 0.06
		shape.meander_scale = 0.88
		shape.lift_scale = 0.42
		shape.curve_scale = 0.24
		shape.wall_scallop_scale = 0.14
		shape.wall_notch_scale = 0.11
		shape.wall_rib_scale = 0.12
	}
	return shape
}

terrain_density_cave_passage_shape_apply_biome :: proc(
	shape: ^TerrainCaveSegmentShape,
	biome_id: biomes.BiomeID,
) {
	#partial switch biome_id {
	case .Fungal_Vaults:
		shape.wall_scallop_scale *= 1.28
		shape.wall_notch_scale *= 1.20
		shape.wall_rib_scale *= 0.82
	case .Crystal_Geode_Network:
		shape.wall_scallop_scale *= 0.82
		shape.wall_notch_scale *= 0.72
		shape.wall_rib_scale *= 1.45
	case .Buried_Aquifer_Caves:
		shape.wall_scallop_scale *= 0.72
		shape.wall_notch_scale *= 1.05
		shape.wall_rib_scale *= 0.72
	}
}

terrain_density_carve_cave_entrance :: proc(
	view: ^world_async.ChunkVoxelView,
	key: biomes.FeatureGridKey,
	chunk_origin: world_async.BlockCoord,
	columns: []TerrainBiomeColumn,
	anchor: biomes.CaveAnchor,
	node: biomes.CaveNetworkNode,
	link_radius: f32,
	wall_buffer: ^TerrainCaveWallMaterialBuffer = nil,
) {
	opening_radius := math.max(f32(4), anchor.influence_radius_blocks)
	opening_y := opening_radius * 0.45
	if anchor.kind == .Sinkhole || anchor.kind == .Vertical_Shaft {
		opening_y = opening_radius * 1.30
	}

	if anchor.kind == .Cave_Mouth || anchor.kind == .Ravine_Breach {
		terrain_density_carve_cave_mouth(
			view,
			key,
			chunk_origin,
			columns,
			anchor,
			node,
			opening_radius,
			wall_buffer,
		)
		terrain_density_carve_cave_mouth_transition(
			view,
			key,
			chunk_origin,
			columns,
			anchor,
			node,
			opening_radius,
			link_radius,
			wall_buffer,
		)
		return
	} else if anchor.kind == .Sinkhole || anchor.kind == .Vertical_Shaft {
		terrain_density_carve_sinkhole_throat(
			view,
			key,
			chunk_origin,
			columns,
			anchor,
			node,
			opening_radius,
			link_radius,
			wall_buffer,
		)
	} else {
		terrain_density_carve_rough_ellipsoid(
			view,
			key,
			chunk_origin,
			columns,
			anchor.x,
			anchor.y - opening_y * 0.25,
			anchor.z,
			opening_radius * 1.20,
			opening_y,
			opening_radius,
			TERRAIN_CAVE_DETAIL_SALT,
			node.biome_id,
			false,
			wall_buffer,
		)
	}

	mid_x := (anchor.x + node.x) * 0.5
	mid_y := (anchor.y + node.y) * 0.5
	mid_z := (anchor.z + node.z) * 0.5
	terrain_density_carve_rough_segment_shaped(
		view,
		key,
		chunk_origin,
		columns,
		anchor.x,
		anchor.y,
		anchor.z,
		mid_x,
		mid_y,
		mid_z,
		math.max(opening_radius * 0.42, link_radius),
		terrain_density_cave_entrance_link_shape(anchor.kind, true),
		TERRAIN_CAVE_DETAIL_SALT,
		node.biome_id,
		false,
		wall_buffer,
	)
	terrain_density_carve_rough_segment_shaped(
		view,
		key,
		chunk_origin,
		columns,
		mid_x,
		mid_y,
		mid_z,
		node.x,
		node.y,
		node.z,
		link_radius,
		terrain_density_cave_entrance_link_shape(anchor.kind, false),
		TERRAIN_CAVE_ROUGHNESS_SALT,
		node.biome_id,
		false,
		wall_buffer,
	)
}

terrain_density_cave_entrance_link_shape :: proc(
	kind: biomes.CaveAnchorKind,
	near_surface: bool,
) -> TerrainCaveSegmentShape {
	shape := terrain_density_cave_passage_shape(.Tunnel)
	#partial switch kind {
	case .Cave_Mouth, .Ravine_Breach:
		if near_surface {
			shape = terrain_density_cave_passage_shape(.Collapsed_Corridor)
			shape.radius_y_scale = 0.54
			shape.radius_neck_scale = 0.34
			shape.curve_scale = 0.26
		} else {
			shape.radius_y_scale = 0.70
			shape.radius_neck_scale = 0.26
			shape.curve_scale = 0.30
		}
	case .Sinkhole, .Vertical_Shaft:
		if near_surface {
			shape = terrain_density_cave_passage_shape(.Vertical_Shaft)
			shape.radius_x_scale = 0.64
			shape.radius_z_scale = 0.64
			shape.radius_neck_scale = 0.18
			shape.curve_scale = 0.14
		} else {
			shape = terrain_density_cave_passage_shape(.Fracture)
			shape.radius_x_scale = 0.72
			shape.radius_z_scale = 0.78
			shape.curve_scale = 0.24
		}
	case .Lakebed_Breach, .Seabed_Breach, .Underground_River_Source, .Underground_River_Sink:
		shape = terrain_density_cave_passage_shape(.Flooded_Passage)
		shape.radius_neck_scale = 0.14
	}
	return shape
}

terrain_density_cave_entrance_planar_direction :: proc(
	anchor: biomes.CaveAnchor,
	node: biomes.CaveNetworkNode,
) -> (
	dir_x, dir_z: f32,
) {
	dir_x = node.x - anchor.x
	dir_z = node.z - anchor.z
	dir_len := math.sqrt_f32(dir_x * dir_x + dir_z * dir_z)
	if dir_len > 0.001 && anchor.kind != .Cave_Mouth && anchor.kind != .Ravine_Breach {
		return dir_x / dir_len, dir_z / dir_len
	}

	hash := biomes.feature_grid_hash_combine(u64(anchor.id), TERRAIN_CAVE_CURVE_SALT)
	dir_x = biomes.feature_grid_signed_unit_f32(hash, TERRAIN_CAVE_BRANCH_SALT)
	dir_z = biomes.feature_grid_signed_unit_f32(hash, TERRAIN_CAVE_PASSAGE_RIB_SALT)
	dir_len = math.sqrt_f32(dir_x * dir_x + dir_z * dir_z)
	if dir_len <= 0.001 {
		return 0, 1
	}
	return dir_x / dir_len, dir_z / dir_len
}

terrain_density_cave_mouth_size_support :: proc(opening_radius: f32) -> f32 {
	return math.smoothstep(
		TERRAIN_CAVE_MOUTH_SMALL_RADIUS_BLOCKS,
		TERRAIN_CAVE_MOUTH_LARGE_RADIUS_BLOCKS,
		opening_radius,
	)
}

terrain_density_cave_mouth_reach_blocks :: proc(opening_radius: f32) -> f32 {
	size_support := terrain_density_cave_mouth_size_support(opening_radius)
	return(
		opening_radius *
		biomes.regional_terrain_field_lerp(
			TERRAIN_CAVE_MOUTH_SMALL_REACH_SCALE,
			TERRAIN_CAVE_MOUTH_LARGE_REACH_SCALE,
			size_support,
		) \
	)
}

terrain_density_cave_mouth_surface_width_scale :: proc(opening_radius: f32) -> f32 {
	size_support := terrain_density_cave_mouth_size_support(opening_radius)
	return biomes.regional_terrain_field_lerp(
		TERRAIN_CAVE_MOUTH_SMALL_WIDTH_SCALE,
		TERRAIN_CAVE_MOUTH_LARGE_WIDTH_SCALE,
		size_support,
	)
}

terrain_density_cave_mouth_transition_run_blocks :: proc(opening_radius: f32) -> f32 {
	size_support := terrain_density_cave_mouth_size_support(opening_radius)
	return(
		opening_radius *
		biomes.regional_terrain_field_lerp(
			f32(1.70),
			TERRAIN_CAVE_MOUTH_TRANSITION_RUN_SCALE,
			size_support,
		) \
	)
}

terrain_density_cave_mouth_transition_drop_blocks :: proc(opening_radius, total_drop: f32) -> f32 {
	size_support := terrain_density_cave_mouth_size_support(opening_radius)
	drop_limit :=
		opening_radius *
		biomes.regional_terrain_field_lerp(
			f32(1.05),
			TERRAIN_CAVE_MOUTH_TRANSITION_DROP_SCALE,
			size_support,
		)
	return math.min(math.max(f32(3.0), total_drop * 0.32), drop_limit)
}

terrain_density_cave_mouth_near_link_radius :: proc(opening_radius, link_radius: f32) -> f32 {
	size_support := terrain_density_cave_mouth_size_support(opening_radius)
	opening_scaled :=
		opening_radius * biomes.regional_terrain_field_lerp(f32(0.30), f32(0.46), size_support)
	return math.max(f32(1.65), math.min(link_radius, opening_scaled))
}

terrain_density_cave_mouth_transition_style :: proc(
	anchor: biomes.CaveAnchor,
	opening_radius: f32,
) -> TerrainCaveMouthTransitionStyle {
	size_support := terrain_density_cave_mouth_size_support(opening_radius)
	hash := biomes.feature_grid_hash_combine(u64(anchor.id), TERRAIN_CAVE_PASSAGE_RIB_SALT)
	roll := biomes.feature_grid_unit_f32(hash, TERRAIN_CAVE_CURVE_SALT)
	if roll < 0.34 {
		return .Sloped_Tube
	}
	if roll < 0.72 || size_support < TERRAIN_CAVE_MOUTH_VESTIBULE_MIN_SUPPORT {
		return .Curved_Ramp
	}
	return .Spiral_Ramp
}

terrain_density_cave_mouth_transition_scales :: proc(
	style: TerrainCaveMouthTransitionStyle,
) -> TerrainCaveMouthTransitionScales {
	scales := TerrainCaveMouthTransitionScales {
		run_scale          = 1,
		drop_scale         = 1,
		side_scale         = 1,
		vestibule_scale    = 1,
		bend_t             = 0.58,
		bend_return_scale  = 0.55,
		deep_radius_scale  = 0.90,
		near_curve_boost   = 0,
		near_meander_boost = 0,
		deep_curve_boost   = 0.16,
		deep_meander_boost = 0.18,
		deep_lift_boost    = 0,
	}
	switch style {
	case .Sloped_Tube:
		scales.run_scale = 0.92
		scales.side_scale = 0.42
		scales.vestibule_scale = 0.78
		scales.bend_t = 0.64
		scales.bend_return_scale = 0.24
		scales.deep_radius_scale = 0.82
		scales.deep_curve_boost = 0.08
		scales.deep_meander_boost = 0.06
	case .Curved_Ramp:
		scales.drop_scale = 0.94
		scales.side_scale = 1.04
		scales.bend_t = 0.54
		scales.bend_return_scale = 0.68
		scales.near_curve_boost = 0.06
		scales.near_meander_boost = 0.08
		scales.deep_curve_boost = 0.22
		scales.deep_meander_boost = 0.22
	case .Spiral_Ramp:
		scales.run_scale = 1.16
		scales.drop_scale = 0.82
		scales.side_scale = 1.48
		scales.vestibule_scale = 1.16
		scales.bend_t = 0.46
		scales.bend_return_scale = 1.18
		scales.deep_radius_scale = 0.96
		scales.near_curve_boost = 0.14
		scales.near_meander_boost = 0.16
		scales.deep_curve_boost = 0.34
		scales.deep_meander_boost = 0.32
		scales.deep_lift_boost = 0.10
	}
	return scales
}

terrain_density_cave_mouth_transition_bend_extension :: proc(
	style: TerrainCaveMouthTransitionStyle,
	size_support, transition_run: f32,
) -> f32 {
	extension_support := math.smoothstep(
		TERRAIN_CAVE_MOUTH_VESTIBULE_MIN_SUPPORT,
		f32(1),
		size_support,
	)
	switch style {
	case .Curved_Ramp:
		return transition_run * TERRAIN_CAVE_MOUTH_CURVED_BEND_EXTENSION_SCALE * extension_support
	case .Spiral_Ramp:
		return transition_run * TERRAIN_CAVE_MOUTH_SPIRAL_BEND_EXTENSION_SCALE * extension_support
	case .Sloped_Tube:
		small_extension_support :=
			1.0 - math.smoothstep(f32(0), TERRAIN_CAVE_MOUTH_VESTIBULE_MIN_SUPPORT, size_support)
		return(
			transition_run *
			(TERRAIN_CAVE_MOUTH_SMALL_SLOPED_BEND_EXTENSION_SCALE * small_extension_support +
					TERRAIN_CAVE_MOUTH_SLOPED_BEND_EXTENSION_SCALE * extension_support) \
		)
	}
	return 0
}

terrain_density_cave_mouth_transition_plan :: proc(
	anchor: biomes.CaveAnchor,
	node: biomes.CaveNetworkNode,
	opening_radius, link_radius: f32,
) -> TerrainCaveMouthTransitionPlan {
	dir_x, dir_z := terrain_density_cave_entrance_planar_direction(anchor, node)
	side_x := -dir_z
	side_z := dir_x
	size_support := terrain_density_cave_mouth_size_support(opening_radius)
	total_drop := math.max(f32(0), anchor.y - node.y)
	style := terrain_density_cave_mouth_transition_style(anchor, opening_radius)
	scales := terrain_density_cave_mouth_transition_scales(style)
	transition_run :=
		terrain_density_cave_mouth_transition_run_blocks(opening_radius) * scales.run_scale
	transition_drop := math.max(
		f32(3),
		terrain_density_cave_mouth_transition_drop_blocks(opening_radius, total_drop) *
		scales.drop_scale,
	)
	near_radius := terrain_density_cave_mouth_near_link_radius(opening_radius, link_radius)

	hash := biomes.feature_grid_hash_combine(u64(anchor.id), TERRAIN_CAVE_BRANCH_SALT)
	side_sign := biomes.feature_grid_signed_unit_f32(hash, TERRAIN_CAVE_CURVE_SALT)
	if side_sign >= 0 {
		side_sign = 1
	} else {
		side_sign = -1
	}
	side_offset :=
		side_sign *
		opening_radius *
		TERRAIN_CAVE_MOUTH_TRANSITION_SIDE_SCALE *
		biomes.regional_terrain_field_lerp(f32(0.28), f32(1.0), size_support) *
		scales.side_scale

	landing_x := anchor.x + dir_x * transition_run + side_x * side_offset
	landing_y := anchor.y - transition_drop
	landing_z := anchor.z + dir_z * transition_run + side_z * side_offset
	bend_extension := terrain_density_cave_mouth_transition_bend_extension(
		style,
		size_support,
		transition_run,
	)
	bend_x :=
		landing_x +
		(node.x - landing_x) * scales.bend_t -
		side_x * side_offset * scales.bend_return_scale
	bend_z :=
		landing_z +
		(node.z - landing_z) * scales.bend_t -
		side_z * side_offset * scales.bend_return_scale
	bend_y := landing_y + (node.y - landing_y) * scales.bend_t
	if bend_extension > 0 {
		if style == .Curved_Ramp ||
		   (style == .Sloped_Tube && size_support < TERRAIN_CAVE_MOUTH_VESTIBULE_MIN_SUPPORT) {
			bend_x =
				landing_x +
				dir_x * bend_extension -
				side_x * side_offset * scales.bend_return_scale
			bend_z =
				landing_z +
				dir_z * bend_extension -
				side_z * side_offset * scales.bend_return_scale
		} else {
			bend_x += dir_x * bend_extension
			bend_z += dir_z * bend_extension
		}
		bend_run := math.sqrt_f32(
			(bend_x - landing_x) * (bend_x - landing_x) +
			(bend_z - landing_z) * (bend_z - landing_z),
		)
		handoff_run := math.sqrt_f32(
			(node.x - bend_x) * (node.x - bend_x) + (node.z - bend_z) * (node.z - bend_z),
		)
		total_deep_run := math.max(f32(1), bend_run + handoff_run)
		total_deep_drop := math.max(f32(0), landing_y - node.y)
		bend_y = landing_y - total_deep_drop * (bend_run / total_deep_run)
	}
	bend_run_blocks := math.sqrt_f32(
		(bend_x - landing_x) * (bend_x - landing_x) + (bend_z - landing_z) * (bend_z - landing_z),
	)
	handoff_run_blocks := math.sqrt_f32(
		(node.x - bend_x) * (node.x - bend_x) + (node.z - bend_z) * (node.z - bend_z),
	)

	return TerrainCaveMouthTransitionPlan {
		style = style,
		size_support = size_support,
		dir_x = dir_x,
		dir_z = dir_z,
		side_x = side_x,
		side_z = side_z,
		transition_run = transition_run,
		transition_drop = transition_drop,
		near_radius = near_radius,
		side_offset = side_offset,
		landing_x = landing_x,
		landing_y = landing_y,
		landing_z = landing_z,
		bend_x = bend_x,
		bend_y = bend_y,
		bend_z = bend_z,
		near_run_blocks = math.sqrt_f32(
			transition_run * transition_run + side_offset * side_offset,
		),
		near_drop_blocks = math.max(f32(0), anchor.y - landing_y),
		bend_run_blocks = bend_run_blocks,
		bend_drop_blocks = math.max(f32(0), landing_y - bend_y),
		handoff_run_blocks = handoff_run_blocks,
		handoff_drop_blocks = math.max(f32(0), bend_y - node.y),
	}
}

terrain_density_cave_mouth_transition_route_point :: proc(
	anchor: biomes.CaveAnchor,
	node: biomes.CaveNetworkNode,
	plan: TerrainCaveMouthTransitionPlan,
	route_t: f32,
) -> (
	x, y, z: f32,
) {
	t := math.clamp(route_t, f32(0), f32(1))
	near_len := math.max(f32(0.001), plan.near_run_blocks)
	bend_len := math.max(f32(0.001), plan.bend_run_blocks)
	handoff_len := math.max(f32(0.001), plan.handoff_run_blocks)
	total_len := near_len + bend_len + handoff_len
	sample_len := t * total_len

	if sample_len <= near_len {
		segment_t := sample_len / near_len
		x = biomes.regional_terrain_field_lerp(anchor.x, plan.landing_x, segment_t)
		y = biomes.regional_terrain_field_lerp(anchor.y, plan.landing_y, segment_t)
		z = biomes.regional_terrain_field_lerp(anchor.z, plan.landing_z, segment_t)
		return
	}

	sample_len -= near_len
	if sample_len <= bend_len {
		segment_t := sample_len / bend_len
		x = biomes.regional_terrain_field_lerp(plan.landing_x, plan.bend_x, segment_t)
		y = biomes.regional_terrain_field_lerp(plan.landing_y, plan.bend_y, segment_t)
		z = biomes.regional_terrain_field_lerp(plan.landing_z, plan.bend_z, segment_t)
		return
	}

	sample_len -= bend_len
	segment_t := math.clamp(sample_len / handoff_len, f32(0), f32(1))
	x = biomes.regional_terrain_field_lerp(plan.bend_x, node.x, segment_t)
	y = biomes.regional_terrain_field_lerp(plan.bend_y, node.y, segment_t)
	z = biomes.regional_terrain_field_lerp(plan.bend_z, node.z, segment_t)
	return
}

terrain_density_carve_cave_mouth_transition_staging :: proc(
	view: ^world_async.ChunkVoxelView,
	key: biomes.FeatureGridKey,
	chunk_origin: world_async.BlockCoord,
	columns: []TerrainBiomeColumn,
	anchor: biomes.CaveAnchor,
	node: biomes.CaveNetworkNode,
	opening_radius, link_radius: f32,
	plan: TerrainCaveMouthTransitionPlan,
	wall_buffer: ^TerrainCaveWallMaterialBuffer = nil,
) {
	for staging_index := u32(0);
	    staging_index < TERRAIN_CAVE_MOUTH_STAGING_NICHE_COUNT;
	    staging_index += 1 {
		hash := biomes.feature_grid_hash_combine(u64(anchor.id), TERRAIN_CAVE_ROOM_DETAIL_SALT)
		hash = biomes.feature_grid_hash_combine(hash, u64(staging_index))
		step_t := (f32(staging_index) + 0.5) / f32(TERRAIN_CAVE_MOUTH_STAGING_NICHE_COUNT)
		jitter := biomes.feature_grid_signed_unit_f32(hash, TERRAIN_CAVE_CURVE_SALT) * f32(0.055)
		route_t := math.clamp(
			biomes.regional_terrain_field_lerp(
				TERRAIN_CAVE_MOUTH_STAGING_ROUTE_MIN_T,
				TERRAIN_CAVE_MOUTH_STAGING_ROUTE_MAX_T,
				step_t,
			) +
			jitter,
			TERRAIN_CAVE_MOUTH_STAGING_ROUTE_MIN_T,
			TERRAIN_CAVE_MOUTH_STAGING_ROUTE_MAX_T,
		)
		route_x, route_y, route_z := terrain_density_cave_mouth_transition_route_point(
			anchor,
			node,
			plan,
			route_t,
		)
		prev_x, prev_y, prev_z := terrain_density_cave_mouth_transition_route_point(
			anchor,
			node,
			plan,
			math.max(f32(0), route_t - 0.06),
		)
		next_x, next_y, next_z := terrain_density_cave_mouth_transition_route_point(
			anchor,
			node,
			plan,
			math.min(f32(1), route_t + 0.06),
		)
		tangent_x, _, tangent_z := terrain_density_delta_3(
			prev_x,
			prev_y,
			prev_z,
			next_x,
			next_y,
			next_z,
		)
		horizontal_length := math.sqrt_f32(tangent_x * tangent_x + tangent_z * tangent_z)
		side_x := plan.side_x
		side_z := plan.side_z
		if horizontal_length > 0.001 {
			side_x = -tangent_z / horizontal_length
			side_z = tangent_x / horizontal_length
		}

		side_sign := f32(1)
		if plan.side_offset < 0 {
			side_sign = -1
		}
		if biomes.feature_grid_signed_unit_f32(hash, TERRAIN_CAVE_PASSAGE_RIB_SALT) < 0 {
			side_sign = -side_sign
		}
		if (staging_index & 1) != 0 {
			side_sign = -side_sign
		}
		side_x *= side_sign
		side_z *= side_sign

		route_radius := biomes.regional_terrain_field_lerp(
			plan.near_radius,
			link_radius,
			math.smoothstep(f32(0.36), f32(0.82), route_t),
		)
		radius_base := math.clamp(
			opening_radius *
			biomes.regional_terrain_field_lerp(f32(0.30), f32(0.48), plan.size_support) *
			biomes.regional_terrain_field_lerp(
				f32(0.86),
				f32(1.18),
				biomes.feature_grid_unit_f32(hash, TERRAIN_CAVE_ROUGHNESS_SALT),
			),
			TERRAIN_CAVE_MOUTH_STAGING_RADIUS_MIN_BLOCKS,
			TERRAIN_CAVE_MOUTH_STAGING_RADIUS_MAX_BLOCKS,
		)
		side_offset :=
			opening_radius *
			TERRAIN_CAVE_MOUTH_STAGING_SIDE_OFFSET_SCALE *
			biomes.regional_terrain_field_lerp(f32(0.42), f32(0.76), plan.size_support) *
			biomes.regional_terrain_field_lerp(
				f32(0.84),
				f32(1.12),
				biomes.feature_grid_unit_f32(hash, TERRAIN_CAVE_FIELD_DETAIL_SALT),
			)
		center_x := route_x + side_x * side_offset
		center_y :=
			route_y -
			radius_base * 0.10 +
			biomes.feature_grid_signed_unit_f32(hash, TERRAIN_CAVE_BRANCH_SALT) *
				opening_radius *
				0.05
		center_z := route_z + side_z * side_offset

		biome_id := node.biome_id
		radius_x := radius_base * 1.08
		radius_y := math.max(f32(1.65), radius_base * 0.46)
		radius_z := radius_base * 0.78
		#partial switch biome_id {
		case .Fungal_Vaults:
			radius_x *= 1.18
			radius_z *= 1.08
			radius_y *= 0.92
		case .Crystal_Geode_Network:
			radius_x *= 0.78
			radius_y *= 0.80
			radius_z *= 1.18
		case .Buried_Aquifer_Caves:
			radius_x *= 1.10
			radius_y *= 0.64
			radius_z *= 1.04
		}

		throat_shape := terrain_density_cave_passage_shape(.Collapsed_Corridor)
		if biome_id == .Fungal_Vaults {
			throat_shape = terrain_density_cave_passage_shape(.Worm_Path)
			throat_shape.radius_y_scale = math.min(throat_shape.radius_y_scale, f32(0.66))
		} else if biome_id == .Crystal_Geode_Network {
			throat_shape = terrain_density_cave_passage_shape(.Fracture)
		}
		terrain_density_cave_passage_shape_apply_biome(&throat_shape, biome_id)
		throat_radius := math.max(
			f32(1.75),
			math.min(
				radius_base * TERRAIN_CAVE_MOUTH_STAGING_THROAT_SCALE,
				route_radius * f32(0.48),
			),
		)
		terrain_density_carve_rough_segment_shaped(
			view,
			key,
			chunk_origin,
			columns,
			route_x,
			route_y,
			route_z,
			center_x,
			center_y,
			center_z,
			throat_radius,
			throat_shape,
			TERRAIN_CAVE_BRANCH_SALT ~ u64(staging_index + 61),
			biome_id,
			false,
			wall_buffer,
		)
		terrain_density_carve_cave_room_lobed_ellipsoid(
			view,
			key,
			chunk_origin,
			columns,
			center_x,
			center_y,
			center_z,
			radius_x,
			radius_y,
			radius_z,
			TERRAIN_CAVE_ROOM_DETAIL_SALT ~ u64(staging_index + 79),
			biome_id,
			true,
			wall_buffer,
		)
	}
}

terrain_density_carve_cave_mouth_transition :: proc(
	view: ^world_async.ChunkVoxelView,
	key: biomes.FeatureGridKey,
	chunk_origin: world_async.BlockCoord,
	columns: []TerrainBiomeColumn,
	anchor: biomes.CaveAnchor,
	node: biomes.CaveNetworkNode,
	opening_radius, link_radius: f32,
	wall_buffer: ^TerrainCaveWallMaterialBuffer = nil,
) {
	plan := terrain_density_cave_mouth_transition_plan(anchor, node, opening_radius, link_radius)
	scales := terrain_density_cave_mouth_transition_scales(plan.style)

	if plan.size_support >= TERRAIN_CAVE_MOUTH_VESTIBULE_MIN_SUPPORT {
		vestibule_radius :=
			opening_radius *
			biomes.regional_terrain_field_lerp(f32(0.36), f32(0.58), plan.size_support) *
			scales.vestibule_scale
		terrain_density_carve_cave_room_lobed_ellipsoid(
			view,
			key,
			chunk_origin,
			columns,
			anchor.x +
			plan.dir_x * plan.transition_run * 0.58 +
			plan.side_x * plan.side_offset * 0.35,
			anchor.y - plan.transition_drop * 0.62,
			anchor.z +
			plan.dir_z * plan.transition_run * 0.58 +
			plan.side_z * plan.side_offset * 0.35,
			vestibule_radius * 1.05,
			math.max(f32(2.0), vestibule_radius * 0.42),
			vestibule_radius * 0.82,
			TERRAIN_CAVE_ROOM_DETAIL_SALT,
			node.biome_id,
			true,
			wall_buffer,
		)
	}

	near_shape := terrain_density_cave_entrance_link_shape(anchor.kind, true)
	near_shape.radius_y_scale *= 0.86
	near_shape.radius_neck_scale += 0.08
	near_shape.curve_scale += scales.near_curve_boost
	near_shape.meander_scale += scales.near_meander_boost
	terrain_density_carve_rough_segment_shaped(
		view,
		key,
		chunk_origin,
		columns,
		anchor.x,
		anchor.y,
		anchor.z,
		plan.landing_x,
		plan.landing_y,
		plan.landing_z,
		plan.near_radius,
		near_shape,
		TERRAIN_CAVE_DETAIL_SALT,
		node.biome_id,
		false,
		wall_buffer,
	)

	deep_shape := terrain_density_cave_entrance_link_shape(anchor.kind, false)
	deep_shape.curve_scale += scales.deep_curve_boost
	deep_shape.meander_scale += scales.deep_meander_boost
	deep_shape.lift_scale += scales.deep_lift_boost
	terrain_density_carve_rough_segment_shaped(
		view,
		key,
		chunk_origin,
		columns,
		plan.landing_x,
		plan.landing_y,
		plan.landing_z,
		plan.bend_x,
		plan.bend_y,
		plan.bend_z,
		math.max(plan.near_radius, link_radius * scales.deep_radius_scale),
		deep_shape,
		TERRAIN_CAVE_ROUGHNESS_SALT,
		node.biome_id,
		false,
		wall_buffer,
	)
	terrain_density_carve_rough_segment_shaped(
		view,
		key,
		chunk_origin,
		columns,
		plan.bend_x,
		plan.bend_y,
		plan.bend_z,
		node.x,
		node.y,
		node.z,
		link_radius,
		deep_shape,
		TERRAIN_CAVE_BRANCH_SALT,
		node.biome_id,
		false,
		wall_buffer,
	)
	terrain_density_carve_cave_mouth_transition_staging(
		view,
		key,
		chunk_origin,
		columns,
		anchor,
		node,
		opening_radius,
		link_radius,
		plan,
		wall_buffer,
	)
}

terrain_density_carve_cave_mouth :: proc(
	view: ^world_async.ChunkVoxelView,
	key: biomes.FeatureGridKey,
	chunk_origin: world_async.BlockCoord,
	columns: []TerrainBiomeColumn,
	anchor: biomes.CaveAnchor,
	node: biomes.CaveNetworkNode,
	opening_radius: f32,
	wall_buffer: ^TerrainCaveWallMaterialBuffer = nil,
) {
	dir_x, dir_z := terrain_density_cave_entrance_planar_direction(anchor, node)
	side_x := -dir_z
	side_z := dir_x
	size_support := terrain_density_cave_mouth_size_support(opening_radius)
	reach := terrain_density_cave_mouth_reach_blocks(opening_radius)
	height := math.max(
		f32(4),
		opening_radius * biomes.regional_terrain_field_lerp(f32(0.70), f32(0.95), size_support),
	)
	mouth_skew := biomes.regional_terrain_field_value_noise_3(
		key,
		i32(math.floor_f32(anchor.x)),
		i32(math.floor_f32(anchor.y)),
		i32(math.floor_f32(anchor.z)),
		28,
		TERRAIN_CAVE_BRANCH_SALT,
	)
	local_min_x, local_max_x, local_min_y, local_max_y, local_min_z, local_max_z, intersects :=
		terrain_density_carve_bounds_from_extents(
			chunk_origin,
			anchor.x - reach - opening_radius * 1.45,
			anchor.x + reach + opening_radius * 1.45,
			anchor.y - height * 1.60,
			anchor.y + 3,
			anchor.z - reach - opening_radius * 1.45,
			anchor.z + reach + opening_radius * 1.45,
		)
	if !intersects {
		return
	}

	for z := local_min_z; z <= local_max_z; z += 1 {
		world_z := f32(chunk_origin.z + z) + 0.5
		for y := local_min_y; y <= local_max_y; y += 1 {
			world_y := f32(chunk_origin.y + y) + 0.5
			for x := local_min_x; x <= local_max_x; x += 1 {
				if !terrain_density_local_block_can_carve(view, x, y, z) {
					continue
				}
				world_x := f32(chunk_origin.x + x) + 0.5
				column := columns[x + z * CHUNK_BLOCK_LENGTH]
				below_surface := column.surface_height_blocks - world_y
				if below_surface < -1 || below_surface > height * 1.75 {
					continue
				}

				rel_x := world_x - anchor.x
				rel_z := world_z - anchor.z
				forward := rel_x * dir_x + rel_z * dir_z
				if forward < -opening_radius * TERRAIN_CAVE_MOUTH_EXTERIOR_APRON_REACH_SCALE ||
				   forward > reach {
					continue
				}
				side := rel_x * side_x + rel_z * side_z
				t := math.clamp(forward / reach, f32(0), f32(1))
				width_base :=
					opening_radius *
					biomes.regional_terrain_field_lerp(
						terrain_density_cave_mouth_surface_width_scale(opening_radius),
						f32(0.42),
						t,
					)
				arch_height := height * biomes.regional_terrain_field_lerp(1.05, 0.46, t)
				lower_arch_support := math.smoothstep(
					arch_height * 0.34,
					arch_height * 0.92,
					below_surface,
				)
				width :=
					width_base *
					terrain_density_cave_mouth_lower_width_scale(t, lower_arch_support)
				side_bias := mouth_skew * opening_radius * 0.14 * (1.0 - t)
				height_unit := below_surface / arch_height
				vertical := height_unit - 0.32
				if vertical > 0 {
					vertical *= 0.78
				} else {
					vertical *= 1.12
				}
				side_normalized := (side - side_bias) / width
				side_abs := math.abs(side_normalized)
				upper_lip_support := math.clamp(
					(f32(0.42) - height_unit) * f32(3.125),
					f32(0),
					f32(1),
				)
				side_shoulder := math.clamp(
					(side_abs - TERRAIN_CAVE_MOUTH_SIDE_SHOULDER_START) *
					TERRAIN_CAVE_MOUTH_SIDE_SHOULDER_INV_RANGE,
					f32(0),
					f32(1),
				)
				center_support := math.clamp(1.0 - side_abs * f32(2.381), f32(0), f32(1))
				jaw_band := math.clamp(
					1.0 - math.abs(side_abs - f32(0.56)) * f32(3.125),
					f32(0),
					f32(1),
				)
				jaw_side_direction := f32(0)
				if side_normalized > 0 {
					jaw_side_direction = 1
				} else if side_normalized < 0 {
					jaw_side_direction = -1
				}
				jaw_asymmetry := math.clamp(
					1.0 + jaw_side_direction * mouth_skew * f32(0.22),
					f32(0.78),
					f32(1.22),
				)
				lower_jaw_relief :=
					lower_arch_support *
					(1.0 - t * 0.78) *
					jaw_band *
					jaw_asymmetry *
					TERRAIN_CAVE_MOUTH_LOWER_JAW_RELIEF_STRENGTH
				upper_center_lip :=
					upper_lip_support *
					(1.0 - t * 0.62) *
					center_support *
					TERRAIN_CAVE_MOUTH_UPPER_LIP_RIB_STRENGTH
				side_alcove_relief :=
					terrain_density_cave_mouth_side_alcove_relief(
						t,
						side_abs,
						lower_arch_support,
						size_support,
					) *
					jaw_asymmetry
				exterior_apron_relief := terrain_density_cave_mouth_exterior_apron_relief(
					forward,
					side,
					below_surface,
					opening_radius,
					width_base,
					side_bias,
					size_support,
				)
				shape :=
					side_normalized * side_normalized +
					vertical * vertical +
					upper_lip_support *
						(1.0 - t * 0.55) *
						side_shoulder *
						TERRAIN_CAVE_MOUTH_SIDE_SHOULDER_STRENGTH -
					lower_arch_support *
						(1.0 - t) *
						center_support *
						TERRAIN_CAVE_MOUTH_CENTER_RELIEF_STRENGTH -
					lower_jaw_relief +
					upper_center_lip -
					side_alcove_relief -
					exterior_apron_relief
				if shape > 1.18 {
					continue
				}
				rough := biomes.regional_terrain_field_value_noise_3(
					key,
					chunk_origin.x + x,
					chunk_origin.y + y,
					chunk_origin.z + z,
					14,
					TERRAIN_CAVE_DETAIL_SALT,
				)
				if shape <= 1.0 + rough * 0.18 {
					terrain_density_carve_checked_local_block_with_material(
						view,
						key,
						chunk_origin,
						columns,
						x,
						y,
						z,
						node.biome_id,
						false,
						wall_buffer,
					)
				}
			}
		}
	}
}

terrain_density_cave_mouth_lower_width_scale :: proc(forward_t, lower_arch_support: f32) -> f32 {
	return 1.0 + lower_arch_support * (1.0 - forward_t) * TERRAIN_CAVE_MOUTH_LOWER_WIDTH_BOOST
}

terrain_density_cave_mouth_side_shoulder_penalty :: proc(
	forward_t, side_abs, upper_lip_support: f32,
) -> f32 {
	side_shoulder := math.clamp(
		(side_abs - TERRAIN_CAVE_MOUTH_SIDE_SHOULDER_START) *
		TERRAIN_CAVE_MOUTH_SIDE_SHOULDER_INV_RANGE,
		f32(0),
		f32(1),
	)
	return(
		upper_lip_support *
		(1.0 - forward_t * 0.55) *
		side_shoulder *
		TERRAIN_CAVE_MOUTH_SIDE_SHOULDER_STRENGTH \
	)
}

terrain_density_cave_mouth_lower_center_relief :: proc(
	forward_t, side_abs, lower_arch_support: f32,
) -> f32 {
	center_support := math.clamp(1.0 - side_abs * f32(2.381), f32(0), f32(1))
	return(
		lower_arch_support *
		(1.0 - forward_t) *
		center_support *
		TERRAIN_CAVE_MOUTH_CENTER_RELIEF_STRENGTH \
	)
}

terrain_density_cave_mouth_lower_jaw_relief :: proc(
	forward_t, side_abs, lower_arch_support: f32,
) -> f32 {
	jaw_band := math.clamp(1.0 - math.abs(side_abs - f32(0.56)) * f32(3.125), f32(0), f32(1))
	return(
		lower_arch_support *
		(1.0 - forward_t * 0.78) *
		jaw_band *
		TERRAIN_CAVE_MOUTH_LOWER_JAW_RELIEF_STRENGTH \
	)
}

terrain_density_cave_mouth_upper_lip_rib :: proc(
	forward_t, side_abs, upper_lip_support: f32,
) -> f32 {
	center_support := math.clamp(1.0 - side_abs * f32(2.381), f32(0), f32(1))
	return(
		upper_lip_support *
		(1.0 - forward_t * 0.62) *
		center_support *
		TERRAIN_CAVE_MOUTH_UPPER_LIP_RIB_STRENGTH \
	)
}

terrain_density_cave_mouth_side_alcove_relief :: proc(
	forward_t, side_abs, lower_arch_support, size_support: f32,
) -> f32 {
	forward_band :=
		math.smoothstep(f32(0.08), f32(0.36), forward_t) *
		(1.0 - math.smoothstep(f32(0.70), f32(0.96), forward_t))
	side_band := math.clamp(1.0 - math.abs(side_abs - f32(0.72)) * f32(3.85), f32(0), f32(1))
	size_scale := biomes.regional_terrain_field_lerp(
		TERRAIN_CAVE_MOUTH_SIDE_ALCOVE_SMALL_SCALE,
		TERRAIN_CAVE_MOUTH_SIDE_ALCOVE_LARGE_SCALE,
		size_support,
	)
	return(
		lower_arch_support *
		forward_band *
		side_band *
		TERRAIN_CAVE_MOUTH_SIDE_ALCOVE_RELIEF_STRENGTH *
		size_scale \
	)
}

terrain_density_cave_mouth_exterior_apron_relief :: proc(
	forward, side, below_surface, opening_radius, width_base, side_bias, size_support: f32,
) -> f32 {
	apron_reach := opening_radius * TERRAIN_CAVE_MOUTH_EXTERIOR_APRON_REACH_SCALE
	if apron_reach <= 0.001 {
		return 0
	}
	apron_center := -apron_reach * f32(0.42)
	forward_distance := math.abs(forward - apron_center) / apron_reach
	forward_support :=
		(1.0 - math.smoothstep(f32(0.30), f32(1.0), forward_distance)) *
		(1.0 - math.smoothstep(opening_radius * f32(0.18), opening_radius * f32(0.56), forward))
	side_width :=
		math.max(f32(1), width_base) *
		TERRAIN_CAVE_MOUTH_EXTERIOR_APRON_SIDE_SCALE *
		biomes.regional_terrain_field_lerp(f32(0.88), f32(1.10), size_support)
	side_support :=
		1.0 - math.smoothstep(f32(0.62), f32(1.05), math.abs(side - side_bias) / side_width)
	depth_support :=
		1.0 -
		math.smoothstep(
			f32(0),
			opening_radius * TERRAIN_CAVE_MOUTH_EXTERIOR_APRON_DEPTH_SCALE,
			math.max(f32(0), below_surface),
		)
	return(
		forward_support *
		side_support *
		depth_support *
		biomes.regional_terrain_field_lerp(f32(0.78), f32(1.12), size_support) *
		TERRAIN_CAVE_MOUTH_EXTERIOR_APRON_RELIEF_STRENGTH \
	)
}

terrain_density_carve_sinkhole_throat :: proc(
	view: ^world_async.ChunkVoxelView,
	key: biomes.FeatureGridKey,
	chunk_origin: world_async.BlockCoord,
	columns: []TerrainBiomeColumn,
	anchor: biomes.CaveAnchor,
	node: biomes.CaveNetworkNode,
	opening_radius, link_radius: f32,
	wall_buffer: ^TerrainCaveWallMaterialBuffer = nil,
) {
	depth := math.max(opening_radius * 2.2, anchor.y - node.y)
	dir_x, dir_z := terrain_density_cave_entrance_planar_direction(anchor, node)
	side_x := -dir_z
	side_z := dir_x
	rim_skew := biomes.regional_terrain_field_value_noise_3(
		key,
		i32(math.floor_f32(anchor.x)),
		i32(math.floor_f32(anchor.y)),
		i32(math.floor_f32(anchor.z)),
		31,
		TERRAIN_CAVE_BRANCH_SALT,
	)
	spiral_hash := biomes.feature_grid_hash_combine(u64(anchor.id), TERRAIN_CAVE_CURVE_SALT)
	spiral_roll := biomes.feature_grid_unit_f32(spiral_hash, TERRAIN_CAVE_BRANCH_SALT)
	spiral_strength := math.smoothstep(f32(0.24), f32(0.96), spiral_roll)
	spiral_turn := f32(1)
	if biomes.feature_grid_signed_unit_f32(spiral_hash, TERRAIN_CAVE_PASSAGE_RIB_SALT) < 0 {
		spiral_turn = -1
	}
	spiral_phase :=
		biomes.feature_grid_unit_f32(spiral_hash, TERRAIN_CAVE_DETAIL_SALT) * f32(6.2831855)
	spiral_extent := opening_radius * TERRAIN_SINKHOLE_SPIRAL_OFFSET_SCALE * spiral_strength
	local_min_x, local_max_x, local_min_y, local_max_y, local_min_z, local_max_z, intersects :=
		terrain_density_carve_bounds_from_extents(
			chunk_origin,
			anchor.x - opening_radius * 1.48 - spiral_extent,
			anchor.x + opening_radius * 1.48 + spiral_extent,
			anchor.y - depth - 2,
			anchor.y + 2,
			anchor.z - opening_radius * 1.48 - spiral_extent,
			anchor.z + opening_radius * 1.48 + spiral_extent,
		)
	if !intersects {
		return
	}

	for z := local_min_z; z <= local_max_z; z += 1 {
		world_z := f32(chunk_origin.z + z) + 0.5
		for y := local_min_y; y <= local_max_y; y += 1 {
			world_y := f32(chunk_origin.y + y) + 0.5
			drop := anchor.y - world_y
			if drop < -1 || drop > depth {
				continue
			}
			t := math.clamp(drop / depth, f32(0), f32(1))
			radius := biomes.regional_terrain_field_lerp(opening_radius * 1.18, link_radius, t)
			spiral_support :=
				math.smoothstep(f32(0.08), f32(0.72), t) *
				(1.0 - math.smoothstep(f32(0.82), f32(1.0), t))
			spiral_angle := spiral_phase + spiral_turn * t * f32(5.15)
			spiral_x := dir_x * math.cos(spiral_angle) + side_x * math.sin(spiral_angle)
			spiral_z := dir_z * math.cos(spiral_angle) + side_z * math.sin(spiral_angle)
			center_x :=
				anchor.x +
				dir_x * opening_radius * 0.12 * t +
				spiral_x * spiral_extent * spiral_support
			center_z :=
				anchor.z +
				dir_z * opening_radius * 0.12 * t +
				spiral_z * spiral_extent * spiral_support
			major_radius := radius * terrain_density_sinkhole_major_radius_scale(t)
			minor_radius := radius * terrain_density_sinkhole_minor_radius_scale(t)
			for x := local_min_x; x <= local_max_x; x += 1 {
				if !terrain_density_local_block_can_carve(view, x, y, z) {
					continue
				}
				world_x := f32(chunk_origin.x + x) + 0.5
				dx := world_x - center_x
				dz := world_z - center_z
				forward := dx * dir_x + dz * dir_z
				side := dx * side_x + dz * side_z
				forward_unit := forward / major_radius
				side_unit := side / minor_radius
				side_abs := math.abs(side_unit)
				forward_abs := math.abs(forward_unit)
				side_direction := f32(0)
				if side_unit > 0 {
					side_direction = 1
				} else if side_unit < 0 {
					side_direction = -1
				}
				ledge_asymmetry := math.clamp(
					1.0 + side_direction * rim_skew * f32(0.20),
					f32(0.82),
					f32(1.18),
				)
				shape :=
					forward_unit * forward_unit +
					side_unit * side_unit +
					terrain_density_sinkhole_rim_lip_penalty(t, forward_abs, side_abs) -
					terrain_density_sinkhole_side_ledge_relief(t, side_abs) * ledge_asymmetry
				if shape > 1.22 {
					continue
				}
				rough := biomes.regional_terrain_field_value_noise_3(
					key,
					chunk_origin.x + x,
					chunk_origin.y + y,
					chunk_origin.z + z,
					12,
					TERRAIN_CAVE_DETAIL_SALT,
				)
				if shape <= 1.0 + rough * 0.22 {
					terrain_density_carve_checked_local_block_with_material(
						view,
						key,
						chunk_origin,
						columns,
						x,
						y,
						z,
						node.biome_id,
						false,
						wall_buffer,
					)
				}
			}
		}
	}
}

terrain_density_sinkhole_major_radius_scale :: proc(depth_t: f32) -> f32 {
	return biomes.regional_terrain_field_lerp(f32(1.12), f32(0.92), depth_t)
}

terrain_density_sinkhole_minor_radius_scale :: proc(depth_t: f32) -> f32 {
	return biomes.regional_terrain_field_lerp(f32(0.78), f32(1.02), depth_t)
}

terrain_density_sinkhole_side_ledge_relief :: proc(depth_t, side_abs: f32) -> f32 {
	upper_support := math.clamp(1.0 - depth_t * f32(2.2), f32(0), f32(1))
	side_band := math.clamp(1.0 - math.abs(side_abs - f32(0.56)) * f32(3.125), f32(0), f32(1))
	return upper_support * side_band * TERRAIN_SINKHOLE_SIDE_LEDGE_RELIEF_STRENGTH
}

terrain_density_sinkhole_rim_lip_penalty :: proc(depth_t, forward_abs, side_abs: f32) -> f32 {
	rim_support := math.clamp(1.0 - depth_t * f32(3.4), f32(0), f32(1))
	center_support := math.clamp(1.0 - (forward_abs + side_abs) * f32(0.95), f32(0), f32(1))
	return rim_support * center_support * TERRAIN_SINKHOLE_RIM_LIP_STRENGTH
}

terrain_density_carve_rough_ellipsoid :: proc(
	view: ^world_async.ChunkVoxelView,
	key: biomes.FeatureGridKey,
	chunk_origin: world_async.BlockCoord,
	columns: []TerrainBiomeColumn,
	center_x, center_y, center_z, radius_x, radius_y, radius_z: f32,
	noise_salt: u64,
	biome_id: biomes.BiomeID,
	directional_material_profile: bool = false,
	wall_buffer: ^TerrainCaveWallMaterialBuffer = nil,
) {
	rx := math.max(f32(1), radius_x)
	ry := math.max(f32(1), radius_y)
	rz := math.max(f32(1), radius_z)
	padding := math.max(rx, math.max(ry, rz)) * 0.18 + 2
	local_min_x, local_max_x, local_min_y, local_max_y, local_min_z, local_max_z, intersects :=
		terrain_density_carve_bounds_from_extents(
			chunk_origin,
			center_x - rx - padding,
			center_x + rx + padding,
			center_y - ry - padding,
			center_y + ry + padding,
			center_z - rz - padding,
			center_z + rz + padding,
		)
	if !intersects {
		return
	}

	for z := local_min_z; z <= local_max_z; z += 1 {
		world_z := f32(chunk_origin.z + z) + 0.5
		nz := (world_z - center_z) / rz
		nz_sq := nz * nz
		for y := local_min_y; y <= local_max_y; y += 1 {
			world_y := f32(chunk_origin.y + y) + 0.5
			ny := (world_y - center_y) / ry
			ny_sq := ny * ny
			row_min_x, row_max_x, row_intersects := terrain_density_ellipsoid_row_x_bounds(
				chunk_origin,
				local_min_x,
				local_max_x,
				center_x,
				rx,
				ny_sq + nz_sq,
				TERRAIN_CAVE_ROUGH_ELLIPSOID_PRE_NOISE_SHAPE_MAX,
			)
			if !row_intersects {
				continue
			}
			for x := row_min_x; x <= row_max_x; x += 1 {
				if !terrain_density_local_block_can_carve(view, x, y, z) {
					continue
				}
				world_x := f32(chunk_origin.x + x) + 0.5
				nx := (world_x - center_x) / rx
				shape := nx * nx + ny * ny + nz * nz
				if shape > TERRAIN_CAVE_ROUGH_ELLIPSOID_PRE_NOISE_SHAPE_MAX {
					continue
				}
				rough := biomes.regional_terrain_field_value_noise_3(
					key,
					chunk_origin.x + x,
					chunk_origin.y + y,
					chunk_origin.z + z,
					24,
					noise_salt,
				)
				core_support := math.clamp((f32(1.0) - shape) * 1.389, f32(0), f32(1))
				rough_scale :=
					TERRAIN_CAVE_ROUGH_ELLIPSOID_EDGE_SCALE -
					(TERRAIN_CAVE_ROUGH_ELLIPSOID_EDGE_SCALE -
							TERRAIN_CAVE_ROUGH_ELLIPSOID_CORE_SCALE) *
						core_support
				threshold := 1.0 + rough * rough_scale
				if shape <= threshold {
					terrain_density_carve_checked_local_block_with_material(
						view,
						key,
						chunk_origin,
						columns,
						x,
						y,
						z,
						biome_id,
						directional_material_profile,
						wall_buffer,
					)
				}
			}
		}
	}
}

terrain_density_cave_segment_shape_default :: proc() -> TerrainCaveSegmentShape {
	return {
		radius_x_scale = 1.10,
		radius_y_scale = 0.88,
		radius_z_scale = 1.05,
		radius_noise_scale = 0.18,
		radius_neck_scale = 0.16,
		radius_swell_scale = 0.20,
		radius_endpoint_scale = 0.0,
		meander_scale = 0.72,
		lift_scale = 0.36,
		curve_scale = 0.0,
		wall_scallop_scale = 0.10,
		wall_notch_scale = 0.08,
		wall_rib_scale = 0.10,
		wall_lip_relief_scale = 0.0,
	}
}

terrain_density_cave_passage_shape_apply_regional_seam :: proc(shape: ^TerrainCaveSegmentShape) {
	shape.radius_x_scale = math.max(shape.radius_x_scale, f32(1.16))
	shape.radius_y_scale = math.max(shape.radius_y_scale, f32(1.12))
	shape.radius_z_scale = math.max(shape.radius_z_scale, f32(1.12))
	shape.radius_noise_scale = math.min(shape.radius_noise_scale, f32(0.19))
	shape.radius_neck_scale = math.min(shape.radius_neck_scale, f32(0.08))
	shape.radius_swell_scale = math.max(shape.radius_swell_scale, f32(0.29))
	shape.radius_endpoint_scale = math.max(shape.radius_endpoint_scale, f32(0.09))
	shape.wall_notch_scale = math.min(shape.wall_notch_scale, f32(0.16))
	shape.wall_scallop_scale = math.max(
		shape.wall_scallop_scale,
		TERRAIN_CAVE_EDGE_SEAM_WALL_SCALLOP_MIN,
	)
	shape.wall_rib_scale = math.max(shape.wall_rib_scale, TERRAIN_CAVE_EDGE_SEAM_WALL_RIB_MIN)
	shape.wall_lip_relief_scale = math.max(
		shape.wall_lip_relief_scale,
		TERRAIN_CAVE_EDGE_SEAM_LIP_RELIEF_SCALE,
	)
}

terrain_density_cave_field_path_shape :: proc() -> TerrainCaveSegmentShape {
	shape := terrain_density_cave_passage_shape(.Worm_Path)
	shape.radius_x_scale = TERRAIN_CAVE_FIELD_PATH_CROSS_AXIS_SCALE
	shape.radius_y_scale = TERRAIN_CAVE_FIELD_PATH_Y_SCALE
	shape.radius_z_scale = TERRAIN_CAVE_FIELD_PATH_CROSS_AXIS_SCALE
	shape.radius_noise_scale = 0.20
	shape.radius_neck_scale = 0.18
	shape.radius_swell_scale = 0.16
	shape.radius_endpoint_scale = 0.03
	shape.meander_scale = 0.46
	shape.lift_scale = 0.20
	shape.curve_scale = 0.18
	shape.wall_scallop_scale = 0.10
	shape.wall_notch_scale = 0.08
	shape.wall_rib_scale = 0.08
	return shape
}

terrain_density_cave_passage_radius_profile_scale :: proc(
	shape: TerrainCaveSegmentShape,
	rough, center_bulge: f32,
) -> f32 {
	neck := math.smoothstep(f32(0.18), f32(0.92), -rough)
	swell := math.smoothstep(f32(0.22), f32(0.95), rough)
	scale :=
		1.0 +
		center_bulge * shape.radius_swell_scale * 0.18 +
		swell * shape.radius_swell_scale -
		neck * shape.radius_neck_scale
	return math.clamp(scale, f32(0.72), f32(1.34))
}

terrain_density_cave_passage_radius_soft_cap :: proc(radius, cap: f32) -> f32 {
	if radius <= cap {
		return radius
	}
	return cap + (radius - cap) * TERRAIN_CAVE_EDGE_RADIUS_SOFT_CAP_BLEND
}

terrain_density_cave_segment_triangle_wave :: proc(value: f32) -> f32 {
	phase := value - math.floor_f32(value)
	return 1.0 - math.abs(phase * 2.0 - 1.0)
}

terrain_density_carve_rough_segment_shaped :: proc(
	view: ^world_async.ChunkVoxelView,
	key: biomes.FeatureGridKey,
	chunk_origin: world_async.BlockCoord,
	columns: []TerrainBiomeColumn,
	from_x, from_y, from_z, to_x, to_y, to_z, radius_blocks: f32,
	shape: TerrainCaveSegmentShape,
	noise_salt: u64,
	biome_id: biomes.BiomeID,
	directional_material_profile: bool = false,
	wall_buffer: ^TerrainCaveWallMaterialBuffer = nil,
	carveable_row_mask: ^TerrainCarveableRowMask = nil,
) {
	radius := math.max(f32(1), radius_blocks)
	max_radius := radius * 1.45 + 2
	when TERRAIN_GENERATION_PROFILE_PHASES {
		if terrain_generation_profile_edge_core_active {
			terrain_generation_profile_stats.edge_core_segment_calls += 1
		}
	}
	t_min, t_max, intersects := terrain_density_segment_chunk_overlap(
		chunk_origin,
		from_x,
		from_y,
		from_z,
		to_x,
		to_y,
		to_z,
		max_radius,
	)
	if !intersects {
		return
	}
	when TERRAIN_GENERATION_PROFILE_PHASES {
		if terrain_generation_profile_edge_core_active {
			terrain_generation_profile_stats.edge_core_segment_bounds_hits += 1
		}
	}

	dx := to_x - from_x
	dy := to_y - from_y
	dz := to_z - from_z
	length := math.sqrt_f32(dx * dx + dy * dy + dz * dz)
	if length <= 0.001 {
		terrain_density_carve_rough_ellipsoid(
			view,
			key,
			chunk_origin,
			columns,
			from_x,
			from_y,
			from_z,
			radius * shape.radius_x_scale,
			radius * shape.radius_y_scale,
			radius * shape.radius_z_scale,
			noise_salt,
			biome_id,
			directional_material_profile,
			wall_buffer,
		)
		return
	}

	length_sq := length * length
	tangent_x := dx / length
	tangent_y := dy / length
	tangent_z := dz / length
	length_xz := math.sqrt_f32(dx * dx + dz * dz)
	side_x := f32(1)
	side_y := f32(0)
	side_z := f32(0)
	if length_xz > 0.001 {
		side_x = -dz / length_xz
		side_z = dx / length_xz
	}
	up_x := side_y * tangent_z - side_z * tangent_y
	up_y := side_z * tangent_x - side_x * tangent_z
	up_z := side_x * tangent_y - side_y * tangent_x

	max_shape_scale := math.max(
		shape.radius_y_scale,
		math.max(shape.radius_x_scale, shape.radius_z_scale),
	)
	max_curve_extent :=
		radius * (shape.curve_scale + shape.meander_scale * 0.42 + shape.lift_scale * 0.28)
	max_carve_radius := radius * max_shape_scale * 1.46 + max_curve_extent + 2
	seg_min_x := math.min(from_x + dx * t_min, from_x + dx * t_max) - max_carve_radius
	seg_max_x := math.max(from_x + dx * t_min, from_x + dx * t_max) + max_carve_radius
	seg_min_y := math.min(from_y + dy * t_min, from_y + dy * t_max) - max_carve_radius
	seg_max_y := math.max(from_y + dy * t_min, from_y + dy * t_max) + max_carve_radius
	seg_min_z := math.min(from_z + dz * t_min, from_z + dz * t_max) - max_carve_radius
	seg_max_z := math.max(from_z + dz * t_min, from_z + dz * t_max) + max_carve_radius
	local_min_x, local_max_x, local_min_y, local_max_y, local_min_z, local_max_z, bounds_intersects :=
		terrain_density_carve_bounds_from_extents(
			chunk_origin,
			seg_min_x,
			seg_max_x,
			seg_min_y,
			seg_max_y,
			seg_min_z,
			seg_max_z,
		)
	if !bounds_intersects {
		return
	}

	curve_hash := biomes.feature_grid_hash_mix(key.world_seed)
	curve_hash = biomes.feature_grid_hash_combine(curve_hash, u64(key.generator_version))
	curve_hash = biomes.feature_grid_hash_combine(curve_hash, TERRAIN_CAVE_CURVE_SALT)
	curve_hash = biomes.feature_grid_hash_combine(
		curve_hash,
		biomes.feature_grid_hash_i32(i32(math.floor_f32(from_x))),
	)
	curve_hash = biomes.feature_grid_hash_combine(
		curve_hash,
		biomes.feature_grid_hash_i32(i32(math.floor_f32(from_y))),
	)
	curve_hash = biomes.feature_grid_hash_combine(
		curve_hash,
		biomes.feature_grid_hash_i32(i32(math.floor_f32(from_z))),
	)
	curve_hash = biomes.feature_grid_hash_combine(
		curve_hash,
		biomes.feature_grid_hash_i32(i32(math.floor_f32(to_x))),
	)
	curve_hash = biomes.feature_grid_hash_combine(
		curve_hash,
		biomes.feature_grid_hash_i32(i32(math.floor_f32(to_y))),
	)
	curve_hash = biomes.feature_grid_hash_combine(
		curve_hash,
		biomes.feature_grid_hash_i32(i32(math.floor_f32(to_z))),
	)
	curve_side := biomes.feature_grid_signed_unit_f32(curve_hash, TERRAIN_CAVE_CURVE_SALT)
	curve_lift := biomes.feature_grid_signed_unit_f32(curve_hash, TERRAIN_CAVE_BRANCH_SALT)
	branch_side := biomes.feature_grid_signed_unit_f32(
		curve_hash,
		TERRAIN_CAVE_FIELD_SPAGHETTI_A_SALT,
	)
	branch_lift := biomes.feature_grid_signed_unit_f32(
		curve_hash,
		TERRAIN_CAVE_FIELD_SPAGHETTI_B_SALT,
	)
	neck_phase := biomes.feature_grid_unit_f32(curve_hash, TERRAIN_CAVE_PASSAGE_RIB_SALT)
	wall_phase := biomes.feature_grid_unit_f32(curve_hash, TERRAIN_CAVE_DETAIL_SALT)
	wall_phase_b := biomes.feature_grid_unit_f32(curve_hash, TERRAIN_CAVE_ROOM_DETAIL_SALT)
	notch_band_center := biomes.regional_terrain_field_lerp(f32(0.56), f32(0.78), wall_phase)
	notch_frequency := biomes.regional_terrain_field_lerp(f32(2.80), f32(4.90), wall_phase_b)
	rib_frequency := biomes.regional_terrain_field_lerp(f32(4.60), f32(7.10), wall_phase)

	horizontal_radius_scale := (shape.radius_x_scale + shape.radius_z_scale) * 0.5
	raw_t_min := -max_carve_radius / length
	raw_t_max := 1.0 + max_carve_radius / length
	max_along_extent := radius * 1.10 * 1.46 + 2
	max_side_extent :=
		radius * horizontal_radius_scale * 1.46 +
		radius *
			(math.abs(curve_side) * shape.curve_scale +
					math.abs(branch_side) * shape.meander_scale * 0.42) +
		2
	max_up_extent :=
		radius * shape.radius_y_scale * 1.46 +
		radius *
			(math.abs(curve_lift) * shape.curve_scale * 0.45 +
					math.abs(branch_lift) * shape.lift_scale * 0.28) +
		2
	for z := local_min_z; z <= local_max_z; z += 1 {
		world_z := f32(chunk_origin.z + z) + 0.5
		for y := local_min_y; y <= local_max_y; y += 1 {
			world_y := f32(chunk_origin.y + y) + 0.5
			row_block_y := chunk_origin.y + y
			row_full_vertical_support :=
				f32(row_block_y) >= TERRAIN_CAVE_BOTTOM_CUSHION_END_BLOCKS &&
				f32(row_block_y) <= TERRAIN_CAVE_TOP_CUSHION_START_BLOCKS
			when TERRAIN_GENERATION_PROFILE_PHASES {
				if terrain_generation_profile_edge_core_active {
					terrain_generation_profile_stats.edge_core_rows_scanned += 1
				}
			}
			row_min_x, row_max_x, row_intersects :=
				terrain_density_segment_projection_row_x_bounds(
					chunk_origin,
					local_min_x,
					local_max_x,
					world_y,
					world_z,
					from_x,
					from_y,
					from_z,
					dx,
					dy,
					dz,
					length_sq,
					raw_t_min,
					raw_t_max,
				)
			if !row_intersects {
				continue
			}
			when TERRAIN_GENERATION_PROFILE_PHASES {
				if terrain_generation_profile_edge_core_active {
					terrain_generation_profile_stats.edge_core_rows_projected += 1
				}
			}
			row_min_x, row_max_x, row_intersects = terrain_density_segment_capsule_row_x_bounds(
				chunk_origin,
				row_min_x,
				row_max_x,
				world_y,
				world_z,
				from_x,
				from_y,
				from_z,
				tangent_x,
				tangent_y,
				tangent_z,
				max_carve_radius,
			)
			if !row_intersects {
				continue
			}
			row_min_x, row_max_x, row_intersects = terrain_density_axis_row_x_bounds(
				chunk_origin,
				row_min_x,
				row_max_x,
				world_y,
				world_z,
				from_x,
				from_y,
				from_z,
				tangent_x,
				tangent_y,
				tangent_z,
				-max_along_extent,
				length + max_along_extent,
			)
			if !row_intersects {
				continue
			}
			row_min_x, row_max_x, row_intersects = terrain_density_axis_row_x_bounds(
				chunk_origin,
				row_min_x,
				row_max_x,
				world_y,
				world_z,
				from_x,
				from_y,
				from_z,
				side_x,
				side_y,
				side_z,
				-max_side_extent,
				max_side_extent,
			)
			if !row_intersects {
				continue
			}
			row_min_x, row_max_x, row_intersects = terrain_density_axis_row_x_bounds(
				chunk_origin,
				row_min_x,
				row_max_x,
				world_y,
				world_z,
				from_x,
				from_y,
				from_z,
				up_x,
				up_y,
				up_z,
				-max_up_extent,
				max_up_extent,
			)
			if !row_intersects {
				continue
			}
			row_min_x, row_max_x, row_intersects = terrain_density_dual_axis_ellipse_row_x_bounds(
				chunk_origin,
				row_min_x,
				row_max_x,
				world_y,
				world_z,
				from_x,
				from_y,
				from_z,
				side_x,
				side_y,
				side_z,
				up_x,
				up_y,
				up_z,
				max_side_extent,
				max_up_extent,
				1,
			)
			if !row_intersects {
				continue
			}
			when TERRAIN_GENERATION_PROFILE_PHASES {
				if terrain_generation_profile_edge_core_active {
					terrain_generation_profile_stats.edge_core_rows_capsule += 1
				}
			}
			noise_row_cache: TerrainValueNoise3RowCache
			noise_row_cache_ready := false
			use_carveable_row_mask := carveable_row_mask != nil
			row_carveable_bits: u64
			if use_carveable_row_mask {
				row_carveable_bits = carveable_row_mask^[z * CHUNK_BLOCK_LENGTH + y]
				if row_min_x > 0 {
					row_carveable_bits &~= (u64(1) << u32(row_min_x)) - 1
				}
				if row_max_x < CHUNK_BLOCK_LOCAL_MAX {
					row_carveable_bits &= (u64(1) << u32(row_max_x + 1)) - 1
				}
				if row_carveable_bits == 0 {
					continue
				}
			}
			for x := row_min_x; x <= row_max_x; x += 1 {
				if use_carveable_row_mask && (row_carveable_bits & (u64(1) << u32(x))) == 0 {
					continue
				}
				when TERRAIN_GENERATION_PROFILE_PHASES {
					if terrain_generation_profile_edge_core_active {
						terrain_generation_profile_stats.edge_core_voxel_candidates += 1
					}
				}
				if !terrain_density_local_block_can_carve(view, x, y, z) {
					if use_carveable_row_mask {
						terrain_density_carveable_row_mask_clear(carveable_row_mask, x, y, z)
					}
					continue
				}
				when TERRAIN_GENERATION_PROFILE_PHASES {
					if terrain_generation_profile_edge_core_active {
						terrain_generation_profile_stats.edge_core_carveable_candidates += 1
					}
				}
				world_x := f32(chunk_origin.x + x) + 0.5
				rel_from_x := world_x - from_x
				rel_from_y := world_y - from_y
				rel_from_z := world_z - from_z
				raw_t := (rel_from_x * dx + rel_from_y * dy + rel_from_z * dz) / length_sq
				if raw_t < raw_t_min || raw_t > raw_t_max {
					continue
				}
				t := math.clamp(raw_t, f32(0), f32(1))
				center_bulge := 1.0 - math.abs(t * 2.0 - 1.0)
				s_curve :=
					center_bulge *
					(curve_side * shape.curve_scale +
							branch_side * shape.meander_scale * (t * 2.0 - 1.0) * 0.42)
				u_curve :=
					center_bulge *
					(curve_lift * shape.curve_scale * 0.45 +
							branch_lift * shape.lift_scale * (t * 2.0 - 1.0) * 0.28)
				cx := from_x + dx * t + side_x * s_curve * radius + up_x * u_curve * radius
				cy := from_y + dy * t + side_y * s_curve * radius + up_y * u_curve * radius
				cz := from_z + dz * t + side_z * s_curve * radius + up_z * u_curve * radius
				rel_x := world_x - cx
				rel_y := world_y - cy
				rel_z := world_z - cz
				side_dist := rel_x * side_x + rel_y * side_y + rel_z * side_z
				up_dist := rel_x * up_x + rel_y * up_y + rel_z * up_z
				along_dist := rel_x * tangent_x + rel_y * tangent_y + rel_z * tangent_z
				neck_wave := terrain_density_cave_segment_triangle_wave(t * 2.35 + neck_phase)
				profile_scale := math.clamp(
					0.90 +
					center_bulge * 0.10 +
					(1.0 - center_bulge) * shape.radius_endpoint_scale +
					(1.0 - neck_wave) * shape.radius_swell_scale * 0.24 -
					neck_wave * shape.radius_neck_scale * 0.42,
					f32(0.58),
					f32(1.30),
				)
				base_radius := radius * profile_scale
				side_radius := math.max(f32(0.75), base_radius * horizontal_radius_scale)
				up_radius := math.max(f32(0.75), base_radius * shape.radius_y_scale)
				along_radius := math.max(f32(0.75), base_radius * 1.10)
				shape_value :=
					(side_dist * side_dist) / (side_radius * side_radius) +
					(up_dist * up_dist) / (up_radius * up_radius) +
					(along_dist * along_dist) / (along_radius * along_radius)
				if shape_value > 1.42 {
					continue
				}
				when TERRAIN_GENERATION_PROFILE_PHASES {
					if terrain_generation_profile_edge_core_active {
						terrain_generation_profile_stats.edge_core_shape_candidates += 1
					}
				}
				core_support := math.clamp((f32(1.0) - shape_value) * 1.389, f32(0), f32(1))
				rough_scale :=
					shape.radius_noise_scale *
					biomes.regional_terrain_field_lerp(f32(0.58), f32(0.22), core_support)
				negative_rough_profile_scale := math.clamp(
					1.0 + center_bulge * shape.radius_swell_scale * 0.18 - shape.radius_neck_scale,
					f32(0.72),
					f32(1.34),
				)
				wall_delta_lower_bound :=
					-shape.wall_scallop_scale * f32(0.48) -
					shape.wall_rib_scale -
					shape.wall_lip_relief_scale * f32(0.46)
				if shape_value <=
				   1.0 + wall_delta_lower_bound - rough_scale * negative_rough_profile_scale {
					when TERRAIN_GENERATION_PROFILE_PHASES {
						if terrain_generation_profile_edge_core_active {
							terrain_generation_profile_stats.edge_core_threshold_candidates += 1
						}
					}
					carved := false
					if row_full_vertical_support {
						carved =
							terrain_density_carve_checked_local_block_with_material_full_vertical_support(
								view,
								chunk_origin,
								columns,
								x,
								y,
								z,
								biome_id,
								directional_material_profile,
								wall_buffer,
							)
					} else {
						carved = terrain_density_carve_checked_local_block_with_material_result(
							view,
							key,
							chunk_origin,
							columns,
							x,
							y,
							z,
							biome_id,
							directional_material_profile,
							wall_buffer,
						)
					}
					if carved && use_carveable_row_mask {
						terrain_density_carveable_row_mask_clear(carveable_row_mask, x, y, z)
					}
					continue
				}
				side_unit := side_dist / side_radius
				up_unit := up_dist / up_radius
				side_abs := math.abs(side_unit)
				up_abs := math.abs(up_unit)
				cross_radial := math.sqrt_f32(side_unit * side_unit + up_unit * up_unit)
				wall_support :=
					math.smoothstep(f32(0.56), f32(1.02), cross_radial) *
					(1.0 - math.smoothstep(f32(1.20), f32(1.42), cross_radial))
				notch_band := math.clamp(
					1.0 - math.abs(side_abs - notch_band_center) * f32(4.0),
					f32(0),
					f32(1),
				)
				notch_vertical_support := 1.0 - math.smoothstep(f32(0.52), f32(1.04), up_abs)
				notch_wave := terrain_density_cave_segment_triangle_wave(
					t * notch_frequency + wall_phase + side_unit * 0.33,
				)
				notch_support :=
					notch_band *
					notch_vertical_support *
					math.smoothstep(f32(0.42), f32(0.86), notch_wave) *
					wall_support
				scallop_wave_a := terrain_density_cave_segment_triangle_wave(
					t * (4.20 + wall_phase * 1.60) +
					side_unit * 0.44 +
					up_unit * 0.21 +
					wall_phase_b,
				)
				scallop_wave_b := terrain_density_cave_segment_triangle_wave(
					t * (2.70 + wall_phase_b * 1.10) -
					side_unit * 0.31 +
					up_unit * 0.37 +
					wall_phase,
				)
				scallop_mix := scallop_wave_a * 0.62 + scallop_wave_b * 0.38
				rib_side_band := math.clamp(
					1.0 - math.abs(side_abs - f32(0.88)) * f32(3.5),
					f32(0),
					f32(1),
				)
				rib_ceiling_band := math.clamp(
					1.0 - math.abs(up_abs - f32(0.76)) * f32(4.0),
					f32(0),
					f32(1),
				)
				rib_wave := terrain_density_cave_segment_triangle_wave(
					t * rib_frequency + side_abs * 0.48 + wall_phase_b,
				)
				rib_support :=
					math.max(rib_side_band * 0.75, rib_ceiling_band) *
					math.smoothstep(f32(0.50), f32(0.92), rib_wave) *
					wall_support
				lip_band :=
					math.smoothstep(f32(0.76), f32(1.02), up_abs) *
					(1.0 - math.smoothstep(f32(1.15), f32(1.40), cross_radial)) *
					wall_support
				lip_wave := terrain_density_cave_segment_triangle_wave(
					t * (3.10 + wall_phase_b * 1.70) + up_unit * 0.53 + wall_phase,
				)
				lip_relief := shape.wall_lip_relief_scale * (lip_wave - 0.46) * lip_band
				threshold_without_noise :=
					1.0 +
					shape.wall_notch_scale * notch_support +
					shape.wall_scallop_scale * (scallop_mix - 0.48) * wall_support -
					shape.wall_rib_scale * rib_support +
					lip_relief
				if shape_value <=
				   threshold_without_noise - rough_scale * negative_rough_profile_scale {
					when TERRAIN_GENERATION_PROFILE_PHASES {
						if terrain_generation_profile_edge_core_active {
							terrain_generation_profile_stats.edge_core_threshold_candidates += 1
						}
					}
					carved := false
					if row_full_vertical_support {
						carved =
							terrain_density_carve_checked_local_block_with_material_full_vertical_support(
								view,
								chunk_origin,
								columns,
								x,
								y,
								z,
								biome_id,
								directional_material_profile,
								wall_buffer,
							)
					} else {
						carved = terrain_density_carve_checked_local_block_with_material_result(
							view,
							key,
							chunk_origin,
							columns,
							x,
							y,
							z,
							biome_id,
							directional_material_profile,
							wall_buffer,
						)
					}
					if carved && use_carveable_row_mask {
						terrain_density_carveable_row_mask_clear(carveable_row_mask, x, y, z)
					}
					continue
				}
				if shape_value >
				   threshold_without_noise + rough_scale * f32(1.34) + f32(0.000001) {
					continue
				}
				when TERRAIN_GENERATION_PROFILE_PHASES {
					if terrain_generation_profile_edge_core_active {
						terrain_generation_profile_stats.edge_core_noise_candidates += 1
					}
				}
				if !noise_row_cache_ready {
					noise_row_cache = terrain_value_noise3_row_cache_make(
						key,
						noise_salt,
						18,
						chunk_origin.y + y,
						chunk_origin.z + z,
					)
					noise_row_cache_ready = true
				}
				rough := terrain_value_noise3_row_cache_sample(
					&noise_row_cache,
					chunk_origin.x + x,
				)
				threshold :=
					threshold_without_noise +
					rough *
						rough_scale *
						terrain_density_cave_passage_radius_profile_scale(
							shape,
							rough,
							center_bulge,
						)
				if shape_value <= threshold {
					when TERRAIN_GENERATION_PROFILE_PHASES {
						if terrain_generation_profile_edge_core_active {
							terrain_generation_profile_stats.edge_core_threshold_candidates += 1
						}
					}
					carved := false
					if row_full_vertical_support {
						carved =
							terrain_density_carve_checked_local_block_with_material_full_vertical_support(
								view,
								chunk_origin,
								columns,
								x,
								y,
								z,
								biome_id,
								directional_material_profile,
								wall_buffer,
							)
					} else {
						carved = terrain_density_carve_checked_local_block_with_material_result(
							view,
							key,
							chunk_origin,
							columns,
							x,
							y,
							z,
							biome_id,
							directional_material_profile,
							wall_buffer,
						)
					}
					if carved && use_carveable_row_mask {
						terrain_density_carveable_row_mask_clear(carveable_row_mask, x, y, z)
					}
				}
			}
		}
	}
}

terrain_density_carve_checked_local_block_with_material :: proc(
	view: ^world_async.ChunkVoxelView,
	key: biomes.FeatureGridKey,
	chunk_origin: world_async.BlockCoord,
	columns: []TerrainBiomeColumn,
	local_x, local_y, local_z: i32,
	biome_id: biomes.BiomeID,
	directional_material_profile: bool = false,
	wall_buffer: ^TerrainCaveWallMaterialBuffer = nil,
) {
	_ = terrain_density_carve_checked_local_block_with_material_result(
		view,
		key,
		chunk_origin,
		columns,
		local_x,
		local_y,
		local_z,
		biome_id,
		directional_material_profile,
		wall_buffer,
	)
}

terrain_density_carve_checked_local_block_with_material_full_vertical_support :: proc(
	view: ^world_async.ChunkVoxelView,
	chunk_origin: world_async.BlockCoord,
	columns: []TerrainBiomeColumn,
	local_x, local_y, local_z: i32,
	biome_id: biomes.BiomeID,
	directional_material_profile: bool = false,
	wall_buffer: ^TerrainCaveWallMaterialBuffer = nil,
) -> bool {
	when TERRAIN_GENERATION_PROFILE_PHASES {
		terrain_generation_profile_stats.carve_attempts += 1
	}
	world_y := chunk_origin.y + local_y
	column := columns[local_x + local_z * CHUNK_BLOCK_LENGTH]
	if !terrain_density_surface_is_solid(column, world_y) {
		return false
	}

	index := chunk_block_index(u32(local_x), u32(local_y), u32(local_z))
	view.blocks.occupancy[index] = .Empty
	view.blocks.material_id[index] = world_async.BlockMaterialID(0)
	when TERRAIN_GENERATION_PROFILE_PHASES {
		terrain_generation_profile_stats.carve_successes += 1
	}
	terrain_density_mark_cave_wall_neighbors(
		view,
		local_x,
		local_y,
		local_z,
		biome_id,
		directional_material_profile,
		wall_buffer,
	)
	return true
}

terrain_density_local_block_can_carve :: proc(
	view: ^world_async.ChunkVoxelView,
	local_x, local_y, local_z: i32,
) -> bool {
	index := chunk_block_index(u32(local_x), u32(local_y), u32(local_z))
	if view.blocks.occupancy[index] != .Solid {
		return false
	}
	return terrain_material_palette_index(view.blocks.material_id[index]) != TERRAIN_WATER_MAT_ID
}

terrain_density_carveable_row_mask_build :: proc(
	mask: ^TerrainCarveableRowMask,
	view: ^world_async.ChunkVoxelView,
) {
	for z: i32 = 0; z < CHUNK_BLOCK_LENGTH; z += 1 {
		for y: i32 = 0; y < CHUNK_BLOCK_LENGTH; y += 1 {
			row_bits: u64
			for x: i32 = 0; x < CHUNK_BLOCK_LENGTH; x += 1 {
				if terrain_density_local_block_can_carve(view, x, y, z) {
					row_bits |= u64(1) << u32(x)
				}
			}
			mask[z * CHUNK_BLOCK_LENGTH + y] = row_bits
		}
	}
}

terrain_density_carveable_row_mask_clear :: proc(mask: ^TerrainCarveableRowMask, x, y, z: i32) {
	mask[z * CHUNK_BLOCK_LENGTH + y] &~= u64(1) << u32(x)
}

terrain_density_carve_checked_local_block_with_material_result :: proc(
	view: ^world_async.ChunkVoxelView,
	key: biomes.FeatureGridKey,
	chunk_origin: world_async.BlockCoord,
	columns: []TerrainBiomeColumn,
	local_x, local_y, local_z: i32,
	biome_id: biomes.BiomeID,
	directional_material_profile: bool = false,
	wall_buffer: ^TerrainCaveWallMaterialBuffer = nil,
) -> bool {
	when TERRAIN_GENERATION_PROFILE_PHASES {
		terrain_generation_profile_stats.carve_attempts += 1
	}
	world_y := chunk_origin.y + local_y
	vertical_support := terrain_density_cave_vertical_support(f32(world_y))
	if vertical_support <= 0 {
		return false
	}
	if vertical_support < 0.98 {
		edge_roll := biomes.regional_terrain_field_value_noise_3(
			key,
			chunk_origin.x + local_x,
			world_y,
			chunk_origin.z + local_z,
			9,
			TERRAIN_CAVE_VERTICAL_CUSHION_SALT,
		)
		if math.clamp(0.5 + edge_roll * 0.5, f32(0), f32(1)) > vertical_support {
			return false
		}
	}

	column := columns[local_x + local_z * CHUNK_BLOCK_LENGTH]
	if !terrain_density_surface_is_solid(column, world_y) {
		return false
	}

	index := chunk_block_index(u32(local_x), u32(local_y), u32(local_z))
	view.blocks.occupancy[index] = .Empty
	view.blocks.material_id[index] = world_async.BlockMaterialID(0)
	when TERRAIN_GENERATION_PROFILE_PHASES {
		terrain_generation_profile_stats.carve_successes += 1
	}
	terrain_density_mark_cave_wall_neighbors(
		view,
		local_x,
		local_y,
		local_z,
		biome_id,
		directional_material_profile,
		wall_buffer,
	)
	return true
}

terrain_density_fill_local_water_block :: proc(
	view: ^world_async.ChunkVoxelView,
	local_x, local_y, local_z: i32,
) {
	index := chunk_block_index(u32(local_x), u32(local_y), u32(local_z))
	if view.blocks.occupancy[index] != .Empty {
		return
	}
	view.blocks.occupancy[index] = .Solid
	view.blocks.material_id[index] = world_async.BlockMaterialID(TERRAIN_WATER_MAT_ID)
}

terrain_density_cave_vertical_support :: proc(world_y: f32) -> f32 {
	if world_y >= TERRAIN_CAVE_BOTTOM_CUSHION_END_BLOCKS &&
	   world_y <= TERRAIN_CAVE_TOP_CUSHION_START_BLOCKS {
		return 1
	}
	if world_y <= TERRAIN_CAVE_BOTTOM_CUSHION_START_BLOCKS ||
	   world_y >= TERRAIN_CAVE_TOP_CUSHION_END_BLOCKS {
		return 0
	}

	bottom_support := math.smoothstep(
		TERRAIN_CAVE_BOTTOM_CUSHION_START_BLOCKS,
		TERRAIN_CAVE_BOTTOM_CUSHION_END_BLOCKS,
		world_y,
	)
	top_support :=
		1.0 -
		math.smoothstep(
			TERRAIN_CAVE_TOP_CUSHION_START_BLOCKS,
			TERRAIN_CAVE_TOP_CUSHION_END_BLOCKS,
			world_y,
		)
	return math.clamp(bottom_support * top_support, f32(0), f32(1))
}
