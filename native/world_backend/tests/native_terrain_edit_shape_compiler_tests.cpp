#include "test_harness.hpp"

#include "../core/native_terrain_edit_shape_compiler.hpp"

#include <algorithm>
#include <cmath>
#include <cstdint>
#include <cstring>
#include <limits>
#include <optional>
#include <string>
#include <utility>
#include <vector>

using namespace voxel::world_backend;

namespace {

NativeCellState cell_state(
    const CellCoord cell,
    const TerrainMaterialId material,
    const bool solid,
    const double density,
    const std::string &reason = {},
    NativeValue metadata = NativeValue::object({}),
    const bool generated = true,
    std::optional<NativeBlockIdentity> block_id = std::nullopt,
    const TerrainFluidId fluid = TerrainFluidId::none) {
    NativeCellStateInput input;
    input.cell = cell;
    input.material = material;
    input.biome = TerrainBiomeId::forest;
    input.solid = solid;
    input.density = density;
    input.fluid = fluid;
    input.light = {solid ? std::uint8_t{0} : std::uint8_t{15}, 0};
    input.metadata = std::move(metadata);
    input.block_id = std::move(block_id);
    input.edit_reason = generated ? std::nullopt : std::optional<std::string>(reason);
    input.generated = generated;
    input.edited = !generated;
    return make_native_cell_state(input);
}

class FakePinnedSource final : public NativeTerrainEditPinnedSource {
public:
    enum class Fallback : std::uint8_t { solid_stone, air, missing };

    explicit FakePinnedSource(const Fallback fallback = Fallback::solid_stone)
        : fallback_(fallback) {
        digest_[0] = 0xa5U;
        digest_[31] = 0x5aU;
    }

    Sha256Digest snapshot_digest() const noexcept override { return digest_; }
    std::uint64_t source_revision() const noexcept override { return revision_; }

    std::optional<NativeCellState> cell_at(const CellCoord &cell) const override {
        ++reads_;
        for (const NativeCellState &value : overrides_) {
            if (value.cell == cell) {
                if (mismatch_) {
                    NativeCellStateInput input;
                    input.cell = {cell.x + 1, cell.y, cell.z};
                    input.material = value.material;
                    input.biome = value.biome;
                    input.solid = value.solid;
                    input.density = value.density;
                    input.fluid = value.fluid;
                    input.light = value.light;
                    input.metadata = value.metadata;
                    input.generated = true;
                    input.edited = false;
                    return make_native_cell_state(input);
                }
                return value;
            }
        }
        if (fallback_ == Fallback::missing) return std::nullopt;
        if (fallback_ == Fallback::air) {
            return cell_state(cell, TerrainMaterialId::air, false, -1.0);
        }
        return cell_state(cell, TerrainMaterialId::stone, true, 1.0,
            {}, NativeValue::object({{"source", NativeValue::string("generated")}}));
    }

    void add(NativeCellState state) { overrides_.push_back(std::move(state)); }
    void mismatch(const bool value) { mismatch_ = value; }
    void revision(const std::uint64_t value) { revision_ = value; }
    std::size_t read_count() const noexcept { return reads_; }

private:
    Fallback fallback_;
    Sha256Digest digest_{};
    std::vector<NativeCellState> overrides_;
    bool mismatch_ = false;
    mutable std::size_t reads_ = 0;
    std::uint64_t revision_ = 73U;
};

class DriftingPinnedSource final : public NativeTerrainEditPinnedSource {
public:
    enum class Drift : std::uint8_t { digest, revision };

    explicit DriftingPinnedSource(const Drift drift) : drift_(drift) {}

    Sha256Digest snapshot_digest() const noexcept override {
        Sha256Digest digest{};
        digest[0] = drift_ == Drift::digest && reads_ != 0U ? 2U : 1U;
        return digest;
    }
    std::uint64_t source_revision() const noexcept override {
        return drift_ == Drift::revision && reads_ != 0U ? 11U : 10U;
    }
    std::optional<NativeCellState> cell_at(const CellCoord &cell) const override {
        ++reads_;
        return cell_state(cell, TerrainMaterialId::air, false, -1.0);
    }

private:
    Drift drift_;
    mutable std::size_t reads_ = 0;
};

NativeTerrainEditStateTemplate stone_template(const double density = 1.0) {
    NativeTerrainEditStateTemplate target;
    target.material = TerrainMaterialId::stone;
    target.biome = TerrainBiomeId::forest;
    target.solid = true;
    target.density = density;
    target.light = NativeCellLight{0, 0};
    target.metadata = NativeValue::object({{"saveDelta", NativeValue::boolean(false)}});
    return target;
}

NativeTerrainEditStateTemplate air_template() {
    NativeTerrainEditStateTemplate target;
    target.material = TerrainMaterialId::air;
    target.biome = TerrainBiomeId::forest;
    target.solid = false;
    target.density = -1.0;
    target.light = NativeCellLight{15, 0};
    target.metadata = NativeValue::object({{"source", NativeValue::string("player_dig")}});
    return target;
}

NativeTerrainEditCompileRequest request_without_filter(std::vector<NativeTerrainEditShape> shapes) {
    NativeTerrainEditCompileRequest request;
    request.cell_size = 1.0;
    request.shapes = std::move(shapes);
    request.omit_unchanged = false;
    return request;
}

void expect_reason(
    const NativeTerrainEditCompileRejectReason expected,
    const NativeTerrainEditCompileRequest &request) {
    try {
        static_cast<void>(NativeTerrainEditShapeCompiler::compile(request));
    } catch (const NativeTerrainEditCompileRejected &error) {
        VWB_EXPECT_EQ(expected, error.reason());
        return;
    }
    VWB_EXPECT(false);
}

const NativeValue *metadata_value(const NativeValue &metadata, const std::string &key) {
    const auto &object = metadata.as_object();
    const auto found = std::find_if(object.begin(), object.end(), [&key](const auto &entry) {
        return entry.first == key;
    });
    return found == object.end() ? nullptr : &found->second;
}

std::uint64_t double_bits(const double value) {
    std::uint64_t result = 0;
    static_assert(sizeof(result) == sizeof(value));
    std::memcpy(&result, &value, sizeof(result));
    return result;
}

} // namespace

