package vdebug

import "core:fmt"
import math "core:math"
import "core:os"
import "core:strings"
import time "core:time"

VisualDebugImageBuffer :: struct {
	pixels: []PixelRGBA8,
	width:  u32,
	height: u32,
}

compare_mode_against_baseline :: proc(ctx: ^VisualDebugContext, required: bool) {
	mode := ctx.mode_result
	mode.comparison.status = "skip"
	actual_artifact, actual_ok := mode_actual_image_artifact(mode)
	if !actual_ok {
		mode.comparison.status = "fail"
		mode.comparison.error = "no actual image artifact was available for comparison"
		if required {
			mode.status = .Fail
		}
		return
	}
	if !os.exists(mode.comparison.baseline_path) {
		mode.comparison.status = "missing_baseline"
		mode.comparison.error = "required baseline image is missing"
		if !required {
			mode.comparison.status = "skip"
			mode.comparison.error = "optional baseline image is missing"
		}
		if required {
			mode.status = .Fail
		}
		return
	}

	actual_path := artifact_filesystem_path(ctx, actual_artifact.path)
	actual, actual_read_ok := read_bmp_image(actual_path, ctx.allocator)
	if !actual_read_ok {
		mode.comparison.status = "fail"
		mode.comparison.error = "failed to read actual BMP image"
		mode.status = .Fail
		return
	}
	defer delete(actual.pixels, ctx.allocator)
	expected, expected_read_ok := read_bmp_image(mode.comparison.baseline_path, ctx.allocator)
	if !expected_read_ok {
		mode.comparison.status = "fail"
		mode.comparison.error = "failed to read baseline BMP image"
		mode.status = .Fail
		return
	}
	defer delete(expected.pixels, ctx.allocator)

	if actual.width != expected.width || actual.height != expected.height {
		mode.comparison.status = "fail"
		mode.comparison.error = "actual and baseline dimensions differ"
		mode.status = .Fail
		return
	}

	metrics := image_metrics_compute(actual.pixels, expected.pixels)
	mode.comparison.metrics = metrics
	passed := tolerance_passes(metrics, mode.comparison.tolerance)
	if passed {
		mode.comparison.status = "pass"
		mode.comparison.error = ""
		return
	}

	mode.comparison.status = "fail"
	mode.comparison.error = "image comparison exceeded tolerance"
	mode.status = .Fail
	diff := diff_heatmap_make(
		actual.pixels,
		expected.pixels,
		actual.width,
		actual.height,
		ctx.allocator,
	)
	defer delete(diff, ctx.allocator)
	diff_artifact, diff_ok := artifact_write_bmp(
		ctx,
		"diff_heatmap",
		diff,
		actual.width,
		actual.height,
		"visual_diff.v1",
	)
	if diff_ok {
		diff_artifact_record_add(&mode.comparison, diff_artifact)
	}
}

