package world

import world_async "async:world"
import "core:log"
import bits "core:math/bits"
import "core:mem"

//////////////////////////////////////
// Chunk Visibility Types
/////////////////////////////////////

ChunkVisibilityGraph :: struct {
	empty_mask:          u64,
	boundary_empty_mask: u64,
	exterior_mask:       u64,
	adjacency:           [CHUNK_SUBCHUNK_COUNT]u64,
	reachability:        [CHUNK_SUBCHUNK_COUNT]u64,
}

ChunkVisibilityObserver :: struct {
	chunk_coord:         world_async.ChunkCoord,
	subchunk_index:      u32,
	connected_mask:      u64,
	in_generated_chunk:  bool,
	in_empty_air:        bool,
	inside_enclosed_air: bool,
}

//////////////////////////////////////
// Subchunk Bounds Methods
/////////////////////////////////////

chunk_subchunk_coord_from_index :: proc(index: u32) -> (x, y, z: u32) {
	log.assertf(index < CHUNK_SUBCHUNK_COUNT, "subchunk index out of range: %d", index)
	x = index % CHUNK_SUBCHUNK_COUNT_PER_AXIS
	y = (index / CHUNK_SUBCHUNK_COUNT_PER_AXIS) % CHUNK_SUBCHUNK_COUNT_PER_AXIS
	z = index / (CHUNK_SUBCHUNK_COUNT_PER_AXIS * CHUNK_SUBCHUNK_COUNT_PER_AXIS)
	return
}

chunk_subchunk_index_from_local_block :: proc(local: world_async.BlockCoord) -> u32 {
	log.assertf(
		chunk_block_coord_is_inside(local.x, local.y, local.z),
		"local block out of chunk bounds: %v",
		local,
	)
	return chunk_subchunk_index_from_coord(
		u32(local.x) / CHUNK_SUBCHUNK_LENGTH,
		u32(local.y) / CHUNK_SUBCHUNK_LENGTH,
		u32(local.z) / CHUNK_SUBCHUNK_LENGTH,
	)
}

chunk_subchunk_world_get_aabb :: proc(
	coord: world_async.ChunkCoord,
	subchunk_index: u32,
) -> WorldAABB {
	min_block, max_block := chunk_subchunk_bounds_from_index(subchunk_index)
	chunk_origin := terrain_chunk_origin_world_from_coord(coord)

	min_world := Vec3 {
		chunk_origin[0] + f32(min_block.x) * TERRAIN_BLOCK_WORLD_SIZE,
		chunk_origin[1] + f32(min_block.y) * TERRAIN_BLOCK_WORLD_SIZE,
		chunk_origin[2] + f32(min_block.z) * TERRAIN_BLOCK_WORLD_SIZE,
	}
	max_world := Vec3 {
		chunk_origin[0] + f32(max_block.x) * TERRAIN_BLOCK_WORLD_SIZE,
		chunk_origin[1] + f32(max_block.y) * TERRAIN_BLOCK_WORLD_SIZE,
		chunk_origin[2] + f32(max_block.z) * TERRAIN_BLOCK_WORLD_SIZE,
	}
	return {min = min_world, max = max_world}
}

//////////////////////////////////////
// Chunk Visibility Graph Methods
/////////////////////////////////////

chunk_visibility_block_is_empty :: proc(view: world_async.ChunkVoxelView, x, y, z: i32) -> bool {
	log.assertf(
		chunk_block_coord_is_inside(x, y, z),
		"visibility block out of chunk bounds: (%d,%d,%d)",
		x,
		y,
		z,
	)
	index := chunk_block_index(u32(x), u32(y), u32(z))
	return view.blocks.occupancy[index] == .Empty
}

chunk_visibility_subchunk_has_empty :: proc(
	view: world_async.ChunkVoxelView,
	subchunk_index: u32,
) -> bool {
	min_block, max_block := chunk_subchunk_bounds_from_index(subchunk_index)
	for z := min_block.z; z < max_block.z; z += 1 {
		for y := min_block.y; y < max_block.y; y += 1 {
			for x := min_block.x; x < max_block.x; x += 1 {
				if chunk_visibility_block_is_empty(view, x, y, z) {
					return true
				}
			}
		}
	}
	return false
}

