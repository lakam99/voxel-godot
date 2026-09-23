#pragma once

#include "native_surface_prop_ordered_placement.hpp"

namespace voxel::world_backend {

class NativeSurfaceForageOrderedDefinitionRejected final : public std::invalid_argument {
public:
    NativeSurfaceForageOrderedDefinitionRejected();
};

enum class NativeForageMeshKind : std::uint8_t { sphere = 1, cylinder = 2 };

struct NativeForageVec3 final { float x = 0, y = 0, z = 0; };

struct NativeForageMesh final {
    NativeForageMeshKind kind = NativeForageMeshKind::sphere;
    NativeForageVec3 position, rotation, scale{1, 1, 1};
    float radius = 0, height = 0, top_radius = 0, bottom_radius = 0;
    std::int32_t radial_segments = 0, rings = 0;
    std::string material_id;
};

struct NativeForageDecodedGeometry final {
    std::vector<NativeForageMesh> meshes;
    float rotation_y = 0;
    float collider_radius = 0;
    float collider_center_y = 0;
    bool navigation_blocker = false;
};

NativeForageRecipe native_forage_recipe_for_environment_profile(
    const NativeBiomeEnvironmentProfile &profile);
std::size_t native_forage_expected_draw_count(NativeForageGrammar grammar);
void validate_native_forage_attempt_placement(
    const NativeSurfacePropOrderedAttempt &attempt,
    const NativeSurfacePropPlacementEntry &placement);

// Production-used draw decoder. It accepts a catalog-admitted recipe and a
// captured stream, without performing RNG, terrain queries, or publication.
NativeForageDecodedGeometry decode_native_forage_geometry(
    const NativeForageRecipe &recipe, const NativeForageStream &stream);

// Pure, source-bound projection of make_forage's recorded PCG draws. Physics
// collision and NPC navigation occupancy are deliberately independent facts.
class NativeSurfaceForageOrderedDefinition final {
public:
    static NativeSurfaceForageOrderedDefinition create(
        const NativeSurfacePropSourceOrderedStream &ordered,
        const NativeSurfacePropOrderedPlacement &placements, std::uint32_t ordinal,
        const NativeEffectiveTerrainSource &terrain,
        const NativeBiomeEnvironmentCatalog &catalog);

    const NativeForageRecipe &recipe() const noexcept;
    const std::vector<NativeForageMesh> &meshes() const noexcept;
    const NativeSurfacePropPlacementEntry &placement() const noexcept;
    float rotation_y() const noexcept;
    float collider_radius() const noexcept;
    float collider_center_y() const noexcept;
    bool physical_collider_present() const noexcept;
    bool navigation_blocker() const noexcept;
    std::int64_t drop_count() const noexcept;
    const Sha256Digest &content_digest() const noexcept;

private:
    NativeForageRecipe recipe_;
    NativeSurfacePropPlacementEntry placement_;
    std::vector<NativeForageMesh> meshes_;
    float rotation_y_ = 0;
    float collider_radius_ = 0;
    float collider_center_y_ = 0;
    bool navigation_blocker_ = false;
    std::int64_t drop_count_ = 0;
    Sha256Digest content_digest_{};
};

} // namespace voxel::world_backend
