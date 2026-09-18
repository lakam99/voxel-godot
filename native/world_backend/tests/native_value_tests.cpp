#include "test_harness.hpp"
#include "native_value_test_access.hpp"

#include "../core/native_value.hpp"

#include <cmath>
#include <cstdint>
#include <limits>
#include <string>
#include <vector>

using namespace voxel::world_backend;

namespace {

NativeValue nested_arrays(const std::size_t depth) {
    NativeValue value = NativeValue::null();
    for (std::size_t index = 0U; index < depth; ++index) value = NativeValue::array({value});
    return value;
}

} // namespace

VWB_TEST(native_value_admits_all_canonical_json_value_kinds_and_exact_structure) {
    const NativeValue value = NativeValue::object({
        {"active", NativeValue::boolean(true)},
        {"detail", NativeValue::array({NativeValue::null(), NativeValue::number(7.5)})},
        {"name", NativeValue::string("mira")},
    });
    VWB_EXPECT_EQ(NativeValueKind::object, value.kind());
    VWB_EXPECT_EQ(3U, value.as_object().size());
    VWB_EXPECT(value.as_object()[0].second.as_boolean());
    VWB_EXPECT_EQ(NativeValueKind::null_value, value.as_object()[1].second.as_array()[0].kind());
    VWB_EXPECT_EQ(7.5, value.as_object()[1].second.as_array()[1].as_number());
    VWB_EXPECT_EQ(std::string("mira"), value.as_object()[2].second.as_string());
}

VWB_TEST(native_value_rejects_nonfinite_numbers_and_normalizes_signed_zero) {
    VWB_EXPECT_THROW(NativeValueRejected, NativeValue::number(std::numeric_limits<double>::quiet_NaN()));
    VWB_EXPECT_THROW(NativeValueRejected, NativeValue::number(std::numeric_limits<double>::infinity()));
    VWB_EXPECT_THROW(NativeValueRejected, NativeValue::number(-std::numeric_limits<double>::infinity()));
    const NativeValue positive_zero = NativeValue::number(0.0);
    const NativeValue negative_zero = NativeValue::number(-0.0);
    VWB_EXPECT(positive_zero == negative_zero);
    VWB_EXPECT_EQ(positive_zero.canonical_binary(), negative_zero.canonical_binary());
    VWB_EXPECT(!std::signbit(negative_zero.as_number()));
}

VWB_TEST(native_value_rejects_invalid_utf8_and_text_limits) {
    VWB_EXPECT_EQ(std::string("\xc2\xa2"), NativeValue::string("\xc2\xa2").as_string());
    VWB_EXPECT_EQ(std::string("\xe0\xa0\x80"), NativeValue::string("\xe0\xa0\x80").as_string());
    VWB_EXPECT_EQ(std::string("\xf4\x8f\xbf\xbf"), NativeValue::string("\xf4\x8f\xbf\xbf").as_string());
    VWB_EXPECT_THROW(NativeValueRejected, NativeValue::string(std::string("\xc0\x80", 2)));
    VWB_EXPECT_THROW(NativeValueRejected, NativeValue::string(std::string("\xf5\x80\x80\x80", 4)));
    VWB_EXPECT_THROW(NativeValueRejected, NativeValue::string(std::string("\xc2\x41", 2)));
    VWB_EXPECT_THROW(NativeValueRejected, NativeValue::string(std::string("\xe0\x80\x80", 3)));
    VWB_EXPECT_THROW(NativeValueRejected, NativeValue::string(std::string("\xf0\x80\x80\x80", 4)));
    VWB_EXPECT_THROW(NativeValueRejected, NativeValue::string(std::string("\xed\xa0\x80", 3)));
    VWB_EXPECT_THROW(NativeValueRejected, NativeValue::string(std::string("\xf4\x90\x80\x80", 4)));
    VWB_EXPECT_THROW(NativeValueRejected, NativeValue::string(std::string("\xe2\x82", 2)));
    VWB_EXPECT_EQ(std::string("\xf0\x9f\x8c\xb2"), NativeValue::string("\xf0\x9f\x8c\xb2").as_string());
    VWB_EXPECT_THROW(NativeValueRejected, NativeValue::string(std::string(NativeValueLimits::MAX_STRING_BYTES + 1U, 'x')));
}

