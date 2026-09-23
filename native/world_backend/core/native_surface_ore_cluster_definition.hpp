#pragma once

#include "native_surface_prop_ordered_placement.hpp"

#include <array>

namespace voxel::world_backend {

struct NativeSurfaceOreSeamDefinition final {
    WorldFloat32Position local_position{};
    WorldFloat32Position rotation{};
};

struct NativeSurfaceOreGlintDefinition final {
    WorldFloat32Position local_position{};
    WorldFloat32Position scale{};
};

struct NativeSurfaceOreChildDefinition final {
    std::uint32_t child_index = 0U;
    std::string durable_id;
    bool present = false;
    std::uint64_t state_before = 0U;
    std::uint64_t state_after = 0U;
    std::int64_t drop_count = 0;
    WorldFloat32Position local_position{};
    WorldFloat32Position world_anchor{};
    float rotation_y = 0.0F;
    double radius = 0.0;
    float mesh_radius = 0.0F;
    float mesh_height = 0.0F;
    std::int32_t mesh_radial_segments = 0;
    std::int32_t mesh_rings = 0;
    float mesh_center_y = 0.0F;
    WorldFloat32Position mesh_scale{};
    WorldFloat32Position seam_mesh_size{};
    std::array<NativeSurfaceOreSeamDefinition, 5> seams{};
    float glint_mesh_radius = 0.0F;
    float glint_mesh_height = 0.0F;
    std::int32_t glint_radial_segments = 0;
    std::int32_t glint_rings = 0;
    std::array<NativeSurfaceOreGlintDefinition, 3> glints{};
    float collider_radius = 0.0F;
    float collider_center_y = 0.0F;
};

class NativeSurfaceOreClusterDefinitionRejected final : public std::invalid_argument {
public:
    NativeSurfaceOreClusterDefinitionRejected();
};

// Pure captured-draw decoder used by composition and focused contract tests.
NativeSurfaceOreChildDefinition decode_native_surface_ore_child(
    const NativeOreClusterChildStream &child, std::uint32_t child_index,
    const NativeSurfacePropPlacementEntry &root, NativeOreKind kind);

// Fail-closed local receipt check; exposed for mutation tests because ordered
// streams are privately constructed and cannot contain missing optionals.
void validate_native_surface_ore_attempt_receipts(const NativeSurfacePropOrderedAttempt &attempt);

// Geometry-only N4 shadow artifact. ItemCatalog tool/tier metadata and actual
// Godot material/scene publication are outside this immutable definition.
class NativeSurfaceOreClusterDefinition final {
public:
    static constexpr std::uint32_t SCHEMA_REVISION = 1U;
    static NativeSurfaceOreClusterDefinition create(
        const NativeSurfacePropSourceOrderedStream &ordered,
        const NativeSurfacePropOrderedPlacement &placements,
        std::uint32_t ordinal, const NativeEffectiveTerrainSource &terrain);

    NativeOreKind kind() const noexcept;
    std::uint32_t ordinal() const noexcept;
    const std::string &root_durable_id() const noexcept;
    const std::array<NativeSurfaceOreChildDefinition, 2> &children() const noexcept;
    const std::vector<std::uint8_t> &canonical_binary() const noexcept;
    const Sha256Digest &content_digest() const noexcept;

private:
    NativeOreKind kind_ = NativeOreKind::iron;
    std::uint32_t ordinal_ = 0U;
    std::string root_durable_id_;
    std::array<NativeSurfaceOreChildDefinition, 2> children_{};
    std::vector<std::uint8_t> canonical_binary_;
    Sha256Digest content_digest_{};
};

} // namespace voxel::world_backend
