#pragma once

#include "godot_pcg_compat.hpp"
#include "native_feature_delta.hpp"

#include <array>
#include <cstdint>
#include <stdexcept>
#include <string>
#include <vector>

namespace voxel::world_backend {

enum class NativeOreKind : std::uint8_t { iron = 1, copper = 2 };
struct NativeOreClusterChildStream final {
    std::string durable_id;
    bool skipped_by_tombstone = false;
    std::uint64_t state_before = 0U;
    std::uint64_t state_after = 0U;
    std::vector<float> float_draws;
    std::int64_t drop_count = 0;
};
class NativeOreClusterStreamRejected final : public std::invalid_argument {
public: NativeOreClusterStreamRejected();
};

// Shared make_ore_cluster child stream. Surface clusters call this twice with
// child_count=2; underground floor props call it once with child_count=1.
// Keeping one decoder preserves the exact tombstone gate and draw order while
// allowing both source families to retain their production cluster size.
NativeOreClusterChildStream native_ore_cluster_child_stream(
    const std::string &parent_id, NativeOreKind kind,
    std::uint32_t child_index, std::uint32_t child_count,
    const NativeFeatureDeltaSnapshot &removed_props, GodotPcg32 &rng);
// Two-child recipe witness for make_ore_cluster(..., count = 2). The original
// overload remains the intact-only shadow diagnostic. The typed-delta
// overload preserves the live child tombstone gate before recipe draws, but
// does not by itself own the surrounding source-ordered attempt loop.
class NativeOreClusterStream final {
public:
    static NativeOreClusterStream create(const std::string &parent_id, NativeOreKind kind, GodotPcg32 &rng);
    // Production-order variant: each child is checked against the durable
    // removed-prop set before any of that child's shared-PCG draws.
    static NativeOreClusterStream create(const std::string &parent_id, NativeOreKind kind,
        const NativeFeatureDeltaSnapshot &removed_props, GodotPcg32 &rng);
    const std::array<NativeOreClusterChildStream, 2> &children() const noexcept;
    std::uint64_t final_rng_state() const noexcept;
private:
    NativeOreClusterStream(std::array<NativeOreClusterChildStream, 2> children, std::uint64_t final_state) noexcept;
    std::array<NativeOreClusterChildStream, 2> children_{};
    std::uint64_t final_state_ = 0U;
};
} // namespace voxel::world_backend
