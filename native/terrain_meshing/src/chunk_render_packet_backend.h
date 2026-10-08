#ifndef CHUNK_RENDER_PACKET_BACKEND_H
#define CHUNK_RENDER_PACKET_BACKEND_H

#include <godot_cpp/classes/material.hpp>
#include <godot_cpp/classes/mesh.hpp>
#include <godot_cpp/classes/multi_mesh.hpp>
#include <godot_cpp/classes/node3d.hpp>
#include <godot_cpp/classes/rendering_server.hpp>
#include <godot_cpp/classes/visual_instance3d.hpp>
#include <godot_cpp/variant/aabb.hpp>
#include <godot_cpp/variant/array.hpp>
#include <godot_cpp/variant/callable.hpp>
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
#include <godot_cpp/variant/rid.hpp>
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
	static constexpr int32_t MAX_LEGACY_CLAIMS_PER_PACKET = 4096;
	static constexpr int32_t MAX_ATTACHMENT_MANIFEST_MEMBERS = 256;

	struct Batch {
		String attachment_key;
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
		bool intended_visible = true;
		double visibility_range = 0.0;
		double fade_margin = 0.0;
	};

	struct LegacyVisual {
		uint64_t id = 0, parent_id = 0;
		bool was_visible = false;
	};
	struct OwnedRenderBatch {
		RID mesh;
		RID multimesh;
		Ref<Material> override_material;
		std::vector<Ref<Material>> surface_materials;
		int64_t mesh_handle = 0;
		int64_t multimesh_handle = 0;
	};
	struct AttachmentRoot {
		String ownership_kind = "backend_owned_geometry";
		String member_source_id;
		String source_part_id;
		String presentation_member_id;
		bool intended_visible = true;
		bool borrowed_source_visible = false;
		AABB swept_bounds;
		std::vector<LegacyVisual> legacy_visuals;
		uint64_t root_id = 0, parent_id = 0, body_id = 0;
		String source_revision;
		String producer_source_revision;
		String packet_source_id;
		int64_t packet_generation = 0;
		int64_t publisher_id = 0, publication_epoch = -1;
		int64_t payload_bytes = 0;
		Transform3D neutral_parent_world, body_world, local_transform;
		Transform3D closed_parent_to_body;
		String motion_kind;
		Vector3 raise_offset;
		double swing = 0.0;
	};
	using AttachmentRoots = std::map<std::string, AttachmentRoot>;
	struct InstalledPacket {
		AttachmentRoots attachments;
		AttachmentRoots suppressed_legacy;
		String source_id;
		Vector2i owner_cell;
		int64_t generation = 0;
		String source_revision;
		String packet_digest;
		Transform3D local_to_chunk;
		uint64_t root_instance_id = 0;
		std::vector<Dictionary> batch_receipts;
		std::vector<Dictionary> layer_receipts;
		std::map<std::string, Dictionary> expected_attachment_manifest;
		String attachment_manifest_digest;
		bool attachment_manifest_declared = false;
		int64_t instance_count = 0;
		int64_t buffer_bytes = 0;
		int64_t mesh_payload_bytes = 0;
		int64_t payload_bytes = 0;
	};

	struct StagedPacket {
		std::map<std::string, Dictionary> expected_attachment_manifest;
		String attachment_manifest_digest;
		bool attachment_manifest_declared = false;
		AttachmentRoots attachments;
		AttachmentRoots suppressed_legacy;
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

	struct PendingPresentation {
		bool previous_unavailable = false;
		bool replacement_owner_lost = false;
		bool replacement_active = false;
		bool previous_active = false;
		String token;
		InstalledPacket replacement;
		InstalledPacket previous;
		bool has_previous = false;
	};

	std::map<std::string, InstalledPacket> _installed;
	std::map<std::string, StagedPacket> _staged;
	std::map<std::string, PendingPresentation> _pending_presentations;
	std::map<std::string, Dictionary> _owner_loss_cancellations;
	int64_t _presentation_sequence = 0;
	mutable int64_t _installed_receipt_validation_polls = 0;
	int64_t _staged_payload_bytes = 0;
	int64_t _retiring_roots = 0;
	int64_t _retiring_payload_bytes = 0;
	std::map<uint64_t, int64_t> _retiring_payload_by_root;
	std::map<uint64_t, OwnedRenderBatch> _owned_render_batches;
	int64_t _next_render_resource_handle = 0;

	static std::string _key(const String &p_source_id);
	Dictionary _status(const String &p_status, const String &p_reason = "") const;
	Node3D *_node3d_for_id(uint64_t p_object_id) const;
	int64_t _installed_payload_bytes() const;
	bool _owner_cell_matches_parent(const Vector2i &p_owner_cell) const;
	bool _stage_matches(const StagedPacket &p_packet, int64_t p_generation) const;
	void _free_staging_root(StagedPacket &r_packet);
	bool _attachments_valid(const AttachmentRoots &p_roots, bool p_visible, bool p_require_current = true) const;
	bool _borrowed_root_active(uint64_t p_root_id) const;
	bool _borrowed_root_has_presentation_role(uint64_t p_root_id) const;
	bool _borrowed_root_source_visibility(uint64_t p_root_id, bool &r_visible) const;
	void _restore_borrowed_source_visibility(const AttachmentRoots &p_roots);
	bool _attachment_manifest_matches(const AttachmentRoots &p_roots,
		const std::map<std::string, Dictionary> &p_manifest) const;
	bool _borrowed_root_claimed_elsewhere(uint64_t p_root_id, const String &p_source_id) const;
	bool _attachment_motion_valid(const AttachmentRoot &p_attachment, Node3D *p_parent, Node3D *p_body) const;
	void _on_attachment_owner_exiting(int64_t p_owner_id);
	void _on_render_batch_retiring(int64_t p_instance_id);
	void _release_render_batch(uint64_t p_instance_id);
	bool _create_opaque_render_batch(const Batch &p_batch, StagedPacket &r_packet,
		Node3D *p_staging_root, Dictionary &r_receipt);
	bool _legacy_valid(const AttachmentRoot &p_attachment, const LegacyVisual &p_visual) const;
	bool _legacy_identity_valid(const AttachmentRoot &p_attachment, const LegacyVisual &p_visual) const;
	bool _legacy_hidden(const AttachmentRoots &p_roots) const;
	bool _suppressed_legacy_hidden(const AttachmentRoots &p_roots) const;
	void _hide_legacy(const AttachmentRoots &p_roots);
	void _restore_legacy(const AttachmentRoots &p_roots);
	bool _original_legacy_visibility(uint64_t p_id, bool p_fallback) const;
	void _merge_suppressed_legacy(AttachmentRoots &r_target, const AttachmentRoots &p_from, const AttachmentRoots &p_active) const;
	int64_t _legacy_claim_count(const AttachmentRoots &p_first, const AttachmentRoots &p_second) const;
	void _withdraw_source(const std::string &p_key);
	void _show_attachments(const AttachmentRoots &p_roots, bool p_visible);
	void _show_attachments_transition(const AttachmentRoots &p_roots, bool p_visible,
		const AttachmentRoots &p_preserved_borrowed_roots);
	void _retire_attachments(const AttachmentRoots &p_roots);
	int64_t _attachment_payload_bytes(const AttachmentRoots &p_roots) const;
	Array _attachment_receipts(const AttachmentRoots &p_roots, bool p_active_claim = true) const;
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
		double p_visibility_range, double p_fade_margin, const String &p_render_layer,
		const String &p_attachment_key = "", bool p_intended_visible = true);
	Dictionary _batch_snapshot(const Batch &p_batch, int32_t p_index,
		VisualInstance3D *p_instance) const;
	Dictionary _installed_snapshot(const InstalledPacket &p_packet,
		bool p_allow_hidden_root = false) const;
	Dictionary _pending_presentation_snapshot(const PendingPresentation &p_pending) const;

