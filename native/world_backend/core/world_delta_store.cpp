#include "world_delta_store.hpp"

#include <algorithm>
#include <cmath>
#include <cstring>
#include <limits>
#include <map>
#include <set>
#include <type_traits>
#include <utility>

namespace voxel::world_backend {
namespace {

struct NamespaceCellKey {
    WorldDeltaNamespace name_space;
    CellCoord coordinate;
};

struct NamespaceCellKeyLess {
    bool operator()(const NamespaceCellKey &left, const NamespaceCellKey &right) const noexcept {
        if (left.coordinate.z != right.coordinate.z) return left.coordinate.z < right.coordinate.z;
        if (left.coordinate.y != right.coordinate.y) return left.coordinate.y < right.coordinate.y;
        if (left.coordinate.x != right.coordinate.x) return left.coordinate.x < right.coordinate.x;
        return static_cast<std::uint8_t>(left.name_space) < static_cast<std::uint8_t>(right.name_space);
    }
};

struct SectionKeyLess {
    bool operator()(const WorldDeltaSectionKey &left, const WorldDeltaSectionKey &right) const noexcept {
        if (left.section.z != right.section.z) return left.section.z < right.section.z;
        if (left.section.y != right.section.y) return left.section.y < right.section.y;
        return left.section.x < right.section.x;
    }
};

struct CellCoordLess {
    bool operator()(const CellCoord &left, const CellCoord &right) const noexcept {
        if (left.z != right.z) return left.z < right.z;
        if (left.y != right.y) return left.y < right.y;
        return left.x < right.x;
    }
};

class CanonicalWriter {
public:
    void u8(const std::uint8_t value) { bytes_.push_back(value); }
    void u64(const std::uint64_t value) {
        for (unsigned shift = 0; shift < 64U; shift += 8U) u8(static_cast<std::uint8_t>(value >> shift));
    }
    void i32(const std::int32_t value) {
        const auto unsigned_value = static_cast<std::uint32_t>(value);
        for (unsigned shift = 0; shift < 32U; shift += 8U) u8(static_cast<std::uint8_t>(unsigned_value >> shift));
    }
    void binary64(const double value) {
        std::uint64_t bits = 0;
        static_assert(sizeof(bits) == sizeof(value));
        std::memcpy(&bits, &value, sizeof(bits));
        u64(bits);
    }
    void text(const std::string &value) {
        u64(static_cast<std::uint64_t>(value.size()));
        bytes_.insert(bytes_.end(), value.begin(), value.end());
    }
    void binary(const std::vector<std::uint8_t> &value) {
        u64(static_cast<std::uint64_t>(value.size()));
        bytes_.insert(bytes_.end(), value.begin(), value.end());
    }
    void operation(const WorldDeltaOperation &operation) {
        u8(static_cast<std::uint8_t>(operation.name_space));
        i32(operation.coordinate.x); i32(operation.coordinate.y); i32(operation.coordinate.z);
        u8(static_cast<std::uint8_t>(operation.kind));
        u8(operation.state.has_value() ? 1U : 0U);
        if (operation.state) {
            binary64(operation.state->density);
            u8(operation.state->solid ? 1U : 0U);
            u8(static_cast<std::uint8_t>(operation.state->material));
            u8(static_cast<std::uint8_t>(operation.state->resolved_biome));
            u8(static_cast<std::uint8_t>(operation.state->fluid));
        }
    }
    void native_cell_state(const NativeCellState &state) {
        i32(state.cell.x); i32(state.cell.y); i32(state.cell.z);
        i32(state.section.x); i32(state.section.y); i32(state.section.z);
        i32(state.local_cell.x); i32(state.local_cell.y); i32(state.local_cell.z);
        u8(static_cast<std::uint8_t>(state.material));
        u8(static_cast<std::uint8_t>(state.biome));
        u8(state.solid ? 1U : 0U);
        binary64(state.density);
        u8(static_cast<std::uint8_t>(state.fluid));
        u8(state.light.sky); u8(state.light.block);
        // Typed admissions reject any record other than an edited,
        // non-generated state before reaching the journal.  Encoding the
        // invariant directly avoids coverage-only impossible states while
        // retaining the full canonical record shape.
        u8(0U); u8(1U);
        // Metadata has its own self-describing canonical encoding.  The
        // outer length keeps the typed journal unambiguous without inventing
        // a second recursive metadata serialization here.
        binary(state.metadata.canonical_binary());
        u8(state.block_id.has_value() ? 1U : 0U);
        if (state.block_id) text(state.block_id->value());
    }
    void typed_record(const NativeTypedWorldStateRecord &record) {
        u8(static_cast<std::uint8_t>(record.name_space));
        u8(static_cast<std::uint8_t>(record.persistence));
        native_cell_state(record.state);
    }
    std::vector<std::uint8_t> finish() { return std::move(bytes_); }
private:
    std::vector<std::uint8_t> bytes_;
};

bool valid_namespace(const WorldDeltaNamespace value) noexcept {
    return value == WorldDeltaNamespace::terrain_override || value == WorldDeltaNamespace::scene_overlay;
}

bool valid_kind(const WorldDeltaOperationKind value) noexcept {
    return value == WorldDeltaOperationKind::set || value == WorldDeltaOperationKind::clear;
}

bool valid_state(const WorldDeltaState &state) noexcept {
    const auto material = static_cast<std::uint8_t>(state.material);
    const auto biome = static_cast<std::uint8_t>(state.resolved_biome);
    const bool material_valid = material <= static_cast<std::uint8_t>(TerrainMaterialId::lava);
    const bool biome_valid = biome <= static_cast<std::uint8_t>(TerrainBiomeId::alpine);
    const bool fluid_valid = state.fluid == TerrainFluidId::none || state.fluid == TerrainFluidId::water
        || state.fluid == TerrainFluidId::lava;
    return std::isfinite(state.density) && state.solid == (state.density >= 0.0)
        && material_valid && biome_valid && fluid_valid
        && (!state.solid || state.material != TerrainMaterialId::air)
        && (state.solid || state.material == TerrainMaterialId::air || state.material == TerrainMaterialId::water
            || state.material == TerrainMaterialId::lava)
        && (state.fluid != TerrainFluidId::water || state.material == TerrainMaterialId::water)
        && (state.fluid != TerrainFluidId::lava || state.material == TerrainMaterialId::lava);
}

void validate_operation(const WorldDeltaOperation &operation) {
    if (!valid_namespace(operation.name_space) || !valid_kind(operation.kind)) {
        throw WorldDeltaRejected(WorldDeltaRejectReason::invalid_transaction);
    }
    if (operation.kind == WorldDeltaOperationKind::set) {
        if (!operation.state || !valid_state(*operation.state)) {
            throw WorldDeltaRejected(WorldDeltaRejectReason::invalid_transaction);
        }
    } else if (operation.state) {
        throw WorldDeltaRejected(WorldDeltaRejectReason::invalid_transaction);
    }
}

std::vector<std::uint8_t> canonical_transaction(const WorldDeltaTransaction &transaction) {
    if (transaction.transaction_id.empty() || transaction.transaction_id.find('\0') != std::string::npos
        || transaction.operations.empty()) {
        throw WorldDeltaRejected(WorldDeltaRejectReason::invalid_transaction);
    }
    std::vector<WorldDeltaOperation> operations = transaction.operations;
    std::sort(operations.begin(), operations.end(), [](const WorldDeltaOperation &left, const WorldDeltaOperation &right) {
        const NamespaceCellKeyLess less;
        return less({left.name_space, left.coordinate}, {right.name_space, right.coordinate});
    });
    for (std::size_t index = 0; index < operations.size(); ++index) {
        validate_operation(operations[index]);
        if (index != 0U && operations[index - 1U].name_space == operations[index].name_space
            && operations[index - 1U].coordinate == operations[index].coordinate) {
            throw WorldDeltaRejected(WorldDeltaRejectReason::invalid_transaction);
        }
    }
    CanonicalWriter writer;
    writer.u8('W'); writer.u8('D'); writer.u8('T'); writer.u8('X');
    writer.text(transaction.transaction_id);
    writer.u64(transaction.expected_revision);
    writer.u64(static_cast<std::uint64_t>(operations.size()));
    for (const WorldDeltaOperation &operation : operations) writer.operation(operation);
    return writer.finish();
}

struct ValidatedTypedAdmission {
    NativeTypedWorldStateSnapshot durable_snapshot = NativeTypedWorldStateSnapshot::create({});
    std::vector<NativeTypedWorldStateRecord> transient_overlays;
};

ValidatedTypedAdmission validate_typed_admission(const WorldTypedStateAdmission &admission) {
    if (admission.transaction_id.empty() || admission.transaction_id.find('\0') != std::string::npos) {
        throw WorldDeltaRejected(WorldDeltaRejectReason::invalid_transaction);
    }
    try {
        NativeTypedWorldStateStore validator;
        validator.admit_durable_snapshot(admission.durable_snapshot);
        validator.replace_transient_overlays(admission.transient_overlays);
        return {validator.durable_snapshot(), validator.transient_overlays()};
    } catch (const NativeCellStateRejected &) {
        throw WorldDeltaRejected(WorldDeltaRejectReason::invalid_transaction);
    }
}

std::vector<std::uint8_t> canonical_typed_admission(
    const WorldTypedStateAdmission &admission, const ValidatedTypedAdmission &validated) {
    CanonicalWriter writer;
    // Different discriminator from WDTX means a transaction ID cannot be
    // replayed across the legacy delta and typed-state APIs.
    // WTY2 is intentionally distinct from WTY S: native recursive metadata
    // and optional block identity have a different canonical record schema.
    writer.u8('W'); writer.u8('T'); writer.u8('Y'); writer.u8('2');
    writer.text(admission.transaction_id);
    writer.u64(admission.expected_revision);
    writer.u64(static_cast<std::uint64_t>(validated.durable_snapshot.records().size()));
    for (const NativeTypedWorldStateRecord &record : validated.durable_snapshot.records()) writer.typed_record(record);
    writer.u64(static_cast<std::uint64_t>(validated.transient_overlays.size()));
    for (const NativeTypedWorldStateRecord &record : validated.transient_overlays) writer.typed_record(record);
    return writer.finish();
}

std::vector<WorldDeltaOperation> sorted_operations(const WorldDeltaTransaction &transaction) {
    std::vector<WorldDeltaOperation> operations = transaction.operations;
    std::sort(operations.begin(), operations.end(), [](const WorldDeltaOperation &left, const WorldDeltaOperation &right) {
        const NamespaceCellKeyLess less;
        return less({left.name_space, left.coordinate}, {right.name_space, right.coordinate});
    });
    return operations;
}

WorldDeltaSectionKey section_key_for(const CellCoord &coordinate) {
    // SECTION_SIZE is a positive compile-time constant, so split_cell cannot
    // reject this request. The optional is only part of the generic coordinate
    // helper's public contract for caller-supplied divisors.
    return {split_cell(coordinate, WorldDeltaStore::SECTION_SIZE).value().section};
}

void add_conservative_invalidation_neighborhood(
    const WorldDeltaSectionKey &owner, std::set<WorldDeltaSectionKey, SectionKeyLess> &affected) {
    for (std::int32_t z_offset = -1; z_offset <= 1; ++z_offset) {
        for (std::int32_t y_offset = -1; y_offset <= 1; ++y_offset) {
            for (std::int32_t x_offset = -1; x_offset <= 1; ++x_offset) {
                affected.insert({{
                    static_cast<std::int32_t>(owner.section.x + x_offset),
                    static_cast<std::int32_t>(owner.section.y + y_offset),
                    static_cast<std::int32_t>(owner.section.z + z_offset),
                }});
            }
        }
    }
}

void add_changed_typed_cells(
    const std::vector<NativeTypedWorldStateRecord> &before,
    const std::vector<NativeTypedWorldStateRecord> &after,
    std::set<CellCoord, CellCoordLess> &changed_cells) {
    std::size_t before_index = 0;
    std::size_t after_index = 0;
    const CellCoordLess less;
    while (before_index < before.size() || after_index < after.size()) {
        if (before_index == before.size()) {
            changed_cells.insert(after[after_index++].state.cell);
        } else if (after_index == after.size()) {
            changed_cells.insert(before[before_index++].state.cell);
        } else if (less(before[before_index].state.cell, after[after_index].state.cell)) {
            changed_cells.insert(before[before_index++].state.cell);
        } else if (less(after[after_index].state.cell, before[before_index].state.cell)) {
            changed_cells.insert(after[after_index++].state.cell);
        } else {
            if (!(before[before_index] == after[after_index])) {
                changed_cells.insert(before[before_index].state.cell);
            }
            ++before_index;
            ++after_index;
        }
    }
}

bool fits_record_capacity(
    const WorldDeltaSnapshotState &state, const WorldDeltaStoreLimits &limits) noexcept;

const char *reject_message(const WorldDeltaRejectReason reason) noexcept {
    if (reason == WorldDeltaRejectReason::invalid_transaction) return "invalid world delta transaction";
    if (reason == WorldDeltaRejectReason::revision_conflict) return "world delta expected revision does not match";
    if (reason == WorldDeltaRejectReason::transaction_conflict) return "world delta transaction ID has different content";
    if (reason == WorldDeltaRejectReason::capacity_exceeded) return "world delta store capacity exceeded";
    return "unknown world delta rejection";
}

} // namespace

struct WorldDeltaSnapshotState {
    std::uint64_t revision = 0;
    std::map<NamespaceCellKey, WorldDeltaRecord, NamespaceCellKeyLess> records;
    NativeTypedWorldStateSnapshot typed_durable_snapshot = NativeTypedWorldStateSnapshot::create({});
    std::vector<NativeTypedWorldStateRecord> typed_transient_overlays;
};

namespace {

bool fits_record_capacity(const WorldDeltaSnapshotState &state, const WorldDeltaStoreLimits &limits) noexcept {
    const std::size_t delta_count = state.records.size();
    const std::size_t durable_count = state.typed_durable_snapshot.records().size();
    const std::size_t overlay_count = state.typed_transient_overlays.size();
    if (delta_count > limits.max_records) return false;
    if (durable_count > limits.max_records - delta_count) return false;
    return overlay_count <= limits.max_records - delta_count - durable_count;
}

std::optional<NativeCellState> typed_value_at(
    const std::vector<NativeTypedWorldStateRecord> &records, const CellCoord &cell) {
    const auto found = std::lower_bound(records.begin(), records.end(), cell,
        [](const NativeTypedWorldStateRecord &record, const CellCoord &coordinate) {
            return CellCoordLess{}(record.state.cell, coordinate);
        });
    if (found == records.end() || !(found->state.cell == cell)) return std::nullopt;
    return found->state;
}

} // namespace

struct WorldDeltaStore::TransactionRecord {
    std::string transaction_id;
    std::vector<std::uint8_t> canonical;
    WorldDeltaCommitReceipt receipt;
};

static_assert(std::is_nothrow_move_assignable_v<std::shared_ptr<const WorldDeltaSnapshotState>>);

bool WorldDeltaState::operator==(const WorldDeltaState &other) const noexcept {
    return density == other.density && solid == other.solid && material == other.material
        && resolved_biome == other.resolved_biome && fluid == other.fluid;
}

bool WorldDeltaRecord::operator==(const WorldDeltaRecord &other) const noexcept {
    return name_space == other.name_space && coordinate == other.coordinate && state == other.state
        && revision == other.revision;
}

bool WorldDeltaSectionKey::operator==(const WorldDeltaSectionKey &other) const noexcept {
    return section == other.section;
}

bool WorldDeltaCommitReceipt::operator==(const WorldDeltaCommitReceipt &other) const noexcept {
    return status == other.status && transaction_id == other.transaction_id && revision == other.revision
        && affected_sections == other.affected_sections;
}

WorldDeltaRejected::WorldDeltaRejected(const WorldDeltaRejectReason reason)
    : std::runtime_error(reject_message(reason)), reason_(reason) {}

WorldDeltaRejectReason WorldDeltaRejected::reason() const noexcept { return reason_; }

WorldDeltaPinnedSnapshot::WorldDeltaPinnedSnapshot(std::shared_ptr<const WorldDeltaSnapshotState> state)
    : state_(std::move(state)) {}

std::uint64_t WorldDeltaPinnedSnapshot::revision() const noexcept { return state_->revision; }

std::optional<WorldDeltaRecord> WorldDeltaPinnedSnapshot::value_at(
    const WorldDeltaNamespace name_space, const CellCoord &coordinate) const {
    const auto found = state_->records.find({name_space, coordinate});
    if (found == state_->records.end()) return std::nullopt;
    return found->second;
}

std::optional<WorldDeltaRecord> WorldDeltaPinnedSnapshot::effective_value_at(const CellCoord &coordinate) const {
    if (const auto overlay = value_at(WorldDeltaNamespace::scene_overlay, coordinate)) return overlay;
    return value_at(WorldDeltaNamespace::terrain_override, coordinate);
}

std::vector<WorldDeltaRecord> WorldDeltaPinnedSnapshot::records() const {
    std::vector<WorldDeltaRecord> result;
    result.reserve(state_->records.size());
    for (const auto &[key, record] : state_->records) {
        static_cast<void>(key);
        result.push_back(record);
    }
    return result;
}

const NativeTypedWorldStateSnapshot &WorldDeltaPinnedSnapshot::typed_durable_snapshot() const noexcept {
    return state_->typed_durable_snapshot;
}

const std::vector<NativeTypedWorldStateRecord> &WorldDeltaPinnedSnapshot::typed_transient_overlays() const noexcept {
    return state_->typed_transient_overlays;
}

std::optional<NativeCellState> WorldDeltaPinnedSnapshot::typed_durable_value_at(const CellCoord &coordinate) const {
    return typed_value_at(state_->typed_durable_snapshot.records(), coordinate);
}

std::optional<NativeCellState> WorldDeltaPinnedSnapshot::typed_transient_overlay_at(const CellCoord &coordinate) const {
    return typed_value_at(state_->typed_transient_overlays, coordinate);
}

std::optional<NativeCellState> WorldDeltaPinnedSnapshot::typed_effective_value_at(const CellCoord &coordinate) const {
    if (const auto overlay = typed_transient_overlay_at(coordinate)) return overlay;
    return typed_durable_value_at(coordinate);
}

WorldDeltaStore::WorldDeltaStore(const WorldDeltaStoreLimits limits) : limits_(limits) {
    if (limits_.max_records == 0U || limits_.max_transactions == 0U) {
        throw WorldDeltaRejected(WorldDeltaRejectReason::invalid_transaction);
    }
    // Reserve once so a later journal append cannot allocate after a candidate
    // state exists. Constructor failure leaves no observable store.
    transactions_.reserve(limits_.max_transactions);
    auto initial = std::make_shared<WorldDeltaSnapshotState>();
    initial->revision = limits_.initial_revision;
    state_ = std::move(initial);
}

WorldDeltaStore::~WorldDeltaStore() = default;

std::uint64_t WorldDeltaStore::revision() const noexcept { return state_->revision; }

WorldDeltaPinnedSnapshot WorldDeltaStore::pin() const { return WorldDeltaPinnedSnapshot(state_); }

WorldDeltaCommitReceipt WorldDeltaStore::commit(const WorldDeltaTransaction &transaction) {
    static_assert(std::is_nothrow_move_constructible_v<TransactionRecord>);
    static_assert(std::is_nothrow_move_constructible_v<WorldDeltaCommitReceipt>);
    std::vector<std::uint8_t> canonical = canonical_transaction(transaction);
    const auto replay = std::find_if(transactions_.begin(), transactions_.end(), [&](const TransactionRecord &record) {
        return record.transaction_id == transaction.transaction_id;
    });
    if (replay != transactions_.end()) {
        if (replay->canonical != canonical) throw WorldDeltaRejected(WorldDeltaRejectReason::transaction_conflict);
        WorldDeltaCommitReceipt receipt = replay->receipt;
        receipt.status = WorldDeltaCommitStatus::idempotent_replay;
        return receipt;
    }
    if (transaction.expected_revision != state_->revision) {
        throw WorldDeltaRejected(WorldDeltaRejectReason::revision_conflict);
    }
    if (transactions_.size() >= limits_.max_transactions) {
        throw WorldDeltaRejected(WorldDeltaRejectReason::capacity_exceeded);
    }

    auto next = std::make_shared<WorldDeltaSnapshotState>(*state_);
    std::vector<NamespaceCellKey> changed_records;
    bool changed = false;
    std::set<WorldDeltaSectionKey, SectionKeyLess> affected;
    for (const WorldDeltaOperation &operation : sorted_operations(transaction)) {
        const NamespaceCellKey key{operation.name_space, operation.coordinate};
        const auto found = next->records.find(key);
        if (operation.kind == WorldDeltaOperationKind::set) {
            if (found == next->records.end() || !(found->second.state == *operation.state)) {
                next->records[key] = {operation.name_space, operation.coordinate, *operation.state, 0};
                changed_records.push_back(key);
                changed = true;
                add_conservative_invalidation_neighborhood(section_key_for(operation.coordinate), affected);
            }
        } else if (found != next->records.end()) {
            next->records.erase(found);
            changed = true;
            add_conservative_invalidation_neighborhood(section_key_for(operation.coordinate), affected);
        }
    }
    if (!fits_record_capacity(*next, limits_)) {
        throw WorldDeltaRejected(WorldDeltaRejectReason::capacity_exceeded);
    }

    WorldDeltaCommitReceipt receipt;
    receipt.transaction_id = transaction.transaction_id;
    receipt.revision = state_->revision;
    if (!changed) {
        receipt.status = WorldDeltaCommitStatus::no_change;
    } else {
        if (state_->revision == std::numeric_limits<std::uint64_t>::max()) {
            throw WorldDeltaRejected(WorldDeltaRejectReason::capacity_exceeded);
        }
        next->revision = state_->revision + 1U;
        for (const NamespaceCellKey &key : changed_records) next->records.at(key).revision = next->revision;
        receipt.status = WorldDeltaCommitStatus::committed;
        receipt.revision = next->revision;
        receipt.affected_sections.assign(affected.begin(), affected.end());
    }
    // All throwing work is deliberately complete before either durable journal
    // or current state becomes observable. reserve() plus the static assertion
    // above make this move append nonthrowing.
    TransactionRecord journal{transaction.transaction_id, std::move(canonical), receipt};
    transactions_.push_back(std::move(journal));
    if (changed) state_ = std::move(next);
    return std::move(receipt);
}

WorldDeltaCommitReceipt WorldDeltaStore::admit_typed_state(const WorldTypedStateAdmission &admission) {
    static_assert(std::is_nothrow_move_constructible_v<TransactionRecord>);
    static_assert(std::is_nothrow_move_constructible_v<WorldDeltaCommitReceipt>);
    const ValidatedTypedAdmission validated = validate_typed_admission(admission);
    std::vector<std::uint8_t> canonical = canonical_typed_admission(admission, validated);
    const auto replay = std::find_if(transactions_.begin(), transactions_.end(), [&](const TransactionRecord &record) {
        return record.transaction_id == admission.transaction_id;
    });
    if (replay != transactions_.end()) {
        if (replay->canonical != canonical) throw WorldDeltaRejected(WorldDeltaRejectReason::transaction_conflict);
        WorldDeltaCommitReceipt receipt = replay->receipt;
        receipt.status = WorldDeltaCommitStatus::idempotent_replay;
        return receipt;
    }
    if (admission.expected_revision != state_->revision) {
        throw WorldDeltaRejected(WorldDeltaRejectReason::revision_conflict);
    }
    if (transactions_.size() >= limits_.max_transactions) {
        throw WorldDeltaRejected(WorldDeltaRejectReason::capacity_exceeded);
    }

    auto next = std::make_shared<WorldDeltaSnapshotState>(*state_);
    next->typed_durable_snapshot = validated.durable_snapshot;
    next->typed_transient_overlays = validated.transient_overlays;
    if (!fits_record_capacity(*next, limits_)) {
        throw WorldDeltaRejected(WorldDeltaRejectReason::capacity_exceeded);
    }

    std::set<CellCoord, CellCoordLess> changed_cells;
    add_changed_typed_cells(
        state_->typed_durable_snapshot.records(), next->typed_durable_snapshot.records(), changed_cells);
    add_changed_typed_cells(state_->typed_transient_overlays, next->typed_transient_overlays, changed_cells);

    WorldDeltaCommitReceipt receipt;
    receipt.transaction_id = admission.transaction_id;
    receipt.revision = state_->revision;
    if (changed_cells.empty()) {
        receipt.status = WorldDeltaCommitStatus::no_change;
    } else {
        if (state_->revision == std::numeric_limits<std::uint64_t>::max()) {
            throw WorldDeltaRejected(WorldDeltaRejectReason::capacity_exceeded);
        }
        next->revision = state_->revision + 1U;
        std::set<WorldDeltaSectionKey, SectionKeyLess> affected;
        for (const CellCoord &cell : changed_cells) {
            add_conservative_invalidation_neighborhood(section_key_for(cell), affected);
        }
        receipt.status = WorldDeltaCommitStatus::committed;
        receipt.revision = next->revision;
        receipt.affected_sections.assign(affected.begin(), affected.end());
    }
    TransactionRecord journal{admission.transaction_id, std::move(canonical), receipt};
    transactions_.push_back(std::move(journal));
    if (!changed_cells.empty()) state_ = std::move(next);
    return receipt;
}

} // namespace voxel::world_backend
