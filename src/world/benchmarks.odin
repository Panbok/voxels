package world

import biomes "world:biomes"
import world_async "async:world"

import "core:log"
import "core:math"
import "core:mem"
import time "core:time"

//////////////////////////////////////
// Benchmarking
/////////////////////////////////////

when ODIN_DEBUG {

	RUN_MESH_BENCHMARK :: #config(RUN_MESH_BENCHMARK, false)
	MESH_BENCHMARK_ITERATIONS :: #config(MESH_BENCHMARK_ITERATIONS, 8)
	RUN_TERRAIN_GENERATION_BENCHMARK :: #config(RUN_TERRAIN_GENERATION_BENCHMARK, false)
	TERRAIN_GENERATION_BENCHMARK_ITERATIONS :: #config(TERRAIN_GENERATION_BENCHMARK_ITERATIONS, 1)
	TERRAIN_GENERATION_BENCHMARK_RESET_CACHE :: #config(TERRAIN_GENERATION_BENCHMARK_RESET_CACHE, false)
	TERRAIN_GENERATION_BENCHMARK_COORD_COUNT :: 8
	TERRAIN_GENERATION_BENCHMARK_BIOME_OWNER_SCAN_RADIUS_XZ :: 4
	TERRAIN_GENERATION_BENCHMARK_CAVE_FIELD_PATH_NEIGHBOR_RADIUS :: 1
	TERRAIN_GENERATION_BENCHMARK_SURFACE_CAVE_OWNER_SCAN_RADIUS_XZ :: 8
	TERRAIN_GENERATION_BENCHMARK_LEGACY_SURFACE_ANCHOR_EMIT_ROLL_MAX :: f32(0.42)
	TERRAIN_GENERATION_BENCHMARK_LEGACY_SURFACE_CAVE_MOUTH_ROLL_MAX :: f32(0.62)
	TERRAIN_GENERATION_BENCHMARK_BIOME_OWNER_SCAN_Y_MIN :: -2
	TERRAIN_GENERATION_BENCHMARK_BIOME_OWNER_SCAN_Y_MAX :: 0
	TERRAIN_GENERATION_BENCHMARK_TINY_CAVE_COMPONENT_NODE_MAX :: u32(3)
	TERRAIN_GENERATION_BENCHMARK_SURFACE_CAVE_SCAN_SEED_COUNT :: u32(4)

	chunk_mesher_benchmarks_debug_contracts_run :: proc(transient_arena: ^mem.Arena) {
		log.assert(transient_arena != nil, "benchmark transient arena must not be nil")
		_ = world_async.ChunkVoxelView{}
		_ = time.Duration(0)
		_ = biomes.GenerationRegionCoord{}
		_ = math.abs(f32(0))
	}

	when RUN_MESH_BENCHMARK {

		ChunkMesherBenchmarkCase :: struct {
			name:         string,
			view:         world_async.ChunkVoxelView,
			run_build:    bool,
			face_count:   u32,
			output_bytes: u32,
		}

		chunk_mesher_benchmark_fill_full :: proc(view: ^world_async.ChunkVoxelView) {
			chunk_voxel_view_fill_empty(view)
			for z in 0 ..< CHUNK_BLOCK_LENGTH {
				for y in 0 ..< CHUNK_BLOCK_LENGTH {
					for x in 0 ..< CHUNK_BLOCK_LENGTH {
						index := chunk_block_index(u32(x), u32(y), u32(z))
						view.blocks.occupancy[index] = .Solid
						view.blocks.material_id[index] = world_async.BlockMaterialID(
							TERRAIN_STONE_MAT_ID,
						)
					}
				}
			}
		}

		chunk_mesher_benchmark_fill_checkerboard :: proc(view: ^world_async.ChunkVoxelView) {
			chunk_voxel_view_fill_empty(view)
			for z in 0 ..< CHUNK_BLOCK_LENGTH {
				for y in 0 ..< CHUNK_BLOCK_LENGTH {
					for x in 0 ..< CHUNK_BLOCK_LENGTH {
						if ((x + y + z) & 1) != 0 {
							continue
						}

						index := chunk_block_index(u32(x), u32(y), u32(z))
						view.blocks.occupancy[index] = .Solid
						view.blocks.material_id[index] = world_async.BlockMaterialID(
							TERRAIN_STONE_MAT_ID,
						)
					}
				}
			}
		}

		chunk_mesher_benchmark_count_once :: proc(
			view: world_async.ChunkVoxelView,
			mesher: world_async.ChunkMeshing,
			scratch: ^TerrainBinaryGreedyScratch,
		) -> u32 {
			switch mesher {
			case .Greedy_Binary:
				return chunk_voxel_view_count_binary_greedy_faces(
					view,
					.Treat_Out_Of_Chunk_As_Empty,
					scratch,
				)
			}

			log.assertf(false, "unhandled benchmark mesher: %v", mesher)
			return 0
		}

		chunk_mesher_benchmark_build_once :: proc(
			view: world_async.ChunkVoxelView,
			mesher: world_async.ChunkMeshing,
			allocator: mem.Allocator,
			scratch: ^TerrainBinaryGreedyScratch,
		) -> world_async.ChunkMeshOutput {
			switch mesher {
			case .Greedy_Binary:
				return chunk_voxel_view_build_binary_greedy_mesh(
					view,
					.Treat_Out_Of_Chunk_As_Empty,
					allocator,
					scratch,
				)
			}

			log.assertf(false, "unhandled benchmark mesher: %v", mesher)
			return {}
		}

		chunk_mesher_benchmark_mesher_name :: proc(mesher: world_async.ChunkMeshing) -> string {
			switch mesher {
			case .Greedy_Binary:
				return "binary_greedy"
			}

			return "unknown"
		}

		chunk_mesher_benchmark_log_result :: proc(
			case_name, phase: string,
			mesher: world_async.ChunkMeshing,
			iterations: u32,
			duration: time.Duration,
			face_count: u32,
			output_bytes: u32,
		) {
			total_ms := time.duration_milliseconds(duration)
			avg_us := time.duration_microseconds(duration) / f64(iterations)
			log.infof(
				"MESH_BENCH case=%s phase=%s mesher=%s iterations=%d total_ms=%.3f avg_us=%.3f faces=%d output_bytes=%d",
				case_name,
				phase,
				chunk_mesher_benchmark_mesher_name(mesher),
				iterations,
				total_ms,
				avg_us,
				face_count,
				output_bytes,
			)
		}

		chunk_mesher_benchmark_count_run :: proc(
			case_data: ChunkMesherBenchmarkCase,
			mesher: world_async.ChunkMeshing,
			iterations: u32,
			transient_arena: ^mem.Arena,
		) {
			log.assertf(iterations > 0, "benchmark iterations must be greater than zero")

			// Warm the instruction/data path before taking the timed sample.
			warmup_temp := mem.begin_arena_temp_memory(transient_arena)
			warmup_allocator := mem.arena_allocator(transient_arena)
			warmup_scratch := terrain_binary_greedy_scratch_alloc(warmup_allocator)
			_ = chunk_mesher_benchmark_count_once(case_data.view, mesher, warmup_scratch)
			mem.end_arena_temp_memory(warmup_temp)

			face_count: u32
			start := time.tick_now()
			for _ in 0 ..< iterations {
				temp := mem.begin_arena_temp_memory(transient_arena)
				allocator := mem.arena_allocator(transient_arena)
				scratch := terrain_binary_greedy_scratch_alloc(allocator)
				face_count = chunk_mesher_benchmark_count_once(case_data.view, mesher, scratch)
				mem.end_arena_temp_memory(temp)
			}
			duration := time.tick_since(start)

			chunk_mesher_benchmark_log_result(
				case_data.name,
				"count",
				mesher,
				iterations,
				duration,
				face_count,
				0,
			)
		}

		chunk_mesher_benchmark_build_run :: proc(
			case_data: ChunkMesherBenchmarkCase,
			mesher: world_async.ChunkMeshing,
			iterations: u32,
			transient_arena: ^mem.Arena,
		) {
			log.assertf(iterations > 0, "benchmark iterations must be greater than zero")

			warmup_temp := mem.begin_arena_temp_memory(transient_arena)
			warmup_allocator := mem.arena_allocator(transient_arena)
			warmup_scratch := terrain_binary_greedy_scratch_alloc(warmup_allocator)
			_ = chunk_mesher_benchmark_build_once(
				case_data.view,
				mesher,
				warmup_allocator,
				warmup_scratch,
			)
			mem.end_arena_temp_memory(warmup_temp)

			face_count: u32
			output_bytes: u32
			start := time.tick_now()
			for _ in 0 ..< iterations {
				temp := mem.begin_arena_temp_memory(transient_arena)
				allocator := mem.arena_allocator(transient_arena)
				scratch := terrain_binary_greedy_scratch_alloc(allocator)
				output := chunk_mesher_benchmark_build_once(
					case_data.view,
					mesher,
					allocator,
					scratch,
				)
				face_count = output.face_count
				output_bytes =
					u32(len(output.vertices) * size_of(world_async.TerrainPackedVertex)) +
					u32(len(output.indices) * size_of(u32))
				mem.end_arena_temp_memory(temp)
			}
			duration := time.tick_since(start)

			chunk_mesher_benchmark_log_result(
				case_data.name,
				"build",
				mesher,
				iterations,
				duration,
				face_count,
				output_bytes,
			)
		}

		chunk_mesher_benchmark_subchunk_build_run :: proc(
			case_name: string,
			view: world_async.ChunkVoxelView,
			subchunk_index: u32,
			iterations: u32,
			transient_arena: ^mem.Arena,
		) {
			log.assertf(iterations > 0, "benchmark iterations must be greater than zero")
			min_bound, max_bound := chunk_subchunk_bounds_from_index(subchunk_index)

			warmup_temp := mem.begin_arena_temp_memory(transient_arena)
			warmup_allocator := mem.arena_allocator(transient_arena)
			warmup_scratch := terrain_binary_greedy_scratch_alloc(warmup_allocator)
			_ = chunk_voxel_view_build_binary_greedy_mesh_in_bounds(
				view,
				min_bound,
				max_bound,
				.Treat_Out_Of_Chunk_As_Empty,
				warmup_allocator,
				warmup_scratch,
			)
			mem.end_arena_temp_memory(warmup_temp)

			face_count: u32
			output_bytes: u32
			start := time.tick_now()
			for _ in 0 ..< iterations {
				temp := mem.begin_arena_temp_memory(transient_arena)
				allocator := mem.arena_allocator(transient_arena)
				scratch := terrain_binary_greedy_scratch_alloc(allocator)
				output := chunk_voxel_view_build_binary_greedy_mesh_in_bounds(
					view,
					min_bound,
					max_bound,
					.Treat_Out_Of_Chunk_As_Empty,
					allocator,
					scratch,
				)
				face_count = output.face_count
				output_bytes =
					u32(len(output.vertices) * size_of(world_async.TerrainPackedVertex)) +
					u32(len(output.indices) * size_of(u32))
				mem.end_arena_temp_memory(temp)
			}
			duration := time.tick_since(start)

			chunk_mesher_benchmark_log_result(
				case_name,
				"subchunk_build",
				.Greedy_Binary,
				iterations,
				duration,
				face_count,
				output_bytes,
			)
		}

		chunk_mesher_benchmark_run_case :: proc(
			case_data: ChunkMesherBenchmarkCase,
			iterations: u32,
			transient_arena: ^mem.Arena,
		) {
			meshers := [?]world_async.ChunkMeshing{.Greedy_Binary}
			for mesher in meshers {
				chunk_mesher_benchmark_count_run(case_data, mesher, iterations, transient_arena)
				if case_data.run_build {
					chunk_mesher_benchmark_build_run(
						case_data,
						mesher,
						iterations,
						transient_arena,
					)
				}
			}
		}

		chunk_mesher_benchmark_runs_run :: proc(transient_arena: ^mem.Arena, iterations: u32) {
			log.assertf(iterations > 0, "benchmark iterations must be greater than zero")

			temp := mem.begin_arena_temp_memory(transient_arena)
			defer mem.end_arena_temp_memory(temp)
			allocator := mem.arena_allocator(transient_arena)

			heightfield := world_async.ChunkVoxelView{}
			chunk_voxel_view_alloc(&heightfield, allocator)
			terrain_heightfield_voxel_view_fill(&heightfield, world_async.ChunkCoord{0, 0, 0}, 0)

			rect := world_async.ChunkVoxelView{}
			chunk_voxel_view_debug_rect_build(&rect, allocator)

			full := world_async.ChunkVoxelView{}
			chunk_voxel_view_alloc(&full, allocator)
			chunk_mesher_benchmark_fill_full(&full)

			checkerboard := world_async.ChunkVoxelView{}
			chunk_voxel_view_alloc(&checkerboard, allocator)
			chunk_mesher_benchmark_fill_checkerboard(&checkerboard)

			cases := [?]ChunkMesherBenchmarkCase {
				{name = "heightfield", view = heightfield, run_build = true},
				{name = "solid_rect", view = rect, run_build = true},
				{name = "full_chunk", view = full, run_build = true},
				{name = "checkerboard_count_only", view = checkerboard, run_build = false},
			}

			log.infof(
				"MESH_BENCH_START iterations=%d chunk_blocks=%d",
				iterations,
				CHUNK_BLOCK_COUNT,
			)
			for case_data in cases {
				chunk_mesher_benchmark_run_case(case_data, iterations, transient_arena)
			}
			chunk_mesher_benchmark_subchunk_build_run(
				"heightfield_subchunk",
				heightfield,
				chunk_subchunk_index_from_coord(1, 1, 1),
				iterations,
				transient_arena,
			)
			log.info("MESH_BENCH_END")
		}

	}

	when RUN_TERRAIN_GENERATION_BENCHMARK {

		TerrainGenerationBenchmarkCoords :: [TERRAIN_GENERATION_BENCHMARK_COORD_COUNT]world_async.ChunkCoord

		TerrainGenerationBenchmarkSurfaceWaterStats :: struct {
			column_count:                  u32,
			local_water_feature_columns:  u32,
			local_water_below_columns:    u32,
			local_water_fill_columns:     u32,
			local_water_gap_columns:      u32,
			sea_fill_columns:             u32,
			basin_columns:                u32,
			channel_columns:              u32,
			anchor_columns:               u32,
			max_water_influence:          f32,
			max_unfilled_water_influence: f32,
			max_unfilled_water_depth:     f32,
			max_floor_depression_blocks:  f32,
			shore_columns:                u32,
			shore_wet_surface_columns:    u32,
			shore_grass_surface_columns:  u32,
			shore_low_columns:            u32,
			shore_mid_columns:            u32,
			shore_upper_columns:          u32,
			shore_low_green_columns:      u32,
			shore_mid_green_columns:      u32,
			shore_upper_green_columns:    u32,
			min_surface_height_blocks:     f32,
			max_surface_height_blocks:     f32,
			top_soft_zone_columns:         u32,
			bottom_soft_zone_columns:      u32,
		}

		TerrainGenerationBenchmarkSurfaceCaveAnchors :: struct {
			mouth:             biomes.CaveAnchor,
			sinkhole:          biomes.CaveAnchor,
			mouth_small:       biomes.CaveAnchor,
			mouth_medium:      biomes.CaveAnchor,
			mouth_large:       biomes.CaveAnchor,
			mouth_node:        biomes.CaveNetworkNode,
			sinkhole_node:     biomes.CaveNetworkNode,
			mouth_small_node:  biomes.CaveNetworkNode,
			mouth_medium_node: biomes.CaveNetworkNode,
			mouth_large_node:  biomes.CaveNetworkNode,
			mouth_found:       bool,
			sinkhole_found:    bool,
			mouth_small_found: bool,
			mouth_medium_found: bool,
			mouth_large_found: bool,
		}

		TerrainGenerationBenchmarkSurfaceCaveStats :: struct {
			selected_anchor_count: u32,
			mouth_count:          u32,
			sinkhole_count:       u32,
			open_anchor_count:    u32,
			sealed_anchor_count:  u32,
			open_blocks:          u32,
			mouth_open_blocks:    u32,
			sinkhole_open_blocks: u32,
			mouth_aperture_open_blocks: u32,
			mouth_throat_open_blocks:   u32,
			mouth_inner_open_blocks:    u32,
			mouth_outer_carve_open_blocks: u32,
			mouth_lower_center_open_blocks: u32,
			mouth_lower_side_band_open_blocks: u32,
			mouth_side_pocket_open_blocks: u32,
			sinkhole_upper_center_open_blocks: u32,
			sinkhole_upper_ledge_open_blocks:  u32,
			sinkhole_upper_outer_open_blocks:  u32,
			sinkhole_upper_side_band_open_blocks: u32,
			sinkhole_upper_end_band_open_blocks:  u32,
			water_blocks:         u32,
			solid_blocks:         u32,
			near_surface_open:    u32,
			sub_surface_open:     u32,
			max_open_depth:       i32,
			min_open_blocks:      u32,
			mouth_link_horizontal_blocks: f32,
			mouth_link_vertical_blocks:   f32,
			mouth_link_drop_per_run:      f32,
			mouth_bend_horizontal_blocks: f32,
			mouth_bend_vertical_blocks:   f32,
			mouth_bend_drop_per_run:      f32,
			mouth_handoff_horizontal_blocks: f32,
			mouth_handoff_vertical_blocks:   f32,
			mouth_handoff_drop_per_run:      f32,
		}

		TerrainGenerationBenchmarkSurfaceCaveScanStats :: struct {
			owner_count:            u32,
			legacy_emit_count:      u32,
			current_emit_count:     u32,
			additional_emit_count:  u32,
			legacy_mouth_count:     u32,
			legacy_sinkhole_count:  u32,
			current_mouth_count:    u32,
			current_sinkhole_count: u32,
			current_mouth_small_count:  u32,
			current_mouth_medium_count: u32,
			current_mouth_large_count:  u32,
			current_mouth_vestibule_count: u32,
			current_mouth_shallow_transition_count: u32,
			current_mouth_steep_transition_count:   u32,
			current_mouth_raw_vertical_count:       u32,
			current_mouth_sloped_tube_count:        u32,
			current_mouth_curved_ramp_count:        u32,
			current_mouth_spiral_ramp_count:        u32,
			current_anchor_component_tiny_count:    u32,
			current_mouth_component_tiny_count:     u32,
			current_sinkhole_component_tiny_count:  u32,
			current_anchor_component_missing_count: u32,
			current_anchor_component_external_link_count: u32,
			current_anchor_component_max_nodes:     u32,
			current_mouth_radius_total:             f32,
			current_mouth_radius_max:               f32,
			guaranteed_count:       u32,
			vertical_count:         u32,
		}

		TerrainGenerationBenchmarkCavePhysicalStats :: struct {
			chunk_count:                 u32,
			open_blocks:                 u32,
			water_blocks:                u32,
			solid_blocks:                u32,
			open_core_6_blocks:          u32,
			open_core_27_blocks:         u32,
			exposed_solid_blocks:        u32,
			exposed_grass_blocks:        u32,
			exposed_dirt_blocks:         u32,
			exposed_stone_blocks:        u32,
			exposed_wet_blocks:          u32,
			exposed_ash_blocks:          u32,
			exposed_aquifer_wall_blocks: u32,
			exposed_crystal_blocks:      u32,
			exposed_fungal_floor_blocks:   u32,
			exposed_fungal_ceiling_blocks: u32,
			cave_biome_exposed_blocks:   u32,
			open_neighbor_low_blocks:     u32,
			open_neighbor_mid_blocks:     u32,
			open_neighbor_high_blocks:    u32,
			chamber_span_blocks:          u32,
			narrow_span_blocks:           u32,
			axis_span_x_total:            u32,
			axis_span_y_total:            u32,
			axis_span_z_total:            u32,
			max_open_core_27_per_chunk:  u32,
			min_open_core_27_per_chunk:  u32,
			max_exposed_biome_per_chunk: u32,
			min_exposed_biome_per_chunk: u32,
		}

		TerrainGenerationBenchmarkCaveFieldStats :: struct {
			chunk_count:             u32,
			candidate_count:         u32,
			path_candidate_count:    u32,
			chamber_candidate_count: u32,
			stamp_count:             u32,
			path_stamp_count:        u32,
			route_pocket_stamp_count: u32,
			chamber_stamp_count:     u32,
			network_connected_candidate_count: u32,
			network_bridge_candidate_count:    u32,
			network_culled_candidate_count:    u32,
			network_bridge_stamp_count:        u32,
			route_pocket_candidate_count:      u32,
			route_promoted_path_candidate_count: u32,
			route_promoted_path_stamp_count:     u32,
			route_follow_path_candidate_count: u32,
			route_follow_path_stamp_count:     u32,
			route_follow_path_vertical_stamp_count: u32,
			fungal_stamp_count:      u32,
			crystal_stamp_count:     u32,
			aquifer_stamp_count:     u32,
		}

		TerrainGenerationBenchmarkCaveSelection :: struct {
			node:                  biomes.CaveNetworkNode,
			chunk:                 world_async.ChunkCoord,
			vertical_support:      f32,
			found_matching_biome:  bool,
			streamed_underground:  bool,
		}

		TerrainGenerationBenchmarkCaveFieldPathSelection :: struct {
			chunk:                 world_async.ChunkCoord,
			found:                 bool,
			path_candidate_count:  u32,
			path_stamp_count:      u32,
			route_follow_count:    u32,
			vertical_follow_count: u32,
		}

		TerrainGenerationBenchmarkCaveComponentMeasure :: struct {
			found:               bool,
			node_count:          u32,
			external_link_count: u32,
		}

		TerrainGenerationBenchmarkRegionStats :: struct {
			node_count:                 u32,
			edge_count:                 u32,
			anchor_count:               u32,
			water_feature_node_count:   u32,
			water_feature_segment_count: u32,
			water_feature_anchor_count: u32,
			major_count:                u32,
			water_linked_count:         u32,
			connector_count:            u32,
			pocket_count:               u32,
			resource_count:             u32,
			sealed_count:               u32,
			fungal_count:               u32,
			crystal_count:              u32,
			aquifer_count:              u32,
			rooted_macro_count:         u32,
			mineral_macro_count:        u32,
			aquifer_macro_count:        u32,
			shallow_depth_count:        u32,
			mid_depth_count:            u32,
			deep_depth_count:           u32,
			cave_mouth_count:           u32,
			sinkhole_count:             u32,
			water_anchor_count:         u32,
			tunnel_edge_count:          u32,
			canyon_edge_count:          u32,
			worm_edge_count:            u32,
			flooded_edge_count:         u32,
			fracture_edge_count:        u32,
			collapsed_edge_count:       u32,
			vertical_edge_count:        u32,
			node_edge_connected_count:  u32,
			node_anchor_connected_count: u32,
			node_bridge_count:          u32,
			node_culled_count:          u32,
			profile_room_node_count:    u32,
			profile_room_nonmajor_count: u32,
			component_count:            u32,
			component_tiny_count:       u32,
			component_tiny_node_count:  u32,
			component_external_link_count: u32,
			component_anchored_tiny_count: u32,
			component_mouth_tiny_count: u32,
			component_sinkhole_tiny_count: u32,
			component_required_tiny_count: u32,
			component_large_room_tiny_count: u32,
			component_max_nodes:        u32,
		}

		terrain_generation_benchmark_cache_clear :: proc() {
			state.terrain_generation_region_cache = {}
		}

		terrain_generation_benchmark_floor_i32 :: proc(value: f32) -> i32 {
			truncated := i32(value)
			if value < f32(truncated) {
				return truncated - 1
			}
			return truncated
		}

		terrain_generation_benchmark_chunk_for_cave_node :: proc(
			node: biomes.CaveNetworkNode,
		) -> world_async.ChunkCoord {
			return chunk_coord_from_block_coord({
				x = terrain_generation_benchmark_floor_i32(node.x),
				y = terrain_generation_benchmark_floor_i32(node.y),
				z = terrain_generation_benchmark_floor_i32(node.z),
			})
		}

		terrain_generation_benchmark_chunk_for_surface_water_node :: proc(
			node: biomes.WaterFeatureNode,
		) -> world_async.ChunkCoord {
			return chunk_coord_from_block_coord({
				x = terrain_generation_benchmark_floor_i32(node.x),
				y = terrain_generation_benchmark_floor_i32(node.water_level_blocks),
				z = terrain_generation_benchmark_floor_i32(node.z),
			})
		}

		terrain_generation_benchmark_chunk_for_cave_anchor :: proc(
			anchor: biomes.CaveAnchor,
		) -> world_async.ChunkCoord {
			return chunk_coord_from_block_coord({
				x = terrain_generation_benchmark_floor_i32(anchor.x),
				y = terrain_generation_benchmark_floor_i32(anchor.y),
				z = terrain_generation_benchmark_floor_i32(anchor.z),
			})
		}

		terrain_generation_benchmark_coord_append_unique :: proc(
			coords: ^TerrainGenerationBenchmarkCoords,
			count: ^u32,
			coord: world_async.ChunkCoord,
		) {
			for i := u32(0); i < count^; i += 1 {
				if coords[i] == coord {
					return
				}
			}
			if count^ >= TERRAIN_GENERATION_BENCHMARK_COORD_COUNT {
				return
			}
			coords[count^] = coord
			count^ += 1
		}

		terrain_generation_benchmark_surface_water_owner_pick :: proc(
			key: biomes.FeatureGridKey,
			want_lake: bool,
			fallback_owner: biomes.FeatureGridCoord2,
		) -> biomes.FeatureGridCoord2 {
			best_owner := fallback_owner
			best_radius := f32(-1)
			for z := -TERRAIN_GENERATION_BENCHMARK_BIOME_OWNER_SCAN_RADIUS_XZ;
			    z <= TERRAIN_GENERATION_BENCHMARK_BIOME_OWNER_SCAN_RADIUS_XZ;
			    z += 1 {
				for x := -TERRAIN_GENERATION_BENCHMARK_BIOME_OWNER_SCAN_RADIUS_XZ;
				    x <= TERRAIN_GENERATION_BENCHMARK_BIOME_OWNER_SCAN_RADIUS_XZ;
				    x += 1 {
					owner := biomes.FeatureGridCoord2{x = i32(x), z = i32(z)}
					node := biomes.water_feature_surface_node_from_owner(key, owner)
					if want_lake && node.kind != .Surface_Lake {
						continue
					}
					if !want_lake && node.kind != .Surface_River {
						continue
					}
					if node.influence_radius_blocks > best_radius {
						best_owner = owner
						best_radius = node.influence_radius_blocks
					}
				}
			}
			return best_owner
		}

		terrain_generation_benchmark_surface_cave_anchors_pick :: proc(
			key: biomes.FeatureGridKey,
		) -> TerrainGenerationBenchmarkSurfaceCaveAnchors {
			result := TerrainGenerationBenchmarkSurfaceCaveAnchors{}
			best_mouth_score := f32(-1)
			best_sinkhole_score := f32(-1)
			best_small_mouth_score := f32(-1)
			best_medium_mouth_score := f32(-1)
			best_large_mouth_score := f32(-1)
			for z := -TERRAIN_GENERATION_BENCHMARK_BIOME_OWNER_SCAN_RADIUS_XZ;
			    z <= TERRAIN_GENERATION_BENCHMARK_BIOME_OWNER_SCAN_RADIUS_XZ;
			    z += 1 {
				for x := -TERRAIN_GENERATION_BENCHMARK_BIOME_OWNER_SCAN_RADIUS_XZ;
				    x <= TERRAIN_GENERATION_BENCHMARK_BIOME_OWNER_SCAN_RADIUS_XZ;
				    x += 1 {
					node := biomes.cave_network_node_from_owner(
						key,
						{x = i32(x), y = 0, z = i32(z)},
					)
					if !biomes.cave_node_should_emit_anchor(node) {
						continue
					}
					anchor := biomes.cave_anchor_from_node(key, node)
					score := anchor.influence_radius_blocks
					if anchor.guaranteed_connection {
						score += 8
					}
					#partial switch anchor.kind {
					case .Cave_Mouth:
						if score > best_mouth_score {
							result.mouth = anchor
							result.mouth_node = node
							result.mouth_found = true
							best_mouth_score = score
						}
						radius := math.max(f32(4), anchor.influence_radius_blocks)
						if radius < TERRAIN_CAVE_MOUTH_SMALL_RADIUS_BLOCKS {
							if score > best_small_mouth_score {
								result.mouth_small = anchor
								result.mouth_small_node = node
								result.mouth_small_found = true
								best_small_mouth_score = score
							}
						} else if radius < TERRAIN_CAVE_MOUTH_LARGE_RADIUS_BLOCKS {
							if score > best_medium_mouth_score {
								result.mouth_medium = anchor
								result.mouth_medium_node = node
								result.mouth_medium_found = true
								best_medium_mouth_score = score
							}
						} else {
							if score > best_large_mouth_score {
								result.mouth_large = anchor
								result.mouth_large_node = node
								result.mouth_large_found = true
								best_large_mouth_score = score
							}
						}
					case .Sinkhole:
						if score > best_sinkhole_score {
							result.sinkhole = anchor
							result.sinkhole_node = node
							result.sinkhole_found = true
							best_sinkhole_score = score
						}
					}
				}
			}
			return result
		}

		terrain_generation_benchmark_cave_component_measure_for_node :: proc(
			region: ^biomes.GenerationRegion,
			node_id: biomes.FeatureID,
		) -> TerrainGenerationBenchmarkCaveComponentMeasure {
			start_index, start_found :=
				terrain_generation_benchmark_cave_node_index_by_id(region, node_id)
			if !start_found {
				return {}
			}

			measure := TerrainGenerationBenchmarkCaveComponentMeasure {
				found = true,
			}
			visited: [biomes.GENERATION_REGION_CAVE_NETWORK_NODE_CAPACITY]bool
			queue: [biomes.GENERATION_REGION_CAVE_NETWORK_NODE_CAPACITY]u32
			queue_head: u32
			queue_tail: u32
			visited[start_index] = true
			queue[queue_tail] = start_index
			queue_tail += 1

			for queue_head < queue_tail {
				node_index := queue[queue_head]
				queue_head += 1
				measure.node_count += 1
				node := region.cave_network_nodes[node_index]
				for edge_index := u32(0);
				    edge_index < region.cave_network_edge_count;
				    edge_index += 1 {
					edge := region.cave_network_edges[edge_index]
					neighbor_id: biomes.FeatureID
					if edge.from_node_id == node.id {
						neighbor_id = edge.to_node_id
					} else if edge.to_node_id == node.id {
						neighbor_id = edge.from_node_id
					} else {
						continue
					}
					neighbor_index, neighbor_found :=
						terrain_generation_benchmark_cave_node_index_by_id(
							region,
							neighbor_id,
						)
					if !neighbor_found {
						measure.external_link_count += 1
						continue
					}
					if !visited[neighbor_index] {
						visited[neighbor_index] = true
						queue[queue_tail] = neighbor_index
						queue_tail += 1
					}
				}
			}
			return measure
		}

		terrain_generation_benchmark_surface_cave_scan_stats :: proc(
			key: biomes.FeatureGridKey,
		) -> TerrainGenerationBenchmarkSurfaceCaveScanStats {
			stats := TerrainGenerationBenchmarkSurfaceCaveScanStats{}
			for z := -TERRAIN_GENERATION_BENCHMARK_SURFACE_CAVE_OWNER_SCAN_RADIUS_XZ;
			    z <= TERRAIN_GENERATION_BENCHMARK_SURFACE_CAVE_OWNER_SCAN_RADIUS_XZ;
			    z += 1 {
				for x := -TERRAIN_GENERATION_BENCHMARK_SURFACE_CAVE_OWNER_SCAN_RADIUS_XZ;
				    x <= TERRAIN_GENERATION_BENCHMARK_SURFACE_CAVE_OWNER_SCAN_RADIUS_XZ;
				    x += 1 {
					node := biomes.cave_network_node_from_owner(
						key,
						{x = i32(x), y = 0, z = i32(z)},
					)
					if node.role == .Sealed_Secret {
						continue
					}
					stats.owner_count += 1
					roll := biomes.feature_grid_unit_f32(
						u64(node.id),
						biomes.CAVE_NETWORK_SURFACE_ANCHOR_SALT,
					)
					legacy_emit :=
						node.major_region || node.kind == .Vertical_Shaft ||
						roll < TERRAIN_GENERATION_BENCHMARK_LEGACY_SURFACE_ANCHOR_EMIT_ROLL_MAX
					current_emit := biomes.cave_node_should_emit_anchor(node)
					if legacy_emit {
						stats.legacy_emit_count += 1
						if node.kind == .Vertical_Shaft ||
						   roll >=
						   TERRAIN_GENERATION_BENCHMARK_LEGACY_SURFACE_CAVE_MOUTH_ROLL_MAX {
							stats.legacy_sinkhole_count += 1
						} else {
							stats.legacy_mouth_count += 1
						}
					}
					if current_emit {
						stats.current_emit_count += 1
						anchor := biomes.cave_anchor_from_node(key, node)
						anchor_region_coord := biomes.generation_region_coord_from_block(
							terrain_generation_benchmark_floor_i32(node.x),
							terrain_generation_benchmark_floor_i32(node.y),
							terrain_generation_benchmark_floor_i32(node.z),
						)
						anchor_region := terrain_generation_region_for_fill(
							key,
							anchor_region_coord,
						)
						component_measure :=
							terrain_generation_benchmark_cave_component_measure_for_node(
								&anchor_region,
								node.id,
							)
						component_tiny := false
						if !component_measure.found {
							stats.current_anchor_component_missing_count += 1
						} else {
							stats.current_anchor_component_external_link_count +=
								component_measure.external_link_count
							stats.current_anchor_component_max_nodes = math.max(
								stats.current_anchor_component_max_nodes,
								component_measure.node_count,
							)
							component_tiny =
								component_measure.node_count <=
								TERRAIN_GENERATION_BENCHMARK_TINY_CAVE_COMPONENT_NODE_MAX &&
								component_measure.external_link_count == 0
							if component_tiny {
								stats.current_anchor_component_tiny_count += 1
							}
						}
						if anchor.guaranteed_connection {
							stats.guaranteed_count += 1
						}
						if node.kind == .Vertical_Shaft {
							stats.vertical_count += 1
						}
						#partial switch anchor.kind {
						case .Cave_Mouth:
							stats.current_mouth_count += 1
							radius := math.max(f32(4), anchor.influence_radius_blocks)
							stats.current_mouth_radius_total += radius
							stats.current_mouth_radius_max =
								math.max(stats.current_mouth_radius_max, radius)
							if radius < TERRAIN_CAVE_MOUTH_SMALL_RADIUS_BLOCKS {
								stats.current_mouth_small_count += 1
							} else if radius < TERRAIN_CAVE_MOUTH_LARGE_RADIUS_BLOCKS {
								stats.current_mouth_medium_count += 1
							} else {
								stats.current_mouth_large_count += 1
							}
							style := terrain_density_cave_mouth_transition_style(anchor, radius)
							switch style {
							case .Sloped_Tube:
								stats.current_mouth_sloped_tube_count += 1
							case .Curved_Ramp:
								stats.current_mouth_curved_ramp_count += 1
							case .Spiral_Ramp:
								stats.current_mouth_spiral_ramp_count += 1
							}
							if terrain_density_cave_mouth_size_support(radius) >=
							   TERRAIN_CAVE_MOUTH_VESTIBULE_MIN_SUPPORT {
								stats.current_mouth_vestibule_count += 1
							}
							anchor_radius := math.max(
								f32(3),
								anchor.influence_radius_blocks * 0.55,
							)
							link_radius := math.max(
								f32(3),
								math.min(anchor_radius * 0.75, node.connection_radius_blocks),
							)
							plan :=
								terrain_density_cave_mouth_transition_plan(anchor, node, radius, link_radius)
							drop_per_run :=
								plan.near_drop_blocks / math.max(f32(1), plan.near_run_blocks)
							if drop_per_run <= 0.80 {
								stats.current_mouth_shallow_transition_count += 1
							} else {
								stats.current_mouth_steep_transition_count += 1
							}
							raw_dx := node.x - anchor.x
							raw_dz := node.z - anchor.z
							if raw_dx * raw_dx + raw_dz * raw_dz < 1.0 {
								stats.current_mouth_raw_vertical_count += 1
							}
							if component_tiny {
								stats.current_mouth_component_tiny_count += 1
							}
						case .Sinkhole:
							stats.current_sinkhole_count += 1
							if component_tiny {
								stats.current_sinkhole_component_tiny_count += 1
							}
						}
					}
					if current_emit && !legacy_emit {
						stats.additional_emit_count += 1
					}
				}
			}
			return stats
		}

		terrain_generation_benchmark_surface_cave_scan_stats_log :: proc(
			phase: string,
			key: biomes.FeatureGridKey,
		) {
			stats := terrain_generation_benchmark_surface_cave_scan_stats(key)
			mouth_radius_avg := f32(0)
			if stats.current_mouth_count > 0 {
				mouth_radius_avg =
					stats.current_mouth_radius_total / f32(stats.current_mouth_count)
			}
			log.infof(
				"TERRAIN_GENERATION_BENCH_SURFACE_CAVE_SCAN phase=%s owners=%d legacy_emit=%d current_emit=%d additional_emit=%d legacy_mouth=%d legacy_sinkhole=%d current_mouth=%d current_sinkhole=%d mouth_small=%d mouth_medium=%d mouth_large=%d mouth_vestibule=%d mouth_shallow=%d mouth_steep=%d mouth_raw_vertical=%d mouth_sloped=%d mouth_curved=%d mouth_spiral=%d anchor_component_tiny=%d mouth_component_tiny=%d sinkhole_component_tiny=%d anchor_component_missing=%d anchor_component_external_links=%d anchor_component_max_nodes=%d mouth_radius_avg=%.2f mouth_radius_max=%.2f guaranteed=%d vertical=%d",
				phase,
				stats.owner_count,
				stats.legacy_emit_count,
				stats.current_emit_count,
				stats.additional_emit_count,
				stats.legacy_mouth_count,
				stats.legacy_sinkhole_count,
				stats.current_mouth_count,
				stats.current_sinkhole_count,
				stats.current_mouth_small_count,
				stats.current_mouth_medium_count,
				stats.current_mouth_large_count,
				stats.current_mouth_vestibule_count,
				stats.current_mouth_shallow_transition_count,
				stats.current_mouth_steep_transition_count,
				stats.current_mouth_raw_vertical_count,
				stats.current_mouth_sloped_tube_count,
				stats.current_mouth_curved_ramp_count,
				stats.current_mouth_spiral_ramp_count,
				stats.current_anchor_component_tiny_count,
				stats.current_mouth_component_tiny_count,
				stats.current_sinkhole_component_tiny_count,
				stats.current_anchor_component_missing_count,
				stats.current_anchor_component_external_link_count,
				stats.current_anchor_component_max_nodes,
				mouth_radius_avg,
				stats.current_mouth_radius_max,
				stats.guaranteed_count,
				stats.vertical_count,
			)
		}

		terrain_generation_benchmark_surface_cave_scan_stats_add :: proc(
			total: ^TerrainGenerationBenchmarkSurfaceCaveScanStats,
			stats: TerrainGenerationBenchmarkSurfaceCaveScanStats,
		) {
			total.owner_count += stats.owner_count
			total.legacy_emit_count += stats.legacy_emit_count
			total.current_emit_count += stats.current_emit_count
			total.additional_emit_count += stats.additional_emit_count
			total.legacy_mouth_count += stats.legacy_mouth_count
			total.legacy_sinkhole_count += stats.legacy_sinkhole_count
			total.current_mouth_count += stats.current_mouth_count
			total.current_sinkhole_count += stats.current_sinkhole_count
			total.current_mouth_small_count += stats.current_mouth_small_count
			total.current_mouth_medium_count += stats.current_mouth_medium_count
			total.current_mouth_large_count += stats.current_mouth_large_count
			total.current_mouth_vestibule_count += stats.current_mouth_vestibule_count
			total.current_mouth_shallow_transition_count +=
				stats.current_mouth_shallow_transition_count
			total.current_mouth_steep_transition_count +=
				stats.current_mouth_steep_transition_count
			total.current_mouth_raw_vertical_count += stats.current_mouth_raw_vertical_count
			total.current_mouth_sloped_tube_count += stats.current_mouth_sloped_tube_count
			total.current_mouth_curved_ramp_count += stats.current_mouth_curved_ramp_count
			total.current_mouth_spiral_ramp_count += stats.current_mouth_spiral_ramp_count
			total.current_anchor_component_tiny_count +=
				stats.current_anchor_component_tiny_count
			total.current_mouth_component_tiny_count += stats.current_mouth_component_tiny_count
			total.current_sinkhole_component_tiny_count +=
				stats.current_sinkhole_component_tiny_count
			total.current_anchor_component_missing_count +=
				stats.current_anchor_component_missing_count
			total.current_anchor_component_external_link_count +=
				stats.current_anchor_component_external_link_count
			total.current_anchor_component_max_nodes = math.max(
				total.current_anchor_component_max_nodes,
				stats.current_anchor_component_max_nodes,
			)
			total.current_mouth_radius_total += stats.current_mouth_radius_total
			total.current_mouth_radius_max = math.max(
				total.current_mouth_radius_max,
				stats.current_mouth_radius_max,
			)
			total.guaranteed_count += stats.guaranteed_count
			total.vertical_count += stats.vertical_count
		}

		terrain_generation_benchmark_surface_cave_scan_stats_log_multi :: proc(
			phase: string,
		) {
			total := TerrainGenerationBenchmarkSurfaceCaveScanStats{}
			worst_seed: u32
			worst_tiny_count: u32
			for seed := u32(0);
			    seed < TERRAIN_GENERATION_BENCHMARK_SURFACE_CAVE_SCAN_SEED_COUNT;
			    seed += 1 {
				terrain_generation_benchmark_cache_clear()
				stats := terrain_generation_benchmark_surface_cave_scan_stats(
					terrain_generation_key_make(seed),
				)
				tiny_count :=
					stats.current_anchor_component_tiny_count +
					stats.current_anchor_component_missing_count
				if tiny_count > worst_tiny_count {
					worst_tiny_count = tiny_count
					worst_seed = seed
				}
				terrain_generation_benchmark_surface_cave_scan_stats_add(&total, stats)
			}
			mouth_radius_avg := f32(0)
			if total.current_mouth_count > 0 {
				mouth_radius_avg =
					total.current_mouth_radius_total / f32(total.current_mouth_count)
			}
			log.infof(
				"TERRAIN_GENERATION_BENCH_SURFACE_CAVE_SCAN_MULTI phase=%s seeds=%d owners=%d current_emit=%d current_mouth=%d current_sinkhole=%d mouth_small=%d mouth_medium=%d mouth_large=%d mouth_raw_vertical=%d anchor_component_tiny=%d mouth_component_tiny=%d sinkhole_component_tiny=%d anchor_component_missing=%d anchor_component_external_links=%d anchor_component_max_nodes=%d mouth_radius_avg=%.2f mouth_radius_max=%.2f guaranteed=%d vertical=%d worst_seed=%d worst_tiny=%d",
				phase,
				TERRAIN_GENERATION_BENCHMARK_SURFACE_CAVE_SCAN_SEED_COUNT,
				total.owner_count,
				total.current_emit_count,
				total.current_mouth_count,
				total.current_sinkhole_count,
				total.current_mouth_small_count,
				total.current_mouth_medium_count,
				total.current_mouth_large_count,
				total.current_mouth_raw_vertical_count,
				total.current_anchor_component_tiny_count,
				total.current_mouth_component_tiny_count,
				total.current_sinkhole_component_tiny_count,
				total.current_anchor_component_missing_count,
				total.current_anchor_component_external_link_count,
				total.current_anchor_component_max_nodes,
				mouth_radius_avg,
				total.current_mouth_radius_max,
				total.guaranteed_count,
				total.vertical_count,
				worst_seed,
				worst_tiny_count,
			)
		}

		terrain_generation_benchmark_cave_selection_score :: proc(
			node: biomes.CaveNetworkNode,
			chunk: world_async.ChunkCoord,
			vertical_support: f32,
		) -> f32 {
			if vertical_support <= 0 {
				return f32(-1)
			}

			score := vertical_support * 2000 + node.radius_blocks
			if chunk.y < 0 {
				score += 250
			}
			if chunk.y < 0 && chunk.y >= -i32(CHUNK_STREAMING_RADIUS_Y_DOWN) {
				score += 5000
			}
			if node.major_region {
				score += 150
			}
			if node.role == .Resource_Chamber || node.role == .Water_Linked_Region {
				score += 45
			}
			return score
		}

		terrain_generation_benchmark_cave_selection_for_biome :: proc(
			key: biomes.FeatureGridKey,
			biome_id: biomes.BiomeID,
			fallback_owner: biomes.FeatureGridCoord3,
		) -> TerrainGenerationBenchmarkCaveSelection {
			best_node := biomes.cave_network_node_from_owner(key, fallback_owner)
			best_chunk := terrain_generation_benchmark_chunk_for_cave_node(best_node)
			best_support := terrain_density_cave_vertical_support(best_node.y)
			best_score := f32(-1)
			found := best_node.biome_id == biome_id && best_support > 0
			for y := TERRAIN_GENERATION_BENCHMARK_BIOME_OWNER_SCAN_Y_MIN;
			    y <= TERRAIN_GENERATION_BENCHMARK_BIOME_OWNER_SCAN_Y_MAX;
			    y += 1 {
				for z := -TERRAIN_GENERATION_BENCHMARK_BIOME_OWNER_SCAN_RADIUS_XZ;
				    z <= TERRAIN_GENERATION_BENCHMARK_BIOME_OWNER_SCAN_RADIUS_XZ;
				    z += 1 {
					for x := -TERRAIN_GENERATION_BENCHMARK_BIOME_OWNER_SCAN_RADIUS_XZ;
					    x <= TERRAIN_GENERATION_BENCHMARK_BIOME_OWNER_SCAN_RADIUS_XZ;
					    x += 1 {
						node := biomes.cave_network_node_from_owner(
							key,
							{x = i32(x), y = i32(y), z = i32(z)},
						)
						if node.biome_id != biome_id {
							continue
						}
						chunk := terrain_generation_benchmark_chunk_for_cave_node(node)
						support := terrain_density_cave_vertical_support(node.y)
						score := terrain_generation_benchmark_cave_selection_score(node, chunk, support)
						if score > best_score {
							best_node = node
							best_chunk = chunk
							best_support = support
							best_score = score
							found = true
						}
					}
				}
			}
			return {
				node = best_node,
				chunk = best_chunk,
				vertical_support = best_support,
				found_matching_biome = found,
				streamed_underground =
					best_chunk.y < 0 && best_chunk.y >= -i32(CHUNK_STREAMING_RADIUS_Y_DOWN),
			}
		}

		terrain_generation_benchmark_cave_profile_room_selection :: proc(
			key: biomes.FeatureGridKey,
			fallback_owner: biomes.FeatureGridCoord3,
		) -> TerrainGenerationBenchmarkCaveSelection {
			best_node := biomes.cave_network_node_from_owner(key, fallback_owner)
			best_chunk := terrain_generation_benchmark_chunk_for_cave_node(best_node)
			best_support := terrain_density_cave_vertical_support(best_node.y)
			best_score := f32(-1)
			found := false
			for y := TERRAIN_GENERATION_BENCHMARK_BIOME_OWNER_SCAN_Y_MIN;
			    y <= TERRAIN_GENERATION_BENCHMARK_BIOME_OWNER_SCAN_Y_MAX;
			    y += 1 {
				for z := -TERRAIN_GENERATION_BENCHMARK_BIOME_OWNER_SCAN_RADIUS_XZ;
				    z <= TERRAIN_GENERATION_BENCHMARK_BIOME_OWNER_SCAN_RADIUS_XZ;
				    z += 1 {
					for x := -TERRAIN_GENERATION_BENCHMARK_BIOME_OWNER_SCAN_RADIUS_XZ;
					    x <= TERRAIN_GENERATION_BENCHMARK_BIOME_OWNER_SCAN_RADIUS_XZ;
					    x += 1 {
						node := biomes.cave_network_node_from_owner(
							key,
							{x = i32(x), y = i32(y), z = i32(z)},
						)
						if node.major_region ||
						   !terrain_density_cave_node_uses_profile_room(node) {
							continue
						}
						chunk := terrain_generation_benchmark_chunk_for_cave_node(node)
						support := terrain_density_cave_vertical_support(node.y)
						if support <= 0 {
							continue
						}
						origin := chunk_origin_from_coord(chunk)
						region_coord := biomes.generation_region_coord_from_block(
							origin.x,
							origin.y,
							origin.z,
						)
						region := terrain_generation_region_for_fill(key, region_coord)
						connected := false
						for region_node_index := u32(0);
						    region_node_index < region.cave_network_node_count;
						    region_node_index += 1 {
							region_node := region.cave_network_nodes[region_node_index]
							if region_node.id != node.id {
								continue
							}
							connectivity := terrain_density_cave_node_connectivity(
								&region,
								region_node,
							)
							connected = connectivity.should_carve
							break
						}
						if !connected {
							continue
						}
						score := terrain_generation_benchmark_cave_selection_score(
							node,
							chunk,
							support,
						) + 400
						if node.role == .Resource_Chamber {
							score += 75
						}
						if node.role == .Water_Linked_Region {
							score += 60
						}
						if score > best_score {
							best_node = node
							best_chunk = chunk
							best_support = support
							best_score = score
							found = true
						}
					}
				}
			}
			return {
				node = best_node,
				chunk = best_chunk,
				vertical_support = best_support,
				found_matching_biome = found,
				streamed_underground =
					best_chunk.y < 0 && best_chunk.y >= -i32(CHUNK_STREAMING_RADIUS_Y_DOWN),
			}
		}

		terrain_generation_benchmark_cave_field_path_selection_score :: proc(
			selection: TerrainGenerationBenchmarkCaveFieldPathSelection,
			chunk: world_async.ChunkCoord,
		) -> i64 {
			score := i64(selection.route_follow_count) * 1000 +
			         i64(selection.vertical_follow_count) * 180 +
			         i64(selection.path_stamp_count) * 90 +
			         i64(selection.path_candidate_count) * 9
			score -= i64(math.abs(f32(chunk.x))) + i64(math.abs(f32(chunk.z)))
			score -= i64(math.abs(f32(chunk.y + 1))) * 3
			return score
		}

		terrain_generation_benchmark_cave_field_path_selection_for_chunk :: proc(
			key: biomes.FeatureGridKey,
			chunk: world_async.ChunkCoord,
		) -> TerrainGenerationBenchmarkCaveFieldPathSelection {
			origin := chunk_origin_from_coord(chunk)
			region_coord := biomes.generation_region_coord_from_block(
				origin.x,
				origin.y,
				origin.z,
			)
			region := terrain_generation_region_for_fill(key, region_coord)
			selection := TerrainGenerationBenchmarkCaveFieldPathSelection {
				chunk = chunk,
			}
			chunk_stamp_count: u32
			for z := TERRAIN_CAVE_FIELD_SAMPLE_STEP_BLOCKS / 2;
			    z < CHUNK_BLOCK_LENGTH;
			    z += TERRAIN_CAVE_FIELD_SAMPLE_STEP_BLOCKS {
				world_z := origin.z + z
				for y := TERRAIN_CAVE_FIELD_SAMPLE_STEP_BLOCKS / 2;
				    y < CHUNK_BLOCK_LENGTH;
				    y += TERRAIN_CAVE_FIELD_SAMPLE_STEP_BLOCKS {
					world_y := origin.y + y
					vertical_support := terrain_density_cave_vertical_support(f32(world_y))
					if vertical_support <= 0 {
						continue
					}
					for x := TERRAIN_CAVE_FIELD_SAMPLE_STEP_BLOCKS / 2;
					    x < CHUNK_BLOCK_LENGTH;
					    x += TERRAIN_CAVE_FIELD_SAMPLE_STEP_BLOCKS {
						world_x := origin.x + x
						column := terrain_biome_column_sample_direct(key, world_x, world_z)
						depth_below_surface := column.surface_height_blocks - f32(world_y)
						if depth_below_surface < 18 {
							continue
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
							continue
						}
						path_candidate :=
							terrain_density_cave_field_sample_prefers_path(
								field_sample,
								vertical_support,
							)
						open_strength := field_sample.open_strength * vertical_support
						radius := biomes.regional_terrain_field_lerp(
							f32(3.5),
							f32(10.5),
							open_strength,
						)
						subterranean_sample := biomes.subterranean_biome_field_sample(
							key,
							world_x,
							world_y,
							world_z,
						)
						if subterranean_sample.cells[0].biome_id == .Fungal_Vaults {
							radius *= 1.25
						} else if subterranean_sample.cells[0].biome_id ==
						          .Crystal_Geode_Network {
							radius *= 0.82
						} else if subterranean_sample.cells[0].biome_id ==
						          .Buried_Aquifer_Caves {
							radius *= 1.05
						}
						network_sample := terrain_density_cave_field_network_sample(
							&region,
							f32(world_x) + 0.5,
							f32(world_y) + 0.5,
							f32(world_z) + 0.5,
							radius,
							path_candidate,
						)
						if !network_sample.connected {
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
						if !path_candidate {
							continue
						}
						selection.path_candidate_count += 1
						_, path_dir_y, _, route_follow :=
							terrain_density_cave_field_path_direction(
								field_sample,
								network_sample,
							)
						if route_follow {
							selection.route_follow_count += 1
							if math.abs(path_dir_y) > 0.001 {
								selection.vertical_follow_count += 1
							}
						}
						if chunk_stamp_count < TERRAIN_CAVE_FIELD_STAMP_CAPACITY_PER_CHUNK {
							selection.path_stamp_count += 1
							chunk_stamp_count += 1
						}
					}
				}
			}
			selection.found = selection.route_follow_count > 0
			return selection
		}

		terrain_generation_benchmark_cave_field_path_selection :: proc(
			key: biomes.FeatureGridKey,
		) -> TerrainGenerationBenchmarkCaveFieldPathSelection {
			best := TerrainGenerationBenchmarkCaveFieldPathSelection{}
			best_score := i64(-9223372036854775807)
			fungal_selection := terrain_generation_benchmark_cave_selection_for_biome(
				key,
				.Fungal_Vaults,
				{x = 0, y = -1, z = 0},
			)
			crystal_selection := terrain_generation_benchmark_cave_selection_for_biome(
				key,
				.Crystal_Geode_Network,
				{x = 1, y = -1, z = 0},
			)
			aquifer_selection := terrain_generation_benchmark_cave_selection_for_biome(
				key,
				.Buried_Aquifer_Caves,
				{x = 0, y = -1, z = 1},
			)
			profile_room_selection := terrain_generation_benchmark_cave_profile_room_selection(
				key,
				{x = 0, y = -1, z = 0},
			)
			base_chunks := [?]world_async.ChunkCoord {
				{0, -1, 0},
				{0, -2, 0},
				fungal_selection.chunk,
				crystal_selection.chunk,
				aquifer_selection.chunk,
				profile_room_selection.chunk,
			}
			for base_chunk in base_chunks {
				for chunk_y := base_chunk.y - 1; chunk_y <= base_chunk.y + 1; chunk_y += 1 {
					if chunk_y >= 0 || chunk_y < -i32(CHUNK_STREAMING_RADIUS_Y_DOWN) {
						continue
					}
					for offset_z := -TERRAIN_GENERATION_BENCHMARK_CAVE_FIELD_PATH_NEIGHBOR_RADIUS;
					    offset_z <= TERRAIN_GENERATION_BENCHMARK_CAVE_FIELD_PATH_NEIGHBOR_RADIUS;
					    offset_z += 1 {
						for offset_x := -TERRAIN_GENERATION_BENCHMARK_CAVE_FIELD_PATH_NEIGHBOR_RADIUS;
						    offset_x <= TERRAIN_GENERATION_BENCHMARK_CAVE_FIELD_PATH_NEIGHBOR_RADIUS;
						    offset_x += 1 {
							chunk := world_async.ChunkCoord {
								x = base_chunk.x + i32(offset_x),
								y = chunk_y,
								z = base_chunk.z + i32(offset_z),
							}
							selection :=
								terrain_generation_benchmark_cave_field_path_selection_for_chunk(
									key,
									chunk,
								)
							if !selection.found {
								continue
							}
							score :=
								terrain_generation_benchmark_cave_field_path_selection_score(
									selection,
									chunk,
								)
							if score > best_score {
								best = selection
								best_score = score
							}
						}
					}
				}
			}
			return best
		}

		terrain_generation_benchmark_cave_field_path_selection_log :: proc(
			selection: TerrainGenerationBenchmarkCaveFieldPathSelection,
		) {
			log.infof(
				"TERRAIN_GENERATION_BENCH_CAVE_FIELD_PATH_SELECTION found=%v chunk=(%d,%d,%d) path_candidates=%d path_stamps=%d route_follow=%d vertical_follow=%d",
				selection.found,
				selection.chunk.x,
				selection.chunk.y,
				selection.chunk.z,
				selection.path_candidate_count,
				selection.path_stamp_count,
				selection.route_follow_count,
				selection.vertical_follow_count,
			)
		}

		terrain_generation_benchmark_cave_selection_log :: proc(
			label: string,
			selection: TerrainGenerationBenchmarkCaveSelection,
		) {
			origin := chunk_origin_from_coord(selection.chunk)
			region_coord := biomes.generation_region_coord_from_block(
				origin.x,
				origin.y,
				origin.z,
			)
			node := selection.node
			log.infof(
				"TERRAIN_GENERATION_BENCH_CAVE_SELECTION label=%s found=%v streamed_underground=%v owner=(%d,%d,%d) node=(%.2f,%.2f,%.2f) chunk=(%d,%d,%d) origin_y=%d region=(%d,%d,%d) support=%.3f radius=%.2f major=%v kind=%v role=%v biome=%v",
				label,
				selection.found_matching_biome,
				selection.streamed_underground,
				node.owner.x,
				node.owner.y,
				node.owner.z,
				node.x,
				node.y,
				node.z,
				selection.chunk.x,
				selection.chunk.y,
				selection.chunk.z,
				origin.y,
				region_coord.x,
				region_coord.y,
				region_coord.z,
				selection.vertical_support,
				node.radius_blocks,
				node.major_region,
				node.kind,
				node.role,
				node.biome_id,
			)
		}

		terrain_generation_benchmark_cave_selections_log :: proc(
			key: biomes.FeatureGridKey,
		) {
			terrain_generation_benchmark_cave_selection_log(
				"fungal",
				terrain_generation_benchmark_cave_selection_for_biome(
					key,
					.Fungal_Vaults,
					{x = 0, y = -1, z = 0},
				),
			)
			terrain_generation_benchmark_cave_selection_log(
				"crystal",
				terrain_generation_benchmark_cave_selection_for_biome(
					key,
					.Crystal_Geode_Network,
					{x = 1, y = -1, z = 0},
				),
			)
			terrain_generation_benchmark_cave_selection_log(
				"aquifer",
				terrain_generation_benchmark_cave_selection_for_biome(
					key,
					.Buried_Aquifer_Caves,
					{x = 0, y = -1, z = 1},
				),
			)
			terrain_generation_benchmark_cave_selection_log(
				"profile_room",
				terrain_generation_benchmark_cave_profile_room_selection(
					key,
					{x = 0, y = -1, z = 0},
				),
			)
		}

		terrain_generation_benchmark_cave_coords_make :: proc(
			key: biomes.FeatureGridKey,
			path_selection: TerrainGenerationBenchmarkCaveFieldPathSelection,
		) -> TerrainGenerationBenchmarkCoords {
			fungal_selection := terrain_generation_benchmark_cave_selection_for_biome(
				key,
				.Fungal_Vaults,
				{x = 0, y = -1, z = 0},
			)
			crystal_selection := terrain_generation_benchmark_cave_selection_for_biome(
				key,
				.Crystal_Geode_Network,
				{x = 1, y = -1, z = 0},
			)
			aquifer_selection := terrain_generation_benchmark_cave_selection_for_biome(
				key,
				.Buried_Aquifer_Caves,
				{x = 0, y = -1, z = 1},
			)
			profile_room_selection := terrain_generation_benchmark_cave_profile_room_selection(
				key,
				{x = 0, y = -1, z = 0},
			)
			return {
				{0, 0, 0},
				{1, 0, 0},
				{0, -1, 0},
				path_selection.chunk,
				fungal_selection.chunk,
				crystal_selection.chunk,
				aquifer_selection.chunk,
				profile_room_selection.chunk,
			}
		}

		terrain_generation_benchmark_surface_water_coords_make :: proc(
			key: biomes.FeatureGridKey,
		) -> TerrainGenerationBenchmarkCoords {
			lake_owner := terrain_generation_benchmark_surface_water_owner_pick(
				key,
				true,
				{x = 0, z = 0},
			)
			river_owner := terrain_generation_benchmark_surface_water_owner_pick(
				key,
				false,
				{x = 1, z = 0},
			)
			lake_node := biomes.water_feature_surface_node_from_owner(key, lake_owner)
			river_node := biomes.water_feature_surface_node_from_owner(key, river_owner)
			lake_chunk := terrain_generation_benchmark_chunk_for_surface_water_node(lake_node)
			river_chunk := terrain_generation_benchmark_chunk_for_surface_water_node(river_node)
			lake_neighbor_chunk := terrain_generation_benchmark_chunk_for_surface_water_node(
				biomes.water_feature_surface_node_from_owner(
					key,
					{x = lake_owner.x + 1, z = lake_owner.z},
				),
			)
			river_neighbor_chunk := terrain_generation_benchmark_chunk_for_surface_water_node(
				biomes.water_feature_surface_node_from_owner(
					key,
					{x = river_owner.x, z = river_owner.z + 1},
				),
			)

			return {
				lake_chunk,
				{lake_chunk.x + 1, lake_chunk.y, lake_chunk.z},
				{lake_chunk.x, lake_chunk.y, lake_chunk.z + 1},
				lake_neighbor_chunk,
				river_chunk,
				{river_chunk.x + 1, river_chunk.y, river_chunk.z},
				{river_chunk.x, river_chunk.y, river_chunk.z + 1},
				river_neighbor_chunk,
			}
		}

		terrain_generation_benchmark_surface_cave_coords_make :: proc(
			anchors: TerrainGenerationBenchmarkSurfaceCaveAnchors,
		) -> TerrainGenerationBenchmarkCoords {
			coords := TerrainGenerationBenchmarkCoords{}
			coord_count: u32
			base := world_async.ChunkCoord{0, 0, 0}

			if anchors.mouth_found {
				mouth_chunk := terrain_generation_benchmark_chunk_for_cave_anchor(anchors.mouth)
				mouth_node_chunk :=
					terrain_generation_benchmark_chunk_for_cave_node(anchors.mouth_node)
				base = mouth_chunk
				terrain_generation_benchmark_coord_append_unique(&coords, &coord_count, mouth_chunk)
				terrain_generation_benchmark_coord_append_unique(
					&coords,
					&coord_count,
					{mouth_chunk.x, mouth_chunk.y - 1, mouth_chunk.z},
				)
				terrain_generation_benchmark_coord_append_unique(
					&coords,
					&coord_count,
					mouth_node_chunk,
				)
				terrain_generation_benchmark_coord_append_unique(
					&coords,
					&coord_count,
					{mouth_node_chunk.x, mouth_node_chunk.y + 1, mouth_node_chunk.z},
				)
			}

			if anchors.sinkhole_found {
				sinkhole_chunk :=
					terrain_generation_benchmark_chunk_for_cave_anchor(anchors.sinkhole)
				sinkhole_node_chunk :=
					terrain_generation_benchmark_chunk_for_cave_node(anchors.sinkhole_node)
				if !anchors.mouth_found {
					base = sinkhole_chunk
				}
				terrain_generation_benchmark_coord_append_unique(
					&coords,
					&coord_count,
					sinkhole_chunk,
				)
				terrain_generation_benchmark_coord_append_unique(
					&coords,
					&coord_count,
					{sinkhole_chunk.x, sinkhole_chunk.y - 1, sinkhole_chunk.z},
				)
				terrain_generation_benchmark_coord_append_unique(
					&coords,
					&coord_count,
					sinkhole_node_chunk,
				)
				terrain_generation_benchmark_coord_append_unique(
					&coords,
					&coord_count,
					{sinkhole_node_chunk.x, sinkhole_node_chunk.y + 1, sinkhole_node_chunk.z},
				)
			}

			fallback_offsets := [?]world_async.ChunkCoord {
				{0, 0, 0},
				{0, -1, 0},
				{1, 0, 0},
				{-1, 0, 0},
				{0, 0, 1},
				{0, 0, -1},
				{1, -1, 0},
				{0, -1, 1},
				{-1, -1, 0},
				{0, -1, -1},
			}
			for offset in fallback_offsets {
				if coord_count >= TERRAIN_GENERATION_BENCHMARK_COORD_COUNT {
					break
				}
				terrain_generation_benchmark_coord_append_unique(
					&coords,
					&coord_count,
					{base.x + offset.x, base.y + offset.y, base.z + offset.z},
				)
			}
			return coords
		}

		terrain_generation_benchmark_checksum :: proc(view: world_async.ChunkVoxelView) -> (
			checksum: u64,
			solid_count: u32,
			water_count: u32,
		) {
			for index := 0; index < CHUNK_BLOCK_COUNT; index += 1 {
				material := u32(view.blocks.material_id[index])
				if view.blocks.occupancy[index] == .Solid {
					solid_count += 1
					checksum = checksum * 1099511628211 ~ u64(index + 1)
					checksum = checksum * 1099511628211 ~ u64(material + 17)
					if terrain_material_palette_index(view.blocks.material_id[index]) ==
					   TERRAIN_WATER_MAT_ID {
						water_count += 1
					}
				} else {
					checksum = checksum * 1099511628211 ~ u64(index + 3)
				}
			}
			return
		}

		terrain_generation_benchmark_checksum_coords :: proc(
			view: ^world_async.ChunkVoxelView,
			coords: TerrainGenerationBenchmarkCoords,
			seed: u32,
		) -> (
			checksum: u64,
			solid_count: u32,
			water_count: u32,
		) {
			for coord in coords {
				terrain_heightfield_voxel_view_fill(view, coord, seed)
				chunk_checksum, chunk_solid_count, chunk_water_count :=
					terrain_generation_benchmark_checksum(view^)
				checksum = checksum * 1099511628211 ~ chunk_checksum
				solid_count += chunk_solid_count
				water_count += chunk_water_count
			}
			return
		}

		terrain_generation_benchmark_surface_water_stats_from_coords :: proc(
			coords: TerrainGenerationBenchmarkCoords,
			seed: u32,
		) -> TerrainGenerationBenchmarkSurfaceWaterStats {
			key := terrain_generation_key_make(seed)
			stats := TerrainGenerationBenchmarkSurfaceWaterStats {
				min_surface_height_blocks = max(f32),
				max_surface_height_blocks = -max(f32),
			}
			for chunk_coord in coords {
				origin := chunk_origin_from_coord(chunk_coord)
				region_coord := biomes.generation_region_coord_from_block(
					origin.x,
					origin.y,
					origin.z,
				)
				region := terrain_generation_region_for_fill(key, region_coord)
				for z := i32(0); z < CHUNK_BLOCK_LENGTH; z += 1 {
					world_z := origin.z + z
					for x := i32(0); x < CHUNK_BLOCK_LENGTH; x += 1 {
						world_x := origin.x + x
						surface_sample := biomes.surface_biome_field_sample_from_region(
							&region,
							world_x,
							world_z,
						)
						hydrology_sample := biomes.hydrology_layer_surface_sample_from_region(
							&region,
							world_x,
							world_z,
						)
						evaluation := biomes.surface_biome_profile_evaluate_with_hydrology(
							key,
							surface_sample,
							hydrology_sample,
							world_x,
							world_z,
						)
						column := terrain_biome_column_from_profile_evaluation(
							key,
							evaluation,
							world_x,
							world_z,
						)
						water_influence := hydrology_sample.basin_influence
						if hydrology_sample.channel_influence > water_influence {
							water_influence = hydrology_sample.channel_influence
						}
						stats.column_count += 1
						if water_influence > stats.max_water_influence {
							stats.max_water_influence = water_influence
						}
						if hydrology_sample.floor_depression_blocks >
						   stats.max_floor_depression_blocks {
							stats.max_floor_depression_blocks =
								hydrology_sample.floor_depression_blocks
						}
						stats.min_surface_height_blocks = math.min(
							stats.min_surface_height_blocks,
							column.surface_height_blocks,
						)
						stats.max_surface_height_blocks = math.max(
							stats.max_surface_height_blocks,
							column.surface_height_blocks,
						)
						if column.surface_height_blocks >=
						   TERRAIN_SURFACE_HEIGHT_TOP_SOFT_START_BLOCKS {
							stats.top_soft_zone_columns += 1
						}
						if column.surface_height_blocks <=
						   TERRAIN_SURFACE_HEIGHT_BOTTOM_SOFT_START_BLOCKS {
							stats.bottom_soft_zone_columns += 1
						}
						if hydrology_sample.basin_influence > 0 {
							stats.basin_columns += 1
						}
						if hydrology_sample.channel_influence > 0 {
							stats.channel_columns += 1
						}
						if hydrology_sample.anchor_count > 0 {
							stats.anchor_columns += 1
						}
						shore_width := terrain_shoreline_material_width(evaluation)
						height_delta := terrain_shoreline_height_delta(
							column.surface_height_blocks,
							column.water_level_blocks,
						)
						if height_delta >= -4 && height_delta <= shore_width {
							stats.shore_columns += 1
							surface_palette := terrain_material_palette_index(
								column.surface_material_id,
							)
							green_surface := surface_palette == TERRAIN_GRASS_MAT_ID
							if surface_palette == TERRAIN_WET_MARSH_MAT_ID {
								stats.shore_wet_surface_columns += 1
							}
							if green_surface {
								stats.shore_grass_surface_columns += 1
							}
							if height_delta <= shore_width * 0.42 {
								stats.shore_low_columns += 1
								if green_surface {
									stats.shore_low_green_columns += 1
								}
							} else if height_delta <= shore_width * 0.70 {
								stats.shore_mid_columns += 1
								if green_surface {
									stats.shore_mid_green_columns += 1
								}
							} else {
								stats.shore_upper_columns += 1
								if green_surface {
									stats.shore_upper_green_columns += 1
								}
							}
						}
						if column.water_fill_active &&
						   column.water_level_blocks == biomes.SEA_LEVEL_BLOCKS {
							stats.sea_fill_columns += 1
						}
						if water_influence <= 0 {
							continue
						}
						stats.local_water_feature_columns += 1
						local_water_below := column.surface_height_blocks <
						                     hydrology_sample.water_level_blocks
						if local_water_below {
							stats.local_water_below_columns += 1
						}
						local_water_fill := column.water_fill_active &&
						                    column.water_level_blocks + 0.001 >=
						                    hydrology_sample.water_level_blocks
						if local_water_fill {
							stats.local_water_fill_columns += 1
						}
						if local_water_below && !local_water_fill {
							water_depth :=
								hydrology_sample.water_level_blocks -
								column.surface_height_blocks
							stats.local_water_gap_columns += 1
							if water_influence > stats.max_unfilled_water_influence {
								stats.max_unfilled_water_influence = water_influence
							}
							if water_depth > stats.max_unfilled_water_depth {
								stats.max_unfilled_water_depth = water_depth
							}
						}
					}
				}
			}
			return stats
		}

		terrain_generation_benchmark_surface_water_stats_log :: proc(
			phase: string,
			coords: TerrainGenerationBenchmarkCoords,
			seed: u32,
		) {
			stats := terrain_generation_benchmark_surface_water_stats_from_coords(coords, seed)
			log.infof(
				"TERRAIN_GENERATION_BENCH_SURFACE_WATER phase=%s columns=%d local_feature=%d local_below=%d local_fill=%d local_gap=%d sea_fill=%d basin=%d channel=%d anchor=%d shore=%d shore_wet=%d shore_grass=%d shore_low=%d shore_mid=%d shore_upper=%d shore_low_green=%d shore_mid_green=%d shore_upper_green=%d min_height=%.3f max_height=%.3f top_soft=%d bottom_soft=%d max_influence=%.3f max_gap_influence=%.3f max_gap_depth=%.3f max_floor_depression=%.3f",
				phase,
				stats.column_count,
				stats.local_water_feature_columns,
				stats.local_water_below_columns,
				stats.local_water_fill_columns,
				stats.local_water_gap_columns,
				stats.sea_fill_columns,
				stats.basin_columns,
				stats.channel_columns,
				stats.anchor_columns,
				stats.shore_columns,
				stats.shore_wet_surface_columns,
				stats.shore_grass_surface_columns,
				stats.shore_low_columns,
				stats.shore_mid_columns,
				stats.shore_upper_columns,
				stats.shore_low_green_columns,
				stats.shore_mid_green_columns,
				stats.shore_upper_green_columns,
				stats.min_surface_height_blocks,
				stats.max_surface_height_blocks,
				stats.top_soft_zone_columns,
				stats.bottom_soft_zone_columns,
				stats.max_water_influence,
				stats.max_unfilled_water_influence,
				stats.max_unfilled_water_depth,
				stats.max_floor_depression_blocks,
			)
		}

		terrain_generation_benchmark_surface_cave_anchor_stats_add :: proc(
			stats: ^TerrainGenerationBenchmarkSurfaceCaveStats,
			view: world_async.ChunkVoxelView,
			chunk_coord: world_async.ChunkCoord,
			anchor: biomes.CaveAnchor,
			node: biomes.CaveNetworkNode,
			anchor_open_blocks: ^u32,
		) {
			origin := chunk_origin_from_coord(chunk_coord)
			anchor_x := terrain_generation_benchmark_floor_i32(anchor.x)
			anchor_y := terrain_generation_benchmark_floor_i32(anchor.y)
			anchor_z := terrain_generation_benchmark_floor_i32(anchor.z)
			radius := i32(anchor.influence_radius_blocks)
			if radius < 5 {
				radius = 5
			}
			if radius > 14 {
				radius = 14
			}
			depth := radius * 3
			radius_sq := radius * radius
			dir_x, dir_z := terrain_density_cave_entrance_planar_direction(anchor, node)
			side_x := -dir_z
			side_z := dir_x

			for z := i32(0); z < CHUNK_BLOCK_LENGTH; z += 1 {
				world_z := origin.z + z
				dz := world_z - anchor_z
				for y := i32(0); y < CHUNK_BLOCK_LENGTH; y += 1 {
					world_y := origin.y + y
					depth_below_surface := anchor_y - world_y
					if depth_below_surface < -2 || depth_below_surface > depth {
						continue
					}
					for x := i32(0); x < CHUNK_BLOCK_LENGTH; x += 1 {
						world_x := origin.x + x
						dx := world_x - anchor_x
						mouth_anchor :=
							anchor.kind == .Cave_Mouth || anchor.kind == .Ravine_Breach
						forward_unit := f32(0)
						side_unit := f32(0)
						if mouth_anchor {
							forward := f32(dx) * dir_x + f32(dz) * dir_z
							side := f32(dx) * side_x + f32(dz) * side_z
							forward_unit = forward / f32(radius)
							side_unit = side / f32(radius)
							if forward_unit < -0.35 ||
							   forward_unit > 2.75 ||
							   math.abs(side_unit) > 1.40 {
								continue
							}
						} else if dx * dx + dz * dz > radius_sq {
							continue
						}
						index := chunk_block_index(u32(x), u32(y), u32(z))
						palette := terrain_material_palette_index(view.blocks.material_id[index])
						open := view.blocks.occupancy[index] == .Empty
						water := palette == TERRAIN_WATER_MAT_ID
						if open || water {
							stats.open_blocks += 1
							anchor_open_blocks^ += 1
							if mouth_anchor {
								forward_abs := math.abs(forward_unit)
								side_abs := math.abs(side_unit)
								if depth_below_surface >= -1 &&
								   depth_below_surface <= radius / 2 &&
								   forward_unit >= -0.28 && forward_unit <= 0.45 &&
								   side_abs <= 0.52 {
									stats.mouth_aperture_open_blocks += 1
								}
								if depth_below_surface >= 0 &&
								   depth_below_surface <= radius * 3 / 2 &&
								   forward_unit >= 0.35 && forward_unit <= 1.35 &&
								   side_abs <= 0.72 {
									stats.mouth_throat_open_blocks += 1
								}
								if depth_below_surface >= radius / 2 &&
								   depth_below_surface <= radius * 3 &&
								   forward_unit >= 1.35 && forward_unit <= 2.65 &&
								   side_abs <= 0.82 {
									stats.mouth_inner_open_blocks += 1
								}
								if depth_below_surface >= 0 &&
								   depth_below_surface <= radius &&
								   forward_unit >= -0.10 && forward_unit <= 1.25 &&
								   side_abs >= 0.95 {
									stats.mouth_outer_carve_open_blocks += 1
								}
								if depth_below_surface >= 0 &&
								   depth_below_surface <= radius {
									if side_abs <= 0.34 && forward_abs <= 0.82 {
										stats.mouth_lower_center_open_blocks += 1
									}
									if side_abs >= 0.36 && side_abs <= 0.86 &&
									   forward_abs <= 0.88 {
										stats.mouth_lower_side_band_open_blocks += 1
									}
								}
								if depth_below_surface >= radius / 3 &&
								   depth_below_surface <= radius * 2 &&
								   side_abs >= 0.46 && side_abs <= 0.94 &&
								   forward_unit >= -0.12 && forward_unit <= 2.35 {
									stats.mouth_side_pocket_open_blocks += 1
								}
							}
							if anchor.kind == .Sinkhole &&
							   depth_below_surface >= 0 &&
							   depth_below_surface <= radius {
								ring_distance_sq := dx * dx + dz * dz
								if ring_distance_sq <= radius_sq / 9 {
									stats.sinkhole_upper_center_open_blocks += 1
								} else if ring_distance_sq <= radius_sq * 4 / 9 {
									stats.sinkhole_upper_ledge_open_blocks += 1
								} else {
									stats.sinkhole_upper_outer_open_blocks += 1
								}
								sinkhole_forward_unit :=
									(f32(dx) * dir_x + f32(dz) * dir_z) / f32(radius)
								sinkhole_side_unit :=
									(f32(dx) * side_x + f32(dz) * side_z) / f32(radius)
								forward_abs := math.abs(sinkhole_forward_unit)
								side_abs := math.abs(sinkhole_side_unit)
								if side_abs >= 0.32 && side_abs <= 0.80 && forward_abs <= 0.76 {
									stats.sinkhole_upper_side_band_open_blocks += 1
								}
								if forward_abs >= 0.32 && forward_abs <= 0.92 && side_abs <= 0.62 {
									stats.sinkhole_upper_end_band_open_blocks += 1
								}
							}
							if water {
								stats.water_blocks += 1
							}
							if depth_below_surface <= 2 {
								stats.near_surface_open += 1
							} else {
								stats.sub_surface_open += 1
							}
							if depth_below_surface > stats.max_open_depth {
								stats.max_open_depth = depth_below_surface
							}
						} else {
							stats.solid_blocks += 1
						}
					}
				}
			}
		}

		terrain_generation_benchmark_surface_cave_stats_from_coords :: proc(
			view: ^world_async.ChunkVoxelView,
			coords: TerrainGenerationBenchmarkCoords,
			anchors: TerrainGenerationBenchmarkSurfaceCaveAnchors,
			seed: u32,
		) -> TerrainGenerationBenchmarkSurfaceCaveStats {
			stats := TerrainGenerationBenchmarkSurfaceCaveStats {
				min_open_blocks = 0xffffffff,
			}
				selected := [?]biomes.CaveAnchor {
				anchors.mouth,
				anchors.sinkhole,
			}
			nodes := [?]biomes.CaveNetworkNode {
				anchors.mouth_node,
				anchors.sinkhole_node,
			}
			found := [?]bool {
				anchors.mouth_found,
				anchors.sinkhole_found,
			}

			for anchor, anchor_index in selected {
				if !found[anchor_index] {
					continue
				}
				stats.selected_anchor_count += 1
				#partial switch anchor.kind {
				case .Cave_Mouth:
					stats.mouth_count += 1
					opening_radius := math.max(f32(4), anchor.influence_radius_blocks)
					anchor_radius := math.max(
						f32(3),
						anchor.influence_radius_blocks * 0.55,
					)
					link_radius := math.max(
						f32(3),
						math.min(
							anchor_radius * 0.75,
							nodes[anchor_index].connection_radius_blocks,
						),
					)
					plan := terrain_density_cave_mouth_transition_plan(
						anchor,
						nodes[anchor_index],
						opening_radius,
						link_radius,
					)
					stats.mouth_link_horizontal_blocks = plan.near_run_blocks
					stats.mouth_link_vertical_blocks = plan.near_drop_blocks
					stats.mouth_link_drop_per_run =
						plan.near_drop_blocks / math.max(f32(1), plan.near_run_blocks)
					stats.mouth_bend_horizontal_blocks = plan.bend_run_blocks
					stats.mouth_bend_vertical_blocks = plan.bend_drop_blocks
					stats.mouth_bend_drop_per_run =
						plan.bend_drop_blocks / math.max(f32(1), plan.bend_run_blocks)
					stats.mouth_handoff_horizontal_blocks = plan.handoff_run_blocks
					stats.mouth_handoff_vertical_blocks = plan.handoff_drop_blocks
					stats.mouth_handoff_drop_per_run =
						plan.handoff_drop_blocks / math.max(f32(1), plan.handoff_run_blocks)
				case .Sinkhole:
					stats.sinkhole_count += 1
				}

				anchor_open_blocks: u32
				for coord in coords {
					terrain_heightfield_voxel_view_fill(view, coord, seed)
					terrain_generation_benchmark_surface_cave_anchor_stats_add(
						&stats,
						view^,
						coord,
						anchor,
						nodes[anchor_index],
						&anchor_open_blocks,
					)
				}
				#partial switch anchor.kind {
				case .Cave_Mouth:
					stats.mouth_open_blocks = anchor_open_blocks
				case .Sinkhole:
					stats.sinkhole_open_blocks = anchor_open_blocks
				}

				if anchor_open_blocks > 0 {
					stats.open_anchor_count += 1
				} else {
					stats.sealed_anchor_count += 1
				}
				if anchor_open_blocks < stats.min_open_blocks {
					stats.min_open_blocks = anchor_open_blocks
				}
			}
			if stats.selected_anchor_count == 0 {
				stats.min_open_blocks = 0
			}
			return stats
		}

		terrain_generation_benchmark_surface_cave_stats_log :: proc(
			phase: string,
			view: ^world_async.ChunkVoxelView,
			coords: TerrainGenerationBenchmarkCoords,
			anchors: TerrainGenerationBenchmarkSurfaceCaveAnchors,
			seed: u32,
		) {
			stats := terrain_generation_benchmark_surface_cave_stats_from_coords(
				view,
				coords,
				anchors,
				seed,
			)
			log.infof(
				"TERRAIN_GENERATION_BENCH_SURFACE_CAVE phase=%s selected=%d mouth=%d sinkhole=%d open_anchor=%d sealed_anchor=%d open_blocks=%d mouth_open=%d sinkhole_open=%d mouth_aperture=%d mouth_throat=%d mouth_inner=%d mouth_outer=%d mouth_lower_center=%d mouth_lower_side=%d mouth_side_pocket=%d sinkhole_upper_center=%d sinkhole_upper_ledge=%d sinkhole_upper_outer=%d sinkhole_upper_side=%d sinkhole_upper_end=%d water_blocks=%d solid_blocks=%d near_surface_open=%d sub_surface_open=%d max_open_depth=%d min_open_blocks=%d mouth_link_run=%.2f mouth_link_drop=%.2f mouth_drop_per_run=%.3f mouth_bend_run=%.2f mouth_bend_drop=%.2f mouth_bend_drop_per_run=%.3f mouth_handoff_run=%.2f mouth_handoff_drop=%.2f mouth_handoff_drop_per_run=%.3f",
				phase,
				stats.selected_anchor_count,
				stats.mouth_count,
				stats.sinkhole_count,
				stats.open_anchor_count,
				stats.sealed_anchor_count,
				stats.open_blocks,
				stats.mouth_open_blocks,
				stats.sinkhole_open_blocks,
				stats.mouth_aperture_open_blocks,
				stats.mouth_throat_open_blocks,
				stats.mouth_inner_open_blocks,
				stats.mouth_outer_carve_open_blocks,
				stats.mouth_lower_center_open_blocks,
				stats.mouth_lower_side_band_open_blocks,
				stats.mouth_side_pocket_open_blocks,
				stats.sinkhole_upper_center_open_blocks,
				stats.sinkhole_upper_ledge_open_blocks,
				stats.sinkhole_upper_outer_open_blocks,
				stats.sinkhole_upper_side_band_open_blocks,
				stats.sinkhole_upper_end_band_open_blocks,
				stats.water_blocks,
				stats.solid_blocks,
				stats.near_surface_open,
				stats.sub_surface_open,
				stats.max_open_depth,
				stats.min_open_blocks,
				stats.mouth_link_horizontal_blocks,
				stats.mouth_link_vertical_blocks,
				stats.mouth_link_drop_per_run,
				stats.mouth_bend_horizontal_blocks,
				stats.mouth_bend_vertical_blocks,
				stats.mouth_bend_drop_per_run,
				stats.mouth_handoff_horizontal_blocks,
				stats.mouth_handoff_vertical_blocks,
				stats.mouth_handoff_drop_per_run,
			)
		}

		terrain_generation_benchmark_surface_cave_mouth_size_stats_log :: proc(
			phase: string,
			label: string,
			view: ^world_async.ChunkVoxelView,
			anchor: biomes.CaveAnchor,
			node: biomes.CaveNetworkNode,
			found: bool,
			seed: u32,
		) {
			if !found {
				log.infof(
					"TERRAIN_GENERATION_BENCH_SURFACE_CAVE_MOUTH_SIZE phase=%s label=%s found=%v",
					phase,
					label,
					found,
				)
				return
			}

			anchors := TerrainGenerationBenchmarkSurfaceCaveAnchors {
				mouth = anchor,
				mouth_node = node,
				mouth_found = true,
			}
			coords := terrain_generation_benchmark_surface_cave_coords_make(anchors)
			stats := terrain_generation_benchmark_surface_cave_stats_from_coords(
				view,
				coords,
				anchors,
				seed,
			)

			opening_radius := math.max(f32(4), anchor.influence_radius_blocks)
			size_support := terrain_density_cave_mouth_size_support(opening_radius)
			style := terrain_density_cave_mouth_transition_style(anchor, opening_radius)
			outer_per_aperture := f32(0)
			throat_per_aperture := f32(0)
			inner_per_throat := f32(0)
			if stats.mouth_aperture_open_blocks > 0 {
				outer_per_aperture =
					f32(stats.mouth_outer_carve_open_blocks) /
					f32(stats.mouth_aperture_open_blocks)
				throat_per_aperture =
					f32(stats.mouth_throat_open_blocks) /
					f32(stats.mouth_aperture_open_blocks)
			}
			if stats.mouth_throat_open_blocks > 0 {
				inner_per_throat =
					f32(stats.mouth_inner_open_blocks) / f32(stats.mouth_throat_open_blocks)
			}

			log.infof(
				"TERRAIN_GENERATION_BENCH_SURFACE_CAVE_MOUTH_SIZE phase=%s label=%s found=%v style=%v owner=(%d,%d,%d) anchor=(%.2f,%.2f,%.2f) node=(%.2f,%.2f,%.2f) radius=%.2f size_support=%.3f open_blocks=%d aperture=%d throat=%d inner=%d outer=%d lower_center=%d lower_side=%d side_pocket=%d water_blocks=%d solid_blocks=%d max_open_depth=%d min_open_blocks=%d link_run=%.2f link_drop=%.2f drop_per_run=%.3f bend_run=%.2f bend_drop=%.2f bend_drop_per_run=%.3f handoff_run=%.2f handoff_drop=%.2f handoff_drop_per_run=%.3f outer_per_aperture=%.3f throat_per_aperture=%.3f inner_per_throat=%.3f",
				phase,
				label,
				found,
				style,
				anchor.owner.x,
				anchor.owner.y,
				anchor.owner.z,
				anchor.x,
				anchor.y,
				anchor.z,
				node.x,
				node.y,
				node.z,
				opening_radius,
				size_support,
				stats.open_blocks,
				stats.mouth_aperture_open_blocks,
				stats.mouth_throat_open_blocks,
				stats.mouth_inner_open_blocks,
				stats.mouth_outer_carve_open_blocks,
				stats.mouth_lower_center_open_blocks,
				stats.mouth_lower_side_band_open_blocks,
				stats.mouth_side_pocket_open_blocks,
				stats.water_blocks,
				stats.solid_blocks,
				stats.max_open_depth,
				stats.min_open_blocks,
				stats.mouth_link_horizontal_blocks,
				stats.mouth_link_vertical_blocks,
				stats.mouth_link_drop_per_run,
				stats.mouth_bend_horizontal_blocks,
				stats.mouth_bend_vertical_blocks,
				stats.mouth_bend_drop_per_run,
				stats.mouth_handoff_horizontal_blocks,
				stats.mouth_handoff_vertical_blocks,
				stats.mouth_handoff_drop_per_run,
				outer_per_aperture,
				throat_per_aperture,
				inner_per_throat,
			)
		}

		terrain_generation_benchmark_cave_block_is_open_or_water :: proc(
			view: world_async.ChunkVoxelView,
			x, y, z: i32,
		) -> bool {
			if !chunk_block_coord_is_inside(x, y, z) {
				return false
			}
			index := chunk_block_index(u32(x), u32(y), u32(z))
			palette := terrain_material_palette_index(view.blocks.material_id[index])
			return view.blocks.occupancy[index] == .Empty || palette == TERRAIN_WATER_MAT_ID
		}

		terrain_generation_benchmark_cave_open_neighbor_count_26 :: proc(
			view: world_async.ChunkVoxelView,
			x, y, z: i32,
		) -> u32 {
			count: u32
			for dz := i32(-1); dz <= 1; dz += 1 {
				for dy := i32(-1); dy <= 1; dy += 1 {
					for dx := i32(-1); dx <= 1; dx += 1 {
						if dx == 0 && dy == 0 && dz == 0 {
							continue
						}
						if terrain_generation_benchmark_cave_block_is_open_or_water(
							view,
							x + dx,
							y + dy,
							z + dz,
						) {
							count += 1
						}
					}
				}
			}
			return count
		}

		terrain_generation_benchmark_cave_axis_span :: proc(
			view: world_async.ChunkVoxelView,
			x, y, z, step_x, step_y, step_z: i32,
		) -> u32 {
			span := u32(1)
			for distance := i32(1); distance <= 8; distance += 1 {
				if !terrain_generation_benchmark_cave_block_is_open_or_water(
					view,
					x + step_x * distance,
					y + step_y * distance,
					z + step_z * distance,
				) {
					break
				}
				span += 1
			}
			for distance := i32(1); distance <= 8; distance += 1 {
				if !terrain_generation_benchmark_cave_block_is_open_or_water(
					view,
					x - step_x * distance,
					y - step_y * distance,
					z - step_z * distance,
				) {
					break
				}
				span += 1
			}
			return span
		}

		terrain_generation_benchmark_cave_shape_stats_add_open_block :: proc(
			stats: ^TerrainGenerationBenchmarkCavePhysicalStats,
			view: world_async.ChunkVoxelView,
			x, y, z: i32,
		) {
			neighbor_count := terrain_generation_benchmark_cave_open_neighbor_count_26(
				view,
				x,
				y,
				z,
			)
			if neighbor_count <= 8 {
				stats.open_neighbor_low_blocks += 1
			} else if neighbor_count < 20 {
				stats.open_neighbor_mid_blocks += 1
			} else {
				stats.open_neighbor_high_blocks += 1
			}

			span_x := terrain_generation_benchmark_cave_axis_span(view, x, y, z, 1, 0, 0)
			span_y := terrain_generation_benchmark_cave_axis_span(view, x, y, z, 0, 1, 0)
			span_z := terrain_generation_benchmark_cave_axis_span(view, x, y, z, 0, 0, 1)
			stats.axis_span_x_total += span_x
			stats.axis_span_y_total += span_y
			stats.axis_span_z_total += span_z

			min_span := span_x
			max_span := span_x
			if span_y < min_span {min_span = span_y}
			if span_z < min_span {min_span = span_z}
			if span_y > max_span {max_span = span_y}
			if span_z > max_span {max_span = span_z}
			mid_span := span_x + span_y + span_z - min_span - max_span
			if span_x >= 7 && span_y >= 5 && span_z >= 7 {
				stats.chamber_span_blocks += 1
			}
			if max_span >= 9 && mid_span <= 5 && min_span <= 3 {
				stats.narrow_span_blocks += 1
			}
		}

		terrain_generation_benchmark_cave_open_core_27 :: proc(
			view: world_async.ChunkVoxelView,
			x, y, z: i32,
		) -> bool {
			for dz := i32(-1); dz <= 1; dz += 1 {
				for dy := i32(-1); dy <= 1; dy += 1 {
					for dx := i32(-1); dx <= 1; dx += 1 {
						if !terrain_generation_benchmark_cave_block_is_open_or_water(
							view,
							x + dx,
							y + dy,
							z + dz,
						) {
							return false
						}
					}
				}
			}
			return true
		}

		terrain_generation_benchmark_cave_open_core_6 :: proc(
			view: world_async.ChunkVoxelView,
			x, y, z: i32,
		) -> bool {
			offsets := [?]world_async.BlockCoord {
				{1, 0, 0},
				{-1, 0, 0},
				{0, 1, 0},
				{0, -1, 0},
				{0, 0, 1},
				{0, 0, -1},
			}
			for offset in offsets {
				if !terrain_generation_benchmark_cave_block_is_open_or_water(
					view,
					x + offset.x,
					y + offset.y,
					z + offset.z,
				) {
					return false
				}
			}
			return true
		}

		terrain_generation_benchmark_cave_solid_exposed :: proc(
			view: world_async.ChunkVoxelView,
			x, y, z: i32,
		) -> bool {
			offsets := [?]world_async.BlockCoord {
				{1, 0, 0},
				{-1, 0, 0},
				{0, 1, 0},
				{0, -1, 0},
				{0, 0, 1},
				{0, 0, -1},
			}
			for offset in offsets {
				if terrain_generation_benchmark_cave_block_is_open_or_water(
					view,
					x + offset.x,
					y + offset.y,
					z + offset.z,
				) {
					return true
				}
			}
			return false
		}

		terrain_generation_benchmark_cave_physical_stats_add_view :: proc(
			stats: ^TerrainGenerationBenchmarkCavePhysicalStats,
			view: world_async.ChunkVoxelView,
		) {
			chunk_core_27: u32
			chunk_biome_exposed: u32
			for z := i32(0); z < CHUNK_BLOCK_LENGTH; z += 1 {
				for y := i32(0); y < CHUNK_BLOCK_LENGTH; y += 1 {
					for x := i32(0); x < CHUNK_BLOCK_LENGTH; x += 1 {
						index := chunk_block_index(u32(x), u32(y), u32(z))
						palette := terrain_material_palette_index(view.blocks.material_id[index])
						open := view.blocks.occupancy[index] == .Empty
						water := palette == TERRAIN_WATER_MAT_ID
						if open {
							stats.open_blocks += 1
						}
						if water {
							stats.water_blocks += 1
						}
						if open || water {
							terrain_generation_benchmark_cave_shape_stats_add_open_block(
								stats,
								view,
								x,
								y,
								z,
							)
							if terrain_generation_benchmark_cave_open_core_6(view, x, y, z) {
								stats.open_core_6_blocks += 1
							}
							if terrain_generation_benchmark_cave_open_core_27(view, x, y, z) {
								stats.open_core_27_blocks += 1
								chunk_core_27 += 1
							}
							continue
						}

						stats.solid_blocks += 1
						if !terrain_generation_benchmark_cave_solid_exposed(view, x, y, z) {
							continue
						}
						stats.exposed_solid_blocks += 1
						switch palette {
						case TERRAIN_GRASS_MAT_ID:
							stats.exposed_grass_blocks += 1
							if terrain_generation_benchmark_cave_block_is_open_or_water(
								view,
								x,
								y + 1,
								z,
							) {
								stats.exposed_fungal_floor_blocks += 1
								stats.cave_biome_exposed_blocks += 1
								chunk_biome_exposed += 1
							}
						case TERRAIN_DIRT_MAT_ID:
							stats.exposed_dirt_blocks += 1
							if terrain_generation_benchmark_cave_block_is_open_or_water(
								view,
								x,
								y - 1,
								z,
							) {
								stats.exposed_fungal_ceiling_blocks += 1
								stats.cave_biome_exposed_blocks += 1
								chunk_biome_exposed += 1
							}
						case TERRAIN_STONE_MAT_ID:
							stats.exposed_stone_blocks += 1
						case TERRAIN_WET_MARSH_MAT_ID:
							stats.exposed_wet_blocks += 1
							stats.cave_biome_exposed_blocks += 1
							chunk_biome_exposed += 1
						case TERRAIN_CORRUPTED_ASH_MAT_ID:
							stats.exposed_ash_blocks += 1
						case TERRAIN_AQUIFER_WALL_MAT_ID:
							stats.exposed_aquifer_wall_blocks += 1
							stats.cave_biome_exposed_blocks += 1
							chunk_biome_exposed += 1
						case TERRAIN_CRYSTAL_MAT_ID:
							stats.exposed_crystal_blocks += 1
							stats.cave_biome_exposed_blocks += 1
							chunk_biome_exposed += 1
						}
					}
				}
			}

			if chunk_core_27 > stats.max_open_core_27_per_chunk {
				stats.max_open_core_27_per_chunk = chunk_core_27
			}
			if chunk_biome_exposed > stats.max_exposed_biome_per_chunk {
				stats.max_exposed_biome_per_chunk = chunk_biome_exposed
			}
			if chunk_core_27 < stats.min_open_core_27_per_chunk {
				stats.min_open_core_27_per_chunk = chunk_core_27
			}
			if chunk_biome_exposed < stats.min_exposed_biome_per_chunk {
				stats.min_exposed_biome_per_chunk = chunk_biome_exposed
			}
		}

		terrain_generation_benchmark_cave_physical_stats_log :: proc(
			phase: string,
			view: ^world_async.ChunkVoxelView,
			coords: TerrainGenerationBenchmarkCoords,
			seed: u32,
		) {
			stats := TerrainGenerationBenchmarkCavePhysicalStats {
				min_open_core_27_per_chunk  = 0xffffffff,
				min_exposed_biome_per_chunk = 0xffffffff,
			}
			for coord in coords {
				if coord.y >= 0 {
					continue
				}
				stats.chunk_count += 1
				terrain_heightfield_voxel_view_fill(view, coord, seed)
				terrain_generation_benchmark_cave_physical_stats_add_view(&stats, view^)
			}
			if stats.chunk_count == 0 {
				stats.min_open_core_27_per_chunk = 0
				stats.min_exposed_biome_per_chunk = 0
			}
			log.infof(
				"TERRAIN_GENERATION_BENCH_CAVE_PHYSICAL phase=%s chunks=%d open=%d water=%d solid=%d core6=%d core27=%d neighbor_low=%d neighbor_mid=%d neighbor_high=%d chamber_span=%d narrow_span=%d span_x_total=%d span_y_total=%d span_z_total=%d exposed=%d exposed_grass=%d exposed_dirt=%d exposed_stone=%d exposed_wet=%d exposed_ash=%d exposed_aquifer=%d exposed_crystal=%d exposed_fungal_floor=%d exposed_fungal_ceiling=%d biome_exposed=%d min_core27=%d max_core27=%d min_biome_exposed=%d max_biome_exposed=%d",
				phase,
				stats.chunk_count,
				stats.open_blocks,
				stats.water_blocks,
				stats.solid_blocks,
				stats.open_core_6_blocks,
				stats.open_core_27_blocks,
				stats.open_neighbor_low_blocks,
				stats.open_neighbor_mid_blocks,
				stats.open_neighbor_high_blocks,
				stats.chamber_span_blocks,
				stats.narrow_span_blocks,
				stats.axis_span_x_total,
				stats.axis_span_y_total,
				stats.axis_span_z_total,
				stats.exposed_solid_blocks,
				stats.exposed_grass_blocks,
				stats.exposed_dirt_blocks,
				stats.exposed_stone_blocks,
				stats.exposed_wet_blocks,
				stats.exposed_ash_blocks,
				stats.exposed_aquifer_wall_blocks,
				stats.exposed_crystal_blocks,
				stats.exposed_fungal_floor_blocks,
				stats.exposed_fungal_ceiling_blocks,
				stats.cave_biome_exposed_blocks,
				stats.min_open_core_27_per_chunk,
				stats.max_open_core_27_per_chunk,
				stats.min_exposed_biome_per_chunk,
				stats.max_exposed_biome_per_chunk,
			)
		}

		terrain_generation_benchmark_cave_field_stats_log :: proc(
			phase: string,
			coords: TerrainGenerationBenchmarkCoords,
			seed: u32,
		) {
			key := terrain_generation_key_make(seed)
			stats := TerrainGenerationBenchmarkCaveFieldStats{}
			for coord in coords {
				if coord.y >= 0 {
					continue
				}
				stats.chunk_count += 1
				chunk_stamp_count: u32
				origin := chunk_origin_from_coord(coord)
				region_coord := biomes.generation_region_coord_from_block(
					origin.x,
					origin.y,
					origin.z,
				)
				region := terrain_generation_region_for_fill(key, region_coord)
				for z := TERRAIN_CAVE_FIELD_SAMPLE_STEP_BLOCKS / 2;
				    z < CHUNK_BLOCK_LENGTH;
				    z += TERRAIN_CAVE_FIELD_SAMPLE_STEP_BLOCKS {
					world_z := origin.z + z
					for y := TERRAIN_CAVE_FIELD_SAMPLE_STEP_BLOCKS / 2;
					    y < CHUNK_BLOCK_LENGTH;
					    y += TERRAIN_CAVE_FIELD_SAMPLE_STEP_BLOCKS {
						world_y := origin.y + y
						vertical_support := terrain_density_cave_vertical_support(f32(world_y))
						if vertical_support <= 0 {
							continue
						}
						for x := TERRAIN_CAVE_FIELD_SAMPLE_STEP_BLOCKS / 2;
						    x < CHUNK_BLOCK_LENGTH;
						    x += TERRAIN_CAVE_FIELD_SAMPLE_STEP_BLOCKS {
							world_x := origin.x + x
							column := terrain_biome_column_sample_direct(key, world_x, world_z)
							depth_below_surface := column.surface_height_blocks - f32(world_y)
							if depth_below_surface < 18 {
								continue
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
								continue
							}

							path_candidate :=
								terrain_density_cave_field_sample_prefers_path(
									field_sample,
									vertical_support,
								)
							stats.candidate_count += 1
							open_strength := field_sample.open_strength * vertical_support
							radius := biomes.regional_terrain_field_lerp(
								f32(3.5),
								f32(10.5),
								open_strength,
							)
							subterranean_sample := biomes.subterranean_biome_field_sample(
								key,
								world_x,
								world_y,
								world_z,
							)
							if subterranean_sample.cells[0].biome_id == .Fungal_Vaults {
								radius *= 1.25
							} else if subterranean_sample.cells[0].biome_id == .Crystal_Geode_Network {
								radius *= 0.82
							} else if subterranean_sample.cells[0].biome_id == .Buried_Aquifer_Caves {
								radius *= 1.05
							}
							network_sample := terrain_density_cave_field_network_sample(
								&region,
								f32(world_x) + 0.5,
								f32(world_y) + 0.5,
								f32(world_z) + 0.5,
								radius,
								path_candidate,
							)
							if network_sample.connected {
								stats.network_connected_candidate_count += 1
							} else if network_sample.bridgeable {
								stats.network_bridge_candidate_count += 1
							} else {
								stats.network_culled_candidate_count += 1
								continue
							}
							route_promoted_path := false
							if !path_candidate &&
							   terrain_density_cave_field_sample_prefers_route_path(
								   field_sample,
								   vertical_support,
								   network_sample,
							   ) {
								path_candidate = true
								route_promoted_path = true
							}
							if path_candidate {
								stats.path_candidate_count += 1
							} else {
								stats.chamber_candidate_count += 1
							}
							if route_promoted_path {
								stats.route_promoted_path_candidate_count += 1
							}
							route_pocket_candidate :=
								!path_candidate &&
								terrain_density_cave_field_sample_prefers_route_pocket(
									field_sample,
									vertical_support,
									network_sample,
								)
							if route_pocket_candidate {
								stats.route_pocket_candidate_count += 1
							}
							path_route_follow := false
							path_route_vertical := false
							if path_candidate {
								_, path_dir_y, _, route_follow :=
									terrain_density_cave_field_path_direction(
										field_sample,
										network_sample,
									)
								path_route_follow = route_follow
								path_route_vertical = math.abs(path_dir_y) > 0.001
								if path_route_follow {
									stats.route_follow_path_candidate_count += 1
								}
							}
							if chunk_stamp_count >= TERRAIN_CAVE_FIELD_STAMP_CAPACITY_PER_CHUNK {
								continue
							}
							if !path_candidate &&
							   chunk_stamp_count >=
							   TERRAIN_CAVE_FIELD_STAMP_CAPACITY_PER_CHUNK -
							   TERRAIN_CAVE_FIELD_PATH_STAMP_RESERVE_PER_CHUNK {
								continue
							}

							stats.stamp_count += 1
							chunk_stamp_count += 1
							if network_sample.bridgeable {
								stats.network_bridge_stamp_count += 1
							}
							if path_candidate {
								stats.path_stamp_count += 1
								if route_promoted_path {
									stats.route_promoted_path_stamp_count += 1
								}
								if path_route_follow {
									stats.route_follow_path_stamp_count += 1
									if path_route_vertical {
										stats.route_follow_path_vertical_stamp_count += 1
									}
								}
							} else if route_pocket_candidate {
								stats.route_pocket_stamp_count += 1
							} else {
								stats.chamber_stamp_count += 1
							}
							#partial switch subterranean_sample.cells[0].biome_id {
							case .Fungal_Vaults:
								stats.fungal_stamp_count += 1
							case .Crystal_Geode_Network:
								stats.crystal_stamp_count += 1
							case .Buried_Aquifer_Caves:
								stats.aquifer_stamp_count += 1
							}
						}
					}
				}
			}

			log.infof(
				"TERRAIN_GENERATION_BENCH_CAVE_FIELD phase=%s chunks=%d candidates=%d path_candidates=%d chamber_candidates=%d connected_candidates=%d bridge_candidates=%d culled_candidates=%d stamps=%d path_stamps=%d route_pocket_stamps=%d chamber_stamps=%d bridge_stamps=%d route_pocket_candidates=%d route_promoted_path_candidates=%d route_promoted_path_stamps=%d route_follow_path_candidates=%d route_follow_path_stamps=%d route_follow_path_vertical_stamps=%d fungal_stamps=%d crystal_stamps=%d aquifer_stamps=%d",
				phase,
				stats.chunk_count,
				stats.candidate_count,
				stats.path_candidate_count,
				stats.chamber_candidate_count,
				stats.network_connected_candidate_count,
				stats.network_bridge_candidate_count,
				stats.network_culled_candidate_count,
				stats.stamp_count,
				stats.path_stamp_count,
				stats.route_pocket_stamp_count,
				stats.chamber_stamp_count,
				stats.network_bridge_stamp_count,
				stats.route_pocket_candidate_count,
				stats.route_promoted_path_candidate_count,
				stats.route_promoted_path_stamp_count,
				stats.route_follow_path_candidate_count,
				stats.route_follow_path_stamp_count,
				stats.route_follow_path_vertical_stamp_count,
				stats.fungal_stamp_count,
				stats.crystal_stamp_count,
				stats.aquifer_stamp_count,
			)
		}

		terrain_generation_benchmark_cave_node_index_by_id :: proc(
			region: ^biomes.GenerationRegion,
			id: biomes.FeatureID,
		) -> (
			node_index: u32,
			found: bool,
		) {
			for i := u32(0); i < region.cave_network_node_count; i += 1 {
				if region.cave_network_nodes[i].id == id {
					return i, true
				}
			}
			return 0, false
		}

		terrain_generation_benchmark_region_component_stats_add :: proc(
			stats: ^TerrainGenerationBenchmarkRegionStats,
			region: ^biomes.GenerationRegion,
		) {
			visited: [biomes.GENERATION_REGION_CAVE_NETWORK_NODE_CAPACITY]bool
			for start_index := u32(0);
			    start_index < region.cave_network_node_count;
			    start_index += 1 {
				if visited[start_index] {
					continue
				}

				stats.component_count += 1
				queue: [biomes.GENERATION_REGION_CAVE_NETWORK_NODE_CAPACITY]u32
				queue_head: u32
				queue_tail: u32
				component_node_count: u32
				component_anchor_count: u32
				component_mouth_count: u32
				component_sinkhole_count: u32
				component_required_count: u32
				component_large_room_count: u32
				component_external_link_count: u32

				visited[start_index] = true
				queue[queue_tail] = start_index
				queue_tail += 1

				for queue_head < queue_tail {
					node_index := queue[queue_head]
					queue_head += 1
					component_node_count += 1
					node := region.cave_network_nodes[node_index]

					if biomes.cave_region_role_requires_connectivity(node.role) {
						component_required_count += 1
					}
					if terrain_density_cave_node_uses_profile_room(node) ||
					   node.radius_blocks >= TERRAIN_CAVE_NODE_ISOLATED_CULL_RADIUS_BLOCKS {
						component_large_room_count += 1
					}
					for anchor_index := u32(0);
					    anchor_index < region.cave_anchor_count;
					    anchor_index += 1 {
						anchor := region.cave_anchors[anchor_index]
						if anchor.feature_id != node.id &&
						   anchor.target_feature_id != node.id {
							continue
						}
						component_anchor_count += 1
						#partial switch anchor.kind {
						case .Cave_Mouth:
							component_mouth_count += 1
						case .Sinkhole:
							component_sinkhole_count += 1
						}
					}

					for edge_index := u32(0);
					    edge_index < region.cave_network_edge_count;
					    edge_index += 1 {
						edge := region.cave_network_edges[edge_index]
						neighbor_id: biomes.FeatureID
						if edge.from_node_id == node.id {
							neighbor_id = edge.to_node_id
						} else if edge.to_node_id == node.id {
							neighbor_id = edge.from_node_id
						} else {
							continue
						}
						neighbor_index, neighbor_found :=
							terrain_generation_benchmark_cave_node_index_by_id(
								region,
								neighbor_id,
							)
						if !neighbor_found {
							component_external_link_count += 1
							continue
						}
						if !visited[neighbor_index] {
							visited[neighbor_index] = true
							queue[queue_tail] = neighbor_index
							queue_tail += 1
						}
					}
				}

				stats.component_external_link_count += component_external_link_count
				if component_node_count > stats.component_max_nodes {
					stats.component_max_nodes = component_node_count
				}
				tiny_component :=
					component_node_count <=
					TERRAIN_GENERATION_BENCHMARK_TINY_CAVE_COMPONENT_NODE_MAX &&
					component_external_link_count == 0
				if tiny_component {
					stats.component_tiny_count += 1
					stats.component_tiny_node_count += component_node_count
					if component_anchor_count > 0 {
						stats.component_anchored_tiny_count += 1
					}
					if component_mouth_count > 0 {
						stats.component_mouth_tiny_count += 1
					}
					if component_sinkhole_count > 0 {
						stats.component_sinkhole_tiny_count += 1
					}
					if component_required_count > 0 {
						stats.component_required_tiny_count += 1
					}
					if component_large_room_count > 0 {
						stats.component_large_room_tiny_count += 1
					}
				}
			}
		}

		terrain_generation_benchmark_region_stats_from_region :: proc(
			region: ^biomes.GenerationRegion,
		) -> TerrainGenerationBenchmarkRegionStats {
			stats := TerrainGenerationBenchmarkRegionStats {
				node_count                  = region.cave_network_node_count,
				edge_count                  = region.cave_network_edge_count,
				anchor_count                = region.cave_anchor_count,
				water_feature_node_count    = region.water_feature_node_count,
				water_feature_segment_count = region.water_feature_segment_count,
				water_feature_anchor_count  = region.water_feature_anchor_count,
			}
			terrain_generation_benchmark_region_component_stats_add(&stats, region)
			for i := u32(0); i < region.cave_network_node_count; i += 1 {
				node := region.cave_network_nodes[i]
				connectivity := terrain_density_cave_node_connectivity(region, node)
				if connectivity.has_edge {
					stats.node_edge_connected_count += 1
				}
				if connectivity.has_anchor {
					stats.node_anchor_connected_count += 1
				}
				if connectivity.should_bridge {
					stats.node_bridge_count += 1
				}
				if !connectivity.should_carve {
					stats.node_culled_count += 1
				}
				if terrain_density_cave_node_uses_profile_room(node) {
					stats.profile_room_node_count += 1
					if !node.major_region {
						stats.profile_room_nonmajor_count += 1
					}
				}
				#partial switch node.role {
				case .Major_Region:
					stats.major_count += 1
				case .Water_Linked_Region:
					stats.water_linked_count += 1
				case .Connector:
					stats.connector_count += 1
				case .Resource_Chamber:
					stats.resource_count += 1
				case .Sealed_Secret:
					stats.sealed_count += 1
				case .Pocket:
					stats.pocket_count += 1
				}
				#partial switch node.biome_id {
				case .Fungal_Vaults:
					stats.fungal_count += 1
				case .Crystal_Geode_Network:
					stats.crystal_count += 1
				case .Buried_Aquifer_Caves:
					stats.aquifer_count += 1
				}
				_, macro_zone, depth_band, _ := biomes.subterranean_biome_identity_select(
					region.key,
					node.owner,
				)
				#partial switch macro_zone {
				case .Rooted:
					stats.rooted_macro_count += 1
				case .Mineral:
					stats.mineral_macro_count += 1
				case .Aquifer:
					stats.aquifer_macro_count += 1
				}
				#partial switch depth_band {
				case .Shallow:
					stats.shallow_depth_count += 1
				case .Mid:
					stats.mid_depth_count += 1
				case .Deep:
					stats.deep_depth_count += 1
				}
			}
			for i := u32(0); i < region.cave_network_edge_count; i += 1 {
				edge := region.cave_network_edges[i]
				#partial switch edge.kind {
				case .Tunnel:
					stats.tunnel_edge_count += 1
				case .Canyon:
					stats.canyon_edge_count += 1
				case .Worm_Path:
					stats.worm_edge_count += 1
				case .Flooded_Passage:
					stats.flooded_edge_count += 1
				case .Fracture:
					stats.fracture_edge_count += 1
				case .Collapsed_Corridor:
					stats.collapsed_edge_count += 1
				case .Vertical_Shaft:
					stats.vertical_edge_count += 1
				}
			}
			for i := u32(0); i < region.cave_anchor_count; i += 1 {
				anchor := region.cave_anchors[i]
				#partial switch anchor.kind {
				case .Cave_Mouth:
					stats.cave_mouth_count += 1
				case .Sinkhole:
					stats.sinkhole_count += 1
				case .Lakebed_Breach, .Seabed_Breach, .Underground_River_Source,
				     .Underground_River_Sink:
					stats.water_anchor_count += 1
				}
			}
			return stats
		}

		terrain_generation_benchmark_region_stats_add :: proc(
			total: ^TerrainGenerationBenchmarkRegionStats,
			stats: TerrainGenerationBenchmarkRegionStats,
		) {
			total.node_count += stats.node_count
			total.edge_count += stats.edge_count
			total.anchor_count += stats.anchor_count
			total.water_feature_node_count += stats.water_feature_node_count
			total.water_feature_segment_count += stats.water_feature_segment_count
			total.water_feature_anchor_count += stats.water_feature_anchor_count
			total.major_count += stats.major_count
			total.water_linked_count += stats.water_linked_count
			total.connector_count += stats.connector_count
			total.pocket_count += stats.pocket_count
			total.resource_count += stats.resource_count
			total.sealed_count += stats.sealed_count
			total.fungal_count += stats.fungal_count
			total.crystal_count += stats.crystal_count
			total.aquifer_count += stats.aquifer_count
			total.rooted_macro_count += stats.rooted_macro_count
			total.mineral_macro_count += stats.mineral_macro_count
			total.aquifer_macro_count += stats.aquifer_macro_count
			total.shallow_depth_count += stats.shallow_depth_count
			total.mid_depth_count += stats.mid_depth_count
			total.deep_depth_count += stats.deep_depth_count
			total.cave_mouth_count += stats.cave_mouth_count
			total.sinkhole_count += stats.sinkhole_count
			total.water_anchor_count += stats.water_anchor_count
			total.tunnel_edge_count += stats.tunnel_edge_count
			total.canyon_edge_count += stats.canyon_edge_count
			total.worm_edge_count += stats.worm_edge_count
			total.flooded_edge_count += stats.flooded_edge_count
			total.fracture_edge_count += stats.fracture_edge_count
			total.collapsed_edge_count += stats.collapsed_edge_count
			total.vertical_edge_count += stats.vertical_edge_count
			total.node_edge_connected_count += stats.node_edge_connected_count
			total.node_anchor_connected_count += stats.node_anchor_connected_count
			total.node_bridge_count += stats.node_bridge_count
			total.node_culled_count += stats.node_culled_count
			total.profile_room_node_count += stats.profile_room_node_count
			total.profile_room_nonmajor_count += stats.profile_room_nonmajor_count
			total.component_count += stats.component_count
			total.component_tiny_count += stats.component_tiny_count
			total.component_tiny_node_count += stats.component_tiny_node_count
			total.component_external_link_count += stats.component_external_link_count
			total.component_anchored_tiny_count += stats.component_anchored_tiny_count
			total.component_mouth_tiny_count += stats.component_mouth_tiny_count
			total.component_sinkhole_tiny_count += stats.component_sinkhole_tiny_count
			total.component_required_tiny_count += stats.component_required_tiny_count
			total.component_large_room_tiny_count += stats.component_large_room_tiny_count
			total.component_max_nodes = math.max(
				total.component_max_nodes,
				stats.component_max_nodes,
			)
		}

		terrain_generation_benchmark_region_stats_log_one :: proc(
			region_coord: biomes.GenerationRegionCoord,
			stats: TerrainGenerationBenchmarkRegionStats,
		) {
			log.infof(
				"TERRAIN_GENERATION_BENCH_REGION coord=(%d,%d,%d) nodes=%d edges=%d anchors=%d water_nodes=%d water_segments=%d water_feature_anchors=%d major=%d water_linked=%d connector=%d pocket=%d resource=%d sealed=%d fungal=%d crystal=%d aquifer=%d rooted_macro=%d mineral_macro=%d aquifer_macro=%d shallow=%d mid=%d deep=%d cave_mouth=%d sinkhole=%d water_anchor=%d edge_tunnel=%d edge_canyon=%d edge_worm=%d edge_flooded=%d edge_fracture=%d edge_collapsed=%d edge_vertical=%d node_edge_connected=%d node_anchor_connected=%d node_bridge=%d node_culled=%d profile_room=%d profile_room_nonmajor=%d components=%d tiny_components=%d tiny_component_nodes=%d component_external_links=%d anchored_tiny_components=%d mouth_tiny_components=%d sinkhole_tiny_components=%d required_tiny_components=%d large_room_tiny_components=%d max_component_nodes=%d",
				region_coord.x,
				region_coord.y,
				region_coord.z,
				stats.node_count,
				stats.edge_count,
				stats.anchor_count,
				stats.water_feature_node_count,
				stats.water_feature_segment_count,
				stats.water_feature_anchor_count,
				stats.major_count,
				stats.water_linked_count,
				stats.connector_count,
				stats.pocket_count,
				stats.resource_count,
				stats.sealed_count,
				stats.fungal_count,
				stats.crystal_count,
				stats.aquifer_count,
				stats.rooted_macro_count,
				stats.mineral_macro_count,
				stats.aquifer_macro_count,
				stats.shallow_depth_count,
				stats.mid_depth_count,
				stats.deep_depth_count,
				stats.cave_mouth_count,
				stats.sinkhole_count,
				stats.water_anchor_count,
				stats.tunnel_edge_count,
				stats.canyon_edge_count,
				stats.worm_edge_count,
				stats.flooded_edge_count,
				stats.fracture_edge_count,
				stats.collapsed_edge_count,
				stats.vertical_edge_count,
				stats.node_edge_connected_count,
				stats.node_anchor_connected_count,
				stats.node_bridge_count,
				stats.node_culled_count,
				stats.profile_room_node_count,
				stats.profile_room_nonmajor_count,
				stats.component_count,
				stats.component_tiny_count,
				stats.component_tiny_node_count,
				stats.component_external_link_count,
				stats.component_anchored_tiny_count,
				stats.component_mouth_tiny_count,
				stats.component_sinkhole_tiny_count,
				stats.component_required_tiny_count,
				stats.component_large_room_tiny_count,
				stats.component_max_nodes,
			)
		}

		terrain_generation_benchmark_region_stats_log :: proc(
			coords: TerrainGenerationBenchmarkCoords,
			seed: u32,
		) {
			key := terrain_generation_key_make(seed)
			seen_coords: [TERRAIN_GENERATION_BENCHMARK_COORD_COUNT]biomes.GenerationRegionCoord
			seen_count: u32
			total := TerrainGenerationBenchmarkRegionStats{}

			for chunk_coord in coords {
				origin := chunk_origin_from_coord(chunk_coord)
				region_coord := biomes.generation_region_coord_from_block(
					origin.x,
					origin.y,
					origin.z,
				)
				seen := false
				for i := u32(0); i < seen_count; i += 1 {
					if seen_coords[i] == region_coord {
						seen = true
						break
					}
				}
				if seen {
					continue
				}
				seen_coords[seen_count] = region_coord
				seen_count += 1

				region := terrain_generation_region_for_fill(key, region_coord)
				stats := terrain_generation_benchmark_region_stats_from_region(&region)
				terrain_generation_benchmark_region_stats_add(&total, stats)
				terrain_generation_benchmark_region_stats_log_one(region_coord, stats)
			}
			log.infof(
				"TERRAIN_GENERATION_BENCH_REGION_SUMMARY regions=%d nodes=%d edges=%d anchors=%d water_nodes=%d water_segments=%d water_feature_anchors=%d major=%d water_linked=%d connector=%d pocket=%d resource=%d sealed=%d fungal=%d crystal=%d aquifer=%d rooted_macro=%d mineral_macro=%d aquifer_macro=%d shallow=%d mid=%d deep=%d cave_mouth=%d sinkhole=%d water_anchor=%d edge_tunnel=%d edge_canyon=%d edge_worm=%d edge_flooded=%d edge_fracture=%d edge_collapsed=%d edge_vertical=%d node_edge_connected=%d node_anchor_connected=%d node_bridge=%d node_culled=%d profile_room=%d profile_room_nonmajor=%d components=%d tiny_components=%d tiny_component_nodes=%d component_external_links=%d anchored_tiny_components=%d mouth_tiny_components=%d sinkhole_tiny_components=%d required_tiny_components=%d large_room_tiny_components=%d max_component_nodes=%d",
				seen_count,
				total.node_count,
				total.edge_count,
				total.anchor_count,
				total.water_feature_node_count,
				total.water_feature_segment_count,
				total.water_feature_anchor_count,
				total.major_count,
				total.water_linked_count,
				total.connector_count,
				total.pocket_count,
				total.resource_count,
				total.sealed_count,
				total.fungal_count,
				total.crystal_count,
				total.aquifer_count,
				total.rooted_macro_count,
				total.mineral_macro_count,
				total.aquifer_macro_count,
				total.shallow_depth_count,
				total.mid_depth_count,
				total.deep_depth_count,
				total.cave_mouth_count,
				total.sinkhole_count,
				total.water_anchor_count,
				total.tunnel_edge_count,
				total.canyon_edge_count,
				total.worm_edge_count,
				total.flooded_edge_count,
				total.fracture_edge_count,
				total.collapsed_edge_count,
				total.vertical_edge_count,
				total.node_edge_connected_count,
				total.node_anchor_connected_count,
				total.node_bridge_count,
				total.node_culled_count,
				total.profile_room_node_count,
				total.profile_room_nonmajor_count,
				total.component_count,
				total.component_tiny_count,
				total.component_tiny_node_count,
				total.component_external_link_count,
				total.component_anchored_tiny_count,
				total.component_mouth_tiny_count,
				total.component_sinkhole_tiny_count,
				total.component_required_tiny_count,
				total.component_large_room_tiny_count,
				total.component_max_nodes,
			)
		}
		terrain_generation_benchmark_run_phase :: proc(
			phase: string,
			coords: TerrainGenerationBenchmarkCoords,
			seed: u32,
			iterations: u32,
			reset_cache_each_iteration: bool,
			view: ^world_async.ChunkVoxelView,
		) {
			log.assertf(iterations > 0, "terrain generation benchmark iterations must be greater than zero")
			terrain_generation_benchmark_cache_clear()
			for coord in coords {
				terrain_heightfield_voxel_view_fill(view, coord, seed)
			}

			start := time.tick_now()
			for _ in 0 ..< iterations {
				if reset_cache_each_iteration {
					terrain_generation_benchmark_cache_clear()
				}
				for coord in coords {
					terrain_heightfield_voxel_view_fill(view, coord, seed)
				}
			}
			duration := time.tick_since(start)

			chunk_iterations := iterations * u32(len(coords))
			checksum, solid_count, water_count :=
				terrain_generation_benchmark_checksum_coords(view, coords, seed)
			total_ms := time.duration_milliseconds(duration)
			avg_us := time.duration_microseconds(duration) / f64(chunk_iterations)
			log.infof(
				"TERRAIN_GENERATION_BENCH phase=%s iterations=%d chunk_iterations=%d total_ms=%.3f avg_us_per_chunk=%.3f checksum=%d solid_count=%d water_count=%d reset_cache=%v",
				phase,
				iterations,
				chunk_iterations,
				total_ms,
				avg_us,
				checksum,
				solid_count,
				water_count,
				reset_cache_each_iteration,
			)
		}

		terrain_generation_benchmark_runs_run :: proc(
			transient_arena: ^mem.Arena,
			iterations: u32,
		) {
			log.assert(transient_arena != nil, "terrain generation benchmark transient arena must not be nil")
			log.assertf(iterations > 0, "terrain generation benchmark iterations must be greater than zero")

			temp := mem.begin_arena_temp_memory(transient_arena)
			defer mem.end_arena_temp_memory(temp)
			allocator := mem.arena_allocator(transient_arena)

			view := world_async.ChunkVoxelView{}
			chunk_voxel_view_alloc(&view, allocator)
			seed := u32(0)
			key := terrain_generation_key_make(seed)
			cave_field_path_selection := terrain_generation_benchmark_cave_field_path_selection(key)
			cave_coords := terrain_generation_benchmark_cave_coords_make(
				key,
				cave_field_path_selection,
			)
			surface_water_coords := terrain_generation_benchmark_surface_water_coords_make(key)
			surface_cave_anchors := terrain_generation_benchmark_surface_cave_anchors_pick(key)
			surface_cave_coords := terrain_generation_benchmark_surface_cave_coords_make(
				surface_cave_anchors,
			)

			log.infof(
				"TERRAIN_GENERATION_BENCH_START iterations=%d cave_coords=%d surface_water_coords=%d surface_cave_coords=%d chunk_blocks=%d",
				iterations,
				len(cave_coords),
				len(surface_water_coords),
				len(surface_cave_coords),
				CHUNK_BLOCK_COUNT,
			)
			terrain_generation_benchmark_cave_selections_log(key)
			terrain_generation_benchmark_cave_field_path_selection_log(cave_field_path_selection)
			terrain_generation_benchmark_region_stats_log(cave_coords, seed)
			terrain_generation_benchmark_cave_physical_stats_log(
				"cave_physical_pre",
				&view,
				cave_coords,
				seed,
			)
			terrain_generation_benchmark_cave_field_stats_log(
				"cave_field_pre",
				cave_coords,
				seed,
			)
			terrain_generation_benchmark_surface_water_stats_log(
				"surface_water_pre",
				surface_water_coords,
				seed,
			)
			terrain_generation_benchmark_surface_cave_scan_stats_log(
				"surface_cave_scan",
				key,
			)
			terrain_generation_benchmark_surface_cave_scan_stats_log_multi(
				"surface_cave_scan_multi",
			)
			terrain_generation_benchmark_surface_cave_stats_log(
				"surface_cave_pre",
				&view,
				surface_cave_coords,
				surface_cave_anchors,
				seed,
			)
			terrain_generation_benchmark_surface_cave_mouth_size_stats_log(
				"surface_cave_pre",
				"small",
				&view,
				surface_cave_anchors.mouth_small,
				surface_cave_anchors.mouth_small_node,
				surface_cave_anchors.mouth_small_found,
				seed,
			)
			terrain_generation_benchmark_surface_cave_mouth_size_stats_log(
				"surface_cave_pre",
				"medium",
				&view,
				surface_cave_anchors.mouth_medium,
				surface_cave_anchors.mouth_medium_node,
				surface_cave_anchors.mouth_medium_found,
				seed,
			)
			terrain_generation_benchmark_surface_cave_mouth_size_stats_log(
				"surface_cave_pre",
				"large",
				&view,
				surface_cave_anchors.mouth_large,
				surface_cave_anchors.mouth_large_node,
				surface_cave_anchors.mouth_large_found,
				seed,
			)
			terrain_generation_benchmark_run_phase(
				"cave_hot_region_cache",
				cave_coords,
				seed,
				iterations,
				false,
				&view,
			)
			terrain_generation_benchmark_run_phase(
				"surface_water_hot_region_cache",
				surface_water_coords,
				seed,
				iterations,
				false,
				&view,
			)
			terrain_generation_benchmark_run_phase(
				"surface_cave_hot_region_cache",
				surface_cave_coords,
				seed,
				iterations,
				false,
				&view,
			)
			when TERRAIN_GENERATION_BENCHMARK_RESET_CACHE {
				terrain_generation_benchmark_run_phase(
					"cave_reset_region_cache",
					cave_coords,
					seed,
					iterations,
					true,
					&view,
				)
				terrain_generation_benchmark_run_phase(
					"surface_water_reset_region_cache",
					surface_water_coords,
					seed,
					iterations,
					true,
					&view,
				)
				terrain_generation_benchmark_run_phase(
					"surface_cave_reset_region_cache",
					surface_cave_coords,
					seed,
					iterations,
					true,
					&view,
				)
			}
			log.info("TERRAIN_GENERATION_BENCH_END")
		}

	}

}
