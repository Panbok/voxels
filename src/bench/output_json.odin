package bench

import "core:fmt"
import "core:os"
import "core:strings"

write_json :: proc(path: string, suite: ^BenchmarkSuiteResult) -> bool {
	builder, alloc_err := strings.builder_make(allocator = context.allocator)
	if alloc_err != nil {
		fmt.eprintln("failed to allocate benchmark JSON builder")
		return false
	}
	defer strings.builder_destroy(&builder)

	json_write_suite(&builder, suite)
	err := os.write_entire_file(path, strings.to_string(builder))
	if err != nil {
		fmt.eprintfln("failed to write benchmark JSON %s: %v", path, err)
		return false
	}
	return true
}

json_write_suite :: proc(builder: ^strings.Builder, suite: ^BenchmarkSuiteResult) {
	strings.write_string(builder, "{\n")
	json_write_named_string(builder, "schema", suite.schema, 1, true)
	json_write_named_string(builder, "suite", suite.suite, 1, true)
	json_indent(builder, 1)
	strings.write_string(builder, "\"build\": ")
	json_write_metadata_object(builder, suite.build[:suite.build_count], 1)
	strings.write_string(builder, ",\n")
	json_indent(builder, 1)
	strings.write_string(builder, "\"benchmarks\": [\n")
	for i := u32(0); i < suite.benchmark_count; i += 1 {
		json_write_case_result(builder, &suite.benchmarks[i], 2)
		if i + 1 < suite.benchmark_count {
			strings.write_string(builder, ",")
		}
		strings.write_string(builder, "\n")
	}
	json_indent(builder, 1)
	strings.write_string(builder, "]\n")
	strings.write_string(builder, "}\n")
}

json_write_case_result :: proc(
	builder: ^strings.Builder,
	result: ^BenchmarkCaseResult,
	indent: int,
) {
	json_indent(builder, indent)
	strings.write_string(builder, "{\n")
	json_write_named_string(builder, "name", result.name, indent + 1, true)
	json_write_named_string(builder, "version", result.version, indent + 1, true)
	json_write_named_string(
		builder,
		"status",
		benchmark_status_string(result.status),
		indent + 1,
		true,
	)
	json_write_named_string(builder, "error", result.error, indent + 1, true)

	json_indent(builder, indent + 1)
	strings.write_string(builder, "\"flags\": [")
	first_flag := true
	for flag in BenchmarkCaseFlag {
		if case_has_flag(result.flags, flag) {
			if !first_flag {
				strings.write_string(builder, ", ")
			}
			json_write_string(builder, benchmark_flag_string(flag))
			first_flag = false
		}
	}
	strings.write_string(builder, "],\n")

	json_write_named_u64(builder, "workers", u64(result.workers), indent + 1, true)
	json_write_named_u64(builder, "iterations", u64(result.iterations), indent + 1, true)
	json_write_named_u64(
		builder,
		"warmup_iterations",
		u64(result.warmup_iterations),
		indent + 1,
		true,
	)
	json_indent(builder, indent + 1)
	strings.write_string(builder, "\"fixture\": ")
	json_write_metadata_object(builder, result.fixture[:result.fixture_count], indent + 1)
	strings.write_string(builder, ",\n")
	json_indent(builder, indent + 1)
	strings.write_string(builder, "\"timing\": {\n")
	json_write_named_f64(builder, "total_wall_ms", result.timing.total_wall_ms, indent + 2, true)
	json_write_named_f64(
		builder,
		"total_worker_ms",
		result.timing.total_worker_ms,
		indent + 2,
		true,
	)
	json_write_named_f64(
		builder,
		"avg_us_per_iteration",
		result.timing.avg_us_per_iteration,
		indent + 2,
		true,
	)
	json_write_named_f64(builder, "min_worker_ms", result.timing.min_worker_ms, indent + 2, true)
	json_write_named_f64(builder, "max_worker_ms", result.timing.max_worker_ms, indent + 2, true)
	json_write_named_u64(
		builder,
		"completed_iterations",
		result.timing.completed_iterations,
		indent + 2,
		true,
	)
	json_write_named_u64(
		builder,
		"failed_iterations",
		result.timing.failed_iterations,
		indent + 2,
		true,
	)
	json_write_named_u64(
		builder,
		"skipped_iterations",
		result.timing.skipped_iterations,
		indent + 2,
		false,
	)
	strings.write_string(builder, "\n")
	json_indent(builder, indent + 1)
	strings.write_string(builder, "},\n")

	json_indent(builder, indent + 1)
	strings.write_string(builder, "\"metrics\": ")
	json_write_metrics_object(builder, result.metrics[:result.metric_count], indent + 1)
	strings.write_string(builder, ",\n")
	json_indent(builder, indent + 1)
	strings.write_string(builder, "\"artifacts\": [")
	for i := u32(0); i < result.artifact_count; i += 1 {
		if i > 0 {
			strings.write_string(builder, ", ")
		}
		artifact := result.artifacts[i]
		strings.write_string(builder, "{\"label\":")
		json_write_string(builder, artifact.label)
		strings.write_string(builder, ",\"kind\":")
		json_write_string(builder, artifact.kind)
		strings.write_string(builder, ",\"path\":")
		json_write_string(builder, artifact.path)
		strings.write_string(builder, ",\"content_type\":")
		json_write_string(builder, artifact.content_type)
		strings.write_string(builder, "}")
	}
	strings.write_string(builder, "]\n")
	json_indent(builder, indent)
	strings.write_string(builder, "}")
}

json_write_metadata_object :: proc(
	builder: ^strings.Builder,
	metadata: []BenchmarkMetadataValue,
	indent: int,
) {
	if len(metadata) == 0 {
		strings.write_string(builder, "{}")
		return
	}
	strings.write_string(builder, "{\n")
	for i := 0; i < len(metadata); i += 1 {
		value := metadata[i]
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

json_write_metrics_object :: proc(
	builder: ^strings.Builder,
	metrics: []BenchmarkMetricValue,
	indent: int,
) {
	if len(metrics) == 0 {
		strings.write_string(builder, "{}")
		return
	}
	strings.write_string(builder, "{\n")
	for i := 0; i < len(metrics); i += 1 {
		metric := metrics[i]
		json_indent(builder, indent + 1)
		json_write_string(builder, metric.name)
		strings.write_string(builder, ": ")
		json_write_metric_value(builder, metric)
		if i + 1 < len(metrics) {
			strings.write_string(builder, ",")
		}
		strings.write_string(builder, "\n")
	}
	json_indent(builder, indent)
	strings.write_string(builder, "}")
}

json_write_metadata_value :: proc(builder: ^strings.Builder, value: BenchmarkMetadataValue) {
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

json_write_metric_value :: proc(builder: ^strings.Builder, value: BenchmarkMetricValue) {
	switch value.kind {
	case .U64, .Artifact_Path:
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
