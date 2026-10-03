#ifndef CHUNK_STATIC_RENDER_BACKEND_H
#define CHUNK_STATIC_RENDER_BACKEND_H

#include <godot_cpp/classes/material.hpp>
#include <godot_cpp/classes/mesh.hpp>
#include <godot_cpp/classes/multi_mesh.hpp>
#include <godot_cpp/classes/multi_mesh_instance3d.hpp>
#include <godot_cpp/classes/node3d.hpp>
#include <godot_cpp/classes/static_body3d.hpp>
#include <godot_cpp/classes/weak_ref.hpp>
#include <godot_cpp/core/object.hpp>
#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/string.hpp>
#include <godot_cpp/variant/transform3d.hpp>

#include <cstdint>
#include <map>
#include <vector>

using namespace godot;

class ChunkStaticRenderBackend : public Node3D {
	GDCLASS(ChunkStaticRenderBackend, Node3D);

	static constexpr int32_t PAGE_CAPACITY = 32;
	static constexpr const char *PUBLISHER_META = "static_chunk_render_publisher";

	struct Page {
		Ref<MultiMesh> meshes[3];
		MultiMeshInstance3D *instances[3] = {nullptr, nullptr, nullptr};
		int32_t live_count = 0;
		double cull_range_end = 0.0;
	};

	struct Group {
		String key;
		String mode;
		String architecture;
		String biome;
		double visibility_range = 0.0;
		Ref<Mesh> branch_mesh;
		Ref<Mesh> crown_mesh;
		Ref<Material> branch_material;
		Ref<Material> foliage_material;
		std::vector<Page> pages;
	};

	struct TreeRecord {
		int64_t body_id = 0;
		Ref<WeakRef> body_weak;
		int64_t chunk_id = 0;
		String prop_id;
		String recipe_signature;
		String group_key;
		int32_t page_index = -1;
		int32_t slot = -1;
		Transform3D body_transform;
		Transform3D batch_transform;
		Transform3D transforms[3];
		double visibility_range = 0.0;
	};

	int64_t _chunk_id = 0;
	std::map<std::string, Group> _groups;
	std::map<int64_t, TreeRecord> _trees;

	String _make_group_key(const String &p_mode, const String &p_architecture,
		const String &p_biome, double p_visibility_range,
		const Ref<Mesh> &p_branch_mesh, const Ref<Mesh> &p_crown_mesh,
		const Ref<Material> &p_branch_material,
		const Ref<Material> &p_foliage_material) const;
	Group *_get_or_create_group(const String &p_key, const String &p_mode,
		const String &p_architecture, const String &p_biome,
		double p_visibility_range, const Ref<Mesh> &p_branch_mesh,
		const Ref<Mesh> &p_crown_mesh, const Ref<Material> &p_branch_material,
		const Ref<Material> &p_foliage_material);
	bool _create_page(Group &r_group);
	void _remove_body_id(int64_t p_body_id);
	void _on_body_exiting(int64_t p_body_id);
	bool _valid_body(const StaticBody3D *p_body) const;
	bool _record_installed(const TreeRecord &p_record,
		const StaticBody3D *p_body, String &r_stale_reason,
		int32_t &r_failed_role, Transform3D &r_expected_transform,
		Transform3D &r_actual_transform) const;
	void _expand_page_cull_range(Group &r_group, int32_t p_page_index,
		double p_cull_range_end);
	static void _tree_transforms(const Transform3D &p_body_to_batch,
		double p_height, double p_crown_radius, double p_trunk_radius,
		Transform3D r_transforms[3]);
	Dictionary _snapshot(const TreeRecord &p_record,
		const StaticBody3D *p_body) const;

protected:
	static void _bind_methods();

public:
	Dictionary publish_tree_impostor(StaticBody3D *p_body,
		const Dictionary &p_request, const Dictionary &p_recipe,
		const Ref<Mesh> &p_branch_mesh, const Ref<Mesh> &p_crown_mesh,
		const Ref<Material> &p_branch_material,
		const Ref<Material> &p_foliage_material);
	void release_tree(StaticBody3D *p_body);
	Dictionary installed_snapshot(StaticBody3D *p_body) const;
	bool visual_receipt_installed(const String &p_source_identity,
		const String &p_source_revision, const String &p_world_revision,
		int64_t p_view_revision, const String &p_candidate_id,
		const Dictionary &p_metadata, const String &p_representation_id,
		const String &p_tier) const;
	Dictionary metrics() const;
};

#endif
