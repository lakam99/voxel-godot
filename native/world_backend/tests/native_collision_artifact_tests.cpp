#include "../core/native_collision_artifact.hpp"
#include "test_harness.hpp"

#include <limits>
#include <new>
#include <thread>
#include <utility>
#include <vector>

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
    return {1048576, 8, 8, 24, 8, 8, 128, alignof(std::max_align_t), 1024, 7};
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

VWB_TEST(synthetic_collision_artifact_default_foreign_incarnation_and_closed_session_reject) {
    const auto before = Domain::allocation_totals();
    {
        Domain d(config(), {0}), other(config(), {0});
        ArtifactSession blank;
        VWB_EXPECT_EQ(Reason::foreign_token, d.begin(blank, stamp(), {1, 0}).reason);
        auto p = d.issue_session(Owner::producer), foreign = other.issue_session(Owner::producer);
        VWB_EXPECT_EQ(Reason::foreign_token, d.begin(foreign.value, stamp(), {1, 0}).reason);
        auto b = d.issue_session(Owner::broker), r = d.issue_session(Owner::receiver);
        VWB_EXPECT_EQ(Reason::wrong_owner, d.begin(b.value, stamp(), {1, 0}).reason);
        VWB_EXPECT_EQ(Reason::wrong_owner, d.begin(r.value, stamp(), {1, 0}).reason);
        auto wrong = stamp(); wrong.incarnation++;
        const auto incarnation_state = d.accounting().value;
        const auto incarnation_allocations = Domain::allocation_totals();
        VWB_EXPECT_EQ(Reason::invalid_configuration, d.begin(p.value, wrong, {1, 0}).reason);
        const auto unchanged = d.accounting().value;
        const auto unchanged_allocations = Domain::allocation_totals();
        VWB_EXPECT_EQ(incarnation_state.requested_bytes, unchanged.requested_bytes);
        VWB_EXPECT_EQ(incarnation_state.peak_requested_bytes, unchanged.peak_requested_bytes);
        VWB_EXPECT_EQ(incarnation_state.reserved_bytes, unchanged.reserved_bytes);
        VWB_EXPECT_EQ(incarnation_state.live_tokens, unchanged.live_tokens);
        VWB_EXPECT_EQ(incarnation_state.occupied_artifacts, unchanged.occupied_artifacts);
        VWB_EXPECT_EQ(incarnation_allocations.live_requested_bytes, unchanged_allocations.live_requested_bytes);
        VWB_EXPECT_EQ(incarnation_allocations.live_blocks, unchanged_allocations.live_blocks);
        VWB_EXPECT_EQ(incarnation_allocations.allocations, unchanged_allocations.allocations);
        VWB_EXPECT_EQ(incarnation_allocations.deallocations, unchanged_allocations.deallocations);
        wrong = stamp(); wrong.through_revision = wrong.original_revision - 1;
        VWB_EXPECT_EQ(Reason::invalid_configuration, d.begin(p.value, wrong, {1, 0}).reason);
        auto a = artifact(d, p.value), alien = artifact(other, foreign.value);
        VWB_EXPECT_EQ(Reason::foreign_token, d.acquire_role(alien, p.value).reason);
        VWB_EXPECT_EQ(Reason::foreign_token, d.acquire_role(a, foreign.value).reason);
        VWB_EXPECT_EQ(Reason::wrong_owner, d.acquire_role(a, b.value).reason);
        CollisionArtifact empty_artifact; ArtifactRole empty_role; ArtifactTransfer empty_transfer; ArtifactHold empty_hold;
        VWB_EXPECT_EQ(Reason::foreign_token, d.snapshot(empty_artifact).reason);
        VWB_EXPECT_EQ(Reason::foreign_token, d.clone_role(empty_role).reason);
        VWB_EXPECT_EQ(Reason::foreign_token, d.begin_transfer(empty_role, b.value).reason);
        VWB_EXPECT_EQ(Reason::foreign_token, d.commit_transfer(empty_transfer).reason);
        VWB_EXPECT_EQ(Reason::foreign_token, d.abort_transfer(empty_transfer));
        VWB_EXPECT_EQ(Reason::foreign_token, d.release_hold(empty_hold));
        const auto count = d.snapshot(a).value.triangle_count;
        auto caller_metadata = d.snapshot(a).value;
        caller_metadata.triangle_count = 999;
        caller_metadata.source_stamp.original19.words[0] = 999;
        VWB_EXPECT_EQ(999u, caller_metadata.triangle_count);
        VWB_EXPECT_EQ(count, d.snapshot(a).value.triangle_count);
        VWB_EXPECT_EQ(19u, d.snapshot(a).value.source_stamp.original19.words[0]);
        VWB_EXPECT_EQ(Reason::none, d.close_session(p.value));
        VWB_EXPECT_EQ(Reason::closed, d.clone_session(p.value).reason);
        VWB_EXPECT_EQ(Reason::closed, d.begin(p.value, stamp(), {0, 0}).reason);
        VWB_EXPECT_EQ(Reason::closed, d.clone_artifact(a).reason);
        VWB_EXPECT(d.snapshot(a).value.cancelled);
    }
    same_live_allocations(before);
}

