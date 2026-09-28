#pragma once

#include <cstdint>
#include <cstddef>
#include <array>
#include <vector>

namespace voxel::world_backend {

bool is_unicode_scalar(std::uint32_t code_point) noexcept;
std::uint32_t legacy_seed_hash(const std::vector<std::uint32_t> &code_points);

// Caller continuity, not authentication. The caller reacquires the genuine
// immutable definition on each step; no cursor retains that definition.
struct EvaluatorStamp {
    std::uint64_t incarnation = 0;
    std::uint64_t revision = 0;
    std::uint64_t configuration = 0;
    std::uint64_t generation = 0;
    std::array<std::uint8_t, 32> definition_digest{};
    bool operator==(const EvaluatorStamp &other) const noexcept;
};
enum class EvalStatus : std::uint8_t { idle, pending, ready, rejected, cancelled, drained };
enum class EvalReason : std::uint8_t {
    none, quota, identity, phase, scalar, input, storage, generation, in_use
};
struct EvalStep {
    EvalStatus status;
    EvalReason reason;
    std::size_t consumed_work;
    std::size_t next_atomic_work;
};
struct ControlResult { EvalStatus status; EvalReason reason; std::size_t control_cost; };
class WorkQuota final {
public:
    // Logical work, not wall-clock time. Suboperations share this same object;
    // zero-quota stepping is observational only. Administrative cancel/reset
    // receipts have fixed control cost and never create a fresh work allowance.
    explicit WorkQuota(std::size_t offered) noexcept;
    std::size_t offered() const noexcept;
    std::size_t remaining() const noexcept;
    bool try_debit(std::size_t units) noexcept;
private:
    std::size_t offered_;
    std::size_t remaining_;
};
struct ScalarSpan { const std::uint32_t *data; std::size_t size; };
struct ByteSpan { char *data; std::size_t size; };
struct HashStep { EvalStep step; std::size_t consumed_scalars; std::uint32_t value; };
struct DecimalStep { EvalStep step; std::size_t written_bytes; bool output_complete; };
struct LegacyCursor {
    LegacyCursor() noexcept;
    EvaluatorStamp stamp;
    EvalStatus status;
    EvalReason reason;
    std::uint32_t value;
};
struct DecimalCursor {
    DecimalCursor() noexcept;
    EvalStatus status;
    std::uint64_t magnitude;
    std::array<char, 11> digits;
    std::size_t length;
    std::size_t emitted;
    bool negative;
    bool assembled;
};
EvalStep begin_hash(LegacyCursor &, EvaluatorStamp, WorkQuota &) noexcept;
HashStep append_hash(LegacyCursor &, EvaluatorStamp, ScalarSpan, WorkQuota &) noexcept;
HashStep finish_hash(LegacyCursor &, EvaluatorStamp, WorkQuota &) noexcept;
ControlResult cancel_hash(LegacyCursor &) noexcept;
ControlResult reset_hash(LegacyCursor &) noexcept;
EvalStep begin_decimal(DecimalCursor &, std::int32_t, WorkQuota &) noexcept;
DecimalStep advance_decimal(DecimalCursor &, ByteSpan, WorkQuota &) noexcept;
ControlResult cancel_decimal(DecimalCursor &) noexcept;
ControlResult reset_decimal(DecimalCursor &) noexcept;

// Fixed token recipes; borrowed seed is supplied afresh, never saved. A hash
// reset discards its prefix and may reuse a source stamp for another key;
// placement NoiseCursor generation nonreuse is a separate ownership rule.
enum class SeedKeyKind : std::uint8_t {
    raw, underground, site_x, site_z, climate_temperature, climate_moisture,
    lattice_temperature, lattice_moisture
};
struct SeedKeyCursor {
    SeedKeyCursor() noexcept;
    LegacyCursor hash;
    DecimalCursor decimal;
    SeedKeyKind kind;
    std::array<std::int32_t, 3> coordinates;
    std::array<char, 11> decimal_bytes;
    std::size_t decimal_length;
    std::size_t segment;
    std::size_t offset;
    bool decimal_started;
};
EvalStep begin_seed_key(SeedKeyCursor &, EvaluatorStamp, SeedKeyKind,
    std::int32_t x, std::int32_t y, std::int32_t z, WorkQuota &) noexcept;
HashStep advance_seed_key(SeedKeyCursor &, EvaluatorStamp, ScalarSpan seed, WorkQuota &) noexcept;

} // namespace voxel::world_backend
