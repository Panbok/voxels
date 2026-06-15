package camera

import world "app:world"
import world_async "async:world"

import "core:log"
import math "core:math"
import bits "core:math/bits"
import la "core:math/linalg"
import "core:mem"

//////////////////////////////////////
// Camera Constants
/////////////////////////////////////

TERRAIN_CLEARANCE :: f32(18.05)

//////////////////////////////////////
// Terrain Culling Constants
/////////////////////////////////////

TERRAIN_FRONT_TO_BACK_SORT_THRESHOLD :: 512
TERRAIN_SUBCHUNK_CULL_MAX_GEOMETRY_COUNT :: world.CHUNK_SUBCHUNK_COUNT

//////////////////////////////////////
// Camera Types
/////////////////////////////////////

Camera :: struct {
	position:   world.Vec3,
	forward:    world.Vec3,
	up:         world.Vec3,
	right:      world.Vec3,
	world_up:   world.Vec3,
	yaw:        f32,
	pitch:      f32,
	near_plane: f32,
	far_plane:  f32,
}

//////////////////////////////////////
// Frustum Types
/////////////////////////////////////

Plane :: struct {
	normal:   world.Vec3,
	distance: f32,
}

FrustumPlane :: enum u32 {
	Left,
	Right,
	Top,
	Bottom,
	Near,
	Far,
}

Frustum :: struct {
	planes: [FrustumPlane]Plane,
}

FrustumAABBResult :: enum u32 {
	Outside,
	Intersecting,
	Inside,
}

//////////////////////////////////////
// Terrain Culling Types
/////////////////////////////////////

TerrainDrawItem :: struct {
	chunk_coord:    world_async.ChunkCoord,
	geometry_id:    world.ChunkGeometryID,
	aabb:           world.WorldAABB,
	distance_sq:    f32,
	subchunk_index: u32,
	is_subchunk:    bool,
}

TerrainCullingStats :: struct {
	chunks_total:                u32,
	chunks_without_geometry:     u32,
	chunks_frustum_culled:       u32,
	chunks_drawn:                u32,
	draw_units_tested:           u32,
	draw_units_frustum_culled:   u32,
	draw_units_occlusion_culled: u32,
	draw_units_drawn:            u32,
}

TerrainDrawItemEmitProc :: #type proc(item: TerrainDrawItem, userdata: rawptr)

//////////////////////////////////////
// Camera Methods
/////////////////////////////////////

default_create :: proc() -> Camera {
	return {
		position = {0.0, 0.0, -5.0},
		forward = {0.0, 0.0, 1.0},
		up = {0.0, 1.0, 0.0},
		right = {1.0, 0.0, 0.0},
		world_up = {0.0, 1.0, 0.0},
		yaw = 0.0,
		pitch = 0.0,
		near_plane = 0.1,
		far_plane = 100.0,
	}
}

vectors_update :: proc(camera: ^Camera) {
	camera.forward = la.normalize(
		la.Vector3f32 {
			math.sin(camera.yaw) * math.cos(camera.pitch),
			math.sin(camera.pitch),
			math.cos(camera.yaw) * math.cos(camera.pitch),
		},
	)

	camera.right = la.normalize(la.cross(camera.world_up, camera.forward))
	camera.up = la.normalize(la.cross(camera.forward, camera.right))
}

move_above_block :: proc(camera: ^Camera, block: world_async.BlockCoord) {
	camera.position[1] = world.terrain_block_top_world_y(block.y) + TERRAIN_CLEARANCE
}

terrain_intersection_resolve :: proc(camera: ^Camera) -> bool {
	moved := false

	for push_count := 0; push_count < world.CHUNK_BLOCK_LENGTH + 1; push_count += 1 {
		block, intersects := world.chunk_store_solid_block_at_world_position(camera.position).?
		if !intersects {
			return moved
		}

		move_above_block(camera, block)
		moved = true
	}

	log.assertf(false, "camera remained inside solid terrain after repeated upward pushes")
	return moved
}

//////////////////////////////////////
// Frustum Methods
/////////////////////////////////////

