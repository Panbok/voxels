package world

import world_async "async:world"
import "base:runtime"
import "core:log"
import "core:mem"
import "core:sync"

import biomes "world:biomes"

//////////////////////////////////////
// Terrain Generation Cache Types
/////////////////////////////////////

TerrainGenerationRegionCacheSlot :: struct {
	valid:     bool,
	key:       biomes.FeatureGridKey,
	coord:     biomes.GenerationRegionCoord,
	region:    biomes.GenerationRegion,
	last_used: u64,
}

TerrainGenerationRegionCache :: struct {
	mutex: sync.Mutex,
	slots: [TERRAIN_GENERATION_REGION_CACHE_CAPACITY]TerrainGenerationRegionCacheSlot,
	clock: u64,
}

TerrainCaveChunkOverlay :: struct {
	empty_masks:          [TERRAIN_CAVE_CHUNK_OVERLAY_WORD_COUNT]u64,
	solid_material_masks: [TERRAIN_CAVE_CHUNK_OVERLAY_WORD_COUNT]u64,
	solid_material_ids:   [CHUNK_BLOCK_COUNT]world_async.BlockMaterialID,
	change_count:         u32,
}

TerrainCaveChunkOverlayBaseSnapshot :: struct {
	occupancy:   [CHUNK_BLOCK_COUNT]world_async.BlockOccupancy,
	material_id: [CHUNK_BLOCK_COUNT]world_async.BlockMaterialID,
}

TerrainGenerationCaveOverlayCacheSlot :: struct {
	valid:     bool,
	key:       biomes.FeatureGridKey,
	coord:     world_async.ChunkCoord,
	overlay:   TerrainCaveChunkOverlay,
	last_used: u64,
}

TerrainGenerationCaveOverlayCache :: struct {
	mutex:       sync.Mutex,
	initialized: bool,
	slots:       []TerrainGenerationCaveOverlayCacheSlot,
	clock:       u64,
}

TerrainGenerationChunkCacheSlot :: struct {
	valid:     bool,
	key:       biomes.FeatureGridKey,
	coord:     world_async.ChunkCoord,
	view:      world_async.ChunkVoxelView,
	last_used: u64,
}

TerrainGenerationChunkCache :: struct {
	mutex:       sync.Mutex,
	initialized: bool,
	slots:       [TERRAIN_GENERATION_CHUNK_CACHE_CAPACITY]TerrainGenerationChunkCacheSlot,
	clock:       u64,
}

TerrainGenerationColumnCacheSlot :: struct {
	valid:     bool,
	key:       biomes.FeatureGridKey,
	chunk_x:   i32,
	chunk_z:   i32,
	columns:   [CHUNK_BLOCK_LENGTH * CHUNK_BLOCK_LENGTH]TerrainBiomeColumn,
	last_used: u64,
}

TerrainGenerationColumnCache :: struct {
	mutex: sync.Mutex,
	slots: [TERRAIN_GENERATION_COLUMN_CACHE_CAPACITY]TerrainGenerationColumnCacheSlot,
	clock: u64,
}

//////////////////////////////////////
// Terrain Generation Cache Methods
/////////////////////////////////////

terrain_cave_chunk_overlay_mask_set :: proc(
	mask: ^[TERRAIN_CAVE_CHUNK_OVERLAY_WORD_COUNT]u64,
	index: u32,
) {
	mask[index >> 6] |= u64(1) << (index & 63)
}

terrain_cave_chunk_overlay_base_snapshot_capture :: proc(
	snapshot: ^TerrainCaveChunkOverlayBaseSnapshot,
	view: ^world_async.ChunkVoxelView,
) {
	log.assertf(
		len(view.blocks) == CHUNK_BLOCK_COUNT,
		"cave overlay base snapshot expects %d blocks, got %d",
		CHUNK_BLOCK_COUNT,
		len(view.blocks),
	)
	mem.copy(
		raw_data(snapshot.occupancy[:]),
		view.blocks.occupancy,
		int(CHUNK_BLOCK_COUNT * size_of(world_async.BlockOccupancy)),
	)
	mem.copy(
		raw_data(snapshot.material_id[:]),
		view.blocks.material_id,
		int(CHUNK_BLOCK_COUNT * size_of(world_async.BlockMaterialID)),
	)
}

