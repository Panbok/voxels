package vdebug

import json "core:encoding/json"
import "core:fmt"
import "core:mem"
import "core:os"
import "core:strconv"
import "core:strings"
import time "core:time"

parse_cli_args :: proc(args: []string) -> VisualDebugCLIParseResult {
	result := VisualDebugCLIParseResult {
		ok = true,
		options = {ffmpeg_mode = "auto"},
	}

	for i := 1; i < len(args); i += 1 {
		arg := args[i]
		if arg == "--vdebug-list" {
			result.options.list_requested = true
		} else if arg == "--vdebug" {
			if i + 1 >= len(args) {
				return cli_error("--vdebug requires a config JSON path")
			}
			i += 1
			result.options.run_requested = true
			result.options.config_path = args[i]
		} else if arg == "--vdebug-out" {
			if i + 1 >= len(args) {
				return cli_error("--vdebug-out requires a directory")
			}
			i += 1
			result.options.output_dir = args[i]
		} else if arg == "--vdebug-json" {
			if i + 1 >= len(args) {
				return cli_error("--vdebug-json requires a manifest path")
			}
			i += 1
			result.options.json_path = args[i]
		} else if arg == "--vdebug-html" {
			if i + 1 >= len(args) {
				return cli_error("--vdebug-html requires a gallery path")
			}
			i += 1
			result.options.html_path = args[i]
		} else if arg == "--vdebug-baselines" {
			if i + 1 >= len(args) {
				return cli_error("--vdebug-baselines requires a directory")
			}
			i += 1
			result.options.baseline_dir = args[i]
		} else if arg == "--vdebug-compare" {
			result.options.compare = true
			result.options.compare_specified = true
		} else if arg == "--vdebug-accept" {
			result.options.accept = true
		} else if arg == "--vdebug-shard" {
			if i + 1 >= len(args) {
				return cli_error("--vdebug-shard requires <index>/<count>")
			}
			i += 1
			shard_index, shard_count, ok := parse_shard(args[i])
			if !ok {
				return cli_error("--vdebug-shard requires <index>/<count> with index < count")
			}
			result.options.shard_enabled = true
			result.options.shard_index = shard_index
			result.options.shard_count = shard_count
		} else if arg == "--vdebug-merge" {
			if i + 2 >= len(args) {
				return cli_error(
					"--vdebug-merge requires an output manifest and at least one input manifest",
				)
			}
			i += 1
			result.options.merge_requested = true
			result.options.merge_out_path = args[i]
			for i + 1 < len(args) && !strings.has_prefix(args[i + 1], "--") {
				i += 1
				if result.options.merge_input_count >= VISUAL_DEBUG_MAX_MERGE_INPUTS {
					return cli_error("--vdebug-merge input capacity exceeded")
				}
				result.options.merge_inputs[result.options.merge_input_count] = args[i]
				result.options.merge_input_count += 1
			}
		} else if arg == "--vdebug-ffmpeg" {
			if i + 1 >= len(args) {
				return cli_error("--vdebug-ffmpeg requires off, auto, or an executable path")
			}
			i += 1
			mode := args[i]
			if mode == "" {
				return cli_error("--vdebug-ffmpeg value must not be empty")
			}
			result.options.ffmpeg_mode = mode
		} else if strings.has_prefix(arg, "--vdebug") {
			return cli_error(fmt.aprintf("unknown visual debug argument: %s", arg))
		}
	}

	entry_modes := 0
	if result.options.list_requested {
		entry_modes += 1
	}
	if result.options.run_requested {
		entry_modes += 1
	}
	if result.options.merge_requested {
		entry_modes += 1
	}
	if entry_modes > 1 {
		return cli_error("--vdebug-list, --vdebug, and --vdebug-merge are mutually exclusive")
	}

	has_output_only :=
		result.options.output_dir != "" ||
		result.options.json_path != "" ||
		result.options.html_path != "" ||
		result.options.baseline_dir != "" ||
		result.options.compare_specified ||
		result.options.accept ||
		result.options.shard_enabled ||
		result.options.ffmpeg_mode != "auto"
	if entry_modes == 0 && has_output_only {
		return cli_error(
			"visual debug output flags require --vdebug-list, --vdebug, or --vdebug-merge",
		)
	}
	if result.options.merge_requested && result.options.merge_input_count == 0 {
		return cli_error("--vdebug-merge requires at least one input manifest")
	}
	if result.options.accept && !result.options.run_requested {
		return cli_error("--vdebug-accept is valid only with --vdebug")
	}
	if result.options.shard_enabled && !result.options.run_requested {
		return cli_error("--vdebug-shard is valid only with --vdebug")
	}
	if result.options.output_dir != "" && !path_is_safe_relative(result.options.output_dir) {
		return cli_error("--vdebug-out must be a safe relative path")
	}
	if result.options.json_path != "" && !path_is_safe_relative(result.options.json_path) {
		return cli_error("--vdebug-json must be a safe relative path")
	}
	if result.options.html_path != "" && !path_is_safe_relative(result.options.html_path) {
		return cli_error("--vdebug-html must be a safe relative path")
	}
	if result.options.merge_out_path != "" &&
	   !path_is_safe_relative(result.options.merge_out_path) {
		return cli_error("--vdebug-merge output must be a safe relative path")
	}

	return result
}

