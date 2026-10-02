extends RefCounted
class_name StructureSystem

const StructureDoorRulesScript := preload("res://scripts/StructureDoorRules.gd")
const StructureLootScript := preload("res://scripts/StructureLoot.gd")
const TownRuntimeManifestScript := preload("res://scripts/world/TownRuntimeManifest.gd")
const StartupReadinessResultScript := preload("res://scripts/world/StartupReadinessResult.gd")
const CitadelTerrainAdmissionScript := preload("res://scripts/world/CitadelTerrainAdmission.gd")
const CitadelSiteFieldScript := preload("res://scripts/world/CitadelSiteField.gd")
const CitadelPublicationServiceScript := preload("res://scripts/world/CitadelPublicationService.gd")
const GeneratedStructureRuntimeBindingsScript := preload("res://scripts/world/GeneratedStructureRuntimeBindings.gd")
const StandaloneSourceScript := preload("res://scripts/world/StandaloneStructureCandidate.gd")
const NavigationConstantsScript := preload("res://scripts/npc_ai/NpcConstants.gd")

const STREAMING_STRUCTURE_OPS_PER_FRAME := 24
const STREAMING_STRUCTURE_FRAME_BUDGET_MS := 6.0
const STREAMING_STRUCTURE_QUEUE_COMPACT_THRESHOLD := 256
const CITADEL_PUBLICATION_BUDGET_USEC := 4000
const STANDALONE_ADMISSION_SAMPLES_PER_SLICE := 2
const STANDALONE_ADMISSION_BUDGET_USEC := 1200
const ORDINARY_VISUAL_SOURCE_MAX_EXPECTED_BLOCKS := 8192
const ORDINARY_VISUAL_QUERY_MAX_EXPECTED_BLOCKS := 16384

var main
var loot
var generated_towns := {}
var generated_structures := {}
var generated_building_count := 0
var generated_town_count := 0
var generated_mine_count := 0
var generated_ruin_count := 0
var generated_shrine_count := 0
var generated_camp_count := 0
var generated_path_count := 0
var generated_door_count := 0
var generated_utility_count := 0
var town_home_records := {}
var pending_structure_ops: Array = []
var pending_structure_retry_ops: Array = []
var pending_structure_op_index := 0
var defer_structure_ops := false
var deferred_town_home_records := {}
var town_manifest_publish_states := {}
var active_structure_town_key := ""
var active_structure_visual_source_id := ""
var ordinary_visual_sources := {}
var removed_generated_structure_blocks := {}
var ordinary_visual_revision := 0
var terrain_surface_sample_cache := {}
var terrain_footprint_records := {}
var natural_prop_exclusion_records := {}
var surface_prop_exclusion_revision := 0
var private_interior_records := {}
var private_interior_revision := 0
var town_home_records_revision := 0
var citadel_terrain_admission = CitadelTerrainAdmissionScript.new()
var citadel_publication = CitadelPublicationServiceScript.new()
var citadel_runtime_bindings
var regional_source_revision := 0
var regional_source_generation := 0
var regional_requirements_cache := {}
var regional_standalone_requests := {}
var standalone_admission_states := {}

func setup(main_node) -> void:
    regional_source_generation += 1
    surface_prop_exclusion_revision += 1
    main = main_node
    loot = StructureLootScript.new()
    configure_citadel_terrain_admission()

func configure_citadel_terrain_admission() -> void:
    citadel_terrain_admission.configure(String(main.seed_text), main.town_region_cache, {
        "regionCells": int(main.STRUCTURE_REGION_CELLS),
        "spawnChance": float(main.STRUCTURE_SPAWN_CHANCE)
    })
    citadel_publication.configure(citadel_terrain_admission)
    bind_citadel_runtime()

func bind_citadel_runtime() -> bool:
    if citadel_runtime_bindings != null and citadel_runtime_bindings.available(): return true
    if citadel_publication.requires_scene_retirement(): return false
    var bindings = GeneratedStructureRuntimeBindingsScript.new()
    if not bindings.configure(main): return false
    if not citadel_publication.configure_construction_guard(bindings.construction_members_allowed,true): return false
    if not citadel_publication.configure_door_publication(bindings.register_door, bindings.retire_door): return false
    if not citadel_publication.configure_scene_publication(main, bindings.publish_tree, bindings.retire_tree, true): return false
    citadel_runtime_bindings = bindings
    return true

func citadel_physical_publication_state(bounds: Rect2i) -> Dictionary:
    var result: Dictionary = citadel_publication.physical_publication_state(bounds)
    if result.get("status") == "ready" and result.get("required", false) \
        and (citadel_runtime_bindings == null or not citadel_runtime_bindings.available()):
        return {"status":"pending", "reason":"landmark_runtime_owners_pending"}
    return result

func region_citadel_visual_source(bounds: Rect2i) -> Dictionary:
    return citadel_publication.visual_source_state(bounds)

func region_ordinary_visual_source(bounds: Rect2i) -> Dictionary:
    if not is_instance_valid(main) or not CitadelPublicationServiceScript._bounded_region_rectangle(bounds):
        return {"status":"failed","reason":"invalid_ordinary_visual_source_bounds"}
    var source_ids: Dictionary = {}
    var town_size := int(main.TOWN_REGION_CELLS)
    var structure_size := int(main.STRUCTURE_REGION_CELLS)
    if town_size <= 0 or structure_size <= 0:
        return {"status":"failed","reason":"invalid_ordinary_visual_source_grid"}
    var town_low := Vector2i(floori(float(bounds.position.x)/town_size),floori(float(bounds.position.y)/town_size))-Vector2i.ONE
    var town_high := Vector2i(floori(float(bounds.end.x-1)/town_size),floori(float(bounds.end.y-1)/town_size))+Vector2i.ONE
    var standalone_low := Vector2i(floori(float(bounds.position.x)/structure_size),floori(float(bounds.position.y)/structure_size))-Vector2i.ONE
    var standalone_high := Vector2i(floori(float(bounds.end.x-1)/structure_size),floori(float(bounds.end.y-1)/structure_size))+Vector2i.ONE
    if (town_high.x-town_low.x+1)*(town_high.y-town_low.y+1)>256 \
            or (standalone_high.x-standalone_low.x+1)*(standalone_high.y-standalone_low.y+1)>256:
        return {"status":"failed","reason":"ordinary_visual_source_region_limit"}
    var cached_towns_value=main.get("town_region_cache")
    var cached_towns: Dictionary=cached_towns_value if cached_towns_value is Dictionary else {}
    for z in range(town_low.y,town_high.y+1):
        for x in range(town_low.x,town_high.x+1):
            if cached_towns_value is Dictionary and not cached_towns.has(Vector2i(x,z)):
                return {"status":"pending","reason":"ordinary_visual_town_description_pending",
                    "retryable":true,"region":Vector2i(x,z)}
            var town: Dictionary=cached_towns.get(Vector2i(x,z),{}) if cached_towns_value is Dictionary \
                else main.town_region(x,z)
            if town.is_empty() or not _regional_town_bounds(town).intersects(bounds): continue
            var town_key:=town_key_for(town)
            var source_id: String="town:"+town_key
            source_ids[source_id]=true
    for z in range(standalone_low.y,standalone_high.y+1):
        for x in range(standalone_low.x,standalone_high.x+1):
            var region:=Vector2i(x,z)
            var candidate:=StandaloneSourceScript.candidate_for_region(String(main.seed_text),region,structure_size,float(main.STRUCTURE_SPAWN_CHANCE))
            if candidate.is_empty(): continue
            var influence:=StandaloneSourceScript.terrain_influence_for_candidate(candidate)
            if not bool(influence.get("bounded",false)):
                return {"status":"failed","reason":"standalone_visual_source_bounds_missing"}
            if not (influence.influenceCells as Rect2i).intersects(bounds): continue
            var source_id: String="standalone:%d,%d" % [x,z]
            if generated_structures.get(region,null)==false: continue
            source_ids[source_id]=true
    var ids: Array=source_ids.keys()
    ids.sort()
    var candidates: Array[Dictionary]=[]
    var pending_ids: Array[String]=[]
    var bindings: Array=[]
    var expected_scanned:=0
    var live_blocks: Dictionary=main.get("blocks")
    for source_id_value in ids:
        var source_id:=String(source_id_value)
        var source: Dictionary=ordinary_visual_sources.get(source_id,{})
        if source.is_empty() or not bool(source.get("completed",false)):
            pending_ids.append(source_id)
            continue
        bindings.append([source_id,int(source.get("revision",0))])
        var expected: Dictionary=source.get("expected",{})
        if expected.size()>ORDINARY_VISUAL_SOURCE_MAX_EXPECTED_BLOCKS \
                or expected_scanned+expected.size()>ORDINARY_VISUAL_QUERY_MAX_EXPECTED_BLOCKS:
            return {"status":"pending","reason":"ordinary_visual_source_capacity","retryable":true,
                "sourceId":source_id,"expectedCount":expected.size(),"scannedCount":expected_scanned}
        expected_scanned+=expected.size()
        # Ordinary accepted sites always emit blocks. Completion with no
        # producer records is a missing publication, not an empty visual source.
        var omitted: Dictionary=source.get("omitted",{})
        var failed: Dictionary=source.get("failed",{})
        if not failed.is_empty():
            pending_ids.append(source_id+":unaccepted_block_output")
        if expected.is_empty() and omitted.is_empty():
            pending_ids.append(source_id+":no_emitted_blocks")
            continue
        var cells: Array=expected.keys()
        cells.sort_custom(func(a: Vector3i,b: Vector3i): return a.z<b.z if a.z!=b.z else (a.x<b.x if a.x!=b.x else a.y<b.y))
        for cell_value in cells:
            var cell: Vector3i=cell_value
            if not bounds.has_point(Vector2i(cell.x,cell.z)): continue
            var block_type:=String(expected[cell])
            var durable_id:=_ordinary_visual_block_key(source_id,cell,block_type)
            if removed_generated_structure_blocks.has(durable_id): continue
            var body:=live_blocks.get(cell) as Node3D
            if not is_instance_valid(body) or not body.is_inside_tree() or body.is_queued_for_deletion() \
                    or String(body.get_meta("generated_visual_source_id",""))!=source_id \
                    or String(body.get_meta("block_type",""))!=block_type:
                body=null
            var representation:=_ordinary_visible_renderable(body) if is_instance_valid(body) else null
            var candidate_id: String="ordinary:%s:%d,%d,%d:%s" % [source_id,cell.x,cell.y,cell.z,block_type]
            candidates.append({"candidateId":candidate_id,"positionXZ":Vector2(float(cell.x)+0.5,float(cell.z)+0.5),
                "cell":cell,"owner":body,"representation":representation,"installed":is_instance_valid(representation)})
            bindings.append([candidate_id,body.get_instance_id() if is_instance_valid(body) else 0,
                representation.get_instance_id() if is_instance_valid(representation) else 0])
    if candidates.size()>100000:
        return {"status":"pending","reason":"ordinary_visual_source_capacity","retryable":true,
            "candidateCount":candidates.size()}
    var hasher:=HashingContext.new()
    hasher.start(HashingContext.HASH_SHA256)
    hasher.update(JSON.stringify([String(main.seed_text),regional_source_generation,ids,bindings]).to_utf8_buffer())
    var revision:=hasher.finish().hex_encode()
    return {"status":"pending" if not pending_ids.is_empty() else "described",
        "reason":"ordinary_visual_sources_pending" if not pending_ids.is_empty() else "",
        "sourceRevision":revision,"candidates":candidates,"pendingSourceIds":pending_ids,
        "sourceCount":ids.size(),"candidateCount":candidates.size()}

func _ordinary_visible_renderable(root_node: Node) -> Node3D:
    if root_node is GeometryInstance3D:
        var geometry:=root_node as GeometryInstance3D
        if geometry.visible and geometry.is_visible_in_tree():
            if geometry is MeshInstance3D and (geometry as MeshInstance3D).mesh!=null: return geometry
            if geometry is MultiMeshInstance3D and (geometry as MultiMeshInstance3D).multimesh!=null: return geometry
    for child in root_node.get_children():
        if child is Node:
            var found:=_ordinary_visible_renderable(child)
            if found!=null: return found
    return null

func _ordinary_visual_block_key(source_id: String, cell: Vector3i, block_type: String) -> String:
    return "%s|%d,%d,%d|%s" % [source_id,cell.x,cell.y,cell.z,block_type]

func _begin_ordinary_visual_source(source_id: String) -> void:
    if source_id.is_empty(): return
    if not ordinary_visual_sources.has(source_id):
        ordinary_visual_sources[source_id]={"completed":false,"expected":{},"omitted":{},"failed":{},"revision":1}
        ordinary_visual_revision+=1

func _complete_ordinary_visual_source(source_id: String) -> void:
    if source_id.is_empty(): return
    _begin_ordinary_visual_source(source_id)
    var source: Dictionary=ordinary_visual_sources[source_id]
    if not bool(source.get("completed",false)):
        source.completed=true
        source.revision=int(source.get("revision",0))+1
        ordinary_visual_revision+=1

func _record_ordinary_visual_block(cell: Vector3i, block_type: String, output: Node3D) -> void:
    var source_id:=active_structure_visual_source_id
    if source_id.is_empty(): return
    _begin_ordinary_visual_source(source_id)
    var source: Dictionary=ordinary_visual_sources[source_id]
    var expected: Dictionary=source.expected
    var omitted: Dictionary=source.omitted
    var failed: Dictionary=source.failed
    var key:=_ordinary_visual_block_key(source_id,cell,block_type)
    var accepted:=is_instance_valid(output) and bool(output.get_meta("generated",false)) \
        and String(output.get_meta("generated_visual_source_id",""))==source_id
    if accepted:
        var actual_type:=String(output.get_meta("block_type",""))
        if expected.get(cell,"")!=actual_type:
            expected[cell]=actual_type
            source.revision=int(source.get("revision",0))+1
            ordinary_visual_revision+=1
        omitted.erase(key)
        failed.erase(key)
    elif is_instance_valid(output) or removed_generated_structure_blocks.has(key):
        if not omitted.has(key):
            omitted[key]=true
            source.revision=int(source.get("revision",0))+1
            ordinary_visual_revision+=1
        failed.erase(key)
    else:
        if not failed.has(key):
            failed[key]=true
            source.revision=int(source.get("revision",0))+1
            ordinary_visual_revision+=1

func generated_visual_block_removed(body: Node3D) -> void:
    if not is_instance_valid(body) or not bool(body.get_meta("generated",false)): return
    var source_id:=String(body.get_meta("generated_visual_source_id",""))
    var cell_value=body.get_meta("cell",null)
    if source_id.is_empty() or not cell_value is Vector3i: return
    var key:=_ordinary_visual_block_key(source_id,cell_value,String(body.get_meta("block_type","")))
    if not removed_generated_structure_blocks.has(key):
        removed_generated_structure_blocks[key]=true
        if ordinary_visual_sources.has(source_id):
            var source: Dictionary=ordinary_visual_sources[source_id]
            source.revision=int(source.get("revision",0))+1
        ordinary_visual_revision+=1

func generated_visual_block_is_removed(source_id: String, cell: Vector3i, block_type: String) -> bool:
    return removed_generated_structure_blocks.has(_ordinary_visual_block_key(source_id,cell,block_type))

func snapshot_removed_generated_structure_blocks() -> Array:
    var result: Array=removed_generated_structure_blocks.keys()
    result.sort()
    return result

func restore_removed_generated_structure_blocks(value) -> void:
    removed_generated_structure_blocks.clear()
    if value is Array:
        for item in value:
            var key:=String(item)
            if key.begins_with("town:") or key.begins_with("standalone:"):
                removed_generated_structure_blocks[key]=true
    for source: Dictionary in ordinary_visual_sources.values():
        source.revision=int(source.get("revision",0))+1
    ordinary_visual_revision+=1

func advance_citadel_publication(observer_bounds := Rect2i(), allow_dispatch := false, budget_usec := CITADEL_PUBLICATION_BUDGET_USEC) -> Dictionary:
    if budget_usec<=0:
        return citadel_publication.stats()
    return citadel_publication.advance(observer_bounds,allow_dispatch,mini(CITADEL_PUBLICATION_BUDGET_USEC,budget_usec))