chunk_visibility_subchunk_touches_chunk_boundary_air :: proc(
	view: world_async.ChunkVoxelView,
	subchunk_index: u32,
) -> bool {
	min_block, max_block := chunk_subchunk_bounds_from_index(subchunk_index)

	if min_block.x == 0 {
		for z := min_block.z; z < max_block.z; z += 1 {
			for y := min_block.y; y < max_block.y; y += 1 {
				if chunk_visibility_block_is_empty(view, min_block.x, y, z) {
					return true
				}
			}
		}
	}
	if max_block.x == CHUNK_BLOCK_LENGTH {
		x := max_block.x - 1
		for z := min_block.z; z < max_block.z; z += 1 {
			for y := min_block.y; y < max_block.y; y += 1 {
				if chunk_visibility_block_is_empty(view, x, y, z) {
					return true
				}
			}
		}
	}
	if min_block.y == 0 {
		for z := min_block.z; z < max_block.z; z += 1 {
			for x := min_block.x; x < max_block.x; x += 1 {
				if chunk_visibility_block_is_empty(view, x, min_block.y, z) {
					return true
				}
			}
		}
	}
	if max_block.y == CHUNK_BLOCK_LENGTH {
		y := max_block.y - 1
		for z := min_block.z; z < max_block.z; z += 1 {
			for x := min_block.x; x < max_block.x; x += 1 {
				if chunk_visibility_block_is_empty(view, x, y, z) {
					return true
				}
			}
		}
	}
	if min_block.z == 0 {
		for y := min_block.y; y < max_block.y; y += 1 {
			for x := min_block.x; x < max_block.x; x += 1 {
				if chunk_visibility_block_is_empty(view, x, y, min_block.z) {
					return true
				}
			}
		}
	}
	if max_block.z == CHUNK_BLOCK_LENGTH {
		z := max_block.z - 1
		for y := min_block.y; y < max_block.y; y += 1 {
			for x := min_block.x; x < max_block.x; x += 1 {
				if chunk_visibility_block_is_empty(view, x, y, z) {
					return true
				}
			}
		}
	}

	return false
}

chunk_visibility_adjacent_subchunks_touch_air :: proc(
	view: world_async.ChunkVoxelView,
	a_index, b_index, axis: u32,
) -> bool {
	a_min, a_max := chunk_subchunk_bounds_from_index(a_index)
	b_min, _ := chunk_subchunk_bounds_from_index(b_index)

	switch axis {
	case 0:
		ax := a_max.x - 1
		bx := b_min.x
		for z := a_min.z; z < a_max.z; z += 1 {
			for y := a_min.y; y < a_max.y; y += 1 {
				if chunk_visibility_block_is_empty(view, ax, y, z) &&
				   chunk_visibility_block_is_empty(view, bx, y, z) {
					return true
				}
			}
		}
	case 1:
		ay := a_max.y - 1
		by := b_min.y
		for z := a_min.z; z < a_max.z; z += 1 {
			for x := a_min.x; x < a_max.x; x += 1 {
				if chunk_visibility_block_is_empty(view, x, ay, z) &&
				   chunk_visibility_block_is_empty(view, x, by, z) {
					return true
				}
			}
		}
	case 2:
		az := a_max.z - 1
		bz := b_min.z
		for y := a_min.y; y < a_max.y; y += 1 {
			for x := a_min.x; x < a_max.x; x += 1 {
				if chunk_visibility_block_is_empty(view, x, y, az) &&
				   chunk_visibility_block_is_empty(view, x, y, bz) {
					return true
				}
			}
		}
	}

	return false
}

chunk_visibility_graph_component_assign :: proc(
	graph: ^ChunkVisibilityGraph,
	seed_index: u32,
) -> u64 {
	component: u64
	frontier := chunk_subchunk_mask_from_index(seed_index)
	for frontier != 0 {
		index := u32(bits.trailing_zeros(frontier))
		bit := chunk_subchunk_mask_from_index(index)
		frontier &~= bit
		if (component & bit) != 0 {
			continue
		}

		component |= bit
		frontier |= graph.adjacency[index] & graph.empty_mask & ~component
	}

	mask := component
	for mask != 0 {
		index := u32(bits.trailing_zeros(mask))
		bit := chunk_subchunk_mask_from_index(index)
		graph.reachability[index] = component
		mask &~= bit
	}

	return component
}