terrain_cave_chunk_overlay_build_from_base :: proc(
	overlay: ^TerrainCaveChunkOverlay,
	final: ^world_async.ChunkVoxelView,
	base: ^TerrainCaveChunkOverlayBaseSnapshot,
) {
	log.assertf(
		len(final.blocks) == CHUNK_BLOCK_COUNT,
		"cave overlay final view expects %d blocks, got %d",
		CHUNK_BLOCK_COUNT,
		len(final.blocks),
	)

	overlay^ = {}
	for index := u32(0); index < CHUNK_BLOCK_COUNT; index += 1 {
		final_occupancy := final.blocks.occupancy[index]
		final_material_id := final.blocks.material_id[index]
		base_occupancy := base.occupancy[index]
		base_material_id := base.material_id[index]

		if final_occupancy == .Empty {
			if base_occupancy != .Empty || base_material_id != final_material_id {
				terrain_cave_chunk_overlay_mask_set(&overlay.empty_masks, index)
				overlay.change_count += 1
			}
			continue
		}

		if base_occupancy != .Solid || base_material_id != final_material_id {
			terrain_cave_chunk_overlay_mask_set(&overlay.solid_material_masks, index)
			overlay.solid_material_ids[index] = final_material_id
			overlay.change_count += 1
		}
	}
}

terrain_cave_chunk_overlay_apply :: proc(
	overlay: ^TerrainCaveChunkOverlay,
	view: ^world_async.ChunkVoxelView,
) {
	log.assertf(
		len(view.blocks) == CHUNK_BLOCK_COUNT,
		"cave overlay replay expects %d blocks, got %d",
		CHUNK_BLOCK_COUNT,
		len(view.blocks),
	)

	for word_index := u32(0); word_index < TERRAIN_CAVE_CHUNK_OVERLAY_WORD_COUNT; word_index += 1 {
		word := overlay.empty_masks[word_index]
		if word == 0 {
			continue
		}
		base_index := word_index << 6
		for bit := u32(0); bit < 64; bit += 1 {
			if (word & (u64(1) << bit)) == 0 {
				continue
			}
			index := base_index + bit
			view.blocks.occupancy[index] = .Empty
			view.blocks.material_id[index] = world_async.BlockMaterialID(0)
		}
	}

	for word_index := u32(0); word_index < TERRAIN_CAVE_CHUNK_OVERLAY_WORD_COUNT; word_index += 1 {
		word := overlay.solid_material_masks[word_index]
		if word == 0 {
			continue
		}
		base_index := word_index << 6
		for bit := u32(0); bit < 64; bit += 1 {
			if (word & (u64(1) << bit)) == 0 {
				continue
			}
			index := base_index + bit
			view.blocks.occupancy[index] = .Solid
			view.blocks.material_id[index] = overlay.solid_material_ids[index]
		}
	}
}

terrain_generation_chunk_cache_init :: proc(allocator: mem.Allocator) {
	when TERRAIN_GENERATION_CHUNK_CACHE_ENABLED {
		cache := &state.terrain_generation_chunk_cache
		sync.lock(&cache.mutex)
		defer sync.unlock(&cache.mutex)

		if cache.initialized {
			return
		}

		for i := 0; i < TERRAIN_GENERATION_CHUNK_CACHE_CAPACITY; i += 1 {
			chunk_voxel_view_alloc(&cache.slots[i].view, allocator)
		}
		cache.initialized = true
	}
}

terrain_generation_chunk_cache_clear :: proc() {
	when TERRAIN_GENERATION_CHUNK_CACHE_ENABLED {
		cache := &state.terrain_generation_chunk_cache
		if !cache.initialized {
			return
		}

		sync.lock(&cache.mutex)
		defer sync.unlock(&cache.mutex)

		for i := 0; i < TERRAIN_GENERATION_CHUNK_CACHE_CAPACITY; i += 1 {
			cache.slots[i].valid = false
		}
		cache.clock = 0
	}
}

