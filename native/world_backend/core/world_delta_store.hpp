#pragma once

#include "coordinates.hpp"
#include "terrain_snapshot.hpp"

#include <cstddef>
#include <cstdint>
#include <memory>
#include <optional>
#include <stdexcept>
#include <string>
#include <vector>

namespace voxel::world_backend {

// Durable terrain edits and transient scene overlays deliberately live in
// separate namespaces. A caller must name the namespace it intends to alter;
// an overlay never silently becomes a durable world delta.
enum class WorldDeltaNamespace : std::uint8_t {
    terrain_override = 1,
    scene_overlay = 2,
};

enum class WorldDeltaOperationKind : std::uint8_t {
    set = 1,
    clear = 2,
};

struct WorldDeltaState {
    double density = -1.35;
    bool solid = false;
    TerrainMaterialId material = TerrainMaterialId::air;
    TerrainBiomeId resolved_biome = TerrainBiomeId::underground_air;
    TerrainFluidId fluid = TerrainFluidId::none;

    bool operator==(const WorldDeltaState &other) const noexcept;
};

struct WorldDeltaOperation {
    WorldDeltaNamespace name_space = WorldDeltaNamespace::terrain_override;
    CellCoord coordinate;
    WorldDeltaOperationKind kind = WorldDeltaOperationKind::set;
    std::optional<WorldDeltaState> state;
};

struct WorldDeltaTransaction {
    std::string transaction_id;
    std::uint64_t expected_revision = 0;
    std::vector<WorldDeltaOperation> operations;
};

struct WorldDeltaRecord {
    WorldDeltaNamespace name_space = WorldDeltaNamespace::terrain_override;
    CellCoord coordinate;
    WorldDeltaState state;
    std::uint64_t revision = 0;

    bool operator==(const WorldDeltaRecord &other) const noexcept;
};

struct WorldDeltaSectionKey {
    CellCoord section;

    bool operator==(const WorldDeltaSectionKey &other) const noexcept;
};

enum class WorldDeltaCommitStatus : std::uint8_t {
    committed = 1,
    no_change = 2,
    idempotent_replay = 3,
};

struct WorldDeltaCommitReceipt {
    WorldDeltaCommitStatus status = WorldDeltaCommitStatus::no_change;
    std::string transaction_id;
    std::uint64_t revision = 0;
    // Conservative invalidation keys. Every changed owner section contributes
    // its complete 3x3x3 section neighborhood so boundary consumers cannot
    // retain stale halo data.
    std::vector<WorldDeltaSectionKey> affected_sections;

    bool operator==(const WorldDeltaCommitReceipt &other) const noexcept;
};

enum class WorldDeltaRejectReason : std::uint8_t {
    invalid_transaction = 1,
    revision_conflict = 2,
    transaction_conflict = 3,
    capacity_exceeded = 4,
};

class WorldDeltaRejected final : public std::runtime_error {
public:
    explicit WorldDeltaRejected(WorldDeltaRejectReason reason);
    WorldDeltaRejectReason reason() const noexcept;

private:
    WorldDeltaRejectReason reason_;
};

struct WorldDeltaStoreLimits {
    // These are hard bounds rather than eviction hints: evicting a completed
    // transaction would invalidate its idempotency contract.
    std::size_t max_records = 65536;
    std::size_t max_transactions = 65536;
    // Imported save state may resume a nonzero global revision. It is part of
    // the immutable first pin, never a post-construction mutable setting.
    std::uint64_t initial_revision = 0;
};

struct WorldDeltaSnapshotState;

// A pin owns an immutable store revision. Later commits replace the store's
// state rather than mutating this snapshot, so section builders can retain it
// without observing a mixed revision.
class WorldDeltaPinnedSnapshot final {
public:
    std::uint64_t revision() const noexcept;
    std::optional<WorldDeltaRecord> value_at(
        WorldDeltaNamespace name_space, const CellCoord &coordinate) const;
    std::optional<WorldDeltaRecord> effective_value_at(const CellCoord &coordinate) const;
    std::vector<WorldDeltaRecord> records() const;

private:
    friend class WorldDeltaStore;
    explicit WorldDeltaPinnedSnapshot(std::shared_ptr<const WorldDeltaSnapshotState> state);

    std::shared_ptr<const WorldDeltaSnapshotState> state_;
};

class WorldDeltaStore final {
public:
    static constexpr std::int32_t SECTION_SIZE = 16;

    explicit WorldDeltaStore(WorldDeltaStoreLimits limits = {});
    ~WorldDeltaStore();

    std::uint64_t revision() const noexcept;
    WorldDeltaPinnedSnapshot pin() const;
    // Strong exception guarantee: validation, replacement-state construction,
    // receipt allocation, and durable transaction journaling all complete
    // before the immutable state pointer is published.
    WorldDeltaCommitReceipt commit(const WorldDeltaTransaction &transaction);

private:
    WorldDeltaStoreLimits limits_;
    std::shared_ptr<const WorldDeltaSnapshotState> state_;
    struct TransactionRecord;
    std::vector<TransactionRecord> transactions_;
};

} // namespace voxel::world_backend
