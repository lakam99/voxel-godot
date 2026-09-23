#include "test_harness.hpp"
#include "../core/native_surface_tree_presence.hpp"

#include <limits>

using namespace voxel::world_backend;

namespace {

Sha256Digest digest(std::uint8_t first) { Sha256Digest d{}; d[0] = first; return d; }

CitadelExclusionSource absent(std::int32_t x, std::int32_t z) {
    CitadelExclusionSource c;
    c.region_x = x; c.region_z = z; c.status = CitadelSourceStatus::absent;
    c.source_key = "world:" + std::to_string(x) + "," + std::to_string(z);
    return c;
}

NativeTreeExclusionHaloCapture halo(StructureExclusionRect bounds,
    std::vector<StructureExclusionRecord> natural = {},
    std::vector<StructureExclusionRecord> terrain = {},
    std::vector<CitadelExclusionSource> citadels = {absent(0,0)}) {
    return NativeTreeExclusionHaloCapture::create(digest(1), 1U, digest(2), bounds,
        std::move(natural), std::move(terrain), std::move(citadels));
}

} // namespace

VWB_TEST(native_tree_halo_rejects_uncaptured_chunk_edge_and_negative_region) {
    const auto local = halo({0,0,27,27});
    VWB_EXPECT_THROW(NativeSurfaceTreePresenceRejected,
        evaluate_native_tree_exclusion_halo(26, 2, 1.0, 5.0, 0.0, 1.35, local));
    const auto expanded = halo({-8,-8,35,35}, {}, {},
        {absent(-1,-1), absent(0,-1), absent(-1,0), absent(0,0)});
    const auto decision = evaluate_native_tree_exclusion_halo(1, 1, 1.0, 5.0, 0.0, 1.35, expanded);
    VWB_EXPECT_EQ(NativeSurfaceTreePresence::present, decision.presence);
    VWB_EXPECT_EQ(1, decision.natural_margin_cells);
    VWB_EXPECT_EQ(4, decision.structure_margin_cells);
    const auto missing_region = halo({-8,-8,35,35}, {}, {}, {absent(0,0)});
    VWB_EXPECT_THROW(NativeSurfaceTreePresenceRejected,
        evaluate_native_tree_exclusion_halo(1, 1, 1.0, 5.0, 0.0, 1.35, missing_region));
    const auto pending = [] {
        auto c = absent(-1,-1); c.status = CitadelSourceStatus::pending;
        c.source_key.clear(); c.reason = "pending"; return c;
    }();
    const auto pending_halo = halo({-8,-8,35,35}, {}, {},
        {pending, absent(0,-1), absent(-1,0), absent(0,0)});
    VWB_EXPECT_THROW(NativeSurfaceTreePresenceRejected,
        evaluate_native_tree_exclusion_halo(1, 1, 1.0, 5.0, 0.0, 1.35, pending_halo));
    auto failed_elsewhere = absent(-1,-1);
    failed_elsewhere.status = CitadelSourceStatus::failed;
    failed_elsewhere.source_key.clear();
    failed_elsewhere.reason = "failed_site_outside_requested_bounds";
    const auto failed_elsewhere_halo = halo({-8,-8,35,35}, {}, {},
        {failed_elsewhere, absent(0,-1), absent(-1,0), absent(0,0)});
    VWB_EXPECT_EQ(NativeSurfaceTreePresence::present,
        evaluate_native_tree_exclusion_halo(1, 1, 1.0, 5.0, 0.0, 1.35, failed_elsewhere_halo).presence);
    auto unrequested = absent(-1,-1);
    unrequested.source_key.clear();
    unrequested.reason = "source_not_requested";
    const auto unrequested_halo = halo({-8,-8,35,35}, {}, {},
        {unrequested, absent(0,-1), absent(-1,0), absent(0,0)});
    VWB_EXPECT_EQ(NativeSurfaceTreePresence::present,
        evaluate_native_tree_exclusion_halo(1, 1, 1.0, 5.0, 0.0, 1.35, unrequested_halo).presence);
    const auto masked_unrequested = halo({-8,-8,35,35},
        {{"blocker", {0,0,3,3}}}, {},
        {unrequested, absent(0,-1), absent(-1,0), absent(0,0)});
    VWB_EXPECT_EQ(NativeSurfaceTreePresence::absent,
        evaluate_native_tree_exclusion_halo(1, 1, 1.0, 5.0, 0.0, 1.35, masked_unrequested).presence);
}

