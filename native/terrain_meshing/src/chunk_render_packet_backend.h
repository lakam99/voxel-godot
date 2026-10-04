#ifndef CHUNK_RENDER_PACKET_BACKEND_H
#define CHUNK_RENDER_PACKET_BACKEND_H

#include <godot_cpp/classes/material.hpp>
#include <godot_cpp/classes/mesh.hpp>
#include <godot_cpp/classes/multi_mesh.hpp>
#include <godot_cpp/classes/multi_mesh_instance3d.hpp>
#include <godot_cpp/classes/node3d.hpp>
#include <godot_cpp/variant/aabb.hpp>
#include <godot_cpp/variant/array.hpp>
#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/packed_byte_array.hpp>
#include <godot_cpp/variant/packed_color_array.hpp>
#include <godot_cpp/variant/packed_float32_array.hpp>
#include <godot_cpp/variant/packed_float64_array.hpp>
#include <godot_cpp/variant/packed_int32_array.hpp>
#include <godot_cpp/variant/packed_int64_array.hpp>
#include <godot_cpp/variant/packed_vector2_array.hpp>
#include <godot_cpp/variant/packed_vector3_array.hpp>
#include <godot_cpp/variant/packed_vector4_array.hpp>
#include <godot_cpp/variant/string.hpp>
#include <godot_cpp/variant/transform3d.hpp>
#include <godot_cpp/variant/variant.hpp>
#include <godot_cpp/variant/vector2i.hpp>

#include <cstdint>
#include <map>
#include <vector>

using namespace godot;

// Revision-bound owner for chunk-local, non-colliding static render packets.
// Source authority and packet compilation remain outside this class.
class ChunkRenderPacketBackend : public Node3D {
	GDCLASS(ChunkRenderPacketBackend, Node3D);

	static constexpr int32_t FLOATS_PER_INSTANCE = 20;
	static constexpr int32_t MAX_BATCH_INSTANCES = 256;
	static constexpr int32_t MAX_PACKET_BATCHES = 4096;
	static constexpr int64_t MAX_PACKET_BUFFER_BYTES = 64LL * 1024LL * 1024LL;
	static constexpr int64_t MAX_STAGED_BUFFER_BYTES = 128LL * 1024LL * 1024LL;
	static constexpr int64_t MAX_RESIDENT_BUFFER_BYTES = 256LL * 1024LL * 1024LL;
	static constexpr int32_t MAX_INSTALLED_PACKETS = 128;

	struct Batch {
		String id;
		Ref<Mesh> mesh;
		Ref<Material> material;
		PackedFloat32Array buffer;
		int64_t mesh_payload_bytes = 0;
		String mesh_content_digest;
		String render_layer;
		AABB bounds;
		String render_tier;
		bool cast_shadows = true;
		double visibility_range = 0.0;
		double fade_margin = 0.0;
	};

	struct InstalledPacket {
		String source_id;
		Vector2i owner_cell;
		int64_t generation = 0;
		String source_revision;
		String packet_digest;
		Transform3D local_to_chunk;
		uint64_t root_instance_id = 0;
		std::vector<Dictionary> batch_receipts;
		std::vector<Dictionary> layer_receipts;
		int64_t instance_count = 0;
		int64_t buffer_bytes = 0;
		int64_t mesh_payload_bytes = 0;
		int64_t payload_bytes = 0;
	};

	struct StagedPacket {
		struct LayerManifestEntry {
			String layer;
			int64_t expected_batch_count = 0;
			int64_t expected_instance_count = 0;
			int64_t accepted_batch_count = 0;
			int64_t accepted_instance_count = 0;
		};

		String source_id;
		Vector2i owner_cell;
		int64_t generation = 0;
		String source_revision;
		String packet_digest;
		Transform3D local_to_chunk;
		int64_t expected_batch_count = 0;
		int64_t expected_instance_count = 0;
		int64_t instance_count = 0;
		int64_t buffer_bytes = 0;
		int64_t mesh_payload_bytes = 0;
		int64_t reserved_bytes = 0;
		int32_t upload_cursor = 0;
		String state = "collecting";
		String failure_reason;
		Node3D *root = nullptr;
		uint64_t root_instance_id = 0;
		std::vector<Batch> batches;
		std::vector<Dictionary> batch_receipts;
		std::vector<LayerManifestEntry> layers;
		std::vector<Dictionary> layer_receipts;
	};

