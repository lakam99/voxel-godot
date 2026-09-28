#pragma once

#include "native_terrain_shaping_snapshot.hpp"

#include <array>
#include <cstddef>
#include <cstdint>
#include <memory>
#include <optional>
#include <stdexcept>
#include <vector>

namespace voxel::world_backend {

struct NativeSiteSourceRegionKey {
    std::int32_t x = 0;
    std::int32_t z = 0;
    bool operator==(const NativeSiteSourceRegionKey &other) const noexcept;
};

// Exact native representation of CitadelSiteField.gd's deterministic v1
// candidate. It is derived from the pinned raw seed; callers cannot declare,
// omit, move, or relabel a source candidate.
struct NativeSiteSourceCandidate {
    NativeSiteSourceRegionKey region;
    std::string site_id;
    std::int32_t center_x = 0;
    std::int32_t center_z = 0;
    std::uint32_t recipe_seed = 0;
    NativeHorizontalRect declared_influence_cells;
};

std::optional<NativeSiteSourceCandidate> native_site_source_candidate_for_region(
    const WorldSourceDefinition &definition, NativeSiteSourceRegionKey region);

// Allocation-free scalar candidate for a borrowed shaping-page admission.
// It streams the exact site-id text through the four original SHA channels;
// no std::string, registry pin, or source-owned pointer survives a step. The
// caller binds an immutable source stamp across calls and supplies the shared
// frame quota. Decimal conversion and SHA input are both resumable.
class BorrowedSiteCandidateCursor final {
public:
    enum class Status : std::uint8_t { idle, pending, absent, ready, failed };
    struct Step {
        Status status = Status::idle;
        std::uint32_t consumed_ops = 0;
        std::uint32_t next_atomic_ops = 1;
    };
    Step begin(const WorldSourceDefinition &definition, NativeSiteSourceRegionKey region,
        std::uint32_t offered_ops) noexcept;
    Step advance(const WorldSourceDefinition &definition, std::uint32_t offered_ops) noexcept;
    void reset() noexcept;
    Status status() const noexcept;
    NativeSiteSourceRegionKey region() const noexcept;
    std::int32_t center_x() const noexcept;
    std::int32_t center_z() const noexcept;
    std::uint32_t recipe_seed() const noexcept;
    NativeHorizontalRect declared_influence_cells() const noexcept;
private:
    std::uint8_t text_byte(const WorldSourceDefinition &definition, std::size_t offset) const noexcept;
    std::size_t text_size(const WorldSourceDefinition &definition) const noexcept;
    std::array<std::array<char, 24>, 3> numbers_{};
    std::array<std::uint8_t, 3> number_lengths_{};
    Sha256State hash_;
    NativeSiteSourceRegionKey region_{};
    std::array<std::uint32_t, 4> channels_{};
    std::size_t input_offset_ = 0;
    std::uint8_t channel_ = 0;
    std::uint8_t phase_ = 0;
    std::uint8_t decimal_index_ = 0;
    std::uint8_t decimal_phase_ = 0;
    std::uint8_t decimal_reverse_index_ = 0;
    std::uint64_t decimal_remaining_ = 0;
    bool decimal_negative_ = false;
    Status status_ = Status::idle;
};

// Enumerates the same at-most-four source regions as pin_page without
// constructing a NativeTerrainShapingSnapshot. Stored indices refer only to
// the registry incarnation stamped by the external borrowed lease; no entry
// reference or shared_ptr is retained in the cursor.
class BorrowedShapingPageCursor final {
public:
    enum class Status : std::uint8_t { idle, pending, unresolved, failed, ready };
    struct Step {
        Status status = Status::idle;
        std::uint32_t consumed_ops = 0;
        std::uint32_t next_atomic_ops = 1;
    };
    Step begin(NativeTerrainPageKey page, std::uint32_t offered_ops) noexcept;
    void reset() noexcept;
    Status status() const noexcept;
    NativeTerrainPageKey page_key() const noexcept;
    NativeHorizontalRect page_bounds() const noexcept;
    std::size_t profile_count() const noexcept;
private:
    friend class NativeTerrainShapingRegistry;
    NativeTerrainPageKey page_{};
    NativeHorizontalRect bounds_{};
    NativeSiteSourceRegionKey low_region_{};
    NativeSiteSourceRegionKey high_region_{};
    NativeSiteSourceRegionKey region_{};
    BorrowedSiteCandidateCursor candidate_;
    std::array<std::size_t, 4> profile_indices_{};
    std::size_t profile_count_ = 0U;
    std::size_t entry_scan_index_ = 0U;
    bool unresolved_seen_ = false;
    bool failed_seen_ = false;
    std::uint8_t phase_ = 0U;
    Status status_ = Status::idle;
};

// Immutable typed replacement for CitadelSiteBuildQueue._canonical_request's
// physical inputs. The transitional Godot adapter must still recompute and
// compare the worker's legacy var_to_bytes sourceKey before admission; pure
// core deliberately does not duplicate Godot Variant serialization.
struct NativeSiteSourcePolicy {
    struct TownOverride {
        std::int32_t region_x = 0;
        std::int32_t region_z = 0;
        bool has_town = false;
        std::int64_t center_x = 0;
        std::int64_t center_z = 0;
        std::int64_t radius_cells = 0;
        double level_meters = 0.0;
    };
    std::uint32_t source_policy_revision = 1;
    std::uint32_t survey_generation_policy_revision = 1;
    std::string engine_version_utf8;
    std::vector<TownOverride> town_overrides;
    std::int64_t ordinary_region_cells = 0;
    double ordinary_spawn_chance = 0.0;
};

enum class NativeSiteSourceResolutionKind : std::uint8_t {
    absent = 1,
    prepared = 2,
    failed = 3,
};

struct NativeSiteSourceResolution {
    NativeSiteSourceRegionKey region;
    NativeSiteSourceResolutionKind kind = NativeSiteSourceResolutionKind::absent;
    WorldPhysicalContentIdentity request_identity;
    // Opaque legacy provenance, already checked by the transitional adapter
    // against CitadelSiteBuildQueue._canonical_request.
    std::string worker_source_key;
    // Empty only for prepared. Absent/failed preserve their bounded terminal
    // reason instead of being collapsed into ordinary empty terrain.
    std::string reason_code;
    // Prepared-only geometry receipt facts. The adapter verifies the worker
    // manifest; native admission binds those facts to the admitted profile.
    std::string manifest_source_signature;
    NativeHorizontalRect source_reservation_cells;
    NativeAdmittedSiteTerrainProfileHandle profile;
};

struct NativeTerrainShapingRegistryLimits {
    // Resident terminal decisions are a cache, not permanent world history.
    // Callers retire terminal regions after their page consumers drain, then
    // deterministically reconstruct them on later demand.
    std::size_t max_resident_resolutions = 4096;
    std::size_t max_batch_resolutions = 64;
    // Retired entries retain only compact terminal fingerprints, never raster
    // buffers. Exhaustion fails closed instead of forgetting world history.
    std::size_t max_retired_fingerprints = 65536;
    std::uint64_t max_revision = UINT64_MAX;
};

struct NativeTerrainShapingRegistryBatch {
    std::uint64_t expected_revision = 0;
    std::vector<NativeSiteSourceResolution> resolutions;
};

struct NativeTerrainShapingRegistryRetirement {
    std::uint64_t expected_revision = 0;
    std::vector<NativeSiteSourceRegionKey> regions;
};

enum class NativeTerrainShapingRegistryCommitStatus : std::uint8_t {
    committed = 1,
    no_change = 2,
};

struct NativeTerrainShapingRegistryReceipt {
    NativeTerrainShapingRegistryCommitStatus status = NativeTerrainShapingRegistryCommitStatus::no_change;
    std::uint64_t revision = 0;
};

enum class NativeTerrainShapingRegistryRejectReason : std::uint8_t {
    invalid_limits = 1,
    revision_conflict = 2,
    batch_limit = 3,
    duplicate_region = 4,
    invalid_region = 5,
    candidate_absent = 6,
    invalid_resolution = 7,
    terminal_conflict = 8,
    capacity_exceeded = 9,
    revision_exhausted = 10,
    invalid_policy = 11,
};

class NativeTerrainShapingRegistryRejected final : public std::runtime_error {
public:
    explicit NativeTerrainShapingRegistryRejected(NativeTerrainShapingRegistryRejectReason reason);
    NativeTerrainShapingRegistryRejectReason reason() const noexcept;
private:
    NativeTerrainShapingRegistryRejectReason reason_;
};

enum class NativeTerrainShapingPageReadiness : std::uint8_t {
    ready = 1,
    unresolved = 2,
    failed = 3,
};

// A pin copies registry provenance and owns its immutable local page snapshot.
// Later resolutions or retirement cannot mutate it. Registry provenance is
// deliberately separate from the page's physical-content identity.
class NativeTerrainShapingPagePin final {
public:
    NativeTerrainShapingPageReadiness readiness() const noexcept;
    NativeTerrainPageKey page_key() const noexcept;
    std::uint64_t registry_revision() const noexcept;
    const WorldPhysicalContentIdentity &registry_content_identity() const noexcept;
    const std::vector<NativeSiteSourceRegionKey> &dependencies() const noexcept;
    const std::vector<NativeSiteSourceRegionKey> &unresolved_dependencies() const noexcept;
    const std::vector<NativeSiteSourceRegionKey> &failed_dependencies() const noexcept;
    const std::shared_ptr<const NativeTerrainShapingSnapshot> &snapshot() const noexcept;

private:
    friend class NativeTerrainShapingRegistry;
    NativeTerrainShapingPageReadiness readiness_ = NativeTerrainShapingPageReadiness::unresolved;
    NativeTerrainPageKey page_key_;
    std::uint64_t registry_revision_ = 0;
    WorldPhysicalContentIdentity registry_content_identity_;
    std::vector<NativeSiteSourceRegionKey> dependencies_;
    std::vector<NativeSiteSourceRegionKey> unresolved_dependencies_;
    std::vector<NativeSiteSourceRegionKey> failed_dependencies_;
    std::shared_ptr<const NativeTerrainShapingSnapshot> snapshot_;
};

struct NativeTerrainShapingRegistryState;

class NativeTerrainShapingRegistry final {
public:
    explicit NativeTerrainShapingRegistry(
        WorldSourceDefinition definition,
        NativeSiteSourcePolicy policy,
        NativeTerrainShapingRegistryLimits limits = {});
    NativeTerrainShapingRegistry(const NativeTerrainShapingRegistry &) = delete;
    NativeTerrainShapingRegistry(NativeTerrainShapingRegistry &&) = delete;
    NativeTerrainShapingRegistry &operator=(const NativeTerrainShapingRegistry &) = delete;
    NativeTerrainShapingRegistry &operator=(NativeTerrainShapingRegistry &&) = delete;

