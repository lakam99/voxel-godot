#include "native_tree_geometry_dispatcher.h"

#include <godot_cpp/classes/thread.hpp>
#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/variant/array.hpp>
#include <godot_cpp/variant/aabb.hpp>
#include <godot_cpp/variant/vector3.hpp>
#include <godot_cpp/variant/vector3i.hpp>
#include <godot_cpp/variant/transform3d.hpp>

#include <algorithm>
#include <cmath>
#include <iterator>
#include <limits>
#include <map>
#include <sstream>
#include <stdexcept>

using namespace godot;

namespace {
Dictionary status_result(const char *p_status, const char *p_reason) {
	Dictionary result;
	result["status"] = p_status;
	result["reason"] = p_reason;
	return result;
}

bool read_string(const Variant &p_value, std::string &r_value) {
	if (p_value.get_type() != Variant::STRING) return false;
	const CharString utf8 = String(p_value).utf8();
	r_value.assign(utf8.get_data(), static_cast<std::size_t>(utf8.length()));
	return !r_value.empty();
}

bool read_number(const Variant &p_value, double &r_value) {
	if (p_value.get_type() != Variant::FLOAT && p_value.get_type() != Variant::INT) return false;
	r_value = static_cast<double>(p_value);
	return std::isfinite(r_value);
}

bool finite_positive(const double p_value) {
	return std::isfinite(p_value) && p_value > 0.0;
}

std::vector<std::uint32_t> utf8_codepoints(const std::string &p_text) {
	std::vector<std::uint32_t> result;
	for (std::size_t i = 0; i < p_text.size();) {
		const unsigned char first = static_cast<unsigned char>(p_text[i]);
		std::uint32_t codepoint = 0U;
		std::size_t length = 0U;
		if (first < 0x80U) { codepoint = first; length = 1U; }
		else if ((first & 0xE0U) == 0xC0U) { codepoint = first & 0x1FU; length = 2U; }
		else if ((first & 0xF0U) == 0xE0U) { codepoint = first & 0x0FU; length = 3U; }
		else if ((first & 0xF8U) == 0xF0U) { codepoint = first & 0x07U; length = 4U; }
		else throw std::invalid_argument("invalid_utf8_identity");
		if (i + length > p_text.size()) throw std::invalid_argument("truncated_utf8_identity");
		for (std::size_t offset = 1U; offset < length; ++offset) {
			const unsigned char next = static_cast<unsigned char>(p_text[i + offset]);
			if ((next & 0xC0U) != 0x80U) throw std::invalid_argument("invalid_utf8_identity");
			codepoint = (codepoint << 6U) | (next & 0x3FU);
		}
		if ((length == 2U && codepoint < 0x80U) ||
				(length == 3U && codepoint < 0x800U) ||
				(length == 4U && codepoint < 0x10000U) ||
				codepoint > 0x10FFFFU || (codepoint >= 0xD800U && codepoint <= 0xDFFFU)) {
			throw std::invalid_argument("noncanonical_utf8_identity");
		}
		result.push_back(codepoint);
		i += length;
	}
	return result;
}

std::uint32_t stable_hash(const std::string &p_text) {
	std::uint32_t hash = 2166136261U;
	for (const std::uint32_t codepoint : utf8_codepoints(p_text)) {
		hash = (hash ^ codepoint) * 16777619U;
	}
	return hash;
}

double stable_unit(const std::string &p_text) {
	return static_cast<double>(stable_hash(p_text) & 0x7FFFFFFFU) /
		static_cast<double>(0x7FFFFFFFU);
}

void euler_yxz(const double x, const double y, const double z, double r_basis[3][3]) {
	const double cx = std::cos(x), sx = std::sin(x);
	const double cy = std::cos(y), sy = std::sin(y);
	const double cz = std::cos(z), sz = std::sin(z);
	// Godot's default Basis.from_euler order is YXZ: Ry * Rx * Rz.
	r_basis[0][0] = cy * cz + sy * sx * sz;
	r_basis[0][1] = -cy * sz + sy * sx * cz;
	r_basis[0][2] = sy * cx;
	r_basis[1][0] = cx * sz;
	r_basis[1][1] = cx * cz;
	r_basis[1][2] = -sx;
	r_basis[2][0] = -sy * cz + cy * sx * sz;
	r_basis[2][1] = sy * sz + cy * sx * cz;
	r_basis[2][2] = cy * cx;
}

} // namespace

NativeTreeGeometryDispatcher::NativeTreeGeometryDispatcher() {
	workers_.reserve(2U);
	for (int index = 0; index < 2; ++index) workers_.emplace_back([this]() { _worker_loop(); });
}

NativeTreeGeometryDispatcher::~NativeTreeGeometryDispatcher() { _stop_and_join(); }

void NativeTreeGeometryDispatcher::_bind_methods() {
	ClassDB::bind_method(D_METHOD("submit_foliage_compile", "recipe_snapshot", "biome", "prop_id", "identity"),
		&NativeTreeGeometryDispatcher::submit_foliage_compile);
	ClassDB::bind_method(D_METHOD("submit_tree_record_compile", "recipe_snapshot", "biome", "prop_id", "identity"),
		&NativeTreeGeometryDispatcher::submit_tree_record_compile);
	ClassDB::bind_method(D_METHOD("submit_tree_section_pack", "packet", "identity"),
		&NativeTreeGeometryDispatcher::submit_tree_section_pack);
	ClassDB::bind_method(D_METHOD("poll_tree_geometry_compile", "ticket"),
		&NativeTreeGeometryDispatcher::poll_tree_geometry_compile);
	ClassDB::bind_method(D_METHOD("take_tree_geometry_compile_result", "ticket"),
		&NativeTreeGeometryDispatcher::take_tree_geometry_compile_result);
	ClassDB::bind_method(D_METHOD("cancel_tree_geometry_compile", "ticket"),
		&NativeTreeGeometryDispatcher::cancel_tree_geometry_compile);
	ClassDB::bind_method(D_METHOD("release_tree_geometry_compile", "ticket"),
		&NativeTreeGeometryDispatcher::release_tree_geometry_compile);
	ClassDB::bind_method(D_METHOD("drain_tree_geometry_compiles"),
		&NativeTreeGeometryDispatcher::drain_tree_geometry_compiles);
	ClassDB::bind_method(D_METHOD("tree_geometry_compile_metrics"),
		&NativeTreeGeometryDispatcher::tree_geometry_compile_metrics);
}

bool NativeTreeGeometryDispatcher::_read_identity(const Dictionary &p_identity,
		Identity &r_identity, std::string &r_reason) {
	const Variant generation_value = p_identity.get("artifactGeneration", Variant());
	if (!read_string(p_identity.get("worldId", Variant()), r_identity.world_id) ||
			!read_string(p_identity.get("worldEpoch", Variant()), r_identity.world_epoch) ||
			!read_string(p_identity.get("sourceId", Variant()), r_identity.source_id) ||
			!read_string(p_identity.get("sourceRevision", Variant()), r_identity.source_revision) ||
			!read_string(p_identity.get("recipeSignature", Variant()), r_identity.recipe_signature) ||
			generation_value.get_type() != Variant::INT ||
			static_cast<std::int64_t>(generation_value) <= 0) {
		r_reason = "incomplete_tree_geometry_identity";
		return false;
	}
	r_identity.artifact_generation = static_cast<std::int64_t>(generation_value);
	if (!read_string(p_identity.get("sourceRecordDigest", Variant()), r_identity.source_record_digest) ||
			!read_string(p_identity.get("sourceProvenanceDigest", Variant()), r_identity.source_provenance_digest) ||
			!read_string(p_identity.get("requestDigest", Variant()), r_identity.request_digest)) {
		r_reason = "incomplete_tree_geometry_source_digest_identity";
		return false;
	}
	return true;
}

