#include "native_surface_prop_placement_set.hpp"

#include <cstring>
#include <cmath>
#include <utility>

namespace voxel::world_backend {
namespace {

[[noreturn]] void reject() { throw NativeSurfacePropPlacementSetRejected(); }

bool has_nonzero_digest(const Sha256Digest &digest) noexcept {
    for (const std::uint8_t byte : digest) if (byte != 0U) return true;
    return false;
}

bool valid_outcome(const NativeSurfacePropClassificationOutcome outcome) noexcept {
    return outcome == NativeSurfacePropClassificationOutcome::skipped_before_prop_roll
        || outcome == NativeSurfacePropClassificationOutcome::no_feature
        || outcome == NativeSurfacePropClassificationOutcome::ordinary_rock
        || outcome == NativeSurfacePropClassificationOutcome::broadleaf_tree
        || outcome == NativeSurfacePropClassificationOutcome::conifer_tree
        || outcome == NativeSurfacePropClassificationOutcome::unported_iron_ore_cluster
        || outcome == NativeSurfacePropClassificationOutcome::unported_copper_ore_cluster
        || outcome == NativeSurfacePropClassificationOutcome::forage_recipe
        || outcome == NativeSurfacePropClassificationOutcome::wildlife_recipe;
}

bool physical_outcome(const NativeSurfacePropClassificationOutcome outcome) noexcept {
    return outcome == NativeSurfacePropClassificationOutcome::ordinary_rock
        || outcome == NativeSurfacePropClassificationOutcome::broadleaf_tree
        || outcome == NativeSurfacePropClassificationOutcome::conifer_tree
        || outcome == NativeSurfacePropClassificationOutcome::unported_iron_ore_cluster
        || outcome == NativeSurfacePropClassificationOutcome::unported_copper_ore_cluster
        || outcome == NativeSurfacePropClassificationOutcome::forage_recipe
        || outcome == NativeSurfacePropClassificationOutcome::wildlife_recipe;
}

std::int32_t floor_chunk(const std::int32_t cell) noexcept {
    constexpr std::int32_t span = NativeSurfacePropAttemptStream::CHUNK_CELLS;
    const std::int32_t quotient = cell / span;
    return quotient - static_cast<std::int32_t>(cell % span < 0);
}

float source_float_product(const std::int64_t cell, const double cell_size) noexcept {
    return static_cast<float>(static_cast<double>(cell) * cell_size);
}

float source_transform_sum(const float origin, const float local) noexcept {
    return static_cast<float>(static_cast<double>(origin) + static_cast<double>(local));
}

class CanonicalWriter final {
public:
    void u8(const std::uint8_t value) { bytes_.push_back(value); }
    void u32(const std::uint32_t value) {
        for (int shift = 24; shift >= 0; shift -= 8) u8(static_cast<std::uint8_t>(value >> shift));
    }
    void i32(const std::int32_t value) { u32(static_cast<std::uint32_t>(value)); }
    void u64(const std::uint64_t value) {
        for (int shift = 56; shift >= 0; shift -= 8) u8(static_cast<std::uint8_t>(value >> shift));
    }
    void digest(const Sha256Digest &value) { bytes_.insert(bytes_.end(), value.begin(), value.end()); }
    void text(const std::string &value) {
        u32(static_cast<std::uint32_t>(value.size()));
        bytes_.insert(bytes_.end(), value.begin(), value.end());
    }
    void number(const float value) {
        std::uint32_t bits = 0U;
        std::memcpy(&bits, &value, sizeof(bits));
        u32(bits);
    }
    void number(const double value) {
        std::uint64_t bits = 0U;
        std::memcpy(&bits, &value, sizeof(bits));
        u64(bits);
    }
    std::vector<std::uint8_t> finish() { return std::move(bytes_); }
private:
    std::vector<std::uint8_t> bytes_;
};

std::vector<std::uint8_t> canonical_placement_binary(
    const NativeSurfacePropSourceReceipt &source_receipt,
    const WorldPhysicalContentIdentity &world_source_identity,
    const WorldPhysicalContentIdentity &definition_source_identity,
    const std::array<NativeSurfacePropPlacementEntry, NativeSurfacePropAttemptStream::ATTEMPT_COUNT> &entries) {
    CanonicalWriter writer;
    writer.u8('S'); writer.u8('P'); writer.u8('P'); writer.u8('2');
    writer.u32(NativeSurfacePropPlacementSet::SCHEMA_REVISION);
    writer.u32(source_receipt.schema_revision); writer.digest(source_receipt.effective_source_digest);
    writer.u64(source_receipt.terrain_delta_revision); writer.u64(source_receipt.shaping_registry_revision);
    writer.u32(source_receipt.environment_profile_revision); writer.digest(source_receipt.environment_profile_digest);
    writer.digest(world_source_identity.digest);
    writer.digest(definition_source_identity.digest);
    writer.u32(static_cast<std::uint32_t>(entries.size()));
    for (const NativeSurfacePropPlacementEntry &entry : entries) {
        writer.u32(entry.ordinal); writer.text(entry.durable_id); writer.i32(entry.cell_x); writer.i32(entry.cell_z);
        writer.i32(entry.chunk_x); writer.i32(entry.chunk_z);
        writer.number(entry.chunk_origin.x); writer.number(entry.chunk_origin.y); writer.number(entry.chunk_origin.z);
        writer.number(entry.local_position.x); writer.number(entry.local_position.y); writer.number(entry.local_position.z);
        writer.digest(entry.source_decision_digest); writer.u8(static_cast<std::uint8_t>(entry.outcome));
        writer.u8(static_cast<std::uint8_t>(entry.presence));
        writer.u8(static_cast<std::uint8_t>(entry.mode)); writer.number(entry.source_height_meters);
        writer.u8(static_cast<std::uint8_t>(entry.biome)); writer.u8(static_cast<std::uint8_t>(entry.material));
        writer.i32(entry.solid_cell.x); writer.i32(entry.solid_cell.y); writer.i32(entry.solid_cell.z);
        writer.i32(entry.air_cell.x); writer.i32(entry.air_cell.y); writer.i32(entry.air_cell.z);
        writer.number(entry.world_anchor.x); writer.number(entry.world_anchor.y); writer.number(entry.world_anchor.z);
    }
    return writer.finish();
}

} // namespace

NativeSurfacePropPlacementSetRejected::NativeSurfacePropPlacementSetRejected()
    : std::invalid_argument("invalid native surface-prop placement set") {}

NativeSurfacePropChunkFrame resolve_native_surface_prop_chunk_frame(
    const std::int32_t chunk_x, const std::int32_t chunk_z,
    const std::int32_t cell_x, const std::int32_t cell_z,
    const double cell_size_meters, const float anchor_y) {
    const std::int64_t start_x = static_cast<std::int64_t>(chunk_x) * NativeSurfacePropAttemptStream::CHUNK_CELLS;
    const std::int64_t start_z = static_cast<std::int64_t>(chunk_z) * NativeSurfacePropAttemptStream::CHUNK_CELLS;
    const std::int64_t local_x = static_cast<std::int64_t>(cell_x) - start_x;
    const std::int64_t local_z = static_cast<std::int64_t>(cell_z) - start_z;
    if (!std::isfinite(cell_size_meters) || cell_size_meters <= 0.0 || !std::isfinite(anchor_y)
        || floor_chunk(cell_x) != chunk_x || floor_chunk(cell_z) != chunk_z
        || local_x < NativeSurfacePropAttemptStream::EDGE_MARGIN_CELLS
        || local_x > NativeSurfacePropAttemptStream::CHUNK_CELLS - NativeSurfacePropAttemptStream::EDGE_MARGIN_CELLS
        || local_z < NativeSurfacePropAttemptStream::EDGE_MARGIN_CELLS
        || local_z > NativeSurfacePropAttemptStream::CHUNK_CELLS - NativeSurfacePropAttemptStream::EDGE_MARGIN_CELLS) reject();
    NativeSurfacePropChunkFrame result;
    result.chunk_origin = {
        source_float_product(start_x, cell_size_meters), 0.0F,
        source_float_product(start_z, cell_size_meters)};
    result.local_position = {
        source_float_product(local_x, cell_size_meters), anchor_y,
        source_float_product(local_z, cell_size_meters)};
    result.world_anchor = {
        source_transform_sum(result.chunk_origin.x, result.local_position.x), anchor_y,
        source_transform_sum(result.chunk_origin.z, result.local_position.z)};
    if (!std::isfinite(result.chunk_origin.x) || !std::isfinite(result.chunk_origin.z)
        || !std::isfinite(result.local_position.x) || !std::isfinite(result.local_position.z)
        || !std::isfinite(result.world_anchor.x) || !std::isfinite(result.world_anchor.z)) reject();
    return result;
}

NativeSurfacePropPlacementSet::NativeSurfacePropPlacementSet(
    NativeSurfacePropSourceReceipt source_receipt,
    WorldPhysicalContentIdentity world_source_identity,
    WorldPhysicalContentIdentity definition_source_identity,
    const std::uint64_t terrain_delta_revision, const std::uint64_t shaping_registry_revision,
    std::array<NativeSurfacePropPlacementEntry, NativeSurfacePropAttemptStream::ATTEMPT_COUNT> entries,
    std::vector<std::uint8_t> canonical_binary, Sha256Digest content_digest) noexcept
    : source_receipt_(std::move(source_receipt)), world_source_identity_(world_source_identity),
      definition_source_identity_(definition_source_identity),
      terrain_delta_revision_(terrain_delta_revision), shaping_registry_revision_(shaping_registry_revision),
      entries_(std::move(entries)), canonical_binary_(std::move(canonical_binary)), content_digest_(content_digest) {}

NativeSurfacePropPlacementSet NativeSurfacePropPlacementSet::create(
    const NativeSurfacePropAttemptStream &attempts,
    const NativeSurfacePropBaselineStream &baseline,
    NativeSurfacePropSourceReceipt source_receipt,
    const NativeEffectiveTerrainSource &terrain) {
    const WorldSourcePin &pin = terrain.pin();
    if (!source_receipt.matches_pin(pin)) reject();
    const WorldPhysicalContentIdentity identity = pin.physical_content_identity();
    const WorldPhysicalContentIdentity definition_identity = pin.definition().physical_content_identity();
    // Both identities are SHA-256 outputs of admitted immutable sources. A
    // zero byte pattern is not a sentinel in that domain; rejecting it here
    // would invent a second source-admission rule.
    std::array<NativeSurfacePropPlacementEntry, NativeSurfacePropAttemptStream::ATTEMPT_COUNT> entries{};
    const auto &attempt_entries = attempts.attempts();
    const auto &baseline_entries = baseline.entries();
    const std::int32_t chunk_x = floor_chunk(attempt_entries[0].cell_x);
    const std::int32_t chunk_z = floor_chunk(attempt_entries[0].cell_z);
    const double cell_size = pin.definition().constants().cell_size_meters;
    for (std::size_t index = 0U; index < entries.size(); ++index) {
        const NativeSurfacePropAttempt &attempt = attempt_entries[index];
        const NativeSurfacePropBaselineEntry &baseline_entry = baseline_entries[index];
        if (floor_chunk(attempt.cell_x) != chunk_x || floor_chunk(attempt.cell_z) != chunk_z
            || !pin.primary_terrain_shaping().owns_cell(attempt.cell_x, attempt.cell_z)
            || attempt.ordinal != index
            || baseline_entry.ordinal != attempt.ordinal || baseline_entry.durable_id != attempt.durable_id
            || baseline_entry.cell_x != attempt.cell_x || baseline_entry.cell_z != attempt.cell_z
            || !has_nonzero_digest(baseline_entry.source_decision_digest)
            || !valid_outcome(baseline_entry.outcome)) reject();
        const bool must_anchor = physical_outcome(baseline_entry.outcome);
        NativeSurfacePropPlacementEntry entry;
        entry.ordinal = attempt.ordinal;
        entry.durable_id = attempt.durable_id;
        entry.cell_x = attempt.cell_x;
        entry.cell_z = attempt.cell_z;
        entry.chunk_x = chunk_x;
        entry.chunk_z = chunk_z;
        const NativeSurfacePropChunkFrame absent_frame = resolve_native_surface_prop_chunk_frame(
            chunk_x, chunk_z, attempt.cell_x, attempt.cell_z, cell_size, 0.0F);
        entry.chunk_origin = absent_frame.chunk_origin;
        entry.local_position = absent_frame.local_position;
        entry.source_decision_digest = baseline_entry.source_decision_digest;
        entry.outcome = baseline_entry.outcome;
        if (must_anchor) {
            NativeSurfacePropSpawnFacts facts;
            try {
                facts = terrain.sample_surface_prop_spawn(
                    {attempt.cell_x, attempt.cell_z, WorldQueryIntent::gameplay});
            } catch (const std::exception &) {
                reject();
            }
            // The immutable resolver itself constructs pin identity/revisions,
            // column coordinates, adjacent support cells, and solid material.
            // Rechecking those fields here cannot reject a caller mutation.
            // Missing support is a real outcome. Chunk-frame construction
            // below already rejects a nonfinite float32 anchor.
            if (!facts.found) reject();
            entry.presence = NativeSurfacePropPlacementPresence::anchored;
            entry.mode = facts.mode;
            entry.source_height_meters = facts.height_meters;
            entry.biome = facts.biome;
            entry.material = facts.material;
            entry.solid_cell = facts.solid_cell;
            entry.air_cell = facts.air_cell;
            const NativeSurfacePropChunkFrame frame = resolve_native_surface_prop_chunk_frame(
                chunk_x, chunk_z, attempt.cell_x, attempt.cell_z, cell_size, facts.world_anchor_y);
            entry.local_position = frame.local_position;
            entry.world_anchor = frame.world_anchor;
        }
        entries[index] = std::move(entry);
    }
    std::vector<std::uint8_t> canonical = canonical_placement_binary(
        source_receipt, identity, definition_identity, entries);
    const Sha256Digest digest = sha256(canonical);
    return NativeSurfacePropPlacementSet(
        std::move(source_receipt), identity, definition_identity,
        pin.terrain_delta_revision(), pin.shaping_registry_revision(),
        std::move(entries), std::move(canonical), digest);
}

const NativeSurfacePropSourceReceipt &NativeSurfacePropPlacementSet::source_receipt() const noexcept {
    return source_receipt_;
}
const WorldPhysicalContentIdentity &NativeSurfacePropPlacementSet::world_source_identity() const noexcept {
    return world_source_identity_;
}
const WorldPhysicalContentIdentity &NativeSurfacePropPlacementSet::definition_source_identity() const noexcept {
    return definition_source_identity_;
}
std::uint64_t NativeSurfacePropPlacementSet::terrain_delta_revision() const noexcept {
    return terrain_delta_revision_;
}
std::uint64_t NativeSurfacePropPlacementSet::shaping_registry_revision() const noexcept {
    return shaping_registry_revision_;
}
const std::array<NativeSurfacePropPlacementEntry, NativeSurfacePropAttemptStream::ATTEMPT_COUNT> &
NativeSurfacePropPlacementSet::entries() const noexcept { return entries_; }
const std::vector<std::uint8_t> &NativeSurfacePropPlacementSet::canonical_binary() const noexcept {
    return canonical_binary_;
}
const Sha256Digest &NativeSurfacePropPlacementSet::content_digest() const noexcept { return content_digest_; }

} // namespace voxel::world_backend
