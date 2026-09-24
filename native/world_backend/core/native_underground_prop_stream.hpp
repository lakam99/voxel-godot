#pragma once

#include "native_biome_environment_catalog.hpp"
#include "native_effective_terrain_source.hpp"
#include "native_feature_delta.hpp"
#include "native_forage_stream.hpp"
#include "native_surface_forage_ordered_definition.hpp"
#include "native_surface_ore_cluster_definition.hpp"
#include "native_surface_rock_asset_catalog.hpp"
#include "native_surface_rock_definition.hpp"
#include "native_surface_rock_ordered_visual_plan.hpp"

#include <cstdint>
#include <functional>
#include <optional>
#include <stdexcept>
#include <string>
#include <vector>

namespace voxel::world_backend {

struct NativeUndergroundFloorCandidate final {
    std::uint32_t ordinal = 0U;
    CellCoord floor_cell{};
    CellCoord air_cell{};
    TerrainMaterialId material = TerrainMaterialId::air;
    double candidate_roll = 0.0;

    bool operator==(const NativeUndergroundFloorCandidate &other) const noexcept;
};

class NativeUndergroundPropRejected final : public std::invalid_argument {
public:
    NativeUndergroundPropRejected();
};

class NativeUndergroundPropCancelled final : public std::runtime_error {
public:
    NativeUndergroundPropCancelled();
};

// Immutable terrain-volume scan result. It performs the exact production
// x-fastest 28x28 scan and retains only the first 36 hash-admitted exposed
// underground floors. This value has no publication or scene mutation API.
class NativeUndergroundFloorScan final {
public:
    static constexpr std::int32_t CHUNK_CELLS = 28;
    static constexpr std::uint32_t MAX_CANDIDATES = 36U;
    static constexpr std::uint32_t SCHEMA_REVISION = 1U;

    static NativeUndergroundFloorScan create(
        const AdmittedTerrainSeed &seed, std::int32_t chunk_x, std::int32_t chunk_z,
        const NativeEffectiveTerrainSource &terrain,
        const std::function<bool()> &should_cancel = {});

    std::int32_t chunk_x() const noexcept;
    std::int32_t chunk_z() const noexcept;
    std::uint32_t scanned_cells() const noexcept;
    std::uint32_t scanned_columns() const noexcept;
    const WorldPhysicalContentIdentity &source_identity() const noexcept;
    const WorldPhysicalContentIdentity &definition_identity() const noexcept;
    std::uint64_t terrain_delta_revision() const noexcept;
    std::uint64_t shaping_registry_revision() const noexcept;
    const Sha256Digest &shaping_registry_identity() const noexcept;
    const std::vector<NativeUndergroundFloorCandidate> &candidates() const noexcept;
    const Sha256Digest &content_digest() const noexcept;

private:
    NativeUndergroundFloorScan(
        std::int32_t chunk_x, std::int32_t chunk_z, std::uint32_t scanned_cells,
        std::uint32_t scanned_columns, WorldPhysicalContentIdentity source_identity,
        WorldPhysicalContentIdentity definition_identity, std::uint64_t terrain_delta_revision,
        std::uint64_t shaping_registry_revision, Sha256Digest shaping_registry_identity,
        std::vector<NativeUndergroundFloorCandidate> candidates,
        Sha256Digest content_digest) noexcept;

    std::int32_t chunk_x_ = 0;
    std::int32_t chunk_z_ = 0;
    std::uint32_t scanned_cells_ = 0U;
    std::uint32_t scanned_columns_ = 0U;
    WorldPhysicalContentIdentity source_identity_{};
    WorldPhysicalContentIdentity definition_identity_{};
    std::uint64_t terrain_delta_revision_ = 0U;
    std::uint64_t shaping_registry_revision_ = 0U;
    Sha256Digest shaping_registry_identity_{};
    std::vector<NativeUndergroundFloorCandidate> candidates_;
    Sha256Digest content_digest_{};
};

enum class NativeUndergroundPropOutcome : std::uint8_t {
    tombstoned = 1,
    no_feature = 2,
    iron_ore = 3,
    copper_ore = 4,
    rock = 5,
    forage = 6,
};

struct NativeUndergroundRockArtifact final {
    NativeSurfaceRockDefinition definition;
    NativeSurfaceRockAssetSelection selection;
    NativeSurfaceRockVisualIntent visual_intent = NativeSurfaceRockVisualIntent::primitive_required;
};

struct NativeUndergroundForageArtifact final {
    NativeForageRecipe recipe;
    NativeForageStream stream;
    NativeForageDecodedGeometry geometry;
};

struct NativeUndergroundPropAttempt final {
    std::uint32_t ordinal = 0U;
    std::string durable_id;
    NativeUndergroundFloorCandidate candidate;
    bool parent_tombstoned = false;
    NativeUndergroundPropOutcome outcome = NativeUndergroundPropOutcome::no_feature;
    WorldFloat32Position chunk_origin{};
    WorldFloat32Position local_position{};
    WorldFloat32Position world_anchor{};
    std::uint64_t state_before = 0U;
    std::uint64_t state_after_selection = 0U;
    std::uint64_t state_after_recipe = 0U;
    std::optional<float> selection_roll;
    std::optional<float> deep_iron_roll;
    std::optional<NativeOreKind> ore_kind;
    std::optional<NativeSurfaceOreChildDefinition> ore;
    std::optional<NativeUndergroundRockArtifact> rock;
    std::optional<NativeUndergroundForageArtifact> forage;
    Sha256Digest content_digest{};
};

// Whole ordered source artifact for one chunk. The stream is intentionally a
// diagnostic shadow: it cannot publish visuals, install colliders, mutate
// removedProps, or signal navigation/routing readiness.
class NativeUndergroundPropStream final {
public:
    static constexpr std::uint32_t SCHEMA_REVISION = 1U;

