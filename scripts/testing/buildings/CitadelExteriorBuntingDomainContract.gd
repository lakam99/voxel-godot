extends "res://scripts/testing/buildings/CitadelBuntingStageCapture.gd"
## Explicit synthetic ownership/domain unit contract; no physical acceptance.
const Domain = preload("res://scripts/buildings/CitadelExteriorBuntingDomain.gd")
const Blueprint = preload("res://scripts/buildings/BuildingBlueprint.gd")
const Structural = preload("res://scripts/buildings/CitadelStructuralCompletionRecipe.gd")
const PAV := "castle_keep_forecourt_pavilion_1"
const LANDMARK := "urban_civic_tower"
static func _source():
	var source = Blueprint.new("synthetic_exterior", 19, "masonry")
	source.add_part({"id": LANDMARK, "kind": "wall", "semantic": "citadel_civic_landmark", "position": Vector3(-14, 10.5, -8), "size": Vector3(8.4, 17, 9), "collision": true})
	Domain.declare(source.parts.back(), "landmark", 0)
	source.add_part({"id": PAV, "kind": "wall", "semantic": "castle_keep_forecourt_pavilion", "position": Vector3(17, 8, -10), "size": Vector3(7, 8, 4), "collision": true})
	Domain.declare(source.parts.back(), "forecourt_pavilion", 1)
	source.rooms = [{"id": "castle_courtyard", "role": "courtyard", "bounds": AABB(Vector3(-30, 0, -20), Vector3(60, 25, 40))},
		{"id": "interior", "role": "great_hall", "bounds": AABB(Vector3(-5, 0, 2), Vector3(10, 12, 10))}]
	source.add_part({"id": "rope", "kind": "beam", "semantic": "citadel_bunting_rope", "position": Vector3(0, 8, -10), "size": Vector3(17, 0.035, 0.035), "collision": false})
	source.add_part({"id": "flag", "kind": "pennant", "semantic": "citadel_bunting", "position": Vector3(0, 7.5, -10), "size": Vector3(0.7, 0.7, 0.055), "collision": false})
	source.recipe["citadelBuntingAssemblies"] = [{"ropeId": "rope", "pennantIds": ["flag"]}]
	var layout := [{"side": -1, "pavilionCenter": Vector3(-17, 0, -10), "pavilionWidth": 7, "pavilionHeight": 8, "pavilionDepth": 4},
		{"side": 1, "pavilionCenter": Vector3(17, 0, -10), "pavilionWidth": 7, "pavilionHeight": 8, "pavilionDepth": 4}]
	source.recipe["foundationHeight"] = 0
	source.recipe["castleGrammar"] = {"courtyardWidth": 60, "courtyardDepth": 40, "wallHeight": 25, "keepDepth": 8, "keepOffset": {"z": 0},
		"palaceGrammar": {"forecourtLayout": layout, "forecourtLayoutHash": JSON.stringify(layout).sha256_text()}}
	return Heads.Copy.copy_blueprint(source.snapshot())

