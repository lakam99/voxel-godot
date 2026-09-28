#include "test_harness.hpp"

#include "../core/godot_pcg_compat.hpp"

#include <array>
#include <cstdint>
#include <cstring>
#include <limits>

using namespace voxel::world_backend;

namespace {

std::uint32_t float_bits(const float value) {
    std::uint32_t result = 0U;
    std::memcpy(&result, &value, sizeof(result));
    return result;
}

} // namespace

VWB_TEST(godot_pcg_compat_matches_godot_461_seed_raw_values_and_states) {
    GodotPcg32 zero(0U);
    const std::array<std::uint32_t, 8U> expected_zero = {
        881477183U, 1327520283U, 692503688U, 2153658078U,
        2046399657U, 3080186220U, 910586837U, 2901098513U,
    };
    const std::array<std::uint64_t, 8U> states_zero = {
        17770778703077977929ULL, 11034430523946273140ULL,
        10046909401099057155ULL, 5735713945700390950ULL,
        5295815986678782797ULL, 5822712955866432040ULL,
        5141441010930940839ULL, 10389552378507106298ULL,
    };
    for (std::size_t index = 0U; index < expected_zero.size(); ++index) {
        const std::uint32_t actual = zero.randi();
        VWB_EXPECT(actual == expected_zero[index]);
        VWB_EXPECT(zero.state() == states_zero[index]);
    }

    GodotPcg32 one(1U);
    const std::array<std::uint32_t, 8U> expected_one = {
        1811587497U, 683407368U, 2033395789U, 2375931748U,
        2873319489U, 2189615729U, 3391941925U, 1039475129U,
    };
    for (const std::uint32_t value : expected_one) VWB_EXPECT(one.randi() == value);
    VWB_EXPECT(one.state() == 16973795863689901511ULL);
}

VWB_TEST(godot_pcg_compat_matches_inclusive_ranges_swapped_bounds_and_full_domain) {
    GodotPcg32 rng(0U);
    const std::array<std::int64_t, 8U> expected = {8, 8, 13, 3, 7, 20, 12, 13};
    for (const std::int64_t value : expected) VWB_EXPECT_EQ(value, rng.randi_range(0, 24));
    VWB_EXPECT_EQ(10389552378507106298ULL, rng.state());

    GodotPcg32 swapped(1U);
    VWB_EXPECT_EQ(22, swapped.randi_range(24, 0));
    VWB_EXPECT_EQ(6844932353678761266ULL, swapped.state());

    // This range has a 2^31+1 bound.  The first three raw samples are below
    // PCG's rejection threshold, proving a native modulo shortcut cannot
    // preserve subsequent world-source state.
    GodotPcg32 rejected(0U);
    VWB_EXPECT_EQ(-1067567395LL, rejected.randi_range(-1073741824, 1073741824));
    VWB_EXPECT_EQ(5735713945700390950ULL, rejected.state());

    GodotPcg32 full_domain(0U);
    VWB_EXPECT_EQ(-1266006465LL, full_domain.randi_range(
        std::numeric_limits<std::int32_t>::min(), std::numeric_limits<std::int32_t>::max()));
    VWB_EXPECT_EQ(17770778703077977929ULL, full_domain.state());
}

VWB_TEST(godot_pcg_compat_equal_bound_range_preserves_godot_461_state) {
    // Direct Godot RandomNumberGenerator oracle, seed 0xffffffff:
    // randi_range(1, 1) -> 1, before == after == -9176265316429931931
    // when viewed as signed, or 9270478757279619685 as uint64_t.
    GodotPcg32 rng(0xffffffffULL);
    VWB_EXPECT_EQ(9270478757279619685ULL, rng.state());
    VWB_EXPECT_EQ(1, rng.randi_range(1, 1));
    VWB_EXPECT_EQ(9270478757279619685ULL, rng.state());
    VWB_EXPECT_EQ(-7, rng.randi_range(-7, -7));
    VWB_EXPECT_EQ(9270478757279619685ULL, rng.state());
    // A neighboring non-equal range must still consume the original draw.
    VWB_EXPECT_EQ(10362380710714179936ULL, (static_cast<void>(rng.randi_range(1, 2)), rng.state()));
}

VWB_TEST(godot_pcg_compat_matches_randf_bits_and_explicit_zero_path) {
    GodotPcg32 rng(0U);
    const std::array<std::uint32_t, 8U> expected_bits = {
        1045373018U, 1040211511U, 1052219369U, 1043131200U,
        1062992400U, 1056026839U, 1060466456U, 1057272525U,
    };
    for (const std::uint32_t bits : expected_bits) VWB_EXPECT_EQ(bits, float_bits(rng.randf()));
    VWB_EXPECT_EQ(7438143122385300322ULL, rng.state());

    GodotPcg32 zero_path(1U);
    zero_path.set_state(0U);
    VWB_EXPECT_EQ(0.0F, zero_path.randf());
    VWB_EXPECT_EQ(2885390081777926815ULL, zero_path.state());

    // State 2^27 produces raw PCG output 1: its 31 leading zeroes exercise
    // the count-to-bit-exhaustion branch that ordinary short streams rarely
    // reach, without inventing a non-engine RNG path.
    GodotPcg32 smallest_exponent(1U);
    smallest_exponent.set_state(0x08000000ULL);
    VWB_EXPECT(float_bits(smallest_exponent.randf()) > 0U);

    // Seed one reaches a high-bit proto exponent by its third randf(), which
    // covers the ordinary zero-leading-bit exit independently of the crafted
    // smallest exponent above.
    GodotPcg32 high_bit_exponent(1U);
    static_cast<void>(high_bit_exponent.randf());
    static_cast<void>(high_bit_exponent.randf());
    VWB_EXPECT(float_bits(high_bit_exponent.randf()) > 0U);
}

VWB_TEST(godot_pcg_compat_state_replacement_preserves_godot_stream_increment) {
    GodotPcg32 seeded(123U);
    seeded.set_state(0U);
    VWB_EXPECT_EQ(0U, seeded.randi());
    VWB_EXPECT_EQ(2885390081777926815ULL, seeded.state());
    seeded.seed(0xffffffffULL);
    VWB_EXPECT_EQ(1866142959U, seeded.randi());
}
