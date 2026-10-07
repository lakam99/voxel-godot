#include "chunk_render_packet_backend.h"

#include <godot_cpp/classes/geometry_instance3d.hpp>
#include <godot_cpp/classes/hashing_context.hpp>
#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/core/object.hpp>
#include <godot_cpp/variant/array.hpp>
#include <godot_cpp/variant/callable.hpp>
#include <godot_cpp/variant/string_name.hpp>
#include <godot_cpp/variant/utility_functions.hpp>

#include <algorithm>
#include <cmath>
#include <limits>
#include <set>
#include <string>

using namespace godot;

namespace {
constexpr int64_t FLOAT_BYTES = 4;

bool tier_supported(const String &p_tier) {
	return p_tier == "silhouette" || p_tier == "structural" || p_tier == "detail" || p_tier == "horizon";
}

bool render_layer_supported(const String &p_layer) {
	return p_layer == "opaque" || p_layer == "cutout" || p_layer == "translucent";
}

int64_t packed_mesh_array_bytes(const Variant &p_value) {
	switch (p_value.get_type()) {
		case Variant::NIL: return 0;
		case Variant::PACKED_BYTE_ARRAY: { const PackedByteArray array = p_value; return static_cast<int64_t>(array.size()); }
		case Variant::PACKED_INT32_ARRAY: { const PackedInt32Array array = p_value; return static_cast<int64_t>(array.size()) * sizeof(int32_t); }
		case Variant::PACKED_INT64_ARRAY: { const PackedInt64Array array = p_value; return static_cast<int64_t>(array.size()) * sizeof(int64_t); }
		case Variant::PACKED_FLOAT32_ARRAY: { const PackedFloat32Array array = p_value; return static_cast<int64_t>(array.size()) * sizeof(float); }
		case Variant::PACKED_FLOAT64_ARRAY: { const PackedFloat64Array array = p_value; return static_cast<int64_t>(array.size()) * sizeof(double); }
		case Variant::PACKED_VECTOR2_ARRAY: { const PackedVector2Array array = p_value; return static_cast<int64_t>(array.size()) * sizeof(Vector2); }
		case Variant::PACKED_VECTOR3_ARRAY: { const PackedVector3Array array = p_value; return static_cast<int64_t>(array.size()) * sizeof(Vector3); }
		case Variant::PACKED_VECTOR4_ARRAY: { const PackedVector4Array array = p_value; return static_cast<int64_t>(array.size()) * sizeof(Vector4); }
		case Variant::PACKED_COLOR_ARRAY: { const PackedColorArray array = p_value; return static_cast<int64_t>(array.size()) * sizeof(Color); }
		default: return -1;
	}
}

int64_t mesh_surface_payload_bytes(const Ref<Mesh> &p_mesh) {
	if (p_mesh.is_null()) return -1;
	const int32_t surface_count = p_mesh->get_surface_count();
	if (surface_count < 1) return -1;
	int64_t total_bytes = 0;
	bool has_vertices = false;
	for (int32_t surface = 0; surface < surface_count; ++surface) {
		const Array arrays = p_mesh->surface_get_arrays(surface);
		if (arrays.size() <= Mesh::ARRAY_VERTEX) return -1;
		const Variant vertices = arrays[Mesh::ARRAY_VERTEX];
		if (vertices.get_type() != Variant::PACKED_VECTOR3_ARRAY || PackedVector3Array(vertices).is_empty()) return -1;
		has_vertices = true;
		for (int32_t index = 0; index < arrays.size(); ++index) {
			const int64_t bytes = packed_mesh_array_bytes(arrays[index]);
			if (bytes < 0 || total_bytes > std::numeric_limits<int64_t>::max() - bytes) return -1;
			total_bytes += bytes;
		}
	}
	return has_vertices && total_bytes > 0 ? total_bytes : -1;
}

bool mesh_surface_fingerprint(const Ref<Mesh> &p_mesh, int64_t &r_payload_bytes,
		String &r_digest) {
	const int64_t bytes = mesh_surface_payload_bytes(p_mesh);
	if (bytes < 0) return false;
	Array fingerprint_payload;
	fingerprint_payload.push_back(String("chunk-render-mesh-content/v2"));
	fingerprint_payload.push_back(p_mesh->get_aabb());
	const int32_t surface_count = p_mesh->get_surface_count();
	fingerprint_payload.push_back(surface_count);
	for (int32_t surface = 0; surface < surface_count; ++surface) {
		fingerprint_payload.push_back(surface);
		fingerprint_payload.push_back(p_mesh->is_class("PrimitiveMesh")
				? p_mesh->get("primitive_type")
				: p_mesh->call("surface_get_primitive_type", surface));
		fingerprint_payload.push_back(p_mesh->surface_get_arrays(surface));
	}
	const PackedByteArray payload_bytes = UtilityFunctions::var_to_bytes(fingerprint_payload);
	Ref<HashingContext> context;
	context.instantiate();
	if (context->start(HashingContext::HASH_SHA256) != OK || context->update(payload_bytes) != OK) return false;
	r_payload_bytes = bytes;
	r_digest = context->finish().hex_encode();
	return r_digest.length() == 64;
}

bool transform_finite(const Transform3D &p_transform) {
	const Basis basis = p_transform.get_basis();
	const Vector3 columns[] = {basis.get_column(0), basis.get_column(1), basis.get_column(2), p_transform.get_origin()};
	for (const Vector3 &column : columns) {
		if (!std::isfinite(column.x) || !std::isfinite(column.y) || !std::isfinite(column.z)) return false;
	}
	return true;
}

bool sha256_hex(const String &p_value) {
	if (p_value.length() != 64) return false;
	for (int64_t index = 0; index < p_value.length(); ++index) {
		const char32_t ch = p_value[index];
		if (!((ch >= U'0' && ch <= U'9') || (ch >= U'a' && ch <= U'f'))) return false;
	}
	return true;
}
}

void ChunkRenderPacketBackend::_bind_methods() {
	ClassDB::bind_method(D_METHOD("declare_attachment_manifest", "source_id", "generation", "members", "manifest_digest"), &ChunkRenderPacketBackend::declare_attachment_manifest);
	ClassDB::bind_method(D_METHOD("register_packet_attachment", "source_id", "generation", "key", "parent", "body", "neutral_parent_world", "motion", "legacy_visuals"), &ChunkRenderPacketBackend::register_packet_attachment);
	ClassDB::bind_method(D_METHOD("register_borrowed_presentation", "source_id", "generation", "key", "member_source_id", "source_part_id", "member_id", "mount", "parent", "body", "neutral_parent_world", "mount_local_transform", "motion", "intended_visible", "legacy_visuals"), &ChunkRenderPacketBackend::register_borrowed_presentation, DEFVAL(Array()));
	ClassDB::bind_method(D_METHOD("legacy_visual_state", "visual_id"), &ChunkRenderPacketBackend::legacy_visual_state);
	ClassDB::bind_method(D_METHOD("restore_legacy_for_visual", "visual_id"), &ChunkRenderPacketBackend::restore_legacy_for_visual);
	ClassDB::bind_method(D_METHOD("settle_attachment_owner_loss", "source_id", "generation", "token"), &ChunkRenderPacketBackend::settle_attachment_owner_loss);
	ClassDB::bind_method(D_METHOD("settle_presentation_cancellation", "source_id", "generation", "token", "withdrawal_requested"), &ChunkRenderPacketBackend::settle_presentation_cancellation, DEFVAL(false));
	ClassDB::bind_method(D_METHOD("append_batch_in_attachment", "source_id", "generation", "batch_id", "mesh", "expected_mesh_content_digest", "material", "buffer", "bounds", "render_tier", "cast_shadows", "visibility_range", "fade_margin", "render_layer", "attachment_key", "intended_visible"), &ChunkRenderPacketBackend::append_batch_in_attachment, DEFVAL(true));
	ClassDB::bind_method(D_METHOD("begin_packet", "source_id", "owner_cell", "generation", "source_revision", "packet_digest", "local_to_chunk", "expected_batch_count", "expected_instance_count"), &ChunkRenderPacketBackend::begin_packet);
	ClassDB::bind_method(D_METHOD("begin_packet_with_layers", "source_id", "owner_cell", "generation", "source_revision", "packet_digest", "local_to_chunk", "expected_batch_count", "expected_instance_count", "expected_layers"), &ChunkRenderPacketBackend::begin_packet_with_layers);
	ClassDB::bind_method(D_METHOD("append_batch", "source_id", "generation", "batch_id", "mesh", "expected_mesh_content_digest", "material", "buffer", "bounds", "render_tier", "cast_shadows", "visibility_range", "fade_margin"), &ChunkRenderPacketBackend::append_batch);
	ClassDB::bind_method(D_METHOD("append_batch_in_layer", "source_id", "generation", "batch_id", "mesh", "expected_mesh_content_digest", "material", "buffer", "bounds", "render_tier", "cast_shadows", "visibility_range", "fade_margin", "render_layer", "intended_visible"), &ChunkRenderPacketBackend::append_batch_in_layer, DEFVAL(true));
	ClassDB::bind_method(D_METHOD("advance_packet", "source_id", "generation", "max_units"), &ChunkRenderPacketBackend::advance_packet, DEFVAL(1));
	ClassDB::bind_method(D_METHOD("commit_packet", "source_id", "generation", "await_frame_ack"), &ChunkRenderPacketBackend::commit_packet, DEFVAL(false));
	ClassDB::bind_method(D_METHOD("pending_presentation_snapshot", "source_id"), &ChunkRenderPacketBackend::pending_presentation_snapshot);
	ClassDB::bind_method(D_METHOD("finalize_presentation", "source_id", "generation", "token"), &ChunkRenderPacketBackend::finalize_presentation);
	ClassDB::bind_method(D_METHOD("rollback_presentation", "source_id", "generation", "token"), &ChunkRenderPacketBackend::rollback_presentation);
	ClassDB::bind_method(D_METHOD("abort_packet", "source_id", "generation"), &ChunkRenderPacketBackend::abort_packet);
	ClassDB::bind_method(D_METHOD("release_packet", "source_id", "generation"), &ChunkRenderPacketBackend::release_packet);
	ClassDB::bind_method(D_METHOD("installed_snapshot", "source_id"), &ChunkRenderPacketBackend::installed_snapshot);
	ClassDB::bind_method(D_METHOD("receipt_installed", "source_id", "generation", "source_revision", "packet_digest"), &ChunkRenderPacketBackend::receipt_installed);
	ClassDB::bind_method(D_METHOD("metrics"), &ChunkRenderPacketBackend::metrics);
}

Dictionary ChunkRenderPacketBackend::declare_attachment_manifest(const String &p_source_id,
		int64_t p_generation, const Array &p_members, const String &p_manifest_digest) {
	auto found = _staged.find(_key(p_source_id));
	if (found == _staged.end() || !_stage_matches(found->second, p_generation))
		return _status("failed", "staged_generation_missing");
	StagedPacket &packet = found->second;
	const bool empty_geometry_ready = packet.state == "ready" && packet.expected_batch_count == 0 && packet.expected_instance_count == 0 && packet.batches.empty();
	if ((packet.state != "collecting" && !empty_geometry_ready) || !packet.attachments.empty() || packet.attachment_manifest_declared)
		return _status("failed", "attachment_manifest_declaration_order_invalid");
	if (!sha256_hex(p_manifest_digest) || p_members.size() > MAX_ATTACHMENT_MANIFEST_MEMBERS)
		return _status("failed", "attachment_manifest_header_invalid");
	std::map<std::string, Dictionary> manifest;
	std::set<std::string> member_ids;
	std::string prior_key;
	Array canonical_members;
	for (int64_t index = 0; index < p_members.size(); ++index) {
		if (p_members[index].get_type() != Variant::DICTIONARY)
			return _status("failed", "attachment_manifest_member_invalid");
		const Dictionary row = p_members[index];
		if (row.size() != 12 || !row.has("producerSourceRevision") || !row.has("schema") || !row.has("sourceId") ||
				!row.has("sourcePartId") || !row.has("sourceRevision") || !row.has("attachmentKey") ||
				!row.has("presentationMemberId") || !row.has("ownershipKind") ||
				!row.has("intendedVisible") || !row.has("neutralParentToWorld") ||
				!row.has("sweptWorldBounds") || !row.has("motion"))
			return _status("failed", "attachment_manifest_member_fields_invalid");
		if (row.get("schema", Variant()).get_type() != Variant::STRING ||
				row.get("sourceId", Variant()).get_type() != Variant::STRING ||
				row.get("sourcePartId", Variant()).get_type() != Variant::STRING ||
				row.get("sourceRevision", Variant()).get_type() != Variant::STRING ||
				row.get("producerSourceRevision", Variant()).get_type() != Variant::STRING ||
				row.get("attachmentKey", Variant()).get_type() != Variant::STRING ||
				row.get("presentationMemberId", Variant()).get_type() != Variant::STRING ||
				row.get("ownershipKind", Variant()).get_type() != Variant::STRING)
			return _status("failed", "attachment_manifest_member_types_invalid");
		const String schema = row.get("schema", String());
		const String source_id = row.get("sourceId", String());
		const String key = row.get("attachmentKey", String());
		const String source_part_id = row.get("sourcePartId", String());
		const String member_id = row.get("presentationMemberId", String());
		const String ownership = row.get("ownershipKind", String());
		const String revision = row.get("sourceRevision", String());
		const String producer_revision = row.get("producerSourceRevision", String());
		const Variant visible_value = row.get("intendedVisible", Variant());
		const Variant neutral_value = row.get("neutralParentToWorld", Variant());
		const Variant swept_value = row.get("sweptWorldBounds", Variant());
		const Variant motion_value = row.get("motion", Variant());
		if (schema != "static-section-presentation-member/v2" || producer_revision.strip_edges().is_empty() || source_id.strip_edges().is_empty() ||
				key.strip_edges().is_empty() || source_part_id.strip_edges().is_empty() || member_id.strip_edges().is_empty() ||
				revision.strip_edges().is_empty() || neutral_value.get_type() != Variant::TRANSFORM3D ||
				swept_value.get_type() != Variant::AABB || motion_value.get_type() != Variant::DICTIONARY ||
				(ownership != "backend_owned_geometry" && ownership != "borrowed_presentation") ||
				visible_value.get_type() != Variant::BOOL)
			return _status("failed", "attachment_manifest_member_invalid");
		const Transform3D neutral = neutral_value;
		const AABB swept = swept_value;
		const Dictionary supplied_motion = motion_value;
		if (supplied_motion.size() != 4 || !supplied_motion.has("kind") ||
				!supplied_motion.has("closedParentToBody") || !supplied_motion.has("raiseOffset") ||
				!supplied_motion.has("swing") || supplied_motion.get("kind", Variant()).get_type() != Variant::STRING ||
				supplied_motion.get("closedParentToBody", Variant()).get_type() != Variant::TRANSFORM3D ||
				supplied_motion.get("raiseOffset", Variant()).get_type() != Variant::VECTOR3 ||
				supplied_motion.get("swing", Variant()).get_type() != Variant::FLOAT)
			return _status("failed", "attachment_manifest_motion_fields_invalid");
		const String motion_kind = supplied_motion.get("kind", String());
		const Transform3D closed_parent_to_body = supplied_motion.get("closedParentToBody", Transform3D());
		const Vector3 raise_offset = supplied_motion.get("raiseOffset", Vector3());
		const double swing = supplied_motion.get("swing", 0.0);
		Dictionary motion;
		motion["kind"] = motion_kind;
		motion["closedParentToBody"] = closed_parent_to_body;
		motion["raiseOffset"] = raise_offset;
		motion["swing"] = swing;
		motion.make_read_only();
		const Vector3 swept_end = swept.get_position() + swept.get_size();
		const bool motion_kind_valid = motion_kind == "static" || motion_kind == "swing" || motion_kind == "raise";
		const bool motion_values_valid = motion_kind == "static" ?
			(raise_offset == Vector3() && swing == 0.0) : motion_kind == "swing" ?
			(raise_offset == Vector3() && std::abs(swing) > 0.0 && std::abs(swing) <= 3.141592653589793) :
			(motion_kind == "raise" && swing == 0.0 && raise_offset.length_squared() > 0.000001);
		if (!transform_finite(neutral) || Math::is_zero_approx(neutral.basis.determinant()) ||
				!swept.get_position().is_finite() || !swept.get_size().is_finite() ||
				swept.get_size().x <= 0.0 || swept.get_size().y <= 0.0 || swept.get_size().z <= 0.0 ||
				!swept_end.is_finite() || !motion_kind_valid || !motion_values_valid ||
				!transform_finite(closed_parent_to_body) ||
				Math::is_zero_approx(closed_parent_to_body.basis.determinant()) ||
				!raise_offset.is_finite() || !std::isfinite(swing))
			return _status("failed", "attachment_manifest_spatial_contract_invalid");
		const std::string native_key = _key(key);
		const std::string native_member = _key(member_id);
		if ((index > 0 && native_key <= prior_key) || manifest.count(native_key) || member_ids.count(native_member))
			return _status("failed", "attachment_manifest_duplicate_identity");
		prior_key = native_key;
		Dictionary sealed;
		sealed["schema"] = schema;
		sealed["sourceId"] = source_id;
		sealed["sourcePartId"] = source_part_id;
		sealed["sourceRevision"] = revision;
		sealed["producerSourceRevision"] = producer_revision;
		sealed["attachmentKey"] = key;
		sealed["presentationMemberId"] = member_id;
		sealed["ownershipKind"] = ownership;
		sealed["intendedVisible"] = bool(visible_value);
		sealed["neutralParentToWorld"] = neutral;
		sealed["sweptWorldBounds"] = swept;
		sealed["motion"] = motion;
		sealed.make_read_only();
		manifest.emplace(native_key, sealed);
		member_ids.insert(native_member);
		canonical_members.push_back(sealed);
	}
	const PackedByteArray canonical_payload = UtilityFunctions::var_to_bytes(canonical_members);
	Ref<HashingContext> manifest_context;
	manifest_context.instantiate();
	if (manifest_context->start(HashingContext::HASH_SHA256) != OK ||
			manifest_context->update(canonical_payload) != OK ||
			manifest_context->finish().hex_encode() != p_manifest_digest)
		return _status("failed", "attachment_manifest_digest_mismatch");
	packet.expected_attachment_manifest = std::move(manifest);
	packet.attachment_manifest_digest = p_manifest_digest;
	packet.attachment_manifest_declared = true;
	Dictionary result = _status("manifest_declared");
	result["sourceId"] = p_source_id;
	result["generation"] = p_generation;
	result["memberCount"] = static_cast<int64_t>(packet.expected_attachment_manifest.size());
	result["manifestDigest"] = p_manifest_digest;
	return result;
}

