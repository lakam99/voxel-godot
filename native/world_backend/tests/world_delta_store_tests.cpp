#include "test_harness.hpp"

#include "../core/world_delta_store.hpp"

#include <algorithm>
#include <cstdint>
#include <limits>
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

WorldDeltaState lava() {
    return {-0.25, false, TerrainMaterialId::lava, TerrainBiomeId::underground, TerrainFluidId::lava};
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

NativeCellState typed_air(const CellCoord cell, const NativeCellStateNamespace name_space) {
    NativeCellStateInput input;
    input.cell = cell;
    input.material = TerrainMaterialId::air;
    input.biome = TerrainBiomeId::underground_air;
    input.solid = false;
    input.density = -1.35;
    input.fluid = TerrainFluidId::none;
    input.generated = false;
    input.edited = true;
    return make_native_cell_state(input, name_space);
}

NativeTypedWorldStateRecord typed_durable(const CellCoord cell) {
    return {NativeCellStateNamespace::durable_terrain, NativeTypedWorldStatePersistence::durable,
        typed_air(cell, NativeCellStateNamespace::durable_terrain)};
}

NativeTypedWorldStateRecord typed_stone(const CellCoord cell) {
    NativeCellStateInput input;
    input.cell = cell;
    input.material = TerrainMaterialId::stone;
    input.biome = TerrainBiomeId::underground;
    input.solid = true;
    input.density = 1.35;
    input.fluid = TerrainFluidId::none;
    input.light = {15, 4};
    input.metadata = NativeValue::object({{"key", NativeValue::string("value")}});
    input.block_id = NativeBlockIdentity::create("door.oak.closed");
    input.generated = false;
    input.edited = true;
    return {NativeCellStateNamespace::durable_terrain, NativeTypedWorldStatePersistence::durable,
        make_native_cell_state(input, NativeCellStateNamespace::durable_terrain)};
}

NativeTypedWorldStateRecord typed_overlay(const CellCoord cell) {
    return {NativeCellStateNamespace::scene_overlay, NativeTypedWorldStatePersistence::transient,
        typed_air(cell, NativeCellStateNamespace::scene_overlay)};
}

WorldTypedStateAdmission typed_admission(const std::string &id, const std::uint64_t expected,
    std::vector<NativeTypedWorldStateRecord> durable, std::vector<NativeTypedWorldStateRecord> overlays = {}) {
    return {id, expected, NativeTypedWorldStateSnapshot::create(std::move(durable)), std::move(overlays)};
}

void expect_typed_rejection(const WorldDeltaRejectReason expected, const WorldTypedStateAdmission &value,
    WorldDeltaStore &store) {
    try {
        static_cast<void>(store.admit_typed_state(value));
    } catch (const WorldDeltaRejected &error) {
        VWB_EXPECT_EQ(expected, error.reason());
        return;
    }
    fail("typed world delta rejection", __FILE__, __LINE__, "expected WorldDeltaRejected");
}

NativePlayerCreatedInstance feature_instance(const std::string &id, const CellCoord cell) {
    return {id, cell, 3.5, 0.25, NativeBlockIdentity::create("crate.oak"),
        NativeValue::object({{"open", NativeValue::boolean(false)}})};
}

WorldFeatureDeltaAdmission feature_admission(const std::string &id, const std::uint64_t expected,
    std::vector<NativeFeatureTombstone> tombstones = {},
    std::vector<NativePlayerCreatedInstance> instances = {}) {
    return {id, expected, NativeFeatureDeltaSnapshot::create(std::move(tombstones), std::move(instances))};
}

void expect_feature_rejection(const WorldDeltaRejectReason expected, const WorldFeatureDeltaAdmission &value,
    WorldDeltaStore &store) {
    try {
        static_cast<void>(store.admit_feature_deltas(value));
    } catch (const WorldDeltaRejected &error) {
        VWB_EXPECT_EQ(expected, error.reason());
        return;
    }
    fail("feature world delta rejection", __FILE__, __LINE__, "expected WorldDeltaRejected");
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
    VWB_EXPECT(first.typed_durable_snapshot().records().empty());
    VWB_EXPECT(first.typed_transient_overlays().empty());
    VWB_EXPECT(!first.typed_effective_value_at({0, 0, 0}));
    VWB_EXPECT(first.feature_delta_snapshot().tombstones().empty());
    VWB_EXPECT(first.feature_delta_snapshot().player_created_instances().empty());
}

VWB_TEST(world_delta_store_pins_feature_deltas_in_the_same_immutable_revision_as_cells) {
    WorldDeltaStore store;
    const WorldDeltaPinnedSnapshot before = store.pin();
    const WorldDeltaCommitReceipt admitted = store.admit_feature_deltas(feature_admission("feature:initial", 0,
        {}, {feature_instance("player:crate:1", {-16, 0, 0})}));
    VWB_EXPECT_EQ(WorldDeltaCommitStatus::committed, admitted.status);
    VWB_EXPECT_EQ(1ULL, admitted.revision);
    VWB_EXPECT_EQ(27U, admitted.affected_sections.size());
    VWB_EXPECT(before.feature_delta_snapshot().tombstones().empty());
    VWB_EXPECT(before.feature_delta_snapshot().player_created_instances().empty());
    const WorldDeltaPinnedSnapshot pin = store.pin();
    VWB_EXPECT_EQ(1ULL, pin.revision());
    VWB_EXPECT_EQ(std::string("player:crate:1"),
        pin.feature_delta_snapshot().player_created_instances()[0].instance_id);
    VWB_EXPECT((pin.feature_delta_snapshot().player_created_instances()[0].cell == CellCoord{-16, 0, 0}));

    const WorldDeltaCommitReceipt terrain = store.commit(transaction("delta:after-feature", 1, {
        set(WorldDeltaNamespace::terrain_override, {0, 0, 0}, stone()),
    }));
    VWB_EXPECT_EQ(2ULL, terrain.revision);
    VWB_EXPECT_EQ(1ULL, pin.revision());
    VWB_EXPECT_EQ(2ULL, store.pin().revision());
    VWB_EXPECT_EQ(1U, store.pin().feature_delta_snapshot().player_created_instances().size());
}

VWB_TEST(world_delta_store_feature_replacement_invalidates_old_new_and_removed_instance_cells) {
    WorldDeltaStore store;
    static_cast<void>(store.admit_feature_deltas(feature_admission("feature:first", 0, {}, {
        feature_instance("player:crate:1", {-16, 0, 0}),
    })));
    NativePlayerCreatedInstance moved = feature_instance("player:crate:1", {32, 0, 0});
    moved.runtime_state = NativeValue::object({{"open", NativeValue::boolean(true)}});
    const WorldDeltaCommitReceipt moved_receipt = store.admit_feature_deltas(feature_admission("feature:moved", 1,
        {}, {moved}));
    VWB_EXPECT_EQ(WorldDeltaCommitStatus::committed, moved_receipt.status);
    VWB_EXPECT_EQ(2ULL, moved_receipt.revision);
    // Old section -1 and new section 2 yield full x=-2..3 halos.
    VWB_EXPECT_EQ(54U, moved_receipt.affected_sections.size());
    for (std::int32_t z = -1; z <= 1; ++z) {
        for (std::int32_t y = -1; y <= 1; ++y) {
            for (std::int32_t x = -2; x <= 3; ++x) {
                VWB_EXPECT(std::find(moved_receipt.affected_sections.begin(), moved_receipt.affected_sections.end(),
                    WorldDeltaSectionKey{{x, y, z}}) != moved_receipt.affected_sections.end());
            }
        }
    }
    const WorldDeltaCommitReceipt removed = store.admit_feature_deltas(feature_admission("feature:removed", 2));
    VWB_EXPECT_EQ(WorldDeltaCommitStatus::committed, removed.status);
    VWB_EXPECT_EQ(3ULL, removed.revision);
    VWB_EXPECT_EQ(27U, removed.affected_sections.size());
    VWB_EXPECT(store.pin().feature_delta_snapshot().player_created_instances().empty());

}

VWB_TEST(world_delta_store_rejects_tombstones_until_a_native_feature_footprint_catalog_exists) {
    WorldDeltaStore store;
    const WorldDeltaPinnedSnapshot before = store.pin();
    // An ID-only removedProps entry cannot safely invalidate the generated
    // feature's unknown collision/render/navigation footprint.
    expect_feature_rejection(WorldDeltaRejectReason::invalid_transaction,
        feature_admission("feature:tombstone-only", 0, {{"generated:ruin:1"}}), store);
    expect_feature_rejection(WorldDeltaRejectReason::invalid_transaction,
        feature_admission("feature:mixed", 0, {{"generated:ruin:1"}}, {
            feature_instance("player:crate:1", {0, 0, 0}),
        }), store);
    VWB_EXPECT_EQ(0ULL, store.revision());
    VWB_EXPECT_EQ(0ULL, before.revision());
    VWB_EXPECT(store.pin().feature_delta_snapshot().tombstones().empty());
    VWB_EXPECT(store.pin().feature_delta_snapshot().player_created_instances().empty());

    // Player instances do carry a cell, so they remain safe to admit now.
    const WorldDeltaCommitReceipt player_only = store.admit_feature_deltas(feature_admission("feature:player-only", 0, {}, {
        feature_instance("player:crate:1", {0, 0, 0}),
    }));
    VWB_EXPECT_EQ(WorldDeltaCommitStatus::committed, player_only.status);
    VWB_EXPECT_EQ(27U, player_only.affected_sections.size());
}

VWB_TEST(world_delta_store_feature_admissions_are_idempotent_kind_strict_and_capacity_bounded) {
    WorldDeltaStore store;
    const WorldFeatureDeltaAdmission first = feature_admission("shared:feature", 0, {}, {
        feature_instance("player:crate:1", {0, 0, 0}),
    });
    const WorldDeltaCommitReceipt committed = store.admit_feature_deltas(first);
    const WorldDeltaCommitReceipt replay = store.admit_feature_deltas(first);
    VWB_EXPECT_EQ(WorldDeltaCommitStatus::idempotent_replay, replay.status);
    VWB_EXPECT_EQ(committed.revision, replay.revision);
    expect_rejection(WorldDeltaRejectReason::transaction_conflict, transaction("shared:feature", 1, {
        set(WorldDeltaNamespace::terrain_override, {0, 0, 0}, stone()),
    }), store);
    expect_typed_rejection(WorldDeltaRejectReason::transaction_conflict,
        typed_admission("shared:feature", 1, {typed_durable({0, 0, 0})}), store);
    expect_feature_rejection(WorldDeltaRejectReason::transaction_conflict, feature_admission("shared:feature", 1, {}, {
        feature_instance("player:crate:1", {1, 0, 0}),
    }), store);
    expect_feature_rejection(WorldDeltaRejectReason::invalid_transaction,
        feature_admission("", 1), store);
    expect_feature_rejection(WorldDeltaRejectReason::invalid_transaction,
        feature_admission(std::string("feature\0nul", 10), 1), store);
    expect_feature_rejection(WorldDeltaRejectReason::revision_conflict,
        feature_admission("feature:stale", 0), store);

    WorldDeltaStore combined_capacity({2, 4});
    static_cast<void>(combined_capacity.admit_typed_state(
        typed_admission("typed:capacity", 0, {typed_durable({0, 0, 0})})));
    expect_feature_rejection(WorldDeltaRejectReason::capacity_exceeded,
        feature_admission("feature:over-capacity", 1, {}, {
            feature_instance("player:crate:2", {1, 0, 0}),
            feature_instance("player:crate:3", {2, 0, 0}),
        }), combined_capacity);
    VWB_EXPECT_EQ(1ULL, combined_capacity.revision());

    WorldDeltaStore transaction_capacity({4, 1});
    static_cast<void>(transaction_capacity.admit_feature_deltas(feature_admission("feature:journal", 0)));
    expect_feature_rejection(WorldDeltaRejectReason::capacity_exceeded,
        feature_admission("feature:journal-full", 0), transaction_capacity);

    WorldDeltaStore overflow({4, 4, std::numeric_limits<std::uint64_t>::max()});
    expect_feature_rejection(WorldDeltaRejectReason::capacity_exceeded,
        feature_admission("feature:max-revision", std::numeric_limits<std::uint64_t>::max(), {}, {
            feature_instance("player:crate:max", {0, 0, 0}),
        }), overflow);
    VWB_EXPECT(overflow.pin().feature_delta_snapshot().player_created_instances().empty());
}

VWB_TEST(world_delta_store_feature_no_change_keeps_revision_and_pinned_snapshot_immutable) {
    WorldDeltaStore store;
    const WorldFeatureDeltaAdmission first = feature_admission("feature:first", 0, {}, {
        feature_instance("player:crate:1", {0, 0, 0}),
    });
    static_cast<void>(store.admit_feature_deltas(first));
    const WorldDeltaPinnedSnapshot pin = store.pin();
    const WorldDeltaCommitReceipt no_change = store.admit_feature_deltas(feature_admission("feature:no-change", 1,
        {}, {feature_instance("player:crate:1", {0, 0, 0})}));
    VWB_EXPECT_EQ(WorldDeltaCommitStatus::no_change, no_change.status);
    VWB_EXPECT_EQ(1ULL, no_change.revision);
    VWB_EXPECT(no_change.affected_sections.empty());
    VWB_EXPECT_EQ(1ULL, pin.revision());
    VWB_EXPECT_EQ(1U, pin.feature_delta_snapshot().player_created_instances().size());
}

VWB_TEST(world_delta_store_feature_instance_merge_compares_canonical_ids_without_cell_order_assumptions) {
    WorldDeltaStore store;
    static_cast<void>(store.admit_feature_deltas(feature_admission("feature:merge-first", 0, {}, {
        feature_instance("player:bravo", {0, 0, 0}),
        feature_instance("player:zulu", {64, 0, 0}),
    })));
    // The old/new walk encounters old-ID < new-ID, then new-ID < old-ID,
    // then an unchanged shared ID. It is intentionally independent of the
    // cells' z/y/x storage order.
    const WorldDeltaCommitReceipt receipt = store.admit_feature_deltas(feature_admission("feature:merge-second", 1, {}, {
        feature_instance("player:charlie", {16, 0, 0}),
        feature_instance("player:zulu", {64, 0, 0}),
    }));
    VWB_EXPECT_EQ(WorldDeltaCommitStatus::committed, receipt.status);
    VWB_EXPECT_EQ(2ULL, receipt.revision);
    // Only sections 0 (removed bravo) and 1 (added charlie) changed; the
    // unchanged zulu instance must not expand the invalidation neighborhood.
    VWB_EXPECT_EQ(36U, receipt.affected_sections.size());
    VWB_EXPECT(std::find(receipt.affected_sections.begin(), receipt.affected_sections.end(),
        WorldDeltaSectionKey{{-1, -1, -1}}) != receipt.affected_sections.end());
    VWB_EXPECT(std::find(receipt.affected_sections.begin(), receipt.affected_sections.end(),
        WorldDeltaSectionKey{{2, 1, 1}}) != receipt.affected_sections.end());
}

VWB_TEST(world_delta_store_admits_typed_state_in_the_same_immutable_revision_as_deltas) {
    WorldDeltaStore store;
    const WorldDeltaPinnedSnapshot before = store.pin();
    NativeTypedWorldStateRecord durable = typed_stone({-16, 0, 0});
    NativeTypedWorldStateRecord overlay = typed_overlay({-16, 0, 0});
    overlay.state.light = {0, 7};
    const WorldDeltaCommitReceipt admitted = store.admit_typed_state(
        typed_admission("typed:initial", 0, {durable}, {overlay}));
    VWB_EXPECT_EQ(WorldDeltaCommitStatus::committed, admitted.status);
    VWB_EXPECT_EQ(1ULL, admitted.revision);
    VWB_EXPECT_EQ(27U, admitted.affected_sections.size());
    VWB_EXPECT_EQ(0ULL, before.revision());
    VWB_EXPECT(before.typed_durable_snapshot().records().empty());
    VWB_EXPECT(before.typed_transient_overlays().empty());

    const WorldDeltaPinnedSnapshot typed_pin = store.pin();
    VWB_EXPECT_EQ(1ULL, typed_pin.revision());
    VWB_EXPECT_EQ(1U, typed_pin.typed_durable_snapshot().records().size());
    VWB_EXPECT_EQ(1U, typed_pin.typed_transient_overlays().size());
    VWB_EXPECT_EQ(15, static_cast<int>(typed_pin.typed_durable_value_at({-16, 0, 0})->light.sky));
    VWB_EXPECT_EQ(1U, typed_pin.typed_durable_value_at({-16, 0, 0})->metadata.as_object().size());
    VWB_EXPECT(typed_pin.typed_durable_value_at({-16, 0, 0})->block_id.has_value());
    VWB_EXPECT_EQ(7, static_cast<int>(typed_pin.typed_effective_value_at({-16, 0, 0})->light.block));

    const WorldDeltaCommitReceipt delta = store.commit(transaction("delta:after-typed", 1, {
        set(WorldDeltaNamespace::terrain_override, {0, 0, 0}, stone()),
    }));
    VWB_EXPECT_EQ(2ULL, delta.revision);
    const WorldDeltaPinnedSnapshot after = store.pin();
    VWB_EXPECT_EQ(2ULL, after.revision());
    VWB_EXPECT(after.typed_effective_value_at({-16, 0, 0}).has_value());
    VWB_EXPECT_EQ(1ULL, typed_pin.revision());
    VWB_EXPECT(!typed_pin.effective_value_at({0, 0, 0}));
}

VWB_TEST(world_delta_store_typed_replacement_invalidates_the_union_of_old_and_new_owner_cells) {
    WorldDeltaStore store;
    static_cast<void>(store.admit_typed_state(typed_admission("typed:first", 0,
        {typed_durable({0, 0, 0})}, {typed_overlay({16, 0, 0})})));
    NativeTypedWorldStateRecord changed = typed_durable({0, 0, 0});
    changed.state.light.sky = 2;
    const WorldDeltaCommitReceipt replaced = store.admit_typed_state(typed_admission("typed:replace", 1,
        {changed, typed_durable({32, 0, 0})}));
    VWB_EXPECT_EQ(WorldDeltaCommitStatus::committed, replaced.status);
    VWB_EXPECT_EQ(2ULL, replaced.revision);
    // Owners 0, 1, and 2 along X produce the complete x=-1..3 halo.
    VWB_EXPECT_EQ(45U, replaced.affected_sections.size());
    for (std::int32_t z = -1; z <= 1; ++z) {
        for (std::int32_t y = -1; y <= 1; ++y) {
            for (std::int32_t x = -1; x <= 3; ++x) {
                VWB_EXPECT(std::find(replaced.affected_sections.begin(), replaced.affected_sections.end(),
                    WorldDeltaSectionKey{{x, y, z}}) != replaced.affected_sections.end());
            }
        }
    }
    const WorldDeltaPinnedSnapshot pin = store.pin();
    VWB_EXPECT(!pin.typed_transient_overlay_at({16, 0, 0}));
    VWB_EXPECT_EQ(2, static_cast<int>(pin.typed_durable_value_at({0, 0, 0})->light.sky));
    VWB_EXPECT(pin.typed_durable_value_at({32, 0, 0}).has_value());
}

VWB_TEST(world_delta_store_typed_admission_is_idempotent_and_transaction_kind_strict) {
    WorldDeltaStore store;
    const WorldTypedStateAdmission first = typed_admission("shared:id", 0, {typed_durable({0, 0, 0})});
    const WorldDeltaCommitReceipt committed = store.admit_typed_state(first);
    VWB_EXPECT_EQ(WorldDeltaCommitStatus::committed, committed.status);
    const WorldDeltaCommitReceipt replay = store.admit_typed_state(first);
    VWB_EXPECT_EQ(WorldDeltaCommitStatus::idempotent_replay, replay.status);
    VWB_EXPECT_EQ(1ULL, replay.revision);
    expect_rejection(WorldDeltaRejectReason::transaction_conflict, transaction("shared:id", 1, {
        set(WorldDeltaNamespace::terrain_override, {0, 0, 0}, stone()),
    }), store);
    expect_typed_rejection(WorldDeltaRejectReason::transaction_conflict,
        typed_admission("shared:id", 1, {typed_durable({1, 0, 0})}), store);
    NativeTypedWorldStateRecord different_value = typed_durable({0, 0, 0});
    different_value.state.metadata = NativeValue::object({
        {"door", NativeValue::object({{"locked", NativeValue::boolean(true)}})},
    });
    different_value.state.block_id = NativeBlockIdentity::create("door.oak.locked");
    // The WTY2 journal must distinguish recursive metadata/block identity;
    // otherwise a same-ID replay could hide a materially different v2 state.
    expect_typed_rejection(WorldDeltaRejectReason::transaction_conflict,
        typed_admission("shared:id", 1, {different_value}), store);
    expect_typed_rejection(WorldDeltaRejectReason::invalid_transaction,
        typed_admission("", 1, {typed_durable({1, 0, 0})}), store);
    expect_typed_rejection(WorldDeltaRejectReason::invalid_transaction,
        typed_admission(std::string("typed\0nul", 9), 1, {typed_durable({1, 0, 0})}), store);
    expect_typed_rejection(WorldDeltaRejectReason::revision_conflict,
        typed_admission("typed:stale", 0, {typed_durable({1, 0, 0})}), store);
    VWB_EXPECT_EQ(1ULL, store.revision());
}

VWB_TEST(world_delta_store_rejects_typed_capacity_and_malformed_overlay_without_publishing) {
    WorldDeltaStore store({1, 8});
    expect_typed_rejection(WorldDeltaRejectReason::capacity_exceeded,
        typed_admission("typed:over-capacity", 0, {typed_durable({0, 0, 0})}, {typed_overlay({1, 0, 0})}), store);
    VWB_EXPECT_EQ(0ULL, store.revision());
    VWB_EXPECT(store.pin().typed_durable_snapshot().records().empty());

    NativeTypedWorldStateRecord malformed = typed_overlay({0, 0, 0});
    malformed.persistence = NativeTypedWorldStatePersistence::durable;
    expect_typed_rejection(WorldDeltaRejectReason::invalid_transaction,
        {"typed:malformed", 0, NativeTypedWorldStateSnapshot::create({}), {malformed}}, store);
    VWB_EXPECT_EQ(0ULL, store.revision());
    VWB_EXPECT(store.pin().typed_transient_overlays().empty());
}

VWB_TEST(world_delta_store_typed_admission_covers_no_change_search_order_capacity_and_overflow) {
    WorldDeltaStore store;
    const std::vector<NativeTypedWorldStateRecord> ordered = {
        typed_durable({0, 0, 1}), typed_durable({0, 2, 0}), typed_durable({0, 0, 0}),
    };
    static_cast<void>(store.admit_typed_state(typed_admission("typed:ordered", 0, ordered)));
    const WorldDeltaPinnedSnapshot pin = store.pin();
    // The missing middle-Y lookup visits both y-order sides; the missing Z
    // lookup exercises the primary z comparison and end boundary.
    VWB_EXPECT(!pin.typed_durable_value_at({0, 1, 0}));
    VWB_EXPECT(!pin.typed_durable_value_at({0, 0, 2}));
    const WorldDeltaCommitReceipt no_change = store.admit_typed_state(
        typed_admission("typed:no-change", 1, ordered));
    VWB_EXPECT_EQ(WorldDeltaCommitStatus::no_change, no_change.status);
    VWB_EXPECT(no_change.affected_sections.empty());

    // These replacements force both comparisons in the old/new merge: first
    // old<new, then new<old. They must still publish only whole halos.
    static_cast<void>(store.admit_typed_state(typed_admission("typed:before-less", 1,
        {typed_durable({32, 0, 0})})));
    static_cast<void>(store.admit_typed_state(typed_admission("typed:after-less", 2,
        {typed_durable({0, 0, 0})})));

    WorldDeltaStore combined_capacity({2, 8});
    static_cast<void>(combined_capacity.commit(transaction("delta:capacity-base", 0, {
        set(WorldDeltaNamespace::terrain_override, {0, 0, 0}, stone()),
    })));
    expect_typed_rejection(WorldDeltaRejectReason::capacity_exceeded,
        typed_admission("typed:combined-capacity", 1,
            {typed_durable({1, 0, 0}), typed_durable({2, 0, 0})}), combined_capacity);
    VWB_EXPECT_EQ(1ULL, combined_capacity.revision());

    WorldDeltaStore transaction_capacity({8, 1});
    static_cast<void>(transaction_capacity.admit_typed_state(
        typed_admission("typed:journal-base", 0, {typed_durable({0, 0, 0})})));
    expect_typed_rejection(WorldDeltaRejectReason::capacity_exceeded,
        typed_admission("typed:journal-full", 1, {typed_durable({1, 0, 0})}), transaction_capacity);

    WorldDeltaStore overflow({8, 8, std::numeric_limits<std::uint64_t>::max()});
    expect_typed_rejection(WorldDeltaRejectReason::capacity_exceeded,
        typed_admission("typed:max-revision", std::numeric_limits<std::uint64_t>::max(),
            {typed_durable({0, 0, 0})}), overflow);
    VWB_EXPECT(overflow.pin().typed_durable_snapshot().records().empty());
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
    VWB_EXPECT_EQ(54U, receipt.affected_sections.size());
    VWB_EXPECT((receipt.affected_sections.front().section == CellCoord{-2, -2, -3}));
    VWB_EXPECT((receipt.affected_sections.back().section == CellCoord{2, 1, 2}));
    VWB_EXPECT(std::find(receipt.affected_sections.begin(), receipt.affected_sections.end(),
        WorldDeltaSectionKey{{-1, -1, -2}}) != receipt.affected_sections.end());
    VWB_EXPECT(std::find(receipt.affected_sections.begin(), receipt.affected_sections.end(),
        WorldDeltaSectionKey{{1, 0, 1}}) != receipt.affected_sections.end());

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
    VWB_EXPECT_EQ(27U, clear_receipt.affected_sections.size());
    VWB_EXPECT((clear_receipt.affected_sections.front().section == CellCoord{-1, -1, -1}));
    VWB_EXPECT((clear_receipt.affected_sections.back().section == CellCoord{1, 1, 1}));
    const WorldDeltaPinnedSnapshot restored = store.pin();
    VWB_EXPECT(!restored.value_at(WorldDeltaNamespace::scene_overlay, target));
    VWB_EXPECT_EQ(stone(), restored.effective_value_at(target)->state);
}

VWB_TEST(world_delta_store_commits_lava_as_a_typed_delta_state) {
    WorldDeltaStore store;
    const CellCoord target{-16, -1, 16};
    const auto receipt = store.commit(transaction("delta:lava", 0, {
        set(WorldDeltaNamespace::terrain_override, target, lava()),
    }));
    VWB_EXPECT_EQ(WorldDeltaCommitStatus::committed, receipt.status);
    VWB_EXPECT_EQ(1ULL, receipt.revision);
    const auto value = store.pin().effective_value_at(target);
    VWB_EXPECT(value.has_value());
    VWB_EXPECT_EQ(lava(), value->state);
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

VWB_TEST(world_delta_store_validates_all_typed_state_and_transaction_boundaries) {
    WorldDeltaStore store;
    const CellCoord target{0, 0, 0};
    expect_rejection(WorldDeltaRejectReason::invalid_transaction, transaction("delta:missing-state", 0, {
        {WorldDeltaNamespace::terrain_override, target, WorldDeltaOperationKind::set, std::nullopt},
    }), store);
    expect_rejection(WorldDeltaRejectReason::invalid_transaction, transaction("delta:no-ops", 0, {}), store);
    expect_rejection(WorldDeltaRejectReason::invalid_transaction, transaction(std::string("delta\0nul", 9), 0, {
        set(WorldDeltaNamespace::terrain_override, target, stone()),
    }), store);

    std::vector<WorldDeltaState> invalid_states;
    WorldDeltaState invalid = stone(); invalid.density = std::numeric_limits<double>::infinity(); invalid_states.push_back(invalid);
    invalid = stone(); invalid.material = static_cast<TerrainMaterialId>(255U); invalid_states.push_back(invalid);
    invalid = stone(); invalid.resolved_biome = static_cast<TerrainBiomeId>(255U); invalid_states.push_back(invalid);
    invalid = stone(); invalid.fluid = static_cast<TerrainFluidId>(255U); invalid_states.push_back(invalid);
    invalid = stone(); invalid.material = TerrainMaterialId::air; invalid_states.push_back(invalid);
    invalid = stone(); invalid.density = -1.0; invalid.solid = false; invalid.material = TerrainMaterialId::dirt; invalid_states.push_back(invalid);
    invalid = stone(); invalid.density = -1.0; invalid.solid = false; invalid.material = TerrainMaterialId::air;
    invalid.fluid = TerrainFluidId::water; invalid_states.push_back(invalid);
    invalid = lava(); invalid.material = TerrainMaterialId::water; invalid_states.push_back(invalid);
    invalid = water(); invalid.material = TerrainMaterialId::lava; invalid_states.push_back(invalid);
    for (std::size_t index = 0; index < invalid_states.size(); ++index) {
        expect_rejection(WorldDeltaRejectReason::invalid_transaction, transaction("delta:bad-state:" + std::to_string(index), 0, {
            set(WorldDeltaNamespace::terrain_override, target, invalid_states[index]),
        }), store);
    }
    VWB_EXPECT_EQ(0ULL, store.revision());
}

VWB_TEST(world_delta_store_value_types_have_strict_field_equality) {
    const WorldDeltaState base = stone();
    VWB_EXPECT(base == base);
    for (unsigned field = 0; field < 5U; ++field) {
        WorldDeltaState changed = base;
        if (field == 0U) changed.density += 1.0;
        if (field == 1U) changed.solid = false;
        if (field == 2U) changed.material = TerrainMaterialId::dirt;
        if (field == 3U) changed.resolved_biome = TerrainBiomeId::forest;
        if (field == 4U) changed.fluid = TerrainFluidId::water;
        VWB_EXPECT(!(base == changed));
    }
    const WorldDeltaRecord record{WorldDeltaNamespace::terrain_override, {1, 2, 3}, base, 5};
    VWB_EXPECT(record == record);
    for (unsigned field = 0; field < 4U; ++field) {
        WorldDeltaRecord changed = record;
        if (field == 0U) changed.name_space = WorldDeltaNamespace::scene_overlay;
        if (field == 1U) ++changed.coordinate.x;
        if (field == 2U) changed.state = air();
        if (field == 3U) ++changed.revision;
        VWB_EXPECT(!(record == changed));
    }
    const WorldDeltaSectionKey section{{1, 2, 3}};
    VWB_EXPECT(section == section);
    VWB_EXPECT(!(section == WorldDeltaSectionKey{{1, 2, 4}}));
    const WorldDeltaCommitReceipt receipt{WorldDeltaCommitStatus::committed, "delta:receipt", 5, {section}};
    VWB_EXPECT(receipt == receipt);
    for (unsigned field = 0; field < 4U; ++field) {
        WorldDeltaCommitReceipt changed = receipt;
        if (field == 0U) changed.status = WorldDeltaCommitStatus::no_change;
        if (field == 1U) changed.transaction_id += ":other";
        if (field == 2U) ++changed.revision;
        if (field == 3U) changed.affected_sections.push_back({{9, 9, 9}});
        VWB_EXPECT(!(receipt == changed));
    }
    const WorldDeltaRejected unknown(static_cast<WorldDeltaRejectReason>(255U));
    VWB_EXPECT_EQ(static_cast<WorldDeltaRejectReason>(255U), unknown.reason());
    VWB_EXPECT_EQ(std::string("unknown world delta rejection"), std::string(unknown.what()));
}

VWB_TEST(world_delta_store_uses_stable_namespace_cell_and_section_ordering) {
    WorldDeltaStore store;
    const auto receipt = store.commit(transaction("delta:ordering", 0, {
        set(WorldDeltaNamespace::scene_overlay, {16, 16, 0}, air()),
        set(WorldDeltaNamespace::terrain_override, {16, 0, 16}, stone()),
        set(WorldDeltaNamespace::terrain_override, {16, 0, 0}, water()),
        set(WorldDeltaNamespace::terrain_override, {16, 16, 0}, stone()),
        set(WorldDeltaNamespace::terrain_override, {0, 0, 0}, air()),
    }));
    // The four owner sections have an asymmetric overlap: z=-1/0/1 each
    // contribute 15 keys, while the z=2 halo slice contributes 9 (54 total).
    VWB_EXPECT_EQ(54U, receipt.affected_sections.size());
    VWB_EXPECT((receipt.affected_sections.front().section == CellCoord{-1, -1, -1}));
    VWB_EXPECT((receipt.affected_sections.back().section == CellCoord{2, 1, 2}));
    const auto records = store.pin().records();
    VWB_EXPECT_EQ(5U, records.size());
    VWB_EXPECT_EQ(WorldDeltaNamespace::terrain_override, records[0].name_space);
    VWB_EXPECT((records[0].coordinate == CellCoord{0, 0, 0}));
    VWB_EXPECT((records[1].coordinate == CellCoord{16, 0, 0}));
    VWB_EXPECT((records[2].coordinate == CellCoord{16, 16, 0}));
    VWB_EXPECT_EQ(WorldDeltaNamespace::terrain_override, records[2].name_space);
    VWB_EXPECT((records[3].coordinate == CellCoord{16, 16, 0}));
    VWB_EXPECT_EQ(WorldDeltaNamespace::scene_overlay, records[3].name_space);
    VWB_EXPECT((records[4].coordinate == CellCoord{16, 0, 16}));
    VWB_EXPECT_EQ(WorldDeltaNamespace::terrain_override, records[4].name_space);
}

VWB_TEST(world_delta_store_invalidates_the_complete_negative_boundary_neighborhood_in_zyx_order) {
    WorldDeltaStore store;
    const auto receipt = store.commit(transaction("delta:negative-boundary", 0, {
        set(WorldDeltaNamespace::terrain_override, {-16, -16, -16}, stone()),
    }));
    VWB_EXPECT_EQ(27U, receipt.affected_sections.size());
    VWB_EXPECT((receipt.affected_sections.front().section == CellCoord{-2, -2, -2}));
    VWB_EXPECT((receipt.affected_sections.back().section == CellCoord{0, 0, 0}));
    const WorldDeltaSectionKey owner{{-1, -1, -1}};
    VWB_EXPECT(std::find(receipt.affected_sections.begin(), receipt.affected_sections.end(), owner)
        != receipt.affected_sections.end());
    for (std::int32_t z = -2; z <= 0; ++z) {
        for (std::int32_t y = -2; y <= 0; ++y) {
            for (std::int32_t x = -2; x <= 0; ++x) {
                const WorldDeltaSectionKey expected{{x, y, z}};
                VWB_EXPECT(std::find(receipt.affected_sections.begin(), receipt.affected_sections.end(), expected)
                    != receipt.affected_sections.end());
            }
        }
    }
    for (std::size_t index = 1; index < receipt.affected_sections.size(); ++index) {
        const CellCoord before = receipt.affected_sections[index - 1U].section;
        const CellCoord after = receipt.affected_sections[index].section;
        VWB_EXPECT(before.z < after.z || (before.z == after.z && (before.y < after.y
            || (before.y == after.y && before.x < after.x))));
    }
}

VWB_TEST(world_delta_store_imported_max_revision_refuses_an_overflowing_commit) {
    WorldDeltaStore store({1, 1, std::numeric_limits<std::uint64_t>::max()});
    VWB_EXPECT_EQ(std::numeric_limits<std::uint64_t>::max(), store.pin().revision());
    expect_rejection(WorldDeltaRejectReason::capacity_exceeded,
        transaction("delta:max-revision", std::numeric_limits<std::uint64_t>::max(), {
            set(WorldDeltaNamespace::terrain_override, {0, 0, 0}, stone()),
        }), store);
    VWB_EXPECT(store.pin().records().empty());
}

} // namespace voxel::world_backend::tests
