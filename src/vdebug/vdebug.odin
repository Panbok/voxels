package vdebug

import json "core:encoding/json"
import "core:fmt"
import "core:mem"
import "core:os"
import "core:strings"

VISUAL_DEBUG_SCHEMA :: "voxels.visual_debug.v1"
VISUAL_DEBUG_CONFIG_SCHEMA :: "voxels.visual_debug.config.v1"
VISUAL_DEBUG_BASELINE_SCHEMA :: "voxels.visual_debug.baseline.v1"
VISUAL_DEBUG_MAX_CASES :: 96
VISUAL_DEBUG_MAX_CAPTURES :: 256
VISUAL_DEBUG_MAX_MODES :: 16
VISUAL_DEBUG_MAX_ARTIFACTS_PER_MODE :: 32
VISUAL_DEBUG_MAX_DIFF_ARTIFACTS :: 8
VISUAL_DEBUG_MAX_METADATA :: 128
VISUAL_DEBUG_MAX_MERGE_INPUTS :: 64
VISUAL_DEBUG_MAX_IMAGE_DIMENSION :: 4096
VISUAL_DEBUG_MAX_FRAME_COUNT :: 512

PixelRGBA8 :: struct {
	r, g, b, a: u8,
}

VisualDebugStatusKind :: enum {
	Pass,
	Fail,
	Skip,
}

VisualDebugStatus :: struct {
	kind:    VisualDebugStatusKind,
	message: string,
}

VisualDebugCaseFlag :: enum {
	Serial_Only,
	Parallel_Safe,
	Uses_Shared_Caches,
	Mutates_Global_State,
	Requires_Gfx,
	Runtime_Owns_Main_Loop,
	Emits_Artifacts,
	Snapshot_Comparable,
	FFMPEG_Optional,
	FFMPEG_Required,
}

VisualDebugCaseFlags :: bit_set[VisualDebugCaseFlag;u32]

VisualDebugMetadataValueKind :: enum {
	U64,
	I64,
	F64,
	Bool,
	String,
}

VisualDebugMetadataValue :: struct {
	name:         string,
	kind:         VisualDebugMetadataValueKind,
	u64_value:    u64,
	i64_value:    i64,
	f64_value:    f64,
	bool_value:   bool,
	string_value: string,
	unit:         string,
}

VisualDebugMetadataWriter :: struct {
	allocator: mem.Allocator,
	entries:   [VISUAL_DEBUG_MAX_METADATA]VisualDebugMetadataValue,
	count:     u32,
}

VisualDebugArtifactRecord :: struct {
	label:        string,
	kind:         string,
	path:         string,
	content_type: string,
	byte_size:    u64,
	width:        u32,
	height:       u32,
	pixel_format: string,
	color_space:  string,
	orientation:  string,
	palette:      string,
	encoder:      string,
	hash:         string,
}

VisualDebugComparisonMetrics :: struct {
	changed_pixels:      u64,
	changed_pixel_ratio: f64,
	max_channel_delta:   u32,
	mean_abs_error:      f64,
	rms_error:           f64,
	psnr:                f64,
	psnr_infinite:       bool,
}

VisualDebugToleranceMode :: enum {
	Exact,
	Pixel_Threshold,
	Metric_Threshold,
	Masked,
}

VisualDebugTolerance :: struct {
	mode:                VisualDebugToleranceMode,
	max_channel_delta:   u32,
	mean_abs_error:      f64,
	rms_error:           f64,
	changed_pixel_ratio: f64,
	psnr_min:            f64,
	has_max_delta:       bool,
	has_mean_abs_error:  bool,
	has_rms_error:       bool,
	has_changed_ratio:   bool,
	has_psnr_min:        bool,
}

VisualDebugComparisonResult :: struct {
	status:              string,
	error:               string,
	baseline_path:       string,
	baseline_sidecar:    string,
	platform_key:        string,
	tolerance:           VisualDebugTolerance,
	metrics:             VisualDebugComparisonMetrics,
	diff_artifacts:      [VISUAL_DEBUG_MAX_DIFF_ARTIFACTS]VisualDebugArtifactRecord,
	diff_artifact_count: u32,
	old_hash:            string,
	accepted:            bool,
}

