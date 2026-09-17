#include "test_harness.hpp"

#include "../core/world_delta_store.hpp"

#include <cstdint>
#include <stdexcept>
#include <string>
#include <vector>

namespace voxel::world_backend::tests {
namespace {

WorldDeltaState air() {
    return {-1.35, false, TerrainMaterialId::air, TerrainBiomeId::underground_air, TerrainFluidId::none};
}

WorldDeltaState stone() {
    return {1.35, true, TerrainMaterialId::stone, TerrainBiomeId::underground, TerrainFluidId::none};
}

WorldDeltaState water() {
    return {-0.25, false, TerrainMaterialId::water, TerrainBiomeId::ocean, TerrainFluidId::water};
}

WorldDeltaOperation set(const WorldDeltaNamespace name_space, const CellCoord coordinate, const WorldDeltaState state) {
    return {name_space, coordinate, WorldDeltaOperationKind::set, state};
}

WorldDeltaOperation clear(const WorldDeltaNamespace name_space, const CellCoord coordinate) {
    return {name_space, coordinate, WorldDeltaOperationKind::clear, std::nullopt};
}

WorldDeltaTransaction transaction(const std::string &id, const std::uint64_t expected,
    std::vector<WorldDeltaOperation> operations) {
    return {id, expected, std::move(operations)};
}

void expect_rejection(const WorldDeltaRejectReason expected, const WorldDeltaTransaction &value,
    WorldDeltaStore &store) {
    try {
        static_cast<void>(store.commit(value));
    } catch (const WorldDeltaRejected &error) {
        VWB_EXPECT_EQ(expected, error.reason());
        return;
    }
    fail("world delta rejection", __FILE__, __LINE__, "expected WorldDeltaRejected");
}

} // namespace

VWB_TEST(world_delta_store_starts_empty_and_pins_an_immutable_zero_revision) {
    WorldDeltaStore store;
    const WorldDeltaPinnedSnapshot first = store.pin();
    VWB_EXPECT_EQ(0ULL, store.revision());
    VWB_EXPECT_EQ(0ULL, first.revision());
    VWB_EXPECT(first.records().empty());
    VWB_EXPECT(!first.value_at(WorldDeltaNamespace::terrain_override, {0, 0, 0}));
    VWB_EXPECT(!first.effective_value_at({0, 0, 0}));
}

VWB_TEST(world_delta_store_commits_typed_state_sections_and_preserves_old_pins) {
    WorldDeltaStore store;
    const WorldDeltaPinnedSnapshot before = store.pin();
    const WorldDeltaCommitReceipt receipt = store.commit(transaction("delta:negative", 0, {
        set(WorldDeltaNamespace::terrain_override, {-1, -16, -17}, stone()),
        set(WorldDeltaNamespace::terrain_override, {16, 0, 31}, air()),
    }));
    VWB_EXPECT_EQ(WorldDeltaCommitStatus::committed, receipt.status);
    VWB_EXPECT_EQ(1ULL, receipt.revision);
    VWB_EXPECT_EQ(std::string("delta:negative"), receipt.transaction_id);
    VWB_EXPECT_EQ(2U, receipt.affected_sections.size());
    VWB_EXPECT((receipt.affected_sections[0].section == CellCoord{-1, -1, -2}));
    VWB_EXPECT((receipt.affected_sections[1].section == CellCoord{1, 0, 1}));

    VWB_EXPECT_EQ(0ULL, before.revision());
    VWB_EXPECT(!before.effective_value_at({-1, -16, -17}));
    const WorldDeltaPinnedSnapshot after = store.pin();
    VWB_EXPECT_EQ(1ULL, after.revision());
    const auto first = after.value_at(WorldDeltaNamespace::terrain_override, {-1, -16, -17});
    VWB_EXPECT(first.has_value());
    VWB_EXPECT_EQ(stone(), first->state);
    VWB_EXPECT_EQ(1ULL, first->revision);
    const auto second = after.value_at(WorldDeltaNamespace::terrain_override, {16, 0, 31});
    VWB_EXPECT(second.has_value());
    VWB_EXPECT_EQ(air(), second->state);
    VWB_EXPECT_EQ(1ULL, second->revision);
}

VWB_TEST(world_delta_store_scene_overlay_wins_only_while_it_exists) {
    WorldDeltaStore store;
    const CellCoord target{4, 5, 6};
    static_cast<void>(store.commit(transaction("delta:durable", 0, {
        set(WorldDeltaNamespace::terrain_override, target, stone()),
    })));
    static_cast<void>(store.commit(transaction("delta:overlay", 1, {
        set(WorldDeltaNamespace::scene_overlay, target, water()),
    })));
    const WorldDeltaPinnedSnapshot overlay = store.pin();
    VWB_EXPECT_EQ(stone(), overlay.value_at(WorldDeltaNamespace::terrain_override, target)->state);
    VWB_EXPECT_EQ(water(), overlay.value_at(WorldDeltaNamespace::scene_overlay, target)->state);
    VWB_EXPECT_EQ(water(), overlay.effective_value_at(target)->state);

    const auto clear_receipt = store.commit(transaction("delta:clear-overlay", 2, {
        clear(WorldDeltaNamespace::scene_overlay, target),
    }));
    VWB_EXPECT_EQ(WorldDeltaCommitStatus::committed, clear_receipt.status);
    VWB_EXPECT_EQ(3ULL, clear_receipt.revision);
    VWB_EXPECT_EQ(1U, clear_receipt.affected_sections.size());
    const WorldDeltaPinnedSnapshot restored = store.pin();
    VWB_EXPECT(!restored.value_at(WorldDeltaNamespace::scene_overlay, target));
    VWB_EXPECT_EQ(stone(), restored.effective_value_at(target)->state);
}

VWB_TEST(world_delta_store_clear_removes_the_named_namespace_and_revision_bumps_once) {
    WorldDeltaStore store;
    const CellCoord target{0, 0, 0};
    static_cast<void>(store.commit(transaction("delta:set", 0, {
        set(WorldDeltaNamespace::terrain_override, target, stone()),
        set(WorldDeltaNamespace::scene_overlay, target, air()),
    })));
    const auto receipt = store.commit(transaction("delta:clear-durable", 1, {
        clear(WorldDeltaNamespace::terrain_override, target),
    }));
    VWB_EXPECT_EQ(2ULL, receipt.revision);
    const auto pin = store.pin();
    VWB_EXPECT(!pin.value_at(WorldDeltaNamespace::terrain_override, target));
    VWB_EXPECT_EQ(air(), pin.effective_value_at(target)->state);
    static_cast<void>(store.commit(transaction("delta:clear-overlay", 2, {
        clear(WorldDeltaNamespace::scene_overlay, target),
    })));
    VWB_EXPECT(!store.pin().effective_value_at(target));
}

VWB_TEST(world_delta_store_transaction_ids_are_order_independent_idempotent_and_conflict_strictly) {
    WorldDeltaStore store;
    const WorldDeltaTransaction first = transaction("delta:stable", 0, {
        set(WorldDeltaNamespace::terrain_override, {17, 0, 0}, stone()),
        set(WorldDeltaNamespace::scene_overlay, {-1, 0, 0}, air()),
    });
    const auto committed = store.commit(first);
    const WorldDeltaTransaction replayed_order = transaction("delta:stable", 0, {
        set(WorldDeltaNamespace::scene_overlay, {-1, 0, 0}, air()),
        set(WorldDeltaNamespace::terrain_override, {17, 0, 0}, stone()),
    });
    const auto replay = store.commit(replayed_order);
    VWB_EXPECT_EQ(WorldDeltaCommitStatus::idempotent_replay, replay.status);
    VWB_EXPECT_EQ(committed.transaction_id, replay.transaction_id);
    VWB_EXPECT_EQ(committed.revision, replay.revision);
    VWB_EXPECT_EQ(committed.affected_sections, replay.affected_sections);
    VWB_EXPECT_EQ(1ULL, store.revision());

    expect_rejection(WorldDeltaRejectReason::transaction_conflict, transaction("delta:stable", 1, {
        set(WorldDeltaNamespace::terrain_override, {17, 0, 0}, air()),
    }), store);
    VWB_EXPECT_EQ(1ULL, store.revision());
}

VWB_TEST(world_delta_store_noop_set_and_clear_do_not_bump_but_are_idempotent) {
    WorldDeltaStore store;
    const CellCoord target{1, 2, 3};
    static_cast<void>(store.commit(transaction("delta:set", 0, {
        set(WorldDeltaNamespace::terrain_override, target, stone()),
    })));
    const auto no_change = store.commit(transaction("delta:same", 1, {
        set(WorldDeltaNamespace::terrain_override, target, stone()),
        clear(WorldDeltaNamespace::scene_overlay, target),
    }));
    VWB_EXPECT_EQ(WorldDeltaCommitStatus::no_change, no_change.status);
    VWB_EXPECT_EQ(1ULL, no_change.revision);
    VWB_EXPECT(no_change.affected_sections.empty());
    const auto replay = store.commit(transaction("delta:same", 1, {
        clear(WorldDeltaNamespace::scene_overlay, target),
        set(WorldDeltaNamespace::terrain_override, target, stone()),
    }));
    VWB_EXPECT_EQ(WorldDeltaCommitStatus::idempotent_replay, replay.status);
    VWB_EXPECT_EQ(1ULL, store.revision());
}

VWB_TEST(world_delta_store_validates_everything_before_mutating) {
    WorldDeltaStore store;
    const CellCoord target{1, 2, 3};
    expect_rejection(WorldDeltaRejectReason::invalid_transaction, transaction("delta:duplicate", 0, {
        set(WorldDeltaNamespace::terrain_override, target, stone()),
        clear(WorldDeltaNamespace::terrain_override, target),
    }), store);
    WorldDeltaState invalid = stone();
    invalid.density = -1.0;
    invalid.solid = true;
    expect_rejection(WorldDeltaRejectReason::invalid_transaction, transaction("delta:invalid", 0, {
        set(WorldDeltaNamespace::terrain_override, target, invalid),
    }), store);
    expect_rejection(WorldDeltaRejectReason::invalid_transaction, transaction("delta:clear-state", 0, {
        {WorldDeltaNamespace::terrain_override, target, WorldDeltaOperationKind::clear, air()},
    }), store);
    expect_rejection(WorldDeltaRejectReason::invalid_transaction, transaction("", 0, {
        set(WorldDeltaNamespace::terrain_override, target, stone()),
    }), store);
    VWB_EXPECT_EQ(0ULL, store.revision());
    VWB_EXPECT(store.pin().records().empty());

    const auto committed = store.commit(transaction("delta:duplicate", 0, {
        set(WorldDeltaNamespace::terrain_override, target, stone()),
    }));
    VWB_EXPECT_EQ(WorldDeltaCommitStatus::committed, committed.status);
}

VWB_TEST(world_delta_store_rejects_stale_revisions_and_bounded_capacity_atomically) {
    WorldDeltaStore store({1, 2});
    expect_rejection(WorldDeltaRejectReason::revision_conflict, transaction("delta:stale", 1, {
        set(WorldDeltaNamespace::terrain_override, {0, 0, 0}, stone()),
    }), store);
    const auto first = store.commit(transaction("delta:first", 0, {
        set(WorldDeltaNamespace::terrain_override, {0, 0, 0}, stone()),
    }));
    VWB_EXPECT_EQ(1ULL, first.revision);
    expect_rejection(WorldDeltaRejectReason::capacity_exceeded, transaction("delta:full", 1, {
        set(WorldDeltaNamespace::terrain_override, {0, 0, 0}, air()),
        set(WorldDeltaNamespace::terrain_override, {1, 0, 0}, water()),
    }), store);
    const auto pin = store.pin();
    VWB_EXPECT_EQ(1ULL, pin.revision());
    VWB_EXPECT_EQ(stone(), pin.effective_value_at({0, 0, 0})->state);
    VWB_EXPECT(!pin.effective_value_at({1, 0, 0}));
    static_cast<void>(store.commit(transaction("delta:no-change", 1, {
        set(WorldDeltaNamespace::terrain_override, {0, 0, 0}, stone()),
    })));
    expect_rejection(WorldDeltaRejectReason::capacity_exceeded, transaction("delta:over-ledger", 1, {
        clear(WorldDeltaNamespace::scene_overlay, {99, 0, 0}),
    }), store);
}

VWB_TEST(world_delta_store_rejects_invalid_limits_and_unknown_enums) {
    VWB_EXPECT_THROW(WorldDeltaRejected, WorldDeltaStore({0, 1}));
    VWB_EXPECT_THROW(WorldDeltaRejected, WorldDeltaStore({1, 0}));
    WorldDeltaStore store;
    expect_rejection(WorldDeltaRejectReason::invalid_transaction, transaction("delta:unknown-space", 0, {
        set(static_cast<WorldDeltaNamespace>(255U), {0, 0, 0}, stone()),
    }), store);
    expect_rejection(WorldDeltaRejectReason::invalid_transaction, transaction("delta:unknown-kind", 0, {
        {WorldDeltaNamespace::terrain_override, {0, 0, 0}, static_cast<WorldDeltaOperationKind>(255U), std::nullopt},
    }), store);
}

} // namespace voxel::world_backend::tests
