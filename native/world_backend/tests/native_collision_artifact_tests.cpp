#include "../core/native_collision_artifact.hpp"
#include "test_harness.hpp"

#include <limits>
#include <new>
#include <utility>

namespace voxel::world_backend::tests {
// Synthetic pure-core ownership tests only. Stamps below are deliberate unit
// data, not genuine world19/world16 captures or native/physics publication.
using Domain = NativeCollisionArtifactDomain;
using Reason = ArtifactReason;
using Status = ArtifactStatus;
using Owner = ArtifactOwnerKind;

struct NativeCollisionArtifactTestAccess {
    static void exhaust_cookies(Domain &d) { d.test_force_cookie_exhaustion(); }
};
static ArtifactDomainConfig config() {
    return {1048576, 8, 8, 24, 8, 8, 128, alignof(std::max_align_t), 1024};
}
static ArtifactSourceStamp stamp() {
    ArtifactSourceStamp s{};
    s.original19.words[0] = 19; s.original16.words[0] = 16;
    s.source.words[0] = 101; s.configuration.words[0] = 202;
    s.policy.words[0] = 303; s.original_revision = s.through_revision = 3;
    s.incarnation = 7;
    return s;
}
static ArtifactTriangle triangle() {
    return {{1.0f, 2.0f, 3.0f}, {1.0f, 2.0f, 3.0f}, {1.0f, 2.0f, 3.0f}};
}
static CollisionArtifact artifact(Domain &d, const ArtifactSession &s) {
    auto b = d.begin(s, stamp(), {1, 64});
    VWB_EXPECT_EQ(Status::ready, b.status);
    VWB_EXPECT_EQ(Reason::none, d.append(b.value, triangle()));
    auto a = d.seal(b.value);
    VWB_EXPECT_EQ(Status::ready, a.status);
    VWB_EXPECT_EQ(Reason::foreign_token, d.append(b.value, triangle()));
    return std::move(a.value);
}
static void same_live_allocations(ArtifactAllocationTotals before) {
    const auto after = Domain::allocation_totals();
    VWB_EXPECT_EQ(before.live_requested_bytes, after.live_requested_bytes);
    VWB_EXPECT_EQ(before.live_blocks, after.live_blocks);
}

VWB_TEST(synthetic_collision_artifact_checked_layout_and_constructor_admission) {
    const auto before = Domain::allocation_totals();
    VWB_EXPECT(Domain::checked_requested_bytes(36, 64) >= 100);
    VWB_EXPECT_EQ(0u, Domain::checked_requested_bytes(36, 64) % 64);
    VWB_EXPECT_THROW(std::invalid_argument, Domain::checked_requested_bytes(36, 3));
    VWB_EXPECT_THROW(std::overflow_error, Domain::checked_requested_bytes(std::numeric_limits<std::size_t>::max(), 64));
    auto bad = config(); bad.token_slots = std::numeric_limits<std::size_t>::max();
    VWB_EXPECT_THROW(std::overflow_error, Domain(bad, {0}));
    bad = config(); bad.byte_limit = 1;
    VWB_EXPECT_THROW(std::invalid_argument, Domain(bad, {0}));
    VWB_EXPECT_THROW(std::bad_alloc, Domain(config(), {1}));
    same_live_allocations(before);
}
VWB_TEST(synthetic_collision_artifact_finite_degenerate_seal_and_partial_cancel) {
    const auto before = Domain::allocation_totals();
    {
        Domain d(config(), {0});
        auto s = d.issue_session(Owner::producer);
        auto b = d.begin(s.value, stamp(), {2, 128});
        VWB_EXPECT_EQ(Status::ready, b.status);
        auto invalid = triangle(); invalid.a.x = std::numeric_limits<float>::infinity();
        VWB_EXPECT_EQ(Reason::nonfinite_vertex, d.append(b.value, invalid));
        VWB_EXPECT_EQ(Reason::none, d.append(b.value, triangle()));
        auto tiny = triangle(); tiny.c.x += std::numeric_limits<float>::epsilon();
        VWB_EXPECT_EQ(Reason::none, d.append(b.value, tiny));
        VWB_EXPECT_EQ(Reason::capacity, d.append(b.value, triangle()));
        auto a = d.seal(b.value);
        auto metadata = d.snapshot(a.value);
        VWB_EXPECT_EQ(2u, metadata.value.triangle_count);
        VWB_EXPECT_EQ(2u, metadata.value.triangle_capacity);
        VWB_EXPECT(metadata.value.sealed && !metadata.value.cancelled);
        VWB_EXPECT_EQ(Reason::foreign_token, d.seal(b.value).reason);
        auto partial = d.begin(s.value, stamp(), {2, 32});
        VWB_EXPECT_EQ(Reason::none, d.cancel(partial.value));
        VWB_EXPECT_EQ(Reason::cancelled, d.append(partial.value, triangle()));
        VWB_EXPECT_EQ(Reason::cancelled, d.seal(partial.value).reason);
        VWB_EXPECT_EQ(Reason::none, d.release_builder(partial.value));
        VWB_EXPECT_EQ(1u, d.accounting().value.occupied_artifacts);
    }
    same_live_allocations(before);
}
VWB_TEST(synthetic_collision_artifact_same_backing_transfer_alias_conflict_and_replay) {
    const auto before = Domain::allocation_totals();
    {
        Domain d(config(), {0});
        auto p = d.issue_session(Owner::producer), b = d.issue_session(Owner::broker), r = d.issue_session(Owner::receiver);
        auto a = artifact(d, p.value);
        auto first = d.acquire_role(a, p.value), distinct = d.acquire_role(a, p.value);
        auto alias = d.clone_role(first.value);
        const auto original = d.snapshot(a).value;
        const auto bytes = d.accounting().value.requested_bytes;
        auto t = d.begin_transfer(first.value, b.value);
        VWB_EXPECT_EQ(Status::ready, t.status);
        VWB_EXPECT_EQ(Reason::competing_transfer, d.begin_transfer(distinct.value, r.value).reason);
        auto broker = d.commit_transfer(t.value);
        VWB_EXPECT_EQ(Status::ready, broker.status);
        VWB_EXPECT_EQ(Reason::consumed_transfer, d.commit_transfer(t.value).reason);
        VWB_EXPECT_EQ(Reason::consumed_transfer, d.abort_transfer(t.value));
        VWB_EXPECT_EQ(Reason::stale_token, d.clone_role(alias.value).reason);
        VWB_EXPECT_EQ(Reason::stale_token, d.begin_transfer(distinct.value, r.value).reason);
        auto next = d.begin_transfer(broker.value, r.value);
        VWB_EXPECT_EQ(Status::ready, next.status);
        VWB_EXPECT_EQ(Reason::none, d.abort_transfer(next.value));
        VWB_EXPECT_EQ(Reason::consumed_transfer, d.commit_transfer(next.value).reason);
        VWB_EXPECT_EQ(Status::ready, d.clone_role(broker.value).status);
        next.value = ArtifactTransfer{};
        auto final = d.begin_transfer(broker.value, r.value);
        auto receiver = d.commit_transfer(final.value);
        VWB_EXPECT_EQ(Status::ready, receiver.status);
        VWB_EXPECT_EQ(Reason::wrong_owner, d.begin_transfer(receiver.value, p.value).reason);
        const auto current = d.snapshot(a).value;
        VWB_EXPECT_EQ(original.allocation_id, current.allocation_id);
        VWB_EXPECT_EQ(original.source_stamp.original_revision, current.source_stamp.original_revision);
        VWB_EXPECT_EQ(original.source_stamp.original19.words[0], current.source_stamp.original19.words[0]);
        VWB_EXPECT_EQ(bytes, d.accounting().value.requested_bytes);
    }
    same_live_allocations(before);
}
VWB_TEST(synthetic_collision_artifact_nth_allocation_rollback_and_token_quota) {
    const auto before = Domain::allocation_totals();
    for (const std::size_t ordinal : {2u, 3u}) {
        Domain d(config(), {ordinal}); auto p = d.issue_session(Owner::producer);
        const auto initial = d.accounting().value;
        auto denied = d.begin(p.value, stamp(), {4, 64});
        VWB_EXPECT_EQ(Reason::allocation_failed, denied.reason);
        const auto after = d.accounting().value;
        VWB_EXPECT_EQ(initial.requested_bytes, after.requested_bytes);
        VWB_EXPECT_EQ(0u, after.reserved_bytes);
        VWB_EXPECT_EQ(0u, after.occupied_artifacts);
        VWB_EXPECT_EQ(initial.live_tokens, after.live_tokens);
        VWB_EXPECT_EQ(Status::ready, d.begin(p.value, stamp(), {1, 64}).status);
    }
    {
        auto cfg = config(); cfg.token_slots = 3;
        Domain d(cfg, {0}); auto p = d.issue_session(Owner::producer); auto a = artifact(d, p.value);
        auto h = d.retain_backing(a);
        VWB_EXPECT_EQ(3u, d.accounting().value.live_tokens);
        VWB_EXPECT_EQ(Reason::capacity, d.clone_session(p.value).reason);
        VWB_EXPECT_EQ(Reason::capacity, d.clone_artifact(a).reason);
        VWB_EXPECT_EQ(Reason::capacity, d.clone_hold(h.value).reason);
        VWB_EXPECT_EQ(Reason::capacity, d.acquire_role(a, p.value).reason);
        VWB_EXPECT_EQ(Reason::none, d.release_hold(h.value));
        VWB_EXPECT_EQ(Status::ready, d.clone_artifact(a).status);
    }
    same_live_allocations(before);
}
VWB_TEST(synthetic_collision_artifact_facade_loss_keeps_actual_backing_and_constant_final_release) {
    const auto before = Domain::allocation_totals();
    CollisionArtifact a;
    ArtifactHold held;
    {
        Domain d(config(), {0}); auto p = d.issue_session(Owner::producer);
        a = artifact(d, p.value); held = std::move(d.retain_backing(a).value);
        VWB_EXPECT_EQ(Reason::none, d.close());
        VWB_EXPECT_EQ(Reason::closed, d.clone_artifact(a).reason);
        const auto cursor = d.accounting().value.cursor;
        const auto drain = d.drain(1);
        VWB_EXPECT_EQ(1u, drain.work_slots);
        VWB_EXPECT(!drain.payload_drained);
        VWB_EXPECT_EQ(cursor + 1, d.accounting().value.cursor);
    }
    VWB_EXPECT(Domain::allocation_totals().live_requested_bytes > before.live_requested_bytes);
    a = CollisionArtifact{};
    VWB_EXPECT(Domain::allocation_totals().live_requested_bytes > before.live_requested_bytes);
    held = ArtifactHold{};
    same_live_allocations(before);
}
}