cli_error :: proc(message: string) -> VisualDebugCLIParseResult {
	return {ok = false, error = message}
}

parse_shard :: proc(value: string) -> (index: u32, count: u32, ok: bool) {
	slash := strings.index(value, "/")
	if slash <= 0 || slash + 1 >= len(value) {
		return 0, 0, false
	}
	index_u64, index_ok := strconv.parse_uint(value[:slash])
	count_u64, count_ok := strconv.parse_uint(value[slash + 1:])
	if !index_ok || !count_ok || count_u64 == 0 || index_u64 >= count_u64 {
		return 0, 0, false
	}
	return u32(index_u64), u32(count_u64), true
}

run :: proc(registry: ^VisualDebugRegistry, options: VisualDebugRunnerOptions) -> bool {
	if registry == nil {
		fmt.eprintln("visual debug registry is nil")
		return false
	}
	if options.merge_requested {
		return merge_manifests(options)
	}
	if !registry.ok {
		fmt.eprintfln("%s", registry.error)
		return false
	}
	if options.list_requested {
		list(registry)
		return true
	}
	if !options.run_requested {
		return false
	}

	config_bytes, read_err := os.read_entire_file(options.config_path, registry.allocator)
	if read_err != nil {
		fmt.eprintfln("failed to read visual debug config %s: %v", options.config_path, read_err)
		return false
	}
	defer delete(config_bytes, registry.allocator)

	root, parse_err := json.parse(config_bytes, json.Specification.JSON, true, registry.allocator)
	if parse_err != .None {
		fmt.eprintfln("failed to parse visual debug config %s: %v", options.config_path, parse_err)
		return false
	}
	defer json.destroy_value(root, registry.allocator)

	root_obj, root_ok := json_value_object(root)
	if !root_ok {
		fmt.eprintln("visual debug config root must be an object")
		return false
	}
	schema := json_string_default(root_obj, "schema", "")
	if schema != VISUAL_DEBUG_CONFIG_SCHEMA {
		fmt.eprintfln("visual debug config schema must be %s", VISUAL_DEBUG_CONFIG_SCHEMA)
		return false
	}

	defaults := config_defaults_parse(root_obj)
	run_id := json_string_default(root_obj, "run_id", "")
	if run_id != "" && !identifier_is_safe(run_id) {
		fmt.eprintfln("visual debug run_id is not a safe identifier: %s", run_id)
		return false
	}
	if run_id == "" {
		run_id = run_id_generate(registry.allocator)
	}

	output_dir := options.output_dir
	if output_dir == "" {
		stem := config_stem_make(options.config_path)
		output_dir = fmt.aprintf(
			"vdebug/results/%s-%s",
			stem,
			run_id,
			allocator = registry.allocator,
		)
	}

	artifact_subdir := "artifacts"
	if output_value, output_ok := root_obj["output"]; output_ok {
		output_obj, ok := json_value_object(output_value)
		if !ok {
			fmt.eprintln("visual debug config output must be an object")
			return false
		}
		config_artifact_dir := json_string_default(output_obj, "artifact_dir", "")
		if config_artifact_dir != "" {
			if !path_is_safe_relative(config_artifact_dir) {
				fmt.eprintfln(
					"visual debug output.artifact_dir is unsafe: %s",
					config_artifact_dir,
				)
				return false
			}
			artifact_subdir = config_artifact_dir
		}
	}

	local_options := options
	local_options.output_dir = output_dir
	if local_options.json_path == "" {
		local_options.json_path = path_join2(output_dir, "manifest.json", registry.allocator)
	}
	if local_options.html_path == "" {
		local_options.html_path = path_join2(output_dir, "index.html", registry.allocator)
	}
	if local_options.artifact_dir == "" {
		local_options.artifact_dir = path_join2(output_dir, artifact_subdir, registry.allocator)
	}
	if local_options.baseline_dir == "" {
		default_baseline := "../testdata/vdebug/baselines"
		local_options.baseline_dir = default_baseline
	}

	if !prepare_output_file_create_only(local_options.json_path) ||
	   !prepare_output_file_create_only(local_options.html_path) {
		return false
	}
	if err := os.make_directory_all(local_options.artifact_dir);
	   err != nil && !os.is_directory(local_options.artifact_dir) {
		fmt.eprintfln(
			"failed to create visual debug artifact directory %s: %v",
			local_options.artifact_dir,
			err,
		)
		return false
	}

	captures_value, captures_ok := root_obj["captures"]
	if !captures_ok {
		fmt.eprintln("visual debug config missing captures array")
		return false
	}
	captures, captures_array_ok := json_value_array(captures_value)
	if !captures_array_ok || len(captures) == 0 {
		fmt.eprintln("visual debug config captures must be a non-empty array")
		return false
	}
	if len(captures) > VISUAL_DEBUG_MAX_CAPTURES {
		fmt.eprintfln("visual debug captures capacity exceeded: %d", len(captures))
		return false
	}
	if !validate_unique_request_ids(captures) {
		return false
	}
	for _, capture_index in captures {
		if local_options.shard_enabled &&
		   (u32(capture_index) % local_options.shard_count) != local_options.shard_index {
			continue
		}
		local_options.selected_capture_count += 1
	}

	ffmpeg := ffmpeg_discover(local_options.ffmpeg_mode, registry.allocator)
	suite := new(VisualDebugSuiteResult, registry.allocator)
	suite.schema = VISUAL_DEBUG_SCHEMA
	suite.run_id = run_id
	suite.config_path = local_options.config_path
	suite.config_hash = hash_bytes_hex(config_bytes, registry.allocator)
	suite.process_id = os.get_pid()
	suite.shard_index = local_options.shard_enabled ? i32(local_options.shard_index) : -1
	suite.shard_count = local_options.shard_enabled ? i32(local_options.shard_count) : -1
	suite.output_dir = local_options.output_dir
	suite.artifact_dir = local_options.artifact_dir
	suite.baseline_dir = local_options.baseline_dir
	build_writer := VisualDebugMetadataWriter{}
	metadata_reset(&build_writer, registry.allocator)
	if local_options.write_build_metadata != nil {
		local_options.write_build_metadata(&build_writer)
	}
	suite.build_count = build_writer.count
	for i := u32(0); i < build_writer.count; i += 1 {
		suite.build[i] = build_writer.entries[i]
	}

	accept_locked := false
	if local_options.accept {
		if !baseline_accept_lock(local_options.baseline_dir, registry.allocator) {
			return false
		}
		accept_locked = true
	}
	defer {
		if accept_locked {
			baseline_accept_unlock(local_options.baseline_dir, registry.allocator)
		}
	}

	all_passed := true
	for value, capture_index in captures {
		if local_options.shard_enabled &&
		   (u32(capture_index) % local_options.shard_count) != local_options.shard_index {
			continue
		}
		if suite.capture_count >= VISUAL_DEBUG_MAX_CAPTURES {
			fmt.eprintln("visual debug result capture capacity exceeded")
			all_passed = false
			break
		}
		request_obj, request_ok := json_value_object(value)
		if !request_ok {
			fmt.eprintfln("visual debug capture %d must be an object", capture_index)
			all_passed = false
			continue
		}
		capture_result := &suite.captures[suite.capture_count]
		run_capture_request(
			registry,
			&local_options,
			&ffmpeg,
			defaults,
			request_obj,
			u32(capture_index),
			suite,
			capture_result,
		)
		suite.capture_count += 1
		if capture_result.status == .Fail && capture_result.required {
			all_passed = false
		}
	}
	suite.ffmpeg = ffmpeg_manifest_record(&ffmpeg)

	if !write_json(local_options.json_path, suite) {
		all_passed = false
	}
	if !write_html(local_options.html_path, suite) {
		all_passed = false
	}

	return all_passed
}

