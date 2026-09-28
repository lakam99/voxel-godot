#include "test_harness.hpp"

#include "../core/world_delta_store.hpp"

#include <algorithm>
#include <array>
#include <cstdint>
#include <limits>
#include <memory>
#include <stdexcept>
#include <string>
#include <type_traits>
#include <vector>

namespace voxel::world_backend::tests {
namespace {

enum class WorldDeltaNamespace : std::uint8_t {
    terrain_override = 1,
    scene_overlay = 2,
};

enum class WorldDeltaOperationKind : std::uint8_t {
    set = 1,
    clear = 2,
};

struct WorldDeltaState {
    double density = -1.35;
    bool solid = false;
    TerrainMaterialId material = TerrainMaterialId::air;
    TerrainBiomeId resolved_biome = TerrainBiomeId::underground_air;
    TerrainFluidId fluid = TerrainFluidId::none;

    bool operator==(const WorldDeltaState &other) const noexcept {
        return density == other.density && solid == other.solid && material == other.material
            && resolved_biome == other.resolved_biome && fluid == other.fluid;
    }
};

static_assert(sizeof(BorrowedTypedCellCursor) <= 256U);
static_assert(std::is_trivially_copyable_v<BorrowedTypedCellCursor>);

NativeCellState typed_from_legacy(const WorldDeltaState &state, const CellCoord cell,
    const WorldDeltaNamespace name_space) {
    NativeCellStateInput input;
    input.cell = cell;
    input.density = state.density;
    input.solid = state.solid;
    input.material = state.material;
    input.biome = state.resolved_biome;
    input.fluid = state.fluid;
    input.light = {static_cast<std::uint8_t>(state.solid ? 0 : 15), 0};
    input.metadata = NativeValue::object({});
    input.block_id = NativeBlockIdentity::create("terrain.test");
    input.edit_reason = "test";
    input.generated = false;
    input.edited = true;
    return make_native_cell_state(input, name_space == WorldDeltaNamespace::terrain_override
        ? NativeCellStateNamespace::durable_terrain : NativeCellStateNamespace::scene_overlay);
}

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

WorldTypedCellOperation set(const WorldDeltaNamespace name_space, const CellCoord coordinate, const WorldDeltaState state) {
    return {name_space == WorldDeltaNamespace::terrain_override
            ? NativeCellStateNamespace::durable_terrain : NativeCellStateNamespace::scene_overlay,
        coordinate, WorldTypedCellOperationKind::set, typed_from_legacy(state, coordinate, name_space)};
}

WorldTypedCellOperation clear(const WorldDeltaNamespace name_space, const CellCoord coordinate) {
    return {name_space == WorldDeltaNamespace::terrain_override
            ? NativeCellStateNamespace::durable_terrain : NativeCellStateNamespace::scene_overlay,
        coordinate, WorldTypedCellOperationKind::clear, std::nullopt};
}

WorldTypedCellTransaction transaction(const std::string &id, const std::uint64_t expected,
    std::vector<WorldTypedCellOperation> operations) {
    return {id, expected, std::move(operations)};
}

void expect_rejection(const WorldDeltaRejectReason expected, const WorldTypedCellTransaction &value,
    WorldDeltaStore &store) {
    try {
        static_cast<void>(store.commit_typed_cells(value));
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
    input.block_id = NativeBlockIdentity::create("terrain.air.edited");
    input.edit_reason = "test";
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
    input.edit_reason = "player_place";
    input.generated = false;
    input.edited = true;
    return {NativeCellStateNamespace::durable_terrain, NativeTypedWorldStatePersistence::durable,
        make_native_cell_state(input, NativeCellStateNamespace::durable_terrain)};
}

NativeTypedWorldStateRecord typed_overlay(const CellCoord cell) {
    return {NativeCellStateNamespace::scene_overlay, NativeTypedWorldStatePersistence::transient,
        typed_air(cell, NativeCellStateNamespace::scene_overlay)};
}

NativeTypedWorldStateRecord typed_overlay_without_persistence_metadata(const CellCoord cell) {
    NativeTypedWorldStateRecord record = typed_overlay(cell);
    // Scene overlays are transient typed state.  Unlike durable terrain v2
    // records, they do not need a durable block identity or edit reason.
    record.state.block_id.reset();
    record.state.edit_reason.reset();
    return record;
}

WorldTypedStateAdmission typed_admission(const std::string &id, const std::uint64_t expected,
    std::vector<NativeTypedWorldStateRecord> durable, std::vector<NativeTypedWorldStateRecord> overlays = {}) {
    return {id, expected, NativeTypedWorldStateSnapshot::create(std::move(durable)), std::move(overlays)};
}

BorrowedTypedCellCursor::Status finish_borrowed_typed_cell(
    const WorldDeltaStore &store, BorrowedTypedCellCursor &cursor,
    const CellCoord cell, const std::uint64_t token) {
    constexpr std::array<std::uint32_t, 4> offers{1U, 0U, 2U, 64U};
    for (std::size_t call = 0; call < 100000U; ++call) {
        const auto step = store.advance_borrowed_typed_cell(cursor, cell, token,
            offers[call % offers.size()]);
        VWB_EXPECT(step.consumed_ops <= offers[call % offers.size()]);
        VWB_EXPECT(step.consumed_ops <= 64U);
        VWB_EXPECT(step.status != BorrowedTypedCellCursor::Status::failed);
        if (step.status == BorrowedTypedCellCursor::Status::ready_present
            || step.status == BorrowedTypedCellCursor::Status::ready_absent
            || step.status == BorrowedTypedCellCursor::Status::source_changed)
            return step.status;
    }
    fail("borrowed typed cell bounded progress", __FILE__, __LINE__, "cursor did not finish");
    return BorrowedTypedCellCursor::Status::failed;
}

void expect_borrowed_scalar_header(const BorrowedTypedCellHeader &header,
    const NativeCellState &expected, const BorrowedTypedCellHeader::SourceLayer layer) {
    VWB_EXPECT(header.cell == expected.cell);
    VWB_EXPECT(header.section == expected.section);
    VWB_EXPECT(header.local_cell == expected.local_cell);
    VWB_EXPECT_EQ(layer, header.source_layer);
    VWB_EXPECT_EQ(expected.material, header.material);
    VWB_EXPECT_EQ(expected.biome, header.biome);
    VWB_EXPECT_EQ(expected.solid, header.solid);
    VWB_EXPECT_EQ(expected.density, header.density);
    VWB_EXPECT_EQ(expected.fluid, header.fluid);
    VWB_EXPECT_EQ(expected.light, header.light);
    VWB_EXPECT_EQ(expected.generated, header.generated);
    VWB_EXPECT_EQ(expected.edited, header.edited);
    VWB_EXPECT_EQ(expected.block_id.has_value(), header.has_block_id);
    VWB_EXPECT_EQ(expected.edit_reason.has_value(), header.has_edit_reason);
}

VWB_TEST(world_delta_store_borrowed_typed_cell_scalar_header_matches_pin_layers_and_absence) {
    WorldDeltaStore store;
    const CellCoord overlap{-16, -1, 16};
    const CellCoord durable_only{15, 0, 15};
    const CellCoord absent{-17, 0, 16};
    const auto admitted = store.admit_typed_state(typed_admission("a2a:layers", 0U,
        {typed_stone(overlap), typed_durable(durable_only)},
        {typed_overlay_without_persistence_metadata(overlap)}));
    VWB_EXPECT_EQ(WorldDeltaCommitStatus::committed, admitted.status);
    constexpr std::uint64_t token = 0x41326101U;

    BorrowedTypedCellCursor overlay_cursor;
    const auto zero = store.advance_borrowed_typed_cell(overlay_cursor, overlap, token, 0U);
    VWB_EXPECT_EQ(BorrowedTypedCellCursor::Status::idle, zero.status);
    VWB_EXPECT_EQ(0U, zero.consumed_ops);
    VWB_EXPECT(!store.borrowed_typed_cell_header(overlay_cursor, token));
    VWB_EXPECT_EQ(BorrowedTypedCellCursor::Status::ready_present,
        finish_borrowed_typed_cell(store, overlay_cursor, overlap, token));
    const auto overlay_header = store.borrowed_typed_cell_header(overlay_cursor, token);
    VWB_EXPECT(overlay_header.has_value());
    expect_borrowed_scalar_header(*overlay_header,
        store.pin().effective_typed_cell_at(overlap).value(),
        BorrowedTypedCellHeader::SourceLayer::overlay);
    VWB_EXPECT(!overlay_header->has_block_id);
    VWB_EXPECT(!overlay_header->has_edit_reason);
    const auto repeated = store.advance_borrowed_typed_cell(overlay_cursor, overlap, token, 64U);
    VWB_EXPECT_EQ(BorrowedTypedCellCursor::Status::ready_present, repeated.status);
    VWB_EXPECT_EQ(0U, repeated.consumed_ops);

    BorrowedTypedCellCursor durable_cursor;
    VWB_EXPECT_EQ(BorrowedTypedCellCursor::Status::ready_present,
        finish_borrowed_typed_cell(store, durable_cursor, durable_only, token));
    const auto durable_header = store.borrowed_typed_cell_header(durable_cursor, token);
    VWB_EXPECT(durable_header.has_value());
    expect_borrowed_scalar_header(*durable_header,
        store.pin().effective_typed_cell_at(durable_only).value(),
        BorrowedTypedCellHeader::SourceLayer::durable);

    BorrowedTypedCellCursor absent_cursor;
    VWB_EXPECT(!store.pin().effective_typed_cell_at(absent));
    VWB_EXPECT_EQ(BorrowedTypedCellCursor::Status::ready_absent,
        finish_borrowed_typed_cell(store, absent_cursor, absent, token));
    VWB_EXPECT(!store.borrowed_typed_cell_header(absent_cursor, token));

    const auto cleared = store.commit_typed_cells(transaction("a2a:clear-overlay", 1U,
        {clear(WorldDeltaNamespace::scene_overlay, overlap)}));
    VWB_EXPECT_EQ(WorldDeltaCommitStatus::committed, cleared.status);
    VWB_EXPECT(!store.borrowed_typed_cell_header(overlay_cursor, token));
    overlay_cursor.reset();
    VWB_EXPECT_EQ(BorrowedTypedCellCursor::Status::ready_present,
        finish_borrowed_typed_cell(store, overlay_cursor, overlap, token + 1U));
    const auto revealed = store.borrowed_typed_cell_header(overlay_cursor, token + 1U);
    VWB_EXPECT(revealed.has_value());
    expect_borrowed_scalar_header(*revealed,
        store.pin().effective_typed_cell_at(overlap).value(),
        BorrowedTypedCellHeader::SourceLayer::durable);
}

VWB_TEST(world_delta_store_borrowed_typed_cell_stales_on_mutation_and_token_change) {
    WorldDeltaStore store;
    const CellCoord cell{16, -16, -1};
    const auto admitted = store.admit_typed_state(typed_admission("a2a:stale", 0U,
        {typed_stone(cell)}));
    VWB_EXPECT_EQ(WorldDeltaCommitStatus::committed, admitted.status);
    BorrowedTypedCellCursor cursor;
    constexpr std::uint64_t token = 0x41326102U;
    const auto begun = store.advance_borrowed_typed_cell(cursor, cell, token, 1U);
    VWB_EXPECT_EQ(BorrowedTypedCellCursor::Status::pending, begun.status);
    VWB_EXPECT(begun.consumed_ops <= 1U);
    const auto changed = store.commit_typed_cells(transaction("a2a:mutate", 1U,
        {set(WorldDeltaNamespace::scene_overlay, cell, water())}));
    VWB_EXPECT_EQ(WorldDeltaCommitStatus::committed, changed.status);
    const auto stale = store.advance_borrowed_typed_cell(cursor, cell, token, 64U);
    VWB_EXPECT_EQ(BorrowedTypedCellCursor::Status::source_changed, stale.status);
    VWB_EXPECT(!store.borrowed_typed_cell_header(cursor, token));

    cursor.reset();
    const auto restarted = store.advance_borrowed_typed_cell(cursor, cell, token + 1U, 1U);
    VWB_EXPECT_EQ(BorrowedTypedCellCursor::Status::pending, restarted.status);
    const auto wrong_token = store.advance_borrowed_typed_cell(cursor, cell, token + 2U, 64U);
    VWB_EXPECT_EQ(BorrowedTypedCellCursor::Status::source_changed, wrong_token.status);
    VWB_EXPECT(!store.borrowed_typed_cell_header(cursor, token + 1U));

    cursor.reset();
    VWB_EXPECT_EQ(BorrowedTypedCellCursor::Status::ready_present,
        finish_borrowed_typed_cell(store, cursor, cell, token + 3U));
    const auto header = store.borrowed_typed_cell_header(cursor, token + 3U);
    VWB_EXPECT(header.has_value());
    expect_borrowed_scalar_header(*header,
        store.pin().effective_typed_cell_at(cell).value(),
        BorrowedTypedCellHeader::SourceLayer::overlay);
    VWB_EXPECT(!store.borrowed_typed_cell_header(cursor, token + 2U));
    cursor.reset();
    VWB_EXPECT_EQ(BorrowedTypedCellCursor::Status::idle, cursor.status());
    VWB_EXPECT(!store.borrowed_typed_cell_header(cursor, token + 3U));
}

VWB_TEST(world_delta_store_borrowed_typed_cell_rejects_unbound_token_and_changed_request) {
    WorldDeltaStore store;
    BorrowedTypedCellCursor cursor;
    const CellCoord first{-1, 0, 16};
    const CellCoord second{0, 0, 16};
    const auto invalid = store.advance_borrowed_typed_cell(cursor, first, 0U, 64U);
    VWB_EXPECT_EQ(BorrowedTypedCellCursor::Status::failed, invalid.status);
    VWB_EXPECT(!store.borrowed_typed_cell_header(cursor, 0U));
    cursor.reset();
    const auto begun = store.advance_borrowed_typed_cell(cursor, first, 51U, 1U);
    VWB_EXPECT_EQ(BorrowedTypedCellCursor::Status::pending, begun.status);
    VWB_EXPECT_EQ(1U, begun.consumed_ops);
    const auto different_cell = store.advance_borrowed_typed_cell(cursor, second, 51U, 64U);
    VWB_EXPECT_EQ(BorrowedTypedCellCursor::Status::source_changed, different_cell.status);
    VWB_EXPECT(!store.borrowed_typed_cell_header(cursor, 51U));
    cursor.reset();
    VWB_EXPECT_EQ(BorrowedTypedCellCursor::Status::ready_absent,
        finish_borrowed_typed_cell(store, cursor, second, 52U));
}

VWB_TEST(world_delta_store_borrowed_typed_cell_checks_full_coordinate_and_sorted_layer_misses) {
    WorldDeltaStore store;
    const auto admitted = store.admit_typed_state(typed_admission("a2a:lower-bound", 0U,
        {typed_stone({2, 1, 1}), typed_durable({4, 1, 1}), typed_stone({8, 1, 1})},
        {typed_overlay_without_persistence_metadata({1, 2, 2}),
            typed_overlay_without_persistence_metadata({5, 2, 2}),
            typed_overlay_without_persistence_metadata({9, 2, 2})}));
    VWB_EXPECT_EQ(WorldDeltaCommitStatus::committed, admitted.status);
    constexpr std::uint64_t token = 0x41326103U;

    // Each layer has a miss before, between, and after its three records.
    // The final two queries share a section and two coordinates with a real
    // record, so a section-only or XZ-only match would be a false positive.
    const std::array<CellCoord, 8> misses{{
        {0, 2, 2}, {3, 2, 2}, {10, 2, 2},
        {1, 1, 1}, {3, 1, 1}, {10, 1, 1},
        {4, 2, 1}, {5, 2, 3},
    }};
    for (const CellCoord cell : misses) {
        VWB_EXPECT(!store.pin().effective_typed_cell_at(cell));
        BorrowedTypedCellCursor cursor;
        VWB_EXPECT_EQ(BorrowedTypedCellCursor::Status::ready_absent,
            finish_borrowed_typed_cell(store, cursor, cell, token));
        VWB_EXPECT(!store.borrowed_typed_cell_header(cursor, token));
    }

    // Explicit typed air is a present edit. Its material and solidity match
    // an absent terrain cell, while the source layer and record presence do not.
    const CellCoord durable_air{4, 1, 1};
    BorrowedTypedCellCursor air_cursor;
    VWB_EXPECT_EQ(BorrowedTypedCellCursor::Status::ready_present,
        finish_borrowed_typed_cell(store, air_cursor, durable_air, token));
    const auto air_header = store.borrowed_typed_cell_header(air_cursor, token);
    VWB_EXPECT(air_header.has_value());
    expect_borrowed_scalar_header(*air_header,
        store.pin().effective_typed_cell_at(durable_air).value(),
        BorrowedTypedCellHeader::SourceLayer::durable);
    VWB_EXPECT_EQ(TerrainMaterialId::air, air_header->material);
    VWB_EXPECT(!air_header->solid);

    const CellCoord overlay_air{5, 2, 2};
    BorrowedTypedCellCursor overlay_cursor;
    VWB_EXPECT_EQ(BorrowedTypedCellCursor::Status::ready_present,
        finish_borrowed_typed_cell(store, overlay_cursor, overlay_air, token));
    const auto overlay_header = store.borrowed_typed_cell_header(overlay_cursor, token);
    VWB_EXPECT(overlay_header.has_value());
    expect_borrowed_scalar_header(*overlay_header,
        store.pin().effective_typed_cell_at(overlay_air).value(),
        BorrowedTypedCellHeader::SourceLayer::overlay);
    VWB_EXPECT_EQ(TerrainMaterialId::air, overlay_header->material);
    VWB_EXPECT(!overlay_header->solid);
}

VWB_TEST(world_delta_store_borrowed_typed_cell_finds_sorted_edges_across_negative_sections) {
    WorldDeltaStore store;
    const std::array<CellCoord, 5> durable{{
        {-15, -17, -17}, {-14, -16, -16}, {-13, -1, -1},
        {-12, 0, 0}, {-11, 16, 16},
    }};
    const std::array<CellCoord, 5> overlays{{
        {1, -17, -17}, {2, -16, -16}, {3, -1, -1},
        {4, 0, 0}, {5, 16, 16},
    }};
    const auto admitted = store.admit_typed_state(typed_admission("a2a:sorted-five", 0U,
        {typed_stone(durable[0]), typed_durable(durable[1]), typed_stone(durable[2]),
            typed_durable(durable[3]), typed_stone(durable[4])},
        {typed_overlay_without_persistence_metadata(overlays[0]), typed_overlay(overlays[1]),
            typed_overlay_without_persistence_metadata(overlays[2]), typed_overlay(overlays[3]),
            typed_overlay_without_persistence_metadata(overlays[4])}));
    VWB_EXPECT_EQ(WorldDeltaCommitStatus::committed, admitted.status);
    constexpr std::uint64_t token = 0x41326104U;

    const auto expect_lookup = [&](const CellCoord cell, const bool present,
                                   const BorrowedTypedCellHeader::SourceLayer layer) {
        BorrowedTypedCellCursor cursor;
        std::uint32_t charged = 0U;
        for (std::size_t call = 0U; call < 1000U; ++call) {
            const std::uint32_t offered = call % 2U == 0U ? 1U : 64U;
            const auto step = store.advance_borrowed_typed_cell(cursor, cell, token, offered);
            VWB_EXPECT(step.consumed_ops <= offered);
            VWB_EXPECT(step.consumed_ops <= 64U);
            VWB_EXPECT(step.status != BorrowedTypedCellCursor::Status::failed);
            VWB_EXPECT(step.status != BorrowedTypedCellCursor::Status::source_changed);
            charged += step.consumed_ops;
            if (step.status == BorrowedTypedCellCursor::Status::ready_present
                || step.status == BorrowedTypedCellCursor::Status::ready_absent) break;
        }
        VWB_EXPECT(charged > 0U);
        const auto expected = store.pin().effective_typed_cell_at(cell);
        VWB_EXPECT_EQ(present, expected.has_value());
        VWB_EXPECT_EQ(present ? BorrowedTypedCellCursor::Status::ready_present
                              : BorrowedTypedCellCursor::Status::ready_absent, cursor.status());
        const auto header = store.borrowed_typed_cell_header(cursor, token);
        VWB_EXPECT_EQ(present, header.has_value());
        if (present) expect_borrowed_scalar_header(*header, *expected, layer);
    };

    // Each vector contributes first, middle, and last hits. Durable queries
    // also have to miss the five overlay records before falling through.
    for (const std::size_t index : {0U, 2U, 4U}) {
        expect_lookup(durable[index], true, BorrowedTypedCellHeader::SourceLayer::durable);
        expect_lookup(overlays[index], true, BorrowedTypedCellHeader::SourceLayer::overlay);
    }
    // These positions are before, between, and after the ordered records in
    // each layer. Both axes cross negative section boundaries; the middle
    // probes share a section with their neighboring records.
    const std::array<CellCoord, 3> durable_misses{{
        {-16, -17, -17}, {-14, -15, -8}, {-10, 16, 17},
    }};
    const std::array<CellCoord, 3> overlay_misses{{
        {0, -17, -17}, {2, -15, -8}, {6, 17, 17},
    }};
    for (const CellCoord cell : durable_misses)
        expect_lookup(cell, false, BorrowedTypedCellHeader::SourceLayer::durable);
    for (const CellCoord cell : overlay_misses)
        expect_lookup(cell, false, BorrowedTypedCellHeader::SourceLayer::overlay);
}

VWB_TEST(borrowed_typed_projection_wdp1_matches_immutable_pin_with_nested_metadata_and_remote_rows) {
    WorldDeltaStore store;
    const auto receipt = store.admit_typed_state(typed_admission("borrowed:projection", 0U,
        {typed_stone({-1, 7, 2}), typed_durable({500, 7, 500})},
        {typed_overlay_without_persistence_metadata({3, -2, 1})}));
    VWB_EXPECT_EQ(WorldDeltaCommitStatus::committed, receipt.status);
    const WorldDeltaHorizontalBounds bounds{-20, -20, 40, 40};
    const Sha256Digest expected = store.pin().typed_projection_digest(bounds);
    BorrowedTypedProjectionCursor cursor;
    const std::uint32_t quotas[] = {0U, 1U, 2U, 3U, 7U, 34U, 63U, 64U};
    for (std::size_t call = 0U;
         call < 100000U && cursor.status() != BorrowedTypedProjectionCursor::Status::ready;
         ++call) {
        const std::uint32_t offered = quotas[call % 8U];
        const auto step = store.advance_borrowed_projection(cursor, bounds, 19U, offered);
        VWB_EXPECT(step.consumed_ops <= offered);
        VWB_EXPECT(step.consumed_ops <= 64U);
        VWB_EXPECT(step.status != BorrowedTypedProjectionCursor::Status::failed);
    }
    VWB_EXPECT_EQ(BorrowedTypedProjectionCursor::Status::ready, cursor.status());
    VWB_EXPECT_EQ(expected, cursor.digest());
    const WorldDeltaHorizontalBounds remote{490, 490, 30, 30};
    cursor.reset(remote);
    for (std::size_t call = 0U;
         call < 100000U && cursor.status() != BorrowedTypedProjectionCursor::Status::ready;
         ++call) {
        const auto step = store.advance_borrowed_projection(cursor, remote, 20U, 64U);
        VWB_EXPECT(step.consumed_ops <= 64U);
        VWB_EXPECT(step.status != BorrowedTypedProjectionCursor::Status::failed);
    }
    VWB_EXPECT_EQ(BorrowedTypedProjectionCursor::Status::ready, cursor.status());
    VWB_EXPECT_EQ(store.pin().typed_projection_digest(remote), cursor.digest());
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

Sha256Digest feature_digest(const std::uint8_t value) {
    Sha256Digest result{};
    result.fill(value);
    return result;
}

NativeGeneratedFeatureFootprintEntry footprint_entry(
    const std::string &feature_id,
    const std::int32_t first_x,
    const std::int32_t last_x,
    const std::int32_t y = 0,
    const std::int32_t z = 0) {
    NativeGeneratedFeatureFootprintEntry result;
    result.feature_id = feature_id;
    result.recipe_key = "tree.bushy_oak";
    result.recipe_revision = 21U;
    result.footprint_schema_revision = 1U;
    result.generated_definition_digest = feature_digest(9U);
    result.runs = {
        {NativeFeatureFootprintChannel::terrain_source, {first_x, y, z}, last_x},
        {NativeFeatureFootprintChannel::render, {first_x, y, z}, last_x},
        {NativeFeatureFootprintChannel::collision, {first_x, y, z}, last_x},
        {NativeFeatureFootprintChannel::navigation, {first_x, y, z}, last_x},
    };
    return result;
}

std::shared_ptr<const NativeGeneratedFeatureFootprintCatalog> feature_catalog(
    std::vector<NativeGeneratedFeatureFootprintEntry> entries) {
    return std::make_shared<const NativeGeneratedFeatureFootprintCatalog>(
        NativeGeneratedFeatureFootprintCatalog::create(feature_digest(3U), 7U, std::move(entries)));
}

NativeTerrainVolumeV2 persisted_terrain_volume(
    const std::uint64_t revision,
    std::vector<NativeTypedWorldStateRecord> records,
    std::vector<NativeTerrainVolumeV2SectionRevision> sections) {
    NativeTerrainVolumeV2 volume;
    volume.revision = revision;
    volume.durable_snapshot = NativeTypedWorldStateSnapshot::create(std::move(records));
    volume.section_revisions = std::move(sections);
    return volume;
}

WorldDeltaInitialSnapshot initial_checkpoint(
    const std::uint64_t world_revision,
    NativeTerrainVolumeV2 terrain_volume,
    std::vector<NativeTypedWorldStateRecord> overlays = {},
    NativeFeatureDeltaSnapshot features = NativeFeatureDeltaSnapshot::create({}, {})) {
    WorldDeltaInitialSnapshot result;
    result.revision = world_revision;
    result.terrain_volume = std::move(terrain_volume);
    result.transient_overlays = std::move(overlays);
    result.feature_delta_snapshot = std::move(features);
    return result;
}

WorldDeltaStoreLimits capacity_limits(
    const std::size_t durable,
    const std::size_t overlays,
    const std::size_t tombstones,
    const std::size_t player_instances,
    const std::size_t persisted_total,
    const std::size_t resident_total,
    const std::size_t transactions,
    const std::uint64_t initial_revision = 0U) {
    WorldDeltaStoreLimits limits;
    limits.max_durable_terrain_records = durable;
    limits.max_scene_overlay_records = overlays;
    limits.max_feature_tombstones = tombstones;
    limits.max_player_created_instances = player_instances;
    limits.max_persisted_records = persisted_total;
    limits.max_resident_records = resident_total;
    limits.max_transactions = transactions;
    limits.initial_revision = initial_revision;
    return limits;
}

// Preserve the old tests' deliberately shared small total while making that
// policy explicit. Production defaults no longer collapse all domains into
// this one record ceiling.
WorldDeltaStoreLimits combined_test_limits(
    const std::size_t records,
    const std::size_t transactions,
    const std::uint64_t initial_revision = 0U) {
    return capacity_limits(
        records, records, records, records, records, records,
        transactions, initial_revision);
}

Sha256Digest expect_borrowed_projection_parity(
    const WorldDeltaStore &store, BorrowedTypedProjectionCursor &cursor,
    const WorldDeltaHorizontalBounds bounds, const std::uint64_t source_token) {
    const Sha256Digest expected = store.pin().typed_projection_digest(bounds);
    cursor.reset(bounds);
    const auto initial_zero = store.advance_borrowed_projection(cursor, bounds, source_token, 0U);
    VWB_EXPECT_EQ(0U, initial_zero.consumed_ops);
    VWB_EXPECT_EQ(BorrowedTypedProjectionCursor::Status::idle, cursor.status());
    VWB_EXPECT_THROW(std::logic_error, cursor.digest());

    // Small offers exercise refusal and resume; the fifth offer pays the
    // reported atomic cost so a legitimately indivisible step can complete.
    const std::array<std::uint32_t, 4> small{1U, 2U, 3U, 0U};
    std::size_t positive_calls = 0U;
    std::size_t small_calls = 0U;
    std::uint32_t next_atomic = initial_zero.next_atomic_ops;
    for (std::size_t call = 0U;
         call < 250000U && cursor.status() != BorrowedTypedProjectionCursor::Status::ready;
         ++call) {
        const std::uint32_t offered = call % 5U == 4U
            ? std::max(4U, next_atomic) : small[call % 5U];
        const auto step = store.advance_borrowed_projection(cursor, bounds, source_token, offered);
        VWB_EXPECT(step.consumed_ops <= offered);
        VWB_EXPECT(step.consumed_ops <= 64U);
        VWB_EXPECT(step.status == BorrowedTypedProjectionCursor::Status::pending
            || step.status == BorrowedTypedProjectionCursor::Status::ready);
        if (offered == 0U) VWB_EXPECT_EQ(0U, step.consumed_ops);
        if (offered <= 3U) ++small_calls;
        if (step.consumed_ops > 0U) ++positive_calls;
        if (step.status == BorrowedTypedProjectionCursor::Status::pending)
            VWB_EXPECT(step.next_atomic_ops > 0U && step.next_atomic_ops <= 64U);
        next_atomic = step.next_atomic_ops;
    }
    VWB_EXPECT(small_calls >= 4U);
    VWB_EXPECT(positive_calls > 1U);
    VWB_EXPECT_EQ(BorrowedTypedProjectionCursor::Status::ready, cursor.status());
    VWB_EXPECT_EQ(expected, cursor.digest());
    const auto repeat = store.advance_borrowed_projection(cursor, bounds, source_token, 64U);
    VWB_EXPECT_EQ(BorrowedTypedProjectionCursor::Status::ready, repeat.status);
    VWB_EXPECT_EQ(0U, repeat.consumed_ops);
    VWB_EXPECT_EQ(expected, cursor.digest());
    return expected;
}

struct ProjectionByteSink final : NativeValueCanonicalSink {
    std::vector<std::uint8_t> bytes;
    void append(const std::uint8_t *data, const std::size_t size) override {
        bytes.insert(bytes.end(), data, data + size);
    }
};

NativeTerrainVolumeV2 complete_section_volume() {
    std::vector<NativeTypedWorldStateRecord> records;
    records.reserve(NativeTerrainVolumeV2Limits::MAX_CELLS_PER_SECTION);
    for (std::int32_t z = 0; z < NativeCellState::SECTION_SIZE; ++z) {
        for (std::int32_t y = 0; y < NativeCellState::SECTION_SIZE; ++y) {
            for (std::int32_t x = 0; x < NativeCellState::SECTION_SIZE; ++x) {
                records.push_back(typed_durable({x, y, z}));
            }
        }
    }
    return persisted_terrain_volume(11U, std::move(records), {{{0, 0, 0}, 10U}});
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
    VWB_EXPECT(first.durable_terrain_snapshot().records().empty());
    VWB_EXPECT(!first.durable_terrain_at({0, 0, 0}));
    VWB_EXPECT(!first.effective_typed_cell_at({0, 0, 0}));
    VWB_EXPECT(first.scene_overlays().empty());
    VWB_EXPECT(first.feature_delta_snapshot().tombstones().empty());
    VWB_EXPECT(first.feature_delta_snapshot().player_created_instances().empty());
}

VWB_TEST(world_delta_store_capacity_contract_preserves_every_independent_production_maximum) {
    const WorldDeltaStoreLimits limits;
    VWB_EXPECT_EQ(65536U, limits.max_durable_terrain_records);
    VWB_EXPECT_EQ(65536U, limits.max_scene_overlay_records);
    VWB_EXPECT_EQ(65536U, limits.max_feature_tombstones);
    VWB_EXPECT_EQ(65536U, limits.max_player_created_instances);
    VWB_EXPECT_EQ(196608U, limits.max_persisted_records);
    VWB_EXPECT_EQ(262144U, limits.max_resident_records);

    VWB_EXPECT(world_delta_store_fits_capacity({65536U, 0U, 0U, 0U}, limits));
    VWB_EXPECT(world_delta_store_fits_capacity({0U, 65536U, 0U, 0U}, limits));
    VWB_EXPECT(world_delta_store_fits_capacity({0U, 0U, 65536U, 0U}, limits));
    VWB_EXPECT(world_delta_store_fits_capacity({0U, 0U, 0U, 65536U}, limits));
    // The complete v2 persisted maximum and the runtime-only overlay maximum
    // coexist. Tombstone semantic admission remains a separate, fail-closed
    // footprint contract exercised by the store tests below.
    VWB_EXPECT(world_delta_store_fits_capacity(
        {65536U, 65536U, 65536U, 65536U}, limits));

    VWB_EXPECT(!world_delta_store_fits_capacity({65537U, 0U, 0U, 0U}, limits));
    VWB_EXPECT(!world_delta_store_fits_capacity({0U, 65537U, 0U, 0U}, limits));
    VWB_EXPECT(!world_delta_store_fits_capacity({0U, 0U, 65537U, 0U}, limits));
    VWB_EXPECT(!world_delta_store_fits_capacity({0U, 0U, 0U, 65537U}, limits));
}

VWB_TEST(world_delta_store_capacity_totals_use_subtraction_without_overflow) {
    const WorldDeltaStoreLimits constrained = capacity_limits(
        4U, 5U, 4U, 4U, 10U, 14U, 8U);
    VWB_EXPECT(world_delta_store_fits_capacity({4U, 4U, 3U, 3U}, constrained));
    VWB_EXPECT(!world_delta_store_fits_capacity({4U, 4U, 4U, 3U}, constrained));
    VWB_EXPECT(!world_delta_store_fits_capacity({4U, 5U, 3U, 3U}, constrained));
    const WorldDeltaStoreLimits tombstone_total = capacity_limits(
        8U, 1U, 8U, 1U, 10U, 11U, 1U);
    VWB_EXPECT(!world_delta_store_fits_capacity({4U, 0U, 7U, 0U}, tombstone_total));

    const std::size_t maximum = std::numeric_limits<std::size_t>::max();
    const WorldDeltaStoreLimits maximum_limits = capacity_limits(
        maximum, maximum, maximum, maximum, maximum, maximum, 1U);
    VWB_EXPECT(world_delta_store_fits_capacity({maximum, 0U, 0U, 0U}, maximum_limits));
    VWB_EXPECT(!world_delta_store_fits_capacity({maximum, 0U, 1U, 0U}, maximum_limits));
    VWB_EXPECT(!world_delta_store_fits_capacity({maximum - 1U, 1U, 1U, 0U}, maximum_limits));
}

VWB_TEST(world_delta_store_coexisting_domain_caps_reject_atomically_without_journaling_failure) {
    const NativeTerrainVolumeV2 terrain = persisted_terrain_volume(5U, {
        typed_durable({0, 0, 0}), typed_durable({1, 0, 0}),
    }, {{{0, 0, 0}, 5U}});
    const NativeFeatureDeltaSnapshot features = NativeFeatureDeltaSnapshot::create({}, {
        feature_instance("capacity:player:1", {4, 0, 0}),
        feature_instance("capacity:player:2", {5, 0, 0}),
    });
    const WorldDeltaStoreLimits limits = capacity_limits(
        2U, 2U, 1U, 2U, 4U, 6U, 8U);
    WorldDeltaStore store(limits, initial_checkpoint(0U, terrain, {
        typed_overlay({2, 0, 0}), typed_overlay({3, 0, 0}),
    }, features));
    const WorldDeltaPinnedSnapshot before = store.pin();
    VWB_EXPECT_EQ(2U, before.durable_terrain_snapshot().records().size());
    VWB_EXPECT_EQ(2U, before.scene_overlays().size());
    VWB_EXPECT_EQ(2U, before.feature_delta_snapshot().player_created_instances().size());
    VWB_EXPECT(world_delta_store_fits_capacity({2U, 2U, 0U, 2U}, limits));

    expect_rejection(WorldDeltaRejectReason::capacity_exceeded,
        transaction("capacity:failed-not-journaled", 0U, {
            set(WorldDeltaNamespace::terrain_override, {6, 0, 0}, stone()),
        }), store);
    expect_typed_rejection(WorldDeltaRejectReason::capacity_exceeded,
        typed_admission("capacity:overlay-over", 0U, {
            typed_durable({0, 0, 0}), typed_durable({1, 0, 0}),
        }, {
            typed_overlay({2, 0, 0}), typed_overlay({3, 0, 0}), typed_overlay({6, 0, 0}),
        }), store);
    expect_feature_rejection(WorldDeltaRejectReason::capacity_exceeded,
        feature_admission("capacity:player-over", 0U, {}, {
            feature_instance("capacity:player:1", {4, 0, 0}),
            feature_instance("capacity:player:2", {5, 0, 0}),
            feature_instance("capacity:player:3", {6, 0, 0}),
        }), store);

    const WorldDeltaPinnedSnapshot after_rejections = store.pin();
    VWB_EXPECT_EQ(0ULL, after_rejections.revision());
    VWB_EXPECT_EQ(before.content_digest(), after_rejections.content_digest());
    VWB_EXPECT_EQ(2U, after_rejections.durable_terrain_snapshot().records().size());
    VWB_EXPECT_EQ(2U, after_rejections.scene_overlays().size());
    VWB_EXPECT_EQ(2U, after_rejections.feature_delta_snapshot().player_created_instances().size());

    // Reusing the first rejected transaction ID must succeed: capacity
    // rejection cannot consume journal capacity or poison idempotency state.
    const WorldDeltaCommitReceipt recovered = store.commit_typed_cells(transaction(
        "capacity:failed-not-journaled", 0U, {
            clear(WorldDeltaNamespace::terrain_override, {1, 0, 0}),
        }));
    VWB_EXPECT_EQ(WorldDeltaCommitStatus::committed, recovered.status);
    VWB_EXPECT_EQ(1ULL, recovered.revision);
    VWB_EXPECT_EQ(1U, store.pin().durable_terrain_snapshot().records().size());
}

VWB_TEST(world_delta_store_persisted_total_rejects_with_each_domain_below_its_own_cap) {
    const NativeTerrainVolumeV2 terrain = persisted_terrain_volume(5U, {
        typed_durable({0, 0, 0}), typed_durable({1, 0, 0}),
    }, {{{0, 0, 0}, 5U}});
    const NativeFeatureDeltaSnapshot features = NativeFeatureDeltaSnapshot::create({}, {
        feature_instance("capacity:total:player:1", {4, 0, 0}),
        feature_instance("capacity:total:player:2", {5, 0, 0}),
    });
    const WorldDeltaStoreLimits limits = capacity_limits(
        3U, 2U, 1U, 3U, 4U, 6U, 8U);
    WorldDeltaStore store(limits, initial_checkpoint(0U, terrain, {}, features));
    const WorldDeltaPinnedSnapshot before = store.pin();

    // Three terrain records and two player instances would each remain below
    // their domain limits, but together would exceed the persisted total.
    expect_rejection(WorldDeltaRejectReason::capacity_exceeded,
        transaction("capacity:persisted-total", 0U, {
            set(WorldDeltaNamespace::terrain_override, {6, 0, 0}, stone()),
        }), store);
    VWB_EXPECT_EQ(0ULL, store.revision());
    VWB_EXPECT_EQ(before.content_digest(), store.pin().content_digest());
}

VWB_TEST(world_delta_store_constructor_admits_a_complete_4096_cell_v2_section_without_native_value_limits) {
    const NativeTerrainVolumeV2 volume = complete_section_volume();
    WorldDeltaStore store(combined_test_limits(4096U, 8U), initial_checkpoint(0U, volume));
    const WorldDeltaPinnedSnapshot pin = store.pin();
    VWB_EXPECT_EQ(4096U, pin.durable_terrain_snapshot().records().size());
    VWB_EXPECT_EQ(1U, pin.terrain_volume().section_revisions.size());
    VWB_EXPECT_EQ(11ULL, pin.terrain_volume().revision);
    VWB_EXPECT_EQ(volume, pin.terrain_volume());
}

VWB_TEST(world_delta_store_constructor_preserves_section_grouped_interleaved_v2_cells) {
    const NativeTerrainVolumeV2 volume = persisted_terrain_volume(11U, {
        typed_stone({0, 0, 1}),
        typed_stone({-1, 0, 15}),
        typed_stone({-16, 0, 0}),
    }, {
        {{-1, 0, 0}, 10U}, {{0, 0, 0}, 11U},
    });
    WorldDeltaStore store({}, initial_checkpoint(0U, volume));
    const WorldDeltaPinnedSnapshot pin = store.pin();
    VWB_EXPECT_EQ(volume, pin.terrain_volume());
    VWB_EXPECT((pin.durable_terrain_snapshot().records()[0].state.cell == CellCoord{-16, 0, 0}));
    VWB_EXPECT((pin.durable_terrain_snapshot().records()[1].state.cell == CellCoord{-1, 0, 15}));
    VWB_EXPECT((pin.durable_terrain_snapshot().records()[2].state.cell == CellCoord{0, 0, 1}));
    VWB_EXPECT(pin.durable_terrain_at({-16, 0, 0}).has_value());
    VWB_EXPECT(pin.durable_terrain_at({-1, 0, 15}).has_value());
    VWB_EXPECT(pin.durable_terrain_at({0, 0, 1}).has_value());
    VWB_EXPECT(!pin.durable_terrain_at({0, 0, 15}).has_value());
}

VWB_TEST(world_delta_store_constructor_atomically_pins_a_validated_v2_terrain_checkpoint) {
    const NativeTerrainVolumeV2 volume = persisted_terrain_volume(73U, {
        typed_stone({-16, 0, 0}), typed_stone({16, 0, 0}),
    }, {
        {{-1, 0, 0}, 71U}, {{1, 0, 0}, 72U},
    });
    const NativeFeatureDeltaSnapshot features = NativeFeatureDeltaSnapshot::create({}, {
        feature_instance("player:checkpoint", {0, 0, 0}),
    });
    WorldDeltaStore store(combined_test_limits(64U, 64U, 19U), initial_checkpoint(19U, volume, {
        typed_overlay_without_persistence_metadata({0, 0, 0}),
    }, features));
    const WorldDeltaPinnedSnapshot first = store.pin();
    VWB_EXPECT_EQ(19ULL, first.revision());
    VWB_EXPECT_EQ(volume, first.terrain_volume());
    VWB_EXPECT_EQ(volume.durable_snapshot, first.durable_terrain_snapshot());
    VWB_EXPECT_EQ(1U, first.scene_overlays().size());
    VWB_EXPECT_EQ(features, first.feature_delta_snapshot());
    VWB_EXPECT(!(first.content_digest() == Sha256Digest{}));

    const WorldDeltaCommitReceipt overlay = store.commit_typed_cells(transaction("checkpoint:overlay", 19, {
        set(WorldDeltaNamespace::scene_overlay, {0, 0, 0}, air()),
    }));
    VWB_EXPECT_EQ(WorldDeltaCommitStatus::committed, overlay.status);
    VWB_EXPECT_EQ(20ULL, overlay.revision);
    VWB_EXPECT_EQ(volume, store.pin().terrain_volume());
    VWB_EXPECT_EQ(19ULL, first.revision());
    VWB_EXPECT_EQ(volume, first.terrain_volume());
    VWB_EXPECT(!(first.content_digest() == store.pin().content_digest()));
}

VWB_TEST(world_delta_store_durable_transactions_advance_only_persisted_terrain_revisions_and_remove_empty_sections) {
    const NativeTerrainVolumeV2 volume = persisted_terrain_volume(73U, {
        typed_stone({-16, 0, 0}), typed_stone({16, 0, 0}),
    }, {
        {{-1, 0, 0}, 71U}, {{1, 0, 0}, 72U},
    });
    WorldDeltaStore store({}, initial_checkpoint(0U, volume));
    const WorldDeltaCommitReceipt changed = store.commit_typed_cells(transaction("checkpoint:durable", 0, {
        set(WorldDeltaNamespace::terrain_override, {-16, 0, 0}, water()),
        set(WorldDeltaNamespace::terrain_override, {32, 0, 0}, stone()),
    }));
    VWB_EXPECT_EQ(1ULL, changed.revision);
    const NativeTerrainVolumeV2 after = store.pin().terrain_volume();
    VWB_EXPECT_EQ(74ULL, after.revision);
    VWB_EXPECT_EQ(3U, after.section_revisions.size());
    VWB_EXPECT_EQ(74ULL, after.section_revisions[0].revision);
    VWB_EXPECT_EQ(72ULL, after.section_revisions[1].revision);
    VWB_EXPECT_EQ(74ULL, after.section_revisions[2].revision);

    const WorldDeltaCommitReceipt cleared_receipt = store.commit_typed_cells(transaction("checkpoint:clear", 1, {
        clear(WorldDeltaNamespace::terrain_override, {-16, 0, 0}),
    }));
    VWB_EXPECT_EQ(2ULL, cleared_receipt.revision);
    const NativeTerrainVolumeV2 cleared = store.pin().terrain_volume();
    VWB_EXPECT_EQ(75ULL, cleared.revision);
    VWB_EXPECT_EQ(2U, cleared.section_revisions.size());
    VWB_EXPECT((cleared.section_revisions[0].section == CellCoord{1, 0, 0}));
    VWB_EXPECT((cleared.section_revisions[1].section == CellCoord{2, 0, 0}));
}

VWB_TEST(world_delta_store_rejects_malformed_or_conflicting_constructor_checkpoints_without_a_live_import_endpoint) {
    const NativeTerrainVolumeV2 valid = persisted_terrain_volume(1U, {
        typed_stone({0, 0, 0}),
    }, {{{0, 0, 0}, 1U}});
    NativeTerrainVolumeV2 malformed = valid;
    malformed.section_revisions.clear();
    VWB_EXPECT_THROW(WorldDeltaRejected, WorldDeltaStore({}, initial_checkpoint(0U, malformed)));
    malformed = valid;
    malformed.revision = 9007199254740993ULL;
    VWB_EXPECT_THROW(WorldDeltaRejected, WorldDeltaStore({}, initial_checkpoint(0U, malformed)));
    VWB_EXPECT_THROW(WorldDeltaRejected,
        WorldDeltaStore(combined_test_limits(8U, 8U, 3U), initial_checkpoint(2U, valid)));

    NativeTypedWorldStateRecord malformed_overlay = typed_overlay({0, 0, 0});
    malformed_overlay.persistence = NativeTypedWorldStatePersistence::durable;
    VWB_EXPECT_THROW(WorldDeltaRejected,
        WorldDeltaStore({}, initial_checkpoint(0U, valid, {malformed_overlay})));
    VWB_EXPECT_THROW(WorldDeltaRejected, WorldDeltaStore(combined_test_limits(1U, 8U), initial_checkpoint(0U, valid, {
        typed_overlay({1, 0, 0}),
    })));
}

VWB_TEST(world_delta_store_rejects_a_durable_mutation_after_the_v2_json_revision_limit) {
    const NativeTerrainVolumeV2 volume = persisted_terrain_volume(9007199254740992ULL, {
        typed_stone({0, 0, 0}),
    }, {{{0, 0, 0}, 9007199254740992ULL}});
    WorldDeltaStore store({}, initial_checkpoint(0U, volume));
    expect_rejection(WorldDeltaRejectReason::capacity_exceeded, transaction("checkpoint:exhausted", 0, {
        set(WorldDeltaNamespace::terrain_override, {0, 0, 0}, water()),
    }), store);
    VWB_EXPECT_EQ(volume, store.pin().terrain_volume());
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

    const WorldDeltaCommitReceipt terrain = store.commit_typed_cells(transaction("delta:after-feature", 1, {
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

VWB_TEST(world_delta_store_admits_catalog_resolved_tombstones_and_invalidates_all_channels) {
    const auto catalog = feature_catalog({
        footprint_entry("generated:tree:west", -16, -1, 0, 0),
        footprint_entry("generated:tree:east", 32, 47, 0, 0),
    });
    WorldDeltaStore store({}, {}, catalog);
    const WorldDeltaCommitReceipt first = store.admit_feature_deltas(feature_admission(
        "feature:remove-west", 0, {{"generated:tree:west"}}));
    VWB_EXPECT_EQ(WorldDeltaCommitStatus::committed, first.status);
    VWB_EXPECT_EQ(1ULL, first.revision);
    // All four channels name the same section here, so the receipt is one
    // deduplicated conservative 3x3x3 neighborhood rather than four copies.
    VWB_EXPECT_EQ(27U, first.affected_sections.size());
    VWB_EXPECT(std::find(first.affected_sections.begin(), first.affected_sections.end(),
        WorldDeltaSectionKey{{-1, 0, 0}}) != first.affected_sections.end());
    VWB_EXPECT_EQ(std::string("generated:tree:west"),
        store.pin().feature_delta_snapshot().tombstones()[0].feature_id);

    const WorldDeltaCommitReceipt replaced = store.admit_feature_deltas(feature_admission(
        "feature:replace-tombstone", 1, {{"generated:tree:east"}}));
    VWB_EXPECT_EQ(WorldDeltaCommitStatus::committed, replaced.status);
    // Old (section -1) and new (section 2) footprints both invalidate,
    // including their halo sections, so resurrecting the old tree cannot
    // retain a stale physical or navigation artifact.
    VWB_EXPECT_EQ(54U, replaced.affected_sections.size());
    VWB_EXPECT(std::find(replaced.affected_sections.begin(), replaced.affected_sections.end(),
        WorldDeltaSectionKey{{-1, 0, 0}}) != replaced.affected_sections.end());
    VWB_EXPECT(std::find(replaced.affected_sections.begin(), replaced.affected_sections.end(),
        WorldDeltaSectionKey{{2, 0, 0}}) != replaced.affected_sections.end());

    const WorldDeltaCommitReceipt reversed = store.admit_feature_deltas(feature_admission(
        "feature:reverse-tombstone", 2, {{"generated:tree:west"}}));
    VWB_EXPECT_EQ(WorldDeltaCommitStatus::committed, reversed.status);
    VWB_EXPECT_EQ(54U, reversed.affected_sections.size());

    const WorldDeltaCommitReceipt restored = store.admit_feature_deltas(feature_admission(
        "feature:restore", 3));
    VWB_EXPECT_EQ(WorldDeltaCommitStatus::committed, restored.status);
    VWB_EXPECT_EQ(27U, restored.affected_sections.size());
    VWB_EXPECT(store.pin().feature_delta_snapshot().tombstones().empty());
}

VWB_TEST(world_delta_store_rejects_unresolved_or_overlarge_catalog_tombstone_receipts_atomically) {
    const auto catalog = feature_catalog({footprint_entry("generated:tree:known", 0, 0)});
    WorldDeltaStore unresolved({}, {}, catalog);
    expect_feature_rejection(WorldDeltaRejectReason::invalid_transaction,
        feature_admission("feature:unknown", 0, {{"generated:tree:unknown"}}), unresolved);
    VWB_EXPECT_EQ(0ULL, unresolved.revision());
    VWB_EXPECT(unresolved.pin().feature_delta_snapshot().tombstones().empty());

    WorldDeltaStoreLimits tight = WorldDeltaStoreLimits{};
    tight.max_affected_sections = 26U;
    WorldDeltaStore overlarge(tight, {}, catalog);
    expect_feature_rejection(WorldDeltaRejectReason::capacity_exceeded,
        feature_admission("feature:too-wide", 0, {{"generated:tree:known"}}), overlarge);
    VWB_EXPECT_EQ(0ULL, overlarge.revision());
    VWB_EXPECT(overlarge.pin().feature_delta_snapshot().tombstones().empty());

    const NativeFeatureDeltaSnapshot tombstones = NativeFeatureDeltaSnapshot::create(
        {{"generated:tree:known"}}, {});
    WorldDeltaStore restored({}, initial_checkpoint(4U, {}, {}, tombstones), catalog);
    VWB_EXPECT_EQ(4ULL, restored.revision());
    VWB_EXPECT_EQ(1U, restored.pin().feature_delta_snapshot().tombstones().size());
    VWB_EXPECT_THROW(WorldDeltaRejected,
        WorldDeltaStore({}, initial_checkpoint(4U, {}, {}, tombstones)));

    WorldDeltaStoreLimits invalid_limits = WorldDeltaStoreLimits{};
    invalid_limits.max_affected_sections = 0U;
    VWB_EXPECT_THROW(WorldDeltaRejected, WorldDeltaStore{invalid_limits});
}

VWB_TEST(world_delta_store_keeps_an_unchanged_tombstone_footprint_when_other_feature_state_changes) {
    const auto catalog = feature_catalog({footprint_entry("generated:tree:fixed", 0, 0)});
    WorldDeltaStore store({}, {}, catalog);
    static_cast<void>(store.admit_feature_deltas(feature_admission(
        "feature:remove", 0, {{"generated:tree:fixed"}})));
    const WorldDeltaCommitReceipt mixed = store.admit_feature_deltas(feature_admission(
        "feature:add-player", 1, {{"generated:tree:fixed"}}, {
            feature_instance("player:crate:catalog", {32, 0, 0}),
        }));
    // The unchanged tombstone is compared and retained without needless
    // republishing; only the new player instance invalidates its own halo.
    VWB_EXPECT_EQ(27U, mixed.affected_sections.size());
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

    WorldDeltaStore combined_capacity(combined_test_limits(2U, 4U));
    static_cast<void>(combined_capacity.admit_typed_state(
        typed_admission("typed:capacity", 0, {typed_durable({0, 0, 0})})));
    expect_feature_rejection(WorldDeltaRejectReason::capacity_exceeded,
        feature_admission("feature:over-capacity", 1, {}, {
            feature_instance("player:crate:2", {1, 0, 0}),
            feature_instance("player:crate:3", {2, 0, 0}),
        }), combined_capacity);
    VWB_EXPECT_EQ(1ULL, combined_capacity.revision());

    WorldDeltaStore transaction_capacity(combined_test_limits(4U, 1U));
    static_cast<void>(transaction_capacity.admit_feature_deltas(feature_admission("feature:journal", 0)));
    expect_feature_rejection(WorldDeltaRejectReason::capacity_exceeded,
        feature_admission("feature:journal-full", 0), transaction_capacity);

    WorldDeltaStore overflow(combined_test_limits(
        4U, 4U, std::numeric_limits<std::uint64_t>::max()));
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
    VWB_EXPECT(before.durable_terrain_snapshot().records().empty());
    VWB_EXPECT(before.scene_overlays().empty());

    const WorldDeltaPinnedSnapshot typed_pin = store.pin();
    VWB_EXPECT_EQ(1ULL, typed_pin.revision());
    VWB_EXPECT_EQ(1U, typed_pin.durable_terrain_snapshot().records().size());
    VWB_EXPECT_EQ(1U, typed_pin.scene_overlays().size());
    VWB_EXPECT_EQ(15, static_cast<int>(typed_pin.durable_terrain_at({-16, 0, 0})->light.sky));
    VWB_EXPECT_EQ(1U, typed_pin.durable_terrain_at({-16, 0, 0})->metadata.as_object().size());
    VWB_EXPECT(typed_pin.durable_terrain_at({-16, 0, 0})->block_id.has_value());
    VWB_EXPECT_EQ(7, static_cast<int>(typed_pin.effective_typed_cell_at({-16, 0, 0})->light.block));

    const WorldDeltaCommitReceipt delta = store.commit_typed_cells(transaction("delta:after-typed", 1, {
        set(WorldDeltaNamespace::terrain_override, {0, 0, 0}, stone()),
    }));
    VWB_EXPECT_EQ(2ULL, delta.revision);
    const WorldDeltaPinnedSnapshot after = store.pin();
    VWB_EXPECT_EQ(2ULL, after.revision());
    VWB_EXPECT(after.effective_typed_cell_at({-16, 0, 0}).has_value());
    VWB_EXPECT_EQ(1ULL, typed_pin.revision());
    VWB_EXPECT(!typed_pin.effective_typed_cell_at({0, 0, 0}));
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
    VWB_EXPECT(!pin.scene_overlay_at({16, 0, 0}));
    VWB_EXPECT_EQ(2, static_cast<int>(pin.durable_terrain_at({0, 0, 0})->light.sky));
    VWB_EXPECT(pin.durable_terrain_at({32, 0, 0}).has_value());
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
    different_value.state.edit_reason = "player_place_different";
    // The WTY3 journal must distinguish recursive metadata, block identity,
    // and optional edit reason;
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
    WorldDeltaStore store(combined_test_limits(1U, 8U));
    expect_typed_rejection(WorldDeltaRejectReason::capacity_exceeded,
        typed_admission("typed:over-capacity", 0, {typed_durable({0, 0, 0})}, {typed_overlay({1, 0, 0})}), store);
    VWB_EXPECT_EQ(0ULL, store.revision());
    VWB_EXPECT(store.pin().durable_terrain_snapshot().records().empty());

    NativeTypedWorldStateRecord malformed = typed_overlay({0, 0, 0});
    malformed.persistence = NativeTypedWorldStatePersistence::durable;
    expect_typed_rejection(WorldDeltaRejectReason::invalid_transaction,
        {"typed:malformed", 0, NativeTypedWorldStateSnapshot::create({}), {malformed}}, store);

    NativeTypedWorldStateRecord missing_durable_identity = typed_durable({0, 0, 0});
    missing_durable_identity.state.block_id.reset();
    expect_typed_rejection(WorldDeltaRejectReason::invalid_transaction,
        typed_admission("typed:missing-durable-identity", 0, {missing_durable_identity}), store);

    VWB_EXPECT_EQ(0ULL, store.revision());
    VWB_EXPECT(store.pin().scene_overlays().empty());
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
    VWB_EXPECT(!pin.durable_terrain_at({0, 1, 0}));
    VWB_EXPECT(!pin.durable_terrain_at({0, 0, 2}));
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

    WorldDeltaStore combined_capacity(combined_test_limits(2U, 8U));
    static_cast<void>(combined_capacity.commit_typed_cells(transaction("delta:capacity-base", 0, {
        set(WorldDeltaNamespace::terrain_override, {0, 0, 0}, stone()),
    })));
    expect_typed_rejection(WorldDeltaRejectReason::capacity_exceeded,
        typed_admission("typed:combined-capacity", 1,
            {typed_durable({1, 0, 0}), typed_durable({2, 0, 0}), typed_durable({3, 0, 0})}), combined_capacity);
    VWB_EXPECT_EQ(1ULL, combined_capacity.revision());

    WorldDeltaStore transaction_capacity(combined_test_limits(8U, 1U));
    static_cast<void>(transaction_capacity.admit_typed_state(
        typed_admission("typed:journal-base", 0, {typed_durable({0, 0, 0})})));
    expect_typed_rejection(WorldDeltaRejectReason::capacity_exceeded,
        typed_admission("typed:journal-full", 1, {typed_durable({1, 0, 0})}), transaction_capacity);

    WorldDeltaStore overflow(combined_test_limits(
        8U, 8U, std::numeric_limits<std::uint64_t>::max()));
    expect_typed_rejection(WorldDeltaRejectReason::capacity_exceeded,
        typed_admission("typed:max-revision", std::numeric_limits<std::uint64_t>::max(),
            {typed_durable({0, 0, 0})}), overflow);
    VWB_EXPECT(overflow.pin().durable_terrain_snapshot().records().empty());
}

VWB_TEST(world_delta_store_pinned_column_index_tracks_durable_replacements_without_overlay_or_revision_leakage) {
    WorldDeltaStore store;
    const auto any = [](const WorldDeltaPinnedSnapshot &pin, const int x, const int z) {
        return pin.durable_terrain_column_any(x, z, [](const NativeCellState &) { return true; });
    };
    const WorldDeltaPinnedSnapshot empty = store.pin();
    VWB_EXPECT(!any(empty, -3, 7));
    static_cast<void>(store.admit_typed_state(typed_admission("column:initial", 0, {
        typed_durable({-3, -8, 7}), typed_durable({-3, 9, 7}),
        typed_durable({-3, 0, 8}), typed_durable({4, 0, 7}),
    })));
    const WorldDeltaPinnedSnapshot initial = store.pin();
    VWB_EXPECT(any(initial, -3, 7));
    VWB_EXPECT(!any(initial, -3, 6));
    VWB_EXPECT(!any(initial, 4, 8));
    int visited = 0;
    VWB_EXPECT(initial.durable_terrain_column_any(-3, 7, [&visited](const NativeCellState &state) {
        ++visited;
        return state.cell.y == 9;
    }));
    VWB_EXPECT_EQ(2, visited);
    VWB_EXPECT(!initial.durable_terrain_column_any(-3, 7,
        [](const NativeCellState &state) { return state.cell.y == 20; }));
    VWB_EXPECT(!initial.durable_terrain_column_any(-3, 8,
        [](const NativeCellState &) { return false; }));
    VWB_EXPECT(!initial.durable_terrain_column_any(4, 7,
        [](const NativeCellState &) { return false; }));
    static_cast<void>(store.commit_typed_cells(transaction("column:overlay", 1, {
        set(WorldDeltaNamespace::scene_overlay, {-3, 20, 6}, stone()),
    })));
    VWB_EXPECT(!any(store.pin(), -3, 6));
    static_cast<void>(store.commit_typed_cells(transaction("column:clear-one", 2, {
        clear(WorldDeltaNamespace::terrain_override, {-3, -8, 7}),
    })));
    VWB_EXPECT(any(store.pin(), -3, 7));
    VWB_EXPECT(any(initial, -3, 7));
    static_cast<void>(store.commit_typed_cells(transaction("column:clear-last", 3, {
        clear(WorldDeltaNamespace::terrain_override, {-3, 9, 7}),
    })));
    VWB_EXPECT(!any(store.pin(), -3, 7));
    VWB_EXPECT(any(initial, -3, 7));
    VWB_EXPECT(!any(empty, -3, 7));
}

VWB_TEST(world_delta_store_effective_column_index_respects_overlay_masking_and_pin_isolation) {
    WorldDeltaStore store;
    const auto stone_in_column = [](const WorldDeltaPinnedSnapshot &pin) {
        return pin.effective_typed_column_any(-3, 7, [](const NativeCellState &state) {
            return state.material == TerrainMaterialId::stone;
        });
    };
    const auto empty = store.pin();
    VWB_EXPECT(!stone_in_column(empty));
    static_cast<void>(store.commit_typed_cells(transaction("column:effective-durable", 0, {
        set(WorldDeltaNamespace::terrain_override, {-3, 5, 7}, stone()),
    })));
    const auto durable = store.pin();
    VWB_EXPECT(stone_in_column(durable));
    static_cast<void>(store.commit_typed_cells(transaction("column:effective-mask", 1, {
        set(WorldDeltaNamespace::scene_overlay, {-3, 5, 7}, air()),
        set(WorldDeltaNamespace::scene_overlay, {-3, 8, 7}, stone()),
        set(WorldDeltaNamespace::scene_overlay, {-3, 8, 8}, stone()),
        set(WorldDeltaNamespace::scene_overlay, {4, 8, 7}, stone()),
    })));
    const auto with_second = store.pin();
    VWB_EXPECT(stone_in_column(with_second));
    VWB_EXPECT(!with_second.effective_typed_column_any(-3, 7,
        [](const NativeCellState &) { return false; }));
    VWB_EXPECT(!with_second.effective_typed_column_any(-3, 8,
        [](const NativeCellState &) { return false; }));
    VWB_EXPECT(!with_second.effective_typed_column_any(4, 7,
        [](const NativeCellState &) { return false; }));
    VWB_EXPECT(!with_second.effective_typed_column_any(-3, 7,
        [](const NativeCellState &state) { return state.cell.y == 5 && state.material == TerrainMaterialId::stone; }));
    static_cast<void>(store.commit_typed_cells(transaction("column:effective-clear", 2, {
        clear(WorldDeltaNamespace::scene_overlay, {-3, 8, 7}),
    })));
    VWB_EXPECT(!stone_in_column(store.pin()));
    VWB_EXPECT(stone_in_column(durable));
    VWB_EXPECT(stone_in_column(with_second));
    VWB_EXPECT(!stone_in_column(empty));
    static_cast<void>(store.commit_typed_cells(transaction("column:effective-unmask", 3, {
        clear(WorldDeltaNamespace::scene_overlay, {-3, 5, 7}),
    })));
    VWB_EXPECT(stone_in_column(store.pin()));
}

VWB_TEST(world_delta_store_commits_typed_cells_sections_and_preserves_old_pins) {
    WorldDeltaStore store;
    const WorldDeltaPinnedSnapshot before = store.pin();
    const WorldDeltaCommitReceipt receipt = store.commit_typed_cells(transaction("delta:negative", 0, {
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
    VWB_EXPECT(!before.effective_typed_cell_at({-1, -16, -17}));
    const WorldDeltaPinnedSnapshot after = store.pin();
    VWB_EXPECT_EQ(1ULL, after.revision());
    const auto first = after.durable_terrain_at({-1, -16, -17});
    VWB_EXPECT(first.has_value());
    VWB_EXPECT_EQ(typed_from_legacy(stone(), {-1, -16, -17}, WorldDeltaNamespace::terrain_override), first.value());
    const auto second = after.durable_terrain_at({16, 0, 31});
    VWB_EXPECT(second.has_value());
    VWB_EXPECT_EQ(typed_from_legacy(air(), {16, 0, 31}, WorldDeltaNamespace::terrain_override), second.value());
}

VWB_TEST(world_delta_store_scene_overlay_wins_only_while_it_exists) {
    WorldDeltaStore store;
    const CellCoord target{4, 5, 6};
    static_cast<void>(store.commit_typed_cells(transaction("delta:durable", 0, {
        set(WorldDeltaNamespace::terrain_override, target, stone()),
    })));
    static_cast<void>(store.commit_typed_cells(transaction("delta:overlay", 1, {
        set(WorldDeltaNamespace::scene_overlay, target, water()),
    })));
    const WorldDeltaPinnedSnapshot overlay = store.pin();
    VWB_EXPECT_EQ(typed_from_legacy(stone(), target, WorldDeltaNamespace::terrain_override), overlay.durable_terrain_at(target).value());
    VWB_EXPECT_EQ(typed_from_legacy(water(), target, WorldDeltaNamespace::scene_overlay), overlay.scene_overlay_at(target).value());
    VWB_EXPECT_EQ(typed_from_legacy(water(), target, WorldDeltaNamespace::scene_overlay), overlay.effective_typed_cell_at(target).value());

    const auto clear_receipt = store.commit_typed_cells(transaction("delta:clear-overlay", 2, {
        clear(WorldDeltaNamespace::scene_overlay, target),
    }));
    VWB_EXPECT_EQ(WorldDeltaCommitStatus::committed, clear_receipt.status);
    VWB_EXPECT_EQ(3ULL, clear_receipt.revision);
    VWB_EXPECT_EQ(27U, clear_receipt.affected_sections.size());
    VWB_EXPECT((clear_receipt.affected_sections.front().section == CellCoord{-1, -1, -1}));
    VWB_EXPECT((clear_receipt.affected_sections.back().section == CellCoord{1, 1, 1}));
    const WorldDeltaPinnedSnapshot restored = store.pin();
    VWB_EXPECT(!restored.scene_overlay_at(target));
    VWB_EXPECT_EQ(typed_from_legacy(stone(), target, WorldDeltaNamespace::terrain_override), restored.effective_typed_cell_at(target).value());
}

VWB_TEST(world_delta_store_commits_lava_as_a_typed_delta_state) {
    WorldDeltaStore store;
    const CellCoord target{-16, -1, 16};
    const auto receipt = store.commit_typed_cells(transaction("delta:lava", 0, {
        set(WorldDeltaNamespace::terrain_override, target, lava()),
    }));
    VWB_EXPECT_EQ(WorldDeltaCommitStatus::committed, receipt.status);
    VWB_EXPECT_EQ(1ULL, receipt.revision);
    const auto value = store.pin().effective_typed_cell_at(target);
    VWB_EXPECT(value.has_value());
    VWB_EXPECT_EQ(typed_from_legacy(lava(), target, WorldDeltaNamespace::terrain_override), value.value());
}

VWB_TEST(world_delta_store_clear_removes_the_named_namespace_and_revision_bumps_once) {
    WorldDeltaStore store;
    const CellCoord target{0, 0, 0};
    static_cast<void>(store.commit_typed_cells(transaction("delta:set", 0, {
        set(WorldDeltaNamespace::terrain_override, target, stone()),
        set(WorldDeltaNamespace::scene_overlay, target, air()),
    })));
    const auto receipt = store.commit_typed_cells(transaction("delta:clear-durable", 1, {
        clear(WorldDeltaNamespace::terrain_override, target),
    }));
    VWB_EXPECT_EQ(2ULL, receipt.revision);
    const auto pin = store.pin();
    VWB_EXPECT(!pin.durable_terrain_at(target));
    VWB_EXPECT_EQ(typed_from_legacy(air(), target, WorldDeltaNamespace::scene_overlay), pin.effective_typed_cell_at(target).value());
    static_cast<void>(store.commit_typed_cells(transaction("delta:clear-overlay", 2, {
        clear(WorldDeltaNamespace::scene_overlay, target),
    })));
    VWB_EXPECT(!store.pin().effective_typed_cell_at(target));
}

VWB_TEST(world_delta_store_transaction_ids_are_order_independent_idempotent_and_conflict_strictly) {
    WorldDeltaStore store;
    const WorldTypedCellTransaction first = transaction("delta:stable", 0, {
        set(WorldDeltaNamespace::terrain_override, {17, 0, 0}, stone()),
        set(WorldDeltaNamespace::scene_overlay, {-1, 0, 0}, air()),
    });
    const auto committed = store.commit_typed_cells(first);
    const WorldTypedCellTransaction replayed_order = transaction("delta:stable", 0, {
        set(WorldDeltaNamespace::scene_overlay, {-1, 0, 0}, air()),
        set(WorldDeltaNamespace::terrain_override, {17, 0, 0}, stone()),
    });
    const auto replay = store.commit_typed_cells(replayed_order);
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
    static_cast<void>(store.commit_typed_cells(transaction("delta:set", 0, {
        set(WorldDeltaNamespace::terrain_override, target, stone()),
    })));
    const auto no_change = store.commit_typed_cells(transaction("delta:same", 1, {
        set(WorldDeltaNamespace::terrain_override, target, stone()),
        clear(WorldDeltaNamespace::scene_overlay, target),
    }));
    VWB_EXPECT_EQ(WorldDeltaCommitStatus::no_change, no_change.status);
    VWB_EXPECT_EQ(1ULL, no_change.revision);
    VWB_EXPECT(no_change.affected_sections.empty());
    const auto replay = store.commit_typed_cells(transaction("delta:same", 1, {
        clear(WorldDeltaNamespace::scene_overlay, target),
        set(WorldDeltaNamespace::terrain_override, target, stone()),
    }));
    VWB_EXPECT_EQ(WorldDeltaCommitStatus::idempotent_replay, replay.status);
    VWB_EXPECT_EQ(1ULL, store.revision());
}

VWB_TEST(world_delta_store_typed_patch_searches_an_occupied_later_cell_before_inserting) {
    WorldDeltaStore store;
    static_cast<void>(store.commit_typed_cells(transaction("delta:search-first", 0, {
        set(WorldDeltaNamespace::terrain_override, {1, 0, 0}, stone()),
    })));
    const WorldDeltaCommitReceipt receipt = store.commit_typed_cells(transaction("delta:search-before", 1, {
        set(WorldDeltaNamespace::terrain_override, {0, 0, 0}, air()),
    }));
    VWB_EXPECT_EQ(WorldDeltaCommitStatus::committed, receipt.status);
    VWB_EXPECT_EQ(2ULL, receipt.revision);
    VWB_EXPECT(store.pin().durable_terrain_at({0, 0, 0}).has_value());
    VWB_EXPECT(store.pin().durable_terrain_at({1, 0, 0}).has_value());
}

VWB_TEST(world_delta_store_validates_everything_before_mutating) {
    WorldDeltaStore store;
    const CellCoord target{1, 2, 3};
    expect_rejection(WorldDeltaRejectReason::invalid_transaction, transaction("delta:duplicate", 0, {
        set(WorldDeltaNamespace::terrain_override, target, stone()),
        clear(WorldDeltaNamespace::terrain_override, target),
    }), store);
    NativeCellState invalid = typed_from_legacy(stone(), target, WorldDeltaNamespace::terrain_override);
    invalid.density = -1.0;
    expect_rejection(WorldDeltaRejectReason::invalid_transaction, transaction("delta:invalid", 0, {
        {NativeCellStateNamespace::durable_terrain, target, WorldTypedCellOperationKind::set, invalid},
    }), store);
    expect_rejection(WorldDeltaRejectReason::invalid_transaction, transaction("delta:clear-state", 0, {
        {NativeCellStateNamespace::durable_terrain, target, WorldTypedCellOperationKind::clear,
            typed_from_legacy(air(), target, WorldDeltaNamespace::terrain_override)},
    }), store);
    expect_rejection(WorldDeltaRejectReason::invalid_transaction, transaction("", 0, {
        set(WorldDeltaNamespace::terrain_override, target, stone()),
    }), store);
    VWB_EXPECT_EQ(0ULL, store.revision());
    VWB_EXPECT(store.pin().durable_terrain_snapshot().records().empty());

    const auto committed = store.commit_typed_cells(transaction("delta:duplicate", 0, {
        set(WorldDeltaNamespace::terrain_override, target, stone()),
    }));
    VWB_EXPECT_EQ(WorldDeltaCommitStatus::committed, committed.status);
}

VWB_TEST(world_delta_store_rejects_stale_revisions_and_bounded_capacity_atomically) {
    WorldDeltaStore store(combined_test_limits(1U, 2U));
    expect_rejection(WorldDeltaRejectReason::revision_conflict, transaction("delta:stale", 1, {
        set(WorldDeltaNamespace::terrain_override, {0, 0, 0}, stone()),
    }), store);
    const auto first = store.commit_typed_cells(transaction("delta:first", 0, {
        set(WorldDeltaNamespace::terrain_override, {0, 0, 0}, stone()),
    }));
    VWB_EXPECT_EQ(1ULL, first.revision);
    expect_rejection(WorldDeltaRejectReason::capacity_exceeded, transaction("delta:full", 1, {
        set(WorldDeltaNamespace::terrain_override, {0, 0, 0}, air()),
        set(WorldDeltaNamespace::terrain_override, {1, 0, 0}, water()),
    }), store);
    const auto pin = store.pin();
    VWB_EXPECT_EQ(1ULL, pin.revision());
    VWB_EXPECT_EQ(typed_from_legacy(stone(), {0, 0, 0}, WorldDeltaNamespace::terrain_override), pin.effective_typed_cell_at({0, 0, 0}).value());
    VWB_EXPECT(!pin.effective_typed_cell_at({1, 0, 0}));
    static_cast<void>(store.commit_typed_cells(transaction("delta:no-change", 1, {
        set(WorldDeltaNamespace::terrain_override, {0, 0, 0}, stone()),
    })));
    expect_rejection(WorldDeltaRejectReason::capacity_exceeded, transaction("delta:over-ledger", 1, {
        clear(WorldDeltaNamespace::scene_overlay, {99, 0, 0}),
    }), store);
}

VWB_TEST(world_delta_store_rejects_invalid_limits_and_unknown_enums) {
    VWB_EXPECT_THROW(WorldDeltaRejected, WorldDeltaStore(combined_test_limits(0U, 1U)));
    VWB_EXPECT_THROW(WorldDeltaRejected, WorldDeltaStore(combined_test_limits(1U, 0U)));
    const WorldDeltaStoreLimits zero_resident = capacity_limits(
        0U, 0U, 0U, 0U, 1U, 0U, 1U);
    // Braces force construction; `WorldDeltaStore(zero_resident);` is a
    // most-vexing declaration inside the assertion lambda under MSVC.
    VWB_EXPECT_THROW(WorldDeltaRejected, WorldDeltaStore{zero_resident});
    VWB_EXPECT(!world_delta_store_fits_capacity({}, zero_resident));
    VWB_EXPECT_THROW(WorldDeltaRejected, WorldDeltaStore(capacity_limits(
        3U, 1U, 1U, 1U, 2U, 4U, 1U)));
    VWB_EXPECT_THROW(WorldDeltaRejected, WorldDeltaStore(capacity_limits(
        1U, 1U, 3U, 1U, 2U, 4U, 1U)));
    VWB_EXPECT_THROW(WorldDeltaRejected, WorldDeltaStore(capacity_limits(
        1U, 1U, 1U, 3U, 2U, 4U, 1U)));
    VWB_EXPECT_THROW(WorldDeltaRejected, WorldDeltaStore(capacity_limits(
        1U, 1U, 1U, 1U, 4U, 3U, 1U)));
    VWB_EXPECT_THROW(WorldDeltaRejected, WorldDeltaStore(capacity_limits(
        1U, 5U, 1U, 1U, 3U, 4U, 1U)));
    WorldDeltaStore store;
    expect_rejection(WorldDeltaRejectReason::invalid_transaction, transaction("delta:unknown-space", 0, {
        {static_cast<NativeCellStateNamespace>(255U), {0, 0, 0}, WorldTypedCellOperationKind::set,
            typed_from_legacy(stone(), {0, 0, 0}, WorldDeltaNamespace::terrain_override)},
    }), store);
    expect_rejection(WorldDeltaRejectReason::invalid_transaction, transaction("delta:unknown-kind", 0, {
        {NativeCellStateNamespace::durable_terrain, {0, 0, 0}, static_cast<WorldTypedCellOperationKind>(255U), std::nullopt},
    }), store);
}

VWB_TEST(world_delta_store_validates_all_typed_state_and_transaction_boundaries) {
    WorldDeltaStore store;
    const CellCoord target{0, 0, 0};
    expect_rejection(WorldDeltaRejectReason::invalid_transaction, transaction("delta:missing-state", 0, {
        {NativeCellStateNamespace::durable_terrain, target, WorldTypedCellOperationKind::set, std::nullopt},
    }), store);
    // The operation address is authoritative for the patch key; a full typed
    // value for a different cell must not be admitted under that key.
    NativeCellState mismatched_cell = typed_from_legacy(stone(), {1, 0, 0}, WorldDeltaNamespace::terrain_override);
    expect_rejection(WorldDeltaRejectReason::invalid_transaction, transaction("delta:mismatched-cell", 0, {
        {NativeCellStateNamespace::durable_terrain, target, WorldTypedCellOperationKind::set, mismatched_cell},
    }), store);
    expect_rejection(WorldDeltaRejectReason::invalid_transaction, transaction("delta:no-ops", 0, {}), store);
    expect_rejection(WorldDeltaRejectReason::invalid_transaction, transaction(std::string("delta\0nul", 9), 0, {
        set(WorldDeltaNamespace::terrain_override, target, stone()),
    }), store);

    NativeCellState invalid = typed_from_legacy(stone(), target, WorldDeltaNamespace::terrain_override);
    ++invalid.section.x;
    expect_rejection(WorldDeltaRejectReason::invalid_transaction, transaction("delta:forged-address", 0, {
        {NativeCellStateNamespace::durable_terrain, target, WorldTypedCellOperationKind::set, invalid},
    }), store);
    invalid = typed_from_legacy(stone(), target, WorldDeltaNamespace::terrain_override);
    invalid.density = std::numeric_limits<double>::infinity();
    expect_rejection(WorldDeltaRejectReason::invalid_transaction, transaction("delta:nonfinite", 0, {
        {NativeCellStateNamespace::durable_terrain, target, WorldTypedCellOperationKind::set, invalid},
    }), store);
    invalid = typed_from_legacy(stone(), target, WorldDeltaNamespace::terrain_override);
    invalid.block_id.reset();
    expect_rejection(WorldDeltaRejectReason::invalid_transaction, transaction("delta:missing-block-id", 0, {
        {NativeCellStateNamespace::durable_terrain, target, WorldTypedCellOperationKind::set, invalid},
    }), store);
    invalid = typed_from_legacy(stone(), target, WorldDeltaNamespace::terrain_override);
    invalid.edit_reason.reset();
    expect_rejection(WorldDeltaRejectReason::invalid_transaction, transaction("delta:missing-edit-reason", 0, {
        {NativeCellStateNamespace::durable_terrain, target, WorldTypedCellOperationKind::set, invalid},
    }), store);
    VWB_EXPECT_EQ(0ULL, store.revision());
}

VWB_TEST(world_delta_store_typed_receipt_values_have_strict_field_equality) {
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
    const auto receipt = store.commit_typed_cells(transaction("delta:ordering", 0, {
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
    const WorldDeltaPinnedSnapshot pin = store.pin();
    const auto &durable = pin.durable_terrain_snapshot().records();
    const auto &overlays = pin.scene_overlays();
    VWB_EXPECT_EQ(4U, durable.size());
    VWB_EXPECT_EQ(1U, overlays.size());
    VWB_EXPECT((durable[0].state.cell == CellCoord{0, 0, 0}));
    VWB_EXPECT((durable[1].state.cell == CellCoord{16, 0, 0}));
    VWB_EXPECT((durable[2].state.cell == CellCoord{16, 16, 0}));
    VWB_EXPECT((durable[3].state.cell == CellCoord{16, 0, 16}));
    VWB_EXPECT((overlays[0].state.cell == CellCoord{16, 16, 0}));
}

VWB_TEST(world_delta_store_invalidates_the_complete_negative_boundary_neighborhood_in_zyx_order) {
    WorldDeltaStore store;
    const auto receipt = store.commit_typed_cells(transaction("delta:negative-boundary", 0, {
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
    WorldDeltaStore store(combined_test_limits(
        1U, 1U, std::numeric_limits<std::uint64_t>::max()));
    VWB_EXPECT_EQ(std::numeric_limits<std::uint64_t>::max(), store.pin().revision());
    expect_rejection(WorldDeltaRejectReason::capacity_exceeded,
        transaction("delta:max-revision", std::numeric_limits<std::uint64_t>::max(), {
            set(WorldDeltaNamespace::terrain_override, {0, 0, 0}, stone()),
        }), store);
    VWB_EXPECT(store.pin().durable_terrain_snapshot().records().empty());
}

// Contract oracle for the forthcoming borrowed WDP1 cursor. These tests use
// the existing synchronous projection only as the independent digest oracle;
// the cursor must do its own bounded count, metadata-length, and emit passes.
VWB_TEST(world_delta_store_borrowed_projection_matches_durable_overlay_and_nested_metadata) {
    WorldDeltaStore store;
    NativeTypedWorldStateRecord nested = typed_stone({-1, 2, 3});
    nested.state.metadata = NativeValue::object({
        {"payload", NativeValue::array({NativeValue::null(), NativeValue::object({
            {"label", NativeValue::string("nested")},
            {"weight", NativeValue::number(7.5)},
        })})},
    });
    NativeTypedWorldStateRecord overlay = typed_overlay_without_persistence_metadata({-1, 2, 3});
    overlay.state.metadata = NativeValue::object({{"overlay", NativeValue::boolean(true)}});
    const auto admitted = store.admit_typed_state(typed_admission("wdp1:mixed", 0,
        {typed_stone({16, 0, 0}), typed_durable({15, 1, 15}), nested},
        {typed_overlay({0, 0, 16}), overlay}));
    VWB_EXPECT_EQ(WorldDeltaCommitStatus::committed, admitted.status);
    const WorldDeltaHorizontalBounds clipped{-16, 0, 32, 16};
    const WorldDeltaPinnedSnapshot pin = store.pin();
    VWB_EXPECT_EQ(3U, pin.durable_terrain_snapshot().records().size());
    VWB_EXPECT_EQ(2U, pin.scene_overlays().size());
    const Sha256Digest expected = pin.typed_projection_digest(clipped);

    BorrowedTypedProjectionCursor cursor;
    cursor.reset(clipped);
    VWB_EXPECT_EQ(BorrowedTypedProjectionCursor::Status::idle, cursor.status());
    constexpr std::uint64_t source_token = 0x574450310001ULL;
    const auto zero = store.advance_borrowed_projection(cursor, clipped, source_token, 0U);
    VWB_EXPECT_EQ(0U, zero.consumed_ops);
    VWB_EXPECT_EQ(BorrowedTypedProjectionCursor::Status::idle, cursor.status());
    const auto one = store.advance_borrowed_projection(cursor, clipped, source_token, 1U);
    VWB_EXPECT_EQ(1U, one.consumed_ops);
    VWB_EXPECT_EQ(BorrowedTypedProjectionCursor::Status::pending, cursor.status());
    const std::array<std::uint32_t, 8> quotas{0U, 1U, 2U, 3U, 7U, 8U, 31U, 64U};
    std::size_t resumed = 0U;
    for (std::size_t call = 0U;
         call < 200000U && cursor.status() == BorrowedTypedProjectionCursor::Status::pending;
         ++call) {
        const std::uint32_t offered = quotas[call % quotas.size()];
        const auto step = store.advance_borrowed_projection(cursor, clipped, source_token, offered);
        VWB_EXPECT(step.consumed_ops <= offered);
        VWB_EXPECT(step.consumed_ops <= 64U);
        if (step.consumed_ops != 0U) ++resumed;
    }
    VWB_EXPECT(resumed > 1U);
    VWB_EXPECT_EQ(BorrowedTypedProjectionCursor::Status::ready, cursor.status());
    VWB_EXPECT_EQ(expected, cursor.digest());
    const auto repeat = store.advance_borrowed_projection(cursor, clipped, source_token, 64U);
    VWB_EXPECT_EQ(BorrowedTypedProjectionCursor::Status::ready, repeat.status);
    VWB_EXPECT_EQ(0U, repeat.consumed_ops);
    VWB_EXPECT_EQ(expected, cursor.digest());
}

VWB_TEST(world_delta_store_borrowed_projection_clips_remote_records_without_reordering_local_layers) {
    WorldDeltaStore store;
    const auto admitted = store.admit_typed_state(typed_admission("wdp1:clip", 0,
        {typed_stone({16, 0, 0}), typed_stone({-1, 0, 0}), typed_durable({0, 1, 0})},
        {typed_overlay({16, 0, 0}), typed_overlay_without_persistence_metadata({-1, 0, 0})}));
    VWB_EXPECT_EQ(WorldDeltaCommitStatus::committed, admitted.status);
    const WorldDeltaHorizontalBounds clipped{-16, 0, 32, 16};
    const WorldDeltaHorizontalBounds wider{-16, 0, 48, 16};
    const Sha256Digest local_before = store.pin().typed_projection_digest(clipped);
    const Sha256Digest wide_before = store.pin().typed_projection_digest(wider);
    const auto changed = store.commit_typed_cells(transaction("wdp1:remote", 1, {
        set(WorldDeltaNamespace::terrain_override, {16, 0, 0}, water()),
        set(WorldDeltaNamespace::scene_overlay, {16, 0, 0}, stone()),
    }));
    VWB_EXPECT_EQ(WorldDeltaCommitStatus::committed, changed.status);
    VWB_EXPECT_EQ(local_before, store.pin().typed_projection_digest(clipped));
    VWB_EXPECT(!(wide_before == store.pin().typed_projection_digest(wider)));

    BorrowedTypedProjectionCursor cursor;
    cursor.reset(clipped);
    VWB_EXPECT_EQ(BorrowedTypedProjectionCursor::Status::idle, cursor.status());
    constexpr std::uint64_t token = 0x574450310002ULL;
    const auto begun = store.advance_borrowed_projection(cursor, clipped, token, 1U);
    VWB_EXPECT_EQ(1U, begun.consumed_ops);
    VWB_EXPECT_EQ(BorrowedTypedProjectionCursor::Status::pending, cursor.status());
    for (std::size_t call = 0U;
         call < 200000U && cursor.status() == BorrowedTypedProjectionCursor::Status::pending;
         ++call) {
        const std::uint32_t offered = (call % 3U == 0U) ? 1U : 64U;
        const auto step = store.advance_borrowed_projection(cursor, clipped, token, offered);
        VWB_EXPECT(step.consumed_ops <= offered);
    }
    VWB_EXPECT_EQ(BorrowedTypedProjectionCursor::Status::ready, cursor.status());
    VWB_EXPECT_EQ(local_before, cursor.digest());
}

VWB_TEST(world_delta_store_borrowed_projection_rejects_changed_source_token_midstream) {
    WorldDeltaStore store;
    const auto admitted = store.admit_typed_state(typed_admission("wdp1:token", 0,
        {typed_stone({0, 0, 0})}));
    VWB_EXPECT_EQ(WorldDeltaCommitStatus::committed, admitted.status);
    const WorldDeltaHorizontalBounds bounds{0, 0, 16, 16};
    BorrowedTypedProjectionCursor cursor;
    cursor.reset(bounds);
    const auto started = store.advance_borrowed_projection(cursor, bounds, 41U, 64U);
    VWB_EXPECT(started.consumed_ops > 0U);
    VWB_EXPECT_EQ(BorrowedTypedProjectionCursor::Status::pending, cursor.status());
    const auto changed = store.commit_typed_cells(transaction("wdp1:token-change", 1, {
        set(WorldDeltaNamespace::scene_overlay, {0, 0, 0}, air()),
    }));
    VWB_EXPECT_EQ(WorldDeltaCommitStatus::committed, changed.status);
    const auto stale = store.advance_borrowed_projection(cursor, bounds, 42U, 64U);
    VWB_EXPECT_EQ(BorrowedTypedProjectionCursor::Status::source_changed, stale.status);
    VWB_EXPECT_EQ(BorrowedTypedProjectionCursor::Status::source_changed, cursor.status());
    VWB_EXPECT_THROW(std::logic_error, cursor.digest());

    cursor.reset(bounds);
    VWB_EXPECT_EQ(BorrowedTypedProjectionCursor::Status::idle, cursor.status());
    const auto begun = store.advance_borrowed_projection(cursor, bounds, 42U, 1U);
    VWB_EXPECT_EQ(1U, begun.consumed_ops);
    VWB_EXPECT_EQ(BorrowedTypedProjectionCursor::Status::pending, cursor.status());
    for (std::size_t call = 0U;
         call < 200000U && cursor.status() == BorrowedTypedProjectionCursor::Status::pending;
         ++call) {
        const auto step = store.advance_borrowed_projection(cursor, bounds, 42U, 64U);
        VWB_EXPECT(step.consumed_ops <= 64U);
    }
    VWB_EXPECT_EQ(BorrowedTypedProjectionCursor::Status::ready, cursor.status());
    VWB_EXPECT_EQ(store.pin().typed_projection_digest(bounds), cursor.digest());
}

VWB_TEST(world_delta_store_borrowed_projection_empty_durable_overlay_and_mixed_differential) {
    WorldDeltaStore store;
    BorrowedTypedProjectionCursor cursor;
    const WorldDeltaHorizontalBounds bounds{-17, -5, 19, 11};
    const Sha256Digest empty = expect_borrowed_projection_parity(store, cursor, bounds, 101U);
    VWB_EXPECT(store.pin().durable_terrain_snapshot().records().empty());
    VWB_EXPECT(store.pin().scene_overlays().empty());

    const auto durable = store.admit_typed_state(typed_admission("wdp1:durable-only", 0,
        {typed_stone({-17, 0, -5}), typed_durable({1, 1, 5}), typed_durable({2, 0, 5})}));
    VWB_EXPECT_EQ(WorldDeltaCommitStatus::committed, durable.status);
    VWB_EXPECT_EQ(3U, store.pin().durable_terrain_snapshot().records().size());
    VWB_EXPECT(store.pin().scene_overlays().empty());
    const Sha256Digest durable_digest = expect_borrowed_projection_parity(store, cursor, bounds, 102U);
    VWB_EXPECT(!(empty == durable_digest));

    const auto overlay = store.admit_typed_state(typed_admission("wdp1:overlay-only", 1, {},
        {typed_overlay({-17, 0, -5}), typed_overlay_without_persistence_metadata({1, 1, 5})}));
    VWB_EXPECT_EQ(WorldDeltaCommitStatus::committed, overlay.status);
    VWB_EXPECT(store.pin().durable_terrain_snapshot().records().empty());
    VWB_EXPECT_EQ(2U, store.pin().scene_overlays().size());
    const Sha256Digest overlay_digest = expect_borrowed_projection_parity(store, cursor, bounds, 103U);
    VWB_EXPECT(!(empty == overlay_digest));
    VWB_EXPECT(!(durable_digest == overlay_digest));

    const auto mixed = store.admit_typed_state(typed_admission("wdp1:mixed-matrix", 2,
        {typed_stone({-17, 0, -5}), typed_durable({1, 1, 5})},
        {typed_overlay_without_persistence_metadata({-17, 0, -5}), typed_overlay({1, 1, 5})}));
    VWB_EXPECT_EQ(WorldDeltaCommitStatus::committed, mixed.status);
    VWB_EXPECT_EQ(2U, store.pin().durable_terrain_snapshot().records().size());
    VWB_EXPECT_EQ(2U, store.pin().scene_overlays().size());
    const Sha256Digest mixed_digest = expect_borrowed_projection_parity(store, cursor, bounds, 104U);
    VWB_EXPECT(!(mixed_digest == empty));
    VWB_EXPECT(!(mixed_digest == durable_digest));
    VWB_EXPECT(!(mixed_digest == overlay_digest));
}

VWB_TEST(world_delta_store_borrowed_projection_reset_reuse_respects_negative_unaligned_edges) {
    WorldDeltaStore store;
    const WorldDeltaHorizontalBounds bounds{-17, -5, 19, 11}; // x in [-17,2), z in [-5,6)
    const auto admitted = store.admit_typed_state(typed_admission("wdp1:unaligned", 0,
        {typed_stone({-17, 0, -5}), typed_durable({1, 0, 5}),
            typed_stone({2, 0, 5}), typed_stone({-18, 0, -5}), typed_stone({1, 0, 6})},
        {typed_overlay_without_persistence_metadata({-17, 0, -5})}));
    VWB_EXPECT_EQ(WorldDeltaCommitStatus::committed, admitted.status);
    BorrowedTypedProjectionCursor cursor;
    const Sha256Digest first = expect_borrowed_projection_parity(store, cursor, bounds, 201U);

    // Changing the first excluded X coordinate leaves the exact same-bounds
    // projection unchanged, although the global store revision advances.
    const auto remote = store.commit_typed_cells(transaction("wdp1:unaligned-remote", 1, {
        set(WorldDeltaNamespace::terrain_override, {2, 0, 5}, water()),
    }));
    VWB_EXPECT_EQ(WorldDeltaCommitStatus::committed, remote.status);
    VWB_EXPECT_EQ(first, expect_borrowed_projection_parity(store, cursor, bounds, 202U));

    const auto local = store.commit_typed_cells(transaction("wdp1:unaligned-local", 2, {
        set(WorldDeltaNamespace::terrain_override, {1, 0, 5}, lava()),
    }));
    VWB_EXPECT_EQ(WorldDeltaCommitStatus::committed, local.status);
    const Sha256Digest third = expect_borrowed_projection_parity(store, cursor, bounds, 203U);
    VWB_EXPECT(!(first == third));
}

VWB_TEST(world_delta_store_borrowed_projection_large_sparse_index_matches_pin_and_clips_remote_edit) {
    WorldDeltaStore store;
    std::vector<NativeTypedWorldStateRecord> rows;
    rows.reserve(1025U);
    for (std::int32_t index = 0; index <= 1024; ++index) {
        rows.push_back(typed_stone({(index - 512) * 257, index % 3, index % 7 - 3}));
    }
    const auto admitted = store.admit_typed_state(typed_admission("wdp1:sparse", 0, std::move(rows)));
    VWB_EXPECT_EQ(WorldDeltaCommitStatus::committed, admitted.status);
    VWB_EXPECT_EQ(1025U, store.pin().durable_terrain_snapshot().records().size());
    const WorldDeltaHorizontalBounds bounds{-300, -4, 600, 9};
    BorrowedTypedProjectionCursor cursor;
    const Sha256Digest before = expect_borrowed_projection_parity(store, cursor, bounds, 301U);

    const auto remote = store.commit_typed_cells(transaction("wdp1:sparse-remote", 1, {
        set(WorldDeltaNamespace::terrain_override, {131584, 1, -1}, water()),
    }));
    VWB_EXPECT_EQ(WorldDeltaCommitStatus::committed, remote.status);
    VWB_EXPECT_EQ(before, expect_borrowed_projection_parity(store, cursor, bounds, 302U));
}

VWB_TEST(world_delta_store_borrowed_projection_nested_nv1_prefix_honors_three_four_atom_hint) {
    const NativeValue metadata = NativeValue::object({
        {"nested", NativeValue::array({NativeValue::object({
            {"leaf", NativeValue::string("value")},
        })})},
    });
    NativeValueCanonicalCursor direct;
    ProjectionByteSink sink;
    constexpr std::uint64_t token = 401U;
    std::size_t after_marker_hint = 0U;
    for (std::size_t marker = 0U; marker < 3U; ++marker) {
        const auto step = direct.advance(metadata, token, 1U, 64U, 64U, sink);
        VWB_EXPECT_EQ(1U, step.bytes_written);
        if (marker == 2U) after_marker_hint = step.next_atomic_units;
    }
    VWB_EXPECT_EQ((std::vector<std::uint8_t>{'N', 'V', '1'}), sink.bytes);
    // The next root phase costs two traversal units plus its tag byte.
    VWB_EXPECT_EQ(3U, after_marker_hint);
    const auto after_prefix = direct.advance(metadata, token, 0U, 64U, 64U, sink);
    VWB_EXPECT_EQ(0U, after_prefix.bytes_written);

    // An empty object root isolates the NV1 marker boundary: metadata_count adds one
    // sink atom (hint 4), while metadata_emit adds two (hint 5). Nested
    // metadata below is checked separately against the pinned digest.
    NativeTypedWorldStateRecord root = typed_stone({0, 0, 0});
    root.state.metadata = NativeValue::object({});
    WorldDeltaStore root_store;
    const auto admitted = root_store.admit_typed_state(typed_admission("wdp1:nv1-boundary", 0, {root}));
    VWB_EXPECT_EQ(WorldDeltaCommitStatus::committed, admitted.status);
    const WorldDeltaHorizontalBounds bounds{0, 0, 16, 16};
    const Sha256Digest expected = root_store.pin().typed_projection_digest(bounds);
    BorrowedTypedProjectionCursor cursor;
    cursor.reset(bounds);
    bool saw_count_boundary = false;
    bool saw_emit_boundary = false;
    for (std::size_t call = 0U;
         call < 200000U && cursor.status() != BorrowedTypedProjectionCursor::Status::ready;
         ++call) {
        const auto preview = root_store.advance_borrowed_projection(cursor, bounds, token, 0U);
        VWB_EXPECT_EQ(0U, preview.consumed_ops);
        if (!saw_count_boundary && preview.next_atomic_ops == 4U) {
            const auto blocked = root_store.advance_borrowed_projection(cursor, bounds, token, 3U);
            VWB_EXPECT_EQ(BorrowedTypedProjectionCursor::Status::pending, blocked.status);
            VWB_EXPECT_EQ(0U, blocked.consumed_ops);
            VWB_EXPECT_EQ(4U, blocked.next_atomic_ops);
            const auto resumed = root_store.advance_borrowed_projection(cursor, bounds, token, 4U);
            VWB_EXPECT(resumed.consumed_ops > 0U && resumed.consumed_ops <= 4U);
            saw_count_boundary = true;
        } else if (saw_count_boundary && !saw_emit_boundary && preview.next_atomic_ops == 5U) {
            const auto blocked = root_store.advance_borrowed_projection(cursor, bounds, token, 4U);
            VWB_EXPECT_EQ(BorrowedTypedProjectionCursor::Status::pending, blocked.status);
            VWB_EXPECT_EQ(0U, blocked.consumed_ops);
            VWB_EXPECT_EQ(5U, blocked.next_atomic_ops);
            const auto resumed = root_store.advance_borrowed_projection(cursor, bounds, token, 5U);
            VWB_EXPECT(resumed.consumed_ops > 0U && resumed.consumed_ops <= 5U);
            saw_emit_boundary = true;
        } else {
            const auto step = root_store.advance_borrowed_projection(
                cursor, bounds, token, std::max(1U, preview.next_atomic_ops));
            VWB_EXPECT(step.consumed_ops <= std::max(1U, preview.next_atomic_ops));
        }
        VWB_EXPECT(cursor.status() == BorrowedTypedProjectionCursor::Status::pending
            || cursor.status() == BorrowedTypedProjectionCursor::Status::ready);
    }
    VWB_EXPECT(saw_count_boundary);
    VWB_EXPECT(saw_emit_boundary);
    VWB_EXPECT_EQ(BorrowedTypedProjectionCursor::Status::ready, cursor.status());
    VWB_EXPECT_EQ(expected, cursor.digest());

    NativeTypedWorldStateRecord nested = typed_stone({0, 0, 0});
    nested.state.metadata = metadata;
    WorldDeltaStore nested_store;
    const auto nested_admitted = nested_store.admit_typed_state(
        typed_admission("wdp1:nested-nv1", 0, {nested}));
    VWB_EXPECT_EQ(WorldDeltaCommitStatus::committed, nested_admitted.status);
    VWB_EXPECT_EQ(nested_store.pin().typed_projection_digest(bounds),
        expect_borrowed_projection_parity(nested_store, cursor, bounds, token + 1U));
}

} // namespace voxel::world_backend::tests