chunk_visibility_graph_build :: proc(view: world_async.ChunkVoxelView) -> ChunkVisibilityGraph {
	log.assertf(
		len(view.blocks) == CHUNK_BLOCK_COUNT,
		"visibility graph expects %d blocks, got %d",
		CHUNK_BLOCK_COUNT,
		len(view.blocks),
	)

	graph := ChunkVisibilityGraph{}
	for subchunk_index := u32(0); subchunk_index < CHUNK_SUBCHUNK_COUNT; subchunk_index += 1 {
		bit := chunk_subchunk_mask_from_index(subchunk_index)
		if !chunk_visibility_subchunk_has_empty(view, subchunk_index) {
			continue
		}

		graph.empty_mask |= bit
		if chunk_visibility_subchunk_touches_chunk_boundary_air(view, subchunk_index) {
			graph.boundary_empty_mask |= bit
		}
	}

	for z := u32(0); z < CHUNK_SUBCHUNK_COUNT_PER_AXIS; z += 1 {
		for y := u32(0); y < CHUNK_SUBCHUNK_COUNT_PER_AXIS; y += 1 {
			for x := u32(0); x < CHUNK_SUBCHUNK_COUNT_PER_AXIS; x += 1 {
				index := chunk_subchunk_index_from_coord(x, y, z)
				bit := chunk_subchunk_mask_from_index(index)
				if (graph.empty_mask & bit) == 0 {
					continue
				}

				if x + 1 < CHUNK_SUBCHUNK_COUNT_PER_AXIS {
					neighbor_index := chunk_subchunk_index_from_coord(x + 1, y, z)
					neighbor_bit := chunk_subchunk_mask_from_index(neighbor_index)
					if (graph.empty_mask & neighbor_bit) != 0 &&
					   chunk_visibility_adjacent_subchunks_touch_air(
						   view,
						   index,
						   neighbor_index,
						   0,
					   ) {
						graph.adjacency[index] |= neighbor_bit
						graph.adjacency[neighbor_index] |= bit
					}
				}
				if y + 1 < CHUNK_SUBCHUNK_COUNT_PER_AXIS {
					neighbor_index := chunk_subchunk_index_from_coord(x, y + 1, z)
					neighbor_bit := chunk_subchunk_mask_from_index(neighbor_index)
					if (graph.empty_mask & neighbor_bit) != 0 &&
					   chunk_visibility_adjacent_subchunks_touch_air(
						   view,
						   index,
						   neighbor_index,
						   1,
					   ) {
						graph.adjacency[index] |= neighbor_bit
						graph.adjacency[neighbor_index] |= bit
					}
				}
				if z + 1 < CHUNK_SUBCHUNK_COUNT_PER_AXIS {
					neighbor_index := chunk_subchunk_index_from_coord(x, y, z + 1)
					neighbor_bit := chunk_subchunk_mask_from_index(neighbor_index)
					if (graph.empty_mask & neighbor_bit) != 0 &&
					   chunk_visibility_adjacent_subchunks_touch_air(
						   view,
						   index,
						   neighbor_index,
						   2,
					   ) {
						graph.adjacency[index] |= neighbor_bit
						graph.adjacency[neighbor_index] |= bit
					}
				}
			}
		}
	}

	assigned: u64
	for subchunk_index := u32(0); subchunk_index < CHUNK_SUBCHUNK_COUNT; subchunk_index += 1 {
		bit := chunk_subchunk_mask_from_index(subchunk_index)
		if (graph.empty_mask & bit) == 0 || (assigned & bit) != 0 {
			continue
		}

		component := chunk_visibility_graph_component_assign(&graph, subchunk_index)
		assigned |= component
	}

	boundary_mask := graph.boundary_empty_mask
	for boundary_mask != 0 {
		index := u32(bits.trailing_zeros(boundary_mask))
		bit := chunk_subchunk_mask_from_index(index)
		graph.exterior_mask |= graph.reachability[index]
		boundary_mask &~= bit
	}

	return graph
}

chunk_visibility_graph_rebuild :: proc(chunk: ^Chunk) {
	if chunk.generation_state != .Generated || len(chunk.block_storage.voxel_view.blocks) == 0 {
		chunk.visibility_graph = {}
		return
	}

	chunk.visibility_graph = chunk_visibility_graph_build(chunk.block_storage.voxel_view)
}

