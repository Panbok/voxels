package bench

import json "core:encoding/json"

import "core:fmt"
import "core:mem"
import "core:os"
import "core:strings"

BENCHMARK_GRAPH_MAX_RECORDS :: 512
BENCHMARK_GRAPH_MAX_VERSIONS :: 128

BenchmarkGraphRecord :: struct {
	source_path:    string,
	name:           string,
	version:        string,
	status:         string,
	avg_us:         f64,
	total_wall_ms:  f64,
	score:          f64,
	delta_pct:      f64,
	prev_delta_pct: f64,
}

BenchmarkGraphVersionScore :: struct {
	version: string,
	total:   f64,
	count:   u32,
}

write_graph_html :: proc(path: string, input_paths: []string, allocator: mem.Allocator) -> bool {
	records: [BENCHMARK_GRAPH_MAX_RECORDS]BenchmarkGraphRecord
	record_count: u32

	for input_path in input_paths {
		if !benchmark_graph_read_report(input_path, allocator, records[:], &record_count) {
			return false
		}
	}
	if record_count == 0 {
		fmt.eprintln("benchmark graph input contained no benchmark results")
		return false
	}

	benchmark_graph_scores_compute(records[:record_count])

	builder, alloc_err := strings.builder_make(allocator = allocator)
	if alloc_err != nil {
		fmt.eprintln("failed to allocate benchmark graph HTML builder")
		return false
	}
	defer strings.builder_destroy(&builder)

	benchmark_graph_html_write(&builder, records[:record_count], input_paths)
	err := os.write_entire_file(path, strings.to_string(builder))
	if err != nil {
		fmt.eprintfln("failed to write benchmark graph HTML %s: %v", path, err)
		return false
	}
	fmt.printfln(
		"BENCH_GRAPH output=%s inputs=%d records=%d",
		path,
		len(input_paths),
		record_count,
	)
	return true
}

benchmark_graph_read_report :: proc(
	path: string,
	allocator: mem.Allocator,
	records: []BenchmarkGraphRecord,
	record_count: ^u32,
) -> bool {
	data, read_err := os.read_entire_file(path, allocator)
	if read_err != nil {
		fmt.eprintfln("failed to read benchmark JSON %s: %v", path, read_err)
		return false
	}
	defer delete(data, allocator)

	root, parse_err := json.parse(data, json.DEFAULT_SPECIFICATION, true, allocator)
	if parse_err != .None {
		fmt.eprintfln("failed to parse benchmark JSON %s: %v", path, parse_err)
		return false
	}
	defer json.destroy_value(root, allocator)

	root_obj, root_ok := benchmark_graph_json_object(root)
	if !root_ok {
		fmt.eprintfln("benchmark JSON %s root is not an object", path)
		return false
	}
	benchmarks_value, benchmarks_value_ok := root_obj["benchmarks"]
	if !benchmarks_value_ok {
		fmt.eprintfln("benchmark JSON %s missing benchmarks array", path)
		return false
	}
	benchmarks, benchmarks_ok := benchmark_graph_json_array(benchmarks_value)
	if !benchmarks_ok {
		fmt.eprintfln("benchmark JSON %s benchmarks field is not an array", path)
		return false
	}

	for benchmark_value in benchmarks {
		benchmark_obj, benchmark_obj_ok := benchmark_graph_json_object(benchmark_value)
		if !benchmark_obj_ok {
			continue
		}
		if record_count^ >= u32(len(records)) {
			fmt.eprintln("benchmark graph record capacity exceeded")
			return false
		}

		name := benchmark_graph_json_string_default(benchmark_obj, "name", "")
		if name == "" {
			continue
		}
		version := benchmark_graph_json_string_default(benchmark_obj, "version", "1")
		status := benchmark_graph_json_string_default(benchmark_obj, "status", "unknown")

		timing_value, timing_value_ok := benchmark_obj["timing"]
		if !timing_value_ok {
			continue
		}
		timing, timing_ok := benchmark_graph_json_object(timing_value)
		if !timing_ok {
			continue
		}
		avg_us := benchmark_graph_json_f64_default(timing, "avg_us_per_iteration", 0)
		total_wall_ms := benchmark_graph_json_f64_default(timing, "total_wall_ms", 0)

		source_copy := benchmark_graph_clone(path, allocator)
		name_copy := benchmark_graph_clone(name, allocator)
		version_copy := benchmark_graph_clone(version, allocator)
		status_copy := benchmark_graph_clone(status, allocator)
		if source_copy == "" || name_copy == "" || version_copy == "" || status_copy == "" {
			fmt.eprintln("failed to allocate benchmark graph record strings")
			return false
		}

		records[record_count^] = {
			source_path   = source_copy,
			name          = name_copy,
			version       = version_copy,
			status        = status_copy,
			avg_us        = avg_us,
			total_wall_ms = total_wall_ms,
		}
		record_count^ += 1
	}
	return true
}

