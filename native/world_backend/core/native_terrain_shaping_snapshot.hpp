#pragma once

#include "world_source.hpp"

#include <cstddef>
#include <cstdint>
#include <functional>
#include <memory>
#include <optional>
#include <stdexcept>
#include <string>
#include <vector>

namespace voxel::world_backend {

struct NativeHorizontalRect {
    std::int32_t x = 0;
    std::int32_t z = 0;
    std::int32_t width = 0;
    std::int32_t depth = 0;
    bool operator==(const NativeHorizontalRect &other) const noexcept;
};

struct NativeTerrainPageKey {
    std::int32_t x = 0;
    std::int32_t z = 0;
    bool operator==(const NativeTerrainPageKey &other) const noexcept;
};

struct NativeTownTerrainProfile {
    std::int32_t region_x = 0;
    std::int32_t region_z = 0;
    std::int32_t center_x = 0;
    std::int32_t center_z = 0;
    std::int32_t radius_cells = 0;
    double level_meters = 0.0;
};

// An explicit empty dependency suppresses procedural fallback just as a key
// mapped to `{}` does in VoxelWorldGenerationContext.pinned_town_regions.
struct NativeTownRegionOverride {
    std::int32_t region_x = 0;
    std::int32_t region_z = 0;
    bool has_town = false;
    NativeTownTerrainProfile town;
};

// One-time registry admission input. Page construction accepts only the
// immutable admitted handle below and never rescans this full raster.
struct NativeSiteTerrainProfile {
    std::int32_t version = 1;
    std::string world_seed_utf8;
    std::string site_id;
    std::string source_signature;
    double cell_size_meters = 1.35;
    NativeHorizontalRect core_cells;
    NativeHorizontalRect envelope_cells;
    NativeHorizontalRect reservation_cells;
    WorldFloat32Position origin;
    double level_meters = 0.0;
    std::int32_t apron_cells = 0;
    std::vector<std::uint8_t> support_mask;
    std::vector<float> distance_cells;
    std::vector<WorldFloat32Position> ground_root_points;
};

// Immutable page-owned form. `full_profile_digest` is provenance only; page
// physical identity is deliberately derived from the cropped fields/bits.
struct NativeSiteTerrainFragment {
    Sha256Digest full_profile_digest{};
    double level_meters = 0.0;
    std::int32_t apron_cells = 0;
    NativeHorizontalRect cropped_cells;
    std::vector<std::uint8_t> support_mask;
    std::vector<float> distance_cells;
};

enum class NativeTerrainShapingAdmissionFailure : std::uint8_t {
    missing_generation_revision = 1,
    invalid_page = 2,
    town_dependency_count = 3,
    duplicate_town_region = 4,
    town_dependency_scope = 5,
    invalid_town = 6,
    duplicate_site_id = 7,
    invalid_site = 8,
    site_outside_page = 9,
    overlapping_sites = 10,
    site_profile_count = 11,
};

class NativeTerrainShapingAdmissionError final : public std::runtime_error {
public:
    explicit NativeTerrainShapingAdmissionError(NativeTerrainShapingAdmissionFailure failure);
    NativeTerrainShapingAdmissionFailure failure() const noexcept;
private:
    NativeTerrainShapingAdmissionFailure failure_;
};

class NativeTerrainShapingPageQueryError final : public std::out_of_range {
public:
    NativeTerrainShapingPageQueryError();
};

class NativeAdmittedSiteTerrainProfile final {
public:
    NativeAdmittedSiteTerrainProfile(const NativeAdmittedSiteTerrainProfile &) = delete;
    NativeAdmittedSiteTerrainProfile(NativeAdmittedSiteTerrainProfile &&) = delete;
    NativeAdmittedSiteTerrainProfile &operator=(const NativeAdmittedSiteTerrainProfile &) = delete;
    NativeAdmittedSiteTerrainProfile &operator=(NativeAdmittedSiteTerrainProfile &&) = delete;

    const WorldPhysicalContentIdentity &source_definition_identity() const noexcept;
    const Sha256Digest &full_profile_digest() const noexcept;
    const std::string &site_id() const noexcept;
    NativeHorizontalRect envelope_cells() const noexcept;
    double level_meters() const noexcept;
    std::int32_t apron_cells() const noexcept;
    const std::vector<std::uint8_t> &support_mask() const noexcept;
    const std::vector<float> &distance_cells() const noexcept;

private:
    NativeAdmittedSiteTerrainProfile(
        WorldPhysicalContentIdentity source_definition_identity, Sha256Digest full_profile_digest,
        NativeSiteTerrainProfile profile);
    friend std::shared_ptr<const NativeAdmittedSiteTerrainProfile> admit_native_site_terrain_profile(
        const WorldSourceDefinition &, NativeSiteTerrainProfile);

