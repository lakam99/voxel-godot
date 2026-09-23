#pragma once

#include "native_surface_forage_ordered_definition.hpp"
#include "native_surface_ore_cluster_definition.hpp"
#include "native_surface_rock_ordered_composer.hpp"
#include "native_surface_rock_ordered_visual_plan.hpp"
#include "native_surface_tree_presence.hpp"
#include "native_surface_wildlife_ordered_definition.hpp"

#include <array>
#include <optional>

namespace voxel::world_backend {

class NativeSurfaceFeatureManifestRejected final : public std::invalid_argument {
public:
    NativeSurfaceFeatureManifestRejected();
};

// Exact native environment-profile projection, shared with the adapter's
// ordered tree shadow until that bridge is cut over to this core helper.
NativeSurfaceTreeEcologyProfile native_surface_tree_profile_from_catalog(
    const NativeBiomeEnvironmentCatalog &catalog, const std::string &biome);

struct NativeSurfaceFeatureEntry final {
    NativeSurfacePropPlacementEntry placement;
    bool parent_tombstoned = false;
    std::uint64_t state_after_recipe = 0U;
    std::optional<NativeSurfaceRockOrderedVisualPlan> rock;
    std::optional<NativeSurfaceOreClusterDefinition> ore;
    std::optional<NativeSurfaceForageOrderedDefinition> forage;
    std::optional<NativeSurfaceWildlifeOrderedDefinition> wildlife;
    std::optional<NativeTreeDefinition> tree;
    std::optional<NativeSurfaceTreePresenceDecision> tree_presence;
};

// N4 pure-core composition witness for one ordinary 28-attempt chunk. This is
// neither a publication packet nor a WorldDeltaStore-ready footprint catalog.
class NativeSurfaceFeatureManifest final {
public:
    static constexpr std::uint32_t SCHEMA_REVISION = 1U;
    static NativeSurfaceFeatureManifest create(
        const NativeSurfacePropSourceOrderedStream &ordered,
        const NativeSurfacePropOrderedPlacement &placements,
        const NativeEffectiveTerrainSource &terrain,
        const NativeBiomeEnvironmentCatalog &catalog,
        const NativeSurfaceRockAssetCatalog &rock_assets,
        const NativeStructureExclusionSnapshot &exclusions,
        const NativeWildlifePresentationCatalog &wildlife_presentations,
        const NativeTreeExclusionHaloCapture *tree_halo);

    std::int32_t chunk_x() const noexcept;
    std::int32_t chunk_z() const noexcept;
    std::uint64_t final_rng_state() const noexcept;
    const Sha256Digest &world_digest() const noexcept;
    std::uint64_t world_generation() const noexcept;
    const Sha256Digest &placement_digest() const noexcept;
    const Sha256Digest &exclusion_digest() const noexcept;
    const std::array<NativeSurfaceFeatureEntry,
        NativeSurfacePropAttemptStream::ATTEMPT_COUNT> &entries() const noexcept;
    const std::vector<std::uint8_t> &canonical_binary() const noexcept;
    const Sha256Digest &content_digest() const noexcept;

private:
    std::int32_t chunk_x_ = 0, chunk_z_ = 0;
    std::uint64_t final_rng_state_ = 0U, world_generation_ = 0U;
    Sha256Digest world_digest_{}, placement_digest_{}, exclusion_digest_{}, content_digest_{};
    std::array<NativeSurfaceFeatureEntry, NativeSurfacePropAttemptStream::ATTEMPT_COUNT> entries_{};
    std::vector<std::uint8_t> canonical_binary_;
};

} // namespace voxel::world_backend
