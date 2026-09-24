#pragma once

#include "native_value.hpp"
#include "terrain_snapshot.hpp"
#include "world_source.hpp"

#include <cstddef>
#include <cstdint>
#include <optional>
#include <stdexcept>
#include <string>
#include <vector>

namespace voxel::world_backend {

// These layers describe source composition, not persistence namespaces. Only
// generated_feature_terrain is admitted by the manifest below; the adjacent
// values make the later effective-terrain precedence explicit without adding
// a third NativeCellStateNamespace.
enum class NativeTerrainSourceLayer : std::uint8_t {
    natural_generated = 1,
    generated_feature_terrain = 2,
    durable_terrain_override = 3,
};

enum class NativeGeneratedTerrainPatchRole : std::uint8_t {
    foundation_fill = 1,
    floor_cap = 2,
    interior_clearance = 3,
};

enum class NativeGeneratedTerrainPatchLifecycle : std::uint8_t {
    permanent_site_shaping = 1,
    follows_feature_tombstone = 2,
};

struct NativeInclusiveCellBox final {
    CellCoord minimum;
    CellCoord maximum;

    bool operator==(const NativeInclusiveCellBox &other) const noexcept;
    bool contains(CellCoord cell) const noexcept;
};

struct NativeGeneratedTerrainLight final {
    std::uint8_t sky = 0;
    std::uint8_t block = 0;

    bool operator==(const NativeGeneratedTerrainLight &other) const noexcept;
};

// Generated cells deliberately have no edited/save flag, edit reason,
// persistence namespace, or caller-controlled mesh/projection policy.
struct NativeGeneratedTerrainCellTemplate final {
    TerrainMaterialId material = TerrainMaterialId::air;
    TerrainBiomeId biome = TerrainBiomeId::plains;
    bool solid = false;
    double density = -1.35;
    TerrainFluidId fluid = TerrainFluidId::none;
    NativeGeneratedTerrainLight light;
    std::optional<std::string> block_identity;
    NativeValue metadata = NativeValue::object({});

    bool operator==(const NativeGeneratedTerrainCellTemplate &other) const noexcept;
};

struct NativeGeneratedTerrainPatchOperation final {
    NativeTerrainSourceLayer source_layer = NativeTerrainSourceLayer::generated_feature_terrain;
    std::string owner_feature_id;
    std::uint32_t recipe_revision = 0;
    std::uint32_t deterministic_order = 0;
    std::uint32_t operation_ordinal = 0;
    NativeGeneratedTerrainPatchRole role = NativeGeneratedTerrainPatchRole::foundation_fill;
    NativeGeneratedTerrainPatchLifecycle lifecycle = NativeGeneratedTerrainPatchLifecycle::permanent_site_shaping;
    NativeInclusiveCellBox bounds;
    NativeGeneratedTerrainCellTemplate state;