func navigation_tile_sources(tile: Vector2i) -> Dictionary:
    return citadel_publication.navigation_tile_sources(tile)

func navigation_tile_source_identity(tile: Vector2i) -> Dictionary:
    return citadel_publication.navigation_tile_source_identity(tile)

func region_dependency_revision(bounds: Rect2i) -> String:
    # No source compilation, town generation, home copies or queue scans here.
    return JSON.stringify([String(main.seed_text) if is_instance_valid(main) else "",
        regional_source_generation,regional_source_revision,private_interior_revision,
        pending_structure_op_index,pending_structure_ops.size(),pending_structure_retry_ops.size(),generated_structures.size(),generated_towns.size(),
        _regional_edit_revision(),_regional_town_input_revision(bounds),citadel_publication.region_dependency_revision(bounds)])

## Polling only needs to know when a dependency description may have changed.
## Physical edits and owner receipts are still read freshly by
## region_dependency_revision/region_publication_readiness at acceptance.
func region_dependency_scheduling_revision(bounds: Rect2i) -> Array:
    var npc = main.get("npc_system") if is_instance_valid(main) else null
    var autonomy = npc.get("autonomy_system") if is_instance_valid(npc) else null
    var portals = autonomy.get("door_portals") if is_instance_valid(autonomy) else null
    return [String(main.seed_text) if is_instance_valid(main) else "",
        regional_source_generation,regional_source_revision,private_interior_revision,town_home_records_revision,
        pending_structure_op_index,pending_structure_ops.size(),pending_structure_retry_ops.size(),generated_structures.size(),generated_towns.size(),
        portals.get_instance_id() if is_instance_valid(portals) else 0,
        portals.door_to_portal.size() if is_instance_valid(portals) else 0,
        _regional_town_scheduling_revision(bounds),citadel_publication.region_dependency_scheduling_revision(bounds)]

func _regional_town_scheduling_revision(bounds: Rect2i) -> Array:
    if not is_instance_valid(main) or not CitadelPublicationServiceScript._bounded_region_rectangle(bounds): return []
    var size := int(main.TOWN_REGION_CELLS)
    if size <= 0: return []
    var low := Vector2i(floori(float(bounds.position.x)/size),floori(float(bounds.position.y)/size))-Vector2i.ONE
    var high := Vector2i(floori(float(bounds.end.x-1)/size),floori(float(bounds.end.y-1)/size))+Vector2i.ONE
    if (high.x-low.x+1)*(high.y-low.y+1)>256: return ["region_limit"]
    var cache: Dictionary = main.get("town_region_cache")
    var result: Array = [cache.size()]
    for z in range(low.y,high.y+1):
        for x in range(low.x,high.x+1):
            var key := Vector2i(x,z)
            result.append([key,cache.has(key)])
    return result

func _regional_town_input_revision(bounds: Rect2i) -> Array:
    if not is_instance_valid(main) or not CitadelPublicationServiceScript._bounded_region_rectangle(bounds): return []
    var size := int(main.TOWN_REGION_CELLS)
    if size <= 0: return []
    var low := Vector2i(floori(float(bounds.position.x)/size),floori(float(bounds.position.y)/size))-Vector2i.ONE
    var high := Vector2i(floori(float(bounds.end.x-1)/size),floori(float(bounds.end.y-1)/size))+Vector2i.ONE
    if (high.x-low.x+1)*(high.y-low.y+1)>256: return ["region_limit"]
    var cache: Dictionary = main.get("town_region_cache")
    var sources: Array = []
    for z in range(low.y,high.y+1):
        for x in range(low.x,high.x+1):
            var key := Vector2i(x,z)
            if not cache.has(key):
                sources.append([key,"unqueried"])
                continue
            var town: Dictionary = cache[key]
            # Only generation inputs consumed by this owner, never cached home
            # records, runtime manifests, timestamps or arbitrary metadata.
            sources.append([key,town.get("centerX"),town.get("centerZ"),town.get("radius"),town.get("level"),town.get("homeExclusionRings",[])])
    return sources

func _regional_edit_revision() -> Array:
    var world = main.get("world_generation_system") if is_instance_valid(main) else null
    var volume = world.get("terrain_volume_service") if is_instance_valid(world) else null
    var npc = main.get("npc_system") if is_instance_valid(main) else null
    var autonomy = npc.get("autonomy_system") if is_instance_valid(npc) else null
    var portals = autonomy.get("door_portals") if is_instance_valid(autonomy) else null
    return [volume.get_instance_id() if is_instance_valid(volume) else 0,
        int(volume.revision) if is_instance_valid(volume) else -1,
        portals.get_instance_id() if is_instance_valid(portals) else 0,
        portals.door_to_portal if is_instance_valid(portals) else {}]

func region_dependency_requirements(bounds: Rect2i) -> Dictionary:
    # Descriptions change with source scheduling inputs. Physical terrain,
    # collision and door state are validated by their live owners at the
    # acceptance boundary and must not churn this description cache.
    var revision := region_dependency_scheduling_revision(bounds)
    var cached: Dictionary = regional_requirements_cache.get(bounds,{})
    if cached.get("revision") == revision and cached.get("result",{}).get("status") in ["described","failed"]:
        return cached.result.duplicate(false)
    var result := _uncached_region_dependency_requirements(bounds)
    if regional_requirements_cache.size() >= 64 and not regional_requirements_cache.has(bounds):
        regional_requirements_cache.erase(regional_requirements_cache.keys()[0])
    regional_requirements_cache[bounds] = {"revision":region_dependency_scheduling_revision(bounds),"result":result}
    return result.duplicate(false)

func _uncached_region_dependency_requirements(bounds: Rect2i) -> Dictionary:
    var result: Dictionary = citadel_publication.region_dependency_requirements(bounds)
    if not is_instance_valid(main) or not CitadelPublicationServiceScript._bounded_region_rectangle(bounds):
        result.status = "failed"; result.reason = "invalid_structure_dependency_owner"
        return result
    # Even a pending citadel must not hide an ordinary town's required work.
    var town_size := int(main.TOWN_REGION_CELLS)
    var structure_size := int(main.STRUCTURE_REGION_CELLS)
    result.sourceRevisions["structure-world"] = {"worldSeed":String(main.seed_text),"generation":regional_source_generation,
        "sourceRevision":regional_source_revision,"editRevision":_regional_edit_revision(),
        "townRegionCells":town_size,"structureRegionCells":structure_size,"structureSpawnChance":float(main.STRUCTURE_SPAWN_CHANCE)}
    for size: int in [town_size,structure_size]:
        if size <= 0:
            result.status = "failed"; result.reason = "invalid_ordinary_structure_grid"
            return result
        var low := Vector2i(floori(float(bounds.position.x)/size),floori(float(bounds.position.y)/size))-Vector2i.ONE
        var high := Vector2i(floori(float(bounds.end.x-1)/size),floori(float(bounds.end.y-1)/size))+Vector2i.ONE
        if (high.x-low.x+1)*(high.y-low.y+1) > 256:
            result.status = "failed"; result.reason = "ordinary_structure_dependency_region_limit"
            return result
    var low := Vector2i(floori(float(bounds.position.x)/town_size),floori(float(bounds.position.y)/town_size))-Vector2i.ONE
    var high := Vector2i(floori(float(bounds.end.x-1)/town_size),floori(float(bounds.end.y-1)/town_size))+Vector2i.ONE
    for z in range(low.y,high.y+1):
        for x in range(low.x,high.x+1):
            var town: Dictionary = main.town_region(x,z)
            if town.is_empty(): continue # Authoritative deterministic absence.
            var town_bounds := _regional_town_bounds(town)
            if not town_bounds.intersects(bounds): continue
            _describe_regional_town(town,town_bounds,result)
    low = Vector2i(floori(float(bounds.position.x)/structure_size),floori(float(bounds.position.y)/structure_size))-Vector2i.ONE
    high = Vector2i(floori(float(bounds.end.x-1)/structure_size),floori(float(bounds.end.y-1)/structure_size))+Vector2i.ONE
    for z in range(low.y,high.y+1):
        for x in range(low.x,high.x+1):
            var region := Vector2i(x,z)
            var candidate := StandaloneSourceScript.candidate_for_region(String(main.seed_text),region,structure_size,float(main.STRUCTURE_SPAWN_CHANCE))
            if candidate.is_empty(): continue
            var influence := StandaloneSourceScript.terrain_influence_for_candidate(candidate)
            if not influence.get("bounded",false):
                _regional_problem(result,"failed","standalone_dependency_bounds_missing")
                continue
            if not influence.influenceCells.intersects(bounds): continue
            var id := "standalone:%d,%d" % [x,z]
            result.sourceRevisions[id] = _regional_source_binding(id,candidate)
            if not generated_structures.has(region):
                if not regional_standalone_requests.has(region):
                    regional_standalone_requests[region] = true
                    enqueue_structure_op({"type":"regional_standalone_source","region":region})
                _regional_problem(result,"pending","standalone_generation_not_requested")
                continue
            if generated_structures[region] == false: continue # Terrain owner rejected source.
            _regional_add_bounds(result,influence.influenceCells)
            var pending := false
            for index in range(pending_structure_op_index,pending_structure_ops.size()):
                if String(pending_structure_ops[index].get("townKey","")) == "": pending = true; break
            if pending:
                _regional_problem(result,"pending","standalone_structure_operations_pending")
                continue
            var footprint_found := false
            for footprint: Dictionary in terrain_footprint_records.values():
                if int(footprint.baseX)==candidate.baseCell.x and int(footprint.baseZ)==candidate.baseCell.y:
                    footprint_found = true
                    _regional_add_footprint(result,footprint)
            if not footprint_found:
                result.missingSourceIds.append(id)
                _regional_problem(result,"failed","standalone_physical_source_receipt_missing")
            else:
                result.physicalOwnerAcknowledgements[id] = {"binding":result.sourceRevisions[id],"pendingStructureOps":0,"terrainFootprintRecorded":true}
                _describe_regional_live_doors(influence.influenceCells,result.sourceRevisions[id],result)
    if not result.missingSourceIds.is_empty() or not result.unresolvedCrossingIds.is_empty():
        _regional_problem(result,"failed","structure_source_dependencies_unresolved")
    result["dependencyRevision"] = region_dependency_scheduling_revision(bounds)
    return result

func region_publication_readiness(bounds: Rect2i) -> Dictionary:
    var result := region_dependency_requirements(bounds)
    result["acknowledgementScope"] = "structures_physical_only"
    if result.status != "described": return result
    var physical := citadel_physical_publication_state(bounds)
    result.status = String(physical.get("status","pending"))
    result.reason = String(physical.get("reason","structure_physical_publication_pending"))
    result["physicalPublication"] = physical
    result.publicationAcknowledged = result.status == "ready"
    return result

func _regional_source_binding(id: String, source: Dictionary) -> Dictionary:
    return {"siteId":id,"worldSeed":String(main.seed_text),"sourceKey":String(main.seed_text)+"|"+id,
        "generation":regional_source_generation,"sourceRevision":regional_source_revision,
        "editRevision":_regional_edit_revision(),"source":source.duplicate(true)}

func _regional_town_bounds(town: Dictionary) -> Rect2i:
    var center := Vector2i(int(town.centerX),int(town.centerZ))
    var radius := int(town.radius)
    var bounds := Rect2i(center-Vector2i.ONE*radius,Vector2i.ONE*(radius*2+1))
    # The existing owner tests each potential home with a 10x10 envelope before
    # choosing its 7..9 cell walls. Include that envelope and foundation border.
    for site: Dictionary in town_home_sites(town,null):
        bounds = bounds.merge(Rect2i(center+Vector2i(int(site.dx),int(site.dz))-Vector2i.ONE,Vector2i(12,12)))
    return bounds

func _describe_regional_town(town: Dictionary, bounds: Rect2i, result: Dictionary) -> void:
    var key := town_key_for(town)
    var id := "town:"+key
    _regional_add_bounds(result,bounds)
    result.sourceRevisions[id] = _regional_source_binding(id,town)
    var state: Dictionary = town_manifest_publish_states.get(key,{})
    if state.is_empty() or int(state.get("generationAttempts",0)) == 0:
        # Dependency demand can be outside update_around(player)'s scan. Retain
        # it in the existing staged town queue rather than waiting for proximity.
        generated_towns[Vector2i(int(town.regionX),int(town.regionZ))] = true
        enqueue_deferred_town_build(town)
        _regional_problem(result,"pending","town_manifest_generation_not_requested")
        return
    if state.get("status") == "failed":
        _regional_problem(result,"failed","required_town_manifest_generation_failed")
        return
    if state.get("status") != "published" or pending_structure_op_count_for_town(key)>0:
        _regional_problem(result,"pending","required_town_structure_operations_pending")
        return
    var count := int(state.get("builtHomeCount",0))
    if count<=0:
        result.missingSourceIds.append(id)
        _regional_problem(result,"failed","published_town_home_sources_missing")
        return
    var required_keys: Array = []
    for index in range(count): required_keys.append(index)
    var published := town_manifest_status(town,{"requiredHomeKeys":required_keys,"actorHomeAssignments":{}})
    if published.status != "ready":
        _regional_problem(result,String(published.status),String(published.reason))
        return
    var manifest: Dictionary = published.manifest
    result.sourceRevisions[id]["manifest"] = manifest
    var owners := GeneratedStructureRuntimeBindingsScript._current_owners(main)
    for home: Dictionary in manifest.homesByKey.values():
        for cell in home.get("homeRouteCells",[]): _regional_add_bounds(result,Rect2i(cell,Vector2i.ONE))
        _regional_add_bounds(result,Rect2i(home.interiorMinCell,home.interiorMaxCell-home.interiorMinCell+Vector2i.ONE))
        var portal_id := String(home.doorPortalId)
        var portal = owners.portals.portals.get(portal_id) if not owners.is_empty() else null
        var registration = owners.smart.registrations.get(portal_id) if not owners.is_empty() else null
        if not is_instance_valid(portal) or not is_instance_valid(registration) or registration.kind != "door":
            _regional_problem(result,"pending","town_door_registration_pending")
            continue
        if not is_instance_valid(registration.node) or not portal.leaf_nodes.has(registration.node):
            _regional_problem(result,"pending","town_door_owner_pending")
            continue
        # Smart registration represents the group and may point at either leaf.
        # The manifest's primary cell must exist, and every live leaf contributes
        # its own source/endpoints (including a leaf across a navigation seam).
        var primary_found := false
        for body in portal.leaf_nodes:
            if not is_instance_valid(body): continue
            var cell_value = body.get_meta("cell")
            if cell_value is Vector3i and Vector2i(cell_value.x,cell_value.z) == home.doorCell:
                primary_found = true
        if not primary_found:
            _regional_problem(result,"pending","town_door_owner_pending")
            continue
        _describe_regional_portal_leaves(portal,String(home.stableId)+":door",result.sourceRevisions[id],owners.portals,result)
    for footprint: Dictionary in terrain_footprint_records.values():
        var low: Vector3i = footprint.minCell
        var high: Vector3i = footprint.maxCell
        if bounds.intersects(Rect2i(Vector2i(low.x,low.z),Vector2i(high.x-low.x+1,high.z-low.z+1))):
            _regional_add_footprint(result,footprint)
    result.physicalOwnerAcknowledgements[id] = {"binding":result.sourceRevisions[id],"manifestReady":true,"pendingStructureOps":0}

func _describe_regional_live_doors(bounds: Rect2i, binding: Dictionary, result: Dictionary) -> void:
    # Ordinary standalone doors have live block/portal ownership rather than a
    # BuildingSpatialDependencies packet. Read that same publication source.
    var owners := GeneratedStructureRuntimeBindingsScript._current_owners(main)
    var blocks: Dictionary = main.get("blocks")
    var described_portals := {}
    for value in blocks.values():
        var body := value as Node3D
        if not is_instance_valid(body) or String(body.get_meta("block_type","")) != "door": continue
        var cell_value = body.get_meta("cell")
        if not cell_value is Vector3i:
            _regional_problem(result,"failed","ordinary_door_source_cell_missing")
            continue
        var cell := Vector2i(cell_value.x,cell_value.z)
        if not bounds.has_point(cell): continue
        var portal_id := String(body.get_meta("door_portal_id",""))
        var portal = owners.portals.portal_for_door(body) if not owners.is_empty() else null
        if portal_id.is_empty() or not is_instance_valid(portal) or not portal.leaf_nodes.has(body) \
            or not body.is_inside_tree() or body.is_queued_for_deletion() or String(portal.portal_id)!=portal_id:
            _regional_problem(result,"pending","ordinary_door_registration_pending")
            continue
        if described_portals.has(portal_id): continue
        described_portals[portal_id] = true
        _describe_regional_portal_leaves(portal,String(binding.siteId)+":door:"+portal_id,binding,owners.portals,result)