run_capture_request :: proc(
	registry: ^VisualDebugRegistry,
	options: ^VisualDebugRunnerOptions,
	ffmpeg: ^FFmpegAdapter,
	defaults: VisualDebugConfigDefaults,
	request: json.Object,
	input_index: u32,
	suite: ^VisualDebugSuiteResult,
	result: ^VisualDebugCaptureResult,
) {
	request_id := json_string_default(request, "id", "")
	case_name := json_string_default(request, "case", "")
	version := json_string_default(request, "version", "")
	if version == "" {
		version = "1"
	}
	required := json_bool_default(request, "required", true)
	result.id = request_id
	result.input_index = input_index
	result.case_name = case_name
	result.version = version
	result.status = .Pass
	result.required = required

	if !identifier_is_safe(request_id) {
		result.status = .Fail
		result.error = "capture id must match [A-Za-z0-9_.-]+ and contain no path traversal"
		return
	}
	if !identifier_is_safe(case_name) {
		result.status = .Fail
		result.error = "capture case name is invalid"
		return
	}
	if !identifier_is_safe(version) {
		result.status = .Fail
		result.error = "capture version is invalid"
		return
	}
	case_ptr, case_ok := case_find(registry, case_name)
	if !case_ok {
		result.status = .Fail
		result.error = fmt.aprintf(
			"unknown visual debug case: %s",
			case_name,
			allocator = registry.allocator,
		)
		return
	}
	result.flags = case_ptr.options.flags
	if case_has_flag(case_ptr.options.flags, .Runtime_Owns_Main_Loop) &&
	   options.selected_capture_count != 1 {
		result.status = .Fail
		result.error = "runtime-owned visual debug cases must be selected alone"
		return
	}

	modes_value, modes_ok := request["modes"]
	modes: json.Array
	if modes_ok {
		modes_array, array_ok := json_value_array(modes_value)
		if !array_ok {
			result.status = .Fail
			result.error = "capture modes must be an array"
			return
		}
		modes = modes_array
	} else if !case_ptr.options.metadata_only {
		result.status = .Fail
		result.error = "capture modes must be non-empty"
		return
	}
	if !case_ptr.options.metadata_only && len(modes) == 0 {
		result.status = .Fail
		result.error = "capture modes must be non-empty"
		return
	}
	if len(modes) > VISUAL_DEBUG_MAX_MODES {
		result.status = .Fail
		result.error = "capture mode capacity exceeded"
		return
	}
	if !validate_modes_common(modes, result) {
		return
	}

	data: rawptr
	if case_ptr.options.data_size > 0 {
		align := case_ptr.options.data_align
		if align <= 0 {
			align = mem.DEFAULT_ALIGNMENT
		}
		storage, alloc_err := mem.alloc(case_ptr.options.data_size, align, registry.allocator)
		if alloc_err != nil || storage == nil {
			result.status = .Fail
			result.error = "failed to allocate visual debug fixture storage"
			return
		}
		mem.zero(storage, case_ptr.options.data_size)
		data = storage
		defer {
			if case_ptr.options.destroy != nil {
				case_ptr.options.destroy(data, registry.allocator)
			}
			_ = mem.free(data, registry.allocator)
		}
	}

	config_ctx := VisualDebugConfigContext {
		request_id = request_id,
		case_name  = case_name,
		version    = version,
		defaults   = defaults,
		allocator  = registry.allocator,
	}
	config_status := case_ptr.configure(&config_ctx, request, data)
	if config_status.kind != .Pass {
		result.status = config_status.kind
		result.error = config_status.message
		return
	}

	fixture_ctx := VisualDebugContext {
		request_id     = request_id,
		case_name      = case_name,
		output_dir     = options.output_dir,
		artifact_dir   = options.artifact_dir,
		baseline_dir   = options.baseline_dir,
		allocator      = registry.allocator,
		manifest_entry = result,
		ffmpeg         = ffmpeg,
	}
	fixture_writer := VisualDebugMetadataWriter{}
	metadata_reset(&fixture_writer, registry.allocator)
	if case_ptr.options.write_fixture != nil {
		fixture_status := case_ptr.options.write_fixture(&fixture_ctx, data, &fixture_writer)
		if fixture_status.kind != .Pass {
			result.status = fixture_status.kind
			result.error = fixture_status.message
			return
		}
	}
	result.fixture_count = fixture_writer.count
	for i := u32(0); i < fixture_writer.count; i += 1 {
		result.fixture[i] = fixture_writer.entries[i]
	}

	for mode_value, mode_index in modes {
		mode_obj, mode_ok := json_value_object(mode_value)
		if !mode_ok {
			continue
		}
		mode_id := json_string_default(mode_obj, "id", "")
		mode_kind := json_string_default(mode_obj, "kind", "")
		mode_result_ptr := &result.modes[result.mode_count]
		mode_result_ptr.id = mode_id
		mode_result_ptr.kind = mode_kind
		mode_result_ptr.status = .Pass
		mode_result_ptr.required = json_bool_default(mode_obj, "required", result.required)
		mode_result_ptr.width = u32(json_i64_default(mode_obj, "width", 0))
		mode_result_ptr.height = u32(json_i64_default(mode_obj, "height", 0))
		mode_result_ptr.palette = "terrain_debug.v1"
		result.mode_count += 1

		ctx := VisualDebugContext {
			request_id     = request_id,
			case_name      = case_name,
			mode_id        = mode_id,
			mode_kind      = mode_kind,
			output_dir     = options.output_dir,
			artifact_dir   = options.artifact_dir,
			baseline_dir   = options.baseline_dir,
			allocator      = registry.allocator,
			manifest_entry = result,
			mode_result    = mode_result_ptr,
			ffmpeg         = ffmpeg,
		}
		status := case_ptr.run(&ctx, data, mode_obj)
		if status.kind != .Pass {
			mode_result_ptr.status = status.kind
			mode_result_ptr.error = status.message
		}
		if mode_result_ptr.status == .Pass &&
		   mode_result_ptr.artifact_count == 0 &&
		   case_has_flag(case_ptr.options.flags, .Emits_Artifacts) {
			mode_result_ptr.status = .Fail
			mode_result_ptr.error = "capture mode emitted no artifacts"
		}
		if mode_result_ptr.hash == "" {
			for artifact_index := u32(0);
			    artifact_index < mode_result_ptr.artifact_count;
			    artifact_index += 1 {
				artifact := mode_result_ptr.artifacts[artifact_index]
				if artifact.kind == "image" && artifact.hash != "" {
					mode_result_ptr.hash = artifact.hash
					break
				}
			}
		}
		snapshot := snapshot_options_parse(
			request,
			mode_obj,
			defaults,
			options^,
			mode_result_ptr.required,
		)
		if snapshot.active && mode_result_ptr.status == .Pass {
			mode_result_ptr.comparison_active = true
			mode_result_ptr.comparison.tolerance = snapshot.tolerance
			mode_result_ptr.comparison.platform_key = snapshot.platform_key
			mode_result_ptr.comparison.baseline_path = baseline_image_path(
				options.baseline_dir,
				snapshot.baseline_id,
				snapshot.platform_key,
				mode_id,
				registry.allocator,
			)
			mode_result_ptr.comparison.baseline_sidecar = baseline_sidecar_path(
				options.baseline_dir,
				snapshot.baseline_id,
				snapshot.platform_key,
				mode_id,
				registry.allocator,
			)
			if options.accept {
				accept_mode_baseline(
					options,
					&ctx,
					suite,
					snapshot.baseline_id,
					snapshot.platform_key,
					case_name,
					version,
				)
			} else if snapshot.compare {
				compare_mode_against_baseline(&ctx, snapshot.required)
			}
		}

		_ = mode_index
	}

	capture_status_recompute(result)
	return
}

