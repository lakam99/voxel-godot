#include "native_generated_feature_footprint_catalog.hpp"
#include "native_value.hpp"

#include <algorithm>
#include <array>
#include <limits>
#include <set>
#include <tuple>
#include <utility>

namespace voxel::world_backend {
namespace {

[[noreturn]] void reject() {
    throw NativeGeneratedFeatureFootprintCatalogRejected();
}

bool is_zero_digest(const Sha256Digest &digest) noexcept {
    return std::all_of(digest.begin(), digest.end(), [](const std::uint8_t byte) { return byte == 0U; });
}

bool utf8_byte_less(const std::string_view left, const std::string_view right) noexcept {
    return std::lexicographical_compare(left.begin(), left.end(), right.begin(), right.end(),
        [](const char left_byte, const char right_byte) noexcept {
            return static_cast<std::uint8_t>(static_cast<unsigned char>(left_byte))
                < static_cast<std::uint8_t>(static_cast<unsigned char>(right_byte));
        });
}

bool valid_channel(const NativeFeatureFootprintChannel channel) noexcept {
    switch (channel) {
    case NativeFeatureFootprintChannel::terrain_source:
    case NativeFeatureFootprintChannel::render:
    case NativeFeatureFootprintChannel::collision:
    case NativeFeatureFootprintChannel::navigation:
        return true;
    default:
        return false;
    }
}

void validate_limits(const NativeGeneratedFeatureFootprintCatalogLimits &limits) {
    const std::array<std::size_t, 7U> positive_limits = {
        limits.max_feature_id_bytes, limits.max_recipe_key_bytes, limits.max_entries,
        limits.max_runs_per_entry, limits.max_total_runs,
        limits.max_expanded_sections_per_entry, limits.max_canonical_bytes,
    };
    if (std::any_of(positive_limits.begin(), positive_limits.end(),
            [](const std::size_t value) { return value == 0U; })) reject();
    const std::array<std::size_t, 4U> u32_limits = {
        limits.max_feature_id_bytes, limits.max_recipe_key_bytes,
        limits.max_entries, limits.max_runs_per_entry,
    };
    if (std::any_of(u32_limits.begin(), u32_limits.end(),
            [](const std::size_t value) {
                return value > std::numeric_limits<std::uint32_t>::max();
            })) reject();
}

void validate_text(const std::string &value, const std::size_t max_bytes) {
    if (value.empty()) reject();
    if (value.size() > max_bytes) reject();
    try {
        static_cast<void>(NativeValue::string(value));
    } catch (const NativeValueRejected &) {
        reject();
    }
}

bool run_less(const NativeFeatureFootprintRun &left, const NativeFeatureFootprintRun &right) noexcept {
    const auto left_channel = static_cast<std::uint8_t>(left.channel);
    const auto right_channel = static_cast<std::uint8_t>(right.channel);
    return std::tie(left_channel, left.first.z, left.first.y, left.first.x, left.last_x_inclusive)
        < std::tie(right_channel, right.first.z, right.first.y, right.first.x, right.last_x_inclusive);
}

bool same_run_row(
    const NativeFeatureFootprintRun &left, const NativeFeatureFootprintRun &right) noexcept {
    return std::tie(left.channel, left.first.y, left.first.z)
        == std::tie(right.channel, right.first.y, right.first.z);
}

struct ChannelSectionKey final {
    NativeFeatureFootprintChannel channel;
    CellCoord section;
};

struct ChannelSectionKeyLess final {
    bool operator()(const ChannelSectionKey &left, const ChannelSectionKey &right) const noexcept {
        const auto left_channel = static_cast<std::uint8_t>(left.channel);
        const auto right_channel = static_cast<std::uint8_t>(right.channel);
        return std::tie(left_channel, left.section.z, left.section.y, left.section.x)
            < std::tie(right_channel, right.section.z, right.section.y, right.section.x);
    }
};

std::int32_t section_coordinate(const std::int32_t cell) noexcept {
    std::int32_t quotient = cell / NativeGeneratedFeatureFootprintCatalog::SECTION_SIZE;
    if (cell % NativeGeneratedFeatureFootprintCatalog::SECTION_SIZE < 0) --quotient;
    return quotient;
}

std::vector<NativeFeatureFootprintRun> canonical_runs(
    std::vector<NativeFeatureFootprintRun> runs,
    const NativeGeneratedFeatureFootprintCatalogLimits &limits) {
    // create() has already applied the raw per-entry cap before canonical
    // normalization, so only the semantic empty-set rejection belongs here.
    if (runs.empty()) reject();
    for (const NativeFeatureFootprintRun &run : runs) {
        if (!valid_channel(run.channel) || run.first.x > run.last_x_inclusive) reject();
    }
    std::sort(runs.begin(), runs.end(), run_less);

    std::vector<NativeFeatureFootprintRun> merged;
    merged.reserve(runs.size());
    for (const NativeFeatureFootprintRun &run : runs) {
        if (!merged.empty() && same_run_row(merged.back(), run)
            && static_cast<std::int64_t>(run.first.x)
                <= static_cast<std::int64_t>(merged.back().last_x_inclusive) + 1LL) {
            merged.back().last_x_inclusive = std::max(merged.back().last_x_inclusive, run.last_x_inclusive);
        } else {
            merged.push_back(run);
        }
    }

    std::set<ChannelSectionKey, ChannelSectionKeyLess> expanded;
    for (const NativeFeatureFootprintRun &run : merged) {
        const std::int32_t first_section_x = section_coordinate(run.first.x);
        const std::int32_t last_section_x = section_coordinate(run.last_x_inclusive);
        const std::uint64_t section_count = static_cast<std::uint64_t>(
            static_cast<std::int64_t>(last_section_x) - static_cast<std::int64_t>(first_section_x) + 1LL);
        if (section_count > limits.max_expanded_sections_per_entry) reject();
        const std::int32_t section_y = section_coordinate(run.first.y);
        const std::int32_t section_z = section_coordinate(run.first.z);
        for (std::int64_t section_x = first_section_x; section_x <= last_section_x; ++section_x) {
            expanded.insert({run.channel, {
                static_cast<std::int32_t>(section_x), section_y, section_z,
            }});
            if (expanded.size() > limits.max_expanded_sections_per_entry) reject();
        }
    }
    return merged;
}

NativeGeneratedFeatureFootprintEntry canonical_entry(
    NativeGeneratedFeatureFootprintEntry entry,
    const NativeGeneratedFeatureFootprintCatalogLimits &limits) {
    validate_text(entry.feature_id, limits.max_feature_id_bytes);
    validate_text(entry.recipe_key, limits.max_recipe_key_bytes);
    if (entry.recipe_revision == 0U || entry.footprint_schema_revision == 0U
        || is_zero_digest(entry.generated_definition_digest)
        || entry.declared_channel_mask != NATIVE_FEATURE_FOOTPRINT_ALL_CHANNELS) {
        reject();
    }
    entry.runs = canonical_runs(std::move(entry.runs), limits);
    return entry;
}

class CanonicalWriter final {
public:
    explicit CanonicalWriter(const std::size_t limit) : limit_(limit) {}

