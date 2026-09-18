#pragma once

#include "coordinates.hpp"
#include "native_feature_delta.hpp"
#include "native_terrain_volume_v2_codec.hpp"
#include "native_typed_world_state_snapshot.hpp"
#include "sha256.hpp"

#include <cstddef>
#include <cstdint>
#include <memory>
#include <optional>
#include <stdexcept>
#include <string>
#include <vector>

namespace voxel::world_backend {

// An operation changes one named layer in the canonical typed cell snapshot.
// `clear` removes the named-layer record, revealing the lower layer/baseline
// to a resolver.  It is deliberately distinct from setting an explicit air
// NativeCellState, which remains an owned edit record.
enum class WorldTypedCellOperationKind : std::uint8_t {
    set = 1,
    clear = 2,
};

struct WorldTypedCellOperation {
    NativeCellStateNamespace name_space = NativeCellStateNamespace::durable_terrain;
    CellCoord cell;
    WorldTypedCellOperationKind kind = WorldTypedCellOperationKind::set;
    std::optional<NativeCellState> state;
};

struct WorldTypedCellTransaction {
    std::string transaction_id;
    std::uint64_t expected_revision = 0;
    std::vector<WorldTypedCellOperation> operations;
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

// This is a constructor-only checkpoint, not a live replacement API.  A v2
// terrainVolume's numeric revision is legacy persisted terrain metadata; it
// is deliberately separate from `revision`, the native world-state sequence
// number.  This prevents a save's terrain-only revision from being confused
// with feature or transient-overlay mutation sequencing.
struct WorldDeltaInitialSnapshot {
    std::uint64_t revision = 0;
    NativeTerrainVolumeV2 terrain_volume;
    std::vector<NativeTypedWorldStateRecord> transient_overlays;
    NativeFeatureDeltaSnapshot feature_delta_snapshot = NativeFeatureDeltaSnapshot::create({}, {});
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

struct WorldDeltaHorizontalBounds {
    std::int32_t x = 0;
    std::int32_t z = 0;
    std::int32_t width = 0;
    std::int32_t depth = 0;
};

// A pin owns an immutable store revision. Later commits replace the store's
// state rather than mutating this snapshot, so section builders can retain it
// without observing a mixed revision.
class WorldDeltaPinnedSnapshot final {
public:
    std::uint64_t revision() const noexcept;
    // Contains the entire persisted v2 terrainVolume domain from this exact
    // immutable pin: root revision, durable typed records, and their
    // bijective nonempty-section revision entries.
    const NativeTerrainVolumeV2 &terrain_volume() const noexcept;
    const NativeTypedWorldStateSnapshot &durable_terrain_snapshot() const noexcept;
    const std::vector<NativeTypedWorldStateRecord> &scene_overlays() const noexcept;
    std::optional<NativeCellState> durable_terrain_at(const CellCoord &cell) const;
    std::optional<NativeCellState> scene_overlay_at(const CellCoord &cell) const;
    // This resolves only the two typed edit layers. Generated terrain and
    // feature precedence remain the owning source resolver's responsibility.
    std::optional<NativeCellState> effective_typed_cell_at(const CellCoord &cell) const;

    // This canonical feature snapshot is pinned beside terrain records and
    // typed cells.  Consumers must still define their own terrain/feature
    // precedence at production cutover; a feature instance is not silently
    // coerced into a terrain override here.
    const NativeFeatureDeltaSnapshot &feature_delta_snapshot() const noexcept;
    // A canonical digest of all state carried by this pin.  It is content,
    // rather than process-sequence, identity and is required when pins from
    // independently restored saves have equal numeric revisions.
    const Sha256Digest &content_digest() const noexcept;
    // Canonical physical identity of only the typed terrain and scene-overlay
    // records whose X/Z coordinates are owned by these exact bounds. Global
    // store revision, terrain root/section revisions, feature deltas, and
    // records on other pages are deliberately excluded.
    Sha256Digest typed_projection_digest(WorldDeltaHorizontalBounds bounds) const;

private:
    friend class WorldDeltaStore;
    explicit WorldDeltaPinnedSnapshot(std::shared_ptr<const WorldDeltaSnapshotState> state);

    std::shared_ptr<const WorldDeltaSnapshotState> state_;
};

class WorldDeltaStore final {
public:
    static constexpr std::int32_t SECTION_SIZE = 16;

    // `initial` is accepted only as the first immutable state created by this
    // constructor.  There is intentionally no post-construction import or
    // reset endpoint: callers must build a fresh owner before publishing any
    // pin, so an import cannot expose a mixed old/new world snapshot.
    explicit WorldDeltaStore(
        WorldDeltaStoreLimits limits = {}, WorldDeltaInitialSnapshot initial = {});
    ~WorldDeltaStore();

    std::uint64_t revision() const noexcept;
    WorldDeltaPinnedSnapshot pin() const;
    // Strong exception guarantee: validation, replacement-state construction,
    // receipt allocation, and durable transaction journaling all complete
    // before the immutable state pointer is published.
    WorldDeltaCommitReceipt commit_typed_cells(const WorldTypedCellTransaction &transaction);

    // Atomically replaces both typed portions of the current immutable state.
    // It shares revision, pinning, journal-ID conflict handling, capacity, and
    // conservative invalidation semantics with `commit_typed_cells`.
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