VWB_TEST(synthetic_collision_artifact_expired_owner_reuse_never_authenticates_old_output) {
    const auto before = Domain::allocation_totals();
    {
        auto cfg = config(); cfg.session_slots = 1;
        Domain d(cfg, {0}); auto p = d.issue_session(Owner::producer); auto a = artifact(d, p.value);
        p.value = ArtifactSession{};
        VWB_EXPECT_EQ(Reason::stale_token, d.clone_artifact(a).reason);
        auto replacement = d.issue_session(Owner::producer);
        VWB_EXPECT_EQ(Status::ready, replacement.status);
        VWB_EXPECT_EQ(Reason::stale_token, d.acquire_role(a, replacement.value).reason);
        VWB_EXPECT(d.snapshot(a).value.cancelled);
    }
    same_live_allocations(before);
}

VWB_TEST(synthetic_collision_artifact_each_fixed_pool_and_global_alias_quota) {
    const auto before = Domain::allocation_totals();
    {
        auto cfg = config(); cfg.session_slots = 1;
        Domain d(cfg, {0}); auto p = d.issue_session(Owner::producer);
        VWB_EXPECT_EQ(Reason::capacity, d.issue_session(Owner::broker).reason);
        d.close_session(p.value);
        VWB_EXPECT_EQ(Reason::capacity, d.issue_session(Owner::receiver).reason);
        p.value = ArtifactSession{};
        VWB_EXPECT_EQ(Status::ready, d.issue_session(Owner::receiver).status);
    }
    {
        auto cfg = config(); cfg.artifact_slots = 1; cfg.role_slots = 2; cfg.hold_slots = 1;
        Domain d(cfg, {0}); auto p = d.issue_session(Owner::producer);
        auto a = artifact(d, p.value);
        VWB_EXPECT_EQ(Reason::capacity, d.begin(p.value, stamp(), {1, 0}).reason);
        auto one = d.acquire_role(a, p.value), two = d.acquire_role(a, p.value);
        VWB_EXPECT_EQ(Reason::capacity, d.acquire_role(a, p.value).reason);
        auto held = d.retain_backing(a), alias = d.clone_hold(held.value);
        VWB_EXPECT_EQ(Status::ready, alias.status);
        VWB_EXPECT_EQ(1u, d.accounting().value.occupied_holds);
        VWB_EXPECT_EQ(Reason::capacity, d.retain_backing(a).reason);
        auto role_alias = d.clone_role(one.value);
        VWB_EXPECT_EQ(Status::ready, role_alias.status);
        VWB_EXPECT_EQ(2u, d.accounting().value.occupied_roles);
        VWB_EXPECT(d.accounting().value.charged_live_token_credit_bytes > 0);
        d.release_role(one.value); d.release_role(two.value);
        d.release_hold(held.value); d.release_hold(alias.value);
        a = CollisionArtifact{};
        VWB_EXPECT_EQ(Reason::capacity, d.begin(p.value, stamp(), {1, 0}).reason); // stale alias still owns backing
        role_alias.value = ArtifactRole{};
        VWB_EXPECT_EQ(Status::ready, d.begin(p.value, stamp(), {1, 0}).status);
    }
    {
        auto cfg = config(); cfg.transfer_slots = 1;
        Domain d(cfg, {0}); auto p = d.issue_session(Owner::producer), b = d.issue_session(Owner::broker);
        auto a = artifact(d, p.value), second = artifact(d, p.value);
        auto role = d.acquire_role(a, p.value), second_role = d.acquire_role(second, p.value);
        auto t = d.begin_transfer(role.value, b.value);
        VWB_EXPECT_EQ(Reason::capacity, d.begin_transfer(second_role.value, b.value).reason);
        d.abort_transfer(t.value);
        VWB_EXPECT_EQ(Reason::capacity, d.begin_transfer(second_role.value, b.value).reason);
        t.value = ArtifactTransfer{};
        VWB_EXPECT_EQ(Status::ready, d.begin_transfer(second_role.value, b.value).status);
    }
    same_live_allocations(before);
}

