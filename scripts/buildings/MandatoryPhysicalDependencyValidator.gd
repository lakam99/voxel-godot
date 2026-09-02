extends RefCounted

## Final validation-only failure propagation. Local geometry/root/assembly
## checks remain authoritative; this does not prove grounding of a valid cycle.
## Malformed declarations are handled here, not by earlier blueprint parsing.
const REQUIRED_KEYS := ["physicalRequiredSupportPartIds", "physicalRequiredSeatPartIds", "physicalRequiredAnchorPartIds"]

static func apply(parts: Array, checks: Array, violations: Array) -> void:
	var part_counts: Dictionary = {}
	var check_counts: Dictionary = {}
	var invalid_targets: Dictionary = {}
	var malformed_owners: Dictionary = {}
	var dependencies: Dictionary = {}
	var newly_invalid: Dictionary = {}
	for part in parts:
		if part != null:
			part_counts[part.id] = int(part_counts.get(part.id, 0)) + 1
	for check in checks:
		var id: String = check.partId
		check_counts[id] = int(check_counts.get(id, 0)) + 1
		if not bool(check.passed):
			invalid_targets[id] = true
	for id in part_counts:
		if part_counts[id] != 1 or check_counts.get(id, 0) != 1:
			invalid_targets[id] = true
	for part in parts:
		if part == null:
			continue
		if not dependencies.has(part.id):
			dependencies[part.id] = {}
		for key in REQUIRED_KEYS:
			if not part.recipe.has(key):
				continue
			var values: Variant = part.recipe[key]
			if not values is Array:
				malformed_owners[part.id] = true
				continue
			for value in values:
				if not value is String or value.is_empty() or value != value.strip_edges():
					malformed_owners[part.id] = true
					continue
				dependencies[part.id][value] = true
				if part_counts.get(value, 0) != 1 or check_counts.get(value, 0) != 1:
					invalid_targets[value] = true
	var dependents: Dictionary = {}
	for owner in dependencies:
		for dependency in dependencies[owner]:
			if not dependents.has(dependency):
				dependents[dependency] = []
			dependents[dependency].append(owner)
	for owner in malformed_owners:
		invalid_targets[owner] = true
		newly_invalid[owner] = true
	# Each invalid target is enqueued once; each required edge is visited once.
	# An ambiguous target invalidates consumers, without arbitrarily selecting
	# one duplicate as its authoritative physical record.
	var queue: Array = invalid_targets.keys()
	var cursor := 0
	while cursor < queue.size():
		var failed_id = queue[cursor]
		cursor += 1
		for owner in dependents.get(failed_id, []):
			newly_invalid[owner] = true
			if not invalid_targets.has(owner):
				invalid_targets[owner] = true
				queue.append(owner)
	# Keep check ordering and original local facts/reasons. Failure wording does
	# not depend on which failed branch reached a diamond or cycle first.
	for check in checks:
		if bool(check.passed) and newly_invalid.has(check.partId):
			check["passed"] = false
			check["hasValidRequiredDependencies"] = false
			var reason := "has an invalid required physical dependency declaration" if malformed_owners.has(check.partId) else "has a failed, missing or ambiguous required physical dependency"
			violations.append("%s %s" % [check.partId, reason])
