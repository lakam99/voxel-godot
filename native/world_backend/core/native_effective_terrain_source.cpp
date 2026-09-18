#include "native_effective_terrain_source.hpp"

#include <algorithm>
#include <cmath>
#include <limits>
#include <stdexcept>
#include <string>
#include <utility>

namespace voxel::world_backend {
namespace {

std::int32_t floor_position_cell(const float coordinate, const double cell_size) {
    const double quotient = static_cast<double>(coordinate) / cell_size;
    const double floored = std::floor(quotient);
    if (!std::isfinite(floored)
        || floored < static_cast<double>(std::numeric_limits<std::int32_t>::min())
        || floored > static_cast<double>(std::numeric_limits<std::int32_t>::max())) {
        throw std::invalid_argument("native effective terrain position is outside cell domain");
    }
    return static_cast<std::int32_t>(floored);
}

CellCoord position_cell(const WorldFloat32Position &position, const double cell_size) {
    return {
        floor_position_cell(position.x, cell_size),
        floor_position_cell(position.y, cell_size),
        floor_position_cell(position.z, cell_size),
    };
}

NativeTerrainPageKey page_for(const std::int32_t x, const std::int32_t z) {
    const auto coordinate = [](const std::int32_t value) noexcept {
        constexpr std::int32_t page_cells = NativeTerrainShapingSnapshot::PAGE_CELLS;
        const std::int32_t quotient = value / page_cells;
        return quotient - static_cast<std::int32_t>(value % page_cells < 0);
    };
    // PAGE_CELLS is a positive compile-time constant, so every int32 has one
    // representable page key. An optional/failure branch here would be dead.
    return {coordinate(x), coordinate(z)};
}

void require_primary_page_query(
    const WorldSourcePin &pin, const std::int32_t x, const std::int32_t z) {
    if (!pin.primary_terrain_shaping().owns_cell(x, z)) {
        throw std::out_of_range("native effective terrain query is outside the primary page");
    }
}

NativeEffectiveNumericFacts edited_numeric(
    const CellCoord requested, const CellCoord source, const NativeCellState &state,
    const double surface_y) {
    return {
        requested,
        source,
        state.density,
        !state.solid && state.biome == TerrainBiomeId::underground_air,
        surface_y,
        state.material,
        false,
        true,
    };
}

const NativeValue *metadata_value(const NativeCellState &state, const std::string &key) noexcept {
    const auto &items = state.metadata.as_object();
    const auto found = std::lower_bound(items.begin(), items.end(), key,
        [](const auto &item, const std::string &candidate) { return item.first < candidate; });
    return found != items.end() && found->first == key ? &found->second : nullptr;
}

bool metadata_boolean(const NativeValue &value) {
    // Godot 4.6 Variant's bool constructor admits bool and numeric values.
    // Other NativeValue kinds would be an invalid call in the GDScript owner;
    // reject them instead of inventing container/string truthiness.
    if (value.kind() == NativeValueKind::boolean) return value.as_boolean();
    if (value.kind() == NativeValueKind::number) return value.as_number() != 0.0;
    throw std::invalid_argument("native terrain metadata boolean has incompatible type");
}

std::string metadata_string(const NativeCellState &state, const std::string &key) {
    const NativeValue *value = metadata_value(state, key);
    return value && value->kind() == NativeValueKind::string ? value->as_string() : std::string{};
}

bool affects_terrain_mesh(const NativeCellState &state) {
    if (const NativeValue *declared = metadata_value(state, "terrainMeshAffects"))
        return metadata_boolean(*declared);
    if (const NativeValue *scene_rendered = metadata_value(state, "renderedBySceneBlock"))
        if (metadata_boolean(*scene_rendered)) return false;
    return metadata_string(state, "source") != "scene_block";
}

bool affects_surface_projection(const NativeCellState &state) {
    if (const NativeValue *scene_rendered = metadata_value(state, "renderedBySceneBlock"))
        if (metadata_boolean(*scene_rendered)) return false;
    const std::string source = metadata_string(state, "source");
    if (source == "scene_block" || source.rfind("structure_", 0) == 0) return false;
    if (const NativeValue *declared = metadata_value(state, "terrainMeshAffects"))
        return metadata_boolean(*declared);
    return true;
}

} // namespace

NativeResolvedSurfaceProjectionQuery resolve_native_surface_projection_query(
    const WorldSourceDefinition &definition, const WorldLatticeQuery &query) {
    validate_world_query(query);
    const double cell_size = definition.constants().cell_size_meters;
    const auto component = [cell_size](const std::int32_t coordinate) noexcept {
        return static_cast<float>(static_cast<double>(coordinate) * cell_size);
    };
    return {query.coordinate, {
        component(query.coordinate.x), component(query.coordinate.y), component(query.coordinate.z),
    }, query.intent};
}

struct NativeEffectiveTerrainSource::GeneratedFacts {
    CellCoord source_cell;
    double surface_y = 0.0;
    double density = 0.0;
    bool solid = false;
    bool underground_air_void = false;
};

NativeEffectiveTerrainSource::NativeEffectiveTerrainSource(WorldSourcePin pin)
    : pin_(std::move(pin)), natural_(pin_.definition()) {}

const WorldSourcePin &NativeEffectiveTerrainSource::pin() const noexcept { return pin_; }

const NativeTerrainShapingSnapshot &NativeEffectiveTerrainSource::shaping_for(
    const std::int32_t x, const std::int32_t z) const {
    return pin_.terrain_shaping_for_page(page_for(x, z));
}

double NativeEffectiveTerrainSource::natural_surface(const std::int32_t x, const std::int32_t z) const {
    return natural_.natural_surface_y(x, z);
}

double NativeEffectiveTerrainSource::shaped_surface(const std::int32_t x, const std::int32_t z) const {
    const auto sampler = [this](const std::int32_t sample_x, const std::int32_t sample_z) {
        return natural_surface(sample_x, sample_z);
    };
    return shaping_for(x, z).surface_y(x, z, sampler);
}

TerrainBiomeId NativeEffectiveTerrainSource::shaped_surface_biome(
    const std::int32_t x, const std::int32_t z) const {
    const auto sampler = [this](const std::int32_t sample_x, const std::int32_t sample_z) {
        return natural_surface(sample_x, sample_z);
    };
    const auto &shaping = shaping_for(x, z);
    if (shaping.town_core_contains(x, z, sampler)) return TerrainBiomeId::town;
    const double surface = shaping.surface_y(x, z, sampler);
    if (surface < pin_.definition().constants().water_level_meters + 0.3) return TerrainBiomeId::ocean;
    if (surface < pin_.definition().constants().water_level_meters + 1.7) return TerrainBiomeId::beach;
    return natural_.regional_surface_biome(x, z);
}

NativeEffectiveTerrainSource::GeneratedFacts NativeEffectiveTerrainSource::generated_at(
    const WorldFloat32Position position) const {
    const double cell_size = pin_.definition().constants().cell_size_meters;
    const CellCoord source = position_cell(position, cell_size);
    const auto sampler = [this](const std::int32_t sample_x, const std::int32_t sample_z) {
        return natural_surface(sample_x, sample_z);
    };
    const auto &shaping = shaping_for(source.x, source.z);
    const double surface = shaping.surface_y(source.x, source.z, sampler);
    const double depth_cells = std::max(0.0, surface - static_cast<double>(position.y))
        / std::max(0.001, cell_size);
    double density = surface - static_cast<double>(position.y);
    if (density > 0.0) {
        const double overburden = shaping.protects_minimum_overburden(source.x, source.z, sampler) ? 8.0 : 3.0;
        density = std::min(density,
            natural_.underground_air_density(position, source, surface, depth_cells, overburden));
        if (position.y <= pin_.definition().constants().world_bottom_cell_y * cell_size)
            density = std::max(density, cell_size * 4.0);
    }
    const bool solid = density >= 0.0;
    return {source, surface, density, solid,
        !solid && surface - static_cast<double>(position.y) > cell_size * 0.35};
}

NativeEffectiveNumericFacts NativeEffectiveTerrainSource::generated_numeric(
    const CellCoord requested_cell, const WorldFloat32Position position,
    const CellCoord material_cell, const CellCoord biome_cell) const {
    const GeneratedFacts generated = generated_at(position);
    TerrainMaterialId material = TerrainMaterialId::air;
    if (generated.solid) {
        if (material_cell.y <= pin_.definition().constants().world_bottom_cell_y + 1)
            material = TerrainMaterialId::bedrock;
        else
            material = natural_.solid_material_for(material_cell, generated.surface_y, position.y,
                shaped_surface_biome(biome_cell.x, biome_cell.z), generated.density);
    }
    return {
        requested_cell,
        generated.source_cell,
        generated.density,
        generated.underground_air_void,
        generated.surface_y,
        material,
        true,
        false,
    };
}

NativeSurfaceColumnFacts NativeEffectiveTerrainSource::sample_surface_column(
    const WorldSurfaceColumnQuery &query) const {
    validate_world_query(query);
    require_primary_page_query(pin_, query.x, query.z);
    const double surface = shaped_surface(query.x, query.z);
    return {query.x, query.z, surface, surface};
}

TerrainBiomeId NativeEffectiveTerrainSource::sample_surface_biome(
    const WorldSurfaceColumnQuery &query) const {
    validate_world_query(query);
    require_primary_page_query(pin_, query.x, query.z);
    return shaped_surface_biome(query.x, query.z);
}

NativeEffectiveNumericFacts NativeEffectiveTerrainSource::sample_lattice_numeric(
    const WorldLatticeQuery &query) const {
    validate_world_query(query);
    require_primary_page_query(pin_, query.coordinate.x, query.coordinate.z);
    const auto resolved = resolve_world_query(pin_.definition(), query);
    const CellCoord source = position_cell(resolved.lattice_position, pin_.definition().constants().cell_size_meters);
    const double surface = shaped_surface(source.x, source.z);
    if (const auto durable = pin_.deltas().durable_terrain_at(query.coordinate))
        return edited_numeric(query.coordinate, source, *durable, surface);
    // This mirrors VoxelTerrainGenerator: density/shaping follows the remapped
    // world position while generated material classification keeps the
    // original lattice cell and its direct-integer biome lookup.
    return generated_numeric(query.coordinate, resolved.lattice_position, query.coordinate, query.coordinate);
}

NativeEffectiveNumericFacts NativeEffectiveTerrainSource::sample_world_numeric(
    const WorldFloat32Position position) const {
    const double cell_size = pin_.definition().constants().cell_size_meters;
    const CellCoord source = position_cell(position, cell_size);
    // TerrainVolumeService.generated_sample(position) contributes surfaceY,
    // while get_cell_state(remapped_cell) owns density/material/biome. Its
    // generated fallback is sampled at that cell's centre, not at `position`.
    const double surface = generated_at(position).surface_y;
    const NativeCellState state = sample_cell_state_in_pinned_page(
        {source, WorldQueryIntent::gameplay});
    if (!affects_terrain_mesh(state)) {
        return {source, source, -cell_size, false, surface, TerrainMaterialId::air,
            state.generated, state.edited};
    }
    return {source, source, state.density,
        !state.solid && state.biome == TerrainBiomeId::underground_air,
        surface, state.material, state.generated, state.edited};
}

NativeEffectiveNumericFacts NativeEffectiveTerrainSource::sample_surface_projection_numeric(
    const WorldLatticeQuery &query) const {
    validate_world_query(query);
    require_primary_page_query(pin_, query.coordinate.x, query.coordinate.z);
    const auto resolved = resolve_native_surface_projection_query(pin_.definition(), query);
    const CellCoord source = position_cell(resolved.position, pin_.definition().constants().cell_size_meters);
    const NativeCellState state = sample_cell_state({query.coordinate, WorldQueryIntent::gameplay});
    if (state.edited && affects_surface_projection(state)) {
        // The edited branch in GDScript reports the requested column's
        // deformed reference, not the float32-remapped generated column.
        // Legacy brush authority is disabled; volume edits already live in
        // typed cells, so current deformed reference equals native shaping.
        const double requested_surface = shaped_surface(query.coordinate.x, query.coordinate.z);
        return edited_numeric(query.coordinate, source, state, requested_surface);
    }
    // WorldGenerationSystem.generate_sample_without_volume derives its
    // material/biome cell from world_to_cell3(position). At float32 precision
    // boundaries that cell can differ from the requested grid coordinate.
    return generated_numeric(query.coordinate, resolved.position, source, source);
}

NativeEffectiveCellStateFacts NativeEffectiveTerrainSource::sample_cell_state_facts(
    const WorldCellCenterQuery &query) const {
    validate_world_query(query);
    require_primary_page_query(pin_, query.coordinate.x, query.coordinate.z);
    const auto resolved = resolve_world_query(pin_.definition(), query);
    const CellCoord source = position_cell(
        resolved.center_position, pin_.definition().constants().cell_size_meters);
    return {query.coordinate, source, sample_cell_state_in_pinned_page(query)};
}

NativeCellState NativeEffectiveTerrainSource::sample_cell_state(
    const WorldCellCenterQuery &query) const {
    return sample_cell_state_facts(query).state;
}

NativeCellState NativeEffectiveTerrainSource::sample_cell_state_in_pinned_page(
    const WorldCellCenterQuery &query) const {
    // Typed state is page-projected into the pin identity. Prove that the
    // queried page participates before consulting the delta snapshot; a typed
    // hit must never bypass the pin's physical-content boundary.
    static_cast<void>(pin_.terrain_shaping_for_page(
        page_for(query.coordinate.x, query.coordinate.z)));
    const auto resolved = resolve_world_query(pin_.definition(), query);
    if (const auto typed = pin_.deltas().effective_typed_cell_at(query.coordinate)) return *typed;

    const GeneratedFacts generated = generated_at(resolved.center_position);
    const double cell_size = pin_.definition().constants().cell_size_meters;
    const double depth = std::max(0.0, generated.surface_y - static_cast<double>(resolved.center_position.y));
    const double depth_cells = depth / std::max(0.001, cell_size);
    const TerrainBiomeId surface_biome = shaped_surface_biome(query.coordinate.x, query.coordinate.z);
    bool solid = generated.solid;
    double density = generated.density;
    TerrainMaterialId material = TerrainMaterialId::air;
    TerrainBiomeId biome = surface_biome;
    TerrainFluidId fluid = TerrainFluidId::none;

    if (query.coordinate.y <= pin_.definition().constants().world_bottom_cell_y + 1) {
        solid = true;
        density = std::max(density, cell_size * 4.0);
        material = TerrainMaterialId::bedrock;
        biome = TerrainBiomeId::deep_underground;
    } else if (solid) {
        material = natural_.solid_material_for(query.coordinate, generated.surface_y,
            resolved.center_position.y, surface_biome, density);
        biome = depth > cell_size * 34.0 ? TerrainBiomeId::deep_underground
            : depth > cell_size * 3.0 ? TerrainBiomeId::underground : surface_biome;
    } else if (resolved.center_position.y <= pin_.definition().constants().water_level_meters
        && depth <= cell_size * 2.0) {
        material = TerrainMaterialId::water;
        biome = surface_biome;
        fluid = TerrainFluidId::water;
    } else if (depth > cell_size * 0.35) {
        biome = TerrainBiomeId::underground_air;
        fluid = natural_.underground_fluid_for(query.coordinate, resolved.center_position,
            depth_cells, surface_biome);
        material = fluid == TerrainFluidId::water ? TerrainMaterialId::water
            : fluid == TerrainFluidId::lava ? TerrainMaterialId::lava : TerrainMaterialId::air;
    }

    const std::uint8_t sky = solid || biome == TerrainBiomeId::underground_air ? 0 : 15;
    NativeCellStateInput state;
    state.cell = query.coordinate;
    state.material = material;
    state.biome = biome;
    state.solid = solid;
    state.density = density;
    state.fluid = fluid;
    state.light = {sky, 0};
    state.generated = true;
    state.edited = false;
    return make_native_cell_state(state);
}

} // namespace voxel::world_backend
