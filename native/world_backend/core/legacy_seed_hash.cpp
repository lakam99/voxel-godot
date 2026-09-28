#include "legacy_seed_hash.hpp"

#include <stdexcept>

namespace voxel::world_backend {

bool EvaluatorStamp::operator==(const EvaluatorStamp &other) const noexcept {
    return incarnation == other.incarnation && revision == other.revision
        && configuration == other.configuration && generation == other.generation
        && definition_digest == other.definition_digest;
}
WorkQuota::WorkQuota(const std::size_t offered) noexcept : offered_(offered), remaining_(offered) {}
std::size_t WorkQuota::offered() const noexcept { return offered_; }
std::size_t WorkQuota::remaining() const noexcept { return remaining_; }
bool WorkQuota::try_debit(const std::size_t units) noexcept {
    if (units > remaining_) return false;
    remaining_ -= units;
    return true;
}
LegacyCursor::LegacyCursor() noexcept
    : stamp{}, status(EvalStatus::idle), reason(EvalReason::none), value(2166136261U) {}
DecimalCursor::DecimalCursor() noexcept
    : status(EvalStatus::idle), magnitude(0), digits{}, length(0), emitted(0),
      negative(false), assembled(false) {}

namespace {
EvalStep hash_preflight(LegacyCursor &cursor, const EvaluatorStamp &stamp,
    const WorkQuota &quota) noexcept {
    if (!(cursor.stamp == stamp)) {
        if (quota.remaining() != 0U) {
            cursor.status = EvalStatus::rejected;
            cursor.reason = EvalReason::identity;
        }
        return {EvalStatus::rejected, EvalReason::identity, 0U, 0U};
    }
    if (cursor.status != EvalStatus::pending && cursor.status != EvalStatus::ready)
        return {cursor.status, cursor.reason == EvalReason::none ? EvalReason::phase : cursor.reason, 0U, 0U};
    return {cursor.status, EvalReason::none, 0U, cursor.status == EvalStatus::ready ? 0U : 1U};
}
}
EvalStep begin_hash(LegacyCursor &cursor, const EvaluatorStamp stamp, WorkQuota &quota) noexcept {
    if (cursor.status != EvalStatus::idle && cursor.status != EvalStatus::drained)
        return {EvalStatus::rejected, EvalReason::phase, 0U, 0U};
    if (!quota.try_debit(1U)) return {EvalStatus::pending, EvalReason::quota, 0U, 1U};
    cursor.stamp = stamp;
    cursor.value = 2166136261U;
    cursor.reason = EvalReason::none;
    cursor.status = EvalStatus::pending;
    return {cursor.status, EvalReason::none, 1U, 1U};
}
HashStep append_hash(LegacyCursor &cursor, const EvaluatorStamp stamp,
    const ScalarSpan input, WorkQuota &quota) noexcept {
    const auto checked = hash_preflight(cursor, stamp, quota);
    if (checked.reason != EvalReason::none) return {checked, 0U, 0U};
    if (cursor.status == EvalStatus::ready) return {{EvalStatus::rejected, EvalReason::phase, 0U, 0U}, 0U, 0U};
    if (input.data == nullptr && input.size != 0U) {
        if (quota.remaining() != 0U) { cursor.status = EvalStatus::rejected; cursor.reason = EvalReason::input; }
        return {{EvalStatus::rejected, EvalReason::input, 0U, 0U}, 0U, 0U};
    }
    std::size_t consumed = 0U;
    while (consumed < input.size && quota.remaining() != 0U) {
        // Charge even an invalid examined scalar; never read it at quota zero.
        (void)quota.try_debit(1U);
        const auto scalar = input.data[consumed];
        if (!is_unicode_scalar(scalar)) {
            cursor.status = EvalStatus::rejected; cursor.reason = EvalReason::scalar;
            return {{cursor.status, cursor.reason, consumed + 1U, 0U}, consumed, 0U};
        }
        cursor.value = (cursor.value ^ scalar) * 16777619U;
        ++consumed;
    }
    return {{EvalStatus::pending, consumed == input.size ? EvalReason::none : EvalReason::quota,
        consumed, 1U}, consumed, cursor.value};
}
HashStep finish_hash(LegacyCursor &cursor, const EvaluatorStamp stamp, WorkQuota &quota) noexcept {
    const auto checked = hash_preflight(cursor, stamp, quota);
    if (checked.reason != EvalReason::none) return {checked, 0U, 0U};
    if (cursor.status == EvalStatus::ready) return {checked, 0U, cursor.value};
    if (!quota.try_debit(1U)) return {{EvalStatus::pending, EvalReason::quota, 0U, 1U}, 0U, 0U};
    cursor.status = EvalStatus::ready;
    return {{cursor.status, EvalReason::none, 1U, 0U}, 0U, cursor.value};
}
ControlResult cancel_hash(LegacyCursor &cursor) noexcept {
    cursor.status = EvalStatus::cancelled;
    return {cursor.status, EvalReason::none, 1U};
}
ControlResult reset_hash(LegacyCursor &cursor) noexcept {
    if (cursor.status == EvalStatus::pending) return {EvalStatus::rejected, EvalReason::phase, 1U};
    cursor = LegacyCursor{};
    return {cursor.status, EvalReason::none, 1U};
}
EvalStep begin_decimal(DecimalCursor &cursor, const std::int32_t value, WorkQuota &quota) noexcept {
    if (cursor.status != EvalStatus::idle && cursor.status != EvalStatus::drained)
        return {EvalStatus::rejected, EvalReason::phase, 0U, 0U};
    if (!quota.try_debit(1U)) return {EvalStatus::pending, EvalReason::quota, 0U, 1U};
    cursor.negative = value < 0;
    const auto widened = static_cast<std::int64_t>(value);
    cursor.magnitude = static_cast<std::uint64_t>(cursor.negative ? -widened : widened);
    cursor.length = 0U; cursor.emitted = 0U; cursor.assembled = false;
    cursor.status = EvalStatus::pending;
    return {cursor.status, EvalReason::none, 1U, 1U};
}
DecimalStep advance_decimal(DecimalCursor &cursor, const ByteSpan output, WorkQuota &quota) noexcept {
    if (cursor.status != EvalStatus::pending && cursor.status != EvalStatus::ready)
        return {{cursor.status, EvalReason::phase, 0U, 0U}, 0U, false};
    if (output.data == nullptr && output.size != 0U)
        return {{EvalStatus::rejected, EvalReason::input, 0U, 0U}, 0U, false};
    if (cursor.status == EvalStatus::ready) return {{cursor.status, EvalReason::none, 0U, 0U}, 0U, true};
    const auto before = quota.remaining();
    while (!cursor.assembled && quota.try_debit(1U)) {
        if (cursor.length == 0U || cursor.magnitude != 0U) {
            cursor.digits[cursor.length++] = static_cast<char>('0' + cursor.magnitude % 10U);
            cursor.magnitude /= 10U;
        } else {
            if (cursor.negative) cursor.digits[cursor.length++] = '-';
            cursor.assembled = true;
        }
    }
    std::size_t written = 0U;
    while (cursor.assembled && cursor.emitted < cursor.length && written < output.size && quota.try_debit(1U))
        output.data[written++] = cursor.digits[cursor.length - 1U - cursor.emitted++];
    if (cursor.assembled && cursor.emitted == cursor.length) cursor.status = EvalStatus::ready;
    return {{cursor.status, cursor.status == EvalStatus::ready ? EvalReason::none : EvalReason::quota,
        before - quota.remaining(), cursor.status == EvalStatus::ready ? 0U : 1U}, written,
        cursor.status == EvalStatus::ready};
}
ControlResult cancel_decimal(DecimalCursor &cursor) noexcept {
    cursor.status = EvalStatus::cancelled; return {cursor.status, EvalReason::none, 1U};
}
ControlResult reset_decimal(DecimalCursor &cursor) noexcept {
    if (cursor.status == EvalStatus::pending) return {EvalStatus::rejected, EvalReason::phase, 1U};
    cursor = DecimalCursor{}; return {cursor.status, EvalReason::none, 1U};
}

SeedKeyCursor::SeedKeyCursor() noexcept : hash{}, decimal{}, kind(SeedKeyKind::raw),
    coordinates{}, decimal_bytes{}, decimal_length(0), segment(0), offset(0), decimal_started(false) {}
namespace {
enum class TokenType { end, ascii, seed, decimal };
struct KeyToken { TokenType type; const char *ascii; std::size_t coordinate; };
KeyToken key_token(const SeedKeyKind kind, const std::size_t segment) noexcept {
    if (kind == SeedKeyKind::raw) return {segment == 0U ? TokenType::seed : TokenType::end, nullptr, 0U};
    if (kind == SeedKeyKind::underground) {
        switch (segment) {
        case 0: case 3: return {TokenType::seed, nullptr, 0U};
        case 1: case 4: return {TokenType::ascii, ":", 0U};
        case 2: return {TokenType::ascii, "underground-volume:", 0U};
        case 5: return {TokenType::decimal, nullptr, 0U};
        case 6: case 8: return {TokenType::ascii, ",", 0U};
        case 7: return {TokenType::decimal, nullptr, 1U};
        case 9: return {TokenType::decimal, nullptr, 2U};
        default: return {TokenType::end, nullptr, 0U};
        }
    }
    const bool site = kind == SeedKeyKind::site_x || kind == SeedKeyKind::site_z;
    const bool climate = kind == SeedKeyKind::climate_temperature || kind == SeedKeyKind::climate_moisture;
    const bool temperature = kind == SeedKeyKind::climate_temperature || kind == SeedKeyKind::lattice_temperature;
    if (segment == 0U) return {TokenType::ascii, site
        ? (kind == SeedKeyKind::site_x ? "biome-region-site-x:" : "biome-region-site-z:")
        : (climate ? "biome-region-climate:" : "biome-region-lattice:"), 0U};
    if (segment == 1U) return {TokenType::seed, nullptr, 0U};
    if (segment == 2U) return {TokenType::ascii, ":", 0U};
    if (!site && segment == 3U) return {TokenType::ascii, temperature
        ? (climate ? "temperature" : "temperature-broad")
        : (climate ? "moisture" : "moisture-broad"), 0U};
    if (!site && segment == 4U) return {TokenType::ascii, ":", 0U};
    const auto suffix = site ? segment - 3U : segment - 5U;
    if (suffix == 0U) return {TokenType::decimal, nullptr, 0U};
    if (suffix == 1U) return {TokenType::ascii, ",", 0U};
    if (suffix == 2U) return {TokenType::decimal, nullptr, 2U};
    return {TokenType::end, nullptr, 0U};
}
}
EvalStep begin_seed_key(SeedKeyCursor &cursor, const EvaluatorStamp stamp,
    const SeedKeyKind kind, const std::int32_t x, const std::int32_t y, const std::int32_t z,
    WorkQuota &quota) noexcept {
    if (cursor.hash.status == EvalStatus::pending) return {EvalStatus::rejected, EvalReason::phase, 0U, 0U};
    if (static_cast<std::uint8_t>(kind) > static_cast<std::uint8_t>(SeedKeyKind::lattice_moisture))
        return {EvalStatus::rejected, EvalReason::input, 0U, 0U};
    if (!quota.try_debit(1U)) return {EvalStatus::pending, EvalReason::quota, 0U, 1U};
    cursor = SeedKeyCursor{}; cursor.kind = kind; cursor.coordinates = {x, y, z};
    cursor.hash.stamp = stamp; cursor.hash.status = EvalStatus::pending;
    return {EvalStatus::pending, EvalReason::none, 1U, 1U};
}
HashStep advance_seed_key(SeedKeyCursor &cursor, const EvaluatorStamp stamp,
    const ScalarSpan seed, WorkQuota &quota) noexcept {
    const auto checked = hash_preflight(cursor.hash, stamp, quota);
    if (checked.reason != EvalReason::none) return {checked, 0U, 0U};
    if (cursor.hash.status == EvalStatus::ready) return {checked, 0U, cursor.hash.value};
    if (seed.data == nullptr && seed.size != 0U) {
        if (quota.remaining() != 0U) { cursor.hash.status = EvalStatus::rejected; cursor.hash.reason = EvalReason::input; }
        return {{EvalStatus::rejected, EvalReason::input, 0U, 0U}, 0U, 0U};
    }
    const auto before = quota.remaining();
    while (quota.remaining() != 0U) {
        const auto token = key_token(cursor.kind, cursor.segment);
        if (token.type == TokenType::end) {
            const auto finished = finish_hash(cursor.hash, stamp, quota);
            return {{finished.step.status, finished.step.reason, before - quota.remaining(),
                finished.step.next_atomic_work}, 0U, finished.value};
        }
        if (token.type == TokenType::decimal) {
            if (!cursor.decimal_started) {
                const auto begun = begin_decimal(cursor.decimal, cursor.coordinates[token.coordinate], quota);
                if (begun.consumed_work == 0U) break;
                cursor.decimal_started = true;
            }
            if (cursor.decimal.status != EvalStatus::ready) {
                const auto step = advance_decimal(cursor.decimal,
                    {cursor.decimal_bytes.data() + cursor.decimal_length,
                        cursor.decimal_bytes.size() - cursor.decimal_length}, quota);
                cursor.decimal_length += step.written_bytes;
                if (!step.output_complete) break;
            }
        }
        if (quota.remaining() == 0U) break;
        std::uint32_t scalar = 0U;
        bool end = false;
        if (token.type == TokenType::seed) {
            if (cursor.offset > seed.size) {
                cursor.hash.status = EvalStatus::rejected; cursor.hash.reason = EvalReason::input;
                return {{cursor.hash.status, cursor.hash.reason, before - quota.remaining(), 0U}, 0U, 0U};
            }
            end = cursor.offset == seed.size;
            if (!end) scalar = seed.data[cursor.offset];
        } else if (token.type == TokenType::ascii) {
            scalar = static_cast<unsigned char>(token.ascii[cursor.offset]); end = scalar == 0U;
        } else {
            end = cursor.offset == cursor.decimal_length;
            if (!end) scalar = static_cast<unsigned char>(cursor.decimal_bytes[cursor.offset]);
        }
        // Even empty-token transitions cost one; no uncharged string scans.
        if (!quota.try_debit(1U)) break;
        if (end) {
            ++cursor.segment; cursor.offset = 0U;
            cursor.decimal = DecimalCursor{}; cursor.decimal_length = 0U; cursor.decimal_started = false;
        } else if (!is_unicode_scalar(scalar)) {
            cursor.hash.status = EvalStatus::rejected; cursor.hash.reason = EvalReason::scalar;
            return {{cursor.hash.status, cursor.hash.reason, before - quota.remaining(), 0U}, 0U, 0U};
        } else {
            cursor.hash.value = (cursor.hash.value ^ scalar) * 16777619U; ++cursor.offset;
        }
    }
    return {{EvalStatus::pending, EvalReason::quota, before - quota.remaining(), 1U}, 0U, cursor.hash.value};
}

bool is_unicode_scalar(const std::uint32_t code_point) noexcept {
    return code_point <= 0x10ffffU && !(code_point >= 0xd800U && code_point <= 0xdfffU);
}

std::uint32_t legacy_seed_hash(const std::vector<std::uint32_t> &code_points) {
    std::uint32_t hash = 2166136261U;
    for (const std::uint32_t code_point : code_points) {
        if (!is_unicode_scalar(code_point)) {
            throw std::invalid_argument("seed contains an invalid Unicode scalar value");
        }
        hash ^= code_point;
        hash *= 16777619U;
    }
    return hash;
}

} // namespace voxel::world_backend
