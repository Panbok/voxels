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
	surface_water_feature_blocks:      i32,
	subterranean_water_feature_blocks: i32,
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
	surface_water_feature_owner_range:      FeatureGridOwnerRange2,
	subterranean_water_feature_owner_range: FeatureGridOwnerRange3,
}

GenerationRegion :: struct {
	key:                                    FeatureGridKey,
	coord:                                  GenerationRegionCoord,
	bounds:                                 BlockBounds3,
	influence_margins:                      GenerationInfluenceMargins,
	surface_biome_owner_range:              FeatureGridOwnerRange2,
	subterranean_biome_owner_range:         FeatureGridOwnerRange3,
	surface_water_feature_owner_range:      FeatureGridOwnerRange2,
	subterranean_water_feature_owner_range: FeatureGridOwnerRange3,
	surface_biome_cells:                    [GENERATION_REGION_SURFACE_BIOME_CELL_CAPACITY]GenerationRegionSurfaceBiomeCell,
	surface_biome_cell_count:               u32,
	subterranean_biome_cells:               [GENERATION_REGION_SUBTERRANEAN_BIOME_CELL_CAPACITY]GenerationRegionSubterraneanBiomeCell,
	subterranean_biome_cell_count:          u32,
	water_feature_nodes:                    [GENERATION_REGION_WATER_FEATURE_NODE_CAPACITY]WaterFeatureNode,
	water_feature_node_count:               u32,
	water_feature_segments:                 [GENERATION_REGION_WATER_FEATURE_SEGMENT_CAPACITY]WaterFeatureSegment,
	water_feature_segment_count:            u32,
	water_feature_anchors:                  [GENERATION_REGION_WATER_FEATURE_ANCHOR_CAPACITY]WaterFeatureAnchor,
	water_feature_anchor_count:             u32,
}

//////////////////////////////////////
// Generation Region Constants
/////////////////////////////////////

GENERATION_REGION_BLOCK_LENGTH :: 512

// Margins include one owning biome cell plus the first blend band so chunk queries can
// sample nearest-cell and boundary data from a region without inventing edge-local features.
GENERATION_REGION_SURFACE_BIOME_MARGIN_BLOCKS :: 608
GENERATION_REGION_SUBTERRANEAN_BIOME_MARGIN_BLOCKS :: 456
GENERATION_REGION_SURFACE_WATER_FEATURE_MARGIN_BLOCKS :: HYDROLOGY_SURFACE_SAMPLE_MARGIN_BLOCKS
GENERATION_REGION_SUBTERRANEAN_WATER_FEATURE_MARGIN_BLOCKS ::
	HYDROLOGY_SUBTERRANEAN_SAMPLE_MARGIN_BLOCKS

GENERATION_REGION_DEFAULT_INFLUENCE_MARGINS :: GenerationInfluenceMargins {
	surface_biome_blocks              = GENERATION_REGION_SURFACE_BIOME_MARGIN_BLOCKS,
	subterranean_biome_blocks         = GENERATION_REGION_SUBTERRANEAN_BIOME_MARGIN_BLOCKS,
	surface_water_feature_blocks      = GENERATION_REGION_SURFACE_WATER_FEATURE_MARGIN_BLOCKS,
	subterranean_water_feature_blocks = GENERATION_REGION_SUBTERRANEAN_WATER_FEATURE_MARGIN_BLOCKS,
}

GENERATION_REGION_SURFACE_BIOME_CELL_CAPACITY :: 25
GENERATION_REGION_SUBTERRANEAN_BIOME_CELL_CAPACITY :: 125
GENERATION_REGION_WATER_FEATURE_NODE_CAPACITY :: 64
GENERATION_REGION_WATER_FEATURE_SEGMENT_CAPACITY :: 128
GENERATION_REGION_WATER_FEATURE_ANCHOR_CAPACITY :: 192

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

generation_region_build :: proc(
	key: FeatureGridKey,
	coord: GenerationRegionCoord,
) -> GenerationRegion {
	return generation_region_build_with_margins(
		key,
		coord,
		GENERATION_REGION_DEFAULT_INFLUENCE_MARGINS,
	)
}

generation_region_build_with_margins :: proc(
	key: FeatureGridKey,
	coord: GenerationRegionCoord,
	influence_margins: GenerationInfluenceMargins,
) -> GenerationRegion {
	generation_region_influence_margins_validate(influence_margins)

	region := GenerationRegion {
		key               = key,
		coord             = coord,
		bounds            = generation_region_bounds_from_coord(coord),
		influence_margins = influence_margins,
	}
	generation_region_surface_biome_cells_fill(&region)
	generation_region_subterranean_biome_cells_fill(&region)
	generation_region_water_features_fill(&region)
	return region
}