bool NativeTreeGeometryDispatcher::_copy_recipe_snapshot(const Dictionary &p_recipe_snapshot,
		const String &p_biome, const String &p_prop_id, Job &r_job, std::string &r_reason) {
	std::string recipe_signature;
	const Variant signature_value = p_recipe_snapshot.get("signature", Variant());
	if (!read_string(signature_value, recipe_signature) ||
			recipe_signature != r_job.identity.recipe_signature) {
		r_reason = "tree_foliage_recipe_signature_mismatch";
		return false;
	}
	if (!p_recipe_snapshot.is_read_only() || p_recipe_snapshot.is_empty() ||
			p_biome.is_empty() || p_prop_id.is_empty() ||
			bool(p_recipe_snapshot.get("runtimeImpostor", false))) {
		r_reason = "unsupported_or_unsealed_tree_foliage_recipe_snapshot";
		return false;
	}
	const Variant anchors_value = p_recipe_snapshot.get("foliage", Variant());
	if (anchors_value.get_type() != Variant::ARRAY) {
		r_reason = "tree_foliage_anchor_list_missing";
		return false;
	}
	const Array anchors = anchors_value;
	if (!anchors.is_read_only()) {
		r_reason = "tree_foliage_anchor_values_not_sealed";
		return false;
	}
	if (anchors.size() > static_cast<std::int64_t>(MAX_ANCHORS_PER_JOB)) {
		r_reason = "tree_foliage_anchor_limit";
		return false;
	}
	r_job.anchors.reserve(static_cast<std::size_t>(anchors.size()));
	for (std::int64_t index = 0; index < anchors.size(); ++index) {
		const Variant anchor_value = anchors[index];
		if (anchor_value.get_type() != Variant::DICTIONARY ||
				!Dictionary(anchor_value).is_read_only()) {
			r_reason = "tree_foliage_anchor_invalid";
			return false;
		}
		const Dictionary anchor = anchor_value;
		const Variant position_value = anchor.get("position", Variant());
		const Variant rotation_value = anchor.get("rotation", Variant());
		const Variant scale_value = anchor.get("scale", Variant());
		const Variant variant_value = anchor.get("clusterVariant", Variant(0));
		const Variant source_segment_value = anchor.get("sourceSegment", Variant(-1));
		const Variant source_order_value = anchor.get("sourceOrder", Variant(0));
		Anchor copied;
		if (position_value.get_type() != Variant::VECTOR3 || rotation_value.get_type() != Variant::VECTOR3 ||
			scale_value.get_type() != Variant::VECTOR3 ||
			variant_value.get_type() != Variant::INT || source_segment_value.get_type() != Variant::INT ||
			source_order_value.get_type() != Variant::INT) {
			r_reason = "tree_foliage_anchor_fields_invalid";
			return false;
		}
		const Vector3 position = position_value;
		const Vector3 rotation = rotation_value;
		const Vector3 scale = scale_value;
		copied.position[0] = position.x; copied.position[1] = position.y; copied.position[2] = position.z;
		copied.rotation[0] = rotation.x; copied.rotation[1] = rotation.y; copied.rotation[2] = rotation.z;
		copied.scale[0] = scale.x; copied.scale[1] = scale.y; copied.scale[2] = scale.z;
		if (!finite_positive(copied.scale[0]) || !finite_positive(copied.scale[1]) ||
				!finite_positive(copied.scale[2]) || !std::isfinite(copied.position[0]) ||
				!std::isfinite(copied.position[1]) || !std::isfinite(copied.position[2]) ||
				!std::isfinite(copied.rotation[0]) || !std::isfinite(copied.rotation[1]) ||
				!std::isfinite(copied.rotation[2]) ||
				!read_number(anchor.get("windWeight", Variant(0.5)), copied.wind_weight) ||
				!read_number(anchor.get("variation", Variant(0.5)), copied.variation)) {
			r_reason = "tree_foliage_anchor_numeric_invalid";
			return false;
		}
		copied.cluster_variant = static_cast<std::int32_t>(std::clamp(
			static_cast<std::int64_t>(variant_value), static_cast<std::int64_t>(0),
			static_cast<std::int64_t>(3)));
		copied.source_segment = static_cast<std::int32_t>(source_segment_value);
		copied.source_order = static_cast<std::int32_t>(source_order_value);
		if (copied.source_segment < -1 || copied.source_order < 0 || copied.wind_weight < 0.0 ||
				copied.wind_weight > 1.0 || copied.variation < 0.0 || copied.variation > 1.0) {
			r_reason = "tree_foliage_anchor_range_invalid";
			return false;
		}
		r_job.anchors.push_back(copied);
	}
	const CharString biome_utf8 = p_biome.utf8();
	const CharString prop_utf8 = p_prop_id.utf8();
	r_job.biome.assign(biome_utf8.get_data(), static_cast<std::size_t>(biome_utf8.length()));
	r_job.prop_id.assign(prop_utf8.get_data(), static_cast<std::size_t>(prop_utf8.length()));
	return true;
}

bool NativeTreeGeometryDispatcher::_copy_tree_record_snapshot(const Dictionary &p_recipe_snapshot,
		const String &p_biome, const String &p_prop_id, Job &r_job, std::string &r_reason) {
	if (!_copy_recipe_snapshot(p_recipe_snapshot, p_biome, p_prop_id, r_job, r_reason)) return false;
	const Variant branches_value = p_recipe_snapshot.get("branches", Variant());
	if (branches_value.get_type() != Variant::ARRAY || !Array(branches_value).is_read_only()) {
		r_reason = "tree_record_branch_values_not_sealed";
		return false;
	}
	const Array source_branches = branches_value;
	if (source_branches.size() > static_cast<std::int64_t>(MAX_ANCHORS_PER_JOB)) {
		r_reason = "tree_record_branch_limit";
		return false;
	}
	r_job.branches.reserve(static_cast<std::size_t>(source_branches.size()));
	for (std::int64_t index = 0; index < source_branches.size(); ++index) {
		const Variant value = source_branches[index];
		if (value.get_type() != Variant::DICTIONARY || !Dictionary(value).is_read_only()) {
			r_reason = "tree_record_branch_not_sealed";
			return false;
		}
		const Dictionary branch = value;
		const Variant order_value = branch.get("order", Variant(1));
		if (order_value.get_type() != Variant::INT) {
			r_reason = "tree_record_branch_order_invalid";
			return false;
		}
		if (static_cast<std::int64_t>(order_value) == 0) continue; // order-zero segments build the GDScript bole.
		const Variant start_value = branch.get("start", Variant());
		const Variant end_value = branch.get("end", Variant());
		if (start_value.get_type() != Variant::VECTOR3 || end_value.get_type() != Variant::VECTOR3) {
			r_reason = "tree_record_branch_points_invalid";
			return false;
		}
		const Vector3 start = start_value;
		const Vector3 end = end_value;
		Branch copied;
		copied.start[0] = start.x; copied.start[1] = start.y; copied.start[2] = start.z;
		copied.end[0] = end.x; copied.end[1] = end.y; copied.end[2] = end.z;
		const Variant radius_start_value = branch.get("radiusStart", Variant(0.1));
		const Variant radius_end_value = branch.get("radiusEnd", Variant(0.05));
		if (!read_number(radius_start_value, copied.radius_start) ||
				!read_number(radius_end_value, copied.radius_end) ||
				!read_number(branch.get("windWeight", Variant(0.0)), copied.wind_weight) ||
				!std::isfinite(copied.start[0]) || !std::isfinite(copied.start[1]) || !std::isfinite(copied.start[2]) ||
				!std::isfinite(copied.end[0]) || !std::isfinite(copied.end[1]) || !std::isfinite(copied.end[2]) ||
				copied.radius_start < 0.0 || copied.radius_end < 0.0 ||
				copied.wind_weight < 0.0 || copied.wind_weight > 1.0) {
			r_reason = "tree_record_branch_numeric_invalid";
			return false;
		}
		r_job.branches.push_back(copied);
	}
	return true;
}