terrain_generation_chunk_cache_try_read :: proc(
	view: ^world_async.ChunkVoxelView,
	key: biomes.FeatureGridKey,
	coord: world_async.ChunkCoord,
) -> bool {
	when TERRAIN_GENERATION_CHUNK_CACHE_ENABLED {
		cache := &state.terrain_generation_chunk_cache
		if !cache.initialized {
			return false
		}

		sync.lock(&cache.mutex)
		defer sync.unlock(&cache.mutex)

		for i := 0; i < TERRAIN_GENERATION_CHUNK_CACHE_CAPACITY; i += 1 {
			slot := &cache.slots[i]
			if slot.valid && slot.key == key && slot.coord == coord {
				cache.clock += 1
				slot.last_used = cache.clock
				chunk_voxel_view_copy(view, &slot.view)
				return true
			}
		}
	}
	return false
}

terrain_generation_chunk_cache_contains :: proc(
	key: biomes.FeatureGridKey,
	coord: world_async.ChunkCoord,
) -> bool {
	when TERRAIN_GENERATION_CHUNK_CACHE_ENABLED {
		cache := &state.terrain_generation_chunk_cache
		if !cache.initialized {
			return false
		}

		sync.lock(&cache.mutex)
		defer sync.unlock(&cache.mutex)

		for i := 0; i < TERRAIN_GENERATION_CHUNK_CACHE_CAPACITY; i += 1 {
			slot := &cache.slots[i]
			if slot.valid && slot.key == key && slot.coord == coord {
				return true
			}
		}
	}
	return false
}

terrain_generation_chunk_cache_store :: proc(
	view: ^world_async.ChunkVoxelView,
	key: biomes.FeatureGridKey,
	coord: world_async.ChunkCoord,
) {
	when TERRAIN_GENERATION_CHUNK_CACHE_ENABLED {
		cache := &state.terrain_generation_chunk_cache
		if !cache.initialized {
			return
		}

		sync.lock(&cache.mutex)
		defer sync.unlock(&cache.mutex)

		slot_index := 0
		oldest_tick := max(u64)
		for i := 0; i < TERRAIN_GENERATION_CHUNK_CACHE_CAPACITY; i += 1 {
			slot := &cache.slots[i]
			if slot.valid && slot.key == key && slot.coord == coord {
				slot_index = i
				break
			}
			if !slot.valid {
				slot_index = i
				break
			}
			if slot.last_used < oldest_tick {
				oldest_tick = slot.last_used
				slot_index = i
			}
		}

		cache.clock += 1
		slot := &cache.slots[slot_index]
		chunk_voxel_view_copy(&slot.view, view)
		slot.key = key
		slot.coord = coord
		slot.last_used = cache.clock
		slot.valid = true
	}
}

terrain_generation_cave_overlay_cache_init :: proc(allocator: mem.Allocator) {
	when TERRAIN_GENERATION_CAVE_OVERLAY_CACHE_ENABLED {
		cache := &state.terrain_generation_cave_overlay_cache
		sync.lock(&cache.mutex)
		defer sync.unlock(&cache.mutex)

		if cache.initialized {
			return
		}

		cache.slots = make(
			[]TerrainGenerationCaveOverlayCacheSlot,
			int(TERRAIN_GENERATION_CAVE_OVERLAY_CACHE_CAPACITY),
			allocator,
		)
		cache.initialized = true
	}
}

terrain_generation_cave_overlay_cache_destroy :: proc() {
	when TERRAIN_GENERATION_CAVE_OVERLAY_CACHE_ENABLED {
		cache := &state.terrain_generation_cave_overlay_cache
		if !cache.initialized {
			return
		}

		sync.lock(&cache.mutex)
		defer sync.unlock(&cache.mutex)

		_ = delete(cache.slots, state.persistent_allocator)
		cache.slots = nil
		cache.initialized = false
		cache.clock = 0
	}
}

