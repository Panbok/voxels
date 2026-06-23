package biomes

import "core:log"
import math "core:math"

//////////////////////////////////////
// Cave Network Types
/////////////////////////////////////

// CaveNetworkNodeKind identifies the local feature represented by one Cave Network node.
CaveNetworkNodeKind :: enum u8 {
	// Chamber is a general cave room used by ordinary cave networks and pockets.
	Chamber,
	// Biome_Hub is a central node for a major subterranean biome region.
	Biome_Hub,
	// Underground_Lake is a broad water-linked cave room or buried lake node.
	Underground_Lake,
	// River_Junction is a node where underground water passages or cave routes meet.
	River_Junction,
	// Magma_Pocket is a heat-biased hazardous chamber or future magma feature.
	Magma_Pocket,
	// Entrance is a node intended to connect cave structure toward the surface.
	Entrance,
	// Vertical_Shaft is a node that favors strong Y-axis cave connectivity.
	Vertical_Shaft,
	// Gateway is a connector between subterranean biome regions.
	Gateway,
	// Geode_Chamber is a crystal-biased room used by geode cave networks.
	Geode_Chamber,
}

// CaveNetworkEdgeKind identifies the intended passage shape between Cave Network nodes.
CaveNetworkEdgeKind :: enum u8 {
	// Tunnel is the default medium-width cave passage.
	Tunnel,
	// Canyon is a wider passage used for major-region connections.
	Canyon,
	// Worm_Path is a sinuous ordinary passage with stronger local meander.
	Worm_Path,
	// Flooded_Passage links water-bearing cave rooms and underground hydrology.
	Flooded_Passage,
	// Fracture is a narrow or jagged connector, often used by crystal cave regions.
	Fracture,
	// Collapsed_Corridor is a flatter, pinched ordinary passage.
	Collapsed_Corridor,
	// Vertical_Shaft is a passage with dominant vertical displacement.
	Vertical_Shaft,
}

// CaveRegionRole classifies whether a cave region needs guaranteed connectivity.
CaveRegionRole :: enum u8 {
	// Major_Region is an explorable subterranean region that must connect to the cave graph.
	Major_Region,
	// Pocket is a small ordinary cave region that may connect opportunistically.
	Pocket,
	// Connector is a region whose main purpose is linking other cave or water features.
	Connector,
	// Hazard is a dangerous region role reserved for later cave shaping and materials.
	Hazard,
	// Resource_Chamber is a small feature room for future resource or decoration placement.
	Resource_Chamber,
	// Sealed_Secret is allowed to remain isolated from the main cave graph.
	Sealed_Secret,
	// Water_Linked_Region is a cave region that should connect to hydrology features.
	Water_Linked_Region,
}

// CaveAnchorKind marks an intentional Cave Network connection to terrain or hydrology.
CaveAnchorKind :: enum u8 {
	// Cave_Mouth is a surface-facing entrance into a Cave Network.
	Cave_Mouth,
	// Sinkhole is a vertical or steep surface breach into underground space.
	Sinkhole,
	// Ravine_Breach connects a surface ravine or river-bank feature into caves.
	Ravine_Breach,
	// Vertical_Shaft anchors a shaft-style cave connection.
	Vertical_Shaft,
	// Underground_River_Source anchors the start or upstream side of a buried water route.
	Underground_River_Source,
	// Underground_River_Sink anchors the end or downstream side of a buried water route.
	Underground_River_Sink,
	// Lakebed_Breach intentionally links a surface lakebed to cave structure.
	Lakebed_Breach,
	// Seabed_Breach intentionally links sea or shoreline terrain to cave structure.
	Seabed_Breach,
	// Magma_Vent anchors a heat-biased vertical cave or future magma connection.
	Magma_Vent,
	// Subterranean_Biome_Gateway anchors a transition into or between underground biomes.
	Subterranean_Biome_Gateway,
}

CaveNetworkNode :: struct {
	id:                       FeatureID,
	owner:                    FeatureGridCoord3,
	kind:                     CaveNetworkNodeKind,
	role:                     CaveRegionRole,
	biome_id:                 BiomeID,
	x, y, z:                  f32,
	radius_blocks:            f32,
	connection_radius_blocks: f32,
	major_region:             bool,
}

CaveNetworkEdge :: struct {
	id:                       FeatureID,
	owner:                    FeatureGridCoord3,
	kind:                     CaveNetworkEdgeKind,
	from_node_id:             FeatureID,
	to_node_id:               FeatureID,
	from_biome_id:            BiomeID,
	to_biome_id:              BiomeID,
	from_x, from_y, from_z:   f32,
	bend_x, bend_y, bend_z:   f32,
	to_x, to_y, to_z:         f32,
	radius_blocks:            f32,
	influence_radius_blocks:  f32,
	guaranteed_connection:    bool,
	regional_seam_connection: bool,
}

CaveAnchor :: struct {
	id:                      FeatureID,
	owner:                   FeatureGridCoord3,
	feature_id:              FeatureID,
	target_feature_id:       FeatureID,
	kind:                    CaveAnchorKind,
	x, y, z:                 f32,
	influence_radius_blocks: f32,
	guaranteed_connection:   bool,
}

CaveNetworkDebugSurfaceSample :: struct {
	nearest_feature_id:      FeatureID,
	nearest_anchor_id:       FeatureID,
	nearest_distance_blocks: f32,
	network_feature_count:   u32,
	anchor_feature_count:    u32,
	network_influence:       f32,
	anchor_influence:        f32,
}

//////////////////////////////////////
// Cave Network Constants
/////////////////////////////////////

CAVE_NETWORK_GRID_CONFIG :: FeatureGridConfig {
	domain           = .Subterranean,
	level            = .Micro,
	cell_size_blocks = 768,
	jitter_fraction  = 0.72,
}

