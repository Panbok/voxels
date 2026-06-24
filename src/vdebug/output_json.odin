package vdebug

import "core:fmt"
import "core:os"
import "core:strings"

write_json :: proc(path: string, suite: ^VisualDebugSuiteResult) -> bool {
	builder, alloc_err := strings.builder_make(allocator = context.allocator)
	if alloc_err != nil {
		fmt.eprintln("failed to allocate visual debug JSON builder")
		return false
	}
	defer strings.builder_destroy(&builder)

	json_write_suite(&builder, suite)
	err := os.write_entire_file(path, strings.to_string(builder))
	if err != nil {
		fmt.eprintfln("failed to write visual debug JSON %s: %v", path, err)
		return false
	}
	return true
}

json_write_suite :: proc(builder: ^strings.Builder, suite: ^VisualDebugSuiteResult) {
	strings.write_string(builder, "{\n")
	json_write_named_string(builder, "schema", suite.schema, 1, true)
	json_write_named_string(builder, "run_id", suite.run_id, 1, true)
	json_write_named_string(builder, "config_path", suite.config_path, 1, true)
	json_write_named_string(builder, "config_hash", suite.config_hash, 1, true)
	json_write_named_i64(builder, "process_id", i64(suite.process_id), 1, true)
	json_write_named_i64(builder, "shard_index", i64(suite.shard_index), 1, true)
	json_write_named_i64(builder, "shard_count", i64(suite.shard_count), 1, true)
	json_write_named_string(builder, "output_dir", suite.output_dir, 1, true)
	json_write_named_string(builder, "artifact_dir", suite.artifact_dir, 1, true)
	json_write_named_string(builder, "baseline_dir", suite.baseline_dir, 1, true)

	json_indent(builder, 1)
	strings.write_string(builder, "\"build\": ")
	json_write_metadata_object(builder, suite.build[:suite.build_count], 1)
	strings.write_string(builder, ",\n")

	json_indent(builder, 1)
	strings.write_string(builder, "\"ffmpeg\": ")
	json_write_ffmpeg_record(builder, &suite.ffmpeg, 1)
	strings.write_string(builder, ",\n")

	json_indent(builder, 1)
	strings.write_string(builder, "\"accept\": {\n")
	json_write_named_u64(builder, "created", u64(suite.accept_created), 2, true)
	json_write_named_u64(builder, "replaced", u64(suite.accept_replaced), 2, true)
	json_write_named_u64(builder, "unchanged", u64(suite.accept_unchanged), 2, true)
	json_write_named_u64(builder, "skipped", u64(suite.accept_skipped), 2, false)
	json_indent(builder, 1)
	strings.write_string(builder, "},\n")

	json_indent(builder, 1)
	strings.write_string(builder, "\"captures\": [\n")
	for i := u32(0); i < suite.capture_count; i += 1 {
		json_write_capture(builder, &suite.captures[i], 2)
		if i + 1 < suite.capture_count {
			strings.write_string(builder, ",")
		}
		strings.write_string(builder, "\n")
	}
	json_indent(builder, 1)
	strings.write_string(builder, "]\n")
	strings.write_string(builder, "}\n")
}

json_write_capture :: proc(
	builder: ^strings.Builder,
	capture: ^VisualDebugCaptureResult,
	indent: int,
) {
	json_indent(builder, indent)
	strings.write_string(builder, "{\n")
	json_write_named_string(builder, "id", capture.id, indent + 1, true)
	json_write_named_u64(builder, "input_index", u64(capture.input_index), indent + 1, true)
	json_write_named_string(builder, "case", capture.case_name, indent + 1, true)
	json_write_named_string(builder, "version", capture.version, indent + 1, true)
	json_write_named_string(builder, "status", status_string(capture.status), indent + 1, true)
	json_write_named_string(builder, "error", capture.error, indent + 1, true)
	json_write_named_bool(builder, "required", capture.required, indent + 1, true)

	json_indent(builder, indent + 1)
	strings.write_string(builder, "\"flags\": [")
	first := true
	for flag in VisualDebugCaseFlag {
		if case_has_flag(capture.flags, flag) {
			if !first {
				strings.write_string(builder, ", ")
			}
			json_write_string(builder, flag_string(flag))
			first = false
		}
	}
	strings.write_string(builder, "],\n")

	json_indent(builder, indent + 1)
	strings.write_string(builder, "\"fixture\": ")
	json_write_metadata_object(builder, capture.fixture[:capture.fixture_count], indent + 1)
	strings.write_string(builder, ",\n")

	json_indent(builder, indent + 1)
	strings.write_string(builder, "\"modes\": [\n")
	for i := u32(0); i < capture.mode_count; i += 1 {
		json_write_mode(builder, &capture.modes[i], indent + 2)
		if i + 1 < capture.mode_count {
			strings.write_string(builder, ",")
		}
		strings.write_string(builder, "\n")
	}
	json_indent(builder, indent + 1)
	strings.write_string(builder, "]\n")
	json_indent(builder, indent)
	strings.write_string(builder, "}")
}

