package biomes

import "core:log"
import math "core:math"

//////////////////////////////////////
// Generation Region Types
/////////////////////////////////////

// GenerationRegionCoord is the coarse world-space owner coordinate for disposable generation data.
GenerationRegionCoord :: IVec3

GenerationInfluenceMargins :: struct {
	surface_biome_blocks:              i32,
	subterranean_biome_blocks:         i32,
	surface_morphology_blocks:         i32,
	surface_decoration_blocks:         i32,
	surface_water_feature_blocks:      i32,
	subterranean_water_feature_blocks: i32,
	cave_network_blocks:               i32,
}

GenerationRegionSurfaceBiomeCell :: struct {
	feature:          FeaturePoint2,
	biome_id:         BiomeID,
	macro_zone:       SurfaceMacroZone,
	macro_feature_id: FeatureID,
}

GenerationRegionSubterraneanBiomeCell :: struct {
	feature:          FeaturePoint3,
	biome_id:         BiomeID,
	macro_zone:       SubterraneanMacroZone,
	depth_band:       SubterraneanDepthBand,
	macro_feature_id: FeatureID,
}

GenerationRegionQuery :: struct {
	bounds:                                 BlockBounds3,
	influence_margins:                      GenerationInfluenceMargins,
	surface_biome_owner_range:              FeatureGridOwnerRange2,
	subterranean_biome_owner_range:         FeatureGridOwnerRange3,
	surface_morphology_owner_range:         FeatureGridOwnerRange2,
	surface_decoration_owner_range:         FeatureGridOwnerRange2,
	surface_water_feature_owner_range:      FeatureGridOwnerRange2,
	subterranean_water_feature_owner_range: FeatureGridOwnerRange3,
	cave_network_owner_range:               FeatureGridOwnerRange3,
}

GenerationRegion :: struct {
	key:                                    FeatureGridKey,
	coord:                                  GenerationRegionCoord,
	bounds:                                 BlockBounds3,
	influence_margins:                      GenerationInfluenceMargins,
	surface_biome_owner_range:              FeatureGridOwnerRange2,
	subterranean_biome_owner_range:         FeatureGridOwnerRange3,
	surface_morphology_owner_range:         FeatureGridOwnerRange2,
	surface_decoration_owner_range:         FeatureGridOwnerRange2,
	surface_water_feature_owner_range:      FeatureGridOwnerRange2,
	subterranean_water_feature_owner_range: FeatureGridOwnerRange3,
	cave_network_owner_range:               FeatureGridOwnerRange3,
	surface_biome_cells:                    [GENERATION_REGION_SURFACE_BIOME_CELL_CAPACITY]GenerationRegionSurfaceBiomeCell,
	surface_biome_cell_count:               u32,
	subterranean_biome_cells:               [GENERATION_REGION_SUBTERRANEAN_BIOME_CELL_CAPACITY]GenerationRegionSubterraneanBiomeCell,
	subterranean_biome_cell_count:          u32,
	surface_morphology_features:            [GENERATION_REGION_SURFACE_MORPHOLOGY_FEATURE_CAPACITY]SurfaceMorphologyFeature,
	surface_morphology_feature_count:       u32,
	surface_decoration_features:            [GENERATION_REGION_SURFACE_DECORATION_FEATURE_CAPACITY]DecorationFeature,
	surface_decoration_feature_count:       u32,
	water_feature_nodes:                    [GENERATION_REGION_WATER_FEATURE_NODE_CAPACITY]WaterFeatureNode,
	water_feature_node_count:               u32,
	water_feature_segments:                 [GENERATION_REGION_WATER_FEATURE_SEGMENT_CAPACITY]WaterFeatureSegment,
	water_feature_segment_count:            u32,
	water_feature_anchors:                  [GENERATION_REGION_WATER_FEATURE_ANCHOR_CAPACITY]WaterFeatureAnchor,
	water_feature_anchor_count:             u32,
	cave_network_nodes:                     [GENERATION_REGION_CAVE_NETWORK_NODE_CAPACITY]CaveNetworkNode,
	cave_network_node_count:                u32,
	cave_network_edges:                     [GENERATION_REGION_CAVE_NETWORK_EDGE_CAPACITY]CaveNetworkEdge,
	cave_network_edge_count:                u32,
	cave_anchors:                           [GENERATION_REGION_CAVE_ANCHOR_CAPACITY]CaveAnchor,
	cave_anchor_count:                      u32,
}

//////////////////////////////////////
// Generation Region Constants
/////////////////////////////////////

GENERATION_REGION_BLOCK_LENGTH :: 512

// Margins include the neighbouring biome owner cells needed by nearest-cell sampling.
// Surface sampling keeps the legacy blend-band margin; subterranean sampling uses a
// full neighbouring owner shell after the coarser underground biome scale.
GENERATION_REGION_SURFACE_BIOME_MARGIN_BLOCKS :: 608
GENERATION_REGION_SUBTERRANEAN_BIOME_MARGIN_BLOCKS :: 768
GENERATION_REGION_SURFACE_WATER_FEATURE_MARGIN_BLOCKS :: HYDROLOGY_SURFACE_SAMPLE_MARGIN_BLOCKS
GENERATION_REGION_SUBTERRANEAN_WATER_FEATURE_MARGIN_BLOCKS ::
	HYDROLOGY_SUBTERRANEAN_SAMPLE_MARGIN_BLOCKS
GENERATION_REGION_CAVE_NETWORK_MARGIN_BLOCKS :: CAVE_NETWORK_SAMPLE_MARGIN_BLOCKS

GENERATION_REGION_DEFAULT_INFLUENCE_MARGINS :: GenerationInfluenceMargins {
	surface_biome_blocks              = GENERATION_REGION_SURFACE_BIOME_MARGIN_BLOCKS,
	subterranean_biome_blocks         = GENERATION_REGION_SUBTERRANEAN_BIOME_MARGIN_BLOCKS,
	surface_morphology_blocks         = SURFACE_MORPHOLOGY_INFLUENCE_MARGIN_BLOCKS,
	surface_decoration_blocks         = DECORATION_SURFACE_INFLUENCE_MARGIN_BLOCKS,
	surface_water_feature_blocks      = GENERATION_REGION_SURFACE_WATER_FEATURE_MARGIN_BLOCKS,
	subterranean_water_feature_blocks = GENERATION_REGION_SUBTERRANEAN_WATER_FEATURE_MARGIN_BLOCKS,
	cave_network_blocks               = GENERATION_REGION_CAVE_NETWORK_MARGIN_BLOCKS,
}

GENERATION_REGION_SURFACE_BIOME_CELL_CAPACITY :: 25
GENERATION_REGION_SUBTERRANEAN_BIOME_CELL_CAPACITY :: 125
GENERATION_REGION_SURFACE_DECORATION_FEATURE_CAPACITY :: 1024
GENERATION_REGION_WATER_FEATURE_NODE_CAPACITY :: 64
GENERATION_REGION_WATER_FEATURE_SEGMENT_CAPACITY :: 128
GENERATION_REGION_WATER_FEATURE_ANCHOR_CAPACITY :: 192
GENERATION_REGION_CAVE_NETWORK_NODE_CAPACITY :: 125
GENERATION_REGION_CAVE_NETWORK_EDGE_CAPACITY :: 375
GENERATION_REGION_CAVE_ANCHOR_CAPACITY :: 320

#assert(GENERATION_REGION_BLOCK_LENGTH > SURFACE_MICRO_GRID_CONFIG.cell_size_blocks)
#assert(GENERATION_REGION_BLOCK_LENGTH > 64)

//////////////////////////////////////
// Generation Region Coordinate Methods
/////////////////////////////////////

generation_region_coord_from_block :: proc(
	block_x, block_y, block_z: i32,
) -> GenerationRegionCoord {
	return {
		x = math.floor_div(block_x, GENERATION_REGION_BLOCK_LENGTH),
		y = math.floor_div(block_y, GENERATION_REGION_BLOCK_LENGTH),
		z = math.floor_div(block_z, GENERATION_REGION_BLOCK_LENGTH),
	}
}

generation_region_coord_from_block_bounds :: proc(bounds: BlockBounds3) -> GenerationRegionCoord {
	feature_grid_block_bounds_validate(bounds)

	min_coord := generation_region_coord_from_block(bounds.min.x, bounds.min.y, bounds.min.z)
	max_coord := generation_region_coord_from_block(
		bounds.max.x - 1,
		bounds.max.y - 1,
		bounds.max.z - 1,
	)
	log.assert(
		min_coord == max_coord,
		"block bounds cross Generation Region boundaries and must be split first",
	)
	return min_coord
}

generation_region_bounds_from_coord :: proc(coord: GenerationRegionCoord) -> BlockBounds3 {
	min_bound := IVec3 {
		x = coord.x * GENERATION_REGION_BLOCK_LENGTH,
		y = coord.y * GENERATION_REGION_BLOCK_LENGTH,
		z = coord.z * GENERATION_REGION_BLOCK_LENGTH,
	}
	return {
		min = min_bound,
		max = {
			x = min_bound.x + GENERATION_REGION_BLOCK_LENGTH,
			y = min_bound.y + GENERATION_REGION_BLOCK_LENGTH,
			z = min_bound.z + GENERATION_REGION_BLOCK_LENGTH,
		},
	}
}

generation_region_surface_bounds_from_bounds :: proc(bounds: BlockBounds3) -> BlockBounds2 {
	feature_grid_block_bounds_validate(bounds)
	return {min = {x = bounds.min.x, z = bounds.min.z}, max = {x = bounds.max.x, z = bounds.max.z}}
}

//////////////////////////////////////
// Generation Region Build Methods
/////////////////////////////////////

generation_region_build_with_margins_into :: proc(
	region: ^GenerationRegion,
	key: FeatureGridKey,
	coord: GenerationRegionCoord,
	influence_margins: GenerationInfluenceMargins,
) {
	generation_region_influence_margins_validate(influence_margins)

	region^ = GenerationRegion {
		key               = key,
		coord             = coord,
		bounds            = generation_region_bounds_from_coord(coord),
		influence_margins = influence_margins,
	}
	generation_region_surface_biome_cells_fill(region)
	generation_region_subterranean_biome_cells_fill(region)
	generation_region_surface_morphology_features_fill(region)
	generation_region_surface_decorations_fill(region)
	generation_region_water_features_fill(region)
	generation_region_cave_networks_fill(region)
}

generation_region_build_for_terrain_fill :: proc(
	key: FeatureGridKey,
	coord: GenerationRegionCoord,
) -> GenerationRegion {
	region := GenerationRegion{}
	generation_region_build_for_terrain_fill_into(&region, key, coord)
	return region
}

generation_region_build_for_terrain_fill_into :: proc(
	region: ^GenerationRegion,
	key: FeatureGridKey,
	coord: GenerationRegionCoord,
) {
	region^ = GenerationRegion {
		key               = key,
		coord             = coord,
		bounds            = generation_region_bounds_from_coord(coord),
		influence_margins = GENERATION_REGION_DEFAULT_INFLUENCE_MARGINS,
	}
	generation_region_surface_biome_cells_fill(region)
	generation_region_surface_morphology_features_fill(region)
	generation_region_surface_decorations_fill(region)
	generation_region_water_features_fill(region)
	generation_region_cave_networks_fill(region)
}

