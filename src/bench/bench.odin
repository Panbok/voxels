package bench

import "core:fmt"
import "core:mem"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:thread"
import time "core:time"

BENCHMARKS_ENABLED :: #config(BENCHMARKS_ENABLED, true)

BENCHMARK_MAX_CASES :: 128
BENCHMARK_MAX_SELECTIONS :: 64
BENCHMARK_MAX_GRAPH_INPUTS :: 64
BENCHMARK_MAX_METRICS :: 128
BENCHMARK_MAX_METADATA :: 96
BENCHMARK_MAX_ARTIFACTS :: 32
BENCHMARK_WORKER_TEMP_BYTES :: #config(BENCHMARK_WORKER_TEMP_BYTES, 16 * mem.Megabyte)

BenchmarkStatusKind :: enum {
	Pass,
	Fail,
	Skip,
}

BenchmarkStatus :: struct {
	kind:    BenchmarkStatusKind,
	message: string,
}

BenchmarkProfile :: struct {}

BenchmarkContext :: struct {
	name:            string,
	worker_index:    u32,
	worker_count:    u32,
	iteration_index: u64,
	iteration_count: u64,
	allocator:       mem.Allocator,
	temp_arena:      ^mem.Arena,
	profile:         ^BenchmarkProfile,
	artifact_dir:    string,
	case_result:     ^BenchmarkCaseResult,
}

BenchmarkRunProc :: #type proc(
	ctx: ^BenchmarkContext,
	data: rawptr,
	result: rawptr,
) -> BenchmarkStatus

BenchmarkReduceProc :: #type proc(dst, src: rawptr)
BenchmarkLifecycleProc :: #type proc(ctx: ^BenchmarkContext, data: rawptr) -> BenchmarkStatus
BenchmarkFinalizeProc :: #type proc(
	ctx: ^BenchmarkContext,
	data: rawptr,
	result: rawptr,
) -> BenchmarkStatus

BenchmarkMetadataValueKind :: enum {
	U64,
	I64,
	F64,
	Bool,
	String,
}

BenchmarkMetadataValue :: struct {
	name:         string,
	kind:         BenchmarkMetadataValueKind,
	u64_value:    u64,
	i64_value:    i64,
	f64_value:    f64,
	bool_value:   bool,
	string_value: string,
	unit:         string,
}

BenchmarkMetadataWriter :: struct {
	allocator: mem.Allocator,
	entries:   [BENCHMARK_MAX_METADATA]BenchmarkMetadataValue,
	count:     u32,
}

BenchmarkMetadataProc :: #type proc(
	ctx: ^BenchmarkContext,
	data: rawptr,
	writer: ^BenchmarkMetadataWriter,
) -> BenchmarkStatus

BenchmarkCaseFlag :: enum {
	Parallel_Safe,
	Serial_Only,
	Exclusive_World_State,
	Requires_Gfx,
	Mutates_Global_State,
	Uses_Shared_Caches,
	Measures_Cache_Contention,
	Emits_Artifacts,
	Runtime_Owns_Main_Loop,
}

BenchmarkCaseFlags :: bit_set[BenchmarkCaseFlag;u32]

BenchmarkWarmupMode :: enum {
	None,
	Serial,
	Per_Worker,
}

BenchmarkMetricKind :: enum {
	U64,
	I64,
	F64,
	Bool,
	String,
	Artifact_Path,
}

BenchmarkReduceOp :: enum {
	Last,
	Sum,
	Min,
	Max,
	Mean,
	Weighted_Mean,
	Checksum_Xor,
}

BenchmarkMetricDescriptor :: struct {
	name:        string,
	kind:        BenchmarkMetricKind,
	offset:      uintptr,
	reduce:      BenchmarkReduceOp,
	weight_name: string,
	unit:        string,
	description: string,
}

BenchmarkOptions :: struct {
	iterations:        u32,
	warmup_iterations: u32,
	workers:           u32,
	result_size:       int,
	result_align:      int,
	data_size:         int,
	data_align:        int,
	metrics:           []BenchmarkMetricDescriptor,
	reduce:            BenchmarkReduceProc,
	flags:             BenchmarkCaseFlags,
	warmup_mode:       BenchmarkWarmupMode,
	setup:             BenchmarkLifecycleProc,
	precondition:      BenchmarkLifecycleProc,
	teardown:          BenchmarkLifecycleProc,
	setup_worker:      BenchmarkLifecycleProc,
	teardown_worker:   BenchmarkLifecycleProc,
	finalize:          BenchmarkFinalizeProc,
	write_fixture:     BenchmarkMetadataProc,
	category:          string,
	notes:             string,
	version:           string,
	default_in_all:    bool,
}

BenchmarkBuildMetadataProc :: #type proc(writer: ^BenchmarkMetadataWriter)

BenchmarkRunnerOptions :: struct {
	stdout:              bool,
	json_enabled:        bool,
	json_path:           string,
	html_enabled:        bool,
	html_path:           string,
	graph_requested:     bool,
	graph_path:          string,
	graph_inputs:        [BENCHMARK_MAX_GRAPH_INPUTS]string,
	graph_input_count:   u32,
	artifact_dir:        string,
	workers:             u32,
	list_requested:      bool,
	bench_requested:     bool,
	select_all:          bool,
	selected_names:      [BENCHMARK_MAX_SELECTIONS]string,
	selected_name_count: u32,
	write_build:         BenchmarkBuildMetadataProc,
}

BenchmarkCLIParseResult :: struct {
	options: BenchmarkRunnerOptions,
	ok:      bool,
	error:   string,
}

BenchmarkTimingResult :: struct {
	total_wall_ms:        f64,
	total_worker_ms:      f64,
	avg_us_per_iteration: f64,
	min_worker_ms:        f64,
	max_worker_ms:        f64,
	completed_iterations: u64,
	failed_iterations:    u64,
	skipped_iterations:   u64,
}

