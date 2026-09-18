#include "test_harness.hpp"

#include "../core/native_typed_world_state_snapshot.hpp"

#include <vector>

using namespace voxel::world_backend;

namespace {

NativeCellState durable_air(const CellCoord cell) {
    NativeCellStateInput input;
    input.cell = cell;
    input.material = TerrainMaterialId::air;
    input.biome = TerrainBiomeId::underground_air;
    input.solid = false;
    input.density = -1.35;
    input.fluid = TerrainFluidId::none;
    input.generated = false;
    input.edited = true;
    return make_native_cell_state(input);
}

NativeCellState overlay_air(const CellCoord cell) {
    NativeCellStateInput input;
    input.cell = cell;
    input.material = TerrainMaterialId::air;
    input.biome = TerrainBiomeId::underground_air;
    input.solid = false;
    input.density = -1.35;
    input.fluid = TerrainFluidId::none;
    input.generated = false;
    input.edited = true;
    return make_native_cell_state(input, NativeCellStateNamespace::scene_overlay);
}

NativeTypedWorldStateRecord durable_record(const CellCoord cell) {
    return {
        NativeCellStateNamespace::durable_terrain,
        NativeTypedWorldStatePersistence::durable,
        durable_air(cell),
    };
}

NativeTypedWorldStateRecord overlay_record(const CellCoord cell) {
    return {
        NativeCellStateNamespace::scene_overlay,
        NativeTypedWorldStatePersistence::transient,
        overlay_air(cell),
    };
}

} // namespace

VWB_TEST(native_typed_world_state_snapshot_canonicalizes_durable_records_z_y_x) {
    const NativeTypedWorldStateSnapshot snapshot = NativeTypedWorldStateSnapshot::create({
        durable_record({4, 0, 1}), durable_record({-8, -2, -1}), durable_record({5, -2, -1}),
    });
    VWB_EXPECT_EQ(3U, snapshot.records().size());
    VWB_EXPECT((snapshot.records()[0].state.cell == CellCoord{-8, -2, -1}));
    VWB_EXPECT((snapshot.records()[1].state.cell == CellCoord{5, -2, -1}));
    VWB_EXPECT((snapshot.records()[2].state.cell == CellCoord{4, 0, 1}));

    const NativeTypedWorldStateSnapshot same = NativeTypedWorldStateSnapshot::create({
        durable_record({5, -2, -1}), durable_record({4, 0, 1}), durable_record({-8, -2, -1}),
    });
    VWB_EXPECT(snapshot == same);
}

VWB_TEST(native_typed_world_state_snapshot_rejects_overlay_generated_and_duplicate_persistence) {
    VWB_EXPECT_THROW(NativeCellStateRejected, NativeTypedWorldStateSnapshot::create({overlay_record({0, 0, 0})}));
    NativeTypedWorldStateRecord transient_durable = durable_record({0, 1, 0});
    transient_durable.persistence = NativeTypedWorldStatePersistence::transient;
    VWB_EXPECT_THROW(NativeCellStateRejected, NativeTypedWorldStateSnapshot::create({transient_durable}));
    NativeTypedWorldStateRecord generated = durable_record({0, 0, 0});
    generated.state.generated = true;
    generated.state.edited = false;
    VWB_EXPECT_THROW(NativeCellStateRejected, NativeTypedWorldStateSnapshot::create({generated}));
    NativeTypedWorldStateRecord missing_edited = durable_record({0, 0, 1});
    missing_edited.state.edited = false;
    VWB_EXPECT_THROW(NativeCellStateRejected, NativeTypedWorldStateSnapshot::create({missing_edited}));
    VWB_EXPECT_THROW(NativeCellStateRejected, NativeTypedWorldStateSnapshot::create({
        durable_record({-16, -16, -16}), durable_record({-16, -16, -16}),
    }));
    NativeTypedWorldStateRecord invalid_edit_reason = durable_record({1, 2, 3});
    invalid_edit_reason.state.edit_reason = std::string("bad\xC0\x80", 5);
    VWB_EXPECT_THROW(NativeCellStateRejected, NativeTypedWorldStateSnapshot::create({invalid_edit_reason}));
    NativeTypedWorldStateRecord invalid_metadata = durable_record({2, 3, 4});
    invalid_metadata.state.metadata = NativeValue::null();
    VWB_EXPECT_THROW(NativeCellStateRejected, NativeTypedWorldStateSnapshot::create({invalid_metadata}));
}

VWB_TEST(native_typed_world_state_record_equality_includes_namespace_policy_and_full_cell_state) {
    const NativeTypedWorldStateRecord original = durable_record({1, 2, 3});
    NativeTypedWorldStateRecord changed = original;
    VWB_EXPECT(original == changed);
    changed.name_space = NativeCellStateNamespace::scene_overlay;
    VWB_EXPECT(!(original == changed));
    changed = original;
    changed.persistence = NativeTypedWorldStatePersistence::transient;
    VWB_EXPECT(!(original == changed));
    changed = original;
    changed.state.light.block = 1;
    VWB_EXPECT(!(original == changed));
}