Dictionary NativeTreeGeometryDispatcher::_identity_dictionary(const Identity &p_identity) {
	Dictionary result;
	result["worldId"] = String(p_identity.world_id.c_str());
	result["worldEpoch"] = String(p_identity.world_epoch.c_str());
	result["sourceId"] = String(p_identity.source_id.c_str());
	result["sourceRevision"] = String(p_identity.source_revision.c_str());
	result["recipeSignature"] = String(p_identity.recipe_signature.c_str());
	result["artifactGeneration"] = p_identity.artifact_generation;
	result["sourceRecordDigest"] = String(p_identity.source_record_digest.c_str());
	result["sourceProvenanceDigest"] = String(p_identity.source_provenance_digest.c_str());
	result["requestDigest"] = String(p_identity.request_digest.c_str());
	result.make_read_only();
	return result;
}

Dictionary NativeTreeGeometryDispatcher::_job_status(const Job &p_job, const bool p_include_values) {
	Dictionary result;
	result["status"] = String(p_job.state.c_str());
	result["ticket"] = p_job.ticket;
	result["identity"] = _identity_dictionary(p_job.identity);
	if (!p_job.reason.empty()) result["reason"] = String(p_job.reason.c_str());
	if (p_include_values && p_job.state == "ready") {
		if (p_job.section_pack) {
			Array sections;
			for (const Job::PackSection &section : p_job.pack_sections) {
				Array attributes;
				attributes.set_typed(Variant::FLOAT, StringName(), Variant());
				for (const float value : section.attributes) attributes.push_back(value);
				attributes.make_read_only();
				Array members;
				for (const Job::PackMember &member : section.members) {
					Array supports;
					for (const std::array<std::int32_t, 3> &key : member.support_sections) {
						supports.push_back(Vector3i(key[0], key[1], key[2]));
					}
					supports.make_read_only();
					Dictionary row;
					row["instanceIndex"] = member.instance_index;
					row["attributeOffset"] = member.attribute_offset;
					row["ownedSectionKey"] = Vector3i(member.owned_section[0],
						member.owned_section[1], member.owned_section[2]);
					row["supportSectionKeys"] = supports;
					row["worldBounds"] = AABB(
						Vector3(member.world_bounds_position[0], member.world_bounds_position[1], member.world_bounds_position[2]),
						Vector3(member.world_bounds_size[0], member.world_bounds_size[1], member.world_bounds_size[2]));
					row.make_read_only();
					members.push_back(row);
				}
				members.make_read_only();
				Dictionary row;
				row["sectionKey"] = Vector3i(section.section_key[0], section.section_key[1], section.section_key[2]);
				row["instanceAttributes"] = attributes;
				row["instanceCount"] = static_cast<std::int64_t>(section.attributes.size() / FLOATS_PER_INSTANCE);
				row["members"] = members;
				row.make_read_only();
				sections.push_back(row);
			}
			sections.make_read_only();
			result["sections"] = sections;
			result["role"] = String(p_job.pack_role.c_str());
			result["sourcePartId"] = String(p_job.pack_source_part_id.c_str());
			result["batchKey"] = String(p_job.pack_batch_key.c_str());
			result["windEnvelopeDigest"] = String(p_job.pack_wind_digest.c_str());
			result["supportEnvelopePolicyRevision"] = String(p_job.pack_support_policy_revision.c_str());
			result["meshContentDigest"] = String(p_job.pack_mesh_digest.c_str());
			result["instanceCount"] = p_job.pack_instance_count;
			result.make_read_only();
			return result;
		}
		PackedFloat32Array values;
		values.resize(static_cast<std::int64_t>(p_job.instance_values.size()));
		float *destination = values.ptrw();
		std::copy(p_job.instance_values.begin(), p_job.instance_values.end(), destination);
		result["instanceValues"] = values;
		result["instanceCount"] = static_cast<std::int64_t>(p_job.anchors.size());
		PackedFloat32Array branch_values;
		branch_values.resize(static_cast<std::int64_t>(p_job.branch_instance_values.size()));
		float *branch_destination = branch_values.ptrw();
		std::copy(p_job.branch_instance_values.begin(), p_job.branch_instance_values.end(), branch_destination);
		result["branchInstanceValues"] = branch_values;
		result["branchInstanceCount"] = static_cast<std::int64_t>(p_job.branches.size());
	}
	result.make_read_only();
	return result;
}

std::shared_ptr<NativeTreeGeometryDispatcher::Job>
NativeTreeGeometryDispatcher::_find_job_locked(const std::int64_t p_ticket) const {
	for (const std::shared_ptr<Job> &job : jobs_) if (job->ticket == p_ticket) return job;
	return nullptr;
}

void NativeTreeGeometryDispatcher::_reclaim_terminal_locked(const std::shared_ptr<Job> &p_job) {
	if (p_job == nullptr || p_job->state == "queued" || p_job->state == "running") return;
	const std::size_t reserved = p_job->reserved_output_floats;
	retained_output_floats_ = reserved > retained_output_floats_ ? 0U : retained_output_floats_ - reserved;
	p_job->reserved_output_floats = 0U;
	p_job->instance_values.clear();
	p_job->branch_instance_values.clear();
	p_job->anchors.clear();
	p_job->branches.clear();
	p_job->pack_input_values.clear();
	p_job->pack_sections.clear();
	jobs_.erase(std::remove(jobs_.begin(), jobs_.end(), p_job), jobs_.end());
}

