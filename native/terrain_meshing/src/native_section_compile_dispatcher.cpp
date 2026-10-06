#include "native_section_compile_dispatcher.h"

#include "sha256.hpp"

#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/classes/thread.hpp>
#include <godot_cpp/variant/array.hpp>
#include <godot_cpp/variant/string_name.hpp>

#include <algorithm>
#include <chrono>
#include <cmath>
#include <limits>
#include <set>
#include <sstream>
#include <tuple>
#include <utility>

using namespace godot;
using namespace voxel::world_backend;

namespace {
constexpr const char *PREPARATION_SCHEMA = "static-section-compile-preparation/v1";
constexpr const char *INSTANCE_ATTRIBUTE_LAYOUT = "static-instance-transform-color-custom/v2";
constexpr std::int64_t RANGE_ACCOUNTING_BYTES = 96;

std::int64_t now_msec() {
	return std::chrono::duration_cast<std::chrono::milliseconds>(
		std::chrono::steady_clock::now().time_since_epoch()).count();
}

bool variant_to_string(const Variant &p_value, std::string &r_value) {
	if (p_value.get_type() != Variant::STRING) return false;
	r_value = String(p_value).utf8().get_data();
	return !r_value.empty();
}

bool is_sha256_text(const std::string &p_value) {
	if (p_value.size() != 64) return false;
	return std::all_of(p_value.begin(), p_value.end(), [](unsigned char value) {
		return (value >= '0' && value <= '9') ||
			(value >= 'a' && value <= 'f') || (value >= 'A' && value <= 'F');
	});
}

bool finite_float(const Variant &p_value, float &r_value) {
	if (p_value.get_type() != Variant::FLOAT && p_value.get_type() != Variant::INT) return false;
	const double value = static_cast<double>(p_value);
	if (!std::isfinite(value) || value < -std::numeric_limits<float>::max() ||
			value > std::numeric_limits<float>::max()) return false;
	r_value = static_cast<float>(value);
	return true;
}

template <typename BoundsType>
bool finite_positive_bounds(const BoundsType &p_bounds) {
	for (int index = 0; index < 3; ++index) {
		if (!std::isfinite(p_bounds.position[index]) || !std::isfinite(p_bounds.size[index]) ||
				p_bounds.size[index] <= 0.0F ||
				!std::isfinite(p_bounds.position[index] + p_bounds.size[index])) return false;
	}
	return true;
}

std::string merged_segment_id(const std::string &p_batch_key, std::int32_t p_index) {
	const std::string canonical = p_batch_key + "\n" + std::to_string(p_index);
	const Sha256Digest digest = sha256(reinterpret_cast<const std::uint8_t *>(canonical.data()), canonical.size());
	return "merged:" + sha256_hex(digest);
}

} // namespace

NativeSectionCompileDispatcher::NativeSectionCompileDispatcher() {
	workers_.reserve(2);
	for (int index = 0; index < 2; ++index) {
		workers_.emplace_back([this]() { _worker_loop(); });
	}
}

NativeSectionCompileDispatcher::~NativeSectionCompileDispatcher() {
	_stop_and_join();
}

void NativeSectionCompileDispatcher::_bind_methods() {
	ClassDB::bind_method(D_METHOD("submit_section_compile", "preparation", "identity"),
		&NativeSectionCompileDispatcher::submit_section_compile);
	ClassDB::bind_method(D_METHOD("set_compile_camera", "position", "camera_revision"),
		&NativeSectionCompileDispatcher::set_compile_camera);
	ClassDB::bind_method(D_METHOD("cancel_section_compile", "world_id", "world_epoch", "section_key", "generation"),
		&NativeSectionCompileDispatcher::cancel_section_compile);
	ClassDB::bind_method(D_METHOD("poll_section_compile", "ticket"),
		&NativeSectionCompileDispatcher::poll_section_compile);
	ClassDB::bind_method(D_METHOD("take_section_compile_result", "ticket"),
		&NativeSectionCompileDispatcher::take_section_compile_result);
	ClassDB::bind_method(D_METHOD("release_section_compile", "ticket"),
		&NativeSectionCompileDispatcher::release_section_compile);
	ClassDB::bind_method(D_METHOD("drain_section_compiles"),
		&NativeSectionCompileDispatcher::drain_section_compiles);
	ClassDB::bind_method(D_METHOD("metrics"), &NativeSectionCompileDispatcher::metrics);
}

bool NativeSectionCompileDispatcher::_parse_identity(const Dictionary &p_identity,
		JobIdentity &r_identity, std::string &r_reason) {
	if (!variant_to_string(p_identity.get("worldId", Variant()), r_identity.world_id) ||
			!variant_to_string(p_identity.get("worldEpoch", Variant()), r_identity.world_epoch) ||
			!variant_to_string(p_identity.get("providerRevisionDigest", Variant()),
				r_identity.provider_revision_digest) ||
			!variant_to_string(p_identity.get("coverageDigest", Variant()), r_identity.coverage_digest) ||
			!variant_to_string(p_identity.get("preparedPayloadDigest", Variant()),
				r_identity.prepared_payload_digest)) {
		r_reason = "incomplete_section_compile_identity";
		return false;
	}
	if (!is_sha256_text(r_identity.provider_revision_digest) ||
			!is_sha256_text(r_identity.coverage_digest) ||
			!is_sha256_text(r_identity.prepared_payload_digest)) {
		r_reason = "malformed_section_compile_digest";
		return false;
	}
	const Variant source_index = p_identity.get("sourceIndexRevision", Variant());
	if (source_index.get_type() == Variant::STRING) {
		r_identity.source_index_revision = String(source_index).utf8().get_data();
	} else if (source_index.get_type() == Variant::INT) {
		r_identity.source_index_revision = std::to_string(static_cast<std::int64_t>(source_index));
		r_identity.source_index_revision_is_integer = true;
		r_identity.source_index_revision_integer = static_cast<std::int64_t>(source_index);
	} else {
		r_reason = "invalid_section_compile_source_index_revision";
		return false;
	}
	return true;
}