func _describe_regional_portal_leaves(portal, source_prefix: String, binding: Dictionary, portals, result: Dictionary) -> void:
    if portal.leaf_nodes.is_empty():
        _regional_problem(result,"pending","ordinary_door_live_owner_pending")
        return
    var seen_cells := {}
    for value in portal.leaf_nodes:
        var body := value as Node3D
        if not is_instance_valid(body) or not body.is_inside_tree() or body.is_queued_for_deletion() \
            or String(body.get_meta("block_type","")) != "door" \
            or portals.door_to_portal.get(body.get_instance_id()) != portal.portal_id \
            or String(body.get_meta("door_portal_id","")) != portal.portal_id:
            _regional_problem(result,"pending","ordinary_door_live_owner_pending")
            continue
        var leaf_cell = body.get_meta("cell")
        if not leaf_cell is Vector3i:
            _regional_problem(result,"failed","ordinary_door_source_cell_missing")
            continue
        var cell := Vector2i(leaf_cell.x,leaf_cell.z)
        if seen_cells.has(cell):
            _regional_problem(result,"failed","ordinary_door_source_cell_ambiguous")
            continue
        seen_cells[cell] = true
        var source_id := "%s:leaf:%d,%d,%d" % [source_prefix,leaf_cell.x,leaf_cell.y,leaf_cell.z]
        var tile := Vector2i(floori(float(cell.x)/NavigationConstantsScript.NAV_TILE_CELL_SIZE),floori(float(cell.y)/NavigationConstantsScript.NAV_TILE_CELL_SIZE))
        var tile_key := "%d,%d" % [tile.x,tile.y]
        var obligation := {"sourceId":source_id,"kind":"doors","portalId":String(portal.portal_id),"cell":cell,
            "ownerTileKey":tile_key,"tileKeys":[tile_key],"requiredLinkIds":["door-link:%s:%s" % [portal.portal_id,tile_key]],
            "binding":binding,"mappingStatus":"pending"}
        result.requiredCrossings[source_id] = obligation
        _regional_add_bounds(result,Rect2i(cell,Vector2i.ONE))
        _describe_regional_door_endpoints(body,portal,obligation,result)

func _describe_regional_door_endpoints(body: Node3D, portal, obligation: Dictionary, result: Dictionary) -> void:
    var npc = main.get("npc_system")
    var pathing = npc.get("pathing") if is_instance_valid(npc) else null
    var adapter = pathing.get("navigation_world") if is_instance_valid(pathing) else null
    if not is_instance_valid(adapter) or not is_instance_valid(portal):
        _regional_problem(result,"pending","ordinary_door_endpoint_owner_pending")
        return
    var cell: Vector2i = adapter.block_world_cell(body)
    if cell != obligation.cell:
        _regional_problem(result,"failed","ordinary_door_source_cell_mismatch")
        return
    var step := Vector2i.RIGHT if String(adapter._door_crossing_axis(body))=="x" else Vector2i.DOWN
    # Use the same leaf orientation and source-cell surface queries as the
    # production navigation adapter, not the group's smart-object representative.
    obligation["entrance"] = adapter.cell_position(cell-step)
    obligation["exit"] = adapter.cell_position(cell+step)
    obligation["doorSource"] = {"id":obligation.requiredLinkIds[0],"portalId":obligation.portalId,
        "cell":cell,"start":obligation.entrance,"end":obligation.exit}
    obligation.mappingStatus = "described"
    for endpoint: Vector2i in [cell-step,cell+step]:
        _regional_add_bounds(result,Rect2i(endpoint,Vector2i.ONE))
        var key: String = adapter.tile_key_for_cell(endpoint)
        if not obligation.tileKeys.has(key): obligation.tileKeys.append(key)

func _regional_add_footprint(result: Dictionary, footprint: Dictionary) -> void:
    var low: Vector3i = footprint.minCell
    var high: Vector3i = footprint.maxCell
    _regional_add_bounds(result,Rect2i(Vector2i(low.x,low.z),Vector2i(high.x-low.x+1,high.z-low.z+1)))

static func _regional_add_bounds(result: Dictionary, bounds: Rect2i) -> void:
    if bounds.has_area() and not result.dependencyBounds.has(bounds): result.dependencyBounds.append(bounds)
    if bounds.has_area() and result.has("domainBounds"):
        for domain: String in ["terrain","render","navigation"]:
            if not result.domainBounds[domain].has(bounds): result.domainBounds[domain].append(bounds)

static func _regional_problem(result: Dictionary, status: String, reason: String) -> void:
    if result.status == "failed": return
    if status == "failed" or result.status == "described":
        result.status = status; result.reason = reason

func reset() -> void:
    regional_standalone_requests.clear()
    standalone_admission_states.clear()
    regional_requirements_cache.clear()
    regional_source_generation += 1
    regional_source_revision += 1
    configure_citadel_terrain_admission()
    generated_towns.clear()
    generated_structures.clear()
    generated_building_count = 0
    generated_town_count = 0
    generated_mine_count = 0
    generated_ruin_count = 0
    generated_shrine_count = 0
    generated_camp_count = 0
    generated_path_count = 0
    generated_door_count = 0
    generated_utility_count = 0
    town_home_records.clear()
    town_home_records_revision += 1
    pending_structure_ops.clear()
    pending_structure_retry_ops.clear()
    pending_structure_op_index = 0
    defer_structure_ops = false
    deferred_town_home_records.clear()
    town_manifest_publish_states.clear()
    active_structure_town_key = ""
    active_structure_visual_source_id = ""
    ordinary_visual_sources.clear()
    removed_generated_structure_blocks.clear()
    ordinary_visual_revision += 1
    terrain_surface_sample_cache.clear()
    terrain_footprint_records.clear()
    natural_prop_exclusion_records.clear()
    surface_prop_exclusion_revision += 1
    private_interior_records.clear()
    private_interior_revision += 1

func register_private_interior(stable_id: String, min_cell: Vector2i, max_cell: Vector2i, owner_actor_id := "") -> bool:
    var normalized_id := stable_id.strip_edges()
    if normalized_id == "":
        return false
    var record := {
        "stableId": normalized_id,
        "interiorMinCell": Vector2i(mini(min_cell.x, max_cell.x), mini(min_cell.y, max_cell.y)),
        "interiorMaxCell": Vector2i(maxi(min_cell.x, max_cell.x), maxi(min_cell.y, max_cell.y)),
        "ownerActorId": String(owner_actor_id).strip_edges()
    }
    if private_interior_records.get(normalized_id, {}) == record:
        return true
    private_interior_records[normalized_id] = record
    private_interior_revision += 1
    return true

func private_interior_records_snapshot() -> Array:
    var records: Array = []
    for stable_id in private_interior_records.keys():
        records.append((private_interior_records[stable_id] as Dictionary).duplicate(true))
    records.sort_custom(func(a, b): return String(a.get("stableId", "")) < String(b.get("stableId", "")))
    return records

func private_interior_records_revision() -> int:
    return private_interior_revision

func update_around(center_cell: Vector2i) -> void:
    if main == null:
        return
    terrain_surface_sample_cache.clear()
    update_towns(center_cell)
    update_standalone_structures(center_cell)

func update_around_budgeted(center_cell: Vector2i, allow_builds := true) -> int:
    if main == null:
        return 0
    terrain_surface_sample_cache.clear()
    var monitor = performance_monitor()
    var towns_start: int = monitor.begin_section("structure_scan_towns") if monitor != null else Time.get_ticks_usec()
    update_towns(center_cell, true)
    if monitor != null:
        monitor.end_section("structure_scan_towns", towns_start)
    var standalone_start: int = monitor.begin_section("structure_scan_standalone") if monitor != null else Time.get_ticks_usec()
    update_standalone_structures(center_cell, true, 1)
    if monitor != null:
        monitor.end_section("structure_scan_standalone", standalone_start)
    if not allow_builds:
        if monitor != null:
            monitor.increment_counter("structure_op_queue_depth", pending_structure_op_count())
        return 0
    return process_pending_structure_ops()

func update_towns(center_cell: Vector2i, defer_builds := false) -> void:
    var center_region := Vector2i(floori(float(center_cell.x) / float(main.TOWN_REGION_CELLS)), floori(float(center_cell.y) / float(main.TOWN_REGION_CELLS)))
    for rz in range(center_region.y - 1, center_region.y + 2):
        for rx in range(center_region.x - 1, center_region.x + 2):
            var key := Vector2i(rx, rz)
            if generated_towns.has(key):
                continue
            var town: Dictionary = main.town_region(rx, rz)
            if town.is_empty():
                generated_towns[key] = false
                continue
            var distance := Vector2(float(center_cell.x - int(town["centerX"])), float(center_cell.y - int(town["centerZ"]))).length()
            var active_render_distance: int = int(main.get("render_distance"))
            if active_render_distance <= 0:
                active_render_distance = main.RENDER_DISTANCE
            var activation_range: float = float(main.TOWN_RADIUS_CELLS + main.CHUNK_SIZE * active_render_distance + 20)
            if distance > activation_range:
                continue
            generated_towns[key] = true
            if defer_builds:
                enqueue_deferred_town_build(town)
            else:
                build_town(town)

func update_standalone_structures(center_cell: Vector2i, defer_builds := false, max_new_regions := 9, required_region = null) -> int:
    const Candidate := preload("res://scripts/world/StandaloneStructureCandidate.gd")
    var center_region := Vector2i(floori(float(center_cell.x) / float(main.STRUCTURE_REGION_CELLS)), floori(float(center_cell.y) / float(main.STRUCTURE_REGION_CELLS)))
    var low := center_region-Vector2i.ONE
    var high := center_region+Vector2i.ONE
    if required_region is Vector2i:
        low = required_region
        high = required_region
    var new_regions := 0
    for rz in range(low.y, high.y + 1):
        for rx in range(low.x, high.x + 1):
            var key := Vector2i(rx, rz)
            if generated_structures.has(key):
                continue
            new_regions += 1
            var candidate := Candidate.candidate_for_region(main.seed_text, key, main.STRUCTURE_REGION_CELLS, main.STRUCTURE_SPAWN_CHANCE)
            if candidate.is_empty():
                generated_structures[key] = false
                if max_new_regions > 0 and new_regions >= max_new_regions:
                    return new_regions
                continue
            var base_x: int = candidate.baseCell.x
            var base_z: int = candidate.baseCell.y
            var structure_type: String = candidate.structureType
            var dimensions: Vector2i = candidate.dimensions
            var admission := advance_standalone_terrain_admission(key,candidate)
            if admission.status=="pending":
                if max_new_regions > 0 and new_regions >= max_new_regions:
                    return new_regions
                continue
            if admission.status!="ready":
                generated_structures[key] = false
                if max_new_regions > 0 and new_regions >= max_new_regions:
                    return new_regions
                continue
            var level := float(admission.level)
            var rng := Candidate.continuation_rng(candidate)
            generated_structures[key] = true
            var visual_source_id := "standalone:%d,%d" % [key.x,key.y]
            _begin_ordinary_visual_source(visual_source_id)
            if defer_builds:
                enqueue_standalone_structure_build(structure_type, base_x, base_z, level, dimensions, rng, visual_source_id)
                if max_new_regions > 0 and new_regions >= max_new_regions:
                    return new_regions
                continue
            var previous_visual_source_id:=active_structure_visual_source_id
            active_structure_visual_source_id=visual_source_id
            if structure_type == "mine":
                build_mine(base_x, base_z, level, dimensions.x, dimensions.y, rng)
            elif structure_type == "ruin":
                build_ruin(base_x, base_z, level, dimensions.x, dimensions.y, rng)
            elif structure_type == "shrine":
                build_shrine(base_x, base_z, level, dimensions.x, dimensions.y, rng)
            elif structure_type == "camp":
                build_camp(base_x, base_z, level, dimensions.x, dimensions.y, rng)
            else:
                var wall_type := "woodBlock" if rng.randf() < 0.5 else "stoneBlock"
                var roof_type := "stoneBlock" if wall_type == "woodBlock" else "woodBlock"
                build_building(base_x, base_z, level, dimensions.x, dimensions.y, rng.randi_range(4, 5), wall_type, roof_type, rng.randi_range(0, 3), rng, false)
            active_structure_visual_source_id=previous_visual_source_id
            _complete_ordinary_visual_source(visual_source_id)
            if max_new_regions > 0 and new_regions >= max_new_regions:
                return new_regions
    return new_regions

func enqueue_standalone_structure_build(structure_type: String, base_x: int, base_z: int, level: float, dimensions: Vector2i, rng: RandomNumberGenerator, visual_source_id := "") -> void:
    var previous_visual_source_id:=active_structure_visual_source_id
    active_structure_visual_source_id=visual_source_id
    if structure_type == "mine":
        enqueue_deferred_build(func() -> void:
            build_mine(base_x, base_z, level, dimensions.x, dimensions.y, rng)
        )
    elif structure_type == "ruin":
        enqueue_deferred_build(func() -> void:
            build_ruin(base_x, base_z, level, dimensions.x, dimensions.y, rng)
        )
    elif structure_type == "shrine":
        enqueue_deferred_build(func() -> void:
            build_shrine(base_x, base_z, level, dimensions.x, dimensions.y, rng)
        )
    elif structure_type == "camp":
        enqueue_deferred_build(func() -> void:
            build_camp(base_x, base_z, level, dimensions.x, dimensions.y, rng)
        )
    else:
        var wall_type := "woodBlock" if rng.randf() < 0.5 else "stoneBlock"
        var roof_type := "stoneBlock" if wall_type == "woodBlock" else "woodBlock"
        var wall_height := rng.randi_range(4, 5)
        var door_side := rng.randi_range(0, 3)
        enqueue_deferred_build(func() -> void:
            build_building(base_x, base_z, level, dimensions.x, dimensions.y, wall_height, wall_type, roof_type, door_side, rng, false)
        )
    enqueue_structure_op({"type":"ordinary_visual_source_complete","visualSourceId":visual_source_id})
    active_structure_visual_source_id=previous_visual_source_id

func enqueue_deferred_build(build_callable: Callable) -> void:
    var previous := defer_structure_ops
    defer_structure_ops = true
    build_callable.call()
    defer_structure_ops = previous

func enqueue_deferred_town_build(town: Dictionary) -> void:
    if town.is_empty() or main == null:
        return
    var rng := RandomNumberGenerator.new()
    rng.seed = main.hash_string("%s:town-build:%d,%d" % [main.seed_text, int(town["regionX"]), int(town["regionZ"])])
    var town_key := town_key_for(town)
    _begin_ordinary_visual_source("town:"+town_key)
    var publish_state: Dictionary = town_manifest_publish_states.get(town_key, {}) if town_manifest_publish_states.get(town_key, {}) is Dictionary else {}
    if String(publish_state.get("status", "")) in ["queued", "building", "published"]:
        return
    var attempts := int(publish_state.get("generationAttempts", 0)) + 1
    town_manifest_publish_states[town_key] = {
        "status": "queued",
        "generationAttempts": attempts,
        "startedUsec": int(publish_state.get("startedUsec", Time.get_ticks_usec())),
        "updatedUsec": Time.get_ticks_usec(),
        "desiredHomeCount": town_home_count(town),
        "builtHomeCount": 0,
        "failureReasons": []
    }
    deferred_town_home_records[town_key] = []
    generated_town_count += 1
    enqueue_structure_op({
        "type": "town_build_phase",
        "townKey": town_key,
        "state": {
            "town": town.duplicate(true),
            "townKey": town_key,
            "phase": "paths",
            "rng": rng,
            "sites": town_home_sites(town, rng),
            "desiredHomeCount": town_home_count(town),
            "homeSiteIndex": 0,
            "builtHomeCount": 0
        }
    })