BenchmarkArtifactRecord :: struct {
	label:        string,
	kind:         string,
	path:         string,
	content_type: string,
}

BenchmarkMetricValue :: struct {
	name:         string,
	kind:         BenchmarkMetricKind,
	u64_value:    u64,
	i64_value:    i64,
	f64_value:    f64,
	bool_value:   bool,
	string_value: string,
	unit:         string,
	description:  string,
}

BenchmarkCaseResult :: struct {
	name:              string,
	version:           string,
	status:            BenchmarkStatusKind,
	error:             string,
	flags:             BenchmarkCaseFlags,
	workers:           u32,
	iterations:        u32,
	warmup_iterations: u32,
	fixture:           [BENCHMARK_MAX_METADATA]BenchmarkMetadataValue,
	fixture_count:     u32,
	timing:            BenchmarkTimingResult,
	metrics:           [BENCHMARK_MAX_METRICS]BenchmarkMetricValue,
	metric_count:      u32,
	artifacts:         [BENCHMARK_MAX_ARTIFACTS]BenchmarkArtifactRecord,
	artifact_count:    u32,
	category:          string,
	notes:             string,
}

BenchmarkSuiteResult :: struct {
	schema:          string,
	suite:           string,
	build:           [BENCHMARK_MAX_METADATA]BenchmarkMetadataValue,
	build_count:     u32,
	benchmarks:      [BENCHMARK_MAX_CASES]BenchmarkCaseResult,
	benchmark_count: u32,
}

BenchmarkCase :: struct {
	name:            string,
	run:             BenchmarkRunProc,
	data:            rawptr,
	result_external: rawptr,
	result_storage:  rawptr,
	options:         BenchmarkOptions,
}

BenchmarkRegistry :: struct {
	allocator: mem.Allocator,
	cases:     [BENCHMARK_MAX_CASES]BenchmarkCase,
	count:     u32,
	ok:        bool,
	error:     string,
}

BenchmarkWorkerRunData :: struct {
	case_ptr:             ^BenchmarkCase,
	worker_index:         u32,
	worker_count:         u32,
	iteration_count:      u64,
	allocator:            mem.Allocator,
	artifact_dir:         string,
	result:               rawptr,
	status:               BenchmarkStatus,
	duration:             time.Duration,
	completed_iterations: u64,
	failed_iterations:    u64,
	skipped_iterations:   u64,
	temp_slab:            []u8,
	temp_arena:           mem.Arena,
	profile:              BenchmarkProfile,
	case_result:          ^BenchmarkCaseResult,
}

status_pass :: proc() -> BenchmarkStatus {
	return {kind = .Pass}
}

status_fail :: proc(message: string) -> BenchmarkStatus {
	return {kind = .Fail, message = message}
}

registry_init :: proc(registry: ^BenchmarkRegistry, allocator: mem.Allocator) {
	registry^ = {
		allocator = allocator,
		ok        = true,
	}
}

case_has_flag :: proc(flags: BenchmarkCaseFlags, flag: BenchmarkCaseFlag) -> bool {
	return flag in flags
}

register :: proc(
	registry: ^BenchmarkRegistry,
	name: string,
	run: BenchmarkRunProc,
	data: rawptr,
	result: rawptr,
	options: BenchmarkOptions,
) {
	if registry == nil {
		return
	}
	if !registry.ok {
		return
	}
	if name == "" {
		registry.ok = false
		registry.error = "benchmark registration failed: empty name"
		return
	}
	if run == nil {
		registry.ok = false
		registry.error = fmt.aprintf(
			"benchmark registration failed for %s: run proc is nil",
			name,
			allocator = registry.allocator,
		)
		return
	}
	case_options := options
	for i := u32(0); i < registry.count; i += 1 {
		if registry.cases[i].name == name {
			registry.ok = false
			registry.error = fmt.aprintf(
				"benchmark registration failed: duplicate name %s",
				name,
				allocator = registry.allocator,
			)
			return
		}
	}
	if registry.count >= BENCHMARK_MAX_CASES {
		registry.ok = false
		registry.error = "benchmark registration failed: registry capacity exceeded"
		return
	}
	if case_options.iterations == 0 {
		case_options.iterations = 1
	}
	if case_options.workers == 0 {
		case_options.workers = 1
	}
	if case_options.version == "" {
		case_options.version = "1"
	}
	if case_options.warmup_mode == .None && case_options.warmup_iterations > 0 {
		case_options.warmup_mode = .Serial
	}
	if !case_options.default_in_all &&
	   !case_has_flag(case_options.flags, .Runtime_Owns_Main_Loop) &&
	   !case_has_flag(case_options.flags, .Emits_Artifacts) &&
	   !case_has_flag(case_options.flags, .Measures_Cache_Contention) {
		case_options.default_in_all = true
	}
	if case_options.data_size < 0 || case_options.result_size < 0 {
		registry.ok = false
		registry.error = fmt.aprintf(
			"benchmark registration failed for %s: negative storage size",
			name,
			allocator = registry.allocator,
		)
		return
	}

	stored_data := data
	if case_options.data_size > 0 {
		if data == nil {
			registry.ok = false
			registry.error = fmt.aprintf(
				"benchmark registration failed for %s: data pointer is nil",
				name,
				allocator = registry.allocator,
			)
			return
		}
		data_align := case_options.data_align
		if data_align <= 0 {
			data_align = mem.DEFAULT_ALIGNMENT
		}
		data_storage, alloc_err := mem.alloc(
			case_options.data_size,
			data_align,
			registry.allocator,
		)
		if alloc_err != nil || data_storage == nil {
			registry.ok = false
			registry.error = fmt.aprintf(
				"benchmark registration failed for %s: could not allocate fixture storage",
				name,
				allocator = registry.allocator,
			)
			return
		}
		mem.copy(data_storage, data, case_options.data_size)
		stored_data = data_storage
	}

	result_storage: rawptr
	if case_options.result_size > 0 {
		result_align := case_options.result_align
		if result_align <= 0 {
			result_align = mem.DEFAULT_ALIGNMENT
		}
		storage, alloc_err := mem.alloc(case_options.result_size, result_align, registry.allocator)
		if alloc_err != nil || storage == nil {
			registry.ok = false
			registry.error = fmt.aprintf(
				"benchmark registration failed for %s: could not allocate result storage",
				name,
				allocator = registry.allocator,
			)
			return
		}
		mem.zero(storage, case_options.result_size)
		if result != nil {
			mem.copy(storage, result, case_options.result_size)
		}
		result_storage = storage
	}

	registry.cases[registry.count] = {
		name            = name,
		run             = run,
		data            = stored_data,
		result_external = result,
		result_storage  = result_storage,
		options         = case_options,
	}
	registry.count += 1
}

