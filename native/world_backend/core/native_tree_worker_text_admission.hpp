#pragma once

#include <cstddef>
#include <cstdint>
#include <initializer_list>
#include <stdexcept>
#include <string_view>

namespace voxel::world_backend {

inline constexpr std::size_t NATIVE_TREE_WORKER_MAX_TEXT_FIELD_BYTES = 256U;
inline constexpr std::size_t NATIVE_TREE_WORKER_MAX_REQUEST_TEXT_BYTES = 1024U;
inline constexpr std::size_t NATIVE_TREE_WORKER_MAX_SERIALIZED_IDENTITY_BYTES = 2048U;

inline void admit_native_tree_worker_text(
    const std::initializer_list<std::string_view> fields) {
    std::size_t total = 0U;
    for (const std::string_view field : fields) {
        if (field.size() > NATIVE_TREE_WORKER_MAX_TEXT_FIELD_BYTES
            || total > NATIVE_TREE_WORKER_MAX_REQUEST_TEXT_BYTES - field.size()) {
            throw std::invalid_argument("native tree worker text exceeds bounded identity limits");
        }
        total += field.size();
        for (std::size_t index = 0U; index < field.size();) {
            const auto first = static_cast<std::uint8_t>(field[index]);
            std::uint32_t codepoint = 0U;
            std::size_t length = 0U;
            if (first < 0x80U) { codepoint = first; length = 1U; }
            else if ((first & 0xe0U) == 0xc0U) { codepoint = first & 0x1fU; length = 2U; }
            else if ((first & 0xf0U) == 0xe0U) { codepoint = first & 0x0fU; length = 3U; }
            else if ((first & 0xf8U) == 0xf0U) { codepoint = first & 0x07U; length = 4U; }
            else throw std::invalid_argument("native tree worker text is not UTF-8");
            if (length > field.size() - index) {
                throw std::invalid_argument("native tree worker text is not UTF-8");
            }
            for (std::size_t offset = 1U; offset < length; ++offset) {
                const auto next = static_cast<std::uint8_t>(field[index + offset]);
                if ((next & 0xc0U) != 0x80U) {
                    throw std::invalid_argument("native tree worker text is not UTF-8");
                }
                codepoint = (codepoint << 6U) | (next & 0x3fU);
            }
            if ((length == 2U && codepoint < 0x80U)
                || (length == 3U && codepoint < 0x800U)
                || (length == 4U && codepoint < 0x10000U)
                || codepoint > 0x10ffffU
                || (codepoint >= 0xd800U && codepoint <= 0xdfffU)) {
                throw std::invalid_argument("native tree worker text has invalid Unicode");
            }
            index += length;
        }
    }
}

inline void admit_native_tree_worker_serialized_identity(const std::string_view identity) {
    if (identity.size() > NATIVE_TREE_WORKER_MAX_SERIALIZED_IDENTITY_BYTES) {
        throw std::invalid_argument("native tree worker serialized identity exceeds its byte limit");
    }
}

} // namespace voxel::world_backend
