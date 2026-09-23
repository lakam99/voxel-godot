#include "../core/native_voxel_block_demand.hpp"
#include "test_harness.hpp"

namespace voxel::world_backend::tests {
using Demand = NativeVoxelBlockDemand;
static WorldPhysicalContentIdentity pin(std::uint8_t byte) {
    WorldPhysicalContentIdentity value;
    value.digest[0] = byte;
    return value;
}

VWB_TEST(native_voxel_demand_capacity_resize_preserves_retained_requests) {
    Demand owner(1, 8, 2, 4);
    const Demand::Key first{0, 0, 0, 0, 0}, second{0, 16, 0, 0, 0}, third{0, 32, 0, 0, 0};
    VWB_EXPECT(owner.request_pending(first, 7, 1));
    VWB_EXPECT(owner.request_pending(second, 7, 1));
    VWB_EXPECT(!owner.request_pending(third, 7, 1));
    VWB_EXPECT_EQ(2u, owner.size());
    VWB_EXPECT_EQ(2u, owner.max_entries());
    VWB_EXPECT(!owner.set_max_entries(1));
    VWB_EXPECT_EQ(2u, owner.max_entries());
    VWB_EXPECT(owner.set_max_entries(3));
    VWB_EXPECT(owner.request_pending(third, 7, 1));
    VWB_EXPECT_EQ(3u, owner.size());
    VWB_EXPECT_EQ(1u, owner.find(first)->consumers.size());
    VWB_EXPECT_EQ(1u, owner.find(second)->consumers.size());
    VWB_EXPECT(!owner.set_max_entries(0));
}

VWB_TEST(native_voxel_demand_capacity_retries_after_retirement) {
    Demand owner(1, 8, 1, 4);
    const Demand::Key old_key{0, 0, 0, 0, 0}, next_key{0, 16, 0, 0, 0};
    VWB_EXPECT(owner.request_pending(old_key, 7, 1));
    VWB_EXPECT(!owner.request_pending(next_key, 9, 1));
    VWB_EXPECT(owner.find(next_key) == nullptr);
    owner.release(old_key, 7);
    VWB_EXPECT_EQ(1u, owner.retire(1));
    VWB_EXPECT(owner.request_pending(next_key, 9, 1));
    VWB_EXPECT_EQ(1u, owner.find(next_key)->consumers.size());
}

VWB_TEST(native_voxel_demand_retains_and_promotes_without_duplicate_jobs) {
    Demand owner(1, 8, 2, 4);
    Demand::Key key{0, 1, 2, 3, 0};
    owner.request(key, 10, 1, 5, pin(9));
    owner.request(key, 11, 9, 5, pin(9));
    VWB_EXPECT_EQ(2u, owner.find(key)->consumers.size());
    VWB_EXPECT_EQ(9, owner.find(key)->priority);
    VWB_EXPECT(owner.dispatch().empty());
    owner.source_ready(key, 4, pin(9));
    VWB_EXPECT(owner.dispatch().empty());
    owner.source_ready(key, 5, pin(9));
    auto jobs = owner.dispatch(2);
    VWB_EXPECT_EQ(1u, jobs.size());
    VWB_EXPECT(owner.dispatch().empty());
    VWB_EXPECT(owner.complete(jobs[0], {1, 2, 3}));
    VWB_EXPECT_EQ(3u, owner.prepared_bytes());
    VWB_EXPECT(!owner.insertion_result(jobs[0], false));
    VWB_EXPECT_EQ(Demand::State::prepared, owner.find(key)->state);
    VWB_EXPECT(owner.insertion_result(jobs[0], true));
    VWB_EXPECT(!owner.receipt(jobs[0], true, false));
    VWB_EXPECT(owner.receipt(jobs[0], true, true));
    VWB_EXPECT_EQ(Demand::State::published, owner.find(key)->state);
    owner.mesh_exited(key);
    VWB_EXPECT_EQ(Demand::State::inserted_waiting_mesh, owner.find(key)->state);
    VWB_EXPECT(owner.receipt(jobs[0], true, true));
    owner.release(key, 11);
    VWB_EXPECT_EQ(1, owner.find(key)->priority);
    owner.unloaded(key);
    VWB_EXPECT_EQ(Demand::State::queued, owner.find(key)->state);
    VWB_EXPECT_EQ(1u, owner.dispatch().size());
}

VWB_TEST(native_voxel_demand_pending_consumers_wait_for_authoritative_source) {
    Demand owner(1, 8, 2, 4);
    Demand::Key key{0, 16, 0, 0, 0};
    VWB_EXPECT(owner.request_pending(key, 10, 2));
    VWB_EXPECT(owner.request_pending(key, 11, 7));
    VWB_EXPECT_EQ(2u, owner.find(key)->consumers.size());
    VWB_EXPECT_EQ(7, owner.find(key)->priority);
    VWB_EXPECT(!owner.find(key)->source_bound);
    VWB_EXPECT(owner.dispatch().empty());
    owner.source_ready(key, 0, pin(0));
    VWB_EXPECT(owner.dispatch().empty());
    owner.bind_source(key, 5, pin(9));
    VWB_EXPECT(owner.find(key)->source_bound);
    auto ticket = owner.dispatch()[0];
    VWB_EXPECT_EQ(5u, ticket.revision);
    VWB_EXPECT_EQ(9, ticket.pin.digest[0]);
    owner.request_pending(key, 12, 8);
    VWB_EXPECT_EQ(Demand::State::encoding, owner.find(key)->state);
    owner.bind_source(key, 6, pin(10));
    VWB_EXPECT(!owner.complete(ticket, {1}));
    auto current = owner.dispatch()[0];
    VWB_EXPECT_EQ(6u, current.revision);
    VWB_EXPECT_EQ(3u, owner.find(key)->consumers.size());
}

VWB_TEST(native_voxel_demand_specific_dispatch_never_reserves_another_key) {
    Demand owner(1, 8, 2, 4);
    Demand::Key high{0, 0, 0, 0, 0}, captured{0, 16, 0, 0, 0};
    owner.request_pending(high, 1, 10);
    owner.request_pending(captured, 1, 1);
    owner.bind_source(high, 1, pin(1));
    owner.bind_source(captured, 1, pin(1));
    auto ticket = owner.dispatch_specific(captured);
    VWB_EXPECT(ticket.has_value());
    VWB_EXPECT_EQ(16, ticket->key.x);
    VWB_EXPECT_EQ(Demand::State::queued, owner.find(high)->state);
    VWB_EXPECT(!owner.dispatch_specific(high).has_value());
    VWB_EXPECT(owner.defer(*ticket));
    VWB_EXPECT_EQ(0u, owner.in_flight());
}

VWB_TEST(native_voxel_demand_pending_admission_and_binding_require_live_consumers) {
    Demand owner(1, 8, 1, 4);
    Demand::Key first{0, 0, 0, 0, 0}, other{0, 1, 0, 0, 0}, stale{1, 0, 0, 0, 0};
    VWB_EXPECT(!owner.request_pending(stale, 1, 1));
    VWB_EXPECT(owner.request_pending(first, 1, 2));
    VWB_EXPECT(!owner.request_pending(other, 2, 3));
    owner.bind_source(other, 1, pin(1));
    owner.bind_source(stale, 1, pin(1));
    VWB_EXPECT(!owner.find(first)->source_bound);
    owner.release(first, 1);
    const auto retired_generation = owner.find(first)->generation;
    owner.bind_source(first, 1, pin(1));
    VWB_EXPECT_EQ(Demand::State::retired, owner.find(first)->state);
    VWB_EXPECT_EQ(retired_generation, owner.find(first)->generation);
    VWB_EXPECT(owner.request_pending(first, 2, 3));
    owner.bind_source(first, 1, pin(1));
    VWB_EXPECT_EQ(Demand::State::queued, owner.find(first)->state);
    const auto generation = owner.find(first)->generation;
    owner.bind_source(first, 1, pin(1));
    VWB_EXPECT_EQ(generation, owner.find(first)->generation);
    auto changed = pin(1);
    changed.digest[31] = 7;
    owner.bind_source(first, 1, changed);
    VWB_EXPECT_EQ(generation + 1, owner.find(first)->generation);
    VWB_EXPECT_EQ(7, owner.find(first)->pin.digest[31]);
}

VWB_TEST(native_voxel_demand_waiting_source_selection_and_capture_retry) {
    Demand owner(1, 8, 4, 4);
    Demand::Key low{0, 0, 0, 0, 0}, high{0, 1, 0, 0, 0}, retired{0, 2, 0, 0, 0};
    VWB_EXPECT(!owner.next_waiting_source().has_value());
    owner.source_attempted(low);
    owner.source_capture_deferred(low);
    owner.request_pending(low, 1, 1);
    owner.request_pending(high, 1, 3);
    owner.request_pending(retired, 1, 9);
    owner.release(retired, 1);
    VWB_EXPECT_EQ(1, owner.next_waiting_source()->x);
    owner.source_attempted(high);
    VWB_EXPECT_EQ(1, owner.next_waiting_source()->x);
    owner.bind_source(high, 1, pin(1));
    VWB_EXPECT_EQ(0, owner.next_waiting_source()->x);
    owner.source_capture_deferred(high);
    VWB_EXPECT_EQ(Demand::State::waiting_source, owner.find(high)->state);
    VWB_EXPECT_EQ(1, owner.next_waiting_source()->x);
    owner.source_attempted(high);
    VWB_EXPECT(owner.find(high)->queued_at > 0);
    owner.source_capture_deferred(high);
    VWB_EXPECT_EQ(Demand::State::waiting_source, owner.find(high)->state);
    owner.bind_source(low, 1, pin(1));
    owner.bind_source(high, 1, pin(1));
    VWB_EXPECT(!owner.next_waiting_source().has_value());
}

VWB_TEST(native_voxel_demand_specific_dispatch_checks_state_and_capacity) {
    Demand owner(1, 4, 3, 4);
    Demand::Key a{0, 0, 0, 0, 0}, b{0, 1, 0, 0, 0}, absent{0, 2, 0, 0, 0};
    Demand::Key stale{1, 0, 0, 0, 0};
    VWB_EXPECT(!owner.dispatch_specific(absent).has_value());
    VWB_EXPECT(!owner.dispatch_specific(stale).has_value());
    owner.request_pending(a, 1, 1);
    VWB_EXPECT(!owner.dispatch_specific(a).has_value());
    owner.request_pending(b, 1, 1);
    owner.bind_source(a, 1, pin(1));
    owner.bind_source(b, 1, pin(1));
    auto first = owner.dispatch_specific(a);
    VWB_EXPECT(first.has_value());
    VWB_EXPECT(!owner.dispatch_specific(a).has_value());
    VWB_EXPECT(!owner.dispatch_specific(b).has_value());
    VWB_EXPECT(owner.complete(*first, {1, 2, 3, 4}));
    VWB_EXPECT(!owner.dispatch_specific(b).has_value());
    owner.release(a, 1);
    VWB_EXPECT(owner.dispatch_specific(b).has_value());
}

VWB_TEST(native_voxel_demand_old_epoch_keys_cannot_bind_or_dispatch) {
    Demand owner(2, 8, 2, 4);
    Demand::Key old{0, 0, 0, 0, 0}, current{1, 0, 0, 0, 0};
    owner.request_pending(old, 1, 1);
    owner.reset_epoch(1);
    owner.bind_source(old, 1, pin(1));
    VWB_EXPECT_EQ(Demand::State::retired, owner.find(old)->state);
    VWB_EXPECT(!owner.dispatch_specific(old).has_value());
    owner.request_pending(current, 1, 1);
    owner.bind_source(current, 1, pin(1));
    VWB_EXPECT(owner.dispatch_specific(current).has_value());
}

VWB_TEST(native_voxel_demand_waiting_source_priority_and_age_ties) {
    Demand owner(2, 8, 4, 4);
    Demand::Key first{0, 0, 0, 0, 0}, second{0, 1, 0, 0, 0};
    owner.request_pending(first, 1, 1);
    owner.request_pending(second, 1, 2);
    VWB_EXPECT_EQ(1, owner.next_waiting_source()->x);
    owner.request_pending(second, 1, 0);
    VWB_EXPECT_EQ(0, owner.next_waiting_source()->x);
    owner.request_pending(second, 1, 1);
    VWB_EXPECT_EQ(0, owner.next_waiting_source()->x);
    owner.source_attempted(first);
    VWB_EXPECT_EQ(1, owner.next_waiting_source()->x);
    owner.source_attempted(second);
    VWB_EXPECT_EQ(0, owner.next_waiting_source()->x);
    owner.bind_source(first, 1, pin(1));
    const auto queued_at = owner.find(first)->queued_at;
    owner.source_attempted(first);
    VWB_EXPECT_EQ(queued_at, owner.find(first)->queued_at);
}

VWB_TEST(native_voxel_demand_specific_dispatch_reserves_output_budget) {
    Demand owner(2, 4, 2, 4);
    Demand::Key first{0, 0, 0, 0, 0}, second{0, 1, 0, 0, 0};
    owner.request_pending(first, 1, 1);
    owner.request_pending(second, 1, 1);
    owner.bind_source(first, 1, pin(1));
    owner.bind_source(second, 1, pin(1));
    auto ticket = owner.dispatch_specific(first);
    VWB_EXPECT(ticket.has_value());
    VWB_EXPECT_EQ(1u, owner.in_flight());
    VWB_EXPECT(!owner.dispatch_specific(second).has_value());
    VWB_EXPECT(owner.defer(*ticket));
    owner.bind_source(first, 1, pin(1));
    VWB_EXPECT(owner.dispatch_specific(second).has_value());
}

VWB_TEST(native_voxel_demand_caps_and_stale_worker_completion) {
    Demand owner(1, 4, 2, 4);
    Demand::Key a{0, 0, 0, 0, 0}, b{0, 1, 0, 0, 0};
    owner.request(a, 1, 1, 1, pin(1));
    owner.request(b, 1, 1, 1, pin(1));
    owner.source_ready(a, 1, pin(1));
    owner.source_ready(b, 1, pin(1));
    auto old = owner.dispatch()[0];
    owner.invalidate(old.key, 2, pin(2));
    owner.source_ready(old.key, 2, pin(2));
    VWB_EXPECT(owner.dispatch().empty()); // Physical worker still holds the slot.
    VWB_EXPECT(!owner.complete(old, {1}));
    VWB_EXPECT_EQ(0u, owner.in_flight());
    auto next = owner.dispatch()[0];
    VWB_EXPECT(owner.complete(next, {1, 2, 3, 4}));
    VWB_EXPECT_EQ(4u, owner.prepared_bytes());
    VWB_EXPECT(owner.dispatch().empty());
    owner.release(next.key, 1);
    VWB_EXPECT_EQ(0u, owner.prepared_bytes());
    VWB_EXPECT_EQ(1u, owner.retire(1));
    VWB_EXPECT_EQ(1u, owner.dispatch().size());
}

VWB_TEST(native_voxel_demand_epoch_and_retirement_wait_for_worker) {
    Demand owner(1, 10, 2, 5);
    Demand::Key old_key{0, 0, 0, 0, 0}, new_key{1, 0, 0, 0, 0};
    owner.request(old_key, 1, 0, 1, pin(1));
    owner.source_ready(old_key, 1, pin(1));
    auto old = owner.dispatch()[0];
    owner.reset_epoch(1);
    VWB_EXPECT_EQ(0u, owner.retire(2));
    owner.request(new_key, 1, 0, 1, pin(1));
    owner.source_ready(new_key, 1, pin(1));
    VWB_EXPECT(owner.dispatch().empty());
    VWB_EXPECT(!owner.complete(old, {1}));
    VWB_EXPECT_EQ(1u, owner.retire(1));
    VWB_EXPECT_EQ(1u, owner.dispatch().size());
}

VWB_TEST(native_voxel_demand_uses_full_pin_and_render_receipt) {
    Demand owner(1, 4, 2, 4);
    Demand::Key key{0, 2, 0, 0, 0};
    auto first = pin(7);
    auto second = first;
    second.digest[31] = 1;
    owner.request(key, 1, 0, 1, first);
    owner.source_ready(key, 1, first);
    auto stale = owner.dispatch()[0];
    owner.invalidate(key, 1, second);
    owner.source_ready(key, 1, first);
    VWB_EXPECT_EQ(Demand::State::waiting_source, owner.find(key)->state);
    owner.source_ready(key, 1, second);
    VWB_EXPECT(!owner.complete(stale, {1}));
    auto current = owner.dispatch()[0];
    VWB_EXPECT(!owner.complete(current, {1, 2, 3, 4, 5}));
    VWB_EXPECT_EQ(Demand::State::failed_oversize, owner.find(key)->state);
    VWB_EXPECT_EQ(0u, owner.prepared_bytes());
    VWB_EXPECT(owner.dispatch().empty());
    owner.invalidate(key, 2, second);
    owner.source_ready(key, 2, second);
    current = owner.dispatch()[0];
    VWB_EXPECT(owner.complete(current, {1}));
    VWB_EXPECT(owner.insertion_result(current, true));
    VWB_EXPECT(owner.receipt(current, true, false, false));
}

VWB_TEST(native_voxel_demand_bounded_admission_retries_after_retirement) {
    Demand owner(1, 4, 1, 4);
    Demand::Key a{0, 0, 0, 0, 0}, b{0, 1, 0, 0, 0};
    VWB_EXPECT(owner.request(a, 1, 0, 1, pin(1)));
    VWB_EXPECT(!owner.request(b, 1, 0, 1, pin(1)));
    VWB_EXPECT_EQ(1u, owner.size());
    owner.release(a, 1);
    VWB_EXPECT(!owner.request(b, 1, 0, 1, pin(1)));
    VWB_EXPECT_EQ(1u, owner.retire(1));
    VWB_EXPECT(owner.request(b, 1, 0, 1, pin(1)));
}

VWB_TEST(native_voxel_demand_reserves_each_inflight_output) {
    Demand owner(3, 8, 3, 4);
    for (int x = 0; x < 3; ++x) {
        Demand::Key key{0, x, 0, 0, 0};
        VWB_EXPECT(owner.request(key, 1, 0, 1, pin(1)));
        owner.source_ready(key, 1, pin(1));
    }
    auto jobs = owner.dispatch(3);
    VWB_EXPECT_EQ(2u, jobs.size());
    VWB_EXPECT(owner.complete(jobs[0], {1, 2, 3, 4}));
    VWB_EXPECT(owner.complete(jobs[1], {1, 2, 3, 4}));
    VWB_EXPECT_EQ(8u, owner.prepared_bytes());
    VWB_EXPECT(owner.dispatch().empty());
    VWB_EXPECT_THROW(std::invalid_argument, Demand(1, 3, 1, 4));
}

VWB_TEST(native_voxel_demand_empty_completion_is_terminal_until_invalidated) {
    Demand owner(1, 4, 1, 4);
    Demand::Key key{0, 0, 0, 0, 0};
    owner.request(key, 1, 0, 1, pin(1));
    owner.source_ready(key, 1, pin(1));
    auto job = owner.dispatch()[0];
    VWB_EXPECT(!owner.complete(job, {}));
    VWB_EXPECT_EQ(Demand::State::failed_empty, owner.find(key)->state);
    VWB_EXPECT(owner.dispatch().empty());
    owner.invalidate(key, 2, pin(2));
    owner.source_ready(key, 2, pin(2));
    VWB_EXPECT_EQ(1u, owner.dispatch().size());
}

VWB_TEST(native_voxel_demand_deferred_capture_retries_without_fake_empty) {
    Demand owner(1, 4, 2, 4);
    Demand::Key key{0, 0, 0, 0, 0};
    owner.request(key, 1, 2, 1, pin(1));
    owner.source_ready(key, 1, pin(1));
    auto first = owner.dispatch()[0];
    auto wrong_generation = first;
    ++wrong_generation.generation;
    VWB_EXPECT(!owner.defer(wrong_generation));
    auto wrong_revision = first;
    ++wrong_revision.revision;
    VWB_EXPECT(!owner.defer(wrong_revision));
    auto altered = first;
    altered.pin.digest[31] = 1;
    VWB_EXPECT(!owner.defer(altered));
    VWB_EXPECT_EQ(1u, owner.in_flight());
    VWB_EXPECT(owner.defer(first));
    VWB_EXPECT_EQ(0u, owner.in_flight());
    VWB_EXPECT_EQ(Demand::State::waiting_source, owner.find(key)->state);
    VWB_EXPECT(owner.dispatch().empty());
    VWB_EXPECT(!owner.defer(first));
    owner.source_ready(key, 1, pin(1));
    auto second = owner.dispatch()[0];
    VWB_EXPECT(first.generation != second.generation);
    VWB_EXPECT(!owner.complete(first, {1}));
    VWB_EXPECT(owner.complete(second, {1}));
}

VWB_TEST(native_voxel_demand_defer_preserves_newer_same_key_worker) {
    Demand owner(2, 8, 1, 4);
    Demand::Key key{0, 0, 0, 0, 0};
    owner.request(key, 1, 0, 1, pin(1));
    owner.source_ready(key, 1, pin(1));
    auto old = owner.dispatch()[0];
    owner.invalidate(key, 2, pin(2));
    owner.source_ready(key, 2, pin(2));
    auto current = owner.dispatch()[0];
    VWB_EXPECT_EQ(2u, owner.in_flight());
    VWB_EXPECT(!owner.defer(old));
    VWB_EXPECT_EQ(1u, owner.in_flight());
    VWB_EXPECT_EQ(Demand::State::encoding, owner.find(key)->state);
    VWB_EXPECT(owner.defer(current));
    VWB_EXPECT_EQ(0u, owner.in_flight());
    VWB_EXPECT_EQ(Demand::State::waiting_source, owner.find(key)->state);
}

VWB_TEST(native_voxel_demand_deferred_stale_epoch_and_revision_retire_slot) {
    Demand owner(1, 4, 2, 4);
    Demand::Key key{0, 0, 0, 0, 0};
    owner.request(key, 1, 0, 1, pin(1));
    owner.source_ready(key, 1, pin(1));
    auto stale_revision = owner.dispatch()[0];
    owner.invalidate(key, 2, pin(2));
    VWB_EXPECT(!owner.defer(stale_revision));
    VWB_EXPECT_EQ(0u, owner.in_flight());
    VWB_EXPECT_EQ(Demand::State::waiting_source, owner.find(key)->state);
    owner.source_ready(key, 2, pin(2));
    auto stale_epoch = owner.dispatch()[0];
    owner.reset_epoch(1);
    VWB_EXPECT(!owner.defer(stale_epoch));
    VWB_EXPECT_EQ(0u, owner.in_flight());
    VWB_EXPECT_EQ(1u, owner.retire(1));
}

VWB_TEST(native_voxel_demand_rejects_invalid_capacity_and_epoch) {
    VWB_EXPECT_THROW(std::invalid_argument, Demand(0, 4, 1, 4));
    VWB_EXPECT_THROW(std::invalid_argument, Demand(1, 4, 0, 4));
    VWB_EXPECT_THROW(std::invalid_argument, Demand(1, 4, 1, 0));
    Demand owner(1, 4, 1, 4);
    Demand::Key old{0, 0, 0, 0, 0}, current{1, 0, 0, 0, 0};
    owner.reset_epoch(1);
    VWB_EXPECT(!owner.request(old, 1, 1, 1, pin(1)));
    VWB_EXPECT(owner.request(current, 1, 1, 1, pin(1)));
    owner.source_ready(old, 1, pin(1));
    owner.invalidate(old, 2, pin(2));
    owner.release(old, 1);
    owner.unloaded(old);
    owner.mesh_exited(old);
    VWB_EXPECT(owner.find(old) == nullptr);
    VWB_EXPECT_EQ(0u, owner.retire(0));
}

VWB_TEST(native_voxel_demand_source_and_consumer_lifecycle) {
    Demand owner(1, 8, 2, 4);
    Demand::Key key{0, 0, 0, 0, 0};
    owner.request(key, 1, -2, 1, pin(1));
    owner.source_ready(key, 2, pin(1));
    owner.source_ready(key, 1, pin(2));
    VWB_EXPECT_EQ(Demand::State::waiting_source, owner.find(key)->state);
    owner.release(key, 1);
    owner.source_ready(key, 1, pin(1));
    VWB_EXPECT_EQ(Demand::State::retired, owner.find(key)->state);
    owner.request(key, 2, 3, 1, pin(1));
    VWB_EXPECT_EQ(Demand::State::waiting_source, owner.find(key)->state);
    owner.source_ready(key, 1, pin(1));
    owner.source_ready(key, 1, pin(1));
    VWB_EXPECT_EQ(Demand::State::queued, owner.find(key)->state);
    owner.invalidate(key, 2, pin(2));
    VWB_EXPECT_EQ(Demand::State::waiting_source, owner.find(key)->state);
    owner.source_ready(key, 2, pin(2));
    VWB_EXPECT_EQ(1u, owner.dispatch().size());
}

VWB_TEST(native_voxel_demand_stale_and_duplicate_tickets_do_not_advance) {
    Demand owner(1, 8, 2, 4);
    Demand::Key key{0, 0, 0, 0, 0}, absent{0, 1, 0, 0, 0};
    owner.request(key, 1, 1, 1, pin(1));
    owner.source_ready(key, 1, pin(1));
    auto job = owner.dispatch()[0];
    auto alien = job;
    alien.key = absent;
    VWB_EXPECT(!owner.complete(alien, {1}));
    VWB_EXPECT(!owner.insertion_result(alien, true));
    VWB_EXPECT(!owner.receipt(alien, true, true));
    auto wrong_generation = job;
    ++wrong_generation.generation;
    VWB_EXPECT(!owner.complete(wrong_generation, {1}));
    VWB_EXPECT(!owner.insertion_result(job, true));
    VWB_EXPECT(!owner.receipt(job, true, true));
    VWB_EXPECT(owner.complete(job, {1}));
    VWB_EXPECT(!owner.complete(job, {1}));
    VWB_EXPECT(!owner.insertion_result(wrong_generation, true));
    VWB_EXPECT(!owner.receipt(job, true, true));
    VWB_EXPECT(owner.insertion_result(job, true));
    VWB_EXPECT(!owner.insertion_result(job, true));
    VWB_EXPECT(!owner.receipt(job, false, true));
    VWB_EXPECT(owner.receipt(job, true, false, false));
    VWB_EXPECT(!owner.receipt(job, true, true));
}

VWB_TEST(native_voxel_demand_revisions_retirement_and_mesh_transitions) {
    Demand owner(1, 8, 3, 4);
    Demand::Key a{0, 0, 0, 0, 0}, b{0, 1, 0, 0, 0};
    owner.request(a, 1, 1, 1, pin(1));
    owner.source_ready(a, 1, pin(1));
    auto stale = owner.dispatch()[0];
    owner.release(a, 1);
    VWB_EXPECT_EQ(0u, owner.retire(1));
    owner.request(a, 2, 2, 2, pin(2));
    owner.source_ready(a, 2, pin(2));
    VWB_EXPECT(!owner.complete(stale, {1}));
    auto job = owner.dispatch()[0];
    VWB_EXPECT(!owner.insertion_result(stale, true));
    VWB_EXPECT(!owner.receipt(stale, true, true));
    VWB_EXPECT(owner.complete(job, {1}));
    owner.request(a, 2, 2, 3, pin(3));
    VWB_EXPECT_EQ(0u, owner.prepared_bytes());
    VWB_EXPECT(!owner.insertion_result(job, true));
    owner.source_ready(a, 3, pin(3));
    job = owner.dispatch()[0];
    VWB_EXPECT(owner.complete(job, {1}));
    VWB_EXPECT(owner.insertion_result(job, true));
    owner.mesh_exited(a);
    VWB_EXPECT_EQ(Demand::State::inserted_waiting_mesh, owner.find(a)->state);
    owner.unloaded(a);
    VWB_EXPECT_EQ(Demand::State::queued, owner.find(a)->state);
    owner.unloaded(a);
    VWB_EXPECT_EQ(Demand::State::queued, owner.find(a)->state);
    owner.request(b, 3, 1, 1, pin(1));
    owner.release(b, 3);
    VWB_EXPECT_EQ(1u, owner.retire(1));
    VWB_EXPECT(owner.find(b) == nullptr);
    owner.release(a, 2);
    VWB_EXPECT_EQ(1u, owner.retire(2));
    VWB_EXPECT(owner.find(a) == nullptr);
}

VWB_TEST(native_voxel_demand_priority_ties_epoch_and_ticket_integrity) {
    Demand owner(2, 8, 3, 4);
    Demand::Key a{0, 0, 0, 0, 0}, b{0, 1, 0, 0, 0}, c{0, 2, 0, 0, 0};
    owner.request(a, 1, 2, 1, pin(1));
    owner.request(b, 1, 2, 1, pin(1));
    owner.request(c, 1, 3, 1, pin(1));
    owner.source_ready(a, 1, pin(1));
    owner.source_ready(b, 1, pin(1));
    owner.source_ready(c, 1, pin(1));
    auto jobs = owner.dispatch(2);
    VWB_EXPECT_EQ(2u, jobs.size());
    VWB_EXPECT_EQ(2, jobs[0].key.x);
    VWB_EXPECT_EQ(0, jobs[1].key.x);
    auto altered = jobs[0];
    altered.revision = 2;
    VWB_EXPECT(!owner.complete(altered, {1}));
    VWB_EXPECT_EQ(2u, owner.in_flight());
    altered = jobs[0];
    altered.pin = pin(2);
    VWB_EXPECT(!owner.complete(altered, {1}));
    VWB_EXPECT_EQ(2u, owner.in_flight());
    VWB_EXPECT(!owner.insertion_result(altered, true));
    VWB_EXPECT(!owner.receipt(altered, true, true));
    owner.invalidate(c, 2, pin(2));
    owner.source_ready(c, 2, pin(2));
    VWB_EXPECT(!owner.complete(jobs[0], {1}));
    VWB_EXPECT(owner.complete(jobs[1], {1}));
    VWB_EXPECT(owner.insertion_result(jobs[1], true));
    owner.reset_epoch(1);
    owner.source_ready(a, 1, pin(1));
    VWB_EXPECT(!owner.insertion_result(jobs[1], true));
    VWB_EXPECT(!owner.receipt(jobs[1], true, true));
    VWB_EXPECT_EQ(3u, owner.retire(3));
}

VWB_TEST(native_voxel_demand_altered_completion_preserves_genuine_worker) {
    Demand owner(1, 4, 1, 4);
    Demand::Key key{0, 0, 0, 0, 0};
    owner.request(key, 1, 1, 1, pin(1));
    owner.source_ready(key, 1, pin(1));
    auto ticket = owner.dispatch()[0];
    auto altered = ticket;
    altered.revision = 2;
    VWB_EXPECT(!owner.complete(altered, {1}));
    altered = ticket;
    altered.pin = pin(2);
    VWB_EXPECT(!owner.complete(altered, {1}));
    VWB_EXPECT_EQ(1u, owner.in_flight());
    VWB_EXPECT_EQ(Demand::State::encoding, owner.find(key)->state);
    VWB_EXPECT(owner.complete(ticket, {1}));
    VWB_EXPECT_EQ(0u, owner.in_flight());
    VWB_EXPECT_EQ(Demand::State::prepared, owner.find(key)->state);
    altered = ticket;
    altered.revision = 2;
    VWB_EXPECT(!owner.insertion_result(altered, true));
    VWB_EXPECT_EQ(Demand::State::prepared, owner.find(key)->state);
}

VWB_TEST(native_voxel_demand_overlapping_stale_workers_keep_physical_slots) {
    Demand owner(2, 8, 1, 4);
    Demand::Key key{0, 0, 0, 0, 0};
    owner.request(key, 1, 1, 1, pin(1));
    owner.source_ready(key, 1, pin(1));
    auto old = owner.dispatch()[0];
    owner.invalidate(key, 2, pin(2));
    owner.source_ready(key, 2, pin(2));
    auto current = owner.dispatch()[0];
    VWB_EXPECT(!owner.complete(old, {1}));
    VWB_EXPECT_EQ(1u, owner.in_flight());
    VWB_EXPECT(owner.complete(current, {1}));
    VWB_EXPECT_EQ(0u, owner.in_flight());
}

VWB_TEST(native_voxel_demand_same_revision_pin_and_epoch_refresh) {
    Demand owner(1, 8, 1, 4);
    Demand::Key key{0, 0, 0, 0, 0};
    owner.request(key, 1, 1, 1, pin(1));
    owner.request(key, 1, 1, 1, pin(2));
    VWB_EXPECT_EQ(1u, owner.find(key)->consumers.size());
    VWB_EXPECT_EQ(2, owner.find(key)->pin.digest[0]);
    owner.reset_epoch(0);
    owner.source_ready(key, 1, pin(2));
    VWB_EXPECT_EQ(1u, owner.dispatch().size());
}

VWB_TEST(native_voxel_demand_equal_priority_prefers_older_later_key) {
    Demand owner(1, 8, 2, 4);
    Demand::Key low{0, 0, 0, 0, 0}, high{0, 1, 0, 0, 0};
    owner.request(low, 1, 1, 1, pin(1));
    owner.request(high, 1, 1, 1, pin(1));
    owner.source_ready(high, 1, pin(1));
    owner.source_ready(low, 1, pin(1));
    auto jobs = owner.dispatch();
    VWB_EXPECT_EQ(1u, jobs.size());
    VWB_EXPECT_EQ(1, jobs[0].key.x);
    Demand reverse(1, 8, 2, 4);
    reverse.request(low, 1, 1, 1, pin(1));
    reverse.request(high, 1, 1, 1, pin(1));
    reverse.source_ready(low, 1, pin(1));
    reverse.source_ready(high, 1, pin(1));
    VWB_EXPECT_EQ(0, reverse.dispatch()[0].key.x);
    Demand lower_score(1, 8, 2, 4);
    lower_score.request(low, 1, 3, 1, pin(1));
    lower_score.request(high, 1, 1, 1, pin(1));
    lower_score.source_ready(low, 1, pin(1));
    lower_score.source_ready(high, 1, pin(1));
    VWB_EXPECT_EQ(0, lower_score.dispatch()[0].key.x);
}

} // namespace voxel::world_backend::tests
