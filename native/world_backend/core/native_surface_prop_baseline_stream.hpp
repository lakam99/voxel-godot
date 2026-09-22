#pragma once

#include "native_forage_stream.hpp"
#include "native_ore_cluster_stream.hpp"
#include "native_surface_prop_classifier.hpp"
#include "native_wildlife_stream.hpp"

#include <array>
#include <cstddef>
#include <cstdint>
#include <optional>
#include <stdexcept>
#include <string>
#include <vector>

namespace voxel::world_backend {

namespace tests {
struct NativeSurfacePropBaselineStreamTestAccess;
}

// One source-bound classification plus exactly the typed recipe input required
// by its result.  Supplying a recipe for another outcome is rejected rather
// than silently making an unused second authority.
struct NativeSurfacePropBaselineInput final {
    NativeSurfacePropClassificationInput classification;
    std::optional<NativeForageRecipe> forage_recipe;
    std::optional<NativeWildlifeStreamInput> wildlife;
};

struct NativeSurfacePropBaselineEntry final {
    // Preserve the source-bound identity that produced this replay result.
    // Later physical placement must bind to these facts instead of accepting a
    // second, merely ordinal-matched terrain/profile decision.
    std::uint32_t ordinal = 0U;
    std::int32_t cell_x = 0;
    std::int32_t cell_z = 0;
    std::string durable_id;
    Sha256Digest source_decision_digest{};
    NativeSurfacePropAdmission admission = NativeSurfacePropAdmission::surface_unavailable;
    NativeSurfacePropClassificationOutcome outcome = NativeSurfacePropClassificationOutcome::no_feature;
    std::uint64_t state_before_coordinates = 0U;
    std::uint64_t state_after_coordinates = 0U;
    std::uint64_t state_after_classification = 0U;
    std::uint64_t state_after_recipe = 0U;
    std::optional<float> prop_roll;
    std::optional<float> ore_roll;
    std::vector<float> compatibility_draws;
    std::optional<NativeOreClusterStream> ore_cluster;
    std::optional<NativeForageStream> forage;
    std::optional<NativeWildlifeStream> wildlife;
};

class NativeSurfacePropBaselineStreamRejected final : public std::invalid_argument {
public:
    NativeSurfacePropBaselineStreamRejected();
};

// Full unfiltered shared-PCG baseline for every currently typed surface-prop
// family.  This is deliberately a stream witness, not geometry publication;
// a later manifest owns definitions, footprints, and tombstone filtering.
class NativeSurfacePropBaselineStream final {
public:
    static NativeSurfacePropBaselineStream create(
        const NativeSurfacePropAttemptStream &attempts,
        const std::array<NativeSurfacePropBaselineInput, NativeSurfacePropAttemptStream::ATTEMPT_COUNT> &inputs);

    const std::array<NativeSurfacePropBaselineEntry, NativeSurfacePropAttemptStream::ATTEMPT_COUNT> &
    entries() const noexcept;
    std::uint64_t final_rng_state() const noexcept;

private:
    struct ComposedBaseline final {
        std::array<NativeSurfacePropBaselineEntry, NativeSurfacePropAttemptStream::ATTEMPT_COUNT> entries;
        std::uint64_t final_rng_state = 0U;
    };

    friend struct tests::NativeSurfacePropBaselineStreamTestAccess;

    NativeSurfacePropBaselineStream(
        std::array<NativeSurfacePropBaselineEntry, NativeSurfacePropAttemptStream::ATTEMPT_COUNT> entries,
        std::uint64_t final_rng_state) noexcept;

    // Classifier output is internal and exhaustive, but retain a fail-closed
    // guard for corrupt enum values. The friend supplies focused invariant
    // coverage without making an unsupported outcome a production input.
    static std::size_t compatibility_draw_count(NativeSurfacePropClassificationOutcome outcome);
    static ComposedBaseline compose(
        const NativeSurfacePropAttemptStream &attempts,
        const std::array<NativeSurfacePropBaselineInput, NativeSurfacePropAttemptStream::ATTEMPT_COUNT> &inputs,
        GodotPcg32 &rng);

    std::array<NativeSurfacePropBaselineEntry, NativeSurfacePropAttemptStream::ATTEMPT_COUNT> entries_{};
    std::uint64_t final_rng_state_ = 0U;
};

} // namespace voxel::world_backend