VWB_TEST(native_terrain_edit_box_is_inclusive_reorders_negative_endpoints_and_emits_v2_transaction) {
    NativeTerrainEditStateTemplate target = stone_template(2.25);
    target.block_id = NativeBlockIdentity::create("foundation.stone");
    const NativeTerrainEditCompiledBatch batch = NativeTerrainEditShapeCompiler::compile(request_without_filter({
        NativeTerrainEditShape::inclusive_box({1, 0, 1}, {-1, -1, 0}, target, "structure_foundation:test"),
    }));
    const auto &operations = batch.compiled_operations();
    VWB_EXPECT_EQ(12U, operations.size());
    VWB_EXPECT((operations.front().operation.cell == CellCoord{-1, -1, 0}));
    VWB_EXPECT((operations[1].operation.cell == CellCoord{0, -1, 0}));
    VWB_EXPECT((operations[3].operation.cell == CellCoord{-1, 0, 0}));
    VWB_EXPECT((operations.back().operation.cell == CellCoord{1, 0, 1}));
    for (const auto &operation : operations) {
        VWB_EXPECT_EQ(NativeCellStateNamespace::durable_terrain, operation.operation.name_space);
        VWB_EXPECT_EQ(WorldTypedCellOperationKind::set, operation.operation.kind);
        VWB_EXPECT(operation.operation.state.has_value());
        VWB_EXPECT_EQ(std::string("foundation.stone"), operation.operation.state->block_id->value());
        VWB_EXPECT_EQ(std::string("structure_foundation:test"), *operation.operation.state->edit_reason);
        VWB_EXPECT_EQ(NativeTerrainEditCellClassification::direct_target, operation.classification);
    }
    const auto &summary = batch.summary();
    VWB_EXPECT_EQ(1U, summary.shape_count);
    VWB_EXPECT_EQ(12U, summary.candidate_visits);
    VWB_EXPECT_EQ(12U, summary.unique_cells_before_filter);
    VWB_EXPECT_EQ(12U, summary.emitted_operations);
    VWB_EXPECT_EQ(12U, summary.direct_target_operations);
    VWB_EXPECT_EQ(0U, summary.excavation_boundary_operations);
    VWB_EXPECT_EQ(12U, summary.solid_operations);
    VWB_EXPECT_EQ(0U, summary.nonsolid_operations);
    VWB_EXPECT_EQ(1U, summary.material_counts.size());
    VWB_EXPECT_EQ(TerrainMaterialId::stone, summary.material_counts[0].material);
    VWB_EXPECT_EQ(12U, summary.material_counts[0].count);
    VWB_EXPECT(!summary.source_pinned);
    VWB_EXPECT(!summary.source_transition_summary_available);
    VWB_EXPECT_EQ(0U, summary.changed_cells);
    VWB_EXPECT(summary.changed_columns.empty());
    VWB_EXPECT(summary.removed_material_counts.empty());

    const WorldTypedCellTransaction transaction = batch.make_transaction("shape:box", 42U);
    VWB_EXPECT_EQ(std::string("shape:box"), transaction.transaction_id);
    VWB_EXPECT_EQ(42U, transaction.expected_revision);
    VWB_EXPECT_EQ(operations.size(), transaction.operations.size());
}

VWB_TEST(native_terrain_edit_template_defaults_derive_solidity_density_and_light_after_material) {
    NativeTerrainEditStateTemplate stone;
    stone.material = TerrainMaterialId::stone;
    NativeTerrainEditStateTemplate air;
    air.material = TerrainMaterialId::air;
    const NativeTerrainEditCompiledBatch batch = NativeTerrainEditShapeCompiler::compile(request_without_filter({
        NativeTerrainEditShape::inclusive_box({0, 0, 0}, {0, 0, 0}, stone, ""),
        NativeTerrainEditShape::inclusive_box({1, 0, 0}, {1, 0, 0}, air, ""),
    }));
    const NativeCellState &solid = *batch.compiled_operations()[0].operation.state;
    VWB_EXPECT(solid.solid);
    VWB_EXPECT_EQ(1.0, solid.density);
    VWB_EXPECT_EQ(0U, solid.light.sky);
    VWB_EXPECT_EQ(0U, solid.light.block);
    VWB_EXPECT(solid.edit_reason.has_value());
    VWB_EXPECT_EQ(std::string(""), *solid.edit_reason);
    const NativeCellState &empty = *batch.compiled_operations()[1].operation.state;
    VWB_EXPECT(!empty.solid);
    VWB_EXPECT_EQ(-1.0, empty.density);
    VWB_EXPECT_EQ(15U, empty.light.sky);
    VWB_EXPECT_EQ(0U, empty.light.block);
}