VisualDebugSnapshotRunOptions :: struct {
	active:       bool,
	compare:      bool,
	required:     bool,
	baseline_id:  string,
	platform_key: string,
	tolerance:    VisualDebugTolerance,
}

snapshot_options_parse :: proc(
	request: json.Object,
	mode: json.Object,
	defaults: VisualDebugConfigDefaults,
	options: VisualDebugRunnerOptions,
	mode_required: bool,
) -> VisualDebugSnapshotRunOptions {
	snapshot_value, request_has_snapshot := request["snapshot"]
	mode_snapshot_value, mode_has_snapshot := mode["snapshot"]
	if mode_has_snapshot {
		if disabled, ok := json_value_bool(mode_snapshot_value); ok && !disabled {
			return {}
		}
		snapshot_value = mode_snapshot_value
		request_has_snapshot = true
	}
	if !request_has_snapshot {
		return {}
	}
	if disabled, ok := json_value_bool(snapshot_value); ok && !disabled {
		return {}
	}
	snapshot_obj, ok := json_value_object(snapshot_value)
	if !ok {
		return {}
	}
	baseline_id := json_string_default(
		snapshot_obj,
		"baseline",
		json_string_default(request, "id", ""),
	)
	if !identifier_is_safe(baseline_id) {
		return {}
	}
	compare := true
	if defaults.compare_specified {
		compare = defaults.compare
	}
	if options.compare_specified {
		compare = options.compare
	}
	if request_compare, ok := json_bool_get(request, "compare"); ok {
		compare = request_compare
	}
	required := json_bool_default(snapshot_obj, "required", mode_required)
	return {
		active = true,
		compare = compare || options.accept,
		required = required,
		baseline_id = baseline_id,
		platform_key = "cpu",
		tolerance = tolerance_parse(snapshot_obj),
	}
}

