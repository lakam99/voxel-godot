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

class ThrowingSink final : public NativeValueCanonicalSink {
public:
    void append(const std::uint8_t *, std::size_t) override {
        ++calls;
        throw std::runtime_error("sink rejected canonical bytes");
    }
    std::size_t calls = 0U;
};

class ReentrantSink final : public NativeValueCanonicalSink {
public:
    void append(const std::uint8_t *data, const std::size_t size) override {
        if (!attempted) {
            attempted = true;
            nested_progress = cursor->advance(*root, token, 1U, 1U, 4U, *this);
        }
        bytes.insert(bytes.end(), data, data + size);
    }
    NativeValueCanonicalCursor *cursor = nullptr;
    const NativeValue *root = nullptr;
    std::uint64_t token = 0U;
    bool attempted = false;
    NativeValueCanonicalCursorProgress nested_progress;
    std::vector<std::uint8_t> bytes;
};

class ObservationalReentrantSink final : public NativeValueCanonicalSink {
public:
    void append(const std::uint8_t *data, const std::size_t size) override {
        if (!attempted) {
            attempted = true;
            nested_progress = cursor->advance(*root, token + 1U, 0U, 0U, 0U, *this);
        }
        bytes.insert(bytes.end(), data, data + size);
    }
    NativeValueCanonicalCursor *cursor = nullptr;
    const NativeValue *root = nullptr;
    std::uint64_t token = 0U;
    bool attempted = false;
    NativeValueCanonicalCursorProgress nested_progress;
    std::vector<std::uint8_t> bytes;
};

class ResettingSink final : public NativeValueCanonicalSink {
public:
    void append(const std::uint8_t *data, const std::size_t size) override {
        ++calls;
        cursor->reset();
        bytes.insert(bytes.end(), data, data + size);
    }
    NativeValueCanonicalCursor *cursor = nullptr;
    std::size_t calls = 0U;
    std::vector<std::uint8_t> bytes;
};

std::vector<std::uint8_t> encode_with_cursor(const NativeValue &value,
    const std::size_t byte_budget, const std::size_t node_budget, const std::uint64_t source_token) {
    NativeValueCanonicalCursor cursor;
    CollectingSink sink;
    for (std::size_t call = 0U; call < 200000U; ++call) {
        const NativeValueCanonicalCursorProgress progress = cursor.advance(
            value, source_token, byte_budget, node_budget, 4096U, sink);
        VWB_EXPECT(progress.bytes_written <= byte_budget);
        VWB_EXPECT(progress.nodes_started <= node_budget);
        if (progress.status == NativeValueCanonicalCursorStatus::complete) return sink.bytes;
        VWB_EXPECT_EQ(NativeValueCanonicalCursorStatus::in_progress, progress.status);
    }
    ::voxel::world_backend::tests::fail("cursor completed within bounded calls", __FILE__, __LINE__);
}

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

VWB_TEST(native_value_canonical_cursor_preserves_wire_bytes_across_byte_and_node_budgets) {
    const std::vector<NativeValue> values = {
        NativeValue::null(),
        NativeValue::boolean(false),
        NativeValue::boolean(true),
        NativeValue::number(-17.25),
        NativeValue::string("a split multibyte value: \xf0\x9f\x8c\xb2"),
        NativeValue::array({}),
        NativeValue::object({}),
        NativeValue::array({NativeValue::boolean(false), NativeValue::string("A"),
            NativeValue::object({{"a", NativeValue::number(1.0)},
                {"\xc3\xa9", NativeValue::array({NativeValue::null(), NativeValue::boolean(true)})}})}),
        nested_arrays(NativeValueLimits::MAX_DEPTH),
    };
    const std::vector<std::size_t> byte_budgets = {1U, 2U, 3U, 4U, 7U, 8U, 9U, 17U};
    const std::vector<std::size_t> node_budgets = {1U, 2U, 7U};
    std::uint64_t token = 0U;
    for (const NativeValue &value : values) {
        const std::vector<std::uint8_t> expected = value.canonical_binary();
        for (const std::size_t bytes : byte_budgets) {
            for (const std::size_t nodes : node_budgets) {
                VWB_EXPECT_EQ(expected, encode_with_cursor(value, bytes, nodes, ++token));
            }
        }
    }
}