bool ChunkRenderPacketBackend::_attachment_manifest_matches(const AttachmentRoots &p_roots,
		const std::map<std::string, Dictionary> &p_manifest) const {
	if (p_roots.size() != p_manifest.size()) return false;
	for (const auto &entry : p_manifest) {
		auto actual = p_roots.find(entry.first);
		if (actual == p_roots.end()) return false;
		const AttachmentRoot &root = actual->second;
		const Dictionary &expected = entry.second;
		const Dictionary expected_motion = expected.get("motion", Dictionary());
		if (String(expected.get("schema", "")) != "static-section-presentation-member/v2" ||
				root.ownership_kind != String(expected.get("ownershipKind", "")) ||
				root.member_source_id != String(expected.get("sourceId", "")) ||
				root.source_part_id != String(expected.get("sourcePartId", "")) ||
				root.presentation_member_id != String(expected.get("presentationMemberId", "")) ||
				root.motion_kind != String(expected_motion.get("kind", "")) ||
				root.intended_visible != bool(expected.get("intendedVisible", false)) ||
				root.source_revision != String(expected.get("sourceRevision", "")) ||
				root.producer_source_revision != String(expected.get("producerSourceRevision", "")) ||
				!root.neutral_parent_world.is_equal_approx(expected.get("neutralParentToWorld", Transform3D())) ||
				root.swept_bounds != AABB(expected.get("sweptWorldBounds", AABB())) ||
				!root.closed_parent_to_body.is_equal_approx(expected_motion.get("closedParentToBody", Transform3D())) ||
				!root.raise_offset.is_equal_approx(expected_motion.get("raiseOffset", Vector3())) ||
				!Math::is_equal_approx(root.swing, double(expected_motion.get("swing", 0.0)))) return false;
	}
	return true;
}

bool ChunkRenderPacketBackend::_borrowed_root_claimed_elsewhere(uint64_t p_root_id,
		const String &p_source_id) const {
	const auto matches = [p_root_id](const AttachmentRoots &roots) {
		for (const auto &entry : roots)
			if (entry.second.ownership_kind == "borrowed_presentation" && entry.second.root_id == p_root_id) return true;
		return false;
	};
	for (const auto &entry : _installed) if (entry.second.source_id != p_source_id && matches(entry.second.attachments)) return true;
	for (const auto &entry : _staged) if (entry.second.source_id != p_source_id && matches(entry.second.attachments)) return true;
	for (const auto &entry : _pending_presentations) {
		if (entry.second.replacement.source_id == p_source_id) continue;
		if (matches(entry.second.replacement.attachments) ||
				(entry.second.has_previous && matches(entry.second.previous.attachments))) return true;
	}
	return false;
}

bool ChunkRenderPacketBackend::_borrowed_root_active(uint64_t p_root_id) const {
	const auto matches = [p_root_id](const AttachmentRoots &roots) {
		for (const auto &entry : roots)
			if (entry.second.ownership_kind == "borrowed_presentation" && entry.second.root_id == p_root_id && entry.second.intended_visible) return true;
		return false;
	};
	for (const auto &entry : _installed) {
		if (_pending_presentations.count(entry.first)) continue;
		if (matches(entry.second.attachments)) return true;
	}
	for (const auto &entry : _pending_presentations) {
		const PendingPresentation &pending = entry.second;
		if (pending.replacement_active && matches(pending.replacement.attachments)) return true;
		if (pending.previous_active && pending.has_previous && matches(pending.previous.attachments)) return true;
	}
	return false;
}

bool ChunkRenderPacketBackend::_borrowed_root_has_presentation_role(uint64_t p_root_id) const {
	const auto matches = [p_root_id](const AttachmentRoots &roots) {
		for (const auto &entry : roots)
			if (entry.second.ownership_kind == "borrowed_presentation" && entry.second.root_id == p_root_id) return true;
		return false;
	};
	for (const auto &entry : _installed) if (matches(entry.second.attachments)) return true;
	for (const auto &entry : _pending_presentations) {
		if (matches(entry.second.replacement.attachments) ||
				(entry.second.has_previous && matches(entry.second.previous.attachments))) return true;
	}
	return false;
}

bool ChunkRenderPacketBackend::_borrowed_root_source_visibility(uint64_t p_root_id, bool &r_visible) const {
	const auto find = [p_root_id, &r_visible](const AttachmentRoots &roots) {
		for (const auto &entry : roots) {
			const AttachmentRoot &a = entry.second;
			if (a.ownership_kind != "borrowed_presentation" || a.root_id != p_root_id) continue;
			r_visible = a.borrowed_source_visible;
			return true;
		}
		return false;
	};
	for (const auto &entry : _installed) if (find(entry.second.attachments)) return true;
	for (const auto &entry : _pending_presentations) {
		if (find(entry.second.replacement.attachments) ||
				(entry.second.has_previous && find(entry.second.previous.attachments))) return true;
	}
	for (const auto &entry : _staged) if (find(entry.second.attachments)) return true;
	return false;
}

void ChunkRenderPacketBackend::_restore_borrowed_source_visibility(const AttachmentRoots &p_roots) {
	for (const auto &entry : p_roots) {
		const AttachmentRoot &a = entry.second;
		if (a.ownership_kind != "borrowed_presentation" || _borrowed_root_has_presentation_role(a.root_id)) continue;
		Node3D *root = _node3d_for_id(a.root_id);
		Node3D *body = _node3d_for_id(a.body_id);
		Node3D *parent = _node3d_for_id(a.parent_id);
		if (root && body && parent && !root->is_queued_for_deletion() && !body->is_queued_for_deletion() &&
				root->get_parent() == parent && (parent == body || body->is_ancestor_of(parent)) &&
				String(body->get_meta("section_attachment_source_revision", "")) == a.producer_source_revision &&
				int64_t(body->get_meta("section_attachment_publisher_instance_id", 0)) == a.publisher_id &&
				int64_t(body->get_meta("section_attachment_publication_epoch", -1)) == a.publication_epoch)
			root->set_visible(a.borrowed_source_visible);
	}
}

std::string ChunkRenderPacketBackend::_key(const String &p_source_id) {
	return p_source_id.utf8().get_data();
}

Dictionary ChunkRenderPacketBackend::_status(const String &p_status, const String &p_reason) const {
	Dictionary result;
	result["status"] = p_status;
	if (!p_reason.is_empty()) result["reason"] = p_reason;
	return result;
}

Node3D *ChunkRenderPacketBackend::_node3d_for_id(uint64_t p_object_id) const {
	return Object::cast_to<Node3D>(ObjectDB::get_instance(p_object_id));
}

int64_t ChunkRenderPacketBackend::_installed_payload_bytes() const {
	int64_t result = 0;
	for (const auto &entry : _installed) result += entry.second.payload_bytes;
	for (const auto &entry : _pending_presentations) result += entry.second.replacement.payload_bytes;
	return result;
}

bool ChunkRenderPacketBackend::_owner_cell_matches_parent(const Vector2i &p_owner_cell) const {
	if (get_parent() == nullptr) return false;
	const String parent_name = String(get_parent()->get_name());
	const PackedStringArray parts = parent_name.split("_");
	if (parts.size() != 3 || parts[0] != "Chunk") return false;
	const int64_t x = parts[1].to_int();
	const int64_t z = parts[2].to_int();
	return String::num_int64(x) == parts[1] && String::num_int64(z) == parts[2] &&
		x == p_owner_cell.x && z == p_owner_cell.y;
}

bool ChunkRenderPacketBackend::_stage_matches(const StagedPacket &p_packet, int64_t p_generation) const {
	return p_generation > 0 && p_packet.generation == p_generation && p_packet.source_id.length() > 0;
}

void ChunkRenderPacketBackend::_free_staging_root(StagedPacket &r_packet) {
	const int64_t attachment_bytes = _attachment_payload_bytes(r_packet.attachments);
	_retire_attachments(r_packet.attachments);
	r_packet.attachments.clear();
	_retire_root(r_packet.root_instance_id, r_packet.reserved_bytes - attachment_bytes);
	r_packet.root = nullptr;
	r_packet.root_instance_id = 0;
}

void ChunkRenderPacketBackend::_retire_root(uint64_t p_root_id, int64_t p_payload_bytes) {
	Node3D *root = _node3d_for_id(p_root_id);
	if (root == nullptr) return;
	if (_retiring_payload_by_root.count(p_root_id)) return;
	const int64_t retained_bytes = std::max<int64_t>(0, p_payload_bytes);
	_retiring_payload_by_root[p_root_id] = retained_bytes;
	_retiring_payload_bytes += retained_bytes;
	root->set_visible(false);
	Callable exiting = callable_mp(this, &ChunkRenderPacketBackend::_on_retired_root_exiting).bind(static_cast<int64_t>(p_root_id));
	if (!root->is_connected("tree_exiting", exiting)) root->connect("tree_exiting", exiting, Object::CONNECT_ONE_SHOT);
	root->queue_free();
	_retiring_roots++;
}

void ChunkRenderPacketBackend::_on_retired_root_exiting(uint64_t p_root_id) {
	_retiring_roots = std::max<int64_t>(0, _retiring_roots - 1);
	auto found = _retiring_payload_by_root.find(p_root_id);
	if (found != _retiring_payload_by_root.end()) {
		_retiring_payload_bytes = std::max<int64_t>(0, _retiring_payload_bytes - found->second);
		_retiring_payload_by_root.erase(found);
	}
}

void ChunkRenderPacketBackend::_release_stage(std::map<std::string, StagedPacket>::iterator p_it) {
	if (p_it == _staged.end()) return;
	_staged_payload_bytes = std::max<int64_t>(0, _staged_payload_bytes - p_it->second.reserved_bytes);
	_free_staging_root(p_it->second);
	_restore_legacy(p_it->second.suppressed_legacy);
	_staged.erase(p_it);
}

void ChunkRenderPacketBackend::_build_layer_receipts(StagedPacket &r_packet) const {
	r_packet.layer_receipts.clear();
	for (const StagedPacket::LayerManifestEntry &layer : r_packet.layers) {
		Dictionary layer_receipt;
		Array batch_ids;
		for (const Dictionary &batch_receipt : r_packet.batch_receipts) {
			if (String(batch_receipt.get("renderLayer", "")) == layer.layer) {
				batch_ids.push_back(batch_receipt.get("batchId", String()));
			}
		}
		layer_receipt["status"] = layer.expected_batch_count == 0 ? "empty" : "ready";
		layer_receipt["layer"] = layer.layer;
		layer_receipt["sourceId"] = r_packet.source_id;
		layer_receipt["generation"] = r_packet.generation;
		layer_receipt["sourceRevision"] = r_packet.source_revision;
		layer_receipt["packetDigest"] = r_packet.packet_digest;
		layer_receipt["expectedBatchCount"] = layer.expected_batch_count;
		layer_receipt["expectedInstanceCount"] = layer.expected_instance_count;
		layer_receipt["installedBatchCount"] = layer.accepted_batch_count;
		layer_receipt["installedInstanceCount"] = layer.accepted_instance_count;
		layer_receipt["batchIds"] = batch_ids;
		r_packet.layer_receipts.push_back(layer_receipt);
	}
}

Dictionary ChunkRenderPacketBackend::begin_packet(const String &p_source_id,
		const Vector2i &p_owner_cell, int64_t p_generation,
		const String &p_source_revision, const String &p_packet_digest,
		const Transform3D &p_local_to_chunk, int64_t p_expected_batch_count,
		int64_t p_expected_instance_count) {
	return _begin_packet(p_source_id, p_owner_cell, p_generation, p_source_revision,
		p_packet_digest, p_local_to_chunk, p_expected_batch_count,
		p_expected_instance_count, Array());
}

Dictionary ChunkRenderPacketBackend::begin_packet_with_layers(const String &p_source_id,
		const Vector2i &p_owner_cell, int64_t p_generation,
		const String &p_source_revision, const String &p_packet_digest,
		const Transform3D &p_local_to_chunk, int64_t p_expected_batch_count,
		int64_t p_expected_instance_count, const Array &p_expected_layers) {
	return _begin_packet(p_source_id, p_owner_cell, p_generation, p_source_revision,
		p_packet_digest, p_local_to_chunk, p_expected_batch_count,
		p_expected_instance_count, p_expected_layers);
}