frustum_plane_from_point_normal :: proc(point, normal: world.Vec3) -> Plane {
	n := la.normalize(normal)
	return {normal = n, distance = -la.dot(n, point)}
}

frustum_from_camera :: proc(camera: Camera, vertical_fov_radians, aspect: f32) -> Frustum {
	position := camera.position
	forward := la.normalize(camera.forward)
	up := la.normalize(camera.up)
	right := la.normalize(camera.right)

	near_center := position + forward * camera.near_plane
	far_center := position + forward * camera.far_plane

	tan_vertical := math.tan_f32(vertical_fov_radians * 0.5)
	tan_horizontal := aspect * tan_vertical

	frustum := Frustum{}
	frustum.planes[.Left] = frustum_plane_from_point_normal(
		position,
		forward * tan_horizontal + right,
	)
	frustum.planes[.Right] = frustum_plane_from_point_normal(
		position,
		forward * tan_horizontal - right,
	)
	frustum.planes[.Top] = frustum_plane_from_point_normal(position, forward * tan_vertical - up)
	frustum.planes[.Bottom] = frustum_plane_from_point_normal(
		position,
		forward * tan_vertical + up,
	)
	frustum.planes[.Near] = frustum_plane_from_point_normal(near_center, forward)
	frustum.planes[.Far] = frustum_plane_from_point_normal(far_center, -forward)

	return frustum
}

frustum_classify_aabb :: proc(frustum: Frustum, aabb: world.WorldAABB) -> FrustumAABBResult {
	center := aabb_center(aabb)
	extent := world.Vec3 {
		(aabb.max[0] - aabb.min[0]) * 0.5,
		(aabb.max[1] - aabb.min[1]) * 0.5,
		(aabb.max[2] - aabb.min[2]) * 0.5,
	}

	result := FrustumAABBResult.Inside
	for plane in frustum.planes {
		half_distance :=
			extent[0] * math.abs(plane.normal[0]) +
			extent[1] * math.abs(plane.normal[1]) +
			extent[2] * math.abs(plane.normal[2])

		signed_dist :=
			plane.normal[0] * center[0] +
			plane.normal[1] * center[1] +
			plane.normal[2] * center[2] +
			plane.distance
		if signed_dist + half_distance < 0 {
			return .Outside
		}
		if signed_dist - half_distance < 0 {
			result = .Intersecting
		}
	}

	return result
}

frustum_test_aabb :: proc(frustum: Frustum, aabb: world.WorldAABB) -> bool {
	return frustum_classify_aabb(frustum, aabb) != .Outside
}

frustum_test_chunk_subchunk :: proc(
	frustum: Frustum,
	chunk_origin: world.Vec4,
	subchunk_index: u32,
) -> bool {
	#assert(world.CHUNK_SUBCHUNK_COUNT_PER_AXIS == 4)

	sx := subchunk_index & 3
	sy := (subchunk_index >> 2) & 3
	sz := (subchunk_index >> 4) & 3
	length := f32(world.CHUNK_SUBCHUNK_LENGTH) * world.TERRAIN_BLOCK_WORLD_SIZE
	half_length := length * 0.5
	center := world.Vec3 {
		chunk_origin[0] + (f32(sx) + 0.5) * length,
		chunk_origin[1] + (f32(sy) + 0.5) * length,
		chunk_origin[2] + (f32(sz) + 0.5) * length,
	}

	for plane in frustum.planes {
		half_distance :=
			half_length *
			(math.abs(plane.normal[0]) + math.abs(plane.normal[1]) + math.abs(plane.normal[2]))

		signed_dist :=
			plane.normal[0] * center[0] +
			plane.normal[1] * center[1] +
			plane.normal[2] * center[2] +
			plane.distance
		if signed_dist + half_distance < 0 {
			return false
		}
	}
	return true
}

//////////////////////////////////////
// Terrain Culling Methods
/////////////////////////////////////

terrain_draw_item_less :: proc(a, b: TerrainDrawItem) -> bool {
	return a.distance_sq < b.distance_sq
}

