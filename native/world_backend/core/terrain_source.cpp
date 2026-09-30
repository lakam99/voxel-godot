#include "terrain_source.hpp"

#include "biome_region_field.hpp"
#include "fast_noise_compat.hpp"
#include "native_procedural_cave_field.hpp"

#include <algorithm>
#include <array>
#include <cmath>
#include <cstring>
#include <limits>
#include <map>
#include <set>
#include <sstream>
#include <stdexcept>
#include <tuple>
#include <utility>

namespace voxel::world_backend {
namespace {

constexpr double CELL = 1.35;
constexpr float CELL_F = 1.35F;
constexpr double MIN_HEIGHT = 4.0;
constexpr double MAX_HEIGHT = 120.0;
constexpr double WATER_LEVEL = 11.1;
constexpr std::int32_t WORLD_BOTTOM_CELL_Y = -64;

bool same_region(const CellRegion &left, const CellRegion &right) noexcept {
    return left.minimum == right.minimum && left.maximum_exclusive == right.maximum_exclusive;
}

std::uint32_t fnv_code_points(const std::string &ascii) {
    std::uint32_t value = 2166136261U;
    for (const unsigned char code_point : ascii) value = (value ^ code_point) * 16777619U;
    return value;
}

double stable_unit(const std::string &text) {
    return static_cast<double>(fnv_code_points(text) & 0x7fffffffU) / static_cast<double>(0x7fffffffU);
}

double hash01(const std::string &seed, const std::string &text) {
    return static_cast<double>(fnv_code_points(seed + ":" + text) % 100000U) / 100000.0;
}

double clamp01(const double value) noexcept { return std::clamp(value, 0.0, 1.0); }

double lerp(const double from, const double to, const double weight) noexcept {
    return from + (to - from) * weight;
}

double lattice_position(const std::int32_t coordinate) noexcept {
    return static_cast<double>(coordinate) * CELL;
}

std::int32_t truncating_divide(const std::int32_t value, const std::int32_t divisor) noexcept {
    return value / divisor;
}

std::string coord_text(const CellCoord &cell) {
    return std::to_string(cell.x) + "," + std::to_string(cell.y) + "," + std::to_string(cell.z);
}

struct ColumnKey {
    std::int32_t x;
    std::int32_t z;
    bool operator<(const ColumnKey &other) const noexcept { return std::tie(x, z) < std::tie(other.x, other.z); }
};

struct Vec2 {
    double x;
    double z;
};

double distance(const Vec2 &left, const Vec2 &right) noexcept {
    return std::hypot(left.x - right.x, left.z - right.z);
}

Vec2 biome_site(const std::string &seed, const std::int32_t region_x, const std::int32_t region_z) {
    constexpr double spacing = 6000.0;
    constexpr double jitter = 320.0;
    const std::string suffix = seed + ":" + std::to_string(region_x) + "," + std::to_string(region_z);
    return {
        (static_cast<double>(region_x) + 0.5) * spacing
            + lerp(-jitter, jitter, stable_unit("biome-region-site-x:" + suffix)),
        (static_cast<double>(region_z) + 0.5) * spacing
            + lerp(-jitter, jitter, stable_unit("biome-region-site-z:" + suffix)),
    };
}

double climate_lattice(
    const std::string &seed, const std::string &channel, const std::int32_t x, const std::int32_t z) {
    return stable_unit("biome-region-lattice:" + seed + ":" + channel + ":" + std::to_string(x) + "," + std::to_string(z));
}

double climate_value_noise(const std::string &seed, const Vec2 point, const std::string &channel) {
    const auto x0 = static_cast<std::int32_t>(std::floor(point.x));
    const auto z0 = static_cast<std::int32_t>(std::floor(point.z));
    const double tx = terrain_smoothstep(point.x - x0, 0.0, 1.0);
    const double tz = terrain_smoothstep(point.z - z0, 0.0, 1.0);
    const double a = climate_lattice(seed, channel, x0, z0);
    const double b = climate_lattice(seed, channel, x0 + 1, z0);
    const double c = climate_lattice(seed, channel, x0, z0 + 1);
    const double d = climate_lattice(seed, channel, x0 + 1, z0 + 1);
    return lerp(lerp(a, b, tx), lerp(c, d, tx), tz);
}

double climate_channel(
    const std::string &seed, const std::int32_t region_x, const std::int32_t region_z, const std::string &channel) {
    constexpr double climate_lattice_metres = 18000.0;
    const Vec2 site = biome_site(seed, region_x, region_z);
    const double broad = climate_value_noise(seed, {site.x / climate_lattice_metres, site.z / climate_lattice_metres}, channel + "-broad");
    const double regional = stable_unit("biome-region-climate:" + seed + ":" + channel + ":"
        + std::to_string(region_x) + "," + std::to_string(region_z));
    return clamp01(broad * 0.72 + regional * 0.28);
}

TerrainBiomeId regional_biome(const std::string &seed, const std::int32_t cell_x, const std::int32_t cell_z) {
    constexpr double spacing = 6000.0;
    const Vec2 world_position{lattice_position(cell_x), lattice_position(cell_z)};
    const auto grid_x = static_cast<std::int32_t>(std::floor(world_position.x / spacing));
    const auto grid_z = static_cast<std::int32_t>(std::floor(world_position.z / spacing));
    std::int32_t nearest_x = 0;
    std::int32_t nearest_z = 0;
    double nearest_distance = std::numeric_limits<double>::infinity();
    for (std::int32_t region_z = grid_z - 1; region_z <= grid_z + 1; ++region_z) {
        for (std::int32_t region_x = grid_x - 1; region_x <= grid_x + 1; ++region_x) {
            const double candidate_distance = distance(world_position, biome_site(seed, region_x, region_z));
            if (candidate_distance < nearest_distance) {
                nearest_distance = candidate_distance;
                nearest_x = region_x;
                nearest_z = region_z;
            }
        }
    }
    return terrain_biome_for_climate(
        climate_channel(seed, nearest_x, nearest_z, "temperature"),
        climate_channel(seed, nearest_x, nearest_z, "moisture"));
}

WorldSourceDefinition legacy_cave_definition(const std::string &seed) {
    WorldSourceDescriptor descriptor;
    descriptor.raw_terrain_seed = admit_raw_terrain_seed(seed);
    descriptor.admitted_biome_seed = BiomeRegionField::admit_utf8_seed(seed);
    descriptor.constants.cell_size_meters = CELL;
    descriptor.constants.world_bottom_cell_y = WORLD_BOTTOM_CELL_Y;
    descriptor.constants.water_level_meters = WATER_LEVEL;
    descriptor.constants.minimum_surface_meters = MIN_HEIGHT;
    descriptor.constants.maximum_surface_meters = MAX_HEIGHT;
    return WorldSourceDefinition(std::move(descriptor));
}

class Generator {
public:
    Generator(std::string seed, const std::uint32_t seed_hash)
        : seed_(std::move(seed)), noise_(seed_hash), caves_(legacy_cave_definition(seed_)) {}