Dictionary ChunkRenderPacketBackend::_begin_packet(const String &p_source_id,
		const Vector2i &p_owner_cell, int64_t p_generation,
		const String &p_source_revision, const String &p_packet_digest,
		const Transform3D &p_local_to_chunk, int64_t p_expected_batch_count,
		int64_t p_expected_instance_count, const Array &p_expected_layers) {
	if (_owner_loss_cancellations.count(_key(p_source_id)) || _owner_loss_cancellations.size() >= MAX_INSTALLED_PACKETS)
		return _status("backpressure", "owner_loss_cleanup_acknowledgement_pending");
	if (!_staged.count(_key(p_source_id)) && _staged.size() + _pending_presentations.size() +
			_owner_loss_cancellations.size() >= MAX_INSTALLED_PACKETS)
		return _status("backpressure", "presentation_cancellation_capacity_reserved");
	if (p_source_id.strip_edges().is_empty() || p_source_revision.strip_edges().is_empty() ||
			p_packet_digest.strip_edges().is_empty() || p_generation <= 0 ||
			p_expected_batch_count < 0 || p_expected_batch_count > MAX_PACKET_BATCHES ||
			p_expected_instance_count < 0 || p_expected_instance_count > MAX_PACKET_BATCHES * MAX_BATCH_INSTANCES ||
			((p_expected_batch_count == 0) != (p_expected_instance_count == 0)) ||
			!transform_finite(p_local_to_chunk) || !is_inside_tree() || !_owner_cell_matches_parent(p_owner_cell)) {
		return _status("failed", "invalid_packet_header_or_owner_cell");
	}
	const std::string key = _key(p_source_id);
	Array expected_layers = p_expected_layers;
	if (expected_layers.is_empty()) {
		Dictionary opaque;
		opaque["layer"] = "opaque";
		opaque["expectedBatchCount"] = p_expected_batch_count;
		opaque["expectedInstanceCount"] = p_expected_instance_count;
		expected_layers.push_back(opaque);
	}
	std::vector<StagedPacket::LayerManifestEntry> parsed_layers;
	int64_t expected_layer_batches = 0;
	int64_t expected_layer_instances = 0;
	for (int64_t index = 0; index < expected_layers.size(); ++index) {
		if (expected_layers[index].get_type() != Variant::DICTIONARY) return _status("failed", "invalid_packet_layer_manifest");
		const Dictionary layer_value = expected_layers[index];
		const String layer_name = layer_value.get("layer", String());
		const int64_t layer_batches = layer_value.get("expectedBatchCount", int64_t(-1));
		const int64_t layer_instances = layer_value.get("expectedInstanceCount", int64_t(-1));
		if (!render_layer_supported(layer_name) || layer_batches < 0 || layer_instances < 0 ||
				((layer_batches == 0) != (layer_instances == 0)) ||
				layer_batches > MAX_PACKET_BATCHES || layer_instances > MAX_PACKET_BATCHES * MAX_BATCH_INSTANCES) {
			return _status("failed", "invalid_packet_layer_manifest_entry");
		}
		for (const StagedPacket::LayerManifestEntry &existing : parsed_layers) {
			if (existing.layer == layer_name) return _status("failed", "duplicate_packet_render_layer");
		}
		StagedPacket::LayerManifestEntry entry;
		entry.layer = layer_name;
		entry.expected_batch_count = layer_batches;
		entry.expected_instance_count = layer_instances;
		parsed_layers.push_back(entry);
		expected_layer_batches += layer_batches;
		expected_layer_instances += layer_instances;
	}
	if (parsed_layers.empty() || expected_layer_batches != p_expected_batch_count ||
			expected_layer_instances != p_expected_instance_count) {
		return _status("failed", "packet_layer_manifest_count_mismatch");
	}
	auto staged = _staged.find(key);
	if (staged != _staged.end()) {
		const StagedPacket &current = staged->second;
		if (current.generation == p_generation && current.owner_cell == p_owner_cell &&
				current.source_revision == p_source_revision && current.packet_digest == p_packet_digest &&
				current.local_to_chunk.is_equal_approx(p_local_to_chunk) &&
				current.expected_batch_count == p_expected_batch_count &&
				current.expected_instance_count == p_expected_instance_count &&
				current.layers.size() == parsed_layers.size()) {
			bool manifest_matches = true;
			for (size_t index = 0; index < parsed_layers.size(); ++index) {
				const auto &expected = parsed_layers[index];
				const auto &actual = current.layers[index];
				manifest_matches &= expected.layer == actual.layer &&
					expected.expected_batch_count == actual.expected_batch_count &&
					expected.expected_instance_count == actual.expected_instance_count;
			}
			if (!manifest_matches) return _status("backpressure", "source_has_unresolved_staged_generation");
			const String status = current.state == "failed" ? "failed" : current.state == "ready" ? "ready_to_commit" : "ready_to_append";
			Dictionary result = _status(status, current.failure_reason);
			result["generation"] = current.generation;
			result["acceptedBatches"] = static_cast<int64_t>(current.batches.size());
			result["acceptedInstances"] = current.instance_count;
			return result;
		}
		return _status("backpressure", "source_has_unresolved_staged_generation");
	}
	auto installed = _installed.find(key);
	if (installed != _installed.end()) {
		if (installed->second.owner_cell != p_owner_cell) return _status("failed", "owner_cell_mismatch");
		if (p_generation <= installed->second.generation) return _status("failed", "stale_packet_generation");
	}
	StagedPacket packet;
	packet.source_id = p_source_id;
	packet.owner_cell = p_owner_cell;
	packet.generation = p_generation;
	packet.source_revision = p_source_revision;
	packet.packet_digest = p_packet_digest;
	packet.local_to_chunk = p_local_to_chunk;
	packet.expected_batch_count = p_expected_batch_count;
	packet.expected_instance_count = p_expected_instance_count;
	packet.layers = std::move(parsed_layers);
	packet.state = p_expected_batch_count == 0 && p_expected_instance_count == 0 ? "ready" : "collecting";
	if (packet.state == "ready") _build_layer_receipts(packet);
	packet.root = memnew(Node3D);
	packet.root->set_name(String("StagedPacket_") + p_source_id.validate_node_name() + "_" + String::num_int64(p_generation));
	packet.root->set_transform(p_local_to_chunk);
	packet.root->set_visible(false);
	packet.root->set_meta("packet_source_id", p_source_id);
	packet.root->set_meta("packet_backend_instance_id", static_cast<int64_t>(get_instance_id()));
	packet.root->set_meta("packet_owner_cell", p_owner_cell);
	packet.root->set_meta("packet_generation", p_generation);
	packet.root->set_meta("packet_source_revision", p_source_revision);
	packet.root->set_meta("packet_digest", p_packet_digest);
	add_child(packet.root);
	packet.root_instance_id = packet.root->get_instance_id();
	_staged.emplace(key, std::move(packet));
	Dictionary result = _status("ready_to_append");
	result["generation"] = p_generation;
	result["acceptedBatches"] = 0;
	result["acceptedInstances"] = 0;
	return result;
}

bool ChunkRenderPacketBackend::_attachments_valid(const AttachmentRoots &p_roots, bool p_visible, bool p_require_current) const {
	for (const auto &entry : p_roots) {
		const AttachmentRoot &a = entry.second;
		Node3D *root = _node3d_for_id(a.root_id), *parent = _node3d_for_id(a.parent_id), *body = _node3d_for_id(a.body_id);
		const bool borrowed = a.ownership_kind == "borrowed_presentation";
		if (!root || !parent || !body || !parent->is_inside_tree() || !body->is_inside_tree() ||
				root->is_queued_for_deletion() || parent->is_queued_for_deletion() || body->is_queued_for_deletion() ||
				root->get_parent() != parent || (parent != body && !body->is_ancestor_of(parent)) ||
				(!borrowed && (int64_t(root->get_meta("packet_backend_instance_id", 0)) != int64_t(get_instance_id()) ||
				String(root->get_meta("packet_source_id", "")) != a.packet_source_id ||
				int64_t(root->get_meta("packet_generation", 0)) != a.packet_generation)) ||
				(borrowed && (!root->has_meta("section_attachment_presentation_member_id") ||
				String(root->get_meta("section_attachment_presentation_member_id", "")) != a.presentation_member_id ||
				_borrowed_root_claimed_elsewhere(a.root_id, a.packet_source_id))) ||
				(p_require_current && (String(body->get_meta("section_attachment_source_revision", "")) != a.producer_source_revision ||
				int64_t(body->get_meta("section_attachment_publisher_instance_id", 0)) != a.publisher_id ||
				int64_t(body->get_meta("section_attachment_publication_epoch", -1)) != a.publication_epoch)) ||
				(!borrowed && root->is_visible() != (p_visible && a.intended_visible)) ||
				(borrowed && root->is_visible() != (_borrowed_root_has_presentation_role(a.root_id) ?
					_borrowed_root_active(a.root_id) : a.borrowed_source_visible)) ||
				!body->get_global_transform().is_equal_approx(a.body_world) ||
				!root->get_transform().is_equal_approx(a.local_transform) ||
				!_attachment_motion_valid(a, parent, body)) return false;
		for (const LegacyVisual &visual : a.legacy_visuals) if (!_legacy_valid(a, visual)) return false;
	}
	return true;
}

bool ChunkRenderPacketBackend::_attachment_motion_valid(const AttachmentRoot &a, Node3D *parent, Node3D *body) const {
	const Transform3D actual = body->get_global_transform().affine_inverse() * parent->get_global_transform();
	if (!actual.is_finite()) return false;
	if (a.motion_kind == "static") return actual.is_equal_approx(a.closed_parent_to_body);
	if (a.motion_kind == "raise") {
		const double length_squared = a.raise_offset.length_squared();
		if (length_squared <= 0.000001) return false;
		const double amount = (actual.origin - a.closed_parent_to_body.origin).dot(a.raise_offset) / length_squared;
		return amount >= -0.00001 && amount <= 1.00001 && actual.basis.is_equal_approx(a.closed_parent_to_body.basis) &&
			actual.origin.is_equal_approx(a.closed_parent_to_body.origin + a.raise_offset * amount);
	}
	if (a.motion_kind != "swing") return false;
	const Basis rotation = a.closed_parent_to_body.basis.inverse() * actual.basis;
	const double angle = std::atan2(-rotation.get_column(0).z, rotation.get_column(0).x);
	return angle >= std::min(0.0, a.swing) - 0.00001 && angle <= std::max(0.0, a.swing) + 0.00001 &&
		actual.origin.is_equal_approx(a.closed_parent_to_body.origin) && rotation.is_equal_approx(Basis(Vector3(0, 1, 0), angle));
}

bool ChunkRenderPacketBackend::_legacy_valid(const AttachmentRoot &a, const LegacyVisual &claim) const {
	GeometryInstance3D *visual = Object::cast_to<GeometryInstance3D>(_node3d_for_id(claim.id));
	return visual && !visual->is_queued_for_deletion() && visual->is_inside_tree() && _legacy_identity_valid(a, claim);
}

bool ChunkRenderPacketBackend::_legacy_identity_valid(const AttachmentRoot &a, const LegacyVisual &claim) const {
	Node3D *body = _node3d_for_id(a.body_id);
	GeometryInstance3D *visual = Object::cast_to<GeometryInstance3D>(_node3d_for_id(claim.id));
	return body && visual &&
		visual->get_parent() && visual->get_parent()->get_instance_id() == claim.parent_id && body->is_ancestor_of(visual) &&
		int64_t(body->get_meta("section_attachment_publisher_instance_id", 0)) == a.publisher_id;
}

bool ChunkRenderPacketBackend::_legacy_hidden(const AttachmentRoots &roots) const {
	for (const auto &entry : roots) for (const LegacyVisual &claim : entry.second.legacy_visuals) {
		if (!_legacy_valid(entry.second, claim) || _node3d_for_id(claim.id)->is_visible()) return false;
	}
	return true;
}

void ChunkRenderPacketBackend::_hide_legacy(const AttachmentRoots &roots) {
	for (const auto &entry : roots) for (const LegacyVisual &claim : entry.second.legacy_visuals) {
		if (!_legacy_valid(entry.second, claim)) continue;
		Node3D *visual = _node3d_for_id(claim.id);
		visual->remove_meta("section_attachment_legacy_restoration_receipt");
		visual->set_meta("section_attachment_native_backend_id", static_cast<int64_t>(get_instance_id()));
		visual->set_visible(false);
	}
}

bool ChunkRenderPacketBackend::_suppressed_legacy_hidden(const AttachmentRoots &roots) const {
	for (const auto &entry : roots) for (const LegacyVisual &claim : entry.second.legacy_visuals)
		if (_legacy_identity_valid(entry.second, claim) && _node3d_for_id(claim.id)->is_visible()) return false;
	return true;
}

void ChunkRenderPacketBackend::_restore_legacy(const AttachmentRoots &roots) {
	for (const auto &entry : roots) for (const LegacyVisual &claim : entry.second.legacy_visuals) {
		if (!_legacy_identity_valid(entry.second, claim)) continue;
		Node3D *visual = _node3d_for_id(claim.id);
		visual->set_visible(claim.was_visible);
		Dictionary restoration;
		restoration["visualInstanceId"] = static_cast<int64_t>(claim.id);
		restoration["parentInstanceId"] = static_cast<int64_t>(claim.parent_id);
		restoration["bodyInstanceId"] = static_cast<int64_t>(entry.second.body_id);
		restoration["publisherInstanceId"] = entry.second.publisher_id;
		restoration["publicationEpoch"] = entry.second.publication_epoch;
		restoration["sourceRevision"] = entry.second.source_revision;
		restoration["producerSourceRevision"] = entry.second.producer_source_revision;
		restoration["originalVisible"] = claim.was_visible;
		restoration.make_read_only();
		visual->set_meta("section_attachment_legacy_restoration_receipt", restoration);
		if (int64_t(visual->get_meta("section_attachment_native_backend_id", 0)) == int64_t(get_instance_id()))
			visual->remove_meta("section_attachment_native_backend_id");
	}
}

bool ChunkRenderPacketBackend::_original_legacy_visibility(uint64_t id, bool fallback) const {
	for (const auto &entry : _staged) for (const auto &attachment : entry.second.suppressed_legacy)
		for (const LegacyVisual &claim : attachment.second.legacy_visuals) if (claim.id == id) return claim.was_visible;
	for (const auto &entry : _installed) for (const auto &attachment : entry.second.suppressed_legacy)
		for (const LegacyVisual &claim : attachment.second.legacy_visuals) if (claim.id == id) return claim.was_visible;
	for (const auto &entry : _pending_presentations) for (const auto &attachment : entry.second.replacement.suppressed_legacy)
		for (const LegacyVisual &claim : attachment.second.legacy_visuals) if (claim.id == id) return claim.was_visible;
	for (const auto &entry : _installed) for (const auto &attachment : entry.second.attachments)
		for (const LegacyVisual &claim : attachment.second.legacy_visuals) if (claim.id == id) return claim.was_visible;
	for (const auto &entry : _pending_presentations) for (const auto &attachment : entry.second.replacement.attachments)
		for (const LegacyVisual &claim : attachment.second.legacy_visuals) if (claim.id == id) return claim.was_visible;
	return fallback;
}

void ChunkRenderPacketBackend::_merge_suppressed_legacy(AttachmentRoots &target, const AttachmentRoots &from, const AttachmentRoots &active) const {
	std::set<uint64_t> active_ids, retained_ids;
	for (const auto &entry : active) for (const LegacyVisual &claim : entry.second.legacy_visuals) active_ids.insert(claim.id);
	for (const auto &entry : target) for (const LegacyVisual &claim : entry.second.legacy_visuals) retained_ids.insert(claim.id);
	const auto active_claim = [&active_ids](uint64_t id) { return active_ids.count(id) != 0; };
	for (const auto &entry : from) {
		AttachmentRoot copy = entry.second;
		copy.legacy_visuals.clear();
		for (const LegacyVisual &claim : entry.second.legacy_visuals) {
			if (active_claim(claim.id) || !_node3d_for_id(claim.id)) continue;
			if (retained_ids.insert(claim.id).second) copy.legacy_visuals.push_back(claim);
		}
		if (!copy.legacy_visuals.empty()) {
			const String key = String::num_int64(static_cast<int64_t>(copy.body_id)) + ":" +
				String::num_int64(static_cast<int64_t>(copy.parent_id)) + ":" +
				String::num_int64(copy.publisher_id) + ":" + String::num_int64(copy.publication_epoch);
			auto existing = target.find(_key(key));
			if (existing == target.end()) target.emplace(_key(key), copy);
			else existing->second.legacy_visuals.insert(existing->second.legacy_visuals.end(), copy.legacy_visuals.begin(), copy.legacy_visuals.end());
		}
	}
	// If a formerly suppressed ID becomes current geometry again, its original
	// visibility is already inherited at registration; remove the duplicate claim.
	for (auto it = target.begin(); it != target.end();) {
		auto &claims = it->second.legacy_visuals;
		claims.erase(std::remove_if(claims.begin(), claims.end(), [&active_claim, this](const LegacyVisual &claim) {
			return active_claim(claim.id) || !_node3d_for_id(claim.id);
		}), claims.end());
		if (claims.empty()) it = target.erase(it); else ++it;
	}
}

int64_t ChunkRenderPacketBackend::_legacy_claim_count(const AttachmentRoots &first, const AttachmentRoots &second) const {
	std::set<uint64_t> ids;
	for (const AttachmentRoots *roots : {&first, &second})
		for (const auto &entry : *roots) for (const LegacyVisual &claim : entry.second.legacy_visuals)
			if (_node3d_for_id(claim.id)) ids.insert(claim.id);
	return static_cast<int64_t>(ids.size());
}

void ChunkRenderPacketBackend::_withdraw_source(const std::string &key) {
	// Erase ownership first. Hide every representation before any legacy is restored.
	std::vector<InstalledPacket> packets;
	Dictionary cancellation_proof;
	auto pending = _pending_presentations.find(key);
	if (pending != _pending_presentations.end()) {
		Dictionary proof = _status("cancelled", "presentation_withdrawn");
		proof["sourceId"] = pending->second.replacement.source_id;
		proof["generation"] = pending->second.replacement.generation;
		proof["token"] = pending->second.token; proof["presentationToken"] = pending->second.token;
		proof["ownershipReleased"] = true; proof["candidateQuiesced"] = true;
		proof["previousRestored"] = false; proof["previousUnavailable"] = true;
		proof["attachmentRoots"] = _attachment_receipts(pending->second.replacement.attachments, false);
		proof["attachmentManifestDeclared"] = pending->second.replacement.attachment_manifest_declared;
		proof["attachmentManifestDigest"] = pending->second.replacement.attachment_manifest_digest;
		cancellation_proof = proof;
		Dictionary in_progress = proof.duplicate(false);
		in_progress["status"] = "cancelling";
		in_progress["ownershipReleased"] = false; in_progress["candidateQuiesced"] = false;
		_owner_loss_cancellations[key] = in_progress;
		packets.push_back(pending->second.replacement);
		if (pending->second.has_previous) packets.push_back(pending->second.previous);
		_pending_presentations.erase(pending);
	}
	auto installed = _installed.find(key);
	if (installed != _installed.end()) { packets.push_back(installed->second); _installed.erase(installed); }
	auto staged = _staged.find(key);
	if (staged != _staged.end()) {
		if (cancellation_proof.is_empty()) {
			cancellation_proof = _status("aborted", "staged_source_withdrawn");
			cancellation_proof["sourceId"] = staged->second.source_id;
			cancellation_proof["generation"] = staged->second.generation;
			cancellation_proof["ownershipReleased"] = true;
			cancellation_proof["candidateQuiesced"] = true;
			cancellation_proof["requiresAuthoritativeReassembly"] = true;
			cancellation_proof["attachmentRoots"] = _attachment_receipts(staged->second.attachments, false);
			cancellation_proof["attachmentManifestDeclared"] = staged->second.attachment_manifest_declared;
			cancellation_proof["attachmentManifestDigest"] = staged->second.attachment_manifest_digest;
		}
		_release_stage(staged);
	}
	for (const InstalledPacket &packet : packets) {
		_show_attachments(packet.attachments, false);
		Node3D *root = _node3d_for_id(packet.root_instance_id); if (root) root->set_visible(false);
	}
	for (const InstalledPacket &packet : packets) {
		_restore_legacy(packet.attachments);
		_restore_legacy(packet.suppressed_legacy);
	}
	for (const InstalledPacket &packet : packets) {
		_retire_attachments(packet.attachments);
		_retire_root(packet.root_instance_id, packet.payload_bytes - _attachment_payload_bytes(packet.attachments));
	}
	for (const InstalledPacket &packet : packets) _restore_borrowed_source_visibility(packet.attachments);
	if (!cancellation_proof.is_empty()) _owner_loss_cancellations[key] = cancellation_proof;
}

