package world

import world_async "async:world"

import "core:log"
import "core:mem"
import time "core:time"

//////////////////////////////////////
// Benchmarking
/////////////////////////////////////

when ODIN_DEBUG {

	RUN_MESH_BENCHMARK :: #config(RUN_MESH_BENCHMARK, false)
	MESH_BENCHMARK_ITERATIONS :: #config(MESH_BENCHMARK_ITERATIONS, 8)

	chunk_mesher_benchmarks_debug_contracts_run :: proc(transient_arena: ^mem.Arena) {
		log.assert(transient_arena != nil, "benchmark transient arena must not be nil")
		_ = world_async.ChunkVoxelView{}
		_ = time.Duration(0)
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

}