tolerance_parse :: proc(snapshot_obj: json.Object) -> VisualDebugTolerance {
	tolerance := VisualDebugTolerance {
		mode = .Exact,
	}
	tolerance_value, ok := snapshot_obj["tolerance"]
	if !ok {
		return tolerance
	}
	tolerance_obj, obj_ok := json_value_object(tolerance_value)
	if !obj_ok {
		return tolerance
	}
	mode := json_string_default(tolerance_obj, "mode", "exact")
	switch mode {
	case "pixel_threshold":
		tolerance.mode = .Pixel_Threshold
	case "metric_threshold":
		tolerance.mode = .Metric_Threshold
	case "masked":
		tolerance.mode = .Masked
	case:
		tolerance.mode = .Exact
	}
	if v, v_ok := json_i64_get(tolerance_obj, "max_channel_delta"); v_ok {
		tolerance.max_channel_delta = u32(v)
		tolerance.has_max_delta = true
	}
	if v, v_ok := json_f64_get(tolerance_obj, "mean_abs_error"); v_ok {
		tolerance.mean_abs_error = v
		tolerance.has_mean_abs_error = true
	}
	if v, v_ok := json_f64_get(tolerance_obj, "rms_error"); v_ok {
		tolerance.rms_error = v
		tolerance.has_rms_error = true
	}
	if v, v_ok := json_f64_get(tolerance_obj, "changed_pixel_ratio"); v_ok {
		tolerance.changed_pixel_ratio = v
		tolerance.has_changed_ratio = true
	}
	if v, v_ok := json_f64_get(tolerance_obj, "psnr_min"); v_ok {
		tolerance.psnr_min = v
		tolerance.has_psnr_min = true
	}
	return tolerance
}

