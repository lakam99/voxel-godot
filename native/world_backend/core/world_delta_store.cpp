#include "world_delta_store.hpp"

#include <algorithm>
#include <cstring>
#include <limits>
#include <set>
#include <type_traits>
#include <utility>

namespace voxel::world_backend {
namespace {

struct TypedNamespaceCellKey {
    NativeCellStateNamespace name_space;
    CellCoord cell;
};

struct TypedNamespaceCellKeyLess {
    bool operator()(const TypedNamespaceCellKey &left, const TypedNamespaceCellKey &right) const noexcept {
        if (left.cell.z != right.cell.z) return left.cell.z < right.cell.z;
        if (left.cell.y != right.cell.y) return left.cell.y < right.cell.y;
        if (left.cell.x != right.cell.x) return left.cell.x < right.cell.x;
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
    void typed_cell_operation(const WorldTypedCellOperation &operation) {
        u8(static_cast<std::uint8_t>(operation.name_space));
        i32(operation.cell.x); i32(operation.cell.y); i32(operation.cell.z);
        u8(static_cast<std::uint8_t>(operation.kind));
        u8(operation.state.has_value() ? 1U : 0U);
        if (operation.state) native_cell_state(*operation.state);
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
        // Every public mutation endpoint validates the non-generated edited
        // invariant before journaling, so its canonical form has one shape.
        u8(0U); u8(1U);
        // Metadata has its own self-describing canonical encoding.  The
        // outer length keeps the typed journal unambiguous without inventing
        // a second recursive metadata serialization here.
        binary(state.metadata.canonical_binary());
        u8(state.block_id.has_value() ? 1U : 0U);
        if (state.block_id) text(state.block_id->value());
        u8(state.edit_reason.has_value() ? 1U : 0U);
        if (state.edit_reason) text(*state.edit_reason);
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

bool valid_namespace(const NativeCellStateNamespace value) noexcept {
    return value == NativeCellStateNamespace::durable_terrain || value == NativeCellStateNamespace::scene_overlay;
}

bool valid_kind(const WorldTypedCellOperationKind value) noexcept {
    return value == WorldTypedCellOperationKind::set || value == WorldTypedCellOperationKind::clear;
}

NativeTypedWorldStateRecord typed_record_for(const WorldTypedCellOperation &operation) {
    return {operation.name_space,
        operation.name_space == NativeCellStateNamespace::durable_terrain
            ? NativeTypedWorldStatePersistence::durable
            : NativeTypedWorldStatePersistence::transient,
        *operation.state};
}

void validate_operation(const WorldTypedCellOperation &operation) {
    if (!valid_namespace(operation.name_space) || !valid_kind(operation.kind)) {
        throw WorldDeltaRejected(WorldDeltaRejectReason::invalid_transaction);
    }
    if (operation.kind == WorldTypedCellOperationKind::set) {
        if (!operation.state || !(operation.state->cell == operation.cell)) {
            throw WorldDeltaRejected(WorldDeltaRejectReason::invalid_transaction);
        }
        try {
            NativeTypedWorldStateStore validator;
            const NativeTypedWorldStateRecord record = typed_record_for(operation);
            if (operation.name_space == NativeCellStateNamespace::durable_terrain) {
                validator.admit_durable_records({record});
            } else {
                validator.replace_transient_overlays({record});
            }
        } catch (const std::invalid_argument &) {
            throw WorldDeltaRejected(WorldDeltaRejectReason::invalid_transaction);
        }
    } else if (operation.state) {
        throw WorldDeltaRejected(WorldDeltaRejectReason::invalid_transaction);
    }
}

std::vector<std::uint8_t> canonical_transaction(const WorldTypedCellTransaction &transaction) {
    if (transaction.transaction_id.empty() || transaction.transaction_id.find('\0') != std::string::npos
        || transaction.operations.empty()) {
        throw WorldDeltaRejected(WorldDeltaRejectReason::invalid_transaction);
    }
    std::vector<WorldTypedCellOperation> operations = transaction.operations;
    std::sort(operations.begin(), operations.end(), [](const WorldTypedCellOperation &left, const WorldTypedCellOperation &right) {
        const TypedNamespaceCellKeyLess less;
        return less({left.name_space, left.cell}, {right.name_space, right.cell});
    });
    for (std::size_t index = 0; index < operations.size(); ++index) {
        validate_operation(operations[index]);
        if (index != 0U && operations[index - 1U].name_space == operations[index].name_space
            && operations[index - 1U].cell == operations[index].cell) {
            throw WorldDeltaRejected(WorldDeltaRejectReason::invalid_transaction);
        }
    }
    CanonicalWriter writer;
    writer.u8('W'); writer.u8('T'); writer.u8('C'); writer.u8('1');
    writer.text(transaction.transaction_id);
    writer.u64(transaction.expected_revision);
    writer.u64(static_cast<std::uint64_t>(operations.size()));
    for (const WorldTypedCellOperation &operation : operations) writer.typed_cell_operation(operation);
    return writer.finish();
}

struct ValidatedTypedAdmission {
    NativeTypedWorldStateSnapshot durable_snapshot = NativeTypedWorldStateSnapshot::create({});
    std::vector<NativeTypedWorldStateRecord> transient_overlays;
};

struct ValidatedFeatureAdmission {
    NativeFeatureDeltaSnapshot snapshot = NativeFeatureDeltaSnapshot::create({}, {});
    std::vector<std::uint8_t> canonical_snapshot;
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
    // WTY3 is intentionally distinct from WTY2: native recursive metadata,
    // optional block identity, and optional durable edit reason have a
    // different canonical record schema.
    writer.u8('W'); writer.u8('T'); writer.u8('Y'); writer.u8('3');
    writer.text(admission.transaction_id);
    writer.u64(admission.expected_revision);
    writer.u64(static_cast<std::uint64_t>(validated.durable_snapshot.records().size()));
    for (const NativeTypedWorldStateRecord &record : validated.durable_snapshot.records()) writer.typed_record(record);
    writer.u64(static_cast<std::uint64_t>(validated.transient_overlays.size()));
    for (const NativeTypedWorldStateRecord &record : validated.transient_overlays) writer.typed_record(record);
    return writer.finish();
}

ValidatedFeatureAdmission validate_feature_admission(const WorldFeatureDeltaAdmission &admission) {
    if (admission.transaction_id.empty() || admission.transaction_id.find('\0') != std::string::npos) {
        throw WorldDeltaRejected(WorldDeltaRejectReason::invalid_transaction);
    }
    // A removedProps tombstone changes generated geometry, but FD1 records
    // only its stable ID. Until a native baseline feature-footprint catalog
    // can resolve that ID to all affected cells, publishing this replacement
    // would let collision, render, and navigation retain stale geometry.
    // Reject it at the WDS boundary rather than pretending an empty section
    // receipt is safe. NativeFeatureDeltaSnapshot still retains tombstones as
    // persistence groundwork for that catalog-backed admission later.
    if (!admission.snapshot.tombstones().empty()) {
        throw WorldDeltaRejected(WorldDeltaRejectReason::invalid_transaction);
    }
    // NativeFeatureDeltaSnapshot is immutable at its public boundary; FD1
    // repeats its own feature validation before producing the journal payload.
    // There is therefore no raw, unvalidated feature value to translate here.
    return {admission.snapshot, admission.snapshot.canonical_binary()};
}

std::vector<std::uint8_t> canonical_feature_admission(
    const WorldFeatureDeltaAdmission &admission, const ValidatedFeatureAdmission &validated) {
    CanonicalWriter writer;
    // WFD1 is distinct from WDTX and WTY3: one transaction ID can identify
    // exactly one native world-state mutation kind.
    writer.u8('W'); writer.u8('F'); writer.u8('D'); writer.u8('1');
    writer.text(admission.transaction_id);
    writer.u64(admission.expected_revision);
    writer.binary(validated.canonical_snapshot);
    return writer.finish();
}

std::vector<WorldTypedCellOperation> sorted_operations(const WorldTypedCellTransaction &transaction) {
    std::vector<WorldTypedCellOperation> operations = transaction.operations;
    std::sort(operations.begin(), operations.end(), [](const WorldTypedCellOperation &left, const WorldTypedCellOperation &right) {
        const TypedNamespaceCellKeyLess less;
        return less({left.name_space, left.cell}, {right.name_space, right.cell});
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

bool utf8_byte_less(const std::string &left, const std::string &right) noexcept {
    return std::lexicographical_compare(left.begin(), left.end(), right.begin(), right.end(),
        [](const char left_byte, const char right_byte) noexcept {
            return static_cast<std::uint8_t>(static_cast<unsigned char>(left_byte))
                < static_cast<std::uint8_t>(static_cast<unsigned char>(right_byte));
        });
}

void add_changed_feature_instance_cells(
    const NativeFeatureDeltaSnapshot &before,
    const NativeFeatureDeltaSnapshot &after,
    std::set<CellCoord, CellCoordLess> &changed_cells) {
    const auto &old_instances = before.player_created_instances();
    const auto &new_instances = after.player_created_instances();
    std::size_t old_index = 0;
    std::size_t new_index = 0;
    while (old_index < old_instances.size() || new_index < new_instances.size()) {
        if (old_index == old_instances.size()) {
            changed_cells.insert(new_instances[new_index++].cell);
        } else if (new_index == new_instances.size()) {
            changed_cells.insert(old_instances[old_index++].cell);
        } else {
            const NativePlayerCreatedInstance &old_instance = old_instances[old_index];
            const NativePlayerCreatedInstance &new_instance = new_instances[new_index];
            if (utf8_byte_less(old_instance.instance_id, new_instance.instance_id)) {
                changed_cells.insert(old_instance.cell);
                ++old_index;
            } else if (utf8_byte_less(new_instance.instance_id, old_instance.instance_id)) {
                changed_cells.insert(new_instance.cell);
                ++new_index;
            } else {
                if (!(old_instance == new_instance)) {
                    changed_cells.insert(old_instance.cell);
                    changed_cells.insert(new_instance.cell);
                }
                ++old_index;
                ++new_index;
            }
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
    NativeTypedWorldStateSnapshot typed_durable_snapshot = NativeTypedWorldStateSnapshot::create({});
    std::vector<NativeTypedWorldStateRecord> typed_transient_overlays;
    NativeFeatureDeltaSnapshot feature_delta_snapshot = NativeFeatureDeltaSnapshot::create({}, {});
};

namespace {

bool fits_record_capacity(const WorldDeltaSnapshotState &state, const WorldDeltaStoreLimits &limits) noexcept {
    const std::size_t durable_count = state.typed_durable_snapshot.records().size();
    const std::size_t overlay_count = state.typed_transient_overlays.size();
    const std::size_t feature_count = state.feature_delta_snapshot.tombstones().size()
        + state.feature_delta_snapshot.player_created_instances().size();
    if (durable_count > limits.max_records) return false;
    if (overlay_count > limits.max_records - durable_count) return false;
    return feature_count <= limits.max_records - durable_count - overlay_count;
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

const NativeTypedWorldStateSnapshot &WorldDeltaPinnedSnapshot::durable_terrain_snapshot() const noexcept {
    return state_->typed_durable_snapshot;
}

const std::vector<NativeTypedWorldStateRecord> &WorldDeltaPinnedSnapshot::scene_overlays() const noexcept {
    return state_->typed_transient_overlays;
}

std::optional<NativeCellState> WorldDeltaPinnedSnapshot::durable_terrain_at(const CellCoord &cell) const {
    return typed_value_at(state_->typed_durable_snapshot.records(), cell);
}

std::optional<NativeCellState> WorldDeltaPinnedSnapshot::scene_overlay_at(const CellCoord &cell) const {
    return typed_value_at(state_->typed_transient_overlays, cell);
}

std::optional<NativeCellState> WorldDeltaPinnedSnapshot::effective_typed_cell_at(const CellCoord &cell) const {
    if (const auto overlay = scene_overlay_at(cell)) return overlay;
    return durable_terrain_at(cell);
}

const NativeFeatureDeltaSnapshot &WorldDeltaPinnedSnapshot::feature_delta_snapshot() const noexcept {
    return state_->feature_delta_snapshot;
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

WorldDeltaCommitReceipt WorldDeltaStore::commit_typed_cells(const WorldTypedCellTransaction &transaction) {
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
    std::vector<NativeTypedWorldStateRecord> durable = state_->typed_durable_snapshot.records();
    std::vector<NativeTypedWorldStateRecord> overlays = state_->typed_transient_overlays;
    for (const WorldTypedCellOperation &operation : sorted_operations(transaction)) {
        std::vector<NativeTypedWorldStateRecord> &records = operation.name_space == NativeCellStateNamespace::durable_terrain
            ? durable : overlays;
        const auto found = std::lower_bound(records.begin(), records.end(), operation.cell,
            [](const NativeTypedWorldStateRecord &record, const CellCoord &cell) {
                return CellCoordLess{}(record.state.cell, cell);
            });
        const bool exists = found != records.end() && found->state.cell == operation.cell;
        if (operation.kind == WorldTypedCellOperationKind::set) {
            const NativeTypedWorldStateRecord replacement = typed_record_for(operation);
            if (!exists) {
                records.insert(found, replacement);
            } else if (!(*found == replacement)) {
                *found = replacement;
            }
        } else if (exists) {
            records.erase(found);
        }
    }
    // Every operation was re-admitted before this candidate was built; this
    // final canonical construction cannot introduce a new validation branch.
    next->typed_durable_snapshot = NativeTypedWorldStateSnapshot::create(std::move(durable));
    NativeTypedWorldStateStore validator;
    validator.replace_transient_overlays(std::move(overlays));
    next->typed_transient_overlays = validator.transient_overlays();
    if (!fits_record_capacity(*next, limits_)) {
        throw WorldDeltaRejected(WorldDeltaRejectReason::capacity_exceeded);
    }

    std::set<CellCoord, CellCoordLess> changed_cells;
    add_changed_typed_cells(state_->typed_durable_snapshot.records(), next->typed_durable_snapshot.records(), changed_cells);
    add_changed_typed_cells(state_->typed_transient_overlays, next->typed_transient_overlays, changed_cells);

    WorldDeltaCommitReceipt receipt;
    receipt.transaction_id = transaction.transaction_id;
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
    // All throwing work is deliberately complete before either durable journal
    // or current state becomes observable. reserve() plus the static assertion
    // above make this move append nonthrowing.
    TransactionRecord journal{transaction.transaction_id, std::move(canonical), receipt};
    transactions_.push_back(std::move(journal));
    if (!changed_cells.empty()) state_ = std::move(next);
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

WorldDeltaCommitReceipt WorldDeltaStore::admit_feature_deltas(const WorldFeatureDeltaAdmission &admission) {
    static_assert(std::is_nothrow_move_constructible_v<TransactionRecord>);
    static_assert(std::is_nothrow_move_constructible_v<WorldDeltaCommitReceipt>);
    const ValidatedFeatureAdmission validated = validate_feature_admission(admission);
    std::vector<std::uint8_t> canonical = canonical_feature_admission(admission, validated);
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
    next->feature_delta_snapshot = validated.snapshot;
    if (!fits_record_capacity(*next, limits_)) {
        throw WorldDeltaRejected(WorldDeltaRejectReason::capacity_exceeded);
    }

    const bool changed = !(state_->feature_delta_snapshot == next->feature_delta_snapshot);
    std::set<CellCoord, CellCoordLess> changed_cells;
    if (changed) {
        add_changed_feature_instance_cells(
            state_->feature_delta_snapshot, next->feature_delta_snapshot, changed_cells);
    }

    WorldDeltaCommitReceipt receipt;
    receipt.transaction_id = admission.transaction_id;
    receipt.revision = state_->revision;
    if (!changed) {
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
    if (changed) state_ = std::move(next);
    return receipt;
}

} // namespace voxel::world_backend