func process_deferred_town_build_phase(state_value) -> void:
    if not (state_value is Dictionary):
        return
    var state: Dictionary = state_value
    var town: Dictionary = state.get("town", {}) if state.get("town", {}) is Dictionary else {}
    if town.is_empty():
        return
    var rng := state.get("rng") as RandomNumberGenerator
    if rng == null:
        return
    var center_x := int(town["centerX"])
    var center_z := int(town["centerZ"])
    var level := float(town["level"])
    var town_key := String(state.get("townKey", town_key_for(town)))
    var phase := String(state.get("phase", "paths"))
    var complete := false
    var previous := defer_structure_ops
    var previous_town_key := active_structure_town_key
    var previous_visual_source_id:=active_structure_visual_source_id
    defer_structure_ops = true
    active_structure_town_key = town_key
    active_structure_visual_source_id="town:"+town_key
    update_town_manifest_publish_state(town_key, {
        "status": "building",
        "builtHomeCount": int(state.get("builtHomeCount", 0)),
        "desiredHomeCount": int(state.get("desiredHomeCount", town_home_count(town)))
    })
    if phase == "paths":
        build_town_paths(center_x, center_z, int(town["radius"]), level)
        state["phase"] = "perimeter"
    elif phase == "perimeter":
        build_town_perimeter(center_x, center_z, int(town["radius"]), level, town_key)
        state["phase"] = "homes"
    elif phase == "homes":
        process_deferred_town_home_phase(state, town, rng, town_key, level)
    elif phase == "market":
        build_town_market(center_x, center_z, level, rng)
        state["phase"] = "utilities"
    elif phase == "utilities":
        place_utility(center_x - 2, center_z + 1, level, "chest", {
            "storageSlots": loot.make_loot_slots(rng, "town"),
            "generatedTier": "town",
            "cacheKey": "%s:town-cache:%d,%d" % [main.seed_text, center_x, center_z]
        })
        place_utility(center_x + 2, center_z + 1, level, "furnace")
        place_utility(center_x, center_z - 3, level, "workbench")
        state["phase"] = "publish"
    elif phase == "publish":
        enqueue_structure_op({
            "type": "publish_town_home_records",
            "townKey": town_key
        })
        complete = true
    else:
        complete = true
    defer_structure_ops = previous
    active_structure_town_key = previous_town_key
    active_structure_visual_source_id=previous_visual_source_id
    if not complete:
        enqueue_structure_op({
            "type": "town_build_phase",
            "townKey": town_key,
            "state": state
        })

func process_deferred_town_home_phase(state: Dictionary, town: Dictionary, rng: RandomNumberGenerator, town_key: String, level: float) -> void:
    var sites: Array = state.get("sites", []) if state.get("sites", []) is Array else []
    var desired_home_count := int(state.get("desiredHomeCount", town_home_count(town)))
    var built_home_count := int(state.get("builtHomeCount", 0))
    var site_index := int(state.get("homeSiteIndex", 0))
    while site_index < sites.size() and built_home_count < desired_home_count:
        var site: Dictionary = sites[site_index] if sites[site_index] is Dictionary else {}
        site_index += 1
        if site.is_empty():
            continue
        var base_x := int(town["centerX"]) + int(site["dx"])
        var base_z := int(town["centerZ"]) + int(site["dz"])
        var side := int(site["side"])
        if town_home_site_excluded(town, base_x, base_z, 10, 10, side):
            continue
        var width := rng.randi_range(7, 9)
        var depth := rng.randi_range(7, 9)
        var wall_height := rng.randi_range(4, 5)
        var wall_type := "woodBlock" if site_index % 2 == 1 else "stoneBlock"
        if rng.randf() < 0.35:
            wall_type = "stoneBlock" if wall_type == "woodBlock" else "woodBlock"
        var roof_type := "stoneBlock" if wall_type == "woodBlock" else "woodBlock"
        if town_home_site_excluded(town, base_x, base_z, width, depth, side):
            continue
        build_building(base_x, base_z, level, width, depth, wall_height, wall_type, roof_type, side, rng, true)
        record_town_home(town_key, town, base_x, base_z, width, depth, side, built_home_count)
        built_home_count += 1
        break
    state["homeSiteIndex"] = site_index
    state["builtHomeCount"] = built_home_count
    update_town_manifest_publish_state(town_key, {
        "builtHomeCount": built_home_count,
        "desiredHomeCount": desired_home_count
    })
    if built_home_count >= desired_home_count or site_index >= sites.size():
        state["phase"] = "market"

func performance_monitor():
    if main == null:
        return null
    return main.get("runtime_perf_monitor")

func pending_structure_op_count() -> int:
    return max(0, pending_structure_ops.size() - pending_structure_op_index)+pending_structure_retry_ops.size()

func enqueue_structure_op(op: Dictionary) -> void:
    regional_source_revision += 1
    if active_structure_town_key != "" and String(op.get("townKey", "")) == "":
        op["townKey"] = active_structure_town_key
    if active_structure_visual_source_id!="" and String(op.get("visualSourceId",""))=="":
        op["visualSourceId"]=active_structure_visual_source_id
    pending_structure_ops.append(op)

func process_pending_structure_ops(max_ops := STREAMING_STRUCTURE_OPS_PER_FRAME, budget_ms := STREAMING_STRUCTURE_FRAME_BUDGET_MS) -> int:
    if not pending_structure_retry_ops.is_empty():
        pending_structure_ops.append_array(pending_structure_retry_ops)
        pending_structure_retry_ops.clear()
    if pending_structure_op_index >= pending_structure_ops.size():
        pending_structure_ops.clear()
        pending_structure_op_index = 0
        return 0
    var monitor = performance_monitor()
    var queue_start: int = monitor.begin_section("structure_op_queue") if monitor != null else Time.get_ticks_usec()
    var processed := 0
    var frame_start := Time.get_ticks_usec()
    while pending_structure_op_index < pending_structure_ops.size() and processed < max_ops:
        var op: Dictionary = pending_structure_ops[pending_structure_op_index]
        pending_structure_op_index += 1
        execute_structure_op(op)
        processed += 1
        if float(Time.get_ticks_usec() - frame_start) / 1000.0 >= budget_ms:
            break
    if pending_structure_op_index >= pending_structure_ops.size():
        pending_structure_ops.clear()
        pending_structure_op_index = 0
    elif pending_structure_op_index >= STREAMING_STRUCTURE_QUEUE_COMPACT_THRESHOLD:
        pending_structure_ops = pending_structure_ops.slice(pending_structure_op_index)
        pending_structure_op_index = 0
    if monitor != null:
        monitor.increment_counter("structure_ops_processed", processed)
        monitor.increment_counter("structure_op_queue_depth", pending_structure_op_count())
        monitor.end_section("structure_op_queue", queue_start)
    return processed

func execute_structure_op(op: Dictionary) -> void:
    if String(op.get("type","")) == "regional_standalone_source":
        var region: Vector2i = op.region
        update_standalone_structures(region*int(main.STRUCTURE_REGION_CELLS),true,1,region)
        if generated_structures.has(region):
            regional_standalone_requests.erase(region)
            regional_source_revision += 1
        else:
            # Retain one explicit retry while incremental terrain admission is
            # pending. Completion owns the revision change and construction
            # enqueue, so polling cannot consume or restart the request.
            pending_structure_retry_ops.append(op.duplicate(true))
        return
    regional_source_revision += 1
    var previous := defer_structure_ops
    var previous_visual_source_id:=active_structure_visual_source_id
    defer_structure_ops = false
    active_structure_visual_source_id=String(op.get("visualSourceId",""))
    var op_type := String(op.get("type", ""))
    if op_type == "block":
        place_structure_block(int(op.get("cellX", 0)), int(op.get("cellZ", 0)), float(op.get("level", 0.0)), int(op.get("dy", 0)), String(op.get("blockType", "")), op.get("options", {}))
    elif op_type == "path":
        place_path(int(op.get("cellX", 0)), int(op.get("cellZ", 0)), float(op.get("level", 0.0)), op.get("options", {}))
    elif op_type == "utility":
        place_utility(int(op.get("cellX", 0)), int(op.get("cellZ", 0)), float(op.get("level", 0.0)), String(op.get("blockType", "")), op.get("options", {}))
    elif op_type == "door":
        place_door(int(op.get("cellX", 0)), int(op.get("cellZ", 0)), float(op.get("level", 0.0)), int(op.get("side", 0)), bool(op.get("secondary", false)), String(op.get("doorPolicy", "private_home")))
    elif op_type == "terrain_footprint":
        reserve_structure_terrain_footprint(
            int(op.get("baseX", 0)),
            int(op.get("baseZ", 0)),
            float(op.get("level", 0.0)),
            int(op.get("width", 0)),
            int(op.get("depth", 0)),
            int(op.get("clearanceCells", 0)),
            String(op.get("source", "structure")),
            String(op.get("foundationMaterial", "stone"))
        )
    elif op_type == "publish_town_home_records":
        publish_deferred_town_home_records(String(op.get("townKey", "")))
        _complete_ordinary_visual_source("town:"+String(op.get("townKey","")))
    elif op_type == "town_build_phase":
        process_deferred_town_build_phase(op.get("state", {}))
    elif op_type == "ordinary_visual_source_complete":
        _complete_ordinary_visual_source(active_structure_visual_source_id)
    defer_structure_ops = previous
    active_structure_visual_source_id=previous_visual_source_id

func publish_deferred_town_home_records(town_key: String) -> void:
    if town_key == "":
        return
    var records: Array = deferred_town_home_records.get(town_key, [])
    var existing_value = town_home_records.get(town_key, [])
    var existing_records: Array = existing_value if existing_value is Array else []
    if existing_records.size() > records.size():
        deferred_town_home_records.erase(town_key)
        update_town_manifest_publish_state(town_key, {
            "status": "published",
            "builtHomeCount": existing_records.size()
        })
        return
    town_home_records[town_key] = records.duplicate(true)
    town_home_records_revision += 1
    deferred_town_home_records.erase(town_key)
    update_town_manifest_publish_state(town_key, {
        "status": "published",
        "builtHomeCount": records.size()
    })

func standalone_structure_type(rng: RandomNumberGenerator) -> String:
    return preload("res://scripts/world/StandaloneStructureCandidate.gd").standalone_structure_type(rng)

func structure_dimensions_for_type(structure_type: String, rng: RandomNumberGenerator) -> Vector2i:
    return preload("res://scripts/world/StandaloneStructureCandidate.gd").structure_dimensions_for_type(structure_type, rng)

func remember_terrain_surface_sample(cache_key: Vector2i, sample: Dictionary) -> Dictionary:
    terrain_surface_sample_cache[cache_key] = sample.duplicate(true)
    return sample

func terrain_surface_sample_at_cell(cell_x: int, cell_z: int) -> Dictionary:
    var cache_key := Vector2i(cell_x, cell_z)
    if terrain_surface_sample_cache.has(cache_key):
        var cached: Dictionary = terrain_surface_sample_cache[cache_key]
        return cached.duplicate(true)
    var column_cell := Vector3i(cell_x, 0, cell_z)
    var fallback_height := float(main.surface_y_at_cell(column_cell)) if main != null and main.has_method("surface_y_at_cell") else 0.0
    var fallback_biome := String(main.surface_biome_at_cell(column_cell)) if main != null and main.has_method("surface_biome_at_cell") else "plains"
    var fallback_material := ""
    var fallback := {
        "found": true,
        "height": fallback_height,
        "biome": fallback_biome,
        "material": fallback_material,
        "authority": "height_compat"
    }
    if main == null or main.world_generation_system == null:
        return remember_terrain_surface_sample(cache_key, fallback)
    var world_generation = main.world_generation_system
    if world_generation.has_method("terrain_volume_column_has_surface_projection_affecting_edits"):
        var has_surface_edits := bool(world_generation.call("terrain_volume_column_has_surface_projection_affecting_edits", column_cell))
        if not has_surface_edits:
            return remember_terrain_surface_sample(cache_key, fallback)
    if not world_generation.has_method("surface_projection_for_cell"):
        return remember_terrain_surface_sample(cache_key, fallback)
    var start_cell := Vector3i(cell_x, floori(fallback_height / main.CELL), cell_z)
    var projection: Dictionary = world_generation.call("surface_projection_for_cell", start_cell, 8, 32)
    if projection.is_empty() or not bool(projection.get("found", false)):
        fallback["found"] = false
        fallback["authority"] = "terrain_volume_projection"
        return remember_terrain_surface_sample(cache_key, fallback)
    var solid_state: Dictionary = projection.get("solidState", {}) if projection.get("solidState", {}) is Dictionary else {}
    var air_state: Dictionary = projection.get("airState", {}) if projection.get("airState", {}) is Dictionary else {}
    var material := String(solid_state.get("material", ""))
    if material == "" or material == "air" or material == "water" or material == "lava":
        fallback["found"] = false
        fallback["authority"] = "terrain_volume_projection"
        fallback["material"] = material
        return remember_terrain_surface_sample(cache_key, fallback)
    if String(air_state.get("fluid", "")) != "":
        fallback["found"] = false
        fallback["authority"] = "terrain_volume_projection"
        fallback["material"] = material
        return remember_terrain_surface_sample(cache_key, fallback)
    var air_cell: Vector3i = projection.get("airCell", start_cell + Vector3i(0, 1, 0))
    var biome := String(solid_state.get("biome", fallback_biome))
    if biome == "" or biome == "underground" or biome == "deep_underground" or biome == "underground_air":
        biome = fallback_biome
    return remember_terrain_surface_sample(cache_key, {
        "found": true,
        "height": float(air_cell.y) * main.CELL,
        "biome": biome,
        "material": material,
        "solidCell": projection.get("solidCell", start_cell),
        "airCell": air_cell,
        "authority": "terrain_volume_projection"
    })

func structure_surface_level_for_cell(cell_x: int, cell_z: int, fallback_level: float) -> float:
    var sample := terrain_surface_sample_at_cell(cell_x, cell_z)
    if bool(sample.get("found", false)):
        var level := float(sample.get("height", fallback_level))
        if not is_nan(level):
            return level
    return fallback_level

func structure_surface_level_for_gate_pair(first_cell: Vector2i, second_cell: Vector2i, fallback_level: float) -> float:
    var first_sample := terrain_surface_sample_at_cell(first_cell.x, first_cell.y)
    var second_sample := terrain_surface_sample_at_cell(second_cell.x, second_cell.y)
    var levels: Array[float] = []
    if bool(first_sample.get("found", false)):
        var first_level := float(first_sample.get("height", fallback_level))
        if not is_nan(first_level):
            levels.append(first_level)
    if bool(second_sample.get("found", false)):
        var second_level := float(second_sample.get("height", fallback_level))
        if not is_nan(second_level):
            levels.append(second_level)
    if levels.size() == 2:
        return (levels[0] + levels[1]) * 0.5
    if levels.size() == 1:
        return levels[0]
    return fallback_level

