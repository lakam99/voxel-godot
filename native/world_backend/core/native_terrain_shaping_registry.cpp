#include "native_terrain_shaping_registry.hpp"

#include "sha256.hpp"

#include <algorithm>
#include <cmath>
#include <cstring>
#include <limits>
#include <string>
#include <utility>

namespace voxel::world_backend {

struct NativeTerrainShapingRegistryState {
    struct Entry {
        NativeSiteSourceRegionKey region;
        NativeSiteSourceResolutionKind kind = NativeSiteSourceResolutionKind::absent;
        WorldPhysicalContentIdentity request_identity;
        std::string worker_source_key;
        std::string reason_code;
        std::string manifest_source_signature;
        NativeHorizontalRect source_reservation_cells;
        NativeAdmittedSiteTerrainProfileHandle profile;
    };

    struct Fingerprint {
        NativeSiteSourceRegionKey region;
        NativeSiteSourceResolutionKind kind = NativeSiteSourceResolutionKind::absent;
        WorldPhysicalContentIdentity request_identity;
        std::string worker_source_key;
        std::string reason_code;
        std::string site_id;
        std::string source_signature;
        NativeHorizontalRect source_reservation_cells;
        Sha256Digest full_profile_digest{};
    };

    std::uint64_t revision = 1;
    std::vector<Entry> entries;
    std::vector<Fingerprint> retired;
    WorldPhysicalContentIdentity content_identity;
};

namespace {

constexpr std::int32_t SITE_FIELD_VERSION = 1;
constexpr std::int32_t SOURCE_REGION_CELLS = 2048;
constexpr std::int32_t SOURCE_JITTER_CELLS = 384;
constexpr std::int32_t MAX_INFLUENCE_RADIUS_CELLS = 384;
// Adjacent candidates have at least 511 uncovered cells between their
// inclusive influence rectangles. One 280-cell page cannot intersect both.
static_assert(SOURCE_REGION_CELLS - 2 * (SOURCE_JITTER_CELLS + MAX_INFLUENCE_RADIUS_CELLS)
    > NativeTerrainShapingSnapshot::PAGE_CELLS);
constexpr std::uint32_t SOURCE_OCCUPANCY_PER_THOUSAND = 350;
constexpr std::int32_t MIN_SOURCE_REGION_COORD = -1048576;
constexpr std::int32_t MAX_SOURCE_REGION_COORD = 1048575;

class Writer final {
public:
    void u8(const std::uint8_t value) { bytes_.push_back(value); }
    void u32(const std::uint32_t value) {
        for (unsigned shift = 0; shift < 32U; shift += 8U)
            bytes_.push_back(static_cast<std::uint8_t>(value >> shift));
    }
    void u64(const std::uint64_t value) {
        for (unsigned shift = 0; shift < 64U; shift += 8U)
            bytes_.push_back(static_cast<std::uint8_t>(value >> shift));
    }
    void i32(const std::int32_t value) { u32(static_cast<std::uint32_t>(value)); }
    void i64(const std::int64_t value) { u64(static_cast<std::uint64_t>(value)); }
    void text(const std::string &value) {
        u64(static_cast<std::uint64_t>(value.size())); bytes_.insert(bytes_.end(), value.begin(), value.end());
    }
    void f64(const double value) {
        std::uint64_t bits = 0; std::memcpy(&bits, &value, sizeof(bits)); u64(bits);
    }
    void digest(const Sha256Digest &value) { bytes_.insert(bytes_.end(), value.begin(), value.end()); }
    std::vector<std::uint8_t> finish() && { return std::move(bytes_); }
private:
    std::vector<std::uint8_t> bytes_;
};

bool region_valid(const NativeSiteSourceRegionKey region) noexcept {
    return region.x >= MIN_SOURCE_REGION_COORD && region.x <= MAX_SOURCE_REGION_COORD
        && region.z >= MIN_SOURCE_REGION_COORD && region.z <= MAX_SOURCE_REGION_COORD;
}

bool region_less(const NativeSiteSourceRegionKey left, const NativeSiteSourceRegionKey right) noexcept {
    return left.x < right.x || (left.x == right.x && left.z < right.z);
}

bool entry_less(const NativeTerrainShapingRegistryState::Entry &left,
    const NativeTerrainShapingRegistryState::Entry &right) noexcept {
    return region_less(left.region, right.region);
}

bool fingerprint_less(const NativeTerrainShapingRegistryState::Fingerprint &left,
    const NativeTerrainShapingRegistryState::Fingerprint &right) noexcept {
    return region_less(left.region, right.region);
}

bool resolution_less(const NativeSiteSourceResolution &left, const NativeSiteSourceResolution &right) noexcept {
    return region_less(left.region, right.region);
}

bool town_less(const NativeSiteSourcePolicy::TownOverride &left,
    const NativeSiteSourcePolicy::TownOverride &right) noexcept {
    return left.region_x < right.region_x
        || (left.region_x == right.region_x && left.region_z < right.region_z);
}

std::uint32_t channel(const std::string &identity, const char *name) {
    const std::string text = identity + ':' + name;
    const Sha256Digest digest = sha256(std::vector<std::uint8_t>(text.begin(), text.end()));
    // Godot sha256_text().substr(0, 8).hex_to_int() reads the first four
    // digest bytes in their displayed (big-endian) hexadecimal order.
    return (static_cast<std::uint32_t>(digest[0]) << 24U)
        | (static_cast<std::uint32_t>(digest[1]) << 16U)
        | (static_cast<std::uint32_t>(digest[2]) << 8U)
        | static_cast<std::uint32_t>(digest[3]);
}

std::string site_identity(const WorldSourceDefinition &definition, const NativeSiteSourceRegionKey region) {
    const auto &seed = definition.raw_terrain_seed();
    // GDScript String.length() counts Unicode scalar values, not UTF-8 bytes.
    return "citadel-site-v" + std::to_string(SITE_FIELD_VERSION) + ':'
        + std::to_string(seed.code_points.size()) + ':' + seed.utf8 + ':'
        + std::to_string(region.x) + ',' + std::to_string(region.z);
}

bool rect_intersects(const NativeHorizontalRect &left, const NativeHorizontalRect &right) noexcept {
    const std::int64_t overlap_x = std::min(
        static_cast<std::int64_t>(left.x) + left.width,
        static_cast<std::int64_t>(right.x) + right.width) - std::max<std::int64_t>(left.x, right.x);
    const std::int64_t overlap_z = std::min(
        static_cast<std::int64_t>(left.z) + left.depth,
        static_cast<std::int64_t>(right.z) + right.depth) - std::max<std::int64_t>(left.z, right.z);
    return std::min(overlap_x, overlap_z) > 0;
}

bool rect_encloses(const NativeHorizontalRect &outer, const NativeHorizontalRect &inner) noexcept {
    // Both call sites receive rectangles whose positive extents were already
    // proven by full-profile admission or derived from those rectangles.
    return static_cast<std::int64_t>(inner.x) >= outer.x
        && static_cast<std::int64_t>(inner.z) >= outer.z
        && static_cast<std::int64_t>(inner.x) + inner.width <= static_cast<std::int64_t>(outer.x) + outer.width
        && static_cast<std::int64_t>(inner.z) + inner.depth <= static_cast<std::int64_t>(outer.z) + outer.depth;
}

bool valid_utf8(const std::string &value) noexcept {
    try { (void)admit_raw_terrain_seed(value); return true; }
    catch (const std::invalid_argument &) { return false; }
}

bool lowercase_sha256_hex(const std::string &value) noexcept {
    return value.size() == 64 && value.find_first_not_of("0123456789abcdef") == std::string::npos;
}

NativeHorizontalRect prepared_source_reservation(
    const NativeAdmittedSiteTerrainProfile &profile) noexcept {
    const NativeHorizontalRect envelope = profile.envelope_cells();
    const NativeHorizontalRect reservation = profile.reservation_cells();
    const std::int64_t low_x = std::min<std::int64_t>(static_cast<std::int64_t>(envelope.x) - 1, reservation.x);
    const std::int64_t low_z = std::min<std::int64_t>(static_cast<std::int64_t>(envelope.z) - 1, reservation.z);
    const std::int64_t high_x = std::max(
        static_cast<std::int64_t>(envelope.x) + envelope.width + 1,
        static_cast<std::int64_t>(reservation.x) + reservation.width);
    const std::int64_t high_z = std::max(
        static_cast<std::int64_t>(envelope.z) + envelope.depth + 1,
        static_cast<std::int64_t>(reservation.z) + reservation.depth);
    // Full-profile admission already bounds both rectangles to +/-1,000,000,
    // positive extents and int32-safe ends, so one-cell growth and merge are
    // representable without a second unreachable failure state.
    return NativeHorizontalRect{static_cast<std::int32_t>(low_x), static_cast<std::int32_t>(low_z),
        static_cast<std::int32_t>(high_x - low_x), static_cast<std::int32_t>(high_z - low_z)};
}

bool prepared_reservation_fits(const NativeSiteSourceCandidate &candidate,
    const NativeHorizontalRect &merged) noexcept {
    const NativeHorizontalRect declared = candidate.declared_influence_cells;
    // Candidate derivation proves the complete declared rectangle is inside
    // CitadelSiteField's guarded source-region interior. Enclosing the exact
    // merged receipt therefore proves both GDScript checks without duplicating
    // logically unreachable guard failures.
    return rect_encloses(declared, merged);
}

std::int32_t floor_div(const std::int64_t value, const std::int32_t divisor) noexcept {
    std::int64_t quotient = value / divisor;
    if (value < 0 && value % divisor != 0) --quotient;
    return static_cast<std::int32_t>(quotient);
}

WorldPhysicalContentIdentity registry_identity(
    const WorldSourceDefinition &definition,
    const WorldPhysicalContentIdentity &policy_identity,
    const std::vector<NativeTerrainShapingRegistryState::Entry> &entries,
    const std::vector<NativeTerrainShapingRegistryState::Fingerprint> &retired) {
    Writer writer;
    writer.u32(0x52535756U); // "VWSR"
    writer.u32(1); writer.digest(definition.physical_content_identity().digest);
    writer.digest(policy_identity.digest);
    writer.u32(SITE_FIELD_VERSION); writer.i32(SOURCE_REGION_CELLS);
    writer.i32(SOURCE_JITTER_CELLS); writer.u32(SOURCE_OCCUPANCY_PER_THOUSAND);
    writer.u64(static_cast<std::uint64_t>(entries.size()));
    for (const auto &entry : entries) {
        writer.i32(entry.region.x); writer.i32(entry.region.z); writer.u8(static_cast<std::uint8_t>(entry.kind));
        writer.digest(entry.request_identity.digest); writer.text(entry.worker_source_key); writer.text(entry.reason_code);
        if (entry.kind == NativeSiteSourceResolutionKind::prepared) {
            writer.text(entry.manifest_source_signature);
            writer.i32(entry.source_reservation_cells.x); writer.i32(entry.source_reservation_cells.z);
            writer.i32(entry.source_reservation_cells.width); writer.i32(entry.source_reservation_cells.depth);
            writer.digest(entry.profile->full_profile_digest());
        }
    }
    writer.u64(static_cast<std::uint64_t>(retired.size()));
    for (const auto &fingerprint : retired) {
        writer.i32(fingerprint.region.x); writer.i32(fingerprint.region.z);
        writer.u8(static_cast<std::uint8_t>(fingerprint.kind)); writer.digest(fingerprint.request_identity.digest);
        writer.text(fingerprint.worker_source_key); writer.text(fingerprint.reason_code);
        if (fingerprint.kind == NativeSiteSourceResolutionKind::prepared) {
            writer.text(fingerprint.site_id); writer.text(fingerprint.source_signature);
            writer.i32(fingerprint.source_reservation_cells.x); writer.i32(fingerprint.source_reservation_cells.z);
            writer.i32(fingerprint.source_reservation_cells.width); writer.i32(fingerprint.source_reservation_cells.depth);
            writer.digest(fingerprint.full_profile_digest);
        }
    }
    return {sha256(std::move(writer).finish())};
}

WorldPhysicalContentIdentity policy_identity(const WorldSourceDefinition &definition,
    const NativeSiteSourcePolicy &policy) {
    Writer writer; writer.u32(0x50535756U); // "VWSP"
    writer.u32(1); writer.digest(definition.physical_content_identity().digest);
    writer.u32(policy.source_policy_revision); writer.u32(policy.survey_generation_policy_revision);
    writer.text(policy.engine_version_utf8); writer.u64(static_cast<std::uint64_t>(policy.town_overrides.size()));
    for (const auto &town : policy.town_overrides) {
        writer.i32(town.region_x); writer.i32(town.region_z); writer.u8(town.has_town ? 1 : 0);
        if (town.has_town) {
            writer.i64(town.center_x); writer.i64(town.center_z); writer.i64(town.radius_cells);
            writer.f64(town.level_meters);
        }
    }
    writer.i64(policy.ordinary_region_cells); writer.f64(policy.ordinary_spawn_chance);
    return {sha256(std::move(writer).finish())};
}

WorldPhysicalContentIdentity request_identity(const WorldPhysicalContentIdentity &policy,
    const NativeSiteSourceRegionKey region) {
    Writer writer; writer.u32(0x51535756U); // "VWSQ"
    writer.u32(1); writer.digest(policy.digest); writer.i32(region.x); writer.i32(region.z);
    return {sha256(std::move(writer).finish())};
}

[[noreturn]] void reject(NativeTerrainShapingRegistryRejectReason reason);

NativeSiteSourcePolicy canonical_policy(NativeSiteSourcePolicy policy) {
    if (policy.source_policy_revision != 1 || policy.survey_generation_policy_revision != 1
        || policy.engine_version_utf8.empty() || policy.engine_version_utf8.size() > 1024
        || !valid_utf8(policy.engine_version_utf8) || policy.town_overrides.size() > 4096
        || policy.ordinary_region_cells < 34 || !std::isfinite(policy.ordinary_spawn_chance)
        || policy.ordinary_spawn_chance < 0.0 || policy.ordinary_spawn_chance > 1.0)
        reject(NativeTerrainShapingRegistryRejectReason::invalid_policy);
    std::sort(policy.town_overrides.begin(), policy.town_overrides.end(), town_less);
    for (std::size_t index = 0; index < policy.town_overrides.size(); ++index) {
        const auto &town = policy.town_overrides[index];
        if (index > 0 && town.region_x == policy.town_overrides[index - 1].region_x
            && town.region_z == policy.town_overrides[index - 1].region_z)
            reject(NativeTerrainShapingRegistryRejectReason::invalid_policy);
        if (!town.has_town) continue;
        if (town.center_x != static_cast<std::int64_t>(town.region_x) * NativeTerrainShapingSnapshot::PAGE_CELLS
            || town.center_z != static_cast<std::int64_t>(town.region_z) * NativeTerrainShapingSnapshot::PAGE_CELLS
            || town.radius_cells <= 0
            || town.radius_cells > NativeTerrainShapingSnapshot::PAGE_CELLS - NativeTerrainShapingSnapshot::MAX_TOWN_APRON_CELLS
            || !std::isfinite(town.level_meters))
            reject(NativeTerrainShapingRegistryRejectReason::invalid_policy);
    }
    return policy;
}

[[noreturn]] void reject(const NativeTerrainShapingRegistryRejectReason reason) {
    throw NativeTerrainShapingRegistryRejected(reason);
}

bool valid_kind(const NativeSiteSourceResolutionKind kind) noexcept {
    return kind == NativeSiteSourceResolutionKind::absent
        || kind == NativeSiteSourceResolutionKind::prepared
        || kind == NativeSiteSourceResolutionKind::failed;
}

bool same_resolution(const NativeTerrainShapingRegistryState::Entry &entry,
    const NativeSiteSourceResolution &resolution) noexcept {
    if (entry.kind != resolution.kind || entry.worker_source_key != resolution.worker_source_key
        || entry.reason_code != resolution.reason_code) return false;
    if (entry.kind != NativeSiteSourceResolutionKind::prepared) return true;
    // Prepared admission already binds manifest signature and the exact merged
    // reservation into the full profile digest plus deterministic receipt.
    return entry.profile->full_profile_digest() == resolution.profile->full_profile_digest();
}

bool same_fingerprint(const NativeTerrainShapingRegistryState::Fingerprint &fingerprint,
    const NativeSiteSourceResolution &resolution) noexcept {
    if (fingerprint.kind != resolution.kind || fingerprint.worker_source_key != resolution.worker_source_key
        || fingerprint.reason_code != resolution.reason_code)
        return false;
    if (fingerprint.kind != NativeSiteSourceResolutionKind::prepared) return true;
    return fingerprint.full_profile_digest == resolution.profile->full_profile_digest();
}

auto find_entry(std::vector<NativeTerrainShapingRegistryState::Entry> &entries,
    const NativeSiteSourceRegionKey region) {
    NativeTerrainShapingRegistryState::Entry key; key.region = region;
    return std::lower_bound(entries.begin(), entries.end(), key, entry_less);
}

auto find_entry(const std::vector<NativeTerrainShapingRegistryState::Entry> &entries,
    const NativeSiteSourceRegionKey region) {
    NativeTerrainShapingRegistryState::Entry key; key.region = region;
    return std::lower_bound(entries.begin(), entries.end(), key, entry_less);
}

auto find_fingerprint(std::vector<NativeTerrainShapingRegistryState::Fingerprint> &retired,
    const NativeSiteSourceRegionKey region) {
    NativeTerrainShapingRegistryState::Fingerprint key; key.region = region;
    return std::lower_bound(retired.begin(), retired.end(), key, fingerprint_less);
}

} // namespace

bool NativeSiteSourceRegionKey::operator==(const NativeSiteSourceRegionKey &other) const noexcept {
    return x == other.x && z == other.z;
}

std::optional<NativeSiteSourceCandidate> native_site_source_candidate_for_region(
    const WorldSourceDefinition &definition, const NativeSiteSourceRegionKey region) {
    if (definition.raw_terrain_seed().utf8.empty() || !region_valid(region)) return std::nullopt;
    NativeSiteSourceCandidate candidate; candidate.region = region;
    candidate.site_id = site_identity(definition, region);
    if (channel(candidate.site_id, "presence") % 1000U >= SOURCE_OCCUPANCY_PER_THOUSAND)
        return std::nullopt;
    const std::int64_t center_x = static_cast<std::int64_t>(region.x) * SOURCE_REGION_CELLS
        + SOURCE_REGION_CELLS / 2 + static_cast<std::int32_t>(channel(candidate.site_id, "x") % 769U) - SOURCE_JITTER_CELLS;
    const std::int64_t center_z = static_cast<std::int64_t>(region.z) * SOURCE_REGION_CELLS
        + SOURCE_REGION_CELLS / 2 + static_cast<std::int32_t>(channel(candidate.site_id, "z") % 769U) - SOURCE_JITTER_CELLS;
    candidate.center_x = static_cast<std::int32_t>(center_x);
    candidate.center_z = static_cast<std::int32_t>(center_z);
    candidate.recipe_seed = channel(candidate.site_id, "recipe") & 0x7fffffffU;
    candidate.declared_influence_cells = {
        candidate.center_x - MAX_INFLUENCE_RADIUS_CELLS,
        candidate.center_z - MAX_INFLUENCE_RADIUS_CELLS,
        MAX_INFLUENCE_RADIUS_CELLS * 2 + 1,
        MAX_INFLUENCE_RADIUS_CELLS * 2 + 1};
    return candidate;
}

void BorrowedSiteCandidateCursor::reset() noexcept {
    hash_.reset();
    region_ = {};
    input_offset_ = 0U;
    channel_ = 0U;
    phase_ = 0U;
    decimal_index_ = 0U; decimal_phase_ = 0U; decimal_reverse_index_ = 0U;
    decimal_remaining_ = 0U; decimal_negative_ = false;
    status_ = Status::idle;
}

BorrowedSiteCandidateCursor::Status BorrowedSiteCandidateCursor::status() const noexcept { return status_; }
NativeSiteSourceRegionKey BorrowedSiteCandidateCursor::region() const noexcept { return region_; }
std::uint32_t BorrowedSiteCandidateCursor::recipe_seed() const noexcept {
    return channels_[3] & 0x7fffffffU;
}
std::int32_t BorrowedSiteCandidateCursor::center_x() const noexcept {
    return static_cast<std::int32_t>(static_cast<std::int64_t>(region_.x) * SOURCE_REGION_CELLS
        + SOURCE_REGION_CELLS / 2 + static_cast<std::int32_t>(channels_[1] % 769U) - SOURCE_JITTER_CELLS);
}
std::int32_t BorrowedSiteCandidateCursor::center_z() const noexcept {
    return static_cast<std::int32_t>(static_cast<std::int64_t>(region_.z) * SOURCE_REGION_CELLS
        + SOURCE_REGION_CELLS / 2 + static_cast<std::int32_t>(channels_[2] % 769U) - SOURCE_JITTER_CELLS);
}
NativeHorizontalRect BorrowedSiteCandidateCursor::declared_influence_cells() const noexcept {
    return {center_x() - MAX_INFLUENCE_RADIUS_CELLS, center_z() - MAX_INFLUENCE_RADIUS_CELLS,
        MAX_INFLUENCE_RADIUS_CELLS * 2 + 1, MAX_INFLUENCE_RADIUS_CELLS * 2 + 1};
}

BorrowedSiteCandidateCursor::Step BorrowedSiteCandidateCursor::begin(
    const WorldSourceDefinition &definition, const NativeSiteSourceRegionKey region,
    const std::uint32_t offered_ops) noexcept {
    Step result; result.status = status_;
    if (status_ != Status::idle || offered_ops == 0U) return result;
    region_ = region;
    if (definition.raw_terrain_seed().utf8.empty() || !region_valid(region)) {
        status_ = Status::absent; result.status = status_; result.consumed_ops = 1U; return result;
    }
    number_lengths_ = {};
    hash_.reset(); input_offset_ = 0U; channel_ = 0U; phase_ = 0U;
    decimal_index_ = 0U; decimal_phase_ = 0U; decimal_reverse_index_ = 0U;
    decimal_remaining_ = 0U; decimal_negative_ = false;
    status_ = Status::pending; result.status = status_; result.consumed_ops = 1U;
    return result;
}

std::size_t BorrowedSiteCandidateCursor::text_size(const WorldSourceDefinition &definition) const noexcept {
    static constexpr char prefix[] = "citadel-site-v1:";
    return sizeof(prefix) - 1U + number_lengths_[0] + 1U
        + definition.raw_terrain_seed().utf8.size() + 1U
        + number_lengths_[1] + 1U + number_lengths_[2];
}

std::uint8_t BorrowedSiteCandidateCursor::text_byte(
    const WorldSourceDefinition &definition, std::size_t offset) const noexcept {
    static constexpr char prefix[] = "citadel-site-v1:";
    if (offset < sizeof(prefix) - 1U) return static_cast<std::uint8_t>(prefix[offset]);
    offset -= sizeof(prefix) - 1U;
    if (offset < number_lengths_[0]) return static_cast<std::uint8_t>(numbers_[0][offset]);
    offset -= number_lengths_[0];
    if (offset-- == 0U) return ':';
    const std::string &seed = definition.raw_terrain_seed().utf8;
    if (offset < seed.size()) return static_cast<std::uint8_t>(seed[offset]);
    offset -= seed.size();
    if (offset-- == 0U) return ':';
    if (offset < number_lengths_[1]) return static_cast<std::uint8_t>(numbers_[1][offset]);
    offset -= number_lengths_[1];
    if (offset-- == 0U) return ',';
    return static_cast<std::uint8_t>(numbers_[2][offset]);
}

BorrowedSiteCandidateCursor::Step BorrowedSiteCandidateCursor::advance(
    const WorldSourceDefinition &definition, const std::uint32_t offered_ops) noexcept {
    Step result; result.status = status_;
    if (status_ != Status::pending) return result;
    static constexpr const char *names[] = {"presence", "x", "z", "recipe"};
    static constexpr std::size_t lengths[] = {8U, 1U, 1U, 6U};
    const std::uint32_t limit = std::min(offered_ops, 64U);
    while (result.consumed_ops < limit && status_ == Status::pending) {
        if (phase_ == 0U) {
            if (decimal_index_ >= 3U) { phase_ = 1U; continue; }
            if (decimal_phase_ == 0U) {
                const std::int64_t signed_value = decimal_index_ == 0U
                    ? static_cast<std::int64_t>(definition.raw_terrain_seed().code_points.size())
                    : decimal_index_ == 1U ? region_.x : region_.z;
                decimal_negative_ = signed_value < 0;
                decimal_remaining_ = static_cast<std::uint64_t>(decimal_negative_
                    ? -signed_value : signed_value);
                decimal_phase_ = 1U; ++result.consumed_ops;
            } else if (decimal_phase_ == 1U) {
                if (limit - result.consumed_ops < 2U) {
                    result.next_atomic_ops = 2U; break;
                }
                const std::uint64_t digit = decimal_remaining_ % 10U;
                decimal_remaining_ /= 10U;
                numbers_[decimal_index_][number_lengths_[decimal_index_]++] =
                    static_cast<char>('0' + digit);
                result.consumed_ops += 2U;
                if (decimal_remaining_ == 0U) decimal_phase_ = 2U;
            } else if (decimal_phase_ == 2U) {
                if (decimal_negative_)
                    numbers_[decimal_index_][number_lengths_[decimal_index_]++] = '-';
                decimal_reverse_index_ = 0U; decimal_phase_ = 3U;
                ++result.consumed_ops;
            } else if (decimal_reverse_index_ < number_lengths_[decimal_index_] / 2U) {
                const std::size_t last = number_lengths_[decimal_index_] - 1U - decimal_reverse_index_;
                std::swap(numbers_[decimal_index_][decimal_reverse_index_],
                    numbers_[decimal_index_][last]);
                ++decimal_reverse_index_; ++result.consumed_ops;
            } else {
                ++decimal_index_; decimal_phase_ = 0U; ++result.consumed_ops;
            }
        } else if (phase_ == 1U) {
            if (limit - result.consumed_ops < 3U) { result.next_atomic_ops = 3U; break; }
            const std::size_t identity_size = text_size(definition);
            const std::size_t suffix_offset = input_offset_ - std::min(input_offset_, identity_size);
            const std::uint8_t byte = input_offset_ < identity_size
                ? text_byte(definition, input_offset_)
                : suffix_offset == 0U ? static_cast<std::uint8_t>(':')
                    : static_cast<std::uint8_t>(names[channel_][suffix_offset - 1U]);
            const auto updated = hash_.update_step(&byte, 1U, 1U, 1U);
            if (!updated.input_complete) { status_ = Status::failed; break; }
            ++input_offset_; result.consumed_ops += 3U;
            if (input_offset_ == identity_size + 1U + lengths[channel_]) phase_ = 2U;
        } else if (phase_ == 2U) {
            const auto finished = hash_.finish_step(1U);
            ++result.consumed_ops;
            if (finished.digest_ready) {
                const Sha256Digest digest = hash_.digest();
                channels_[channel_] = (static_cast<std::uint32_t>(digest[0]) << 24U)
                    | (static_cast<std::uint32_t>(digest[1]) << 16U)
                    | (static_cast<std::uint32_t>(digest[2]) << 8U)
                    | static_cast<std::uint32_t>(digest[3]);
                if (channel_ == 0U && channels_[0] % 1000U >= SOURCE_OCCUPANCY_PER_THOUSAND)
                    status_ = Status::absent;
                else if (channel_ == 3U) status_ = Status::ready;
                else phase_ = 3U;
            }
        } else {
            hash_.reset(); input_offset_ = 0U; ++channel_; phase_ = 1U;
            ++result.consumed_ops;
        }
    }
    result.status = status_;
    if (status_ == Status::pending) result.next_atomic_ops = phase_ == 1U ? 3U
        : phase_ == 0U && decimal_phase_ == 1U ? 2U : 1U;
    return result;
}

void BorrowedShapingPageCursor::reset() noexcept {
    page_ = {}; bounds_ = {}; low_region_ = {}; high_region_ = {}; region_ = {};
    candidate_.reset(); profile_count_ = 0U; entry_scan_index_ = 0U;
    unresolved_seen_ = false; failed_seen_ = false;
    phase_ = 0U; status_ = Status::idle;
}
BorrowedShapingPageCursor::Status BorrowedShapingPageCursor::status() const noexcept { return status_; }
NativeTerrainPageKey BorrowedShapingPageCursor::page_key() const noexcept { return page_; }
NativeHorizontalRect BorrowedShapingPageCursor::page_bounds() const noexcept { return bounds_; }
std::size_t BorrowedShapingPageCursor::profile_count() const noexcept { return profile_count_; }

BorrowedShapingPageCursor::Step BorrowedShapingPageCursor::begin(
    const NativeTerrainPageKey page, const std::uint32_t offered_ops) noexcept {
    Step result; result.status = status_;
    if (status_ != Status::idle || offered_ops == 0U) return result;
    const auto bounds = native_terrain_page_bounds(page);
    if (!bounds) { status_ = Status::failed; result.status = status_; return result; }
    page_ = page; bounds_ = *bounds;
    const std::int64_t last_x = static_cast<std::int64_t>(bounds->x) + bounds->width - 1;
    const std::int64_t last_z = static_cast<std::int64_t>(bounds->z) + bounds->depth - 1;
    low_region_ = {floor_div(bounds->x, SOURCE_REGION_CELLS),
        floor_div(bounds->z, SOURCE_REGION_CELLS)};
    high_region_ = {floor_div(last_x, SOURCE_REGION_CELLS),
        floor_div(last_z, SOURCE_REGION_CELLS)};
    region_ = low_region_; profile_count_ = 0U; entry_scan_index_ = 0U;
    candidate_.reset(); phase_ = 0U; status_ = Status::pending;
    unresolved_seen_ = false; failed_seen_ = false;
    result.status = status_; result.consumed_ops = 1U; result.next_atomic_ops = 1U;
    return result;
}

BorrowedShapingPageCursor::Step NativeTerrainShapingRegistry::advance_borrowed_page(
    BorrowedShapingPageCursor &cursor, const std::uint32_t offered_ops) const noexcept {
    BorrowedShapingPageCursor::Step result; result.status = cursor.status_;
    if (cursor.status_ != BorrowedShapingPageCursor::Status::pending) return result;
    const std::uint32_t limit = std::min(offered_ops, 64U);
    while (result.consumed_ops < limit && cursor.status_ == BorrowedShapingPageCursor::Status::pending) {
        const std::uint32_t remaining = limit - result.consumed_ops;
        if (cursor.phase_ == 0U) {
            const auto begun = cursor.candidate_.begin(definition_, cursor.region_, remaining);
            if (begun.consumed_ops == 0U
                && cursor.candidate_.status() == BorrowedSiteCandidateCursor::Status::idle) {
                result.next_atomic_ops = 1U; break;
            }
            result.consumed_ops += begun.consumed_ops;
            cursor.phase_ = 1U;
        } else if (cursor.phase_ == 1U) {
            if (cursor.candidate_.status() == BorrowedSiteCandidateCursor::Status::pending) {
                const auto advanced = cursor.candidate_.advance(definition_, remaining);
                result.consumed_ops += advanced.consumed_ops;
                if (advanced.consumed_ops == 0U) {
                    result.next_atomic_ops = advanced.next_atomic_ops; break;
                }
            }
            if (cursor.candidate_.status() == BorrowedSiteCandidateCursor::Status::pending) continue;
            if (cursor.candidate_.status() == BorrowedSiteCandidateCursor::Status::failed) {
                cursor.status_ = BorrowedShapingPageCursor::Status::failed; break;
            }
            if (cursor.candidate_.status() == BorrowedSiteCandidateCursor::Status::absent
                || !rect_intersects(cursor.candidate_.declared_influence_cells(), cursor.bounds_)) {
                cursor.phase_ = 3U; continue;
            }
            cursor.entry_scan_index_ = 0U; cursor.phase_ = 2U;
        } else if (cursor.phase_ == 2U) {
            if (cursor.entry_scan_index_ == state_->entries.size()) {
                cursor.unresolved_seen_ = true; cursor.phase_ = 3U; continue;
            }
            const auto &entry = state_->entries[cursor.entry_scan_index_];
            ++result.consumed_ops;
            if (entry.region == cursor.region_) {
                if (entry.kind == NativeSiteSourceResolutionKind::failed)
                    cursor.failed_seen_ = true;
                if (entry.kind == NativeSiteSourceResolutionKind::prepared
                    && rect_intersects(entry.profile->envelope_cells(), cursor.bounds_)) {
                    if (cursor.profile_count_ == cursor.profile_indices_.size()) {
                        cursor.status_ = BorrowedShapingPageCursor::Status::failed; break;
                    }
                    cursor.profile_indices_[cursor.profile_count_++] = cursor.entry_scan_index_;
                }
                cursor.phase_ = 3U;
            } else if (region_less(cursor.region_, entry.region)) {
                cursor.unresolved_seen_ = true; cursor.phase_ = 3U;
            } else ++cursor.entry_scan_index_;
        } else {
            ++result.consumed_ops;
            if (cursor.region_.x < cursor.high_region_.x) ++cursor.region_.x;
            else if (cursor.region_.z < cursor.high_region_.z) {
                cursor.region_.x = cursor.low_region_.x; ++cursor.region_.z;
            } else {
                // Keep the synchronous pin_page precedence. With today's
                // 2048-cell regions, 384-cell jitter/radius and 280-cell
                // pages, two relevant candidates cannot share a page; the
                // aggregate also remains correct if those constants change.
                cursor.status_ = cursor.failed_seen_ ? BorrowedShapingPageCursor::Status::failed
                    : cursor.unresolved_seen_ ? BorrowedShapingPageCursor::Status::unresolved
                    : BorrowedShapingPageCursor::Status::ready;
                break;
            }
            cursor.candidate_.reset(); cursor.phase_ = 0U;
        }
    }
    result.status = cursor.status_;
    if (cursor.status_ == BorrowedShapingPageCursor::Status::pending)
        result.next_atomic_ops = cursor.phase_ == 0U ? 1U
            : cursor.phase_ == 1U ? 3U : 1U;
    return result;
}

BorrowedShapingIdentityCursor::Step NativeTerrainShapingRegistry::advance_borrowed_page_identity(
    const BorrowedShapingPageCursor &page, BorrowedShapingIdentityCursor &identity,
    const std::array<NativeTownRegionOverride, 9> &towns,
    const std::size_t town_count, const std::uint32_t offered_ops) const noexcept {
    BorrowedShapingIdentityCursor::Step result; result.status = identity.status();
    if (page.status_ != BorrowedShapingPageCursor::Status::ready
        || town_count > towns.size()) return result;
    if (identity.status() == BorrowedShapingIdentityCursor::Status::ready
        || identity.status() == BorrowedShapingIdentityCursor::Status::failed) return result;
    const std::uint32_t limit = std::min(offered_ops, 64U);
    if (limit < page.profile_count_) {
        result.next_atomic_ops = static_cast<std::uint32_t>(page.profile_count_); return result;
    }
    std::array<const NativeAdmittedSiteTerrainProfile *, BorrowedShapingIdentityCursor::MAX_PROFILES>
        profiles{};
    for (std::size_t index = 0U; index < page.profile_count_; ++index) {
        const std::size_t entry_index = page.profile_indices_[index];
        if (entry_index >= state_->entries.size()
            || state_->entries[entry_index].kind != NativeSiteSourceResolutionKind::prepared)
            return result;
        profiles[index] = state_->entries[entry_index].profile.get();
    }
    result.consumed_ops = static_cast<std::uint32_t>(page.profile_count_);
    if (identity.status() == BorrowedShapingIdentityCursor::Status::idle) {
        const auto begun = identity.begin(page.page_, page.bounds_, towns, town_count,
            page.profile_count_, limit - result.consumed_ops);
        result.consumed_ops += begun.consumed_ops;
        result.status = begun.status;
        result.next_atomic_ops = begun.next_atomic_ops;
        return result;
    }
    const auto advanced = identity.advance(definition_, profiles, limit - result.consumed_ops);
    result.consumed_ops += advanced.consumed_ops;
    result.status = advanced.status;
    result.next_atomic_ops = advanced.next_atomic_ops;
    return result;
}

NativeTerrainShapingRegistryRejected::NativeTerrainShapingRegistryRejected(
    const NativeTerrainShapingRegistryRejectReason reason)
    : std::runtime_error("native terrain shaping registry rejected an operation"), reason_(reason) {}
NativeTerrainShapingRegistryRejectReason NativeTerrainShapingRegistryRejected::reason() const noexcept { return reason_; }

NativeTerrainShapingPageReadiness NativeTerrainShapingPagePin::readiness() const noexcept { return readiness_; }
NativeTerrainPageKey NativeTerrainShapingPagePin::page_key() const noexcept { return page_key_; }
std::uint64_t NativeTerrainShapingPagePin::registry_revision() const noexcept { return registry_revision_; }
const WorldPhysicalContentIdentity &NativeTerrainShapingPagePin::registry_content_identity() const noexcept {
    return registry_content_identity_;
}
const std::vector<NativeSiteSourceRegionKey> &NativeTerrainShapingPagePin::dependencies() const noexcept {
    return dependencies_;
}
const std::vector<NativeSiteSourceRegionKey> &NativeTerrainShapingPagePin::unresolved_dependencies() const noexcept {
    return unresolved_dependencies_;
}
const std::vector<NativeSiteSourceRegionKey> &NativeTerrainShapingPagePin::failed_dependencies() const noexcept {
    return failed_dependencies_;
}
const std::shared_ptr<const NativeTerrainShapingSnapshot> &NativeTerrainShapingPagePin::snapshot() const noexcept {
    return snapshot_;
}

NativeTerrainShapingRegistry::NativeTerrainShapingRegistry(
    WorldSourceDefinition definition, NativeSiteSourcePolicy policy,
    const NativeTerrainShapingRegistryLimits limits)
    : definition_(std::move(definition)), policy_(canonical_policy(std::move(policy))), limits_(limits) {
    if (limits_.max_resident_resolutions == 0 || limits_.max_batch_resolutions == 0
        || limits_.max_batch_resolutions > limits_.max_resident_resolutions
        || limits_.max_retired_fingerprints == 0 || limits_.max_revision == 0)
        reject(NativeTerrainShapingRegistryRejectReason::invalid_limits);
    if (definition_.raw_terrain_seed().utf8.empty() || definition_.raw_terrain_seed().code_points.size() > 1024)
        reject(NativeTerrainShapingRegistryRejectReason::invalid_policy);
    policy_content_identity_ = policy_identity(definition_, policy_);
    auto state = std::make_shared<NativeTerrainShapingRegistryState>();
    state->content_identity = registry_identity(definition_, policy_content_identity_, state->entries, state->retired);
    state_ = std::move(state);
}

const WorldSourceDefinition &NativeTerrainShapingRegistry::definition() const noexcept { return definition_; }
const NativeSiteSourcePolicy &NativeTerrainShapingRegistry::policy() const noexcept { return policy_; }
const WorldPhysicalContentIdentity &NativeTerrainShapingRegistry::policy_content_identity() const noexcept {
    return policy_content_identity_;
}
WorldPhysicalContentIdentity NativeTerrainShapingRegistry::source_request_identity(
    const NativeSiteSourceRegionKey region) const {
    if (!region_valid(region)) reject(NativeTerrainShapingRegistryRejectReason::invalid_region);
    return request_identity(policy_content_identity_, region);
}
std::uint64_t NativeTerrainShapingRegistry::revision() const noexcept { return state_->revision; }
std::size_t NativeTerrainShapingRegistry::resident_resolution_count() const noexcept { return state_->entries.size(); }
std::size_t NativeTerrainShapingRegistry::retired_fingerprint_count() const noexcept { return state_->retired.size(); }
const WorldPhysicalContentIdentity &NativeTerrainShapingRegistry::content_identity() const noexcept {
    return state_->content_identity;
}

bool NativeTerrainShapingRegistry::bind_source_mutation_fence(WorldSourceMutationFence *fence) noexcept {
    if (!fence || !fence->on_owner_thread() || source_mutation_fence_) return false;
    source_mutation_fence_ = fence;
    return true;
}

NativeTerrainShapingRegistryReceipt NativeTerrainShapingRegistry::apply(
    const NativeTerrainShapingRegistryBatch &batch) {
    if (source_mutation_fence_) source_mutation_fence_->require_writer_entry();
    if (batch.expected_revision != state_->revision)
        reject(NativeTerrainShapingRegistryRejectReason::revision_conflict);
    if (batch.resolutions.size() > limits_.max_batch_resolutions)
        reject(NativeTerrainShapingRegistryRejectReason::batch_limit);
    std::vector<NativeSiteSourceResolution> incoming = batch.resolutions;
    std::sort(incoming.begin(), incoming.end(), resolution_less);
    for (std::size_t index = 0; index < incoming.size(); ++index) {
        const auto &resolution = incoming[index];
        if (!region_valid(resolution.region)) reject(NativeTerrainShapingRegistryRejectReason::invalid_region);
        if (index > 0 && resolution.region == incoming[index - 1].region)
            reject(NativeTerrainShapingRegistryRejectReason::duplicate_region);
        const auto candidate = native_site_source_candidate_for_region(definition_, resolution.region);
        if (!candidate) reject(NativeTerrainShapingRegistryRejectReason::candidate_absent);
        if (!valid_kind(resolution.kind)) reject(NativeTerrainShapingRegistryRejectReason::invalid_resolution);
        if (!(resolution.request_identity == request_identity(policy_content_identity_, resolution.region))
            || !lowercase_sha256_hex(resolution.worker_source_key)
            || resolution.reason_code.size() > 2048 || !valid_utf8(resolution.reason_code)
            || (resolution.kind == NativeSiteSourceResolutionKind::prepared) != resolution.reason_code.empty())
            reject(NativeTerrainShapingRegistryRejectReason::invalid_resolution);
        if (resolution.kind == NativeSiteSourceResolutionKind::prepared) {
            const NativeHorizontalRect merged = resolution.profile
                ? prepared_source_reservation(*resolution.profile) : NativeHorizontalRect{};
            const WorldFloat32Position origin = resolution.profile ? resolution.profile->origin() : WorldFloat32Position{};
            const float expected_origin_x = static_cast<float>(
                static_cast<double>(candidate->center_x) * definition_.constants().cell_size_meters);
            const float expected_origin_z = static_cast<float>(
                static_cast<double>(candidate->center_z) * definition_.constants().cell_size_meters);
            if (!resolution.profile
                || !(resolution.profile->source_definition_identity() == definition_.physical_content_identity())
                || resolution.profile->site_id() != candidate->site_id
                || !rect_encloses(candidate->declared_influence_cells, resolution.profile->envelope_cells())
                || !prepared_reservation_fits(*candidate, merged)
                || !(resolution.source_reservation_cells == merged)
                || resolution.manifest_source_signature != resolution.profile->source_signature()
                || origin.x != expected_origin_x || origin.z != expected_origin_z)
                reject(NativeTerrainShapingRegistryRejectReason::invalid_resolution);
        } else if (resolution.profile) {
            reject(NativeTerrainShapingRegistryRejectReason::invalid_resolution);
        } else if (!resolution.manifest_source_signature.empty()
            || resolution.source_reservation_cells.width != 0 || resolution.source_reservation_cells.depth != 0
            || resolution.source_reservation_cells.x != 0 || resolution.source_reservation_cells.z != 0) {
            reject(NativeTerrainShapingRegistryRejectReason::invalid_resolution);
        }
    }

    auto next_entries = state_->entries;
    auto next_retired = state_->retired;
    bool changed = false;
    for (const auto &resolution : incoming) {
        auto found = find_entry(next_entries, resolution.region);
        if (found != next_entries.end() && found->region == resolution.region) {
            if (!same_resolution(*found, resolution))
                reject(NativeTerrainShapingRegistryRejectReason::terminal_conflict);
            continue;
        }
        const auto retired = find_fingerprint(next_retired, resolution.region);
        if (retired != next_retired.end() && retired->region == resolution.region) {
            if (!same_fingerprint(*retired, resolution))
                reject(NativeTerrainShapingRegistryRejectReason::terminal_conflict);
            next_retired.erase(retired);
        }
        NativeTerrainShapingRegistryState::Entry entry;
        entry.region = resolution.region; entry.kind = resolution.kind;
        entry.request_identity = resolution.request_identity; entry.worker_source_key = resolution.worker_source_key;
        entry.reason_code = resolution.reason_code; entry.manifest_source_signature = resolution.manifest_source_signature;
        entry.source_reservation_cells = resolution.source_reservation_cells; entry.profile = resolution.profile;
        next_entries.insert(found, std::move(entry)); changed = true;
    }
    if (!changed) return {NativeTerrainShapingRegistryCommitStatus::no_change, state_->revision};
    if (next_entries.size() > limits_.max_resident_resolutions)
        reject(NativeTerrainShapingRegistryRejectReason::capacity_exceeded);
    if (state_->revision >= limits_.max_revision)
        reject(NativeTerrainShapingRegistryRejectReason::revision_exhausted);
    auto next = std::make_shared<NativeTerrainShapingRegistryState>();
    next->revision = state_->revision + 1; next->entries = std::move(next_entries); next->retired = std::move(next_retired);
    next->content_identity = registry_identity(definition_, policy_content_identity_, next->entries, next->retired);
    if (source_mutation_fence_) source_mutation_fence_->published();
    state_ = std::move(next);
    return {NativeTerrainShapingRegistryCommitStatus::committed, state_->revision};
}

NativeTerrainShapingRegistryReceipt NativeTerrainShapingRegistry::retire(
    const NativeTerrainShapingRegistryRetirement &retirement) {
    if (source_mutation_fence_) source_mutation_fence_->require_writer_entry();
    if (retirement.expected_revision != state_->revision)
        reject(NativeTerrainShapingRegistryRejectReason::revision_conflict);
    if (retirement.regions.size() > limits_.max_batch_resolutions)
        reject(NativeTerrainShapingRegistryRejectReason::batch_limit);
    std::vector<NativeSiteSourceRegionKey> regions = retirement.regions;
    std::sort(regions.begin(), regions.end(), region_less);
    for (std::size_t index = 0; index < regions.size(); ++index) {
        if (!region_valid(regions[index])) reject(NativeTerrainShapingRegistryRejectReason::invalid_region);
        if (index > 0 && regions[index] == regions[index - 1])
            reject(NativeTerrainShapingRegistryRejectReason::duplicate_region);
        const auto found = find_entry(state_->entries, regions[index]);
        if (found == state_->entries.end() || !(found->region == regions[index]))
            reject(NativeTerrainShapingRegistryRejectReason::terminal_conflict);
        if (found->kind == NativeSiteSourceResolutionKind::failed)
            reject(NativeTerrainShapingRegistryRejectReason::terminal_conflict);
    }
    if (regions.empty()) return {NativeTerrainShapingRegistryCommitStatus::no_change, state_->revision};
    if (regions.size() > limits_.max_retired_fingerprints
        || state_->retired.size() > limits_.max_retired_fingerprints - regions.size())
        reject(NativeTerrainShapingRegistryRejectReason::capacity_exceeded);
    if (state_->revision >= limits_.max_revision)
        reject(NativeTerrainShapingRegistryRejectReason::revision_exhausted);
    auto next = std::make_shared<NativeTerrainShapingRegistryState>();
    next->revision = state_->revision + 1; next->entries = state_->entries; next->retired = state_->retired;
    for (const auto region : regions) {
        const auto found = find_entry(next->entries, region);
        NativeTerrainShapingRegistryState::Fingerprint fingerprint;
        fingerprint.region = found->region; fingerprint.kind = found->kind;
        fingerprint.request_identity = found->request_identity; fingerprint.worker_source_key = found->worker_source_key;
        fingerprint.reason_code = found->reason_code;
        if (found->kind == NativeSiteSourceResolutionKind::prepared) {
            fingerprint.site_id = found->profile->site_id();
            fingerprint.source_signature = found->manifest_source_signature;
            fingerprint.source_reservation_cells = found->source_reservation_cells;
            fingerprint.full_profile_digest = found->profile->full_profile_digest();
        }
        next->retired.insert(find_fingerprint(next->retired, region), std::move(fingerprint));
        next->entries.erase(found);
    }
    next->content_identity = registry_identity(definition_, policy_content_identity_, next->entries, next->retired);
    if (source_mutation_fence_) source_mutation_fence_->published();
    state_ = std::move(next);
    return {NativeTerrainShapingRegistryCommitStatus::committed, state_->revision};
}

NativeTerrainShapingPagePin NativeTerrainShapingRegistry::pin_page(
    const NativeTerrainPageKey page_key,
    std::vector<NativeTownRegionOverride> town_overrides) const {
    const auto bounds = native_terrain_page_bounds(page_key);
    if (!bounds) {
        NativeTerrainShapingRequest invalid; invalid.generation_revision = state_->revision; invalid.page_key = page_key;
        (void)NativeTerrainShapingSnapshot(definition_, std::move(invalid));
    }
    NativeTerrainShapingRequest validation;
    validation.generation_revision = state_->revision; validation.page_key = page_key;
    validation.town_overrides = town_overrides;
    (void)NativeTerrainShapingSnapshot(definition_, std::move(validation));

    NativeTerrainShapingPagePin pin;
    pin.page_key_ = page_key; pin.registry_revision_ = state_->revision;
    pin.registry_content_identity_ = state_->content_identity;
    std::vector<NativeAdmittedSiteTerrainProfileHandle> profiles;
    const std::int64_t last_x = static_cast<std::int64_t>(bounds->x) + bounds->width - 1;
    const std::int64_t last_z = static_cast<std::int64_t>(bounds->z) + bounds->depth - 1;
    const std::int32_t low_x = floor_div(bounds->x, SOURCE_REGION_CELLS);
    const std::int32_t high_x = floor_div(last_x, SOURCE_REGION_CELLS);
    const std::int32_t low_z = floor_div(bounds->z, SOURCE_REGION_CELLS);
    const std::int32_t high_z = floor_div(last_z, SOURCE_REGION_CELLS);
    for (std::int32_t z = low_z; z <= high_z; ++z) {
        for (std::int32_t x = low_x; x <= high_x; ++x) {
            const NativeSiteSourceRegionKey region{x, z};
            const auto candidate = native_site_source_candidate_for_region(definition_, region);
            if (!candidate || !rect_intersects(candidate->declared_influence_cells, *bounds)) continue;
            pin.dependencies_.push_back(region);
            const auto found = find_entry(state_->entries, region);
            if (found == state_->entries.end() || !(found->region == region)) {
                pin.unresolved_dependencies_.push_back(region); continue;
            }
            if (found->kind == NativeSiteSourceResolutionKind::failed) {
                pin.failed_dependencies_.push_back(region); continue;
            }
            if (found->kind == NativeSiteSourceResolutionKind::prepared
                && rect_intersects(found->profile->envelope_cells(), *bounds))
                profiles.push_back(found->profile);
        }
    }
    if (!pin.failed_dependencies_.empty()) pin.readiness_ = NativeTerrainShapingPageReadiness::failed;
    else if (!pin.unresolved_dependencies_.empty()) pin.readiness_ = NativeTerrainShapingPageReadiness::unresolved;
    else {
        NativeTerrainShapingRequest request;
        request.generation_revision = state_->revision; request.page_key = page_key;
        request.town_overrides = std::move(town_overrides); request.site_profiles = std::move(profiles);
        pin.snapshot_ = std::make_shared<const NativeTerrainShapingSnapshot>(definition_, std::move(request));
        pin.readiness_ = NativeTerrainShapingPageReadiness::ready;
    }
    return pin;
}

} // namespace voxel::world_backend
