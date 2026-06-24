package vdebug

import "core:fmt"
import "core:os"
import "core:strings"

ffmpeg_discover :: proc(mode: string, allocator := context.allocator) -> FFmpegAdapter {
	probe_mode := mode
	if probe_mode == "" {
		probe_mode = "auto"
	}
	adapter := FFmpegAdapter {
		mode = probe_mode,
	}
	if probe_mode == "off" {
		adapter.available = false
		adapter.error = "ffmpeg disabled"
		return adapter
	}
	path := probe_mode
	if probe_mode == "auto" {
		path = "ffmpeg"
	}
	command := [?]string{path, "-version"}
	state, stdout, stderr, err := os.process_exec(os.Process_Desc{command = command[:]}, allocator)
	defer {
		if stdout != nil {
			delete(stdout, allocator)
		}
		if stderr != nil {
			delete(stderr, allocator)
		}
	}
	adapter.path = path
	if err != nil || !state.success {
		adapter.available = false
		if len(stderr) > 0 {
			adapter.error = strings.clone(string(stderr), allocator)
		} else {
			adapter.error = fmt.aprintf("ffmpeg probe failed: %v", err, allocator = allocator)
		}
		return adapter
	}
	adapter.available = true
	version_output := string(stdout)
	newline := strings.index(version_output, "\n")
	if newline >= 0 {
		adapter.version = strings.clone(version_output[:newline], allocator)
	} else {
		adapter.version = strings.clone(version_output, allocator)
	}
	return adapter
}

ffmpeg_manifest_record :: proc(adapter: ^FFmpegAdapter) -> VisualDebugFFmpegRunRecord {
	if adapter == nil {
		return {status = "not_checked"}
	}
	status := "missing"
	if adapter.mode == "off" {
		status = "disabled"
	} else if adapter.last_command != "" && adapter.error != "" {
		status = "failed"
	} else if adapter.last_command != "" {
		status = "ran"
	} else if adapter.available {
		status = "available"
	}
	return {
		status = status,
		path = adapter.path,
		version = adapter.version,
		command = adapter.last_command != "" ? adapter.last_command : (adapter.available ? fmt.aprintf("%s -version", adapter.path) : ""),
		exit_code = adapter.last_command != "" ? adapter.last_exit_code : (adapter.available ? 0 : -1),
		stderr_tail = ffmpeg_tail(adapter.error),
		output_path = adapter.last_output_path,
		output_hash = adapter.last_output_hash,
	}
}

ffmpeg_tail :: proc(value: string) -> string {
	if len(value) <= 512 {
		return value
	}
	return value[len(value) - 512:]
}

ffmpeg_contact_sheet_make :: proc(ctx: ^VisualDebugContext, columns, rows: u32) -> bool {
	if ctx == nil || ctx.ffmpeg == nil || !ctx.ffmpeg.available {
		return false
	}
	output_path, path_ok := artifact_path_make(ctx, "contact_sheet", "bmp")
	if !path_ok || os.exists(output_path) {
		return false
	}
	frame_dir := path_join3(ctx.artifact_dir, ctx.request_id, ctx.mode_id, ctx.allocator)
	input_glob := path_join2(frame_dir, "*.bmp", ctx.allocator)
	tile_filter := fmt.aprintf("tile=%dx%d", columns, rows, allocator = ctx.allocator)
	command := [?]string {
		ctx.ffmpeg.path,
		"-y",
		"-pattern_type",
		"glob",
		"-i",
		input_glob,
		"-vf",
		tile_filter,
		output_path,
	}
	ctx.ffmpeg.last_command = ffmpeg_command_string(command[:], ctx.allocator)
	ctx.ffmpeg.last_output_path = artifact_manifest_path(ctx, output_path)

	state, stdout, stderr, err := os.process_exec(
		os.Process_Desc{command = command[:]},
		ctx.allocator,
	)
	defer {
		if stdout != nil {
			delete(stdout, ctx.allocator)
		}
		if stderr != nil {
			delete(stderr, ctx.allocator)
		}
	}
	ctx.ffmpeg.last_exit_code = state.exit_code
	if err != nil || !state.success {
		if len(stderr) > 0 {
			ctx.ffmpeg.error = strings.clone(string(stderr), ctx.allocator)
		} else {
			ctx.ffmpeg.error = fmt.aprintf(
				"ffmpeg contact sheet failed: %v",
				err,
				allocator = ctx.allocator,
			)
		}
		return false
	}
	artifact, artifact_ok := artifact_add_existing(
		ctx,
		"contact_sheet",
		"image",
		"image/bmp",
		output_path,
	)
	if artifact_ok {
		ctx.ffmpeg.last_output_hash = artifact.hash
	}
	return artifact_ok
}

ffmpeg_command_string :: proc(args: []string, allocator := context.allocator) -> string {
	builder, alloc_err := strings.builder_make(allocator = allocator)
	if alloc_err != nil {
		return ""
	}
	defer strings.builder_destroy(&builder)
	for arg, i in args {
		if i > 0 {
			strings.write_byte(&builder, ' ')
		}
		strings.write_quoted_string(&builder, arg)
	}
	return strings.clone(strings.to_string(builder), allocator)
}
