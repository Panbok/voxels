package bench

RUNTIME_FRAME_TIME_HISTOGRAM_BIN_COUNT :: 512
RUNTIME_FRAME_TIME_HISTOGRAM_BIN_MS :: f64(0.25)
RUNTIME_FRAME_TIME_HISTOGRAM_MAX_MS ::
	RUNTIME_FRAME_TIME_HISTOGRAM_BIN_MS * f64(RUNTIME_FRAME_TIME_HISTOGRAM_BIN_COUNT)

RuntimeFrameWindowSample :: struct {
	samples:                      u32,
	avg_ms:                       f64,
	min_ms:                       f64,
	max_ms:                       f64,
	frame_time_histogram:         [RUNTIME_FRAME_TIME_HISTOGRAM_BIN_COUNT]u32,
	chunks_generated:             u32,
	chunks_generated_full:        u32,
	chunks_generated_proxy:       u32,
	chunks_refined_full:          u32,
	chunks_prewarmed:             u32,
	generation_full_us:           u64,
	generation_proxy_us:          u64,
	generation_refined_full_us:   u64,
	generation_prewarm_us:        u64,
	generation_queue_depth_max:   u32,
	generation_result_depth_max:  u32,
	generation_enqueue_failures:  u64,
	generation_workers_busy_max:  u32,
	generation_worker_jobs:       u64,
	generation_worker_busy_us:    u64,
	mesh_queue_depth_max:         u32,
	mesh_result_depth_max:        u32,
	mesh_enqueue_failures:        u64,
	mesh_workers_busy_max:        u32,
	mesh_worker_jobs:             u64,
	mesh_worker_busy_us:          u64,
	mesh_result_worker_us:        u64,
	chunks_evicted:               u32,
	mesh_submitted:               u32,
	mesh_committed:               u32,
	mesh_uploaded:                u32,
	mesh_empty:                   u32,
	mesh_upload_count:            u32,
	mesh_upload_us:               u64,
	mesh_upload_vertex_bytes:     u64,
	mesh_upload_index_bytes:      u64,
	mesh_upload_bytes:            u64,
	dirty_remaining_max:          u32,
	dirty_meshable_max:           u32,
	dirty_dependency_blocked_max: u32,
	dirty_outside_window_max:     u32,
	draw_units_tested:            u32,
	draw_units_frustum_culled:    u32,
	draw_units_occlusion_culled:  u32,
	draw_units_drawn:             u32,
	terrain_triangles_drawn:      u32,
	deferred_geometry:            u32,
	deferred_enqueued:            u64,
	deferred_completed:           u64,
}

RuntimeAutoMoveResult :: struct {
	completed_windows:            u64,
	total_samples:                u64,
	weighted_avg_frame_ms:        f64,
	weighted_fps:                 f64,
	worst_window_avg_frame_ms:    f64,
	p95_frame_ms:                 f64,
	p99_frame_ms:                 f64,
	max_frame_ms:                 f64,
	frame_time_histogram:         [RUNTIME_FRAME_TIME_HISTOGRAM_BIN_COUNT]u32,
	chunks_generated:             u64,
	chunks_generated_full:        u64,
	chunks_generated_proxy:       u64,
	chunks_refined_full:          u64,
	chunks_prewarmed:             u64,
	generation_full_us:           u64,
	generation_proxy_us:          u64,
	generation_refined_full_us:   u64,
	generation_prewarm_us:        u64,
	generation_queue_depth_max:   u64,
	generation_result_depth_max:  u64,
	generation_enqueue_failures:  u64,
	generation_workers_busy_max:  u64,
	generation_worker_jobs:       u64,
	generation_worker_busy_us:    u64,
	mesh_queue_depth_max:         u64,
	mesh_result_depth_max:        u64,
	mesh_enqueue_failures:        u64,
	mesh_workers_busy_max:        u64,
	mesh_worker_jobs:             u64,
	mesh_worker_busy_us:          u64,
	mesh_result_worker_us:        u64,
	chunks_evicted:               u64,
	mesh_submitted:               u64,
	mesh_committed:               u64,
	mesh_uploaded:                u64,
	mesh_empty:                   u64,
	mesh_committed_upload_gap:    u64,
	mesh_nonempty_upload_gap:     u64,
	mesh_upload_count:            u64,
	mesh_upload_us:               u64,
	mesh_upload_vertex_bytes:     u64,
	mesh_upload_index_bytes:      u64,
	mesh_upload_bytes:            u64,
	dirty_remaining_max:          u64,
	dirty_meshable_max:           u64,
	dirty_dependency_blocked_max: u64,
	dirty_outside_window_max:     u64,
	draw_units_tested:            u64,
	draw_units_frustum_culled:    u64,
	draw_units_occlusion_culled:  u64,
	draw_units_drawn:             u64,
	terrain_triangles_drawn:      u64,
	deferred_geometry:            u64,
	deferred_enqueued:            u64,
	deferred_completed:           u64,
}