benchmark_graph_clone :: proc(value: string, allocator: mem.Allocator) -> string {
	copy, err := strings.clone(value, allocator)
	if err != nil {
		return ""
	}
	return copy
}

benchmark_graph_scores_compute :: proc(records: []BenchmarkGraphRecord) {
	for i := 0; i < len(records); i += 1 {
		baseline := benchmark_graph_baseline_avg_us(records, records[i].name)
		previous := benchmark_graph_previous_avg_us(records, i)
		if baseline > 0 && records[i].avg_us > 0 {
			records[i].score = baseline / records[i].avg_us * 100.0
			records[i].delta_pct = (records[i].avg_us - baseline) / baseline * 100.0
		}
		if previous > 0 && records[i].avg_us > 0 {
			records[i].prev_delta_pct = (records[i].avg_us - previous) / previous * 100.0
		}
	}
}

benchmark_graph_baseline_avg_us :: proc(records: []BenchmarkGraphRecord, name: string) -> f64 {
	for record in records {
		if record.name == name && record.avg_us > 0 {
			return record.avg_us
		}
	}
	return 0
}

benchmark_graph_previous_avg_us :: proc(records: []BenchmarkGraphRecord, index: int) -> f64 {
	if index <= 0 {
		return 0
	}
	name := records[index].name
	for i := index - 1; i >= 0; i -= 1 {
		if records[i].name == name && records[i].avg_us > 0 {
			return records[i].avg_us
		}
		if i == 0 {
			break
		}
	}
	return 0
}

benchmark_graph_html_write :: proc(
	builder: ^strings.Builder,
	records: []BenchmarkGraphRecord,
	input_paths: []string,
) {
	strings.write_string(
		builder,
		"<!doctype html><html><head><meta charset=\"utf-8\"><title>Voxel Benchmark Comparison</title>",
	)
	strings.write_string(
		builder,
		"<style>body{font-family:-apple-system,BlinkMacSystemFont,Segoe UI,sans-serif;margin:24px;color:#1f2933;background:#f8fafb}h1{font-size:24px}h2{font-size:18px;margin-top:28px}table{border-collapse:collapse;width:100%;background:white;margin:10px 0 18px}th,td{padding:8px 10px;border-bottom:1px solid #dde3ea;text-align:left;font-size:13px}th{background:#eef3f7}.chart{background:white;border:1px solid #dde3ea;padding:12px;margin:10px 0 16px}.row{display:grid;grid-template-columns:180px 1fr 90px;gap:10px;align-items:center;margin:7px 0;font-size:13px}.track{height:18px;background:#e8edf2}.bar{height:18px;background:#2f7ebc}.metrics{font-family:ui-monospace,SFMono-Regular,Menlo,monospace;font-size:12px}.good{color:#176b3a}.bad{color:#a32727}.muted{color:#667085}</style></head><body>",
	)
	strings.write_string(builder, "<h1>Voxel Benchmark Version Comparison</h1>")
	fmt.sbprintf(
		builder,
		"<p class=\"muted\">Inputs: %d, records: %d</p>",
		len(input_paths),
		len(records),
	)
	strings.write_string(builder, "<ul>")
	for input_path in input_paths {
		strings.write_string(builder, "<li><span class=\"metrics\">")
		benchmark_graph_html_write_escaped(builder, input_path)
		strings.write_string(builder, "</span></li>")
	}
	strings.write_string(builder, "</ul>")

	benchmark_graph_html_write_version_summary(builder, records)
	benchmark_graph_html_write_benchmark_summary(builder, records)

	for i := 0; i < len(records); i += 1 {
		if benchmark_graph_first_record_index(records, records[i].name) != i {
			continue
		}
		benchmark_graph_html_write_benchmark(builder, records, records[i].name)
	}
	strings.write_string(builder, "</body></html>\n")
}