CAVE_NETWORK_DOMAIN_SALT :: u64(0x4d7c2a19e58f6b31)
CAVE_NETWORK_NODE_KIND_SALT :: u64(0x7b91d04e3c2a65f8)
CAVE_NETWORK_NODE_ROLE_SALT :: u64(0x92a4e7c51b6d308f)
CAVE_NETWORK_EDGE_ID_SALT :: u64(0xd36e5b0a481fc297)
CAVE_NETWORK_EDGE_KIND_SALT :: u64(0x6c58e21bd4a0739f)
CAVE_NETWORK_EDGE_ROLL_SALT :: u64(0x17e2b9d643a8c50f)
CAVE_NETWORK_EDGE_BEND_X_SALT :: u64(0xd947a38c12f06be5)
CAVE_NETWORK_EDGE_BEND_Y_SALT :: u64(0x74e219c63db805fa)
CAVE_NETWORK_EDGE_BEND_Z_SALT :: u64(0x2c80ad4f9e16b735)
CAVE_NETWORK_ANCHOR_ID_SALT :: u64(0xa8c51e42d0f3796b)
CAVE_NETWORK_WATER_ANCHOR_ID_SALT :: u64(0x5f12d7a83be0469c)
CAVE_NETWORK_RADIUS_SALT :: u64(0xc47e1f902a6db358)
CAVE_NETWORK_SURFACE_DEPTH_SALT :: u64(0xb5a74e29d6381c0f)
CAVE_NETWORK_SURFACE_ANCHOR_SALT :: u64(0x3f82b1d670a49ec5)
CAVE_NETWORK_SURFACE_ANCHOR_RADIUS_SALT :: u64(0x9ad41f8c7e63250b)
CAVE_NETWORK_SURFACE_ANCHOR_OFFSET_SALT :: u64(0x24a91cb087de35f6)
CAVE_NETWORK_SAMPLE_MARGIN_BLOCKS :: 256
CAVE_NETWORK_DEBUG_SURFACE_FALLOFF_BLOCKS :: f32(6)
CAVE_NETWORK_SURFACE_ADJACENT_OFFSET_BLOCKS :: f32(128)
CAVE_NETWORK_SURFACE_CLEARANCE_BLOCKS :: f32(12)
CAVE_NETWORK_SURFACE_MIN_DEPTH_BLOCKS :: f32(72)
CAVE_NETWORK_SURFACE_MAX_DEPTH_BLOCKS :: f32(152)
CAVE_NETWORK_SURFACE_OWNER_RADIUS_SCALE :: f32(0.45)
CAVE_NETWORK_SURFACE_ANCHOR_EMIT_ROLL_MAX :: f32(0.30)
CAVE_NETWORK_SURFACE_CAVE_MOUTH_ROLL_MAX :: f32(0.68)
CAVE_NETWORK_SURFACE_MOUTH_OFFSET_MIN_SCALE :: f32(0.36)
CAVE_NETWORK_SURFACE_MOUTH_OFFSET_MAX_SCALE :: f32(0.78)
CAVE_NETWORK_GRAPH_VERTICAL_WEIGHT_SCALE :: f32(1.85)
CAVE_NETWORK_GRAPH_BIOME_MISMATCH_WEIGHT_BLOCKS :: f32(96)
CAVE_NETWORK_GRAPH_REQUIRED_WEIGHT_BONUS_BLOCKS :: f32(80)
CAVE_NETWORK_GRAPH_LOOP_ROLL_MAX :: f32(0.46)
CAVE_NETWORK_GRAPH_LOOP_TARGET_NUMERATOR :: u32(7)
CAVE_NETWORK_GRAPH_LOOP_TARGET_DENOMINATOR :: u32(20)
CAVE_NETWORK_GRAPH_LOOP_MAX_WEIGHT_BLOCKS :: f32(980)
CAVE_NETWORK_GRAPH_LOOP_WEIGHT_JITTER_SCALE :: f32(0.24)
CAVE_NETWORK_GRAPH_LOCAL_EDGE_ROLL_MAX :: f32(0.30)
CAVE_NETWORK_GRAPH_LOCAL_EDGE_MAX_WEIGHT_BLOCKS :: f32(620)
CAVE_NETWORK_GRAPH_SEAM_EDGE_FACE_MARGIN_BLOCKS :: f32(256)
CAVE_NETWORK_GRAPH_SEAM_EDGE_MAX_WEIGHT_BLOCKS :: f32(720)
CAVE_NETWORK_GRAPH_SEAM_EDGE_REQUIRED_BONUS_BLOCKS :: f32(96)
CAVE_NETWORK_GRAPH_SEAM_EDGE_WEIGHT_JITTER_SCALE :: f32(0.14)
CAVE_NETWORK_GRAPH_SEAM_EDGE_MIN_RADIUS_BLOCKS :: f32(12)
CAVE_NETWORK_GRAPH_SEAM_EDGE_INFLUENCE_RADIUS_SCALE :: f32(1.65)

//////////////////////////////////////
// Cave Network Feature Methods
/////////////////////////////////////

