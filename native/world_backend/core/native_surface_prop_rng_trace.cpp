#include "native_surface_prop_rng_trace.hpp"

#include "godot_pcg_compat.hpp"

#include <utility>

namespace voxel::world_backend {
namespace {

[[noreturn]] void reject() { throw NativeSurfacePropRngTraceRejected(); }

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

} // namespace

NativeSurfacePropRngTraceRejected::NativeSurfacePropRngTraceRejected()
    : std::invalid_argument("invalid native surface-prop RNG trace") {}

NativeSurfacePropRngTrace::NativeSurfacePropRngTrace(
    std::array<NativeSurfacePropRngTraceEntry, NativeSurfacePropAttemptStream::ATTEMPT_COUNT> entries,
    const std::uint64_t final_rng_state) noexcept
    : entries_(std::move(entries)), final_rng_state_(final_rng_state) {}

NativeSurfacePropRngTrace NativeSurfacePropRngTrace::create(
    const NativeSurfacePropAttemptStream &attempt_stream,
    const std::vector<NativeSurfacePropReplayReceipt> &receipts) {
    if (receipts.size() != NativeSurfacePropAttemptStream::ATTEMPT_COUNT) reject();
    GodotPcg32 rng(attempt_stream.rng_seed());
    std::array<NativeSurfacePropRngTraceEntry, NativeSurfacePropAttemptStream::ATTEMPT_COUNT> entries{};
    for (std::size_t index = 0U; index < receipts.size(); ++index) {
        const NativeSurfacePropReplayReceipt &receipt = receipts[index];
        const NativeSurfacePropAttempt &attempt = attempt_stream.attempts()[index];
        if (receipt.ordinal != index || receipt.durable_id != attempt.durable_id
            || !valid_disposition(receipt.disposition)) reject();
        NativeSurfacePropRngTraceEntry entry;
        entry.ordinal = receipt.ordinal;
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
    return NativeSurfacePropRngTrace(std::move(entries), rng.state());
}

const std::array<NativeSurfacePropRngTraceEntry, NativeSurfacePropAttemptStream::ATTEMPT_COUNT> &
NativeSurfacePropRngTrace::entries() const noexcept { return entries_; }
std::uint64_t NativeSurfacePropRngTrace::final_rng_state() const noexcept { return final_rng_state_; }

} // namespace voxel::world_backend
