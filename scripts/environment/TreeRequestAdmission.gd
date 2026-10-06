extends RefCounted
class_name TreeRequestAdmission

## Catalog-bound upper bounds for procedural tree requests. This is an admission
## certificate, not a second tree dimension authority: valid dimensions still
## come from TreeRuntimeRequestBuilder and the current biome profile.

const ProducerDomainScript := preload("res://scripts/world/EcologyProducerDomain.gd")
const CERTIFICATE_SCHEMA := "tree-request-admission-certificate/v1"
const MAX_CERTIFICATE_CACHE_ENTRIES := 8

static var _certificate_cache: Dictionary = {}
static var _certificate_cache_order: Array[String] = []


static func certificate_for_snapshot(snapshot: Dictionary,
		copy_result := true) -> Dictionary:
	var content_identity := String(snapshot.get("contentIdentity", ""))
	var profiles_value: Variant = snapshot.get("profiles", null)
	if not bool(snapshot.get("ok", false)) or int(snapshot.get("schemaVersion", -1)) != 1 \
			or String(snapshot.get("fallbackId", "")) != "default" \
			or content_identity.length() != 64 or not profiles_value is Array:
		return {"status": "failed", "reason": "tree_profile_snapshot_not_ready"}
	var cached_value: Variant = _certificate_cache.get(content_identity, null)
	if cached_value is Dictionary:
		var cached: Dictionary = cached_value
		var cached_snapshot: Dictionary = cached.get("profileCatalogSnapshot", {})
		if cached_snapshot.get("profiles", null) == profiles_value:
			return cached.duplicate(true) if copy_result else cached
	var profile_value := {
		"ok": true,
		"schemaVersion": int(snapshot.get("schemaVersion", -1)),
		"fallbackId": String(snapshot.get("fallbackId", "")),
		"contentIdentity": content_identity,
		"profiles": (profiles_value as Array).duplicate(true)
	}
	var identity_text := JSON.stringify({"domain":"biome_environment_resolved_catalog",
		"schemaVersion":1, "fallbackId":"default", "profiles":profile_value.profiles})
	if _sha256(identity_text) != content_identity:
		return {"status":"failed", "reason":"tree_profile_snapshot_content_identity_mismatch"}
	var envelope := ProducerDomainScript.derive_tree_request_envelope(profile_value)
	if String(envelope.get("status", "")) != "ready":
		return {"status": String(envelope.get("status", "failed")),
			"reason": String(envelope.get("reason", "tree_request_envelope_unavailable"))}
	var certificate := {
		"schema": CERTIFICATE_SCHEMA,
		"status": "ready",
		"profileCatalogRevision": String(envelope.get("profileCatalogRevision", "")),
		"requestEnvelopeDigest": String(envelope.get("digest", "")),
		"maxVisualHeightMeters": float(envelope.get("maxVisualHeightMeters", 0.0)),
		"maxTrunkRadiusMeters": float(envelope.get("maxTrunkRadiusMeters", 0.0)),
		"maxCanopyRadiusMeters": float(envelope.get("maxCanopyRadiusMeters", 0.0)),
		"maxWindResponse": float(envelope.get("maxWindResponse", 0.0)),
		"profileBounds": (envelope.get("profileBounds", {}) as Dictionary).duplicate(true),
		"profileCatalogSnapshot": profile_value
	}
	certificate["digest"] = _digest(certificate)
	var frozen := _freeze_value(certificate) as Dictionary
	if not _certificate_cache.has(content_identity):
		_certificate_cache_order.append(content_identity)
	_certificate_cache[content_identity] = frozen
	while _certificate_cache_order.size() > MAX_CERTIFICATE_CACHE_ENTRIES:
		var retired: String = _certificate_cache_order.pop_front()
		_certificate_cache.erase(retired)
	return frozen.duplicate(true) if copy_result else frozen


static func attach_certificate(request: Dictionary, snapshot: Dictionary = {}) -> Dictionary:
	if snapshot.is_empty():
		return {}
	var certificate := certificate_for_snapshot(snapshot, false)
	if String(certificate.get("status", "")) != "ready":
		return {}
	var result := request.duplicate(true)
	result["treeAdmissionCertificate"] = certificate
	result["treeProducerCatalogRevision"] = String(certificate.profileCatalogRevision)
	result["treeProducerEnvelopeDigest"] = String(certificate.requestEnvelopeDigest)
	return result


