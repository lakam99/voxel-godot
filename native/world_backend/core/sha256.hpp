#pragma once

#include <array>
#include <cstddef>
#include <cstdint>
#include <string>
#include <vector>

namespace voxel::world_backend {

using Sha256Digest = std::array<std::uint8_t, 32>;

struct Sha256UpdateStep {
    std::size_t consumed_bytes;
    std::size_t compressed_blocks;
    // True only when the entire offered input span was consumed.
    bool input_complete;
};

struct Sha256FinishStep {
    std::size_t compressed_blocks;
    bool digest_ready;
};

// Fixed value-owned state; callers serialize access. No frame-budget or
// thread-safety claim is made. All storage, including ABI padding, is charged
// using sizeof(Sha256State), never a guessed byte count.
class Sha256State final {
public:
    Sha256State() noexcept;
    void reset() noexcept;
    // Finishing/finalized rejects first, then nonempty-null, then overflow.
    // The whole offered size is checked before dereference or any mutation,
    // even when either quota is zero. A full message block is never deferred.
    Sha256UpdateStep update_step(const std::uint8_t *data, std::size_t size,
        std::size_t byte_quota, std::size_t block_quota);
    // Zero quota preserves state. First positive call forbids later updates.
    // At most two padding blocks; completed calls are idempotent/no-work.
    Sha256FinishStep finish_step(std::size_t block_quota);
    Sha256Digest digest() const;

private:
    friend struct Sha256TestAccess;
    void process_block(const std::uint8_t *block) noexcept;
    std::array<std::uint32_t, 8> words_;
    std::array<std::uint8_t, 64> partial_;
    std::uint64_t accepted_bytes_;
    std::uint8_t partial_bytes_;
    // 0 accepting, 1 second padding block pending, 2 complete.
    std::uint8_t phase_;
};

Sha256Digest sha256(const std::uint8_t *data, std::size_t size);
Sha256Digest sha256(const std::vector<std::uint8_t> &bytes);
std::string sha256_hex(const Sha256Digest &digest);

} // namespace voxel::world_backend
