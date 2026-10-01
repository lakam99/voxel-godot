#include "native_procedural_cave_field.hpp"

#include "godot_pcg_compat.hpp"

#include <algorithm>
#include <array>
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

std::uint32_t fallback_center_seed(const std::vector<std::uint32_t> &seed_code_points,
    const CaveRegionKey region) {
    std::uint32_t hash = 2166136261U;
    for (const std::uint32_t code_point : seed_code_points) hash = fnv_append(hash, code_point);
    append_ascii(hash, ":cave-center-fallback:");
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

std::optional<CaveRecipeBuildDiagnostics> NativeProceduralCaveField::build_diagnostics(
    const CaveRegionKey region) const {
    const std::lock_guard<std::mutex> lock(cache_mutex_);
    const auto found = recipe_diagnostics_.find(region);
    if (found == recipe_diagnostics_.end()) return std::nullopt;
    return found->second;
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
    CaveRecipeBuildDiagnostics diagnostics;
    const std::optional<CaveRecipe> built = build_recipe(region, surface, protected_bounds, diagnostics);
    const std::shared_ptr<const CaveRecipe> snapshot = built
        ? std::make_shared<const CaveRecipe>(*built) : std::shared_ptr<const CaveRecipe>{};
    const auto elapsed = static_cast<std::uint64_t>(std::chrono::duration_cast<std::chrono::microseconds>(
        std::chrono::steady_clock::now() - started).count());
    diagnostics.build_time_usec = elapsed;
    {
        const std::lock_guard<std::mutex> lock(cache_mutex_);
        const auto found = recipe_cache_.find(region);
        if (found != recipe_cache_.end()) return found->second;
        ++cache_stats_.recipe_build_count;
        cache_stats_.recipe_build_total_usec += elapsed;
        cache_stats_.recipe_build_max_usec = std::max(cache_stats_.recipe_build_max_usec, elapsed);
        if (recipe_cache_.size() >= RECIPE_CACHE_LIMIT) {
            recipe_cache_.clear();
            recipe_diagnostics_.clear();
            ++cache_stats_.cache_evictions;
        }
        recipe_cache_.emplace(region, snapshot);
        recipe_diagnostics_[region] = std::move(diagnostics);
    }
    return snapshot;
}

NativeProceduralCaveField::CacheStats NativeProceduralCaveField::cache_stats() const {
    const std::lock_guard<std::mutex> lock(cache_mutex_);
    return cache_stats_;
}

std::optional<CaveRecipe> NativeProceduralCaveField::build_recipe(
    const CaveRegionKey region, const SurfaceSampler &surface,
    const ProtectedBounds &protected_bounds,
    CaveRecipeBuildDiagnostics &diagnostics) const {
    CaveCenterAttemptDiagnostics primary_diagnostics;
    std::optional<CaveRecipe> recipe = build_recipe_at_offset(region, {0.0F, 0.0F, 0.0F},
        surface, protected_bounds, primary_diagnostics);
    diagnostics.centers_attempted = 1U;
    diagnostics.directions_evaluated = primary_diagnostics.directions_evaluated;
    diagnostics.centers.push_back(primary_diagnostics);
    if (recipe) {
        diagnostics.terminal_reason = "accepted";
        return recipe;
    }
    // Preserve primary-center output and cost exactly. Center search is only
    // entered when that center evaluated all eight directions without success.
    if (primary_diagnostics.directions_evaluated != 8U) {
        diagnostics.terminal_reason = primary_diagnostics.terminal_reason;
        return std::nullopt;
    }
    GodotPcg32 offset_rng(fallback_center_seed(seed_code_points_, region));
    const double first_angle = randf_range(offset_rng, 0.0F, static_cast<float>(TAU));
    for (std::int32_t index = 0; index < 4; ++index) {
        const double angle = first_angle + static_cast<double>(index) * TAU / 4.0;
        const CaveVector3 offset{static_cast<float>(std::cos(angle) * 28.0), 0.0F,
            static_cast<float>(std::sin(angle) * 28.0)};
        CaveCenterAttemptDiagnostics attempt;
        recipe = build_recipe_at_offset(region, offset, surface, protected_bounds, attempt);
        ++diagnostics.centers_attempted;
        diagnostics.directions_evaluated += attempt.directions_evaluated;
        diagnostics.centers.push_back(attempt);
        if (recipe) {
            diagnostics.terminal_reason = "accepted";
            return recipe;
        }
    }
    diagnostics.terminal_reason = diagnostics.centers.back().terminal_reason;
    return std::nullopt;
}

std::optional<CaveRecipe> NativeProceduralCaveField::build_recipe_at_offset(
    const CaveRegionKey region, const CaveVector3 center_offset,
    const SurfaceSampler &surface, const ProtectedBounds &protected_bounds,
    CaveCenterAttemptDiagnostics &attempt_diagnostics) const {
    GodotPcg32 rng(region_seed(region));

    const double region_x = static_cast<double>(region.x) * REGION_METRES;
    const double region_z = static_cast<double>(region.z) * REGION_METRES;
    CaveVector3 center{static_cast<float>(region_x + randf_range(rng, -14.0, 14.0)), 0.0F,
        static_cast<float>(region_z + randf_range(rng, -14.0, 14.0))};
    if (center_offset.x != 0.0F || center_offset.z != 0.0F) center = add(center, center_offset);
    attempt_diagnostics.center = center;
    if (!(region_at(center) == region)) {
        attempt_diagnostics.terminal_reason = "center_outside_region";
        return std::nullopt;
    }
    center.y = static_cast<float>(surface(center.x, center.z));
    attempt_diagnostics.center = center;
    if (center.y < 19.0F) {
        attempt_diagnostics.terminal_reason = "lowland_center";
        return std::nullopt;
    }

    const double length_value = randf_range(rng, 43.0, 52.0);
    const double phase = randf_range(rng, 0.0, TAU);
    const double bend = randf_range(rng, -7.0, 7.0);
    struct EntranceCandidate {
        CaveVector3 entry;
        CaveVector3 outward;
        CaveVector3 side;
        double floor_end = 0.0;
        double roof_margin = 0.0;
        std::int64_t roof_margin_millimeters = 0;
        double drop_preference = 0.0;
        std::int64_t drop_preference_millimeters = 0;
        std::int32_t candidate_index = 0;
        std::size_t lower_level_count = 0U;
        std::vector<CaveVector3> route;
    };
    std::vector<EntranceCandidate> candidates;
    const std::array<double, 7> vertical_radii{{1.35, 1.45, 1.45, 2.1, 2.5, TUNNEL_RADIUS, TUNNEL_RADIUS}};
    const double roof_reserve = cell_size_meters_ * 1.15;
    bool saw_drop_candidate = false;
    bool saw_descent_candidate = false;
    bool saw_depth_candidate = false;
    bool saw_surface_crossing = false;
    bool saw_roof_failure = false;
    bool saw_grade_failure = false;
    attempt_diagnostics.directions_evaluated = 8U;
    for (std::int32_t index = 0; index < 8; ++index) {
        const double angle = phase + static_cast<double>(index) * TAU / 8.0;
        const CaveVector3 direction{static_cast<float>(std::cos(angle)), 0.0F, static_cast<float>(std::sin(angle))};
        CaveVector3 entry = add(center, multiply(direction, length_value));
        entry.y = static_cast<float>(surface(entry.x, entry.z));
        if (entry.y < 17.0F) {
            ++attempt_diagnostics.rejection_counts["entry_too_low"];
            continue;
        }
        const double drop = static_cast<double>(center.y) - entry.y;
        if (drop < -3.0 || drop > 18.0) {
            ++attempt_diagnostics.rejection_counts["entry_drop"];
            continue;
        }
        saw_drop_candidate = true;
        const double floor_end = std::min(static_cast<double>(entry.y) - 7.5,
            static_cast<double>(center.y) - 11.0);
        if (static_cast<double>(entry.y) - floor_end > length_value * 0.35) {
            ++attempt_diagnostics.rejection_counts["descent_limit"];
            continue;
        }
        saw_descent_candidate = true;
        const double remaining_depth = floor_end - 10.0 - lowest_cave_floor_meters_;
        const std::size_t lower_level_count = std::min(MAX_DEEP_LEVELS,
            static_cast<std::size_t>(std::max(0.0, std::floor(remaining_depth / DEEP_LEVEL_DROP_METERS))));
        if (lower_level_count < 4U) {
            ++attempt_diagnostics.rejection_counts["depth_capacity"];
            continue;
        }
        saw_depth_candidate = true;
        const CaveVector3 side{-direction.z, 0.0F, direction.x};
        EntranceCandidate candidate;
        candidate.entry = entry;
        candidate.outward = direction;
        candidate.side = side;
        candidate.floor_end = floor_end;
        candidate.drop_preference = -std::abs(drop - 8.0);
        candidate.drop_preference_millimeters = static_cast<std::int64_t>(
            std::floor(candidate.drop_preference * 1000.0));
        candidate.candidate_index = index;
        candidate.lower_level_count = lower_level_count;
        candidate.route.reserve(7U);
        for (std::int32_t route_index = 0; route_index < 7; ++route_index) {
            const double t = static_cast<double>(route_index) / 6.0;
            CaveVector3 point = add(lerp(entry, center, t), multiply(side,
                std::sin(t * PI) * bend + std::sin(t * TAU) * 2.0));
            const double eased_t = std::pow(t, 0.4);
            point.y = static_cast<float>(static_cast<double>(entry.y) - cell_size_meters_ * 0.25
                + (floor_end - (static_cast<double>(entry.y) - cell_size_meters_ * 0.25)) * eased_t);
            candidate.route.push_back(point);
        }
        candidate.route[1].y += 0.25F;
        bool route_below_surface = true;
        for (std::size_t route_index = 0; route_index + 1U < candidate.route.size(); ++route_index) {
            for (std::int32_t step = 0; step < 5; ++step) {
                const CaveVector3 point = lerp(candidate.route[route_index], candidate.route[route_index + 1U],
                    static_cast<double>(step) / 4.0);
                if (static_cast<double>(point.y) - 0.3 > surface(point.x, point.z)) {
                    route_below_surface = false;
                    break;
                }
            }
            if (!route_below_surface) break;
        }
        if (!route_below_surface) {
            saw_surface_crossing = true;
            ++attempt_diagnostics.rejection_counts["route_crosses_surface"];
            continue;
        }
        const double maximum_grade = std::tan(46.0 * PI / 180.0);
        bool guide_walkable = true;
        for (std::size_t route_index = 0; route_index + 1U < candidate.route.size(); ++route_index) {
            const CaveVector3 a = candidate.route[route_index];
            const CaveVector3 b = candidate.route[route_index + 1U];
            const double horizontal_run = std::hypot(static_cast<double>(b.x - a.x),
                static_cast<double>(b.z - a.z));
            if (horizontal_run > 0.01 && std::abs(static_cast<double>(b.y - a.y)) / horizontal_run > maximum_grade) {
                guide_walkable = false;
                break;
            }
        }
        if (!guide_walkable) {
            saw_grade_failure = true;
            ++attempt_diagnostics.rejection_counts["entrance_guide_grade"];
            continue;
        }
        double minimum_roof_margin = std::numeric_limits<double>::infinity();
        for (std::size_t segment_index = 1U; segment_index + 1U < candidate.route.size(); ++segment_index) {
            for (std::int32_t sample_index = 0; sample_index < 5; ++sample_index) {
                const double t = static_cast<double>(sample_index) / 4.0;
                const CaveVector3 floor_point = lerp(candidate.route[segment_index],
                    candidate.route[segment_index + 1U], t);
                const double vertical_radius = vertical_radii[segment_index]
                    + (vertical_radii[segment_index + 1U] - vertical_radii[segment_index]) * t;
                const double margin = surface(floor_point.x, floor_point.z)
                    - (static_cast<double>(floor_point.y) + vertical_radius * 2.0 + roof_reserve);
                minimum_roof_margin = std::min(minimum_roof_margin, margin);
            }
        }
        if (minimum_roof_margin < 0.0) {
            saw_roof_failure = true;
            ++attempt_diagnostics.rejection_counts["entrance_roof"];
            continue;
        }
        candidate.roof_margin = minimum_roof_margin;
        candidate.roof_margin_millimeters = static_cast<std::int64_t>(std::floor(minimum_roof_margin * 1000.0));
        candidates.push_back(std::move(candidate));
        ++attempt_diagnostics.viable_entrances;
    }
    if (candidates.empty()) {
        if (saw_depth_candidate) {
            if (saw_roof_failure) attempt_diagnostics.terminal_reason = "entrance_roof";
            else if (saw_surface_crossing) attempt_diagnostics.terminal_reason = "route_crosses_surface";
            else if (saw_grade_failure) attempt_diagnostics.terminal_reason = "entrance_grade";
            else attempt_diagnostics.terminal_reason = "no_valid_entrance";
            return std::nullopt;
        }
        if (saw_descent_candidate && !saw_depth_candidate) {
            attempt_diagnostics.terminal_reason = "insufficient_world_depth";
            return std::nullopt;
        }
        if (saw_drop_candidate && !saw_descent_candidate) {
            attempt_diagnostics.terminal_reason = "entrance_descent_limit";
            return std::nullopt;
        }
        attempt_diagnostics.terminal_reason = "no_valid_entrance";
        return std::nullopt;
    }
    std::stable_sort(candidates.begin(), candidates.end(), [](const EntranceCandidate &a, const EntranceCandidate &b) {
        if (a.roof_margin_millimeters != b.roof_margin_millimeters)
            return a.roof_margin_millimeters > b.roof_margin_millimeters;
        if (a.drop_preference_millimeters != b.drop_preference_millimeters)
            return a.drop_preference_millimeters > b.drop_preference_millimeters;
        return a.candidate_index < b.candidate_index;
    });
    const double branch_distance = randf_range(rng, 15.0, 21.0);
    const CaveVector3 requested_main_radii{randf_range(rng, 10.0, 14.0),
        randf_range(rng, 5.0, 7.0), randf_range(rng, 10.0, 13.0)};
    attempt_diagnostics.full_recipe_attempts = static_cast<std::uint32_t>(candidates.size());
    std::string last_candidate_rejection = "no_valid_entrance";
    for (const EntranceCandidate &candidate : candidates) {
        const CaveVector3 entry = candidate.entry;
        const CaveVector3 outward = candidate.outward;
        const CaveVector3 side = candidate.side;
        const double floor_end = candidate.floor_end;
        const std::size_t lower_level_count = candidate.lower_level_count;
        std::string candidate_rejection = "unknown";
        const auto try_candidate = [&]() -> std::optional<CaveRecipe> {

    CaveRecipe recipe;
    recipe.region = region;
    recipe.entry = entry;
    recipe.outward = outward;
    recipe.route = candidate.route;
    for (std::size_t index = 0; index + 1U < recipe.route.size(); ++index) {
        for (std::int32_t step = 0; step < 5; ++step) {
            const CaveVector3 floor_point = lerp(recipe.route[index], recipe.route[index + 1U],
                static_cast<double>(step) / 4.0);
            if (static_cast<double>(floor_point.y) - 0.3
                > surface(floor_point.x, floor_point.z)) {
                candidate_rejection = "route_crosses_surface";
                return std::nullopt;
            }
        }
    }

    recipe = append_tapered_arch_path(recipe, recipe.route,
        {2.5, 2.3, 2.1, 2.1, 2.5, TUNNEL_RADIUS, TUNNEL_RADIUS},
        {1.35, 1.45, 1.45, 2.1, 2.5, TUNNEL_RADIUS, TUNNEL_RADIUS});
    if (!interior_segments_keep_natural_roof(recipe, 1U, surface)) { candidate_rejection = "network_roof"; return std::nullopt; }
    const CaveVector3 junction = recipe.route[3];
    const CaveVector3 branch_end = [&]() {
        CaveVector3 value = add(recipe.route[5], multiply(side, branch_distance));
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
    if (!interior_segments_keep_natural_roof(recipe, 1U, surface)) { candidate_rejection = "entrance_roof"; return std::nullopt; }

    CaveVector3 main_radii = requested_main_radii;
    main_radii.y = static_cast<float>(fit_chamber_vertical_radius(
        recipe.route[6], main_radii.x, main_radii.z, main_radii.y, surface));
    if (main_radii.y < TUNNEL_RADIUS) { candidate_rejection = "main_chamber_clearance"; return std::nullopt; }
    CaveVector3 branch_radii{6.0F, 4.0F, 7.0F};
    branch_radii.y = static_cast<float>(fit_chamber_vertical_radius(
        branch_end, branch_radii.x, branch_radii.z, branch_radii.y, surface));
    if (branch_radii.y < 2.5F) { candidate_rejection = "branch_chamber_clearance"; return std::nullopt; }
    CaveVector3 deep_radii{8.0F, 5.0F, 9.0F};
    deep_radii.y = static_cast<float>(fit_chamber_vertical_radius(
        deep_end_at_floor, deep_radii.x, deep_radii.z, deep_radii.y, surface));
    if (deep_radii.y < 2.5F) { candidate_rejection = "deep_chamber_clearance"; return std::nullopt; }
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
        if (radii.y < TUNNEL_RADIUS) { candidate_rejection = "tier_chamber_clearance_or_world_bottom"; return std::nullopt; }
        if (static_cast<double>(tier_floor.y) < lowest_cave_floor_meters_) {
            candidate_rejection = "tier_chamber_clearance_or_world_bottom";
            return std::nullopt;
        }
        recipe.chambers.push_back({add(floor, {0.0F, radii.y, 0.0F}), radii});
    }
    for (const CaveChamber &chamber : recipe.chambers) {
        const CaveVector3 extent{chamber.radii.x + 1.0F, chamber.radii.y + 1.0F,
            chamber.radii.z + 1.0F};
        const CaveBounds bounds{subtract(chamber.center, extent), multiply(extent, 2.0F)};
        recipe.bounds.merge(bounds);
    }
    if (!(region_at(recipe.bounds.position) == region)
        || !(region_at(add(recipe.bounds.position, recipe.bounds.size)) == region)) {
        candidate_rejection = "region_bounds";
        return std::nullopt;
    }
    if (protected_bounds(recipe.bounds)) { candidate_rejection = "protected_site"; return std::nullopt; }
    if (!route_has_walkable_effective_support(recipe, surface)) { candidate_rejection = "entrance_effective_grade"; return std::nullopt; }
    return recipe;
        };
        const std::optional<CaveRecipe> built = try_candidate();
        if (built) {
            attempt_diagnostics.terminal_reason = "accepted";
            return built;
        }
        ++attempt_diagnostics.rejection_counts[candidate_rejection];
        last_candidate_rejection = candidate_rejection;
    }
    attempt_diagnostics.terminal_reason = candidates.empty() ? "no_valid_entrance" : last_candidate_rejection;
    return std::nullopt;
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

bool NativeProceduralCaveField::route_has_walkable_effective_support(
    const CaveRecipe &recipe, const SurfaceSampler &surface) const {
    CaveVector3 previous{std::numeric_limits<float>::infinity(),
        std::numeric_limits<float>::infinity(), std::numeric_limits<float>::infinity()};
    for (std::size_t index = 0; index + 1U < recipe.route.size(); ++index) {
        const CaveVector3 a = recipe.route[index];
        const CaveVector3 b = recipe.route[index + 1U];
        for (std::int32_t step = 0; step < 11; ++step) {
            CaveVector3 guide = lerp(a, b, static_cast<double>(step) / 10.0);
            const double ground_y = candidate_volume_ground_height_near(recipe, guide, surface);
            if (!std::isfinite(ground_y) || std::abs(ground_y - guide.y) > 3.0) return false;
            guide.y = static_cast<float>(ground_y);
            if (std::isfinite(previous.x)) {
                const double run = std::hypot(static_cast<double>(guide.x - previous.x),
                    static_cast<double>(guide.z - previous.z));
                if (run > 0.01 && std::abs(static_cast<double>(guide.y - previous.y)) / run
                    > std::tan(46.0 * PI / 180.0)) return false;
            }
            previous = guide;
        }
    }
    return true;
}

double NativeProceduralCaveField::candidate_volume_ground_height_near(
    const CaveRecipe &recipe, const CaveVector3 position,
    const SurfaceSampler &surface) const {
    const float cell_size = static_cast<float>(cell_size_meters_);
    const CaveVector3 lattice{position.x / cell_size, position.y / cell_size, position.z / cell_size};
    const auto x = static_cast<std::int32_t>(std::floor(lattice.x));
    const auto z = static_cast<std::int32_t>(std::floor(lattice.z));
    const float fraction_x = lattice.x - static_cast<float>(x);
    const float fraction_z = lattice.z - static_cast<float>(z);
    const float start_height = lattice.y + 0.95F;
    const auto start_y = static_cast<std::int32_t>(std::floor(start_height));
    const auto column_density = [&](const std::int32_t y) {
        const double a = candidate_volume_density_at_cell(recipe, x, y, z, surface);
        const double b = candidate_volume_density_at_cell(recipe, x + 1, y, z, surface);
        const double c = candidate_volume_density_at_cell(recipe, x, y, z + 1, surface);
        const double d = candidate_volume_density_at_cell(recipe, x + 1, y, z + 1, surface);
        const float front = static_cast<float>(a + (b - a) * fraction_x);
        const float back = static_cast<float>(c + (d - c) * fraction_x);
        return static_cast<double>(front + (back - front) * fraction_z);
    };
    const double lower = column_density(start_y);
    const double upper = column_density(start_y + 1);
    double previous_density = static_cast<double>(static_cast<float>(lower
        + (upper - lower) * (start_height - static_cast<float>(start_y))));
    if (previous_density >= 0.0) return std::numeric_limits<double>::quiet_NaN();
    double previous_height = start_height;
    const auto lowest_y = static_cast<std::int32_t>(std::floor(lattice.y - 14.0F));
    for (std::int32_t y = start_y; y >= lowest_y; --y) {
        const double density = column_density(y);
        if (density >= 0.0 && previous_density < 0.0) {
            const double fraction = (density - previous_density) == 0.0 ? 0.0
                : density / std::max(density - previous_density, 0.0001);
            const float height = static_cast<float>(static_cast<float>(y)
                + (previous_height - static_cast<float>(y)) * static_cast<float>(fraction));
            return static_cast<double>(height * cell_size);
        }
        previous_density = density;
        previous_height = static_cast<double>(y);
    }
    return std::numeric_limits<double>::quiet_NaN();
}

double NativeProceduralCaveField::candidate_volume_density_at_cell(
    const CaveRecipe &recipe, const std::int32_t x, const std::int32_t y,
    const std::int32_t z, const SurfaceSampler &surface) const {
    const float cell_size = static_cast<float>(cell_size_meters_);
    const CaveVector3 position{static_cast<float>(x) * cell_size,
        static_cast<float>(y) * cell_size, static_cast<float>(z) * cell_size};
    const double surface_y = surface(position.x, position.z);
    double cave_density = ROCK;
    if (recipe.bounds.contains(position)) {
        cave_density = recipe_density(position, recipe);
        if (cave_density < 1.0) {
            const double detail = static_cast<double>(noise_.sample_3d(CaveNoiseChannel::detail,
                position.x, position.y, position.z)) * 0.24;
            cave_density += cave_density < 0.0 ? std::min(detail, -cave_density - 0.02)
                : std::max(detail, -cave_density + 0.04);
        }
    }
    double density = std::min(surface_y - static_cast<double>(position.y), cave_density);
    if (static_cast<double>(position.y) <= lowest_cave_floor_meters_ - 4.0 * cell_size)
        density = std::max(density, cell_size * 4.0);
    return density;
}

} // namespace voxel::world_backend
