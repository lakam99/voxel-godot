#pragma once

#include "godot_pcg_compat.hpp"

#include <array>
#include <cstdint>
#include <stdexcept>
#include <string>
#include <vector>

namespace voxel::world_backend {

enum class NativeOreKind : std::uint8_t { iron = 1, copper = 2 };
struct NativeOreClusterChildStream final {
    std::string durable_id;
    std::uint64_t state_before = 0U;
    std::uint64_t state_after = 0U;
    std::vector<float> float_draws;
    std::int64_t drop_count = 0;
};
class NativeOreClusterStreamRejected final : public std::invalid_argument {
public: NativeOreClusterStreamRejected();
};
// Shadow recipe witness for make_ore_cluster(..., count = 2) with neither
// child removed. This is not yet a save-replay authority: live Godot checks
// each child tombstone before that child's draws, so filtering a completed
// cluster would perturb later shared-PCG coordinates and features.
class NativeOreClusterStream final {
public:
    static NativeOreClusterStream create(const std::string &parent_id, NativeOreKind kind, GodotPcg32 &rng);
    const std::array<NativeOreClusterChildStream, 2> &children() const noexcept;
    std::uint64_t final_rng_state() const noexcept;
private:
    NativeOreClusterStream(std::array<NativeOreClusterChildStream, 2> children, std::uint64_t final_state) noexcept;
    std::array<NativeOreClusterChildStream, 2> children_{};
    std::uint64_t final_state_ = 0U;
};
} // namespace voxel::world_backend
