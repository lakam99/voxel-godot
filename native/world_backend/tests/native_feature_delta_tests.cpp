#include "test_harness.hpp"

#include "../core/native_feature_delta.hpp"

#include <cmath>
#include <limits>
#include <string>
#include <utility>
#include <vector>

using namespace voxel::world_backend;

namespace voxel::world_backend {

// NativeValue exposes no public malformed state.  This test-only friend
// reproduces its existing exceptional-state seam so the public feature-delta
// factory can prove that a corrupt decoded runtime object is translated to its
// own fail-closed rejection rather than leaking a lower-layer exception.
struct NativeValueTestAccess final {
    static bool force_valueless_by_exception(NativeValue &value) {
        try {
            value.storage_.template emplace<std::string>(std::numeric_limits<std::size_t>::max(), 'x');
        } catch (const std::length_error &) {
            return value.storage_.valueless_by_exception();
        }
        return false;
    }
};

struct NativeBlockIdentityTestAccess final {
    static void force_empty(NativeBlockIdentity &identity) {
        identity.value_.clear();
    }
};

} // namespace voxel::world_backend

namespace {

NativePlayerCreatedInstance instance(
    const std::string &id = "player:crate:001", const CellCoord cell = {4, 5, 6}) {
    NativePlayerCreatedInstance value{
        "", {}, 0.0, 0.0, NativeBlockIdentity::create("crate.oak"), NativeValue::object({})};
    value.instance_id = id;
    value.cell = cell;
    value.world_y = 12.5;
    value.facing = 1.25;
    value.runtime_state = NativeValue::object({
        {"locked", NativeValue::boolean(false)},
        {"optional", NativeValue::object({
            {"owner", NativeValue::string("mira")},
            {"slots", NativeValue::array({NativeValue::number(3.0), NativeValue::null()})},
        })},
    });
    return value;
}

} // namespace

VWB_TEST(native_feature_delta_canonicalizes_sorted_ids_and_preserves_runtime_optional_values) {
    const NativeFeatureDeltaSnapshot snapshot = NativeFeatureDeltaSnapshot::create(
        {{"zeta"}, {"alpha"}, {"\xc2\xa2-feature"}},
        {instance("z-instance", {7, 8, 9}), instance("a-instance", {-2, 4, 5})});

    VWB_EXPECT_EQ(3U, snapshot.tombstones().size());
    VWB_EXPECT_EQ(std::string("alpha"), snapshot.tombstones()[0].feature_id);
    VWB_EXPECT_EQ(std::string("zeta"), snapshot.tombstones()[1].feature_id);
    VWB_EXPECT_EQ(std::string("\xc2\xa2-feature"), snapshot.tombstones()[2].feature_id);
    VWB_EXPECT_EQ(std::string("a-instance"), snapshot.player_created_instances()[0].instance_id);
    const NativeValue &optional = snapshot.player_created_instances()[0].runtime_state.as_object()[1].second;
    VWB_EXPECT_EQ(NativeValueKind::object, optional.kind());
    VWB_EXPECT_EQ(std::string("mira"), optional.as_object()[0].second.as_string());
    VWB_EXPECT_EQ(NativeValueKind::null_value, optional.as_object()[1].second.as_array()[1].kind());
}

VWB_TEST(native_feature_delta_retains_block_identity_independently_of_cell_or_terrain_material) {
    NativePlayerCreatedInstance door = instance("player:door:001", {4, 5, 6});
    door.block_id = NativeBlockIdentity::create("door.oak.closed");
    const NativeFeatureDeltaSnapshot snapshot = NativeFeatureDeltaSnapshot::create({}, {door});
    VWB_EXPECT_EQ(std::string("door.oak.closed"), snapshot.player_created_instances()[0].block_id.value());
    VWB_EXPECT((snapshot.player_created_instances()[0].cell == CellCoord{4, 5, 6}));
}

VWB_TEST(native_feature_delta_rejects_bad_ids_duplicate_ids_and_duplicate_instance_cells) {
    VWB_EXPECT_THROW(NativeFeatureDeltaRejected,
        NativeFeatureDeltaSnapshot::create({{""}}, {}));
    VWB_EXPECT_THROW(NativeFeatureDeltaRejected,
        NativeFeatureDeltaSnapshot::create({{std::string("bad\xc0\x80", 5)}}, {}));
    VWB_EXPECT_THROW(NativeFeatureDeltaRejected,
        NativeFeatureDeltaSnapshot::create({{"same"}, {"same"}}, {}));
    VWB_EXPECT_THROW(NativeFeatureDeltaRejected,
        NativeFeatureDeltaSnapshot::create({}, {instance("same"), instance("same", {7, 8, 9})}));
    VWB_EXPECT_THROW(NativeFeatureDeltaRejected,
        NativeFeatureDeltaSnapshot::create({}, {instance("first"), instance("second", {4, 5, 6})}));
    VWB_EXPECT_THROW(NativeFeatureDeltaRejected,
        NativeFeatureDeltaSnapshot::create({}, {instance(std::string("bad\xf5", 4))}));
}