cave_network_node_from_owner :: proc(
	key: FeatureGridKey,
	owner: FeatureGridCoord3,
) -> CaveNetworkNode {
	id := cave_network_node_id_from_owner(key, owner)
	hash := u64(id)
	config := CAVE_NETWORK_GRID_CONFIG
	cell_size := f32(config.cell_size_blocks)
	jitter_radius := cell_size * 0.5 * config.jitter_fraction
	x :=
		feature_grid_cell_center(owner.x, cell_size) +
		feature_grid_signed_unit_f32(hash, FEATURE_GRID_JITTER_X_SALT) * jitter_radius
	y :=
		feature_grid_cell_center(owner.y, cell_size) +
		feature_grid_signed_unit_f32(hash, FEATURE_GRID_JITTER_Y_SALT) * jitter_radius
	z :=
		feature_grid_cell_center(owner.z, cell_size) +
		feature_grid_signed_unit_f32(hash, FEATURE_GRID_JITTER_Z_SALT) * jitter_radius
	surface_evaluation := surface_biome_profile_sample(
		key,
		i32(math.floor_f32(x)),
		i32(math.floor_f32(z)),
	)
	surface_ceiling_y :=
		surface_evaluation.final_target.surface_height_blocks -
		CAVE_NETWORK_SURFACE_CLEARANCE_BLOCKS
	if owner.y >= 0 {
		depth_roll := feature_grid_unit_f32(hash, CAVE_NETWORK_SURFACE_DEPTH_SALT)
		surface_depth := regional_terrain_field_lerp(
			CAVE_NETWORK_SURFACE_MIN_DEPTH_BLOCKS,
			CAVE_NETWORK_SURFACE_MAX_DEPTH_BLOCKS,
			depth_roll,
		)
		y = surface_ceiling_y - surface_depth
	} else {
		y -= CAVE_NETWORK_SURFACE_ADJACENT_OFFSET_BLOCKS
		y = math.min(y, surface_ceiling_y - CAVE_NETWORK_SURFACE_MIN_DEPTH_BLOCKS)
	}

	biome_id, _, _, _ := subterranean_biome_identity_select(key, owner)
	fields := regional_terrain_fields_sample(
		key,
		i32(math.floor_f32(x)),
		i32(math.floor_f32(y)),
		i32(math.floor_f32(z)),
	)
	hydrology_sample := cave_network_hydrology_context_from_owner(
		key,
		owner,
		i32(math.floor_f32(x)),
		i32(math.floor_f32(y)),
		i32(math.floor_f32(z)),
	)
	profile := biome_profile_for(biome_id)
	role := cave_region_role_select(
		biome_id,
		fields,
		hydrology_sample,
		feature_grid_unit_f32(hash, CAVE_NETWORK_NODE_ROLE_SALT),
	)
	kind := cave_network_node_kind_select(
		biome_id,
		role,
		fields,
		hydrology_sample,
		feature_grid_unit_f32(hash, CAVE_NETWORK_NODE_KIND_SALT),
	)
	radius_roll := feature_grid_unit_f32(hash, CAVE_NETWORK_RADIUS_SALT)
	radius := cave_network_node_radius_blocks(biome_id, role, profile.cave_openness, radius_roll)
	if owner.y >= 0 {
		radius = math.max(f32(5), radius * CAVE_NETWORK_SURFACE_OWNER_RADIUS_SCALE)
	}

	return {
		id = id,
		owner = owner,
		kind = kind,
		role = role,
		biome_id = biome_id,
		x = x,
		y = y,
		z = z,
		radius_blocks = radius,
		connection_radius_blocks = math.max(f32(4), radius * 0.45),
		major_region = cave_region_role_requires_connectivity(role),
	}
}

cave_network_edge_from_owners :: proc(
	key: FeatureGridKey,
	owner, neighbor_owner: FeatureGridCoord3,
) -> (
	edge: CaveNetworkEdge,
	exists: bool,
) {
	from_node := cave_network_node_from_owner(key, owner)
	to_node := cave_network_node_from_owner(key, neighbor_owner)
	edge = cave_network_edge_from_nodes(from_node, to_node)
	exists = cave_network_edge_should_exist(edge, from_node, to_node)
	return
}

cave_network_edge_from_nodes :: proc(from_node, to_node: CaveNetworkNode) -> CaveNetworkEdge {
	return cave_network_edge_from_nodes_with_kind(
		from_node,
		to_node,
		cave_network_edge_kind_select(from_node, to_node),
	)
}

cave_network_seam_edge_from_nodes :: proc(from_node, to_node: CaveNetworkNode) -> CaveNetworkEdge {
	kind := cave_network_seam_edge_kind_select(from_node, to_node)
	edge := cave_network_edge_from_nodes_with_kind(from_node, to_node, kind)
	edge.radius_blocks = math.max(
		edge.radius_blocks,
		CAVE_NETWORK_GRAPH_SEAM_EDGE_MIN_RADIUS_BLOCKS,
	)
	edge.influence_radius_blocks = math.max(
		edge.influence_radius_blocks,
		edge.radius_blocks * CAVE_NETWORK_GRAPH_SEAM_EDGE_INFLUENCE_RADIUS_SCALE,
	)
	edge.guaranteed_connection = true
	edge.regional_seam_connection = true
	return edge
}

cave_network_seam_edge_kind_select :: proc(
	from_node, to_node: CaveNetworkNode,
) -> CaveNetworkEdgeKind {
	base_kind := cave_network_edge_kind_select(from_node, to_node)
	if base_kind == .Flooded_Passage || base_kind == .Vertical_Shaft {
		return base_kind
	}
	return .Canyon
}

cave_network_edge_from_nodes_with_kind :: proc(
	from_node, to_node: CaveNetworkNode,
	kind: CaveNetworkEdgeKind,
) -> CaveNetworkEdge {
	radius := math.max(
		f32(3),
		(from_node.connection_radius_blocks + to_node.connection_radius_blocks) * 0.5,
	)
	if kind == .Fracture {
		radius *= 0.65
	}
	if kind == .Flooded_Passage || kind == .Canyon {
		radius *= 1.20
	}
	id := cave_network_edge_id_from_nodes(from_node.id, to_node.id, kind)
	dx := to_node.x - from_node.x
	dy := to_node.y - from_node.y
	dz := to_node.z - from_node.z
	length_xz := math.sqrt_f32(dx * dx + dz * dz)
	length_3 := math.sqrt_f32(dx * dx + dy * dy + dz * dz)
	bend_scale := math.min(math.max(length_3 * 0.22, f32(14)), f32(110))
	normal_x := f32(0)
	normal_z := f32(0)
	if length_xz > 0.001 {
		normal_x = -dz / length_xz
		normal_z = dx / length_xz
	}
	vertical_scale := f32(0.32)
	if kind == .Vertical_Shaft {
		vertical_scale = 0.12
	}

	return {
		id = id,
		owner = from_node.owner,
		kind = kind,
		from_node_id = from_node.id,
		to_node_id = to_node.id,
		from_biome_id = from_node.biome_id,
		to_biome_id = to_node.biome_id,
		from_x = from_node.x,
		from_y = from_node.y,
		from_z = from_node.z,
		bend_x = (from_node.x + to_node.x) * 0.5 +
		normal_x *
			feature_grid_signed_unit_f32(u64(id), CAVE_NETWORK_EDGE_BEND_X_SALT) *
			bend_scale,
		bend_y = (from_node.y + to_node.y) * 0.5 +
		feature_grid_signed_unit_f32(u64(id), CAVE_NETWORK_EDGE_BEND_Y_SALT) *
			bend_scale *
			vertical_scale,
		bend_z = (from_node.z + to_node.z) * 0.5 +
		normal_z *
			feature_grid_signed_unit_f32(u64(id), CAVE_NETWORK_EDGE_BEND_Z_SALT) *
			bend_scale,
		to_x = to_node.x,
		to_y = to_node.y,
		to_z = to_node.z,
		radius_blocks = radius,
		influence_radius_blocks = math.max(f32(4), radius * 1.45),
		guaranteed_connection = from_node.major_region || to_node.major_region,
	}
}