json_write_mode :: proc(builder: ^strings.Builder, mode: ^VisualDebugModeResult, indent: int) {
	json_indent(builder, indent)
	strings.write_string(builder, "{\n")
	json_write_named_string(builder, "id", mode.id, indent + 1, true)
	json_write_named_string(builder, "kind", mode.kind, indent + 1, true)
	json_write_named_string(builder, "status", status_string(mode.status), indent + 1, true)
	json_write_named_string(builder, "error", mode.error, indent + 1, true)
	json_write_named_bool(builder, "required", mode.required, indent + 1, true)
	json_write_named_u64(builder, "width", u64(mode.width), indent + 1, true)
	json_write_named_u64(builder, "height", u64(mode.height), indent + 1, true)
	json_write_named_string(builder, "palette", mode.palette, indent + 1, true)
	json_write_named_string(builder, "hash", mode.hash, indent + 1, true)

	json_indent(builder, indent + 1)
	strings.write_string(builder, "\"artifacts\": [\n")
	for i := u32(0); i < mode.artifact_count; i += 1 {
		json_write_artifact(builder, &mode.artifacts[i], indent + 2)
		if i + 1 < mode.artifact_count {
			strings.write_string(builder, ",")
		}
		strings.write_string(builder, "\n")
	}
	json_indent(builder, indent + 1)
	strings.write_string(builder, "],\n")

	json_indent(builder, indent + 1)
	strings.write_string(builder, "\"comparison\": ")
	if mode.comparison_active {
		json_write_comparison(builder, &mode.comparison, indent + 1)
	} else {
		strings.write_string(builder, "null")
	}
	strings.write_string(builder, "\n")
	json_indent(builder, indent)
	strings.write_string(builder, "}")
}

json_write_artifact :: proc(
	builder: ^strings.Builder,
	artifact: ^VisualDebugArtifactRecord,
	indent: int,
) {
	json_indent(builder, indent)
	strings.write_string(builder, "{\n")
	json_write_named_string(builder, "label", artifact.label, indent + 1, true)
	json_write_named_string(builder, "kind", artifact.kind, indent + 1, true)
	json_write_named_string(builder, "path", artifact.path, indent + 1, true)
	json_write_named_string(builder, "content_type", artifact.content_type, indent + 1, true)
	json_write_named_u64(builder, "byte_size", artifact.byte_size, indent + 1, true)
	json_write_named_u64(builder, "width", u64(artifact.width), indent + 1, true)
	json_write_named_u64(builder, "height", u64(artifact.height), indent + 1, true)
	json_write_named_string(builder, "pixel_format", artifact.pixel_format, indent + 1, true)
	json_write_named_string(builder, "color_space", artifact.color_space, indent + 1, true)
	json_write_named_string(builder, "orientation", artifact.orientation, indent + 1, true)
	json_write_named_string(builder, "palette", artifact.palette, indent + 1, true)
	json_write_named_string(builder, "encoder", artifact.encoder, indent + 1, true)
	json_write_named_string(builder, "hash", artifact.hash, indent + 1, false)
	json_indent(builder, indent)
	strings.write_string(builder, "}")
}

