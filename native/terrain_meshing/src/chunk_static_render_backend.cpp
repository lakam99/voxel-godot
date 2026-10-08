#include "chunk_static_render_backend.h"

#include <godot_cpp/classes/geometry_instance3d.hpp>
#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/classes/weak_ref.hpp>
#include <godot_cpp/variant/array.hpp>
#include <godot_cpp/variant/callable.hpp>
#include <godot_cpp/variant/string_name.hpp>
#include <godot_cpp/variant/utility_functions.hpp>

#include <algorithm>
#include <cmath>
#include <string>

using namespace godot;

void ChunkStaticRenderBackend::_bind_methods() {
	ClassDB::bind_static_method("ChunkStaticRenderBackend", D_METHOD("tree_impostor_descriptor", "recipe"), &ChunkStaticRenderBackend::tree_impostor_descriptor);
	ClassDB::bind_method(D_METHOD("publish_tree_impostor", "body", "request", "recipe", "branch_mesh", "crown_mesh", "branch_material", "foliage_material"), &ChunkStaticRenderBackend::publish_tree_impostor);
	ClassDB::bind_method(D_METHOD("release_tree", "body"), &ChunkStaticRenderBackend::release_tree);
	ClassDB::bind_method(D_METHOD("installed_snapshot", "body"), &ChunkStaticRenderBackend::installed_snapshot);
	ClassDB::bind_method(D_METHOD("visual_receipt_installed", "source_identity", "source_revision", "world_revision", "view_revision", "candidate_id", "metadata", "representation_id", "tier"), &ChunkStaticRenderBackend::visual_receipt_installed);
	ClassDB::bind_method(D_METHOD("metrics"), &ChunkStaticRenderBackend::metrics);
}

bool ChunkStaticRenderBackend::_valid_body(const StaticBody3D *p_body) const {
	return p_body != nullptr && p_body->is_inside_tree() &&
		is_inside_tree() && get_parent() != nullptr && p_body->get_parent() == get_parent();
}

String ChunkStaticRenderBackend::_make_group_key(const String &p_mode, const String &p_architecture,
		const String &p_biome, double p_visibility_range, const Ref<Mesh> &p_branch_mesh,
		const Ref<Mesh> &p_crown_mesh, const Ref<Material> &p_branch_material,
		const Ref<Material> &p_foliage_material) const {
	return p_mode + String(":") + p_architecture + String(":") + p_biome + String(":") + String::num(p_visibility_range, 3) + String(":") +
		String::num_int64(p_branch_mesh.is_valid() ? p_branch_mesh->get_instance_id() : 0) + String(":") +
		String::num_int64(p_crown_mesh.is_valid() ? p_crown_mesh->get_instance_id() : 0) + String(":") +
		String::num_int64(p_branch_material.is_valid() ? p_branch_material->get_instance_id() : 0) + String(":") +
		String::num_int64(p_foliage_material.is_valid() ? p_foliage_material->get_instance_id() : 0);
}

ChunkStaticRenderBackend::Group *ChunkStaticRenderBackend::_get_or_create_group(const String &p_key,
		const String &p_mode, const String &p_architecture, const String &p_biome,
		double p_visibility_range, const Ref<Mesh> &p_branch_mesh, const Ref<Mesh> &p_crown_mesh,
		const Ref<Material> &p_branch_material, const Ref<Material> &p_foliage_material) {
	std::string key = p_key.utf8().get_data();
	auto found = _groups.find(key);
	if (found != _groups.end()) return &found->second;
	Group group;
	group.key = p_key; group.mode = p_mode; group.architecture = p_architecture; group.biome = p_biome;
	group.visibility_range = p_visibility_range; group.branch_mesh = p_branch_mesh; group.crown_mesh = p_crown_mesh;
	group.branch_material = p_branch_material; group.foliage_material = p_foliage_material;
	return &_groups.emplace(key, std::move(group)).first->second;
}

