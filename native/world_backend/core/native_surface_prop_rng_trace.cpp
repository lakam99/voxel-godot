#include "native_surface_prop_rng_trace.hpp"

#include "godot_pcg_compat.hpp"

#include <cstring>
#include <utility>

namespace voxel::world_backend {
namespace {

[[noreturn]] void reject() { throw NativeSurfacePropRngTraceRejected(); }

bool is_zero_digest(const Sha256Digest &digest) noexcept {
    for (const std::uint8_t byte : digest) if (byte != 0U) return false;
    return true;
}

bool valid_source_receipt(const NativeSurfacePropSourceReceipt &receipt) noexcept {
    return receipt.schema_revision == NativeSurfacePropSourceReceipt::SCHEMA_REVISION
        && !is_zero_digest(receipt.effective_source_digest)
        && receipt.environment_profile_revision != 0U
        && !is_zero_digest(receipt.environment_profile_digest);
}

bool valid_disposition(const NativeSurfacePropReplayDisposition value) noexcept {
    return value == NativeSurfacePropReplayDisposition::skipped_before_prop_roll
        || value == NativeSurfacePropReplayDisposition::no_feature
        || value == NativeSurfacePropReplayDisposition::ordinary_rock
        || value == NativeSurfacePropReplayDisposition::broadleaf_tree
        || value == NativeSurfacePropReplayDisposition::conifer_tree;
}

std::size_t recipe_draw_count(const NativeSurfacePropReplayDisposition value) noexcept {
    switch (value) {
    case NativeSurfacePropReplayDisposition::ordinary_rock: return 6U;
    case NativeSurfacePropReplayDisposition::broadleaf_tree: return 36U;
    case NativeSurfacePropReplayDisposition::conifer_tree: return 22U;
    default: return 0U;
    }
}

class CanonicalWriter final {
public:
    void u8(const std::uint8_t value) { bytes_.push_back(value); }
    void u32(const std::uint32_t value) {
        for (int shift = 24; shift >= 0; shift -= 8) u8(static_cast<std::uint8_t>(value >> shift));
    }
    void u64(const std::uint64_t value) {
        for (int shift = 56; shift >= 0; shift -= 8) u8(static_cast<std::uint8_t>(value >> shift));
    }
    void digest(const Sha256Digest &value) { bytes_.insert(bytes_.end(), value.begin(), value.end()); }
    void number(const float value) {
        std::uint32_t bits = 0U;
        std::memcpy(&bits, &value, sizeof(bits));
        u32(bits);
    }
    std::vector<std::uint8_t> finish() { return std::move(bytes_); }
private:
    std::vector<std::uint8_t> bytes_;
};

std::vector<std::uint8_t> canonical_trace_binary(
    const NativeSurfacePropSourceReceipt &source_receipt,
    const std::array<NativeSurfacePropRngTraceEntry, NativeSurfacePropAttemptStream::ATTEMPT_COUNT> &entries,
    const std::uint64_t final_rng_state) {
    CanonicalWriter writer;
    writer.u8('S'); writer.u8('P'); writer.u8('T'); writer.u8('2');
    writer.u32(source_receipt.schema_revision); writer.digest(source_receipt.effective_source_digest);
    writer.u64(source_receipt.terrain_delta_revision); writer.u64(source_receipt.shaping_registry_revision);
    writer.u32(source_receipt.environment_profile_revision);
    writer.digest(source_receipt.environment_profile_digest);
    writer.u32(static_cast<std::uint32_t>(entries.size()));
    for (const NativeSurfacePropRngTraceEntry &entry : entries) {
        writer.u32(entry.ordinal); writer.u8(static_cast<std::uint8_t>(entry.disposition));
        writer.u64(entry.state_before_coordinates); writer.u64(entry.state_after_coordinates);
        writer.u64(entry.state_after_recipe); writer.u8(entry.has_prop_roll ? 1U : 0U);
        writer.number(entry.prop_roll); writer.u32(static_cast<std::uint32_t>(entry.recipe_draws.size()));
        for (const float draw : entry.recipe_draws) writer.number(draw);
    }
    writer.u64(final_rng_state);
    return writer.finish();
}

} // namespace

NativeSurfacePropRngTraceRejected::NativeSurfacePropRngTraceRejected()
    : std::invalid_argument("invalid native surface-prop RNG trace") {}

NativeSurfacePropSourceReceipt NativeSurfacePropSourceReceipt::from_pin(
    const WorldSourcePin &pin, const std::uint32_t environment_profile_revision,
    Sha256Digest environment_profile_digest) {
    NativeSurfacePropSourceReceipt receipt;
    receipt.effective_source_digest = pin.physical_content_identity().digest;
    receipt.terrain_delta_revision = pin.terrain_delta_revision();
    receipt.shaping_registry_revision = pin.shaping_registry_revision();
    receipt.environment_profile_revision = environment_profile_revision;
    receipt.environment_profile_digest = environment_profile_digest;
    if (!valid_source_receipt(receipt)) reject();
    return receipt;
}

bool NativeSurfacePropSourceReceipt::matches_pin(const WorldSourcePin &pin) const noexcept {
    return valid_source_receipt(*this)
        && effective_source_digest == pin.physical_content_identity().digest
        && terrain_delta_revision == pin.terrain_delta_revision()
        && shaping_registry_revision == pin.shaping_registry_revision();
}

NativeSurfacePropRngTrace::NativeSurfacePropRngTrace(
    NativeSurfacePropSourceReceipt source_receipt,
    std::array<NativeSurfacePropRngTraceEntry, NativeSurfacePropAttemptStream::ATTEMPT_COUNT> entries,
    const std::uint64_t final_rng_state, std::vector<std::uint8_t> canonical_binary,
    Sha256Digest content_digest) noexcept
    : source_receipt_(std::move(source_receipt)), entries_(std::move(entries)),
      final_rng_state_(final_rng_state), canonical_binary_(std::move(canonical_binary)),
      content_digest_(content_digest) {}

NativeSurfacePropRngTrace NativeSurfacePropRngTrace::create(
    const NativeSurfacePropAttemptStream &attempt_stream,
    NativeSurfacePropSourceReceipt source_receipt,
    const std::vector<NativeSurfacePropReplayReceipt> &receipts) {
    if (!valid_source_receipt(source_receipt)
        || receipts.size() != NativeSurfacePropAttemptStream::ATTEMPT_COUNT) reject();
    GodotPcg32 rng(attempt_stream.rng_seed());
    std::array<NativeSurfacePropRngTraceEntry, NativeSurfacePropAttemptStream::ATTEMPT_COUNT> entries{};
    for (std::size_t index = 0U; index < receipts.size(); ++index) {
        const NativeSurfacePropReplayReceipt &receipt = receipts[index];
        const NativeSurfacePropAttempt &attempt = attempt_stream.attempts()[index];
        if (receipt.ordinal != index || receipt.durable_id != attempt.durable_id
            || !valid_disposition(receipt.disposition)) reject();
        NativeSurfacePropRngTraceEntry entry;
        entry.ordinal = receipt.ordinal;
        entry.disposition = receipt.disposition;
        entry.state_before_coordinates = rng.state();
        // Replaying the coordinates proves this trace is bound to the same
        // source stream rather than merely trusting a matching opaque ID.
        static_cast<void>(rng.randi_range(0, NativeSurfacePropAttemptStream::CHUNK_CELLS - 4));
        static_cast<void>(rng.randi_range(0, NativeSurfacePropAttemptStream::CHUNK_CELLS - 4));
        entry.state_after_coordinates = rng.state();
        if (receipt.disposition != NativeSurfacePropReplayDisposition::skipped_before_prop_roll) {
            entry.has_prop_roll = true;
            entry.prop_roll = rng.randf();
            entry.recipe_draws.reserve(recipe_draw_count(receipt.disposition));
            for (std::size_t draw = 0U; draw < recipe_draw_count(receipt.disposition); ++draw) {
                entry.recipe_draws.push_back(rng.randf());
            }
        }
        entry.state_after_recipe = rng.state();
        entries[index] = std::move(entry);
    }
    std::vector<std::uint8_t> canonical = canonical_trace_binary(source_receipt, entries, rng.state());
    return NativeSurfacePropRngTrace(
        std::move(source_receipt), std::move(entries), rng.state(), canonical, sha256(canonical));
}

const std::array<NativeSurfacePropRngTraceEntry, NativeSurfacePropAttemptStream::ATTEMPT_COUNT> &
NativeSurfacePropRngTrace::entries() const noexcept { return entries_; }
const NativeSurfacePropSourceReceipt &NativeSurfacePropRngTrace::source_receipt() const noexcept {
    return source_receipt_;
}
std::uint64_t NativeSurfacePropRngTrace::final_rng_state() const noexcept { return final_rng_state_; }
const std::vector<std::uint8_t> &NativeSurfacePropRngTrace::canonical_binary() const noexcept {
    return canonical_binary_;
}
const Sha256Digest &NativeSurfacePropRngTrace::content_digest() const noexcept { return content_digest_; }

} // namespace voxel::world_backend