cave_network_hydrology_context_from_owner :: proc(
	key: FeatureGridKey,
	owner: FeatureGridCoord3,
	block_x, block_y, block_z: i32,
) -> HydrologyLayerSubterraneanSample {
	sample := HydrologyLayerSubterraneanSample {
		nearest_feature_kind    = .Aquifer,
		nearest_distance_blocks = BIOME_FIELD_NO_DISTANCE,
		water_level_blocks      = f32(block_y),
	}
	node := water_feature_subterranean_node_from_owner(key, owner)
	if water_feature_subterranean_node_should_emit(node) {
		hydrology_layer_subterranean_sample_accumulate_node(
			&sample,
			node,
			block_x,
			block_y,
			block_z,
		)
	}
	return sample
}

cave_anchor_from_node :: proc(key: FeatureGridKey, node: CaveNetworkNode) -> CaveAnchor {
	kind := cave_anchor_kind_from_node(node)
	x := node.x
	y := node.y
	z := node.z
	if kind == .Cave_Mouth {
		offset_x, offset_z := cave_anchor_surface_mouth_offset_from_node(node)
		x += offset_x
		z += offset_z
	}
	if kind == .Cave_Mouth || kind == .Sinkhole {
		surface_evaluation := surface_biome_profile_sample(
			key,
			i32(math.floor_f32(x)),
			i32(math.floor_f32(z)),
		)
		y = surface_evaluation.final_target.surface_height_blocks
	}
	return {
		id = cave_anchor_id_from_feature(node.id, CAVE_NETWORK_ANCHOR_ID_SALT),
		owner = node.owner,
		feature_id = node.id,
		target_feature_id = node.id,
		kind = kind,
		x = x,
		y = y,
		z = z,
		influence_radius_blocks = cave_anchor_influence_radius_from_node(node, kind),
		guaranteed_connection = node.major_region,
	}
}

cave_anchor_surface_mouth_offset_from_node :: proc(
	node: CaveNetworkNode,
) -> (
	offset_x, offset_z: f32,
) {
	hash := feature_grid_hash_combine(u64(node.id), CAVE_NETWORK_SURFACE_ANCHOR_OFFSET_SALT)
	dir_x := feature_grid_signed_unit_f32(hash, CAVE_NETWORK_EDGE_BEND_X_SALT)
	dir_z := feature_grid_signed_unit_f32(hash, CAVE_NETWORK_EDGE_BEND_Z_SALT)
	dir_len := math.sqrt_f32(dir_x * dir_x + dir_z * dir_z)
	if dir_len <= 0.001 {
		dir_x = 0
		dir_z = 1
		dir_len = 1
	}
	dir_x /= dir_len
	dir_z /= dir_len
	radius := cave_anchor_influence_radius_from_node(node, .Cave_Mouth)
	distance_roll := feature_grid_unit_f32(hash, CAVE_NETWORK_SURFACE_ANCHOR_RADIUS_SALT)
	distance :=
		radius *
		regional_terrain_field_lerp(
			CAVE_NETWORK_SURFACE_MOUTH_OFFSET_MIN_SCALE,
			CAVE_NETWORK_SURFACE_MOUTH_OFFSET_MAX_SCALE,
			distance_roll,
		)
	return dir_x * distance, dir_z * distance
}

cave_anchor_influence_radius_from_node :: proc(
	node: CaveNetworkNode,
	kind: CaveAnchorKind,
) -> f32 {
	radius := math.max(f32(8), node.radius_blocks * 0.55)
	if kind == .Cave_Mouth || kind == .Sinkhole {
		roll := feature_grid_unit_f32(u64(node.id), CAVE_NETWORK_SURFACE_ANCHOR_RADIUS_SALT)
		radius = math.max(f32(6), radius + cave_anchor_surface_radius_adjust_blocks(kind, roll))
	}
	return radius
}

cave_anchor_surface_radius_adjust_blocks :: proc(kind: CaveAnchorKind, roll: f32) -> f32 {
	#partial switch kind {
	case .Cave_Mouth:
		return regional_terrain_field_lerp(-2.0, 4.0, roll)
	case .Sinkhole:
		return regional_terrain_field_lerp(-1.5, 3.0, roll)
	}
	return 0
}

cave_anchor_from_water_anchor :: proc(anchor: WaterFeatureAnchor) -> CaveAnchor {
	kind := CaveAnchorKind.Underground_River_Source
	#partial switch anchor.kind {
	case .Shoreline:
		kind = .Seabed_Breach
	case .Lakebed_Breach:
		kind = .Lakebed_Breach
	case .River_Bank:
		kind = .Ravine_Breach
	case .Aquifer_Breach:
		kind = .Underground_River_Sink
	case .Underground_River_Link:
		kind = .Underground_River_Source
	case .Flooded_Cave_Link:
		kind = .Underground_River_Sink
	}
	return {
		id = cave_anchor_id_from_feature(anchor.id, CAVE_NETWORK_WATER_ANCHOR_ID_SALT),
		owner = anchor.owner,
		feature_id = anchor.id,
		target_feature_id = anchor.feature_id,
		kind = kind,
		x = anchor.x,
		y = anchor.y,
		z = anchor.z,
		influence_radius_blocks = math.max(f32(8), anchor.influence_radius_blocks * 0.75),
		guaranteed_connection = true,
	}
}

