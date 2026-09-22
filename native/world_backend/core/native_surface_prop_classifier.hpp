#pragma once

#include "native_surface_prop_attempt_stream.hpp"
#include "sha256.hpp"

#include <cstdint>
#include <stdexcept>

namespace voxel::world_backend {

// These values are source receipts, not an alternate terrain sampler or
// biome-environment catalog. Godot decides admission from its authoritative
// structure/surface projection and supplies the already-normalized policies.
enum class NativeSurfacePropAdmission : std::uint8_t {
    structure_blocked = 1,
    surface_unavailable = 2,
    surface_ineligible = 3,
    town = 4,
    eligible = 5,
};

enum class NativeSurfacePropTreeCompatibilityFamily : std::uint8_t {
    none = 0,
    broadleaf_36_draw = 1,
    conifer_22_draw = 2,
};

enum class NativeSurfacePropOrePolicy : std::uint8_t {
    none = 0,
    eligible = 1,
};

// The cutoffs are cumulative, exact float32 source values. They intentionally
// are not capped at one: live source priority makes totals greater than one a
// saturated final branch rather than an invalid profile.
struct NativeSurfacePropPlacementPolicy final {
    float rock_upper = 0.0F;
    float tree_upper = 0.0F;
    float forage_upper = 0.0F;
    float wildlife_upper = 0.0F;
    NativeSurfacePropTreeCompatibilityFamily tree_family = NativeSurfacePropTreeCompatibilityFamily::none;
    NativeSurfacePropOrePolicy ore_policy = NativeSurfacePropOrePolicy::none;
    float iron_upper = 0.0F;
    float copper_upper = 0.0F;
};

// source_decision_digest is calculated by the Godot adapter from this exact
// per-attempt receipt and is subsequently bound to the aggregate trace. It
// prevents a matching ordinal/ID from being replayed with stale terrain or
// profile facts. No tombstone belongs here: baseline selection precedes
// publication filtering.
struct NativeSurfacePropClassificationInput final {
    std::uint32_t ordinal = 0U;
    std::int32_t cell_x = 0;
    std::int32_t cell_z = 0;
    Sha256Digest source_decision_digest{};
    NativeSurfacePropAdmission admission = NativeSurfacePropAdmission::surface_unavailable;
    NativeSurfacePropPlacementPolicy policy{};
};

enum class NativeSurfacePropClassificationOutcome : std::uint8_t {
    skipped_before_prop_roll = 1,
    no_feature = 2,
    ordinary_rock = 3,
    broadleaf_tree = 4,
    conifer_tree = 5,
    unported_iron_ore_cluster = 6,
    unported_copper_ore_cluster = 7,
    unported_forage_recipe = 8,
    unported_wildlife_recipe = 9,
};

struct NativeSurfacePropClassification final {
    NativeSurfacePropClassificationOutcome outcome = NativeSurfacePropClassificationOutcome::skipped_before_prop_roll;
    bool consumes_prop_roll = false;
    bool consumes_ore_roll = false;
};

class NativeSurfacePropClassifierRejected final : public std::invalid_argument {
public:
    NativeSurfacePropClassifierRejected();
};

// Pure source-receipt classifier. It compares only precomputed source cutoffs
// with the caller's exact Godot PCG float32 values. An unported result is an
// intentional hard boundary: a caller cannot claim a complete RNG trace until
// that recipe family supplies its own stream contract.
class NativeSurfacePropClassifier final {
public:
    static NativeSurfacePropClassification classify(
        const NativeSurfacePropClassificationInput &input,
        const NativeSurfacePropAttempt &attempt,
        float prop_roll, bool has_ore_roll = false, float ore_roll = 0.0F);
};

} // namespace voxel::world_backend
