#pragma once

#include "authority.hpp"
#include "biome_region_field.hpp"
#include "sha256.hpp"
#include "world_delta_store.hpp"

#include <array>
#include <cstddef>
#include <cstdint>
#include <memory>
#include <string>
#include <vector>

namespace voxel::world_backend {

class WorldSourceDefinition;
class NativeTerrainShapingPagePin;
class NativeTerrainShapingSnapshot;
struct NativeTerrainPageKey;

// Terrain generation hashes the raw Godot seed text; it does not use the
// BiomeRegionField's strip_edges/default admission.  Keeping this type apart
// from AdmittedBiomeSeed prevents a whitespace-only or non-ASCII terrain seed
// from being silently rewritten while the macrobiome field remains canonical.
struct AdmittedTerrainSeed {
    std::vector<std::uint32_t> code_points;
    std::string utf8;
    bool admitted = false;

    bool operator==(const AdmittedTerrainSeed &other) const noexcept;
};

AdmittedTerrainSeed admit_raw_terrain_seed(const std::string &presentation_utf8);
AdmittedTerrainSeed validate_admitted_raw_terrain_seed(
    const std::vector<std::uint32_t> &code_points, const std::string &presentation_utf8, bool admitted);

// Generated physical content is deliberately distinct from request ownership:
// cancellation and publication authority never change this definition.
struct WorldSourceRevisionDescriptor {
    // Raw terrain seed and water-level admission expanded the immutable source
    // envelope; v1 callers cannot describe this physical content completely.
    std::uint32_t source_schema_revision = 2;
    std::uint32_t terrain_generator_revision = 1;
    std::uint32_t biome_region_field_revision = BiomeRegionField::FIELD_VERSION;
    std::uint32_t lattice_query_revision = 1;
    std::uint32_t cell_center_query_revision = 1;
    std::uint32_t surface_column_query_revision = 1;
};

struct WorldSourceConstants {
    double cell_size_meters = 1.35;
    // Center queries use this declared fractional offset; they do not silently
    // acquire lattice/mesh coordinate semantics.
    double cell_center_offset_cells = 0.5;
    std::int32_t world_bottom_cell_y = -64;
    double water_level_meters = 11.1;
    double minimum_surface_meters = 4.0;
    double maximum_surface_meters = 120.0;
};

struct WorldSourceDescriptor {
    // Required independently from admitted_biome_seed.  It preserves the raw
    // `seed_text` Godot passes to FNL/FNV terrain rules.
    AdmittedTerrainSeed raw_terrain_seed;
    AdmittedBiomeSeed admitted_biome_seed;
    WorldSourceRevisionDescriptor revisions;
    WorldSourceConstants constants;
};

enum class WorldQueryIntent : std::uint8_t {
    terrain_mesh = 1,
    terrain_collision = 2,
    gameplay = 3,
};

enum class WorldQueryKind : std::uint8_t {
    lattice_cell = 1,
    cell_center = 2,
    surface_column = 3,
};

struct WorldLatticeQuery {
    CellCoord coordinate;
    WorldQueryIntent intent = WorldQueryIntent::terrain_mesh;
};

struct WorldCellCenterQuery {
    CellCoord coordinate;
    WorldQueryIntent intent = WorldQueryIntent::gameplay;
};

struct WorldSurfaceColumnQuery {
    std::int32_t x = 0;
    std::int32_t z = 0;
    WorldQueryIntent intent = WorldQueryIntent::gameplay;
};

// These are the values after Godot's ordinary single-precision Vector3 / Vector2
// storage boundary.  Keep them distinct from the int32 cell domain: callers
// must not reconstruct a cell by rounding one of these lossy coordinates.
struct WorldFloat32Position {
    float x = 0.0F;
    float y = 0.0F;
    float z = 0.0F;
};

struct WorldFloat32HorizontalPosition {
    float x = 0.0F;
    float z = 0.0F;
};

// A lattice result intentionally retains a full cell coordinate and a
// Vector3(cell) * CELL location.  It is for the numeric meshing lattice, not
// a cell-state lookup at the center of that cell.
struct WorldResolvedLatticeQuery {
    CellCoord lattice_cell;
    WorldFloat32Position lattice_position;
    WorldQueryIntent intent = WorldQueryIntent::terrain_mesh;
};

// A center result retains the same integer cell identity but has a different
// physical location: (cell + 0.5) * CELL.  It cannot be substituted for a
// lattice numeric query just because both name the same cell.
struct WorldResolvedCellCenterQuery {
    CellCoord cell;
    WorldFloat32Position center_position;
    WorldQueryIntent intent = WorldQueryIntent::gameplay;
};

// A surface column has no vertical cell coordinate.  Representing it as an
// X/Z location rather than a CellCoord{ x, 0, z } prevents accidental claims
// that its sample is a Y=0 lattice query.
struct WorldResolvedSurfaceColumnQuery {
    std::int32_t lattice_x = 0;
    std::int32_t lattice_z = 0;
    WorldFloat32HorizontalPosition lattice_position;
    WorldQueryIntent intent = WorldQueryIntent::gameplay;
};

WorldQueryKind query_kind(const WorldLatticeQuery &query) noexcept;
WorldQueryKind query_kind(const WorldCellCenterQuery &query) noexcept;
WorldQueryKind query_kind(const WorldSurfaceColumnQuery &query) noexcept;
bool is_valid_world_query_intent(WorldQueryIntent intent) noexcept;
void validate_world_query(const WorldLatticeQuery &query);
void validate_world_query(const WorldCellCenterQuery &query);
void validate_world_query(const WorldSurfaceColumnQuery &query);

// Resolve explicit query intent into the coordinate convention used by the
// production GDScript authority.  Each overload validates its intent before
// returning a typed result.
WorldResolvedLatticeQuery resolve_world_query(const WorldSourceDefinition &definition, const WorldLatticeQuery &query);
WorldResolvedCellCenterQuery resolve_world_query(const WorldSourceDefinition &definition, const WorldCellCenterQuery &query);
WorldResolvedSurfaceColumnQuery resolve_world_query(const WorldSourceDefinition &definition, const WorldSurfaceColumnQuery &query);

struct WorldPhysicalContentIdentity {
    Sha256Digest digest{};
    std::string digest_hex() const;
    bool operator==(const WorldPhysicalContentIdentity &other) const noexcept;
};

class WorldSourceDefinition final {
public:
    explicit WorldSourceDefinition(WorldSourceDescriptor descriptor);
    WorldSourceDefinition(const WorldSourceDefinition &) = default;
    WorldSourceDefinition(WorldSourceDefinition &&) = default;
    WorldSourceDefinition &operator=(const WorldSourceDefinition &) = delete;
    WorldSourceDefinition &operator=(WorldSourceDefinition &&) = delete;
    const AdmittedBiomeSeed &admitted_biome_seed() const noexcept;
    const AdmittedTerrainSeed &raw_terrain_seed() const noexcept;
    const WorldSourceRevisionDescriptor &revisions() const noexcept;
    const WorldSourceConstants &constants() const noexcept;
    const WorldPhysicalContentIdentity &physical_content_identity() const noexcept;

private:
    AdmittedTerrainSeed raw_terrain_seed_;
    AdmittedBiomeSeed admitted_biome_seed_;
    WorldSourceRevisionDescriptor revisions_;
    WorldSourceConstants constants_;
    WorldPhysicalContentIdentity physical_content_identity_;
};

// Sampling implementations bind to both the query type and its explicitly
// versioned convention in the immutable source definition.
std::uint32_t query_revision(const WorldSourceDefinition &definition, const WorldLatticeQuery &query) noexcept;
std::uint32_t query_revision(const WorldSourceDefinition &definition, const WorldCellCenterQuery &query) noexcept;
std::uint32_t query_revision(const WorldSourceDefinition &definition, const WorldSurfaceColumnQuery &query) noexcept;

// Complete canonical shaping-page dependency set for effective terrain
// sampling across one primary integer page. Godot's distinct float32 voxel
// lattice, one-boundary grid numeric, and cell-center round-trips can each
// select a source cell in a neighbouring page, so the exact Cartesian
// dependency set for each convention participates in this bounded union.
std::vector<NativeTerrainPageKey> world_effective_shaping_dependencies(
    const WorldSourceDefinition &definition, NativeTerrainPageKey primary_page);

// Fixed-storage version of the three exact float32 remap dependency sets.
// The caller owns and stamps the immutable definition across calls. Axis
// preparation charges every remap, insertion-sort comparison, and compaction;
// page emission merges four sorted streams without allocating a page vector.
class WorldShapingDependencyCursor final {
public:
    static constexpr std::size_t AXIS_LIMIT = 280U;
    struct Step {
        std::uint32_t consumed_ops = 0;
        std::uint32_t next_atomic_ops = 1;
        bool ready = false;
        bool complete = false;
        bool has_page = false;
        std::int32_t page_x = 0;
        std::int32_t page_z = 0;
    };

