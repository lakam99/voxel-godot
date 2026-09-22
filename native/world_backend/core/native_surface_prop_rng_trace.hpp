#pragma once

#include "native_surface_prop_attempt_stream.hpp"
#include "sha256.hpp"
#include "world_source.hpp"

#include <array>
#include <cstdint>
#include <stdexcept>
#include <string>
#include <vector>

namespace voxel::world_backend {

// One admitted effective terrain pin and one environment catalog snapshot.
// Revisions are ownership epochs and may be zero for an initial snapshot;
// the digest names physical content. This trace does not sample either source.
struct NativeSurfacePropSourceReceipt final {
    static constexpr std::uint32_t SCHEMA_REVISION = 4U;
    std::uint32_t schema_revision = SCHEMA_REVISION;
    Sha256Digest effective_source_digest{};
    std::uint64_t terrain_delta_revision = 0U;
    std::uint64_t shaping_registry_revision = 0U;
    std::uint32_t environment_profile_revision = 0U;
    Sha256Digest environment_profile_digest{};

    static NativeSurfacePropSourceReceipt from_pin(
        const WorldSourcePin &pin, std::uint32_t environment_profile_revision,
        Sha256Digest environment_profile_digest);
    bool matches_pin(const WorldSourcePin &pin) const noexcept;
};

// The Godot source decides these dispositions from authoritative terrain and
// environment-profile receipts. This pure value deliberately replays their
// shared-PCG consequences without duplicating a terrain/profile authority.
// It has no tombstone argument: removals must filter completed definitions at
// publication, never alter this baseline trace.
enum class NativeSurfacePropReplayDisposition : std::uint8_t {
    skipped_before_prop_roll = 1,
    no_feature = 2,
    ordinary_rock = 3,
    tree_36_draw = 4,
    tree_22_draw = 5,
};

struct NativeSurfacePropReplayReceipt final {
    std::uint32_t ordinal = 0U;
    std::string durable_id;
    NativeSurfacePropReplayDisposition disposition = NativeSurfacePropReplayDisposition::no_feature;
};

struct NativeSurfacePropRngTraceEntry final {
    std::uint32_t ordinal = 0U;
    NativeSurfacePropReplayDisposition disposition = NativeSurfacePropReplayDisposition::no_feature;
    std::uint64_t state_before_coordinates = 0U;
    std::uint64_t state_after_coordinates = 0U;
    std::uint64_t state_after_recipe = 0U;
    bool has_prop_roll = false;
    float prop_roll = 0.0F;
    // Exact legacy values consumed after class selection. Ordinary rocks use
    // six; legacy tree compatibility consumers use 22 or 36 regardless of architecture.
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
        NativeSurfacePropSourceReceipt source_receipt,
        const std::vector<NativeSurfacePropReplayReceipt> &receipts);

    const std::array<NativeSurfacePropRngTraceEntry, NativeSurfacePropAttemptStream::ATTEMPT_COUNT> &
    entries() const noexcept;
    const NativeSurfacePropSourceReceipt &source_receipt() const noexcept;
    std::uint64_t final_rng_state() const noexcept;
    const std::vector<std::uint8_t> &canonical_binary() const noexcept;
    const Sha256Digest &content_digest() const noexcept;

private:
    NativeSurfacePropRngTrace(
        NativeSurfacePropSourceReceipt source_receipt,
        std::array<NativeSurfacePropRngTraceEntry, NativeSurfacePropAttemptStream::ATTEMPT_COUNT> entries,
        std::uint64_t final_rng_state, std::vector<std::uint8_t> canonical_binary,
        Sha256Digest content_digest) noexcept;

    NativeSurfacePropSourceReceipt source_receipt_{};
    std::array<NativeSurfacePropRngTraceEntry, NativeSurfacePropAttemptStream::ATTEMPT_COUNT> entries_{};
    std::uint64_t final_rng_state_ = 0U;
    std::vector<std::uint8_t> canonical_binary_;
    Sha256Digest content_digest_{};
};

} // namespace voxel::world_backend