json_write_comparison :: proc(
	builder: ^strings.Builder,
	comparison: ^VisualDebugComparisonResult,
	indent: int,
) {
	strings.write_string(builder, "{\n")
	json_write_named_string(builder, "status", comparison.status, indent + 1, true)
	json_write_named_string(builder, "error", comparison.error, indent + 1, true)
	json_write_named_string(builder, "baseline_path", comparison.baseline_path, indent + 1, true)
	json_write_named_string(
		builder,
		"baseline_sidecar",
		comparison.baseline_sidecar,
		indent + 1,
		true,
	)
	json_write_named_string(builder, "platform_key", comparison.platform_key, indent + 1, true)
	json_write_named_string(builder, "old_hash", comparison.old_hash, indent + 1, true)
	json_write_named_bool(builder, "accepted", comparison.accepted, indent + 1, true)

	json_indent(builder, indent + 1)
	strings.write_string(builder, "\"tolerance\": ")
	json_write_tolerance(builder, comparison.tolerance, indent + 1)
	strings.write_string(builder, ",\n")

	json_indent(builder, indent + 1)
	strings.write_string(builder, "\"metrics\": ")
	json_write_metrics(builder, &comparison.metrics, indent + 1)
	strings.write_string(builder, ",\n")

	json_indent(builder, indent + 1)
	strings.write_string(builder, "\"diff_artifacts\": [\n")
	for i := u32(0); i < comparison.diff_artifact_count; i += 1 {
		json_write_artifact(builder, &comparison.diff_artifacts[i], indent + 2)
		if i + 1 < comparison.diff_artifact_count {
			strings.write_string(builder, ",")
		}
		strings.write_string(builder, "\n")
	}
	json_indent(builder, indent + 1)
	strings.write_string(builder, "]\n")
	json_indent(builder, indent)
	strings.write_string(builder, "}")
}

json_write_tolerance :: proc(
	builder: ^strings.Builder,
	tolerance: VisualDebugTolerance,
	indent: int,
) {
	strings.write_string(builder, "{\n")
	mode := "exact"
	switch tolerance.mode {
	case .Exact:
		mode = "exact"
	case .Pixel_Threshold:
		mode = "pixel_threshold"
	case .Metric_Threshold:
		mode = "metric_threshold"
	case .Masked:
		mode = "masked"
	}
	json_write_named_string(builder, "mode", mode, indent + 1, true)
	json_write_named_u64(
		builder,
		"max_channel_delta",
		u64(tolerance.max_channel_delta),
		indent + 1,
		true,
	)
	json_write_named_f64(builder, "mean_abs_error", tolerance.mean_abs_error, indent + 1, true)
	json_write_named_f64(builder, "rms_error", tolerance.rms_error, indent + 1, true)
	json_write_named_f64(
		builder,
		"changed_pixel_ratio",
		tolerance.changed_pixel_ratio,
		indent + 1,
		true,
	)
	json_write_named_f64(builder, "psnr_min", tolerance.psnr_min, indent + 1, false)
	json_indent(builder, indent)
	strings.write_string(builder, "}")
}

json_write_metrics :: proc(
	builder: ^strings.Builder,
	metrics: ^VisualDebugComparisonMetrics,
	indent: int,
) {
	strings.write_string(builder, "{\n")
	json_write_named_u64(builder, "changed_pixels", metrics.changed_pixels, indent + 1, true)
	json_write_named_f64(
		builder,
		"changed_pixel_ratio",
		metrics.changed_pixel_ratio,
		indent + 1,
		true,
	)
	json_write_named_u64(
		builder,
		"max_channel_delta",
		u64(metrics.max_channel_delta),
		indent + 1,
		true,
	)
	json_write_named_f64(builder, "mean_abs_error", metrics.mean_abs_error, indent + 1, true)
	json_write_named_f64(builder, "rms_error", metrics.rms_error, indent + 1, true)
	json_indent(builder, indent + 1)
	json_write_string(builder, "psnr")
	strings.write_string(builder, ": ")
	if metrics.psnr_infinite {
		json_write_string(builder, "inf")
	} else {
		fmt.sbprintf(builder, "%.6f", metrics.psnr)
	}
	strings.write_string(builder, "\n")
	json_indent(builder, indent)
	strings.write_string(builder, "}")
}

