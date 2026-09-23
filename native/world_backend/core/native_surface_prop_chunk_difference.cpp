#include "native_surface_prop_chunk_difference.hpp"

#include <cstring>

namespace voxel::world_backend {
namespace {

[[noreturn]] void reject() { throw NativeSurfacePropChunkDifferenceRejected(); }

class Writer final {
public:
    void u8(std::uint8_t v) { bytes.push_back(v); }
    void u32(std::uint32_t v) { for (int s = 24; s >= 0; s -= 8) u8(static_cast<std::uint8_t>(v >> s)); }
    void i32(std::int32_t v) { u32(static_cast<std::uint32_t>(v)); }
    void u64(std::uint64_t v) { for (int s = 56; s >= 0; s -= 8) u8(static_cast<std::uint8_t>(v >> s)); }
    void i64(std::int64_t v) { u64(static_cast<std::uint64_t>(v)); }
    void text(const std::string &v) { u32(static_cast<std::uint32_t>(v.size())); bytes.insert(bytes.end(), v.begin(), v.end()); }
    void digest(const Sha256Digest &d) { bytes.insert(bytes.end(), d.begin(), d.end()); }
    void f32(float v) { std::uint32_t b; std::memcpy(&b, &v, sizeof(b)); u32(b); }
    void f64(double v) { std::uint64_t b; std::memcpy(&b, &v, sizeof(b)); u64(b); }
    std::vector<std::uint8_t> bytes;
};

void floats(Writer &w, const std::vector<float> &draws) {
    w.u32(static_cast<std::uint32_t>(draws.size()));
    for (float draw : draws) w.f32(draw);
}

Sha256Digest attempt_digest(const NativeSurfacePropOrderedAttempt &a) {
    Writer w;
    w.u8('S'); w.u8('P'); w.u8('A'); w.u8('1');
    w.u32(a.attempt.ordinal); w.i32(a.attempt.cell_x); w.i32(a.attempt.cell_z);
    w.text(a.attempt.durable_id); w.u8(a.parent_tombstoned ? 1U : 0U);
    w.u8(static_cast<std::uint8_t>(a.outcome));
    w.u64(a.state_before_coordinates); w.u64(a.state_after_coordinates);
    w.u64(a.state_after_classification); w.u64(a.state_after_recipe);
    w.u8(a.prop_roll.has_value() ? 1U : 0U); if (a.prop_roll) w.f32(*a.prop_roll);
    w.u8(a.ore_roll.has_value() ? 1U : 0U); if (a.ore_roll) w.f32(*a.ore_roll);
    floats(w, a.compatibility_draws);
    w.u8(a.source.has_value() ? 1U : 0U);
    if (a.source) {
        const auto &s = *a.source;
        w.digest(s.classification.source_decision_digest);
        w.u8(static_cast<std::uint8_t>(s.classification.admission));
        w.u8(s.has_surface ? 1U : 0U); w.text(s.biome_id);
        if (s.has_surface) {
            const auto &f = s.surface;
            w.u8(f.found ? 1U : 0U); w.u8(static_cast<std::uint8_t>(f.mode));
            w.f64(f.height_meters); w.f32(f.world_anchor_y);
            w.u8(static_cast<std::uint8_t>(f.biome)); w.u8(static_cast<std::uint8_t>(f.material));
            w.i32(f.solid_cell.x); w.i32(f.solid_cell.y); w.i32(f.solid_cell.z);
            w.i32(f.air_cell.x); w.i32(f.air_cell.y); w.i32(f.air_cell.z);
            w.digest(f.physical_content_identity.digest);
            w.u64(f.terrain_delta_revision); w.u64(f.shaping_registry_revision);
        }
    }
    w.u8(a.ore_cluster.has_value() ? 1U : 0U);
    if (a.ore_cluster) {
        for (const auto &child : a.ore_cluster->children()) {
            w.text(child.durable_id); w.u8(child.skipped_by_tombstone ? 1U : 0U);
            w.u64(child.state_before); w.u64(child.state_after);
            w.i64(child.drop_count); floats(w, child.float_draws);
        }
        w.u64(a.ore_cluster->final_rng_state());
    }
    w.u8(a.forage.has_value() ? 1U : 0U);
    if (a.forage) {
        const auto &f = *a.forage;
        w.text(f.recipe.recipe_id); w.text(f.recipe.material_id); w.text(f.recipe.drop_id);
        w.i32(f.recipe.drop_min); w.i32(f.recipe.drop_max); w.f32(f.recipe.collider_radius);
        w.u8(static_cast<std::uint8_t>(f.recipe.grammar));
        w.u8(static_cast<std::uint8_t>(f.recipe.navigation));
        w.u64(f.state_before); w.u64(f.state_after); w.i64(f.drop_count); floats(w, f.float_draws);
    }
    w.u8(a.wildlife.has_value() ? 1U : 0U);
    if (a.wildlife) {
        const auto &v = *a.wildlife;
        const auto &r = v.recipe;
        const auto &p = v.presentation;
        w.u32(r.revision); w.u8(static_cast<std::uint8_t>(r.variant));
        w.text(r.material_id); w.text(r.primary_drop_id); w.i32(r.primary_drop_min); w.i32(r.primary_drop_max);
        w.text(r.extra_drop_id); w.i32(r.extra_drop_min); w.i32(r.extra_drop_max);
        w.f32(r.visual_scale); w.f32(r.speed_multiplier); w.f32(r.cold_speed_multiplier);
        w.f32(r.collider.size_x); w.f32(r.collider.size_y); w.f32(r.collider.size_z); w.f32(r.collider.center_y);
        w.u32(r.collision_layer); w.u32(r.collision_mask); w.u8(static_cast<std::uint8_t>(r.navigation));
        w.u32(p.schema_revision); w.digest(p.asset_catalog_digest);
        w.u8(static_cast<std::uint8_t>(p.variant)); w.text(p.asset_id); w.text(p.animation_clip_id);
        w.u8(static_cast<std::uint8_t>(p.path)); w.u8(v.cold ? 1U : 0U);
        w.u64(v.state_before); w.u64(v.state_after);
        w.f32(v.profile_roll); w.f32(v.yaw_roll);
        w.i64(v.primary_drop_count); w.i64(v.extra_drop_count);
        w.f32(v.presentation_first_roll); w.f32(v.presentation_second_roll);
        w.f32(v.direction_roll); w.f32(v.timer_roll); w.f32(v.speed_roll);
    }
    return sha256(w.bytes);
}

bool same_position(const WorldFloat32Position &a, const WorldFloat32Position &b) noexcept {
    return std::memcmp(&a.x, &b.x, sizeof(float)) == 0
        && std::memcmp(&a.y, &b.y, sizeof(float)) == 0
        && std::memcmp(&a.z, &b.z, sizeof(float)) == 0;
}

NativeSurfacePropChunkAttemptSnapshot snapshot(const NativeSurfacePropOrderedAttempt &source,
    const NativeSurfacePropPlacementEntry &placement) {
    NativeSurfacePropChunkAttemptSnapshot s;
    s.ordinal = source.attempt.ordinal;
    s.durable_id = source.attempt.durable_id;
    s.outcome = source.outcome;
    s.parent_tombstoned = source.parent_tombstoned;
    s.presence = placement.presence;
    s.world_anchor = placement.world_anchor;
    s.source_decision_digest = placement.source_decision_digest;
    s.source_attempt_digest = attempt_digest(source);
    s.state_before_coordinates = source.state_before_coordinates;
    s.state_after_coordinates = source.state_after_coordinates;
    s.state_after_classification = source.state_after_classification;
    s.state_after_recipe = source.state_after_recipe;
    return s;
}

bool different(const NativeSurfacePropChunkAttemptSnapshot &a,
    const NativeSurfacePropChunkAttemptSnapshot &b) noexcept {
    return a.presence != b.presence || !same_position(a.world_anchor, b.world_anchor)
        || a.source_attempt_digest != b.source_attempt_digest;
}

void validate_pair(const NativeSurfacePropSourceOrderedStream &stream,
    const NativeSurfacePropOrderedPlacement &placement,
    const NativeEffectiveTerrainSource &terrain) {
    const auto &pin = terrain.pin();
    if (!stream.source_receipt().matches_pin(pin)) reject();
    if (NativeSurfacePropOrderedPlacement::create(stream, terrain).content_digest()
        != placement.content_digest()) reject();
}

} // namespace

NativeSurfacePropChunkDifferenceRejected::NativeSurfacePropChunkDifferenceRejected()
    : std::invalid_argument("invalid native surface-prop chunk difference") {}

bool native_surface_prop_source_receipts_match(const NativeSurfacePropSourceReceipt &a,
    const NativeSurfacePropSourceReceipt &b) noexcept {
    return a.schema_revision == b.schema_revision
        && a.effective_source_digest == b.effective_source_digest
        && a.terrain_delta_revision == b.terrain_delta_revision
        && a.shaping_registry_revision == b.shaping_registry_revision
        && a.environment_profile_revision == b.environment_profile_revision
        && a.environment_profile_digest == b.environment_profile_digest;
}

Sha256Digest native_surface_prop_ordered_attempt_digest(const NativeSurfacePropOrderedAttempt &attempt) {
    return attempt_digest(attempt);
}

NativeSurfacePropChunkDifference NativeSurfacePropChunkDifference::create(
    const NativeSurfacePropSourceOrderedStream &before,
    const NativeSurfacePropOrderedPlacement &before_placements,
    const NativeSurfacePropSourceOrderedStream &after,
    const NativeSurfacePropOrderedPlacement &after_placements,
    const NativeEffectiveTerrainSource &terrain) {
    if (before.chunk_x() != after.chunk_x() || before.chunk_z() != after.chunk_z()
        || before.world_digest() != after.world_digest()
        || before.world_generation() != after.world_generation()
        || before.exclusion_digest() != after.exclusion_digest()
        || !native_surface_prop_source_receipts_match(before.source_receipt(), after.source_receipt())) reject();
    validate_pair(before, before_placements, terrain);
    validate_pair(after, after_placements, terrain);
    NativeSurfacePropChunkDifference result;
    result.chunk_x_ = before.chunk_x(); result.chunk_z_ = before.chunk_z();
    result.world_digest_ = before.world_digest(); result.world_generation_ = before.world_generation();
    result.world_source_identity_ = terrain.pin().physical_content_identity();
    result.before_final_rng_state_ = before.final_rng_state();
    result.after_final_rng_state_ = after.final_rng_state();
    for (std::size_t i = 0U; i < NativeSurfacePropAttemptStream::ATTEMPT_COUNT; ++i) {
        const auto old = snapshot(before.attempts()[i], before_placements.entries()[i]);
        const auto now = snapshot(after.attempts()[i], after_placements.entries()[i]);
        if (different(old, now)) result.changed_ordinals_.push_back({static_cast<std::uint32_t>(i), old, now});
    }
    Writer w;
    w.u8('S'); w.u8('P'); w.u8('D'); w.u8('F'); w.u8('1');
    w.digest(result.world_digest_); w.u64(result.world_generation_);
    w.digest(result.world_source_identity_.digest); w.i32(result.chunk_x_); w.i32(result.chunk_z_);
    w.u64(result.before_final_rng_state_); w.u64(result.after_final_rng_state_);
    w.digest(before_placements.content_digest()); w.digest(after_placements.content_digest());
    for (std::size_t i = 0U; i < NativeSurfacePropAttemptStream::ATTEMPT_COUNT; ++i) {
        w.digest(attempt_digest(before.attempts()[i]));
        w.digest(attempt_digest(after.attempts()[i]));
    }
    result.content_digest_ = sha256(w.bytes);
    return result;
}

bool NativeSurfacePropChunkDifference::channel_footprints_complete() const noexcept { return false; }
std::int32_t NativeSurfacePropChunkDifference::chunk_x() const noexcept { return chunk_x_; }
std::int32_t NativeSurfacePropChunkDifference::chunk_z() const noexcept { return chunk_z_; }
const Sha256Digest &NativeSurfacePropChunkDifference::world_digest() const noexcept { return world_digest_; }
std::uint64_t NativeSurfacePropChunkDifference::world_generation() const noexcept { return world_generation_; }
const WorldPhysicalContentIdentity &NativeSurfacePropChunkDifference::world_source_identity() const noexcept {
    return world_source_identity_;
}
const Sha256Digest &NativeSurfacePropChunkDifference::content_digest() const noexcept { return content_digest_; }
std::uint64_t NativeSurfacePropChunkDifference::before_final_rng_state() const noexcept {
    return before_final_rng_state_;
}
std::uint64_t NativeSurfacePropChunkDifference::after_final_rng_state() const noexcept {
    return after_final_rng_state_;
}
const std::vector<NativeSurfacePropOrdinalDifference> &NativeSurfacePropChunkDifference::changed_ordinals() const noexcept {
    return changed_ordinals_;
}

} // namespace voxel::world_backend
