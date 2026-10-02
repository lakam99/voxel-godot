#ifndef NATIVE_WORLD_BACKEND_ADAPTER_H
#define NATIVE_WORLD_BACKEND_ADAPTER_H

#include "native_effective_terrain_batch.hpp"
#include "native_biome_environment_catalog.hpp"
#include "native_feature_delta.hpp"
#include "native_structure_exclusion_snapshot.hpp"
#include "native_surface_prop_ordered_placement.hpp"
#include "native_surface_prop_source_ordered_stream.hpp"
#include "native_surface_rock_asset_catalog.hpp"
#include "native_surface_rock_footprint.hpp"
#include "native_underground_prop_stream.hpp"
#include "native_wildlife_presentation_receipt.hpp"
#include "native_terrain_shaping_registry.hpp"
#include "native_world_backend_state.hpp"
#include "native_captured_voxel_encode_job.hpp"
#include "native_terrain_volume_v2_import_builder.hpp"
#include "native_voxel_block_demand.hpp"

#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/classes/ref.hpp>
#include <godot_cpp/classes/thread.hpp>
#include <godot_cpp/variant/array.hpp>
#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/string.hpp>
#include <godot_cpp/variant/vector2i.hpp>

#include <cstdint>
#include <array>
#include <atomic>
#include <exception>
#include <memory>
#include <map>
#include <optional>
#include <string>
#include <thread>
#include <vector>

class NativeEffectiveTerrainPage : public godot::RefCounted {
	GDCLASS(NativeEffectiveTerrainPage, godot::RefCounted);

protected:
	static void _bind_methods();

public:
	godot::Dictionary status() const;
	godot::Dictionary sample_batch(const godot::Dictionary &p_request) const;
	godot::Dictionary project_surfaces(const godot::Dictionary &p_request) const;
	godot::Dictionary sample_continuous_surface(const godot::Vector2i &p_column) const;
	godot::Dictionary encode_voxel_block(const godot::Dictionary &p_request) const;

private:
	friend class NativeWorldBackend;
	void admit(std::unique_ptr<voxel::world_backend::NativeEffectiveTerrainBatch> p_batch);

	std::unique_ptr<voxel::world_backend::NativeEffectiveTerrainBatch> batch_;
};

struct NativeRockOrderedCache {
	const voxel::world_backend::NativeEffectiveTerrainBatch *batch;
	const voxel::world_backend::NativeBiomeEnvironmentCatalog *biome;
	const voxel::world_backend::NativeFeatureDeltaSnapshot *removed;
	const voxel::world_backend::NativeWildlifePresentationCatalog *wildlife;
	const voxel::world_backend::NativeSurfaceRockAssetCatalog *visual;
	std::string biome_identity, removed_identity, visual_identity, wildlife_identity;
	voxel::world_backend::WorldSourcePin pin;
	voxel::world_backend::NativeSurfacePropSourceOrderedStream ordered;
	voxel::world_backend::NativeSurfacePropOrderedPlacement placement;
};

struct NativeTerrainVolumeV2FinalizeJob;

class NativeStructureExclusionChunk : public godot::RefCounted {
	GDCLASS(NativeStructureExclusionChunk, godot::RefCounted);

protected:
	static void _bind_methods();

public:
	godot::Dictionary status() const;
	godot::Dictionary query(const godot::Vector2i &p_cell) const;

private:
	friend class NativeWorldBackend;
	void admit(std::unique_ptr<voxel::world_backend::NativeStructureExclusionSnapshot> p_snapshot,
		godot::Vector2i p_chunk, std::int64_t p_owner_id, std::int64_t p_revision,
		std::int64_t p_admission_generation, std::string p_capture_identity);

	std::unique_ptr<voxel::world_backend::NativeStructureExclusionSnapshot> snapshot_;
	godot::Vector2i chunk_;
	std::int64_t owner_id_ = 0;
	std::int64_t revision_ = 0;
	std::int64_t admission_generation_ = 0;
	std::string capture_identity_;
	std::unique_ptr<NativeRockOrderedCache> rock_ordered_cache_;
};

