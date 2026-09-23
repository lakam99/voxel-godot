#include "native_structure_exclusion_snapshot.hpp"

#include <algorithm>
#include <array>
#include <cstddef>
#include <cstdint>
#include <limits>
#include <tuple>
#include <utility>

namespace voxel::world_backend {
namespace {

constexpr std::size_t MAX_RECORDS = 65536U;
constexpr std::size_t MAX_TEXT_BYTES = 1024U;
constexpr std::size_t MAX_CANONICAL_BYTES = 16U * 1024U * 1024U;
constexpr std::int64_t CITADEL_REGION_SIZE = 2048;
constexpr std::int64_t PROP_CHUNK_SIZE = 28;

void reject_if(bool invalid) {
    if (invalid) {
        throw NativeStructureExclusionRejected();
    }
}

bool nonzero(const Sha256Digest &digest) {
    return std::any_of(digest.begin(), digest.end(), [](std::uint8_t byte) { return byte != 0; });
}

bool valid_text(const std::string &value, bool required = true) {
    if (value.size() > MAX_TEXT_BYTES || (required && value.empty())) {
        return false;
    }
    return std::none_of(value.begin(), value.end(), [](char c) { return c == '\0'; });
}

bool inclusive_contains(const StructureExclusionRect &rect, std::int32_t x, std::int32_t z) {
    return x >= rect.min_x && x <= rect.max_x && z >= rect.min_z && z <= rect.max_z;
}

bool half_open_contains(const StructureExclusionRect &rect, std::int32_t x, std::int32_t z) {
    return x >= rect.min_x && x < rect.max_x && z >= rect.min_z && z < rect.max_z;
}

std::int64_t floor_grid(std::int32_t cell, std::int64_t size) {
    const auto wide = static_cast<std::int64_t>(cell);
    return wide >= 0 ? wide / size : (wide - (size - 1)) / size;
}

void append_u32(std::vector<std::uint8_t> &bytes, std::uint32_t value) {
    for (int shift = 24; shift >= 0; shift -= 8) {
        bytes.push_back(static_cast<std::uint8_t>(value >> shift));
    }
}

void append_u64(std::vector<std::uint8_t> &bytes, std::uint64_t value) {
    for (int shift = 56; shift >= 0; shift -= 8) {
        bytes.push_back(static_cast<std::uint8_t>(value >> shift));
    }
}

void append_i32(std::vector<std::uint8_t> &bytes, std::int32_t value) {
    append_u32(bytes, static_cast<std::uint32_t>(value));
}

void append_text(std::vector<std::uint8_t> &bytes, const std::string &value) {
    append_u32(bytes, static_cast<std::uint32_t>(value.size()));
    bytes.insert(bytes.end(), value.begin(), value.end());
}

void append_rect(std::vector<std::uint8_t> &bytes, const StructureExclusionRect &rect) {
    append_i32(bytes, rect.min_x);
    append_i32(bytes, rect.min_z);
    append_i32(bytes, rect.max_x);
    append_i32(bytes, rect.max_z);
}

void append_records(std::vector<std::uint8_t> &bytes, const std::vector<StructureExclusionRecord> &records) {
    append_u32(bytes, static_cast<std::uint32_t>(records.size()));
    for (const auto &record : records) {
        append_text(bytes, record.id);
        append_rect(bytes, record.bounds);
    }
}

bool record_less(const StructureExclusionRecord &left, const StructureExclusionRecord &right) {
    return left.id < right.id;
}

bool citadel_less(const CitadelExclusionSource &left, const CitadelExclusionSource &right) {
    return std::tie(left.region_z, left.region_x) < std::tie(right.region_z, right.region_x);
}

bool bounds_less(const StructureExclusionBoundsAdmission &left,
                 const StructureExclusionBoundsAdmission &right) {
    return std::tie(left.min_z, left.min_x) < std::tie(right.min_z, right.min_x);
}

void validate_bounds(std::vector<StructureExclusionBoundsAdmission> &bounds) {
    reject_if(bounds.empty() || bounds.size() > MAX_RECORDS);
    std::sort(bounds.begin(), bounds.end(), bounds_less);
    for (std::size_t i = 0; i < bounds.size(); ++i) {
        const auto &receipt = bounds[i];
        reject_if(!receipt.ready || receipt.min_x % PROP_CHUNK_SIZE != 0 ||
                  receipt.min_z % PROP_CHUNK_SIZE != 0 ||
                  (i != 0 && receipt.min_x == bounds[i - 1].min_x &&
                   receipt.min_z == bounds[i - 1].min_z));
    }
}

void validate_records(std::vector<StructureExclusionRecord> &records) {
    reject_if(records.size() > MAX_RECORDS);
    std::sort(records.begin(), records.end(), record_less);
    for (std::size_t i = 0; i < records.size(); ++i) {
        const auto &record = records[i];
        reject_if(!valid_text(record.id) || record.bounds.min_x > record.bounds.max_x ||
                  record.bounds.min_z > record.bounds.max_z ||
                  (i != 0 && records[i - 1].id == record.id));
    }
}

void validate_citadels(std::vector<CitadelExclusionSource> &records) {
    reject_if(records.size() > MAX_RECORDS);
    std::sort(records.begin(), records.end(), citadel_less);
    for (std::size_t i = 0; i < records.size(); ++i) {
        const auto &source = records[i];
        reject_if(i != 0 && source.region_x == records[i - 1].region_x &&
                  source.region_z == records[i - 1].region_z);
        const bool physical = source.status == CitadelSourceStatus::ready ||
                              source.status == CitadelSourceStatus::prepared;
        const bool nonphysical = source.status == CitadelSourceStatus::absent ||
                                 source.status == CitadelSourceStatus::pending ||
                                 source.status == CitadelSourceStatus::failed;
        reject_if(!physical && !nonphysical);
        if (physical) {
            reject_if(!source.reason.empty() || !valid_text(source.source_key) ||
                      !valid_text(source.source_signature) || source.admission_generation == 0 ||
                      source.reservation.min_x >= source.reservation.max_x ||
                      source.reservation.min_z >= source.reservation.max_z);
        } else {
            // A decided absent source can retain its sourceKey receipt and an
            // empty reason. An unrequested lookup has only its reason. Neither
            // carries reservation geometry or a physical signature.
            reject_if(!valid_text(source.reason, source.status != CitadelSourceStatus::absent) ||
                      !valid_text(source.source_key, false) ||
                      (source.status != CitadelSourceStatus::absent && !source.source_key.empty()) ||
                      !source.source_signature.empty() || source.admission_generation != 0 ||
                      source.reservation.min_x != 0 || source.reservation.min_z != 0 ||
                      source.reservation.max_x != 0 || source.reservation.max_z != 0);
        }
    }
}

} // namespace

NativeStructureExclusionRejected::NativeStructureExclusionRejected()
    : std::invalid_argument("invalid native structure exclusion snapshot") {}

NativeStructureExclusionSnapshot::NativeStructureExclusionSnapshot(
    Sha256Digest world_digest, std::uint64_t world_generation,
    std::vector<StructureExclusionRecord> natural,
    std::vector<StructureExclusionRecord> terrain,
    std::vector<CitadelExclusionSource> citadels,
    std::vector<StructureExclusionBoundsAdmission> admitted_bounds,
    Sha256Digest content_digest)
    : world_digest_(world_digest), world_generation_(world_generation),
      natural_(std::move(natural)), terrain_(std::move(terrain)),
      citadels_(std::move(citadels)), admitted_bounds_(std::move(admitted_bounds)),
      content_digest_(content_digest) {}

NativeStructureExclusionSnapshot NativeStructureExclusionSnapshot::create(
    Sha256Digest world_digest, std::uint64_t world_generation,
    std::vector<StructureExclusionRecord> natural,
    std::vector<StructureExclusionRecord> terrain,
    std::vector<CitadelExclusionSource> citadels,
    std::vector<StructureExclusionBoundsAdmission> admitted_bounds) {
    reject_if(!nonzero(world_digest) || world_generation == 0);
    validate_records(natural);
    validate_records(terrain);
    validate_citadels(citadels);
    validate_bounds(admitted_bounds);
    std::vector<std::uint8_t> bytes{'S', 'E', 'S', '1'};
    // World/reset ownership is a separate snapshot identity. Local semantic
    // content may be reused only when both that owner and this digest match.
    append_records(bytes, natural);
    append_records(bytes, terrain);
    append_u32(bytes, static_cast<std::uint32_t>(admitted_bounds.size()));
    for (const auto &receipt : admitted_bounds) {
        append_i32(bytes, receipt.min_x);
        append_i32(bytes, receipt.min_z);
    }
    append_u32(bytes, static_cast<std::uint32_t>(citadels.size()));
    for (const auto &source : citadels) {
        append_i32(bytes, source.region_x);
        append_i32(bytes, source.region_z);
        // Resident "ready" and reconstructible "prepared" name the same
        // durable physical source. Cache residency is not content identity.
        const auto status = source.status == CitadelSourceStatus::prepared
                                ? CitadelSourceStatus::ready : source.status;
        bytes.push_back(static_cast<std::uint8_t>(status));
        append_text(bytes, source.reason);
        append_text(bytes, source.source_key);
        append_text(bytes, source.source_signature);
        append_u64(bytes, source.admission_generation);
        append_rect(bytes, source.reservation);
    }
    reject_if(bytes.size() > MAX_CANONICAL_BYTES);
    return NativeStructureExclusionSnapshot(world_digest, world_generation,
                                             std::move(natural), std::move(terrain),
                                             std::move(citadels), std::move(admitted_bounds),
                                             sha256(bytes));
}

StructureExclusionDecision NativeStructureExclusionSnapshot::query(std::int32_t x, std::int32_t z) const {
    const auto min_x = floor_grid(x, PROP_CHUNK_SIZE) * PROP_CHUNK_SIZE;
    const auto min_z = floor_grid(z, PROP_CHUNK_SIZE) * PROP_CHUNK_SIZE;
    const auto admitted = std::any_of(admitted_bounds_.begin(), admitted_bounds_.end(),
        [min_x, min_z](const StructureExclusionBoundsAdmission &receipt) {
            return receipt.min_x == min_x && receipt.min_z == min_z;
        });
    if (!admitted) {
        return {false, false, StructureExclusionKind::unresolved, "bounds_not_admitted"};
    }
    for (const auto &record : natural_) {
        if (inclusive_contains(record.bounds, x, z)) {
            return {true, true, StructureExclusionKind::natural, record.id};
        }
    }
    for (const auto &record : terrain_) {
        if (inclusive_contains(record.bounds, x, z)) {
            return {true, true, StructureExclusionKind::terrain, record.id};
        }
    }
    const auto region_x = floor_grid(x, CITADEL_REGION_SIZE);
    const auto region_z = floor_grid(z, CITADEL_REGION_SIZE);
    for (const auto &source : citadels_) {
        if (source.region_x != region_x || source.region_z != region_z) {
            continue;
        }
        if (source.status == CitadelSourceStatus::pending || source.status == CitadelSourceStatus::failed) {
            return {false, false, StructureExclusionKind::unresolved, source.reason};
        }
        if (source.status == CitadelSourceStatus::absent) {
            // Exact ready bounds admission proves an unrequested candidate
            // cannot affect this chunk. The source lookup alone does not.
            return {false, true, StructureExclusionKind::clear, source.reason};
        }
        if (half_open_contains(source.reservation, x, z)) {
            return {true, true, StructureExclusionKind::citadel, source.source_key};
        }
        return {false, true, StructureExclusionKind::clear, {}};
    }
    return {false, false, StructureExclusionKind::unresolved, "region_not_captured"};
}

bool NativeStructureExclusionSnapshot::covers_decided_regions(
    std::int32_t min_x, std::int32_t min_z, std::int32_t max_x, std::int32_t max_z) const noexcept {
    if (min_x > max_x || min_z > max_z) return false;
    const auto low_x = floor_grid(min_x, CITADEL_REGION_SIZE);
    const auto low_z = floor_grid(min_z, CITADEL_REGION_SIZE);
    const auto high_x = floor_grid(max_x, CITADEL_REGION_SIZE);
    const auto high_z = floor_grid(max_z, CITADEL_REGION_SIZE);
    for (auto region_z = low_z; region_z <= high_z; ++region_z) {
        for (auto region_x = low_x; region_x <= high_x; ++region_x) {
            const auto found = std::find_if(citadels_.begin(), citadels_.end(),
                [region_x, region_z](const CitadelExclusionSource &source) {
                    return source.region_x == region_x && source.region_z == region_z;
                });
            if (found == citadels_.end()) return false;
            if (found->status == CitadelSourceStatus::pending || found->status == CitadelSourceStatus::failed)
                return false;
        }
    }
    return true;
}

const Sha256Digest &NativeStructureExclusionSnapshot::world_digest() const noexcept { return world_digest_; }
std::uint64_t NativeStructureExclusionSnapshot::world_generation() const noexcept { return world_generation_; }
const Sha256Digest &NativeStructureExclusionSnapshot::content_digest() const noexcept { return content_digest_; }
const std::vector<StructureExclusionRecord> &NativeStructureExclusionSnapshot::natural() const noexcept { return natural_; }
const std::vector<StructureExclusionRecord> &NativeStructureExclusionSnapshot::terrain() const noexcept { return terrain_; }
const std::vector<CitadelExclusionSource> &NativeStructureExclusionSnapshot::citadels() const noexcept { return citadels_; }
const std::vector<StructureExclusionBoundsAdmission> &NativeStructureExclusionSnapshot::admitted_bounds() const noexcept { return admitted_bounds_; }

} // namespace voxel::world_backend