Dictionary ChunkRenderPacketBackend::legacy_visual_state(int64_t id) const {
	const auto contains = [id](const AttachmentRoots &roots) {
		for (const auto &entry : roots) for (const LegacyVisual &claim : entry.second.legacy_visuals)
			if (claim.id == uint64_t(id)) return true;
		return false;
	};
	for (const auto &entry : _staged) if (contains(entry.second.suppressed_legacy)) {
		Dictionary state = _status("retained_suppressed");
		state["role"] = "suppressed"; state["sourceId"] = entry.second.source_id;
		state["generation"] = entry.second.generation; return state;
	}
	for (const auto &entry : _pending_presentations) if (contains(entry.second.replacement.attachments)) {
		Dictionary receipt = _pending_presentation_snapshot(entry.second);
		Dictionary state = _status(receipt.get("status", String()) == String("pending_presentation") ? "pending_presentation" : "stale");
		state["sourceId"] = entry.second.replacement.source_id; state["generation"] = entry.second.replacement.generation;
		state["role"] = "replacement";
		state["receipt"] = receipt; return state;
	}
	for (const auto &entry : _pending_presentations) if (entry.second.has_previous && contains(entry.second.previous.attachments)) {
		Dictionary state = _status("retained_previous");
		state["role"] = "previous"; state["sourceId"] = entry.second.replacement.source_id;
		state["generation"] = entry.second.replacement.generation; state["token"] = entry.second.token;
		state["previousUnavailable"] = entry.second.previous_unavailable;
		return state;
	}
	for (const auto &entry : _pending_presentations) if (contains(entry.second.replacement.suppressed_legacy) ||
			(entry.second.has_previous && contains(entry.second.previous.suppressed_legacy))) {
		Dictionary state = _status("retained_suppressed");
		state["role"] = "suppressed"; state["sourceId"] = entry.second.replacement.source_id;
		state["generation"] = entry.second.replacement.generation; state["token"] = entry.second.token;
		return state;
	}
	for (const auto &entry : _installed) if (!_pending_presentations.count(entry.first) && contains(entry.second.attachments)) {
		if (_staged.count(entry.first)) {
			Dictionary state = _status("retained_previous");
			state["role"] = "previous"; state["sourceId"] = entry.second.source_id;
			state["generation"] = entry.second.generation; return state;
		}
		Dictionary receipt = _installed_snapshot(entry.second);
		Dictionary state = _status(receipt.get("status", String()) == String("ready") ? "installed" : "stale");
		state["sourceId"] = entry.second.source_id; state["generation"] = entry.second.generation;
		state["role"] = "installed";
		state["receipt"] = receipt; return state;
	}
	for (const auto &entry : _installed) if (!_pending_presentations.count(entry.first) && contains(entry.second.suppressed_legacy)) {
		Dictionary state = _status("retained_suppressed");
		state["role"] = "suppressed"; state["sourceId"] = entry.second.source_id; state["generation"] = entry.second.generation;
		return state;
	}
	return _status("unowned");
}

Dictionary ChunkRenderPacketBackend::restore_legacy_for_visual(int64_t id) {
	Dictionary ownership = legacy_visual_state(id);
	if (String(ownership.get("status", "")) == "retained_previous" || String(ownership.get("status", "")) == "retained_suppressed") return ownership;
	std::vector<std::string> sources;
	const auto contains = [id](const AttachmentRoots &roots) {
		for (const auto &entry : roots) for (const LegacyVisual &claim : entry.second.legacy_visuals)
			if (claim.id == uint64_t(id)) return true;
		return false;
	};
	for (const auto &entry : _installed) if (!_pending_presentations.count(entry.first) && contains(entry.second.attachments)) sources.push_back(entry.first);
	for (const auto &entry : _pending_presentations) if (contains(entry.second.replacement.attachments)) sources.push_back(entry.first);
	for (const std::string &source : sources) _withdraw_source(source);
	return _status(sources.empty() ? "unowned" : "restored");
}

void ChunkRenderPacketBackend::_on_attachment_owner_exiting(int64_t p_owner_id) {
	// tree_exiting also fires on reversible detach. Retain exact live-object
	// suppression claims and their original visibility until final withdrawal.
	const auto owns = [p_owner_id, this](const AttachmentRoots &roots) {
		for (const auto &entry : roots) {
			if (entry.second.body_id == uint64_t(p_owner_id) || entry.second.parent_id == uint64_t(p_owner_id)) return true;
			if (entry.second.ownership_kind == "borrowed_presentation" && entry.second.root_id == uint64_t(p_owner_id)) {
				Node3D *mount = _node3d_for_id(entry.second.root_id);
				// Removing a mount from the tree can be a reversible detach; only a
				// queued destruction invalidates this source-owned presentation claim.
				if (mount == nullptr || mount->is_queued_for_deletion()) return true;
			}
		}
		return false;
	};
	std::vector<std::string> sources;
	for (auto &entry : _pending_presentations) {
		PendingPresentation &pending = entry.second;
		const bool previous_lost = pending.has_previous && owns(pending.previous.attachments);
		if (previous_lost) {
			pending.previous_unavailable = true;
			pending.previous_active = false;
			// Previous-only disappearance cannot cancel the independent replacement.
			_installed.erase(entry.first);
			_retire_attachments(pending.previous.attachments);
			_retire_root(pending.previous.root_instance_id, pending.previous.payload_bytes - _attachment_payload_bytes(pending.previous.attachments));
		}
		if (owns(pending.replacement.attachments)) {
			pending.replacement_owner_lost = true;
			pending.replacement_active = false;
			_show_attachments(pending.replacement.attachments, false);
			Node3D *root = _node3d_for_id(pending.replacement.root_instance_id); if (root) root->set_visible(false);
		}
	}
	for (auto staged = _staged.begin(); staged != _staged.end();) {
		if (!_pending_presentations.count(staged->first) && owns(staged->second.attachments)) {
			Dictionary proof = _status("aborted", "attachment_staged_owner_lost");
			proof["sourceId"] = staged->second.source_id; proof["generation"] = staged->second.generation;
			proof["ownershipReleased"] = true; proof["candidateQuiesced"] = true;
			proof["requiresAuthoritativeReassembly"] = true;
			_owner_loss_cancellations[staged->first] = proof;
			auto retiring = staged++;
			_release_stage(retiring);
		} else {
			++staged;
		}
	}
	for (const auto &entry : _installed) if (!_pending_presentations.count(entry.first) && owns(entry.second.attachments)) sources.push_back(entry.first);
	for (const std::string &source : sources) {
		auto replacement = _staged.find(source);
		auto previous = _installed.find(source);
		if (replacement != _staged.end() && previous != _installed.end()) {
			// A previous owner may leave while an independent candidate is still
			// uploading. Retain its visibility claims, not its invalid render roots.
			_merge_suppressed_legacy(replacement->second.suppressed_legacy,
				previous->second.suppressed_legacy, replacement->second.attachments);
			_merge_suppressed_legacy(replacement->second.suppressed_legacy,
				previous->second.attachments, replacement->second.attachments);
			_show_attachments(previous->second.attachments, false);
			const AttachmentRoots released_borrowed = previous->second.attachments;
			_retire_attachments(previous->second.attachments);
			_retire_root(previous->second.root_instance_id, previous->second.payload_bytes - _attachment_payload_bytes(previous->second.attachments));
			_installed.erase(previous);
			_restore_borrowed_source_visibility(released_borrowed);
			if (_legacy_claim_count(replacement->second.attachments, replacement->second.suppressed_legacy) > MAX_LEGACY_CLAIMS_PER_PACKET) {
				Dictionary proof = _status("aborted", "legacy_visual_retention_capacity");
				proof["sourceId"] = replacement->second.source_id; proof["generation"] = replacement->second.generation;
				proof["ownershipReleased"] = true; proof["candidateQuiesced"] = true;
				proof["requiresAuthoritativeReassembly"] = true;
				_release_stage(replacement);
				_owner_loss_cancellations[source] = proof;
			}
		} else {
			_withdraw_source(source);
		}
	}
}

Dictionary ChunkRenderPacketBackend::settle_attachment_owner_loss(const String &source, int64_t generation, const String &token) {
	return settle_presentation_cancellation(source, generation, token);
}

Dictionary ChunkRenderPacketBackend::settle_presentation_cancellation(const String &source, int64_t generation, const String &token, bool withdrawal_requested) {
	const std::string key = _key(source);
	auto cancellation = _owner_loss_cancellations.find(key);
	if (cancellation != _owner_loss_cancellations.end()) {
		if (int64_t(cancellation->second.get("generation", 0)) != generation ||
				String(cancellation->second.get("presentationToken", "")) != token ||
				String(cancellation->second.get("status", "")) != "cancelled")
			return _status("failed", "presentation_cancellation_identity_mismatch");
		Dictionary proof = cancellation->second;
		_owner_loss_cancellations.erase(cancellation);
		return proof;
	}
	auto found = _pending_presentations.find(key);
	if (found == _pending_presentations.end()) return _status("not_applicable");
	PendingPresentation &pending = found->second;
	if (pending.replacement.generation != generation || pending.token != token) return _status("failed", "pending_presentation_identity_mismatch");
	const bool can_restore = pending.has_previous && !pending.previous_unavailable &&
		String(_installed_snapshot(pending.previous, true).get("status", "")) == "ready";
	if (!pending.replacement_owner_lost) {
		if (!withdrawal_requested || !pending.has_previous || can_restore) return _status("not_applicable");
		// Explicit cancellation may release an unavailable rollback target. It
		// does not turn partial restoration into a successful rollback.
		_withdraw_source(key);
		return settle_presentation_cancellation(source, generation, token);
	}
	bool previous_restored = false;
	if (can_restore) {
		Dictionary rollback = rollback_presentation(source, generation, token);
		previous_restored = String(rollback.get("status", "")) == "rolled_back";
	}
	if (!previous_restored) {
		_withdraw_source(key);
		return settle_presentation_cancellation(source, generation, token);
	}
	Dictionary result = _status("cancelled", "attachment_replacement_owner_lost");
	result["sourceId"] = source; result["generation"] = generation; result["token"] = token;
	result["presentationToken"] = token;
	result["ownershipReleased"] = true; result["candidateQuiesced"] = true;
	result["previousRestored"] = previous_restored; result["previousUnavailable"] = !previous_restored;
	return result;
}

void ChunkRenderPacketBackend::_show_attachments(const AttachmentRoots &p_roots, bool p_visible) {
	for (const auto &entry : p_roots) {
		Node3D *root = _node3d_for_id(entry.second.root_id);
		if (root) root->set_visible(p_visible && entry.second.intended_visible);
	}
}

void ChunkRenderPacketBackend::_show_attachments_transition(const AttachmentRoots &p_roots,
		bool p_visible, const AttachmentRoots &p_preserved_borrowed_roots) {
	for (const auto &entry : p_roots) {
		const AttachmentRoot &attachment = entry.second;
		if (attachment.ownership_kind == "borrowed_presentation") {
			bool shared = false;
			for (const auto &preserved : p_preserved_borrowed_roots) {
				if (preserved.second.ownership_kind == "borrowed_presentation" &&
						preserved.second.root_id == attachment.root_id) {
					shared = true;
					break;
				}
			}
			if (shared) continue;
		}
		Node3D *root = _node3d_for_id(attachment.root_id);
		if (root) root->set_visible(p_visible && attachment.intended_visible);
	}
}

void ChunkRenderPacketBackend::_retire_attachments(const AttachmentRoots &p_roots) {
	for (const auto &entry : p_roots) {
		if (entry.second.ownership_kind == "borrowed_presentation") continue;
		_retire_root(entry.second.root_id, entry.second.payload_bytes);
	}
}

int64_t ChunkRenderPacketBackend::_attachment_payload_bytes(const AttachmentRoots &p_roots) const {
	int64_t result = 0;
	for (const auto &entry : p_roots)
		if (entry.second.ownership_kind == "backend_owned_geometry") result += entry.second.payload_bytes;
	return result;
}

Array ChunkRenderPacketBackend::_attachment_receipts(const AttachmentRoots &p_roots, bool p_active_claim) const {
	Array rows;
	for (const auto &entry : p_roots) {
		Dictionary row;
		row["attachmentKey"] = String(entry.first.c_str());
		row["memberSourceId"] = entry.second.member_source_id;
		row["sourcePartId"] = entry.second.source_part_id;
		row["presentationMemberId"] = entry.second.presentation_member_id;
		row["ownershipKind"] = entry.second.ownership_kind;
		row["intendedVisible"] = entry.second.intended_visible;
		row["activeClaim"] = p_active_claim && entry.second.intended_visible;
		row["rootInstanceId"] = static_cast<int64_t>(entry.second.root_id);
		row["parentInstanceId"] = static_cast<int64_t>(entry.second.parent_id);
		row["bodyInstanceId"] = static_cast<int64_t>(entry.second.body_id);
		row["neutralParentToWorld"] = entry.second.neutral_parent_world;
		row["sourceRevision"] = entry.second.source_revision;
		row["producerSourceRevision"] = entry.second.producer_source_revision;
		row["publisherInstanceId"] = entry.second.publisher_id;
		row["publicationEpoch"] = entry.second.publication_epoch;
		row["rootVisible"] = _node3d_for_id(entry.second.root_id) && _node3d_for_id(entry.second.root_id)->is_visible();
		row["motionKind"] = entry.second.motion_kind;
		row["closedParentToBody"] = entry.second.closed_parent_to_body;
		row["swing"] = entry.second.swing;
		row["raiseOffset"] = entry.second.raise_offset;
		row["sweptWorldBounds"] = entry.second.swept_bounds;
		Array claims;
		for (const LegacyVisual &claim : entry.second.legacy_visuals) {
			Dictionary visual;
			visual["visualInstanceId"] = static_cast<int64_t>(claim.id);
			visual["parentInstanceId"] = static_cast<int64_t>(claim.parent_id);
			visual["originalVisible"] = claim.was_visible;
			Node3D *current = _node3d_for_id(claim.id);
			visual["hidden"] = _legacy_valid(entry.second, claim) && current && !current->is_visible();
			claims.push_back(visual);
		}
		row["legacyVisuals"] = claims;
		row["payloadBytes"] = entry.second.ownership_kind == "backend_owned_geometry" ? entry.second.payload_bytes : int64_t(0);
		rows.push_back(row);
	}
	return rows;
}

void ChunkRenderPacketBackend::_notification(int p_what) {
	if (p_what != NOTIFICATION_EXIT_TREE) return;
	std::vector<std::string> sources;
	for (const auto &entry : _staged) sources.push_back(entry.first);
	for (const auto &entry : _installed) sources.push_back(entry.first);
	for (const auto &entry : _pending_presentations) sources.push_back(entry.first);
	for (const std::string &source : sources) _withdraw_source(source);
	// EXIT_TREE can be a reversible detach. Keep exact-token cancellation
	// receipts callable and block re-admission until the session acknowledges.
	// The coordinator must drain sessions before destroying this native object.
}

