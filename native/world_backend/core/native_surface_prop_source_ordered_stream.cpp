#include "native_surface_prop_source_ordered_stream.hpp"

#include <algorithm>
#include <utility>

namespace voxel::world_backend {
namespace {

// Game chunks and terrain shaping pages share the origin. Every aligned
// 28-cell chunk must fit one primary page, including negative chunk keys.
static_assert(NativeTerrainShapingSnapshot::PAGE_CELLS
    % NativeSurfacePropAttemptStream::CHUNK_CELLS == 0);

[[noreturn]] void reject() { throw NativeSurfacePropSourceOrderedStreamRejected(); }

NativeForageRecipe forage_recipe(const NativeBiomeEnvironmentProfile &profile) {
    NativeForageRecipe recipe;
    recipe.recipe_id = profile.biome_id + ":" + profile.forage_material;
    recipe.material_id = profile.forage_material;
    recipe.drop_id = profile.forage_drop;
    recipe.drop_min = profile.forage_drop_min;
    recipe.drop_max = profile.forage_drop_max;
    recipe.collider_radius = static_cast<float>(profile.forage_radius);
    if (profile.forage_material == "berryBush") {
        recipe.grammar = NativeForageGrammar::berry;
        recipe.navigation = NativeForageNavigationPolicy::blocking;
    } else if (profile.forage_material == "aloePatch") {
        recipe.grammar = NativeForageGrammar::aloe;
        recipe.navigation = NativeForageNavigationPolicy::nonblocking;
    } else if (profile.forage_material == "mushroomCluster") {
        recipe.grammar = NativeForageGrammar::mushroom;
        recipe.navigation = NativeForageNavigationPolicy::nonblocking;
    } else if (profile.forage_material == "frostHerbPatch") {
        recipe.grammar = NativeForageGrammar::frost_herb;
        recipe.navigation = NativeForageNavigationPolicy::nonblocking;
    } else {
        reject();
    }
    return NativeForageRecipeCatalog::admit(std::move(recipe));
}

NativeWildlifeBiomeGroup wildlife_group(const std::string &biome) noexcept {
    if (biome == "snow" || biome == "tundra" || biome == "alpine" || biome == "taiga")
        return NativeWildlifeBiomeGroup::cold;
    if (biome == "forest" || biome == "plains") return NativeWildlifeBiomeGroup::forest_or_plains;
    if (biome == "savanna" || biome == "desert" || biome == "beach") return NativeWildlifeBiomeGroup::dry;
    if (biome == "swamp") return NativeWildlifeBiomeGroup::swamp;
    return NativeWildlifeBiomeGroup::other;
}

std::size_t compatibility_draw_count(const NativeSurfacePropClassificationOutcome outcome) {
    switch (outcome) {
        case NativeSurfacePropClassificationOutcome::ordinary_rock: return 6U;
        case NativeSurfacePropClassificationOutcome::tree_36_draw: return 36U;
        case NativeSurfacePropClassificationOutcome::tree_22_draw: return 22U;
        case NativeSurfacePropClassificationOutcome::skipped_before_prop_roll:
        case NativeSurfacePropClassificationOutcome::no_feature:
        case NativeSurfacePropClassificationOutcome::unported_iron_ore_cluster:
        case NativeSurfacePropClassificationOutcome::unported_copper_ore_cluster:
        case NativeSurfacePropClassificationOutcome::forage_recipe:
        case NativeSurfacePropClassificationOutcome::wildlife_recipe: return 0U;
    }
    reject();
}

void preflight(const AdmittedTerrainSeed &seed, const std::int32_t chunk_x, const std::int32_t chunk_z,
    const Sha256Digest &expected_world_digest, const std::uint64_t expected_world_generation,
    const NativeEffectiveTerrainSource &terrain, const NativeStructureExclusionSnapshot &exclusions) {
    if (!(seed == terrain.pin().definition().raw_terrain_seed())
        || expected_world_digest == Sha256Digest{} || expected_world_generation == 0U
        || exclusions.world_digest() != expected_world_digest
        || exclusions.world_generation() != expected_world_generation) reject();
    const auto min_x = native_surface_prop_checked_chunk_cell(chunk_x, 0);
    const auto min_z = native_surface_prop_checked_chunk_cell(chunk_z, 0);
    const auto max_x = native_surface_prop_checked_chunk_cell(chunk_x, 27);
    const auto max_z = native_surface_prop_checked_chunk_cell(chunk_z, 27);
    // The admitted snapshot stores these exact validated page-key bounds.
    const auto page = terrain.pin().primary_terrain_shaping().page_bounds();
    if (min_x < page.x || min_z < page.z
        || static_cast<std::int64_t>(max_x) >= static_cast<std::int64_t>(page.x) + page.width
        || static_cast<std::int64_t>(max_z) >= static_cast<std::int64_t>(page.z) + page.depth) reject();
    const bool bounds_ready = std::any_of(exclusions.admitted_bounds().begin(), exclusions.admitted_bounds().end(),
        [min_x, min_z](const StructureExclusionBoundsAdmission &receipt) {
            // Snapshot admission already rejects unready bounds receipts.
            return receipt.min_x == min_x && receipt.min_z == min_z;
        });
    if (!bounds_ready) reject();
    // A natural/terrain exclusion can short-circuit an individual query, but
    // all crossed region states still must be captured. Exact ready bounds
    // admission proves unrequested candidates irrelevant to this chunk.
    if (!exclusions.covers_decided_regions(min_x, min_z, max_x, max_z)) reject();
    // Exact chunk bounds and decided coverage make every center-cell query
    // complete. A second 28x28 scan would only duplicate these admissions.
}

} // namespace

NativeWildlifeBiomeGroup native_surface_prop_wildlife_group(const std::string &biome) noexcept {
    return wildlife_group(biome);
}

std::size_t native_surface_prop_compatibility_draw_count(
    const NativeSurfacePropClassificationOutcome outcome) {
    return compatibility_draw_count(outcome);
}

NativeSurfacePropSourceOrderedStreamRejected::NativeSurfacePropSourceOrderedStreamRejected()
    : std::invalid_argument("incomplete native source-ordered surface-prop stream") {}

NativeSurfacePropSourceOrderedStream::NativeSurfacePropSourceOrderedStream(
    const std::uint32_t rng_seed, const std::uint64_t final_rng_state,
    const std::int32_t chunk_x, const std::int32_t chunk_z, Sha256Digest world_digest,
    const std::uint64_t world_generation, NativeSurfacePropSourceReceipt source_receipt,
    Sha256Digest exclusion_digest,
    std::array<NativeSurfacePropOrderedAttempt, NativeSurfacePropAttemptStream::ATTEMPT_COUNT> attempts) noexcept
    : rng_seed_(rng_seed), final_rng_state_(final_rng_state), chunk_x_(chunk_x), chunk_z_(chunk_z),
      world_digest_(world_digest), world_generation_(world_generation), source_receipt_(source_receipt),
      exclusion_digest_(exclusion_digest), attempts_(std::move(attempts)) {}

NativeSurfacePropSourceOrderedStream NativeSurfacePropSourceOrderedStream::create(
    const AdmittedTerrainSeed &seed, const std::int32_t chunk_x, const std::int32_t chunk_z,
    const Sha256Digest &expected_world_digest, const std::uint64_t expected_world_generation,
    const NativeEffectiveTerrainSource &terrain, const NativeBiomeEnvironmentCatalog &catalog,
    const NativeStructureExclusionSnapshot &exclusions, const NativeFeatureDeltaSnapshot &removed_props,
    const NativeWildlifePresentationCatalog &wildlife_presentations) {
    try {
        preflight(seed, chunk_x, chunk_z, expected_world_digest, expected_world_generation, terrain, exclusions);
        const auto seed_value = native_surface_prop_chunk_rng_seed(seed, chunk_x, chunk_z);
        GodotPcg32 rng(seed_value);
        std::array<NativeSurfacePropOrderedAttempt, NativeSurfacePropAttemptStream::ATTEMPT_COUNT> entries{};
        for (std::uint32_t ordinal = 0U; ordinal < entries.size(); ++ordinal) {
            NativeSurfacePropOrderedAttempt entry;
            entry.state_before_coordinates = rng.state();
            const auto x = native_surface_prop_checked_chunk_cell(chunk_x,
                2 + static_cast<std::int32_t>(rng.randi_range(0, 24)));
            const auto z = native_surface_prop_checked_chunk_cell(chunk_z,
                2 + static_cast<std::int32_t>(rng.randi_range(0, 24)));
            entry.attempt = {ordinal, x, z, seed.utf8 + ":" + std::to_string(x) + ","
                + std::to_string(z) + ":" + std::to_string(ordinal)};
            entry.state_after_coordinates = rng.state();
            entry.parent_tombstoned = removed_props.contains_tombstone(entry.attempt.durable_id);
            if (entry.parent_tombstoned) {
                entry.state_after_classification = rng.state();
                entry.state_after_recipe = rng.state();
                entries[ordinal] = std::move(entry);
                continue;
            }
            entry.source = NativeSurfacePropSourceDecisionResolver::resolve(entry.attempt, terrain, catalog,
                exclusions, expected_world_digest, expected_world_generation);
            const auto &classification_input = entry.source->classification;
            float prop_roll = 0.0F;
            float ore_roll = 0.0F;
            bool has_ore_roll = false;
            if (classification_input.admission == NativeSurfacePropAdmission::eligible) {
                prop_roll = rng.randf();
                entry.prop_roll = prop_roll;
                if (prop_roll < classification_input.policy.rock_upper
                    && classification_input.policy.ore_policy == NativeSurfacePropOrePolicy::eligible) {
                    ore_roll = rng.randf();
                    entry.ore_roll = ore_roll;
                    has_ore_roll = true;
                }
            }
            const auto classified = NativeSurfacePropClassifier::classify(classification_input,
                entry.attempt, prop_roll, has_ore_roll, ore_roll);
            entry.outcome = classified.outcome;
            entry.state_after_classification = rng.state();
            const auto count = native_surface_prop_compatibility_draw_count(entry.outcome);
            entry.compatibility_draws.reserve(count);
            for (std::size_t i = 0; i < count; ++i) entry.compatibility_draws.push_back(rng.randf());
            if (entry.outcome == NativeSurfacePropClassificationOutcome::unported_iron_ore_cluster)
                entry.ore_cluster = NativeOreClusterStream::create(entry.attempt.durable_id,
                    NativeOreKind::iron, removed_props, rng);
            if (entry.outcome == NativeSurfacePropClassificationOutcome::unported_copper_ore_cluster)
                entry.ore_cluster = NativeOreClusterStream::create(entry.attempt.durable_id,
                    NativeOreKind::copper, removed_props, rng);
            // The resolver marks a surface present before eligible classification;
            // only eligible attempts can produce forage or wildlife outcomes.
            if (entry.outcome == NativeSurfacePropClassificationOutcome::forage_recipe) {
                const auto &profile = catalog.profile_for_biome(entry.source->biome_id);
                entry.forage = NativeForageStreamBuilder::create(forage_recipe(profile), rng);
            }
            if (entry.outcome == NativeSurfacePropClassificationOutcome::wildlife_recipe) {
                entry.wildlife = NativeWildlifeStreamBuilder::create(
                    native_surface_prop_wildlife_group(entry.source->biome_id), wildlife_presentations, rng);
            }
            entry.state_after_recipe = rng.state();
            entries[ordinal] = std::move(entry);
        }
        const auto source_receipt = NativeSurfacePropSourceReceipt::from_pin(terrain.pin(),
            NativeBiomeEnvironmentCatalog::SCHEMA_REVISION, catalog.content_digest());
        return NativeSurfacePropSourceOrderedStream(seed_value, rng.state(), chunk_x, chunk_z,
            expected_world_digest, expected_world_generation, source_receipt,
            exclusions.content_digest(), std::move(entries));
    } catch (const NativeSurfacePropSourceOrderedStreamRejected &) {
        throw;
    } catch (const std::invalid_argument &) {
        reject();
    }
}

std::uint32_t NativeSurfacePropSourceOrderedStream::rng_seed() const noexcept { return rng_seed_; }
std::uint64_t NativeSurfacePropSourceOrderedStream::final_rng_state() const noexcept { return final_rng_state_; }
std::int32_t NativeSurfacePropSourceOrderedStream::chunk_x() const noexcept { return chunk_x_; }
std::int32_t NativeSurfacePropSourceOrderedStream::chunk_z() const noexcept { return chunk_z_; }
const Sha256Digest &NativeSurfacePropSourceOrderedStream::world_digest() const noexcept { return world_digest_; }
std::uint64_t NativeSurfacePropSourceOrderedStream::world_generation() const noexcept { return world_generation_; }
const NativeSurfacePropSourceReceipt &NativeSurfacePropSourceOrderedStream::source_receipt() const noexcept {
    return source_receipt_;
}
const Sha256Digest &NativeSurfacePropSourceOrderedStream::exclusion_digest() const noexcept {
    return exclusion_digest_;
}
const std::array<NativeSurfacePropOrderedAttempt, NativeSurfacePropAttemptStream::ATTEMPT_COUNT> &
NativeSurfacePropSourceOrderedStream::attempts() const noexcept { return attempts_; }

} // namespace voxel::world_backend
