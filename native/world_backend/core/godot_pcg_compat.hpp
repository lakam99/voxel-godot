#pragma once

#include <cstdint>

namespace voxel::world_backend {

// Exact Godot 4.6 RandomNumberGenerator primitive used by legacy deterministic
// world sources.  This is deliberately not std::mt19937 or a modulo-based
// range helper: source compatibility needs PCG's seed, rejection, and float
// draw semantics to remain visible and testable in the standalone core.
class GodotPcg32 final {
public:
    static constexpr std::uint64_t DEFAULT_INCREMENT = 1442695040888963407ULL;

    explicit GodotPcg32(std::uint64_t seed = 0U) noexcept;

    void seed(std::uint64_t value) noexcept;
    void set_state(std::uint64_t value) noexcept;
    std::uint64_t state() const noexcept;
    std::uint32_t randi() noexcept;

    // Mirrors RandomNumberGenerator.randi_range(): endpoints are inclusive,
    // accepted in either order, and the full int32 domain takes Godot's raw
    // unsigned branch rather than overflowing the bounded range.
    std::int64_t randi_range(std::int32_t from, std::int32_t to) noexcept;

    // Mirrors RandomNumberGenerator.randf(), including the rare one-draw
    // zero path.  The returned value is a Godot single-precision float.
    float randf() noexcept;

private:
    static std::uint32_t bounded_randi(GodotPcg32 &rng, std::uint32_t bound) noexcept;
    std::uint64_t state_ = 0U;
    std::uint64_t increment_ = 1U;
};

} // namespace voxel::world_backend