terrain_draw_item_add :: proc(items: []TerrainDrawItem, count: ^int, item: TerrainDrawItem) {
	log.assertf(count^ < len(items), "terrain draw item capacity exceeded")
	items[count^] = item
	count^ += 1
}

terrain_visible_items_should_sort :: proc(count: int) -> bool {
	return count > 1 && count <= TERRAIN_FRONT_TO_BACK_SORT_THRESHOLD
}

terrain_subchunk_world_get_aabb :: proc(
	chunk_origin: world.Vec4,
	subchunk_index: u32,
) -> world.WorldAABB {
	#assert(world.CHUNK_SUBCHUNK_COUNT_PER_AXIS == 4)

	sx := subchunk_index & 3
	sy := (subchunk_index >> 2) & 3
	sz := (subchunk_index >> 4) & 3
	length := f32(world.CHUNK_SUBCHUNK_LENGTH) * world.TERRAIN_BLOCK_WORLD_SIZE
	min_world := world.Vec3 {
		chunk_origin[0] + f32(sx) * length,
		chunk_origin[1] + f32(sy) * length,
		chunk_origin[2] + f32(sz) * length,
	}
	return {min = min_world, max = min_world + world.Vec3{length, length, length}}
}

terrain_visible_items_gather :: proc(
	frustum: Frustum,
	observer: world.ChunkVisibilityObserver,
	camera_position: world.Vec3,
	items: []TerrainDrawItem,
	stats: ^TerrainCullingStats,
	need_sort_distance := true,
) -> int {
	draw_count := 0

	for chunk in world.chunk_store_chunks() {
		stats.chunks_total += 1

		has_full_geometry := chunk.geometry_id != world.INVALID_CHUNK_GEOMETRY_ID
		has_subchunk_geometry := world.chunk_subchunk_geometry_has_any(chunk)
		if !has_full_geometry && !has_subchunk_geometry {
			stats.chunks_without_geometry += 1
			continue
		}

		chunk_tested: u32
		chunk_frustum_culled: u32
		chunk_visible := false

		if has_full_geometry {
			aabb := world.chunk_world_get_aabb(chunk.coord)
			stats.draw_units_tested += 1
			chunk_tested += 1
			if !frustum_test_aabb(frustum, aabb) {
				stats.draw_units_frustum_culled += 1
				chunk_frustum_culled += 1
			} else {
				distance_sq := f32(0)
				if need_sort_distance {
					distance_sq = vec3_distance_sq(camera_position, aabb_center(aabb))
				}
				terrain_draw_item_add(
					items,
					&draw_count,
					{
						chunk_coord = chunk.coord,
						geometry_id = chunk.geometry_id,
						aabb = aabb,
						distance_sq = distance_sq,
						subchunk_index = world.CHUNK_SUBCHUNK_INVALID_INDEX,
						is_subchunk = false,
					},
				)
				chunk_visible = true
			}
		} else {
			chunk_aabb := world.chunk_world_get_aabb(chunk.coord)
			chunk_frustum_result := frustum_classify_aabb(frustum, chunk_aabb)
			subchunk_count := chunk.subchunk_geometry_count
			stats.draw_units_tested += subchunk_count
			chunk_tested += subchunk_count
			if chunk_frustum_result == .Outside {
				stats.draw_units_frustum_culled += subchunk_count
				chunk_frustum_culled += subchunk_count
				stats.chunks_frustum_culled += 1
				continue
			}

			use_occlusion := chunk.visibility_graph.empty_mask != 0
			bulk_accept_subchunks :=
				chunk_frustum_result == .Inside ||
				subchunk_count > TERRAIN_SUBCHUNK_CULL_MAX_GEOMETRY_COUNT
			chunk_origin := world.terrain_chunk_origin_world_from_coord(chunk.coord)
			geometry_mask := chunk.subchunk_geometry_mask
			for geometry_mask != 0 {
				subchunk_index_u32 := u32(bits.trailing_zeros(geometry_mask))
				geometry_mask &~= u64(1) << subchunk_index_u32
				subchunk_geometry_id := chunk.subchunk_geometry_ids[subchunk_index_u32]
				log.assert(subchunk_geometry_id != world.INVALID_CHUNK_GEOMETRY_ID)
				needs_subchunk_aabb :=
					need_sort_distance ||
					(!bulk_accept_subchunks && chunk_frustum_result == .Intersecting)
				aabb := world.WorldAABB{}
				if needs_subchunk_aabb {
					aabb = terrain_subchunk_world_get_aabb(chunk_origin, subchunk_index_u32)
				}
				if !bulk_accept_subchunks &&
				   chunk_frustum_result == .Intersecting &&
				   !frustum_test_aabb(frustum, aabb) {
					stats.draw_units_frustum_culled += 1
					chunk_frustum_culled += 1
					continue
				}

				if use_occlusion &&
				   !world.chunk_visibility_graph_allows_subchunk(
						   chunk,
						   subchunk_index_u32,
						   observer,
					   ) {
					stats.draw_units_occlusion_culled += 1
					continue
				}

				distance_sq := f32(0)
				if need_sort_distance {
					distance_sq = vec3_distance_sq(camera_position, aabb_center(aabb))
				}
				terrain_draw_item_add(
					items,
					&draw_count,
					{
						chunk_coord = chunk.coord,
						geometry_id = subchunk_geometry_id,
						aabb = aabb,
						distance_sq = distance_sq,
						subchunk_index = subchunk_index_u32,
						is_subchunk = true,
					},
				)
				chunk_visible = true
			}
		}

		if chunk_visible {
			stats.chunks_drawn += 1
		} else if chunk_tested > 0 && chunk_frustum_culled == chunk_tested {
			stats.chunks_frustum_culled += 1
		}
	}

	return draw_count
}

