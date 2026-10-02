#pragma once

#include "fast_noise_compat.hpp"
#include "world_source.hpp"

#include <functional>
#include <cstdint>
#include <map>
#include <memory>
#include <mutex>
#include <optional>
#include <string>
#include <vector>

namespace voxel::world_backend {

struct CaveVector3 {
    float x = 0.0F;
    float y = 0.0F;
    float z = 0.0F;
};

struct CaveBounds {
    CaveVector3 position;
    CaveVector3 size;
    bool contains(CaveVector3 point) const noexcept;
    void merge(const CaveBounds &other) noexcept;
};

struct CaveSegment {
    CaveVector3 a;
    CaveVector3 b;
    double radius = 0.0;
    double radius_end = 0.0;
    double vertical_radius = 0.0;
    double vertical_radius_end = 0.0;
    CaveBounds bounds;
};

struct CaveChamber {
    CaveVector3 center;
    CaveVector3 radii;
};

struct CaveDepthTierLink {
    std::string id;
    std::uint32_t from_tier = 0U;
    std::uint32_t to_tier = 0U;
    std::vector<CaveVector3> points;
};

struct CaveRegionKey {
    std::int32_t x = 0;
    std::int32_t z = 0;
    bool operator<(const CaveRegionKey &other) const noexcept {
        return z != other.z ? z < other.z : x < other.x;
    }
    bool operator==(const CaveRegionKey &other) const noexcept {
        return x == other.x && z == other.z;
    }
};

struct CaveRecipe {
    CaveRegionKey region;
    CaveVector3 entry;
    CaveVector3 outward;
    std::vector<CaveVector3> route;
    std::vector<CaveVector3> loop;
    std::vector<CaveVector3> deep_route;
    std::vector<std::vector<CaveVector3>> depth_loops;
    std::vector<CaveDepthTierLink> depth_tier_links;
    std::vector<CaveSegment> segments;
    std::vector<CaveChamber> chambers;
    CaveBounds bounds;
};

struct CaveCenterAttemptDiagnostics {
    CaveVector3 center;
    std::uint32_t directions_evaluated = 0U;
    std::uint32_t viable_entrances = 0U;
    std::uint32_t full_recipe_attempts = 0U;
    std::string terminal_reason;
    std::string last_rejection_detail;
    std::map<std::string, std::uint32_t> rejection_counts;
};

struct CaveRecipeBuildDiagnostics {
    std::uint32_t centers_attempted = 0U;
    std::uint32_t directions_evaluated = 0U;
    std::uint64_t build_time_usec = 0U;
    std::string terminal_reason;
    std::vector<CaveCenterAttemptDiagnostics> centers;
};

// Native port of scripts/world/ProceduralCaveField.gd. Inputs are callbacks
// over the owning native source only during deterministic recipe construction;
// the returned recipe contains values, never Nodes or retained callbacks.
class NativeProceduralCaveField final {
public:
    struct CacheStats { std::uint64_t recipe_build_count = 0; std::uint64_t recipe_build_total_usec = 0; std::uint64_t recipe_build_max_usec = 0; std::uint64_t cache_evictions = 0; };
    using SurfaceSampler = std::function<double(float, float)>;
    using ProtectedBounds = std::function<bool(const CaveBounds &)>;

    explicit NativeProceduralCaveField(const WorldSourceDefinition &definition);
    NativeProceduralCaveField(const NativeProceduralCaveField &) = delete;
    NativeProceduralCaveField &operator=(const NativeProceduralCaveField &) = delete;

    static CaveRegionKey region_at(CaveVector3 position);
    std::optional<CaveRecipe> recipe_for_region(
        CaveRegionKey region, const SurfaceSampler &surface,
        const ProtectedBounds &protected_bounds) const;
    bool recipe_bounds_intersects_xz_footprint(
        CaveVector3 position, double radius, const SurfaceSampler &surface,
        const ProtectedBounds &protected_bounds) const;
    std::optional<CaveRecipeBuildDiagnostics> build_diagnostics(CaveRegionKey region) const;
    double density(CaveVector3 position, double depth_meters,
        const SurfaceSampler &surface, const ProtectedBounds &protected_bounds) const;
    double recipe_density(CaveVector3 position, const CaveRecipe &recipe) const;
    CacheStats cache_stats() const;

private:
    std::optional<CaveRecipe> build_recipe(
        CaveRegionKey region, const SurfaceSampler &surface,
        const ProtectedBounds &protected_bounds,
        CaveRecipeBuildDiagnostics &diagnostics) const;
    std::optional<CaveRecipe> build_recipe_at_offset(
        CaveRegionKey region, CaveVector3 center_offset,
        const SurfaceSampler &surface, const ProtectedBounds &protected_bounds,
        CaveCenterAttemptDiagnostics &diagnostics) const;
    std::shared_ptr<const CaveRecipe> recipe_snapshot_for_region(
        CaveRegionKey region, const SurfaceSampler &surface,
        const ProtectedBounds &protected_bounds) const;
    CaveRecipe append_path(CaveRecipe recipe,
        const std::vector<CaveVector3> &points, double radius) const;
    CaveRecipe append_tapered_path(CaveRecipe recipe,
        const std::vector<CaveVector3> &points,
        const std::vector<double> &radii) const;
    CaveRecipe append_tapered_arch_path(CaveRecipe recipe,
        const std::vector<CaveVector3> &points,
        const std::vector<double> &radii,
        const std::vector<double> &vertical_radii) const;
    bool interior_segments_keep_natural_roof(const CaveRecipe &recipe,
        std::size_t first_interior_segment, const SurfaceSampler &surface) const;
    bool route_has_walkable_effective_support(const CaveRecipe &recipe,
        const SurfaceSampler &surface, std::string *failure_detail = nullptr) const;
    double candidate_volume_ground_height_near(const CaveRecipe &recipe,
        CaveVector3 position, const SurfaceSampler &surface) const;
    double candidate_volume_density_at_cell(const CaveRecipe &recipe,
        std::int32_t x, std::int32_t y, std::int32_t z,
        const SurfaceSampler &surface) const;
    double fit_chamber_vertical_radius(const CaveVector3 &floor_point,
        double radius_x, double radius_z, double requested_radius,
        const SurfaceSampler &surface) const;
    std::uint32_t region_seed(CaveRegionKey region) const noexcept;

    std::vector<std::uint32_t> seed_code_points_;
    std::string seed_utf8_;
    double cell_size_meters_ = 1.35;
    double lowest_cave_floor_meters_ = -81.0;
    CaveNoiseCompat noise_;
    mutable std::mutex cache_mutex_;
    mutable std::map<CaveRegionKey, std::shared_ptr<const CaveRecipe>> recipe_cache_;
    mutable std::map<CaveRegionKey, CaveRecipeBuildDiagnostics> recipe_diagnostics_;
    mutable CacheStats cache_stats_;
};

} // namespace voxel::world_backend
