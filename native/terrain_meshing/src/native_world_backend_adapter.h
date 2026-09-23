#ifndef NATIVE_WORLD_BACKEND_ADAPTER_H
#define NATIVE_WORLD_BACKEND_ADAPTER_H

#include "native_effective_terrain_batch.hpp"
#include "native_biome_environment_catalog.hpp"
#include "native_terrain_shaping_registry.hpp"
#include "native_world_backend_state.hpp"

#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/variant/array.hpp>
#include <godot_cpp/variant/dictionary.hpp>
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

private:
	friend class NativeWorldBackend;
	void admit(std::unique_ptr<voxel::world_backend::NativeEffectiveTerrainBatch> p_batch);

	std::unique_ptr<voxel::world_backend::NativeEffectiveTerrainBatch> batch_;
};

class NativeWorldBackend : public godot::RefCounted {
	GDCLASS(NativeWorldBackend, godot::RefCounted);

protected:
	static void _bind_methods();

public:
	godot::Dictionary initialize(const godot::Dictionary &p_request);
	godot::Dictionary initialize_from_save_v2(const godot::Dictionary &p_request);
	godot::Dictionary export_terrain_volume_v2() const;
	godot::Dictionary admit_removed_props_tombstones(const godot::Dictionary &p_capture) const;
	godot::Dictionary admit_biome_environment_catalog(const godot::Dictionary &p_capture);
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
	std::int64_t biome_capture_owner_id_ = 0;
	std::int64_t biome_capture_revision_ = 0;
	std::string biome_capture_identity_;
	std::vector<voxel::world_backend::NativeTownRegionOverride> town_overrides_;
};

#endif