cave_region_role_select :: proc(
	biome_id: BiomeID,
	fields: RegionalTerrainFields,
	hydrology_sample: HydrologyLayerSubterraneanSample,
	roll: f32,
) -> CaveRegionRole {
	water_influence := math.max(
		hydrology_sample.aquifer_influence,
		math.max(hydrology_sample.channel_influence, hydrology_sample.flooded_region_influence),
	)
	major_score := fields.subterranean_pressure * 0.45 + water_influence * 0.35

	#partial switch biome_id {
	case .Fungal_Vaults:
		major_score += 0.25
		if roll < major_score {
			return .Major_Region
		}
		if roll < major_score + 0.18 {
			return .Connector
		}
		return .Pocket
	case .Crystal_Geode_Network:
		if roll < major_score * 0.45 {
			return .Major_Region
		}
		if roll > 0.78 && water_influence < 0.35 {
			return .Sealed_Secret
		}
		if roll > 0.58 {
			return .Resource_Chamber
		}
		return .Pocket
	case .Buried_Aquifer_Caves:
		if water_influence > 0.20 || roll < major_score + 0.20 {
			return .Water_Linked_Region
		}
		if roll < 0.72 {
			return .Connector
		}
		return .Pocket
	}

	return .Pocket
}

cave_network_node_kind_select :: proc(
	biome_id: BiomeID,
	role: CaveRegionRole,
	fields: RegionalTerrainFields,
	hydrology_sample: HydrologyLayerSubterraneanSample,
	roll: f32,
) -> CaveNetworkNodeKind {
	if role == .Water_Linked_Region || hydrology_sample.flooded_region_influence > 0.45 {
		return .Underground_Lake
	}
	if role == .Connector {
		if cave_network_hydrology_should_force_water_route(hydrology_sample) {
			return .River_Junction
		}
		return .Gateway
	}
	if hydrology_sample.channel_influence > 0.35 {
		return .River_Junction
	}
	if role == .Major_Region {
		return .Biome_Hub
	}
	if fields.heat_affinity > 0.82 && roll > 0.60 {
		return .Magma_Pocket
	}

	#partial switch biome_id {
	case .Crystal_Geode_Network:
		return .Geode_Chamber
	case .Fungal_Vaults:
		if roll < 0.20 {
			return .Vertical_Shaft
		}
		return .Chamber
	case .Buried_Aquifer_Caves:
		if roll < 0.35 {
			return .Underground_Lake
		}
		return .River_Junction
	}
	return .Chamber
}

cave_network_hydrology_should_force_water_route :: proc(
	hydrology_sample: HydrologyLayerSubterraneanSample,
) -> bool {
	return(
		hydrology_sample.channel_influence > 0.22 ||
		hydrology_sample.flooded_region_influence > 0.28 ||
		hydrology_sample.aquifer_influence > 0.38 \
	)
}

cave_network_node_radius_blocks :: proc(
	biome_id: BiomeID,
	role: CaveRegionRole,
	cave_openness, roll: f32,
) -> f32 {
	base := regional_terrain_field_lerp(10, 24, roll) + cave_openness * 22
	switch role {
	case .Major_Region, .Water_Linked_Region:
		base *= 1.65
	case .Connector:
		base *= 1.10
	case .Sealed_Secret:
		base *= 0.70
	case .Pocket, .Hazard, .Resource_Chamber:
		base *= 1.0
	}

	if biome_id == .Fungal_Vaults {
		base *= 1.20
	} else if biome_id == .Crystal_Geode_Network {
		base *= 0.85
	} else if biome_id == .Buried_Aquifer_Caves {
		base *= 1.10
	}
	return math.max(f32(5), base)
}

cave_network_edge_kind_select :: proc(from_node, to_node: CaveNetworkNode) -> CaveNetworkEdgeKind {
	dy := math.abs(to_node.y - from_node.y)
	dx := math.abs(to_node.x - from_node.x)
	dz := math.abs(to_node.z - from_node.z)
	if dy > dx && dy > dz {
		return .Vertical_Shaft
	}
	from_water := cave_network_node_prefers_flooded_route(from_node)
	to_water := cave_network_node_prefers_flooded_route(to_node)
	if from_water && to_water {
		return .Flooded_Passage
	}
	roll := cave_network_edge_kind_roll(from_node.id, to_node.id)
	if from_water || to_water {
		if roll < 0.34 {
			return .Flooded_Passage
		}
		if roll < 0.70 {
			return .Worm_Path
		}
		return .Collapsed_Corridor
	}
	if from_node.biome_id == .Crystal_Geode_Network || to_node.biome_id == .Crystal_Geode_Network {
		return .Fracture
	}
	if from_node.kind == .Gateway || to_node.kind == .Gateway {
		if roll < 0.62 {
			return .Worm_Path
		}
		return .Collapsed_Corridor
	}
	if from_node.major_region || to_node.major_region {
		if from_node.kind != .Gateway && to_node.kind != .Gateway {
			return .Canyon
		}
	}
	if roll < 0.10 {
		return .Worm_Path
	}
	if roll < 0.16 {
		return .Collapsed_Corridor
	}
	return .Tunnel
}

cave_network_node_prefers_flooded_route :: proc(node: CaveNetworkNode) -> bool {
	return(
		node.role == .Water_Linked_Region ||
		node.kind == .Underground_Lake ||
		node.kind == .River_Junction \
	)
}

cave_network_edge_kind_roll :: proc(from_node_id, to_node_id: FeatureID) -> f32 {
	h := feature_grid_hash_combine(u64(from_node_id), CAVE_NETWORK_EDGE_KIND_SALT)
	h = feature_grid_hash_combine(h, u64(to_node_id))
	return feature_grid_unit_f32(h, CAVE_NETWORK_EDGE_KIND_SALT)
}