VWB_TEST(native_tree_halo_uses_separate_natural_and_structure_margins) {
    const auto natural_edge = halo({0,0,40,40}, {{"road", {14,10,15,11}}});
    const auto far_natural = evaluate_native_tree_exclusion_halo(10,10,1.0,7.0,0.0,1.35,natural_edge);
    VWB_EXPECT_EQ(NativeSurfaceTreePresence::present, far_natural.presence);
    const auto terrain_edge = halo({0,0,40,40}, {}, {{"building", {14,10,15,11}}});
    const auto blocked = evaluate_native_tree_exclusion_halo(10,10,1.0,7.0,0.0,1.35,terrain_edge);
    VWB_EXPECT_EQ(NativeSurfaceTreePresence::absent, blocked.presence);
    VWB_EXPECT_EQ(StructureExclusionKind::terrain, blocked.blocker_kind);
    VWB_EXPECT_EQ(std::string("building"), blocked.blocker_id);
    const auto near_natural = halo({0,0,40,40}, {{"road", {11,10,12,11}}});
    const auto natural_blocked = evaluate_native_tree_exclusion_halo(10,10,1.0,7.0,0.0,1.35,near_natural);
    VWB_EXPECT_EQ(NativeSurfaceTreePresence::absent, natural_blocked.presence);
    VWB_EXPECT_EQ(StructureExclusionKind::natural, natural_blocked.blocker_kind);
}

VWB_TEST(native_tree_halo_respects_citadel_half_open_reservation_and_seam) {
    auto c = absent(0,0);
    c.status = CitadelSourceStatus::ready; c.source_key = "site";
    c.source_signature = "v1"; c.admission_generation = 1U;
    c.reservation = {15,15,18,18};
    const auto capture = halo({0,0,40,40}, {}, {}, {c});
    const auto hit = evaluate_native_tree_exclusion_halo(10,10,1.0,7.0,0.0,1.35,capture);
    VWB_EXPECT_EQ(NativeSurfaceTreePresence::absent, hit.presence);
    VWB_EXPECT_EQ(StructureExclusionKind::citadel, hit.blocker_kind);
    const auto clear = evaluate_native_tree_exclusion_halo(25,25,1.0,1.0,0.0,1.35,capture);
    VWB_EXPECT_EQ(NativeSurfaceTreePresence::present, clear.presence);
    c.status = CitadelSourceStatus::prepared;
    const auto prepared = halo({0,0,40,40}, {}, {}, {c});
    VWB_EXPECT_EQ(NativeSurfaceTreePresence::absent,
        evaluate_native_tree_exclusion_halo(10,10,1.0,7.0,0.0,1.35,prepared).presence);
    // An overcaptured neighbouring region is not queried by Godot. Its
    // synthetic overlapping reservation must not block this region's tree.
    const std::array<std::pair<std::int32_t,std::int32_t>,4> outside_regions{{
        {-1,0}, {1,0}, {0,-1}, {0,1}
    }};
    for (const auto [rx, rz] : outside_regions) {
        auto outside_region = c;
        outside_region.region_x = rx; outside_region.region_z = rz;
        outside_region.status = CitadelSourceStatus::ready;
        outside_region.source_key = "outside-region";
        outside_region.reservation = {10,10,12,12};
        const auto overcaptured = halo({0,0,40,40}, {}, {}, {absent(0,0), outside_region});
        VWB_EXPECT_EQ(NativeSurfaceTreePresence::present,
            evaluate_native_tree_exclusion_halo(10,10,1.0,1.0,0.0,1.35,overcaptured).presence);
    }
}