    WorldPhysicalContentIdentity source_definition_identity_;
    Sha256Digest full_profile_digest_{};
    NativeSiteTerrainProfile profile_;
};

using NativeAdmittedSiteTerrainProfileHandle = std::shared_ptr<const NativeAdmittedSiteTerrainProfile>;

NativeAdmittedSiteTerrainProfileHandle admit_native_site_terrain_profile(
    const WorldSourceDefinition &definition, NativeSiteTerrainProfile profile);

struct NativeTerrainShapingRequest {
    std::uint64_t generation_revision = 0;
    NativeTerrainPageKey page_key;
    // Zero to nine explicit records inside the owner's 3x3 neighbourhood.
    // Omission uses deterministic procedural fallback; an explicit empty
    // record suppresses that fallback.
    std::vector<NativeTownRegionOverride> town_overrides;
    // Every supplied immutable admitted profile must intersect this page.
    std::vector<NativeAdmittedSiteTerrainProfileHandle> site_profiles;
};

class NativeTerrainShapingSnapshot final {
public:
    static constexpr std::int32_t PAGE_CELLS = 280;
    static constexpr std::size_t PAGE_SAMPLE_CAPACITY = static_cast<std::size_t>(PAGE_CELLS) * PAGE_CELLS;
    static constexpr std::size_t MAX_TOWN_DEPENDENCIES = 9;
    static constexpr std::size_t MAX_SITE_SAMPLES = 262144;
    static constexpr std::size_t MAX_SITE_ID_BYTES = 2048;
    static constexpr std::size_t MAX_GROUND_ROOT_POINTS = 80000;
    static constexpr std::int32_t MAX_TOWN_APRON_CELLS = 128;

    using NaturalSurfaceSampler = std::function<double(std::int32_t, std::int32_t)>;

    NativeTerrainShapingSnapshot(WorldSourceDefinition definition, NativeTerrainShapingRequest request);
    NativeTerrainShapingSnapshot(const NativeTerrainShapingSnapshot &) = default;
    NativeTerrainShapingSnapshot(NativeTerrainShapingSnapshot &&) = default;
    NativeTerrainShapingSnapshot &operator=(const NativeTerrainShapingSnapshot &) = delete;
    NativeTerrainShapingSnapshot &operator=(NativeTerrainShapingSnapshot &&) = delete;

    const WorldSourceDefinition &definition() const noexcept;
    std::uint64_t generation_revision() const noexcept;
    NativeTerrainPageKey page_key() const noexcept;
    NativeHorizontalRect page_bounds() const noexcept;
    const WorldPhysicalContentIdentity &physical_content_identity() const noexcept;
    const std::vector<NativeTownRegionOverride> &town_overrides() const noexcept;
    const std::vector<NativeSiteTerrainFragment> &site_fragments() const noexcept;
    std::size_t retained_site_samples() const noexcept;
    bool owns_cell(std::int32_t cell_x, std::int32_t cell_z) const noexcept;

    std::optional<NativeTownTerrainProfile> town_dependency(
        std::int32_t region_x, std::int32_t region_z, const NaturalSurfaceSampler &natural_surface) const;
    std::optional<NativeTownTerrainProfile> town_region_at_cell(
        std::int32_t cell_x, std::int32_t cell_z, const NaturalSurfaceSampler &natural_surface) const;
    std::optional<NativeTownTerrainProfile> town_region_for_surface_cell(
        std::int32_t cell_x, std::int32_t cell_z, const NaturalSurfaceSampler &natural_surface) const;
    std::int32_t town_slope_apron_cells(
        const NativeTownTerrainProfile &town, const NaturalSurfaceSampler &natural_surface) const;
    double surface_y(
        std::int32_t cell_x, std::int32_t cell_z, const NaturalSurfaceSampler &natural_surface) const;
    bool town_core_contains(
        std::int32_t cell_x, std::int32_t cell_z, const NaturalSurfaceSampler &natural_surface) const;
    bool site_core_contains(std::int32_t cell_x, std::int32_t cell_z) const;
    bool protects_minimum_overburden(
        std::int32_t cell_x, std::int32_t cell_z, const NaturalSurfaceSampler &natural_surface) const;

private:
    void require_owned(std::int32_t cell_x, std::int32_t cell_z) const;
    const NativeTownRegionOverride *find_override(std::int32_t region_x, std::int32_t region_z) const noexcept;
    const NativeSiteTerrainFragment *site_fragment_at(std::int32_t cell_x, std::int32_t cell_z) const noexcept;

    WorldSourceDefinition definition_;
    std::uint64_t generation_revision_ = 0;
    NativeTerrainPageKey page_key_;
    NativeHorizontalRect page_bounds_;
    std::vector<NativeTownRegionOverride> town_overrides_;
    std::vector<NativeSiteTerrainFragment> site_fragments_;
    std::size_t retained_site_samples_ = 0;
    WorldPhysicalContentIdentity physical_content_identity_;
};

} // namespace voxel::world_backend