Dictionary NativeTreeGeometryDispatcher::submit_foliage_compile(
		const Dictionary &p_recipe_snapshot, const String &p_biome,
		const String &p_prop_id, const Dictionary &p_identity) {
	if (!Thread::is_main_thread()) return status_result("failed", "tree_geometry_main_thread_required");
	auto job = std::make_shared<Job>();
	std::string reason;
	if (!_read_identity(p_identity, job->identity, reason) ||
			!_copy_recipe_snapshot(p_recipe_snapshot, p_biome, p_prop_id, *job, reason)) {
		Dictionary failed = status_result("failed", reason.c_str());
		return failed;
	}
	std::lock_guard<std::mutex> lock(mutex_);
	if (stopping_ || drained_) return status_result("failed", "tree_geometry_dispatcher_draining");
	const std::size_t reservation = job->anchors.size() * FLOATS_PER_INSTANCE;
	if (jobs_.size() >= MAX_JOBS || retained_output_floats_ +
			reservation > MAX_RETAINED_OUTPUT_FLOATS) {
		return status_result("backpressure", "tree_geometry_dispatcher_capacity");
	}
	job->ticket = next_ticket_++;
	job->state = "queued";
	job->reserved_output_floats = reservation;
	retained_output_floats_ += reservation;
	jobs_.push_back(job);
	work_available_.notify_one();
	Dictionary result;
	result["status"] = "pending";
	result["reason"] = "tree_foliage_compile_queued";
	result["ticket"] = job->ticket;
	result["identity"] = _identity_dictionary(job->identity);
	return result;
}

Dictionary NativeTreeGeometryDispatcher::submit_tree_record_compile(
		const Dictionary &p_recipe_snapshot, const String &p_biome,
		const String &p_prop_id, const Dictionary &p_identity) {
	if (!Thread::is_main_thread()) return status_result("failed", "tree_geometry_main_thread_required");
	auto job = std::make_shared<Job>();
	std::string reason;
	if (!_read_identity(p_identity, job->identity, reason) ||
			!_copy_tree_record_snapshot(p_recipe_snapshot, p_biome, p_prop_id, *job, reason)) {
		return status_result("failed", reason.c_str());
	}
	std::lock_guard<std::mutex> lock(mutex_);
	if (stopping_ || drained_) return status_result("failed", "tree_geometry_dispatcher_draining");
	const std::size_t reservation = (job->anchors.size() + job->branches.size()) * FLOATS_PER_INSTANCE;
	if (jobs_.size() >= MAX_JOBS || retained_output_floats_ + reservation > MAX_RETAINED_OUTPUT_FLOATS) {
		return status_result("backpressure", "tree_geometry_dispatcher_capacity");
	}
	job->ticket = next_ticket_++;
	job->state = "queued";
	job->reserved_output_floats = reservation;
	retained_output_floats_ += reservation;
	jobs_.push_back(job);
	work_available_.notify_one();
	Dictionary result;
	result["status"] = "pending";
	result["reason"] = "tree_record_compile_queued";
	result["ticket"] = job->ticket;
	result["identity"] = _identity_dictionary(job->identity);
	return result;
}

Dictionary NativeTreeGeometryDispatcher::submit_tree_section_pack(
		const Dictionary &p_packet, const Dictionary &p_identity) {
	if (!Thread::is_main_thread()) return status_result("failed", "tree_geometry_main_thread_required");
	auto job = std::make_shared<Job>();
	job->section_pack = true;
	std::string reason;
	if (!_read_identity(p_identity, job->identity, reason)) return status_result("failed", reason.c_str());
	const Variant role_value = p_packet.get("role", Variant());
	const Variant part_value = p_packet.get("sourcePartId", Variant());
	const Variant batch_value = p_packet.get("batchKey", Variant());
	const Variant mesh_digest_value = p_packet.get("meshContentDigest", Variant());
	const Variant wind_digest_value = p_packet.get("windEnvelopeDigest", Variant());
	const Variant support_policy_value = p_packet.get("supportEnvelopePolicyRevision", Variant());
	const Variant mesh_bounds_value = p_packet.get("meshLocalBounds", Variant());
	const Variant transform_value = p_packet.get("sourceGlobalTransform", Variant());
	const Variant certified_bounds_value = p_packet.get("certifiedWorldBounds", Variant());
	const Variant section_size_value = p_packet.get("sectionSize", Variant());
	const Variant wind_horizontal_value = p_packet.get("windHorizontalMeters", Variant());
	const Variant wind_vertical_value = p_packet.get("windVerticalMeters", Variant());
	const Variant instance_values_value = p_packet.get("instanceValues", Variant());
	const Variant instance_stride_value = p_packet.get("instanceStride", Variant(FLOATS_PER_INSTANCE));
	const Variant use_colors_value = p_packet.get("useInstanceColors", Variant(true));
	const Variant use_custom_value = p_packet.get("useInstanceCustomData", Variant(true));
	if (role_value.get_type() != Variant::STRING || part_value.get_type() != Variant::STRING ||
			batch_value.get_type() != Variant::STRING || mesh_digest_value.get_type() != Variant::STRING ||
			wind_digest_value.get_type() != Variant::STRING || support_policy_value.get_type() != Variant::STRING ||
			mesh_bounds_value.get_type() != Variant::AABB ||
			transform_value.get_type() != Variant::TRANSFORM3D ||
			certified_bounds_value.get_type() != Variant::AABB ||
			instance_values_value.get_type() != Variant::PACKED_FLOAT32_ARRAY ||
			instance_stride_value.get_type() != Variant::INT ||
			use_colors_value.get_type() != Variant::BOOL ||
			use_custom_value.get_type() != Variant::BOOL) {
		return status_result("failed", "incomplete_tree_section_pack_packet");
	}
	job->pack_role = String(role_value).utf8().get_data();
	job->pack_source_part_id = String(part_value).utf8().get_data();
	job->pack_batch_key = String(batch_value).utf8().get_data();
	job->pack_mesh_digest = String(mesh_digest_value).utf8().get_data();
	job->pack_wind_digest = String(wind_digest_value).utf8().get_data();
	job->pack_support_policy_revision = String(support_policy_value).utf8().get_data();
	if (job->pack_role != "bole" && job->pack_role != "branches" && job->pack_role != "foliage")
		return status_result("failed", "tree_section_pack_role_invalid");
	if (job->pack_source_part_id.empty() || job->pack_batch_key.empty() ||
			job->pack_mesh_digest.size() != 64U || job->pack_wind_digest.size() != 64U ||
			job->pack_support_policy_revision.empty())
		return status_result("failed", "tree_section_pack_identity_incomplete");
	const AABB mesh_bounds = mesh_bounds_value;
	const Vector3 mesh_position = mesh_bounds.get_position();
	const Vector3 mesh_size = mesh_bounds.get_size();
	const AABB certified_bounds = certified_bounds_value;
	const Vector3 certified_position = certified_bounds.get_position();
	const Vector3 certified_size = certified_bounds.get_size();
	if (!mesh_position.is_finite() || !mesh_size.is_finite() || mesh_size.x <= 0.0 ||
			mesh_size.y <= 0.0 || mesh_size.z <= 0.0 || !certified_position.is_finite() ||
			!certified_size.is_finite() || certified_size.x <= 0.0 || certified_size.y <= 0.0 ||
			certified_size.z <= 0.0) {
		return status_result("failed", "tree_section_pack_bounds_or_grid_invalid");
	}
	job->pack_mesh_bounds_position[0] = mesh_position.x;
	job->pack_mesh_bounds_position[1] = mesh_position.y;
	job->pack_mesh_bounds_position[2] = mesh_position.z;
	job->pack_mesh_bounds_size[0] = mesh_size.x;
	job->pack_mesh_bounds_size[1] = mesh_size.y;
	job->pack_mesh_bounds_size[2] = mesh_size.z;
	job->pack_certified_bounds_position[0] = certified_position.x;
	job->pack_certified_bounds_position[1] = certified_position.y;
	job->pack_certified_bounds_position[2] = certified_position.z;
	job->pack_certified_bounds_size[0] = certified_size.x;
	job->pack_certified_bounds_size[1] = certified_size.y;
	job->pack_certified_bounds_size[2] = certified_size.z;
	const Transform3D body_transform = transform_value;
	if (!body_transform.is_finite()) return status_result("failed", "tree_section_pack_transform_invalid");
	for (int row = 0; row < 3; ++row) {
		for (int column = 0; column < 3; ++column) {
			job->pack_body_basis[row * 3 + column] = body_transform.basis.get_column(column)[row];
		}
	}
	job->pack_body_origin[0] = body_transform.origin.x;
	job->pack_body_origin[1] = body_transform.origin.y;
	job->pack_body_origin[2] = body_transform.origin.z;
	double wind_horizontal = 0.0, wind_vertical = 0.0, section_size = 0.0;
	if (!read_number(wind_horizontal_value, wind_horizontal) || wind_horizontal < 0.0 ||
			!read_number(wind_vertical_value, wind_vertical) || wind_vertical < 0.0 ||
			!read_number(section_size_value, section_size) || section_size <= 0.0) {
		return status_result("failed", "tree_section_pack_wind_or_grid_invalid");
	}
	const float section_size_real = static_cast<float>(section_size);
	if (!std::isfinite(section_size_real) || section_size_real <= 0.0F) {
		return status_result("failed", "tree_section_pack_section_size_not_representable");
	}
	job->pack_section_size = section_size;
	job->pack_wind_horizontal = wind_horizontal;
	job->pack_wind_vertical = wind_vertical;
	const PackedFloat32Array values = instance_values_value;
	job->pack_use_colors = static_cast<bool>(use_colors_value);
	job->pack_use_custom_data = static_cast<bool>(use_custom_value);
	job->pack_input_stride = static_cast<std::int32_t>(instance_stride_value);
	const std::int32_t expected_stride = 12 + (job->pack_use_colors ? 4 : 0) +
		(job->pack_use_custom_data ? 4 : 0);
	if (job->pack_input_stride != expected_stride || values.is_empty() ||
			values.size() % job->pack_input_stride != 0 ||
			values.size() / job->pack_input_stride >
				static_cast<std::int64_t>(MAX_ANCHORS_PER_JOB)) {
		return status_result("failed", "tree_section_pack_instance_layout_invalid");
	}
	job->pack_input_values.reserve(static_cast<std::size_t>(values.size()));
	job->pack_instance_count = values.size() / job->pack_input_stride;
	for (std::int64_t index = 0; index < values.size(); ++index) {
		const float value = values[index];
		if (!std::isfinite(value)) return status_result("failed", "tree_section_pack_nonfinite_instance_value");
		job->pack_input_values.push_back(value);
	}
	std::lock_guard<std::mutex> lock(mutex_);
	if (stopping_ || drained_) return status_result("failed", "tree_geometry_dispatcher_draining");
	const std::size_t reservation = static_cast<std::size_t>(job->pack_instance_count) * FLOATS_PER_INSTANCE;
	if (jobs_.size() >= MAX_JOBS || retained_output_floats_ + reservation > MAX_RETAINED_OUTPUT_FLOATS)
		return status_result("backpressure", "tree_geometry_dispatcher_capacity");
	job->ticket = next_ticket_++;
	job->state = "queued";
	job->reserved_output_floats = reservation;
	retained_output_floats_ += reservation;
	jobs_.push_back(job);
	work_available_.notify_one();
	Dictionary result;
	result["status"] = "pending";
	result["reason"] = "tree_section_pack_queued";
	result["ticket"] = job->ticket;
	result["identity"] = _identity_dictionary(job->identity);
	return result;
}

