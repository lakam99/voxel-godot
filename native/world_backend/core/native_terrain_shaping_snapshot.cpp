#include "native_terrain_shaping_snapshot.hpp"

#include "legacy_seed_hash.hpp"
#include "sha256.hpp"

#include <algorithm>
#include <array>
#include <cmath>
#include <cstring>
#include <limits>
#include <tuple>
#include <utility>

namespace voxel::world_backend {
namespace {

constexpr std::int32_t MAX_ABS_SITE_CELL = 1000000;
constexpr std::int32_t DEFAULT_TOWN_RADIUS_CELLS = 30;
constexpr double TOWN_SPAWN_CHANCE = 0.18;

class Writer final {
public:
    void u8(const std::uint8_t value) { bytes_.push_back(value); }
    void u32(const std::uint32_t value) { for (unsigned shift = 0; shift < 32; shift += 8) bytes_.push_back(static_cast<std::uint8_t>(value >> shift)); }
    void u64(const std::uint64_t value) { for (unsigned shift = 0; shift < 64; shift += 8) bytes_.push_back(static_cast<std::uint8_t>(value >> shift)); }
    void i32(const std::int32_t value) { u32(static_cast<std::uint32_t>(value)); }
    void text(const std::string &value) { u64(static_cast<std::uint64_t>(value.size())); bytes_.insert(bytes_.end(), value.begin(), value.end()); }
    void digest(const Sha256Digest &value) { bytes_.insert(bytes_.end(), value.begin(), value.end()); }
    void f32(const float value) { std::uint32_t bits = 0; std::memcpy(&bits, &value, sizeof(bits)); u32(bits); }
    void f64(const double value) { std::uint64_t bits = 0; std::memcpy(&bits, &value, sizeof(bits)); u64(bits); }
    std::vector<std::uint8_t> finish() && { return std::move(bytes_); }
private:
    std::vector<std::uint8_t> bytes_;
};

bool region_less(const NativeTownRegionOverride &left, const NativeTownRegionOverride &right) noexcept {
    return left.region_x < right.region_x || (left.region_x == right.region_x && left.region_z < right.region_z);
}

bool rect_valid(const NativeHorizontalRect &rect) noexcept {
    const std::int64_t end_x = static_cast<std::int64_t>(rect.x) + rect.width;
    const std::int64_t end_z = static_cast<std::int64_t>(rect.z) + rect.depth;
    return rect.width > 0 && rect.depth > 0
        && std::abs(static_cast<std::int64_t>(rect.x)) <= MAX_ABS_SITE_CELL
        && std::abs(static_cast<std::int64_t>(rect.z)) <= MAX_ABS_SITE_CELL
        && end_x <= MAX_ABS_SITE_CELL && end_z <= MAX_ABS_SITE_CELL;
}

bool rect_contains(const NativeHorizontalRect &rect, const std::int32_t x, const std::int32_t z) noexcept {
    return static_cast<std::int64_t>(x) >= rect.x && static_cast<std::int64_t>(z) >= rect.z
        && static_cast<std::int64_t>(x) < static_cast<std::int64_t>(rect.x) + rect.width
        && static_cast<std::int64_t>(z) < static_cast<std::int64_t>(rect.z) + rect.depth;
}

std::optional<NativeHorizontalRect> intersection(const NativeHorizontalRect &left, const NativeHorizontalRect &right) noexcept {
    const std::int64_t low_x = std::max<std::int64_t>(left.x, right.x);
    const std::int64_t low_z = std::max<std::int64_t>(left.z, right.z);
    const std::int64_t high_x = std::min(static_cast<std::int64_t>(left.x) + left.width, static_cast<std::int64_t>(right.x) + right.width);
    const std::int64_t high_z = std::min(static_cast<std::int64_t>(left.z) + left.depth, static_cast<std::int64_t>(right.z) + right.depth);
    if (low_x >= high_x || low_z >= high_z) return std::nullopt;
    return NativeHorizontalRect{static_cast<std::int32_t>(low_x), static_cast<std::int32_t>(low_z),
        static_cast<std::int32_t>(high_x - low_x), static_cast<std::int32_t>(high_z - low_z)};
}

std::optional<NativeHorizontalRect> page_bounds_for(const NativeTerrainPageKey key) noexcept {
    const std::int64_t low_x = static_cast<std::int64_t>(key.x) * NativeTerrainShapingSnapshot::PAGE_CELLS;
    const std::int64_t low_z = static_cast<std::int64_t>(key.z) * NativeTerrainShapingSnapshot::PAGE_CELLS;
    const std::int64_t one_past_i32 = static_cast<std::int64_t>(std::numeric_limits<std::int32_t>::max()) + 1;
    const std::int64_t sample_x_min = static_cast<std::int64_t>(key.x - 2LL) * NativeTerrainShapingSnapshot::PAGE_CELLS;
    const std::int64_t sample_x_max = static_cast<std::int64_t>(key.x + 2LL) * NativeTerrainShapingSnapshot::PAGE_CELLS;
    const std::int64_t sample_z_min = static_cast<std::int64_t>(key.z - 2LL) * NativeTerrainShapingSnapshot::PAGE_CELLS;
    const std::int64_t sample_z_max = static_cast<std::int64_t>(key.z + 2LL) * NativeTerrainShapingSnapshot::PAGE_CELLS;
    if (low_x < std::numeric_limits<std::int32_t>::min() || low_x > std::numeric_limits<std::int32_t>::max()
        || low_z < std::numeric_limits<std::int32_t>::min() || low_z > std::numeric_limits<std::int32_t>::max()
        || low_x + NativeTerrainShapingSnapshot::PAGE_CELLS > one_past_i32
        || low_z + NativeTerrainShapingSnapshot::PAGE_CELLS > one_past_i32
        || sample_x_min < std::numeric_limits<std::int32_t>::min()
        || sample_x_max > std::numeric_limits<std::int32_t>::max()
        || sample_z_min < std::numeric_limits<std::int32_t>::min()
        || sample_z_max > std::numeric_limits<std::int32_t>::max()) return std::nullopt;
    return NativeHorizontalRect{static_cast<std::int32_t>(low_x), static_cast<std::int32_t>(low_z),
        NativeTerrainShapingSnapshot::PAGE_CELLS, NativeTerrainShapingSnapshot::PAGE_CELLS};
}

bool valid_utf8(const std::string &value) {
    try { (void)admit_raw_terrain_seed(value); return true; }
    catch (const std::invalid_argument &) { return false; }
}

double hash01(const AdmittedTerrainSeed &seed, const std::string &text) {
    std::vector<std::uint32_t> input = seed.code_points;
    input.push_back(':');
    for (const unsigned char character : text) input.push_back(character);
    return static_cast<double>(legacy_seed_hash(input) % 100000U) / 100000.0;
}

double town_distance(const std::int32_t x, const std::int32_t z, const NativeTownTerrainProfile &town) noexcept {
    // WorldGenerationSystem materializes a float32 Vector2 before length().
    const float dx = static_cast<float>(static_cast<std::int64_t>(x) - town.center_x);
    const float dz = static_cast<float>(static_cast<std::int64_t>(z) - town.center_z);
    return static_cast<double>(std::sqrt(dx * dx + dz * dz));
}

double eased(const double value) noexcept {
    const double unit = std::clamp(value, 0.0, 1.0);
    return unit * unit * (3.0 - 2.0 * unit);
}

std::int32_t checked_offset(const std::int32_t origin, const double offset) {
    const double result = static_cast<double>(origin) + std::round(offset);
    if (result < std::numeric_limits<std::int32_t>::min() || result > std::numeric_limits<std::int32_t>::max())
        throw std::out_of_range("native shaping sample leaves int32 cell domain");
    return static_cast<std::int32_t>(result);
}

[[noreturn]] void reject(const NativeTerrainShapingAdmissionFailure failure) {
    throw NativeTerrainShapingAdmissionError(failure);
}

Sha256Digest full_profile_digest(const NativeSiteTerrainProfile &site) {
    Writer writer;
    writer.u32(0x46535756U); // "VWSF"
    writer.u32(2); writer.i32(site.version);
    writer.text(site.world_seed_utf8); writer.text(site.site_id); writer.text(site.source_signature);
    writer.f64(site.cell_size_meters);
    writer.i32(site.core_cells.x); writer.i32(site.core_cells.z); writer.i32(site.core_cells.width); writer.i32(site.core_cells.depth);
    writer.i32(site.envelope_cells.x); writer.i32(site.envelope_cells.z); writer.i32(site.envelope_cells.width); writer.i32(site.envelope_cells.depth);
    writer.i32(site.reservation_cells.x); writer.i32(site.reservation_cells.z);
    writer.i32(site.reservation_cells.width); writer.i32(site.reservation_cells.depth);
    writer.f32(site.origin.x); writer.f32(site.origin.y); writer.f32(site.origin.z);
    writer.f64(site.level_meters); writer.i32(site.apron_cells);
    writer.u64(static_cast<std::uint64_t>(site.support_mask.size()));
    for (const std::uint8_t value : site.support_mask) writer.u8(value);
    for (const float value : site.distance_cells) writer.f32(value);
    writer.u64(static_cast<std::uint64_t>(site.ground_root_points.size()));
    for (const auto &point : site.ground_root_points) {
        writer.f32(point.x); writer.f32(point.y); writer.f32(point.z);
    }
    return sha256(std::move(writer).finish());
}

NativeSiteTerrainFragment crop_profile(
    const NativeAdmittedSiteTerrainProfile &site, const NativeHorizontalRect &crop) {
    NativeSiteTerrainFragment fragment;
    fragment.full_profile_digest = site.full_profile_digest();
    fragment.level_meters = site.level_meters(); fragment.apron_cells = site.apron_cells(); fragment.cropped_cells = crop;
    const std::size_t count = static_cast<std::size_t>(crop.width) * crop.depth;
    fragment.support_mask.reserve(count); fragment.distance_cells.reserve(count);
    const NativeHorizontalRect envelope = site.envelope_cells();
    for (std::int32_t z = crop.z; z < static_cast<std::int64_t>(crop.z) + crop.depth; ++z) {
        const std::size_t source = static_cast<std::size_t>(z - envelope.z) * envelope.width
            + static_cast<std::size_t>(crop.x - envelope.x);
        fragment.support_mask.insert(fragment.support_mask.end(), site.support_mask().begin() + source, site.support_mask().begin() + source + crop.width);
        fragment.distance_cells.insert(fragment.distance_cells.end(), site.distance_cells().begin() + source, site.distance_cells().begin() + source + crop.width);
    }
    return fragment;
}

WorldPhysicalContentIdentity page_identity(
    const WorldSourceDefinition &definition, const NativeTerrainPageKey page_key, const NativeHorizontalRect page_bounds,
    const std::vector<NativeTownRegionOverride> &towns, const std::vector<NativeSiteTerrainFragment> &fragments) {
    Writer writer;
    writer.u32(0x48535756U); // "VWSH"
    // Lifecycle generation revision is deliberately excluded: distant source
    // admission must not invalidate a page whose physical dependencies match.
    writer.u32(2); writer.digest(definition.physical_content_identity().digest);
    writer.i32(page_key.x); writer.i32(page_key.z);
    writer.i32(page_bounds.x); writer.i32(page_bounds.z); writer.i32(page_bounds.width); writer.i32(page_bounds.depth);
    writer.u64(static_cast<std::uint64_t>(towns.size()));
    for (const auto &record : towns) {
        writer.i32(record.region_x); writer.i32(record.region_z); writer.u8(record.has_town ? 1 : 0);
        if (record.has_town) {
            writer.i32(record.town.center_x); writer.i32(record.town.center_z);
            writer.i32(record.town.radius_cells); writer.f64(record.town.level_meters);
        }
    }
    writer.u64(static_cast<std::uint64_t>(fragments.size()));
    for (const auto &fragment : fragments) {
        writer.i32(fragment.cropped_cells.x); writer.i32(fragment.cropped_cells.z);
        writer.i32(fragment.cropped_cells.width); writer.i32(fragment.cropped_cells.depth);
        writer.f64(fragment.level_meters); writer.i32(fragment.apron_cells);
        writer.u64(static_cast<std::uint64_t>(fragment.support_mask.size()));
        for (const std::uint8_t value : fragment.support_mask) writer.u8(value);
        for (const float value : fragment.distance_cells) writer.f32(value);
    }
    return {sha256(std::move(writer).finish())};
}

} // namespace

bool NativeHorizontalRect::operator==(const NativeHorizontalRect &other) const noexcept {
    return x == other.x && z == other.z && width == other.width && depth == other.depth;
}
bool NativeTerrainPageKey::operator==(const NativeTerrainPageKey &other) const noexcept { return x == other.x && z == other.z; }

std::optional<NativeHorizontalRect> native_terrain_page_bounds(const NativeTerrainPageKey key) noexcept {
    return page_bounds_for(key);
}

NativeTerrainShapingAdmissionError::NativeTerrainShapingAdmissionError(const NativeTerrainShapingAdmissionFailure failure)
    : std::runtime_error("native terrain shaping page admission failed"), failure_(failure) {}
NativeTerrainShapingAdmissionFailure NativeTerrainShapingAdmissionError::failure() const noexcept { return failure_; }
NativeTerrainShapingPageQueryError::NativeTerrainShapingPageQueryError()
    : std::out_of_range("native terrain shaping query is outside its owner page") {}

NativeAdmittedSiteTerrainProfile::NativeAdmittedSiteTerrainProfile(
    WorldPhysicalContentIdentity source_definition_identity, Sha256Digest full_profile_digest,
    NativeSiteTerrainProfile profile)
    : source_definition_identity_(std::move(source_definition_identity)), full_profile_digest_(full_profile_digest),
      profile_(std::move(profile)) {}
const WorldPhysicalContentIdentity &NativeAdmittedSiteTerrainProfile::source_definition_identity() const noexcept {
    return source_definition_identity_;
}
const Sha256Digest &NativeAdmittedSiteTerrainProfile::full_profile_digest() const noexcept { return full_profile_digest_; }
const std::string &NativeAdmittedSiteTerrainProfile::site_id() const noexcept { return profile_.site_id; }
const std::string &NativeAdmittedSiteTerrainProfile::source_signature() const noexcept { return profile_.source_signature; }
NativeHorizontalRect NativeAdmittedSiteTerrainProfile::reservation_cells() const noexcept { return profile_.reservation_cells; }
NativeHorizontalRect NativeAdmittedSiteTerrainProfile::envelope_cells() const noexcept { return profile_.envelope_cells; }
WorldFloat32Position NativeAdmittedSiteTerrainProfile::origin() const noexcept { return profile_.origin; }
double NativeAdmittedSiteTerrainProfile::level_meters() const noexcept { return profile_.level_meters; }
std::int32_t NativeAdmittedSiteTerrainProfile::apron_cells() const noexcept { return profile_.apron_cells; }
const std::vector<std::uint8_t> &NativeAdmittedSiteTerrainProfile::support_mask() const noexcept { return profile_.support_mask; }
const std::vector<float> &NativeAdmittedSiteTerrainProfile::distance_cells() const noexcept { return profile_.distance_cells; }

NativeAdmittedSiteTerrainProfileHandle admit_native_site_terrain_profile(
    const WorldSourceDefinition &definition, NativeSiteTerrainProfile profile) {
    if (profile.version != 1 || profile.site_id.empty()
        || profile.site_id.size() > NativeTerrainShapingSnapshot::MAX_SITE_ID_BYTES
        || profile.source_signature.empty() || profile.source_signature.size() > NativeTerrainShapingSnapshot::MAX_SOURCE_SIGNATURE_BYTES
        || !valid_utf8(profile.site_id) || !valid_utf8(profile.source_signature)
        || profile.world_seed_utf8 != definition.raw_terrain_seed().utf8
        || profile.cell_size_meters != definition.constants().cell_size_meters
        || !std::isfinite(profile.level_meters) || !rect_valid(profile.core_cells) || !rect_valid(profile.envelope_cells)
        || !rect_valid(profile.reservation_cells)
        || !std::isfinite(profile.origin.x) || !std::isfinite(profile.origin.y) || !std::isfinite(profile.origin.z)
        || std::abs(static_cast<double>(profile.origin.y) - profile.level_meters) > 0.0001
        || profile.apron_cells < 1 || profile.apron_cells > NativeTerrainShapingSnapshot::MAX_TOWN_APRON_CELLS)
        reject(NativeTerrainShapingAdmissionFailure::invalid_site);
    const std::int64_t grown_x = static_cast<std::int64_t>(profile.core_cells.x) - profile.apron_cells;
    const std::int64_t grown_z = static_cast<std::int64_t>(profile.core_cells.z) - profile.apron_cells;
    const std::int64_t grown_width = static_cast<std::int64_t>(profile.core_cells.width) + profile.apron_cells * 2LL;
    const std::int64_t grown_depth = static_cast<std::int64_t>(profile.core_cells.depth) + profile.apron_cells * 2LL;
    if (profile.envelope_cells.x != grown_x || profile.envelope_cells.z != grown_z
        || profile.envelope_cells.width != grown_width || profile.envelope_cells.depth != grown_depth)
        reject(NativeTerrainShapingAdmissionFailure::invalid_site);
    const std::uint64_t sample_count = static_cast<std::uint64_t>(profile.envelope_cells.width) * profile.envelope_cells.depth;
    if (sample_count > NativeTerrainShapingSnapshot::MAX_SITE_SAMPLES
        || profile.support_mask.size() != sample_count || profile.distance_cells.size() != sample_count)
        reject(NativeTerrainShapingAdmissionFailure::invalid_site);
    for (std::size_t sample = 0; sample < profile.support_mask.size(); ++sample) {
        if (profile.support_mask[sample] > 1 || !std::isfinite(profile.distance_cells[sample])
            || profile.distance_cells[sample] < 0.0F
            || (profile.support_mask[sample] == 1 && profile.distance_cells[sample] != 0.0F))
            reject(NativeTerrainShapingAdmissionFailure::invalid_site);
    }
    if (profile.ground_root_points.empty()
        || profile.ground_root_points.size() > NativeTerrainShapingSnapshot::MAX_GROUND_ROOT_POINTS
        || profile.ground_root_points.size() % 4 != 0)
        reject(NativeTerrainShapingAdmissionFailure::invalid_site);
    const double minimum_x = static_cast<double>(profile.core_cells.x) * profile.cell_size_meters;
    const double maximum_x = static_cast<double>(static_cast<std::int64_t>(profile.core_cells.x) + profile.core_cells.width - 1)
        * profile.cell_size_meters;
    const double minimum_z = static_cast<double>(profile.core_cells.z) * profile.cell_size_meters;
    const double maximum_z = static_cast<double>(static_cast<std::int64_t>(profile.core_cells.z) + profile.core_cells.depth - 1)
        * profile.cell_size_meters;
    for (const auto &point : profile.ground_root_points) {
        if (!std::isfinite(point.x) || !std::isfinite(point.y) || !std::isfinite(point.z)
            || std::abs(static_cast<double>(point.y) - profile.level_meters) > 0.061
            || point.x < minimum_x || point.x > maximum_x || point.z < minimum_z || point.z > maximum_z)
            reject(NativeTerrainShapingAdmissionFailure::invalid_site);
    }
    const Sha256Digest digest = full_profile_digest(profile);
    return NativeAdmittedSiteTerrainProfileHandle(new NativeAdmittedSiteTerrainProfile(
        definition.physical_content_identity(), digest, std::move(profile)));
}

NativeTerrainShapingSnapshot::NativeTerrainShapingSnapshot(WorldSourceDefinition definition, NativeTerrainShapingRequest request)
    : definition_(std::move(definition)), generation_revision_(request.generation_revision), page_key_(request.page_key),
      town_overrides_(std::move(request.town_overrides)) {
    if (generation_revision_ == 0) reject(NativeTerrainShapingAdmissionFailure::missing_generation_revision);
    const auto bounds = page_bounds_for(page_key_);
    if (!bounds) reject(NativeTerrainShapingAdmissionFailure::invalid_page);
    page_bounds_ = *bounds;
    if (town_overrides_.size() > MAX_TOWN_DEPENDENCIES)
        reject(NativeTerrainShapingAdmissionFailure::town_dependency_count);
    std::sort(town_overrides_.begin(), town_overrides_.end(), region_less);
    for (std::size_t index = 0; index < town_overrides_.size(); ++index) {
        const auto &record = town_overrides_[index];
        if (index > 0 && record.region_x == town_overrides_[index - 1].region_x && record.region_z == town_overrides_[index - 1].region_z)
            reject(NativeTerrainShapingAdmissionFailure::duplicate_town_region);
        if (record.region_x < page_key_.x - 1 || record.region_x > page_key_.x + 1
            || record.region_z < page_key_.z - 1 || record.region_z > page_key_.z + 1)
            reject(NativeTerrainShapingAdmissionFailure::town_dependency_scope);
        if (!record.has_town) continue;
        const auto &town = record.town;
        const std::int64_t expected_x = static_cast<std::int64_t>(record.region_x) * PAGE_CELLS;
        const std::int64_t expected_z = static_cast<std::int64_t>(record.region_z) * PAGE_CELLS;
        if (town.region_x != record.region_x || town.region_z != record.region_z
            || town.center_x != expected_x || town.center_z != expected_z || town.radius_cells <= 0
            || town.radius_cells > PAGE_CELLS - MAX_TOWN_APRON_CELLS || !std::isfinite(town.level_meters))
            reject(NativeTerrainShapingAdmissionFailure::invalid_town);
    }
    auto profiles = std::move(request.site_profiles);
    if (profiles.size() > PAGE_SAMPLE_CAPACITY)
        reject(NativeTerrainShapingAdmissionFailure::site_profile_count);
    for (const auto &site : profiles) {
        if (!site || !(site->source_definition_identity() == definition_.physical_content_identity()))
            reject(NativeTerrainShapingAdmissionFailure::invalid_site);
    }
    std::sort(profiles.begin(), profiles.end(), [](const auto &left, const auto &right) {
        return left->site_id() < right->site_id();
    });
    std::array<std::uint8_t, PAGE_SAMPLE_CAPACITY> occupied{};
    for (std::size_t index = 0; index < profiles.size(); ++index) {
        const auto &site = *profiles[index];
        if (index > 0 && site.site_id() == profiles[index - 1]->site_id())
            reject(NativeTerrainShapingAdmissionFailure::duplicate_site_id);
        const auto crop = intersection(site.envelope_cells(), page_bounds_);
        if (!crop) reject(NativeTerrainShapingAdmissionFailure::site_outside_page);
        const std::size_t fragment_samples = static_cast<std::size_t>(crop->width) * crop->depth;
        if (fragment_samples > PAGE_SAMPLE_CAPACITY - retained_site_samples_)
            reject(NativeTerrainShapingAdmissionFailure::overlapping_sites);
        for (std::int32_t z = crop->z; z < static_cast<std::int64_t>(crop->z) + crop->depth; ++z) {
            const std::size_t page_row = static_cast<std::size_t>(z - page_bounds_.z) * PAGE_CELLS;
            for (std::int32_t x = crop->x; x < static_cast<std::int64_t>(crop->x) + crop->width; ++x) {
                const std::size_t page_index = page_row + static_cast<std::size_t>(x - page_bounds_.x);
                if (occupied[page_index] != 0) reject(NativeTerrainShapingAdmissionFailure::overlapping_sites);
                occupied[page_index] = 1;
            }
        }
        NativeSiteTerrainFragment fragment = crop_profile(site, *crop);
        retained_site_samples_ += fragment_samples;
        site_fragments_.push_back(std::move(fragment));
    }
    std::sort(site_fragments_.begin(), site_fragments_.end(), [](const auto &left, const auto &right) {
        return std::tie(left.cropped_cells.x, left.cropped_cells.z, left.cropped_cells.width, left.cropped_cells.depth)
            < std::tie(right.cropped_cells.x, right.cropped_cells.z, right.cropped_cells.width, right.cropped_cells.depth);
    });
    physical_content_identity_ = page_identity(definition_, page_key_, page_bounds_, town_overrides_, site_fragments_);
}

const WorldSourceDefinition &NativeTerrainShapingSnapshot::definition() const noexcept { return definition_; }
std::uint64_t NativeTerrainShapingSnapshot::generation_revision() const noexcept { return generation_revision_; }
NativeTerrainPageKey NativeTerrainShapingSnapshot::page_key() const noexcept { return page_key_; }
NativeHorizontalRect NativeTerrainShapingSnapshot::page_bounds() const noexcept { return page_bounds_; }
const WorldPhysicalContentIdentity &NativeTerrainShapingSnapshot::physical_content_identity() const noexcept { return physical_content_identity_; }
const std::vector<NativeTownRegionOverride> &NativeTerrainShapingSnapshot::town_overrides() const noexcept { return town_overrides_; }
const std::vector<NativeSiteTerrainFragment> &NativeTerrainShapingSnapshot::site_fragments() const noexcept { return site_fragments_; }
std::size_t NativeTerrainShapingSnapshot::retained_site_samples() const noexcept { return retained_site_samples_; }
bool NativeTerrainShapingSnapshot::owns_cell(const std::int32_t cell_x, const std::int32_t cell_z) const noexcept {
    return rect_contains(page_bounds_, cell_x, cell_z);
}
void NativeTerrainShapingSnapshot::require_owned(const std::int32_t cell_x, const std::int32_t cell_z) const {
    if (!owns_cell(cell_x, cell_z)) throw NativeTerrainShapingPageQueryError();
}

const NativeTownRegionOverride *NativeTerrainShapingSnapshot::find_override(const std::int32_t region_x, const std::int32_t region_z) const noexcept {
    NativeTownRegionOverride key; key.region_x = region_x; key.region_z = region_z;
    const auto found = std::lower_bound(town_overrides_.begin(), town_overrides_.end(), key, region_less);
    return found != town_overrides_.end() && found->region_x == region_x && found->region_z == region_z ? &*found : nullptr;
}

std::optional<NativeTownTerrainProfile> NativeTerrainShapingSnapshot::town_dependency(
    const std::int32_t region_x, const std::int32_t region_z, const NaturalSurfaceSampler &natural_surface) const {
    if (region_x < page_key_.x - 1 || region_x > page_key_.x + 1 || region_z < page_key_.z - 1 || region_z > page_key_.z + 1)
        throw NativeTerrainShapingPageQueryError();
    if (!natural_surface) throw std::invalid_argument("native shaping requires a natural surface sampler");
    if (const auto *record = find_override(region_x, region_z))
        return record->has_town ? std::optional(record->town) : std::nullopt;
    const bool forced = region_x == 1 && region_z == 0;
    const std::string region = std::to_string(region_x) + "," + std::to_string(region_z);
    if (!forced && hash01(definition_.raw_terrain_seed(), "town:" + region) > TOWN_SPAWN_CHANCE) return std::nullopt;
    const auto center_x = static_cast<std::int32_t>(static_cast<std::int64_t>(region_x) * PAGE_CELLS);
    const auto center_z = static_cast<std::int32_t>(static_cast<std::int64_t>(region_z) * PAGE_CELLS);
    const double natural = natural_surface(center_x, center_z);
    if (!std::isfinite(natural)) throw std::invalid_argument("natural surface sampler returned a nonfinite value");
    const double minimum = definition_.constants().water_level_meters + 3.0;
    const double cell_size = definition_.constants().cell_size_meters;
    const double rounded_level = std::round(std::max(natural, minimum) / cell_size) * cell_size;
    const double level = rounded_level < minimum ? minimum : rounded_level > 52.0 ? 52.0 : rounded_level;
    const double radius_roll = hash01(definition_.raw_terrain_seed(), "town-radius:" + region);
    std::int32_t radius = DEFAULT_TOWN_RADIUS_CELLS + static_cast<std::int32_t>(radius_roll * 8.0);
    if (!forced) {
        const double class_roll = hash01(definition_.raw_terrain_seed(), "town-size-class:" + region);
        if (class_roll < 0.34) radius = 22 + static_cast<std::int32_t>(radius_roll * 7.0);
        else if (class_roll > 0.82) radius = 38 + static_cast<std::int32_t>(radius_roll * 9.0);
    }
    return NativeTownTerrainProfile{region_x, region_z, center_x, center_z, radius, level};
}

std::optional<NativeTownTerrainProfile> NativeTerrainShapingSnapshot::town_region_at_cell(
    const std::int32_t cell_x, const std::int32_t cell_z, const NaturalSurfaceSampler &natural_surface) const {
    require_owned(cell_x, cell_z);
    for (std::int32_t rz = page_key_.z - 1; rz <= page_key_.z + 1; ++rz) {
        for (std::int32_t rx = page_key_.x - 1; rx <= page_key_.x + 1; ++rx) {
            const auto town = town_dependency(rx, rz, natural_surface);
            if (town && town_distance(cell_x, cell_z, *town) <= town->radius_cells) return town;
        }
    }
    return std::nullopt;
}

std::optional<NativeTownTerrainProfile> NativeTerrainShapingSnapshot::town_region_for_surface_cell(
    const std::int32_t cell_x, const std::int32_t cell_z, const NaturalSurfaceSampler &natural_surface) const {
    require_owned(cell_x, cell_z);
    std::optional<NativeTownTerrainProfile> best; double best_distance = std::numeric_limits<double>::infinity();
    for (std::int32_t rz = page_key_.z - 1; rz <= page_key_.z + 1; ++rz) {
        for (std::int32_t rx = page_key_.x - 1; rx <= page_key_.x + 1; ++rx) {
            const auto town = town_dependency(rx, rz, natural_surface);
            if (!town) continue;
            const double candidate_distance = town_distance(cell_x, cell_z, *town);
            const double maximum = town->radius_cells + town_slope_apron_cells(*town, natural_surface);
            if (candidate_distance <= maximum && candidate_distance < best_distance) {
                best = town; best_distance = candidate_distance;
            }
        }
    }
    return best;
}

std::int32_t NativeTerrainShapingSnapshot::town_slope_apron_cells(
    const NativeTownTerrainProfile &town, const NaturalSurfaceSampler &natural_surface) const {
    if (!natural_surface) throw std::invalid_argument("native shaping requires a natural surface sampler");
    std::int32_t apron = std::max(18, static_cast<std::int32_t>(std::ceil(town.radius_cells * 0.55)));
    const std::int32_t maximum = std::max(apron, MAX_TOWN_APRON_CELLS);
    constexpr float diagonal = 0.70710676908493041992F;
    constexpr float directions[8][2] = {{1,0},{-1,0},{0,1},{0,-1},{diagonal,diagonal},{-diagonal,diagonal},{diagonal,-diagonal},{-diagonal,-diagonal}};
    for (unsigned pass = 0; pass < 3; ++pass) {
        double max_difference = 0.0;
        const float sample_distance = static_cast<float>(town.radius_cells) + static_cast<float>(apron);
        for (const auto &direction : directions) {
            const auto x = checked_offset(town.center_x, direction[0] * sample_distance);
            const auto z = checked_offset(town.center_z, direction[1] * sample_distance);
            const double sample = natural_surface(x, z);
            if (!std::isfinite(sample)) throw std::invalid_argument("natural surface sampler returned a nonfinite value");
            max_difference = std::max(max_difference, std::abs(sample - town.level_meters));
        }
        const double required_without_margin = std::ceil(
            max_difference / std::max(0.01, definition_.constants().cell_size_meters * 0.52));
        if (!std::isfinite(required_without_margin)
            || required_without_margin > static_cast<double>(std::numeric_limits<std::int32_t>::max() - 6))
            throw std::out_of_range("town apron requirement leaves int32 domain");
        const auto needed = static_cast<std::int32_t>(required_without_margin) + 6;
        const std::int32_t next = std::min(maximum, std::max(apron, needed));
        if (next == apron) break;
        apron = next;
    }
    return apron;
}

const NativeSiteTerrainFragment *NativeTerrainShapingSnapshot::site_fragment_at(
    const std::int32_t cell_x, const std::int32_t cell_z) const noexcept {
    for (const auto &fragment : site_fragments_) if (rect_contains(fragment.cropped_cells, cell_x, cell_z)) return &fragment;
    return nullptr;
}

double NativeTerrainShapingSnapshot::surface_y(
    const std::int32_t cell_x, const std::int32_t cell_z, const NaturalSurfaceSampler &natural_surface) const {
    require_owned(cell_x, cell_z);
    if (!natural_surface) throw std::invalid_argument("native shaping requires a natural surface sampler");
    if (const auto town = town_region_for_surface_cell(cell_x, cell_z, natural_surface)) {
        const double distance = town_distance(cell_x, cell_z, *town);
        if (distance <= town->radius_cells) return town->level_meters;
        const std::int32_t apron = town_slope_apron_cells(*town, natural_surface);
        const float dx = static_cast<float>(static_cast<std::int64_t>(cell_x) - town->center_x);
        const float dz = static_cast<float>(static_cast<std::int64_t>(cell_z) - town->center_z);
        const float sample_distance = static_cast<float>(town->radius_cells + apron);
        const auto outer_x = checked_offset(town->center_x, dx / static_cast<float>(distance) * sample_distance);
        const auto outer_z = checked_offset(town->center_z, dz / static_cast<float>(distance) * sample_distance);
        const double outer = natural_surface(outer_x, outer_z);
        if (!std::isfinite(outer)) throw std::invalid_argument("natural surface sampler returned a nonfinite value");
        return town->level_meters + (outer - town->level_meters) * eased((distance - town->radius_cells) / std::max(1.0, static_cast<double>(apron)));
    }
    const double natural = natural_surface(cell_x, cell_z);
    if (!std::isfinite(natural)) throw std::invalid_argument("natural surface sampler returned a nonfinite value");
    const auto *fragment = site_fragment_at(cell_x, cell_z);
    if (!fragment) return natural;
    const std::size_t index = static_cast<std::size_t>(cell_z - fragment->cropped_cells.z) * fragment->cropped_cells.width
        + static_cast<std::size_t>(cell_x - fragment->cropped_cells.x);
    const double blend = std::clamp(static_cast<double>(fragment->distance_cells[index]) / fragment->apron_cells, 0.0, 1.0);
    return fragment->level_meters + (natural - fragment->level_meters) * eased(blend);
}

bool NativeTerrainShapingSnapshot::town_core_contains(
    const std::int32_t cell_x, const std::int32_t cell_z, const NaturalSurfaceSampler &natural_surface) const {
    return town_region_at_cell(cell_x, cell_z, natural_surface).has_value();
}

bool NativeTerrainShapingSnapshot::site_core_contains(const std::int32_t cell_x, const std::int32_t cell_z) const {
    require_owned(cell_x, cell_z);
    const auto *fragment = site_fragment_at(cell_x, cell_z);
    if (!fragment) return false;
    const std::size_t index = static_cast<std::size_t>(cell_z - fragment->cropped_cells.z) * fragment->cropped_cells.width
        + static_cast<std::size_t>(cell_x - fragment->cropped_cells.x);
    return fragment->support_mask[index] != 0;
}

bool NativeTerrainShapingSnapshot::protects_minimum_overburden(
    const std::int32_t cell_x, const std::int32_t cell_z, const NaturalSurfaceSampler &natural_surface) const {
    require_owned(cell_x, cell_z);
    return town_region_for_surface_cell(cell_x, cell_z, natural_surface).has_value() || site_core_contains(cell_x, cell_z);
}

} // namespace voxel::world_backend