bool ChunkStaticRenderBackend::_create_page(Group &r_group) {
	Page page;
	for (int32_t role = 0; role < 3; ++role) {
		Ref<MultiMesh> multimesh;
		multimesh.instantiate();
		multimesh->set_transform_format(MultiMesh::TRANSFORM_3D);
		multimesh->set_mesh(role == 0 ? r_group.branch_mesh : r_group.crown_mesh);
		multimesh->set_instance_count(PAGE_CAPACITY);
		multimesh->set_visible_instance_count(0);
		MultiMeshInstance3D *instance = memnew(MultiMeshInstance3D);
		instance->set_name(String("StaticTree_") + r_group.architecture + "_" + r_group.biome + "_" + String::num_int64(static_cast<int64_t>(r_group.pages.size())) + "_" + String::num_int64(role));
		instance->set_multimesh(multimesh);
		instance->set_material_override(role == 0 ? r_group.branch_material : r_group.foliage_material);
		instance->set_cast_shadows_setting(GeometryInstance3D::SHADOW_CASTING_SETTING_OFF);
		instance->set_visibility_range_end(r_group.visibility_range);
		instance->set_visibility_range_end_margin(std::min(20.0, r_group.visibility_range * 0.12));
		instance->set_visibility_range_fade_mode(GeometryInstance3D::VISIBILITY_RANGE_FADE_SELF);
		instance->set_extra_cull_margin(1.0);
		add_child(instance);
		page.meshes[role] = multimesh;
		page.instances[role] = instance;
	}
	page.cull_range_end = r_group.visibility_range;
	r_group.pages.push_back(page);
	return true;
}

void ChunkStaticRenderBackend::_tree_transforms(const Transform3D &p_body_to_batch,
		double p_height, double p_crown_radius, double p_trunk_radius, Transform3D r_transforms[3]) {
	const double height = std::max(2.0, p_height);
	const double crown_radius = std::max(1.0, p_crown_radius);
	const double trunk_radius = std::max(0.10, p_trunk_radius);
	Transform3D trunk(Basis().scaled(Vector3(trunk_radius, height * 0.54, trunk_radius)), Vector3(0, height * 0.27, 0));
	Vector3 crown_scale(crown_radius * 2.0, std::max(crown_radius * 1.25, height * 0.46), 1.0);
	Transform3D crown_a(Basis().scaled(crown_scale), Vector3(0, height * 0.68, 0));
	Transform3D crown_b(Basis(Vector3(0, 1, 0), Math_PI * 0.5).scaled(crown_scale), Vector3(0, height * 0.68, 0));
	r_transforms[0] = p_body_to_batch * trunk;
	r_transforms[1] = p_body_to_batch * crown_a;
	r_transforms[2] = p_body_to_batch * crown_b;
}

Dictionary ChunkStaticRenderBackend::tree_impostor_descriptor(const Dictionary &p_recipe) {
	Dictionary result;
	const double height = p_recipe.get("height", 0.0);
	const double radius = p_recipe.get("canopyRadius", 0.0);
	const double trunk = p_recipe.get("trunkRadius", 0.0);
	if (!std::isfinite(height) || !std::isfinite(radius) || !std::isfinite(trunk) || height <= 0 || radius <= 0 || trunk <= 0) {
		result["status"] = "failed";
		result["reason"] = "invalid_tree_impostor_dimensions";
		result.make_read_only();
		return result;
	}
	Transform3D transforms[3];
	_tree_transforms(Transform3D(), height, radius, trunk, transforms);
	Array instances;
	for (const Transform3D &transform : transforms) instances.push_back(transform);
	instances.make_read_only();
	result["status"] = "ready";
	result["schema"] = "tree-impostor-descriptor/v1";
	result["transforms"] = instances;
	result.make_read_only();
	return result;
}