VisualDebugModeResult :: struct {
	id:                string,
	kind:              string,
	status:            VisualDebugStatusKind,
	error:             string,
	required:          bool,
	width:             u32,
	height:            u32,
	palette:           string,
	hash:              string,
	artifacts:         [VISUAL_DEBUG_MAX_ARTIFACTS_PER_MODE]VisualDebugArtifactRecord,
	artifact_count:    u32,
	comparison:        VisualDebugComparisonResult,
	comparison_active: bool,
}

VisualDebugCaptureResult :: struct {
	id:            string,
	input_index:   u32,
	case_name:     string,
	version:       string,
	status:        VisualDebugStatusKind,
	error:         string,
	flags:         VisualDebugCaseFlags,
	required:      bool,
	fixture:       [VISUAL_DEBUG_MAX_METADATA]VisualDebugMetadataValue,
	fixture_count: u32,
	modes:         [VISUAL_DEBUG_MAX_MODES]VisualDebugModeResult,
	mode_count:    u32,
}

VisualDebugFFmpegRunRecord :: struct {
	status:      string,
	path:        string,
	version:     string,
	command:     string,
	exit_code:   int,
	stderr_tail: string,
	output_path: string,
	output_hash: string,
}

VisualDebugSuiteResult :: struct {
	schema:           string,
	run_id:           string,
	config_path:      string,
	config_hash:      string,
	process_id:       int,
	shard_index:      i32,
	shard_count:      i32,
	output_dir:       string,
	artifact_dir:     string,
	baseline_dir:     string,
	build:            [VISUAL_DEBUG_MAX_METADATA]VisualDebugMetadataValue,
	build_count:      u32,
	ffmpeg:           VisualDebugFFmpegRunRecord,
	captures:         [VISUAL_DEBUG_MAX_CAPTURES]VisualDebugCaptureResult,
	capture_count:    u32,
	accept_created:   u32,
	accept_replaced:  u32,
	accept_unchanged: u32,
	accept_skipped:   u32,
}

VisualDebugConfigDefaults :: struct {
	seed:              u32,
	quality:           string,
	image_format:      string,
	compare:           bool,
	compare_specified: bool,
}

VisualDebugConfigContext :: struct {
	request_id: string,
	case_name:  string,
	version:    string,
	defaults:   VisualDebugConfigDefaults,
	allocator:  mem.Allocator,
	temp_arena: ^mem.Arena,
}

FFmpegAdapter :: struct {
	mode:             string,
	path:             string,
	available:        bool,
	version:          string,
	error:            string,
	last_command:     string,
	last_exit_code:   int,
	last_output_path: string,
	last_output_hash: string,
}

VisualDebugContext :: struct {
	request_id:     string,
	case_name:      string,
	mode_id:        string,
	mode_kind:      string,
	output_dir:     string,
	artifact_dir:   string,
	baseline_dir:   string,
	allocator:      mem.Allocator,
	temp_arena:     ^mem.Arena,
	manifest_entry: ^VisualDebugCaptureResult,
	mode_result:    ^VisualDebugModeResult,
	ffmpeg:         ^FFmpegAdapter,
}

VisualDebugConfigureProc :: #type proc(
	ctx: ^VisualDebugConfigContext,
	request: json.Object,
	data: rawptr,
) -> VisualDebugStatus

VisualDebugRunProc :: #type proc(
	ctx: ^VisualDebugContext,
	data: rawptr,
	mode: json.Object,
) -> VisualDebugStatus

VisualDebugMetadataProc :: #type proc(
	ctx: ^VisualDebugContext,
	data: rawptr,
	writer: ^VisualDebugMetadataWriter,
) -> VisualDebugStatus

