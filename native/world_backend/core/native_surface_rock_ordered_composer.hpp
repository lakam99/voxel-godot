#pragma once

#include "native_surface_rock_definition.hpp"
#include "native_surface_prop_ordered_placement.hpp"

namespace voxel::world_backend {

// Adapter-owned, immutable visual asset selection for one rock profile.
struct NativeSurfaceRockPresentationReceipt final {
    std::uint32_t schema_revision = 0U;
    Sha256Digest asset_catalog_digest{};
    Sha256Digest source_profile_digest{};
    std::string source_biome;
    std::string profile_id;
    std::string asset_id;
};

class NativeSurfaceRockOrderedComposerRejected final : public std::invalid_argument {
public:
    NativeSurfaceRockOrderedComposerRejected();
};

// Godot roundi of a Vector3 float32 world component divided by cell size.
std::int32_t native_surface_rock_visual_cell(float world_component, double cell_size_meters);

class NativeSurfaceRockOrderedComposer final {
public:
    // Shadow definition bridge. The adapter still owns admission of the
    // profile and asset receipt against its environment/visual catalog.
    static constexpr std::uint32_t PRODUCER_REVISION = 1U;
    static NativeSurfaceRockDefinition create(
        const NativeSurfacePropSourceOrderedStream &ordered,
        const NativeSurfacePropOrderedPlacement &placements,
        std::uint32_t ordinal, const NativeEffectiveTerrainSource &terrain,
        const NativeSurfaceRockProfile &profile,
        const NativeSurfaceRockPresentationReceipt &presentation);
};

} // namespace voxel::world_backend