cave_network_edge_should_exist :: proc(
	edge: CaveNetworkEdge,
	from_node, to_node: CaveNetworkNode,
) -> bool {
	if edge.guaranteed_connection {
		return true
	}
	if from_node.role == .Sealed_Secret || to_node.role == .Sealed_Secret {
		return false
	}
	if from_node.role == .Connector || to_node.role == .Connector {
		return true
	}
	roll := feature_grid_unit_f32(u64(edge.id), CAVE_NETWORK_EDGE_ROLL_SALT)
	threshold := f32(0.34)
	if from_node.biome_id == to_node.biome_id {
		threshold += 0.18
	}
	if edge.kind == .Fracture {
		threshold -= 0.08
	}
	return roll < threshold
}

cave_region_role_requires_connectivity :: proc(role: CaveRegionRole) -> bool {
	return role == .Major_Region || role == .Water_Linked_Region || role == .Connector
}

cave_anchor_kind_from_node :: proc(node: CaveNetworkNode) -> CaveAnchorKind {
	if node.owner.y >= 0 {
		if node.kind == .Vertical_Shaft {
			return .Sinkhole
		}
		roll := feature_grid_unit_f32(u64(node.id), CAVE_NETWORK_SURFACE_ANCHOR_SALT)
		if roll < CAVE_NETWORK_SURFACE_CAVE_MOUTH_ROLL_MAX {
			return .Cave_Mouth
		}
		return .Sinkhole
	}
	if node.kind == .Magma_Pocket {
		return .Magma_Vent
	}
	if node.kind == .Vertical_Shaft {
		return .Vertical_Shaft
	}
	if node.role == .Water_Linked_Region {
		return .Underground_River_Source
	}
	if node.role == .Major_Region {
		if node.owner.y >= 0 {
			return .Sinkhole
		}
		return .Subterranean_Biome_Gateway
	}
	if node.kind == .Entrance {
		return .Cave_Mouth
	}
	return .Subterranean_Biome_Gateway
}

cave_node_should_emit_anchor :: proc(node: CaveNetworkNode) -> bool {
	if node.role == .Sealed_Secret {
		return false
	}
	if node.owner.y >= 0 {
		roll := feature_grid_unit_f32(u64(node.id), CAVE_NETWORK_SURFACE_ANCHOR_SALT)
		return(
			node.major_region ||
			node.kind == .Vertical_Shaft ||
			roll < CAVE_NETWORK_SURFACE_ANCHOR_EMIT_ROLL_MAX \
		)
	}
	return node.major_region || node.kind == .Vertical_Shaft || node.kind == .Magma_Pocket
}

//////////////////////////////////////
// Cave Network IDs
/////////////////////////////////////

cave_network_node_id_from_owner :: proc(
	key: FeatureGridKey,
	owner: FeatureGridCoord3,
) -> FeatureID {
	h := feature_grid_key_hash(key)
	h = feature_grid_hash_combine(h, CAVE_NETWORK_DOMAIN_SALT)
	h = feature_grid_hash_combine(h, FEATURE_GRID_DIMENSION_3)
	h = feature_grid_hash_combine(h, feature_grid_hash_i32(owner.x))
	h = feature_grid_hash_combine(h, feature_grid_hash_i32(owner.y))
	h = feature_grid_hash_combine(h, feature_grid_hash_i32(owner.z))
	return FeatureID(h)
}

cave_network_edge_id_from_nodes :: proc(
	from_node_id, to_node_id: FeatureID,
	kind: CaveNetworkEdgeKind,
) -> FeatureID {
	h := feature_grid_hash_combine(u64(from_node_id), CAVE_NETWORK_EDGE_ID_SALT)
	h = feature_grid_hash_combine(h, u64(to_node_id))
	h = feature_grid_hash_combine(h, u64(u8(kind)))
	return FeatureID(h)
}

cave_anchor_id_from_feature :: proc(feature_id: FeatureID, salt: u64) -> FeatureID {
	return FeatureID(feature_grid_hash_combine(u64(feature_id), salt))
}

//////////////////////////////////////
// Cave Debug Sampling Methods
/////////////////////////////////////

cave_network_debug_surface_sample_from_region :: proc(
	region: ^GenerationRegion,
	block_x, block_z: i32,
) -> CaveNetworkDebugSurfaceSample {
	log.assert(
		generation_region_bounds_contains_block_xz(region.bounds, block_x, block_z),
		"surface cave debug sample must be inside the Generation Region X/Z bounds",
	)

	sample := CaveNetworkDebugSurfaceSample {
		nearest_distance_blocks = BIOME_FIELD_NO_DISTANCE,
	}
	x := f32(block_x) + 0.5
	z := f32(block_z) + 0.5

	for i := u32(0); i < region.cave_network_node_count; i += 1 {
		node := region.cave_network_nodes[i]
		distance := hydrology_distance_2(x, z, node.x, node.z)
		influence := cave_network_debug_surface_influence(distance, node.radius_blocks * 0.32)
		if influence <= 0 {
			continue
		}
		sample.network_feature_count += 1
		sample.network_influence = math.max(sample.network_influence, influence)
		cave_network_debug_surface_note_nearest(&sample, node.id, distance)
	}

	for i := u32(0); i < region.cave_network_edge_count; i += 1 {
		edge := region.cave_network_edges[i]
		distance := math.min(
			hydrology_distance_to_segment_2(
				x,
				z,
				edge.from_x,
				edge.from_z,
				edge.bend_x,
				edge.bend_z,
			),
			hydrology_distance_to_segment_2(x, z, edge.bend_x, edge.bend_z, edge.to_x, edge.to_z),
		)
		influence := cave_network_debug_surface_influence(
			distance,
			math.max(f32(3), edge.radius_blocks * 0.24),
		)
		if influence <= 0 {
			continue
		}
		sample.network_feature_count += 1
		sample.network_influence = math.max(sample.network_influence, influence)
		cave_network_debug_surface_note_nearest(&sample, edge.id, distance)
	}

	for i := u32(0); i < region.cave_anchor_count; i += 1 {
		anchor := region.cave_anchors[i]
		distance := hydrology_distance_2(x, z, anchor.x, anchor.z)
		influence := cave_network_debug_surface_influence(
			distance,
			math.max(f32(4), anchor.influence_radius_blocks * 0.45),
		)
		if influence <= 0 {
			continue
		}
		sample.anchor_feature_count += 1
		sample.anchor_influence = math.max(sample.anchor_influence, influence)
		if sample.nearest_anchor_id == FeatureID(0) || distance < sample.nearest_distance_blocks {
			sample.nearest_anchor_id = anchor.id
		}
		cave_network_debug_surface_note_nearest(&sample, anchor.id, distance)
	}
	return sample
}

