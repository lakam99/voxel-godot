#include "native_surface_rock_ordered_composer.hpp"

#include <cmath>
#include <cstring>
#include <limits>
#include <utility>

namespace voxel::world_backend {
namespace {

[[noreturn]] void reject() { throw NativeSurfaceRockOrderedComposerRejected(); }

bool nonzero(const Sha256Digest &digest) noexcept { return digest != Sha256Digest{}; }

class Writer final {
public:
    void u8(std::uint8_t v) { bytes.push_back(v); }
    void u32(std::uint32_t v) { for (int s = 24; s >= 0; s -= 8) u8(static_cast<std::uint8_t>(v >> s)); }
    void u64(std::uint64_t v) { for (int s = 56; s >= 0; s -= 8) u8(static_cast<std::uint8_t>(v >> s)); }
    void digest(const Sha256Digest &d) { bytes.insert(bytes.end(), d.begin(), d.end()); }
    void text(const std::string &v) { u32(static_cast<std::uint32_t>(v.size())); bytes.insert(bytes.end(), v.begin(), v.end()); }
    void f32(float v) { std::uint32_t bits; std::memcpy(&bits, &v, sizeof(bits)); u32(bits); }
    std::vector<std::uint8_t> bytes;
};

Sha256Digest recipe_digest(const NativeSurfacePropSourceOrderedStream &ordered,
    const NativeSurfacePropOrderedPlacement &placements,
    const NativeSurfacePropOrderedAttempt &attempt, const NativeSurfacePropPlacementEntry &placement,
    const NativeSurfaceRockProfile &profile, const NativeSurfaceRockPresentationReceipt &presentation,
    std::int32_t visual_x, std::int32_t visual_z, TerrainBiomeId visual_biome) {
    Writer w;
    w.u8('S'); w.u8('R'); w.u8('O'); w.u8('1'); w.u32(NativeSurfaceRockOrderedComposer::PRODUCER_REVISION);
    w.digest(placements.content_digest()); w.digest(placements.world_source_identity().digest);
    w.digest(placements.definition_source_identity().digest);
    w.digest(ordered.world_digest()); w.u64(ordered.world_generation());
    w.digest(ordered.exclusion_digest()); w.digest(ordered.source_receipt().effective_source_digest);
    w.u32(placement.ordinal); w.text(placement.durable_id); w.digest(placement.source_decision_digest);
    w.u32(static_cast<std::uint32_t>(visual_x)); w.u32(static_cast<std::uint32_t>(visual_z));
    w.u8(static_cast<std::uint8_t>(visual_biome));
    w.u32(profile.schema_revision); w.u32(profile.profile_revision);
    w.digest(profile.source_profile_digest); w.text(profile.source_biome); w.text(profile.profile_id);
    w.u32(presentation.schema_revision); w.digest(presentation.asset_catalog_digest);
    w.digest(presentation.source_profile_digest); w.text(presentation.source_biome);
    w.text(presentation.profile_id); w.text(presentation.asset_id);
    w.u32(static_cast<std::uint32_t>(attempt.compatibility_draws.size()));
    for (float draw : attempt.compatibility_draws) w.f32(draw);
    return sha256(w.bytes);
}

} // namespace

NativeSurfaceRockOrderedComposerRejected::NativeSurfaceRockOrderedComposerRejected()
    : std::invalid_argument("invalid native ordered surface rock definition") {}

std::int32_t native_surface_rock_visual_cell(float world_component, double cell_size_meters) {
    if (!std::isfinite(world_component) || !std::isfinite(cell_size_meters) || cell_size_meters <= 0.0) reject();
    const double quotient = static_cast<double>(world_component) / cell_size_meters;
    if (!std::isfinite(quotient)
        || quotient <= static_cast<double>(std::numeric_limits<std::int32_t>::min()) - 0.5
        || quotient >= static_cast<double>(std::numeric_limits<std::int32_t>::max()) + 0.5) reject();
    return static_cast<std::int32_t>(std::round(quotient));
}

NativeSurfaceRockDefinition NativeSurfaceRockOrderedComposer::create(
    const NativeSurfacePropSourceOrderedStream &ordered, const NativeSurfacePropOrderedPlacement &placements,
    const std::uint32_t ordinal, const NativeEffectiveTerrainSource &terrain,
    const NativeSurfaceRockProfile &profile, const NativeSurfaceRockPresentationReceipt &presentation) {
    if (ordinal >= NativeSurfacePropAttemptStream::ATTEMPT_COUNT
        || !ordered.source_receipt().matches_pin(terrain.pin())
        || placements.final_rng_state() != ordered.final_rng_state()) reject();
    // Bind all 28 placement entries to this exact ordered witness. This
    // reconstruction consumes its captured facts only; it performs no sample.
    if (NativeSurfacePropOrderedPlacement::create(ordered, terrain).content_digest()
        != placements.content_digest()) reject();
    if (profile.schema_revision == 0U || profile.profile_revision == 0U
        || !nonzero(profile.source_profile_digest) || profile.source_biome.empty() || profile.profile_id.empty()
        || presentation.schema_revision == 0U || !nonzero(presentation.asset_catalog_digest)
        || presentation.source_profile_digest != profile.source_profile_digest
        || presentation.source_biome != profile.source_biome
        || presentation.profile_id != profile.profile_id || presentation.asset_id.empty()) reject();
    const auto &attempt = ordered.attempts()[ordinal];
    const auto &placement = placements.entries()[ordinal];
    if (attempt.outcome != NativeSurfacePropClassificationOutcome::ordinary_rock) reject();
    const double cell_size = terrain.pin().definition().constants().cell_size_meters;
    const std::int32_t visual_x = native_surface_rock_visual_cell(placement.world_anchor.x, cell_size);
    const std::int32_t visual_z = native_surface_rock_visual_cell(placement.world_anchor.z, cell_size);
    TerrainBiomeId visual_biome;
    try {
        visual_biome = terrain.sample_surface_biome({visual_x, visual_z, WorldQueryIntent::gameplay});
    } catch (const std::invalid_argument &) { reject(); }
    if (profile.source_biome != NativeSurfacePropSourceDecisionResolver::biome_name(visual_biome)) reject();
    const auto &draw = attempt.compatibility_draws;
    NativeSurfaceRockDefinitionInput input;
    input.schema_revision = 2U; input.producer_key = "native_surface_rock_ordered_recipe";
    input.producer_revision = PRODUCER_REVISION;
    input.source_recipe_digest = recipe_digest(ordered, placements, attempt, placement,
        profile, presentation, visual_x, visual_z, visual_biome);
    input.durable_feature_id = placement.durable_id; input.source_biome = profile.source_biome;
    input.profile_id = profile.profile_id; input.position = placement.world_anchor;
    input.rotation_y = static_cast<double>(draw[0]) * 6.28318530717958647692;
    input.visual_radius = 0.55 + static_cast<double>(draw[1]) * 0.7;
    input.visual_height_factor = 0.75 + static_cast<double>(draw[2]) * 0.8;
    input.visual_scale_x = static_cast<float>(1.15 + static_cast<double>(draw[3]) * 0.6);
    input.visual_scale_y = static_cast<float>(0.58 + static_cast<double>(draw[4]) * 0.72);
    input.visual_scale_z = static_cast<float>(1.0 + static_cast<double>(draw[5]) * 0.5);
    input.collision = {static_cast<float>(input.visual_radius * 1.05),
        static_cast<float>(input.visual_radius * 0.42)};
    try { return NativeSurfaceRockDefinition::create(std::move(input)); }
    catch (const NativeSurfaceRockDefinitionRejected &) { reject(); }
}

} // namespace voxel::world_backend