metadata_reset :: proc(writer: ^BenchmarkMetadataWriter, allocator: mem.Allocator) {
	writer^ = {
		allocator = allocator,
	}
}

metadata_add :: proc(writer: ^BenchmarkMetadataWriter, value: BenchmarkMetadataValue) {
	if writer == nil || writer.count >= BENCHMARK_MAX_METADATA {
		return
	}
	writer.entries[writer.count] = value
	writer.count += 1
}

metadata_u64 :: proc(
	writer: ^BenchmarkMetadataWriter,
	name: string,
	value: u64,
	unit: string = "",
) {
	metadata_add(writer, {name = name, kind = .U64, u64_value = value, unit = unit})
}

metadata_i64 :: proc(
	writer: ^BenchmarkMetadataWriter,
	name: string,
	value: i64,
	unit: string = "",
) {
	metadata_add(writer, {name = name, kind = .I64, i64_value = value, unit = unit})
}

metadata_f64 :: proc(
	writer: ^BenchmarkMetadataWriter,
	name: string,
	value: f64,
	unit: string = "",
) {
	metadata_add(writer, {name = name, kind = .F64, f64_value = value, unit = unit})
}

metadata_bool :: proc(writer: ^BenchmarkMetadataWriter, name: string, value: bool) {
	metadata_add(writer, {name = name, kind = .Bool, bool_value = value})
}

metadata_string :: proc(writer: ^BenchmarkMetadataWriter, name: string, value: string) {
	metadata_add(writer, {name = name, kind = .String, string_value = value})
}

artifact_add :: proc(
	result: ^BenchmarkCaseResult,
	label: string,
	kind: string,
	path: string,
	content_type: string,
) {
	if result == nil || result.artifact_count >= BENCHMARK_MAX_ARTIFACTS {
		return
	}
	result.artifacts[result.artifact_count] = {
		label        = label,
		kind         = kind,
		path         = path,
		content_type = content_type,
	}
	result.artifact_count += 1
}

parse_cli_args :: proc(args: []string) -> BenchmarkCLIParseResult {
	result := BenchmarkCLIParseResult {
		ok = true,
		options = {
			stdout = true,
			json_path = "bench/results.json",
			html_path = "bench/results.html",
			graph_path = "bench/compare.html",
			artifact_dir = "bench/artifacts",
			workers = 0,
		},
	}

	for i := 1; i < len(args); i += 1 {
		arg := args[i]
		if arg == "--bench-list" {
			result.options.bench_requested = true
			result.options.list_requested = true
		} else if arg == "--bench-graph" {
			if i + 1 >= len(args) {
				result.ok = false
				result.error = "--bench-graph requires an output HTML path and at least one JSON input"
				return result
			}
			i += 1
			result.options.bench_requested = true
			result.options.graph_requested = true
			result.options.graph_path = args[i]
			for i + 1 < len(args) && !strings.has_prefix(args[i + 1], "--") {
				i += 1
				if !benchmark_graph_input_add(&result.options, args[i]) {
					result.ok = false
					result.error = "--bench-graph input capacity exceeded"
					return result
				}
			}
		} else if arg == "--bench-graph-input" {
			if i + 1 >= len(args) {
				result.ok = false
				result.error = "--bench-graph-input requires a JSON path"
				return result
			}
			i += 1
			result.options.bench_requested = true
			result.options.graph_requested = true
			if !benchmark_graph_input_add(&result.options, args[i]) {
				result.ok = false
				result.error = "--bench-graph input capacity exceeded"
				return result
			}
		} else if arg == "--bench" {
			if i + 1 >= len(args) {
				result.ok = false
				result.error = "--bench requires a benchmark name, comma-separated list, or all"
				return result
			}
			i += 1
			selection := strings.trim_space(args[i])
			if !benchmark_parse_selection(&result.options, selection) {
				result.ok = false
				result.error = "invalid --bench selection"
				return result
			}
			result.options.bench_requested = true
			result.options.json_enabled = true
		} else if arg == "--bench-json" {
			if i + 1 >= len(args) {
				result.ok = false
				result.error = "--bench-json requires a path"
				return result
			}
			i += 1
			result.options.json_enabled = true
			result.options.json_path = args[i]
		} else if arg == "--bench-html" {
			result.options.html_enabled = true
			if i + 1 < len(args) && !strings.has_prefix(args[i + 1], "--") {
				i += 1
				result.options.html_path = args[i]
			}
		} else if arg == "--bench-workers" {
			if i + 1 >= len(args) {
				result.ok = false
				result.error = "--bench-workers requires a positive integer"
				return result
			}
			i += 1
			workers, ok := strconv.parse_uint(args[i])
			if !ok || workers == 0 {
				result.ok = false
				result.error = "--bench-workers requires a positive integer"
				return result
			}
			result.options.workers = u32(workers)
		} else {
			if strings.has_prefix(arg, "--bench") {
				result.ok = false
				result.error = fmt.aprintf("unknown benchmark argument: %s", arg)
				return result
			}
		}
	}

	if result.options.graph_requested {
		if result.options.graph_path == "" {
			result.ok = false
			result.error = "--bench-graph requires an output HTML path"
			return result
		}
		if result.options.graph_input_count == 0 {
			result.ok = false
			result.error = "--bench-graph requires at least one JSON input"
			return result
		}
		return result
	}

	if result.options.bench_requested &&
	   !result.options.list_requested &&
	   !result.options.select_all &&
	   result.options.selected_name_count == 0 {
		result.ok = false
		result.error = "--bench requires a non-empty selection"
		return result
	}
	return result
}