validate_unique_request_ids :: proc(captures: json.Array) -> bool {
	for value, i in captures {
		obj, ok := json_value_object(value)
		if !ok {
			fmt.eprintfln("visual debug capture %d must be an object", i)
			return false
		}
		id := json_string_default(obj, "id", "")
		if !identifier_is_safe(id) {
			fmt.eprintfln("visual debug capture %d has invalid id: %s", i, id)
			return false
		}
		for other_value, j in captures {
			if j >= i {
				break
			}
			other_obj, other_ok := json_value_object(other_value)
			if !other_ok {
				continue
			}
			if json_string_default(other_obj, "id", "") == id {
				fmt.eprintfln("visual debug duplicate capture id: %s", id)
				return false
			}
		}
	}
	return true
}

validate_modes_common :: proc(modes: json.Array, result: ^VisualDebugCaptureResult) -> bool {
	for value, i in modes {
		obj, ok := json_value_object(value)
		if !ok {
			result.status = .Fail
			result.error = fmt.aprintf("mode %d must be an object", i)
			return false
		}
		id := json_string_default(obj, "id", "")
		kind := json_string_default(obj, "kind", "")
		if !identifier_is_safe(id) {
			result.status = .Fail
			result.error = fmt.aprintf("mode %d has invalid id", i)
			return false
		}
		if !identifier_is_safe(kind) {
			result.status = .Fail
			result.error = fmt.aprintf("mode %s has invalid kind", id)
			return false
		}
		if width, width_ok := json_i64_get(obj, "width"); width_ok {
			if width <= 0 || width > VISUAL_DEBUG_MAX_IMAGE_DIMENSION {
				result.status = .Fail
				result.error = fmt.aprintf("mode %s width is out of bounds", id)
				return false
			}
		}
		if height, height_ok := json_i64_get(obj, "height"); height_ok {
			if height <= 0 || height > VISUAL_DEBUG_MAX_IMAGE_DIMENSION {
				result.status = .Fail
				result.error = fmt.aprintf("mode %s height is out of bounds", id)
				return false
			}
		}
		if frames, frames_ok := json_i64_get(obj, "frames"); frames_ok {
			if frames <= 0 || frames > VISUAL_DEBUG_MAX_FRAME_COUNT {
				result.status = .Fail
				result.error = fmt.aprintf("mode %s frame count is out of bounds", id)
				return false
			}
		}
		for other_value, j in modes {
			if j >= i {
				break
			}
			other_obj, other_ok := json_value_object(other_value)
			if other_ok && json_string_default(other_obj, "id", "") == id {
				result.status = .Fail
				result.error = fmt.aprintf("duplicate mode id: %s", id)
				return false
			}
		}
	}
	return true
}