VWB_TEST(synthetic_collision_artifact_configured_ordinary_capacity_is_not_custody64) {
    const auto before = Domain::allocation_totals();
    {
        auto cfg = config(); cfg.artifact_slots = 65;
        Domain d(cfg, {0}); auto p = d.issue_session(Owner::producer);
        std::vector<CollisionArtifact> held; held.reserve(65); // unit fixture storage, outside core allocator
        for (std::size_t i = 0; i != 65; ++i) {
            auto b = d.begin(p.value, stamp(), {0, 0});
            VWB_EXPECT_EQ(Status::ready, b.status);
            auto a = d.seal(b.value);
            VWB_EXPECT_EQ(Status::ready, a.status);
            held.push_back(std::move(a.value));
        }
        VWB_EXPECT_EQ(65u, d.accounting().value.occupied_artifacts);
        VWB_EXPECT_EQ(0u, d.accounting().value.backing_bytes);
        VWB_EXPECT_EQ(Reason::capacity, d.begin(p.value, stamp(), {0, 0}).reason);
    }
    same_live_allocations(before);
}

VWB_TEST(synthetic_collision_artifact_cookie_reference_exhaustion_is_checked_before_mutation) {
    const auto before = Domain::allocation_totals();
    {
        Domain d(config(), {0}); auto p = d.issue_session(Owner::producer); auto a = artifact(d, p.value);
        const auto state = d.accounting().value;
        NativeCollisionArtifactTestAccess::exhaust_cookies(d);
        VWB_EXPECT_EQ(Reason::cookie_exhausted, d.issue_session(Owner::broker).reason);
        VWB_EXPECT_EQ(Reason::cookie_exhausted, d.begin(p.value, stamp(), {1, 0}).reason);
        VWB_EXPECT_EQ(Reason::cookie_exhausted, d.acquire_role(a, p.value).reason);
        VWB_EXPECT_EQ(Reason::cookie_exhausted, d.retain_backing(a).reason);
        VWB_EXPECT_EQ(Status::ready, d.clone_artifact(a).status); // same ID, no new issuance
        VWB_EXPECT_EQ(state.occupied_artifacts, d.accounting().value.occupied_artifacts);
        VWB_EXPECT_EQ(state.live_tokens, d.accounting().value.live_tokens);
    }
    {
        auto cfg = config(); cfg.maximum_references = 1;
        Domain d(cfg, {0}); auto p = d.issue_session(Owner::producer);
        VWB_EXPECT_EQ(Reason::reference_exhausted, d.clone_session(p.value).reason);
        VWB_EXPECT_EQ(Reason::reference_exhausted, d.begin(p.value, stamp(), {1, 0}).reason);
        VWB_EXPECT_EQ(1u, d.accounting().value.live_tokens);
    }
    {
        auto cfg = config(); cfg.maximum_references = 2;
        Domain d(cfg, {0}); auto p = d.issue_session(Owner::producer), b = d.issue_session(Owner::broker);
        auto a = artifact(d, p.value); auto role = d.acquire_role(a, p.value);
        auto alias = d.clone_role(role.value);
        VWB_EXPECT_EQ(Status::ready, alias.status);
        VWB_EXPECT_EQ(Reason::reference_exhausted, d.clone_role(role.value).reason);
        VWB_EXPECT_EQ(Reason::reference_exhausted, d.clone_artifact(a).reason);
        VWB_EXPECT_EQ(Reason::reference_exhausted, d.begin_transfer(role.value, b.value).reason);
        VWB_EXPECT_EQ(0u, d.accounting().value.occupied_transfers);
    }
    same_live_allocations(before);
}

