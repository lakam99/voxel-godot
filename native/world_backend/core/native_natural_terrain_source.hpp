#pragma once

#include "native_cell_state.hpp"
#include "native_procedural_cave_field.hpp"
#include "world_source.hpp"
#include "fast_noise_compat.hpp"

#include <array>
#include <cstdint>
#include <memory>
#include <stdexcept>

namespace voxel::world_backend {

class NativeEffectiveTerrainSource;

// This initial N3 kernel accepts natural terrain only.  The production source
// can shape a column through a generated town or BuildingTerrainProfile;
// sampling natural terrain in their presence would be a second authority.
enum class NativeTerrainShapingInput : std::uint8_t {
    declared_absent = 0,
    generated_town_profiles_present = 1,
    generated_site_profiles_present = 2,
};

struct NativeNaturalTerrainRequest {
    NativeTerrainShapingInput shaping_input = NativeTerrainShapingInput::declared_absent;
};

class NativeNaturalTerrainUnsupported final : public std::runtime_error {
public:
    explicit NativeNaturalTerrainUnsupported(NativeTerrainShapingInput input);
    NativeTerrainShapingInput input() const noexcept;
private:
    NativeTerrainShapingInput input_;
};

// Pure natural-terrain sampler: it consumes the immutable WorldSource
// definition and does not callback into GDScript or carry a fallback source.
class NativeNaturalTerrainSource final {
public:
    NativeNaturalTerrainSource(WorldSourceDefinition definition, NativeNaturalTerrainRequest request = {});
    NativeNaturalTerrainSource(const NativeNaturalTerrainSource &) = delete;
    NativeNaturalTerrainSource(NativeNaturalTerrainSource &&) noexcept = default;
    NativeNaturalTerrainSource &operator=(const NativeNaturalTerrainSource &) = delete;
    NativeNaturalTerrainSource &operator=(NativeNaturalTerrainSource &&) = delete;

    const WorldSourceDefinition &definition() const noexcept;
    NativeSurfaceColumnFacts sample_surface_column(const WorldSurfaceColumnQuery &query) const;
    TerrainBiomeId sample_surface_biome(const WorldSurfaceColumnQuery &query) const;
    NativeLatticeNumericFacts sample_lattice_numeric(const WorldLatticeQuery &query) const;
    NativeCellState sample_cell_state(const WorldCellCenterQuery &query) const;

private:
    friend class NativeEffectiveTerrainSource;
    struct GeneratedSample;
    GeneratedSample sample_generated_at_position(
        const WorldFloat32Position &position, const CellCoord &numeric_coordinate) const;
    double natural_surface_y(std::int32_t x, std::int32_t z) const;
    TerrainBiomeId natural_surface_biome(std::int32_t x, std::int32_t z) const;
    TerrainBiomeId regional_surface_biome(std::int32_t x, std::int32_t z) const;
    double cave_density(const WorldFloat32Position &position, double base_surface_y) const;
    TerrainMaterialId solid_material_for(
        const CellCoord &cell, double surface_y, double position_y, TerrainBiomeId biome,
        double density) const;
    TerrainMaterialId world_sample_material_for(
        const CellCoord &cell, double surface_y, double position_y, TerrainBiomeId biome,
        double density) const;
    TerrainFluidId underground_fluid_for(
        const CellCoord &cell, const WorldFloat32Position &position, double depth_cells,
        TerrainBiomeId surface_biome) const;

    WorldSourceDefinition definition_;
    std::uint32_t seed_hash_ = 0;
    std::unique_ptr<NativeProceduralCaveField> caves_;
};

// Numeric prerequisite only: no material/fluid or generated-cell-state API.
// Cave density is intentionally absent: it depends on complete effective
// shaping inputs and belongs to NativeEffectiveTerrainSource, not the
// standalone natural-only quota cursor.
enum class NaturalComponent : std::uint8_t { surface_height, regional_biome };
struct NaturalRequest {
    NaturalComponent component = NaturalComponent::surface_height;
    std::int32_t x = 0;
    std::int32_t z = 0;
};
struct NumericNaturalSample { double value; NumericBiomeSample regional; };
// Fixed scalar intermediates shared by the synchronous natural sampler and
// its quota-driven cursor. No source, noise object or generated cell is owned.
struct NaturalScalarStageState { std::array<double, 16> values; double result; };
struct NaturalCursor {
    NaturalCursor() noexcept;
    EvaluatorStamp stamp;
    ContextIdentity context;
    EvalStatus status;
    EvalReason reason;
    NaturalRequest request;
    BiomeCursor biome;
    NaturalScalarStageState scalars;
    NumericNaturalSample result;
    std::uint8_t stage;
    std::uint8_t sample;
};
struct NaturalStep { EvalStep step; NumericNaturalSample value; };
EvalStep begin_natural(NaturalCursor &, EvaluatorStamp, ContextIdentity, NaturalRequest, WorkQuota &) noexcept;
NaturalStep advance_natural(NaturalCursor &, EvaluatorStamp, const WorldSourceDefinition &,
    NoiseCursor &, StorageSpan, WorkQuota &) noexcept;
ControlResult cancel_natural(NaturalCursor &) noexcept;
ControlResult reset_natural(NaturalCursor &) noexcept;

} // namespace voxel::world_backend
