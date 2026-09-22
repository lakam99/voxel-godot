#include "native_surface_prop_attempt_stream.hpp"

#include "legacy_seed_hash.hpp"

#include <limits>
#include <utility>
#include <vector>

namespace voxel::world_backend {
namespace {

void append_ascii(std::vector<std::uint32_t> &target, const std::string &value) {
    for (const unsigned char byte : value) target.push_back(byte);
}

std::int32_t checked_chunk_cell(const std::int32_t chunk, const std::int32_t offset) {
    const std::int64_t value = static_cast<std::int64_t>(chunk)
        * NativeSurfacePropAttemptStream::CHUNK_CELLS + offset;
    if (value < std::numeric_limits<std::int32_t>::min()
        || value > std::numeric_limits<std::int32_t>::max()) {
        throw NativeSurfacePropAttemptStreamRejected();
    }
    return static_cast<std::int32_t>(value);
}

std::uint32_t stream_seed(
    const AdmittedTerrainSeed &seed, const std::int32_t chunk_x, const std::int32_t chunk_z) {
    try {
        const AdmittedTerrainSeed admitted = validate_admitted_raw_terrain_seed(
            seed.code_points, seed.utf8, seed.admitted);
        std::vector<std::uint32_t> key = admitted.code_points;
        append_ascii(key, ":props:" + std::to_string(chunk_x) + "," + std::to_string(chunk_z));
        return legacy_seed_hash(key);
    } catch (const std::invalid_argument &) {
        throw NativeSurfacePropAttemptStreamRejected();
    }
}

} // namespace

bool NativeSurfacePropAttempt::operator==(const NativeSurfacePropAttempt &other) const noexcept {
    return ordinal == other.ordinal && cell_x == other.cell_x && cell_z == other.cell_z
        && durable_id == other.durable_id;
}

NativeSurfacePropAttemptStreamRejected::NativeSurfacePropAttemptStreamRejected()
    : std::invalid_argument("invalid native surface-prop attempt stream") {}

NativeSurfacePropAttemptStream::NativeSurfacePropAttemptStream(
    const std::uint32_t rng_seed, const std::uint64_t final_rng_state,
    std::array<NativeSurfacePropAttempt, ATTEMPT_COUNT> attempts) noexcept
    : rng_seed_(rng_seed), final_rng_state_(final_rng_state), attempts_(std::move(attempts)) {}

NativeSurfacePropAttemptStream NativeSurfacePropAttemptStream::create(
    const AdmittedTerrainSeed &seed, const std::int32_t chunk_x, const std::int32_t chunk_z) {
    const std::uint32_t seed_value = stream_seed(seed, chunk_x, chunk_z);
    GodotPcg32 rng(seed_value);
    std::array<NativeSurfacePropAttempt, ATTEMPT_COUNT> attempts{};
    constexpr std::int32_t span = CHUNK_CELLS - EDGE_MARGIN_CELLS * 2;
    for (std::uint32_t ordinal = 0U; ordinal < ATTEMPT_COUNT; ++ordinal) {
        const std::int32_t cell_x = checked_chunk_cell(chunk_x,
            EDGE_MARGIN_CELLS + static_cast<std::int32_t>(rng.randi_range(0, span)));
        const std::int32_t cell_z = checked_chunk_cell(chunk_z,
            EDGE_MARGIN_CELLS + static_cast<std::int32_t>(rng.randi_range(0, span)));
        attempts[ordinal] = {ordinal, cell_x, cell_z,
            seed.utf8 + ":" + std::to_string(cell_x) + "," + std::to_string(cell_z)
                + ":" + std::to_string(ordinal)};
    }
    return NativeSurfacePropAttemptStream(seed_value, rng.state(), std::move(attempts));
}

std::uint32_t NativeSurfacePropAttemptStream::rng_seed() const noexcept { return rng_seed_; }
std::uint64_t NativeSurfacePropAttemptStream::final_rng_state() const noexcept { return final_rng_state_; }
const std::array<NativeSurfacePropAttempt, NativeSurfacePropAttemptStream::ATTEMPT_COUNT> &
NativeSurfacePropAttemptStream::attempts() const noexcept { return attempts_; }

} // namespace voxel::world_backend