benchmark_graph_input_add :: proc(options: ^BenchmarkRunnerOptions, path: string) -> bool {
	if options == nil || path == "" {
		return false
	}
	if options.graph_input_count >= BENCHMARK_MAX_GRAPH_INPUTS {
		return false
	}
	options.graph_inputs[options.graph_input_count] = path
	options.graph_input_count += 1
	return true
}

benchmark_parse_selection :: proc(options: ^BenchmarkRunnerOptions, selection: string) -> bool {
	trimmed_selection := strings.trim_space(selection)
	if trimmed_selection == "" {
		return false
	}
	if trimmed_selection[len(trimmed_selection) - 1] == ',' {
		return false
	}

	options.select_all = false
	options.selected_name_count = 0

	remaining := trimmed_selection
	for {
		part, ok := strings.split_iterator(&remaining, ",")
		if !ok {
			break
		}
		name := strings.trim_space(part)
		if name == "" {
			return false
		}
		if name == "all" {
			if options.selected_name_count > 0 {
				return false
			}
			options.select_all = true
			continue
		}
		if options.select_all {
			return false
		}
		for i := u32(0); i < options.selected_name_count; i += 1 {
			if options.selected_names[i] == name {
				return false
			}
		}
		if options.selected_name_count >= BENCHMARK_MAX_SELECTIONS {
			return false
		}
		options.selected_names[options.selected_name_count] = name
		options.selected_name_count += 1
	}

	return options.select_all || options.selected_name_count > 0
}

list :: proc(registry: ^BenchmarkRegistry) {
	if registry == nil {
		return
	}
	for i := u32(0); i < registry.count; i += 1 {
		fmt.println(registry.cases[i].name)
	}
}

run :: proc(registry: ^BenchmarkRegistry, options: BenchmarkRunnerOptions) -> bool {
	if registry == nil {
		fmt.eprintln("benchmark registry is nil")
		return false
	}
	if options.graph_requested {
		if !benchmark_prepare_output_path(options.graph_path) {
			return false
		}
		graph_inputs := options.graph_inputs
		return write_graph_html(
			options.graph_path,
			graph_inputs[:options.graph_input_count],
			registry.allocator,
		)
	}
	if !BENCHMARKS_ENABLED {
		fmt.eprintln(
			"benchmarks are disabled in this binary; rebuild with -define:BENCHMARKS_ENABLED=true",
		)
		return false
	}
	if !registry.ok {
		fmt.eprintfln("%s", registry.error)
		return false
	}
	if options.list_requested {
		list(registry)
		return true
	}

	selected_indices: [BENCHMARK_MAX_CASES]u32
	selected_count: u32
	if !benchmark_resolve_selection(registry, options, selected_indices[:], &selected_count) {
		return false
	}

	runtime_case_count: u32
	for i := u32(0); i < selected_count; i += 1 {
		if case_has_flag(
			registry.cases[selected_indices[i]].options.flags,
			.Runtime_Owns_Main_Loop,
		) {
			runtime_case_count += 1
		}
	}
	if runtime_case_count > 0 && selected_count != 1 {
		fmt.eprintln("runtime benchmark cases must be selected alone")
		return false
	}

	if options.json_enabled {
		if !benchmark_prepare_output_path(options.json_path) {
			return false
		}
	}
	if options.html_enabled {
		if !benchmark_prepare_output_path(options.html_path) {
			return false
		}
	}
	if options.artifact_dir != "" {
		err := os.make_directory_all(options.artifact_dir)
		if err != nil && !os.is_directory(options.artifact_dir) {
			fmt.eprintfln(
				"failed to create benchmark artifact directory %s: %v",
				options.artifact_dir,
				err,
			)
			return false
		}
	}

	suite := new(BenchmarkSuiteResult, registry.allocator)
	suite^ = {
		schema = "voxels.benchmark.v1",
		suite  = "default",
	}
	build_writer := BenchmarkMetadataWriter{}
	metadata_reset(&build_writer, registry.allocator)
	if options.write_build != nil {
		options.write_build(&build_writer)
	}
	suite.build_count = build_writer.count
	for i := u32(0); i < build_writer.count; i += 1 {
		suite.build[i] = build_writer.entries[i]
	}

	all_passed := true
	for i := u32(0); i < selected_count; i += 1 {
		case_index := selected_indices[i]
		case_result := benchmark_run_case(&registry.cases[case_index], registry.allocator, options)
		if suite.benchmark_count < BENCHMARK_MAX_CASES {
			suite.benchmarks[suite.benchmark_count] = case_result
			suite.benchmark_count += 1
		}
		if case_result.status != .Pass {
			all_passed = false
		}
	}

	if options.json_enabled {
		if !write_json(options.json_path, suite) {
			all_passed = false
		}
	}
	if options.html_enabled {
		if !write_html(options.html_path, suite) {
			all_passed = false
		}
	}

	return all_passed
}

