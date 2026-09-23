#include "native_surface_tree_presence.hpp"

#include <algorithm>
#include <cmath>
#include <cstring>
#include <limits>
#include <tuple>

namespace voxel::world_backend {
namespace {

[[noreturn]] void reject() { throw NativeSurfaceTreePresenceRejected(); }

class Writer final {
public:
    void u8(std::uint8_t v) { bytes.push_back(v); }
    void u32(std::uint32_t v) { for (int s = 24; s >= 0; s -= 8) u8(static_cast<std::uint8_t>(v >> s)); }
    void u64(std::uint64_t v) { for (int s = 56; s >= 0; s -= 8) u8(static_cast<std::uint8_t>(v >> s)); }
    void i32(std::int32_t v) { u32(static_cast<std::uint32_t>(v)); }
    void digest(const Sha256Digest &d) { bytes.insert(bytes.end(), d.begin(), d.end()); }
    void text(const std::string &v) { u32(static_cast<std::uint32_t>(v.size())); bytes.insert(bytes.end(), v.begin(), v.end()); }
    void rect(const StructureExclusionRect &r) { i32(r.min_x); i32(r.min_z); i32(r.max_x); i32(r.max_z); }
    std::vector<std::uint8_t> bytes;
};

std::int64_t floor_grid(std::int64_t cell, std::int64_t size) {
    return cell >= 0 ? cell / size : (cell - size + 1) / size;
}

bool overlaps(const StructureExclusionRect &r, std::int64_t lo_x, std::int64_t lo_z,
    std::int64_t hi_x, std::int64_t hi_z) {
    return static_cast<std::int64_t>(r.min_x) <= hi_x && static_cast<std::int64_t>(r.max_x) >= lo_x
        && static_cast<std::int64_t>(r.min_z) <= hi_z && static_cast<std::int64_t>(r.max_z) >= lo_z;
}

std::int32_t margin_cells(double radius, double exclusion, double cell_size) {
    if (!std::isfinite(radius) || !std::isfinite(exclusion) || !std::isfinite(cell_size)
        || radius < 0.0 || exclusion < 0.0 || cell_size <= 0.0) reject();
    const double rounded = std::ceil(std::max(0.0, radius + exclusion) / cell_size);
    if (!std::isfinite(rounded) || rounded > 4096.0) reject();
    return static_cast<std::int32_t>(rounded);
}

void validate_records(std::vector<StructureExclusionRecord> &records) {
    if (records.size() > 65536U) reject();
    std::sort(records.begin(), records.end(), [](const auto &a, const auto &b) { return a.id < b.id; });
    for (std::size_t i = 0; i < records.size(); ++i) {
        const auto &r = records[i];
        if (r.id.empty() || r.id.size() > 1024U || r.id.find('\0') != std::string::npos
            || r.bounds.min_x > r.bounds.max_x || r.bounds.min_z > r.bounds.max_z
            || (i != 0U && records[i - 1U].id == r.id)) reject();
    }
}

void write_records(Writer &w, const std::vector<StructureExclusionRecord> &records) {
    w.u32(static_cast<std::uint32_t>(records.size()));
    for (const auto &r : records) { w.text(r.id); w.rect(r.bounds); }
}

} // namespace

NativeSurfaceTreePresenceRejected::NativeSurfaceTreePresenceRejected()
    : std::invalid_argument("invalid source-bound tree exclusion halo") {}

NativeTreeExclusionHaloCapture NativeTreeExclusionHaloCapture::create(
    Sha256Digest world_digest, std::uint64_t world_generation,
    Sha256Digest center_exclusion_digest, StructureExclusionRect coverage,
    std::vector<StructureExclusionRecord> natural,
    std::vector<StructureExclusionRecord> terrain,
    std::vector<CitadelExclusionSource> citadels) {
    if (world_digest == Sha256Digest{} || world_generation == 0U
        || center_exclusion_digest == Sha256Digest{}
        || coverage.min_x > coverage.max_x || coverage.min_z > coverage.max_z
        || citadels.size() > 64U) reject();
    validate_records(natural); validate_records(terrain);
    std::sort(citadels.begin(), citadels.end(), [](const auto &a, const auto &b) {
        return std::tie(a.region_z, a.region_x) < std::tie(b.region_z, b.region_x);
    });
    for (std::size_t i = 0U; i < citadels.size(); ++i) {
        const auto &c = citadels[i];
        if (i != 0U && c.region_x == citadels[i - 1U].region_x
            && c.region_z == citadels[i - 1U].region_z) reject();
        if (c.status == CitadelSourceStatus::ready || c.status == CitadelSourceStatus::prepared) {
            if (c.source_key.empty() || c.source_signature.empty() || c.admission_generation == 0U
                || c.reservation.min_x >= c.reservation.max_x
                || c.reservation.min_z >= c.reservation.max_z) reject();
        } else if (c.status != CitadelSourceStatus::absent
            && c.status != CitadelSourceStatus::pending && c.status != CitadelSourceStatus::failed) reject();
        else if ((c.status != CitadelSourceStatus::absent
                && (c.reason.empty() || !c.source_key.empty()))
            || !c.source_signature.empty() || c.admission_generation != 0U
            || c.reservation.min_x != 0 || c.reservation.min_z != 0
            || c.reservation.max_x != 0 || c.reservation.max_z != 0) reject();
    }
    Writer w;
    w.u8('T'); w.u8('H'); w.u8('L'); w.u8('1');
    w.digest(world_digest); w.u64(world_generation); w.digest(center_exclusion_digest);
    w.rect(coverage); write_records(w, natural); write_records(w, terrain);
    w.u32(static_cast<std::uint32_t>(citadels.size()));
    for (const auto &c : citadels) {
        w.i32(c.region_x); w.i32(c.region_z); w.u8(static_cast<std::uint8_t>(c.status));
        w.text(c.reason); w.text(c.source_key); w.text(c.source_signature);
        w.u64(c.admission_generation); w.rect(c.reservation);
    }
    NativeTreeExclusionHaloCapture out;
    out.world_digest_ = world_digest; out.world_generation_ = world_generation;
    out.center_exclusion_digest_ = center_exclusion_digest; out.coverage_ = coverage;
    out.natural_ = std::move(natural); out.terrain_ = std::move(terrain);
    out.citadels_ = std::move(citadels); out.content_digest_ = sha256(w.bytes);
    return out;
}

const Sha256Digest &NativeTreeExclusionHaloCapture::world_digest() const noexcept { return world_digest_; }
std::uint64_t NativeTreeExclusionHaloCapture::world_generation() const noexcept { return world_generation_; }
const Sha256Digest &NativeTreeExclusionHaloCapture::center_exclusion_digest() const noexcept { return center_exclusion_digest_; }
const Sha256Digest &NativeTreeExclusionHaloCapture::content_digest() const noexcept { return content_digest_; }
const StructureExclusionRect &NativeTreeExclusionHaloCapture::coverage() const noexcept { return coverage_; }
const std::vector<StructureExclusionRecord> &NativeTreeExclusionHaloCapture::natural() const noexcept { return natural_; }
const std::vector<StructureExclusionRecord> &NativeTreeExclusionHaloCapture::terrain() const noexcept { return terrain_; }
const std::vector<CitadelExclusionSource> &NativeTreeExclusionHaloCapture::citadels() const noexcept { return citadels_; }

NativeSurfaceTreePresenceDecision evaluate_native_tree_exclusion_halo(
    std::int32_t cell_x, std::int32_t cell_z, double trunk_radius,
    double canopy_radius, double exclusion_margin, double cell_size_meters,
    const NativeTreeExclusionHaloCapture &halo) {
    NativeSurfaceTreePresenceDecision out;
    out.natural_margin_cells = margin_cells(trunk_radius, exclusion_margin, cell_size_meters);
    out.structure_margin_cells = margin_cells(canopy_radius, exclusion_margin, cell_size_meters);
    const auto widest = std::max(out.natural_margin_cells, out.structure_margin_cells);
    const std::int64_t lo_x = static_cast<std::int64_t>(cell_x) - widest;
    const std::int64_t hi_x = static_cast<std::int64_t>(cell_x) + widest;
    const std::int64_t lo_z = static_cast<std::int64_t>(cell_z) - widest;
    const std::int64_t hi_z = static_cast<std::int64_t>(cell_z) + widest;
    const auto &coverage = halo.coverage();
    if (lo_x < coverage.min_x || hi_x > coverage.max_x
        || lo_z < coverage.min_z || hi_z > coverage.max_z) reject();
    const auto low_region_x = floor_grid(lo_x, 2048), high_region_x = floor_grid(hi_x, 2048);
    const auto low_region_z = floor_grid(lo_z, 2048), high_region_z = floor_grid(hi_z, 2048);
    // margin_cells caps each radius at 4096, so at most 5x5 Citadel regions
    // intersect this footprint; the capture cap of 64 already covers that.
    // Check all crossed source states even if an earlier natural record blocks;
    // otherwise an incomplete capture could be disguised by a local blocker.
    for (auto rz = low_region_z; rz <= high_region_z; ++rz) {
        for (auto rx = low_region_x; rx <= high_region_x; ++rx) {
            const auto found = std::find_if(halo.citadels().begin(), halo.citadels().end(),
                [rx, rz](const auto &c) { return c.region_x == rx && c.region_z == rz; });
            // The adapter must have admitted the exact expanded coverage.
            // Under that receipt, source_not_requested means the candidate's
            // declared influence cannot touch this halo. The same ready
            // admission makes an unrelated failed source irrelevant.
            if (found == halo.citadels().end() || found->status == CitadelSourceStatus::pending) reject();
        }
    }
    const auto n = out.natural_margin_cells, s = out.structure_margin_cells;
    for (const auto &r : halo.natural()) {
        if (overlaps(r.bounds, static_cast<std::int64_t>(cell_x) - n,
            static_cast<std::int64_t>(cell_z) - n, static_cast<std::int64_t>(cell_x) + n,
            static_cast<std::int64_t>(cell_z) + n)) {
            out.presence = NativeSurfaceTreePresence::absent;
            out.blocker_kind = StructureExclusionKind::natural; out.blocker_id = r.id; break;
        }
    }
    if (out.presence == NativeSurfaceTreePresence::present) for (const auto &r : halo.terrain()) {
        if (overlaps(r.bounds, static_cast<std::int64_t>(cell_x) - s,
            static_cast<std::int64_t>(cell_z) - s, static_cast<std::int64_t>(cell_x) + s,
            static_cast<std::int64_t>(cell_z) + s)) {
            out.presence = NativeSurfaceTreePresence::absent;
            out.blocker_kind = StructureExclusionKind::terrain; out.blocker_id = r.id; break;
        }
    }
    if (out.presence == NativeSurfaceTreePresence::present) for (const auto &c : halo.citadels()) {
        if (c.region_x < low_region_x || c.region_x > high_region_x
            || c.region_z < low_region_z || c.region_z > high_region_z) continue;
        if (c.status != CitadelSourceStatus::ready && c.status != CitadelSourceStatus::prepared) continue;
        // Citadel reservation max is exclusive, unlike natural/terrain rects.
        if (static_cast<std::int64_t>(c.reservation.min_x) <= hi_x
            && static_cast<std::int64_t>(c.reservation.max_x) > lo_x
            && static_cast<std::int64_t>(c.reservation.min_z) <= hi_z
            && static_cast<std::int64_t>(c.reservation.max_z) > lo_z) {
            out.presence = NativeSurfaceTreePresence::absent;
            out.blocker_kind = StructureExclusionKind::citadel; out.blocker_id = c.source_key; break;
        }
    }
    out.halo_digest = halo.content_digest();
    return out;
}

NativeSurfaceTreePresenceDecision compose_native_surface_tree_presence(
    const NativeSurfacePropSourceOrderedStream &ordered,
    const NativeSurfacePropOrderedPlacement &placements, std::uint32_t ordinal,
    const NativeEffectiveTerrainSource &terrain,
    const NativeSurfaceTreeEcologyProfile &profile,
    const NativeTreeExclusionHaloCapture &halo) {
    if (halo.world_digest() != ordered.world_digest()
        || halo.world_generation() != ordered.world_generation()
        || halo.center_exclusion_digest() != ordered.exclusion_digest()) reject();
    const auto tree = NativeSurfaceTreeOrderedComposer::create(ordered, placements, ordinal, terrain, profile);
    const auto &entry = placements.entries()[ordinal];
    auto out = evaluate_native_tree_exclusion_halo(entry.cell_x, entry.cell_z,
        tree.input().trunk_radius, tree.input().canopy_radius,
        tree.input().exclusion_margin, terrain.pin().definition().constants().cell_size_meters, halo);
    out.tree_definition_digest = tree.content_digest();
    Writer w;
    w.u8('T'); w.u8('P'); w.u8('D'); w.u8('1');
    w.digest(tree.content_digest()); w.digest(halo.content_digest());
    w.digest(placements.content_digest()); w.digest(ordered.world_digest());
    w.u64(ordered.world_generation()); w.digest(ordered.exclusion_digest());
    w.u32(ordinal); w.text(entry.durable_id);
    w.i32(entry.cell_x); w.i32(entry.cell_z);
    w.i32(out.natural_margin_cells); w.i32(out.structure_margin_cells);
    w.u8(static_cast<std::uint8_t>(out.presence));
    w.u8(static_cast<std::uint8_t>(out.blocker_kind)); w.text(out.blocker_id);
    out.content_digest = sha256(w.bytes);
    return out;
}

} // namespace voxel::world_backend
