#include "native_natural_terrain_source.hpp"

#include "biome_region_field.hpp"
#include "fast_noise_compat.hpp"
#include "legacy_seed_hash.hpp"

#include <algorithm>
#include <cmath>
#include <limits>
#include <string>
#include <utility>
#include <vector>

namespace voxel::world_backend {
namespace {

double clamp01(const double value) noexcept { return std::clamp(value, 0.0, 1.0); }
double lerp(const double from, const double to, const double weight) noexcept { return from + (to - from) * weight; }
double smoothstep(const double value, const double low, const double high) noexcept {
    // Every private call below supplies fixed, strictly ordered thresholds.
    // This is deliberately not a public generic smoothstep API.
    const double unit = clamp01((value - low) / (high - low));
    return unit * unit * (3.0 - 2.0 * unit);
}

void append_ascii(std::vector<std::uint32_t> &target, const std::string &value) {
    for (const unsigned char character : value) target.push_back(character);
}
std::vector<std::uint32_t> script_hash_key(const AdmittedTerrainSeed &seed, const std::string &prefix, const std::string &suffix) {
    // The prefix/suffix are literal ASCII format tokens.  Both occurrences of
    // seed_text are inserted as Godot Unicode scalars, never UTF-8 bytes.
    std::vector<std::uint32_t> key = seed.code_points;
    key.push_back(':'); append_ascii(key, prefix); key.insert(key.end(), seed.code_points.begin(), seed.code_points.end()); append_ascii(key, suffix); return key;
}
double script_hash01(const AdmittedTerrainSeed &seed, const std::string &prefix, const std::string &suffix) {
    return static_cast<double>(legacy_seed_hash(script_hash_key(seed, prefix, suffix)) % 100000U) / 100000.0;
}
std::string cell_text(const CellCoord &cell) {
    return std::to_string(cell.x) + "," + std::to_string(cell.y) + "," + std::to_string(cell.z);
}
std::int32_t floor_cell(const float position, const double cell_size) {
    const double quotient = static_cast<double>(position) / cell_size;
    if (!std::isfinite(quotient) || quotient < static_cast<double>(std::numeric_limits<std::int32_t>::min())
        || quotient >= static_cast<double>(std::numeric_limits<std::int32_t>::max())) throw std::invalid_argument("native terrain position is outside cell domain");
    return static_cast<std::int32_t>(std::floor(quotient));
}
CellCoord source_cell(const WorldFloat32Position &position, const double cell_size) {
    return {floor_cell(position.x, cell_size), floor_cell(position.y, cell_size), floor_cell(position.z, cell_size)};
}
constexpr std::int32_t script_floor_divide(const std::int32_t value, const std::int32_t divisor) noexcept {
    // GDScript's `float(cell.x) / 2.0` is binary64 arithmetic even though the
    // resulting world Vector types use real_t. Every int32 and these positive
    // integer divisors are exactly representable in binary64, so exact signed
    // integer floor division preserves the script result without narrowing.
    const std::int32_t quotient = value / divisor;
    return value % divisor < 0 ? quotient - 1 : quotient;
}
static_assert(script_floor_divide(16777219, 2) == 8388609);
static_assert(script_floor_divide(16777225, 5) == 3355445);
static_assert(script_floor_divide(-1, 2) == -1);

WorldFloat32HorizontalPosition regional_biome_position(
    const std::int32_t x, const std::int32_t z, const double cell_size) noexcept {
    // `Vector2(float(cell.x) * cell_size(), ...)` evaluates each scalar
    // expression in GDScript's binary64 `float`, then crosses the Vector2
    // real_t boundary once.  This is intentionally different from the
    // two-float-boundary `Vector3(cell) * CELL` meshing lattice convention.
    return {
        static_cast<float>(static_cast<double>(x) * cell_size),
        static_cast<float>(static_cast<double>(z) * cell_size),
    };
}
TerrainBiomeId regional_biome_id(const std::string &value) {
    if (value == "plains") return TerrainBiomeId::plains;
    if (value == "forest") return TerrainBiomeId::forest;
    if (value == "swamp") return TerrainBiomeId::swamp;
    if (value == "desert") return TerrainBiomeId::desert;
    if (value == "savanna") return TerrainBiomeId::savanna;
    if (value == "snow") return TerrainBiomeId::snow;
    if (value == "taiga") return TerrainBiomeId::taiga;
    // BiomeRegionField is a closed eight-name source.  The preceding seven
    // names exhaust every alternative to its remaining tundra output.
    return TerrainBiomeId::tundra;
}
TerrainMaterialId top_material(const TerrainBiomeId biome) noexcept {
    if (biome == TerrainBiomeId::beach || biome == TerrainBiomeId::desert) return TerrainMaterialId::sand;
    if (biome == TerrainBiomeId::swamp) return TerrainMaterialId::mud;
    if (biome == TerrainBiomeId::snow) return TerrainMaterialId::snow;
    // Natural-source biome admission cannot yield alpine: it is ocean/beach or
    // one of BiomeRegionField's eight declared regional strings.
    if (biome == TerrainBiomeId::tundra) return TerrainMaterialId::stone;
    return TerrainMaterialId::grass;
}
TerrainMaterialId subsoil_material(const TerrainBiomeId biome) noexcept {
    if (biome == TerrainBiomeId::beach || biome == TerrainBiomeId::desert) return TerrainMaterialId::sand;
    if (biome == TerrainBiomeId::swamp) return TerrainMaterialId::mud;
    if (biome == TerrainBiomeId::snow) return TerrainMaterialId::snow;
    return TerrainMaterialId::dirt;
}
TerrainMaterialId solid_material(const AdmittedTerrainSeed &seed, const CellCoord &cell, const double surface_y,
    const double position_y, const TerrainBiomeId biome, const double density, const double cell_size,
    const std::int32_t world_bottom_cell_y, const bool classify_deep_stone) {
    // The only caller has already selected `solid`, and handles the bottom
    // bedrock cells before entering this material classifier.
    (void)density; (void)world_bottom_cell_y;
    const double depth = std::max(0.0, surface_y - position_y);
    if (depth <= cell_size * 1.20) return top_material(biome);
    if (depth <= cell_size * 4.65) return subsoil_material(biome);
    const double depth_cells = depth / std::max(0.001, cell_size);
    const CellCoord copper{cell.x / 3, cell.y / 3, cell.z / 3};
    if (depth_cells >= 8.0 && script_hash01(seed, "subsurface-copper:", ":" + cell_text(copper)) > 0.985) return TerrainMaterialId::copper_ore;
    const CellCoord iron{cell.x / 4, cell.y / 4, cell.z / 4};
    if (depth_cells >= 15.0 && script_hash01(seed, "subsurface-iron:", ":" + cell_text(iron)) > 0.992) return TerrainMaterialId::iron_ore;
    return classify_deep_stone && depth > cell_size * 38.0
        ? TerrainMaterialId::deep_stone : TerrainMaterialId::stone;
}
TerrainFluidId underground_fluid(const AdmittedTerrainSeed &seed, const CellCoord &cell, const WorldFloat32Position &position,
    const double depth_cells, const TerrainBiomeId surface_biome, const double cell_size, const std::int32_t world_bottom_cell_y,
    const double water_level_meters) {
    if (depth_cells < 6.0) return TerrainFluidId::none;
    if (cell.y <= world_bottom_cell_y + 9 && depth_cells >= 34.0) {
        const CellCoord key{script_floor_divide(cell.x, 4), script_floor_divide(cell.y, 2), script_floor_divide(cell.z, 4)};
        if (script_hash01(seed, "terrain-volume-lava:", ":" + cell_text(key)) > 0.82) return TerrainFluidId::lava;
    }
    if (static_cast<double>(position.y) <= water_level_meters - cell_size * 1.5 && surface_biome != TerrainBiomeId::desert) {
        const CellCoord key{script_floor_divide(cell.x, 5), script_floor_divide(cell.y, 3), script_floor_divide(cell.z, 5)};
        if (script_hash01(seed, "terrain-volume-aquifer:", ":" + cell_text(key)) > 0.88) return TerrainFluidId::water;
    }
    return TerrainFluidId::none;
}
} // namespace

double native_underground_density_from_raw(
    const double raw_density, const double cell_size, const double depth_cells,
    const double minimum_overburden_cells) noexcept {
    if (depth_cells <= minimum_overburden_cells) return cell_size;
    const double fade = clamp01(smoothstep(depth_cells, minimum_overburden_cells,
        minimum_overburden_cells + 5.0) * (1.0 - smoothstep(depth_cells, 58.0, 74.0)));
    return lerp(cell_size, raw_density, fade);
}

struct NativeNaturalTerrainSource::GeneratedSample {
    CellCoord source_cell; double surface_y = 0.0; double density = 0.0; bool solid = false;
    TerrainBiomeId surface_biome = TerrainBiomeId::plains; TerrainBiomeId biome = TerrainBiomeId::plains;
};

NativeNaturalTerrainUnsupported::NativeNaturalTerrainUnsupported(const NativeTerrainShapingInput input)
    : std::runtime_error("native natural terrain requires generated town and site profile migration"), input_(input) {}
NativeTerrainShapingInput NativeNaturalTerrainUnsupported::input() const noexcept { return input_; }
NativeNaturalTerrainSource::NativeNaturalTerrainSource(WorldSourceDefinition definition, const NativeNaturalTerrainRequest request)
    : definition_(std::move(definition)), seed_hash_(legacy_seed_hash(definition_.raw_terrain_seed().code_points)) {
    if (request.shaping_input != NativeTerrainShapingInput::declared_absent) throw NativeNaturalTerrainUnsupported(request.shaping_input);
}
const WorldSourceDefinition &NativeNaturalTerrainSource::definition() const noexcept { return definition_; }

double NativeNaturalTerrainSource::natural_surface_y(const std::int32_t x, const std::int32_t z) const {
    const FastNoiseCompat noise(seed_hash_);
    const double continent = noise.sample_2d_01(TerrainNoiseChannel::height, x, z);
    const double broad = noise.sample_2d_01(TerrainNoiseChannel::height, x + 12000.0, z - 12200.0);
    const double plain = noise.sample_2d_01(TerrainNoiseChannel::flat, x - 8400.0, z + 7200.0);
    const double ridges = std::abs(noise.sample_2d_01(TerrainNoiseChannel::ridge, x - 200.0, z + 510.0) - 0.5) * 2.0;
    const double flat_mask = smoothstep(plain, 0.42, 0.68);
    const double mountain_mask = smoothstep(noise.sample_2d_01(TerrainNoiseChannel::height, x + 1800.0, z - 1500.0), 0.58, 0.82);
    const double peak_mask = smoothstep(noise.sample_2d_01(TerrainNoiseChannel::ridge, x - 3900.0, z + 2600.0), 0.74, 0.93) * mountain_mask;
    const double plains = 6.0 + continent * 10.0 + (broad - 0.5) * 2.0;
    const double hills = 7.2 + continent * 15.5 + std::pow(std::max(broad - 0.18, 0.0), 1.45) * 12.0;
    const double mountains = 10.0 + continent * 21.0 + std::pow(ridges, 1.92) * (16.0 + mountain_mask * 44.0) + std::pow(peak_mask, 2.05) * 34.0;
    const double detail = (noise.sample_2d_01(TerrainNoiseChannel::ridge, x + 7800.0, z - 9100.0) - 0.5) * lerp(0.28, 1.35, mountain_mask);
    const double raw = definition_.constants().minimum_surface_meters + lerp(lerp(hills, plains, flat_mask), mountains, mountain_mask) + detail;
    const double terrace = lerp(definition_.constants().cell_size_meters * 0.34, definition_.constants().cell_size_meters * 1.15, mountain_mask);
    return std::clamp(std::round(raw / terrace) * terrace, definition_.constants().minimum_surface_meters, definition_.constants().maximum_surface_meters);
}

TerrainBiomeId NativeNaturalTerrainSource::natural_surface_biome(const std::int32_t x, const std::int32_t z) const {
    const double surface = natural_surface_y(x, z);
    if (surface < definition_.constants().water_level_meters + 0.3) return TerrainBiomeId::ocean;
    if (surface < definition_.constants().water_level_meters + 1.7) return TerrainBiomeId::beach;
    return regional_surface_biome(x, z);
}

TerrainBiomeId NativeNaturalTerrainSource::regional_surface_biome(const std::int32_t x, const std::int32_t z) const {
    const auto position = regional_biome_position(x, z, definition_.constants().cell_size_meters);
    return regional_biome_id(BiomeRegionField::sample(definition_.admitted_biome_seed(), {position.x, position.z}).biome);
}

double NativeNaturalTerrainSource::underground_air_density(const WorldFloat32Position &position, const CellCoord &source,
    const double /*surface_y*/, const double depth_cells, const double minimum_overburden_cells) const {
    const double cell_size = definition_.constants().cell_size_meters;
    if (static_cast<double>(position.y) <= static_cast<double>(definition_.constants().world_bottom_cell_y + 2) * cell_size) return cell_size;
    const FastNoiseCompat noise(seed_hash_);
    const float x = static_cast<float>(static_cast<double>(position.x) / cell_size);
    const float y = static_cast<float>(static_cast<double>(position.y) / cell_size);
    const float z = static_cast<float>(static_cast<double>(position.z) / cell_size);
    const double broad = noise.sample_3d_01(TerrainNoiseChannel::ridge, x * 0.44 + 4100.0, y * 0.58 - 2300.0, z * 0.44 + 1700.0);
    const double local = noise.sample_3d_01(TerrainNoiseChannel::height, x * 0.82 - 6200.0, y * 0.76 + 910.0, z * 0.82 + 3600.0);
    const double chamber = noise.sample_3d_01(TerrainNoiseChannel::ridge, x * 0.23 + 8100.0, y * 0.30 - 5400.0, z * 0.23 + 2600.0);
    const double porous_a = noise.sample_3d_01(TerrainNoiseChannel::ridge, x * 0.92 - 7100.0, y * 0.46 + 1900.0, z * 0.74 + 800.0);
    const double porous_b = noise.sample_3d_01(TerrainNoiseChannel::height, x * 0.62 + 2200.0, y * 0.68 - 3600.0, z - 4900.0);
    const double porous = smoothstep(1.0 - std::abs(porous_a - porous_b), 0.44, 0.82);
    const double cellular = script_hash01(definition_.raw_terrain_seed(), "underground-volume:", ":" + cell_text(source));
    const double broad_strength = smoothstep(broad * 0.66 + local * 0.34, 0.48, 0.72);
    const double chamber_strength = smoothstep(chamber, 0.48, 0.66);
    const double porous_strength = porous * smoothstep(local, 0.52, 0.82);
    const double chamber_depth = smoothstep(depth_cells, 8.0, 18.0) * (1.0 - smoothstep(depth_cells, 48.0, 64.0));
    const double signal = clamp01(std::max({broad_strength, chamber_strength * 0.96, porous_strength * 0.90}) + chamber_depth * 0.10 + cellular * 0.025);
    const double strata = noise.sample_3d_01(TerrainNoiseChannel::ridge, x * 0.38 - 1400.0, y * 0.62 + 2500.0, z * 0.38 - 3700.0);
    const double raw_density = (lerp(0.50, 0.60, strata) - chamber_depth * 0.04 - signal) * cell_size * 4.25;
    return native_underground_density_from_raw(
        raw_density, cell_size, depth_cells, minimum_overburden_cells);
}

TerrainMaterialId NativeNaturalTerrainSource::solid_material_for(
    const CellCoord &cell, const double surface_y, const double position_y,
    const TerrainBiomeId biome, const double density) const {
    return solid_material(definition_.raw_terrain_seed(), cell, surface_y, position_y, biome, density,
        definition_.constants().cell_size_meters, definition_.constants().world_bottom_cell_y, true);
}

TerrainMaterialId NativeNaturalTerrainSource::world_sample_material_for(
    const CellCoord &cell, const double surface_y, const double position_y,
    const TerrainBiomeId biome, const double density) const {
    // WorldGenerationSystem.material_from_sample_components deliberately ends
    // with stone after ore classification. Deep-stone is a generated cell
    // state/lattice rule, not a raw world-position sample rule.
    return solid_material(definition_.raw_terrain_seed(), cell, surface_y, position_y, biome, density,
        definition_.constants().cell_size_meters, definition_.constants().world_bottom_cell_y, false);
}

TerrainFluidId NativeNaturalTerrainSource::underground_fluid_for(
    const CellCoord &cell, const WorldFloat32Position &position, const double depth_cells,
    const TerrainBiomeId surface_biome) const {
    return underground_fluid(definition_.raw_terrain_seed(), cell, position, depth_cells, surface_biome,
        definition_.constants().cell_size_meters, definition_.constants().world_bottom_cell_y,
        definition_.constants().water_level_meters);
}

NativeNaturalTerrainSource::GeneratedSample NativeNaturalTerrainSource::sample_generated_at_position(const WorldFloat32Position &position, const CellCoord &coordinate) const {
    const double cell_size = definition_.constants().cell_size_meters;
    const CellCoord source = source_cell(position, cell_size);
    const double surface = natural_surface_y(source.x, source.z);
    double density = surface - position.y;
    const double depth_cells = std::max(0.0, surface - static_cast<double>(position.y)) / std::max(0.001, cell_size);
    if (density > 0.0) density = std::min(density, underground_air_density(position, source, surface, depth_cells));
    if (density > 0.0 && position.y <= definition_.constants().world_bottom_cell_y * cell_size) density = std::max(density, cell_size * 4.0);
    const bool solid = density >= 0.0;
    const TerrainBiomeId surface_biome = natural_surface_biome(source.x, source.z);
    TerrainBiomeId biome = surface_biome;
    if (!solid && surface - position.y > cell_size * 0.35) biome = TerrainBiomeId::underground_air;
    else if (solid && depth_cells > 3.0) biome = TerrainBiomeId::underground;
    (void)coordinate; return {source, surface, density, solid, surface_biome, biome};
}

NativeSurfaceColumnFacts NativeNaturalTerrainSource::sample_surface_column(const WorldSurfaceColumnQuery &query) const {
    validate_world_query(query);
    const double surface = natural_surface_y(query.x, query.z);
    return {query.x, query.z, surface, surface};
}
TerrainBiomeId NativeNaturalTerrainSource::sample_surface_biome(const WorldSurfaceColumnQuery &query) const {
    validate_world_query(query);
    return natural_surface_biome(query.x, query.z);
}
NativeLatticeNumericFacts NativeNaturalTerrainSource::sample_lattice_numeric(const WorldLatticeQuery &query) const {
    const auto resolved = resolve_world_query(definition_, query); const auto generated = sample_generated_at_position(resolved.lattice_position, query.coordinate);
    return {query.coordinate, generated.density, !generated.solid && generated.biome == TerrainBiomeId::underground_air};
}
NativeCellState NativeNaturalTerrainSource::sample_cell_state(const WorldCellCenterQuery &query) const {
    const auto resolved = resolve_world_query(definition_, query); const auto sample = sample_generated_at_position(resolved.center_position, query.coordinate);
    const double cell_size = definition_.constants().cell_size_meters;
    const double depth = std::max(0.0, sample.surface_y - resolved.center_position.y); const double depth_cells = depth / std::max(0.001, cell_size);
    double density = sample.surface_y - resolved.center_position.y;
    if (density > 0.0) density = std::min(density, underground_air_density(resolved.center_position, sample.source_cell, sample.surface_y, depth_cells));
    if (density > 0.0 && resolved.center_position.y <= definition_.constants().world_bottom_cell_y * cell_size) density = std::max(density, cell_size * 4.0);
    bool solid = density >= 0.0; const TerrainBiomeId surface_biome = natural_surface_biome(query.coordinate.x, query.coordinate.z);
    TerrainMaterialId material = TerrainMaterialId::air; TerrainBiomeId biome = sample.biome; TerrainFluidId fluid = TerrainFluidId::none;
    if (query.coordinate.y <= definition_.constants().world_bottom_cell_y + 1) { solid = true; density = std::max(density, cell_size * 4.0); material = TerrainMaterialId::bedrock; biome = TerrainBiomeId::deep_underground; }
    else if (solid) { material = solid_material_for(query.coordinate, sample.surface_y, resolved.center_position.y, surface_biome, density); biome = depth > cell_size * 34.0 ? TerrainBiomeId::deep_underground : depth > cell_size * 3.0 ? TerrainBiomeId::underground : surface_biome; }
    // A generated surface-water cell is necessarily above its surface, which
    // the same water-level classification already identifies as ocean.  A
    // below-surface void needs over three cells before it can be non-solid and
    // therefore cannot enter this at-most-two-cell water branch.
    else if (resolved.center_position.y <= definition_.constants().water_level_meters && depth <= cell_size * 2.0) { material = TerrainMaterialId::water; biome = surface_biome; fluid = TerrainFluidId::water; }
    else if (depth > cell_size * 0.35) { biome = TerrainBiomeId::underground_air; fluid = underground_fluid_for(query.coordinate, resolved.center_position, depth_cells, surface_biome); material = fluid == TerrainFluidId::water ? TerrainMaterialId::water : fluid == TerrainFluidId::lava ? TerrainMaterialId::lava : TerrainMaterialId::air; }
    else biome = surface_biome;
    // A non-solid depth above .35 cell is assigned underground_air before this
    // point; water can retain surface biome only above the surface (depth=0).
    const std::uint8_t sky = solid || biome == TerrainBiomeId::underground_air ? 0 : 15;
    NativeCellStateInput state; state.cell = query.coordinate; state.material = material; state.biome = biome; state.solid = solid; state.density = density; state.fluid = fluid; state.light = {sky, 0}; state.generated = true; state.edited = false;
    return make_native_cell_state(state);
}
} // namespace voxel::world_backend