std::string NativeTreeGeometryDispatcher::_compile_foliage(
		const std::shared_ptr<Job> &p_job, std::vector<float> &r_values) {
	const std::size_t count = p_job->anchors.size();
	r_values.reserve(count * FLOATS_PER_INSTANCE);
	const double phase_base = stable_unit("foliage-phase:" + p_job->biome + ":" + p_job->prop_id);
	for (std::size_t index = 0U; index < count; ++index) {
		if (p_job->cancel_requested.load(std::memory_order_relaxed)) return "cancelled";
		const Anchor &anchor = p_job->anchors[index];
		double basis[3][3] = {};
		euler_yxz(anchor.rotation[0], anchor.rotation[1], anchor.rotation[2], basis);
		const double sx = anchor.scale[0], sy = anchor.scale[1], sz = anchor.scale[2];
		// Match Transform3D(Basis.from_euler(rotation).scaled(scale), position).
		const double row0_x = basis[0][0] * sx, row0_y = basis[0][1] * sx, row0_z = basis[0][2] * sx;
		const double row1_x = basis[1][0] * sy, row1_y = basis[1][1] * sy, row1_z = basis[1][2] * sy;
		const double row2_x = basis[2][0] * sz, row2_y = basis[2][1] * sz, row2_z = basis[2][2] * sz;
		const double phase = std::fmod(phase_base + static_cast<double>(index) * 0.037 +
			static_cast<double>(anchor.cluster_variant) * 0.173, 1.0);
		const double variant = static_cast<double>(anchor.cluster_variant);
		const double custom[4] = {phase, std::clamp(anchor.wind_weight, 0.0, 1.0),
			std::clamp(anchor.variation, 0.0, 1.0), variant / 3.0};
		const double values[FLOATS_PER_INSTANCE] = {
			row0_x, row0_y, row0_z, anchor.position[0],
			row1_x, row1_y, row1_z, anchor.position[1],
			row2_x, row2_y, row2_z, anchor.position[2],
			1.0, 1.0, 1.0, 1.0,
			custom[0], custom[1], custom[2], custom[3]};
		for (const double value : values) {
			if (!std::isfinite(value) || std::abs(value) > std::numeric_limits<float>::max()) return "tree_foliage_output_nonfinite";
			r_values.push_back(static_cast<float>(value));
		}
	}
	return p_job->cancel_requested.load(std::memory_order_relaxed) ? "cancelled" : "ready";
}