VWB_TEST(synthetic_collision_artifact_exact_byte_refusal_and_overflow_allocate_nothing) {
    const auto before = Domain::allocation_totals();
    auto cfg = config();
    std::size_t fixed;
    { Domain probe(cfg, {0}); fixed = probe.accounting().value.fixed_control_bytes; }
    cfg.byte_limit = fixed + Domain::checked_requested_bytes(sizeof(ArtifactTriangle), cfg.allocation_alignment) - 1;
    {
        Domain d(cfg, {0}); auto p = d.issue_session(Owner::producer);
        const auto allocations = Domain::allocation_totals().allocations;
        VWB_EXPECT_EQ(Reason::capacity, d.begin(p.value, stamp(), {1, 0}).reason);
        VWB_EXPECT_EQ(allocations, Domain::allocation_totals().allocations);
        VWB_EXPECT_EQ(Reason::size_overflow, d.begin(p.value, stamp(), {std::numeric_limits<std::size_t>::max(), 0}).reason);
        VWB_EXPECT_EQ(0u, d.accounting().value.occupied_artifacts);
        VWB_EXPECT_EQ(0u, d.accounting().value.reserved_bytes);
        VWB_EXPECT_EQ(fixed, d.accounting().value.requested_bytes);
    }
    cfg = config(); cfg.byte_limit = Domain::byte_ceiling + 1;
    VWB_EXPECT_THROW(std::invalid_argument, Domain(cfg, {0}));
    cfg = config(); cfg.incarnation = 0;
    const auto zero_incarnation_before = Domain::allocation_totals();
    VWB_EXPECT_THROW(std::invalid_argument, Domain(cfg, {0}));
    const auto zero_incarnation_after = Domain::allocation_totals();
    VWB_EXPECT_EQ(zero_incarnation_before.live_requested_bytes, zero_incarnation_after.live_requested_bytes);
    VWB_EXPECT_EQ(zero_incarnation_before.live_blocks, zero_incarnation_after.live_blocks);
    VWB_EXPECT_EQ(zero_incarnation_before.allocations, zero_incarnation_after.allocations);
    VWB_EXPECT_EQ(zero_incarnation_before.deallocations, zero_incarnation_after.deallocations);
    same_live_allocations(before);
}

VWB_TEST(synthetic_collision_artifact_transfer_origin_release_destination_close_and_cancel) {
    const auto before = Domain::allocation_totals();
    for (int variant = 0; variant != 5; ++variant) {
        Domain d(config(), {0}); auto p = d.issue_session(Owner::producer), r = d.issue_session(Owner::receiver);
        auto a = artifact(d, p.value); auto role = d.acquire_role(a, p.value);
        auto origin_alias = d.clone_role(role.value); auto t = d.begin_transfer(role.value, r.value);
        VWB_EXPECT_EQ(Status::ready, t.status);
        const auto bytes = d.accounting().value.requested_bytes;
        if (variant == 0) {
            d.release_role(role.value);
            VWB_EXPECT_EQ(Reason::stale_token, d.commit_transfer(t.value).reason);
            VWB_EXPECT_EQ(Reason::stale_token, d.clone_role(origin_alias.value).reason);
        } else if (variant == 1) {
            d.close_session(r.value);
            VWB_EXPECT_EQ(Reason::closed, d.commit_transfer(t.value).reason);
        } else if (variant == 2) {
            d.cancel(a);
            VWB_EXPECT_EQ(Reason::cancelled, d.commit_transfer(t.value).reason);
        } else if (variant == 3) {
            d.close();
            VWB_EXPECT_EQ(Reason::closed, d.commit_transfer(t.value).reason);
        } else {
            d.close_session(p.value);
            VWB_EXPECT_EQ(Reason::closed, d.commit_transfer(t.value).reason);
        }
        VWB_EXPECT_EQ(bytes, d.accounting().value.requested_bytes);
        VWB_EXPECT_EQ(Reason::none, d.abort_transfer(t.value));
        VWB_EXPECT_EQ(Reason::consumed_transfer, d.abort_transfer(t.value));
        VWB_EXPECT_EQ(Reason::consumed_transfer, d.commit_transfer(t.value).reason);
    }
    same_live_allocations(before);
}