terrain_visible_unsorted_walk :: proc(
	frustum: Frustum,
	observer: world.ChunkVisibilityObserver,
	stats: ^TerrainCullingStats,
	emit: TerrainDrawItemEmitProc = nil,
	userdata: rawptr = nil,
) -> int {
	draw_count := 0
	for chunk in world.chunk_store_chunks() {
		stats.chunks_total += 1

		has_full_geometry := chunk.geometry_id != world.INVALID_CHUNK_GEOMETRY_ID
		has_subchunk_geometry := world.chunk_subchunk_geometry_has_any(chunk)
		if !has_full_geometry && !has_subchunk_geometry {
			stats.chunks_without_geometry += 1
			continue
		}

		chunk_tested: u32
		chunk_frustum_culled: u32
		chunk_visible := false

		if has_full_geometry {
			aabb := world.chunk_world_get_aabb(chunk.coord)
			stats.draw_units_tested += 1
			chunk_tested += 1
			if !frustum_test_aabb(frustum, aabb) {
				stats.draw_units_frustum_culled += 1
				chunk_frustum_culled += 1
			} else {
				if emit != nil {
					emit(
						{
							chunk_coord = chunk.coord,
							geometry_id = chunk.geometry_id,
							aabb = aabb,
							subchunk_index = world.CHUNK_SUBCHUNK_INVALID_INDEX,
							is_subchunk = false,
						},
						userdata,
					)
				}
				draw_count += 1
				chunk_visible = true
			}
		} else {
			chunk_aabb := world.chunk_world_get_aabb(chunk.coord)
			chunk_frustum_result := frustum_classify_aabb(frustum, chunk_aabb)
			subchunk_count := chunk.subchunk_geometry_count
			stats.draw_units_tested += subchunk_count
			chunk_tested += subchunk_count
			if chunk_frustum_result == .Outside {
				stats.draw_units_frustum_culled += subchunk_count
				chunk_frustum_culled += subchunk_count
				stats.chunks_frustum_culled += 1
				continue
			}

			use_occlusion := chunk.visibility_graph.empty_mask != 0
			bulk_accept_subchunks :=
				chunk_frustum_result == .Inside ||
				subchunk_count > TERRAIN_SUBCHUNK_CULL_MAX_GEOMETRY_COUNT
			if bulk_accept_subchunks &&
			   !use_occlusion &&
			   chunk.subchunk_geometry_mask == world.CHUNK_SUBCHUNK_ALL_MASK {
				for subchunk_index := u32(0);
				    subchunk_index < world.CHUNK_SUBCHUNK_COUNT;
				    subchunk_index += 1 {
					subchunk_geometry_id := chunk.subchunk_geometry_ids[subchunk_index]
					log.assert(subchunk_geometry_id != world.INVALID_CHUNK_GEOMETRY_ID)
					if emit != nil {
						emit(
							{
								chunk_coord = chunk.coord,
								geometry_id = subchunk_geometry_id,
								subchunk_index = subchunk_index,
								is_subchunk = true,
							},
							userdata,
						)
					}
					draw_count += 1
				}
				chunk_visible = true
			} else {
				needs_subchunk_frustum_test :=
					!bulk_accept_subchunks && chunk_frustum_result == .Intersecting
				chunk_origin := world.Vec4{}
				if needs_subchunk_frustum_test {
					chunk_origin = world.terrain_chunk_origin_world_from_coord(chunk.coord)
				}

				geometry_mask := chunk.subchunk_geometry_mask
				for geometry_mask != 0 {
					subchunk_index := u32(bits.trailing_zeros(geometry_mask))
					geometry_mask &~= u64(1) << subchunk_index
					subchunk_geometry_id := chunk.subchunk_geometry_ids[subchunk_index]
					log.assert(subchunk_geometry_id != world.INVALID_CHUNK_GEOMETRY_ID)

					if needs_subchunk_frustum_test &&
					   !frustum_test_chunk_subchunk(frustum, chunk_origin, subchunk_index) {
						stats.draw_units_frustum_culled += 1
						chunk_frustum_culled += 1
						continue
					}

					if use_occlusion &&
					   !world.chunk_visibility_graph_allows_subchunk(
							   chunk,
							   subchunk_index,
							   observer,
						   ) {
						stats.draw_units_occlusion_culled += 1
						continue
					}

					if emit != nil {
						emit(
							{
								chunk_coord = chunk.coord,
								geometry_id = subchunk_geometry_id,
								subchunk_index = subchunk_index,
								is_subchunk = true,
							},
							userdata,
						)
					}
					draw_count += 1
					chunk_visible = true
				}
			}
		}

		if chunk_visible {
			stats.chunks_drawn += 1
		} else if chunk_tested > 0 && chunk_frustum_culled == chunk_tested {
			stats.chunks_frustum_culled += 1
		}
	}
	stats.draw_units_drawn += u32(draw_count)
	return draw_count
}

