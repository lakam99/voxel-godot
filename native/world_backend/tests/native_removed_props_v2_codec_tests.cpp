#include "test_harness.hpp"
#include "native_value_test_access.hpp"

#include "../core/native_removed_props_v2_codec.hpp"

#include <cstddef>
#include <string>
#include <vector>

using namespace voxel::world_backend;

VWB_TEST(native_removed_props_v2_decodes_game_written_string_set_and_canonicalizes_order) {
    const NativeValue raw = NativeValue::array({
        NativeValue::string("zeta"),
        NativeValue::string("alpha"),
        NativeValue::string("\xc2\xa2-prop"),
    });

    const NativeFeatureDeltaSnapshot snapshot = decode_native_removed_props_v2(raw);
    VWB_EXPECT_EQ(3U, snapshot.tombstones().size());
    VWB_EXPECT(snapshot.player_created_instances().empty());
    VWB_EXPECT_EQ(std::string("alpha"), snapshot.tombstones()[0].feature_id);
    VWB_EXPECT_EQ(std::string("zeta"), snapshot.tombstones()[1].feature_id);
    VWB_EXPECT_EQ(std::string("\xc2\xa2-prop"), snapshot.tombstones()[2].feature_id);

    const NativeValue encoded = encode_native_removed_props_v2(snapshot);
    VWB_EXPECT_EQ(NativeValueKind::array, encoded.kind());
    VWB_EXPECT_EQ(3U, encoded.as_array().size());
    VWB_EXPECT_EQ(std::string("alpha"), encoded.as_array()[0].as_string());
    VWB_EXPECT_EQ(std::string("zeta"), encoded.as_array()[1].as_string());
    VWB_EXPECT_EQ(std::string("\xc2\xa2-prop"), encoded.as_array()[2].as_string());
    VWB_EXPECT_EQ(snapshot, decode_native_removed_props_v2(encoded));
}

VWB_TEST(native_removed_props_v2_typed_boundary_supports_the_full_feature_tombstone_limit) {
    std::vector<std::string> raw;
    raw.reserve(NativeFeatureDeltaLimits::MAX_TOMBSTONES);
    for (std::size_t index = NativeFeatureDeltaLimits::MAX_TOMBSTONES; index > 0U; --index) {
        raw.push_back("generated:prop:" + std::to_string(index));
    }
    const NativeFeatureDeltaSnapshot snapshot = decode_native_removed_props_v2_ids(raw);
    VWB_EXPECT_EQ(NativeFeatureDeltaLimits::MAX_TOMBSTONES, snapshot.tombstones().size());
    const std::vector<std::string> encoded = encode_native_removed_props_v2_ids(snapshot);
    VWB_EXPECT_EQ(NativeFeatureDeltaLimits::MAX_TOMBSTONES, encoded.size());
    VWB_EXPECT_EQ(std::string("generated:prop:1"), encoded[0]);
    VWB_EXPECT_EQ(std::string("generated:prop:9999"), encoded.back());

    // A count-only over-limit input avoids allocating 65,537 unique strings:
    // NativeFeatureDeltaSnapshot checks the record limit before ID admission.
    std::vector<std::string> too_many(NativeFeatureDeltaLimits::MAX_TOMBSTONES + 1U, "x");
    VWB_EXPECT_THROW(NativeRemovedPropsV2Rejected, decode_native_removed_props_v2_ids(too_many));
}

VWB_TEST(native_removed_props_v2_native_value_wrapper_remains_explicitly_bounded) {
    std::vector<std::string> ids;
    ids.reserve(NativeValueLimits::MAX_CONTAINER_ENTRIES + 1U);
    for (std::size_t index = 0U; index <= NativeValueLimits::MAX_CONTAINER_ENTRIES; ++index) {
        ids.push_back("generated:prop:" + std::to_string(index));
    }
    const NativeFeatureDeltaSnapshot snapshot = decode_native_removed_props_v2_ids(ids);
    VWB_EXPECT_EQ(NativeValueLimits::MAX_CONTAINER_ENTRIES + 1U, snapshot.tombstones().size());
    VWB_EXPECT_THROW(NativeRemovedPropsV2Rejected, encode_native_removed_props_v2(snapshot));
    VWB_EXPECT_THROW(NativeValueRejected, NativeValue::array([&ids]() {
        NativeValue::Array values;
        values.reserve(ids.size());
        for (const std::string &id : ids) values.push_back(NativeValue::string(id));
        return values;
    }()));
}

