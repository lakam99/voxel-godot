#include "native_terrain_edit_shape_compiler.hpp"

#include <algorithm>
#include <cmath>
#include <cstdint>
#include <limits>
#include <map>
#include <memory>
#include <set>
#include <string_view>
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

bool metadata_has_key(const NativeValue &metadata, const std::string_view key) {
    const NativeValue::Object &object = metadata.as_object();
    const auto position = std::lower_bound(object.begin(), object.end(), key,
        [](const auto &entry, const std::string_view needle) {
            return std::string_view(entry.first) < needle;
        });
    return position != object.end() && std::string_view(position->first) == key;
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
    if (shape.kind == NativeTerrainEditShapeKind::sphere
        && !shape.target.solid.has_value()) {
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
    if ((shape.kind == NativeTerrainEditShapeKind::sphere
            || shape.kind == NativeTerrainEditShapeKind::surface_deformation)
        && (!std::isfinite(shape.center.x) || !std::isfinite(shape.center.y) || !std::isfinite(shape.center.z)
            || !std::isfinite(shape.radius)
            || (shape.kind == NativeTerrainEditShapeKind::surface_deformation
                && !std::isfinite(shape.drop_depth)))) {
        reject(NativeTerrainEditCompileRejectReason::invalid_request);
    }
    if ((shape.kind == NativeTerrainEditShapeKind::sphere
            || shape.kind == NativeTerrainEditShapeKind::surface_deformation)
        && (!std::isfinite(static_cast<float>(shape.center.x))
            || !std::isfinite(static_cast<float>(shape.center.y))
            || !std::isfinite(static_cast<float>(shape.center.z)))) {
        reject(NativeTerrainEditCompileRejectReason::invalid_request);
    }
    if (shape.kind == NativeTerrainEditShapeKind::sphere) {
        static_cast<void>(metadata_boolean_or_false(shape.target.metadata, "deferSkyLight"));
    }
    if (shape.kind != NativeTerrainEditShapeKind::inclusive_box
        && shape.kind != NativeTerrainEditShapeKind::sphere
        && shape.kind != NativeTerrainEditShapeKind::surface_deformation) {
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

std::string_view metadata_source_string_or_empty(const NativeValue &metadata) {
    const NativeValue::Object &object = metadata.as_object();
    const auto position = std::lower_bound(object.begin(), object.end(), std::string_view("source"),
        [](const auto &entry, const std::string_view needle) {
            return std::string_view(entry.first) < needle;
        });
    if (position == object.end() || std::string_view(position->first) != "source"
        || position->second.kind() != NativeValueKind::string) return {};
    return position->second.as_string();
}

bool cell_state_affects_terrain_mesh(const NativeCellState &state) {
    if (metadata_has_key(state.metadata, "terrainMeshAffects")) {
        return metadata_boolean_or_false(state.metadata, "terrainMeshAffects");
    }
    if (metadata_boolean_or_false(state.metadata, "renderedBySceneBlock")) return false;
    return metadata_source_string_or_empty(state.metadata) != "scene_block";
}

bool terrain_edit_updates_sky_light(const NativeCellState &state) {
    if (!cell_state_affects_terrain_mesh(state)) return false;
    const std::string_view source = metadata_source_string_or_empty(state.metadata);
    if (source.size() >= 10U && source.substr(0U, 10U) == "structure_") return false;
    return !metadata_boolean_or_false(state.metadata, "renderedBySceneBlock");
}

std::string_view metadata_string_or(
    const NativeValue &metadata,
    const std::string_view key,
    const std::string_view fallback) {
    const NativeValue::Object &object = metadata.as_object();
    const auto position = std::lower_bound(object.begin(), object.end(), key,
        [](const auto &entry, const std::string_view needle) {
            return std::string_view(entry.first) < needle;
        });
    if (position == object.end() || std::string_view(position->first) != key) return fallback;
    return position->second.as_string();
}

NativeTerrainEditShape NativeTerrainEditShape::surface_deformation(
    const Vec3d center,
    const double radius,
    const double drop_depth,
    NativeTerrainEditStateTemplate target,
    std::string provenance_id) {
    NativeTerrainEditShape result;
    result.kind = NativeTerrainEditShapeKind::surface_deformation;
    result.center = center;
    result.radius = radius;
    result.drop_depth = drop_depth;
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
    if (summary_.requires_identity_bound_commit) {
        reject(NativeTerrainEditCompileRejectReason::identity_bound_commit_required);
    }
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
    const bool has_surface_deformation = std::any_of(
        request.shapes.begin(), request.shapes.end(), [](const NativeTerrainEditShape &shape) {
            return shape.kind == NativeTerrainEditShapeKind::surface_deformation;
        });
    if (has_surface_deformation) {
        // Surface deformation can retain a large source cache and prepared
        // state. It must use the resumable API so retirement stays off-frame.
        reject(NativeTerrainEditCompileRejectReason::unsupported_shape);
    }
    try {
    if (!std::isfinite(request.cell_size) || request.cell_size <= 0.0
        || request.limits.max_candidate_visits == 0U || request.limits.max_operations == 0U
        || request.limits.max_columns == 0U || request.limits.max_projection_reads == 0U
        || request.limits.max_projection_reads_per_query == 0U
        || request.limits.max_y_candidates == 0U || request.limits.max_prepared_bytes == 0U) {
        reject(NativeTerrainEditCompileRejectReason::invalid_request);
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
        if (request.omit_unchanged && request.source == nullptr) {
            reject(NativeTerrainEditCompileRejectReason::source_required);
        }
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

namespace {

constexpr std::size_t NORMALIZED_VALUE_NODE_BYTES = 64U;
constexpr std::size_t NORMALIZED_ARRAY_SLOT_BYTES = 64U;
constexpr std::size_t NORMALIZED_OBJECT_SLOT_BYTES = 128U;
constexpr std::size_t NORMALIZED_CELL_FIXED_BYTES = 128U;
constexpr std::size_t NORMALIZED_JOB_FIXED_BYTES = 2048U;

struct NativeValueFootprint {
    std::size_t canonical_bytes = 3U;
    std::size_t retained_bytes = 0U;
    std::size_t nodes = 0U;
    std::size_t entries = 0U;
    std::size_t text_bytes = 0U;
    std::size_t maximum_depth = 0U;
};

void checked_add(std::size_t &destination, const std::size_t value) {
    // NativeValue and terrain-edit text/container caps keep every aggregate
    // many orders of magnitude below 64-bit size_t overflow.
    static_assert(sizeof(std::size_t) >= sizeof(std::uint64_t));
    destination += value;
}

std::size_t normalized_text_storage(const std::size_t size) {
    return size * 2U + 32U;
}

void inspect_native_value(
    const NativeValue &value,
    const NativeTerrainEditCompileLimits &limits,
    const std::size_t depth,
    const bool include_owned_capacity,
    NativeValueFootprint &result) {
    if (depth > limits.max_metadata_depth) {
        reject(NativeTerrainEditCompileRejectReason::invalid_request);
    }
    if (result.nodes == limits.max_metadata_nodes) {
        reject(NativeTerrainEditCompileRejectReason::invalid_request);
    }
    ++result.nodes;
    result.maximum_depth = std::max(result.maximum_depth, depth);
    checked_add(result.retained_bytes, NORMALIZED_VALUE_NODE_BYTES);
    checked_add(result.canonical_bytes, 1U);
    const NativeValueKind kind = value.kind();
    if (kind == NativeValueKind::null_value || kind == NativeValueKind::boolean) return;
    if (kind == NativeValueKind::number) {
        checked_add(result.canonical_bytes, 8U);
        return;
    }
    if (kind == NativeValueKind::string) {
        const std::string &text = value.as_string();
        checked_add(result.text_bytes, text.size());
        if (result.text_bytes > limits.max_metadata_text_bytes) {
            reject(NativeTerrainEditCompileRejectReason::invalid_request);
        }
        checked_add(result.retained_bytes,
            include_owned_capacity ? text.capacity() + 1U : normalized_text_storage(text.size()));
        checked_add(result.canonical_bytes, 4U + text.size());
        return;
    }
    if (kind == NativeValueKind::array) {
        const NativeValue::Array &children = value.as_array();
        checked_add(result.entries, children.size());
        const std::size_t slots = include_owned_capacity ? children.capacity() : children.size();
        checked_add(result.retained_bytes, slots * NORMALIZED_ARRAY_SLOT_BYTES);
        checked_add(result.canonical_bytes, 4U);
        for (const NativeValue &child : children) {
            inspect_native_value(child, limits, depth + 1U, include_owned_capacity, result);
        }
        return;
    }
    const NativeValue::Object &entries = value.as_object();
    checked_add(result.entries, entries.size());
    const std::size_t slots = include_owned_capacity ? entries.capacity() : entries.size();
    checked_add(result.retained_bytes, slots * NORMALIZED_OBJECT_SLOT_BYTES);
    checked_add(result.canonical_bytes, 4U);
    for (const auto &entry : entries) {
        checked_add(result.text_bytes, entry.first.size());
        if (result.text_bytes > limits.max_metadata_text_bytes) {
            reject(NativeTerrainEditCompileRejectReason::invalid_request);
        }
        checked_add(result.retained_bytes,
            include_owned_capacity ? entry.first.capacity() + 1U
                                   : normalized_text_storage(entry.first.size()));
        checked_add(result.canonical_bytes, 4U + entry.first.size());
        inspect_native_value(entry.second, limits, depth + 1U, include_owned_capacity, result);
    }
}

NativeValueFootprint native_value_footprint(
    const NativeValue &value,
    const NativeTerrainEditCompileLimits &limits,
    const bool include_owned_capacity) {
    NativeValueFootprint result;
    inspect_native_value(value, limits, 0U, include_owned_capacity, result);
    return result;
}

NativeValue normalized_native_value_copy(const NativeValue &value) {
    const NativeValueKind kind = value.kind();
    if (kind == NativeValueKind::null_value) return NativeValue::null();
    if (kind == NativeValueKind::boolean) return NativeValue::boolean(value.as_boolean());
    if (kind == NativeValueKind::number) return NativeValue::number(value.as_number());
    if (kind == NativeValueKind::string) {
        const std::string &source = value.as_string();
        return NativeValue::string(std::string(source.data(), source.size()));
    }
    if (kind == NativeValueKind::array) {
        NativeValue::Array result;
        result.reserve(value.as_array().size());
        for (const NativeValue &child : value.as_array()) {
            result.push_back(normalized_native_value_copy(child));
        }
        return NativeValue::array(std::move(result));
    }
    NativeValue::Object result;
    result.reserve(value.as_object().size());
    for (const auto &entry : value.as_object()) {
        result.push_back({std::string(entry.first.data(), entry.first.size()),
            normalized_native_value_copy(entry.second)});
    }
    return NativeValue::object(std::move(result));
}

std::size_t cell_retained_bytes(
    const NativeCellState &state,
    const NativeTerrainEditCompileLimits &limits,
    const bool include_owned_capacity,
    const std::string &provenance_id = {}) {
    std::size_t bytes = NORMALIZED_CELL_FIXED_BYTES;
    checked_add(bytes, native_value_footprint(
        state.metadata, limits, include_owned_capacity).retained_bytes);
    if (state.block_id.has_value()) {
        checked_add(bytes, (include_owned_capacity
            ? state.block_id->value().capacity() + 1U
            : normalized_text_storage(state.block_id->value().size())));
    }
    if (state.edit_reason.has_value()) {
        checked_add(bytes, (include_owned_capacity
            ? state.edit_reason->capacity() + 1U
            : normalized_text_storage(state.edit_reason->size())));
    }
    checked_add(bytes, normalized_text_storage(provenance_id.size()));
    return bytes;
}

std::size_t surface_metadata_declared_bytes(
    const NativeValue &base,
    const NativeTerrainEditCompileLimits &limits,
    const std::string_view source_value) {
    const NativeValueFootprint footprint = native_value_footprint(base, limits, false);
    static constexpr const char *keys[] = {
        "saveDelta", "source", "surfaceProjectionAffects", "terrainMeshAffects"};
    std::size_t missing = 0U;
    std::size_t added_text = source_value.size();
    std::size_t added_retained = normalized_text_storage(source_value.size());
    for (const char *key : keys) {
        if (!metadata_has_key(base, key)) {
            ++missing;
            const std::size_t key_size = std::char_traits<char>::length(key);
            checked_add(added_text, key_size);
            checked_add(added_retained, normalized_text_storage(key_size));
        }
    }
    if (base.as_object().size() > NativeValueLimits::MAX_CONTAINER_ENTRIES - missing
        || footprint.nodes + missing > limits.max_metadata_nodes
        || footprint.text_bytes + added_text > limits.max_metadata_text_bytes) {
        reject(NativeTerrainEditCompileRejectReason::invalid_request);
    }
    std::size_t result = footprint.retained_bytes;
    checked_add(result, missing * NORMALIZED_OBJECT_SLOT_BYTES);
    checked_add(result, missing * NORMALIZED_VALUE_NODE_BYTES);
    checked_add(result, added_retained);
    return result;
}

void set_metadata_entry(NativeValue::Object &object, std::string key, NativeValue value) {
    const auto position = std::lower_bound(object.begin(), object.end(), key,
        [](const auto &entry, const std::string &needle) { return entry.first < needle; });
    if (position != object.end() && position->first == key) position->second = std::move(value);
    else object.insert(position, {std::move(key), std::move(value)});
}

NativeValue surface_metadata(
    const NativeValue &base,
    const std::string_view source_value,
    const bool preserve_existing_source) {
    static constexpr const char *keys[] = {
        "saveDelta", "source", "surfaceProjectionAffects", "terrainMeshAffects"};
    std::size_t missing = 0U;
    for (const char *key : keys) {
        if (!metadata_has_key(base, key)) ++missing;
    }
    NativeValue::Object object;
    object.reserve(base.as_object().size() + missing);
    for (const auto &entry : base.as_object()) {
        object.push_back({std::string(entry.first.data(), entry.first.size()),
            normalized_native_value_copy(entry.second)});
    }
    if (!preserve_existing_source || !metadata_has_key(base, "source")) {
        set_metadata_entry(object, "source", NativeValue::string(std::string(source_value)));
    }
    set_metadata_entry(object, "terrainMeshAffects", NativeValue::boolean(true));
    set_metadata_entry(object, "surfaceProjectionAffects", NativeValue::boolean(true));
    set_metadata_entry(object, "saveDelta", NativeValue::boolean(true));
    return NativeValue::object(std::move(object));
}

std::size_t declared_surface_state_bytes(
    const NativeValue &base_metadata,
    const NativeTerrainEditCompileLimits &limits,
    const std::string_view source_value,
    const std::size_t block_identity_bytes,
    const std::string &provenance_id) {
    std::size_t bytes = NORMALIZED_CELL_FIXED_BYTES;
    checked_add(bytes, surface_metadata_declared_bytes(base_metadata, limits, source_value));
    checked_add(bytes, normalized_text_storage(block_identity_bytes));
    // The edited state and PendingOperation retain separate reason/provenance
    // strings while they coexist in the job.
    checked_add(bytes, normalized_text_storage(provenance_id.size()));
    checked_add(bytes, normalized_text_storage(provenance_id.size()));
    return bytes;
}

struct RequestPreflight {
    std::size_t retained_bytes = 0U;
    std::size_t retained_entries = 0U;
};

RequestPreflight preflight_surface_request(const NativeTerrainEditCompileRequest &request) {
    if (!std::isfinite(request.cell_size) || request.cell_size <= 0.0
        || request.limits.max_candidate_visits == 0U || request.limits.max_operations == 0U
        || request.limits.max_columns == 0U || request.limits.max_projection_reads == 0U
        || request.limits.max_projection_reads_per_query == 0U
        || request.limits.max_y_candidates == 0U || request.limits.max_prepared_bytes == 0U
        || request.limits.max_metadata_nodes == 0U
        || request.limits.max_metadata_text_bytes == 0U
        || request.limits.max_metadata_depth == 0U) {
        reject(NativeTerrainEditCompileRejectReason::invalid_request);
    }
    const std::size_t deformation_count = static_cast<std::size_t>(std::count_if(
        request.shapes.begin(), request.shapes.end(), [](const NativeTerrainEditShape &candidate) {
            return candidate.kind == NativeTerrainEditShapeKind::surface_deformation;
        }));
    if (deformation_count != 1U || request.shapes.size() != 1U) {
        reject(NativeTerrainEditCompileRejectReason::mixed_surface_deformation);
    }
    if (!request.owned_source) reject(NativeTerrainEditCompileRejectReason::source_required);
    if (request.source != nullptr && request.source != request.owned_source.get()) {
        reject(NativeTerrainEditCompileRejectReason::invalid_request);
    }
    const NativeTerrainEditShape &shape = request.shapes.front();
    const NativeValueFootprint metadata = native_value_footprint(
        shape.target.metadata, request.limits, false);
    if (shape.target.metadata.kind() != NativeValueKind::object) {
        reject(NativeTerrainEditCompileRejectReason::invalid_request);
    }
    const NativeValue::Object &target_metadata = shape.target.metadata.as_object();
    const auto source_metadata = std::lower_bound(
        target_metadata.begin(), target_metadata.end(), std::string_view("source"),
        [](const auto &entry, const std::string_view needle) {
            return std::string_view(entry.first) < needle;
        });
    if (source_metadata != target_metadata.end()
        && std::string_view(source_metadata->first) == "source"
        && source_metadata->second.kind() != NativeValueKind::string) {
        reject(NativeTerrainEditCompileRejectReason::invalid_request);
    }
    const std::string_view direct_source = source_metadata == target_metadata.end()
            || std::string_view(source_metadata->first) != "source"
        ? std::string_view("player_dig") : std::string_view(source_metadata->second.as_string());
    static_cast<void>(surface_metadata_declared_bytes(
        shape.target.metadata, request.limits, direct_source));

    RequestPreflight result;
    result.retained_bytes = NORMALIZED_JOB_FIXED_BYTES + sizeof(NativeTerrainEditShape);
    checked_add(result.retained_bytes, metadata.retained_bytes);
    checked_add(result.retained_bytes, normalized_text_storage(shape.provenance_id.size()));
    if (shape.target.block_id.has_value()) {
        checked_add(result.retained_bytes,
            normalized_text_storage(shape.target.block_id->value().size()));
    }
    // Conservatively retain validation high-water: make_native_cell_state()
    // validates through one canonical buffer while its input and normalized
    // request metadata coexist. This is charged once at begin even though the
    // scratch dies before incremental work starts.
    checked_add(result.retained_bytes, metadata.retained_bytes);
    checked_add(result.retained_bytes, metadata.canonical_bytes);
    if (result.retained_bytes > request.limits.max_prepared_bytes) {
        reject(NativeTerrainEditCompileRejectReason::prepared_byte_limit_exceeded);
    }
    result.retained_entries = 2U + metadata.nodes + metadata.entries;
    return result;
}

NativeTerrainEditCompileRequest normalized_surface_request_copy(
    const NativeTerrainEditCompileRequest &request) {
    const NativeTerrainEditShape &source = request.shapes.front();
    NativeTerrainEditShape shape;
    shape.kind = source.kind;
    shape.first = source.first;
    shape.second = source.second;
    shape.center = source.center;
    shape.radius = source.radius;
    shape.drop_depth = source.drop_depth;
    shape.provenance_id = std::string(source.provenance_id.data(), source.provenance_id.size());
    shape.target.material = source.target.material;
    shape.target.biome = source.target.biome;
    shape.target.solid = source.target.solid;
    shape.target.density = source.target.density;
    shape.target.fluid = source.target.fluid;
    shape.target.light = source.target.light;
    shape.target.metadata = normalized_native_value_copy(source.target.metadata);
    if (source.target.block_id.has_value()) {
        shape.target.block_id = NativeBlockIdentity::create(std::string(
            source.target.block_id->value().data(), source.target.block_id->value().size()));
    }
    NativeTerrainEditCompileRequest result;
    result.cell_size = request.cell_size;
    result.shapes.reserve(1U);
    result.shapes.push_back(std::move(shape));
    result.source = request.source;
    result.owned_source = request.owned_source;
    result.omit_unchanged = request.omit_unchanged;
    result.limits = request.limits;
    return result;
}

std::int32_t checked_coordinate_offset(const std::int32_t value, const std::int32_t offset) {
    const std::int64_t result = static_cast<std::int64_t>(value) + offset;
    if (result < std::numeric_limits<std::int32_t>::min()
        || result > std::numeric_limits<std::int32_t>::max()) {
        reject(NativeTerrainEditCompileRejectReason::invalid_request);
    }
    return static_cast<std::int32_t>(result);
}

} // namespace

struct NativeTerrainEditCompileJob::Impl final {
    enum class Phase : std::uint8_t {
        enumerate_columns,
        project_column,
        begin_cell_compilation,
        compile_cells,
        begin_finalization,
        finalize_operations,
        finalize_materials,
        finalize_removed_materials,
        finalize_changed_columns,
        verify_source,
    };

    struct ColumnTarget {
        NativeTerrainEditColumn column;
        double surface_y = 0.0;
        double target_y = 0.0;
        std::int32_t high_y = 0;
        std::int32_t low_y = 0;
    };

    Impl() = default;
    Impl(NativeTerrainEditCompileRequest value, const RequestPreflight &preflight)
        : request(std::move(value)), request_retained_entries(preflight.retained_entries) {
        static_assert(sizeof(Impl) <= NORMALIZED_JOB_FIXED_BYTES);
        summary.prepared_bytes = preflight.retained_bytes;
        progress.prepared_bytes = preflight.retained_bytes;
    }

    NativeTerrainEditCompileRequest request;
    std::size_t request_retained_entries = 0U;
    std::shared_ptr<const NativeTerrainEditPinnedSource> source;
    NativeTerrainEditCompileJobStatus status = NativeTerrainEditCompileJobStatus::running;
    NativeTerrainEditCompileProgress progress;
    std::optional<NativeTerrainEditCompileRejectReason> rejection;
    Phase phase = Phase::enumerate_columns;
    Sha256Digest source_digest{};
    std::uint64_t source_revision = 0;
    double safe_radius = 0.0;
    double safe_drop = 0.0;
    std::int32_t min_x = 0;
    std::int32_t max_x = 0;
    std::int32_t min_z = 0;
    std::int32_t max_z = 0;
    std::int32_t next_x = 0;
    std::int32_t next_z = 0;
    bool columns_exhausted = false;
    NativeTerrainEditColumn pending_projection_column;
    double pending_projection_falloff = 0.0;
    std::vector<ColumnTarget> targets;
    std::size_t target_index = 0;
    bool active_target = false;
    std::int32_t next_y = 0;
    std::map<CellCoord, PendingOperation, CellLess> pending;
    SourceCellCache durable_cache;
    std::map<CellCoord, PendingOperation, CellLess>::const_iterator pending_iterator;
    std::vector<NativeTerrainEditCompiledOperation> operations;
    std::map<TerrainMaterialId, std::size_t> material_counts;
    std::map<TerrainMaterialId, std::size_t> removed_material_counts;
    std::set<std::pair<std::int32_t, std::int32_t>> changed_columns;
    std::set<std::pair<std::int32_t, std::int32_t>> legacy_columns_seen;
    std::set<std::pair<std::int32_t, std::int32_t>> skylight_columns_seen;
    std::set<std::pair<std::int32_t, std::int32_t>> fluid_columns_seen;
    std::map<TerrainMaterialId, std::size_t>::const_iterator material_iterator;
    std::map<TerrainMaterialId, std::size_t>::const_iterator removed_iterator;
    std::set<std::pair<std::int32_t, std::int32_t>>::const_iterator changed_column_iterator;
    NativeTerrainEditCompileSummary summary;

    const NativeTerrainEditShape &shape() const { return request.shapes.front(); }

    void fail(const NativeTerrainEditCompileRejectReason reason) noexcept {
        rejection = reason;
        status = NativeTerrainEditCompileJobStatus::rejected;
        progress.status = status;
    }

    void initialize() {
        validate_shape(shape(), request.cell_size);
        source = request.owned_source;
        request.source = source.get();
        source_digest = source->snapshot_digest();
        source_revision = source->source_revision();
        summary.shape_count = 1U;
        summary.source_pinned = true;
        summary.source_transition_summary_available = true;
        summary.requires_identity_bound_commit = true;
        summary.source_snapshot_digest = source_digest;
        summary.source_revision = source_revision;

        const float center_x = static_cast<float>(shape().center.x);
        const float center_z = static_cast<float>(shape().center.z);
        safe_radius = std::max(shape().radius, request.cell_size * 0.75);
        safe_drop = std::max(shape().drop_depth, request.cell_size * 0.35);
        min_x = checked_coordinate_offset(checked_floor_cell(
            (static_cast<double>(center_x) - safe_radius) / request.cell_size), -1);
        max_x = checked_coordinate_offset(checked_ceil_cell(
            (static_cast<double>(center_x) + safe_radius) / request.cell_size), 1);
        min_z = checked_coordinate_offset(checked_floor_cell(
            (static_cast<double>(center_z) - safe_radius) / request.cell_size), -1);
        max_z = checked_coordinate_offset(checked_ceil_cell(
            (static_cast<double>(center_z) + safe_radius) / request.cell_size), 1);
        const std::uint64_t width = inclusive_extent(min_x, max_x);
        const std::uint64_t depth = inclusive_extent(min_z, max_z);
        if (width > request.limits.max_columns
            || depth > request.limits.max_columns / width) {
            reject(NativeTerrainEditCompileRejectReason::column_limit_exceeded);
        }
        next_x = min_x;
        next_z = min_z;
        progress.status = status;
    }

    void check_source_identity() const {
        if (source->snapshot_digest() != source_digest
            || source->source_revision() != source_revision) {
            reject(NativeTerrainEditCompileRejectReason::source_drift);
        }
    }

    const NativeCellState &durable_cell(const CellCoord &cell) {
        const auto cached = durable_cache.find(cell);
        if (cached != durable_cache.end()) return cached->second;
        const std::optional<std::size_t> declared =
            source->physical_terrain_cell_retained_bytes_excluding_scene_overlay_at(cell);
        if (!declared.has_value() || *declared == 0U) {
            reject(NativeTerrainEditCompileRejectReason::source_cell_size_missing);
        }
        if (*declared > std::numeric_limits<std::size_t>::max() - 128U) {
            reject(NativeTerrainEditCompileRejectReason::source_cell_size_mismatch);
        }
        const std::size_t admitted_bytes = 128U + *declared;
        ensure_prepared_capacity(admitted_bytes);
        std::optional<NativeCellState> result =
            source->physical_terrain_cell_excluding_scene_overlay_at(cell);
        if (!result.has_value()) reject(NativeTerrainEditCompileRejectReason::source_cell_missing);
        if (!(result->cell == cell)) reject(NativeTerrainEditCompileRejectReason::source_cell_mismatch);
        const std::size_t actual = cell_retained_bytes(
            *result, request.limits, true);
        if (actual > *declared) {
            reject(NativeTerrainEditCompileRejectReason::source_cell_size_mismatch);
        }
        add_prepared_bytes(admitted_bytes);
        return durable_cache.emplace(cell, std::move(*result)).first->second;
    }

    void ensure_prepared_capacity(const std::size_t bytes) const {
        if (bytes > request.limits.max_prepared_bytes - summary.prepared_bytes) {
            reject(NativeTerrainEditCompileRejectReason::prepared_byte_limit_exceeded);
        }
    }

    void add_prepared_bytes(const std::size_t bytes) {
        ensure_prepared_capacity(bytes);
        summary.prepared_bytes += bytes;
        progress.prepared_bytes = summary.prepared_bytes;
    }

    void add_legacy_column(
        std::set<std::pair<std::int32_t, std::int32_t>> &seen,
        std::vector<NativeTerrainEditColumn> &destination,
        const NativeTerrainEditColumn column) {
        const std::pair<std::int32_t, std::int32_t> key{column.x, column.z};
        if (seen.find(key) == seen.cend()) {
            add_prepared_bytes(80U);
            seen.emplace(key);
            destination.push_back(column);
        }
    }

    void enumerate_one_column() {
        if (columns_exhausted) {
            phase = Phase::begin_cell_compilation;
            return;
        }
        const NativeTerrainEditColumn column{next_x, next_z};
        if (next_x == max_x) {
            next_x = min_x;
            if (next_z == max_z) columns_exhausted = true;
            else next_z = checked_coordinate_offset(next_z, 1);
        } else {
            next_x = checked_coordinate_offset(next_x, 1);
        }
        ++summary.enumerated_columns;
        ++progress.enumerated_columns;
        ++summary.candidate_visits;
        if (summary.candidate_visits > request.limits.max_candidate_visits) {
            reject(NativeTerrainEditCompileRejectReason::candidate_limit_exceeded);
        }

        const float column_x = static_cast<float>(
            (static_cast<double>(column.x) + 0.5) * request.cell_size);
        const float column_z = static_cast<float>(
            (static_cast<double>(column.z) + 0.5) * request.cell_size);
        const float center_x = static_cast<float>(shape().center.x);
        const float center_z = static_cast<float>(shape().center.z);
        const float dx = column_x - center_x;
        const float dz = column_z - center_z;
        const float horizontal_distance = std::sqrt(dx * dx + dz * dz);
        if (static_cast<double>(horizontal_distance) > safe_radius) return;
        const double t = std::clamp(static_cast<double>(horizontal_distance) / safe_radius, 0.0, 1.0);
        const double smooth = t * t * (3.0 - 2.0 * t);
        const double falloff = 1.0 - smooth;
        if (falloff <= 0.001) return;

        pending_projection_column = column;
        pending_projection_falloff = falloff;
        phase = Phase::project_column;
    }

    void project_one_column() {
        const NativeTerrainEditColumn column = pending_projection_column;
        const double falloff = pending_projection_falloff;
        phase = Phase::enumerate_columns;
        if (summary.projection_candidate_reads >= request.limits.max_projection_reads) {
            reject(NativeTerrainEditCompileRejectReason::projection_limit_exceeded);
        }
        const std::size_t remaining = request.limits.max_projection_reads
            - summary.projection_candidate_reads;
        const std::size_t allowance = std::min(
            remaining, request.limits.max_projection_reads_per_query);
        std::optional<NativeTerrainEditSurfaceProjection> projection =
            source->continuous_surface_projection_at(column, allowance);
        ++summary.projection_queries;
        ++progress.projection_queries;
        if (!projection.has_value()) reject(NativeTerrainEditCompileRejectReason::projection_missing);
        if (!(projection->column == column) || !std::isfinite(projection->surface_y)) {
            reject(NativeTerrainEditCompileRejectReason::source_cell_mismatch);
        }
        if (projection->candidate_reads > allowance) {
            reject(NativeTerrainEditCompileRejectReason::projection_limit_exceeded);
        }
        summary.projection_candidate_reads += projection->candidate_reads;
        progress.projection_candidate_reads = summary.projection_candidate_reads;

        const double surface_y = projection->surface_y;
        const double surface_target_y = surface_y - safe_drop * falloff;
        const double impact_strength = std::clamp(falloff * 1.35, 0.0, 1.0);
        const double center_y = static_cast<double>(static_cast<float>(shape().center.y));
        const double impact_endpoint = center_y - safe_drop * 0.72;
        const double impact_target_y = surface_y + (impact_endpoint - surface_y) * impact_strength;
        const double target_y = std::min(surface_target_y, impact_target_y);
        if (!std::isfinite(target_y)) reject(NativeTerrainEditCompileRejectReason::invalid_request);
        if (target_y >= surface_y - request.cell_size * 0.08) return;
        const std::int32_t high_y = checked_ceil_cell(
            (surface_y + request.cell_size * 0.60) / request.cell_size);
        const std::int32_t low_y = checked_floor_cell(
            (target_y - request.cell_size * 0.85) / request.cell_size);
        const std::uint64_t y_count = inclusive_extent(high_y, low_y);
        if (y_count > request.limits.max_y_candidates - summary.y_candidates) {
            reject(NativeTerrainEditCompileRejectReason::y_candidate_limit_exceeded);
        }
        if (y_count > request.limits.max_candidate_visits - summary.candidate_visits) {
            reject(NativeTerrainEditCompileRejectReason::candidate_limit_exceeded);
        }
        summary.y_candidates += static_cast<std::size_t>(y_count);
        progress.y_candidates = summary.y_candidates;
        summary.candidate_visits += static_cast<std::size_t>(y_count);
        add_prepared_bytes(128U);
        targets.push_back({column, surface_y, target_y, high_y, low_y});
    }

    void begin_cell_compilation() {
        target_index = 0U;
        active_target = false;
        phase = Phase::compile_cells;
    }

    void compile_one_cell() {
        if (!active_target) {
            if (target_index >= targets.size()) {
                phase = Phase::begin_finalization;
                return;
            }
            active_target = true;
            next_y = targets[target_index].high_y;
            return;
        }
        const ColumnTarget &target = targets[target_index];
        if (next_y < target.low_y) {
            active_target = false;
            ++target_index;
            return;
        }
        const std::int32_t y = next_y;
        if (next_y == std::numeric_limits<std::int32_t>::min()) {
            // The accepted low bound is also INT32_MIN; this candidate is last.
            next_y = target.low_y;
            active_target = false;
            ++target_index;
        } else {
            --next_y;
        }
        const CellCoord cell{target.column.x, y, target.column.z};
        const double center_y = (static_cast<double>(y) + 0.5) * request.cell_size;
        const NativeCellState &existing = durable_cell(cell);
        std::optional<NativeCellState> edited;
        NativeTerrainEditCellClassification classification =
            NativeTerrainEditCellClassification::direct_target;
        std::size_t declared_state_bytes = 0U;
        if (center_y > target.target_y
            && center_y <= target.surface_y + request.cell_size * 0.65) {
            const NativeValue &base_metadata = shape().target.metadata;
            const std::string_view source_value = metadata_string_or(
                base_metadata, "source", "player_dig");
            const std::size_t block_bytes = shape().target.block_id.has_value()
                ? shape().target.block_id->value().size() : 32U;
            declared_state_bytes = declared_surface_state_bytes(
                base_metadata, request.limits, source_value, block_bytes, shape().provenance_id);
            const std::size_t metadata_peak = surface_metadata_declared_bytes(
                base_metadata, request.limits, source_value);
            std::size_t peak_bytes = 160U;
            checked_add(peak_bytes, declared_state_bytes);
            checked_add(peak_bytes, metadata_peak);
            checked_add(peak_bytes, metadata_peak);
            checked_add(peak_bytes, metadata_peak);
            ensure_prepared_capacity(peak_bytes);
            NativeValue metadata = surface_metadata(
                base_metadata, source_value, true);
            const double density = clamp_density(target.target_y - center_y,
                -request.cell_size * 2.0, -request.cell_size * 0.05);
            edited = make_native_cell_state(target_input(
                shape().target, cell, density, shape().provenance_id, std::move(metadata)));
        } else if (existing.solid && center_y <= target.target_y
            && center_y >= target.target_y - request.cell_size * 1.25) {
            classification = NativeTerrainEditCellClassification::excavation_boundary;
            const std::string_view boundary_source = "surface_excavation_boundary";
            const std::size_t block_bytes = existing.block_id.has_value()
                ? existing.block_id->value().size() : 32U;
            declared_state_bytes = declared_surface_state_bytes(existing.metadata,
                request.limits, boundary_source, block_bytes, shape().provenance_id);
            const std::size_t metadata_peak = surface_metadata_declared_bytes(
                existing.metadata, request.limits, boundary_source);
            std::size_t peak_bytes = 160U;
            checked_add(peak_bytes, declared_state_bytes);
            checked_add(peak_bytes, metadata_peak);
            checked_add(peak_bytes, metadata_peak);
            checked_add(peak_bytes, metadata_peak);
            ensure_prepared_capacity(peak_bytes);
            NativeValue metadata = surface_metadata(existing.metadata,
                boundary_source, false);
            const double density = clamp_density(target.target_y - center_y,
                request.cell_size * 0.05, request.cell_size * 1.35);
            edited = make_native_cell_state(cloned_input(
                existing, density, shape().provenance_id, std::move(metadata)));
        }
        if (!edited.has_value()) return;
        if (pending.size() >= request.limits.max_operations) {
            reject(NativeTerrainEditCompileRejectReason::operation_limit_exceeded);
        }
        // Pending map node/state, legacy changed-cell vector entry, and their
        // variable payloads are all resident together.
        add_prepared_bytes(160U + declared_state_bytes);
        stage(pending, {std::move(*edited), shape().kind, classification, 0U,
            shape().provenance_id}, summary);
        add_prepared_bytes(16U);
        summary.legacy_changed_cells.push_back(cell);
        add_legacy_column(legacy_columns_seen, summary.legacy_changed_columns, target.column);
        const NativeCellState &after = pending.find(cell)->second.state;
        if (terrain_edit_updates_sky_light(after) || terrain_edit_updates_sky_light(existing)) {
            add_legacy_column(skylight_columns_seen, summary.skylight_columns, target.column);
        }
        if (existing.solid != after.solid || existing.fluid != after.fluid) {
            add_legacy_column(fluid_columns_seen, summary.fluid_transition_columns, target.column);
        }
        progress.prepared_operations = pending.size();
    }

    void begin_finalization() {
        summary.unique_cells_before_filter = pending.size();
        pending_iterator = pending.cbegin();
        phase = Phase::finalize_operations;
    }

    void finalize_one_operation() {
        if (pending_iterator == pending.cend()) {
            summary.emitted_operations = operations.size();
            material_iterator = material_counts.cbegin();
            phase = Phase::finalize_materials;
            return;
        }
        const CellCoord cell = pending_iterator->first;
        const PendingOperation &value = pending_iterator->second;
        ++pending_iterator;
        const NativeCellState &original = durable_cell(cell);
        const bool changed = !(original == value.state);
        if (changed) {
            ++summary.changed_cells;
            const std::pair<std::int32_t, std::int32_t> column{cell.x, cell.z};
            if (changed_columns.find(column) == changed_columns.cend()) {
                add_prepared_bytes(64U);
                changed_columns.emplace(column);
            }
            if (original.solid && !value.state.solid) {
                if (removed_material_counts.find(original.material) == removed_material_counts.end()) {
                    add_prepared_bytes(64U);
                }
                ++removed_material_counts[original.material];
            }
        }
        if (request.omit_unchanged && !changed) {
            ++summary.unchanged_filtered;
            return;
        }
        const std::size_t operation_state_bytes = cell_retained_bytes(
            value.state, request.limits, false, value.provenance_id);
        ensure_prepared_capacity(160U + operation_state_bytes);
        NativeTerrainEditCompiledOperation compiled;
        compiled.operation = {NativeCellStateNamespace::durable_terrain, cell,
            WorldTypedCellOperationKind::set, value.state};
        compiled.shape_kind = value.shape_kind;
        compiled.classification = value.classification;
        compiled.source_shape_index = value.source_shape_index;
        compiled.provenance_id = value.provenance_id;
        add_prepared_bytes(160U + operation_state_bytes);
        operations.push_back(std::move(compiled));
        if (material_counts.find(value.state.material) == material_counts.end()) {
            add_prepared_bytes(64U);
        }
        ++material_counts[value.state.material];
        if (value.classification == NativeTerrainEditCellClassification::direct_target) {
            ++summary.direct_target_operations;
        } else {
            ++summary.excavation_boundary_operations;
        }
        if (value.state.solid) ++summary.solid_operations;
        else ++summary.nonsolid_operations;
    }

    void finalize_one_material() {
        if (material_iterator == material_counts.cend()) {
            removed_iterator = removed_material_counts.cbegin();
            phase = Phase::finalize_removed_materials;
            return;
        }
        add_prepared_bytes(80U);
        summary.material_counts.push_back({material_iterator->first, material_iterator->second});
        ++material_iterator;
    }

    void finalize_one_removed_material() {
        if (removed_iterator == removed_material_counts.cend()) {
            changed_column_iterator = changed_columns.cbegin();
            phase = Phase::finalize_changed_columns;
            return;
        }
        add_prepared_bytes(80U);
        summary.removed_material_counts.push_back({removed_iterator->first, removed_iterator->second});
        ++removed_iterator;
    }

    void finalize_one_changed_column() {
        if (changed_column_iterator == changed_columns.cend()) {
            phase = Phase::verify_source;
            return;
        }
        add_prepared_bytes(80U);
        summary.changed_columns.push_back(
            {changed_column_iterator->first, changed_column_iterator->second});
        ++changed_column_iterator;
    }

    void process_one() {
        if (phase == Phase::enumerate_columns) enumerate_one_column();
        else if (phase == Phase::project_column) project_one_column();
        else if (phase == Phase::begin_cell_compilation) begin_cell_compilation();
        else if (phase == Phase::compile_cells) compile_one_cell();
        else if (phase == Phase::begin_finalization) begin_finalization();
        else if (phase == Phase::finalize_operations) finalize_one_operation();
        else if (phase == Phase::finalize_materials) finalize_one_material();
        else if (phase == Phase::finalize_removed_materials) finalize_one_removed_material();
        else if (phase == Phase::finalize_changed_columns) finalize_one_changed_column();
        else {
            check_source_identity();
            status = NativeTerrainEditCompileJobStatus::completed;
            progress.status = status;
        }
    }
};

NativeTerrainEditCompileJob::NativeTerrainEditCompileJob(std::unique_ptr<Impl> impl) noexcept
    : impl_(std::move(impl)) {}

NativeTerrainEditCompileJob::NativeTerrainEditCompileJob(
    NativeTerrainEditCompileJob &&) noexcept = default;

NativeTerrainEditCompileJob::~NativeTerrainEditCompileJob() = default;

NativeTerrainEditCompileJobStatus NativeTerrainEditCompileJob::status() const noexcept {
    return impl_ ? impl_->status : NativeTerrainEditCompileJobStatus::cancelled;
}

const NativeTerrainEditCompileProgress &NativeTerrainEditCompileJob::progress() const noexcept {
    static const NativeTerrainEditCompileProgress empty{
        NativeTerrainEditCompileJobStatus::cancelled, 0U, 0U, 0U, 0U, 0U, 0U, 0U, 0U};
    return impl_ ? impl_->progress : empty;
}

std::optional<NativeTerrainEditCompileRejectReason>
NativeTerrainEditCompileJob::reject_reason() const noexcept {
    return impl_ ? impl_->rejection : std::nullopt;
}

std::size_t NativeTerrainEditCompileJob::retained_entries_for_off_worker_destruction() const noexcept {
    if (!impl_) return 0U;
    return impl_->request_retained_entries + (impl_->source ? 1U : 0U)
        + impl_->targets.size() + impl_->pending.size() + impl_->durable_cache.size()
        + impl_->operations.size() + impl_->summary.legacy_changed_cells.size()
        + impl_->summary.legacy_changed_columns.size() + impl_->summary.skylight_columns.size()
        + impl_->summary.fluid_transition_columns.size() + impl_->material_counts.size()
        + impl_->removed_material_counts.size() + impl_->changed_columns.size();
}

void NativeTerrainEditCompileJob::advance(const std::size_t max_work_units) {
    if (!impl_ || impl_->status != NativeTerrainEditCompileJobStatus::running) return;
    if (max_work_units == 0U) {
        impl_->fail(NativeTerrainEditCompileRejectReason::invalid_request);
        return;
    }
    try {
        impl_->check_source_identity();
        ++impl_->progress.advance_calls;
        std::size_t processed = 0U;
        while (processed < max_work_units
            && impl_->status == NativeTerrainEditCompileJobStatus::running) {
            impl_->process_one();
            ++processed;
            ++impl_->progress.work_units;
        }
    } catch (const NativeTerrainEditCompileRejected &error) {
        impl_->fail(error.reason());
    } catch (const std::invalid_argument &) {
        impl_->fail(NativeTerrainEditCompileRejectReason::invalid_request);
    }
}

void NativeTerrainEditCompileJob::cancel() noexcept {
    if (!impl_ || impl_->status != NativeTerrainEditCompileJobStatus::running) return;
    impl_->status = NativeTerrainEditCompileJobStatus::cancelled;
    impl_->progress.status = impl_->status;
}

std::optional<NativeTerrainEditCompiledBatch>
NativeTerrainEditCompileJob::take_completed_batch() {
    if (!impl_ || impl_->status != NativeTerrainEditCompileJobStatus::completed) {
        return std::nullopt;
    }
    impl_->status = NativeTerrainEditCompileJobStatus::result_taken;
    impl_->progress.status = impl_->status;
    return NativeTerrainEditCompiledBatch(
        std::move(impl_->operations), std::move(impl_->summary));
}

NativeTerrainEditCompileJob NativeTerrainEditResumableCompiler::begin(
    const NativeTerrainEditCompileRequest &request) {
    try {
        const RequestPreflight preflight = preflight_surface_request(request);
        auto impl = std::make_unique<NativeTerrainEditCompileJob::Impl>(
            normalized_surface_request_copy(request), preflight);
        impl->initialize();
        return NativeTerrainEditCompileJob(std::move(impl));
    } catch (const NativeTerrainEditCompileRejected &error) {
        auto impl = std::make_unique<NativeTerrainEditCompileJob::Impl>();
        impl->fail(error.reason());
        return NativeTerrainEditCompileJob(std::move(impl));
    }
}

} // namespace voxel::world_backend