std::string NativeTreeGeometryDispatcher::_compile_branches(
		const std::shared_ptr<Job> &p_job, std::vector<float> &r_values) {
	const std::size_t count = p_job->branches.size();
	r_values.reserve(count * FLOATS_PER_INSTANCE);
	const double phase_base = stable_unit("branch-phase:" + p_job->biome + ":" + p_job->prop_id);
	for (std::size_t index = 0U; index < count; ++index) {
		if (p_job->cancel_requested.load(std::memory_order_relaxed)) return "cancelled";
		const Branch &branch = p_job->branches[index];
		double dx = branch.end[0] - branch.start[0];
		double dy = branch.end[1] - branch.start[1];
		double dz = branch.end[2] - branch.start[2];
		const double length = std::max(0.01, std::sqrt(dx * dx + dy * dy + dz * dz));
		const double up[3] = {dx / length, dy / length, dz / length};
		// ProceduralTreeVisualFactory.branch_transform(): UP.cross(up), falling
		// back to RIGHT for nearly vertical segments, then side.cross(up).
		double side[3] = {up[2], 0.0, -up[0]};
		const double side_length_squared = side[0] * side[0] + side[2] * side[2];
		if (side_length_squared < 0.0001) {
			side[0] = 1.0; side[1] = 0.0; side[2] = 0.0;
		} else {
			const double inv = 1.0 / std::sqrt(side_length_squared);
			side[0] *= inv; side[2] *= inv;
		}
		double forward[3] = {
			side[1] * up[2] - side[2] * up[1],
			side[2] * up[0] - side[0] * up[2],
			side[0] * up[1] - side[1] * up[0]};
		const double forward_length = std::sqrt(forward[0] * forward[0] +
			forward[1] * forward[1] + forward[2] * forward[2]);
		if (forward_length > 0.0) {
			forward[0] /= forward_length; forward[1] /= forward_length; forward[2] /= forward_length;
		}
		const double radius = std::max(0.025, branch.radius_start);
		const double origin[3] = {(branch.start[0] + branch.end[0]) * 0.5,
			(branch.start[1] + branch.end[1]) * 0.5,
			(branch.start[2] + branch.end[2]) * 0.5};
		const double radius_start = std::max(0.025, branch.radius_start);
		const double radius_end = std::max(0.012, branch.radius_end);
		const double phase = std::fmod(phase_base + static_cast<double>(index) * 0.0618034, 1.0);
		const double bark = stable_unit("bark:" + p_job->prop_id + ":" + std::to_string(index));
		const double custom[4] = {std::clamp(radius_end / radius_start, 0.03, 1.0),
			std::clamp(branch.wind_weight, 0.0, 1.0), phase, bark};
		const double values[FLOATS_PER_INSTANCE] = {
			side[0] * radius, up[0] * length, forward[0] * radius, origin[0],
			side[1] * radius, up[1] * length, forward[1] * radius, origin[1],
			side[2] * radius, up[2] * length, forward[2] * radius, origin[2],
			1.0, 1.0, 1.0, 1.0,
			custom[0], custom[1], custom[2], custom[3]};
		for (const double value : values) {
			if (!std::isfinite(value) || std::abs(value) > std::numeric_limits<float>::max())
				return "tree_branch_output_nonfinite";
			r_values.push_back(static_cast<float>(value));
		}
	}
	return p_job->cancel_requested.load(std::memory_order_relaxed) ? "cancelled" : "ready";
}