VWB_TEST(native_removed_props_v2_preserves_set_semantics_but_rejects_noncanonical_duplicate_input) {
    const NativeFeatureDeltaSnapshot empty = decode_native_removed_props_v2(NativeValue::array({}));
    VWB_EXPECT(empty.tombstones().empty());
    VWB_EXPECT_EQ(NativeValue::array({}), encode_native_removed_props_v2(empty));

    // MainSaveState writes Dictionary.keys(), so the writer never emits a
    // duplicate. Treating one as an alias would hide a noncanonical save,
    // even though the legacy restorer happens to collapse it into a set.
    VWB_EXPECT_THROW(NativeRemovedPropsV2Rejected, decode_native_removed_props_v2(NativeValue::array({
        NativeValue::string("duplicate"), NativeValue::string("duplicate"),
    })));
}

VWB_TEST(native_removed_props_v2_rejects_noncanonical_variant_coercions_and_empty_ids) {
    VWB_EXPECT_THROW(NativeRemovedPropsV2Rejected, decode_native_removed_props_v2(NativeValue::null()));
    VWB_EXPECT_THROW(NativeRemovedPropsV2Rejected, decode_native_removed_props_v2(NativeValue::string("not-an-array")));
    VWB_EXPECT_THROW(NativeRemovedPropsV2Rejected, decode_native_removed_props_v2(NativeValue::array({NativeValue::string("")})));
    VWB_EXPECT_THROW(NativeRemovedPropsV2Rejected, decode_native_removed_props_v2(NativeValue::array({NativeValue::null()})));
    VWB_EXPECT_THROW(NativeRemovedPropsV2Rejected, decode_native_removed_props_v2(NativeValue::array({NativeValue::boolean(false)})));
    VWB_EXPECT_THROW(NativeRemovedPropsV2Rejected, decode_native_removed_props_v2(NativeValue::array({NativeValue::number(17.0)})));
    VWB_EXPECT_THROW(NativeRemovedPropsV2Rejected, decode_native_removed_props_v2(NativeValue::array({NativeValue::array({})})));
    VWB_EXPECT_THROW(NativeRemovedPropsV2Rejected, decode_native_removed_props_v2(NativeValue::array({NativeValue::object({})})));
    VWB_EXPECT_THROW(NativeRemovedPropsV2Rejected, decode_native_removed_props_v2(NativeValue::array({
        NativeValue::string(std::string(NativeFeatureDeltaLimits::MAX_ID_BYTES + 1U, 'x')),
    })));
    // Invalid UTF-8 cannot reach the codec through public NativeValue input:
    // NativeValue owns that lower-level rejection and must fail before any
    // tombstone interpretation occurs.
    VWB_EXPECT_THROW(NativeValueRejected, NativeValue::string(std::string("bad\xc0\x80", 5)));
    VWB_EXPECT_THROW(NativeRemovedPropsV2Rejected,
        decode_native_removed_props_v2_ids({std::string("bad\xc0\x80", 5)}));

    NativeValue corrupt = NativeValue::array({});
    VWB_EXPECT(NativeValueTestAccess::force_valueless_by_exception(corrupt));
    VWB_EXPECT_THROW(NativeRemovedPropsV2Rejected, decode_native_removed_props_v2(corrupt));
}

VWB_TEST(native_removed_props_v2_rejects_player_block_domain_and_remains_outside_wds_admission) {
    const NativeFeatureDeltaSnapshot mixed = NativeFeatureDeltaSnapshot::create(
        {{"generated:tree:7"}},
        {{"player:block:1", {1, 2, 3}, 4.0, 0.0, NativeBlockIdentity::create("crate.oak"), NativeValue::object({})}});
    VWB_EXPECT_THROW(NativeRemovedPropsV2Rejected, encode_native_removed_props_v2(mixed));

    // Successful pure codec conversion has only a feature snapshot value. It
    // deliberately does not call WorldDeltaStore, whose tombstone admission
    // separately fails closed until footprint invalidation is available.
    const NativeFeatureDeltaSnapshot decoded = decode_native_removed_props_v2(NativeValue::array({
        NativeValue::string("generated:tree:7"),
    }));
    VWB_EXPECT_EQ(std::string("generated:tree:7"), decoded.tombstones()[0].feature_id);
}