    bool operator==(const NativeGeneratedTerrainPatchOperation &other) const noexcept;
};

struct NativeGeneratedTerrainPatchLimits final {
    // A normal structure currently contributes three compact boxes. These
    // bounds allow large settlements while rejecting accidental world-sized
    // captures before expansion or publication.
    static constexpr std::size_t MAX_MANIFEST_OPERATIONS = 4096U;
    static constexpr std::size_t MAX_TEXT_FIELD_BYTES = 1024U;
    static constexpr std::size_t MAX_MANIFEST_UTF8_BYTES = 1024U * 1024U;
    // Compact boxes make 1 MiB ample for the hard 4096-operation ceiling
    // while keeping canonical preflight independently testable before the
    // larger retained-representation ceiling.
    static constexpr std::size_t MAX_MANIFEST_CANONICAL_BYTES = 1024U * 1024U;
    static constexpr std::size_t MAX_MANIFEST_RETAINED_BYTES = 16U * 1024U * 1024U;
    static constexpr std::uint64_t MAX_OPERATION_CELL_VOLUME = 4ULL * 1024ULL * 1024ULL;
    static constexpr std::uint64_t MAX_AGGREGATE_CELL_VOLUME = 64ULL * 1024ULL * 1024ULL;
    static constexpr std::size_t MAX_AFFECTED_SECTIONS = 65536U;
    static constexpr std::size_t MAX_PAGE_PROJECTED_OPERATIONS = 2048U;
    static constexpr std::size_t MAX_PAGE_TOMBSTONES = 4096U;
    static constexpr std::uint64_t MAX_PAGE_PROJECTED_CELL_VOLUME = 8ULL * 1024ULL * 1024ULL;
    static constexpr std::size_t MAX_PAGE_RETAINED_BYTES = 4U * 1024U * 1024U;
    static constexpr std::uint8_t MAX_MESH_HALO_CELLS = 16U;
    static constexpr std::int32_t SECTION_SIZE = 16;
};

enum class NativeGeneratedTerrainPatchFailure : std::uint8_t {
    invalid_source_identity = 1,
    invalid_schema_revision = 2,
    invalid_producer_revision = 3,
    invalid_feature_source_revision = 4,
    invalid_text = 5,
    invalid_region = 6,
    operation_count_limit = 7,
    invalid_source_layer = 8,
    invalid_recipe_revision = 9,
    invalid_role = 10,
    invalid_lifecycle = 11,
    invalid_cell_state = 12,
    forbidden_policy_metadata = 13,
    invalid_box = 14,
    coordinate_overflow = 15,
    operation_volume_limit = 16,
    aggregate_volume_limit = 17,
    utf8_bytes_limit = 18,
    canonical_bytes_limit = 19,
    manifest_retained_bytes_limit = 20,
    affected_sections_limit = 21,
    mixed_owner_recipe_revision = 22,
    duplicate_operation_identity = 23,
    conflicting_operation_identity = 24,
    invalid_page_domain = 25,
    invalid_halo = 26,
    invalid_tombstone = 27,
    page_operation_limit = 28,
    page_volume_limit = 29,
    page_retained_bytes_limit = 30,
};

class NativeGeneratedTerrainPatchError final : public std::runtime_error {
public:
    explicit NativeGeneratedTerrainPatchError(NativeGeneratedTerrainPatchFailure failure);
    NativeGeneratedTerrainPatchFailure failure() const noexcept;

private:
    NativeGeneratedTerrainPatchFailure failure_;
};

struct NativeGeneratedTerrainPatchManifestDescriptor final {
    static constexpr std::uint32_t SCHEMA_REVISION = 1U;

    std::uint32_t schema_revision = SCHEMA_REVISION;
    WorldPhysicalContentIdentity world_physical_identity;
    std::string region_id;
    NativeInclusiveCellBox complete_region_bounds;
    std::uint32_t producer_revision = 0;
    std::uint64_t feature_source_revision = 0;
    std::vector<NativeGeneratedTerrainPatchOperation> operations;
};

// Complete deterministic generated-feature content for its declared region,
// independent of load state, cancellation, publication, or footprint history.
class NativeGeneratedTerrainPatchManifest final {
public:
    static NativeGeneratedTerrainPatchManifest admit(
        const NativeGeneratedTerrainPatchManifestDescriptor &descriptor);

    NativeGeneratedTerrainPatchManifest(const NativeGeneratedTerrainPatchManifest &) = default;
    NativeGeneratedTerrainPatchManifest(NativeGeneratedTerrainPatchManifest &&) noexcept = default;
    NativeGeneratedTerrainPatchManifest &operator=(const NativeGeneratedTerrainPatchManifest &) = delete;
    NativeGeneratedTerrainPatchManifest &operator=(NativeGeneratedTerrainPatchManifest &&) = delete;

    std::uint32_t schema_revision() const noexcept;
    const WorldPhysicalContentIdentity &world_physical_identity() const noexcept;
    const std::string &region_id() const noexcept;
    const NativeInclusiveCellBox &complete_region_bounds() const noexcept;
    std::uint32_t producer_revision() const noexcept;
    std::uint64_t feature_source_revision() const noexcept;
    const std::vector<NativeGeneratedTerrainPatchOperation> &operations() const noexcept;
    const std::vector<CellCoord> &affected_sections() const noexcept;
    const std::vector<std::uint8_t> &canonical_binary() const noexcept;
    const Sha256Digest &content_digest() const noexcept;
    std::string content_digest_hex() const;
    std::size_t retained_bytes() const noexcept;

private:
    NativeGeneratedTerrainPatchManifest(
        NativeGeneratedTerrainPatchManifestDescriptor descriptor,
        std::vector<CellCoord> affected_sections,
        std::vector<std::uint8_t> canonical_binary,
        Sha256Digest content_digest,
        std::size_t retained_bytes);