bool NativeSectionCompileDispatcher::_read_bounds(const Variant &p_value, Bounds &r_bounds) {
	if (p_value.get_type() != Variant::AABB) return false;
	const AABB value = p_value;
	const Vector3 position = value.get_position();
	const Vector3 size = value.get_size();
	r_bounds.position[0] = static_cast<float>(position.x);
	r_bounds.position[1] = static_cast<float>(position.y);
	r_bounds.position[2] = static_cast<float>(position.z);
	r_bounds.size[0] = static_cast<float>(size.x);
	r_bounds.size[1] = static_cast<float>(size.y);
	r_bounds.size[2] = static_cast<float>(size.z);
	return finite_positive_bounds(r_bounds);
}

bool NativeSectionCompileDispatcher::_bounds_finite_and_positive(const Bounds &p_bounds) {
	return finite_positive_bounds(p_bounds);
}

bool NativeSectionCompileDispatcher::_preflight_preparation(const Dictionary &p_preparation,
		std::int64_t &r_input_bytes, std::int64_t &r_input_segments,
		std::int64_t &r_instance_count, std::int32_t r_section_key[3],
		float &r_section_size, float r_section_offset[3], std::string &r_reason) {
	if (String(p_preparation.get("schema", String())) != PREPARATION_SCHEMA ||
			String(p_preparation.get("instanceAttributeLayout", String())) != INSTANCE_ATTRIBUTE_LAYOUT) {
		r_reason = "unsupported_section_compile_preparation";
		return false;
	}
	const Variant section_key_value = p_preparation.get("sectionKey", Variant());
	const Variant section_bounds_value = p_preparation.get("sectionBounds", Variant());
	const Variant batch_keys_value = p_preparation.get("batchKeys", Variant());
	const Variant batches_value = p_preparation.get("batches", Variant());
	if (section_key_value.get_type() != Variant::VECTOR3I ||
			section_bounds_value.get_type() != Variant::AABB ||
			batch_keys_value.get_type() != Variant::ARRAY ||
			batches_value.get_type() != Variant::DICTIONARY) {
		r_reason = "incomplete_section_compile_preparation";
		return false;
	}
	const Vector3i section_key = section_key_value;
	r_section_key[0] = section_key.x;
	r_section_key[1] = section_key.y;
	r_section_key[2] = section_key.z;
	const AABB section_bounds = section_bounds_value;
	const Vector3 origin = section_bounds.get_position();
	const Vector3 size = section_bounds.get_size();
	if (!origin.is_finite() || !size.is_finite() || size.x <= 0.0 ||
			std::abs(size.x - size.y) > 0.0001 || std::abs(size.x - size.z) > 0.0001) {
		r_reason = "invalid_section_compile_bounds";
		return false;
	}
	r_section_size = static_cast<float>(size.x);
	r_section_offset[0] = static_cast<float>(origin.x);
	r_section_offset[1] = static_cast<float>(origin.y);
	r_section_offset[2] = static_cast<float>(origin.z);
	const Array batch_keys = batch_keys_value;
	const Dictionary batches = batches_value;
	if (batch_keys.size() > 4096 || batches.size() != batch_keys.size()) {
		r_reason = "section_compile_batch_count_limit";
		return false;
	}
	std::string previous_batch_key;
	std::set<std::tuple<std::string, std::string, std::string, std::string>> seen_segments;
	for (int64_t batch_index = 0; batch_index < batch_keys.size(); ++batch_index) {
		std::string batch_key;
		if (!variant_to_string(batch_keys[batch_index], batch_key) ||
				(!previous_batch_key.empty() && batch_key <= previous_batch_key) ||
				!batches.has(String(batch_key.c_str()))) {
			r_reason = "invalid_or_unsorted_section_compile_batch_keys";
			return false;
		}
		previous_batch_key = batch_key;
		const Variant batch_value = batches.get(String(batch_key.c_str()), Variant());
		if (batch_value.get_type() != Variant::DICTIONARY) {
			r_reason = "invalid_section_compile_batch";
			return false;
		}
		const Variant contributions_value = Dictionary(batch_value).get("inputContributions", Variant());
		if (contributions_value.get_type() != Variant::ARRAY) {
			r_reason = "missing_section_compile_contributions";
			return false;
		}
		const Array contributions = contributions_value;
		if (contributions.size() > 4096 - r_input_segments) {
			r_reason = "section_compile_input_segment_limit";
			return false;
		}
		for (int64_t contribution_index = 0; contribution_index < contributions.size(); ++contribution_index) {
			const Variant contribution_value = contributions[contribution_index];
			if (contribution_value.get_type() != Variant::DICTIONARY) {
				r_reason = "invalid_section_compile_contribution";
				return false;
			}
			const Dictionary contribution = contribution_value;
			std::string source_id, source_part_id, source_revision, segment_id;
			Bounds bounds;
			if (!variant_to_string(contribution.get("sourceId", Variant()), source_id) ||
					!variant_to_string(contribution.get("sourcePartId", Variant()), source_part_id) ||
					!variant_to_string(contribution.get("sourceRevision", Variant()), source_revision) ||
					!variant_to_string(contribution.get("segmentId", Variant()), segment_id) ||
					!_read_bounds(contribution.get("bounds", Variant()), bounds)) {
				r_reason = "incomplete_section_compile_contribution_identity";
				return false;
			}
			if (!seen_segments.emplace(batch_key, source_id, source_part_id, segment_id).second) {
				r_reason = "duplicate_section_compile_source_segment";
				return false;
			}
			const Variant count_value = contribution.get("instanceCount", Variant());
			const Variant buffer_value = contribution.get("buffer", Variant());
			if (count_value.get_type() != Variant::INT || buffer_value.get_type() != Variant::ARRAY) {
				r_reason = "invalid_section_compile_instance_payload";
				return false;
			}
			const std::int64_t count = static_cast<std::int64_t>(count_value);
			const Array buffer = buffer_value;
			if (count <= 0 || count > MAX_INSTANCES_PER_SEGMENT ||
					buffer.get_typed_builtin() != Variant::FLOAT ||
					buffer.size() != count * FLOATS_PER_INSTANCE) {
				r_reason = "section_compile_instance_buffer_count_mismatch";
				return false;
			}
			const std::int64_t bytes = count * FLOATS_PER_INSTANCE * 4;
			if (bytes > MAX_JOB_INPUT_BYTES - r_input_bytes) {
				r_reason = "section_compile_input_byte_limit";
				return false;
			}
			r_input_bytes += bytes;
			r_instance_count += count;
			r_input_segments++;
		}
	}
	const Variant declared_instances = p_preparation.get("instanceCount", Variant());
	const Variant declared_segments = p_preparation.get("inputSegmentCount", Variant());
	if (declared_instances.get_type() != Variant::INT || declared_segments.get_type() != Variant::INT ||
			static_cast<std::int64_t>(declared_instances) != r_instance_count ||
			static_cast<std::int64_t>(declared_segments) != r_input_segments) {
		r_reason = "section_compile_preparation_count_mismatch";
		return false;
	}
	return true;
}