config_defaults_parse :: proc(root: json.Object) -> VisualDebugConfigDefaults {
	defaults := VisualDebugConfigDefaults {
		seed         = 0,
		quality      = "Full",
		image_format = "bmp",
		compare      = true,
	}
	defaults_value, ok := root["defaults"]
	if !ok {
		return defaults
	}
	defaults_obj, obj_ok := json_value_object(defaults_value)
	if !obj_ok {
		return defaults
	}
	defaults.seed = u32(json_i64_default(defaults_obj, "seed", i64(defaults.seed)))
	defaults.quality = json_string_default(defaults_obj, "quality", defaults.quality)
	defaults.image_format = json_string_default(
		defaults_obj,
		"image_format",
		defaults.image_format,
	)
	if compare, compare_ok := json_bool_get(defaults_obj, "compare"); compare_ok {
		defaults.compare = compare
		defaults.compare_specified = true
	}
	return defaults
}

run_id_generate :: proc(allocator: mem.Allocator) -> string {
	now := time.now()
	return fmt.aprintf("%d-%d", time.time_to_unix_nano(now), os.get_pid(), allocator = allocator)
}

config_stem_make :: proc(path: string) -> string {
	base := os.base(path)
	stem := os.stem(base)
	if stem == "" {
		return "config"
	}
	builder, alloc_err := strings.builder_make(allocator = context.temp_allocator)
	if alloc_err != nil {
		return "config"
	}
	defer strings.builder_destroy(&builder)
	for i := 0; i < len(stem); i += 1 {
		c := stem[i]
		if (c >= 'a' && c <= 'z') ||
		   (c >= 'A' && c <= 'Z') ||
		   (c >= '0' && c <= '9') ||
		   c == '_' ||
		   c == '-' ||
		   c == '.' {
			strings.write_byte(&builder, c)
		} else {
			strings.write_byte(&builder, '-')
		}
	}
	out := strings.to_string(builder)
	if out == "" {
		return "config"
	}
	return out
}

