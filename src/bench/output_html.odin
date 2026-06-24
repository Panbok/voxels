package bench

import "core:fmt"
import "core:os"
import "core:strings"

write_html :: proc(path: string, suite: ^BenchmarkSuiteResult) -> bool {
	builder, alloc_err := strings.builder_make(allocator = context.allocator)
	if alloc_err != nil {
		fmt.eprintln("failed to allocate benchmark HTML builder")
		return false
	}
	defer strings.builder_destroy(&builder)

	html_write_suite(&builder, suite)
	err := os.write_entire_file(path, strings.to_string(builder))
	if err != nil {
		fmt.eprintfln("failed to write benchmark HTML %s: %v", path, err)
		return false
	}
	return true
}

html_write_suite :: proc(builder: ^strings.Builder, suite: ^BenchmarkSuiteResult) {
	strings.write_string(
		builder,
		"<!doctype html><html><head><meta charset=\"utf-8\"><title>Voxel Benchmarks</title>",
	)
	strings.write_string(
		builder,
		"<style>body{font-family:-apple-system,BlinkMacSystemFont,Segoe UI,sans-serif;margin:24px;color:#1f2933;background:#f8fafb}table{border-collapse:collapse;width:100%;background:white}th,td{padding:8px 10px;border-bottom:1px solid #dde3ea;text-align:left;font-size:13px}th{background:#eef3f7}.status-pass{color:#176b3a}.status-fail{color:#a32727}.status-skip{color:#8a5a00}.bar{height:10px;background:#2f7ebc;border-radius:2px}.metrics{font-family:ui-monospace,SFMono-Regular,Menlo,monospace;font-size:12px}</style></head><body>",
	)
	strings.write_string(builder, "<h1>Voxel Benchmarks</h1>")
	strings.write_string(
		builder,
		"<table><thead><tr><th>Name</th><th>Version</th><th>Status</th><th>Workers</th><th>Iterations</th><th>Avg us</th><th>Total ms</th><th>Metrics</th></tr></thead><tbody>",
	)

	max_avg := f64(0)
	for i := u32(0); i < suite.benchmark_count; i += 1 {
		if suite.benchmarks[i].timing.avg_us_per_iteration > max_avg {
			max_avg = suite.benchmarks[i].timing.avg_us_per_iteration
		}
	}
	if max_avg <= 0 {
		max_avg = 1
	}

	for i := u32(0); i < suite.benchmark_count; i += 1 {
		result := &suite.benchmarks[i]
		status := benchmark_status_string(result.status)
		bar_width := result.timing.avg_us_per_iteration / max_avg * 100.0
		fmt.sbprintf(
			builder,
			"<tr><td>%s</td><td>%s</td><td class=\"status-%s\">%s</td><td>%d</td><td>%d</td><td>%.3f<div class=\"bar\" style=\"width:%.2f%%\"></div></td><td>%.3f</td><td class=\"metrics\">",
			result.name,
			result.version,
			status,
			status,
			result.workers,
			result.iterations,
			result.timing.avg_us_per_iteration,
			bar_width,
			result.timing.total_wall_ms,
		)
		for metric_index := u32(0); metric_index < result.metric_count; metric_index += 1 {
			metric := result.metrics[metric_index]
			if metric_index > 0 {
				strings.write_string(builder, "<br>")
			}
			html_write_metric(builder, metric)
		}
		strings.write_string(builder, "</td></tr>")
	}

	strings.write_string(
		builder,
		"</tbody></table><h2>Embedded JSON</h2><script type=\"application/json\" id=\"benchmark-json\">",
	)
	json_write_suite(builder, suite)
	strings.write_string(builder, "</script></body></html>\n")
}

html_write_metric :: proc(builder: ^strings.Builder, metric: BenchmarkMetricValue) {
	switch metric.kind {
	case .U64, .Artifact_Path:
		fmt.sbprintf(builder, "%s=%d", metric.name, metric.u64_value)
	case .I64:
		fmt.sbprintf(builder, "%s=%d", metric.name, metric.i64_value)
	case .F64:
		fmt.sbprintf(builder, "%s=%.3f", metric.name, metric.f64_value)
	case .Bool:
		fmt.sbprintf(builder, "%s=%v", metric.name, metric.bool_value)
	case .String:
		fmt.sbprintf(builder, "%s=%s", metric.name, metric.string_value)
	}
}