Dictionary ChunkRenderPacketBackend::register_packet_attachment(const String &p_source_id, int64_t p_generation,
		const String &p_key, Node3D *p_parent, Node3D *p_body, const Transform3D &p_neutral_parent_world, const Dictionary &p_motion, const Array &p_legacy_visuals) {
	auto found = _staged.find(_key(p_source_id));
	if (found == _staged.end() || !_stage_matches(found->second, p_generation)) return _status("failed", "staged_generation_missing");
	StagedPacket &packet = found->second;
	Node3D *chunk = Object::cast_to<Node3D>(get_parent());
	if (_legacy_claim_count(packet.attachments, packet.suppressed_legacy) + p_legacy_visuals.size() > MAX_LEGACY_CLAIMS_PER_PACKET)
		return _status("backpressure", "legacy_visual_claim_capacity");
	if (!chunk || packet.state != "collecting" || !packet.batches.empty() || p_key.is_empty() ||
			packet.attachments.count(_key(p_key)) || !p_parent || !p_body ||
			!p_parent->is_inside_tree() || !p_body->is_inside_tree() ||
			(p_parent != p_body && !p_body->is_ancestor_of(p_parent)) ||
			p_parent == this || is_ancestor_of(p_parent) ||
			!p_neutral_parent_world.is_finite() || Math::is_zero_approx(p_neutral_parent_world.basis.determinant()))
		return _status("failed", "invalid_attachment_binding");
	AttachmentRoot a;
	a.packet_source_id = p_source_id; a.packet_generation = p_generation;
	if (packet.attachment_manifest_declared) {
		auto expected = packet.expected_attachment_manifest.find(_key(p_key));
		if (expected == packet.expected_attachment_manifest.end() ||
				String(expected->second.get("ownershipKind", "")) != "backend_owned_geometry")
			return _status("failed", "attachment_manifest_member_mismatch");
		a.presentation_member_id = expected->second.get("presentationMemberId", String());
		a.member_source_id = expected->second.get("sourceId", String());
		a.source_part_id = expected->second.get("sourcePartId", String());
		a.source_revision = expected->second.get("sourceRevision", String());
		a.producer_source_revision = expected->second.get("producerSourceRevision", String());
		a.intended_visible = expected->second.get("intendedVisible", true);
		a.neutral_parent_world = expected->second.get("neutralParentToWorld", Transform3D());
		a.swept_bounds = expected->second.get("sweptWorldBounds", AABB());
	}
	if (p_motion.size() != 4 || p_motion.get("kind", Variant()).get_type() != Variant::STRING ||
			p_motion.get("closedParentToBody", Variant()).get_type() != Variant::TRANSFORM3D ||
			p_motion.get("raiseOffset", Variant()).get_type() != Variant::VECTOR3 ||
			p_motion.get("swing", Variant()).get_type() != Variant::FLOAT) return _status("failed", "attachment_motion_descriptor_missing");
	a.motion_kind = p_motion["kind"]; a.closed_parent_to_body = p_motion["closedParentToBody"];
	a.raise_offset = p_motion["raiseOffset"]; a.swing = p_motion["swing"];
	if (packet.attachment_manifest_declared) {
		const Dictionary expected = packet.expected_attachment_manifest.at(_key(p_key));
		if (a.motion_kind != String(Dictionary(expected.get("motion", Dictionary())).get("kind", "")) ||
				!a.neutral_parent_world.is_equal_approx(p_neutral_parent_world) ||
				!a.closed_parent_to_body.is_equal_approx(Dictionary(expected.get("motion", Dictionary())).get("closedParentToBody", Transform3D())) ||
				!a.raise_offset.is_equal_approx(Dictionary(expected.get("motion", Dictionary())).get("raiseOffset", Vector3())) ||
				!Math::is_equal_approx(a.swing, double(Dictionary(expected.get("motion", Dictionary())).get("swing", 0.0))))
			return _status("failed", "attachment_manifest_spatial_contract_mismatch");
	}
	if (!a.closed_parent_to_body.is_finite() || Math::is_zero_approx(a.closed_parent_to_body.basis.determinant()) ||
			!a.raise_offset.is_finite() || !std::isfinite(a.swing) || std::abs(a.swing) > 3.141592653589793 ||
			!a.closed_parent_to_body.is_equal_approx(p_body->get_global_transform().affine_inverse() * p_neutral_parent_world) ||
			!_attachment_motion_valid(a, p_parent, p_body)) return _status("failed", "attachment_motion_outside_declared_envelope");
	const String captured_revision = p_body->get_meta("section_attachment_source_revision", "");
	const int64_t captured_publisher = p_body->get_meta("section_attachment_publisher_instance_id", 0);
	const int64_t captured_epoch = p_body->get_meta("section_attachment_publication_epoch", -1);
	if (packet.attachment_manifest_declared && a.producer_source_revision != captured_revision)
		return _status("failed", "attachment_manifest_source_identity_mismatch");
	if (!packet.attachment_manifest_declared) a.source_revision = captured_revision;
	a.producer_source_revision = captured_revision;
	a.publisher_id = captured_publisher;
	a.publication_epoch = captured_epoch;
	// RefCounted ObjectIDs use bit 63; their signed Variant integer is negative.
	if (a.source_revision.is_empty() || a.producer_source_revision.is_empty() || a.publisher_id == 0 || a.publication_epoch < 0)
		return _status("failed", "attachment_source_boundary_missing");
	a.parent_id = p_parent->get_instance_id(); a.body_id = p_body->get_instance_id();
	if (p_legacy_visuals.is_empty()) return _status("failed", "attachment_legacy_manifest_empty");
	for (int64_t index = 0; index < p_legacy_visuals.size(); ++index) {
		Object *object = p_legacy_visuals[index];
		GeometryInstance3D *visual = Object::cast_to<GeometryInstance3D>(object);
		if (!visual || !visual->get_parent() || !visual->is_inside_tree() || visual->is_queued_for_deletion() ||
				!p_body->is_ancestor_of(visual)) return _status("failed", "attachment_legacy_manifest_invalid");
		LegacyVisual claim;
		claim.id = visual->get_instance_id(); claim.parent_id = visual->get_parent()->get_instance_id();
		Dictionary ownership = legacy_visual_state(static_cast<int64_t>(claim.id));
		if (String(ownership.get("status", "unowned")) != "unowned" && String(ownership.get("sourceId", "")) != p_source_id)
			return _status("failed", "legacy_visual_owned_by_other_packet");
		const int64_t other_backend = visual->get_meta("section_attachment_native_backend_id", 0);
		if (other_backend != 0 && other_backend != int64_t(get_instance_id()) && _node3d_for_id(other_backend))
			return _status("failed", "legacy_visual_owned_by_other_backend");
		claim.was_visible = _original_legacy_visibility(claim.id, visual->is_visible());
		for (const LegacyVisual &existing : a.legacy_visuals) if (existing.id == claim.id) return _status("failed", "duplicate_attachment_legacy_visual");
		for (const auto &entry : packet.attachments) for (const LegacyVisual &existing : entry.second.legacy_visuals)
			if (existing.id == claim.id) return _status("failed", "duplicate_attachment_legacy_visual");
		a.legacy_visuals.push_back(claim);
	}
	a.neutral_parent_world = p_neutral_parent_world; a.body_world = p_body->get_global_transform();
	a.local_transform = p_neutral_parent_world.affine_inverse() * chunk->get_global_transform() * packet.local_to_chunk;
	Node3D *root = memnew(Node3D);
	root->set_name(String("PacketAttachment_") + p_key.validate_node_name());
	root->set_meta("section_attachment_native_root", true);
	root->set_meta("packet_backend_instance_id", static_cast<int64_t>(get_instance_id()));
	root->set_meta("packet_source_id", p_source_id);
	root->set_meta("packet_generation", p_generation);
	root->set_visible(false); root->set_transform(a.local_transform);
	p_parent->add_child(root); a.root_id = root->get_instance_id();
	packet.attachments.emplace(_key(p_key), a);
	for (Node3D *owner : {p_body, p_parent}) {
		Callable exiting = callable_mp(this, &ChunkRenderPacketBackend::_on_attachment_owner_exiting).bind(static_cast<int64_t>(owner->get_instance_id()));
		if (!owner->is_connected("tree_exiting", exiting)) owner->connect("tree_exiting", exiting, Object::CONNECT_ONE_SHOT);
	}
	return _status("registered");
}

Dictionary ChunkRenderPacketBackend::register_borrowed_presentation(const String &p_source_id,
		int64_t p_generation, const String &p_key, const String &p_member_source_id,
		const String &p_source_part_id, const String &p_member_id,
		Node3D *p_mount, Node3D *p_parent, Node3D *p_body,
		const Transform3D &p_neutral_parent_world, const Transform3D &p_mount_local_transform,
		const Dictionary &p_motion, bool p_intended_visible, const Array &p_legacy_visuals) {
	auto found = _staged.find(_key(p_source_id));
	if (found == _staged.end() || !_stage_matches(found->second, p_generation))
		return _status("failed", "staged_generation_missing");
	StagedPacket &packet = found->second;
	if (!packet.attachment_manifest_declared)
		return _status("failed", "borrowed_presentation_manifest_required");
	auto expected = packet.expected_attachment_manifest.find(_key(p_key));
	if (expected == packet.expected_attachment_manifest.end() ||
			String(expected->second.get("ownershipKind", "")) != "borrowed_presentation" ||
			String(expected->second.get("sourceId", "")) != p_member_source_id ||
			String(expected->second.get("sourcePartId", "")) != p_source_part_id ||
			String(expected->second.get("presentationMemberId", "")) != p_member_id ||
			bool(expected->second.get("intendedVisible", false)) != p_intended_visible)
		return _status("failed", "attachment_manifest_member_mismatch");
	if (p_key.is_empty() || p_member_id.is_empty() || !p_mount || !p_parent || !p_body ||
			(packet.state != "collecting" && !(packet.state == "ready" && packet.expected_batch_count == 0 && packet.expected_instance_count == 0)) || !packet.batches.empty() || packet.attachments.count(_key(p_key)) ||
			!p_mount->is_inside_tree() || !p_parent->is_inside_tree() || !p_body->is_inside_tree() ||
			p_mount->is_queued_for_deletion() || p_parent->is_queued_for_deletion() || p_body->is_queued_for_deletion() ||
			p_mount->get_parent() != p_parent || (p_parent != p_body && !p_body->is_ancestor_of(p_parent)) ||
			p_mount == this || is_ancestor_of(p_mount) || p_parent == this || is_ancestor_of(p_parent) ||
			!p_mount->has_meta("section_attachment_presentation_member_id") ||
			String(p_mount->get_meta("section_attachment_presentation_member_id", "")) != p_member_id ||
			!p_neutral_parent_world.is_finite() || Math::is_zero_approx(p_neutral_parent_world.basis.determinant()) ||
			!transform_finite(p_mount_local_transform) || !p_mount->get_transform().is_equal_approx(p_mount_local_transform))
		return _status("failed", "invalid_borrowed_presentation_binding");
	if (_borrowed_root_claimed_elsewhere(p_mount->get_instance_id(), p_source_id))
		return _status("failed", "borrowed_mount_owned_by_other_source");
	AttachmentRoot a;
	a.ownership_kind = "borrowed_presentation";
	a.member_source_id = p_member_source_id;
	a.source_part_id = p_source_part_id;
	a.presentation_member_id = p_member_id;
	a.intended_visible = p_intended_visible;
	a.packet_source_id = p_source_id; a.packet_generation = p_generation;
	a.source_revision = expected->second.get("sourceRevision", String());
	a.producer_source_revision = p_body->get_meta("section_attachment_source_revision", "");
	a.publisher_id = p_body->get_meta("section_attachment_publisher_instance_id", int64_t(0));
	a.publication_epoch = p_body->get_meta("section_attachment_publication_epoch", int64_t(-1));
	if (a.producer_source_revision != String(expected->second.get("producerSourceRevision", "")) ||
			a.source_revision.is_empty() || a.producer_source_revision.is_empty() || a.publisher_id == 0 || a.publication_epoch < 0)
		return _status("failed", "attachment_manifest_source_identity_mismatch");
	a.root_id = p_mount->get_instance_id();
	a.borrowed_source_visible = p_mount->is_visible();
	_borrowed_root_source_visibility(a.root_id, a.borrowed_source_visible);
	a.parent_id = p_parent->get_instance_id(); a.body_id = p_body->get_instance_id();
	a.neutral_parent_world = p_neutral_parent_world;
	a.swept_bounds = expected->second.get("sweptWorldBounds", AABB());
	a.body_world = p_body->get_global_transform();
	a.local_transform = p_mount_local_transform;
	if (p_motion.size() != 4 || p_motion.get("kind", Variant()).get_type() != Variant::STRING ||
			p_motion.get("closedParentToBody", Variant()).get_type() != Variant::TRANSFORM3D ||
			p_motion.get("raiseOffset", Variant()).get_type() != Variant::VECTOR3 ||
			p_motion.get("swing", Variant()).get_type() != Variant::FLOAT)
		return _status("failed", "attachment_motion_descriptor_missing");
	a.motion_kind = p_motion["kind"];
	a.closed_parent_to_body = p_motion["closedParentToBody"];
	a.raise_offset = p_motion["raiseOffset"];
	a.swing = p_motion["swing"];
	const Dictionary expected_motion = expected->second.get("motion", Dictionary());
	if (a.motion_kind != String(expected_motion.get("kind", "")))
		return _status("failed", "attachment_manifest_motion_mismatch");
	if (!a.neutral_parent_world.is_equal_approx(expected->second.get("neutralParentToWorld", Transform3D())) ||
			!a.closed_parent_to_body.is_equal_approx(expected_motion.get("closedParentToBody", Transform3D())) ||
			!a.raise_offset.is_equal_approx(expected_motion.get("raiseOffset", Vector3())) ||
			!Math::is_equal_approx(a.swing, double(expected_motion.get("swing", 0.0))))
		return _status("failed", "attachment_manifest_spatial_contract_mismatch");
	if (!a.closed_parent_to_body.is_finite() || Math::is_zero_approx(a.closed_parent_to_body.basis.determinant()) ||
			!a.raise_offset.is_finite() || !std::isfinite(a.swing) || std::abs(a.swing) > 3.141592653589793 ||
			!a.closed_parent_to_body.is_equal_approx(p_body->get_global_transform().affine_inverse() * p_neutral_parent_world) ||
			!_attachment_motion_valid(a, p_parent, p_body))
		return _status("failed", "attachment_motion_outside_declared_envelope");
	const auto same_mount_identity = [&a, &p_key](const AttachmentRoots &roots) {
		for (const auto &entry : roots) {
			const AttachmentRoot &prior = entry.second;
			if (prior.ownership_kind != "borrowed_presentation" || prior.root_id != a.root_id) continue;
			if (entry.first != _key(p_key) || prior.member_source_id != a.member_source_id ||
					prior.source_part_id != a.source_part_id ||
					prior.producer_source_revision != a.producer_source_revision ||
					prior.presentation_member_id != a.presentation_member_id || prior.parent_id != a.parent_id ||
					prior.body_id != a.body_id || prior.publisher_id != a.publisher_id ||
					prior.publication_epoch != a.publication_epoch || prior.intended_visible != a.intended_visible ||
					prior.swept_bounds != a.swept_bounds ||
					!prior.local_transform.is_equal_approx(a.local_transform) ||
					!prior.neutral_parent_world.is_equal_approx(a.neutral_parent_world) ||
					prior.motion_kind != a.motion_kind ||
					!prior.closed_parent_to_body.is_equal_approx(a.closed_parent_to_body) ||
					!prior.raise_offset.is_equal_approx(a.raise_offset) || !Math::is_equal_approx(prior.swing, a.swing)) return false;
		}
		return true;
	};
	for (const auto &entry : packet.attachments)
		if (entry.second.ownership_kind == "borrowed_presentation" && entry.second.root_id == a.root_id)
			return _status("failed", "duplicate_borrowed_presentation_mount");
	for (const auto &entry : _installed) if (entry.second.source_id == p_source_id && !same_mount_identity(entry.second.attachments))
		return _status("failed", "borrowed_mount_transfer_identity_mismatch");
	for (const auto &entry : _pending_presentations) if (entry.second.replacement.source_id == p_source_id &&
			(!same_mount_identity(entry.second.replacement.attachments) ||
			(entry.second.has_previous && !same_mount_identity(entry.second.previous.attachments))))
		return _status("failed", "borrowed_mount_transfer_identity_mismatch");
	if (p_mount->is_visible() != (_borrowed_root_has_presentation_role(a.root_id) ?
			_borrowed_root_active(a.root_id) : a.borrowed_source_visible))
		return _status("failed", "borrowed_mount_visibility_claim_mismatch");
	for (int64_t index = 0; index < p_legacy_visuals.size(); ++index) {
		Object *object = p_legacy_visuals[index];
		GeometryInstance3D *visual = Object::cast_to<GeometryInstance3D>(object);
		if (!visual || !visual->get_parent() || !visual->is_inside_tree() || visual->is_queued_for_deletion() ||
				!p_body->is_ancestor_of(visual)) return _status("failed", "attachment_legacy_manifest_invalid");
		LegacyVisual claim;
		claim.id = visual->get_instance_id(); claim.parent_id = visual->get_parent()->get_instance_id();
		claim.was_visible = _original_legacy_visibility(claim.id, visual->is_visible());
		for (const LegacyVisual &existing : a.legacy_visuals)
			if (existing.id == claim.id) return _status("failed", "duplicate_attachment_legacy_visual");
		a.legacy_visuals.push_back(claim);
	}
	packet.attachments.emplace(_key(p_key), a);
	for (Node3D *owner : {p_body, p_parent}) {
		Callable exiting = callable_mp(this, &ChunkRenderPacketBackend::_on_attachment_owner_exiting).bind(static_cast<int64_t>(owner->get_instance_id()));
		if (!owner->is_connected("tree_exiting", exiting)) owner->connect("tree_exiting", exiting, Object::CONNECT_ONE_SHOT);
	}
	// A borrowed mount may be detached and reattached without ending its source
	// incarnation. Keep this callback connected across reversible detach so a
	// later queued destruction can still invalidate the claim.
	Callable mount_exiting = callable_mp(this, &ChunkRenderPacketBackend::_on_attachment_owner_exiting).bind(static_cast<int64_t>(p_mount->get_instance_id()));
	if (!p_mount->is_connected("tree_exiting", mount_exiting)) p_mount->connect("tree_exiting", mount_exiting);
	Dictionary result = _status("registered_borrowed");
	result["sourceId"] = p_source_id; result["generation"] = p_generation;
	result["attachmentKey"] = p_key; result["presentationMemberId"] = p_member_id;
	result["ownershipKind"] = a.ownership_kind;
	result["mountInstanceId"] = static_cast<int64_t>(a.root_id);
	return result;
}

