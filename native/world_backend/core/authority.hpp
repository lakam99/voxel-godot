#pragma once

#include "sha256.hpp"

#include <cstdint>

namespace voxel::world_backend {

struct OwnerGeneration {
    std::uint64_t value = 0;
};

struct CancellationEpoch {
    std::uint64_t value = 0;
};

struct SourceRevision {
    std::uint64_t value = 0;
};

struct RequestAuthority {
    Sha256Digest world_digest{};
    OwnerGeneration owner;
    CancellationEpoch cancellation;
    SourceRevision source_revision;
};

enum class AuthorityDecision : std::uint8_t {
    accept = 0,
    wrong_world = 1,
    stale_owner = 2,
    cancelled = 3,
    stale_source = 4,
};

AuthorityDecision validate_result_authority(const RequestAuthority &result, const RequestAuthority &current) noexcept;
bool advance_epoch(CancellationEpoch &epoch) noexcept;
bool advance_owner(OwnerGeneration &owner) noexcept;

} // namespace voxel::world_backend