VWB_TEST(native_tree_halo_rejects_invalid_capture_and_margin) {
    VWB_EXPECT_THROW(NativeSurfaceTreePresenceRejected,
        NativeTreeExclusionHaloCapture::create({},1U,digest(2),{0,0,1,1},{},{},{absent(0,0)}));
    VWB_EXPECT_THROW(NativeSurfaceTreePresenceRejected,
        NativeTreeExclusionHaloCapture::create(digest(1),0U,digest(2),{0,0,1,1},{},{},{absent(0,0)}));
    VWB_EXPECT_THROW(NativeSurfaceTreePresenceRejected,
        NativeTreeExclusionHaloCapture::create(digest(1),1U,{}, {0,0,1,1},{},{},{absent(0,0)}));
    VWB_EXPECT_THROW(NativeSurfaceTreePresenceRejected,
        halo({2,0,1,1}));
    VWB_EXPECT_THROW(NativeSurfaceTreePresenceRejected,
        halo({0,0,1,1}, {{"", {0,0,1,1}}}));
    VWB_EXPECT_THROW(NativeSurfaceTreePresenceRejected,
        halo({0,0,1,1}, {{"duplicate", {0,0,1,1}}, {"duplicate", {2,2,3,3}}}));
    const auto distinct = halo({0,0,40,40}, {{"a",{0,0,1,1}}, {"b",{2,2,3,3}}});
    VWB_EXPECT(distinct.content_digest() != Sha256Digest{});
    const auto capture = halo({0,0,40,40});
    VWB_EXPECT_THROW(NativeSurfaceTreePresenceRejected,
        evaluate_native_tree_exclusion_halo(10,10,std::numeric_limits<double>::infinity(),1.0,0.0,1.35,capture));
    VWB_EXPECT_THROW(NativeSurfaceTreePresenceRejected,
        evaluate_native_tree_exclusion_halo(10,10,1.0,1.0,0.0,0.0,capture));
    VWB_EXPECT_THROW(NativeSurfaceTreePresenceRejected,
        evaluate_native_tree_exclusion_halo(10,10,1.0,10000.0,0.0,1.35,capture));
}

VWB_TEST(native_tree_halo_validates_complete_receipt_fields) {
    const auto invalid = [&](std::vector<StructureExclusionRecord> records,
        std::vector<CitadelExclusionSource> regions = {absent(0,0)}) {
        VWB_EXPECT_THROW(NativeSurfaceTreePresenceRejected,
            halo({0,0,40,40}, std::move(records), {}, std::move(regions)));
    };
    invalid({{std::string(1025U, 'x'), {0,0,1,1}}});
    invalid({{std::string("a\0b", 3U), {0,0,1,1}}});
    invalid({{"bad-x", {2,0,1,1}}});
    invalid({{"bad-z", {0,2,1,1}}});
    std::vector<StructureExclusionRecord> many;
    many.reserve(65537U);
    for (std::uint32_t i = 0U; i < 65537U; ++i)
        many.push_back({std::to_string(i), {0,0,1,1}});
    invalid(std::move(many));
    VWB_EXPECT_THROW(NativeSurfaceTreePresenceRejected,
        NativeTreeExclusionHaloCapture::create(digest(1),1U,digest(2),{0,2,1,1},{},{},{absent(0,0)}));
    VWB_EXPECT_THROW(NativeSurfaceTreePresenceRejected,
        NativeTreeExclusionHaloCapture::create(digest(1),1U,digest(2),{0,0,1,1},{},{},
            std::vector<CitadelExclusionSource>(65U, absent(0,0))));
    invalid({}, {absent(0,0), absent(0,0)});
    auto same_x = absent(0,0); same_x.region_z = 1;
    const auto two_regions = halo({0,0,40,40}, {}, {}, {same_x, absent(0,0)});
    VWB_EXPECT(two_regions.content_digest() != Sha256Digest{});
    auto c = absent(0,0); c.status = CitadelSourceStatus::ready;
    c.source_key = "site"; c.source_signature = "sig"; c.admission_generation = 1U;
    c.reservation = {0,0,2,2};
    auto invalid_citadel = [&](const CitadelExclusionSource &bad) { invalid({}, {bad}); };
    auto bad = c; bad.source_key.clear(); invalid_citadel(bad);
    bad = c; bad.source_signature.clear(); invalid_citadel(bad);
    bad = c; bad.admission_generation = 0U; invalid_citadel(bad);
    bad = c; bad.reservation.max_x = 0; invalid_citadel(bad);
    bad = c; bad.reservation.max_z = 0; invalid_citadel(bad);
    bad = c; bad.status = static_cast<CitadelSourceStatus>(99); invalid_citadel(bad);
    bad = c; bad.status = CitadelSourceStatus::failed; bad.reason = "failed";
    invalid_citadel(bad);
    bad = absent(0,0); bad.status = CitadelSourceStatus::failed;
    bad.source_key.clear(); invalid_citadel(bad);
    bad.reason = "failed"; bad.source_key = "site"; invalid_citadel(bad);
    bad.source_key.clear(); bad.source_signature = "sig"; invalid_citadel(bad);
    bad.source_signature.clear(); bad.admission_generation = 1U; invalid_citadel(bad);
    bad.admission_generation = 0U; bad.reservation.min_x = 1; invalid_citadel(bad);
    bad.reservation.min_x = 0; bad.reservation.min_z = 1; invalid_citadel(bad);
    bad.reservation.min_z = 0; bad.reservation.max_x = 1; invalid_citadel(bad);
    bad.reservation.max_x = 0; bad.reservation.max_z = 1; invalid_citadel(bad);
}

