#include "native_value.hpp"

#include <algorithm>
#include <cmath>
#include <cstring>
#include <limits>

namespace voxel::world_backend {
namespace {

enum class BinaryTag : std::uint8_t {
    null_value = 0U,
    false_value = 1U,
    true_value = 2U,
    number = 3U,
    string = 4U,
    array = 5U,
    object = 6U,
};

[[noreturn]] void reject(const char *) {
    throw NativeValueRejected();
}

bool is_valid_utf8(const std::string &value) noexcept {
    const auto *bytes = reinterpret_cast<const std::uint8_t *>(value.data());
    std::size_t index = 0U;
    while (index < value.size()) {
        const std::uint8_t first = bytes[index++];
        if (first <= 0x7fU) continue;

        std::uint32_t code_point = 0U;
        std::size_t continuation_count = 0U;
        if (first >= 0xc2U && first <= 0xdfU) {
            code_point = static_cast<std::uint32_t>(first & 0x1fU);
            continuation_count = 1U;
        } else if (first >= 0xe0U && first <= 0xefU) {
            code_point = static_cast<std::uint32_t>(first & 0x0fU);
            continuation_count = 2U;
        } else if (first >= 0xf0U && first <= 0xf4U) {
            code_point = static_cast<std::uint32_t>(first & 0x07U);
            continuation_count = 3U;
        } else {
            return false;
        }
        if (value.size() - index < continuation_count) return false;
        for (std::size_t continuation = 0U; continuation < continuation_count; ++continuation) {
            const std::uint8_t byte = bytes[index++];
            if ((byte & 0xc0U) != 0x80U) return false;
            code_point = (code_point << 6U) | static_cast<std::uint32_t>(byte & 0x3fU);
        }
        const bool overlong = (continuation_count == 2U && code_point < 0x800U)
            || (continuation_count == 3U && code_point < 0x10000U);
        if (overlong || (code_point >= 0xd800U && code_point <= 0xdfffU) || code_point > 0x10ffffU) return false;
    }
    return true;
}

void validate_text(const std::string &value, const std::size_t maximum_bytes) {
    if (value.size() > maximum_bytes || !is_valid_utf8(value)) reject("invalid text");
}

bool utf8_byte_less(const std::string &left, const std::string &right) noexcept {
    return std::lexicographical_compare(left.begin(), left.end(), right.begin(), right.end(),
        [](const char left_byte, const char right_byte) noexcept {
            return static_cast<std::uint8_t>(static_cast<unsigned char>(left_byte))
                < static_cast<std::uint8_t>(static_cast<unsigned char>(right_byte));
        });
}

void validate_value(const NativeValue &value, const std::size_t depth, std::size_t &nodes) {
    if (depth > NativeValueLimits::MAX_DEPTH || ++nodes > NativeValueLimits::MAX_NODES) reject("value limits exceeded");
    const NativeValueKind kind = value.kind();
    if (kind == NativeValueKind::null_value || kind == NativeValueKind::boolean) {
        return;
    }
    if (kind == NativeValueKind::number) {
        // number() is the sole admission path for this private storage and
        // rejects every non-finite value before it can become a child.
        return;
    }
    if (kind == NativeValueKind::string) {
        validate_text(value.as_string(), NativeValueLimits::MAX_STRING_BYTES);
        return;
    }
    if (kind == NativeValueKind::array) {
        const NativeValue::Array &children = value.as_array();
        if (children.size() > NativeValueLimits::MAX_CONTAINER_ENTRIES) reject("array too large");
        for (const NativeValue &child : children) validate_value(child, depth + 1U, nodes);
        return;
    }
    // The private variant has exactly six alternatives whose indexes map to
    // NativeValueKind.  The only remaining validated kind is object.
    const NativeValue::Object &entries = value.as_object();
    if (entries.size() > NativeValueLimits::MAX_CONTAINER_ENTRIES) reject("object too large");
    const std::string *previous_key = nullptr;
    for (const auto &entry : entries) {
        validate_text(entry.first, NativeValueLimits::MAX_OBJECT_KEY_BYTES);
        if (previous_key != nullptr && !utf8_byte_less(*previous_key, entry.first)) reject("object keys are not strictly sorted");
        previous_key = &entry.first;
        validate_value(entry.second, depth + 1U, nodes);
    }
}

void validate_root(const NativeValue &value) {
    std::size_t nodes = 0U;
    validate_value(value, 0U, nodes);
}

void append_u32(NativeValueCanonicalSink &sink, const std::uint32_t value) {
    std::uint8_t bytes[4];
    for (int index = 0, shift = 24; shift >= 0; ++index, shift -= 8) {
        bytes[index] = static_cast<std::uint8_t>((value >> shift) & 0xffU);
    }
    sink.append(bytes, sizeof(bytes));
}

void append_bytes(NativeValueCanonicalSink &sink, const std::string &value) {
    append_u32(sink, static_cast<std::uint32_t>(value.size()));
    sink.append(reinterpret_cast<const std::uint8_t *>(value.data()), value.size());
}

void append_tag(NativeValueCanonicalSink &sink, const BinaryTag tag) {
    const std::uint8_t byte = static_cast<std::uint8_t>(tag);
    sink.append(&byte, 1U);
}

void append_value(NativeValueCanonicalSink &sink, const NativeValue &value) {
    const NativeValueKind kind = value.kind();
    if (kind == NativeValueKind::null_value) {
        append_tag(sink, BinaryTag::null_value);
        return;
    }
    if (kind == NativeValueKind::boolean) {
        append_tag(sink, value.as_boolean() ? BinaryTag::true_value : BinaryTag::false_value);
        return;
    }
    if (kind == NativeValueKind::number) {
        static_assert(sizeof(double) == sizeof(std::uint64_t), "NativeValue requires 64-bit double storage");
        static_assert(std::numeric_limits<double>::is_iec559, "NativeValue requires IEEE-754 double storage");
        std::uint64_t bits = 0U;
        const double number = value.as_number();
        std::memcpy(&bits, &number, sizeof(bits));
        append_tag(sink, BinaryTag::number);
        std::uint8_t bytes[8];
        for (int index = 0, shift = 56; shift >= 0; ++index, shift -= 8) {
            bytes[index] = static_cast<std::uint8_t>((bits >> shift) & 0xffU);
        }
        sink.append(bytes, sizeof(bytes));
        return;
    }
    if (kind == NativeValueKind::string) {
        append_tag(sink, BinaryTag::string);
        append_bytes(sink, value.as_string());
        return;
    }
    if (kind == NativeValueKind::array) {
        append_tag(sink, BinaryTag::array);
        append_u32(sink, static_cast<std::uint32_t>(value.as_array().size()));
        for (const NativeValue &child : value.as_array()) append_value(sink, child);
        return;
    }
    // Factories and private storage admit only the six tags above; object is
    // therefore the sole remaining serializer case, never a fallback policy.
    append_tag(sink, BinaryTag::object);
    append_u32(sink, static_cast<std::uint32_t>(value.as_object().size()));
    for (const auto &entry : value.as_object()) {
        append_bytes(sink, entry.first);
        append_value(sink, entry.second);
    }
}

std::size_t compact_string_dynamic_bytes(const std::size_t size) noexcept {
    // MSVC's basic_string uses 15 inline chars and 16-byte allocation
    // granularity. Count no heap for inline values and round every larger
    // payload (including its terminator) to the next 16-byte bucket.
    return size <= 15U ? 0U : ((size | 15U) + 1U);
}

NativeValueCanonicalMetrics measure_value(const NativeValue &value) {
    const NativeValueKind kind = value.kind();
    if (kind == NativeValueKind::null_value || kind == NativeValueKind::boolean) return {1U, 0U, 0U};
    if (kind == NativeValueKind::number) return {9U, 0U, 0U};
    if (kind == NativeValueKind::string) {
        return {5U + value.as_string().size(), value.as_string().size(),
            compact_string_dynamic_bytes(value.as_string().size())};
    }
    NativeValueCanonicalMetrics result{5U, 0U, 0U};
    if (kind == NativeValueKind::array) {
        result.compact_retained_dynamic_bytes = value.as_array().size() * sizeof(NativeValue);
        for (const NativeValue &child : value.as_array()) {
            const NativeValueCanonicalMetrics child_metrics = measure_value(child);
            result.canonical_bytes += child_metrics.canonical_bytes;
            result.utf8_bytes += child_metrics.utf8_bytes;
            result.compact_retained_dynamic_bytes += child_metrics.compact_retained_dynamic_bytes;
        }
        return result;
    }
    result.compact_retained_dynamic_bytes = value.as_object().size() * sizeof(NativeValue::Object::value_type);
    for (const auto &entry : value.as_object()) {
        result.canonical_bytes += 4U + entry.first.size();
        result.utf8_bytes += entry.first.size();
        result.compact_retained_dynamic_bytes += compact_string_dynamic_bytes(entry.first.size());
        const NativeValueCanonicalMetrics child_metrics = measure_value(entry.second);
        result.canonical_bytes += child_metrics.canonical_bytes;
        result.utf8_bytes += child_metrics.utf8_bytes;
        result.compact_retained_dynamic_bytes += child_metrics.compact_retained_dynamic_bytes;
    }
    return result;
}

std::string compact_string(const std::string &value) {
    std::string result(value.data(), value.size());
    result.shrink_to_fit();
    return result;
}

NativeValue compact_value(const NativeValue &value) {
    const NativeValueKind kind = value.kind();
    if (kind == NativeValueKind::null_value) return NativeValue::null();
    if (kind == NativeValueKind::boolean) return NativeValue::boolean(value.as_boolean());
    if (kind == NativeValueKind::number) return NativeValue::number(value.as_number());
    if (kind == NativeValueKind::string) return NativeValue::string(compact_string(value.as_string()));
    if (kind == NativeValueKind::array) {
        NativeValue::Array result;
        result.reserve(value.as_array().size());
        for (const NativeValue &child : value.as_array()) result.push_back(compact_value(child));
        result.shrink_to_fit();
        return NativeValue::array(std::move(result));
    }
    NativeValue::Object result;
    result.reserve(value.as_object().size());
    for (const auto &entry : value.as_object()) {
        result.emplace_back(compact_string(entry.first), compact_value(entry.second));
    }
    result.shrink_to_fit();
    return NativeValue::object(std::move(result));
}

class VectorCanonicalSink final : public NativeValueCanonicalSink {
public:
    explicit VectorCanonicalSink(const std::size_t exact_size) { bytes_.reserve(exact_size); }
    void append(const std::uint8_t *data, const std::size_t size) override {
        bytes_.insert(bytes_.end(), data, data + size);
    }
    std::vector<std::uint8_t> finish() { return std::move(bytes_); }
private:
    std::vector<std::uint8_t> bytes_;
};

} // namespace

NativeValueRejected::NativeValueRejected() : std::invalid_argument("native value rejected") {}

NativeValue::NativeValue(Storage storage) : storage_(std::move(storage)) {}

NativeValue NativeValue::null() { return NativeValue(std::monostate{}); }
NativeValue NativeValue::boolean(const bool value) { return NativeValue(value); }

NativeValue NativeValue::number(double value) {
    if (!std::isfinite(value)) reject("non-finite number");
    if (value == 0.0) value = 0.0; // canonicalize IEEE signed zero.
    return NativeValue(value);
}

NativeValue NativeValue::string(std::string value) {
    validate_text(value, NativeValueLimits::MAX_STRING_BYTES);
    return NativeValue(std::move(value));
}

NativeValue NativeValue::array(Array value) {
    NativeValue result(std::move(value));
    validate_root(result);
    return result;
}

NativeValue NativeValue::object(Object value) {
    NativeValue result(std::move(value));
    validate_root(result);
    return result;
}

NativeValue &NativeValue::operator=(const NativeValue &other) {
    NativeValue staged(other);
    storage_.swap(staged.storage_);
    return *this;
}

NativeValue &NativeValue::operator=(NativeValue &&other) noexcept {
    static_assert(std::is_nothrow_swappable_v<Storage>, "NativeValue assignment requires no-throw storage exchange");
    storage_.swap(other.storage_);
    return *this;
}

NativeValueKind NativeValue::kind() const {
    if (storage_.valueless_by_exception()) reject("valueless native value");
    static_assert(std::variant_size_v<Storage> == 6U, "NativeValue kind mapping requires exactly six storage alternatives");
    return static_cast<NativeValueKind>(storage_.index());
}

bool NativeValue::as_boolean() const { return std::get<bool>(storage_); }
double NativeValue::as_number() const { return std::get<double>(storage_); }
const std::string &NativeValue::as_string() const { return std::get<std::string>(storage_); }
const NativeValue::Array &NativeValue::as_array() const { return std::get<Array>(storage_); }
const NativeValue::Object &NativeValue::as_object() const { return std::get<Object>(storage_); }

std::vector<std::uint8_t> NativeValue::canonical_binary() const {
    const NativeValueCanonicalMetrics metrics = canonical_metrics();
    VectorCanonicalSink sink(metrics.canonical_bytes);
    write_canonical(sink);
    return sink.finish();
}

NativeValueCanonicalMetrics NativeValue::canonical_metrics() const {
    if (storage_.valueless_by_exception()) reject("valueless native value");
    validate_root(*this);
    NativeValueCanonicalMetrics result = measure_value(*this);
    result.canonical_bytes += 3U;
    return result;
}

void NativeValue::write_canonical(NativeValueCanonicalSink &sink) const {
    if (storage_.valueless_by_exception()) reject("valueless native value");
    validate_root(*this);
    static constexpr std::uint8_t marker[] = {'N', 'V', '1'};
    sink.append(marker, sizeof(marker));
    append_value(sink, *this);
}

NativeValueCanonicalCursor::NativeValueCanonicalCursor() noexcept { reset(); }

void NativeValueCanonicalCursor::reset() noexcept {
    if (advancing_) {
        fail(NativeValueCanonicalCursorStatus::invalid_state);
        return;
    }
    // Child frames are initialized only when entered. Clearing every frame
    // here would hide MAX_FRAMES work behind an administrative reset.
    frames_[0] = Frame{};
    depth_ = 0U;
    nodes_total_ = 0U;
    prefix_offset_ = 0U;
    source_token_ = 0U;
    status_ = NativeValueCanonicalCursorStatus::in_progress;
    source_started_ = false;
}

NativeValueCanonicalCursorStatus NativeValueCanonicalCursor::status() const noexcept {
    return status_;
}

void NativeValueCanonicalCursor::fail(const NativeValueCanonicalCursorStatus status) noexcept {
    if (status_ == NativeValueCanonicalCursorStatus::in_progress) status_ = status;
}

const NativeValue *NativeValueCanonicalCursor::resolve_value(
    const NativeValue &root, const std::size_t depth) noexcept {
    if (depth >= MAX_FRAMES) return nullptr;
    const NativeValue *value = &root;
    for (std::size_t level = 1U; level <= depth; ++level) {
        const Frame &parent = frames_[level - 1U];
        const Frame &child = frames_[level];
        if (parent.kind == NativeValueKind::array) {
            const NativeValue::Array *entries = std::get_if<NativeValue::Array>(&value->storage_);
            if (entries == nullptr || child.parent_index >= entries->size()) return nullptr;
            value = &(*entries)[child.parent_index];
        } else if (parent.kind == NativeValueKind::object) {
            const NativeValue::Object *entries = std::get_if<NativeValue::Object>(&value->storage_);
            if (entries == nullptr || child.parent_index >= entries->size()) return nullptr;
            value = &(*entries)[child.parent_index].second;
        } else {
            return nullptr;
        }
    }
    return value;
}

NativeValueCanonicalCursorProgress NativeValueCanonicalCursor::advance(
    const NativeValue &root,
    const std::uint64_t source_token,
    const std::size_t byte_budget,
    const std::size_t node_budget,
    const std::size_t work_budget,
    NativeValueCanonicalSink &sink) noexcept {
    NativeValueCanonicalCursorProgress progress;
    progress.status = status_;
    if (status_ != NativeValueCanonicalCursorStatus::in_progress) return progress;
    // An observational probe is also safe from inside a sink callback. It
    // neither diagnoses a changed token nor alters the outer advance.
    if (work_budget == 0U || byte_budget == 0U) return progress;
    if (advancing_) {
        fail(NativeValueCanonicalCursorStatus::invalid_state);
        progress.status = status_;
        return progress;
    }
    if (source_started_) {
        if (source_token_ != source_token) {
            fail(NativeValueCanonicalCursorStatus::source_changed);
            progress.status = status_;
            return progress;
        }
    }

    advancing_ = true;
    std::size_t bytes_remaining = byte_budget;
    std::size_t nodes_remaining = node_budget;
    std::size_t work_remaining = work_budget;

    const auto append_limited = [&](const std::uint8_t *data, const std::size_t size,
        std::size_t &offset) noexcept -> bool {
        if (offset >= size) return true;
        if (bytes_remaining == 0U || work_remaining == 0U) return false;
        const std::size_t chunk = std::min({size - offset, bytes_remaining, work_remaining});
        try {
            sink.append(data + offset, chunk);
        } catch (...) {
            fail(NativeValueCanonicalCursorStatus::sink_failed);
            return false;
        }
        if (status_ != NativeValueCanonicalCursorStatus::in_progress) return false;
        offset += chunk;
        bytes_remaining -= chunk;
        work_remaining -= chunk;
        progress.work_units += chunk;
        progress.bytes_written += chunk;
        if (!source_started_) {
            source_token_ = source_token;
            source_started_ = true;
        }
        return offset == size;
    };

    const auto append_u32_limited = [&](const std::uint32_t value, std::size_t &offset) noexcept -> bool {
        std::uint8_t bytes[4];
        for (int index = 0, shift = 24; shift >= 0; ++index, shift -= 8) {
            bytes[index] = static_cast<std::uint8_t>((value >> shift) & 0xffU);
        }
        return append_limited(bytes, sizeof(bytes), offset);
    };

    static constexpr std::uint8_t marker[] = {'N', 'V', '1'};
    if (!append_limited(marker, sizeof(marker), prefix_offset_)) {
        advancing_ = false;
        progress.status = status_;
        return progress;
    }

    while (status_ == NativeValueCanonicalCursorStatus::in_progress) {
        Frame &frame = frames_[depth_];
        // Stop at a byte-producing phase when this call's output allowance is
        // exhausted. Structural completion/child transitions are still safe
        // to consume, so a value whose last byte exactly fills the budget can
        // become complete in this same call without spinning on partial data.
        const bool structural_phase = frame.phase == Phase::complete_value
            || frame.phase == Phase::array_items || frame.phase == Phase::object_items;
        const bool empty_payload_phase = (frame.phase == Phase::string_bytes && frame.declared_length == 0U)
            || (frame.phase == Phase::object_key_bytes && frame.segment_length == 0U);
        if (bytes_remaining == 0U && !structural_phase && !empty_payload_phase) {
            progress.next_atomic_units = depth_ + 2U;
            break;
        }
        // resolve_value follows at most MAX_DEPTH parent links. Charge each
        // link plus the phase transition before touching borrowed children.
        const std::size_t phase_cost = depth_ + 2U;
        if (work_remaining < phase_cost) {
            progress.next_atomic_units = phase_cost;
            break;
        }
        work_remaining -= phase_cost;
        progress.work_units += phase_cost;
        const NativeValue *value = resolve_value(root, depth_);
        if (value == nullptr) {
            fail(NativeValueCanonicalCursorStatus::invalid_value);
            break;
        }

        switch (frame.phase) {
        case Phase::start_value: {
            if (bytes_remaining == 0U || nodes_remaining == 0U || nodes_total_ >= NativeValueLimits::MAX_NODES) {
                if (nodes_total_ >= NativeValueLimits::MAX_NODES && bytes_remaining != 0U && nodes_remaining != 0U) {
                    fail(NativeValueCanonicalCursorStatus::invalid_value);
                }
                advancing_ = false;
                progress.status = status_;
                progress.nodes_started = node_budget - nodes_remaining;
                return progress;
            }
            if (value->storage_.valueless_by_exception()) {
                fail(NativeValueCanonicalCursorStatus::invalid_value);
                break;
            }
            const NativeValueKind kind = static_cast<NativeValueKind>(value->storage_.index());
            std::uint8_t tag = 0U;
            switch (kind) {
            case NativeValueKind::null_value:
                tag = 0U;
                break;
            case NativeValueKind::boolean: {
                const bool *boolean = std::get_if<bool>(&value->storage_);
                if (boolean == nullptr) {
                    fail(NativeValueCanonicalCursorStatus::invalid_value);
                    break;
                }
                tag = *boolean ? 2U : 1U;
                break;
            }
            case NativeValueKind::number: {
                const double *number = std::get_if<double>(&value->storage_);
                if (number == nullptr) {
                    fail(NativeValueCanonicalCursorStatus::invalid_value);
                    break;
                }
                tag = 3U;
                std::memcpy(&frame.number_bits, number, sizeof(frame.number_bits));
                break;
            }
            case NativeValueKind::string: {
                const std::string *text = std::get_if<std::string>(&value->storage_);
                if (text == nullptr || text->size() > NativeValueLimits::MAX_STRING_BYTES
                    || text->size() > std::numeric_limits<std::uint32_t>::max()) {
                    fail(NativeValueCanonicalCursorStatus::invalid_value);
                    break;
                }
                tag = 4U;
                frame.declared_length = text->size();
                break;
            }
            case NativeValueKind::array: {
                const NativeValue::Array *entries = std::get_if<NativeValue::Array>(&value->storage_);
                if (entries == nullptr || entries->size() > NativeValueLimits::MAX_CONTAINER_ENTRIES) {
                    fail(NativeValueCanonicalCursorStatus::invalid_value);
                    break;
                }
                tag = 5U;
                frame.declared_length = entries->size();
                break;
            }
            case NativeValueKind::object: {
                const NativeValue::Object *entries = std::get_if<NativeValue::Object>(&value->storage_);
                if (entries == nullptr || entries->size() > NativeValueLimits::MAX_CONTAINER_ENTRIES) {
                    fail(NativeValueCanonicalCursorStatus::invalid_value);
                    break;
                }
                tag = 6U;
                frame.declared_length = entries->size();
                break;
            }
            default:
                fail(NativeValueCanonicalCursorStatus::invalid_value);
                break;
            }
            if (status_ != NativeValueCanonicalCursorStatus::in_progress) break;
            std::size_t tag_offset = 0U;
            if (!append_limited(&tag, 1U, tag_offset)) break;
            if (status_ != NativeValueCanonicalCursorStatus::in_progress) break;
            frame.kind = kind;
            if (kind == NativeValueKind::number) frame.phase = Phase::number_bytes;
            else if (kind == NativeValueKind::string) frame.phase = Phase::string_length;
            else if (kind == NativeValueKind::array || kind == NativeValueKind::object) frame.phase = Phase::container_count;
            else frame.phase = Phase::complete_value;
            frame.offset = 0U;
            ++nodes_total_;
            --nodes_remaining;
            ++progress.nodes_started;
            break;
        }
        case Phase::number_bytes: {
            static_assert(sizeof(double) == sizeof(std::uint64_t), "NativeValue requires 64-bit double storage");
            static_assert(std::numeric_limits<double>::is_iec559, "NativeValue requires IEEE-754 double storage");
            std::uint8_t bytes[8];
            for (int index = 0, shift = 56; shift >= 0; ++index, shift -= 8) {
                bytes[index] = static_cast<std::uint8_t>((frame.number_bits >> shift) & 0xffU);
            }
            if (append_limited(bytes, sizeof(bytes), frame.offset)) frame.phase = Phase::complete_value;
            break;
        }
        case Phase::string_length:
            if (append_u32_limited(static_cast<std::uint32_t>(frame.declared_length), frame.offset)) {
                frame.phase = Phase::string_bytes;
                frame.offset = 0U;
            }
            break;
        case Phase::string_bytes: {
            const std::string *text = std::get_if<std::string>(&value->storage_);
            if (text == nullptr || text->size() != frame.declared_length) {
                fail(NativeValueCanonicalCursorStatus::invalid_value);
                break;
            }
            if (append_limited(reinterpret_cast<const std::uint8_t *>(text->data()), text->size(), frame.offset)) {
                frame.phase = Phase::complete_value;
            }
            break;
        }
        case Phase::container_count:
            if (append_u32_limited(static_cast<std::uint32_t>(frame.declared_length), frame.offset)) {
                frame.phase = frame.kind == NativeValueKind::array ? Phase::array_items : Phase::object_items;
                frame.offset = 0U;
            }
            break;
        case Phase::array_items: {
            const NativeValue::Array *entries = std::get_if<NativeValue::Array>(&value->storage_);
            if (entries == nullptr || entries->size() != frame.declared_length) {
                fail(NativeValueCanonicalCursorStatus::invalid_value);
                break;
            }
            if (frame.next_child >= frame.declared_length) {
                frame.phase = Phase::complete_value;
                break;
            }
            if (depth_ + 1U >= MAX_FRAMES) {
                fail(NativeValueCanonicalCursorStatus::invalid_value);
                break;
            }
            Frame child{};
            child.parent_index = frame.next_child++;
            frames_[depth_ + 1U] = child;
            ++depth_;
            break;
        }
        case Phase::object_items: {
            const NativeValue::Object *entries = std::get_if<NativeValue::Object>(&value->storage_);
            if (entries == nullptr || entries->size() != frame.declared_length) {
                fail(NativeValueCanonicalCursorStatus::invalid_value);
                break;
            }
            if (frame.next_child >= frame.declared_length) {
                frame.phase = Phase::complete_value;
                break;
            }
            frame.phase = Phase::object_key_length;
            frame.offset = 0U;
            frame.length_ready = false;
            break;
        }
        case Phase::object_key_length: {
            const NativeValue::Object *entries = std::get_if<NativeValue::Object>(&value->storage_);
            if (entries == nullptr || entries->size() != frame.declared_length
                || frame.next_child >= entries->size()) {
                fail(NativeValueCanonicalCursorStatus::invalid_value);
                break;
            }
            const std::string &key = (*entries)[frame.next_child].first;
            if (!frame.length_ready) {
                if (key.size() > NativeValueLimits::MAX_OBJECT_KEY_BYTES
                    || key.size() > std::numeric_limits<std::uint32_t>::max()) {
                    fail(NativeValueCanonicalCursorStatus::invalid_value);
                    break;
                }
                frame.segment_length = key.size();
                frame.length_ready = true;
            }
            if (append_u32_limited(static_cast<std::uint32_t>(frame.segment_length), frame.offset)) {
                frame.phase = Phase::object_key_bytes;
                frame.offset = 0U;
            }
            break;
        }
        case Phase::object_key_bytes: {
            const NativeValue::Object *entries = std::get_if<NativeValue::Object>(&value->storage_);
            if (entries == nullptr || entries->size() != frame.declared_length
                || frame.next_child >= entries->size()) {
                fail(NativeValueCanonicalCursorStatus::invalid_value);
                break;
            }
            const std::string &key = (*entries)[frame.next_child].first;
            if (key.size() != frame.segment_length) {
                fail(NativeValueCanonicalCursorStatus::invalid_value);
                break;
            }
            if (!append_limited(reinterpret_cast<const std::uint8_t *>(key.data()), key.size(), frame.offset)) break;
            if (status_ != NativeValueCanonicalCursorStatus::in_progress) break;
            if (depth_ + 1U >= MAX_FRAMES) {
                fail(NativeValueCanonicalCursorStatus::invalid_value);
                break;
            }
            Frame child{};
            child.parent_index = frame.next_child++;
            frame.phase = Phase::object_items;
            frame.length_ready = false;
            frames_[depth_ + 1U] = child;
            ++depth_;
            break;
        }
        case Phase::complete_value:
            if (depth_ == 0U) {
                status_ = NativeValueCanonicalCursorStatus::complete;
            } else {
                --depth_;
            }
            break;
        }
    }

    advancing_ = false;
    progress.status = status_;
    return progress;
}

NativeValue NativeValue::compact_copy() const {
    if (storage_.valueless_by_exception()) reject("valueless native value");
    validate_root(*this);
    return compact_value(*this);
}

bool NativeValue::operator==(const NativeValue &other) const noexcept { return storage_ == other.storage_; }
bool NativeValue::operator!=(const NativeValue &other) const noexcept { return !(*this == other); }

} // namespace voxel::world_backend
