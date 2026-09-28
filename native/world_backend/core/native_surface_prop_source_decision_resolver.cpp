#include "native_surface_prop_source_decision_resolver.hpp"

#include <cmath>
#include <cstring>
#include <limits>
#include <vector>

namespace voxel::world_backend {
namespace {

[[noreturn]] void reject() { throw NativeSurfacePropSourceDecisionRejected(); }

class Writer final {
public:
    void u8(std::uint8_t v) { bytes_.push_back(v); }
    void u32(std::uint32_t v) { for (int s = 24; s >= 0; s -= 8) u8(static_cast<std::uint8_t>(v >> s)); }
    void i32(std::int32_t v) { u32(static_cast<std::uint32_t>(v)); }
    void u64(std::uint64_t v) { for (int s = 56; s >= 0; s -= 8) u8(static_cast<std::uint8_t>(v >> s)); }
    void number(double v) { std::uint64_t bits = 0; std::memcpy(&bits, &v, sizeof(bits)); u64(bits); }
    void digest(const Sha256Digest &v) { bytes_.insert(bytes_.end(), v.begin(), v.end()); }
    void text(const std::string &v) { u32(static_cast<std::uint32_t>(v.size())); bytes_.insert(bytes_.end(), v.begin(), v.end()); }
    Sha256Digest finish() const { return sha256(bytes_); }
private:
    std::vector<std::uint8_t> bytes_;
};

double biome_bias(TerrainBiomeId biome) {
    switch (biome) {
        case TerrainBiomeId::alpine: return 1.0;
        case TerrainBiomeId::snow: return 0.92;
        case TerrainBiomeId::tundra: return 0.82;
        case TerrainBiomeId::desert: return 0.62;
        case TerrainBiomeId::savanna: return 0.58;
        case TerrainBiomeId::taiga: return 0.54;
        case TerrainBiomeId::plains: return 0.38;
        case TerrainBiomeId::forest: return 0.34;
        case TerrainBiomeId::swamp: return 0.16;
        default: return 0.28;
    }
}

NativeSurfacePropPlacementPolicy policy_for(const NativeSurfacePropSpawnFacts &surface,
                                             const NativeBiomeEnvironmentProfile &profile) {
    NativeSurfacePropPlacementPolicy p;
    const double height = surface.height_meters;
    const double rock = profile.rock_base_chance + (height > 42.0 ? 0.12 : 0.0);
    const double tree = height <= 70.0 ? profile.tree_chance : 0.0;
    const double forage = profile.forage_chance;
    const double wildlife = height > 70.0 ? 0.0 : profile.wildlife_chance;
    p.rock_upper = rock;
    p.tree_upper = rock + tree;
    p.forage_upper = rock + tree + forage;
    p.wildlife_upper = rock + tree + forage + wildlife;
    p.tree_replay = surface.biome == TerrainBiomeId::taiga || surface.biome == TerrainBiomeId::snow
            || surface.biome == TerrainBiomeId::tundra
        ? NativeSurfacePropTreeReplayMode::legacy_22_draw : NativeSurfacePropTreeReplayMode::legacy_36_draw;
    // resolve() admits policy construction only through height <= 92.0.
    if (height >= 24.0) {
        p.ore_policy = NativeSurfacePropOrePolicy::eligible;
        const double bias = biome_bias(surface.biome);
        const double height_bias = height > 58.0 ? 1.0 : height > 42.0 ? 0.68 : height > 30.0 ? 0.40 : 0.16;
        p.iron_upper = height > 40.0 ? 0.10 * bias * height_bias : 0.015 * bias;
        p.copper_upper = p.iron_upper + (0.16 * bias + 0.10 * height_bias);
    }
    return p;
}

Sha256Digest decision_digest(const NativeSurfacePropClassificationInput &input,
                             const NativeSurfacePropAttempt &attempt,
                             const NativeSurfacePropSpawnFacts *surface,
                             const NativeBiomeEnvironmentCatalog &catalog,
                             const NativeStructureExclusionSnapshot &exclusions,
                             const StructureExclusionDecision &exclusion) {
    Writer w;
    w.u8('S'); w.u8('P'); w.u8('D'); w.u8('1');
    w.u32(input.ordinal); w.i32(input.cell_x); w.i32(input.cell_z); w.text(attempt.durable_id);
    w.digest(exclusions.world_digest()); w.u64(exclusions.world_generation()); w.digest(exclusions.content_digest());
    w.u8(static_cast<std::uint8_t>(exclusion.kind)); w.text(exclusion.source_id);
    w.u8(static_cast<std::uint8_t>(input.admission));
    if (surface != nullptr) {
        w.digest(surface->physical_content_identity.digest);
        w.u64(surface->terrain_delta_revision); w.u64(surface->shaping_registry_revision);
        w.u8(static_cast<std::uint8_t>(surface->mode)); w.u8(surface->found ? 1U : 0U);
        w.number(surface->height_meters); w.u8(static_cast<std::uint8_t>(surface->biome));
        w.u8(static_cast<std::uint8_t>(surface->material));
        w.i32(surface->solid_cell.x); w.i32(surface->solid_cell.y); w.i32(surface->solid_cell.z);
        w.i32(surface->air_cell.x); w.i32(surface->air_cell.y); w.i32(surface->air_cell.z);
        w.digest(catalog.profile_digest(NativeSurfacePropSourceDecisionResolver::biome_name(surface->biome)));
    }
    const auto &p = input.policy;
    w.number(p.rock_upper); w.number(p.tree_upper); w.number(p.forage_upper); w.number(p.wildlife_upper);
    w.u8(static_cast<std::uint8_t>(p.tree_replay)); w.u8(static_cast<std::uint8_t>(p.ore_policy));
    w.number(p.iron_upper); w.number(p.copper_upper);
    return w.finish();
}

} // namespace

NativeSurfacePropSourceDecisionRejected::NativeSurfacePropSourceDecisionRejected()
    : std::invalid_argument("invalid or incomplete native surface-prop source decision") {}

const char *NativeSurfacePropSourceDecisionResolver::biome_name(TerrainBiomeId biome) {
    switch (biome) {
        case TerrainBiomeId::plains: return "plains";
        case TerrainBiomeId::forest: return "forest";
        case TerrainBiomeId::swamp: return "swamp";
        case TerrainBiomeId::desert: return "desert";
        case TerrainBiomeId::savanna: return "savanna";
        case TerrainBiomeId::snow: return "snow";
        case TerrainBiomeId::taiga: return "taiga";
        case TerrainBiomeId::tundra: return "tundra";
        case TerrainBiomeId::ocean: return "ocean";
        case TerrainBiomeId::beach: return "beach";
        case TerrainBiomeId::town: return "town";
        case TerrainBiomeId::underground: return "underground";
        case TerrainBiomeId::deep_underground: return "deep_underground";
        case TerrainBiomeId::underground_air: return "underground_air";
        case TerrainBiomeId::alpine: return "alpine";
    }
    reject();
}

void NativeSurfacePropSourceDecisionResolver::require_finite_surface_height(double height_meters) {
    if (!std::isfinite(height_meters)) reject();
}

NativeSurfacePropResolvedDecision NativeSurfacePropSourceDecisionResolver::resolve(
    const NativeSurfacePropAttempt &attempt, const NativeEffectiveTerrainSource &terrain,
    const NativeBiomeEnvironmentCatalog &catalog, const NativeStructureExclusionSnapshot &exclusions,
    const Sha256Digest &expected_world_digest, std::uint64_t expected_world_generation) {
    if (attempt.durable_id.empty() || attempt.ordinal >= NativeSurfacePropAttemptStream::ATTEMPT_COUNT
        || exclusions.world_digest() != expected_world_digest
        || exclusions.world_generation() != expected_world_generation) reject();
    NativeSurfacePropResolvedDecision resolved;
    auto &input = resolved.classification;
    input.ordinal = attempt.ordinal; input.cell_x = attempt.cell_x; input.cell_z = attempt.cell_z;
    const auto exclusion = exclusions.query(attempt.cell_x, attempt.cell_z);
    if (!exclusion.complete) reject();
    if (exclusion.blocked) {
        input.admission = NativeSurfacePropAdmission::structure_blocked;
        input.source_decision_digest = decision_digest(input, attempt, nullptr, catalog, exclusions, exclusion);
        return resolved;
    }
    const auto surface = terrain.sample_surface_prop_spawn({attempt.cell_x, attempt.cell_z, WorldQueryIntent::gameplay});
    resolved.has_surface = true;
    resolved.surface = surface;
    resolved.biome_id = biome_name(surface.biome);
    if (!surface.found) input.admission = NativeSurfacePropAdmission::surface_unavailable;
    else {
        require_finite_surface_height(surface.height_meters);
        if (surface.height_meters < terrain.pin().definition().constants().water_level_meters + 1.0
             || surface.height_meters > 92.0)
            input.admission = NativeSurfacePropAdmission::surface_ineligible;
        else if (surface.biome == TerrainBiomeId::town) input.admission = NativeSurfacePropAdmission::town;
        else {
            input.admission = NativeSurfacePropAdmission::eligible;
            input.policy = policy_for(surface, catalog.profile_for_biome(resolved.biome_id));
        }
    }
    input.source_decision_digest = decision_digest(input, attempt, &surface, catalog, exclusions, exclusion);
    return resolved;
}

} // namespace voxel::world_backend
