#pragma once

#include <array>
#include <cstddef>
#include <cstdint>
#include <memory>

namespace voxel::world_backend {

enum class TerrainNoiseChannel : std::uint8_t {
    height = 0,
    ridge = 1,
    flat = 2,
    moisture = 3,
    temperature = 4,
};

struct FastNoiseConfiguration {
    TerrainNoiseChannel channel = TerrainNoiseChannel::height;
    const char *name = "height";
    std::int32_t salt = 17;
    float frequency = 0.0058F;
    std::int32_t octaves = 4;
    float gain = 0.5F;
    float lacunarity = 2.0F;
    float weighted_strength = 0.0F;
};

const std::array<FastNoiseConfiguration, 5> &terrain_noise_configurations() noexcept;
std::int32_t terrain_noise_seed(std::uint32_t legacy_hash, std::int32_t salt) noexcept;

// This is the only first-party type allowed to include the vendored
// FastNoiseLite implementation. Inputs cross the same float boundary as
// Godot's single-precision FastNoiseLite resource before sampling.
class FastNoiseCompat final {
public:
    explicit FastNoiseCompat(std::uint32_t legacy_hash);
    ~FastNoiseCompat();

    FastNoiseCompat(FastNoiseCompat &&) noexcept;
    FastNoiseCompat &operator=(FastNoiseCompat &&) noexcept;
    FastNoiseCompat(const FastNoiseCompat &) = delete;
    FastNoiseCompat &operator=(const FastNoiseCompat &) = delete;

    std::int32_t seed(TerrainNoiseChannel channel) const noexcept;
    float sample_2d(TerrainNoiseChannel channel, double x, double z) const noexcept;
    float sample_3d(TerrainNoiseChannel channel, double x, double y, double z) const noexcept;
    double sample_2d_01(TerrainNoiseChannel channel, double x, double z) const noexcept;
    double sample_3d_01(TerrainNoiseChannel channel, double x, double y, double z) const noexcept;

private:
    struct Impl;
    std::unique_ptr<Impl> impl_;
};

} // namespace voxel::world_backend