VWB_TEST(native_terrain_edit_nonpositive_sphere_is_empty_before_state_or_source_validation) {
    NativeTerrainEditStateTemplate invalid;
    invalid.material = static_cast<TerrainMaterialId>(255U);
    NativeTerrainEditCompileRequest request = request_without_filter({
        NativeTerrainEditShape::sphere(
            {std::numeric_limits<double>::infinity(), 0.0, 0.0}, 0.0, invalid, std::string("bad\0id", 6)),
        NativeTerrainEditShape::sphere(
            {0.0, std::numeric_limits<double>::quiet_NaN(), 0.0}, -1.0, invalid, ""),
        NativeTerrainEditShape::sphere(
            {0.0, 0.0, 0.0}, -std::numeric_limits<double>::infinity(), invalid, ""),
    });
    const NativeTerrainEditCompiledBatch batch = NativeTerrainEditShapeCompiler::compile(request);
    VWB_EXPECT(batch.compiled_operations().empty());
    VWB_EXPECT_EQ(3U, batch.summary().shape_count);
    VWB_EXPECT_EQ(0U, batch.summary().candidate_visits);
    VWB_EXPECT_EQ(0U, batch.summary().emitted_operations);
}

VWB_TEST(native_terrain_edit_shapes_are_later_wins_unique_and_changed_only_against_exact_pin) {
    FakePinnedSource source(FakePinnedSource::Fallback::air);
    source.add(cell_state({0, 0, 0}, TerrainMaterialId::air, false, -1.0, "second",
        NativeValue::object({{"source", NativeValue::string("player_dig")}}), false,
        NativeBlockIdentity::create("air")));
    NativeTerrainEditCompileRequest request;
    request.cell_size = 1.0;
    request.source = &source;
    request.shapes = {
        NativeTerrainEditShape::inclusive_box({0, 0, 0}, {1, 0, 0}, stone_template(), "first"),
        NativeTerrainEditShape::inclusive_box({0, 0, 0}, {0, 0, 0}, air_template(), "second"),
    };
    const NativeTerrainEditCompiledBatch batch = NativeTerrainEditShapeCompiler::compile(request);
    VWB_EXPECT_EQ(1U, batch.compiled_operations().size());
    const auto &operation = batch.compiled_operations()[0];
    VWB_EXPECT((operation.operation.cell == CellCoord{1, 0, 0}));
    VWB_EXPECT_EQ(std::string("first"), operation.provenance_id);
    VWB_EXPECT_EQ(0U, operation.source_shape_index);
    VWB_EXPECT_EQ(3U, batch.summary().candidate_visits);
    VWB_EXPECT_EQ(2U, batch.summary().unique_cells_before_filter);
    VWB_EXPECT_EQ(1U, batch.summary().coincident_overwrites);
    VWB_EXPECT_EQ(1U, batch.summary().unchanged_filtered);
    VWB_EXPECT(batch.summary().source_pinned);
    VWB_EXPECT_EQ(73U, batch.summary().source_revision);
    VWB_EXPECT_EQ(0xa5U, batch.summary().source_snapshot_digest[0]);
    VWB_EXPECT_EQ(0x5aU, batch.summary().source_snapshot_digest[31]);
}

VWB_TEST(native_terrain_edit_pinned_transaction_binds_revision_and_real_store_rejects_post_compile_drift) {
    FakePinnedSource source(FakePinnedSource::Fallback::air);
    source.revision(0U);
    NativeTerrainEditCompileRequest request;
    request.cell_size = 1.0;
    request.source = &source;
    request.shapes = {NativeTerrainEditShape::inclusive_box(
        {0, 0, 0}, {0, 0, 0}, stone_template(), "pinned-store")};
    const NativeTerrainEditCompiledBatch batch = NativeTerrainEditShapeCompiler::compile(request);

    WorldDeltaStore store;
    const WorldDeltaCommitReceipt exact = store.commit_typed_cells(
        batch.make_transaction("pinned:exact", 0U));
    VWB_EXPECT_EQ(WorldDeltaCommitStatus::committed, exact.status);
    VWB_EXPECT_EQ(1U, exact.revision);
    VWB_EXPECT_EQ(1U, store.revision());
    VWB_EXPECT(store.pin().durable_terrain_at({0, 0, 0}).has_value());

    try {
        static_cast<void>(batch.make_transaction("pinned:relabeled", 1U));
        VWB_EXPECT(false);
    } catch (const NativeTerrainEditCompileRejected &error) {
        VWB_EXPECT_EQ(NativeTerrainEditCompileRejectReason::source_revision_mismatch, error.reason());
    }
    VWB_EXPECT_EQ(1U, store.revision());

    const WorldTypedCellTransaction stale = batch.make_transaction("pinned:after-store-drift", 0U);
    try {
        static_cast<void>(store.commit_typed_cells(stale));
        VWB_EXPECT(false);
    } catch (const WorldDeltaRejected &error) {
        VWB_EXPECT_EQ(WorldDeltaRejectReason::revision_conflict, error.reason());
    }
    VWB_EXPECT_EQ(1U, store.revision());
}

