#pragma once

#include "native_surface_prop_placement_set.hpp"
#include "sha256.hpp"

#include <cstdint>
#include <stdexcept>
#include <string>
#include <vector>

namespace voxel::world_backend {

// The source visual has one collision-owning sphere; asset selection and its
// rendered scale remain presentation facts.  This value deliberately makes
// the physical sphere explicit so a later publisher cannot rebuild collision
// from a mesh node.
struct NativeSurfaceRockSphere final {
    float radius = 0.0F;
    float center_y = 0.0F;

    bool operator==(const NativeSurfaceRockSphere &other) const noexcept;
};

struct NativeSurfaceRockDefinitionInput final {
    std::uint32_t schema_revision = 0U;
    std::string producer_key;
    std::uint32_t producer_revision = 0U;
    Sha256Digest source_recipe_digest{};
    std::string durable_feature_id;
    std::string source_biome;
    std::string profile_id;
    WorldFloat32Position position{};
    double rotation_y = 0.0;
    double visual_radius = 0.0;
    double visual_height_factor = 0.0;
    float visual_scale_x = 0.0F;
    float visual_scale_y = 0.0F;
    float visual_scale_z = 0.0F;
    NativeSurfaceRockSphere collision;

    bool operator==(const NativeSurfaceRockDefinitionInput &other) const noexcept;
};

struct NativeSurfaceRockDefinitionLimits final {
    std::size_t max_text_bytes = 4096U;
    std::size_t max_canonical_bytes = 65536U;
};

class NativeSurfaceRockDefinitionRejected final : public std::invalid_argument {
public:
    NativeSurfaceRockDefinitionRejected();
};

class NativeSurfaceRockDefinition final {
public:
    static NativeSurfaceRockDefinition create(
        NativeSurfaceRockDefinitionInput input, NativeSurfaceRockDefinitionLimits limits = {});

    const NativeSurfaceRockDefinitionInput &input() const noexcept;
    const std::vector<std::uint8_t> &canonical_binary() const noexcept;
    const Sha256Digest &content_digest() const noexcept;

    bool operator==(const NativeSurfaceRockDefinition &other) const noexcept;
    bool operator!=(const NativeSurfaceRockDefinition &other) const noexcept;

private:
    NativeSurfaceRockDefinition(NativeSurfaceRockDefinitionInput input,
        std::vector<std::uint8_t> canonical_binary, Sha256Digest content_digest) noexcept;

    NativeSurfaceRockDefinitionInput input_{};
    std::vector<std::uint8_t> canonical_binary_{};
    Sha256Digest content_digest_{};
};

// Source profile identity is supplied by the adapter from the exact
// environment profile that selected the biome's presentation mapping. It is
// intentionally metadata-only here: the six shared-PCG draws own geometry.
struct NativeSurfaceRockProfile final {
    std::uint32_t schema_revision = 0U;
    std::uint32_t profile_revision = 0U;
    Sha256Digest source_profile_digest{};
    std::string source_biome;
    std::string profile_id;
};

class NativeSurfaceRockDefinitionComposerRejected final : public std::invalid_argument {
public:
    NativeSurfaceRockDefinitionComposerRejected();
};

class NativeSurfaceRockDefinitionComposer final {
public:
    static constexpr std::uint32_t PRODUCER_REVISION = 2U;

    static NativeSurfaceRockDefinition create(
        const NativeSurfacePropPlacementSet &placement_set,
        const NativeSurfacePropBaselineStream &baseline,
        std::uint32_t ordinal,
        const WorldSourceDefinition &world_source,
        const NativeSurfaceRockProfile &profile);
};

} // namespace voxel::world_backend