generation_region_influence_margins_validate :: proc(margins: GenerationInfluenceMargins) {
	log.assert(margins.surface_biome_blocks >= 0, "surface biome margin must not be negative")
	log.assert(
		margins.subterranean_biome_blocks >= 0,
		"subterranean biome margin must not be negative",
	)
	log.assert(
		margins.surface_morphology_blocks >= 0,
		"surface morphology margin must not be negative",
	)
	log.assert(
		margins.surface_decoration_blocks >= 0,
		"surface decoration margin must not be negative",
	)
	log.assert(
		margins.surface_water_feature_blocks >= 0,
		"surface water feature margin must not be negative",
	)
	log.assert(
		margins.subterranean_water_feature_blocks >= 0,
		"subterranean water feature margin must not be negative",
	)
	log.assert(margins.cave_network_blocks >= 0, "cave network margin must not be negative")
}

generation_region_surface_biome_cells_fill :: proc(region: ^GenerationRegion) {
	config := feature_grid_config_for(.Surface, .Biome)
	surface_bounds := generation_region_surface_bounds_from_bounds(region.bounds)
	region.surface_biome_owner_range = feature_grid_owner_range_from_block_bounds(
		surface_bounds,
		region.influence_margins.surface_biome_blocks,
		config,
	)
	cell_count_required := feature_grid_owner_range_count(region.surface_biome_owner_range)
	log.assertf(
		cell_count_required <= GENERATION_REGION_SURFACE_BIOME_CELL_CAPACITY,
		"Generation Region surface biome cell capacity too small: required=%d capacity=%d",
		cell_count_required,
		GENERATION_REGION_SURFACE_BIOME_CELL_CAPACITY,
	)

	count: u32
	for z := region.surface_biome_owner_range.min.z;
	    z <= region.surface_biome_owner_range.max.z;
	    z += 1 {
		for x := region.surface_biome_owner_range.min.x;
		    x <= region.surface_biome_owner_range.max.x;
		    x += 1 {
			owner := FeatureGridCoord2 {
				x = x,
				z = z,
			}
			region.surface_biome_cells[count] = generation_region_surface_biome_cell_from_owner(
				region.key,
				owner,
			)
			count += 1
		}
	}
	region.surface_biome_cell_count = count
}

generation_region_subterranean_biome_cells_fill :: proc(region: ^GenerationRegion) {
	config := feature_grid_config_for(.Subterranean, .Biome)
	region.subterranean_biome_owner_range = feature_grid_owner_range_from_block_bounds(
		region.bounds,
		region.influence_margins.subterranean_biome_blocks,
		config,
	)
	cell_count_required := feature_grid_owner_range_count(region.subterranean_biome_owner_range)
	log.assertf(
		cell_count_required <= GENERATION_REGION_SUBTERRANEAN_BIOME_CELL_CAPACITY,
		"Generation Region subterranean biome cell capacity too small: required=%d capacity=%d",
		cell_count_required,
		GENERATION_REGION_SUBTERRANEAN_BIOME_CELL_CAPACITY,
	)

	count: u32
	for z := region.subterranean_biome_owner_range.min.z;
	    z <= region.subterranean_biome_owner_range.max.z;
	    z += 1 {
		for y := region.subterranean_biome_owner_range.min.y;
		    y <= region.subterranean_biome_owner_range.max.y;
		    y += 1 {
			for x := region.subterranean_biome_owner_range.min.x;
			    x <= region.subterranean_biome_owner_range.max.x;
			    x += 1 {
				owner := FeatureGridCoord3 {
					x = x,
					y = y,
					z = z,
				}
				region.subterranean_biome_cells[count] =
					generation_region_subterranean_biome_cell_from_owner(region.key, owner)
				count += 1
			}
		}
	}
	region.subterranean_biome_cell_count = count
}

generation_region_surface_morphology_features_fill :: proc(region: ^GenerationRegion) {
	surface_bounds := generation_region_surface_bounds_from_bounds(region.bounds)
	region.surface_morphology_owner_range = feature_grid_owner_range_from_block_bounds(
		surface_bounds,
		region.influence_margins.surface_morphology_blocks,
		SURFACE_MORPHOLOGY_OWNER_GRID_CONFIG,
	)
	owner_count_required := feature_grid_owner_range_count(region.surface_morphology_owner_range)
	log.assertf(
		owner_count_required <= GENERATION_REGION_SURFACE_MORPHOLOGY_FEATURE_CAPACITY,
		"Generation Region surface morphology capacity too small: required=%d capacity=%d",
		owner_count_required,
		GENERATION_REGION_SURFACE_MORPHOLOGY_FEATURE_CAPACITY,
	)

	count: u32
	for z := region.surface_morphology_owner_range.min.z;
	    z <= region.surface_morphology_owner_range.max.z;
	    z += 1 {
		for x := region.surface_morphology_owner_range.min.x;
		    x <= region.surface_morphology_owner_range.max.x;
		    x += 1 {
			owner := FeatureGridCoord2 {
				x = x,
				z = z,
			}
			feature, found := surface_morphology_feature_from_owner(region.key, owner)
			if !found {
				continue
			}
			region.surface_morphology_features[count] = feature
			count += 1
		}
	}
	region.surface_morphology_feature_count = count
}

generation_region_surface_decorations_fill :: proc(region: ^GenerationRegion) {
	surface_bounds := generation_region_surface_bounds_from_bounds(region.bounds)
	region.surface_decoration_owner_range = feature_grid_owner_range_from_block_bounds(
		surface_bounds,
		region.influence_margins.surface_decoration_blocks,
		DECORATION_SURFACE_GRID_CONFIG,
	)
	owner_count_required := feature_grid_owner_range_count(region.surface_decoration_owner_range)
	log.assertf(
		owner_count_required * u32(DECORATION_SURFACE_SLOT_COUNT_MAX) <=
		GENERATION_REGION_SURFACE_DECORATION_FEATURE_CAPACITY,
		"Generation Region surface decoration capacity too small: required=%d capacity=%d",
		owner_count_required * u32(DECORATION_SURFACE_SLOT_COUNT_MAX),
		GENERATION_REGION_SURFACE_DECORATION_FEATURE_CAPACITY,
	)

	count: u32
	for z := region.surface_decoration_owner_range.min.z;
	    z <= region.surface_decoration_owner_range.max.z;
	    z += 1 {
		for x := region.surface_decoration_owner_range.min.x;
		    x <= region.surface_decoration_owner_range.max.x;
		    x += 1 {
			owner := FeatureGridCoord2 {
				x = x,
				z = z,
			}
			for slot_index := u8(0);
			    slot_index < DECORATION_SURFACE_SLOT_COUNT_MAX;
			    slot_index += 1 {
				feature, found := generation_region_surface_decoration_feature_from_owner_slot(
					region,
					owner,
					slot_index,
				)
				if !found {
					continue
				}
				region.surface_decoration_features[count] = feature
				count += 1
			}
		}
	}
	region.surface_decoration_feature_count = count
}

generation_region_surface_decoration_feature_from_owner_slot :: proc(
	region: ^GenerationRegion,
	owner: FeatureGridCoord2,
	slot_index: u8,
) -> (
	feature: DecorationFeature,
	found: bool,
) {
	point := decoration_surface_slot_point_from_owner(region.key, owner, slot_index)
	biome_id, biome_found := generation_region_nearest_surface_biome_id(region, point.x, point.z)
	if !biome_found {
		return
	}

	placement, placement_found := decoration_surface_placement_profile_for_biome(biome_id)
	if !placement_found || slot_index >= placement.slot_count {
		return
	}
	patch_strength := decoration_surface_patch_strength_for_point(region.key, point, biome_id)
	density_class := decoration_surface_density_class_from_strength(patch_strength)
	chance := decoration_surface_acceptance_chance(placement, density_class)
	roll := feature_grid_unit_f32(u64(point.id), DECORATION_SURFACE_ROLL_SALT)
	if roll > chance {
		return
	}

	feature = decoration_surface_feature_make(
		point,
		owner,
		slot_index,
		biome_id,
		placement,
		density_class,
	)
	found = true
	return
}

generation_region_nearest_surface_biome_id :: proc(
	region: ^GenerationRegion,
	block_x, block_z: f32,
) -> (
	biome_id: BiomeID,
	found: bool,
) {
	best_distance_sq := BIOME_FIELD_NO_DISTANCE
	for i := u32(0); i < region.surface_biome_cell_count; i += 1 {
		cell := region.surface_biome_cells[i]
		dx := cell.feature.x - block_x
		dz := cell.feature.z - block_z
		distance_sq := dx * dx + dz * dz
		if distance_sq >= best_distance_sq {
			continue
		}
		best_distance_sq = distance_sq
		biome_id = cell.biome_id
		found = true
	}
	return
}

generation_region_water_features_fill :: proc(region: ^GenerationRegion) {
	surface_bounds := generation_region_surface_bounds_from_bounds(region.bounds)
	region.surface_water_feature_owner_range = feature_grid_owner_range_from_block_bounds(
		surface_bounds,
		region.influence_margins.surface_water_feature_blocks,
		HYDROLOGY_SURFACE_GRAPH_GRID_CONFIG,
	)
	region.subterranean_water_feature_owner_range = feature_grid_owner_range_from_block_bounds(
		region.bounds,
		region.influence_margins.subterranean_water_feature_blocks,
		HYDROLOGY_SUBTERRANEAN_GRAPH_GRID_CONFIG,
	)

	surface_node_count_required := feature_grid_owner_range_count(
		region.surface_water_feature_owner_range,
	)
	subterranean_node_count_required := feature_grid_owner_range_count(
		region.subterranean_water_feature_owner_range,
	)
	node_count_required := surface_node_count_required + subterranean_node_count_required
	log.assertf(
		node_count_required <= GENERATION_REGION_WATER_FEATURE_NODE_CAPACITY,
		"Generation Region water feature node capacity too small: required=%d capacity=%d",
		node_count_required,
		GENERATION_REGION_WATER_FEATURE_NODE_CAPACITY,
	)
	segment_count_required :=
		surface_node_count_required * 2 + subterranean_node_count_required * 3
	log.assertf(
		segment_count_required <= GENERATION_REGION_WATER_FEATURE_SEGMENT_CAPACITY,
		"Generation Region water feature segment capacity too small: required=%d capacity=%d",
		segment_count_required,
		GENERATION_REGION_WATER_FEATURE_SEGMENT_CAPACITY,
	)
	log.assertf(
		node_count_required + segment_count_required <=
		GENERATION_REGION_WATER_FEATURE_ANCHOR_CAPACITY,
		"Generation Region water feature anchor capacity too small: required=%d capacity=%d",
		node_count_required + segment_count_required,
		GENERATION_REGION_WATER_FEATURE_ANCHOR_CAPACITY,
	)

	for z := region.surface_water_feature_owner_range.min.z;
	    z <= region.surface_water_feature_owner_range.max.z;
	    z += 1 {
		for x := region.surface_water_feature_owner_range.min.x;
		    x <= region.surface_water_feature_owner_range.max.x;
		    x += 1 {
			owner := FeatureGridCoord2 {
				x = x,
				z = z,
			}
			node := water_feature_surface_node_from_owner(region.key, owner)
			if !water_feature_surface_node_should_emit(region.key, node) {
				continue
			}
			generation_region_water_feature_node_append(region, node)

			x_neighbor := FeatureGridCoord2 {
				x = x + 1,
				z = z,
			}
			z_neighbor := FeatureGridCoord2 {
				x = x,
				z = z + 1,
			}
			x_segment, x_segment_exists := water_feature_surface_segment_from_owners(
				region.key,
				owner,
				x_neighbor,
			)
			if x_segment_exists {
				generation_region_water_feature_segment_append(region, x_segment)
			}
			z_segment, z_segment_exists := water_feature_surface_segment_from_owners(
				region.key,
				owner,
				z_neighbor,
			)
			if z_segment_exists {
				generation_region_water_feature_segment_append(region, z_segment)
			}
		}
	}

	for z := region.subterranean_water_feature_owner_range.min.z;
	    z <= region.subterranean_water_feature_owner_range.max.z;
	    z += 1 {
		for y := region.subterranean_water_feature_owner_range.min.y;
		    y <= region.subterranean_water_feature_owner_range.max.y;
		    y += 1 {
			for x := region.subterranean_water_feature_owner_range.min.x;
			    x <= region.subterranean_water_feature_owner_range.max.x;
			    x += 1 {
				owner := FeatureGridCoord3 {
					x = x,
					y = y,
					z = z,
				}
				node := water_feature_subterranean_node_from_owner(region.key, owner)
				if !water_feature_subterranean_node_should_emit(node) {
					continue
				}
				generation_region_water_feature_node_append(region, node)

				x_neighbor := FeatureGridCoord3 {
					x = x + 1,
					y = y,
					z = z,
				}
				y_neighbor := FeatureGridCoord3 {
					x = x,
					y = y + 1,
					z = z,
				}
				z_neighbor := FeatureGridCoord3 {
					x = x,
					y = y,
					z = z + 1,
				}
				x_segment, x_segment_exists := water_feature_subterranean_segment_from_owners(
					region.key,
					owner,
					x_neighbor,
				)
				if x_segment_exists {
					generation_region_water_feature_segment_append(region, x_segment)
				}
				y_segment, y_segment_exists := water_feature_subterranean_segment_from_owners(
					region.key,
					owner,
					y_neighbor,
				)
				if y_segment_exists {
					generation_region_water_feature_segment_append(region, y_segment)
				}
				z_segment, z_segment_exists := water_feature_subterranean_segment_from_owners(
					region.key,
					owner,
					z_neighbor,
				)
				if z_segment_exists {
					generation_region_water_feature_segment_append(region, z_segment)
				}
			}
		}
	}

	for i := u32(0); i < region.water_feature_node_count; i += 1 {
		generation_region_water_feature_anchor_append(
			region,
			water_feature_node_anchor(region.water_feature_nodes[i]),
		)
	}
	for i := u32(0); i < region.water_feature_segment_count; i += 1 {
		generation_region_water_feature_anchor_append(
			region,
			water_feature_segment_anchor(region.water_feature_segments[i]),
		)
	}
}

