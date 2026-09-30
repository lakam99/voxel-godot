#include "fast_noise_compat.hpp"

#include "thirdparty/fast_noise_lite/FastNoiseLite.h"

#include <utility>
#include <new>
#include <cstring>
#include <limits>
#include <cmath>
#include <string_view>

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

struct CaveNoiseConfiguration {
    CaveNoiseChannel channel;
    const char *salt;
    float frequency;
};

constexpr std::array<CaveNoiseConfiguration, 4> CAVE_CONFIGURATIONS{{
    {CaveNoiseChannel::chambers, "chambers", 0.032F},
    {CaveNoiseChannel::passages, "passages", 0.022F},
    {CaveNoiseChannel::crossings, "passage-crossings", 0.024F},
    {CaveNoiseChannel::detail, "rock", 0.19F},
}};

std::size_t cave_channel_index(const CaveNoiseChannel channel) noexcept {
    const auto value = static_cast<std::size_t>(channel);
    return value < CAVE_CONFIGURATIONS.size() ? value : 0U;
}

std::uint32_t cave_seed(const std::vector<std::uint32_t> &seed_code_points, const char *salt) noexcept {
    std::uint32_t result = 2166136261U;
    const auto append = [&result](const std::uint32_t code_point) {
        result = (result ^ code_point) * 16777619U;
    };
    for (const std::uint32_t code_point : seed_code_points) append(code_point);
    constexpr char prefix[] = ":caves:";
    for (const char value : prefix) {
        if (value == '\0') break;
        append(static_cast<std::uint8_t>(value));
    }
    for (const char value : std::string_view(salt)) append(static_cast<std::uint8_t>(value));
    return result & 0x7fffffffU;
}

