package gfx

import world "app:world"
import world_async "async:world"
import camera "gfx:camera"

import "core:log"
import math "core:math"
import "core:mem"
import "core:slice"
import time "core:time"

//////////////////////////////////////
// Benchmarking Constants
/////////////////////////////////////

when ODIN_DEBUG {

	RUN_CULLING_BENCHMARK :: #config(RUN_CULLING_BENCHMARK, false)
	CULLING_BENCHMARK_ITERATIONS :: #config(CULLING_BENCHMARK_ITERATIONS, 10_000)

	benchmarks_debug_contracts_run :: proc(
		persistent_allocator: mem.Allocator,
		transient_arena: ^mem.Arena,
	) {
		log.assertf(world.CHUNK_STORE_CAPACITY > 0, "chunk store capacity must be positive")
		log.assertf(math.to_radians_f32(FOV) > 0, "field of view must be positive")
		log.assert(transient_arena != nil, "benchmark transient arena must not be nil")
		_ = persistent_allocator
		_ = camera.Camera{}
		_ = world_async.ChunkGenerationJob{}
		_ = time.Duration(0)

		values := [?]int{0}
		slice.sort_by(values[:], benchmarks_debug_int_less)
	}

	benchmarks_debug_int_less :: proc(a, b: int) -> bool {
		return a < b
	}

	when RUN_CULLING_BENCHMARK {

		//////////////////////////////////////
		// Culling Benchmark Types
		/////////////////////////////////////

		CullingBenchmarkCaseKind :: enum {
			Full_Chunks,
			Sparse_Subchunks,
			Dense_Subchunks,
		}

		CullingBenchmarkStats :: struct {
			chunks_total:                u64,
			chunks_without_geometry:     u64,
			chunks_frustum_culled:       u64,
			chunks_drawn:                u64,
			draw_units_tested:           u64,
			draw_units_frustum_culled:   u64,
			draw_units_occlusion_culled: u64,
			draw_units_drawn:            u64,
		}

		//////////////////////////////////////
		// Culling Benchmark Async Adapters
		/////////////////////////////////////

		culling_benchmark_generation_request :: proc(job: world_async.ChunkGenerationJob) -> bool {
			_ = job
			return false
		}

		culling_benchmark_generation_poll_results :: proc(
			results: []world_async.ChunkGenerationJobResult,
		) -> u32 {
			_ = results
			return 0
		}

		culling_benchmark_mesh_request :: proc(job: world_async.ChunkMeshJob) -> bool {
			_ = job
			return false
		}

		culling_benchmark_mesh_poll_results :: proc(
			results: []world_async.ChunkMeshJobResult,
		) -> u32 {
			_ = results
			return 0
		}

		culling_benchmark_mesh_release_result :: proc(result: world_async.ChunkMeshJobResult) {
			_ = result
		}

		culling_benchmark_chunk_mesh_upload :: proc(
			old_id: world.ChunkGeometryID,
			output: world_async.ChunkMeshOutput,
		) -> world.ChunkGeometryID {
			_ = output
			return old_id
		}

		culling_benchmark_chunk_geometry_release :: proc(id: world.ChunkGeometryID) {
			_ = id
		}

		//////////////////////////////////////
		// Culling Benchmark Methods
		/////////////////////////////////////

		culling_benchmark_stats_from_camera :: proc(
			stats: camera.TerrainCullingStats,
		) -> CullingBenchmarkStats {
			return {
				chunks_total = u64(stats.chunks_total),
				chunks_without_geometry = u64(stats.chunks_without_geometry),
				chunks_frustum_culled = u64(stats.chunks_frustum_culled),
				chunks_drawn = u64(stats.chunks_drawn),
				draw_units_tested = u64(stats.draw_units_tested),
				draw_units_frustum_culled = u64(stats.draw_units_frustum_culled),
				draw_units_occlusion_culled = u64(stats.draw_units_occlusion_culled),
				draw_units_drawn = u64(stats.draw_units_drawn),
			}
		}

		culling_benchmark_fake_geometry_id :: proc(index: u32) -> world.ChunkGeometryID {
			return world.ChunkGeometryID(index + 1)
		}

		culling_benchmark_camera_setup :: proc() -> camera.Camera {
			return {
				position = {0.0, 16.0, -64.0},
				forward = {0.0, 0.0, 1.0},
				up = {0.0, 1.0, 0.0},
				right = {1.0, 0.0, 0.0},
				world_up = {0.0, 1.0, 0.0},
				yaw = 0.0,
				pitch = 0.0,
				near_plane = 0.1,
				far_plane = 260.0,
			}
		}

		culling_benchmark_case_name :: proc(kind: CullingBenchmarkCaseKind) -> string {
			switch kind {
			case .Full_Chunks:
				return "full_chunks"
			case .Sparse_Subchunks:
				return "sparse_subchunks"
			case .Dense_Subchunks:
				return "dense_subchunks"
			}
			return "unknown"
		}

		culling_benchmark_subchunk_is_sparse :: proc(subchunk_index: u32) -> bool {
			x, y, z := world.chunk_subchunk_coord_from_index(subchunk_index)
			return(
				(x == 0 || x == world.CHUNK_SUBCHUNK_COUNT_PER_AXIS - 1) &&
				(y == 1 || y == 2) &&
				(z == 0 || z == world.CHUNK_SUBCHUNK_COUNT_PER_AXIS - 1) \
			)
		}

		culling_benchmark_case_setup :: proc(kind: CullingBenchmarkCaseKind) {
			world.chunk_store_clear()

			chunk_index: u32
			for z := i32(0); z < 8; z += 1 {
				for x := i32(-8); x < 8; x += 1 {
					chunk_id := world.chunk_store_append_reserved({x, 0, z})
					chunk := world.chunk_store_get_by_id(chunk_id)
					chunk.generation_state = .Generated
					chunk.mesh_state = .Ready
					chunk.block_version = 1
					chunk.mesh_version = 1

					switch kind {
					case .Full_Chunks:
						chunk.geometry_id = culling_benchmark_fake_geometry_id(chunk_index)
					case .Sparse_Subchunks:
						for subchunk_index := u32(0);
						    subchunk_index < world.CHUNK_SUBCHUNK_COUNT;
						    subchunk_index += 1 {
							if !culling_benchmark_subchunk_is_sparse(subchunk_index) {
								continue
							}
							geometry_id := culling_benchmark_fake_geometry_id(
								chunk_index * world.CHUNK_SUBCHUNK_COUNT + subchunk_index,
							)
							world.chunk_subchunk_geometry_set(chunk, subchunk_index, geometry_id)
						}
					case .Dense_Subchunks:
						for subchunk_index := u32(0);
						    subchunk_index < world.CHUNK_SUBCHUNK_COUNT;
						    subchunk_index += 1 {
							geometry_id := culling_benchmark_fake_geometry_id(
								chunk_index * world.CHUNK_SUBCHUNK_COUNT + subchunk_index,
							)
							world.chunk_subchunk_geometry_set(chunk, subchunk_index, geometry_id)
						}
					}

					chunk_index += 1
				}
			}
		}

		culling_benchmark_current_once :: proc(
			frustum: camera.Frustum,
			benchmark_camera: camera.Camera,
			transient_arena: ^mem.Arena,
			sort_visible: bool = true,
		) -> CullingBenchmarkStats {
			chunks := world.chunk_store_chunks()
			draw_item_capacity := len(chunks) + int(world.chunk_store_subchunk_geometry_count())
			observer := world.chunk_visibility_observer_from_world_position(
				benchmark_camera.position,
			)
			stats := camera.TerrainCullingStats{}
			sort_visible_items :=
				sort_visible && camera.terrain_visible_items_should_sort(draw_item_capacity)
			if !sort_visible_items {
				camera.terrain_visible_unsorted_walk(frustum, observer, &stats)
				return culling_benchmark_stats_from_camera(stats)
			}

			temp := mem.begin_arena_temp_memory(transient_arena)
			defer mem.end_arena_temp_memory(temp)
			allocator := mem.arena_allocator(transient_arena)

			draw_items := make([]camera.TerrainDrawItem, draw_item_capacity, allocator)
			draw_count := camera.terrain_visible_items_gather(
				frustum,
				observer,
				benchmark_camera.position,
				draw_items,
				&stats,
				sort_visible_items,
			)
			visible_items := draw_items[:draw_count]
			if sort_visible_items && len(visible_items) > 1 {
				slice.sort_by(visible_items, camera.terrain_draw_item_less)
			}
			stats.draw_units_drawn = u32(draw_count)
			return culling_benchmark_stats_from_camera(stats)
		}

		culling_benchmark_stats_checksum :: proc(stats: CullingBenchmarkStats) -> u64 {
			return(
				stats.chunks_total +
				stats.chunks_without_geometry * 3 +
				stats.chunks_frustum_culled * 5 +
				stats.chunks_drawn * 7 +
				stats.draw_units_tested * 11 +
				stats.draw_units_frustum_culled * 13 +
				stats.draw_units_occlusion_culled * 17 +
				stats.draw_units_drawn * 19 \
			)
		}

		culling_benchmark_log_result :: proc(
			case_name, mode: string,
			iterations: u32,
			duration: time.Duration,
			stats: CullingBenchmarkStats,
			checksum: u64,
		) {
			total_ms := time.duration_milliseconds(duration)
			avg_us := time.duration_microseconds(duration) / f64(iterations)
			log.infof(
				"CULL_BENCH case=%s mode=%s iterations=%d total_ms=%.3f avg_us=%.3f chunks=%d chunks_culled=%d draw_units_tested=%d draw_units_frustum_culled=%d draw_units_occlusion_culled=%d draw_units_drawn=%d checksum=%d",
				case_name,
				mode,
				iterations,
				total_ms,
				avg_us,
				stats.chunks_total,
				stats.chunks_frustum_culled,
				stats.draw_units_tested,
				stats.draw_units_frustum_culled,
				stats.draw_units_occlusion_culled,
				stats.draw_units_drawn,
				checksum,
			)
		}

		culling_benchmark_run_mode :: proc(
			case_name, mode: string,
			iterations: u32,
			frustum: camera.Frustum,
			benchmark_camera: camera.Camera,
			transient_arena: ^mem.Arena,
			sort_visible: bool = true,
		) {
			log.assertf(iterations > 0, "culling benchmark iterations must be greater than zero")

			stats := culling_benchmark_current_once(
				frustum,
				benchmark_camera,
				transient_arena,
				sort_visible,
			)
			checksum := culling_benchmark_stats_checksum(stats)

			start := time.tick_now()
			for _ in 0 ..< iterations {
				run_stats := culling_benchmark_current_once(
					frustum,
					benchmark_camera,
					transient_arena,
					sort_visible,
				)
				checksum += culling_benchmark_stats_checksum(run_stats)
			}
			duration := time.tick_since(start)

			culling_benchmark_log_result(case_name, mode, iterations, duration, stats, checksum)
		}

		culling_benchmark_runs_run :: proc(
			iterations: u32,
			persistent_allocator: mem.Allocator,
			transient_arena: ^mem.Arena,
		) {
			world.init(
				{
					persistent_allocator = persistent_allocator,
					generation_request = culling_benchmark_generation_request,
					generation_poll_results = culling_benchmark_generation_poll_results,
					mesh_request = culling_benchmark_mesh_request,
					mesh_poll_results = culling_benchmark_mesh_poll_results,
					mesh_release_result = culling_benchmark_mesh_release_result,
					chunk_mesh_upload = culling_benchmark_chunk_mesh_upload,
					chunk_geometry_release = culling_benchmark_chunk_geometry_release,
				},
			)
			defer world.shutdown()

			benchmark_camera := culling_benchmark_camera_setup()
			frustum := camera.frustum_from_camera(
				benchmark_camera,
				math.to_radians_f32(FOV),
				ASPECT_RATIO,
			)
			cases := [?]CullingBenchmarkCaseKind{.Full_Chunks, .Sparse_Subchunks, .Dense_Subchunks}

			log.infof(
				"CULL_BENCH_START iterations=%d chunks=%d",
				iterations,
				world.CHUNK_STORE_CAPACITY,
			)
			for kind in cases {
				culling_benchmark_case_setup(kind)
				case_name := culling_benchmark_case_name(kind)
				culling_benchmark_run_mode(
					case_name,
					"current_no_sort",
					iterations,
					frustum,
					benchmark_camera,
					transient_arena,
					false,
				)
				culling_benchmark_run_mode(
					case_name,
					"current_visibility",
					iterations,
					frustum,
					benchmark_camera,
					transient_arena,
				)
			}
		}

	}

}