generation_region_water_feature_node_append :: proc(
	region: ^GenerationRegion,
	node: WaterFeatureNode,
) {
	log.assert(
		region.water_feature_node_count < GENERATION_REGION_WATER_FEATURE_NODE_CAPACITY,
		"Generation Region water feature node capacity exceeded",
	)
	region.water_feature_nodes[region.water_feature_node_count] = node
	region.water_feature_node_count += 1
}

generation_region_water_feature_segment_append :: proc(
	region: ^GenerationRegion,
	segment: WaterFeatureSegment,
) {
	log.assert(
		region.water_feature_segment_count < GENERATION_REGION_WATER_FEATURE_SEGMENT_CAPACITY,
		"Generation Region water feature segment capacity exceeded",
	)
	region.water_feature_segments[region.water_feature_segment_count] = segment
	region.water_feature_segment_count += 1
}

generation_region_water_feature_anchor_append :: proc(
	region: ^GenerationRegion,
	anchor: WaterFeatureAnchor,
) {
	log.assert(
		region.water_feature_anchor_count < GENERATION_REGION_WATER_FEATURE_ANCHOR_CAPACITY,
		"Generation Region water feature anchor capacity exceeded",
	)
	region.water_feature_anchors[region.water_feature_anchor_count] = anchor
	region.water_feature_anchor_count += 1
}

generation_region_cave_networks_fill :: proc(region: ^GenerationRegion) {
	region.cave_network_owner_range = feature_grid_owner_range_from_block_bounds(
		region.bounds,
		region.influence_margins.cave_network_blocks,
		CAVE_NETWORK_GRID_CONFIG,
	)

	node_count_required := feature_grid_owner_range_count(region.cave_network_owner_range)
	log.assertf(
		node_count_required <= GENERATION_REGION_CAVE_NETWORK_NODE_CAPACITY,
		"Generation Region Cave Network node capacity too small: required=%d capacity=%d",
		node_count_required,
		GENERATION_REGION_CAVE_NETWORK_NODE_CAPACITY,
	)
	log.assertf(
		node_count_required * 3 <= GENERATION_REGION_CAVE_NETWORK_EDGE_CAPACITY,
		"Generation Region Cave Network edge capacity too small: required=%d capacity=%d",
		node_count_required * 3,
		GENERATION_REGION_CAVE_NETWORK_EDGE_CAPACITY,
	)

	for z := region.cave_network_owner_range.min.z;
	    z <= region.cave_network_owner_range.max.z;
	    z += 1 {
		for y := region.cave_network_owner_range.min.y;
		    y <= region.cave_network_owner_range.max.y;
		    y += 1 {
			for x := region.cave_network_owner_range.min.x;
			    x <= region.cave_network_owner_range.max.x;
			    x += 1 {
				owner := FeatureGridCoord3 {
					x = x,
					y = y,
					z = z,
				}
				node := cave_network_node_from_owner(region.key, owner)
				generation_region_cave_network_node_append(region, node)
				if cave_node_should_emit_anchor(node) {
					generation_region_cave_anchor_append(
						region,
						cave_anchor_from_node(region.key, node),
					)
				}
			}
		}
	}

	generation_region_cave_network_connected_edges_fill(region)

	for i := u32(0); i < region.water_feature_anchor_count; i += 1 {
		generation_region_cave_anchor_append(
			region,
			cave_anchor_from_water_anchor(region.water_feature_anchors[i]),
		)
	}
}

generation_region_cave_network_node_append :: proc(
	region: ^GenerationRegion,
	node: CaveNetworkNode,
) {
	log.assert(
		region.cave_network_node_count < GENERATION_REGION_CAVE_NETWORK_NODE_CAPACITY,
		"Generation Region Cave Network node capacity exceeded",
	)
	region.cave_network_nodes[region.cave_network_node_count] = node
	region.cave_network_node_count += 1
}

generation_region_cave_network_connected_edges_fill :: proc(region: ^GenerationRegion) {
	if region.cave_network_node_count <= 1 {
		return
	}

	eligible: [GENERATION_REGION_CAVE_NETWORK_NODE_CAPACITY]bool
	connected: [GENERATION_REGION_CAVE_NETWORK_NODE_CAPACITY]bool
	eligible_count: u32
	start_index: u32
	start_found := false
	for i := u32(0); i < region.cave_network_node_count; i += 1 {
		node := region.cave_network_nodes[i]
		if node.role == .Sealed_Secret {
			continue
		}
		eligible[i] = true
		eligible_count += 1
		if !start_found {
			start_index = i
			start_found = true
		}
	}
	if eligible_count <= 1 || !start_found {
		return
	}

	connected[start_index] = true
	connected_count := u32(1)
	for connected_count < eligible_count {
		from_index, to_index, found := generation_region_cave_network_mst_edge_select(
			region,
			eligible,
			connected,
		)
		if !found {
			break
		}
		edge := cave_network_edge_from_nodes(
			region.cave_network_nodes[from_index],
			region.cave_network_nodes[to_index],
		)
		generation_region_cave_network_edge_append(region, edge)
		connected[to_index] = true
		connected_count += 1
	}

	generation_region_cave_network_loop_edges_fill(region, eligible, eligible_count)
	generation_region_cave_network_local_edges_fill(region, eligible)
	generation_region_cave_network_seam_edges_fill(region, eligible)
}

generation_region_cave_network_mst_edge_select :: proc(
	region: ^GenerationRegion,
	eligible: [GENERATION_REGION_CAVE_NETWORK_NODE_CAPACITY]bool,
	connected: [GENERATION_REGION_CAVE_NETWORK_NODE_CAPACITY]bool,
) -> (
	from_index, to_index: u32,
	found: bool,
) {
	best_weight := max(f32)
	for i := u32(0); i < region.cave_network_node_count; i += 1 {
		if !eligible[i] || !connected[i] {
			continue
		}
		from_node := region.cave_network_nodes[i]
		for j := u32(0); j < region.cave_network_node_count; j += 1 {
			if !eligible[j] || connected[j] {
				continue
			}
			to_node := region.cave_network_nodes[j]
			weight := generation_region_cave_network_edge_weight(from_node, to_node)
			if weight < best_weight {
				best_weight = weight
				from_index = i
				to_index = j
				found = true
			}
		}
	}
	return
}

generation_region_cave_network_loop_edges_fill :: proc(
	region: ^GenerationRegion,
	eligible: [GENERATION_REGION_CAVE_NETWORK_NODE_CAPACITY]bool,
	eligible_count: u32,
) {
	if eligible_count <= 2 {
		return
	}
	target_loop_count :=
		(eligible_count * CAVE_NETWORK_GRAPH_LOOP_TARGET_NUMERATOR) /
		CAVE_NETWORK_GRAPH_LOOP_TARGET_DENOMINATOR
	if target_loop_count == 0 {
		target_loop_count = 1
	}

	loop_count: u32
	for loop_count < target_loop_count &&
	    region.cave_network_edge_count < GENERATION_REGION_CAVE_NETWORK_EDGE_CAPACITY {
		from_index, to_index, found := generation_region_cave_network_loop_edge_select(
			region,
			eligible,
		)
		if !found {
			break
		}
		edge := cave_network_edge_from_nodes(
			region.cave_network_nodes[from_index],
			region.cave_network_nodes[to_index],
		)
		generation_region_cave_network_edge_append(region, edge)
		loop_count += 1
	}
}

generation_region_cave_network_loop_edge_select :: proc(
	region: ^GenerationRegion,
	eligible: [GENERATION_REGION_CAVE_NETWORK_NODE_CAPACITY]bool,
) -> (
	from_index, to_index: u32,
	found: bool,
) {
	best_weight := max(f32)
	for i := u32(0); i < region.cave_network_node_count; i += 1 {
		if !eligible[i] {
			continue
		}
		from_node := region.cave_network_nodes[i]
		for j := i + 1; j < region.cave_network_node_count; j += 1 {
			if !eligible[j] {
				continue
			}
			to_node := region.cave_network_nodes[j]
			if generation_region_cave_network_edge_exists(region, from_node.id, to_node.id) {
				continue
			}
			edge := cave_network_edge_from_nodes(from_node, to_node)
			roll := feature_grid_unit_f32(u64(edge.id), CAVE_NETWORK_EDGE_ROLL_SALT)
			if roll > CAVE_NETWORK_GRAPH_LOOP_ROLL_MAX {
				continue
			}
			base_weight := generation_region_cave_network_edge_weight(from_node, to_node)
			if base_weight > CAVE_NETWORK_GRAPH_LOOP_MAX_WEIGHT_BLOCKS {
				continue
			}
			jitter := feature_grid_unit_f32(u64(edge.id), CAVE_NETWORK_EDGE_KIND_SALT)
			weight :=
				base_weight *
				regional_terrain_field_lerp(
					1.0 - CAVE_NETWORK_GRAPH_LOOP_WEIGHT_JITTER_SCALE,
					1.0 + CAVE_NETWORK_GRAPH_LOOP_WEIGHT_JITTER_SCALE,
					jitter,
				)
			if weight < best_weight {
				best_weight = weight
				from_index = i
				to_index = j
				found = true
			}
		}
	}
	return
}