accept_mode_baseline :: proc(
	options: ^VisualDebugRunnerOptions,
	ctx: ^VisualDebugContext,
	suite: ^VisualDebugSuiteResult,
	baseline_id: string,
	platform_key: string,
	case_name: string,
	case_version: string,
) {
	mode := ctx.mode_result
	actual_artifact, actual_ok := mode_actual_image_artifact(mode)
	if !actual_ok {
		mode.comparison.status = "skip"
		mode.comparison.error = "no actual image artifact was available for accept"
		suite.accept_skipped += 1
		return
	}
	actual_path := artifact_filesystem_path(ctx, actual_artifact.path)
	actual_bytes, read_err := os.read_entire_file(actual_path, ctx.allocator)
	if read_err != nil {
		mode.comparison.status = "fail"
		mode.comparison.error = "failed to read actual artifact for accept"
		mode.status = .Fail
		suite.accept_skipped += 1
		return
	}
	defer delete(actual_bytes, ctx.allocator)

	baseline_dir := baseline_mode_dir(
		options.baseline_dir,
		baseline_id,
		platform_key,
		ctx.allocator,
	)
	if err := os.make_directory_all(baseline_dir); err != nil && !os.is_directory(baseline_dir) {
		mode.comparison.status = "fail"
		mode.comparison.error = "failed to create baseline directory"
		mode.status = .Fail
		suite.accept_skipped += 1
		return
	}

	baseline_path := baseline_image_path(
		options.baseline_dir,
		baseline_id,
		platform_key,
		mode.id,
		ctx.allocator,
	)
	sidecar_path := baseline_sidecar_path(
		options.baseline_dir,
		baseline_id,
		platform_key,
		mode.id,
		ctx.allocator,
	)
	meta_path := path_join2(baseline_dir, "baseline.json", ctx.allocator)
	new_hash := hash_bytes_hex(actual_bytes, ctx.allocator)
	old_hash := ""
	replace := false
	if os.exists(baseline_path) {
		old_bytes, old_err := os.read_entire_file(baseline_path, ctx.allocator)
		if old_err == nil {
			old_hash = hash_bytes_hex(old_bytes, ctx.allocator)
			delete(old_bytes, ctx.allocator)
		}
		if old_hash == new_hash {
			mode.comparison.status = "accepted"
			mode.comparison.accepted = true
			mode.comparison.old_hash = old_hash
			suite.accept_unchanged += 1
			return
		}
		replace = true
	}

	tmp_image := fmt.aprintf("%s.tmp-%d", baseline_path, os.get_pid(), allocator = ctx.allocator)
	if os.exists(tmp_image) {
		_ = os.remove(tmp_image)
	}
	if err := os.write_entire_file(tmp_image, actual_bytes); err != nil {
		mode.comparison.status = "fail"
		mode.comparison.error = "failed to write temporary baseline image"
		mode.status = .Fail
		suite.accept_skipped += 1
		return
	}
	verify_bytes, verify_err := os.read_entire_file(tmp_image, ctx.allocator)
	if verify_err != nil || hash_bytes_hex(verify_bytes, ctx.allocator) != new_hash {
		if verify_err == nil {
			delete(verify_bytes, ctx.allocator)
		}
		_ = os.remove(tmp_image)
		mode.comparison.status = "fail"
		mode.comparison.error = "temporary baseline image hash verification failed"
		mode.status = .Fail
		suite.accept_skipped += 1
		return
	}
	delete(verify_bytes, ctx.allocator)

	sidecar := baseline_sidecar_make(
		ctx,
		actual_artifact,
		baseline_id,
		platform_key,
		case_name,
		case_version,
	)
	tmp_sidecar := fmt.aprintf("%s.tmp-%d", sidecar_path, os.get_pid(), allocator = ctx.allocator)
	tmp_meta := fmt.aprintf("%s.tmp-%d", meta_path, os.get_pid(), allocator = ctx.allocator)
	_ = os.write_entire_file(tmp_sidecar, sidecar)
	_ = os.write_entire_file(tmp_meta, sidecar)
	if replace {
		_ = os.remove(baseline_path)
		_ = os.remove(sidecar_path)
		_ = os.remove(meta_path)
	}
	if os.rename(tmp_image, baseline_path) != nil ||
	   os.rename(tmp_sidecar, sidecar_path) != nil ||
	   os.rename(tmp_meta, meta_path) != nil {
		mode.comparison.status = "fail"
		mode.comparison.error = "failed to publish accepted baseline"
		mode.status = .Fail
		suite.accept_skipped += 1
		return
	}
	mode.comparison.status = "accepted"
	mode.comparison.accepted = true
	mode.comparison.old_hash = old_hash
	mode.comparison.baseline_path = baseline_path
	mode.comparison.baseline_sidecar = sidecar_path
	if replace {
		suite.accept_replaced += 1
	} else {
		suite.accept_created += 1
	}
}

baseline_accept_lock :: proc(baseline_dir: string, allocator := context.allocator) -> bool {
	if err := os.make_directory_all(baseline_dir); err != nil && !os.is_directory(baseline_dir) {
		fmt.eprintfln("failed to create baseline directory %s: %v", baseline_dir, err)
		return false
	}
	lock_path := path_join2(baseline_dir, ".accept.lock", allocator)
	if os.exists(lock_path) {
		fmt.eprintfln("baseline accept lock already exists: %s", lock_path)
		return false
	}
	content := fmt.aprintf("pid=%d\n", os.get_pid(), allocator = allocator)
	return write_file_create_only_atomic(lock_path, transmute([]byte)content, allocator)
}

