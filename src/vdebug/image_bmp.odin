package vdebug

import "core:mem"

BMP_FILE_HEADER_BYTES :: 14
BMP_INFO_HEADER_BYTES :: 40
BMP_HEADER_BYTES :: BMP_FILE_HEADER_BYTES + BMP_INFO_HEADER_BYTES

bmp_encode_rgba8 :: proc(
	pixels: []PixelRGBA8,
	width, height: u32,
	allocator := context.allocator,
) -> (
	[]byte,
	bool,
) {
	pixel_count := int(width * height)
	if width == 0 || height == 0 || len(pixels) < pixel_count {
		return nil, false
	}
	data_bytes := pixel_count * 4
	file_size := BMP_HEADER_BYTES + data_bytes
	out := make([]byte, file_size, allocator)
	mem.zero_slice(out)

	out[0] = 'B'
	out[1] = 'M'
	bmp_write_u32_le(out, 2, u32(file_size))
	bmp_write_u32_le(out, 10, BMP_HEADER_BYTES)

	bmp_write_u32_le(out, 14, BMP_INFO_HEADER_BYTES)
	bmp_write_i32_le(out, 18, i32(width))
	bmp_write_i32_le(out, 22, -i32(height))
	bmp_write_u16_le(out, 26, 1)
	bmp_write_u16_le(out, 28, 32)
	bmp_write_u32_le(out, 30, 0)
	bmp_write_u32_le(out, 34, u32(data_bytes))
	bmp_write_i32_le(out, 38, 2835)
	bmp_write_i32_le(out, 42, 2835)

	dst := BMP_HEADER_BYTES
	for i := 0; i < pixel_count; i += 1 {
		p := pixels[i]
		out[dst + 0] = p.b
		out[dst + 1] = p.g
		out[dst + 2] = p.r
		out[dst + 3] = p.a
		dst += 4
	}
	return out, true
}

bmp_decode_rgba8 :: proc(
	data: []byte,
	allocator := context.allocator,
) -> (
	pixels: []PixelRGBA8,
	width: u32,
	height: u32,
	ok: bool,
) {
	if len(data) < BMP_HEADER_BYTES || data[0] != 'B' || data[1] != 'M' {
		return nil, 0, 0, false
	}
	offset := int(bmp_read_u32_le(data, 10))
	header_size := bmp_read_u32_le(data, 14)
	if header_size < BMP_INFO_HEADER_BYTES || offset < BMP_HEADER_BYTES || offset >= len(data) {
		return nil, 0, 0, false
	}
	w := bmp_read_i32_le(data, 18)
	h := bmp_read_i32_le(data, 22)
	bpp := bmp_read_u16_le(data, 28)
	compression := bmp_read_u32_le(data, 30)
	if w <= 0 || h == 0 || bpp != 32 || compression != 0 {
		return nil, 0, 0, false
	}
	top_down := h < 0
	if h < 0 {
		h = -h
	}
	width = u32(w)
	height = u32(h)
	pixel_count := int(width * height)
	if offset + pixel_count * 4 > len(data) {
		return nil, 0, 0, false
	}
	pixels = make([]PixelRGBA8, pixel_count, allocator)
	for y := u32(0); y < height; y += 1 {
		src_y := y
		if !top_down {
			src_y = height - 1 - y
		}
		for x := u32(0); x < width; x += 1 {
			src := offset + int((src_y * width + x) * 4)
			dst := int(y * width + x)
			pixels[dst] = {
				r = data[src + 2],
				g = data[src + 1],
				b = data[src + 0],
				a = data[src + 3],
			}
		}
	}
	return pixels, width, height, true
}

bmp_write_u16_le :: proc(bytes: []byte, offset: int, value: u16) {
	bytes[offset + 0] = u8(value & 0xff)
	bytes[offset + 1] = u8((value >> 8) & 0xff)
}

bmp_write_u32_le :: proc(bytes: []byte, offset: int, value: u32) {
	bytes[offset + 0] = u8(value & 0xff)
	bytes[offset + 1] = u8((value >> 8) & 0xff)
	bytes[offset + 2] = u8((value >> 16) & 0xff)
	bytes[offset + 3] = u8((value >> 24) & 0xff)
}

bmp_write_i32_le :: proc(bytes: []byte, offset: int, value: i32) {
	bmp_write_u32_le(bytes, offset, transmute(u32)value)
}

bmp_read_u16_le :: proc(bytes: []byte, offset: int) -> u16 {
	return u16(bytes[offset]) | (u16(bytes[offset + 1]) << 8)
}

bmp_read_u32_le :: proc(bytes: []byte, offset: int) -> u32 {
	return(
		u32(bytes[offset]) |
		(u32(bytes[offset + 1]) << 8) |
		(u32(bytes[offset + 2]) << 16) |
		(u32(bytes[offset + 3]) << 24) \
	)
}

bmp_read_i32_le :: proc(bytes: []byte, offset: int) -> i32 {
	return transmute(i32)bmp_read_u32_le(bytes, offset)
}