runtime_frame_time_histogram_percentile_ms :: proc(
	histogram: []u32,
	sample_count: u64,
	percentile: u64,
) -> f64 {
	if sample_count == 0 {
		return 0
	}
	target := (sample_count * percentile + 99) / 100
	cumulative: u64
	for bin_index in 0 ..< len(histogram) {
		cumulative += u64(histogram[bin_index])
		if cumulative >= target {
			return (f64(bin_index) + 1.0) * RUNTIME_FRAME_TIME_HISTOGRAM_BIN_MS
		}
	}
	return RUNTIME_FRAME_TIME_HISTOGRAM_MAX_MS
}

runtime_auto_move_result_add_window :: proc(
	result: ^RuntimeAutoMoveResult,
	window: RuntimeFrameWindowSample,
) {
	if window.samples == 0 {
		return
	}
	previous_samples := result.total_samples
	result.completed_windows += 1
	result.total_samples += u64(window.samples)
	weighted_sum :=
		result.weighted_avg_frame_ms * f64(previous_samples) + window.avg_ms * f64(window.samples)
	result.weighted_avg_frame_ms = weighted_sum / f64(result.total_samples)
	if result.weighted_avg_frame_ms > 0 {
		result.weighted_fps = 1000.0 / result.weighted_avg_frame_ms
	}
	if window.avg_ms > result.worst_window_avg_frame_ms {
		result.worst_window_avg_frame_ms = window.avg_ms
	}
	if window.max_ms > result.max_frame_ms {
		result.max_frame_ms = window.max_ms
	}
	for bin_index in 0 ..< RUNTIME_FRAME_TIME_HISTOGRAM_BIN_COUNT {
		result.frame_time_histogram[bin_index] += window.frame_time_histogram[bin_index]
	}
	result.p95_frame_ms = runtime_frame_time_histogram_percentile_ms(
		result.frame_time_histogram[:],
		result.total_samples,
		95,
	)
	result.p99_frame_ms = runtime_frame_time_histogram_percentile_ms(
		result.frame_time_histogram[:],
		result.total_samples,
		99,
	)
	result.chunks_generated += u64(window.chunks_generated)
	result.chunks_generated_full += u64(window.chunks_generated_full)
	result.chunks_generated_proxy += u64(window.chunks_generated_proxy)
	result.chunks_refined_full += u64(window.chunks_refined_full)
	result.chunks_prewarmed += u64(window.chunks_prewarmed)
	result.generation_full_us += window.generation_full_us
	result.generation_proxy_us += window.generation_proxy_us
	result.generation_refined_full_us += window.generation_refined_full_us
	result.generation_prewarm_us += window.generation_prewarm_us
	if u64(window.generation_queue_depth_max) > result.generation_queue_depth_max {
		result.generation_queue_depth_max = u64(window.generation_queue_depth_max)
	}
	if u64(window.generation_result_depth_max) > result.generation_result_depth_max {
		result.generation_result_depth_max = u64(window.generation_result_depth_max)
	}
	if window.generation_enqueue_failures > result.generation_enqueue_failures {
		result.generation_enqueue_failures = window.generation_enqueue_failures
	}
	if u64(window.generation_workers_busy_max) > result.generation_workers_busy_max {
		result.generation_workers_busy_max = u64(window.generation_workers_busy_max)
	}
	result.generation_worker_jobs += window.generation_worker_jobs
	result.generation_worker_busy_us += window.generation_worker_busy_us
	if u64(window.mesh_queue_depth_max) > result.mesh_queue_depth_max {
		result.mesh_queue_depth_max = u64(window.mesh_queue_depth_max)
	}
	if u64(window.mesh_result_depth_max) > result.mesh_result_depth_max {
		result.mesh_result_depth_max = u64(window.mesh_result_depth_max)
	}
	if window.mesh_enqueue_failures > result.mesh_enqueue_failures {
		result.mesh_enqueue_failures = window.mesh_enqueue_failures
	}
	if u64(window.mesh_workers_busy_max) > result.mesh_workers_busy_max {
		result.mesh_workers_busy_max = u64(window.mesh_workers_busy_max)
	}
	result.mesh_worker_jobs += window.mesh_worker_jobs
	result.mesh_worker_busy_us += window.mesh_worker_busy_us
	result.mesh_result_worker_us += window.mesh_result_worker_us
	result.chunks_evicted += u64(window.chunks_evicted)
	result.mesh_submitted += u64(window.mesh_submitted)
	result.mesh_committed += u64(window.mesh_committed)
	result.mesh_uploaded += u64(window.mesh_uploaded)
	result.mesh_empty += u64(window.mesh_empty)
	if result.mesh_committed > result.mesh_uploaded {
		result.mesh_committed_upload_gap = result.mesh_committed - result.mesh_uploaded
	} else {
		result.mesh_committed_upload_gap = 0
	}
	uploaded_or_empty := result.mesh_uploaded + result.mesh_empty
	if result.mesh_committed > uploaded_or_empty {
		result.mesh_nonempty_upload_gap = result.mesh_committed - uploaded_or_empty
	} else {
		result.mesh_nonempty_upload_gap = 0
	}
	result.mesh_upload_count += u64(window.mesh_upload_count)
	result.mesh_upload_us += window.mesh_upload_us
	result.mesh_upload_vertex_bytes += window.mesh_upload_vertex_bytes
	result.mesh_upload_index_bytes += window.mesh_upload_index_bytes
	result.mesh_upload_bytes += window.mesh_upload_bytes
	if u64(window.dirty_remaining_max) > result.dirty_remaining_max {
		result.dirty_remaining_max = u64(window.dirty_remaining_max)
	}
	if u64(window.dirty_meshable_max) > result.dirty_meshable_max {
		result.dirty_meshable_max = u64(window.dirty_meshable_max)
	}
	if u64(window.dirty_dependency_blocked_max) > result.dirty_dependency_blocked_max {
		result.dirty_dependency_blocked_max = u64(window.dirty_dependency_blocked_max)
	}
	if u64(window.dirty_outside_window_max) > result.dirty_outside_window_max {
		result.dirty_outside_window_max = u64(window.dirty_outside_window_max)
	}
	result.draw_units_tested += u64(window.draw_units_tested)
	result.draw_units_frustum_culled += u64(window.draw_units_frustum_culled)
	result.draw_units_occlusion_culled += u64(window.draw_units_occlusion_culled)
	result.draw_units_drawn += u64(window.draw_units_drawn)
	result.terrain_triangles_drawn += u64(window.terrain_triangles_drawn)
	if u64(window.deferred_geometry) > result.deferred_geometry {
		result.deferred_geometry = u64(window.deferred_geometry)
	}
	if window.deferred_enqueued > result.deferred_enqueued {
		result.deferred_enqueued = window.deferred_enqueued
	}
	if window.deferred_completed > result.deferred_completed {
		result.deferred_completed = window.deferred_completed
	}
}
