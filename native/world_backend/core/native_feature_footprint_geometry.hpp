#pragma once

#include "native_generated_feature_footprint_catalog.hpp"

namespace voxel::world_backend {

class NativeFeatureFootprintGeometryRejected final : public std::invalid_argument {
public:
    NativeFeatureFootprintGeometryRejected();
};

struct NativeFeatureWorldBounds final {
    double min_x, min_y, min_z, max_x, max_y, max_z;
};

void native_feature_bounds_include_sphere(NativeFeatureWorldBounds &bounds,
    double x, double y, double z, double radius);
void native_feature_bounds_enclose_body_yaw(NativeFeatureWorldBounds &bounds,
    double body_x, double body_z);

// Conservative closed-box quantization. Negative coordinates floor correctly;
// exact positive boundaries may overinclude one cell rather than miss one.
std::vector<NativeFeatureFootprintRun> native_feature_runs_for_bounds(
    NativeFeatureWorldBounds bounds, double cell_size,
    NativeFeatureFootprintChannel channel);

} // namespace voxel::world_backend