VWB_TEST(synthetic_collision_artifact_transfer_token_quota_failure_retains_original_authority) {
    const auto before = Domain::allocation_totals();
    {
        auto cfg = config(); cfg.token_slots = 5;
        Domain d(cfg, {0}); auto p = d.issue_session(Owner::producer), r = d.issue_session(Owner::receiver);
        auto a = artifact(d, p.value); auto role = d.acquire_role(a, p.value);
        auto t = d.begin_transfer(role.value, r.value);
        VWB_EXPECT_EQ(5u, d.accounting().value.live_tokens);
        const auto epoch = d.snapshot(a).value.owner_epoch;
        VWB_EXPECT_EQ(Reason::capacity, d.commit_transfer(t.value).reason);
        VWB_EXPECT_EQ(epoch, d.snapshot(a).value.owner_epoch);
        VWB_EXPECT_EQ(Reason::none, d.abort_transfer(t.value));
        t.value = ArtifactTransfer{};
        VWB_EXPECT_EQ(Status::ready, d.clone_role(role.value).status);
    }
    same_live_allocations(before);
}

VWB_TEST(synthetic_collision_artifact_stale_receipt_drop_cannot_clear_new_guard) {
    const auto before = Domain::allocation_totals();
    {
        Domain d(config(), {0}); auto p = d.issue_session(Owner::producer), b = d.issue_session(Owner::broker), r = d.issue_session(Owner::receiver);
        auto a = artifact(d, p.value); auto origin = d.acquire_role(a, p.value);
        auto old = d.begin_transfer(origin.value, b.value); auto broker = d.commit_transfer(old.value);
        auto pending = d.begin_transfer(broker.value, r.value);
        VWB_EXPECT_EQ(Status::ready, pending.status);
        old.value = ArtifactTransfer{};
        VWB_EXPECT_EQ(Reason::competing_transfer, d.begin_transfer(broker.value, r.value).reason);
        VWB_EXPECT_EQ(Status::ready, d.commit_transfer(pending.value).status);
    }
    same_live_allocations(before);
}

VWB_TEST(synthetic_collision_artifact_immediate_cancel_held_aliases_and_truthful_control_zero) {
    const auto before = Domain::allocation_totals();
    {
        Domain d(config(), {0}); auto p = d.issue_session(Owner::producer); auto a = artifact(d, p.value);
        auto alias = d.clone_artifact(a); auto held = d.retain_backing(a); auto held_alias = d.clone_hold(held.value);
        const auto bytes = d.accounting().value.requested_bytes;
        VWB_EXPECT_EQ(Reason::none, d.cancel(a));
        VWB_EXPECT_EQ(Reason::cancelled, d.clone_artifact(a).reason);
        VWB_EXPECT_EQ(Reason::cancelled, d.clone_hold(held.value).reason);
        VWB_EXPECT_EQ(Reason::cancelled, d.acquire_role(a, p.value).reason);
        VWB_EXPECT_EQ(bytes, d.accounting().value.requested_bytes);
        a = CollisionArtifact{}; alias.value = CollisionArtifact{};
        d.release_hold(held.value);
        VWB_EXPECT_EQ(Status::pending, d.drain(1).status);
        held_alias.value = ArtifactHold{};
        const auto zero_payload = d.accounting().value;
        VWB_EXPECT(zero_payload.payload_drained);
        VWB_EXPECT_EQ(0u, zero_payload.backing_bytes);
        VWB_EXPECT_EQ(zero_payload.fixed_control_bytes, zero_payload.requested_bytes);
        VWB_EXPECT(zero_payload.requested_bytes > 0); // live facade/session controls remain charged
        VWB_EXPECT_EQ(Status::ready, d.drain(1).status);
    }
    same_live_allocations(before); // actual final control allocation was freed
}

