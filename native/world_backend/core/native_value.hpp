#pragma once

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

    bool operator==(const NativeValue &other) const noexcept;
    bool operator!=(const NativeValue &other) const noexcept;

private:
    friend struct NativeValueTestAccess;
    using Storage = std::variant<std::monostate, bool, double, std::string, Array, Object>;

    explicit NativeValue(Storage storage);

    Storage storage_;
};

} // namespace voxel::world_backend
