package vdebug

import hash "core:crypto/hash"
import "core:fmt"
import "core:strings"

hash_bytes_hex :: proc(data: []byte, allocator := context.allocator) -> string {
	digest: [32]byte
	_ = hash.hash_bytes_to_buffer(.SHA256, data, digest[:])
	builder, alloc_err := strings.builder_make(allocator = allocator)
	if alloc_err != nil {
		return ""
	}
	defer strings.builder_destroy(&builder)
	strings.write_string(&builder, "sha256:")
	for b in digest {
		fmt.sbprintf(&builder, "%02x", b)
	}
	return strings.clone(strings.to_string(builder), allocator)
}

hash_string_hex :: proc(data: string, allocator := context.allocator) -> string {
	return hash_bytes_hex(transmute([]byte)data, allocator)
}