benchmark_resolve_selection :: proc(
	registry: ^BenchmarkRegistry,
	options: BenchmarkRunnerOptions,
	selected_indices: []u32,
	selected_count: ^u32,
) -> bool {
	selected_count^ = 0
	if options.select_all {
		for i := u32(0); i < registry.count; i += 1 {
			if !registry.cases[i].options.default_in_all {
				continue
			}
			selected_indices[selected_count^] = i
			selected_count^ += 1
		}
		return selected_count^ > 0
	}

	for i := u32(0); i < options.selected_name_count; i += 1 {
		name := options.selected_names[i]
		found := false
		for case_index := u32(0); case_index < registry.count; case_index += 1 {
			if registry.cases[case_index].name == name {
				selected_indices[selected_count^] = case_index
				selected_count^ += 1
				found = true
				break
			}
		}
		if !found {
			fmt.eprintfln("unknown benchmark: %s", name)
			fmt.eprintln("available benchmarks:")
			for case_index := u32(0); case_index < registry.count; case_index += 1 {
				fmt.eprintfln("  %s", registry.cases[case_index].name)
			}
			return false
		}
	}
	return selected_count^ > 0
}

benchmark_prepare_output_path :: proc(path: string) -> bool {
	if path == "" {
		fmt.eprintln("benchmark output path must not be empty")
		return false
	}
	dir := os.dir(path)
	if dir != "." && dir != "" {
		err := os.make_directory_all(dir)
		if err != nil && !os.is_directory(dir) {
			fmt.eprintfln("failed to create benchmark output directory %s: %v", dir, err)
			return false
		}
	}
	return true
}

benchmark_run_case :: proc(
	case_ptr: ^BenchmarkCase,
	allocator: mem.Allocator,
	options: BenchmarkRunnerOptions,
) -> BenchmarkCaseResult {
	result := BenchmarkCaseResult {
		name              = case_ptr.name,
		version           = case_ptr.options.version,
		status            = .Pass,
		flags             = case_ptr.options.flags,
		iterations        = case_ptr.options.iterations,
		warmup_iterations = case_ptr.options.warmup_iterations,
		category          = case_ptr.options.category,
		notes             = case_ptr.options.notes,
	}

	worker_count := case_ptr.options.workers
	if options.workers > 0 {
		worker_count = options.workers
	}
	if worker_count == 0 {
		worker_count = 1
	}
	if !case_has_flag(case_ptr.options.flags, .Parallel_Safe) && worker_count > 1 {
		result.status = .Fail
		result.error = "--bench-workers requested multiple workers for a benchmark that is not Parallel_Safe"
		benchmark_print_result(&result, options.stdout)
		return result
	}
	if case_has_flag(case_ptr.options.flags, .Serial_Only) ||
	   case_has_flag(case_ptr.options.flags, .Runtime_Owns_Main_Loop) {
		worker_count = 1
	}
	result.workers = worker_count

	ctx := BenchmarkContext {
		name            = case_ptr.name,
		worker_index    = 0,
		worker_count    = worker_count,
		iteration_count = u64(case_ptr.options.iterations),
		allocator       = allocator,
		artifact_dir    = options.artifact_dir,
		case_result     = &result,
	}

	if case_ptr.result_storage != nil && case_ptr.options.result_size > 0 {
		mem.zero(case_ptr.result_storage, case_ptr.options.result_size)
	}

	status := benchmark_lifecycle_call(case_ptr.options.setup, &ctx, case_ptr.data)
	if status.kind != .Pass {
		result.status = status.kind
		result.error = status.message
		benchmark_print_result(&result, options.stdout)
		return result
	}
	defer {
		teardown_status := benchmark_lifecycle_call(case_ptr.options.teardown, &ctx, case_ptr.data)
		if result.status == .Pass && teardown_status.kind != .Pass {
			result.status = teardown_status.kind
			result.error = teardown_status.message
		}
	}

	fixture_writer := BenchmarkMetadataWriter{}
	metadata_reset(&fixture_writer, allocator)
	if case_ptr.options.write_fixture != nil {
		fixture_status := case_ptr.options.write_fixture(&ctx, case_ptr.data, &fixture_writer)
		if fixture_status.kind != .Pass {
			result.status = fixture_status.kind
			result.error = fixture_status.message
			benchmark_print_result(&result, options.stdout)
			return result
		}
	}
	result.fixture_count = fixture_writer.count
	for i := u32(0); i < fixture_writer.count; i += 1 {
		result.fixture[i] = fixture_writer.entries[i]
	}

	if case_ptr.options.warmup_iterations > 0 {
		warmup_status := benchmark_run_warmup(case_ptr, allocator, options.artifact_dir)
		if warmup_status.kind != .Pass {
			result.status = warmup_status.kind
			result.error = warmup_status.message
			benchmark_print_result(&result, options.stdout)
			return result
		}
	}

	status = benchmark_lifecycle_call(case_ptr.options.precondition, &ctx, case_ptr.data)
	if status.kind != .Pass {
		result.status = status.kind
		result.error = status.message
		benchmark_print_result(&result, options.stdout)
		return result
	}

	if case_has_flag(case_ptr.options.flags, .Runtime_Owns_Main_Loop) {
		timing_start := time.tick_now()
		status = case_ptr.run(&ctx, case_ptr.data, case_ptr.result_storage)
		duration := time.tick_since(timing_start)
		result.timing.total_wall_ms = time.duration_milliseconds(duration)
		result.timing.total_worker_ms = result.timing.total_wall_ms
		result.timing.completed_iterations = 1
		result.timing.avg_us_per_iteration = time.duration_microseconds(duration)
		result.timing.min_worker_ms = result.timing.total_wall_ms
		result.timing.max_worker_ms = result.timing.total_wall_ms
		if status.kind != .Pass {
			result.status = status.kind
			result.error = status.message
		}
	} else {
		benchmark_workers_run(case_ptr, allocator, options.artifact_dir, worker_count, &result)
	}

	if result.status == .Pass && case_ptr.options.finalize != nil {
		finalize_status := case_ptr.options.finalize(&ctx, case_ptr.data, case_ptr.result_storage)
		if finalize_status.kind != .Pass {
			result.status = finalize_status.kind
			result.error = finalize_status.message
		}
	}

	if case_ptr.result_external != nil &&
	   case_ptr.result_storage != nil &&
	   case_ptr.options.result_size > 0 {
		mem.copy(case_ptr.result_external, case_ptr.result_storage, case_ptr.options.result_size)
	}

	benchmark_metrics_extract(case_ptr, &result)
	benchmark_print_result(&result, options.stdout)
	return result
}