VWB_TEST(native_terrain_edit_transition_summary_counts_final_removals_once_and_reuses_source_reads) {
    FakePinnedSource source(FakePinnedSource::Fallback::solid_stone);
    source.add(cell_state({0, 0, 0}, TerrainMaterialId::stone, true, 1.0));
    source.add(cell_state({1, 0, 0}, TerrainMaterialId::dirt, true, 1.0));
    source.add(cell_state({2, 0, 0}, TerrainMaterialId::stone, true, 1.0));
    source.add(cell_state({3, 0, 0}, TerrainMaterialId::air, false, -1.0, "dig",
        NativeValue::object({{"source", NativeValue::string("player_dig")}}), false,
        NativeBlockIdentity::create("air")));

    NativeTerrainEditCompileRequest request;
    request.cell_size = 1.0;
    request.source = &source;
    request.shapes = {
        NativeTerrainEditShape::inclusive_box({0, 0, 0}, {3, 0, 0}, air_template(), "dig"),
        NativeTerrainEditShape::inclusive_box({1, 0, 0}, {1, 0, 0}, stone_template(), "fill"),
        NativeTerrainEditShape::inclusive_box({0, 0, 0}, {0, 0, 0}, air_template(), "dig"),
    };
    const NativeTerrainEditCompiledBatch batch = NativeTerrainEditShapeCompiler::compile(request);
    const auto &summary = batch.summary();
    VWB_EXPECT(summary.source_transition_summary_available);
    VWB_EXPECT_EQ(3U, summary.changed_cells);
    VWB_EXPECT_EQ(3U, summary.changed_columns.size());
    VWB_EXPECT((summary.changed_columns[0] == NativeTerrainEditColumn{0, 0}));
    VWB_EXPECT((summary.changed_columns[1] == NativeTerrainEditColumn{1, 0}));
    VWB_EXPECT((summary.changed_columns[2] == NativeTerrainEditColumn{2, 0}));
    VWB_EXPECT_EQ(1U, summary.removed_material_counts.size());
    VWB_EXPECT_EQ(TerrainMaterialId::stone, summary.removed_material_counts[0].material);
    VWB_EXPECT_EQ(2U, summary.removed_material_counts[0].count);
    VWB_EXPECT_EQ(1U, summary.unchanged_filtered);
    VWB_EXPECT_EQ(3U, summary.emitted_operations);
    VWB_EXPECT_EQ(4U, source.read_count());
}

VWB_TEST(native_terrain_edit_air_sphere_matches_inclusive_boundary_negative_bounds_and_solid_shell) {
    FakePinnedSource source;
    NativeTerrainEditCompileRequest request;
    request.cell_size = 1.0;
    request.source = &source;
    request.omit_unchanged = false;
    NativeTerrainEditStateTemplate deferred_air = air_template();
    deferred_air.metadata = NativeValue::object({
        {"deferSkyLight", NativeValue::boolean(true)},
        {"source", NativeValue::string("player_dig")},
    });
    request.shapes = {NativeTerrainEditShape::sphere(
        {-0.5, -0.5, -0.5}, 1.0, deferred_air, "dig:negative-boundary")};
    const NativeTerrainEditCompiledBatch batch = NativeTerrainEditShapeCompiler::compile(request);
    const auto &summary = batch.summary();
    VWB_EXPECT_EQ(216U, summary.candidate_visits);
    VWB_EXPECT_EQ(7U, summary.direct_target_operations);
    VWB_EXPECT(summary.excavation_boundary_operations > 0U);
    VWB_EXPECT_EQ(summary.emitted_operations,
        summary.direct_target_operations + summary.excavation_boundary_operations);
    VWB_EXPECT_EQ(7U, summary.nonsolid_operations);
    VWB_EXPECT_EQ(summary.excavation_boundary_operations, summary.solid_operations);
    VWB_EXPECT_EQ(2U, summary.material_counts.size());
    VWB_EXPECT_EQ(TerrainMaterialId::air, summary.material_counts[0].material);
    VWB_EXPECT_EQ(TerrainMaterialId::stone, summary.material_counts[1].material);

    std::size_t exact_boundary = 0;
    std::size_t shell_with_defer = 0;
    for (const auto &compiled : batch.compiled_operations()) {
        const NativeCellState &state = *compiled.operation.state;
        if (compiled.classification == NativeTerrainEditCellClassification::direct_target
            && state.density == 0.0) {
            ++exact_boundary;
        }
        const NativeValue *direct_defer = metadata_value(state.metadata, "deferSkyLight");
        VWB_EXPECT(direct_defer != nullptr && direct_defer->as_boolean());
        if (compiled.classification == NativeTerrainEditCellClassification::excavation_boundary) {
            const NativeValue *source_value = metadata_value(state.metadata, "source");
            const NativeValue *defer_value = metadata_value(state.metadata, "deferSkyLight");
            VWB_EXPECT(source_value != nullptr);
            VWB_EXPECT_EQ(std::string("excavation_boundary"), source_value->as_string());
            VWB_EXPECT(defer_value != nullptr && defer_value->as_boolean());
            VWB_EXPECT(state.density >= 0.05 && state.density <= 1.35);
            ++shell_with_defer;
        }
    }
    VWB_EXPECT_EQ(6U, exact_boundary);
    VWB_EXPECT_EQ(summary.excavation_boundary_operations, shell_with_defer);
}

