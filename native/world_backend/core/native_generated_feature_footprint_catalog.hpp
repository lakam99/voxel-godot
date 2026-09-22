#pragma once

#include "coordinates.hpp"
#include "sha256.hpp"

#include <cstddef>
#include <cstdint>
#include <stdexcept>
#include <string>
#include <string_view>
#include <vector>

namespace voxel::world_backend {

// A footprint names the cells whose derived artifact may change when one
// generated feature is removed or restored.  Runs are X-contiguous at a fixed
// Y/Z row.  The catalog canonicalizer merges overlap and adjacency, avoiding
// multiple wire identities for the same affected-cell set.
enum class NativeFeatureFootprintChannel : std::uint8_t {
    terrain_source = 1,
    render = 2,
    collision = 3,
    navigation = 4,
};

constexpr std::uint8_t NATIVE_FEATURE_FOOTPRINT_ALL_CHANNELS = 0x0fU;

struct NativeFeatureFootprintRun final {
    NativeFeatureFootprintChannel channel = NativeFeatureFootprintChannel::terrain_source;
    CellCoord first;
    std::int32_t last_x_inclusive = 0;

    bool operator==(const NativeFeatureFootprintRun &other) const noexcept;
};

struct NativeGeneratedFeatureFootprintEntry final {
    // Existing save-facing IDs are opaque. Admission validates their bytes but
    // never parses, trims, case-folds, or derives location from them.
    std::string feature_id;
    std::string recipe_key;
    std::uint32_t recipe_revision = 0;
    std::uint32_t footprint_schema_revision = 0;
    Sha256Digest generated_definition_digest{};
    // Every channel must be explicitly declared even when its run set is
    // empty. This distinguishes an intentionally non-colliding feature from
    // an incomplete producer.
    std::uint8_t declared_channel_mask = NATIVE_FEATURE_FOOTPRINT_ALL_CHANNELS;
    std::vector<NativeFeatureFootprintRun> runs;

    bool operator==(const NativeGeneratedFeatureFootprintEntry &other) const noexcept;
};

struct NativeGeneratedFeatureFootprintCatalogLimits final {
    std::size_t max_feature_id_bytes = 1024U;
    std::size_t max_recipe_key_bytes = 1024U;
    std::size_t max_entries = 65536U;
    std::size_t max_runs_per_entry = 4096U;
    std::size_t max_total_runs = 1048576U;
    std::size_t max_expanded_sections_per_entry = 65536U;
    std::size_t max_canonical_bytes = 64U * 1024U * 1024U;
};

class NativeGeneratedFeatureFootprintCatalogRejected final : public std::invalid_argument {
public:
    NativeGeneratedFeatureFootprintCatalogRejected();
};

// Immutable source-bound catalog value. The source digest is the canonical
// physical-world digest supplied by the owning backend; keeping only the
// digest here leaves this low-level value independent of world_source.hpp and
// prevents an include cycle when world-delta state later retains a catalog.
class NativeGeneratedFeatureFootprintCatalog final {
public:
    // Matches the native world-delta/collision artifact grid without making
    // this foundational value depend on world_delta_store.hpp.
    static constexpr std::int32_t SECTION_SIZE = 16;

    static NativeGeneratedFeatureFootprintCatalog create(
        Sha256Digest source_digest,
        std::uint32_t feature_source_revision,
        std::vector<NativeGeneratedFeatureFootprintEntry> entries,
        NativeGeneratedFeatureFootprintCatalogLimits limits = {});

    const Sha256Digest &source_digest() const noexcept;
    std::uint32_t feature_source_revision() const noexcept;
    const std::vector<NativeGeneratedFeatureFootprintEntry> &entries() const noexcept;
    const NativeGeneratedFeatureFootprintEntry *find(std::string_view feature_id) const noexcept;

    // Returns a new canonical catalog containing exactly the requested IDs.
    // Request order is irrelevant; duplicate or unknown IDs fail closed.
    NativeGeneratedFeatureFootprintCatalog subset(
        const std::vector<std::string> &feature_ids) const;

    // GFC1 uses explicit big-endian fixed-width integers, length-delimited
    // UTF-8 text, canonical unsigned-byte ID order, and canonical run order.
    const std::vector<std::uint8_t> &canonical_binary() const noexcept;
    const Sha256Digest &content_digest() const noexcept;

    bool operator==(const NativeGeneratedFeatureFootprintCatalog &other) const noexcept;
    bool operator!=(const NativeGeneratedFeatureFootprintCatalog &other) const noexcept;

private:
    NativeGeneratedFeatureFootprintCatalog(
        Sha256Digest source_digest,
        std::uint32_t feature_source_revision,
        std::vector<NativeGeneratedFeatureFootprintEntry> entries,
        NativeGeneratedFeatureFootprintCatalogLimits limits,
        std::vector<std::uint8_t> canonical_binary,
        Sha256Digest content_digest);

    Sha256Digest source_digest_{};
    std::uint32_t feature_source_revision_ = 0;
    std::vector<NativeGeneratedFeatureFootprintEntry> entries_;
    NativeGeneratedFeatureFootprintCatalogLimits limits_;
    std::vector<std::uint8_t> canonical_binary_;
    Sha256Digest content_digest_{};
};

} // namespace voxel::world_backend
