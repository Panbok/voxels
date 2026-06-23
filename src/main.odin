package main

import world "app:world"
import async "async"
import gfx "gfx"
import camera "gfx:camera"
import sdl "vendor:sdl3"

import "core:c"
import "core:log"
import math "core:math"
import "core:mem"
import "core:os"

//////////////////////////////////////
// Constants
/////////////////////////////////////

DEFAULT_ACCELERATION :: f32(1.5)
MAX_ACCELERATION :: f32(20.0)
MOUSE_SENSITIVITY :: f32(0.0025)
AUTO_MOVE_STRESS_TEST :: #config(AUTO_MOVE_STRESS_TEST, false)
AUTO_TEST_FRAME_LIMIT :: #config(AUTO_TEST_FRAME_LIMIT, 0)
AUTO_TEST_DURATION_MS :: #config(AUTO_TEST_DURATION_MS, 0)
LOG_FRAME_METRICS :: #config(LOG_FRAME_METRICS, false)
FRAME_METRICS_LOG_INTERVAL_MS :: #config(FRAME_METRICS_LOG_INTERVAL_MS, 1000)
AUTO_TEST_DISABLE_VSYNC :: #config(AUTO_TEST_DISABLE_VSYNC, false)
AUTO_CAVE_VIEW :: #config(AUTO_CAVE_VIEW, false)
AUTO_CAVE_VIEW_DEBUG_MATERIALS :: #config(AUTO_CAVE_VIEW_DEBUG_MATERIALS, false)
AUTO_CAVE_VIEW_X :: #config(AUTO_CAVE_VIEW_X, 0)
AUTO_CAVE_VIEW_Y :: #config(AUTO_CAVE_VIEW_Y, 0)
AUTO_CAVE_VIEW_Z :: #config(AUTO_CAVE_VIEW_Z, 0)
AUTO_CAVE_VIEW_YAW_DEGREES :: #config(AUTO_CAVE_VIEW_YAW_DEGREES, 0)
AUTO_CAVE_VIEW_PITCH_DEGREES :: #config(AUTO_CAVE_VIEW_PITCH_DEGREES, 0)
PERSISTENT_SLAB_BYTES :: #config(PERSISTENT_SLAB_BYTES, 768 * mem.Megabyte)
TRANSIENT_SLAB_BYTES :: #config(TRANSIENT_SLAB_BYTES, 64 * mem.Megabyte)
RESOURCE_GENERATION_WORKER_MAX :: #config(RESOURCE_GENERATION_WORKER_MAX, 6)
RESOURCE_MESH_WORKER_MAX :: #config(RESOURCE_MESH_WORKER_MAX, 8)
RESOURCE_MESH_REQUESTS_PER_WORKER :: #config(RESOURCE_MESH_REQUESTS_PER_WORKER, 2)
#assert(RESOURCE_GENERATION_WORKER_MAX > 0)
#assert(RESOURCE_MESH_WORKER_MAX > 0)
#assert(RESOURCE_MESH_REQUESTS_PER_WORKER > 0)

//////////////////////////////////////
// State Types
/////////////////////////////////////

Memory :: struct {
	persistent_slab:      []u8,
	transient_slab:       [TRANSIENT_SLAB_BYTES]u8,
	persistent_arena:     mem.Arena,
	transient_arena:      mem.Arena,
	persistent_allocator: mem.Allocator,
	transient_allocator:  mem.Allocator,
}

