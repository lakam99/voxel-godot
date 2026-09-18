#pragma once

#include "authority.hpp"
#include "biome_region_field.hpp"
#include "sha256.hpp"
#include "world_delta_store.hpp"

#include <cstdint>
#include <string>

namespace voxel::world_backend {

class WorldSourceDefinition;

// Generated physical content is deliberately distinct from request ownership:
// cancellation and publication authority never change this definition.
struct WorldSourceRevisionDescriptor {
    std::uint32_t source_schema_revision = 1;
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
    double minimum_surface_meters = 4.0;
    double maximum_surface_meters = 120.0;
};

struct WorldSourceDescriptor {
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
    const WorldSourceRevisionDescriptor &revisions() const noexcept;
    const WorldSourceConstants &constants() const noexcept;
    const WorldPhysicalContentIdentity &physical_content_identity() const noexcept;

private:
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

// A pin retains both immutable source definition and immutable delta-store
// snapshot; later delta commits cannot alter its revision or content identity.
class WorldSourcePin final {
public:
    WorldSourcePin(WorldSourceDefinition definition, WorldDeltaPinnedSnapshot deltas);
    WorldSourcePin(const WorldSourcePin &) = default;
    WorldSourcePin(WorldSourcePin &&) = default;
    WorldSourcePin &operator=(const WorldSourcePin &) = delete;
    WorldSourcePin &operator=(WorldSourcePin &&) = delete;
    const WorldSourceDefinition &definition() const noexcept;
    const WorldDeltaPinnedSnapshot &deltas() const noexcept;
    std::uint64_t terrain_delta_revision() const noexcept;
    const WorldPhysicalContentIdentity &physical_content_identity() const noexcept;

private:
    WorldSourceDefinition definition_;
    WorldDeltaPinnedSnapshot deltas_;
    WorldPhysicalContentIdentity physical_content_identity_;
};

// Scope is an asynchronous publication concern. It is intentionally beside,
// rather than inside, the physical pin and its digest.
struct WorldSourceRequestScope {
    WorldSourcePin pin;
    RequestAuthority authority;
};

} // namespace voxel::world_backend
