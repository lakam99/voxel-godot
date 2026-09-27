#include "sha256.hpp"

#include <cstring>
#include <algorithm>
#include <limits>
#include <stdexcept>

namespace voxel::world_backend {
namespace {

constexpr std::array<std::uint32_t, 64> ROUND_CONSTANTS = {
    0x428a2f98U, 0x71374491U, 0xb5c0fbcfU, 0xe9b5dba5U, 0x3956c25bU, 0x59f111f1U, 0x923f82a4U, 0xab1c5ed5U,
    0xd807aa98U, 0x12835b01U, 0x243185beU, 0x550c7dc3U, 0x72be5d74U, 0x80deb1feU, 0x9bdc06a7U, 0xc19bf174U,
    0xe49b69c1U, 0xefbe4786U, 0x0fc19dc6U, 0x240ca1ccU, 0x2de92c6fU, 0x4a7484aaU, 0x5cb0a9dcU, 0x76f988daU,
    0x983e5152U, 0xa831c66dU, 0xb00327c8U, 0xbf597fc7U, 0xc6e00bf3U, 0xd5a79147U, 0x06ca6351U, 0x14292967U,
    0x27b70a85U, 0x2e1b2138U, 0x4d2c6dfcU, 0x53380d13U, 0x650a7354U, 0x766a0abbU, 0x81c2c92eU, 0x92722c85U,
    0xa2bfe8a1U, 0xa81a664bU, 0xc24b8b70U, 0xc76c51a3U, 0xd192e819U, 0xd6990624U, 0xf40e3585U, 0x106aa070U,
    0x19a4c116U, 0x1e376c08U, 0x2748774cU, 0x34b0bcb5U, 0x391c0cb3U, 0x4ed8aa4aU, 0x5b9cca4fU, 0x682e6ff3U,
    0x748f82eeU, 0x78a5636fU, 0x84c87814U, 0x8cc70208U, 0x90befffaU, 0xa4506cebU, 0xbef9a3f7U, 0xc67178f2U,
};

constexpr std::uint32_t rotate_right(const std::uint32_t value, const unsigned count) noexcept {
    return (value >> count) | (value << (32U - count));
}

} // namespace

Sha256State::Sha256State() noexcept { reset(); }

void Sha256State::reset() noexcept {
    words_ = {
        0x6a09e667U, 0xbb67ae85U, 0x3c6ef372U, 0xa54ff53aU,
        0x510e527fU, 0x9b05688cU, 0x1f83d9abU, 0x5be0cd19U,
    };
    partial_.fill(0U);
    accepted_bytes_ = 0U;
    partial_bytes_ = 0U;
    phase_ = 0U;
}

void Sha256State::process_block(const std::uint8_t *block) noexcept {
        // Fixed scratch: 256-byte schedule plus eight uint32 round variables
        // and scalar temporaries. No heap, render object, or TLS workspace.
        std::array<std::uint32_t, 64> schedule{};
        for (std::size_t index = 0; index < 16U; ++index) {
            const std::size_t offset = index * 4U;
            schedule[index] = (static_cast<std::uint32_t>(block[offset]) << 24U)
                | (static_cast<std::uint32_t>(block[offset + 1U]) << 16U)
                | (static_cast<std::uint32_t>(block[offset + 2U]) << 8U)
                | static_cast<std::uint32_t>(block[offset + 3U]);
        }
        for (std::size_t index = 16U; index < schedule.size(); ++index) {
            const std::uint32_t s0 = rotate_right(schedule[index - 15U], 7U)
                ^ rotate_right(schedule[index - 15U], 18U) ^ (schedule[index - 15U] >> 3U);
            const std::uint32_t s1 = rotate_right(schedule[index - 2U], 17U)
                ^ rotate_right(schedule[index - 2U], 19U) ^ (schedule[index - 2U] >> 10U);
            schedule[index] = schedule[index - 16U] + s0 + schedule[index - 7U] + s1;
        }

        std::uint32_t a = words_[0];
        std::uint32_t b = words_[1];
        std::uint32_t c = words_[2];
        std::uint32_t d = words_[3];
        std::uint32_t e = words_[4];
        std::uint32_t f = words_[5];
        std::uint32_t g = words_[6];
        std::uint32_t h = words_[7];
        for (std::size_t index = 0; index < schedule.size(); ++index) {
            const std::uint32_t sum1 = rotate_right(e, 6U) ^ rotate_right(e, 11U) ^ rotate_right(e, 25U);
            const std::uint32_t choice = (e & f) ^ ((~e) & g);
            const std::uint32_t temporary1 = h + sum1 + choice + ROUND_CONSTANTS[index] + schedule[index];
            const std::uint32_t sum0 = rotate_right(a, 2U) ^ rotate_right(a, 13U) ^ rotate_right(a, 22U);
            const std::uint32_t majority = (a & b) ^ (a & c) ^ (b & c);
            const std::uint32_t temporary2 = sum0 + majority;
            h = g;
            g = f;
            f = e;
            e = d + temporary1;
            d = c;
            c = b;
            b = a;
            a = temporary1 + temporary2;
        }
        words_[0] += a;
        words_[1] += b;
        words_[2] += c;
        words_[3] += d;
        words_[4] += e;
        words_[5] += f;
        words_[6] += g;
        words_[7] += h;
}

Sha256UpdateStep Sha256State::update_step(const std::uint8_t *data,
    const std::size_t size, const std::size_t byte_quota, const std::size_t block_quota) {
    if (phase_ != 0U) throw std::logic_error("SHA-256 updates are closed");
    if (data == nullptr && size != 0U)
        throw std::invalid_argument("non-empty SHA-256 input has a null data pointer");
    constexpr std::uint64_t MAX_BYTES = std::numeric_limits<std::uint64_t>::max() >> 3U;
    if (size > MAX_BYTES - accepted_bytes_)
        throw std::length_error("SHA-256 input is too large");
    Sha256UpdateStep result{0U, 0U, false};
    const std::size_t allowed = std::min(size, byte_quota);
    while (result.consumed_bytes < allowed) {
        const std::size_t room = 64U - partial_bytes_;
        const std::size_t maximum = result.compressed_blocks < block_quota ? room : room - 1U;
        const std::size_t count = std::min(allowed - result.consumed_bytes, maximum);
        if (count == 0U) break;
        std::memcpy(partial_.data() + partial_bytes_, data + result.consumed_bytes, count);
        partial_bytes_ = static_cast<std::uint8_t>(partial_bytes_ + count);
        accepted_bytes_ += count;
        result.consumed_bytes += count;
        if (partial_bytes_ == 64U) {
            process_block(partial_.data());
            partial_bytes_ = 0U;
            ++result.compressed_blocks;
        }
    }
    result.input_complete = result.consumed_bytes == size;
    return result;
}

Sha256FinishStep Sha256State::finish_step(const std::size_t block_quota) {
    if (phase_ == 2U) return {0U, true};
    if (block_quota == 0U) return {0U, false};
    std::size_t blocks = 0U;
    if (phase_ == 0U) {
        const std::size_t length = partial_bytes_;
        partial_[length] = 0x80U;
        std::fill(partial_.begin() + length + 1U, partial_.end(), 0U);
        phase_ = 1U;
        if (length >= 56U) {
            process_block(partial_.data());
            ++blocks;
            partial_.fill(0U);
            if (blocks == block_quota) return {blocks, false};
        }
    }
    const std::uint64_t bits = accepted_bytes_ * 8U;
    for (std::size_t index = 0U; index < 8U; ++index)
        partial_[63U - index] = static_cast<std::uint8_t>(bits >> (index * 8U));
    process_block(partial_.data());
    ++blocks;
    phase_ = 2U;
    return {blocks, true};
}

Sha256Digest Sha256State::digest() const {
    if (phase_ != 2U) throw std::logic_error("SHA-256 digest is not complete");
    Sha256Digest digest{};
    for (std::size_t index = 0; index < words_.size(); ++index) {
        digest[index * 4U] = static_cast<std::uint8_t>(words_[index] >> 24U);
        digest[index * 4U + 1U] = static_cast<std::uint8_t>(words_[index] >> 16U);
        digest[index * 4U + 2U] = static_cast<std::uint8_t>(words_[index] >> 8U);
        digest[index * 4U + 3U] = static_cast<std::uint8_t>(words_[index]);
    }
    return digest;
}

Sha256Digest sha256(const std::uint8_t *data, const std::size_t size) {
    Sha256State state;
    state.update_step(data, size, size, std::numeric_limits<std::size_t>::max());
    state.finish_step(2U);
    return state.digest();
}

Sha256Digest sha256(const std::vector<std::uint8_t> &bytes) {
    return sha256(bytes.data(), bytes.size());
}

std::string sha256_hex(const Sha256Digest &digest) {
    static constexpr char HEX[] = "0123456789abcdef";
    std::string result;
    result.reserve(digest.size() * 2U);
    for (const std::uint8_t byte : digest) {
        result.push_back(HEX[byte >> 4U]);
        result.push_back(HEX[byte & 0x0fU]);
    }
    return result;
}

} // namespace voxel::world_backend