void ChunkStaticRenderBackend::_expand_page_cull_range(Group &r_group, int32_t p_page_index, double p_cull_range_end) {
	if (p_page_index < 0 || p_page_index >= static_cast<int32_t>(r_group.pages.size())) return;
	Page &page = r_group.pages[p_page_index];
	if (p_cull_range_end <= page.cull_range_end) return;
	page.cull_range_end = p_cull_range_end;
	for (int role = 0; role < 3; ++role) page.instances[role]->set_visibility_range_end(p_cull_range_end);
	for (auto &entry : _trees) {
		TreeRecord &record = entry.second;
		if (record.group_key == r_group.key && record.page_index == p_page_index) record.visibility_range = p_cull_range_end;
	}
}


bool ChunkStaticRenderBackend::_record_installed(const TreeRecord &p_record,
		const StaticBody3D *p_body, String &r_stale_reason, int32_t &r_failed_role,
		Transform3D &r_expected_transform, Transform3D &r_actual_transform) const {
	r_stale_reason = "";
	r_failed_role = -1;
	if (!_valid_body(p_body) || p_record.body_id != static_cast<int64_t>(p_body->get_instance_id())) {
		r_stale_reason = "invalid_ownership";
		return false;
	}
	auto group_it = _groups.find(p_record.group_key.utf8().get_data());
	if (group_it == _groups.end()) {
		r_stale_reason = "group_missing";
		return false;
	}
	if (p_record.page_index < 0 || p_record.page_index >= static_cast<int32_t>(group_it->second.pages.size())) {
		r_stale_reason = "page_missing";
		return false;
	}
	const Page &page = group_it->second.pages[p_record.page_index];
	if (p_record.slot < 0 || p_record.slot >= page.live_count) {
		r_stale_reason = "slot_invalid";
		return false;
	}
	for (int role = 0; role < 3; ++role) {
		if (page.instances[role] == nullptr) {
			r_stale_reason = "page_node_missing";
			return false;
		}
	}
	if (!p_body->get_global_transform().is_equal_approx(p_record.body_transform)) {
		r_stale_reason = "body_transform_mismatch";
		return false;
	}
	if (!get_global_transform().is_equal_approx(p_record.batch_transform)) {
		r_stale_reason = "backend_transform_mismatch";
		return false;
	}
	if (!p_body->has_meta(PUBLISHER_META) ||
			p_body->get_meta(PUBLISHER_META) != Variant(const_cast<ChunkStaticRenderBackend *>(this))) {
		r_stale_reason = "publisher_metadata_mismatch";
		return false;
	}
	for (int role = 0; role < 3; ++role) {
		if (page.meshes[role].is_null()) {
			r_stale_reason = "page_resource_missing";
			return false;
		}
		const Transform3D actual_transform = page.meshes[role]->get_instance_transform(p_record.slot);
		if (!actual_transform.is_equal_approx(p_record.transforms[role])) {
			r_stale_reason = "role_transform_mismatch";
			r_failed_role = role;
			r_expected_transform = p_record.transforms[role];
			r_actual_transform = actual_transform;
			return false;
		}
	}
	return true;
}