baseline_accept_unlock :: proc(baseline_dir: string, allocator := context.allocator) {
	lock_path := path_join2(baseline_dir, ".accept.lock", allocator)
	if os.exists(lock_path) {
		_ = os.remove(lock_path)
	}
}

baseline_mode_dir :: proc(
	baseline_root: string,
	baseline_id: string,
	platform_key: string,
	allocator := context.allocator,
) -> string {
	return path_join3(baseline_root, baseline_id, platform_key, allocator)
}

baseline_image_path :: proc(
	baseline_root: string,
	baseline_id: string,
	platform_key: string,
	mode_id: string,
	allocator := context.allocator,
) -> string {
	dir := baseline_mode_dir(baseline_root, baseline_id, platform_key, allocator)
	return path_join2(dir, fmt.aprintf("%s.bmp", mode_id, allocator = allocator), allocator)
}

baseline_sidecar_path :: proc(
	baseline_root: string,
	baseline_id: string,
	platform_key: string,
	mode_id: string,
	allocator := context.allocator,
) -> string {
	dir := baseline_mode_dir(baseline_root, baseline_id, platform_key, allocator)
	return path_join2(dir, fmt.aprintf("%s.json", mode_id, allocator = allocator), allocator)
}

baseline_sidecar_make :: proc(
	ctx: ^VisualDebugContext,
	artifact: VisualDebugArtifactRecord,
	baseline_id: string,
	platform_key: string,
	case_name: string,
	case_version: string,
) -> string {
	builder, _ := strings.builder_make(allocator = ctx.allocator)
	defer strings.builder_destroy(&builder)
	strings.write_string(&builder, "{\n")
	json_write_named_string(&builder, "schema", VISUAL_DEBUG_BASELINE_SCHEMA, 1, true)
	json_write_named_string(&builder, "baseline", baseline_id, 1, true)
	json_write_named_string(&builder, "request_id", ctx.request_id, 1, true)
	json_write_named_string(&builder, "mode_id", ctx.mode_id, 1, true)
	json_write_named_string(&builder, "case", case_name, 1, true)
	json_write_named_string(&builder, "case_version", case_version, 1, true)
	json_write_named_string(&builder, "platform_key", platform_key, 1, true)
	json_write_named_string(
		&builder,
		"created_unix_nano",
		fmt.aprintf("%d", time.time_to_unix_nano(time.now()), allocator = ctx.allocator),
		1,
		true,
	)
	json_indent(&builder, 1)
	strings.write_string(&builder, "\"artifact\": ")
	artifact_record := artifact
	json_write_artifact(&builder, &artifact_record, 1)
	strings.write_string(&builder, "\n}\n")
	return strings.clone(strings.to_string(builder), ctx.allocator)
}

mode_actual_image_artifact :: proc(
	mode: ^VisualDebugModeResult,
) -> (
	VisualDebugArtifactRecord,
	bool,
) {
	for i := u32(0); i < mode.artifact_count; i += 1 {
		artifact := mode.artifacts[i]
		if artifact.kind == "image" && artifact.label == "actual" {
			return artifact, true
		}
	}
	for i := u32(0); i < mode.artifact_count; i += 1 {
		artifact := mode.artifacts[i]
		if artifact.kind == "image" {
			return artifact, true
		}
	}
	return {}, false
}

artifact_filesystem_path :: proc(ctx: ^VisualDebugContext, artifact_path: string) -> string {
	if os.is_absolute_path(artifact_path) {
		return artifact_path
	}
	return path_join2(ctx.output_dir, artifact_path, ctx.allocator)
}

read_bmp_image :: proc(
	path: string,
	allocator := context.allocator,
) -> (
	VisualDebugImageBuffer,
	bool,
) {
	bytes, read_err := os.read_entire_file(path, allocator)
	if read_err != nil {
		return {}, false
	}
	defer delete(bytes, allocator)
	pixels, width, height, ok := bmp_decode_rgba8(bytes, allocator)
	if !ok {
		return {}, false
	}
	return {pixels = pixels, width = width, height = height}, true
}