bool NativeSectionCompileDispatcher::_copy_preparation(const Dictionary &p_preparation,
		Job &r_job, std::string &r_reason) {
	if (String(p_preparation.get("schema", String())) != PREPARATION_SCHEMA ||
			String(p_preparation.get("instanceAttributeLayout", String())) != INSTANCE_ATTRIBUTE_LAYOUT) {
		r_reason = "unsupported_section_compile_preparation";
		return false;
	}
	const Variant section_key_value = p_preparation.get("sectionKey", Variant());
	const Variant section_bounds_value = p_preparation.get("sectionBounds", Variant());
	const Variant batch_keys_value = p_preparation.get("batchKeys", Variant());
	const Variant batches_value = p_preparation.get("batches", Variant());
	if (section_key_value.get_type() != Variant::VECTOR3I ||
			section_bounds_value.get_type() != Variant::AABB ||
			batch_keys_value.get_type() != Variant::ARRAY ||
			batches_value.get_type() != Variant::DICTIONARY) {
		r_reason = "incomplete_section_compile_preparation";
		return false;
	}
	const Vector3i section_key = section_key_value;
	r_job.section_key[0] = section_key.x;
	r_job.section_key[1] = section_key.y;
	r_job.section_key[2] = section_key.z;
	const AABB section_bounds = section_bounds_value;
	const Vector3 section_origin = section_bounds.get_position();
	const Vector3 section_size = section_bounds.get_size();
	if (!section_origin.is_finite() || !section_size.is_finite() ||
			section_size.x <= 0.0 || std::abs(section_size.x - section_size.y) > 0.0001 ||
			std::abs(section_size.x - section_size.z) > 0.0001) {
		r_reason = "invalid_section_compile_bounds";
		return false;
	}
	r_job.section_size = static_cast<float>(section_size.x);
	r_job.section_offset[0] = static_cast<float>(section_origin.x);
	r_job.section_offset[1] = static_cast<float>(section_origin.y);
	r_job.section_offset[2] = static_cast<float>(section_origin.z);
	const Array batch_keys = batch_keys_value;
	const Dictionary batches = batches_value;
	std::int64_t total_bytes = 0;
	std::int64_t expected_instances = 0;
	std::int64_t input_segment_count = 0;
	std::string previous_batch_key;
	for (int64_t batch_index = 0; batch_index < batch_keys.size(); ++batch_index) {
		std::string batch_key;
		if (!variant_to_string(batch_keys[batch_index], batch_key) ||
				(!previous_batch_key.empty() && batch_key <= previous_batch_key) ||
				!batches.has(String(batch_key.c_str()))) {
			r_reason = "invalid_or_unsorted_section_compile_batch_keys";
			return false;
		}
		previous_batch_key = batch_key;
		const Variant batch_value = batches.get(String(batch_key.c_str()), Variant());
		if (batch_value.get_type() != Variant::DICTIONARY) {
			r_reason = "invalid_section_compile_batch";
			return false;
		}
		const Dictionary batch = batch_value;
		const Variant contributions_value = batch.get("inputContributions", Variant());
		if (contributions_value.get_type() != Variant::ARRAY) {
			r_reason = "missing_section_compile_contributions";
			return false;
		}
		const Array contributions = contributions_value;
		InputGroup group;
		group.batch_key = batch_key;
		group.contributions.reserve(contributions.size());
		for (int64_t contribution_index = 0; contribution_index < contributions.size(); ++contribution_index) {
			const Variant contribution_value = contributions[contribution_index];
			if (contribution_value.get_type() != Variant::DICTIONARY) {
				r_reason = "invalid_section_compile_contribution";
				return false;
			}
			const Dictionary contribution = contribution_value;
			InputContribution input;
			if (!variant_to_string(contribution.get("sourceId", Variant()), input.source_id) ||
					!variant_to_string(contribution.get("sourcePartId", Variant()), input.source_part_id) ||
					!variant_to_string(contribution.get("sourceRevision", Variant()), input.source_revision) ||
					!variant_to_string(contribution.get("segmentId", Variant()), input.segment_id) ||
					!_read_bounds(contribution.get("bounds", Variant()), input.bounds)) {
				r_reason = "incomplete_section_compile_contribution_identity";
				return false;
			}
			const Variant count_value = contribution.get("instanceCount", Variant());
			if (count_value.get_type() != Variant::INT) {
				r_reason = "invalid_section_compile_instance_count";
				return false;
			}
			const int64_t count = static_cast<std::int64_t>(count_value);
			if (count <= 0 || count > MAX_INSTANCES_PER_SEGMENT) {
				r_reason = "section_compile_instance_count_out_of_range";
				return false;
			}
			input.instance_count = static_cast<std::int32_t>(count);
			const Variant buffer_value = contribution.get("buffer", Variant());
			if (buffer_value.get_type() != Variant::ARRAY) {
				r_reason = "invalid_section_compile_instance_buffer";
				return false;
			}
			const Array buffer = buffer_value;
			if (buffer.get_typed_builtin() != Variant::FLOAT ||
					buffer.size() != count * FLOATS_PER_INSTANCE) {
				r_reason = "section_compile_instance_buffer_count_mismatch";
				return false;
			}
			const std::int64_t contribution_bytes = count * FLOATS_PER_INSTANCE * 4;
			if (contribution_bytes > MAX_JOB_INPUT_BYTES - total_bytes) {
				r_reason = "section_compile_input_byte_limit";
				return false;
			}
			total_bytes += contribution_bytes;
			input.buffer.reserve(static_cast<std::size_t>(buffer.size()));
			for (int64_t float_index = 0; float_index < buffer.size(); ++float_index) {
				float component = 0.0F;
				if (!finite_float(buffer[float_index], component)) {
					r_reason = "non_finite_section_compile_instance_value";
					return false;
				}
				input.buffer.push_back(component);
			}
			if (expected_instances > std::numeric_limits<std::int64_t>::max() - count) {
				r_reason = "section_compile_instance_count_overflow";
				return false;
			}
			expected_instances += count;
			input_segment_count++;
			group.contributions.push_back(std::move(input));
		}
		r_job.groups.push_back(std::move(group));
	}
	if (batches.size() != batch_keys.size() ||
			static_cast<std::int64_t>(p_preparation.get("instanceCount", int64_t(-1))) != expected_instances ||
			static_cast<std::int64_t>(p_preparation.get("inputSegmentCount", int64_t(-1))) != input_segment_count) {
		r_reason = "section_compile_preparation_count_mismatch";
		return false;
	}
	r_job.input_bytes = total_bytes;
	return true;
}