Metrics :: struct {
	// General frame stats
	frame_count:                              u64,
	current_frame_ms:                         f32,
	current_fps:                              f32,
	auto_test_elapsed_ms:                     f32,
	frame_metrics_accum_ms:                   f32,
	frame_metrics_elapsed_ms:                 f32,
	frame_metrics_min_ms:                     f32,
	frame_metrics_max_ms:                     f32,
	frame_metrics_sample_count:               u32,
	frame_metrics_chunks_generated:           u32,
	frame_metrics_chunks_generated_full:      u32,
	frame_metrics_chunks_generated_proxy:     u32,
	frame_metrics_chunks_refined_full:        u32,
	frame_metrics_chunks_prewarmed:           u32,
	frame_metrics_generation_full_us:         u64,
	frame_metrics_generation_proxy_us:        u64,
	frame_metrics_generation_refined_full_us: u64,
	frame_metrics_generation_prewarm_us:      u64,
	frame_metrics_chunks_evicted:             u32,
	frame_metrics_mesh_submitted:             u32,
	frame_metrics_mesh_committed:             u32,
	frame_metrics_mesh_uploaded:              u32,
	frame_metrics_dirty_remaining_max:        u32,
	frame_metrics_draw_units_tested:          u32,
	frame_metrics_frustum_culled:             u32,
	frame_metrics_occlusion_culled:           u32,
	frame_metrics_draw_units_drawn:           u32,
	frame_metrics_triangles_drawn:            u32,

	// Current frame stats
	chunks_total:                             u32,
	chunks_without_geometry:                  u32,
	chunks_frustum_culled:                    u32,
	chunks_drawn:                             u32,
	terrain_draw_units_tested:                u32,
	terrain_draw_units_frustum_culled:        u32,
	terrain_draw_units_occlusion_culled:      u32,
	terrain_draw_units_drawn:                 u32,
	terrain_faces_drawn:                      u32,
	terrain_triangles_drawn:                  u32,
	terrain_indices_drawn:                    u32,
	chunks_generated:                         u32,
	chunks_generated_full:                    u32,
	chunks_generated_proxy:                   u32,
	chunks_refined_full:                      u32,
	chunks_prewarmed:                         u32,
	generation_full_us:                       u64,
	generation_proxy_us:                      u64,
	generation_refined_full_us:               u64,
	generation_prewarm_us:                    u64,
	chunk_mesh_jobs_submitted:                u32,
	chunk_mesh_results_committed:             u32,
	chunk_mesh_results_uploaded:              u32,
	chunks_dirty_remaining:                   u32,
	chunks_evicted:                           u32,
	deferred_geometry_count:                  u32,
	deferred_release_enqueued_total:          u64,
	deferred_release_completed_total:         u64,

	// Previous frame stats
	prev_chunks_total:                        u32,
	prev_chunks_without_geometry:             u32,
	prev_chunks_frustum_culled:               u32,
	prev_chunks_drawn:                        u32,
	prev_terrain_draw_units_tested:           u32,
	prev_terrain_draw_units_frustum_culled:   u32,
	prev_terrain_draw_units_occlusion_culled: u32,
	prev_terrain_draw_units_drawn:            u32,
	prev_terrain_faces_drawn:                 u32,
	prev_terrain_triangles_drawn:             u32,
	prev_terrain_indices_drawn:               u32,
	prev_chunks_generated:                    u32,
	prev_chunks_generated_full:               u32,
	prev_chunks_generated_proxy:              u32,
	prev_chunks_refined_full:                 u32,
	prev_chunks_prewarmed:                    u32,
	prev_generation_full_us:                  u64,
	prev_generation_proxy_us:                 u64,
	prev_generation_refined_full_us:          u64,
	prev_generation_prewarm_us:               u64,
	prev_chunk_mesh_jobs_submitted:           u32,
	prev_chunk_mesh_results_committed:        u32,
	prev_chunk_mesh_results_uploaded:         u32,
	prev_chunks_dirty_remaining:              u32,
	prev_chunks_evicted:                      u32,
	prev_deferred_geometry_count:             u32,
	prev_deferred_release_enqueued_total:     u64,
	prev_deferred_release_completed_total:    u64,
}

RuntimeResourceConfig :: struct {
	logical_thread_count:    u32,
	generation_worker_count: u32,
	mesh_worker_count:       u32,
	chunk_work_budget:       world.ChunkWorkBudget,
}

//////////////////////////////////////
// State
/////////////////////////////////////

state := struct {
	// Memory
	using memory:    Memory,

	// Metrics
	using metrics:   Metrics,

	// Player
	auto_move_on:    bool,
	sprint_on:       bool,

	// State variables
	debug_mode:      bool,
	enable_vsync:    bool,
	is_window_open:  bool,
	resource_config: RuntimeResourceConfig,
} {
	auto_move_on   = AUTO_MOVE_STRESS_TEST,
	sprint_on      = AUTO_MOVE_STRESS_TEST,
	debug_mode     = true,
	enable_vsync   = !AUTO_TEST_DISABLE_VSYNC,
	is_window_open = true,
}

//////////////////////////////////////
// Memory Methods
/////////////////////////////////////

memory_init :: proc() {
	state.persistent_slab = make([]u8, PERSISTENT_SLAB_BYTES)
	log.assertf(
		len(state.persistent_slab) == PERSISTENT_SLAB_BYTES,
		"persistent slab allocation failed: expected=%d got=%d",
		PERSISTENT_SLAB_BYTES,
		len(state.persistent_slab),
	)

	mem.arena_init(&state.persistent_arena, state.persistent_slab)
	mem.arena_init(&state.transient_arena, state.transient_slab[:])

	state.transient_allocator = mem.arena_allocator(&state.transient_arena)
	state.persistent_allocator = mem.arena_allocator(&state.persistent_arena)
}