generation_region_cave_network_local_edges_fill :: proc(
	region: ^GenerationRegion,
	eligible: [GENERATION_REGION_CAVE_NETWORK_NODE_CAPACITY]bool,
) {
	for i := u32(0); i < region.cave_network_node_count; i += 1 {
		if !eligible[i] {
			continue
		}
		from_node := region.cave_network_nodes[i]
		for j := i + 1; j < region.cave_network_node_count; j += 1 {
			if !eligible[j] {
				continue
			}
			to_node := region.cave_network_nodes[j]
			if !generation_region_cave_network_local_edge_should_exist(from_node, to_node) {
				continue
			}
			if generation_region_cave_network_edge_exists(region, from_node.id, to_node.id) {
				continue
			}
			if region.cave_network_edge_count >= GENERATION_REGION_CAVE_NETWORK_EDGE_CAPACITY {
				return
			}
			generation_region_cave_network_edge_append(
				region,
				cave_network_edge_from_nodes(from_node, to_node),
			)
		}
	}
}

generation_region_cave_network_seam_edges_fill :: proc(
	region: ^GenerationRegion,
	eligible: [GENERATION_REGION_CAVE_NETWORK_NODE_CAPACITY]bool,
) {
	for axis in 0 ..< 3 {
		generation_region_cave_network_seam_edge_fill(
			region,
			eligible,
			axis,
			generation_region_bounds_axis_min(region.bounds, axis),
		)
		generation_region_cave_network_seam_edge_fill(
			region,
			eligible,
			axis,
			generation_region_bounds_axis_max(region.bounds, axis),
		)
	}
}

generation_region_cave_network_seam_edge_fill :: proc(
	region: ^GenerationRegion,
	eligible: [GENERATION_REGION_CAVE_NETWORK_NODE_CAPACITY]bool,
	axis: int,
	face_block: f32,
) {
	from_index, to_index, found := generation_region_cave_network_seam_edge_select(
		region,
		eligible,
		axis,
		face_block,
	)
	if !found {
		return
	}
	edge := cave_network_seam_edge_from_nodes(
		region.cave_network_nodes[from_index],
		region.cave_network_nodes[to_index],
	)
	existing_index, existing_found := generation_region_cave_network_edge_pair_index(
		region,
		edge.from_node_id,
		edge.to_node_id,
	)
	if existing_found {
		region.cave_network_edges[existing_index] = edge
		return
	}
	if generation_region_cave_network_edge_id_exists(region, edge.id) {
		return
	}
	if region.cave_network_edge_count >= GENERATION_REGION_CAVE_NETWORK_EDGE_CAPACITY {
		return
	}
	generation_region_cave_network_edge_append(region, edge)
}

generation_region_cave_network_seam_edge_select :: proc(
	region: ^GenerationRegion,
	eligible: [GENERATION_REGION_CAVE_NETWORK_NODE_CAPACITY]bool,
	axis: int,
	face_block: f32,
) -> (
	from_index, to_index: u32,
	found: bool,
) {
	best_score := max(f32)
	for i := u32(0); i < region.cave_network_node_count; i += 1 {
		if !eligible[i] {
			continue
		}
		a_node := region.cave_network_nodes[i]
		if !generation_region_cave_network_node_allows_seam_edge(a_node) {
			continue
		}
		a_axis := generation_region_cave_network_node_axis_value(a_node, axis)
		if math.abs(a_axis - face_block) > CAVE_NETWORK_GRAPH_SEAM_EDGE_FACE_MARGIN_BLOCKS {
			continue
		}
		for j := i + 1; j < region.cave_network_node_count; j += 1 {
			if !eligible[j] {
				continue
			}
			b_node := region.cave_network_nodes[j]
			if !generation_region_cave_network_node_allows_seam_edge(b_node) {
				continue
			}
			b_axis := generation_region_cave_network_node_axis_value(b_node, axis)
			if math.abs(b_axis - face_block) > CAVE_NETWORK_GRAPH_SEAM_EDGE_FACE_MARGIN_BLOCKS {
				continue
			}
			if !generation_region_cave_network_nodes_straddle_face(a_axis, b_axis, face_block) {
				continue
			}

			local_from_index := i
			local_to_index := j
			from_node := a_node
			to_node := b_node
			if a_axis > b_axis {
				local_from_index = j
				local_to_index = i
				from_node = b_node
				to_node = a_node
			}

			weight := generation_region_cave_network_edge_weight(from_node, to_node)
			if weight > CAVE_NETWORK_GRAPH_SEAM_EDGE_MAX_WEIGHT_BLOCKS {
				continue
			}
			score := generation_region_cave_network_seam_edge_score(from_node, to_node, weight)
			if score < best_score {
				best_score = score
				from_index = local_from_index
				to_index = local_to_index
				found = true
			}
		}
	}
	return
}

generation_region_cave_network_seam_edge_score :: proc(
	from_node, to_node: CaveNetworkNode,
	base_weight: f32,
) -> f32 {
	edge := cave_network_seam_edge_from_nodes(from_node, to_node)
	jitter := feature_grid_unit_f32(
		u64(edge.id),
		CAVE_NETWORK_EDGE_KIND_SALT ~ CAVE_NETWORK_EDGE_ROLL_SALT,
	)
	score :=
		base_weight *
		regional_terrain_field_lerp(
			1.0 - CAVE_NETWORK_GRAPH_SEAM_EDGE_WEIGHT_JITTER_SCALE,
			1.0 + CAVE_NETWORK_GRAPH_SEAM_EDGE_WEIGHT_JITTER_SCALE,
			jitter,
		)
	if generation_region_cave_network_node_prefers_seam_edge(from_node) {
		score -= CAVE_NETWORK_GRAPH_SEAM_EDGE_REQUIRED_BONUS_BLOCKS
	}
	if generation_region_cave_network_node_prefers_seam_edge(to_node) {
		score -= CAVE_NETWORK_GRAPH_SEAM_EDGE_REQUIRED_BONUS_BLOCKS
	}
	return math.max(f32(1), score)
}

generation_region_cave_network_node_prefers_seam_edge :: proc(node: CaveNetworkNode) -> bool {
	return(
		cave_region_role_requires_connectivity(node.role) ||
		node.kind == .Entrance ||
		node.kind == .Vertical_Shaft ||
		node.kind == .Underground_Lake ||
		node.kind == .River_Junction \
	)
}

generation_region_cave_network_node_allows_seam_edge :: proc(node: CaveNetworkNode) -> bool {
	return node.owner.y >= 0
}

generation_region_cave_network_nodes_straddle_face :: proc(
	a_axis, b_axis, face_block: f32,
) -> bool {
	return(
		(a_axis < face_block && b_axis >= face_block) ||
		(b_axis < face_block && a_axis >= face_block) \
	)
}

generation_region_cave_network_node_axis_value :: proc(node: CaveNetworkNode, axis: int) -> f32 {
	if axis == 0 {
		return node.x
	}
	if axis == 1 {
		return node.y
	}
	return node.z
}

generation_region_bounds_axis_min :: proc(bounds: BlockBounds3, axis: int) -> f32 {
	if axis == 0 {
		return f32(bounds.min.x)
	}
	if axis == 1 {
		return f32(bounds.min.y)
	}
	return f32(bounds.min.z)
}

generation_region_bounds_axis_max :: proc(bounds: BlockBounds3, axis: int) -> f32 {
	if axis == 0 {
		return f32(bounds.max.x)
	}
	if axis == 1 {
		return f32(bounds.max.y)
	}
	return f32(bounds.max.z)
}

generation_region_cave_network_edge_weight :: proc(from_node, to_node: CaveNetworkNode) -> f32 {
	dx := to_node.x - from_node.x
	dy := to_node.y - from_node.y
	dz := to_node.z - from_node.z
	horizontal := math.sqrt_f32(dx * dx + dz * dz)
	vertical := math.abs(dy) * CAVE_NETWORK_GRAPH_VERTICAL_WEIGHT_SCALE
	weight := math.sqrt_f32(horizontal * horizontal + vertical * vertical)
	if from_node.biome_id != to_node.biome_id {
		weight += CAVE_NETWORK_GRAPH_BIOME_MISMATCH_WEIGHT_BLOCKS
	}
	if cave_region_role_requires_connectivity(from_node.role) ||
	   cave_region_role_requires_connectivity(to_node.role) {
		weight -= CAVE_NETWORK_GRAPH_REQUIRED_WEIGHT_BONUS_BLOCKS
	}
	return math.max(f32(1), weight)
}

generation_region_cave_network_local_edge_should_exist :: proc(
	from_node, to_node: CaveNetworkNode,
) -> bool {
	weight := generation_region_cave_network_edge_weight(from_node, to_node)
	if weight > CAVE_NETWORK_GRAPH_LOCAL_EDGE_MAX_WEIGHT_BLOCKS {
		return false
	}
	edge := cave_network_edge_from_nodes(from_node, to_node)
	roll := feature_grid_unit_f32(
		u64(edge.id),
		CAVE_NETWORK_EDGE_ROLL_SALT ~ CAVE_NETWORK_EDGE_ID_SALT,
	)
	return roll < CAVE_NETWORK_GRAPH_LOCAL_EDGE_ROLL_MAX
}

generation_region_cave_network_edge_exists :: proc(
	region: ^GenerationRegion,
	from_node_id, to_node_id: FeatureID,
) -> bool {
	_, found := generation_region_cave_network_edge_pair_index(region, from_node_id, to_node_id)
	return found
}

generation_region_cave_network_edge_pair_index :: proc(
	region: ^GenerationRegion,
	from_node_id, to_node_id: FeatureID,
) -> (
	index: u32,
	found: bool,
) {
	for i := u32(0); i < region.cave_network_edge_count; i += 1 {
		edge := region.cave_network_edges[i]
		if (edge.from_node_id == from_node_id && edge.to_node_id == to_node_id) ||
		   (edge.from_node_id == to_node_id && edge.to_node_id == from_node_id) {
			return i, true
		}
	}
	return
}

generation_region_cave_network_edge_id_exists :: proc(
	region: ^GenerationRegion,
	edge_id: FeatureID,
) -> bool {
	for i := u32(0); i < region.cave_network_edge_count; i += 1 {
		if region.cave_network_edges[i].id == edge_id {
			return true
		}
	}
	return false
}

generation_region_cave_network_edge_append :: proc(
	region: ^GenerationRegion,
	edge: CaveNetworkEdge,
) {
	log.assert(
		region.cave_network_edge_count < GENERATION_REGION_CAVE_NETWORK_EDGE_CAPACITY,
		"Generation Region Cave Network edge capacity exceeded",
	)
	region.cave_network_edges[region.cave_network_edge_count] = edge
	region.cave_network_edge_count += 1
}

generation_region_cave_anchor_append :: proc(region: ^GenerationRegion, anchor: CaveAnchor) {
	log.assert(
		region.cave_anchor_count < GENERATION_REGION_CAVE_ANCHOR_CAPACITY,
		"Generation Region Cave Anchor capacity exceeded",
	)
	region.cave_anchors[region.cave_anchor_count] = anchor
	region.cave_anchor_count += 1
}

generation_region_surface_biome_cell_from_owner :: proc(
	key: FeatureGridKey,
	owner: FeatureGridCoord2,
) -> GenerationRegionSurfaceBiomeCell {
	config := feature_grid_config_for(.Surface, .Biome)
	point := feature_grid_point_from_owner(key, config, owner)
	biome_id, macro_zone, macro_feature_id := surface_biome_identity_select(key, owner)
	return {
		feature = point,
		biome_id = biome_id,
		macro_zone = macro_zone,
		macro_feature_id = macro_feature_id,
	}
}

