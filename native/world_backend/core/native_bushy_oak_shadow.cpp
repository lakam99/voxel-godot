#include "native_bushy_oak_shadow.hpp"

#include "godot_pcg_compat.hpp"
#include "native_tree_worker_text_admission.hpp"

#include <algorithm>
#include <cctype>
#include <cmath>
#include <cstdio>
#include <vector>

namespace voxel::world_backend {
namespace {

constexpr double TAU = 6.28318530717958647692;

[[noreturn]] void reject() { throw NativeBushyOakShadowRejected(); }

double clamp(const double value, const double low, const double high) {
    return std::clamp(value, low, high);
}
int clampi(const int value, const int low, const int high) {
    return std::clamp(value, low, high);
}
double lerpf(const double from, const double to, const double weight) {
    return from + (to - from) * weight;
}
int roundi(const double value) {
    return static_cast<int>(std::round(value));
}

std::string trim_ascii(const std::string &source) {
    std::size_t first = 0U;
    std::size_t last = source.size();
    while (first < last && std::isspace(static_cast<unsigned char>(source[first]))) ++first;
    while (last > first && std::isspace(static_cast<unsigned char>(source[last - 1U]))) --last;
    return source.substr(first, last - first);
}

std::string lower_ascii_enum_token(std::string source) {
    // Godot's String.to_lower accepts UTF-8 input. Preserve non-ASCII bytes at
    // this normalization layer while folding ASCII letters exactly; enum
    // callers will subsequently treat an unrecognized token as unknown.
    for (char &character : source) {
        const unsigned char value = static_cast<unsigned char>(character);
        if (value < 0x80U) character = static_cast<char>(std::tolower(value));
    }
    return source;
}

std::string normalized_tier(const std::string &source) {
    const std::string tier = lower_ascii_enum_token(trim_ascii(source));
    if (tier == "near" || tier == "mid" || tier == "far" || tier == "impostor") return tier;
    return "near";
}

double lod_scale(const std::string &tier) noexcept {
    if (tier == "mid") return 0.52;
    if (tier == "far") return 0.23;
    return 1.0;
}

std::string fixed(const double value, const int digits) {
    const int required = std::snprintf(nullptr, 0, "%.*f", digits, value);
    std::vector<char> buffer(static_cast<std::size_t>(required) + 1U);
    std::snprintf(buffer.data(), buffer.size(), "%.*f", digits, value);
    return std::string(buffer.data(), static_cast<std::size_t>(required));
}

std::uint32_t unicode_stable_hash(const std::string &source) noexcept {
    // The request boundary admits UTF-8 once. Every separator and suffix added
    // below is ASCII, so this decoder cannot encounter malformed input.
    std::uint32_t value = 2166136261U;
    for (std::size_t index = 0U; index < source.size();) {
        const unsigned char first = static_cast<unsigned char>(source[index]);
        std::uint32_t codepoint = 0U;
        std::size_t length = 0U;
        if (first < 0x80U) { codepoint = first; length = 1U; }
        else if ((first & 0xe0U) == 0xc0U) { codepoint = first & 0x1fU; length = 2U; }
        else if ((first & 0xf0U) == 0xe0U) { codepoint = first & 0x0fU; length = 3U; }
        else { codepoint = first & 0x07U; length = 4U; }
        for (std::size_t offset = 1U; offset < length; ++offset) {
            const unsigned char next = static_cast<unsigned char>(source[index + offset]);
            codepoint = (codepoint << 6U) | (next & 0x3fU);
        }
        value = (value ^ codepoint) * 16777619U;
        index += length;
    }
    return value;
}

std::string hex8(const std::uint32_t value) {
    char buffer[16];
    std::snprintf(buffer, sizeof(buffer), "%08x", value);
    return buffer;
}

void require_finite(const double value) {
    if (!std::isfinite(value)) reject();
}

void validate_growth_profile(const NativeBushyOakGrowthProfile &profile) {
    if (profile.attraction_point_count <= 0) reject();
    if (profile.branch_segment_budget <= 0) reject();
    if (profile.foliage_cluster_budget <= 0) reject();
    if (profile.space_colonization_iteration_budget <= 0) reject();
    if (profile.derived_axis_maximum_growth_seasons <= 0) reject();
}

NativeBushyOakBiomeParameters normalize_parameters(NativeBushyOakBiomeParameters value) {
    for (const double number : {value.height_min, value.height_max, value.trunk_radius_min,
            value.trunk_radius_max, value.canopy_radius_min, value.canopy_radius_max,
            value.canopy_density, value.wind_response, value.visibility_range,
            value.shadow_range, value.exclusion_margin}) require_finite(number);
    value.version = std::max(1, value.version);
    value.architecture = lower_ascii_enum_token(trim_ascii(value.architecture));
    value.height_min = std::max(0.0, value.height_min);
    value.height_max = std::max(0.0, value.height_max);
    value.trunk_radius_min = std::max(0.0, value.trunk_radius_min);
    value.trunk_radius_max = std::max(0.0, value.trunk_radius_max);
    value.canopy_radius_min = std::max(0.0, value.canopy_radius_min);
    value.canopy_radius_max = std::max(0.0, value.canopy_radius_max);
    value.canopy_density = clamp(value.canopy_density, 0.20, 1.0);
    value.wind_response = clamp(value.wind_response, 0.0, 2.0);
    value.visibility_range = std::max(32.0, value.visibility_range);
    value.shadow_range = std::max(16.0, value.shadow_range);
    value.exclusion_margin = std::max(0.0, value.exclusion_margin);
    return value;
}

std::string parameter_key(const NativeBushyOakBiomeParameters &value) {
    return std::to_string(value.version) + ":" + value.architecture + ":"
        + fixed(value.height_min, 2) + ":" + fixed(value.height_max, 2) + ":"
        + fixed(value.trunk_radius_min, 3) + ":" + fixed(value.trunk_radius_max, 3) + ":"
        + fixed(value.canopy_radius_min, 3) + ":" + fixed(value.canopy_radius_max, 3) + ":"
        + fixed(value.canopy_density, 3) + ":" + fixed(value.wind_response, 3) + ":"
        + fixed(value.visibility_range, 1) + ":" + fixed(value.shadow_range, 1);
}

std::string identity_key(const NativeBushyOakWorkerShadow &shadow) {
    return shadow.presentation + ":" + shadow.world_seed + ":" + shadow.tree_id + ":"
        + shadow.biome + ":" + shadow.architecture + ":" + shadow.species_grammar + ":"
        + fixed(shadow.growth_stage, 5) + ":" + fixed(shadow.height, 3) + ":"
        + fixed(shadow.trunk_radius, 3) + ":" + fixed(shadow.canopy_radius, 3) + ":"
        + fixed(shadow.canopy_density, 3) + ":" + std::to_string(shadow.genetic_seed) + ":"
        + parameter_key(shadow.biome_parameters);
}

std::string finalized_signature(
    const NativeBushyOakWorkerShadow &shadow,
    const std::string &topology_signature,
    const std::size_t branch_count) {
    if (shadow.request_key.empty() || topology_signature.empty()) reject();
    const std::string source = shadow.request_key + ":" + topology_signature + ":"
        + std::to_string(branch_count);
    admit_native_tree_worker_serialized_identity(source);
    return "tree-v10-" + hex8(unicode_stable_hash(source));
}

void render_budgets(
    const double density,
    const double scale,
    int &branch_budget,
    int &foliage_budget) {
    branch_budget = clampi(roundi(420.0 * lerpf(0.70, 1.0, density) * scale), 24, 420);
    foliage_budget = clampi(roundi(620.0 * lerpf(0.70, 1.0, density) * scale), 32, 620);
}

NativeBushyOakGrowthProfile runtime_growth_profile(
    const double maturity,
    const double density,
    const double scale) {
    int branch_target = 0;
    int foliage_target = 0;
    render_budgets(density, scale, branch_target, foliage_target);
    const int mature_seasons = clampi(roundi(lerpf(2.0, 4.0, maturity)), 2, 4);
    const int scaled_seasons = std::max(1,
        static_cast<int>(std::floor(static_cast<double>(mature_seasons) * std::pow(scale, 1.35))));
    double topology_headroom = lerpf(1.24, 1.60, maturity);
    topology_headroom *= lerpf(0.72, 1.0, scale);
    const int branch_source = clampi(
        static_cast<int>(std::ceil(static_cast<double>(branch_target) * topology_headroom)), 144, 720);
    const int foliage_source = clampi(static_cast<int>(std::ceil(static_cast<double>(foliage_target)
        * lerpf(1.08, 1.42, maturity) * lerpf(0.82, 1.0, scale))), 176, 960);
    const double attraction_density = lerpf(0.62, 1.0, maturity);
    const int attraction = clampi(static_cast<int>(std::ceil(static_cast<double>(branch_source)
        * std::max(0.45, attraction_density * std::pow(scale, 0.90)))), 96, 700);
    const int iterations = clampi(roundi(lerpf(8.0, 18.0, maturity)
        * std::pow(scale, 1.40)), 4, 18);
    return {attraction, branch_source, foliage_source, iterations, scaled_seasons};
}

} // namespace

NativeBushyOakShadowRejected::NativeBushyOakShadowRejected()
    : std::invalid_argument("invalid bushy-oak shadow input") {}

NativeBushyOakGrowthProfile NativeBushyOakShadowRecipeBuilder::review_growth_profile() noexcept {
    return {};
}

NativeBushyOakShadowRecipe NativeBushyOakShadowRecipeBuilder::build(
    const std::int64_t seed,
    const double maturity,
    const NativeBushyOakGrowthProfile growth_profile) {
    require_finite(maturity);
    validate_growth_profile(growth_profile);
    NativeBushyOakShadowRecipe result;
    result.valid = true;
    result.seed = seed;
    result.maturity = clamp(maturity, 0.12, 1.0);
    result.normalized_growth = (1.0 - std::exp(-3.40 * result.maturity)) / (1.0 - std::exp(-3.40));
    result.height = lerpf(16.0, 43.0, result.normalized_growth);
    result.trunk_radius = lerpf(0.78, 3.10, std::pow(result.normalized_growth, 0.70));
    result.crown_base = lerpf(5.8, 11.6, std::pow(result.normalized_growth, 0.78));
    result.canopy_radius = lerpf(9.0, 29.0, std::pow(result.normalized_growth, 0.84));
    result.crown_height = lerpf(13.0, 32.5, std::pow(result.normalized_growth, 0.82));
    result.crown_center = {0.0F, static_cast<float>(result.crown_base + result.crown_height * 0.45), 0.0F};
    result.crown_radii = {static_cast<float>(result.canopy_radius),
        static_cast<float>(result.crown_height * 0.54), static_cast<float>(result.canopy_radius * 0.92)};
    GodotPcg32 rng(static_cast<std::uint64_t>(seed));
    result.crown_phase = static_cast<double>(rng.randf()) * TAU;
    result.growth_profile = growth_profile;
    return result;
}

NativeBushyOakWorkerShadow NativeBushyOakWorkerShadowBuilder::build(
    const NativeBushyOakWorkerShadowRequest &input) {
    admit_native_tree_worker_text({input.tree_id, input.world_seed, input.biome,
        input.has_architecture ? input.architecture : std::string(),
        input.species_grammar, input.age_band, input.render_lod_tier, input.presentation,
        input.biome_parameters.architecture});
    NativeBushyOakWorkerShadow result;
    result.tree_id = trim_ascii(input.tree_id);
    if (result.tree_id.empty()) return result;
    result.world_seed = trim_ascii(input.world_seed);
    if (result.world_seed.empty()) result.world_seed = "default";
    result.biome = lower_ascii_enum_token(trim_ascii(input.biome));
    result.biome_parameters = normalize_parameters(input.biome_parameters);
    result.architecture = lower_ascii_enum_token(trim_ascii(input.has_architecture
        ? input.architecture
        : result.biome_parameters.architecture));
    if (result.architecture != "broadleaf" && result.architecture != "conifer"
            && result.architecture != "savanna") {
        result.architecture = "broadleaf";
    }
    result.species_grammar = lower_ascii_enum_token(trim_ascii(input.species_grammar));
    if (result.species_grammar == "rounded_broadleaf") result.species_grammar = "bushy_oak";
    if (result.species_grammar.empty()) {
        result.species_grammar = result.architecture == "conifer" ? "norway_spruce"
            : result.architecture == "savanna" ? "umbrella_thorn"
            : "bushy_oak";
    }
    // This compiler owns the bushy-oak grammar, not an architecture label.
    // TreeSpawnService permits an explicit oak grammar with any normalized
    // architecture and uses that architecture for collision policy.
    if (result.species_grammar != "bushy_oak") reject();
    for (const double value : {input.growth_stage, input.visual_height, input.trunk_radius,
            input.canopy_radius, input.age_years, input.world_rotation_y,
            static_cast<double>(input.world_position.x), static_cast<double>(input.world_position.y),
            static_cast<double>(input.world_position.z)}) require_finite(value);
    if (input.has_canopy_density) require_finite(input.canopy_density);
    result.age_band = input.age_band;
    result.age_years = input.age_years;
    result.presentation = input.presentation;
    result.review = input.presentation == "review";
    result.render_lod_tier = normalized_tier(input.render_lod_tier);
    result.impostor_tier = result.render_lod_tier == "impostor";
    result.has_runtime_lod_policy = !result.review;
    result.runtime_impostor = !result.review && result.impostor_tier;
    result.runtime_continuous_bole = !result.review && !result.impostor_tier;
    result.poc_continuous_wood = result.review;
    result.growth_stage = clamp(input.growth_stage, 0.12, 1.0);
    result.height = std::max(4.0, input.visual_height);
    result.trunk_radius = std::max(0.18,
        input.has_trunk_radius ? input.trunk_radius : result.height * 0.04);
    result.canopy_radius = std::max(result.trunk_radius * 2.2,
        input.has_canopy_radius ? input.canopy_radius : result.height * 0.34);
    require_finite(result.height);
    require_finite(result.trunk_radius);
    require_finite(result.canopy_radius);
    result.canopy_density = input.has_canopy_density
        ? clamp(input.canopy_density, 0.20, 1.0)
        : result.biome_parameters.canopy_density;
    result.genetic_seed = input.genetic_seed;
    if (result.genetic_seed == 0) {
        result.genetic_seed = static_cast<std::int64_t>(unicode_stable_hash("tree-local:"
            + result.world_seed + ":" + result.tree_id + ":" + result.biome + ":"
            + result.architecture + ":" + result.species_grammar + ":v10"));
    }
    result.interaction_world_position = input.world_position;
    result.interaction_world_rotation_y = input.world_rotation_y;
    result.render_visibility_range = std::max(32.0, result.biome_parameters.visibility_range);
    result.render_shadow_range = clamp(result.biome_parameters.shadow_range,
        16.0, result.render_visibility_range);
    result.render_wind_response = clamp(result.biome_parameters.wind_response, 0.0, 2.0);
    result.collision_trunk_radius = result.trunk_radius;
    const double trunk_fraction = result.architecture == "conifer" ? 0.82
        : result.architecture == "savanna" ? 0.52
        : 0.46;
    result.collision_trunk_height = std::max(2.0, result.height * trunk_fraction);
    require_finite(result.collision_trunk_height);
    result.recipe_identity_key = identity_key(result);
    result.request_key = result.recipe_identity_key + ":" + result.render_lod_tier;
    admit_native_tree_worker_serialized_identity(result.request_key);
    if (result.impostor_tier) {
        result.status = NativeBushyOakWorkerShadowStatus::exact_impostor_shadow;
        result.topology_complete = true;
        result.topology_signature = "impostor:" + result.world_seed + ":" + result.tree_id + ":"
            + result.species_grammar;
        // The impostor topology identity is composed only from already-admitted
        // request fields. It may exceed one input-field limit without exceeding
        // the shared serialized-identity limit.
        result.signature = finalized_signature(result, result.topology_signature, 0U);
    } else {
        result.status = NativeBushyOakWorkerShadowStatus::topology_pending;
        result.grammar_invoked = true;
        const double scale = lod_scale(result.render_lod_tier);
        result.growth_profile = result.review
            ? NativeBushyOakShadowRecipeBuilder::review_growth_profile()
            : runtime_growth_profile(result.growth_stage, result.canopy_density, scale);
        result.raw_recipe = NativeBushyOakShadowRecipeBuilder::build(
            result.genetic_seed, result.growth_stage, result.growth_profile);
        if (!result.review) {
            render_budgets(result.canopy_density, scale,
                result.render_branch_budget, result.render_foliage_budget);
        }
    }
    result.valid = true;
    return result;
}

std::string NativeBushyOakWorkerShadowBuilder::finalize_signature(
    const NativeBushyOakWorkerShadow &shadow,
    const std::string &topology_signature,
    const std::size_t branch_count) {
    admit_native_tree_worker_text({topology_signature});
    return finalized_signature(shadow, topology_signature, branch_count);
}

void NativeBushyOakWorkerShadowBuilder::validate_definition_dimensions(
    const NativeBushyOakWorkerShadow &shadow,
    const NativeBushyOakDefinitionDimensions &definition) {
    if (!shadow.valid) reject();
    require_finite(definition.height);
    require_finite(definition.trunk_radius);
    require_finite(definition.canopy_radius);
    require_finite(definition.collision_trunk_radius);
    require_finite(definition.collision_trunk_height);
    if (shadow.height != definition.height) reject();
    if (shadow.trunk_radius != definition.trunk_radius) reject();
    if (shadow.canopy_radius != definition.canopy_radius) reject();
    if (shadow.collision_trunk_radius != definition.collision_trunk_radius) reject();
    if (shadow.collision_trunk_height != definition.collision_trunk_height) reject();
}

} // namespace voxel::world_backend
