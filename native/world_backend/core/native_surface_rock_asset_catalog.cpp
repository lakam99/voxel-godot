#include "native_surface_rock_asset_catalog.hpp"

#include <algorithm>
#include <cmath>
#include <cstring>
#include <limits>
#include <utility>

namespace voxel::world_backend {
namespace {

[[noreturn]] void reject() { throw NativeSurfaceRockAssetCatalogRejected(); }

class Writer final {
public:
    void u8(const std::uint8_t value) { bytes_.push_back(value); }
    void u32(const std::uint32_t value) {
        for (int shift = 24; shift >= 0; shift -= 8) u8(static_cast<std::uint8_t>(value >> shift));
    }
    void f64(const double value) {
        std::uint64_t bits = 0U;
        std::memcpy(&bits, &value, sizeof(bits));
        for (int shift = 56; shift >= 0; shift -= 8) u8(static_cast<std::uint8_t>(bits >> shift));
    }
    void text(const std::string &value) {
        u32(static_cast<std::uint32_t>(value.size()));
        bytes_.insert(bytes_.end(), value.begin(), value.end());
    }
    void digest(const Sha256Digest &value) { bytes_.insert(bytes_.end(), value.begin(), value.end()); }
    std::vector<std::uint8_t> finish() { return std::move(bytes_); }
private:
    std::vector<std::uint8_t> bytes_;
};

// Godot String.unicode_at(i) iterates Unicode scalar values. Reject malformed
// UTF-8 instead of silently hashing bytes or Unicode replacement characters.
std::uint32_t next_codepoint(const std::string &text, std::size_t &index) {
    const auto first = static_cast<std::uint8_t>(text[index++]);
    if (first < 0x80U) return first;
    std::size_t trailing = 0U;
    std::uint32_t codepoint = 0U;
    std::uint32_t minimum = 0U;
    if (first >= 0xC2U && first <= 0xDFU) {
        trailing = 1U; codepoint = first & 0x1FU; minimum = 0x80U;
    } else if (first >= 0xE0U && first <= 0xEFU) {
        trailing = 2U; codepoint = first & 0x0FU; minimum = 0x800U;
    } else if (first >= 0xF0U && first <= 0xF4U) {
        trailing = 3U; codepoint = first & 0x07U; minimum = 0x10000U;
    } else reject();
    if (text.size() - index < trailing) reject();
    for (std::size_t offset = 0U; offset < trailing; ++offset) {
        const auto continuation = static_cast<std::uint8_t>(text[index++]);
        if ((continuation & 0xC0U) != 0x80U) reject();
        codepoint = (codepoint << 6U) | (continuation & 0x3FU);
    }
    if (codepoint < minimum || codepoint > 0x10FFFFU
        || (codepoint >= 0xD800U && codepoint <= 0xDFFFU)) reject();
    return codepoint;
}

void validate_text(const std::string &value) {
    if (value.empty() || value.size() > 4096U) reject();
    for (std::size_t index = 0U; index < value.size();) (void)next_codepoint(value, index);
}

bool has_tag(const std::vector<std::string> &tags, const std::string &biome) {
    return tags.empty() || std::find(tags.begin(), tags.end(), biome) != tags.end();
}

} // namespace

NativeSurfaceRockAssetCatalogRejected::NativeSurfaceRockAssetCatalogRejected()
    : std::invalid_argument("invalid native surface rock asset catalog") {}

std::uint32_t native_surface_rock_stable_hash(const std::string &utf8) {
    std::uint32_t hash = 2166136261U;
    for (std::size_t index = 0U; index < utf8.size();) {
        hash = (hash ^ next_codepoint(utf8, index)) * 16777619U;
    }
    return hash;
}

NativeSurfaceRockAssetCatalog::NativeSurfaceRockAssetCatalog(
    std::vector<NativeSurfaceRockAssetRecord> rows, std::map<std::string, std::size_t> last_by_id,
    NativeBiomeEnvironmentCatalog environment,
    std::vector<std::uint8_t> canonical, const Sha256Digest digest) noexcept
    : rows_(std::move(rows)), last_by_id_(std::move(last_by_id)), environment_(std::move(environment)),
      canonical_binary_(std::move(canonical)), content_digest_(digest) {}

NativeSurfaceRockAssetCatalog NativeSurfaceRockAssetCatalog::create(
    std::vector<NativeSurfaceRockAssetRecord> manifest_rows, NativeBiomeEnvironmentCatalog environment) {
    if (manifest_rows.empty() || manifest_rows.size() > 65536U) reject();
    std::vector<NativeSurfaceRockAssetRecord> enabled;
    enabled.reserve(manifest_rows.size());
    for (auto &row : manifest_rows) {
        if (!row.runtime_enabled) continue;
        // VisualAssetRegistry skips missing id/family rows. A ready native
        // snapshot records only the admitted effective registry entries.
        if (row.id.empty() || row.family.empty()) continue;
        validate_text(row.id); validate_text(row.family); validate_text(row.path);
        if (row.biome_tags.size() > 256U || !std::isfinite(row.size_x)
            || !std::isfinite(row.size_y) || !std::isfinite(row.size_z)
            || row.size_x < 0.0 || row.size_y < 0.0 || row.size_z < 0.0) reject();
        for (const auto &tag : row.biome_tags) validate_text(tag);
        enabled.push_back(std::move(row));
    }
    if (enabled.empty()) reject();
    std::map<std::string, std::size_t> last_by_id;
    for (std::size_t index = 0U; index < enabled.size(); ++index)
        last_by_id[enabled[index].id] = index;
    Writer writer;
    writer.u8('S'); writer.u8('R'); writer.u8('A'); writer.u8('1');
    writer.u32(SCHEMA_REVISION); writer.digest(environment.content_digest());
    writer.u32(static_cast<std::uint32_t>(enabled.size()));
    for (const auto &row : enabled) {
        writer.text(row.id); writer.text(row.family); writer.text(row.path);
        writer.u32(static_cast<std::uint32_t>(row.biome_tags.size()));
        for (const auto &tag : row.biome_tags) writer.text(tag);
        writer.f64(row.size_x); writer.f64(row.size_y); writer.f64(row.size_z);
    }
    auto bytes = writer.finish();
    const auto digest = sha256(bytes);
    return NativeSurfaceRockAssetCatalog(std::move(enabled), std::move(last_by_id), std::move(environment),
        std::move(bytes), digest);
}

NativeSurfaceRockAssetSelection NativeSurfaceRockAssetCatalog::select(
    const std::string &biome, const std::string &durable_prop_id) const {
    validate_text(biome); validate_text(durable_prop_id);
    const auto &profile = environment_.profile_for_biome(biome);
    NativeSurfaceRockAssetSelection result;
    result.schema_revision = SCHEMA_REVISION;
    result.asset_catalog_digest = content_digest_;
    result.environment_catalog_digest = environment_.content_digest();
    result.environment_profile_digest = environment_.profile_digest(biome);
    result.requested_biome = biome;
    result.resolved_profile_biome = profile.biome_id;
    result.durable_prop_id = durable_prop_id;
    result.rock_scale = profile.rock_scale;
    std::vector<std::string> candidates;
    for (const auto &family : profile.rock_families) {
        for (const auto &row : rows_) {
            if (row.family != family) continue;
            const auto &resolved = rows_[last_by_id_.at(row.id)];
            if (has_tag(resolved.biome_tags, biome))
                candidates.push_back(row.id);
        }
    }
    result.matched_biome_tag = !candidates.empty();
    if (candidates.empty()) {
        for (const auto &family : profile.rock_families)
            for (const auto &row : rows_)
                if (row.family == family) candidates.push_back(row.id);
    }
    if (candidates.empty()) return result;
    std::sort(candidates.begin(), candidates.end());
    result.candidate_count = static_cast<std::uint32_t>(candidates.size());
    const std::string key = "rock:" + biome + ":" + durable_prop_id;
    const std::uint32_t index = native_surface_rock_stable_hash(key) % result.candidate_count;
    result.asset_id = candidates[index];
    const auto &record = rows_[last_by_id_.at(result.asset_id)];
    result.asset_path = record.path;
    result.asset_size = {static_cast<float>(record.size_x),
        static_cast<float>(record.size_y), static_cast<float>(record.size_z)};
    if (!std::isfinite(result.asset_size.x) || !std::isfinite(result.asset_size.y)
        || !std::isfinite(result.asset_size.z)) reject();
    return result;
}

const Sha256Digest &NativeSurfaceRockAssetCatalog::content_digest() const noexcept { return content_digest_; }
const Sha256Digest &NativeSurfaceRockAssetCatalog::environment_digest() const noexcept {
    return environment_.content_digest();
}
const std::vector<std::uint8_t> &NativeSurfaceRockAssetCatalog::canonical_binary() const noexcept {
    return canonical_binary_;
}

} // namespace voxel::world_backend
