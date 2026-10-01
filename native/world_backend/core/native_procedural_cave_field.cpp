#include "native_procedural_cave_field.hpp"

#include "godot_pcg_compat.hpp"

#include <algorithm>
#include <cmath>
#include <chrono>
#include <limits>
#include <stdexcept>
#include <string>

namespace voxel::world_backend {
namespace {
constexpr double REGION_METRES = 192.0;
constexpr std::size_t RECIPE_CACHE_LIMIT = 128U;
constexpr float ROCK = 8.0F;
constexpr double TUNNEL_RADIUS = 2.7;
constexpr double DEEP_LEVEL_DROP_METERS = 18.0;
constexpr std::size_t MAX_DEEP_LEVELS = 7U;
constexpr double PI = 3.14159265358979323846;
constexpr double TAU = 6.28318530717958647692;

CaveVector3 add(CaveVector3 a, CaveVector3 b) noexcept { return {a.x + b.x, a.y + b.y, a.z + b.z}; }
CaveVector3 subtract(CaveVector3 a, CaveVector3 b) noexcept { return {a.x - b.x, a.y - b.y, a.z - b.z}; }
CaveVector3 multiply(CaveVector3 a, double value) noexcept {
    // Vector3's operator*(float) converts the Variant scalar to real_t before
    // multiplying each float component; it does not multiply in double first.
    const float real_value = static_cast<float>(value);
    return {a.x * real_value, a.y * real_value, a.z * real_value};
}
CaveVector3 divide(CaveVector3 a, CaveVector3 b) noexcept { return {a.x / b.x, a.y / b.y, a.z / b.z}; }
CaveVector3 lerp(CaveVector3 a, CaveVector3 b, double t) noexcept { return add(a, multiply(subtract(b, a), t)); }
float dot_xz(CaveVector3 a, CaveVector3 b) noexcept { return a.x * b.x + a.z * b.z; }
float length_squared_xz(CaveVector3 a) noexcept { return a.x * a.x + a.z * a.z; }
float length(CaveVector3 a) noexcept { return std::sqrt(a.x * a.x + a.y * a.y + a.z * a.z); }
float clamp01(const float value) noexcept { return std::clamp(value, 0.0F, 1.0F); }
float randf_range(GodotPcg32 &rng, const float from, const float to) noexcept {
    // Godot's randf_range rounds the interpolated result to real_t before a
    // caller may promote it into a scalar expression or Vector3 constructor.
    return from + rng.randf() * (to - from);
}
std::uint32_t fnv_append(std::uint32_t hash, const std::uint32_t value) noexcept {
    return (hash ^ value) * 16777619U;
}
void append_ascii(std::uint32_t &hash, const std::string &value) noexcept {
    for (const unsigned char character : value) hash = fnv_append(hash, character);
}
float max3(const float a, const float b, const float c) noexcept { return std::max(a, std::max(b, c)); }
float min3(const float a, const float b, const float c) noexcept { return std::min(a, std::min(b, c)); }
} // namespace

bool CaveBounds::contains(const CaveVector3 point) const noexcept {
    return point.x >= position.x && point.y >= position.y && point.z >= position.z
        && point.x < position.x + size.x && point.y < position.y + size.y
        && point.z < position.z + size.z;
}

void CaveBounds::merge(const CaveBounds &other) noexcept {
    const CaveVector3 low{std::min(position.x, other.position.x),
        std::min(position.y, other.position.y), std::min(position.z, other.position.z)};
    const CaveVector3 high{std::max(position.x + size.x, other.position.x + other.size.x),
        std::max(position.y + size.y, other.position.y + other.size.y),
        std::max(position.z + size.z, other.position.z + other.size.z)};
    position = low;
    size = subtract(high, low);
}

NativeProceduralCaveField::NativeProceduralCaveField(const WorldSourceDefinition &definition)
    : seed_code_points_(definition.raw_terrain_seed().code_points),
      cell_size_meters_(definition.constants().cell_size_meters),
      lowest_cave_floor_meters_(static_cast<double>(definition.constants().world_bottom_cell_y + 4)
          * definition.constants().cell_size_meters),
      noise_(seed_code_points_) {}

CaveRegionKey NativeProceduralCaveField::region_at(const CaveVector3 position) {
    if (!std::isfinite(position.x) || !std::isfinite(position.z))
        throw std::invalid_argument("native cave position must be finite");
    const double region_x = std::floor((static_cast<double>(position.x) + 96.0) / 192.0);
    const double region_z = std::floor((static_cast<double>(position.z) + 96.0) / 192.0);
    if (region_x < static_cast<double>(std::numeric_limits<std::int32_t>::min())
        || region_x > static_cast<double>(std::numeric_limits<std::int32_t>::max())
        || region_z < static_cast<double>(std::numeric_limits<std::int32_t>::min())
        || region_z > static_cast<double>(std::numeric_limits<std::int32_t>::max()))
        throw std::out_of_range("native cave region is outside int32");
    return {static_cast<std::int32_t>(region_x), static_cast<std::int32_t>(region_z)};
}

std::uint32_t NativeProceduralCaveField::region_seed(const CaveRegionKey region) const noexcept {
    std::uint32_t hash = 2166136261U;
    for (const std::uint32_t code_point : seed_code_points_) hash = fnv_append(hash, code_point);
    append_ascii(hash, ":cave-region:");
    append_ascii(hash, std::to_string(region.x));
    append_ascii(hash, ",");
    append_ascii(hash, std::to_string(region.z));
    return hash;
}

std::optional<CaveRecipe> NativeProceduralCaveField::recipe_for_region(
    const CaveRegionKey region, const SurfaceSampler &surface,
    const ProtectedBounds &protected_bounds) const {
    const std::shared_ptr<const CaveRecipe> recipe = recipe_snapshot_for_region(
        region, surface, protected_bounds);
    return recipe ? std::optional<CaveRecipe>(*recipe) : std::nullopt;
}

std::shared_ptr<const CaveRecipe> NativeProceduralCaveField::recipe_snapshot_for_region(
    const CaveRegionKey region, const SurfaceSampler &surface,
    const ProtectedBounds &protected_bounds) const {
    if (!surface || !protected_bounds) throw std::invalid_argument("native cave recipe inputs are required");
    {
        const std::lock_guard<std::mutex> lock(cache_mutex_);
        const auto found = recipe_cache_.find(region);
        if (found != recipe_cache_.end()) return found->second;
    }
    const auto started = std::chrono::steady_clock::now();
    const std::optional<CaveRecipe> built = build_recipe(region, surface, protected_bounds);
    const std::shared_ptr<const CaveRecipe> snapshot = built
        ? std::make_shared<const CaveRecipe>(*built) : std::shared_ptr<const CaveRecipe>{};
    const auto elapsed = static_cast<std::uint64_t>(std::chrono::duration_cast<std::chrono::microseconds>(
        std::chrono::steady_clock::now() - started).count());
    {
        const std::lock_guard<std::mutex> lock(cache_mutex_);
        const auto found = recipe_cache_.find(region);
        if (found != recipe_cache_.end()) return found->second;
        ++cache_stats_.recipe_build_count;
        cache_stats_.recipe_build_total_usec += elapsed;
        cache_stats_.recipe_build_max_usec = std::max(cache_stats_.recipe_build_max_usec, elapsed);
        if (recipe_cache_.size() >= RECIPE_CACHE_LIMIT) { recipe_cache_.clear(); ++cache_stats_.cache_evictions; }
        recipe_cache_.emplace(region, snapshot);
    }
    return snapshot;
}

NativeProceduralCaveField::CacheStats NativeProceduralCaveField::cache_stats() const {
    const std::lock_guard<std::mutex> lock(cache_mutex_);
    return cache_stats_;
}

std::optional<CaveRecipe> NativeProceduralCaveField::build_recipe(
    const CaveRegionKey region, const SurfaceSampler &surface,
    const ProtectedBounds &protected_bounds) const {
    GodotPcg32 rng(region_seed(region));
    if (static_cast<double>(rng.randf()) > 0.72) return std::nullopt;

    const double region_x = static_cast<double>(region.x) * REGION_METRES;
    const double region_z = static_cast<double>(region.z) * REGION_METRES;
    CaveVector3 center{static_cast<float>(region_x + randf_range(rng, -14.0, 14.0)), 0.0F,
        static_cast<float>(region_z + randf_range(rng, -14.0, 14.0))};
    center.y = static_cast<float>(surface(center.x, center.z));
    if (center.y < 19.0F) return std::nullopt;

    const double length_value = randf_range(rng, 43.0, 52.0);
    const double phase = randf_range(rng, 0.0, TAU);
    CaveVector3 entry{};
    CaveVector3 outward{};
    double best_score = -std::numeric_limits<double>::infinity();
    for (std::int32_t index = 0; index < 8; ++index) {
        const double angle = phase + static_cast<double>(index) * TAU / 8.0;
        const CaveVector3 direction{static_cast<float>(std::cos(angle)), 0.0F, static_cast<float>(std::sin(angle))};
        CaveVector3 candidate = add(center, multiply(direction, length_value));
        candidate.y = static_cast<float>(surface(candidate.x, candidate.z));
        if (candidate.y < 17.0F) continue;
        const double drop = static_cast<double>(center.y) - candidate.y;
        if (drop < -3.0 || drop > 18.0) continue;
        const double score = -std::abs(drop - 8.0);
        if (score > best_score) { best_score = score; entry = candidate; outward = direction; }
    }
    if (outward.x == 0.0F && outward.y == 0.0F && outward.z == 0.0F) return std::nullopt;

    const CaveVector3 side{-outward.z, 0.0F, outward.x};
    const double bend = randf_range(rng, -7.0, 7.0);
    const double floor_end = std::min(static_cast<double>(entry.y) - 7.5,
        static_cast<double>(center.y) - 11.0);
    if (static_cast<double>(entry.y) - floor_end > length_value * 0.35) return std::nullopt;

    CaveRecipe recipe;
    recipe.region = region;
    recipe.entry = entry;
    recipe.outward = outward;
    recipe.route.reserve(7U);
    for (std::int32_t index = 0; index < 7; ++index) {
        const double t = static_cast<double>(index) / 6.0;
        CaveVector3 point = add(lerp(entry, center, t), multiply(side,
            std::sin(t * PI) * bend + std::sin(t * TAU) * 2.0));
        const double eased_t = std::pow(t, 0.4);
        point.y = static_cast<float>(static_cast<double>(entry.y) - cell_size_meters_ * 0.25
            + (floor_end - (static_cast<double>(entry.y) - cell_size_meters_ * 0.25)) * eased_t);
        recipe.route.push_back(point);
    }
    // Raise the first interior control point into the natural hillside so the
    // entrance collar does not stack its descent on a steep surface grade.
    recipe.route[1].y += 0.25F;
    for (std::size_t index = 0; index + 1U < recipe.route.size(); ++index) {
        for (std::int32_t step = 0; step < 5; ++step) {
            const CaveVector3 floor_point = lerp(recipe.route[index], recipe.route[index + 1U],
                static_cast<double>(step) / 4.0);
            if (static_cast<double>(floor_point.y) - 0.3
                > surface(floor_point.x, floor_point.z))
                return std::nullopt;
        }
    }

    recipe = append_tapered_arch_path(recipe, recipe.route,
        {2.5, 2.3, 2.1, 2.1, 2.5, TUNNEL_RADIUS, TUNNEL_RADIUS},
        {1.35, 1.2, 1.2, 2.1, 2.5, TUNNEL_RADIUS, TUNNEL_RADIUS});
    if (!interior_segments_keep_natural_roof(recipe, 1U, surface)) return std::nullopt;
    const CaveVector3 junction = recipe.route[3];
    const CaveVector3 branch_end = [&]() {
        CaveVector3 value = add(recipe.route[5], multiply(side, randf_range(rng, 15.0, 21.0)));
        value.y = static_cast<float>(floor_end - 1.0);
        return value;
    }();
    recipe.loop = {junction, subtract(add(junction, multiply(side, 10.0F)), {0.0F, 1.0F, 0.0F}),
        branch_end, recipe.route[6]};
    recipe = append_path(recipe, recipe.loop, static_cast<float>(TUNNEL_RADIUS));
    const CaveVector3 deep_end = subtract(subtract(recipe.route[6], multiply(outward, 23.0F)),
        multiply(side, 12.0F));
    CaveVector3 deep_end_at_floor = deep_end;
    deep_end_at_floor.y = static_cast<float>(floor_end - 10.0);
    const CaveVector3 deep_mid = subtract(subtract(recipe.route[6], multiply(outward, 12.0F)),
        {0.0F, 7.0F, 0.0F});
    recipe.deep_route = {recipe.route[6], deep_mid, deep_end_at_floor};
    const double remaining_depth = static_cast<double>(deep_end_at_floor.y) - lowest_cave_floor_meters_;
    const std::size_t lower_level_count = std::min(MAX_DEEP_LEVELS,
        static_cast<std::size_t>(std::max(0.0, std::floor(remaining_depth / DEEP_LEVEL_DROP_METERS))));
    const double first_angle = std::atan2(
        static_cast<double>(deep_end_at_floor.z - recipe.route[6].z),
        static_cast<double>(deep_end_at_floor.x - recipe.route[6].x));
    std::vector<CaveVector3> lower_floors;
    for (std::size_t index = 1U; index <= lower_level_count; ++index) {
        // Keep successive floors around a compact helical footprint. Each
        // level drops 18m; lateral chords and alternating radii limit overlap
        // while keeping the descent traversable.
        const double angle = first_angle + static_cast<double>(index) * 1.7;
        const double orbit_radius = 32.0 + (index % 2U == 0U ? 4.0 : 0.0);
        CaveVector3 floor = recipe.route[6];
        floor.x += static_cast<float>(std::cos(angle) * orbit_radius);
        floor.z += static_cast<float>(std::sin(angle) * orbit_radius);
        floor.y = static_cast<float>(static_cast<double>(deep_end_at_floor.y)
            - static_cast<double>(index) * DEEP_LEVEL_DROP_METERS);
        const CaveVector3 previous = lower_floors.empty() ? deep_end_at_floor : lower_floors.back();
        const CaveVector3 incoming = lower_floors.empty()
            ? subtract(deep_end_at_floor, deep_mid)
            : subtract(previous, lower_floors.size() < 2U
                ? deep_end_at_floor : lower_floors[lower_floors.size() - 2U]);
        const double incoming_length = std::max(std::hypot(static_cast<double>(incoming.x),
            static_cast<double>(incoming.z)), 0.001);
        CaveVector3 departure{static_cast<float>(-incoming.z / incoming_length), 0.0F,
            static_cast<float>(incoming.x / incoming_length)};
        const CaveVector3 toward_next = subtract(floor, previous);
        if (static_cast<double>(departure.x) * toward_next.x
            + static_cast<double>(departure.z) * toward_next.z < 0.0)
            departure = multiply(departure, -1.0);
        CaveVector3 collar = previous;
        collar.x += departure.x * 20.0F;
        collar.z += departure.z * 20.0F;
        recipe.deep_route.push_back(collar);
        recipe.deep_route.push_back(floor);
        lower_floors.push_back(floor);
    }
    for (std::size_t index = 0U; index < lower_floors.size(); ++index) {
        const CaveVector3 &floor = lower_floors[index];
        const CaveVector3 &previous = index == 0U ? deep_end_at_floor : lower_floors[index - 1U];
        const CaveVector3 &next = index + 1U < lower_floors.size()
            ? lower_floors[index + 1U] : floor;
        const CaveVector3 incoming = subtract(floor, previous);
        const double incoming_length = std::max(std::hypot(static_cast<double>(incoming.x),
            static_cast<double>(incoming.z)), 0.001);
        CaveVector3 departure{static_cast<float>(-incoming.z / incoming_length), 0.0F,
            static_cast<float>(incoming.x / incoming_length)};
        if (index + 1U < lower_floors.size()) {
            const CaveVector3 toward_next = subtract(next, floor);
            if (static_cast<double>(departure.x) * toward_next.x
                + static_cast<double>(departure.z) * toward_next.z < 0.0)
                departure = multiply(departure, -1.0);
        }
        const CaveVector3 outgoing_direction = departure;
        const CaveVector3 incoming_direction{static_cast<float>(incoming.x / incoming_length), 0.0F,
            static_cast<float>(incoming.z / incoming_length)};
        CaveVector3 direction = add(outgoing_direction, incoming_direction);
        const double direction_length = std::hypot(static_cast<double>(direction.x),
            static_cast<double>(direction.z));
        if (direction_length > 0.001) direction = multiply(direction, 1.0 / direction_length);
        else direction = outgoing_direction;
        CaveVector3 side{-direction.z, 0.0F, direction.x};
        if (static_cast<double>(side.x) * incoming.x + static_cast<double>(side.z) * incoming.z > 0.0)
            side = multiply(side, -1.0);
        const CaveVector3 along = multiply(direction, 14.0);
        const CaveVector3 across = multiply(side, 28.0);
        const CaveVector3 entrance = add(floor, multiply(side, 10.0));
        recipe.depth_loops.push_back({floor, entrance, add(entrance, add(along, across)),
            add(entrance, add(multiply(along, -1.0), across)), entrance});
    }
    recipe = append_path(recipe, recipe.deep_route, 2.5F);
    for (std::size_t index = 0U; index < recipe.depth_loops.size(); ++index) {
        const std::vector<CaveVector3> depth_loop = recipe.depth_loops[index];
        recipe = append_path(recipe, depth_loop, static_cast<float>(TUNNEL_RADIUS));
    }
    if (!interior_segments_keep_natural_roof(recipe, 1U, surface)) return std::nullopt;

    CaveVector3 main_radii{static_cast<float>(randf_range(rng, 10.0, 14.0)),
        static_cast<float>(randf_range(rng, 5.0, 7.0)),
        static_cast<float>(randf_range(rng, 10.0, 13.0))};
    main_radii.y = static_cast<float>(fit_chamber_vertical_radius(
        recipe.route[6], main_radii.x, main_radii.z, main_radii.y, surface));
    if (main_radii.y < TUNNEL_RADIUS) return std::nullopt;
    CaveVector3 branch_radii{6.0F, 4.0F, 7.0F};
    branch_radii.y = static_cast<float>(fit_chamber_vertical_radius(
        branch_end, branch_radii.x, branch_radii.z, branch_radii.y, surface));
    if (branch_radii.y < 2.5F) return std::nullopt;
    CaveVector3 deep_radii{8.0F, 5.0F, 9.0F};
    deep_radii.y = static_cast<float>(fit_chamber_vertical_radius(
        deep_end_at_floor, deep_radii.x, deep_radii.z, deep_radii.y, surface));
    if (deep_radii.y < 2.5F) return std::nullopt;
    recipe.chambers = {
        {add(recipe.route[6], {0.0F, main_radii.y, 0.0F}), main_radii},
        {add(branch_end, {0.0F, branch_radii.y, 0.0F}), branch_radii},
        {add(deep_end_at_floor, {0.0F, deep_radii.y, 0.0F}), deep_radii},
    };
    for (std::size_t index = 0U; index < lower_level_count; ++index) {
        const CaveVector3 &tier_floor = lower_floors[index];
        const CaveVector3 floor = multiply(add(recipe.depth_loops[index][2],
            recipe.depth_loops[index][3]), 0.5);
        CaveVector3 radii{7.0F + (index % 2U == 0U ? 1.0F : 0.0F), 4.5F,
            8.0F + (index % 3U == 0U ? 1.0F : 0.0F)};
        radii.y = static_cast<float>(fit_chamber_vertical_radius(
            floor, radii.x, radii.z, radii.y, surface));
        if (radii.y < TUNNEL_RADIUS) return std::nullopt;
        if (static_cast<double>(tier_floor.y) < lowest_cave_floor_meters_)
            return std::nullopt;
        recipe.chambers.push_back({add(floor, {0.0F, radii.y, 0.0F}), radii});
    }
    for (const CaveChamber &chamber : recipe.chambers) {
        const CaveVector3 extent{chamber.radii.x + 1.0F, chamber.radii.y + 1.0F,
            chamber.radii.z + 1.0F};
        const CaveBounds bounds{subtract(chamber.center, extent), multiply(extent, 2.0F)};
        recipe.bounds.merge(bounds);
    }
    if (!(region_at(recipe.bounds.position) == region)
        || !(region_at(add(recipe.bounds.position, recipe.bounds.size)) == region))
        return std::nullopt;
    if (protected_bounds(recipe.bounds)) return std::nullopt;
    return recipe;
}

CaveRecipe NativeProceduralCaveField::append_path(
    CaveRecipe recipe, const std::vector<CaveVector3> &points, const double radius) const {
    for (std::size_t index = 0; index + 1U < points.size(); ++index) {
        const CaveVector3 a = points[index];
        const CaveVector3 b = points[index + 1U];
        const double grow = radius + 1.0;
        const double grow_up = grow + radius;
        const CaveVector3 low{static_cast<float>(std::min(a.x, b.x) - grow),
            static_cast<float>(std::min(a.y, b.y) - grow),
            static_cast<float>(std::min(a.z, b.z) - grow)};
        const CaveVector3 high{static_cast<float>(std::max(a.x, b.x) + grow),
            static_cast<float>(std::max(a.y, b.y) + grow_up),
            static_cast<float>(std::max(a.z, b.z) + grow)};
        const CaveBounds bounds{low, subtract(high, low)};
        if (recipe.segments.empty()) recipe.bounds = bounds;
        else recipe.bounds.merge(bounds);
        recipe.segments.push_back({a, b, radius, radius, radius, radius, bounds});
    }
    return recipe;
}

CaveRecipe NativeProceduralCaveField::append_tapered_path(
    CaveRecipe recipe, const std::vector<CaveVector3> &points,
    const std::vector<double> &radii) const {
    if (points.size() != radii.size())
        throw std::invalid_argument("native tapered cave path requires one radius per point");
    for (std::size_t index = 0; index + 1U < points.size(); ++index) {
        const CaveVector3 a = points[index];
        const CaveVector3 b = points[index + 1U];
        const double start_radius = radii[index];
        const double end_radius = radii[index + 1U];
        const double bounds_radius = std::max(start_radius, end_radius);
        const double grow = bounds_radius + 1.0;
        const CaveVector3 low{static_cast<float>(std::min(a.x, b.x) - grow),
            static_cast<float>(std::min(a.y, b.y) - grow),
            static_cast<float>(std::min(a.z, b.z) - grow)};
        const CaveVector3 high{static_cast<float>(std::max(a.x, b.x) + grow),
            static_cast<float>(std::max(a.y, b.y) + grow + bounds_radius),
            static_cast<float>(std::max(a.z, b.z) + grow)};
        const CaveBounds bounds{low, subtract(high, low)};
        if (recipe.segments.empty()) recipe.bounds = bounds;
        else recipe.bounds.merge(bounds);
        recipe.segments.push_back({a, b, start_radius, end_radius, start_radius, end_radius, bounds});
    }
    return recipe;
}

CaveRecipe NativeProceduralCaveField::append_tapered_arch_path(
    CaveRecipe recipe, const std::vector<CaveVector3> &points,
    const std::vector<double> &radii, const std::vector<double> &vertical_radii) const {
    if (points.size() != radii.size() || points.size() != vertical_radii.size())
        throw std::invalid_argument("native tapered cave arch requires one horizontal and vertical radius per point");
    for (std::size_t index = 0; index + 1U < points.size(); ++index) {
        const CaveVector3 a = points[index];
        const CaveVector3 b = points[index + 1U];
        const double start_radius = radii[index];
        const double end_radius = radii[index + 1U];
        const double start_vertical = vertical_radii[index];
        const double end_vertical = vertical_radii[index + 1U];
        const double bounds_radius = std::max(start_radius, end_radius);
        const double grow = bounds_radius + 1.0;
        const CaveVector3 low{static_cast<float>(std::min(a.x, b.x) - grow),
            static_cast<float>(std::min(a.y, b.y) - grow),
            static_cast<float>(std::min(a.z, b.z) - grow)};
        const CaveVector3 high{static_cast<float>(std::max(a.x, b.x) + grow),
            static_cast<float>(std::max(a.y, b.y) + grow + bounds_radius),
            static_cast<float>(std::max(a.z, b.z) + grow)};
        const CaveBounds bounds{low, subtract(high, low)};
        if (recipe.segments.empty()) recipe.bounds = bounds;
        else recipe.bounds.merge(bounds);
        recipe.segments.push_back({a, b, start_radius, end_radius, start_vertical, end_vertical, bounds});
    }
    return recipe;
}

bool NativeProceduralCaveField::interior_segments_keep_natural_roof(
    const CaveRecipe &recipe, const std::size_t first_interior_segment,
    const SurfaceSampler &surface) const {
    const double reserve = cell_size_meters_ * 1.15;
    for (std::size_t index = first_interior_segment; index < recipe.segments.size(); ++index) {
        const CaveSegment &segment = recipe.segments[index];
        const double vertical_start = segment.vertical_radius > 0.0 ? segment.vertical_radius : segment.radius;
        const double vertical_end = segment.vertical_radius_end > 0.0 ? segment.vertical_radius_end : segment.radius_end;
        for (std::int32_t sample_index = 0; sample_index < 5; ++sample_index) {
            const double t = static_cast<double>(sample_index) / 4.0;
            const CaveVector3 floor_point = lerp(segment.a, segment.b, t);
            const double radius = vertical_start + (vertical_end - vertical_start) * t;
            if (static_cast<double>(floor_point.y) + radius * 2.0 + reserve > surface(floor_point.x, floor_point.z))
                return false;
        }
    }
    return true;
}

double NativeProceduralCaveField::fit_chamber_vertical_radius(
    const CaveVector3 &floor_point, const double radius_x, const double radius_z,
    const double requested_radius, const SurfaceSampler &surface) const {
    const double reserve = cell_size_meters_ + 1.1 + 0.24;
    double fitted = requested_radius;
    for (std::int32_t x_step = -4; x_step <= 4; ++x_step) {
        for (std::int32_t z_step = -4; z_step <= 4; ++z_step) {
            const double nx = static_cast<double>(x_step) * 0.2;
            const double nz = static_cast<double>(z_step) * 0.2;
            const double radial_squared = nx * nx + nz * nz;
            if (radial_squared >= 1.0) continue;
            const double surface_y = surface(
                static_cast<float>(static_cast<double>(floor_point.x) + nx * radius_x),
                static_cast<float>(static_cast<double>(floor_point.z) + nz * radius_z));
            const double cap_factor = 1.0 + std::sqrt(1.0 - radial_squared);
            const double allowed_radius = (surface_y - floor_point.y - reserve) / cap_factor;
            fitted = std::min(fitted, allowed_radius);
        }
    }
    return fitted;
}

double NativeProceduralCaveField::recipe_density(
    const CaveVector3 position, const CaveRecipe &recipe) const {
    // Godot Vector3 storage/operations remain real_t(float), but GDScript's
    // scalar expressions (distance, minf/maxf and blend) use double precision.
    // Keep the same boundary arithmetic so N2's typed density stays exact.
    double result = ROCK;
    for (const CaveSegment &segment : recipe.segments) {
        if (!segment.bounds.contains(position)) continue;
        const CaveVector3 horizontal{segment.b.x - segment.a.x, 0.0F, segment.b.z - segment.a.z};
        const double denominator = std::max(
            static_cast<double>(length_squared_xz(horizontal)), 0.001);
        const double t = std::clamp(
            static_cast<double>(dot_xz(subtract(position, segment.a), horizontal)) / denominator,
            0.0, 1.0);
        const CaveVector3 floor_point = lerp(segment.a, segment.b, static_cast<float>(t));
        const double radius = segment.radius + (segment.radius_end - segment.radius) * t;
        const double vertical_radius = segment.vertical_radius
            + (segment.vertical_radius_end - segment.vertical_radius) * t;
        const CaveVector3 delta = subtract(position, add(floor_point, multiply({0.0F, 1.0F, 0.0F}, vertical_radius)));
        const double horizontal_squared = static_cast<double>(length_squared_xz(delta))
            / (static_cast<double>(radius) * radius);
        const double vertical = static_cast<double>(delta.y) / vertical_radius;
        const double distance = (std::sqrt(horizontal_squared + vertical * vertical) - 1.0)
            * std::min(radius, vertical_radius);
        result = std::min(result, distance);
    }
    for (const CaveChamber &chamber : recipe.chambers) {
        const CaveVector3 q = divide(subtract(position, chamber.center), chamber.radii);
        double distance = (static_cast<double>(length(q)) - 1.0)
            * min3(chamber.radii.x, chamber.radii.y, chamber.radii.z);
        if (distance < 2.0) {
            const CaveVector3 detail_position{position.x * 2.3F, position.y * 2.3F, position.z * 2.3F};
            distance += static_cast<double>(noise_.sample_3d(CaveNoiseChannel::chambers,
                detail_position.x, detail_position.y, detail_position.z)) * 1.1;
        }
        const double blend = std::max(1.8 - std::abs(result - distance), 0.0) / 1.8;
        result = std::min(result, distance) - blend * blend * 1.8 * 0.25;
    }
    return static_cast<double>(result);
}

double NativeProceduralCaveField::density(
    const CaveVector3 position, const double,
    const SurfaceSampler &surface, const ProtectedBounds &protected_bounds) const {
    const std::shared_ptr<const CaveRecipe> recipe = recipe_snapshot_for_region(
        region_at(position), surface, protected_bounds);
    // Explicit cave recipes are the sole underground-air authority. The former
    // free-running noise caves made unrelated voids outside recipes and could
    // undercut a recipe floor from below. Unauthored regions therefore remain
    // solid; generated edits can still open them through the terrain volume.
    if (!recipe || !recipe->bounds.contains(position)) return ROCK;
    double carved = recipe_density(position, *recipe);
    if (carved < 1.0) {
        const double detail = static_cast<double>(noise_.sample_3d(CaveNoiseChannel::detail,
            position.x, position.y, position.z)) * 0.24;
        // Keep additive roughness on the cave-facing wall while preventing a
        // positive SDF near thin overburden from becoming a hairline skylight.
        // Noise may roughen a wall, but it must never turn recipe-owned air
        // into solid terrain. Positive-side detail remains biased outward to
        // avoid thin-roof skylights.
        carved += carved < 0.0 ? std::min(detail, -carved - 0.02)
            : std::max(detail, -carved + 0.04);
    }
    return carved;
}

} // namespace voxel::world_backend
