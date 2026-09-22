#include "native_surface_prop_placement_set.hpp"

#include <cstring>
#include <limits>
#include <utility>

namespace voxel::world_backend {
namespace {

[[noreturn]] void reject() { throw NativeSurfacePropPlacementSetRejected(); }

bool has_nonzero_digest(const Sha256Digest &digest) noexcept {
    for (const std::uint8_t byte : digest) if (byte != 0U) return true;
    return false;
}

bool valid_source_receipt(const NativeSurfacePropSourceReceipt &receipt) noexcept {
    return receipt.schema_revision != 0U && receipt.terrain_revision != 0U
        && has_nonzero_digest(receipt.terrain_digest)
        && receipt.environment_profile_revision != 0U
        && has_nonzero_digest(receipt.environment_profile_digest);
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

bool default_cell(const CellCoord cell) noexcept {
    return cell.x == 0 && cell.y == 0 && cell.z == 0;
}

class CanonicalWriter final {
public:
    void u8(const std::uint8_t value) { bytes_.push_back(value); }
    void u32(const std::uint32_t value) {
        for (int shift = 24; shift >= 0; shift -= 8) u8(static_cast<std::uint8_t>(value >> shift));
    }
    void i32(const std::int32_t value) { u32(static_cast<std::uint32_t>(value)); }
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
    std::vector<std::uint8_t> finish() { return std::move(bytes_); }
private:
    std::vector<std::uint8_t> bytes_;
};

std::vector<std::uint8_t> canonical_placement_binary(
    const NativeSurfacePropSourceReceipt &source_receipt,
    const WorldPhysicalContentIdentity &world_source_identity,
    const std::array<NativeSurfacePropPlacementEntry, NativeSurfacePropAttemptStream::ATTEMPT_COUNT> &entries) {
    CanonicalWriter writer;
    writer.u8('S'); writer.u8('P'); writer.u8('P'); writer.u8('1');
    writer.u32(NativeSurfacePropPlacementSet::SCHEMA_REVISION);
    writer.u32(source_receipt.schema_revision); writer.u32(static_cast<std::uint32_t>(source_receipt.terrain_revision >> 32U));
    writer.u32(static_cast<std::uint32_t>(source_receipt.terrain_revision)); writer.digest(source_receipt.terrain_digest);
    writer.u32(source_receipt.environment_profile_revision); writer.digest(source_receipt.environment_profile_digest);
    writer.digest(world_source_identity.digest);
    writer.u32(static_cast<std::uint32_t>(entries.size()));
    for (const NativeSurfacePropPlacementEntry &entry : entries) {
        writer.u32(entry.ordinal); writer.text(entry.durable_id); writer.i32(entry.cell_x); writer.i32(entry.cell_z);
        writer.digest(entry.source_decision_digest); writer.u8(static_cast<std::uint8_t>(entry.outcome));
        writer.u8(static_cast<std::uint8_t>(entry.presence));
        writer.i32(entry.solid_cell.x); writer.i32(entry.solid_cell.y); writer.i32(entry.solid_cell.z);
        writer.i32(entry.air_cell.x); writer.i32(entry.air_cell.y); writer.i32(entry.air_cell.z);
        writer.number(entry.world_anchor.x); writer.number(entry.world_anchor.y); writer.number(entry.world_anchor.z);
    }
    return writer.finish();
}

} // namespace

NativeSurfacePropPlacementSetRejected::NativeSurfacePropPlacementSetRejected()
    : std::invalid_argument("invalid native surface-prop placement set") {}

NativeSurfacePropPlacementSet::NativeSurfacePropPlacementSet(
    NativeSurfacePropSourceReceipt source_receipt,
    WorldPhysicalContentIdentity world_source_identity,
    std::array<NativeSurfacePropPlacementEntry, NativeSurfacePropAttemptStream::ATTEMPT_COUNT> entries,
    std::vector<std::uint8_t> canonical_binary, Sha256Digest content_digest) noexcept
    : source_receipt_(std::move(source_receipt)), world_source_identity_(world_source_identity),
      entries_(std::move(entries)), canonical_binary_(std::move(canonical_binary)), content_digest_(content_digest) {}

NativeSurfacePropPlacementSet NativeSurfacePropPlacementSet::create(
    const NativeSurfacePropAttemptStream &attempts,
    const NativeSurfacePropBaselineStream &baseline,
    NativeSurfacePropSourceReceipt source_receipt,
    const WorldSourceDefinition &world_source,
    const std::array<NativeSurfacePropPlacementReceipt, NativeSurfacePropAttemptStream::ATTEMPT_COUNT> &receipts) {
    if (!valid_source_receipt(source_receipt)) reject();
    std::array<NativeSurfacePropPlacementEntry, NativeSurfacePropAttemptStream::ATTEMPT_COUNT> entries{};
    const auto &attempt_entries = attempts.attempts();
    const auto &baseline_entries = baseline.entries();
    for (std::size_t index = 0U; index < entries.size(); ++index) {
        const NativeSurfacePropAttempt &attempt = attempt_entries[index];
        const NativeSurfacePropBaselineEntry &baseline_entry = baseline_entries[index];
        const NativeSurfacePropPlacementReceipt &receipt = receipts[index];
        if (attempt.ordinal != index || receipt.ordinal != index
            || baseline_entry.ordinal != attempt.ordinal || baseline_entry.durable_id != attempt.durable_id
            || baseline_entry.cell_x != attempt.cell_x || baseline_entry.cell_z != attempt.cell_z
            || !has_nonzero_digest(baseline_entry.source_decision_digest)
            || !valid_outcome(baseline_entry.outcome)) reject();
        const bool must_anchor = physical_outcome(baseline_entry.outcome);
        if ((receipt.presence == NativeSurfacePropPlacementPresence::anchored) != must_anchor) reject();
        NativeSurfacePropPlacementEntry entry;
        entry.ordinal = attempt.ordinal;
        entry.durable_id = attempt.durable_id;
        entry.cell_x = attempt.cell_x;
        entry.cell_z = attempt.cell_z;
        entry.source_decision_digest = baseline_entry.source_decision_digest;
        entry.outcome = baseline_entry.outcome;
        entry.presence = receipt.presence;
        if (receipt.presence == NativeSurfacePropPlacementPresence::absent) {
            if (!default_cell(receipt.solid_cell) || !default_cell(receipt.air_cell)) reject();
        } else if (receipt.presence == NativeSurfacePropPlacementPresence::anchored) {
            if (receipt.solid_cell.x != attempt.cell_x || receipt.solid_cell.z != attempt.cell_z
                || receipt.air_cell.x != attempt.cell_x || receipt.air_cell.z != attempt.cell_z
                || receipt.solid_cell.y == std::numeric_limits<std::int32_t>::max()
                || receipt.air_cell.y != receipt.solid_cell.y + 1) reject();
            entry.solid_cell = receipt.solid_cell;
            entry.air_cell = receipt.air_cell;
            entry.world_anchor = resolve_world_query(world_source,
                WorldLatticeQuery{receipt.air_cell, WorldQueryIntent::gameplay}).lattice_position;
        } else {
            reject();
        }
        entries[index] = std::move(entry);
    }
    const WorldPhysicalContentIdentity identity = world_source.physical_content_identity();
    if (!has_nonzero_digest(identity.digest)) reject();
    std::vector<std::uint8_t> canonical = canonical_placement_binary(source_receipt, identity, entries);
    return NativeSurfacePropPlacementSet(
        std::move(source_receipt), identity, std::move(entries), canonical, sha256(canonical));
}

const NativeSurfacePropSourceReceipt &NativeSurfacePropPlacementSet::source_receipt() const noexcept {
    return source_receipt_;
}
const WorldPhysicalContentIdentity &NativeSurfacePropPlacementSet::world_source_identity() const noexcept {
    return world_source_identity_;
}
const std::array<NativeSurfacePropPlacementEntry, NativeSurfacePropAttemptStream::ATTEMPT_COUNT> &
NativeSurfacePropPlacementSet::entries() const noexcept { return entries_; }
const std::vector<std::uint8_t> &NativeSurfacePropPlacementSet::canonical_binary() const noexcept {
    return canonical_binary_;
}
const Sha256Digest &NativeSurfacePropPlacementSet::content_digest() const noexcept { return content_digest_; }

} // namespace voxel::world_backend