std::string NativeTreeGeometryDispatcher::_compile_section_pack(
		const std::shared_ptr<Job> &p_job, std::vector<Job::PackSection> &r_sections,
		std::string &r_reason) {
	const auto snapped_floor = [](const float value, const float size) -> std::int32_t {
		float quotient = value / size;
		const float nearest = std::round(quotient);
		if (std::abs(quotient - nearest) <= 0.000001F) quotient = nearest;
		return static_cast<std::int32_t>(std::floor(quotient));
	};
	const auto snapped_ceil = [](const float value, const float size) -> std::int32_t {
		float quotient = value / size;
		const float nearest = std::round(quotient);
		if (std::abs(quotient - nearest) <= 0.000001F) quotient = nearest;
		return static_cast<std::int32_t>(std::ceil(quotient));
	};
	const auto contains = [](const double outer_position[3], const double outer_size[3],
			const double inner_position[3], const double inner_size[3]) -> bool {
		for (int axis = 0; axis < 3; ++axis) {
			if (inner_position[axis] < outer_position[axis] - 0.002 ||
					inner_position[axis] + inner_size[axis] >
						outer_position[axis] + outer_size[axis] + 0.002) return false;
		}
		return true;
	};
	std::map<std::array<std::int32_t, 3>, Job::PackSection> sections_by_owner;
	std::size_t total_support_keys = 0U;
	const std::size_t instance_count = static_cast<std::size_t>(p_job->pack_instance_count);
	for (std::size_t index = 0U; index < instance_count; ++index) {
		if (p_job->cancel_requested.load(std::memory_order_relaxed)) {
			r_reason = "tree_section_pack_cancelled";
			return "cancelled";
		}
		const float *input = p_job->pack_input_values.data() + index * p_job->pack_input_stride;
		// Match Godot's real_t Transform3D/Basis operations before widening the
		// resulting world bounds for section-coordinate validation.
		float local_basis[3][3] = {
			{input[0], input[1], input[2]},
			{input[4], input[5], input[6]},
			{input[8], input[9], input[10]}};
		float world_basis[3][3] = {};
		for (int row = 0; row < 3; ++row)
			for (int column = 0; column < 3; ++column)
				for (int inner = 0; inner < 3; ++inner)
					world_basis[row][column] += static_cast<float>(p_job->pack_body_basis[row * 3 + inner]) * local_basis[inner][column];
		float local_origin[3] = {input[3], input[7], input[11]};
		float world_origin[3] = {static_cast<float>(p_job->pack_body_origin[0]),
			static_cast<float>(p_job->pack_body_origin[1]), static_cast<float>(p_job->pack_body_origin[2])};
		for (int row = 0; row < 3; ++row)
			world_origin[row] =
				(static_cast<float>(p_job->pack_body_basis[row * 3 + 0]) * local_origin[0] +
				 static_cast<float>(p_job->pack_body_basis[row * 3 + 1]) * local_origin[1] +
				 static_cast<float>(p_job->pack_body_basis[row * 3 + 2]) * local_origin[2]) +
				static_cast<float>(p_job->pack_body_origin[row]);
		float local_min[3] = {static_cast<float>(p_job->pack_mesh_bounds_position[0]),
			static_cast<float>(p_job->pack_mesh_bounds_position[1]),
			static_cast<float>(p_job->pack_mesh_bounds_position[2])};
		float local_max[3] = {
			local_min[0] + static_cast<float>(p_job->pack_mesh_bounds_size[0]),
			local_min[1] + static_cast<float>(p_job->pack_mesh_bounds_size[1]),
			local_min[2] + static_cast<float>(p_job->pack_mesh_bounds_size[2])};
		float world_bounds_position[3] = {}, world_bounds_size[3] = {};
		for (int row = 0; row < 3; ++row) {
			float min = world_origin[row];
			float max = world_origin[row];
			for (int column = 0; column < 3; ++column) {
				const float e = world_basis[row][column] * local_min[column];
				const float f = world_basis[row][column] * local_max[column];
				if (e < f) {
					min += e;
					max += f;
				} else {
					min += f;
					max += e;
				}
			}
			const float wind = static_cast<float>(row == 1 ?
				p_job->pack_wind_vertical : p_job->pack_wind_horizontal);
			world_bounds_position[row] = min - wind;
			world_bounds_size[row] = (max - min) + (2.0F * wind);
		}
		const float size = static_cast<float>(p_job->pack_section_size);
		for (int axis = 0; axis < 3; ++axis) {
			const double low = static_cast<double>(world_bounds_position[axis]);
			const double high = static_cast<double>(world_bounds_position[axis] + world_bounds_size[axis]);
			const double section_coordinate = static_cast<double>(
				world_bounds_position[axis] + world_bounds_size[axis] * 0.5F) /
				p_job->pack_section_size;
			if (!std::isfinite(low) || !std::isfinite(high) || world_bounds_size[axis] <= 0.0F ||
					!std::isfinite(section_coordinate) ||
					section_coordinate < static_cast<double>(std::numeric_limits<std::int32_t>::min()) + 2.0 ||
					section_coordinate > static_cast<double>(std::numeric_limits<std::int32_t>::max()) - 2.0 ||
					low / p_job->pack_section_size < static_cast<double>(std::numeric_limits<std::int32_t>::min()) + 2.0 ||
					high / p_job->pack_section_size > static_cast<double>(std::numeric_limits<std::int32_t>::max()) - 2.0) {
				r_reason = "tree_instance_section_coordinate_out_of_range";
				return "failed";
			}
		}
		double certified_position[3] = {p_job->pack_certified_bounds_position[0],
			p_job->pack_certified_bounds_position[1], p_job->pack_certified_bounds_position[2]};
		double certified_size[3] = {p_job->pack_certified_bounds_size[0],
			p_job->pack_certified_bounds_size[1], p_job->pack_certified_bounds_size[2]};
		double certified_member_position[3] = {world_bounds_position[0],
			world_bounds_position[1], world_bounds_position[2]};
		double certified_member_size[3] = {world_bounds_size[0],
			world_bounds_size[1], world_bounds_size[2]};
		if (!contains(certified_position, certified_size,
				certified_member_position, certified_member_size)) {
			r_reason = "tree_compiled_instance_exceeds_certified_envelope";
			return "failed";
		}
		const float center_x = world_bounds_position[0] + world_bounds_size[0] * 0.5F;
		const float center_y = world_bounds_position[1] + world_bounds_size[1] * 0.5F;
		const float center_z = world_bounds_position[2] + world_bounds_size[2] * 0.5F;
		std::array<std::int32_t, 3> owner = {
			snapped_floor(center_x, size), snapped_floor(center_y, size),
			snapped_floor(center_z, size)};
		auto found = sections_by_owner.find(owner);
		if (found == sections_by_owner.end()) {
			Job::PackSection section;
			section.section_key[0] = owner[0]; section.section_key[1] = owner[1]; section.section_key[2] = owner[2];
			found = sections_by_owner.emplace(owner, std::move(section)).first;
		}
		Job::PackMember member;
		member.instance_index = static_cast<std::int32_t>(index);
		member.attribute_offset = static_cast<std::int32_t>(found->second.attributes.size() / FLOATS_PER_INSTANCE);
		member.owned_section[0] = owner[0]; member.owned_section[1] = owner[1]; member.owned_section[2] = owner[2];
		for (int axis = 0; axis < 3; ++axis) {
			member.world_bounds_position[axis] = world_bounds_position[axis];
			member.world_bounds_size[axis] = world_bounds_size[axis];
		}
		std::int32_t low[3] = {}, high[3] = {};
		std::int64_t support_deltas[3] = {};
		for (int axis = 0; axis < 3; ++axis) {
			low[axis] = snapped_floor(world_bounds_position[axis], size);
			const float bounds_end = world_bounds_position[axis] + world_bounds_size[axis];
			high[axis] = snapped_ceil(bounds_end, size) - 1;
			support_deltas[axis] = static_cast<std::int64_t>(high[axis]) -
				static_cast<std::int64_t>(low[axis]);
			if (support_deltas[axis] < 0 || support_deltas[axis] > 64) {
				r_reason = "tree_instance_support_section_range_invalid";
				return "failed";
			}
		}
		const std::uint64_t support_key_count =
			static_cast<std::uint64_t>(support_deltas[0] + 1) *
			static_cast<std::uint64_t>(support_deltas[1] + 1) *
			static_cast<std::uint64_t>(support_deltas[2] + 1);
		if (support_key_count > MAX_TREE_PACK_SUPPORT_KEYS_PER_INSTANCE ||
				support_key_count > MAX_TREE_PACK_SUPPORT_KEYS_PER_JOB - total_support_keys) {
			r_reason = "tree_instance_support_section_budget_exceeded";
			return "failed";
		}
		total_support_keys += static_cast<std::size_t>(support_key_count);
		member.support_sections.reserve(static_cast<std::size_t>(support_key_count));
		for (std::int32_t z = low[2]; z <= high[2]; ++z)
			for (std::int32_t y = low[1]; y <= high[1]; ++y)
				for (std::int32_t x = low[0]; x <= high[0]; ++x)
					member.support_sections.push_back({x, y, z});
		const float section_origin[3] = {static_cast<float>(owner[0]) * size,
			static_cast<float>(owner[1]) * size, static_cast<float>(owner[2]) * size};
		const float packed[12] = {
			world_basis[0][0], world_basis[0][1], world_basis[0][2], world_origin[0] - section_origin[0],
			world_basis[1][0], world_basis[1][1], world_basis[1][2], world_origin[1] - section_origin[1],
			world_basis[2][0], world_basis[2][1], world_basis[2][2], world_origin[2] - section_origin[2]};
		for (int lane = 0; lane < 12; ++lane) {
			if (!std::isfinite(packed[lane]) || std::abs(packed[lane]) > std::numeric_limits<float>::max()) {
				r_reason = "tree_section_pack_output_nonfinite";
				return "failed";
			}
			found->second.attributes.push_back(static_cast<float>(packed[lane]));
		}
		if (p_job->pack_use_colors) {
			for (int lane = 0; lane < 4; ++lane) found->second.attributes.push_back(input[12 + lane]);
		} else {
			found->second.attributes.insert(found->second.attributes.end(), {1.0F, 1.0F, 1.0F, 1.0F});
		}
		if (p_job->pack_use_custom_data) {
			const std::int32_t custom_offset = 12 + (p_job->pack_use_colors ? 4 : 0);
			for (int lane = 0; lane < 4; ++lane) found->second.attributes.push_back(input[custom_offset + lane]);
		} else {
			found->second.attributes.insert(found->second.attributes.end(), {0.0F, 0.0F, 0.0F, 0.0F});
		}
		found->second.members.push_back(std::move(member));
	}
	std::vector<Job::PackSection> sections;
	sections.reserve(sections_by_owner.size());
	for (auto &entry : sections_by_owner) sections.push_back(std::move(entry.second));
	r_sections = std::move(sections);
	return p_job->cancel_requested.load(std::memory_order_relaxed) ? "cancelled" : "ready";
}

