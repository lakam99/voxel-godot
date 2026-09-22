#include "native_surface_rock_definition.hpp"

#include "sha256.hpp"

#include <cmath>
#include <cstring>
#include <utility>

namespace voxel::world_backend {
namespace {

[[noreturn]] void reject() { throw NativeSurfaceRockDefinitionRejected(); }
[[noreturn]] void reject_composer() { throw NativeSurfaceRockDefinitionComposerRejected(); }

bool nonzero_digest(const Sha256Digest &value) noexcept {
    for (const std::uint8_t byte : value) if (byte != 0U) return true;
    return false;
}

bool finite(const float value) noexcept { return std::isfinite(value); }
bool finite(const double value) noexcept { return std::isfinite(value); }
bool finite_position(const WorldFloat32Position &value) noexcept {
    return finite(value.x) && finite(value.y) && finite(value.z);
}

void text(const std::string &value, const std::size_t limit) {
    if (value.empty() || value.size() > limit) reject();
}

class Writer final {
public:
    void u8(const std::uint8_t value) { bytes_.push_back(value); }
    void u32(const std::uint32_t value) {
        for (int shift = 24; shift >= 0; shift -= 8) u8(static_cast<std::uint8_t>(value >> shift));
    }
    void text(const std::string &value) {
        u32(static_cast<std::uint32_t>(value.size()));
        bytes_.insert(bytes_.end(), value.begin(), value.end());
    }
    void digest(const Sha256Digest &value) { bytes_.insert(bytes_.end(), value.begin(), value.end()); }
    void number(const float value) {
        std::uint32_t bits = 0U;
        std::memcpy(&bits, &value, sizeof(bits));
        u32(bits);
    }
    void number(const double value) {
        std::uint64_t bits = 0U;
        std::memcpy(&bits, &value, sizeof(bits));
        for (int shift = 56; shift >= 0; shift -= 8) u8(static_cast<std::uint8_t>(bits >> shift));
    }
    std::vector<std::uint8_t> finish() { return std::move(bytes_); }
private:
    std::vector<std::uint8_t> bytes_{};
};

std::vector<std::uint8_t> canonical(const NativeSurfaceRockDefinitionInput &input) {
    Writer writer;
    writer.u8('S'); writer.u8('R'); writer.u8('K'); writer.u8('2');
    writer.u32(input.schema_revision); writer.text(input.producer_key); writer.u32(input.producer_revision);
    writer.digest(input.source_recipe_digest); writer.text(input.durable_feature_id);
    writer.text(input.source_biome); writer.text(input.profile_id);
    writer.number(input.position.x); writer.number(input.position.y); writer.number(input.position.z);
    writer.number(input.rotation_y); writer.number(input.visual_radius); writer.number(input.visual_height_factor);
    writer.number(input.visual_scale_x); writer.number(input.visual_scale_y); writer.number(input.visual_scale_z);
    writer.number(input.collision.radius); writer.number(input.collision.center_y);
    return writer.finish();
}

void validate_profile(const NativeSurfaceRockProfile &profile) {
    if (profile.schema_revision == 0U) reject_composer();
    if (profile.profile_revision == 0U) reject_composer();
    if (!nonzero_digest(profile.source_profile_digest)) reject_composer();
    if (profile.source_biome.empty() || profile.profile_id.empty()) reject_composer();
}

Sha256Digest recipe_digest(const NativeSurfacePropPlacementSet &set,
    const NativeSurfacePropPlacementEntry &placement,
    const NativeSurfacePropBaselineEntry &baseline,
    const WorldSourceDefinition &source, const NativeSurfaceRockProfile &profile) {
    Writer writer;
    writer.u8('S'); writer.u8('R'); writer.u8('C'); writer.u8('1');
    writer.u32(NativeSurfaceRockDefinitionComposer::PRODUCER_REVISION);
    writer.digest(set.content_digest()); writer.digest(source.physical_content_identity().digest);
    writer.u32(placement.ordinal); writer.text(placement.durable_id); writer.digest(placement.source_decision_digest);
    writer.u32(profile.schema_revision); writer.u32(profile.profile_revision); writer.digest(profile.source_profile_digest);
    writer.text(profile.source_biome); writer.text(profile.profile_id);
    writer.u32(static_cast<std::uint32_t>(baseline.compatibility_draws.size()));
    for (const float draw : baseline.compatibility_draws) writer.number(draw);
    return sha256(writer.finish());
}

} // namespace

bool NativeSurfaceRockSphere::operator==(const NativeSurfaceRockSphere &other) const noexcept {
    return radius == other.radius && center_y == other.center_y;
}
bool NativeSurfaceRockDefinitionInput::operator==(const NativeSurfaceRockDefinitionInput &other) const noexcept {
    return schema_revision == other.schema_revision && producer_key == other.producer_key
        && producer_revision == other.producer_revision && source_recipe_digest == other.source_recipe_digest
        && durable_feature_id == other.durable_feature_id && source_biome == other.source_biome
        && profile_id == other.profile_id && position.x == other.position.x && position.y == other.position.y
        && position.z == other.position.z && rotation_y == other.rotation_y
        && visual_radius == other.visual_radius && visual_height_factor == other.visual_height_factor
        && visual_scale_x == other.visual_scale_x && visual_scale_y == other.visual_scale_y
        && visual_scale_z == other.visual_scale_z && collision == other.collision;
}
NativeSurfaceRockDefinitionRejected::NativeSurfaceRockDefinitionRejected()
    : std::invalid_argument("invalid native surface rock definition") {}
NativeSurfaceRockDefinition::NativeSurfaceRockDefinition(NativeSurfaceRockDefinitionInput input,
    std::vector<std::uint8_t> canonical_binary, Sha256Digest content_digest) noexcept
    : input_(std::move(input)), canonical_binary_(std::move(canonical_binary)), content_digest_(content_digest) {}

NativeSurfaceRockDefinition NativeSurfaceRockDefinition::create(
    NativeSurfaceRockDefinitionInput input, const NativeSurfaceRockDefinitionLimits limits) {
    if (input.schema_revision == 0U) reject();
    if (input.producer_revision == 0U) reject();
    if (!nonzero_digest(input.source_recipe_digest)) reject();
    text(input.producer_key, limits.max_text_bytes); text(input.durable_feature_id, limits.max_text_bytes);
    text(input.source_biome, limits.max_text_bytes); text(input.profile_id, limits.max_text_bytes);
    if (!finite_position(input.position)) reject();
    if (!finite(input.rotation_y)) reject();
    if (!finite(input.visual_radius)) reject();
    if (!finite(input.visual_height_factor)) reject();
    if (!finite(input.visual_scale_x)) reject();
    if (!finite(input.visual_scale_y)) reject();
    if (!finite(input.visual_scale_z)) reject();
    if (!finite(input.collision.radius)) reject();
    if (!finite(input.collision.center_y)) reject();
    if (input.visual_radius < 0.55) reject();
    if (input.visual_radius >= 1.25) reject();
    if (input.visual_height_factor < 0.75) reject();
    if (input.visual_height_factor >= 1.55) reject();
    if (input.visual_scale_x < 1.15F) reject();
    if (input.visual_scale_x > 1.75F) reject();
    if (input.visual_scale_y < 0.58F) reject();
    if (input.visual_scale_y > 1.30F) reject();
    if (input.visual_scale_z < 1.00F) reject();
    if (input.visual_scale_z > 1.50F) reject();
    if (input.collision.radius != static_cast<float>(input.visual_radius * 1.05)) reject();
    if (input.collision.center_y != static_cast<float>(input.visual_radius * 0.42)) reject();
    std::vector<std::uint8_t> bytes = canonical(input);
    if (bytes.size() > limits.max_canonical_bytes) reject();
    const Sha256Digest digest = sha256(bytes);
    return NativeSurfaceRockDefinition(std::move(input), std::move(bytes), digest);
}
const NativeSurfaceRockDefinitionInput &NativeSurfaceRockDefinition::input() const noexcept { return input_; }
const std::vector<std::uint8_t> &NativeSurfaceRockDefinition::canonical_binary() const noexcept { return canonical_binary_; }
const Sha256Digest &NativeSurfaceRockDefinition::content_digest() const noexcept { return content_digest_; }
bool NativeSurfaceRockDefinition::operator==(const NativeSurfaceRockDefinition &other) const noexcept {
    // Both derived fields are deterministic functions of the validated input.
    return input_ == other.input_;
}
bool NativeSurfaceRockDefinition::operator!=(const NativeSurfaceRockDefinition &other) const noexcept { return !(*this == other); }

NativeSurfaceRockDefinitionComposerRejected::NativeSurfaceRockDefinitionComposerRejected()
    : std::invalid_argument("invalid native surface rock definition composer input") {}
NativeSurfaceRockDefinition NativeSurfaceRockDefinitionComposer::create(
    const NativeSurfacePropPlacementSet &placement_set, const NativeSurfacePropBaselineStream &baseline,
    const std::uint32_t ordinal, const WorldSourceDefinition &world_source, const NativeSurfaceRockProfile &profile) {
    validate_profile(profile);
    if (ordinal >= NativeSurfacePropAttemptStream::ATTEMPT_COUNT) reject_composer();
    if (!(placement_set.definition_source_identity() == world_source.physical_content_identity())) reject_composer();
    const NativeSurfacePropPlacementEntry &placement = placement_set.entries()[ordinal];
    const NativeSurfacePropBaselineEntry &entry = baseline.entries()[ordinal];
    if (placement.outcome != NativeSurfacePropClassificationOutcome::ordinary_rock) reject_composer();
    // PlacementSet anchors every physical outcome and preserves attempt indices;
    // BaselineStream also preserves attempt indices and owns recipe draw validity.
    if (placement.durable_id != entry.durable_id) reject_composer();
    // Both immutable producers derive the coordinates from the canonical
    // durable ID. Equal IDs above already prove equal X/Z and ordinal.
    if (placement.source_decision_digest != entry.source_decision_digest) reject_composer();
    if (entry.outcome != placement.outcome) reject_composer();
    NativeSurfaceRockDefinitionInput input;
    input.schema_revision = 2U; input.producer_key = "native_surface_rock_recipe";
    input.producer_revision = PRODUCER_REVISION; input.source_recipe_digest = recipe_digest(placement_set, placement, entry, world_source, profile);
    input.durable_feature_id = placement.durable_id; input.source_biome = profile.source_biome; input.profile_id = profile.profile_id;
    input.position = placement.world_anchor;
    input.rotation_y = static_cast<double>(entry.compatibility_draws[0]) * 6.28318530717958647692;
    input.visual_radius = 0.55 + static_cast<double>(entry.compatibility_draws[1]) * 0.7;
    input.visual_height_factor = 0.75 + static_cast<double>(entry.compatibility_draws[2]) * 0.8;
    input.visual_scale_x = static_cast<float>(1.15 + static_cast<double>(entry.compatibility_draws[3]) * 0.6);
    input.visual_scale_y = static_cast<float>(0.58 + static_cast<double>(entry.compatibility_draws[4]) * 0.72);
    input.visual_scale_z = static_cast<float>(1.0 + static_cast<double>(entry.compatibility_draws[5]) * 0.5);
    input.collision = {static_cast<float>(input.visual_radius * 1.05), static_cast<float>(input.visual_radius * 0.42)};
    try { return NativeSurfaceRockDefinition::create(std::move(input)); }
    catch (const NativeSurfaceRockDefinitionRejected &) { reject_composer(); }
}

} // namespace voxel::world_backend
