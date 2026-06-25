package vdebug

import "core:fmt"
import "core:os"
import slice "core:slice"
import "core:strings"

artifact_path_make :: proc(
	ctx: ^VisualDebugContext,
	label, extension: string,
) -> (
	path: string,
	ok: bool,
) {
	if ctx == nil {
		return "", false
	}
	if !identifier_is_safe(ctx.request_id) ||
	   !identifier_is_safe(ctx.mode_id) ||
	   !identifier_is_safe(label) ||
	   !identifier_is_safe(extension) ||
	   strings.contains(extension, ".") {
		return "", false
	}
	dir := path_join3(ctx.artifact_dir, ctx.request_id, ctx.mode_id, ctx.allocator)
	if err := os.make_directory_all(dir); err != nil && !os.is_directory(dir) {
		ctx.mode_result.status = .Fail
		ctx.mode_result.error = fmt.aprintf("failed to create artifact directory %s: %v", dir, err)
		return "", false
	}
	filename := fmt.aprintf("%s.%s", label, extension, allocator = ctx.allocator)
	return path_join2(dir, filename, ctx.allocator), true
}

artifact_write_json_text :: proc(
	ctx: ^VisualDebugContext,
	label: string,
	content: string,
) -> (
	VisualDebugArtifactRecord,
	bool,
) {
	return artifact_write_bytes(
		ctx,
		label,
		"json",
		"application/json",
		transmute([]byte)content,
		"json",
	)
}

artifact_write_bytes :: proc(
	ctx: ^VisualDebugContext,
	label: string,
	kind: string,
	content_type: string,
	bytes: []byte,
	extension: string,
) -> (
	VisualDebugArtifactRecord,
	bool,
) {
	path, path_ok := artifact_path_make(ctx, label, extension)
	if !path_ok {
		return {}, false
	}
	if !write_file_create_only_atomic(path, bytes, ctx.allocator) {
		if ctx.mode_result != nil {
			ctx.mode_result.status = .Fail
			ctx.mode_result.error = fmt.aprintf("failed to write artifact %s", path)
		}
		return {}, false
	}
	artifact := VisualDebugArtifactRecord {
		label        = label,
		kind         = kind,
		path         = artifact_manifest_path(ctx, path),
		content_type = content_type,
		byte_size    = u64(len(bytes)),
		hash         = hash_bytes_hex(bytes, ctx.allocator),
	}
	artifact_record_add(ctx, artifact)
	return artifact, true
}

artifact_write_bmp :: proc(
	ctx: ^VisualDebugContext,
	label: string,
	pixels: []PixelRGBA8,
	width, height: u32,
	palette: string,
) -> (
	VisualDebugArtifactRecord,
	bool,
) {
	if width == 0 || height == 0 || len(pixels) < int(width * height) {
		if ctx.mode_result != nil {
			ctx.mode_result.status = .Fail
			ctx.mode_result.error = "invalid BMP pixel buffer dimensions"
		}
		return {}, false
	}
	bytes, encode_ok := bmp_encode_rgba8(pixels, width, height, ctx.allocator)
	if !encode_ok {
		if ctx.mode_result != nil {
			ctx.mode_result.status = .Fail
			ctx.mode_result.error = "failed to encode BMP artifact"
		}
		return {}, false
	}
	defer delete(bytes, ctx.allocator)

	path, path_ok := artifact_path_make(ctx, label, "bmp")
	if !path_ok {
		return {}, false
	}
	if !write_file_create_only_atomic(path, bytes, ctx.allocator) {
		if ctx.mode_result != nil {
			ctx.mode_result.status = .Fail
			ctx.mode_result.error = fmt.aprintf("failed to write BMP artifact %s", path)
		}
		return {}, false
	}

	canonical_bytes := slice.bytes_from_ptr(
		raw_data(pixels),
		int(width * height) * size_of(PixelRGBA8),
	)
	pixel_hash := hash_bytes_hex(canonical_bytes, ctx.allocator)
	if ctx.mode_result != nil {
		ctx.mode_result.width = width
		ctx.mode_result.height = height
		ctx.mode_result.palette = palette
		ctx.mode_result.hash = pixel_hash
	}
	artifact := VisualDebugArtifactRecord {
		label        = label,
		kind         = "image",
		path         = artifact_manifest_path(ctx, path),
		content_type = "image/bmp",
		byte_size    = u64(len(bytes)),
		width        = width,
		height       = height,
		pixel_format = "rgba8",
		color_space  = "linear",
		orientation  = "top_left",
		palette      = palette,
		encoder      = "bmp.v1",
		hash         = hash_bytes_hex(bytes, ctx.allocator),
	}
	artifact_record_add(ctx, artifact)
	return artifact, true
}

artifact_add_existing :: proc(
	ctx: ^VisualDebugContext,
	label: string,
	kind: string,
	content_type: string,
	path: string,
) -> (
	VisualDebugArtifactRecord,
	bool,
) {
	bytes, read_err := os.read_entire_file(path, ctx.allocator)
	if read_err != nil {
		return {}, false
	}
	defer delete(bytes, ctx.allocator)
	artifact := VisualDebugArtifactRecord {
		label        = label,
		kind         = kind,
		path         = artifact_manifest_path(ctx, path),
		content_type = content_type,
		byte_size    = u64(len(bytes)),
		hash         = hash_bytes_hex(bytes, ctx.allocator),
	}
	artifact_record_add(ctx, artifact)
	return artifact, true
}

write_file_create_only_atomic :: proc(
	path: string,
	bytes: []byte,
	allocator := context.allocator,
) -> bool {
	if path == "" || os.exists(path) {
		return false
	}
	dir := os.dir(path)
	if dir != "." && dir != "" {
		if err := os.make_directory_all(dir); err != nil && !os.is_directory(dir) {
			return false
		}
	}
	tmp := fmt.aprintf("%s.tmp-%d", path, os.get_pid(), allocator = allocator)
	if os.exists(tmp) {
		_ = os.remove(tmp)
	}
	err := os.write_entire_file(tmp, bytes)
	if err != nil {
		_ = os.remove(tmp)
		return false
	}
	if os.exists(path) {
		_ = os.remove(tmp)
		return false
	}
	rename_err := os.rename(tmp, path)
	if rename_err != nil {
		_ = os.remove(tmp)
		return false
	}
	return true
}

artifact_manifest_path :: proc(ctx: ^VisualDebugContext, path: string) -> string {
	prefix := ctx.output_dir
	if prefix != "" {
		sep := os.Path_Separator_String
		with_sep := prefix
		if !strings.has_suffix(prefix, "/") && !strings.has_suffix(prefix, "\\") {
			with_sep = fmt.aprintf("%s%s", prefix, sep, allocator = ctx.allocator)
		}
		if strings.has_prefix(path, with_sep) {
			return strings.clone(path[len(with_sep):], ctx.allocator)
		}
	}
	return strings.clone(path, ctx.allocator)
}