image_metrics_compute :: proc(actual, expected: []PixelRGBA8) -> VisualDebugComparisonMetrics {
	count := len(actual)
	metrics := VisualDebugComparisonMetrics{}
	if count == 0 || len(expected) != count {
		return metrics
	}
	total_abs: f64
	total_squared: f64
	for i := 0; i < count; i += 1 {
		a := actual[i]
		e := expected[i]
		dr := channel_delta(a.r, e.r)
		dg := channel_delta(a.g, e.g)
		db := channel_delta(a.b, e.b)
		da := channel_delta(a.a, e.a)
		max_delta := max_u32(max_u32(dr, dg), max_u32(db, da))
		if max_delta > 0 {
			metrics.changed_pixels += 1
		}
		if max_delta > metrics.max_channel_delta {
			metrics.max_channel_delta = max_delta
		}
		total_abs += f64(dr + dg + db + da) / 4.0
		total_squared += (f64(dr * dr) + f64(dg * dg) + f64(db * db) + f64(da * da)) / 4.0
	}
	metrics.changed_pixel_ratio = f64(metrics.changed_pixels) / f64(count)
	metrics.mean_abs_error = total_abs / f64(count)
	mse := total_squared / f64(count)
	metrics.rms_error = math.sqrt(mse)
	if mse <= 0 {
		metrics.psnr_infinite = true
	} else {
		metrics.psnr = 20.0 * math.log10(255.0 / math.sqrt(mse))
	}
	return metrics
}

tolerance_passes :: proc(
	metrics: VisualDebugComparisonMetrics,
	tolerance: VisualDebugTolerance,
) -> bool {
	switch tolerance.mode {
	case .Exact:
		return metrics.changed_pixels == 0 && metrics.max_channel_delta == 0
	case .Pixel_Threshold:
		if tolerance.has_max_delta && metrics.max_channel_delta > tolerance.max_channel_delta {
			return false
		}
		if tolerance.has_changed_ratio &&
		   metrics.changed_pixel_ratio > tolerance.changed_pixel_ratio {
			return false
		}
		if !tolerance.has_max_delta && !tolerance.has_changed_ratio {
			return metrics.changed_pixels == 0
		}
		return true
	case .Metric_Threshold, .Masked:
		if tolerance.has_max_delta && metrics.max_channel_delta > tolerance.max_channel_delta {
			return false
		}
		if tolerance.has_mean_abs_error && metrics.mean_abs_error > tolerance.mean_abs_error {
			return false
		}
		if tolerance.has_rms_error && metrics.rms_error > tolerance.rms_error {
			return false
		}
		if tolerance.has_changed_ratio &&
		   metrics.changed_pixel_ratio > tolerance.changed_pixel_ratio {
			return false
		}
		if tolerance.has_psnr_min && !metrics.psnr_infinite && metrics.psnr < tolerance.psnr_min {
			return false
		}
		if !tolerance.has_max_delta &&
		   !tolerance.has_mean_abs_error &&
		   !tolerance.has_rms_error &&
		   !tolerance.has_changed_ratio &&
		   !tolerance.has_psnr_min {
			return metrics.changed_pixels == 0
		}
		return true
	}
	return false
}

diff_heatmap_make :: proc(
	actual, expected: []PixelRGBA8,
	width, height: u32,
	allocator := context.allocator,
) -> []PixelRGBA8 {
	count := int(width * height)
	out := make([]PixelRGBA8, count, allocator)
	for i := 0; i < count; i += 1 {
		a := actual[i]
		e := expected[i]
		max_delta := max_u32(
			max_u32(channel_delta(a.r, e.r), channel_delta(a.g, e.g)),
			max_u32(channel_delta(a.b, e.b), channel_delta(a.a, e.a)),
		)
		if max_delta == 0 {
			out[i] = {
				r = 24,
				g = 28,
				b = 32,
				a = 255,
			}
		} else {
			intensity := u8(max_delta)
			out[i] = {
				r = 255,
				g = intensity,
				b = 32,
				a = 255,
			}
		}
	}
	return out
}

channel_delta :: proc(a, b: u8) -> u32 {
	if a > b {
		return u32(a - b)
	}
	return u32(b - a)
}

max_u32 :: proc(a, b: u32) -> u32 {
	if a > b {
		return a
	}
	return b
}
