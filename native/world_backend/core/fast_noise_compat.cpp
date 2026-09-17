#include "fast_noise_compat.hpp"

#include "thirdparty/fast_noise_lite/FastNoiseLite.h"

#include <utility>

namespace voxel::world_backend {
namespace {

constexpr std::array<FastNoiseConfiguration, 5> CONFIGURATIONS{{
    {TerrainNoiseChannel::height, "height", 17, 0.0058F, 4, 0.5F, 2.0F, 0.0F},
    {TerrainNoiseChannel::ridge, "ridge", 43, 0.014F, 3, 0.5F, 2.0F, 0.0F},
    {TerrainNoiseChannel::flat, "flat", 71, 0.0024F, 3, 0.5F, 2.0F, 0.0F},
    {TerrainNoiseChannel::moisture, "moisture", 107, 0.006F, 3, 0.5F, 2.0F, 0.0F},
    {TerrainNoiseChannel::temperature, "temperature", 131, 0.005F, 3, 0.5F, 2.0F, 0.0F},
}};

std::size_t channel_index(const TerrainNoiseChannel channel) noexcept {
    const auto value = static_cast<std::size_t>(channel);
    return value < CONFIGURATIONS.size() ? value : 0U;
}

fastnoiselite::FastNoiseLite make_noise(const std::uint32_t legacy_hash, const FastNoiseConfiguration &configuration) {
    fastnoiselite::FastNoiseLite noise;
    noise.SetSeed(terrain_noise_seed(legacy_hash, configuration.salt));
    noise.SetNoiseType(fastnoiselite::FastNoiseLite::NoiseType_OpenSimplex2);
    noise.SetFrequency(configuration.frequency);
    noise.SetFractalType(fastnoiselite::FastNoiseLite::FractalType_FBm);
    noise.SetFractalOctaves(configuration.octaves);
    noise.SetFractalGain(configuration.gain);
    noise.SetFractalLacunarity(configuration.lacunarity);
    noise.SetFractalWeightedStrength(configuration.weighted_strength);
    noise.SetDomainWarpType(fastnoiselite::FastNoiseLite::DomainWarpType_OpenSimplex2);
    noise.SetDomainWarpAmp(0.0F);
    return noise;
}

} // namespace

struct FastNoiseCompat::Impl {
    explicit Impl(const std::uint32_t legacy_hash)
        : noises{{
              make_noise(legacy_hash, CONFIGURATIONS[0]),
              make_noise(legacy_hash, CONFIGURATIONS[1]),
              make_noise(legacy_hash, CONFIGURATIONS[2]),
              make_noise(legacy_hash, CONFIGURATIONS[3]),
              make_noise(legacy_hash, CONFIGURATIONS[4]),
          }},
          seeds{{
              terrain_noise_seed(legacy_hash, CONFIGURATIONS[0].salt),
              terrain_noise_seed(legacy_hash, CONFIGURATIONS[1].salt),
              terrain_noise_seed(legacy_hash, CONFIGURATIONS[2].salt),
              terrain_noise_seed(legacy_hash, CONFIGURATIONS[3].salt),
              terrain_noise_seed(legacy_hash, CONFIGURATIONS[4].salt),
          }} {}

    std::array<fastnoiselite::FastNoiseLite, 5> noises;
    std::array<std::int32_t, 5> seeds;
};

const std::array<FastNoiseConfiguration, 5> &terrain_noise_configurations() noexcept {
    return CONFIGURATIONS;
}

std::int32_t terrain_noise_seed(const std::uint32_t legacy_hash, const std::int32_t salt) noexcept {
    const std::uint32_t salted = legacy_hash + static_cast<std::uint32_t>(salt) * 7919U;
    return static_cast<std::int32_t>(salted & 0x7fffffffU);
}

FastNoiseCompat::FastNoiseCompat(const std::uint32_t legacy_hash)
    : impl_(std::make_unique<Impl>(legacy_hash)) {}

FastNoiseCompat::~FastNoiseCompat() = default;
FastNoiseCompat::FastNoiseCompat(FastNoiseCompat &&) noexcept = default;
FastNoiseCompat &FastNoiseCompat::operator=(FastNoiseCompat &&) noexcept = default;

std::int32_t FastNoiseCompat::seed(const TerrainNoiseChannel channel) const noexcept {
    return impl_->seeds[channel_index(channel)];
}

float FastNoiseCompat::sample_2d(const TerrainNoiseChannel channel, const double x, const double z) const noexcept {
    return impl_->noises[channel_index(channel)].GetNoise<float>(static_cast<float>(x), static_cast<float>(z));
}

float FastNoiseCompat::sample_3d(
    const TerrainNoiseChannel channel, const double x, const double y, const double z) const noexcept {
    return impl_->noises[channel_index(channel)].GetNoise<float>(
        static_cast<float>(x), static_cast<float>(y), static_cast<float>(z));
}

double FastNoiseCompat::sample_2d_01(
    const TerrainNoiseChannel channel, const double x, const double z) const noexcept {
    return static_cast<double>(sample_2d(channel, x, z)) * 0.5 + 0.5;
}

double FastNoiseCompat::sample_3d_01(
    const TerrainNoiseChannel channel, const double x, const double y, const double z) const noexcept {
    return static_cast<double>(sample_3d(channel, x, y, z)) * 0.5 + 0.5;
}

} // namespace voxel::world_backend
