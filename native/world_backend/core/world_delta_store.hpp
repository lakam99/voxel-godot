#pragma once

#include "coordinates.hpp"
#include "native_feature_delta.hpp"
#include "native_generated_feature_footprint_catalog.hpp"
#include "native_terrain_volume_v2_codec.hpp"
#include "native_typed_world_state_snapshot.hpp"
#include "native_value.hpp"
#include "sha256.hpp"

#include <cstddef>
#include <cstdint>
#include <functional>
#include <memory>
#include <optional>
#include <stdexcept>
#include <string>
#include <thread>
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
    // Persisted v2 domains have independent production capacities. The total
    // defaults are their exact sum, so filling one domain never silently
    // steals advertised capacity from either sibling domain. Scene overlays
    // are runtime-only and have their own capacity plus the resident total.
    static constexpr std::size_t DEFAULT_MAX_DURABLE_TERRAIN_RECORDS =
        NativeTerrainVolumeV2Limits::DEFAULT_MAX_RECORDS;
    static constexpr std::size_t DEFAULT_MAX_SCENE_OVERLAY_RECORDS = 65536U;
    static constexpr std::size_t DEFAULT_MAX_FEATURE_TOMBSTONES =
        NativeFeatureDeltaLimits::MAX_TOMBSTONES;
    static constexpr std::size_t DEFAULT_MAX_PLAYER_CREATED_INSTANCES =
        NativeFeatureDeltaLimits::MAX_PLAYER_CREATED_INSTANCES;
    static constexpr std::size_t DEFAULT_MAX_PERSISTED_RECORDS =
        DEFAULT_MAX_DURABLE_TERRAIN_RECORDS
        + DEFAULT_MAX_FEATURE_TOMBSTONES
        + DEFAULT_MAX_PLAYER_CREATED_INSTANCES;
    static constexpr std::size_t DEFAULT_MAX_RESIDENT_RECORDS =
        DEFAULT_MAX_PERSISTED_RECORDS + DEFAULT_MAX_SCENE_OVERLAY_RECORDS;
    // A receipt is consumed by bounded publication queues, so it must have a
    // hard section cap. A feature mutation that would exceed it is rejected
    // atomically and remains retryable after the caller narrows its request.
    static constexpr std::size_t DEFAULT_MAX_AFFECTED_SECTIONS = 262144U;

    std::size_t max_durable_terrain_records = DEFAULT_MAX_DURABLE_TERRAIN_RECORDS;
    std::size_t max_scene_overlay_records = DEFAULT_MAX_SCENE_OVERLAY_RECORDS;
    std::size_t max_feature_tombstones = DEFAULT_MAX_FEATURE_TOMBSTONES;
    std::size_t max_player_created_instances = DEFAULT_MAX_PLAYER_CREATED_INSTANCES;
    std::size_t max_persisted_records = DEFAULT_MAX_PERSISTED_RECORDS;
    std::size_t max_resident_records = DEFAULT_MAX_RESIDENT_RECORDS;
    std::size_t max_affected_sections = DEFAULT_MAX_AFFECTED_SECTIONS;
    // This is a hard bound rather than an eviction hint: evicting a completed
    // transaction would invalidate its idempotency contract.
    std::size_t max_transactions = 65536;
    // Imported save state may resume a nonzero global revision. It is part of
    // the immutable first pin, never a post-construction mutable setting.
    std::uint64_t initial_revision = 0;
};

// Count-only capacity is a public value contract so aggregate save admission
// can preflight every domain before constructing or copying a snapshot. It
// deliberately does not bypass semantic admission; in particular, nonempty
// tombstones remain rejected by WorldDeltaStore until feature footprints can
// produce complete invalidation receipts.
struct WorldDeltaStoreCapacityUsage {
    std::size_t durable_terrain_records = 0;
    std::size_t scene_overlay_records = 0;
    std::size_t feature_tombstones = 0;
    std::size_t player_created_instances = 0;
};

// Uses subtraction rather than unchecked addition, so adversarial size_t
// counts cannot wrap into an apparently valid persisted or resident total.
bool world_delta_store_fits_capacity(
    const WorldDeltaStoreCapacityUsage &usage,
    const WorldDeltaStoreLimits &limits = {}) noexcept;

struct WorldDeltaSnapshotState;

struct WorldDeltaHorizontalBounds {
    std::int32_t x = 0;
    std::int32_t z = 0;
    std::int32_t width = 0;
    std::int32_t depth = 0;
};