terrain_generation_cave_overlay_cache_clear :: proc() {
	when TERRAIN_GENERATION_CAVE_OVERLAY_CACHE_ENABLED {
		cache := &state.terrain_generation_cave_overlay_cache
		if !cache.initialized {
			return
		}

		sync.lock(&cache.mutex)
		defer sync.unlock(&cache.mutex)

		for i := 0; i < len(cache.slots); i += 1 {
			cache.slots[i].valid = false
		}
		cache.clock = 0
	}
}

terrain_generation_cave_overlay_cache_capture_enabled :: proc() -> bool {
	when TERRAIN_BAKE_DEBUG_MATERIAL_FLAGS {
		return false
	}
	when TERRAIN_GENERATION_CAVE_OVERLAY_CACHE_ENABLED {
		return state.terrain_generation_cave_overlay_cache.initialized
	}
	return false
}

terrain_generation_cave_overlay_cache_try_apply :: proc(
	view: ^world_async.ChunkVoxelView,
	key: biomes.FeatureGridKey,
	coord: world_async.ChunkCoord,
) -> bool {
	when TERRAIN_GENERATION_CAVE_OVERLAY_CACHE_ENABLED {
		cache := &state.terrain_generation_cave_overlay_cache
		if !cache.initialized {
			return false
		}

		sync.lock(&cache.mutex)
		defer sync.unlock(&cache.mutex)

		for i := 0; i < len(cache.slots); i += 1 {
			slot := &cache.slots[i]
			if slot.valid && slot.key == key && slot.coord == coord {
				cache.clock += 1
				slot.last_used = cache.clock
				terrain_cave_chunk_overlay_apply(&slot.overlay, view)
				return true
			}
		}
	}
	return false
}

terrain_generation_cave_overlay_cache_store_from_base :: proc(
	final: ^world_async.ChunkVoxelView,
	key: biomes.FeatureGridKey,
	coord: world_async.ChunkCoord,
	base: ^TerrainCaveChunkOverlayBaseSnapshot,
) {
	when TERRAIN_GENERATION_CAVE_OVERLAY_CACHE_ENABLED {
		cache := &state.terrain_generation_cave_overlay_cache
		if !cache.initialized {
			return
		}

		scratch_allocator := runtime.heap_allocator()
		overlay := new(TerrainCaveChunkOverlay, scratch_allocator)
		defer {
			_ = mem.free(rawptr(overlay), scratch_allocator)
		}
		terrain_cave_chunk_overlay_build_from_base(overlay, final, base)

		sync.lock(&cache.mutex)
		defer sync.unlock(&cache.mutex)

		slot_index := 0
		oldest_tick := max(u64)
		for i := 0; i < len(cache.slots); i += 1 {
			slot := &cache.slots[i]
			if slot.valid && slot.key == key && slot.coord == coord {
				slot_index = i
				break
			}
			if !slot.valid {
				slot_index = i
				break
			}
			if slot.last_used < oldest_tick {
				oldest_tick = slot.last_used
				slot_index = i
			}
		}

		cache.clock += 1
		slot := &cache.slots[slot_index]
		slot.key = key
		slot.coord = coord
		slot.overlay = overlay^
		slot.last_used = cache.clock
		slot.valid = true
	}
}

terrain_generation_column_cache_clear :: proc() {
	when TERRAIN_GENERATION_COLUMN_CACHE_ENABLED {
		cache := &state.terrain_generation_column_cache
		sync.lock(&cache.mutex)
		defer sync.unlock(&cache.mutex)

		for i := 0; i < TERRAIN_GENERATION_COLUMN_CACHE_CAPACITY; i += 1 {
			cache.slots[i].valid = false
		}
		cache.clock = 0
	}
}

