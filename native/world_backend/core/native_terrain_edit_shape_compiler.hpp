#pragma once

#include "native_cell_state.hpp"
#include "sha256.hpp"
#include "world_delta_store.hpp"

#include <cstddef>
#include <cstdint>
#include <memory>
#include <optional>
#include <stdexcept>
#include <string>
#include <vector>

namespace voxel::world_backend {

enum class NativeTerrainEditShapeKind : std::uint8_t {
    inclusive_box = 1,
    sphere = 2,
    surface_deformation = 3,
};

enum class NativeTerrainEditCellClassification : std::uint8_t {
    direct_target = 1,
    excavation_boundary = 2,
};

struct NativeTerrainEditStateTemplate {
    TerrainMaterialId material = TerrainMaterialId::air;
    TerrainBiomeId biome = TerrainBiomeId::plains;
    // Absent values follow TerrainVolumeService.normalize_cell_state():
    // solidity derives from material and light derives from resolved solidity.
    // Positive-radius spheres deliberately require solid to be present because
    // script geometry defaults the missing key differently from state
    // normalization. Audited production sphere callers are explicit; rejecting
    // the ambiguous form preserves the typed density/solid invariant.
    std::optional<bool> solid;
    std::optional<double> density;
    TerrainFluidId fluid = TerrainFluidId::none;
    std::optional<NativeCellLight> light;
    // This is a typed native boundary, not a Variant coercion boundary. For
    // surface deformation, an optional `source` entry must already be a UTF-8
    // string; non-string Godot values are normalized before constructing this
    // request or rejected as invalid_request.
    NativeValue metadata = NativeValue::object({});
    // TerrainVolumeService defaults blockId to material when absent. The
    // compiler performs the same normalization so every emitted durable set
    // operation is immediately admissible by WorldDeltaStore's v2 contract.
    std::optional<NativeBlockIdentity> block_id;
};

struct NativeTerrainEditShape {
    NativeTerrainEditShapeKind kind = NativeTerrainEditShapeKind::inclusive_box;
    CellCoord first;
    CellCoord second;
    Vec3d center;
    double radius = 0.0;
    double drop_depth = 0.0;
    NativeTerrainEditStateTemplate target;
    std::string provenance_id;

    static NativeTerrainEditShape inclusive_box(
        CellCoord first,
        CellCoord second,
        NativeTerrainEditStateTemplate target,
        std::string provenance_id);
    static NativeTerrainEditShape sphere(
        Vec3d center,
        double radius,
        NativeTerrainEditStateTemplate target,
        std::string provenance_id);
    static NativeTerrainEditShape surface_deformation(
        Vec3d center,
        double radius,
        double drop_depth,
        NativeTerrainEditStateTemplate target,
        std::string provenance_id);
};

struct NativeTerrainEditColumn {
    std::int32_t x = 0;
    std::int32_t z = 0;