Dictionary ChunkRenderPacketBackend::append_batch_in_attachment(const String &p_source_id,
		int64_t p_generation, const String &p_batch_id, const Ref<Mesh> &p_mesh,
		const String &p_expected_mesh_content_digest, const Ref<Material> &p_material,
		const PackedFloat32Array &p_buffer, const AABB &p_bounds, const String &p_render_tier,
		bool p_cast_shadows, double p_visibility_range, double p_fade_margin,
		const String &p_render_layer, const String &p_attachment_key, bool p_intended_visible) {
	return _append_batch(p_source_id, p_generation, p_batch_id, p_mesh, p_expected_mesh_content_digest,
		p_material, p_buffer, p_bounds, p_render_tier, p_cast_shadows, p_visibility_range,
		p_fade_margin, p_render_layer, p_attachment_key, p_intended_visible);
}

Dictionary ChunkRenderPacketBackend::append_batch(const String &p_source_id,
		int64_t p_generation, const String &p_batch_id, const Ref<Mesh> &p_mesh,
		const String &p_expected_mesh_content_digest,
		const Ref<Material> &p_material, const PackedFloat32Array &p_buffer,
		const AABB &p_bounds, const String &p_render_tier, bool p_cast_shadows,
		double p_visibility_range, double p_fade_margin) {
	return _append_batch(p_source_id, p_generation, p_batch_id, p_mesh,
		p_expected_mesh_content_digest, p_material, p_buffer, p_bounds,
		p_render_tier, p_cast_shadows, p_visibility_range, p_fade_margin, "opaque", "", true);
}

Dictionary ChunkRenderPacketBackend::append_batch_in_layer(const String &p_source_id,
		int64_t p_generation, const String &p_batch_id, const Ref<Mesh> &p_mesh,
		const String &p_expected_mesh_content_digest,
		const Ref<Material> &p_material, const PackedFloat32Array &p_buffer,
		const AABB &p_bounds, const String &p_render_tier, bool p_cast_shadows,
		double p_visibility_range, double p_fade_margin, const String &p_render_layer,
		bool p_intended_visible) {
	return _append_batch(p_source_id, p_generation, p_batch_id, p_mesh,
		p_expected_mesh_content_digest, p_material, p_buffer, p_bounds,
		p_render_tier, p_cast_shadows, p_visibility_range, p_fade_margin, p_render_layer,
		"", p_intended_visible);
}

Dictionary ChunkRenderPacketBackend::_append_batch(const String &p_source_id,
		int64_t p_generation, const String &p_batch_id, const Ref<Mesh> &p_mesh,
		const String &p_expected_mesh_content_digest,
		const Ref<Material> &p_material, const PackedFloat32Array &p_buffer,
		const AABB &p_bounds, const String &p_render_tier, bool p_cast_shadows,
		double p_visibility_range, double p_fade_margin, const String &p_render_layer,
		const String &p_attachment_key, bool p_intended_visible) {
	auto found = _staged.find(_key(p_source_id));
	if (found == _staged.end() || !_stage_matches(found->second, p_generation)) return _status("failed", "staged_generation_missing");
	StagedPacket &packet = found->second;
	if (packet.state != "collecting") return _status("failed", "packet_not_collecting");
	if ((!p_attachment_key.is_empty() && !packet.attachments.count(_key(p_attachment_key))) ||
			!_attachments_valid(packet.attachments, false)) return _status("failed", "attachment_binding_stale");
	Node3D *staging_root = _node3d_for_id(packet.root_instance_id);
	if (staging_root == nullptr || staging_root->get_parent() != this) return _status("failed", "staging_root_retired");
	if (p_batch_id.strip_edges().is_empty() || p_mesh.is_null() || !render_layer_supported(p_render_layer) ||
			p_expected_mesh_content_digest.length() != 64 || p_buffer.is_empty() ||
			p_buffer.size() % FLOATS_PER_INSTANCE != 0 ||
			p_buffer.size() > MAX_BATCH_INSTANCES * FLOATS_PER_INSTANCE ||
			!tier_supported(p_render_tier) || !std::isfinite(p_visibility_range) ||
			!std::isfinite(p_fade_margin) || p_visibility_range < 0.0 || p_fade_margin < 0.0 ||
			!std::isfinite(p_bounds.get_position().x) || !std::isfinite(p_bounds.get_position().y) ||
			!std::isfinite(p_bounds.get_position().z) || !std::isfinite(p_bounds.get_size().x) ||
			!std::isfinite(p_bounds.get_size().y) || !std::isfinite(p_bounds.get_size().z) ||
			p_bounds.get_size().x < 0.0 || p_bounds.get_size().y < 0.0 || p_bounds.get_size().z < 0.0) {
		return _status("failed", "invalid_batch_payload");
	}
	for (const Batch &existing : packet.batches) {
		if (existing.id == p_batch_id) return _status("failed", "duplicate_batch_id");
	}
	const int64_t instances = p_buffer.size() / FLOATS_PER_INSTANCE;
	StagedPacket::LayerManifestEntry *target_layer = nullptr;
	for (StagedPacket::LayerManifestEntry &layer : packet.layers) {
		if (layer.layer == p_render_layer) { target_layer = &layer; break; }
	}
	if (target_layer == nullptr) return _status("failed", "batch_render_layer_missing_from_manifest");
	if (target_layer->accepted_batch_count + 1 > target_layer->expected_batch_count ||
			target_layer->accepted_instance_count + instances > target_layer->expected_instance_count) {
		return _status("failed", "packet_layer_expected_count_exceeded");
	}
	const int64_t buffer_bytes = static_cast<int64_t>(p_buffer.size()) * FLOAT_BYTES;
	Ref<Resource> duplicated_resource = p_mesh->duplicate(true);
	Ref<Mesh> owned_mesh = duplicated_resource;
	if (owned_mesh.is_null()) return _status("failed", "mesh_payload_snapshot_failed");
	int64_t mesh_bytes = 0;
	String mesh_digest;
	if (!mesh_surface_fingerprint(owned_mesh, mesh_bytes, mesh_digest)) return _status("failed", "mesh_surface_payload_unmeasurable");
	if (mesh_digest != p_expected_mesh_content_digest) return _status("failed", "mesh_content_identity_mismatch");
	if (buffer_bytes > std::numeric_limits<int64_t>::max() - mesh_bytes) return _status("failed", "batch_payload_size_overflow");
	const int64_t payload_bytes = buffer_bytes + mesh_bytes;
	for (int64_t index = 0; index < p_buffer.size(); ++index) {
		if (!std::isfinite(p_buffer[index])) return _status("failed", "non_finite_instance_buffer_value");
	}
	if (static_cast<int64_t>(packet.batches.size()) >= packet.expected_batch_count ||
			packet.instance_count + instances > packet.expected_instance_count) {
		return _status("failed", "packet_expected_count_exceeded");
	}
	if (packet.reserved_bytes + payload_bytes > MAX_PACKET_BUFFER_BYTES ||
			_staged_payload_bytes + payload_bytes > MAX_STAGED_BUFFER_BYTES ||
			_installed_payload_bytes() + _staged_payload_bytes + _retiring_payload_bytes + payload_bytes > MAX_RESIDENT_BUFFER_BYTES) {
		return _status("backpressure", "staged_packet_payload_capacity");
	}
	Batch batch;
	batch.attachment_key = p_attachment_key;
	batch.id = p_batch_id;
	batch.mesh = owned_mesh;
	batch.material = p_material;
	batch.buffer = p_buffer;
	batch.mesh_payload_bytes = mesh_bytes;
	batch.mesh_content_digest = mesh_digest;
	batch.render_layer = p_render_layer;
	batch.bounds = p_bounds;
	batch.render_tier = p_render_tier;
	batch.cast_shadows = p_cast_shadows;
	batch.intended_visible = p_intended_visible;
	batch.visibility_range = p_visibility_range;
	batch.fade_margin = p_fade_margin;
	packet.batches.push_back(std::move(batch));
	packet.instance_count += instances;
	target_layer->accepted_batch_count++;
	target_layer->accepted_instance_count += instances;
	packet.buffer_bytes += buffer_bytes;
	packet.mesh_payload_bytes += mesh_bytes;
	packet.reserved_bytes += payload_bytes;
	_staged_payload_bytes += payload_bytes;
	Dictionary result = _status("accepted");
	result["batchId"] = p_batch_id;
	result["acceptedBatches"] = static_cast<int64_t>(packet.batches.size());
	result["acceptedInstances"] = packet.instance_count;
	result["stagedBufferBytes"] = packet.buffer_bytes;
	result["stagedMeshPayloadBytes"] = packet.mesh_payload_bytes;
	result["stagedPayloadBytes"] = packet.reserved_bytes;
	return result;
}

Dictionary ChunkRenderPacketBackend::advance_packet(const String &p_source_id,
		int64_t p_generation, int64_t p_max_units) {
	auto found = _staged.find(_key(p_source_id));
	if (found == _staged.end() || !_stage_matches(found->second, p_generation)) return _status("failed", "staged_generation_missing");
	StagedPacket &packet = found->second;
	if (packet.state == "failed") return _status("failed", packet.failure_reason);
	if (packet.state == "ready") return _status("ready_to_commit");
	if (packet.state != "collecting" || p_max_units < 1 || p_max_units > 64) return _status("failed", "invalid_advance_state_or_budget");
	if (static_cast<int64_t>(packet.batches.size()) != packet.expected_batch_count ||
			packet.instance_count != packet.expected_instance_count) {
		return _status("pending", "packet_batches_incomplete");
	}
	for (const StagedPacket::LayerManifestEntry &layer : packet.layers) {
		if (layer.accepted_batch_count != layer.expected_batch_count ||
				layer.accepted_instance_count != layer.expected_instance_count) {
			return _status("pending", "packet_layer_manifest_incomplete");
		}
	}
	int64_t units = 0;
	while (units < p_max_units && packet.upload_cursor < static_cast<int32_t>(packet.batches.size())) {
		Node3D *staging_root = _node3d_for_id(packet.root_instance_id);
		if (staging_root == nullptr || staging_root->get_parent() != this) {
			packet.state = "failed";
			packet.failure_reason = "staging_root_retired";
			return _status("failed", packet.failure_reason);
		}
		Batch &batch = packet.batches[packet.upload_cursor];
		if (!_attachments_valid(packet.attachments, false)) return _status("failed", "attachment_binding_stale");
		if (!batch.attachment_key.is_empty()) staging_root = _node3d_for_id(packet.attachments.at(_key(batch.attachment_key)).root_id);
		int64_t current_mesh_bytes = 0;
		String current_mesh_digest;
		if (!mesh_surface_fingerprint(batch.mesh, current_mesh_bytes, current_mesh_digest) ||
				current_mesh_bytes != batch.mesh_payload_bytes || current_mesh_digest != batch.mesh_content_digest) {
			packet.state = "failed";
			packet.failure_reason = "mesh_content_changed_after_admission";
			return _status("failed", packet.failure_reason);
		}
		Ref<MultiMesh> multi;
		multi.instantiate();
		multi->set_transform_format(MultiMesh::TRANSFORM_3D);
		multi->set_use_colors(true);
		multi->set_use_custom_data(true);
		multi->set_instance_count(batch.buffer.size() / FLOATS_PER_INSTANCE);
		multi->set_mesh(batch.mesh);
		multi->set_custom_aabb(batch.bounds);
		multi->set_buffer(batch.buffer);
		MultiMeshInstance3D *instance = memnew(MultiMeshInstance3D);
		instance->set_name(String("Packet_") + batch.id.validate_node_name());
		instance->set_multimesh(multi);
		instance->set_visible(batch.intended_visible);
		instance->set_material_override(batch.material);
		instance->set_cast_shadows_setting(batch.cast_shadows ?
				GeometryInstance3D::SHADOW_CASTING_SETTING_ON :
				GeometryInstance3D::SHADOW_CASTING_SETTING_OFF);
		instance->set_visibility_range_end(batch.visibility_range);
		instance->set_visibility_range_end_margin(batch.fade_margin);
		instance->set_visibility_range_fade_mode(GeometryInstance3D::VISIBILITY_RANGE_FADE_SELF);
		instance->set_custom_aabb(batch.bounds);
		instance->set_meta("packet_batch_id", batch.id);
		instance->set_meta("packet_render_layer", batch.render_layer);
		instance->set_meta("packet_render_tier", batch.render_tier);
		instance->set_meta("packet_bounds", batch.bounds);
		instance->set_meta("packet_batch_intended_visible", batch.intended_visible);
		staging_root->add_child(instance);
		Dictionary receipt;
		receipt["batchId"] = batch.id;
		receipt["attachmentKey"] = batch.attachment_key;
		receipt["parentRootId"] = static_cast<int64_t>(staging_root->get_instance_id());
		receipt["instanceId"] = static_cast<int64_t>(instance->get_instance_id());
		receipt["multimeshId"] = static_cast<int64_t>(multi->get_instance_id());
		receipt["meshId"] = static_cast<int64_t>(batch.mesh->get_instance_id());
		receipt["meshContentDigest"] = batch.mesh_content_digest;
		receipt["renderLayer"] = batch.render_layer;
		receipt["intendedVisible"] = batch.intended_visible;
		receipt["materialId"] = batch.material.is_valid() ? static_cast<int64_t>(batch.material->get_instance_id()) : 0;
		receipt["bounds"] = batch.bounds;
		receipt["renderTier"] = batch.render_tier;
		receipt["castShadows"] = batch.cast_shadows;
		receipt["visibilityRange"] = batch.visibility_range;
		receipt["fadeMargin"] = batch.fade_margin;
		receipt["instanceCount"] = batch.buffer.size() / FLOATS_PER_INSTANCE;
		receipt["usesColors"] = true;
		receipt["usesCustomData"] = true;
		receipt["bufferBytes"] = static_cast<int64_t>(batch.buffer.size()) * FLOAT_BYTES;
		receipt["meshPayloadBytes"] = batch.mesh_payload_bytes;
		receipt["payloadBytes"] = int64_t(receipt["bufferBytes"]) + batch.mesh_payload_bytes;
		if (!batch.attachment_key.is_empty()) packet.attachments.at(_key(batch.attachment_key)).payload_bytes += int64_t(receipt["payloadBytes"]);
		packet.batch_receipts.push_back(receipt);
		packet.buffer_bytes -= static_cast<int64_t>(batch.buffer.size()) * FLOAT_BYTES;
		batch.buffer.clear();
		packet.upload_cursor++;
		units++;
	}
	if (packet.upload_cursor == static_cast<int32_t>(packet.batches.size())) {
		_build_layer_receipts(packet);
		packet.state = "ready";
	}
	Dictionary result = _status(packet.state == "ready" ? "ready_to_commit" : "pending");
	result["uploadedBatches"] = packet.upload_cursor;
	result["expectedBatches"] = packet.expected_batch_count;
	result["units"] = units;
	result["stagedBufferBytes"] = packet.buffer_bytes;
	result["stagedMeshPayloadBytes"] = packet.mesh_payload_bytes;
	result["stagedPayloadBytes"] = packet.reserved_bytes;
	return result;
}