func reserve_structure_terrain_footprint(base_x: int, base_z: int, level: float, width: int, depth: int, clearance_cells: int, source: String, foundation_material := "stone") -> void:
    if defer_structure_ops:
        enqueue_structure_op({
            "type": "terrain_footprint",
            "baseX": base_x,
            "baseZ": base_z,
            "level": level,
            "width": width,
            "depth": depth,
            "clearanceCells": clearance_cells,
            "source": source,
            "foundationMaterial": foundation_material
        })
        return
    if main == null or main.world_generation_system == null:
        return
    var world_generation = main.world_generation_system
    if not world_generation.has_method("apply_box_edit"):
        return
    var floor_y := floori(level / main.CELL)
    record_structure_terrain_footprint(base_x, base_z, level, width, depth, clearance_cells, source, foundation_material, floor_y)
    var center_sample := terrain_surface_sample_at_cell(base_x + int(width / 2), base_z + int(depth / 2))
    var biome := String(center_sample.get("biome", "plains"))
    var foundation_state := {
        "material": foundation_material,
        "biome": biome,
        "solid": true,
        "density": main.CELL * 1.65,
        "fluid": "",
        "light": { "sky": 0, "block": 0 },
        "metadata": {
            "source": "structure_foundation",
            "structureSource": source,
            "terrainMeshAffects": true,
            "saveDelta": false
        }
    }
    var floor_cap_state := foundation_state.duplicate(true)
    floor_cap_state["density"] = main.CELL * 0.08
    var floor_cap_metadata: Dictionary = floor_cap_state.get("metadata", {}) if floor_cap_state.get("metadata", {}) is Dictionary else {}
    floor_cap_metadata = floor_cap_metadata.duplicate(true)
    floor_cap_metadata["source"] = "structure_floor_cap"
    floor_cap_metadata["structureSource"] = source
    floor_cap_state["metadata"] = floor_cap_metadata
    world_generation.call(
        "apply_box_edit",
        Vector3i(base_x - 1, floor_y - 3, base_z - 1),
        Vector3i(base_x + width, floor_y - 1, base_z + depth),
        foundation_state,
        "structure_foundation:%s" % source
    )
    world_generation.call(
        "apply_box_edit",
        Vector3i(base_x - 1, floor_y, base_z - 1),
        Vector3i(base_x + width, floor_y, base_z + depth),
        floor_cap_state,
        "structure_floor_cap:%s" % source
    )
    if width <= 2 or depth <= 2 or clearance_cells <= 0:
        return
    var interior_air_state := {
        "material": "air",
        "biome": biome,
        "solid": false,
        "density": -main.CELL,
        "fluid": "",
        "light": { "sky": 15, "block": 0 },
        "metadata": {
            "source": "structure_reserved_air",
            "structureSource": source,
            "terrainMeshAffects": true,
            "saveDelta": false
        }
    }
    world_generation.call(
        "apply_box_edit",
        Vector3i(base_x + 1, floor_y + 1, base_z + 1),
        Vector3i(base_x + width - 2, floor_y + clearance_cells, base_z + depth - 2),
        interior_air_state,
        "structure_air:%s" % source
    )

func record_structure_terrain_footprint(base_x: int, base_z: int, level: float, width: int, depth: int, clearance_cells: int, source: String, foundation_material: String, floor_y: int) -> void:
    regional_source_revision += 1
    if width <= 0 or depth <= 0:
        return
    var min_cell := Vector3i(base_x - 1, floor_y - 3, base_z - 1)
    var max_cell := Vector3i(base_x + width, floor_y, base_z + depth)
    var record_id := "%s:%d,%d:%dx%d:%d" % [source, base_x, base_z, width, depth, floor_y]
    var record := {
        "id": record_id,
        "source": source,
        "material": foundation_material,
        "baseX": base_x,
        "baseZ": base_z,
        "width": width,
        "depth": depth,
        "level": level,
        "floorY": floor_y,
        "clearanceCells": clearance_cells,
        "minCell": min_cell,
        "maxCell": max_cell
    }
    if terrain_footprint_records.get(record_id, {}) != record:
        terrain_footprint_records[record_id] = record
        surface_prop_exclusion_revision += 1

func structure_terrain_footprints_for_chunk(chunk_key: Vector2i, chunk_size: int) -> Array:
    var result := []
    var size := maxi(1, int(chunk_size))
    var start_x := chunk_key.x * size
    var start_z := chunk_key.y * size
    var end_x := start_x + size
    var end_z := start_z + size
    for record_value in terrain_footprint_records.values():
        if not (record_value is Dictionary):
            continue
        var record: Dictionary = record_value
        var min_cell: Vector3i = record.get("minCell", Vector3i.ZERO)
        var max_cell: Vector3i = record.get("maxCell", Vector3i.ZERO)
        if max_cell.x < start_x or min_cell.x >= end_x:
            continue
        if max_cell.z < start_z or min_cell.z >= end_z:
            continue
        result.append(record.duplicate(true))
    return result

func structure_terrain_footprints_snapshot() -> Array:
    var result := []
    for record_value in terrain_footprint_records.values():
        if record_value is Dictionary:
            result.append((record_value as Dictionary).duplicate(true))
    return result

func reserve_natural_prop_exclusion(base_x: int, base_z: int, width: int, depth: int, source: String) -> void:
    if width <= 0 or depth <= 0:
        return
    var record_id := "%s:%d,%d:%dx%d" % [source, base_x, base_z, width, depth]
    var record := {
        "id": record_id,
        "source": source,
        "minX": base_x,
        "maxX": base_x + width - 1,
        "minZ": base_z,
        "maxZ": base_z + depth - 1
    }
    if natural_prop_exclusion_records.get(record_id, {}) != record:
        natural_prop_exclusion_records[record_id] = record
        surface_prop_exclusion_revision += 1

func surface_prop_exclusion_records_revision() -> int:
    # Only owner API mutations are revisioned. A future native adapter must
    # still copy/hash the captured records because GDScript maps are mutable.
    return surface_prop_exclusion_revision

func capture_surface_tree_exclusion_halo(
    x: int, z: int, natural_margin_cells: int, structure_margin_cells: int
) -> Dictionary:
    # Capture the post-draw tree decision footprint, not just its 28-cell
    # source chunk. Source records outside that chunk can block the tree.
    if natural_margin_cells < 0 or structure_margin_cells < 0 \
        or natural_margin_cells > 4096 or structure_margin_cells > 4096:
        return {"ready":false, "reason":"invalid_margin"}
    var natural_margin := natural_margin_cells
    var structure_margin := structure_margin_cells
    var coverage := maxi(natural_margin, structure_margin)
    var ready := true
    var natural_rows := []
    for value in natural_prop_exclusion_records.values():
        if not (value is Dictionary):
            ready = false
            continue
        var row: Dictionary = value
        if String(row.get("id", "")).is_empty() or String(row.get("id", "")).length() > 1024 \
            or not (row.get("minX") is int) or not (row.get("maxX") is int) \
            or not (row.get("minZ") is int) or not (row.get("maxZ") is int):
            ready = false
            natural_rows.append(row.duplicate(true))
            continue
        if int(row.minX) > int(row.maxX) or int(row.minZ) > int(row.maxZ):
            ready = false
            natural_rows.append(row.duplicate(true))
            continue
        if x < int(row.get("minX", x)) - coverage or x > int(row.get("maxX", x)) + coverage: continue
        if z < int(row.get("minZ", z)) - coverage or z > int(row.get("maxZ", z)) + coverage: continue
        natural_rows.append(row.duplicate(true))
    natural_rows.sort_custom(func(a, b): return String(a.get("id", "")) < String(b.get("id", "")))
    var terrain_rows := []
    for value in terrain_footprint_records.values():
        if not (value is Dictionary):
            ready = false
            continue
        var row: Dictionary = value
        if String(row.get("id", "")).is_empty() or String(row.get("id", "")).length() > 1024 \
            or not (row.get("minCell") is Vector3i) or not (row.get("maxCell") is Vector3i):
            ready = false
            terrain_rows.append(row.duplicate(true))
            continue
        var low: Vector3i = row.get("minCell", Vector3i.ZERO)
        var high: Vector3i = row.get("maxCell", Vector3i.ZERO)
        if low.x > high.x or low.z > high.z:
            ready = false
            terrain_rows.append(row.duplicate(true))
            continue
        if x < low.x - coverage or x > high.x + coverage: continue
        if z < low.z - coverage or z > high.z + coverage: continue
        terrain_rows.append(row.duplicate(true))
    terrain_rows.sort_custom(func(a, b): return String(a.get("id", "")) < String(b.get("id", "")))
    if natural_rows.size() > 65536 or terrain_rows.size() > 65536: ready = false
    var bounds := Rect2i(Vector2i(x, z), Vector2i.ONE).grow(coverage)
    # A source_state lookup alone cannot distinguish a genuinely undecided
    # region from an irrelevant candidate. Exact ready bounds admission does.
    var bounds_admission: Dictionary = citadel_terrain_admission.request_bounds(bounds)
    if bounds_admission.get("status") != "ready": ready = false
    var low_region := CitadelSiteFieldScript.region_for_cell(bounds.position)
    var high_region := CitadelSiteFieldScript.region_for_cell(bounds.end - Vector2i.ONE)
    var source_rows := []
    for region_z in range(low_region.y, high_region.y + 1):
        for region_x in range(low_region.x, high_region.x + 1):
            var region := Vector2i(region_x, region_z)
            var state: Dictionary = citadel_terrain_admission.source_state(region)
            var status := String(state.get("status", ""))
            # A failed source outside this footprint is irrelevant when the
            # exact bounds request is ready; a failed relevant source makes
            # that request fail before this capture can be admitted.
            if status not in ["ready", "prepared", "absent", "failed"]:
                ready = false
            var binding_value: Variant = state.get("binding", {})
            if not (binding_value is Dictionary):
                ready = false
                binding_value = {}
            var binding: Dictionary = binding_value
            var source_key := String(binding.get("sourceKey", state.get("sourceKey", "")))
            var source_generation := int(binding.get("generation", -1))
            # A source payload is mutable and potentially huge. Only its
            # admission identity and half-open reservation are needed here.
            var source_row := {"region":region, "status":status,
                "reason":String(state.get("reason", "")),
                "sourceKey":source_key, "sourceGeneration":source_generation,
                "binding":binding.duplicate(true),
                "sourceSignature":String(state.get("sourceSignature", "")),
                "reservationCells":state.get("reservationCells", Rect2i())}
            if status in ["ready", "prepared"] and (not state.has("reservationCells") or not (state.reservationCells is Rect2i) \
                or not state.has("sourceSignature") or String(state.sourceSignature).is_empty() \
                or source_key.is_empty() or not (binding.get("generation") is int) or source_generation <= 0 \
                or String(binding.get("siteId", "")).is_empty() \
                or (state.get("reservationCells") is Rect2i and (state.reservationCells.size.x <= 0 or state.reservationCells.size.y <= 0))):
                ready = false
            source_rows.append(source_row)
    var content := {"natural":natural_rows, "terrain":terrain_rows, "citadel":source_rows}
    return {"ownerInstanceId":get_instance_id(), "ownerGeneration":regional_source_generation,
        "exclusionRevision":surface_prop_exclusion_revision, "cell":Vector2i(x, z),
        "naturalMarginCells":natural_margin, "structureMarginCells":structure_margin,
        "ready":ready, "boundsAdmission":bounds_admission.duplicate(true), "content":content,
        "contentDigest":Marshalls.raw_to_base64(var_to_bytes([
            Vector2i(x, z), natural_margin, structure_margin, bounds_admission, content])).sha256_text()}

func surface_tree_exclusion_halo_is_current(snapshot: Dictionary) -> bool:
    for required in ["cell", "naturalMarginCells", "structureMarginCells", "boundsAdmission", "content", "contentDigest"]:
        if not snapshot.has(required): return false
    if not (snapshot.cell is Vector2i) or not (snapshot.content is Dictionary): return false
    if int(snapshot.get("ownerInstanceId", -1)) != get_instance_id(): return false
    if int(snapshot.get("ownerGeneration", -1)) != regional_source_generation: return false
    if int(snapshot.get("exclusionRevision", -1)) != surface_prop_exclusion_revision: return false
    var cell: Vector2i = snapshot.get("cell", Vector2i.ZERO)
    var current := capture_surface_tree_exclusion_halo(cell.x, cell.y,
        int(snapshot.get("naturalMarginCells", -1)), int(snapshot.get("structureMarginCells", -1)))
    return bool(snapshot.get("ready", false)) and bool(current.ready) \
        and snapshot.get("boundsAdmission", {}) == current.boundsAdmission \
        and snapshot.get("content", {}) == current.content \
        and snapshot.get("contentDigest", "") == current.contentDigest \
        and snapshot.get("naturalMarginCells", -1) == current.naturalMarginCells \
        and snapshot.get("structureMarginCells", -1) == current.structureMarginCells

func blocks_natural_prop_at_cell(x: int, z: int) -> bool:
    return blocks_natural_prop_with_margin_at_cell(x, z, 0)

func blocks_natural_prop_with_margin_at_cell(x: int, z: int, margin_cells: int) -> bool:
    return blocks_natural_prop_with_separate_margins_at_cell(x, z, margin_cells, margin_cells)

func blocks_natural_prop_with_separate_margins_at_cell(
    x: int,
    z: int,
    natural_exclusion_margin_cells: int,
    structure_footprint_margin_cells: int
) -> bool:
    var natural_margin := maxi(0, natural_exclusion_margin_cells)
    for record_value in natural_prop_exclusion_records.values():
        if not (record_value is Dictionary):
            continue
        var record: Dictionary = record_value
        if x >= int(record.get("minX", x)) - natural_margin \
            and x <= int(record.get("maxX", x)) + natural_margin \
            and z >= int(record.get("minZ", z)) - natural_margin \
            and z <= int(record.get("maxZ", z)) + natural_margin:
            return true
    var structure_margin := maxi(0, structure_footprint_margin_cells)
    for record_value in terrain_footprint_records.values():
        if not (record_value is Dictionary):
            continue
        var record: Dictionary = record_value
        var min_cell: Vector3i = record.get("minCell", Vector3i.ZERO)
        var max_cell: Vector3i = record.get("maxCell", Vector3i.ZERO)
        if x >= min_cell.x - structure_margin and x <= max_cell.x + structure_margin \
            and z >= min_cell.z - structure_margin and z <= max_cell.z + structure_margin:
            return true
    # Surface land use belongs to admitted source reservations, including when
    # the reconstructible source or its scene is not resident. Pending source
    # demand is handled before chunk prop RNG, not treated as an exclusion here.
    var bounds := Rect2i(Vector2i(x, z), Vector2i.ONE).grow(structure_margin)
    var low := CitadelSiteFieldScript.region_for_cell(bounds.position)
    var high := CitadelSiteFieldScript.region_for_cell(bounds.end - Vector2i.ONE)
    for region_z in range(low.y, high.y + 1):
        for region_x in range(low.x, high.x + 1):
            var source: Dictionary = citadel_terrain_admission.source_state(Vector2i(region_x, region_z))
            if source.get("status") not in ["ready", "prepared"]:
                continue
            var reservation: Rect2i = source.reservationCells
            if reservation.intersects(bounds):
                return true
    return false

func build_town(town: Dictionary) -> void:
    var rng := RandomNumberGenerator.new()
    rng.seed = main.hash_string("%s:town-build:%d,%d" % [main.seed_text, int(town["regionX"]), int(town["regionZ"])])
    var center_x := int(town["centerX"])
    var center_z := int(town["centerZ"])
    var level := float(town["level"])
    var town_key := town_key_for(town)
    var previous_town_key := active_structure_town_key
    var previous_visual_source_id:=active_structure_visual_source_id
    active_structure_town_key = town_key
    active_structure_visual_source_id="town:"+town_key
    _begin_ordinary_visual_source(active_structure_visual_source_id)
    begin_town_manifest_generation_state(town_key, town)
    if defer_structure_ops:
        deferred_town_home_records[town_key] = []
    else:
        town_home_records[town_key] = []
        town_home_records_revision += 1
    generated_town_count += 1
    build_town_paths(center_x, center_z, int(town["radius"]), level)
    build_town_perimeter(center_x, center_z, int(town["radius"]), level, town_key)
    var desired_home_count := town_home_count(town)
    var sites := town_home_sites(town, rng)
    var built_home_count := 0
    for i in range(sites.size()):
        if built_home_count >= desired_home_count:
            break
        var site: Dictionary = sites[i]
        var base_x := center_x + int(site["dx"])
        var base_z := center_z + int(site["dz"])
        var side := int(site["side"])
        if town_home_site_excluded(town, base_x, base_z, 10, 10, side):
            continue
        var width := rng.randi_range(7, 9)
        var depth := rng.randi_range(7, 9)
        var wall_height := rng.randi_range(4, 5)
        var wall_type := "woodBlock" if i % 2 == 0 else "stoneBlock"
        if rng.randf() < 0.35:
            wall_type = "stoneBlock" if wall_type == "woodBlock" else "woodBlock"
        var roof_type := "stoneBlock" if wall_type == "woodBlock" else "woodBlock"
        if town_home_site_excluded(town, base_x, base_z, width, depth, side):
            continue
        build_building(base_x, base_z, level, width, depth, wall_height, wall_type, roof_type, side, rng, true)
        record_town_home(town_key, town, base_x, base_z, width, depth, side, built_home_count)
        built_home_count += 1
    build_town_market(center_x, center_z, level, rng)
    place_utility(center_x - 2, center_z + 1, level, "chest", {
        "storageSlots": loot.make_loot_slots(rng, "town"),
        "generatedTier": "town",
        "cacheKey": "%s:town-cache:%d,%d" % [main.seed_text, center_x, center_z]
    })
    place_utility(center_x + 2, center_z + 1, level, "furnace")
    place_utility(center_x, center_z - 3, level, "workbench")
    if defer_structure_ops:
        enqueue_structure_op({
            "type": "publish_town_home_records",
            "townKey": town_key
        })
    else:
        update_town_manifest_publish_state(town_key, {
            "status": "published",
            "builtHomeCount": built_home_count
        })
        _complete_ordinary_visual_source(active_structure_visual_source_id)
    active_structure_town_key = previous_town_key
    active_structure_visual_source_id=previous_visual_source_id

