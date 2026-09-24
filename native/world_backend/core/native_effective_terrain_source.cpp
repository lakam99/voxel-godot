#include "native_effective_terrain_source.hpp"

#include <algorithm>
#include <array>
#include <cmath>
#include <limits>
#include <stdexcept>
#include <string>
#include <utility>

namespace voxel::world_backend {
namespace {

std::int32_t checked_cell_coordinate(const double value) {
    if (!std::isfinite(value)
        || value < static_cast<double>(std::numeric_limits<std::int32_t>::min())
        || value > static_cast<double>(std::numeric_limits<std::int32_t>::max())) {
        throw std::invalid_argument("native effective terrain position is outside cell domain");
    }
    return static_cast<std::int32_t>(value);
}

std::int32_t floor_position_cell(const float coordinate, const double cell_size) {
    return checked_cell_coordinate(
        std::floor(static_cast<double>(coordinate) / cell_size));
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

struct ProjectionScanBounds {
    std::int32_t top = 0;
    std::int32_t bottom = 0;
    std::size_t candidates = 0;
};

void validate_projection_query_header(
    const NativeEffectiveSurfaceProjectionQuery &query) {
    validate_world_query(WorldLatticeQuery{query.start_cell, query.intent});
    if (query.intent != WorldQueryIntent::gameplay
        || query.semantic_revision
            != NativeEffectiveSurfaceProjectionQuery::SEMANTIC_REVISION) {
        throw std::invalid_argument("native effective surface projection query is invalid");
    }
}

void validate_known_height_query_header(
    const NativeEffectiveKnownHeightProjectionQuery &query) {
    validate_world_query(WorldLatticeQuery{query.column_cell, query.intent});
    if (query.intent != WorldQueryIntent::gameplay
        || query.semantic_revision
            != NativeEffectiveKnownHeightProjectionQuery::SEMANTIC_REVISION
        || !std::isfinite(query.surface_y)) {
        throw std::invalid_argument("native effective known-height projection query is invalid");
    }
}

ProjectionScanBounds projection_scan_bounds(
    const WorldSourceConstants &constants,
    const NativeEffectiveSurfaceProjectionQuery &query) {
    validate_projection_query_header(query);
    const double cell_size = constants.cell_size_meters;
    const std::int32_t admitted_world_top = checked_cell_coordinate(std::ceil(
        (constants.maximum_surface_meters + cell_size * 4.0) / cell_size));
    if (admitted_world_top == std::numeric_limits<std::int32_t>::max()) {
        throw std::invalid_argument("native effective surface projection top has no air cell");
    }
    const std::int64_t world_top = admitted_world_top;
    const std::int64_t up = std::max<std::int64_t>(1, query.max_up_cells);
    const std::int64_t down = std::max<std::int64_t>(1, query.max_down_cells);
    const std::int64_t top = std::min(
        world_top, static_cast<std::int64_t>(query.start_cell.y) + up);
    const std::int64_t bottom = std::max(
        static_cast<std::int64_t>(constants.world_bottom_cell_y),
        static_cast<std::int64_t>(query.start_cell.y) - down);
    const std::size_t count = top < bottom ? 0U
        : static_cast<std::size_t>(top - bottom + 1);
    if (count > NativeEffectiveTerrainSource::MAX_PROJECTION_VERTICAL_CANDIDATES) {
        throw std::length_error("native effective surface projection vertical scan exceeds source limit");
    }
    return {static_cast<std::int32_t>(top), static_cast<std::int32_t>(bottom), count};
}

NativeTerrainOccupancyFacts occupancy_facts(
    const CellCoord cell, const NativeCellState &state,
    const NativeCellState &below, const NativeCellState &above) {
    NativeTerrainOccupancyFacts result;
    result.cell = cell;
    result.solid = state.solid;
    result.air = !state.solid;
    result.material = state.material;
    result.biome = state.biome;
    result.fluid = state.fluid;
    result.light = state.light;
    result.floor_solid = below.solid;
    result.ceiling_solid = above.solid;
    // Projection callers have already proven standing air and solid support;
    // headroom is the only remaining walkability decision at this boundary.
    result.walkable_air = !above.solid;
    return result;
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

NativeEffectiveTerrainSource::LatticeColumnScratch
NativeEffectiveTerrainSource::prepare_lattice_column(const std::int32_t x, const std::int32_t z) const {
    require_primary_page_query(pin_, x, z);
    return {this, x, z};
}

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
    const WorldFloat32Position position, LatticeColumnScratch *column) const {
    const double cell_size = pin_.definition().constants().cell_size_meters;
    const CellCoord source = position_cell(position, cell_size);
    const auto sampler = [this](const std::int32_t sample_x, const std::int32_t sample_z) {
        return natural_surface(sample_x, sample_z);
    };
    const auto &shaping = shaping_for(source.x, source.z);
    const double surface = column && column->source_surface_y
        ? *column->source_surface_y : shaping.surface_y(source.x, source.z, sampler);
    if (column && !column->source_surface_y) column->source_surface_y = surface;
    const double depth_cells = std::max(0.0, surface - static_cast<double>(position.y))
        / std::max(0.001, cell_size);
    double density = surface - static_cast<double>(position.y);
    if (density > 0.0) {
        const bool protected_column = column && column->source_protects_overburden
            ? *column->source_protects_overburden
            : shaping.protects_minimum_overburden(source.x, source.z, sampler);
        if (column && !column->source_protects_overburden)
            column->source_protects_overburden = protected_column;
        const double overburden = protected_column ? 8.0 : 3.0;
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
    const CellCoord material_cell, const CellCoord biome_cell,
    const GeneratedMaterialSemantics material_semantics, LatticeColumnScratch *column) const {
    const GeneratedFacts generated = generated_at(position, column);
    TerrainMaterialId material = TerrainMaterialId::air;
    if (generated.solid) {
        if (material_semantics == GeneratedMaterialSemantics::cell_state
            && material_cell.y <= pin_.definition().constants().world_bottom_cell_y + 1)
            material = TerrainMaterialId::bedrock;
        else {
            const TerrainBiomeId biome = column && column->requested_surface_biome
                ? *column->requested_surface_biome
                : shaped_surface_biome(biome_cell.x, biome_cell.z);
            if (column && !column->requested_surface_biome)
                column->requested_surface_biome = biome;
            material = material_semantics == GeneratedMaterialSemantics::world_sample
                ? natural_.world_sample_material_for(material_cell, generated.surface_y, position.y,
                    biome, generated.density)
                : natural_.solid_material_for(material_cell, generated.surface_y, position.y,
                    biome, generated.density);
        }
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

double NativeEffectiveTerrainSource::sample_volume_surface_y(
    const WorldSurfaceColumnQuery &query) const {
    validate_world_query(query);
    require_primary_page_query(pin_, query.x, query.z);
    const auto &constants = pin_.definition().constants();
    const double cell_size = constants.cell_size_meters;
    const double reference_y = shaped_surface(query.x, query.z);
    // Match TerrainVolumeService.world_top_cell_y() and its bounded +16-cell
    // probe above the reference surface. The source definition has already
    // admitted finite positive cell size and finite surface bounds.
    const double world_top = std::ceil(
        (constants.maximum_surface_meters + cell_size * 4.0) / cell_size);
    const double reference_probe_top = std::floor(reference_y / cell_size) + 16.0;
    const std::int32_t top_y = checked_cell_coordinate(
        std::min(world_top, reference_probe_top));
    for (std::int64_t scan_y = top_y;
         scan_y >= static_cast<std::int64_t>(constants.world_bottom_cell_y); --scan_y) {
        const std::int32_t y = static_cast<std::int32_t>(scan_y);
        const CellCoord solid_cell{query.x, y, query.z};
        if (sample_cell_state({solid_cell, WorldQueryIntent::gameplay}).solid) {
            const CellCoord above_cell{
                query.x, checked_cell_coordinate(static_cast<double>(y) + 1.0), query.z};
            if (!sample_cell_state({above_cell, WorldQueryIntent::gameplay}).solid)
                return static_cast<double>(y + 1) * cell_size;
        }
    }
    return reference_y;
}

double NativeEffectiveTerrainSource::sample_continuous_volume_surface_y(
    const WorldSurfaceColumnQuery &query) const {
    validate_world_query(query);
    require_primary_page_query(pin_, query.x, query.z);
    return continuous_volume_surface_y(query);
}

double NativeEffectiveTerrainSource::continuous_volume_surface_y(
    const WorldSurfaceColumnQuery &query) const {
    const auto &constants = pin_.definition().constants();
    const double cell_size = constants.cell_size_meters;
    const double reference = shaped_surface(query.x, query.z);
    const std::int32_t top = checked_cell_coordinate(std::min(
        std::ceil((constants.maximum_surface_meters + cell_size * 4.0) / cell_size),
        std::floor(reference / cell_size) + 8.0));
    for (std::int64_t scan_y = top;
         scan_y > static_cast<std::int64_t>(constants.world_bottom_cell_y); --scan_y) {
        const auto y = static_cast<std::int32_t>(scan_y);
        // The GDScript helper returns Vector3, so each density crosses one
        // float32 storage boundary before the scalar interpolation resumes.
        const double solid = static_cast<float>(sample_surface_projection_numeric(
            {{query.x, y, query.z}, WorldQueryIntent::terrain_collision}).density);
        if (solid < 0.0) continue;
        const double air = static_cast<float>(sample_surface_projection_numeric(
            {{query.x, checked_cell_coordinate(scan_y + 1.0), query.z},
                WorldQueryIntent::terrain_collision}).density);
        if (air >= 0.0) continue;
        const double denominator = solid - air;
        if (std::abs(denominator) <= 0.0001) return static_cast<double>(scan_y + 1) * cell_size;
        const double t = std::clamp(solid / denominator, 0.0, 1.0);
        return static_cast<double>(scan_y) * cell_size
            + (static_cast<double>(scan_y + 1) * cell_size
                - static_cast<double>(scan_y) * cell_size) * t;
    }
    return reference;
}

NativeSurfacePropSpawnFacts NativeEffectiveTerrainSource::sample_surface_prop_spawn(
    const WorldSurfaceColumnQuery &query) const {
    validate_world_query(query);
    require_primary_page_query(pin_, query.x, query.z);
    const auto &constants = pin_.definition().constants();
    const double cell_size = constants.cell_size_meters;
    NativeSurfacePropSpawnFacts result;
    result.physical_content_identity = pin_.physical_content_identity();
    result.terrain_delta_revision = pin_.terrain_delta_revision();
    result.shaping_registry_revision = pin_.shaping_registry_revision();
    const double height = continuous_volume_surface_y(query);
    result.height_meters = height;
    result.world_anchor_y = static_cast<float>(height);
    result.biome = shaped_surface_biome(query.x, query.z);
    const std::int32_t height_cell = checked_cell_coordinate(std::floor(height / cell_size));

    // The live projection count includes edited cells even when saveDelta is
    // false. Resolve the effective typed column, including transient edits;
    // an overlay masks its durable cell just as point queries do.
    const bool has_projection_edit = pin_.deltas().effective_typed_column_any(
        query.x, query.z, affects_surface_projection);
    if (!has_projection_edit) {
        result.found = true;
        result.mode = NativeSurfacePropSpawnMode::generated_surface_fast;
        result.material = result.biome == TerrainBiomeId::beach
                || result.biome == TerrainBiomeId::desert ? TerrainMaterialId::sand
            : result.biome == TerrainBiomeId::swamp ? TerrainMaterialId::mud
            : result.biome == TerrainBiomeId::snow ? TerrainMaterialId::snow
            // The generated fast path can only yield ocean/beach, town, or
            // BiomeRegionField's eight regional names. Alpine is not among
            // them; an edited alpine state uses the projection path above.
            : result.biome == TerrainBiomeId::tundra ? TerrainMaterialId::stone
            : TerrainMaterialId::grass;
        result.solid_cell = {query.x, height_cell, query.z};
        result.air_cell = {query.x, checked_cell_coordinate(static_cast<double>(height_cell) + 1.0), query.z};
        return result;
    }

    result.mode = NativeSurfacePropSpawnMode::terrain_volume_projection;
    const std::int32_t top = checked_cell_coordinate(
        std::ceil((constants.maximum_surface_meters + cell_size * 4.0) / cell_size));
    const std::int32_t scan_top = checked_cell_coordinate(std::min(
        static_cast<double>(top), static_cast<double>(height_cell) + 24.0));
    const std::int32_t scan_bottom = checked_cell_coordinate(std::max(
        static_cast<double>(constants.world_bottom_cell_y), static_cast<double>(height_cell) - 96.0));
    for (std::int64_t y = scan_top; y >= scan_bottom; --y) {
        const CellCoord solid_cell{query.x, static_cast<std::int32_t>(y), query.z};
        const CellCoord air_cell{query.x, checked_cell_coordinate(y + 1.0), query.z};
        const NativeCellState solid = sample_cell_state({solid_cell, WorldQueryIntent::gameplay});
        if (!solid.solid) continue;
        const NativeCellState air = sample_cell_state({air_cell, WorldQueryIntent::gameplay});
        if (air.solid) continue;
        // NativeCellState admission rejects solid air/fluid materials. The
        // remaining live rejection is a fluid occupying the air cell.
        if (air.fluid != TerrainFluidId::none) return result;
        result.found = true;
        result.height_meters = static_cast<double>(air_cell.y) * cell_size;
        result.world_anchor_y = static_cast<float>(result.height_meters);
        result.biome = solid.biome == TerrainBiomeId::underground
                || solid.biome == TerrainBiomeId::deep_underground
            ? shaped_surface_biome(query.x, query.z) : solid.biome;
        result.material = solid.material;
        result.solid_cell = solid_cell;
        result.air_cell = air_cell;
        return result;
    }
    return result;
}

std::size_t NativeEffectiveTerrainSource::surface_projection_candidate_capacity(
    const NativeEffectiveSurfaceProjectionQuery &query) const {
    require_primary_page_query(pin_, query.start_cell.x, query.start_cell.z);
    return projection_scan_bounds(pin_.definition().constants(), query).candidates;
}

std::size_t NativeEffectiveTerrainSource::known_height_projection_candidate_capacity(
    const NativeEffectiveKnownHeightProjectionQuery &query) const {
    validate_known_height_query_header(query);
    require_primary_page_query(pin_, query.column_cell.x, query.column_cell.z);
    const double floored_probe = std::floor(
        query.surface_y / pin_.definition().constants().cell_size_meters);
    if (floored_probe < static_cast<double>(std::numeric_limits<std::int32_t>::min()) + 2.0
        || floored_probe > static_cast<double>(std::numeric_limits<std::int32_t>::max()) - 2.0) {
        throw std::invalid_argument("native effective known-height projection is outside cell domain");
    }
    return KNOWN_HEIGHT_PROJECTION_CANDIDATES;
}

NativeEffectiveSurfaceProjectionFacts NativeEffectiveTerrainSource::sample_surface_projection(
    const NativeEffectiveSurfaceProjectionQuery &query) const {
    require_primary_page_query(pin_, query.start_cell.x, query.start_cell.z);
    const ProjectionScanBounds bounds = projection_scan_bounds(
        pin_.definition().constants(), query);
    NativeEffectiveSurfaceProjectionFacts result;
    result.column_cell = query.start_cell;
    if (bounds.candidates == 0U) return result;
    const double cell_size = pin_.definition().constants().cell_size_meters;
    for (std::int64_t y = bounds.top; y >= bounds.bottom; --y) {
        const CellCoord solid_cell{
            query.start_cell.x, static_cast<std::int32_t>(y), query.start_cell.z};
        const CellCoord air_cell{
            query.start_cell.x, static_cast<std::int32_t>(y + 1), query.start_cell.z};
        const NativeCellState solid = sample_cell_state(
            {solid_cell, WorldQueryIntent::gameplay});
        if (!solid.solid) continue;
        const NativeCellState air = sample_cell_state(
            {air_cell, WorldQueryIntent::gameplay});
        if (air.solid) continue;
        result.found = true;
        result.solid_cell = solid_cell;
        result.air_cell = air_cell;
        result.position = {
            static_cast<float>((static_cast<double>(air_cell.x) + 0.5) * cell_size),
            static_cast<float>(static_cast<double>(air_cell.y) * cell_size),
            static_cast<float>((static_cast<double>(air_cell.z) + 0.5) * cell_size),
        };
        result.solid_state = solid;
        result.air_state = air;
        return result;
    }
    return result;
}

NativeEffectiveWalkableProjectionFacts
NativeEffectiveTerrainSource::sample_walkable_surface_near(
    const NativeEffectiveSurfaceProjectionQuery &query) const {
    NativeEffectiveWalkableProjectionFacts result;
    result.projection = sample_surface_projection(query);
    if (!result.projection.found) return result;
    const CellCoord above_cell{
        result.projection.air_cell.x,
        checked_cell_coordinate(static_cast<double>(result.projection.air_cell.y) + 1.0),
        result.projection.air_cell.z,
    };
    const NativeCellState above = sample_cell_state(
        {above_cell, WorldQueryIntent::gameplay});
    result.headroom_state = above;
    // sample_surface_projection already proved the standing cell is air.
    result.walkable = !above.solid;
    result.occupancy = occupancy_facts(
        result.projection.air_cell, *result.projection.air_state,
        *result.projection.solid_state, above);
    return result;
}

NativeEffectiveKnownHeightProjectionFacts
NativeEffectiveTerrainSource::sample_navigation_surface_at_known_height(
    const NativeEffectiveKnownHeightProjectionQuery &query) const {
    static_cast<void>(known_height_projection_candidate_capacity(query));
    const double cell_size = pin_.definition().constants().cell_size_meters;
    const double floored_probe = std::floor(query.surface_y / cell_size);
    const std::int32_t probe_y = static_cast<std::int32_t>(floored_probe);
    NativeEffectiveKnownHeightProjectionFacts result;
    result.projection.column_cell = {
        query.column_cell.x, 0, query.column_cell.z};
    // This deliberately matches range(probe_y, probe_y - 3, -1): three
    // candidates, each proven by support, standing-air, and headroom cells.
    // TerrainVolumeService's nearby prose still says "four"; executable
    // semantics and the shadow parity contract are authoritative here.
    std::array<std::optional<NativeCellState>, 5> states;
    const auto state_at = [&](const std::int32_t y) -> const NativeCellState & {
        const std::size_t index = static_cast<std::size_t>(y - (probe_y - 2));
        if (!states[index]) {
            states[index] = sample_cell_state(
                {{query.column_cell.x, y, query.column_cell.z},
                    WorldQueryIntent::gameplay});
        }
        return *states[index];
    };
    for (std::int32_t offset = 0;
         offset < static_cast<std::int32_t>(KNOWN_HEIGHT_PROJECTION_CANDIDATES);
         ++offset) {
        const CellCoord solid_cell{
            query.column_cell.x, probe_y - offset, query.column_cell.z};
        const CellCoord air_cell{
            query.column_cell.x, probe_y - offset + 1, query.column_cell.z};
        const CellCoord above_cell{
            query.column_cell.x, probe_y - offset + 2, query.column_cell.z};
        const NativeCellState solid = state_at(solid_cell.y);
        const NativeCellState air = state_at(air_cell.y);
        const NativeCellState above = state_at(above_cell.y);
        if (!solid.solid || air.solid || above.solid) continue;
        result.status = NativeKnownHeightProjectionStatus::ready;
        result.projection.found = true;
        result.projection.solid_cell = solid_cell;
        result.projection.air_cell = air_cell;
        result.projection.position = {
            static_cast<float>(static_cast<double>(query.column_cell.x) * cell_size),
            static_cast<float>(query.surface_y),
            static_cast<float>(static_cast<double>(query.column_cell.z) * cell_size),
        };
        result.projection.solid_state = solid;
        result.projection.air_state = air;
        result.headroom_state = above;
        result.walkable = true;
        result.occupancy = occupancy_facts(air_cell, air, solid, above);
        return result;
    }
    return result;
}

NativeEffectiveNumericFacts NativeEffectiveTerrainSource::sample_lattice_numeric(
    const WorldLatticeQuery &query) const {
    validate_world_query(query);
    LatticeColumnScratch column = prepare_lattice_column(query.coordinate.x, query.coordinate.z);
    return sample_lattice_numeric(query, column);
}

NativeEffectiveNumericFacts NativeEffectiveTerrainSource::sample_lattice_numeric(
    const WorldLatticeQuery &query, LatticeColumnScratch &column) const {
    validate_world_query(query);
    require_primary_page_query(pin_, query.coordinate.x, query.coordinate.z);
    const auto resolved = resolve_world_query(pin_.definition(), query);
    const CellCoord source = position_cell(resolved.lattice_position, pin_.definition().constants().cell_size_meters);
    // The versioned lattice remap computes each float32 axis independently.
    // With the same requested X/Z and source instance, Y cannot select a
    // different shaping column; there is no separate mutable X/Z cache to
    // accept as caller authority.
    if (column.owner != this || column.requested_x != query.coordinate.x
        || column.requested_z != query.coordinate.z)
        throw std::invalid_argument("native lattice column scratch does not match query");
    if (const auto durable = pin_.deltas().durable_terrain_at(query.coordinate)) {
        if (!column.source_surface_y)
            column.source_surface_y = shaped_surface(source.x, source.z);
        return edited_numeric(query.coordinate, source, *durable, *column.source_surface_y);
    }
    // This mirrors VoxelTerrainGenerator: density/shaping follows the remapped
    // world position while generated material classification keeps the
    // original lattice cell and its direct-integer biome lookup.
    return generated_numeric(query.coordinate, resolved.lattice_position, query.coordinate, query.coordinate,
        GeneratedMaterialSemantics::cell_state, &column);
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
    return generated_numeric(query.coordinate, resolved.position, source, source,
        GeneratedMaterialSemantics::world_sample);
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