Dictionary ChunkStaticRenderBackend::_snapshot(const TreeRecord &p_record, const StaticBody3D *p_body) const {
	Dictionary result;
	String stale_reason;
	int32_t failed_role = -1;
	Transform3D expected_transform;
	Transform3D actual_transform;
	if (!_record_installed(p_record, p_body, stale_reason, failed_role,
			expected_transform, actual_transform)) {
		result["status"] = "stale";
		result["staleReason"] = stale_reason;
		if (failed_role >= 0) {
			result["staleRole"] = failed_role;
			result["expectedTransform"] = expected_transform;
			result["actualTransform"] = actual_transform;
		}
		return result;
	}
	const Group &group = _groups.find(p_record.group_key.utf8().get_data())->second;
	const Page &page = group.pages[p_record.page_index];
	Array transforms, node_ids, mesh_ids, resource_ids, material_ids;
	for (int role = 0; role < 3; ++role) {
		transforms.push_back(page.meshes[role]->get_instance_transform(p_record.slot));
		node_ids.push_back(static_cast<int64_t>(page.instances[role]->get_instance_id()));
		mesh_ids.push_back(static_cast<int64_t>(page.meshes[role]->get_instance_id()));
		Ref<Mesh> mesh = page.meshes[role]->get_mesh();
		resource_ids.push_back(mesh.is_valid() ? static_cast<int64_t>(mesh->get_instance_id()) : 0);
		Ref<Material> material = page.instances[role]->get_material_override();
		material_ids.push_back(material.is_valid() ? static_cast<int64_t>(material->get_instance_id()) : 0);
	}
	result["status"] = "ready"; result["bodyInstanceId"] = p_record.body_id; result["chunkInstanceId"] = p_record.chunk_id;
	result["propId"] = p_record.prop_id; result["recipeSignature"] = p_record.recipe_signature;
	result["batchInstanceId"] = static_cast<int64_t>(get_instance_id()); result["groupKey"] = p_record.group_key;
	result["pageIndex"] = p_record.page_index; result["slot"] = p_record.slot;
	result["bodyGlobalTransform"] = p_body->get_global_transform(); result["batchGlobalTransform"] = get_global_transform();
	result["visibilityRange"] = p_record.visibility_range; result["renderMode"] = "impostor";
	result["instanceTransforms"] = transforms; result["meshInstanceIds"] = node_ids; result["multimeshIds"] = mesh_ids;
	result["meshResourceIds"] = resource_ids; result["materialIds"] = material_ids;
	return result;
}