func build_town_paths(center_x: int, center_z: int, radius: int, level: float) -> void:
    var path_span: int = max(10, radius - 2)
    for offset in range(-path_span, path_span + 1):
        place_town_path_cell(center_x + offset, center_z, level)
        place_town_path_cell(center_x, center_z + offset, level)
        if offset % 4 == 0:
            place_town_path_cell(center_x + offset, center_z + 1, level)
            place_town_path_cell(center_x + 1, center_z + offset, level)

func place_town_path_cell(cell_x: int, cell_z: int, fallback_level: float, extra_options: Dictionary = {}) -> void:
    place_path(cell_x, cell_z, structure_surface_level_for_cell(cell_x, cell_z, fallback_level), extra_options)

func town_home_count(town: Dictionary) -> int:
    var radius := int(town.get("radius", main.TOWN_RADIUS_CELLS))
    var extra_from_radius: int = clampi(floori(float(radius - main.TOWN_RADIUS_CELLS) * 0.75), 0, 7)
    var bonus := int(main.hash01("town-home-count:%d,%d" % [int(town.get("regionX", 0)), int(town.get("regionZ", 0))]) * 3.0)
    return clampi(4 + extra_from_radius + bonus, 4, 12)

func town_home_sites(town: Dictionary, _rng: RandomNumberGenerator) -> Array:
    var radius := int(town.get("radius", main.TOWN_RADIUS_CELLS))
    var candidates := [
        { "dx": -16, "dz": -13, "side": 2 },
        { "dx": 8, "dz": -14, "side": 2 },
        { "dx": -17, "dz": 8, "side": 0 },
        { "dx": 9, "dz": 9, "side": 0 },
        { "dx": -5, "dz": -25, "side": 2 },
        { "dx": 22, "dz": -4, "side": 1 },
        { "dx": -29, "dz": -4, "side": 3 },
        { "dx": -5, "dz": 20, "side": 0 },
        { "dx": 18, "dz": 18, "side": 0 },
        { "dx": -24, "dz": 18, "side": 0 },
        { "dx": 18, "dz": -24, "side": 2 },
        { "dx": -24, "dz": -24, "side": 2 }
    ]
    var sites := []
    for candidate_value in candidates:
        var candidate: Dictionary = candidate_value
        var dx := int(candidate.get("dx", 0))
        var dz := int(candidate.get("dz", 0))
        if maxi(absi(dx), absi(dz)) > radius - 4:
            continue
        sites.append(candidate)
    return sites

func town_home_site_excluded(town: Dictionary, base_x: int, base_z: int, width: int, depth: int, door_side: int) -> bool:
    var rings_value = town.get("homeExclusionRings", [])
    if not (rings_value is Array):
        return false
    var min_x := base_x - 1
    var max_x := base_x + width
    var min_z := base_z - 1
    var max_z := base_z + depth
    var door_entries := StructureDoorRulesScript.door_cells(width, depth, door_side)
    for entry_value in door_entries:
        var entry: Dictionary = entry_value
        var door_x := base_x + int(entry.get("x", 0))
        var door_z := base_z + int(entry.get("z", 0))
        if door_side == 0:
            max_z = maxi(max_z, door_z + 1)
        elif door_side == 2:
            min_z = mini(min_z, door_z - 1)
        elif door_side == 1:
            max_x = maxi(max_x, door_x + 1)
        elif door_side == 3:
            min_x = mini(min_x, door_x - 1)
    var center_x := int(town.get("centerX", 0))
    var center_z := int(town.get("centerZ", 0))
    for ring_value in rings_value:
        if not (ring_value is Dictionary):
            continue
        var ring: Dictionary = ring_value
        var radius := int(ring.get("radius", 0))
        if radius <= 0:
            continue
        var margin := maxi(0, int(ring.get("margin", 0)))
        if rect_intersects_town_ring(min_x, max_x, min_z, max_z, center_x, center_z, radius, margin):
            return true
    return false

func rect_intersects_town_ring(min_x: int, max_x: int, min_z: int, max_z: int, center_x: int, center_z: int, radius: int, margin: int) -> bool:
    var west := center_x - radius
    var east := center_x + radius
    var north := center_z - radius
    var south := center_z + radius
    var min_ring_x := west - margin
    var max_ring_x := east + margin
    var min_ring_z := north - margin
    var max_ring_z := south + margin
    if ranges_intersect(min_z, max_z, north - margin, north + margin) and ranges_intersect(min_x, max_x, min_ring_x, max_ring_x):
        return true
    if ranges_intersect(min_z, max_z, south - margin, south + margin) and ranges_intersect(min_x, max_x, min_ring_x, max_ring_x):
        return true
    if ranges_intersect(min_x, max_x, west - margin, west + margin) and ranges_intersect(min_z, max_z, min_ring_z, max_ring_z):
        return true
    if ranges_intersect(min_x, max_x, east - margin, east + margin) and ranges_intersect(min_z, max_z, min_ring_z, max_ring_z):
        return true
    return false

func ranges_intersect(a_min: int, a_max: int, b_min: int, b_max: int) -> bool:
    return a_min <= b_max and b_min <= a_max

func build_town_perimeter(center_x: int, center_z: int, radius: int, level: float, town_key: String) -> void:
    var gate_cells := {}
    var north_level := structure_surface_level_for_gate_pair(Vector2i(center_x, center_z - radius), Vector2i(center_x + 1, center_z - radius), level)
    var south_level := structure_surface_level_for_gate_pair(Vector2i(center_x, center_z + radius), Vector2i(center_x + 1, center_z + radius), level)
    var west_level := structure_surface_level_for_gate_pair(Vector2i(center_x - radius, center_z), Vector2i(center_x - radius, center_z + 1), level)
    var east_level := structure_surface_level_for_gate_pair(Vector2i(center_x + radius, center_z), Vector2i(center_x + radius, center_z + 1), level)
    for offset in [0, 1]:
        gate_cells[Vector2i(center_x + offset, center_z - radius)] = { "side": 2, "secondary": offset == 1, "axis": "x", "level": north_level }
        gate_cells[Vector2i(center_x + offset, center_z + radius)] = { "side": 0, "secondary": offset == 1, "axis": "x", "level": south_level }
        gate_cells[Vector2i(center_x - radius, center_z + offset)] = { "side": 3, "secondary": offset == 1, "axis": "z", "level": west_level }
        gate_cells[Vector2i(center_x + radius, center_z + offset)] = { "side": 1, "secondary": offset == 1, "axis": "z", "level": east_level }
    for offset in range(-radius, radius + 1):
        place_town_perimeter_cell(center_x + offset, center_z - radius, level, gate_cells, "x", town_key)
        place_town_perimeter_cell(center_x + offset, center_z + radius, level, gate_cells, "x", town_key)
        place_town_perimeter_cell(center_x - radius, center_z + offset, level, gate_cells, "z", town_key)
        place_town_perimeter_cell(center_x + radius, center_z + offset, level, gate_cells, "z", town_key)

func place_town_perimeter_cell(cell_x: int, cell_z: int, level: float, gate_cells: Dictionary, axis: String, town_key: String) -> void:
    var cell := Vector2i(cell_x, cell_z)
    if gate_cells.has(cell):
        var gate: Dictionary = gate_cells[cell]
        var gate_level := float(gate.get("level", structure_surface_level_for_cell(cell_x, cell_z, level)))
        place_path(cell_x, cell_z, gate_level, { "generatedTier": "town", "cacheKey": "%s:town-gate-path:%s:%d,%d" % [main.seed_text, town_key, cell_x, cell_z] })
        place_door(cell_x, cell_z, gate_level, int(gate.get("side", 0)), bool(gate.get("secondary", false)), "public_gate")
        return
    var fence_level := structure_surface_level_for_cell(cell_x, cell_z, level)
    place_structure_block(cell_x, cell_z, fence_level, 0, "woodBlock", {
        "generatedTier": "town",
        "accentRole": "fencePost",
        "fenceAxis": axis,
        "cacheKey": "%s:town-fence:%s:%d,%d" % [main.seed_text, town_key, cell_x, cell_z]
    })

func build_town_market(center_x: int, center_z: int, level: float, rng: RandomNumberGenerator) -> void:
    var stalls := [
        { "dx": -5, "dz": -5, "facing": PI * 0.5 },
        { "dx": 5, "dz": -5, "facing": -PI * 0.5 },
        { "dx": -5, "dz": 5, "facing": PI * 0.5 },
        { "dx": 5, "dz": 5, "facing": -PI * 0.5 }
    ]
    var count := 2 + rng.randi_range(0, 1)
    for i in range(count):
        var stall: Dictionary = stalls[i]
        place_utility(center_x + int(stall["dx"]), center_z + int(stall["dz"]), level, "traderStall", {
            "facing": float(stall["facing"]),
            "generatedTier": "town"
        })

func town_key_for(town: Dictionary) -> String:
    return "%d,%d" % [int(town.get("centerX", 0)), int(town.get("centerZ", 0))]

func town_home_door_portal_id(door_cell: Vector2i, level: float, door_side: int) -> String:
    if main == null:
        return ""
    var world_y: float = level + float(main.CELL) * 0.48
    var cell_y: int = floori(world_y / float(main.CELL)) + 1
    return "door:door-group:%d,%d,%d:%d" % [door_cell.x, cell_y, door_cell.y, door_side]

func record_town_home(town_key: String, town: Dictionary, base_x: int, base_z: int, width: int, depth: int, door_side: int, index: int) -> void:
    if town_key == "":
        return
    if not town_home_records.has(town_key):
        town_home_records[town_key] = []
    var center_cell := Vector2i(base_x + int(width / 2), base_z + int(depth / 2))
    var home_cell := center_cell
    var porch_cell := home_cell
    var guard_cell := home_cell
    var interior_min_cell := Vector2i(base_x + 1, base_z + 1)
    var interior_max_cell := Vector2i(base_x + width - 2, base_z + depth - 2)
    var door_cell := porch_cell
    var interior_landing_cell := home_cell
    var door_entries := StructureDoorRulesScript.door_cells(width, depth, door_side)
    if not door_entries.is_empty():
        var entry: Dictionary = door_entries[0]
        door_cell = Vector2i(base_x + int(entry.get("x", 0)), base_z + int(entry.get("z", 0)))
        var interior_landing := door_cell
        var inward := Vector2i.ZERO
        porch_cell = door_cell
        if door_side == 0:
            porch_cell.y += 1
            guard_cell = Vector2i(porch_cell.x, porch_cell.y + 4)
            inward = Vector2i(0, -1)
        elif door_side == 2:
            porch_cell.y -= 1
            guard_cell = Vector2i(porch_cell.x, porch_cell.y - 4)
            inward = Vector2i(0, 1)
        elif door_side == 1:
            porch_cell.x += 1
            guard_cell = Vector2i(porch_cell.x + 4, porch_cell.y)
            inward = Vector2i(-1, 0)
        else:
            porch_cell.x -= 1
            guard_cell = Vector2i(porch_cell.x - 4, porch_cell.y)
            inward = Vector2i(1, 0)
        interior_landing = door_cell + inward
        home_cell = door_cell + inward * 3
        var lateral := Vector2i(-inward.y, inward.x)
        if lateral != Vector2i.ZERO:
            var center_delta := (center_cell.x - door_cell.x) * lateral.x + (center_cell.y - door_cell.y) * lateral.y
            var lateral_sign := 1 if center_delta >= 0 else -1
            home_cell += lateral * lateral_sign * 2
        interior_landing.x = clampi(interior_landing.x, interior_min_cell.x, interior_max_cell.x)
        interior_landing.y = clampi(interior_landing.y, interior_min_cell.y, interior_max_cell.y)
        interior_landing_cell = interior_landing
        home_cell.x = clampi(home_cell.x, interior_min_cell.x, interior_max_cell.x)
        home_cell.y = clampi(home_cell.y, interior_min_cell.y, interior_max_cell.y)
    var route_candidates := [porch_cell, door_cell, interior_landing_cell, home_cell]
    var home_route_cells: Array = []
    for route_cell_variant in route_candidates:
        if not (route_cell_variant is Vector2i):
            continue
        var route_cell: Vector2i = route_cell_variant
        if home_route_cells.is_empty() or home_route_cells[home_route_cells.size() - 1] != route_cell:
            home_route_cells.append(route_cell)
    var record := {
        "id": "%s:home:%d" % [town_key, index],
        "stableId": "%s:home:%d" % [town_key, index],
        "homeKey": index,
        "townKey": town_key,
        "townCenter": Vector2i(int(town.get("centerX", 0)), int(town.get("centerZ", 0))),
        "townRadius": int(town.get("radius", main.TOWN_RADIUS_CELLS)),
        "level": float(town.get("level", 16.0)),
        "homeCell": home_cell,
        "porchCell": porch_cell,
        "doorCell": door_cell,
        "doorPortalId": town_home_door_portal_id(door_cell, float(town.get("level", 16.0)), door_side),
        "interiorLandingCell": interior_landing_cell,
        "homeRouteCells": home_route_cells,
        "guardCell": guard_cell,
        "interiorMinCell": interior_min_cell,
        "interiorMaxCell": interior_max_cell,
        "buildingIndex": index
    }
    if defer_structure_ops:
        if not deferred_town_home_records.has(town_key):
            deferred_town_home_records[town_key] = []
        (deferred_town_home_records[town_key] as Array).append(record)
        return
    town_home_records[town_key].append(record)
    town_home_records_revision += 1

func town_home_records_snapshot() -> Dictionary:
    return town_home_records.duplicate(true)

func town_home_records_source_revision() -> int:
    return town_home_records_revision

func ensure_town_home_records(town: Dictionary, requirements_or_minimum = {}) -> Array:
    var requirements := normalized_town_manifest_requirements(requirements_or_minimum)
    var status := town_manifest_status(town, requirements)
    if String(status.get("status", "")) != StartupReadinessResultScript.STATUS_READY:
        return []
    var town_key := town_key_for(town)
    var records_value = town_home_records.get(town_key, [])
    return (records_value as Array).duplicate(true) if records_value is Array else []

func town_manifest_status(town: Dictionary, requirements: Dictionary) -> Dictionary:
    if main == null:
        return StartupReadinessResultScript.failed("missing_structure_main", {}, [], {})
    if town.is_empty():
        return StartupReadinessResultScript.failed("missing_town", {}, [], {})
    var requirements_validation := validate_town_manifest_requirements(requirements)
    if not bool(requirements_validation.get("ok", false)):
        return StartupReadinessResultScript.failed("invalid_town_requirements", {}, [], {
            "failureReasons": requirements_validation.get("problems", [])
        })
    var town_key := town_key_for(town)
    var required_keys: Array = requirements.get("requiredHomeKeys", [])
    var records_value = town_home_records.get(town_key, [])
    var records: Array = records_value.duplicate(true) if records_value is Array else []
    var portal_ids: Array = []
    var published_keys: Array = []
    for record_value in records:
        if not (record_value is Dictionary):
            continue
        var record: Dictionary = record_value
        published_keys.append(int(record.get("homeKey", record.get("buildingIndex", -1))))
        var portal_id := String(record.get("doorPortalId", ""))
        if portal_id != "":
            portal_ids.append(portal_id)
    published_keys = TownRuntimeManifestScript.sorted_unique_ints(published_keys)
    var pending_count := pending_structure_op_count_for_town(town_key)
    var manifest := TownRuntimeManifestScript.build(
        String(main.seed_text),
        town_key,
        Vector2i(int(town.get("centerX", 0)), int(town.get("centerZ", 0))),
        1,
        required_keys,
        records,
        portal_ids,
        pending_count
    )
    var validation: Dictionary = TownRuntimeManifestScript.validate(manifest)
    var publish_state: Dictionary = town_manifest_publish_states.get(town_key, {}) if town_manifest_publish_states.get(town_key, {}) is Dictionary else {}
    var elapsed_ms := 0.0
    var started_usec := int(publish_state.get("startedUsec", 0))
    if started_usec > 0:
        elapsed_ms = maxf(0.0, float(Time.get_ticks_usec() - started_usec) / 1000.0)
    var metrics := {
        "townKey": town_key,
        "requiredKeys": required_keys.duplicate(),
        "publishedKeys": published_keys,
        "pendingOpCount": pending_count,
        "generationAttempts": int(publish_state.get("generationAttempts", 0)),
        "elapsedLoadingMs": snappedf(elapsed_ms, 0.001),
        "publishState": String(publish_state.get("status", "not_requested")),
        "failureReasons": validation.get("problems", [])
    }
    if pending_count > 0 or String(publish_state.get("status", "")) in ["queued", "building"]:
        return StartupReadinessResultScript.pending(
            "required_town_structure_operations_pending",
            manifest,
            ["town_structure_operations"],
            metrics
        )
    if bool(validation.get("ok", false)):
        return StartupReadinessResultScript.ready(manifest, metrics)
    if int(publish_state.get("generationAttempts", 0)) > 0 or String(publish_state.get("status", "")) in ["published", "failed"]:
        metrics["publishState"] = "failed"
        return StartupReadinessResultScript.failed("required_town_manifest_generation_failed", manifest, [], metrics)
    return StartupReadinessResultScript.pending("town_manifest_generation_not_requested", manifest, ["town_generation"], metrics)