chunk_visibility_subchunk_mask_expand_face_neighbors :: proc(mask: u64) -> u64 {
	expanded := mask
	work_mask := mask
	for work_mask != 0 {
		index := u32(bits.trailing_zeros(work_mask))
		bit := chunk_subchunk_mask_from_index(index)
		work_mask &~= bit

		x, y, z := chunk_subchunk_coord_from_index(index)
		if x > 0 {
			expanded |= chunk_subchunk_mask_from_index(
				chunk_subchunk_index_from_coord(x - 1, y, z),
			)
		}
		if x + 1 < CHUNK_SUBCHUNK_COUNT_PER_AXIS {
			expanded |= chunk_subchunk_mask_from_index(
				chunk_subchunk_index_from_coord(x + 1, y, z),
			)
		}
		if y > 0 {
			expanded |= chunk_subchunk_mask_from_index(
				chunk_subchunk_index_from_coord(x, y - 1, z),
			)
		}
		if y + 1 < CHUNK_SUBCHUNK_COUNT_PER_AXIS {
			expanded |= chunk_subchunk_mask_from_index(
				chunk_subchunk_index_from_coord(x, y + 1, z),
			)
		}
		if z > 0 {
			expanded |= chunk_subchunk_mask_from_index(
				chunk_subchunk_index_from_coord(x, y, z - 1),
			)
		}
		if z + 1 < CHUNK_SUBCHUNK_COUNT_PER_AXIS {
			expanded |= chunk_subchunk_mask_from_index(
				chunk_subchunk_index_from_coord(x, y, z + 1),
			)
		}
	}

	return expanded
}

chunk_visibility_observer_from_world_position :: proc(position: Vec3) -> ChunkVisibilityObserver {
	observer := ChunkVisibilityObserver {
		subchunk_index = CHUNK_SUBCHUNK_INVALID_INDEX,
	}
	block := block_coord_from_world_position(position)
	observer.chunk_coord = chunk_coord_from_block_coord(block)
	local := block_coord_local_from_chunk_coord(block, observer.chunk_coord)
	if !chunk_block_coord_is_inside(local.x, local.y, local.z) {
		return observer
	}

	observer.subchunk_index = chunk_subchunk_index_from_local_block(local)
	chunk_index, chunk_ok := chunk_store_find_index_by_coord(observer.chunk_coord).?
	if !chunk_ok {
		return observer
	}

	chunk := chunk_store_get_by_index(chunk_index)
	if chunk.generation_state != .Generated {
		return observer
	}
	observer.in_generated_chunk = true

	block_index := chunk_block_index(u32(local.x), u32(local.y), u32(local.z))
	if chunk.block_storage.voxel_view.blocks.occupancy[block_index] != .Empty {
		return observer
	}

	observer.in_empty_air = true
	observer.connected_mask = chunk.visibility_graph.reachability[observer.subchunk_index]
	if observer.connected_mask == 0 {
		observer.connected_mask = chunk_subchunk_mask_from_index(observer.subchunk_index)
	}
	observer.inside_enclosed_air =
		(observer.connected_mask & chunk.visibility_graph.exterior_mask) == 0
	return observer
}

chunk_visibility_graph_allows_subchunk :: proc(
	chunk: Chunk,
	subchunk_index: u32,
	observer: ChunkVisibilityObserver,
) -> bool {
	log.assertf(
		subchunk_index < CHUNK_SUBCHUNK_COUNT,
		"subchunk index out of range: %d",
		subchunk_index,
	)
	if chunk.generation_state != .Generated {
		return true
	}

	graph := chunk.visibility_graph
	if graph.empty_mask == 0 {
		return true
	}

	visible_air_mask: u64
	if observer.in_empty_air &&
	   observer.in_generated_chunk &&
	   observer.chunk_coord == chunk.coord {
		visible_air_mask = observer.connected_mask
	} else {
		if observer.inside_enclosed_air {
			return true
		}
		visible_air_mask = graph.exterior_mask
	}
	if visible_air_mask == 0 {
		return true
	}

	visible_geometry_mask := chunk_visibility_subchunk_mask_expand_face_neighbors(visible_air_mask)
	return (visible_geometry_mask & chunk_subchunk_mask_from_index(subchunk_index)) != 0
}

