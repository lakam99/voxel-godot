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

// Legacy tree_visual_spec draw path. This is not a visual/tree-grammar family:
// alpine selects conifer architecture while consuming the 36-draw path.
enum class NativeSurfacePropTreeReplayMode : std::uint8_t {
    none = 0,
    // tree_visual_spec consumes rotation + fallback height, then six values
    // for its center clump (fixed zero spread) and seven per outer clump.
    legacy_36_draw = 1,
    legacy_22_draw = 2,
};

enum class NativeSurfacePropOrePolicy : std::uint8_t {
    none = 0,
    eligible = 1,
};

// The cutoffs are cumulative, exact Godot float64 source values. The live
// GDScript adds scalar profile probabilities at this precision, then promotes
// each float32 randf result exactly for the strict comparison. Narrowing a
// cutoff would lose a reachable equality boundary when it rounds downward.
// Cutoffs intentionally are not capped at one: live source priority makes
// totals greater than one a saturated final branch rather than an invalid
// profile.
struct NativeSurfacePropPlacementPolicy final {
    double rock_upper = 0.0;
    double tree_upper = 0.0;
    double forage_upper = 0.0;
    double wildlife_upper = 0.0;
    NativeSurfacePropTreeReplayMode tree_replay = NativeSurfacePropTreeReplayMode::none;
    NativeSurfacePropOrePolicy ore_policy = NativeSurfacePropOrePolicy::none;
    double iron_upper = 0.0;
    double copper_upper = 0.0;
};

// source_decision_digest is calculated by the Godot adapter from this exact
// per-attempt receipt, including IEEE-754 float64 cutoff bits, and is
// subsequently bound to the aggregate trace. It
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
    tree_36_draw = 4,
    tree_22_draw = 5,
    unported_iron_ore_cluster = 6,
    unported_copper_ore_cluster = 7,
    forage_recipe = 8,
    wildlife_recipe = 9,
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

// Pure source-receipt classifier. It compares only precomputed float64 source
// cutoffs with the caller's exact Godot PCG float32 values. A recipe result remains a
// hard aggregate boundary: a caller cannot claim a complete RNG trace until a
// manifest composer supplies its typed recipe-stream input.
class NativeSurfacePropClassifier final {
public:
    static NativeSurfacePropClassification classify(
        const NativeSurfacePropClassificationInput &input,
        const NativeSurfacePropAttempt &attempt,
        float prop_roll, bool has_ore_roll = false, float ore_roll = 0.0F);
};

} // namespace voxel::world_backend