std::string NativeSectionCompileDispatcher::_slot_key(const std::string &p_world_id,
		const std::string &p_world_epoch, const std::int32_t p_section_key[3]) {
	return p_world_id + "\n" + p_world_epoch + "\n" + std::to_string(p_section_key[0]) + "," +
		std::to_string(p_section_key[1]) + "," + std::to_string(p_section_key[2]);
}

std::int64_t NativeSectionCompileDispatcher::_latest_generation_locked(const Job &p_job) const {
	const auto found = latest_generations_.find(_slot_key(p_job.identity.world_id,
		p_job.identity.world_epoch, p_job.section_key));
	return found == latest_generations_.end() ? 0 : found->second;
}

std::shared_ptr<NativeSectionCompileDispatcher::Job>
NativeSectionCompileDispatcher::_find_job_locked(std::int64_t p_ticket) const {
	for (const std::shared_ptr<Job> &job : jobs_) {
		if (job->ticket == p_ticket) return job;
	}
	return nullptr;
}

std::shared_ptr<NativeSectionCompileDispatcher::Job>
NativeSectionCompileDispatcher::_choose_next_job_locked() const {
	const std::int64_t now = now_msec();
	std::shared_ptr<Job> oldest;
	std::shared_ptr<Job> nearest;
	double nearest_distance = std::numeric_limits<double>::infinity();
	for (const std::shared_ptr<Job> &job : jobs_) {
		if (job->state != "queued" || job->cancel_requested.load(std::memory_order_relaxed)) continue;
		if (oldest == nullptr || job->submitted_msec < oldest->submitted_msec ||
				(job->submitted_msec == oldest->submitted_msec && job->ticket < oldest->ticket)) {
			oldest = job;
		}
		const double half = static_cast<double>(job->section_size) * 0.5;
		const double center[3] = {
			static_cast<double>(job->section_key[0]) * job->section_size + job->section_offset[0] + half,
			static_cast<double>(job->section_key[1]) * job->section_size + job->section_offset[1] + half,
			static_cast<double>(job->section_key[2]) * job->section_size + job->section_offset[2] + half};
		const double dx = center[0] - camera_position_[0];
		const double dy = center[1] - camera_position_[1];
		const double dz = center[2] - camera_position_[2];
		const double distance = dx * dx + dy * dy + dz * dz;
		if (nearest == nullptr || distance < nearest_distance ||
				(distance == nearest_distance && job->ticket < nearest->ticket)) {
			nearest = job;
			nearest_distance = distance;
		}
	}
	if (oldest != nullptr && now - oldest->submitted_msec >= STARVATION_MSEC) return oldest;
	return nearest;
}

void NativeSectionCompileDispatcher::_reclaim_terminal_locked(const std::shared_ptr<Job> &p_job) {
	if (p_job == nullptr) return;
	retained_buffer_bytes_ = std::max<std::int64_t>(0, retained_buffer_bytes_ - p_job->reserved_bytes);
	p_job->reserved_bytes = 0;
	auto found = std::find(jobs_.begin(), jobs_.end(), p_job);
	if (found != jobs_.end()) jobs_.erase(found);
}

Variant NativeSectionCompileDispatcher::_bounds_variant(const Bounds &p_bounds) {
	return AABB(Vector3(p_bounds.position[0], p_bounds.position[1], p_bounds.position[2]),
		Vector3(p_bounds.size[0], p_bounds.size[1], p_bounds.size[2]));
}