VWB_TEST(native_typed_world_state_snapshot_rejects_forged_section_local_address_at_negative_boundaries) {
    NativeTypedWorldStateRecord forged = durable_record({-16, -17, -1});
    VWB_EXPECT((forged.state.section == CellCoord{-1, -2, -1}));
    VWB_EXPECT((forged.state.local_cell == CellCoord{0, 15, 15}));
    forged.state.local_cell.y = 0;
    VWB_EXPECT_THROW(NativeCellStateRejected, NativeTypedWorldStateSnapshot::create({forged}));
}

VWB_TEST(native_typed_world_state_store_excludes_transient_overlays_from_durable_snapshot) {
    NativeTypedWorldStateStore store;
    store.admit_durable_snapshot(NativeTypedWorldStateSnapshot::create({durable_record({1, 2, 3})}));
    store.replace_transient_overlays({overlay_record({1, 2, 3}), overlay_record({-16, 0, 16})});
    VWB_EXPECT_EQ(1U, store.durable_snapshot().records().size());
    VWB_EXPECT_EQ(2U, store.transient_overlays().size());
    VWB_EXPECT(store.durable_value_at({1, 2, 3}).has_value());
    VWB_EXPECT(store.transient_overlay_at({1, 2, 3}).has_value());
    VWB_EXPECT(!store.durable_value_at({-16, 0, 16}).has_value());

    VWB_EXPECT_THROW(NativeCellStateRejected, store.replace_transient_overlays({durable_record({4, 5, 6})}));
    VWB_EXPECT_EQ(2U, store.transient_overlays().size());
    NativeTypedWorldStateRecord durable_overlay = overlay_record({4, 5, 6});
    durable_overlay.persistence = NativeTypedWorldStatePersistence::durable;
    VWB_EXPECT_THROW(NativeCellStateRejected, store.replace_transient_overlays({durable_overlay}));
    VWB_EXPECT_EQ(2U, store.transient_overlays().size());
}

VWB_TEST(native_typed_world_state_store_lookups_cover_z_y_x_and_missing_boundaries) {
    NativeTypedWorldStateStore store;
    store.admit_durable_records({
        durable_record({0, 0, 0}), durable_record({0, 2, 0}), durable_record({0, 0, 1}),
    });
    VWB_EXPECT(store.durable_value_at({0, 0, 0}).has_value());
    // Same z but between two y values: lower_bound finds a nonmatching entry.
    VWB_EXPECT(!store.durable_value_at({0, 1, 0}).has_value());
    // Different z exercises the primary ordering comparison, including end.
    VWB_EXPECT(store.durable_value_at({0, 0, 1}).has_value());
    VWB_EXPECT(!store.durable_value_at({0, 0, 2}).has_value());
}

VWB_TEST(native_typed_world_state_store_preserves_prior_snapshot_when_admission_is_rejected) {
    NativeTypedWorldStateStore store;
    const NativeTypedWorldStateSnapshot accepted = NativeTypedWorldStateSnapshot::create({durable_record({7, 8, 9})});
    store.admit_durable_snapshot(accepted);

    NativeTypedWorldStateRecord malformed = durable_record({-1, -16, -17});
    malformed.state.section.z = 0;
    // This models a future parser's raw typed batch: validation completes
    // before swap, so the accepted state remains published on rejection.
    VWB_EXPECT_THROW(NativeCellStateRejected, store.admit_durable_records({malformed}));
    VWB_EXPECT(store.durable_snapshot() == accepted);
    VWB_EXPECT(store.durable_value_at({7, 8, 9}).has_value());
}

VWB_TEST(native_typed_world_state_snapshot_preserves_exact_typed_fields) {
    NativeTypedWorldStateRecord record = durable_record({-17, 31, 16});
    record.state.light = {15, 4};
    record.state.metadata = NativeValue::object({
        {"alpha", NativeValue::array({NativeValue::number(1.0), NativeValue::boolean(true)})},
        {"beta", NativeValue::object({{"nested", NativeValue::string("two")}})},
    });
    record.state.edit_reason = "player_dig";
    const NativeTypedWorldStateSnapshot snapshot = NativeTypedWorldStateSnapshot::create({record});
    const NativeCellState &state = snapshot.records()[0].state;
    VWB_EXPECT_EQ(15, static_cast<int>(state.light.sky));
    VWB_EXPECT_EQ(4, static_cast<int>(state.light.block));
    VWB_EXPECT_EQ(2U, state.metadata.as_object().size());
    VWB_EXPECT_EQ(NativeValueKind::array, state.metadata.as_object()[0].second.kind());
    VWB_EXPECT_EQ(std::string("player_dig"), *state.edit_reason);
    VWB_EXPECT((state.section == CellCoord{-2, 1, 1}));
    VWB_EXPECT((state.local_cell == CellCoord{15, 15, 0}));
}