benchmark_lifecycle_call :: proc(
	lifecycle: BenchmarkLifecycleProc,
	ctx: ^BenchmarkContext,
	data: rawptr,
) -> BenchmarkStatus {
	if lifecycle == nil {
		return status_pass()
	}
	return lifecycle(ctx, data)
}

benchmark_run_warmup :: proc(
	case_ptr: ^BenchmarkCase,
	allocator: mem.Allocator,
	artifact_dir: string,
) -> BenchmarkStatus {
	temp_slab := make([]u8, BENCHMARK_WORKER_TEMP_BYTES, allocator)
	temp_arena := mem.Arena{}
	mem.arena_init(&temp_arena, temp_slab)
	defer {
		_ = delete(temp_slab, allocator)
	}

	result_storage: rawptr
	if case_ptr.options.result_size > 0 {
		result_storage, _ = mem.alloc(
			case_ptr.options.result_size,
			case_ptr.options.result_align,
			allocator,
		)
		if result_storage == nil {
			return status_fail("warmup result allocation failed")
		}
		defer {
			_ = mem.free(result_storage, allocator)
		}
	}

	ctx := BenchmarkContext {
		name            = case_ptr.name,
		worker_index    = 0,
		worker_count    = 1,
		iteration_count = u64(case_ptr.options.warmup_iterations),
		allocator       = allocator,
		temp_arena      = &temp_arena,
		artifact_dir    = artifact_dir,
		case_result     = nil,
	}
	for i := u64(0); i < u64(case_ptr.options.warmup_iterations); i += 1 {
		mem.arena_free_all(&temp_arena)
		if result_storage != nil {
			mem.zero(result_storage, case_ptr.options.result_size)
		}
		ctx.iteration_index = i
		status := case_ptr.run(&ctx, case_ptr.data, result_storage)
		if status.kind != .Pass {
			return status
		}
	}
	return status_pass()
}

benchmark_workers_run :: proc(
	case_ptr: ^BenchmarkCase,
	allocator: mem.Allocator,
	artifact_dir: string,
	worker_count: u32,
	result: ^BenchmarkCaseResult,
) {
	worker_data: [BENCHMARK_MAX_SELECTIONS]BenchmarkWorkerRunData
	threads: [BENCHMARK_MAX_SELECTIONS]^thread.Thread
	if worker_count > BENCHMARK_MAX_SELECTIONS {
		result.status = .Fail
		result.error = "requested worker count exceeds benchmark worker capacity"
		return
	}

	result_size := case_ptr.options.result_size
	result_align := case_ptr.options.result_align
	if result_align <= 0 {
		result_align = mem.DEFAULT_ALIGNMENT
	}

	for worker_index := u32(0); worker_index < worker_count; worker_index += 1 {
		data := &worker_data[worker_index]
		data.case_ptr = case_ptr
		data.worker_index = worker_index
		data.worker_count = worker_count
		data.iteration_count = u64(case_ptr.options.iterations)
		data.allocator = allocator
		data.artifact_dir = artifact_dir
		data.case_result = result
		data.status = status_pass()
		data.temp_slab = make([]u8, BENCHMARK_WORKER_TEMP_BYTES, allocator)
		mem.arena_init(&data.temp_arena, data.temp_slab)
		if result_size > 0 {
			data.result, _ = mem.alloc(result_size, result_align, allocator)
			if data.result == nil {
				result.status = .Fail
				result.error = "worker result allocation failed"
				return
			}
			mem.zero(data.result, result_size)
		}
	}
	defer {
		for worker_index := u32(0); worker_index < worker_count; worker_index += 1 {
			if worker_data[worker_index].result != nil {
				_ = mem.free(worker_data[worker_index].result, allocator)
			}
			if worker_data[worker_index].temp_slab != nil {
				_ = delete(worker_data[worker_index].temp_slab, allocator)
			}
		}
	}

	wall_start := time.tick_now()
	if worker_count == 1 {
		benchmark_worker_proc(rawptr(&worker_data[0]))
	} else {
		for worker_index := u32(0); worker_index < worker_count; worker_index += 1 {
			threads[worker_index] = thread.create_and_start_with_data(
				rawptr(&worker_data[worker_index]),
				benchmark_worker_proc,
			)
		}
		for worker_index := u32(0); worker_index < worker_count; worker_index += 1 {
			thread.join(threads[worker_index])
			thread.destroy(threads[worker_index])
		}
	}
	wall_duration := time.tick_since(wall_start)

	total_worker_duration := time.Duration(0)
	min_worker_duration := time.Duration(0)
	max_worker_duration := time.Duration(0)
	for worker_index := u32(0); worker_index < worker_count; worker_index += 1 {
		data := &worker_data[worker_index]
		if worker_index == 0 || data.duration < min_worker_duration {
			min_worker_duration = data.duration
		}
		if worker_index == 0 || data.duration > max_worker_duration {
			max_worker_duration = data.duration
		}
		total_worker_duration += data.duration
		result.timing.completed_iterations += data.completed_iterations
		result.timing.failed_iterations += data.failed_iterations
		result.timing.skipped_iterations += data.skipped_iterations
		if result.status == .Pass && data.status.kind != .Pass {
			result.status = data.status.kind
			result.error = data.status.message
		}
	}

	result.timing.total_wall_ms = time.duration_milliseconds(wall_duration)
	result.timing.total_worker_ms = time.duration_milliseconds(total_worker_duration)
	result.timing.min_worker_ms = time.duration_milliseconds(min_worker_duration)
	result.timing.max_worker_ms = time.duration_milliseconds(max_worker_duration)
	if result.timing.completed_iterations > 0 {
		result.timing.avg_us_per_iteration =
			time.duration_microseconds(wall_duration) / f64(result.timing.completed_iterations)
	}

	if case_ptr.options.result_size > 0 && case_ptr.result_storage != nil {
		benchmark_results_merge(case_ptr, worker_data[:worker_count])
	}
}