terrain_generation_column_cache_try_read :: proc(
	columns: []TerrainBiomeColumn,
	key: biomes.FeatureGridKey,
	coord: world_async.ChunkCoord,
) -> bool {
	when TERRAIN_GENERATION_COLUMN_CACHE_ENABLED {
		log.assertf(
			len(columns) == CHUNK_BLOCK_LENGTH * CHUNK_BLOCK_LENGTH,
			"column cache read expects %d columns, got %d",
			CHUNK_BLOCK_LENGTH * CHUNK_BLOCK_LENGTH,
			len(columns),
		)

		cache := &state.terrain_generation_column_cache
		sync.lock(&cache.mutex)
		defer sync.unlock(&cache.mutex)

		for i := 0; i < TERRAIN_GENERATION_COLUMN_CACHE_CAPACITY; i += 1 {
			slot := &cache.slots[i]
			if slot.valid &&
			   slot.key == key &&
			   slot.chunk_x == coord.x &&
			   slot.chunk_z == coord.z {
				cache.clock += 1
				slot.last_used = cache.clock
				mem.copy(
					raw_data(columns),
					raw_data(slot.columns[:]),
					int(len(columns) * size_of(TerrainBiomeColumn)),
				)
				return true
			}
		}
	}
	return false
}

terrain_generation_column_cache_store :: proc(
	columns: []TerrainBiomeColumn,
	key: biomes.FeatureGridKey,
	coord: world_async.ChunkCoord,
) {
	when TERRAIN_GENERATION_COLUMN_CACHE_ENABLED {
		log.assertf(
			len(columns) == CHUNK_BLOCK_LENGTH * CHUNK_BLOCK_LENGTH,
			"column cache store expects %d columns, got %d",
			CHUNK_BLOCK_LENGTH * CHUNK_BLOCK_LENGTH,
			len(columns),
		)

		cache := &state.terrain_generation_column_cache
		sync.lock(&cache.mutex)
		defer sync.unlock(&cache.mutex)

		slot_index := 0
		oldest_tick := max(u64)
		for i := 0; i < TERRAIN_GENERATION_COLUMN_CACHE_CAPACITY; i += 1 {
			slot := &cache.slots[i]
			if slot.valid &&
			   slot.key == key &&
			   slot.chunk_x == coord.x &&
			   slot.chunk_z == coord.z {
				slot_index = i
				break
			}
			if !slot.valid {
				slot_index = i
				break
			}
			if slot.last_used < oldest_tick {
				oldest_tick = slot.last_used
				slot_index = i
			}
		}

		cache.clock += 1
		slot := &cache.slots[slot_index]
		mem.copy(
			raw_data(slot.columns[:]),
			raw_data(columns),
			int(len(columns) * size_of(TerrainBiomeColumn)),
		)
		slot.key = key
		slot.chunk_x = coord.x
		slot.chunk_z = coord.z
		slot.last_used = cache.clock
		slot.valid = true
	}
}

//////////////////////////////////////
// Terrain Generation Region Cache Methods
/////////////////////////////////////

terrain_generation_key_make :: proc(seed: u32) -> biomes.FeatureGridKey {
	return biomes.feature_grid_key_make(u64(seed), TERRAIN_GENERATOR_VERSION)
}

terrain_generation_region_for_fill :: proc(
	key: biomes.FeatureGridKey,
	coord: biomes.GenerationRegionCoord,
) -> biomes.GenerationRegion {
	cache := &state.terrain_generation_region_cache

	sync.lock(&cache.mutex)
	cache.clock += 1
	stamp := cache.clock
	lru_index := u32(0)
	lru_stamp := max(u64)
	empty_index: i32 = -1
	for i := u32(0); i < TERRAIN_GENERATION_REGION_CACHE_CAPACITY; i += 1 {
		slot := &cache.slots[i]
		if slot.valid {
			if slot.key == key && slot.coord == coord {
				slot.last_used = stamp
				region := slot.region
				sync.unlock(&cache.mutex)
				return region
			}
			if slot.last_used < lru_stamp {
				lru_stamp = slot.last_used
				lru_index = i
			}
		} else if empty_index < 0 {
			empty_index = i32(i)
		}
	}
	sync.unlock(&cache.mutex)

	region := biomes.generation_region_build_for_terrain_fill(key, coord)

	sync.lock(&cache.mutex)
	cache.clock += 1
	target_index := lru_index
	if empty_index >= 0 {
		target_index = u32(empty_index)
	}
	cache.slots[target_index] = {
		valid     = true,
		key       = key,
		coord     = coord,
		region    = region,
		last_used = cache.clock,
	}
	sync.unlock(&cache.mutex)

	return region
}
