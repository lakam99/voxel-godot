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
}

void ChunkRenderPacketBackend::_bind_methods() {
	ClassDB::bind_method(D_METHOD("begin_packet", "source_id", "owner_cell", "generation", "source_revision", "packet_digest", "local_to_chunk", "expected_batch_count", "expected_instance_count"), &ChunkRenderPacketBackend::begin_packet);
	ClassDB::bind_method(D_METHOD("begin_packet_with_layers", "source_id", "owner_cell", "generation", "source_revision", "packet_digest", "local_to_chunk", "expected_batch_count", "expected_instance_count", "expected_layers"), &ChunkRenderPacketBackend::begin_packet_with_layers);
	ClassDB::bind_method(D_METHOD("append_batch", "source_id", "generation", "batch_id", "mesh", "expected_mesh_content_digest", "material", "buffer", "bounds", "render_tier", "cast_shadows", "visibility_range", "fade_margin"), &ChunkRenderPacketBackend::append_batch);
	ClassDB::bind_method(D_METHOD("append_batch_in_layer", "source_id", "generation", "batch_id", "mesh", "expected_mesh_content_digest", "material", "buffer", "bounds", "render_tier", "cast_shadows", "visibility_range", "fade_margin", "render_layer"), &ChunkRenderPacketBackend::append_batch_in_layer);
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

int64_t ChunkRenderPacketBackend::_installed_payload_bytes() const {
	int64_t result = 0;
	for (const auto &entry : _installed) result += entry.second.payload_bytes;
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
	_retire_root(r_packet.root_instance_id, r_packet.reserved_bytes);
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
		const String &p_expected_mesh_content_digest,
		const Ref<Material> &p_material, const PackedFloat32Array &p_buffer,
		const AABB &p_bounds, const String &p_render_tier, bool p_cast_shadows,
		double p_visibility_range, double p_fade_margin) {
	return _append_batch(p_source_id, p_generation, p_batch_id, p_mesh,
		p_expected_mesh_content_digest, p_material, p_buffer, p_bounds,
		p_render_tier, p_cast_shadows, p_visibility_range, p_fade_margin, "opaque");
}

Dictionary ChunkRenderPacketBackend::append_batch_in_layer(const String &p_source_id,
		int64_t p_generation, const String &p_batch_id, const Ref<Mesh> &p_mesh,
		const String &p_expected_mesh_content_digest,
		const Ref<Material> &p_material, const PackedFloat32Array &p_buffer,
		const AABB &p_bounds, const String &p_render_tier, bool p_cast_shadows,
		double p_visibility_range, double p_fade_margin, const String &p_render_layer) {
	return _append_batch(p_source_id, p_generation, p_batch_id, p_mesh,
		p_expected_mesh_content_digest, p_material, p_buffer, p_bounds,
		p_render_tier, p_cast_shadows, p_visibility_range, p_fade_margin, p_render_layer);
}

Dictionary ChunkRenderPacketBackend::_append_batch(const String &p_source_id,
		int64_t p_generation, const String &p_batch_id, const Ref<Mesh> &p_mesh,
		const String &p_expected_mesh_content_digest,
		const Ref<Material> &p_material, const PackedFloat32Array &p_buffer,
		const AABB &p_bounds, const String &p_render_tier, bool p_cast_shadows,
		double p_visibility_range, double p_fade_margin, const String &p_render_layer) {
	auto found = _staged.find(_key(p_source_id));
	if (found == _staged.end() || !_stage_matches(found->second, p_generation)) return _status("failed", "staged_generation_missing");
	StagedPacket &packet = found->second;
	if (packet.state != "collecting") return _status("failed", "packet_not_collecting");
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
		staging_root->add_child(instance);
		Dictionary receipt;
		receipt["batchId"] = batch.id;
		receipt["instanceId"] = static_cast<int64_t>(instance->get_instance_id());
		receipt["multimeshId"] = static_cast<int64_t>(multi->get_instance_id());
		receipt["meshId"] = static_cast<int64_t>(batch.mesh->get_instance_id());
		receipt["meshContentDigest"] = batch.mesh_content_digest;
		receipt["renderLayer"] = batch.render_layer;
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
	replacement.layer_receipts = staged.layer_receipts;
	replacement.instance_count = staged.instance_count;
	for (const Dictionary &receipt : replacement.batch_receipts) {
		replacement.buffer_bytes += int64_t(receipt.get("bufferBytes", 0));
		replacement.mesh_payload_bytes += int64_t(receipt.get("meshPayloadBytes", 0));
		replacement.payload_bytes += int64_t(receipt.get("payloadBytes", 0));
	}
	staging_root->set_visible(true);
	const uint64_t old_root_id = old != _installed.end() ? old->second.root_instance_id : 0;
	const int64_t old_payload_bytes = old != _installed.end() ? old->second.payload_bytes : 0;
	_installed[_key(p_source_id)] = replacement;
	staged.root = nullptr;
	staged.root_instance_id = 0;
	_staged_payload_bytes = std::max<int64_t>(0, _staged_payload_bytes - staged.reserved_bytes);
	_staged.erase(found);
	_retire_root(old_root_id, old_payload_bytes);
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
	_retire_root(installed->second.root_instance_id, installed->second.payload_bytes);
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
	result["renderLayer"] = p_batch.render_layer;
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
	return packet.generation == p_generation && packet.source_revision == p_source_revision &&
		packet.packet_digest == p_packet_digest && _owner_cell_matches_parent(packet.owner_cell) &&
		String(_installed_snapshot(packet).get("status", "")) == "ready";
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
	result["retiringPayloadBytes"] = _retiring_payload_bytes;
	result["residentPayloadBytes"] = installed_bytes + _staged_payload_bytes + _retiring_payload_bytes;
	result["installedInstanceBufferBytes"] = installed_buffer_bytes;
	result["installedMeshPayloadBytes"] = installed_mesh_bytes;
	result["retiringRoots"] = _retiring_roots;
	result["maxBatchInstances"] = MAX_BATCH_INSTANCES;
	result["maxPacketBatches"] = MAX_PACKET_BATCHES;
	result["maxPacketBufferBytes"] = MAX_PACKET_BUFFER_BYTES;
	result["maxStagedBufferBytes"] = MAX_STAGED_BUFFER_BYTES;
	result["maxResidentBufferBytes"] = MAX_RESIDENT_BUFFER_BYTES;
	result["maxInstalledPackets"] = MAX_INSTALLED_PACKETS;
	return result;
}