generation_region_subterranean_biome_cell_from_owner :: proc(
	key: FeatureGridKey,
	owner: FeatureGridCoord3,
) -> GenerationRegionSubterraneanBiomeCell {
	config := feature_grid_config_for(.Subterranean, .Biome)
	point := feature_grid_point_from_owner(key, config, owner)
	biome_id, macro_zone, depth_band, macro_feature_id := subterranean_biome_identity_select(
		key,
		owner,
	)
	return {
		feature = point,
		biome_id = biome_id,
		macro_zone = macro_zone,
		depth_band = depth_band,
		macro_feature_id = macro_feature_id,
	}
}

//////////////////////////////////////
// Generation Region Query Methods
/////////////////////////////////////

generation_region_query_make :: proc(
	bounds: BlockBounds3,
	influence_margins: GenerationInfluenceMargins,
) -> GenerationRegionQuery {
	feature_grid_block_bounds_validate(bounds)
	generation_region_influence_margins_validate(influence_margins)

	surface_bounds := generation_region_surface_bounds_from_bounds(bounds)
	return {
		bounds = bounds,
		influence_margins = influence_margins,
		surface_biome_owner_range = feature_grid_owner_range_from_block_bounds(
			surface_bounds,
			influence_margins.surface_biome_blocks,
			feature_grid_config_for(.Surface, .Biome),
		),
		surface_morphology_owner_range = feature_grid_owner_range_from_block_bounds(
			surface_bounds,
			influence_margins.surface_morphology_blocks,
			SURFACE_MORPHOLOGY_OWNER_GRID_CONFIG,
		),
		subterranean_biome_owner_range = feature_grid_owner_range_from_block_bounds(
			bounds,
			influence_margins.subterranean_biome_blocks,
			feature_grid_config_for(.Subterranean, .Biome),
		),
		surface_decoration_owner_range = feature_grid_owner_range_from_block_bounds(
			surface_bounds,
			influence_margins.surface_decoration_blocks,
			DECORATION_SURFACE_GRID_CONFIG,
		),
		surface_water_feature_owner_range = feature_grid_owner_range_from_block_bounds(
			surface_bounds,
			influence_margins.surface_water_feature_blocks,
			HYDROLOGY_SURFACE_GRAPH_GRID_CONFIG,
		),
		subterranean_water_feature_owner_range = feature_grid_owner_range_from_block_bounds(
			bounds,
			influence_margins.subterranean_water_feature_blocks,
			HYDROLOGY_SUBTERRANEAN_GRAPH_GRID_CONFIG,
		),
		cave_network_owner_range = feature_grid_owner_range_from_block_bounds(
			bounds,
			influence_margins.cave_network_blocks,
			CAVE_NETWORK_GRID_CONFIG,
		),
	}
}

generation_region_query_make_default :: proc(bounds: BlockBounds3) -> GenerationRegionQuery {
	return generation_region_query_make(bounds, GENERATION_REGION_DEFAULT_INFLUENCE_MARGINS)
}

generation_region_query_validate :: proc(region: ^GenerationRegion, query: GenerationRegionQuery) {
	log.assert(
		generation_region_bounds_contains_bounds(region.bounds, query.bounds),
		"Generation Region query target bounds must be inside the region",
	)
	log.assert(
		generation_region_owner_range_contains_range_2(
			region.surface_biome_owner_range,
			query.surface_biome_owner_range,
		),
		"Generation Region is missing surface biome owners for the query margin",
	)
	log.assert(
		generation_region_owner_range_contains_range_3(
			region.subterranean_biome_owner_range,
			query.subterranean_biome_owner_range,
		),
		"Generation Region is missing subterranean biome owners for the query margin",
	)
	log.assert(
		generation_region_owner_range_contains_range_2(
			region.surface_morphology_owner_range,
			query.surface_morphology_owner_range,
		),
		"Generation Region is missing surface morphology owners for the query margin",
	)
	log.assert(
		generation_region_owner_range_contains_range_2(
			region.surface_decoration_owner_range,
			query.surface_decoration_owner_range,
		),
		"Generation Region is missing surface Decoration Feature owners for the query margin",
	)
	log.assert(
		generation_region_owner_range_contains_range_2(
			region.surface_water_feature_owner_range,
			query.surface_water_feature_owner_range,
		),
		"Generation Region is missing surface Water Feature owners for the query margin",
	)
	log.assert(
		generation_region_owner_range_contains_range_3(
			region.subterranean_water_feature_owner_range,
			query.subterranean_water_feature_owner_range,
		),
		"Generation Region is missing subterranean Water Feature owners for the query margin",
	)
	log.assert(
		generation_region_owner_range_contains_range_3(
			region.cave_network_owner_range,
			query.cave_network_owner_range,
		),
		"Generation Region is missing Cave Network owners for the query margin",
	)
}

generation_region_surface_biome_cells_write :: proc(
	region: ^GenerationRegion,
	query: GenerationRegionQuery,
	cells: []GenerationRegionSurfaceBiomeCell,
) -> u32 {
	generation_region_query_validate(region, query)
	count_required := feature_grid_owner_range_count(query.surface_biome_owner_range)
	log.assertf(
		u32(len(cells)) >= count_required,
		"surface biome query output too small: required=%d got=%d",
		count_required,
		len(cells),
	)

	count: u32
	for i := u32(0); i < region.surface_biome_cell_count; i += 1 {
		cell := region.surface_biome_cells[i]
		if !generation_region_owner_range_contains_owner_2(
			query.surface_biome_owner_range,
			cell.feature.owner,
		) {
			continue
		}
		cells[count] = cell
		count += 1
	}
	log.assert(count == count_required, "surface biome query did not return every owner cell")
	return count
}

generation_region_subterranean_biome_cells_write :: proc(
	region: ^GenerationRegion,
	query: GenerationRegionQuery,
	cells: []GenerationRegionSubterraneanBiomeCell,
) -> u32 {
	generation_region_query_validate(region, query)
	count_required := feature_grid_owner_range_count(query.subterranean_biome_owner_range)
	log.assertf(
		u32(len(cells)) >= count_required,
		"subterranean biome query output too small: required=%d got=%d",
		count_required,
		len(cells),
	)

	count: u32
	for i := u32(0); i < region.subterranean_biome_cell_count; i += 1 {
		cell := region.subterranean_biome_cells[i]
		if !generation_region_owner_range_contains_owner_3(
			query.subterranean_biome_owner_range,
			cell.feature.owner,
		) {
			continue
		}
		cells[count] = cell
		count += 1
	}
	log.assert(count == count_required, "subterranean biome query did not return every owner cell")
	return count
}

generation_region_surface_morphology_features_write :: proc(
	region: ^GenerationRegion,
	query: GenerationRegionQuery,
	features: []SurfaceMorphologyFeature,
) -> u32 {
	log.assert(
		generation_region_bounds_contains_bounds(region.bounds, query.bounds),
		"surface morphology feature query target bounds must be inside the Generation Region",
	)
	log.assert(
		generation_region_owner_range_contains_range_2(
			region.surface_morphology_owner_range,
			query.surface_morphology_owner_range,
		),
		"Generation Region is missing surface morphology owners for the query margin",
	)

	count: u32
	for i := u32(0); i < region.surface_morphology_feature_count; i += 1 {
		feature := region.surface_morphology_features[i]
		if !generation_region_owner_range_contains_owner_2(
			query.surface_morphology_owner_range,
			feature.owner,
		) {
			continue
		}
		log.assertf(
			count < u32(len(features)),
			"surface morphology feature query output too small: got=%d",
			len(features),
		)
		features[count] = feature
		count += 1
	}
	return count
}

generation_region_surface_decoration_features_write :: proc(
	region: ^GenerationRegion,
	query: GenerationRegionQuery,
	features: []DecorationFeature,
) -> u32 {
	log.assert(
		generation_region_bounds_contains_bounds(region.bounds, query.bounds),
		"surface Decoration Feature query target bounds must be inside the Generation Region",
	)
	log.assert(
		generation_region_owner_range_contains_range_2(
			region.surface_decoration_owner_range,
			query.surface_decoration_owner_range,
		),
		"Generation Region is missing surface Decoration Feature owners for the query margin",
	)

	count: u32
	for i := u32(0); i < region.surface_decoration_feature_count; i += 1 {
		feature := region.surface_decoration_features[i]
		if !generation_region_owner_range_contains_owner_2(
			query.surface_decoration_owner_range,
			feature.owner,
		) {
			continue
		}
		log.assertf(
			count < u32(len(features)),
			"surface Decoration Feature query output too small: got=%d",
			len(features),
		)
		features[count] = feature
		count += 1
	}
	return count
}

generation_region_water_feature_nodes_write :: proc(
	region: ^GenerationRegion,
	query: GenerationRegionQuery,
	nodes: []WaterFeatureNode,
) -> u32 {
	generation_region_query_validate(region, query)

	count: u32
	for i := u32(0); i < region.water_feature_node_count; i += 1 {
		node := region.water_feature_nodes[i]
		if !generation_region_water_feature_owner_in_query(query, node.owner, node.kind) {
			continue
		}
		log.assertf(
			count < u32(len(nodes)),
			"water feature node query output too small: got=%d",
			len(nodes),
		)
		nodes[count] = node
		count += 1
	}
	return count
}

generation_region_water_feature_segments_write :: proc(
	region: ^GenerationRegion,
	query: GenerationRegionQuery,
	segments: []WaterFeatureSegment,
) -> u32 {
	generation_region_query_validate(region, query)

	count: u32
	for i := u32(0); i < region.water_feature_segment_count; i += 1 {
		segment := region.water_feature_segments[i]
		if !generation_region_water_feature_owner_in_query(query, segment.owner, segment.kind) {
			continue
		}
		log.assertf(
			count < u32(len(segments)),
			"water feature segment query output too small: got=%d",
			len(segments),
		)
		segments[count] = segment
		count += 1
	}
	return count
}

generation_region_water_feature_anchors_write :: proc(
	region: ^GenerationRegion,
	query: GenerationRegionQuery,
	anchors: []WaterFeatureAnchor,
) -> u32 {
	generation_region_query_validate(region, query)

	count: u32
	for i := u32(0); i < region.water_feature_anchor_count; i += 1 {
		anchor := region.water_feature_anchors[i]
		if !generation_region_water_feature_anchor_owner_in_query(query, anchor) {
			continue
		}
		log.assertf(
			count < u32(len(anchors)),
			"water feature anchor query output too small: got=%d",
			len(anchors),
		)
		anchors[count] = anchor
		count += 1
	}
	return count
}

generation_region_cave_network_nodes_write :: proc(
	region: ^GenerationRegion,
	query: GenerationRegionQuery,
	nodes: []CaveNetworkNode,
) -> u32 {
	generation_region_query_validate(region, query)

	count: u32
	for i := u32(0); i < region.cave_network_node_count; i += 1 {
		node := region.cave_network_nodes[i]
		if !generation_region_owner_range_contains_owner_3(
			query.cave_network_owner_range,
			node.owner,
		) {
			continue
		}
		log.assertf(
			count < u32(len(nodes)),
			"Cave Network node query output too small: got=%d",
			len(nodes),
		)
		nodes[count] = node
		count += 1
	}
	return count
}