VWB_TEST(native_tree_halo_rejects_all_margin_and_coverage_boundaries) {
    const auto capture = halo({0,0,20,20});
    const auto reject = [&](double trunk, double canopy, double exclusion, double cell) {
        VWB_EXPECT_THROW(NativeSurfaceTreePresenceRejected,
            evaluate_native_tree_exclusion_halo(10,10,trunk,canopy,exclusion,cell,capture));
    };
    reject(1.0,std::numeric_limits<double>::infinity(),0.0,1.35);
    reject(1.0,1.0,std::numeric_limits<double>::infinity(),1.35);
    reject(-1.0,1.0,0.0,1.35); reject(1.0,1.0,-1.0,1.35);
    reject(1.0,1.0,0.0,std::numeric_limits<double>::infinity());
    reject(1.0,1.0,0.0,-1.0);
    VWB_EXPECT_THROW(NativeSurfaceTreePresenceRejected,
        evaluate_native_tree_exclusion_halo(0,10,1.0,1.0,0.0,1.35,capture));
    VWB_EXPECT_THROW(NativeSurfaceTreePresenceRejected,
        evaluate_native_tree_exclusion_halo(20,10,1.0,1.0,0.0,1.35,capture));
    VWB_EXPECT_THROW(NativeSurfaceTreePresenceRejected,
        evaluate_native_tree_exclusion_halo(10,0,1.0,1.0,0.0,1.35,capture));
    VWB_EXPECT_THROW(NativeSurfaceTreePresenceRejected,
        evaluate_native_tree_exclusion_halo(10,20,1.0,1.0,0.0,1.35,capture));
}

VWB_TEST(native_tree_halo_geometry_rejects_each_axis_independently) {
    const std::array<StructureExclusionRect, 4> outside{{
        {1,9,2,11}, {18,9,19,11}, {9,1,11,2}, {9,18,11,19}
    }};
    for (const auto &r : outside) {
        const auto natural = halo({0,0,30,30}, {{"outside", r}});
        const auto terrain = halo({0,0,30,30}, {}, {{"outside", r}});
        VWB_EXPECT_EQ(NativeSurfaceTreePresence::present,
            evaluate_native_tree_exclusion_halo(10,10,1.0,1.0,0.0,1.35,natural).presence);
        VWB_EXPECT_EQ(NativeSurfaceTreePresence::present,
            evaluate_native_tree_exclusion_halo(10,10,1.0,1.0,0.0,1.35,terrain).presence);
    }
    // Citadel half-open bounds use max as exclusive. Exercise each rejection
    // side after the earlier x/z predicates have succeeded where applicable.
    for (const auto &r : outside) {
        auto c = absent(0,0); c.status = CitadelSourceStatus::ready;
        c.source_key = "outside"; c.source_signature = "sig"; c.admission_generation = 1U;
        c.reservation = {r.min_x,r.min_z,r.max_x + 1,r.max_z + 1};
        const auto capture = halo({0,0,30,30}, {}, {}, {c});
        VWB_EXPECT_EQ(NativeSurfaceTreePresence::present,
            evaluate_native_tree_exclusion_halo(10,10,1.0,1.0,0.0,1.35,capture).presence);
    }
}
