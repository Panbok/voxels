package vdebug

import "core:fmt"
import "core:os"
import "core:strings"

write_html :: proc(path: string, suite: ^VisualDebugSuiteResult) -> bool {
	builder, alloc_err := strings.builder_make(allocator = context.allocator)
	if alloc_err != nil {
		fmt.eprintln("failed to allocate visual debug HTML builder")
		return false
	}
	defer strings.builder_destroy(&builder)

	html_write_suite(&builder, suite)
	err := os.write_entire_file(path, strings.to_string(builder))
	if err != nil {
		fmt.eprintfln("failed to write visual debug HTML %s: %v", path, err)
		return false
	}
	return true
}

html_write_suite :: proc(builder: ^strings.Builder, suite: ^VisualDebugSuiteResult) {
	strings.write_string(
		builder,
		"<!doctype html><html><head><meta charset=\"utf-8\"><title>Voxel Visual Debug</title>",
	)
	strings.write_string(
		builder,
		"<style>body{font-family:-apple-system,BlinkMacSystemFont,Segoe UI,sans-serif;margin:24px;color:#17202a;background:#f7f9fb}h1{font-size:24px;margin:0 0 8px}h2{font-size:18px;margin:28px 0 10px}.meta{font-family:ui-monospace,SFMono-Regular,Menlo,monospace;font-size:12px;color:#40505f;margin-bottom:18px}.capture{border-top:1px solid #d7e0e8;padding:18px 0}.status-pass{color:#176b3a}.status-fail,.status-missing_baseline{color:#a32727}.status-skip{color:#7a5a00}.modes{display:grid;grid-template-columns:repeat(auto-fit,minmax(260px,1fr));gap:14px}.mode{background:white;border:1px solid #dce4ec;border-radius:6px;padding:12px}.mode h3{font-size:14px;margin:0 0 8px}.thumbs{display:grid;grid-template-columns:repeat(auto-fit,minmax(140px,1fr));gap:8px}.thumb{font-size:12px;color:#40505f}.thumb img{display:block;max-width:100%;height:auto;border:1px solid #ccd7e0;background:#fff;image-rendering:pixelated}.kv{font-family:ui-monospace,SFMono-Regular,Menlo,monospace;font-size:12px;line-height:1.45}.error{color:#a32727;font-size:13px}</style></head><body>",
	)
	strings.write_string(builder, "<h1>Voxel Visual Debug</h1><div class=\"meta\">run_id=")
	html_escape(builder, suite.run_id)
	strings.write_string(builder, " process_id=")
	fmt.sbprintf(builder, "%d", suite.process_id)
	strings.write_string(builder, " config=")
	html_escape(builder, suite.config_path)
	strings.write_string(builder, "</div>")

	html_write_capture_group(builder, suite, true)
	html_write_capture_group(builder, suite, false)

	strings.write_string(builder, "</body></html>\n")
}

html_write_capture_group :: proc(
	builder: ^strings.Builder,
	suite: ^VisualDebugSuiteResult,
	failures: bool,
) {
	heading := failures ? "Failures" : "Passes And Skips"
	strings.write_string(builder, "<h2>")
	strings.write_string(builder, heading)
	strings.write_string(builder, "</h2>")
	wrote := false
	for i := u32(0); i < suite.capture_count; i += 1 {
		capture := &suite.captures[i]
		is_failure := capture.status == .Fail || capture_has_failed_comparison(capture)
		if is_failure != failures {
			continue
		}
		html_write_capture(builder, capture)
		wrote = true
	}
	if !wrote {
		strings.write_string(builder, "<p class=\"kv\">None</p>")
	}
}

capture_has_failed_comparison :: proc(capture: ^VisualDebugCaptureResult) -> bool {
	for i := u32(0); i < capture.mode_count; i += 1 {
		mode := &capture.modes[i]
		if mode.comparison_active &&
		   (mode.comparison.status == "fail" || mode.comparison.status == "missing_baseline") {
			return true
		}
	}
	return false
}

