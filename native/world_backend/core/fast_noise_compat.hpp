#pragma once

#include <array>
#include <cstddef>
#include <cstdint>
#include <memory>
#include <vector>
#include "legacy_seed_hash.hpp"

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

// FastNoiseLite profile used by scripts/world/ProceduralCaveField.gd. Kept
// separate from the legacy terrain channels because cave seeds, frequencies,
// and fractal settings are part of that field's deterministic contract.
enum class CaveNoiseChannel : std::uint8_t { chambers, passages, crossings, detail };

class CaveNoiseCompat final {
public:
    explicit CaveNoiseCompat(const std::vector<std::uint32_t> &seed_code_points);
    ~CaveNoiseCompat();
    CaveNoiseCompat(CaveNoiseCompat &&) noexcept;
    CaveNoiseCompat &operator=(CaveNoiseCompat &&) noexcept;
    CaveNoiseCompat(const CaveNoiseCompat &) = delete;
    CaveNoiseCompat &operator=(const CaveNoiseCompat &) = delete;

    std::int32_t seed(CaveNoiseChannel channel) const noexcept;
    float sample_3d(CaveNoiseChannel channel, float x, float y, float z) const noexcept;

private:
    struct Impl;
    std::unique_ptr<Impl> impl_;
};

struct StorageSpan { void *data; std::size_t size; };
struct ContextIdentity {
    EvaluatorStamp stamp;
    std::uint64_t generation = 0;
    std::uint32_t legacy_hash = 0;
    bool operator==(const ContextIdentity &) const noexcept;
};
class NoiseUse;
class NoiseCursor final {
public:
    // Caller-owned placement storage must outlive this owner and stay fixed.
    // Generations increase within this owner; callers also provide distinct
    // generations across owner destruction/address reuse. Identity is a
    // serialized-caller continuity contract, not hostile-input authenticity.
    NoiseCursor() noexcept;
    ~NoiseCursor();
    NoiseCursor(const NoiseCursor &) = delete;
    NoiseCursor &operator=(const NoiseCursor &) = delete;
    NoiseCursor(NoiseCursor &&) = delete;
    NoiseCursor &operator=(NoiseCursor &&) = delete;
    EvalStatus status() const noexcept;
    std::size_t constructed_count() const noexcept;
    ContextIdentity identity() const noexcept;
    bool in_use() const noexcept;
private:
    friend class NoiseUse;
    friend EvalStep begin_noise(NoiseCursor &, StorageSpan, ContextIdentity, WorkQuota &) noexcept;
    friend EvalStep advance_noise(NoiseCursor &, StorageSpan, ContextIdentity, WorkQuota &) noexcept;
    friend EvalStep drain_noise(NoiseCursor &, StorageSpan, WorkQuota &) noexcept;
    friend ControlResult cancel_noise(NoiseCursor &) noexcept;
    friend ControlResult reset_noise(NoiseCursor &) noexcept;
    friend struct NoiseAccess;
    std::uintptr_t base_;
    std::size_t extent_;
    ContextIdentity identity_;
    std::uint64_t generation_floor_;
    std::uint64_t cookie_;
    EvalStatus status_;
    EvalReason reason_;
    std::uint8_t constructed_;
    std::uint8_t setup_step_;
    bool in_use_;
};
// Ephemeral owner-local guard; never retained by an evaluation cursor.
class NoiseUse final {
public:
    explicit NoiseUse(NoiseCursor &) noexcept;
    ~NoiseUse();
    NoiseUse(const NoiseUse &) = delete;
    NoiseUse &operator=(const NoiseUse &) = delete;
    bool acquired() const noexcept;
private:
    friend struct NoiseAccess;
    NoiseCursor *owner_;
    bool acquired_;
};
struct NoiseStep { EvalStep step; double value; };
std::size_t noise_storage_size() noexcept;
std::size_t noise_storage_alignment() noexcept;
EvalStep begin_noise(NoiseCursor &, StorageSpan, ContextIdentity, WorkQuota &) noexcept;
EvalStep advance_noise(NoiseCursor &, StorageSpan, ContextIdentity, WorkQuota &) noexcept;
ControlResult cancel_noise(NoiseCursor &) noexcept;
EvalStep drain_noise(NoiseCursor &, StorageSpan, WorkQuota &) noexcept;
ControlResult reset_noise(NoiseCursor &) noexcept;
EvalStep validate_noise(NoiseCursor &, StorageSpan, ContextIdentity, const WorkQuota &) noexcept;
NoiseStep sample_noise(NoiseUse &, StorageSpan, ContextIdentity,
    TerrainNoiseChannel, double x, double y, double z, bool three_dimensional,
    WorkQuota &) noexcept;
// Sampling rejects nonfinite or |coordinate|>2^32 on all three arguments,
// including Y for 2D. Input/enum faults are retryable with no owner/quota
// mutation; identity/storage faults with positive quota remain sticky.

} // namespace voxel::world_backend
