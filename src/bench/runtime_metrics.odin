package bench

RuntimeFrameWindowSample :: struct {
	samples:                     u32,
	avg_ms:                      f64,
	min_ms:                      f64,
	max_ms:                      f64,
	chunks_generated:            u32,
	chunks_generated_full:       u32,
	chunks_generated_proxy:      u32,
	chunks_refined_full:         u32,
	chunks_prewarmed:            u32,
	chunks_evicted:              u32,
	mesh_submitted:              u32,
	mesh_committed:              u32,
	mesh_uploaded:               u32,
	dirty_remaining_max:         u32,
	draw_units_tested:           u32,
	draw_units_frustum_culled:   u32,
	draw_units_occlusion_culled: u32,
	draw_units_drawn:            u32,
	terrain_triangles_drawn:     u32,
	deferred_geometry:           u32,
	deferred_enqueued:           u64,
	deferred_completed:          u64,
}

RuntimeAutoMoveResult :: struct {
	completed_windows:           u64,
	total_samples:               u64,
	weighted_avg_frame_ms:       f64,
	weighted_fps:                f64,
	max_frame_ms:                f64,
	chunks_generated:            u64,
	chunks_generated_full:       u64,
	chunks_generated_proxy:      u64,
	chunks_refined_full:         u64,
	chunks_prewarmed:            u64,
	chunks_evicted:              u64,
	mesh_submitted:              u64,
	mesh_committed:              u64,
	mesh_uploaded:               u64,
	dirty_remaining_max:         u64,
	draw_units_tested:           u64,
	draw_units_frustum_culled:   u64,
	draw_units_occlusion_culled: u64,
	draw_units_drawn:            u64,
	terrain_triangles_drawn:     u64,
	deferred_geometry:           u64,
	deferred_enqueued:           u64,
	deferred_completed:          u64,
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
	if window.max_ms > result.max_frame_ms {
		result.max_frame_ms = window.max_ms
	}
	result.chunks_generated += u64(window.chunks_generated)
	result.chunks_generated_full += u64(window.chunks_generated_full)
	result.chunks_generated_proxy += u64(window.chunks_generated_proxy)
	result.chunks_refined_full += u64(window.chunks_refined_full)
	result.chunks_prewarmed += u64(window.chunks_prewarmed)
	result.chunks_evicted += u64(window.chunks_evicted)
	result.mesh_submitted += u64(window.mesh_submitted)
	result.mesh_committed += u64(window.mesh_committed)
	result.mesh_uploaded += u64(window.mesh_uploaded)
	if u64(window.dirty_remaining_max) > result.dirty_remaining_max {
		result.dirty_remaining_max = u64(window.dirty_remaining_max)
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
