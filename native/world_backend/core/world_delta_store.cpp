#include "world_delta_store.hpp"

#include <algorithm>
#include <cmath>
#include <cstring>
#include <limits>
#include <map>
#include <set>
#include <utility>

namespace voxel::world_backend {
namespace {

struct NamespaceCellKey {
    WorldDeltaNamespace name_space;
    CellCoord coordinate;
};

struct NamespaceCellKeyLess {
    bool operator()(const NamespaceCellKey &left, const NamespaceCellKey &right) const noexcept {
        if (left.name_space != right.name_space) {
            return static_cast<std::uint8_t>(left.name_space) < static_cast<std::uint8_t>(right.name_space);
        }
        if (left.coordinate.x != right.coordinate.x) return left.coordinate.x < right.coordinate.x;
        if (left.coordinate.y != right.coordinate.y) return left.coordinate.y < right.coordinate.y;
        return left.coordinate.z < right.coordinate.z;
    }
};

struct SectionKeyLess {
    bool operator()(const WorldDeltaSectionKey &left, const WorldDeltaSectionKey &right) const noexcept {
        if (left.section.x != right.section.x) return left.section.x < right.section.x;
        if (left.section.y != right.section.y) return left.section.y < right.section.y;
        return left.section.z < right.section.z;
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
    const bool material_valid = material <= static_cast<std::uint8_t>(TerrainMaterialId::water);
    const bool biome_valid = biome <= static_cast<std::uint8_t>(TerrainBiomeId::alpine);
    const bool fluid_valid = state.fluid == TerrainFluidId::none || state.fluid == TerrainFluidId::water;
    return std::isfinite(state.density) && state.solid == (state.density >= 0.0)
        && material_valid && biome_valid && fluid_valid
        && (!state.solid || state.material != TerrainMaterialId::air)
        && (state.solid || state.material == TerrainMaterialId::air || state.material == TerrainMaterialId::water)
        && (state.fluid != TerrainFluidId::water || state.material == TerrainMaterialId::water);
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

const char *reject_message(const WorldDeltaRejectReason reason) noexcept {
    switch (reason) {
    case WorldDeltaRejectReason::invalid_transaction: return "invalid world delta transaction";
    case WorldDeltaRejectReason::revision_conflict: return "world delta expected revision does not match";
    case WorldDeltaRejectReason::transaction_conflict: return "world delta transaction ID has different content";
    case WorldDeltaRejectReason::capacity_exceeded: return "world delta store capacity exceeded";
    }
    return "unknown world delta rejection";
}

} // namespace

struct WorldDeltaSnapshotState {
    std::uint64_t revision = 0;
    std::map<NamespaceCellKey, WorldDeltaRecord, NamespaceCellKeyLess> records;
};

struct WorldDeltaStore::TransactionRecord {
    std::string transaction_id;
    std::vector<std::uint8_t> canonical;
    WorldDeltaCommitReceipt receipt;
};

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

WorldDeltaStore::WorldDeltaStore(const WorldDeltaStoreLimits limits) : limits_(limits) {
    if (limits_.max_records == 0U || limits_.max_transactions == 0U) {
        throw WorldDeltaRejected(WorldDeltaRejectReason::invalid_transaction);
    }
    auto initial = std::make_shared<WorldDeltaSnapshotState>();
    initial->revision = limits_.initial_revision;
    state_ = std::move(initial);
}

WorldDeltaStore::~WorldDeltaStore() = default;

std::uint64_t WorldDeltaStore::revision() const noexcept { return state_->revision; }

WorldDeltaPinnedSnapshot WorldDeltaStore::pin() const { return WorldDeltaPinnedSnapshot(state_); }

WorldDeltaCommitReceipt WorldDeltaStore::commit(const WorldDeltaTransaction &transaction) {
    const std::vector<std::uint8_t> canonical = canonical_transaction(transaction);
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
                affected.insert(section_key_for(operation.coordinate));
            }
        } else if (found != next->records.end()) {
            next->records.erase(found);
            changed = true;
            affected.insert(section_key_for(operation.coordinate));
        }
    }
    if (next->records.size() > limits_.max_records) {
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
        state_ = std::move(next);
    }
    transactions_.push_back({transaction.transaction_id, canonical, receipt});
    return receipt;
}

} // namespace voxel::world_backend