generation_region_cave_network_edges_write :: proc(
	region: ^GenerationRegion,
	query: GenerationRegionQuery,
	edges: []CaveNetworkEdge,
) -> u32 {
	generation_region_query_validate(region, query)

	count: u32
	for i := u32(0); i < region.cave_network_edge_count; i += 1 {
		edge := region.cave_network_edges[i]
		if !generation_region_owner_range_contains_owner_3(
			query.cave_network_owner_range,
			edge.owner,
		) {
			continue
		}
		log.assertf(
			count < u32(len(edges)),
			"Cave Network edge query output too small: got=%d",
			len(edges),
		)
		edges[count] = edge
		count += 1
	}
	return count
}

generation_region_cave_anchors_write :: proc(
	region: ^GenerationRegion,
	query: GenerationRegionQuery,
	anchors: []CaveAnchor,
) -> u32 {
	generation_region_query_validate(region, query)

	count: u32
	for i := u32(0); i < region.cave_anchor_count; i += 1 {
		anchor := region.cave_anchors[i]
		if !generation_region_owner_range_contains_owner_3(
			query.cave_network_owner_range,
			anchor.owner,
		) {
			continue
		}
		log.assertf(
			count < u32(len(anchors)),
			"Cave Anchor query output too small: got=%d",
			len(anchors),
		)
		anchors[count] = anchor
		count += 1
	}
	return count
}

//////////////////////////////////////
// Generation Region Sampling Methods
/////////////////////////////////////

surface_biome_field_sample_from_region :: proc(
	region: ^GenerationRegion,
	block_x, block_z: i32,
) -> SurfaceBiomeFieldSample {
	log.assert(
		generation_region_bounds_contains_block_xz(region.bounds, block_x, block_z),
		"surface biome region sample must be inside the Generation Region X/Z bounds",
	)

	config := feature_grid_config_for(.Surface, .Biome)
	sample_x, sample_z := surface_biome_field_warped_sample_position(region.key, block_x, block_z)
	owner_block_x := i32(math.floor_f32(sample_x))
	owner_block_z := i32(math.floor_f32(sample_z))
	owners: [FEATURE_GRID_WORLEY_NEIGHBOR_COUNT_2]FeatureGridCoord2
	owner_count := feature_grid_neighbor_owners_from_block(
		owner_block_x,
		owner_block_z,
		FEATURE_GRID_WORLEY_NEIGHBOR_RADIUS,
		config,
		owners[:],
	)

	sample := SurfaceBiomeFieldSample{}
	for i := u32(0); i < owner_count; i += 1 {
		region_cell, found := generation_region_surface_biome_cell_find(region, owners[i])
		log.assertf(
			found,
			"Generation Region missing surface biome owner {%d,%d}",
			owners[i].x,
			owners[i].z,
		)
		cell := generation_region_surface_biome_cell_to_sample_cell(
			region_cell,
			sample_x,
			sample_z,
		)
		surface_biome_field_sample_insert_cell(&sample, cell)
	}
	surface_biome_field_sample_finalize(&sample)
	return sample
}

subterranean_biome_field_sample_from_region :: proc(
	region: ^GenerationRegion,
	block_x, block_y, block_z: i32,
) -> SubterraneanBiomeFieldSample {
	log.assert(
		generation_region_bounds_contains_block(region.bounds, block_x, block_y, block_z),
		"subterranean biome region sample must be inside the Generation Region bounds",
	)

	config := feature_grid_config_for(.Subterranean, .Biome)
	owners: [FEATURE_GRID_WORLEY_NEIGHBOR_COUNT_3]FeatureGridCoord3
	owner_count := feature_grid_neighbor_owners_from_block(
		block_x,
		block_y,
		block_z,
		FEATURE_GRID_WORLEY_NEIGHBOR_RADIUS,
		config,
		owners[:],
	)

	sample := SubterraneanBiomeFieldSample{}
	sample_x := f32(block_x) + 0.5
	sample_y := f32(block_y) + 0.5
	sample_z := f32(block_z) + 0.5
	for i := u32(0); i < owner_count; i += 1 {
		region_cell, found := generation_region_subterranean_biome_cell_find(region, owners[i])
		log.assertf(
			found,
			"Generation Region missing subterranean biome owner {%d,%d,%d}",
			owners[i].x,
			owners[i].y,
			owners[i].z,
		)
		cell := generation_region_subterranean_biome_cell_to_sample_cell(
			region_cell,
			sample_x,
			sample_y,
			sample_z,
		)
		subterranean_biome_field_sample_insert_cell(&sample, cell)
	}
	subterranean_biome_field_sample_finalize(&sample)
	return sample
}

generation_region_surface_biome_cell_to_sample_cell :: proc(
	region_cell: GenerationRegionSurfaceBiomeCell,
	sample_x, sample_z: f32,
) -> SurfaceBiomeCell {
	dx := region_cell.feature.x - sample_x
	dz := region_cell.feature.z - sample_z
	distance_sq := dx * dx + dz * dz
	return {
		feature = region_cell.feature,
		biome_id = region_cell.biome_id,
		macro_zone = region_cell.macro_zone,
		macro_feature_id = region_cell.macro_feature_id,
		distance = math.sqrt_f32(distance_sq),
		distance_sq = distance_sq,
	}
}

generation_region_subterranean_biome_cell_to_sample_cell :: proc(
	region_cell: GenerationRegionSubterraneanBiomeCell,
	sample_x, sample_y, sample_z: f32,
) -> SubterraneanBiomeCell {
	dx := region_cell.feature.x - sample_x
	dy := region_cell.feature.y - sample_y
	dz := region_cell.feature.z - sample_z
	distance_sq := dx * dx + dy * dy + dz * dz
	return {
		feature = region_cell.feature,
		biome_id = region_cell.biome_id,
		macro_zone = region_cell.macro_zone,
		depth_band = region_cell.depth_band,
		macro_feature_id = region_cell.macro_feature_id,
		distance = math.sqrt_f32(distance_sq),
		distance_sq = distance_sq,
	}
}

generation_region_surface_biome_cell_find :: proc(
	region: ^GenerationRegion,
	owner: FeatureGridCoord2,
) -> (
	cell: GenerationRegionSurfaceBiomeCell,
	found: bool,
) {
	for i := u32(0); i < region.surface_biome_cell_count; i += 1 {
		if region.surface_biome_cells[i].feature.owner == owner {
			cell = region.surface_biome_cells[i]
			found = true
			return
		}
	}
	return
}

generation_region_subterranean_biome_cell_find :: proc(
	region: ^GenerationRegion,
	owner: FeatureGridCoord3,
) -> (
	cell: GenerationRegionSubterraneanBiomeCell,
	found: bool,
) {
	for i := u32(0); i < region.subterranean_biome_cell_count; i += 1 {
		if region.subterranean_biome_cells[i].feature.owner == owner {
			cell = region.subterranean_biome_cells[i]
			found = true
			return
		}
	}
	return
}

generation_region_water_feature_owner_in_query :: proc(
	query: GenerationRegionQuery,
	owner: FeatureGridCoord3,
	kind: WaterFeatureKind,
) -> bool {
	if water_feature_kind_is_surface(kind) {
		return generation_region_owner_range_contains_owner_2(
			query.surface_water_feature_owner_range,
			{x = owner.x, z = owner.z},
		)
	}
	return generation_region_owner_range_contains_owner_3(
		query.subterranean_water_feature_owner_range,
		owner,
	)
}

generation_region_water_feature_anchor_owner_in_query :: proc(
	query: GenerationRegionQuery,
	anchor: WaterFeatureAnchor,
) -> bool {
	switch anchor.kind {
	case .Shoreline, .Lakebed_Breach, .River_Bank:
		return generation_region_owner_range_contains_owner_2(
			query.surface_water_feature_owner_range,
			{x = anchor.owner.x, z = anchor.owner.z},
		)
	case .Aquifer_Breach, .Underground_River_Link, .Flooded_Cave_Link:
		return generation_region_owner_range_contains_owner_3(
			query.subterranean_water_feature_owner_range,
			anchor.owner,
		)
	}
	return false
}

//////////////////////////////////////
// Generation Region Bounds Methods
/////////////////////////////////////

generation_region_bounds_contains_bounds :: proc(bounds, target: BlockBounds3) -> bool {
	feature_grid_block_bounds_validate(bounds)
	feature_grid_block_bounds_validate(target)
	return(
		target.min.x >= bounds.min.x &&
		target.min.y >= bounds.min.y &&
		target.min.z >= bounds.min.z &&
		target.max.x <= bounds.max.x &&
		target.max.y <= bounds.max.y &&
		target.max.z <= bounds.max.z \
	)
}

generation_region_bounds_contains_block :: proc(
	bounds: BlockBounds3,
	block_x, block_y, block_z: i32,
) -> bool {
	feature_grid_block_bounds_validate(bounds)
	return(
		block_x >= bounds.min.x &&
		block_x < bounds.max.x &&
		block_y >= bounds.min.y &&
		block_y < bounds.max.y &&
		block_z >= bounds.min.z &&
		block_z < bounds.max.z \
	)
}

generation_region_bounds_contains_block_xz :: proc(
	bounds: BlockBounds3,
	block_x, block_z: i32,
) -> bool {
	feature_grid_block_bounds_validate(bounds)
	return(
		block_x >= bounds.min.x &&
		block_x < bounds.max.x &&
		block_z >= bounds.min.z &&
		block_z < bounds.max.z \
	)
}

generation_region_owner_range_contains_range_2 :: proc(
	owner_range, target: FeatureGridOwnerRange2,
) -> bool {
	feature_grid_owner_range_validate(owner_range)
	feature_grid_owner_range_validate(target)
	return(
		target.min.x >= owner_range.min.x &&
		target.min.z >= owner_range.min.z &&
		target.max.x <= owner_range.max.x &&
		target.max.z <= owner_range.max.z \
	)
}

generation_region_owner_range_contains_range_3 :: proc(
	owner_range, target: FeatureGridOwnerRange3,
) -> bool {
	feature_grid_owner_range_validate(owner_range)
	feature_grid_owner_range_validate(target)
	return(
		target.min.x >= owner_range.min.x &&
		target.min.y >= owner_range.min.y &&
		target.min.z >= owner_range.min.z &&
		target.max.x <= owner_range.max.x &&
		target.max.y <= owner_range.max.y &&
		target.max.z <= owner_range.max.z \
	)
}

generation_region_owner_range_contains_owner_2 :: proc(
	owner_range: FeatureGridOwnerRange2,
	owner: FeatureGridCoord2,
) -> bool {
	feature_grid_owner_range_validate(owner_range)
	return(
		owner.x >= owner_range.min.x &&
		owner.z >= owner_range.min.z &&
		owner.x <= owner_range.max.x &&
		owner.z <= owner_range.max.z \
	)
}

generation_region_owner_range_contains_owner_3 :: proc(
	owner_range: FeatureGridOwnerRange3,
	owner: FeatureGridCoord3,
) -> bool {
	feature_grid_owner_range_validate(owner_range)
	return(
		owner.x >= owner_range.min.x &&
		owner.y >= owner_range.min.y &&
		owner.z >= owner_range.min.z &&
		owner.x <= owner_range.max.x &&
		owner.y <= owner_range.max.y &&
		owner.z <= owner_range.max.z \
	)
}

//////////////////////////////////////
// Debug Methods
/////////////////////////////////////

