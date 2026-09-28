#pragma once

#include "native_surface_prop_ordered_placement.hpp"
#include "native_surface_tree_definition_composer.hpp"

namespace voxel::world_backend {

class NativeSurfaceTreeOrderedComposerRejected final : public std::invalid_argument {
public:
    NativeSurfaceTreeOrderedComposerRejected();
};

// Shadow source-ordered tree definition. Caller-supplied ecology profile is
// source-biome-matched and digest-bound here, but not yet admitted against the
// active Godot environment catalog generation. Adapter cutover must close that
// boundary. This does not publish Godot bodies, visual recipes, interaction
// metadata, or navigation footprints.
class NativeSurfaceTreeOrderedComposer final {
public:
    static constexpr std::uint32_t PRODUCER_REVISION = 1U;
    static NativeTreeDefinition create(
        const NativeSurfacePropSourceOrderedStream &ordered,
        const NativeSurfacePropOrderedPlacement &placements,
        std::uint32_t ordinal, const NativeEffectiveTerrainSource &terrain,
        const NativeSurfaceTreeEcologyProfile &profile);
};

// Local receipt guard exposed for mutation tests; the ordered producer itself
// is private and cannot be supplied with torn optionals by normal callers.
void validate_native_surface_tree_ordered_receipts(const NativeSurfacePropOrderedAttempt &attempt);

} // namespace voxel::world_backend
