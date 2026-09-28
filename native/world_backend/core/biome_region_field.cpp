#include "biome_region_field.hpp"

#include "legacy_seed_hash.hpp"
#include "world_source.hpp"

#include <algorithm>
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
    // Private callers establish Unicode scalar validity before encoding: UTF-8
    // admission decodes only scalars, and validate_admitted_seed checks a
    // supplied canonical vector before returning it. Keeping that proof at the
    // input boundary avoids an untestable duplicate defensive branch here.
    std::string result;
    for (const std::uint32_t code_point : code_points) {
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

double smooth_curve_unit(const double unit) noexcept {
    return unit * unit * (3.0 - 2.0 * unit);
}

double ecotone_smoothstep(const double edge_distance) noexcept {
    // edge_distance is non-negative by construction. The field uses one fixed
    // non-zero ecotone width, so a generic high<=low branch was dead API
    // surface, not field behavior.
    const double unit = std::clamp(edge_distance / BiomeRegionField::ECOTONE_WIDTH_METERS, 0.0, 1.0);
    return smooth_curve_unit(unit);
}

std::int32_t checked_floor_region(const double value) {
    // Public callers reject non-finite coordinates before this conversion.
    // A max-exclusive upper bound makes x0 + 1 representable for lattice
    // sampling and subsumes the former unrepresentable x0 == INT32_MAX guard.
    if (value < static_cast<double>(std::numeric_limits<std::int32_t>::min())
        || value >= static_cast<double>(std::numeric_limits<std::int32_t>::max())) {
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
    for (const std::uint32_t code_point : canonical_code_points) {
        if (!is_unicode_scalar(code_point)) {
            throw std::invalid_argument("biome seed contains an invalid Unicode scalar value");
        }
    }
    const std::vector<std::uint32_t> decoded = decode_utf8(presentation_utf8);
    // Strict UTF-8 decoding and encode_utf8 form a unique canonical spelling,
    // so equality of decoded scalars is the complete presentation contract.
    if (decoded != canonical_code_points) {
        throw std::invalid_argument("biome seed canonical code points and UTF-8 presentation disagree");
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
    // Both terms are unit values and the weights form a convex combination.
    // std::clamp documents/retains the external [0,1] contract without local
    // dead branches in the deterministic field kernel.
    return std::clamp(result, 0.0, 1.0);
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
    // x0/z0 are floors, so each fraction is already in [0, 1).
    const double tx = smooth_curve_unit(point.x - static_cast<double>(x0));
    const double tz = smooth_curve_unit(point.z - static_cast<double>(z0));
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
    const double grid_x_value = world_position.x / REGION_SPACING_METERS;
    const double grid_z_value = world_position.z / REGION_SPACING_METERS;
    // The 3x3 neighborhood needs both predecessor and successor. Express its
    // bounds before conversion instead of retaining impossible float32 equality
    // checks for exact INT32 endpoints.
    if (grid_x_value <= static_cast<double>(std::numeric_limits<std::int32_t>::min())
        || grid_x_value >= static_cast<double>(std::numeric_limits<std::int32_t>::max())
        || grid_z_value <= static_cast<double>(std::numeric_limits<std::int32_t>::min())
        || grid_z_value >= static_cast<double>(std::numeric_limits<std::int32_t>::max())) {
        throw std::invalid_argument("biome sample cannot enumerate a complete 3x3 neighbourhood");
    }
    const std::int32_t grid_x = checked_floor_region(grid_x_value);
    const std::int32_t grid_z = checked_floor_region(grid_z_value);
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
        1.0 - ecotone_smoothstep(edge_distance),
        MINIMUM_CORE_RADIUS_METERS, MINIMUM_CORE_DIAMETER_METERS};
}

BiomeCursor::BiomeCursor() noexcept : stamp{}, status(EvalStatus::idle), reason(EvalReason::none),
    position{}, grid{}, candidate{}, result{}, key{}, values{},
    nearest_distance(std::numeric_limits<double>::infinity()), second_distance(std::numeric_limits<double>::infinity()),
    tx(0), tz(0), lattice{}, stage(0), visit(0), axis(0), channel(0), value_index(0) {}
namespace {
RegionalBiome numeric_biome(const double temperature, const double moisture) noexcept {
    if (temperature < 0.19) return RegionalBiome::snow;
    if (temperature < 0.33) return moisture >= 0.42 ? RegionalBiome::taiga : RegionalBiome::tundra;
    if (moisture > 0.79) return RegionalBiome::swamp;
    if (temperature > 0.70 && moisture < 0.30) return RegionalBiome::desert;
    if (temperature > 0.60 && moisture < 0.49) return RegionalBiome::savanna;
    if (moisture > 0.62) return RegionalBiome::forest;
    return RegionalBiome::plains;
}
bool complete_grid(const BiomeVec2 position) noexcept {
    const double x = position.x / BiomeRegionField::REGION_SPACING_METERS;
    const double z = position.z / BiomeRegionField::REGION_SPACING_METERS;
    return std::isfinite(x) && std::isfinite(z)
        && x > static_cast<double>(std::numeric_limits<std::int32_t>::min())
        && x < static_cast<double>(std::numeric_limits<std::int32_t>::max())
        && z > static_cast<double>(std::numeric_limits<std::int32_t>::min())
        && z < static_cast<double>(std::numeric_limits<std::int32_t>::max());
}
}
EvalStep begin_biome(BiomeCursor &cursor, const EvaluatorStamp stamp,
    const BiomeVec2 position, WorkQuota &quota) noexcept {
    if (cursor.status != EvalStatus::idle && cursor.status != EvalStatus::drained)
        return {EvalStatus::rejected, EvalReason::phase, 0U, 0U};
    if (!complete_grid(position)) return {EvalStatus::rejected, EvalReason::input, 0U, 0U};
    if (!quota.try_debit(1U)) return {EvalStatus::pending, EvalReason::quota, 0U, 1U};
    cursor = BiomeCursor{}; cursor.stamp = stamp; cursor.position = position; cursor.status = EvalStatus::pending;
    return {cursor.status, EvalReason::none, 1U, 1U};
}
BiomeStep advance_biome(BiomeCursor &cursor, const EvaluatorStamp stamp,
    const WorldSourceDefinition &definition, WorkQuota &quota) noexcept {
    // Immutable definition is caller-authenticated, not admitted or copied here.
    if (!(cursor.stamp == stamp) || stamp.definition_digest != definition.physical_content_identity().digest) {
        if (quota.remaining() != 0U) { cursor.status = EvalStatus::rejected; cursor.reason = EvalReason::identity; }
        return {{EvalStatus::rejected, EvalReason::identity, 0U, 0U}, {}};
    }
    if (cursor.status != EvalStatus::pending) return {{cursor.status, cursor.reason, 0U, 0U}, cursor.result};
    const auto before = quota.remaining();
    while (quota.remaining() != 0U && cursor.status == EvalStatus::pending) {
        if (cursor.stage == 2U || cursor.stage == 9U) {
            const auto &seed = definition.admitted_biome_seed().code_points;
            const auto step = advance_seed_key(cursor.key, stamp, {seed.data(), seed.size()}, quota);
            if (step.step.status == EvalStatus::rejected) {
                cursor.status = step.step.status; cursor.reason = step.step.reason; break;
            }
            if (step.step.status != EvalStatus::ready) break;
            cursor.values[cursor.stage == 2U ? cursor.axis : cursor.value_index]
                = static_cast<double>(step.value & 0x7fffffffU) / UNIT_DENOMINATOR;
            ++cursor.stage;
            continue;
        }
        if (cursor.stage == 1U || cursor.stage == 8U) {
            SeedKeyKind kind;
            BiomeRegion coordinate;
            if (cursor.stage == 1U) {
                kind = cursor.axis == 0U ? SeedKeyKind::site_x : SeedKeyKind::site_z;
                coordinate = cursor.candidate;
            } else {
                const bool temperature = cursor.channel == 0U;
                kind = cursor.value_index == 4U
                    ? (temperature ? SeedKeyKind::climate_temperature : SeedKeyKind::climate_moisture)
                    : (temperature ? SeedKeyKind::lattice_temperature : SeedKeyKind::lattice_moisture);
                coordinate = cursor.value_index == 4U ? cursor.result.region : BiomeRegion{
                    cursor.lattice.x + static_cast<std::int32_t>(cursor.value_index % 2U),
                    cursor.lattice.z + static_cast<std::int32_t>(cursor.value_index / 2U)};
            }
            const auto begun = begin_seed_key(cursor.key, stamp, kind, coordinate.x, 0, coordinate.z, quota);
            if (begun.consumed_work == 0U) break;
            ++cursor.stage; continue;
        }
        if (!quota.try_debit(1U)) break;
        switch (cursor.stage) {
        case 0:
            cursor.grid = {static_cast<std::int32_t>(std::floor(cursor.position.x / BiomeRegionField::REGION_SPACING_METERS)),
                static_cast<std::int32_t>(std::floor(cursor.position.z / BiomeRegionField::REGION_SPACING_METERS))};
            cursor.candidate = {cursor.grid.x - 1, cursor.grid.z - 1}; cursor.stage = 1U; break;
        case 3:
            if (cursor.axis == 0U) { cursor.axis = 1U; cursor.stage = 1U; }
            else cursor.stage = 4U;
            break;
        case 4: {
            const float base_x = static_cast<float>((static_cast<double>(cursor.candidate.x) + 0.5) * BiomeRegionField::REGION_SPACING_METERS);
            const float base_z = static_cast<float>((static_cast<double>(cursor.candidate.z) + 0.5) * BiomeRegionField::REGION_SPACING_METERS);
            const float jitter_x = static_cast<float>(-BiomeRegionField::REGION_SITE_JITTER_METERS
                + 2.0 * BiomeRegionField::REGION_SITE_JITTER_METERS * cursor.values[0]);
            const float jitter_z = static_cast<float>(-BiomeRegionField::REGION_SITE_JITTER_METERS
                + 2.0 * BiomeRegionField::REGION_SITE_JITTER_METERS * cursor.values[1]);
            const BiomeVec2 site{base_x + jitter_x, base_z + jitter_z};
            const float dx = cursor.position.x - site.x, dz = cursor.position.z - site.z;
            const float distance = std::sqrt(dx * dx + dz * dz);
            if (distance < cursor.nearest_distance) {
                cursor.second_distance = cursor.nearest_distance; cursor.nearest_distance = distance;
                cursor.result.region = cursor.candidate; cursor.result.site_position = site;
            } else if (distance < cursor.second_distance) cursor.second_distance = distance;
            cursor.stage = 5U; break;
        }
        case 5:
            ++cursor.visit;
            if (cursor.visit == 9U) cursor.stage = 7U;
            else {
                cursor.candidate = {cursor.grid.x - 1 + static_cast<std::int32_t>(cursor.visit % 3U),
                    cursor.grid.z - 1 + static_cast<std::int32_t>(cursor.visit / 3U)};
                cursor.axis = 0U; cursor.stage = 1U;
            }
            break;
        case 7: {
            const BiomeVec2 point{cursor.result.site_position.x / static_cast<float>(BiomeRegionField::CLIMATE_LATTICE_METERS),
                cursor.result.site_position.z / static_cast<float>(BiomeRegionField::CLIMATE_LATTICE_METERS)};
            // Sites in the supported 3x3 grid imply representable lattice floors.
            cursor.lattice = {static_cast<std::int32_t>(std::floor(point.x)), static_cast<std::int32_t>(std::floor(point.z))};
            cursor.tx = smooth_curve_unit(point.x - static_cast<double>(cursor.lattice.x));
            cursor.tz = smooth_curve_unit(point.z - static_cast<double>(cursor.lattice.z));
            cursor.value_index = 0U; cursor.stage = 8U; break;
        }
        case 10:
            if (++cursor.value_index < 5U) cursor.stage = 8U; else cursor.stage = 11U;
            break;
        case 11: {
            const double ab = cursor.values[0] + (cursor.values[1] - cursor.values[0]) * cursor.tx;
            const double cd = cursor.values[2] + (cursor.values[3] - cursor.values[2]) * cursor.tx;
            const double broad = ab + (cd - ab) * cursor.tz;
            const double climate = std::clamp(broad * 0.72 + cursor.values[4] * 0.28, 0.0, 1.0);
            if (cursor.channel == 0U) { cursor.result.temperature = climate; cursor.channel = 1U; cursor.stage = 7U; }
            else { cursor.result.moisture = climate; cursor.stage = 12U; }
            break;
        }
        case 12:
            cursor.result.biome = numeric_biome(cursor.result.temperature, cursor.result.moisture);
            cursor.result.second_distance_meters = cursor.second_distance;
            cursor.result.edge_distance_meters = std::fmax(0.0, (cursor.second_distance - cursor.nearest_distance) * 0.5);
            cursor.result.ecotone_weight = 1.0 - ecotone_smoothstep(cursor.result.edge_distance_meters);
            cursor.status = EvalStatus::ready; break;
        default: cursor.status = EvalStatus::rejected; cursor.reason = EvalReason::phase; break;
        }
    }
    return {{cursor.status, cursor.status == EvalStatus::pending ? EvalReason::quota : cursor.reason,
        before - quota.remaining(), cursor.status == EvalStatus::pending ? 1U : 0U}, cursor.result};
}
ControlResult cancel_biome(BiomeCursor &cursor) noexcept {
    cursor.status = EvalStatus::cancelled; (void)cancel_hash(cursor.key.hash);
    return {cursor.status, EvalReason::none, 1U};
}
ControlResult reset_biome(BiomeCursor &cursor) noexcept {
    if (cursor.status == EvalStatus::pending) return {EvalStatus::rejected, EvalReason::phase, 1U};
    cursor = BiomeCursor{}; return {cursor.status, EvalReason::none, 1U};
}

} // namespace voxel::world_backend