VWB_TEST(synthetic_collision_artifact_owner_thread_checks_and_domain_moves) {
    const auto before = Domain::allocation_totals();
    {
        Domain d(config(), {0}); auto p = d.issue_session(Owner::producer);
        Reason issue = Reason::none, copy = Reason::none, observe = Reason::none, close = Reason::none;
        std::thread foreign([&] {
            issue = d.issue_session(Owner::receiver).reason;
            copy = d.clone_session(p.value).reason;
            observe = d.accounting().reason;
            close = d.close();
        });
        foreign.join();
        VWB_EXPECT_EQ(Reason::wrong_thread, issue);
        VWB_EXPECT_EQ(Reason::wrong_thread, copy);
        VWB_EXPECT_EQ(Reason::wrong_thread, observe);
        VWB_EXPECT_EQ(Reason::wrong_thread, close);
        Domain moved(std::move(d));
        VWB_EXPECT_EQ(Reason::closed, d.accounting().reason);
        VWB_EXPECT_EQ(Status::ready, moved.clone_session(p.value).status);
        Domain destination(config(), {0}); destination = std::move(moved);
        VWB_EXPECT_EQ(Reason::closed, moved.issue_session(Owner::producer).reason);
        VWB_EXPECT_EQ(Status::ready, destination.clone_session(p.value).status);
        VWB_EXPECT_EQ(Reason::invalid_configuration, destination.drain(0).reason);
        const auto count = destination.drain(std::numeric_limits<std::size_t>::max()).work_slots;
        const auto cfg = config();
        VWB_EXPECT_EQ(cfg.session_slots + cfg.artifact_slots + cfg.role_slots + cfg.transfer_slots + cfg.hold_slots, count);
    }
    // Deliberately no fake test for wrong-thread noexcept destruction:
    // that fatal branch needs a genuine separately authorized death harness.
    same_live_allocations(before);
}

VWB_TEST(synthetic_collision_artifact_exact_owner_transition_table) {
    const auto before = Domain::allocation_totals();
    for (int from = 0; from != 3; ++from) {
        for (int to = 0; to != 3; ++to) {
            Domain d(config(), {0});
            auto p = d.issue_session(Owner::producer), b = d.issue_session(Owner::broker), r = d.issue_session(Owner::receiver);
            auto a = artifact(d, p.value); auto current = d.acquire_role(a, p.value);
            if (from != 0) {
                const auto &destination = from == 1 ? b.value : r.value;
                auto transfer = d.begin_transfer(current.value, destination);
                auto committed = d.commit_transfer(transfer.value);
                VWB_EXPECT_EQ(Status::ready, committed.status);
                current.value = std::move(committed.value);
            }
            const auto &destination = to == 0 ? p.value : to == 1 ? b.value : r.value;
            const bool legal = (from == 0 && (to == 1 || to == 2)) || (from == 1 && to == 2);
            auto transfer = d.begin_transfer(current.value, destination);
            VWB_EXPECT_EQ(legal ? Reason::none : Reason::wrong_owner, transfer.reason);
            if (legal) VWB_EXPECT_EQ(Reason::none, d.abort_transfer(transfer.value));
        }
    }
    same_live_allocations(before);
}

VWB_TEST(synthetic_collision_artifact_abandoned_builder_and_transfer_roots_release_after_facade) {
    const auto before = Domain::allocation_totals();
    ArtifactBuilder partial;
    ArtifactTransfer transfer;
    {
        Domain d(config(), {0}); auto p = d.issue_session(Owner::producer), r = d.issue_session(Owner::receiver);
        auto builder = d.begin(p.value, stamp(), {2, 128});
        VWB_EXPECT_EQ(Reason::none, d.append(builder.value, triangle()));
        partial = std::move(builder.value);
        auto a = artifact(d, p.value); auto role = d.acquire_role(a, p.value);
        transfer = std::move(d.begin_transfer(role.value, r.value).value);
        VWB_EXPECT_EQ(2u, d.accounting().value.occupied_artifacts);
        // Facade/session/artifact/role tokens leave scope. The transfer's
        // counted edges and builder root alone retain their exact backing.
    }
    VWB_EXPECT(Domain::allocation_totals().live_blocks > before.live_blocks);
    partial = ArtifactBuilder{};
    VWB_EXPECT(Domain::allocation_totals().live_blocks > before.live_blocks);
    transfer = ArtifactTransfer{};
    same_live_allocations(before);
}

