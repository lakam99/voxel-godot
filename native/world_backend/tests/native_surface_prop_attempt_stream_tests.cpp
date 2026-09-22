#include "test_harness.hpp"

#include "../core/native_surface_prop_attempt_stream.hpp"

#include <array>
#include <cstdint>
#include <limits>
#include <string>
#include <utility>

using namespace voxel::world_backend;

namespace {

AdmittedTerrainSeed raw_seed(const std::string &value) {
    return admit_raw_terrain_seed(value);
}

} // namespace

VWB_TEST(native_surface_prop_attempt_stream_matches_godot_461_all_ascii_chunk_coordinates) {
    const NativeSurfacePropAttemptStream stream = NativeSurfacePropAttemptStream::create(raw_seed("atlas-1492"), 0, 0);
    const std::array<std::array<std::int32_t, 2U>, 28U> coordinates = {{
        {{16, 17}}, {{14, 9}}, {{19, 7}}, {{10, 7}}, {{24, 10}}, {{12, 17}}, {{21, 2}},
        {{14, 10}}, {{22, 22}}, {{3, 22}}, {{7, 16}}, {{14, 20}}, {{20, 6}}, {{5, 8}},
        {{25, 13}}, {{16, 19}}, {{11, 24}}, {{20, 3}}, {{13, 4}}, {{10, 14}}, {{8, 4}},
        {{12, 9}}, {{23, 6}}, {{25, 13}}, {{20, 5}}, {{3, 26}}, {{13, 12}}, {{6, 3}},
    }};
    VWB_EXPECT_EQ(3123596935U, stream.rng_seed());
    VWB_EXPECT_EQ(9985430908601423557ULL, stream.final_rng_state());
    for (std::size_t index = 0U; index < coordinates.size(); ++index) {
        const NativeSurfacePropAttempt &attempt = stream.attempts()[index];
        VWB_EXPECT_EQ(index, static_cast<std::size_t>(attempt.ordinal));
        VWB_EXPECT_EQ(coordinates[index][0], attempt.cell_x);
        VWB_EXPECT_EQ(coordinates[index][1], attempt.cell_z);
        VWB_EXPECT_EQ("atlas-1492:" + std::to_string(attempt.cell_x) + ","
            + std::to_string(attempt.cell_z) + ":" + std::to_string(index), attempt.durable_id);
    }
}

VWB_TEST(native_surface_prop_attempt_stream_uses_unicode_scalars_and_negative_chunks) {
    const std::string seed = u8"世界🌲";
    const NativeSurfacePropAttemptStream stream = NativeSurfacePropAttemptStream::create(raw_seed(seed), -3, 5);
    VWB_EXPECT_EQ(560539456U, stream.rng_seed());
    VWB_EXPECT_EQ(9602837116197045674ULL, stream.final_rng_state());
    VWB_EXPECT_EQ(-72, stream.attempts()[0].cell_x);
    VWB_EXPECT_EQ(143, stream.attempts()[0].cell_z);
    VWB_EXPECT_EQ(seed + ":-72,143:0", stream.attempts()[0].durable_id);
    VWB_EXPECT_EQ(-77, stream.attempts()[27].cell_x);
    VWB_EXPECT_EQ(148, stream.attempts()[27].cell_z);
    VWB_EXPECT_EQ(seed + ":-77,148:27", stream.attempts()[27].durable_id);
}

VWB_TEST(native_surface_prop_attempt_stream_is_unfiltered_and_rejects_invalid_seed_or_coordinate_domain) {
    const NativeSurfacePropAttemptStream first = NativeSurfacePropAttemptStream::create(raw_seed("atlas-1492"), 0, 0);
    const NativeSurfacePropAttemptStream second = NativeSurfacePropAttemptStream::create(raw_seed("atlas-1492"), 0, 0);
    VWB_EXPECT_EQ(first.rng_seed(), second.rng_seed());
    VWB_EXPECT_EQ(first.final_rng_state(), second.final_rng_state());
    VWB_EXPECT(first.attempts()[0] == second.attempts()[0]);
    VWB_EXPECT(!(first.attempts()[0] == first.attempts()[1]));
    NativeSurfacePropAttempt changed = first.attempts()[0];
    changed.cell_x += 1;
    VWB_EXPECT(!(first.attempts()[0] == changed));
    changed = first.attempts()[0];
    changed.cell_z += 1;
    VWB_EXPECT(!(first.attempts()[0] == changed));
    changed = first.attempts()[0];
    changed.durable_id += ":different";
    VWB_EXPECT(!(first.attempts()[0] == changed));

    AdmittedTerrainSeed rejected = raw_seed("seed");
    rejected.admitted = false;
    VWB_EXPECT_THROW(NativeSurfacePropAttemptStreamRejected,
        NativeSurfacePropAttemptStream::create(rejected, 0, 0));
    AdmittedTerrainSeed invalid_scalar = raw_seed("seed");
    invalid_scalar.code_points = {0xd800U};
    VWB_EXPECT_THROW(NativeSurfacePropAttemptStreamRejected,
        NativeSurfacePropAttemptStream::create(invalid_scalar, 0, 0));
    AdmittedTerrainSeed mismatched_scalar = raw_seed("seed");
    mismatched_scalar.code_points = {'o', 't', 'h', 'e', 'r'};
    VWB_EXPECT_THROW(NativeSurfacePropAttemptStreamRejected,
        NativeSurfacePropAttemptStream::create(mismatched_scalar, 0, 0));
    VWB_EXPECT_THROW(NativeSurfacePropAttemptStreamRejected,
        NativeSurfacePropAttemptStream::create(raw_seed("seed"), std::numeric_limits<std::int32_t>::max(), 0));
    VWB_EXPECT_THROW(NativeSurfacePropAttemptStreamRejected,
        NativeSurfacePropAttemptStream::create(raw_seed("seed"), std::numeric_limits<std::int32_t>::min(), 0));
}