Dictionary ChunkRenderPacketBackend::commit_packet(const String &p_source_id, int64_t p_generation,
		bool p_await_frame_ack) {
	auto found = _staged.find(_key(p_source_id));
	if (found == _staged.end() || !_stage_matches(found->second, p_generation)) return _status("failed", "staged_generation_missing");
	const std::string key = _key(p_source_id);
	if (_pending_presentations.count(key)) return _status("backpressure", "source_has_pending_presentation");
	StagedPacket &staged = found->second;
	if (staged.state != "ready" || staged.upload_cursor != staged.expected_batch_count ||
			staged.batches.size() != static_cast<size_t>(staged.expected_batch_count) ||
			staged.instance_count != staged.expected_instance_count) {
		return _status(staged.state == "failed" ? "failed" : "pending",
			staged.state == "failed" ? staged.failure_reason : "packet_not_fully_installed");
	}
	if (!_owner_cell_matches_parent(staged.owner_cell)) return _status("failed", "owner_cell_mismatch");
	if (staged.attachment_manifest_declared &&
			!_attachment_manifest_matches(staged.attachments, staged.expected_attachment_manifest))
		return _status("failed", "attachment_manifest_membership_mismatch");
	if (!staged.attachment_manifest_declared) {
		for (const auto &entry : staged.attachments)
			if (entry.second.ownership_kind == "borrowed_presentation")
				return _status("failed", "borrowed_presentation_manifest_required");
	}
	Node3D *staging_root = _node3d_for_id(staged.root_instance_id);
	if (staging_root == nullptr || staging_root->get_parent() != this) return _status("failed", "staging_root_retired");
	auto old = _installed.find(key);
	if (old != _installed.end() && (old->second.owner_cell != staged.owner_cell || old->second.generation >= staged.generation)) {
		return _status("failed", old->second.owner_cell != staged.owner_cell ? "owner_cell_mismatch" : "stale_packet_generation");
	}
	if (old == _installed.end() && static_cast<int32_t>(
			_installed.size() + _pending_presentations.size()) >= MAX_INSTALLED_PACKETS) {
		return _status("backpressure", "installed_packet_capacity");
	}
	InstalledPacket replacement;
	replacement.source_id = staged.source_id;
	replacement.owner_cell = staged.owner_cell;
	replacement.generation = staged.generation;
	replacement.source_revision = staged.source_revision;
	replacement.packet_digest = staged.packet_digest;
	replacement.local_to_chunk = staged.local_to_chunk;
	replacement.root_instance_id = staged.root_instance_id;
	replacement.attachments = staged.attachments;
	replacement.expected_attachment_manifest = staged.expected_attachment_manifest;
	replacement.attachment_manifest_digest = staged.attachment_manifest_digest;
	replacement.attachment_manifest_declared = staged.attachment_manifest_declared;
	_merge_suppressed_legacy(replacement.suppressed_legacy, staged.suppressed_legacy, replacement.attachments);
	if (old != _installed.end()) {
		_merge_suppressed_legacy(replacement.suppressed_legacy, old->second.suppressed_legacy, replacement.attachments);
		_merge_suppressed_legacy(replacement.suppressed_legacy, old->second.attachments, replacement.attachments);
	}
	if (_legacy_claim_count(replacement.attachments, replacement.suppressed_legacy) > MAX_LEGACY_CLAIMS_PER_PACKET)
		return _status("backpressure", "legacy_visual_retention_capacity");
	if (!_attachments_valid(replacement.attachments, false)) return _status("failed", "attachment_binding_stale");
	replacement.batch_receipts = staged.batch_receipts;
	replacement.layer_receipts = staged.layer_receipts;
	replacement.instance_count = staged.instance_count;
	for (const Dictionary &receipt : replacement.batch_receipts) {
		replacement.buffer_bytes += int64_t(receipt.get("bufferBytes", 0));
		replacement.mesh_payload_bytes += int64_t(receipt.get("meshPayloadBytes", 0));
		replacement.payload_bytes += int64_t(receipt.get("payloadBytes", 0));
	}
	const uint64_t old_root_id = old != _installed.end() ? old->second.root_instance_id : 0;
	const int64_t old_payload_bytes = old != _installed.end() ? old->second.payload_bytes - _attachment_payload_bytes(old->second.attachments) : 0;
	if (!p_await_frame_ack) {
		_hide_legacy(replacement.attachments);
		_hide_legacy(replacement.suppressed_legacy);
		if (old != _installed.end()) {
			_show_attachments_transition(old->second.attachments, false, replacement.attachments);
			_retire_attachments(old->second.attachments);
		}
		_show_attachments(replacement.attachments, true);
		staging_root->set_visible(true);
		_installed[key] = replacement;
		staged.root = nullptr;
		staged.root_instance_id = 0;
		_staged_payload_bytes = std::max<int64_t>(0, _staged_payload_bytes - staged.reserved_bytes);
		_staged.erase(found);
		_retire_root(old_root_id, old_payload_bytes);
		return _installed_snapshot(_installed.find(key)->second);
	}
	PendingPresentation pending;
	pending.replacement = replacement;
	pending.has_previous = old != _installed.end();
	pending.replacement_active = false;
	pending.previous_active = pending.has_previous;
	if (pending.has_previous) {
		pending.previous = old->second;
	}
	pending.token = p_source_id.sha256_text().substr(0, 16) + ":" +
		String::num_int64(p_generation) + ":" + String::num_int64(_presentation_sequence + 1) + ":" +
		String::num_int64(static_cast<int64_t>(replacement.root_instance_id));
	_pending_presentations.emplace(key, pending);
	PendingPresentation &transaction = _pending_presentations.find(key)->second;
	// Transfer the borrowed-root activation claim before validating the retained
	// packet. Shared mounts stay visible across this synchronous main-thread
	// transition, so the replacement must already own their active claim while
	// old-only mounts are expected hidden. No frame can observe the intermediate
	// claim change.
	transaction.replacement_active = true;
	transaction.previous_active = false;
	if (transaction.has_previous) {
		Node3D *old_root = _node3d_for_id(transaction.previous.root_instance_id);
		if (old_root) old_root->set_visible(false);
		_show_attachments_transition(transaction.previous.attachments, false, transaction.replacement.attachments);
		// Retained validation checks hidden attachment roots. Evaluate after the
		// synchronous hide, before exposing the fully uploaded replacement.
		transaction.previous_unavailable = old_root == nullptr || old_root->get_parent() != this ||
			String(_installed_snapshot(transaction.previous, true).get("status", "")) != "ready";
	}
	// Candidate show and previous-root hide are one main-thread promotion step;
	// the previous packet remains retained for rollback until frame acceptance.
	_hide_legacy(replacement.attachments);
	_hide_legacy(replacement.suppressed_legacy);
	staging_root->set_visible(true);
	_show_attachments(transaction.replacement.attachments, true);
	_presentation_sequence++;
	transaction.token = p_source_id.sha256_text().substr(0, 16) + ":" +
		String::num_int64(p_generation) + ":" + String::num_int64(_presentation_sequence) + ":" +
		String::num_int64(static_cast<int64_t>(replacement.root_instance_id));
	staged.root = nullptr;
	staged.root_instance_id = 0;
	_staged_payload_bytes = std::max<int64_t>(0, _staged_payload_bytes - staged.reserved_bytes);
	_staged.erase(found);
	Dictionary result = _pending_presentation_snapshot(transaction);
	result["status"] = "pending_presentation";
	return result;
}

Dictionary ChunkRenderPacketBackend::_pending_presentation_snapshot(
		const PendingPresentation &p_pending) const {
	if (p_pending.replacement_owner_lost) {
		Dictionary result = _status("owner_lost", "attachment_replacement_owner_lost");
		result["sourceId"] = p_pending.replacement.source_id;
		result["generation"] = p_pending.replacement.generation;
		result["token"] = p_pending.token; result["candidateQuiesced"] = true;
		result["ownershipReleased"] = false; result["previousUnavailable"] = p_pending.previous_unavailable;
		result["attachmentRoots"] = _attachment_receipts(p_pending.replacement.attachments, false);
		result["attachmentManifestDeclared"] = p_pending.replacement.attachment_manifest_declared;
		result["attachmentManifestDigest"] = p_pending.replacement.attachment_manifest_digest;
		return result;
	}
	if (!_legacy_hidden(p_pending.replacement.attachments)) return _status("failed", "pending_legacy_visibility_changed");
	if (!_suppressed_legacy_hidden(p_pending.replacement.suppressed_legacy)) return _status("failed", "pending_suppressed_legacy_visibility_changed");
	if (p_pending.replacement.attachment_manifest_declared &&
			!_attachment_manifest_matches(p_pending.replacement.attachments,
			p_pending.replacement.expected_attachment_manifest))
		return _status("failed", "pending_attachment_manifest_mismatch");
	if (!_attachments_valid(p_pending.replacement.attachments, true))
		return _status("failed", "pending_attachment_root_set_stale");
	Node3D *candidate_root = _node3d_for_id(p_pending.replacement.root_instance_id);
	if (candidate_root == nullptr || candidate_root->get_parent() != this || !candidate_root->is_visible() ||
			!_owner_cell_matches_parent(p_pending.replacement.owner_cell)) {
		return _status("failed", "pending_presentation_candidate_root_unavailable");
	}
	const bool previous_available = p_pending.has_previous && !p_pending.previous_unavailable &&
		String(_installed_snapshot(p_pending.previous, true).get("status", "")) == "ready";
	if (p_pending.has_previous) {
		Node3D *previous_root = _node3d_for_id(p_pending.previous.root_instance_id);
		if (previous_root && previous_root->is_visible()) {
			return _status("failed", "pending_presentation_previous_root_visible");
		}
	}
	Dictionary candidate_snapshot = _installed_snapshot(p_pending.replacement);
	if (candidate_snapshot.get("status", String()) != String("ready"))
		return _status("failed", "pending_presentation_candidate_manifest_invalid");
	Dictionary result = _status("pending_presentation");
	result["token"] = p_pending.token;
	result["sourceId"] = p_pending.replacement.source_id;
	result["ownerCell"] = p_pending.replacement.owner_cell;
	result["generation"] = p_pending.replacement.generation;
	result["sourceRevision"] = p_pending.replacement.source_revision;
	result["packetDigest"] = p_pending.replacement.packet_digest;
	result["rootInstanceId"] = static_cast<int64_t>(p_pending.replacement.root_instance_id);
	result["attachmentRoots"] = _attachment_receipts(p_pending.replacement.attachments, true);
	result["attachmentManifestDeclared"] = p_pending.replacement.attachment_manifest_declared;
	result["attachmentManifestDigest"] = p_pending.replacement.attachment_manifest_digest;
	result["attachmentManifestCount"] = static_cast<int64_t>(p_pending.replacement.expected_attachment_manifest.size());
	result["previousGeneration"] = p_pending.has_previous ? p_pending.previous.generation : 0;
	result["previousRootInstanceId"] = p_pending.has_previous ?
		static_cast<int64_t>(p_pending.previous.root_instance_id) : 0;
	result["hasPrevious"] = p_pending.has_previous;
	result["previousUnavailable"] = p_pending.has_previous && !previous_available;
	result["batchCount"] = static_cast<int64_t>(p_pending.replacement.batch_receipts.size());
	result["instanceCount"] = p_pending.replacement.instance_count;
	Array layers;
	for (const Dictionary &layer : p_pending.replacement.layer_receipts) {
		layers.push_back(layer);
	}
	result["layers"] = layers;
	result["batches"] = candidate_snapshot.get("batches", Array());
	if (previous_available) {
		Dictionary previous_snapshot = _installed_snapshot(p_pending.previous, true);
		if (previous_snapshot.get("status", String()) != String("ready"))
			return _status("failed", "pending_presentation_previous_packet_manifest_invalid");
		previous_snapshot["status"] = "retained_previous";
		result["previousReceipt"] = previous_snapshot;
	}
	return result;
}

Dictionary ChunkRenderPacketBackend::pending_presentation_snapshot(const String &p_source_id) const {
	auto found = _pending_presentations.find(_key(p_source_id));
	return found == _pending_presentations.end() ? _status("missing") :
		_pending_presentation_snapshot(found->second);
}

Dictionary ChunkRenderPacketBackend::finalize_presentation(const String &p_source_id,
		int64_t p_generation, const String &p_token) {
	const std::string key = _key(p_source_id);
	auto found = _pending_presentations.find(key);
	if (found == _pending_presentations.end()) return _status("failed", "pending_presentation_missing");
	PendingPresentation &pending = found->second;
	if (pending.replacement.generation != p_generation || pending.token != p_token)
		return _status("failed", "pending_presentation_identity_mismatch");
	Dictionary validated = _pending_presentation_snapshot(pending);
	if (validated.get("status", String()) != String("pending_presentation")) return validated;
	const uint64_t old_root_id = pending.has_previous ? pending.previous.root_instance_id : 0;
	const int64_t old_payload_bytes = pending.has_previous ? pending.previous.payload_bytes - _attachment_payload_bytes(pending.previous.attachments) : 0;
	_installed[key] = pending.replacement;
	if (pending.has_previous) _retire_attachments(pending.previous.attachments);
	_pending_presentations.erase(found);
	_retire_root(old_root_id, old_payload_bytes);
	return _installed_snapshot(_installed.find(key)->second);
}

Dictionary ChunkRenderPacketBackend::rollback_presentation(const String &p_source_id,
		int64_t p_generation, const String &p_token) {
	const std::string key = _key(p_source_id);
	auto found = _pending_presentations.find(key);
	if (found == _pending_presentations.end()) return _status("missing");
	PendingPresentation &pending = found->second;
	if (pending.replacement.generation != p_generation || pending.token != p_token)
		return _status("failed", "pending_presentation_identity_mismatch");
	Node3D *candidate_root = _node3d_for_id(pending.replacement.root_instance_id);
	// Failure to restore old geometry must never leave an unaccepted replacement visible.
	// The old claim takes ownership of any shared visible mount before the
	// replacement claim is withdrawn. This keeps `_borrowed_root_active` true
	// throughout rollback's synchronous visibility transition.
	if (pending.has_previous) pending.previous_active = true;
	pending.replacement_active = false;
	_show_attachments_transition(pending.replacement.attachments, false,
		pending.has_previous ? pending.previous.attachments : AttachmentRoots());
	if (candidate_root != nullptr) candidate_root->set_visible(false);
	if (pending.has_previous) {
		// Restore only old borrowed mounts before validation. Previous geometry
		// attachment roots must stay hidden until the old packet is accepted.
		for (const auto &entry : pending.previous.attachments) {
			if (entry.second.ownership_kind != "borrowed_presentation") continue;
			Node3D *root = _node3d_for_id(entry.second.root_id);
			if (root) root->set_visible(entry.second.intended_visible);
		}
		Node3D *previous_root = _node3d_for_id(pending.previous.root_instance_id);
		if (previous_root == nullptr || previous_root->get_parent() != this ||
				!_attachments_valid(pending.previous.attachments, false, false) ||
				String(_installed_snapshot(pending.previous, true).get("status", "")) != "ready") {
			// Door fallback is only a partial restoration of this section. Keep the
			// pending transaction and previous ownership for explicit cleanup/retry.
			_show_attachments(pending.previous.attachments, false);
			pending.previous_active = false;
			if (previous_root != nullptr) previous_root->set_visible(false);
			_restore_legacy(pending.replacement.attachments);
			_restore_legacy(pending.previous.attachments);
			_restore_legacy(pending.replacement.suppressed_legacy);
			_restore_legacy(pending.previous.suppressed_legacy);
			Dictionary result = _status("rollback_failed", "previous_representation_incomplete");
			result["partialLegacyRestoration"] = true;
			result["replacementHidden"] = true;
			result["ownerRetained"] = true;
			result["retryable"] = true;
			result["token"] = pending.token;
			return result;
		}
		_merge_suppressed_legacy(pending.previous.suppressed_legacy, pending.replacement.attachments, pending.previous.attachments);
		_merge_suppressed_legacy(pending.previous.suppressed_legacy, pending.replacement.suppressed_legacy, pending.previous.attachments);
		_hide_legacy(pending.previous.attachments);
		_hide_legacy(pending.previous.suppressed_legacy);
		pending.previous_active = true;
		previous_root->set_visible(true);
		_show_attachments(pending.previous.attachments, true);
		_installed[key] = pending.previous;
	} else {
		_restore_legacy(pending.replacement.attachments);
		_restore_legacy(pending.replacement.suppressed_legacy);
	}
	const uint64_t candidate_root_id = pending.replacement.root_instance_id;
	const int64_t candidate_payload_bytes = pending.replacement.payload_bytes - _attachment_payload_bytes(pending.replacement.attachments);
	const bool had_previous = pending.has_previous;
	const AttachmentRoots released_borrowed = pending.replacement.attachments;
	_retire_attachments(pending.replacement.attachments);
	_pending_presentations.erase(found);
	_retire_root(candidate_root_id, candidate_payload_bytes);
	if (!had_previous) _installed.erase(key);
	_restore_borrowed_source_visibility(released_borrowed);
	return _status("rolled_back");
}

