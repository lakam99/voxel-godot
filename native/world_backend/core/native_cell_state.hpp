#pragma once

#include "coordinates.hpp"
#include "native_value.hpp"
#include "terrain_snapshot.hpp"

#include <cstddef>
#include <cstdint>
#include <optional>
#include <stdexcept>
#include <string>
#include <vector>

namespace voxel::world_backend {

// Test-only corruption seam, mirroring NativeValueTestAccess. Production code
// has no API for constructing an invalid block identity.
struct NativeBlockIdentityTestAccess;

// This model mirrors only TerrainVolumeService's normalized, persisted cell
// fields.  Surface columns and lattice samples deliberately have their own
// types below: putting either into NativeCellState would recreate the current
// script-side ambiguity between a cell-centre state and a numeric mesh query.
enum class NativeCellStateNamespace : std::uint8_t {
    durable_terrain = 1,
    scene_overlay = 2,
};

class NativeCellStateRejected final : public std::invalid_argument {
public:
    NativeCellStateRejected();
};

// A block identity is intentionally a separate, optional field rather than
// an alias for TerrainMaterialId.  For example, a torch or door can be
// terrain-solid or terrain-air according to the volume state while retaining
// a distinct gameplay/render identity.  An absent identity preserves the
// existing material-only terrain state without inventing a block type.
class NativeBlockIdentity final {
public:
    static NativeBlockIdentity create(std::string value);

    const std::string &value() const noexcept;

    bool operator==(const NativeBlockIdentity &other) const noexcept;
    bool operator!=(const NativeBlockIdentity &other) const noexcept;

private:
    friend struct NativeBlockIdentityTestAccess;
    explicit NativeBlockIdentity(std::string value);

    std::string value_;
};

struct NativeCellLight {
    std::uint8_t sky = 0;
    std::uint8_t block = 0;

    bool operator==(const NativeCellLight &other) const noexcept;
};

struct NativeCellStateInput {
    CellCoord cell;
    TerrainMaterialId material = TerrainMaterialId::air;
    TerrainBiomeId biome = TerrainBiomeId::plains;
    bool solid = false;
    double density = -1.35;
    TerrainFluidId fluid = TerrainFluidId::none;
    NativeCellLight light;
    // Metadata is one canonical recursive object, not a flat string-pair
    // channel.  The state factory rejects every non-object value.
    NativeValue metadata = NativeValue::object({});
    std::optional<NativeBlockIdentity> block_id;
    bool generated = true;
    bool edited = false;
};

struct NativeCellState {
    static constexpr std::int32_t SECTION_SIZE = 16;

    CellCoord cell;
    CellCoord section;
    CellCoord local_cell;
    TerrainMaterialId material = TerrainMaterialId::air;
    TerrainBiomeId biome = TerrainBiomeId::plains;
    bool solid = false;
    double density = -1.35;
    TerrainFluidId fluid = TerrainFluidId::none;
    NativeCellLight light;
    NativeValue metadata = NativeValue::object({});
    std::optional<NativeBlockIdentity> block_id;
    bool generated = true;
    bool edited = false;

    bool operator==(const NativeCellState &other) const noexcept;
};

// Transient numeric facts are intentionally incapable of carrying material,
// biome, metadata, or save flags.  A lattice position is not a cell centre.
struct NativeLatticeNumericFacts {
    CellCoord lattice_cell;
    double density = 0.0;
    bool underground_air_void = false;
};

// A surface/column value is transient independently from both state and mesh
// density. It is keyed solely by XZ; callers must not serialize it as a cell.
struct NativeSurfaceColumnFacts {
    std::int32_t cell_x = 0;
    std::int32_t cell_z = 0;
    double reference_surface_y = 0.0;
    double deformed_surface_y = 0.0;
};

struct NativeCellStatePersistencePolicy {
    NativeCellStateNamespace name_space = NativeCellStateNamespace::durable_terrain;
    bool persists_in_save = true;
    bool affects_terrain_mesh = true;
    bool affects_surface_projection = true;
};

NativeCellState make_native_cell_state(
    const NativeCellStateInput &input,
    NativeCellStateNamespace name_space = NativeCellStateNamespace::durable_terrain);
std::size_t native_cell_state_section_index(const NativeCellState &state);
NativeCellStatePersistencePolicy native_cell_state_policy(NativeCellStateNamespace name_space) noexcept;

// Save v2 has one stable coordinate ordering regardless of in-memory map or
// section layout: z, then y, then x.  It is intentionally not section order.
bool native_cell_state_v2_save_less(const NativeCellState &left, const NativeCellState &right) noexcept;
std::vector<NativeCellState> sort_native_cell_states_v2_for_save(std::vector<NativeCellState> states);

} // namespace voxel::world_backend
