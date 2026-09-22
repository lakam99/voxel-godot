#include "native_surface_tree_definition_composer.hpp"

#include "legacy_seed_hash.hpp"
#include "native_value.hpp"

#include <algorithm>
#include <cmath>
#include <cstring>
#include <limits>
#include <utility>

namespace voxel::world_backend {
namespace {

constexpr double UNIT_DENOMINATOR = 2147483647.0;
constexpr double TAU = 6.283185307179586476925286766559;

[[noreturn]] void reject() { throw NativeSurfaceTreeDefinitionComposerRejected(); }

bool nonzero_digest(const Sha256Digest &value) noexcept {
    return std::any_of(value.begin(), value.end(), [](const std::uint8_t byte) { return byte != 0U; });
}
bool finite(const double value) noexcept { return std::isfinite(value); }
bool nonnegative(const double value) noexcept { return finite(value) && value >= 0.0; }
bool positive(const double value) noexcept { return finite(value) && value > 0.0; }
bool unit(const double value) noexcept { return finite(value) && value >= 0.0 && value <= 1.0; }

void text(const std::string &value) {
    if (value.empty()) reject();
    try { static_cast<void>(NativeValue::string(value)); }
    catch (const NativeValueRejected &) { reject(); }
}

std::vector<std::uint32_t> scalars(const std::string &value) {
    try { return BiomeRegionField::admit_utf8_seed(value).code_points; }
    catch (const std::invalid_argument &) { reject(); }
}

std::uint32_t hash_text(const std::string &value) { return legacy_seed_hash(scalars(value)); }
double stable_unit(const std::string &value) {
    return static_cast<double>(hash_text(value) & 0x7fffffffU) / UNIT_DENOMINATOR;
}

double clamp(const double value, const double lower, const double upper) noexcept {
    return std::max(lower, std::min(value, upper));
}
double lerp(const double from, const double to, const double weight) noexcept {
    return from + (to - from) * weight;
}
double smooth(const double value) noexcept {
    const double bounded = clamp(value, 0.0, 1.0);
    return bounded * bounded * (3.0 - 2.0 * bounded);
}

NativeTreeArchitecture architecture_for(const std::string &family) {
    if (family.find("conifer") != std::string::npos) return NativeTreeArchitecture::conifer;
    if (family.find("savanna") != std::string::npos) return NativeTreeArchitecture::savanna;
    if (family.find("broadleaf") != std::string::npos) return NativeTreeArchitecture::broadleaf;
    reject();
}
std::string grammar_for(const NativeTreeArchitecture architecture) {
    if (architecture == NativeTreeArchitecture::conifer) return "norway_spruce";
    if (architecture == NativeTreeArchitecture::savanna) return "umbrella_thorn";
    // architecture_for is the only caller and admits broadleaf/conifer/savanna.
    return "bushy_oak";
}

void validate_profile(const NativeSurfaceTreeEcologyProfile &profile) {
    if (profile.schema_revision == 0U || profile.profile_revision == 0U || !nonzero_digest(profile.source_profile_digest)
        || profile.tree_families.empty() || profile.tree_families.size() > 64U) reject();
    text(profile.source_biome); text(profile.profile_id);
    for (const std::string &family : profile.tree_families) { text(family); static_cast<void>(architecture_for(family)); }
    if (!positive(profile.tree_scale)) reject();
    if (!nonnegative(profile.height_min)) reject();
    if (!nonnegative(profile.height_max)) reject();
    if (profile.height_min > profile.height_max) reject();
    if (!nonnegative(profile.trunk_radius_min)) reject();
    if (!nonnegative(profile.trunk_radius_max)) reject();
    if (profile.trunk_radius_min > profile.trunk_radius_max) reject();
    if (!nonnegative(profile.canopy_radius_min)) reject();
    if (!nonnegative(profile.canopy_radius_max)) reject();
    if (profile.canopy_radius_min > profile.canopy_radius_max) reject();
    if (!nonnegative(profile.canopy_density)) reject();
    if (!nonnegative(profile.wind_response)) reject();
    if (!nonnegative(profile.visibility_range)) reject();
    if (!nonnegative(profile.shadow_range)) reject();
    if (!nonnegative(profile.exclusion_margin)) reject();
    if (!nonnegative(profile.age_min_years)) reject();
    if (!nonnegative(profile.age_typical_years)) reject();
    if (!nonnegative(profile.age_max_years)) reject();
    if (profile.age_min_years > profile.age_typical_years) reject();
    if (profile.age_typical_years > profile.age_max_years) reject();
    if (!finite(profile.maturity_cell_scale)) reject();
    if (profile.maturity_cell_scale < 8.0) reject();
    if (!unit(profile.maturity_influence)) reject();
    if (!finite(profile.local_age_span)) reject();
    if (profile.local_age_span < 0.05) reject();
    if (profile.local_age_span > 1.0) reject();
    if (!finite(profile.age_distribution_skew)) reject();
    if (profile.age_distribution_skew < 0.2) reject();
    if (profile.age_distribution_skew > 3.0) reject();
    if (!finite(profile.height_growth_exponent)) reject();
    if (profile.height_growth_exponent < 0.25) reject();
    if (profile.height_growth_exponent > 2.0) reject();
    if (!finite(profile.girth_growth_exponent)) reject();
    if (profile.girth_growth_exponent < 0.25) reject();
    if (profile.girth_growth_exponent > 2.0) reject();
    if (!finite(profile.crown_growth_exponent)) reject();
    if (profile.crown_growth_exponent < 0.25) reject();
    if (profile.crown_growth_exponent > 2.0) reject();
    double previous = 0.0;
    for (const double threshold : profile.age_band_thresholds) {
        if (!finite(threshold) || threshold <= previous || threshold >= 1.0) reject();
        previous = threshold;
    }
}

double lattice_unit(const std::string &seed, const std::string &biome,
    const std::int32_t x, const std::int32_t z, const std::string &octave) {
    return stable_unit("tree-maturity:" + seed + ":" + biome + ":" + octave + ":"
        + std::to_string(x) + "," + std::to_string(z));
}
double value_noise(const std::string &seed, const std::string &biome,
    const float point_x, const float point_z, const std::string &octave) {
    // The caller divides an int32 cell by a finite scale no smaller than 8,
    // so both float coordinates are finite and safely inside the int32 floor
    // domain. Keep that source invariant at the typed boundary rather than
    // retaining an unreachable fallback branch in the hot recipe path.
    const double x = point_x; const double z = point_z;
    const std::int32_t x0 = static_cast<std::int32_t>(std::floor(x));
    const std::int32_t z0 = static_cast<std::int32_t>(std::floor(z));
    const double tx = smooth(x - static_cast<double>(x0)); const double tz = smooth(z - static_cast<double>(z0));
    const double n00 = lattice_unit(seed, biome, x0, z0, octave);
    const double n10 = lattice_unit(seed, biome, x0 + 1, z0, octave);
    const double n01 = lattice_unit(seed, biome, x0, z0 + 1, octave);
    const double n11 = lattice_unit(seed, biome, x0 + 1, z0 + 1, octave);
    return lerp(lerp(n00, n10, tx), lerp(n01, n11, tx), tz);
}

struct Ecology final {
    double maturity = 0.0;
    double age_min = 0.0;
    double age_max = 0.0;
    double age = 0.0;
    double growth_stage = 0.0;
    std::string age_band;
    double genetic_unit = 0.0;
    std::uint32_t genetic_seed = 0U;
    double height_growth = 0.0;
    double girth_growth = 0.0;
    double crown_growth = 0.0;
};

Ecology ecology_for(const std::string &world_seed, const NativeSurfaceTreeEcologyProfile &profile,
    const std::string &prop_id, const std::int32_t cell_x, const std::int32_t cell_z) {
    const double scale = std::max(8.0, profile.maturity_cell_scale);
    const float point_x = static_cast<float>(cell_x) / static_cast<float>(scale);
    const float point_z = static_cast<float>(cell_z) / static_cast<float>(scale);
    const double base = value_noise(world_seed, profile.source_biome, point_x, point_z, "base");
    const double detail = value_noise(world_seed, profile.source_biome,
        static_cast<float>(cell_x) / static_cast<float>(scale * 0.46),
        static_cast<float>(cell_z) / static_cast<float>(scale * 0.46), "detail");
    Ecology result;
    result.maturity = clamp(base * 0.78 + detail * 0.22, 0.0, 1.0);
    const double effective = lerp(0.5, result.maturity, profile.maturity_influence);
    const double center = effective <= 0.5
        ? lerp(profile.age_min_years, profile.age_typical_years, effective * 2.0)
        : lerp(profile.age_typical_years, profile.age_max_years, (effective - 0.5) * 2.0);
    const double total = profile.age_max_years - profile.age_min_years;
    const double local_span = std::max(1.0, total * profile.local_age_span);
    result.age_min = clamp(center - local_span * 0.5, profile.age_min_years, profile.age_max_years);
    result.age_max = clamp(center + local_span * 0.5, profile.age_min_years, profile.age_max_years);
    if (result.age_max - result.age_min < std::min(1.0, total))
        result.age_max = std::min(profile.age_max_years, result.age_min + std::min(1.0, total));
    const double roll = stable_unit("tree-age:" + world_seed + ":" + profile.source_biome + ":" + prop_id
        + ":" + std::to_string(cell_x) + "," + std::to_string(cell_z));
    result.age = lerp(result.age_min, result.age_max, std::pow(roll, profile.age_distribution_skew));
    result.growth_stage = total <= 0.0001 ? 1.0 : clamp((result.age - profile.age_min_years) / total, 0.0, 1.0);
    result.age_band = result.growth_stage < profile.age_band_thresholds[0] ? "young"
        : result.growth_stage < profile.age_band_thresholds[1] ? "established"
        : result.growth_stage < profile.age_band_thresholds[2] ? "mature"
        : result.growth_stage < profile.age_band_thresholds[3] ? "old" : "ancient";
    result.genetic_unit = stable_unit("tree-genetics:" + world_seed + ":" + profile.source_biome + ":" + prop_id);
    result.genetic_seed = hash_text("tree-genetics-seed:" + world_seed + ":" + profile.source_biome + ":" + prop_id);
    result.height_growth = std::pow(result.growth_stage, profile.height_growth_exponent);
    result.girth_growth = std::pow(result.growth_stage, profile.girth_growth_exponent);
    result.crown_growth = std::pow(result.growth_stage, profile.crown_growth_exponent);
    return result;
}

class Writer final {
public:
    void u8(const std::uint8_t value) { bytes_.push_back(value); }
    void u32(const std::uint32_t value) { for (int shift = 24; shift >= 0; shift -= 8) u8(static_cast<std::uint8_t>(value >> shift)); }
    void digest(const Sha256Digest &value) { bytes_.insert(bytes_.end(), value.begin(), value.end()); }
    void text(const std::string &value) { u32(static_cast<std::uint32_t>(value.size())); bytes_.insert(bytes_.end(), value.begin(), value.end()); }
    void number(const float value) { std::uint32_t bits = 0U; std::memcpy(&bits, &value, sizeof(bits)); u32(bits); }
    std::vector<std::uint8_t> finish() { return std::move(bytes_); }
private:
    std::vector<std::uint8_t> bytes_;
};

Sha256Digest recipe_digest(const NativeSurfacePropPlacementSet &set, const NativeSurfacePropPlacementEntry &placement,
    const NativeSurfacePropBaselineEntry &baseline, const WorldSourceDefinition &source,
    const NativeSurfaceTreeEcologyProfile &profile) {
    Writer writer;
    writer.u8('S'); writer.u8('T'); writer.u8('R'); writer.u8('1'); writer.u32(NativeSurfaceTreeDefinitionComposer::PRODUCER_REVISION);
    writer.digest(set.content_digest()); writer.digest(source.physical_content_identity().digest);
    writer.u32(placement.ordinal); writer.text(placement.durable_id); writer.digest(placement.source_decision_digest);
    writer.u32(profile.schema_revision); writer.u32(profile.profile_revision); writer.digest(profile.source_profile_digest);
    writer.text(profile.source_biome); writer.text(profile.profile_id); writer.u32(static_cast<std::uint32_t>(baseline.compatibility_draws.size()));
    for (const float draw : baseline.compatibility_draws) writer.number(draw);
    return sha256(writer.finish());
}

} // namespace

NativeSurfaceTreeDefinitionComposerRejected::NativeSurfaceTreeDefinitionComposerRejected()
    : std::invalid_argument("invalid native surface tree definition composer input") {}

NativeTreeDefinition NativeSurfaceTreeDefinitionComposer::create(
    const NativeSurfacePropPlacementSet &placement_set,
    const NativeSurfacePropBaselineStream &baseline, const std::uint32_t ordinal,
    const WorldSourceDefinition &world_source, const NativeSurfaceTreeEcologyProfile &profile) {
    validate_profile(profile);
    if (ordinal >= NativeSurfacePropAttemptStream::ATTEMPT_COUNT
        || !(placement_set.world_source_identity() == world_source.physical_content_identity())) reject();
    const NativeSurfacePropPlacementEntry &placement = placement_set.entries()[ordinal];
    const NativeSurfacePropBaselineEntry &baseline_entry = baseline.entries()[ordinal];
    const bool tree = placement.outcome == NativeSurfacePropClassificationOutcome::broadleaf_tree
        || placement.outcome == NativeSurfacePropClassificationOutcome::conifer_tree;
    if (!tree) reject();
    if (placement.presence != NativeSurfacePropPlacementPresence::anchored) reject();
    if (placement.ordinal != ordinal) reject();
    if (baseline_entry.ordinal != ordinal) reject();
    if (placement.durable_id != baseline_entry.durable_id) reject();
    if (placement.cell_x != baseline_entry.cell_x) reject();
    if (placement.cell_z != baseline_entry.cell_z) reject();
    if (placement.source_decision_digest != baseline_entry.source_decision_digest) reject();
    if (placement.outcome != baseline_entry.outcome) reject();
    if (!nonzero_digest(placement.source_decision_digest)) reject();
    const std::size_t expected_draws = placement.outcome == NativeSurfacePropClassificationOutcome::conifer_tree ? 22U : 36U;
    if (baseline_entry.compatibility_draws.size() != expected_draws) reject();
    for (const float draw : baseline_entry.compatibility_draws) {
        if (!std::isfinite(draw)) reject();
        if (draw < 0.0F) reject();
        if (draw >= 1.0F) reject();
    }
    const std::string &raw_seed = world_source.raw_terrain_seed().utf8;
    const AdmittedBiomeSeed ecology_seed = BiomeRegionField::admit_utf8_seed(raw_seed);
    // TreeRuntimeRequestBuilder intentionally selects family with seed_text as
    // presented, while TreeEcologySampler strips/defaults its ecology key.
    // They must remain distinct even where a current two-family profile happens
    // to map both hashes to the same family index.
    const std::uint32_t family_index = hash_text("tree-family:" + raw_seed + ":" + profile.source_biome + ":" + placement.durable_id)
        % static_cast<std::uint32_t>(profile.tree_families.size());
    const std::string family = profile.tree_families[family_index];
    const NativeTreeArchitecture architecture = architecture_for(family);
    if ((placement.outcome == NativeSurfacePropClassificationOutcome::conifer_tree)
        != (architecture == NativeTreeArchitecture::conifer)) reject();
    const Ecology ecology = ecology_for(ecology_seed.utf8, profile, placement.durable_id, placement.cell_x, placement.cell_z);
    const double fallback = 3.0 + static_cast<double>(baseline_entry.compatibility_draws[1]) * 2.2
        + ((profile.source_biome == "taiga" || profile.source_biome == "snow" || profile.source_biome == "tundra") ? 1.6 : 0.0);
    double height = std::max(0.1, fallback) * profile.tree_scale;
    // validate_profile has already established height_max >= height_min.
    if (profile.height_min > 0.0)
        height = lerp(profile.height_min, profile.height_max, ecology.height_growth)
            * lerp(0.94, 1.06, ecology.genetic_unit) * profile.tree_scale;
    double trunk_ratio = lerp(0.038, 0.070, ecology.girth_growth);
    double canopy_ratio = lerp(0.34, 0.56, ecology.crown_growth);
    double collision_fraction = 0.46;
    if (architecture == NativeTreeArchitecture::conifer) { trunk_ratio = lerp(0.024, 0.034, ecology.girth_growth); canopy_ratio = lerp(0.20, 0.34, ecology.crown_growth); collision_fraction = 0.82; }
    if (architecture == NativeTreeArchitecture::savanna) { trunk_ratio = lerp(0.038, 0.055, ecology.girth_growth); canopy_ratio = lerp(0.42, 0.70, ecology.crown_growth); collision_fraction = 0.52; }
    double trunk = std::max(0.18, height * trunk_ratio * lerp(0.92, 1.08, ecology.genetic_unit));
    double canopy = std::max(trunk * 2.2, height * canopy_ratio * lerp(0.90, 1.10, ecology.genetic_unit));
    if (profile.trunk_radius_max >= profile.trunk_radius_min && profile.trunk_radius_max > 0.0)
        trunk = clamp(trunk, std::max(0.18, profile.trunk_radius_min), profile.trunk_radius_max);
    if (profile.canopy_radius_max >= profile.canopy_radius_min && profile.canopy_radius_max > 0.0)
        canopy = clamp(canopy, std::max(trunk * 2.2, profile.canopy_radius_min), profile.canopy_radius_max);
    NativeTreeDefinitionInput input;
    input.schema_revision = 1U; input.producer_key = "native_surface_tree_recipe"; input.producer_revision = PRODUCER_REVISION;
    input.source_recipe_digest = recipe_digest(placement_set, placement, baseline_entry, world_source, profile);
    input.feature_kind = NativeTreeFeatureKind::natural_surface_tree; input.durable_feature_id = placement.durable_id;
    input.recipe_tree_id = placement.durable_id; input.world_seed = raw_seed; input.biome = profile.source_biome;
    input.family = family; input.growth_class = ecology.age_band; input.age_band = ecology.age_band;
    input.architecture = architecture; input.species_grammar = grammar_for(architecture);
    input.coordinate_frame = NativeTreeCoordinateFrame::world;
    input.position = {placement.world_anchor.x, placement.world_anchor.y, placement.world_anchor.z};
    input.rotation_y = static_cast<double>(baseline_entry.compatibility_draws[0]) * TAU;
    input.ecology = {ecology.age, ecology.age_min, ecology.age_max, ecology.maturity, ecology.growth_stage,
        static_cast<std::int64_t>(ecology.genetic_seed)};
    input.biome_parameters = {profile.profile_revision, profile.height_min, profile.height_max,
        profile.trunk_radius_min, profile.trunk_radius_max, profile.canopy_radius_min, profile.canopy_radius_max,
        profile.canopy_density, profile.wind_response, profile.visibility_range, profile.shadow_range, profile.exclusion_margin};
    input.visual_height = height; input.trunk_radius = trunk; input.canopy_radius = canopy;
    input.collision_height = std::max(2.0, height * collision_fraction); input.exclusion_margin = profile.exclusion_margin;
    input.old_growth = ecology.age_band == "old" || ecology.age_band == "ancient";
    try { return NativeTreeDefinition::create(std::move(input)); }
    catch (const NativeTreeDefinitionRejected &) { reject(); }
}

} // namespace voxel::world_backend