class NativeWorldBackend : public godot::RefCounted {
	GDCLASS(NativeWorldBackend, godot::RefCounted);

protected:
	static void _bind_methods();

public:
	~NativeWorldBackend() override;
	godot::Dictionary start_private_staged_save_retirement(std::int64_t p_generation);
	godot::Dictionary poll_private_staged_save_retirement();
	godot::Dictionary initialize(const godot::Dictionary &p_request);
	godot::Dictionary initialize_from_save_v2(const godot::Dictionary &p_request);
	godot::Dictionary export_terrain_volume_v2() const;
	godot::Dictionary admit_removed_props_tombstones(const godot::Dictionary &p_capture);
	godot::Dictionary admit_biome_environment_catalog(const godot::Dictionary &p_capture);
	godot::Dictionary admit_visual_asset_catalog(const godot::Dictionary &p_bundle);
	godot::Dictionary select_rock_asset_shadow(const godot::String &p_biome,
		const godot::String &p_durable_prop_id) const;
	godot::Dictionary project_published_rock_footprint_shadow(
		const godot::Ref<NativeEffectiveTerrainPage> &p_page,
		const godot::Ref<NativeStructureExclusionChunk> &p_exclusions,
		std::int64_t p_ordinal, const godot::String &p_visual_source,
		const godot::String &p_visual_asset_id) const;
	godot::Dictionary begin_rock_ordered_source_async(
		const godot::Ref<NativeEffectiveTerrainPage> &p_page,
		const godot::Ref<NativeStructureExclusionChunk> &p_exclusions);
	godot::Dictionary cancel_rock_ordered_source_async(std::int64_t p_ticket);
	godot::Dictionary poll_rock_ordered_source_async(std::int64_t p_ticket);
	godot::Dictionary admit_wildlife_presentation_catalog(const godot::Dictionary &p_bundle);
	godot::Dictionary admit_structure_exclusion_chunk(const godot::Dictionary &p_capture) const;
	godot::Dictionary compose_surface_prop_ordered_shadow(
		const godot::Ref<NativeEffectiveTerrainPage> &p_page,
		const godot::Ref<NativeStructureExclusionChunk> &p_exclusions) const;
	// Diagnostic pure-value shadow. It neither samples terrain nor publishes details.
	godot::Dictionary compose_detail_ordered_plan_shadow(const godot::Dictionary &p_capture) const;
	godot::Dictionary compose_underground_prop_ordered_shadow(
		const godot::Ref<NativeEffectiveTerrainPage> &p_page,
		const godot::Vector2i &p_chunk) const;
	godot::Dictionary compose_surface_tree_presence_shadow(
		const godot::Ref<NativeEffectiveTerrainPage> &p_page,
		const godot::Ref<NativeStructureExclusionChunk> &p_exclusions,
		const godot::Dictionary &p_union_capture) const;
	godot::Dictionary wildlife_presentation_shadow(const godot::String &p_variant) const;
	godot::Dictionary status() const;
	godot::Dictionary shaping_requests(const godot::Vector2i &p_primary_page) const;
	godot::Dictionary apply_shaping_resolutions(const godot::Array &p_resolutions);
	godot::Dictionary commit_typed_cells(const godot::Dictionary &p_request);
	godot::Dictionary commit_durable_cells(const godot::Dictionary &p_request);
	godot::Dictionary begin_staged_durable_cells(const godot::Dictionary &p_request);
	godot::Dictionary append_staged_durable_cells(const godot::Array &p_operations);
	godot::Dictionary commit_staged_durable_cells();
	godot::Dictionary abort_staged_durable_cells();
	godot::Dictionary pin_effective_page(const godot::Vector2i &p_primary_page) const;
	// Experimental current-state source identity lease. A ready identity does
	// not itself own cell samples, shape buffers, or physical collision proof.
	// The caller must retain this backend Ref until exact-issue cancel/drain;
	// the numeric issue alone is never a backend-lifetime capability.
	godot::Dictionary begin_borrowed_source_lease(const godot::Vector2i &p_primary_page);
	godot::Dictionary advance_borrowed_source_lease(std::int64_t p_issue, std::int64_t p_offered_ops);
	godot::Dictionary cancel_borrowed_source_lease(std::int64_t p_issue);
	godot::Dictionary drain_borrowed_source_lease(std::int64_t p_issue);
	// A2a: one live typed-edit scalar header within a ready A1 primary page.
	// Metadata, block identity text, and edit reason text are deliberately omitted.
	godot::Dictionary begin_borrowed_typed_cell(std::int64_t p_lease_issue, const godot::Vector3i &p_cell);
	godot::Dictionary advance_borrowed_typed_cell(std::int64_t p_cell_issue, std::int64_t p_offered_ops);
	godot::Dictionary cancel_borrowed_typed_cell(std::int64_t p_cell_issue);
	godot::Dictionary drain_borrowed_typed_cell(std::int64_t p_cell_issue);
	// Serialized, shadow-service-only composite admission. Not a Voxel Tools
	// worker callback or a production publication authority.
	godot::Dictionary encode_voxel_block_shadow(const godot::Dictionary &p_request) const;
	godot::Dictionary begin_voxel_block_shadow_async(const godot::Dictionary &p_request);
	godot::Dictionary poll_voxel_block_shadow_async(std::int64_t p_ticket);
	 godot::Dictionary cancel_voxel_block_shadow_async(std::int64_t p_ticket);
	// Staging-only incremental save import. Appends/cleanup have record/item
	// count caps per call, not CPU-time bounds; finalization is not exposed.
	godot::Dictionary begin_terrain_volume_v2_import(const godot::Dictionary &p_identity);
	godot::Dictionary append_terrain_volume_v2_import(const godot::Array &p_chunks, std::int64_t p_generation);
	godot::Dictionary cancel_terrain_volume_v2_import(std::int64_t p_generation);
	godot::Dictionary drain_terrain_volume_v2_import(std::int64_t p_generation);
	godot::Dictionary terrain_volume_v2_import_status(std::int64_t p_generation) const;
	// Staged save-v2 initialization: metadata is parsed on the calling thread,
	// durable volume records are appended under the existing bounded contract,
	// and whole-volume finalization/build happens on a pure-C++ worker.
	// All adapter lifecycle calls are main-thread-only; only the private worker
	// touches the detached C++ job while finalizing/discarding candidates.
	// Only explicit commit consumes the backend's one-shot initialization right;
	// cancelled/rejected uncommitted generations may retry after acknowledged drain.
	godot::Dictionary begin_staged_save_v2_initialization(
		const godot::Dictionary &p_source_request, const godot::Dictionary &p_import_identity);
	godot::Dictionary start_staged_save_v2_finalization(std::int64_t p_generation);
	godot::Dictionary staged_save_v2_initialization_status(std::int64_t p_generation) const;
	godot::Dictionary cancel_staged_save_v2_initialization(std::int64_t p_generation);
	godot::Dictionary drain_staged_save_v2_initialization(std::int64_t p_generation);
	godot::Dictionary commit_staged_save_v2_initialization(
		std::int64_t p_generation, const godot::Dictionary &p_expected_source_identity);
	 godot::Dictionary request_voxel_block_shadow(const godot::Dictionary &p_request, std::int64_t p_consumer_id, int p_priority);
	 godot::Dictionary configure_voxel_block_shadow_capacity(std::int64_t p_max_entries);
	 godot::Dictionary release_voxel_block_shadow(const godot::Dictionary &p_request, std::int64_t p_consumer_id);
	 godot::Dictionary pump_voxel_block_shadow();
	 godot::Dictionary voxel_block_shadow_insertion_receipt(const godot::Dictionary &p_key, std::int64_t p_generation, bool p_accepted);
	 godot::Dictionary voxel_block_shadow_mesh_receipt(const godot::Dictionary &p_key, std::int64_t p_generation,
		bool p_mesh_ready, bool p_physics_ready, bool p_physics_required = true);
	 godot::Dictionary voxel_block_shadow_unloaded(const godot::Dictionary &p_key);
	 godot::Dictionary voxel_block_shadow_mesh_exited(const godot::Dictionary &p_key);

private:
	struct PrivateStagedSaveRetirementJob;
	std::vector<voxel::world_backend::NativeTownRegionOverride> town_overrides_for_page(
		voxel::world_backend::NativeTerrainPageKey p_page) const;
	std::string canonical_worker_source_key(
		voxel::world_backend::NativeSiteSourceRegionKey p_region) const;
	voxel::world_backend::NativeVoxelBlockDemand::Key voxel_demand_key(const godot::Dictionary &p_request) const;
	godot::Dictionary voxel_demand_key_dictionary(const voxel::world_backend::NativeVoxelBlockDemand::Key &p_key) const;
	godot::Dictionary voxel_demand_event(const voxel::world_backend::NativeVoxelBlockDemand::Key &p_key) const;
	voxel::world_backend::WorldPhysicalContentIdentity voxel_demand_source_pin(
		const voxel::world_backend::NativeVoxelBlockDemand::Key &p_key,
		const voxel::world_backend::WorldDeltaPinnedSnapshot &p_deltas,
		const std::vector<voxel::world_backend::NativeTerrainShapingPagePin> &p_pages) const;
	void invalidate_changed_voxel_demand(const godot::Array &p_affected_sections);

