#include "biome_region_field.hpp"

#include "legacy_seed_hash.hpp"

#include <cmath>
#include <limits>
#include <stdexcept>

namespace voxel::world_backend {
namespace {

constexpr double UNIT_DENOMINATOR = 2147483647.0;

bool is_strip_edge_character(const std::uint32_t value) noexcept {
    // Godot String::strip_edges() is deliberately not a Unicode White_Space
    // normalizer. The engine checks the code point directly and trims only
    // scalar values through U+0020.
    return value <= 0x0020U;
}

std::vector<std::uint32_t> decode_utf8(const std::string &text) {
    if (text.find('\0') != std::string::npos) {
        throw std::invalid_argument("biome seed presentation must not contain NUL");
    }
    std::vector<std::uint32_t> result;
    const auto *bytes = reinterpret_cast<const std::uint8_t *>(text.data());
    for (std::size_t index = 0; index < text.size();) {
        const std::uint8_t first = bytes[index];
        std::uint32_t code_point = 0;
        std::size_t length = 0;
        if (first <= 0x7fU) {
            code_point = first;
            length = 1;
        } else if (first >= 0xc2U && first <= 0xdfU && index + 1U < text.size()
            && (bytes[index + 1U] & 0xc0U) == 0x80U) {
            code_point = (static_cast<std::uint32_t>(first & 0x1fU) << 6U)
                | static_cast<std::uint32_t>(bytes[index + 1U] & 0x3fU);
            length = 2;
        } else if (first >= 0xe0U && first <= 0xefU && index + 2U < text.size()
            && (bytes[index + 1U] & 0xc0U) == 0x80U && (bytes[index + 2U] & 0xc0U) == 0x80U
            && !(first == 0xe0U && bytes[index + 1U] < 0xa0U)
            && !(first == 0xedU && bytes[index + 1U] >= 0xa0U)) {
            code_point = (static_cast<std::uint32_t>(first & 0x0fU) << 12U)
                | (static_cast<std::uint32_t>(bytes[index + 1U] & 0x3fU) << 6U)
                | static_cast<std::uint32_t>(bytes[index + 2U] & 0x3fU);
            length = 3;
        } else if (first >= 0xf0U && first <= 0xf4U && index + 3U < text.size()
            && (bytes[index + 1U] & 0xc0U) == 0x80U && (bytes[index + 2U] & 0xc0U) == 0x80U
            && (bytes[index + 3U] & 0xc0U) == 0x80U
            && !(first == 0xf0U && bytes[index + 1U] < 0x90U)
            && !(first == 0xf4U && bytes[index + 1U] >= 0x90U)) {
            code_point = (static_cast<std::uint32_t>(first & 0x07U) << 18U)
                | (static_cast<std::uint32_t>(bytes[index + 1U] & 0x3fU) << 12U)
                | (static_cast<std::uint32_t>(bytes[index + 2U] & 0x3fU) << 6U)
                | static_cast<std::uint32_t>(bytes[index + 3U] & 0x3fU);
            length = 4;
        } else {
            throw std::invalid_argument("biome seed presentation must be valid UTF-8");
        }
        result.push_back(code_point);
        index += length;
    }
    return result;
}

std::string encode_utf8(const std::vector<std::uint32_t> &code_points) {
    std::string result;
    for (const std::uint32_t code_point : code_points) {
        if (!is_unicode_scalar(code_point)) {
            throw std::invalid_argument("biome seed contains an invalid Unicode scalar value");
        }
        if (code_point <= 0x7fU) result.push_back(static_cast<char>(code_point));
        else if (code_point <= 0x7ffU) {
            result.push_back(static_cast<char>(0xc0U | (code_point >> 6U)));
            result.push_back(static_cast<char>(0x80U | (code_point & 0x3fU)));
        } else if (code_point <= 0xffffU) {
            result.push_back(static_cast<char>(0xe0U | (code_point >> 12U)));
            result.push_back(static_cast<char>(0x80U | ((code_point >> 6U) & 0x3fU)));
            result.push_back(static_cast<char>(0x80U | (code_point & 0x3fU)));
        } else {
            result.push_back(static_cast<char>(0xf0U | (code_point >> 18U)));
            result.push_back(static_cast<char>(0x80U | ((code_point >> 12U) & 0x3fU)));
            result.push_back(static_cast<char>(0x80U | ((code_point >> 6U) & 0x3fU)));
            result.push_back(static_cast<char>(0x80U | (code_point & 0x3fU)));
        }
    }
    return result;
}

std::vector<std::uint32_t> trim_edges(std::vector<std::uint32_t> code_points) {
    std::size_t begin = 0;
    while (begin < code_points.size() && is_strip_edge_character(code_points[begin])) ++begin;
    std::size_t end = code_points.size();
    while (end > begin && is_strip_edge_character(code_points[end - 1U])) --end;
    return {code_points.begin() + static_cast<std::ptrdiff_t>(begin),
        code_points.begin() + static_cast<std::ptrdiff_t>(end)};
}

void append_ascii(std::vector<std::uint32_t> &text, const char *value) {
    for (const char *current = value; *current != '\0'; ++current) {
        text.push_back(static_cast<unsigned char>(*current));
    }
}

void append_i32(std::vector<std::uint32_t> &text, const std::int32_t value) {
    const std::string rendered = std::to_string(value);
    append_ascii(text, rendered.c_str());
}

std::vector<std::uint32_t> compose_site_key(
    const AdmittedBiomeSeed &seed, const char *axis, const BiomeRegion region) {
    std::vector<std::uint32_t> result;
    append_ascii(result, "biome-region-site-");
    append_ascii(result, axis);
    append_ascii(result, ":");
    result.insert(result.end(), seed.code_points.begin(), seed.code_points.end());
    append_ascii(result, ":");
    append_i32(result, region.x);
    append_ascii(result, ",");
    append_i32(result, region.z);
    return result;
}

std::vector<std::uint32_t> compose_climate_key(
    const AdmittedBiomeSeed &seed, const std::string &channel, const BiomeRegion region) {
    std::vector<std::uint32_t> result;
    append_ascii(result, "biome-region-climate:");
    result.insert(result.end(), seed.code_points.begin(), seed.code_points.end());
    append_ascii(result, ":");
    append_ascii(result, channel.c_str());
    append_ascii(result, ":");
    append_i32(result, region.x);
    append_ascii(result, ",");
    append_i32(result, region.z);
    return result;
}

std::vector<std::uint32_t> compose_lattice_key(
    const AdmittedBiomeSeed &seed, const std::string &channel, const std::int32_t x, const std::int32_t z) {
    std::vector<std::uint32_t> result;
    append_ascii(result, "biome-region-lattice:");
    result.insert(result.end(), seed.code_points.begin(), seed.code_points.end());
    append_ascii(result, ":");
    append_ascii(result, channel.c_str());
    append_ascii(result, ":");
    append_i32(result, x);
    append_ascii(result, ",");
    append_i32(result, z);
    return result;
}

double smooth_curve(const double value) noexcept {
    const double clamped = value < 0.0 ? 0.0 : (value > 1.0 ? 1.0 : value);
    return clamped * clamped * (3.0 - 2.0 * clamped);
}

double smoothstep_range(const double value, const double low, const double high) noexcept {
    if (high <= low) return value >= high ? 1.0 : 0.0;
    return smooth_curve((value - low) / (high - low));
}

std::int32_t checked_floor_region(const double value) {
    if (!std::isfinite(value) || value < static_cast<double>(std::numeric_limits<std::int32_t>::min())
        || value > static_cast<double>(std::numeric_limits<std::int32_t>::max())) {
        throw std::invalid_argument("biome world position is outside supported global coordinate range");
    }
    return static_cast<std::int32_t>(std::floor(value));
}

std::int32_t checked_lattice_coordinate(const double value) {
    return checked_floor_region(value);
}

double lattice_unit(const AdmittedBiomeSeed &seed, const std::string &channel, const std::int32_t x, const std::int32_t z) {
    return BiomeRegionField::stable_unit(compose_lattice_key(seed, channel, x, z));
}

} // namespace

bool AdmittedBiomeSeed::operator==(const AdmittedBiomeSeed &other) const noexcept {
    return code_points == other.code_points && utf8 == other.utf8;
}

bool BiomeRegion::operator==(const BiomeRegion &other) const noexcept {
    return x == other.x && z == other.z;
}

bool BiomeVec2::operator==(const BiomeVec2 &other) const noexcept {
    return x == other.x && z == other.z;
}

bool BiomeRegionSample::operator==(const BiomeRegionSample &other) const noexcept {
    return version == other.version && region == other.region && region_id == other.region_id && site_position == other.site_position
        && biome == other.biome && temperature == other.temperature && moisture == other.moisture
        && second_distance_meters == other.second_distance_meters
        && edge_distance_meters == other.edge_distance_meters && ecotone_weight == other.ecotone_weight
        && minimum_core_radius_meters == other.minimum_core_radius_meters
        && minimum_core_diameter_meters == other.minimum_core_diameter_meters;
}

AdmittedBiomeSeed BiomeRegionField::admit_utf8_seed(const std::string &presentation_utf8) {
    std::vector<std::uint32_t> code_points = trim_edges(decode_utf8(presentation_utf8));
    if (code_points.empty()) code_points = {'d', 'e', 'f', 'a', 'u', 'l', 't'};
    return {code_points, encode_utf8(code_points)};
}

AdmittedBiomeSeed BiomeRegionField::validate_admitted_seed(
    const std::vector<std::uint32_t> &canonical_code_points, const std::string &presentation_utf8) {
    if (canonical_code_points.empty()) {
        throw std::invalid_argument("admitted biome seed must not be empty");
    }
    const std::vector<std::uint32_t> decoded = decode_utf8(presentation_utf8);
    if (decoded != canonical_code_points || encode_utf8(canonical_code_points) != presentation_utf8) {
        throw std::invalid_argument("biome seed canonical code points and UTF-8 presentation disagree");
    }
    for (const std::uint32_t code_point : canonical_code_points) {
        if (!is_unicode_scalar(code_point)) {
            throw std::invalid_argument("biome seed contains an invalid Unicode scalar value");
        }
    }
    return {canonical_code_points, presentation_utf8};
}

BiomeVec2 BiomeRegionField::site_position(const AdmittedBiomeSeed &seed, const BiomeRegion region) {
    (void)validate_admitted_seed(seed.code_points, seed.utf8);
    const float base_x = static_cast<float>((static_cast<double>(region.x) + 0.5) * REGION_SPACING_METERS);
    const float base_z = static_cast<float>((static_cast<double>(region.z) + 0.5) * REGION_SPACING_METERS);
    const float x_jitter = static_cast<float>(-REGION_SITE_JITTER_METERS + 2.0 * REGION_SITE_JITTER_METERS
        * stable_unit(compose_site_key(seed, "x", region)));
    const float z_jitter = static_cast<float>(-REGION_SITE_JITTER_METERS + 2.0 * REGION_SITE_JITTER_METERS
        * stable_unit(compose_site_key(seed, "z", region)));
    return {base_x + x_jitter, base_z + z_jitter};
}

std::string BiomeRegionField::region_id(const AdmittedBiomeSeed &seed, const BiomeRegion region) {
    (void)validate_admitted_seed(seed.code_points, seed.utf8);
    return "biome-v" + std::to_string(FIELD_VERSION) + ":" + seed.utf8 + ":"
        + std::to_string(region.x) + "," + std::to_string(region.z);
}

double BiomeRegionField::climate_channel(
    const AdmittedBiomeSeed &seed, const BiomeRegion region, const std::string &channel) {
    (void)validate_admitted_seed(seed.code_points, seed.utf8);
    if (channel.empty()) throw std::invalid_argument("biome climate channel must not be empty");
    const BiomeVec2 site = site_position(seed, region);
    const double broad = value_noise(seed,
        {site.x / static_cast<float>(CLIMATE_LATTICE_METERS),
            site.z / static_cast<float>(CLIMATE_LATTICE_METERS)}, channel + "-broad");
    const double regional = stable_unit(compose_climate_key(seed, channel, region));
    const double result = broad * 0.72 + regional * 0.28;
    return result < 0.0 ? 0.0 : (result > 1.0 ? 1.0 : result);
}

std::string BiomeRegionField::biome_for_climate(const double temperature, const double moisture) {
    if (temperature < 0.19) return "snow";
    if (temperature < 0.33) return moisture >= 0.42 ? "taiga" : "tundra";
    if (moisture > 0.79) return "swamp";
    if (temperature > 0.70 && moisture < 0.30) return "desert";
    if (temperature > 0.60 && moisture < 0.49) return "savanna";
    if (moisture > 0.62) return "forest";
    return "plains";
}

double BiomeRegionField::value_noise(const AdmittedBiomeSeed &seed, const BiomeVec2 point, const std::string &channel) {
    (void)validate_admitted_seed(seed.code_points, seed.utf8);
    if (!std::isfinite(point.x) || !std::isfinite(point.z) || channel.empty()) {
        throw std::invalid_argument("biome value noise requires finite coordinates and a channel");
    }
    const std::int32_t x0 = checked_lattice_coordinate(point.x);
    const std::int32_t z0 = checked_lattice_coordinate(point.z);
    if (x0 == std::numeric_limits<std::int32_t>::max() || z0 == std::numeric_limits<std::int32_t>::max()) {
        throw std::invalid_argument("biome value noise cannot address a lattice successor");
    }
    const double tx = smooth_curve(point.x - static_cast<double>(x0));
    const double tz = smooth_curve(point.z - static_cast<double>(z0));
    const double a = lattice_unit(seed, channel, x0, z0);
    const double b = lattice_unit(seed, channel, x0 + 1, z0);
    const double c = lattice_unit(seed, channel, x0, z0 + 1);
    const double d = lattice_unit(seed, channel, x0 + 1, z0 + 1);
    const double ab = a + (b - a) * tx;
    const double cd = c + (d - c) * tx;
    return ab + (cd - ab) * tz;
}

double BiomeRegionField::stable_unit(const std::vector<std::uint32_t> &text) {
    return static_cast<double>(legacy_seed_hash(text) & 0x7fffffffU) / UNIT_DENOMINATOR;
}

BiomeRegionSample BiomeRegionField::sample(const AdmittedBiomeSeed &seed, const BiomeVec2 world_position) {
    (void)validate_admitted_seed(seed.code_points, seed.utf8);
    if (!std::isfinite(world_position.x) || !std::isfinite(world_position.z)) {
        throw std::invalid_argument("biome sample world position must be finite");
    }
    const std::int32_t grid_x = checked_floor_region(world_position.x / REGION_SPACING_METERS);
    const std::int32_t grid_z = checked_floor_region(world_position.z / REGION_SPACING_METERS);
    if (grid_x == std::numeric_limits<std::int32_t>::min() || grid_x == std::numeric_limits<std::int32_t>::max()
        || grid_z == std::numeric_limits<std::int32_t>::min() || grid_z == std::numeric_limits<std::int32_t>::max()) {
        throw std::invalid_argument("biome sample cannot enumerate a complete 3x3 neighbourhood");
    }
    BiomeRegion nearest_region{};
    BiomeVec2 nearest_site{};
    double nearest_distance = std::numeric_limits<double>::infinity();
    double second_distance = std::numeric_limits<double>::infinity();
    for (std::int32_t region_z = grid_z - 1; region_z <= grid_z + 1; ++region_z) {
        for (std::int32_t region_x = grid_x - 1; region_x <= grid_x + 1; ++region_x) {
            const BiomeRegion candidate{region_x, region_z};
            const BiomeVec2 site = site_position(seed, candidate);
            const float dx = world_position.x - site.x;
            const float dz = world_position.z - site.z;
            const float distance = std::sqrt(dx * dx + dz * dz);
            if (distance < nearest_distance) {
                second_distance = nearest_distance;
                nearest_distance = distance;
                nearest_region = candidate;
                nearest_site = site;
            } else if (distance < second_distance) {
                second_distance = distance;
            }
        }
    }
    const double temperature = climate_channel(seed, nearest_region, "temperature");
    const double moisture = climate_channel(seed, nearest_region, "moisture");
    const double edge_distance = std::fmax(0.0, (second_distance - nearest_distance) * 0.5);
    return {FIELD_VERSION, nearest_region, region_id(seed, nearest_region), nearest_site,
        biome_for_climate(temperature, moisture), temperature, moisture, second_distance, edge_distance,
        1.0 - smoothstep_range(edge_distance, 0.0, ECOTONE_WIDTH_METERS),
        MINIMUM_CORE_RADIUS_METERS, MINIMUM_CORE_DIAMETER_METERS};
}

} // namespace voxel::world_backend
