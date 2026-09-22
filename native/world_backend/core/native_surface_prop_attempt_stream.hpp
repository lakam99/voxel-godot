#pragma once

#include "godot_pcg_compat.hpp"
#include "world_source.hpp"

#include <array>
#include <cstdint>
#include <stdexcept>
#include <string>

namespace voxel::world_backend {

struct NativeSurfacePropAttempt final {
    std::uint32_t ordinal = 0U;
    std::int32_t cell_x = 0;
    std::int32_t cell_z = 0;
    std::string durable_id;

    bool operator==(const NativeSurfacePropAttempt &other) const noexcept;
};

class NativeSurfacePropAttemptStreamRejected final : public std::invalid_argument {
public:
    NativeSurfacePropAttemptStreamRejected();
};

// Immutable *unfiltered* legacy attempt stream for one natural surface chunk.
// It owns neither terrain sampling nor feature publication.  That separation
// is intentional: removed-prop tombstones must filter a completed manifest,
// never change which shared-RNG candidates later attempts observe.
class NativeSurfacePropAttemptStream final {
public:
    static constexpr std::uint32_t ATTEMPT_COUNT = 28U;
    static constexpr std::int32_t CHUNK_CELLS = 28;
    static constexpr std::int32_t EDGE_MARGIN_CELLS = 2;

    static NativeSurfacePropAttemptStream create(
        const AdmittedTerrainSeed &seed, std::int32_t chunk_x, std::int32_t chunk_z);

    std::uint32_t rng_seed() const noexcept;
    std::uint64_t final_rng_state() const noexcept;
    const std::array<NativeSurfacePropAttempt, ATTEMPT_COUNT> &attempts() const noexcept;

private:
    NativeSurfacePropAttemptStream(
        std::uint32_t rng_seed, std::uint64_t final_rng_state,
        std::array<NativeSurfacePropAttempt, ATTEMPT_COUNT> attempts) noexcept;

    std::uint32_t rng_seed_ = 0U;
    std::uint64_t final_rng_state_ = 0U;
    std::array<NativeSurfacePropAttempt, ATTEMPT_COUNT> attempts_{};
};

} // namespace voxel::world_backend
