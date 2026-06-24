package vdebug

import json "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strings"

merge_manifests :: proc(options: VisualDebugRunnerOptions) -> bool {
	if !prepare_output_file_create_only(options.merge_out_path) {
		return false
	}
	html_path := options.html_path
	if html_path == "" {
		dir := os.dir(options.merge_out_path)
		stem := os.stem(os.base(options.merge_out_path))
		html_path = path_join2(
			dir,
			fmt.aprintf("%s.html", stem, allocator = context.allocator),
			context.allocator,
		)
	}
	if !prepare_output_file_create_only(html_path) {
		return false
	}

	suite := new(VisualDebugSuiteResult)
	suite.schema = VISUAL_DEBUG_SCHEMA
	suite.run_id = fmt.aprintf("merge-%d", os.get_pid())
	suite.config_path = "merged"
	suite.process_id = os.get_pid()
	suite.shard_index = -1
	suite.shard_count = -1
	for i := u32(0); i < options.merge_input_count; i += 1 {
		if !merge_manifest_read(options.merge_inputs[i], suite) {
			return false
		}
	}
	if !write_json(options.merge_out_path, suite) {
		return false
	}
	if !write_html(html_path, suite) {
		return false
	}
	return true
}

merge_manifest_read :: proc(path: string, suite: ^VisualDebugSuiteResult) -> bool {
	bytes, read_err := os.read_entire_file(path, context.allocator)
	if read_err != nil {
		fmt.eprintfln("failed to read visual debug manifest %s: %v", path, read_err)
		return false
	}
	defer delete(bytes)
	root, parse_err := json.parse(bytes, json.Specification.JSON, true, context.allocator)
	if parse_err != .None {
		fmt.eprintfln("failed to parse visual debug manifest %s: %v", path, parse_err)
		return false
	}
	defer json.destroy_value(root)
	root_obj, ok := json_value_object(root)
	if !ok || json_string_default(root_obj, "schema", "") != VISUAL_DEBUG_SCHEMA {
		fmt.eprintfln("visual debug manifest %s has incompatible schema", path)
		return false
	}
	if suite.config_hash == "" {
		suite.config_hash = json_string_default(root_obj, "config_hash", "")
	} else if suite.config_hash !=
	   json_string_default(root_obj, "config_hash", suite.config_hash) {
		fmt.eprintfln("visual debug manifest %s config hash differs from other merge inputs", path)
		return false
	}
	captures_value, captures_ok := root_obj["captures"]
	if !captures_ok {
		return true
	}
	captures, captures_array_ok := json_value_array(captures_value)
	if !captures_array_ok {
		fmt.eprintfln("visual debug manifest %s captures field is not an array", path)
		return false
	}
	for capture_value in captures {
		if suite.capture_count >= VISUAL_DEBUG_MAX_CAPTURES {
			fmt.eprintln("visual debug merge capture capacity exceeded")
			return false
		}
		capture_obj, capture_ok := json_value_object(capture_value)
		if !capture_ok {
			continue
		}
		capture_from_json(capture_obj, &suite.captures[suite.capture_count])
		suite.capture_count += 1
	}
	return true
}

capture_from_json :: proc(obj: json.Object, capture: ^VisualDebugCaptureResult) {
	capture.id = json_string_default(obj, "id", "")
	capture.input_index = u32(json_i64_default(obj, "input_index", 0))
	capture.case_name = json_string_default(obj, "case", "")
	capture.version = json_string_default(obj, "version", "")
	capture.status = status_from_string(json_string_default(obj, "status", "skip"))
	capture.error = json_string_default(obj, "error", "")
	capture.required = json_bool_default(obj, "required", true)
	if modes_value, modes_ok := obj["modes"]; modes_ok {
		modes, modes_array_ok := json_value_array(modes_value)
		if modes_array_ok {
			for mode_value in modes {
				if capture.mode_count >= VISUAL_DEBUG_MAX_MODES {
					break
				}
				mode_obj, mode_ok := json_value_object(mode_value)
				if !mode_ok {
					continue
				}
				capture.modes[capture.mode_count] = mode_from_json(mode_obj)
				capture.mode_count += 1
			}
		}
	}
}