VWB_TEST(native_value_rejects_unsorted_duplicate_or_invalid_object_keys) {
    VWB_EXPECT_THROW(NativeValueRejected, NativeValue::object({
        {"z", NativeValue::null()}, {"a", NativeValue::null()},
    }));
    VWB_EXPECT_THROW(NativeValueRejected, NativeValue::object({
        {"same", NativeValue::null()}, {"same", NativeValue::boolean(true)},
    }));
    VWB_EXPECT_THROW(NativeValueRejected, NativeValue::object({
        {std::string("\xc0\x80", 2), NativeValue::null()},
    }));
    VWB_EXPECT_THROW(NativeValueRejected, NativeValue::object({
        {std::string(NativeValueLimits::MAX_OBJECT_KEY_BYTES + 1U, 'k'), NativeValue::null()},
    }));
    VWB_EXPECT_EQ(NativeValueKind::object, NativeValue::object({
        {"\x7f", NativeValue::null()}, {"\xc2\xa2", NativeValue::null()},
    }).kind());
    VWB_EXPECT_THROW(NativeValueRejected, NativeValue::object({
        {"\xc2\xa2", NativeValue::null()}, {"\x7f", NativeValue::null()},
    }));
}

VWB_TEST(native_value_rejects_container_depth_node_and_entry_limit_violations) {
    VWB_EXPECT_EQ(NativeValueKind::array, nested_arrays(NativeValueLimits::MAX_DEPTH).kind());
    VWB_EXPECT_THROW(NativeValueRejected, nested_arrays(NativeValueLimits::MAX_DEPTH + 1U));
    NativeValue::Array too_many;
    too_many.resize(NativeValueLimits::MAX_CONTAINER_ENTRIES + 1U, NativeValue::null());
    VWB_EXPECT_THROW(NativeValueRejected, NativeValue::array(std::move(too_many)));
    NativeValue::Object too_many_object;
    too_many_object.resize(NativeValueLimits::MAX_CONTAINER_ENTRIES + 1U, {"x", NativeValue::null()});
    VWB_EXPECT_THROW(NativeValueRejected, NativeValue::object(std::move(too_many_object)));

    NativeValue value = NativeValue::null();
    for (std::size_t index = 0U; index < 11U; ++index) value = NativeValue::array({value, value});
    VWB_EXPECT_THROW(NativeValueRejected, NativeValue::array({value, value}));
}

VWB_TEST(native_value_canonical_binary_is_type_tagged_ordered_and_deterministic) {
    const NativeValue left = NativeValue::object({
        {"a", NativeValue::number(1.0)},
        {"b", NativeValue::array({NativeValue::boolean(false), NativeValue::string("x")})},
    });
    const NativeValue same = NativeValue::object({
        {"a", NativeValue::number(1.0)},
        {"b", NativeValue::array({NativeValue::boolean(false), NativeValue::string("x")})},
    });
    const NativeValue distinct_type = NativeValue::string("1");
    VWB_EXPECT(left == same);
    VWB_EXPECT_EQ(left.canonical_binary(), same.canonical_binary());
    VWB_EXPECT(!(left == distinct_type));
    VWB_EXPECT(left.canonical_binary() != distinct_type.canonical_binary());
    const std::vector<std::uint8_t> binary = left.canonical_binary();
    VWB_EXPECT_EQ(static_cast<std::uint8_t>('N'), binary[0]);
    VWB_EXPECT_EQ(static_cast<std::uint8_t>('V'), binary[1]);
    VWB_EXPECT_EQ(static_cast<std::uint8_t>('1'), binary[2]);
    VWB_EXPECT_EQ(6U, binary[3]);
}

VWB_TEST(native_value_canonical_binary_exercises_every_valid_tag_and_inequality) {
    const std::vector<NativeValue> values = {
        NativeValue::null(),
        NativeValue::boolean(false),
        NativeValue::boolean(true),
        NativeValue::number(-17.25),
        NativeValue::string("text"),
        NativeValue::array({NativeValue::null()}),
        NativeValue::object({{"key", NativeValue::null()}}),
    };
    const std::vector<std::uint8_t> expected_tags = {0U, 1U, 2U, 3U, 4U, 5U, 6U};
    for (std::size_t index = 0U; index < values.size(); ++index) {
        const std::vector<std::uint8_t> binary = values[index].canonical_binary();
        VWB_EXPECT_EQ(static_cast<std::uint8_t>('N'), binary[0]);
        VWB_EXPECT_EQ(expected_tags[index], binary[3]);
    }
    VWB_EXPECT(NativeValue::null() != NativeValue::boolean(false));
    VWB_EXPECT(NativeValue::number(2.0) != NativeValue::number(3.0));
}