//////////////////////////////////////
// Resource Config Methods
/////////////////////////////////////

resource_u32_min :: proc(a, b: u32) -> u32 {
	if a < b {
		return a
	}
	return b
}

resource_u32_max :: proc(a, b: u32) -> u32 {
	if a > b {
		return a
	}
	return b
}

resource_u32_clamp :: proc(value, min_value, max_value: u32) -> u32 {
	return resource_u32_min(resource_u32_max(value, min_value), max_value)
}

resource_logical_thread_count_query :: proc() -> u32 {
	logical_thread_count := os.get_processor_core_count()
	if logical_thread_count < 1 {
		return 1
	}
	return u32(logical_thread_count)
}

runtime_resource_config_make :: proc() -> RuntimeResourceConfig {
	logical_thread_count := resource_logical_thread_count_query()
	reserved_thread_count := u32(1)
	if logical_thread_count >= 6 {
		reserved_thread_count = 2
	}

	background_thread_budget := u32(1)
	if logical_thread_count > reserved_thread_count {
		background_thread_budget = logical_thread_count - reserved_thread_count
	}
	background_thread_budget = resource_u32_max(background_thread_budget, 2)

	generation_worker_count := resource_u32_clamp(
		background_thread_budget / 3,
		1,
		u32(RESOURCE_GENERATION_WORKER_MAX),
	)
	mesh_worker_count := resource_u32_clamp(
		background_thread_budget - generation_worker_count,
		1,
		u32(RESOURCE_MESH_WORKER_MAX),
	)

	return {
		logical_thread_count = logical_thread_count,
		generation_worker_count = generation_worker_count,
		mesh_worker_count = mesh_worker_count,
		chunk_work_budget = {
			generation_requests_per_frame = generation_worker_count,
			generation_results_per_frame = generation_worker_count,
			mesh_requests_per_frame = mesh_worker_count * u32(RESOURCE_MESH_REQUESTS_PER_WORKER),
			mesh_results_per_frame = mesh_worker_count,
		},
	}
}

//////////////////////////////////////
// Metrics Methods
/////////////////////////////////////

metrics_render_stats_apply :: proc(render_stats: gfx.RenderStats) {
	state.chunks_total = render_stats.chunks_total
	state.chunks_without_geometry = render_stats.chunks_without_geometry
	state.chunks_frustum_culled = render_stats.chunks_frustum_culled
	state.chunks_drawn = render_stats.chunks_drawn
	state.terrain_draw_units_tested = render_stats.terrain_draw_units_tested
	state.terrain_draw_units_frustum_culled = render_stats.terrain_draw_units_frustum_culled
	state.terrain_draw_units_occlusion_culled = render_stats.terrain_draw_units_occlusion_culled
	state.terrain_draw_units_drawn = render_stats.terrain_draw_units_drawn
	state.terrain_faces_drawn = render_stats.terrain_faces_drawn
	state.terrain_triangles_drawn = render_stats.terrain_triangles_drawn
	state.terrain_indices_drawn = render_stats.terrain_indices_drawn
	state.deferred_geometry_count = render_stats.deferred_geometry_count
	state.deferred_release_enqueued_total = render_stats.deferred_release_enqueued_total
	state.deferred_release_completed_total = render_stats.deferred_release_completed_total
}