fastnoiselite::FastNoiseLite make_cave_noise(
    const std::vector<std::uint32_t> &seed_code_points,
    const CaveNoiseConfiguration &configuration) {
    fastnoiselite::FastNoiseLite noise;
    noise.SetSeed(static_cast<std::int32_t>(cave_seed(seed_code_points, configuration.salt)));
    noise.SetNoiseType(fastnoiselite::FastNoiseLite::NoiseType_OpenSimplex2);
    noise.SetFrequency(configuration.frequency);
    noise.SetFractalType(fastnoiselite::FastNoiseLite::FractalType_FBm);
    noise.SetFractalOctaves(2);
    noise.SetFractalGain(0.45F);
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

struct CaveNoiseCompat::Impl {
    explicit Impl(const std::vector<std::uint32_t> &seed_code_points)
        : noises{{
              make_cave_noise(seed_code_points, CAVE_CONFIGURATIONS[0]),
              make_cave_noise(seed_code_points, CAVE_CONFIGURATIONS[1]),
              make_cave_noise(seed_code_points, CAVE_CONFIGURATIONS[2]),
              make_cave_noise(seed_code_points, CAVE_CONFIGURATIONS[3]),
          }},
          seeds{{
              static_cast<std::int32_t>(cave_seed(seed_code_points, CAVE_CONFIGURATIONS[0].salt)),
              static_cast<std::int32_t>(cave_seed(seed_code_points, CAVE_CONFIGURATIONS[1].salt)),
              static_cast<std::int32_t>(cave_seed(seed_code_points, CAVE_CONFIGURATIONS[2].salt)),
              static_cast<std::int32_t>(cave_seed(seed_code_points, CAVE_CONFIGURATIONS[3].salt)),
          }} {}

    std::array<fastnoiselite::FastNoiseLite, 4> noises;
    std::array<std::int32_t, 4> seeds;
};

CaveNoiseCompat::CaveNoiseCompat(const std::vector<std::uint32_t> &seed_code_points)
    : impl_(std::make_unique<Impl>(seed_code_points)) {}
CaveNoiseCompat::~CaveNoiseCompat() = default;
CaveNoiseCompat::CaveNoiseCompat(CaveNoiseCompat &&) noexcept = default;
CaveNoiseCompat &CaveNoiseCompat::operator=(CaveNoiseCompat &&) noexcept = default;

std::int32_t CaveNoiseCompat::seed(const CaveNoiseChannel channel) const noexcept {
    return impl_->seeds[cave_channel_index(channel)];
}

float CaveNoiseCompat::sample_3d(
    const CaveNoiseChannel channel, const float x, const float y, const float z) const noexcept {
    return impl_->noises[cave_channel_index(channel)].GetNoise<float>(x, y, z);
}

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

namespace {
using Noise = fastnoiselite::FastNoiseLite;
struct NoiseHeader {
    std::uintptr_t self;
    std::uintptr_t owner;
    std::uint64_t cookie;
    std::uint64_t generation;
    std::uint32_t hash;
    std::uint32_t magic;
};
struct NoiseSlot { alignas(Noise) std::byte bytes[sizeof(Noise)]; };
struct NoiseStorage { NoiseHeader header; NoiseSlot slots[5]; };
constexpr std::uint32_t NOISE_MAGIC = 0x4e35464eU;
// Pinned OpenSimplex2 FBm: among the five paired frequency/octave settings,
// the largest frequency * 2^octaves (including the extra post-final multiply)
// is ridge .014 * 8 = .112; height's four octaves yield only .0058 * 16.
// A conservative factor 3 for either the 2D skew or default 3D rotation
// gives .112 * 3 * 2^32 < 1.45e9. FastFloor/FastRound and their
// +/-0.5 conversion stay comfortably inside int32. Natural int32 cell inputs
// plus all fixed surface/cave offsets are inside this argument envelope.
constexpr double SAFE_NOISE_ARGUMENT = 4294967296.0;
bool safe_noise_argument(const double value) noexcept {
    return std::isfinite(value) && std::abs(value) <= SAFE_NOISE_ARGUMENT;
}
bool valid_span(const StorageSpan span) noexcept {
    return span.data != nullptr && span.size == sizeof(NoiseStorage)
        && reinterpret_cast<std::uintptr_t>(span.data) % alignof(NoiseStorage) == 0U;
}
Noise *slot(NoiseStorage *storage, const std::size_t index) noexcept {
    return std::launder(reinterpret_cast<Noise *>(storage->slots[index].bytes));
}
// Each effect is debited before execution. Octave/Gain setters run the
// vendored fixed octave bounding loop, so include that cost in their atom.
std::size_t setup_cost(const std::uint8_t step, const FastNoiseConfiguration &configuration) noexcept {
    if (step == 5U || step == 6U) return 1U + static_cast<std::size_t>(configuration.octaves - 1);
    return 1U;
}
void setup_noise(Noise &noise, const std::uint8_t step, const std::uint32_t hash,
    const FastNoiseConfiguration &configuration) noexcept {
    switch (step) {
    case 1: noise.SetSeed(terrain_noise_seed(hash, configuration.salt)); break;
    case 2: noise.SetNoiseType(Noise::NoiseType_OpenSimplex2); break;
    case 3: noise.SetFrequency(configuration.frequency); break;
    case 4: noise.SetFractalType(Noise::FractalType_FBm); break;
    case 5: noise.SetFractalOctaves(configuration.octaves); break;
    case 6: noise.SetFractalGain(configuration.gain); break;
    case 7: noise.SetFractalLacunarity(configuration.lacunarity); break;
    case 8: noise.SetFractalWeightedStrength(configuration.weighted_strength); break;
    case 9: noise.SetDomainWarpType(Noise::DomainWarpType_OpenSimplex2); break;
    case 10: noise.SetDomainWarpAmp(0.0F); break;
    default: break;
    }
}
}
struct NoiseAccess {
    static EvalReason binding(const NoiseCursor &cursor, const StorageSpan span) noexcept {
        if (!valid_span(span) || reinterpret_cast<std::uintptr_t>(span.data) != cursor.base_
            || span.size != cursor.extent_) return EvalReason::storage;
        // Read only the initialized trivial header, after supplied-span preflight.
        NoiseHeader header{};
        std::memcpy(&header, span.data, sizeof(header));
        if (header.self != cursor.base_ || header.owner != reinterpret_cast<std::uintptr_t>(&cursor)
            || header.cookie != cursor.cookie_ || header.generation != cursor.identity_.generation
            || header.hash != cursor.identity_.legacy_hash || header.magic != NOISE_MAGIC)
            return EvalReason::storage;
        return EvalReason::none;
    }
    static EvalReason check(NoiseCursor &cursor, const StorageSpan span,
        const ContextIdentity &identity, const WorkQuota &quota) noexcept {
        auto reason = binding(cursor, span);
        if (reason == EvalReason::none && !(cursor.identity_ == identity)) reason = EvalReason::identity;
        if (reason != EvalReason::none && quota.remaining() != 0U) {
            cursor.status_ = EvalStatus::rejected;
            cursor.reason_ = reason;
        }
        return reason;
    }
    static NoiseStep sample(NoiseUse &use, const StorageSpan span, const ContextIdentity identity,
        const TerrainNoiseChannel channel, const double x, const double y, const double z,
        const bool three, WorkQuota &quota) noexcept {
        if (!use.acquired_) return {{EvalStatus::rejected, EvalReason::in_use, 0U, 0U}, 0.0};
        auto &cursor = *use.owner_;
        const auto reason = check(cursor, span, identity, quota);
        if (reason != EvalReason::none) return {{EvalStatus::rejected, reason, 0U, 0U}, 0.0};
        if (cursor.status_ != EvalStatus::ready)
            return {{cursor.status_, cursor.reason_, 0U, 0U}, 0.0};
        const auto index = static_cast<std::size_t>(channel);
        if (index >= 5U) return {{EvalStatus::rejected, EvalReason::input, 0U, 0U}, 0.0};
        // Validate all three values, including Y for a 2D call. Malformed
        // numeric input is retryable and never changes the owner or quota.
        if (!safe_noise_argument(x) || !safe_noise_argument(y) || !safe_noise_argument(z))
            return {{EvalStatus::rejected, EvalReason::input, 0U, 0U}, 0.0};
        const auto cost = static_cast<std::size_t>(CONFIGURATIONS[index].octaves);
        if (!quota.try_debit(cost)) return {{EvalStatus::pending, EvalReason::quota, 0U, cost}, 0.0};
        auto *noise = slot(static_cast<NoiseStorage *>(span.data), index);
        const float value = three ? noise->GetNoise<float>(static_cast<float>(x), static_cast<float>(y), static_cast<float>(z))
            : noise->GetNoise<float>(static_cast<float>(x), static_cast<float>(z));
        return {{EvalStatus::ready, EvalReason::none, cost, 0U}, static_cast<double>(value) * 0.5 + 0.5};
    }
    static EvalStep validate(NoiseCursor &cursor, const StorageSpan span,
        const ContextIdentity identity, const WorkQuota &quota) noexcept {
        if (cursor.in_use_) return {EvalStatus::rejected, EvalReason::in_use, 0U, 0U};
        if (cursor.status_ == EvalStatus::idle || cursor.status_ == EvalStatus::drained)
            return {EvalStatus::rejected, EvalReason::phase, 0U, 0U};
        const auto reason = check(cursor, span, identity, quota);
        return {reason == EvalReason::none ? cursor.status_ : EvalStatus::rejected,
            reason == EvalReason::none ? cursor.reason_ : reason, 0U, 0U};
    }
};
bool ContextIdentity::operator==(const ContextIdentity &other) const noexcept {
    return stamp == other.stamp && generation == other.generation && legacy_hash == other.legacy_hash;
}
NoiseCursor::NoiseCursor() noexcept
    : base_(0), extent_(0), identity_{}, generation_floor_(0), cookie_(0),
      status_(EvalStatus::idle), reason_(EvalReason::none), constructed_(0), setup_step_(0), in_use_(false) {}
NoiseCursor::~NoiseCursor() {
    // Caller storage must outlive this nonmovable owner; destruction during use
    // is prohibited by the serialized-caller contract. Emergency cleanup <=5.
    if (constructed_ != 0U) {
        auto *storage = reinterpret_cast<NoiseStorage *>(base_);
        while (constructed_ != 0U) slot(storage, --constructed_)->~Noise();
    }
}
EvalStatus NoiseCursor::status() const noexcept { return status_; }
std::size_t NoiseCursor::constructed_count() const noexcept { return constructed_; }
ContextIdentity NoiseCursor::identity() const noexcept { return identity_; }
bool NoiseCursor::in_use() const noexcept { return in_use_; }
NoiseUse::NoiseUse(NoiseCursor &owner) noexcept : owner_(&owner), acquired_(!owner.in_use_) {
    if (acquired_) owner.in_use_ = true;
}
NoiseUse::~NoiseUse() { if (acquired_) owner_->in_use_ = false; }
bool NoiseUse::acquired() const noexcept { return acquired_; }
std::size_t noise_storage_size() noexcept { return sizeof(NoiseStorage); }
std::size_t noise_storage_alignment() noexcept { return alignof(NoiseStorage); }
EvalStep begin_noise(NoiseCursor &cursor, const StorageSpan span,
    const ContextIdentity identity, WorkQuota &quota) noexcept {
    if (cursor.in_use_) return {EvalStatus::rejected, EvalReason::in_use, 0U, 0U};
    if (cursor.status_ != EvalStatus::idle && cursor.status_ != EvalStatus::drained)
        return {EvalStatus::rejected, EvalReason::phase, 0U, 0U};
    if (!valid_span(span)) return {EvalStatus::rejected, EvalReason::storage, 0U, 0U};
    if (identity.generation == 0U || identity.generation <= cursor.generation_floor_
        || cursor.cookie_ == std::numeric_limits<std::uint64_t>::max())
        return {EvalStatus::rejected, EvalReason::generation, 0U, 0U};
    if (!quota.try_debit(1U)) return {EvalStatus::pending, EvalReason::quota, 0U, 1U};
    cursor.base_ = reinterpret_cast<std::uintptr_t>(span.data); cursor.extent_ = span.size;
    cursor.identity_ = identity; cursor.generation_floor_ = identity.generation; ++cursor.cookie_;
    cursor.status_ = EvalStatus::pending; cursor.reason_ = EvalReason::none;
    cursor.constructed_ = 0U; cursor.setup_step_ = 0U;
    new (span.data) NoiseStorage; // Slots are bytes: no noise constructors here.
    static_cast<NoiseStorage *>(span.data)->header = {cursor.base_, reinterpret_cast<std::uintptr_t>(&cursor),
        cursor.cookie_, identity.generation, identity.legacy_hash, NOISE_MAGIC};
    return {cursor.status_, EvalReason::none, 1U, 1U};
}
EvalStep advance_noise(NoiseCursor &cursor, const StorageSpan span,
    const ContextIdentity identity, WorkQuota &quota) noexcept {
    if (cursor.in_use_) return {EvalStatus::rejected, EvalReason::in_use, 0U, 0U};
    if (cursor.status_ == EvalStatus::idle || cursor.status_ == EvalStatus::drained)
        return {EvalStatus::rejected, EvalReason::phase, 0U, 0U};
    const auto reason = NoiseAccess::check(cursor, span, identity, quota);
    if (reason != EvalReason::none) return {EvalStatus::rejected, reason, 0U, 0U};
    if (cursor.status_ != EvalStatus::pending) return {cursor.status_, cursor.reason_, 0U, 0U};
    const auto before = quota.remaining();
    std::size_t next = 1U;
    while (cursor.status_ == EvalStatus::pending) {
        const auto index = cursor.setup_step_ == 0U ? cursor.constructed_ : cursor.constructed_ - 1U;
        const auto &configuration = CONFIGURATIONS[index];
        next = setup_cost(cursor.setup_step_, configuration);
        if (!quota.try_debit(next)) break;
        auto *storage = static_cast<NoiseStorage *>(span.data);
        if (cursor.setup_step_ == 0U) {
            new (storage->slots[index].bytes) Noise; ++cursor.constructed_;
        } else setup_noise(*slot(storage, index), cursor.setup_step_, identity.legacy_hash, configuration);
        if (++cursor.setup_step_ == 11U) {
            cursor.setup_step_ = 0U;
            if (cursor.constructed_ == 5U) cursor.status_ = EvalStatus::ready;
        }
    }
    return {cursor.status_, cursor.status_ == EvalStatus::ready ? EvalReason::none : EvalReason::quota,
        before - quota.remaining(), cursor.status_ == EvalStatus::ready ? 0U : next};
}
ControlResult cancel_noise(NoiseCursor &cursor) noexcept {
    if (cursor.in_use_) return {EvalStatus::rejected, EvalReason::in_use, 1U};
    if (cursor.status_ == EvalStatus::idle || cursor.status_ == EvalStatus::drained)
        return {cursor.status_, EvalReason::none, 1U};
    cursor.status_ = EvalStatus::cancelled; return {cursor.status_, EvalReason::none, 1U};
}
EvalStep drain_noise(NoiseCursor &cursor, const StorageSpan span, WorkQuota &quota) noexcept {
    if (cursor.in_use_) return {EvalStatus::rejected, EvalReason::in_use, 0U, 0U};
    if (cursor.status_ != EvalStatus::cancelled && cursor.status_ != EvalStatus::rejected && cursor.status_ != EvalStatus::drained)
        return {EvalStatus::rejected, EvalReason::phase, 0U, 0U};
    const auto reason = NoiseAccess::binding(cursor, span);
    if (reason != EvalReason::none) return {EvalStatus::rejected, reason, 0U, 0U};
    if (cursor.status_ == EvalStatus::drained) return {cursor.status_, EvalReason::none, 0U, 0U};
    const auto before = quota.remaining();
    // A separate final atom prevents zero-quota mutation even for empty prefix.
    while (cursor.constructed_ != 0U && quota.try_debit(1U))
        slot(static_cast<NoiseStorage *>(span.data), --cursor.constructed_)->~Noise();
    if (cursor.constructed_ == 0U && quota.try_debit(1U)) cursor.status_ = EvalStatus::drained;
    return {cursor.status_, cursor.status_ == EvalStatus::drained ? EvalReason::none : EvalReason::quota,
        before - quota.remaining(), cursor.status_ == EvalStatus::drained ? 0U : 1U};
}
ControlResult reset_noise(NoiseCursor &cursor) noexcept {
    if (cursor.in_use_) return {EvalStatus::rejected, EvalReason::in_use, 1U};
    if (cursor.status_ != EvalStatus::idle && cursor.status_ != EvalStatus::drained)
        return {EvalStatus::rejected, EvalReason::phase, 1U};
    cursor.status_ = EvalStatus::idle; cursor.reason_ = EvalReason::none;
    return {cursor.status_, EvalReason::none, 1U};
}
NoiseStep sample_noise(NoiseUse &use, const StorageSpan span, const ContextIdentity identity,
    const TerrainNoiseChannel channel, const double x, const double y, const double z,
    const bool three, WorkQuota &quota) noexcept {
    return NoiseAccess::sample(use, span, identity, channel, x, y, z, three, quota);
}
EvalStep validate_noise(NoiseCursor &cursor, const StorageSpan span,
    const ContextIdentity identity, const WorkQuota &quota) noexcept {
    return NoiseAccess::validate(cursor, span, identity, quota);
}

} // namespace voxel::world_backend
