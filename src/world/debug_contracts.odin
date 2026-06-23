package world

import world_async "async:world"
import "core:log"
import math "core:math"
import "core:mem"
import time "core:time"
import biomes "world:biomes"

//////////////////////////////////////
// Debug Methods
/////////////////////////////////////

when ODIN_DEBUG {

	DEBUG_TERRAIN_QUALITY_GRID_STEPS :: 17
	DEBUG_TERRAIN_QUALITY_GRID_STEP_BLOCKS :: 64
	DEBUG_TERRAIN_QUALITY_GRID_MIN_BLOCK :: -512

	debug_terrain_generation_quality_contract_checks_run :: proc(key: biomes.FeatureGridKey) {
		log.assert(
			CHUNK_STREAMING_RADIUS_Y_UP >= 1,
			"terrain streaming must include an upper layer so mountains are visible",
		)
		log.assert(
			CHUNK_STREAMING_RADIUS_Y_DOWN >= 2,
			"terrain streaming must include at least two lower layers for subterranean depth",
		)

		min_height := max(f32)
		max_height := -max(f32)
		same_biome_pairs: u32
		biome_pair_count: u32
		water_debug_columns: u32
		previous_row: [DEBUG_TERRAIN_QUALITY_GRID_STEPS]biomes.BiomeID

		for z_index := 0; z_index < DEBUG_TERRAIN_QUALITY_GRID_STEPS; z_index += 1 {
			prev_x_valid := false
			prev_x_biome := biomes.BiomeID.Temperate_Hills
			world_z := i32(
				DEBUG_TERRAIN_QUALITY_GRID_MIN_BLOCK +
				z_index * DEBUG_TERRAIN_QUALITY_GRID_STEP_BLOCKS,
			)

			for x_index := 0; x_index < DEBUG_TERRAIN_QUALITY_GRID_STEPS; x_index += 1 {
				world_x := i32(
					DEBUG_TERRAIN_QUALITY_GRID_MIN_BLOCK +
					x_index * DEBUG_TERRAIN_QUALITY_GRID_STEP_BLOCKS,
				)
				column := terrain_biome_column_sample_direct(key, world_x, world_z)

				min_height = math.min(min_height, column.surface_height_blocks)
				max_height = math.max(max_height, column.surface_height_blocks)

				if prev_x_valid {
					biome_pair_count += 1
					if prev_x_biome == column.dominant_biome_id {
						same_biome_pairs += 1
					}
				}
				if z_index > 0 {
					biome_pair_count += 1
					if previous_row[x_index] == column.dominant_biome_id {
						same_biome_pairs += 1
					}
				}
				previous_row[x_index] = column.dominant_biome_id
				prev_x_biome = column.dominant_biome_id
				prev_x_valid = true

				if column.hydrology_debug_material_active {
					water_debug_columns += 1
					log.assert(
						column.water_fill_active,
						"hydrology debug columns must correspond to actual local water fill",
					)
				}
			}
		}

		height_range := max_height - min_height
		same_biome_ratio := f32(same_biome_pairs) / f32(biome_pair_count)
		log.assertf(
			height_range >= 55,
			"surface terrain should have meaningful elevation range: min=%.2f max=%.2f range=%.2f",
			min_height,
			max_height,
			height_range,
		)
		log.assertf(
			max_height >= 78,
			"surface terrain should generate visible highland/mountain heights, max=%.2f",
			max_height,
		)
		log.assertf(
			same_biome_ratio >= 0.48,
			"surface biome field should have coherent neighboring samples, ratio=%.3f",
			same_biome_ratio,
		)
		log.assert(
			water_debug_columns > 0,
			"terrain quality sample should include local water-fill debug columns",
		)
		shore_eval := biomes.SurfaceBiomeProfileEvaluation {
			final_target = {shoreline_width_blocks = 18},
		}
		shore_material := terrain_surface_material_apply_shoreline(
			key,
			shore_eval,
			world_async.BlockMaterialID(TERRAIN_GRASS_MAT_ID),
			biomes.SEA_LEVEL_BLOCKS + 1,
			biomes.SEA_LEVEL_BLOCKS,
			11,
			23,
		)
		log.assert(
			shore_material == world_async.BlockMaterialID(TERRAIN_WET_MARSH_MAT_ID),
			"shoreline material rule should turn low beach surface to sand/wet material",
		)
		lower_middle_shore_material := terrain_surface_material_apply_shoreline(
			key,
			shore_eval,
			world_async.BlockMaterialID(TERRAIN_GRASS_MAT_ID),
			biomes.SEA_LEVEL_BLOCKS + 8,
			biomes.SEA_LEVEL_BLOCKS,
			11,
			23,
		)
		log.assert(
			lower_middle_shore_material == world_async.BlockMaterialID(TERRAIN_WET_MARSH_MAT_ID),
			"shoreline material dither should keep lower-middle beach surface sand/wet",
		)
		upland_material := terrain_surface_material_apply_shoreline(
			key,
			shore_eval,
			world_async.BlockMaterialID(TERRAIN_GRASS_MAT_ID),
			biomes.SEA_LEVEL_BLOCKS + 48,
			biomes.SEA_LEVEL_BLOCKS,
			11,
			23,
		)
		log.assert(
			upland_material == world_async.BlockMaterialID(TERRAIN_GRASS_MAT_ID),
			"shoreline material rule should leave upland grass material alone",
		)
		shore_cap_depth := terrain_surface_layer_depth_apply_shoreline(
			shore_eval,
			TERRAIN_GRASS_CAP_BLOCK_DEPTH,
			biomes.SEA_LEVEL_BLOCKS + 8,
			biomes.SEA_LEVEL_BLOCKS,
		)
		log.assert(
			shore_cap_depth == 1,
			"shoreline material layering should thin grass caps over middle beach sand",
		)
		shore_subsurface_material := terrain_subsurface_material_apply_shoreline(
			shore_eval,
			world_async.BlockMaterialID(TERRAIN_DIRT_MAT_ID),
			biomes.SEA_LEVEL_BLOCKS + 8,
			biomes.SEA_LEVEL_BLOCKS,
		)
		log.assert(
			shore_subsurface_material == world_async.BlockMaterialID(TERRAIN_WET_MARSH_MAT_ID),
			"shoreline material layering should expose sand/wet material under the beach cap",
		)
		upland_cap_depth := terrain_surface_layer_depth_apply_shoreline(
			shore_eval,
			TERRAIN_GRASS_CAP_BLOCK_DEPTH,
			biomes.SEA_LEVEL_BLOCKS + 48,
			biomes.SEA_LEVEL_BLOCKS,
		)
		upland_subsurface_material := terrain_subsurface_material_apply_shoreline(
			shore_eval,
			world_async.BlockMaterialID(TERRAIN_DIRT_MAT_ID),
			biomes.SEA_LEVEL_BLOCKS + 48,
			biomes.SEA_LEVEL_BLOCKS,
		)
		log.assert(
			upland_cap_depth == TERRAIN_GRASS_CAP_BLOCK_DEPTH &&
			upland_subsurface_material == world_async.BlockMaterialID(TERRAIN_DIRT_MAT_ID),
			"shoreline material layering should leave upland caps and subsurface material alone",
		)
		log.assert(
			terrain_surface_height_apply_vertical_cushion(200) <
			TERRAIN_SURFACE_HEIGHT_TOP_LIMIT_BLOCKS,
			"surface height top cushion should keep generated terrain below the hard top support",
		)
		log.assert(
			terrain_surface_height_apply_vertical_cushion(-220) >
			TERRAIN_SURFACE_HEIGHT_BOTTOM_LIMIT_BLOCKS,
			"surface height bottom cushion should keep generated terrain above the hard lower support",
		)

		material_blend_evaluation := biomes.SurfaceBiomeProfileEvaluation {
			cell_count = 2,
			transition_strength = 1,
			final_target = {biome_id = .Temperate_Hills},
		}
		material_blend_evaluation.targets[0] = {
			biome_id = .Temperate_Hills,
		}
		material_blend_evaluation.targets[1] = {
			biome_id = .Basalt_Spire_Highlands,
		}
		material_blend_evaluation.blend_weights[0] = 0.5
		material_blend_evaluation.blend_weights[1] = 0.5

		material_blend_grass_count: u32
		material_blend_stone_count: u32
		material_blend_isolated_count: u32
		for z := i32(0); z < 64; z += 1 {
			for x := i32(0); x < 64; x += 1 {
				biome_id := terrain_biome_material_biome_pick(key, material_blend_evaluation, x, z)
				if biome_id == .Temperate_Hills {
					material_blend_grass_count += 1
				} else if biome_id == .Basalt_Spire_Highlands {
					material_blend_stone_count += 1
				}
			}
		}
		for z := i32(1); z < 63; z += 1 {
			for x := i32(1); x < 63; x += 1 {
				center := terrain_biome_material_biome_pick(key, material_blend_evaluation, x, z)
				if center !=
					   terrain_biome_material_biome_pick(
						   key,
						   material_blend_evaluation,
						   x - 1,
						   z,
					   ) &&
				   center !=
					   terrain_biome_material_biome_pick(
						   key,
						   material_blend_evaluation,
						   x + 1,
						   z,
					   ) &&
				   center !=
					   terrain_biome_material_biome_pick(
						   key,
						   material_blend_evaluation,
						   x,
						   z - 1,
					   ) &&
				   center !=
					   terrain_biome_material_biome_pick(
						   key,
						   material_blend_evaluation,
						   x,
						   z + 1,
					   ) {
					material_blend_isolated_count += 1
				}
			}
		}
		log.assert(
			material_blend_grass_count > 0 && material_blend_stone_count > 0,
			"surface material blending should include both weighted biome materials",
		)
		log.assertf(
			material_blend_isolated_count == 0,
			"surface material blending should avoid isolated single-column material noise, got %d",
			material_blend_isolated_count,
		)

		tunnel_passage_shape := terrain_density_cave_passage_shape(.Tunnel)
		generic_segment_shape := terrain_density_cave_segment_shape_default()
		canyon_passage_shape := terrain_density_cave_passage_shape(.Canyon)
		fracture_passage_shape := terrain_density_cave_passage_shape(.Fracture)
		flooded_passage_shape := terrain_density_cave_passage_shape(.Flooded_Passage)
		worm_passage_shape := terrain_density_cave_passage_shape(.Worm_Path)
		collapsed_passage_shape := terrain_density_cave_passage_shape(.Collapsed_Corridor)
		fungal_worm_passage_shape := worm_passage_shape
		terrain_density_cave_passage_shape_apply_biome(&fungal_worm_passage_shape, .Fungal_Vaults)
		crystal_fracture_passage_shape := fracture_passage_shape
		terrain_density_cave_passage_shape_apply_biome(
			&crystal_fracture_passage_shape,
			.Crystal_Geode_Network,
		)
		log.assert(
			canyon_passage_shape.radius_x_scale > tunnel_passage_shape.radius_x_scale &&
			canyon_passage_shape.radius_y_scale > tunnel_passage_shape.radius_y_scale,
			"canyon cave passage profile should be broader than a tunnel",
		)
		log.assert(
			fracture_passage_shape.radius_x_scale < tunnel_passage_shape.radius_x_scale &&
			fracture_passage_shape.radius_y_scale > tunnel_passage_shape.radius_y_scale,
			"fracture cave passage profile should be narrow and tall",
		)
		log.assert(
			fracture_passage_shape.radius_neck_scale > tunnel_passage_shape.radius_neck_scale,
			"fracture cave passage profile should pinch more strongly than a tunnel",
		)
		log.assert(
			canyon_passage_shape.radius_swell_scale > tunnel_passage_shape.radius_swell_scale,
			"canyon cave passage profile should support wider local chambers",
		)
		log.assert(
			flooded_passage_shape.radius_y_scale < tunnel_passage_shape.radius_y_scale,
			"flooded cave passage profile should be vertically flattened",
		)
		log.assert(
			worm_passage_shape.meander_scale > tunnel_passage_shape.meander_scale &&
			worm_passage_shape.radius_z_scale > tunnel_passage_shape.radius_z_scale,
			"worm cave passage profile should be more sinuous than a tunnel",
		)
		log.assert(
			worm_passage_shape.curve_scale > tunnel_passage_shape.curve_scale &&
			tunnel_passage_shape.curve_scale > generic_segment_shape.curve_scale,
			"cave passage profiles should add coherent centerline curvature over generic segments",
		)
		log.assert(
			collapsed_passage_shape.radius_y_scale < tunnel_passage_shape.radius_y_scale &&
			collapsed_passage_shape.radius_neck_scale > tunnel_passage_shape.radius_neck_scale,
			"collapsed cave passage profile should be flatter and more pinched than a tunnel",
		)
		log.assert(
			tunnel_passage_shape.radius_neck_scale > generic_segment_shape.radius_neck_scale &&
			tunnel_passage_shape.meander_scale > generic_segment_shape.meander_scale,
			"ordinary tunnel cave passage profile should be more pinched and wandering than a generic segment",
		)
		log.assert(
			tunnel_passage_shape.radius_endpoint_scale >
				generic_segment_shape.radius_endpoint_scale &&
			fracture_passage_shape.radius_endpoint_scale >=
				tunnel_passage_shape.radius_endpoint_scale,
			"cave passage profiles should keep endpoint sockets wider than generic segments",
		)
		log.assert(
			worm_passage_shape.wall_scallop_scale > tunnel_passage_shape.wall_scallop_scale &&
			fungal_worm_passage_shape.wall_scallop_scale > worm_passage_shape.wall_scallop_scale,
			"fungal worm passages should preserve stronger organic wall scalloping",
		)
		log.assert(
			fracture_passage_shape.wall_rib_scale > tunnel_passage_shape.wall_rib_scale &&
			crystal_fracture_passage_shape.wall_rib_scale > fracture_passage_shape.wall_rib_scale,
			"crystal fracture passages should preserve stronger angular wall ribs",
		)
		log.assert(
			terrain_density_cave_passage_radius_profile_scale(tunnel_passage_shape, -1.0, 0.0) <
			terrain_density_cave_passage_radius_profile_scale(tunnel_passage_shape, 1.0, 0.0),
			"cave passage radius profile should create deterministic necks and swells",
		)
		log.assert(
			terrain_density_cave_edge_approach_radius_scale(.Worm_Path, 0.03) >
			terrain_density_cave_edge_approach_radius_scale(.Worm_Path, 0.50),
			"cave edge approach profile should widen near chamber endpoints",
		)
		log.assert(
			terrain_density_cave_edge_approach_radius_scale(.Fracture, 0.03) <
			terrain_density_cave_edge_approach_radius_scale(.Worm_Path, 0.03),
			"fracture approaches should stay narrower than worm passage approaches",
		)
		log.assert(
			math.abs(terrain_density_cave_edge_approach_radius_scale(.Canyon, 0.50) - 1.0) < 0.001,
			"cave edge approach widening should leave route middles under normal modulation",
		)
		wide_worm_edge := biomes.CaveNetworkEdge {
			id            = biomes.FeatureID(0x771),
			kind          = .Worm_Path,
			radius_blocks = TERRAIN_CAVE_EDGE_BRAID_RADIUS_THRESHOLD_BLOCKS + 1,
		}
		small_worm_edge := wide_worm_edge
		small_worm_edge.radius_blocks = TERRAIN_CAVE_EDGE_BRAID_RADIUS_THRESHOLD_BLOCKS - 1
		guaranteed_tunnel_edge := biomes.CaveNetworkEdge {
			id                    = biomes.FeatureID(0x772),
			kind                  = .Tunnel,
			radius_blocks         = 8,
			guaranteed_connection = true,
		}
		wide_fracture_edge := biomes.CaveNetworkEdge {
			id            = biomes.FeatureID(0x773),
			kind          = .Fracture,
			radius_blocks = TERRAIN_CAVE_EDGE_BRAID_RADIUS_THRESHOLD_BLOCKS + 5,
		}
		vertical_braid_edge := biomes.CaveNetworkEdge {
			id                    = biomes.FeatureID(0x774),
			kind                  = .Vertical_Shaft,
			radius_blocks         = TERRAIN_CAVE_EDGE_BRAID_RADIUS_THRESHOLD_BLOCKS + 5,
			guaranteed_connection = true,
		}
		log.assert(
			terrain_density_cave_edge_braid_enabled(wide_worm_edge) &&
			!terrain_density_cave_edge_braid_enabled(small_worm_edge) &&
			terrain_density_cave_edge_braid_enabled(guaranteed_tunnel_edge),
			"cave edge braids should target wide or guaranteed traversable routes",
		)
		log.assert(
			!terrain_density_cave_edge_braid_enabled(wide_fracture_edge) &&
			!terrain_density_cave_edge_braid_enabled(vertical_braid_edge),
			"cave edge braids should not inflate fracture or vertical shaft silhouettes",
		)
		route_bypass_edge := wide_worm_edge
		route_bypass_edge.radius_blocks =
			TERRAIN_CAVE_EDGE_ROUTE_BYPASS_MIN_ROUTE_RADIUS_BLOCKS + f32(2)
		route_bypass_seam_edge := route_bypass_edge
		route_bypass_seam_edge.regional_seam_connection = true
		log.assert(
			terrain_density_cave_edge_route_bypass_enabled(
				route_bypass_edge,
				TERRAIN_CAVE_EDGE_ROUTE_BYPASS_MIN_ROUTE_RADIUS_BLOCKS + f32(1),
				TERRAIN_CAVE_EDGE_ROUTE_BYPASS_MIN_ROUTE_LENGTH_BLOCKS + f32(1),
			) &&
			!terrain_density_cave_edge_route_bypass_enabled(
					route_bypass_edge,
					TERRAIN_CAVE_EDGE_ROUTE_BYPASS_MIN_ROUTE_RADIUS_BLOCKS - f32(1),
					TERRAIN_CAVE_EDGE_ROUTE_BYPASS_MIN_ROUTE_LENGTH_BLOCKS + f32(1),
				) &&
			!terrain_density_cave_edge_route_bypass_enabled(
					route_bypass_edge,
					TERRAIN_CAVE_EDGE_ROUTE_BYPASS_MIN_ROUTE_RADIUS_BLOCKS + f32(1),
					TERRAIN_CAVE_EDGE_ROUTE_BYPASS_MIN_ROUTE_LENGTH_BLOCKS - f32(1),
				),
			"route bypasses should target only broad long ordinary routes",
		)
		log.assert(
			!terrain_density_cave_edge_route_bypass_enabled(
				route_bypass_seam_edge,
				TERRAIN_CAVE_EDGE_ROUTE_BYPASS_MIN_ROUTE_RADIUS_BLOCKS + f32(1),
				TERRAIN_CAVE_EDGE_ROUTE_BYPASS_MIN_ROUTE_LENGTH_BLOCKS + f32(1),
			) &&
			!terrain_density_cave_edge_route_bypass_enabled(
					wide_fracture_edge,
					TERRAIN_CAVE_EDGE_ROUTE_BYPASS_MIN_ROUTE_RADIUS_BLOCKS + f32(1),
					TERRAIN_CAVE_EDGE_ROUTE_BYPASS_MIN_ROUTE_LENGTH_BLOCKS + f32(1),
				) &&
			!terrain_density_cave_edge_route_bypass_enabled(
					vertical_braid_edge,
					TERRAIN_CAVE_EDGE_ROUTE_BYPASS_MIN_ROUTE_RADIUS_BLOCKS + f32(1),
					TERRAIN_CAVE_EDGE_ROUTE_BYPASS_MIN_ROUTE_LENGTH_BLOCKS + f32(1),
				),
			"route bypasses should not duplicate seam, fracture, or vertical-route passes",
		)
		approach_vestibule_edge := guaranteed_tunnel_edge
		seam_approach_vestibule_edge := approach_vestibule_edge
		seam_approach_vestibule_edge.regional_seam_connection = true
		log.assert(
			terrain_density_cave_edge_approach_vestibules_enabled(
				approach_vestibule_edge,
				TERRAIN_CAVE_EDGE_APPROACH_VESTIBULE_MIN_ROUTE_RADIUS_BLOCKS + 1,
			) &&
			!terrain_density_cave_edge_approach_vestibules_enabled(
					approach_vestibule_edge,
					TERRAIN_CAVE_EDGE_APPROACH_VESTIBULE_MIN_ROUTE_RADIUS_BLOCKS - 1,
				) &&
			!terrain_density_cave_edge_approach_vestibules_enabled(
					seam_approach_vestibule_edge,
					TERRAIN_CAVE_EDGE_APPROACH_VESTIBULE_MIN_ROUTE_RADIUS_BLOCKS + 1,
				) &&
			!terrain_density_cave_edge_approach_vestibules_enabled(
					vertical_braid_edge,
					TERRAIN_CAVE_EDGE_APPROACH_VESTIBULE_MIN_ROUTE_RADIUS_BLOCKS + 1,
				),
			"cave approach vestibules should target wide guaranteed non-seam route endpoints",
		)
		ordinary_canyon_edge := biomes.CaveNetworkEdge {
			id   = biomes.FeatureID(0x881),
			kind = .Canyon,
		}
		seam_canyon_edge := ordinary_canyon_edge
		seam_canyon_edge.regional_seam_connection = true
		log.assert(
			terrain_density_cave_edge_radius_modulation(seam_canyon_edge, 0.30) >=
			terrain_density_cave_edge_radius_modulation(ordinary_canyon_edge, 0.30),
			"regional seam corridors should not be more necked than ordinary canyon passages",
		)
		log.assert(
			terrain_density_cave_edge_seam_radius_scale(seam_canyon_edge, 0.30) >
			terrain_density_cave_edge_seam_radius_scale(ordinary_canyon_edge, 0.30),
			"regional seam corridors should get extra interior route support",
		)
		seam_passage_shape := canyon_passage_shape
		terrain_density_cave_passage_shape_apply_regional_seam(&seam_passage_shape)
		log.assert(
			seam_passage_shape.radius_neck_scale < canyon_passage_shape.radius_neck_scale &&
			seam_passage_shape.radius_y_scale > canyon_passage_shape.radius_y_scale,
			"regional seam passage profile should be broader and less pinched than ordinary canyon",
		)
		log.assert(
			seam_passage_shape.wall_scallop_scale > canyon_passage_shape.wall_scallop_scale &&
			seam_passage_shape.wall_rib_scale > canyon_passage_shape.wall_rib_scale,
			"regional seam passage profile should add stronger wall relief than ordinary canyon",
		)
		log.assert(
			seam_passage_shape.wall_lip_relief_scale > canyon_passage_shape.wall_lip_relief_scale,
			"regional seam passage profile should perturb ceiling and floor lips",
		)
		log.assert(
			TERRAIN_CAVE_EDGE_SEAM_GALLERY_SIDE_OFFSET_SCALE <
				TERRAIN_CAVE_EDGE_ALCOVE_SIDE_OFFSET_SCALE &&
			TERRAIN_CAVE_EDGE_SEAM_GALLERY_VERTICAL_OFFSET_SCALE > 0.30,
			"regional seam galleries should stay route-adjacent while breaking vertical silhouettes",
		)
		log.assert(
			TERRAIN_CAVE_EDGE_SEAM_BAY_SIDE_OFFSET_SCALE <
				TERRAIN_CAVE_EDGE_SEAM_GALLERY_SIDE_OFFSET_SCALE &&
			TERRAIN_CAVE_EDGE_SEAM_BAY_THROAT_SCALE > TERRAIN_CAVE_EDGE_SEAM_GALLERY_THROAT_SCALE,
			"regional seam bays should overlap the route more strongly than side galleries",
		)
		log.assert(
			TERRAIN_CAVE_EDGE_SEAM_BYPASS_SIDE_OFFSET_SCALE >
				TERRAIN_CAVE_EDGE_SEAM_GALLERY_SIDE_OFFSET_SCALE &&
			TERRAIN_CAVE_EDGE_SEAM_BYPASS_SPAN_T_MIN > TERRAIN_CAVE_EDGE_SEAM_SHOULDER_SPAN_T &&
			TERRAIN_CAVE_EDGE_SEAM_BYPASS_THROAT_SCALE <
				TERRAIN_CAVE_EDGE_SEAM_GALLERY_THROAT_SCALE,
			"regional seam bypasses should be long connected macro arcs, not another local widening pass",
		)
		log.assert(
			TERRAIN_CAVE_EDGE_SEAM_CROSSCUT_SIDE_OFFSET_SCALE <
				TERRAIN_CAVE_EDGE_SEAM_BYPASS_SIDE_OFFSET_SCALE &&
			TERRAIN_CAVE_EDGE_SEAM_CROSSCUT_SIDE_OFFSET_SCALE >
				TERRAIN_CAVE_EDGE_SEAM_GALLERY_SIDE_OFFSET_SCALE &&
			TERRAIN_CAVE_EDGE_SEAM_CROSSCUT_SPAN_T > TERRAIN_CAVE_EDGE_SEAM_SHOULDER_SPAN_T &&
			TERRAIN_CAVE_EDGE_SEAM_CROSSCUT_NODE_SIDE_SCALE > 0.70 &&
			TERRAIN_CAVE_EDGE_SEAM_CROSSCUT_NODE_RADIUS_SCALE > 1.20,
			"regional seam crosscuts should break route-forward silhouettes without becoming distant bypasses",
		)
		log.assert(
			TERRAIN_CAVE_EDGE_SEAM_SHOULDER_SIDE_OFFSET_SCALE >
				TERRAIN_CAVE_EDGE_SEAM_BAY_SIDE_OFFSET_SCALE &&
			TERRAIN_CAVE_EDGE_SEAM_SHOULDER_SIDE_OFFSET_SCALE <
				TERRAIN_CAVE_EDGE_SEAM_GALLERY_SIDE_OFFSET_SCALE &&
			TERRAIN_CAVE_EDGE_SEAM_SHOULDER_THROAT_SCALE < TERRAIN_CAVE_EDGE_SEAM_BAY_THROAT_SCALE,
			"regional seam shoulders should stay between route-overlapping bays and farther side galleries",
		)
		log.assert(
			TERRAIN_CAVE_EDGE_SEAM_VERTICAL_RELIEF_OFFSET_SCALE >
				TERRAIN_CAVE_EDGE_SEAM_SHOULDER_VERTICAL_OFFSET_SCALE &&
			TERRAIN_CAVE_EDGE_SEAM_VERTICAL_RELIEF_SIDE_DRIFT_SCALE <
				TERRAIN_CAVE_EDGE_SEAM_BAY_SIDE_OFFSET_SCALE &&
			TERRAIN_CAVE_EDGE_SEAM_VERTICAL_RELIEF_THROAT_SCALE <
				TERRAIN_CAVE_EDGE_SEAM_BAY_THROAT_SCALE,
			"regional seam vertical relief should be route-attached vertical variation, not side galleries",
		)
		log.assert(
			TERRAIN_FUNGAL_ROOM_LOWER_XZ_SCALE > 1.0 &&
			TERRAIN_FUNGAL_ROOM_LOWER_Y_SCALE < TERRAIN_FUNGAL_ROOM_DOME_Y_SCALE,
			"fungal cave room profile should favor broad lower vaults with taller domes",
		)
		log.assert(
			TERRAIN_FUNGAL_ROOM_ALCOVE_OFFSET_SCALE > TERRAIN_FUNGAL_ROOM_ALCOVE_XZ_SCALE,
			"fungal cave room profile should push side alcoves away from the room center",
		)
		log.assert(
			TERRAIN_CRYSTAL_ROOM_MAIN_Y_SCALE > 1.0 && TERRAIN_CRYSTAL_ROOM_MAIN_XZ_SCALE < 0.85,
			"crystal cave room profile should favor tall narrow geode volumes",
		)
		log.assert(
			TERRAIN_CRYSTAL_ROOM_FISSURE_UPPER_Y_SCALE >
			TERRAIN_CRYSTAL_ROOM_FISSURE_LOWER_Y_SCALE,
			"crystal cave room fissure should rise through the geode room",
		)
		log.assert(
			TERRAIN_AQUIFER_ROOM_BASIN_XZ_SCALE > 1.0 &&
			TERRAIN_AQUIFER_ROOM_BASIN_Y_SCALE < TERRAIN_AQUIFER_ROOM_SHELF_Y_SCALE + 0.08,
			"aquifer cave room profile should favor a broad low flooded basin",
		)
		log.assert(
			TERRAIN_AQUIFER_ROOM_SHELF_OFFSET_SCALE > TERRAIN_AQUIFER_ROOM_SHELF_XZ_SCALE * 0.5,
			"aquifer cave room profile should offset the dry shelf away from the basin center",
		)
		log.assert(
			TERRAIN_AQUIFER_ROOM_MIRROR_SHELF_OFFSET_SCALE >
				TERRAIN_AQUIFER_ROOM_SHELF_OFFSET_SCALE &&
			TERRAIN_AQUIFER_ROOM_SIDE_SHELF_OFFSET_SCALE > TERRAIN_AQUIFER_ROOM_BASIN_XZ_SCALE &&
			TERRAIN_AQUIFER_ROOM_CRESCENT_SIDE_OFFSET_SCALE >
				TERRAIN_AQUIFER_ROOM_SHELF_OFFSET_SCALE &&
			TERRAIN_AQUIFER_ROOM_CRESCENT_SIDE_OFFSET_SCALE <
				TERRAIN_AQUIFER_ROOM_SIDE_SHELF_OFFSET_SCALE,
			"aquifer cave room profile should wrap side shelves around the flooded basin",
		)
		log.assert(
			TERRAIN_AQUIFER_ROOM_WATER_Y_OFFSET_SCALE <
				TERRAIN_AQUIFER_ROOM_BASIN_Y_OFFSET_SCALE &&
			TERRAIN_AQUIFER_ROOM_WATER_Y_SCALE < TERRAIN_AQUIFER_ROOM_BASIN_Y_SCALE,
			"aquifer cave room water profile should stay lower and shallower than the basin",
		)
		log.assert(
			terrain_density_cave_node_uses_profile_room(
				{role = .Pocket, kind = .Chamber, radius_blocks = 5, major_region = true},
			),
			"major cave nodes should always use biome-specific profile rooms",
		)
		log.assert(
			terrain_density_cave_node_uses_profile_room(
				{
					role = .Resource_Chamber,
					kind = .Geode_Chamber,
					radius_blocks = TERRAIN_CAVE_NODE_PROFILE_ROOM_MIN_RADIUS_BLOCKS,
				},
			),
			"medium resource chambers should use biome-specific profile rooms",
		)
		log.assert(
			terrain_density_cave_node_uses_profile_room(
				{
					role = .Water_Linked_Region,
					kind = .Underground_Lake,
					radius_blocks = TERRAIN_CAVE_NODE_PROFILE_ROOM_MIN_RADIUS_BLOCKS,
				},
			),
			"medium water-linked chambers should use biome-specific profile rooms",
		)
		log.assert(
			terrain_density_cave_node_uses_profile_room(
				{
					role = .Pocket,
					kind = .Chamber,
					radius_blocks = TERRAIN_CAVE_NODE_ISOLATED_CULL_RADIUS_BLOCKS,
				},
			),
			"large ordinary chambers should use profile rooms instead of plain ellipsoids",
		)
		log.assert(
			!terrain_density_cave_node_uses_profile_room(
				{
					role = .Pocket,
					kind = .Chamber,
					radius_blocks = TERRAIN_CAVE_NODE_PROFILE_ROOM_MIN_RADIUS_BLOCKS - 1,
				},
			),
			"small ordinary pockets should remain cheap or be culled by connectivity",
		)
		log.assert(
			terrain_density_cave_room_lobe_threshold_adjust(0.92, 0, 0, 1, 0) > 0,
			"cave room lobe profile should expand at least one deterministic side",
		)
		log.assert(
			terrain_density_cave_room_lobe_threshold_adjust(0, 0, 0.92, 1, 0) < 0,
			"cave room lobe profile should notch the perpendicular room edge",
		)
		log.assert(
			math.abs(terrain_density_cave_room_lobe_threshold_adjust(0, 0, 0, 1, 0)) < 0.001,
			"cave room lobe profile should leave the core room connection intact",
		)
		log.assert(
			math.abs(
				terrain_density_cave_room_strata_threshold_adjust(
					0,
					0,
					0,
					0,
					0.8,
					0.8,
					.Fungal_Vaults,
				),
			) <
			0.001,
			"cave room strata profile should leave the connected core open",
		)
		log.assert(
			terrain_density_cave_room_strata_threshold_adjust(
				-0.62,
				0.54,
				0,
				0.44,
				0.62,
				0.08,
				.Fungal_Vaults,
			) <
			0,
			"fungal cave room strata should preserve uneven lower floor mounds",
		)
		log.assert(
			terrain_density_cave_room_strata_threshold_adjust(
				0.72,
				0.18,
				0,
				0.10,
				-0.30,
				0.82,
				.Crystal_Geode_Network,
			) >
			0,
			"crystal cave room strata should carve stronger upper chimney pockets",
		)
		log.assert(
			terrain_density_cave_room_compound_shape(0, 0, 0, .Fungal_Vaults) < 0.01,
			"compound cave room profile should leave the connected core open",
		)
		log.assert(
			terrain_density_cave_room_smooth_min(
				0.82,
				0.86,
				TERRAIN_CAVE_ROOM_COMPOUND_BLEND_RADIUS,
			) <
			0.82,
			"compound cave room smooth union should open inter-lobe transition space",
		)
		log.assert(
			math.abs(
				terrain_density_cave_room_smooth_min(
					0.30,
					0.70,
					TERRAIN_CAVE_ROOM_COMPOUND_BLEND_RADIUS,
				) -
				0.30,
			) <
			0.001,
			"compound cave room smooth union should leave clearly dominant lobes unchanged",
		)
		log.assert(
			terrain_density_cave_room_segment_shape(
				0.50,
				0,
				0,
				0,
				0,
				0,
				1,
				0,
				0,
				0.20,
				0.20,
				0.20,
			) <
			0.01,
			"cave room segment shape should keep its corridor centerline open",
		)
		log.assert(
			terrain_density_cave_room_segment_shape(
				0.50,
				0.36,
				0,
				0,
				0,
				0,
				1,
				0,
				0,
				0.20,
				0.20,
				0.20,
			) >
			1.0,
			"cave room segment shape should stay bounded around the connecting throat",
		)
		log.assert(
			terrain_density_cave_major_room_perimeter_shape(0, 0, 0, .Fungal_Vaults) > 1.0,
			"major room perimeter field should not reopen the protected room core",
		)
		log.assert(
			terrain_density_cave_major_room_perimeter_shape(
				TERRAIN_CAVE_NODE_MAJOR_ROOM_FIELD_SIDE_CENTER_SCALE,
				-0.04,
				TERRAIN_CAVE_NODE_MAJOR_ROOM_FIELD_SIDE_ACROSS_SCALE,
				.Fungal_Vaults,
			) <
			0.10,
			"fungal major room perimeter field should include broad attached side halls",
		)
		log.assert(
			terrain_density_cave_major_room_perimeter_shape(
				TERRAIN_CAVE_NODE_MAJOR_ROOM_FIELD_SIDE_CENTER_SCALE * f32(0.22),
				0.74,
				-TERRAIN_CAVE_NODE_MAJOR_ROOM_FIELD_SIDE_ACROSS_SCALE * f32(0.24),
				.Crystal_Geode_Network,
			) <
			0.10,
			"crystal major room perimeter field should include upper geode chimneys",
		)
		log.assert(
			terrain_density_cave_major_room_perimeter_shape(
				-TERRAIN_CAVE_NODE_MAJOR_ROOM_FIELD_SIDE_CENTER_SCALE * f32(0.18),
				-0.44,
				TERRAIN_CAVE_NODE_MAJOR_ROOM_FIELD_SIDE_ACROSS_SCALE * f32(0.54),
				.Buried_Aquifer_Caves,
			) <
			0.10,
			"aquifer major room perimeter field should include low dry shelf halls",
		)
		log.assert(
			TERRAIN_CAVE_NODE_MACRO_SATELLITE_APRON_RADIUS_SCALE >
				TERRAIN_CAVE_NODE_MACRO_SATELLITE_THROAT_SCALE &&
			TERRAIN_CAVE_NODE_MACRO_SATELLITE_APRON_INNER_SCALE <
				TERRAIN_CAVE_NODE_MACRO_SATELLITE_OFFSET_SCALE &&
			TERRAIN_CAVE_NODE_MACRO_SATELLITE_APRON_BLEND_RADIUS <
				TERRAIN_CAVE_NODE_MACRO_SATELLITE_APRON_RADIUS_SCALE,
			"major room satellite aprons should be broad blended fields, not just thin throat tunnels",
		)
		log.assert(
			terrain_density_cave_room_compound_shape(0.42, -0.10, -0.20, .Fungal_Vaults) < 0.12,
			"fungal compound cave rooms should include broad off-center organic lobes",
		)
		log.assert(
			terrain_density_cave_room_compound_shape(0.42, 0.08, -0.20, .Crystal_Geode_Network) <
			0.12,
			"crystal compound cave rooms should include narrow vertical geode lobes",
		)
		log.assert(
			terrain_density_cave_room_compound_shape(0.30, -0.20, -0.26, .Buried_Aquifer_Caves) <
			0.12,
			"aquifer compound cave rooms should include low shelf-like lobes",
		)
		log.assert(
			terrain_density_cave_room_compound_shape(0.58, -0.06, 0.54, .Fungal_Vaults) < 0.12,
			"fungal compound cave rooms should include diagonal side galleries",
		)
		log.assert(
			terrain_density_cave_room_compound_shape(0.58, 0.12, 0.54, .Crystal_Geode_Network) <
			0.12,
			"crystal compound cave rooms should include tall diagonal side galleries",
		)
		log.assert(
			terrain_density_cave_room_compound_shape(-0.58, -0.18, -0.50, .Buried_Aquifer_Caves) <
			0.12,
			"aquifer compound cave rooms should include low rear alcove shelves",
		)
		log.assert(
			terrain_density_cave_room_compound_shape(0, 0, 0.90, .Crystal_Geode_Network) > 0.90,
			"compound cave room profile should pinch generic side rims instead of inflating one ellipsoid",
		)
		log.assert(
			!terrain_density_cave_room_internal_structure_preserves(
				0,
				0,
				0,
				8,
				8,
				8,
				1,
				0,
				1,
				.Fungal_Vaults,
			),
			"cave room internal structure should leave the connected core open",
		)
		log.assert(
			terrain_density_cave_room_internal_structure_preserves(
				0,
				0,
				0.42,
				8,
				8,
				8,
				1,
				0,
				1,
				.Fungal_Vaults,
			),
			"fungal cave rooms should preserve off-center root-like internal columns",
		)
		log.assert(
			terrain_density_cave_room_internal_structure_preserves(
				0.28,
				0,
				0.07,
				8,
				8,
				8,
				1,
				0,
				1,
				.Fungal_Vaults,
			),
			"fungal cave rooms should preserve inner root curtains outside the connected core",
		)
		log.assert(
			terrain_density_cave_room_internal_structure_preserves(
				0,
				0,
				0.32,
				8,
				8,
				8,
				1,
				0,
				1,
				.Crystal_Geode_Network,
			),
			"crystal cave rooms should preserve narrow off-center blade-like structure",
		)
		log.assert(
			terrain_density_cave_room_internal_structure_preserves(
				0.30,
				0,
				0.12,
				8,
				8,
				8,
				1,
				0,
				1,
				.Crystal_Geode_Network,
			),
			"crystal cave rooms should preserve inner geode splinter structure",
		)
		log.assert(
			terrain_density_cave_room_internal_structure_preserves(
				0,
				-0.45,
				0.32,
				8,
				8,
				8,
				1,
				0,
				1,
				.Buried_Aquifer_Caves,
			),
			"aquifer cave rooms should preserve low island-like structure",
		)
		portal_major_node := biomes.CaveNetworkNode {
			kind          = .Biome_Hub,
			radius_blocks = 16,
			major_region  = true,
		}
		portal_minor_node := portal_major_node
		portal_minor_node.major_region = false
		portal_vertical_node := portal_major_node
		portal_vertical_node.kind = .Vertical_Shaft
		log.assert(
			terrain_density_cave_node_edge_portals_enabled(portal_major_node) &&
			!terrain_density_cave_node_edge_portals_enabled(portal_minor_node) &&
			!terrain_density_cave_node_edge_portals_enabled(portal_vertical_node),
			"cave node edge portals should target major non-vertical profile rooms",
		)
		log.assert(
			terrain_density_cave_mouth_lower_width_scale(0.0, 1.0) >
			terrain_density_cave_mouth_lower_width_scale(1.0, 1.0),
			"cave mouth profile should keep the surface opening wider than the back throat",
		)
		log.assert(
			terrain_density_cave_mouth_lower_width_scale(0.0, 1.0) >= 1.25,
			"cave mouth profile should keep a broad lower surface arch",
		)
		log.assert(
			terrain_density_cave_mouth_side_shoulder_penalty(0.0, 0.9, 1.0) >
			terrain_density_cave_mouth_side_shoulder_penalty(0.0, 0.1, 1.0),
			"cave mouth profile should leave stronger upper side shoulders than the center",
		)
		log.assert(
			terrain_density_cave_mouth_side_shoulder_penalty(0.0, 0.36, 1.0) > 0,
			"cave mouth profile should start preserving upper side shoulders before the far edge",
		)
		log.assert(
			terrain_density_cave_mouth_lower_center_relief(0.0, 0.1, 1.0) >
			terrain_density_cave_mouth_lower_center_relief(0.0, 0.9, 1.0),
			"cave mouth profile should open the lower center more than side edges",
		)
		log.assert(
			terrain_density_cave_mouth_lower_center_relief(0.0, 0.1, 1.0) > 0.10,
			"cave mouth profile should cut a stronger lower-center opening",
		)
		log.assert(
			terrain_density_cave_mouth_lower_jaw_relief(0.0, 0.52, 1.0) >
			terrain_density_cave_mouth_lower_jaw_relief(0.0, 0.05, 1.0),
			"cave mouth profile should carve lower side jaw pockets away from the center",
		)
		log.assert(
			terrain_density_cave_mouth_lower_jaw_relief(1.0, 0.52, 1.0) <
			terrain_density_cave_mouth_lower_jaw_relief(0.0, 0.52, 1.0),
			"cave mouth lower jaw relief should fade into the back throat",
		)
		log.assert(
			terrain_density_cave_mouth_side_alcove_relief(0.42, 0.72, 1.0, 1.0) >
			terrain_density_cave_mouth_side_alcove_relief(0.42, 0.10, 1.0, 1.0),
			"cave mouth side alcove relief should target off-center side pockets",
		)
		log.assert(
			terrain_density_cave_mouth_side_alcove_relief(0.95, 0.72, 1.0, 1.0) <
			terrain_density_cave_mouth_side_alcove_relief(0.42, 0.72, 1.0, 1.0),
			"cave mouth side alcove relief should fade before the back throat",
		)
		log.assert(
			terrain_density_cave_mouth_side_alcove_relief(0.42, 0.72, 1.0, 0.0) <
			terrain_density_cave_mouth_side_alcove_relief(0.42, 0.72, 1.0, 1.0),
			"small cave mouths should keep side alcove relief smaller than large mouths",
		)
		log.assert(
			terrain_density_cave_mouth_upper_lip_rib(0.0, 0.05, 1.0) >
			terrain_density_cave_mouth_upper_lip_rib(0.0, 0.9, 1.0),
			"cave mouth profile should preserve a small upper-center lip",
		)
		log.assert(
			terrain_density_sinkhole_major_radius_scale(0.0) >
			terrain_density_sinkhole_minor_radius_scale(0.0),
			"sinkhole throat profile should start as an asymmetric oval at the surface",
		)
		log.assert(
			terrain_density_sinkhole_minor_radius_scale(1.0) >
			terrain_density_sinkhole_major_radius_scale(1.0),
			"sinkhole throat profile should twist toward a narrower lower connector",
		)
		log.assert(
			terrain_density_sinkhole_side_ledge_relief(0.0, 0.56) >
			terrain_density_sinkhole_side_ledge_relief(0.0, 0.05),
			"sinkhole throat profile should carve upper side ledges away from the center",
		)
		log.assert(
			terrain_density_sinkhole_side_ledge_relief(1.0, 0.56) <
			terrain_density_sinkhole_side_ledge_relief(0.0, 0.56),
			"sinkhole side ledge relief should fade with depth",
		)
		log.assert(
			terrain_density_sinkhole_rim_lip_penalty(0.0, 0.05, 0.05) >
			terrain_density_sinkhole_rim_lip_penalty(0.0, 0.9, 0.9),
			"sinkhole throat profile should preserve a small upper-center rim lip",
		)
		mouth_entrance_shape := terrain_density_cave_entrance_link_shape(.Cave_Mouth, true)
		mouth_deep_shape := terrain_density_cave_entrance_link_shape(.Cave_Mouth, false)
		sinkhole_entrance_shape := terrain_density_cave_entrance_link_shape(.Sinkhole, true)
		log.assert(
			mouth_entrance_shape.radius_y_scale < tunnel_passage_shape.radius_y_scale &&
			mouth_entrance_shape.radius_neck_scale > tunnel_passage_shape.radius_neck_scale,
			"cave mouth entrance link should flatten and pinch before joining the graph",
		)
		log.assert(
			mouth_deep_shape.curve_scale > tunnel_passage_shape.curve_scale,
			"deep cave mouth link should keep coherent curvature into the graph",
		)
		log.assert(
			terrain_density_cave_mouth_reach_blocks(6) <
			terrain_density_cave_mouth_reach_blocks(12),
			"small cave mouths should have shorter surface carving reach than large mouths",
		)
		log.assert(
			terrain_density_cave_mouth_near_link_radius(6, 3) < 3,
			"small cave mouths should keep the near-surface connector narrower than the graph link",
		)
		log.assert(
			terrain_density_cave_mouth_transition_drop_blocks(12, 120) /
				terrain_density_cave_mouth_transition_run_blocks(12) <
			0.8,
			"cave mouth transition should slope before dropping into the deep graph",
		)
		small_mouth_anchor := biomes.CaveAnchor {
			id = 1,
		}
		log.assert(
			terrain_density_cave_mouth_transition_style(small_mouth_anchor, 6) != .Spiral_Ramp,
			"small cave mouths should not choose the semi-chamber spiral ramp profile",
		)
		log.assert(
			sinkhole_entrance_shape.radius_y_scale > mouth_entrance_shape.radius_y_scale &&
			sinkhole_entrance_shape.radius_x_scale < tunnel_passage_shape.radius_x_scale,
			"sinkhole entrance link should remain vertical and narrower than ordinary tunnels",
		)
		cave_field_path_shape := terrain_density_cave_field_path_shape()
		log.assert(
			cave_field_path_shape.radius_y_scale < tunnel_passage_shape.radius_y_scale &&
			cave_field_path_shape.radius_x_scale < tunnel_passage_shape.radius_x_scale,
			"stochastic cave-field paths should use a narrow flattened profile",
		)
		log.assert(
			TERRAIN_CAVE_FIELD_PATH_SEGMENT_HALF_LENGTH_SCALE >
			TERRAIN_CAVE_FIELD_PATH_SEGMENT_RADIUS_SCALE,
			"stochastic cave-field path segments should be longer than they are wide",
		)
		path_direction_field_sample := TerrainCaveFieldSample {
			path_axis_x = false,
		}
		path_direction_network_sample := TerrainCaveFieldNetworkSample {
			found       = true,
			route_dir_x = 0.6,
			route_dir_y = 0.4,
			route_dir_z = 0.8,
		}
		path_dir_x, path_dir_y, path_dir_z, path_route_follow :=
			terrain_density_cave_field_path_direction(
				path_direction_field_sample,
				path_direction_network_sample,
			)
		path_horizontal_len := math.sqrt_f32(path_dir_x * path_dir_x + path_dir_z * path_dir_z)
		log.assert(
			path_route_follow &&
			math.abs(path_horizontal_len - 1.0) < 0.001 &&
			path_dir_y > 0 &&
			path_dir_y <= TERRAIN_CAVE_FIELD_PATH_ROUTE_VERTICAL_SCALE,
			"stochastic cave-field path segments should follow nearby route tangents with bounded pitch",
		)
		fallback_dir_x, fallback_dir_y, fallback_dir_z, fallback_route_follow :=
			terrain_density_cave_field_path_direction(path_direction_field_sample, {})
		log.assert(
			!fallback_route_follow &&
			fallback_dir_x == 0 &&
			fallback_dir_y == 0 &&
			fallback_dir_z == 1,
			"stochastic cave-field path direction should retain deterministic axis fallback",
		)
		route_pocket_field_sample := TerrainCaveFieldSample {
				chamber_open_strength = TERRAIN_CAVE_FIELD_OPEN_STRENGTH_MIN + 0.08,
				path_open_strength    = 0.08,
			}
		route_pocket_network_sample := TerrainCaveFieldNetworkSample {
				connected    = true,
				distance     = 10,
				route_radius = 4,
			}
		log.assert(
			!terrain_density_cave_field_sample_prefers_route_path(
				route_pocket_field_sample,
				1.0,
				route_pocket_network_sample,
			),
			"route-adjacent chamber samples should not be promoted into path segments",
		)
		log.assert(
			terrain_density_cave_field_sample_prefers_route_pocket(
				route_pocket_field_sample,
				1.0,
				route_pocket_network_sample,
			),
			"route-adjacent chamber samples should become connected cave-field side pockets",
		)
		route_pocket_network_sample.connected = false
		log.assert(
			!terrain_density_cave_field_sample_prefers_route_pocket(
				route_pocket_field_sample,
				1.0,
				route_pocket_network_sample,
			),
			"route-pocket cave-field samples should require actual network connectivity",
		)
		log.assert(
			terrain_density_cave_field_route_pocket_compound_shape(0, 0, 0, 0, .Fungal_Vaults) <
			0.01,
			"route-pocket compound field should leave the connected core open",
		)
		log.assert(
			terrain_density_cave_field_route_pocket_compound_shape(
				TERRAIN_CAVE_FIELD_ROUTE_POCKET_FIELD_SIDE_OFFSET_SCALE,
				0,
				TERRAIN_CAVE_FIELD_ROUTE_POCKET_FIELD_OUTWARD_OFFSET_SCALE * 0.18,
				0,
				.Fungal_Vaults,
			) <
			0.12,
			"fungal route-pocket compound field should add side alcove volume",
		)
		log.assert(
			terrain_density_cave_field_route_pocket_compound_shape(
				0,
				0,
				TERRAIN_CAVE_FIELD_ROUTE_POCKET_FIELD_OUTWARD_OFFSET_SCALE,
				0,
				.Buried_Aquifer_Caves,
			) <
			0.12,
			"route-pocket compound field should add an outward chamber lobe",
		)
		log.assert(
			terrain_density_cave_field_route_pocket_compound_shape(
				TERRAIN_CAVE_FIELD_ROUTE_POCKET_FIELD_SIDE_OFFSET_SCALE +
				TERRAIN_CAVE_FIELD_ROUTE_POCKET_FIELD_BRANCH_OFFSET_SCALE * f32(0.38),
				0,
				TERRAIN_CAVE_FIELD_ROUTE_POCKET_FIELD_OUTWARD_OFFSET_SCALE +
				TERRAIN_CAVE_FIELD_ROUTE_POCKET_FIELD_BRANCH_AWAY_SCALE * f32(0.34),
				0,
				.Fungal_Vaults,
			) <
			0.12,
			"route-pocket compound field should add a diagonal side branch lobe",
		)
		log.assert(
			terrain_density_cave_field_route_pocket_compound_shape(
				0,
				0,
				1.08,
				0,
				.Crystal_Geode_Network,
			) >
			0.90,
			"route-pocket compound field should not inflate every far rim",
		)
		shallow_warp_x, shallow_warp_y, shallow_warp_z :=
			terrain_density_cave_field_domain_warp_sample_coord(key, 73, -48, -41, 0)
		log.assert(
			shallow_warp_x == 73 && shallow_warp_y == -48 && shallow_warp_z == -41,
			"near-surface cave-field samples should not domain-warp before depth support",
		)
		deep_warp_a_x, deep_warp_a_y, deep_warp_a_z :=
			terrain_density_cave_field_domain_warp_sample_coord(key, 73, -72, -41, 1)
		deep_warp_b_x, deep_warp_b_y, deep_warp_b_z :=
			terrain_density_cave_field_domain_warp_sample_coord(key, -118, -96, 84, 1)
		cave_field_domain_warp_moved :=
			math.abs(f32(deep_warp_a_x - 73)) +
					math.abs(f32(deep_warp_a_y + 72)) +
					math.abs(f32(deep_warp_a_z + 41)) >=
				2 ||
			math.abs(f32(deep_warp_b_x + 118)) +
					math.abs(f32(deep_warp_b_y + 96)) +
					math.abs(f32(deep_warp_b_z - 84)) >=
				2
		log.assert(
			cave_field_domain_warp_moved,
			"deep cave-field samples should use domain-warped coordinates",
		)
		cave_field_candidates: u32
		cave_field_path_candidates: u32
		cave_field_chamber_candidates: u32
		for sample_z := i32(-128); sample_z <= 128; sample_z += 16 {
			for sample_y := i32(-112); sample_y <= -32; sample_y += 16 {
				for sample_x := i32(-128); sample_x <= 128; sample_x += 16 {
					sample_column := terrain_biome_column_sample_direct(key, sample_x, sample_z)
					depth_below_surface := sample_column.surface_height_blocks - f32(sample_y)
					field_sample := terrain_density_subterranean_cave_field_sample(
						key,
						sample_x,
						sample_y,
						sample_z,
						depth_below_surface,
					)
					if terrain_density_cave_field_sample_is_candidate(
						field_sample,
						terrain_density_cave_vertical_support(f32(sample_y)),
					) {
						cave_field_candidates += 1
						if terrain_density_cave_field_sample_prefers_path(
							field_sample,
							terrain_density_cave_vertical_support(f32(sample_y)),
						) {
							cave_field_path_candidates += 1
						} else {
							cave_field_chamber_candidates += 1
						}
					}
				}
			}
		}
		log.assert(
			cave_field_candidates > 0,
			"subterranean cave field should produce narrow/cavern candidate samples",
		)
		log.assert(
			cave_field_path_candidates > 0 && cave_field_chamber_candidates > 0,
			"subterranean cave field should produce both path and chamber shaped candidates",
		)

		cave_connectivity_route_edge := biomes.CaveNetworkEdge {
			id            = biomes.FeatureID(0x701),
			kind          = .Canyon,
			from_node_id  = biomes.FeatureID(0x702),
			to_node_id    = biomes.FeatureID(0x703),
			from_biome_id = .Fungal_Vaults,
			to_biome_id   = .Fungal_Vaults,
			from_x        = 48,
			from_y        = -80,
			from_z        = 0,
			bend_x        = 72,
			bend_y        = -76,
			bend_z        = 12,
			to_x          = 96,
			to_y          = -80,
			to_z          = 0,
			radius_blocks = 6,
		}
		cave_connectivity_small_node := biomes.CaveNetworkNode {
			id                       = biomes.FeatureID(0x711),
			kind                     = .Chamber,
			role                     = .Pocket,
			biome_id                 = .Fungal_Vaults,
			x                        = 0,
			y                        = -80,
			z                        = 0,
			radius_blocks            = 6,
			connection_radius_blocks = 3,
		}
		cave_connectivity_small_region := biomes.GenerationRegion {
			key = key,
		}
		cave_connectivity_small_region.cave_network_node_count = 1
		cave_connectivity_small_region.cave_network_nodes[0] = cave_connectivity_small_node
		cave_connectivity_small := terrain_density_cave_node_connectivity(
			&cave_connectivity_small_region,
			cave_connectivity_small_node,
		)
		log.assert(
			!cave_connectivity_small.should_carve,
			"small isolated cave network pockets should be culled before voxel carving",
		)

		cave_connectivity_large_node := biomes.CaveNetworkNode {
			id                       = biomes.FeatureID(0x721),
			kind                     = .Biome_Hub,
			role                     = .Major_Region,
			biome_id                 = .Fungal_Vaults,
			x                        = 0,
			y                        = -80,
			z                        = 0,
			radius_blocks            = 24,
			connection_radius_blocks = 8,
			major_region             = true,
		}
		cave_connectivity_large_region := biomes.GenerationRegion {
			key = key,
		}
		cave_connectivity_large_region.cave_network_node_count = 1
		cave_connectivity_large_region.cave_network_nodes[0] = cave_connectivity_large_node
		cave_connectivity_large := terrain_density_cave_node_connectivity(
			&cave_connectivity_large_region,
			cave_connectivity_large_node,
		)
		log.assert(
			!cave_connectivity_large.should_carve,
			"large cave network chambers without an edge or bridge route should not carve isolated rooms",
		)

		cave_connectivity_large_region.cave_network_edge_count = 1
		cave_connectivity_large_region.cave_network_edges[0] = cave_connectivity_route_edge
		cave_connectivity_large = terrain_density_cave_node_connectivity(
			&cave_connectivity_large_region,
			cave_connectivity_large_node,
		)
		log.assert(
			cave_connectivity_large.should_carve && cave_connectivity_large.should_bridge,
			"large cave network chambers near a route should bridge into the network",
		)

		cave_connectivity_anchor_node := biomes.CaveNetworkNode {
			id                       = biomes.FeatureID(0x731),
			kind                     = .Entrance,
			role                     = .Pocket,
			biome_id                 = .Buried_Aquifer_Caves,
			x                        = 0,
			y                        = -80,
			z                        = 0,
			radius_blocks            = 8,
			connection_radius_blocks = 4,
		}
		cave_connectivity_anchor := biomes.CaveAnchor {
			id                      = biomes.FeatureID(0x732),
			feature_id              = cave_connectivity_anchor_node.id,
			target_feature_id       = cave_connectivity_anchor_node.id,
			kind                    = .Cave_Mouth,
			x                       = 0,
			y                       = 64,
			z                       = 0,
			influence_radius_blocks = 8,
			guaranteed_connection   = true,
		}
		cave_connectivity_anchor_region := biomes.GenerationRegion {
			key = key,
		}
		cave_connectivity_anchor_region.cave_network_node_count = 1
		cave_connectivity_anchor_region.cave_network_nodes[0] = cave_connectivity_anchor_node
		cave_connectivity_anchor_region.cave_anchor_count = 1
		cave_connectivity_anchor_region.cave_anchors[0] = cave_connectivity_anchor
		cave_connectivity_anchor_sample := terrain_density_cave_node_connectivity(
			&cave_connectivity_anchor_region,
			cave_connectivity_anchor_node,
		)
		log.assert(
			cave_connectivity_anchor_sample.has_anchor &&
			!cave_connectivity_anchor_sample.should_carve,
			"anchored cave mouths without an edge or bridge route should not become dead-end entrances",
		)
		cave_connectivity_anchor_region.cave_network_edge_count = 1
		cave_connectivity_anchor_region.cave_network_edges[0] = cave_connectivity_route_edge
		cave_connectivity_anchor_sample = terrain_density_cave_node_connectivity(
			&cave_connectivity_anchor_region,
			cave_connectivity_anchor_node,
		)
		log.assert(
			cave_connectivity_anchor_sample.should_carve &&
			cave_connectivity_anchor_sample.should_bridge,
			"anchored cave mouths near a route should carve only when they can bridge into the network",
		)

		surface_node := biomes.cave_network_node_from_owner(
			key,
			biomes.FeatureGridCoord3{x = 0, y = 0, z = 0},
		)
		surface_column := terrain_biome_column_sample_direct(
			key,
			i32(math.floor_f32(surface_node.x)),
			i32(math.floor_f32(surface_node.z)),
		)
		surface_node_depth := surface_column.surface_height_blocks - surface_node.y
		log.assertf(
			surface_node_depth >= 60,
			"surface-adjacent cave node should have meaningful depth, depth=%.2f",
			surface_node_depth,
		)
		log.assertf(
			surface_node.radius_blocks <= 45,
			"surface-adjacent cave node radius should not create a broad crater, radius=%.2f",
			surface_node.radius_blocks,
		)

		deep_node := biomes.cave_network_node_from_owner(
			key,
			biomes.FeatureGridCoord3{x = 0, y = -1, z = 0},
		)
		log.assertf(
			deep_node.y < surface_node.y - 64,
			"deep cave owner should produce a lower subterranean node: surface_y=%.2f deep_y=%.2f",
			surface_node.y,
			deep_node.y,
		)
		log.assertf(
			deep_node.y < -96,
			"deep cave owner should reach mid-depth terrain, deep_y=%.2f",
			deep_node.y,
		)
	}

	debug_chunk_mesher_contract_checks_run :: proc(transient_arena: ^mem.Arena) {
		temp := mem.begin_arena_temp_memory(transient_arena)
		defer mem.end_arena_temp_memory(temp)
		allocator := mem.arena_allocator(transient_arena)
		scratch := terrain_binary_greedy_scratch_alloc(transient_arena)
		decoration_contract_key := terrain_generation_key_make(0)

		view := world_async.ChunkVoxelView {
			blocks = make(#soa[]world_async.ChunkVoxelViewElement, CHUNK_BLOCK_COUNT, allocator),
		}

		chunk_voxel_view_fill_empty(&view)
		anchoring_node := biomes.CaveNetworkNode {
			id            = biomes.FeatureID(0xdec0a11),
			x             = 32,
			y             = 32,
			z             = 32,
			radius_blocks = 12,
			biome_id      = .Crystal_Geode_Network,
			major_region  = true,
		}
		floating_written := terrain_decoration_cave_node_apply(
			&view,
			anchoring_node,
			.Cave_Ruin_Hall,
			{},
		)
		log.assert(
			floating_written == 0,
			"cave decoration without a discovered floor must not stamp floating structures",
		)
		for z := i32(20); z <= 44; z += 1 {
			for x := i32(20); x <= 44; x += 1 {
				index := chunk_block_index(u32(x), 16, u32(z))
				view.blocks.occupancy[index] = .Solid
				view.blocks.material_id[index] = world_async.BlockMaterialID(TERRAIN_STONE_MAT_ID)
			}
		}
		grounded_written := terrain_decoration_cave_node_apply(
			&view,
			anchoring_node,
			.Cave_Ruin_Hall,
			{},
		)
		ground_contact_count: u32
		for z := i32(0); z < CHUNK_BLOCK_LENGTH; z += 1 {
			for x := i32(0); x < CHUNK_BLOCK_LENGTH; x += 1 {
				index := chunk_block_index(u32(x), 17, u32(z))
				if view.blocks.occupancy[index] == .Solid {
					ground_contact_count += 1
				}
			}
		}
		log.assert(
			grounded_written > 0 && ground_contact_count > 0,
			"cave decoration with a valid floor should stamp grounded contact blocks",
		)

		chunk_voxel_view_fill_empty(&view)
		cave_water_material := terrain_block_material_id_from_biome_material(.Swamp_Water)
		terrain_density_fill_water_ellipsoid(&view, {}, cave_water_material, 32, 32, 32, 5, 2, 5)
		unsupported_cave_water_count: u32
		for z := i32(0); z < CHUNK_BLOCK_LENGTH; z += 1 {
			for y := i32(0); y < CHUNK_BLOCK_LENGTH; y += 1 {
				for x := i32(0); x < CHUNK_BLOCK_LENGTH; x += 1 {
					index := chunk_block_index(u32(x), u32(y), u32(z))
					if terrain_material_palette_index(view.blocks.material_id[index]) ==
					   TERRAIN_WATER_MAT_ID {
						unsupported_cave_water_count += 1
					}
				}
			}
		}
		log.assert(
			unsupported_cave_water_count == 0,
			"cave water ellipsoids without nearby support must not create floating water",
		)

		for z := i32(25); z <= 39; z += 1 {
			for x := i32(25); x <= 39; x += 1 {
				index := chunk_block_index(u32(x), 29, u32(z))
				view.blocks.occupancy[index] = .Solid
				view.blocks.material_id[index] = world_async.BlockMaterialID(TERRAIN_STONE_MAT_ID)
			}
		}
		terrain_density_fill_water_ellipsoid(&view, {}, cave_water_material, 32, 32, 32, 5, 2, 5)
		supported_cave_water_count: u32
		for z := i32(0); z < CHUNK_BLOCK_LENGTH; z += 1 {
			for y := i32(0); y < CHUNK_BLOCK_LENGTH; y += 1 {
				for x := i32(0); x < CHUNK_BLOCK_LENGTH; x += 1 {
					index := chunk_block_index(u32(x), u32(y), u32(z))
					if terrain_material_palette_index(view.blocks.material_id[index]) ==
					   TERRAIN_WATER_MAT_ID {
						supported_cave_water_count += 1
					}
				}
			}
		}
		log.assert(
			supported_cave_water_count > 0,
			"cave water ellipsoids should still fill floor-backed basin pockets",
		)

		surface_columns: [CHUNK_BLOCK_LENGTH * CHUNK_BLOCK_LENGTH]TerrainBiomeColumn
		surface_feature := biomes.DecorationFeature {
			id               = biomes.FeatureID(0x51a7face),
			x                = 32,
			z                = 32,
			biome_id         = .Temperate_Hills,
			family_id        = .Ruin_Hamlet,
			height_blocks    = 5,
			radius_blocks    = 10,
			material_variant = 0,
		}
		for z := i32(0); z < CHUNK_BLOCK_LENGTH; z += 1 {
			for x := i32(0); x < CHUNK_BLOCK_LENGTH; x += 1 {
				surface_columns[x + z * CHUNK_BLOCK_LENGTH] = {
					surface_height        = 16,
					surface_height_blocks = 16,
					surface_material_id   = world_async.BlockMaterialID(TERRAIN_GRASS_MAT_ID),
				}
			}
		}

		chunk_voxel_view_fill_empty(&view)
		for z := i32(0); z < CHUNK_BLOCK_LENGTH; z += 1 {
			for x := i32(0); x < CHUNK_BLOCK_LENGTH; x += 1 {
				index := chunk_block_index(u32(x), 16, u32(z))
				view.blocks.occupancy[index] = .Solid
				view.blocks.material_id[index] = world_async.BlockMaterialID(TERRAIN_GRASS_MAT_ID)
			}
		}
		dry_flat_result := terrain_decoration_surface_feature_apply(
			&view,
			decoration_contract_key,
			surface_feature,
			{},
			surface_columns[:],
		)
		log.assert(
			dry_flat_result.blocks_written > 800,
			"surface village should stamp a substantial multi-building cluster on a flat dry footprint",
		)

		chunk_voxel_view_fill_empty(&view)
		for z := i32(0); z < CHUNK_BLOCK_LENGTH; z += 1 {
			for x := i32(0); x < CHUNK_BLOCK_LENGTH; x += 1 {
				surface_columns[x + z * CHUNK_BLOCK_LENGTH].water_fill_active = true
				surface_columns[x + z * CHUNK_BLOCK_LENGTH].water_level_blocks = 32
				index := chunk_block_index(u32(x), 16, u32(z))
				view.blocks.occupancy[index] = .Solid
				view.blocks.material_id[index] = world_async.BlockMaterialID(TERRAIN_GRASS_MAT_ID)
			}
		}
		water_result := terrain_decoration_surface_feature_apply(
			&view,
			decoration_contract_key,
			surface_feature,
			{},
			surface_columns[:],
		)
		log.assert(
			water_result.blocks_written == 0,
			"surface structures must reject water-covered footprints",
		)

		chunk_voxel_view_fill_empty(&view)
		for z := i32(0); z < CHUNK_BLOCK_LENGTH; z += 1 {
			for x := i32(0); x < CHUNK_BLOCK_LENGTH; x += 1 {
				surface_columns[x + z * CHUNK_BLOCK_LENGTH].water_fill_active = false
				surface_columns[x + z * CHUNK_BLOCK_LENGTH].water_level_blocks = 0
				surface_columns[x + z * CHUNK_BLOCK_LENGTH].surface_height = 16
				surface_columns[x + z * CHUNK_BLOCK_LENGTH].surface_height_blocks = 16
				index := chunk_block_index(u32(x), 16, u32(z))
				view.blocks.occupancy[index] = .Solid
				view.blocks.material_id[index] = world_async.BlockMaterialID(TERRAIN_GRASS_MAT_ID)
			}
		}
		for slope_z := i32(12); slope_z <= 52; slope_z += 2 {
			for slope_x := i32(12); slope_x <= 52; slope_x += 2 {
				surface_columns[slope_x + slope_z * CHUNK_BLOCK_LENGTH].surface_height = 19
				surface_columns[slope_x + slope_z * CHUNK_BLOCK_LENGTH].surface_height_blocks = 19
				slope_index := chunk_block_index(u32(slope_x), 19, u32(slope_z))
				view.blocks.occupancy[slope_index] = .Solid
				view.blocks.material_id[slope_index] = world_async.BlockMaterialID(
					TERRAIN_GRASS_MAT_ID,
				)
			}
		}
		slope_result := terrain_decoration_surface_feature_apply(
			&view,
			decoration_contract_key,
			surface_feature,
			{},
			surface_columns[:],
		)
		log.assert(
			slope_result.blocks_written == 0,
			"surface structures must reject uneven footprints",
		)

		for z := i32(0); z < CHUNK_BLOCK_LENGTH; z += 1 {
			for x := i32(0); x < CHUNK_BLOCK_LENGTH; x += 1 {
				height := i32(12 + (x + z) % 7)
				surface_columns[x + z * CHUNK_BLOCK_LENGTH] = {
					surface_height        = height,
					surface_height_blocks = f32(height),
					dominant_biome_id     = .Temperate_Hills,
					surface_material_id   = world_async.BlockMaterialID(TERRAIN_GRASS_MAT_ID),
				}
			}
		}
		terrain_decoration_surface_structure_pad_apply(
			decoration_contract_key,
			surface_feature,
			{},
			surface_columns[:],
		)
		pad_min := i32(100000)
		pad_max := i32(-100000)
		for z := i32(24); z <= 40; z += 1 {
			for x := i32(24); x <= 40; x += 1 {
				column := surface_columns[x + z * CHUNK_BLOCK_LENGTH]
				pad_min = math.min(pad_min, column.surface_height)
				pad_max = math.max(pad_max, column.surface_height)
			}
		}
		log.assertf(
			pad_max - pad_min <= 1,
			"structure pad should flatten the core footprint, min=%d max=%d",
			pad_min,
			pad_max,
		)

		reservations: [TERRAIN_DECORATION_SURFACE_STRUCTURE_RESERVATION_CAPACITY]TerrainDecorationSurfaceReservation
		reservation_count: u32
		terrain_decoration_surface_reservation_add(
			reservations[:],
			&reservation_count,
			surface_feature,
		)
		tree_feature := biomes.DecorationFeature {
			id                  = biomes.FeatureID(0x7aee),
			x                   = 34,
			z                   = 34,
			biome_id            = .Temperate_Hills,
			family_id           = .Baseline_Tree,
			radius_blocks       = 8,
			stand_radius_blocks = 12,
		}
		log.assert(
			terrain_decoration_surface_feature_overlaps_reservations(
				tree_feature,
				reservations[:reservation_count],
			),
			"tree stands must be reserved out of structure footprints",
		)

		packed_fields := terrain_unpack_vertex(terrain_pack_vertex(2, 3, 4, 5, 6))
		log.assertf(
			packed_fields.block_x == 2,
			"terrain pack/unpack: expected block_x 2, got %d",
			packed_fields.block_x,
		)
		log.assertf(
			packed_fields.block_y == 3,
			"terrain pack/unpack: expected block_y 3, got %d",
			packed_fields.block_y,
		)
		log.assertf(
			packed_fields.block_z == 4,
			"terrain pack/unpack: expected block_z 4, got %d",
			packed_fields.block_z,
		)
		log.assertf(
			packed_fields.normal_id == 5,
			"terrain pack/unpack: expected normal 5, got %d",
			packed_fields.normal_id,
		)
		log.assertf(
			packed_fields.material_id == 6,
			"terrain pack/unpack: expected material 6, got %d",
			packed_fields.material_id,
		)
		chunk_voxel_view_fill_empty(&view)
		empty_output := chunk_voxel_view_build_binary_greedy_mesh(
			view,
			.Treat_Out_Of_Chunk_As_Empty,
			allocator,
			scratch,
		)
		log.assertf(
			empty_output.face_count == 0,
			"empty chunk: expected 0 faces, got %d",
			empty_output.face_count,
		)
		log.assertf(
			len(empty_output.vertices) == 0,
			"empty chunk: expected 0 vertices, got %d",
			len(empty_output.vertices),
		)
		log.assertf(
			len(empty_output.indices) == 0,
			"empty chunk: expected 0 indices, got %d",
			len(empty_output.indices),
		)

		// one edge block proves boundary policy at local 0
		chunk_voxel_view_fill_empty(&view)
		index := chunk_block_index(0, 0, 0)
		view.blocks.occupancy[index] = .Solid
		view.blocks.material_id[index] = world_async.BlockMaterialID(5)

		edge_output := chunk_voxel_view_build_binary_greedy_mesh(
			view,
			.Treat_Out_Of_Chunk_As_Empty,
			allocator,
			scratch,
		)
		log.assertf(
			edge_output.face_count == 6,
			"edge chunk: expected 6 face, got %d",
			edge_output.face_count,
		)

		// one interior block exact payload
		chunk_voxel_view_fill_empty(&view)
		index = chunk_block_index(2, 3, 4)
		view.blocks.occupancy[index] = .Solid
		view.blocks.material_id[index] = world_async.BlockMaterialID(5)


		output := chunk_voxel_view_build_binary_greedy_mesh(
			view,
			.Treat_Out_Of_Chunk_As_Empty,
			allocator,
			scratch,
		)
		log.assertf(
			output.face_count == 6,
			"edge chunk: expected 6 face, got %d",
			output.face_count,
		)
		log.assertf(
			len(output.vertices) == 24,
			"edge chunk: expected 24 vertices, got %d",
			len(output.vertices),
		)
		log.assertf(
			len(output.indices) == 36,
			"edge chunk: expected 36 indices, got %d",
			len(output.indices),
		)

		expected_normals := [?]u32{0, 1, 2, 3, 4, 5}
		expected_single_block_corners := [?]TerrainGridPoint {
			// +X
			{3, 3, 4},
			{3, 4, 4},
			{3, 4, 5},
			{3, 3, 5},

			// -X
			{2, 3, 4},
			{2, 3, 5},
			{2, 4, 5},
			{2, 4, 4},

			// +Y
			{2, 4, 4},
			{2, 4, 5},
			{3, 4, 5},
			{3, 4, 4},

			// -Y
			{2, 3, 4},
			{3, 3, 4},
			{3, 3, 5},
			{2, 3, 5},

			// +Z
			{2, 3, 5},
			{3, 3, 5},
			{3, 4, 5},
			{2, 4, 5},

			// -Z
			{2, 3, 4},
			{2, 4, 4},
			{3, 4, 4},
			{3, 3, 4},
		}
		for face_index in 0 ..< 6 {
			expected_normal := expected_normals[face_index]
			for corner_index in 0 ..< 4 {
				vertex_index := face_index * 4 + corner_index
				expected_corner := expected_single_block_corners[vertex_index]
				unpacked_vertex := terrain_unpack_vertex(output.vertices[vertex_index])

				log.assertf(
					unpacked_vertex.block_x == expected_corner.x,
					"single block vertex %d: expected local_x %d, got %d",
					vertex_index,
					expected_corner.x,
					unpacked_vertex.block_x,
				)
				log.assertf(
					unpacked_vertex.block_y == expected_corner.y,
					"single block vertex %d: expected local_y %d, got %d",
					vertex_index,
					expected_corner.y,
					unpacked_vertex.block_y,
				)
				log.assertf(
					unpacked_vertex.block_z == expected_corner.z,
					"single block vertex %d: expected local_z %d, got %d",
					vertex_index,
					expected_corner.z,
					unpacked_vertex.block_z,
				)
				log.assertf(
					unpacked_vertex.normal_id == expected_normal,
					"single block vertex %d: expected normal %d, got %d",
					vertex_index,
					expected_normal,
					unpacked_vertex.normal_id,
				)
				log.assertf(
					unpacked_vertex.material_id == 5,
					"single block vertex %d: expected material 5, got %d",
					vertex_index,
					unpacked_vertex.material_id,
				)
			}
		}

		chunk_voxel_view_fill_empty(&view)
		index = chunk_block_index(5, 6, 7)
		hydrology_debug_material_id := terrain_hydrology_debug_material_id(
			world_async.BlockMaterialID(TERRAIN_DIRT_MAT_ID),
		)
		view.blocks.occupancy[index] = .Solid
		view.blocks.material_id[index] = hydrology_debug_material_id

		debug_output := chunk_voxel_view_build_binary_greedy_mesh(
			view,
			.Treat_Out_Of_Chunk_As_Empty,
			allocator,
			scratch,
		)
		log.assertf(
			debug_output.face_count == 6,
			"hydrology debug block: expected 6 faces, got %d",
			debug_output.face_count,
		)
		for vertex in debug_output.vertices {
			unpacked_vertex := terrain_unpack_vertex(vertex)
			log.assertf(
				unpacked_vertex.material_id == u32(u8(hydrology_debug_material_id)),
				"hydrology debug block: expected material %d, got %d",
				u8(hydrology_debug_material_id),
				unpacked_vertex.material_id,
			)
		}

		row_cache := new(world_async.ChunkBinaryGreedyRowCache, allocator)
		log.assert(row_cache != nil, "hydrology debug row cache allocation failed")
		terrain_binary_row_cache_fill(row_cache, view, 1)
		debug_cache_output := chunk_binary_row_cache_build_binary_greedy_mesh(
			row_cache,
			view,
			.Treat_Out_Of_Chunk_As_Empty,
			allocator,
			scratch,
		)
		log.assertf(
			debug_cache_output.face_count == 6,
			"hydrology debug cached block: expected 6 faces, got %d",
			debug_cache_output.face_count,
		)
		for vertex in debug_cache_output.vertices {
			unpacked_vertex := terrain_unpack_vertex(vertex)
			log.assertf(
				unpacked_vertex.material_id == u32(u8(hydrology_debug_material_id)),
				"hydrology debug cached block: expected material %d, got %d",
				u8(hydrology_debug_material_id),
				unpacked_vertex.material_id,
			)
		}

		chunk_voxel_view_fill_empty(&view)
		shore_below_index := chunk_block_index(4, 4, 4)
		shore_grass_index := chunk_block_index(4, 5, 4)
		view.blocks.occupancy[shore_below_index] = .Solid
		view.blocks.material_id[shore_below_index] = world_async.BlockMaterialID(
			TERRAIN_WET_MARSH_MAT_ID,
		)
		view.blocks.occupancy[shore_grass_index] = .Solid
		view.blocks.material_id[shore_grass_index] = world_async.BlockMaterialID(
			TERRAIN_GRASS_MAT_ID,
		)
		shore_output := chunk_voxel_view_build_binary_greedy_mesh(
			view,
			.Treat_Out_Of_Chunk_As_Empty,
			allocator,
			scratch,
		)
		log.assertf(
			shore_output.face_count == 6,
			"shore grass cap: expected visible cap faces to merge as wet material, got %d faces",
			shore_output.face_count,
		)
		for vertex in shore_output.vertices {
			unpacked_vertex := terrain_unpack_vertex(vertex)
			log.assertf(
				unpacked_vertex.material_id == TERRAIN_WET_MARSH_MAT_ID,
				"shore grass cap: normal=%d expected wet material, got %d",
				unpacked_vertex.normal_id,
				unpacked_vertex.material_id,
			)
		}

		shore_row_cache := new(world_async.ChunkBinaryGreedyRowCache, allocator)
		log.assert(shore_row_cache != nil, "shore row cache allocation failed")
		terrain_binary_row_cache_fill(shore_row_cache, view, 1)
		shore_cache_output := chunk_binary_row_cache_build_binary_greedy_mesh(
			shore_row_cache,
			view,
			.Treat_Out_Of_Chunk_As_Empty,
			allocator,
			scratch,
		)
		log.assertf(
			shore_cache_output.face_count == 6,
			"shore cached grass cap: expected visible cap faces to merge as wet material, got %d faces",
			shore_cache_output.face_count,
		)
		for vertex in shore_cache_output.vertices {
			unpacked_vertex := terrain_unpack_vertex(vertex)
			log.assertf(
				unpacked_vertex.material_id == TERRAIN_WET_MARSH_MAT_ID,
				"shore cached grass cap: normal=%d expected wet material, got %d",
				unpacked_vertex.normal_id,
				unpacked_vertex.material_id,
			)
		}
		log.assert(
			terrain_binary_cave_face_material_index(2, TERRAIN_AQUIFER_WALL_MAT_ID) ==
			TERRAIN_WET_MARSH_MAT_ID,
			"aquifer cave top faces should render as wet floor material",
		)
		log.assert(
			terrain_binary_cave_face_material_index(3, TERRAIN_AQUIFER_WALL_MAT_ID) ==
			TERRAIN_STONE_MAT_ID,
			"aquifer cave bottom faces should render as stone ceiling material",
		)
		log.assert(
			terrain_binary_cave_face_material_index(0, TERRAIN_AQUIFER_WALL_MAT_ID) ==
			TERRAIN_AQUIFER_WALL_MAT_ID,
			"aquifer cave side faces should keep aquifer wall material",
		)
		log.assert(
			terrain_binary_cave_face_material_index(2, TERRAIN_CRYSTAL_MAT_ID) ==
			TERRAIN_STONE_MAT_ID,
			"crystal cave top faces should render as stone floor material",
		)
		log.assert(
			terrain_binary_cave_face_material_index(3, TERRAIN_CRYSTAL_MAT_ID) ==
			TERRAIN_CRYSTAL_MAT_ID,
			"crystal cave bottom faces should keep crystal ceiling material",
		)

		chunk_voxel_view_fill_empty(&view)
		index = chunk_block_index(8, 9, 10)
		cave_debug_material_id := terrain_cave_anchor_debug_material_id(
			terrain_cave_network_debug_material_id(
				world_async.BlockMaterialID(TERRAIN_STONE_MAT_ID),
			),
		)
		view.blocks.occupancy[index] = .Solid
		view.blocks.material_id[index] = cave_debug_material_id

		cave_debug_output := chunk_voxel_view_build_binary_greedy_mesh(
			view,
			.Treat_Out_Of_Chunk_As_Empty,
			allocator,
			scratch,
		)
		log.assertf(
			cave_debug_output.face_count == 6,
			"cave debug block: expected 6 faces, got %d",
			cave_debug_output.face_count,
		)
		for vertex in cave_debug_output.vertices {
			unpacked_vertex := terrain_unpack_vertex(vertex)
			log.assertf(
				unpacked_vertex.material_id == u32(u8(cave_debug_material_id)),
				"cave debug block: expected material %d, got %d",
				u8(cave_debug_material_id),
				unpacked_vertex.material_id,
			)
		}

		chunk_voxel_view_fill_empty(&view)
		index = chunk_block_index(2, 3, 4)
		view.blocks.occupancy[index] = .Solid
		view.blocks.material_id[index] = world_async.BlockMaterialID(5)

		for face_index in 0 ..< 6 {
			base := u32(face_index * 4)
			i := face_index * 6
			log.assertf(output.indices[i + 0] == base + 0, "single block index %d mismatch", i + 0)
			log.assertf(output.indices[i + 1] == base + 1, "single block index %d mismatch", i + 1)
			log.assertf(output.indices[i + 2] == base + 2, "single block index %d mismatch", i + 2)
			log.assertf(output.indices[i + 3] == base + 0, "single block index %d mismatch", i + 3)
			log.assertf(output.indices[i + 4] == base + 2, "single block index %d mismatch", i + 4)
			log.assertf(output.indices[i + 5] == base + 3, "single block index %d mismatch", i + 5)
		}

		{
			binary_temp := mem.begin_arena_temp_memory(transient_arena)
			defer mem.end_arena_temp_memory(binary_temp)
			greedy_single_output := mesh_job_execute_sync(
				{
					mesher = .Greedy_Binary,
					snapshot = {coord = {0, 0, 0}, voxel_view = view},
					boundary_policy = .Treat_Out_Of_Chunk_As_Empty,
				},
				allocator,
				transient_arena,
			)
			log.assertf(
				greedy_single_output.face_count == 6,
				"greedy single block: expected 6 faces, got %d",
				greedy_single_output.face_count,
			)
			log.assertf(
				len(greedy_single_output.vertices) == 24,
				"greedy single block: expected 24 vertices, got %d",
				len(greedy_single_output.vertices),
			)
			log.assertf(
				len(greedy_single_output.indices) == 36,
				"greedy single block: expected 36 indices, got %d",
				len(greedy_single_output.indices),
			)
			subchunk_single_output := mesh_job_execute_sync(
				{
					mesher = .Greedy_Binary,
					scope_kind = .Subchunk,
					subchunk_index = chunk_subchunk_index_from_coord(0, 0, 0),
					snapshot = {coord = {0, 0, 0}, voxel_view = view},
					boundary_policy = .Treat_Out_Of_Chunk_As_Empty,
				},
				allocator,
				transient_arena,
			)
			log.assertf(
				subchunk_single_output.face_count == 6,
				"subchunk single block: expected 6 faces, got %d",
				subchunk_single_output.face_count,
			)
			subchunk_empty_output := mesh_job_execute_sync(
				{
					mesher = .Greedy_Binary,
					scope_kind = .Subchunk,
					subchunk_index = chunk_subchunk_index_from_coord(1, 0, 0),
					snapshot = {coord = {0, 0, 0}, voxel_view = view},
					boundary_policy = .Treat_Out_Of_Chunk_As_Empty,
				},
				allocator,
				transient_arena,
			)
			log.assertf(
				subchunk_empty_output.face_count == 0,
				"empty subchunk: expected 0 faces, got %d",
				subchunk_empty_output.face_count,
			)
			for face_index in 0 ..< 6 {
				expected_normal := expected_normals[face_index]
				for corner_index in 0 ..< 4 {
					vertex_index := face_index * 4 + corner_index
					expected_corner := expected_single_block_corners[vertex_index]
					unpacked_vertex := terrain_unpack_vertex(
						greedy_single_output.vertices[vertex_index],
					)

					log.assertf(
						unpacked_vertex.block_x == expected_corner.x,
						"greedy single block vertex %d: expected local_x %d, got %d",
						vertex_index,
						expected_corner.x,
						unpacked_vertex.block_x,
					)
					log.assertf(
						unpacked_vertex.block_y == expected_corner.y,
						"greedy single block vertex %d: expected local_y %d, got %d",
						vertex_index,
						expected_corner.y,
						unpacked_vertex.block_y,
					)
					log.assertf(
						unpacked_vertex.block_z == expected_corner.z,
						"greedy single block vertex %d: expected local_z %d, got %d",
						vertex_index,
						expected_corner.z,
						unpacked_vertex.block_z,
					)
					log.assertf(
						unpacked_vertex.normal_id == expected_normal,
						"greedy single block vertex %d: expected normal %d, got %d",
						vertex_index,
						expected_normal,
						unpacked_vertex.normal_id,
					)
					log.assertf(
						unpacked_vertex.material_id == 5,
						"greedy single block vertex %d: expected material 5, got %d",
						vertex_index,
						unpacked_vertex.material_id,
					)
				}
			}
		}

		// adjacent X/Y/Z: each pair becomes one rectangular prism with six merged faces.
		adjacent_pairs := [?][2]world_async.BlockCoord {
			{{1, 1, 1}, {2, 1, 1}},
			{{1, 1, 1}, {1, 2, 1}},
			{{1, 1, 1}, {1, 1, 2}},
		}

		for pair, pair_index in adjacent_pairs {
			chunk_voxel_view_fill_empty(&view)

			for block in pair {
				index = chunk_block_index(u32(block.x), u32(block.y), u32(block.z))
				view.blocks.occupancy[index] = .Solid
				view.blocks.material_id[index] = world_async.BlockMaterialID(1)
			}

			adjacent_output := chunk_voxel_view_build_binary_greedy_mesh(
				view,
				.Treat_Out_Of_Chunk_As_Empty,
				allocator,
				scratch,
			)
			log.assertf(
				adjacent_output.face_count == 6,
				"adjacent pair %d: expected 6 merged faces, got %d",
				pair_index,
				adjacent_output.face_count,
			)
		}

		// adjacent chunks: touching boundary blocks suppress their shared faces.
		left_view := world_async.ChunkVoxelView {
			blocks = make(#soa[]world_async.ChunkVoxelViewElement, CHUNK_BLOCK_COUNT, allocator),
		}
		right_view := world_async.ChunkVoxelView {
			blocks = make(#soa[]world_async.ChunkVoxelViewElement, CHUNK_BLOCK_COUNT, allocator),
		}
		chunk_voxel_view_fill_empty(&left_view)
		chunk_voxel_view_fill_empty(&right_view)

		left_index := chunk_block_index(CHUNK_BLOCK_LOCAL_MAX, 1, 1)
		left_view.blocks.occupancy[left_index] = .Solid
		left_view.blocks.material_id[left_index] = world_async.BlockMaterialID(7)

		right_index := chunk_block_index(0, 1, 1)
		right_view.blocks.occupancy[right_index] = .Solid
		right_view.blocks.material_id[right_index] = world_async.BlockMaterialID(7)

		left_snapshot := world_async.ChunkSnapshot {
			coord      = {0, 0, 0},
			voxel_view = left_view,
		}
		right_snapshot := world_async.ChunkSnapshot {
			coord      = {1, 0, 0},
			voxel_view = right_view,
		}
		neighbor_test_snapshots := [?]world_async.ChunkSnapshot{left_snapshot, right_snapshot}

		left_neighbor_output := mesh_job_execute_sync(
			{
				mesher = .Greedy_Binary,
				snapshot = left_snapshot,
				neighbors = chunk_mesh_neighbors_find(
					neighbor_test_snapshots[:],
					left_snapshot.coord,
				),
				boundary_policy = .Sample_Neighbor_Snapshots,
			},
			allocator,
			transient_arena,
		)
		log.assertf(
			left_neighbor_output.face_count == 5,
			"left boundary block: expected 5 faces with +X neighbor, got %d",
			left_neighbor_output.face_count,
		)

		right_neighbor_output := mesh_job_execute_sync(
			{
				mesher = .Greedy_Binary,
				snapshot = right_snapshot,
				neighbors = chunk_mesh_neighbors_find(
					neighbor_test_snapshots[:],
					right_snapshot.coord,
				),
				boundary_policy = .Sample_Neighbor_Snapshots,
			},
			allocator,
			transient_arena,
		)
		log.assertf(
			right_neighbor_output.face_count == 5,
			"right boundary block: expected 5 faces with -X neighbor, got %d",
			right_neighbor_output.face_count,
		)

		missing_neighbor_output := mesh_job_execute_sync(
			{
				mesher = .Greedy_Binary,
				snapshot = left_snapshot,
				neighbors = chunk_mesh_neighbors_find(
					neighbor_test_snapshots[:1],
					left_snapshot.coord,
				),
				boundary_policy = .Sample_Neighbor_Snapshots,
			},
			allocator,
			transient_arena,
		)
		log.assertf(
			missing_neighbor_output.face_count == 5,
			"left boundary block: expected missing sampled neighbor to suppress perimeter face, got %d",
			missing_neighbor_output.face_count,
		)

		{
			binary_temp := mem.begin_arena_temp_memory(transient_arena)
			defer mem.end_arena_temp_memory(binary_temp)
			left_greedy_neighbor_output := mesh_job_execute_sync(
				{
					mesher = .Greedy_Binary,
					snapshot = left_snapshot,
					neighbors = chunk_mesh_neighbors_find(
						neighbor_test_snapshots[:],
						left_snapshot.coord,
					),
					boundary_policy = .Sample_Neighbor_Snapshots,
				},
				allocator,
				transient_arena,
			)
			log.assertf(
				left_greedy_neighbor_output.face_count == 5,
				"greedy left boundary block: expected 5 faces with +X neighbor, got %d",
				left_greedy_neighbor_output.face_count,
			)

			right_greedy_neighbor_output := mesh_job_execute_sync(
				{
					mesher = .Greedy_Binary,
					snapshot = right_snapshot,
					neighbors = chunk_mesh_neighbors_find(
						neighbor_test_snapshots[:],
						right_snapshot.coord,
					),
					boundary_policy = .Sample_Neighbor_Snapshots,
				},
				allocator,
				transient_arena,
			)
			log.assertf(
				right_greedy_neighbor_output.face_count == 5,
				"greedy right boundary block: expected 5 faces with -X neighbor, got %d",
				right_greedy_neighbor_output.face_count,
			)
		}

		// 2x2x2 solid cube: binary greedy merges each side into one quad.
		chunk_voxel_view_fill_empty(&view)
		for z in 1 ..< 3 {
			for y in 1 ..< 3 {
				for x in 1 ..< 3 {
					index = chunk_block_index(u32(x), u32(y), u32(z))
					view.blocks.occupancy[index] = .Solid
					view.blocks.material_id[index] = world_async.BlockMaterialID(2)
				}
			}
		}

		{
			binary_temp := mem.begin_arena_temp_memory(transient_arena)
			defer mem.end_arena_temp_memory(binary_temp)
			greedy_output := chunk_voxel_view_build_binary_greedy_mesh(
				view,
				.Treat_Out_Of_Chunk_As_Empty,
				allocator,
				scratch,
			)
			log.assertf(
				greedy_output.face_count == 6,
				"greedy 2x2x2: expected 6 faces, got %d",
				greedy_output.face_count,
			)
			log.assertf(
				len(greedy_output.vertices) == 24,
				"greedy 2x2x2: expected 24 vertices, got %d",
				len(greedy_output.vertices),
			)
			log.assertf(
				len(greedy_output.indices) == 36,
				"greedy 2x2x2: expected 36 indices, got %d",
				len(greedy_output.indices),
			)
		}

		// current rectangular debug fixture: one cuboid should merge to six quads.
		chunk_voxel_view_debug_rect_build(&view, allocator)

		{
			binary_temp := mem.begin_arena_temp_memory(transient_arena)
			defer mem.end_arena_temp_memory(binary_temp)
			greedy_rect_output := chunk_voxel_view_build_binary_greedy_mesh(
				view,
				.Treat_Out_Of_Chunk_As_Empty,
				allocator,
				scratch,
			)
			log.assertf(
				greedy_rect_output.face_count == 6,
				"greedy debug rect: expected 6 faces, got %d",
				greedy_rect_output.face_count,
			)
		}

		// full chunk: only six outer surfaces emit.
		chunk_voxel_view_fill_empty(&view)
		for z in 0 ..< CHUNK_BLOCK_LENGTH {
			for y in 0 ..< CHUNK_BLOCK_LENGTH {
				for x in 0 ..< CHUNK_BLOCK_LENGTH {
					index = chunk_block_index(u32(x), u32(y), u32(z))
					view.blocks.occupancy[index] = .Solid
					view.blocks.material_id[index] = world_async.BlockMaterialID(3)
				}
			}
		}

		{
			binary_temp := mem.begin_arena_temp_memory(transient_arena)
			defer mem.end_arena_temp_memory(binary_temp)
			greedy_full_output := chunk_voxel_view_build_binary_greedy_mesh(
				view,
				.Treat_Out_Of_Chunk_As_Empty,
				allocator,
				scratch,
			)
			log.assertf(
				greedy_full_output.face_count == 6,
				"greedy full chunk: expected 6 faces, got %d",
				greedy_full_output.face_count,
			)
			log.assertf(
				len(greedy_full_output.vertices) == 24,
				"greedy full chunk: expected 24 vertices, got %d",
				len(greedy_full_output.vertices),
			)
			log.assertf(
				len(greedy_full_output.indices) == 36,
				"greedy full chunk: expected 36 indices, got %d",
				len(greedy_full_output.indices),
			)
		}

		// checkerboard: count-only, do not build mesh output.
		chunk_voxel_view_fill_empty(&view)
		for z in 0 ..< CHUNK_BLOCK_LENGTH {
			for y in 0 ..< CHUNK_BLOCK_LENGTH {
				for x in 0 ..< CHUNK_BLOCK_LENGTH {
					if ((x + y + z) & 1) == 0 {
						index = chunk_block_index(u32(x), u32(y), u32(z))
						view.blocks.occupancy[index] = .Solid
						view.blocks.material_id[index] = world_async.BlockMaterialID(4)
					}
				}
			}
		}

		expected_checker_faces := u32(786432)
		{
			binary_temp := mem.begin_arena_temp_memory(transient_arena)
			defer mem.end_arena_temp_memory(binary_temp)
			greedy_checker_count := chunk_voxel_view_count_binary_greedy_faces(
				view,
				.Treat_Out_Of_Chunk_As_Empty,
				scratch,
			)
			log.assertf(
				greedy_checker_count == expected_checker_faces,
				"greedy checkerboard: expected %d faces, got %d",
				expected_checker_faces,
				greedy_checker_count,
			)
		}

		heightfield_seed := u32(0)
		heightfield_key := terrain_generation_key_make(heightfield_seed)

		heightfield_sample_column := terrain_biome_column_sample_direct(heightfield_key, 0, 0)
		heightfield_coord := chunk_coord_from_block_coord(
			world_async.BlockCoord{x = 0, y = heightfield_sample_column.surface_height, z = 0},
		)
		heightfield_origin := chunk_origin_from_coord(heightfield_coord)
		terrain_heightfield_voxel_view_fill(&view, heightfield_coord, heightfield_seed)
		heightfield_solid_count: u32
		heightfield_surface_column_count: u32
		heightfield_surface_material_column_count: u32
		for z in 0 ..< CHUNK_BLOCK_LENGTH {
			for x in 0 ..< CHUNK_BLOCK_LENGTH {
				column := terrain_biome_column_sample_direct(
					heightfield_key,
					heightfield_origin.x + i32(x),
					heightfield_origin.z + i32(z),
				)
				surface_local_y := column.surface_height - heightfield_origin.y
				if surface_local_y >= 0 && surface_local_y < CHUNK_BLOCK_LENGTH {
					heightfield_surface_column_count += 1
					surface_index := chunk_block_index(u32(x), u32(surface_local_y), u32(z))
					if view.blocks.occupancy[surface_index] == .Solid {
						surface_material_id := terrain_material_palette_index(
							view.blocks.material_id[surface_index],
						)
						expected_surface_material_id := terrain_material_palette_index(
							column.surface_material_id,
						)
						if surface_material_id == expected_surface_material_id {
							heightfield_surface_material_column_count += 1
						}
					}
				}

				for y in 0 ..< CHUNK_BLOCK_LENGTH {
					index = chunk_block_index(u32(x), u32(y), u32(z))
					if view.blocks.occupancy[index] == .Solid {
						heightfield_solid_count += 1
					}
				}
			}
		}
		log.assert(heightfield_solid_count > 0, "heightfield chunk: expected solid terrain")
		log.assert(
			heightfield_surface_column_count > 0,
			"heightfield chunk: expected at least one surface column in chunk",
		)
		log.assert(
			heightfield_surface_material_column_count > 0,
			"heightfield chunk: expected at least one uncarved biome surface material",
		)

		lower_heightfield_coord := world_async.ChunkCoord {
			heightfield_coord.x,
			heightfield_coord.y - 1,
			heightfield_coord.z,
		}
		terrain_heightfield_voxel_view_fill(&view, lower_heightfield_coord, heightfield_seed)
		lower_solid_count: u32
		for z in 0 ..< CHUNK_BLOCK_LENGTH {
			for y in 0 ..< CHUNK_BLOCK_LENGTH {
				for x in 0 ..< CHUNK_BLOCK_LENGTH {
					index = chunk_block_index(u32(x), u32(y), u32(z))
					if view.blocks.occupancy[index] == .Solid {
						lower_solid_count += 1
					}
				}
			}
		}
		log.assertf(
			lower_solid_count > CHUNK_BLOCK_COUNT / 4,
			"lower heightfield chunk: expected substantial solid terrain, got %d blocks",
			lower_solid_count,
		)

		cave_floor_offset := world_async.BlockCoord {
			x = 0,
			y = -1,
			z = 0,
		}
		cave_ceiling_offset := world_async.BlockCoord {
			x = 0,
			y = 1,
			z = 0,
		}
		cave_wall_offset := world_async.BlockCoord {
			x = 1,
			y = 0,
			z = 0,
		}
		log.assert(
			terrain_material_palette_index(
				terrain_cave_wall_material_id_for_neighbor(.Fungal_Vaults, cave_floor_offset),
			) ==
			TERRAIN_GRASS_MAT_ID,
			"fungal cave profile should use mossy floor material",
		)
		log.assert(
			terrain_material_palette_index(
				terrain_cave_wall_material_id_for_neighbor(.Fungal_Vaults, cave_ceiling_offset),
			) ==
			TERRAIN_DIRT_MAT_ID,
			"fungal cave profile should use earth ceiling material",
		)
		log.assert(
			terrain_material_palette_index(
				terrain_cave_wall_material_id_for_neighbor(
					.Crystal_Geode_Network,
					cave_floor_offset,
				),
			) ==
			TERRAIN_STONE_MAT_ID,
			"crystal cave profile should use stone floor material",
		)
		log.assert(
			terrain_material_palette_index(
				terrain_cave_wall_material_id_for_neighbor(
					.Crystal_Geode_Network,
					cave_ceiling_offset,
				),
			) ==
			TERRAIN_CRYSTAL_MAT_ID,
			"crystal cave profile should use crystal ceiling material",
		)
		log.assert(
			terrain_material_palette_index(
				terrain_cave_wall_material_id_for_neighbor(
					.Buried_Aquifer_Caves,
					cave_wall_offset,
				),
			) ==
			TERRAIN_AQUIFER_WALL_MAT_ID,
			"aquifer cave profile should use distinct side wall material",
		)

		chunk_voxel_view_fill_empty(&view)
		test_columns: [CHUNK_BLOCK_LENGTH * CHUNK_BLOCK_LENGTH]TerrainBiomeColumn
		for z in 0 ..< CHUNK_BLOCK_LENGTH {
			for x in 0 ..< CHUNK_BLOCK_LENGTH {
				test_columns[x + z * CHUNK_BLOCK_LENGTH] = {
					surface_height         = 64,
					surface_height_blocks  = 64,
					surface_material_id    = world_async.BlockMaterialID(TERRAIN_GRASS_MAT_ID),
					subsurface_material_id = world_async.BlockMaterialID(TERRAIN_STONE_MAT_ID),
				}
				for y in 0 ..< CHUNK_BLOCK_LENGTH {
					index = chunk_block_index(u32(x), u32(y), u32(z))
					view.blocks.occupancy[index] = .Solid
					view.blocks.material_id[index] = world_async.BlockMaterialID(
						TERRAIN_CORRUPTED_ASH_MAT_ID,
					)
				}
			}
		}
		aquifer_origin := world_async.BlockCoord {
			x = 0,
			y = -CHUNK_BLOCK_LENGTH,
			z = 0,
		}
		terrain_density_carve_cave_room(
			&view,
			heightfield_key,
			aquifer_origin,
			test_columns[:],
			16,
			-16,
			16,
			9,
			6,
			9,
			.Underground_Lake,
			.Buried_Aquifer_Caves,
		)
		aquifer_open_count: u32
		aquifer_water_count: u32
		aquifer_wall_count: u32
		aquifer_floor_count: u32
		aquifer_ceiling_count: u32
		aquifer_wall_material := terrain_cave_wall_material_id(.Buried_Aquifer_Caves)
		aquifer_floor_material := terrain_cave_floor_material_id(.Buried_Aquifer_Caves)
		aquifer_ceiling_material := terrain_cave_ceiling_material_id(.Buried_Aquifer_Caves)
		for z in 0 ..< CHUNK_BLOCK_LENGTH {
			for y in 0 ..< CHUNK_BLOCK_LENGTH {
				for x in 0 ..< CHUNK_BLOCK_LENGTH {
					index = chunk_block_index(u32(x), u32(y), u32(z))
					palette := terrain_material_palette_index(view.blocks.material_id[index])
					if view.blocks.occupancy[index] == .Empty {
						aquifer_open_count += 1
					}
					if palette == TERRAIN_WATER_MAT_ID {
						aquifer_water_count += 1
					}
					if palette == terrain_material_palette_index(aquifer_wall_material) {
						aquifer_wall_count += 1
					}
					if palette == terrain_material_palette_index(aquifer_floor_material) {
						aquifer_floor_count += 1
					}
					if palette == terrain_material_palette_index(aquifer_ceiling_material) {
						aquifer_ceiling_count += 1
					}
				}
			}
		}
		log.assertf(
			aquifer_open_count > 64,
			"aquifer cave room should carve explorable open volume, got %d",
			aquifer_open_count,
		)
		log.assert(
			aquifer_water_count > 0,
			"aquifer cave room should fill lower pockets with water",
		)
		log.assert(
			aquifer_wall_count > 0,
			"aquifer cave room should expose subterranean biome wall material",
		)
		log.assert(aquifer_floor_count > 0, "aquifer cave room should expose wet floor material")
		log.assert(
			aquifer_ceiling_count > 0,
			"aquifer cave room should expose stone ceiling material",
		)

		chunk_voxel_view_fill_empty(&view)
		for z in 0 ..< CHUNK_BLOCK_LENGTH {
			for x in 0 ..< CHUNK_BLOCK_LENGTH {
				test_columns[x + z * CHUNK_BLOCK_LENGTH] = {
					surface_height         = 64,
					surface_height_blocks  = 64,
					surface_material_id    = world_async.BlockMaterialID(TERRAIN_GRASS_MAT_ID),
					subsurface_material_id = world_async.BlockMaterialID(TERRAIN_STONE_MAT_ID),
				}
				for y in 0 ..< CHUNK_BLOCK_LENGTH {
					index = chunk_block_index(u32(x), u32(y), u32(z))
					view.blocks.occupancy[index] = .Solid
					view.blocks.material_id[index] = world_async.BlockMaterialID(
						TERRAIN_STONE_MAT_ID,
					)
				}
			}
		}
		passage_region := new(biomes.GenerationRegion)
		passage_region.key = heightfield_key
		passage_from_id := biomes.FeatureID(0x101)
		passage_to_id := biomes.FeatureID(0x202)
		passage_region.cave_network_node_count = 2
		passage_region.cave_network_nodes[0] = {
			id                       = passage_from_id,
			kind                     = .Chamber,
			role                     = .Major_Region,
			biome_id                 = .Fungal_Vaults,
			x                        = 4,
			y                        = -16,
			z                        = 16,
			radius_blocks            = 7,
			connection_radius_blocks = 4,
			major_region             = true,
		}
		passage_region.cave_network_nodes[1] = {
			id                       = passage_to_id,
			kind                     = .Geode_Chamber,
			role                     = .Resource_Chamber,
			biome_id                 = .Crystal_Geode_Network,
			x                        = 28,
			y                        = -15,
			z                        = 16,
			radius_blocks            = 6,
			connection_radius_blocks = 4,
		}
		passage_edge := biomes.CaveNetworkEdge {
			id            = biomes.FeatureID(0x303),
			kind          = .Canyon,
			from_node_id  = passage_from_id,
			to_node_id    = passage_to_id,
			from_biome_id = .Fungal_Vaults,
			to_biome_id   = .Crystal_Geode_Network,
			from_x        = 4,
			from_y        = -16,
			from_z        = 16,
			bend_x        = 16,
			bend_y        = -15,
			bend_z        = 16,
			to_x          = 28,
			to_y          = -15,
			to_z          = 16,
			radius_blocks = 3.4,
		}
		terrain_density_carve_cave_edge(
			&view,
			passage_region,
			aquifer_origin,
			test_columns[:],
			passage_edge,
		)
		passage_fungal_wall_count: u32
		passage_crystal_wall_count: u32
		passage_fungal_wall_material := terrain_cave_wall_material_id(.Fungal_Vaults)
		passage_crystal_wall_material := terrain_cave_wall_material_id(.Crystal_Geode_Network)
		for z in 0 ..< CHUNK_BLOCK_LENGTH {
			for y in 0 ..< CHUNK_BLOCK_LENGTH {
				for x in 0 ..< CHUNK_BLOCK_LENGTH {
					index = chunk_block_index(u32(x), u32(y), u32(z))
					palette := terrain_material_palette_index(view.blocks.material_id[index])
					if palette == terrain_material_palette_index(passage_fungal_wall_material) {
						passage_fungal_wall_count += 1
					}
					if palette == terrain_material_palette_index(passage_crystal_wall_material) {
						passage_crystal_wall_count += 1
					}
				}
			}
		}
		log.assert(
			passage_fungal_wall_count > 0,
			"cave edge should inherit the from-node subterranean biome material",
		)
		log.assert(
			passage_crystal_wall_count > 0,
			"cave edge should inherit the to-node subterranean biome material",
		)

		cave_region := new(biomes.GenerationRegion)
		biomes.generation_region_build_for_terrain_fill_into(
			cave_region,
			heightfield_key,
			biomes.GenerationRegionCoord{},
		)
		cave_node_found := false
		cave_local: world_async.BlockCoord
		cave_index: u32
		for i := u32(0); i < cave_region.cave_network_node_count; i += 1 {
			candidate := cave_region.cave_network_nodes[i]
			connectivity := terrain_density_cave_node_connectivity(cave_region, candidate)
			if !connectivity.should_carve {
				continue
			}
			candidate_center_block := world_async.BlockCoord {
				x = i32(math.floor_f32(candidate.x)),
				y = i32(math.floor_f32(candidate.y)),
				z = i32(math.floor_f32(candidate.z)),
			}
			candidate_chunk_coord := chunk_coord_from_block_coord(candidate_center_block)
			terrain_heightfield_voxel_view_fill(&view, candidate_chunk_coord, heightfield_seed)
			candidate_local := block_coord_local_from_chunk_coord(
				candidate_center_block,
				candidate_chunk_coord,
			)
			if !chunk_block_coord_is_inside(
				candidate_local.x,
				candidate_local.y,
				candidate_local.z,
			) {
				continue
			}
			candidate_index := chunk_block_index(
				u32(candidate_local.x),
				u32(candidate_local.y),
				u32(candidate_local.z),
			)
			candidate_palette := terrain_material_palette_index(
				view.blocks.material_id[candidate_index],
			)
			if view.blocks.occupancy[candidate_index] == .Empty ||
			   candidate_palette == TERRAIN_WATER_MAT_ID {
				cave_local = candidate_local
				cave_index = candidate_index
				cave_node_found = true
				break
			}
		}
		log.assert(
			cave_node_found,
			"cave node contract should find a generated carved Cave Network node",
		)
		log.assert(
			chunk_block_coord_is_inside(cave_local.x, cave_local.y, cave_local.z),
			"cave node center should map inside its generated chunk",
		)
		cave_palette := terrain_material_palette_index(view.blocks.material_id[cave_index])
		log.assertf(
			view.blocks.occupancy[cave_index] == .Empty || cave_palette == TERRAIN_WATER_MAT_ID,
			"cave node center should be carved or water-filled, occupancy=%v material=%d",
			view.blocks.occupancy[cave_index],
			cave_palette,
		)
		cave_open_count: u32
		for dz := i32(-4); dz <= 4; dz += 1 {
			for dy := i32(-4); dy <= 4; dy += 1 {
				for dx := i32(-4); dx <= 4; dx += 1 {
					lx := cave_local.x + dx
					ly := cave_local.y + dy
					lz := cave_local.z + dz
					if !chunk_block_coord_is_inside(lx, ly, lz) {
						continue
					}
					local_index := chunk_block_index(u32(lx), u32(ly), u32(lz))
					local_palette := terrain_material_palette_index(
						view.blocks.material_id[local_index],
					)
					if view.blocks.occupancy[local_index] == .Empty ||
					   local_palette == TERRAIN_WATER_MAT_ID {
						cave_open_count += 1
					}
				}
			}
		}
		log.assertf(
			cave_open_count > 12,
			"cave node room should carve a local volume, got %d open/water blocks",
			cave_open_count,
		)

		water_found := false
		for owner_z := i32(-2); owner_z <= 2 && !water_found; owner_z += 1 {
			for owner_x := i32(-2); owner_x <= 2 && !water_found; owner_x += 1 {
				water_node := biomes.water_feature_surface_node_from_owner(
					heightfield_key,
					biomes.FeatureGridCoord2{x = owner_x, z = owner_z},
				)
				water_block := world_async.BlockCoord {
					x = i32(math.floor_f32(water_node.x)),
					y = i32(math.floor_f32(water_node.water_level_blocks)),
					z = i32(math.floor_f32(water_node.z)),
				}
				water_chunk_coord := chunk_coord_from_block_coord(water_block)
				terrain_heightfield_voxel_view_fill(&view, water_chunk_coord, heightfield_seed)
				for z in 0 ..< CHUNK_BLOCK_LENGTH {
					for y in 0 ..< CHUNK_BLOCK_LENGTH {
						for x in 0 ..< CHUNK_BLOCK_LENGTH {
							index = chunk_block_index(u32(x), u32(y), u32(z))
							if view.blocks.occupancy[index] != .Solid {
								continue
							}
							if terrain_material_palette_index(view.blocks.material_id[index]) ==
							   TERRAIN_WATER_MAT_ID {
								water_found = true
								break
							}
						}
						if water_found {
							break
						}
					}
					if water_found {
						break
					}
				}
			}
		}
		log.assert(water_found, "surface hydrology should generate visible water blocks")

		chunk_voxel_view_fill_empty(&view)
		for z in 0 ..< CHUNK_BLOCK_LENGTH {
			for x in 0 ..< CHUNK_BLOCK_LENGTH {
				test_columns[x + z * CHUNK_BLOCK_LENGTH] = {}
				for y in 0 ..< CHUNK_BLOCK_LENGTH {
					index = chunk_block_index(u32(x), u32(y), u32(z))
					view.blocks.occupancy[index] = .Solid
					view.blocks.material_id[index] = world_async.BlockMaterialID(
						TERRAIN_STONE_MAT_ID,
					)
				}
			}
		}
		sealed_water_x := i32(8)
		sealed_water_z := i32(8)
		sealed_water_column_index := sealed_water_x + sealed_water_z * CHUNK_BLOCK_LENGTH
		test_columns[sealed_water_column_index] = {
			water_fill_active  = true,
			water_level_blocks = 50,
		}
		for y := i32(45); y <= 50; y += 1 {
			index = chunk_block_index(u32(sealed_water_x), u32(y), u32(sealed_water_z))
			view.blocks.occupancy[index] = .Empty
			view.blocks.material_id[index] = world_async.BlockMaterialID(0)
		}
		for y := i32(20); y <= 24; y += 1 {
			index = chunk_block_index(u32(sealed_water_x), u32(y), u32(sealed_water_z))
			view.blocks.occupancy[index] = .Empty
			view.blocks.material_id[index] = world_async.BlockMaterialID(0)
		}
		terrain_water_volume_fill(&view, world_async.BlockCoord{}, test_columns[:])
		surface_water_index := chunk_block_index(u32(sealed_water_x), u32(50), u32(sealed_water_z))
		sealed_cave_index := chunk_block_index(u32(sealed_water_x), u32(22), u32(sealed_water_z))
		log.assert(
			terrain_material_palette_index(view.blocks.material_id[surface_water_index]) ==
			TERRAIN_WATER_MAT_ID,
			"surface water volume fill should fill open space above the first solid roof",
		)
		log.assert(
			view.blocks.occupancy[sealed_cave_index] == .Empty,
			"surface water volume fill should not flood sealed underground cave pockets",
		)

		chunk_voxel_view_fill_empty(&view)
		for z in 0 ..< CHUNK_BLOCK_LENGTH {
			for x in 0 ..< CHUNK_BLOCK_LENGTH {
				test_columns[x + z * CHUNK_BLOCK_LENGTH] = {}
				for y in 0 ..< CHUNK_BLOCK_LENGTH {
					index = chunk_block_index(u32(x), u32(y), u32(z))
					view.blocks.occupancy[index] = .Solid
					view.blocks.material_id[index] = world_async.BlockMaterialID(
						TERRAIN_STONE_MAT_ID,
					)
				}
			}
		}
		undercut_water_x := i32(11)
		undercut_water_z := i32(11)
		undercut_column_index := undercut_water_x + undercut_water_z * CHUNK_BLOCK_LENGTH
		undercut_surface_y := i32(CHUNK_BLOCK_LENGTH - 8)
		undercut_water_level_y := i32(CHUNK_BLOCK_LENGTH - 2)
		test_columns[undercut_column_index] = {
			surface_height_blocks = f32(undercut_surface_y),
			water_fill_active     = true,
			water_level_blocks    = f32(undercut_water_level_y),
		}
		for y := i32(0); y <= undercut_water_level_y; y += 1 {
			index = chunk_block_index(u32(undercut_water_x), u32(y), u32(undercut_water_z))
			view.blocks.occupancy[index] = .Empty
			view.blocks.material_id[index] = world_async.BlockMaterialID(0)
		}
		terrain_water_volume_fill(&view, world_async.BlockCoord{}, test_columns[:])
		undercut_surface_water_index := chunk_block_index(
			u32(undercut_water_x),
			u32(undercut_water_level_y),
			u32(undercut_water_z),
		)
		undercut_gate_y := terrain_water_volume_surface_gate_world_y(
			test_columns[undercut_column_index],
		)
		log.assert(
			undercut_gate_y > 0,
			"undercut water contract expects the surface gate to fall inside the test chunk",
		)
		undercut_deep_index := chunk_block_index(
			u32(undercut_water_x),
			u32(undercut_gate_y - 1),
			u32(undercut_water_z),
		)
		log.assert(
			terrain_material_palette_index(
				view.blocks.material_id[undercut_surface_water_index],
			) ==
			TERRAIN_WATER_MAT_ID,
			"surface water volume fill should still fill the surface-adjacent open band",
		)
		log.assert(
			view.blocks.occupancy[undercut_deep_index] == .Empty,
			"surface water volume fill should not flood exposed cavities below the surface band",
		)

		chunk_voxel_view_fill_empty(&view)
		for z in 0 ..< CHUNK_BLOCK_LENGTH {
			for x in 0 ..< CHUNK_BLOCK_LENGTH {
				test_columns[x + z * CHUNK_BLOCK_LENGTH] = {
					surface_height        = 16,
					surface_height_blocks = 16,
				}
				index = chunk_block_index(u32(x), 16, u32(z))
				view.blocks.occupancy[index] = .Solid
				view.blocks.material_id[index] = world_async.BlockMaterialID(TERRAIN_STONE_MAT_ID)
			}
		}
		normal_water_x := i32(20)
		lava_water_x := i32(21)
		mixed_water_z := i32(20)
		normal_water_column := normal_water_x + mixed_water_z * CHUNK_BLOCK_LENGTH
		lava_water_column := lava_water_x + mixed_water_z * CHUNK_BLOCK_LENGTH
		test_columns[normal_water_column].dominant_biome_id = .Temperate_Hills
		test_columns[normal_water_column].water_biome_id = .Temperate_Hills
		test_columns[normal_water_column].water_fill_active = true
		test_columns[normal_water_column].water_level_blocks = 24
		test_columns[lava_water_column].dominant_biome_id = .Emberglass_Badlands
		test_columns[lava_water_column].water_biome_id = .Emberglass_Badlands
		test_columns[lava_water_column].water_fill_active = true
		test_columns[lava_water_column].water_level_blocks = 24
		terrain_water_volume_fill(&view, world_async.BlockCoord{}, test_columns[:])
		normal_border_index := chunk_block_index(u32(normal_water_x), 24, u32(mixed_water_z))
		lava_border_index := chunk_block_index(u32(lava_water_x), 24, u32(mixed_water_z))
		log.assert(
			terrain_material_palette_index(view.blocks.material_id[normal_border_index]) !=
				TERRAIN_WATER_MAT_ID &&
			terrain_material_palette_index(view.blocks.material_id[lava_border_index]) !=
				TERRAIN_WATER_MAT_ID,
			"different surface water materials must not touch without a terrain separator",
		)
		debug_terrain_generation_quality_contract_checks_run(heightfield_key)

		terrain_heightfield_voxel_view_fill(&view, heightfield_coord, heightfield_seed)

		heightfield_output := chunk_voxel_view_build_binary_greedy_mesh(
			view,
			.Treat_Out_Of_Chunk_As_Empty,
			allocator,
			scratch,
		)
		log.assertf(
			heightfield_output.face_count > 0,
			"greedy heightfield: expected non-empty output",
		)
		top_face_count: u32
		for face_index in 0 ..< heightfield_output.face_count {
			vertex := terrain_unpack_vertex(heightfield_output.vertices[face_index * 4])

			if vertex.normal_id != 2 {
				continue
			}
			top_face_count += 1

			log.assertf(
				vertex.block_x < CHUNK_BLOCK_LENGTH && vertex.block_z < CHUNK_BLOCK_LENGTH,
				"heightfield top face %d: local x/z out of column range: %d,%d",
				face_index,
				vertex.block_x,
				vertex.block_z,
			)

			log.assertf(
				(vertex.material_id & (TERRAIN_MATERIAL_PALETTE_COUNT - 1)) <
				TERRAIN_MATERIAL_PALETTE_COUNT,
				"heightfield face %d: material out of palette range: %d",
				face_index,
				vertex.material_id,
			)
		}
		log.assert(top_face_count > 0, "greedy heightfield: expected at least one top face")

		log.debug("Chunk mesher contract checks passed")
	}

	debug_chunk_edit_contract_checks_run :: proc(transient_arena: ^mem.Arena) {
		log.assert(state.initialized, "chunk edit checks require initialized world state")
		log.assertf(
			state.chunk_store.chunk_count == 0,
			"chunk edit checks expect an empty chunk store, got %d chunks",
			state.chunk_store.chunk_count,
		)

		proxy_id := chunk_store_append_reserved({-1, 0, 0})
		proxy := chunk_store_get_by_id(proxy_id)
		proxy_storage := chunk_block_storage_alloc_for_store()
		chunk_mark_generated(proxy, proxy_storage, .Proxy)
		proxy.mesh_state = .Ready
		proxy.dirty_flags = {}
		chunk_dirty_region_clear(proxy)
		proxy_block := world_async.BlockCoord{-CHUNK_BLOCK_LENGTH + 1, 2, 3}
		proxy_applied := chunk_store_block_edit_apply(
			proxy_block,
			.Solid,
			world_async.BlockMaterialID(5),
		)
		log.assert(!proxy_applied, "block edits must not apply to proxy chunks")
		proxy_sample, proxy_sample_ok := chunk_store_block_get(proxy_block).?
		log.assert(proxy_sample_ok, "proxy chunk should remain readable after rejected edit")
		log.assert(
			proxy_sample.occupancy == .Empty,
			"rejected proxy edit should leave proxy block unchanged",
		)
		chunk_store_remove_at(0)
		log.assert(state.chunk_store.chunk_count == 0, "proxy edit check should clean up chunk")

		left_id := chunk_store_append_reserved({0, 0, 0})
		left := chunk_store_get_by_id(left_id)
		left_storage := chunk_block_storage_alloc_for_store()
		chunk_mark_generated(left, left_storage)
		left.mesh_state = .Ready
		left.dirty_flags = {}
		chunk_dirty_region_clear(left)
		{
			temp := mem.begin_arena_temp_memory(transient_arena)
			allocator := mem.arena_allocator(transient_arena)
			scratch := terrain_binary_greedy_scratch_alloc(transient_arena)
			seed_index := chunk_block_index(8, 8, 8)
			left.block_storage.voxel_view.blocks.occupancy[seed_index] = .Solid
			left.block_storage.voxel_view.blocks.material_id[seed_index] =
				world_async.BlockMaterialID(TERRAIN_STONE_MAT_ID)
			if left.block_storage.binary_greedy_row_cache != nil {
				terrain_binary_row_cache_fill(
					left.block_storage.binary_greedy_row_cache,
					left.block_storage.voxel_view,
					left.block_version,
				)
			}
			full_output := chunk_voxel_view_build_binary_greedy_mesh(
				left.block_storage.voxel_view,
				.Treat_Out_Of_Chunk_As_Empty,
				allocator,
				scratch,
			)
			left.geometry_id = state.chunk_mesh_upload(left.geometry_id, full_output)
			mem.end_arena_temp_memory(temp)
		}
		log.assert(
			left.geometry_id != INVALID_CHUNK_GEOMETRY_ID,
			"edit contract should start with drawable full chunk geometry",
		)

		right_id := chunk_store_append_reserved({1, 0, 0})
		right := chunk_store_get_by_id(right_id)
		right_storage := chunk_block_storage_alloc_for_store()
		chunk_mark_generated(right, right_storage)
		right.mesh_state = .Ready
		right.dirty_flags = {}
		chunk_dirty_region_clear(right)

		interior_block := world_async.BlockCoord{1, 2, 3}
		applied := chunk_store_block_edit_apply(
			interior_block,
			.Solid,
			world_async.BlockMaterialID(5),
		)
		log.assert(applied, "interior block edit should apply")

		sample, sample_ok := chunk_store_block_get(interior_block).?
		log.assert(sample_ok, "edited interior block should be readable")
		log.assert(sample.occupancy == .Solid, "edited interior block should be solid")
		log.assert(
			sample.material_id == world_async.BlockMaterialID(5),
			"edited interior block material mismatch",
		)
		log.assert(left.mesh_state == .Dirty, "interior edit should dirty owning chunk")
		log.assert(.Blocks in left.dirty_flags, "interior edit should set Blocks dirty flag")
		log.assert(left.dirty_region.valid, "interior edit should create dirty region")
		log.assert(
			left.dirty_region.min == world_async.BlockCoord{0, 1, 2} &&
			left.dirty_region.max == world_async.BlockCoord{3, 4, 5},
			"interior edit dirty region mismatch",
		)
		interior_dirty_mask := chunk_dirty_region_subchunk_mask(left.dirty_region)
		log.assertf(
			interior_dirty_mask ==
			chunk_subchunk_mask_from_index(chunk_subchunk_index_from_coord(0, 0, 0)),
			"interior edit subchunk mask mismatch: %x",
			interior_dirty_mask,
		)
		log.assertf(
			left.subchunk_dirty_mask == CHUNK_SUBCHUNK_ALL_MASK,
			"first edit of full chunk should queue all subchunks for transition, got %x",
			left.subchunk_dirty_mask,
		)
		log.assert(
			left.block_storage.binary_greedy_row_cache != nil &&
			left.block_storage.binary_greedy_row_cache.block_version == left.block_version,
			"interior edit should keep binary row cache version current",
		)

		state.streaming_center_coord = {999, 0, 999}
		submitted := mesh_request_budgeted()
		log.assertf(submitted == 1, "expected one subchunk mesh job, got %d", submitted)
		queued_subchunk_index := left.queued_subchunk_index
		log.assertf(
			queued_subchunk_index == chunk_subchunk_index_from_coord(0, 0, 0),
			"expected first queued subchunk 0, got %d",
			queued_subchunk_index,
		)
		commit_stats := ChunkMeshBatchStats{}
		for attempt := 0; attempt < 1000 && commit_stats.chunks_committed == 0; attempt += 1 {
			commit_stats = mesh_results_poll_budgeted()
			if commit_stats.chunks_committed == 0 {
				time.sleep(time.Millisecond)
			}
		}
		log.assertf(
			commit_stats.chunks_committed == 1,
			"expected one committed subchunk result, got %d",
			commit_stats.chunks_committed,
		)
		log.assert(
			(left.subchunk_ready_mask & chunk_subchunk_mask_from_index(queued_subchunk_index)) !=
			0,
			"committed subchunk should be marked ready",
		)
		log.assert(
			left.geometry_id != INVALID_CHUNK_GEOMETRY_ID,
			"full chunk geometry should stay active until all subchunks are ready",
		)

		left.mesh_state = .Ready
		left.dirty_flags = {}
		chunk_dirty_region_clear(left)
		chunk_subchunk_geometry_release_all(left)
		right.mesh_state = .Ready
		right.dirty_flags = {}
		chunk_dirty_region_clear(right)

		boundary_block := world_async.BlockCoord{CHUNK_BLOCK_LOCAL_MAX, 2, 3}
		boundary_applied := chunk_store_block_edit_apply(
			boundary_block,
			.Solid,
			world_async.BlockMaterialID(6),
		)
		log.assert(boundary_applied, "boundary block edit should apply")
		log.assert(left.mesh_state == .Dirty, "boundary edit should dirty owning chunk")
		log.assert(right.mesh_state == .Dirty, "boundary edit should dirty neighboring chunk")
		log.assert(
			.Boundary in right.dirty_flags,
			"boundary edit should set neighbor Boundary flag",
		)
		log.assert(
			right.dirty_region.valid &&
			right.dirty_region.min == world_async.BlockCoord{0, 2, 3} &&
			right.dirty_region.max == world_async.BlockCoord{1, 3, 4},
			"neighbor boundary dirty region mismatch",
		)
		left_boundary_mask := chunk_dirty_region_subchunk_mask(left.dirty_region)
		right_boundary_mask := chunk_dirty_region_subchunk_mask(right.dirty_region)
		log.assertf(
			left_boundary_mask ==
			chunk_subchunk_mask_from_index(chunk_subchunk_index_from_coord(3, 0, 0)),
			"owner boundary edit subchunk mask mismatch: %x",
			left_boundary_mask,
		)
		log.assertf(
			right_boundary_mask ==
			chunk_subchunk_mask_from_index(chunk_subchunk_index_from_coord(0, 0, 0)),
			"neighbor boundary edit subchunk mask mismatch: %x",
			right_boundary_mask,
		)

		snapshot := chunk_snapshot_from_chunk(left)
		log.assert(snapshot.dirty_region.valid, "snapshot should carry dirty region")
		log.assert(
			snapshot.binary_greedy_row_cache != nil &&
			snapshot.binary_greedy_row_cache.block_version == snapshot.block_version,
			"snapshot should carry current binary row cache",
		)

		chunk_store_clear()
		streaming_reset()
		log.debug("Chunk edit contract checks passed")
	}
}