VisualDebugDestroyProc :: #type proc(data: rawptr, allocator: mem.Allocator)
VisualDebugBuildMetadataProc :: #type proc(writer: ^VisualDebugMetadataWriter)

VisualDebugCaseOptions :: struct {
	data_size:      int,
	data_align:     int,
	flags:          VisualDebugCaseFlags,
	category:       string,
	version:        string,
	write_fixture:  VisualDebugMetadataProc,
	destroy:        VisualDebugDestroyProc,
	metadata_only:  bool,
	default_in_all: bool,
}

VisualDebugCase :: struct {
	name:      string,
	configure: VisualDebugConfigureProc,
	run:       VisualDebugRunProc,
	options:   VisualDebugCaseOptions,
}

VisualDebugRegistry :: struct {
	allocator: mem.Allocator,
	cases:     [VISUAL_DEBUG_MAX_CASES]VisualDebugCase,
	count:     u32,
	ok:        bool,
	error:     string,
}

VisualDebugRunnerOptions :: struct {
	list_requested:         bool,
	run_requested:          bool,
	merge_requested:        bool,
	config_path:            string,
	output_dir:             string,
	json_path:              string,
	html_path:              string,
	artifact_dir:           string,
	baseline_dir:           string,
	compare:                bool,
	compare_specified:      bool,
	accept:                 bool,
	shard_enabled:          bool,
	shard_index:            u32,
	shard_count:            u32,
	ffmpeg_mode:            string,
	merge_out_path:         string,
	merge_inputs:           [VISUAL_DEBUG_MAX_MERGE_INPUTS]string,
	merge_input_count:      u32,
	write_build_metadata:   VisualDebugBuildMetadataProc,
	selected_capture_count: u32,
}

VisualDebugCLIParseResult :: struct {
	options: VisualDebugRunnerOptions,
	ok:      bool,
	error:   string,
}

status_pass :: proc() -> VisualDebugStatus {
	return {kind = .Pass}
}

status_fail :: proc(message: string) -> VisualDebugStatus {
	return {kind = .Fail, message = message}
}

status_skip :: proc(message: string) -> VisualDebugStatus {
	return {kind = .Skip, message = message}
}

registry_init :: proc(registry: ^VisualDebugRegistry, allocator: mem.Allocator) {
	registry^ = {
		allocator = allocator,
		ok        = true,
	}
}

case_has_flag :: proc(flags: VisualDebugCaseFlags, flag: VisualDebugCaseFlag) -> bool {
	return flag in flags
}

register :: proc(
	registry: ^VisualDebugRegistry,
	name: string,
	configure: VisualDebugConfigureProc,
	run: VisualDebugRunProc,
	options: VisualDebugCaseOptions,
) {
	if registry == nil || !registry.ok {
		return
	}
	if !identifier_is_safe(name) {
		registry.ok = false
		registry.error = "visual debug registration failed: invalid case name"
		return
	}
	if configure == nil || run == nil {
		registry.ok = false
		registry.error = fmt.aprintf(
			"visual debug registration failed for %s: configure/run proc is nil",
			name,
			allocator = registry.allocator,
		)
		return
	}
	for i := u32(0); i < registry.count; i += 1 {
		if registry.cases[i].name == name {
			registry.ok = false
			registry.error = fmt.aprintf(
				"visual debug registration failed: duplicate case %s",
				name,
				allocator = registry.allocator,
			)
			return
		}
	}
	if registry.count >= VISUAL_DEBUG_MAX_CASES {
		registry.ok = false
		registry.error = "visual debug registration failed: registry capacity exceeded"
		return
	}

	case_options := options
	if case_options.version == "" {
		case_options.version = "1"
	}
	if case_has_flag(case_options.flags, .Serial_Only) &&
	   case_has_flag(case_options.flags, .Parallel_Safe) {
		registry.ok = false
		registry.error = fmt.aprintf(
			"visual debug registration failed for %s: Serial_Only and Parallel_Safe are exclusive",
			name,
			allocator = registry.allocator,
		)
		return
	}
	if case_has_flag(case_options.flags, .Runtime_Owns_Main_Loop) &&
	   !case_has_flag(case_options.flags, .Serial_Only) {
		registry.ok = false
		registry.error = fmt.aprintf(
			"visual debug registration failed for %s: Runtime_Owns_Main_Loop requires Serial_Only",
			name,
			allocator = registry.allocator,
		)
		return
	}

	registry.cases[registry.count] = {
		name      = name,
		configure = configure,
		run       = run,
		options   = case_options,
	}
	registry.count += 1
}