Dictionary NativeSectionCompileDispatcher::_identity_dictionary(const Job &p_job) {
	Dictionary identity;
	identity["worldId"] = String(p_job.identity.world_id.c_str());
	identity["worldEpoch"] = String(p_job.identity.world_epoch.c_str());
	identity["sectionKey"] = Vector3i(p_job.section_key[0], p_job.section_key[1], p_job.section_key[2]);
	identity["generation"] = p_job.generation;
	identity["providerRevisionDigest"] = String(p_job.identity.provider_revision_digest.c_str());
	identity["sourceIndexRevision"] = p_job.identity.source_index_revision_is_integer ?
		Variant(p_job.identity.source_index_revision_integer) :
		Variant(String(p_job.identity.source_index_revision.c_str()));
	identity["coverageDigest"] = String(p_job.identity.coverage_digest.c_str());
	identity["preparedPayloadDigest"] = String(p_job.identity.prepared_payload_digest.c_str());
	identity.make_read_only();
	return identity;
}

Dictionary NativeSectionCompileDispatcher::_materialize_result(const Job &p_job) {
	Dictionary result;
	result["status"] = "ready";
	result["ticket"] = p_job.ticket;
	result["identity"] = _identity_dictionary(p_job);
	Dictionary groups;
	for (const OutputGroup &group : p_job.output_groups) {
		Array segments;
		for (const OutputSegment &segment : group.segments) {
			Array buffer;
			buffer.set_typed(Variant::FLOAT, StringName(), Variant());
			for (float value : segment.buffer) buffer.push_back(value);
			buffer.make_read_only();
			Array source_ranges;
			for (const SourceRange &range : segment.source_ranges) {
				Dictionary row;
				row["batchKey"] = String(group.batch_key.c_str());
				row["batchIndex"] = range.batch_index;
				row["firstInstance"] = range.first_instance;
				row["instanceCount"] = range.instance_count;
				row["sourceId"] = String(range.source_id.c_str());
				row["sourcePartId"] = String(range.source_part_id.c_str());
				row["sourceRevision"] = String(range.source_revision.c_str());
				row["sourceSegmentId"] = String(range.source_segment_id.c_str());
				row["sourceFirstInstance"] = range.source_first_instance;
				row.make_read_only();
				source_ranges.push_back(row);
			}
			source_ranges.make_read_only();
			Dictionary value;
			value["segmentId"] = String(segment.segment_id.c_str());
			value["instanceAttributeLayout"] = INSTANCE_ATTRIBUTE_LAYOUT;
			value["batchIndex"] = segment.batch_index;
			value["buffer"] = buffer;
			value["bounds"] = _bounds_variant(segment.bounds);
			value["instanceCount"] = segment.instance_count;
			value["sourceRanges"] = source_ranges;
			value.make_read_only();
			segments.push_back(value);
		}
		segments.make_read_only();
		groups[String(group.batch_key.c_str())] = segments;
	}
	groups.make_read_only();
	result["groups"] = groups;
	result.make_read_only();
	return result;
}

Dictionary NativeSectionCompileDispatcher::_job_status(const Job &p_job,
		bool p_include_result) const {
	Dictionary result;
	result["status"] = String(p_job.state.c_str());
	result["ticket"] = p_job.ticket;
	result["sectionKey"] = Vector3i(p_job.section_key[0], p_job.section_key[1], p_job.section_key[2]);
	result["generation"] = p_job.generation;
	if (!p_job.reason.empty()) result["reason"] = String(p_job.reason.c_str());
	if (p_include_result && p_job.state == "ready") return _materialize_result(p_job);
	return result;
}

std::string NativeSectionCompileDispatcher::_compile_job(const std::shared_ptr<Job> &p_job,
		std::vector<OutputGroup> &r_output_groups, std::string &r_reason) {
	std::vector<OutputGroup> output_groups;
	output_groups.reserve(p_job->groups.size());
	for (const InputGroup &group : p_job->groups) {
		if (p_job->cancel_requested.load(std::memory_order_relaxed)) {
			r_reason = "section_compile_cancelled";
			return "cancelled";
		}
		OutputGroup output_group;
		output_group.batch_key = group.batch_key;
		OutputSegment current;
		current.batch_index = 0;
		current.segment_id = merged_segment_id(group.batch_key, current.batch_index);
		for (const InputContribution &input : group.contributions) {
			if (p_job->cancel_requested.load(std::memory_order_relaxed)) {
				r_reason = "section_compile_cancelled";
				return "cancelled";
			}
			if (!_bounds_finite_and_positive(input.bounds) || input.instance_count <= 0 ||
					input.buffer.size() != static_cast<std::size_t>(input.instance_count * FLOATS_PER_INSTANCE)) {
				r_reason = "section_compile_input_changed_after_admission";
				return "failed";
			}
			std::int32_t source_cursor = 0;
			while (source_cursor < input.instance_count) {
				if (p_job->cancel_requested.load(std::memory_order_relaxed)) {
					r_reason = "section_compile_cancelled";
					return "cancelled";
				}
				const std::int32_t available = MAX_INSTANCES_PER_SEGMENT - current.instance_count;
				const std::int32_t count = std::min(available, input.instance_count - source_cursor);
				if (count <= 0) {
					r_reason = "section_compile_segment_capacity";
					return "failed";
				}
				const std::int32_t output_first = current.instance_count;
				if (current.instance_count == 0) current.bounds = input.bounds;
				else {
					for (int axis = 0; axis < 3; ++axis) {
						const float low = std::min(current.bounds.position[axis], input.bounds.position[axis]);
						const float high = std::max(current.bounds.position[axis] + current.bounds.size[axis],
							input.bounds.position[axis] + input.bounds.size[axis]);
						current.bounds.position[axis] = low;
						current.bounds.size[axis] = high - low;
					}
				}
				const std::size_t source_begin = static_cast<std::size_t>(source_cursor) * FLOATS_PER_INSTANCE;
				const std::size_t source_end = static_cast<std::size_t>(source_cursor + count) * FLOATS_PER_INSTANCE;
				current.buffer.insert(current.buffer.end(), input.buffer.begin() + source_begin,
					input.buffer.begin() + source_end);
				current.source_ranges.push_back({input.source_id, input.source_part_id,
					input.source_revision, input.segment_id, current.batch_index,
					output_first, count, source_cursor});
				current.instance_count += count;
				source_cursor += count;
				if (current.instance_count == MAX_INSTANCES_PER_SEGMENT) {
					output_group.segments.push_back(std::move(current));
					current = OutputSegment();
					current.batch_index = static_cast<std::int32_t>(output_group.segments.size());
					current.segment_id = merged_segment_id(group.batch_key, current.batch_index);
				}
			}
		}
		if (current.instance_count > 0) output_group.segments.push_back(std::move(current));
		output_groups.push_back(std::move(output_group));
	}
	if (p_job->cancel_requested.load(std::memory_order_relaxed)) {
		r_reason = "section_compile_cancelled";
		return "cancelled";
	}
	r_output_groups = std::move(output_groups);
	return "ready";
}

