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
	// Worm_Path is a sinuous passage type reserved for later density shaping.
	Worm_Path,
	// Flooded_Passage links water-bearing cave rooms and underground hydrology.
	Flooded_Passage,
	// Fracture is a narrow or jagged connector, often used by crystal cave regions.
	Fracture,
	// Collapsed_Corridor is a partially blocked passage type reserved for later shaping.
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
	id:                      FeatureID,
	owner:                   FeatureGridCoord3,
	kind:                    CaveNetworkEdgeKind,
	from_node_id:            FeatureID,
	to_node_id:              FeatureID,
	from_x, from_y, from_z:  f32,
	to_x, to_y, to_z:        f32,
	radius_blocks:           f32,
	influence_radius_blocks: f32,
	guaranteed_connection:   bool,
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
	cell_size_blocks = 384,
	jitter_fraction  = 0.72,
}

CAVE_NETWORK_DOMAIN_SALT :: u64(0x4d7c2a19e58f6b31)
CAVE_NETWORK_NODE_KIND_SALT :: u64(0x7b91d04e3c2a65f8)
CAVE_NETWORK_NODE_ROLE_SALT :: u64(0x92a4e7c51b6d308f)
CAVE_NETWORK_EDGE_ID_SALT :: u64(0xd36e5b0a481fc297)
CAVE_NETWORK_EDGE_KIND_SALT :: u64(0x6c58e21bd4a0739f)
CAVE_NETWORK_EDGE_ROLL_SALT :: u64(0x17e2b9d643a8c50f)
CAVE_NETWORK_ANCHOR_ID_SALT :: u64(0xa8c51e42d0f3796b)
CAVE_NETWORK_WATER_ANCHOR_ID_SALT :: u64(0x5f12d7a83be0469c)
CAVE_NETWORK_RADIUS_SALT :: u64(0xc47e1f902a6db358)
CAVE_NETWORK_SAMPLE_MARGIN_BLOCKS :: 512
CAVE_NETWORK_DEBUG_SURFACE_FALLOFF_BLOCKS :: f32(6)

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
		connection_radius_blocks = math.max(f32(8), radius * 0.45),
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
	kind := cave_network_edge_kind_select(from_node, to_node)
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

	return {
		id = cave_network_edge_id_from_nodes(from_node.id, to_node.id, kind),
		owner = from_node.owner,
		kind = kind,
		from_node_id = from_node.id,
		to_node_id = to_node.id,
		from_x = from_node.x,
		from_y = from_node.y,
		from_z = from_node.z,
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
	hydrology_layer_subterranean_sample_accumulate_node(
		&sample,
		water_feature_subterranean_node_from_owner(key, owner),
		block_x,
		block_y,
		block_z,
	)
	return sample
}

cave_anchor_from_node :: proc(key: FeatureGridKey, node: CaveNetworkNode) -> CaveAnchor {
	kind := cave_anchor_kind_from_node(node)
	x := node.x
	y := node.y
	z := node.z
	if kind == .Cave_Mouth || kind == .Sinkhole {
		surface_evaluation := surface_biome_profile_sample(
			key,
			i32(math.floor_f32(node.x)),
			i32(math.floor_f32(node.z)),
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
		influence_radius_blocks = math.max(f32(8), node.radius_blocks * 0.55),
		guaranteed_connection = node.major_region,
	}
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
	if role == .Connector || hydrology_sample.channel_influence > 0.35 {
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
	if from_node.role == .Water_Linked_Region ||
	   to_node.role == .Water_Linked_Region ||
	   from_node.kind == .Underground_Lake ||
	   to_node.kind == .Underground_Lake ||
	   from_node.kind == .River_Junction ||
	   to_node.kind == .River_Junction {
		return .Flooded_Passage
	}
	if from_node.biome_id == .Crystal_Geode_Network || to_node.biome_id == .Crystal_Geode_Network {
		return .Fracture
	}
	if from_node.major_region || to_node.major_region {
		return .Canyon
	}
	return .Tunnel
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
		distance := hydrology_distance_to_segment_2(
			x,
			z,
			edge.from_x,
			edge.from_z,
			edge.to_x,
			edge.to_z,
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
		log.assert(edge.from_node_id == node.id, "Cave Network edge must keep source node ID")
		log.assert(edge.radius_blocks > 0, "Cave Network edge radius must be positive")
		if node.major_region {
			log.assert(exists, "major Cave Network node must emit a guaranteed edge")
		}

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