    bool operator==(const NativeTerrainEditColumn &other) const noexcept {
        return x == other.x && z == other.z;
    }
};

struct NativeTerrainEditSurfaceProjection {
    NativeTerrainEditColumn column;
    double surface_y = 0.0;
    std::size_t candidate_reads = 0;
};

// Implementations must retain one immutable effective-world snapshot for the
// duration of compile(). The identity is copied into the result, making a
// compiled operation batch auditable against the exact source it sampled.
class NativeTerrainEditPinnedSource {
public:
    virtual ~NativeTerrainEditPinnedSource() = default;
    virtual Sha256Digest snapshot_digest() const noexcept = 0;
    virtual std::uint64_t source_revision() const noexcept = 0;
    virtual std::optional<NativeCellState> cell_at(const CellCoord &cell) const = 0;
    // Surface deformation is admitted only against a prevalidated immutable
    // view with bounded callbacks. A true result is a trust-boundary promise:
    // physical retained-size lookup is allocation-free O(1), physical cell
    // lookup is O(1) with retained storage no larger than its declaration, and
    // projection performs no more than max_candidate_reads bounded source
    // reads. Callback exceptions are terminal compile failures; callbacks are
    // never retried within a job.
    virtual bool has_bounded_prevalidated_surface_deformation_view() const noexcept {
        return false;
    }
    // Surface-deformation persistence must never clone a transient scene
    // overlay. A source which cannot expose the durable layer stays unavailable.
    // Effective physical terrain state after natural/site shaping, generated
    // physical patches, and durable overrides, but before transient/exact
    // scene-overlay precedence. The compiler commits a new durable override
    // derived from this physical state.
    virtual std::optional<NativeCellState> physical_terrain_cell_excluding_scene_overlay_at(
        const CellCoord &) const {
        return std::nullopt;
    }
    // Allocation-free admission query for the corresponding physical cell.
    // The declaration may be exact or conservative, but must cover the full
    // retained NativeCellState returned by the subsequent fetch. A missing,
    // zero, or understated declaration makes the source inadmissible.
    virtual std::optional<std::size_t>
    physical_terrain_cell_retained_bytes_excluding_scene_overlay_at(
        const CellCoord &) const noexcept {
        return std::nullopt;
    }
    // The source must honor max_candidate_reads and report its exact reads.
    virtual std::optional<NativeTerrainEditSurfaceProjection> continuous_surface_projection_at(
        const NativeTerrainEditColumn &, std::size_t) const {
        return std::nullopt;
    }
};

struct NativeTerrainEditCompileLimits {
    std::size_t max_candidate_visits = 1'000'000U;
    std::size_t max_operations = 1'000'000U;
    std::size_t max_columns = 65'536U;
    std::size_t max_projection_reads = 4'000'000U;
    std::size_t max_projection_reads_per_query = 4096U;
    std::size_t max_y_candidates = 4'000'000U;
    std::size_t max_metadata_nodes = NativeValueLimits::MAX_NODES;
    std::size_t max_metadata_text_bytes = 1024U * 1024U;
    std::size_t max_metadata_depth = NativeValueLimits::MAX_DEPTH;
    // Conservative aggregate logical residency across planned columns,
    // physical-source cache, pending map, compatibility summaries, map/set
    // indexes, and final operation copies. Every concurrently retained copy is
    // charged; immutable source-pin storage is pre-existing input, not prepared
    // job memory.
    std::size_t max_prepared_bytes = 64U * 1024U * 1024U;
};

struct NativeTerrainEditCompileRequest {
    double cell_size = 1.35;
    std::vector<NativeTerrainEditShape> shapes;
    const NativeTerrainEditPinnedSource *source = nullptr;
    // Resumable jobs retain this immutable pin. It is mandatory for surface
    // deformation; borrowed `source` remains for the synchronous legacy shapes.
    std::shared_ptr<const NativeTerrainEditPinnedSource> owned_source;
    // When enabled, final states identical to the pinned effective source are
    // omitted. Sphere compilation always requires a source because an air
    // sphere's softened boundary preserves existing solid cell payloads.
    bool omit_unchanged = true;
    NativeTerrainEditCompileLimits limits;
};

struct NativeTerrainEditCompiledOperation {
    WorldTypedCellOperation operation;
    NativeTerrainEditShapeKind shape_kind = NativeTerrainEditShapeKind::inclusive_box;
    NativeTerrainEditCellClassification classification = NativeTerrainEditCellClassification::direct_target;
    std::size_t source_shape_index = 0;
    std::string provenance_id;
};

struct NativeTerrainEditMaterialCount {
    TerrainMaterialId material = TerrainMaterialId::air;
    std::size_t count = 0;
};

struct NativeTerrainEditCompileSummary {
    std::size_t shape_count = 0;
    std::size_t candidate_visits = 0;
    std::size_t unique_cells_before_filter = 0;
    std::size_t coincident_overwrites = 0;
    std::size_t unchanged_filtered = 0;
    std::size_t emitted_operations = 0;
    std::size_t direct_target_operations = 0;
    std::size_t excavation_boundary_operations = 0;
    std::size_t solid_operations = 0;
    std::size_t nonsolid_operations = 0;
    std::vector<NativeTerrainEditMaterialCount> material_counts;
    // These source-to-final transition summaries are available only with an
    // immutable effective-source pin. They describe the final later-wins
    // result, never intermediate overlapped shapes.
    bool source_transition_summary_available = false;
    std::size_t changed_cells = 0;
    std::vector<NativeTerrainEditColumn> changed_columns;
    std::vector<NativeTerrainEditMaterialCount> removed_material_counts;
    std::vector<CellCoord> legacy_changed_cells;
    std::vector<NativeTerrainEditColumn> legacy_changed_columns;
    std::vector<NativeTerrainEditColumn> skylight_columns;
    std::vector<NativeTerrainEditColumn> fluid_transition_columns;
    std::size_t enumerated_columns = 0;
    std::size_t projection_queries = 0;
    std::size_t projection_candidate_reads = 0;
    std::size_t y_candidates = 0;
    std::size_t prepared_bytes = 0;
    bool source_pinned = false;
    // Surface-deformation output is bound to a physical snapshot digest and
    // may not use the revision-only legacy transaction conversion.
    bool requires_identity_bound_commit = false;
    Sha256Digest source_snapshot_digest{};
    std::uint64_t source_revision = 0;
};

class NativeTerrainEditCompiledBatch final {
public:
    const std::vector<NativeTerrainEditCompiledOperation> &compiled_operations() const noexcept;
    const NativeTerrainEditCompileSummary &summary() const noexcept;
    WorldTypedCellTransaction make_transaction(std::string transaction_id, std::uint64_t expected_revision) const;

private:
    friend class NativeTerrainEditShapeCompiler;
    friend class NativeTerrainEditCompileJob;
    NativeTerrainEditCompiledBatch(
        std::vector<NativeTerrainEditCompiledOperation> operations,
        NativeTerrainEditCompileSummary summary);

