#include "native_surface_forage_ordered_definition.hpp"

#include <cmath>
#include <cstring>

namespace voxel::world_backend {
namespace {
[[noreturn]] void reject() { throw NativeSurfaceForageOrderedDefinitionRejected(); }
constexpr double TAU_VALUE = 6.28318530717958647692;
float f(double value) { return static_cast<float>(value); }

class Writer final {
public:
    void u8(std::uint8_t value) { bytes.push_back(value); }
    void u32(std::uint32_t value) { for (int shift = 24; shift >= 0; shift -= 8) u8(static_cast<std::uint8_t>(value >> shift)); }
    void u64(std::uint64_t value) { for (int shift = 56; shift >= 0; shift -= 8) u8(static_cast<std::uint8_t>(value >> shift)); }
    void digest(const Sha256Digest &value) { bytes.insert(bytes.end(), value.begin(), value.end()); }
    void text(const std::string &value) { u32(static_cast<std::uint32_t>(value.size())); bytes.insert(bytes.end(), value.begin(), value.end()); }
    void f32(float value) { std::uint32_t bits; std::memcpy(&bits, &value, sizeof(bits)); u32(bits); }
    void vec(const NativeForageVec3 &v) { f32(v.x); f32(v.y); f32(v.z); }
    std::vector<std::uint8_t> bytes;
};

NativeForageRecipe recipe_for(const NativeBiomeEnvironmentProfile &profile) {
    NativeForageRecipe recipe;
    recipe.recipe_id = profile.biome_id + ":" + profile.forage_material;
    recipe.material_id = profile.forage_material;
    recipe.drop_id = profile.forage_drop;
    recipe.drop_min = profile.forage_drop_min;
    recipe.drop_max = profile.forage_drop_max;
    recipe.collider_radius = f(profile.forage_radius);
    if (recipe.material_id == "berryBush") {
        recipe.grammar = NativeForageGrammar::berry;
        recipe.navigation = NativeForageNavigationPolicy::blocking;
    } else if (recipe.material_id == "aloePatch") {
        recipe.grammar = NativeForageGrammar::aloe;
        recipe.navigation = NativeForageNavigationPolicy::nonblocking;
    } else if (recipe.material_id == "mushroomCluster") {
        recipe.grammar = NativeForageGrammar::mushroom;
        recipe.navigation = NativeForageNavigationPolicy::nonblocking;
    } else if (recipe.material_id == "frostHerbPatch") {
        recipe.grammar = NativeForageGrammar::frost_herb;
        recipe.navigation = NativeForageNavigationPolicy::nonblocking;
    } else reject();
    return NativeForageRecipeCatalog::admit(std::move(recipe));
}

void write_mesh(Writer &writer, const NativeForageMesh &mesh) {
    writer.u8(static_cast<std::uint8_t>(mesh.kind)); writer.text(mesh.material_id);
    writer.vec(mesh.position); writer.vec(mesh.rotation); writer.vec(mesh.scale);
    writer.f32(mesh.radius); writer.f32(mesh.height); writer.f32(mesh.top_radius);
    writer.f32(mesh.bottom_radius); writer.u32(static_cast<std::uint32_t>(mesh.radial_segments));
    writer.u32(static_cast<std::uint32_t>(mesh.rings));
}
} // namespace

NativeSurfaceForageOrderedDefinitionRejected::NativeSurfaceForageOrderedDefinitionRejected()
    : std::invalid_argument("invalid native ordered surface forage definition") {}

NativeForageRecipe native_forage_recipe_for_environment_profile(
    const NativeBiomeEnvironmentProfile &profile) {
    return recipe_for(profile);
}

std::size_t native_forage_expected_draw_count(NativeForageGrammar grammar) {
    switch (grammar) {
        case NativeForageGrammar::berry: return 25U;
        case NativeForageGrammar::aloe: return 43U;
        case NativeForageGrammar::mushroom: return 25U;
        case NativeForageGrammar::frost_herb: return 36U;
    }
    reject();
}

void validate_native_forage_attempt_placement(
    const NativeSurfacePropOrderedAttempt &attempt,
    const NativeSurfacePropPlacementEntry &placement) {
    if (attempt.outcome != NativeSurfacePropClassificationOutcome::forage_recipe
        || !attempt.forage || placement.presence != NativeSurfacePropPlacementPresence::anchored
        || placement.durable_id != attempt.attempt.durable_id) reject();
}

NativeForageDecodedGeometry decode_native_forage_geometry(
    const NativeForageRecipe &recipe, const NativeForageStream &stream) {
    NativeForageRecipe admitted;
    try { admitted = NativeForageRecipeCatalog::admit(recipe); }
    catch (const NativeForageRecipeRejected &) { reject(); }
    if (admitted.recipe_id != stream.recipe.recipe_id || admitted.material_id != stream.recipe.material_id
        || admitted.drop_id != stream.recipe.drop_id || admitted.drop_min != stream.recipe.drop_min
        || admitted.drop_max != stream.recipe.drop_max || admitted.collider_radius != stream.recipe.collider_radius
        || admitted.grammar != stream.recipe.grammar || admitted.navigation != stream.recipe.navigation
        || stream.float_draws.size() != native_forage_expected_draw_count(admitted.grammar)
        || stream.drop_count < admitted.drop_min || stream.drop_count > admitted.drop_max) reject();
    NativeForageDecodedGeometry result;
    std::size_t index = 0U;
    const auto draw = [&]() -> double {
        const float value = stream.float_draws[index++];
        if (!std::isfinite(value) || value < 0.0F || value >= 1.0F) reject();
        return static_cast<double>(value);
    };
    result.rotation_y = f(draw() * TAU_VALUE);
    result.collider_radius = admitted.collider_radius;
    result.collider_center_y = f(static_cast<double>(result.collider_radius) * 0.45);
    result.navigation_blocker = admitted.navigation == NativeForageNavigationPolicy::blocking;
    auto sphere = [](float radius, float height, std::string material) {
        NativeForageMesh mesh; mesh.kind = NativeForageMeshKind::sphere;
        mesh.radius = radius; mesh.height = height; mesh.radial_segments = 64; mesh.rings = 32;
        mesh.material_id = std::move(material); return mesh;
    };
    auto cylinder = [](float bottom, float top, float height, int segments, std::string material) {
        NativeForageMesh mesh; mesh.kind = NativeForageMeshKind::cylinder;
        mesh.top_radius = top; mesh.bottom_radius = bottom; mesh.height = height;
        mesh.radial_segments = segments; mesh.material_id = std::move(material); return mesh;
    };
    switch (admitted.grammar) {
        case NativeForageGrammar::berry: {
            auto bush = sphere(0.48F, 0.50F, "berryBush"); bush.position.y = 0.38F;
            bush.scale = {f(1.02 + draw() * 0.28), f(0.62 + draw() * 0.18), f(0.96 + draw() * 0.22)};
            result.meshes.push_back(bush);
            for (int i = 0; i < 7; ++i) {
                auto berry = sphere(0.055F, 0.11F, "berryFruit");
                const double angle = draw() * TAU_VALUE;
                const double spread = 0.20 + draw() * 0.22;
                berry.position = {f(std::cos(angle) * spread), f(0.40 + draw() * 0.20), f(std::sin(angle) * spread)};
                result.meshes.push_back(berry);
            }
            break; }
        case NativeForageGrammar::aloe: {
            for (int i = 0; i < 6; ++i) {
                auto leaf = cylinder(0.14F, 0.0F, 0.68F, 5, "aloePatch");
                leaf.position = {f((draw() - 0.5) * 0.38), 0.24F, f((draw() - 0.5) * 0.38)};
                leaf.rotation = {f(0.35 + draw() * 0.35), f(draw() * TAU_VALUE), 0.0F};
                leaf.scale = {f(0.86 + draw() * 0.28), f(0.82 + draw() * 0.35), f(0.86 + draw() * 0.28)};
                result.meshes.push_back(leaf);
            }
            break; }
        case NativeForageGrammar::mushroom: {
            for (int i = 0; i < 4; ++i) {
                auto stem = cylinder(0.055F, 0.04F, 0.36F, 5, "mushroomCluster");
                const double stem_scale = 0.72 + draw() * 0.55;
                stem.position = {f((draw() - 0.5) * 0.52), f(0.18 * stem_scale), f((draw() - 0.5) * 0.52)};
                stem.scale.y = f(stem_scale);
                result.meshes.push_back(stem);
                auto cap = sphere(0.16F, 0.13F, "mushroomCap");
                cap.position = {stem.position.x, f(static_cast<double>(stem.position.y) + f(0.21 * stem_scale)), stem.position.z};
                cap.scale = {f(1.0 + draw() * 0.34), f(0.48 + draw() * 0.16), f(1.0 + draw() * 0.34)};
                result.meshes.push_back(cap);
            }
            break; }
        case NativeForageGrammar::frost_herb: {
            for (int i = 0; i < 5; ++i) {
                auto blade = cylinder(0.055F, 0.0F, 0.52F, 4, "frostHerbPatch");
                blade.position = {f((draw() - 0.5) * 0.44), 0.22F, f((draw() - 0.5) * 0.44)};
                blade.rotation = {f(0.18 + draw() * 0.28), f(draw() * TAU_VALUE), 0.0F};
                blade.scale = {f(0.9 + draw() * 0.22), f(0.82 + draw() * 0.42), f(0.9 + draw() * 0.22)};
                result.meshes.push_back(blade);
            }
            break; }
    }
    // The admitted grammar and exact draw count above match these fixed loops;
    // every accepted float is consumed once, so a residual count is impossible.
    return result;
}

NativeSurfaceForageOrderedDefinition NativeSurfaceForageOrderedDefinition::create(
    const NativeSurfacePropSourceOrderedStream &ordered,
    const NativeSurfacePropOrderedPlacement &placements, const std::uint32_t ordinal,
    const NativeEffectiveTerrainSource &terrain, const NativeBiomeEnvironmentCatalog &catalog) {
    if (ordinal >= NativeSurfacePropAttemptStream::ATTEMPT_COUNT
        || !ordered.source_receipt().matches_pin(terrain.pin())
        || ordered.source_receipt().environment_profile_digest != catalog.content_digest()
        || placements.final_rng_state() != ordered.final_rng_state()
        || NativeSurfacePropOrderedPlacement::create(ordered, terrain).content_digest() != placements.content_digest()) reject();
    const auto &attempt = ordered.attempts()[ordinal];
    const auto &placement = placements.entries()[ordinal];
    validate_native_forage_attempt_placement(attempt, placement);
    NativeSurfaceForageOrderedDefinition result;
    result.placement_ = placement;
    const auto &stream = *attempt.forage;
    try {
        // Godot passes surface_sample.biome to make_forage; unlike rocks it
        // does not re-query the rounded world-anchor cell for visual policy.
        const auto &profile = catalog.profile_for_biome(
            NativeSurfacePropSourceDecisionResolver::biome_name(placement.biome));
        result.recipe_ = native_forage_recipe_for_environment_profile(profile);
    } catch (const std::invalid_argument &) { reject(); }
    const auto decoded = decode_native_forage_geometry(result.recipe_, stream);
    result.meshes_ = decoded.meshes;
    result.rotation_y_ = decoded.rotation_y;
    result.collider_radius_ = decoded.collider_radius;
    result.collider_center_y_ = decoded.collider_center_y;
    result.navigation_blocker_ = decoded.navigation_blocker;
    result.drop_count_ = stream.drop_count;
    Writer writer; writer.u8('N'); writer.u8('F'); writer.u8('O'); writer.u8('1');
    writer.digest(ordered.world_digest()); writer.u64(ordered.world_generation());
    writer.digest(ordered.exclusion_digest());
    writer.digest(ordered.source_receipt().environment_profile_digest);
    writer.digest(catalog.profile_digest(result.recipe_.recipe_id.substr(0, result.recipe_.recipe_id.find(':'))));
    writer.digest(terrain.pin().physical_content_identity().digest);
    writer.digest(placements.content_digest()); writer.u32(ordinal);
    writer.text(result.recipe_.recipe_id); writer.text(result.recipe_.material_id); writer.text(result.recipe_.drop_id);
    writer.u32(result.recipe_.drop_min); writer.u32(result.recipe_.drop_max); writer.f32(result.recipe_.collider_radius);
    writer.u8(static_cast<std::uint8_t>(result.recipe_.grammar)); writer.u8(static_cast<std::uint8_t>(result.recipe_.navigation));
    writer.text(result.placement_.durable_id); writer.f32(result.placement_.world_anchor.x);
    writer.f32(result.placement_.world_anchor.y); writer.f32(result.placement_.world_anchor.z);
    writer.u64(static_cast<std::uint64_t>(stream.drop_count)); writer.u64(stream.state_before); writer.u64(stream.state_after);
    for (float value : stream.float_draws) writer.f32(value);
    writer.f32(result.rotation_y_); writer.f32(result.collider_radius_); writer.f32(result.collider_center_y_);
    writer.u8(result.navigation_blocker_ ? 1U : 0U);
    for (const auto &mesh : result.meshes_) write_mesh(writer, mesh);
    result.content_digest_ = sha256(writer.bytes);
    return result;
}

const NativeForageRecipe &NativeSurfaceForageOrderedDefinition::recipe() const noexcept { return recipe_; }
const std::vector<NativeForageMesh> &NativeSurfaceForageOrderedDefinition::meshes() const noexcept { return meshes_; }
const NativeSurfacePropPlacementEntry &NativeSurfaceForageOrderedDefinition::placement() const noexcept { return placement_; }
float NativeSurfaceForageOrderedDefinition::rotation_y() const noexcept { return rotation_y_; }
float NativeSurfaceForageOrderedDefinition::collider_radius() const noexcept { return collider_radius_; }
float NativeSurfaceForageOrderedDefinition::collider_center_y() const noexcept { return collider_center_y_; }
bool NativeSurfaceForageOrderedDefinition::physical_collider_present() const noexcept { return true; }
bool NativeSurfaceForageOrderedDefinition::navigation_blocker() const noexcept { return navigation_blocker_; }
std::int64_t NativeSurfaceForageOrderedDefinition::drop_count() const noexcept { return drop_count_; }
const Sha256Digest &NativeSurfaceForageOrderedDefinition::content_digest() const noexcept { return content_digest_; }

} // namespace voxel::world_backend
