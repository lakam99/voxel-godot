#ifndef NATIVE_WORLD_BACKEND_ADAPTER_H
#define NATIVE_WORLD_BACKEND_ADAPTER_H

#include "native_effective_terrain_batch.hpp"
#include "native_biome_environment_catalog.hpp"
#include "native_feature_delta.hpp"
#include "native_structure_exclusion_snapshot.hpp"
#include "native_surface_prop_ordered_placement.hpp"
#include "native_surface_rock_asset_catalog.hpp"
#include "native_wildlife_presentation_receipt.hpp"
#include "native_terrain_shaping_registry.hpp"
#include "native_world_backend_state.hpp"

#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/classes/ref.hpp>
#include <godot_cpp/variant/array.hpp>
#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/string.hpp>
#include <godot_cpp/variant/vector2i.hpp>

#include <cstdint>
#include <memory>
#include <string>
#include <vector>

class NativeEffectiveTerrainPage : public godot::RefCounted {
	GDCLASS(NativeEffectiveTerrainPage, godot::RefCounted);

protected:
	static void _bind_methods();

public:
	godot::Dictionary status() const;
	godot::Dictionary sample_batch(const godot::Dictionary &p_request) const;
	godot::Dictionary encode_voxel_block(const godot::Dictionary &p_request) const;

private:
	friend class NativeWorldBackend;
	void admit(std::unique_ptr<voxel::world_backend::NativeEffectiveTerrainBatch> p_batch);

	std::unique_ptr<voxel::world_backend::NativeEffectiveTerrainBatch> batch_;
};

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
};

class NativeWorldBackend : public godot::RefCounted {
	GDCLASS(NativeWorldBackend, godot::RefCounted);

protected:
	static void _bind_methods();

public:
	godot::Dictionary initialize(const godot::Dictionary &p_request);
	godot::Dictionary initialize_from_save_v2(const godot::Dictionary &p_request);
	godot::Dictionary export_terrain_volume_v2() const;
	godot::Dictionary admit_removed_props_tombstones(const godot::Dictionary &p_capture);
	godot::Dictionary admit_biome_environment_catalog(const godot::Dictionary &p_capture);
	godot::Dictionary admit_visual_asset_catalog(const godot::Dictionary &p_bundle);
	godot::Dictionary select_rock_asset_shadow(const godot::String &p_biome,
		const godot::String &p_durable_prop_id) const;
	godot::Dictionary admit_wildlife_presentation_catalog(const godot::Dictionary &p_bundle);
	godot::Dictionary admit_structure_exclusion_chunk(const godot::Dictionary &p_capture) const;
	godot::Dictionary compose_surface_prop_ordered_shadow(
		const godot::Ref<NativeEffectiveTerrainPage> &p_page,
		const godot::Ref<NativeStructureExclusionChunk> &p_exclusions) const;
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
	godot::Dictionary pin_effective_page(const godot::Vector2i &p_primary_page) const;

private:
	std::vector<voxel::world_backend::NativeTownRegionOverride> town_overrides_for_page(
		voxel::world_backend::NativeTerrainPageKey p_page) const;
	std::string canonical_worker_source_key(
		voxel::world_backend::NativeSiteSourceRegionKey p_region) const;

	bool initialization_attempted_ = false;
	std::string initialization_failure_;
	std::unique_ptr<voxel::world_backend::NativeWorldBackendState> state_;
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
	std::int64_t visual_capture_owner_id_ = 0;
	std::int64_t visual_capture_revision_ = 0;
	std::string visual_capture_identity_;
	std::unique_ptr<voxel::world_backend::NativeWildlifePresentationCatalog> wildlife_presentations_;
	std::int64_t presentation_capture_owner_id_ = 0;
	std::int64_t presentation_capture_revision_ = 0;
	std::string presentation_capture_identity_;
	std::vector<voxel::world_backend::NativeTownRegionOverride> town_overrides_;
};

#endif