VWB_TEST(native_terrain_edit_sphere_matches_godot_4_6_1_float32_vector_bit_oracle) {
    // Fixed independently by Godot 4.6.1 stable (14d19694e) using the exact
    // production expressions: Vector3 cell-center construction,
    // distance_squared_to(), sqrt(), and sphere_edit_density(). This case is
    // intentionally far from the origin so binary64 geometry would disagree.
    FakePinnedSource source;
    NativeTerrainEditCompileRequest request;
    request.cell_size = 1.35;
    request.source = &source;
    request.omit_unchanged = false;
    request.shapes = {NativeTerrainEditShape::sphere(
        {1'350'000.625, -1'350'000.375, 675'000.3125}, 1.35,
        air_template(), "godot-float32-oracle")};
    const NativeTerrainEditCompiledBatch batch = NativeTerrainEditShapeCompiler::compile(request);
    struct Expected {
        CellCoord cell;
        NativeTerrainEditCellClassification classification;
        std::uint64_t density_bits;
    };
    const std::vector<Expected> expected = {
        {{1'000'000, -1'000'001, 500'000}, NativeTerrainEditCellClassification::direct_target,
            UINT64_C(0xbfecc71d9102863a)},
        {{1'000'001, -1'000'001, 500'000}, NativeTerrainEditCellClassification::excavation_boundary,
            UINT64_C(0x3fb8d3a7e9907240)},
        {{999'999, -1'000'001, 500'000}, NativeTerrainEditCellClassification::direct_target,
            UINT64_C(0xbf95bdc831b25900)},
        {{1'000'000, -1'000'002, 500'000}, NativeTerrainEditCellClassification::excavation_boundary,
            UINT64_C(0x3fd45553f806ba78)},
    };
    for (const Expected &oracle : expected) {
        const auto found = std::find_if(batch.compiled_operations().begin(), batch.compiled_operations().end(),
            [&oracle](const auto &compiled) { return compiled.operation.cell == oracle.cell; });
        VWB_EXPECT(found != batch.compiled_operations().end());
        VWB_EXPECT_EQ(oracle.classification, found->classification);
        VWB_EXPECT_EQ(oracle.density_bits, double_bits(found->operation.state->density));
    }
}

VWB_TEST(native_terrain_edit_sphere_reads_prior_coincident_state_and_skips_air_shell) {
    FakePinnedSource source(FakePinnedSource::Fallback::air);
    NativeTerrainEditCompileRequest request;
    request.cell_size = 1.0;
    request.source = &source;
    request.omit_unchanged = false;
    request.shapes = {
        NativeTerrainEditShape::inclusive_box({1, 0, 0}, {1, 0, 0}, stone_template(), "prior-solid"),
        NativeTerrainEditShape::sphere({0.5, 0.5, 0.5}, 0.4, air_template(), "dig:small"),
    };
    const NativeTerrainEditCompiledBatch batch = NativeTerrainEditShapeCompiler::compile(request);
    VWB_EXPECT_EQ(2U, batch.compiled_operations().size());
    VWB_EXPECT_EQ(1U, batch.summary().excavation_boundary_operations);
    const auto found = std::find_if(batch.compiled_operations().begin(), batch.compiled_operations().end(),
        [](const auto &operation) { return operation.operation.cell == CellCoord{1, 0, 0}; });
    VWB_EXPECT(found != batch.compiled_operations().end());
    VWB_EXPECT_EQ(NativeTerrainEditCellClassification::excavation_boundary, found->classification);
    VWB_EXPECT_EQ(std::string("dig:small"), found->provenance_id);
}

VWB_TEST(native_terrain_edit_sphere_uses_godot_truthiness_for_deferred_skylight) {
    FakePinnedSource source;
    const std::vector<std::pair<NativeValue, bool>> cases = {
        {NativeValue::null(), false},
        {NativeValue::boolean(false), false},
        {NativeValue::boolean(true), true},
        {NativeValue::number(0.0), false},
        {NativeValue::number(-1.0), true},
        {NativeValue::string(""), false},
        {NativeValue::string("true"), true},
        {NativeValue::array({}), false},
        {NativeValue::array({NativeValue::null()}), true},
        {NativeValue::object({}), false},
        {NativeValue::object({{"value", NativeValue::null()}}), true},
    };
    for (const auto &entry : cases) {
        NativeTerrainEditStateTemplate target = air_template();
        target.metadata = NativeValue::object({
            {"deferSkyLight", entry.first},
            {"source", NativeValue::string("player_dig")},
        });
        NativeTerrainEditCompileRequest request;
        request.cell_size = 1.0;
        request.source = &source;
        request.omit_unchanged = false;
        request.shapes = {NativeTerrainEditShape::sphere(
            {0.5, 0.5, 0.5}, 0.2, target, "truthy-defer")};
        const NativeTerrainEditCompiledBatch batch = NativeTerrainEditShapeCompiler::compile(request);
        const auto shell = std::find_if(batch.compiled_operations().begin(), batch.compiled_operations().end(),
            [](const auto &compiled) {
                return compiled.classification == NativeTerrainEditCellClassification::excavation_boundary;
            });
        VWB_EXPECT(shell != batch.compiled_operations().end());
        const NativeValue *defer = metadata_value(shell->operation.state->metadata, "deferSkyLight");
        VWB_EXPECT_EQ(entry.second, defer != nullptr && defer->as_boolean());
    }
}

VWB_TEST(native_terrain_edit_box_preserves_explicit_air_fluid_metadata_without_sphere_classification) {
    FakePinnedSource air_source(FakePinnedSource::Fallback::air);
    NativeTerrainEditStateTemplate water;
    water.material = TerrainMaterialId::water;
    water.biome = TerrainBiomeId::forest;
    water.solid = false;
    water.density = -1.0;
    water.fluid = TerrainFluidId::water;
    water.light = NativeCellLight{15, 0};
    water.metadata = NativeValue::object({});
    NativeTerrainEditCompileRequest request;
    request.cell_size = 1.0;
    request.source = &air_source;
    request.omit_unchanged = false;
    request.shapes = {NativeTerrainEditShape::inclusive_box(
        {0, 0, 0}, {0, 0, 0}, water, "box:water")};
    const NativeTerrainEditCompiledBatch water_box = NativeTerrainEditShapeCompiler::compile(request);
    VWB_EXPECT(metadata_value(
        water_box.compiled_operations()[0].operation.state->metadata, "terrainMeshAffects") == nullptr);

    FakePinnedSource water_source(FakePinnedSource::Fallback::air);
    water_source.add(cell_state({0, 0, 0}, TerrainMaterialId::water, false, -1.0,
        {}, NativeValue::object({}), true, std::nullopt, TerrainFluidId::water));
    request.source = &water_source;
    request.shapes = {NativeTerrainEditShape::inclusive_box(
        {0, 0, 0}, {0, 0, 0}, air_template(), "box:air")};
    const NativeTerrainEditCompiledBatch air_box = NativeTerrainEditShapeCompiler::compile(request);
    VWB_EXPECT(metadata_value(
        air_box.compiled_operations()[0].operation.state->metadata, "terrainMeshAffects") == nullptr);
}

VWB_TEST(native_terrain_edit_solid_sphere_and_fluid_only_normalization_are_typed) {
    FakePinnedSource air_source(FakePinnedSource::Fallback::air);
    NativeTerrainEditCompileRequest solid_request;
    solid_request.cell_size = 1.0;
    solid_request.source = &air_source;
    solid_request.omit_unchanged = false;
    solid_request.shapes = {NativeTerrainEditShape::sphere(
        {0.5, 0.5, 0.5}, 0.5, stone_template(), "fill:sphere")};
    const NativeTerrainEditCompiledBatch solid = NativeTerrainEditShapeCompiler::compile(solid_request);
    VWB_EXPECT_EQ(1U, solid.compiled_operations().size());
    VWB_EXPECT_EQ(0.5, solid.compiled_operations()[0].operation.state->density);
    VWB_EXPECT_EQ(1U, solid.summary().solid_operations);

    NativeTerrainEditStateTemplate water;
    water.material = TerrainMaterialId::water;
    water.biome = TerrainBiomeId::forest;
    water.solid = false;
    water.fluid = TerrainFluidId::water;
    water.light = NativeCellLight{15, 0};
    water.metadata = NativeValue::object({});
    NativeTerrainEditCompileRequest fluid_request;
    fluid_request.cell_size = 1.0;
    fluid_request.source = &air_source;
    fluid_request.omit_unchanged = false;
    fluid_request.shapes = {NativeTerrainEditShape::sphere(
        {0.5, 0.5, 0.5}, 0.25, water, "fluid:sphere")};
    const NativeTerrainEditCompiledBatch fluid = NativeTerrainEditShapeCompiler::compile(fluid_request);
    const NativeValue *mesh_affects = metadata_value(
        fluid.compiled_operations()[0].operation.state->metadata, "terrainMeshAffects");
    VWB_EXPECT(mesh_affects != nullptr && !mesh_affects->as_boolean());

    water.metadata = NativeValue::object({{"terrainMeshAffects", NativeValue::boolean(true)}});
    fluid_request.shapes = {NativeTerrainEditShape::sphere(
        {0.5, 0.5, 0.5}, 0.25, water, "fluid:explicit")};
    const NativeTerrainEditCompiledBatch explicit_mesh = NativeTerrainEditShapeCompiler::compile(fluid_request);
    mesh_affects = metadata_value(explicit_mesh.compiled_operations()[0].operation.state->metadata, "terrainMeshAffects");
    VWB_EXPECT(mesh_affects != nullptr && mesh_affects->as_boolean());

    water.metadata = NativeValue::object({{"zzz", NativeValue::boolean(true)}});
    fluid_request.shapes = {NativeTerrainEditShape::sphere(
        {0.5, 0.5, 0.5}, 0.25, water, "fluid:key-miss")};
    const NativeTerrainEditCompiledBatch key_miss = NativeTerrainEditShapeCompiler::compile(fluid_request);
    mesh_affects = metadata_value(key_miss.compiled_operations()[0].operation.state->metadata, "terrainMeshAffects");
    VWB_EXPECT(mesh_affects != nullptr && !mesh_affects->as_boolean());

    FakePinnedSource solid_source;
    fluid_request.source = &solid_source;
    fluid_request.shapes = {NativeTerrainEditShape::sphere(
        {0.5, 0.5, 0.5}, 0.25, water, "fluid:solid-before")};
    const NativeTerrainEditCompiledBatch solid_before = NativeTerrainEditShapeCompiler::compile(fluid_request);
    VWB_EXPECT(metadata_value(
        solid_before.compiled_operations()[0].operation.state->metadata, "terrainMeshAffects") == nullptr);

    FakePinnedSource water_source(FakePinnedSource::Fallback::air);
    water_source.add(cell_state({0, 0, 0}, TerrainMaterialId::water, false, -1.0,
        {}, NativeValue::object({}), true, std::nullopt, TerrainFluidId::water));
    solid_request.source = &water_source;
    const NativeTerrainEditCompiledBatch fluid_before_solid = NativeTerrainEditShapeCompiler::compile(solid_request);
    VWB_EXPECT(metadata_value(
        fluid_before_solid.compiled_operations()[0].operation.state->metadata, "terrainMeshAffects") == nullptr);
}

VWB_TEST(native_terrain_edit_material_normalization_covers_every_persisted_material_id) {
    std::vector<NativeTerrainEditShape> shapes;
    const std::vector<TerrainMaterialId> materials = {
        TerrainMaterialId::air, TerrainMaterialId::grass, TerrainMaterialId::dirt, TerrainMaterialId::stone,
        TerrainMaterialId::sand, TerrainMaterialId::snow, TerrainMaterialId::deep_stone, TerrainMaterialId::bedrock,
        TerrainMaterialId::clay, TerrainMaterialId::gravel, TerrainMaterialId::coal_ore, TerrainMaterialId::iron_ore,
        TerrainMaterialId::crystal_ore, TerrainMaterialId::copper_ore, TerrainMaterialId::mud,
        TerrainMaterialId::water, TerrainMaterialId::lava,
    };
    for (std::size_t index = 0; index < materials.size(); ++index) {
        NativeTerrainEditStateTemplate target;
        target.material = materials[index];
        target.biome = TerrainBiomeId::plains;
        target.solid = index > 0U && materials[index] != TerrainMaterialId::water && materials[index] != TerrainMaterialId::lava;
        target.density = target.solid.value() ? 1.0 : -1.0;
        target.fluid = materials[index] == TerrainMaterialId::water ? TerrainFluidId::water
            : materials[index] == TerrainMaterialId::lava ? TerrainFluidId::lava : TerrainFluidId::none;
        target.light = NativeCellLight{
            target.solid.value() ? std::uint8_t{0} : std::uint8_t{15}, 0};
        shapes.push_back(NativeTerrainEditShape::inclusive_box(
            {static_cast<std::int32_t>(index), 0, 0}, {static_cast<std::int32_t>(index), 0, 0},
            target, "materials"));
    }
    const NativeTerrainEditCompiledBatch batch = NativeTerrainEditShapeCompiler::compile(
        request_without_filter(std::move(shapes)));
    VWB_EXPECT_EQ(materials.size(), batch.compiled_operations().size());
    VWB_EXPECT_EQ(materials.size(), batch.summary().material_counts.size());
    for (std::size_t index = 0; index < materials.size(); ++index) {
        VWB_EXPECT_EQ(materials[index], batch.compiled_operations()[index].operation.state->material);
        VWB_EXPECT(batch.compiled_operations()[index].operation.state->block_id.has_value());
    }
}

VWB_TEST(native_terrain_edit_rejects_invalid_requests_sources_shapes_and_limits_atomically) {
    NativeTerrainEditCompileRequest request = request_without_filter({
        NativeTerrainEditShape::inclusive_box({0, 0, 0}, {0, 0, 0}, stone_template(), "valid"),
    });
    request.cell_size = 0.0;
    expect_reason(NativeTerrainEditCompileRejectReason::invalid_request, request);
    request.cell_size = std::numeric_limits<double>::quiet_NaN();
    expect_reason(NativeTerrainEditCompileRejectReason::invalid_request, request);
    request.cell_size = 1.0;
    request.limits.max_candidate_visits = 0U;
    expect_reason(NativeTerrainEditCompileRejectReason::invalid_request, request);
    request.limits.max_candidate_visits = 100U;
    request.limits.max_operations = 0U;
    expect_reason(NativeTerrainEditCompileRejectReason::invalid_request, request);

    request = request_without_filter({
        NativeTerrainEditShape::inclusive_box({0, 0, 0}, {4, 0, 0}, stone_template(), "limit"),
    });
    request.limits.max_candidate_visits = 4U;
    expect_reason(NativeTerrainEditCompileRejectReason::candidate_limit_exceeded, request);
    request.shapes = {NativeTerrainEditShape::inclusive_box(
        {0, 0, 0}, {0, 4, 0}, stone_template(), "limit-y")};
    expect_reason(NativeTerrainEditCompileRejectReason::candidate_limit_exceeded, request);
    request.shapes = {NativeTerrainEditShape::inclusive_box(
        {0, 0, 0}, {0, 0, 4}, stone_template(), "limit-z")};
    expect_reason(NativeTerrainEditCompileRejectReason::candidate_limit_exceeded, request);
    request.shapes = {NativeTerrainEditShape::inclusive_box(
        {0, 0, 0}, {4, 0, 0}, stone_template(), "limit")};
    request.limits.max_candidate_visits = 5U;
    request.limits.max_operations = 4U;
    expect_reason(NativeTerrainEditCompileRejectReason::operation_limit_exceeded, request);

    request = request_without_filter({
        NativeTerrainEditShape::inclusive_box({0, 0, 0}, {0, 0, 0}, stone_template(), ""),
    });
    const NativeTerrainEditCompiledBatch empty_reason = NativeTerrainEditShapeCompiler::compile(request);
    VWB_EXPECT_EQ(std::string(""), *empty_reason.compiled_operations()[0].operation.state->edit_reason);
    request.shapes[0].provenance_id = std::string("bad\0id", 6);
    expect_reason(NativeTerrainEditCompileRejectReason::invalid_request, request);
    request.shapes[0].provenance_id = std::string("bad\xc0\x80", 5);
    expect_reason(NativeTerrainEditCompileRejectReason::invalid_request, request);
    request.shapes[0].provenance_id = "valid";
    request.shapes[0].target.metadata = NativeValue::string("not-an-object");
    expect_reason(NativeTerrainEditCompileRejectReason::invalid_request, request);
    request.shapes[0].target = stone_template(-1.0);
    expect_reason(NativeTerrainEditCompileRejectReason::invalid_request, request);
    request.shapes[0].target = stone_template();
    request.shapes[0].target.material = static_cast<TerrainMaterialId>(255U);
    expect_reason(NativeTerrainEditCompileRejectReason::invalid_request, request);
    request.shapes[0].target = stone_template();
    request.shapes[0].kind = static_cast<NativeTerrainEditShapeKind>(255U);
    expect_reason(NativeTerrainEditCompileRejectReason::unsupported_shape, request);

    request = request_without_filter({
        NativeTerrainEditShape::sphere({0.0, 0.0, 0.0}, 1.0, air_template(), "sphere"),
    });
    expect_reason(NativeTerrainEditCompileRejectReason::source_required, request);
    FakePinnedSource missing(FakePinnedSource::Fallback::missing);
    request.source = &missing;
    expect_reason(NativeTerrainEditCompileRejectReason::source_cell_missing, request);
    FakePinnedSource mismatch;
    mismatch.add(cell_state({0, 0, 0}, TerrainMaterialId::stone, true, 1.0));
    mismatch.mismatch(true);
    request.source = &mismatch;
    request.shapes = {NativeTerrainEditShape::sphere({0.5, 0.5, 0.5}, 0.2, air_template(), "sphere")};
    expect_reason(NativeTerrainEditCompileRejectReason::source_cell_mismatch, request);

    FakePinnedSource valid;
    request.source = &valid;
    request.shapes[0].center.x = std::numeric_limits<double>::infinity();
    expect_reason(NativeTerrainEditCompileRejectReason::invalid_request, request);
    request.shapes[0].center = {0.0, std::numeric_limits<double>::quiet_NaN(), 0.0};
    expect_reason(NativeTerrainEditCompileRejectReason::invalid_request, request);
    request.shapes[0].center = {0.0, 0.0, std::numeric_limits<double>::infinity()};
    expect_reason(NativeTerrainEditCompileRejectReason::invalid_request, request);
    request.shapes[0].center = {0.0, 0.0, 0.0};
    request.shapes[0].radius = 0.0;
    VWB_EXPECT(NativeTerrainEditShapeCompiler::compile(request).compiled_operations().empty());
    request.shapes[0].radius = std::numeric_limits<double>::quiet_NaN();
    expect_reason(NativeTerrainEditCompileRejectReason::invalid_request, request);
    request.shapes[0].radius = 0.2;
    request.shapes[0].target = air_template();
    request.shapes[0].target.metadata = NativeValue::object({
        {"deferSkyLight", NativeValue::string("true")},
    });
    VWB_EXPECT(!NativeTerrainEditShapeCompiler::compile(request).compiled_operations().empty());
    request.shapes[0].target = air_template();
    request.shapes[0].radius = std::numeric_limits<double>::max();
    expect_reason(NativeTerrainEditCompileRejectReason::invalid_request, request);
    request.shapes[0].radius = 1.0;
    request.cell_size = std::numeric_limits<double>::max();
    expect_reason(NativeTerrainEditCompileRejectReason::invalid_request, request);
    request.cell_size = std::numeric_limits<double>::denorm_min();
    expect_reason(NativeTerrainEditCompileRejectReason::invalid_request, request);
    request.cell_size = 1.0;
    request.shapes[0].radius = 1.0;
    request.shapes[0].center = {-std::numeric_limits<double>::max(), 0.0, 0.0};
    expect_reason(NativeTerrainEditCompileRejectReason::invalid_request, request);
    request.shapes[0].center = {std::numeric_limits<double>::max(), 0.0, 0.0};
    expect_reason(NativeTerrainEditCompileRejectReason::invalid_request, request);
    request.shapes[0].radius = std::numeric_limits<double>::max();
    request.shapes[0].center = {std::numeric_limits<double>::max(), 0.0, 0.0};
    expect_reason(NativeTerrainEditCompileRejectReason::invalid_request, request);
    request.shapes[0].center = {-std::numeric_limits<double>::max(), 0.0, 0.0};
    expect_reason(NativeTerrainEditCompileRejectReason::invalid_request, request);
    request.shapes[0].radius = 10'000'000'000.0;
    request.shapes[0].center = {10'000'000'000.0, 10'000'000'000.0, 10'000'000'000.0};
    expect_reason(NativeTerrainEditCompileRejectReason::invalid_request, request);
    const double overflow_component = std::numeric_limits<double>::max() * 0.75;
    request.shapes[0].radius = overflow_component;
    request.shapes[0].center = {overflow_component, overflow_component, overflow_component};
    expect_reason(NativeTerrainEditCompileRejectReason::invalid_request, request);

    NativeTerrainEditCompileRequest filtered;
    filtered.cell_size = 1.0;
    filtered.shapes = {NativeTerrainEditShape::inclusive_box(
        {0, 0, 0}, {0, 0, 0}, stone_template(), "filtered")};
    expect_reason(NativeTerrainEditCompileRejectReason::source_required, filtered);
}

VWB_TEST(native_terrain_edit_empty_batch_is_valid_but_cannot_form_a_delta_transaction) {
    NativeTerrainEditCompileRequest request;
    request.cell_size = 1.0;
    request.omit_unchanged = false;
    const NativeTerrainEditCompiledBatch batch = NativeTerrainEditShapeCompiler::compile(request);
    VWB_EXPECT(batch.compiled_operations().empty());
    VWB_EXPECT_EQ(0U, batch.summary().shape_count);
    try {
        static_cast<void>(batch.make_transaction("empty", 0U));
        VWB_EXPECT(false);
    } catch (const NativeTerrainEditCompileRejected &error) {
        VWB_EXPECT_EQ(NativeTerrainEditCompileRejectReason::empty_transaction, error.reason());
    }

    const NativeTerrainEditCompiledBatch nonempty = NativeTerrainEditShapeCompiler::compile(request_without_filter({
        NativeTerrainEditShape::inclusive_box({0, 0, 0}, {0, 0, 0}, stone_template(), "one"),
    }));
    try {
        static_cast<void>(nonempty.make_transaction("", 0U));
        VWB_EXPECT(false);
    } catch (const NativeTerrainEditCompileRejected &error) {
        VWB_EXPECT_EQ(NativeTerrainEditCompileRejectReason::invalid_request, error.reason());
    }
    VWB_EXPECT_THROW(NativeTerrainEditCompileRejected,
        nonempty.make_transaction(std::string("bad\0id", 6), 0U));
}

VWB_TEST(native_terrain_edit_rejects_source_identity_drift_after_all_reads_without_returning_a_batch) {
    NativeTerrainEditCompileRequest request;
    request.cell_size = 1.0;
    request.shapes = {NativeTerrainEditShape::inclusive_box(
        {0, 0, 0}, {0, 0, 0}, stone_template(), "drift")};
    DriftingPinnedSource digest_source(DriftingPinnedSource::Drift::digest);
    request.source = &digest_source;
    expect_reason(NativeTerrainEditCompileRejectReason::source_drift, request);
    DriftingPinnedSource revision_source(DriftingPinnedSource::Drift::revision);
    request.source = &revision_source;
    expect_reason(NativeTerrainEditCompileRejectReason::source_drift, request);
}
