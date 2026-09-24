#include "test_harness.hpp"

#include "../core/native_terrain_edit_shape_compiler.hpp"

#include <algorithm>
#include <cmath>
#include <cstdlib>
#include <cstdint>
#include <cstring>
#include <fstream>
#include <iomanip>
#include <limits>
#include <map>
#include <memory>
#include <new>
#include <optional>
#include <stdexcept>
#include <sstream>
#include <string>
#include <type_traits>
#include <utility>
#include <vector>

using namespace voxel::world_backend;

static_assert(std::is_move_constructible_v<NativeTerrainEditCompileJob>);
static_assert(!std::is_move_assignable_v<NativeTerrainEditCompileJob>);

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
    enum class CallbackFailure : std::uint8_t { none, runtime_error, bad_alloc };

    explicit FakePinnedSource(const Fallback fallback = Fallback::solid_stone)
        : fallback_(fallback) {
        digest_[0] = 0xa5U;
        digest_[31] = 0x5aU;
    }

    Sha256Digest snapshot_digest() const noexcept override { return digest_; }
    std::uint64_t source_revision() const noexcept override { return revision_; }
    bool has_bounded_prevalidated_surface_deformation_view() const noexcept override {
        return bounded_prevalidated_;
    }

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

    std::optional<NativeCellState> physical_terrain_cell_excluding_scene_overlay_at(
        const CellCoord &cell) const override {
        ++durable_reads_;
        throw_callback_failure(physical_failure_);
        for (const NativeCellState &value : durable_overrides_) {
            if (value.cell == cell) return value;
        }
        if (durable_mismatch_) {
            return cell_state({cell.x + 1, cell.y, cell.z}, TerrainMaterialId::stone, true, 1.0);
        }
        if (fallback_ == Fallback::missing) return std::nullopt;
        if (fallback_ == Fallback::air) {
            return cell_state(cell, TerrainMaterialId::air, false, -1.0);
        }
        return cell_state(cell, TerrainMaterialId::stone, true, 1.0,
            {}, NativeValue::object({{"source", NativeValue::string("generated")}}));
    }

    std::optional<std::size_t>
    physical_terrain_cell_retained_bytes_excluding_scene_overlay_at(
        const CellCoord &) const noexcept override {
        ++size_queries_;
        return declared_cell_bytes_;
    }

    std::optional<NativeTerrainEditSurfaceProjection> continuous_surface_projection_at(
        const NativeTerrainEditColumn &column, const std::size_t allowance) const override {
        ++projection_queries_;
        throw_callback_failure(projection_failure_);
        if (projection_throws_rejected_) {
            throw NativeTerrainEditCompileRejected(
                NativeTerrainEditCompileRejectReason::projection_limit_exceeded);
        }
        if (projection_throws_invalid_) throw std::invalid_argument("projection fixture failure");
        if (projection_missing_) return std::nullopt;
        const auto found = projections_.find({column.x, column.z});
        const double surface = found == projections_.end() ? projection_surface_ : found->second.first;
        const std::size_t reads = found == projections_.end() ? projection_reads_ : found->second.second;
        if (respect_projection_allowance_ && reads > allowance) return std::nullopt;
        NativeTerrainEditColumn reported = column;
        if (projection_mismatch_) ++reported.x;
        return NativeTerrainEditSurfaceProjection{reported, surface, reads};
    }

    void add(NativeCellState state) { overrides_.push_back(std::move(state)); }
    void add_durable(NativeCellState state) { durable_overrides_.push_back(std::move(state)); }
    void mismatch(const bool value) { mismatch_ = value; }
    void durable_mismatch(const bool value) { durable_mismatch_ = value; }
    void revision(const std::uint64_t value) { revision_ = value; }
    std::size_t read_count() const noexcept { return reads_; }
    std::size_t durable_read_count() const noexcept { return durable_reads_; }
    std::size_t projection_query_count() const noexcept { return projection_queries_; }
    std::size_t size_query_count() const noexcept { return size_queries_; }
    void declared_cell_bytes(std::optional<std::size_t> value) { declared_cell_bytes_ = value; }
    void projection(const NativeTerrainEditColumn column, const double surface, const std::size_t reads) {
        projections_[{column.x, column.z}] = {surface, reads};
    }
    void projection_defaults(const double surface, const std::size_t reads) {
        projection_surface_ = surface;
        projection_reads_ = reads;
    }
    void projection_missing(const bool value) { projection_missing_ = value; }
    void projection_mismatch(const bool value) { projection_mismatch_ = value; }
    void respect_projection_allowance(const bool value) { respect_projection_allowance_ = value; }
    void projection_throws_invalid(const bool value) { projection_throws_invalid_ = value; }
    void projection_throws_rejected(const bool value) { projection_throws_rejected_ = value; }
    void bounded_prevalidated(const bool value) { bounded_prevalidated_ = value; }
    void projection_failure(const CallbackFailure value) { projection_failure_ = value; }
    void physical_failure(const CallbackFailure value) { physical_failure_ = value; }

private:
    static void throw_callback_failure(const CallbackFailure failure) {
        if (failure == CallbackFailure::runtime_error) {
            throw std::runtime_error("injected source callback failure");
        }
        if (failure == CallbackFailure::bad_alloc) throw std::bad_alloc();
    }

    Fallback fallback_;
    Sha256Digest digest_{};
    std::vector<NativeCellState> overrides_;
    std::vector<NativeCellState> durable_overrides_;
    bool mismatch_ = false;
    bool durable_mismatch_ = false;
    mutable std::size_t reads_ = 0;
    mutable std::size_t durable_reads_ = 0;
    mutable std::size_t projection_queries_ = 0;
    mutable std::size_t size_queries_ = 0;
    std::uint64_t revision_ = 73U;
    std::map<std::pair<std::int32_t, std::int32_t>, std::pair<double, std::size_t>> projections_;
    double projection_surface_ = 2.0;
    std::size_t projection_reads_ = 5U;
    bool projection_missing_ = false;
    bool projection_mismatch_ = false;
    bool respect_projection_allowance_ = true;
    bool projection_throws_invalid_ = false;
    bool projection_throws_rejected_ = false;
    bool bounded_prevalidated_ = true;
    CallbackFailure projection_failure_ = CallbackFailure::none;
    CallbackFailure physical_failure_ = CallbackFailure::none;
    std::optional<std::size_t> declared_cell_bytes_ = 16U * 1024U;
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

class SurfaceDriftingPinnedSource final : public NativeTerrainEditPinnedSource {
public:
    enum class Drift : std::uint8_t { digest, revision };
    explicit SurfaceDriftingPinnedSource(const Drift value) : drift_(value) {}

