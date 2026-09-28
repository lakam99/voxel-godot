#include "native_feature_footprint_geometry.hpp"

#include <algorithm>
#include <cmath>
#include <limits>

namespace voxel::world_backend {
namespace {
[[noreturn]] void reject() { throw NativeFeatureFootprintGeometryRejected(); }

std::int32_t cell_for(const double position, const double cell_size) {
    const double cell = std::floor(position / cell_size);
    if (!std::isfinite(cell) || cell < std::numeric_limits<std::int32_t>::min()
        || cell > std::numeric_limits<std::int32_t>::max()) reject();
    return static_cast<std::int32_t>(cell);
}
} // namespace

NativeFeatureFootprintGeometryRejected::NativeFeatureFootprintGeometryRejected()
    : std::invalid_argument("invalid native feature world bounds") {}

void native_feature_bounds_include_sphere(NativeFeatureWorldBounds &bounds,
    const double x, const double y, const double z, const double radius) {
    if (!std::isfinite(x) || !std::isfinite(y) || !std::isfinite(z)
        || !std::isfinite(radius) || radius < 0.0) reject();
    bounds.min_x = std::min(bounds.min_x, x - radius);
    bounds.min_y = std::min(bounds.min_y, y - radius);
    bounds.min_z = std::min(bounds.min_z, z - radius);
    bounds.max_x = std::max(bounds.max_x, x + radius);
    bounds.max_y = std::max(bounds.max_y, y + radius);
    bounds.max_z = std::max(bounds.max_z, z + radius);
}

void native_feature_bounds_enclose_body_yaw(NativeFeatureWorldBounds &bounds,
    const double body_x, const double body_z) {
    if (!std::isfinite(body_x) || !std::isfinite(body_z)) reject();
    const double far_x = std::max(std::abs(bounds.min_x - body_x), std::abs(bounds.max_x - body_x));
    const double far_z = std::max(std::abs(bounds.min_z - body_z), std::abs(bounds.max_z - body_z));
    const double outer = std::hypot(far_x, far_z);
    bounds.min_x = body_x - outer; bounds.max_x = body_x + outer;
    bounds.min_z = body_z - outer; bounds.max_z = body_z + outer;
}

std::vector<NativeFeatureFootprintRun> native_feature_runs_for_bounds(
    const NativeFeatureWorldBounds bounds, const double cell_size,
    const NativeFeatureFootprintChannel channel) {
    if (!std::isfinite(cell_size) || cell_size <= 0.0) reject();
    if (channel != NativeFeatureFootprintChannel::terrain_source
        && channel != NativeFeatureFootprintChannel::render
        && channel != NativeFeatureFootprintChannel::collision
        && channel != NativeFeatureFootprintChannel::navigation) reject();
    const auto x0 = cell_for(bounds.min_x, cell_size);
    const auto x1 = cell_for(bounds.max_x, cell_size);
    const auto y0 = cell_for(bounds.min_y, cell_size);
    const auto y1 = cell_for(bounds.max_y, cell_size);
    const auto z0 = cell_for(bounds.min_z, cell_size);
    const auto z1 = cell_for(bounds.max_z, cell_size);
    const std::int64_t rows_y = static_cast<std::int64_t>(y1) - y0 + 1LL;
    const std::int64_t rows_z = static_cast<std::int64_t>(z1) - z0 + 1LL;
    if (x0 > x1 || rows_y <= 0 || rows_z <= 0
        || rows_y > 4096LL || rows_z > 4096LL || rows_y * rows_z > 4096LL) reject();
    std::vector<NativeFeatureFootprintRun> runs;
    for (std::int64_t z = z0; z <= z1; ++z)
        for (std::int64_t y = y0; y <= y1; ++y)
            runs.push_back({channel, {x0, static_cast<std::int32_t>(y), static_cast<std::int32_t>(z)}, x1});
    return runs;
}

} // namespace voxel::world_backend
