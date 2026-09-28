#pragma once

#include <array>
#include <cstddef>
#include <cstdint>
#include <stdexcept>
#include <string>
#include <type_traits>
#include <utility>
#include <variant>
#include <vector>

namespace voxel::world_backend {

// This friend name intentionally has no production API.  The native tests use
// it to exercise std::variant's exceptional valueless state, which ordinary
// factory construction and staged assignment cannot create.
struct NativeValueTestAccess;

// NativeValue is intentionally the small JSON-compatible *value* algebra used
// by the native snapshot work.  It is not a JSON parser and does not admit
// JSON syntax: callers supply already-decoded values, which are normalized and
// validated before construction.  Keeping this separate from persisted cells
// prevents untyped script dictionaries from becoming a second state authority.
enum class NativeValueKind : std::uint8_t {
    null_value = 0,
    boolean = 1,
    number = 2,
    string = 3,
    array = 4,
    object = 5,
};

struct NativeValueLimits final {
    // These limits deliberately bound identity work.  A root scalar has depth
    // zero; each array/object edge increases depth by one.
    static constexpr std::size_t MAX_DEPTH = 32U;
    static constexpr std::size_t MAX_NODES = 4096U;
    static constexpr std::size_t MAX_STRING_BYTES = 65536U;
    static constexpr std::size_t MAX_OBJECT_KEY_BYTES = 1024U;
    static constexpr std::size_t MAX_CONTAINER_ENTRIES = 1024U;
};

// NativeValue owns the NV1 wire contract. Consumers can measure once and
// stream the exact canonical bytes into their own already-bounded writer
// without duplicating the recursive tag/length rules.
struct NativeValueCanonicalMetrics final {
    std::size_t canonical_bytes = 0U;
    std::size_t utf8_bytes = 0U;
    std::size_t compact_retained_dynamic_bytes = 0U;
};

class NativeValueCanonicalSink {
public:
    virtual ~NativeValueCanonicalSink() = default;
    virtual void append(const std::uint8_t *data, std::size_t size) = 0;
};

class NativeValueRejected final : public std::invalid_argument {
public:
    NativeValueRejected();
};

class NativeValue final {
public:
    using Array = std::vector<NativeValue>;
    // Object order is part of the representation and identity.  Keys must be
    // valid UTF-8 in strictly increasing byte/UTF-8 order; thus duplicates are
    // rejected rather than silently overwritten.
    using Object = std::vector<std::pair<std::string, NativeValue>>;

    static NativeValue null();
    static NativeValue boolean(bool value);
    static NativeValue number(double value);
    static NativeValue string(std::string value);
    static NativeValue array(Array value);
    static NativeValue object(Object value);

    NativeValue(const NativeValue &) = default;
    NativeValue(NativeValue &&) noexcept = default;
    // Assignment stages a complete value before no-throw exchange, so private
    // storage cannot become valueless during an ordinary public assignment.
    NativeValue &operator=(const NativeValue &other);
    NativeValue &operator=(NativeValue &&other) noexcept;

    NativeValueKind kind() const;
    bool as_boolean() const;
    double as_number() const;
    const std::string &as_string() const;
    const Array &as_array() const;
    const Object &as_object() const;

    // The encoding begins with the ASCII protocol marker NV1 and then uses a
    // one-byte tag, big-endian fixed-width lengths, exact IEEE-754 bits for
    // finite doubles, and recursively encoded ordered children.  -0.0 is
    // normalized to +0.0 at admission so equality and identity agree.
    std::vector<std::uint8_t> canonical_binary() const;
    NativeValueCanonicalMetrics canonical_metrics() const;
    void write_canonical(NativeValueCanonicalSink &sink) const;

    // Returns a value-semantic deep copy whose strings and containers are
    // rebuilt from logical sizes rather than inheriting caller spare capacity.
    // canonical_metrics().compact_retained_dynamic_bytes is a conservative
    // bound for the dynamic storage of this compact representation under the
    // pinned MSVC STL used by both supported compiler frontends.
    NativeValue compact_copy() const;

    bool operator==(const NativeValue &other) const noexcept;
    bool operator!=(const NativeValue &other) const noexcept;

private:
    friend struct NativeValueTestAccess;
    friend class NativeValueCanonicalCursor;
    using Storage = std::variant<std::monostate, bool, double, std::string, Array, Object>;

    explicit NativeValue(Storage storage);

    Storage storage_;
};

enum class NativeValueCanonicalCursorStatus : std::uint8_t {
    in_progress = 0U,
    complete = 1U,
    source_changed = 2U,
    invalid_value = 3U,
    sink_failed = 4U,
    invalid_state = 5U,
};

struct NativeValueCanonicalCursorProgress final {
    NativeValueCanonicalCursorStatus status = NativeValueCanonicalCursorStatus::in_progress;
    std::size_t bytes_written = 0U;
    std::size_t nodes_started = 0U;
    std::size_t work_units = 0U;
    std::size_t next_atomic_units = 1U;
};

// Resumable, allocation-free traversal of the existing NV1 canonical wire
// format. The source token must identify one immutable semantic root version;
// change it whenever that root can change. The cursor retains only indices,
// scalar encoding state, and a fixed depth stack. It never stores a NativeValue,
// container, string, or pointer between advance() calls. The caller must also
// ensure that the same source version remains borrowed for the duration of an
// individual call and serialize calls for a given cursor.
class NativeValueCanonicalCursor final {
public:
    static constexpr std::size_t MAX_FRAMES = NativeValueLimits::MAX_DEPTH + 1U;

    NativeValueCanonicalCursor() noexcept;
    NativeValueCanonicalCursor(const NativeValueCanonicalCursor &) = delete;
    NativeValueCanonicalCursor &operator=(const NativeValueCanonicalCursor &) = delete;
    NativeValueCanonicalCursor(NativeValueCanonicalCursor &&) = delete;
    NativeValueCanonicalCursor &operator=(NativeValueCanonicalCursor &&) = delete;

    void reset() noexcept;
    NativeValueCanonicalCursorProgress advance(
        const NativeValue &root,
        std::uint64_t source_token,
        std::size_t byte_budget,
        std::size_t node_budget,
        std::size_t work_budget,
        NativeValueCanonicalSink &sink) noexcept;

    NativeValueCanonicalCursorStatus status() const noexcept;

private:
    enum class Phase : std::uint8_t {
        start_value,
        number_bytes,
        string_length,
        string_bytes,
        container_count,
        array_items,
        object_items,
        object_key_length,
        object_key_bytes,
        complete_value,
    };

    struct Frame final {
        Phase phase = Phase::start_value;
        NativeValueKind kind = NativeValueKind::null_value;
        std::size_t parent_index = 0U;
        std::size_t next_child = 0U;
        std::size_t offset = 0U;
        std::size_t declared_length = 0U;
        std::size_t segment_length = 0U;
        std::uint64_t number_bits = 0U;
        bool length_ready = false;
    };

    const NativeValue *resolve_value(const NativeValue &root, std::size_t depth) noexcept;
    void fail(NativeValueCanonicalCursorStatus status) noexcept;

    std::array<Frame, MAX_FRAMES> frames_{};
    std::size_t depth_ = 0U;
    std::size_t nodes_total_ = 0U;
    std::size_t prefix_offset_ = 0U;
    std::uint64_t source_token_ = 0U;
    NativeValueCanonicalCursorStatus status_ = NativeValueCanonicalCursorStatus::in_progress;
    bool source_started_ = false;
    bool advancing_ = false;
};

} // namespace voxel::world_backend