when ODIN_DEBUG {

	generation_region_debug_contract_checks_run :: proc() {
		key := feature_grid_key_make(0x123456789abcdef0, 1)
		next_version_key := feature_grid_key_make(key.world_seed, key.generator_version + 1)
		decoration_owner_range := feature_grid_owner_range_from_block_bounds(
			generation_region_surface_bounds_from_bounds(
				BlockBounds3 {
					min = {},
					max = {
						x = GENERATION_REGION_BLOCK_LENGTH,
						y = GENERATION_REGION_BLOCK_LENGTH,
						z = GENERATION_REGION_BLOCK_LENGTH,
					},
				},
			),
			GENERATION_REGION_DEFAULT_INFLUENCE_MARGINS.surface_decoration_blocks,
			DECORATION_SURFACE_GRID_CONFIG,
		)
		decoration_owner_count := feature_grid_owner_range_count(decoration_owner_range)
		log.assert(
			decoration_owner_count * u32(DECORATION_SURFACE_SLOT_COUNT_MAX) <=
			GENERATION_REGION_SURFACE_DECORATION_FEATURE_CAPACITY,
			"surface decoration capacity must cover all owner slots in a generation region",
		)

		origin_region := new(GenerationRegion)
		generation_region_build_with_margins_into(
			origin_region,
			key,
			{x = 0, y = 0, z = 0},
			GENERATION_REGION_DEFAULT_INFLUENCE_MARGINS,
		)
		log.assert(origin_region.bounds.min == IVec3{}, "origin region min bounds mismatch")
		log.assert(
			origin_region.bounds.max ==
			IVec3 {
					x = GENERATION_REGION_BLOCK_LENGTH,
					y = GENERATION_REGION_BLOCK_LENGTH,
					z = GENERATION_REGION_BLOCK_LENGTH,
				},
			"origin region max bounds mismatch",
		)
		log.assert(
			origin_region.surface_biome_cell_count == 25,
			"origin region surface biome sparse cell count mismatch",
		)
		log.assert(
			origin_region.subterranean_biome_cell_count == 27,
			"origin region subterranean biome sparse cell count mismatch",
		)
		log.assert(
			origin_region.water_feature_node_count > 0 &&
			origin_region.water_feature_segment_count > 0 &&
			origin_region.water_feature_anchor_count > 0,
			"origin region should store sparse Water Feature Graph data",
		)
		log.assert(
			origin_region.cave_network_node_count > 0 &&
			origin_region.cave_network_edge_count > 0 &&
			origin_region.cave_anchor_count > 0,
			"origin region should store sparse Cave Network data",
		)
		debug_generation_region_cave_network_graph_assert_connected(origin_region)
		local_edges_shared_checked := false
		for z := i32(-1); z <= 1 && !local_edges_shared_checked; z += 1 {
			for y := i32(-1); y <= 1 && !local_edges_shared_checked; y += 1 {
				for x := i32(-1); x <= 1 && !local_edges_shared_checked; x += 1 {
					from_coord := GenerationRegionCoord {
						x = x,
						y = y,
						z = z,
					}
					neighbor_offsets := [?]GenerationRegionCoord {
						{x = 1, y = 0, z = 0},
						{x = 0, y = 1, z = 0},
						{x = 0, y = 0, z = 1},
					}
					for offset in neighbor_offsets {
						to_coord := GenerationRegionCoord {
							x = from_coord.x + offset.x,
							y = from_coord.y + offset.y,
							z = from_coord.z + offset.z,
						}
						if debug_generation_region_cave_network_local_edges_assert_shared(
							key,
							from_coord,
							to_coord,
						) {
							local_edges_shared_checked = true
							break
						}
					}
				}
			}
		}
		log.assert(
			local_edges_shared_checked,
			"nearby adjacent Generation Regions should share canonical local Cave Network edges",
		)
		seam_edges_shared_checked := false
		for z := i32(-1); z <= 1 && !seam_edges_shared_checked; z += 1 {
			for y := i32(-1); y <= 1 && !seam_edges_shared_checked; y += 1 {
				for x := i32(-1); x <= 1 && !seam_edges_shared_checked; x += 1 {
					from_coord := GenerationRegionCoord {
						x = x,
						y = y,
						z = z,
					}
					neighbor_offsets := [?]GenerationRegionCoord {
						{x = 1, y = 0, z = 0},
						{x = 0, y = 1, z = 0},
						{x = 0, y = 0, z = 1},
					}
					for offset in neighbor_offsets {
						to_coord := GenerationRegionCoord {
							x = from_coord.x + offset.x,
							y = from_coord.y + offset.y,
							z = from_coord.z + offset.z,
						}
						if debug_generation_region_cave_network_seam_edges_assert_shared(
							key,
							from_coord,
							to_coord,
						) {
							seam_edges_shared_checked = true
							break
						}
					}
				}
			}
		}
		log.assert(
			seam_edges_shared_checked,
			"nearby adjacent Generation Regions should select a shared Cave Network seam edge",
		)
		log.assert(
			generation_region_coord_from_block(-1, -1, -1) ==
			GenerationRegionCoord{x = -1, y = -1, z = -1},
			"negative block coordinates must use floor division for Generation Regions",
		)

		next_version_region := new(GenerationRegion)
		generation_region_build_with_margins_into(
			next_version_region,
			next_version_key,
			origin_region.coord,
			GENERATION_REGION_DEFAULT_INFLUENCE_MARGINS,
		)
		log.assert(
			origin_region.surface_biome_cells[0].feature.id !=
			next_version_region.surface_biome_cells[0].feature.id,
			"Generation Region sparse feature data must include generator version",
		)

		chunk_bounds := BlockBounds3 {
			min = {x = 0, y = 0, z = 0},
			max = {x = 64, y = 64, z = 64},
		}
		log.assert(
			generation_region_coord_from_block_bounds(chunk_bounds) == origin_region.coord,
			"chunk-like bounds should resolve to the origin Generation Region",
		)
		query := generation_region_query_make_default(chunk_bounds)
		generation_region_query_validate(origin_region, query)

		surface_cells: [GENERATION_REGION_SURFACE_BIOME_CELL_CAPACITY]GenerationRegionSurfaceBiomeCell
		surface_cell_count := generation_region_surface_biome_cells_write(
			origin_region,
			query,
			surface_cells[:],
		)
		log.assert(surface_cell_count == 16, "chunk surface biome query count mismatch")

		subterranean_cells: [GENERATION_REGION_SUBTERRANEAN_BIOME_CELL_CAPACITY]GenerationRegionSubterraneanBiomeCell
		subterranean_cell_count := generation_region_subterranean_biome_cells_write(
			origin_region,
			query,
			subterranean_cells[:],
		)
		log.assert(subterranean_cell_count == 27, "chunk subterranean biome query count mismatch")

		surface_decorations: [GENERATION_REGION_SURFACE_DECORATION_FEATURE_CAPACITY]DecorationFeature
		_ = generation_region_surface_decoration_features_write(
			origin_region,
			query,
			surface_decorations[:],
		)

		water_nodes: [GENERATION_REGION_WATER_FEATURE_NODE_CAPACITY]WaterFeatureNode
		water_node_count := generation_region_water_feature_nodes_write(
			origin_region,
			query,
			water_nodes[:],
		)
		log.assert(water_node_count > 0, "chunk Water Feature node query returned no data")

		water_segments: [GENERATION_REGION_WATER_FEATURE_SEGMENT_CAPACITY]WaterFeatureSegment
		water_segment_count := generation_region_water_feature_segments_write(
			origin_region,
			query,
			water_segments[:],
		)
		log.assert(water_segment_count > 0, "chunk Water Feature segment query returned no data")

		water_anchors: [GENERATION_REGION_WATER_FEATURE_ANCHOR_CAPACITY]WaterFeatureAnchor
		water_anchor_count := generation_region_water_feature_anchors_write(
			origin_region,
			query,
			water_anchors[:],
		)
		log.assert(water_anchor_count > 0, "chunk Water Feature anchor query returned no data")

		cave_nodes: [GENERATION_REGION_CAVE_NETWORK_NODE_CAPACITY]CaveNetworkNode
		cave_node_count := generation_region_cave_network_nodes_write(
			origin_region,
			query,
			cave_nodes[:],
		)
		log.assert(cave_node_count > 0, "chunk Cave Network node query returned no data")

		cave_edges: [GENERATION_REGION_CAVE_NETWORK_EDGE_CAPACITY]CaveNetworkEdge
		cave_edge_count := generation_region_cave_network_edges_write(
			origin_region,
			query,
			cave_edges[:],
		)
		log.assert(cave_edge_count > 0, "chunk Cave Network edge query returned no data")

		cave_anchors: [GENERATION_REGION_CAVE_ANCHOR_CAPACITY]CaveAnchor
		cave_anchor_count := generation_region_cave_anchors_write(
			origin_region,
			query,
			cave_anchors[:],
		)
		log.assert(cave_anchor_count > 0, "chunk Cave Anchor query returned no data")

		edge_chunk_bounds := BlockBounds3 {
			min = {x = 448, y = 448, z = 448},
			max = {x = 512, y = 512, z = 512},
		}
		edge_query := generation_region_query_make_default(edge_chunk_bounds)
		generation_region_query_validate(origin_region, edge_query)

		surface_sample_coord := IVec2 {
			x = 17,
			z = -33,
		}
		surface_region_coord := generation_region_coord_from_block(
			surface_sample_coord.x,
			0,
			surface_sample_coord.z,
		)
		surface_region := new(GenerationRegion)
		generation_region_build_with_margins_into(
			surface_region,
			key,
			surface_region_coord,
			GENERATION_REGION_DEFAULT_INFLUENCE_MARGINS,
		)
		surface_direct := surface_biome_field_sample(
			key,
			surface_sample_coord.x,
			surface_sample_coord.z,
		)
		surface_region_sample := surface_biome_field_sample_from_region(
			surface_region,
			surface_sample_coord.x,
			surface_sample_coord.z,
		)
		debug_surface_biome_samples_assert_equal(surface_direct, surface_region_sample)
		surface_hydrology_direct := hydrology_layer_surface_sample(
			key,
			surface_sample_coord.x,
			surface_sample_coord.z,
		)
		surface_hydrology_region := hydrology_layer_surface_sample_from_region(
			surface_region,
			surface_sample_coord.x,
			surface_sample_coord.z,
		)
		debug_hydrology_surface_samples_assert_equal(
			surface_hydrology_direct,
			surface_hydrology_region,
		)

		subterranean_sample_coord := IVec3 {
			x = -45,
			y = -96,
			z = 130,
		}
		subterranean_region_coord := generation_region_coord_from_block(
			subterranean_sample_coord.x,
			subterranean_sample_coord.y,
			subterranean_sample_coord.z,
		)
		subterranean_region := new(GenerationRegion)
		generation_region_build_with_margins_into(
			subterranean_region,
			key,
			subterranean_region_coord,
			GENERATION_REGION_DEFAULT_INFLUENCE_MARGINS,
		)
		subterranean_direct := subterranean_biome_field_sample(
			key,
			subterranean_sample_coord.x,
			subterranean_sample_coord.y,
			subterranean_sample_coord.z,
		)
		subterranean_region_sample := subterranean_biome_field_sample_from_region(
			subterranean_region,
			subterranean_sample_coord.x,
			subterranean_sample_coord.y,
			subterranean_sample_coord.z,
		)
		debug_subterranean_biome_samples_assert_equal(
			subterranean_direct,
			subterranean_region_sample,
		)
		subterranean_hydrology_direct := hydrology_layer_subterranean_sample(
			key,
			subterranean_sample_coord.x,
			subterranean_sample_coord.y,
			subterranean_sample_coord.z,
		)
		subterranean_hydrology_region := hydrology_layer_subterranean_sample_from_region(
			subterranean_region,
			subterranean_sample_coord.x,
			subterranean_sample_coord.y,
			subterranean_sample_coord.z,
		)
		debug_hydrology_subterranean_samples_assert_equal(
			subterranean_hydrology_direct,
			subterranean_hydrology_region,
		)

		cave_debug_sample := cave_network_debug_surface_sample_from_region(
			surface_region,
			surface_sample_coord.x,
			surface_sample_coord.z,
		)
		log.assert(
			cave_debug_sample.nearest_distance_blocks >= 0,
			"surface Cave Network debug sample should be valid",
		)

		log.debug("Generation Region contract checks passed")
	}

	debug_generation_region_cave_network_graph_assert_connected :: proc(
		region: ^GenerationRegion,
	) {
		eligible: [GENERATION_REGION_CAVE_NETWORK_NODE_CAPACITY]bool
		visited: [GENERATION_REGION_CAVE_NETWORK_NODE_CAPACITY]bool
		queue: [GENERATION_REGION_CAVE_NETWORK_NODE_CAPACITY]u32
		eligible_count: u32
		start_index: u32
		start_found := false
		for i := u32(0); i < region.cave_network_node_count; i += 1 {
			if region.cave_network_nodes[i].role == .Sealed_Secret {
				continue
			}
			eligible[i] = true
			eligible_count += 1
			if !start_found {
				start_index = i
				start_found = true
			}
		}
		if eligible_count <= 1 || !start_found {
			return
		}

		queue_head: u32
		queue_tail: u32
		queue[queue_tail] = start_index
		queue_tail += 1
		visited[start_index] = true
		visited_count := u32(1)
		for queue_head < queue_tail {
			node_index := queue[queue_head]
			queue_head += 1
			node := region.cave_network_nodes[node_index]
			for edge_index := u32(0);
			    edge_index < region.cave_network_edge_count;
			    edge_index += 1 {
				edge := region.cave_network_edges[edge_index]
				neighbor_id := FeatureID(0)
				if edge.from_node_id == node.id {
					neighbor_id = edge.to_node_id
				} else if edge.to_node_id == node.id {
					neighbor_id = edge.from_node_id
				} else {
					continue
				}
				neighbor_index, found := debug_generation_region_cave_network_node_index_by_id(
					region,
					neighbor_id,
				)
				if !found || !eligible[neighbor_index] || visited[neighbor_index] {
					continue
				}
				visited[neighbor_index] = true
				queue[queue_tail] = neighbor_index
				queue_tail += 1
				visited_count += 1
			}
		}

		log.assertf(
			visited_count == eligible_count,
			"Generation Region Cave Network graph must connect non-sealed nodes: visited=%d eligible=%d",
			visited_count,
			eligible_count,
		)
		tree_edge_count := eligible_count - 1
		log.assertf(
			region.cave_network_edge_count >= tree_edge_count,
			"Generation Region Cave Network graph has fewer than tree edges: edges=%d tree=%d",
			region.cave_network_edge_count,
			tree_edge_count,
		)
		if eligible_count > 3 {
			log.assertf(
				region.cave_network_edge_count > tree_edge_count,
				"Generation Region Cave Network graph should include augmented loop edges: edges=%d tree=%d",
				region.cave_network_edge_count,
				tree_edge_count,
			)
		}
	}

	debug_generation_region_cave_network_local_edges_assert_shared :: proc(
		key: FeatureGridKey,
		from_coord, to_coord: GenerationRegionCoord,
	) -> bool {
		from_region := new(GenerationRegion)
		to_region := new(GenerationRegion)
		generation_region_build_with_margins_into(
			from_region,
			key,
			from_coord,
			GENERATION_REGION_DEFAULT_INFLUENCE_MARGINS,
		)
		generation_region_build_with_margins_into(
			to_region,
			key,
			to_coord,
			GENERATION_REGION_DEFAULT_INFLUENCE_MARGINS,
		)

		shared_local_edges: u32
		for i := u32(0); i < from_region.cave_network_node_count; i += 1 {
			from_node := from_region.cave_network_nodes[i]
			if from_node.role == .Sealed_Secret ||
			   !generation_region_owner_range_contains_owner_3(
					   to_region.cave_network_owner_range,
					   from_node.owner,
				   ) {
				continue
			}
			for j := i + 1; j < from_region.cave_network_node_count; j += 1 {
				to_node := from_region.cave_network_nodes[j]
				if to_node.role == .Sealed_Secret ||
				   !generation_region_owner_range_contains_owner_3(
						   to_region.cave_network_owner_range,
						   to_node.owner,
					   ) {
					continue
				}
				if !generation_region_cave_network_local_edge_should_exist(from_node, to_node) {
					continue
				}
				shared_local_edges += 1
				log.assert(
					generation_region_cave_network_edge_exists(
						from_region,
						from_node.id,
						to_node.id,
					),
					"left Generation Region missing canonical local Cave Network edge",
				)
				log.assert(
					generation_region_cave_network_edge_exists(
						to_region,
						from_node.id,
						to_node.id,
					),
					"right Generation Region missing shared canonical local Cave Network edge",
				)
			}
		}
		return shared_local_edges > 0
	}

	debug_generation_region_cave_network_seam_edges_assert_shared :: proc(
		key: FeatureGridKey,
		from_coord, to_coord: GenerationRegionCoord,
	) -> bool {
		from_region := new(GenerationRegion)
		to_region := new(GenerationRegion)
		generation_region_build_with_margins_into(
			from_region,
			key,
			from_coord,
			GENERATION_REGION_DEFAULT_INFLUENCE_MARGINS,
		)
		generation_region_build_with_margins_into(
			to_region,
			key,
			to_coord,
			GENERATION_REGION_DEFAULT_INFLUENCE_MARGINS,
		)

		axis, face_block, face_found := debug_generation_region_cave_network_shared_face(
			from_coord,
			to_coord,
			from_region.bounds,
		)
		log.assert(face_found, "debug seam check requires directly adjacent Generation Regions")

		from_eligible: [GENERATION_REGION_CAVE_NETWORK_NODE_CAPACITY]bool
		for i := u32(0); i < from_region.cave_network_node_count; i += 1 {
			from_eligible[i] = from_region.cave_network_nodes[i].role != .Sealed_Secret
		}
		to_eligible: [GENERATION_REGION_CAVE_NETWORK_NODE_CAPACITY]bool
		for i := u32(0); i < to_region.cave_network_node_count; i += 1 {
			to_eligible[i] = to_region.cave_network_nodes[i].role != .Sealed_Secret
		}

		from_from_index, from_to_index, from_found :=
			generation_region_cave_network_seam_edge_select(
				from_region,
				from_eligible,
				axis,
				face_block,
			)
		to_from_index, to_to_index, to_found := generation_region_cave_network_seam_edge_select(
			to_region,
			to_eligible,
			axis,
			face_block,
		)
		if !from_found || !to_found {
			return false
		}

		from_from_node := from_region.cave_network_nodes[from_from_index]
		from_to_node := from_region.cave_network_nodes[from_to_index]
		to_from_node := to_region.cave_network_nodes[to_from_index]
		to_to_node := to_region.cave_network_nodes[to_to_index]
		log.assert(
			from_from_node.id == to_from_node.id && from_to_node.id == to_to_node.id,
			"adjacent Generation Regions selected different Cave Network seam endpoints",
		)

		seam_edge := cave_network_seam_edge_from_nodes(from_from_node, from_to_node)
		log.assert(
			generation_region_cave_network_edge_id_exists(from_region, seam_edge.id),
			"left Generation Region missing deterministic Cave Network seam edge",
		)
		log.assert(
			generation_region_cave_network_edge_id_exists(to_region, seam_edge.id),
			"right Generation Region missing shared deterministic Cave Network seam edge",
		)
		return true
	}

	debug_generation_region_cave_network_shared_face :: proc(
		from_coord, to_coord: GenerationRegionCoord,
		from_bounds: BlockBounds3,
	) -> (
		axis: int,
		face_block: f32,
		found: bool,
	) {
		if from_coord.y == to_coord.y && from_coord.z == to_coord.z {
			if to_coord.x == from_coord.x + 1 {
				return 0, f32(from_bounds.max.x), true
			}
			if to_coord.x == from_coord.x - 1 {
				return 0, f32(from_bounds.min.x), true
			}
		}
		if from_coord.x == to_coord.x && from_coord.z == to_coord.z {
			if to_coord.y == from_coord.y + 1 {
				return 1, f32(from_bounds.max.y), true
			}
			if to_coord.y == from_coord.y - 1 {
				return 1, f32(from_bounds.min.y), true
			}
		}
		if from_coord.x == to_coord.x && from_coord.y == to_coord.y {
			if to_coord.z == from_coord.z + 1 {
				return 2, f32(from_bounds.max.z), true
			}
			if to_coord.z == from_coord.z - 1 {
				return 2, f32(from_bounds.min.z), true
			}
		}
		return
	}

	debug_generation_region_cave_network_node_index_by_id :: proc(
		region: ^GenerationRegion,
		node_id: FeatureID,
	) -> (
		index: u32,
		found: bool,
	) {
		for i := u32(0); i < region.cave_network_node_count; i += 1 {
			if region.cave_network_nodes[i].id == node_id {
				return i, true
			}
		}
		return
	}

	debug_surface_biome_samples_assert_equal :: proc(a, b: SurfaceBiomeFieldSample) {
		log.assert(a.cell_count == b.cell_count, "surface region sample cell count mismatch")
		log.assert(
			debug_f32_approx_equal(a.distance_gap, b.distance_gap, 0.001),
			"surface region sample distance gap mismatch",
		)
		log.assert(
			debug_f32_approx_equal(a.boundary_blend, b.boundary_blend, 0.001),
			"surface region sample boundary blend mismatch",
		)
		for i := u32(0); i < a.cell_count; i += 1 {
			log.assert(
				a.cells[i].feature.id == b.cells[i].feature.id,
				"surface region sample feature ID mismatch",
			)
			log.assert(
				a.cells[i].biome_id == b.cells[i].biome_id,
				"surface region sample biome identity mismatch",
			)
			log.assert(
				debug_f32_approx_equal(a.cells[i].distance, b.cells[i].distance, 0.001),
				"surface region sample distance mismatch",
			)
			log.assert(
				debug_f32_approx_equal(a.blend_weights[i], b.blend_weights[i], 0.001),
				"surface region sample blend weight mismatch",
			)
		}
	}

	debug_subterranean_biome_samples_assert_equal :: proc(a, b: SubterraneanBiomeFieldSample) {
		log.assert(a.cell_count == b.cell_count, "subterranean region sample cell count mismatch")
		log.assert(
			debug_f32_approx_equal(a.distance_gap, b.distance_gap, 0.001),
			"subterranean region sample distance gap mismatch",
		)
		log.assert(
			debug_f32_approx_equal(a.boundary_blend, b.boundary_blend, 0.001),
			"subterranean region sample boundary blend mismatch",
		)
		for i := u32(0); i < a.cell_count; i += 1 {
			log.assert(
				a.cells[i].feature.id == b.cells[i].feature.id,
				"subterranean region sample feature ID mismatch",
			)
			log.assert(
				a.cells[i].biome_id == b.cells[i].biome_id,
				"subterranean region sample biome identity mismatch",
			)
			log.assert(
				debug_f32_approx_equal(a.cells[i].distance, b.cells[i].distance, 0.001),
				"subterranean region sample distance mismatch",
			)
			log.assert(
				debug_f32_approx_equal(a.blend_weights[i], b.blend_weights[i], 0.001),
				"subterranean region sample blend weight mismatch",
			)
		}
	}

}