case_find :: proc(registry: ^VisualDebugRegistry, name: string) -> (^VisualDebugCase, bool) {
	if registry == nil {
		return nil, false
	}
	for i := u32(0); i < registry.count; i += 1 {
		if registry.cases[i].name == name {
			return &registry.cases[i], true
		}
	}
	return nil, false
}

list :: proc(registry: ^VisualDebugRegistry) {
	if registry == nil {
		return
	}
	for i := u32(0); i < registry.count; i += 1 {
		fmt.println(registry.cases[i].name)
	}
}

metadata_reset :: proc(writer: ^VisualDebugMetadataWriter, allocator: mem.Allocator) {
	writer^ = {
		allocator = allocator,
	}
}

metadata_add :: proc(writer: ^VisualDebugMetadataWriter, value: VisualDebugMetadataValue) {
	if writer == nil || writer.count >= VISUAL_DEBUG_MAX_METADATA {
		return
	}
	writer.entries[writer.count] = value
	writer.count += 1
}

metadata_u64 :: proc(
	writer: ^VisualDebugMetadataWriter,
	name: string,
	value: u64,
	unit: string = "",
) {
	metadata_add(writer, {name = name, kind = .U64, u64_value = value, unit = unit})
}

metadata_i64 :: proc(
	writer: ^VisualDebugMetadataWriter,
	name: string,
	value: i64,
	unit: string = "",
) {
	metadata_add(writer, {name = name, kind = .I64, i64_value = value, unit = unit})
}

metadata_f64 :: proc(
	writer: ^VisualDebugMetadataWriter,
	name: string,
	value: f64,
	unit: string = "",
) {
	metadata_add(writer, {name = name, kind = .F64, f64_value = value, unit = unit})
}

metadata_bool :: proc(writer: ^VisualDebugMetadataWriter, name: string, value: bool) {
	metadata_add(writer, {name = name, kind = .Bool, bool_value = value})
}

metadata_string :: proc(writer: ^VisualDebugMetadataWriter, name: string, value: string) {
	metadata_add(writer, {name = name, kind = .String, string_value = value})
}

artifact_record_add :: proc(
	ctx: ^VisualDebugContext,
	artifact: VisualDebugArtifactRecord,
) -> bool {
	if ctx == nil || ctx.mode_result == nil {
		return false
	}
	if ctx.mode_result.artifact_count >= VISUAL_DEBUG_MAX_ARTIFACTS_PER_MODE {
		ctx.mode_result.status = .Fail
		ctx.mode_result.error = "visual debug mode artifact capacity exceeded"
		return false
	}
	ctx.mode_result.artifacts[ctx.mode_result.artifact_count] = artifact
	ctx.mode_result.artifact_count += 1
	return true
}

diff_artifact_record_add :: proc(
	comparison: ^VisualDebugComparisonResult,
	artifact: VisualDebugArtifactRecord,
) -> bool {
	if comparison == nil || comparison.diff_artifact_count >= VISUAL_DEBUG_MAX_DIFF_ARTIFACTS {
		return false
	}
	comparison.diff_artifacts[comparison.diff_artifact_count] = artifact
	comparison.diff_artifact_count += 1
	return true
}