VWB_TEST(native_feature_delta_admits_same_text_key_in_distinct_v2_domains_with_tagged_fd1_records) {
    const NativePlayerCreatedInstance placed{
        "same", {0, 0, 0}, 0.0, 0.0, NativeBlockIdentity::create("b"), NativeValue::object({})};
    const NativeFeatureDeltaSnapshot snapshot = NativeFeatureDeltaSnapshot::create({{"same"}}, {placed});
    VWB_EXPECT_EQ(std::string("same"), snapshot.tombstones()[0].feature_id);
    VWB_EXPECT_EQ(std::string("same"), snapshot.player_created_instances()[0].instance_id);
    VWB_EXPECT_EQ(std::vector<std::uint8_t>({
        'F', 'D', '1',
        0x00U, 0x00U, 0x00U, 0x01U,
        0x01U, 0x00U, 0x00U, 0x00U, 0x04U, 's', 'a', 'm', 'e',
        0x00U, 0x00U, 0x00U, 0x01U,
        0x02U, 0x00U, 0x00U, 0x00U, 0x04U, 's', 'a', 'm', 'e',
        0x00U, 0x00U, 0x00U, 0x00U, 0x00U, 0x00U, 0x00U, 0x00U,
        0x00U, 0x00U, 0x00U, 0x00U,
        0x00U, 0x00U, 0x00U, 0x00U, 0x00U, 0x00U, 0x00U, 0x00U,
        0x00U, 0x00U, 0x00U, 0x00U, 0x00U, 0x00U, 0x00U, 0x00U,
        0x00U, 0x00U, 0x00U, 0x01U, 'b',
        0x00U, 0x00U, 0x00U, 0x08U, 'N', 'V', '1', 0x06U,
        0x00U, 0x00U, 0x00U, 0x00U,
    }), snapshot.canonical_binary());
}

VWB_TEST(native_feature_delta_enforces_explicit_id_and_record_count_limits_before_storage) {
    VWB_EXPECT_THROW(NativeFeatureDeltaRejected,
        NativeFeatureDeltaSnapshot::create({{std::string(NativeFeatureDeltaLimits::MAX_ID_BYTES + 1U, 'x')}}, {}));
    std::vector<NativeFeatureTombstone> too_many_tombstones(
        NativeFeatureDeltaLimits::MAX_TOMBSTONES + 1U, NativeFeatureTombstone{"valid"});
    VWB_EXPECT_THROW(NativeFeatureDeltaRejected,
        NativeFeatureDeltaSnapshot::create(std::move(too_many_tombstones), {}));
    std::vector<NativePlayerCreatedInstance> too_many_instances(
        NativeFeatureDeltaLimits::MAX_PLAYER_CREATED_INSTANCES + 1U, instance());
    VWB_EXPECT_THROW(NativeFeatureDeltaRejected,
        NativeFeatureDeltaSnapshot::create({}, std::move(too_many_instances)));
}

VWB_TEST(native_feature_delta_rejects_nonfinite_scalars_and_nonobject_runtime_state) {
    NativePlayerCreatedInstance malformed = instance();
    malformed.world_y = std::numeric_limits<double>::quiet_NaN();
    VWB_EXPECT_THROW(NativeFeatureDeltaRejected, NativeFeatureDeltaSnapshot::create({}, {malformed}));
    malformed = instance();
    malformed.facing = std::numeric_limits<double>::infinity();
    VWB_EXPECT_THROW(NativeFeatureDeltaRejected, NativeFeatureDeltaSnapshot::create({}, {malformed}));
    malformed = instance();
    malformed.runtime_state = NativeValue::array({NativeValue::null()});
    VWB_EXPECT_THROW(NativeFeatureDeltaRejected, NativeFeatureDeltaSnapshot::create({}, {malformed}));
    malformed = instance();
    VWB_EXPECT(NativeValueTestAccess::force_valueless_by_exception(malformed.runtime_state));
    VWB_EXPECT_THROW(NativeFeatureDeltaRejected, NativeFeatureDeltaSnapshot::create({}, {malformed}));
    malformed = instance();
    NativeBlockIdentityTestAccess::force_empty(malformed.block_id);
    VWB_EXPECT(malformed.block_id.value().empty());
    VWB_EXPECT_THROW(NativeFeatureDeltaRejected, NativeFeatureDeltaSnapshot::create({}, {malformed}));
}

VWB_TEST(native_feature_delta_canonical_binary_is_versioned_complete_and_normalizes_signed_zero) {
    NativePlayerCreatedInstance left_instance = instance("instance", {-1, -2, -3});
    left_instance.world_y = -0.0;
    left_instance.facing = -0.0;
    NativePlayerCreatedInstance right_instance = left_instance;
    right_instance.world_y = 0.0;
    right_instance.facing = 0.0;
    const NativeFeatureDeltaSnapshot left = NativeFeatureDeltaSnapshot::create({{"removed"}}, {left_instance});
    const NativeFeatureDeltaSnapshot right = NativeFeatureDeltaSnapshot::create({{"removed"}}, {right_instance});
    VWB_EXPECT(left == right);
    VWB_EXPECT_EQ(left.canonical_binary(), right.canonical_binary());
    VWB_EXPECT(!std::signbit(left.player_created_instances()[0].world_y));
    VWB_EXPECT(!std::signbit(left.player_created_instances()[0].facing));
    const std::vector<std::uint8_t> bytes = left.canonical_binary();
    VWB_EXPECT_EQ(static_cast<std::uint8_t>('F'), bytes[0]);
    VWB_EXPECT_EQ(static_cast<std::uint8_t>('D'), bytes[1]);
    VWB_EXPECT_EQ(static_cast<std::uint8_t>('1'), bytes[2]);
    VWB_EXPECT_EQ(0x01U, bytes[7]);
}

