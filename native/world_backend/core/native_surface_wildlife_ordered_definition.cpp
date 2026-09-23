#include "native_surface_wildlife_ordered_definition.hpp"

#include <cmath>
#include <cstring>

namespace voxel::world_backend {
namespace {
constexpr double PI = 3.14159265358979323846;
constexpr double TAU = 6.28318530717958647692;
[[noreturn]] void reject() { throw NativeSurfaceWildlifeOrderedDefinitionRejected(); }
float f(double value) { return static_cast<float>(value); }
bool roll(float value) { return std::isfinite(value) && value >= 0.0F && value < 1.0F; }
float range(float from, float to, float unit) { return from + (to - from) * unit; }

class Writer final {
public:
    void u8(std::uint8_t v) { bytes.push_back(v); }
    void u32(std::uint32_t v) { for (int n = 24; n >= 0; n -= 8) u8(static_cast<std::uint8_t>(v >> n)); }
    void u64(std::uint64_t v) { for (int n = 56; n >= 0; n -= 8) u8(static_cast<std::uint8_t>(v >> n)); }
    void text(const std::string &v) { u32(static_cast<std::uint32_t>(v.size())); bytes.insert(bytes.end(), v.begin(), v.end()); }
    void digest(const Sha256Digest &v) { bytes.insert(bytes.end(), v.begin(), v.end()); }
    void f32(float v) { std::uint32_t bits; std::memcpy(&bits, &v, sizeof(bits)); u32(bits); }
    void vec(NativeWildlifeVec3 v) { f32(v.x); f32(v.y); f32(v.z); }
    std::vector<std::uint8_t> bytes;
};

NativeWildlifeMesh sphere(float radius, float height, std::string material) {
    NativeWildlifeMesh m; m.kind = NativeWildlifeMeshKind::sphere;
    m.radius = radius; m.height = height; m.radial_segments = 64; m.rings = 32;
    m.material_id = std::move(material); return m;
}
NativeWildlifeMesh cylinder(float top, float bottom, float height, int segments, std::string material) {
    NativeWildlifeMesh m; m.kind = NativeWildlifeMeshKind::cylinder;
    m.top_radius = top; m.bottom_radius = bottom; m.height = height;
    m.radial_segments = segments; m.material_id = std::move(material); return m;
}
void write_mesh(Writer &w, const NativeWildlifeMesh &m) {
    w.u8(static_cast<std::uint8_t>(m.kind)); w.vec(m.position); w.vec(m.rotation); w.vec(m.scale);
    w.f32(m.radius); w.f32(m.height); w.f32(m.top_radius); w.f32(m.bottom_radius);
    w.u32(static_cast<std::uint32_t>(m.radial_segments)); w.u32(static_cast<std::uint32_t>(m.rings));
    w.text(m.material_id);
}
} // namespace

bool native_surface_wildlife_same_receipt(
    const NativeWildlifePresentationReceipt &a, const NativeWildlifePresentationReceipt &b) {
    return a.schema_revision == b.schema_revision && a.asset_catalog_digest == b.asset_catalog_digest
        && a.variant == b.variant && a.asset_id == b.asset_id
        && a.animation_clip_id == b.animation_clip_id && a.path == b.path;
}
bool native_surface_wildlife_same_recipe(const NativeWildlifeRecipe &a, const NativeWildlifeRecipe &b) {
    return a.revision == b.revision && a.variant == b.variant && a.material_id == b.material_id
        && a.primary_drop_id == b.primary_drop_id && a.primary_drop_min == b.primary_drop_min
        && a.primary_drop_max == b.primary_drop_max && a.extra_drop_id == b.extra_drop_id
        && a.extra_drop_min == b.extra_drop_min && a.extra_drop_max == b.extra_drop_max
        && a.visual_scale == b.visual_scale && a.speed_multiplier == b.speed_multiplier
        && a.cold_speed_multiplier == b.cold_speed_multiplier
        && a.collider.size_x == b.collider.size_x && a.collider.size_y == b.collider.size_y
        && a.collider.size_z == b.collider.size_z && a.collider.center_y == b.collider.center_y
        && a.collision_layer == b.collision_layer && a.collision_mask == b.collision_mask
        && a.navigation == b.navigation;
}

void validate_native_surface_wildlife_ordered_facts(
    const std::uint32_t ordinal, const NativeSurfacePropSourceReceipt &receipt,
    const std::uint64_t ordered_final_state, const std::uint64_t placement_final_state,
    const Sha256Digest &placement_digest, const Sha256Digest &recomputed_placement_digest,
    const NativeSurfacePropOrderedAttempt &attempt,
    const NativeSurfacePropPlacementEntry &placement,
    const WorldSourcePin &pin, const NativeBiomeEnvironmentCatalog &catalog,
    const NativeWildlifePresentationCatalog &presentations) {
    if (ordinal >= NativeSurfacePropAttemptStream::ATTEMPT_COUNT
        || !receipt.matches_pin(pin)
        || receipt.environment_profile_digest != catalog.content_digest()
        || placement_final_state != ordered_final_state
        || recomputed_placement_digest != placement_digest) reject();
    if (attempt.outcome != NativeSurfacePropClassificationOutcome::wildlife_recipe || !attempt.wildlife
        || !attempt.source || placement.presence != NativeSurfacePropPlacementPresence::anchored
        || placement.durable_id != attempt.attempt.durable_id) reject();
    const auto &stream = *attempt.wildlife;
    try {
        const auto expected = presentations.resolve(stream.recipe.variant);
        if (!native_surface_wildlife_same_receipt(expected, stream.presentation)
            || !native_surface_wildlife_same_recipe(NativeWildlifeRecipeCatalog::resolve(stream.recipe.variant),
                stream.recipe)
            || stream.cold != (native_surface_prop_wildlife_group(attempt.source->biome_id)
                == NativeWildlifeBiomeGroup::cold)
            || NativeWildlifeProfileSelector::select(
                native_surface_prop_wildlife_group(attempt.source->biome_id), stream.profile_roll)
                != stream.recipe.variant) reject();
    } catch (const std::invalid_argument &) { reject(); }
}

NativeSurfaceWildlifeOrderedDefinitionRejected::NativeSurfaceWildlifeOrderedDefinitionRejected()
    : std::invalid_argument("invalid native ordered surface wildlife definition") {}

NativeWildlifeDecodedConstruction decode_native_wildlife_construction(
    const NativeWildlifeStream &s, const WorldFloat32Position &anchor) {
    for (float v : {s.profile_roll, s.yaw_roll, s.presentation_first_roll,
            s.presentation_second_roll, s.direction_roll, s.timer_roll, s.speed_roll}) if (!roll(v)) reject();
    if (s.primary_drop_count < s.recipe.primary_drop_min || s.primary_drop_count > s.recipe.primary_drop_max
        || s.extra_drop_count < s.recipe.extra_drop_min || s.extra_drop_count > s.recipe.extra_drop_max
        || s.presentation.variant != s.recipe.variant) reject();
    try { NativeWildlifePresentationReceiptValidator::admit(s.presentation); }
    catch (const NativeWildlifePresentationReceiptRejected &) { reject(); }
    NativeWildlifeDecodedConstruction r;
    r.body_yaw = f(static_cast<double>(s.yaw_roll) * TAU);
    r.collider_size = {s.recipe.collider.size_x, s.recipe.collider.size_y, s.recipe.collider.size_z};
    r.collider_center = {0.0F, s.recipe.collider.center_y, 0.0F};
    r.presentation_path = s.presentation.path;
    if (s.presentation.path == NativeWildlifePresentationPath::animated_playable) {
        const float scale = s.recipe.visual_scale * range(0.92F, 1.08F, s.presentation_first_roll);
        r.visual_scale = {scale, scale, scale};
        r.visual_rotation = {0.0F, f(PI), 0.0F};
        r.animation_speed_scale = range(0.75F, 1.10F, s.presentation_second_roll);
    } else {
        // ReceiptValidator admitted exactly the animated/procedural enum pair.
        r.visual_scale = {s.recipe.visual_scale, s.recipe.visual_scale, s.recipe.visual_scale};
        auto torso = sphere(f(0.42 + static_cast<double>(s.presentation_first_roll) * 0.08),
            f(0.72 + static_cast<double>(s.presentation_second_roll) * 0.10), "wildlife");
        torso.position = {0.0F, 0.56F, 0.0F}; torso.scale = {1.38F, 0.80F, 0.82F};
        r.procedural_meshes.push_back(torso);
        auto head = sphere(0.20F, 0.30F, "wildlife");
        head.position = {0.48F, 0.74F, 0.0F}; head.scale = {1.0F, 0.86F, 0.86F};
        r.procedural_meshes.push_back(head);
        for (float x : {-0.28F, 0.28F}) for (float z : {-0.18F, 0.18F}) {
            auto leg = cylinder(0.045F, 0.055F, 0.52F, 5, "wildlifeDark");
            leg.position = {x, 0.24F, z}; r.procedural_meshes.push_back(leg);
        }
        for (float z : {-0.09F, 0.09F}) {
            auto ear = cylinder(0.0F, 0.06F, 0.20F, 4, "wildlifeDark");
            ear.position = {0.53F, 0.94F, z}; ear.rotation.z = -0.45F;
            r.procedural_meshes.push_back(ear);
        }
    }
    r.movement.home = {anchor.x, anchor.y, anchor.z};
    const double angle = static_cast<double>(s.direction_roll) * TAU;
    // Godot stores Vector3 components in float32 before normalizing.
    const float dx = f(std::cos(angle));
    const float dz = f(std::sin(angle));
    const float length = std::sqrt(dx * dx + dz * dz);
    // A finite roll in [0,1) gives a finite angle in [0,TAU); cos/sin cannot
    // both round to zero and their finite unit norm is strictly positive.
    r.movement.direction = {dx / length, 0.0F, dz / length};
    r.movement.timer = range(0.8F, 2.6F, s.timer_roll);
    r.movement.speed = f(range(0.42F, 0.74F, s.speed_roll)
        * (s.cold ? s.recipe.cold_speed_multiplier : 1.0F) * s.recipe.speed_multiplier);
    return r;
}

NativeSurfaceWildlifeOrderedDefinition NativeSurfaceWildlifeOrderedDefinition::create(
    const NativeSurfacePropSourceOrderedStream &ordered,
    const NativeSurfacePropOrderedPlacement &placements, const std::uint32_t ordinal,
    const NativeEffectiveTerrainSource &terrain, const NativeBiomeEnvironmentCatalog &catalog,
    const NativeWildlifePresentationCatalog &presentations) {
    if (ordinal >= NativeSurfacePropAttemptStream::ATTEMPT_COUNT) reject();
    if (!ordered.source_receipt().matches_pin(terrain.pin())) reject();
    const auto recomputed = NativeSurfacePropOrderedPlacement::create(ordered, terrain);
    const auto &a = ordered.attempts()[ordinal];
    const auto &p = placements.entries()[ordinal];
    validate_native_surface_wildlife_ordered_facts(ordinal, ordered.source_receipt(),
        ordered.final_rng_state(), placements.final_rng_state(), placements.content_digest(),
        recomputed.content_digest(), a, p, terrain.pin(), catalog, presentations);
    const auto &s = *a.wildlife;
    NativeSurfaceWildlifeOrderedDefinition r;
    r.placement_ = p; r.stream_ = s;
    r.construction_ = decode_native_wildlife_construction(s, p.world_anchor);
    r.initial_collider_ = {p.durable_id,
        {p.world_anchor.x, p.world_anchor.y, p.world_anchor.z},
        r.construction_.collider_center, r.construction_.collider_size,
        r.construction_.body_yaw, s.recipe.collision_layer, s.recipe.collision_mask};
    Writer w; w.u8('N'); w.u8('W'); w.u8('O'); w.u8('1');
    w.digest(ordered.world_digest()); w.u64(ordered.world_generation());
    w.digest(ordered.source_receipt().environment_profile_digest);
    w.digest(ordered.exclusion_digest()); w.digest(terrain.pin().physical_content_identity().digest);
    w.digest(placements.content_digest()); w.u32(ordinal);
    w.text(p.durable_id); w.f32(p.world_anchor.x); w.f32(p.world_anchor.y); w.f32(p.world_anchor.z);
    w.u64(s.state_before); w.u64(s.state_after); w.u8(static_cast<std::uint8_t>(s.cold));
    w.u8(static_cast<std::uint8_t>(s.recipe.variant)); w.text(s.recipe.material_id);
    w.text(s.recipe.primary_drop_id); w.u32(static_cast<std::uint32_t>(s.primary_drop_count));
    w.text(s.recipe.extra_drop_id); w.u32(static_cast<std::uint32_t>(s.extra_drop_count));
    w.f32(s.recipe.visual_scale); w.f32(s.recipe.speed_multiplier); w.f32(s.recipe.cold_speed_multiplier);
    w.vec(r.construction_.collider_size); w.vec(r.construction_.collider_center);
    w.u32(s.recipe.collision_layer); w.u32(s.recipe.collision_mask);
    w.u32(s.presentation.schema_revision); w.digest(s.presentation.asset_catalog_digest);
    w.u8(static_cast<std::uint8_t>(s.presentation.path)); w.text(s.presentation.asset_id);
    w.text(s.presentation.animation_clip_id);
    for (float v : {s.profile_roll, s.yaw_roll, s.presentation_first_roll, s.presentation_second_roll,
            s.direction_roll, s.timer_roll, s.speed_roll}) w.f32(v);
    w.f32(r.construction_.body_yaw); w.vec(r.construction_.visual_scale);
    w.vec(r.construction_.visual_rotation); w.f32(r.construction_.animation_speed_scale);
    for (const auto &m : r.construction_.procedural_meshes) write_mesh(w, m);
    w.vec(r.construction_.movement.home); w.vec(r.construction_.movement.direction);
    w.f32(r.construction_.movement.timer); w.f32(r.construction_.movement.speed);
    w.f32(r.construction_.movement.last_move);
    r.content_digest_ = sha256(w.bytes);
    return r;
}

const NativeSurfacePropPlacementEntry &NativeSurfaceWildlifeOrderedDefinition::placement() const noexcept { return placement_; }
const NativeWildlifeStream &NativeSurfaceWildlifeOrderedDefinition::stream() const noexcept { return stream_; }
const NativeWildlifeDecodedConstruction &NativeSurfaceWildlifeOrderedDefinition::construction() const noexcept { return construction_; }
const NativeWildlifeInitialCollider &NativeSurfaceWildlifeOrderedDefinition::initial_collider() const noexcept { return initial_collider_; }
const Sha256Digest &NativeSurfaceWildlifeOrderedDefinition::content_digest() const noexcept { return content_digest_; }
} // namespace voxel::world_backend