    std::vector<NativeTerrainEditCompiledOperation> operations_;
    NativeTerrainEditCompileSummary summary_;
};

enum class NativeTerrainEditCompileRejectReason : std::uint8_t {
    invalid_request = 1,
    unsupported_shape = 2,
    candidate_limit_exceeded = 3,
    operation_limit_exceeded = 4,
    source_required = 5,
    source_cell_missing = 6,
    source_cell_mismatch = 7,
    empty_transaction = 8,
    source_drift = 9,
    source_revision_mismatch = 10,
    column_limit_exceeded = 11,
    projection_limit_exceeded = 12,
    projection_missing = 13,
    y_candidate_limit_exceeded = 14,
    prepared_byte_limit_exceeded = 15,
    mixed_surface_deformation = 16,
    source_cell_size_missing = 17,
    source_cell_size_mismatch = 18,
    identity_bound_commit_required = 19,
    source_contract_missing = 20,
    source_callback_failure = 21,
};

class NativeTerrainEditCompileRejected final : public std::invalid_argument {
public:
    explicit NativeTerrainEditCompileRejected(NativeTerrainEditCompileRejectReason reason);
    NativeTerrainEditCompileRejectReason reason() const noexcept;

private:
    NativeTerrainEditCompileRejectReason reason_;
};

class NativeTerrainEditShapeCompiler final {
public:
    static NativeTerrainEditCompiledBatch compile(const NativeTerrainEditCompileRequest &request);
};

enum class NativeTerrainEditCompileJobStatus : std::uint8_t {
    running = 1,
    completed = 2,
    cancelled = 3,
    rejected = 4,
    result_taken = 5,
};

struct NativeTerrainEditCompileProgress {
    NativeTerrainEditCompileJobStatus status = NativeTerrainEditCompileJobStatus::running;
    std::size_t advance_calls = 0;
    std::size_t work_units = 0;
    std::size_t enumerated_columns = 0;
    std::size_t projection_queries = 0;
    std::size_t projection_candidate_reads = 0;
    std::size_t y_candidates = 0;
    std::size_t prepared_operations = 0;
    std::size_t prepared_bytes = 0;
};

class NativeTerrainEditCompileJob final {
public:
    NativeTerrainEditCompileJob(NativeTerrainEditCompileJob &&) noexcept;
    NativeTerrainEditCompileJob &operator=(NativeTerrainEditCompileJob &&) noexcept = delete;
    NativeTerrainEditCompileJob(const NativeTerrainEditCompileJob &) = delete;
    NativeTerrainEditCompileJob &operator=(const NativeTerrainEditCompileJob &) = delete;
    ~NativeTerrainEditCompileJob();

    NativeTerrainEditCompileJobStatus status() const noexcept;
    const NativeTerrainEditCompileProgress &progress() const noexcept;
    std::optional<NativeTerrainEditCompileRejectReason> reject_reason() const noexcept;
    // Cancellation/rejection is O(1): large prepared buffers stay owned by the
    // job. A nonzero value means the caller must move and destroy this job on
    // its backend-retirement worker, never in a gameplay-frame callback.
    std::size_t retained_entries_for_off_worker_destruction() const noexcept;
    void advance(std::size_t max_work_units);
    void cancel() noexcept;
    std::optional<NativeTerrainEditCompiledBatch> take_completed_batch();

private:
    friend class NativeTerrainEditResumableCompiler;
    struct Impl;
    explicit NativeTerrainEditCompileJob(std::unique_ptr<Impl> impl) noexcept;
    std::unique_ptr<Impl> impl_;
};

class NativeTerrainEditResumableCompiler final {
public:
    static NativeTerrainEditCompileJob begin(const NativeTerrainEditCompileRequest &request);
};

} // namespace voxel::world_backend
