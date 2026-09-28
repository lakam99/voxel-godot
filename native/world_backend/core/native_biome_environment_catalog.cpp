#include "native_biome_environment_catalog.hpp"

#include "native_value.hpp"

#include <algorithm>
#include <array>
#include <cmath>
#include <utility>

namespace voxel::world_backend {
namespace {

constexpr std::array<const char *, NativeBiomeEnvironmentCatalog::PROFILE_COUNT> EXPECTED_IDS{
    "alpine", "beach", "default", "desert", "forest", "ocean", "plains",
    "savanna", "snow", "swamp", "taiga", "town", "tundra"};

[[noreturn]] void reject() { throw NativeBiomeEnvironmentCatalogRejected(); }
bool finite(double value) noexcept { return std::isfinite(value); }
bool nonnegative(double value) noexcept { return finite(value) && value >= 0.0; }
bool unit(double value) noexcept { return finite(value) && value >= 0.0 && value <= 1.0; }

void validate_text(const std::string &value, bool nonempty = true) {
    if (nonempty && value.empty()) reject();
    try { static_cast<void>(NativeValue::string(value)); }
    catch (const NativeValueRejected &) { reject(); }
}

void validate_profile(const NativeBiomeEnvironmentProfile &p) {
    validate_text(p.biome_id);
    validate_text(p.forage_material);
    validate_text(p.forage_drop);
    validate_text(p.tree_architecture);
    if (p.tree_families.empty() || p.tree_families.size() > 64U
        || p.rock_families.empty() || p.rock_families.size() > 64U) reject();
    for (const auto &s : p.tree_families) validate_text(s);
    for (const auto &s : p.rock_families) validate_text(s);
    if (p.detail_types.empty() || p.detail_types.size() > 64U
        || p.detail_thresholds.size() != p.detail_types.size()
        || p.detail_y_offsets.size() != p.detail_types.size()
        || p.detail_scale_mins.size() != p.detail_types.size()
        || p.detail_scale_maxs.size() != p.detail_types.size()) reject();
    for (const auto &s : p.detail_types) validate_text(s, false);
    float previous = 0.0F;
    for (std::size_t i = 0; i < p.detail_types.size(); ++i) {
        const float threshold = p.detail_thresholds[i];
        if (!finite(threshold) || threshold <= previous || threshold > 1.0F
            || !finite(p.detail_y_offsets[i]) || !finite(p.detail_scale_mins[i])
            || !finite(p.detail_scale_maxs[i])
            || p.detail_scale_mins[i] > p.detail_scale_maxs[i]) reject();
        previous = threshold;
    }
    if (previous != 1.0F) reject();
    if (p.forage_drop_min < 0 || p.forage_drop_max < p.forage_drop_min) reject();
    if (!nonnegative(p.tree_scale) || !nonnegative(p.rock_scale) || !nonnegative(p.forage_radius)
        || !unit(p.tree_chance) || !unit(p.rock_base_chance)
        || !unit(p.forage_chance) || !unit(p.wildlife_chance)
        || !unit(p.weather_precip) || !unit(p.weather_clouds)
        || !nonnegative(p.detail_max_height_above_water)
        || !nonnegative(p.tree_height_min) || !finite(p.tree_height_max)
        || p.tree_height_min > p.tree_height_max
        || !nonnegative(p.crown_radius_min) || !finite(p.crown_radius_max)
        || p.crown_radius_min > p.crown_radius_max
        || !nonnegative(p.trunk_radius_min) || !finite(p.trunk_radius_max)
        || p.trunk_radius_min > p.trunk_radius_max
        || !unit(p.old_growth_chance) || !nonnegative(p.wind_response)
        || !nonnegative(p.canopy_density) || !nonnegative(p.natural_prop_exclusion_margin)
        || !nonnegative(p.tree_visibility_range) || !nonnegative(p.tree_shadow_range)
        || !nonnegative(p.tree_age_min_years) || !finite(p.tree_age_typical_years)
        || !finite(p.tree_age_max_years)
        || p.tree_age_min_years > p.tree_age_typical_years
        || p.tree_age_typical_years > p.tree_age_max_years
        || !finite(p.tree_maturity_cell_scale) || p.tree_maturity_cell_scale < 8.0
        || !unit(p.tree_maturity_influence)
        || !unit(p.tree_local_age_span) || p.tree_local_age_span < 0.05
        || !finite(p.tree_age_distribution_skew)
        || p.tree_age_distribution_skew < 0.2 || p.tree_age_distribution_skew > 3.0
        || !finite(p.tree_height_growth_exponent) || p.tree_height_growth_exponent < 0.25
        || p.tree_height_growth_exponent > 2.0
        || !finite(p.tree_girth_growth_exponent) || p.tree_girth_growth_exponent < 0.25
        || p.tree_girth_growth_exponent > 2.0
        || !finite(p.tree_crown_growth_exponent) || p.tree_crown_growth_exponent < 0.25
        || p.tree_crown_growth_exponent > 2.0) reject();
    if (p.tree_architecture != "broadleaf" && p.tree_architecture != "conifer"
        && p.tree_architecture != "savanna") reject();
    float previous_age = 0.0F;
    for (const float threshold : p.tree_age_band_thresholds) {
        if (!finite(threshold) || threshold <= previous_age || threshold >= 1.0F) reject();
        previous_age = threshold;
    }
}

NativeValue strings(const std::vector<std::string> &values) {
    NativeValue::Array result;
    result.reserve(values.size());
    for (const auto &value : values) result.push_back(NativeValue::string(value));
    return NativeValue::array(std::move(result));
}
NativeValue numbers(const std::vector<float> &values) {
    NativeValue::Array result;
    result.reserve(values.size());
    for (const float value : values) result.push_back(NativeValue::number(static_cast<double>(value)));
    return NativeValue::array(std::move(result));
}
NativeValue age_bands(const std::array<float, 4> &values) {
    return numbers(std::vector<float>(values.begin(), values.end()));
}

NativeValue object(NativeValue::Object fields) {
    std::sort(fields.begin(), fields.end(), [](const auto &a, const auto &b) { return a.first < b.first; });
    return NativeValue::object(std::move(fields));
}

NativeValue semantic_profile(const NativeBiomeEnvironmentProfile &p) {
    NativeValue::Object fields;
    fields.reserve(51U);
#define TEXT(name) fields.emplace_back(#name, NativeValue::string(p.name))
#define NUM(name) fields.emplace_back(#name, NativeValue::number(p.name))
#define BOOL(name) fields.emplace_back(#name, NativeValue::boolean(p.name))
#define STRINGS(name) fields.emplace_back(#name, strings(p.name))
#define NUMBERS(name) fields.emplace_back(#name, numbers(p.name))
    TEXT(biome_id); STRINGS(tree_families); STRINGS(rock_families);
    NUM(tree_scale); NUM(rock_scale); NUM(tree_chance); NUM(rock_base_chance);
    NUM(forage_chance); NUM(wildlife_chance); TEXT(forage_material); TEXT(forage_drop);
    NUM(forage_drop_min); NUM(forage_drop_max); NUM(forage_radius);
    NUM(weather_precip); NUM(weather_clouds); BOOL(cold_weather);
    STRINGS(detail_types); NUMBERS(detail_thresholds); NUMBERS(detail_y_offsets);
    NUMBERS(detail_scale_mins); NUMBERS(detail_scale_maxs); NUM(detail_max_height_above_water);
    NUM(tree_height_min); NUM(tree_height_max); NUM(crown_radius_min); NUM(crown_radius_max);
    NUM(trunk_radius_min); NUM(trunk_radius_max); NUM(old_growth_chance); NUM(wind_response);
    NUM(canopy_density); NUM(natural_prop_exclusion_margin); NUM(tree_visibility_range);
    NUM(tree_shadow_range); TEXT(tree_architecture); NUM(tree_age_min_years);
    NUM(tree_age_typical_years); NUM(tree_age_max_years); NUM(tree_maturity_cell_scale);
    NUM(tree_maturity_influence); NUM(tree_local_age_span); NUM(tree_age_distribution_skew);
    fields.emplace_back("tree_age_band_thresholds", age_bands(p.tree_age_band_thresholds));
    NUM(tree_height_growth_exponent); NUM(tree_girth_growth_exponent); NUM(tree_crown_growth_exponent);
#undef TEXT
#undef NUM
#undef BOOL
#undef STRINGS
#undef NUMBERS
    return object(std::move(fields));
}

Sha256Digest domain_hash(const char *domain, const NativeValue &value) {
    const NativeValue wrapped = object({{"domain", NativeValue::string(domain)},
        {"schema_revision", NativeValue::number(NativeBiomeEnvironmentCatalog::SCHEMA_REVISION)},
        {"value", value}});
    return sha256(wrapped.canonical_binary());
}

} // namespace

NativeBiomeEnvironmentCatalogRejected::NativeBiomeEnvironmentCatalogRejected()
    : std::invalid_argument("invalid native resolved biome-environment catalog") {}

NativeBiomeEnvironmentCatalog::NativeBiomeEnvironmentCatalog(
    std::vector<NativeBiomeEnvironmentProfile> profiles, std::string fallback_id,
    std::vector<Sha256Digest> profile_digests, std::vector<std::uint8_t> canonical_binary,
    Sha256Digest content_digest) noexcept
    : profiles_(std::move(profiles)), fallback_id_(std::move(fallback_id)),
      profile_digests_(std::move(profile_digests)), canonical_binary_(std::move(canonical_binary)),
      content_digest_(content_digest) {}

NativeBiomeEnvironmentCatalog NativeBiomeEnvironmentCatalog::create(
    std::vector<NativeBiomeEnvironmentProfile> profiles, std::string fallback_id) {
    validate_text(fallback_id);
    if (profiles.size() != PROFILE_COUNT || fallback_id != "default") reject();
    std::sort(profiles.begin(), profiles.end(), [](const auto &a, const auto &b) {
        return a.biome_id < b.biome_id;
    });
    for (std::size_t i = 0U; i < PROFILE_COUNT; ++i) {
        if (profiles[i].biome_id != EXPECTED_IDS[i]) reject();
        validate_profile(profiles[i]);
    }
    NativeValue::Array rows;
    std::vector<Sha256Digest> profile_digests;
    rows.reserve(PROFILE_COUNT);
    profile_digests.reserve(PROFILE_COUNT);
    for (const auto &profile : profiles) {
        NativeValue row = semantic_profile(profile);
        profile_digests.push_back(domain_hash("resolved_biome_environment_profile/v1", row));
        rows.push_back(std::move(row));
    }
    const NativeValue value = object({
        {"domain", NativeValue::string("resolved_biome_environment_catalog/v1")},
        {"fallback_id", NativeValue::string(fallback_id)},
        {"profiles", NativeValue::array(std::move(rows))},
        {"schema_revision", NativeValue::number(SCHEMA_REVISION)}});
    auto binary = value.canonical_binary();
    const auto digest = sha256(binary);
    return NativeBiomeEnvironmentCatalog(std::move(profiles), std::move(fallback_id),
        std::move(profile_digests), std::move(binary), digest);
}

const NativeBiomeEnvironmentProfile &NativeBiomeEnvironmentCatalog::profile_for_biome(
    const std::string &biome_id) const noexcept {
    const auto it = std::lower_bound(profiles_.begin(), profiles_.end(), biome_id,
        [](const auto &profile, const std::string &id) { return profile.biome_id < id; });
    return it != profiles_.end() && it->biome_id == biome_id ? *it : profiles_[2U];
}
const std::vector<NativeBiomeEnvironmentProfile> &NativeBiomeEnvironmentCatalog::profiles() const noexcept {
    return profiles_;
}
const std::string &NativeBiomeEnvironmentCatalog::fallback_id() const noexcept { return fallback_id_; }
const Sha256Digest &NativeBiomeEnvironmentCatalog::content_digest() const noexcept { return content_digest_; }
const Sha256Digest &NativeBiomeEnvironmentCatalog::profile_digest(const std::string &biome_id) const noexcept {
    const auto it = std::lower_bound(profiles_.begin(), profiles_.end(), biome_id,
        [](const auto &profile, const std::string &id) { return profile.biome_id < id; });
    const auto index = it != profiles_.end() && it->biome_id == biome_id
        ? static_cast<std::size_t>(it - profiles_.begin()) : 2U;
    return profile_digests_[index];
}
const std::vector<std::uint8_t> &NativeBiomeEnvironmentCatalog::canonical_binary() const noexcept {
    return canonical_binary_;
}

} // namespace voxel::world_backend
