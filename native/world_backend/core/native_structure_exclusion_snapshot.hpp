#pragma once

#include "sha256.hpp"

#include <cstdint>
#include <stdexcept>
#include <string>
#include <vector>

namespace voxel::world_backend {

struct StructureExclusionRect final {
    std::int32_t min_x = 0;
    std::int32_t min_z = 0;
    std::int32_t max_x = 0;
    std::int32_t max_z = 0;
};

struct StructureExclusionRecord final {
    std::string id;
    StructureExclusionRect bounds; // Inclusive maximum, as in StructureSystem.
};

enum class CitadelSourceStatus : std::uint8_t {
    absent = 0,
    pending = 1,
    failed = 2,
    ready = 3,
    prepared = 4,
};

struct CitadelExclusionSource final {
    std::int32_t region_x = 0;
    std::int32_t region_z = 0;
    CitadelSourceStatus status = CitadelSourceStatus::absent;
    std::string reason;
    std::string source_key;
    std::string source_signature;
    std::uint64_t admission_generation = 0;
    // Half-open Rect2i reservation: max is the exclusive end.
    StructureExclusionRect reservation;
};

struct StructureExclusionBoundsAdmission final {
    // Exact live CHUNK_SIZE=28 request_bounds origin, not a site cache hit.
    std::int32_t min_x = 0;
    std::int32_t min_z = 0;
    bool ready = false;
};

enum class StructureExclusionKind : std::uint8_t {
    clear = 0,
    natural = 1,
    terrain = 2,
    citadel = 3,
    unresolved = 4,
};

struct StructureExclusionDecision final {
    bool blocked = false;
    bool complete = false;
    StructureExclusionKind kind = StructureExclusionKind::unresolved;
    std::string source_id;
};

class NativeStructureExclusionRejected final : public std::invalid_argument {
public:
    NativeStructureExclusionRejected();
};

// Shadow-only immutable query value. The owning StructureSystem must capture
// source records after exact request_bounds admission, on the main thread.
// A production capture should use one admitted 28x28 chunk and only natural,
// terrain, and Citadel records intersecting that footprint. This keeps the
// content digest local; world/reset generation is a separate identity.
class NativeStructureExclusionSnapshot final {
public:
    static NativeStructureExclusionSnapshot create(
        Sha256Digest world_digest,
        std::uint64_t world_generation,
        std::vector<StructureExclusionRecord> natural,
        std::vector<StructureExclusionRecord> terrain,
        std::vector<CitadelExclusionSource> citadels,
        std::vector<StructureExclusionBoundsAdmission> admitted_bounds);

    StructureExclusionDecision query(std::int32_t x, std::int32_t z) const;
    // Inclusive cell rectangle. The caller separately requires exact ready
    // bounds admission; within it, an unrequested candidate is irrelevant.
    bool covers_decided_regions(std::int32_t min_x, std::int32_t min_z,
                                std::int32_t max_x, std::int32_t max_z) const noexcept;
    const Sha256Digest &world_digest() const noexcept;
    std::uint64_t world_generation() const noexcept;
    const Sha256Digest &content_digest() const noexcept;
    const std::vector<StructureExclusionRecord> &natural() const noexcept;
    const std::vector<StructureExclusionRecord> &terrain() const noexcept;
    const std::vector<CitadelExclusionSource> &citadels() const noexcept;
    const std::vector<StructureExclusionBoundsAdmission> &admitted_bounds() const noexcept;

private:
    NativeStructureExclusionSnapshot(Sha256Digest world_digest,
                                     std::uint64_t world_generation,
                                     std::vector<StructureExclusionRecord> natural,
                                     std::vector<StructureExclusionRecord> terrain,
                                     std::vector<CitadelExclusionSource> citadels,
                                     std::vector<StructureExclusionBoundsAdmission> admitted_bounds,
                                     Sha256Digest content_digest);

    Sha256Digest world_digest_{};
    std::uint64_t world_generation_ = 0;
    std::vector<StructureExclusionRecord> natural_;
    std::vector<StructureExclusionRecord> terrain_;
    std::vector<CitadelExclusionSource> citadels_;
    std::vector<StructureExclusionBoundsAdmission> admitted_bounds_;
    Sha256Digest content_digest_{};
};

} // namespace voxel::world_backend