protected:
	static void _bind_methods();
	void _notification(int p_what);

public:
	Dictionary declare_attachment_manifest(const String &p_source_id, int64_t p_generation,
		const Array &p_members, const String &p_manifest_digest);
	Dictionary register_packet_attachment(const String &p_source_id, int64_t p_generation,
		const String &p_key, Node3D *p_parent, Node3D *p_body, const Transform3D &p_neutral_parent_world, const Dictionary &p_motion, const Array &p_legacy_visuals);
	Dictionary register_borrowed_presentation(const String &p_source_id, int64_t p_generation,
		const String &p_key, const String &p_member_source_id, const String &p_source_part_id,
		const String &p_member_id, Node3D *p_mount, Node3D *p_parent,
		Node3D *p_body, const Transform3D &p_neutral_parent_world,
		const Transform3D &p_mount_local_transform, const Dictionary &p_motion,
		bool p_intended_visible, const Array &p_legacy_visuals = Array());
	Dictionary legacy_visual_state(int64_t p_visual_id) const;
	Dictionary restore_legacy_for_visual(int64_t p_visual_id);
	Dictionary settle_attachment_owner_loss(const String &p_source_id, int64_t p_generation, const String &p_token);
	Dictionary settle_presentation_cancellation(const String &p_source_id, int64_t p_generation, const String &p_token, bool p_withdrawal_requested = false);
	Dictionary append_batch_in_attachment(const String &p_source_id, int64_t p_generation,
		const String &p_batch_id, const Ref<Mesh> &p_mesh, const String &p_expected_mesh_content_digest,
		const Ref<Material> &p_material, const PackedFloat32Array &p_buffer,
		const AABB &p_bounds, const String &p_render_tier, bool p_cast_shadows,
		double p_visibility_range, double p_fade_margin, const String &p_render_layer,
		const String &p_attachment_key, bool p_intended_visible = true);
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
		double p_visibility_range, double p_fade_margin, const String &p_render_layer,
		bool p_intended_visible = true);
	Dictionary advance_packet(const String &p_source_id, int64_t p_generation,
		int64_t p_max_units = 1);
	Dictionary commit_packet(const String &p_source_id, int64_t p_generation,
		bool p_await_frame_ack = false);
	Dictionary pending_presentation_snapshot(const String &p_source_id) const;
	Dictionary finalize_presentation(const String &p_source_id, int64_t p_generation,
		const String &p_token);
	Dictionary rollback_presentation(const String &p_source_id, int64_t p_generation,
		const String &p_token);
	Dictionary abort_packet(const String &p_source_id, int64_t p_generation);
	Dictionary release_packet(const String &p_source_id, int64_t p_generation);
	Dictionary installed_snapshot(const String &p_source_id) const;
	bool receipt_installed(const String &p_source_id, int64_t p_generation,
		const String &p_source_revision, const String &p_packet_digest) const;
	Dictionary metrics() const;
};

#endif