benchmark_worker_proc :: proc(data_raw: rawptr) {
	data := (^BenchmarkWorkerRunData)(data_raw)
	case_ptr := data.case_ptr
	ctx := BenchmarkContext {
		name            = case_ptr.name,
		worker_index    = data.worker_index,
		worker_count    = data.worker_count,
		iteration_count = data.iteration_count,
		allocator       = data.allocator,
		temp_arena      = &data.temp_arena,
		profile         = &data.profile,
		artifact_dir    = data.artifact_dir,
		case_result     = data.case_result,
	}

	status := benchmark_lifecycle_call(case_ptr.options.setup_worker, &ctx, case_ptr.data)
	if status.kind != .Pass {
		data.status = status
		return
	}
	defer {
		teardown_status := benchmark_lifecycle_call(
			case_ptr.options.teardown_worker,
			&ctx,
			case_ptr.data,
		)
		if data.status.kind == .Pass && teardown_status.kind != .Pass {
			data.status = teardown_status
		}
	}

	start := time.tick_now()
	for iteration := u64(data.worker_index);
	    iteration < data.iteration_count;
	    iteration += u64(data.worker_count) {
		mem.arena_free_all(&data.temp_arena)
		ctx.iteration_index = iteration
		status = case_ptr.run(&ctx, case_ptr.data, data.result)
		switch status.kind {
		case .Pass:
			data.completed_iterations += 1
		case .Fail:
			data.failed_iterations += 1
			data.status = status
			data.duration = time.tick_since(start)
			return
		case .Skip:
			data.skipped_iterations += 1
			data.status = status
			data.duration = time.tick_since(start)
			return
		}
	}
	data.duration = time.tick_since(start)
}

benchmark_results_merge :: proc(case_ptr: ^BenchmarkCase, worker_data: []BenchmarkWorkerRunData) {
	if case_ptr.options.reduce != nil {
		mem.zero(case_ptr.result_storage, case_ptr.options.result_size)
		for i := 0; i < len(worker_data); i += 1 {
			case_ptr.options.reduce(case_ptr.result_storage, worker_data[i].result)
		}
		return
	}

	if len(case_ptr.options.metrics) == 0 {
		if len(worker_data) > 0 && worker_data[0].result != nil {
			mem.copy(case_ptr.result_storage, worker_data[0].result, case_ptr.options.result_size)
		}
		return
	}

	mem.zero(case_ptr.result_storage, case_ptr.options.result_size)
	for metric in case_ptr.options.metrics {
		benchmark_metric_reduce(case_ptr.result_storage, worker_data, metric)
	}
}

benchmark_metric_reduce :: proc(
	dst: rawptr,
	worker_data: []BenchmarkWorkerRunData,
	metric: BenchmarkMetricDescriptor,
) {
	if len(worker_data) == 0 {
		return
	}
	switch metric.kind {
	case .U64, .Artifact_Path:
		out := benchmark_metric_ptr_u64(dst, metric.offset)
		switch metric.reduce {
		case .Sum:
			for data in worker_data {
				out^ += benchmark_metric_ptr_u64(data.result, metric.offset)^
			}
		case .Min:
			for i in 0 ..< len(worker_data) {
				value := benchmark_metric_ptr_u64(worker_data[i].result, metric.offset)^
				if i == 0 || value < out^ {
					out^ = value
				}
			}
		case .Max:
			for i in 0 ..< len(worker_data) {
				value := benchmark_metric_ptr_u64(worker_data[i].result, metric.offset)^
				if i == 0 || value > out^ {
					out^ = value
				}
			}
		case .Checksum_Xor:
			for data in worker_data {
				out^ = out^ ~ benchmark_metric_ptr_u64(data.result, metric.offset)^
			}
		case .Mean, .Weighted_Mean:
			total: u64
			for data in worker_data {
				total += benchmark_metric_ptr_u64(data.result, metric.offset)^
			}
			out^ = total / u64(len(worker_data))
		case .Last:
			out^ = benchmark_metric_ptr_u64(
				worker_data[len(worker_data) - 1].result,
				metric.offset,
			)^
		}
	case .I64:
		out := benchmark_metric_ptr_i64(dst, metric.offset)
		switch metric.reduce {
		case .Sum:
			for data in worker_data {
				out^ += benchmark_metric_ptr_i64(data.result, metric.offset)^
			}
		case .Min:
			for i in 0 ..< len(worker_data) {
				value := benchmark_metric_ptr_i64(worker_data[i].result, metric.offset)^
				if i == 0 || value < out^ {
					out^ = value
				}
			}
		case .Max:
			for i in 0 ..< len(worker_data) {
				value := benchmark_metric_ptr_i64(worker_data[i].result, metric.offset)^
				if i == 0 || value > out^ {
					out^ = value
				}
			}
		case .Mean, .Weighted_Mean:
			total: i64
			for data in worker_data {
				total += benchmark_metric_ptr_i64(data.result, metric.offset)^
			}
			out^ = total / i64(len(worker_data))
		case .Last, .Checksum_Xor:
			out^ = benchmark_metric_ptr_i64(
				worker_data[len(worker_data) - 1].result,
				metric.offset,
			)^
		}
	case .F64:
		out := benchmark_metric_ptr_f64(dst, metric.offset)
		switch metric.reduce {
		case .Sum:
			for data in worker_data {
				out^ += benchmark_metric_ptr_f64(data.result, metric.offset)^
			}
		case .Min:
			for i in 0 ..< len(worker_data) {
				value := benchmark_metric_ptr_f64(worker_data[i].result, metric.offset)^
				if i == 0 || value < out^ {
					out^ = value
				}
			}
		case .Max:
			for i in 0 ..< len(worker_data) {
				value := benchmark_metric_ptr_f64(worker_data[i].result, metric.offset)^
				if i == 0 || value > out^ {
					out^ = value
				}
			}
		case .Mean, .Weighted_Mean:
			total: f64
			for data in worker_data {
				total += benchmark_metric_ptr_f64(data.result, metric.offset)^
			}
			out^ = total / f64(len(worker_data))
		case .Last, .Checksum_Xor:
			out^ = benchmark_metric_ptr_f64(
				worker_data[len(worker_data) - 1].result,
				metric.offset,
			)^
		}
	case .Bool:
		out := benchmark_metric_ptr_bool(dst, metric.offset)
		out^ = benchmark_metric_ptr_bool(worker_data[len(worker_data) - 1].result, metric.offset)^
	case .String:
		out := benchmark_metric_ptr_string(dst, metric.offset)
		out^ = benchmark_metric_ptr_string(
			worker_data[len(worker_data) - 1].result,
			metric.offset,
		)^
	}
}