mode_from_json :: proc(obj: json.Object) -> VisualDebugModeResult {
	mode := VisualDebugModeResult {
		id       = json_string_default(obj, "id", ""),
		kind     = json_string_default(obj, "kind", ""),
		status   = status_from_string(json_string_default(obj, "status", "skip")),
		error    = json_string_default(obj, "error", ""),
		required = json_bool_default(obj, "required", true),
		width    = u32(json_i64_default(obj, "width", 0)),
		height   = u32(json_i64_default(obj, "height", 0)),
		palette  = json_string_default(obj, "palette", ""),
		hash     = json_string_default(obj, "hash", ""),
	}
	if artifacts_value, artifacts_ok := obj["artifacts"]; artifacts_ok {
		artifacts, artifacts_array_ok := json_value_array(artifacts_value)
		if artifacts_array_ok {
			for artifact_value in artifacts {
				if mode.artifact_count >= VISUAL_DEBUG_MAX_ARTIFACTS_PER_MODE {
					break
				}
				artifact_obj, artifact_ok := json_value_object(artifact_value)
				if !artifact_ok {
					continue
				}
				mode.artifacts[mode.artifact_count] = artifact_from_json(artifact_obj)
				mode.artifact_count += 1
			}
		}
	}
	if comparison_value, comparison_ok := obj["comparison"]; comparison_ok {
		comparison_obj, comparison_obj_ok := json_value_object(comparison_value)
		if comparison_obj_ok {
			mode.comparison_active = true
			mode.comparison = comparison_from_json(comparison_obj)
		}
	}
	return mode
}

artifact_from_json :: proc(obj: json.Object) -> VisualDebugArtifactRecord {
	return {
		label = json_string_default(obj, "label", ""),
		kind = json_string_default(obj, "kind", ""),
		path = json_string_default(obj, "path", ""),
		content_type = json_string_default(obj, "content_type", ""),
		byte_size = u64(json_i64_default(obj, "byte_size", 0)),
		width = u32(json_i64_default(obj, "width", 0)),
		height = u32(json_i64_default(obj, "height", 0)),
		pixel_format = json_string_default(obj, "pixel_format", ""),
		color_space = json_string_default(obj, "color_space", ""),
		orientation = json_string_default(obj, "orientation", ""),
		palette = json_string_default(obj, "palette", ""),
		encoder = json_string_default(obj, "encoder", ""),
		hash = json_string_default(obj, "hash", ""),
	}
}

comparison_from_json :: proc(obj: json.Object) -> VisualDebugComparisonResult {
	comparison := VisualDebugComparisonResult {
		status           = json_string_default(obj, "status", ""),
		error            = json_string_default(obj, "error", ""),
		baseline_path    = json_string_default(obj, "baseline_path", ""),
		baseline_sidecar = json_string_default(obj, "baseline_sidecar", ""),
		platform_key     = json_string_default(obj, "platform_key", ""),
		old_hash         = json_string_default(obj, "old_hash", ""),
		accepted         = json_bool_default(obj, "accepted", false),
	}
	if diff_value, diff_ok := obj["diff_artifacts"]; diff_ok {
		diff_array, diff_array_ok := json_value_array(diff_value)
		if diff_array_ok {
			for artifact_value in diff_array {
				if comparison.diff_artifact_count >= VISUAL_DEBUG_MAX_DIFF_ARTIFACTS {
					break
				}
				artifact_obj, artifact_ok := json_value_object(artifact_value)
				if !artifact_ok {
					continue
				}
				comparison.diff_artifacts[comparison.diff_artifact_count] = artifact_from_json(
					artifact_obj,
				)
				comparison.diff_artifact_count += 1
			}
		}
	}
	return comparison
}

status_from_string :: proc(value: string) -> VisualDebugStatusKind {
	switch value {
	case "pass":
		return .Pass
	case "fail":
		return .Fail
	case:
		return .Skip
	}
}
