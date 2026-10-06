#ifndef NATIVE_SECTION_COMPILE_DISPATCHER_H
#define NATIVE_SECTION_COMPILE_DISPATCHER_H

#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/variant/aabb.hpp>
#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/string.hpp>
#include <godot_cpp/variant/vector3.hpp>
#include <godot_cpp/variant/vector3i.hpp>

#include <atomic>
#include <condition_variable>
#include <cstdint>
#include <memory>
#include <map>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

using namespace godot;

// Owns value-only section buffer compilation jobs. All Godot Variant parsing
// and result materialization happen on the calling thread; workers only touch
// the POD structures declared below.
class NativeSectionCompileDispatcher : public RefCounted {
	GDCLASS(NativeSectionCompileDispatcher, RefCounted);

	static constexpr std::int64_t MAX_JOBS = 32;
	static constexpr std::int64_t MAX_JOB_INPUT_BYTES = 64LL * 1024LL * 1024LL;
	static constexpr std::int64_t MAX_RETAINED_BUFFER_BYTES = 128LL * 1024LL * 1024LL;
	static constexpr std::int64_t STARVATION_MSEC = 3000;
	static constexpr std::int32_t MAX_INSTANCES_PER_SEGMENT = 256;
	static constexpr std::int32_t FLOATS_PER_INSTANCE = 20;

	struct Bounds {
		float position[3] = {};
		float size[3] = {};
	};

	struct SourceRange {
		std::string source_id;
		std::string source_part_id;
		std::string source_revision;
		std::string source_segment_id;
		std::int32_t batch_index = 0;
		std::int32_t first_instance = 0;
		std::int32_t instance_count = 0;
		std::int32_t source_first_instance = 0;
	};

	struct InputContribution {
		std::string source_id;
		std::string source_part_id;
		std::string source_revision;
		std::string segment_id;
		std::int32_t instance_count = 0;
		Bounds bounds;
		std::vector<float> buffer;
	};

	struct InputGroup {
		std::string batch_key;
		std::vector<InputContribution> contributions;
	};

	struct OutputSegment {
		std::string segment_id;
		std::int32_t batch_index = 0;
		std::int32_t instance_count = 0;
		Bounds bounds;
		std::vector<float> buffer;
		std::vector<SourceRange> source_ranges;
	};

	struct OutputGroup {
		std::string batch_key;
		std::vector<OutputSegment> segments;
	};

	struct JobIdentity {
		std::string world_id;
		std::string world_epoch;
		std::string provider_revision_digest;
		std::string source_index_revision;
		bool source_index_revision_is_integer = false;
		std::int64_t source_index_revision_integer = 0;
		std::string coverage_digest;
		std::string prepared_payload_digest;
	};

	struct Job {
		std::int64_t ticket = 0;
		std::int64_t generation = 0;
		std::int32_t section_key[3] = {};
		float section_size = 0.0F;
		float section_offset[3] = {};
		JobIdentity identity;
		std::vector<InputGroup> groups;
		std::vector<OutputGroup> output_groups;
		std::atomic<bool> cancel_requested{false};
		std::string state = "queued";
		std::string reason;
		bool release_requested = false;
		std::int64_t input_bytes = 0;
		std::int64_t reserved_bytes = 0;
		std::int64_t finished_bytes = 0;
		std::int64_t submitted_msec = 0;
	};

	mutable std::mutex mutex_;
	std::condition_variable work_available_;
	std::vector<std::thread> workers_;
	std::vector<std::shared_ptr<Job>> jobs_;
	std::map<std::string, std::int64_t> latest_generations_;
	std::int64_t next_ticket_ = 1;
	std::int64_t retained_buffer_bytes_ = 0;
	float camera_position_[3] = {};
	std::int64_t camera_revision_ = 0;
	bool stopping_ = false;
	bool drained_ = false;

	static void _bind_methods();
	void _worker_loop();
	void _stop_and_join();
	static std::string _compile_job(const std::shared_ptr<Job> &p_job,
		std::vector<OutputGroup> &r_output_groups, std::string &r_reason);
	static Dictionary _identity_dictionary(const Job &p_job);
	static bool _parse_identity(const Dictionary &p_identity, JobIdentity &r_identity,
		std::string &r_reason);
	static bool _copy_preparation(const Dictionary &p_preparation, Job &r_job,
		std::string &r_reason);
	static bool _preflight_preparation(const Dictionary &p_preparation,
		std::int64_t &r_input_bytes, std::int64_t &r_input_segments,
		std::int64_t &r_instance_count, std::int32_t r_section_key[3],
		float &r_section_size, float r_section_offset[3], std::string &r_reason);
	static bool _read_bounds(const Variant &p_value, Bounds &r_bounds);
	static bool _bounds_finite_and_positive(const Bounds &p_bounds);
	std::int64_t _latest_generation_locked(const Job &p_job) const;
	static std::string _slot_key(const std::string &p_world_id,
		const std::string &p_world_epoch, const std::int32_t p_section_key[3]);
	std::shared_ptr<Job> _find_job_locked(std::int64_t p_ticket) const;
	std::shared_ptr<Job> _choose_next_job_locked() const;
	void _reclaim_terminal_locked(const std::shared_ptr<Job> &p_job);
	Dictionary _job_status(const Job &p_job, bool p_include_result) const;
	static Variant _bounds_variant(const Bounds &p_bounds);
	static Dictionary _materialize_result(const Job &p_job);

public:
	NativeSectionCompileDispatcher();
	~NativeSectionCompileDispatcher();

	Dictionary submit_section_compile(const Dictionary &p_preparation,
		const Dictionary &p_identity);
	Dictionary set_compile_camera(const Vector3 &p_position,
		std::int64_t p_camera_revision);
	Dictionary cancel_section_compile(const String &p_world_id,
		const String &p_world_epoch, const Vector3i &p_section_key,
		std::int64_t p_generation);
	Dictionary poll_section_compile(std::int64_t p_ticket) const;
	Dictionary take_section_compile_result(std::int64_t p_ticket);
	Dictionary release_section_compile(std::int64_t p_ticket);
	Dictionary drain_section_compiles();
	Dictionary metrics() const;
};

#endif