Dictionary ChunkRenderPacketBackend::abort_packet(const String &p_source_id, int64_t p_generation) {
	auto found = _staged.find(_key(p_source_id));
	if (found == _staged.end()) {
		auto cancelled = _owner_loss_cancellations.find(_key(p_source_id));
		if (cancelled != _owner_loss_cancellations.end() && int64_t(cancelled->second.get("generation", 0)) == p_generation &&
				String(cancelled->second.get("status", "")) == "aborted") {
			Dictionary proof = cancelled->second;
			_owner_loss_cancellations.erase(cancelled);
			return proof;
		}
		auto pending = _pending_presentations.find(_key(p_source_id));
		if (pending == _pending_presentations.end() || pending->second.replacement.generation != p_generation)
			return _status("missing");
		return rollback_presentation(p_source_id, p_generation, pending->second.token);
	}
	if (!_stage_matches(found->second, p_generation)) return _status("failed", "staged_generation_mismatch");
	Array released_attachments = _attachment_receipts(found->second.attachments, false);
	const String manifest_digest = found->second.attachment_manifest_digest;
	const bool manifest_declared = found->second.attachment_manifest_declared;
	_release_stage(found);
	Dictionary result = _status("aborted");
	result["sourceId"] = p_source_id; result["generation"] = p_generation;
	result["releasedAttachmentRoots"] = released_attachments;
	result["attachmentManifestDeclared"] = manifest_declared;
	result["attachmentManifestDigest"] = manifest_digest;
	return result;
}

Dictionary ChunkRenderPacketBackend::release_packet(const String &p_source_id, int64_t p_generation) {
	const std::string key = _key(p_source_id);
	if (_pending_presentations.count(key)) return _status("backpressure", "source_has_pending_presentation");
	auto installed = _installed.find(key);
	if (installed == _installed.end()) return _status("released");
	if (installed->second.generation != p_generation) return _status("failed", "installed_generation_mismatch");
	Array released_attachments = _attachment_receipts(installed->second.attachments, false);
	const String manifest_digest = installed->second.attachment_manifest_digest;
	_withdraw_source(key);
	Dictionary result = _status("released");
	result["sourceId"] = p_source_id; result["generation"] = p_generation;
	result["releasedAttachmentRoots"] = released_attachments;
	result["attachmentManifestDigest"] = manifest_digest;
	return result;
}

Dictionary ChunkRenderPacketBackend::_batch_snapshot(const Batch &p_batch, int32_t p_index,
		MultiMeshInstance3D *p_instance) const {
	Dictionary result;
	result["batchId"] = p_batch.id;
	result["index"] = p_index;
	result["instanceId"] = p_instance != nullptr ? static_cast<int64_t>(p_instance->get_instance_id()) : 0;
	result["meshId"] = p_batch.mesh.is_valid() ? static_cast<int64_t>(p_batch.mesh->get_instance_id()) : 0;
	result["materialId"] = p_batch.material.is_valid() ? static_cast<int64_t>(p_batch.material->get_instance_id()) : 0;
	result["bounds"] = p_batch.bounds;
	result["renderTier"] = p_batch.render_tier;
	result["castShadows"] = p_batch.cast_shadows;
	result["visibilityRange"] = p_batch.visibility_range;
	result["fadeMargin"] = p_batch.fade_margin;
	result["renderLayer"] = p_batch.render_layer;
	result["intendedVisible"] = p_batch.intended_visible;
	return result;
}

Dictionary ChunkRenderPacketBackend::_installed_snapshot(const InstalledPacket &p_packet,
		bool p_allow_hidden_root) const {
	if (!p_allow_hidden_root && !_legacy_hidden(p_packet.attachments)) return _status("stale", "installed_legacy_visibility_changed");
	if (!p_allow_hidden_root && !_suppressed_legacy_hidden(p_packet.suppressed_legacy)) return _status("stale", "installed_suppressed_legacy_visibility_changed");
	if (!_attachments_valid(p_packet.attachments, !p_allow_hidden_root, !p_allow_hidden_root)) return _status("stale", "attachment_root_set_stale");
	if (p_packet.attachment_manifest_declared &&
			!_attachment_manifest_matches(p_packet.attachments, p_packet.expected_attachment_manifest))
		return _status("stale", "installed_attachment_manifest_mismatch");
	Node3D *root = _node3d_for_id(p_packet.root_instance_id);
	int64_t root_children = root ? root->get_child_count() : 0;
	for (const auto &entry : p_packet.attachments)
		if (entry.second.ownership_kind == "backend_owned_geometry")
			root_children += _node3d_for_id(entry.second.root_id)->get_child_count();
	if (root_children != static_cast<int64_t>(p_packet.batch_receipts.size())) return _status("stale", "installed_root_set_child_count_mismatch");
	if (root == nullptr || root->get_parent() != this || (!p_allow_hidden_root && !root->is_visible()) ||
			int64_t(root->get_meta("packet_backend_instance_id", 0)) != int64_t(get_instance_id()) ||
			!root->get_transform().is_equal_approx(p_packet.local_to_chunk) ||
			!root->has_meta("packet_source_id") || String(root->get_meta("packet_source_id")) != p_packet.source_id ||
			!root->has_meta("packet_owner_cell") || root->get_meta("packet_owner_cell") != Variant(p_packet.owner_cell) ||
			!root->has_meta("packet_generation") || int64_t(root->get_meta("packet_generation")) != p_packet.generation ||
			!root->has_meta("packet_source_revision") || String(root->get_meta("packet_source_revision")) != p_packet.source_revision ||
			!root->has_meta("packet_digest") || String(root->get_meta("packet_digest")) != p_packet.packet_digest) return _status("stale", "installed_root_missing_or_identity_changed");
	for (int64_t index = 0; index < static_cast<int64_t>(p_packet.batch_receipts.size()); ++index) {
		const Dictionary &expected = p_packet.batch_receipts[index];
		MultiMeshInstance3D *instance = Object::cast_to<MultiMeshInstance3D>(_node3d_for_id(int64_t(expected.get("instanceId", 0))));
		if (instance == nullptr || instance->get_parent() != _node3d_for_id(int64_t(expected.get("parentRootId", p_packet.root_instance_id)))) return _status("stale", "installed_batch_parent_replaced");
		if (instance == nullptr || static_cast<int64_t>(instance->get_instance_id()) != int64_t(expected.get("instanceId", 0))) {
			return _status("stale", "installed_batch_node_replaced");
		}
		Ref<MultiMesh> multi = instance->get_multimesh();
		if (multi.is_null() || static_cast<int64_t>(multi->get_instance_id()) != int64_t(expected.get("multimeshId", 0)) ||
				multi->get_instance_count() != int64_t(expected.get("instanceCount", 0)) ||
				!multi->is_using_colors() || !bool(expected.get("usesColors", false)) ||
				!multi->is_using_custom_data() ||
				!bool(expected.get("usesCustomData", false)) ||
				multi->get_mesh().is_null() || static_cast<int64_t>(multi->get_mesh()->get_instance_id()) != int64_t(expected.get("meshId", 0))) {
			return _status("stale", "installed_batch_resource_replaced");
		}
		int64_t current_mesh_bytes = 0;
		String current_mesh_digest;
		if (!mesh_surface_fingerprint(multi->get_mesh(), current_mesh_bytes, current_mesh_digest) ||
				current_mesh_bytes != int64_t(expected.get("meshPayloadBytes", -1)) ||
				current_mesh_digest != String(expected.get("meshContentDigest", ""))) {
			return _status("stale", "installed_mesh_content_changed");
		}
		Ref<Material> material = instance->get_material_override();
		const int64_t material_id = material.is_valid() ? static_cast<int64_t>(material->get_instance_id()) : 0;
		const Variant actual_bounds = instance->get_meta("packet_bounds", Variant());
		const Variant expected_bounds = expected.get("bounds", Variant());
		const AABB expected_aabb = expected_bounds;
		if (material_id != int64_t(expected.get("materialId", 0)) ||
				instance->get_cast_shadows_setting() != (bool(expected.get("castShadows", true)) ?
					GeometryInstance3D::SHADOW_CASTING_SETTING_ON : GeometryInstance3D::SHADOW_CASTING_SETTING_OFF) ||
				std::abs(instance->get_visibility_range_end() - double(expected.get("visibilityRange", 0.0))) > 0.0001 ||
				std::abs(instance->get_visibility_range_end_margin() - double(expected.get("fadeMargin", 0.0))) > 0.0001 ||
				!instance->has_meta("packet_batch_id") || String(instance->get_meta("packet_batch_id")) != String(expected.get("batchId", "")) ||
				!instance->has_meta("packet_render_layer") || String(instance->get_meta("packet_render_layer")) != String(expected.get("renderLayer", "")) ||
				instance->is_visible() != bool(expected.get("intendedVisible", true)) ||
				!instance->has_meta("packet_batch_intended_visible") || bool(instance->get_meta("packet_batch_intended_visible")) != bool(expected.get("intendedVisible", true)) ||
				!instance->has_meta("packet_render_tier") || String(instance->get_meta("packet_render_tier")) != String(expected.get("renderTier", "")) ||
				!instance->has_meta("packet_bounds") || actual_bounds != expected_bounds ||
				!instance->get_custom_aabb().is_equal_approx(expected_aabb)) {
			return _status("stale", "installed_batch_policy_replaced");
		}
	}
	if (p_packet.layer_receipts.empty()) return _status("stale", "installed_layer_manifest_missing");
	int64_t manifest_batches = 0;
	int64_t manifest_instances = 0;
	for (const Dictionary &layer : p_packet.layer_receipts) {
		const int64_t expected_batches = layer.get("expectedBatchCount", int64_t(-1));
		const int64_t expected_instances = layer.get("expectedInstanceCount", int64_t(-1));
		const String expected_status = expected_batches == 0 ? "empty" : "ready";
		if (!render_layer_supported(String(layer.get("layer", String()))) ||
				String(layer.get("status", String())) != expected_status ||
				String(layer.get("sourceId", String())) != p_packet.source_id ||
				int64_t(layer.get("generation", int64_t(0))) != p_packet.generation ||
				String(layer.get("sourceRevision", String())) != p_packet.source_revision ||
				String(layer.get("packetDigest", String())) != p_packet.packet_digest ||
				expected_batches < 0 || expected_instances < 0 ||
				int64_t(layer.get("installedBatchCount", int64_t(-1))) != expected_batches ||
				int64_t(layer.get("installedInstanceCount", int64_t(-1))) != expected_instances) {
			return _status("stale", "installed_layer_receipt_identity_or_count_mismatch");
		}
		const Array batch_ids = layer.get("batchIds", Array());
		if (batch_ids.size() != expected_batches) return _status("stale", "installed_layer_batch_receipt_mismatch");
		for (int64_t index = 0; index < batch_ids.size(); ++index) {
			const String batch_id = batch_ids[index];
			bool found_batch = false;
			for (const Dictionary &batch : p_packet.batch_receipts) {
				if (String(batch.get("batchId", String())) == batch_id &&
						String(batch.get("renderLayer", String())) == String(layer.get("layer", String()))) {
					found_batch = true;
					break;
				}
			}
			if (!found_batch) return _status("stale", "installed_layer_batch_identity_mismatch");
		}
		manifest_batches += expected_batches;
		manifest_instances += expected_instances;
	}
	if (manifest_batches != static_cast<int64_t>(p_packet.batch_receipts.size()) ||
			manifest_instances != p_packet.instance_count) return _status("stale", "installed_layer_manifest_total_mismatch");
	Dictionary result = _status("ready");
	result["sourceId"] = p_packet.source_id;
	result["ownerCell"] = p_packet.owner_cell;
	result["generation"] = p_packet.generation;
	result["sourceRevision"] = p_packet.source_revision;
	result["packetDigest"] = p_packet.packet_digest;
	result["localToChunk"] = p_packet.local_to_chunk;
	result["rootInstanceId"] = static_cast<int64_t>(root->get_instance_id());
	result["attachmentRoots"] = _attachment_receipts(p_packet.attachments, !p_allow_hidden_root);
	result["attachmentManifestDeclared"] = p_packet.attachment_manifest_declared;
	result["attachmentManifestDigest"] = p_packet.attachment_manifest_digest;
	result["attachmentManifestCount"] = static_cast<int64_t>(p_packet.expected_attachment_manifest.size());
	result["expectedBatchCount"] = static_cast<int64_t>(p_packet.batch_receipts.size());
	result["expectedLayerCount"] = static_cast<int64_t>(p_packet.layer_receipts.size());
	result["instanceCount"] = p_packet.instance_count;
	result["bufferBytes"] = p_packet.buffer_bytes;
	result["meshPayloadBytes"] = p_packet.mesh_payload_bytes;
	result["payloadBytes"] = p_packet.payload_bytes;
	Array batches;
	for (const Dictionary &receipt : p_packet.batch_receipts) batches.push_back(receipt);
	result["batches"] = batches;
	Array layers;
	for (const Dictionary &receipt : p_packet.layer_receipts) layers.push_back(receipt);
	result["layers"] = layers;
	return result;
}

Dictionary ChunkRenderPacketBackend::installed_snapshot(const String &p_source_id) const {
	auto found = _installed.find(_key(p_source_id));
	return found == _installed.end() ? _status("missing") : _installed_snapshot(found->second);
}

bool ChunkRenderPacketBackend::receipt_installed(const String &p_source_id, int64_t p_generation,
		const String &p_source_revision, const String &p_packet_digest) const {
	auto found = _installed.find(_key(p_source_id));
	if (found == _installed.end()) return false;
	const InstalledPacket &packet = found->second;
	if (packet.generation != p_generation || packet.source_revision != p_source_revision ||
			packet.packet_digest != p_packet_digest || !_owner_cell_matches_parent(packet.owner_cell)) {
		return false;
	}
	const bool is_retained_previous = [&]() {
		auto pending = _pending_presentations.find(_key(p_source_id));
		return pending != _pending_presentations.end() && pending->second.has_previous &&
			pending->second.previous.generation == p_generation &&
			pending->second.previous.source_revision == p_source_revision &&
			pending->second.previous.packet_digest == p_packet_digest;
	}();
	return String(_installed_snapshot(packet, is_retained_previous).get("status", "")) == "ready";
}

Dictionary ChunkRenderPacketBackend::metrics() const {
	int64_t installed_packets = 0;
	int64_t installed_batches = 0;
	int64_t installed_instances = 0;
	int64_t installed_bytes = 0;
	int64_t installed_buffer_bytes = 0;
	int64_t installed_mesh_bytes = 0;
	int64_t staged_packets = 0;
	int64_t staged_batches = 0;
	int64_t staged_instances = 0;
	int64_t staged_buffer_bytes = 0;
	int64_t staged_mesh_bytes = 0;
	int64_t pending_presentations = 0;
	int64_t pending_presentation_bytes = 0;
	for (const auto &entry : _installed) {
		installed_packets++;
		installed_batches += entry.second.batch_receipts.size();
		installed_instances += entry.second.instance_count;
		installed_bytes += entry.second.payload_bytes;
		installed_buffer_bytes += entry.second.buffer_bytes;
		installed_mesh_bytes += entry.second.mesh_payload_bytes;
	}
	for (const auto &entry : _staged) {
		staged_packets++;
		staged_batches += entry.second.batches.size();
		staged_instances += entry.second.instance_count;
		staged_buffer_bytes += entry.second.buffer_bytes;
		staged_mesh_bytes += entry.second.mesh_payload_bytes;
	}
	for (const auto &entry : _pending_presentations) {
		pending_presentations++;
		pending_presentation_bytes += entry.second.replacement.payload_bytes;
	}
	Dictionary result;
	result["installedPackets"] = installed_packets;
	result["installedBatches"] = installed_batches;
	result["installedInstances"] = installed_instances;
	result["installedBytes"] = installed_bytes;
	result["stagedPackets"] = staged_packets;
	result["stagedBatches"] = staged_batches;
	result["stagedInstances"] = staged_instances;
	result["stagedBufferBytes"] = staged_buffer_bytes;
	result["stagedMeshPayloadBytes"] = staged_mesh_bytes;
	result["stagedPayloadBytes"] = _staged_payload_bytes;
	result["pendingPresentations"] = pending_presentations;
	result["pendingPresentationBytes"] = pending_presentation_bytes;
	result["retiringPayloadBytes"] = _retiring_payload_bytes;
	result["residentPayloadBytes"] = installed_bytes + pending_presentation_bytes +
		_staged_payload_bytes + _retiring_payload_bytes;
	result["installedInstanceBufferBytes"] = installed_buffer_bytes;
	result["installedMeshPayloadBytes"] = installed_mesh_bytes;
	result["retiringRoots"] = _retiring_roots;
	result["maxBatchInstances"] = MAX_BATCH_INSTANCES;
	result["maxPacketBatches"] = MAX_PACKET_BATCHES;
	result["maxPacketBufferBytes"] = MAX_PACKET_BUFFER_BYTES;
	result["maxStagedBufferBytes"] = MAX_STAGED_BUFFER_BYTES;
	result["maxResidentBufferBytes"] = MAX_RESIDENT_BUFFER_BYTES;
	result["maxInstalledPackets"] = MAX_INSTALLED_PACKETS;
	result["maxLegacyVisualClaimsPerPacket"] = MAX_LEGACY_CLAIMS_PER_PACKET;
	result["maxAttachmentManifestMembers"] = MAX_ATTACHMENT_MANIFEST_MEMBERS;
	result["unacknowledgedCancellations"] = static_cast<int64_t>(_owner_loss_cancellations.size());
	return result;
}