json_write_ffmpeg_record :: proc(
	builder: ^strings.Builder,
	record: ^VisualDebugFFmpegRunRecord,
	indent: int,
) {
	strings.write_string(builder, "{\n")
	json_write_named_string(builder, "status", record.status, indent + 1, true)
	json_write_named_string(builder, "path", record.path, indent + 1, true)
	json_write_named_string(builder, "version", record.version, indent + 1, true)
	json_write_named_string(builder, "command", record.command, indent + 1, true)
	json_write_named_i64(builder, "exit_code", i64(record.exit_code), indent + 1, true)
	json_write_named_string(builder, "stderr_tail", record.stderr_tail, indent + 1, true)
	json_write_named_string(builder, "output_path", record.output_path, indent + 1, true)
	json_write_named_string(builder, "output_hash", record.output_hash, indent + 1, false)
	json_indent(builder, indent)
	strings.write_string(builder, "}")
}

json_write_metadata_object :: proc(
	builder: ^strings.Builder,
	metadata: []VisualDebugMetadataValue,
	indent: int,
) {
	if len(metadata) == 0 {
		strings.write_string(builder, "{}")
		return
	}
	strings.write_string(builder, "{\n")
	for value, i in metadata {
		json_indent(builder, indent + 1)
		json_write_string(builder, value.name)
		strings.write_string(builder, ": ")
		json_write_metadata_value(builder, value)
		if i + 1 < len(metadata) {
			strings.write_string(builder, ",")
		}
		strings.write_string(builder, "\n")
	}
	json_indent(builder, indent)
	strings.write_string(builder, "}")
}

json_write_metadata_value :: proc(builder: ^strings.Builder, value: VisualDebugMetadataValue) {
	switch value.kind {
	case .U64:
		fmt.sbprintf(builder, "%d", value.u64_value)
	case .I64:
		fmt.sbprintf(builder, "%d", value.i64_value)
	case .F64:
		fmt.sbprintf(builder, "%.6f", value.f64_value)
	case .Bool:
		strings.write_string(builder, value.bool_value ? "true" : "false")
	case .String:
		json_write_string(builder, value.string_value)
	}
}

json_write_named_string :: proc(
	builder: ^strings.Builder,
	name: string,
	value: string,
	indent: int,
	comma: bool,
) {
	json_indent(builder, indent)
	json_write_string(builder, name)
	strings.write_string(builder, ": ")
	json_write_string(builder, value)
	if comma {
		strings.write_string(builder, ",")
	}
	strings.write_string(builder, "\n")
}

json_write_named_bool :: proc(
	builder: ^strings.Builder,
	name: string,
	value: bool,
	indent: int,
	comma: bool,
) {
	json_indent(builder, indent)
	json_write_string(builder, name)
	strings.write_string(builder, value ? ": true" : ": false")
	if comma {
		strings.write_string(builder, ",")
	}
	strings.write_string(builder, "\n")
}

json_write_named_u64 :: proc(
	builder: ^strings.Builder,
	name: string,
	value: u64,
	indent: int,
	comma: bool,
) {
	json_indent(builder, indent)
	json_write_string(builder, name)
	fmt.sbprintf(builder, ": %d", value)
	if comma {
		strings.write_string(builder, ",")
	}
	strings.write_string(builder, "\n")
}

json_write_named_i64 :: proc(
	builder: ^strings.Builder,
	name: string,
	value: i64,
	indent: int,
	comma: bool,
) {
	json_indent(builder, indent)
	json_write_string(builder, name)
	fmt.sbprintf(builder, ": %d", value)
	if comma {
		strings.write_string(builder, ",")
	}
	strings.write_string(builder, "\n")
}

json_write_named_f64 :: proc(
	builder: ^strings.Builder,
	name: string,
	value: f64,
	indent: int,
	comma: bool,
) {
	json_indent(builder, indent)
	json_write_string(builder, name)
	fmt.sbprintf(builder, ": %.6f", value)
	if comma {
		strings.write_string(builder, ",")
	}
	strings.write_string(builder, "\n")
}

json_write_string :: proc(builder: ^strings.Builder, value: string) {
	strings.write_quoted_string(builder, value)
}

json_indent :: proc(builder: ^strings.Builder, level: int) {
	for _ in 0 ..< level {
		strings.write_string(builder, "  ")
	}
}