VWB_TEST(synthetic_collision_artifact_last_external_origin_drop_revokes_but_retains_backing) {
    const auto before = Domain::allocation_totals();
    for (int variant = 0; variant != 3; ++variant) {
        Domain d(config(), {0}); auto p = d.issue_session(Owner::producer), r = d.issue_session(Owner::receiver);
        auto a = artifact(d, p.value);
        ArtifactTransfer transfer;
        if (variant == 0) {
            // Pure scope destruction of the only external origin handle.
            auto role = d.acquire_role(a, p.value);
            transfer = std::move(d.begin_transfer(role.value, r.value).value);
        } else {
            auto role = d.acquire_role(a, p.value); auto alias = d.clone_role(role.value);
            transfer = std::move(d.begin_transfer(role.value, r.value).value);
            if (variant == 1) {
                role.value = ArtifactRole{};
                alias.value = ArtifactRole{};
            } else {
                // Overwriting by another genuine role also releases the old
                // external identity; the unrelated replacement is no alias.
                auto other = artifact(d, p.value); auto replacement = d.acquire_role(other, p.value);
                role.value = std::move(replacement.value);
                alias.value = ArtifactRole{};
            }
        }
        const auto bytes = d.accounting().value.requested_bytes;
        const auto allocations = Domain::allocation_totals();
        VWB_EXPECT_EQ(Reason::stale_token, d.commit_transfer(transfer).reason);
        VWB_EXPECT_EQ(bytes, d.accounting().value.requested_bytes);
        VWB_EXPECT_EQ(allocations.allocations, Domain::allocation_totals().allocations);
        VWB_EXPECT_EQ(allocations.deallocations, Domain::allocation_totals().deallocations);
        a = CollisionArtifact{};
        VWB_EXPECT_EQ(bytes, d.accounting().value.requested_bytes);
        VWB_EXPECT_EQ(Reason::none, d.abort_transfer(transfer));
        VWB_EXPECT_EQ(bytes, d.accounting().value.requested_bytes);
        transfer = ArtifactTransfer{};
        VWB_EXPECT_EQ(0u, d.accounting().value.occupied_artifacts);
        VWB_EXPECT_EQ(0u, d.accounting().value.backing_bytes);
    }
    same_live_allocations(before);
}

VWB_TEST(synthetic_collision_artifact_surviving_alias_and_moves_preserve_origin_authority) {
    const auto before = Domain::allocation_totals();
    {
        Domain d(config(), {0}); auto p = d.issue_session(Owner::producer), r = d.issue_session(Owner::receiver);
        auto a = artifact(d, p.value); auto role = d.acquire_role(a, p.value); auto alias = d.clone_role(role.value);
        auto transfer = d.begin_transfer(role.value, r.value);
        const auto tokens = d.accounting().value.live_tokens;
        ArtifactRole moved(std::move(alias.value));
        ArtifactRole assigned; assigned = std::move(moved);
        VWB_EXPECT_EQ(tokens, d.accounting().value.live_tokens);
        role.value = ArtifactRole{}; // one external alias remains
        VWB_EXPECT_EQ(Status::ready, d.clone_role(assigned).status);
        VWB_EXPECT_EQ(Status::ready, d.commit_transfer(transfer.value).status);
        VWB_EXPECT_EQ(Reason::stale_token, d.clone_role(assigned).reason);
    }
    {
        Domain d(config(), {0}); auto p = d.issue_session(Owner::producer), r = d.issue_session(Owner::receiver);
        auto a = artifact(d, p.value); auto role = d.acquire_role(a, p.value); auto alias = d.clone_role(role.value);
        auto transfer = d.begin_transfer(role.value, r.value);
        VWB_EXPECT_EQ(Reason::none, d.release_role(alias.value)); // explicit release revokes all aliases
        VWB_EXPECT_EQ(Reason::stale_token, d.clone_role(role.value).reason);
        VWB_EXPECT_EQ(Reason::stale_token, d.commit_transfer(transfer.value).reason);
        VWB_EXPECT_EQ(Reason::none, d.abort_transfer(transfer.value));
    }
    same_live_allocations(before);
}
}