benchmark_metric_ptr_u64 :: proc(base: rawptr, offset: uintptr) -> ^u64 {
	bytes := mem.byte_slice(base, int(offset) + size_of(u64))
	return (^u64)(rawptr(&bytes[int(offset)]))
}

benchmark_metric_ptr_i64 :: proc(base: rawptr, offset: uintptr) -> ^i64 {
	bytes := mem.byte_slice(base, int(offset) + size_of(i64))
	return (^i64)(rawptr(&bytes[int(offset)]))
}

benchmark_metric_ptr_f64 :: proc(base: rawptr, offset: uintptr) -> ^f64 {
	bytes := mem.byte_slice(base, int(offset) + size_of(f64))
	return (^f64)(rawptr(&bytes[int(offset)]))
}

benchmark_metric_ptr_bool :: proc(base: rawptr, offset: uintptr) -> ^bool {
	bytes := mem.byte_slice(base, int(offset) + size_of(bool))
	return (^bool)(rawptr(&bytes[int(offset)]))
}

benchmark_metric_ptr_string :: proc(base: rawptr, offset: uintptr) -> ^string {
	bytes := mem.byte_slice(base, int(offset) + size_of(string))
	return (^string)(rawptr(&bytes[int(offset)]))
}

benchmark_metrics_extract :: proc(case_ptr: ^BenchmarkCase, result: ^BenchmarkCaseResult) {
	if case_ptr.result_storage == nil {
		return
	}
	for metric in case_ptr.options.metrics {
		if result.metric_count >= BENCHMARK_MAX_METRICS {
			return
		}
		value := BenchmarkMetricValue {
			name        = metric.name,
			kind        = metric.kind,
			unit        = metric.unit,
			description = metric.description,
		}
		switch metric.kind {
		case .U64, .Artifact_Path:
			value.u64_value = benchmark_metric_ptr_u64(case_ptr.result_storage, metric.offset)^
		case .I64:
			value.i64_value = benchmark_metric_ptr_i64(case_ptr.result_storage, metric.offset)^
		case .F64:
			value.f64_value = benchmark_metric_ptr_f64(case_ptr.result_storage, metric.offset)^
		case .Bool:
			value.bool_value = benchmark_metric_ptr_bool(case_ptr.result_storage, metric.offset)^
		case .String:
			value.string_value = benchmark_metric_ptr_string(
				case_ptr.result_storage,
				metric.offset,
			)^
		}
		result.metrics[result.metric_count] = value
		result.metric_count += 1
	}
}

benchmark_print_result :: proc(result: ^BenchmarkCaseResult, enabled: bool) {
	if !enabled {
		return
	}
	status := benchmark_status_string(result.status)
	if result.status != .Pass {
		fmt.printfln(
			"BENCH name=%s version=%s status=%s error=%q workers=%d iterations=%d",
			result.name,
			result.version,
			status,
			result.error,
			result.workers,
			result.iterations,
		)
		return
	}
	fmt.printf(
		"BENCH name=%s version=%s status=%s workers=%d iterations=%d avg_us=%.3f total_wall_ms=%.3f",
		result.name,
		result.version,
		status,
		result.workers,
		result.iterations,
		result.timing.avg_us_per_iteration,
		result.timing.total_wall_ms,
	)
	for i := u32(0); i < result.metric_count; i += 1 {
		metric := result.metrics[i]
		switch metric.kind {
		case .U64, .Artifact_Path:
			fmt.printf(" %s=%d", metric.name, metric.u64_value)
		case .I64:
			fmt.printf(" %s=%d", metric.name, metric.i64_value)
		case .F64:
			fmt.printf(" %s=%.3f", metric.name, metric.f64_value)
		case .Bool:
			fmt.printf(" %s=%v", metric.name, metric.bool_value)
		case .String:
			fmt.printf(" %s=%s", metric.name, metric.string_value)
		}
	}
	fmt.println()
}

benchmark_status_string :: proc(status: BenchmarkStatusKind) -> string {
	switch status {
	case .Pass:
		return "pass"
	case .Fail:
		return "fail"
	case .Skip:
		return "skip"
	}
	return "unknown"
}

benchmark_flag_string :: proc(flag: BenchmarkCaseFlag) -> string {
	switch flag {
	case .Parallel_Safe:
		return "Parallel_Safe"
	case .Serial_Only:
		return "Serial_Only"
	case .Exclusive_World_State:
		return "Exclusive_World_State"
	case .Requires_Gfx:
		return "Requires_Gfx"
	case .Mutates_Global_State:
		return "Mutates_Global_State"
	case .Uses_Shared_Caches:
		return "Uses_Shared_Caches"
	case .Measures_Cache_Contention:
		return "Measures_Cache_Contention"
	case .Emits_Artifacts:
		return "Emits_Artifacts"
	case .Runtime_Owns_Main_Loop:
		return "Runtime_Owns_Main_Loop"
	}
	return "Unknown"
}