func _work() -> Dictionary:
	state.begin_phase("exterior_domain_unit", 30000)
	var checks := {}; var source = _source()
	var before := var_to_bytes(source.snapshot())
	var association := Domain.association(source)
	checks.association_ready = association.get("ready", false)
	if not checks.association_ready: return {"passed": false, "checks": checks, "detail": association}
	var owners: Dictionary = association.owners
	var positive := Domain.build(source, owners)
	checks.domain_ready = positive.get("ready", false)
	checks.authored_center_inside_domain_accepted = positive.get("ready",false) and Domain.accepts_authored_center(source,owners,positive.domain.bounds.get_center())
	checks.authored_center_outside_domain_rejected = positive.get("ready",false) and not Domain.accepts_authored_center(source,owners,positive.domain.bounds.get_center()+Vector3(0,0,positive.domain.bounds.size.z+1.0))
	checks.immutable = before == var_to_bytes(source.snapshot())
	checks.actual_owner_ids = owners == {"leftPartId": LANDMARK, "rightPartId": PAV, "courtyardId": "castle_courtyard"}
	checks.interior_protected = positive.get("protectedRooms", []) == [source.rooms[1].bounds]
	source.parts.reverse(); source.rooms.reverse()
	checks.order_invariant = Domain.build(source, owners) == positive and Domain.association(source) == association
	Heads.Copy.clear_caches(source)
	checks.cache_sanitation_preserves_receipts = Domain.build(source, owners) == positive
	for label: String in ["missing", "extra", "side_type", "side", "role", "position", "size", "rotation", "collision", "semantic", "id", "binding_extra", "duplicate_role", "copied_foreign", "courtyard_role", "courtyard_id", "courtyard_size", "duplicate_courtyard", "duplicate_room", "room_bounds", "empty_overlap", "swapped", "foreign_owner", "extra_owner", "owner_type"]:
		var b = _source(); var owner: Dictionary = owners.duplicate(true); var p = b.find_part(PAV)
		match label:
			"missing": p.recipe.erase(Domain.MOUNT)
			"extra": p.recipe[Domain.MOUNT].extra = true
			"side_type": p.recipe[Domain.MOUNT].side = 1.0
			"side": p.recipe[Domain.MOUNT].side = -1
			"role": p.recipe[Domain.MOUNT].role = "landmark"
			"position": p.position.x += 1.0
			"size": p.size.x += 1.0
			"rotation": p.rotation.y = 0.1
			"collision": p.collision_enabled = false
			"semantic": p.semantic = "foreign_wall"
			"id": p.id = "renamed"
			"binding_extra": p.recipe[Domain.MOUNT].geometryBinding.extra = true
			"duplicate_role":
				b.add_part(p.snapshot()); b.parts.back().id = "duplicate"
				Domain.declare(b.parts.back(), "forecourt_pavilion", 1)
			"copied_foreign": b.find_part(LANDMARK).recipe[Domain.MOUNT] = p.recipe[Domain.MOUNT].duplicate(true)
			"courtyard_role": b.rooms[0].role = "great_hall"
			"courtyard_id": b.rooms[0].id = "changed"
			"courtyard_size":
				b.recipe.castleGrammar.courtyardWidth = 1
				b.rooms[0].bounds = AABB(Vector3(-0.5, 0, -20), Vector3(1, 25, 40))
			"duplicate_courtyard": b.rooms.append({"id": "other", "role": "courtyard", "bounds": b.rooms[0].bounds})
			"duplicate_room": b.rooms.append(b.rooms[1].duplicate(true))
			"room_bounds": b.rooms[1].bounds = AABB()
			"empty_overlap":
				p.position.z = 30; Domain.declare(p, "forecourt_pavilion", 1)
				var palace: Dictionary = b.recipe.castleGrammar.palaceGrammar
				palace.forecourtLayout[1].pavilionCenter.z = 30
				palace.forecourtLayoutHash = JSON.stringify(palace.forecourtLayout).sha256_text()
			"swapped": owner.leftPartId = PAV; owner.rightPartId = LANDMARK
			"foreign_owner": owner.rightPartId = "rope"
			"extra_owner": owner.extra = true
			"owner_type": owner.courtyardId = 2
		var frozen := var_to_bytes(b.snapshot())
		var rejected := Domain.build(b, owner)
		checks[label+"_rejected"] = not rejected.get("ready", false)
		if label == "empty_overlap": checks.empty_overlap_specific_reason = rejected.get("reason") == "empty_exterior_bunting_domain"
		if label == "courtyard_size": checks.courtyard_size_specific_reason = rejected.get("reason") == "exterior_bunting_outside_courtyard"
		checks[label+"_immutable"] = frozen == var_to_bytes(b.snapshot())
	var b = _source(); b.find_part("rope").recipe[Domain.OWNERS] = owners.duplicate(true)
	b.recipe.citadelBuntingAssemblies[0]["mounting"] = "exterior"
	checks.manifest_validates_association = Structural._bunting_manifest(b).get("ready", false)
	b.find_part("rope").recipe[Domain.OWNERS].leftPartId = "foreign"
	checks.stale_association_rejected_before_physical_selection = not Structural._bunting_manifest(b).get("ready", false)
	b.find_part("rope").recipe.erase(Domain.OWNERS)
	checks.deleted_association_rejected_before_physical_selection = not Structural._bunting_manifest(b).get("ready", false)
	b = _source()
	var foreign = b.find_part(LANDMARK); foreign.position.x += 1.0
	Domain.declare(foreign, "landmark", 0)
	checks.fresh_foreign_landmark_rejected = Domain.build(b, owners).get("reason") == "foreign_civic_landmark_declaration"
	b = _source(); foreign = b.find_part(PAV)
	foreign.position.x = -17; Domain.declare(foreign, "forecourt_pavilion", 1)
	checks.freshly_bound_wrong_side_rejected = Domain.build(b, owners).get("reason") == "foreign_forecourt_pavilion_declaration"
	for sides: Array in [[-1, 1], [-1.0, 1.0], [-1, 1.0], [-1.0, 1]]:
		b = _source()
		var palace: Dictionary = b.recipe.castleGrammar.palaceGrammar
		palace.forecourtLayout[0].side = sides[0]; palace.forecourtLayout[1].side = sides[1]
		palace.forecourtLayoutHash = JSON.stringify(palace.forecourtLayout).sha256_text()
		checks["numeric_sides_%d_%d" % [typeof(sides[0]), typeof(sides[1])]] = Domain.build(b, owners).get("ready", false)
	var invalid_sides: Array = [0, 2, -2, 0.5, 1.5, NAN, INF, -INF, "1", true]
	for index in range(invalid_sides.size()):
		b = _source()
		var palace: Dictionary = b.recipe.castleGrammar.palaceGrammar
		palace.forecourtLayout[1].side = invalid_sides[index]
		if typeof(invalid_sides[index]) != TYPE_FLOAT or is_finite(invalid_sides[index]):
			palace.forecourtLayoutHash = JSON.stringify(palace.forecourtLayout).sha256_text()
		else: checks["nonfinite_descriptor_%d" % index] = not Domain._finite_descriptor(palace.forecourtLayout)
		checks["invalid_numeric_side_%d" % index] = Domain.build(b, owners).get("reason") == "foreign_forecourt_pavilion_declaration"
	checks.deadline = state.checkpoint("exterior_domain_unit_completed")
	return {"passed": checks.values().all(func(value): return value == true), "checks": checks,
		"scope": "Synthetic strict ownership/domain and pre-selection manifest validation only; no rootedness, physical placement, production generation or gameplay acceptance."}