cave_network_debug_surface_influence :: proc(distance, radius: f32) -> f32 {
	return hydrology_feature_influence(
		distance,
		math.max(f32(1), radius),
		CAVE_NETWORK_DEBUG_SURFACE_FALLOFF_BLOCKS,
	)
}

cave_network_debug_surface_note_nearest :: proc(
	sample: ^CaveNetworkDebugSurfaceSample,
	feature_id: FeatureID,
	distance: f32,
) {
	if sample.nearest_feature_id == FeatureID(0) || distance < sample.nearest_distance_blocks {
		sample.nearest_feature_id = feature_id
		sample.nearest_distance_blocks = distance
	}
}

//////////////////////////////////////
// Debug Methods
/////////////////////////////////////

when ODIN_DEBUG {

	cave_network_debug_contract_checks_run :: proc() {
		key := feature_grid_key_make(0x123456789abcdef0, 1)
		next_version_key := feature_grid_key_make(key.world_seed, key.generator_version + 1)
		owner := FeatureGridCoord3 {
			x = 0,
			y = -1,
			z = 0,
		}

		node := cave_network_node_from_owner(key, owner)
		node_again := cave_network_node_from_owner(key, owner)
		next_version_node := cave_network_node_from_owner(next_version_key, owner)
		log.assert(node.id == node_again.id, "Cave Network node IDs must be stable")
		log.assert(
			node.id != next_version_node.id,
			"Cave Network node IDs must include generator version",
		)
		log.assert(
			biome_id_is_subterranean(node.biome_id),
			"Cave Network node must use a subterranean biome identity",
		)
		log.assert(node.radius_blocks > 0, "Cave Network node radius must be positive")

		edge, exists := cave_network_edge_from_owners(
			key,
			owner,
			{x = owner.x + 1, y = owner.y, z = owner.z},
		)
		neighbor_node := cave_network_node_from_owner(
			key,
			{x = owner.x + 1, y = owner.y, z = owner.z},
		)
		log.assert(edge.from_node_id == node.id, "Cave Network edge must keep source node ID")
		log.assert(
			edge.from_biome_id == node.biome_id,
			"Cave Network edge must keep source subterranean biome ID",
		)
		log.assert(
			edge.to_biome_id == neighbor_node.biome_id,
			"Cave Network edge must keep target subterranean biome ID",
		)
		log.assert(edge.radius_blocks > 0, "Cave Network edge radius must be positive")
		if node.major_region {
			log.assert(exists, "major Cave Network node must emit a guaranteed edge")
		}
		dry_connector_kind := cave_network_node_kind_select(
			.Fungal_Vaults,
			.Connector,
			{},
			{},
			0.5,
		)
		water_connector_kind := cave_network_node_kind_select(
			.Fungal_Vaults,
			.Connector,
			{},
			{channel_influence = 0.4},
			0.5,
		)
		log.assert(
			dry_connector_kind == .Gateway,
			"dry Cave Network connectors should become biome gateways, not river junctions",
		)
		log.assert(
			water_connector_kind == .River_Junction,
			"water-influenced Cave Network connectors should remain river junctions",
		)
		log.assert(
			CAVE_NETWORK_SURFACE_ANCHOR_EMIT_ROLL_MAX >= 0.20 &&
			CAVE_NETWORK_SURFACE_ANCHOR_EMIT_ROLL_MAX < CAVE_NETWORK_SURFACE_CAVE_MOUTH_ROLL_MAX,
			"surface Cave Network anchors should stay sparse while Cave Mouth bias is tuned separately",
		)
		log.assert(
			CAVE_NETWORK_SURFACE_CAVE_MOUTH_ROLL_MAX > 0.5 &&
			CAVE_NETWORK_SURFACE_CAVE_MOUTH_ROLL_MAX < 0.75,
			"surface Cave Network anchors should bias toward cave mouths without eliminating sinkholes",
		)
		gateway_from := CaveNetworkNode {
			id                       = FeatureID(0x501),
			kind                     = .Biome_Hub,
			role                     = .Major_Region,
			biome_id                 = .Fungal_Vaults,
			connection_radius_blocks = 12,
			major_region             = true,
		}
		gateway_to := CaveNetworkNode {
			id                       = FeatureID(0x502),
			kind                     = .Gateway,
			role                     = .Connector,
			biome_id                 = .Fungal_Vaults,
			connection_radius_blocks = 7,
			x                        = 64,
		}
		log.assert(
			cave_network_edge_kind_select(gateway_from, gateway_to) != .Canyon,
			"dry Cave Network gateways should not force canyon passages from major rooms",
		)
		log.assert(
			cave_network_edge_kind_select(gateway_from, gateway_to) != .Tunnel,
			"dry Cave Network gateways should use irregular transition passages",
		)
		water_from := CaveNetworkNode {
			id                       = FeatureID(0x701),
			kind                     = .Underground_Lake,
			role                     = .Water_Linked_Region,
			biome_id                 = .Buried_Aquifer_Caves,
			connection_radius_blocks = 10,
			major_region             = true,
		}
		water_to := CaveNetworkNode {
			id                       = FeatureID(0x702),
			kind                     = .River_Junction,
			role                     = .Water_Linked_Region,
			biome_id                 = .Buried_Aquifer_Caves,
			connection_radius_blocks = 8,
			x                        = 64,
			major_region             = true,
		}
		log.assert(
			cave_network_edge_kind_select(water_from, water_to) == .Flooded_Passage,
			"water-to-water Cave Network routes should stay flooded",
		)
		mixed_non_flooded_seen := false
		for candidate := u64(1); candidate < 96; candidate += 1 {
			water_from.id = FeatureID(candidate)
			kind := cave_network_edge_kind_select(water_from, gateway_to)
			if kind == .Worm_Path || kind == .Collapsed_Corridor {
				mixed_non_flooded_seen = true
				break
			}
		}
		log.assert(
			mixed_non_flooded_seen,
			"mixed water/dry Cave Network routes should not all collapse to flooded passages",
		)
		log.assert(
			cave_network_edge_kind_roll(FeatureID(1), FeatureID(2)) !=
			cave_network_edge_kind_roll(FeatureID(2), FeatureID(1)),
			"Cave Network ordinary edge kind roll should preserve edge direction entropy",
		)
		ordinary_from := CaveNetworkNode {
			id                       = FeatureID(10),
			kind                     = .Chamber,
			role                     = .Pocket,
			biome_id                 = .Fungal_Vaults,
			connection_radius_blocks = 5,
		}
		ordinary_to := CaveNetworkNode {
			id                       = FeatureID(11),
			kind                     = .Chamber,
			role                     = .Pocket,
			biome_id                 = .Fungal_Vaults,
			connection_radius_blocks = 5,
			x                        = 64,
		}
		worm_seen := false
		collapsed_seen := false
		for candidate := u64(1); candidate < 96; candidate += 1 {
			ordinary_from.id = FeatureID(candidate)
			kind := cave_network_edge_kind_select(ordinary_from, ordinary_to)
			if kind == .Worm_Path {
				worm_seen = true
			}
			if kind == .Collapsed_Corridor {
				collapsed_seen = true
			}
		}
		log.assert(
			worm_seen && collapsed_seen,
			"Cave Network ordinary edge selection should make worm and collapsed passages reachable",
		)
		seam_edge := cave_network_seam_edge_from_nodes(ordinary_from, ordinary_to)
		log.assert(
			seam_edge.regional_seam_connection && seam_edge.guaranteed_connection,
			"Cave Network seam edges should carry explicit regional seam connectivity metadata",
		)
		log.assert(
			seam_edge.radius_blocks >= CAVE_NETWORK_GRAPH_SEAM_EDGE_MIN_RADIUS_BLOCKS,
			"Cave Network seam edges should keep a minimum cross-region corridor radius",
		)
		log.assert(
			cave_anchor_surface_radius_adjust_blocks(.Cave_Mouth, 1.0) >
			cave_anchor_surface_radius_adjust_blocks(.Cave_Mouth, 0.0),
			"Cave Mouth anchor radius profile should support wider and smaller openings",
		)
		log.assert(
			cave_anchor_surface_radius_adjust_blocks(.Sinkhole, 1.0) >
			cave_anchor_surface_radius_adjust_blocks(.Sinkhole, 0.0),
			"Sinkhole anchor radius profile should support wider and smaller throats",
		)
		anchor_radius_node := CaveNetworkNode {
			id                       = FeatureID(0xabc),
			kind                     = .Chamber,
			role                     = .Pocket,
			biome_id                 = .Fungal_Vaults,
			radius_blocks            = 16,
			connection_radius_blocks = 6,
		}
		log.assert(
			cave_anchor_influence_radius_from_node(
				anchor_radius_node,
				.Subterranean_Biome_Gateway,
			) ==
			math.max(f32(8), anchor_radius_node.radius_blocks * 0.55),
			"non-surface cave anchors should keep the base influence radius",
		)
		mouth_offset_node := CaveNetworkNode {
			id = FeatureID(0xabe),
			owner = {x = 0, y = -1, z = 0},
			kind = .Entrance,
			role = .Pocket,
			biome_id = .Fungal_Vaults,
			x = 16,
			y = -72,
			z = 16,
			radius_blocks = 12,
			connection_radius_blocks = 5,
		}
		mouth_offset_anchor := cave_anchor_from_node(key, mouth_offset_node)
		mouth_offset_dx := mouth_offset_anchor.x - mouth_offset_node.x
		mouth_offset_dz := mouth_offset_anchor.z - mouth_offset_node.z
		log.assert(
			mouth_offset_anchor.kind == .Cave_Mouth &&
			mouth_offset_dx * mouth_offset_dx + mouth_offset_dz * mouth_offset_dz > 4,
			"Cave Mouth anchors should offset laterally from their node instead of opening straight above it",
		)
		sinkhole_offset_node := mouth_offset_node
		sinkhole_offset_node.id = FeatureID(0xabf)
		sinkhole_offset_node.owner = {
			x = 0,
			y = 0,
			z = 0,
		}
		sinkhole_offset_node.kind = .Vertical_Shaft
		sinkhole_offset_anchor := cave_anchor_from_node(key, sinkhole_offset_node)
		log.assert(
			sinkhole_offset_anchor.kind == .Sinkhole &&
			sinkhole_offset_anchor.x == sinkhole_offset_node.x &&
			sinkhole_offset_anchor.z == sinkhole_offset_node.z,
			"Sinkhole anchors should keep vertical breach alignment while Cave Mouths offset laterally",
		)

		anchor := cave_anchor_from_node(key, node)
		log.assert(anchor.id != FeatureID(0), "Cave Anchor ID must be non-zero")
		if node.major_region {
			log.assert(
				anchor.guaranteed_connection,
				"major Cave Network node anchor must be guaranteed",
			)
		}

		water_anchor := water_feature_node_anchor(
			water_feature_subterranean_node_from_owner(key, owner),
		)
		cave_water_anchor := cave_anchor_from_water_anchor(water_anchor)
		log.assert(
			cave_water_anchor.target_feature_id == water_anchor.feature_id,
			"Cave Anchor derived from water must retain target Water Feature ID",
		)

		log.debug("Cave Network contract checks passed")
	}

}