VWB_TEST(native_value_canonical_binary_has_exact_versioned_wire_goldens) {
    VWB_EXPECT_EQ(std::vector<std::uint8_t>({'N', 'V', '1', 0x00U}), NativeValue::null().canonical_binary());
    VWB_EXPECT_EQ(std::vector<std::uint8_t>({'N', 'V', '1', 0x01U}), NativeValue::boolean(false).canonical_binary());
    VWB_EXPECT_EQ(std::vector<std::uint8_t>({'N', 'V', '1', 0x02U}), NativeValue::boolean(true).canonical_binary());
    VWB_EXPECT_EQ(std::vector<std::uint8_t>({'N', 'V', '1', 0x03U, 0x3fU, 0xf0U, 0x00U, 0x00U, 0x00U, 0x00U, 0x00U, 0x00U}),
        NativeValue::number(1.0).canonical_binary());
    VWB_EXPECT_EQ(std::vector<std::uint8_t>({'N', 'V', '1', 0x03U, 0x00U, 0x00U, 0x00U, 0x00U, 0x00U, 0x00U, 0x00U, 0x00U}),
        NativeValue::number(-0.0).canonical_binary());
    VWB_EXPECT_EQ(std::vector<std::uint8_t>({'N', 'V', '1', 0x04U, 0x00U, 0x00U, 0x00U, 0x02U, 0xc3U, 0xa9U}),
        NativeValue::string("\xc3\xa9").canonical_binary());
    VWB_EXPECT_EQ(std::vector<std::uint8_t>({'N', 'V', '1', 0x05U, 0x00U, 0x00U, 0x00U, 0x02U, 0x01U, 0x04U, 0x00U, 0x00U, 0x00U, 0x01U, 'A'}),
        NativeValue::array({NativeValue::boolean(false), NativeValue::string("A")}).canonical_binary());
    VWB_EXPECT_EQ(std::vector<std::uint8_t>({
        'N', 'V', '1', 0x06U, 0x00U, 0x00U, 0x00U, 0x02U,
        0x00U, 0x00U, 0x00U, 0x01U, 'a', 0x03U, 0x3fU, 0xf0U, 0x00U, 0x00U, 0x00U, 0x00U, 0x00U, 0x00U,
        0x00U, 0x00U, 0x00U, 0x02U, 0xc3U, 0xa9U, 0x05U, 0x00U, 0x00U, 0x00U, 0x02U, 0x00U, 0x02U,
    }), NativeValue::object({
        {"a", NativeValue::number(1.0)},
        {"\xc3\xa9", NativeValue::array({NativeValue::null(), NativeValue::boolean(true)})},
    }).canonical_binary());
}

VWB_TEST(native_value_rejects_the_variant_exceptional_state_before_tag_dispatch) {
    NativeValue kind_probe = NativeValue::null();
    VWB_EXPECT(NativeValueTestAccess::force_valueless_by_exception(kind_probe));
    VWB_EXPECT_THROW(NativeValueRejected, kind_probe.kind());

    NativeValue serialization_probe = NativeValue::null();
    VWB_EXPECT(NativeValueTestAccess::force_valueless_by_exception(serialization_probe));
    VWB_EXPECT_THROW(NativeValueRejected, serialization_probe.canonical_binary());
}

VWB_TEST(native_value_assignment_stages_copy_and_exchanges_moved_storage) {
    const NativeValue source = NativeValue::object({{"stable", NativeValue::number(4.0)}});
    NativeValue copy_target = NativeValue::string("old");
    copy_target = source;
    VWB_EXPECT(copy_target == source);
    VWB_EXPECT_EQ(source.canonical_binary(), copy_target.canonical_binary());

    NativeValue move_target = NativeValue::boolean(false);
    move_target = NativeValue::array({NativeValue::null()});
    VWB_EXPECT_EQ(NativeValueKind::array, move_target.kind());
    VWB_EXPECT_EQ(NativeValueKind::null_value, move_target.as_array()[0].kind());
}
