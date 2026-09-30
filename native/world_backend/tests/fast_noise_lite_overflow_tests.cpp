#include "../core/thirdparty/fast_noise_lite/FastNoiseLite.h"
#include "../core/fast_noise_compat.hpp"
#include "test_harness.hpp"

#include <array>
#include <cmath>
#include <cstdint>
#include <cstring>
#include <limits>

namespace voxel::world_backend::tests {
namespace {
std::uint32_t bits(float value) {
    std::uint32_t result = 0;
    static_assert(sizeof(result) == sizeof(value));
    std::memcpy(&result, &value, sizeof(result));
    return result;
}
fastnoiselite::FastNoiseLite configured(std::int32_t seed, float frequency, int octaves) {
    fastnoiselite::FastNoiseLite noise;
    noise.SetSeed(seed);
    noise.SetNoiseType(fastnoiselite::FastNoiseLite::NoiseType_OpenSimplex2);
    noise.SetFrequency(frequency);
    noise.SetFractalType(fastnoiselite::FastNoiseLite::FractalType_FBm);
    noise.SetFractalOctaves(octaves);
    noise.SetFractalGain(0.5f);
    noise.SetFractalLacunarity(2.0f);
    noise.SetFractalWeightedStrength(0.0f);
    return noise;
}
}

VWB_TEST(fast_noise_vendor_wrapped_lattice_preserves_existing_world_golden_bits) {
    // These pinned direct-vendor inputs match the five production channel
    // configurations; existing terrain_source_tests independently pin facade bits.
    constexpr std::array<std::int32_t, 5> seeds{{1769607420, 1769813314, 1770035046, 1770320130, 1770510186}};
    constexpr std::array<float, 5> frequency{{0.0058f, 0.014f, 0.0024f, 0.006f, 0.005f}};
    constexpr std::array<int, 5> octaves{{4, 3, 3, 3, 3}};
    constexpr std::array<std::uint32_t, 5> expected2{{1054991575u, 3200512682u, 3206307141u, 3193515022u, 1035827032u}};
    constexpr std::array<std::uint32_t, 5> expected3{{3196712140u, 1045121409u, 3197985548u, 1048590768u, 1021684448u}};
    for (std::size_t i = 0; i < seeds.size(); ++i) {
        auto noise = configured(seeds[i], frequency[i], octaves[i]);
        VWB_EXPECT_EQ(expected2[i], bits(noise.GetNoise<float>(-3900.25f, 2600.75f)));
        VWB_EXPECT_EQ(expected3[i], bits(noise.GetNoise<float>(-7100.125f, 1899.875f, 799.625f)));
    }
}

VWB_TEST(cave_noise_compat_uses_procedural_cave_field_seed_and_profile_contract) {
    const std::vector<std::uint32_t> seed_code_points{
        'a','t','l','a','s','-','1','4','9','2'};
    const CaveNoiseCompat first(seed_code_points);
    const CaveNoiseCompat second(seed_code_points);
    VWB_EXPECT_EQ(832792642, first.seed(CaveNoiseChannel::chambers));
    VWB_EXPECT_EQ(1139199212, first.seed(CaveNoiseChannel::passages));
    VWB_EXPECT_EQ(701837427, first.seed(CaveNoiseChannel::crossings));
    VWB_EXPECT_EQ(1202240360, first.seed(CaveNoiseChannel::detail));
    for (const CaveNoiseChannel channel : {CaveNoiseChannel::chambers,
             CaveNoiseChannel::passages, CaveNoiseChannel::crossings,
             CaveNoiseChannel::detail}) {
        const float left = first.sample_3d(channel, -17.25F, 8.5F, 93.75F);
        const float right = second.sample_3d(channel, -17.25F, 8.5F, 93.75F);
        VWB_EXPECT(std::isfinite(left));
        VWB_EXPECT_EQ(bits(left), bits(right));
    }
}

VWB_TEST(fast_noise_vendor_fractal_seed_wrap_matches_separate_boundary_octaves) {
    const int last = std::numeric_limits<int>::max();
    const int first = std::numeric_limits<int>::min();
    auto combined = configured(last, 1.0f, 2);
    auto first_octave = configured(last, 1.0f, 1);
    auto second_octave = configured(first, 1.0f, 1);
    const float first2 = first_octave.GetNoise<float>(0.25f, -0.5f);
    const float second2 = second_octave.GetNoise<float>(0.5f, -1.0f);
    const float first3 = first_octave.GetNoise<float>(0.25f, -0.5f, -0.125f);
    const float second3 = second_octave.GetNoise<float>(0.5f, -1.0f, -0.25f);
    const float expected2 = first2 * (2.0f / 3.0f) + second2 * (1.0f / 3.0f);
    const float expected3 = first3 * (2.0f / 3.0f) + second3 * (1.0f / 3.0f);
    VWB_EXPECT(std::isfinite(combined.GetNoise<float>(0.25f, -0.5f)));
    VWB_EXPECT(std::isfinite(combined.GetNoise<float>(0.25f, -0.5f, -0.125f)));
    VWB_EXPECT(std::fabs(combined.GetNoise<float>(0.25f, -0.5f) - expected2) < 0.000001f);
    VWB_EXPECT(std::fabs(combined.GetNoise<float>(0.25f, -0.5f, -0.125f) - expected3) < 0.000001f);
}
}