VWB_TEST(native_value_canonical_cursor_bounds_maximum_string_and_node_counts) {
    const NativeValue largest_string = NativeValue::string(
        std::string(NativeValueLimits::MAX_STRING_BYTES, 's'));
    VWB_EXPECT_EQ(largest_string.canonical_binary(), encode_with_cursor(largest_string, 257U, 1U, 101U));

    NativeValue::Array branches;
    for (std::size_t branch = 0U; branch < 3U; ++branch) {
        NativeValue::Array leaves;
        leaves.resize(NativeValueLimits::MAX_CONTAINER_ENTRIES, NativeValue::null());
        branches.push_back(NativeValue::array(std::move(leaves)));
    }
    NativeValue::Array last_branch;
    last_branch.resize(1019U, NativeValue::null());
    branches.push_back(NativeValue::array(std::move(last_branch)));
    const NativeValue maximum_nodes = NativeValue::array(std::move(branches));
    VWB_EXPECT_EQ(maximum_nodes.canonical_binary(), encode_with_cursor(maximum_nodes, 19U, 7U, 102U));
    static_assert(sizeof(NativeValueCanonicalCursor) <= 2304U,
        "The cursor's complete retained state must remain a small fixed-depth value.");
}

VWB_TEST(native_value_canonical_cursor_handles_zero_budgets_reset_and_source_replacement) {
    const NativeValue value = NativeValue::object({{"name", NativeValue::string("tree")}});
    NativeValueCanonicalCursor cursor;
    CollectingSink sink;

    NativeValueCanonicalCursorProgress progress = cursor.advance(value, 17U, 0U, 0U, 4096U, sink);
    VWB_EXPECT_EQ(NativeValueCanonicalCursorStatus::in_progress, progress.status);
    VWB_EXPECT_EQ(0U, progress.bytes_written);
    VWB_EXPECT_EQ(0U, progress.nodes_started);

    NativeValueCanonicalCursor zero_probe;
    CollectingSink zero_probe_sink;
    const auto zero = zero_probe.advance(value, 17U, 0U, 0U, 0U, zero_probe_sink);
    VWB_EXPECT_EQ(0U, zero.work_units);
    const auto changed_after_no_work = zero_probe.advance(
        value, 18U, 3U, 1U, 3U, zero_probe_sink);
    VWB_EXPECT_EQ(NativeValueCanonicalCursorStatus::in_progress, changed_after_no_work.status);
    VWB_EXPECT_EQ(3U, changed_after_no_work.bytes_written);

    progress = cursor.advance(value, 17U, 3U, 0U, 4096U, sink);
    VWB_EXPECT_EQ(NativeValueCanonicalCursorStatus::in_progress, progress.status);
    VWB_EXPECT_EQ(3U, progress.bytes_written);
    VWB_EXPECT_EQ(0U, progress.nodes_started);

    NativeValueCanonicalCursor bounded_work_cursor;
    CollectingSink bounded_work_sink;
    const auto one_work = bounded_work_cursor.advance(
        value, 23U, 64U, 64U, 1U, bounded_work_sink);
    VWB_EXPECT_EQ(1U, one_work.work_units);
    VWB_EXPECT_EQ(1U, one_work.bytes_written);
    const auto no_work = bounded_work_cursor.advance(
        value, 23U, 64U, 64U, 0U, bounded_work_sink);
    VWB_EXPECT_EQ(0U, no_work.work_units);
    VWB_EXPECT_EQ(1U, bounded_work_sink.bytes.size());
    const auto changed_without_work = bounded_work_cursor.advance(
        value, 24U, 0U, 0U, 0U, bounded_work_sink);
    VWB_EXPECT_EQ(NativeValueCanonicalCursorStatus::in_progress, changed_without_work.status);
    VWB_EXPECT_EQ(0U, changed_without_work.work_units);
    const auto resumed_original = bounded_work_cursor.advance(
        value, 23U, 64U, 64U, 64U, bounded_work_sink);
    VWB_EXPECT(resumed_original.status == NativeValueCanonicalCursorStatus::in_progress
        || resumed_original.status == NativeValueCanonicalCursorStatus::complete);
    VWB_EXPECT(resumed_original.bytes_written > 0U);
    NativeValueCanonicalCursor observational_cursor;
    ObservationalReentrantSink observational_sink;
    observational_sink.cursor = &observational_cursor;
    observational_sink.root = &value;
    observational_sink.token = 27U;
    const auto outer = observational_cursor.advance(
        value, 27U, 64U, 64U, 64U, observational_sink);
    VWB_EXPECT_EQ(NativeValueCanonicalCursorStatus::in_progress,
        observational_sink.nested_progress.status);
    VWB_EXPECT_EQ(0U, observational_sink.nested_progress.work_units);
    VWB_EXPECT(outer.status == NativeValueCanonicalCursorStatus::in_progress
        || outer.status == NativeValueCanonicalCursorStatus::complete);
    progress = cursor.advance(value, 17U, 0U, 1U, 4096U, sink);
    VWB_EXPECT_EQ(0U, progress.bytes_written);
    VWB_EXPECT_EQ(0U, progress.nodes_started);

    progress = cursor.advance(value, 18U, 32U, 8U, 4096U, sink);
    VWB_EXPECT_EQ(NativeValueCanonicalCursorStatus::source_changed, progress.status);
    const std::size_t bytes_after_source_change = sink.bytes.size();
    progress = cursor.advance(value, 17U, 32U, 8U, 4096U, sink);
    VWB_EXPECT_EQ(NativeValueCanonicalCursorStatus::source_changed, progress.status);
    VWB_EXPECT_EQ(bytes_after_source_change, sink.bytes.size());

    cursor.reset();
    VWB_EXPECT_EQ(NativeValueCanonicalCursorStatus::in_progress, cursor.status());
    CollectingSink restarted_sink;
    for (std::size_t call = 0U; call < 100U; ++call) {
        progress = cursor.advance(value, 18U, 5U, 1U, 4096U, restarted_sink);
        VWB_EXPECT(progress.bytes_written <= 5U);
        VWB_EXPECT(progress.nodes_started <= 1U);
        if (progress.status == NativeValueCanonicalCursorStatus::complete) break;
        VWB_EXPECT_EQ(NativeValueCanonicalCursorStatus::in_progress, progress.status);
    }
    VWB_EXPECT_EQ(NativeValueCanonicalCursorStatus::complete, progress.status);
    VWB_EXPECT_EQ(value.canonical_binary(), restarted_sink.bytes);

    const NativeValue exact_budget_value = NativeValue::number(1.0);
    NativeValueCanonicalCursor exact_budget_cursor;
    CollectingSink exact_budget_sink;
    progress = exact_budget_cursor.advance(exact_budget_value, 19U, 4U, 1U, 4096U, exact_budget_sink);
    VWB_EXPECT_EQ(NativeValueCanonicalCursorStatus::in_progress, progress.status);
    VWB_EXPECT_EQ(4U, progress.bytes_written);
    progress = exact_budget_cursor.advance(exact_budget_value, 19U, 0U, 1U, 4096U, exact_budget_sink);
    VWB_EXPECT_EQ(NativeValueCanonicalCursorStatus::in_progress, progress.status);
    VWB_EXPECT_EQ(0U, progress.bytes_written);
    progress = exact_budget_cursor.advance(exact_budget_value, 19U, 8U, 0U, 4096U, exact_budget_sink);
    VWB_EXPECT_EQ(NativeValueCanonicalCursorStatus::complete, progress.status);
    VWB_EXPECT_EQ(8U, progress.bytes_written);
    VWB_EXPECT_EQ(exact_budget_value.canonical_binary(), exact_budget_sink.bytes);

    const NativeValue empty_string = NativeValue::string("");
    NativeValueCanonicalCursor empty_string_cursor;
    CollectingSink empty_string_sink;
    progress = empty_string_cursor.advance(empty_string, 20U, 8U, 1U, 4096U, empty_string_sink);
    VWB_EXPECT_EQ(NativeValueCanonicalCursorStatus::complete, progress.status);
    VWB_EXPECT_EQ(empty_string.canonical_binary(), empty_string_sink.bytes);

    const NativeValue empty_key = NativeValue::object({{"", NativeValue::null()}});
    NativeValueCanonicalCursor empty_key_cursor;
    CollectingSink empty_key_sink;
    progress = empty_key_cursor.advance(empty_key, 21U, 13U, 2U, 4096U, empty_key_sink);
    VWB_EXPECT_EQ(NativeValueCanonicalCursorStatus::complete, progress.status);
    VWB_EXPECT_EQ(empty_key.canonical_binary(), empty_key_sink.bytes);

    NativeValueCanonicalCursor split_empty_key_cursor;
    CollectingSink split_empty_key_sink;
    progress = split_empty_key_cursor.advance(empty_key, 22U, 12U, 1U, 4096U, split_empty_key_sink);
    VWB_EXPECT_EQ(NativeValueCanonicalCursorStatus::in_progress, progress.status);
    VWB_EXPECT_EQ(12U, progress.bytes_written);
    progress = split_empty_key_cursor.advance(empty_key, 22U, 1U, 1U, 4096U, split_empty_key_sink);
    VWB_EXPECT_EQ(NativeValueCanonicalCursorStatus::complete, progress.status);
    VWB_EXPECT_EQ(1U, progress.bytes_written);
    VWB_EXPECT_EQ(empty_key.canonical_binary(), split_empty_key_sink.bytes);
}