    static NativeUndergroundPropStream create(
        const AdmittedTerrainSeed &seed, const NativeUndergroundFloorScan &scan,
        const NativeEffectiveTerrainSource &terrain,
        const NativeBiomeEnvironmentCatalog &biomes,
        const NativeSurfaceRockAssetCatalog &rock_assets,
        const NativeFeatureDeltaSnapshot &removed_props,
        const std::function<bool()> &should_cancel = {});

    std::uint32_t rng_seed() const noexcept;
    std::uint64_t final_rng_state() const noexcept;
    const Sha256Digest &scan_digest() const noexcept;
    const Sha256Digest &removed_props_digest() const noexcept;
    const Sha256Digest &biome_catalog_digest() const noexcept;
    const Sha256Digest &rock_catalog_digest() const noexcept;
    const Sha256Digest &transition_contract_digest() const noexcept;
    const std::vector<NativeUndergroundPropAttempt> &attempts() const noexcept;
    const Sha256Digest &content_digest() const noexcept;
    bool publishable() const noexcept;
    bool channel_footprints_complete() const noexcept;

private:
    NativeUndergroundPropStream(
        std::uint32_t rng_seed, std::uint64_t final_rng_state,
        Sha256Digest scan_digest, Sha256Digest removed_props_digest,
        Sha256Digest biome_catalog_digest, Sha256Digest rock_catalog_digest,
        Sha256Digest transition_contract_digest,
        std::vector<NativeUndergroundPropAttempt> attempts,
        Sha256Digest content_digest) noexcept;

    std::uint32_t rng_seed_ = 0U;
    std::uint64_t final_rng_state_ = 0U;
    Sha256Digest scan_digest_{};
    Sha256Digest removed_props_digest_{};
    Sha256Digest biome_catalog_digest_{};
    Sha256Digest rock_catalog_digest_{};
    Sha256Digest transition_contract_digest_{};
    std::vector<NativeUndergroundPropAttempt> attempts_;
    Sha256Digest content_digest_{};
};

struct NativeUndergroundPropChangedAttempt final {
    std::uint32_t ordinal = 0U;
    std::string before_durable_id;
    std::string after_durable_id;
    NativeUndergroundPropOutcome before_outcome = NativeUndergroundPropOutcome::no_feature;
    NativeUndergroundPropOutcome after_outcome = NativeUndergroundPropOutcome::no_feature;
    Sha256Digest before_identity{};
    Sha256Digest after_identity{};
};

// Before/after diagnostic for tombstone-driven shared-RNG shifts. It reports
// changed source rows but deliberately cannot satisfy WorldDeltaStore's
// complete all-channel feature-footprint admission.
class NativeUndergroundPropTransition final {
public:
    static NativeUndergroundPropTransition create(
        const NativeUndergroundPropStream &before,
        const NativeUndergroundPropStream &after);

    const std::vector<NativeUndergroundPropChangedAttempt> &changed() const noexcept;
    const Sha256Digest &content_digest() const noexcept;
    bool publishable() const noexcept;
    bool channel_footprints_complete() const noexcept;

private:
    NativeUndergroundPropTransition(
        std::vector<NativeUndergroundPropChangedAttempt> changed,
        Sha256Digest content_digest) noexcept;

    std::vector<NativeUndergroundPropChangedAttempt> changed_;
    Sha256Digest content_digest_{};
};

std::uint32_t native_underground_prop_chunk_rng_seed(
    const AdmittedTerrainSeed &seed, std::int32_t chunk_x, std::int32_t chunk_z);
double native_underground_prop_candidate_roll(
    const AdmittedTerrainSeed &seed, CellCoord floor_cell);

} // namespace voxel::world_backend