	bool initialization_attempted_ = false;
	std::string initialization_failure_;
	voxel::world_backend::WorldSourceMutationFence source_mutation_fence_;
	std::uint64_t source_lease_incarnation_ = 0;
	struct BorrowedSourceLeaseSlot {
		enum class Phase : std::uint8_t {
			empty, axes, count_pages, rewind_pages, pin_header, next_page,
			town_scan, shaping_ready, shaping_digest, projection_reset, typed_projection,
			page_emit, pin_finish,
			cancelled, stale, failed, ready
		};
		Phase phase = Phase::empty;
		std::uint64_t issue = 0;
		std::uint64_t incarnation = 0;
		std::uint64_t epoch = 0;
		std::uint64_t delta_revision = 0;
		std::uint64_t registry_revision = 0;
		voxel::world_backend::Sha256Digest source_identity{};
		voxel::world_backend::Sha256Digest delta_content{};
		voxel::world_backend::Sha256Digest registry_content{};
		voxel::world_backend::Sha256Digest policy_content{};
		voxel::world_backend::NativeTerrainPageKey primary{};
		voxel::world_backend::NativeTerrainPageKey current_page{};
		voxel::world_backend::NativeHorizontalRect primary_bounds{};
		voxel::world_backend::NativeHorizontalRect current_bounds{};
		voxel::world_backend::WorldShapingDependencyCursor dependencies;
		voxel::world_backend::BorrowedShapingPageCursor page;
		voxel::world_backend::BorrowedShapingIdentityCursor shaping;
		voxel::world_backend::BorrowedTypedProjectionCursor projection;
		voxel::world_backend::Sha256State pin_hash;
		std::array<voxel::world_backend::NativeTownRegionOverride, 9> towns{};
		std::size_t town_count = 0;
		std::size_t town_scan_index = 0;
		std::uint64_t page_count = 0;
		std::size_t pin_byte_offset = 0;
		voxel::world_backend::Sha256Digest current_shaping_digest{};
		voxel::world_backend::Sha256Digest current_projection_digest{};
		voxel::world_backend::Sha256Digest pin_digest{};
	};
	static_assert(sizeof(BorrowedSourceLeaseSlot) <= 64U * 1024U,
		"borrowed source identity slot exceeds its fixed 64 KiB owner capacity");
	BorrowedSourceLeaseSlot borrowed_source_lease_;
	struct BorrowedTypedCellSlot {
		enum class Phase : std::uint8_t { empty, pending, ready, cancelled, stale, failed };
		Phase phase = Phase::empty;
		std::uint64_t issue = 0;
		std::uint64_t lease_issue = 0;
		voxel::world_backend::CellCoord cell{};
		voxel::world_backend::BorrowedTypedCellCursor cursor;
	};
	static_assert(sizeof(BorrowedTypedCellSlot) <= 1024U,
		"borrowed typed-cell slot exceeds its fixed 1 KiB capacity");
	static_assert(sizeof(BorrowedSourceLeaseSlot) + sizeof(BorrowedTypedCellSlot) <= 64U * 1024U,
		"combined borrowed source and typed-cell slots exceed the 64 KiB owner capacity");
	BorrowedTypedCellSlot borrowed_typed_cell_;
	std::uint64_t source_lease_frame_ = 0;
	std::uint32_t source_lease_frame_ops_ = 0;
	bool borrowed_source_stamp_matches(const BorrowedSourceLeaseSlot &slot) const noexcept;
	std::uint32_t borrowed_source_frame_budget() noexcept;
	void borrowed_source_charge(std::uint32_t ops) noexcept;
	void borrowed_source_seal() noexcept;
	std::unique_ptr<voxel::world_backend::NativeWorldBackendState> state_;
	std::int64_t private_staged_save_generation_ = 0;
	std::shared_ptr<PrivateStagedSaveRetirementJob> private_retirement_job_;
	std::thread private_retirement_worker_;
	std::optional<voxel::world_backend::NativeWorldBackendTransaction> staged_durable_cells_;
	std::unique_ptr<voxel::world_backend::NativeTerrainVolumeV2ImportBuilder> terrain_volume_import_;
	std::string terrain_volume_import_failure_;
	std::uint64_t terrain_volume_import_generation_ = 0;
	std::shared_ptr<NativeTerrainVolumeV2FinalizeJob> terrain_volume_finalize_job_;
	std::thread terrain_volume_finalize_worker_;
	std::unique_ptr<voxel::world_backend::NativeTerrainShapingRegistry> shaping_registry_;
	std::unique_ptr<voxel::world_backend::NativeBiomeEnvironmentCatalog> biome_catalog_;
	std::unique_ptr<voxel::world_backend::NativeFeatureDeltaSnapshot> removed_props_;
	std::int64_t removed_capture_owner_id_ = 0;
	std::int64_t removed_capture_revision_ = 0;
	std::string removed_capture_identity_;
	std::string removed_fd1_identity_;
	std::int64_t biome_capture_owner_id_ = 0;
	std::int64_t biome_capture_revision_ = 0;
	std::string biome_capture_identity_;
	std::unique_ptr<voxel::world_backend::NativeSurfaceRockAssetCatalog> visual_catalog_;
	std::map<std::string, voxel::world_backend::NativeSurfaceRockImportedBoundsReceipt> rock_import_bounds_;
	std::int64_t visual_capture_owner_id_ = 0;
	std::int64_t visual_capture_revision_ = 0;
	std::string visual_capture_identity_;
	std::unique_ptr<voxel::world_backend::NativeWildlifePresentationCatalog> wildlife_presentations_;
	std::int64_t presentation_capture_owner_id_ = 0;
	std::int64_t presentation_capture_revision_ = 0;
	std::string presentation_capture_identity_;
	std::vector<voxel::world_backend::NativeTownRegionOverride> town_overrides_;
	// One full-height primary viewer can exceed 3,000 retained data keys.
	// This is an entry cap, not the independent one-worker/4 MiB byte caps.
	voxel::world_backend::NativeVoxelBlockDemand voxel_demand_{1, 4U * 1024U * 1024U, 16384, 16384};
	std::uint64_t voxel_demand_capacity_rejections_ = 0;
	std::size_t voxel_demand_peak_entries_ = 0;
	std::map<voxel::world_backend::NativeVoxelBlockDemand::Key, godot::Dictionary> voxel_demand_requests_;
	std::map<voxel::world_backend::NativeVoxelBlockDemand::Key,
		std::vector<voxel::world_backend::NativeTerrainPageKey>> voxel_demand_dependencies_;
	std::optional<voxel::world_backend::NativeVoxelBlockDemand::Ticket> voxel_demand_worker_;
	std::optional<voxel::world_backend::NativeVoxelBlockDemand::Key> voxel_demand_capture_;
	std::map<voxel::world_backend::NativeVoxelBlockDemand::Key, voxel::world_backend::NativeVoxelBlockDemand::Ticket> voxel_demand_tickets_;
	std::map<voxel::world_backend::NativeVoxelBlockDemand::Key, godot::Dictionary> voxel_demand_results_;
	std::uint64_t voxel_demand_epoch_ = 0;
	bool voxel_demand_prepared_returned_ = false;
	std::optional<voxel::world_backend::NativeVoxelBlockDemand::Key> voxel_demand_last_prepared_;
	std::thread voxel_worker_;
	std::shared_ptr<std::atomic<bool>> voxel_worker_cancel_token_;
	std::atomic<bool> voxel_worker_finished_{false};
	std::optional<voxel::world_backend::NativeEffectiveVoxelBlock> voxel_worker_result_;
	std::exception_ptr voxel_worker_error_;
	std::int64_t voxel_worker_ticket_ = 0;
	bool voxel_worker_cancelled_ = false;
	std::int64_t next_voxel_worker_ticket_ = 1;
	voxel::world_backend::WorldPhysicalContentIdentity voxel_worker_source_identity_;
	voxel::world_backend::WorldPhysicalContentIdentity voxel_worker_registry_identity_;
	voxel::world_backend::WorldPhysicalContentIdentity voxel_worker_town_policy_identity_;
	std::uint64_t voxel_worker_registry_revision_ = 0;
	std::uint64_t voxel_worker_delta_revision_ = 0;
	std::int64_t voxel_worker_primary_page_count_ = 0;
	std::int64_t voxel_worker_shaping_page_count_ = 0;
	std::int64_t voxel_worker_capture_usec_ = 0;
	std::int64_t voxel_worker_encode_usec_ = 0;
	std::thread rock_source_worker_;
	std::atomic<bool> rock_source_worker_finished_{false};
	std::shared_ptr<std::atomic<bool>> rock_source_worker_cancel_token_;
	std::unique_ptr<NativeRockOrderedCache> rock_source_worker_result_;
	std::exception_ptr rock_source_worker_error_;
	bool rock_source_worker_cancelled_ = false;
	bool rock_source_worker_cancel_requested_ = false;
	std::int64_t rock_source_worker_ticket_ = 0;
	std::int64_t next_rock_source_worker_ticket_ = 1;
	std::int64_t rock_source_worker_capture_usec_ = 0;
	std::int64_t rock_source_worker_compose_usec_ = 0;
	std::int64_t rock_source_worker_started_usec_ = 0;
	godot::Ref<NativeEffectiveTerrainPage> rock_source_worker_page_;
	godot::Ref<NativeStructureExclusionChunk> rock_source_worker_exclusions_;
	const voxel::world_backend::NativeStructureExclusionSnapshot *rock_source_worker_exclusion_snapshot_ = nullptr;
	const voxel::world_backend::NativeEffectiveTerrainBatch *rock_source_worker_batch_ = nullptr;
	const voxel::world_backend::NativeBiomeEnvironmentCatalog *rock_source_worker_biome_ = nullptr;
	const voxel::world_backend::NativeFeatureDeltaSnapshot *rock_source_worker_removed_ = nullptr;
	const voxel::world_backend::NativeWildlifePresentationCatalog *rock_source_worker_wildlife_ = nullptr;
	const voxel::world_backend::NativeSurfaceRockAssetCatalog *rock_source_worker_visual_ = nullptr;
	std::string rock_source_worker_biome_identity_;
	std::string rock_source_worker_removed_identity_;
	std::string rock_source_worker_visual_identity_;
	std::string rock_source_worker_wildlife_identity_;
};

#endif