    void reset(NativeTerrainPageKey primary) noexcept;
    Step advance_axes(const WorldSourceDefinition &definition, std::uint32_t offered_ops);
    Step next_page(std::uint32_t offered_ops) noexcept;
    Step rewind_pages(std::uint32_t offered_ops) noexcept;
    bool axes_ready() const noexcept;

private:
    std::array<std::array<std::int32_t, AXIS_LIMIT>, 6> axes_{};
    std::array<std::uint16_t, 6> counts_{};
    std::array<std::uint16_t, 3> product_x_{};
    std::array<std::uint16_t, 3> product_z_{};
    std::int32_t primary_x_ = 0;
    std::int32_t primary_z_ = 0;
    std::int32_t last_page_x_ = 0;
    std::int32_t last_page_z_ = 0;
    std::uint16_t collect_index_ = 0;
    std::uint16_t sort_axis_ = 0;
    std::uint16_t sort_i_ = 1;
    std::uint16_t sort_j_ = 1;
    std::uint16_t compact_axis_ = 0;
    std::uint16_t compact_index_ = 0;
    bool primary_pending_ = true;
    bool last_page_valid_ = false;
    std::uint8_t phase_ = 0;
};

// A production pin is page-scoped and requires the complete canonical set of
// ready shaping dependencies. It retains immutable source, shaping, and delta
// snapshots; later registry or delta changes cannot alter it.
class WorldSourcePin final {
public:
    WorldSourcePin(
        WorldSourceDefinition definition,
        WorldDeltaPinnedSnapshot deltas,
        NativeTerrainPageKey primary_page,
        const std::vector<NativeTerrainShapingPagePin> &shaping_pages);
    WorldSourcePin(const WorldSourcePin &) = default;
    WorldSourcePin(WorldSourcePin &&) = default;
    WorldSourcePin &operator=(const WorldSourcePin &) = delete;
    WorldSourcePin &operator=(WorldSourcePin &&) = delete;
    const WorldSourceDefinition &definition() const noexcept;
    const WorldDeltaPinnedSnapshot &deltas() const noexcept;
    const NativeTerrainShapingSnapshot &primary_terrain_shaping() const noexcept;
    const NativeTerrainShapingSnapshot &terrain_shaping_for_page(NativeTerrainPageKey page) const;
    std::size_t terrain_shaping_page_count() const noexcept;
    std::uint64_t terrain_delta_revision() const noexcept;
    std::uint64_t shaping_registry_revision() const noexcept;
    const WorldPhysicalContentIdentity &shaping_registry_content_identity() const noexcept;
    const Sha256Digest &typed_projection_digest_for_page(NativeTerrainPageKey page) const;
    const WorldPhysicalContentIdentity &physical_content_identity() const noexcept;

private:
    WorldSourceDefinition definition_;
    WorldDeltaPinnedSnapshot deltas_;
    std::shared_ptr<const NativeTerrainShapingSnapshot> primary_terrain_shaping_;
    std::vector<std::shared_ptr<const NativeTerrainShapingSnapshot>> terrain_shaping_pages_;
    std::vector<Sha256Digest> typed_projection_digests_;
    std::uint64_t shaping_registry_revision_ = 0;
    WorldPhysicalContentIdentity shaping_registry_content_identity_;
    WorldPhysicalContentIdentity physical_content_identity_;
};

// Scope is an asynchronous publication concern. It is intentionally beside,
// rather than inside, the physical pin and its digest.
struct WorldSourceRequestScope {
    WorldSourcePin pin;
    RequestAuthority authority;
};

} // namespace voxel::world_backend