// A borrowed WDP1/v1 projection has fixed owner storage. Record indices and
// byte offsets are reacquired only during a guarded, same-incarnation step;
// no WorldDeltaSnapshotState, NativeValue, string or iterator is retained.
class BorrowedTypedProjectionCursor final {
public:
    enum class Status : std::uint8_t { idle, pending, source_changed, failed, ready };
    struct Step {
        Status status = Status::idle;
        std::uint32_t consumed_ops = 0;
        std::uint32_t next_atomic_ops = 1;
    };
    void reset(WorldDeltaHorizontalBounds bounds) noexcept;
    Status status() const noexcept;
    Sha256Digest digest() const;
private:
    friend class WorldDeltaStore;
    enum class Phase : std::uint8_t {
        count_durable, count_overlay, header, durable_count, durable_records,
        overlay_count, overlay_records, finish, complete
    };
    enum class RecordPhase : std::uint8_t {
        start, fixed, metadata_count, metadata_reset, metadata_length, metadata_emit,
        block_flag, block_length, block_text,
        reason_flag, reason_length, reason_text, end
    };
    WorldDeltaHorizontalBounds bounds_{};
    Sha256State hash_;
    NativeValueCanonicalCursor metadata_;
    std::size_t scan_index_ = 0;
    std::uint64_t durable_count_ = 0;
    std::uint64_t overlay_count_ = 0;
    std::uint64_t metadata_bytes_ = 0;
    std::uint64_t metadata_emitted_ = 0;
    std::uint64_t source_token_ = 0;
    std::size_t byte_offset_ = 0;
    Phase phase_ = Phase::count_durable;
    RecordPhase record_phase_ = RecordPhase::start;
    Status status_ = Status::idle;
};

// A live borrowed source reader uses this single-owner fence. Detached save
// candidates are built without one and bind only when the adapter publishes
// them. The guard is serialized on the adapter's main thread; it never owns a
// delta snapshot or lets a pointer escape an advance call.
class WorldSourceMutationFence final {
public:
    class ReadGuard final {
    public:
        explicit ReadGuard(WorldSourceMutationFence &fence);
        ReadGuard(const ReadGuard &) = delete;
        ReadGuard &operator=(const ReadGuard &) = delete;
        ~ReadGuard();
    private:
        WorldSourceMutationFence &fence_;
    };

    void require_writer_entry() const;
    void published() noexcept;
    void revoke() noexcept;
    void reset_after_owner_drain();
    std::uint64_t epoch() const noexcept;
    bool read_active() const noexcept;
    bool writer_available() const noexcept;
    bool exhausted() const noexcept;
    bool on_owner_thread() const noexcept;
private:
    const std::thread::id owner_thread_ = std::this_thread::get_id();
    bool read_active_ = false;
    bool revoked_ = false;
    std::uint64_t epoch_ = 1U;
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
    // Visit only durable edits in this X/Z column. The immutable index is
    // rebuilt with a changed terrain snapshot, never per world query.
    bool durable_terrain_column_any(
        std::int32_t x, std::int32_t z,
        const std::function<bool(const NativeCellState &)> &predicate) const;
    // Evaluate the effective typed state in a column. A transient overlay
    // masks a durable record at the same cell, just as point resolution does.
    bool effective_typed_column_any(
        std::int32_t x, std::int32_t z,
        const std::function<bool(const NativeCellState &)> &predicate) const;
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
        WorldDeltaStoreLimits limits = {},
        WorldDeltaInitialSnapshot initial = {},
        std::shared_ptr<const NativeGeneratedFeatureFootprintCatalog> feature_footprint_catalog = nullptr);
    ~WorldDeltaStore();

    std::uint64_t revision() const noexcept;
    const Sha256Digest &current_content_digest() const noexcept;
    BorrowedTypedProjectionCursor::Step advance_borrowed_projection(
        BorrowedTypedProjectionCursor &cursor, WorldDeltaHorizontalBounds bounds,
        std::uint64_t source_token, std::uint32_t offered_ops) const noexcept;
    WorldDeltaPinnedSnapshot pin() const;
    bool bind_source_mutation_fence(WorldSourceMutationFence *fence) noexcept;
    void require_source_writer_entry() const;
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
    // Configuration is immutable for this store lifetime. It is not persisted
    // delta state: the owning generated-world source recreates and verifies it
    // before a v2 snapshot containing tombstones is admitted.
    std::shared_ptr<const NativeGeneratedFeatureFootprintCatalog> feature_footprint_catalog_;
    std::shared_ptr<const WorldDeltaSnapshotState> state_;
    WorldSourceMutationFence *source_mutation_fence_ = nullptr;
    struct TransactionRecord;
    std::vector<TransactionRecord> transactions_;
};

} // namespace voxel::world_backend
