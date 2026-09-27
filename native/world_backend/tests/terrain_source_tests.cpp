#include "test_harness.hpp"

#include "../core/fast_noise_compat.hpp"
#include "../core/sha256.hpp"
#include "../core/terrain_source.hpp"

#include <array>
#include <cmath>
#include <cstdint>
#include <cstring>
#include <limits>
#include <sstream>
#include <stdexcept>
#include <string>
#include <utility>
#include <vector>
#include <type_traits>

namespace voxel::world_backend::tests {
namespace {

RequestAuthority authority(const std::uint64_t owner = 7, const std::uint64_t cancellation = 11,
    const std::uint64_t source_revision = 13) {
    const std::vector<std::uint8_t> identity{'a', 't', 'l', 'a', 's', '-', '1', '4', '9', '2'};
    return {sha256(identity), {owner}, {cancellation}, {source_revision}};
}

std::uint32_t float_bits(const float value) {
    std::uint32_t bits = 0;
    std::memcpy(&bits, &value, sizeof(bits));
    return bits;
}

bool near(const double left, const double right, const double tolerance = 1.0e-12) {
    return std::abs(left - right) <= tolerance;
}

std::vector<TerrainDelta> seam_air_deltas() {
    const TerrainDeltaState air{-1.35, false, TerrainMaterialId::air,
        TerrainBiomeId::underground_air, TerrainFluidId::none};
    return {
        {"n2:edit:-33,12,-5", 101, {-33, 12, -5}, air},
        {"n2:edit:-32,12,-5", 102, {-32, 12, -5}, air},
        {"n2:edit:-33,12,-4", 103, {-33, 12, -4}, air},
        {"n2:edit:-32,12,-4", 104, {-32, 12, -4}, air},
    };
}

TerrainSnapshot build(const std::vector<TerrainDelta> &deltas = {}) {
    const auto current = authority();
    return build_terrain_snapshot(n2_terrain_source_request(current, "n2:test", deltas), current);
}

TerrainSnapshotDescriptor one_cell_descriptor() {
    return {authority(), "n2:one-cell", {{0, 0, 0}, {1, 1, 1}}, TerrainSnapshotDescriptor::SCHEMA};
}

TerrainCell valid_cell() {
    return {{0, 0, 0}, 1.0, 2.0, true, TerrainMaterialId::stone,
        TerrainBiomeId::plains, TerrainBiomeId::plains, TerrainFluidId::none,
        TerrainProvenanceKind::generated, "generator:test", 1};
}

void append_u32(std::vector<std::uint8_t> &bytes, const std::uint32_t value) {
    for (unsigned shift = 0; shift < 32U; shift += 8U) {
        bytes.push_back(static_cast<std::uint8_t>(value >> shift));
    }
}

void append_i32(std::vector<std::uint8_t> &bytes, const std::int32_t value) {
    append_u32(bytes, static_cast<std::uint32_t>(value));
}

void append_u64(std::vector<std::uint8_t> &bytes, const std::uint64_t value) {
    for (unsigned shift = 0; shift < 64U; shift += 8U) {
        bytes.push_back(static_cast<std::uint8_t>(value >> shift));
    }
}

void append_f64(std::vector<std::uint8_t> &bytes, const double value) {
    std::uint64_t bits = 0;
    std::memcpy(&bits, &value, sizeof(bits));
    append_u64(bytes, bits);
}

void append_delta_record(std::vector<std::uint8_t> &bytes, const TerrainDelta &delta) {
    append_u32(bytes, static_cast<std::uint32_t>(delta.id.size()));
    bytes.insert(bytes.end(), delta.id.begin(), delta.id.end());
    append_u64(bytes, delta.revision);
    append_i32(bytes, delta.coordinate.x);
    append_i32(bytes, delta.coordinate.y);
    append_i32(bytes, delta.coordinate.z);
    append_f64(bytes, delta.state.density);
    bytes.push_back(delta.state.solid ? 1U : 0U);
    bytes.push_back(static_cast<std::uint8_t>(delta.state.material));
    bytes.push_back(static_cast<std::uint8_t>(delta.state.resolved_biome));
    bytes.push_back(static_cast<std::uint8_t>(delta.state.fluid));
}

std::vector<std::uint8_t> noncanonical_delta_bytes(const std::vector<TerrainDelta> &deltas) {
    std::vector<std::uint8_t> bytes{'V', 'T', 'D', 'L'};
    append_u32(bytes, 1U);
    append_u32(bytes, static_cast<std::uint32_t>(deltas.size()));
    for (const TerrainDelta &delta : deltas) append_delta_record(bytes, delta);
    return bytes;
}

} // namespace

VWB_TEST(terrain_typed_ids_and_names_are_frozen) {
    VWB_EXPECT_EQ(0U, static_cast<unsigned>(TerrainMaterialId::air));
    VWB_EXPECT_EQ(15U, static_cast<unsigned>(TerrainMaterialId::water));
    VWB_EXPECT_EQ(16U, static_cast<unsigned>(TerrainMaterialId::lava));
    VWB_EXPECT_EQ(0U, static_cast<unsigned>(TerrainFluidId::none));
    VWB_EXPECT_EQ(1U, static_cast<unsigned>(TerrainFluidId::water));
    VWB_EXPECT_EQ(2U, static_cast<unsigned>(TerrainFluidId::lava));
    VWB_EXPECT_EQ(0U, static_cast<unsigned>(TerrainBiomeId::plains));
    VWB_EXPECT_EQ(2U, static_cast<unsigned>(TerrainBiomeId::swamp));
    VWB_EXPECT_EQ(13U, static_cast<unsigned>(TerrainBiomeId::underground_air));
    VWB_EXPECT_EQ(14U, static_cast<unsigned>(TerrainBiomeId::alpine));
    VWB_EXPECT_EQ(std::string("deepStone"), std::string(terrain_material_name(TerrainMaterialId::deep_stone)));
    VWB_EXPECT_EQ(std::string("lava"), std::string(terrain_material_name(TerrainMaterialId::lava)));
    VWB_EXPECT_EQ(std::string("underground_air"), std::string(terrain_biome_name(TerrainBiomeId::underground_air)));
    VWB_EXPECT_EQ(std::string("alpine"), std::string(terrain_biome_name(TerrainBiomeId::alpine)));
}

VWB_TEST(fast_noise_configuration_and_seed_contract_are_explicit) {
    const auto &configurations = terrain_noise_configurations();
    VWB_EXPECT_EQ(5U, configurations.size());
    const std::array<std::int32_t, 5> salts{{17, 43, 71, 107, 131}};
    const std::array<float, 5> frequencies{{0.0058F, 0.014F, 0.0024F, 0.006F, 0.005F}};
    const std::array<std::int32_t, 5> octaves{{4, 3, 3, 3, 3}};
    const std::array<std::int32_t, 5> seeds{{1769607420, 1769813314, 1770035046, 1770320130, 1770510186}};
    FastNoiseCompat noise(1769472797U);
    for (std::size_t index = 0; index < configurations.size(); ++index) {
        VWB_EXPECT_EQ(salts[index], configurations[index].salt);
        VWB_EXPECT_EQ(frequencies[index], configurations[index].frequency);
        VWB_EXPECT_EQ(octaves[index], configurations[index].octaves);
        VWB_EXPECT_EQ(0.5F, configurations[index].gain);
        VWB_EXPECT_EQ(2.0F, configurations[index].lacunarity);
        VWB_EXPECT_EQ(0.0F, configurations[index].weighted_strength);
        VWB_EXPECT_EQ(seeds[index], noise.seed(configurations[index].channel));
    }
}

VWB_TEST(placement_noise_preserves_pinned_samples_and_atomic_quota) {
    static_assert(!std::is_copy_constructible_v<NoiseCursor>);
    static_assert(!std::is_move_constructible_v<NoiseCursor>);
    std::vector<std::byte> bytes(noise_storage_size() + noise_storage_alignment());
    void *base = bytes.data(); auto space = bytes.size();
    VWB_EXPECT(std::align(noise_storage_alignment(), noise_storage_size(), base, space) != nullptr);
    const StorageSpan storage{base, noise_storage_size()};
    NoiseCursor cursor;
    ContextIdentity identity{}; identity.generation = 1U; identity.legacy_hash = 1769472797U;
    WorkQuota zero(0U); VWB_EXPECT_EQ(0U, begin_noise(cursor, storage, identity, zero).consumed_work);
    VWB_EXPECT_EQ(EvalStatus::idle, cursor.status());
    WorkQuota begin(1U); (void)begin_noise(cursor, storage, identity, begin);
    // Constructor + first four setters, then the 4-octave setter is next.
    WorkQuota prefix(5U); const auto prefix_step = advance_noise(cursor, storage, identity, prefix);
    VWB_EXPECT_EQ(5U, prefix_step.consumed_work);
    VWB_EXPECT_EQ(4U, prefix_step.next_atomic_work);
    const auto constructed = cursor.constructed_count();
    WorkQuota insufficient(3U); const auto refused = advance_noise(cursor, storage, identity, insufficient);
    VWB_EXPECT_EQ(0U, refused.consumed_work); VWB_EXPECT_EQ(4U, refused.next_atomic_work);
    VWB_EXPECT_EQ(3U, insufficient.remaining()); VWB_EXPECT_EQ(constructed, cursor.constructed_count());
    for (std::size_t calls = 0U; cursor.status() == EvalStatus::pending && calls < 100U; ++calls) {
        WorkQuota quota(4U); const auto step = advance_noise(cursor, storage, identity, quota);
        VWB_EXPECT_EQ(4U - quota.remaining(), step.consumed_work);
    }
    VWB_EXPECT_EQ(EvalStatus::ready, cursor.status());
    const std::array<std::uint32_t, 5> expected_2d{{1054991575U, 3200512682U, 3206307141U, 3193515022U, 1035827032U}};
    const std::array<std::uint32_t, 5> expected_3d{{3196712140U, 1045121409U, 3197985548U, 1048590768U, 1021684448U}};
    {
        NoiseUse use(cursor); VWB_EXPECT(use.acquired());
        WorkQuota no_sample(0U);
        const auto deferred = sample_noise(use, storage, identity, TerrainNoiseChannel::height, 0, 0, 0, false, no_sample);
        VWB_EXPECT_EQ(EvalStatus::pending, deferred.step.status); VWB_EXPECT_EQ(4U, deferred.step.next_atomic_work);
        WorkQuota short_sample(2U);
        VWB_EXPECT_EQ(0U, sample_noise(use, storage, identity, TerrainNoiseChannel::ridge, 0, 0, 0, true, short_sample).step.consumed_work);
        VWB_EXPECT_EQ(2U, short_sample.remaining());
        const double invalid_values[] = {
            std::numeric_limits<double>::quiet_NaN(),
            std::numeric_limits<double>::infinity(),
            -std::numeric_limits<double>::infinity(),
            std::numeric_limits<double>::max(),
            4294967297.0,
        };
        for (const double invalid : invalid_values) {
            WorkQuota zero_input(0U), positive_input(4U);
            const auto rejected_zero = sample_noise(use, storage, identity, TerrainNoiseChannel::height,
                invalid, 0.0, 0.0, false, zero_input);
            const auto rejected_positive = sample_noise(use, storage, identity, TerrainNoiseChannel::height,
                0.0, invalid, 0.0, false, positive_input);
            WorkQuota z_input(4U);
            const auto rejected_z = sample_noise(use, storage, identity, TerrainNoiseChannel::height,
                0.0, 0.0, invalid, false, z_input);
            VWB_EXPECT_EQ(EvalReason::input, rejected_zero.step.reason);
            VWB_EXPECT_EQ(EvalReason::input, rejected_positive.step.reason);
            VWB_EXPECT_EQ(EvalReason::input, rejected_z.step.reason);
            VWB_EXPECT_EQ(0U, rejected_zero.step.consumed_work);
            VWB_EXPECT_EQ(0U, rejected_positive.step.consumed_work);
            VWB_EXPECT_EQ(0U, rejected_z.step.consumed_work);
            VWB_EXPECT_EQ(0U, zero_input.remaining()); VWB_EXPECT_EQ(4U, positive_input.remaining());
            VWB_EXPECT_EQ(4U, z_input.remaining());
            VWB_EXPECT_EQ(EvalStatus::ready, cursor.status()); VWB_EXPECT_EQ(identity, cursor.identity());
        }
        WorkQuota invalid_channel_quota(4U);
        WorkQuota zero_channel(0U);
        VWB_EXPECT_EQ(EvalReason::input, sample_noise(use, storage, identity,
            static_cast<TerrainNoiseChannel>(255U), 0.0, 0.0, 0.0, true, zero_channel).step.reason);
        VWB_EXPECT_EQ(EvalReason::input, sample_noise(use, storage, identity,
            static_cast<TerrainNoiseChannel>(255U), 0.0, 0.0, 0.0, true, invalid_channel_quota).step.reason);
        VWB_EXPECT_EQ(4U, invalid_channel_quota.remaining()); VWB_EXPECT_EQ(EvalStatus::ready, cursor.status());
        WorkQuota valid_boundary(4U);
        const auto legitimate = sample_noise(use, storage, identity, TerrainNoiseChannel::height,
            static_cast<double>(std::numeric_limits<std::int32_t>::max()) + 12200.0,
            0.0, -static_cast<double>(std::numeric_limits<std::int32_t>::max()), false, valid_boundary);
        VWB_EXPECT_EQ(EvalStatus::ready, legitimate.step.status);
        VWB_EXPECT(std::isfinite(legitimate.value));
        for (std::size_t index = 0U; index < 5U; ++index) {
            WorkQuota quota(8U); const auto channel = static_cast<TerrainNoiseChannel>(index);
            const auto two = sample_noise(use, storage, identity, channel, -3900.25, 0, 2600.75, false, quota);
            const auto three = sample_noise(use, storage, identity, channel, -7100.125, 1899.875, 799.625, true, quota);
            VWB_EXPECT_EQ(EvalStatus::ready, two.step.status); VWB_EXPECT_EQ(EvalStatus::ready, three.step.status);
            VWB_EXPECT_EQ(expected_2d[index], float_bits(static_cast<float>((two.value - 0.5) * 2.0)));
            VWB_EXPECT_EQ(expected_3d[index], float_bits(static_cast<float>((three.value - 0.5) * 2.0)));
        }
        NoiseUse nested(cursor); VWB_EXPECT(!nested.acquired());
        WorkQuota quota(5U);
        VWB_EXPECT_EQ(EvalReason::in_use, advance_noise(cursor, storage, identity, quota).reason);
        VWB_EXPECT_EQ(EvalReason::in_use, cancel_noise(cursor).reason);
        VWB_EXPECT_EQ(EvalReason::in_use, drain_noise(cursor, storage, quota).reason);
        VWB_EXPECT_EQ(EvalReason::in_use, reset_noise(cursor).reason);
        VWB_EXPECT_EQ(5U, quota.remaining());
    }
    (void)cancel_noise(cursor);
    WorkQuota empty(0U); const auto before = cursor.constructed_count();
    (void)drain_noise(cursor, storage, empty); VWB_EXPECT_EQ(before, cursor.constructed_count());
    WorkQuota drain(6U); VWB_EXPECT_EQ(EvalStatus::drained, drain_noise(cursor, storage, drain).status);
    VWB_EXPECT_EQ(EvalStatus::idle, reset_noise(cursor).status);
    WorkQuota reused(1U); VWB_EXPECT_EQ(EvalReason::generation, begin_noise(cursor, storage, identity, reused).reason);
    ++identity.generation; WorkQuota next(1U); VWB_EXPECT_EQ(EvalStatus::pending, begin_noise(cursor, storage, identity, next).status);
    (void)cancel_noise(cursor); WorkQuota final_drain(1U);
    VWB_EXPECT_EQ(EvalStatus::drained, drain_noise(cursor, storage, final_drain).status);
}

VWB_TEST(placement_noise_storage_substitution_is_sticky_but_original_binding_drains) {
    std::vector<std::byte> bytes(noise_storage_size() + noise_storage_alignment());
    std::vector<std::byte> foreign(noise_storage_size() + noise_storage_alignment());
    void *base = bytes.data(); auto space = bytes.size(); (void)std::align(noise_storage_alignment(), noise_storage_size(), base, space);
    void *other = foreign.data(); auto other_space = foreign.size(); (void)std::align(noise_storage_alignment(), noise_storage_size(), other, other_space);
    const StorageSpan storage{base, noise_storage_size()}; NoiseCursor cursor;
    ContextIdentity identity{}; identity.generation = 1U;
    WorkQuota begin(1U); (void)begin_noise(cursor, storage, identity, begin);
    WorkQuota construct(1U); (void)advance_noise(cursor, storage, identity, construct);
    std::memcpy(other, base, noise_storage_size()); // Deliberate invalid caller byte-copy witness.
    WorkQuota zero(0U);
    VWB_EXPECT_EQ(EvalReason::storage, advance_noise(cursor, {other, noise_storage_size()}, identity, zero).reason);
    VWB_EXPECT_EQ(EvalStatus::pending, cursor.status());
    WorkQuota positive(1U);
    VWB_EXPECT_EQ(EvalReason::storage, advance_noise(cursor, {other, noise_storage_size()}, identity, positive).reason);
    VWB_EXPECT_EQ(EvalStatus::rejected, cursor.status()); VWB_EXPECT_EQ(identity, cursor.identity());
    WorkQuota wrong_drain(4U);
    VWB_EXPECT_EQ(EvalReason::storage, drain_noise(cursor, {other, noise_storage_size()}, wrong_drain).reason);
    VWB_EXPECT_EQ(1U, cursor.constructed_count());
    WorkQuota proper(2U); VWB_EXPECT_EQ(EvalStatus::drained, drain_noise(cursor, storage, proper).status);
    VWB_EXPECT_EQ(0U, cursor.constructed_count());
    // A second placement generation must not accept the old copied header.
    ++identity.generation; WorkQuota second_begin(1U); (void)begin_noise(cursor, storage, identity, second_begin);
    std::vector<std::byte> current(noise_storage_size());
    std::memcpy(current.data(), base, current.size());
    std::memcpy(base, other, noise_storage_size());
    WorkQuota stale(1U);
    VWB_EXPECT_EQ(EvalReason::storage, advance_noise(cursor, storage, identity, stale).reason);
    VWB_EXPECT_EQ(0U, cursor.constructed_count());
    std::memcpy(base, current.data(), current.size()); // Restore original binding for genuine cleanup.
    WorkQuota restored(1U); VWB_EXPECT_EQ(EvalStatus::drained, drain_noise(cursor, storage, restored).status);
    ++identity.generation; WorkQuota third_begin(1U); (void)begin_noise(cursor, storage, identity, third_begin);
    auto substituted = identity; ++substituted.legacy_hash;
    WorkQuota zero_context(0U);
    VWB_EXPECT_EQ(EvalReason::identity, advance_noise(cursor, storage, substituted, zero_context).reason);
    VWB_EXPECT_EQ(EvalStatus::pending, cursor.status());
    WorkQuota changed_context(1U);
    VWB_EXPECT_EQ(EvalReason::identity, advance_noise(cursor, storage, substituted, changed_context).reason);
    VWB_EXPECT_EQ(identity, cursor.identity()); VWB_EXPECT_EQ(EvalStatus::rejected, cursor.status());
    WorkQuota context_drain(1U); VWB_EXPECT_EQ(EvalStatus::drained, drain_noise(cursor, storage, context_drain).status);
    NoiseCursor uninitialized;
    WorkQuota invalid(1U);
    VWB_EXPECT_EQ(EvalReason::storage, begin_noise(uninitialized, {nullptr, noise_storage_size()}, identity, invalid).reason);
    VWB_EXPECT_EQ(EvalReason::storage, begin_noise(uninitialized, {base, noise_storage_size() - 1U}, identity, invalid).reason);
    VWB_EXPECT_EQ(EvalReason::storage, begin_noise(uninitialized,
        {static_cast<std::byte *>(base) + 1U, noise_storage_size()}, identity, invalid).reason);
    VWB_EXPECT_EQ(1U, invalid.remaining());
}

VWB_TEST(fast_noise_float_boundary_is_deterministic_for_all_channels) {
    FastNoiseCompat first(1769472797U);
    FastNoiseCompat second(1769472797U);
    const std::array<std::uint32_t, 5> expected_2d{{
        1054991575U, 3200512682U, 3206307141U, 3193515022U, 1035827032U}};
    const std::array<std::uint32_t, 5> expected_3d{{
        3196712140U, 1045121409U, 3197985548U, 1048590768U, 1021684448U}};
    std::size_t index = 0;
    for (const auto &configuration : terrain_noise_configurations()) {
        const float a2 = first.sample_2d(configuration.channel, -3900.25, 2600.75);
        const float b2 = second.sample_2d(configuration.channel, -3900.25, 2600.75);
        const float a3 = first.sample_3d(configuration.channel, -7100.125, 1899.875, 799.625);
        const float b3 = second.sample_3d(configuration.channel, -7100.125, 1899.875, 799.625);
        VWB_EXPECT_EQ(float_bits(a2), float_bits(b2));
        VWB_EXPECT_EQ(float_bits(a3), float_bits(b3));
        VWB_EXPECT_EQ(expected_2d[index], float_bits(a2));
        VWB_EXPECT_EQ(expected_3d[index], float_bits(a3));
        VWB_EXPECT(std::isfinite(a2));
        VWB_EXPECT(std::isfinite(a3));
        ++index;
    }
    const float negative = first.sample_3d(TerrainNoiseChannel::ridge, -0.0, -2.000000035321271, -5.0);
    const float large = first.sample_2d(TerrainNoiseChannel::height, 12000000.25, -12200000.75);
    VWB_EXPECT(std::isfinite(negative));
    VWB_EXPECT(std::isfinite(large));
    VWB_EXPECT_EQ(float_bits(negative), float_bits(second.sample_3d(TerrainNoiseChannel::ridge, -0.0, -2.000000035321271, -5.0)));
    VWB_EXPECT_EQ(float_bits(large), float_bits(second.sample_2d(TerrainNoiseChannel::height, 12000000.25, -12200000.75)));
    VWB_EXPECT_EQ(3199709222U, float_bits(negative));
    VWB_EXPECT_EQ(1050808087U, float_bits(large));
}

VWB_TEST(fast_noise_move_and_invalid_channel_fallback_are_deterministic) {
    FastNoiseCompat original(1769472797U);
    const float expected = original.sample_2d(TerrainNoiseChannel::height, -20.0, -5.0);
    FastNoiseCompat moved(std::move(original));
    VWB_EXPECT_EQ(float_bits(expected), float_bits(moved.sample_2d(TerrainNoiseChannel::height, -20.0, -5.0)));

    FastNoiseCompat assigned(1U);
    assigned = std::move(moved);
    const auto invalid = static_cast<TerrainNoiseChannel>(255U);
    VWB_EXPECT_EQ(assigned.seed(TerrainNoiseChannel::height), assigned.seed(invalid));
    VWB_EXPECT_EQ(float_bits(expected), float_bits(assigned.sample_2d(invalid, -20.0, -5.0)));
}

VWB_TEST(legacy_scalar_climate_and_floor_rules_cover_all_boundaries) {
    VWB_EXPECT_EQ(0.0, terrain_smoothstep(-1.0, 0.0, 1.0));
    VWB_EXPECT_EQ(0.5, terrain_smoothstep(0.5, 0.0, 1.0));
    VWB_EXPECT_EQ(1.0, terrain_smoothstep(2.0, 0.0, 1.0));
    VWB_EXPECT_EQ(0.0, terrain_smoothstep(0.9, 1.0, 1.0));
    VWB_EXPECT_EQ(1.0, terrain_smoothstep(1.0, 1.0, 1.0));

    VWB_EXPECT_EQ(TerrainBiomeId::snow, terrain_biome_for_climate(0.18, 0.5));
    VWB_EXPECT_EQ(TerrainBiomeId::taiga, terrain_biome_for_climate(0.25, 0.42));
    VWB_EXPECT_EQ(TerrainBiomeId::tundra, terrain_biome_for_climate(0.25, 0.41));
    VWB_EXPECT_EQ(TerrainBiomeId::swamp, terrain_biome_for_climate(0.50, 0.80));
    VWB_EXPECT_EQ(TerrainBiomeId::desert, terrain_biome_for_climate(0.71, 0.29));
    VWB_EXPECT_EQ(TerrainBiomeId::savanna, terrain_biome_for_climate(0.71, 0.40));
    VWB_EXPECT_EQ(TerrainBiomeId::savanna, terrain_biome_for_climate(0.61, 0.48));
    VWB_EXPECT_EQ(TerrainBiomeId::plains, terrain_biome_for_climate(0.61, 0.50));
    VWB_EXPECT_EQ(TerrainBiomeId::forest, terrain_biome_for_climate(0.50, 0.63));
    VWB_EXPECT_EQ(TerrainBiomeId::plains, terrain_biome_for_climate(0.50, 0.62));

    VWB_EXPECT_EQ(TerrainBiomeId::ocean,
        terrain_surface_biome_for_height(11.29, TerrainBiomeId::forest));
    VWB_EXPECT_EQ(TerrainBiomeId::beach,
        terrain_surface_biome_for_height(12.0, TerrainBiomeId::forest));
    VWB_EXPECT_EQ(TerrainBiomeId::forest,
        terrain_surface_biome_for_height(12.8, TerrainBiomeId::forest));

    VWB_EXPECT_EQ(5.4, terrain_apply_world_floor_density(-86.4, 1.0));
    VWB_EXPECT_EQ(6.0, terrain_apply_world_floor_density(-86.4, 6.0));
    VWB_EXPECT_EQ(-1.0, terrain_apply_world_floor_density(-86.4, -1.0));
    VWB_EXPECT_EQ(1.0, terrain_apply_world_floor_density(-86.39, 1.0));
    VWB_EXPECT_EQ(1.35, terrain_apply_underground_floor_density(-83.7, -1.0));
    VWB_EXPECT_EQ(-1.0, terrain_apply_underground_floor_density(-83.69, -1.0));
}

VWB_TEST(legacy_solid_material_rule_covers_every_stratum_and_biome) {
    constexpr double cell_size = 1.35;
    const CellCoord ordinary{0, 0, 0};
    VWB_EXPECT_EQ(TerrainMaterialId::air,
        terrain_solid_material("atlas-1492", ordinary, 0.0, 0.0, TerrainBiomeId::plains, -0.1));
    VWB_EXPECT_EQ(TerrainMaterialId::bedrock,
        terrain_solid_material("atlas-1492", {0, -63, 0}, 0.0, -85.05, TerrainBiomeId::plains, 1.0));

    for (const auto &sample : std::array<std::pair<TerrainBiomeId, TerrainMaterialId>, 7>{{
             {TerrainBiomeId::beach, TerrainMaterialId::sand},
             {TerrainBiomeId::desert, TerrainMaterialId::sand},
             {TerrainBiomeId::swamp, TerrainMaterialId::mud},
             {TerrainBiomeId::snow, TerrainMaterialId::snow},
             {TerrainBiomeId::tundra, TerrainMaterialId::stone},
             {TerrainBiomeId::forest, TerrainMaterialId::grass},
             {TerrainBiomeId::plains, TerrainMaterialId::grass}}}) {
        VWB_EXPECT_EQ(sample.second,
            terrain_solid_material("atlas-1492", ordinary, cell_size, 0.0, sample.first, 1.0));
    }

    for (const auto &sample : std::array<std::pair<TerrainBiomeId, TerrainMaterialId>, 6>{{
             {TerrainBiomeId::beach, TerrainMaterialId::sand},
             {TerrainBiomeId::desert, TerrainMaterialId::sand},
             {TerrainBiomeId::swamp, TerrainMaterialId::mud},
             {TerrainBiomeId::snow, TerrainMaterialId::snow},
             {TerrainBiomeId::forest, TerrainMaterialId::dirt},
             {TerrainBiomeId::plains, TerrainMaterialId::dirt}}}) {
        VWB_EXPECT_EQ(sample.second,
            terrain_solid_material("atlas-1492", ordinary, cell_size * 3.0, 0.0, sample.first, 1.0));
    }

    VWB_EXPECT_EQ(TerrainMaterialId::stone,
        terrain_solid_material("atlas-1492", ordinary, cell_size * 7.0, 0.0, TerrainBiomeId::plains, 1.0));

    bool found_copper = false;
    bool found_iron = false;
    bool found_deep_stone = false;
    for (std::int32_t x = -5000; x <= 5000 && !(found_copper && found_iron && found_deep_stone); ++x) {
        const CellCoord cell{x, 0, 0};
        found_copper = found_copper || terrain_solid_material(
            "atlas-1492", cell, cell_size * 12.0, 0.0, TerrainBiomeId::plains, 1.0)
            == TerrainMaterialId::copper_ore;
        found_iron = found_iron || terrain_solid_material(
            "atlas-1492", cell, cell_size * 20.0, 0.0, TerrainBiomeId::plains, 1.0)
            == TerrainMaterialId::iron_ore;
        found_deep_stone = found_deep_stone || terrain_solid_material(
            "atlas-1492", cell, cell_size * 60.0, 0.0, TerrainBiomeId::plains, 1.0)
            == TerrainMaterialId::deep_stone;
    }
    VWB_EXPECT(found_copper);
    VWB_EXPECT(found_iron);
    VWB_EXPECT(found_deep_stone);
}

VWB_TEST(n2_snapshot_has_frozen_region_order_authority_and_blocker) {
    const TerrainSnapshot snapshot = build();
    VWB_EXPECT_EQ(33915U, snapshot.cells().size());
    VWB_EXPECT_EQ(35U, snapshot.size_x());
    VWB_EXPECT_EQ(51U, snapshot.size_y());
    VWB_EXPECT_EQ(19U, snapshot.size_z());
    VWB_EXPECT((snapshot.cells().front().coordinate == CellCoord{-49, -17, -17}));
    VWB_EXPECT((snapshot.cells()[1].coordinate == CellCoord{-48, -17, -17}));
    VWB_EXPECT((snapshot.cells()[35].coordinate == CellCoord{-49, -17, -16}));
    VWB_EXPECT((snapshot.cells()[35U * 19U].coordinate == CellCoord{-49, -16, -17}));
    VWB_EXPECT((snapshot.cells().back().coordinate == CellCoord{-15, 33, 1}));
    VWB_EXPECT_EQ(1U, snapshot.blockers().size());
    VWB_EXPECT_EQ(std::string("n2:blocker:tile-b:-24,-10"), snapshot.blockers()[0].stable_id);
    VWB_EXPECT((snapshot.blockers()[0].center == Vec3d{-32.4, 16.497000000000003, -13.5}));
    VWB_EXPECT((snapshot.blockers()[0].size == Vec3d{1.35, 2.7, 1.35}));
    VWB_EXPECT_EQ(std::string("fixture_obstacle"), snapshot.blockers()[0].semantic_class);
    VWB_EXPECT_EQ(std::string("blocker"), snapshot.blockers()[0].physical_intent);
    VWB_EXPECT_EQ(7ULL, snapshot.descriptor().authority.owner.value);
    VWB_EXPECT_EQ(11ULL, snapshot.descriptor().authority.cancellation.value);
    VWB_EXPECT_EQ(13ULL, snapshot.descriptor().authority.source_revision.value);
    VWB_EXPECT(!snapshot.canonical_bytes().empty());
    VWB_EXPECT(snapshot.digest() == sha256(snapshot.canonical_bytes()));
}

VWB_TEST(n2_lattice_origin_frozen_surface_density_and_material_anchors_match) {
    const TerrainSnapshot snapshot = build();
    const TerrainCell &slope_a = snapshot.at({-20, 13, -2});
    const TerrainCell &slope_b = snapshot.at({-20, 13, -1});
    VWB_EXPECT(near(slope_a.surface_y, 17.901000000000003));
    VWB_EXPECT(near(slope_b.surface_y, 17.901000000000003));
    VWB_EXPECT(near(slope_b.surface_y - slope_a.surface_y, 0.0));

    const TerrainCell &cave_a = snapshot.at({-33, -2, -5});
    const TerrainCell &cave_b = snapshot.at({-32, -2, -5});
    VWB_EXPECT(near(cave_a.density, -0.6017665929014142));
    VWB_EXPECT(near(cave_b.density, -0.35286612593816424));
    VWB_EXPECT(!cave_a.solid && !cave_b.solid);
    VWB_EXPECT_EQ(TerrainMaterialId::air, cave_a.material);
    VWB_EXPECT_EQ(TerrainMaterialId::air, cave_b.material);
    VWB_EXPECT_EQ(TerrainBiomeId::swamp, cave_a.surface_biome);
    VWB_EXPECT_EQ(TerrainBiomeId::swamp, cave_b.surface_biome);
    VWB_EXPECT_EQ(TerrainBiomeId::underground_air, cave_a.resolved_biome);
    VWB_EXPECT_EQ(TerrainBiomeId::underground_air, cave_b.resolved_biome);

    // Exercises the five-cell underground-air transition band. The cave
    // anchors above are already beyond it and would not catch a mistranslated
    // transition-width constant.
    VWB_EXPECT(near(snapshot.at({-36, 2, -17}).density, 0.9741575565764948));

    for (const CellCoord coordinate : std::array<CellCoord, 4>{{
             {-33, 12, -5}, {-32, 12, -5}, {-33, 12, -4}, {-32, 12, -4}}}) {
        const TerrainCell &cell = snapshot.at(coordinate);
        VWB_EXPECT(near(cell.density, 0.3260338576977162));
        VWB_EXPECT(cell.solid);
        VWB_EXPECT_EQ(TerrainMaterialId::mud, cell.material);
        VWB_EXPECT_EQ(TerrainProvenanceKind::generated, cell.provenance);
        VWB_EXPECT_EQ(std::string("generator:atlas-1492"), cell.provenance_id);
        VWB_EXPECT_EQ(13ULL, cell.provenance_revision);
    }
}

VWB_TEST(typed_delta_canonical_roundtrip_distinguishes_absence_from_explicit_air) {
    const auto deltas = seam_air_deltas();
    const auto bytes = serialize_terrain_deltas({deltas[3], deltas[1], deltas[0], deltas[2]});
    const auto restored = deserialize_terrain_deltas(bytes);
    VWB_EXPECT_EQ(4U, restored.size());
    VWB_EXPECT_EQ(bytes, serialize_terrain_deltas(restored));

    const TerrainSnapshot original = build();
    const TerrainSnapshot edited = build(restored);
    VWB_EXPECT(original.digest() != edited.digest());
    for (const TerrainDelta &delta : restored) {
        const TerrainCell &before = original.at(delta.coordinate);
        const TerrainCell &after = edited.at(delta.coordinate);
        VWB_EXPECT(before.solid);
        VWB_EXPECT(!after.solid);
        VWB_EXPECT(near(after.density, -1.35, 0.0));
        VWB_EXPECT_EQ(TerrainMaterialId::air, after.material);
        VWB_EXPECT_EQ(TerrainBiomeId::underground_air, after.resolved_biome);
        VWB_EXPECT_EQ(TerrainFluidId::none, after.fluid);
        VWB_EXPECT_EQ(TerrainProvenanceKind::typed_delta, after.provenance);
        VWB_EXPECT_EQ(delta.id, after.provenance_id);
        VWB_EXPECT_EQ(delta.revision, after.provenance_revision);
    }
    const TerrainCell &absent = edited.at({-31, 12, -5});
    VWB_EXPECT_EQ(TerrainProvenanceKind::generated, absent.provenance);
    VWB_EXPECT_EQ(std::string("generator:atlas-1492"), absent.provenance_id);
}

VWB_TEST(reload_rebuilds_new_deterministic_snapshot_from_serialized_deltas) {
    const auto serialized = serialize_terrain_deltas(seam_air_deltas());
    const TerrainSnapshot first = build(deserialize_terrain_deltas(serialized));
    const TerrainSnapshot second = build(deserialize_terrain_deltas(serialized));
    VWB_EXPECT_EQ(first.cells(), second.cells());
    VWB_EXPECT_EQ(first.blockers(), second.blockers());
    VWB_EXPECT_EQ(first.canonical_bytes(), second.canonical_bytes());
    VWB_EXPECT(first.digest() == second.digest());
}

VWB_TEST(terrain_source_rejects_wrong_world_stale_owner_cancellation_and_source) {
    const RequestAuthority requested = authority();
    TerrainSourceRequest request = n2_terrain_source_request(requested, "n2:authority");
    for (const std::pair<RequestAuthority, AuthorityDecision> permutation : std::array<std::pair<RequestAuthority, AuthorityDecision>, 4>{{
             {authority(7, 11, 13), AuthorityDecision::accept},
             {authority(8, 11, 13), AuthorityDecision::stale_owner},
             {authority(7, 12, 13), AuthorityDecision::cancelled},
             {authority(7, 11, 14), AuthorityDecision::stale_source}}}) {
        if (permutation.second == AuthorityDecision::accept) {
            VWB_EXPECT_EQ(33915U, build_terrain_snapshot(request, permutation.first).cells().size());
        } else {
            try {
                (void)build_terrain_snapshot(request, permutation.first);
                VWB_EXPECT(false);
            } catch (const TerrainSourceRejected &error) {
                VWB_EXPECT_EQ(permutation.second, error.decision());
            }
        }
    }
    RequestAuthority wrong_world = requested;
    wrong_world.world_digest[0] ^= 0xffU;
    try {
        (void)build_terrain_snapshot(request, wrong_world);
        VWB_EXPECT(false);
    } catch (const TerrainSourceRejected &error) {
        VWB_EXPECT_EQ(AuthorityDecision::wrong_world, error.decision());
    }
}

VWB_TEST(delta_and_source_reject_malformed_nonfinite_duplicate_overflow_and_incomplete_data) {
    auto invalid = seam_air_deltas();
    invalid[0].state.density = std::numeric_limits<double>::quiet_NaN();
    VWB_EXPECT_THROW(std::invalid_argument, serialize_terrain_deltas(invalid));
    invalid = seam_air_deltas();
    invalid[1].coordinate = invalid[0].coordinate;
    VWB_EXPECT_THROW(std::invalid_argument, serialize_terrain_deltas(invalid));
    invalid = seam_air_deltas();
    invalid[3].id = invalid[0].id;
    VWB_EXPECT_THROW(std::invalid_argument, serialize_terrain_deltas(invalid));
    auto truncated = serialize_terrain_deltas(seam_air_deltas());
    truncated.pop_back();
    VWB_EXPECT_THROW(std::invalid_argument, deserialize_terrain_deltas(truncated));
    auto trailing = serialize_terrain_deltas(seam_air_deltas());
    trailing.push_back(0);
    VWB_EXPECT_THROW(std::invalid_argument, deserialize_terrain_deltas(trailing));

    const RequestAuthority current = authority();
    auto request = n2_terrain_source_request(current, "n2:malformed");
    request.seed_text = "other";
    VWB_EXPECT_THROW(std::invalid_argument, build_terrain_snapshot(request, current));
    request = n2_terrain_source_request(current, "n2:malformed");
    request.sample_region.maximum_exclusive.x = -13;
    VWB_EXPECT_THROW(std::invalid_argument, build_terrain_snapshot(request, current));
    request = n2_terrain_source_request(current, "n2:malformed");
    request.blockers.clear();
    VWB_EXPECT_THROW(std::invalid_argument, build_terrain_snapshot(request, current));

    TerrainSnapshotDescriptor descriptor{current, "n2:incomplete", {{0, 0, 0}, {1, 1, 1}}, 1};
    VWB_EXPECT_THROW(std::invalid_argument, TerrainSnapshot::create(descriptor, {}));
    TerrainCell cell{{0, 0, 0}, std::numeric_limits<double>::infinity(), 0.0, true, TerrainMaterialId::stone,
        TerrainBiomeId::plains, TerrainBiomeId::plains, TerrainFluidId::none,
        TerrainProvenanceKind::generated, "generator:test", 1};
    VWB_EXPECT_THROW(std::invalid_argument, TerrainSnapshot::create(descriptor, {cell}));
    descriptor.sample_region = {{std::numeric_limits<std::int32_t>::min(), 0, 0},
        {std::numeric_limits<std::int32_t>::max(), std::numeric_limits<std::int32_t>::max(),
            std::numeric_limits<std::int32_t>::max()}};
    VWB_EXPECT_THROW(std::overflow_error, TerrainSnapshot::create(descriptor, {}));
}

VWB_TEST(delta_validation_rejects_every_invalid_typed_state) {
    TerrainDelta delta = seam_air_deltas().front();
    delta.id.clear();
    VWB_EXPECT_THROW(std::invalid_argument, serialize_terrain_deltas({delta}));
    delta = seam_air_deltas().front();
    delta.id = std::string("bad\0id", 6);
    VWB_EXPECT_THROW(std::invalid_argument, serialize_terrain_deltas({delta}));
    delta = seam_air_deltas().front();
    delta.revision = 0;
    VWB_EXPECT_THROW(std::invalid_argument, serialize_terrain_deltas({delta}));
    delta = seam_air_deltas().front();
    delta.state.solid = true;
    VWB_EXPECT_THROW(std::invalid_argument, serialize_terrain_deltas({delta}));
    delta = seam_air_deltas().front();
    delta.state.material = static_cast<TerrainMaterialId>(255U);
    VWB_EXPECT_THROW(std::invalid_argument, serialize_terrain_deltas({delta}));
    delta = seam_air_deltas().front();
    delta.state.resolved_biome = static_cast<TerrainBiomeId>(255U);
    VWB_EXPECT_THROW(std::invalid_argument, serialize_terrain_deltas({delta}));
    delta = seam_air_deltas().front();
    delta.state.fluid = static_cast<TerrainFluidId>(255U);
    VWB_EXPECT_THROW(std::invalid_argument, serialize_terrain_deltas({delta}));
    delta = seam_air_deltas().front();
    delta.state.material = TerrainMaterialId::stone;
    VWB_EXPECT_THROW(std::invalid_argument, serialize_terrain_deltas({delta}));
    delta = seam_air_deltas().front();
    delta.state = {1.0, true, TerrainMaterialId::air, TerrainBiomeId::plains, TerrainFluidId::none};
    VWB_EXPECT_THROW(std::invalid_argument, serialize_terrain_deltas({delta}));
    delta = seam_air_deltas().front();
    delta.state = {-1.0, false, TerrainMaterialId::air, TerrainBiomeId::underground_air, TerrainFluidId::water};
    VWB_EXPECT_THROW(std::invalid_argument, serialize_terrain_deltas({delta}));
    delta = seam_air_deltas().front();
    delta.state = {-1.0, false, TerrainMaterialId::water, TerrainBiomeId::ocean, TerrainFluidId::lava};
    VWB_EXPECT_THROW(std::invalid_argument, serialize_terrain_deltas({delta}));

    delta = seam_air_deltas().front();
    delta.state = {1.0, true, TerrainMaterialId::stone, TerrainBiomeId::underground, TerrainFluidId::none};
    VWB_EXPECT(!serialize_terrain_deltas({delta}).empty());
    delta.state = {-1.0, false, TerrainMaterialId::water, TerrainBiomeId::ocean, TerrainFluidId::water};
    VWB_EXPECT(!serialize_terrain_deltas({delta}).empty());
    delta.state = {-1.0, false, TerrainMaterialId::lava, TerrainBiomeId::underground, TerrainFluidId::lava};
    const auto lava_bytes = serialize_terrain_deltas({delta});
    const auto lava_round_trip = deserialize_terrain_deltas(lava_bytes);
    VWB_EXPECT_EQ(1U, lava_round_trip.size());
    VWB_EXPECT_EQ(TerrainMaterialId::lava, lava_round_trip.front().state.material);
    VWB_EXPECT_EQ(TerrainFluidId::lava, lava_round_trip.front().state.fluid);
}

VWB_TEST(delta_deserialization_rejects_bad_envelopes_and_noncanonical_order) {
    auto bytes = serialize_terrain_deltas({seam_air_deltas().front()});
    bytes[0] = 'X';
    VWB_EXPECT_THROW(std::invalid_argument, deserialize_terrain_deltas(bytes));

    bytes = serialize_terrain_deltas({seam_air_deltas().front()});
    bytes[4] = 2U;
    VWB_EXPECT_THROW(std::invalid_argument, deserialize_terrain_deltas(bytes));

    bytes.assign({'V', 'T', 'D', 'L'});
    append_u32(bytes, 1U);
    append_u32(bytes, 1000001U);
    VWB_EXPECT_THROW(std::invalid_argument, deserialize_terrain_deltas(bytes));

    const TerrainDelta valid = seam_air_deltas().front();
    bytes = serialize_terrain_deltas({valid});
    const std::size_t bool_offset = 44U + valid.id.size();
    VWB_EXPECT(bool_offset < bytes.size());
    bytes[bool_offset] = 2U;
    VWB_EXPECT_THROW(std::invalid_argument, deserialize_terrain_deltas(bytes));

    const auto deltas = seam_air_deltas();
    bytes = noncanonical_delta_bytes({deltas[1], deltas[0]});
    VWB_EXPECT_THROW(std::invalid_argument, deserialize_terrain_deltas(bytes));

    VWB_EXPECT_THROW(std::invalid_argument, deserialize_terrain_deltas({}));
}

VWB_TEST(delta_value_equality_and_source_rejection_messages_are_covered) {
    const TerrainDelta first = seam_air_deltas().front();
    TerrainDelta second = first;
    VWB_EXPECT(first.state == second.state);
    VWB_EXPECT(first == second);
    for (unsigned field = 0; field < 5U; ++field) {
        second = first;
        if (field == 0U) second.state.density -= 1.0;
        if (field == 1U) second.state.solid = !second.state.solid;
        if (field == 2U) second.state.material = TerrainMaterialId::water;
        if (field == 3U) second.state.resolved_biome = TerrainBiomeId::plains;
        if (field == 4U) second.state.fluid = TerrainFluidId::water;
        VWB_EXPECT(!(first.state == second.state));
    }
    for (unsigned field = 0; field < 4U; ++field) {
        second = first;
        if (field == 0U) second.id += ":other";
        if (field == 1U) ++second.revision;
        if (field == 2U) ++second.coordinate.x;
        if (field == 3U) second.state.fluid = TerrainFluidId::water;
        VWB_EXPECT(!(first == second));
    }

    const TerrainSourceRejected accepted(AuthorityDecision::accept);
    VWB_EXPECT_EQ(AuthorityDecision::accept, accepted.decision());
    VWB_EXPECT(std::string(accepted.what()).find("accept") != std::string::npos);
    const TerrainSourceRejected unknown(static_cast<AuthorityDecision>(255U));
    VWB_EXPECT(std::string(unknown.what()).find("unknown") != std::string::npos);
}

VWB_TEST(snapshot_validation_rejects_invalid_descriptor_cells_and_blockers) {
    TerrainSnapshotDescriptor descriptor = one_cell_descriptor();
    TerrainCell cell = valid_cell();

    descriptor.schema = 2U;
    VWB_EXPECT_THROW(std::invalid_argument, TerrainSnapshot::create(descriptor, {cell}));
    descriptor = one_cell_descriptor();
    descriptor.authority.world_digest = {};
    VWB_EXPECT_THROW(std::invalid_argument, TerrainSnapshot::create(descriptor, {cell}));
    descriptor = one_cell_descriptor();
    descriptor.authority.owner.value = 0;
    VWB_EXPECT_THROW(std::invalid_argument, TerrainSnapshot::create(descriptor, {cell}));
    descriptor = one_cell_descriptor();
    descriptor.authority.cancellation.value = 0;
    VWB_EXPECT_THROW(std::invalid_argument, TerrainSnapshot::create(descriptor, {cell}));
    descriptor = one_cell_descriptor();
    descriptor.authority.source_revision.value = 0;
    VWB_EXPECT_THROW(std::invalid_argument, TerrainSnapshot::create(descriptor, {cell}));
    descriptor = one_cell_descriptor();
    descriptor.transaction_id.clear();
    VWB_EXPECT_THROW(std::invalid_argument, TerrainSnapshot::create(descriptor, {cell}));
    descriptor = one_cell_descriptor();
    descriptor.transaction_id = std::string("bad\0transaction", 15);
    VWB_EXPECT_THROW(std::invalid_argument, TerrainSnapshot::create(descriptor, {cell}));
    descriptor = one_cell_descriptor();
    descriptor.sample_region.maximum_exclusive.x = 0;
    VWB_EXPECT_THROW(std::invalid_argument, TerrainSnapshot::create(descriptor, {cell}));
    descriptor = one_cell_descriptor();
    descriptor.sample_region.maximum_exclusive.y = 0;
    VWB_EXPECT_THROW(std::invalid_argument, TerrainSnapshot::create(descriptor, {cell}));
    descriptor = one_cell_descriptor();
    descriptor.sample_region.maximum_exclusive.z = 0;
    VWB_EXPECT_THROW(std::invalid_argument, TerrainSnapshot::create(descriptor, {cell}));

    descriptor = one_cell_descriptor();
    cell.coordinate.x = 1;
    VWB_EXPECT_THROW(std::invalid_argument, TerrainSnapshot::create(descriptor, {cell}));
    cell = valid_cell();
    cell.surface_y = std::numeric_limits<double>::quiet_NaN();
    VWB_EXPECT_THROW(std::invalid_argument, TerrainSnapshot::create(descriptor, {cell}));
    cell = valid_cell();
    cell.solid = false;
    VWB_EXPECT_THROW(std::invalid_argument, TerrainSnapshot::create(descriptor, {cell}));
    cell = valid_cell();
    cell.material = static_cast<TerrainMaterialId>(255U);
    VWB_EXPECT_THROW(std::invalid_argument, TerrainSnapshot::create(descriptor, {cell}));
    cell = valid_cell();
    cell.surface_biome = static_cast<TerrainBiomeId>(255U);
    VWB_EXPECT_THROW(std::invalid_argument, TerrainSnapshot::create(descriptor, {cell}));
    cell = valid_cell();
    cell.resolved_biome = static_cast<TerrainBiomeId>(255U);
    VWB_EXPECT_THROW(std::invalid_argument, TerrainSnapshot::create(descriptor, {cell}));
    cell = valid_cell();
    cell.fluid = static_cast<TerrainFluidId>(255U);
    VWB_EXPECT_THROW(std::invalid_argument, TerrainSnapshot::create(descriptor, {cell}));
    cell = valid_cell();
    cell.provenance = static_cast<TerrainProvenanceKind>(255U);
    VWB_EXPECT_THROW(std::invalid_argument, TerrainSnapshot::create(descriptor, {cell}));
    cell = valid_cell();
    cell.provenance_id.clear();
    VWB_EXPECT_THROW(std::invalid_argument, TerrainSnapshot::create(descriptor, {cell}));
    cell = valid_cell();
    cell.provenance_id = std::string("bad\0source", 10);
    VWB_EXPECT_THROW(std::invalid_argument, TerrainSnapshot::create(descriptor, {cell}));
    cell = valid_cell();
    cell.provenance_revision = 0;
    VWB_EXPECT_THROW(std::invalid_argument, TerrainSnapshot::create(descriptor, {cell}));
    cell = valid_cell();
    cell.density = -1.0; cell.solid = false;
    VWB_EXPECT_THROW(std::invalid_argument, TerrainSnapshot::create(descriptor, {cell}));
    cell = valid_cell();
    cell.material = TerrainMaterialId::air;
    VWB_EXPECT_THROW(std::invalid_argument, TerrainSnapshot::create(descriptor, {cell}));
    cell = valid_cell();
    cell.fluid = TerrainFluidId::water;
    VWB_EXPECT_THROW(std::invalid_argument, TerrainSnapshot::create(descriptor, {cell}));
    cell = valid_cell();
    cell.density = -1.0; cell.solid = false;
    cell.material = TerrainMaterialId::water;
    cell.fluid = TerrainFluidId::lava;
    VWB_EXPECT_THROW(std::invalid_argument, TerrainSnapshot::create(descriptor, {cell}));

    const DeclaredFeatureBlocker valid{"b", {0.0, 0.0, 0.0}, {1.0, 1.0, 1.0}, "fixture", "blocker"};
    DeclaredFeatureBlocker invalid = valid;
    invalid.stable_id.clear();
    VWB_EXPECT_THROW(std::invalid_argument, TerrainSnapshot::create(descriptor, {valid_cell()}, {invalid}));
    invalid = valid; invalid.semantic_class.clear();
    VWB_EXPECT_THROW(std::invalid_argument, TerrainSnapshot::create(descriptor, {valid_cell()}, {invalid}));
    invalid = valid; invalid.physical_intent.clear();
    VWB_EXPECT_THROW(std::invalid_argument, TerrainSnapshot::create(descriptor, {valid_cell()}, {invalid}));
    invalid = valid; invalid.center.x = std::numeric_limits<double>::infinity();
    VWB_EXPECT_THROW(std::invalid_argument, TerrainSnapshot::create(descriptor, {valid_cell()}, {invalid}));
    invalid = valid; invalid.size.x = 0.0;
    VWB_EXPECT_THROW(std::invalid_argument, TerrainSnapshot::create(descriptor, {valid_cell()}, {invalid}));
    invalid = valid; invalid.size.y = -1.0;
    VWB_EXPECT_THROW(std::invalid_argument, TerrainSnapshot::create(descriptor, {valid_cell()}, {invalid}));
    invalid = valid; invalid.size.z = 0.0;
    VWB_EXPECT_THROW(std::invalid_argument, TerrainSnapshot::create(descriptor, {valid_cell()}, {invalid}));
    VWB_EXPECT_THROW(std::invalid_argument, TerrainSnapshot::create(descriptor, {valid_cell()}, {valid, valid}));
}

VWB_TEST(snapshot_sorts_blockers_and_exposes_digest_hex_and_unknown_names) {
    const DeclaredFeatureBlocker later{"z", {0.0, 0.0, 0.0}, {1.0, 1.0, 1.0}, "fixture", "blocker"};
    const DeclaredFeatureBlocker earlier{"a", {2.0, 0.0, 0.0}, {1.0, 1.0, 1.0}, "fixture", "blocker"};
    const TerrainSnapshot snapshot = TerrainSnapshot::create(one_cell_descriptor(), {valid_cell()}, {later, earlier});
    VWB_EXPECT_EQ(std::string("a"), snapshot.blockers().front().stable_id);
    VWB_EXPECT_EQ(std::string("z"), snapshot.blockers().back().stable_id);
    VWB_EXPECT_EQ(64U, snapshot.digest_hex().size());
    VWB_EXPECT_EQ(std::string("unknown"), std::string(terrain_material_name(static_cast<TerrainMaterialId>(255U))));
    VWB_EXPECT_EQ(std::string("unknown"), std::string(terrain_biome_name(static_cast<TerrainBiomeId>(255U))));

    TerrainCell water = valid_cell();
    water.density = -1.0;
    water.solid = false;
    water.material = TerrainMaterialId::water;
    water.resolved_biome = TerrainBiomeId::ocean;
    water.fluid = TerrainFluidId::water;
    VWB_EXPECT_EQ(TerrainMaterialId::water,
        TerrainSnapshot::create(one_cell_descriptor(), {water}).at_index(0).material);

    TerrainCell lava = valid_cell();
    lava.density = -1.0;
    lava.solid = false;
    lava.material = TerrainMaterialId::lava;
    lava.resolved_biome = TerrainBiomeId::underground;
    lava.fluid = TerrainFluidId::lava;
    VWB_EXPECT_EQ(TerrainMaterialId::lava,
        TerrainSnapshot::create(one_cell_descriptor(), {lava}).at_index(0).material);
}

VWB_TEST(snapshot_value_equality_and_each_contains_boundary_are_explicit) {
    const Vec3d vector{1.0, 2.0, 3.0};
    VWB_EXPECT(vector == vector);
    VWB_EXPECT(!(vector == Vec3d{0.0, 2.0, 3.0}));
    VWB_EXPECT(!(vector == Vec3d{1.0, 0.0, 3.0}));
    VWB_EXPECT(!(vector == Vec3d{1.0, 2.0, 0.0}));

    const TerrainCell base = valid_cell();
    for (unsigned field = 0; field < 11U; ++field) {
        TerrainCell changed = base;
        if (field == 0U) ++changed.coordinate.x;
        if (field == 1U) changed.density += 1.0;
        if (field == 2U) changed.surface_y += 1.0;
        if (field == 3U) changed.solid = false;
        if (field == 4U) changed.material = TerrainMaterialId::dirt;
        if (field == 5U) changed.surface_biome = TerrainBiomeId::forest;
        if (field == 6U) changed.resolved_biome = TerrainBiomeId::forest;
        if (field == 7U) changed.fluid = TerrainFluidId::water;
        if (field == 8U) changed.provenance = TerrainProvenanceKind::typed_delta;
        if (field == 9U) changed.provenance_id += ":other";
        if (field == 10U) ++changed.provenance_revision;
        VWB_EXPECT(!(base == changed));
    }

    const DeclaredFeatureBlocker blocker{"b", {0.0, 1.0, 2.0}, {1.0, 2.0, 3.0}, "fixture", "blocker"};
    for (unsigned field = 0; field < 5U; ++field) {
        DeclaredFeatureBlocker changed = blocker;
        if (field == 0U) changed.stable_id += ":other";
        if (field == 1U) changed.center.x += 1.0;
        if (field == 2U) changed.size.x += 1.0;
        if (field == 3U) changed.semantic_class += ":other";
        if (field == 4U) changed.physical_intent += ":other";
        VWB_EXPECT(!(blocker == changed));
    }

    const TerrainSnapshot snapshot = build();
    VWB_EXPECT(snapshot.contains({-20, 0, 0}));
    for (const CellCoord coordinate : std::array<CellCoord, 6>{{
             {-50, 0, 0}, {-14, 0, 0}, {-20, -18, 0}, {-20, 34, 0}, {-20, 0, -18}, {-20, 0, 2}}}) {
        VWB_EXPECT(!snapshot.contains(coordinate));
    }
}

VWB_TEST(source_request_rejects_duplicate_and_out_of_region_deltas) {
    const RequestAuthority current = authority();
    auto deltas = seam_air_deltas();
    deltas[1].id = deltas[0].id;
    auto request = n2_terrain_source_request(current, "n2:invalid-deltas", deltas);
    VWB_EXPECT_THROW(std::invalid_argument, build_terrain_snapshot(request, current));

    deltas = seam_air_deltas();
    deltas[1].coordinate = deltas[0].coordinate;
    request = n2_terrain_source_request(current, "n2:invalid-deltas", deltas);
    VWB_EXPECT_THROW(std::invalid_argument, build_terrain_snapshot(request, current));

    for (const CellCoord coordinate : std::array<CellCoord, 6>{{
             {-50, 0, 0}, {-14, 0, 0}, {-20, -18, 0}, {-20, 34, 0}, {-20, 0, -18}, {-20, 0, 2}}}) {
        TerrainDelta delta = seam_air_deltas().front();
        delta.coordinate = coordinate;
        request = n2_terrain_source_request(current, "n2:outside", {delta});
        VWB_EXPECT_THROW(std::invalid_argument, build_terrain_snapshot(request, current));
    }

    request = n2_terrain_source_request(current, "n2:bad-blocker");
    request.blockers.front().size.x = 2.0;
    VWB_EXPECT_THROW(std::invalid_argument, build_terrain_snapshot(request, current));
    request = n2_terrain_source_request(current, "n2:bad-seed");
    request.seed_code_points.back() = '3';
    VWB_EXPECT_THROW(std::invalid_argument, build_terrain_snapshot(request, current));

    for (unsigned field = 0; field < 6U; ++field) {
        request = n2_terrain_source_request(current, "n2:bad-region");
        if (field == 0U) --request.sample_region.minimum.x;
        if (field == 1U) --request.sample_region.minimum.y;
        if (field == 2U) --request.sample_region.minimum.z;
        if (field == 3U) ++request.sample_region.maximum_exclusive.x;
        if (field == 4U) ++request.sample_region.maximum_exclusive.y;
        if (field == 5U) ++request.sample_region.maximum_exclusive.z;
        VWB_EXPECT_THROW(std::invalid_argument, build_terrain_snapshot(request, current));
    }
}

VWB_TEST(snapshot_lookup_and_canonicalization_are_strict) {
    const TerrainSnapshot snapshot = build();
    VWB_EXPECT(snapshot.contains({-49, -17, -17}));
    VWB_EXPECT(!snapshot.contains({-14, -17, -17}));
    VWB_EXPECT_EQ(0U, snapshot.index_of({-49, -17, -17}));
    VWB_EXPECT_EQ(snapshot.at({-32, 12, -5}), snapshot.at_index(snapshot.index_of({-32, 12, -5})));
    VWB_EXPECT_THROW(std::out_of_range, snapshot.at({-14, 0, 0}));
    VWB_EXPECT_THROW(std::out_of_range, snapshot.at_index(snapshot.cells().size()));
}

} // namespace voxel::world_backend::tests