Dictionary ChunkStaticRenderBackend::publish_tree_impostor(StaticBody3D *p_body,
		const Dictionary &p_request, const Dictionary &p_recipe, const Ref<Mesh> &p_branch_mesh,
		const Ref<Mesh> &p_crown_mesh, const Ref<Material> &p_branch_material, const Ref<Material> &p_foliage_material) {
	Dictionary failed; failed["status"] = "failed";
	if (!_valid_body(p_body) || !p_branch_mesh.is_valid() || !p_crown_mesh.is_valid() || !p_branch_material.is_valid() || !p_foliage_material.is_valid() || !static_cast<bool>(p_recipe.get("runtimeImpostor", false))) return failed;
	const double height = p_recipe.get("height", p_request.get("visualHeight", 0.0));
	const double crown_radius = p_recipe.get("canopyRadius", p_request.get("canopyRadius", 0.0));
	const double trunk_radius = p_recipe.get("trunkRadius", p_request.get("trunkRadius", 0.0));
	const Dictionary biome_parameters = p_request.get("biomeParameters", Dictionary());
	const Dictionary render_policy = p_recipe.get("renderPolicy", Dictionary());
	const double visibility_range = std::max(32.0, static_cast<double>(render_policy.get("visibilityRange", biome_parameters.get("visibilityRange", 0.0))));
	if (!std::isfinite(height) || !std::isfinite(crown_radius) || !std::isfinite(trunk_radius) || !std::isfinite(visibility_range) || height <= 0 || crown_radius <= 0 || trunk_radius <= 0 || visibility_range <= 0) return failed;
	const String architecture = p_request.get("architecture", "broadleaf");
	const String biome = p_request.get("biome", "forest");
	const String key = _make_group_key("impostor", architecture, biome, visibility_range, p_branch_mesh, p_crown_mesh, p_branch_material, p_foliage_material);
	Group *group = _get_or_create_group(key, "impostor", architecture, biome, visibility_range, p_branch_mesh, p_crown_mesh, p_branch_material, p_foliage_material);
	const int64_t body_id = static_cast<int64_t>(p_body->get_instance_id());
	auto old = _trees.find(body_id);
	bool replacing = false;
	TreeRecord old_record;
	if (old != _trees.end()) {
		old_record = old->second;
		replacing = true;
		Transform3D transforms[3];
		const Transform3D body_to_batch = get_global_transform().affine_inverse() * p_body->get_global_transform();
		_tree_transforms(body_to_batch, height, crown_radius, trunk_radius, transforms);
		const bool same_installation = old_record.group_key == key &&
			old_record.recipe_signature == String(p_recipe.get("signature", "")) &&
			old_record.body_transform.is_equal_approx(p_body->get_global_transform()) &&
			old_record.batch_transform.is_equal_approx(get_global_transform()) &&
			old_record.transforms[0].is_equal_approx(transforms[0]) &&
			old_record.transforms[1].is_equal_approx(transforms[1]) &&
			old_record.transforms[2].is_equal_approx(transforms[2]);
		if (same_installation) {
			Dictionary current = _snapshot(old_record, p_body);
			if (String(current.get("status", "")) == "ready") return current;
		}
		// Keep the accepted slot live while the replacement is prepared below.
		// Once the new transforms are installed, swap the record and compact the
		// old slot in this same call so no frame can observe a missing tree.
	}
	int32_t page_index = -1;
	for (int32_t i = 0; i < static_cast<int32_t>(group->pages.size()); ++i) if (group->pages[i].live_count < PAGE_CAPACITY) { page_index = i; break; }
	if (page_index < 0) { if (!_create_page(*group)) return failed; page_index = static_cast<int32_t>(group->pages.size()) - 1; }
	Page &page = group->pages[page_index];
	const int32_t slot = page.live_count++;
	Transform3D transforms[3];
	const Transform3D body_to_batch = get_global_transform().affine_inverse() * p_body->get_global_transform();
	_tree_transforms(body_to_batch, height, crown_radius, trunk_radius, transforms);
	for (int role = 0; role < 3; ++role) { page.meshes[role]->set_instance_transform(slot, transforms[role]); page.meshes[role]->set_visible_instance_count(page.live_count); page.instances[role]->set_visible(true); }
	const double cull_end = visibility_range + p_body->get_global_position().distance_to(get_global_position());
	_expand_page_cull_range(*group, page_index, cull_end);
	TreeRecord record; record.body_id = body_id; record.chunk_id = static_cast<int64_t>(get_parent()->get_instance_id());
	record.body_weak = UtilityFunctions::weakref(Variant(p_body));
	record.prop_id = p_body->get_meta("prop_id", ""); record.recipe_signature = p_recipe.get("signature", "");
	record.group_key = key; record.page_index = page_index; record.slot = slot; record.body_transform = p_body->get_global_transform();
	record.batch_transform = get_global_transform(); for (int i = 0; i < 3; ++i) record.transforms[i] = transforms[i];
	record.visibility_range = page.cull_range_end;
	_trees[body_id] = record;
	if (replacing) _remove_record_slot(old_record);
	p_body->set_meta(PUBLISHER_META, this);
	Callable exiting = callable_mp(this, &ChunkStaticRenderBackend::_on_body_exiting).bind(body_id);
	if (!p_body->is_connected("tree_exiting", exiting)) p_body->connect("tree_exiting", exiting, Object::CONNECT_ONE_SHOT);
	return _snapshot(_trees[body_id], p_body);
}

void ChunkStaticRenderBackend::_remove_body_id(int64_t p_body_id) {
	auto record_it = _trees.find(p_body_id);
	if (record_it == _trees.end()) return;
	TreeRecord record = record_it->second;
	_remove_record_slot(record);
	_trees.erase(record_it);
}