status_string :: proc(status: VisualDebugStatusKind) -> string {
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

flag_string :: proc(flag: VisualDebugCaseFlag) -> string {
	switch flag {
	case .Serial_Only:
		return "Serial_Only"
	case .Parallel_Safe:
		return "Parallel_Safe"
	case .Uses_Shared_Caches:
		return "Uses_Shared_Caches"
	case .Mutates_Global_State:
		return "Mutates_Global_State"
	case .Requires_Gfx:
		return "Requires_Gfx"
	case .Runtime_Owns_Main_Loop:
		return "Runtime_Owns_Main_Loop"
	case .Emits_Artifacts:
		return "Emits_Artifacts"
	case .Snapshot_Comparable:
		return "Snapshot_Comparable"
	case .FFMPEG_Optional:
		return "FFMPEG_Optional"
	case .FFMPEG_Required:
		return "FFMPEG_Required"
	}
	return "Unknown"
}

identifier_is_safe :: proc(value: string) -> bool {
	if value == "" || strings.trim_space(value) != value {
		return false
	}
	for i := 0; i < len(value); i += 1 {
		c := value[i]
		if (c >= 'a' && c <= 'z') ||
		   (c >= 'A' && c <= 'Z') ||
		   (c >= '0' && c <= '9') ||
		   c == '_' ||
		   c == '-' ||
		   c == '.' {
			continue
		}
		return false
	}
	if strings.contains(value, "..") {
		return false
	}
	return true
}

path_is_safe_relative :: proc(path: string) -> bool {
	if path == "" || os.is_absolute_path(path) {
		return false
	}
	cleaned, err := os.clean_path(path, context.temp_allocator)
	if err != nil {
		return false
	}
	if cleaned == "." || strings.has_prefix(cleaned, "..") {
		return false
	}
	remaining := cleaned
	for {
		part, ok := strings.split_iterator(&remaining, os.Path_Separator_String)
		if !ok {
			break
		}
		if part == ".." || part == "" {
			return false
		}
	}
	return true
}

path_join2 :: proc(a, b: string, allocator: mem.Allocator) -> string {
	if a == "" || a == "." {
		return strings.clone(b, allocator)
	}
	sep := os.Path_Separator_String
	if strings.has_suffix(a, "/") || strings.has_suffix(a, "\\") {
		sep = ""
	}
	return fmt.aprintf("%s%s%s", a, sep, b, allocator = allocator)
}

path_join3 :: proc(a, b, c: string, allocator: mem.Allocator) -> string {
	return path_join2(path_join2(a, b, allocator), c, allocator)
}

prepare_output_file_create_only :: proc(path: string) -> bool {
	if path == "" {
		fmt.eprintln("visual debug output path must not be empty")
		return false
	}
	if os.exists(path) {
		fmt.eprintfln("visual debug output path already exists: %s", path)
		return false
	}
	dir := os.dir(path)
	if dir != "." && dir != "" {
		err := os.make_directory_all(dir)
		if err != nil && !os.is_directory(dir) {
			fmt.eprintfln("failed to create visual debug output directory %s: %v", dir, err)
			return false
		}
	}
	return true
}

capture_status_recompute :: proc(capture: ^VisualDebugCaptureResult) {
	if capture == nil {
		return
	}
	any_fail := false
	any_pass := false
	first_error := ""
	for i := u32(0); i < capture.mode_count; i += 1 {
		mode := &capture.modes[i]
		if mode.status == .Fail && mode.required {
			any_fail = true
			if first_error == "" {
				first_error = mode.error
			}
		}
		if mode.status == .Pass {
			any_pass = true
		}
		if mode.comparison_active &&
		   (mode.comparison.status == "fail" || mode.comparison.status == "missing_baseline") &&
		   mode.required {
			any_fail = true
			if first_error == "" {
				first_error = mode.comparison.error
			}
		}
	}
	if any_fail {
		capture.status = .Fail
		if capture.error == "" {
			if first_error != "" {
				capture.error = first_error
			} else {
				capture.error = "capture contains a failing required mode"
			}
		}
	} else if any_pass {
		capture.status = .Pass
	} else {
		capture.status = .Skip
	}
}