generation_region_influence_margins_validate :: proc(margins: GenerationInfluenceMargins) {
	log.assert(margins.surface_biome_blocks >= 0, "surface biome margin must not be negative")
	log.assert(
		margins.subterranean_biome_blocks >= 0,
		"subterranean biome margin must not be negative",
	)
	log.assert(
		margins.surface_water_feature_blocks >= 0,
		"surface water feature margin must not be negative",
	)
	log.assert(
		margins.subterranean_water_feature_blocks >= 0,
		"subterranean water feature margin must not be negative",
	)
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
			generation_region_water_feature_node_append(region, node)

			x_neighbor := FeatureGridCoord2 {
				x = x + 1,
				z = z,
			}
			z_neighbor := FeatureGridCoord2 {
				x = x,
				z = z + 1,
			}
			generation_region_water_feature_segment_append(
				region,
				water_feature_surface_segment_from_owners(region.key, owner, x_neighbor),
			)
			generation_region_water_feature_segment_append(
				region,
				water_feature_surface_segment_from_owners(region.key, owner, z_neighbor),
			)
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
				generation_region_water_feature_segment_append(
					region,
					water_feature_subterranean_segment_from_owners(region.key, owner, x_neighbor),
				)
				generation_region_water_feature_segment_append(
					region,
					water_feature_subterranean_segment_from_owners(region.key, owner, y_neighbor),
				)
				generation_region_water_feature_segment_append(
					region,
					water_feature_subterranean_segment_from_owners(region.key, owner, z_neighbor),
				)
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
		subterranean_biome_owner_range = feature_grid_owner_range_from_block_bounds(
			bounds,
			influence_margins.subterranean_biome_blocks,
			feature_grid_config_for(.Subterranean, .Biome),
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
	owners: [FEATURE_GRID_WORLEY_NEIGHBOR_COUNT_2]FeatureGridCoord2
	owner_count := feature_grid_neighbor_owners_from_block(
		block_x,
		block_z,
		FEATURE_GRID_WORLEY_NEIGHBOR_RADIUS,
		config,
		owners[:],
	)

	sample := SurfaceBiomeFieldSample{}
	sample_x := f32(block_x) + 0.5
	sample_z := f32(block_z) + 0.5
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

		origin_region := generation_region_build(key, {x = 0, y = 0, z = 0})
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
			origin_region.subterranean_biome_cell_count == 125,
			"origin region subterranean biome sparse cell count mismatch",
		)
		log.assert(
			origin_region.water_feature_node_count > 0 &&
			origin_region.water_feature_segment_count > 0 &&
			origin_region.water_feature_anchor_count > 0,
			"origin region should store sparse Water Feature Graph data",
		)
		log.assert(
			generation_region_coord_from_block(-1, -1, -1) ==
			GenerationRegionCoord{x = -1, y = -1, z = -1},
			"negative block coordinates must use floor division for Generation Regions",
		)

		next_version_region := generation_region_build(next_version_key, origin_region.coord)
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
		generation_region_query_validate(&origin_region, query)

		surface_cells: [GENERATION_REGION_SURFACE_BIOME_CELL_CAPACITY]GenerationRegionSurfaceBiomeCell
		surface_cell_count := generation_region_surface_biome_cells_write(
			&origin_region,
			query,
			surface_cells[:],
		)
		log.assert(surface_cell_count == 16, "chunk surface biome query count mismatch")

		subterranean_cells: [GENERATION_REGION_SUBTERRANEAN_BIOME_CELL_CAPACITY]GenerationRegionSubterraneanBiomeCell
		subterranean_cell_count := generation_region_subterranean_biome_cells_write(
			&origin_region,
			query,
			subterranean_cells[:],
		)
		log.assert(subterranean_cell_count == 64, "chunk subterranean biome query count mismatch")

		water_nodes: [GENERATION_REGION_WATER_FEATURE_NODE_CAPACITY]WaterFeatureNode
		water_node_count := generation_region_water_feature_nodes_write(
			&origin_region,
			query,
			water_nodes[:],
		)
		log.assert(water_node_count > 0, "chunk Water Feature node query returned no data")

		water_segments: [GENERATION_REGION_WATER_FEATURE_SEGMENT_CAPACITY]WaterFeatureSegment
		water_segment_count := generation_region_water_feature_segments_write(
			&origin_region,
			query,
			water_segments[:],
		)
		log.assert(water_segment_count > 0, "chunk Water Feature segment query returned no data")

		water_anchors: [GENERATION_REGION_WATER_FEATURE_ANCHOR_CAPACITY]WaterFeatureAnchor
		water_anchor_count := generation_region_water_feature_anchors_write(
			&origin_region,
			query,
			water_anchors[:],
		)
		log.assert(water_anchor_count > 0, "chunk Water Feature anchor query returned no data")

		edge_chunk_bounds := BlockBounds3 {
			min = {x = 448, y = 448, z = 448},
			max = {x = 512, y = 512, z = 512},
		}
		edge_query := generation_region_query_make_default(edge_chunk_bounds)
		generation_region_query_validate(&origin_region, edge_query)

		surface_sample_coord := IVec2 {
			x = 17,
			z = -33,
		}
		surface_region_coord := generation_region_coord_from_block(
			surface_sample_coord.x,
			0,
			surface_sample_coord.z,
		)
		surface_region := generation_region_build(key, surface_region_coord)
		surface_direct := surface_biome_field_sample(
			key,
			surface_sample_coord.x,
			surface_sample_coord.z,
		)
		surface_region_sample := surface_biome_field_sample_from_region(
			&surface_region,
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
			&surface_region,
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
		subterranean_region := generation_region_build(key, subterranean_region_coord)
		subterranean_direct := subterranean_biome_field_sample(
			key,
			subterranean_sample_coord.x,
			subterranean_sample_coord.y,
			subterranean_sample_coord.z,
		)
		subterranean_region_sample := subterranean_biome_field_sample_from_region(
			&subterranean_region,
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
			&subterranean_region,
			subterranean_sample_coord.x,
			subterranean_sample_coord.y,
			subterranean_sample_coord.z,
		)
		debug_hydrology_subterranean_samples_assert_equal(
			subterranean_hydrology_direct,
			subterranean_hydrology_region,
		)

		log.debug("Generation Region contract checks passed")
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
