extends "res://scripts/testing/buildings/CitadelBuntingStageCapture.gd"
## Synthetic geometry/physical unit contract, never generated gameplay proof.
const Fixture = preload("res://scripts/testing/buildings/CitadelExteriorBuntingDomainContract.gd")
const Domain = preload("res://scripts/buildings/CitadelExteriorBuntingDomain.gd")
const Structural = preload("res://scripts/buildings/CitadelStructuralCompletionRecipe.gd")
const Anchor = preload("res://scripts/buildings/CitadelBuntingAnchorRecipe.gd")
func _work() -> Dictionary:
	state.begin_phase("exterior_completion_unit", 30000)
	var source = Fixture._source(); var checks := {}
	# Use an exactly represented 15-unit synthetic gap so this contract reaches
	# completion's preservation gate, rather than interval construction rounding.
	var pavilion = source.find_part(Fixture.PAV); pavilion.position.x = 8.7
	var palace: Dictionary = source.recipe.castleGrammar.palaceGrammar
	palace.forecourtLayout[1].pavilionCenter.x = pavilion.position.x
	palace.forecourtLayoutHash = JSON.stringify(palace.forecourtLayout).sha256_text()
	Domain.declare(pavilion, "forecourt_pavilion", 1)
	for id: String in [Fixture.LANDMARK, Fixture.PAV]:
		var wall = source.find_part(id)
		var bottom: float = wall.position.y-wall.size.y*0.5
		source.add_part({"id": id+"_unit_root", "kind": "foundation", "semantic": "unit_foundation", "position": Vector3(wall.position.x, bottom*0.5, wall.position.z),
			"size": Vector3(wall.size.x, bottom, wall.size.z), "physicalIntent": "structural_root", "recipe": {"physicalRoot": true}})
	source = Heads.Copy.copy_blueprint(source.snapshot())
	source.find_part("rope").position.y = 9
	source.find_part("flag").position.y = 8.5
	var owners: Dictionary = Domain.association(source).owners
	source.find_part("rope").recipe[Domain.OWNERS] = owners
	source.recipe.citadelBuntingAssemblies[0]["mounting"] = "exterior"
	var domain := Domain.build(source, owners)
	checks.domain_covers_exact_faces = domain.get("ready", false) and domain.domain.bounds.position.x == source.transformed_part_bounds(source.find_part(Fixture.LANDMARK)).end.x and domain.domain.bounds.end.x == source.transformed_part_bounds(source.find_part(Fixture.PAV)).position.x
	var assemblies: Array = source.recipe.citadelBuntingAssemblies.duplicate(true)
	assemblies[0]["placementDomain"] = domain.domain
	var proposal := Anchor.prepare(source, assemblies, domain.protectedRooms, state.checkpoint)
	checks.initial_proposal_ready = proposal.get("ready", false)
	if not checks.initial_proposal_ready: return {"passed": false, "checks": checks, "failure": proposal}
	var snapshot: Dictionary = source.snapshot(); var changes := {}
	for record: Dictionary in proposal.changes: changes[record.id] = record
	for i in range(snapshot.parts.size()): snapshot.parts[i] = changes.get(snapshot.parts[i].id, snapshot.parts[i])
	source = Heads.Copy.copy_blueprint(snapshot)
	var physical: Dictionary = source.validate_physical_integrity_cancellable(state.checkpoint)
	checks.initial_all_parts_physically_pass = not physical.get("cancelled", false) and physical.get("checks", []).size() == source.parts.size() and physical.checks.all(func(row): return row.get("passed", false))
	var frozen := var_to_bytes(source.snapshot())
	var rope = source.find_part("rope")
	var obstacle := AABB(rope.position-Vector3.ONE*0.1, Vector3.ONE*0.2)
	var protected: Array = domain.protectedRooms.duplicate(true); protected.append(obstacle)
	var alternative := Anchor.prepare(source, assemblies, protected, state.checkpoint)
	checks.clear_alternative_exists = alternative.get("ready", false) and alternative.get("changes", []).any(func(r): return r.id == "rope" and r.position != rope.position)
	var rejected := Structural._complete_bunting(source, [obstacle], state.checkpoint)
	checks.passing_relocation_rejected = rejected.get("reason") == "passing_exterior_bunting_requires_relocation"
	checks.relocation_rejection_atomic = frozen == var_to_bytes(source.snapshot())
	var oversized: Array = []; oversized.resize(Anchor.MAX_PROTECTED)
	oversized.fill(AABB(Vector3(100,100,100), Vector3.ONE))
	var protected_before := var_to_bytes(oversized)
	var overflow := Structural._complete_bunting(source, oversized, state.checkpoint)
	checks.combined_protection_limit_rejects = overflow.get("reason") == "bunting_completion_failed" and overflow.get("detail", {}).get("reason") == "invalid_bunting_source"
	checks.overflow_atomic = frozen == var_to_bytes(source.snapshot()) and protected_before == var_to_bytes(oversized)
	checks.deadline = state.checkpoint("exterior_completion_unit_completed")
	return {"passed": checks.values().all(func(value): return value == true), "checks": checks, "rejection": rejected, "overflow": overflow,
		"scope": "Synthetic explicit roots and receipt/domain fixture: atomic rejection of relocating a physically passing assembly and combined protection overflow. No real candidate or gameplay acceptance."}