void NativeTreeGeometryDispatcher::_worker_loop() {
	while (true) {
		std::shared_ptr<Job> job;
		{
			std::unique_lock<std::mutex> lock(mutex_);
			work_available_.wait(lock, [this]() {
				return stopping_ || std::any_of(jobs_.begin(), jobs_.end(),
					[](const std::shared_ptr<Job> &item) { return item->state == "queued"; });
			});
			if (stopping_) return;
			const auto found = std::find_if(jobs_.begin(), jobs_.end(),
				[](const std::shared_ptr<Job> &item) { return item->state == "queued"; });
			if (found == jobs_.end()) continue;
			job = *found;
			if (job->cancel_requested.load(std::memory_order_relaxed)) {
				job->state = "cancelled";
				job->reason = job->section_pack ? "tree_section_pack_cancelled" : "tree_foliage_compile_cancelled";
				job->anchors.clear();
				job->branches.clear();
				job->pack_input_values.clear();
				continue;
			}
			job->state = "running";
		}
		std::vector<float> values;
		std::vector<float> branch_values;
		std::vector<Job::PackSection> packed_sections;
		std::string pack_reason;
		std::string state;
		if (job->section_pack) {
			state = _compile_section_pack(job, packed_sections, pack_reason);
		} else {
			const std::string branch_state = _compile_branches(job, branch_values);
			state = branch_state == "ready" ? _compile_foliage(job, values) : branch_state;
		}
		{
			std::lock_guard<std::mutex> lock(mutex_);
			if (job->cancel_requested.load(std::memory_order_relaxed) || state == "cancelled") {
				job->state = "cancelled";
				job->reason = job->section_pack ? "tree_section_pack_cancelled" : "tree_foliage_compile_cancelled";
				job->anchors.clear();
				job->branches.clear();
				job->pack_input_values.clear();
				job->pack_sections.clear();
			} else if (state != "ready") {
				job->state = "failed";
				job->reason = job->section_pack ? pack_reason : state;
				job->anchors.clear();
				job->branches.clear();
				job->pack_input_values.clear();
				job->pack_sections.clear();
			} else {
				if (job->section_pack) {
					job->pack_sections = std::move(packed_sections);
					std::vector<float>().swap(job->pack_input_values);
				}
				else {
					job->instance_values = std::move(values);
					job->branch_instance_values = std::move(branch_values);
				}
				job->state = "ready";
			}
			if (job->release_requested) _reclaim_terminal_locked(job);
		}
	}
}

Dictionary NativeTreeGeometryDispatcher::poll_tree_geometry_compile(const std::int64_t p_ticket) const {
	if (!Thread::is_main_thread()) return status_result("failed", "tree_geometry_main_thread_required");
	std::lock_guard<std::mutex> lock(mutex_);
	const auto job = _find_job_locked(p_ticket);
	if (job == nullptr) return status_result("pending", "tree_geometry_job_missing");
	return _job_status(*job, false);
}

Dictionary NativeTreeGeometryDispatcher::take_tree_geometry_compile_result(const std::int64_t p_ticket) {
	if (!Thread::is_main_thread()) return status_result("failed", "tree_geometry_main_thread_required");
	std::lock_guard<std::mutex> lock(mutex_);
	const auto job = _find_job_locked(p_ticket);
	if (job == nullptr) return status_result("pending", "tree_geometry_job_missing");
	return _job_status(*job, true);
}

Dictionary NativeTreeGeometryDispatcher::cancel_tree_geometry_compile(const std::int64_t p_ticket) {
	if (!Thread::is_main_thread()) return status_result("failed", "tree_geometry_main_thread_required");
	std::lock_guard<std::mutex> lock(mutex_);
	const auto job = _find_job_locked(p_ticket);
	if (job == nullptr) return status_result("ready", "tree_geometry_job_already_retired");
	job->cancel_requested.store(true, std::memory_order_relaxed);
	if (job->state == "queued" || job->state == "ready") {
		job->state = "cancelled";
		job->reason = job->section_pack ? "tree_section_pack_cancelled" : "tree_foliage_compile_cancelled";
		job->anchors.clear();
		job->branches.clear();
		job->instance_values.clear();
		job->branch_instance_values.clear();
		job->pack_input_values.clear();
		job->pack_sections.clear();
	}
	return status_result("ready", "tree_geometry_cancel_requested");
}

Dictionary NativeTreeGeometryDispatcher::release_tree_geometry_compile(const std::int64_t p_ticket) {
	if (!Thread::is_main_thread()) return status_result("failed", "tree_geometry_main_thread_required");
	std::lock_guard<std::mutex> lock(mutex_);
	const auto job = _find_job_locked(p_ticket);
	if (job == nullptr) return status_result("ready", "tree_geometry_job_missing");
	if (job->state == "queued" || job->state == "running") {
		job->release_requested = true;
		job->cancel_requested.store(true, std::memory_order_relaxed);
		if (job->state == "queued") {
			job->state = "cancelled";
			job->reason = "tree_foliage_compile_cancelled_before_start";
			job->anchors.clear();
			job->branches.clear();
			_reclaim_terminal_locked(job);
			return status_result("ready", "tree_geometry_queued_job_cancelled_and_released");
		}
		return status_result("pending", "tree_geometry_release_deferred_until_worker_exit");
	}
	_reclaim_terminal_locked(job);
	return status_result("ready", "tree_geometry_job_released");
}

Dictionary NativeTreeGeometryDispatcher::drain_tree_geometry_compiles() {
	if (!Thread::is_main_thread()) return status_result("failed", "tree_geometry_main_thread_required");
	_stop_and_join();
	return status_result("ready", "tree_geometry_dispatcher_drained");
}

Dictionary NativeTreeGeometryDispatcher::tree_geometry_compile_metrics() const {
	std::lock_guard<std::mutex> lock(mutex_);
	std::int64_t queued = 0, running = 0, ready = 0, failed = 0, cancelled = 0;
	for (const auto &job : jobs_) {
		if (job->state == "queued") ++queued;
		else if (job->state == "running") ++running;
		else if (job->state == "ready") ++ready;
		else if (job->state == "failed") ++failed;
		else if (job->state == "cancelled") ++cancelled;
	}
	Dictionary result;
	result["jobCount"] = static_cast<std::int64_t>(jobs_.size());
	result["queued"] = queued;
	result["running"] = running;
	result["ready"] = ready;
	result["failed"] = failed;
	result["cancelled"] = cancelled;
	result["retainedOutputFloats"] = static_cast<std::int64_t>(retained_output_floats_);
	result["drained"] = drained_;
	return result;
}

void NativeTreeGeometryDispatcher::_stop_and_join() {
	{
		std::lock_guard<std::mutex> lock(mutex_);
		if (drained_) return;
		stopping_ = true;
		for (const auto &job : jobs_) {
			job->cancel_requested.store(true, std::memory_order_relaxed);
			if (job->state == "queued") {
				job->state = "cancelled";
				job->reason = "tree_geometry_dispatcher_shutdown";
				job->anchors.clear();
				job->branches.clear();
				job->pack_input_values.clear();
			}
		}
	}
	work_available_.notify_all();
	for (std::thread &worker : workers_) if (worker.joinable()) worker.join();
	workers_.clear();
	{
		std::lock_guard<std::mutex> lock(mutex_);
		for (const auto &job : jobs_) {
			if (job->state == "running") {
				job->state = "cancelled";
				job->reason = "tree_geometry_dispatcher_shutdown";
			}
			job->anchors.clear();
			job->instance_values.clear();
			job->branches.clear();
			job->branch_instance_values.clear();
			job->pack_input_values.clear();
			job->pack_sections.clear();
		}
		jobs_.clear();
		retained_output_floats_ = 0U;
		drained_ = true;
	}
}
