#pragma once

#include "native_structure_exclusion_snapshot.hpp"
#include "native_surface_tree_ordered_composer.hpp"

namespace voxel::world_backend {

class NativeSurfaceTreePresenceRejected final : public std::invalid_argument {
public:
    NativeSurfaceTreePresenceRejected();
};

// Adapter-owned capture receipt: records are declared complete for coverage,
// including records whose bounds originate outside the prop chunk. The adapter
// must admit that claim from StructureSystem after post-draw margins are known.
// It is separate from SES1's unchanged center-cell query contract.
class NativeTreeExclusionHaloCapture final {
public:
    static NativeTreeExclusionHaloCapture create(
        Sha256Digest world_digest, std::uint64_t world_generation,
        Sha256Digest center_exclusion_digest, StructureExclusionRect coverage,
        std::vector<StructureExclusionRecord> natural,
        std::vector<StructureExclusionRecord> terrain,
        std::vector<CitadelExclusionSource> citadels);

    const Sha256Digest &world_digest() const noexcept;
    std::uint64_t world_generation() const noexcept;
    const Sha256Digest &center_exclusion_digest() const noexcept;
    const Sha256Digest &content_digest() const noexcept;
    const StructureExclusionRect &coverage() const noexcept;
    const std::vector<StructureExclusionRecord> &natural() const noexcept;
    const std::vector<StructureExclusionRecord> &terrain() const noexcept;
    const std::vector<CitadelExclusionSource> &citadels() const noexcept;

private:
    Sha256Digest world_digest_{};
    std::uint64_t world_generation_ = 0;
    Sha256Digest center_exclusion_digest_{};
    Sha256Digest content_digest_{};
    StructureExclusionRect coverage_{};
    std::vector<StructureExclusionRecord> natural_;
    std::vector<StructureExclusionRecord> terrain_;
    std::vector<CitadelExclusionSource> citadels_;
};

enum class NativeSurfaceTreePresence : std::uint8_t { present = 1, absent = 2 };

struct NativeSurfaceTreePresenceDecision final {
    NativeSurfaceTreePresence presence = NativeSurfaceTreePresence::present;
    StructureExclusionKind blocker_kind = StructureExclusionKind::clear;
    std::string blocker_id;
    std::int32_t natural_margin_cells = 0;
    std::int32_t structure_margin_cells = 0;
    Sha256Digest tree_definition_digest{};
    Sha256Digest halo_digest{};
    Sha256Digest content_digest{};
};

struct NativeTreeExclusionMargins final {
    std::int32_t natural_cells = 0;
    std::int32_t structure_cells = 0;
};

// The same post-draw dimensions govern the capture request and final decision.
NativeTreeExclusionMargins native_tree_exclusion_margins(
    double trunk_radius, double canopy_radius, double exclusion_margin,
    double cell_size_meters);

// Pure expanded-footprint decision used by the source-bound composer and
// focused edge tests. Missing halo or Citadel-region admission rejects.
NativeSurfaceTreePresenceDecision evaluate_native_tree_exclusion_halo(
    std::int32_t cell_x, std::int32_t cell_z, double trunk_radius,
    double canopy_radius, double exclusion_margin, double cell_size_meters,
    const NativeTreeExclusionHaloCapture &halo);

NativeSurfaceTreePresenceDecision compose_native_surface_tree_presence(
    const NativeSurfacePropSourceOrderedStream &ordered,
    const NativeSurfacePropOrderedPlacement &placements,
    std::uint32_t ordinal, const NativeEffectiveTerrainSource &terrain,
    const NativeSurfaceTreeEcologyProfile &profile,
    const NativeTreeExclusionHaloCapture &halo);

} // namespace voxel::world_backend
