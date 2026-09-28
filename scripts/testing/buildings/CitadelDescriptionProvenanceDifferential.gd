extends SceneTree

## Diagnostic-only comparison of the two independent source restorations used
## by bootstrap base preparation and a later legacy preparation.
const Preparation = preload("res://scripts/buildings/BuildingPublicationPreparation.gd")
const Spatial = preload("res://scripts/buildings/BuildingSpatialDependencies.gd")
const Source = preload("res://scripts/buildings/BuildingPublicationSource.gd")
const SiteManifest = preload("res://scripts/buildings/BuildingSiteManifestBuilder.gd")
const INPUT := "res://artifacts/citadel-runtime-integration/actual-site-source-05/result.bin"
const SHA := "7a188cb480f3ed0332b0c568e86f18c061a265dd70a7bc3372ac7cbfd76144bf"
const BINDING := {"siteId":"atlas-1492:1,-3","sourceKey":"actual-site-source-05","generation":7}

func _initialize() -> void: call_deferred("_run")

static func _digest(value: Variant) -> String: return SiteManifest.canonical_value_digest(value)

static func _source_value(description) -> Array:
	return [description.binding,description.origin,description.parts,description.cells,description.navigation,
		description.furnishing_navigation,description.solid_records,description.publication_groups]

func _run() -> void:
	var report := {"schema":"citadel-description-provenance-differential/v1","complete":true,"passed":false,
		"fixture":INPUT,"fixtureSha256":FileAccess.get_sha256(INPUT),"binding":BINDING,"fields":{},"aggregate":{}}
	if report.fixtureSha256!=SHA: report.reason="fixture_sha256"; _finish(report); return
	var file := FileAccess.open(INPUT,FileAccess.READ)
	var source: Variant = file.get_var(false) if file!=null else null
	if file!=null: file.close()
	if not source is Dictionary or source.get("status")!="prepared" or not source.get("blueprint") is Dictionary \
			or not source.get("furnishingPlan") is Dictionary or not source.get("profile") is Dictionary:
		report.reason="fixture_shape"; _finish(report); return
	var first := Source.restore(source.blueprint,source.furnishingPlan)
	var second := Source.restore(source.blueprint,source.furnishingPlan)
	if not first.get("ready",false) or not second.get("ready",false): report.reason="restore_failed"; _finish(report); return
	var compact = Spatial.compile_description(first.blueprint,first.furnishingPlan,BINDING,source.profile.origin,Callable())
	var rebuilt = Spatial.compile_description(second.blueprint,second.furnishingPlan,BINDING,source.profile.origin,Callable())
	var dense = rebuilt.compile_navigation(Callable()) if rebuilt!=null else null
	if compact==null or dense==null: report.reason="description_compile_failed"; _finish(report); return
	for field: String in ["binding","origin","parts","cells","navigation","furnishing_navigation","solid_records","publication_groups"]:
		var left: Variant = compact.get(field) if compact is Dictionary else compact.get(field)
		var right: Variant = dense.get(field) if dense is Dictionary else dense.get(field)
		report.fields[field] = {"sameObject":is_same(left,right),"typedDigestLeft":_digest(left),"typedDigestRight":_digest(right),
			"typedEqual":_digest(left)==_digest(right),"leftReadOnly":left.is_read_only() if left is Array or left is Dictionary else null,
			"rightReadOnly":right.is_read_only() if right is Array or right is Dictionary else null}
	var compact_value := _source_value(compact)
	var dense_value := _source_value(dense)
	report.aggregate={"typedDigestCompact":_digest(compact_value),"typedDigestDense":_digest(dense_value),
		"typedEqual":_digest(compact_value)==_digest(dense_value),"descriptorsSameObject":is_same(compact,dense)}
	report.passed=report.aggregate.typedEqual and not report.aggregate.descriptorsSameObject \
		and report.fields.values().all(func(row): return row.typedEqual)
	if not report.passed: report.reason="provenance_differential"
	_finish(report)

func _finish(report: Dictionary) -> void:
	var path := OS.get_environment("CITADEL_DESCRIPTION_PROVENANCE_REPORT")
	if not path.is_absolute_path(): quit(2); return
	var file := FileAccess.open(path,FileAccess.WRITE)
	if file==null: quit(2); return
	file.store_string(JSON.stringify(report,"\t")); file.close()
	print("CITADEL DESCRIPTION PROVENANCE ",JSON.stringify({"passed":report.passed,"aggregate":report.aggregate}))
	quit(0 if report.passed else 1)