void ChunkStaticRenderBackend::_remove_record_slot(const TreeRecord &p_record) {
	auto group_it = _groups.find(p_record.group_key.utf8().get_data());
	if (group_it != _groups.end() && p_record.page_index >= 0 && p_record.page_index < static_cast<int32_t>(group_it->second.pages.size())) {
		Page &page = group_it->second.pages[p_record.page_index];
		const int32_t last = page.live_count - 1;
		if (p_record.slot >= 0 && p_record.slot <= last && p_record.slot != last) {
			for (int role = 0; role < 3; ++role) page.meshes[role]->set_instance_transform(p_record.slot, page.meshes[role]->get_instance_transform(last));
			for (auto &entry : _trees) if (entry.second.group_key == p_record.group_key && entry.second.page_index == p_record.page_index && entry.second.slot == last) { entry.second.slot = p_record.slot; break; }
		}
		if (last >= 0) { for (int role = 0; role < 3; ++role) page.meshes[role]->set_visible_instance_count(last); page.live_count = last; }
	}
}

void ChunkStaticRenderBackend::_on_body_exiting(int64_t p_body_id) { _remove_body_id(p_body_id); }

void ChunkStaticRenderBackend::release_tree(StaticBody3D *p_body) {
	if (p_body == nullptr) return;
	const int64_t id = static_cast<int64_t>(p_body->get_instance_id());
	_remove_body_id(id);
	if (p_body->has_meta(PUBLISHER_META) && p_body->get_meta(PUBLISHER_META) == Variant(this)) p_body->remove_meta(PUBLISHER_META);
}

Dictionary ChunkStaticRenderBackend::installed_snapshot(StaticBody3D *p_body) const {
	Dictionary result; result["status"] = "missing";
	if (p_body == nullptr) return result;
	auto found = _trees.find(static_cast<int64_t>(p_body->get_instance_id()));
	return found == _trees.end() ? result : _snapshot(found->second, p_body);
}

bool ChunkStaticRenderBackend::visual_receipt_installed(const String &p_source_identity,
		const String &p_source_revision, const String &p_world_revision, int64_t p_view_revision,
		const String &p_candidate_id, const Dictionary &p_metadata,
		const String &p_representation_id, const String &p_tier) const {
	if (p_source_identity.strip_edges().is_empty() || p_source_revision.strip_edges().is_empty() ||
			p_world_revision.strip_edges().is_empty() || p_view_revision <= 0 ||
			p_candidate_id.strip_edges().is_empty() || p_tier != "horizon" ||
			p_representation_id != p_candidate_id + String(":horizon")) {
		return false;
	}
	const int64_t body_id = p_metadata.get("candidateBodyInstanceId", 0);
	auto found = _trees.find(body_id);
	if (found == _trees.end() || !found->second.body_weak.is_valid()) return false;
	Variant weak_target = found->second.body_weak->get_ref();
	Object *object = weak_target;
	StaticBody3D *body = Object::cast_to<StaticBody3D>(object);
	if (body == nullptr) return false;
	Dictionary snapshot = installed_snapshot(body);
	if (String(snapshot.get("status", "")) != "ready") return false;
	const int64_t expected_body_id = p_metadata.get("candidateBodyInstanceId", 0);
	const int64_t expected_chunk_id = p_metadata.get("candidateChunkInstanceId", 0);
	const String expected_signature = p_metadata.get("treeRecipeSignature", "");
	const String installed_prop_id = snapshot.get("propId", String());
	const String installed_signature = snapshot.get("recipeSignature", String());
	return expected_body_id > 0 && expected_chunk_id > 0 && !expected_signature.strip_edges().is_empty() &&
		p_candidate_id == installed_prop_id &&
		expected_body_id == static_cast<int64_t>(snapshot.get("bodyInstanceId", 0)) &&
		expected_chunk_id == static_cast<int64_t>(snapshot.get("chunkInstanceId", 0)) &&
		expected_signature == installed_signature;
}

Dictionary ChunkStaticRenderBackend::metrics() const {
	int64_t pages = 0;
	for (const auto &entry : _groups) pages += static_cast<int64_t>(entry.second.pages.size());
	Dictionary result; result["groups"] = static_cast<int64_t>(_groups.size()); result["pages"] = pages; result["trees"] = static_cast<int64_t>(_trees.size()); result["pageCapacity"] = PAGE_CAPACITY;
	return result;
}
