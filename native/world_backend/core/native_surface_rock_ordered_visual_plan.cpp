#include "native_surface_rock_ordered_visual_plan.hpp"

#include <cstring>
#include <utility>

namespace voxel::world_backend {
namespace {

[[noreturn]] void reject() { throw NativeSurfaceRockOrderedVisualPlanRejected(); }

class Writer final {
public:
    void u8(std::uint8_t v) { bytes.push_back(v); }
    void u32(std::uint32_t v) { for (int s = 24; s >= 0; s -= 8) u8(static_cast<std::uint8_t>(v >> s)); }
    void u64(std::uint64_t v) { for (int s = 56; s >= 0; s -= 8) u8(static_cast<std::uint8_t>(v >> s)); }
    void text(const std::string &v) { u32(static_cast<std::uint32_t>(v.size())); bytes.insert(bytes.end(), v.begin(), v.end()); }
    void digest(const Sha256Digest &d) { bytes.insert(bytes.end(), d.begin(), d.end()); }
    void f32(float v) { std::uint32_t bits; std::memcpy(&bits, &v, sizeof(bits)); u32(bits); }
    void f64(double v) { std::uint64_t bits; std::memcpy(&bits, &v, sizeof(bits)); u64(bits); }
    std::vector<std::uint8_t> bytes;
};

Sha256Digest bound_recipe_digest(const Sha256Digest &base_digest,
    const NativeSurfaceRockAssetSelection &s, NativeSurfaceRockVisualIntent intent) {
    Writer w;
    w.u8('S'); w.u8('R'); w.u8('V'); w.u8('1');
    w.digest(base_digest); w.u8(static_cast<std::uint8_t>(intent));
    w.u32(s.schema_revision); w.digest(s.asset_catalog_digest);
    w.digest(s.environment_catalog_digest); w.digest(s.environment_profile_digest);
    w.text(s.requested_biome); w.text(s.resolved_profile_biome); w.text(s.durable_prop_id);
    w.text(s.asset_id); w.text(s.asset_path);
    w.f32(s.asset_size.x); w.f32(s.asset_size.y); w.f32(s.asset_size.z);
    w.f64(s.rock_scale); w.u32(s.candidate_count); w.u8(s.matched_biome_tag ? 1U : 0U);
    return sha256(w.bytes);
}

} // namespace

NativeSurfaceRockOrderedVisualPlanRejected::NativeSurfaceRockOrderedVisualPlanRejected()
    : std::invalid_argument("invalid native ordered surface rock visual plan") {}

NativeSurfaceRockOrderedVisualPlan::NativeSurfaceRockOrderedVisualPlan(
    NativeSurfaceRockDefinition definition, NativeSurfaceRockAssetSelection selection,
    NativeSurfaceRockVisualIntent intent) noexcept
    : definition_(std::move(definition)), selection_(std::move(selection)), intent_(intent) {}

NativeSurfaceRockOrderedVisualPlan NativeSurfaceRockOrderedVisualPlan::create(
    const NativeSurfacePropSourceOrderedStream &ordered,
    const NativeSurfacePropOrderedPlacement &placements, const std::uint32_t ordinal,
    const NativeEffectiveTerrainSource &terrain, const NativeSurfaceRockAssetCatalog &catalog) {
    if (ordinal >= NativeSurfacePropAttemptStream::ATTEMPT_COUNT
        || catalog.environment_digest() != ordered.source_receipt().environment_profile_digest) reject();
    const auto &placement = placements.entries()[ordinal];
    const double cell_size = terrain.pin().definition().constants().cell_size_meters;
    try {
        const std::int32_t x = native_surface_rock_visual_cell(placement.world_anchor.x, cell_size);
        const std::int32_t z = native_surface_rock_visual_cell(placement.world_anchor.z, cell_size);
        const TerrainBiomeId biome = terrain.sample_surface_biome({x, z, WorldQueryIntent::gameplay});
        const std::string biome_id = NativeSurfacePropSourceDecisionResolver::biome_name(biome);
        NativeSurfaceRockAssetSelection selection = catalog.select(biome_id, placement.durable_id);
        // select constructs these pins from this immutable catalog and the
        // exact biome/ID arguments above; there is no caller selection here.
        NativeSurfaceRockProfile profile;
        profile.schema_revision = NativeBiomeEnvironmentCatalog::SCHEMA_REVISION;
        profile.profile_revision = NativeBiomeEnvironmentCatalog::SCHEMA_REVISION;
        profile.source_profile_digest = selection.environment_profile_digest;
        profile.source_biome = biome_id;
        profile.profile_id = selection.resolved_profile_biome;
        NativeSurfaceRockPresentationReceipt presentation;
        presentation.schema_revision = selection.schema_revision;
        presentation.asset_catalog_digest = selection.asset_catalog_digest;
        presentation.source_profile_digest = selection.environment_profile_digest;
        presentation.source_biome = biome_id;
        presentation.profile_id = profile.profile_id;
        // The existing geometry composer requires a nonempty receipt asset.
        // This internal domain marker is never returned as a selected asset;
        // the plan retains the catalog's empty ID and primitive intent.
        presentation.asset_id = selection.asset_id.empty()
            ? "__native_internal_primitive_fallback_receipt_v1__" : selection.asset_id;
        const auto base = NativeSurfaceRockOrderedComposer::create(
            ordered, placements, ordinal, terrain, profile, presentation);
        const auto intent = selection.asset_id.empty()
            ? NativeSurfaceRockVisualIntent::primitive_required
            : NativeSurfaceRockVisualIntent::selected_asset;
        auto input = base.input();
        input.source_recipe_digest = bound_recipe_digest(input.source_recipe_digest, selection, intent);
        return NativeSurfaceRockOrderedVisualPlan(
            NativeSurfaceRockDefinition::create(std::move(input)), std::move(selection), intent);
    } catch (const std::invalid_argument &) { reject(); }
}

const NativeSurfaceRockDefinition &NativeSurfaceRockOrderedVisualPlan::definition() const noexcept {
    return definition_;
}
const NativeSurfaceRockAssetSelection &NativeSurfaceRockOrderedVisualPlan::selection() const noexcept {
    return selection_;
}
NativeSurfaceRockVisualIntent NativeSurfaceRockOrderedVisualPlan::intent() const noexcept { return intent_; }

} // namespace voxel::world_backend