    Sha256Digest snapshot_digest() const noexcept override {
        Sha256Digest digest{};
        digest[0] = drift_ == Drift::digest && touched_ ? 2U : 1U;
        return digest;
    }
    std::uint64_t source_revision() const noexcept override {
        return drift_ == Drift::revision && touched_ ? 2U : 1U;
    }
    bool has_bounded_prevalidated_surface_deformation_view() const noexcept override {
        return true;
    }
    std::optional<NativeCellState> cell_at(const CellCoord &cell) const override {
        return cell_state(cell, TerrainMaterialId::stone, true, 1.0);
    }
    std::optional<NativeCellState> physical_terrain_cell_excluding_scene_overlay_at(
        const CellCoord &cell) const override {
        touched_ = true;
        return cell_state(cell, TerrainMaterialId::stone, true, 1.0);
    }
    std::optional<std::size_t>
    physical_terrain_cell_retained_bytes_excluding_scene_overlay_at(
        const CellCoord &) const noexcept override {
        return 16U * 1024U;
    }
    std::optional<NativeTerrainEditSurfaceProjection> continuous_surface_projection_at(
        const NativeTerrainEditColumn &column, std::size_t) const override {
        touched_ = true;
        return NativeTerrainEditSurfaceProjection{column, 2.0, 1U};
    }

private:
    Drift drift_;
    mutable bool touched_ = false;
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

NativeTerrainEditCompileRequest deformation_request(
    const std::shared_ptr<const NativeTerrainEditPinnedSource> &source,
    const Vec3d center = {0.5, 1.5, 0.5},
    const double radius = 0.75,
    const double drop_depth = 0.35) {
    NativeTerrainEditCompileRequest request;
    request.cell_size = 1.0;
    request.owned_source = source;
    request.source = source.get();
    request.shapes = {NativeTerrainEditShape::surface_deformation(
        center, radius, drop_depth, air_template(), "surface:test")};
    return request;
}

NativeTerrainEditCompiledBatch drain_deformation(
    NativeTerrainEditCompileRequest request, const std::size_t budget) {
    NativeTerrainEditCompileJob job = NativeTerrainEditResumableCompiler::begin(std::move(request));
    while (job.status() == NativeTerrainEditCompileJobStatus::running) job.advance(budget);
    if (job.status() == NativeTerrainEditCompileJobStatus::rejected) {
        throw NativeTerrainEditCompileRejected(*job.reject_reason());
    }
    std::optional<NativeTerrainEditCompiledBatch> result = job.take_completed_batch();
    VWB_EXPECT(result.has_value());
    return std::move(*result);
}

void expect_job_reason(
    const NativeTerrainEditCompileRejectReason expected,
    NativeTerrainEditCompileRequest request,
    const std::size_t budget = 1U) {
    NativeTerrainEditCompileJob job = NativeTerrainEditResumableCompiler::begin(std::move(request));
    while (job.status() == NativeTerrainEditCompileJobStatus::running) job.advance(budget);
    VWB_EXPECT_EQ(NativeTerrainEditCompileJobStatus::rejected, job.status());
    VWB_EXPECT(job.reject_reason().has_value());
    if (job.reject_reason().has_value() && expected != *job.reject_reason()) {
        throw std::runtime_error("compile reject reason mismatch: expected "
            + std::to_string(static_cast<unsigned>(expected)) + ", received "
            + std::to_string(static_cast<unsigned>(*job.reject_reason())));
    }
    VWB_EXPECT(!job.take_completed_batch().has_value());
}

void expect_same_batch(
    const NativeTerrainEditCompiledBatch &left,
    const NativeTerrainEditCompiledBatch &right) {
    const auto &a = left.compiled_operations();
    const auto &b = right.compiled_operations();
    VWB_EXPECT_EQ(a.size(), b.size());
    for (std::size_t index = 0; index < a.size(); ++index) {
        VWB_EXPECT(a[index].operation.cell == b[index].operation.cell);
        VWB_EXPECT_EQ(a[index].operation.name_space, b[index].operation.name_space);
        VWB_EXPECT_EQ(a[index].operation.kind, b[index].operation.kind);
        VWB_EXPECT(a[index].operation.state == b[index].operation.state);
        VWB_EXPECT_EQ(a[index].shape_kind, b[index].shape_kind);
        VWB_EXPECT_EQ(a[index].classification, b[index].classification);
        VWB_EXPECT_EQ(a[index].source_shape_index, b[index].source_shape_index);
        VWB_EXPECT_EQ(a[index].provenance_id, b[index].provenance_id);
    }
    const auto &x = left.summary();
    const auto &y = right.summary();
    VWB_EXPECT_EQ(x.candidate_visits, y.candidate_visits);
    VWB_EXPECT_EQ(x.emitted_operations, y.emitted_operations);
    VWB_EXPECT_EQ(x.changed_cells, y.changed_cells);
    VWB_EXPECT(x.legacy_changed_cells == y.legacy_changed_cells);
    VWB_EXPECT(x.legacy_changed_columns == y.legacy_changed_columns);
    VWB_EXPECT(x.skylight_columns == y.skylight_columns);
    VWB_EXPECT(x.fluid_transition_columns == y.fluid_transition_columns);
    VWB_EXPECT_EQ(x.prepared_bytes, y.prepared_bytes);
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

std::string little_endian_double_hex(const double value) {
    std::uint8_t bytes[sizeof(value)]{};
    std::memcpy(bytes, &value, sizeof(value));
    std::ostringstream result;
    result << std::hex << std::setfill('0');
    for (const std::uint8_t byte : bytes) result << std::setw(2) << static_cast<unsigned>(byte);
    return result.str();
}

struct SurfaceObservationCase {
    const char *name;
    Vec3d center;
    double radius;
    double drop_depth;
    NativeTerrainEditColumn column;
    double surface_y;
};

const std::vector<SurfaceObservationCase> &surface_observation_cases() {
    static const std::vector<SurfaceObservationCase> cases{
        {"falloffRejected", {0.5, 1.5, 0.5}, 1.01, 0.35, {1, 0}, 2.0},
        {"float32Large", {16777216.5, 1.5, -16777216.5}, 0.75, 0.35,
            {16777216, -16777216}, 2.0},
        {"impactWins", {0.5, 1.5, 0.5}, 0.75, 0.35, {0, 0}, 2.0},
        {"negativeClamp", {-0.5, 1.75, -0.5}, -50.0, -20.0, {-1, -1}, 2.25},
        {"shallowTargetRejected", {0.5, 100.0, 0.5}, 1.1, 0.35, {1, 0}, 2.0},
        {"surfaceDropWins", {0.5, 1.5, 0.5}, 0.75, 1.0, {0, 0}, 1.5},
    };
    return cases;
}

std::string surface_observation_json(
    const NativeTerrainEditSurfaceDeformationColumnObservation &value) {
    const auto bits = [](const double number) {
        return '"' + little_endian_double_hex(number) + '"';
    };
    std::ostringstream json;
    json << "{\"boundaryY0Density\":" << bits(value.boundary_y0_density)
         << ",\"columnCenterX\":" << bits(value.column_center_x)
         << ",\"columnCenterZ\":" << bits(value.column_center_z)
         << ",\"directY1Density\":" << bits(value.direct_y1_density)
         << ",\"directY2Density\":" << bits(value.direct_y2_density)
         << ",\"falloff\":" << bits(value.falloff)
         << ",\"falloffAccepted\":" << (value.falloff_accepted ? "true" : "false")
         << ",\"highY\":" << value.high_y
         << ",\"horizontalDistance\":" << bits(value.horizontal_distance)
         << ",\"impactStrength\":" << bits(value.impact_strength)
         << ",\"impactTarget\":" << bits(value.impact_target_y)
         << ",\"lowY\":" << value.low_y
         << ",\"safeDrop\":" << bits(value.safe_drop)
         << ",\"safeRadius\":" << bits(value.safe_radius)
         << ",\"surfaceTarget\":" << bits(value.surface_target_y)
         << ",\"target\":" << bits(value.target_y)
         << ",\"targetAccepted\":" << (value.target_accepted ? "true" : "false") << '}';
    return json.str();
}

std::string native_surface_observations_json() {
    std::ostringstream json;
    json << '{';
    bool first = true;
    for (const SurfaceObservationCase &case_ : surface_observation_cases()) {
        auto source = std::make_shared<FakePinnedSource>();
        source->projection_defaults(case_.surface_y, 1U);
        source->projection(case_.column, case_.surface_y, 1U);
        const NativeTerrainEditCompiledBatch compiled = drain_deformation(
            deformation_request(source, case_.center, case_.radius, case_.drop_depth), 7U);
        VWB_EXPECT_EQ(1U, compiled.summary().shape_count);
        const auto observation = NativeTerrainEditShapeCompiler::observe_surface_deformation_column(
            case_.center, case_.radius, case_.drop_depth, 1.0, case_.column, case_.surface_y);
        if (!first) json << ',';
        first = false;
        json << '"' << case_.name << "\":" << surface_observation_json(observation);
    }
    json << '}';
    return json.str();
}

std::string text_sha256(const std::string &text) {
    return sha256_hex(sha256(reinterpret_cast<const std::uint8_t *>(text.data()), text.size()));
}

} // namespace

std::optional<int> emit_native_surface_deformation_observations_if_requested() {
    char *raw_path = nullptr;
    std::size_t path_size = 0U;
    if (_dupenv_s(&raw_path, &path_size,
            "N3_NATIVE_SURFACE_DEFORMATION_OBSERVATION_REPORT") != 0) return 5;
    const std::unique_ptr<char, decltype(&std::free)> owned_path(raw_path, &std::free);
    if (raw_path == nullptr || path_size <= 1U) return std::nullopt;
    try {
        const std::string observations = native_surface_observations_json();
        const std::string digest = text_sha256(observations);
        std::ofstream output(raw_path, std::ios::binary | std::ios::trunc);
        if (!output) return 2;
        output << "{\"schema\":\"n3-native-terrain-surface-deformation-observations/v1\""
               << ",\"passed\":true,\"compilerCases\":6,\"observations\":" << observations
               << ",\"observationsSha256\":\"" << digest << "\"}\n";
        return output.good() ? 0 : 3;
    } catch (...) {
        return 4;
    }
}

VWB_TEST(native_surface_deformation_observation_schema_matches_godot_oracle_hash) {
    const std::string observations = native_surface_observations_json();
    VWB_EXPECT_EQ(std::string("0c8d7cce1fffe881edb003f122deb55e2c27366db46fb6486de45463f25a3653"),
        text_sha256(observations));
}

VWB_TEST(native_surface_deformation_observation_rejects_invalid_and_overflowing_inputs) {
    const auto observe = [](Vec3d center, double radius, double drop, double cell_size,
                             NativeTerrainEditColumn column, double surface) {
        return NativeTerrainEditShapeCompiler::observe_surface_deformation_column(
            center, radius, drop, cell_size, column, surface);
    };
    const double nan = std::numeric_limits<double>::quiet_NaN();
    VWB_EXPECT_THROW(NativeTerrainEditCompileRejected,
        observe({0.5, 1.5, 0.5}, 1.0, 1.0, 0.0, {0, 0}, 2.0));
    VWB_EXPECT_THROW(NativeTerrainEditCompileRejected,
        observe({0.5, 1.5, 0.5}, 1.0, 1.0, nan, {0, 0}, 2.0));
    VWB_EXPECT_THROW(NativeTerrainEditCompileRejected,
        observe({0.5, 1.5, 0.5}, nan, 1.0, 1.0, {0, 0}, 2.0));
    VWB_EXPECT_THROW(NativeTerrainEditCompileRejected,
        observe({0.5, 1.5, 0.5}, 1.0, nan, 1.0, {0, 0}, 2.0));
    VWB_EXPECT_THROW(NativeTerrainEditCompileRejected,
        observe({nan, 1.5, 0.5}, 1.0, 1.0, 1.0, {0, 0}, 2.0));
    VWB_EXPECT_THROW(NativeTerrainEditCompileRejected,
        observe({0.5, nan, 0.5}, 1.0, 1.0, 1.0, {0, 0}, 2.0));
    VWB_EXPECT_THROW(NativeTerrainEditCompileRejected,
        observe({0.5, 1.5, nan}, 1.0, 1.0, 1.0, {0, 0}, 2.0));
    VWB_EXPECT_THROW(NativeTerrainEditCompileRejected,
        observe({0.5, 1.5, 0.5}, 1.0, 1.0, 1.0, {0, 0}, nan));
    VWB_EXPECT_THROW(NativeTerrainEditCompileRejected,
        observe({0.5, 1.5, 0.5}, 1.0, 1.0, 1.0e38,
            {std::numeric_limits<std::int32_t>::max(), 0}, 2.0));
    VWB_EXPECT_THROW(NativeTerrainEditCompileRejected,
        observe({0.5, 1.5, 0.5}, 1.0, 1.0, 1.0e38,
            {0, std::numeric_limits<std::int32_t>::max()}, 2.0));
    VWB_EXPECT_THROW(NativeTerrainEditCompileRejected,
        observe({std::numeric_limits<double>::max(), 1.5, 0.5},
            1.0, 1.0, 1.0, {0, 0}, 2.0));
    VWB_EXPECT_THROW(NativeTerrainEditCompileRejected,
        observe({0.5, 1.5, 0.5}, 1.0, std::numeric_limits<double>::max(),
            1.0, {0, 0}, -std::numeric_limits<double>::max()));
    VWB_EXPECT_THROW(NativeTerrainEditCompileRejected,
        observe({0.5, 1.5, 0.5}, 1.0, 1.0, 1.0, {0, 0},
            std::numeric_limits<double>::max()));
    VWB_EXPECT_THROW(NativeTerrainEditCompileRejected,
        observe({0.5, -2147483647.0, 0.5}, 1.0, 1.0, 1.0, {0, 0},
            -2147483647.0));
}

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

VWB_TEST(native_terrain_edit_positive_sphere_rejects_ambiguous_absent_solid_for_stone_and_air) {
    FakePinnedSource source;
    NativeTerrainEditStateTemplate stone_without_solid;
    stone_without_solid.material = TerrainMaterialId::stone;
    NativeTerrainEditCompileRequest request;
    request.cell_size = 1.0;
    request.source = &source;
    request.omit_unchanged = false;
    request.shapes = {NativeTerrainEditShape::sphere(
        {0.5, 0.5, 0.5}, 1.0, stone_without_solid, "absent-solid-stone")};
    expect_reason(NativeTerrainEditCompileRejectReason::invalid_request, request);
    NativeTerrainEditStateTemplate air_without_solid;
    air_without_solid.material = TerrainMaterialId::air;
    request.shapes = {NativeTerrainEditShape::sphere(
        {0.5, 0.5, 0.5}, 1.0, air_without_solid, "absent-solid-air")};
    expect_reason(NativeTerrainEditCompileRejectReason::invalid_request, request);
}

VWB_TEST(native_terrain_edit_nonpositive_sphere_is_empty_before_state_or_source_validation) {
    NativeTerrainEditStateTemplate invalid;
    invalid.material = static_cast<TerrainMaterialId>(255U);
    NativeTerrainEditCompileRequest request;
    request.cell_size = 1.0;
    request.shapes = {
        NativeTerrainEditShape::sphere(
            {std::numeric_limits<double>::infinity(), 0.0, 0.0}, 0.0, invalid, std::string("bad\0id", 6)),
        NativeTerrainEditShape::sphere(
            {0.0, std::numeric_limits<double>::quiet_NaN(), 0.0}, -1.0, invalid, ""),
        NativeTerrainEditShape::sphere(
            {0.0, 0.0, 0.0}, -std::numeric_limits<double>::infinity(), invalid, ""),
    };
    VWB_EXPECT(request.omit_unchanged);
    VWB_EXPECT(request.source == nullptr);
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

VWB_TEST(native_terrain_edit_translates_compiler_added_metadata_overflow_to_public_rejection) {
    NativeValue::Object maximum_metadata;
    maximum_metadata.reserve(NativeValueLimits::MAX_CONTAINER_ENTRIES);
    for (std::size_t index = 0; index < NativeValueLimits::MAX_CONTAINER_ENTRIES; ++index) {
        std::string digits = std::to_string(index);
        maximum_metadata.push_back({
            "k" + std::string(4U - digits.size(), '0') + digits,
            NativeValue::boolean(false),
        });
    }
    NativeTerrainEditStateTemplate water;
    water.material = TerrainMaterialId::water;
    water.solid = false;
    water.fluid = TerrainFluidId::water;
    water.density = -1.0;
    water.light = NativeCellLight{15, 0};
    water.metadata = NativeValue::object(std::move(maximum_metadata));
    FakePinnedSource source(FakePinnedSource::Fallback::air);
    NativeTerrainEditCompileRequest request;
    request.cell_size = 1.0;
    request.source = &source;
    request.omit_unchanged = false;
    request.shapes = {NativeTerrainEditShape::sphere(
        {0.5, 0.5, 0.5}, 0.25, water, "metadata-overflow")};
    expect_reason(NativeTerrainEditCompileRejectReason::invalid_request, request);
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
    const std::vector<std::string> block_ids = {
        "air", "grass", "dirt", "stone", "sand", "snow", "deepStone", "bedrock",
        "clay", "gravel", "coalOre", "ironOre", "crystalOre", "copperOre", "mud", "water", "lava",
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
        VWB_EXPECT_EQ(block_ids[index], batch.compiled_operations()[index].operation.state->block_id->value());
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
    request.limits.max_operations = 100U;
    request.limits.max_columns = 0U;
    expect_reason(NativeTerrainEditCompileRejectReason::invalid_request, request);
    request.limits.max_columns = 1U;
    request.limits.max_projection_reads = 0U;
    expect_reason(NativeTerrainEditCompileRejectReason::invalid_request, request);
    request.limits.max_projection_reads = 1U;
    request.limits.max_projection_reads_per_query = 0U;
    expect_reason(NativeTerrainEditCompileRejectReason::invalid_request, request);
    request.limits.max_projection_reads_per_query = 1U;
    request.limits.max_y_candidates = 0U;
    expect_reason(NativeTerrainEditCompileRejectReason::invalid_request, request);
    request.limits.max_y_candidates = 1U;
    request.limits.max_prepared_bytes = 0U;
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
    request.shapes[0].target = stone_template();
    expect_reason(NativeTerrainEditCompileRejectReason::invalid_request, request);
    request.shapes[0].target = air_template();
    request.cell_size = std::numeric_limits<double>::denorm_min();
    expect_reason(NativeTerrainEditCompileRejectReason::invalid_request, request);
    request.shapes[0].target = stone_template();
    request.cell_size = 1.0e-100;
    request.shapes[0].center = {1.0, 1.0, 1.0};
    request.shapes[0].radius = 1.0e-100;
    expect_reason(NativeTerrainEditCompileRejectReason::invalid_request, request);
    const double float_max = static_cast<double>(std::numeric_limits<float>::max());
    request.cell_size = std::numeric_limits<double>::denorm_min();
    request.shapes[0].center = {float_max, float_max, float_max};
    request.shapes[0].radius = float_max;
    expect_reason(NativeTerrainEditCompileRejectReason::invalid_request, request);
    request.shapes[0].center = {0.0, 0.0, 0.0};
    request.shapes[0].radius = 1.0e200;
    request.cell_size = std::numeric_limits<double>::max();
    expect_reason(NativeTerrainEditCompileRejectReason::invalid_request, request);
    request.cell_size = 1.0;
    request.shapes[0].target = air_template();
    request.shapes[0].radius = 1.0;
    request.shapes[0].center = {-std::numeric_limits<double>::max(), 0.0, 0.0};
    expect_reason(NativeTerrainEditCompileRejectReason::invalid_request, request);
    request.shapes[0].center = {std::numeric_limits<double>::max(), 0.0, 0.0};
    expect_reason(NativeTerrainEditCompileRejectReason::invalid_request, request);
    request.shapes[0].center = {0.0, std::numeric_limits<double>::max(), 0.0};
    expect_reason(NativeTerrainEditCompileRejectReason::invalid_request, request);
    request.shapes[0].center = {0.0, 0.0, std::numeric_limits<double>::max()};
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
    VWB_EXPECT(request.omit_unchanged);
    VWB_EXPECT(request.source == nullptr);
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

VWB_TEST(native_surface_deformation_matches_flat_legacy_shape_and_preserves_payload_summaries) {
    auto source = std::make_shared<FakePinnedSource>();
    NativeCellStateInput boundary_input;
    boundary_input.cell = {0, 0, 0};
    boundary_input.material = TerrainMaterialId::dirt;
    boundary_input.biome = TerrainBiomeId::alpine;
    boundary_input.solid = true;
    boundary_input.density = 0.9;
    boundary_input.fluid = TerrainFluidId::none;
    boundary_input.light = {3, 7};
    boundary_input.metadata = NativeValue::object({
        {"custom", NativeValue::string("keep")},
        {"source", NativeValue::string("durable_player")},
    });
    boundary_input.block_id = NativeBlockIdentity::create("soil.custom");
    boundary_input.edit_reason = "prior";
    boundary_input.generated = false;
    boundary_input.edited = true;
    source->add_durable(make_native_cell_state(boundary_input));
    source->add_durable(cell_state({0, 1, 0}, TerrainMaterialId::water, false, -1.0,
        {}, NativeValue::object({}), true, std::nullopt, TerrainFluidId::water));

    const NativeTerrainEditCompiledBatch batch = drain_deformation(deformation_request(source), 1U);
    const auto &operations = batch.compiled_operations();
    VWB_EXPECT_EQ(3U, operations.size());
    VWB_EXPECT((operations[0].operation.cell == CellCoord{0, 0, 0}));
    VWB_EXPECT((operations[1].operation.cell == CellCoord{0, 1, 0}));
    VWB_EXPECT((operations[2].operation.cell == CellCoord{0, 2, 0}));
    const NativeCellState &boundary = *operations[0].operation.state;
    VWB_EXPECT_EQ(TerrainMaterialId::dirt, boundary.material);
    VWB_EXPECT_EQ(TerrainBiomeId::alpine, boundary.biome);
    VWB_EXPECT_EQ(TerrainFluidId::none, boundary.fluid);
    VWB_EXPECT_EQ(3U, boundary.light.sky);
    VWB_EXPECT_EQ(7U, boundary.light.block);
    VWB_EXPECT_EQ(std::string("soil.custom"), boundary.block_id->value());
    VWB_EXPECT_EQ(NativeTerrainEditCellClassification::excavation_boundary,
        operations[0].classification);
    VWB_EXPECT_EQ(double_bits(0.748), double_bits(boundary.density));
    VWB_EXPECT_EQ(std::string("surface_excavation_boundary"),
        metadata_value(boundary.metadata, "source")->as_string());
    VWB_EXPECT_EQ(std::string("keep"), metadata_value(boundary.metadata, "custom")->as_string());
    VWB_EXPECT_EQ(double_bits(-0.252), double_bits(operations[1].operation.state->density));
    VWB_EXPECT_EQ(double_bits(-1.252), double_bits(operations[2].operation.state->density));
    for (std::size_t index = 1; index < operations.size(); ++index) {
        const NativeCellState &air = *operations[index].operation.state;
        VWB_EXPECT_EQ(NativeTerrainEditCellClassification::direct_target,
            operations[index].classification);
        VWB_EXPECT(metadata_value(air.metadata, "terrainMeshAffects")->as_boolean());
        VWB_EXPECT(metadata_value(air.metadata, "surfaceProjectionAffects")->as_boolean());
        VWB_EXPECT(metadata_value(air.metadata, "saveDelta")->as_boolean());
        VWB_EXPECT_EQ(std::string("player_dig"), metadata_value(air.metadata, "source")->as_string());
    }

    const auto &summary = batch.summary();
    VWB_EXPECT_EQ(36U, summary.enumerated_columns);
    VWB_EXPECT_EQ(1U, summary.projection_queries);
    VWB_EXPECT_EQ(5U, summary.projection_candidate_reads);
    VWB_EXPECT_EQ(4U, summary.y_candidates);
    VWB_EXPECT_EQ(40U, summary.candidate_visits);
    VWB_EXPECT_EQ(3U, summary.changed_cells);
    VWB_EXPECT_EQ(3U, summary.emitted_operations);
    VWB_EXPECT_EQ(2U, summary.direct_target_operations);
    VWB_EXPECT_EQ(1U, summary.excavation_boundary_operations);
    VWB_EXPECT_EQ(1U, summary.removed_material_counts.size());
    VWB_EXPECT_EQ(TerrainMaterialId::stone, summary.removed_material_counts[0].material);
    VWB_EXPECT_EQ(1U, summary.removed_material_counts[0].count);
    VWB_EXPECT((summary.legacy_changed_cells == std::vector<CellCoord>{
        {0, 2, 0}, {0, 1, 0}, {0, 0, 0}}));
    VWB_EXPECT((summary.legacy_changed_columns == std::vector<NativeTerrainEditColumn>{{0, 0}}));
    VWB_EXPECT((summary.skylight_columns == std::vector<NativeTerrainEditColumn>{{0, 0}}));
    VWB_EXPECT((summary.fluid_transition_columns == std::vector<NativeTerrainEditColumn>{{0, 0}}));
    VWB_EXPECT(summary.prepared_bytes > 40U);
    VWB_EXPECT_EQ(0U, source->read_count());
    VWB_EXPECT(source->durable_read_count() >= 4U);

    try {
        static_cast<void>(batch.make_transaction("surface:flat", 73U));
        VWB_EXPECT(false);
    } catch (const NativeTerrainEditCompileRejected &error) {
        VWB_EXPECT_EQ(NativeTerrainEditCompileRejectReason::identity_bound_commit_required,
            error.reason());
    }
}

VWB_TEST(native_surface_deformation_invalidates_no_fluid_columns_on_solidity_change) {
    const NativeTerrainEditCompiledBatch batch = drain_deformation(
        deformation_request(std::make_shared<FakePinnedSource>()), 2U);
    VWB_EXPECT((batch.summary().fluid_transition_columns
        == std::vector<NativeTerrainEditColumn>{{0, 0}}));
    VWB_EXPECT((batch.summary().skylight_columns
        == std::vector<NativeTerrainEditColumn>{{0, 0}}));
}

VWB_TEST(native_surface_deformation_skylight_predicate_matches_script_sources) {
    auto run_pair = [](NativeValue target_metadata, NativeValue existing_metadata) {
        auto source = std::make_shared<FakePinnedSource>(FakePinnedSource::Fallback::air);
        source->add_durable(cell_state({0, 1, 0}, TerrainMaterialId::air, false, -1.0,
            {}, existing_metadata));
        source->add_durable(cell_state({0, 2, 0}, TerrainMaterialId::air, false, -1.0,
            {}, existing_metadata));
        NativeTerrainEditCompileRequest request = deformation_request(source);
        request.shapes[0].target.metadata = std::move(target_metadata);
        return drain_deformation(request, 2U);
    };
    auto run_hidden = [&run_pair](NativeValue metadata) {
        return run_pair(metadata, metadata);
    };
    const NativeTerrainEditCompiledBatch structure = run_hidden(NativeValue::object({
        {"source", NativeValue::string("structure_wall")},
    }));
    VWB_EXPECT(structure.summary().skylight_columns.empty());
    const NativeTerrainEditCompiledBatch scene = run_hidden(NativeValue::object({
        {"renderedBySceneBlock", NativeValue::boolean(true)},
        {"source", NativeValue::string("scene_block")},
    }));
    VWB_EXPECT(scene.summary().skylight_columns.empty());
    const NativeValue structure_target = NativeValue::object({
        {"source", NativeValue::string("structure_wall")},
    });
    VWB_EXPECT_EQ(1U, run_pair(structure_target, NativeValue::object({}))
        .summary().skylight_columns.size());
    VWB_EXPECT_EQ(1U, run_pair(structure_target, NativeValue::object({
        {"zzz", NativeValue::boolean(false)},
    })).summary().skylight_columns.size());
    VWB_EXPECT_EQ(1U, run_pair(structure_target, NativeValue::object({
        {"source", NativeValue::number(4.0)},
    })).summary().skylight_columns.size());
    VWB_EXPECT_EQ(1U, run_pair(NativeValue::object({
        {"source", NativeValue::string("short")},
    }), NativeValue::object({})).summary().skylight_columns.size());
    const NativeTerrainEditCompiledBatch player = drain_deformation(
        deformation_request(std::make_shared<FakePinnedSource>()), 2U);
    VWB_EXPECT_EQ(1U, player.summary().skylight_columns.size());
}

VWB_TEST(native_surface_deformation_uses_effective_projection_but_clones_only_durable_terrain) {
    auto source = std::make_shared<FakePinnedSource>();
    source->projection({0, 0}, 3.0, 7U);
    source->add(cell_state({0, 1, 0}, TerrainMaterialId::mud, true, 1.0,
        {}, NativeValue::object({{"source", NativeValue::string("scene_block")}})));
    source->add_durable(cell_state({0, 1, 0}, TerrainMaterialId::stone, true, 1.0,
        "durable", NativeValue::object({{"source", NativeValue::string("durable")}}), false,
        NativeBlockIdentity::create("durable.stone")));
    NativeTerrainEditCompileRequest request = deformation_request(source, {0.5, 2.5, 0.5});
    const NativeTerrainEditCompiledBatch batch = drain_deformation(std::move(request), 2U);
    const auto found = std::find_if(batch.compiled_operations().begin(), batch.compiled_operations().end(),
        [](const NativeTerrainEditCompiledOperation &operation) {
            return operation.classification == NativeTerrainEditCellClassification::excavation_boundary;
        });
    VWB_EXPECT(found != batch.compiled_operations().end());
    VWB_EXPECT_EQ(TerrainMaterialId::stone, found->operation.state->material);
    VWB_EXPECT_EQ(std::string("durable.stone"), found->operation.state->block_id->value());
    VWB_EXPECT_EQ(0U, source->read_count());
    VWB_EXPECT_EQ(7U, batch.summary().projection_candidate_reads);

    const NativeTerrainEditCompiledBatch generated = drain_deformation(
        deformation_request(std::make_shared<FakePinnedSource>()), 2U);
    const NativeCellState &generated_boundary = *generated.compiled_operations()[0].operation.state;
    VWB_EXPECT_EQ(TerrainMaterialId::stone, generated_boundary.material);
    VWB_EXPECT_EQ(TerrainBiomeId::forest, generated_boundary.biome);
    VWB_EXPECT_EQ(std::string("stone"), generated_boundary.block_id->value());
}

VWB_TEST(native_surface_deformation_is_advance_budget_invariant_and_requires_resumable_api) {
    const NativeTerrainEditCompiledBatch one = drain_deformation(
        deformation_request(std::make_shared<FakePinnedSource>()), 1U);
    const NativeTerrainEditCompiledBatch two = drain_deformation(
        deformation_request(std::make_shared<FakePinnedSource>()), 2U);
    const NativeTerrainEditCompiledBatch eight = drain_deformation(
        deformation_request(std::make_shared<FakePinnedSource>()), 8U);
    expect_same_batch(one, two);
    expect_same_batch(one, eight);
    expect_reason(NativeTerrainEditCompileRejectReason::unsupported_shape,
        deformation_request(std::make_shared<FakePinnedSource>()));
}

VWB_TEST(native_surface_deformation_job_owns_pin_and_cancellation_publishes_no_partial_batch) {
    auto source = std::make_shared<FakePinnedSource>();
    std::weak_ptr<FakePinnedSource> lifetime = source;
    {
        NativeTerrainEditCompileJob planning = NativeTerrainEditResumableCompiler::begin(
            deformation_request(source));
        source.reset();
        VWB_EXPECT(!lifetime.expired());
        while (planning.status() == NativeTerrainEditCompileJobStatus::running
            && planning.progress().projection_queries == 0U) planning.advance(1U);
        planning.cancel();
        VWB_EXPECT_EQ(NativeTerrainEditCompileJobStatus::cancelled, planning.status());
        VWB_EXPECT(!planning.take_completed_batch().has_value());
        VWB_EXPECT(!lifetime.expired());
        VWB_EXPECT(planning.retained_entries_for_off_worker_destruction() > 0U);
        planning.cancel();
        planning.advance(1U);
    }
    VWB_EXPECT(lifetime.expired());

    auto projection_source = std::make_shared<FakePinnedSource>();
    NativeTerrainEditCompileJob projection = NativeTerrainEditResumableCompiler::begin(
        deformation_request(projection_source));
    while (projection.status() == NativeTerrainEditCompileJobStatus::running
        && projection.progress().projection_queries == 0U) projection.advance(1U);
    projection.cancel();
    VWB_EXPECT_EQ(NativeTerrainEditCompileJobStatus::cancelled, projection.status());

    auto cell_source = std::make_shared<FakePinnedSource>();
    NativeTerrainEditCompileJob cells = NativeTerrainEditResumableCompiler::begin(
        deformation_request(cell_source));
    while (cells.status() == NativeTerrainEditCompileJobStatus::running
        && cells.progress().prepared_operations == 0U) cells.advance(1U);
    cells.cancel();
    VWB_EXPECT(!cells.take_completed_batch().has_value());

    auto final_source = std::make_shared<FakePinnedSource>();
    NativeTerrainEditCompileJob finalization = NativeTerrainEditResumableCompiler::begin(
        deformation_request(final_source));
    while (finalization.status() == NativeTerrainEditCompileJobStatus::running
        && finalization.progress().prepared_operations < 3U) finalization.advance(1U);
    finalization.advance(4U);
    finalization.cancel();
    VWB_EXPECT_EQ(NativeTerrainEditCompileJobStatus::cancelled, finalization.status());
}

VWB_TEST(native_surface_deformation_clamps_negative_radius_and_drop_and_handles_negative_slopes) {
    auto source = std::make_shared<FakePinnedSource>();
    source->projection({-1, -1}, 2.25, 3U);
    NativeTerrainEditCompileRequest request = deformation_request(
        source, {-0.5, 1.75, -0.5}, -50.0, -20.0);
    request.shapes[0].target.light = NativeCellLight{0, 0};
    const NativeTerrainEditCompiledBatch batch = drain_deformation(std::move(request), 1U);
    VWB_EXPECT(!batch.compiled_operations().empty());
    VWB_EXPECT_EQ(-1, batch.summary().legacy_changed_columns[0].x);
    VWB_EXPECT_EQ(-1, batch.summary().legacy_changed_columns[0].z);
    VWB_EXPECT_EQ(3U, batch.summary().projection_candidate_reads);
    for (const auto &operation : batch.compiled_operations()) {
        if (operation.classification == NativeTerrainEditCellClassification::direct_target) {
            VWB_EXPECT_EQ(0U, operation.operation.state->light.sky);
            VWB_EXPECT_EQ(0U, operation.operation.state->light.block);
        }
    }

    auto slope = std::make_shared<FakePinnedSource>();
    slope->projection_defaults(1.5, 1U);
    slope->projection({0, 0}, 1.5, 1U);
    slope->projection({1, 0}, 2.25, 2U);
    slope->projection({0, 1}, 0.75, 3U);
    const NativeTerrainEditCompiledBatch sloped = drain_deformation(
        deformation_request(slope, {0.5, 1.5, 0.5}, 1.6, 1.0), 2U);
    VWB_EXPECT(sloped.summary().legacy_changed_columns.size() >= 3U);
    VWB_EXPECT(sloped.summary().projection_candidate_reads >= 6U);
}

VWB_TEST(native_surface_deformation_freezes_falloff_threshold_and_both_target_branches) {
    auto threshold = std::make_shared<FakePinnedSource>();
    const NativeTerrainEditCompiledBatch near_edge = drain_deformation(
        deformation_request(threshold, {0.5, 1.5, 0.5}, 1.01, 0.35), 3U);
    VWB_EXPECT_EQ(1U, near_edge.summary().projection_queries);

    auto shallow = std::make_shared<FakePinnedSource>();
    const NativeTerrainEditCompiledBatch shallow_batch = drain_deformation(
        deformation_request(shallow, {0.5, 100.0, 0.5}, 1.1, 0.35), 3U);
    VWB_EXPECT_EQ(5U, shallow_batch.summary().projection_queries);
    VWB_EXPECT_EQ(4U, shallow_batch.summary().y_candidates);

    auto surface_target = std::make_shared<FakePinnedSource>();
    surface_target->projection_defaults(1.5, 1U);
    const NativeTerrainEditCompiledBatch surface_wins = drain_deformation(
        deformation_request(surface_target, {0.5, 1.5, 0.5}, 0.75, 1.0), 1U);
    const auto direct = std::find_if(surface_wins.compiled_operations().begin(),
        surface_wins.compiled_operations().end(), [](const auto &operation) {
            return operation.classification == NativeTerrainEditCellClassification::direct_target;
        });
    VWB_EXPECT(direct != surface_wins.compiled_operations().end());
    VWB_EXPECT_EQ(double_bits(-1.0), double_bits(direct->operation.state->density));
}

VWB_TEST(native_surface_deformation_skips_nonsolid_boundary_and_preserves_float32_coordinate_math) {
    auto air = std::make_shared<FakePinnedSource>(FakePinnedSource::Fallback::air);
    const NativeTerrainEditCompiledBatch no_boundary = drain_deformation(
        deformation_request(air), 4U);
    VWB_EXPECT_EQ(2U, no_boundary.compiled_operations().size());
    VWB_EXPECT_EQ(0U, no_boundary.summary().excavation_boundary_operations);

    auto large = std::make_shared<FakePinnedSource>();
    const double threshold = 16'777'216.5;
    const NativeTerrainEditCompiledBatch first = drain_deformation(
        deformation_request(large, {threshold, 1.5, -threshold}, 0.75, 0.35), 1U);
    const NativeTerrainEditCompiledBatch second = drain_deformation(
        deformation_request(std::make_shared<FakePinnedSource>(),
            {threshold, 1.5, -threshold}, 0.75, 0.35), 32U);
    expect_same_batch(first, second);
    VWB_EXPECT(!first.summary().legacy_changed_columns.empty());
}

VWB_TEST(native_surface_deformation_rejects_invalid_ownership_shapes_projection_and_hard_limits) {
    auto source = std::make_shared<FakePinnedSource>();
    NativeTerrainEditCompileRequest request = deformation_request(source);
    request.shapes.push_back(NativeTerrainEditShape::inclusive_box(
        {0, 0, 0}, {0, 0, 0}, stone_template(), "mixed"));
    expect_job_reason(NativeTerrainEditCompileRejectReason::mixed_surface_deformation, request);
    request = deformation_request(source);
    request.shapes.clear();
    expect_job_reason(NativeTerrainEditCompileRejectReason::mixed_surface_deformation, request);
    request = deformation_request(source);
    request.shapes = {NativeTerrainEditShape::inclusive_box(
        {0, 0, 0}, {0, 0, 0}, stone_template(), "not-deformation")};
    expect_job_reason(NativeTerrainEditCompileRejectReason::mixed_surface_deformation, request);
    request = deformation_request(source);
    request.owned_source.reset();
    expect_job_reason(NativeTerrainEditCompileRejectReason::source_required, request);
    request = deformation_request(source);
    FakePinnedSource other;
    request.source = &other;
    expect_job_reason(NativeTerrainEditCompileRejectReason::invalid_request, request);
    auto untrusted = std::make_shared<FakePinnedSource>();
    untrusted->bounded_prevalidated(false);
    expect_job_reason(NativeTerrainEditCompileRejectReason::source_contract_missing,
        deformation_request(untrusted));
    VWB_EXPECT_EQ(0U, untrusted->projection_query_count());
    VWB_EXPECT_EQ(0U, untrusted->size_query_count());
    NativeTerrainEditCompileRequest derived_air = deformation_request(source);
    derived_air.shapes[0].target.solid.reset();
    const NativeTerrainEditCompiledBatch derived_air_batch = drain_deformation(derived_air, 2U);
    const NativeTerrainEditCompiledBatch explicit_air_batch = drain_deformation(
        deformation_request(std::make_shared<FakePinnedSource>()), 2U);
    expect_same_batch(derived_air_batch, explicit_air_batch);
    VWB_EXPECT(!derived_air_batch.compiled_operations()[1].operation.state->solid);
    request = deformation_request(source);
    request.shapes[0].drop_depth = std::numeric_limits<double>::quiet_NaN();
    expect_job_reason(NativeTerrainEditCompileRejectReason::invalid_request, request);
    request = deformation_request(source);
    request.shapes[0].target.metadata = NativeValue::object({
        {"source", NativeValue::number(3.0)},
    });
    expect_job_reason(NativeTerrainEditCompileRejectReason::invalid_request, request);
    request = deformation_request(source);
    request.shapes[0].target.metadata = NativeValue::object({
        {"zzz", NativeValue::boolean(true)},
    });
    VWB_EXPECT(!drain_deformation(request, 4U).compiled_operations().empty());
    request = deformation_request(source);
    request.shapes[0].center.x = std::numeric_limits<double>::max();
    expect_job_reason(NativeTerrainEditCompileRejectReason::invalid_request, request);

    request = deformation_request(source);
    request.limits.max_columns = 1U;
    expect_job_reason(NativeTerrainEditCompileRejectReason::column_limit_exceeded, request);
    request = deformation_request(source);
    request.limits.max_columns = 6U;
    expect_job_reason(NativeTerrainEditCompileRejectReason::column_limit_exceeded, request);
    request = deformation_request(source);
    request.limits.max_candidate_visits = 1U;
    expect_job_reason(NativeTerrainEditCompileRejectReason::candidate_limit_exceeded, request);
    request = deformation_request(source);
    request.limits.max_y_candidates = 1U;
    expect_job_reason(NativeTerrainEditCompileRejectReason::y_candidate_limit_exceeded, request);
    request = deformation_request(source);
    request.limits.max_candidate_visits = 17U;
    expect_job_reason(NativeTerrainEditCompileRejectReason::candidate_limit_exceeded, request);
    request = deformation_request(source);
    request.limits.max_operations = 1U;
    expect_job_reason(NativeTerrainEditCompileRejectReason::operation_limit_exceeded, request);
    request = deformation_request(source);
    request.limits.max_prepared_bytes = 39U;
    expect_job_reason(NativeTerrainEditCompileRejectReason::prepared_byte_limit_exceeded, request);

    const NativeTerrainEditCompiledBatch measured = drain_deformation(deformation_request(source), 2U);
    request = deformation_request(source);
    request.limits.max_prepared_bytes = measured.summary().prepared_bytes;
    VWB_EXPECT_EQ(measured.summary().prepared_bytes,
        drain_deformation(request, 3U).summary().prepared_bytes);
    request = deformation_request(source);
    request.limits.max_prepared_bytes = measured.summary().prepared_bytes - 1U;
    expect_job_reason(NativeTerrainEditCompileRejectReason::prepared_byte_limit_exceeded, request);

    auto missing_projection = std::make_shared<FakePinnedSource>();
    missing_projection->projection_missing(true);
    expect_job_reason(NativeTerrainEditCompileRejectReason::projection_missing,
        deformation_request(missing_projection));
    auto excess_projection = std::make_shared<FakePinnedSource>();
    excess_projection->projection_defaults(2.0, 6U);
    excess_projection->respect_projection_allowance(false);
    request = deformation_request(excess_projection);
    request.limits.max_projection_reads_per_query = 5U;
    expect_job_reason(NativeTerrainEditCompileRejectReason::projection_limit_exceeded, request);
    auto exhausted_projection = std::make_shared<FakePinnedSource>();
    exhausted_projection->projection_defaults(2.0, 1U);
    request = deformation_request(exhausted_projection, {0.5, 100.0, 0.5}, 1.1, 0.35);
    request.limits.max_projection_reads = 1U;
    expect_job_reason(NativeTerrainEditCompileRejectReason::projection_limit_exceeded, request);
    auto mismatch_projection = std::make_shared<FakePinnedSource>();
    mismatch_projection->projection_mismatch(true);
    expect_job_reason(NativeTerrainEditCompileRejectReason::source_cell_mismatch,
        deformation_request(mismatch_projection));
    auto nan_projection = std::make_shared<FakePinnedSource>();
    nan_projection->projection_defaults(std::numeric_limits<double>::quiet_NaN(), 1U);
    expect_job_reason(NativeTerrainEditCompileRejectReason::source_cell_mismatch,
        deformation_request(nan_projection));

    auto missing_cell = std::make_shared<FakePinnedSource>(FakePinnedSource::Fallback::missing);
    expect_job_reason(NativeTerrainEditCompileRejectReason::source_cell_missing,
        deformation_request(missing_cell));
    auto mismatch_cell = std::make_shared<FakePinnedSource>();
    mismatch_cell->durable_mismatch(true);
    expect_job_reason(NativeTerrainEditCompileRejectReason::source_cell_mismatch,
        deformation_request(mismatch_cell));
}

VWB_TEST(native_surface_deformation_preflights_request_metadata_before_normalized_copy) {
    auto source = std::make_shared<FakePinnedSource>();
    NativeTerrainEditCompileRequest ordinary = deformation_request(source);
    NativeTerrainEditCompileJob measured = NativeTerrainEditResumableCompiler::begin(ordinary);
    VWB_EXPECT_EQ(NativeTerrainEditCompileJobStatus::running, measured.status());
    const std::size_t admitted = measured.progress().prepared_bytes;
    const std::size_t retained = measured.retained_entries_for_off_worker_destruction();
    VWB_EXPECT(retained > 2U);
    measured.cancel();
    VWB_EXPECT_EQ(retained, measured.retained_entries_for_off_worker_destruction());

    NativeTerrainEditCompileRequest spare = deformation_request(source);
    spare.shapes.reserve(10000U);
    NativeTerrainEditCompileJob spare_job = NativeTerrainEditResumableCompiler::begin(spare);
    VWB_EXPECT_EQ(admitted, spare_job.progress().prepared_bytes);
    spare_job.cancel();

    NativeTerrainEditCompileRequest exact = deformation_request(source);
    exact.limits.max_prepared_bytes = admitted;
    NativeTerrainEditCompileJob exact_job = NativeTerrainEditResumableCompiler::begin(exact);
    VWB_EXPECT_EQ(NativeTerrainEditCompileJobStatus::running, exact_job.status());
    exact_job.cancel();
    NativeTerrainEditCompileRequest under = deformation_request(source);
    under.limits.max_prepared_bytes = admitted - 1U;
    NativeTerrainEditCompileJob under_job = NativeTerrainEditResumableCompiler::begin(under);
    VWB_EXPECT_EQ(NativeTerrainEditCompileJobStatus::rejected, under_job.status());
    VWB_EXPECT_EQ(NativeTerrainEditCompileRejectReason::prepared_byte_limit_exceeded,
        *under_job.reject_reason());
    VWB_EXPECT_EQ(0U, under_job.retained_entries_for_off_worker_destruction());
    VWB_EXPECT_EQ(0U, source->projection_query_count());
    VWB_EXPECT_EQ(0U, source->size_query_count());

    auto boundary_source = std::make_shared<FakePinnedSource>();
    NativeTerrainEditCompileRequest boundary = deformation_request(boundary_source);
    boundary.shapes[0].provenance_id = std::string(4096U, 'p');
    boundary.shapes[0].target.block_id = NativeBlockIdentity::create("air.surface_boundary");
    boundary.shapes[0].target.metadata = NativeValue::object({
        {"payload", NativeValue::string(std::string(60U * 1024U, 'm'))},
        {"source", NativeValue::string("player_dig")},
    });
    NativeTerrainEditCompileJob boundary_measured =
        NativeTerrainEditResumableCompiler::begin(boundary);
    VWB_EXPECT_EQ(NativeTerrainEditCompileJobStatus::running, boundary_measured.status());
    const std::size_t boundary_admitted = boundary_measured.progress().prepared_bytes;
    VWB_EXPECT(boundary_admitted > 3U * 60U * 1024U);
    boundary_measured.cancel();
    boundary.limits.max_prepared_bytes = boundary_admitted;
    NativeTerrainEditCompileJob boundary_exact =
        NativeTerrainEditResumableCompiler::begin(boundary);
    VWB_EXPECT_EQ(NativeTerrainEditCompileJobStatus::running, boundary_exact.status());
    boundary_exact.cancel();
    boundary.limits.max_prepared_bytes = boundary_admitted - 1U;
    expect_job_reason(NativeTerrainEditCompileRejectReason::prepared_byte_limit_exceeded,
        boundary);
    VWB_EXPECT_EQ(0U, boundary_source->projection_query_count());
    VWB_EXPECT_EQ(0U, boundary_source->size_query_count());

    NativeTerrainEditCompileRequest recursive = deformation_request(
        std::make_shared<FakePinnedSource>());
    recursive.shapes[0].target.block_id = NativeBlockIdentity::create("air.custom");
    recursive.shapes[0].target.metadata = NativeValue::object({
        {"nested", NativeValue::array({
            NativeValue::null(), NativeValue::number(2.5),
            NativeValue::object({{"leaf", NativeValue::string("value")}}),
        })},
        {"source", NativeValue::string("player_dig")},
    });
    VWB_EXPECT(!drain_deformation(recursive, 4U).compiled_operations().empty());
    recursive.limits.max_metadata_depth = 1U;
    expect_job_reason(NativeTerrainEditCompileRejectReason::invalid_request, recursive);
    recursive.limits.max_metadata_depth = NativeValueLimits::MAX_DEPTH;
    recursive.limits.max_metadata_text_bytes = 1U;
    expect_job_reason(NativeTerrainEditCompileRejectReason::invalid_request, recursive);
    recursive.limits.max_metadata_text_bytes = 50U;
    recursive.shapes[0].target.metadata = NativeValue::object({
        {"a", NativeValue::string(std::string(100U, 'x'))},
        {"source", NativeValue::string("player_dig")},
    });
    expect_job_reason(NativeTerrainEditCompileRejectReason::invalid_request, recursive);
    recursive.shapes[0].target.metadata = NativeValue::boolean(true);
    expect_job_reason(NativeTerrainEditCompileRejectReason::invalid_request, recursive);

    NativeTerrainEditCompileRequest injected_nodes = deformation_request(source);
    injected_nodes.shapes[0].target.metadata = NativeValue::object({});
    injected_nodes.limits.max_metadata_nodes = 4U;
    expect_job_reason(NativeTerrainEditCompileRejectReason::invalid_request, injected_nodes);
    injected_nodes.limits.max_metadata_nodes = NativeValueLimits::MAX_NODES;
    injected_nodes.limits.max_metadata_text_bytes = 10U;
    expect_job_reason(NativeTerrainEditCompileRejectReason::invalid_request, injected_nodes);

    NativeValue::Object maximum;
    maximum.reserve(NativeValueLimits::MAX_CONTAINER_ENTRIES);
    for (std::size_t index = 0U; index < 1020U; ++index) {
        std::string digits = std::to_string(index);
        maximum.push_back({"a" + std::string(4U - digits.size(), '0') + digits,
            NativeValue::boolean(false)});
    }
    maximum.push_back({"saveDelta", NativeValue::boolean(false)});
    maximum.push_back({"source", NativeValue::string("player_dig")});
    maximum.push_back({"surfaceProjectionAffects", NativeValue::boolean(false)});
    maximum.push_back({"terrainMeshAffects", NativeValue::boolean(false)});
    NativeTerrainEditCompileRequest near_max = deformation_request(
        std::make_shared<FakePinnedSource>());
    near_max.shapes[0].target.metadata = NativeValue::object(std::move(maximum));
    near_max.limits.max_metadata_nodes = 1025U;
    VWB_EXPECT(!drain_deformation(near_max, 32U).compiled_operations().empty());
    near_max.limits.max_metadata_nodes = 1024U;
    expect_job_reason(NativeTerrainEditCompileRejectReason::invalid_request, near_max);

    NativeValue::Object over;
    over.reserve(NativeValueLimits::MAX_CONTAINER_ENTRIES - 1U);
    for (std::size_t index = 0U; index < 1021U; ++index) {
        std::string digits = std::to_string(index);
        over.push_back({"a" + std::string(4U - digits.size(), '0') + digits,
            NativeValue::boolean(false)});
    }
    over.push_back({"source", NativeValue::string("player_dig")});
    NativeTerrainEditCompileRequest injected_over = deformation_request(source);
    injected_over.shapes[0].target.metadata = NativeValue::object(std::move(over));
    expect_job_reason(NativeTerrainEditCompileRejectReason::invalid_request, injected_over);
    VWB_EXPECT_EQ(0U, source->projection_query_count());
}

VWB_TEST(native_surface_deformation_precharges_physical_cells_and_rejects_lying_sources) {
    auto missing = std::make_shared<FakePinnedSource>();
    missing->declared_cell_bytes(std::nullopt);
    expect_job_reason(NativeTerrainEditCompileRejectReason::source_cell_size_missing,
        deformation_request(missing));
    VWB_EXPECT(missing->size_query_count() > 0U);
    VWB_EXPECT_EQ(0U, missing->durable_read_count());

    auto zero = std::make_shared<FakePinnedSource>();
    zero->declared_cell_bytes(0U);
    expect_job_reason(NativeTerrainEditCompileRejectReason::source_cell_size_missing,
        deformation_request(zero));
    VWB_EXPECT_EQ(0U, zero->durable_read_count());

    auto too_large = std::make_shared<FakePinnedSource>();
    too_large->declared_cell_bytes(64U * 1024U * 1024U);
    expect_job_reason(NativeTerrainEditCompileRejectReason::prepared_byte_limit_exceeded,
        deformation_request(too_large));
    VWB_EXPECT_EQ(0U, too_large->durable_read_count());

    auto overflow = std::make_shared<FakePinnedSource>();
    overflow->declared_cell_bytes(std::numeric_limits<std::size_t>::max());
    expect_job_reason(NativeTerrainEditCompileRejectReason::source_cell_size_mismatch,
        deformation_request(overflow));
    VWB_EXPECT_EQ(0U, overflow->durable_read_count());

    auto lying = std::make_shared<FakePinnedSource>();
    lying->declared_cell_bytes(1U);
    expect_job_reason(NativeTerrainEditCompileRejectReason::source_cell_size_mismatch,
        deformation_request(lying));
    VWB_EXPECT(lying->durable_read_count() > 0U);

    std::string spare_text("kept");
    spare_text.reserve(48U * 1024U);
    auto conservative = std::make_shared<FakePinnedSource>();
    conservative->declared_cell_bytes(128U * 1024U);
    conservative->add_durable(cell_state({0, 0, 0}, TerrainMaterialId::stone, true, 1.0,
        {}, NativeValue::object({
            {"custom", NativeValue::string(std::move(spare_text))},
            {"nested", NativeValue::array({NativeValue::boolean(true)})},
        })));
    const NativeTerrainEditCompiledBatch batch = drain_deformation(
        deformation_request(conservative), 2U);
    VWB_EXPECT(!batch.compiled_operations().empty());
    VWB_EXPECT(conservative->durable_read_count() > 0U);
}

VWB_TEST(native_surface_deformation_rejects_every_zero_limit_and_translates_source_errors) {
    auto source = std::make_shared<FakePinnedSource>();
    for (std::size_t index = 0; index < 10U; ++index) {
        NativeTerrainEditCompileRequest request = deformation_request(source);
        if (index == 0U) request.limits.max_candidate_visits = 0U;
        else if (index == 1U) request.limits.max_operations = 0U;
        else if (index == 2U) request.limits.max_columns = 0U;
        else if (index == 3U) request.limits.max_projection_reads = 0U;
        else if (index == 4U) request.limits.max_projection_reads_per_query = 0U;
        else if (index == 5U) request.limits.max_y_candidates = 0U;
        else if (index == 6U) request.limits.max_prepared_bytes = 0U;
        else if (index == 7U) request.limits.max_metadata_nodes = 0U;
        else if (index == 8U) request.limits.max_metadata_text_bytes = 0U;
        else request.limits.max_metadata_depth = 0U;
        expect_job_reason(NativeTerrainEditCompileRejectReason::invalid_request, request);
    }
    NativeTerrainEditCompileRequest invalid_cell_size = deformation_request(source);
    invalid_cell_size.cell_size = 0.0;
    expect_job_reason(NativeTerrainEditCompileRejectReason::invalid_request, invalid_cell_size);
    invalid_cell_size = deformation_request(source);
    invalid_cell_size.cell_size = std::numeric_limits<double>::quiet_NaN();
    expect_job_reason(NativeTerrainEditCompileRejectReason::invalid_request, invalid_cell_size);
    NativeTerrainEditCompileRequest overflow = deformation_request(
        source, {2147483520.0, 1.5, 0.5}, 127.0, 0.35);
    expect_job_reason(NativeTerrainEditCompileRejectReason::invalid_request, overflow);
    overflow = deformation_request(source, {-2147483520.0, 1.5, 0.5}, 128.0, 0.35);
    expect_job_reason(NativeTerrainEditCompileRejectReason::invalid_request, overflow);
    overflow = deformation_request(source);
    overflow.shapes[0].drop_depth = std::numeric_limits<double>::max();
    expect_job_reason(NativeTerrainEditCompileRejectReason::invalid_request, overflow);
    auto target_overflow = std::make_shared<FakePinnedSource>();
    target_overflow->projection_defaults(-std::numeric_limits<double>::max(), 1U);
    overflow = deformation_request(target_overflow);
    overflow.shapes[0].drop_depth = std::numeric_limits<double>::max();
    expect_job_reason(NativeTerrainEditCompileRejectReason::invalid_request, overflow);

    NativeValue::Object maximum_metadata;
    maximum_metadata.reserve(NativeValueLimits::MAX_CONTAINER_ENTRIES);
    maximum_metadata.push_back({"source", NativeValue::string("player_dig")});
    for (std::size_t index = 1; index < NativeValueLimits::MAX_CONTAINER_ENTRIES; ++index) {
        std::string digits = std::to_string(index);
        maximum_metadata.push_back({"z" + std::string(4U - digits.size(), '0') + digits,
            NativeValue::boolean(false)});
    }
    NativeTerrainEditCompileRequest metadata_overflow = deformation_request(source);
    metadata_overflow.shapes[0].target.metadata = NativeValue::object(std::move(maximum_metadata));
    expect_job_reason(NativeTerrainEditCompileRejectReason::invalid_request, metadata_overflow);
    auto rejected = std::make_shared<FakePinnedSource>();
    rejected->projection_throws_rejected(true);
    expect_job_reason(NativeTerrainEditCompileRejectReason::projection_limit_exceeded,
        deformation_request(rejected));
    auto invalid = std::make_shared<FakePinnedSource>();
    invalid->projection_throws_invalid(true);
    expect_job_reason(NativeTerrainEditCompileRejectReason::invalid_request,
        deformation_request(invalid));

    auto runtime_failure = std::make_shared<FakePinnedSource>();
    runtime_failure->projection_failure(FakePinnedSource::CallbackFailure::runtime_error);
    NativeTerrainEditCompileJob runtime_job = NativeTerrainEditResumableCompiler::begin(
        deformation_request(runtime_failure));
    while (runtime_job.status() == NativeTerrainEditCompileJobStatus::running) {
        runtime_job.advance(1U);
    }
    VWB_EXPECT_EQ(NativeTerrainEditCompileJobStatus::rejected, runtime_job.status());
    VWB_EXPECT_EQ(NativeTerrainEditCompileRejectReason::source_callback_failure,
        *runtime_job.reject_reason());
    const NativeTerrainEditCompileProgress runtime_progress = runtime_job.progress();
    const std::size_t runtime_calls = runtime_failure->projection_query_count();
    runtime_job.advance(64U);
    VWB_EXPECT_EQ(runtime_calls, runtime_failure->projection_query_count());
    VWB_EXPECT_EQ(runtime_progress.advance_calls, runtime_job.progress().advance_calls);
    VWB_EXPECT_EQ(runtime_progress.work_units, runtime_job.progress().work_units);
    VWB_EXPECT_EQ(runtime_progress.projection_queries, runtime_job.progress().projection_queries);

    auto allocation_failure = std::make_shared<FakePinnedSource>();
    allocation_failure->physical_failure(FakePinnedSource::CallbackFailure::bad_alloc);
    NativeTerrainEditCompileJob allocation_job = NativeTerrainEditResumableCompiler::begin(
        deformation_request(allocation_failure));
    while (allocation_job.status() == NativeTerrainEditCompileJobStatus::running) {
        allocation_job.advance(2U);
    }
    VWB_EXPECT_EQ(NativeTerrainEditCompileJobStatus::rejected, allocation_job.status());
    VWB_EXPECT_EQ(NativeTerrainEditCompileRejectReason::source_callback_failure,
        *allocation_job.reject_reason());
    const NativeTerrainEditCompileProgress allocation_progress = allocation_job.progress();
    const std::size_t allocation_calls = allocation_failure->durable_read_count();
    allocation_job.advance(64U);
    VWB_EXPECT_EQ(allocation_calls, allocation_failure->durable_read_count());
    VWB_EXPECT_EQ(allocation_progress.advance_calls, allocation_job.progress().advance_calls);
    VWB_EXPECT_EQ(allocation_progress.work_units, allocation_job.progress().work_units);
    VWB_EXPECT_EQ(allocation_progress.prepared_operations,
        allocation_job.progress().prepared_operations);
    NativeTerrainEditCompileJob zero = NativeTerrainEditResumableCompiler::begin(
        deformation_request(source));
    const std::size_t zero_retained = zero.retained_entries_for_off_worker_destruction();
    VWB_EXPECT(zero_retained > 0U);
    zero.advance(0U);
    VWB_EXPECT_EQ(NativeTerrainEditCompileJobStatus::rejected, zero.status());
    VWB_EXPECT_EQ(NativeTerrainEditCompileRejectReason::invalid_request, *zero.reject_reason());
    VWB_EXPECT_EQ(zero_retained, zero.retained_entries_for_off_worker_destruction());
}

VWB_TEST(native_surface_deformation_detects_source_drift_and_blocks_revision_only_commit) {
    auto digest = std::make_shared<SurfaceDriftingPinnedSource>(
        SurfaceDriftingPinnedSource::Drift::digest);
    expect_job_reason(NativeTerrainEditCompileRejectReason::source_drift,
        deformation_request(digest));
    auto revision = std::make_shared<SurfaceDriftingPinnedSource>(
        SurfaceDriftingPinnedSource::Drift::revision);
    expect_job_reason(NativeTerrainEditCompileRejectReason::source_drift,
        deformation_request(revision));

    auto source = std::make_shared<FakePinnedSource>();
    source->revision(0U);
    const NativeTerrainEditCompiledBatch batch = drain_deformation(
        deformation_request(source), 2U);
    try {
        static_cast<void>(batch.make_transaction("surface:commit", 0U));
        VWB_EXPECT(false);
    } catch (const NativeTerrainEditCompileRejected &error) {
        VWB_EXPECT_EQ(NativeTerrainEditCompileRejectReason::identity_bound_commit_required,
            error.reason());
    }
}

VWB_TEST(native_surface_deformation_cancel_and_reject_retain_large_state_for_off_worker_retirement) {
    auto cancel_source = std::make_shared<FakePinnedSource>();
    NativeTerrainEditCompileJob cancelled = NativeTerrainEditResumableCompiler::begin(
        deformation_request(cancel_source, {0.5, 2.0, 0.5}, 4.0, 1.0));
    while (cancelled.status() == NativeTerrainEditCompileJobStatus::running
        && cancelled.progress().prepared_operations < 50U) cancelled.advance(8U);
    VWB_EXPECT(cancelled.progress().prepared_operations >= 50U);
    const std::size_t retained_before = cancelled.retained_entries_for_off_worker_destruction();
    VWB_EXPECT(retained_before >= 100U);
    NativeTerrainEditCompileJob moved_cancel = std::move(cancelled);
    VWB_EXPECT_EQ(0U, cancelled.retained_entries_for_off_worker_destruction());
    VWB_EXPECT_EQ(retained_before, moved_cancel.retained_entries_for_off_worker_destruction());
    moved_cancel.cancel();
    VWB_EXPECT_EQ(retained_before, moved_cancel.retained_entries_for_off_worker_destruction());

    auto reject_source = std::make_shared<FakePinnedSource>();
    NativeTerrainEditCompileRequest request = deformation_request(
        reject_source, {0.5, 2.0, 0.5}, 4.0, 1.0);
    request.limits.max_operations = 32U;
    NativeTerrainEditCompileJob rejected = NativeTerrainEditResumableCompiler::begin(std::move(request));
    while (rejected.status() == NativeTerrainEditCompileJobStatus::running) rejected.advance(8U);
    VWB_EXPECT_EQ(NativeTerrainEditCompileJobStatus::rejected, rejected.status());
    VWB_EXPECT_EQ(NativeTerrainEditCompileRejectReason::operation_limit_exceeded,
        *rejected.reject_reason());
    VWB_EXPECT(rejected.retained_entries_for_off_worker_destruction() >= 64U);
}

VWB_TEST(native_surface_deformation_filters_unchanged_final_states_but_retains_legacy_order) {
    const NativeTerrainEditCompiledBatch initial = drain_deformation(
        deformation_request(std::make_shared<FakePinnedSource>()), 2U);
    auto source = std::make_shared<FakePinnedSource>();
    for (const auto &operation : initial.compiled_operations()) {
        source->add_durable(*operation.operation.state);
    }
    const NativeTerrainEditCompiledBatch filtered = drain_deformation(
        deformation_request(source), 3U);
    VWB_EXPECT(filtered.compiled_operations().empty());
    VWB_EXPECT_EQ(3U, filtered.summary().unchanged_filtered);
    VWB_EXPECT_EQ(0U, filtered.summary().changed_cells);
    VWB_EXPECT_EQ(3U, filtered.summary().legacy_changed_cells.size());
}

VWB_TEST(native_surface_deformation_job_move_and_result_state_are_explicit) {
    NativeTerrainEditCompileJob original = NativeTerrainEditResumableCompiler::begin(
        deformation_request(std::make_shared<FakePinnedSource>()));
    NativeTerrainEditCompileJob moved = std::move(original);
    VWB_EXPECT_EQ(NativeTerrainEditCompileJobStatus::cancelled, original.status());
    VWB_EXPECT_EQ(NativeTerrainEditCompileJobStatus::cancelled, original.progress().status);
    VWB_EXPECT(!original.reject_reason().has_value());
    VWB_EXPECT_EQ(0U, original.retained_entries_for_off_worker_destruction());
    original.advance(1U);
    original.cancel();
    VWB_EXPECT(!original.take_completed_batch().has_value());
    while (moved.status() == NativeTerrainEditCompileJobStatus::running) moved.advance(16U);
    VWB_EXPECT_EQ(NativeTerrainEditCompileJobStatus::completed, moved.status());
    moved.advance(1U);
    moved.cancel();
    VWB_EXPECT(moved.take_completed_batch().has_value());
    VWB_EXPECT_EQ(NativeTerrainEditCompileJobStatus::result_taken, moved.status());
    VWB_EXPECT(!moved.take_completed_batch().has_value());
}

VWB_TEST(native_surface_deformation_absent_source_metadata_and_unfiltered_output_are_exact) {
    auto source = std::make_shared<FakePinnedSource>();
    NativeTerrainEditCompileRequest request = deformation_request(source);
    request.omit_unchanged = false;
    request.shapes[0].target.metadata = NativeValue::object({});
    const NativeTerrainEditCompiledBatch batch = drain_deformation(std::move(request), 4096U);
    VWB_EXPECT_EQ(3U, batch.compiled_operations().size());
    VWB_EXPECT_EQ(std::string("player_dig"),
        metadata_value(batch.compiled_operations()[1].operation.state->metadata, "source")->as_string());
}

VWB_TEST(native_surface_deformation_handles_int32_minimum_final_y_without_wrap) {
    auto source = std::make_shared<FakePinnedSource>();
    source->projection_defaults(-2147483646.8, 1U);
    const NativeTerrainEditCompiledBatch batch = drain_deformation(
        deformation_request(source, {0.5, -2147483392.0, 0.5}, 0.75, 0.35), 1U);
    VWB_EXPECT(!batch.summary().legacy_changed_cells.empty());
    VWB_EXPECT_EQ(std::numeric_limits<std::int32_t>::min(),
        batch.summary().legacy_changed_cells.back().y);
}
