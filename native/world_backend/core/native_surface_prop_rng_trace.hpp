#pragma once

#include "native_surface_prop_attempt_stream.hpp"

#include <array>
#include <cstdint>
#include <stdexcept>
#include <string>
#include <vector>

namespace voxel::world_backend {

// The Godot source decides these dispositions from authoritative terrain and
// environment-profile receipts. This pure value deliberately replays their
// shared-PCG consequences without duplicating a terrain/profile authority.
// It has no tombstone argument: removals must filter completed definitions at
// publication, never alter this baseline trace.
enum class NativeSurfacePropReplayDisposition : std::uint8_t {
    skipped_before_prop_roll = 1,
    no_feature = 2,
    ordinary_rock = 3,
    broadleaf_tree = 4,
    conifer_tree = 5,
};

struct NativeSurfacePropReplayReceipt final {
    std::uint32_t ordinal = 0U;
    std::string durable_id;
    NativeSurfacePropReplayDisposition disposition = NativeSurfacePropReplayDisposition::no_feature;
};

struct NativeSurfacePropRngTraceEntry final {
    std::uint32_t ordinal = 0U;
    std::uint64_t state_before_coordinates = 0U;
    std::uint64_t state_after_coordinates = 0U;
    std::uint64_t state_after_recipe = 0U;
    bool has_prop_roll = false;
    float prop_roll = 0.0F;
    // Exact legacy values consumed after class selection. Ordinary rocks use
    // six; conifer and broadleaf tree compatibility consumers use 22 and 36.
    // They remain a stream compatibility trace, not geometry authority.
    std::vector<float> recipe_draws;
};

class NativeSurfacePropRngTraceRejected final : public std::invalid_argument {
public:
    NativeSurfacePropRngTraceRejected();
};

class NativeSurfacePropRngTrace final {
public:
    static NativeSurfacePropRngTrace create(
        const NativeSurfacePropAttemptStream &attempt_stream,
        const std::vector<NativeSurfacePropReplayReceipt> &receipts);

    const std::array<NativeSurfacePropRngTraceEntry, NativeSurfacePropAttemptStream::ATTEMPT_COUNT> &
    entries() const noexcept;
    std::uint64_t final_rng_state() const noexcept;

private:
    NativeSurfacePropRngTrace(
        std::array<NativeSurfacePropRngTraceEntry, NativeSurfacePropAttemptStream::ATTEMPT_COUNT> entries,
        std::uint64_t final_rng_state) noexcept;

    std::array<NativeSurfacePropRngTraceEntry, NativeSurfacePropAttemptStream::ATTEMPT_COUNT> entries_{};
    std::uint64_t final_rng_state_ = 0U;
};

} // namespace voxel::world_backend