metrics_record_frame :: proc(dt: f32) {
	state.frame_count += 1
	state.current_frame_ms = dt * 1000.0
	state.current_fps = dt > 0 ? 1.0 / dt : 0.0
	state.auto_test_elapsed_ms += state.current_frame_ms
	state.prev_chunks_total = state.chunks_total
	state.prev_chunks_without_geometry = state.chunks_without_geometry
	state.prev_chunks_frustum_culled = state.chunks_frustum_culled
	state.prev_chunks_drawn = state.chunks_drawn
	state.prev_terrain_draw_units_tested = state.terrain_draw_units_tested
	state.prev_terrain_draw_units_frustum_culled = state.terrain_draw_units_frustum_culled
	state.prev_terrain_draw_units_occlusion_culled = state.terrain_draw_units_occlusion_culled
	state.prev_terrain_draw_units_drawn = state.terrain_draw_units_drawn
	state.prev_terrain_faces_drawn = state.terrain_faces_drawn
	state.prev_terrain_triangles_drawn = state.terrain_triangles_drawn
	state.prev_terrain_indices_drawn = state.terrain_indices_drawn
	state.prev_chunks_generated = state.chunks_generated
	state.prev_chunks_generated_full = state.chunks_generated_full
	state.prev_chunks_generated_proxy = state.chunks_generated_proxy
	state.prev_chunks_refined_full = state.chunks_refined_full
	state.prev_chunks_prewarmed = state.chunks_prewarmed
	state.prev_generation_full_us = state.generation_full_us
	state.prev_generation_proxy_us = state.generation_proxy_us
	state.prev_generation_refined_full_us = state.generation_refined_full_us
	state.prev_generation_prewarm_us = state.generation_prewarm_us
	state.prev_chunk_mesh_jobs_submitted = state.chunk_mesh_jobs_submitted
	state.prev_chunk_mesh_results_committed = state.chunk_mesh_results_committed
	state.prev_chunk_mesh_results_uploaded = state.chunk_mesh_results_uploaded
	state.prev_chunks_dirty_remaining = state.chunks_dirty_remaining
	state.prev_chunks_evicted = state.chunks_evicted
	state.prev_deferred_geometry_count = state.deferred_geometry_count
	state.prev_deferred_release_enqueued_total = state.deferred_release_enqueued_total
	state.prev_deferred_release_completed_total = state.deferred_release_completed_total

	if state.frame_metrics_sample_count == 0 {
		state.frame_metrics_min_ms = state.current_frame_ms
		state.frame_metrics_max_ms = state.current_frame_ms
	} else {
		state.frame_metrics_min_ms = math.min(state.frame_metrics_min_ms, state.current_frame_ms)
		state.frame_metrics_max_ms = math.max(state.frame_metrics_max_ms, state.current_frame_ms)
	}

	state.frame_metrics_accum_ms += state.current_frame_ms
	state.frame_metrics_elapsed_ms += state.current_frame_ms
	state.frame_metrics_sample_count += 1
	state.frame_metrics_chunks_generated += state.prev_chunks_generated
	state.frame_metrics_chunks_generated_full += state.prev_chunks_generated_full
	state.frame_metrics_chunks_generated_proxy += state.prev_chunks_generated_proxy
	state.frame_metrics_chunks_refined_full += state.prev_chunks_refined_full
	state.frame_metrics_chunks_prewarmed += state.prev_chunks_prewarmed
	state.frame_metrics_generation_full_us += state.prev_generation_full_us
	state.frame_metrics_generation_proxy_us += state.prev_generation_proxy_us
	state.frame_metrics_generation_refined_full_us += state.prev_generation_refined_full_us
	state.frame_metrics_generation_prewarm_us += state.prev_generation_prewarm_us
	state.frame_metrics_chunks_evicted += state.prev_chunks_evicted
	state.frame_metrics_mesh_submitted += state.prev_chunk_mesh_jobs_submitted
	state.frame_metrics_mesh_committed += state.prev_chunk_mesh_results_committed
	state.frame_metrics_mesh_uploaded += state.prev_chunk_mesh_results_uploaded
	state.frame_metrics_draw_units_tested += state.prev_terrain_draw_units_tested
	state.frame_metrics_frustum_culled += state.prev_terrain_draw_units_frustum_culled
	state.frame_metrics_occlusion_culled += state.prev_terrain_draw_units_occlusion_culled
	state.frame_metrics_draw_units_drawn += state.prev_terrain_draw_units_drawn
	state.frame_metrics_triangles_drawn += state.prev_terrain_triangles_drawn
	state.frame_metrics_dirty_remaining_max = math.max(
		state.frame_metrics_dirty_remaining_max,
		state.prev_chunks_dirty_remaining,
	)

	when LOG_FRAME_METRICS {
		if state.frame_metrics_elapsed_ms >= f32(FRAME_METRICS_LOG_INTERVAL_MS) {
			avg_ms := state.frame_metrics_accum_ms / f32(state.frame_metrics_sample_count)
			avg_fps := avg_ms > 0 ? 1000.0 / avg_ms : 0.0
			generation_full_avg_us := f64(0)
			if state.frame_metrics_chunks_generated_full > 0 {
				generation_full_avg_us =
					f64(state.frame_metrics_generation_full_us) /
					f64(state.frame_metrics_chunks_generated_full)
			}
			generation_proxy_avg_us := f64(0)
			if state.frame_metrics_chunks_generated_proxy > 0 {
				generation_proxy_avg_us =
					f64(state.frame_metrics_generation_proxy_us) /
					f64(state.frame_metrics_chunks_generated_proxy)
			}
			generation_refined_full_avg_us := f64(0)
			if state.frame_metrics_chunks_refined_full > 0 {
				generation_refined_full_avg_us =
					f64(state.frame_metrics_generation_refined_full_us) /
					f64(state.frame_metrics_chunks_refined_full)
			}
			generation_prewarm_avg_us := f64(0)
			if state.frame_metrics_chunks_prewarmed > 0 {
				generation_prewarm_avg_us =
					f64(state.frame_metrics_generation_prewarm_us) /
					f64(state.frame_metrics_chunks_prewarmed)
			}
			log.infof(
				"Frame metrics: frame=%d samples=%d avg_ms=%.3f min_ms=%.3f max_ms=%.3f avg_fps=%.1f chunks_generated=%d chunks_generated_full=%d chunks_generated_proxy=%d chunks_refined_full=%d chunks_prewarmed=%d generation_full_avg_us=%.1f generation_proxy_avg_us=%.1f generation_refined_full_avg_us=%.1f generation_prewarm_avg_us=%.1f chunks_evicted=%d mesh_submitted=%d mesh_committed=%d mesh_uploaded=%d dirty_remaining_max=%d draw_units_tested=%d draw_units_frustum_culled=%d draw_units_occlusion_culled=%d draw_units_drawn=%d terrain_triangles_drawn=%d deferred_geometry=%d deferred_enqueued=%d deferred_completed=%d",
				state.frame_count,
				state.frame_metrics_sample_count,
				avg_ms,
				state.frame_metrics_min_ms,
				state.frame_metrics_max_ms,
				avg_fps,
				state.frame_metrics_chunks_generated,
				state.frame_metrics_chunks_generated_full,
				state.frame_metrics_chunks_generated_proxy,
				state.frame_metrics_chunks_refined_full,
				state.frame_metrics_chunks_prewarmed,
				generation_full_avg_us,
				generation_proxy_avg_us,
				generation_refined_full_avg_us,
				generation_prewarm_avg_us,
				state.frame_metrics_chunks_evicted,
				state.frame_metrics_mesh_submitted,
				state.frame_metrics_mesh_committed,
				state.frame_metrics_mesh_uploaded,
				state.frame_metrics_dirty_remaining_max,
				state.frame_metrics_draw_units_tested,
				state.frame_metrics_frustum_culled,
				state.frame_metrics_occlusion_culled,
				state.frame_metrics_draw_units_drawn,
				state.frame_metrics_triangles_drawn,
				state.prev_deferred_geometry_count,
				state.prev_deferred_release_enqueued_total,
				state.prev_deferred_release_completed_total,
			)

			state.frame_metrics_accum_ms = 0
			state.frame_metrics_elapsed_ms = 0
			state.frame_metrics_sample_count = 0
			state.frame_metrics_min_ms = 0
			state.frame_metrics_max_ms = 0
			state.frame_metrics_chunks_generated = 0
			state.frame_metrics_chunks_generated_full = 0
			state.frame_metrics_chunks_generated_proxy = 0
			state.frame_metrics_chunks_refined_full = 0
			state.frame_metrics_chunks_prewarmed = 0
			state.frame_metrics_generation_full_us = 0
			state.frame_metrics_generation_proxy_us = 0
			state.frame_metrics_generation_refined_full_us = 0
			state.frame_metrics_generation_prewarm_us = 0
			state.frame_metrics_chunks_evicted = 0
			state.frame_metrics_mesh_submitted = 0
			state.frame_metrics_mesh_committed = 0
			state.frame_metrics_mesh_uploaded = 0
			state.frame_metrics_dirty_remaining_max = 0
			state.frame_metrics_draw_units_tested = 0
			state.frame_metrics_frustum_culled = 0
			state.frame_metrics_occlusion_culled = 0
			state.frame_metrics_draw_units_drawn = 0
			state.frame_metrics_triangles_drawn = 0
		}
	}

	state.chunks_total = 0
	state.chunks_without_geometry = 0
	state.chunks_frustum_culled = 0
	state.chunks_drawn = 0
	state.terrain_draw_units_tested = 0
	state.terrain_draw_units_frustum_culled = 0
	state.terrain_draw_units_occlusion_culled = 0
	state.terrain_draw_units_drawn = 0
	state.terrain_faces_drawn = 0
	state.terrain_triangles_drawn = 0
	state.terrain_indices_drawn = 0
	state.chunks_generated = 0
	state.chunks_generated_full = 0
	state.chunks_generated_proxy = 0
	state.chunks_refined_full = 0
	state.chunks_prewarmed = 0
	state.generation_full_us = 0
	state.generation_proxy_us = 0
	state.generation_refined_full_us = 0
	state.generation_prewarm_us = 0
	state.chunk_mesh_jobs_submitted = 0
	state.chunk_mesh_results_committed = 0
	state.chunk_mesh_results_uploaded = 0
	state.chunks_dirty_remaining = 0
	state.chunks_evicted = 0
	state.deferred_geometry_count = 0
	state.deferred_release_enqueued_total = 0
	state.deferred_release_completed_total = 0
}