func request_town_manifest_publication(town: Dictionary, requirements: Dictionary, max_ops := STREAMING_STRUCTURE_OPS_PER_FRAME, budget_ms := STREAMING_STRUCTURE_FRAME_BUDGET_MS) -> Dictionary:
    var initial := town_manifest_status(town, requirements)
    if String(initial.get("status", "")) in [StartupReadinessResultScript.STATUS_READY, StartupReadinessResultScript.STATUS_FAILED]:
        return initial
    var town_key := town_key_for(town)
    var publish_state: Dictionary = town_manifest_publish_states.get(town_key, {}) if town_manifest_publish_states.get(town_key, {}) is Dictionary else {}
    if int(publish_state.get("generationAttempts", 0)) == 0 and pending_structure_op_count_for_town(town_key) == 0:
        generated_towns[Vector2i(int(town.get("regionX", 0)), int(town.get("regionZ", 0)))] = true
        enqueue_deferred_town_build(town)
    process_pending_structure_ops(maxi(1, int(max_ops)), maxf(0.1, float(budget_ms)))
    return town_manifest_status(town, requirements)

func pending_structure_op_count_for_town(town_key: String) -> int:
    if town_key == "":
        return 0
    var count := 0
    for index in range(pending_structure_op_index, pending_structure_ops.size()):
        var op_value = pending_structure_ops[index]
        if not (op_value is Dictionary):
            continue
        var op: Dictionary = op_value
        var owner_key := String(op.get("townKey", ""))
        if owner_key == "" and op.get("state", {}) is Dictionary:
            owner_key = String((op.get("state", {}) as Dictionary).get("townKey", ""))
        if owner_key == town_key:
            count += 1
    return count

func begin_town_manifest_generation_state(town_key: String, town: Dictionary) -> void:
    regional_source_revision += 1
    var current: Dictionary = town_manifest_publish_states.get(town_key, {}) if town_manifest_publish_states.get(town_key, {}) is Dictionary else {}
    town_manifest_publish_states[town_key] = {
        "status": "building",
        "generationAttempts": maxi(1, int(current.get("generationAttempts", 0))),
        "startedUsec": int(current.get("startedUsec", Time.get_ticks_usec())),
        "updatedUsec": Time.get_ticks_usec(),
        "desiredHomeCount": town_home_count(town),
        "builtHomeCount": int(current.get("builtHomeCount", 0)),
        "failureReasons": []
    }

func update_town_manifest_publish_state(town_key: String, changes: Dictionary) -> void:
    regional_source_revision += 1
    if town_key == "":
        return
    var state: Dictionary = town_manifest_publish_states.get(town_key, {}) if town_manifest_publish_states.get(town_key, {}) is Dictionary else {}
    for key in changes.keys():
        state[key] = changes[key]
    state["updatedUsec"] = Time.get_ticks_usec()
    town_manifest_publish_states[town_key] = state

func normalized_town_manifest_requirements(value) -> Dictionary:
    if value is Dictionary:
        return (value as Dictionary).duplicate(true)
    var minimum_count := maxi(0, int(value))
    var keys: Array = []
    for key in range(minimum_count):
        keys.append(key)
    return {
        "ok": true,
        "requiredHomeKeys": keys,
        "actorHomeAssignments": {},
        "problems": []
    }

func validate_town_manifest_requirements(requirements: Dictionary) -> Dictionary:
    var problems: Array[String] = []
    var required_keys_value = requirements.get("requiredHomeKeys", [])
    var required_keys := {}
    if not (required_keys_value is Array):
        problems.append("requiredHomeKeys must be an array")
    else:
        for index in range((required_keys_value as Array).size()):
            var key_value = (required_keys_value as Array)[index]
            if not (key_value is int):
                problems.append("requiredHomeKeys[%d] must be an integer" % index)
                continue
            var home_key := int(key_value)
            if home_key < 0:
                problems.append("requiredHomeKeys[%d] must be non-negative" % index)
            elif required_keys.has(home_key):
                problems.append("requiredHomeKeys contains duplicate key %d" % home_key)
            else:
                required_keys[home_key] = true
    var assignments_value = requirements.get("actorHomeAssignments", {})
    if not (assignments_value is Dictionary):
        problems.append("actorHomeAssignments must be a dictionary")
    else:
        for actor_id_value in (assignments_value as Dictionary).keys():
            var actor_id := String(actor_id_value).strip_edges()
            var assignment_value = (assignments_value as Dictionary).get(actor_id_value)
            if actor_id == "":
                problems.append("actorHomeAssignments contains an empty actor id")
            if not (assignment_value is int):
                problems.append("actorHomeAssignments[%s] must be an integer" % actor_id)
                continue
            var assigned_key := int(assignment_value)
            if assigned_key < 0 or not required_keys.has(assigned_key):
                problems.append("actorHomeAssignments[%s] references undeclared homeKey %d" % [actor_id, assigned_key])
    for problem in requirements.get("problems", []):
        problems.append(String(problem))
    if requirements.has("ok") and not bool(requirements.get("ok", false)) and problems.is_empty():
        problems.append("requirements builder reported failure")
    return {"ok": problems.is_empty(), "problems": problems}

func build_building(base_x: int, base_z: int, level: float, width: int, depth: int, wall_height: int, wall_type: String, roof_type: String, door_side: int, rng: RandomNumberGenerator, town_building: bool) -> void:
    generated_building_count += 1
    reserve_structure_terrain_footprint(base_x, base_z, level, width, depth, wall_height, "town_home" if town_building else "cabin", "stone")
    var doors := StructureDoorRulesScript.door_cells(width, depth, door_side)
    for dy in range(wall_height):
        for x in range(width):
            for z in range(depth):
                var perimeter := x == 0 or z == 0 or x == width - 1 or z == depth - 1
                if not perimeter:
                    continue
                var door_entry: Dictionary = StructureDoorRulesScript.door_entry_at(doors, x, z)
                if not door_entry.is_empty():
                    if dy == 0:
                        place_door(base_x + x, base_z + z, level, door_side, bool(door_entry.get("secondary", false)))
                    if dy <= 1:
                        continue
                var block_type := wall_type
                var window_line := dy == 2 and door_entry.is_empty() and wall_height >= 4
                var window_axis_match := z % 3 == 1 if (x == 0 or x == width - 1) else x % 3 == 1
                if window_line and window_axis_match:
                    block_type = "glass"
                place_structure_block(base_x + x, base_z + z, level, dy, block_type, wall_visual_options(x, z, width, depth, dy, block_type, wall_type))
    for x in range(-1, width + 1):
        for z in range(-1, depth + 1):
            place_structure_block(base_x + x, base_z + z, level, wall_height, roof_type, roof_visual_options(x, z, width, depth, roof_type))
    place_porch(base_x, base_z, level, width, depth, door_side)
    if town_building and rng.randf() > 0.35:
        place_loot_chest(base_x, base_z, level, width, depth, door_side, rng, "town")
    elif not town_building and rng.randf() > 0.25:
        place_loot_chest(base_x, base_z, level, width, depth, door_side, rng, "cabin")
    if town_building and rng.randf() > 0.55:
        place_utility(base_x + 1, base_z + depth - 2, level, "bed")

func wall_visual_options(x: int, z: int, width: int, depth: int, dy: int, block_type: String, wall_type: String) -> Dictionary:
    var trim_key := "trimStone" if wall_type == "stoneBlock" else "trimWood"
    if block_type == "glass":
        var axis := "x" if (x == 0 or x == width - 1) else "z"
        var side := -1 if (x == 0 or z == 0) else 1
        if axis == "z":
            side = -1 if z == 0 else 1
        return {
            "accentRole": "windowFrame",
            "windowAxis": axis,
            "windowSide": side,
            "windowTrimMaterial": trim_key
        }
    var corner := (x == 0 or x == width - 1) and (z == 0 or z == depth - 1)
    if corner and dy <= 2:
        return {
            "accentRole": "cornerTimber",
            "cornerX": -1 if x == 0 else 1,
            "cornerZ": -1 if z == 0 else 1,
            "cornerTrimMaterial": trim_key
        }
    return {}

func roof_visual_options(x: int, z: int, width: int, depth: int, roof_type: String) -> Dictionary:
    var axis := "x" if width >= depth else "z"
    var cross_value := z if axis == "x" else x
    var cross_min := -1
    var cross_max := depth if axis == "x" else width
    var center := float(cross_min + cross_max) * 0.5
    var distance_to_center := absf(float(cross_value) - center)
    var role := "ridge" if distance_to_center <= 0.52 else "slope"
    var side := -1 if float(cross_value) < center else 1
    var edge_x := 0
    var edge_z := 0
    if x == -1:
        edge_x = -1
    elif x == width:
        edge_x = 1
    if z == -1:
        edge_z = -1
    elif z == depth:
        edge_z = 1
    if edge_x != 0 or edge_z != 0:
        role = "eave" if role != "ridge" else role
    var options := {
        "roofRole": role,
        "roofAxis": axis,
        "roofSide": side,
        "roofMaterial": "roofStone" if roof_type == "stoneBlock" else "roofWood",
        "roofTrimMaterial": "trimStone" if roof_type == "stoneBlock" else "trimWood",
        "roofEdgeX": edge_x,
        "roofEdgeZ": edge_z
    }
    var chimney_x: int = clampi(width - 2, 1, width - 2)
    var chimney_z: int = clampi(2, 1, depth - 2)
    if x == chimney_x and z == chimney_z:
        options["roofAccent"] = "chimney"
    return options

func camp_fence_options(base_options: Dictionary, axis: String) -> Dictionary:
    var options := base_options.duplicate()
    options["accentRole"] = "fencePost"
    options["fenceAxis"] = axis
    options["fenceTrimMaterial"] = "trimWood"
    return options

func build_ruin(base_x: int, base_z: int, level: float, width: int, depth: int, rng: RandomNumberGenerator) -> void:
    generated_ruin_count += 1
    var cache_key := "%s:ruin:%d,%d" % [main.seed_text, base_x, base_z]
    var tier_options := { "generatedTier": "ruin", "cacheKey": cache_key }
    var wall_height := rng.randi_range(2, 5)
    reserve_structure_terrain_footprint(base_x, base_z, level, width, depth, maxi(2, wall_height - 1), "ruin", "stone")
    for x in range(width):
        for z in range(depth):
            var edge := x == 0 or z == 0 or x == width - 1 or z == depth - 1
            if not edge:
                continue
            var corner := (x == 0 or x == width - 1) and (z == 0 or z == depth - 1)
            if rng.randf() < (0.14 if corner else 0.42):
                continue
            var height := clampi(1 + rng.randi_range(0, wall_height), 1, wall_height)
            for dy in range(height):
                place_structure_block(base_x + x, base_z + z, level, dy, "stoneBlock", tier_options)
    place_loot_chest(base_x, base_z, level, width, depth, -1, rng, "ruin", cache_key)
    for i in range(rng.randi_range(3, 6)):
        var rubble_x := base_x + rng.randi_range(1, width - 2)
        var rubble_z := base_z + rng.randi_range(1, depth - 2)
        place_structure_block(rubble_x, rubble_z, level, 0, "stoneBlock", tier_options)

func build_camp(base_x: int, base_z: int, level: float, width: int, depth: int, rng: RandomNumberGenerator) -> void:
    generated_camp_count += 1
    var cache_key := "%s:camp:%d,%d" % [main.seed_text, base_x, base_z]
    var tier_options := { "generatedTier": "camp", "cacheKey": cache_key }
    var center_x := int(width / 2)
    var center_z := int(depth / 2)
    reserve_structure_terrain_footprint(base_x, base_z, level, width, depth, 2, "camp", "dirt")
    for x in range(width):
        for z in range(depth):
            var offset := Vector2(float(x - center_x), float(z - center_z))
            if offset.length() <= 4.2 or x == center_x or z == center_z or rng.randf() > 0.72:
                place_path(base_x + x, base_z + z, level, tier_options)
    for z in range(-5, 0):
        for lane in range(-1, 2):
            place_path(base_x + center_x + lane, base_z + z, level, tier_options)
    place_utility(base_x + center_x, base_z + center_z, level, "campfire", tier_options)
    place_utility(base_x + max(1, center_x - 3), base_z + max(1, center_z - 2), level, "chest", {
        "storageSlots": loot.make_loot_slots(rng, "camp"),
        "generatedTier": "camp",
        "cacheKey": cache_key
    })
    var torch_cells := [
        Vector2i(1, 1),
        Vector2i(width - 2, 1),
        Vector2i(1, depth - 2),
        Vector2i(width - 2, depth - 2)
    ]
    for cell in torch_cells:
        place_utility(base_x + cell.x, base_z + cell.y, level, "torch", tier_options)
    for x in range(1, width - 1):
        if x % 3 == 0:
            place_structure_block(base_x + x, base_z, level, 0, "woodBlock", camp_fence_options(tier_options, "x"))
            place_structure_block(base_x + x, base_z + depth - 1, level, 0, "woodBlock", camp_fence_options(tier_options, "x"))
    for z in range(1, depth - 1):
        if z % 3 == 1:
            place_structure_block(base_x, base_z + z, level, 0, "woodBlock", camp_fence_options(tier_options, "z"))
            place_structure_block(base_x + width - 1, base_z + z, level, 0, "woodBlock", camp_fence_options(tier_options, "z"))
    var trap_cells := [
        Vector2i(center_x - 1, -2),
        Vector2i(center_x + 1, -2),
        Vector2i(1, center_z),
        Vector2i(width - 2, center_z)
    ]
    for cell in trap_cells:
        place_utility(base_x + cell.x, base_z + cell.y, level, "spikeTrap", tier_options)

