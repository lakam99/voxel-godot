#pragma once

#include "native_surface_prop_baseline_stream.hpp"
#include "native_surface_prop_rng_trace.hpp"
#include "native_effective_terrain_source.hpp"

#include <array>
#include <cstdint>
#include <stdexcept>
#include <string>
#include <vector>

namespace voxel::world_backend {

enum class NativeSurfacePropPlacementPresence : std::uint8_t {
    absent = 1,
    anchored = 2,
};

// Exact Godot chunk.position + prop.position float32 transform boundary.
// Both operands round through Vector3 storage before global addition.
struct NativeSurfacePropChunkFrame final {
    WorldFloat32Position chunk_origin{};
    WorldFloat32Position local_position{};
    WorldFloat32Position world_anchor{};
};

NativeSurfacePropChunkFrame resolve_native_surface_prop_chunk_frame(
    std::int32_t chunk_x, std::int32_t chunk_z,
    std::int32_t cell_x, std::int32_t cell_z,
    double cell_size_meters, float anchor_y);

struct NativeSurfacePropPlacementEntry final {
    std::uint32_t ordinal = 0U;
    std::string durable_id;
    std::int32_t cell_x = 0;
    std::int32_t cell_z = 0;
    std::int32_t chunk_x = 0;
    std::int32_t chunk_z = 0;
    WorldFloat32Position chunk_origin{};
    WorldFloat32Position local_position{};
    Sha256Digest source_decision_digest{};
    NativeSurfacePropClassificationOutcome outcome = NativeSurfacePropClassificationOutcome::no_feature;
    NativeSurfacePropPlacementPresence presence = NativeSurfacePropPlacementPresence::absent;
    NativeSurfacePropSpawnMode mode = NativeSurfacePropSpawnMode::generated_surface_fast;
    double source_height_meters = 0.0;
    TerrainBiomeId biome = TerrainBiomeId::plains;
    TerrainMaterialId material = TerrainMaterialId::air;
    CellCoord solid_cell{};
    CellCoord air_cell{};
    WorldFloat32Position world_anchor{};
};

class NativeSurfacePropPlacementSetRejected final : public std::invalid_argument {
public:
    NativeSurfacePropPlacementSetRejected();
};

// Immutable, source-bound placement witness for one full surface-prop attempt
// stream. SPP2 derives every physical anchor from one pinned effective terrain
// source. No caller-supplied height or support pair can become production
// authority. It is not a feature footprint or publication catalog.
class NativeSurfacePropPlacementSet final {
public:
    static constexpr std::uint32_t SCHEMA_REVISION = 2U;

    static NativeSurfacePropPlacementSet create(
        const NativeSurfacePropAttemptStream &attempts,
        const NativeSurfacePropBaselineStream &baseline,
        NativeSurfacePropSourceReceipt source_receipt,
        const NativeEffectiveTerrainSource &terrain);

    const NativeSurfacePropSourceReceipt &source_receipt() const noexcept;
    const WorldPhysicalContentIdentity &world_source_identity() const noexcept;
    const WorldPhysicalContentIdentity &definition_source_identity() const noexcept;
    std::uint64_t terrain_delta_revision() const noexcept;
    std::uint64_t shaping_registry_revision() const noexcept;
    const std::array<NativeSurfacePropPlacementEntry, NativeSurfacePropAttemptStream::ATTEMPT_COUNT> &
    entries() const noexcept;
    const std::vector<std::uint8_t> &canonical_binary() const noexcept;
    const Sha256Digest &content_digest() const noexcept;

private:
    NativeSurfacePropPlacementSet(
        NativeSurfacePropSourceReceipt source_receipt,
        WorldPhysicalContentIdentity world_source_identity,
        WorldPhysicalContentIdentity definition_source_identity,
        std::uint64_t terrain_delta_revision, std::uint64_t shaping_registry_revision,
        std::array<NativeSurfacePropPlacementEntry, NativeSurfacePropAttemptStream::ATTEMPT_COUNT> entries,
        std::vector<std::uint8_t> canonical_binary, Sha256Digest content_digest) noexcept;

    NativeSurfacePropSourceReceipt source_receipt_{};
    WorldPhysicalContentIdentity world_source_identity_{};
    WorldPhysicalContentIdentity definition_source_identity_{};
    std::uint64_t terrain_delta_revision_ = 0U;
    std::uint64_t shaping_registry_revision_ = 0U;
    std::array<NativeSurfacePropPlacementEntry, NativeSurfacePropAttemptStream::ATTEMPT_COUNT> entries_{};
    std::vector<std::uint8_t> canonical_binary_;
    Sha256Digest content_digest_{};
};

} // namespace voxel::world_backend