html_write_capture :: proc(builder: ^strings.Builder, capture: ^VisualDebugCaptureResult) {
	status := status_string(capture.status)
	strings.write_string(builder, "<section class=\"capture\"><div class=\"kv\"><strong>")
	html_escape(builder, capture.id)
	strings.write_string(builder, "</strong> case=")
	html_escape(builder, capture.case_name)
	strings.write_string(builder, " status=<span class=\"status-")
	html_escape(builder, status)
	strings.write_string(builder, "\">")
	html_escape(builder, status)
	strings.write_string(builder, "</span></div>")
	if capture.error != "" {
		strings.write_string(builder, "<div class=\"error\">")
		html_escape(builder, capture.error)
		strings.write_string(builder, "</div>")
	}
	strings.write_string(builder, "<div class=\"modes\">")
	for i := u32(0); i < capture.mode_count; i += 1 {
		html_write_mode(builder, &capture.modes[i])
	}
	strings.write_string(builder, "</div></section>")
}

html_write_mode :: proc(builder: ^strings.Builder, mode: ^VisualDebugModeResult) {
	status := status_string(mode.status)
	strings.write_string(builder, "<article class=\"mode\"><h3>")
	html_escape(builder, mode.id)
	strings.write_string(builder, " <span class=\"status-")
	html_escape(builder, status)
	strings.write_string(builder, "\">")
	html_escape(builder, status)
	strings.write_string(builder, "</span></h3><div class=\"kv\">kind=")
	html_escape(builder, mode.kind)
	strings.write_string(builder, "<br>hash=")
	html_escape(builder, mode.hash)
	if mode.comparison_active {
		strings.write_string(builder, "<br>comparison=<span class=\"status-")
		html_escape(builder, mode.comparison.status)
		strings.write_string(builder, "\">")
		html_escape(builder, mode.comparison.status)
		strings.write_string(builder, "</span>")
		strings.write_string(builder, "<br>changed_pixels=")
		fmt.sbprintf(builder, "%d", mode.comparison.metrics.changed_pixels)
		strings.write_string(builder, " ratio=")
		fmt.sbprintf(builder, "%.6f", mode.comparison.metrics.changed_pixel_ratio)
	}
	strings.write_string(builder, "</div>")
	if mode.error != "" {
		strings.write_string(builder, "<div class=\"error\">")
		html_escape(builder, mode.error)
		strings.write_string(builder, "</div>")
	}
	if mode.comparison_active && mode.comparison.error != "" {
		strings.write_string(builder, "<div class=\"error\">")
		html_escape(builder, mode.comparison.error)
		strings.write_string(builder, "</div>")
	}
	strings.write_string(builder, "<div class=\"thumbs\">")
	for i := u32(0); i < mode.artifact_count; i += 1 {
		html_write_artifact_thumb(builder, &mode.artifacts[i])
	}
	if mode.comparison_active {
		if mode.comparison.baseline_path != "" {
			html_write_link_thumb(builder, "expected", mode.comparison.baseline_path, true)
		}
		for i := u32(0); i < mode.comparison.diff_artifact_count; i += 1 {
			html_write_artifact_thumb(builder, &mode.comparison.diff_artifacts[i])
		}
	}
	strings.write_string(builder, "</div></article>")
}

html_write_artifact_thumb :: proc(
	builder: ^strings.Builder,
	artifact: ^VisualDebugArtifactRecord,
) {
	if artifact.kind == "image" {
		html_write_link_thumb(builder, artifact.label, artifact.path, true)
	} else {
		html_write_link_thumb(builder, artifact.label, artifact.path, false)
	}
}

html_write_link_thumb :: proc(builder: ^strings.Builder, label, path: string, image: bool) {
	strings.write_string(builder, "<div class=\"thumb\"><a href=\"")
	html_attr_escape(builder, path)
	strings.write_string(builder, "\">")
	html_escape(builder, label)
	strings.write_string(builder, "</a>")
	if image {
		strings.write_string(builder, "<img alt=\"")
		html_attr_escape(builder, label)
		strings.write_string(builder, "\" src=\"")
		html_attr_escape(builder, path)
		strings.write_string(builder, "\">")
	}
	strings.write_string(builder, "</div>")
}

html_escape :: proc(builder: ^strings.Builder, value: string) {
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

html_attr_escape :: proc(builder: ^strings.Builder, value: string) {
	html_escape(builder, value)
}