func build_mine(base_x: int, base_z: int, level: float, width: int, depth: int, rng: RandomNumberGenerator) -> void:
    generated_mine_count += 1
    var cache_key := "%s:mine:%d,%d" % [main.seed_text, base_x, base_z]
    var tier_options := { "generatedTier": "mine", "cacheKey": cache_key }
    var center_x := int(width / 2)
    reserve_structure_terrain_footprint(base_x, base_z, level, width, depth, 4, "mine", "stone")
    for z in range(depth):
        for x in range(1, width - 1):
            if x == 1 or x == width - 2 or z % 2 == 0:
                place_path(base_x + x, base_z + z, level, tier_options)
    for z in range(-5, 0):
        for lane in range(-1, 2):
            place_path(base_x + center_x + lane, base_z + z, level, tier_options)
    for torch_offset in [Vector2i(center_x - 2, -1), Vector2i(center_x + 2, -1), Vector2i(1, 2), Vector2i(width - 2, 2)]:
        place_structure_block(base_x + torch_offset.x, base_z + torch_offset.y, level, 0, "torch", tier_options)
    for z in range(2, depth):
        for x in [0, width - 1]:
            place_structure_block(base_x + x, base_z + z, level, 0, "stoneBlock", tier_options)
            if z > 4 and z < depth - 1 and rng.randf() > 0.42:
                place_structure_block(base_x + x, base_z + z, level, 1, mine_vein_type(rng), tier_options)
            elif z % 3 == 0:
                place_structure_block(base_x + x, base_z + z, level, 1, "stoneBlock", tier_options)
    for x in range(width):
        place_structure_block(base_x + x, base_z + depth - 1, level, 0, "stoneBlock", tier_options)
        if x > 1 and x < width - 2:
            place_structure_block(base_x + x, base_z + depth - 1, level, 1, mine_vein_type(rng), tier_options)
            if rng.randf() > 0.62:
                place_structure_block(base_x + x, base_z + depth - 1, level, 2, mine_vein_type(rng), tier_options)
        else:
            place_structure_block(base_x + x, base_z + depth - 1, level, 1, "stoneBlock", tier_options)
    for z in [2, 6, depth - 3]:
        for x in [2, width - 3]:
            for dy in range(3):
                place_structure_block(base_x + x, base_z + z, level, dy, "woodBlock", tier_options)
            place_structure_block(base_x + x, base_z + z + 1, level, 0, "torch", tier_options)
        for x in range(2, width - 2):
            place_structure_block(base_x + x, base_z + z, level, 3, "woodBlock", tier_options)
    place_utility(base_x + center_x, base_z + 3, level, "chest", {
        "storageSlots": loot.make_loot_slots(rng, "mine"),
        "generatedTier": "mine",
        "cacheKey": cache_key
    })

func build_shrine(base_x: int, base_z: int, level: float, width: int, depth: int, rng: RandomNumberGenerator) -> void:
    generated_shrine_count += 1
    var cache_key := "%s:shrine:%d,%d" % [main.seed_text, base_x, base_z]
    var tier_options := { "generatedTier": "shrine", "cacheKey": cache_key }
    var center_x := int(width / 2)
    var center_z := int(depth / 2)
    reserve_structure_terrain_footprint(base_x, base_z, level, width, depth, 5, "shrine", "stone")
    for x in range(width):
        for z in range(depth):
            place_path(base_x + x, base_z + z, level, tier_options)
    for xz in [
        Vector2i(1, 1),
        Vector2i(width - 2, 1),
        Vector2i(1, depth - 2),
        Vector2i(width - 2, depth - 2)
    ]:
        for dy in range(5):
            place_structure_block(base_x + xz.x, base_z + xz.y, level, dy, "stoneBlock", tier_options)
    for x in range(1, width - 1):
        place_structure_block(base_x + x, base_z + 1, level, 5, "stoneBlock", tier_options)
        place_structure_block(base_x + x, base_z + depth - 2, level, 5, "stoneBlock", tier_options)
    for z in range(1, depth - 1):
        place_structure_block(base_x + 1, base_z + z, level, 5, "stoneBlock", tier_options)
        place_structure_block(base_x + width - 2, base_z + z, level, 5, "stoneBlock", tier_options)
    place_structure_block(base_x + center_x, base_z + center_z, level, 0, "stoneBlock", tier_options)
    place_structure_block(base_x + center_x, base_z + center_z, level, 2, "glass", tier_options)
    place_structure_block(base_x + center_x, base_z + center_z, level, 3, "glass", tier_options)
    for offset in [Vector2i(0, -3), Vector2i(3, 0), Vector2i(0, 3), Vector2i(-3, 0)]:
        place_structure_block(base_x + center_x + offset.x, base_z + center_z + offset.y, level, 1, "torch", tier_options)
    place_utility(base_x + center_x, base_z + center_z + 2, level, "chest", {
        "storageSlots": loot.make_loot_slots(rng, "shrine"),
        "generatedTier": "shrine",
        "cacheKey": cache_key
    })

func mine_vein_type(rng: RandomNumberGenerator) -> String:
    return "ironVein" if rng.randf() > 0.76 else "copperVein"

func place_loot_chest(base_x: int, base_z: int, level: float, width: int, depth: int, door_side: int, rng: RandomNumberGenerator, tier: String, cache_key: String = "") -> bool:
    if width < 4 or depth < 4:
        return false
    var cell := loot_chest_cell(width, depth, door_side, rng)
    var key := cache_key
    if key == "":
        key = "%s:%s-cache:%d,%d" % [main.seed_text, tier, base_x + int(cell.get("x", 0)), base_z + int(cell.get("z", 0))]
    return place_utility(base_x + int(cell.get("x", 0)), base_z + int(cell.get("z", 0)), level, "chest", {
        "storageSlots": loot.make_loot_slots(rng, tier),
        "generatedTier": tier,
        "cacheKey": key
    }) != null

func loot_chest_cell(width: int, depth: int, door_side: int, rng: RandomNumberGenerator) -> Dictionary:
    var side_x := 1 if rng.randf() < 0.5 else width - 2
    var side_z := 1 if rng.randf() < 0.5 else depth - 2
    if door_side == 0:
        return { "x": side_x, "z": depth - 2 }
    if door_side == 1:
        return { "x": 1, "z": side_z }
    if door_side == 2:
        return { "x": side_x, "z": 1 }
    if door_side == 3:
        return { "x": width - 2, "z": side_z }
    return { "x": side_x, "z": side_z }

func flat_level_for_footprint(base_x: int, base_z: int, width: int, depth: int) -> float:
    var samples := []
    for x in range(base_x, base_x + width):
        var near_sample := terrain_surface_sample_at_cell(x, base_z)
        var far_sample := terrain_surface_sample_at_cell(x, base_z + depth - 1)
        if not bool(near_sample.get("found", false)) or not bool(far_sample.get("found", false)):
            return NAN
        samples.append(float(near_sample.get("height", 0.0)))
        samples.append(float(far_sample.get("height", 0.0)))
    for z in range(base_z, base_z + depth):
        var left_sample := terrain_surface_sample_at_cell(base_x, z)
        var right_sample := terrain_surface_sample_at_cell(base_x + width - 1, z)
        if not bool(left_sample.get("found", false)) or not bool(right_sample.get("found", false)):
            return NAN
        samples.append(float(left_sample.get("height", 0.0)))
        samples.append(float(right_sample.get("height", 0.0)))
    var min_h := 999999.0
    var max_h := -999999.0
    for h in samples:
        min_h = min(min_h, float(h))
        max_h = max(max_h, float(h))
    if max_h - min_h > main.CELL * 0.65 or max_h <= main.WATER_LEVEL + 1.2:
        return NAN
    return (min_h + max_h) * 0.5

## Incremental terrain admission for ordinary standalone structures. The state
## retains only deterministic candidate facts and sampled extrema. Any edit in
## an intersecting terrain chunk restarts the proof before it can commit.
func advance_standalone_terrain_admission(region: Vector2i, candidate: Dictionary) -> Dictionary:
    if candidate.is_empty() or not candidate.get("baseCell") is Vector2i or not candidate.get("dimensions") is Vector2i:
        standalone_admission_states.erase(region)
        return {"status":"failed","reason":"invalid_standalone_candidate"}
    var signature := standalone_admission_revision(candidate)
    var state: Dictionary = standalone_admission_states.get(region,{})
    if state.is_empty() or state.get("candidate",{})!=candidate or state.get("revision",[])!=signature:
        state={"candidate":candidate.duplicate(true),"revision":signature,"cells":standalone_admission_cells(candidate),
            "cursor":0,"minimum":INF,"maximum":-INF,"failed":false}
    var started:=Time.get_ticks_usec()
    var sampled:=0
    while int(state.cursor)<state.cells.size() and sampled<STANDALONE_ADMISSION_SAMPLES_PER_SLICE \
            and Time.get_ticks_usec()-started<STANDALONE_ADMISSION_BUDGET_USEC:
        var cell: Vector2i=state.cells[int(state.cursor)]
        state.cursor=int(state.cursor)+1
        var sample:=terrain_surface_sample_at_cell(cell.x,cell.y)
        sampled+=1
        if not bool(sample.get("found",false)):
            state.failed=true
            break
        var height:=float(sample.get("height",0.0))
        state.minimum=minf(float(state.minimum),height)
        state.maximum=maxf(float(state.maximum),height)
    if bool(state.failed):
        standalone_admission_states.erase(region)
        return {"status":"rejected","reason":"standalone_surface_missing"}
    if int(state.cursor)<state.cells.size():
        standalone_admission_states[region]=state
        return {"status":"pending","reason":"standalone_terrain_admission_sampling",
            "sampled":state.cursor,"total":state.cells.size()}
    if standalone_admission_revision(candidate)!=state.revision:
        standalone_admission_states.erase(region)
        return {"status":"pending","reason":"standalone_terrain_admission_revision_changed"}
    standalone_admission_states.erase(region)
    var minimum:=float(state.minimum)
    var maximum:=float(state.maximum)
    if maximum-minimum>main.CELL*0.65 or maximum<=main.WATER_LEVEL+1.2:
        return {"status":"rejected","reason":"standalone_surface_unsuitable"}
    return {"status":"ready","level":(minimum+maximum)*0.5,"sampleCount":state.cells.size(),"revision":signature}


func standalone_admission_cells(candidate: Dictionary) -> Array[Vector2i]:
    var base: Vector2i=candidate.baseCell
    var dimensions: Vector2i=candidate.dimensions
    var unique: Dictionary={}
    for x: int in range(base.x,base.x+dimensions.x):
        unique[Vector2i(x,base.y)]=true
        unique[Vector2i(x,base.y+dimensions.y-1)]=true
    for z: int in range(base.y,base.y+dimensions.y):
        unique[Vector2i(base.x,z)]=true
        unique[Vector2i(base.x+dimensions.x-1,z)]=true
    var cells: Array[Vector2i]=[]
    for cell: Vector2i in unique: cells.append(cell)
    cells.sort_custom(func(a: Vector2i,b: Vector2i): return a.y<b.y if a.y!=b.y else a.x<b.x)
    return cells


func standalone_admission_revision(candidate: Dictionary) -> Array:
    var world=main.get("world_generation_system") if is_instance_valid(main) else null
    var chunk_size:=int(main.CHUNK_SIZE) if is_instance_valid(main) else 1
    if chunk_size<=0: chunk_size=1
    var base: Vector2i=candidate.baseCell
    var dimensions: Vector2i=candidate.dimensions
    var low:=Vector2i(floori(float(base.x)/chunk_size),floori(float(base.y)/chunk_size))
    var high:=Vector2i(floori(float(base.x+dimensions.x-1)/chunk_size),floori(float(base.y+dimensions.y-1)/chunk_size))
    var signature: Array=[String(main.seed_text) if is_instance_valid(main) else "",regional_source_generation,
        world.get_instance_id() if is_instance_valid(world) else 0]
    for z: int in range(low.y,high.y+1):
        for x: int in range(low.x,high.x+1):
            var key:=Vector2i(x,z)
            signature.append([key,int(world.call("terrain_volume_chunk_revision",key,chunk_size)) \
                if is_instance_valid(world) and world.has_method("terrain_volume_chunk_revision") else 0])
    return signature

func place_structure_block(cell_x: int, cell_z: int, level: float, dy: int, block_type: String, extra_options: Dictionary = {}) -> void:
    if defer_structure_ops:
        enqueue_structure_op({
            "type": "block",
            "cellX": cell_x,
            "cellZ": cell_z,
            "level": level,
            "dy": dy,
            "blockType": block_type,
            "options": extra_options.duplicate(true)
        })
        return
    var world_y: float = level + main.CELL * 0.48 + float(dy) * main.CELL + float(extra_options.get("worldYOffset", 0.0))
    var cell_y: int = floori(world_y / main.CELL) + 1
    var options := {
        "generated": true,
        "world_y": world_y,
        "structureDy": dy,
        "structureLevel": level
    }
    for key in extra_options.keys():
        options[key] = extra_options[key]
    var cell:=Vector3i(cell_x, cell_y, cell_z)
    if active_structure_visual_source_id!="": options["generatedVisualSourceId"]=active_structure_visual_source_id
    var block = main.create_block(cell, block_type, options)
    _record_ordinary_visual_block(cell,block_type,block)

func place_path(cell_x: int, cell_z: int, level: float, extra_options: Dictionary = {}) -> void:
    if defer_structure_ops:
        enqueue_structure_op({
            "type": "path",
            "cellX": cell_x,
            "cellZ": cell_z,
            "level": level,
            "options": extra_options.duplicate(true)
        })
        return
    var cell_y: int = roundi(level / main.CELL)
    var options := {
        "generated": true,
        "world_y": level + main.CELL * 0.024
    }
    for key in extra_options.keys():
        options[key] = extra_options[key]
    var cell:=Vector3i(cell_x, cell_y, cell_z)
    if active_structure_visual_source_id!="": options["generatedVisualSourceId"]=active_structure_visual_source_id
    var block = main.create_block(cell, "cobblestonePath", options)
    _record_ordinary_visual_block(cell,"cobblestonePath",block)
    if block:
        generated_path_count += 1

func place_utility(cell_x: int, cell_z: int, level: float, block_type: String, extra_options: Dictionary = {}) -> StaticBody3D:
    if defer_structure_ops:
        enqueue_structure_op({
            "type": "utility",
            "cellX": cell_x,
            "cellZ": cell_z,
            "level": level,
            "blockType": block_type,
            "options": extra_options.duplicate(true)
        })
        return null
    var world_y: float = level + main.CELL * 0.48
    var cell_y: int = floori(world_y / main.CELL) + 1
    var options := {
        "generated": true,
        "world_y": world_y
    }
    for key in extra_options.keys():
        options[key] = extra_options[key]
    var cell:=Vector3i(cell_x, cell_y, cell_z)
    if active_structure_visual_source_id!="": options["generatedVisualSourceId"]=active_structure_visual_source_id
    var block = main.create_block(cell, block_type, options)
    _record_ordinary_visual_block(cell,block_type,block)
    if block:
        generated_utility_count += 1
    return block

func place_door(cell_x: int, cell_z: int, level: float, side: int, secondary: bool, door_policy := "private_home") -> void:
    if defer_structure_ops:
        enqueue_structure_op({
            "type": "door",
            "cellX": cell_x,
            "cellZ": cell_z,
            "level": level,
            "side": side,
            "secondary": secondary,
            "doorPolicy": door_policy
        })
        return
    var world_y: float = level + main.CELL * 0.48
    var cell_y: int = floori(world_y / main.CELL) + 1
    var facing: float = StructureDoorRulesScript.door_facing(side)
    var group_x := cell_x
    var group_z := cell_z
    if secondary:
        if side == 0 or side == 2:
            group_x -= 1
        elif side == 1 or side == 3:
            group_z -= 1
    var group_id := "door-group:%d,%d,%d:%d" % [group_x, cell_y, group_z, side]
    var cell:=Vector3i(cell_x, cell_y, cell_z)
    var block = main.create_block(cell, "door", {
        "generated": true,
        "generatedVisualSourceId": active_structure_visual_source_id,
        "world_y": world_y,
        "facing": facing,
        "secondary": secondary,
        "doorSide": side,
        "doorLeafIndex": 1 if secondary else 0,
        "doorGroupId": group_id,
        "doorPortalId": "door:%s" % group_id,
        "doorPublicAccess": true,
        "doorPolicy": door_policy,
        "door": true,
        "accentRole": "doorFrame",
        "doorTrimMaterial": "trimWood"
    })
    _record_ordinary_visual_block(cell,"door",block)
    if block:
        generated_door_count += 1

func place_porch(base_x: int, base_z: int, level: float, width: int, depth: int, side: int) -> void:
    var doors := StructureDoorRulesScript.door_cells(width, depth, side)
    for entry in doors:
        var x := base_x + int(entry["x"])
        var z := base_z + int(entry["z"])
        if side == 0:
            place_path(x, z + 1, level)
        elif side == 2:
            place_path(x, z - 1, level)
        elif side == 1:
            place_path(x + 1, z, level)
        else:
            place_path(x - 1, z, level)

func counts() -> Dictionary:
    return {
        "towns": generated_town_count,
        "buildings": generated_building_count,
        "mines": generated_mine_count,
        "ruins": generated_ruin_count,
        "shrines": generated_shrine_count,
        "camps": generated_camp_count,
        "paths": generated_path_count,
        "doors": generated_door_count,
        "utilities": generated_utility_count
    }