VWB_TEST(native_feature_delta_fd1_has_byte_exact_mixed_record_golden) {
    NativePlayerCreatedInstance placed{
        "i", {-1, 2, -3}, -0.0, 1.0, NativeBlockIdentity::create("crate.oak"),
        NativeValue::object({{"a", NativeValue::boolean(true)}})};
    const NativeFeatureDeltaSnapshot snapshot = NativeFeatureDeltaSnapshot::create({{"x"}}, {placed});
    VWB_EXPECT_EQ(std::vector<std::uint8_t>({
        'F', 'D', '1',
        0x00U, 0x00U, 0x00U, 0x01U, // tombstone count
        0x01U, 0x00U, 0x00U, 0x00U, 0x01U, 'x',
        0x00U, 0x00U, 0x00U, 0x01U, // instance count
        0x02U, 0x00U, 0x00U, 0x00U, 0x01U, 'i',
        0xffU, 0xffU, 0xffU, 0xffU, // x = -1
        0x00U, 0x00U, 0x00U, 0x02U, // y = 2
        0xffU, 0xffU, 0xffU, 0xfdU, // z = -3
        0x00U, 0x00U, 0x00U, 0x00U, 0x00U, 0x00U, 0x00U, 0x00U, // world_y = -0 -> +0
        0x3fU, 0xf0U, 0x00U, 0x00U, 0x00U, 0x00U, 0x00U, 0x00U, // facing = 1
        0x00U, 0x00U, 0x00U, 0x09U, 'c', 'r', 'a', 't', 'e', '.', 'o', 'a', 'k',
        0x00U, 0x00U, 0x00U, 0x0eU, // NV1 payload length
        'N', 'V', '1', 0x06U, 0x00U, 0x00U, 0x00U, 0x01U,
        0x00U, 0x00U, 0x00U, 0x01U, 'a', 0x02U,
    }), snapshot.canonical_binary());
}

VWB_TEST(native_feature_delta_equality_and_wire_identity_cover_every_domain_field) {
    const NativeFeatureDeltaSnapshot original = NativeFeatureDeltaSnapshot::create({{"removed"}}, {instance()});
    const NativePlayerCreatedInstance original_instance = instance();
    NativePlayerCreatedInstance changed = instance();
    changed.instance_id = "other";
    VWB_EXPECT(!(original_instance == changed));
    changed = instance();
    changed.cell.x += 1;
    VWB_EXPECT(!(original_instance == changed));
    changed = instance();
    changed.world_y += 1.0;
    VWB_EXPECT(!(original_instance == changed));
    changed = instance();
    changed.facing += 1.0;
    VWB_EXPECT(!(original_instance == changed));
    changed = instance();
    changed.block_id = NativeBlockIdentity::create("torch.wall");
    VWB_EXPECT(!(original_instance == changed));
    changed = instance();
    changed.runtime_state = NativeValue::object({{"changed", NativeValue::boolean(true)}});
    VWB_EXPECT(!(original_instance == changed));
    changed = instance();
    VWB_EXPECT(original_instance == changed);

    changed = instance();
    changed.cell.x += 1;
    VWB_EXPECT(original != NativeFeatureDeltaSnapshot::create({{"removed"}}, {changed}));
    changed = instance(); changed.world_y += 1.0;
    VWB_EXPECT(original.canonical_binary() != NativeFeatureDeltaSnapshot::create({{"removed"}}, {changed}).canonical_binary());
    changed = instance(); changed.facing += 1.0;
    VWB_EXPECT(original.canonical_binary() != NativeFeatureDeltaSnapshot::create({{"removed"}}, {changed}).canonical_binary());
    changed = instance(); changed.block_id = NativeBlockIdentity::create("torch.wall");
    VWB_EXPECT(original.canonical_binary() != NativeFeatureDeltaSnapshot::create({{"removed"}}, {changed}).canonical_binary());
    changed = instance(); changed.runtime_state = NativeValue::object({{"changed", NativeValue::boolean(true)}});
    VWB_EXPECT(original.canonical_binary() != NativeFeatureDeltaSnapshot::create({{"removed"}}, {changed}).canonical_binary());
    VWB_EXPECT(original != NativeFeatureDeltaSnapshot::create({{"other"}}, {instance()}));
    VWB_EXPECT(original.canonical_binary() != NativeFeatureDeltaSnapshot::create({{"other"}}, {instance()}).canonical_binary());
}