    double natural_surface(const std::int32_t x, const std::int32_t z) {
        const ColumnKey key{x, z};
        const auto found = surfaces_.find(key);
        if (found != surfaces_.end()) return found->second;
        const double continent = noise_.sample_2d_01(TerrainNoiseChannel::height, x, z);
        const double broad_hill = noise_.sample_2d_01(TerrainNoiseChannel::height, x + 12000.0, z - 12200.0);
        const double plain_field = noise_.sample_2d_01(TerrainNoiseChannel::flat, x - 8400.0, z + 7200.0);
        const double ridges = std::abs(noise_.sample_2d_01(TerrainNoiseChannel::ridge, x - 200.0, z + 510.0) - 0.5) * 2.0;
        const double flatland_mask = terrain_smoothstep(plain_field, 0.42, 0.68);
        const double mountain_mask = terrain_smoothstep(noise_.sample_2d_01(TerrainNoiseChannel::height, x + 1800.0, z - 1500.0), 0.58, 0.82);
        const double peak_mask = terrain_smoothstep(noise_.sample_2d_01(TerrainNoiseChannel::ridge, x - 3900.0, z + 2600.0), 0.74, 0.93) * mountain_mask;
        const double plains = 6.0 + continent * 10.0 + (broad_hill - 0.5) * 2.0;
        const double hills = 7.2 + continent * 15.5 + std::pow(std::max(broad_hill - 0.18, 0.0), 1.45) * 12.0;
        const double mountains = 10.0 + continent * 21.0 + std::pow(ridges, 1.92) * (16.0 + mountain_mask * 44.0)
            + std::pow(peak_mask, 2.05) * 34.0;
        const double lowland = lerp(hills, plains, flatland_mask);
        const double detail = (noise_.sample_2d_01(TerrainNoiseChannel::ridge, x + 7800.0, z - 9100.0) - 0.5)
            * lerp(0.28, 1.35, mountain_mask);
        const double raw = MIN_HEIGHT + lerp(lowland, mountains, mountain_mask) + detail;
        const double terrace = lerp(CELL * 0.34, CELL * 1.15, mountain_mask);
        const double value = std::clamp(std::round(raw / terrace) * terrace, MIN_HEIGHT, MAX_HEIGHT);
        surfaces_.emplace(key, value);
        return value;
    }