    void u8(const std::uint8_t value) {
        require(1U);
        bytes_.push_back(value);
    }
    void u32(const std::uint32_t value) {
        require(4U);
        for (int shift = 24; shift >= 0; shift -= 8) {
            bytes_.push_back(static_cast<std::uint8_t>(value >> shift));
        }
    }
    void i32(const std::int32_t value) { u32(static_cast<std::uint32_t>(value)); }
    void digest(const Sha256Digest &value) {
        require(value.size());
        bytes_.insert(bytes_.end(), value.begin(), value.end());
    }
    void text(const std::string &value) {
        u32(static_cast<std::uint32_t>(value.size()));
        require(value.size());
        bytes_.insert(bytes_.end(), value.begin(), value.end());
    }
    std::vector<std::uint8_t> finish() { return std::move(bytes_); }

private:
    void require(const std::size_t count) const {
        const std::size_t remaining = limit_ - bytes_.size();
        if (count > remaining) reject();
    }

    std::size_t limit_;
    std::vector<std::uint8_t> bytes_;
};

std::vector<std::uint8_t> canonical_catalog_binary(
    const Sha256Digest &source_digest,
    const std::uint32_t feature_source_revision,
    const std::vector<NativeGeneratedFeatureFootprintEntry> &entries,
    const std::size_t max_bytes) {
    CanonicalWriter writer(max_bytes);
    writer.u8('G'); writer.u8('F'); writer.u8('C'); writer.u8('1');
    writer.digest(source_digest);
    writer.u32(feature_source_revision);
    writer.u32(static_cast<std::uint32_t>(entries.size()));
    for (const NativeGeneratedFeatureFootprintEntry &entry : entries) {
        writer.text(entry.feature_id);
        writer.text(entry.recipe_key);
        writer.u32(entry.recipe_revision);
        writer.u32(entry.footprint_schema_revision);
        writer.digest(entry.generated_definition_digest);
        writer.u8(entry.declared_channel_mask);
        writer.u32(static_cast<std::uint32_t>(entry.runs.size()));
        for (const NativeFeatureFootprintRun &run : entry.runs) {
            writer.u8(static_cast<std::uint8_t>(run.channel));
            writer.i32(run.first.x); writer.i32(run.first.y); writer.i32(run.first.z);
            writer.i32(run.last_x_inclusive);
        }
    }
    return writer.finish();
}

} // namespace

NativeGeneratedFeatureFootprintCatalogRejected::NativeGeneratedFeatureFootprintCatalogRejected()
    : std::invalid_argument("invalid native generated-feature footprint catalog") {}

bool NativeFeatureFootprintRun::operator==(const NativeFeatureFootprintRun &other) const noexcept {
    return channel == other.channel && first == other.first && last_x_inclusive == other.last_x_inclusive;
}

bool NativeGeneratedFeatureFootprintEntry::operator==(
    const NativeGeneratedFeatureFootprintEntry &other) const noexcept {
    return feature_id == other.feature_id && recipe_key == other.recipe_key
        && recipe_revision == other.recipe_revision
        && footprint_schema_revision == other.footprint_schema_revision
        && generated_definition_digest == other.generated_definition_digest
        && declared_channel_mask == other.declared_channel_mask && runs == other.runs;
}

NativeGeneratedFeatureFootprintCatalog::NativeGeneratedFeatureFootprintCatalog(
    Sha256Digest source_digest,
    const std::uint32_t feature_source_revision,
    std::vector<NativeGeneratedFeatureFootprintEntry> entries,
    NativeGeneratedFeatureFootprintCatalogLimits limits,
    std::vector<std::uint8_t> canonical_binary,
    Sha256Digest content_digest)
    : source_digest_(source_digest), feature_source_revision_(feature_source_revision),
      entries_(std::move(entries)), limits_(limits), canonical_binary_(std::move(canonical_binary)),
      content_digest_(content_digest) {}

NativeGeneratedFeatureFootprintCatalog NativeGeneratedFeatureFootprintCatalog::create(
    Sha256Digest source_digest,
    const std::uint32_t feature_source_revision,
    std::vector<NativeGeneratedFeatureFootprintEntry> entries,
    NativeGeneratedFeatureFootprintCatalogLimits limits) {
    validate_limits(limits);
    if (is_zero_digest(source_digest) || feature_source_revision == 0U
        || entries.size() > limits.max_entries) {
        reject();
    }

    std::size_t raw_total_runs = 0U;
    for (const NativeGeneratedFeatureFootprintEntry &entry : entries) {
        if (entry.runs.size() > limits.max_runs_per_entry
            || entry.runs.size() > limits.max_total_runs - raw_total_runs) {
            reject();
        }
        raw_total_runs += entry.runs.size();
    }

    for (NativeGeneratedFeatureFootprintEntry &entry : entries) {
        entry = canonical_entry(std::move(entry), limits);
    }
    std::sort(entries.begin(), entries.end(), [](const auto &left, const auto &right) {
        return utf8_byte_less(left.feature_id, right.feature_id);
    });
    for (std::size_t index = 0U; index < entries.size(); ++index) {
        if (index != 0U && entries[index - 1U].feature_id == entries[index].feature_id) reject();
    }

    std::vector<std::uint8_t> canonical = canonical_catalog_binary(
        source_digest, feature_source_revision, entries, limits.max_canonical_bytes);
    const Sha256Digest digest = sha256(canonical);
    return NativeGeneratedFeatureFootprintCatalog(
        source_digest, feature_source_revision, std::move(entries), limits,
        std::move(canonical), digest);
}

const Sha256Digest &NativeGeneratedFeatureFootprintCatalog::source_digest() const noexcept {
    return source_digest_;
}

std::uint32_t NativeGeneratedFeatureFootprintCatalog::feature_source_revision() const noexcept {
    return feature_source_revision_;
}

const std::vector<NativeGeneratedFeatureFootprintEntry> &
NativeGeneratedFeatureFootprintCatalog::entries() const noexcept {
    return entries_;
}

const NativeGeneratedFeatureFootprintEntry *NativeGeneratedFeatureFootprintCatalog::find(
    const std::string_view feature_id) const noexcept {
    const auto found = std::lower_bound(entries_.begin(), entries_.end(), feature_id,
        [](const NativeGeneratedFeatureFootprintEntry &entry, const std::string_view id) {
            return utf8_byte_less(entry.feature_id, id);
        });
    if (found == entries_.end() || std::string_view(found->feature_id) != feature_id) return nullptr;
    return &*found;
}

NativeGeneratedFeatureFootprintCatalog NativeGeneratedFeatureFootprintCatalog::subset(
    const std::vector<std::string> &feature_ids) const {
    if (feature_ids.size() > limits_.max_entries) reject();
    std::vector<std::string> canonical_ids = feature_ids;
    std::sort(canonical_ids.begin(), canonical_ids.end(), [](const auto &left, const auto &right) {
        return utf8_byte_less(left, right);
    });
    std::vector<NativeGeneratedFeatureFootprintEntry> selected;
    selected.reserve(canonical_ids.size());
    for (std::size_t index = 0U; index < canonical_ids.size(); ++index) {
        if (index != 0U && canonical_ids[index - 1U] == canonical_ids[index]) reject();
        const NativeGeneratedFeatureFootprintEntry *entry = find(canonical_ids[index]);
        if (entry == nullptr) reject();
        selected.push_back(*entry);
    }
    return create(source_digest_, feature_source_revision_, std::move(selected), limits_);
}

const std::vector<std::uint8_t> &
NativeGeneratedFeatureFootprintCatalog::canonical_binary() const noexcept {
    return canonical_binary_;
}

const Sha256Digest &NativeGeneratedFeatureFootprintCatalog::content_digest() const noexcept {
    return content_digest_;
}

bool NativeGeneratedFeatureFootprintCatalog::operator==(
    const NativeGeneratedFeatureFootprintCatalog &other) const noexcept {
    return canonical_binary_ == other.canonical_binary_;
}

bool NativeGeneratedFeatureFootprintCatalog::operator!=(
    const NativeGeneratedFeatureFootprintCatalog &other) const noexcept {
    return !(*this == other);
}

} // namespace voxel::world_backend
