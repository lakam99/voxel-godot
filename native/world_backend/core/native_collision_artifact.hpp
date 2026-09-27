#pragma once

#include <cstddef>
#include <cstdint>

namespace voxel::world_backend {
namespace tests { struct NativeCollisionArtifactTestAccess; }
namespace artifact_detail { struct Control; struct Access; }

// Pure owned-memory prerequisite. These scalar stamps are not world capture,
// source-currentness, native publication, physics, or gameplay proof.
enum class ArtifactOwnerKind : std::uint8_t { producer, broker, receiver };
enum class ArtifactStatus : std::uint8_t { ready, pending, rejected };
enum class ArtifactReason : std::uint8_t {
    none, invalid_configuration, size_overflow, capacity, allocation_failed,
    foreign_token, stale_token, wrong_owner, wrong_thread, closed, cancelled,
    incomplete, consumed_transfer, outstanding_holders, competing_transfer,
    nonfinite_vertex, cookie_exhausted, reference_exhausted
};
struct ArtifactVertex { float x, y, z; };
struct ArtifactTriangle { ArtifactVertex a, b, c; };
struct ArtifactDigest { std::uint64_t words[4]; };
static_assert(sizeof(ArtifactVertex) == 12);
static_assert(sizeof(ArtifactTriangle) == 36);
static_assert(sizeof(ArtifactDigest) == 32);
struct ArtifactSourceStamp {
    ArtifactDigest original19, original16, source, configuration, policy;
    std::uint64_t original_revision, through_revision, incarnation;
};
struct ArtifactDomainConfig {
    std::size_t byte_limit, session_slots, artifact_slots, role_slots;
    std::size_t transfer_slots, hold_slots, token_slots, allocation_alignment;
    std::size_t maximum_references;
    std::uint64_t incarnation;
};
struct ArtifactAllocationPolicy { std::size_t fail_allocation_ordinal; };
struct ArtifactReservation { std::size_t triangle_capacity, scratch_capacity_bytes; };

struct ArtifactSessionTag;
struct ArtifactBuilderTag;
struct CollisionArtifactTag;
struct ArtifactRoleTag;
struct ArtifactTransferTag;
struct ArtifactHoldTag;

// Move/destruction is owner-thread only. Wrong-thread noexcept destruction is
// a fatal contract violation, not a concurrent worker integration guarantee.
// Every issued/explicitly cloned token consumes one precharged token slot.
template<class Tag> class ArtifactToken {
public:
    ArtifactToken() noexcept;
    ~ArtifactToken() noexcept;
    ArtifactToken(ArtifactToken &&) noexcept;
    ArtifactToken &operator=(ArtifactToken &&) noexcept;
    ArtifactToken(const ArtifactToken &) = delete;
    ArtifactToken &operator=(const ArtifactToken &) = delete;
private:
    artifact_detail::Control *control_;
    std::size_t slot_, credit_;
    std::uint64_t cookie_;
    friend struct artifact_detail::Access;
    friend class NativeCollisionArtifactDomain;
};
using ArtifactSession = ArtifactToken<ArtifactSessionTag>;
using ArtifactBuilder = ArtifactToken<ArtifactBuilderTag>;
using CollisionArtifact = ArtifactToken<CollisionArtifactTag>;
using ArtifactRole = ArtifactToken<ArtifactRoleTag>;
using ArtifactTransfer = ArtifactToken<ArtifactTransferTag>;
using ArtifactHold = ArtifactToken<ArtifactHoldTag>;

template<class T> struct ArtifactResult {
    ArtifactStatus status;
    ArtifactReason reason;
    T value;
};
struct ArtifactMetadata {
    std::uint64_t allocation_id, artifact_cookie, owner_epoch;
    ArtifactSourceStamp source_stamp;
    std::size_t triangle_count, triangle_capacity, backing_requested_bytes;
    bool sealed, cancelled;
};
struct ArtifactAccounting {
    std::size_t requested_bytes, peak_requested_bytes, reserved_bytes;
    std::size_t fixed_control_bytes, backing_bytes, occupied_sessions;
    std::size_t occupied_artifacts, occupied_roles, occupied_transfers;
    std::size_t occupied_holds, live_tokens, token_capacity;
    std::size_t charged_live_token_credit_bytes, cursor;
    bool closed, payload_drained;
};
struct ArtifactAllocationTotals {
    std::size_t live_requested_bytes, live_blocks, allocations, deallocations;
};
struct ArtifactDrainResult {
    ArtifactStatus status;
    ArtifactReason reason;
    std::size_t work_slots;
    bool payload_drained;
};

class NativeCollisionArtifactDomain {
public:
    static constexpr std::size_t byte_ceiling = 268435456;
    NativeCollisionArtifactDomain(const ArtifactDomainConfig &, ArtifactAllocationPolicy);
    ~NativeCollisionArtifactDomain() noexcept;
    NativeCollisionArtifactDomain(NativeCollisionArtifactDomain &&) noexcept;
    NativeCollisionArtifactDomain &operator=(NativeCollisionArtifactDomain &&) noexcept;
    NativeCollisionArtifactDomain(const NativeCollisionArtifactDomain &) = delete;
    NativeCollisionArtifactDomain &operator=(const NativeCollisionArtifactDomain &) = delete;

    ArtifactResult<ArtifactSession> issue_session(ArtifactOwnerKind);
    ArtifactResult<ArtifactSession> clone_session(const ArtifactSession &);
    ArtifactReason close_session(const ArtifactSession &);
    ArtifactResult<ArtifactBuilder> begin(const ArtifactSession &,
        const ArtifactSourceStamp &, const ArtifactReservation &);
    ArtifactReason append(ArtifactBuilder &, const ArtifactTriangle &);
    ArtifactResult<CollisionArtifact> seal(ArtifactBuilder &);
    ArtifactReason cancel(ArtifactBuilder &);
    ArtifactReason release_builder(ArtifactBuilder &);
    ArtifactResult<CollisionArtifact> clone_artifact(const CollisionArtifact &);
    ArtifactResult<ArtifactRole> acquire_role(const CollisionArtifact &, const ArtifactSession &);
    ArtifactResult<ArtifactRole> clone_role(const ArtifactRole &);
    ArtifactResult<ArtifactTransfer> begin_transfer(const ArtifactRole &, const ArtifactSession &);
    ArtifactResult<ArtifactRole> commit_transfer(ArtifactTransfer &);
    ArtifactReason abort_transfer(ArtifactTransfer &);
    ArtifactResult<ArtifactHold> retain_backing(const CollisionArtifact &);
    ArtifactResult<ArtifactHold> clone_hold(const ArtifactHold &);
    ArtifactReason cancel(const CollisionArtifact &);
    ArtifactReason release_role(ArtifactRole &);
    ArtifactReason release_hold(ArtifactHold &);
    ArtifactResult<ArtifactMetadata> snapshot(const CollisionArtifact &) const;
    ArtifactResult<ArtifactAccounting> accounting() const;
    ArtifactReason close();
    ArtifactDrainResult drain(std::size_t maximum_slots);

    // Diagnostic atomics, not authority or a transactionally consistent
    // cross-domain snapshot. Exact before/after unit assertions serialize.
    static ArtifactAllocationTotals allocation_totals() noexcept;
    static std::size_t checked_requested_bytes(std::size_t, std::size_t);
private:
    artifact_detail::Control *control_;
    void test_force_cookie_exhaustion();
    friend struct tests::NativeCollisionArtifactTestAccess;
};
}