when ODIN_DEBUG {
	debug_chunk_visibility_fill_solid :: proc(view: ^world_async.ChunkVoxelView) {
		for _, i in view.blocks {
			view.blocks.occupancy[i] = .Solid
			view.blocks.material_id[i] = world_async.BlockMaterialID(TERRAIN_STONE_MAT_ID)
		}
	}

	debug_chunk_visibility_fill_subchunk_empty :: proc(
		view: ^world_async.ChunkVoxelView,
		subchunk_index: u32,
	) {
		min_block, max_block := chunk_subchunk_bounds_from_index(subchunk_index)
		for z := min_block.z; z < max_block.z; z += 1 {
			for y := min_block.y; y < max_block.y; y += 1 {
				for x := min_block.x; x < max_block.x; x += 1 {
					index := chunk_block_index(u32(x), u32(y), u32(z))
					view.blocks.occupancy[index] = .Empty
					view.blocks.material_id[index] = world_async.BlockMaterialID(0)
				}
			}
		}
	}

	debug_chunk_visibility_contract_checks_run :: proc(transient_arena: ^mem.Arena) {
		temp := mem.begin_arena_temp_memory(transient_arena)
		defer mem.end_arena_temp_memory(temp)

		allocator := mem.arena_allocator(transient_arena)
		view := world_async.ChunkVoxelView{}
		chunk_voxel_view_alloc(&view, allocator)

		empty_graph := chunk_visibility_graph_build(view)
		log.assertf(
			empty_graph.empty_mask == CHUNK_SUBCHUNK_ALL_MASK,
			"empty chunk visibility: expected all subchunks empty, got %x",
			empty_graph.empty_mask,
		)
		log.assertf(
			empty_graph.exterior_mask == CHUNK_SUBCHUNK_ALL_MASK,
			"empty chunk visibility: expected all subchunks exterior-connected, got %x",
			empty_graph.exterior_mask,
		)

		debug_chunk_visibility_fill_solid(&view)
		full_graph := chunk_visibility_graph_build(view)
		log.assertf(
			full_graph.empty_mask == 0,
			"full chunk visibility: expected no empty subchunks, got %x",
			full_graph.empty_mask,
		)
		log.assertf(
			full_graph.exterior_mask == 0,
			"full chunk visibility: expected no exterior air, got %x",
			full_graph.exterior_mask,
		)

		cave_index := chunk_subchunk_index_from_coord(1, 1, 1)
		cave_bit := chunk_subchunk_mask_from_index(cave_index)
		debug_chunk_visibility_fill_solid(&view)
		debug_chunk_visibility_fill_subchunk_empty(&view, cave_index)
		cave_graph := chunk_visibility_graph_build(view)
		log.assertf(
			cave_graph.empty_mask == cave_bit,
			"enclosed cave visibility: empty mask mismatch, got %x",
			cave_graph.empty_mask,
		)
		log.assertf(
			cave_graph.exterior_mask == 0,
			"enclosed cave visibility: expected no exterior connection, got %x",
			cave_graph.exterior_mask,
		)
		log.assertf(
			cave_graph.reachability[cave_index] == cave_bit,
			"enclosed cave visibility: reachability mismatch, got %x",
			cave_graph.reachability[cave_index],
		)
		cave_chunk := chunk_create({0, 0, 0})
		cave_chunk.generation_state = .Generated
		cave_chunk.visibility_graph = cave_graph
		cave_observer := ChunkVisibilityObserver {
			chunk_coord         = cave_chunk.coord,
			subchunk_index      = cave_index,
			connected_mask      = cave_bit,
			in_generated_chunk  = true,
			in_empty_air        = true,
			inside_enclosed_air = true,
		}
		log.assert(
			chunk_visibility_graph_allows_subchunk(cave_chunk, cave_index, cave_observer),
			"enclosed cave visibility: observer region should be visible",
		)
		log.assert(
			!chunk_visibility_graph_allows_subchunk(
				cave_chunk,
				chunk_subchunk_index_from_coord(3, 3, 3),
				cave_observer,
			),
			"enclosed cave visibility: disconnected region should be occluded",
		)

		corridor_a := chunk_subchunk_index_from_coord(0, 1, 1)
		corridor_b := chunk_subchunk_index_from_coord(1, 1, 1)
		corridor_mask :=
			chunk_subchunk_mask_from_index(corridor_a) | chunk_subchunk_mask_from_index(corridor_b)
		debug_chunk_visibility_fill_solid(&view)
		debug_chunk_visibility_fill_subchunk_empty(&view, corridor_a)
		debug_chunk_visibility_fill_subchunk_empty(&view, corridor_b)
		corridor_graph := chunk_visibility_graph_build(view)
		log.assertf(
			(corridor_graph.exterior_mask & corridor_mask) == corridor_mask,
			"corridor visibility: expected corridor connected to exterior, got %x",
			corridor_graph.exterior_mask,
		)
		corridor_chunk := chunk_create({0, 0, 0})
		corridor_chunk.generation_state = .Generated
		corridor_chunk.visibility_graph = corridor_graph
		log.assert(
			chunk_visibility_graph_allows_subchunk(corridor_chunk, corridor_b, {}),
			"corridor visibility: exterior-connected subchunk should be visible",
		)
		log.assert(
			!chunk_visibility_graph_allows_subchunk(
				corridor_chunk,
				chunk_subchunk_index_from_coord(3, 3, 3),
				{},
			),
			"corridor visibility: disconnected subchunk should be occluded from exterior",
		)

		log.debug("Chunk visibility contract checks passed")
	}
}