//////////////////////////////////////
// Systems Methods
/////////////////////////////////////

init :: proc() {
	log.debug("Init application")
	state.resource_config = runtime_resource_config_make()
	log.debugf(
		"Runtime resource config: logical_threads=%d generation_workers=%d mesh_workers=%d generation_request_budget=%d mesh_request_budget=%d",
		state.resource_config.logical_thread_count,
		state.resource_config.generation_worker_count,
		state.resource_config.mesh_worker_count,
		state.resource_config.chunk_work_budget.generation_requests_per_frame,
		state.resource_config.chunk_work_budget.mesh_requests_per_frame,
	)

	gfx.init(
		{
			persistent_allocator = state.persistent_allocator,
			transient_allocator = state.transient_allocator,
			transient_arena = &state.transient_arena,
			debug_mode = state.debug_mode,
			enable_vsync = state.enable_vsync,
			window_width = gfx.WINDOW_DEFAULT_WIDTH,
			window_height = gfx.WINDOW_DEFAULT_HEIGHT,
		},
	)

	async.init(
		{
			allocator = state.persistent_allocator,
			generation_worker_count = state.resource_config.generation_worker_count,
			mesh_worker_count = state.resource_config.mesh_worker_count,
			generation_execute = world.generation_job_execute_sync,
			mesh_execute = world.mesh_job_execute_sync,
		},
	)

	log.debug("Application initialized")
}

