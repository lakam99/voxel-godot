#include "native_tree_definition.hpp"

#include "native_value.hpp"

#include <algorithm>
#include <array>
#include <cmath>
#include <cstring>
#include <limits>
#include <utility>

namespace voxel::world_backend {
namespace {

[[noreturn]] void reject() { throw NativeTreeDefinitionRejected(); }

bool finite(const double value) noexcept { return std::isfinite(value); }
bool non_negative_finite(const double value) noexcept { return finite(value) && value >= 0.0; }
bool positive_finite(const double value) noexcept { return finite(value) && value > 0.0; }

bool is_zero_digest(const Sha256Digest &digest) noexcept {
    return std::all_of(digest.begin(), digest.end(), [](const std::uint8_t byte) { return byte == 0U; });
}

bool valid_kind(const NativeTreeFeatureKind kind) noexcept {
    return kind == NativeTreeFeatureKind::natural_surface_tree || kind == NativeTreeFeatureKind::site_tree;
}
bool valid_frame(const NativeTreeCoordinateFrame frame) noexcept {
    return frame == NativeTreeCoordinateFrame::world || frame == NativeTreeCoordinateFrame::owner_local;
}
bool valid_architecture(const NativeTreeArchitecture architecture) noexcept {
    return architecture == NativeTreeArchitecture::broadleaf
        || architecture == NativeTreeArchitecture::conifer
        || architecture == NativeTreeArchitecture::savanna;
}
bool finite_point(const NativeTreePoint3 &point) noexcept {
    return finite(point.x) && finite(point.y) && finite(point.z);
}

void validate_text(const std::string &value, const std::size_t max_bytes) {
    if (value.empty() || value.size() > max_bytes) reject();
    try { static_cast<void>(NativeValue::string(value)); }
    catch (const NativeValueRejected &) { reject(); }
}
void validate_optional_text(const std::string &value, const std::size_t max_bytes) {
    if (value.empty()) return;
    validate_text(value, max_bytes);
}

void validate_limits(const NativeTreeDefinitionLimits &limits) {
    if (limits.max_text_bytes == 0U || limits.max_buttresses == 0U || limits.max_canonical_bytes == 0U
        || limits.max_text_bytes > std::numeric_limits<std::uint32_t>::max()) reject();
}

void validate_input(const NativeTreeDefinitionInput &input, const NativeTreeDefinitionLimits &limits) {
    if (input.schema_revision == 0U || input.producer_revision == 0U
        || is_zero_digest(input.source_recipe_digest) || !valid_kind(input.feature_kind)
        || !valid_architecture(input.architecture) || !valid_frame(input.coordinate_frame)) reject();
    for (const std::string *text : {
            &input.producer_key, &input.durable_feature_id, &input.recipe_tree_id,
            &input.world_seed, &input.biome, &input.family, &input.growth_class,
            &input.age_band, &input.species_grammar,
        }) validate_text(*text, limits.max_text_bytes);
    validate_optional_text(input.coordinate_owner_id, limits.max_text_bytes);
    if ((input.coordinate_frame == NativeTreeCoordinateFrame::world && !input.coordinate_owner_id.empty())
        || (input.coordinate_frame == NativeTreeCoordinateFrame::owner_local && input.coordinate_owner_id.empty())) reject();
    if (input.feature_kind == NativeTreeFeatureKind::natural_surface_tree
        && (input.coordinate_frame != NativeTreeCoordinateFrame::world
            || input.durable_feature_id != input.recipe_tree_id || !input.root_buttresses.empty())) reject();
    if (!finite_point(input.position) || !finite(input.rotation_y)) reject();

    const NativeTreeEcology &ecology = input.ecology;
    if (!non_negative_finite(ecology.age_years) || !non_negative_finite(ecology.age_range_min)
        || !non_negative_finite(ecology.age_range_max) || ecology.age_range_min > ecology.age_range_max
        || ecology.age_years < ecology.age_range_min || ecology.age_years > ecology.age_range_max
        || !finite(ecology.local_maturity) || ecology.local_maturity < 0.0 || ecology.local_maturity > 1.0
        || !finite(ecology.growth_stage) || ecology.growth_stage < 0.0 || ecology.growth_stage > 1.0) reject();

    const NativeTreeBiomeParameters &params = input.biome_parameters;
    if (params.revision == 0U || !non_negative_finite(params.height_min)
        || !non_negative_finite(params.height_max) || params.height_min > params.height_max
        || !non_negative_finite(params.trunk_radius_min) || !non_negative_finite(params.trunk_radius_max)
        || params.trunk_radius_min > params.trunk_radius_max
        || !non_negative_finite(params.canopy_radius_min) || !non_negative_finite(params.canopy_radius_max)
        || params.canopy_radius_min > params.canopy_radius_max
        || !non_negative_finite(params.canopy_density) || !non_negative_finite(params.wind_response)
        || !non_negative_finite(params.visibility_range) || !non_negative_finite(params.shadow_range)
        || !non_negative_finite(params.exclusion_margin)) reject();

    if (!finite(input.visual_height) || input.visual_height < 1.0
        || !finite(input.trunk_radius) || input.trunk_radius < 0.12
        || !finite(input.canopy_radius) || input.canopy_radius < input.trunk_radius
        || !finite(input.collision_height) || input.collision_height < 1.0
        || input.collision_height > input.visual_height
        || !non_negative_finite(input.exclusion_margin)) reject();
    const float trunk = static_cast<float>(input.trunk_radius);
    const float collision = static_cast<float>(input.collision_height);
    if (!std::isfinite(trunk) || !std::isfinite(collision)) reject();
    if (input.root_buttresses.size() > limits.max_buttresses) reject();
    for (const NativeTreeButtressFootprint &buttress : input.root_buttresses) {
        if (!finite_point(buttress.start) || !finite_point(buttress.end)
            || !positive_finite(buttress.radius_start) || !positive_finite(buttress.radius_end)) reject();
        validate_text(buttress.role, limits.max_text_bytes);
    }
}

class CanonicalWriter final {
public:
    explicit CanonicalWriter(const std::size_t limit) : limit_(limit) {}
    void u8(const std::uint8_t value) { require(1U); bytes_.push_back(value); }
    void u32(const std::uint32_t value) {
        require(4U); for (int shift = 24; shift >= 0; shift -= 8) bytes_.push_back(static_cast<std::uint8_t>(value >> shift));
    }
    void i64(const std::int64_t value) {
        const std::uint64_t bits = static_cast<std::uint64_t>(value);
        require(8U); for (int shift = 56; shift >= 0; shift -= 8) bytes_.push_back(static_cast<std::uint8_t>(bits >> shift));
    }
    void number(const double value) {
        std::uint64_t bits = 0U; std::memcpy(&bits, &value, sizeof(bits));
        require(8U); for (int shift = 56; shift >= 0; shift -= 8) bytes_.push_back(static_cast<std::uint8_t>(bits >> shift));
    }
    void text(const std::string &value) {
        u32(static_cast<std::uint32_t>(value.size())); require(value.size());
        bytes_.insert(bytes_.end(), value.begin(), value.end());
    }
    void digest(const Sha256Digest &value) { require(value.size()); bytes_.insert(bytes_.end(), value.begin(), value.end()); }
    std::vector<std::uint8_t> finish() { return std::move(bytes_); }
private:
    void require(const std::size_t count) const { if (count > limit_ - bytes_.size()) reject(); }
    std::size_t limit_;
    std::vector<std::uint8_t> bytes_;
};

void point(CanonicalWriter &writer, const NativeTreePoint3 &value) {
    writer.number(value.x); writer.number(value.y); writer.number(value.z);
}

std::vector<std::uint8_t> canonical_tree_binary(const NativeTreeDefinitionInput &input, const std::size_t limit) {
    CanonicalWriter writer(limit);
    writer.u8('N'); writer.u8('T'); writer.u8('D'); writer.u8('1');
    writer.u32(input.schema_revision); writer.text(input.producer_key); writer.u32(input.producer_revision);
    writer.digest(input.source_recipe_digest); writer.u8(static_cast<std::uint8_t>(input.feature_kind));
    writer.text(input.durable_feature_id); writer.text(input.recipe_tree_id); writer.text(input.world_seed);
    writer.text(input.biome); writer.text(input.family); writer.text(input.growth_class); writer.text(input.age_band);
    writer.u8(static_cast<std::uint8_t>(input.architecture)); writer.text(input.species_grammar);
    writer.u8(static_cast<std::uint8_t>(input.coordinate_frame)); writer.text(input.coordinate_owner_id);
    point(writer, input.position); writer.number(input.rotation_y);
    writer.number(input.ecology.age_years); writer.number(input.ecology.age_range_min); writer.number(input.ecology.age_range_max);
    writer.number(input.ecology.local_maturity); writer.number(input.ecology.growth_stage); writer.i64(input.ecology.genetic_seed);
    writer.u32(input.biome_parameters.revision); writer.number(input.biome_parameters.height_min); writer.number(input.biome_parameters.height_max);
    writer.number(input.biome_parameters.trunk_radius_min); writer.number(input.biome_parameters.trunk_radius_max);
    writer.number(input.biome_parameters.canopy_radius_min); writer.number(input.biome_parameters.canopy_radius_max);
    writer.number(input.biome_parameters.canopy_density); writer.number(input.biome_parameters.wind_response);
    writer.number(input.biome_parameters.visibility_range); writer.number(input.biome_parameters.shadow_range);
    writer.number(input.biome_parameters.exclusion_margin);
    writer.number(input.visual_height); writer.number(input.trunk_radius); writer.number(input.canopy_radius);
    writer.number(input.collision_height); writer.number(input.exclusion_margin); writer.u8(input.old_growth ? 1U : 0U);
    writer.u32(static_cast<std::uint32_t>(input.root_buttresses.size()));
    for (const NativeTreeButtressFootprint &buttress : input.root_buttresses) {
        point(writer, buttress.start); point(writer, buttress.end); writer.number(buttress.radius_start);
        writer.number(buttress.radius_end); writer.text(buttress.role);
    }
    return writer.finish();
}

} // namespace

NativeTreeDefinitionRejected::NativeTreeDefinitionRejected()
    : std::invalid_argument("invalid native tree definition") {}
bool NativeTreePoint3::operator==(const NativeTreePoint3 &other) const noexcept { return x == other.x && y == other.y && z == other.z; }
bool NativeTreeButtressFootprint::operator==(const NativeTreeButtressFootprint &other) const noexcept { return start == other.start && end == other.end && radius_start == other.radius_start && radius_end == other.radius_end && role == other.role; }
bool NativeTreeEcology::operator==(const NativeTreeEcology &other) const noexcept { return age_years == other.age_years && age_range_min == other.age_range_min && age_range_max == other.age_range_max && local_maturity == other.local_maturity && growth_stage == other.growth_stage && genetic_seed == other.genetic_seed; }
bool NativeTreeBiomeParameters::operator==(const NativeTreeBiomeParameters &other) const noexcept { return revision == other.revision && height_min == other.height_min && height_max == other.height_max && trunk_radius_min == other.trunk_radius_min && trunk_radius_max == other.trunk_radius_max && canopy_radius_min == other.canopy_radius_min && canopy_radius_max == other.canopy_radius_max && canopy_density == other.canopy_density && wind_response == other.wind_response && visibility_range == other.visibility_range && shadow_range == other.shadow_range && exclusion_margin == other.exclusion_margin; }
bool NativeTreeDefinitionInput::operator==(const NativeTreeDefinitionInput &other) const noexcept { return schema_revision == other.schema_revision && producer_key == other.producer_key && producer_revision == other.producer_revision && source_recipe_digest == other.source_recipe_digest && feature_kind == other.feature_kind && durable_feature_id == other.durable_feature_id && recipe_tree_id == other.recipe_tree_id && world_seed == other.world_seed && biome == other.biome && family == other.family && growth_class == other.growth_class && age_band == other.age_band && architecture == other.architecture && species_grammar == other.species_grammar && coordinate_frame == other.coordinate_frame && coordinate_owner_id == other.coordinate_owner_id && position == other.position && rotation_y == other.rotation_y && ecology == other.ecology && biome_parameters == other.biome_parameters && visual_height == other.visual_height && trunk_radius == other.trunk_radius && canopy_radius == other.canopy_radius && collision_height == other.collision_height && exclusion_margin == other.exclusion_margin && old_growth == other.old_growth && root_buttresses == other.root_buttresses; }
bool NativeTreeTrunkCylinder::operator==(const NativeTreeTrunkCylinder &other) const noexcept { return radius == other.radius && height == other.height && center_y == other.center_y; }

NativeTreeDefinition::NativeTreeDefinition(NativeTreeDefinitionInput input, std::vector<std::uint8_t> canonical_binary, Sha256Digest content_digest) noexcept
    : input_(std::move(input)), canonical_binary_(std::move(canonical_binary)), content_digest_(content_digest) {}
NativeTreeDefinition NativeTreeDefinition::create(NativeTreeDefinitionInput input, NativeTreeDefinitionLimits limits) {
    validate_limits(limits); validate_input(input, limits);
    std::vector<std::uint8_t> canonical = canonical_tree_binary(input, limits.max_canonical_bytes);
    return NativeTreeDefinition(std::move(input), canonical, sha256(canonical));
}
const NativeTreeDefinitionInput &NativeTreeDefinition::input() const noexcept { return input_; }
NativeTreeTrunkCylinder NativeTreeDefinition::trunk_cylinder() const noexcept {
    const float height = static_cast<float>(input_.collision_height);
    return {static_cast<float>(input_.trunk_radius), height, height * 0.5F};
}
const std::vector<std::uint8_t> &NativeTreeDefinition::canonical_binary() const noexcept { return canonical_binary_; }
const Sha256Digest &NativeTreeDefinition::content_digest() const noexcept { return content_digest_; }
bool NativeTreeDefinition::operator==(const NativeTreeDefinition &other) const noexcept { return canonical_binary_ == other.canonical_binary_; }
bool NativeTreeDefinition::operator!=(const NativeTreeDefinition &other) const noexcept { return !(*this == other); }

} // namespace voxel::world_backend