static func validate_request(request: Dictionary, current_snapshot: Dictionary = {}) -> Dictionary:
	var certificate_value: Variant = request.get("treeAdmissionCertificate", null)
	if not certificate_value is Dictionary:
		return {"status": "failed", "reason": "tree_admission_certificate_missing"}
	var certificate: Dictionary = certificate_value
	if String(certificate.get("schema", "")) != CERTIFICATE_SCHEMA \
			or String(certificate.get("status", "")) != "ready":
		return {"status": "failed", "reason": "tree_admission_certificate_invalid"}
	var supplied_digest := String(certificate.get("digest", ""))
	if supplied_digest.length() != 64:
		return {"status": "failed", "reason": "tree_admission_certificate_digest_mismatch"}
	var snapshot_value: Variant = certificate.get("profileCatalogSnapshot", null)
	if not snapshot_value is Dictionary:
		return {"status": "failed", "reason": "tree_admission_profile_snapshot_missing"}
	var derived_certificate := certificate_for_snapshot(snapshot_value as Dictionary, false)
	if String(derived_certificate.get("status", "")) != "ready" \
			or String(derived_certificate.get("digest", "")) != supplied_digest \
			or certificate != derived_certificate:
		return {"status": "failed", "reason": "tree_admission_profile_snapshot_mismatch"}
	var catalog_revision := String(certificate.get("profileCatalogRevision", ""))
	var envelope_digest := String(certificate.get("requestEnvelopeDigest", ""))
	if catalog_revision.length() != 64 or envelope_digest.length() != 64 \
			or String(request.get("treeProducerCatalogRevision", "")) != catalog_revision \
			or String(request.get("treeProducerEnvelopeDigest", "")) != envelope_digest:
		return {"status": "failed", "reason": "tree_admission_certificate_provenance_mismatch"}
	var parameters_value: Variant = request.get("biomeParameters", {})
	if not parameters_value is Dictionary:
		return {"status": "failed", "reason": "tree_request_biome_parameters_invalid"}
	var parameters: Dictionary = parameters_value
	var height := float(request.get("visualHeight", NAN))
	var trunk := float(request.get("trunkRadius", NAN))
	var canopy := float(request.get("canopyRadius", NAN))
	var wind_response := float(parameters.get("windResponse", NAN))
	if not is_finite(height) or not is_finite(trunk) or not is_finite(canopy) \
			or not is_finite(wind_response) or height <= 0.0 or trunk <= 0.0 \
			or canopy <= 0.0 or wind_response < 0.0:
		return {"status": "failed", "reason": "tree_request_dimensions_invalid"}
	if height > float(certificate.get("maxVisualHeightMeters", -1.0)) \
			or trunk > float(certificate.get("maxTrunkRadiusMeters", -1.0)) \
			or canopy > float(certificate.get("maxCanopyRadiusMeters", -1.0)) \
			or wind_response > float(certificate.get("maxWindResponse", -1.0)):
		return {"status": "failed", "reason": "tree_request_outside_catalog_envelope"}
	var profile_snapshot: Dictionary = snapshot_value as Dictionary
	var requested_biome := String(request.get("biome", "default")).strip_edges().to_lower()
	var selected_profile := "default"
	for profile_value: Variant in profile_snapshot.get("profiles", []):
		if profile_value is Dictionary and String(profile_value.get("biomeId", "")) == requested_biome:
			selected_profile = requested_biome
			break
	var profile_bounds_value: Variant = (certificate.get("profileBounds", {}) as Dictionary).get(selected_profile, null)
	if not profile_bounds_value is Dictionary:
		return {"status": "failed", "reason": "tree_admission_profile_bounds_missing"}
	var profile_bounds: Dictionary = profile_bounds_value
	var architecture := String(request.get("architecture", ""))
	var architecture_bounds_value: Variant = (profile_bounds.get("architectures", {}) as Dictionary).get(architecture, null)
	if not architecture_bounds_value is Dictionary:
		return {"status": "failed", "reason": "tree_admission_architecture_not_in_profile"}
	var architecture_bounds: Dictionary = architecture_bounds_value
	if height > float(architecture_bounds.get("maxVisualHeightMeters", -1.0)) \
			or trunk > float(architecture_bounds.get("maxTrunkRadiusMeters", -1.0)) \
			or canopy > float(architecture_bounds.get("maxCanopyRadiusMeters", -1.0)) \
			or wind_response > float(profile_bounds.get("maxWindResponse", -1.0)):
		return {"status": "failed", "reason": "tree_request_outside_profile_envelope"}
	if not current_snapshot.is_empty():
		var current_certificate := certificate_for_snapshot(current_snapshot, false)
		if String(current_certificate.get("status", "")) != "ready" \
				or String(current_certificate.get("digest", "")) != supplied_digest \
				or current_certificate != derived_certificate:
			return {"status": "failed", "reason": "tree_admission_certificate_stale"}
	return {"status": "ready", "certificate": derived_certificate,
		"profileCatalogRevision": catalog_revision, "requestEnvelopeDigest": envelope_digest}


static func _sha256(value: String) -> String:
	var context := HashingContext.new()
	context.start(HashingContext.HASH_SHA256)
	context.update(value.to_utf8_buffer())
	return context.finish().hex_encode()


static func _freeze_value(value: Variant) -> Variant:
	if value is Dictionary:
		var frozen: Dictionary = {}
		for key_value: Variant in value.keys():
			frozen[key_value] = _freeze_value(value[key_value])
		frozen.make_read_only()
		return frozen
	if value is Array:
		var frozen: Array = []
		for item: Variant in value:
			frozen.append(_freeze_value(item))
		frozen.make_read_only()
		return frozen
	return value


static func _digest(value: Variant) -> String:
	var context := HashingContext.new()
	context.start(HashingContext.HASH_SHA256)
	context.update(JSON.stringify(value).to_utf8_buffer())
	return context.finish().hex_encode()
