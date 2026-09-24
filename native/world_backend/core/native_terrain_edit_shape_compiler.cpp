#include "native_terrain_edit_shape_compiler.hpp"

#include <algorithm>
#include <cmath>
#include <cstdint>
#include <limits>
#include <map>
#include <set>
#include <utility>

namespace voxel::world_backend {
namespace {

struct CellLess {
    bool operator()(const CellCoord &left, const CellCoord &right) const noexcept {
        if (left.z != right.z) return left.z < right.z;
        if (left.y != right.y) return left.y < right.y;
        return left.x < right.x;
    }
};

struct PendingOperation {
    NativeCellState state;
    NativeTerrainEditShapeKind shape_kind = NativeTerrainEditShapeKind::inclusive_box;
    NativeTerrainEditCellClassification classification = NativeTerrainEditCellClassification::direct_target;
    std::size_t source_shape_index = 0;
    std::string provenance_id;
};

using SourceCellCache = std::map<CellCoord, NativeCellState, CellLess>;

[[noreturn]] void reject(const NativeTerrainEditCompileRejectReason reason) {
    throw NativeTerrainEditCompileRejected(reason);
}

std::string material_block_id(const TerrainMaterialId material) {
    switch (material) {
        case TerrainMaterialId::air: return "air";
        case TerrainMaterialId::grass: return "grass";
        case TerrainMaterialId::dirt: return "dirt";
        case TerrainMaterialId::stone: return "stone";
        case TerrainMaterialId::sand: return "sand";
        case TerrainMaterialId::snow: return "snow";
        case TerrainMaterialId::deep_stone: return "deepStone";
        case TerrainMaterialId::bedrock: return "bedrock";
        case TerrainMaterialId::clay: return "clay";
        case TerrainMaterialId::gravel: return "gravel";
        case TerrainMaterialId::coal_ore: return "coalOre";
        case TerrainMaterialId::iron_ore: return "ironOre";
        case TerrainMaterialId::crystal_ore: return "crystalOre";
        case TerrainMaterialId::copper_ore: return "copperOre";
        case TerrainMaterialId::mud: return "mud";
        case TerrainMaterialId::water: return "water";
        case TerrainMaterialId::lava: return "lava";
    }
    reject(NativeTerrainEditCompileRejectReason::invalid_request);
}

bool metadata_has_key(const NativeValue &metadata, const std::string &key) {
    const NativeValue::Object &object = metadata.as_object();
    const auto position = std::lower_bound(object.begin(), object.end(), key,
        [](const auto &entry, const std::string &needle) { return entry.first < needle; });
    return position != object.end() && position->first == key;
}

bool metadata_boolean_or_false(const NativeValue &metadata, const std::string &key) {
    const NativeValue::Object &object = metadata.as_object();
    const auto position = std::lower_bound(object.begin(), object.end(), key,
        [](const auto &entry, const std::string &needle) { return entry.first < needle; });
    if (position == object.end() || position->first != key) return false;
    const NativeValue &value = position->second;
    if (value.kind() == NativeValueKind::null_value) return false;
    if (value.kind() == NativeValueKind::boolean) return value.as_boolean();
    if (value.kind() == NativeValueKind::number) return value.as_number() != 0.0;
    if (value.kind() == NativeValueKind::string) return !value.as_string().empty();
    if (value.kind() == NativeValueKind::array) return !value.as_array().empty();
    return !value.as_object().empty();
}

bool resolved_solid(const NativeTerrainEditStateTemplate &target) noexcept {
    return target.solid.value_or(target.material != TerrainMaterialId::air);
}

NativeCellLight resolved_light(const NativeTerrainEditStateTemplate &target) noexcept {
    return target.light.value_or(NativeCellLight{
        resolved_solid(target) ? std::uint8_t{0} : std::uint8_t{15}, std::uint8_t{0}});
}

bool sphere_target_solid(const NativeTerrainEditStateTemplate &target) noexcept {
    // Positive-radius sphere admission below requires this field explicitly;
    // geometry must never silently substitute material-derived solidity.
    return target.solid.value_or(false);
}

NativeValue metadata_with(const NativeValue &metadata, std::string key, NativeValue value) {
    NativeValue::Object object = metadata.as_object();
    const auto position = std::lower_bound(object.begin(), object.end(), key,
        [](const auto &entry, const std::string &needle) { return entry.first < needle; });
    if (position != object.end() && position->first == key) {
        position->second = std::move(value);
    } else {
        object.insert(position, {std::move(key), std::move(value)});
    }
    return NativeValue::object(std::move(object));
}

NativeCellStateInput target_input(
    const NativeTerrainEditStateTemplate &target,
    const CellCoord &cell,
    const double density,
    const std::string &reason,
    NativeValue metadata) {
    NativeCellStateInput input;
    input.cell = cell;
    input.material = target.material;
    input.biome = target.biome;
    input.solid = resolved_solid(target);
    input.density = density;
    input.fluid = target.fluid;
    input.light = resolved_light(target);
    input.metadata = std::move(metadata);
    input.block_id = target.block_id.has_value()
        ? target.block_id
        : std::optional<NativeBlockIdentity>(NativeBlockIdentity::create(material_block_id(target.material)));
    input.edit_reason = reason;
    input.generated = false;
    input.edited = true;
    return input;
}

NativeCellStateInput cloned_input(
    const NativeCellState &source,
    const double density,
    const std::string &reason,
    NativeValue metadata) {
    NativeCellStateInput input;
    input.cell = source.cell;
    input.material = source.material;
    input.biome = source.biome;
    input.solid = source.solid;
    input.density = density;
    input.fluid = source.fluid;
    input.light = source.light;
    input.metadata = std::move(metadata);
    input.block_id = source.block_id.has_value()
        ? source.block_id
        : std::optional<NativeBlockIdentity>(NativeBlockIdentity::create(material_block_id(source.material)));
    input.edit_reason = reason;
    input.generated = false;
    input.edited = true;
    return input;
}

const NativeCellState &source_cell(
    const NativeTerrainEditCompileRequest &request,
    SourceCellCache &cache,
    const CellCoord &cell) {
    const auto cached = cache.find(cell);
    if (cached != cache.end()) return cached->second;
    std::optional<NativeCellState> result = request.source->cell_at(cell);
    if (!result.has_value()) reject(NativeTerrainEditCompileRejectReason::source_cell_missing);
    if (!(result->cell == cell)) reject(NativeTerrainEditCompileRejectReason::source_cell_mismatch);
    return cache.emplace(cell, std::move(*result)).first->second;
}

const NativeCellState &effective_cell(
    const NativeTerrainEditCompileRequest &request,
    const std::map<CellCoord, PendingOperation, CellLess> &pending,
    SourceCellCache &cache,
    const CellCoord &cell) {
    const auto staged = pending.find(cell);
    if (staged != pending.end()) return staged->second.state;
    return source_cell(request, cache, cell);
}

std::uint64_t inclusive_extent(const std::int32_t first, const std::int32_t second) {
    const std::int64_t low = std::min<std::int64_t>(first, second);
    const std::int64_t high = std::max<std::int64_t>(first, second);
    return static_cast<std::uint64_t>(high - low) + 1U;
}

std::size_t checked_volume(
    const CellCoord &minimum,
    const CellCoord &maximum,
    const std::size_t remaining) {
    const std::uint64_t x = inclusive_extent(minimum.x, maximum.x);
    const std::uint64_t y = inclusive_extent(minimum.y, maximum.y);
    const std::uint64_t z = inclusive_extent(minimum.z, maximum.z);
    if (x > remaining || y > remaining / x || z > remaining / (x * y)) {
        reject(NativeTerrainEditCompileRejectReason::candidate_limit_exceeded);
    }
    return static_cast<std::size_t>(x * y * z);
}

std::int32_t checked_floor_cell(const double value) {
    if (!std::isfinite(value)) reject(NativeTerrainEditCompileRejectReason::invalid_request);
    const double rounded = std::floor(value);
    if (rounded < static_cast<double>(std::numeric_limits<std::int32_t>::min())
        || rounded > static_cast<double>(std::numeric_limits<std::int32_t>::max())) {
        reject(NativeTerrainEditCompileRejectReason::invalid_request);
    }
    return static_cast<std::int32_t>(rounded);
}

std::int32_t checked_ceil_cell(const double value) {
    if (!std::isfinite(value)) reject(NativeTerrainEditCompileRejectReason::invalid_request);
    const double rounded = std::ceil(value);
    // This is the upper sphere bound. The paired lower bound was already
    // accepted and the radius is positive, so only upper overflow is possible.
    if (rounded > static_cast<double>(std::numeric_limits<std::int32_t>::max())) {
        reject(NativeTerrainEditCompileRejectReason::invalid_request);
    }
    return static_cast<std::int32_t>(rounded);
}

std::pair<CellCoord, CellCoord> sphere_bounds(
    const NativeTerrainEditShape &shape,
    const double cell_size) {
    const float center_x = static_cast<float>(shape.center.x);
    const float center_y = static_cast<float>(shape.center.y);
    const float center_z = static_cast<float>(shape.center.z);
    const double shell_radius = sphere_target_solid(shape.target)
        ? shape.radius
        : shape.radius + cell_size * 1.15;
    return {
        {
            checked_floor_cell((static_cast<double>(center_x) - shell_radius) / cell_size),
            checked_floor_cell((static_cast<double>(center_y) - shell_radius) / cell_size),
            checked_floor_cell((static_cast<double>(center_z) - shell_radius) / cell_size),
        },
        {
            checked_ceil_cell((static_cast<double>(center_x) + shell_radius) / cell_size),
            checked_ceil_cell((static_cast<double>(center_y) + shell_radius) / cell_size),
            checked_ceil_cell((static_cast<double>(center_z) + shell_radius) / cell_size),
        },
    };
}

float godot_distance_squared(
    const CellCoord &cell,
    const double cell_size,
    const float center_x,
    const float center_y,
    const float center_z) {
    // GDScript arithmetic constructs a default-precision Godot Vector3 after
    // the binary64 cell-center expression. Vector3 subtraction, products, and
    // additions then round in real_t (binary32 in this project) in this order.
    const auto checked_cell_center = [cell_size](const std::int32_t coordinate) {
        const float value = static_cast<float>((static_cast<double>(coordinate) + 0.5) * cell_size);
        if (!std::isfinite(value)) reject(NativeTerrainEditCompileRejectReason::invalid_request);
        return value;
    };
    const float cell_x = checked_cell_center(cell.x);
    const float cell_y = checked_cell_center(cell.y);
    const float cell_z = checked_cell_center(cell.z);
    const float dx = cell_x - center_x;
    const float dy = cell_y - center_y;
    const float dz = cell_z - center_z;
    const float dx_squared = dx * dx;
    const float dy_squared = dy * dy;
    const float dz_squared = dz * dz;
    const float xy_squared = dx_squared + dy_squared;
    return xy_squared + dz_squared;
}

double clamp_density(const double value, const double minimum, const double maximum) {
    return std::max(minimum, std::min(value, maximum));
}

NativeValue classify_fluid_only_metadata(
    const NativeValue &metadata,
    const NativeCellState &before,
    const NativeTerrainEditStateTemplate &after) {
    if (metadata_has_key(metadata, "terrainMeshAffects")) return metadata;
    if (before.fluid != after.fluid && !before.solid && !resolved_solid(after)) {
        return metadata_with(metadata, "terrainMeshAffects", NativeValue::boolean(false));
    }
    return metadata;
}

void stage(
    std::map<CellCoord, PendingOperation, CellLess> &pending,
    PendingOperation operation,
    NativeTerrainEditCompileSummary &summary) {
    const auto found = pending.find(operation.state.cell);
    if (found != pending.end()) ++summary.coincident_overwrites;
    pending.insert_or_assign(operation.state.cell, std::move(operation));
}

void validate_shape(const NativeTerrainEditShape &shape, const double cell_size) {
    if (shape.provenance_id.find('\0') != std::string::npos) {
        reject(NativeTerrainEditCompileRejectReason::invalid_request);
    }
    if (shape.kind == NativeTerrainEditShapeKind::sphere && !shape.target.solid.has_value()) {
        reject(NativeTerrainEditCompileRejectReason::invalid_request);
    }
    try {
        static_cast<void>(NativeValue::string(shape.provenance_id));
        const double density = shape.target.density.value_or(
            resolved_solid(shape.target) ? cell_size : -cell_size);
        static_cast<void>(make_native_cell_state(target_input(
            shape.target, {}, density, shape.provenance_id, shape.target.metadata)));
    } catch (const NativeTerrainEditCompileRejected &) {
        throw;
    } catch (const std::invalid_argument &) {
        reject(NativeTerrainEditCompileRejectReason::invalid_request);
    }
    if (shape.kind == NativeTerrainEditShapeKind::sphere
        && (!std::isfinite(shape.center.x) || !std::isfinite(shape.center.y) || !std::isfinite(shape.center.z)
            || !std::isfinite(shape.radius))) {
        reject(NativeTerrainEditCompileRejectReason::invalid_request);
    }
    if (shape.kind == NativeTerrainEditShapeKind::sphere
        && (!std::isfinite(static_cast<float>(shape.center.x))
            || !std::isfinite(static_cast<float>(shape.center.y))
            || !std::isfinite(static_cast<float>(shape.center.z)))) {
        reject(NativeTerrainEditCompileRejectReason::invalid_request);
    }
    if (shape.kind == NativeTerrainEditShapeKind::sphere) {
        static_cast<void>(metadata_boolean_or_false(shape.target.metadata, "deferSkyLight"));
    }
    if (shape.kind != NativeTerrainEditShapeKind::inclusive_box
        && shape.kind != NativeTerrainEditShapeKind::sphere) {
        reject(NativeTerrainEditCompileRejectReason::unsupported_shape);
    }
}

void compile_box(
    const NativeTerrainEditCompileRequest &request,
    const NativeTerrainEditShape &shape,
    const std::size_t shape_index,
    std::map<CellCoord, PendingOperation, CellLess> &pending,
    NativeTerrainEditCompileSummary &summary) {
    const CellCoord minimum{
        std::min(shape.first.x, shape.second.x),
        std::min(shape.first.y, shape.second.y),
        std::min(shape.first.z, shape.second.z),
    };
    const CellCoord maximum{
        std::max(shape.first.x, shape.second.x),
        std::max(shape.first.y, shape.second.y),
        std::max(shape.first.z, shape.second.z),
    };
    const double density = shape.target.density.value_or(
        resolved_solid(shape.target) ? request.cell_size : -request.cell_size);
    for (std::int64_t z = minimum.z; z <= static_cast<std::int64_t>(maximum.z); ++z) {
        for (std::int64_t y = minimum.y; y <= static_cast<std::int64_t>(maximum.y); ++y) {
            for (std::int64_t x = minimum.x; x <= static_cast<std::int64_t>(maximum.x); ++x) {
                const CellCoord cell{
                    static_cast<std::int32_t>(x), static_cast<std::int32_t>(y), static_cast<std::int32_t>(z)};
                NativeCellState state = make_native_cell_state(target_input(
                    shape.target, cell, density, shape.provenance_id, shape.target.metadata));
                stage(pending, {std::move(state), shape.kind,
                    NativeTerrainEditCellClassification::direct_target, shape_index, shape.provenance_id}, summary);
            }
        }
    }
}

void compile_sphere(
    const NativeTerrainEditCompileRequest &request,
    const NativeTerrainEditShape &shape,
    const std::size_t shape_index,
    const CellCoord &minimum,
    const CellCoord &maximum,
    std::map<CellCoord, PendingOperation, CellLess> &pending,
    SourceCellCache &source_cache,
    NativeTerrainEditCompileSummary &summary) {
    const double radius_squared = shape.radius * shape.radius;
    const bool target_solid = sphere_target_solid(shape.target);
    const double shell_radius = target_solid
        ? shape.radius
        : shape.radius + request.cell_size * 1.15;
    const double shell_squared = shell_radius * shell_radius;
    const float center_x = static_cast<float>(shape.center.x);
    const float center_y = static_cast<float>(shape.center.y);
    const float center_z = static_cast<float>(shape.center.z);
    const bool defer_sky_light = metadata_boolean_or_false(shape.target.metadata, "deferSkyLight");
    for (std::int64_t z = minimum.z; z <= static_cast<std::int64_t>(maximum.z); ++z) {
        for (std::int64_t y = minimum.y; y <= static_cast<std::int64_t>(maximum.y); ++y) {
            for (std::int64_t x = minimum.x; x <= static_cast<std::int64_t>(maximum.x); ++x) {
                const CellCoord cell{
                    static_cast<std::int32_t>(x), static_cast<std::int32_t>(y), static_cast<std::int32_t>(z)};
                const float distance_squared_f = godot_distance_squared(
                    cell, request.cell_size, center_x, center_y, center_z);
                const double distance_squared = static_cast<double>(distance_squared_f);
                if (distance_squared > shell_squared) continue;
                const double distance = std::sqrt(distance_squared);
                const bool direct = target_solid || distance_squared <= radius_squared;
                std::optional<NativeCellState> state;
                if (direct) {
                    double density = clamp_density(
                        target_solid ? shape.radius - distance : distance - shape.radius,
                        -request.cell_size * 2.0,
                        request.cell_size * 2.0);
                    const NativeCellState before = effective_cell(request, pending, source_cache, cell);
                    NativeValue metadata = classify_fluid_only_metadata(shape.target.metadata, before, shape.target);
                    state = make_native_cell_state(target_input(
                        shape.target, cell, density, shape.provenance_id, std::move(metadata)));
                } else {
                    const NativeCellState existing = effective_cell(request, pending, source_cache, cell);
                    if (!existing.solid) continue;
                    NativeValue metadata = metadata_with(
                        existing.metadata, "source", NativeValue::string("excavation_boundary"));
                    if (defer_sky_light) {
                        metadata = metadata_with(
                            metadata, "deferSkyLight", NativeValue::boolean(true));
                    }
                    const double density = clamp_density(
                        distance - shape.radius, request.cell_size * 0.05, request.cell_size * 1.35);
                    state = make_native_cell_state(cloned_input(
                        existing, density, shape.provenance_id, std::move(metadata)));
                }
                stage(pending, {std::move(*state), shape.kind,
                    direct ? NativeTerrainEditCellClassification::direct_target
                           : NativeTerrainEditCellClassification::excavation_boundary,
                    shape_index, shape.provenance_id}, summary);
            }
        }
    }
}

} // namespace

NativeTerrainEditShape NativeTerrainEditShape::inclusive_box(
    const CellCoord first,
    const CellCoord second,
    NativeTerrainEditStateTemplate target,
    std::string provenance_id) {
    NativeTerrainEditShape result;
    result.kind = NativeTerrainEditShapeKind::inclusive_box;
    result.first = first;
    result.second = second;
    result.target = std::move(target);
    result.provenance_id = std::move(provenance_id);
    return result;
}

NativeTerrainEditShape NativeTerrainEditShape::sphere(
    const Vec3d center,
    const double radius,
    NativeTerrainEditStateTemplate target,
    std::string provenance_id) {
    NativeTerrainEditShape result;
    result.kind = NativeTerrainEditShapeKind::sphere;
    result.center = center;
    result.radius = radius;
    result.target = std::move(target);
    result.provenance_id = std::move(provenance_id);
    return result;
}

NativeTerrainEditCompiledBatch::NativeTerrainEditCompiledBatch(
    std::vector<NativeTerrainEditCompiledOperation> operations,
    NativeTerrainEditCompileSummary summary)
    : operations_(std::move(operations)), summary_(std::move(summary)) {}

const std::vector<NativeTerrainEditCompiledOperation> &
NativeTerrainEditCompiledBatch::compiled_operations() const noexcept {
    return operations_;
}

const NativeTerrainEditCompileSummary &NativeTerrainEditCompiledBatch::summary() const noexcept {
    return summary_;
}

WorldTypedCellTransaction NativeTerrainEditCompiledBatch::make_transaction(
    std::string transaction_id,
    const std::uint64_t expected_revision) const {
    if (operations_.empty()) reject(NativeTerrainEditCompileRejectReason::empty_transaction);
    if (transaction_id.empty() || transaction_id.find('\0') != std::string::npos) {
        reject(NativeTerrainEditCompileRejectReason::invalid_request);
    }
    if (summary_.source_pinned && expected_revision != summary_.source_revision) {
        reject(NativeTerrainEditCompileRejectReason::source_revision_mismatch);
    }
    WorldTypedCellTransaction transaction;
    transaction.transaction_id = std::move(transaction_id);
    transaction.expected_revision = expected_revision;
    transaction.operations.reserve(operations_.size());
    for (const NativeTerrainEditCompiledOperation &compiled : operations_) {
        transaction.operations.push_back(compiled.operation);
    }
    return transaction;
}

NativeTerrainEditCompileRejected::NativeTerrainEditCompileRejected(
    const NativeTerrainEditCompileRejectReason reason)
    : std::invalid_argument("native terrain edit shape compile rejected"), reason_(reason) {}

NativeTerrainEditCompileRejectReason NativeTerrainEditCompileRejected::reason() const noexcept {
    return reason_;
}

NativeTerrainEditCompiledBatch NativeTerrainEditShapeCompiler::compile(
    const NativeTerrainEditCompileRequest &request) {
    try {
    if (!std::isfinite(request.cell_size) || request.cell_size <= 0.0
        || request.limits.max_candidate_visits == 0U || request.limits.max_operations == 0U) {
        reject(NativeTerrainEditCompileRejectReason::invalid_request);
    }
    if (request.omit_unchanged && request.source == nullptr) {
        reject(NativeTerrainEditCompileRejectReason::source_required);
    }

    NativeTerrainEditCompileSummary summary;
    summary.shape_count = request.shapes.size();
    summary.source_pinned = request.source != nullptr;
    if (request.source != nullptr) {
        summary.source_snapshot_digest = request.source->snapshot_digest();
        summary.source_revision = request.source->source_revision();
    }

    std::vector<std::pair<CellCoord, CellCoord>> bounds;
    bounds.reserve(request.shapes.size());
    std::size_t remaining = request.limits.max_candidate_visits;
    for (const NativeTerrainEditShape &shape : request.shapes) {
        // TerrainVolumeService.apply_sphere_edit treats every non-positive
        // radius, including negative infinity, as a successful empty edit
        // before consulting the target state or effective source.
        if (shape.kind == NativeTerrainEditShapeKind::sphere && shape.radius <= 0.0) {
            bounds.push_back({{}, {}});
            continue;
        }
        validate_shape(shape, request.cell_size);
        std::pair<CellCoord, CellCoord> shape_bounds{shape.first, shape.second};
        if (shape.kind == NativeTerrainEditShapeKind::sphere) {
            if (request.source == nullptr) reject(NativeTerrainEditCompileRejectReason::source_required);
            shape_bounds = sphere_bounds(shape, request.cell_size);
        }
        const std::size_t visits = checked_volume(shape_bounds.first, shape_bounds.second, remaining);
        summary.candidate_visits += visits;
        remaining -= visits;
        bounds.push_back(shape_bounds);
    }

    std::map<CellCoord, PendingOperation, CellLess> pending;
    SourceCellCache source_cache;
    for (std::size_t index = 0; index < request.shapes.size(); ++index) {
        const NativeTerrainEditShape &shape = request.shapes[index];
        if (shape.kind == NativeTerrainEditShapeKind::sphere && shape.radius <= 0.0) continue;
        if (shape.kind == NativeTerrainEditShapeKind::inclusive_box) {
            compile_box(request, shape, index, pending, summary);
        } else {
            compile_sphere(request, shape, index, bounds[index].first, bounds[index].second,
                pending, source_cache, summary);
        }
    }
    summary.unique_cells_before_filter = pending.size();

    std::vector<NativeTerrainEditCompiledOperation> operations;
    operations.reserve(pending.size());
    std::map<TerrainMaterialId, std::size_t> material_counts;
    std::map<TerrainMaterialId, std::size_t> removed_material_counts;
    std::set<std::pair<std::int32_t, std::int32_t>> changed_columns;
    summary.source_transition_summary_available = request.source != nullptr;
    for (const auto &entry : pending) {
        const PendingOperation &pending_operation = entry.second;
        bool changed = false;
        if (request.source != nullptr) {
            const NativeCellState &original = source_cell(request, source_cache, entry.first);
            changed = !(original == pending_operation.state);
            if (changed) {
                ++summary.changed_cells;
                changed_columns.emplace(entry.first.x, entry.first.z);
                if (original.solid && !pending_operation.state.solid) {
                    ++removed_material_counts[original.material];
                }
            }
            if (request.omit_unchanged && !changed) {
                ++summary.unchanged_filtered;
                continue;
            }
        }
        if (operations.size() == request.limits.max_operations) {
            reject(NativeTerrainEditCompileRejectReason::operation_limit_exceeded);
        }
        NativeTerrainEditCompiledOperation compiled;
        compiled.operation = {
            NativeCellStateNamespace::durable_terrain,
            entry.first,
            WorldTypedCellOperationKind::set,
            pending_operation.state,
        };
        compiled.shape_kind = pending_operation.shape_kind;
        compiled.classification = pending_operation.classification;
        compiled.source_shape_index = pending_operation.source_shape_index;
        compiled.provenance_id = pending_operation.provenance_id;
        operations.push_back(std::move(compiled));
        ++material_counts[pending_operation.state.material];
        if (pending_operation.classification == NativeTerrainEditCellClassification::direct_target) {
            ++summary.direct_target_operations;
        } else {
            ++summary.excavation_boundary_operations;
        }
        if (pending_operation.state.solid) ++summary.solid_operations;
        else ++summary.nonsolid_operations;
    }
    summary.emitted_operations = operations.size();
    for (const auto &entry : material_counts) {
        summary.material_counts.push_back({entry.first, entry.second});
    }
    for (const auto &entry : changed_columns) {
        summary.changed_columns.push_back({entry.first, entry.second});
    }
    for (const auto &entry : removed_material_counts) {
        summary.removed_material_counts.push_back({entry.first, entry.second});
    }
    if (request.source != nullptr) {
        const Sha256Digest final_digest = request.source->snapshot_digest();
        const std::uint64_t final_revision = request.source->source_revision();
        if (final_digest != summary.source_snapshot_digest || final_revision != summary.source_revision) {
            reject(NativeTerrainEditCompileRejectReason::source_drift);
        }
    }
    return NativeTerrainEditCompiledBatch(std::move(operations), std::move(summary));
    } catch (const NativeTerrainEditCompileRejected &) {
        throw;
    } catch (const std::invalid_argument &) {
        // NativeValue and NativeCellState are stricter internal authorities.
        // Compile exposes one stable rejection algebra and must not leak their
        // exception types when compiler-added metadata crosses a bound.
        reject(NativeTerrainEditCompileRejectReason::invalid_request);
    }
}

} // namespace voxel::world_backend
