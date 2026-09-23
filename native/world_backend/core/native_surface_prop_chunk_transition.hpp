#pragma once

#include "native_surface_feature_manifest.hpp"
#include "native_surface_prop_chunk_difference.hpp"

namespace voxel::world_backend {

// Pure preparation witness. In particular, changed IDs are not section or
// channel footprints and this object cannot authorize a WorldDeltaStore edit.
class NativeSurfacePropChunkTransition final {
public:
    static NativeSurfacePropChunkTransition create(
        const NativeSurfacePropSourceOrderedStream &before,
        const NativeSurfacePropSourceOrderedStream &after,
        const NativeEffectiveTerrainSource &terrain,
        const NativeBiomeEnvironmentCatalog &catalog,
        const NativeSurfaceRockAssetCatalog &rock_assets,
        const NativeStructureExclusionSnapshot &exclusions,
        const NativeWildlifePresentationCatalog &wildlife,
        const NativeTreeExclusionHaloCapture *before_halo,
        const NativeTreeExclusionHaloCapture *after_halo);

    static constexpr bool CHANNEL_FOOTPRINTS_COMPLETE = false;
    bool channel_footprints_complete() const noexcept { return false; }
    const NativeSurfacePropChunkDifference &ordered_difference() const noexcept { return difference_; }
    const NativeSurfaceFeatureManifest &before_manifest() const noexcept { return before_manifest_; }
    const NativeSurfaceFeatureManifest &after_manifest() const noexcept { return after_manifest_; }
    const std::vector<std::uint32_t> &changed_ordinals() const noexcept { return changed_ordinals_; }
    const std::vector<std::string> &changed_ids() const noexcept { return changed_ids_; }
    const Sha256Digest &content_digest() const noexcept { return content_digest_; }

private:
    NativeSurfacePropChunkDifference difference_;
    NativeSurfaceFeatureManifest before_manifest_, after_manifest_;
    std::vector<std::uint32_t> changed_ordinals_;
    std::vector<std::string> changed_ids_;
    Sha256Digest content_digest_{};
};

} // namespace voxel::world_backend
