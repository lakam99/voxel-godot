#include "godot_pcg_compat.hpp"

#include <algorithm>
#include <cmath>

namespace voxel::world_backend {
namespace {

constexpr std::uint64_t PCG_MULTIPLIER = 6364136223846793005ULL;

int count_leading_zeroes(const std::uint32_t value) noexcept {
    int result = 0;
    // randf() calls this only after rejecting zero. Shifting the nonzero
    // unsigned value avoids a redundant bit-exhaustion guard while preserving
    // Godot's CLZ result for every admitted proto exponent.
    std::uint32_t shifted = value;
    while ((shifted & 0x80000000U) == 0U) {
        ++result;
        shifted <<= 1U;
    }
    return result;
}

} // namespace

GodotPcg32::GodotPcg32(const std::uint64_t seed_value) noexcept {
    seed(seed_value);
}

void GodotPcg32::seed(const std::uint64_t value) noexcept {
    state_ = 0U;
    increment_ = (DEFAULT_INCREMENT << 1U) | 1U;
    static_cast<void>(randi());
    state_ += value;
    static_cast<void>(randi());
}

void GodotPcg32::set_state(const std::uint64_t value) noexcept {
    state_ = value;
}

std::uint64_t GodotPcg32::state() const noexcept {
    return state_;
}

std::uint32_t GodotPcg32::randi() noexcept {
    const std::uint64_t old_state = state_;
    state_ = old_state * PCG_MULTIPLIER + increment_;
    const std::uint32_t xorshifted = static_cast<std::uint32_t>(
        ((old_state >> 18U) ^ old_state) >> 27U);
    const std::uint32_t rotation = static_cast<std::uint32_t>(old_state >> 59U);
    return (xorshifted >> rotation) | (xorshifted << ((-rotation) & 31U));
}

std::uint32_t GodotPcg32::bounded_randi(GodotPcg32 &rng, const std::uint32_t bound) noexcept {
    // The source calls this only with a non-zero bound.  This is PCG's exact
    // threshold form: using '%' without the loop would bias the result and
    // alter later world-generation draws after a rejected value.
    const std::uint32_t threshold = -bound % bound;
    for (;;) {
        const std::uint32_t value = rng.randi();
        if (value >= threshold) return value % bound;
    }
}

std::int64_t GodotPcg32::randi_range(const std::int32_t from, const std::int32_t to) noexcept {
    const std::int64_t minimum = std::min<std::int64_t>(from, to);
    const std::int64_t maximum = std::max<std::int64_t>(from, to);
    // Godot 4.6.1 returns an equal-bound range without advancing PCG. This
    // matters for hare's 1..1 primary and extra drops in the shared chunk
    // stream; consuming a raw value here shifts every later prop attempt.
    if (minimum == maximum) return minimum;
    const std::uint32_t difference = static_cast<std::uint32_t>(maximum - minimum);
    if (difference == UINT32_MAX) {
        return static_cast<std::int64_t>(randi()) + minimum;
    }
    return static_cast<std::int64_t>(bounded_randi(*this, difference + 1U)) + minimum;
}

float GodotPcg32::randf() noexcept {
    const std::uint32_t proto_exponent_offset = randi();
    if (proto_exponent_offset == 0U) return 0.0F;
    const std::uint32_t significand = randi() | 0x80000001U;
    return std::ldexp(static_cast<float>(significand), -32 - count_leading_zeroes(proto_exponent_offset));
}

} // namespace voxel::world_backend