    TerrainBiomeId surface_biome(const std::int32_t x, const std::int32_t z) {
        const ColumnKey key{x, z};
        const auto found = biomes_.find(key);
        if (found != biomes_.end()) return found->second;
        const double height = natural_surface(x, z);
        const TerrainBiomeId value = terrain_surface_biome_for_height(height, regional_biome(seed_, x, z));
        biomes_.emplace(key, value);
        return value;
    }

    TerrainCell generated_cell(const CellCoord &cell, const std::uint64_t revision) {
        // Vector3(cell) * CELL is stored in Godot's single-precision real_t.
        // The divided cell_pos is then stored in another Vector3 (rounding
        // back to the exact integer here), while world_to_cell3 floors the
        // unrounded quotient. Preserve both intentionally distinct paths.
        const double position_x = static_cast<double>(static_cast<float>(cell.x) * CELL_F);
        const double position_y = static_cast<double>(static_cast<float>(cell.y) * CELL_F);
        const double position_z = static_cast<double>(static_cast<float>(cell.z) * CELL_F);
        const CellCoord source_cell{
            static_cast<std::int32_t>(std::floor(position_x / CELL)),
            static_cast<std::int32_t>(std::floor(position_y / CELL)),
            static_cast<std::int32_t>(std::floor(position_z / CELL)),
        };
        const double density_surface_y = natural_surface(source_cell.x, source_cell.z);
        // Both public surface queries map the float-rounded lattice position
        // back through volume_cell3_from_world before resolving the column.
        // On negative coordinates that floor may select the preceding cell.
        const double reported_surface_y = density_surface_y;
        double density = density_surface_y - position_y;
        const double depth = std::max(0.0, density_surface_y - position_y);
        const double depth_cells = depth / CELL;
        if (density > -CELL * 16.0) {
            double cave = CELL;
            if (position_y > static_cast<double>(WORLD_BOTTOM_CELL_Y + 2) * CELL) {
                const CaveVector3 position{static_cast<float>(position_x),
                    static_cast<float>(position_y), static_cast<float>(position_z)};
                const NativeProceduralCaveField::SurfaceSampler surface = [this](
                    const float x, const float z) {
                    const auto cell_x = static_cast<std::int32_t>(std::floor(
                        static_cast<double>(x) / CELL));
                    const auto cell_z = static_cast<std::int32_t>(std::floor(
                        static_cast<double>(z) / CELL));
                    return natural_surface(cell_x, cell_z);
                };
                const NativeProceduralCaveField::ProtectedBounds unprotected =
                    [](const CaveBounds &) { return false; };
                cave = caves_.density(position, depth, surface, unprotected);
            }
            density = std::min(density, cave);
        }
        density = terrain_apply_world_floor_density(position_y, density);
        const bool solid = density >= 0.0;
        const TerrainBiomeId surface_biome_value = surface_biome(cell.x, cell.z);
        TerrainBiomeId resolved_biome = surface_biome_value;
        if (!solid) {
            if (density_surface_y - position_y > CELL * 0.35) resolved_biome = TerrainBiomeId::underground_air;
        } else if (depth_cells > 3.0) {
            resolved_biome = TerrainBiomeId::underground;
        }
        const TerrainMaterialId material = terrain_solid_material(
            seed_, cell, density_surface_y, position_y, surface_biome_value, density);
        return {cell, density, reported_surface_y, solid, material, surface_biome_value, resolved_biome,
            TerrainFluidId::none, TerrainProvenanceKind::generated, "generator:" + seed_, revision};
    }

private:
    std::string seed_;
    FastNoiseCompat noise_;
    NativeProceduralCaveField caves_;
    std::map<ColumnKey, double> surfaces_;
    std::map<ColumnKey, TerrainBiomeId> biomes_;
};

bool valid_material(const TerrainMaterialId value) noexcept {
    return static_cast<std::uint8_t>(value) <= static_cast<std::uint8_t>(TerrainMaterialId::lava);
}
bool valid_biome(const TerrainBiomeId value) noexcept {
    return static_cast<std::uint8_t>(value) <= static_cast<std::uint8_t>(TerrainBiomeId::alpine);
}
bool valid_fluid(const TerrainFluidId value) noexcept {
    return value == TerrainFluidId::none || value == TerrainFluidId::water || value == TerrainFluidId::lava;
}

void validate_delta(const TerrainDelta &delta) {
    if (delta.id.empty() || delta.id.find('\0') != std::string::npos || delta.revision == 0U) {
        throw std::invalid_argument("terrain delta requires a nonempty ID and nonzero revision");
    }
    if (!std::isfinite(delta.state.density) || delta.state.solid != (delta.state.density >= 0.0)) {
        throw std::invalid_argument("terrain delta has invalid density/solidity");
    }
    if (!valid_material(delta.state.material) || !valid_biome(delta.state.resolved_biome) || !valid_fluid(delta.state.fluid)) {
        throw std::invalid_argument("terrain delta contains an unknown typed value");
    }
    if (!delta.state.solid && delta.state.material != TerrainMaterialId::air && delta.state.material != TerrainMaterialId::water
        && delta.state.material != TerrainMaterialId::lava) {
        throw std::invalid_argument("nonsolid terrain delta has a solid material");
    }
    if (delta.state.solid && delta.state.material == TerrainMaterialId::air) {
        throw std::invalid_argument("solid terrain delta has air material");
    }
    if (delta.state.fluid == TerrainFluidId::water && delta.state.material != TerrainMaterialId::water) {
        throw std::invalid_argument("water terrain delta requires water material");
    }
    if (delta.state.fluid == TerrainFluidId::lava && delta.state.material != TerrainMaterialId::lava) {
        throw std::invalid_argument("lava terrain delta requires lava material");
    }
}

bool delta_less(const TerrainDelta &left, const TerrainDelta &right) noexcept {
    return std::tie(left.coordinate.y, left.coordinate.z, left.coordinate.x, left.id)
        < std::tie(right.coordinate.y, right.coordinate.z, right.coordinate.x, right.id);
}

class DeltaWriter {
public:
    void u8(const std::uint8_t value) { bytes.push_back(value); }
    void u32(const std::uint32_t value) { for (unsigned shift = 0; shift < 32U; shift += 8U) u8(static_cast<std::uint8_t>(value >> shift)); }
    void i32(const std::int32_t value) { u32(static_cast<std::uint32_t>(value)); }
    void u64(const std::uint64_t value) { for (unsigned shift = 0; shift < 64U; shift += 8U) u8(static_cast<std::uint8_t>(value >> shift)); }
    void f64(const double value) { std::uint64_t bits; std::memcpy(&bits, &value, sizeof(bits)); u64(bits); }
    void text(const std::string &value) {
        u32(canonical_u32_length(value.size())); bytes.insert(bytes.end(), value.begin(), value.end());
    }
    std::vector<std::uint8_t> bytes;
};

class DeltaReader {
public:
    explicit DeltaReader(const std::vector<std::uint8_t> &source) : source_(source) {}
    std::uint8_t u8() { require(1); return source_[offset_++]; }
    std::uint32_t u32() { std::uint32_t value = 0; for (unsigned shift = 0; shift < 32U; shift += 8U) value |= static_cast<std::uint32_t>(u8()) << shift; return value; }
    std::int32_t i32() { return static_cast<std::int32_t>(u32()); }
    std::uint64_t u64() { std::uint64_t value = 0; for (unsigned shift = 0; shift < 64U; shift += 8U) value |= static_cast<std::uint64_t>(u8()) << shift; return value; }
    double f64() { const std::uint64_t bits = u64(); double value; std::memcpy(&value, &bits, sizeof(value)); return value; }
    std::string text() { const std::uint32_t size = u32(); require(size); std::string value(source_.begin() + offset_, source_.begin() + offset_ + size); offset_ += size; return value; }
    void magic(const char (&expected)[5]) { for (std::size_t i = 0; i < 4; ++i) if (u8() != static_cast<std::uint8_t>(expected[i])) throw std::invalid_argument("terrain delta magic mismatch"); }
    bool done() const noexcept { return offset_ == source_.size(); }
private:
    void require(const std::size_t size) { if (size > source_.size() - std::min(offset_, source_.size())) throw std::invalid_argument("terrain delta payload is truncated"); }
    const std::vector<std::uint8_t> &source_;
    std::size_t offset_ = 0;
};

const char *decision_text(const AuthorityDecision decision) noexcept {
    if (decision == AuthorityDecision::accept) return "accept";
    if (decision == AuthorityDecision::wrong_world) return "wrong world";
    if (decision == AuthorityDecision::stale_owner) return "stale owner";
    if (decision == AuthorityDecision::cancelled) return "cancelled";
    if (decision == AuthorityDecision::stale_source) return "stale source";
    return "unknown authority decision";
}

} // namespace

double terrain_smoothstep(const double value, const double low, const double high) noexcept {
    if (high <= low) return value >= high ? 1.0 : 0.0;
    const double t = clamp01((value - low) / (high - low));
    return t * t * (3.0 - 2.0 * t);
}

TerrainBiomeId terrain_biome_for_climate(const double temperature, const double moisture) noexcept {
    if (temperature < 0.19) return TerrainBiomeId::snow;
    if (temperature < 0.33) return moisture >= 0.42 ? TerrainBiomeId::taiga : TerrainBiomeId::tundra;
    if (moisture > 0.79) return TerrainBiomeId::swamp;
    if (temperature > 0.70 && moisture < 0.30) return TerrainBiomeId::desert;
    if (temperature > 0.60 && moisture < 0.49) return TerrainBiomeId::savanna;
    if (moisture > 0.62) return TerrainBiomeId::forest;
    return TerrainBiomeId::plains;
}

TerrainBiomeId terrain_surface_biome_for_height(
    const double height, const TerrainBiomeId regional_biome_value) noexcept {
    if (height < WATER_LEVEL + 0.3) return TerrainBiomeId::ocean;
    if (height < WATER_LEVEL + 1.7) return TerrainBiomeId::beach;
    return regional_biome_value;
}

double terrain_apply_world_floor_density(const double position_y, const double density) noexcept {
    if (density > 0.0 && position_y <= static_cast<double>(WORLD_BOTTOM_CELL_Y) * CELL) {
        return std::max(density, CELL * 4.0);
    }
    return density;
}

double terrain_apply_underground_floor_density(const double position_y, const double density) noexcept {
    if (position_y <= static_cast<double>(WORLD_BOTTOM_CELL_Y + 2) * CELL) return CELL;
    return density;
}

TerrainMaterialId terrain_solid_material(
    const std::string &seed,
    const CellCoord &cell,
    const double surface_y,
    const double position_y,
    const TerrainBiomeId biome,
    const double density) {
    if (density < 0.0) return TerrainMaterialId::air;
    if (cell.y <= WORLD_BOTTOM_CELL_Y + 1) return TerrainMaterialId::bedrock;
    const double depth = std::max(0.0, surface_y - position_y);
    if (depth <= CELL * 1.20) {
        if (biome == TerrainBiomeId::beach || biome == TerrainBiomeId::desert) return TerrainMaterialId::sand;
        if (biome == TerrainBiomeId::swamp) return TerrainMaterialId::mud;
        if (biome == TerrainBiomeId::snow) return TerrainMaterialId::snow;
        if (biome == TerrainBiomeId::tundra) return TerrainMaterialId::stone;
        return TerrainMaterialId::grass;
    }
    if (depth <= CELL * 4.65) {
        if (biome == TerrainBiomeId::beach || biome == TerrainBiomeId::desert) return TerrainMaterialId::sand;
        if (biome == TerrainBiomeId::swamp) return TerrainMaterialId::mud;
        if (biome == TerrainBiomeId::snow) return TerrainMaterialId::snow;
        return TerrainMaterialId::dirt;
    }
    const double depth_cells = depth / CELL;
    const CellCoord copper_cell{truncating_divide(cell.x, 3), truncating_divide(cell.y, 3), truncating_divide(cell.z, 3)};
    const double copper = hash01(seed, "subsurface-copper:" + seed + ":" + coord_text(copper_cell));
    if (depth_cells >= 8.0 && copper > 0.985) return TerrainMaterialId::copper_ore;
    const CellCoord iron_cell{truncating_divide(cell.x, 4), truncating_divide(cell.y, 4), truncating_divide(cell.z, 4)};
    const double iron = hash01(seed, "subsurface-iron:" + seed + ":" + coord_text(iron_cell));
    if (depth_cells >= 15.0 && iron > 0.992) return TerrainMaterialId::iron_ore;
    if (depth > CELL * 38.0) return TerrainMaterialId::deep_stone;
    return TerrainMaterialId::stone;
}

bool TerrainDeltaState::operator==(const TerrainDeltaState &other) const noexcept {
    return density == other.density && solid == other.solid && material == other.material
        && resolved_biome == other.resolved_biome && fluid == other.fluid;
}

bool TerrainDelta::operator==(const TerrainDelta &other) const noexcept {
    return id == other.id && revision == other.revision && coordinate == other.coordinate && state == other.state;
}

std::vector<std::uint8_t> serialize_terrain_deltas(const std::vector<TerrainDelta> &input) {
    std::vector<TerrainDelta> deltas = input;
    for (const TerrainDelta &delta : deltas) validate_delta(delta);
    std::sort(deltas.begin(), deltas.end(), delta_less);
    std::set<std::string> ids;
    for (std::size_t index = 1; index < deltas.size(); ++index) {
        if (deltas[index - 1U].coordinate == deltas[index].coordinate) throw std::invalid_argument("duplicate terrain delta coordinate");
    }
    for (const TerrainDelta &delta : deltas) {
        if (!ids.insert(delta.id).second) throw std::invalid_argument("duplicate terrain delta ID");
    }
    DeltaWriter writer;
    writer.u8('V'); writer.u8('T'); writer.u8('D'); writer.u8('L');
    writer.u32(1U);
    writer.u32(canonical_u32_length(deltas.size()));
    for (const TerrainDelta &delta : deltas) {
        writer.text(delta.id); writer.u64(delta.revision);
        writer.i32(delta.coordinate.x); writer.i32(delta.coordinate.y); writer.i32(delta.coordinate.z);
        writer.f64(delta.state.density); writer.u8(delta.state.solid ? 1U : 0U);
        writer.u8(static_cast<std::uint8_t>(delta.state.material));
        writer.u8(static_cast<std::uint8_t>(delta.state.resolved_biome));
        writer.u8(static_cast<std::uint8_t>(delta.state.fluid));
    }
    return std::move(writer.bytes);
}

std::vector<TerrainDelta> deserialize_terrain_deltas(const std::vector<std::uint8_t> &bytes) {
    DeltaReader reader(bytes);
    reader.magic("VTDL");
    if (reader.u32() != 1U) throw std::invalid_argument("unsupported terrain delta schema");
    const std::uint32_t count = reader.u32();
    if (count > 1000000U) throw std::invalid_argument("terrain delta count exceeds safety bound");
    std::vector<TerrainDelta> deltas;
    deltas.reserve(count);
    for (std::uint32_t index = 0; index < count; ++index) {
        TerrainDelta delta;
        delta.id = reader.text(); delta.revision = reader.u64();
        delta.coordinate = {reader.i32(), reader.i32(), reader.i32()};
        delta.state.density = reader.f64();
        const std::uint8_t solid = reader.u8();
        if (solid > 1U) throw std::invalid_argument("terrain delta has invalid bool encoding");
        delta.state.solid = solid != 0U;
        delta.state.material = static_cast<TerrainMaterialId>(reader.u8());
        delta.state.resolved_biome = static_cast<TerrainBiomeId>(reader.u8());
        delta.state.fluid = static_cast<TerrainFluidId>(reader.u8());
        validate_delta(delta);
        deltas.push_back(std::move(delta));
    }
    if (!reader.done()) throw std::invalid_argument("terrain delta payload has trailing bytes");
    const auto canonical = serialize_terrain_deltas(deltas);
    if (canonical != bytes) throw std::invalid_argument("terrain delta payload is not canonical");
    std::sort(deltas.begin(), deltas.end(), delta_less);
    return deltas;
}

TerrainSourceRejected::TerrainSourceRejected(const AuthorityDecision decision)
    : std::runtime_error(std::string("terrain source authority rejected: ") + decision_text(decision)), decision_(decision) {}
AuthorityDecision TerrainSourceRejected::decision() const noexcept { return decision_; }

CellRegion n2_combined_sample_region() noexcept { return {{-49, -17, -17}, {-14, 34, 2}}; }

DeclaredFeatureBlocker n2_declared_feature_blocker() {
    return {"n2:blocker:tile-b:-24,-10", {-32.4, 16.497000000000003, -13.5}, {1.35, 2.7, 1.35},
        "fixture_obstacle", "blocker"};
}

std::vector<std::uint32_t> atlas_1492_code_points() {
    return {'a', 't', 'l', 'a', 's', '-', '1', '4', '9', '2'};
}

TerrainSourceRequest n2_terrain_source_request(
    const RequestAuthority &authority,
    std::string transaction_id,
    std::vector<TerrainDelta> deltas) {
    return {"atlas-1492", atlas_1492_code_points(), authority, std::move(transaction_id),
        n2_combined_sample_region(), std::move(deltas), {n2_declared_feature_blocker()}};
}

TerrainSnapshot build_terrain_snapshot(
    const TerrainSourceRequest &request,
    const RequestAuthority &current_authority) {
    const AuthorityDecision decision = validate_result_authority(request.authority, current_authority);
    if (decision != AuthorityDecision::accept) throw TerrainSourceRejected(decision);
    if (request.seed_text != "atlas-1492" || request.seed_code_points != atlas_1492_code_points()) {
        throw std::invalid_argument("N2 terrain source accepts only the frozen atlas-1492 seed");
    }
    if (!same_region(request.sample_region, n2_combined_sample_region())) {
        throw std::invalid_argument("N2 terrain source accepts only the frozen combined sample region");
    }
    const DeclaredFeatureBlocker expected_blocker = n2_declared_feature_blocker();
    if (request.blockers.size() != 1U || !(request.blockers.front() == expected_blocker)) {
        throw std::invalid_argument("N2 terrain source requires its frozen declared feature blocker");
    }
    std::map<std::tuple<std::int32_t, std::int32_t, std::int32_t>, TerrainDelta> deltas;
    std::set<std::string> delta_ids;
    for (const TerrainDelta &delta : request.deltas) {
        validate_delta(delta);
        if (!delta_ids.insert(delta.id).second) throw std::invalid_argument("duplicate terrain delta ID");
        const auto key = std::make_tuple(delta.coordinate.x, delta.coordinate.y, delta.coordinate.z);
        if (!deltas.emplace(key, delta).second) throw std::invalid_argument("duplicate terrain delta coordinate");
        const CellRegion region = request.sample_region;
        if (delta.coordinate.x < region.minimum.x || delta.coordinate.x >= region.maximum_exclusive.x
            || delta.coordinate.y < region.minimum.y || delta.coordinate.y >= region.maximum_exclusive.y
            || delta.coordinate.z < region.minimum.z || delta.coordinate.z >= region.maximum_exclusive.z) {
            throw std::invalid_argument("terrain delta lies outside the snapshot region");
        }
    }
    Generator generator(request.seed_text, 1769472797U);
    std::vector<TerrainCell> cells;
    cells.reserve(33915U);
    for (std::int32_t y = request.sample_region.minimum.y; y < request.sample_region.maximum_exclusive.y; ++y) {
        for (std::int32_t z = request.sample_region.minimum.z; z < request.sample_region.maximum_exclusive.z; ++z) {
            for (std::int32_t x = request.sample_region.minimum.x; x < request.sample_region.maximum_exclusive.x; ++x) {
                const CellCoord coordinate{x, y, z};
                TerrainCell cell = generator.generated_cell(coordinate, request.authority.source_revision.value);
                const auto found = deltas.find(std::make_tuple(x, y, z));
                if (found != deltas.end()) {
                    const TerrainDelta &delta = found->second;
                    cell.density = delta.state.density;
                    cell.solid = delta.state.solid;
                    cell.material = delta.state.material;
                    cell.resolved_biome = delta.state.resolved_biome;
                    cell.fluid = delta.state.fluid;
                    cell.provenance = TerrainProvenanceKind::typed_delta;
                    cell.provenance_id = delta.id;
                    cell.provenance_revision = delta.revision;
                }
                cells.push_back(std::move(cell));
            }
        }
    }
    return TerrainSnapshot::create(
        {request.authority, request.transaction_id, request.sample_region, TerrainSnapshotDescriptor::SCHEMA},
        std::move(cells), request.blockers);
}

} // namespace voxel::world_backend