void NativeSectionCompileDispatcher::_worker_loop() {
	while (true) {
		std::shared_ptr<Job> job;
		{
			std::unique_lock<std::mutex> lock(mutex_);
			work_available_.wait(lock, [this]() {
				if (stopping_) return true;
				return std::any_of(jobs_.begin(), jobs_.end(), [](const std::shared_ptr<Job> &item) {
					return item->state == "queued";
				});
			});
			if (stopping_) return;
			job = _choose_next_job_locked();
			if (job == nullptr) continue;
			if (_latest_generation_locked(*job) != job->generation) {
				job->state = "stale";
				job->reason = "section_compile_generation_superseded";
				continue;
			}
			job->state = "running";
		}
		std::vector<OutputGroup> compiled_groups;
		std::string compile_reason;
		const std::string compile_state = _compile_job(job, compiled_groups, compile_reason);
		{
			std::lock_guard<std::mutex> lock(mutex_);
			job->state = compile_state;
			job->reason = compile_reason;
			if (job->cancel_requested.load(std::memory_order_relaxed) && job->state == "ready") {
				job->state = "cancelled";
				job->reason = "section_compile_cancelled";
			}
			if (job->state == "ready" && _latest_generation_locked(*job) != job->generation) {
				job->state = "stale";
				job->reason = "section_compile_generation_superseded";
			}
			if (job->state == "ready") job->output_groups = std::move(compiled_groups);
			else compiled_groups.clear();
			job->groups.clear();
			job->groups.shrink_to_fit();
			std::int64_t output_bytes = 0;
			for (const OutputGroup &group : job->output_groups) {
				for (const OutputSegment &segment : group.segments) {
					output_bytes += static_cast<std::int64_t>(segment.buffer.size()) * 4;
					output_bytes += static_cast<std::int64_t>(segment.source_ranges.size()) * RANGE_ACCOUNTING_BYTES;
				}
			}
			if (output_bytes > MAX_RETAINED_BUFFER_BYTES ||
					retained_buffer_bytes_ - job->reserved_bytes > MAX_RETAINED_BUFFER_BYTES - output_bytes) {
				job->state = "failed";
				job->reason = "section_compile_result_capacity";
				job->output_groups.clear();
				output_bytes = 0;
			}
			retained_buffer_bytes_ = std::max<std::int64_t>(0, retained_buffer_bytes_ - job->reserved_bytes);
			job->reserved_bytes = output_bytes;
			retained_buffer_bytes_ += job->reserved_bytes;
			job->finished_bytes = output_bytes;
			if (job->release_requested) _reclaim_terminal_locked(job);
		}
	}
}

