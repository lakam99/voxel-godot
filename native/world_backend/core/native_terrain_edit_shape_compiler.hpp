#pragma once

#include "native_cell_state.hpp"
#include "sha256.hpp"
#include "world_delta_store.hpp"

#include <cstddef>
#include <cstdint>
#include <optional>
#include <stdexcept>
#include <string>
#include <vector>

namespace voxel::world_backend {

// This compiler is deliberately limited to shapes whose production semantics
// can be expressed entirely from cell coordinates plus one immutable effective
// source pin. Surface deformation is not one of those shapes: it first queries
// the authoritative current surface projection for every X/Z column. It must
// be added only after that projection is native-owned, rather than introducing
// a second height authority here.
enum class NativeTerrainEditShapeKind : std::uint8_t {
    inclusive_box = 1,
    sphere = 2,
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
};

struct NativeTerrainEditCompileLimits {
    std::size_t max_candidate_visits = 1'000'000U;
    std::size_t max_operations = 1'000'000U;
};

struct NativeTerrainEditCompileRequest {
    double cell_size = 1.35;
    std::vector<NativeTerrainEditShape> shapes;
    const NativeTerrainEditPinnedSource *source = nullptr;
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

struct NativeTerrainEditColumn {
    std::int32_t x = 0;
    std::int32_t z = 0;

    bool operator==(const NativeTerrainEditColumn &other) const noexcept {
        return x == other.x && z == other.z;
    }
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
    bool source_pinned = false;
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

} // namespace voxel::world_backend
