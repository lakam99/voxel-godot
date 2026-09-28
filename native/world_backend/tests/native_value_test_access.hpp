#pragma once

#include "../core/native_value.hpp"

#include <limits>
#include <stdexcept>

namespace voxel::world_backend {

// Test-only friend seam for NativeValue's otherwise unconstructable
// valueless-by-exception state. Keeping it shared avoids each consumer test
// declaring a different definition of the friend type.
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

} // namespace voxel::world_backend
