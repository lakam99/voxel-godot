extends RefCounted

## Value-only cut instruction for an aperture-tagged masonry part.  The worker
## never cuts meshes or allocates rendering resources: the scene owner validates
## this declaration against its restored peers, then runs the existing aperture
## cutter and masonry upload sequence.
const Preparation = preload("res://scripts/buildings/BuildingPublicationPreparation.gd")

static func compile(part, geometry: Dictionary, blueprint) -> Dictionary:
	if part == null or blueprint == null or not part.recipe.has("masonryApertureSource"):
		return {}
	var key := String(part.recipe.get("masonryApertureSource", ""))
	var declarations: Variant = blueprint.recipe.get("facadeApertures", {})
	if key.is_empty() or not declarations is Dictionary:
		return {}
	var declaration: Variant = declarations.get(key)
	if not declaration is Dictionary or not declaration.get("partIds") is Array:
		return {}
	var peers: Dictionary = {}
	for peer_id_value in declaration.partIds:
		var peer_id := String(peer_id_value)
		var peer = blueprint.find_part(peer_id)
		if peer_id.is_empty() or peer == null:
			return {}
		var binding := Preparation.static_record_binding(peer.snapshot())
		if binding.is_empty(): return {}
		peers[peer_id] = binding
	var frozen_declaration: Variant = Preparation._freeze_value(declaration)
	var frozen_geometry: Variant = Preparation._freeze_value(geometry)
	if not frozen_declaration is Dictionary or not frozen_geometry is Dictionary or frozen_geometry.is_empty():
		return {}
	peers.make_read_only()
	var packet := {"kind":"masonry_aperture_cut/v1", "partId":String(part.id),
		"binding":Preparation.static_record_binding(part.snapshot()), "key":key,
		"declaration":frozen_declaration, "peerBindings":peers, "geometry":frozen_geometry}
	if String(packet.binding).is_empty(): return {}
	packet.make_read_only()
	return packet
