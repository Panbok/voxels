package world

import bench "app:bench"
import world_async "async:world"
import biomes "world:biomes"

import "core:fmt"
import "core:log"
import "core:math"
import "core:mem"
import "core:os"
import "core:strings"
import time "core:time"

//////////////////////////////////////
// Benchmarking
/////////////////////////////////////

WORLD_MESH_BENCHMARK_LEGACY_ITERATIONS :: 8
WORLD_MESH_BENCHMARK_VERSION :: "1"
TERRAIN_GENERATION_BENCHMARK_VERSION :: "1"
TERRAIN_GENERATION_DIAGNOSTIC_BENCHMARK_VERSION :: "1"
TERRAIN_COMPONENT_BENCHMARK_VERSION :: "1"
TERRAIN_GENERATION_LEGACY_ITERATIONS :: 1
TERRAIN_GENERATION_LEGACY_RESET_CACHE :: true
TERRAIN_GENERATION_LEGACY_CAVE_ONLY :: false

when ODIN_DEBUG || bench.BENCHMARKS_ENABLED {
	TERRAIN_GENERATION_BENCHMARK_CAVE_SLICE_TARGET_ALL :: 0
	TERRAIN_GENERATION_BENCHMARK_CAVE_SLICE_TARGET_FUNGAL :: 1
	TERRAIN_GENERATION_BENCHMARK_CAVE_SLICE_TARGET_FUNGAL_ROUTE :: 2
	TERRAIN_GENERATION_BENCHMARK_CAVE_SLICE_TARGET_FUNGAL_PORTAL :: 3
	TERRAIN_GENERATION_BENCHMARK_CAVE_SLICE_TARGET_FUNGAL_CLUSTER :: 4
	TERRAIN_GENERATION_BENCHMARK_CAVE_SLICE_TARGET_SEAMS :: 5
	TERRAIN_GENERATION_BENCHMARK_CAVE_SLICE_TARGET_CRYSTAL :: 6
	TERRAIN_GENERATION_BENCHMARK_CAVE_SLICE_TARGET_CRYSTAL_PORTAL :: 7
	TERRAIN_GENERATION_BENCHMARK_CAVE_SLICE_TARGET_CRYSTAL_CLUSTER :: 8
	TERRAIN_GENERATION_BENCHMARK_CAVE_SLICE_TARGET_AQUIFER :: 9
	TERRAIN_GENERATION_BENCHMARK_CAVE_SLICE_TARGET_AQUIFER_PORTAL :: 10
	TERRAIN_GENERATION_BENCHMARK_CAVE_SLICE_TARGET_AQUIFER_CLUSTER :: 11
	TERRAIN_GENERATION_BENCHMARK_CAVE_SLICE_TARGET_AQUIFER_WATER :: 12
	TERRAIN_GENERATION_BENCHMARK_CAVE_SLICE_TARGET_SURFACE :: 13
	TERRAIN_GENERATION_BENCHMARK_CAVE_SLICE_TARGET_PROFILE :: 14
	TERRAIN_GENERATION_BENCHMARK_CAVE_SLICE_TARGET_CAVE_FIELD_POCKET :: 15
	TERRAIN_GENERATION_BENCHMARK_CAVE_SLICE_TARGET_CAVE_FIELD_CRYSTAL_POCKET :: 16
	TERRAIN_GENERATION_BENCHMARK_CAVE_SLICE_TARGET_CAVE_FIELD_AQUIFER_POCKET :: 17
	TERRAIN_GENERATION_BENCHMARK_CAVE_SLICE_TARGET_CHAMBERLET_CHAIN :: 18
	TERRAIN_GENERATION_BENCHMARK_CAVE_SLICE_TARGET_CHAMBERLET_GALLERY :: 19
	TERRAIN_GENERATION_BENCHMARK_CAVE_SLICE_TARGET_MACRO_CLUSTERS :: 20
	TERRAIN_GENERATION_BENCHMARK_CAVE_SLICE_TARGET_SEAM_VIEW :: 21
	TERRAIN_GENERATION_BENCHMARK_CAVE_SLICE_TARGET_PROFILE_VIEW :: 22
	TERRAIN_GENERATION_BENCHMARK_CAVE_SLICE_TARGET_MAX ::
		TERRAIN_GENERATION_BENCHMARK_CAVE_SLICE_TARGET_PROFILE_VIEW
	TERRAIN_GENERATION_BENCHMARK_COORD_COUNT :: 8
	TERRAIN_GENERATION_BENCHMARK_BIOME_OWNER_SCAN_RADIUS_XZ :: 4
	TERRAIN_GENERATION_BENCHMARK_CAVE_FIELD_PATH_NEIGHBOR_RADIUS :: 1
	TERRAIN_GENERATION_BENCHMARK_CAVE_FIELD_POCKET_NEIGHBOR_RADIUS :: 2
	TERRAIN_GENERATION_BENCHMARK_SURFACE_CAVE_OWNER_SCAN_RADIUS_XZ :: 8
	TERRAIN_GENERATION_BENCHMARK_SURFACE_MORPHOLOGY_OWNER_SCAN_RADIUS_XZ :: 16
	TERRAIN_GENERATION_BENCHMARK_LEGACY_SURFACE_ANCHOR_EMIT_ROLL_MAX :: f32(0.42)
	TERRAIN_GENERATION_BENCHMARK_LEGACY_SURFACE_CAVE_MOUTH_ROLL_MAX :: f32(0.62)
	TERRAIN_GENERATION_BENCHMARK_BIOME_OWNER_SCAN_Y_MIN :: -2
	TERRAIN_GENERATION_BENCHMARK_BIOME_OWNER_SCAN_Y_MAX :: 0
	TERRAIN_GENERATION_BENCHMARK_TINY_CAVE_COMPONENT_NODE_MAX :: u32(3)
	TERRAIN_GENERATION_BENCHMARK_SURFACE_CAVE_SCAN_SEED_COUNT :: u32(4)
	TERRAIN_GENERATION_BENCHMARK_CAVE_SLICE_WIDTH :: 128
	TERRAIN_GENERATION_BENCHMARK_CAVE_SLICE_HEIGHT :: 96
	TERRAIN_GENERATION_BENCHMARK_CAVE_SLICE_STEP_BLOCKS :: i32(2)
	TERRAIN_GENERATION_BENCHMARK_CAVE_SLICE_CHUNK_CACHE_CAPACITY :: 16
	TERRAIN_GENERATION_BENCHMARK_SURFACE_CAPTURE_WIDTH :: 192
	TERRAIN_GENERATION_BENCHMARK_SURFACE_CAPTURE_HEIGHT :: 128
	TERRAIN_GENERATION_BENCHMARK_SURFACE_CAPTURE_STEP_BLOCKS :: i32(4)
	TERRAIN_GENERATION_BENCHMARK_SURFACE_SHAPE_STEP_BLOCKS :: i32(4)
	TERRAIN_GENERATION_BENCHMARK_SURFACE_CAPTURE_SCAN_Y_MIN :: i32(-96)
	TERRAIN_GENERATION_BENCHMARK_SURFACE_CAPTURE_SCAN_Y_MAX :: i32(160)
	TERRAIN_GENERATION_BENCHMARK_SURFACE_CAPTURE_HEADROOM_BLOCKS :: i32(32)
	TERRAIN_GENERATION_BENCHMARK_CAVE_VIEW_WIDTH :: 128
	TERRAIN_GENERATION_BENCHMARK_CAVE_VIEW_HEIGHT :: 72
	TERRAIN_GENERATION_BENCHMARK_CAVE_VIEW_MAX_DISTANCE_BLOCKS :: f32(160)
	TERRAIN_GENERATION_BENCHMARK_CAVE_VIEW_STEP_BLOCKS :: f32(1.5)
	TERRAIN_GENERATION_BENCHMARK_CAVE_VIEW_MAX_STEPS :: i32(107)
	TERRAIN_GENERATION_BENCHMARK_CAVE_VIEW_FOV_DEGREES :: f32(78)
	chunk_mesher_benchmarks_debug_contracts_run :: proc(transient_arena: ^mem.Arena) {
		log.assert(transient_arena != nil, "benchmark transient arena must not be nil")
		_ = world_async.ChunkVoxelView{}
		_ = time.Duration(0)
		_ = biomes.GenerationRegionCoord{}
		_ = math.abs(f32(0))
	}

	when bench.BENCHMARKS_ENABLED {

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
			warmup_scratch := terrain_binary_greedy_scratch_alloc(transient_arena)
			_ = chunk_mesher_benchmark_count_once(case_data.view, mesher, warmup_scratch)
			mem.end_arena_temp_memory(warmup_temp)

			face_count: u32
			start := time.tick_now()
			for _ in 0 ..< iterations {
				temp := mem.begin_arena_temp_memory(transient_arena)
				scratch := terrain_binary_greedy_scratch_alloc(transient_arena)
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
			warmup_scratch := terrain_binary_greedy_scratch_alloc(transient_arena)
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
				scratch := terrain_binary_greedy_scratch_alloc(transient_arena)
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
			warmup_scratch := terrain_binary_greedy_scratch_alloc(transient_arena)
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
				scratch := terrain_binary_greedy_scratch_alloc(transient_arena)
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

		WorldMeshBenchmarkPhase :: enum {
			Count,
			Build,
			Subchunk_Build,
		}

		WorldMeshBenchmarkFixture :: struct {
			fixture_name:   string,
			phase:          WorldMeshBenchmarkPhase,
			view:           world_async.ChunkVoxelView,
			mesher:         world_async.ChunkMeshing,
			subchunk_index: u32,
		}

		WorldMeshBenchmarkResult :: struct {
			face_count:   u64,
			output_bytes: u64,
			checksum:     u64,
		}

		world_mesh_benchmark_metrics := [?]bench.BenchmarkMetricDescriptor {
			{
				name = "faces",
				kind = .U64,
				offset = offset_of(WorldMeshBenchmarkResult, face_count),
				reduce = .Max,
				unit = "faces",
				description = "Generated terrain face count",
			},
			{
				name = "output_bytes",
				kind = .U64,
				offset = offset_of(WorldMeshBenchmarkResult, output_bytes),
				reduce = .Max,
				unit = "bytes",
				description = "Generated mesh output bytes",
			},
			{
				name = "checksum",
				kind = .U64,
				offset = offset_of(WorldMeshBenchmarkResult, checksum),
				reduce = .Sum,
				description = "Per-iteration mesh checksum",
			},
		}

		world_mesh_benchmark_phase_name :: proc(phase: WorldMeshBenchmarkPhase) -> string {
			switch phase {
			case .Count:
				return "count"
			case .Build:
				return "build"
			case .Subchunk_Build:
				return "subchunk_build"
			}
			return "unknown"
		}

		world_mesh_benchmark_fixture_write :: proc(
			ctx: ^bench.BenchmarkContext,
			data: rawptr,
			writer: ^bench.BenchmarkMetadataWriter,
		) -> bench.BenchmarkStatus {
			fixture := (^WorldMeshBenchmarkFixture)(data)
			bench.metadata_string(writer, "fixture_name", fixture.fixture_name)
			bench.metadata_string(writer, "phase", world_mesh_benchmark_phase_name(fixture.phase))
			bench.metadata_string(
				writer,
				"mesher",
				chunk_mesher_benchmark_mesher_name(fixture.mesher),
			)
			bench.metadata_u64(writer, "chunk_blocks", u64(CHUNK_BLOCK_COUNT), "blocks")
			if fixture.phase == .Subchunk_Build {
				bench.metadata_u64(writer, "subchunk_index", u64(fixture.subchunk_index))
			}
			_ = ctx
			return bench.status_pass()
		}

		world_mesh_benchmark_run :: proc(
			ctx: ^bench.BenchmarkContext,
			data: rawptr,
			result: rawptr,
		) -> bench.BenchmarkStatus {
			fixture := (^WorldMeshBenchmarkFixture)(data)
			out := (^WorldMeshBenchmarkResult)(result)
			temp := mem.begin_arena_temp_memory(ctx.temp_arena)
			defer mem.end_arena_temp_memory(temp)
			allocator := mem.arena_allocator(ctx.temp_arena)
			scratch := terrain_binary_greedy_scratch_alloc(ctx.temp_arena)

			#partial switch fixture.phase {
			case .Count:
				face_count := chunk_mesher_benchmark_count_once(
					fixture.view,
					fixture.mesher,
					scratch,
				)
				out.face_count = u64(face_count)
				out.output_bytes = 0
			case .Build:
				mesh_output := chunk_mesher_benchmark_build_once(
					fixture.view,
					fixture.mesher,
					allocator,
					scratch,
				)
				out.face_count = u64(mesh_output.face_count)
				out.output_bytes =
					u64(len(mesh_output.vertices) * size_of(world_async.TerrainPackedVertex)) +
					u64(len(mesh_output.indices) * size_of(u32))
			case .Subchunk_Build:
				min_bound, max_bound := chunk_subchunk_bounds_from_index(fixture.subchunk_index)
				mesh_output := chunk_voxel_view_build_binary_greedy_mesh_in_bounds(
					fixture.view,
					min_bound,
					max_bound,
					.Treat_Out_Of_Chunk_As_Empty,
					allocator,
					scratch,
				)
				out.face_count = u64(mesh_output.face_count)
				out.output_bytes =
					u64(len(mesh_output.vertices) * size_of(world_async.TerrainPackedVertex)) +
					u64(len(mesh_output.indices) * size_of(u32))
			}

			out.checksum +=
				out.face_count * 131 + out.output_bytes * 17 + u64(ctx.iteration_index + 1)
			return bench.status_pass()
		}

		world_mesh_benchmark_register_case :: proc(
			registry: ^bench.BenchmarkRegistry,
			name: string,
			fixture: WorldMeshBenchmarkFixture,
		) {
			fixture_copy := fixture
			bench.register(
				registry,
				name,
				world_mesh_benchmark_run,
				rawptr(&fixture_copy),
				nil,
				{
					iterations = 1_000,
					warmup_iterations = 10,
					workers = 1,
					result_size = size_of(WorldMeshBenchmarkResult),
					result_align = align_of(WorldMeshBenchmarkResult),
					data_size = size_of(WorldMeshBenchmarkFixture),
					data_align = align_of(WorldMeshBenchmarkFixture),
					metrics = world_mesh_benchmark_metrics[:],
					flags = {.Parallel_Safe},
					warmup_mode = .Serial,
					write_fixture = world_mesh_benchmark_fixture_write,
					category = "world.mesh",
					version = WORLD_MESH_BENCHMARK_VERSION,
				},
			)
		}

		world_mesh_benchmarks_register :: proc(
			registry: ^bench.BenchmarkRegistry,
			allocator: mem.Allocator,
		) {
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

			world_mesh_benchmark_register_case(
				registry,
				"world.mesh.heightfield.count",
				{
					fixture_name = "heightfield",
					phase = .Count,
					view = heightfield,
					mesher = .Greedy_Binary,
				},
			)
			world_mesh_benchmark_register_case(
				registry,
				"world.mesh.heightfield.build",
				{
					fixture_name = "heightfield",
					phase = .Build,
					view = heightfield,
					mesher = .Greedy_Binary,
				},
			)
			world_mesh_benchmark_register_case(
				registry,
				"world.mesh.solid_rect.build",
				{
					fixture_name = "solid_rect",
					phase = .Build,
					view = rect,
					mesher = .Greedy_Binary,
				},
			)
			world_mesh_benchmark_register_case(
				registry,
				"world.mesh.full_chunk.build",
				{
					fixture_name = "full_chunk",
					phase = .Build,
					view = full,
					mesher = .Greedy_Binary,
				},
			)
			world_mesh_benchmark_register_case(
				registry,
				"world.mesh.checkerboard.count",
				{
					fixture_name = "checkerboard",
					phase = .Count,
					view = checkerboard,
					mesher = .Greedy_Binary,
				},
			)
			world_mesh_benchmark_register_case(
				registry,
				"world.mesh.heightfield_subchunk.build",
				{
					fixture_name = "heightfield_subchunk",
					phase = .Subchunk_Build,
					view = heightfield,
					mesher = .Greedy_Binary,
					subchunk_index = chunk_subchunk_index_from_coord(1, 1, 1),
				},
			)
			world_mesh_benchmark_register_case(
				registry,
				"world.mesh.heightfield_surface_subchunk.build",
				{
					fixture_name = "heightfield_surface_subchunk",
					phase = .Subchunk_Build,
					view = heightfield,
					mesher = .Greedy_Binary,
					subchunk_index = chunk_subchunk_index_from_coord(1, 0, 1),
				},
			)
		}

	}

	when bench.BENCHMARKS_ENABLED {

		TerrainGenerationBenchmarkCoords :: [TERRAIN_GENERATION_BENCHMARK_COORD_COUNT]world_async.ChunkCoord
		TerrainGenerationBenchmarkMaterialStats :: struct {
			solid_count:             u64,
			empty_count:             u64,
			water_count:             u64,
			material_counts:         [TERRAIN_MATERIAL_PALETTE_COUNT]u64,
			hydrology_debug_blocks:  u64,
			cave_debug_blocks:       u64,
			decoration_debug_blocks: u64,
		}
		TerrainGenerationBenchmarkSurfaceMorphologyStats :: struct {
			chunk_count:              u32,
			active_column_count:      u64,
			sample_count:             u64,
			base_solid_count:         u64,
			morphology_solid_count:   u64,
			added_solid_count:        u64,
			removed_solid_count:      u64,
			unsupported_solid_count:  u64,
			feature_column_count:     u64,
			max_added_height_blocks:  f32,
			max_removed_depth_blocks: f32,
		}
		TerrainGenerationBenchmarkCaveSlicePixels :: [TERRAIN_GENERATION_BENCHMARK_CAVE_SLICE_WIDTH *
		TERRAIN_GENERATION_BENCHMARK_CAVE_SLICE_HEIGHT]u8
		TerrainGenerationBenchmarkSurfaceCapturePixels :: [TERRAIN_GENERATION_BENCHMARK_SURFACE_CAPTURE_WIDTH *
		TERRAIN_GENERATION_BENCHMARK_SURFACE_CAPTURE_HEIGHT]u8
		TerrainGenerationBenchmarkCaveViewPixels :: [TERRAIN_GENERATION_BENCHMARK_CAVE_VIEW_WIDTH *
		TERRAIN_GENERATION_BENCHMARK_CAVE_VIEW_HEIGHT]u8

		TerrainGenerationBenchmarkArtifactContext :: struct {
			result:         ^bench.BenchmarkCaseResult,
			artifact_dir:   string,
			allocator:      mem.Allocator,
			artifact_count: u32,
			ok:             bool,
			error:          string,
		}

		TerrainGenerationBenchmarkDiagnosticTimingContext :: struct {
			text_artifact_write:   time.Duration,
			text_artifact_bytes:   u64,
			surface_center_select: time.Duration,
			surface_peak_search:   time.Duration,
			surface_emit:          time.Duration,
		}

		@(thread_local)
		terrain_generation_benchmark_artifact_context: ^TerrainGenerationBenchmarkArtifactContext

		@(thread_local)
		terrain_generation_benchmark_diagnostic_timing_context: ^TerrainGenerationBenchmarkDiagnosticTimingContext

		@(thread_local)
		terrain_generation_benchmark_cave_slice_selected_target: int

		@(thread_local)
		terrain_generation_benchmark_surface_capture_step_override: i32

		TerrainGenerationBenchmarkCaveSliceMode :: enum u32 {
			Horizontal_XZ,
			Vertical_XY,
			Route_Longitudinal,
			Route_Cross_Section,
			Route_Plan,
			Route_Oblique,
			Route_Endpoint_Plan,
			Mouth_Longitudinal,
			Mouth_Plan,
		}
		TerrainGenerationBenchmarkSurfaceCaptureMode :: enum u32 {
			Vertical_XY,
			Plan_Surface,
			Morphology_Delta_XY,
			Decorated_Vertical_XY,
			Decorated_Plan_Surface,
		}

		terrain_generation_benchmark_artifact_write :: proc(
			label: string,
			kind: string,
			content: string,
		) {
			ctx := terrain_generation_benchmark_artifact_context
			if ctx == nil || !ctx.ok {
				return
			}
			if ctx.result == nil {
				ctx.ok = false
				ctx.error = "benchmark artifact result is not available"
				return
			}

			stored_label := fmt.aprintf("%s", label, allocator = ctx.allocator)
			path := fmt.aprintf(
				"%s/%s_%s.txt",
				ctx.artifact_dir,
				kind,
				label,
				allocator = ctx.allocator,
			)
			timing_context := terrain_generation_benchmark_diagnostic_timing_context
			write_start: time.Tick
			if timing_context != nil {
				timing_context.text_artifact_bytes += u64(len(content))
				write_start = time.tick_now()
			}
			err := os.write_entire_file(path, content)
			if timing_context != nil {
				timing_context.text_artifact_write += time.tick_since(write_start)
			}
			if err != nil {
				ctx.ok = false
				ctx.error = fmt.aprintf(
					"failed to write benchmark artifact %s: %v",
					path,
					err,
					allocator = ctx.allocator,
				)
				return
			}
			bench.artifact_add(ctx.result, stored_label, kind, path, "text/plain")
			ctx.artifact_count += 1
		}

		terrain_generation_benchmark_cave_slice_artifact_write :: proc(
			label: string,
			mode: TerrainGenerationBenchmarkCaveSliceMode,
			center: world_async.BlockCoord,
			pixels: ^TerrainGenerationBenchmarkCaveSlicePixels,
			cache_count, open_count, water_count, solid_count: u32,
			allocator: mem.Allocator,
		) {
			if terrain_generation_benchmark_artifact_context == nil ||
			   !terrain_generation_benchmark_artifact_context.ok {
				return
			}
			builder, alloc_err := strings.builder_make(allocator = allocator)
			if alloc_err != nil {
				terrain_generation_benchmark_artifact_context.ok = false
				terrain_generation_benchmark_artifact_context.error = "failed to allocate cave slice artifact builder"
				return
			}
			defer strings.builder_destroy(&builder)

			fmt.sbprintf(
				&builder,
				"label=%s mode=%v center=(%d,%d,%d) width=%d height=%d step=%d chunks=%d open=%d water=%d solid=%d\n",
				label,
				mode,
				center.x,
				center.y,
				center.z,
				TERRAIN_GENERATION_BENCHMARK_CAVE_SLICE_WIDTH,
				TERRAIN_GENERATION_BENCHMARK_CAVE_SLICE_HEIGHT,
				TERRAIN_GENERATION_BENCHMARK_CAVE_SLICE_STEP_BLOCKS,
				cache_count,
				open_count,
				water_count,
				solid_count,
			)
			for row := i32(0);
			    row < i32(TERRAIN_GENERATION_BENCHMARK_CAVE_SLICE_HEIGHT);
			    row += 1 {
				row_bytes: [TERRAIN_GENERATION_BENCHMARK_CAVE_SLICE_WIDTH]u8
				for column := i32(0);
				    column < i32(TERRAIN_GENERATION_BENCHMARK_CAVE_SLICE_WIDTH);
				    column += 1 {
					pixel_index :=
						row * i32(TERRAIN_GENERATION_BENCHMARK_CAVE_SLICE_WIDTH) + column
					row_bytes[column] = pixels[pixel_index]
				}
				fmt.sbprintf(&builder, "%s\n", string(row_bytes[:]))
			}
			artifact_label := fmt.aprintf("%s_%v", label, mode, allocator = allocator)
			terrain_generation_benchmark_artifact_write(
				artifact_label,
				"terrain_cave_slice",
				strings.to_string(builder),
			)
		}

		terrain_generation_benchmark_cave_view_artifact_write :: proc(
			label: string,
			route_t: f32,
			camera_x, camera_y, camera_z: f32,
			forward_x, forward_y, forward_z: f32,
			pixels, depths: ^TerrainGenerationBenchmarkCaveViewPixels,
			cache_count, hit_count, miss_count, water_hit_count: u32,
			avg_distance: f32,
			allocator: mem.Allocator,
		) {
			if terrain_generation_benchmark_artifact_context == nil ||
			   !terrain_generation_benchmark_artifact_context.ok {
				return
			}
			builder, alloc_err := strings.builder_make(allocator = allocator)
			if alloc_err != nil {
				terrain_generation_benchmark_artifact_context.ok = false
				terrain_generation_benchmark_artifact_context.error = "failed to allocate cave view artifact builder"
				return
			}
			defer strings.builder_destroy(&builder)

			fmt.sbprintf(
				&builder,
				"label=%s route_t=%.3f camera=(%.2f,%.2f,%.2f) forward=(%.3f,%.3f,%.3f) width=%d height=%d fov=%.1f max_distance=%.1f chunks=%d hits=%d misses=%d water_hits=%d avg_hit_distance=%.2f\n",
				label,
				route_t,
				camera_x,
				camera_y,
				camera_z,
				forward_x,
				forward_y,
				forward_z,
				TERRAIN_GENERATION_BENCHMARK_CAVE_VIEW_WIDTH,
				TERRAIN_GENERATION_BENCHMARK_CAVE_VIEW_HEIGHT,
				TERRAIN_GENERATION_BENCHMARK_CAVE_VIEW_FOV_DEGREES,
				TERRAIN_GENERATION_BENCHMARK_CAVE_VIEW_MAX_DISTANCE_BLOCKS,
				cache_count,
				hit_count,
				miss_count,
				water_hit_count,
				avg_distance,
			)
			for row := i32(0); row < i32(TERRAIN_GENERATION_BENCHMARK_CAVE_VIEW_HEIGHT); row += 1 {
				row_bytes: [TERRAIN_GENERATION_BENCHMARK_CAVE_VIEW_WIDTH]u8
				depth_bytes: [TERRAIN_GENERATION_BENCHMARK_CAVE_VIEW_WIDTH]u8
				for column := i32(0);
				    column < i32(TERRAIN_GENERATION_BENCHMARK_CAVE_VIEW_WIDTH);
				    column += 1 {
					pixel_index := row * i32(TERRAIN_GENERATION_BENCHMARK_CAVE_VIEW_WIDTH) + column
					row_bytes[column] = pixels[pixel_index]
					depth_bytes[column] = depths[pixel_index]
				}
				fmt.sbprintf(
					&builder,
					"%s depth=%s\n",
					string(row_bytes[:]),
					string(depth_bytes[:]),
				)
			}
			terrain_generation_benchmark_artifact_write(
				label,
				"terrain_cave_view",
				strings.to_string(builder),
			)
		}

		TerrainGenerationBenchmarkCaveSliceChunkCacheEntry :: struct {
			coord: world_async.ChunkCoord,
			view:  world_async.ChunkVoxelView,
			valid: bool,
		}

		TerrainGenerationBenchmarkCaveSliceChunkCache :: struct {
			entries:          [TERRAIN_GENERATION_BENCHMARK_CAVE_SLICE_CHUNK_CACHE_CAPACITY]TerrainGenerationBenchmarkCaveSliceChunkCacheEntry,
			count:            u32,
			next_reuse_index: u32,
		}

		TerrainGenerationBenchmarkSurfaceWaterStats :: struct {
			column_count:                 u32,
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
			min_surface_height_blocks:    f32,
			max_surface_height_blocks:    f32,
			top_soft_zone_columns:        u32,
			bottom_soft_zone_columns:     u32,
		}

		TerrainGenerationBenchmarkSurfaceShapeStats :: struct {
			column_count:              u32,
			slope_sample_count:        u32,
			high_slope_columns:        u32,
			peak_columns:              u32,
			valley_columns:            u32,
			min_surface_height_blocks: f32,
			max_surface_height_blocks: f32,
			height_sum_blocks:         f32,
			abs_slope_sum:             f32,
			max_abs_slope:             f32,
		}

		TerrainGenerationBenchmarkSurfaceCaveAnchors :: struct {
			mouth:              biomes.CaveAnchor,
			sinkhole:           biomes.CaveAnchor,
			mouth_small:        biomes.CaveAnchor,
			mouth_medium:       biomes.CaveAnchor,
			mouth_large:        biomes.CaveAnchor,
			mouth_node:         biomes.CaveNetworkNode,
			sinkhole_node:      biomes.CaveNetworkNode,
			mouth_small_node:   biomes.CaveNetworkNode,
			mouth_medium_node:  biomes.CaveNetworkNode,
			mouth_large_node:   biomes.CaveNetworkNode,
			mouth_found:        bool,
			sinkhole_found:     bool,
			mouth_small_found:  bool,
			mouth_medium_found: bool,
			mouth_large_found:  bool,
		}

		TerrainGenerationBenchmarkSurfaceCaveStats :: struct {
			selected_anchor_count:                u32,
			mouth_count:                          u32,
			sinkhole_count:                       u32,
			open_anchor_count:                    u32,
			sealed_anchor_count:                  u32,
			open_blocks:                          u32,
			mouth_open_blocks:                    u32,
			sinkhole_open_blocks:                 u32,
			mouth_aperture_open_blocks:           u32,
			mouth_throat_open_blocks:             u32,
			mouth_inner_open_blocks:              u32,
			mouth_outer_carve_open_blocks:        u32,
			mouth_exterior_apron_open_blocks:     u32,
			mouth_lower_center_open_blocks:       u32,
			mouth_lower_side_band_open_blocks:    u32,
			mouth_side_pocket_open_blocks:        u32,
			sinkhole_upper_center_open_blocks:    u32,
			sinkhole_upper_ledge_open_blocks:     u32,
			sinkhole_upper_outer_open_blocks:     u32,
			sinkhole_upper_side_band_open_blocks: u32,
			sinkhole_upper_end_band_open_blocks:  u32,
			water_blocks:                         u32,
			solid_blocks:                         u32,
			near_surface_open:                    u32,
			sub_surface_open:                     u32,
			max_open_depth:                       i32,
			min_open_blocks:                      u32,
			mouth_link_horizontal_blocks:         f32,
			mouth_link_vertical_blocks:           f32,
			mouth_link_drop_per_run:              f32,
			mouth_bend_horizontal_blocks:         f32,
			mouth_bend_vertical_blocks:           f32,
			mouth_bend_drop_per_run:              f32,
			mouth_handoff_horizontal_blocks:      f32,
			mouth_handoff_vertical_blocks:        f32,
			mouth_handoff_drop_per_run:           f32,
		}

		TerrainGenerationBenchmarkSurfaceCaveScanStats :: struct {
			owner_count:                                  u32,
			legacy_emit_count:                            u32,
			current_emit_count:                           u32,
			additional_emit_count:                        u32,
			legacy_mouth_count:                           u32,
			legacy_sinkhole_count:                        u32,
			current_mouth_count:                          u32,
			current_sinkhole_count:                       u32,
			current_mouth_small_count:                    u32,
			current_mouth_medium_count:                   u32,
			current_mouth_large_count:                    u32,
			current_mouth_vestibule_count:                u32,
			current_mouth_shallow_transition_count:       u32,
			current_mouth_steep_transition_count:         u32,
			current_mouth_raw_vertical_count:             u32,
			current_mouth_sloped_tube_count:              u32,
			current_mouth_curved_ramp_count:              u32,
			current_mouth_spiral_ramp_count:              u32,
			current_anchor_component_tiny_count:          u32,
			current_mouth_component_tiny_count:           u32,
			current_sinkhole_component_tiny_count:        u32,
			current_anchor_component_missing_count:       u32,
			current_anchor_component_external_link_count: u32,
			current_anchor_component_max_nodes:           u32,
			current_mouth_radius_total:                   f32,
			current_mouth_radius_max:                     f32,
			guaranteed_count:                             u32,
			vertical_count:                               u32,
		}

		TerrainGenerationBenchmarkCavePhysicalStats :: struct {
			chunk_count:                   u32,
			open_blocks:                   u32,
			water_blocks:                  u32,
			solid_blocks:                  u32,
			open_core_6_blocks:            u32,
			open_core_27_blocks:           u32,
			exposed_solid_blocks:          u32,
			exposed_grass_blocks:          u32,
			exposed_dirt_blocks:           u32,
			exposed_stone_blocks:          u32,
			exposed_wet_blocks:            u32,
			exposed_ash_blocks:            u32,
			exposed_aquifer_wall_blocks:   u32,
			exposed_crystal_blocks:        u32,
			exposed_fungal_floor_blocks:   u32,
			exposed_fungal_ceiling_blocks: u32,
			cave_biome_exposed_blocks:     u32,
			open_neighbor_low_blocks:      u32,
			open_neighbor_mid_blocks:      u32,
			open_neighbor_high_blocks:     u32,
			chamber_span_blocks:           u32,
			narrow_span_blocks:            u32,
			axis_span_x_total:             u32,
			axis_span_y_total:             u32,
			axis_span_z_total:             u32,
			max_open_core_27_per_chunk:    u32,
			min_open_core_27_per_chunk:    u32,
			max_exposed_biome_per_chunk:   u32,
			min_exposed_biome_per_chunk:   u32,
		}

		TerrainGenerationBenchmarkCaveFieldStats :: struct {
			chunk_count:                            u32,
			candidate_count:                        u32,
			path_candidate_count:                   u32,
			chamber_candidate_count:                u32,
			stamp_count:                            u32,
			path_stamp_count:                       u32,
			route_pocket_stamp_count:               u32,
			chamber_stamp_count:                    u32,
			network_connected_candidate_count:      u32,
			network_bridge_candidate_count:         u32,
			network_culled_candidate_count:         u32,
			network_bridge_stamp_count:             u32,
			route_pocket_candidate_count:           u32,
			route_promoted_path_candidate_count:    u32,
			route_promoted_path_stamp_count:        u32,
			route_follow_path_candidate_count:      u32,
			route_follow_path_stamp_count:          u32,
			route_follow_path_vertical_stamp_count: u32,
			fungal_stamp_count:                     u32,
			crystal_stamp_count:                    u32,
			aquifer_stamp_count:                    u32,
		}

		TerrainGenerationBenchmarkCaveSelection :: struct {
			node:                 biomes.CaveNetworkNode,
			chunk:                world_async.ChunkCoord,
			vertical_support:     f32,
			found_matching_biome: bool,
			streamed_underground: bool,
		}

		TerrainGenerationBenchmarkCaveFieldPathSelection :: struct {
			chunk:                 world_async.ChunkCoord,
			found:                 bool,
			path_candidate_count:  u32,
			path_stamp_count:      u32,
			route_follow_count:    u32,
			vertical_follow_count: u32,
		}

		TerrainGenerationBenchmarkCaveFieldPocketSelection :: struct {
			chunk:                  world_async.ChunkCoord,
			found:                  bool,
			pocket_candidate_count: u32,
			pocket_stamp_count:     u32,
			center_x:               f32,
			center_y:               f32,
			center_z:               f32,
			nearest_x:              f32,
			nearest_y:              f32,
			nearest_z:              f32,
			route_dir_x:            f32,
			route_dir_z:            f32,
			radius:                 f32,
			route_radius:           f32,
			biome_id:               biomes.BiomeID,
			score:                  i64,
		}

		TerrainGenerationBenchmarkSurfaceMorphologyFeatureSelection :: struct {
			feature:         biomes.SurfaceMorphologyFeature,
			center:          world_async.BlockCoord,
			chunk:           world_async.ChunkCoord,
			found:           bool,
			candidate_count: u32,
			score:           f32,
		}

		TerrainGenerationBenchmarkSurfaceFortressSelection :: struct {
			feature:         biomes.DecorationFeature,
			center:          world_async.BlockCoord,
			chunk:           world_async.ChunkCoord,
			found:           bool,
			candidate_count: u32,
			score:           f32,
		}

		TerrainGenerationBenchmarkCaveComponentMeasure :: struct {
			found:               bool,
			node_count:          u32,
			external_link_count: u32,
		}

		TerrainGenerationBenchmarkRegionStats :: struct {
			node_count:                      u32,
			edge_count:                      u32,
			anchor_count:                    u32,
			water_feature_node_count:        u32,
			water_feature_segment_count:     u32,
			water_feature_anchor_count:      u32,
			major_count:                     u32,
			water_linked_count:              u32,
			connector_count:                 u32,
			pocket_count:                    u32,
			resource_count:                  u32,
			sealed_count:                    u32,
			fungal_count:                    u32,
			crystal_count:                   u32,
			aquifer_count:                   u32,
			rooted_macro_count:              u32,
			mineral_macro_count:             u32,
			aquifer_macro_count:             u32,
			shallow_depth_count:             u32,
			mid_depth_count:                 u32,
			deep_depth_count:                u32,
			cave_mouth_count:                u32,
			sinkhole_count:                  u32,
			water_anchor_count:              u32,
			tunnel_edge_count:               u32,
			canyon_edge_count:               u32,
			worm_edge_count:                 u32,
			flooded_edge_count:              u32,
			fracture_edge_count:             u32,
			collapsed_edge_count:            u32,
			vertical_edge_count:             u32,
			node_edge_connected_count:       u32,
			node_anchor_connected_count:     u32,
			node_bridge_count:               u32,
			node_culled_count:               u32,
			profile_room_node_count:         u32,
			profile_room_nonmajor_count:     u32,
			component_count:                 u32,
			component_tiny_count:            u32,
			component_tiny_node_count:       u32,
			component_playable_tiny_count:   u32,
			component_sealed_tiny_count:     u32,
			component_external_link_count:   u32,
			component_anchored_tiny_count:   u32,
			component_mouth_tiny_count:      u32,
			component_sinkhole_tiny_count:   u32,
			component_required_tiny_count:   u32,
			component_large_room_tiny_count: u32,
			component_max_nodes:             u32,
		}

		terrain_generation_benchmark_cache_clear :: proc() {
			terrain_generation_region_cache_clear()
			terrain_generation_cave_overlay_cache_clear()
			terrain_generation_chunk_cache_clear()
			terrain_generation_column_cache_clear()
			terrain_water_separator_sample_cache_clear()
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
			return chunk_coord_from_block_coord(
				{
					x = terrain_generation_benchmark_floor_i32(node.x),
					y = terrain_generation_benchmark_floor_i32(node.y),
					z = terrain_generation_benchmark_floor_i32(node.z),
				},
			)
		}

		terrain_generation_benchmark_chunk_for_surface_water_node :: proc(
			node: biomes.WaterFeatureNode,
		) -> world_async.ChunkCoord {
			return chunk_coord_from_block_coord(
				{
					x = terrain_generation_benchmark_floor_i32(node.x),
					y = terrain_generation_benchmark_floor_i32(node.water_level_blocks),
					z = terrain_generation_benchmark_floor_i32(node.z),
				},
			)
		}

		terrain_generation_benchmark_chunk_for_cave_anchor :: proc(
			anchor: biomes.CaveAnchor,
		) -> world_async.ChunkCoord {
			return chunk_coord_from_block_coord(
				{
					x = terrain_generation_benchmark_floor_i32(anchor.x),
					y = terrain_generation_benchmark_floor_i32(anchor.y),
					z = terrain_generation_benchmark_floor_i32(anchor.z),
				},
			)
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

		terrain_generation_benchmark_surface_morphology_feature_selection :: proc(
			key: biomes.FeatureGridKey,
		) -> TerrainGenerationBenchmarkSurfaceMorphologyFeatureSelection {
			best := TerrainGenerationBenchmarkSurfaceMorphologyFeatureSelection{}
			for z := -TERRAIN_GENERATION_BENCHMARK_SURFACE_MORPHOLOGY_OWNER_SCAN_RADIUS_XZ;
			    z <= TERRAIN_GENERATION_BENCHMARK_SURFACE_MORPHOLOGY_OWNER_SCAN_RADIUS_XZ;
			    z += 1 {
				for x := -TERRAIN_GENERATION_BENCHMARK_SURFACE_MORPHOLOGY_OWNER_SCAN_RADIUS_XZ;
				    x <= TERRAIN_GENERATION_BENCHMARK_SURFACE_MORPHOLOGY_OWNER_SCAN_RADIUS_XZ;
				    x += 1 {
					owner := biomes.FeatureGridCoord2 {
						x = i32(x),
						z = i32(z),
					}
					feature, found := biomes.surface_morphology_feature_from_owner(key, owner)
					if !found {
						continue
					}

					best.candidate_count += 1
					score :=
						feature.biome_weight * f32(100) +
						feature.height_blocks +
						feature.radius_blocks * f32(0.18) +
						feature.arch_strength * f32(18)
					if !best.found || score > best.score {
						world_x := terrain_generation_benchmark_floor_i32(feature.x)
						world_z := terrain_generation_benchmark_floor_i32(feature.z)
						column := terrain_biome_column_sample(
							key,
							biomes.surface_biome_field_sample(key, world_x, world_z),
							world_x,
							world_z,
						)
						center := world_async.BlockCoord {
							x = world_x,
							y = column.surface_height,
							z = world_z,
						}
						best.feature = feature
						best.center = center
						best.chunk = chunk_coord_from_block_coord(center)
						best.found = true
						best.score = score
					}
				}
			}
			return best
		}

		terrain_generation_benchmark_surface_morphology_feature_coords_make :: proc(
			selection: TerrainGenerationBenchmarkSurfaceMorphologyFeatureSelection,
		) -> TerrainGenerationBenchmarkCoords {
			coords := TerrainGenerationBenchmarkCoords{}
			coord_count: u32
			base := selection.chunk
			offsets := [?]world_async.ChunkCoord {
				{0, 0, 0},
				{0, 1, 0},
				{0, -1, 0},
				{1, 0, 0},
				{-1, 0, 0},
				{0, 0, 1},
				{0, 0, -1},
				{1, 1, 0},
			}
			for offset in offsets {
				terrain_generation_benchmark_coord_append_unique(
					&coords,
					&coord_count,
					{base.x + offset.x, base.y + offset.y, base.z + offset.z},
				)
			}
			return coords
		}

		terrain_generation_benchmark_surface_fortress_selection :: proc(
			key: biomes.FeatureGridKey,
		) -> TerrainGenerationBenchmarkSurfaceFortressSelection {
			best := TerrainGenerationBenchmarkSurfaceFortressSelection{}
			for region_z := i32(-4); region_z <= 4; region_z += 1 {
				for region_x := i32(-4); region_x <= 4; region_x += 1 {
					region_coord := biomes.GenerationRegionCoord {
						x = region_x,
						y = 0,
						z = region_z,
					}
					region := terrain_generation_region_for_fill(key, region_coord)
					for i := u32(0); i < region.surface_decoration_feature_count; i += 1 {
						feature := region.surface_decoration_features[i]
						if feature.family_id != .Palisade_Fort {
							continue
						}
						best.candidate_count += 1
						world_x := terrain_generation_benchmark_floor_i32(feature.x)
						world_z := terrain_generation_benchmark_floor_i32(feature.z)
						column := terrain_biome_column_sample_direct(key, world_x, world_z)
						center := world_async.BlockCoord {
							x = world_x,
							y = column.surface_height,
							z = world_z,
						}
						biome_weight := f32(0)
						if feature.biome_id == .Old_Growth_Forest ||
						   feature.biome_id == .Wet_Lowland_Marsh ||
						   feature.biome_id == .Basalt_Spire_Highlands ||
						   feature.biome_id == .Corrupted_Ash_Forest {
							biome_weight = 32
						}
						score :=
							f32(feature.radius_blocks) * 2 +
							f32(feature.height_blocks) +
							biome_weight -
							math.abs(f32(center.x)) * 0.002 -
							math.abs(f32(center.z)) * 0.002
						if !best.found || score > best.score {
							best.feature = feature
							best.center = center
							best.chunk = chunk_coord_from_block_coord(center)
							best.found = true
							best.score = score
						}
					}
				}
			}
			return best
		}

		terrain_generation_benchmark_surface_fortress_coords_make :: proc(
			selection: TerrainGenerationBenchmarkSurfaceFortressSelection,
		) -> TerrainGenerationBenchmarkCoords {
			coords := TerrainGenerationBenchmarkCoords{}
			coord_count: u32
			base := selection.chunk
			offsets := [?]world_async.ChunkCoord {
				{0, 0, 0},
				{1, 0, 0},
				{-1, 0, 0},
				{0, 0, 1},
				{0, 0, -1},
				{1, 0, 1},
				{0, 1, 0},
				{1, 1, 0},
			}
			for offset in offsets {
				terrain_generation_benchmark_coord_append_unique(
					&coords,
					&coord_count,
					{base.x + offset.x, base.y + offset.y, base.z + offset.z},
				)
			}
			return coords
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
					owner := biomes.FeatureGridCoord2 {
						x = i32(x),
						z = i32(z),
					}
					node := biomes.water_feature_surface_node_from_owner(key, owner)
					if !biomes.water_feature_surface_node_should_emit(key, node) {
						continue
					}
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
			start_index, start_found := terrain_generation_benchmark_cave_node_index_by_id(
				region,
				node_id,
			)
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
						terrain_generation_benchmark_cave_node_index_by_id(region, neighbor_id)
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
						node.major_region ||
						node.kind == .Vertical_Shaft ||
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
							stats.current_mouth_radius_max = math.max(
								stats.current_mouth_radius_max,
								radius,
							)
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
							plan := terrain_density_cave_mouth_transition_plan(
								anchor,
								node,
								radius,
								link_radius,
							)
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
			total.current_anchor_component_tiny_count += stats.current_anchor_component_tiny_count
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

		terrain_generation_benchmark_surface_cave_scan_stats_log_multi :: proc(phase: string) {
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
						score := terrain_generation_benchmark_cave_selection_score(
							node,
							chunk,
							support,
						)
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
				streamed_underground = best_chunk.y < 0 &&
				best_chunk.y >= -i32(CHUNK_STREAMING_RADIUS_Y_DOWN),
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
						score :=
							terrain_generation_benchmark_cave_selection_score(
								node,
								chunk,
								support,
							) +
							400
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
				streamed_underground = best_chunk.y < 0 &&
				best_chunk.y >= -i32(CHUNK_STREAMING_RADIUS_Y_DOWN),
			}
		}

		terrain_generation_benchmark_cave_field_path_selection_score :: proc(
			selection: TerrainGenerationBenchmarkCaveFieldPathSelection,
			chunk: world_async.ChunkCoord,
		) -> i64 {
			score :=
				i64(selection.route_follow_count) * 1000 +
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
			region_coord := biomes.generation_region_coord_from_block(origin.x, origin.y, origin.z)
			region := terrain_generation_region_for_fill(key, region_coord)
			edge_route_bounds: [biomes.GENERATION_REGION_CAVE_NETWORK_EDGE_CAPACITY]TerrainCaveEdgeRouteBounds
			terrain_density_cave_edge_route_bounds_fill(&region, edge_route_bounds[:])
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
						path_candidate := terrain_density_cave_field_sample_prefers_path(
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
							edge_route_bounds[:],
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
							terrain_density_cave_field_path_direction(field_sample, network_sample)
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
						    offset_x <=
						    TERRAIN_GENERATION_BENCHMARK_CAVE_FIELD_PATH_NEIGHBOR_RADIUS;
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
							score := terrain_generation_benchmark_cave_field_path_selection_score(
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

		terrain_generation_benchmark_cave_field_pocket_selection_score :: proc(
			radius, open_strength: f32,
			network_sample: TerrainCaveFieldNetworkSample,
			chunk: world_async.ChunkCoord,
		) -> i64 {
			proximity := math.max(
				f32(0),
				network_sample.route_radius +
				TERRAIN_CAVE_FIELD_ROUTE_POCKET_DISTANCE_MARGIN_BLOCKS -
				network_sample.distance,
			)
			score :=
				i64(radius * 120) +
				i64(open_strength * 1400) +
				i64(proximity * 75) +
				i64(network_sample.route_radius * 55)
			score -= i64(math.abs(f32(chunk.x))) + i64(math.abs(f32(chunk.z)))
			score -= i64(math.abs(f32(chunk.y + 1))) * 3
			return score
		}

		terrain_generation_benchmark_cave_field_pocket_selection_for_chunk :: proc(
			key: biomes.FeatureGridKey,
			chunk: world_async.ChunkCoord,
			biome_filter: biomes.BiomeID,
			filter_active: bool,
		) -> TerrainGenerationBenchmarkCaveFieldPocketSelection {
			origin := chunk_origin_from_coord(chunk)
			region_coord := biomes.generation_region_coord_from_block(origin.x, origin.y, origin.z)
			region := terrain_generation_region_for_fill(key, region_coord)
			edge_route_bounds: [biomes.GENERATION_REGION_CAVE_NETWORK_EDGE_CAPACITY]TerrainCaveEdgeRouteBounds
			terrain_density_cave_edge_route_bounds_fill(&region, edge_route_bounds[:])
			selection := TerrainGenerationBenchmarkCaveFieldPocketSelection {
				chunk = chunk,
				score = i64(-9223372036854775807),
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

						path_candidate := terrain_density_cave_field_sample_prefers_path(
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
						biome_id := subterranean_sample.cells[0].biome_id
						if filter_active && biome_id != biome_filter {
							continue
						}
						if biome_id == .Fungal_Vaults {
							radius *= 1.25
						} else if biome_id == .Crystal_Geode_Network {
							radius *= 0.82
						} else if biome_id == .Buried_Aquifer_Caves {
							radius *= 1.05
						}
						network_sample := terrain_density_cave_field_network_sample(
							&region,
							f32(world_x) + 0.5,
							f32(world_y) + 0.5,
							f32(world_z) + 0.5,
							radius,
							path_candidate,
							edge_route_bounds[:],
						)
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
						if route_pocket_candidate {
							selection.pocket_candidate_count += 1
						}
						if chunk_stamp_count >= TERRAIN_CAVE_FIELD_STAMP_CAPACITY_PER_CHUNK {
							continue
						}
						if path_candidate {
							chunk_stamp_count += 1
							continue
						}
						if !route_pocket_candidate &&
						   chunk_stamp_count >=
							   TERRAIN_CAVE_FIELD_STAMP_CAPACITY_PER_CHUNK -
								   TERRAIN_CAVE_FIELD_PATH_STAMP_RESERVE_PER_CHUNK {
							continue
						}
						if !route_pocket_candidate {
							chunk_stamp_count += 1
							continue
						}

						selection.pocket_stamp_count += 1
						chunk_stamp_count += 1
						score := terrain_generation_benchmark_cave_field_pocket_selection_score(
							radius,
							open_strength,
							network_sample,
							chunk,
						)
						if !selection.found || score > selection.score {
							selection.found = true
							selection.center_x = f32(world_x) + 0.5
							selection.center_y = f32(world_y) + 0.5
							selection.center_z = f32(world_z) + 0.5
							selection.nearest_x = network_sample.nearest_x
							selection.nearest_y = network_sample.nearest_y
							selection.nearest_z = network_sample.nearest_z
							selection.route_dir_x = network_sample.route_dir_x
							selection.route_dir_z = network_sample.route_dir_z
							selection.radius = radius
							selection.route_radius = network_sample.route_radius
							selection.biome_id = biome_id
							selection.score = score
						}
					}
				}
			}
			return selection
		}

		terrain_generation_benchmark_cave_field_pocket_selection :: proc(
			key: biomes.FeatureGridKey,
			biome_filter: biomes.BiomeID = {},
			filter_active: bool = false,
		) -> TerrainGenerationBenchmarkCaveFieldPocketSelection {
			best := TerrainGenerationBenchmarkCaveFieldPocketSelection {
				score = i64(-9223372036854775807),
			}
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
					for offset_z := -TERRAIN_GENERATION_BENCHMARK_CAVE_FIELD_POCKET_NEIGHBOR_RADIUS;
					    offset_z <= TERRAIN_GENERATION_BENCHMARK_CAVE_FIELD_POCKET_NEIGHBOR_RADIUS;
					    offset_z += 1 {
						for offset_x := -TERRAIN_GENERATION_BENCHMARK_CAVE_FIELD_POCKET_NEIGHBOR_RADIUS;
						    offset_x <=
						    TERRAIN_GENERATION_BENCHMARK_CAVE_FIELD_POCKET_NEIGHBOR_RADIUS;
						    offset_x += 1 {
							chunk := world_async.ChunkCoord {
								x = base_chunk.x + i32(offset_x),
								y = chunk_y,
								z = base_chunk.z + i32(offset_z),
							}
							selection :=
								terrain_generation_benchmark_cave_field_pocket_selection_for_chunk(
									key,
									chunk,
									biome_filter,
									filter_active,
								)
							if !selection.found {
								continue
							}
							if !best.found || selection.score > best.score {
								best = selection
							}
						}
					}
				}
			}
			return best
		}

		terrain_generation_benchmark_cave_field_pocket_selection_log :: proc(
			selection: TerrainGenerationBenchmarkCaveFieldPocketSelection,
		) {
			log.infof(
				"TERRAIN_GENERATION_BENCH_CAVE_FIELD_POCKET_SELECTION found=%v chunk=(%d,%d,%d) center=(%.2f,%.2f,%.2f) nearest=(%.2f,%.2f,%.2f) radius=%.2f route_radius=%.2f biome=%v pocket_candidates=%d pocket_stamps=%d score=%d",
				selection.found,
				selection.chunk.x,
				selection.chunk.y,
				selection.chunk.z,
				selection.center_x,
				selection.center_y,
				selection.center_z,
				selection.nearest_x,
				selection.nearest_y,
				selection.nearest_z,
				selection.radius,
				selection.route_radius,
				selection.biome_id,
				selection.pocket_candidate_count,
				selection.pocket_stamp_count,
				selection.score,
			)
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

		terrain_generation_benchmark_surface_morphology_feature_selection_log :: proc(
			selection: TerrainGenerationBenchmarkSurfaceMorphologyFeatureSelection,
		) {
			feature := selection.feature
			log.infof(
				"TERRAIN_GENERATION_BENCH_SURFACE_MORPHOLOGY_FEATURE_SELECTION found=%v candidates=%d owner=(%d,%d) center=(%d,%d,%d) chunk=(%d,%d,%d) biome=%v weight=%.3f radius=%.2f influence=%.2f height=%.2f cut_depth=%.2f spires=%d arch=%.3f shelf=%.3f score=%.3f",
				selection.found,
				selection.candidate_count,
				feature.owner.x,
				feature.owner.z,
				selection.center.x,
				selection.center.y,
				selection.center.z,
				selection.chunk.x,
				selection.chunk.y,
				selection.chunk.z,
				feature.biome_id,
				feature.biome_weight,
				feature.radius_blocks,
				feature.influence_radius_blocks,
				feature.height_blocks,
				feature.cut_depth_blocks,
				feature.spire_count,
				feature.arch_strength,
				feature.shelf_strength,
				selection.score,
			)
		}

		terrain_generation_benchmark_surface_fortress_selection_log :: proc(
			selection: TerrainGenerationBenchmarkSurfaceFortressSelection,
		) {
			feature := selection.feature
			log.infof(
				"TERRAIN_GENERATION_BENCH_SURFACE_FORTRESS_SELECTION found=%v candidates=%d owner=(%d,%d) center=(%d,%d,%d) chunk=(%d,%d,%d) biome=%v height=%d radius=%d density=%v score=%.3f",
				selection.found,
				selection.candidate_count,
				feature.owner.x,
				feature.owner.z,
				selection.center.x,
				selection.center.y,
				selection.center.z,
				selection.chunk.x,
				selection.chunk.y,
				selection.chunk.z,
				feature.biome_id,
				feature.height_blocks,
				feature.radius_blocks,
				feature.density_class,
				selection.score,
			)
		}

		terrain_generation_benchmark_cave_selection_log :: proc(
			label: string,
			selection: TerrainGenerationBenchmarkCaveSelection,
		) {
			origin := chunk_origin_from_coord(selection.chunk)
			region_coord := biomes.generation_region_coord_from_block(origin.x, origin.y, origin.z)
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

		terrain_generation_benchmark_cave_selections_log :: proc(key: biomes.FeatureGridKey) {
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
				mouth_node_chunk := terrain_generation_benchmark_chunk_for_cave_node(
					anchors.mouth_node,
				)
				base = mouth_chunk
				terrain_generation_benchmark_coord_append_unique(
					&coords,
					&coord_count,
					mouth_chunk,
				)
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
				sinkhole_chunk := terrain_generation_benchmark_chunk_for_cave_anchor(
					anchors.sinkhole,
				)
				sinkhole_node_chunk := terrain_generation_benchmark_chunk_for_cave_node(
					anchors.sinkhole_node,
				)
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

		terrain_generation_benchmark_checksum :: proc(
			view: world_async.ChunkVoxelView,
		) -> (
			checksum: u64,
			stats: TerrainGenerationBenchmarkMaterialStats,
		) {
			for index := 0; index < CHUNK_BLOCK_COUNT; index += 1 {
				material := u32(view.blocks.material_id[index])
				if view.blocks.occupancy[index] == .Solid {
					stats.solid_count += 1
					checksum = checksum * 1099511628211 ~ u64(index + 1)
					checksum = checksum * 1099511628211 ~ u64(material + 17)
					palette := terrain_material_palette_index(view.blocks.material_id[index])
					stats.material_counts[palette] += 1
					if palette == TERRAIN_WATER_MAT_ID {
						stats.water_count += 1
					}
					if (u8(view.blocks.material_id[index]) &
						   TERRAIN_HYDROLOGY_DEBUG_MATERIAL_FLAG) !=
					   0 {
						stats.hydrology_debug_blocks += 1
					}
					if (u8(view.blocks.material_id[index]) &
						   TERRAIN_CAVE_NETWORK_DEBUG_MATERIAL_FLAG) !=
					   0 {
						stats.cave_debug_blocks += 1
					}
					if (u8(view.blocks.material_id[index]) &
						   TERRAIN_DECORATION_DEBUG_MATERIAL_FLAG) ==
					   TERRAIN_DECORATION_DEBUG_MATERIAL_FLAG {
						stats.decoration_debug_blocks += 1
					}
				} else {
					stats.empty_count += 1
					checksum = checksum * 1099511628211 ~ u64(index + 3)
				}
			}
			return
		}

		terrain_generation_benchmark_checksum_coords :: proc(
			view: ^world_async.ChunkVoxelView,
			coords: TerrainGenerationBenchmarkCoords,
			seed: u32,
			quality: world_async.ChunkGenerationQuality = .Full,
		) -> (
			checksum: u64,
			stats: TerrainGenerationBenchmarkMaterialStats,
		) {
			for coord in coords {
				terrain_heightfield_voxel_view_fill_quality(view, coord, seed, quality)
				chunk_checksum, chunk_stats := terrain_generation_benchmark_checksum(view^)
				checksum = checksum * 1099511628211 ~ chunk_checksum
				terrain_generation_benchmark_material_stats_add(&stats, chunk_stats)
			}
			return
		}

		terrain_generation_benchmark_material_stats_add :: proc(
			total: ^TerrainGenerationBenchmarkMaterialStats,
			stats: TerrainGenerationBenchmarkMaterialStats,
		) {
			total.solid_count += stats.solid_count
			total.empty_count += stats.empty_count
			total.water_count += stats.water_count
			total.hydrology_debug_blocks += stats.hydrology_debug_blocks
			total.cave_debug_blocks += stats.cave_debug_blocks
			total.decoration_debug_blocks += stats.decoration_debug_blocks
			for i := 0; i < TERRAIN_MATERIAL_PALETTE_COUNT; i += 1 {
				total.material_counts[i] += stats.material_counts[i]
			}
		}

		terrain_generation_benchmark_surface_morphology_stats_add_column :: proc(
			stats: ^TerrainGenerationBenchmarkSurfaceMorphologyStats,
			key: biomes.FeatureGridKey,
			column: TerrainBiomeColumn,
			features: []biomes.SurfaceMorphologyFeature,
			feature_count: u32,
			world_x, chunk_bottom_world_y, chunk_top_world_y, world_z: i32,
		) {
			feature_plan := TerrainSurfaceMorphologyColumnFeaturePlan{}
			terrain_surface_morphology_column_feature_plan_write(
				features,
				feature_count,
				world_x,
				world_z,
				&feature_plan,
			)
			column_may_intersect := terrain_surface_density_column_may_intersect_chunk(
				column,
				chunk_bottom_world_y,
				chunk_top_world_y,
			)
			if feature_plan.active {
				stats.feature_column_count += 1
				column_may_intersect =
					column_may_intersect ||
					(f32(chunk_bottom_world_y) <=
								column.surface_height_blocks + feature_plan.band_above &&
							f32(chunk_top_world_y) >=
								column.surface_height_blocks - feature_plan.band_below)
			}
			if !column_may_intersect {
				return
			}

			stats.active_column_count += 1
			morphology_profile := column.surface_morphology_profile
			morphology_shape := terrain_surface_morphology_column_shape_make(
				key,
				column,
				world_x,
				world_z,
			)
			for world_y := chunk_bottom_world_y; world_y <= chunk_top_world_y; world_y += 1 {
				base_density := terrain_surface_base_density_sample(column, world_y)
				band_above := math.max(
					morphology_profile.band_above_blocks,
					feature_plan.band_above,
				)
				band_below := math.max(
					terrain_surface_density_column_lower_influence_blocks(column),
					feature_plan.band_below,
				)
				if base_density < -band_above || base_density > band_below {
					continue
				}

				morphology_density := terrain_surface_density_sample_with_feature_plan(
					column,
					morphology_shape,
					&feature_plan,
					world_x,
					world_y,
					world_z,
				)
				base_solid := base_density >= 0
				morphology_solid := morphology_density >= 0
				stats.sample_count += 1
				if base_solid {
					stats.base_solid_count += 1
				}
				if morphology_solid {
					stats.morphology_solid_count += 1
					below_solid :=
						terrain_surface_density_sample_with_feature_plan(
							column,
							morphology_shape,
							&feature_plan,
							world_x,
							world_y - 1,
							world_z,
						) >=
						0
					if !below_solid {
						stats.unsupported_solid_count += 1
					}
				}
				if morphology_solid && !base_solid {
					stats.added_solid_count += 1
					stats.max_added_height_blocks = math.max(
						stats.max_added_height_blocks,
						-base_density,
					)
				}
				if !morphology_solid && base_solid {
					stats.removed_solid_count += 1
					stats.max_removed_depth_blocks = math.max(
						stats.max_removed_depth_blocks,
						base_density,
					)
				}
			}
		}

		terrain_generation_benchmark_surface_morphology_stats_from_coords :: proc(
			coords: TerrainGenerationBenchmarkCoords,
			seed: u32,
		) -> TerrainGenerationBenchmarkSurfaceMorphologyStats {
			key := terrain_generation_key_make(seed)
			stats := TerrainGenerationBenchmarkSurfaceMorphologyStats {
				chunk_count = u32(len(coords)),
			}
			for chunk_coord in coords {
				origin := chunk_origin_from_coord(chunk_coord)
				region_coord := biomes.generation_region_coord_from_block(
					origin.x,
					origin.y,
					origin.z,
				)
				region := terrain_generation_region_for_fill(key, region_coord)
				chunk_bounds := biomes.BlockBounds3 {
					min = {x = origin.x, y = origin.y, z = origin.z},
					max = {
						x = origin.x + CHUNK_BLOCK_LENGTH,
						y = origin.y + CHUNK_BLOCK_LENGTH,
						z = origin.z + CHUNK_BLOCK_LENGTH,
					},
				}
				query := biomes.generation_region_query_make_default(chunk_bounds)
				surface_morphology_features: [biomes.GENERATION_REGION_SURFACE_MORPHOLOGY_FEATURE_CAPACITY]biomes.SurfaceMorphologyFeature
				surface_morphology_feature_count :=
					biomes.generation_region_surface_morphology_features_write(
						&region,
						query,
						surface_morphology_features[:],
					)
				for z := i32(0); z < CHUNK_BLOCK_LENGTH; z += 1 {
					world_z := origin.z + z
					profile_row_cache := biomes.surface_biome_profile_row_cache_make(key, world_z)
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
							&profile_row_cache,
						)
						evaluation = terrain_surface_morphology_apply_feature_envelopes(
							evaluation,
							region.surface_morphology_features[:],
							region.surface_morphology_feature_count,
							world_x,
							world_z,
						)
						column := terrain_biome_column_from_profile_evaluation(
							key,
							evaluation,
							world_x,
							world_z,
						)
						terrain_generation_benchmark_surface_morphology_stats_add_column(
							&stats,
							key,
							column,
							surface_morphology_features[:],
							surface_morphology_feature_count,
							world_x,
							origin.y,
							origin.y + CHUNK_BLOCK_LENGTH - 1,
							world_z,
						)
					}
				}
			}
			return stats
		}

		terrain_generation_benchmark_surface_morphology_stats_log :: proc(
			phase: string,
			coords: TerrainGenerationBenchmarkCoords,
			seed: u32,
		) {
			stats := terrain_generation_benchmark_surface_morphology_stats_from_coords(
				coords,
				seed,
			)
			log.infof(
				"TERRAIN_GENERATION_BENCH_SURFACE_MORPHOLOGY phase=%s chunks=%d active_columns=%d feature_columns=%d samples=%d base_solid=%d morphology_solid=%d added_solid=%d removed_solid=%d unsupported_solid=%d max_added_height=%.3f max_removed_depth=%.3f",
				phase,
				stats.chunk_count,
				stats.active_column_count,
				stats.feature_column_count,
				stats.sample_count,
				stats.base_solid_count,
				stats.morphology_solid_count,
				stats.added_solid_count,
				stats.removed_solid_count,
				stats.unsupported_solid_count,
				stats.max_added_height_blocks,
				stats.max_removed_depth_blocks,
			)
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
						evaluation = terrain_surface_morphology_apply_feature_envelopes(
							evaluation,
							region.surface_morphology_features[:],
							region.surface_morphology_feature_count,
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
						local_water_below :=
							column.surface_height_blocks < hydrology_sample.water_level_blocks
						if local_water_below {
							stats.local_water_below_columns += 1
						}
						local_water_fill :=
							column.water_fill_active &&
							column.water_level_blocks + 0.001 >=
								hydrology_sample.water_level_blocks
						if local_water_fill {
							stats.local_water_fill_columns += 1
						}
						if local_water_below && !local_water_fill {
							water_depth :=
								hydrology_sample.water_level_blocks - column.surface_height_blocks
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

		terrain_generation_benchmark_surface_shape_stats_from_coords :: proc(
			coords: TerrainGenerationBenchmarkCoords,
			seed: u32,
		) -> TerrainGenerationBenchmarkSurfaceShapeStats {
			key := terrain_generation_key_make(seed)
			stats := TerrainGenerationBenchmarkSurfaceShapeStats {
				min_surface_height_blocks = max(f32),
				max_surface_height_blocks = -max(f32),
			}
			step := TERRAIN_GENERATION_BENCHMARK_SURFACE_SHAPE_STEP_BLOCKS
			step_f32 := f32(step)
			for chunk_coord in coords {
				origin := chunk_origin_from_coord(chunk_coord)
				for z := i32(0); z < CHUNK_BLOCK_LENGTH; z += step {
					world_z := origin.z + z
					for x := i32(0); x < CHUNK_BLOCK_LENGTH; x += step {
						world_x := origin.x + x
						column := terrain_biome_column_sample_direct(key, world_x, world_z)
						height := column.surface_height_blocks
						stats.column_count += 1
						stats.height_sum_blocks += height
						stats.min_surface_height_blocks = math.min(
							stats.min_surface_height_blocks,
							height,
						)
						stats.max_surface_height_blocks = math.max(
							stats.max_surface_height_blocks,
							height,
						)
						if height >= TERRAIN_SURFACE_HEIGHT_TOP_SOFT_START_BLOCKS - 6 {
							stats.peak_columns += 1
						}
						if height <= biomes.SEA_LEVEL_BLOCKS + 8 {
							stats.valley_columns += 1
						}

						east := terrain_biome_column_sample_direct(key, world_x + step, world_z)
						south := terrain_biome_column_sample_direct(key, world_x, world_z + step)
						slope_x := math.abs(east.surface_height_blocks - height) / step_f32
						slope_z := math.abs(south.surface_height_blocks - height) / step_f32
						local_slope := math.max(slope_x, slope_z)
						stats.slope_sample_count += 1
						stats.abs_slope_sum += local_slope
						stats.max_abs_slope = math.max(stats.max_abs_slope, local_slope)
						if local_slope >= 0.85 {
							stats.high_slope_columns += 1
						}
					}
				}
			}
			return stats
		}

		terrain_generation_benchmark_surface_shape_stats_log :: proc(
			phase: string,
			coords: TerrainGenerationBenchmarkCoords,
			seed: u32,
		) {
			stats := terrain_generation_benchmark_surface_shape_stats_from_coords(coords, seed)
			mean_height := f32(0)
			avg_abs_slope := f32(0)
			if stats.column_count > 0 {
				mean_height = stats.height_sum_blocks / f32(stats.column_count)
			}
			if stats.slope_sample_count > 0 {
				avg_abs_slope = stats.abs_slope_sum / f32(stats.slope_sample_count)
			}
			height_range := stats.max_surface_height_blocks - stats.min_surface_height_blocks
			log.infof(
				"TERRAIN_GENERATION_BENCH_SURFACE_SHAPE phase=%s columns=%d min_height=%.3f max_height=%.3f range=%.3f mean_height=%.3f avg_abs_slope=%.3f max_abs_slope=%.3f high_slope=%d peaks=%d valleys=%d",
				phase,
				stats.column_count,
				stats.min_surface_height_blocks,
				stats.max_surface_height_blocks,
				height_range,
				mean_height,
				avg_abs_slope,
				stats.max_abs_slope,
				stats.high_slope_columns,
				stats.peak_columns,
				stats.valley_columns,
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
						mouth_anchor := anchor.kind == .Cave_Mouth || anchor.kind == .Ravine_Breach
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
								   forward_unit >= -0.28 &&
								   forward_unit <= 0.45 &&
								   side_abs <= 0.52 {
									stats.mouth_aperture_open_blocks += 1
								}
								if depth_below_surface >= 0 &&
								   depth_below_surface <= radius * 3 / 2 &&
								   forward_unit >= 0.35 &&
								   forward_unit <= 1.35 &&
								   side_abs <= 0.72 {
									stats.mouth_throat_open_blocks += 1
								}
								if depth_below_surface >= radius / 2 &&
								   depth_below_surface <= radius * 3 &&
								   forward_unit >= 1.35 &&
								   forward_unit <= 2.65 &&
								   side_abs <= 0.82 {
									stats.mouth_inner_open_blocks += 1
								}
								if depth_below_surface >= 0 &&
								   depth_below_surface <= radius &&
								   forward_unit >= -0.10 &&
								   forward_unit <= 1.25 &&
								   side_abs >= 0.95 {
									stats.mouth_outer_carve_open_blocks += 1
								}
								if depth_below_surface >= -1 &&
								   depth_below_surface <= radius / 2 &&
								   forward_unit >= -0.78 &&
								   forward_unit <= 0.20 &&
								   side_abs <= 1.18 {
									stats.mouth_exterior_apron_open_blocks += 1
								}
								if depth_below_surface >= 0 && depth_below_surface <= radius {
									if side_abs <= 0.34 && forward_abs <= 0.82 {
										stats.mouth_lower_center_open_blocks += 1
									}
									if side_abs >= 0.36 &&
									   side_abs <= 0.86 &&
									   forward_abs <= 0.88 {
										stats.mouth_lower_side_band_open_blocks += 1
									}
								}
								if depth_below_surface >= radius / 3 &&
								   depth_below_surface <= radius * 2 &&
								   side_abs >= 0.46 &&
								   side_abs <= 0.94 &&
								   forward_unit >= -0.12 &&
								   forward_unit <= 2.35 {
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
			selected := [?]biomes.CaveAnchor{anchors.mouth, anchors.sinkhole}
			nodes := [?]biomes.CaveNetworkNode{anchors.mouth_node, anchors.sinkhole_node}
			found := [?]bool{anchors.mouth_found, anchors.sinkhole_found}

			for anchor, anchor_index in selected {
				if !found[anchor_index] {
					continue
				}
				stats.selected_anchor_count += 1
				#partial switch anchor.kind {
				case .Cave_Mouth:
					stats.mouth_count += 1
					opening_radius := math.max(f32(4), anchor.influence_radius_blocks)
					anchor_radius := math.max(f32(3), anchor.influence_radius_blocks * 0.55)
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
				"TERRAIN_GENERATION_BENCH_SURFACE_CAVE phase=%s selected=%d mouth=%d sinkhole=%d open_anchor=%d sealed_anchor=%d open_blocks=%d mouth_open=%d sinkhole_open=%d mouth_aperture=%d mouth_throat=%d mouth_inner=%d mouth_outer=%d mouth_apron=%d mouth_lower_center=%d mouth_lower_side=%d mouth_side_pocket=%d sinkhole_upper_center=%d sinkhole_upper_ledge=%d sinkhole_upper_outer=%d sinkhole_upper_side=%d sinkhole_upper_end=%d water_blocks=%d solid_blocks=%d near_surface_open=%d sub_surface_open=%d max_open_depth=%d min_open_blocks=%d mouth_link_run=%.2f mouth_link_drop=%.2f mouth_drop_per_run=%.3f mouth_bend_run=%.2f mouth_bend_drop=%.2f mouth_bend_drop_per_run=%.3f mouth_handoff_run=%.2f mouth_handoff_drop=%.2f mouth_handoff_drop_per_run=%.3f",
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
				stats.mouth_exterior_apron_open_blocks,
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
				mouth       = anchor,
				mouth_node  = node,
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
					f32(stats.mouth_throat_open_blocks) / f32(stats.mouth_aperture_open_blocks)
			}
			if stats.mouth_throat_open_blocks > 0 {
				inner_per_throat =
					f32(stats.mouth_inner_open_blocks) / f32(stats.mouth_throat_open_blocks)
			}

			log.infof(
				"TERRAIN_GENERATION_BENCH_SURFACE_CAVE_MOUTH_SIZE phase=%s label=%s found=%v style=%v owner=(%d,%d,%d) anchor=(%.2f,%.2f,%.2f) node=(%.2f,%.2f,%.2f) radius=%.2f size_support=%.3f open_blocks=%d aperture=%d throat=%d inner=%d outer=%d apron=%d lower_center=%d lower_side=%d side_pocket=%d water_blocks=%d solid_blocks=%d max_open_depth=%d min_open_blocks=%d link_run=%.2f link_drop=%.2f drop_per_run=%.3f bend_run=%.2f bend_drop=%.2f bend_drop_per_run=%.3f handoff_run=%.2f handoff_drop=%.2f handoff_drop_per_run=%.3f outer_per_aperture=%.3f throat_per_aperture=%.3f inner_per_throat=%.3f",
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
				stats.mouth_exterior_apron_open_blocks,
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
				edge_route_bounds: [biomes.GENERATION_REGION_CAVE_NETWORK_EDGE_CAPACITY]TerrainCaveEdgeRouteBounds
				terrain_density_cave_edge_route_bounds_fill(&region, edge_route_bounds[:])
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

							path_candidate := terrain_density_cave_field_sample_prefers_path(
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
								edge_route_bounds[:],
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
				component_sealed_count: u32
				component_external_link_count: u32

				visited[start_index] = true
				queue[queue_tail] = start_index
				queue_tail += 1

				for queue_head < queue_tail {
					node_index := queue[queue_head]
					queue_head += 1
					component_node_count += 1
					node := region.cave_network_nodes[node_index]

					if node.role == .Sealed_Secret {
						component_sealed_count += 1
					}
					if biomes.cave_region_role_requires_connectivity(node.role) {
						component_required_count += 1
					}
					if node.role != .Sealed_Secret &&
					   (terrain_density_cave_node_uses_profile_room(node) ||
							   node.radius_blocks >=
								   TERRAIN_CAVE_NODE_ISOLATED_CULL_RADIUS_BLOCKS) {
						component_large_room_count += 1
					}
					for anchor_index := u32(0);
					    anchor_index < region.cave_anchor_count;
					    anchor_index += 1 {
						anchor := region.cave_anchors[anchor_index]
						if anchor.feature_id != node.id && anchor.target_feature_id != node.id {
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
							terrain_generation_benchmark_cave_node_index_by_id(region, neighbor_id)
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
					if component_sealed_count == component_node_count {
						stats.component_sealed_tiny_count += 1
					} else {
						stats.component_playable_tiny_count += 1
					}
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
				case .Lakebed_Breach,
				     .Seabed_Breach,
				     .Underground_River_Source,
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
			total.component_playable_tiny_count += stats.component_playable_tiny_count
			total.component_sealed_tiny_count += stats.component_sealed_tiny_count
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
				"TERRAIN_GENERATION_BENCH_REGION coord=(%d,%d,%d) nodes=%d edges=%d anchors=%d water_nodes=%d water_segments=%d water_feature_anchors=%d major=%d water_linked=%d connector=%d pocket=%d resource=%d sealed=%d fungal=%d crystal=%d aquifer=%d rooted_macro=%d mineral_macro=%d aquifer_macro=%d shallow=%d mid=%d deep=%d cave_mouth=%d sinkhole=%d water_anchor=%d edge_tunnel=%d edge_canyon=%d edge_worm=%d edge_flooded=%d edge_fracture=%d edge_collapsed=%d edge_vertical=%d node_edge_connected=%d node_anchor_connected=%d node_bridge=%d node_culled=%d profile_room=%d profile_room_nonmajor=%d components=%d tiny_components=%d tiny_component_nodes=%d playable_tiny_components=%d sealed_tiny_components=%d component_external_links=%d anchored_tiny_components=%d mouth_tiny_components=%d sinkhole_tiny_components=%d required_tiny_components=%d large_room_tiny_components=%d max_component_nodes=%d",
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
				stats.component_playable_tiny_count,
				stats.component_sealed_tiny_count,
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
				"TERRAIN_GENERATION_BENCH_REGION_SUMMARY regions=%d nodes=%d edges=%d anchors=%d water_nodes=%d water_segments=%d water_feature_anchors=%d major=%d water_linked=%d connector=%d pocket=%d resource=%d sealed=%d fungal=%d crystal=%d aquifer=%d rooted_macro=%d mineral_macro=%d aquifer_macro=%d shallow=%d mid=%d deep=%d cave_mouth=%d sinkhole=%d water_anchor=%d edge_tunnel=%d edge_canyon=%d edge_worm=%d edge_flooded=%d edge_fracture=%d edge_collapsed=%d edge_vertical=%d node_edge_connected=%d node_anchor_connected=%d node_bridge=%d node_culled=%d profile_room=%d profile_room_nonmajor=%d components=%d tiny_components=%d tiny_component_nodes=%d playable_tiny_components=%d sealed_tiny_components=%d component_external_links=%d anchored_tiny_components=%d mouth_tiny_components=%d sinkhole_tiny_components=%d required_tiny_components=%d large_room_tiny_components=%d max_component_nodes=%d",
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
				total.component_playable_tiny_count,
				total.component_sealed_tiny_count,
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
			clear_chunk_cache_each_iteration: bool = false,
			quality: world_async.ChunkGenerationQuality = .Full,
		) {
			log.assertf(
				iterations > 0,
				"terrain generation benchmark iterations must be greater than zero",
			)
			terrain_generation_benchmark_cache_clear()
			for coord in coords {
				terrain_heightfield_voxel_view_fill_quality(view, coord, seed, quality)
			}

			profile := TerrainGenerationProfile{}
			previous_profile_context := terrain_generation_profile_context_begin(&profile)
			defer terrain_generation_profile_context_end(previous_profile_context)
			terrain_generation_profile_reset(&profile)
			start := time.tick_now()
			for _ in 0 ..< iterations {
				if reset_cache_each_iteration {
					terrain_generation_benchmark_cache_clear()
				} else if clear_chunk_cache_each_iteration {
					terrain_generation_chunk_cache_clear()
				}
				for coord in coords {
					terrain_heightfield_voxel_view_fill_quality(view, coord, seed, quality)
				}
			}
			duration := time.tick_since(start)

			chunk_iterations := iterations * u32(len(coords))
			terrain_generation_profile_log(phase, &profile)
			checksum, material_stats := terrain_generation_benchmark_checksum_coords(
				view,
				coords,
				seed,
				quality,
			)
			total_ms := time.duration_milliseconds(duration)
			avg_us := time.duration_microseconds(duration) / f64(chunk_iterations)
			log.infof(
				"TERRAIN_GENERATION_BENCH phase=%s iterations=%d chunk_iterations=%d total_ms=%.3f avg_us_per_chunk=%.3f checksum=%d solid_count=%d water_count=%d reset_cache=%v clear_chunk_cache=%v quality=%v",
				phase,
				iterations,
				chunk_iterations,
				total_ms,
				avg_us,
				checksum,
				material_stats.solid_count,
				material_stats.water_count,
				reset_cache_each_iteration,
				clear_chunk_cache_each_iteration,
				quality,
			)
			log.infof(
				"TERRAIN_GENERATION_BENCH_MATERIALS phase=%s empty=%d solid=%d grass=%d dirt=%d stone=%d wet=%d water=%d ash=%d aquifer=%d crystal=%d hydrology_debug=%d cave_debug=%d decoration_debug=%d",
				phase,
				material_stats.empty_count,
				material_stats.solid_count,
				material_stats.material_counts[TERRAIN_GRASS_MAT_ID],
				material_stats.material_counts[TERRAIN_DIRT_MAT_ID],
				material_stats.material_counts[TERRAIN_STONE_MAT_ID],
				material_stats.material_counts[TERRAIN_WET_MARSH_MAT_ID],
				material_stats.material_counts[TERRAIN_WATER_MAT_ID],
				material_stats.material_counts[TERRAIN_CORRUPTED_ASH_MAT_ID],
				material_stats.material_counts[TERRAIN_AQUIFER_WALL_MAT_ID],
				material_stats.material_counts[TERRAIN_CRYSTAL_MAT_ID],
				material_stats.hydrology_debug_blocks,
				material_stats.cave_debug_blocks,
				material_stats.decoration_debug_blocks,
			)
		}

		TerrainGenerationBenchmarkPhaseKind :: enum {
			Cave_Hot_Region_Cache,
			Cave_Warm_Region_Column_Cache,
			Cave_Proxy_Anchors,
			Surface_Water_Hot_Region_Cache,
			Surface_Cave_Hot_Region_Cache,
			Surface_Feature_Hot_Region_Cache,
			Surface_Fortress_Hot_Region_Cache,
			Cave_Reset_Region_Cache,
			Surface_Water_Reset_Region_Cache,
			Surface_Cave_Reset_Region_Cache,
			Surface_Feature_Reset_Region_Cache,
			Surface_Fortress_Reset_Region_Cache,
		}

		TerrainGenerationRegisteredFixture :: struct {
			phase:                            TerrainGenerationBenchmarkPhaseKind,
			phase_name:                       string,
			seed:                             u32,
			coords:                           TerrainGenerationBenchmarkCoords,
			reset_cache_each_iteration:       bool,
			clear_chunk_cache_each_iteration: bool,
			quality:                          world_async.ChunkGenerationQuality,
			cache_mode:                       string,
			cache_ownership_mode:             string,
			view:                             world_async.ChunkVoxelView,
			initialized:                      bool,
		}

		TerrainGenerationRegisteredResult :: struct {
			chunk_iterations:        u64,
			checksum:                u64,
			empty_count:             u64,
			solid_count:             u64,
			water_count:             u64,
			grass_count:             u64,
			dirt_count:              u64,
			stone_count:             u64,
			wet_count:               u64,
			ash_count:               u64,
			aquifer_wall_count:      u64,
			crystal_count:           u64,
			hydrology_debug_blocks:  u64,
			cave_debug_blocks:       u64,
			decoration_debug_blocks: u64,
			profile:                 TerrainGenerationProfile,
		}

		terrain_generation_registered_metrics := [?]bench.BenchmarkMetricDescriptor {
			{
				name = "chunk_iterations",
				kind = .U64,
				offset = offset_of(TerrainGenerationRegisteredResult, chunk_iterations),
				reduce = .Sum,
				unit = "chunks",
			},
			{
				name = "checksum",
				kind = .U64,
				offset = offset_of(TerrainGenerationRegisteredResult, checksum),
				reduce = .Last,
			},
			{
				name = "empty_count",
				kind = .U64,
				offset = offset_of(TerrainGenerationRegisteredResult, empty_count),
				reduce = .Last,
				unit = "blocks",
			},
			{
				name = "solid_count",
				kind = .U64,
				offset = offset_of(TerrainGenerationRegisteredResult, solid_count),
				reduce = .Last,
				unit = "blocks",
			},
			{
				name = "water_count",
				kind = .U64,
				offset = offset_of(TerrainGenerationRegisteredResult, water_count),
				reduce = .Last,
				unit = "blocks",
			},
			{
				name = "grass_count",
				kind = .U64,
				offset = offset_of(TerrainGenerationRegisteredResult, grass_count),
				reduce = .Last,
				unit = "blocks",
			},
			{
				name = "dirt_count",
				kind = .U64,
				offset = offset_of(TerrainGenerationRegisteredResult, dirt_count),
				reduce = .Last,
				unit = "blocks",
			},
			{
				name = "stone_count",
				kind = .U64,
				offset = offset_of(TerrainGenerationRegisteredResult, stone_count),
				reduce = .Last,
				unit = "blocks",
			},
			{
				name = "wet_count",
				kind = .U64,
				offset = offset_of(TerrainGenerationRegisteredResult, wet_count),
				reduce = .Last,
				unit = "blocks",
			},
			{
				name = "ash_count",
				kind = .U64,
				offset = offset_of(TerrainGenerationRegisteredResult, ash_count),
				reduce = .Last,
				unit = "blocks",
			},
			{
				name = "aquifer_wall_count",
				kind = .U64,
				offset = offset_of(TerrainGenerationRegisteredResult, aquifer_wall_count),
				reduce = .Last,
				unit = "blocks",
			},
			{
				name = "crystal_count",
				kind = .U64,
				offset = offset_of(TerrainGenerationRegisteredResult, crystal_count),
				reduce = .Last,
				unit = "blocks",
			},
			{
				name = "hydrology_debug_blocks",
				kind = .U64,
				offset = offset_of(TerrainGenerationRegisteredResult, hydrology_debug_blocks),
				reduce = .Last,
				unit = "blocks",
			},
			{
				name = "cave_debug_blocks",
				kind = .U64,
				offset = offset_of(TerrainGenerationRegisteredResult, cave_debug_blocks),
				reduce = .Last,
				unit = "blocks",
			},
			{
				name = "decoration_debug_blocks",
				kind = .U64,
				offset = offset_of(TerrainGenerationRegisteredResult, decoration_debug_blocks),
				reduce = .Last,
				unit = "blocks",
			},
			{
				name = "profile_chunk_count",
				kind = .U64,
				offset = offset_of(TerrainGenerationRegisteredResult, profile) +
				offset_of(TerrainGenerationProfile, chunk_count),
				reduce = .Last,
				unit = "chunks",
			},
			{
				name = "profile_total_ns",
				kind = .I64,
				offset = offset_of(TerrainGenerationRegisteredResult, profile) +
				offset_of(TerrainGenerationProfile, total),
				reduce = .Last,
				unit = "ns",
			},
			{
				name = "profile_clear_ns",
				kind = .I64,
				offset = offset_of(TerrainGenerationRegisteredResult, profile) +
				offset_of(TerrainGenerationProfile, clear),
				reduce = .Last,
				unit = "ns",
			},
			{
				name = "profile_region_ns",
				kind = .I64,
				offset = offset_of(TerrainGenerationRegisteredResult, profile) +
				offset_of(TerrainGenerationProfile, region),
				reduce = .Last,
				unit = "ns",
			},
			{
				name = "profile_columns_ns",
				kind = .I64,
				offset = offset_of(TerrainGenerationRegisteredResult, profile) +
				offset_of(TerrainGenerationProfile, columns),
				reduce = .Last,
				unit = "ns",
			},
			{
				name = "profile_column_cache_ns",
				kind = .I64,
				offset = offset_of(TerrainGenerationRegisteredResult, profile) +
				offset_of(TerrainGenerationProfile, column_cache),
				reduce = .Last,
				unit = "ns",
			},
			{
				name = "profile_base_fill_ns",
				kind = .I64,
				offset = offset_of(TerrainGenerationRegisteredResult, profile) +
				offset_of(TerrainGenerationProfile, base_fill),
				reduce = .Last,
				unit = "ns",
			},
			{
				name = "profile_column_cache_lookup_ns",
				kind = .I64,
				offset = offset_of(TerrainGenerationRegisteredResult, profile) +
				offset_of(TerrainGenerationProfile, column_cache_lookup),
				reduce = .Last,
				unit = "ns",
			},
			{
				name = "profile_column_miss_profile_eval_ns",
				kind = .I64,
				offset = offset_of(TerrainGenerationRegisteredResult, profile) +
				offset_of(TerrainGenerationProfile, column_miss_profile_eval),
				reduce = .Last,
				unit = "ns",
			},
			{
				name = "profile_hydrology_surface_sample_ns",
				kind = .I64,
				offset = offset_of(TerrainGenerationRegisteredResult, profile) +
				offset_of(TerrainGenerationProfile, hydrology_surface_sample),
				reduce = .Last,
				unit = "ns",
			},
			{
				name = "profile_surface_feature_envelope_ns",
				kind = .I64,
				offset = offset_of(TerrainGenerationRegisteredResult, profile) +
				offset_of(TerrainGenerationProfile, surface_feature_envelope),
				reduce = .Last,
				unit = "ns",
			},
			{
				name = "profile_water_separator_ns",
				kind = .I64,
				offset = offset_of(TerrainGenerationRegisteredResult, profile) +
				offset_of(TerrainGenerationProfile, water_separator),
				reduce = .Last,
				unit = "ns",
			},
			{
				name = "profile_water_separator_column_sample_ns",
				kind = .I64,
				offset = offset_of(TerrainGenerationRegisteredResult, profile) +
				offset_of(TerrainGenerationProfile, water_separator_column_sample),
				reduce = .Last,
				unit = "ns",
			},
			{
				name = "profile_water_separator_preflight_ns",
				kind = .I64,
				offset = offset_of(TerrainGenerationRegisteredResult, profile) +
				offset_of(TerrainGenerationProfile, water_separator_preflight),
				reduce = .Last,
				unit = "ns",
			},
			{
				name = "profile_water_separator_padding_sample_ns",
				kind = .I64,
				offset = offset_of(TerrainGenerationRegisteredResult, profile) +
				offset_of(TerrainGenerationProfile, water_separator_padding_sample),
				reduce = .Last,
				unit = "ns",
			},
			{
				name = "profile_water_separator_seed_build_ns",
				kind = .I64,
				offset = offset_of(TerrainGenerationRegisteredResult, profile) +
				offset_of(TerrainGenerationProfile, water_separator_seed_build),
				reduce = .Last,
				unit = "ns",
			},
			{
				name = "profile_water_separator_column_scan_ns",
				kind = .I64,
				offset = offset_of(TerrainGenerationRegisteredResult, profile) +
				offset_of(TerrainGenerationProfile, water_separator_column_scan),
				reduce = .Last,
				unit = "ns",
			},
			{
				name = "profile_water_separator_column_apply_ns",
				kind = .I64,
				offset = offset_of(TerrainGenerationRegisteredResult, profile) +
				offset_of(TerrainGenerationProfile, water_separator_column_apply),
				reduce = .Last,
				unit = "ns",
			},
			{
				name = "profile_water_separator_padding_samples",
				kind = .U64,
				offset = offset_of(TerrainGenerationRegisteredResult, profile) +
				offset_of(TerrainGenerationProfile, water_separator_padding_samples),
				reduce = .Last,
			},
			{
				name = "profile_water_separator_seed_count",
				kind = .U64,
				offset = offset_of(TerrainGenerationRegisteredResult, profile) +
				offset_of(TerrainGenerationProfile, water_separator_seed_count),
				reduce = .Last,
			},
			{
				name = "profile_water_separator_columns_applied",
				kind = .U64,
				offset = offset_of(TerrainGenerationRegisteredResult, profile) +
				offset_of(TerrainGenerationProfile, water_separator_columns_applied),
				reduce = .Last,
			},
			{
				name = "profile_water_separator_sample_cache_hits",
				kind = .U64,
				offset = offset_of(TerrainGenerationRegisteredResult, profile) +
				offset_of(TerrainGenerationProfile, water_separator_sample_cache_hits),
				reduce = .Last,
			},
			{
				name = "profile_water_separator_sample_cache_misses",
				kind = .U64,
				offset = offset_of(TerrainGenerationRegisteredResult, profile) +
				offset_of(TerrainGenerationProfile, water_separator_sample_cache_misses),
				reduce = .Last,
			},
			{
				name = "profile_water_separator_sample_cache_stores",
				kind = .U64,
				offset = offset_of(TerrainGenerationRegisteredResult, profile) +
				offset_of(TerrainGenerationProfile, water_separator_sample_cache_stores),
				reduce = .Last,
			},
			{
				name = "profile_water_separator_sample_cache_evictions",
				kind = .U64,
				offset = offset_of(TerrainGenerationRegisteredResult, profile) +
				offset_of(TerrainGenerationProfile, water_separator_sample_cache_evictions),
				reduce = .Last,
			},
			{
				name = "profile_structure_pad_ns",
				kind = .I64,
				offset = offset_of(TerrainGenerationRegisteredResult, profile) +
				offset_of(TerrainGenerationProfile, structure_pad),
				reduce = .Last,
				unit = "ns",
			},
			{
				name = "profile_surface_feature_query_ns",
				kind = .I64,
				offset = offset_of(TerrainGenerationRegisteredResult, profile) +
				offset_of(TerrainGenerationProfile, surface_feature_query),
				reduce = .Last,
				unit = "ns",
			},
			{
				name = "profile_feature_plan_build_ns",
				kind = .I64,
				offset = offset_of(TerrainGenerationRegisteredResult, profile) +
				offset_of(TerrainGenerationProfile, feature_plan_build),
				reduce = .Last,
				unit = "ns",
			},
			{
				name = "profile_surface_shape_make_ns",
				kind = .I64,
				offset = offset_of(TerrainGenerationRegisteredResult, profile) +
				offset_of(TerrainGenerationProfile, surface_shape_make),
				reduce = .Last,
				unit = "ns",
			},
			{
				name = "profile_surface_density_sample_ns",
				kind = .I64,
				offset = offset_of(TerrainGenerationRegisteredResult, profile) +
				offset_of(TerrainGenerationProfile, surface_density_sample),
				reduce = .Last,
				unit = "ns",
			},
			{
				name = "profile_heightfield_span_write_ns",
				kind = .I64,
				offset = offset_of(TerrainGenerationRegisteredResult, profile) +
				offset_of(TerrainGenerationProfile, heightfield_span_write),
				reduce = .Last,
				unit = "ns",
			},
			{
				name = "profile_morphology_span_write_ns",
				kind = .I64,
				offset = offset_of(TerrainGenerationRegisteredResult, profile) +
				offset_of(TerrainGenerationProfile, morphology_span_write),
				reduce = .Last,
				unit = "ns",
			},
			{
				name = "profile_block_material_write_ns",
				kind = .I64,
				offset = offset_of(TerrainGenerationRegisteredResult, profile) +
				offset_of(TerrainGenerationProfile, block_material_write),
				reduce = .Last,
				unit = "ns",
			},
			{
				name = "profile_final_chunk_cache_hits",
				kind = .U64,
				offset = offset_of(TerrainGenerationRegisteredResult, profile) +
				offset_of(TerrainGenerationProfile, final_chunk_cache_hits),
				reduce = .Last,
			},
			{
				name = "profile_final_chunk_cache_misses",
				kind = .U64,
				offset = offset_of(TerrainGenerationRegisteredResult, profile) +
				offset_of(TerrainGenerationProfile, final_chunk_cache_misses),
				reduce = .Last,
			},
			{
				name = "profile_final_chunk_cache_stores",
				kind = .U64,
				offset = offset_of(TerrainGenerationRegisteredResult, profile) +
				offset_of(TerrainGenerationProfile, final_chunk_cache_stores),
				reduce = .Last,
			},
			{
				name = "profile_final_chunk_cache_evictions",
				kind = .U64,
				offset = offset_of(TerrainGenerationRegisteredResult, profile) +
				offset_of(TerrainGenerationProfile, final_chunk_cache_evictions),
				reduce = .Last,
			},
			{
				name = "profile_final_chunk_cache_clears",
				kind = .U64,
				offset = offset_of(TerrainGenerationRegisteredResult, profile) +
				offset_of(TerrainGenerationProfile, final_chunk_cache_clears),
				reduce = .Last,
			},
			{
				name = "profile_column_cache_hits",
				kind = .U64,
				offset = offset_of(TerrainGenerationRegisteredResult, profile) +
				offset_of(TerrainGenerationProfile, column_cache_hits),
				reduce = .Last,
			},
			{
				name = "profile_column_cache_misses",
				kind = .U64,
				offset = offset_of(TerrainGenerationRegisteredResult, profile) +
				offset_of(TerrainGenerationProfile, column_cache_misses),
				reduce = .Last,
			},
			{
				name = "profile_column_cache_stores",
				kind = .U64,
				offset = offset_of(TerrainGenerationRegisteredResult, profile) +
				offset_of(TerrainGenerationProfile, column_cache_stores),
				reduce = .Last,
			},
			{
				name = "profile_column_cache_evictions",
				kind = .U64,
				offset = offset_of(TerrainGenerationRegisteredResult, profile) +
				offset_of(TerrainGenerationProfile, column_cache_evictions),
				reduce = .Last,
			},
			{
				name = "profile_column_cache_clears",
				kind = .U64,
				offset = offset_of(TerrainGenerationRegisteredResult, profile) +
				offset_of(TerrainGenerationProfile, column_cache_clears),
				reduce = .Last,
			},
			{
				name = "profile_region_cache_hits",
				kind = .U64,
				offset = offset_of(TerrainGenerationRegisteredResult, profile) +
				offset_of(TerrainGenerationProfile, region_cache_hits),
				reduce = .Last,
			},
			{
				name = "profile_region_cache_misses",
				kind = .U64,
				offset = offset_of(TerrainGenerationRegisteredResult, profile) +
				offset_of(TerrainGenerationProfile, region_cache_misses),
				reduce = .Last,
			},
			{
				name = "profile_region_cache_stores",
				kind = .U64,
				offset = offset_of(TerrainGenerationRegisteredResult, profile) +
				offset_of(TerrainGenerationProfile, region_cache_stores),
				reduce = .Last,
			},
			{
				name = "profile_region_cache_evictions",
				kind = .U64,
				offset = offset_of(TerrainGenerationRegisteredResult, profile) +
				offset_of(TerrainGenerationProfile, region_cache_evictions),
				reduce = .Last,
			},
			{
				name = "profile_region_cache_clears",
				kind = .U64,
				offset = offset_of(TerrainGenerationRegisteredResult, profile) +
				offset_of(TerrainGenerationProfile, region_cache_clears),
				reduce = .Last,
			},
			{
				name = "profile_cave_overlay_cache_hits",
				kind = .U64,
				offset = offset_of(TerrainGenerationRegisteredResult, profile) +
				offset_of(TerrainGenerationProfile, cave_overlay_cache_hits),
				reduce = .Last,
			},
			{
				name = "profile_cave_overlay_cache_misses",
				kind = .U64,
				offset = offset_of(TerrainGenerationRegisteredResult, profile) +
				offset_of(TerrainGenerationProfile, cave_overlay_cache_misses),
				reduce = .Last,
			},
			{
				name = "profile_cave_overlay_cache_stores",
				kind = .U64,
				offset = offset_of(TerrainGenerationRegisteredResult, profile) +
				offset_of(TerrainGenerationProfile, cave_overlay_cache_stores),
				reduce = .Last,
			},
			{
				name = "profile_cave_overlay_cache_evictions",
				kind = .U64,
				offset = offset_of(TerrainGenerationRegisteredResult, profile) +
				offset_of(TerrainGenerationProfile, cave_overlay_cache_evictions),
				reduce = .Last,
			},
			{
				name = "profile_cave_overlay_cache_clears",
				kind = .U64,
				offset = offset_of(TerrainGenerationRegisteredResult, profile) +
				offset_of(TerrainGenerationProfile, cave_overlay_cache_clears),
				reduce = .Last,
			},
			{
				name = "profile_cave_field_ns",
				kind = .I64,
				offset = offset_of(TerrainGenerationRegisteredResult, profile) +
				offset_of(TerrainGenerationProfile, cave_field),
				reduce = .Last,
				unit = "ns",
			},
			{
				name = "profile_cave_field_scan_ns",
				kind = .I64,
				offset = offset_of(TerrainGenerationRegisteredResult, profile) +
				offset_of(TerrainGenerationProfile, cave_field_scan),
				reduce = .Last,
				unit = "ns",
			},
			{
				name = "profile_cave_field_network_ns",
				kind = .I64,
				offset = offset_of(TerrainGenerationRegisteredResult, profile) +
				offset_of(TerrainGenerationProfile, cave_field_network),
				reduce = .Last,
				unit = "ns",
			},
			{
				name = "profile_cave_field_path_ns",
				kind = .I64,
				offset = offset_of(TerrainGenerationRegisteredResult, profile) +
				offset_of(TerrainGenerationProfile, cave_field_path),
				reduce = .Last,
				unit = "ns",
			},
			{
				name = "profile_cave_field_pocket_throat_ns",
				kind = .I64,
				offset = offset_of(TerrainGenerationRegisteredResult, profile) +
				offset_of(TerrainGenerationProfile, cave_field_pocket_throat),
				reduce = .Last,
				unit = "ns",
			},
			{
				name = "profile_cave_field_pocket_cluster_ns",
				kind = .I64,
				offset = offset_of(TerrainGenerationRegisteredResult, profile) +
				offset_of(TerrainGenerationProfile, cave_field_pocket_cluster),
				reduce = .Last,
				unit = "ns",
			},
			{
				name = "profile_cave_field_chamber_ns",
				kind = .I64,
				offset = offset_of(TerrainGenerationRegisteredResult, profile) +
				offset_of(TerrainGenerationProfile, cave_field_chamber),
				reduce = .Last,
				unit = "ns",
			},
			{
				name = "profile_cave_field_bridge_ns",
				kind = .I64,
				offset = offset_of(TerrainGenerationRegisteredResult, profile) +
				offset_of(TerrainGenerationProfile, cave_field_bridge),
				reduce = .Last,
				unit = "ns",
			},
			{
				name = "profile_cave_field_sample_points",
				kind = .U64,
				offset = offset_of(TerrainGenerationRegisteredResult, profile) +
				offset_of(TerrainGenerationProfile, cave_field_sample_points),
				reduce = .Last,
			},
			{
				name = "profile_cave_field_depth_rejects",
				kind = .U64,
				offset = offset_of(TerrainGenerationRegisteredResult, profile) +
				offset_of(TerrainGenerationProfile, cave_field_depth_rejects),
				reduce = .Last,
			},
			{
				name = "profile_cave_field_candidate_rejects",
				kind = .U64,
				offset = offset_of(TerrainGenerationRegisteredResult, profile) +
				offset_of(TerrainGenerationProfile, cave_field_candidate_rejects),
				reduce = .Last,
			},
			{
				name = "profile_cave_field_candidates",
				kind = .U64,
				offset = offset_of(TerrainGenerationRegisteredResult, profile) +
				offset_of(TerrainGenerationProfile, cave_field_candidates),
				reduce = .Last,
			},
			{
				name = "profile_cave_field_network_rejects",
				kind = .U64,
				offset = offset_of(TerrainGenerationRegisteredResult, profile) +
				offset_of(TerrainGenerationProfile, cave_field_network_rejects),
				reduce = .Last,
			},
			{
				name = "profile_cave_field_capacity_rejects",
				kind = .U64,
				offset = offset_of(TerrainGenerationRegisteredResult, profile) +
				offset_of(TerrainGenerationProfile, cave_field_capacity_rejects),
				reduce = .Last,
			},
			{
				name = "profile_cave_field_path_candidates",
				kind = .U64,
				offset = offset_of(TerrainGenerationRegisteredResult, profile) +
				offset_of(TerrainGenerationProfile, cave_field_path_candidates),
				reduce = .Last,
			},
			{
				name = "profile_cave_field_route_pocket_candidates",
				kind = .U64,
				offset = offset_of(TerrainGenerationRegisteredResult, profile) +
				offset_of(TerrainGenerationProfile, cave_field_route_pocket_candidates),
				reduce = .Last,
			},
			{
				name = "profile_cave_field_chamber_candidates",
				kind = .U64,
				offset = offset_of(TerrainGenerationRegisteredResult, profile) +
				offset_of(TerrainGenerationProfile, cave_field_chamber_candidates),
				reduce = .Last,
			},
			{
				name = "profile_cave_field_stamps",
				kind = .U64,
				offset = offset_of(TerrainGenerationRegisteredResult, profile) +
				offset_of(TerrainGenerationProfile, cave_field_stamps),
				reduce = .Last,
			},
			{
				name = "profile_cave_field_path_stamps",
				kind = .U64,
				offset = offset_of(TerrainGenerationRegisteredResult, profile) +
				offset_of(TerrainGenerationProfile, cave_field_path_stamps),
				reduce = .Last,
			},
			{
				name = "profile_cave_field_route_pocket_stamps",
				kind = .U64,
				offset = offset_of(TerrainGenerationRegisteredResult, profile) +
				offset_of(TerrainGenerationProfile, cave_field_route_pocket_stamps),
				reduce = .Last,
			},
			{
				name = "profile_cave_field_chamber_stamps",
				kind = .U64,
				offset = offset_of(TerrainGenerationRegisteredResult, profile) +
				offset_of(TerrainGenerationProfile, cave_field_chamber_stamps),
				reduce = .Last,
			},
			{
				name = "profile_cave_field_bridge_stamps",
				kind = .U64,
				offset = offset_of(TerrainGenerationRegisteredResult, profile) +
				offset_of(TerrainGenerationProfile, cave_field_bridge_stamps),
				reduce = .Last,
			},
			{
				name = "profile_route_pocket_cluster_rows_scanned",
				kind = .U64,
				offset = offset_of(TerrainGenerationRegisteredResult, profile) +
				offset_of(TerrainGenerationProfile, route_pocket_cluster_rows_scanned),
				reduce = .Last,
			},
			{
				name = "profile_route_pocket_cluster_rows_box",
				kind = .U64,
				offset = offset_of(TerrainGenerationRegisteredResult, profile) +
				offset_of(TerrainGenerationProfile, route_pocket_cluster_rows_box),
				reduce = .Last,
			},
			{
				name = "profile_route_pocket_cluster_voxel_candidates",
				kind = .U64,
				offset = offset_of(TerrainGenerationRegisteredResult, profile) +
				offset_of(TerrainGenerationProfile, route_pocket_cluster_voxel_candidates),
				reduce = .Last,
			},
			{
				name = "profile_route_pocket_cluster_carveable_candidates",
				kind = .U64,
				offset = offset_of(TerrainGenerationRegisteredResult, profile) +
				offset_of(TerrainGenerationProfile, route_pocket_cluster_carveable_candidates),
				reduce = .Last,
			},
			{
				name = "profile_route_pocket_cluster_shape_candidates",
				kind = .U64,
				offset = offset_of(TerrainGenerationRegisteredResult, profile) +
				offset_of(TerrainGenerationProfile, route_pocket_cluster_shape_candidates),
				reduce = .Last,
			},
			{
				name = "profile_route_pocket_cluster_worley_candidates",
				kind = .U64,
				offset = offset_of(TerrainGenerationRegisteredResult, profile) +
				offset_of(TerrainGenerationProfile, route_pocket_cluster_worley_candidates),
				reduce = .Last,
			},
			{
				name = "profile_cave_network_ns",
				kind = .I64,
				offset = offset_of(TerrainGenerationRegisteredResult, profile) +
				offset_of(TerrainGenerationProfile, cave_network),
				reduce = .Last,
				unit = "ns",
			},
			{
				name = "profile_water_ns",
				kind = .I64,
				offset = offset_of(TerrainGenerationRegisteredResult, profile) +
				offset_of(TerrainGenerationProfile, water),
				reduce = .Last,
				unit = "ns",
			},
			{
				name = "profile_decoration_ns",
				kind = .I64,
				offset = offset_of(TerrainGenerationRegisteredResult, profile) +
				offset_of(TerrainGenerationProfile, decoration),
				reduce = .Last,
				unit = "ns",
			},
			{
				name = "profile_network_connectivity_ns",
				kind = .I64,
				offset = offset_of(TerrainGenerationRegisteredResult, profile) +
				offset_of(TerrainGenerationProfile, network_connectivity),
				reduce = .Last,
				unit = "ns",
			},
			{
				name = "profile_network_nodes_ns",
				kind = .I64,
				offset = offset_of(TerrainGenerationRegisteredResult, profile) +
				offset_of(TerrainGenerationProfile, network_nodes),
				reduce = .Last,
				unit = "ns",
			},
			{
				name = "profile_network_edges_ns",
				kind = .I64,
				offset = offset_of(TerrainGenerationRegisteredResult, profile) +
				offset_of(TerrainGenerationProfile, network_edges),
				reduce = .Last,
				unit = "ns",
			},
			{
				name = "profile_network_bridges_ns",
				kind = .I64,
				offset = offset_of(TerrainGenerationRegisteredResult, profile) +
				offset_of(TerrainGenerationProfile, network_bridges),
				reduce = .Last,
				unit = "ns",
			},
			{
				name = "profile_network_anchors_ns",
				kind = .I64,
				offset = offset_of(TerrainGenerationRegisteredResult, profile) +
				offset_of(TerrainGenerationProfile, network_anchors),
				reduce = .Last,
				unit = "ns",
			},
			{
				name = "profile_node_rooms_ns",
				kind = .I64,
				offset = offset_of(TerrainGenerationRegisteredResult, profile) +
				offset_of(TerrainGenerationProfile, node_rooms),
				reduce = .Last,
				unit = "ns",
			},
			{
				name = "profile_node_perimeter_ns",
				kind = .I64,
				offset = offset_of(TerrainGenerationRegisteredResult, profile) +
				offset_of(TerrainGenerationProfile, node_perimeter),
				reduce = .Last,
				unit = "ns",
			},
			{
				name = "profile_node_satellites_ns",
				kind = .I64,
				offset = offset_of(TerrainGenerationRegisteredResult, profile) +
				offset_of(TerrainGenerationProfile, node_satellites),
				reduce = .Last,
				unit = "ns",
			},
			{
				name = "profile_node_portals_ns",
				kind = .I64,
				offset = offset_of(TerrainGenerationRegisteredResult, profile) +
				offset_of(TerrainGenerationProfile, node_portals),
				reduce = .Last,
				unit = "ns",
			},
			{
				name = "profile_node_satellite_direct_ns",
				kind = .I64,
				offset = offset_of(TerrainGenerationRegisteredResult, profile) +
				offset_of(TerrainGenerationProfile, node_satellite_direct),
				reduce = .Last,
				unit = "ns",
			},
			{
				name = "profile_node_satellite_apron_ns",
				kind = .I64,
				offset = offset_of(TerrainGenerationRegisteredResult, profile) +
				offset_of(TerrainGenerationProfile, node_satellite_apron),
				reduce = .Last,
				unit = "ns",
			},
			{
				name = "profile_node_satellite_cluster_ns",
				kind = .I64,
				offset = offset_of(TerrainGenerationRegisteredResult, profile) +
				offset_of(TerrainGenerationProfile, node_satellite_cluster),
				reduce = .Last,
				unit = "ns",
			},
			{
				name = "profile_edge_core_ns",
				kind = .I64,
				offset = offset_of(TerrainGenerationRegisteredResult, profile) +
				offset_of(TerrainGenerationProfile, edge_core),
				reduce = .Last,
				unit = "ns",
			},
			{
				name = "profile_edge_approach_ns",
				kind = .I64,
				offset = offset_of(TerrainGenerationRegisteredResult, profile) +
				offset_of(TerrainGenerationProfile, edge_approach),
				reduce = .Last,
				unit = "ns",
			},
			{
				name = "profile_edge_braids_ns",
				kind = .I64,
				offset = offset_of(TerrainGenerationRegisteredResult, profile) +
				offset_of(TerrainGenerationProfile, edge_braids),
				reduce = .Last,
				unit = "ns",
			},
			{
				name = "profile_edge_bypasses_ns",
				kind = .I64,
				offset = offset_of(TerrainGenerationRegisteredResult, profile) +
				offset_of(TerrainGenerationProfile, edge_bypasses),
				reduce = .Last,
				unit = "ns",
			},
			{
				name = "profile_edge_alcoves_ns",
				kind = .I64,
				offset = offset_of(TerrainGenerationRegisteredResult, profile) +
				offset_of(TerrainGenerationProfile, edge_alcoves),
				reduce = .Last,
				unit = "ns",
			},
			{
				name = "profile_edge_chamberlets_ns",
				kind = .I64,
				offset = offset_of(TerrainGenerationRegisteredResult, profile) +
				offset_of(TerrainGenerationProfile, edge_chamberlets),
				reduce = .Last,
				unit = "ns",
			},
			{
				name = "profile_edge_seams_ns",
				kind = .I64,
				offset = offset_of(TerrainGenerationRegisteredResult, profile) +
				offset_of(TerrainGenerationProfile, edge_seams),
				reduce = .Last,
				unit = "ns",
			},
			{
				name = "profile_surface_morphology_chunks",
				kind = .U64,
				offset = offset_of(TerrainGenerationRegisteredResult, profile) +
				offset_of(TerrainGenerationProfile, surface_morphology_chunks),
				reduce = .Last,
			},
			{
				name = "profile_surface_heightfield_chunks",
				kind = .U64,
				offset = offset_of(TerrainGenerationRegisteredResult, profile) +
				offset_of(TerrainGenerationProfile, surface_heightfield_chunks),
				reduce = .Last,
			},
			{
				name = "profile_surface_morphology_features",
				kind = .U64,
				offset = offset_of(TerrainGenerationRegisteredResult, profile) +
				offset_of(TerrainGenerationProfile, surface_morphology_features),
				reduce = .Last,
			},
			{
				name = "profile_surface_morphology_feature_columns",
				kind = .U64,
				offset = offset_of(TerrainGenerationRegisteredResult, profile) +
				offset_of(TerrainGenerationProfile, surface_morphology_feature_columns),
				reduce = .Last,
			},
			{
				name = "profile_edge_core_segment_calls",
				kind = .U64,
				offset = offset_of(TerrainGenerationRegisteredResult, profile) +
				offset_of(TerrainGenerationProfile, edge_core_segment_calls),
				reduce = .Last,
			},
			{
				name = "profile_edge_core_segment_bounds_hits",
				kind = .U64,
				offset = offset_of(TerrainGenerationRegisteredResult, profile) +
				offset_of(TerrainGenerationProfile, edge_core_segment_bounds_hits),
				reduce = .Last,
			},
			{
				name = "profile_edge_core_rows_scanned",
				kind = .U64,
				offset = offset_of(TerrainGenerationRegisteredResult, profile) +
				offset_of(TerrainGenerationProfile, edge_core_rows_scanned),
				reduce = .Last,
			},
			{
				name = "profile_edge_core_rows_projected",
				kind = .U64,
				offset = offset_of(TerrainGenerationRegisteredResult, profile) +
				offset_of(TerrainGenerationProfile, edge_core_rows_projected),
				reduce = .Last,
			},
			{
				name = "profile_edge_core_rows_capsule",
				kind = .U64,
				offset = offset_of(TerrainGenerationRegisteredResult, profile) +
				offset_of(TerrainGenerationProfile, edge_core_rows_capsule),
				reduce = .Last,
			},
			{
				name = "profile_edge_core_voxel_candidates",
				kind = .U64,
				offset = offset_of(TerrainGenerationRegisteredResult, profile) +
				offset_of(TerrainGenerationProfile, edge_core_voxel_candidates),
				reduce = .Last,
			},
			{
				name = "profile_edge_core_carveable_candidates",
				kind = .U64,
				offset = offset_of(TerrainGenerationRegisteredResult, profile) +
				offset_of(TerrainGenerationProfile, edge_core_carveable_candidates),
				reduce = .Last,
			},
			{
				name = "profile_edge_core_shape_candidates",
				kind = .U64,
				offset = offset_of(TerrainGenerationRegisteredResult, profile) +
				offset_of(TerrainGenerationProfile, edge_core_shape_candidates),
				reduce = .Last,
			},
			{
				name = "profile_edge_core_noise_candidates",
				kind = .U64,
				offset = offset_of(TerrainGenerationRegisteredResult, profile) +
				offset_of(TerrainGenerationProfile, edge_core_noise_candidates),
				reduce = .Last,
			},
			{
				name = "profile_edge_core_threshold_candidates",
				kind = .U64,
				offset = offset_of(TerrainGenerationRegisteredResult, profile) +
				offset_of(TerrainGenerationProfile, edge_core_threshold_candidates),
				reduce = .Last,
			},
			{
				name = "profile_carve_attempts",
				kind = .U64,
				offset = offset_of(TerrainGenerationRegisteredResult, profile) +
				offset_of(TerrainGenerationProfile, carve_attempts),
				reduce = .Last,
			},
			{
				name = "profile_carve_successes",
				kind = .U64,
				offset = offset_of(TerrainGenerationRegisteredResult, profile) +
				offset_of(TerrainGenerationProfile, carve_successes),
				reduce = .Last,
			},
			{
				name = "profile_wall_neighbor_checks",
				kind = .U64,
				offset = offset_of(TerrainGenerationRegisteredResult, profile) +
				offset_of(TerrainGenerationProfile, wall_neighbor_checks),
				reduce = .Last,
			},
			{
				name = "profile_wall_neighbor_writes",
				kind = .U64,
				offset = offset_of(TerrainGenerationRegisteredResult, profile) +
				offset_of(TerrainGenerationProfile, wall_neighbor_writes),
				reduce = .Last,
			},
			{
				name = "profile_decoration_surface_candidates",
				kind = .U64,
				offset = offset_of(TerrainGenerationRegisteredResult, profile) +
				offset_of(TerrainGenerationProfile, decoration_surface_candidates),
				reduce = .Last,
			},
			{
				name = "profile_decoration_surface_accepted",
				kind = .U64,
				offset = offset_of(TerrainGenerationRegisteredResult, profile) +
				offset_of(TerrainGenerationProfile, decoration_surface_accepted),
				reduce = .Last,
			},
			{
				name = "profile_decoration_cave_candidates",
				kind = .U64,
				offset = offset_of(TerrainGenerationRegisteredResult, profile) +
				offset_of(TerrainGenerationProfile, decoration_cave_candidates),
				reduce = .Last,
			},
			{
				name = "profile_decoration_cave_accepted",
				kind = .U64,
				offset = offset_of(TerrainGenerationRegisteredResult, profile) +
				offset_of(TerrainGenerationProfile, decoration_cave_accepted),
				reduce = .Last,
			},
			{
				name = "profile_decoration_blocks_written",
				kind = .U64,
				offset = offset_of(TerrainGenerationRegisteredResult, profile) +
				offset_of(TerrainGenerationProfile, decoration_blocks_written),
				reduce = .Last,
			},
		}

		terrain_generation_registered_phase_name :: proc(
			phase: TerrainGenerationBenchmarkPhaseKind,
		) -> string {
			switch phase {
			case .Cave_Hot_Region_Cache:
				return "cave_hot_region_cache"
			case .Cave_Warm_Region_Column_Cache:
				return "cave_warm_region_column_cache"
			case .Cave_Proxy_Anchors:
				return "cave_proxy_anchors"
			case .Surface_Water_Hot_Region_Cache:
				return "surface_water_hot_region_cache"
			case .Surface_Cave_Hot_Region_Cache:
				return "surface_cave_hot_region_cache"
			case .Surface_Feature_Hot_Region_Cache:
				return "surface_feature_hot_region_cache"
			case .Surface_Fortress_Hot_Region_Cache:
				return "surface_fortress_hot_region_cache"
			case .Cave_Reset_Region_Cache:
				return "cave_reset_region_cache"
			case .Surface_Water_Reset_Region_Cache:
				return "surface_water_reset_region_cache"
			case .Surface_Cave_Reset_Region_Cache:
				return "surface_cave_reset_region_cache"
			case .Surface_Feature_Reset_Region_Cache:
				return "surface_feature_reset_region_cache"
			case .Surface_Fortress_Reset_Region_Cache:
				return "surface_fortress_reset_region_cache"
			}
			return "unknown"
		}

		terrain_generation_registered_coords_for_phase :: proc(
			phase: TerrainGenerationBenchmarkPhaseKind,
			key: biomes.FeatureGridKey,
		) -> TerrainGenerationBenchmarkCoords {
			cave_field_path_selection := terrain_generation_benchmark_cave_field_path_selection(
				key,
			)
			cave_coords := terrain_generation_benchmark_cave_coords_make(
				key,
				cave_field_path_selection,
			)
			switch phase {
			case .Cave_Hot_Region_Cache,
			     .Cave_Warm_Region_Column_Cache,
			     .Cave_Proxy_Anchors,
			     .Cave_Reset_Region_Cache:
				return cave_coords
			case .Surface_Water_Hot_Region_Cache, .Surface_Water_Reset_Region_Cache:
				return terrain_generation_benchmark_surface_water_coords_make(key)
			case .Surface_Cave_Hot_Region_Cache, .Surface_Cave_Reset_Region_Cache:
				anchors := terrain_generation_benchmark_surface_cave_anchors_pick(key)
				return terrain_generation_benchmark_surface_cave_coords_make(anchors)
			case .Surface_Feature_Hot_Region_Cache, .Surface_Feature_Reset_Region_Cache:
				selection := terrain_generation_benchmark_surface_morphology_feature_selection(key)
				return terrain_generation_benchmark_surface_morphology_feature_coords_make(
					selection,
				)
			case .Surface_Fortress_Hot_Region_Cache, .Surface_Fortress_Reset_Region_Cache:
				selection := terrain_generation_benchmark_surface_fortress_selection(key)
				return terrain_generation_benchmark_surface_fortress_coords_make(selection)
			}
			return cave_coords
		}

		terrain_generation_registered_fixture_init :: proc(
			fixture: ^TerrainGenerationRegisteredFixture,
			allocator: mem.Allocator,
		) {
			if !fixture.initialized {
				chunk_voxel_view_alloc(&fixture.view, allocator)
				fixture.initialized = true
			}
			terrain_generation_chunk_cache_init(allocator)
			terrain_generation_cave_overlay_cache_init(allocator)
			terrain_generation_chunk_cache_clear()
			terrain_generation_cave_overlay_cache_clear()
			terrain_generation_column_cache_clear()
			terrain_generation_region_cache_clear()
			terrain_water_separator_sample_cache_clear()

			fixture.seed = 0
			key := terrain_generation_key_make(fixture.seed)
			fixture.phase_name = terrain_generation_registered_phase_name(fixture.phase)
			fixture.coords = terrain_generation_registered_coords_for_phase(fixture.phase, key)
			fixture.quality = .Full
			fixture.reset_cache_each_iteration = false
			fixture.clear_chunk_cache_each_iteration = false
			fixture.cache_mode = "hot_region_cache"
			fixture.cache_ownership_mode = "global_serial"

			#partial switch fixture.phase {
			case .Cave_Warm_Region_Column_Cache:
				fixture.clear_chunk_cache_each_iteration = true
				fixture.cache_mode = "warm_region_column_cache"
			case .Cave_Proxy_Anchors:
				fixture.clear_chunk_cache_each_iteration = true
				fixture.quality = .Proxy
				fixture.cache_mode = "warm_region_column_cache"
			case .Cave_Reset_Region_Cache,
			     .Surface_Water_Reset_Region_Cache,
			     .Surface_Cave_Reset_Region_Cache,
			     .Surface_Feature_Reset_Region_Cache,
			     .Surface_Fortress_Reset_Region_Cache:
				fixture.reset_cache_each_iteration = true
				fixture.cache_mode = "reset_region_cache"
			}
		}

		terrain_generation_registered_setup :: proc(
			ctx: ^bench.BenchmarkContext,
			data: rawptr,
		) -> bench.BenchmarkStatus {
			fixture := (^TerrainGenerationRegisteredFixture)(data)
			terrain_generation_registered_fixture_init(fixture, ctx.allocator)
			return bench.status_pass()
		}

		terrain_generation_registered_precondition :: proc(
			ctx: ^bench.BenchmarkContext,
			data: rawptr,
		) -> bench.BenchmarkStatus {
			fixture := (^TerrainGenerationRegisteredFixture)(data)
			terrain_generation_benchmark_cache_clear()
			for coord in fixture.coords {
				terrain_heightfield_voxel_view_fill_quality(
					&fixture.view,
					coord,
					fixture.seed,
					fixture.quality,
				)
			}
			_ = ctx
			return bench.status_pass()
		}

		terrain_generation_registered_run :: proc(
			ctx: ^bench.BenchmarkContext,
			data: rawptr,
			result: rawptr,
		) -> bench.BenchmarkStatus {
			fixture := (^TerrainGenerationRegisteredFixture)(data)
			out := (^TerrainGenerationRegisteredResult)(result)
			previous_profile_context := terrain_generation_profile_context_begin(&out.profile)
			defer terrain_generation_profile_context_end(previous_profile_context)
			if fixture.reset_cache_each_iteration {
				terrain_generation_benchmark_cache_clear()
			} else if fixture.clear_chunk_cache_each_iteration {
				terrain_generation_chunk_cache_clear()
			}
			for coord in fixture.coords {
				terrain_heightfield_voxel_view_fill_quality(
					&fixture.view,
					coord,
					fixture.seed,
					fixture.quality,
				)
				out.chunk_iterations += 1
			}
			_ = ctx
			return bench.status_pass()
		}

		terrain_generation_registered_finalize :: proc(
			ctx: ^bench.BenchmarkContext,
			data: rawptr,
			result: rawptr,
		) -> bench.BenchmarkStatus {
			fixture := (^TerrainGenerationRegisteredFixture)(data)
			out := (^TerrainGenerationRegisteredResult)(result)
			checksum, material_stats := terrain_generation_benchmark_checksum_coords(
				&fixture.view,
				fixture.coords,
				fixture.seed,
				fixture.quality,
			)
			out.checksum = checksum
			out.empty_count = material_stats.empty_count
			out.solid_count = material_stats.solid_count
			out.water_count = material_stats.water_count
			out.grass_count = material_stats.material_counts[TERRAIN_GRASS_MAT_ID]
			out.dirt_count = material_stats.material_counts[TERRAIN_DIRT_MAT_ID]
			out.stone_count = material_stats.material_counts[TERRAIN_STONE_MAT_ID]
			out.wet_count = material_stats.material_counts[TERRAIN_WET_MARSH_MAT_ID]
			out.ash_count = material_stats.material_counts[TERRAIN_CORRUPTED_ASH_MAT_ID]
			out.aquifer_wall_count = material_stats.material_counts[TERRAIN_AQUIFER_WALL_MAT_ID]
			out.crystal_count = material_stats.material_counts[TERRAIN_CRYSTAL_MAT_ID]
			out.hydrology_debug_blocks = material_stats.hydrology_debug_blocks
			out.cave_debug_blocks = material_stats.cave_debug_blocks
			out.decoration_debug_blocks = material_stats.decoration_debug_blocks
			_ = ctx
			return bench.status_pass()
		}

		terrain_generation_registered_fixture_write :: proc(
			ctx: ^bench.BenchmarkContext,
			data: rawptr,
			writer: ^bench.BenchmarkMetadataWriter,
		) -> bench.BenchmarkStatus {
			fixture := (^TerrainGenerationRegisteredFixture)(data)
			bench.metadata_string(writer, "fixture_name", fixture.phase_name)
			bench.metadata_u64(writer, "seed", u64(fixture.seed))
			bench.metadata_string(writer, "quality", fmt.aprintf("%v", fixture.quality))
			bench.metadata_string(writer, "cache_mode", fixture.cache_mode)
			bench.metadata_string(writer, "cache_ownership_mode", fixture.cache_ownership_mode)
			bench.metadata_bool(
				writer,
				"reset_cache_each_iteration",
				fixture.reset_cache_each_iteration,
			)
			bench.metadata_bool(
				writer,
				"clear_chunk_cache_each_iteration",
				fixture.clear_chunk_cache_each_iteration,
			)
			for i := 0; i < len(fixture.coords); i += 1 {
				coord := fixture.coords[i]
				bench.metadata_string(
					writer,
					fmt.aprintf("coord_%d", i),
					fmt.aprintf("(%d,%d,%d)", coord.x, coord.y, coord.z),
				)
			}
			_ = ctx
			return bench.status_pass()
		}

		terrain_generation_registered_case_register :: proc(
			registry: ^bench.BenchmarkRegistry,
			name: string,
			phase: TerrainGenerationBenchmarkPhaseKind,
		) {
			fixture := TerrainGenerationRegisteredFixture {
				phase      = phase,
				phase_name = terrain_generation_registered_phase_name(phase),
			}
			bench.register(
				registry,
				name,
				terrain_generation_registered_run,
				rawptr(&fixture),
				nil,
				{
					iterations = 1,
					warmup_iterations = 0,
					workers = 1,
					result_size = size_of(TerrainGenerationRegisteredResult),
					result_align = align_of(TerrainGenerationRegisteredResult),
					data_size = size_of(TerrainGenerationRegisteredFixture),
					data_align = align_of(TerrainGenerationRegisteredFixture),
					metrics = terrain_generation_registered_metrics[:],
					flags = {.Serial_Only, .Uses_Shared_Caches},
					warmup_mode = .None,
					setup = terrain_generation_registered_setup,
					precondition = terrain_generation_registered_precondition,
					finalize = terrain_generation_registered_finalize,
					write_fixture = terrain_generation_registered_fixture_write,
					category = "world.terrain_generation",
					version = TERRAIN_GENERATION_BENCHMARK_VERSION,
				},
			)
		}

		TerrainComponentBenchmarkKind :: enum {
			Water_Volume_Fill,
			Surface_Morphology_Columns,
			Surface_Morphology_Columns_Shared_Cache_Contention,
			Meshing_Generated_Chunk_Build,
			Density_Math_Core,
			Decoration_Pass,
			Cave_Materials_Wall_Neighbors,
		}

		TerrainComponentBenchmarkFixture :: struct {
			kind:         TerrainComponentBenchmarkKind,
			fixture_name: string,
			seed:         u32,
			key:          biomes.FeatureGridKey,
			coords:       TerrainGenerationBenchmarkCoords,
			coord:        world_async.ChunkCoord,
			origin:       world_async.BlockCoord,
			region:       ^biomes.GenerationRegion,
			columns:      ^[CHUNK_BLOCK_LENGTH * CHUNK_BLOCK_LENGTH]TerrainBiomeColumn,
			base_view:    world_async.ChunkVoxelView,
			work_view:    world_async.ChunkVoxelView,
			initialized:  bool,
		}

		@(thread_local)
		terrain_component_benchmark_worker_view: world_async.ChunkVoxelView

		TerrainComponentBenchmarkResult :: struct {
			operation_count:                  u64,
			column_count:                     u64,
			sample_count:                     u64,
			block_count:                      u64,
			face_count:                       u64,
			output_bytes:                     u64,
			surface_candidates:               u64,
			surface_accepted:                 u64,
			surface_tree_instances_attempted: u64,
			surface_tree_instances_accepted:  u64,
			surface_tree_root_rejected:       u64,
			surface_tree_shape_rejected:      u64,
			cave_candidates:                  u64,
			cave_accepted:                    u64,
			blocks_written:                   u64,
			checksum:                         u64,
		}

		terrain_component_benchmark_metrics := [?]bench.BenchmarkMetricDescriptor {
			{
				name = "operation_count",
				kind = .U64,
				offset = offset_of(TerrainComponentBenchmarkResult, operation_count),
				reduce = .Sum,
				description = "Domain operation count for the component workload",
			},
			{
				name = "column_count",
				kind = .U64,
				offset = offset_of(TerrainComponentBenchmarkResult, column_count),
				reduce = .Sum,
				unit = "columns",
			},
			{
				name = "sample_count",
				kind = .U64,
				offset = offset_of(TerrainComponentBenchmarkResult, sample_count),
				reduce = .Sum,
				unit = "samples",
			},
			{
				name = "block_count",
				kind = .U64,
				offset = offset_of(TerrainComponentBenchmarkResult, block_count),
				reduce = .Last,
				unit = "blocks",
			},
			{
				name = "faces",
				kind = .U64,
				offset = offset_of(TerrainComponentBenchmarkResult, face_count),
				reduce = .Last,
				unit = "faces",
			},
			{
				name = "output_bytes",
				kind = .U64,
				offset = offset_of(TerrainComponentBenchmarkResult, output_bytes),
				reduce = .Last,
				unit = "bytes",
			},
			{
				name = "surface_candidates",
				kind = .U64,
				offset = offset_of(TerrainComponentBenchmarkResult, surface_candidates),
				reduce = .Sum,
			},
			{
				name = "surface_accepted",
				kind = .U64,
				offset = offset_of(TerrainComponentBenchmarkResult, surface_accepted),
				reduce = .Sum,
			},
			{
				name = "surface_tree_instances_attempted",
				kind = .U64,
				offset = offset_of(
					TerrainComponentBenchmarkResult,
					surface_tree_instances_attempted,
				),
				reduce = .Sum,
			},
			{
				name = "surface_tree_instances_accepted",
				kind = .U64,
				offset = offset_of(
					TerrainComponentBenchmarkResult,
					surface_tree_instances_accepted,
				),
				reduce = .Sum,
			},
			{
				name = "surface_tree_root_rejected",
				kind = .U64,
				offset = offset_of(TerrainComponentBenchmarkResult, surface_tree_root_rejected),
				reduce = .Sum,
			},
			{
				name = "surface_tree_shape_rejected",
				kind = .U64,
				offset = offset_of(TerrainComponentBenchmarkResult, surface_tree_shape_rejected),
				reduce = .Sum,
			},
			{
				name = "cave_candidates",
				kind = .U64,
				offset = offset_of(TerrainComponentBenchmarkResult, cave_candidates),
				reduce = .Sum,
			},
			{
				name = "cave_accepted",
				kind = .U64,
				offset = offset_of(TerrainComponentBenchmarkResult, cave_accepted),
				reduce = .Sum,
			},
			{
				name = "blocks_written",
				kind = .U64,
				offset = offset_of(TerrainComponentBenchmarkResult, blocks_written),
				reduce = .Sum,
				unit = "blocks",
			},
			{
				name = "checksum",
				kind = .U64,
				offset = offset_of(TerrainComponentBenchmarkResult, checksum),
				reduce = .Sum,
			},
		}

		terrain_component_benchmark_kind_name :: proc(
			kind: TerrainComponentBenchmarkKind,
		) -> string {
			switch kind {
			case .Water_Volume_Fill:
				return "water_volume_fill"
			case .Surface_Morphology_Columns:
				return "surface_morphology_columns"
			case .Surface_Morphology_Columns_Shared_Cache_Contention:
				return "surface_morphology_columns_shared_cache_contention"
			case .Meshing_Generated_Chunk_Build:
				return "meshing_generated_chunk_build"
			case .Density_Math_Core:
				return "density_math_core"
			case .Decoration_Pass:
				return "decoration_pass"
			case .Cave_Materials_Wall_Neighbors:
				return "cave_materials_wall_neighbors"
			}
			return "unknown"
		}

		terrain_component_benchmark_uses_generation_caches :: proc(
			kind: TerrainComponentBenchmarkKind,
		) -> bool {
			switch kind {
			case .Density_Math_Core, .Cave_Materials_Wall_Neighbors:
				return false
			case .Water_Volume_Fill,
			     .Surface_Morphology_Columns,
			     .Surface_Morphology_Columns_Shared_Cache_Contention,
			     .Meshing_Generated_Chunk_Build,
			     .Decoration_Pass:
				return true
			}
			return true
		}

		terrain_component_benchmark_cache_ownership_mode :: proc(
			kind: TerrainComponentBenchmarkKind,
		) -> string {
			switch kind {
			case .Water_Volume_Fill, .Meshing_Generated_Chunk_Build, .Decoration_Pass:
				return "fixture_setup_serial"
			case .Surface_Morphology_Columns:
				return "global_serial"
			case .Surface_Morphology_Columns_Shared_Cache_Contention:
				return "global_shared_contention"
			case .Density_Math_Core, .Cave_Materials_Wall_Neighbors:
				return "none"
			}
			return "unknown"
		}

		terrain_component_benchmark_mutable_view_ownership_mode :: proc(
			kind: TerrainComponentBenchmarkKind,
		) -> string {
			switch kind {
			case .Water_Volume_Fill, .Decoration_Pass:
				return "fixture_serial"
			case .Cave_Materials_Wall_Neighbors:
				return "worker_local"
			case .Surface_Morphology_Columns,
			     .Surface_Morphology_Columns_Shared_Cache_Contention,
			     .Meshing_Generated_Chunk_Build,
			     .Density_Math_Core:
				return "none"
			}
			return "unknown"
		}

		terrain_component_benchmark_resets_view_each_iteration :: proc(
			kind: TerrainComponentBenchmarkKind,
		) -> bool {
			switch kind {
			case .Water_Volume_Fill, .Decoration_Pass, .Cave_Materials_Wall_Neighbors:
				return true
			case .Surface_Morphology_Columns,
			     .Surface_Morphology_Columns_Shared_Cache_Contention,
			     .Meshing_Generated_Chunk_Build,
			     .Density_Math_Core:
				return false
			}
			return false
		}

		terrain_component_benchmark_coords_for_kind :: proc(
			kind: TerrainComponentBenchmarkKind,
			key: biomes.FeatureGridKey,
		) -> TerrainGenerationBenchmarkCoords {
			switch kind {
			case .Water_Volume_Fill:
				return terrain_generation_benchmark_surface_water_coords_make(key)
			case .Surface_Morphology_Columns,
			     .Surface_Morphology_Columns_Shared_Cache_Contention,
			     .Meshing_Generated_Chunk_Build:
				selection := terrain_generation_benchmark_surface_morphology_feature_selection(key)
				return terrain_generation_benchmark_surface_morphology_feature_coords_make(
					selection,
				)
			case .Decoration_Pass:
				selection := terrain_generation_benchmark_surface_fortress_selection(key)
				return terrain_generation_benchmark_surface_fortress_coords_make(selection)
			case .Cave_Materials_Wall_Neighbors, .Density_Math_Core:
				return terrain_generation_registered_coords_for_phase(.Cave_Hot_Region_Cache, key)
			}
			return terrain_generation_benchmark_surface_water_coords_make(key)
		}

		terrain_component_benchmark_surface_columns_prepare :: proc(
			fixture: ^TerrainComponentBenchmarkFixture,
		) {
			fixture.origin = chunk_origin_from_coord(fixture.coord)
			region_coord := biomes.generation_region_coord_from_block(
				fixture.origin.x,
				fixture.origin.y,
				fixture.origin.z,
			)
			fixture.region^ = terrain_generation_region_for_fill(fixture.key, region_coord)
			water_separator_samples: [CHUNK_BLOCK_LENGTH *
			CHUNK_BLOCK_LENGTH]TerrainWaterSeparatorSample
			for z in 0 ..< CHUNK_BLOCK_LENGTH {
				world_z := fixture.origin.z + i32(z)
				profile_row_cache := biomes.surface_biome_profile_row_cache_make(
					fixture.key,
					world_z,
				)
				for x in 0 ..< CHUNK_BLOCK_LENGTH {
					world_x := fixture.origin.x + i32(x)
					surface_sample := biomes.surface_biome_field_sample_from_region(
						fixture.region,
						world_x,
						world_z,
					)
					hydrology_sample := biomes.hydrology_layer_surface_sample_from_region(
						fixture.region,
						world_x,
						world_z,
					)
					evaluation := biomes.surface_biome_profile_evaluate_with_hydrology(
						fixture.key,
						surface_sample,
						hydrology_sample,
						world_x,
						world_z,
						&profile_row_cache,
					)
					evaluation = terrain_surface_morphology_apply_feature_envelopes(
						evaluation,
						fixture.region.surface_morphology_features[:],
						fixture.region.surface_morphology_feature_count,
						world_x,
						world_z,
					)
					column_index := x + z * CHUNK_BLOCK_LENGTH
					column := terrain_biome_column_from_profile_evaluation(
						fixture.key,
						evaluation,
						world_x,
						world_z,
					)
					fixture.columns^[column_index] = column
					water_separator_samples[column_index] =
						terrain_water_separator_sample_from_column_and_hydrology(
							column,
							evaluation.hydrology_sample,
						)
				}
			}
			terrain_surface_water_separators_apply(
				fixture.key,
				fixture.region,
				fixture.origin,
				fixture.columns^[:],
				water_separator_samples[:],
			)
			terrain_decoration_surface_structure_pads_apply(
				fixture.region,
				fixture.origin,
				fixture.columns^[:],
			)
		}

		terrain_component_benchmark_view_fill_solid :: proc(view: ^world_async.ChunkVoxelView) {
			mem.set(
				rawptr(view.blocks.occupancy),
				u8(world_async.BlockOccupancy.Solid),
				CHUNK_BLOCK_COUNT,
			)
			mem.set(
				rawptr(view.blocks.material_id),
				u8(world_async.BlockMaterialID(TERRAIN_STONE_MAT_ID)),
				CHUNK_BLOCK_COUNT,
			)
		}

		terrain_component_benchmark_active_water_columns_count :: proc(
			fixture: ^TerrainComponentBenchmarkFixture,
		) -> u64 {
			active_columns := u64(0)
			for column in fixture.columns^ {
				if column.water_fill_active {
					active_columns += 1
				}
			}
			return active_columns
		}

		terrain_component_benchmark_fixture_init :: proc(
			fixture: ^TerrainComponentBenchmarkFixture,
			allocator: mem.Allocator,
		) {
			if fixture.initialized {
				return
			}

			fixture.seed = 0
			fixture.key = terrain_generation_key_make(fixture.seed)
			fixture.fixture_name = terrain_component_benchmark_kind_name(fixture.kind)
			fixture.coords = terrain_component_benchmark_coords_for_kind(fixture.kind, fixture.key)
			fixture.coord = fixture.coords[0]

			if terrain_component_benchmark_uses_generation_caches(fixture.kind) {
				terrain_generation_chunk_cache_init(allocator)
				terrain_generation_cave_overlay_cache_init(allocator)
				terrain_generation_benchmark_cache_clear()
			}

			if fixture.kind != .Density_Math_Core &&
			   fixture.kind != .Cave_Materials_Wall_Neighbors {
				fixture.region = new(biomes.GenerationRegion, allocator)
				fixture.columns = new(
					[CHUNK_BLOCK_LENGTH * CHUNK_BLOCK_LENGTH]TerrainBiomeColumn,
					allocator,
				)
			}

			if fixture.kind != .Surface_Morphology_Columns &&
			   fixture.kind != .Surface_Morphology_Columns_Shared_Cache_Contention &&
			   fixture.kind != .Density_Math_Core {
				chunk_voxel_view_alloc(&fixture.base_view, allocator)
				chunk_voxel_view_alloc(&fixture.work_view, allocator)
			}

			switch fixture.kind {
			case .Water_Volume_Fill:
				for coord in fixture.coords {
					fixture.coord = coord
					terrain_component_benchmark_surface_columns_prepare(fixture)
					if terrain_component_benchmark_active_water_columns_count(fixture) > 0 {
						break
					}
				}
				chunk_voxel_view_fill_empty(&fixture.base_view)
			case .Surface_Morphology_Columns, .Surface_Morphology_Columns_Shared_Cache_Contention:
				for coord in fixture.coords {
					origin := chunk_origin_from_coord(coord)
					region_coord := biomes.generation_region_coord_from_block(
						origin.x,
						origin.y,
						origin.z,
					)
					_ = terrain_generation_region_for_fill(fixture.key, region_coord)
				}
			case .Meshing_Generated_Chunk_Build, .Decoration_Pass:
				terrain_component_benchmark_surface_columns_prepare(fixture)
				terrain_heightfield_voxel_view_fill_quality(
					&fixture.base_view,
					fixture.coord,
					fixture.seed,
					.Full,
				)
			case .Cave_Materials_Wall_Neighbors:
				fixture.origin = chunk_origin_from_coord(fixture.coord)
				terrain_component_benchmark_view_fill_solid(&fixture.base_view)
			case .Density_Math_Core:
				fixture.origin = {
					x = -64,
					y = -32,
					z = 96,
				}
			}
			if len(fixture.work_view.blocks) == CHUNK_BLOCK_COUNT &&
			   len(fixture.base_view.blocks) == CHUNK_BLOCK_COUNT {
				chunk_voxel_view_copy(&fixture.work_view, &fixture.base_view)
			}
			fixture.initialized = true
		}

		terrain_component_benchmark_setup :: proc(
			ctx: ^bench.BenchmarkContext,
			data: rawptr,
		) -> bench.BenchmarkStatus {
			fixture := (^TerrainComponentBenchmarkFixture)(data)
			terrain_component_benchmark_fixture_init(fixture, ctx.allocator)
			return bench.status_pass()
		}

		terrain_component_benchmark_setup_worker :: proc(
			ctx: ^bench.BenchmarkContext,
			data: rawptr,
		) -> bench.BenchmarkStatus {
			fixture := (^TerrainComponentBenchmarkFixture)(data)
			if fixture.kind != .Cave_Materials_Wall_Neighbors {
				return bench.status_pass()
			}
			if len(terrain_component_benchmark_worker_view.blocks) == CHUNK_BLOCK_COUNT {
				return bench.status_pass()
			}
			terrain_component_benchmark_worker_view.blocks = make(
				#soa[]world_async.ChunkVoxelViewElement,
				CHUNK_BLOCK_COUNT,
				ctx.allocator,
			)
			if len(terrain_component_benchmark_worker_view.blocks) != CHUNK_BLOCK_COUNT {
				return bench.status_fail("terrain component worker view allocation failed")
			}
			return bench.status_pass()
		}

		terrain_component_benchmark_teardown_worker :: proc(
			ctx: ^bench.BenchmarkContext,
			data: rawptr,
		) -> bench.BenchmarkStatus {
			fixture := (^TerrainComponentBenchmarkFixture)(data)
			if fixture.kind != .Cave_Materials_Wall_Neighbors {
				return bench.status_pass()
			}
			if len(terrain_component_benchmark_worker_view.blocks) == 0 {
				return bench.status_pass()
			}
			_ = delete(terrain_component_benchmark_worker_view.blocks, ctx.allocator)
			terrain_component_benchmark_worker_view = {}
			return bench.status_pass()
		}

		terrain_component_benchmark_abs_scaled_u64 :: proc(value: f32) -> u64 {
			scaled_value := value
			if scaled_value < 0 {
				scaled_value = -scaled_value
			}
			return u64(scaled_value * 1000)
		}

		terrain_component_benchmark_density_math_core_run :: proc(
			fixture: ^TerrainComponentBenchmarkFixture,
			out: ^TerrainComponentBenchmarkResult,
			iteration_index: u64,
		) {
			origin := fixture.origin
			key := fixture.key
			checksum := u64(iteration_index + 1)
			operation_count := u64(0)
			sample_count := u64(0)

			for row := i32(0); row < 64; row += 1 {
				world_y := f32(origin.y + (row & 31)) + 0.5
				world_z := f32(origin.z + ((row * 7) & 31)) + 0.5
				from_x := f32(origin.x - 19) + f32(row & 7) * 0.5
				from_y := f32(origin.y - 7)
				from_z := f32(origin.z + 9)
				to_x := f32(origin.x + 77)
				to_y := f32(origin.y + 52)
				to_z := f32(origin.z + 37)
				nearest_x, nearest_y, nearest_z, distance :=
					terrain_density_closest_segment_point_3(
						f32(origin.x + row),
						world_y,
						world_z,
						from_x,
						from_y,
						from_z,
						to_x,
						to_y,
						to_z,
					)
				checksum =
					checksum * 1099511628211 ~
					terrain_component_benchmark_abs_scaled_u64(
						nearest_x + nearest_y + nearest_z + distance,
					)
				operation_count += 1

				t_min, t_max, segment_intersects := terrain_density_segment_chunk_overlap(
					origin,
					from_x,
					from_y,
					from_z,
					to_x,
					to_y,
					to_z,
					12.0,
				)
				if segment_intersects {
					checksum =
						checksum * 1099511628211 ~
						terrain_component_benchmark_abs_scaled_u64(t_min + t_max)
				}
				operation_count += 1

				row_min_x, row_max_x, row_intersects := terrain_density_ellipsoid_row_x_bounds(
					origin,
					0,
					CHUNK_BLOCK_LENGTH - 1,
					f32(origin.x + 16),
					22.0,
					f32((row & 15) - 8) * f32((row & 15) - 8) / 80.0,
					1.0,
				)
				if row_intersects {
					checksum =
						checksum * 1099511628211 ~ u64(row_min_x + row_max_x + CHUNK_BLOCK_LENGTH)
				}
				operation_count += 1

				row_min_x, row_max_x, row_intersects =
					terrain_density_segment_capsule_row_x_bounds(
						origin,
						0,
						CHUNK_BLOCK_LENGTH - 1,
						world_y,
						world_z,
						from_x,
						from_y,
						from_z,
						0.72,
						0.43,
						0.54,
						8.5,
					)
				if row_intersects {
					checksum =
						checksum * 1099511628211 ~
						u64(row_min_x * 17 + row_max_x + CHUNK_BLOCK_LENGTH)
				}
				operation_count += 1

				row_min_x, row_max_x, row_intersects =
					terrain_density_dual_axis_ellipse_row_x_bounds(
						origin,
						0,
						CHUNK_BLOCK_LENGTH - 1,
						world_y,
						world_z,
						f32(origin.x + 10),
						f32(origin.y + 6),
						f32(origin.z + 12),
						0.86,
						0.16,
						0.48,
						-0.32,
						0.88,
						0.34,
						18.0,
						7.0,
						1.0,
					)
				if row_intersects {
					checksum =
						checksum * 1099511628211 ~
						u64(row_min_x * 31 + row_max_x + CHUNK_BLOCK_LENGTH)
				}
				operation_count += 1

				ranges: [8]TerrainDensityRowRange
				range_count := u32(0)
				terrain_density_row_range_add_merged(&ranges, &range_count, row & 15, 24)
				terrain_density_row_range_add_merged(&ranges, &range_count, 12, 31)
				terrain_density_route_pocket_row_range_add_component(
					&ranges,
					&range_count,
					0,
					CHUNK_BLOCK_LENGTH - 1,
					-8.0 + f32(row & 7),
					0.7,
					f32(row & 11),
					3.5,
					-0.35,
					0.4,
					0.0,
					8.0,
					11.0,
					6.0,
					1.0,
					1.0,
				)
				checksum = checksum * 1099511628211 ~ u64(range_count + 1)
				operation_count += 3

				noise_cache := terrain_value_noise3_row_cache_make(
					key,
					0x6e9174d5a2c34811,
					16,
					origin.y + row,
					origin.z + row * 3,
				)
				for x := i32(0); x < CHUNK_BLOCK_LENGTH; x += 1 {
					value := terrain_value_noise3_row_cache_sample(&noise_cache, origin.x + x)
					checksum =
						checksum * 1099511628211 ~
						terrain_component_benchmark_abs_scaled_u64(value)
					sample_count += 1
				}
				operation_count += u64(CHUNK_BLOCK_LENGTH)
			}

			out.operation_count += operation_count
			out.sample_count += sample_count
			out.checksum += checksum
		}

		terrain_component_benchmark_cave_materials_run :: proc(
			fixture: ^TerrainComponentBenchmarkFixture,
			work_view: ^world_async.ChunkVoxelView,
			out: ^TerrainComponentBenchmarkResult,
			iteration_index: u64,
		) {
			chunk_voxel_view_copy(work_view, &fixture.base_view)
			biome_ids := [?]biomes.BiomeID {
				.Fungal_Vaults,
				.Crystal_Geode_Network,
				.Buried_Aquifer_Caves,
			}
			operation_count := u64(0)
			wall_neighbor_calls := u64(0)
			checksum := u64(iteration_index + 1)
			for z := i32(2); z < CHUNK_BLOCK_LENGTH - 2; z += 5 {
				for y := i32(2); y < CHUNK_BLOCK_LENGTH - 2; y += 5 {
					for x := i32(2); x < CHUNK_BLOCK_LENGTH - 2; x += 5 {
						center_index := chunk_block_index(u32(x), u32(y), u32(z))
						work_view.blocks.occupancy[center_index] = .Empty
						biome_index := int(
							(iteration_index + wall_neighbor_calls) % u64(len(biome_ids)),
						)
						biome_id := biome_ids[biome_index]
						wall_material_id, floor_material_id, ceiling_material_id :=
							terrain_cave_material_profile(biome_id)
						checksum = checksum * 1099511628211 ~ u64(wall_material_id)
						checksum = checksum * 1099511628211 ~ u64(floor_material_id)
						checksum = checksum * 1099511628211 ~ u64(ceiling_material_id)
						terrain_density_mark_cave_wall_neighbors(
							work_view,
							x,
							y,
							z,
							biome_id,
							true,
						)
						checksum =
							checksum * 1099511628211 ~
							u64(work_view.blocks.material_id[center_index + 1])
						operation_count += 1
						wall_neighbor_calls += 1
					}
				}
			}
			face_materials := [?]u32 {
				TERRAIN_STONE_MAT_ID,
				TERRAIN_AQUIFER_WALL_MAT_ID,
				TERRAIN_CRYSTAL_MAT_ID,
			}
			for normal_id := u32(0); normal_id < 6; normal_id += 1 {
				for material_id in face_materials {
					face_material := terrain_binary_cave_face_material_index(
						normal_id,
						material_id,
					)
					checksum = checksum * 1099511628211 ~ u64(face_material + normal_id)
					operation_count += 1
				}
			}
			out.operation_count += operation_count
			out.block_count = u64(CHUNK_BLOCK_COUNT) - wall_neighbor_calls
			out.blocks_written += wall_neighbor_calls * 6
			out.checksum += checksum
		}

		terrain_component_benchmark_run :: proc(
			ctx: ^bench.BenchmarkContext,
			data: rawptr,
			result: rawptr,
		) -> bench.BenchmarkStatus {
			fixture := (^TerrainComponentBenchmarkFixture)(data)
			out := (^TerrainComponentBenchmarkResult)(result)

			switch fixture.kind {
			case .Water_Volume_Fill:
				chunk_voxel_view_copy(&fixture.work_view, &fixture.base_view)
				active_columns := terrain_component_benchmark_active_water_columns_count(fixture)
				terrain_water_volume_fill(&fixture.work_view, fixture.origin, fixture.columns^[:])
				out.operation_count += u64(CHUNK_BLOCK_LENGTH * CHUNK_BLOCK_LENGTH)
				out.column_count += active_columns
			case .Surface_Morphology_Columns, .Surface_Morphology_Columns_Shared_Cache_Contention:
				stats := terrain_generation_benchmark_surface_morphology_stats_from_coords(
					fixture.coords,
					fixture.seed,
				)
				out.operation_count += stats.sample_count
				out.column_count += stats.active_column_count
				out.sample_count += stats.sample_count
				out.block_count = stats.morphology_solid_count
				out.blocks_written += stats.added_solid_count + stats.removed_solid_count
				out.checksum +=
					stats.base_solid_count * 131 +
					stats.morphology_solid_count * 197 +
					stats.feature_column_count * 17 +
					u64(ctx.iteration_index + 1)
			case .Meshing_Generated_Chunk_Build:
				if ctx.temp_arena == nil {
					return bench.status_fail("terrain component meshing requires a temp arena")
				}
				temp := mem.begin_arena_temp_memory(ctx.temp_arena)
				defer mem.end_arena_temp_memory(temp)
				allocator := mem.arena_allocator(ctx.temp_arena)
				scratch := terrain_binary_greedy_scratch_alloc(ctx.temp_arena)
				mesh_output := chunk_mesher_benchmark_build_once(
					fixture.base_view,
					.Greedy_Binary,
					allocator,
					scratch,
				)
				out.face_count = u64(mesh_output.face_count)
				out.output_bytes =
					u64(len(mesh_output.vertices) * size_of(world_async.TerrainPackedVertex)) +
					u64(len(mesh_output.indices) * size_of(u32))
				out.checksum +=
					out.face_count * 131 + out.output_bytes * 17 + u64(ctx.iteration_index + 1)
			case .Density_Math_Core:
				terrain_component_benchmark_density_math_core_run(
					fixture,
					out,
					ctx.iteration_index,
				)
			case .Decoration_Pass:
				chunk_voxel_view_copy(&fixture.work_view, &fixture.base_view)
				stats := terrain_decoration_pass_apply(
					&fixture.work_view,
					fixture.region,
					fixture.origin,
					fixture.columns^[:],
				)
				out.operation_count += u64(stats.surface_candidates + stats.cave_candidates)
				out.surface_candidates += u64(stats.surface_candidates)
				out.surface_accepted += u64(stats.surface_accepted)
				out.surface_tree_instances_attempted += u64(stats.surface_tree_instances_attempted)
				out.surface_tree_instances_accepted += u64(stats.surface_tree_instances_accepted)
				out.surface_tree_root_rejected += u64(stats.surface_tree_root_rejected)
				out.surface_tree_shape_rejected += u64(stats.surface_tree_shape_rejected)
				out.cave_candidates += u64(stats.cave_candidates)
				out.cave_accepted += u64(stats.cave_accepted)
				out.blocks_written += u64(stats.blocks_written)
				out.checksum +=
					u64(stats.surface_candidates) * 131 +
					u64(stats.surface_accepted) * 197 +
					u64(stats.cave_candidates) * 251 +
					u64(stats.blocks_written) * 17 +
					u64(ctx.iteration_index + 1)
			case .Cave_Materials_Wall_Neighbors:
				if len(terrain_component_benchmark_worker_view.blocks) == CHUNK_BLOCK_COUNT {
					terrain_component_benchmark_cave_materials_run(
						fixture,
						&terrain_component_benchmark_worker_view,
						out,
						ctx.iteration_index,
					)
				} else {
					if ctx.temp_arena == nil {
						return bench.status_fail(
							"terrain component cave materials requires a temp arena",
						)
					}
					temp := mem.begin_arena_temp_memory(ctx.temp_arena)
					defer mem.end_arena_temp_memory(temp)
					allocator := mem.arena_allocator(ctx.temp_arena)
					work_view := world_async.ChunkVoxelView {
						blocks = make(
							#soa[]world_async.ChunkVoxelViewElement,
							CHUNK_BLOCK_COUNT,
							allocator,
						),
					}
					if len(work_view.blocks) != CHUNK_BLOCK_COUNT {
						return bench.status_fail(
							"terrain component cave materials temp view allocation failed",
						)
					}
					terrain_component_benchmark_cave_materials_run(
						fixture,
						&work_view,
						out,
						ctx.iteration_index,
					)
				}
			}

			return bench.status_pass()
		}

		terrain_component_benchmark_finalize :: proc(
			ctx: ^bench.BenchmarkContext,
			data: rawptr,
			result: rawptr,
		) -> bench.BenchmarkStatus {
			fixture := (^TerrainComponentBenchmarkFixture)(data)
			out := (^TerrainComponentBenchmarkResult)(result)
			switch fixture.kind {
			case .Water_Volume_Fill, .Decoration_Pass:
				if len(fixture.work_view.blocks) == CHUNK_BLOCK_COUNT {
					view_checksum, material_stats := terrain_generation_benchmark_checksum(
						fixture.work_view,
					)
					out.checksum = out.checksum * 1099511628211 ~ view_checksum
					#partial switch fixture.kind {
					case .Water_Volume_Fill:
						out.block_count = material_stats.water_count
					case .Decoration_Pass:
						out.block_count = material_stats.solid_count
					}
				}
			case .Meshing_Generated_Chunk_Build,
			     .Surface_Morphology_Columns,
			     .Surface_Morphology_Columns_Shared_Cache_Contention,
			     .Density_Math_Core,
			     .Cave_Materials_Wall_Neighbors:
			}
			_ = ctx
			return bench.status_pass()
		}

		terrain_component_benchmark_fixture_write :: proc(
			ctx: ^bench.BenchmarkContext,
			data: rawptr,
			writer: ^bench.BenchmarkMetadataWriter,
		) -> bench.BenchmarkStatus {
			fixture := (^TerrainComponentBenchmarkFixture)(data)
			bench.metadata_string(writer, "fixture_name", fixture.fixture_name)
			bench.metadata_string(
				writer,
				"component",
				terrain_component_benchmark_kind_name(fixture.kind),
			)
			bench.metadata_u64(writer, "seed", u64(fixture.seed))
			bench.metadata_string(
				writer,
				"coord",
				fmt.aprintf(
					"(%d,%d,%d)",
					fixture.coord.x,
					fixture.coord.y,
					fixture.coord.z,
					allocator = writer.allocator,
				),
			)
			bench.metadata_u64(
				writer,
				"chunk_columns",
				u64(CHUNK_BLOCK_LENGTH * CHUNK_BLOCK_LENGTH),
				"columns",
			)
			bench.metadata_u64(writer, "chunk_blocks", u64(CHUNK_BLOCK_COUNT), "blocks")
			bench.metadata_bool(
				writer,
				"reset_view_each_iteration",
				terrain_component_benchmark_resets_view_each_iteration(fixture.kind),
			)
			bench.metadata_string(
				writer,
				"cache_ownership_mode",
				terrain_component_benchmark_cache_ownership_mode(fixture.kind),
			)
			bench.metadata_string(
				writer,
				"mutable_view_ownership_mode",
				terrain_component_benchmark_mutable_view_ownership_mode(fixture.kind),
			)
			_ = ctx
			return bench.status_pass()
		}

		terrain_component_benchmark_case_flags :: proc(
			kind: TerrainComponentBenchmarkKind,
		) -> bench.BenchmarkCaseFlags {
			switch kind {
			case .Surface_Morphology_Columns:
				return {.Serial_Only, .Uses_Shared_Caches}
			case .Surface_Morphology_Columns_Shared_Cache_Contention:
				return {.Parallel_Safe, .Uses_Shared_Caches, .Measures_Cache_Contention}
			case .Water_Volume_Fill, .Decoration_Pass:
				return {.Serial_Only, .Uses_Shared_Caches}
			case .Meshing_Generated_Chunk_Build:
				return {.Parallel_Safe}
			case .Density_Math_Core:
				return {.Parallel_Safe}
			case .Cave_Materials_Wall_Neighbors:
				return {.Parallel_Safe}
			}
			return {.Serial_Only}
		}

		terrain_component_benchmark_case_register :: proc(
			registry: ^bench.BenchmarkRegistry,
			name: string,
			kind: TerrainComponentBenchmarkKind,
			iterations: u32,
			warmup_iterations: u32,
		) {
			fixture := TerrainComponentBenchmarkFixture {
				kind         = kind,
				fixture_name = terrain_component_benchmark_kind_name(kind),
			}
			bench.register(
				registry,
				name,
				terrain_component_benchmark_run,
				rawptr(&fixture),
				nil,
				{
					iterations = iterations,
					warmup_iterations = warmup_iterations,
					workers = 1,
					result_size = size_of(TerrainComponentBenchmarkResult),
					result_align = align_of(TerrainComponentBenchmarkResult),
					data_size = size_of(TerrainComponentBenchmarkFixture),
					data_align = align_of(TerrainComponentBenchmarkFixture),
					metrics = terrain_component_benchmark_metrics[:],
					flags = terrain_component_benchmark_case_flags(kind),
					warmup_mode = .Serial,
					setup = terrain_component_benchmark_setup,
					setup_worker = terrain_component_benchmark_setup_worker,
					teardown_worker = terrain_component_benchmark_teardown_worker,
					finalize = terrain_component_benchmark_finalize,
					write_fixture = terrain_component_benchmark_fixture_write,
					category = "world.terrain_component",
					version = TERRAIN_COMPONENT_BENCHMARK_VERSION,
				},
			)
		}

		terrain_component_benchmarks_register :: proc(registry: ^bench.BenchmarkRegistry) {
			terrain_component_benchmark_case_register(
				registry,
				"world.terrain_component.water.volume_fill",
				.Water_Volume_Fill,
				200,
				10,
			)
			terrain_component_benchmark_case_register(
				registry,
				"world.terrain_component.surface_morphology.columns",
				.Surface_Morphology_Columns,
				1,
				0,
			)
			terrain_component_benchmark_case_register(
				registry,
				"world.terrain_component.surface_morphology.columns.shared_cache_contention",
				.Surface_Morphology_Columns_Shared_Cache_Contention,
				4,
				0,
			)
			terrain_component_benchmark_case_register(
				registry,
				"world.terrain_component.meshing.generated_chunk.build",
				.Meshing_Generated_Chunk_Build,
				500,
				10,
			)
			terrain_component_benchmark_case_register(
				registry,
				"world.terrain_component.density_math.core",
				.Density_Math_Core,
				300,
				10,
			)
			terrain_component_benchmark_case_register(
				registry,
				"world.terrain_component.decoration.pass",
				.Decoration_Pass,
				20,
				2,
			)
			terrain_component_benchmark_case_register(
				registry,
				"world.terrain_component.cave_materials.wall_neighbors",
				.Cave_Materials_Wall_Neighbors,
				200,
				10,
			)
		}

		TerrainGenerationDiagnosticKind :: enum {
			Cave_Slice,
			Surface_Morphology_Capture,
			Surface_Fortress_Capture,
		}

		TerrainGenerationDiagnosticFixture :: struct {
			kind:              TerrainGenerationDiagnosticKind,
			seed:              u32,
			cave_slice_target: int,
			step_override:     i32,
		}

		TerrainGenerationDiagnosticResult :: struct {
			artifact_count:           u64,
			setup_clear:              time.Duration,
			selection:                time.Duration,
			capture:                  time.Duration,
			text_artifact_write:      time.Duration,
			text_artifact_bytes:      u64,
			surface_center_selection: time.Duration,
			surface_peak_search:      time.Duration,
			surface_emit:             time.Duration,
			cave_slice_capture:       time.Duration,
		}

		terrain_generation_diagnostic_metrics := [?]bench.BenchmarkMetricDescriptor {
			{
				name = "artifact_count",
				kind = .U64,
				offset = offset_of(TerrainGenerationDiagnosticResult, artifact_count),
				reduce = .Last,
			},
			{
				name = "setup_clear_ns",
				kind = .I64,
				offset = offset_of(TerrainGenerationDiagnosticResult, setup_clear),
				reduce = .Last,
				unit = "ns",
			},
			{
				name = "selection_ns",
				kind = .I64,
				offset = offset_of(TerrainGenerationDiagnosticResult, selection),
				reduce = .Last,
				unit = "ns",
			},
			{
				name = "capture_ns",
				kind = .I64,
				offset = offset_of(TerrainGenerationDiagnosticResult, capture),
				reduce = .Last,
				unit = "ns",
			},
			{
				name = "text_artifact_write_ns",
				kind = .I64,
				offset = offset_of(TerrainGenerationDiagnosticResult, text_artifact_write),
				reduce = .Last,
				unit = "ns",
			},
			{
				name = "text_artifact_bytes",
				kind = .U64,
				offset = offset_of(TerrainGenerationDiagnosticResult, text_artifact_bytes),
				reduce = .Last,
				unit = "bytes",
			},
			{
				name = "surface_center_selection_ns",
				kind = .I64,
				offset = offset_of(TerrainGenerationDiagnosticResult, surface_center_selection),
				reduce = .Last,
				unit = "ns",
			},
			{
				name = "surface_peak_search_ns",
				kind = .I64,
				offset = offset_of(TerrainGenerationDiagnosticResult, surface_peak_search),
				reduce = .Last,
				unit = "ns",
			},
			{
				name = "surface_emit_ns",
				kind = .I64,
				offset = offset_of(TerrainGenerationDiagnosticResult, surface_emit),
				reduce = .Last,
				unit = "ns",
			},
			{
				name = "cave_slice_capture_ns",
				kind = .I64,
				offset = offset_of(TerrainGenerationDiagnosticResult, cave_slice_capture),
				reduce = .Last,
				unit = "ns",
			},
		}

		terrain_generation_diagnostic_kind_name :: proc(
			kind: TerrainGenerationDiagnosticKind,
		) -> string {
			switch kind {
			case .Cave_Slice:
				return "cave_slice"
			case .Surface_Morphology_Capture:
				return "surface_morphology_capture"
			case .Surface_Fortress_Capture:
				return "surface_fortress_capture"
			}
			return "unknown"
		}

		terrain_generation_diagnostic_run :: proc(
			ctx: ^bench.BenchmarkContext,
			data: rawptr,
			result: rawptr,
		) -> bench.BenchmarkStatus {
			if ctx.temp_arena == nil {
				return bench.status_fail("terrain diagnostic capture requires a temp arena")
			}
			fixture := (^TerrainGenerationDiagnosticFixture)(data)
			out := (^TerrainGenerationDiagnosticResult)(result)
			setup_clear_start := time.tick_now()
			terrain_generation_chunk_cache_init(ctx.allocator)
			terrain_generation_chunk_cache_clear()
			terrain_generation_cave_overlay_cache_init(ctx.allocator)
			terrain_generation_cave_overlay_cache_clear()
			terrain_generation_column_cache_clear()
			terrain_generation_region_cache_clear()
			terrain_water_separator_sample_cache_clear()
			out.setup_clear += time.tick_since(setup_clear_start)

			artifact_context := TerrainGenerationBenchmarkArtifactContext {
				result       = ctx.case_result,
				artifact_dir = ctx.artifact_dir,
				allocator    = ctx.allocator,
				ok           = true,
			}
			timing_context := TerrainGenerationBenchmarkDiagnosticTimingContext{}
			previous_artifact_context := terrain_generation_benchmark_artifact_context
			previous_timing_context := terrain_generation_benchmark_diagnostic_timing_context
			previous_cave_slice_target := terrain_generation_benchmark_cave_slice_selected_target
			previous_surface_step_override :=
				terrain_generation_benchmark_surface_capture_step_override
			terrain_generation_benchmark_artifact_context = &artifact_context
			terrain_generation_benchmark_diagnostic_timing_context = &timing_context
			terrain_generation_benchmark_cave_slice_selected_target = fixture.cave_slice_target
			terrain_generation_benchmark_surface_capture_step_override = fixture.step_override
			defer {
				terrain_generation_benchmark_artifact_context = previous_artifact_context
				terrain_generation_benchmark_diagnostic_timing_context = previous_timing_context
				terrain_generation_benchmark_cave_slice_selected_target =
					previous_cave_slice_target
				terrain_generation_benchmark_surface_capture_step_override =
					previous_surface_step_override
			}

			seed := fixture.seed
			key := terrain_generation_key_make(seed)
			capture_start: time.Tick
			switch fixture.kind {
			case .Cave_Slice:
				capture_start = time.tick_now()
				terrain_generation_benchmark_cave_slice_capture_runs_run(key, seed, ctx.temp_arena)
				out.capture += time.tick_since(capture_start)
				out.cave_slice_capture += out.capture
			case .Surface_Morphology_Capture, .Surface_Fortress_Capture:
				selection_start := time.tick_now()
				surface_water_coords := terrain_generation_benchmark_surface_water_coords_make(key)
				surface_cave_anchors := terrain_generation_benchmark_surface_cave_anchors_pick(key)
				surface_cave_coords := terrain_generation_benchmark_surface_cave_coords_make(
					surface_cave_anchors,
				)
				surface_fortress_selection :=
					terrain_generation_benchmark_surface_fortress_selection(key)
				out.selection += time.tick_since(selection_start)
				capture_start = time.tick_now()
				terrain_generation_benchmark_surface_capture_runs_run(
					seed,
					surface_water_coords,
					surface_cave_coords,
					surface_cave_anchors,
					surface_fortress_selection,
					ctx.temp_arena,
					fixture.kind == .Surface_Fortress_Capture,
				)
				out.capture += time.tick_since(capture_start)
			}

			if !artifact_context.ok {
				return bench.status_fail(artifact_context.error)
			}
			out.text_artifact_write += timing_context.text_artifact_write
			out.text_artifact_bytes += timing_context.text_artifact_bytes
			out.surface_center_selection += timing_context.surface_center_select
			out.surface_peak_search += timing_context.surface_peak_search
			out.surface_emit += timing_context.surface_emit
			out.artifact_count = u64(artifact_context.artifact_count)
			if out.artifact_count == 0 {
				return bench.status_fail("terrain diagnostic capture emitted no artifacts")
			}
			return bench.status_pass()
		}

		terrain_generation_diagnostic_fixture_write :: proc(
			ctx: ^bench.BenchmarkContext,
			data: rawptr,
			writer: ^bench.BenchmarkMetadataWriter,
		) -> bench.BenchmarkStatus {
			fixture := (^TerrainGenerationDiagnosticFixture)(data)
			bench.metadata_string(
				writer,
				"fixture_name",
				terrain_generation_diagnostic_kind_name(fixture.kind),
			)
			bench.metadata_u64(writer, "seed", u64(fixture.seed))
			bench.metadata_i64(writer, "cave_slice_target", i64(fixture.cave_slice_target))
			bench.metadata_i64(writer, "surface_step_override", i64(fixture.step_override))
			_ = ctx
			return bench.status_pass()
		}

		terrain_generation_diagnostic_case_register :: proc(
			registry: ^bench.BenchmarkRegistry,
			name: string,
			kind: TerrainGenerationDiagnosticKind,
			cave_slice_target: int = TERRAIN_GENERATION_BENCHMARK_CAVE_SLICE_TARGET_ALL,
			step_override: i32 = 0,
		) {
			fixture := TerrainGenerationDiagnosticFixture {
					kind              = kind,
					seed              = 0,
					cave_slice_target = cave_slice_target,
					step_override     = step_override,
				}
			bench.register(
				registry,
				name,
				terrain_generation_diagnostic_run,
				rawptr(&fixture),
				nil,
				{
					iterations = 1,
					workers = 1,
					result_size = size_of(TerrainGenerationDiagnosticResult),
					result_align = align_of(TerrainGenerationDiagnosticResult),
					data_size = size_of(TerrainGenerationDiagnosticFixture),
					data_align = align_of(TerrainGenerationDiagnosticFixture),
					metrics = terrain_generation_diagnostic_metrics[:],
					flags = {.Serial_Only, .Uses_Shared_Caches, .Emits_Artifacts},
					warmup_mode = .None,
					write_fixture = terrain_generation_diagnostic_fixture_write,
					category = "world.terrain_generation.diagnostic",
					version = TERRAIN_GENERATION_DIAGNOSTIC_BENCHMARK_VERSION,
					default_in_all = false,
				},
			)
		}

		terrain_generation_benchmarks_register :: proc(registry: ^bench.BenchmarkRegistry) {
			terrain_component_benchmarks_register(registry)
			terrain_generation_registered_case_register(
				registry,
				"world.terrain_generation.cave_hot_region_cache",
				.Cave_Hot_Region_Cache,
			)
			terrain_generation_registered_case_register(
				registry,
				"world.terrain_generation.cave_warm_region_column_cache",
				.Cave_Warm_Region_Column_Cache,
			)
			terrain_generation_registered_case_register(
				registry,
				"world.terrain_generation.cave_proxy_anchors",
				.Cave_Proxy_Anchors,
			)
			terrain_generation_registered_case_register(
				registry,
				"world.terrain_generation.surface_water_hot_region_cache",
				.Surface_Water_Hot_Region_Cache,
			)
			terrain_generation_registered_case_register(
				registry,
				"world.terrain_generation.surface_cave_hot_region_cache",
				.Surface_Cave_Hot_Region_Cache,
			)
			terrain_generation_registered_case_register(
				registry,
				"world.terrain_generation.surface_feature_hot_region_cache",
				.Surface_Feature_Hot_Region_Cache,
			)
			terrain_generation_registered_case_register(
				registry,
				"world.terrain_generation.surface_fortress_hot_region_cache",
				.Surface_Fortress_Hot_Region_Cache,
			)
			terrain_generation_registered_case_register(
				registry,
				"world.terrain_generation.cave_reset_region_cache",
				.Cave_Reset_Region_Cache,
			)
			terrain_generation_registered_case_register(
				registry,
				"world.terrain_generation.surface_water_reset_region_cache",
				.Surface_Water_Reset_Region_Cache,
			)
			terrain_generation_registered_case_register(
				registry,
				"world.terrain_generation.surface_cave_reset_region_cache",
				.Surface_Cave_Reset_Region_Cache,
			)
			terrain_generation_registered_case_register(
				registry,
				"world.terrain_generation.surface_feature_reset_region_cache",
				.Surface_Feature_Reset_Region_Cache,
			)
			terrain_generation_registered_case_register(
				registry,
				"world.terrain_generation.surface_fortress_reset_region_cache",
				.Surface_Fortress_Reset_Region_Cache,
			)
			terrain_generation_diagnostic_case_register(
				registry,
				"world.terrain_generation.diagnostic.cave_slice.profile",
				.Cave_Slice,
				TERRAIN_GENERATION_BENCHMARK_CAVE_SLICE_TARGET_PROFILE,
			)
			terrain_generation_diagnostic_case_register(
				registry,
				"world.terrain_generation.diagnostic.surface_morphology_capture",
				.Surface_Morphology_Capture,
			)
			terrain_generation_diagnostic_case_register(
				registry,
				"world.terrain_generation.diagnostic.surface_fortress_capture",
				.Surface_Fortress_Capture,
				TERRAIN_GENERATION_BENCHMARK_CAVE_SLICE_TARGET_ALL,
				1,
			)
		}

		terrain_generation_benchmark_surface_capture_chunk_view_get :: proc(
			cache: ^TerrainGenerationBenchmarkCaveSliceChunkCache,
			coord: world_async.ChunkCoord,
			seed: u32,
			allocator: mem.Allocator,
		) -> ^world_async.ChunkVoxelView {
			for i := u32(0); i < cache.count; i += 1 {
				if cache.entries[i].valid && cache.entries[i].coord == coord {
					return &cache.entries[i].view
				}
			}
			entry: ^TerrainGenerationBenchmarkCaveSliceChunkCacheEntry
			if cache.count < TERRAIN_GENERATION_BENCHMARK_CAVE_SLICE_CHUNK_CACHE_CAPACITY {
				entry = &cache.entries[cache.count]
				cache.count += 1
			} else {
				entry = &cache.entries[cache.next_reuse_index]
				cache.next_reuse_index =
					(cache.next_reuse_index + 1) %
					TERRAIN_GENERATION_BENCHMARK_CAVE_SLICE_CHUNK_CACHE_CAPACITY
			}
			entry.coord = coord
			entry.valid = true
			if len(entry.view.blocks) != CHUNK_BLOCK_COUNT {
				chunk_voxel_view_alloc(&entry.view, allocator)
			}
			terrain_heightfield_voxel_view_fill(&entry.view, coord, seed)
			return &entry.view
		}

		terrain_generation_benchmark_surface_capture_pixel_from_view :: proc(
			view: ^world_async.ChunkVoxelView,
			local: world_async.BlockCoord,
		) -> u8 {
			index := chunk_block_index(u32(local.x), u32(local.y), u32(local.z))
			palette := terrain_material_palette_index(view.blocks.material_id[index])
			if palette == TERRAIN_WATER_MAT_ID {
				return '~'
			}
			if view.blocks.occupancy[index] == .Empty {
				return '.'
			}
			switch palette {
			case TERRAIN_GRASS_MAT_ID:
				return 'g'
			case TERRAIN_DIRT_MAT_ID:
				return 'd'
			case TERRAIN_WET_MARSH_MAT_ID:
				return 'm'
			case TERRAIN_CORRUPTED_ASH_MAT_ID:
				return 'x'
			case TERRAIN_AQUIFER_WALL_MAT_ID:
				return 'a'
			case TERRAIN_CRYSTAL_MAT_ID:
				return 'c'
			}
			return '#'
		}

		terrain_generation_benchmark_surface_capture_sample_pixel :: proc(
			cache: ^TerrainGenerationBenchmarkCaveSliceChunkCache,
			block: world_async.BlockCoord,
			seed: u32,
			allocator: mem.Allocator,
		) -> u8 {
			chunk_coord := chunk_coord_from_block_coord(block)
			view := terrain_generation_benchmark_surface_capture_chunk_view_get(
				cache,
				chunk_coord,
				seed,
				allocator,
			)
			local := block_coord_local_from_chunk_coord(block, chunk_coord)
			if !chunk_block_coord_is_inside(local.x, local.y, local.z) {
				return '?'
			}
			return terrain_generation_benchmark_surface_capture_pixel_from_view(view, local)
		}

		terrain_generation_benchmark_surface_capture_highest_pixel_y :: proc(
			cache: ^TerrainGenerationBenchmarkCaveSliceChunkCache,
			world_x, world_z: i32,
			seed: u32,
			allocator: mem.Allocator,
		) -> (
			highest_y: i32,
			found: bool,
		) {
			for world_y := TERRAIN_GENERATION_BENCHMARK_SURFACE_CAPTURE_SCAN_Y_MAX;
			    world_y >= TERRAIN_GENERATION_BENCHMARK_SURFACE_CAPTURE_SCAN_Y_MIN;
			    world_y -= 1 {
				pixel := terrain_generation_benchmark_surface_capture_sample_pixel(
					cache,
					{x = world_x, y = world_y, z = world_z},
					seed,
					allocator,
				)
				if pixel != '.' {
					highest_y = world_y
					found = true
					return
				}
			}
			return
		}

		terrain_generation_benchmark_surface_capture_plan_pixel :: proc(
			cache: ^TerrainGenerationBenchmarkCaveSliceChunkCache,
			world_x, world_z: i32,
			seed: u32,
			allocator: mem.Allocator,
		) -> u8 {
			highest_y, found := terrain_generation_benchmark_surface_capture_highest_pixel_y(
				cache,
				world_x,
				world_z,
				seed,
				allocator,
			)
			if !found {
				return '.'
			}
			return terrain_generation_benchmark_surface_capture_sample_pixel(
				cache,
				{x = world_x, y = highest_y, z = world_z},
				seed,
				allocator,
			)
		}

		terrain_generation_benchmark_surface_capture_column_for_block :: proc(
			key: biomes.FeatureGridKey,
			block: world_async.BlockCoord,
		) -> TerrainBiomeColumn {
			return terrain_generation_benchmark_surface_capture_column_for_xz(
				key,
				block.x,
				block.z,
			)
		}

		terrain_generation_benchmark_surface_capture_column_for_xz :: proc(
			key: biomes.FeatureGridKey,
			world_x, world_z: i32,
		) -> TerrainBiomeColumn {
			region_coord := biomes.generation_region_coord_from_block(world_x, 0, world_z)
			region := terrain_generation_region_for_fill(key, region_coord)
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
			profile_row_cache := biomes.surface_biome_profile_row_cache_make(key, world_z)
			evaluation := biomes.surface_biome_profile_evaluate_with_hydrology(
				key,
				surface_sample,
				hydrology_sample,
				world_x,
				world_z,
				&profile_row_cache,
			)
			evaluation = terrain_surface_morphology_apply_feature_envelopes(
				evaluation,
				region.surface_morphology_features[:],
				region.surface_morphology_feature_count,
				world_x,
				world_z,
			)
			return terrain_biome_column_from_profile_evaluation(key, evaluation, world_x, world_z)
		}

		terrain_generation_benchmark_surface_capture_material_char :: proc(
			material_id: world_async.BlockMaterialID,
		) -> u8 {
			switch terrain_material_palette_index(material_id) {
			case TERRAIN_GRASS_MAT_ID:
				return 'g'
			case TERRAIN_DIRT_MAT_ID:
				return 'd'
			case TERRAIN_WET_MARSH_MAT_ID:
				return 'm'
			case TERRAIN_WATER_MAT_ID:
				return '~'
			case TERRAIN_CORRUPTED_ASH_MAT_ID:
				return 'x'
			case TERRAIN_AQUIFER_WALL_MAT_ID:
				return 'a'
			case TERRAIN_CRYSTAL_MAT_ID:
				return 'c'
			}
			return '#'
		}

		terrain_generation_benchmark_surface_capture_shape_pixel_from_column_plan :: proc(
			key: biomes.FeatureGridKey,
			column: TerrainBiomeColumn,
			feature_plan: ^TerrainSurfaceMorphologyColumnFeaturePlan,
			world_x, world_y, world_z: i32,
		) -> u8 {
			world_y_f32 := f32(world_y)
			if column.water_fill_active &&
			   world_y_f32 <= column.water_level_blocks &&
			   world_y_f32 > column.surface_height_blocks {
				return '~'
			}

			density := terrain_surface_base_density_sample(column, world_y)
			profile := column.surface_morphology_profile
			if terrain_surface_morphology_effective_strength(column, profile) > 0.001 ||
			   feature_plan.active {
				shape := terrain_surface_morphology_column_shape_make(
					key,
					column,
					world_x,
					world_z,
				)
				density = terrain_surface_density_sample_with_feature_plan(
					column,
					shape,
					feature_plan,
					world_x,
					world_y,
					world_z,
				)
			}
			if density < 0 {
				return '.'
			}

			blocks_below_surface := column.surface_height - world_y
			material_id := terrain_biome_block_material_id(column, blocks_below_surface)
			return terrain_generation_benchmark_surface_capture_material_char(material_id)
		}

		terrain_generation_benchmark_surface_capture_shape_pixel_from_column :: proc(
			key: biomes.FeatureGridKey,
			column: TerrainBiomeColumn,
			world_x, world_y, world_z: i32,
		) -> u8 {
			features: [biomes.FEATURE_GRID_WORLEY_NEIGHBOR_COUNT_2]biomes.SurfaceMorphologyFeature
			feature_count := terrain_surface_morphology_features_for_block_direct(
				key,
				world_x,
				world_z,
				features[:],
			)
			feature_plan := TerrainSurfaceMorphologyColumnFeaturePlan{}
			terrain_surface_morphology_column_feature_plan_write(
				features[:],
				feature_count,
				world_x,
				world_z,
				&feature_plan,
			)
			return terrain_generation_benchmark_surface_capture_shape_pixel_from_column_plan(
				key,
				column,
				&feature_plan,
				world_x,
				world_y,
				world_z,
			)
		}

		terrain_generation_benchmark_surface_capture_shape_pixel :: proc(
			key: biomes.FeatureGridKey,
			block: world_async.BlockCoord,
		) -> u8 {
			column := terrain_generation_benchmark_surface_capture_column_for_xz(
				key,
				block.x,
				block.z,
			)
			return terrain_generation_benchmark_surface_capture_shape_pixel_from_column(
				key,
				column,
				block.x,
				block.y,
				block.z,
			)
		}

		terrain_generation_benchmark_surface_capture_shape_highest_y :: proc(
			key: biomes.FeatureGridKey,
			world_x, world_z: i32,
		) -> (
			highest_y: i32,
			found: bool,
		) {
			column := terrain_generation_benchmark_surface_capture_column_for_xz(
				key,
				world_x,
				world_z,
			)
			features: [biomes.FEATURE_GRID_WORLEY_NEIGHBOR_COUNT_2]biomes.SurfaceMorphologyFeature
			feature_count := terrain_surface_morphology_features_for_block_direct(
				key,
				world_x,
				world_z,
				features[:],
			)
			feature_plan := TerrainSurfaceMorphologyColumnFeaturePlan{}
			terrain_surface_morphology_column_feature_plan_write(
				features[:],
				feature_count,
				world_x,
				world_z,
				&feature_plan,
			)
			for world_y := TERRAIN_GENERATION_BENCHMARK_SURFACE_CAPTURE_SCAN_Y_MAX;
			    world_y >= TERRAIN_GENERATION_BENCHMARK_SURFACE_CAPTURE_SCAN_Y_MIN;
			    world_y -= 1 {
				pixel := terrain_generation_benchmark_surface_capture_shape_pixel_from_column_plan(
					key,
					column,
					&feature_plan,
					world_x,
					world_y,
					world_z,
				)
				if pixel != '.' {
					highest_y = world_y
					found = true
					return
				}
			}
			return
		}

		terrain_generation_benchmark_surface_capture_shape_plan_pixel :: proc(
			key: biomes.FeatureGridKey,
			world_x, world_z: i32,
		) -> u8 {
			highest_y, found := terrain_generation_benchmark_surface_capture_shape_highest_y(
				key,
				world_x,
				world_z,
			)
			if !found {
				return '.'
			}
			column := terrain_generation_benchmark_surface_capture_column_for_xz(
				key,
				world_x,
				world_z,
			)
			return terrain_generation_benchmark_surface_capture_shape_pixel_from_column(
				key,
				column,
				world_x,
				highest_y,
				world_z,
			)
		}

		terrain_generation_benchmark_surface_capture_delta_pixel :: proc(
			key: biomes.FeatureGridKey,
			block: world_async.BlockCoord,
		) -> u8 {
			column := terrain_generation_benchmark_surface_capture_column_for_block(key, block)
			base_density := terrain_surface_base_density_sample(column, block.y)
			base_solid := base_density >= 0
			profile := column.surface_morphology_profile
			if column.water_fill_active {
				block_y_f32 := f32(block.y)
				if block_y_f32 <= column.water_level_blocks &&
				   block_y_f32 > column.surface_height_blocks {
					return '~'
				}
				if base_solid {
					return '#'
				}
				return '.'
			}
			features: [biomes.FEATURE_GRID_WORLEY_NEIGHBOR_COUNT_2]biomes.SurfaceMorphologyFeature
			feature_count := terrain_surface_morphology_features_for_block_direct(
				key,
				block.x,
				block.z,
				features[:],
			)
			feature_plan := TerrainSurfaceMorphologyColumnFeaturePlan{}
			terrain_surface_morphology_column_feature_plan_write(
				features[:],
				feature_count,
				block.x,
				block.z,
				&feature_plan,
			)
			if terrain_surface_morphology_effective_strength(column, profile) <= 0.001 &&
			   !feature_plan.active {
				if base_solid {
					return '#'
				}
				return '.'
			}

			shape := terrain_surface_morphology_column_shape_make(key, column, block.x, block.z)
			morphology_density := terrain_surface_density_sample_with_feature_plan(
				column,
				shape,
				&feature_plan,
				block.x,
				block.y,
				block.z,
			)
			morphology_solid := morphology_density >= 0
			if morphology_solid && !base_solid {
				return '+'
			}
			if !morphology_solid && base_solid {
				return '-'
			}
			if morphology_solid {
				return '#'
			}
			return '.'
		}

		terrain_generation_benchmark_surface_capture_step_blocks :: proc() -> i32 {
			if terrain_generation_benchmark_surface_capture_step_override > 0 {
				return terrain_generation_benchmark_surface_capture_step_override
			}
			return TERRAIN_GENERATION_BENCHMARK_SURFACE_CAPTURE_STEP_BLOCKS
		}

		terrain_generation_benchmark_surface_capture_vertical_block_coord :: proc(
			center: world_async.BlockCoord,
			column, row: i32,
		) -> world_async.BlockCoord {
			half_width := i32(TERRAIN_GENERATION_BENCHMARK_SURFACE_CAPTURE_WIDTH / 2)
			half_height := i32(TERRAIN_GENERATION_BENCHMARK_SURFACE_CAPTURE_HEIGHT / 2)
			step_blocks := terrain_generation_benchmark_surface_capture_step_blocks()
			offset_x := (column - half_width) * step_blocks
			offset_y := (row - half_height) * step_blocks
			return {x = center.x + offset_x, y = center.y - offset_y, z = center.z}
		}

		terrain_generation_benchmark_surface_capture_plan_block_xz :: proc(
			center: world_async.BlockCoord,
			column, row: i32,
		) -> (
			world_x, world_z: i32,
		) {
			half_width := i32(TERRAIN_GENERATION_BENCHMARK_SURFACE_CAPTURE_WIDTH / 2)
			half_height := i32(TERRAIN_GENERATION_BENCHMARK_SURFACE_CAPTURE_HEIGHT / 2)
			step_blocks := terrain_generation_benchmark_surface_capture_step_blocks()
			world_x = center.x + (column - half_width) * step_blocks
			world_z = center.z + (row - half_height) * step_blocks
			return
		}

		terrain_generation_benchmark_surface_capture_center_refit_y :: proc(
			center: world_async.BlockCoord,
			seed: u32,
			transient_arena: ^mem.Arena,
		) -> world_async.BlockCoord {
			_ = transient_arena
			result := center
			key := terrain_generation_key_make(seed)
			highest_y, found := terrain_generation_benchmark_surface_capture_shape_highest_y(
				key,
				center.x,
				center.z,
			)
			if found {
				result.y = highest_y - TERRAIN_GENERATION_BENCHMARK_SURFACE_CAPTURE_HEADROOM_BLOCKS
			}
			return result
		}

		terrain_generation_benchmark_surface_capture_center_from_coords :: proc(
			coords: TerrainGenerationBenchmarkCoords,
			seed: u32,
			transient_arena: ^mem.Arena,
		) -> world_async.BlockCoord {
			origin := chunk_origin_from_coord(coords[0])
			center := world_async.BlockCoord {
				x = origin.x + CHUNK_BLOCK_LENGTH / 2,
				y = origin.y + CHUNK_BLOCK_LENGTH / 2,
				z = origin.z + CHUNK_BLOCK_LENGTH / 2,
			}
			return terrain_generation_benchmark_surface_capture_center_refit_y(
				center,
				seed,
				transient_arena,
			)
		}

		terrain_generation_benchmark_surface_capture_peak_center_find :: proc(
			seed: u32,
			transient_arena: ^mem.Arena,
		) -> world_async.BlockCoord {
			_ = transient_arena
			key := terrain_generation_key_make(seed)
			best_center := world_async.BlockCoord{}
			best_score := -max(f32)
			found := false
			for world_z := i32(-2048); world_z <= 2048; world_z += 32 {
				for world_x := i32(-2048); world_x <= 2048; world_x += 32 {
					column := terrain_generation_benchmark_surface_capture_column_for_xz(
						key,
						world_x,
						world_z,
					)
					if column.water_fill_active {
						continue
					}
					profile := column.surface_morphology_profile
					score := column.surface_height_blocks + profile.strength * 12
					#partial switch column.dominant_biome_id {
					case .Basalt_Spire_Highlands, .Corrupted_Ash_Forest:
						score += 18
					}
					if !found || score > best_score {
						found = true
						best_score = score
						best_center = {
							x = world_x,
							y = i32(
								math.floor_f32(column.surface_height_blocks),
							) - TERRAIN_GENERATION_BENCHMARK_SURFACE_CAPTURE_HEADROOM_BLOCKS,
							z = world_z,
						}
					}
				}
			}
			found_text := "false"
			if found {
				found_text = "true"
			}
			log.infof(
				"TERRAIN_GENERATION_SURFACE_MORPHOLOGY_PEAK_CENTER found=%s center=(%d,%d,%d) score=%.3f",
				found_text,
				best_center.x,
				best_center.y,
				best_center.z,
				best_score,
			)
			return best_center
		}

		terrain_generation_benchmark_surface_capture_count_pixel :: proc(
			pixel: u8,
			added_count,
			removed_count,
			unchanged_solid_count,
			unchanged_empty_count,
			water_count: ^u32,
		) {
			switch pixel {
			case '+':
				added_count^ += 1
			case '-':
				removed_count^ += 1
			case '~':
				water_count^ += 1
			case '.':
				unchanged_empty_count^ += 1
			case '?':
			case:
				unchanged_solid_count^ += 1
			}
		}

		terrain_generation_benchmark_surface_capture_emit :: proc(
			label: string,
			mode: TerrainGenerationBenchmarkSurfaceCaptureMode,
			center: world_async.BlockCoord,
			seed: u32,
			transient_arena: ^mem.Arena,
		) {
			timing_context := terrain_generation_benchmark_diagnostic_timing_context
			emit_start: time.Tick
			if timing_context != nil {
				emit_start = time.tick_now()
			}
			defer {
				if timing_context != nil {
					timing_context.surface_emit += time.tick_since(emit_start)
				}
			}
			temp := mem.begin_arena_temp_memory(transient_arena)
			defer mem.end_arena_temp_memory(temp)
			allocator := mem.arena_allocator(transient_arena)
			pixels := new(TerrainGenerationBenchmarkSurfaceCapturePixels, allocator)
			key := terrain_generation_key_make(seed)
			cache := TerrainGenerationBenchmarkCaveSliceChunkCache{}

			added_count: u32
			removed_count: u32
			unchanged_solid_count: u32
			unchanged_empty_count: u32
			water_count: u32
			for row := i32(0);
			    row < i32(TERRAIN_GENERATION_BENCHMARK_SURFACE_CAPTURE_HEIGHT);
			    row += 1 {
				for column := i32(0);
				    column < i32(TERRAIN_GENERATION_BENCHMARK_SURFACE_CAPTURE_WIDTH);
				    column += 1 {
					pixel := u8('?')
					switch mode {
					case .Plan_Surface:
						world_x, world_z :=
							terrain_generation_benchmark_surface_capture_plan_block_xz(
								center,
								column,
								row,
							)
						pixel = terrain_generation_benchmark_surface_capture_shape_plan_pixel(
							key,
							world_x,
							world_z,
						)
					case .Morphology_Delta_XY:
						block := terrain_generation_benchmark_surface_capture_vertical_block_coord(
							center,
							column,
							row,
						)
						pixel = terrain_generation_benchmark_surface_capture_delta_pixel(
							key,
							block,
						)
					case .Vertical_XY:
						block := terrain_generation_benchmark_surface_capture_vertical_block_coord(
							center,
							column,
							row,
						)
						pixel = terrain_generation_benchmark_surface_capture_shape_pixel(
							key,
							block,
						)
					case .Decorated_Vertical_XY:
						block := terrain_generation_benchmark_surface_capture_vertical_block_coord(
							center,
							column,
							row,
						)
						pixel = terrain_generation_benchmark_surface_capture_sample_pixel(
							&cache,
							block,
							seed,
							allocator,
						)
					case .Decorated_Plan_Surface:
						world_x, world_z :=
							terrain_generation_benchmark_surface_capture_plan_block_xz(
								center,
								column,
								row,
							)
						pixel = terrain_generation_benchmark_surface_capture_plan_pixel(
							&cache,
							world_x,
							world_z,
							seed,
							allocator,
						)
					}
					pixel_index :=
						row * i32(TERRAIN_GENERATION_BENCHMARK_SURFACE_CAPTURE_WIDTH) + column
					pixels[pixel_index] = pixel
					terrain_generation_benchmark_surface_capture_count_pixel(
						pixel,
						&added_count,
						&removed_count,
						&unchanged_solid_count,
						&unchanged_empty_count,
						&water_count,
					)
				}
			}

			log.infof(
				"TERRAIN_GENERATION_SURFACE_MORPHOLOGY_SLICE_BEGIN label=%s mode=%v center=(%d,%d,%d) width=%d height=%d step=%d chunks=%d added=%d removed=%d unchanged_solid=%d unchanged_empty=%d water=%d",
				label,
				mode,
				center.x,
				center.y,
				center.z,
				TERRAIN_GENERATION_BENCHMARK_SURFACE_CAPTURE_WIDTH,
				TERRAIN_GENERATION_BENCHMARK_SURFACE_CAPTURE_HEIGHT,
				terrain_generation_benchmark_surface_capture_step_blocks(),
				0,
				added_count,
				removed_count,
				unchanged_solid_count,
				unchanged_empty_count,
				water_count,
			)
			if terrain_generation_benchmark_artifact_context == nil {
				for row := i32(0);
				    row < i32(TERRAIN_GENERATION_BENCHMARK_SURFACE_CAPTURE_HEIGHT);
				    row += 1 {
					row_bytes: [TERRAIN_GENERATION_BENCHMARK_SURFACE_CAPTURE_WIDTH]u8
					for column := i32(0);
					    column < i32(TERRAIN_GENERATION_BENCHMARK_SURFACE_CAPTURE_WIDTH);
					    column += 1 {
						pixel_index :=
							row * i32(TERRAIN_GENERATION_BENCHMARK_SURFACE_CAPTURE_WIDTH) + column
						row_bytes[column] = pixels[pixel_index]
					}
					log.infof(
						"TERRAIN_GENERATION_SURFACE_MORPHOLOGY_SLICE_ROW label=%s mode=%v row=%d data=%s",
						label,
						mode,
						row,
						string(row_bytes[:]),
					)
				}
			}
			log.infof(
				"TERRAIN_GENERATION_SURFACE_MORPHOLOGY_SLICE_END label=%s mode=%v",
				label,
				mode,
			)

			if terrain_generation_benchmark_artifact_context != nil &&
			   terrain_generation_benchmark_artifact_context.ok {
				builder, alloc_err := strings.builder_make(allocator = allocator)
				if alloc_err != nil {
					terrain_generation_benchmark_artifact_context.ok = false
					terrain_generation_benchmark_artifact_context.error = "failed to allocate surface capture artifact builder"
				} else {
					defer strings.builder_destroy(&builder)
					fmt.sbprintf(
						&builder,
						"label=%s mode=%v center=(%d,%d,%d) width=%d height=%d step=%d added=%d removed=%d unchanged_solid=%d unchanged_empty=%d water=%d\n",
						label,
						mode,
						center.x,
						center.y,
						center.z,
						TERRAIN_GENERATION_BENCHMARK_SURFACE_CAPTURE_WIDTH,
						TERRAIN_GENERATION_BENCHMARK_SURFACE_CAPTURE_HEIGHT,
						terrain_generation_benchmark_surface_capture_step_blocks(),
						added_count,
						removed_count,
						unchanged_solid_count,
						unchanged_empty_count,
						water_count,
					)
					for row := i32(0);
					    row < i32(TERRAIN_GENERATION_BENCHMARK_SURFACE_CAPTURE_HEIGHT);
					    row += 1 {
						row_bytes: [TERRAIN_GENERATION_BENCHMARK_SURFACE_CAPTURE_WIDTH]u8
						for column := i32(0);
						    column < i32(TERRAIN_GENERATION_BENCHMARK_SURFACE_CAPTURE_WIDTH);
						    column += 1 {
							pixel_index :=
								row * i32(TERRAIN_GENERATION_BENCHMARK_SURFACE_CAPTURE_WIDTH) +
								column
							row_bytes[column] = pixels[pixel_index]
						}
						fmt.sbprintf(&builder, "%s\n", string(row_bytes[:]))
					}
					artifact_label := fmt.aprintf("%s_%v", label, mode, allocator = allocator)
					terrain_generation_benchmark_artifact_write(
						artifact_label,
						"terrain_surface_capture",
						strings.to_string(builder),
					)
				}
			}
		}

		terrain_generation_benchmark_surface_capture_runs_run :: proc(
			seed: u32,
			surface_water_coords: TerrainGenerationBenchmarkCoords,
			surface_cave_coords: TerrainGenerationBenchmarkCoords,
			surface_cave_anchors: TerrainGenerationBenchmarkSurfaceCaveAnchors,
			surface_fortress_selection: TerrainGenerationBenchmarkSurfaceFortressSelection,
			transient_arena: ^mem.Arena,
			fortress_only: bool = false,
		) {
			timing_context := terrain_generation_benchmark_diagnostic_timing_context
			center_select_start: time.Tick
			if timing_context != nil {
				center_select_start = time.tick_now()
			}
			water_center := terrain_generation_benchmark_surface_capture_center_from_coords(
				surface_water_coords,
				seed,
				transient_arena,
			)
			cave_center := terrain_generation_benchmark_surface_capture_center_from_coords(
				surface_cave_coords,
				seed,
				transient_arena,
			)
			if surface_cave_anchors.mouth_found {
				cave_center = {
					x = terrain_generation_benchmark_floor_i32(surface_cave_anchors.mouth.x),
					y = terrain_generation_benchmark_floor_i32(surface_cave_anchors.mouth.y),
					z = terrain_generation_benchmark_floor_i32(surface_cave_anchors.mouth.z),
				}
				cave_center = terrain_generation_benchmark_surface_capture_center_refit_y(
					cave_center,
					seed,
					transient_arena,
				)
			}
			if timing_context != nil {
				timing_context.surface_center_select += time.tick_since(center_select_start)
			}
			peak_search_start: time.Tick
			if timing_context != nil {
				peak_search_start = time.tick_now()
			}
			peak_center := terrain_generation_benchmark_surface_capture_peak_center_find(
				seed,
				transient_arena,
			)
			if timing_context != nil {
				timing_context.surface_peak_search += time.tick_since(peak_search_start)
				center_select_start = time.tick_now()
			}
			key := terrain_generation_key_make(seed)
			feature_selection := terrain_generation_benchmark_surface_morphology_feature_selection(
				key,
			)
			feature_center := feature_selection.center
			if feature_selection.found {
				feature_center = terrain_generation_benchmark_surface_capture_center_refit_y(
					feature_selection.center,
					seed,
					transient_arena,
				)
			}
			fortress_center := surface_fortress_selection.center
			if surface_fortress_selection.found {
				fortress_center = terrain_generation_benchmark_surface_capture_center_refit_y(
					surface_fortress_selection.center,
					seed,
					transient_arena,
				)
			}
			if timing_context != nil {
				timing_context.surface_center_select += time.tick_since(center_select_start)
			}

			log.info("TERRAIN_GENERATION_SURFACE_MORPHOLOGY_CAPTURE_START")
			if fortress_only {
				if surface_fortress_selection.found {
					terrain_generation_benchmark_surface_capture_emit(
						"surface_fortress_decorated_xy",
						.Decorated_Vertical_XY,
						fortress_center,
						seed,
						transient_arena,
					)
					terrain_generation_benchmark_surface_capture_emit(
						"surface_fortress_decorated_plan",
						.Decorated_Plan_Surface,
						fortress_center,
						seed,
						transient_arena,
					)
				} else {
					log.info("TERRAIN_GENERATION_SURFACE_MORPHOLOGY_FORTRESS_CAPTURE_SKIP")
				}
				log.info("TERRAIN_GENERATION_SURFACE_MORPHOLOGY_CAPTURE_END")
				return
			}
			terrain_generation_benchmark_surface_capture_emit(
				"surface_water_actual_xy",
				.Vertical_XY,
				water_center,
				seed,
				transient_arena,
			)
			terrain_generation_benchmark_surface_capture_emit(
				"surface_water_delta_xy",
				.Morphology_Delta_XY,
				water_center,
				seed,
				transient_arena,
			)
			terrain_generation_benchmark_surface_capture_emit(
				"surface_water_plan",
				.Plan_Surface,
				water_center,
				seed,
				transient_arena,
			)
			terrain_generation_benchmark_surface_capture_emit(
				"surface_cave_actual_xy",
				.Vertical_XY,
				cave_center,
				seed,
				transient_arena,
			)
			terrain_generation_benchmark_surface_capture_emit(
				"surface_cave_delta_xy",
				.Morphology_Delta_XY,
				cave_center,
				seed,
				transient_arena,
			)
			terrain_generation_benchmark_surface_capture_emit(
				"surface_cave_plan",
				.Plan_Surface,
				cave_center,
				seed,
				transient_arena,
			)
			terrain_generation_benchmark_surface_capture_emit(
				"surface_peak_actual_xy",
				.Vertical_XY,
				peak_center,
				seed,
				transient_arena,
			)
			terrain_generation_benchmark_surface_capture_emit(
				"surface_peak_delta_xy",
				.Morphology_Delta_XY,
				peak_center,
				seed,
				transient_arena,
			)
			terrain_generation_benchmark_surface_capture_emit(
				"surface_peak_plan",
				.Plan_Surface,
				peak_center,
				seed,
				transient_arena,
			)
			if feature_selection.found {
				terrain_generation_benchmark_surface_capture_emit(
					"surface_feature_actual_xy",
					.Vertical_XY,
					feature_center,
					seed,
					transient_arena,
				)
				terrain_generation_benchmark_surface_capture_emit(
					"surface_feature_delta_xy",
					.Morphology_Delta_XY,
					feature_center,
					seed,
					transient_arena,
				)
				terrain_generation_benchmark_surface_capture_emit(
					"surface_feature_plan",
					.Plan_Surface,
					feature_center,
					seed,
					transient_arena,
				)
			} else {
				log.info("TERRAIN_GENERATION_SURFACE_MORPHOLOGY_FEATURE_CAPTURE_SKIP")
			}
			if surface_fortress_selection.found {
				terrain_generation_benchmark_surface_capture_emit(
					"surface_fortress_decorated_xy",
					.Decorated_Vertical_XY,
					fortress_center,
					seed,
					transient_arena,
				)
				terrain_generation_benchmark_surface_capture_emit(
					"surface_fortress_decorated_plan",
					.Decorated_Plan_Surface,
					fortress_center,
					seed,
					transient_arena,
				)
			} else {
				log.info("TERRAIN_GENERATION_SURFACE_MORPHOLOGY_FORTRESS_CAPTURE_SKIP")
			}
			log.info("TERRAIN_GENERATION_SURFACE_MORPHOLOGY_CAPTURE_END")
		}

		terrain_generation_benchmark_cave_slice_chunk_view_get :: proc(
			cache: ^TerrainGenerationBenchmarkCaveSliceChunkCache,
			coord: world_async.ChunkCoord,
			seed: u32,
			allocator: mem.Allocator,
		) -> ^world_async.ChunkVoxelView {
			for i := u32(0); i < cache.count; i += 1 {
				if cache.entries[i].valid && cache.entries[i].coord == coord {
					return &cache.entries[i].view
				}
			}
			entry: ^TerrainGenerationBenchmarkCaveSliceChunkCacheEntry
			if cache.count < TERRAIN_GENERATION_BENCHMARK_CAVE_SLICE_CHUNK_CACHE_CAPACITY {
				entry = &cache.entries[cache.count]
				cache.count += 1
			} else {
				entry = &cache.entries[cache.next_reuse_index]
				cache.next_reuse_index =
					(cache.next_reuse_index + 1) %
					TERRAIN_GENERATION_BENCHMARK_CAVE_SLICE_CHUNK_CACHE_CAPACITY
			}
			entry.coord = coord
			entry.valid = true
			if len(entry.view.blocks) != CHUNK_BLOCK_COUNT {
				chunk_voxel_view_alloc(&entry.view, allocator)
			}
			terrain_heightfield_voxel_view_fill(&entry.view, coord, seed)
			return &entry.view
		}

		terrain_generation_benchmark_cave_slice_pixel :: proc(
			view: ^world_async.ChunkVoxelView,
			local: world_async.BlockCoord,
		) -> u8 {
			index := chunk_block_index(u32(local.x), u32(local.y), u32(local.z))
			palette := terrain_material_palette_index(view.blocks.material_id[index])
			if palette == TERRAIN_WATER_MAT_ID {
				return '~'
			}
			if view.blocks.occupancy[index] == .Empty {
				return '.'
			}
			switch palette {
			case TERRAIN_GRASS_MAT_ID:
				return 'g'
			case TERRAIN_DIRT_MAT_ID:
				return 'd'
			case TERRAIN_WET_MARSH_MAT_ID:
				return 'm'
			case TERRAIN_CORRUPTED_ASH_MAT_ID:
				return 'x'
			case TERRAIN_AQUIFER_WALL_MAT_ID:
				return 'a'
			case TERRAIN_CRYSTAL_MAT_ID:
				return 'c'
			}
			return '#'
		}

		terrain_generation_benchmark_cave_view_sample_pixel :: proc(
			cache: ^TerrainGenerationBenchmarkCaveSliceChunkCache,
			block: world_async.BlockCoord,
			seed: u32,
			allocator: mem.Allocator,
		) -> u8 {
			chunk_coord := chunk_coord_from_block_coord(block)
			view := terrain_generation_benchmark_cave_slice_chunk_view_get(
				cache,
				chunk_coord,
				seed,
				allocator,
			)
			local := block_coord_local_from_chunk_coord(block, chunk_coord)
			if !chunk_block_coord_is_inside(local.x, local.y, local.z) {
				return '?'
			}
			return terrain_generation_benchmark_cave_slice_pixel(view, local)
		}

		terrain_generation_benchmark_cave_view_depth_char :: proc(distance: f32) -> u8 {
			normalized := math.clamp(
				distance / TERRAIN_GENERATION_BENCHMARK_CAVE_VIEW_MAX_DISTANCE_BLOCKS,
				f32(0),
				f32(1),
			)
			index := i32(normalized * f32(15) + f32(0.5))
			if index < 10 {
				return u8('0' + index)
			}
			return u8('a' + index - 10)
		}

		terrain_generation_benchmark_cave_view_ray_sample :: proc(
			cache: ^TerrainGenerationBenchmarkCaveSliceChunkCache,
			camera_x, camera_y, camera_z: f32,
			dir_x, dir_y, dir_z: f32,
			seed: u32,
			allocator: mem.Allocator,
		) -> (
			pixel: u8,
			depth: u8,
			distance: f32,
			hit: bool,
		) {
			for step := i32(0);
			    step <= TERRAIN_GENERATION_BENCHMARK_CAVE_VIEW_MAX_STEPS;
			    step += 1 {
				distance =
					f32(1.0) + f32(step) * TERRAIN_GENERATION_BENCHMARK_CAVE_VIEW_STEP_BLOCKS
				block := world_async.BlockCoord {
					x = terrain_generation_benchmark_floor_i32(camera_x + dir_x * distance),
					y = terrain_generation_benchmark_floor_i32(camera_y + dir_y * distance),
					z = terrain_generation_benchmark_floor_i32(camera_z + dir_z * distance),
				}
				pixel = terrain_generation_benchmark_cave_view_sample_pixel(
					cache,
					block,
					seed,
					allocator,
				)
				if pixel != '.' {
					depth = terrain_generation_benchmark_cave_view_depth_char(distance)
					hit = true
					return
				}
			}
			pixel = '.'
			depth = 'f'
			distance = TERRAIN_GENERATION_BENCHMARK_CAVE_VIEW_MAX_DISTANCE_BLOCKS
			hit = false
			return
		}

		terrain_generation_benchmark_cave_slice_block_coord :: proc(
			center: world_async.BlockCoord,
			mode: TerrainGenerationBenchmarkCaveSliceMode,
			column, row: i32,
		) -> world_async.BlockCoord {
			half_width := i32(TERRAIN_GENERATION_BENCHMARK_CAVE_SLICE_WIDTH / 2)
			half_height := i32(TERRAIN_GENERATION_BENCHMARK_CAVE_SLICE_HEIGHT / 2)
			offset_x := (column - half_width) * TERRAIN_GENERATION_BENCHMARK_CAVE_SLICE_STEP_BLOCKS
			offset_b := (row - half_height) * TERRAIN_GENERATION_BENCHMARK_CAVE_SLICE_STEP_BLOCKS
			switch mode {
			case .Horizontal_XZ:
				return {x = center.x + offset_x, y = center.y, z = center.z + offset_b}
			case .Vertical_XY:
				return {x = center.x + offset_x, y = center.y - offset_b, z = center.z}
			case .Route_Longitudinal,
			     .Route_Cross_Section,
			     .Route_Plan,
			     .Route_Oblique,
			     .Route_Endpoint_Plan,
			     .Mouth_Longitudinal,
			     .Mouth_Plan:
				return center
			}
			return center
		}

		terrain_generation_benchmark_cave_slice_basis_block_coord :: proc(
			center_x, center_y, center_z: f32,
			axis_u_x, axis_u_y, axis_u_z: f32,
			axis_v_x, axis_v_y, axis_v_z: f32,
			column, row: i32,
		) -> world_async.BlockCoord {
			half_width := i32(TERRAIN_GENERATION_BENCHMARK_CAVE_SLICE_WIDTH / 2)
			half_height := i32(TERRAIN_GENERATION_BENCHMARK_CAVE_SLICE_HEIGHT / 2)
			offset_u := f32(
				(column - half_width) * TERRAIN_GENERATION_BENCHMARK_CAVE_SLICE_STEP_BLOCKS,
			)
			offset_v := f32(
				(row - half_height) * TERRAIN_GENERATION_BENCHMARK_CAVE_SLICE_STEP_BLOCKS,
			)
			return {
				x = terrain_generation_benchmark_floor_i32(
					center_x + axis_u_x * offset_u - axis_v_x * offset_v,
				),
				y = terrain_generation_benchmark_floor_i32(
					center_y + axis_u_y * offset_u - axis_v_y * offset_v,
				),
				z = terrain_generation_benchmark_floor_i32(
					center_z + axis_u_z * offset_u - axis_v_z * offset_v,
				),
			}
		}

		terrain_generation_benchmark_cave_route_frame :: proc(
			edge: biomes.CaveNetworkEdge,
			t: f32,
		) -> (
			tangent_x, tangent_y, tangent_z: f32,
			side_x, side_y, side_z: f32,
			up_x, up_y, up_z: f32,
		) {
			delta_t := f32(0.018)
			prev_x, prev_y, prev_z := terrain_density_cave_edge_route_point(
				edge,
				math.max(f32(0), t - delta_t),
			)
			next_x, next_y, next_z := terrain_density_cave_edge_route_point(
				edge,
				math.min(f32(1), t + delta_t),
			)
			tangent_x, tangent_y, tangent_z = terrain_density_delta_3(
				prev_x,
				prev_y,
				prev_z,
				next_x,
				next_y,
				next_z,
			)
			tangent_length := math.sqrt_f32(
				tangent_x * tangent_x + tangent_y * tangent_y + tangent_z * tangent_z,
			)
			if tangent_length <= 0.001 {
				tangent_x, tangent_y, tangent_z = 0, 0, 1
			} else {
				tangent_x /= tangent_length
				tangent_y /= tangent_length
				tangent_z /= tangent_length
			}

			horizontal_length := math.sqrt_f32(tangent_x * tangent_x + tangent_z * tangent_z)
			side_x, side_y, side_z = 1, 0, 0
			if horizontal_length > 0.001 {
				side_x = -tangent_z / horizontal_length
				side_z = tangent_x / horizontal_length
			}
			up_x = side_y * tangent_z - side_z * tangent_y
			up_y = side_z * tangent_x - side_x * tangent_z
			up_z = side_x * tangent_y - side_y * tangent_x
			up_length := math.sqrt_f32(up_x * up_x + up_y * up_y + up_z * up_z)
			if up_length <= 0.001 {
				up_x, up_y, up_z = 0, 1, 0
			} else {
				up_x /= up_length
				up_y /= up_length
				up_z /= up_length
			}
			return
		}

		terrain_generation_benchmark_cave_view_capture_basis :: proc(
			label: string,
			route_t: f32,
			camera_x, camera_y, camera_z: f32,
			forward_x, forward_y, forward_z: f32,
			right_hint_x, right_hint_y, right_hint_z: f32,
			up_hint_x, up_hint_y, up_hint_z: f32,
			seed: u32,
			transient_arena: ^mem.Arena,
		) {
			temp := mem.begin_arena_temp_memory(transient_arena)
			defer mem.end_arena_temp_memory(temp)
			allocator := mem.arena_allocator(transient_arena)
			cache := TerrainGenerationBenchmarkCaveSliceChunkCache{}
			pixels := new(TerrainGenerationBenchmarkCaveViewPixels, allocator)
			depths := new(TerrainGenerationBenchmarkCaveViewPixels, allocator)

			view_forward_x := forward_x
			view_forward_y := forward_y
			view_forward_z := forward_z
			forward_len := math.sqrt_f32(
				view_forward_x * view_forward_x +
				view_forward_y * view_forward_y +
				view_forward_z * view_forward_z,
			)
			if forward_len <= 0.001 {
				view_forward_x, view_forward_y, view_forward_z = 0, 0, 1
			} else {
				view_forward_x /= forward_len
				view_forward_y /= forward_len
				view_forward_z /= forward_len
			}

			right_x := right_hint_x
			right_y := right_hint_y
			right_z := right_hint_z
			right_dot :=
				right_x * view_forward_x + right_y * view_forward_y + right_z * view_forward_z
			right_x -= view_forward_x * right_dot
			right_y -= view_forward_y * right_dot
			right_z -= view_forward_z * right_dot
			right_len := math.sqrt_f32(right_x * right_x + right_y * right_y + right_z * right_z)
			if right_len <= 0.001 {
				horizontal_len := math.sqrt_f32(
					view_forward_x * view_forward_x + view_forward_z * view_forward_z,
				)
				if horizontal_len > 0.001 {
					right_x = -view_forward_z / horizontal_len
					right_y = 0
					right_z = view_forward_x / horizontal_len
				} else {
					right_x, right_y, right_z = 1, 0, 0
				}
			} else {
				right_x /= right_len
				right_y /= right_len
				right_z /= right_len
			}

			view_up_x := right_y * view_forward_z - right_z * view_forward_y
			view_up_y := right_z * view_forward_x - right_x * view_forward_z
			view_up_z := right_x * view_forward_y - right_y * view_forward_x
			view_up_len := math.sqrt_f32(
				view_up_x * view_up_x + view_up_y * view_up_y + view_up_z * view_up_z,
			)
			if view_up_len <= 0.001 {
				view_up_x, view_up_y, view_up_z = up_hint_x, up_hint_y, up_hint_z
				view_up_len = math.sqrt_f32(
					view_up_x * view_up_x + view_up_y * view_up_y + view_up_z * view_up_z,
				)
				if view_up_len <= 0.001 {
					view_up_x, view_up_y, view_up_z = 0, 1, 0
				} else {
					view_up_x /= view_up_len
					view_up_y /= view_up_len
					view_up_z /= view_up_len
				}
			} else {
				view_up_x /= view_up_len
				view_up_y /= view_up_len
				view_up_z /= view_up_len
			}

			fov_radians := math.to_radians_f32(TERRAIN_GENERATION_BENCHMARK_CAVE_VIEW_FOV_DEGREES)
			tan_y := math.tan_f32(fov_radians * f32(0.5))
			aspect :=
				f32(TERRAIN_GENERATION_BENCHMARK_CAVE_VIEW_WIDTH) /
				f32(TERRAIN_GENERATION_BENCHMARK_CAVE_VIEW_HEIGHT)
			tan_x := tan_y * aspect

			hit_count: u32
			miss_count: u32
			water_hit_count: u32
			distance_sum := f32(0)
			for row := i32(0); row < i32(TERRAIN_GENERATION_BENCHMARK_CAVE_VIEW_HEIGHT); row += 1 {
				screen_y :=
					(1.0 -
						((f32(row) + f32(0.5)) /
								f32(TERRAIN_GENERATION_BENCHMARK_CAVE_VIEW_HEIGHT)) *
							f32(2.0)) *
					tan_y
				for column := i32(0);
				    column < i32(TERRAIN_GENERATION_BENCHMARK_CAVE_VIEW_WIDTH);
				    column += 1 {
					screen_x :=
						(((f32(column) + f32(0.5)) /
									f32(TERRAIN_GENERATION_BENCHMARK_CAVE_VIEW_WIDTH)) *
								f32(2.0) -
							1.0) *
						tan_x
					dir_x := view_forward_x + right_x * screen_x + view_up_x * screen_y
					dir_y := view_forward_y + right_y * screen_x + view_up_y * screen_y
					dir_z := view_forward_z + right_z * screen_x + view_up_z * screen_y
					dir_len := math.sqrt_f32(dir_x * dir_x + dir_y * dir_y + dir_z * dir_z)
					if dir_len > 0.001 {
						dir_x /= dir_len
						dir_y /= dir_len
						dir_z /= dir_len
					}
					pixel, depth, distance, hit :=
						terrain_generation_benchmark_cave_view_ray_sample(
							&cache,
							camera_x,
							camera_y,
							camera_z,
							dir_x,
							dir_y,
							dir_z,
							seed,
							allocator,
						)
					pixel_index := row * i32(TERRAIN_GENERATION_BENCHMARK_CAVE_VIEW_WIDTH) + column
					pixels[pixel_index] = pixel
					depths[pixel_index] = depth
					if hit {
						hit_count += 1
						distance_sum += distance
						if pixel == '~' {
							water_hit_count += 1
						}
					} else {
						miss_count += 1
					}
				}
			}
			avg_distance := f32(0)
			if hit_count > 0 {
				avg_distance = distance_sum / f32(hit_count)
			}
			log.infof(
				"TERRAIN_GENERATION_CAVE_VIEW_BEGIN label=%s route_t=%.3f camera=(%.2f,%.2f,%.2f) forward=(%.3f,%.3f,%.3f) width=%d height=%d fov=%.1f max_distance=%.1f chunks=%d hits=%d misses=%d water_hits=%d avg_hit_distance=%.2f",
				label,
				route_t,
				camera_x,
				camera_y,
				camera_z,
				view_forward_x,
				view_forward_y,
				view_forward_z,
				TERRAIN_GENERATION_BENCHMARK_CAVE_VIEW_WIDTH,
				TERRAIN_GENERATION_BENCHMARK_CAVE_VIEW_HEIGHT,
				TERRAIN_GENERATION_BENCHMARK_CAVE_VIEW_FOV_DEGREES,
				TERRAIN_GENERATION_BENCHMARK_CAVE_VIEW_MAX_DISTANCE_BLOCKS,
				cache.count,
				hit_count,
				miss_count,
				water_hit_count,
				avg_distance,
			)
			if terrain_generation_benchmark_artifact_context == nil {
				for row := i32(0);
				    row < i32(TERRAIN_GENERATION_BENCHMARK_CAVE_VIEW_HEIGHT);
				    row += 1 {
					row_bytes: [TERRAIN_GENERATION_BENCHMARK_CAVE_VIEW_WIDTH]u8
					depth_bytes: [TERRAIN_GENERATION_BENCHMARK_CAVE_VIEW_WIDTH]u8
					for column := i32(0);
					    column < i32(TERRAIN_GENERATION_BENCHMARK_CAVE_VIEW_WIDTH);
					    column += 1 {
						pixel_index :=
							row * i32(TERRAIN_GENERATION_BENCHMARK_CAVE_VIEW_WIDTH) + column
						row_bytes[column] = pixels[pixel_index]
						depth_bytes[column] = depths[pixel_index]
					}
					log.infof(
						"TERRAIN_GENERATION_CAVE_VIEW_ROW label=%s row=%d data=%s depth=%s",
						label,
						row,
						string(row_bytes[:]),
						string(depth_bytes[:]),
					)
				}
			}
			log.infof("TERRAIN_GENERATION_CAVE_VIEW_END label=%s", label)
			terrain_generation_benchmark_cave_view_artifact_write(
				label,
				route_t,
				camera_x,
				camera_y,
				camera_z,
				view_forward_x,
				view_forward_y,
				view_forward_z,
				pixels,
				depths,
				cache.count,
				hit_count,
				miss_count,
				water_hit_count,
				avg_distance,
				allocator,
			)
		}

		terrain_generation_benchmark_cave_view_capture :: proc(
			label: string,
			edge: biomes.CaveNetworkEdge,
			route_t: f32,
			side_look_scale, up_look_scale: f32,
			seed: u32,
			transient_arena: ^mem.Arena,
		) {
			temp := mem.begin_arena_temp_memory(transient_arena)
			defer mem.end_arena_temp_memory(temp)
			allocator := mem.arena_allocator(transient_arena)
			cache := TerrainGenerationBenchmarkCaveSliceChunkCache{}
			pixels := new(TerrainGenerationBenchmarkCaveViewPixels, allocator)
			depths := new(TerrainGenerationBenchmarkCaveViewPixels, allocator)

			route_x, route_y, route_z := terrain_density_cave_edge_route_point(edge, route_t)
			tangent_x, tangent_y, tangent_z, side_x, side_y, side_z, up_x, up_y, up_z :=
				terrain_generation_benchmark_cave_route_frame(edge, route_t)

			camera_back := math.max(f32(12), edge.radius_blocks * f32(1.35))
			camera_lift := math.max(f32(2), edge.radius_blocks * f32(0.18))
			camera_x := route_x - tangent_x * camera_back + up_x * camera_lift
			camera_y := route_y - tangent_y * camera_back + up_y * camera_lift
			camera_z := route_z - tangent_z * camera_back + up_z * camera_lift

			forward_x := tangent_x + side_x * side_look_scale + up_x * up_look_scale
			forward_y := tangent_y + side_y * side_look_scale + up_y * up_look_scale
			forward_z := tangent_z + side_z * side_look_scale + up_z * up_look_scale
			forward_len := math.sqrt_f32(
				forward_x * forward_x + forward_y * forward_y + forward_z * forward_z,
			)
			if forward_len <= 0.001 {
				forward_x, forward_y, forward_z = tangent_x, tangent_y, tangent_z
			} else {
				forward_x /= forward_len
				forward_y /= forward_len
				forward_z /= forward_len
			}

			right_x := side_x
			right_y := side_y
			right_z := side_z
			right_dot := right_x * forward_x + right_y * forward_y + right_z * forward_z
			right_x -= forward_x * right_dot
			right_y -= forward_y * right_dot
			right_z -= forward_z * right_dot
			right_len := math.sqrt_f32(right_x * right_x + right_y * right_y + right_z * right_z)
			if right_len <= 0.001 {
				right_x, right_y, right_z = side_x, side_y, side_z
			} else {
				right_x /= right_len
				right_y /= right_len
				right_z /= right_len
			}

			view_up_x := right_y * forward_z - right_z * forward_y
			view_up_y := right_z * forward_x - right_x * forward_z
			view_up_z := right_x * forward_y - right_y * forward_x
			view_up_len := math.sqrt_f32(
				view_up_x * view_up_x + view_up_y * view_up_y + view_up_z * view_up_z,
			)
			if view_up_len <= 0.001 {
				view_up_x, view_up_y, view_up_z = up_x, up_y, up_z
			} else {
				view_up_x /= view_up_len
				view_up_y /= view_up_len
				view_up_z /= view_up_len
			}

			fov_radians := math.to_radians_f32(TERRAIN_GENERATION_BENCHMARK_CAVE_VIEW_FOV_DEGREES)
			tan_y := math.tan_f32(fov_radians * f32(0.5))
			aspect :=
				f32(TERRAIN_GENERATION_BENCHMARK_CAVE_VIEW_WIDTH) /
				f32(TERRAIN_GENERATION_BENCHMARK_CAVE_VIEW_HEIGHT)
			tan_x := tan_y * aspect

			hit_count: u32
			miss_count: u32
			water_hit_count: u32
			distance_sum := f32(0)
			for row := i32(0); row < i32(TERRAIN_GENERATION_BENCHMARK_CAVE_VIEW_HEIGHT); row += 1 {
				screen_y :=
					(1.0 -
						((f32(row) + f32(0.5)) /
								f32(TERRAIN_GENERATION_BENCHMARK_CAVE_VIEW_HEIGHT)) *
							f32(2.0)) *
					tan_y
				for column := i32(0);
				    column < i32(TERRAIN_GENERATION_BENCHMARK_CAVE_VIEW_WIDTH);
				    column += 1 {
					screen_x :=
						(((f32(column) + f32(0.5)) /
									f32(TERRAIN_GENERATION_BENCHMARK_CAVE_VIEW_WIDTH)) *
								f32(2.0) -
							1.0) *
						tan_x
					dir_x := forward_x + right_x * screen_x + view_up_x * screen_y
					dir_y := forward_y + right_y * screen_x + view_up_y * screen_y
					dir_z := forward_z + right_z * screen_x + view_up_z * screen_y
					dir_len := math.sqrt_f32(dir_x * dir_x + dir_y * dir_y + dir_z * dir_z)
					if dir_len > 0.001 {
						dir_x /= dir_len
						dir_y /= dir_len
						dir_z /= dir_len
					}
					pixel, depth, distance, hit :=
						terrain_generation_benchmark_cave_view_ray_sample(
							&cache,
							camera_x,
							camera_y,
							camera_z,
							dir_x,
							dir_y,
							dir_z,
							seed,
							allocator,
						)
					pixel_index := row * i32(TERRAIN_GENERATION_BENCHMARK_CAVE_VIEW_WIDTH) + column
					pixels[pixel_index] = pixel
					depths[pixel_index] = depth
					if hit {
						hit_count += 1
						distance_sum += distance
						if pixel == '~' {
							water_hit_count += 1
						}
					} else {
						miss_count += 1
					}
				}
			}
			avg_distance := f32(0)
			if hit_count > 0 {
				avg_distance = distance_sum / f32(hit_count)
			}
			log.infof(
				"TERRAIN_GENERATION_CAVE_VIEW_BEGIN label=%s route_t=%.3f camera=(%.2f,%.2f,%.2f) forward=(%.3f,%.3f,%.3f) width=%d height=%d fov=%.1f max_distance=%.1f chunks=%d hits=%d misses=%d water_hits=%d avg_hit_distance=%.2f",
				label,
				route_t,
				camera_x,
				camera_y,
				camera_z,
				forward_x,
				forward_y,
				forward_z,
				TERRAIN_GENERATION_BENCHMARK_CAVE_VIEW_WIDTH,
				TERRAIN_GENERATION_BENCHMARK_CAVE_VIEW_HEIGHT,
				TERRAIN_GENERATION_BENCHMARK_CAVE_VIEW_FOV_DEGREES,
				TERRAIN_GENERATION_BENCHMARK_CAVE_VIEW_MAX_DISTANCE_BLOCKS,
				cache.count,
				hit_count,
				miss_count,
				water_hit_count,
				avg_distance,
			)
			if terrain_generation_benchmark_artifact_context == nil {
				for row := i32(0);
				    row < i32(TERRAIN_GENERATION_BENCHMARK_CAVE_VIEW_HEIGHT);
				    row += 1 {
					row_bytes: [TERRAIN_GENERATION_BENCHMARK_CAVE_VIEW_WIDTH]u8
					depth_bytes: [TERRAIN_GENERATION_BENCHMARK_CAVE_VIEW_WIDTH]u8
					for column := i32(0);
					    column < i32(TERRAIN_GENERATION_BENCHMARK_CAVE_VIEW_WIDTH);
					    column += 1 {
						pixel_index :=
							row * i32(TERRAIN_GENERATION_BENCHMARK_CAVE_VIEW_WIDTH) + column
						row_bytes[column] = pixels[pixel_index]
						depth_bytes[column] = depths[pixel_index]
					}
					log.infof(
						"TERRAIN_GENERATION_CAVE_VIEW_ROW label=%s row=%d data=%s depth=%s",
						label,
						row,
						string(row_bytes[:]),
						string(depth_bytes[:]),
					)
				}
			}
			log.infof("TERRAIN_GENERATION_CAVE_VIEW_END label=%s", label)
			terrain_generation_benchmark_cave_view_artifact_write(
				label,
				route_t,
				camera_x,
				camera_y,
				camera_z,
				forward_x,
				forward_y,
				forward_z,
				pixels,
				depths,
				cache.count,
				hit_count,
				miss_count,
				water_hit_count,
				avg_distance,
				allocator,
			)
		}

		terrain_generation_benchmark_cave_route_slice_block_coord :: proc(
			edge: biomes.CaveNetworkEdge,
			mode: TerrainGenerationBenchmarkCaveSliceMode,
			column, row: i32,
		) -> world_async.BlockCoord {
			width_max := f32(TERRAIN_GENERATION_BENCHMARK_CAVE_SLICE_WIDTH - 1)
			t := math.clamp(f32(column) / width_max, f32(0), f32(1))
			center_x, center_y, center_z := terrain_density_cave_edge_route_point(edge, t)
			_, _, _, side_x, side_y, side_z, up_x, up_y, up_z :=
				terrain_generation_benchmark_cave_route_frame(edge, t)

			half_height := i32(TERRAIN_GENERATION_BENCHMARK_CAVE_SLICE_HEIGHT / 2)
			offset_v := f32(
				(row - half_height) * TERRAIN_GENERATION_BENCHMARK_CAVE_SLICE_STEP_BLOCKS,
			)
			axis_v_x := up_x
			axis_v_y := up_y
			axis_v_z := up_z
			if mode == .Route_Plan {
				axis_v_x = side_x
				axis_v_y = side_y
				axis_v_z = side_z
			} else if mode == .Route_Oblique {
				axis_v_x = side_x * f32(0.68) + up_x * f32(0.74)
				axis_v_y = side_y * f32(0.68) + up_y * f32(0.74)
				axis_v_z = side_z * f32(0.68) + up_z * f32(0.74)
				axis_length := math.sqrt_f32(
					axis_v_x * axis_v_x + axis_v_y * axis_v_y + axis_v_z * axis_v_z,
				)
				if axis_length > 0.001 {
					axis_v_x /= axis_length
					axis_v_y /= axis_length
					axis_v_z /= axis_length
				}
			}

			return {
				x = terrain_generation_benchmark_floor_i32(center_x - axis_v_x * offset_v),
				y = terrain_generation_benchmark_floor_i32(center_y - axis_v_y * offset_v),
				z = terrain_generation_benchmark_floor_i32(center_z - axis_v_z * offset_v),
			}
		}

		terrain_generation_benchmark_cave_route_slice_capture :: proc(
			label: string,
			edge: biomes.CaveNetworkEdge,
			mode: TerrainGenerationBenchmarkCaveSliceMode,
			seed: u32,
			transient_arena: ^mem.Arena,
		) {
			temp := mem.begin_arena_temp_memory(transient_arena)
			defer mem.end_arena_temp_memory(temp)
			allocator := mem.arena_allocator(transient_arena)
			cache := TerrainGenerationBenchmarkCaveSliceChunkCache{}
			pixels := new(TerrainGenerationBenchmarkCaveSlicePixels, allocator)
			center_x, center_y, center_z := terrain_density_cave_edge_route_point(edge, 0.5)
			center := world_async.BlockCoord {
				x = terrain_generation_benchmark_floor_i32(center_x),
				y = terrain_generation_benchmark_floor_i32(center_y),
				z = terrain_generation_benchmark_floor_i32(center_z),
			}

			open_count: u32
			water_count: u32
			solid_count: u32
			for row := i32(0);
			    row < i32(TERRAIN_GENERATION_BENCHMARK_CAVE_SLICE_HEIGHT);
			    row += 1 {
				for column := i32(0);
				    column < i32(TERRAIN_GENERATION_BENCHMARK_CAVE_SLICE_WIDTH);
				    column += 1 {
					block := terrain_generation_benchmark_cave_route_slice_block_coord(
						edge,
						mode,
						column,
						row,
					)
					chunk_coord := chunk_coord_from_block_coord(block)
					view := terrain_generation_benchmark_cave_slice_chunk_view_get(
						&cache,
						chunk_coord,
						seed,
						allocator,
					)
					local := block_coord_local_from_chunk_coord(block, chunk_coord)
					pixel := u8('?')
					if chunk_block_coord_is_inside(local.x, local.y, local.z) {
						pixel = terrain_generation_benchmark_cave_slice_pixel(view, local)
					}
					pixel_index :=
						row * i32(TERRAIN_GENERATION_BENCHMARK_CAVE_SLICE_WIDTH) + column
					pixels[pixel_index] = pixel
					if pixel == '.' {
						open_count += 1
					} else if pixel == '~' {
						water_count += 1
					} else {
						solid_count += 1
					}
				}
			}

			log.infof(
				"TERRAIN_GENERATION_CAVE_SLICE_BEGIN label=%s mode=%v center=(%d,%d,%d) width=%d height=%d step=%d chunks=%d open=%d water=%d solid=%d",
				label,
				mode,
				center.x,
				center.y,
				center.z,
				TERRAIN_GENERATION_BENCHMARK_CAVE_SLICE_WIDTH,
				TERRAIN_GENERATION_BENCHMARK_CAVE_SLICE_HEIGHT,
				TERRAIN_GENERATION_BENCHMARK_CAVE_SLICE_STEP_BLOCKS,
				cache.count,
				open_count,
				water_count,
				solid_count,
			)
			if terrain_generation_benchmark_artifact_context == nil {
				for row := i32(0);
				    row < i32(TERRAIN_GENERATION_BENCHMARK_CAVE_SLICE_HEIGHT);
				    row += 1 {
					row_bytes: [TERRAIN_GENERATION_BENCHMARK_CAVE_SLICE_WIDTH]u8
					for column := i32(0);
					    column < i32(TERRAIN_GENERATION_BENCHMARK_CAVE_SLICE_WIDTH);
					    column += 1 {
						pixel_index :=
							row * i32(TERRAIN_GENERATION_BENCHMARK_CAVE_SLICE_WIDTH) + column
						row_bytes[column] = pixels[pixel_index]
					}
					log.infof(
						"TERRAIN_GENERATION_CAVE_SLICE_ROW label=%s mode=%v row=%d data=%s",
						label,
						mode,
						row,
						string(row_bytes[:]),
					)
				}
			}
			log.infof("TERRAIN_GENERATION_CAVE_SLICE_END label=%s mode=%v", label, mode)
			terrain_generation_benchmark_cave_slice_artifact_write(
				label,
				mode,
				center,
				pixels,
				cache.count,
				open_count,
				water_count,
				solid_count,
				allocator,
			)
		}

		terrain_generation_benchmark_mouth_transition_slice_block_coord :: proc(
			anchor: biomes.CaveAnchor,
			node: biomes.CaveNetworkNode,
			plan: TerrainCaveMouthTransitionPlan,
			mode: TerrainGenerationBenchmarkCaveSliceMode,
			column, row: i32,
		) -> world_async.BlockCoord {
			width_max := f32(TERRAIN_GENERATION_BENCHMARK_CAVE_SLICE_WIDTH - 1)
			route_t := math.clamp(f32(column) / width_max, f32(0), f32(1))

			near_dx := plan.landing_x - anchor.x
			near_dy := plan.landing_y - anchor.y
			near_dz := plan.landing_z - anchor.z
			bend_dx := plan.bend_x - plan.landing_x
			bend_dy := plan.bend_y - plan.landing_y
			bend_dz := plan.bend_z - plan.landing_z
			handoff_dx := node.x - plan.bend_x
			handoff_dy := node.y - plan.bend_y
			handoff_dz := node.z - plan.bend_z
			near_len := math.sqrt_f32(near_dx * near_dx + near_dy * near_dy + near_dz * near_dz)
			bend_len := math.sqrt_f32(bend_dx * bend_dx + bend_dy * bend_dy + bend_dz * bend_dz)
			handoff_len := math.sqrt_f32(
				handoff_dx * handoff_dx + handoff_dy * handoff_dy + handoff_dz * handoff_dz,
			)
			total_len := math.max(f32(1), near_len + bend_len + handoff_len)
			distance := route_t * total_len

			from_x, from_y, from_z := anchor.x, anchor.y, anchor.z
			to_x, to_y, to_z := plan.landing_x, plan.landing_y, plan.landing_z
			segment_len := near_len
			if distance > segment_len && bend_len > 0.001 {
				distance -= segment_len
				from_x, from_y, from_z = plan.landing_x, plan.landing_y, plan.landing_z
				to_x, to_y, to_z = plan.bend_x, plan.bend_y, plan.bend_z
				segment_len = bend_len
			}
			if distance > segment_len && handoff_len > 0.001 {
				distance -= segment_len
				from_x, from_y, from_z = plan.bend_x, plan.bend_y, plan.bend_z
				to_x, to_y, to_z = node.x, node.y, node.z
				segment_len = handoff_len
			}
			segment_t := math.clamp(distance / math.max(f32(1), segment_len), f32(0), f32(1))
			center_x := biomes.regional_terrain_field_lerp(from_x, to_x, segment_t)
			center_y := biomes.regional_terrain_field_lerp(from_y, to_y, segment_t)
			center_z := biomes.regional_terrain_field_lerp(from_z, to_z, segment_t)

			tangent_x := to_x - from_x
			tangent_y := to_y - from_y
			tangent_z := to_z - from_z
			tangent_len := math.sqrt_f32(
				tangent_x * tangent_x + tangent_y * tangent_y + tangent_z * tangent_z,
			)
			if tangent_len > 0.001 {
				tangent_x /= tangent_len
				tangent_y /= tangent_len
				tangent_z /= tangent_len
			}

			axis_v_x, axis_v_y, axis_v_z := f32(0), f32(1), f32(0)
			if mode == .Mouth_Plan {
				horizontal_len := math.sqrt_f32(tangent_x * tangent_x + tangent_z * tangent_z)
				if horizontal_len > 0.001 {
					axis_v_x = -tangent_z / horizontal_len
					axis_v_y = 0
					axis_v_z = tangent_x / horizontal_len
				} else {
					axis_v_x = plan.side_x
					axis_v_y = 0
					axis_v_z = plan.side_z
				}
			}

			half_height := i32(TERRAIN_GENERATION_BENCHMARK_CAVE_SLICE_HEIGHT / 2)
			offset_v := f32(
				(row - half_height) * TERRAIN_GENERATION_BENCHMARK_CAVE_SLICE_STEP_BLOCKS,
			)
			return {
				x = terrain_generation_benchmark_floor_i32(center_x - axis_v_x * offset_v),
				y = terrain_generation_benchmark_floor_i32(center_y - axis_v_y * offset_v),
				z = terrain_generation_benchmark_floor_i32(center_z - axis_v_z * offset_v),
			}
		}

		terrain_generation_benchmark_mouth_aperture_slice_block_coord :: proc(
			anchor: biomes.CaveAnchor,
			node: biomes.CaveNetworkNode,
			mode: TerrainGenerationBenchmarkCaveSliceMode,
			column, row: i32,
		) -> world_async.BlockCoord {
			dir_x, dir_z := terrain_density_cave_entrance_planar_direction(anchor, node)
			side_x := -dir_z
			side_z := dir_x
			half_width := i32(TERRAIN_GENERATION_BENCHMARK_CAVE_SLICE_WIDTH / 2)
			half_height := i32(TERRAIN_GENERATION_BENCHMARK_CAVE_SLICE_HEIGHT / 2)
			offset_u := f32(
				(column - half_width) * TERRAIN_GENERATION_BENCHMARK_CAVE_SLICE_STEP_BLOCKS,
			)
			offset_v := f32(
				(row - half_height) * TERRAIN_GENERATION_BENCHMARK_CAVE_SLICE_STEP_BLOCKS,
			)
			center_x := anchor.x + dir_x * offset_u
			center_y := anchor.y
			center_z := anchor.z + dir_z * offset_u
			if mode == .Mouth_Plan {
				return {
					x = terrain_generation_benchmark_floor_i32(center_x - side_x * offset_v),
					y = terrain_generation_benchmark_floor_i32(center_y),
					z = terrain_generation_benchmark_floor_i32(center_z - side_z * offset_v),
				}
			}
			return {
				x = terrain_generation_benchmark_floor_i32(center_x),
				y = terrain_generation_benchmark_floor_i32(center_y - offset_v),
				z = terrain_generation_benchmark_floor_i32(center_z),
			}
		}

		terrain_generation_benchmark_mouth_transition_slice_capture :: proc(
			label: string,
			anchor: biomes.CaveAnchor,
			node: biomes.CaveNetworkNode,
			mode: TerrainGenerationBenchmarkCaveSliceMode,
			center_on_aperture: bool,
			seed: u32,
			transient_arena: ^mem.Arena,
		) {
			temp := mem.begin_arena_temp_memory(transient_arena)
			defer mem.end_arena_temp_memory(temp)
			allocator := mem.arena_allocator(transient_arena)
			cache := TerrainGenerationBenchmarkCaveSliceChunkCache{}
			pixels := new(TerrainGenerationBenchmarkCaveSlicePixels, allocator)
			opening_radius := math.max(f32(4), anchor.influence_radius_blocks)
			anchor_radius := math.max(f32(3), anchor.influence_radius_blocks * 0.55)
			link_radius := math.max(
				f32(3),
				math.min(anchor_radius * 0.75, node.connection_radius_blocks),
			)
			plan := terrain_density_cave_mouth_transition_plan(
				anchor,
				node,
				opening_radius,
				link_radius,
			)
			center := world_async.BlockCoord {
				x = terrain_generation_benchmark_floor_i32(plan.bend_x),
				y = terrain_generation_benchmark_floor_i32(plan.bend_y),
				z = terrain_generation_benchmark_floor_i32(plan.bend_z),
			}
			if center_on_aperture {
				center = {
					x = terrain_generation_benchmark_floor_i32(anchor.x),
					y = terrain_generation_benchmark_floor_i32(anchor.y),
					z = terrain_generation_benchmark_floor_i32(anchor.z),
				}
			}

			open_count: u32
			water_count: u32
			solid_count: u32
			for row := i32(0);
			    row < i32(TERRAIN_GENERATION_BENCHMARK_CAVE_SLICE_HEIGHT);
			    row += 1 {
				for column := i32(0);
				    column < i32(TERRAIN_GENERATION_BENCHMARK_CAVE_SLICE_WIDTH);
				    column += 1 {
					block := terrain_generation_benchmark_mouth_transition_slice_block_coord(
						anchor,
						node,
						plan,
						mode,
						column,
						row,
					)
					if center_on_aperture {
						block = terrain_generation_benchmark_mouth_aperture_slice_block_coord(
							anchor,
							node,
							mode,
							column,
							row,
						)
					}
					chunk_coord := chunk_coord_from_block_coord(block)
					view := terrain_generation_benchmark_cave_slice_chunk_view_get(
						&cache,
						chunk_coord,
						seed,
						allocator,
					)
					local := block_coord_local_from_chunk_coord(block, chunk_coord)
					pixel := u8('?')
					if chunk_block_coord_is_inside(local.x, local.y, local.z) {
						pixel = terrain_generation_benchmark_cave_slice_pixel(view, local)
					}
					pixel_index :=
						row * i32(TERRAIN_GENERATION_BENCHMARK_CAVE_SLICE_WIDTH) + column
					pixels[pixel_index] = pixel
					if pixel == '.' {
						open_count += 1
					} else if pixel == '~' {
						water_count += 1
					} else {
						solid_count += 1
					}
				}
			}

			log.infof(
				"TERRAIN_GENERATION_CAVE_SLICE_BEGIN label=%s mode=%v center=(%d,%d,%d) width=%d height=%d step=%d chunks=%d open=%d water=%d solid=%d",
				label,
				mode,
				center.x,
				center.y,
				center.z,
				TERRAIN_GENERATION_BENCHMARK_CAVE_SLICE_WIDTH,
				TERRAIN_GENERATION_BENCHMARK_CAVE_SLICE_HEIGHT,
				TERRAIN_GENERATION_BENCHMARK_CAVE_SLICE_STEP_BLOCKS,
				cache.count,
				open_count,
				water_count,
				solid_count,
			)
			if terrain_generation_benchmark_artifact_context == nil {
				for row := i32(0);
				    row < i32(TERRAIN_GENERATION_BENCHMARK_CAVE_SLICE_HEIGHT);
				    row += 1 {
					row_bytes: [TERRAIN_GENERATION_BENCHMARK_CAVE_SLICE_WIDTH]u8
					for column := i32(0);
					    column < i32(TERRAIN_GENERATION_BENCHMARK_CAVE_SLICE_WIDTH);
					    column += 1 {
						pixel_index :=
							row * i32(TERRAIN_GENERATION_BENCHMARK_CAVE_SLICE_WIDTH) + column
						row_bytes[column] = pixels[pixel_index]
					}
					log.infof(
						"TERRAIN_GENERATION_CAVE_SLICE_ROW label=%s mode=%v row=%d data=%s",
						label,
						mode,
						row,
						string(row_bytes[:]),
					)
				}
			}
			log.infof("TERRAIN_GENERATION_CAVE_SLICE_END label=%s mode=%v", label, mode)
			terrain_generation_benchmark_cave_slice_artifact_write(
				label,
				mode,
				center,
				pixels,
				cache.count,
				open_count,
				water_count,
				solid_count,
				allocator,
			)
		}

		terrain_generation_benchmark_cave_slice_capture_basis :: proc(
			label: string,
			mode: TerrainGenerationBenchmarkCaveSliceMode,
			center_x, center_y, center_z: f32,
			axis_u_x, axis_u_y, axis_u_z: f32,
			axis_v_x, axis_v_y, axis_v_z: f32,
			seed: u32,
			transient_arena: ^mem.Arena,
		) {
			temp := mem.begin_arena_temp_memory(transient_arena)
			defer mem.end_arena_temp_memory(temp)
			allocator := mem.arena_allocator(transient_arena)
			cache := TerrainGenerationBenchmarkCaveSliceChunkCache{}
			pixels := new(TerrainGenerationBenchmarkCaveSlicePixels, allocator)
			center := world_async.BlockCoord {
				x = terrain_generation_benchmark_floor_i32(center_x),
				y = terrain_generation_benchmark_floor_i32(center_y),
				z = terrain_generation_benchmark_floor_i32(center_z),
			}

			open_count: u32
			water_count: u32
			solid_count: u32
			for row := i32(0);
			    row < i32(TERRAIN_GENERATION_BENCHMARK_CAVE_SLICE_HEIGHT);
			    row += 1 {
				for column := i32(0);
				    column < i32(TERRAIN_GENERATION_BENCHMARK_CAVE_SLICE_WIDTH);
				    column += 1 {
					block := terrain_generation_benchmark_cave_slice_basis_block_coord(
						center_x,
						center_y,
						center_z,
						axis_u_x,
						axis_u_y,
						axis_u_z,
						axis_v_x,
						axis_v_y,
						axis_v_z,
						column,
						row,
					)
					chunk_coord := chunk_coord_from_block_coord(block)
					view := terrain_generation_benchmark_cave_slice_chunk_view_get(
						&cache,
						chunk_coord,
						seed,
						allocator,
					)
					local := block_coord_local_from_chunk_coord(block, chunk_coord)
					pixel := u8('?')
					if chunk_block_coord_is_inside(local.x, local.y, local.z) {
						pixel = terrain_generation_benchmark_cave_slice_pixel(view, local)
					}
					pixel_index :=
						row * i32(TERRAIN_GENERATION_BENCHMARK_CAVE_SLICE_WIDTH) + column
					pixels[pixel_index] = pixel
					if pixel == '.' {
						open_count += 1
					} else if pixel == '~' {
						water_count += 1
					} else {
						solid_count += 1
					}
				}
			}

			log.infof(
				"TERRAIN_GENERATION_CAVE_SLICE_BEGIN label=%s mode=%v center=(%d,%d,%d) width=%d height=%d step=%d chunks=%d open=%d water=%d solid=%d",
				label,
				mode,
				center.x,
				center.y,
				center.z,
				TERRAIN_GENERATION_BENCHMARK_CAVE_SLICE_WIDTH,
				TERRAIN_GENERATION_BENCHMARK_CAVE_SLICE_HEIGHT,
				TERRAIN_GENERATION_BENCHMARK_CAVE_SLICE_STEP_BLOCKS,
				cache.count,
				open_count,
				water_count,
				solid_count,
			)
			if terrain_generation_benchmark_artifact_context == nil {
				for row := i32(0);
				    row < i32(TERRAIN_GENERATION_BENCHMARK_CAVE_SLICE_HEIGHT);
				    row += 1 {
					row_bytes: [TERRAIN_GENERATION_BENCHMARK_CAVE_SLICE_WIDTH]u8
					for column := i32(0);
					    column < i32(TERRAIN_GENERATION_BENCHMARK_CAVE_SLICE_WIDTH);
					    column += 1 {
						pixel_index :=
							row * i32(TERRAIN_GENERATION_BENCHMARK_CAVE_SLICE_WIDTH) + column
						row_bytes[column] = pixels[pixel_index]
					}
					log.infof(
						"TERRAIN_GENERATION_CAVE_SLICE_ROW label=%s mode=%v row=%d data=%s",
						label,
						mode,
						row,
						string(row_bytes[:]),
					)
				}
			}
			log.infof("TERRAIN_GENERATION_CAVE_SLICE_END label=%s mode=%v", label, mode)
			terrain_generation_benchmark_cave_slice_artifact_write(
				label,
				mode,
				center,
				pixels,
				cache.count,
				open_count,
				water_count,
				solid_count,
				allocator,
			)
		}

		terrain_generation_benchmark_cave_slice_capture :: proc(
			label: string,
			node: biomes.CaveNetworkNode,
			mode: TerrainGenerationBenchmarkCaveSliceMode,
			seed: u32,
			transient_arena: ^mem.Arena,
		) {
			temp := mem.begin_arena_temp_memory(transient_arena)
			defer mem.end_arena_temp_memory(temp)
			allocator := mem.arena_allocator(transient_arena)
			cache := TerrainGenerationBenchmarkCaveSliceChunkCache{}
			pixels := new(TerrainGenerationBenchmarkCaveSlicePixels, allocator)
			center := world_async.BlockCoord {
				x = terrain_generation_benchmark_floor_i32(node.x),
				y = terrain_generation_benchmark_floor_i32(node.y),
				z = terrain_generation_benchmark_floor_i32(node.z),
			}

			open_count: u32
			water_count: u32
			solid_count: u32
			for row := i32(0);
			    row < i32(TERRAIN_GENERATION_BENCHMARK_CAVE_SLICE_HEIGHT);
			    row += 1 {
				for column := i32(0);
				    column < i32(TERRAIN_GENERATION_BENCHMARK_CAVE_SLICE_WIDTH);
				    column += 1 {
					block := terrain_generation_benchmark_cave_slice_block_coord(
						center,
						mode,
						column,
						row,
					)
					chunk_coord := chunk_coord_from_block_coord(block)
					view := terrain_generation_benchmark_cave_slice_chunk_view_get(
						&cache,
						chunk_coord,
						seed,
						allocator,
					)
					local := block_coord_local_from_chunk_coord(block, chunk_coord)
					pixel := u8('?')
					if chunk_block_coord_is_inside(local.x, local.y, local.z) {
						pixel = terrain_generation_benchmark_cave_slice_pixel(view, local)
					}
					pixel_index :=
						row * i32(TERRAIN_GENERATION_BENCHMARK_CAVE_SLICE_WIDTH) + column
					pixels[pixel_index] = pixel
					if pixel == '.' {
						open_count += 1
					} else if pixel == '~' {
						water_count += 1
					} else {
						solid_count += 1
					}
				}
			}

			log.infof(
				"TERRAIN_GENERATION_CAVE_SLICE_BEGIN label=%s mode=%v center=(%d,%d,%d) width=%d height=%d step=%d chunks=%d open=%d water=%d solid=%d",
				label,
				mode,
				center.x,
				center.y,
				center.z,
				TERRAIN_GENERATION_BENCHMARK_CAVE_SLICE_WIDTH,
				TERRAIN_GENERATION_BENCHMARK_CAVE_SLICE_HEIGHT,
				TERRAIN_GENERATION_BENCHMARK_CAVE_SLICE_STEP_BLOCKS,
				cache.count,
				open_count,
				water_count,
				solid_count,
			)
			if terrain_generation_benchmark_artifact_context == nil {
				for row := i32(0);
				    row < i32(TERRAIN_GENERATION_BENCHMARK_CAVE_SLICE_HEIGHT);
				    row += 1 {
					row_bytes: [TERRAIN_GENERATION_BENCHMARK_CAVE_SLICE_WIDTH]u8
					for column := i32(0);
					    column < i32(TERRAIN_GENERATION_BENCHMARK_CAVE_SLICE_WIDTH);
					    column += 1 {
						pixel_index :=
							row * i32(TERRAIN_GENERATION_BENCHMARK_CAVE_SLICE_WIDTH) + column
						row_bytes[column] = pixels[pixel_index]
					}
					log.infof(
						"TERRAIN_GENERATION_CAVE_SLICE_ROW label=%s mode=%v row=%d data=%s",
						label,
						mode,
						row,
						string(row_bytes[:]),
					)
				}
			}
			log.infof("TERRAIN_GENERATION_CAVE_SLICE_END label=%s mode=%v", label, mode)
			terrain_generation_benchmark_cave_slice_artifact_write(
				label,
				mode,
				center,
				pixels,
				cache.count,
				open_count,
				water_count,
				solid_count,
				allocator,
			)
		}

		terrain_generation_benchmark_cave_route_edge_select :: proc(
			key: biomes.FeatureGridKey,
			selection: TerrainGenerationBenchmarkCaveSelection,
		) -> (
			best_edge: biomes.CaveNetworkEdge,
			found: bool,
		) {
			origin := chunk_origin_from_coord(selection.chunk)
			region_coord := biomes.generation_region_coord_from_block(origin.x, origin.y, origin.z)
			region := terrain_generation_region_for_fill(key, region_coord)
			best_score := -max(f32)
			for i := u32(0); i < region.cave_network_edge_count; i += 1 {
				edge := region.cave_network_edges[i]
				if edge.from_node_id != selection.node.id && edge.to_node_id != selection.node.id {
					continue
				}
				if edge.kind == .Vertical_Shaft {
					continue
				}
				dx := edge.to_x - edge.from_x
				dy := edge.to_y - edge.from_y
				dz := edge.to_z - edge.from_z
				length := math.sqrt_f32(dx * dx + dy * dy + dz * dz)
				if length <= 0.001 {
					continue
				}
				vertical_fraction := math.abs(dy) / length
				if vertical_fraction > 0.48 {
					continue
				}
				score := edge.radius_blocks * 8.0 + length * 0.04 - vertical_fraction * 24.0
				if edge.from_biome_id == selection.node.biome_id &&
				   edge.to_biome_id == selection.node.biome_id {
					score += 18.0
				}
				if edge.kind == .Worm_Path {
					score += 12.0
				}
				if edge.guaranteed_connection {
					score += 4.0
				}
				if score > best_score {
					best_edge = edge
					best_score = score
					found = true
				}
			}
			return
		}

		terrain_generation_benchmark_cave_route_slice_capture_for_selection :: proc(
			label: string,
			selection: TerrainGenerationBenchmarkCaveSelection,
			key: biomes.FeatureGridKey,
			seed: u32,
			transient_arena: ^mem.Arena,
		) {
			if !selection.found_matching_biome {
				log.infof("TERRAIN_GENERATION_CAVE_ROUTE_SLICE_SKIP label=%s", label)
				return
			}
			edge, edge_found := terrain_generation_benchmark_cave_route_edge_select(key, selection)
			if !edge_found {
				log.infof("TERRAIN_GENERATION_CAVE_ROUTE_SLICE_SKIP label=%s", label)
				return
			}

			center_x, center_y, center_z := terrain_density_cave_edge_route_point(edge, 0.5)
			prev_x, prev_y, prev_z := terrain_density_cave_edge_route_point(edge, 0.42)
			next_x, next_y, next_z := terrain_density_cave_edge_route_point(edge, 0.58)
			tangent_x, tangent_y, tangent_z := terrain_density_delta_3(
				prev_x,
				prev_y,
				prev_z,
				next_x,
				next_y,
				next_z,
			)
			tangent_length := math.sqrt_f32(
				tangent_x * tangent_x + tangent_y * tangent_y + tangent_z * tangent_z,
			)
			if tangent_length <= 0.001 {
				log.infof("TERRAIN_GENERATION_CAVE_ROUTE_SLICE_SKIP label=%s", label)
				return
			}
			tangent_x /= tangent_length
			tangent_y /= tangent_length
			tangent_z /= tangent_length

			horizontal_length := math.sqrt_f32(tangent_x * tangent_x + tangent_z * tangent_z)
			side_x := f32(1)
			side_y := f32(0)
			side_z := f32(0)
			if horizontal_length > 0.001 {
				side_x = -tangent_z / horizontal_length
				side_z = tangent_x / horizontal_length
			}
			up_x := side_y * tangent_z - side_z * tangent_y
			up_y := side_z * tangent_x - side_x * tangent_z
			up_z := side_x * tangent_y - side_y * tangent_x
			up_length := math.sqrt_f32(up_x * up_x + up_y * up_y + up_z * up_z)
			if up_length <= 0.001 {
				up_x, up_y, up_z = 0, 1, 0
			} else {
				up_x /= up_length
				up_y /= up_length
				up_z /= up_length
			}

			route_dx := edge.to_x - edge.from_x
			route_dy := edge.to_y - edge.from_y
			route_dz := edge.to_z - edge.from_z
			route_length := math.sqrt_f32(
				route_dx * route_dx + route_dy * route_dy + route_dz * route_dz,
			)
			log.infof(
				"TERRAIN_GENERATION_CAVE_ROUTE_SLICE_SELECTION label=%s edge=%d kind=%v radius=%.2f length=%.2f center=(%.2f,%.2f,%.2f) from_biome=%v to_biome=%v",
				label,
				edge.id,
				edge.kind,
				edge.radius_blocks,
				route_length,
				center_x,
				center_y,
				center_z,
				edge.from_biome_id,
				edge.to_biome_id,
			)
			terrain_generation_benchmark_cave_route_slice_capture(
				label,
				edge,
				.Route_Longitudinal,
				seed,
				transient_arena,
			)
			terrain_generation_benchmark_cave_slice_capture_basis(
				label,
				.Route_Cross_Section,
				center_x,
				center_y,
				center_z,
				side_x,
				side_y,
				side_z,
				up_x,
				up_y,
				up_z,
				seed,
				transient_arena,
			)
			terrain_generation_benchmark_cave_route_slice_capture(
				label,
				edge,
				.Route_Oblique,
				seed,
				transient_arena,
			)
			terrain_generation_benchmark_cave_route_slice_capture(
				label,
				edge,
				.Route_Plan,
				seed,
				transient_arena,
			)
		}

		TerrainGenerationBenchmarkCaveChamberletChainSelection :: struct {
			found:                                    bool,
			edge:                                     biomes.CaveNetworkEdge,
			chamberlet_index:                         u32,
			detail_index:                             u32,
			center_x, center_y, center_z:             f32,
			route_x, route_y, route_z:                f32,
			chamberlet_x, chamberlet_y, chamberlet_z: f32,
			axis_x, axis_y, axis_z:                   f32,
			plan_axis_x, plan_axis_z:                 f32,
			plan_side_x, plan_side_z:                 f32,
			loop_radius:                              f32,
			detail_radius:                            f32,
			chain_length:                             f32,
			route_radius:                             f32,
			biome_id:                                 biomes.BiomeID,
			score:                                    f32,
		}

		terrain_generation_benchmark_cave_chamberlet_chain_select :: proc(
			key: biomes.FeatureGridKey,
			selection: TerrainGenerationBenchmarkCaveSelection,
		) -> (
			best: TerrainGenerationBenchmarkCaveChamberletChainSelection,
		) {
			if !selection.found_matching_biome {
				return
			}
			edge, edge_found := terrain_generation_benchmark_cave_route_edge_select(key, selection)
			if !edge_found {
				return
			}

			best_score := -max(f32)
			route_radius := math.max(f32(1), edge.radius_blocks)
			for chamberlet_index := u32(0);
			    chamberlet_index < TERRAIN_CAVE_EDGE_CHAMBERLET_COUNT;
			    chamberlet_index += 1 {
				hash := biomes.feature_grid_hash_combine(
					u64(edge.id),
					TERRAIN_CAVE_ROOM_DETAIL_SALT,
				)
				hash = biomes.feature_grid_hash_combine(hash, u64(chamberlet_index))
				step_t := (f32(chamberlet_index) + 0.5) / f32(TERRAIN_CAVE_EDGE_CHAMBERLET_COUNT)
				jitter :=
					biomes.feature_grid_signed_unit_f32(hash, TERRAIN_CAVE_CURVE_SALT) * f32(0.055)
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
				tangent_x, tangent_y, tangent_z := terrain_density_delta_3(
					prev_x,
					prev_y,
					prev_z,
					next_x,
					next_y,
					next_z,
				)
				tangent_len := math.sqrt_f32(
					tangent_x * tangent_x + tangent_y * tangent_y + tangent_z * tangent_z,
				)
				if tangent_len > 0.001 {
					tangent_x /= tangent_len
					tangent_y /= tangent_len
					tangent_z /= tangent_len
				} else {
					tangent_x, tangent_y, tangent_z = 1, 0, 0
				}
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
				side_offset :=
					route_radius *
					TERRAIN_CAVE_EDGE_CHAMBERLET_SIDE_OFFSET_SCALE *
					biomes.regional_terrain_field_lerp(
						f32(0.72),
						f32(1.14),
						biomes.feature_grid_unit_f32(hash, TERRAIN_CAVE_FIELD_DETAIL_SALT),
					)
				chamberlet_x := route_x + side_x * side_offset
				chamberlet_y :=
					route_y +
					biomes.feature_grid_signed_unit_f32(hash, TERRAIN_CAVE_BRANCH_SALT) *
						route_radius *
						f32(0.16)
				chamberlet_z := route_z + side_z * side_offset
				biome_id := edge.from_biome_id
				if t >= 0.5 {
					biome_id = edge.to_biome_id
				}

				previous_detail_found := false
				previous_detail_x := f32(0)
				previous_detail_y := f32(0)
				previous_detail_z := f32(0)
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
					if biomes.feature_grid_signed_unit_f32(detail_hash, TERRAIN_CAVE_CURVE_SALT) <
					   0 {
						forward_sign = -forward_sign
					}
					dir_x :=
						side_x *
							biomes.regional_terrain_field_lerp(
								f32(0.62),
								f32(0.92),
								biomes.feature_grid_unit_f32(
									detail_hash,
									TERRAIN_CAVE_FIELD_DETAIL_SALT,
								),
							) +
						forward_x * forward_sign * f32(0.38)
					dir_z :=
						side_z *
							biomes.regional_terrain_field_lerp(
								f32(0.62),
								f32(0.92),
								biomes.feature_grid_unit_f32(
									detail_hash,
									TERRAIN_CAVE_FIELD_DETAIL_SALT,
								),
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
							biomes.feature_grid_unit_f32(
								detail_hash,
								TERRAIN_CAVE_PASSAGE_RIB_SALT,
							),
						)
					detail_x := chamberlet_x + dir_x * offset
					detail_y :=
						chamberlet_y +
						biomes.feature_grid_signed_unit_f32(
								detail_hash,
								TERRAIN_CAVE_BRANCH_SALT,
							) *
							radius_base *
							f32(0.22)
					detail_z := chamberlet_z + dir_z * offset

					if previous_detail_found {
						loop_radius := math.max(
							f32(1.20),
							math.min(
								math.min(previous_detail_radius, detail_radius) *
								TERRAIN_CAVE_EDGE_CHAMBERLET_DETAIL_LOOP_RADIUS_SCALE,
								route_radius *
								TERRAIN_CAVE_EDGE_CHAMBERLET_DETAIL_LOOP_ROUTE_CAP_SCALE,
							),
						)
						chain_dx := detail_x - previous_detail_x
						chain_dy := detail_y - previous_detail_y
						chain_dz := detail_z - previous_detail_z
						chain_length := math.sqrt_f32(
							chain_dx * chain_dx + chain_dy * chain_dy + chain_dz * chain_dz,
						)
						if chain_length > 0.001 {
							score :=
								loop_radius * f32(100) + chain_length + detail_radius + radius_base
							if biome_id == .Fungal_Vaults {
								score += 20
							}
							if score > best_score {
								axis_x := chain_dx / chain_length
								axis_y := chain_dy / chain_length
								axis_z := chain_dz / chain_length
								plan_axis_x := axis_x
								plan_axis_z := axis_z
								plan_axis_len := math.sqrt_f32(
									plan_axis_x * plan_axis_x + plan_axis_z * plan_axis_z,
								)
								if plan_axis_len <= 0.001 {
									plan_axis_x = tangent_x
									plan_axis_z = tangent_z
									plan_axis_len = math.sqrt_f32(
										plan_axis_x * plan_axis_x + plan_axis_z * plan_axis_z,
									)
								}
								if plan_axis_len <= 0.001 {
									plan_axis_x, plan_axis_z = 1, 0
								} else {
									plan_axis_x /= plan_axis_len
									plan_axis_z /= plan_axis_len
								}
								best_score = score
								best = {
									found            = true,
									edge             = edge,
									chamberlet_index = chamberlet_index,
									detail_index     = detail_index,
									center_x         = (previous_detail_x + detail_x) * 0.5,
									center_y         = (previous_detail_y + detail_y) * 0.5,
									center_z         = (previous_detail_z + detail_z) * 0.5,
									route_x          = route_x,
									route_y          = route_y,
									route_z          = route_z,
									chamberlet_x     = chamberlet_x,
									chamberlet_y     = chamberlet_y,
									chamberlet_z     = chamberlet_z,
									axis_x           = axis_x,
									axis_y           = axis_y,
									axis_z           = axis_z,
									plan_axis_x      = plan_axis_x,
									plan_axis_z      = plan_axis_z,
									plan_side_x      = -plan_axis_z,
									plan_side_z      = plan_axis_x,
									loop_radius      = loop_radius,
									detail_radius    = math.min(
										previous_detail_radius,
										detail_radius,
									),
									chain_length     = chain_length,
									route_radius     = route_radius,
									biome_id         = biome_id,
									score            = score,
								}
							}
						}
					}
					previous_detail_found = true
					previous_detail_x = detail_x
					previous_detail_y = detail_y
					previous_detail_z = detail_z
					previous_detail_radius = detail_radius
				}
			}
			return
		}

		terrain_generation_benchmark_cave_chamberlet_chain_slice_capture_for_selection :: proc(
			label: string,
			selection: TerrainGenerationBenchmarkCaveSelection,
			key: biomes.FeatureGridKey,
			seed: u32,
			transient_arena: ^mem.Arena,
		) {
			chain := terrain_generation_benchmark_cave_chamberlet_chain_select(key, selection)
			if !chain.found {
				log.infof("TERRAIN_GENERATION_CAVE_CHAMBERLET_CHAIN_SLICE_SKIP label=%s", label)
				return
			}

			log.infof(
				"TERRAIN_GENERATION_CAVE_CHAMBERLET_CHAIN_SLICE_SELECTION label=%s edge=%d kind=%v chamberlet=%d detail=%d center=(%.2f,%.2f,%.2f) route=(%.2f,%.2f,%.2f) chamberlet_center=(%.2f,%.2f,%.2f) loop_radius=%.2f detail_radius=%.2f chain_length=%.2f route_radius=%.2f biome=%v score=%.2f",
				label,
				chain.edge.id,
				chain.edge.kind,
				chain.chamberlet_index,
				chain.detail_index,
				chain.center_x,
				chain.center_y,
				chain.center_z,
				chain.route_x,
				chain.route_y,
				chain.route_z,
				chain.chamberlet_x,
				chain.chamberlet_y,
				chain.chamberlet_z,
				chain.loop_radius,
				chain.detail_radius,
				chain.chain_length,
				chain.route_radius,
				chain.biome_id,
				chain.score,
			)
			terrain_generation_benchmark_cave_slice_capture_basis(
				label,
				.Route_Plan,
				chain.center_x,
				chain.center_y,
				chain.center_z,
				chain.plan_axis_x,
				0,
				chain.plan_axis_z,
				chain.plan_side_x,
				0,
				chain.plan_side_z,
				seed,
				transient_arena,
			)
			terrain_generation_benchmark_cave_slice_capture_basis(
				label,
				.Route_Longitudinal,
				chain.center_x,
				chain.center_y,
				chain.center_z,
				chain.axis_x,
				chain.axis_y,
				chain.axis_z,
				0,
				1,
				0,
				seed,
				transient_arena,
			)
			terrain_generation_benchmark_cave_slice_capture_basis(
				label,
				.Route_Cross_Section,
				chain.center_x,
				chain.center_y,
				chain.center_z,
				chain.plan_side_x,
				0,
				chain.plan_side_z,
				0,
				1,
				0,
				seed,
				transient_arena,
			)
		}

		TerrainGenerationBenchmarkCaveChamberletGallerySelection :: struct {
			found:                        bool,
			edge:                         biomes.CaveNetworkEdge,
			from_chamberlet_index:        u32,
			to_chamberlet_index:          u32,
			center_x, center_y, center_z: f32,
			from_x, from_y, from_z:       f32,
			to_x, to_y, to_z:             f32,
			relay_x, relay_y, relay_z:    f32,
			axis_x, axis_y, axis_z:       f32,
			plan_axis_x, plan_axis_z:     f32,
			plan_side_x, plan_side_z:     f32,
			gallery_radius:               f32,
			chain_length:                 f32,
			route_radius:                 f32,
			biome_id:                     biomes.BiomeID,
			score:                        f32,
		}

		terrain_generation_benchmark_cave_chamberlet_gallery_relay_point :: proc(
			from_x, from_y, from_z: f32,
			to_x, to_y, to_z: f32,
			route_radius: f32,
			biome_id: biomes.BiomeID,
			salt: u64,
		) -> (
			relay_x, relay_y, relay_z: f32,
		) {
			gallery_dx := to_x - from_x
			gallery_dy := to_y - from_y
			gallery_dz := to_z - from_z
			gallery_length := math.sqrt_f32(
				gallery_dx * gallery_dx + gallery_dy * gallery_dy + gallery_dz * gallery_dz,
			)
			if gallery_length <= 0.001 {
				relay_x = (from_x + to_x) * 0.5
				relay_y = (from_y + to_y) * 0.5
				relay_z = (from_z + to_z) * 0.5
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
			relay_x = from_x + gallery_dx * f32(0.34) + bend_side_x * bend_offset
			relay_y = from_y + gallery_dy * f32(0.34) + vertical_sign * vertical_offset
			relay_z = from_z + gallery_dz * f32(0.34) + bend_side_z * bend_offset
			return
		}

		terrain_generation_benchmark_cave_chamberlet_gallery_select :: proc(
			key: biomes.FeatureGridKey,
			selection: TerrainGenerationBenchmarkCaveSelection,
		) -> (
			best: TerrainGenerationBenchmarkCaveChamberletGallerySelection,
		) {
			if !selection.found_matching_biome {
				return
			}
			edge, edge_found := terrain_generation_benchmark_cave_route_edge_select(key, selection)
			if !edge_found {
				return
			}

			best_score := -max(f32)
			route_radius := math.max(f32(1), edge.radius_blocks)
			positive_gallery_found := false
			positive_gallery_x := f32(0)
			positive_gallery_y := f32(0)
			positive_gallery_z := f32(0)
			positive_gallery_radius := f32(0)
			positive_gallery_index := u32(0)
			negative_gallery_found := false
			negative_gallery_x := f32(0)
			negative_gallery_y := f32(0)
			negative_gallery_z := f32(0)
			negative_gallery_radius := f32(0)
			negative_gallery_index := u32(0)
			for chamberlet_index := u32(0);
			    chamberlet_index < TERRAIN_CAVE_EDGE_CHAMBERLET_COUNT;
			    chamberlet_index += 1 {
				hash := biomes.feature_grid_hash_combine(
					u64(edge.id),
					TERRAIN_CAVE_ROOM_DETAIL_SALT,
				)
				hash = biomes.feature_grid_hash_combine(hash, u64(chamberlet_index))
				step_t := (f32(chamberlet_index) + 0.5) / f32(TERRAIN_CAVE_EDGE_CHAMBERLET_COUNT)
				jitter :=
					biomes.feature_grid_signed_unit_f32(hash, TERRAIN_CAVE_CURVE_SALT) * f32(0.055)
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
				tangent_x, tangent_y, tangent_z := terrain_density_delta_3(
					prev_x,
					prev_y,
					prev_z,
					next_x,
					next_y,
					next_z,
				)
				tangent_len := math.sqrt_f32(
					tangent_x * tangent_x + tangent_y * tangent_y + tangent_z * tangent_z,
				)
				if tangent_len > 0.001 {
					tangent_x /= tangent_len
					tangent_y /= tangent_len
					tangent_z /= tangent_len
				} else {
					tangent_x, tangent_y, tangent_z = 1, 0, 0
				}
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
				side_offset :=
					route_radius *
					TERRAIN_CAVE_EDGE_CHAMBERLET_SIDE_OFFSET_SCALE *
					biomes.regional_terrain_field_lerp(
						f32(0.72),
						f32(1.14),
						biomes.feature_grid_unit_f32(hash, TERRAIN_CAVE_FIELD_DETAIL_SALT),
					)
				center_x := route_x + side_x * side_offset
				center_y :=
					route_y +
					biomes.feature_grid_signed_unit_f32(hash, TERRAIN_CAVE_BRANCH_SALT) *
						route_radius *
						f32(0.16)
				center_z := route_z + side_z * side_offset
				biome_id := edge.from_biome_id
				if t >= 0.5 {
					biome_id = edge.to_biome_id
				}

				if side_sign >= 0 {
					if positive_gallery_found {
						gallery_radius := math.max(
							f32(2.0),
							math.min(
								math.min(positive_gallery_radius, radius_base) *
								TERRAIN_CAVE_EDGE_CHAMBERLET_GALLERY_RADIUS_SCALE,
								route_radius *
								TERRAIN_CAVE_EDGE_CHAMBERLET_GALLERY_ROUTE_CAP_SCALE,
							),
						)
						chain_dx := center_x - positive_gallery_x
						chain_dy := center_y - positive_gallery_y
						chain_dz := center_z - positive_gallery_z
						chain_length := math.sqrt_f32(
							chain_dx * chain_dx + chain_dy * chain_dy + chain_dz * chain_dz,
						)
						if chain_length > 0.001 {
							gallery_salt :=
								TERRAIN_CAVE_ROOM_DETAIL_SALT ~ u64(chamberlet_index * 67 + 719)
							relay_x, relay_y, relay_z :=
								terrain_generation_benchmark_cave_chamberlet_gallery_relay_point(
									positive_gallery_x,
									positive_gallery_y,
									positive_gallery_z,
									center_x,
									center_y,
									center_z,
									route_radius,
									biome_id,
									gallery_salt,
								)
							score :=
								gallery_radius * f32(120) +
								chain_length * f32(0.15) +
								math.min(positive_gallery_radius, radius_base) * f32(8)
							if biome_id == .Fungal_Vaults {
								score += 20
							}
							if score > best_score {
								axis_x := chain_dx / chain_length
								axis_y := chain_dy / chain_length
								axis_z := chain_dz / chain_length
								plan_axis_x := axis_x
								plan_axis_z := axis_z
								plan_axis_len := math.sqrt_f32(
									plan_axis_x * plan_axis_x + plan_axis_z * plan_axis_z,
								)
								if plan_axis_len <= 0.001 {
									plan_axis_x, plan_axis_z = tangent_x, tangent_z
									plan_axis_len = math.sqrt_f32(
										plan_axis_x * plan_axis_x + plan_axis_z * plan_axis_z,
									)
								}
								if plan_axis_len <= 0.001 {
									plan_axis_x, plan_axis_z = 1, 0
								} else {
									plan_axis_x /= plan_axis_len
									plan_axis_z /= plan_axis_len
								}
								best_score = score
								best = {
									found                 = true,
									edge                  = edge,
									from_chamberlet_index = positive_gallery_index,
									to_chamberlet_index   = chamberlet_index,
									center_x              = (positive_gallery_x + center_x) * 0.5,
									center_y              = (positive_gallery_y + center_y) * 0.5,
									center_z              = (positive_gallery_z + center_z) * 0.5,
									from_x                = positive_gallery_x,
									from_y                = positive_gallery_y,
									from_z                = positive_gallery_z,
									to_x                  = center_x,
									to_y                  = center_y,
									to_z                  = center_z,
									relay_x               = relay_x,
									relay_y               = relay_y,
									relay_z               = relay_z,
									axis_x                = axis_x,
									axis_y                = axis_y,
									axis_z                = axis_z,
									plan_axis_x           = plan_axis_x,
									plan_axis_z           = plan_axis_z,
									plan_side_x           = -plan_axis_z,
									plan_side_z           = plan_axis_x,
									gallery_radius        = gallery_radius,
									chain_length          = chain_length,
									route_radius          = route_radius,
									biome_id              = biome_id,
									score                 = score,
								}
							}
						}
					}
					positive_gallery_found = true
					positive_gallery_x = center_x
					positive_gallery_y = center_y
					positive_gallery_z = center_z
					positive_gallery_radius = radius_base
					positive_gallery_index = chamberlet_index
				} else {
					if negative_gallery_found {
						gallery_radius := math.max(
							f32(2.0),
							math.min(
								math.min(negative_gallery_radius, radius_base) *
								TERRAIN_CAVE_EDGE_CHAMBERLET_GALLERY_RADIUS_SCALE,
								route_radius *
								TERRAIN_CAVE_EDGE_CHAMBERLET_GALLERY_ROUTE_CAP_SCALE,
							),
						)
						chain_dx := center_x - negative_gallery_x
						chain_dy := center_y - negative_gallery_y
						chain_dz := center_z - negative_gallery_z
						chain_length := math.sqrt_f32(
							chain_dx * chain_dx + chain_dy * chain_dy + chain_dz * chain_dz,
						)
						if chain_length > 0.001 {
							gallery_salt :=
								TERRAIN_CAVE_ROOM_DETAIL_SALT ~ u64(chamberlet_index * 67 + 769)
							relay_x, relay_y, relay_z :=
								terrain_generation_benchmark_cave_chamberlet_gallery_relay_point(
									negative_gallery_x,
									negative_gallery_y,
									negative_gallery_z,
									center_x,
									center_y,
									center_z,
									route_radius,
									biome_id,
									gallery_salt,
								)
							score :=
								gallery_radius * f32(120) +
								chain_length * f32(0.15) +
								math.min(negative_gallery_radius, radius_base) * f32(8)
							if biome_id == .Fungal_Vaults {
								score += 20
							}
							if score > best_score {
								axis_x := chain_dx / chain_length
								axis_y := chain_dy / chain_length
								axis_z := chain_dz / chain_length
								plan_axis_x := axis_x
								plan_axis_z := axis_z
								plan_axis_len := math.sqrt_f32(
									plan_axis_x * plan_axis_x + plan_axis_z * plan_axis_z,
								)
								if plan_axis_len <= 0.001 {
									plan_axis_x, plan_axis_z = tangent_x, tangent_z
									plan_axis_len = math.sqrt_f32(
										plan_axis_x * plan_axis_x + plan_axis_z * plan_axis_z,
									)
								}
								if plan_axis_len <= 0.001 {
									plan_axis_x, plan_axis_z = 1, 0
								} else {
									plan_axis_x /= plan_axis_len
									plan_axis_z /= plan_axis_len
								}
								best_score = score
								best = {
									found                 = true,
									edge                  = edge,
									from_chamberlet_index = negative_gallery_index,
									to_chamberlet_index   = chamberlet_index,
									center_x              = (negative_gallery_x + center_x) * 0.5,
									center_y              = (negative_gallery_y + center_y) * 0.5,
									center_z              = (negative_gallery_z + center_z) * 0.5,
									from_x                = negative_gallery_x,
									from_y                = negative_gallery_y,
									from_z                = negative_gallery_z,
									to_x                  = center_x,
									to_y                  = center_y,
									to_z                  = center_z,
									relay_x               = relay_x,
									relay_y               = relay_y,
									relay_z               = relay_z,
									axis_x                = axis_x,
									axis_y                = axis_y,
									axis_z                = axis_z,
									plan_axis_x           = plan_axis_x,
									plan_axis_z           = plan_axis_z,
									plan_side_x           = -plan_axis_z,
									plan_side_z           = plan_axis_x,
									gallery_radius        = gallery_radius,
									chain_length          = chain_length,
									route_radius          = route_radius,
									biome_id              = biome_id,
									score                 = score,
								}
							}
						}
					}
					negative_gallery_found = true
					negative_gallery_x = center_x
					negative_gallery_y = center_y
					negative_gallery_z = center_z
					negative_gallery_radius = radius_base
					negative_gallery_index = chamberlet_index
				}
			}
			return
		}

		terrain_generation_benchmark_cave_chamberlet_gallery_slice_capture_for_selection :: proc(
			label: string,
			selection: TerrainGenerationBenchmarkCaveSelection,
			key: biomes.FeatureGridKey,
			seed: u32,
			transient_arena: ^mem.Arena,
		) {
			gallery := terrain_generation_benchmark_cave_chamberlet_gallery_select(key, selection)
			if !gallery.found {
				log.infof("TERRAIN_GENERATION_CAVE_CHAMBERLET_GALLERY_SLICE_SKIP label=%s", label)
				return
			}

			log.infof(
				"TERRAIN_GENERATION_CAVE_CHAMBERLET_GALLERY_SLICE_SELECTION label=%s edge=%d kind=%v from_chamberlet=%d to_chamberlet=%d center=(%.2f,%.2f,%.2f) from=(%.2f,%.2f,%.2f) to=(%.2f,%.2f,%.2f) relay=(%.2f,%.2f,%.2f) gallery_radius=%.2f chain_length=%.2f route_radius=%.2f biome=%v score=%.2f",
				label,
				gallery.edge.id,
				gallery.edge.kind,
				gallery.from_chamberlet_index,
				gallery.to_chamberlet_index,
				gallery.center_x,
				gallery.center_y,
				gallery.center_z,
				gallery.from_x,
				gallery.from_y,
				gallery.from_z,
				gallery.to_x,
				gallery.to_y,
				gallery.to_z,
				gallery.relay_x,
				gallery.relay_y,
				gallery.relay_z,
				gallery.gallery_radius,
				gallery.chain_length,
				gallery.route_radius,
				gallery.biome_id,
				gallery.score,
			)
			terrain_generation_benchmark_cave_slice_capture_basis(
				"chamberlet_gallery_endpoint",
				.Route_Endpoint_Plan,
				gallery.from_x,
				gallery.from_y,
				gallery.from_z,
				gallery.plan_axis_x,
				0,
				gallery.plan_axis_z,
				gallery.plan_side_x,
				0,
				gallery.plan_side_z,
				seed,
				transient_arena,
			)
			terrain_generation_benchmark_cave_slice_capture_basis(
				"chamberlet_gallery_relay",
				.Route_Endpoint_Plan,
				gallery.relay_x,
				gallery.relay_y,
				gallery.relay_z,
				gallery.plan_axis_x,
				0,
				gallery.plan_axis_z,
				gallery.plan_side_x,
				0,
				gallery.plan_side_z,
				seed,
				transient_arena,
			)
			terrain_generation_benchmark_cave_slice_capture_basis(
				label,
				.Route_Plan,
				gallery.center_x,
				gallery.center_y,
				gallery.center_z,
				gallery.plan_axis_x,
				0,
				gallery.plan_axis_z,
				gallery.plan_side_x,
				0,
				gallery.plan_side_z,
				seed,
				transient_arena,
			)
			terrain_generation_benchmark_cave_slice_capture_basis(
				label,
				.Route_Longitudinal,
				gallery.center_x,
				gallery.center_y,
				gallery.center_z,
				gallery.axis_x,
				gallery.axis_y,
				gallery.axis_z,
				0,
				1,
				0,
				seed,
				transient_arena,
			)
			terrain_generation_benchmark_cave_slice_capture_basis(
				label,
				.Route_Cross_Section,
				gallery.center_x,
				gallery.center_y,
				gallery.center_z,
				gallery.plan_side_x,
				0,
				gallery.plan_side_z,
				0,
				1,
				0,
				seed,
				transient_arena,
			)
		}

		TerrainGenerationBenchmarkCavePortalSelection :: struct {
			found:                        bool,
			node:                         biomes.CaveNetworkNode,
			edge:                         biomes.CaveNetworkEdge,
			center_x, center_y, center_z: f32,
			axis_x, axis_z:               f32,
			side_x, side_z:               f32,
			radius:                       f32,
			score:                        f32,
		}

		TerrainGenerationBenchmarkCaveMacroClusterSelection :: struct {
			found:                        bool,
			node:                         biomes.CaveNetworkNode,
			satellite_index:              u32,
			next_index:                   u32,
			center_x, center_y, center_z: f32,
			tangent_x, tangent_z:         f32,
			outward_x, outward_z:         f32,
			bridge_radius:                f32,
			pocket_radius:                f32,
			score:                        f32,
		}

		terrain_generation_benchmark_cave_portal_room_radii :: proc(
			node: biomes.CaveNetworkNode,
		) -> (
			room_radius_x, room_radius_y, room_radius_z: f32,
		) {
			radius_x := node.radius_blocks
			radius_y := node.radius_blocks * 0.85
			radius_z := node.radius_blocks
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
			case .Geode_Chamber:
				radius_x *= 1.05
				radius_y *= 1.05
				radius_z *= 1.05
			case .Magma_Pocket:
				radius_x *= 1.15
				radius_y *= 0.70
				radius_z *= 1.15
			}
			room_radius_x = math.min(radius_x, TERRAIN_CAVE_NODE_PROFILE_ROOM_MAJOR_MAX_XZ)
			room_radius_y = math.min(radius_y, TERRAIN_CAVE_NODE_PROFILE_ROOM_MAJOR_MAX_Y)
			room_radius_z = math.min(radius_z, TERRAIN_CAVE_NODE_PROFILE_ROOM_MAJOR_MAX_XZ)
			return
		}

		terrain_generation_benchmark_cave_portal_select :: proc(
			key: biomes.FeatureGridKey,
			selection: TerrainGenerationBenchmarkCaveSelection,
		) -> (
			best: TerrainGenerationBenchmarkCavePortalSelection,
		) {
			if !selection.found_matching_biome ||
			   !terrain_density_cave_node_edge_portals_enabled(selection.node) {
				return
			}

			origin := chunk_origin_from_coord(selection.chunk)
			region_coord := biomes.generation_region_coord_from_block(origin.x, origin.y, origin.z)
			region := terrain_generation_region_for_fill(key, region_coord)
			room_radius_x, room_radius_y, room_radius_z :=
				terrain_generation_benchmark_cave_portal_room_radii(selection.node)
			room_radius_xz := math.min(room_radius_x, room_radius_z)

			portal_count := u32(0)
			for i := u32(0);
			    i < region.cave_network_edge_count &&
			    portal_count < TERRAIN_CAVE_NODE_EDGE_PORTAL_MAX_COUNT;
			    i += 1 {
				edge := region.cave_network_edges[i]
				from_endpoint := edge.from_node_id == selection.node.id
				to_endpoint := edge.to_node_id == selection.node.id
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
				dir_x := route_x - selection.node.x
				dir_y := route_y - selection.node.y
				dir_z := route_z - selection.node.z
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
				axis_x := f32(1)
				axis_z := f32(0)
				if horizontal_len > 0.001 {
					axis_x = dir_x / horizontal_len
					axis_z = dir_z / horizontal_len
					side_x = -axis_z
					side_z = axis_x
				}

				hash := biomes.feature_grid_hash_combine(
					u64(edge.id),
					TERRAIN_CAVE_ROOM_DETAIL_SALT,
				)
				hash = biomes.feature_grid_hash_combine(hash, u64(selection.node.id))
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
					selection.node.x +
					dir_x * room_radius_xz * TERRAIN_CAVE_NODE_EDGE_PORTAL_OFFSET_SCALE +
					side_x * side_offset
				center_y := selection.node.y + dir_y * room_radius_y * f32(0.65) + vertical_offset
				center_z :=
					selection.node.z +
					dir_z * room_radius_xz * TERRAIN_CAVE_NODE_EDGE_PORTAL_OFFSET_SCALE +
					side_z * side_offset
				score := portal_radius * 10.0 + edge_radius
				if edge.guaranteed_connection {
					score += edge_radius
				}
				#partial switch edge.kind {
				case .Worm_Path:
					score += 8
				case .Canyon:
					score += 4
				case .Fracture:
					score += 3
				case .Flooded_Passage:
					score += 2
				}
				if !best.found || score > best.score {
					best = {
						found    = true,
						node     = selection.node,
						edge     = edge,
						center_x = center_x,
						center_y = center_y,
						center_z = center_z,
						axis_x   = axis_x,
						axis_z   = axis_z,
						side_x   = side_x * side_sign,
						side_z   = side_z * side_sign,
						radius   = portal_radius,
						score    = score,
					}
				}
				portal_count += 1
			}
			return
		}

		terrain_generation_benchmark_cave_portal_slice_capture_for_selection :: proc(
			label: string,
			selection: TerrainGenerationBenchmarkCaveSelection,
			key: biomes.FeatureGridKey,
			seed: u32,
			transient_arena: ^mem.Arena,
		) {
			portal := terrain_generation_benchmark_cave_portal_select(key, selection)
			if !portal.found {
				log.infof("TERRAIN_GENERATION_CAVE_PORTAL_SLICE_SKIP label=%s", label)
				return
			}
			log.infof(
				"TERRAIN_GENERATION_CAVE_PORTAL_SLICE_SELECTION label=%s node=%d edge=%d kind=%v radius=%.2f center=(%.2f,%.2f,%.2f) axis=(%.3f,%.3f) side=(%.3f,%.3f)",
				label,
				portal.node.id,
				portal.edge.id,
				portal.edge.kind,
				portal.radius,
				portal.center_x,
				portal.center_y,
				portal.center_z,
				portal.axis_x,
				portal.axis_z,
				portal.side_x,
				portal.side_z,
			)
			terrain_generation_benchmark_cave_slice_capture_basis(
				label,
				.Route_Plan,
				portal.center_x,
				portal.center_y,
				portal.center_z,
				portal.axis_x,
				0,
				portal.axis_z,
				portal.side_x,
				0,
				portal.side_z,
				seed,
				transient_arena,
			)
			terrain_generation_benchmark_cave_slice_capture_basis(
				label,
				.Route_Longitudinal,
				portal.center_x,
				portal.center_y,
				portal.center_z,
				portal.axis_x,
				0,
				portal.axis_z,
				0,
				1,
				0,
				seed,
				transient_arena,
			)
		}

		terrain_generation_benchmark_cave_macro_cluster_select :: proc(
			selection: TerrainGenerationBenchmarkCaveSelection,
		) -> (
			best: TerrainGenerationBenchmarkCaveMacroClusterSelection,
		) {
			if !selection.found_matching_biome ||
			   !selection.node.major_region ||
			   !terrain_density_cave_node_uses_profile_room(selection.node) {
				return
			}

			room_radius_x, room_radius_y, room_radius_z :=
				terrain_generation_benchmark_cave_portal_room_radii(selection.node)
			base_radius := math.max(
				TERRAIN_CAVE_NODE_MACRO_SATELLITE_MIN_RADIUS_BLOCKS,
				math.min(room_radius_x, room_radius_z) *
				TERRAIN_CAVE_NODE_MACRO_SATELLITE_RADIUS_XZ_SCALE,
			)

			satellite_center_x: [TERRAIN_CAVE_NODE_MACRO_SATELLITE_COUNT]f32
			satellite_center_y: [TERRAIN_CAVE_NODE_MACRO_SATELLITE_COUNT]f32
			satellite_center_z: [TERRAIN_CAVE_NODE_MACRO_SATELLITE_COUNT]f32
			satellite_radius_xz_min: [TERRAIN_CAVE_NODE_MACRO_SATELLITE_COUNT]f32
			satellite_dir_x: [TERRAIN_CAVE_NODE_MACRO_SATELLITE_COUNT]f32
			satellite_dir_z: [TERRAIN_CAVE_NODE_MACRO_SATELLITE_COUNT]f32

			for satellite_index := u32(0);
			    satellite_index < TERRAIN_CAVE_NODE_MACRO_SATELLITE_COUNT;
			    satellite_index += 1 {
				hash := biomes.feature_grid_hash_combine(
					u64(selection.node.id),
					TERRAIN_CAVE_FIELD_CHAMBER_SALT,
				)
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
				vertical_sign := f32(1)
				if (satellite_index & 1) != 0 {
					vertical_sign = -1
				}
				if biomes.feature_grid_signed_unit_f32(hash, TERRAIN_CAVE_PASSAGE_RIB_SALT) < 0 {
					vertical_sign = -vertical_sign
				}

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
				satellite_radius_z := satellite_radius * f32(0.92)
				#partial switch selection.node.biome_id {
				case .Fungal_Vaults:
					satellite_radius_x *= 1.18
					satellite_radius_z *= 1.08
				case .Crystal_Geode_Network:
					satellite_radius_x *= 0.72
					satellite_radius_z *= 0.82
				case .Buried_Aquifer_Caves:
					satellite_radius_x *= 1.20
					satellite_radius_z *= 1.08
				case .Temperate_Hills,
				     .Old_Growth_Forest,
				     .Basalt_Spire_Highlands,
				     .Emberglass_Badlands,
				     .Wet_Lowland_Marsh,
				     .Corrupted_Ash_Forest,
				     .Corrupted_Fen:
				}

				satellite_center_x[satellite_index] =
					selection.node.x +
					dir_x *
						room_radius_x *
						TERRAIN_CAVE_NODE_MACRO_SATELLITE_OFFSET_SCALE *
						forward_bias
				satellite_center_y[satellite_index] =
					selection.node.y +
					room_radius_y *
						TERRAIN_CAVE_NODE_MACRO_SATELLITE_VERTICAL_OFFSET_SCALE *
						vertical_sign *
						biomes.regional_terrain_field_lerp(
							f32(0.44),
							f32(1.08),
							biomes.feature_grid_unit_f32(hash, TERRAIN_CAVE_DETAIL_SALT),
						)
				satellite_center_z[satellite_index] =
					selection.node.z +
					dir_z *
						room_radius_z *
						TERRAIN_CAVE_NODE_MACRO_SATELLITE_OFFSET_SCALE *
						forward_bias
				satellite_radius_xz_min[satellite_index] = math.min(
					satellite_radius_x,
					satellite_radius_z,
				)
				satellite_dir_x[satellite_index] = dir_x
				satellite_dir_z[satellite_index] = dir_z
			}

			for satellite_index := u32(0);
			    satellite_index < TERRAIN_CAVE_NODE_MACRO_SATELLITE_COUNT;
			    satellite_index += 1 {
				next_index := (satellite_index + 1) % TERRAIN_CAVE_NODE_MACRO_SATELLITE_COUNT
				bridge_source_radius := math.min(
					satellite_radius_xz_min[satellite_index],
					satellite_radius_xz_min[next_index],
				)
				bridge_radius := math.max(
					TERRAIN_CAVE_NODE_MACRO_SATELLITE_CLUSTER_BRIDGE_MIN_BLOCKS,
					bridge_source_radius *
					TERRAIN_CAVE_NODE_MACRO_SATELLITE_CLUSTER_BRIDGE_RADIUS_SCALE,
				)
				outward_x := satellite_dir_x[satellite_index] + satellite_dir_x[next_index]
				outward_z := satellite_dir_z[satellite_index] + satellite_dir_z[next_index]
				outward_length := math.sqrt_f32(outward_x * outward_x + outward_z * outward_z)
				if outward_length <= 0.001 {
					outward_x = satellite_dir_x[satellite_index]
					outward_z = satellite_dir_z[satellite_index]
				} else {
					outward_x /= outward_length
					outward_z /= outward_length
				}
				directional_radius_inv_sq :=
					(outward_x * outward_x) / (room_radius_x * room_radius_x) +
					(outward_z * outward_z) / (room_radius_z * room_radius_z)
				directional_room_radius := math.min(room_radius_x, room_radius_z)
				if directional_radius_inv_sq > 0.0001 {
					directional_room_radius = f32(1) / math.sqrt_f32(directional_radius_inv_sq)
				}
				outer_hash := biomes.feature_grid_hash_combine(
					u64(selection.node.id),
					TERRAIN_CAVE_ROOM_DETAIL_SALT,
				)
				outer_hash = biomes.feature_grid_hash_combine(
					outer_hash,
					u64(satellite_index + 943),
				)
				center_x :=
					selection.node.x +
					outward_x *
						directional_room_radius *
						TERRAIN_CAVE_NODE_MACRO_SATELLITE_CLUSTER_OUTER_OFFSET_SCALE
				center_y :=
					(satellite_center_y[satellite_index] + satellite_center_y[next_index]) *
						f32(0.5) +
					room_radius_y *
						f32(0.12) *
						biomes.feature_grid_signed_unit_f32(
							outer_hash,
							TERRAIN_CAVE_PASSAGE_RIB_SALT,
						)
				center_z :=
					selection.node.z +
					outward_z *
						directional_room_radius *
						TERRAIN_CAVE_NODE_MACRO_SATELLITE_CLUSTER_OUTER_OFFSET_SCALE

				tangent_x := satellite_center_x[next_index] - satellite_center_x[satellite_index]
				tangent_z := satellite_center_z[next_index] - satellite_center_z[satellite_index]
				tangent_length := math.sqrt_f32(tangent_x * tangent_x + tangent_z * tangent_z)
				if tangent_length <= 0.001 {
					tangent_x = -outward_z
					tangent_z = outward_x
				} else {
					tangent_x /= tangent_length
					tangent_z /= tangent_length
				}

				pocket_radius := math.clamp(
					bridge_source_radius *
					TERRAIN_CAVE_NODE_MACRO_SATELLITE_CLUSTER_POCKET_RADIUS_SCALE,
					TERRAIN_CAVE_NODE_MACRO_SATELLITE_CLUSTER_POCKET_MIN_BLOCKS,
					TERRAIN_CAVE_NODE_MACRO_SATELLITE_CLUSTER_POCKET_MAX_BLOCKS,
				)
				score := pocket_radius * 10.0 + bridge_radius * 7.0 + bridge_source_radius * 3.0
				score += math.abs(center_y - selection.node.y) * 0.25
				if selection.node.biome_id == .Fungal_Vaults {
					score += math.abs(outward_x) + math.abs(outward_z)
				}
				if !best.found || score > best.score {
					best = {
						found           = true,
						node            = selection.node,
						satellite_index = satellite_index,
						next_index      = next_index,
						center_x        = center_x,
						center_y        = center_y,
						center_z        = center_z,
						tangent_x       = tangent_x,
						tangent_z       = tangent_z,
						outward_x       = outward_x,
						outward_z       = outward_z,
						bridge_radius   = bridge_radius,
						pocket_radius   = pocket_radius,
						score           = score,
					}
				}
			}
			return
		}

		terrain_generation_benchmark_cave_macro_cluster_slice_capture_for_selection :: proc(
			label: string,
			selection: TerrainGenerationBenchmarkCaveSelection,
			seed: u32,
			transient_arena: ^mem.Arena,
		) {
			cluster := terrain_generation_benchmark_cave_macro_cluster_select(selection)
			if !cluster.found {
				log.infof("TERRAIN_GENERATION_CAVE_MACRO_CLUSTER_SLICE_SKIP label=%s", label)
				return
			}
			log.infof(
				"TERRAIN_GENERATION_CAVE_MACRO_CLUSTER_SLICE_SELECTION label=%s node=%d satellite=%d next=%d bridge_radius=%.2f pocket_radius=%.2f center=(%.2f,%.2f,%.2f) tangent=(%.3f,%.3f) outward=(%.3f,%.3f)",
				label,
				cluster.node.id,
				cluster.satellite_index,
				cluster.next_index,
				cluster.bridge_radius,
				cluster.pocket_radius,
				cluster.center_x,
				cluster.center_y,
				cluster.center_z,
				cluster.tangent_x,
				cluster.tangent_z,
				cluster.outward_x,
				cluster.outward_z,
			)
			terrain_generation_benchmark_cave_slice_capture_basis(
				label,
				.Route_Plan,
				cluster.center_x,
				cluster.center_y,
				cluster.center_z,
				cluster.tangent_x,
				0,
				cluster.tangent_z,
				cluster.outward_x,
				0,
				cluster.outward_z,
				seed,
				transient_arena,
			)
			terrain_generation_benchmark_cave_slice_capture_basis(
				label,
				.Route_Longitudinal,
				cluster.center_x,
				cluster.center_y,
				cluster.center_z,
				cluster.outward_x,
				0,
				cluster.outward_z,
				0,
				1,
				0,
				seed,
				transient_arena,
			)
		}

		terrain_generation_benchmark_cave_seam_edge_select :: proc(
			key: biomes.FeatureGridKey,
			region_coord: biomes.GenerationRegionCoord,
			axis: int,
			positive_face: bool,
		) -> (
			edge: biomes.CaveNetworkEdge,
			face_block: f32,
			found: bool,
		) {
			region := terrain_generation_region_for_fill(key, region_coord)
			switch axis {
			case 0:
				face_block = f32(region.bounds.min.x)
				if positive_face {
					face_block = f32(region.bounds.max.x)
				}
			case 1:
				face_block = f32(region.bounds.min.y)
				if positive_face {
					face_block = f32(region.bounds.max.y)
				}
			case 2:
				face_block = f32(region.bounds.min.z)
				if positive_face {
					face_block = f32(region.bounds.max.z)
				}
			}
			eligible: [biomes.GENERATION_REGION_CAVE_NETWORK_NODE_CAPACITY]bool
			for i := u32(0); i < region.cave_network_node_count; i += 1 {
				eligible[i] = region.cave_network_nodes[i].role != .Sealed_Secret
			}
			from_index, to_index, edge_found :=
				biomes.generation_region_cave_network_seam_edge_select(
					&region,
					eligible,
					axis,
					face_block,
				)
			if !edge_found {
				return
			}
			edge = biomes.cave_network_seam_edge_from_nodes(
				region.cave_network_nodes[from_index],
				region.cave_network_nodes[to_index],
			)
			found = true
			return
		}

		terrain_generation_benchmark_cave_edge_face_t :: proc(
			edge: biomes.CaveNetworkEdge,
			axis: int,
			face_block: f32,
		) -> f32 {
			best_t := f32(0.5)
			best_distance := max(f32)
			for step := i32(0); step <= 64; step += 1 {
				t := f32(step) / f32(64)
				route_x, route_y, route_z := terrain_density_cave_edge_route_point(edge, t)
				route_axis := route_z
				if axis == 0 {
					route_axis = route_x
				} else if axis == 1 {
					route_axis = route_y
				}
				distance := math.abs(route_axis - face_block)
				if distance < best_distance {
					best_distance = distance
					best_t = t
				}
			}
			return best_t
		}

		terrain_generation_benchmark_cave_seam_slice_capture :: proc(
			label: string,
			key: biomes.FeatureGridKey,
			region_coord: biomes.GenerationRegionCoord,
			axis: int,
			positive_face: bool,
			seed: u32,
			transient_arena: ^mem.Arena,
		) {
			edge, face_block, found := terrain_generation_benchmark_cave_seam_edge_select(
				key,
				region_coord,
				axis,
				positive_face,
			)
			if !found {
				log.infof(
					"TERRAIN_GENERATION_CAVE_SEAM_SLICE_SKIP label=%s region=(%d,%d,%d) axis=%d positive_face=%v",
					label,
					region_coord.x,
					region_coord.y,
					region_coord.z,
					axis,
					positive_face,
				)
				return
			}

			route_t := terrain_generation_benchmark_cave_edge_face_t(edge, axis, face_block)
			route_x, route_y, route_z := terrain_density_cave_edge_route_point(edge, route_t)
			length_dx := edge.to_x - edge.from_x
			length_dy := edge.to_y - edge.from_y
			length_dz := edge.to_z - edge.from_z
			route_length := math.sqrt_f32(
				length_dx * length_dx + length_dy * length_dy + length_dz * length_dz,
			)
			log.infof(
				"TERRAIN_GENERATION_CAVE_SEAM_SLICE_SELECTION label=%s region=(%d,%d,%d) axis=%d positive_face=%v face=%.2f edge=%d kind=%v radius=%.2f length=%.2f route_t=%.3f route=(%.2f,%.2f,%.2f) from=(%.2f,%.2f,%.2f) to=(%.2f,%.2f,%.2f)",
				label,
				region_coord.x,
				region_coord.y,
				region_coord.z,
				axis,
				positive_face,
				face_block,
				edge.id,
				edge.kind,
				edge.radius_blocks,
				route_length,
				route_t,
				route_x,
				route_y,
				route_z,
				edge.from_x,
				edge.from_y,
				edge.from_z,
				edge.to_x,
				edge.to_y,
				edge.to_z,
			)
			terrain_generation_benchmark_cave_route_slice_capture(
				label,
				edge,
				.Route_Longitudinal,
				seed,
				transient_arena,
			)
			center_x := route_x
			center_y := route_y
			center_z := route_z
			axis_u_x := f32(1)
			axis_u_y := f32(0)
			axis_u_z := f32(0)
			axis_v_x := f32(0)
			axis_v_y := f32(1)
			axis_v_z := f32(0)
			if axis == 0 {
				center_x = face_block
				axis_u_x = 0
				axis_u_z = 1
			} else if axis == 1 {
				center_y = face_block
				axis_v_y = 0
				axis_v_z = 1
			} else {
				center_z = face_block
			}
			terrain_generation_benchmark_cave_slice_capture_basis(
				label,
				.Route_Cross_Section,
				center_x,
				center_y,
				center_z,
				axis_u_x,
				axis_u_y,
				axis_u_z,
				axis_v_x,
				axis_v_y,
				axis_v_z,
				seed,
				transient_arena,
			)
			terrain_generation_benchmark_cave_route_slice_capture(
				label,
				edge,
				.Route_Oblique,
				seed,
				transient_arena,
			)
			terrain_generation_benchmark_cave_route_slice_capture(
				label,
				edge,
				.Route_Plan,
				seed,
				transient_arena,
			)
		}

		terrain_generation_benchmark_cave_seam_view_capture :: proc(
			forward_label, diag_positive_label, diag_negative_label: string,
			key: biomes.FeatureGridKey,
			region_coord: biomes.GenerationRegionCoord,
			axis: int,
			positive_face: bool,
			seed: u32,
			transient_arena: ^mem.Arena,
		) {
			edge, face_block, found := terrain_generation_benchmark_cave_seam_edge_select(
				key,
				region_coord,
				axis,
				positive_face,
			)
			if !found {
				log.infof(
					"TERRAIN_GENERATION_CAVE_VIEW_SKIP label=%s region=(%d,%d,%d) axis=%d positive_face=%v",
					forward_label,
					region_coord.x,
					region_coord.y,
					region_coord.z,
					axis,
					positive_face,
				)
				return
			}

			route_t := terrain_generation_benchmark_cave_edge_face_t(edge, axis, face_block)
			route_x, route_y, route_z := terrain_density_cave_edge_route_point(edge, route_t)
			length_dx := edge.to_x - edge.from_x
			length_dy := edge.to_y - edge.from_y
			length_dz := edge.to_z - edge.from_z
			route_length := math.sqrt_f32(
				length_dx * length_dx + length_dy * length_dy + length_dz * length_dz,
			)
			log.infof(
				"TERRAIN_GENERATION_CAVE_SEAM_VIEW_SELECTION label=%s region=(%d,%d,%d) axis=%d positive_face=%v face=%.2f edge=%d kind=%v radius=%.2f length=%.2f route_t=%.3f route=(%.2f,%.2f,%.2f) from=(%.2f,%.2f,%.2f) to=(%.2f,%.2f,%.2f)",
				forward_label,
				region_coord.x,
				region_coord.y,
				region_coord.z,
				axis,
				positive_face,
				face_block,
				edge.id,
				edge.kind,
				edge.radius_blocks,
				route_length,
				route_t,
				route_x,
				route_y,
				route_z,
				edge.from_x,
				edge.from_y,
				edge.from_z,
				edge.to_x,
				edge.to_y,
				edge.to_z,
			)
			terrain_generation_benchmark_cave_view_capture(
				forward_label,
				edge,
				route_t,
				0,
				0,
				seed,
				transient_arena,
			)
			terrain_generation_benchmark_cave_view_capture(
				diag_positive_label,
				edge,
				route_t,
				f32(0.68),
				f32(0.42),
				seed,
				transient_arena,
			)
			terrain_generation_benchmark_cave_view_capture(
				diag_negative_label,
				edge,
				route_t,
				f32(-0.68),
				f32(0.42),
				seed,
				transient_arena,
			)
		}

		terrain_generation_benchmark_cave_slice_capture_for_selection :: proc(
			label: string,
			selection: TerrainGenerationBenchmarkCaveSelection,
			seed: u32,
			transient_arena: ^mem.Arena,
		) {
			if !selection.found_matching_biome {
				log.infof("TERRAIN_GENERATION_CAVE_SLICE_SKIP label=%s", label)
				return
			}
			terrain_generation_benchmark_cave_slice_capture(
				label,
				selection.node,
				.Horizontal_XZ,
				seed,
				transient_arena,
			)
			terrain_generation_benchmark_cave_slice_capture(
				label,
				selection.node,
				.Vertical_XY,
				seed,
				transient_arena,
			)
		}

		terrain_generation_benchmark_cave_profile_room_radius_y :: proc(
			node: biomes.CaveNetworkNode,
		) -> f32 {
			radius_y := node.radius_blocks * 0.85
			#partial switch node.kind {
			case .Biome_Hub:
				radius_y *= 0.78
			case .Underground_Lake:
				radius_y *= 0.55
			case .River_Junction:
				radius_y *= 0.72
			case .Vertical_Shaft:
				radius_y *= 1.75
			case .Geode_Chamber:
				radius_y *= 1.05
			case .Magma_Pocket:
				radius_y *= 0.70
			}
			max_radius_y := TERRAIN_CAVE_NODE_PROFILE_ROOM_MAJOR_MAX_Y
			radius_scale := f32(1)
			if !node.major_region {
				max_radius_y = TERRAIN_CAVE_NODE_PROFILE_ROOM_MINOR_MAX_Y
				radius_scale = TERRAIN_CAVE_NODE_PROFILE_ROOM_MINOR_SCALE
			}
			return math.min(radius_y * radius_scale, max_radius_y)
		}

		terrain_generation_benchmark_cave_profile_room_radii :: proc(
			node: biomes.CaveNetworkNode,
		) -> (
			room_radius_x, room_radius_y, room_radius_z: f32,
		) {
			radius_x := node.radius_blocks
			radius_y := node.radius_blocks * 0.85
			radius_z := node.radius_blocks
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
			max_radius_xz := TERRAIN_CAVE_NODE_PROFILE_ROOM_MAJOR_MAX_XZ
			max_radius_y := TERRAIN_CAVE_NODE_PROFILE_ROOM_MAJOR_MAX_Y
			radius_scale := f32(1)
			if !node.major_region {
				max_radius_xz = TERRAIN_CAVE_NODE_PROFILE_ROOM_MINOR_MAX_XZ
				max_radius_y = TERRAIN_CAVE_NODE_PROFILE_ROOM_MINOR_MAX_Y
				radius_scale = TERRAIN_CAVE_NODE_PROFILE_ROOM_MINOR_SCALE
			}
			room_radius_x = math.min(radius_x * radius_scale, max_radius_xz)
			room_radius_y = math.min(radius_y * radius_scale, max_radius_y)
			room_radius_z = math.min(radius_z * radius_scale, max_radius_xz)
			return
		}

		terrain_generation_benchmark_cave_profile_room_axis :: proc(
			key: biomes.FeatureGridKey,
			node: biomes.CaveNetworkNode,
		) -> (
			axis_x, axis_z, side_x, side_z: f32,
		) {
			axis_x = biomes.regional_terrain_field_value_noise_3(
				key,
				i32(math.floor_f32(node.x)),
				i32(math.floor_f32(node.y)),
				i32(math.floor_f32(node.z)),
				56,
				TERRAIN_CAVE_BRANCH_SALT,
			)
			axis_z = biomes.regional_terrain_field_value_noise_3(
				key,
				i32(math.floor_f32(node.x)) + 11,
				i32(math.floor_f32(node.y)),
				i32(math.floor_f32(node.z)) - 7,
				56,
				TERRAIN_CAVE_BRANCH_SALT,
			)
			axis_len := math.sqrt_f32(axis_x * axis_x + axis_z * axis_z)
			if axis_len <= 0.001 {
				axis_x, axis_z = 1, 0
			} else {
				axis_x /= axis_len
				axis_z /= axis_len
			}
			side_x = -axis_z
			side_z = axis_x
			return
		}

		terrain_generation_benchmark_cave_profile_room_view_capture_for_selection :: proc(
			label: string,
			key: biomes.FeatureGridKey,
			selection: TerrainGenerationBenchmarkCaveSelection,
			seed: u32,
			transient_arena: ^mem.Arena,
		) {
			if !selection.found_matching_biome {
				log.infof(
					"TERRAIN_GENERATION_CAVE_PROFILE_VIEW_SKIP label=%s reason=no_selection",
					label,
				)
				return
			}
			if !terrain_density_cave_node_uses_profile_room(selection.node) {
				log.infof(
					"TERRAIN_GENERATION_CAVE_PROFILE_VIEW_SKIP label=%s reason=non_profile_node node=%d biome=%v kind=%v major=%v",
					label,
					selection.node.id,
					selection.node.biome_id,
					selection.node.kind,
					selection.node.major_region,
				)
				return
			}

			room_radius_x, room_radius_y, room_radius_z :=
				terrain_generation_benchmark_cave_profile_room_radii(selection.node)
			axis_x, axis_z, side_x, side_z := terrain_generation_benchmark_cave_profile_room_axis(
				key,
				selection.node,
			)
			room_radius_xz := math.min(room_radius_x, room_radius_z)

			camera_axis_scale := f32(-0.52)
			target_axis_scale := f32(0.62)
			camera_side_scale := f32(0.18)
			target_side_scale := f32(-0.12)
			camera_y_scale := f32(0.04)
			target_y_scale := f32(0.14)
			#partial switch selection.node.biome_id {
			case .Fungal_Vaults:
				camera_axis_scale = -0.48
				target_axis_scale = TERRAIN_FUNGAL_ROOM_ALCOVE_OFFSET_SCALE
				camera_side_scale = 0.22
				target_side_scale = -0.10
				camera_y_scale = TERRAIN_FUNGAL_ROOM_LOWER_Y_OFFSET_SCALE * f32(0.30)
				target_y_scale = TERRAIN_FUNGAL_ROOM_DOME_Y_OFFSET_SCALE * f32(0.62)
			case .Crystal_Geode_Network:
				camera_axis_scale = -0.48
				target_axis_scale = 0.56
				camera_side_scale = 0.18
				target_side_scale = -0.12
				camera_y_scale = TERRAIN_CRYSTAL_ROOM_FISSURE_UPPER_Y_SCALE * f32(0.64)
				target_y_scale = TERRAIN_CRYSTAL_ROOM_MAIN_Y_SCALE * f32(0.34)
			case .Buried_Aquifer_Caves:
				camera_axis_scale = -0.46
				target_axis_scale = 0.54
				camera_side_scale = 0.36
				target_side_scale = -0.28
				camera_y_scale = TERRAIN_AQUIFER_ROOM_SHELF_Y_OFFSET_SCALE * f32(0.62)
				target_y_scale = TERRAIN_AQUIFER_ROOM_BASIN_Y_OFFSET_SCALE * f32(0.42)
			case .Temperate_Hills,
			     .Old_Growth_Forest,
			     .Basalt_Spire_Highlands,
			     .Emberglass_Badlands,
			     .Wet_Lowland_Marsh,
			     .Corrupted_Ash_Forest,
			     .Corrupted_Fen:
			}

			camera_x :=
				selection.node.x +
				axis_x * room_radius_x * camera_axis_scale +
				side_x * room_radius_xz * camera_side_scale
			camera_y := selection.node.y + room_radius_y * camera_y_scale
			camera_z :=
				selection.node.z +
				axis_z * room_radius_z * camera_axis_scale +
				side_z * room_radius_xz * camera_side_scale
			target_x :=
				selection.node.x +
				axis_x * room_radius_x * target_axis_scale +
				side_x * room_radius_xz * target_side_scale
			target_y := selection.node.y + room_radius_y * target_y_scale
			target_z :=
				selection.node.z +
				axis_z * room_radius_z * target_axis_scale +
				side_z * room_radius_xz * target_side_scale

			forward_x := target_x - camera_x
			forward_y := target_y - camera_y
			forward_z := target_z - camera_z
			log.infof(
				"TERRAIN_GENERATION_CAVE_PROFILE_VIEW_SELECTION label=%s node=%d biome=%v kind=%v role=%v major=%v chunk=(%d,%d,%d) radius=(%.2f,%.2f,%.2f) axis=(%.3f,%.3f) side=(%.3f,%.3f) camera=(%.2f,%.2f,%.2f) target=(%.2f,%.2f,%.2f)",
				label,
				selection.node.id,
				selection.node.biome_id,
				selection.node.kind,
				selection.node.role,
				selection.node.major_region,
				selection.chunk.x,
				selection.chunk.y,
				selection.chunk.z,
				room_radius_x,
				room_radius_y,
				room_radius_z,
				axis_x,
				axis_z,
				side_x,
				side_z,
				camera_x,
				camera_y,
				camera_z,
				target_x,
				target_y,
				target_z,
			)
			terrain_generation_benchmark_cave_view_capture_basis(
				label,
				0,
				camera_x,
				camera_y,
				camera_z,
				forward_x,
				forward_y,
				forward_z,
				side_x,
				0,
				side_z,
				0,
				1,
				0,
				seed,
				transient_arena,
			)
		}

		terrain_generation_benchmark_aquifer_water_slice_capture_for_selection :: proc(
			label: string,
			selection: TerrainGenerationBenchmarkCaveSelection,
			seed: u32,
			transient_arena: ^mem.Arena,
		) {
			if !selection.found_matching_biome {
				log.infof("TERRAIN_GENERATION_CAVE_SLICE_SKIP label=%s", label)
				return
			}
			room_radius_y := terrain_generation_benchmark_cave_profile_room_radius_y(
				selection.node,
			)
			water_y := selection.node.y + room_radius_y * TERRAIN_AQUIFER_ROOM_WATER_Y_OFFSET_SCALE
			terrain_generation_benchmark_cave_slice_capture_basis(
				label,
				.Horizontal_XZ,
				selection.node.x,
				water_y,
				selection.node.z,
				1,
				0,
				0,
				0,
				0,
				-1,
				seed,
				transient_arena,
			)
		}

		terrain_generation_benchmark_cave_field_pocket_basis :: proc(
			selection: TerrainGenerationBenchmarkCaveFieldPocketSelection,
		) -> (
			tangent_x, tangent_z, outward_x, outward_z: f32,
		) {
			outward_x = selection.center_x - selection.nearest_x
			outward_z = selection.center_z - selection.nearest_z
			outward_len := math.sqrt_f32(outward_x * outward_x + outward_z * outward_z)
			if outward_len <= 0.001 {
				route_len := math.sqrt_f32(
					selection.route_dir_x * selection.route_dir_x +
					selection.route_dir_z * selection.route_dir_z,
				)
				if route_len > 0.001 {
					outward_x = -selection.route_dir_z / route_len
					outward_z = selection.route_dir_x / route_len
				} else {
					outward_x = 1
					outward_z = 0
				}
			} else {
				outward_x /= outward_len
				outward_z /= outward_len
			}

			tangent_x = selection.route_dir_x
			tangent_z = selection.route_dir_z
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
			return
		}

		terrain_generation_benchmark_cave_field_pocket_slice_capture :: proc(
			label: string,
			key: biomes.FeatureGridKey,
			seed: u32,
			transient_arena: ^mem.Arena,
			biome_filter: biomes.BiomeID = {},
			filter_active: bool = false,
		) {
			selection := terrain_generation_benchmark_cave_field_pocket_selection(
				key,
				biome_filter,
				filter_active,
			)
			terrain_generation_benchmark_cave_field_pocket_selection_log(selection)
			if !selection.found {
				log.infof("TERRAIN_GENERATION_CAVE_SLICE_SKIP label=%s", label)
				return
			}

			tangent_x, tangent_z, outward_x, outward_z :=
				terrain_generation_benchmark_cave_field_pocket_basis(selection)
			log.infof(
				"TERRAIN_GENERATION_CAVE_FIELD_POCKET_SLICE_SELECTION label=%s center=(%.2f,%.2f,%.2f) tangent=(%.3f,%.3f) outward=(%.3f,%.3f) radius=%.2f route_radius=%.2f biome=%v",
				label,
				selection.center_x,
				selection.center_y,
				selection.center_z,
				tangent_x,
				tangent_z,
				outward_x,
				outward_z,
				selection.radius,
				selection.route_radius,
				selection.biome_id,
			)
			terrain_generation_benchmark_cave_slice_capture_basis(
				label,
				.Route_Plan,
				selection.center_x,
				selection.center_y,
				selection.center_z,
				tangent_x,
				0,
				tangent_z,
				outward_x,
				0,
				outward_z,
				seed,
				transient_arena,
			)
			terrain_generation_benchmark_cave_slice_capture_basis(
				label,
				.Route_Cross_Section,
				selection.center_x,
				selection.center_y,
				selection.center_z,
				outward_x,
				0,
				outward_z,
				0,
				1,
				0,
				seed,
				transient_arena,
			)
			terrain_generation_benchmark_cave_slice_capture_basis(
				label,
				.Route_Longitudinal,
				selection.center_x,
				selection.center_y,
				selection.center_z,
				tangent_x,
				0,
				tangent_z,
				0,
				1,
				0,
				seed,
				transient_arena,
			)
		}

		terrain_generation_benchmark_cave_slice_target_enabled :: proc(target: int) -> bool {
			return(
				terrain_generation_benchmark_cave_slice_selected_target ==
					TERRAIN_GENERATION_BENCHMARK_CAVE_SLICE_TARGET_ALL ||
				terrain_generation_benchmark_cave_slice_selected_target == target \
			)
		}

		terrain_generation_benchmark_cave_slice_capture_runs_run :: proc(
			key: biomes.FeatureGridKey,
			seed: u32,
			transient_arena: ^mem.Arena,
		) {
			log.infof(
				"TERRAIN_GENERATION_CAVE_SLICE_CAPTURE_START target=%d",
				terrain_generation_benchmark_cave_slice_selected_target,
			)
			if terrain_generation_benchmark_cave_slice_target_enabled(
				TERRAIN_GENERATION_BENCHMARK_CAVE_SLICE_TARGET_CAVE_FIELD_POCKET,
			) {
				terrain_generation_benchmark_cave_field_pocket_slice_capture(
					"cave_field_pocket",
					key,
					seed,
					transient_arena,
				)
			}
			if terrain_generation_benchmark_cave_slice_target_enabled(
				TERRAIN_GENERATION_BENCHMARK_CAVE_SLICE_TARGET_CAVE_FIELD_CRYSTAL_POCKET,
			) {
				terrain_generation_benchmark_cave_field_pocket_slice_capture(
					"cave_field_crystal_pocket",
					key,
					seed,
					transient_arena,
					.Crystal_Geode_Network,
					true,
				)
			}
			if terrain_generation_benchmark_cave_slice_target_enabled(
				TERRAIN_GENERATION_BENCHMARK_CAVE_SLICE_TARGET_CAVE_FIELD_AQUIFER_POCKET,
			) {
				terrain_generation_benchmark_cave_field_pocket_slice_capture(
					"cave_field_aquifer_pocket",
					key,
					seed,
					transient_arena,
					.Buried_Aquifer_Caves,
					true,
				)
			}
			if terrain_generation_benchmark_cave_slice_target_enabled(
				   TERRAIN_GENERATION_BENCHMARK_CAVE_SLICE_TARGET_FUNGAL,
			   ) ||
			   terrain_generation_benchmark_cave_slice_target_enabled(
				   TERRAIN_GENERATION_BENCHMARK_CAVE_SLICE_TARGET_FUNGAL_ROUTE,
			   ) ||
			   terrain_generation_benchmark_cave_slice_target_enabled(
				   TERRAIN_GENERATION_BENCHMARK_CAVE_SLICE_TARGET_FUNGAL_PORTAL,
			   ) ||
			   terrain_generation_benchmark_cave_slice_target_enabled(
				   TERRAIN_GENERATION_BENCHMARK_CAVE_SLICE_TARGET_FUNGAL_CLUSTER,
			   ) ||
			   terrain_generation_benchmark_cave_slice_target_enabled(
				   TERRAIN_GENERATION_BENCHMARK_CAVE_SLICE_TARGET_MACRO_CLUSTERS,
			   ) ||
			   terrain_generation_benchmark_cave_slice_target_enabled(
				   TERRAIN_GENERATION_BENCHMARK_CAVE_SLICE_TARGET_CHAMBERLET_CHAIN,
			   ) ||
			   terrain_generation_benchmark_cave_slice_target_enabled(
				   TERRAIN_GENERATION_BENCHMARK_CAVE_SLICE_TARGET_CHAMBERLET_GALLERY,
			   ) ||
			   terrain_generation_benchmark_cave_slice_target_enabled(
				   TERRAIN_GENERATION_BENCHMARK_CAVE_SLICE_TARGET_PROFILE_VIEW,
			   ) {
				fungal_selection := terrain_generation_benchmark_cave_selection_for_biome(
					key,
					.Fungal_Vaults,
					{x = 0, y = -1, z = 0},
				)
				if terrain_generation_benchmark_cave_slice_target_enabled(
					TERRAIN_GENERATION_BENCHMARK_CAVE_SLICE_TARGET_FUNGAL,
				) {
					terrain_generation_benchmark_cave_slice_capture_for_selection(
						"fungal",
						fungal_selection,
						seed,
						transient_arena,
					)
				}
				if terrain_generation_benchmark_cave_slice_target_enabled(
					TERRAIN_GENERATION_BENCHMARK_CAVE_SLICE_TARGET_FUNGAL_ROUTE,
				) {
					terrain_generation_benchmark_cave_route_slice_capture_for_selection(
						"fungal_route",
						fungal_selection,
						key,
						seed,
						transient_arena,
					)
				}
				if terrain_generation_benchmark_cave_slice_target_enabled(
					TERRAIN_GENERATION_BENCHMARK_CAVE_SLICE_TARGET_FUNGAL_PORTAL,
				) {
					terrain_generation_benchmark_cave_portal_slice_capture_for_selection(
						"fungal_portal",
						fungal_selection,
						key,
						seed,
						transient_arena,
					)
				}
				if terrain_generation_benchmark_cave_slice_target_enabled(
					   TERRAIN_GENERATION_BENCHMARK_CAVE_SLICE_TARGET_FUNGAL_CLUSTER,
				   ) ||
				   terrain_generation_benchmark_cave_slice_target_enabled(
					   TERRAIN_GENERATION_BENCHMARK_CAVE_SLICE_TARGET_MACRO_CLUSTERS,
				   ) {
					terrain_generation_benchmark_cave_macro_cluster_slice_capture_for_selection(
						"fungal_cluster",
						fungal_selection,
						seed,
						transient_arena,
					)
				}
				if terrain_generation_benchmark_cave_slice_target_enabled(
					TERRAIN_GENERATION_BENCHMARK_CAVE_SLICE_TARGET_PROFILE_VIEW,
				) {
					terrain_generation_benchmark_cave_profile_room_view_capture_for_selection(
						"profile_view_fungal",
						key,
						fungal_selection,
						seed,
						transient_arena,
					)
				}
				if terrain_generation_benchmark_cave_slice_target_enabled(
					TERRAIN_GENERATION_BENCHMARK_CAVE_SLICE_TARGET_CHAMBERLET_CHAIN,
				) {
					terrain_generation_benchmark_cave_chamberlet_chain_slice_capture_for_selection(
						"chamberlet_chain",
						fungal_selection,
						key,
						seed,
						transient_arena,
					)
				}
				if terrain_generation_benchmark_cave_slice_target_enabled(
					TERRAIN_GENERATION_BENCHMARK_CAVE_SLICE_TARGET_CHAMBERLET_GALLERY,
				) {
					terrain_generation_benchmark_cave_chamberlet_gallery_slice_capture_for_selection(
						"chamberlet_gallery",
						fungal_selection,
						key,
						seed,
						transient_arena,
					)
				}
			}
			if terrain_generation_benchmark_cave_slice_target_enabled(
				TERRAIN_GENERATION_BENCHMARK_CAVE_SLICE_TARGET_SEAMS,
			) {
				terrain_generation_benchmark_cave_seam_slice_capture(
					"seam_x",
					key,
					{x = 0, y = -1, z = 0},
					0,
					true,
					seed,
					transient_arena,
				)
				terrain_generation_benchmark_cave_seam_slice_capture(
					"seam_z",
					key,
					{x = 0, y = -1, z = 0},
					2,
					true,
					seed,
					transient_arena,
				)
			}
			if terrain_generation_benchmark_cave_slice_target_enabled(
				TERRAIN_GENERATION_BENCHMARK_CAVE_SLICE_TARGET_SEAM_VIEW,
			) {
				terrain_generation_benchmark_cave_seam_view_capture(
					"seam_x_forward",
					"seam_x_diag_pos",
					"seam_x_diag_neg",
					key,
					{x = 0, y = -1, z = 0},
					0,
					true,
					seed,
					transient_arena,
				)
				terrain_generation_benchmark_cave_seam_view_capture(
					"seam_z_forward",
					"seam_z_diag_pos",
					"seam_z_diag_neg",
					key,
					{x = 0, y = -1, z = 0},
					2,
					true,
					seed,
					transient_arena,
				)
			}
			if terrain_generation_benchmark_cave_slice_target_enabled(
				   TERRAIN_GENERATION_BENCHMARK_CAVE_SLICE_TARGET_CRYSTAL,
			   ) ||
			   terrain_generation_benchmark_cave_slice_target_enabled(
				   TERRAIN_GENERATION_BENCHMARK_CAVE_SLICE_TARGET_CRYSTAL_PORTAL,
			   ) ||
			   terrain_generation_benchmark_cave_slice_target_enabled(
				   TERRAIN_GENERATION_BENCHMARK_CAVE_SLICE_TARGET_CRYSTAL_CLUSTER,
			   ) ||
			   terrain_generation_benchmark_cave_slice_target_enabled(
				   TERRAIN_GENERATION_BENCHMARK_CAVE_SLICE_TARGET_MACRO_CLUSTERS,
			   ) ||
			   terrain_generation_benchmark_cave_slice_target_enabled(
				   TERRAIN_GENERATION_BENCHMARK_CAVE_SLICE_TARGET_PROFILE_VIEW,
			   ) {
				crystal_selection := terrain_generation_benchmark_cave_selection_for_biome(
					key,
					.Crystal_Geode_Network,
					{x = 1, y = -1, z = 0},
				)
				if terrain_generation_benchmark_cave_slice_target_enabled(
					TERRAIN_GENERATION_BENCHMARK_CAVE_SLICE_TARGET_CRYSTAL,
				) {
					terrain_generation_benchmark_cave_slice_capture_for_selection(
						"crystal",
						crystal_selection,
						seed,
						transient_arena,
					)
				}
				if terrain_generation_benchmark_cave_slice_target_enabled(
					TERRAIN_GENERATION_BENCHMARK_CAVE_SLICE_TARGET_CRYSTAL_PORTAL,
				) {
					terrain_generation_benchmark_cave_portal_slice_capture_for_selection(
						"crystal_portal",
						crystal_selection,
						key,
						seed,
						transient_arena,
					)
				}
				if terrain_generation_benchmark_cave_slice_target_enabled(
					   TERRAIN_GENERATION_BENCHMARK_CAVE_SLICE_TARGET_CRYSTAL_CLUSTER,
				   ) ||
				   terrain_generation_benchmark_cave_slice_target_enabled(
					   TERRAIN_GENERATION_BENCHMARK_CAVE_SLICE_TARGET_MACRO_CLUSTERS,
				   ) {
					terrain_generation_benchmark_cave_macro_cluster_slice_capture_for_selection(
						"crystal_cluster",
						crystal_selection,
						seed,
						transient_arena,
					)
				}
				if terrain_generation_benchmark_cave_slice_target_enabled(
					TERRAIN_GENERATION_BENCHMARK_CAVE_SLICE_TARGET_PROFILE_VIEW,
				) {
					terrain_generation_benchmark_cave_profile_room_view_capture_for_selection(
						"profile_view_crystal",
						key,
						crystal_selection,
						seed,
						transient_arena,
					)
				}
			}
			if terrain_generation_benchmark_cave_slice_target_enabled(
				   TERRAIN_GENERATION_BENCHMARK_CAVE_SLICE_TARGET_AQUIFER,
			   ) ||
			   terrain_generation_benchmark_cave_slice_target_enabled(
				   TERRAIN_GENERATION_BENCHMARK_CAVE_SLICE_TARGET_AQUIFER_PORTAL,
			   ) ||
			   terrain_generation_benchmark_cave_slice_target_enabled(
				   TERRAIN_GENERATION_BENCHMARK_CAVE_SLICE_TARGET_AQUIFER_CLUSTER,
			   ) ||
			   terrain_generation_benchmark_cave_slice_target_enabled(
				   TERRAIN_GENERATION_BENCHMARK_CAVE_SLICE_TARGET_AQUIFER_WATER,
			   ) ||
			   terrain_generation_benchmark_cave_slice_target_enabled(
				   TERRAIN_GENERATION_BENCHMARK_CAVE_SLICE_TARGET_MACRO_CLUSTERS,
			   ) ||
			   terrain_generation_benchmark_cave_slice_target_enabled(
				   TERRAIN_GENERATION_BENCHMARK_CAVE_SLICE_TARGET_PROFILE_VIEW,
			   ) {
				aquifer_selection := terrain_generation_benchmark_cave_selection_for_biome(
					key,
					.Buried_Aquifer_Caves,
					{x = 0, y = -1, z = 1},
				)
				if terrain_generation_benchmark_cave_slice_target_enabled(
					TERRAIN_GENERATION_BENCHMARK_CAVE_SLICE_TARGET_AQUIFER,
				) {
					terrain_generation_benchmark_cave_slice_capture_for_selection(
						"aquifer",
						aquifer_selection,
						seed,
						transient_arena,
					)
				}
				if terrain_generation_benchmark_cave_slice_target_enabled(
					TERRAIN_GENERATION_BENCHMARK_CAVE_SLICE_TARGET_AQUIFER_PORTAL,
				) {
					terrain_generation_benchmark_cave_portal_slice_capture_for_selection(
						"aquifer_portal",
						aquifer_selection,
						key,
						seed,
						transient_arena,
					)
				}
				if terrain_generation_benchmark_cave_slice_target_enabled(
					   TERRAIN_GENERATION_BENCHMARK_CAVE_SLICE_TARGET_AQUIFER_CLUSTER,
				   ) ||
				   terrain_generation_benchmark_cave_slice_target_enabled(
					   TERRAIN_GENERATION_BENCHMARK_CAVE_SLICE_TARGET_MACRO_CLUSTERS,
				   ) {
					terrain_generation_benchmark_cave_macro_cluster_slice_capture_for_selection(
						"aquifer_cluster",
						aquifer_selection,
						seed,
						transient_arena,
					)
				}
				if terrain_generation_benchmark_cave_slice_target_enabled(
					TERRAIN_GENERATION_BENCHMARK_CAVE_SLICE_TARGET_AQUIFER_WATER,
				) {
					terrain_generation_benchmark_aquifer_water_slice_capture_for_selection(
						"aquifer_water",
						aquifer_selection,
						seed,
						transient_arena,
					)
				}
				if terrain_generation_benchmark_cave_slice_target_enabled(
					TERRAIN_GENERATION_BENCHMARK_CAVE_SLICE_TARGET_PROFILE_VIEW,
				) {
					terrain_generation_benchmark_cave_profile_room_view_capture_for_selection(
						"profile_view_aquifer",
						key,
						aquifer_selection,
						seed,
						transient_arena,
					)
				}
			}
			if terrain_generation_benchmark_cave_slice_target_enabled(
				TERRAIN_GENERATION_BENCHMARK_CAVE_SLICE_TARGET_SURFACE,
			) {
				surface_cave_anchors := terrain_generation_benchmark_surface_cave_anchors_pick(key)
				if surface_cave_anchors.mouth_found {
					terrain_generation_benchmark_mouth_transition_slice_capture(
						"mouth_transition",
						surface_cave_anchors.mouth,
						surface_cave_anchors.mouth_node,
						.Mouth_Longitudinal,
						false,
						seed,
						transient_arena,
					)
					terrain_generation_benchmark_mouth_transition_slice_capture(
						"mouth_transition",
						surface_cave_anchors.mouth,
						surface_cave_anchors.mouth_node,
						.Mouth_Plan,
						false,
						seed,
						transient_arena,
					)
					terrain_generation_benchmark_mouth_transition_slice_capture(
						"mouth_aperture",
						surface_cave_anchors.mouth,
						surface_cave_anchors.mouth_node,
						.Mouth_Longitudinal,
						true,
						seed,
						transient_arena,
					)
					terrain_generation_benchmark_mouth_transition_slice_capture(
						"mouth_aperture",
						surface_cave_anchors.mouth,
						surface_cave_anchors.mouth_node,
						.Mouth_Plan,
						true,
						seed,
						transient_arena,
					)
				} else {
					log.info("TERRAIN_GENERATION_CAVE_SLICE_SKIP label=mouth_transition")
				}
			}
			if terrain_generation_benchmark_cave_slice_target_enabled(
				TERRAIN_GENERATION_BENCHMARK_CAVE_SLICE_TARGET_PROFILE,
			) {
				profile_room := terrain_generation_benchmark_cave_profile_room_selection(
					key,
					{x = 0, y = -1, z = 0},
				)
				profile_selection := TerrainGenerationBenchmarkCaveSelection {
					node                 = profile_room.node,
					chunk                = profile_room.chunk,
					vertical_support     = profile_room.vertical_support,
					found_matching_biome = profile_room.found_matching_biome,
					streamed_underground = profile_room.streamed_underground,
				}
				terrain_generation_benchmark_cave_slice_capture_for_selection(
					"profile_room",
					profile_selection,
					seed,
					transient_arena,
				)
			}
			log.info("TERRAIN_GENERATION_CAVE_SLICE_CAPTURE_END")
		}

		terrain_generation_benchmark_runs_run :: proc(
			transient_arena: ^mem.Arena,
			iterations: u32,
		) {
			log.assert(
				transient_arena != nil,
				"terrain generation benchmark transient arena must not be nil",
			)
			log.assertf(
				iterations > 0,
				"terrain generation benchmark iterations must be greater than zero",
			)

			temp := mem.begin_arena_temp_memory(transient_arena)
			defer mem.end_arena_temp_memory(temp)
			allocator := mem.arena_allocator(transient_arena)

			view := world_async.ChunkVoxelView{}
			chunk_voxel_view_alloc(&view, allocator)
			terrain_generation_chunk_cache_init(context.allocator)
			terrain_generation_chunk_cache_clear()
			terrain_generation_cave_overlay_cache_init(context.allocator)
			terrain_generation_cave_overlay_cache_clear()
			seed := u32(0)
			key := terrain_generation_key_make(seed)
			cave_field_path_selection := terrain_generation_benchmark_cave_field_path_selection(
				key,
			)
			cave_field_pocket_selection :=
				terrain_generation_benchmark_cave_field_pocket_selection(key)
			cave_coords := terrain_generation_benchmark_cave_coords_make(
				key,
				cave_field_path_selection,
			)
			surface_water_coords := terrain_generation_benchmark_surface_water_coords_make(key)
			surface_cave_anchors := terrain_generation_benchmark_surface_cave_anchors_pick(key)
			surface_cave_coords := terrain_generation_benchmark_surface_cave_coords_make(
				surface_cave_anchors,
			)
			surface_morphology_feature_selection :=
				terrain_generation_benchmark_surface_morphology_feature_selection(key)
			surface_morphology_feature_coords :=
				terrain_generation_benchmark_surface_morphology_feature_coords_make(
					surface_morphology_feature_selection,
				)
			surface_fortress_selection := terrain_generation_benchmark_surface_fortress_selection(
				key,
			)
			surface_fortress_coords := terrain_generation_benchmark_surface_fortress_coords_make(
				surface_fortress_selection,
			)

			log.infof(
				"TERRAIN_GENERATION_BENCH_START iterations=%d cave_coords=%d surface_water_coords=%d surface_cave_coords=%d surface_feature_coords=%d surface_fortress_coords=%d chunk_blocks=%d",
				iterations,
				len(cave_coords),
				len(surface_water_coords),
				len(surface_cave_coords),
				len(surface_morphology_feature_coords),
				len(surface_fortress_coords),
				CHUNK_BLOCK_COUNT,
			)
			terrain_generation_benchmark_cave_selections_log(key)
			terrain_generation_benchmark_cave_field_path_selection_log(cave_field_path_selection)
			terrain_generation_benchmark_cave_field_pocket_selection_log(
				cave_field_pocket_selection,
			)
			terrain_generation_benchmark_surface_morphology_feature_selection_log(
				surface_morphology_feature_selection,
			)
			terrain_generation_benchmark_surface_fortress_selection_log(surface_fortress_selection)
			terrain_generation_benchmark_region_stats_log(cave_coords, seed)
			terrain_generation_benchmark_cave_physical_stats_log(
				"cave_physical_pre",
				&view,
				cave_coords,
				seed,
			)
			terrain_generation_benchmark_cave_field_stats_log("cave_field_pre", cave_coords, seed)
			if !TERRAIN_GENERATION_LEGACY_CAVE_ONLY {
				terrain_generation_benchmark_surface_water_stats_log(
					"surface_water_pre",
					surface_water_coords,
					seed,
				)
				terrain_generation_benchmark_surface_shape_stats_log(
					"surface_water_pre",
					surface_water_coords,
					seed,
				)
				terrain_generation_benchmark_surface_morphology_stats_log(
					"surface_water_pre",
					surface_water_coords,
					seed,
				)
				terrain_generation_benchmark_surface_cave_scan_stats_log("surface_cave_scan", key)
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
				terrain_generation_benchmark_surface_shape_stats_log(
					"surface_cave_pre",
					surface_cave_coords,
					seed,
				)
				terrain_generation_benchmark_surface_morphology_stats_log(
					"surface_cave_pre",
					surface_cave_coords,
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
				if surface_morphology_feature_selection.found {
					terrain_generation_benchmark_surface_shape_stats_log(
						"surface_feature_pre",
						surface_morphology_feature_coords,
						seed,
					)
					terrain_generation_benchmark_surface_morphology_stats_log(
						"surface_feature_pre",
						surface_morphology_feature_coords,
						seed,
					)
				}
				if surface_fortress_selection.found {
					terrain_generation_benchmark_surface_shape_stats_log(
						"surface_fortress_pre",
						surface_fortress_coords,
						seed,
					)
				}
			}
			terrain_generation_benchmark_run_phase(
				"cave_hot_region_cache",
				cave_coords,
				seed,
				iterations,
				false,
				&view,
			)
			terrain_generation_benchmark_run_phase(
				"cave_warm_region_column_cache",
				cave_coords,
				seed,
				iterations,
				false,
				&view,
				true,
			)
			terrain_generation_benchmark_run_phase(
				"cave_proxy_anchors",
				cave_coords,
				seed,
				iterations,
				false,
				&view,
				true,
				.Proxy,
			)
			if !TERRAIN_GENERATION_LEGACY_CAVE_ONLY {
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
				if surface_morphology_feature_selection.found {
					terrain_generation_benchmark_run_phase(
						"surface_feature_hot_region_cache",
						surface_morphology_feature_coords,
						seed,
						iterations,
						false,
						&view,
					)
				}
				if surface_fortress_selection.found {
					terrain_generation_benchmark_run_phase(
						"surface_fortress_hot_region_cache",
						surface_fortress_coords,
						seed,
						iterations,
						false,
						&view,
					)
				}
			}
			when TERRAIN_GENERATION_LEGACY_RESET_CACHE {
				terrain_generation_benchmark_run_phase(
					"cave_reset_region_cache",
					cave_coords,
					seed,
					iterations,
					true,
					&view,
				)
				if !TERRAIN_GENERATION_LEGACY_CAVE_ONLY {
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
					if surface_morphology_feature_selection.found {
						terrain_generation_benchmark_run_phase(
							"surface_feature_reset_region_cache",
							surface_morphology_feature_coords,
							seed,
							iterations,
							true,
							&view,
						)
					}
					if surface_fortress_selection.found {
						terrain_generation_benchmark_run_phase(
							"surface_fortress_reset_region_cache",
							surface_fortress_coords,
							seed,
							iterations,
							true,
							&view,
						)
					}
				}
			}
			log.info("TERRAIN_GENERATION_BENCH_END")
		}

	}

	mesh_benchmarks_register :: proc(
		registry: ^bench.BenchmarkRegistry,
		allocator: mem.Allocator,
	) {
		when bench.BENCHMARKS_ENABLED {
			_ = chunk_mesher_benchmark_runs_run
			world_mesh_benchmarks_register(registry, allocator)
		}
	}

	terrain_benchmarks_register :: proc(registry: ^bench.BenchmarkRegistry) {
		when bench.BENCHMARKS_ENABLED {
			_ = terrain_heightfield_voxel_view_fill_profiled
			_ = terrain_heightfield_voxel_view_fill_quality_profiled
			_ = terrain_generation_benchmark_runs_run
			terrain_generation_benchmarks_register(registry)
		}
	}

}