benchmark_graph_html_write_version_summary :: proc(
	builder: ^strings.Builder,
	records: []BenchmarkGraphRecord,
) {
	scores: [BENCHMARK_GRAPH_MAX_VERSIONS]BenchmarkGraphVersionScore
	score_count: u32
	for record in records {
		if record.score <= 0 {
			continue
		}
		index := benchmark_graph_version_score_index(scores[:], score_count, record.version)
		if index < 0 {
			if score_count >= BENCHMARK_GRAPH_MAX_VERSIONS {
				continue
			}
			index = int(score_count)
			scores[score_count] = {
				version = record.version,
			}
			score_count += 1
		}
		scores[index].total += record.score
		scores[index].count += 1
	}

	strings.write_string(builder, "<h2>Version Score Summary</h2>")
	strings.write_string(
		builder,
		"<table><thead><tr><th>Version</th><th>Compared Benchmarks</th><th>Mean Score</th></tr></thead><tbody>",
	)
	for i := u32(0); i < score_count; i += 1 {
		mean := scores[i].total / f64(scores[i].count)
		strings.write_string(builder, "<tr><td>")
		benchmark_graph_html_write_escaped(builder, scores[i].version)
		fmt.sbprintf(builder, "</td><td>%d</td><td>%.2f</td></tr>", scores[i].count, mean)
	}
	strings.write_string(builder, "</tbody></table>")
}

benchmark_graph_html_write_benchmark_summary :: proc(
	builder: ^strings.Builder,
	records: []BenchmarkGraphRecord,
) {
	strings.write_string(builder, "<h2>Benchmark Summary</h2>")
	strings.write_string(
		builder,
		"<table><thead><tr><th>Benchmark</th><th>Versions</th><th>Baseline Avg us</th><th>Latest Avg us</th><th>Latest Diff</th><th>Latest Score</th></tr></thead><tbody>",
	)
	for i := 0; i < len(records); i += 1 {
		name := records[i].name
		if benchmark_graph_first_record_index(records, name) != i {
			continue
		}
		baseline := benchmark_graph_baseline_avg_us(records, name)
		latest := benchmark_graph_latest_record(records, name)
		group_count := benchmark_graph_record_count(records, name)
		strings.write_string(builder, "<tr><td>")
		benchmark_graph_html_write_escaped(builder, name)
		fmt.sbprintf(
			builder,
			"</td><td>%d</td><td>%.3f</td><td>%.3f</td><td class=\"%s\">%.2f%%</td><td>%.2f</td></tr>",
			group_count,
			baseline,
			latest.avg_us,
			benchmark_graph_delta_class(latest.delta_pct),
			latest.delta_pct,
			latest.score,
		)
	}
	strings.write_string(builder, "</tbody></table>")
}

