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

class CollectingSink final : public NativeValueCanonicalSink {
public:
    void append(const std::uint8_t *data, const std::size_t size) override {
        bytes.insert(bytes.end(), data, data + size);
    }
    std::vector<std::uint8_t> bytes;
};

std::size_t actual_compact_dynamic_bytes(const NativeValue &value) {
    switch (value.kind()) {
    case NativeValueKind::null_value:
    case NativeValueKind::boolean:
    case NativeValueKind::number:
        return 0U;
    case NativeValueKind::string: {
        const std::string &text = value.as_string();
        return text.capacity() <= 15U ? 0U : text.capacity() + 1U;
    }
    case NativeValueKind::array: {
        const NativeValue::Array &values = value.as_array();
        std::size_t result = values.capacity() * sizeof(NativeValue);
        for (const NativeValue &entry : values) result += actual_compact_dynamic_bytes(entry);
        return result;
    }
    case NativeValueKind::object: {
        const NativeValue::Object &entries = value.as_object();
        std::size_t result = entries.capacity() * sizeof(NativeValue::Object::value_type);
        for (const auto &entry : entries) {
            if (entry.first.capacity() > 15U) result += entry.first.capacity() + 1U;
            result += actual_compact_dynamic_bytes(entry.second);
        }
        return result;
    }
    }
    return 0U;
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
    VWB_EXPECT_THROW(NativeValueRejected, serialization_probe.canonical_metrics());
    CollectingSink sink;
    VWB_EXPECT_THROW(NativeValueRejected, serialization_probe.write_canonical(sink));
    VWB_EXPECT_THROW(NativeValueRejected, serialization_probe.compact_copy());
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

VWB_TEST(native_value_owner_metrics_sink_and_compact_copy_are_value_semantic) {
    NativeValue::Array roomy_array;
    roomy_array.reserve(100000U);
    roomy_array.push_back(NativeValue::boolean(false));
    roomy_array.push_back(NativeValue::number(3.25));
    NativeValue::Object roomy_object;
    roomy_object.reserve(10000U);
    std::string roomy_key(1000U, 'k');
    roomy_key.resize(3U);
    roomy_object.emplace_back(std::move(roomy_key), NativeValue::array(std::move(roomy_array)));
    const NativeValue roomy = NativeValue::object(std::move(roomy_object));
    const NativeValue compact = roomy.compact_copy();
    VWB_EXPECT_EQ(roomy, compact);
    VWB_EXPECT(compact.as_object().capacity() < roomy.as_object().capacity());
    VWB_EXPECT(compact.as_object()[0].second.as_array().capacity()
        < roomy.as_object()[0].second.as_array().capacity());

    const NativeValueCanonicalMetrics roomy_metrics = roomy.canonical_metrics();
    const NativeValueCanonicalMetrics compact_metrics = compact.canonical_metrics();
    VWB_EXPECT_EQ(roomy_metrics.canonical_bytes, compact_metrics.canonical_bytes);
    VWB_EXPECT_EQ(roomy_metrics.utf8_bytes, compact_metrics.utf8_bytes);
    VWB_EXPECT_EQ(roomy_metrics.compact_retained_dynamic_bytes,
        compact_metrics.compact_retained_dynamic_bytes);
    CollectingSink sink;
    roomy.write_canonical(sink);
    VWB_EXPECT_EQ(roomy_metrics.canonical_bytes, sink.bytes.size());
    VWB_EXPECT_EQ(roomy.canonical_binary(), sink.bytes);
}

VWB_TEST(native_value_compact_metric_bounds_actual_pinned_stl_storage_at_growth_thresholds) {
    const std::vector<std::size_t> string_sizes = {0U, 1U, 14U, 15U, 16U, 17U, 30U, 31U, 32U,
        33U, 62U, 63U, 64U, 65U, 1023U, 1024U, NativeValueLimits::MAX_STRING_BYTES};
    for (const std::size_t size : string_sizes) {
        const NativeValue compact = NativeValue::string(std::string(size, 's')).compact_copy();
        VWB_EXPECT(actual_compact_dynamic_bytes(compact)
            <= compact.canonical_metrics().compact_retained_dynamic_bytes);
    }

    NativeValue::Array inner;
    inner.reserve(257U);
    for (std::size_t index = 0U; index < 257U; ++index) {
        inner.push_back(NativeValue::string(std::string(14U + index % 20U, 'a')));
    }
    NativeValue::Object object;
    object.reserve(33U);
    for (std::size_t index = 0U; index < 33U; ++index) {
        std::string key = "capacity-key-" + std::to_string(100U + index);
        object.emplace_back(std::move(key), index == 16U
            ? NativeValue::array(inner)
            : NativeValue::array({NativeValue::null(), NativeValue::number(static_cast<double>(index))}));
    }
    NativeValue::Array outer;
    outer.reserve(65U);
    outer.push_back(NativeValue::object(std::move(object)));
    outer.push_back(NativeValue::array(std::move(inner)));
    const NativeValue compact_nested = NativeValue::array(std::move(outer)).compact_copy();
    const std::size_t actual = actual_compact_dynamic_bytes(compact_nested);
    const std::size_t bound = compact_nested.canonical_metrics().compact_retained_dynamic_bytes;
    VWB_EXPECT(actual <= bound);
    VWB_EXPECT(compact_nested.as_array().capacity() <= compact_nested.as_array().size());
}
