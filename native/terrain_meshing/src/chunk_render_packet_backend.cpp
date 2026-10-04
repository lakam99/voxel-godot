#include "chunk_render_packet_backend.h"

#include <godot_cpp/classes/geometry_instance3d.hpp>
#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/core/object.hpp>
#include <godot_cpp/variant/array.hpp>
#include <godot_cpp/variant/callable.hpp>
#include <godot_cpp/variant/string_name.hpp>
#include <godot_cpp/variant/utility_functions.hpp>

#include <algorithm>
#include <cmath>
#include <string>

using namespace godot;

namespace {
constexpr int64_t FLOAT_BYTES = 4;

bool tier_supported(const String &p_tier) {
	return p_tier == "silhouette" || p_tier == "structural" || p_tier == "detail" || p_tier == "horizon";
}

bool transform_finite(const Transform3D &p_transform) {
	const Basis basis = p_transform.get_basis();
	const Vector3 columns[] = {basis.get_column(0), basis.get_column(1), basis.get_column(2), p_transform.get_origin()};
	for (const Vector3 &column : columns) {
		if (!std::isfinite(column.x) || !std::isfinite(column.y) || !std::isfinite(column.z)) return false;
	}
	return true;
}
}

void ChunkRenderPacketBackend::_bind_methods() {
	ClassDB::bind_method(D_METHOD("begin_packet", "source_id", "owner_cell", "generation", "source_revision", "packet_digest", "local_to_chunk", "expected_batch_count", "expected_instance_count"), &ChunkRenderPacketBackend::begin_packet);
	ClassDB::bind_method(D_METHOD("append_batch", "source_id", "generation", "batch_id", "mesh", "material", "buffer", "bounds", "render_tier", "cast_shadows", "visibility_range", "fade_margin"), &ChunkRenderPacketBackend::append_batch);
	ClassDB::bind_method(D_METHOD("advance_packet", "source_id", "generation", "max_units"), &ChunkRenderPacketBackend::advance_packet, DEFVAL(1));
	ClassDB::bind_method(D_METHOD("commit_packet", "source_id", "generation"), &ChunkRenderPacketBackend::commit_packet);
	ClassDB::bind_method(D_METHOD("abort_packet", "source_id", "generation"), &ChunkRenderPacketBackend::abort_packet);
	ClassDB::bind_method(D_METHOD("release_packet", "source_id", "generation"), &ChunkRenderPacketBackend::release_packet);
	ClassDB::bind_method(D_METHOD("installed_snapshot", "source_id"), &ChunkRenderPacketBackend::installed_snapshot);
	ClassDB::bind_method(D_METHOD("receipt_installed", "source_id", "generation", "source_revision", "packet_digest"), &ChunkRenderPacketBackend::receipt_installed);
	ClassDB::bind_method(D_METHOD("metrics"), &ChunkRenderPacketBackend::metrics);
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

int64_t ChunkRenderPacketBackend::_installed_buffer_bytes() const {
	int64_t result = 0;
	for (const auto &entry : _installed) result += entry.second.buffer_bytes;
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
	_retire_root(r_packet.root_instance_id);
	r_packet.root = nullptr;
	r_packet.root_instance_id = 0;
}

void ChunkRenderPacketBackend::_retire_root(uint64_t p_root_id) {
	Node3D *root = _node3d_for_id(p_root_id);
	if (root == nullptr) return;
	root->set_visible(false);
	Callable exiting = callable_mp(this, &ChunkRenderPacketBackend::_on_retired_root_exiting);
	if (!root->is_connected("tree_exiting", exiting)) root->connect("tree_exiting", exiting, Object::CONNECT_ONE_SHOT);
	root->queue_free();
	_retiring_roots++;
}

void ChunkRenderPacketBackend::_on_retired_root_exiting() {
	_retiring_roots = std::max<int64_t>(0, _retiring_roots - 1);
}

void ChunkRenderPacketBackend::_release_stage(std::map<std::string, StagedPacket>::iterator p_it) {
	if (p_it == _staged.end()) return;
	_staged_buffer_bytes = std::max<int64_t>(0, _staged_buffer_bytes - p_it->second.reserved_bytes);
	_free_staging_root(p_it->second);
	_staged.erase(p_it);
}

Dictionary ChunkRenderPacketBackend::begin_packet(const String &p_source_id,
		const Vector2i &p_owner_cell, int64_t p_generation,
		const String &p_source_revision, const String &p_packet_digest,
		const Transform3D &p_local_to_chunk, int64_t p_expected_batch_count,
		int64_t p_expected_instance_count) {
	if (p_source_id.strip_edges().is_empty() || p_source_revision.strip_edges().is_empty() ||
			p_packet_digest.strip_edges().is_empty() || p_generation <= 0 ||
			p_expected_batch_count < 0 || p_expected_batch_count > MAX_PACKET_BATCHES ||
			p_expected_instance_count < 0 || p_expected_instance_count > MAX_PACKET_BATCHES * MAX_BATCH_INSTANCES ||
			((p_expected_batch_count == 0) != (p_expected_instance_count == 0)) ||
			!transform_finite(p_local_to_chunk) || !is_inside_tree() || !_owner_cell_matches_parent(p_owner_cell)) {
		return _status("failed", "invalid_packet_header_or_owner_cell");
	}
	const std::string key = _key(p_source_id);
	auto staged = _staged.find(key);
	if (staged != _staged.end()) {
		const StagedPacket &current = staged->second;
		if (current.generation == p_generation && current.owner_cell == p_owner_cell &&
				current.source_revision == p_source_revision && current.packet_digest == p_packet_digest &&
				current.local_to_chunk.is_equal_approx(p_local_to_chunk) &&
				current.expected_batch_count == p_expected_batch_count &&
				current.expected_instance_count == p_expected_instance_count) {
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
	packet.state = p_expected_batch_count == 0 && p_expected_instance_count == 0 ? "ready" : "collecting";
	packet.root = memnew(Node3D);
	packet.root->set_name(String("StagedPacket_") + p_source_id.validate_node_name() + "_" + String::num_int64(p_generation));
	packet.root->set_transform(p_local_to_chunk);
	packet.root->set_visible(false);
	packet.root->set_meta("packet_source_id", p_source_id);
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

Dictionary ChunkRenderPacketBackend::append_batch(const String &p_source_id,
		int64_t p_generation, const String &p_batch_id, const Ref<Mesh> &p_mesh,
		const Ref<Material> &p_material, const PackedFloat32Array &p_buffer,
		const AABB &p_bounds, const String &p_render_tier, bool p_cast_shadows,
		double p_visibility_range, double p_fade_margin) {
	auto found = _staged.find(_key(p_source_id));
	if (found == _staged.end() || !_stage_matches(found->second, p_generation)) return _status("failed", "staged_generation_missing");
	StagedPacket &packet = found->second;
	if (packet.state != "collecting") return _status("failed", "packet_not_collecting");
	Node3D *staging_root = _node3d_for_id(packet.root_instance_id);
	if (staging_root == nullptr || staging_root->get_parent() != this) return _status("failed", "staging_root_retired");
	if (p_batch_id.strip_edges().is_empty() || p_mesh.is_null() || p_buffer.is_empty() ||
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
	const int64_t bytes = static_cast<int64_t>(p_buffer.size()) * FLOAT_BYTES;
	for (int64_t index = 0; index < p_buffer.size(); ++index) {
		if (!std::isfinite(p_buffer[index])) return _status("failed", "non_finite_instance_buffer_value");
	}
	if (static_cast<int64_t>(packet.batches.size()) >= packet.expected_batch_count ||
			packet.instance_count + instances > packet.expected_instance_count) {
		return _status("failed", "packet_expected_count_exceeded");
	}
	if (packet.reserved_bytes + bytes > MAX_PACKET_BUFFER_BYTES ||
			_staged_buffer_bytes + bytes > MAX_STAGED_BUFFER_BYTES ||
			_installed_buffer_bytes() + _staged_buffer_bytes + bytes > MAX_RESIDENT_BUFFER_BYTES) {
		return _status("backpressure", "staged_packet_buffer_capacity");
	}
	Batch batch;
	batch.id = p_batch_id;
	batch.mesh = p_mesh;
	batch.material = p_material;
	batch.buffer = p_buffer;
	batch.bounds = p_bounds;
	batch.render_tier = p_render_tier;
	batch.cast_shadows = p_cast_shadows;
	batch.visibility_range = p_visibility_range;
	batch.fade_margin = p_fade_margin;
	packet.batches.push_back(std::move(batch));
	packet.instance_count += instances;
	packet.buffer_bytes += bytes;
	packet.reserved_bytes += bytes;
	_staged_buffer_bytes += bytes;
	Dictionary result = _status("accepted");
	result["batchId"] = p_batch_id;
	result["acceptedBatches"] = static_cast<int64_t>(packet.batches.size());
	result["acceptedInstances"] = packet.instance_count;
	result["stagedBytes"] = packet.buffer_bytes;
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
	int64_t units = 0;
	while (units < p_max_units && packet.upload_cursor < static_cast<int32_t>(packet.batches.size())) {
		Node3D *staging_root = _node3d_for_id(packet.root_instance_id);
		if (staging_root == nullptr || staging_root->get_parent() != this) {
			packet.state = "failed";
			packet.failure_reason = "staging_root_retired";
			return _status("failed", packet.failure_reason);
		}
		Batch &batch = packet.batches[packet.upload_cursor];
		Ref<MultiMesh> multi;
		multi.instantiate();
		multi->set_transform_format(MultiMesh::TRANSFORM_3D);
		multi->set_use_custom_data(true);
		multi->set_instance_count(batch.buffer.size() / FLOATS_PER_INSTANCE);
		multi->set_mesh(batch.mesh);
		multi->set_custom_aabb(batch.bounds);
		multi->set_buffer(batch.buffer);
		MultiMeshInstance3D *instance = memnew(MultiMeshInstance3D);
		instance->set_name(String("Packet_") + batch.id.validate_node_name());
		instance->set_multimesh(multi);
		instance->set_material_override(batch.material);
		instance->set_cast_shadows_setting(batch.cast_shadows ?
				GeometryInstance3D::SHADOW_CASTING_SETTING_ON :
				GeometryInstance3D::SHADOW_CASTING_SETTING_OFF);
		instance->set_visibility_range_end(batch.visibility_range);
		instance->set_visibility_range_end_margin(batch.fade_margin);
		instance->set_visibility_range_fade_mode(GeometryInstance3D::VISIBILITY_RANGE_FADE_SELF);
		instance->set_custom_aabb(batch.bounds);
		instance->set_meta("packet_batch_id", batch.id);
		instance->set_meta("packet_render_tier", batch.render_tier);
		instance->set_meta("packet_bounds", batch.bounds);
		staging_root->add_child(instance);
		Dictionary receipt;
		receipt["batchId"] = batch.id;
		receipt["instanceId"] = static_cast<int64_t>(instance->get_instance_id());
		receipt["multimeshId"] = static_cast<int64_t>(multi->get_instance_id());
		receipt["meshId"] = static_cast<int64_t>(batch.mesh->get_instance_id());
		receipt["materialId"] = batch.material.is_valid() ? static_cast<int64_t>(batch.material->get_instance_id()) : 0;
		receipt["bounds"] = batch.bounds;
		receipt["renderTier"] = batch.render_tier;
		receipt["castShadows"] = batch.cast_shadows;
		receipt["visibilityRange"] = batch.visibility_range;
		receipt["fadeMargin"] = batch.fade_margin;
		receipt["instanceCount"] = batch.buffer.size() / FLOATS_PER_INSTANCE;
		receipt["bufferBytes"] = static_cast<int64_t>(batch.buffer.size()) * FLOAT_BYTES;
		packet.batch_receipts.push_back(receipt);
		packet.buffer_bytes -= static_cast<int64_t>(batch.buffer.size()) * FLOAT_BYTES;
		batch.buffer.clear();
		packet.upload_cursor++;
		units++;
	}
	if (packet.upload_cursor == static_cast<int32_t>(packet.batches.size())) packet.state = "ready";
	Dictionary result = _status(packet.state == "ready" ? "ready_to_commit" : "pending");
	result["uploadedBatches"] = packet.upload_cursor;
	result["expectedBatches"] = packet.expected_batch_count;
	result["units"] = units;
	result["stagedBufferBytes"] = packet.buffer_bytes;
	return result;
}

Dictionary ChunkRenderPacketBackend::commit_packet(const String &p_source_id, int64_t p_generation) {
	auto found = _staged.find(_key(p_source_id));
	if (found == _staged.end() || !_stage_matches(found->second, p_generation)) return _status("failed", "staged_generation_missing");
	StagedPacket &staged = found->second;
	if (staged.state != "ready" || staged.upload_cursor != staged.expected_batch_count ||
			staged.batches.size() != static_cast<size_t>(staged.expected_batch_count) ||
			staged.instance_count != staged.expected_instance_count) {
		return _status(staged.state == "failed" ? "failed" : "pending",
			staged.state == "failed" ? staged.failure_reason : "packet_not_fully_installed");
	}
	if (!_owner_cell_matches_parent(staged.owner_cell)) return _status("failed", "owner_cell_mismatch");
	Node3D *staging_root = _node3d_for_id(staged.root_instance_id);
	if (staging_root == nullptr || staging_root->get_parent() != this) return _status("failed", "staging_root_retired");
	auto old = _installed.find(_key(p_source_id));
	if (old != _installed.end() && (old->second.owner_cell != staged.owner_cell || old->second.generation >= staged.generation)) {
		return _status("failed", old->second.owner_cell != staged.owner_cell ? "owner_cell_mismatch" : "stale_packet_generation");
	}
	if (old == _installed.end() && static_cast<int32_t>(_installed.size()) >= MAX_INSTALLED_PACKETS) {
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
	replacement.batch_receipts = staged.batch_receipts;
	replacement.instance_count = staged.instance_count;
	for (const Dictionary &receipt : replacement.batch_receipts) replacement.buffer_bytes += int64_t(receipt.get("bufferBytes", 0));
	staging_root->set_visible(true);
	const uint64_t old_root_id = old != _installed.end() ? old->second.root_instance_id : 0;
	_installed[_key(p_source_id)] = replacement;
	staged.root = nullptr;
	staged.root_instance_id = 0;
	_staged_buffer_bytes = std::max<int64_t>(0, _staged_buffer_bytes - staged.reserved_bytes);
	_staged.erase(found);
	_retire_root(old_root_id);
	return _installed_snapshot(_installed.find(_key(p_source_id))->second);
}

Dictionary ChunkRenderPacketBackend::abort_packet(const String &p_source_id, int64_t p_generation) {
	auto found = _staged.find(_key(p_source_id));
	if (found == _staged.end()) return _status("missing");
	if (!_stage_matches(found->second, p_generation)) return _status("failed", "staged_generation_mismatch");
	_release_stage(found);
	return _status("aborted");
}

Dictionary ChunkRenderPacketBackend::release_packet(const String &p_source_id, int64_t p_generation) {
	const std::string key = _key(p_source_id);
	auto installed = _installed.find(key);
	if (installed == _installed.end()) return _status("released");
	if (installed->second.generation != p_generation) return _status("failed", "installed_generation_mismatch");
	_retire_root(installed->second.root_instance_id);
	_installed.erase(installed);
	return _status("released");
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
	return result;
}

Dictionary ChunkRenderPacketBackend::_installed_snapshot(const InstalledPacket &p_packet) const {
	Node3D *root = _node3d_for_id(p_packet.root_instance_id);
	if (root == nullptr || root->get_parent() != this || !root->is_visible() ||
			!root->get_transform().is_equal_approx(p_packet.local_to_chunk) ||
			root->get_child_count() != static_cast<int64_t>(p_packet.batch_receipts.size()) ||
			!root->has_meta("packet_source_id") || String(root->get_meta("packet_source_id")) != p_packet.source_id ||
			!root->has_meta("packet_owner_cell") || root->get_meta("packet_owner_cell") != Variant(p_packet.owner_cell) ||
			!root->has_meta("packet_generation") || int64_t(root->get_meta("packet_generation")) != p_packet.generation ||
			!root->has_meta("packet_source_revision") || String(root->get_meta("packet_source_revision")) != p_packet.source_revision ||
			!root->has_meta("packet_digest") || String(root->get_meta("packet_digest")) != p_packet.packet_digest) return _status("stale", "installed_root_missing_or_identity_changed");
	for (int64_t index = 0; index < static_cast<int64_t>(p_packet.batch_receipts.size()); ++index) {
		const Dictionary &expected = p_packet.batch_receipts[index];
		MultiMeshInstance3D *instance = Object::cast_to<MultiMeshInstance3D>(root->get_child(index));
		if (instance == nullptr || static_cast<int64_t>(instance->get_instance_id()) != int64_t(expected.get("instanceId", 0))) {
			return _status("stale", "installed_batch_node_replaced");
		}
		Ref<MultiMesh> multi = instance->get_multimesh();
		if (multi.is_null() || static_cast<int64_t>(multi->get_instance_id()) != int64_t(expected.get("multimeshId", 0)) ||
				multi->get_instance_count() != int64_t(expected.get("instanceCount", 0)) ||
				!multi->is_using_custom_data() ||
				multi->get_mesh().is_null() || static_cast<int64_t>(multi->get_mesh()->get_instance_id()) != int64_t(expected.get("meshId", 0))) {
			return _status("stale", "installed_batch_resource_replaced");
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
				!instance->has_meta("packet_render_tier") || String(instance->get_meta("packet_render_tier")) != String(expected.get("renderTier", "")) ||
				!instance->has_meta("packet_bounds") || actual_bounds != expected_bounds ||
				!instance->get_custom_aabb().is_equal_approx(expected_aabb)) {
			return _status("stale", "installed_batch_policy_replaced");
		}
	}
	Dictionary result = _status("ready");
	result["sourceId"] = p_packet.source_id;
	result["ownerCell"] = p_packet.owner_cell;
	result["generation"] = p_packet.generation;
	result["sourceRevision"] = p_packet.source_revision;
	result["packetDigest"] = p_packet.packet_digest;
	result["localToChunk"] = p_packet.local_to_chunk;
	result["rootInstanceId"] = static_cast<int64_t>(root->get_instance_id());
	result["expectedBatchCount"] = static_cast<int64_t>(p_packet.batch_receipts.size());
	result["instanceCount"] = p_packet.instance_count;
	result["bufferBytes"] = p_packet.buffer_bytes;
	Array batches;
	for (const Dictionary &receipt : p_packet.batch_receipts) batches.push_back(receipt);
	result["batches"] = batches;
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
	return packet.generation == p_generation && packet.source_revision == p_source_revision &&
		packet.packet_digest == p_packet_digest && _owner_cell_matches_parent(packet.owner_cell) &&
		String(_installed_snapshot(packet).get("status", "")) == "ready";
}

Dictionary ChunkRenderPacketBackend::metrics() const {
	int64_t installed_packets = 0;
	int64_t installed_batches = 0;
	int64_t installed_instances = 0;
	int64_t installed_bytes = 0;
	int64_t staged_packets = 0;
	int64_t staged_batches = 0;
	int64_t staged_instances = 0;
	for (const auto &entry : _installed) {
		installed_packets++;
		installed_batches += entry.second.batch_receipts.size();
		installed_instances += entry.second.instance_count;
		installed_bytes += entry.second.buffer_bytes;
	}
	for (const auto &entry : _staged) {
		staged_packets++;
		staged_batches += entry.second.batches.size();
		staged_instances += entry.second.instance_count;
	}
	Dictionary result;
	result["installedPackets"] = installed_packets;
	result["installedBatches"] = installed_batches;
	result["installedInstances"] = installed_instances;
	result["installedBytes"] = installed_bytes;
	result["stagedPackets"] = staged_packets;
	result["stagedBatches"] = staged_batches;
	result["stagedInstances"] = staged_instances;
	result["stagedBufferBytes"] = _staged_buffer_bytes;
	result["retiringRoots"] = _retiring_roots;
	result["maxBatchInstances"] = MAX_BATCH_INSTANCES;
	result["maxPacketBatches"] = MAX_PACKET_BATCHES;
	result["maxPacketBufferBytes"] = MAX_PACKET_BUFFER_BYTES;
	result["maxStagedBufferBytes"] = MAX_STAGED_BUFFER_BYTES;
	result["maxResidentBufferBytes"] = MAX_RESIDENT_BUFFER_BYTES;
	result["maxInstalledPackets"] = MAX_INSTALLED_PACKETS;
	return result;
}
