package world

import world_async "async:world"

import math "core:math"

import biomes "world:biomes"

//////////////////////////////////////
// Cave Debug Types
/////////////////////////////////////

TerrainCaveDebugColumnMask :: [CHUNK_BLOCK_LENGTH]u64

//////////////////////////////////////
// Cave Debug Methods
/////////////////////////////////////

terrain_cave_debug_column_mask_build :: proc(
	mask: ^TerrainCaveDebugColumnMask,
	region: ^biomes.GenerationRegion,
	chunk_origin: world_async.BlockCoord,
) {
	for z := u32(0); z < CHUNK_BLOCK_LENGTH; z += 1 {
		mask[z] = 0
	}

	for i := u32(0); i < region.cave_network_node_count; i += 1 {
		node := region.cave_network_nodes[i]
		terrain_cave_debug_column_mask_add_circle(
			mask,
			chunk_origin,
			node.x,
			node.z,
			node.radius_blocks * 0.32 + biomes.CAVE_NETWORK_DEBUG_SURFACE_FALLOFF_BLOCKS,
		)
	}

	for i := u32(0); i < region.cave_network_edge_count; i += 1 {
		edge := region.cave_network_edges[i]
		terrain_cave_debug_column_mask_add_segment(
			mask,
			chunk_origin,
			edge.from_x,
			edge.from_z,
			edge.bend_x,
			edge.bend_z,
			math.max(f32(3), edge.radius_blocks * 0.24) +
			biomes.CAVE_NETWORK_DEBUG_SURFACE_FALLOFF_BLOCKS,
		)
		terrain_cave_debug_column_mask_add_segment(
			mask,
			chunk_origin,
			edge.bend_x,
			edge.bend_z,
			edge.to_x,
			edge.to_z,
			math.max(f32(3), edge.radius_blocks * 0.24) +
			biomes.CAVE_NETWORK_DEBUG_SURFACE_FALLOFF_BLOCKS,
		)
	}

	for i := u32(0); i < region.cave_anchor_count; i += 1 {
		anchor := region.cave_anchors[i]
		terrain_cave_debug_column_mask_add_circle(
			mask,
			chunk_origin,
			anchor.x,
			anchor.z,
			math.max(f32(4), anchor.influence_radius_blocks * 0.45) +
			biomes.CAVE_NETWORK_DEBUG_SURFACE_FALLOFF_BLOCKS,
		)
	}
}

terrain_cave_debug_column_mask_add_circle :: proc(
	mask: ^TerrainCaveDebugColumnMask,
	chunk_origin: world_async.BlockCoord,
	center_x, center_z, radius_blocks: f32,
) {
	radius := math.max(f32(0), radius_blocks)
	local_min_x, local_max_x, local_min_z, local_max_z, intersects :=
		terrain_cave_debug_column_bounds(chunk_origin, center_x, center_z, radius)
	if !intersects {
		return
	}

	radius_sq := radius * radius
	for z := local_min_z; z <= local_max_z; z += 1 {
		world_z := f32(chunk_origin.z + z) + 0.5
		for x := local_min_x; x <= local_max_x; x += 1 {
			world_x := f32(chunk_origin.x + x) + 0.5
			dx := world_x - center_x
			dz := world_z - center_z
			if dx * dx + dz * dz <= radius_sq {
				mask[z] |= u64(1) << u32(x)
			}
		}
	}
}

terrain_cave_debug_column_mask_add_segment :: proc(
	mask: ^TerrainCaveDebugColumnMask,
	chunk_origin: world_async.BlockCoord,
	from_x, from_z, to_x, to_z, radius_blocks: f32,
) {
	radius := math.max(f32(0), radius_blocks)
	local_min_x, local_max_x, local_min_z, local_max_z, intersects :=
		terrain_cave_debug_column_bounds_from_extents(
			chunk_origin,
			math.min(from_x, to_x) - radius,
			math.max(from_x, to_x) + radius,
			math.min(from_z, to_z) - radius,
			math.max(from_z, to_z) + radius,
		)
	if !intersects {
		return
	}

	radius_sq := radius * radius
	for z := local_min_z; z <= local_max_z; z += 1 {
		world_z := f32(chunk_origin.z + z) + 0.5
		for x := local_min_x; x <= local_max_x; x += 1 {
			world_x := f32(chunk_origin.x + x) + 0.5
			if terrain_cave_debug_distance_sq_to_segment_2(
				   world_x,
				   world_z,
				   from_x,
				   from_z,
				   to_x,
				   to_z,
			   ) <=
			   radius_sq {
				mask[z] |= u64(1) << u32(x)
			}
		}
	}
}

terrain_cave_debug_column_bounds :: proc(
	chunk_origin: world_async.BlockCoord,
	center_x, center_z, radius_blocks: f32,
) -> (
	local_min_x, local_max_x, local_min_z, local_max_z: i32,
	intersects: bool,
) {
	return terrain_cave_debug_column_bounds_from_extents(
		chunk_origin,
		center_x - radius_blocks,
		center_x + radius_blocks,
		center_z - radius_blocks,
		center_z + radius_blocks,
	)
}

terrain_cave_debug_column_bounds_from_extents :: proc(
	chunk_origin: world_async.BlockCoord,
	min_world_x, max_world_x, min_world_z, max_world_z: f32,
) -> (
	local_min_x, local_max_x, local_min_z, local_max_z: i32,
	intersects: bool,
) {
	min_x := i32(math.floor_f32(min_world_x)) - chunk_origin.x
	max_x := i32(math.floor_f32(max_world_x)) - chunk_origin.x
	min_z := i32(math.floor_f32(min_world_z)) - chunk_origin.z
	max_z := i32(math.floor_f32(max_world_z)) - chunk_origin.z

	if max_x < 0 || max_z < 0 || min_x >= CHUNK_BLOCK_LENGTH || min_z >= CHUNK_BLOCK_LENGTH {
		return 0, 0, 0, 0, false
	}

	local_min_x = math.clamp(min_x, 0, CHUNK_BLOCK_LENGTH - 1)
	local_max_x = math.clamp(max_x, 0, CHUNK_BLOCK_LENGTH - 1)
	local_min_z = math.clamp(min_z, 0, CHUNK_BLOCK_LENGTH - 1)
	local_max_z = math.clamp(max_z, 0, CHUNK_BLOCK_LENGTH - 1)
	intersects = true
	return
}

terrain_cave_debug_distance_sq_to_segment_2 :: proc(x, z, from_x, from_z, to_x, to_z: f32) -> f32 {
	seg_x := to_x - from_x
	seg_z := to_z - from_z
	len_sq := seg_x * seg_x + seg_z * seg_z
	if len_sq <= 0 {
		dx := x - from_x
		dz := z - from_z
		return dx * dx + dz * dz
	}
	t := math.clamp(((x - from_x) * seg_x + (z - from_z) * seg_z) / len_sq, f32(0), f32(1))
	nearest_x := from_x + seg_x * t
	nearest_z := from_z + seg_z * t
	dx := x - nearest_x
	dz := z - nearest_z
	return dx * dx + dz * dz
}

terrain_cave_network_debug_material_id :: proc(
	material_id: world_async.BlockMaterialID,
) -> world_async.BlockMaterialID {
	return world_async.BlockMaterialID(u8(material_id) | TERRAIN_CAVE_NETWORK_DEBUG_MATERIAL_FLAG)
}

terrain_cave_anchor_debug_material_id :: proc(
	material_id: world_async.BlockMaterialID,
) -> world_async.BlockMaterialID {
	return terrain_cave_network_debug_material_id(material_id)
}