    const WorldSourceDefinition &definition() const noexcept;
    const NativeSiteSourcePolicy &policy() const noexcept;
    const WorldPhysicalContentIdentity &policy_content_identity() const noexcept;
    WorldPhysicalContentIdentity source_request_identity(NativeSiteSourceRegionKey region) const;
    std::uint64_t revision() const noexcept;
    std::size_t resident_resolution_count() const noexcept;
    std::size_t retired_fingerprint_count() const noexcept;
    const WorldPhysicalContentIdentity &content_identity() const noexcept;
    bool bind_source_mutation_fence(WorldSourceMutationFence *fence) noexcept;

    // Strong exception guarantee: the complete batch is validated against one
    // revision before a replacement immutable registry state is published.
    NativeTerrainShapingRegistryReceipt apply(const NativeTerrainShapingRegistryBatch &batch);
    // Retirement is terminal-only and explicit. It does not claim empty
    // terrain: a later intersecting page becomes unresolved until the exact
    // deterministic candidate is reconstructed and resolved again.
    NativeTerrainShapingRegistryReceipt retire(const NativeTerrainShapingRegistryRetirement &retirement);

    NativeTerrainShapingPagePin pin_page(
        NativeTerrainPageKey page_key,
        std::vector<NativeTownRegionOverride> town_overrides = {}) const;
    BorrowedShapingPageCursor::Step advance_borrowed_page(
        BorrowedShapingPageCursor &cursor, std::uint32_t offered_ops) const noexcept;
    BorrowedShapingIdentityCursor::Step advance_borrowed_page_identity(
        const BorrowedShapingPageCursor &page,
        BorrowedShapingIdentityCursor &identity,
        const std::array<NativeTownRegionOverride, 9> &towns,
        std::size_t town_count, std::uint32_t offered_ops) const noexcept;

private:
    WorldSourceDefinition definition_;
    NativeSiteSourcePolicy policy_;
    WorldPhysicalContentIdentity policy_content_identity_;
    NativeTerrainShapingRegistryLimits limits_;
    std::shared_ptr<const NativeTerrainShapingRegistryState> state_;
    WorldSourceMutationFence *source_mutation_fence_ = nullptr;
};

} // namespace voxel::world_backend