shutdown :: proc() {
	log.debug("Application shutdown")
	async.shutdown()
	gfx.shutdown()
	log.debug("Shutdown complete")
}

setup_resources :: proc() {
	log.debug("Setting resources")
	gfx.setup_resources()

	world.init(
		{
			persistent_allocator = state.persistent_allocator,
			chunk_work_budget = state.resource_config.chunk_work_budget,
			generation_request = async.generation_request,
			generation_poll_results = async.generation_results_poll,
			mesh_request = async.mesh_request,
			mesh_poll_results = async.mesh_results_poll,
			mesh_release_result = async.mesh_result_release,
			chunk_mesh_upload = gfx.chunk_mesh_upload,
			chunk_geometry_release = gfx.chunk_geometry_release,
		},
	)
	when AUTO_CAVE_VIEW {
		auto_cave_view_camera_apply()
	}
	when ODIN_DEBUG {
		world.debug_chunk_edit_contract_checks_run(&state.transient_arena)
	}
	cam := gfx.camera_get()
	world.streaming_update_for_observer(cam.position)

	log.debug("Resources initialized")
}

when AUTO_CAVE_VIEW {
	auto_cave_view_camera_apply :: proc() {
		cam := gfx.camera_get()
		cam.position = {f32(AUTO_CAVE_VIEW_X), f32(AUTO_CAVE_VIEW_Y), f32(AUTO_CAVE_VIEW_Z)}
		cam.yaw = math.to_radians_f32(f32(AUTO_CAVE_VIEW_YAW_DEGREES))
		cam.pitch = math.to_radians_f32(f32(AUTO_CAVE_VIEW_PITCH_DEGREES))
		camera.vectors_update(cam)
		when AUTO_CAVE_VIEW_DEBUG_MATERIALS {
			gfx.cave_debug_visualization_toggle()
		}
		log.debugf(
			"Auto cave view camera: position=(%.2f,%.2f,%.2f) yaw=%d pitch=%d cave_debug=%v",
			cam.position[0],
			cam.position[1],
			cam.position[2],
			AUTO_CAVE_VIEW_YAW_DEGREES,
			AUTO_CAVE_VIEW_PITCH_DEGREES,
			AUTO_CAVE_VIEW_DEBUG_MATERIALS,
		)
	}
}

destroy_resources :: proc() {
	log.debug("Destroying resources")
	async.shutdown()
	world.shutdown()
	gfx.destroy_resources()
	log.debug("Resources destroyed")
}