benchmark_graph_html_write_benchmark :: proc(
	builder: ^strings.Builder,
	records: []BenchmarkGraphRecord,
	name: string,
) {
	strings.write_string(builder, "<h2>")
	benchmark_graph_html_write_escaped(builder, name)
	strings.write_string(builder, "</h2>")

	max_score := f64(0)
	for record in records {
		if record.name == name && record.score > max_score {
			max_score = record.score
		}
	}
	if max_score <= 0 {
		max_score = 100
	}

	strings.write_string(builder, "<div class=\"chart\">")
	for record in records {
		if record.name != name {
			continue
		}
		width := record.score / max_score * 100.0
		if width < 1 {
			width = 1
		}
		strings.write_string(builder, "<div class=\"row\"><div class=\"metrics\">v")
		benchmark_graph_html_write_escaped(builder, record.version)
		fmt.sbprintf(
			builder,
			"</div><div class=\"track\"><div class=\"bar\" style=\"width:%.2f%%\"></div></div><div>%.2f</div></div>",
			width,
			record.score,
		)
	}
	strings.write_string(builder, "</div>")

	strings.write_string(
		builder,
		"<table><thead><tr><th>Version</th><th>Status</th><th>Avg us</th><th>Total ms</th><th>Diff vs Baseline</th><th>Diff vs Previous</th><th>Score</th><th>Source</th></tr></thead><tbody>",
	)
	for record in records {
		if record.name != name {
			continue
		}
		strings.write_string(builder, "<tr><td>")
		benchmark_graph_html_write_escaped(builder, record.version)
		strings.write_string(builder, "</td><td>")
		benchmark_graph_html_write_escaped(builder, record.status)
		fmt.sbprintf(
			builder,
			"</td><td>%.3f</td><td>%.3f</td><td class=\"%s\">%.2f%%</td><td class=\"%s\">%.2f%%</td><td>%.2f</td><td class=\"metrics\">",
			record.avg_us,
			record.total_wall_ms,
			benchmark_graph_delta_class(record.delta_pct),
			record.delta_pct,
			benchmark_graph_delta_class(record.prev_delta_pct),
			record.prev_delta_pct,
			record.score,
		)
		benchmark_graph_html_write_escaped(builder, record.source_path)
		strings.write_string(builder, "</td></tr>")
	}
	strings.write_string(builder, "</tbody></table>")
}

benchmark_graph_html_write_escaped :: proc(builder: ^strings.Builder, value: string) {
	for i := 0; i < len(value); i += 1 {
		switch value[i] {
		case '&':
			strings.write_string(builder, "&amp;")
		case '<':
			strings.write_string(builder, "&lt;")
		case '>':
			strings.write_string(builder, "&gt;")
		case '"':
			strings.write_string(builder, "&quot;")
		case '\'':
			strings.write_string(builder, "&#39;")
		case:
			strings.write_byte(builder, value[i])
		}
	}
}

benchmark_graph_delta_class :: proc(delta_pct: f64) -> string {
	if delta_pct < 0 {
		return "good"
	}
	if delta_pct > 0 {
		return "bad"
	}
	return "muted"
}

benchmark_graph_version_score_index :: proc(
	scores: []BenchmarkGraphVersionScore,
	score_count: u32,
	version: string,
) -> int {
	for i := u32(0); i < score_count; i += 1 {
		if scores[i].version == version {
			return int(i)
		}
	}
	_ = scores
	return -1
}

benchmark_graph_first_record_index :: proc(records: []BenchmarkGraphRecord, name: string) -> int {
	for i := 0; i < len(records); i += 1 {
		if records[i].name == name {
			return i
		}
	}
	return -1
}

benchmark_graph_record_count :: proc(records: []BenchmarkGraphRecord, name: string) -> u32 {
	count: u32
	for record in records {
		if record.name == name {
			count += 1
		}
	}
	return count
}

benchmark_graph_latest_record :: proc(
	records: []BenchmarkGraphRecord,
	name: string,
) -> BenchmarkGraphRecord {
	latest := BenchmarkGraphRecord{}
	for record in records {
		if record.name == name {
			latest = record
		}
	}
	return latest
}

benchmark_graph_json_object :: proc(value: json.Value) -> (json.Object, bool) {
	#partial switch v in value {
	case json.Object:
		return v, true
	}
	return nil, false
}

benchmark_graph_json_array :: proc(value: json.Value) -> (json.Array, bool) {
	#partial switch v in value {
	case json.Array:
		return v, true
	}
	return nil, false
}

benchmark_graph_json_string_default :: proc(
	object: json.Object,
	name: string,
	default_value: string,
) -> string {
	value, ok := object[name]
	if !ok {
		return default_value
	}
	#partial switch v in value {
	case json.String:
		return v
	}
	return default_value
}

benchmark_graph_json_f64_default :: proc(
	object: json.Object,
	name: string,
	default_value: f64,
) -> f64 {
	value, ok := object[name]
	if !ok {
		return default_value
	}
	#partial switch v in value {
	case json.Integer:
		return f64(v)
	case json.Float:
		return v
	}
	return default_value
}
