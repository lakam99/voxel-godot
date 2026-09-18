#pragma once

#include "coordinates.hpp"
#include "native_feature_delta.hpp"
#include "native_typed_world_state_snapshot.hpp"
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

// A typed v2-state replacement belongs to the same immutable world snapshot
// as ordinary cell deltas.  It is deliberately a replacement admission, not
// a second mutable store: a pin can therefore never observe a durable typed
// snapshot, its transient overlays, and its delta revision from different
// points in time.
struct WorldTypedStateAdmission {
    std::string transaction_id;
    std::uint64_t expected_revision = 0;
    NativeTypedWorldStateSnapshot durable_snapshot = NativeTypedWorldStateSnapshot::create({});
    std::vector<NativeTypedWorldStateRecord> transient_overlays;
};

// Durable generated-feature removals and player-created feature instances are
// admitted as one replacement snapshot.  This owns only persistence facts;
// it deliberately does not infer doors, inventory, navigation, or scene-node
// behavior from the v2 feature payload.
struct WorldFeatureDeltaAdmission {
    std::string transaction_id;
    std::uint64_t expected_revision = 0;
    NativeFeatureDeltaSnapshot snapshot = NativeFeatureDeltaSnapshot::create({}, {});
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

    // These are attached to this exact delta pin.  There is intentionally no
    // cross-model "effective" lookup yet: production query resolution must
    // make its precedence explicit at cutover rather than silently merging
    // legacy deltas and typed v2 state here.
    const NativeTypedWorldStateSnapshot &typed_durable_snapshot() const noexcept;
    const std::vector<NativeTypedWorldStateRecord> &typed_transient_overlays() const noexcept;
    std::optional<NativeCellState> typed_durable_value_at(const CellCoord &coordinate) const;
    std::optional<NativeCellState> typed_transient_overlay_at(const CellCoord &coordinate) const;
    std::optional<NativeCellState> typed_effective_value_at(const CellCoord &coordinate) const;

    // This canonical feature snapshot is pinned beside terrain records and
    // typed cells.  Consumers must still define their own terrain/feature
    // precedence at production cutover; a feature instance is not silently
    // coerced into a terrain override here.
    const NativeFeatureDeltaSnapshot &feature_delta_snapshot() const noexcept;

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

    // Atomically replaces both typed portions of the current immutable state.
    // It shares revision, pinning, journal-ID conflict handling, capacity, and
    // conservative invalidation semantics with `commit`.
    WorldDeltaCommitReceipt admit_typed_state(const WorldTypedStateAdmission &admission);

    // Atomically replaces feature-delta state in the same revision, pin,
    // journal, capacity, and invalidation model as all other native world
    // state.  The old and new player-instance cells both invalidate so a
    // removal cannot leave an occupied section cached.
    WorldDeltaCommitReceipt admit_feature_deltas(const WorldFeatureDeltaAdmission &admission);

private:
    WorldDeltaStoreLimits limits_;
    std::shared_ptr<const WorldDeltaSnapshotState> state_;
    struct TransactionRecord;
    std::vector<TransactionRecord> transactions_;
};

} // namespace voxel::world_backend
