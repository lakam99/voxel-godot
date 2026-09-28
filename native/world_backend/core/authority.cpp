#include "authority.hpp"

#include <limits>

namespace voxel::world_backend {

AuthorityDecision validate_result_authority(const RequestAuthority &result, const RequestAuthority &current) noexcept {
    if (result.world_digest != current.world_digest) {
        return AuthorityDecision::wrong_world;
    }
    if (result.owner.value != current.owner.value) {
        return AuthorityDecision::stale_owner;
    }
    if (result.cancellation.value != current.cancellation.value) {
        return AuthorityDecision::cancelled;
    }
    if (result.source_revision.value != current.source_revision.value) {
        return AuthorityDecision::stale_source;
    }
    return AuthorityDecision::accept;
}

bool advance_epoch(CancellationEpoch &epoch) noexcept {
    if (epoch.value == std::numeric_limits<std::uint64_t>::max()) {
        return false;
    }
    ++epoch.value;
    return true;
}

bool advance_owner(OwnerGeneration &owner) noexcept {
    if (owner.value == std::numeric_limits<std::uint64_t>::max()) {
        return false;
    }
    ++owner.value;
    return true;
}

} // namespace voxel::world_backend