process_events :: proc() {
	for event: sdl.Event; sdl.PollEvent(&event); {
		#partial switch event.type {
		case .QUIT:
			log.debug("Quit event received")
			state.is_window_open = false
		case .KEY_DOWN:
			{
				if event.key.scancode == sdl.Scancode.ESCAPE {
					log.debug("Escape key pressed")
					state.is_window_open = false
				}

				if event.key.scancode == sdl.Scancode.G && !event.key.repeat {
					gfx.wireframe_toggle()
				}

				if event.key.scancode == sdl.Scancode.F1 && !event.key.repeat {
					gfx.hydrology_debug_visualization_toggle()
				}

				if event.key.scancode == sdl.Scancode.F2 && !event.key.repeat {
					gfx.cave_debug_visualization_toggle()
				}

				if event.key.scancode == sdl.Scancode.F3 && !event.key.repeat {
					gfx.decoration_debug_visualization_toggle()
				}

				if event.key.scancode == sdl.Scancode.L && !event.key.repeat {
					state.auto_move_on = !state.auto_move_on
				}

				if event.key.scancode == sdl.Scancode.LCTRL && !event.key.repeat {
					state.sprint_on = !state.sprint_on
				}

				if event.key.scancode == sdl.Scancode.I && !event.key.repeat {
					log.debugf(
						"Debug info: streaming_center=(%d,%d,%d), streaming_targets=%d, streaming_prewarm_targets=%d, streaming_prewarm_inflight=%d, streaming_radius_y_down=%d, streaming_radius_y_up=%d, chunks_total=%d, chunks_without_geometry=%d, chunks_frustum_culled=%d, chunks_drawn=%d, draw_units_tested=%d, draw_units_frustum_culled=%d, draw_units_occlusion_culled=%d, draw_units_drawn=%d, terrain_faces_drawn=%d, terrain_triangles_drawn=%d, terrain_indices_drawn=%d, chunks_generated=%d, chunks_generated_full=%d, chunks_generated_proxy=%d, chunks_refined_full=%d, chunks_prewarmed=%d, chunks_evicted=%d, chunk_mesh_jobs_submitted=%d, chunk_mesh_results_committed=%d, chunk_mesh_results_uploaded=%d, chunks_dirty_remaining=%d",
						world.streaming_center_coord().x,
						world.streaming_center_coord().y,
						world.streaming_center_coord().z,
						world.streaming_target_count(),
						world.streaming_prewarm_target_count(),
						world.streaming_prewarm_inflight_count(),
						world.streaming_radius_y_down(),
						world.streaming_radius_y_up(),
						state.prev_chunks_total,
						state.prev_chunks_without_geometry,
						state.prev_chunks_frustum_culled,
						state.prev_chunks_drawn,
						state.prev_terrain_draw_units_tested,
						state.prev_terrain_draw_units_frustum_culled,
						state.prev_terrain_draw_units_occlusion_culled,
						state.prev_terrain_draw_units_drawn,
						state.prev_terrain_faces_drawn,
						state.prev_terrain_triangles_drawn,
						state.prev_terrain_indices_drawn,
						state.prev_chunks_generated,
						state.prev_chunks_generated_full,
						state.prev_chunks_generated_proxy,
						state.prev_chunks_refined_full,
						state.prev_chunks_prewarmed,
						state.prev_chunks_evicted,
						state.prev_chunk_mesh_jobs_submitted,
						state.prev_chunk_mesh_results_committed,
						state.prev_chunk_mesh_results_uploaded,
						state.prev_chunks_dirty_remaining,
					)
				}
			}
		case .MOUSE_MOTION:
			{
				cam := gfx.camera_get()
				cam.yaw -= event.motion.xrel * MOUSE_SENSITIVITY
				cam.pitch -= event.motion.yrel * MOUSE_SENSITIVITY
				cam.pitch = math.clamp(
					cam.pitch,
					math.to_radians_f32(-89.0),
					math.to_radians_f32(89.0),
				)
			}
		}
	}
}

update_camera_vectors :: proc() {
	camera.vectors_update(gfx.camera_get())
}

update :: proc() {
	cam := gfx.camera_get()
	streaming_stats := world.streaming_update_budgeted(cam.position)
	state.chunks_evicted = streaming_stats.chunks_evicted
	state.chunks_generated = streaming_stats.chunks_generated
	state.chunks_generated_full = streaming_stats.chunks_generated_full
	state.chunks_generated_proxy = streaming_stats.chunks_generated_proxy
	state.chunks_refined_full = streaming_stats.chunks_refined_full
	state.chunks_prewarmed = streaming_stats.chunks_prewarmed
	state.generation_full_us = streaming_stats.generation_full_us
	state.generation_proxy_us = streaming_stats.generation_proxy_us
	state.generation_refined_full_us = streaming_stats.generation_refined_full_us
	state.generation_prewarm_us = streaming_stats.generation_prewarm_us
	state.chunk_mesh_jobs_submitted = streaming_stats.chunk_mesh_jobs_submitted
	state.chunk_mesh_results_committed = streaming_stats.chunk_mesh_results_committed
	state.chunk_mesh_results_uploaded = streaming_stats.chunk_mesh_results_uploaded
	state.chunks_dirty_remaining = streaming_stats.chunks_dirty_remaining
	camera.terrain_intersection_resolve(cam)
	gfx.view_projection_update()
}

