#include "native_surface_feature_manifest.hpp"

namespace voxel::world_backend {
namespace {

[[noreturn]] void reject() { throw NativeSurfaceFeatureManifestRejected(); }

class Writer final {
public:
    void u8(std::uint8_t v) { bytes.push_back(v); }
    void u32(std::uint32_t v) { for (int shift = 24; shift >= 0; shift -= 8) u8(static_cast<std::uint8_t>(v >> shift)); }
    void i32(std::int32_t v) { u32(static_cast<std::uint32_t>(v)); }
    void u64(std::uint64_t v) { for (int shift = 56; shift >= 0; shift -= 8) u8(static_cast<std::uint8_t>(v >> shift)); }
    void digest(const Sha256Digest &v) { bytes.insert(bytes.end(), v.begin(), v.end()); }
    void text(const std::string &v) { u32(static_cast<std::uint32_t>(v.size())); bytes.insert(bytes.end(), v.begin(), v.end()); }
    std::vector<std::uint8_t> bytes;
};

bool is_tree(NativeSurfacePropClassificationOutcome outcome) {
    return outcome == NativeSurfacePropClassificationOutcome::tree_22_draw
        || outcome == NativeSurfacePropClassificationOutcome::tree_36_draw;
}

} // namespace

NativeSurfaceFeatureManifestRejected::NativeSurfaceFeatureManifestRejected()
    : std::invalid_argument("invalid source-bound surface feature manifest") {}

NativeSurfaceTreeEcologyProfile native_surface_tree_profile_from_catalog(
    const NativeBiomeEnvironmentCatalog &catalog, const std::string &biome) {
    const auto &source = catalog.profile_for_biome(biome);
    NativeSurfaceTreeEcologyProfile profile;
    profile.schema_revision = NativeBiomeEnvironmentCatalog::SCHEMA_REVISION;
    profile.profile_revision = NativeBiomeEnvironmentCatalog::SCHEMA_REVISION;
    profile.source_profile_digest = catalog.profile_digest(biome);
    profile.source_biome = biome; profile.profile_id = source.biome_id;
    profile.tree_families = source.tree_families; profile.tree_scale = source.tree_scale;
    profile.height_min = source.tree_height_min; profile.height_max = source.tree_height_max;
    profile.trunk_radius_min = source.trunk_radius_min; profile.trunk_radius_max = source.trunk_radius_max;
    profile.canopy_radius_min = source.crown_radius_min; profile.canopy_radius_max = source.crown_radius_max;
    profile.canopy_density = source.canopy_density; profile.wind_response = source.wind_response;
    profile.visibility_range = source.tree_visibility_range; profile.shadow_range = source.tree_shadow_range;
    profile.exclusion_margin = source.natural_prop_exclusion_margin;
    profile.age_min_years = source.tree_age_min_years; profile.age_typical_years = source.tree_age_typical_years;
    profile.age_max_years = source.tree_age_max_years;
    profile.maturity_cell_scale = source.tree_maturity_cell_scale;
    profile.maturity_influence = source.tree_maturity_influence;
    profile.local_age_span = source.tree_local_age_span;
    profile.age_distribution_skew = source.tree_age_distribution_skew;
    for (std::size_t i = 0U; i < profile.age_band_thresholds.size(); ++i)
        profile.age_band_thresholds[i] = source.tree_age_band_thresholds[i];
    profile.height_growth_exponent = source.tree_height_growth_exponent;
    profile.girth_growth_exponent = source.tree_girth_growth_exponent;
    profile.crown_growth_exponent = source.tree_crown_growth_exponent;
    return profile;
}

NativeSurfaceFeatureManifest NativeSurfaceFeatureManifest::create(
    const NativeSurfacePropSourceOrderedStream &ordered,
    const NativeSurfacePropOrderedPlacement &placements,
    const NativeEffectiveTerrainSource &terrain,
    const NativeBiomeEnvironmentCatalog &catalog,
    const NativeSurfaceRockAssetCatalog &rock_assets,
    const NativeStructureExclusionSnapshot &exclusions,
    const NativeWildlifePresentationCatalog &wildlife_presentations,
    const NativeTreeExclusionHaloCapture *tree_halo) {
    const auto &pin = terrain.pin();
    // The ordered stream constructor already rejects zero world identity and
    // generation. Validate only independently supplied source bindings here.
    // The ordered constructor fixes the profile schema revision; its digest
    // still has to match the independently supplied catalog.
    if (!ordered.source_receipt().matches_pin(pin)
        || ordered.source_receipt().environment_profile_digest != catalog.content_digest()
        || ordered.exclusion_digest() != exclusions.content_digest()
        || ordered.world_digest() != exclusions.world_digest()
        || ordered.world_generation() != exclusions.world_generation()
        || placements.content_digest() != NativeSurfacePropOrderedPlacement::create(ordered, terrain).content_digest()) reject();
    if (rock_assets.environment_digest() != catalog.content_digest()) reject();
    if (tree_halo && (tree_halo->world_digest() != ordered.world_digest()
        || tree_halo->world_generation() != ordered.world_generation()
        || tree_halo->center_exclusion_digest() != ordered.exclusion_digest())) reject();

    NativeSurfaceFeatureManifest result;
    result.chunk_x_ = ordered.chunk_x(); result.chunk_z_ = ordered.chunk_z();
    result.world_digest_ = ordered.world_digest(); result.world_generation_ = ordered.world_generation();
    result.final_rng_state_ = ordered.final_rng_state();
    result.placement_digest_ = placements.content_digest(); result.exclusion_digest_ = ordered.exclusion_digest();
    Writer w;
    w.u8('S'); w.u8('F'); w.u8('M'); w.u8('1'); w.u32(SCHEMA_REVISION);
    w.digest(result.world_digest_); w.u64(result.world_generation_);
    w.i32(result.chunk_x_); w.i32(result.chunk_z_);
    w.digest(pin.physical_content_identity().digest);
    w.digest(pin.definition().physical_content_identity().digest);
    w.u64(pin.terrain_delta_revision()); w.u64(pin.shaping_registry_revision());
    w.digest(catalog.content_digest()); w.digest(result.exclusion_digest_);
    w.digest(result.placement_digest_); w.u32(ordered.rng_seed()); w.u64(result.final_rng_state_);
    w.digest(tree_halo ? tree_halo->content_digest() : Sha256Digest{});
    w.u32(NativeSurfacePropAttemptStream::ATTEMPT_COUNT);
    for (std::uint32_t ordinal = 0U; ordinal < NativeSurfacePropAttemptStream::ATTEMPT_COUNT; ++ordinal) {
        const auto &src = ordered.attempts()[ordinal];
        const auto &p = placements.entries()[ordinal];
        auto &entry = result.entries_[ordinal];
        entry.placement = p; entry.parent_tombstoned = src.parent_tombstoned;
        entry.state_after_recipe = src.state_after_recipe;
        // SPO1's checked digest binds these entries to the immutable ordered
        // stream, including ordinal, durable ID, outcome and final RNG state.
        const bool rock = src.outcome == NativeSurfacePropClassificationOutcome::ordinary_rock;
        const bool tree = is_tree(src.outcome);
        if (rock) entry.rock = NativeSurfaceRockOrderedVisualPlan::create(ordered, placements,
            ordinal, terrain, rock_assets);
        if (tree) {
            if (!tree_halo) reject();
            const auto profile = native_surface_tree_profile_from_catalog(catalog, src.source->biome_id);
            entry.tree = NativeSurfaceTreeOrderedComposer::create(ordered, placements,
                ordinal, terrain, profile);
            entry.tree_presence = compose_native_surface_tree_presence(ordered, placements,
                ordinal, terrain, profile, *tree_halo);
            // Presence composes the same deterministic definition and records
            // its digest; neither result can be replaced by the caller.
        }
        switch (src.outcome) {
            case NativeSurfacePropClassificationOutcome::unported_iron_ore_cluster:
            case NativeSurfacePropClassificationOutcome::unported_copper_ore_cluster:
                entry.ore = NativeSurfaceOreClusterDefinition::create(ordered, placements, ordinal, terrain); break;
            case NativeSurfacePropClassificationOutcome::forage_recipe:
                entry.forage = NativeSurfaceForageOrderedDefinition::create(ordered, placements,
                    ordinal, terrain, catalog); break;
            case NativeSurfacePropClassificationOutcome::wildlife_recipe:
                entry.wildlife = NativeSurfaceWildlifeOrderedDefinition::create(ordered, placements,
                    ordinal, terrain, catalog, wildlife_presentations); break;
            default: break;
        }
        w.u32(ordinal); w.text(p.durable_id); w.u8(src.parent_tombstoned ? 1U : 0U);
        w.u8(static_cast<std::uint8_t>(src.outcome)); w.u8(static_cast<std::uint8_t>(p.presence));
        w.u64(src.state_before_coordinates); w.u64(src.state_after_coordinates);
        w.u64(src.state_after_classification); w.u64(src.state_after_recipe);
        w.digest(p.source_decision_digest);
        w.digest(entry.rock ? entry.rock->definition().content_digest() : Sha256Digest{});
        w.digest(entry.ore ? entry.ore->content_digest() : Sha256Digest{});
        w.digest(entry.forage ? entry.forage->content_digest() : Sha256Digest{});
        w.digest(entry.wildlife ? entry.wildlife->content_digest() : Sha256Digest{});
        w.digest(entry.tree ? entry.tree->content_digest() : Sha256Digest{});
        w.digest(entry.tree_presence ? entry.tree_presence->content_digest : Sha256Digest{});
    }
    result.canonical_binary_ = std::move(w.bytes);
    result.content_digest_ = sha256(result.canonical_binary_);
    return result;
}

std::int32_t NativeSurfaceFeatureManifest::chunk_x() const noexcept { return chunk_x_; }
std::int32_t NativeSurfaceFeatureManifest::chunk_z() const noexcept { return chunk_z_; }
std::uint64_t NativeSurfaceFeatureManifest::final_rng_state() const noexcept { return final_rng_state_; }
const Sha256Digest &NativeSurfaceFeatureManifest::world_digest() const noexcept { return world_digest_; }
std::uint64_t NativeSurfaceFeatureManifest::world_generation() const noexcept { return world_generation_; }
const Sha256Digest &NativeSurfaceFeatureManifest::placement_digest() const noexcept { return placement_digest_; }
const Sha256Digest &NativeSurfaceFeatureManifest::exclusion_digest() const noexcept { return exclusion_digest_; }
const std::array<NativeSurfaceFeatureEntry, NativeSurfacePropAttemptStream::ATTEMPT_COUNT> &
NativeSurfaceFeatureManifest::entries() const noexcept { return entries_; }
const std::vector<std::uint8_t> &NativeSurfaceFeatureManifest::canonical_binary() const noexcept { return canonical_binary_; }
const Sha256Digest &NativeSurfaceFeatureManifest::content_digest() const noexcept { return content_digest_; }

} // namespace voxel::world_backend