Dictionary NativeSectionCompileDispatcher::submit_section_compile(
		const Dictionary &p_preparation, const Dictionary &p_identity) {
	if (!Thread::is_main_thread()) {
		Dictionary result;
		result["status"] = "failed";
		result["reason"] = "section_compile_main_thread_required";
		return result;
	}
	auto job = std::make_shared<Job>();
	std::string reason;
	if (!_parse_identity(p_identity, job->identity, reason)) {
		Dictionary result;
		result["status"] = "failed";
		result["reason"] = String(reason.c_str());
		return result;
	}
	const Variant identity_section = p_identity.get("sectionKey", Variant());
	const Variant identity_generation = p_identity.get("generation", Variant());
	std::int64_t estimated_input_bytes = 0;
	std::int64_t estimated_input_segments = 0;
	std::int64_t estimated_instance_count = 0;
	float section_size = 0.0F;
	float section_offset[3] = {};
	if (identity_section.get_type() != Variant::VECTOR3I || identity_generation.get_type() != Variant::INT ||
			static_cast<std::int64_t>(identity_generation) <= 0 ||
			!_preflight_preparation(p_preparation, estimated_input_bytes,
				estimated_input_segments, estimated_instance_count, job->section_key,
				section_size, section_offset, reason)) {
		Dictionary result;
		result["status"] = "failed";
		result["reason"] = String(reason.empty() ? "invalid_section_compile_slot_identity" : reason.c_str());
		return result;
	}
	const Vector3i identity_key = identity_section;
	const Vector3i prep_key(job->section_key[0], job->section_key[1], job->section_key[2]);
	job->generation = static_cast<std::int64_t>(identity_generation);
	job->section_size = section_size;
	std::copy(section_offset, section_offset + 3, job->section_offset);
	if (identity_key != prep_key) {
		Dictionary result;
		result["status"] = "failed";
		result["reason"] = "section_compile_identity_key_mismatch";
		return result;
	}
	job->submitted_msec = now_msec();
	const std::int64_t reserved_bytes = estimated_input_bytes * 2 +
		estimated_input_segments *
			RANGE_ACCOUNTING_BYTES * 2;
	if (estimated_input_bytes > MAX_JOB_INPUT_BYTES || reserved_bytes > MAX_RETAINED_BUFFER_BYTES) {
		Dictionary result;
		result["status"] = "backpressure";
		result["reason"] = "section_compile_job_capacity";
		return result;
	}
	{
		std::lock_guard<std::mutex> lock(mutex_);
		if (stopping_ || drained_) {
			Dictionary result;
			result["status"] = "failed";
			result["reason"] = "section_compile_dispatcher_draining";
			return result;
		}
		const std::string slot = _slot_key(job->identity.world_id,
			job->identity.world_epoch, job->section_key);
		const auto latest = latest_generations_.find(slot);
		if (latest != latest_generations_.end() && job->generation <= latest->second) {
			Dictionary result;
			result["status"] = "failed";
			result["reason"] = "stale_section_compile_generation";
			return result;
		}
		if (jobs_.size() >= static_cast<std::size_t>(MAX_JOBS) ||
				reserved_bytes > MAX_RETAINED_BUFFER_BYTES - retained_buffer_bytes_) {
			Dictionary result;
			result["status"] = "backpressure";
			result["reason"] = "section_compile_dispatcher_capacity";
			return result;
		}
		job->ticket = next_ticket_++;
		job->reserved_bytes = reserved_bytes;
		job->state = "copying";
		latest_generations_[slot] = job->generation;
		for (const std::shared_ptr<Job> &previous : jobs_) {
			if (previous->identity.world_id == job->identity.world_id &&
					previous->identity.world_epoch == job->identity.world_epoch &&
					previous->section_key[0] == job->section_key[0] &&
					previous->section_key[1] == job->section_key[1] &&
					previous->section_key[2] == job->section_key[2] &&
					previous->generation < job->generation &&
					(previous->state == "queued" || previous->state == "running" ||
						previous->state == "ready")) {
				previous->cancel_requested.store(true, std::memory_order_relaxed);
				if (previous->state == "queued") {
					previous->state = "cancelled";
					previous->reason = "section_compile_generation_superseded";
					previous->groups.clear();
				} else if (previous->state == "ready") {
					previous->state = "stale";
					previous->reason = "section_compile_generation_superseded";
					previous->output_groups.clear();
				}
			}
		}
		retained_buffer_bytes_ += reserved_bytes;
		jobs_.push_back(job);
	}
	if (!_copy_preparation(p_preparation, *job, reason) || job->input_bytes != estimated_input_bytes) {
		std::lock_guard<std::mutex> lock(mutex_);
		job->state = "failed";
		job->reason = reason.empty() ? "section_compile_preflight_copy_mismatch" : reason;
		job->groups.clear();
		retained_buffer_bytes_ = std::max<std::int64_t>(0,
			retained_buffer_bytes_ - job->reserved_bytes);
		job->reserved_bytes = 0;
		_reclaim_terminal_locked(job);
		Dictionary result;
		result["status"] = "failed";
		result["reason"] = String(job->reason.c_str());
		return result;
	}
	{
		std::lock_guard<std::mutex> lock(mutex_);
		if (job->cancel_requested.load(std::memory_order_relaxed) || stopping_) {
			job->state = "cancelled";
			job->reason = "section_compile_cancelled_during_capture";
			job->groups.clear();
			retained_buffer_bytes_ = std::max<std::int64_t>(0,
				retained_buffer_bytes_ - job->reserved_bytes);
			job->reserved_bytes = 0;
			_reclaim_terminal_locked(job);
			Dictionary result;
			result["status"] = "cancelled";
			result["reason"] = String(job->reason.c_str());
			return result;
		}
		job->state = "queued";
	}
	work_available_.notify_one();
	Dictionary result;
	result["status"] = "queued";
	result["ticket"] = job->ticket;
	result["sectionKey"] = identity_key;
	result["generation"] = job->generation;
	return result;
}

Dictionary NativeSectionCompileDispatcher::set_compile_camera(const Vector3 &p_position,
		std::int64_t p_camera_revision) {
	if (!Thread::is_main_thread()) return Dictionary();
	if (!p_position.is_finite()) {
		Dictionary result;
		result["status"] = "failed";
		result["reason"] = "invalid_section_compile_camera";
		return result;
	}
	{
		std::lock_guard<std::mutex> lock(mutex_);
		if (p_camera_revision < camera_revision_) {
			Dictionary result;
			result["status"] = "stale";
			result["reason"] = "section_compile_camera_revision_stale";
			return result;
		}
		camera_position_[0] = static_cast<float>(p_position.x);
		camera_position_[1] = static_cast<float>(p_position.y);
		camera_position_[2] = static_cast<float>(p_position.z);
		camera_revision_ = p_camera_revision;
	}
	work_available_.notify_all();
	Dictionary result;
	result["status"] = "ready";
	result["cameraRevision"] = p_camera_revision;
	return result;
}

Dictionary NativeSectionCompileDispatcher::cancel_section_compile(
		const String &p_world_id_value, const String &p_world_epoch_value,
		const Vector3i &p_section_key, std::int64_t p_generation) {
	const std::string world_id = p_world_id_value.utf8().get_data();
	const std::string world_epoch = p_world_epoch_value.utf8().get_data();
	std::lock_guard<std::mutex> lock(mutex_);
	std::int64_t cancelled = 0;
	for (const std::shared_ptr<Job> &job : jobs_) {
		if (job->identity.world_id != world_id || job->identity.world_epoch != world_epoch ||
				job->section_key[0] != p_section_key.x || job->section_key[1] != p_section_key.y ||
				job->section_key[2] != p_section_key.z || job->generation != p_generation) continue;
		if (job->state == "queued") {
			job->cancel_requested.store(true, std::memory_order_relaxed);
			job->groups.clear();
			job->state = "cancelled";
			job->reason = "section_compile_cancelled";
			cancelled++;
		} else if (job->state == "running") {
			job->cancel_requested.store(true, std::memory_order_relaxed);
			cancelled++;
		} else if (job->state == "ready") {
			job->cancel_requested.store(true, std::memory_order_relaxed);
			job->output_groups.clear();
			job->state = "cancelled";
			job->reason = "section_compile_cancelled";
			retained_buffer_bytes_ = std::max<std::int64_t>(0,
				retained_buffer_bytes_ - job->reserved_bytes);
			job->reserved_bytes = 0;
			cancelled++;
		}
	}
	work_available_.notify_all();
	Dictionary result;
	result["status"] = "cancelled";
	result["cancelledJobs"] = cancelled;
	return result;
}