handle_input :: proc(dt: f32) {
	key_count: c.int
	keys := sdl.GetKeyboardState(&key_count)

	velocity := DEFAULT_ACCELERATION
	if keys[cast(int)sdl.Scancode.LSHIFT] || state.sprint_on {velocity = MAX_ACCELERATION}

	cam := gfx.camera_get()
	velocity = velocity * dt
	if keys[cast(int)sdl.Scancode.W] {cam.position += cam.forward * velocity}
	if keys[cast(int)sdl.Scancode.S] {cam.position -= cam.forward * velocity}
	if keys[cast(int)sdl.Scancode.D] {cam.position -= cam.right * velocity}
	if keys[cast(int)sdl.Scancode.A] {cam.position += cam.right * velocity}

	if state.auto_move_on {
		cam.position += cam.forward * velocity
	}
}

//////////////////////////////////////
// Main
/////////////////////////////////////

main :: proc() {
	context.logger = log.create_console_logger(.Debug)
	defer log.destroy_console_logger(context.logger)

	memory_init()

	context.allocator = state.persistent_allocator
	context.temp_allocator = state.transient_allocator

	when ODIN_DEBUG {
		camera.debug_frustum_contract_checks_run()
		camera_debug_temp := mem.begin_arena_temp_memory(&state.transient_arena)
		camera.debug_terrain_collision_checks_run(state.transient_allocator)
		mem.end_arena_temp_memory(camera_debug_temp)
		world.debug_chunk_mesher_contract_checks_run(&state.transient_arena)
		world.debug_chunk_visibility_contract_checks_run(&state.transient_arena)
		gfx.benchmarks_debug_contracts_run(state.persistent_allocator, &state.transient_arena)
		world.chunk_mesher_benchmarks_debug_contracts_run(&state.transient_arena)

		when world.RUN_MESH_BENCHMARK {
			world.chunk_mesher_benchmark_runs_run(
				&state.transient_arena,
				world.MESH_BENCHMARK_ITERATIONS,
			)
			return
		}

		when world.RUN_TERRAIN_GENERATION_BENCHMARK {
			world.terrain_generation_benchmark_runs_run(
				&state.transient_arena,
				world.TERRAIN_GENERATION_BENCHMARK_ITERATIONS,
			)
			return
		}

		when gfx.RUN_CULLING_BENCHMARK {
			gfx.culling_benchmark_runs_run(
				gfx.CULLING_BENCHMARK_ITERATIONS,
				state.persistent_allocator,
				&state.transient_arena,
			)
			return
		}
	}
	when !ODIN_DEBUG {
		when world.RUN_TERRAIN_GENERATION_BENCHMARK {
			world.terrain_generation_benchmark_runs_run(
				&state.transient_arena,
				world.TERRAIN_GENERATION_BENCHMARK_ITERATIONS,
			)
			return
		}
	}

	init()
	defer shutdown()

	setup_resources()
	defer destroy_resources()

	performance_frequency := f64(sdl.GetPerformanceFrequency())
	current_time := sdl.GetPerformanceCounter()
	for state.is_window_open {
		now := sdl.GetPerformanceCounter()
		dt := f32(f64(now - current_time) / performance_frequency)
		current_time = now

		process_events()
		update_camera_vectors()
		handle_input(dt)
		update()
		render_stats := gfx.render()
		metrics_render_stats_apply(render_stats)
		metrics_record_frame(dt)

		when AUTO_TEST_DURATION_MS > 0 {
			if state.auto_test_elapsed_ms >= f32(AUTO_TEST_DURATION_MS) {
				log.infof(
					"Auto test duration reached: frame=%d elapsed_ms=%.3f",
					state.frame_count,
					state.auto_test_elapsed_ms,
				)
				state.is_window_open = false
			}
		} else {
			when AUTO_TEST_FRAME_LIMIT > 0 {
				if state.frame_count >= AUTO_TEST_FRAME_LIMIT {
					log.infof("Auto test frame limit reached: frame=%d", state.frame_count)
					state.is_window_open = false
				}
			}
		}
	}
}
