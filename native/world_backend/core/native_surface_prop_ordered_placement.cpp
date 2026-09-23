#include "native_surface_prop_ordered_placement.hpp"

#include <cmath>
#include <cstring>

namespace voxel::world_backend {
namespace {

[[noreturn]] void reject() { throw NativeSurfacePropOrderedPlacementRejected(); }

class Writer final {
public:
    void u8(std::uint8_t v) { bytes.push_back(v); }
    void u32(std::uint32_t v) { for (int s = 24; s >= 0; s -= 8) u8(static_cast<std::uint8_t>(v >> s)); }
    void i32(std::int32_t v) { u32(static_cast<std::uint32_t>(v)); }
    void u64(std::uint64_t v) { for (int s = 56; s >= 0; s -= 8) u8(static_cast<std::uint8_t>(v >> s)); }
    void digest(const Sha256Digest &v) { bytes.insert(bytes.end(), v.begin(), v.end()); }
    void text(const std::string &v) { u32(static_cast<std::uint32_t>(v.size())); bytes.insert(bytes.end(), v.begin(), v.end()); }
    void f32(float v) { std::uint32_t bits; std::memcpy(&bits, &v, sizeof(bits)); u32(bits); }
    void f64(double v) { std::uint64_t bits; std::memcpy(&bits, &v, sizeof(bits)); u64(bits); }
    std::vector<std::uint8_t> bytes;
};

void position(Writer &w, const WorldFloat32Position &p) { w.f32(p.x); w.f32(p.y); w.f32(p.z); }

} // namespace

std::int32_t native_surface_prop_ordered_chunk_for_cell(std::int32_t cell) noexcept {
    constexpr std::int64_t span = NativeSurfacePropAttemptStream::CHUNK_CELLS;
    const std::int64_t wide = cell;
    const std::int64_t quotient = wide / span;
    const std::int64_t floor = quotient - static_cast<std::int64_t>(wide % span < 0);
    return static_cast<std::int32_t>(floor);
}

NativeSurfacePropOrderedPlacementRejected::NativeSurfacePropOrderedPlacementRejected()
    : std::invalid_argument("invalid native ordered surface-prop placement") {}

bool native_surface_prop_outcome_has_placement(const NativeSurfacePropClassificationOutcome outcome) {
    switch (outcome) {
        case NativeSurfacePropClassificationOutcome::ordinary_rock:
        case NativeSurfacePropClassificationOutcome::tree_36_draw:
        case NativeSurfacePropClassificationOutcome::tree_22_draw:
        case NativeSurfacePropClassificationOutcome::unported_iron_ore_cluster:
        case NativeSurfacePropClassificationOutcome::unported_copper_ore_cluster:
        case NativeSurfacePropClassificationOutcome::forage_recipe:
        case NativeSurfacePropClassificationOutcome::wildlife_recipe: return true;
        case NativeSurfacePropClassificationOutcome::skipped_before_prop_roll:
        case NativeSurfacePropClassificationOutcome::no_feature: return false;
    }
    reject();
}

NativeSurfacePropPlacementEntry resolve_native_surface_prop_ordered_placement_entry(
    const NativeSurfacePropOrderedAttempt &src, const std::uint32_t expected_ordinal,
    const std::int32_t expected_chunk_x, const std::int32_t expected_chunk_z,
    const WorldSourcePin &pin, const std::optional<std::uint64_t> previous_rng_state) {
    const auto &a = src.attempt;
    if (a.ordinal != expected_ordinal || a.durable_id.empty()
        || !pin.primary_terrain_shaping().owns_cell(a.cell_x, a.cell_z)
        || (previous_rng_state.has_value() && *previous_rng_state != src.state_before_coordinates)) reject();
    const auto chunk_x = native_surface_prop_ordered_chunk_for_cell(a.cell_x);
    const auto chunk_z = native_surface_prop_ordered_chunk_for_cell(a.cell_z);
    if (chunk_x != expected_chunk_x || chunk_z != expected_chunk_z) reject();
    NativeSurfacePropPlacementEntry e;
    e.ordinal = a.ordinal; e.durable_id = a.durable_id;
    e.cell_x = a.cell_x; e.cell_z = a.cell_z; e.chunk_x = chunk_x; e.chunk_z = chunk_z;
    e.outcome = src.outcome;
    if (src.parent_tombstoned) {
        if (src.source.has_value() || native_surface_prop_outcome_has_placement(src.outcome)) reject();
    } else {
        if (!src.source.has_value()) reject();
        e.source_decision_digest = src.source->classification.source_decision_digest;
        if (e.source_decision_digest == Sha256Digest{}) reject();
    }
    const bool anchor = !src.parent_tombstoned && native_surface_prop_outcome_has_placement(src.outcome);
    float anchor_y = 0.0F;
    if (anchor) {
        const auto &resolved = *src.source;
        if (!resolved.has_surface || !resolved.surface.found) reject();
        const auto &facts = resolved.surface;
        if (!(facts.physical_content_identity == pin.physical_content_identity())
            || facts.terrain_delta_revision != pin.terrain_delta_revision()
            || facts.shaping_registry_revision != pin.shaping_registry_revision()
            || !std::isfinite(facts.height_meters) || !std::isfinite(facts.world_anchor_y)) reject();
        e.presence = NativeSurfacePropPlacementPresence::anchored;
        e.mode = facts.mode; e.source_height_meters = facts.height_meters;
        e.biome = facts.biome; e.material = facts.material;
        e.solid_cell = facts.solid_cell; e.air_cell = facts.air_cell;
        anchor_y = facts.world_anchor_y;
    }
    const auto frame = resolve_native_surface_prop_chunk_frame(
        chunk_x, chunk_z, a.cell_x, a.cell_z, pin.definition().constants().cell_size_meters, anchor_y);
    e.chunk_origin = frame.chunk_origin; e.local_position = frame.local_position;
    if (anchor) e.world_anchor = frame.world_anchor;
    return e;
}

NativeSurfacePropOrderedPlacement NativeSurfacePropOrderedPlacement::create(
    const NativeSurfacePropSourceOrderedStream &ordered, const NativeEffectiveTerrainSource &terrain) {
    NativeSurfacePropOrderedPlacement result;
    const auto &pin = terrain.pin();
    if (!ordered.source_receipt().matches_pin(pin)) reject();
    result.world_source_identity_ = pin.physical_content_identity();
    result.definition_source_identity_ = pin.definition().physical_content_identity();
    result.terrain_delta_revision_ = pin.terrain_delta_revision();
    result.shaping_registry_revision_ = pin.shaping_registry_revision();
    result.final_rng_state_ = ordered.final_rng_state();
    Writer w;
    w.u8('S'); w.u8('P'); w.u8('O'); w.u8('1'); w.u32(SCHEMA_REVISION);
    w.digest(ordered.world_digest()); w.u64(ordered.world_generation());
    w.i32(ordered.chunk_x()); w.i32(ordered.chunk_z()); w.digest(ordered.exclusion_digest());
    w.u32(ordered.source_receipt().schema_revision);
    w.u32(ordered.source_receipt().environment_profile_revision);
    w.digest(ordered.source_receipt().environment_profile_digest);
    w.digest(result.world_source_identity_.digest); w.digest(result.definition_source_identity_.digest);
    w.u64(result.terrain_delta_revision_); w.u64(result.shaping_registry_revision_);
    w.u32(ordered.rng_seed()); w.u64(result.final_rng_state_);
    w.u32(static_cast<std::uint32_t>(result.entries_.size()));
    const auto &source = ordered.attempts();
    for (std::size_t i = 0; i < source.size(); ++i) {
        const auto &src = source[i];
        const NativeSurfacePropPlacementEntry e = resolve_native_surface_prop_ordered_placement_entry(
            src, static_cast<std::uint32_t>(i), ordered.chunk_x(), ordered.chunk_z(), pin,
            i == 0U ? std::nullopt : std::optional<std::uint64_t>(source[i - 1U].state_after_recipe));
        result.entries_[i] = e;
        w.u32(e.ordinal); w.text(e.durable_id); w.i32(e.cell_x); w.i32(e.cell_z);
        w.i32(e.chunk_x); w.i32(e.chunk_z);
        w.u8(src.parent_tombstoned ? 1U : 0U); w.digest(e.source_decision_digest);
        w.u8(static_cast<std::uint8_t>(e.outcome)); w.u8(static_cast<std::uint8_t>(e.presence));
        w.u8(static_cast<std::uint8_t>(e.mode)); w.f64(e.source_height_meters);
        w.u8(static_cast<std::uint8_t>(e.biome)); w.u8(static_cast<std::uint8_t>(e.material));
        w.i32(e.solid_cell.x); w.i32(e.solid_cell.y); w.i32(e.solid_cell.z);
        w.i32(e.air_cell.x); w.i32(e.air_cell.y); w.i32(e.air_cell.z);
        position(w, e.chunk_origin); position(w, e.local_position); position(w, e.world_anchor);
        w.u64(src.state_before_coordinates); w.u64(src.state_after_coordinates);
        w.u64(src.state_after_classification); w.u64(src.state_after_recipe);
    }
    result.canonical_binary_ = std::move(w.bytes);
    result.content_digest_ = sha256(result.canonical_binary_);
    return result;
}

const WorldPhysicalContentIdentity &NativeSurfacePropOrderedPlacement::world_source_identity() const noexcept { return world_source_identity_; }
const WorldPhysicalContentIdentity &NativeSurfacePropOrderedPlacement::definition_source_identity() const noexcept { return definition_source_identity_; }
std::uint64_t NativeSurfacePropOrderedPlacement::terrain_delta_revision() const noexcept { return terrain_delta_revision_; }
std::uint64_t NativeSurfacePropOrderedPlacement::shaping_registry_revision() const noexcept { return shaping_registry_revision_; }
std::uint64_t NativeSurfacePropOrderedPlacement::final_rng_state() const noexcept { return final_rng_state_; }
const std::array<NativeSurfacePropPlacementEntry, NativeSurfacePropAttemptStream::ATTEMPT_COUNT> &
NativeSurfacePropOrderedPlacement::entries() const noexcept { return entries_; }
const std::vector<std::uint8_t> &NativeSurfacePropOrderedPlacement::canonical_binary() const noexcept { return canonical_binary_; }
const Sha256Digest &NativeSurfacePropOrderedPlacement::content_digest() const noexcept { return content_digest_; }

} // namespace voxel::world_backend
