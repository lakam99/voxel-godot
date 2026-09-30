#pragma once

#include "fast_noise_compat.hpp"
#include "world_source.hpp"

#include <functional>
#include <cstdint>
#include <map>
#include <mutex>
#include <optional>
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
    std::vector<CaveSegment> segments;
    std::vector<CaveChamber> chambers;
    CaveBounds bounds;
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
    double density(CaveVector3 position, double depth_meters,
        const SurfaceSampler &surface, const ProtectedBounds &protected_bounds) const;
    double recipe_density(CaveVector3 position, const CaveRecipe &recipe) const;
    CacheStats cache_stats() const;

private:
    std::optional<CaveRecipe> build_recipe(
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
    double fit_chamber_vertical_radius(const CaveVector3 &floor_point,
        double radius_x, double radius_z, double requested_radius,
        const SurfaceSampler &surface) const;
    std::uint32_t region_seed(CaveRegionKey region) const noexcept;

    std::vector<std::uint32_t> seed_code_points_;
    double cell_size_meters_ = 1.35;
    CaveNoiseCompat noise_;
    mutable std::mutex cache_mutex_;
    mutable std::map<CaveRegionKey, std::optional<CaveRecipe>> recipe_cache_;
    mutable CacheStats cache_stats_;
};

} // namespace voxel::world_backend