Dictionary NativeSectionCompileDispatcher::poll_section_compile(std::int64_t p_ticket) const {
	std::lock_guard<std::mutex> lock(mutex_);
	const std::shared_ptr<Job> job = _find_job_locked(p_ticket);
	if (job == nullptr) {
		Dictionary result;
		result["status"] = "failed";
		result["reason"] = "unknown_section_compile_ticket";
		return result;
	}
	Dictionary result = _job_status(*job, false);
	if (job->state == "ready" && _latest_generation_locked(*job) != job->generation) {
		result["status"] = "stale";
		result["reason"] = "section_compile_generation_superseded";
	}
	return result;
}

Dictionary NativeSectionCompileDispatcher::take_section_compile_result(std::int64_t p_ticket) {
	std::lock_guard<std::mutex> lock(mutex_);
	const std::shared_ptr<Job> job = _find_job_locked(p_ticket);
	if (job == nullptr) {
		Dictionary result;
		result["status"] = "failed";
		result["reason"] = "unknown_section_compile_ticket";
		return result;
	}
	if (job->state != "ready") {
		Dictionary result = _job_status(*job, false);
		result["reason"] = job->reason.empty() ? "section_compile_result_not_ready" : String(job->reason.c_str());
		return result;
	}
	if (_latest_generation_locked(*job) != job->generation) {
		job->state = "stale";
		job->reason = "section_compile_generation_superseded";
		job->output_groups.clear();
		_reclaim_terminal_locked(job);
		Dictionary result;
		result["status"] = "stale";
		result["reason"] = "section_compile_generation_superseded";
		return result;
	}
	Dictionary result = _materialize_result(*job);
	_reclaim_terminal_locked(job);
	return result;
}

Dictionary NativeSectionCompileDispatcher::release_section_compile(std::int64_t p_ticket) {
	std::lock_guard<std::mutex> lock(mutex_);
	const std::shared_ptr<Job> job = _find_job_locked(p_ticket);
	if (job == nullptr) {
		Dictionary result;
		result["status"] = "released";
		result["alreadyReleased"] = true;
		return result;
	}
	if (job->state == "queued") {
		job->cancel_requested.store(true, std::memory_order_relaxed);
		job->groups.clear();
		job->state = "cancelled";
		job->reason = "section_compile_released";
		_reclaim_terminal_locked(job);
	} else if (job->state == "running") {
		job->cancel_requested.store(true, std::memory_order_relaxed);
		job->release_requested = true;
		job->reason = "section_compile_release_pending";
		work_available_.notify_all();
		Dictionary result;
		result["status"] = "pending";
		result["reason"] = "worker_cancellation_pending";
		return result;
	} else {
		_reclaim_terminal_locked(job);
	}
	Dictionary result;
	result["status"] = "released";
	return result;
}

void NativeSectionCompileDispatcher::_stop_and_join() {
	{
		std::lock_guard<std::mutex> lock(mutex_);
		if (drained_) return;
		stopping_ = true;
		for (const std::shared_ptr<Job> &job : jobs_) {
			job->cancel_requested.store(true, std::memory_order_relaxed);
			if (job->state == "queued") {
				job->state = "cancelled";
				job->reason = "section_compile_dispatcher_shutdown";
				job->groups.clear();
			}
		}
	}
	work_available_.notify_all();
	for (std::thread &worker : workers_) {
		if (worker.joinable()) worker.join();
	}
	workers_.clear();
	{
		std::lock_guard<std::mutex> lock(mutex_);
		jobs_.clear();
		latest_generations_.clear();
		retained_buffer_bytes_ = 0;
		drained_ = true;
	}
}

Dictionary NativeSectionCompileDispatcher::drain_section_compiles() {
	_stop_and_join();
	Dictionary result;
	result["status"] = "drained";
	result["pendingJobCount"] = 0;
	result["workerCount"] = static_cast<std::int64_t>(workers_.size());
	result["retainedBufferBytes"] = int64_t(0);
	result["activeJobCount"] = int64_t(0);
	return result;
}

Dictionary NativeSectionCompileDispatcher::metrics() const {
	std::lock_guard<std::mutex> lock(mutex_);
	std::int64_t queued = 0;
	std::int64_t running = 0;
	std::int64_t ready = 0;
	std::int64_t failed = 0;
	std::int64_t cancelled = 0;
	for (const std::shared_ptr<Job> &job : jobs_) {
		if (job->state == "queued") queued++;
		else if (job->state == "running") running++;
		else if (job->state == "ready") ready++;
		else if (job->state == "failed" || job->state == "stale") failed++;
		else if (job->state == "cancelled") cancelled++;
	}
	Dictionary result;
	result["status"] = stopping_ ? "draining" : "ready";
	result["workers"] = static_cast<std::int64_t>(workers_.size());
	result["queuedJobs"] = queued;
	result["runningJobs"] = running;
	result["readyResults"] = ready;
	result["failedResults"] = failed;
	result["cancelledResults"] = cancelled;
	result["retainedBufferBytes"] = retained_buffer_bytes_;
	result["cameraRevision"] = camera_revision_;
	return result;
}
