#include "native_surface_tree_ordered_composer.hpp"

#include <cstring>

namespace voxel::world_backend {
namespace {

[[noreturn]] void reject() { throw NativeSurfaceTreeOrderedComposerRejected(); }

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
    const NativeSurfacePropOrderedPlacement &placements, const NativeSurfacePropOrderedAttempt &attempt,
    const NativeSurfacePropPlacementEntry &placement, const NativeSurfaceTreeEcologyProfile &profile) {
    Writer w;
    w.u8('S'); w.u8('T'); w.u8('O'); w.u8('1'); w.u32(NativeSurfaceTreeOrderedComposer::PRODUCER_REVISION);
    w.digest(ordered.world_digest()); w.u64(ordered.world_generation());
    w.u32(static_cast<std::uint32_t>(ordered.chunk_x())); w.u32(static_cast<std::uint32_t>(ordered.chunk_z()));
    w.digest(ordered.exclusion_digest()); w.digest(ordered.source_receipt().effective_source_digest);
    w.u32(ordered.source_receipt().schema_revision);
    w.u32(ordered.source_receipt().environment_profile_revision);
    w.digest(ordered.source_receipt().environment_profile_digest);
    w.digest(placements.content_digest()); w.digest(placements.world_source_identity().digest);
    w.digest(placements.definition_source_identity().digest);
    w.u32(ordered.rng_seed()); w.u64(ordered.final_rng_state());
    w.u32(placement.ordinal); w.text(placement.durable_id); w.digest(placement.source_decision_digest);
    w.u32(static_cast<std::uint32_t>(placement.cell_x)); w.u32(static_cast<std::uint32_t>(placement.cell_z));
    w.u64(attempt.state_before_coordinates); w.u64(attempt.state_after_coordinates);
    w.u64(attempt.state_after_classification); w.u64(attempt.state_after_recipe);
    w.f32(*attempt.prop_roll);
    w.u32(profile.schema_revision); w.u32(profile.profile_revision); w.digest(profile.source_profile_digest);
    w.text(profile.source_biome); w.text(profile.profile_id);
    w.u32(static_cast<std::uint32_t>(attempt.compatibility_draws.size()));
    for (float draw : attempt.compatibility_draws) w.f32(draw);
    return sha256(w.bytes);
}

} // namespace

NativeSurfaceTreeOrderedComposerRejected::NativeSurfaceTreeOrderedComposerRejected()
    : std::invalid_argument("invalid native source-ordered surface tree definition") {}

void validate_native_surface_tree_ordered_receipts(const NativeSurfacePropOrderedAttempt &attempt) {
    if (!attempt.source || !attempt.prop_roll) reject();
}

NativeTreeDefinition NativeSurfaceTreeOrderedComposer::create(
    const NativeSurfacePropSourceOrderedStream &ordered,
    const NativeSurfacePropOrderedPlacement &placements, const std::uint32_t ordinal,
    const NativeEffectiveTerrainSource &terrain, const NativeSurfaceTreeEcologyProfile &profile) {
    if (ordinal >= NativeSurfacePropAttemptStream::ATTEMPT_COUNT
        || !ordered.source_receipt().matches_pin(terrain.pin())
        || NativeSurfacePropOrderedPlacement::create(ordered, terrain).content_digest()
            != placements.content_digest()) reject();
    const auto &attempt = ordered.attempts()[ordinal];
    const auto &placement = placements.entries()[ordinal];
    validate_native_surface_tree_ordered_receipts(attempt);
    // The private ordered producer and reconstructed SPO1 prove source/roll
    // presence, root anchoring, and tombstone absence for either tree outcome.
    if ((attempt.outcome != NativeSurfacePropClassificationOutcome::tree_22_draw
            && attempt.outcome != NativeSurfacePropClassificationOutcome::tree_36_draw)
        || profile.source_biome != attempt.source->biome_id) reject();
    try {
        return compose_native_surface_tree_recipe(placement, attempt.compatibility_draws,
            terrain.pin().definition(), profile,
            recipe_digest(ordered, placements, attempt, placement, profile),
            "native_surface_tree_ordered_recipe", PRODUCER_REVISION);
    } catch (const NativeSurfaceTreeDefinitionComposerRejected &) { reject(); }
}

} // namespace voxel::world_backend