    NativeGeneratedTerrainPatchManifestDescriptor descriptor_;
    std::vector<CellCoord> affected_sections_;
    std::vector<std::uint8_t> canonical_binary_;
    Sha256Digest content_digest_{};
    std::size_t retained_bytes_ = 0U;
};

struct NativeGeneratedTerrainPatchHalo final {
    std::uint8_t x = 0;
    std::uint8_t y = 0;
    std::uint8_t z = 0;
};

struct NativeGeneratedTerrainPageDomain final {
    std::string page_id;
    // Opaque stable scope coordinate. It is identity/provenance, deliberately
    // not a section authority: terrain pages may span multiple 16-cell storage
    // sections and their vertical collision windows are caller-selected.
    CellCoord scope_coordinate;
    NativeInclusiveCellBox owned_bounds;
    // Explicit per-axis halo avoids silently imposing an XZ collision halo on
    // Y. Each axis is independently bounded to 16 cells.
    NativeGeneratedTerrainPatchHalo mesh_halo;
};

struct NativeResolvedGeneratedTerrainPatchCell final {
    CellCoord cell;
    std::string owner_feature_id;
    std::uint32_t recipe_revision = 0;
    std::uint32_t deterministic_order = 0;
    std::uint32_t operation_ordinal = 0;
    NativeGeneratedTerrainPatchRole role = NativeGeneratedTerrainPatchRole::foundation_fill;
    NativeGeneratedTerrainPatchLifecycle lifecycle = NativeGeneratedTerrainPatchLifecycle::permanent_site_shaping;
    NativeGeneratedTerrainCellTemplate state;
};

// Immutable page-local crop. It retains compact clipped boxes, not expanded
// cells. Its digest binds the physical source and exact page domain, but not
// unrelated operations elsewhere in the complete manifest.
// Resolution is later-wins in ascending (deterministic_order, UTF-8 owner ID,
// operation_ordinal) order: the greatest canonical key wins an overlap.
class NativeGeneratedTerrainPatchPageSnapshot final {
public:
    static NativeGeneratedTerrainPatchPageSnapshot project(
        const NativeGeneratedTerrainPatchManifest &manifest,
        const NativeGeneratedTerrainPageDomain &domain,
        const std::vector<std::string> &tombstoned_feature_ids = {});

    NativeGeneratedTerrainPatchPageSnapshot(const NativeGeneratedTerrainPatchPageSnapshot &) = default;
    NativeGeneratedTerrainPatchPageSnapshot(NativeGeneratedTerrainPatchPageSnapshot &&) noexcept = default;
    NativeGeneratedTerrainPatchPageSnapshot &operator=(const NativeGeneratedTerrainPatchPageSnapshot &) = delete;
    NativeGeneratedTerrainPatchPageSnapshot &operator=(NativeGeneratedTerrainPatchPageSnapshot &&) = delete;

    const NativeGeneratedTerrainPageDomain &domain() const noexcept;
    const NativeInclusiveCellBox &projected_bounds() const noexcept;
    const std::vector<NativeGeneratedTerrainPatchOperation> &operations() const noexcept;
    const std::vector<CellCoord> &affected_sections() const noexcept;
    const std::vector<std::uint8_t> &canonical_binary() const noexcept;
    const Sha256Digest &projection_digest() const noexcept;
    std::string projection_digest_hex() const;
    std::size_t retained_bytes() const noexcept;
    std::optional<NativeResolvedGeneratedTerrainPatchCell> resolve(CellCoord cell) const;

private:
    NativeGeneratedTerrainPatchPageSnapshot(
        NativeGeneratedTerrainPageDomain domain,
        NativeInclusiveCellBox projected_bounds,
        std::vector<NativeGeneratedTerrainPatchOperation> operations,
        std::vector<CellCoord> affected_sections,
        std::vector<std::uint8_t> canonical_binary,
        Sha256Digest projection_digest,
        std::size_t retained_bytes);

    NativeGeneratedTerrainPageDomain domain_;
    NativeInclusiveCellBox projected_bounds_;
    std::vector<NativeGeneratedTerrainPatchOperation> operations_;
    std::vector<CellCoord> affected_sections_;
    std::vector<std::uint8_t> canonical_binary_;
    Sha256Digest projection_digest_{};
    std::size_t retained_bytes_ = 0U;
};

} // namespace voxel::world_backend