aabb_center :: proc(aabb: world.WorldAABB) -> world.Vec3 {
	return {
		(aabb.min[0] + aabb.max[0]) * 0.5,
		(aabb.min[1] + aabb.max[1]) * 0.5,
		(aabb.min[2] + aabb.max[2]) * 0.5,
	}
}

vec3_distance_sq :: proc(a, b: world.Vec3) -> f32 {
	d := a - b
	return la.dot(d, d)
}

//////////////////////////////////////
// Debug Methods
/////////////////////////////////////

when ODIN_DEBUG {
	debug_frustum_contract_checks_run :: proc() {
		test_camera := Camera {
			position   = {0, 0, 0},
			forward    = {0, 0, 1},
			up         = {0, 1, 0},
			right      = {1, 0, 0},
			world_up   = {0, 1, 0},
			near_plane = 1,
			far_plane  = 10,
		}
		frustum := frustum_from_camera(test_camera, math.to_radians_f32(90), 1)

		log.assertf(
			frustum_test_aabb(
				frustum,
				world.WorldAABB{min = {-0.5, -0.5, 4}, max = {0.5, 0.5, 5}},
			),
			"frustum check: expected centered box to be visible",
		)
		log.assertf(
			!frustum_test_aabb(
				frustum,
				world.WorldAABB{min = {-0.5, -0.5, -3}, max = {0.5, 0.5, -2}},
			),
			"frustum check: expected box behind camera to be culled",
		)
		log.assertf(
			!frustum_test_aabb(
				frustum,
				world.WorldAABB{min = {-0.5, -0.5, 12}, max = {0.5, 0.5, 13}},
			),
			"frustum check: expected box beyond far plane to be culled",
		)
		log.assertf(
			!frustum_test_aabb(frustum, world.WorldAABB{min = {12, -0.5, 4}, max = {13, 0.5, 5}}),
			"frustum check: expected right-side box to be culled",
		)

		aabb := world.chunk_world_get_aabb(world_async.ChunkCoord{1, 0, -1})
		log.assertf(
			aabb.min == world.Vec3{32, 0, -32},
			"chunk world AABB: min mismatch, got %v",
			aabb.min,
		)
		log.assertf(
			aabb.max == world.Vec3{64, 32, 0},
			"chunk world AABB: max mismatch, got %v",
			aabb.max,
		)

		subchunk_aabb := world.chunk_subchunk_world_get_aabb(
			world_async.ChunkCoord{1, 0, -1},
			world.chunk_subchunk_index_from_coord(2, 1, 3),
		)
		log.assertf(
			subchunk_aabb.min == world.Vec3{48, 8, -8},
			"subchunk world AABB: min mismatch, got %v",
			subchunk_aabb.min,
		)
		log.assertf(
			subchunk_aabb.max == world.Vec3{56, 16, 0},
			"subchunk world AABB: max mismatch, got %v",
			subchunk_aabb.max,
		)
	}

	debug_terrain_collision_checks_run :: proc(transient_allocator: mem.Allocator) {
		chunk := world.chunk_create(world_async.ChunkCoord{0, 0, 0})
		storage := world.chunk_block_storage_alloc(transient_allocator)
		index := world.chunk_block_index(0, 0, 0)
		storage.voxel_view.blocks.occupancy[index] = .Solid
		storage.voxel_view.blocks.material_id[index] = world_async.BlockMaterialID(1)
		world.chunk_mark_generated(&chunk, storage)

		hit_block, hit := world.chunk_solid_block_at_world_block(
			&chunk,
			world_async.BlockCoord{0, 0, 0},
		).?
		log.assert(hit, "camera terrain collision check: expected solid block hit")
		log.assertf(
			hit_block == world_async.BlockCoord{0, 0, 0},
			"camera terrain collision check: wrong hit block %v",
			hit_block,
		)

		test_camera := Camera {
			position = {0.25, 0.25, 0.25},
		}
		move_above_block(&test_camera, hit_block)
		log.assertf(
			test_camera.position[1] > world.terrain_block_top_world_y(hit_block.y),
			"camera terrain collision check: camera was not lifted above block",
		)

		lifted_block := world.block_coord_from_world_position(test_camera.position)
		_, lifted_hit := world.chunk_solid_block_at_world_block(&chunk, lifted_block).?
		log.assert(!lifted_hit, "camera terrain collision check: lifted camera still intersects")

		negative_chunk := world.chunk_create(world_async.ChunkCoord{-1, 0, -1})
		negative_storage := world.chunk_block_storage_alloc(transient_allocator)
		negative_index := world.chunk_block_index(
			world.CHUNK_BLOCK_LOCAL_MAX,
			0,
			world.CHUNK_BLOCK_LOCAL_MAX,
		)
		negative_storage.voxel_view.blocks.occupancy[negative_index] = .Solid
		negative_storage.voxel_view.blocks.material_id[negative_index] =
			world_async.BlockMaterialID(1)
		world.chunk_mark_generated(&negative_chunk, negative_storage)

		negative_hit_block, negative_hit := world.chunk_solid_block_at_world_block(
			&negative_chunk,
			world_async.BlockCoord{-1, 0, -1},
		).?
		log.assert(negative_hit, "camera terrain collision check: expected negative block hit")
		log.assertf(
			negative_hit_block == world_async.BlockCoord{-1, 0, -1},
			"camera terrain collision check: wrong negative hit block %v",
			negative_hit_block,
		)

		log.debug("Camera terrain collision checks passed")
	}
}