json_value_object :: proc(value: json.Value) -> (json.Object, bool) {
	#partial switch v in value {
	case json.Object:
		return v, true
	}
	return nil, false
}

json_value_array :: proc(value: json.Value) -> (json.Array, bool) {
	#partial switch v in value {
	case json.Array:
		return v, true
	}
	return nil, false
}

json_value_string :: proc(value: json.Value) -> (string, bool) {
	#partial switch v in value {
	case json.String:
		return string(v), true
	}
	return "", false
}

json_value_bool :: proc(value: json.Value) -> (bool, bool) {
	#partial switch v in value {
	case json.Boolean:
		return bool(v), true
	}
	return false, false
}

json_value_i64 :: proc(value: json.Value) -> (i64, bool) {
	#partial switch v in value {
	case json.Integer:
		return i64(v), true
	case json.Float:
		return i64(v), true
	}
	return 0, false
}

json_value_f64 :: proc(value: json.Value) -> (f64, bool) {
	#partial switch v in value {
	case json.Integer:
		return f64(v), true
	case json.Float:
		return f64(v), true
	}
	return 0, false
}

json_string_get :: proc(obj: json.Object, key: string) -> (string, bool) {
	if value, ok := obj[key]; ok {
		return json_value_string(value)
	}
	return "", false
}

json_string_default :: proc(obj: json.Object, key: string, default: string) -> string {
	if value, ok := json_string_get(obj, key); ok {
		return value
	}
	return default
}

json_bool_get :: proc(obj: json.Object, key: string) -> (bool, bool) {
	if value, ok := obj[key]; ok {
		return json_value_bool(value)
	}
	return false, false
}

json_bool_default :: proc(obj: json.Object, key: string, default: bool) -> bool {
	if value, ok := json_bool_get(obj, key); ok {
		return value
	}
	return default
}

json_i64_get :: proc(obj: json.Object, key: string) -> (i64, bool) {
	if value, ok := obj[key]; ok {
		return json_value_i64(value)
	}
	return 0, false
}

json_i64_default :: proc(obj: json.Object, key: string, default: i64) -> i64 {
	if value, ok := json_i64_get(obj, key); ok {
		return value
	}
	return default
}

json_f64_get :: proc(obj: json.Object, key: string) -> (f64, bool) {
	if value, ok := obj[key]; ok {
		return json_value_f64(value)
	}
	return 0, false
}

json_f64_default :: proc(obj: json.Object, key: string, default: f64) -> f64 {
	if value, ok := json_f64_get(obj, key); ok {
		return value
	}
	return default
}