VWB_TEST(native_value_canonical_cursor_fails_closed_for_invalid_values_and_sinks) {
    NativeValue valueless = NativeValue::null();
    VWB_EXPECT(NativeValueTestAccess::force_valueless_by_exception(valueless));
    NativeValueCanonicalCursor invalid_cursor;
    CollectingSink invalid_sink;
    NativeValueCanonicalCursorProgress progress = invalid_cursor.advance(valueless, 1U, 64U, 64U, 4096U, invalid_sink);
    VWB_EXPECT_EQ(NativeValueCanonicalCursorStatus::invalid_value, progress.status);
    VWB_EXPECT_EQ(0U, progress.nodes_started);
    progress = invalid_cursor.advance(valueless, 1U, 64U, 64U, 4096U, invalid_sink);
    VWB_EXPECT_EQ(NativeValueCanonicalCursorStatus::invalid_value, progress.status);

    const NativeValue valid = NativeValue::string("sink-error");
    NativeValueCanonicalCursor throwing_cursor;
    ThrowingSink throwing_sink;
    progress = throwing_cursor.advance(valid, 2U, 64U, 64U, 4096U, throwing_sink);
    VWB_EXPECT_EQ(NativeValueCanonicalCursorStatus::sink_failed, progress.status);
    VWB_EXPECT_EQ(1U, throwing_sink.calls);
    progress = throwing_cursor.advance(valid, 2U, 64U, 64U, 4096U, throwing_sink);
    VWB_EXPECT_EQ(NativeValueCanonicalCursorStatus::sink_failed, progress.status);
    VWB_EXPECT_EQ(1U, throwing_sink.calls);

    NativeValueCanonicalCursor reentrant_cursor;
    ReentrantSink reentrant_sink;
    reentrant_sink.cursor = &reentrant_cursor;
    reentrant_sink.root = &valid;
    reentrant_sink.token = 3U;
    progress = reentrant_cursor.advance(valid, 3U, 64U, 64U, 4096U, reentrant_sink);
    VWB_EXPECT_EQ(NativeValueCanonicalCursorStatus::invalid_state, progress.status);
    VWB_EXPECT_EQ(NativeValueCanonicalCursorStatus::invalid_state, reentrant_sink.nested_progress.status);
    const std::size_t bytes_after_reentry = reentrant_sink.bytes.size();
    progress = reentrant_cursor.advance(valid, 3U, 64U, 64U, 4096U, reentrant_sink);
    VWB_EXPECT_EQ(NativeValueCanonicalCursorStatus::invalid_state, progress.status);
    VWB_EXPECT_EQ(bytes_after_reentry, reentrant_sink.bytes.size());

    NativeValueCanonicalCursor resetting_cursor;
    ResettingSink resetting_sink;
    resetting_sink.cursor = &resetting_cursor;
    progress = resetting_cursor.advance(valid, 4U, 64U, 64U, 4096U, resetting_sink);
    VWB_EXPECT_EQ(NativeValueCanonicalCursorStatus::invalid_state, progress.status);
    VWB_EXPECT_EQ(1U, resetting_sink.calls);
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
