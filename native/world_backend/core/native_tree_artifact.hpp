#pragma once

#include "native_tree_definition.hpp"

#include <cstdint>
#include <stdexcept>
#include <string>
#include <vector>

namespace voxel::world_backend {

// A tree artifact is the immutable hand-off between a native recipe compiler
// and an engine adapter.  It deliberately carries render inputs and the one
// source-owned trunk collider together.  The adapter may materialize these
// facts, but it must not derive different dimensions from visual nodes.
enum class NativeTreeRenderTier : std::uint8_t {
    near = 1,
    mid = 2,
    far = 3,
    impostor = 4,
};

enum class NativeTreeArtifactStatus : std::uint8_t {
    complete = 1,
    broadleaf_recipe_pending = 2,
    savanna_recipe_pending = 3,
};

struct NativeTreeArtifactVec3 final {
    float x = 0.0F;
    float y = 0.0F;
    float z = 0.0F;

    bool operator==(const NativeTreeArtifactVec3 &other) const noexcept;
};

struct NativeTreeArtifactBranch final {
    NativeTreeArtifactVec3 start;
    NativeTreeArtifactVec3 end;
    double radius_start = 0.0;
    double radius_end = 0.0;
    std::int32_t order = 0;
    std::int32_t parent_node = -1;
    std::int32_t child_node = -1;
    double wind_weight = 0.0;

    bool operator==(const NativeTreeArtifactBranch &other) const noexcept;
};

struct NativeTreeArtifactFoliage final {
    NativeTreeArtifactVec3 position;
    NativeTreeArtifactVec3 rotation;
    NativeTreeArtifactVec3 scale;
    double wind_weight = 0.0;
    double variation = 0.0;
    std::int32_t cluster_variant = 0;
    std::int32_t source_segment = -1;
    std::int32_t source_order = 0;

    bool operator==(const NativeTreeArtifactFoliage &other) const noexcept;
};

struct NativeTreeArtifactImpostor final {
    float height = 0.0F;
    float trunk_radius = 0.0F;
    float canopy_radius = 0.0F;

    bool operator==(const NativeTreeArtifactImpostor &other) const noexcept;
};

struct NativeTreeArtifactBounds final {
    NativeTreePoint3 minimum;
    NativeTreePoint3 maximum;

    bool operator==(const NativeTreeArtifactBounds &other) const noexcept;
};

struct NativeTreeArtifactFootprint final {
    NativeTreeCoordinateFrame coordinate_frame = NativeTreeCoordinateFrame::world;
    std::string coordinate_owner_id;
    NativeTreeArtifactBounds collision_bounds;
    NativeTreeArtifactBounds render_bounds;
    bool collision_complete = false;
    bool render_complete = false;
    // Pending grammars expose only a dimension envelope.  A complete recipe's
    // AABB may still be conservative in the geometric sense, but it is final;
    // provisional specifically means the render topology is not yet native.
    bool render_bounds_provisional = false;

    bool operator==(const NativeTreeArtifactFootprint &other) const noexcept;
};

class NativeTreeArtifactRejected final : public std::invalid_argument {
public:
    NativeTreeArtifactRejected();
};

class NativeTreeArtifact final {
public:
    static constexpr std::uint32_t SCHEMA_REVISION = 1U;
    static constexpr std::uint32_t BUILDER_REVISION = 1U;

    NativeTreeArtifactStatus status() const noexcept;
    NativeTreeRenderTier render_tier() const noexcept;
    bool complete() const noexcept;
    const Sha256Digest &source_definition_digest() const noexcept;
    const Sha256Digest &native_recipe_digest() const noexcept;
    const std::string &recipe_builder_key() const noexcept;
    std::uint32_t recipe_builder_revision() const noexcept;
    const std::string &recipe_signature() const noexcept;
    const std::string &topology_signature() const noexcept;
    const NativeTreeDefinitionInput &definition() const noexcept;
    NativeTreeTrunkCylinder trunk_cylinder() const noexcept;
    const std::vector<NativeTreeArtifactBranch> &branches() const noexcept;
    const std::vector<NativeTreeArtifactFoliage> &foliage() const noexcept;
    const NativeTreeArtifactImpostor &impostor() const noexcept;
    const NativeTreeArtifactFootprint &footprint() const noexcept;
    const std::vector<std::uint8_t> &canonical_binary() const noexcept;
    const Sha256Digest &content_digest() const noexcept;

    bool operator==(const NativeTreeArtifact &other) const noexcept;
    bool operator!=(const NativeTreeArtifact &other) const noexcept;

private:
    friend class NativeTreeArtifactBuilder;
    friend class NativeTreeArtifactAccess;

    NativeTreeArtifact(
        NativeTreeArtifactStatus status,
        NativeTreeRenderTier render_tier,
        Sha256Digest source_definition_digest,
        Sha256Digest native_recipe_digest,
        std::string recipe_builder_key,
        std::uint32_t recipe_builder_revision,
        std::string recipe_signature,
        std::string topology_signature,
        NativeTreeDefinitionInput definition,
        NativeTreeTrunkCylinder trunk_cylinder,
        std::vector<NativeTreeArtifactBranch> branches,
        std::vector<NativeTreeArtifactFoliage> foliage,
        NativeTreeArtifactImpostor impostor,
        NativeTreeArtifactFootprint footprint,
        std::vector<std::uint8_t> canonical_binary,
        Sha256Digest content_digest) noexcept;

    NativeTreeArtifactStatus status_ = NativeTreeArtifactStatus::complete;
    NativeTreeRenderTier render_tier_ = NativeTreeRenderTier::near;
    Sha256Digest source_definition_digest_{};
    Sha256Digest native_recipe_digest_{};
    std::string recipe_builder_key_;
    std::uint32_t recipe_builder_revision_ = 0U;
    std::string recipe_signature_;
    std::string topology_signature_;
    NativeTreeDefinitionInput definition_;
    NativeTreeTrunkCylinder trunk_cylinder_;
    std::vector<NativeTreeArtifactBranch> branches_;
    std::vector<NativeTreeArtifactFoliage> foliage_;
    NativeTreeArtifactImpostor impostor_;
    NativeTreeArtifactFootprint footprint_;
    std::vector<std::uint8_t> canonical_binary_;
    Sha256Digest content_digest_{};
};

// The compiler consumes native Norway-spruce and umbrella-thorn worker recipes.
// Broadleaf/oak definitions still receive immutable, source-bound artifacts
// with exact trunk collision and conservative extents, but remain explicitly
// pending until that live grammar is ported. A pending artifact must never be
// published as a final render tree.
class NativeTreeArtifactBuilder final {
public:
    static NativeTreeArtifact build(
        const NativeTreeDefinition &definition,
        NativeTreeRenderTier render_tier);
private:
    friend struct NativeTreeArtifactBuilderTestAccess;
    static void validate_complete_for_test(
        const NativeTreeDefinitionInput &definition,
        NativeTreeTrunkCylinder trunk_cylinder,
        NativeTreeRenderTier render_tier,
        const std::vector<NativeTreeArtifactBranch> &branches,
        const std::vector<NativeTreeArtifactFoliage> &foliage,
        NativeTreeArtifactImpostor impostor,
        const NativeTreeArtifactFootprint &footprint);
};

} // namespace voxel::world_backend