	std::map<std::string, InstalledPacket> _installed;
	std::map<std::string, StagedPacket> _staged;
	int64_t _staged_payload_bytes = 0;
	int64_t _retiring_roots = 0;
	int64_t _retiring_payload_bytes = 0;
	std::map<uint64_t, int64_t> _retiring_payload_by_root;

	static std::string _key(const String &p_source_id);
	Dictionary _status(const String &p_status, const String &p_reason = "") const;
	Node3D *_node3d_for_id(uint64_t p_object_id) const;
	int64_t _installed_payload_bytes() const;
	bool _owner_cell_matches_parent(const Vector2i &p_owner_cell) const;
	bool _stage_matches(const StagedPacket &p_packet, int64_t p_generation) const;
	void _free_staging_root(StagedPacket &r_packet);
	void _retire_root(uint64_t p_root_id, int64_t p_payload_bytes = 0);
	void _on_retired_root_exiting(uint64_t p_root_id);
	void _release_stage(std::map<std::string, StagedPacket>::iterator p_it);
	void _build_layer_receipts(StagedPacket &r_packet) const;
	Dictionary _begin_packet(const String &p_source_id, const Vector2i &p_owner_cell,
		int64_t p_generation, const String &p_source_revision,
		const String &p_packet_digest, const Transform3D &p_local_to_chunk,
		int64_t p_expected_batch_count, int64_t p_expected_instance_count,
		const Array &p_expected_layers);
	Dictionary _append_batch(const String &p_source_id, int64_t p_generation,
		const String &p_batch_id, const Ref<Mesh> &p_mesh,
		const String &p_expected_mesh_content_digest, const Ref<Material> &p_material,
		const PackedFloat32Array &p_buffer, const AABB &p_bounds,
		const String &p_render_tier, bool p_cast_shadows,
		double p_visibility_range, double p_fade_margin, const String &p_render_layer);
	Dictionary _batch_snapshot(const Batch &p_batch, int32_t p_index,
		MultiMeshInstance3D *p_instance) const;
	Dictionary _installed_snapshot(const InstalledPacket &p_packet) const;

protected:
	static void _bind_methods();

public:
	Dictionary begin_packet(const String &p_source_id, const Vector2i &p_owner_cell,
		int64_t p_generation, const String &p_source_revision,
		const String &p_packet_digest, const Transform3D &p_local_to_chunk,
		int64_t p_expected_batch_count, int64_t p_expected_instance_count);
	Dictionary begin_packet_with_layers(const String &p_source_id, const Vector2i &p_owner_cell,
		int64_t p_generation, const String &p_source_revision,
		const String &p_packet_digest, const Transform3D &p_local_to_chunk,
		int64_t p_expected_batch_count, int64_t p_expected_instance_count,
		const Array &p_expected_layers);
	Dictionary append_batch(const String &p_source_id, int64_t p_generation,
		const String &p_batch_id, const Ref<Mesh> &p_mesh,
		const String &p_expected_mesh_content_digest,
		const Ref<Material> &p_material, const PackedFloat32Array &p_buffer,
		const AABB &p_bounds, const String &p_render_tier, bool p_cast_shadows,
		double p_visibility_range, double p_fade_margin);
	Dictionary append_batch_in_layer(const String &p_source_id, int64_t p_generation,
		const String &p_batch_id, const Ref<Mesh> &p_mesh,
		const String &p_expected_mesh_content_digest,
		const Ref<Material> &p_material, const PackedFloat32Array &p_buffer,
		const AABB &p_bounds, const String &p_render_tier, bool p_cast_shadows,
		double p_visibility_range, double p_fade_margin, const String &p_render_layer);
	Dictionary advance_packet(const String &p_source_id, int64_t p_generation,
		int64_t p_max_units = 1);
	Dictionary commit_packet(const String &p_source_id, int64_t p_generation);
	Dictionary abort_packet(const String &p_source_id, int64_t p_generation);
	Dictionary release_packet(const String &p_source_id, int64_t p_generation);
	Dictionary installed_snapshot(const String &p_source_id) const;
	bool receipt_installed(const String &p_source_id, int64_t p_generation,
		const String &p_source_revision, const String &p_packet_digest) const;
	Dictionary metrics() const;
};

#endif
