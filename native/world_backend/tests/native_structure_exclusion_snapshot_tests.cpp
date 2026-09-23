#include "../core/native_structure_exclusion_snapshot.hpp"
#include "test_harness.hpp"

#include <algorithm>
#include <array>
#include <cstdint>
#include <utility>
#include <vector>

namespace voxel::world_backend::tests {
namespace {

Sha256Digest world() {
    Sha256Digest digest{};
    digest[0] = 0x42;
    return digest;
}

std::vector<StructureExclusionBoundsAdmission> admissions() {
    return {{-2072, -2072, true}, {-28, -28, true}, {0, 0, true},
            {28, 28, true}, {2044, 2044, true}};
}

CitadelExclusionSource source(std::int32_t rx, std::int32_t rz,
                              CitadelSourceStatus status, StructureExclusionRect rect = {}) {
    CitadelExclusionSource result;
    result.region_x = rx;
    result.region_z = rz;
    result.status = status;
    if (status == CitadelSourceStatus::ready || status == CitadelSourceStatus::prepared) {
        result.source_key = "oracle-citadel";
        result.source_signature = "oracle-v1";
        result.admission_generation = 7;
        result.reservation = rect;
    } else {
        result.reason = status == CitadelSourceStatus::absent ? "" : "not_ready";
        if (status == CitadelSourceStatus::absent) result.source_key = "decided-absent";
    }
    return result;
}

NativeStructureExclusionSnapshot oracle_snapshot(CitadelSourceStatus central = CitadelSourceStatus::ready) {
    return NativeStructureExclusionSnapshot::create(
        world(), 1,
        {{"natural:-4,-4:3x3", {-4, -4, -2, -2}}},
        {{"terrain:9,9:3x3", {8, 8, 12, 12}}},
        {source(0, 0, central, {15, 15, 18, 18}),
         source(1, 1, CitadelSourceStatus::prepared, {2048, 2048, 2050, 2050}),
         source(-2, -2, CitadelSourceStatus::ready, {-2049, -2049, -2048, -2048}),
         source(-1, -1, CitadelSourceStatus::absent),
         source(1, 0, CitadelSourceStatus::absent),
         source(0, 1, CitadelSourceStatus::absent)}, admissions());
}

void expect_bad_source(const CitadelExclusionSource &value) {
    VWB_EXPECT_THROW(NativeStructureExclusionRejected,
        NativeStructureExclusionSnapshot::create(world(), 1, {}, {}, {value}, admissions()));
}

} // namespace

VWB_TEST(structure_exclusion_matches_28_ordered_godot_oracle_decisions) {
    constexpr std::array<bool, 28> expected = {
        false, true, true, true, false, false, false, false, false, false,
        false, false, false, true, true, true, true, true, false, false,
        true, true, true, false, false, false, true, true};
    const auto snapshot = oracle_snapshot();
    for (std::size_t i = 0; i < expected.size(); ++i) {
        const std::int32_t cell = i < 24 ? static_cast<std::int32_t>(i) - 5
                                        : (i == 24 ? 2046 : i == 25 ? 2047 : i == 26 ? 2048 : -2049);
        const auto decision = snapshot.query(cell, cell);
        VWB_EXPECT(decision.complete);
        VWB_EXPECT_EQ(expected[i], decision.blocked);
    }
    VWB_EXPECT_EQ(StructureExclusionKind::natural, snapshot.query(-4, -4).kind);
    VWB_EXPECT_EQ(StructureExclusionKind::terrain, snapshot.query(8, 8).kind);
    VWB_EXPECT_EQ(StructureExclusionKind::citadel, snapshot.query(15, 15).kind);
    VWB_EXPECT(!snapshot.query(18, 18).blocked);
    VWB_EXPECT(!snapshot.query(-2048, -2048).blocked);
    VWB_EXPECT(!snapshot.query(2047, 2047).blocked);
    VWB_EXPECT_EQ(world(), snapshot.world_digest());
    VWB_EXPECT_EQ(std::size_t{1}, snapshot.natural().size());
    VWB_EXPECT_EQ(std::size_t{1}, snapshot.terrain().size());
    VWB_EXPECT_EQ(std::size_t{6}, snapshot.citadels().size());
    VWB_EXPECT_EQ(std::size_t{5}, snapshot.admitted_bounds().size());
    VWB_EXPECT(snapshot.covers_decided_regions(0, 0, 27, 27));
    VWB_EXPECT(snapshot.covers_decided_regions(2047, 2047, 2048, 2048));
    VWB_EXPECT(!snapshot.covers_decided_regions(-1, -1, 0, 0));
    VWB_EXPECT(!snapshot.covers_decided_regions(1, 0, 0, 0));
    VWB_EXPECT(!snapshot.covers_decided_regions(0, 1, 0, 0));
    VWB_EXPECT(!snapshot.query(-3, 0).blocked);
    VWB_EXPECT(!snapshot.query(15, 18).blocked);
    VWB_EXPECT(!snapshot.query(18, 15).blocked);
    for (const auto [x, z] : std::array<std::pair<std::int32_t, std::int32_t>, 8>{
             {{-5, -3}, {-1, -3}, {-3, -5}, {-3, -1},
              {14, 16}, {18, 16}, {16, 14}, {16, 18}}}) {
        VWB_EXPECT(!snapshot.query(x, z).blocked);
    }
}

VWB_TEST(structure_exclusion_canonical_sort_and_physical_residency_equivalence) {
    auto natural = std::vector<StructureExclusionRecord>{{"b", {50, 50, 51, 51}},
                                                         {"a", {40, 40, 41, 41}}};
    auto citadels = std::vector<CitadelExclusionSource>{
        source(1, 1, CitadelSourceStatus::ready, {2048, 2048, 2050, 2050}),
        source(0, 0, CitadelSourceStatus::ready, {15, 15, 18, 18})};
    const auto first = NativeStructureExclusionSnapshot::create(world(), 1, natural, {}, citadels, admissions());
    std::reverse(natural.begin(), natural.end());
    std::reverse(citadels.begin(), citadels.end());
    citadels[1].status = CitadelSourceStatus::prepared;
    const auto second = NativeStructureExclusionSnapshot::create(world(), 1, natural, {}, citadels, admissions());
    VWB_EXPECT_EQ(first.content_digest(), second.content_digest());
    VWB_EXPECT_EQ(std::string("a"), second.natural().front().id);
    VWB_EXPECT_EQ(0, second.citadels().front().region_x);
    natural.front().bounds.max_x = 42;
    VWB_EXPECT(first.content_digest() != NativeStructureExclusionSnapshot::create(world(), 1, natural, {}, citadels, admissions()).content_digest());
    citadels[1].source_signature = "oracle-v2";
    VWB_EXPECT(second.content_digest() != NativeStructureExclusionSnapshot::create(world(), 1, {{"b", {50, 50, 51, 51}}, {"a", {40, 40, 41, 41}}}, {}, citadels, admissions()).content_digest());
    const auto reset = NativeStructureExclusionSnapshot::create(world(), 2,
        {{"b", {50, 50, 51, 51}}, {"a", {40, 40, 41, 41}}}, {},
        {source(0, 0, CitadelSourceStatus::ready, {15, 15, 18, 18}),
         source(1, 1, CitadelSourceStatus::ready, {2048, 2048, 2050, 2050})}, admissions());
    VWB_EXPECT_EQ(first.content_digest(), reset.content_digest());
    VWB_EXPECT(first.world_generation() != reset.world_generation());
}

VWB_TEST(structure_exclusion_status_is_explicit_and_not_empty_success) {
    const auto pending = NativeStructureExclusionSnapshot::create(world(), 1, {}, {},
        {source(1, 1, CitadelSourceStatus::pending)}, admissions());
    const auto failed = NativeStructureExclusionSnapshot::create(world(), 1, {}, {},
        {source(1, 1, CitadelSourceStatus::failed)}, admissions());
    const auto absent = NativeStructureExclusionSnapshot::create(world(), 1, {}, {},
        {source(1, 1, CitadelSourceStatus::absent)}, admissions());
    auto unrequested_source = source(1, 1, CitadelSourceStatus::absent);
    unrequested_source.source_key.clear();
    unrequested_source.reason = "source_not_requested";
    const auto unrequested = NativeStructureExclusionSnapshot::create(world(), 1, {}, {},
        {unrequested_source}, admissions());
    const auto uncaptured = NativeStructureExclusionSnapshot::create(world(), 1, {}, {}, {}, admissions());
    VWB_EXPECT(!pending.query(2048, 2048).blocked && !pending.query(2048, 2048).complete);
    VWB_EXPECT(!failed.query(2048, 2048).complete);
    VWB_EXPECT(!pending.covers_decided_regions(2048, 2048, 2048, 2048));
    VWB_EXPECT(!failed.covers_decided_regions(2048, 2048, 2048, 2048));
    VWB_EXPECT(absent.query(2048, 2048).complete && !absent.query(2048, 2048).blocked);
    VWB_EXPECT(!unrequested.query(2048, 2048).complete && !unrequested.query(2048, 2048).blocked);
    VWB_EXPECT(!unrequested.covers_decided_regions(2048, 2048, 2048, 2048));
    VWB_EXPECT(absent.covers_decided_regions(2048, 2048, 2048, 2048));
    VWB_EXPECT_EQ(std::string("source_not_requested"), unrequested.query(2048, 2048).source_id);
    VWB_EXPECT(!uncaptured.query(2048, 2048).complete);
    VWB_EXPECT(pending.content_digest() != failed.content_digest());
    VWB_EXPECT(absent.content_digest() != uncaptured.content_digest());
    auto decided_absent = source(1, 1, CitadelSourceStatus::absent);
    decided_absent.reason.clear();
    decided_absent.source_key = "decided-absent-receipt";
    const auto decided = NativeStructureExclusionSnapshot::create(world(), 1, {}, {},
        {decided_absent}, admissions());
    VWB_EXPECT(decided.query(2048, 2048).complete);
    VWB_EXPECT_EQ(std::string(""), decided.query(2048, 2048).source_id);
    VWB_EXPECT(decided.content_digest() != absent.content_digest());
    const auto priority = NativeStructureExclusionSnapshot::create(world(), 1,
        {{"n", {2048, 2048, 2048, 2048}}}, {}, {source(1, 1, CitadelSourceStatus::pending)}, admissions());
    VWB_EXPECT(priority.query(2048, 2048).blocked && priority.query(2048, 2048).complete);
    VWB_EXPECT(!priority.query(100, 100).complete);
    VWB_EXPECT_EQ(std::string("bounds_not_admitted"), priority.query(100, 100).source_id);
}

VWB_TEST(structure_exclusion_rejects_ambiguous_or_malformed_sources) {
    auto zero = Sha256Digest{};
    VWB_EXPECT_THROW(NativeStructureExclusionRejected,
        NativeStructureExclusionSnapshot::create(zero, 1, {}, {}, {}, admissions()));
    VWB_EXPECT_THROW(NativeStructureExclusionRejected,
        NativeStructureExclusionSnapshot::create(world(), 0, {}, {}, {}, admissions()));
    VWB_EXPECT_THROW(NativeStructureExclusionRejected,
        NativeStructureExclusionSnapshot::create(world(), 1, {{"x", {1, 1, 0, 2}}}, {}, {}, admissions()));
    VWB_EXPECT_THROW(NativeStructureExclusionRejected,
        NativeStructureExclusionSnapshot::create(world(), 1, {{"x", {}}, {"x", {}}}, {}, {}, admissions()));
    VWB_EXPECT_THROW(NativeStructureExclusionRejected,
        NativeStructureExclusionSnapshot::create(world(), 1, {}, {},
            {source(0, 0, CitadelSourceStatus::absent), source(0, 0, CitadelSourceStatus::absent)}, admissions()));
    const auto distinct_region_z = NativeStructureExclusionSnapshot::create(world(), 1, {}, {},
        {source(0, 0, CitadelSourceStatus::absent), source(0, 1, CitadelSourceStatus::absent)}, admissions());
    VWB_EXPECT_EQ(std::size_t{2}, distinct_region_z.citadels().size());
    auto malformed = source(0, 0, CitadelSourceStatus::ready, {1, 1, 1, 2});
    VWB_EXPECT_THROW(NativeStructureExclusionRejected,
        NativeStructureExclusionSnapshot::create(world(), 1, {}, {}, {malformed}, admissions()));
    malformed = source(0, 0, CitadelSourceStatus::pending);
    malformed.source_key = "stale";
    VWB_EXPECT_THROW(NativeStructureExclusionRejected,
        NativeStructureExclusionSnapshot::create(world(), 1, {}, {}, {malformed}, admissions()));
    malformed = source(0, 0, static_cast<CitadelSourceStatus>(255));
    VWB_EXPECT_THROW(NativeStructureExclusionRejected,
        NativeStructureExclusionSnapshot::create(world(), 1, {}, {}, {malformed}, admissions()));
    VWB_EXPECT_THROW(NativeStructureExclusionRejected,
        NativeStructureExclusionSnapshot::create(world(), 1, {}, {}, {}, {}));
    VWB_EXPECT_THROW(NativeStructureExclusionRejected,
        NativeStructureExclusionSnapshot::create(world(), 1, {}, {}, {}, {{0, 0, false}}));
    VWB_EXPECT_THROW(NativeStructureExclusionRejected,
        NativeStructureExclusionSnapshot::create(world(), 1, {}, {}, {}, {{1, 0, true}}));
    VWB_EXPECT_THROW(NativeStructureExclusionRejected,
        NativeStructureExclusionSnapshot::create(world(), 1, {}, {}, {}, {{0, 0, true}, {0, 0, true}}));
    const auto distinct_bounds_z = NativeStructureExclusionSnapshot::create(world(), 1, {}, {}, {},
        {{0, 0, true}, {0, 28, true}});
    VWB_EXPECT_EQ(std::size_t{2}, distinct_bounds_z.admitted_bounds().size());
    VWB_EXPECT_THROW(NativeStructureExclusionRejected,
        NativeStructureExclusionSnapshot::create(world(), 1, {}, {}, {},
            std::vector<StructureExclusionBoundsAdmission>(65537, {0, 0, true})));
}

VWB_TEST(structure_exclusion_rejects_each_invalid_record_and_status_field) {
    const auto invalid_natural = [](StructureExclusionRecord value) {
        VWB_EXPECT_THROW(NativeStructureExclusionRejected,
            NativeStructureExclusionSnapshot::create(world(), 1, {value}, {}, {}, admissions()));
    };
    invalid_natural({"", {0, 0, 1, 1}});
    invalid_natural({std::string(1025, 'x'), {0, 0, 1, 1}});
    invalid_natural({std::string("x\0y", 3), {0, 0, 1, 1}});
    invalid_natural({"x", {0, 2, 1, 1}});
    auto physical = source(0, 0, CitadelSourceStatus::ready, {0, 0, 2, 2});
    physical.reason = "unexpected";
    expect_bad_source(physical);
    physical = source(0, 0, CitadelSourceStatus::ready, {0, 0, 2, 2});
    physical.source_key.clear();
    expect_bad_source(physical);
    physical = source(0, 0, CitadelSourceStatus::ready, {0, 0, 2, 2});
    physical.source_signature.clear();
    expect_bad_source(physical);
    physical = source(0, 0, CitadelSourceStatus::ready, {0, 0, 2, 2});
    physical.admission_generation = 0;
    expect_bad_source(physical);
    physical = source(0, 0, CitadelSourceStatus::ready, {0, 0, 2, 2});
    physical.reservation.max_z = 0;
    expect_bad_source(physical);
    auto absent = source(0, 0, CitadelSourceStatus::absent);
    absent.source_signature = "unexpected";
    expect_bad_source(absent);
    absent = source(0, 0, CitadelSourceStatus::absent);
    absent.admission_generation = 1;
    expect_bad_source(absent);
    absent = source(0, 0, CitadelSourceStatus::absent);
    absent.reservation.min_x = 1;
    expect_bad_source(absent);
    absent = source(0, 0, CitadelSourceStatus::absent);
    absent.reservation.min_z = 1;
    expect_bad_source(absent);
    absent = source(0, 0, CitadelSourceStatus::absent);
    absent.reservation.max_x = 1;
    expect_bad_source(absent);
    absent = source(0, 0, CitadelSourceStatus::absent);
    absent.reservation.max_z = 1;
    expect_bad_source(absent);
    absent = source(0, 0, CitadelSourceStatus::pending);
    absent.reason.clear();
    expect_bad_source(absent);
    absent = source(0, 0, CitadelSourceStatus::failed);
    absent.source_key = "unexpected";
    expect_bad_source(absent);
    absent = source(0, 0, CitadelSourceStatus::absent);
    absent.source_key = std::string(1025, 'x');
    expect_bad_source(absent);
    VWB_EXPECT_THROW(NativeStructureExclusionRejected,
        NativeStructureExclusionSnapshot::create(world(), 1, {}, {}, {}, {{0, 1, true}}));
    VWB_EXPECT_THROW(NativeStructureExclusionRejected,
        NativeStructureExclusionSnapshot::create(world(), 1, {}, {}, {}, {{0, 0, true}, {0, 28, true}, {0, 0, true}}));
}

} // namespace voxel::world_backend::tests
