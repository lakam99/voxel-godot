#ifndef NATIVE_TREE_GEOMETRY_DISPATCHER_H
#define NATIVE_TREE_GEOMETRY_DISPATCHER_H

#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/packed_float32_array.hpp>
#include <godot_cpp/variant/string.hpp>

#include <atomic>
#include <array>
#include <cstddef>
#include <condition_variable>
#include <cstdint>
#include <memory>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

using namespace godot;

// Bounded, cancellable value preparation for immutable tree records.
// Godot containers are copied on the caller thread; workers retain POD only.
// Recipe generation, resource creation and section ownership remain outside.
class NativeTreeGeometryDispatcher : public RefCounted {
	GDCLASS(NativeTreeGeometryDispatcher, RefCounted);

	static constexpr std::size_t MAX_JOBS = 128U;
	static constexpr std::size_t MAX_ANCHORS_PER_JOB = 4096U;
	static constexpr std::size_t MAX_RETAINED_OUTPUT_FLOATS = 4U * 1024U * 1024U;
	static constexpr std::size_t MAX_TREE_PACK_SUPPORT_KEYS_PER_INSTANCE = 4096U;
	static constexpr std::size_t MAX_TREE_PACK_SUPPORT_KEYS_PER_JOB = 262144U;
	static constexpr std::size_t FLOATS_PER_INSTANCE = 20U;

	struct Anchor {
		double position[3] = {};
		double rotation[3] = {};
		double scale[3] = {};
		double wind_weight = 0.0;
		double variation = 0.0;
		std::int32_t cluster_variant = 0;
		std::int32_t source_segment = -1;
		std::int32_t source_order = 0;
	};

	struct Branch {
		double start[3] = {};
		double end[3] = {};
		double radius_start = 0.0;
		double radius_end = 0.0;
		double wind_weight = 0.0;
	};

	struct Identity {
		std::string world_id;
		std::string world_epoch;
		std::string source_id;
		std::string source_revision;
		std::string recipe_signature;
		std::int64_t artifact_generation = 0;
		std::string source_record_digest;
		std::string source_provenance_digest;
		std::string request_digest;
	};

	struct Job {
		std::int64_t ticket = 0;
		Identity identity;
		std::string prop_id;
		std::string biome;
		std::vector<Anchor> anchors;
		std::vector<Branch> branches;
		std::vector<float> instance_values;
		std::vector<float> branch_instance_values;
		bool section_pack = false;
		std::string pack_role;
		std::string pack_source_part_id;
		std::string pack_batch_key;
		std::string pack_wind_digest;
		std::string pack_support_policy_revision;
		std::string pack_mesh_digest;
		std::string pack_recipe_signature;
		std::int64_t pack_artifact_generation = 0;
		double pack_mesh_bounds_position[3] = {};
		double pack_mesh_bounds_size[3] = {};
		double pack_body_basis[9] = {};
		double pack_body_origin[3] = {};
		double pack_certified_bounds_position[3] = {};
		double pack_certified_bounds_size[3] = {};
		double pack_section_size = 0.0;
		double pack_wind_horizontal = 0.0;
		double pack_wind_vertical = 0.0;
		std::vector<float> pack_input_values;
		std::int64_t pack_instance_count = 0;
		std::int32_t pack_input_stride = FLOATS_PER_INSTANCE;
		bool pack_use_colors = true;
		bool pack_use_custom_data = true;
		struct PackMember {
			std::int32_t instance_index = 0;
			std::int32_t attribute_offset = 0;
			std::int32_t owned_section[3] = {};
			double world_bounds_position[3] = {};
			double world_bounds_size[3] = {};
			std::vector<std::array<std::int32_t, 3>> support_sections;
		};
		struct PackSection {
			std::int32_t section_key[3] = {};
			std::vector<float> attributes;
			std::vector<PackMember> members;
		};
		std::vector<PackSection> pack_sections;
		std::size_t reserved_output_floats = 0U;
	std::atomic<bool> cancel_requested{false};
	bool release_requested = false;
		std::string state = "queued";
		std::string reason;
	};

	mutable std::mutex mutex_;
	std::condition_variable work_available_;
	std::vector<std::thread> workers_;
	std::vector<std::shared_ptr<Job>> jobs_;
	std::int64_t next_ticket_ = 1;
	std::size_t retained_output_floats_ = 0U;
	bool stopping_ = false;
	bool drained_ = false;

	static void _bind_methods();
	void _worker_loop();
	void _stop_and_join();
	static bool _read_identity(const Dictionary &p_identity, Identity &r_identity,
		std::string &r_reason);
	static bool _copy_recipe_snapshot(const Dictionary &p_recipe_snapshot,
		const String &p_biome, const String &p_prop_id, Job &r_job,
		std::string &r_reason);
	static bool _copy_tree_record_snapshot(const Dictionary &p_recipe_snapshot,
		const String &p_biome, const String &p_prop_id, Job &r_job,
		std::string &r_reason);
	static std::string _compile_foliage(const std::shared_ptr<Job> &p_job,
		std::vector<float> &r_values);
	static std::string _compile_branches(const std::shared_ptr<Job> &p_job,
		std::vector<float> &r_values);
	static std::string _compile_section_pack(const std::shared_ptr<Job> &p_job,
		std::vector<Job::PackSection> &r_sections, std::string &r_reason);
	std::shared_ptr<Job> _find_job_locked(std::int64_t p_ticket) const;
	static Dictionary _identity_dictionary(const Identity &p_identity);
	static Dictionary _job_status(const Job &p_job, bool p_include_values);
	void _reclaim_terminal_locked(const std::shared_ptr<Job> &p_job);

public:
	NativeTreeGeometryDispatcher();
	~NativeTreeGeometryDispatcher();

	Dictionary submit_foliage_compile(const Dictionary &p_recipe_snapshot,
		const String &p_biome, const String &p_prop_id,
		const Dictionary &p_identity);
	Dictionary submit_tree_record_compile(const Dictionary &p_recipe_snapshot,
		const String &p_biome, const String &p_prop_id,
		const Dictionary &p_identity);
	Dictionary submit_tree_section_pack(const Dictionary &p_packet,
		const Dictionary &p_identity);
	Dictionary poll_tree_geometry_compile(std::int64_t p_ticket) const;
	Dictionary take_tree_geometry_compile_result(std::int64_t p_ticket);
	Dictionary cancel_tree_geometry_compile(std::int64_t p_ticket);
	Dictionary release_tree_geometry_compile(std::int64_t p_ticket);
	Dictionary drain_tree_geometry_compiles();
	Dictionary tree_geometry_compile_metrics() const;
};

#endif
