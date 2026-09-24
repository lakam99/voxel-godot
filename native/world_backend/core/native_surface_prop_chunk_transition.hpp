#pragma once

#include "native_generated_feature_footprint_catalog.hpp"
#include "native_surface_feature_manifest.hpp"
#include "native_surface_forage_footprint.hpp"
#include "native_surface_ore_footprint.hpp"
#include "native_surface_prop_chunk_difference.hpp"
#include "native_surface_rock_footprint.hpp"

#include <array>
#include <cstddef>
#include <memory>
#include <optional>
#include <string>
#include <vector>

namespace voxel::world_backend {

class NativeSurfaceFeatureFootprintShadowRejected final : public std::invalid_argument {
public:
    NativeSurfaceFeatureFootprintShadowRejected();
};

enum class NativeSurfaceFeatureFootprintShadowStatus : std::uint8_t {
    exact_absent = 1,
    exact_all_channels = 2,
    incomplete_rock_publication_outcome = 3,
    incomplete_tree_geometry = 4,
    incomplete_wildlife_motion_policy = 5,
};

struct NativeSurfaceRockPublicationShadowBinding final {
    std::uint32_t ordinal = 0U;
    std::string feature_id;
    Sha256Digest rock_definition_digest{};
    NativeSurfaceRockPublishedVisual published_visual =
        NativeSurfaceRockPublishedVisual::primitive_fallback;
    std::optional<NativeSurfaceRockImportedBoundsReceipt> imported_bounds;
};

// Optional observed publication facts. They remain diagnostic inputs: an
// absent rock binding is reported as incomplete, never inferred from the
// deterministic asset-selection intent. Duplicate, stale, non-rock or
// mismatched bindings fail the whole projection.
struct NativeSurfaceFeatureFootprintShadowInputs final {
    std::vector<NativeSurfaceRockPublicationShadowBinding> rock_publications;
};

struct NativeSurfaceFeatureFootprintShadowRecord final {
    std::uint32_t ordinal = 0U;
    std::string durable_id;
    NativeSurfaceFeatureFootprintShadowStatus status =
        NativeSurfaceFeatureFootprintShadowStatus::exact_absent;
    Sha256Digest typed_definition_digest{};
    std::vector<std::string> exact_feature_ids;
    Sha256Digest content_digest{};
};

class NativeSurfacePropChunkTransition;

// Explicitly incomplete N4 diagnostic. It classifies every one of the shared
// 28 ordered attempts and carries a source-bound catalog containing only
// entries whose four channels are exact. The partial catalog cannot authorize
// a WorldDeltaStore edit, feature publication, script deletion or cutover.
class NativeSurfaceFeatureFootprintShadowProjection final {
public:
    static constexpr std::uint32_t SCHEMA_REVISION = 1U;
    static constexpr bool CHANNEL_FOOTPRINTS_COMPLETE = false;

    bool channel_footprints_complete() const noexcept { return false; }
    const WorldPhysicalContentIdentity &world_source_identity() const noexcept {
        return world_source_identity_;
    }
    std::uint64_t world_generation() const noexcept { return world_generation_; }
    const Sha256Digest &manifest_digest() const noexcept { return manifest_digest_; }
    const Sha256Digest &environment_catalog_digest() const noexcept {
        return environment_catalog_digest_;
    }
    const Sha256Digest &rock_asset_catalog_digest() const noexcept {
        return rock_asset_catalog_digest_;
    }
    const Sha256Digest &wildlife_presentation_catalog_digest() const noexcept {
        return wildlife_presentation_catalog_digest_;
    }
    const std::vector<NativeSurfaceFeatureFootprintShadowRecord> &records() const noexcept {
        return records_;
    }
    std::size_t incomplete_record_count() const noexcept { return incomplete_record_count_; }
    const NativeGeneratedFeatureFootprintCatalog &
    partial_exact_catalog_for_diagnostics_only() const noexcept {
        return *partial_exact_catalog_;
    }
    const Sha256Digest &content_digest() const noexcept { return content_digest_; }

private:
    friend class NativeSurfacePropChunkTransition;
    NativeSurfaceFeatureFootprintShadowProjection() = default;
    static NativeSurfaceFeatureFootprintShadowProjection create_for_transition_diagnostics_only(
        const NativeSurfaceFeatureManifest &manifest,
        const NativeSurfacePropSourceOrderedStream &ordered,
        const NativeSurfacePropOrderedPlacement &placements,
        const NativeEffectiveTerrainSource &terrain,
        const NativeBiomeEnvironmentCatalog &catalog,
        const NativeSurfaceRockAssetCatalog &rock_assets,
        const NativeWildlifePresentationCatalog &wildlife,
        const NativeSurfaceFeatureFootprintShadowInputs *inputs);

    WorldPhysicalContentIdentity world_source_identity_{};
    std::uint64_t world_generation_ = 0U;
    Sha256Digest manifest_digest_{}, environment_catalog_digest_{},
        rock_asset_catalog_digest_{}, wildlife_presentation_catalog_digest_{},
        content_digest_{};
    std::vector<NativeSurfaceFeatureFootprintShadowRecord> records_;
    std::size_t incomplete_record_count_ = 0U;
    std::optional<NativeGeneratedFeatureFootprintCatalog> partial_exact_catalog_;
};

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
        const NativeTreeExclusionHaloCapture *after_halo,
        const NativeSurfaceFeatureFootprintShadowInputs *before_footprint_inputs = nullptr,
        const NativeSurfaceFeatureFootprintShadowInputs *after_footprint_inputs = nullptr);

    static constexpr bool CHANNEL_FOOTPRINTS_COMPLETE = false;
    bool channel_footprints_complete() const noexcept { return false; }
    const NativeSurfacePropChunkDifference &ordered_difference() const noexcept { return difference_; }
    const NativeSurfaceFeatureManifest &before_manifest() const noexcept { return *before_manifest_; }
    const NativeSurfaceFeatureManifest &after_manifest() const noexcept { return *after_manifest_; }
    const NativeSurfaceFeatureFootprintShadowProjection &before_footprint_shadow() const noexcept {
        return *before_footprint_shadow_;
    }
    const NativeSurfaceFeatureFootprintShadowProjection &after_footprint_shadow() const noexcept {
        return *after_footprint_shadow_;
    }
    const std::vector<std::uint32_t> &changed_ordinals() const noexcept { return changed_ordinals_; }
    const std::vector<std::string> &changed_ids() const noexcept { return changed_ids_; }
    // Publication observations may change this diagnostic list while the
    // ordered/typed source changed_ordinals and changed_ids remain untouched.
    const std::vector<std::uint32_t> &footprint_shadow_changed_ordinals() const noexcept {
        return footprint_shadow_changed_ordinals_;
    }
    const Sha256Digest &content_digest() const noexcept { return content_digest_; }

private:
    NativeSurfacePropChunkTransition() = default;
    NativeSurfacePropChunkDifference difference_;
    std::unique_ptr<NativeSurfaceFeatureManifest> before_manifest_, after_manifest_;
    std::unique_ptr<NativeSurfaceFeatureFootprintShadowProjection> before_footprint_shadow_,
        after_footprint_shadow_;
    std::vector<std::uint32_t> changed_ordinals_;
    std::vector<std::uint32_t> footprint_shadow_changed_ordinals_;
    std::vector<std::string> changed_ids_;
    Sha256Digest content_digest_{};
};

} // namespace voxel::world_backend
