#pragma once

#include "native_surface_prop_ordered_placement.hpp"

namespace voxel::world_backend {

class NativeSurfaceWildlifeOrderedDefinitionRejected final : public std::invalid_argument {
public:
    NativeSurfaceWildlifeOrderedDefinitionRejected();
};

struct NativeWildlifeVec3 final { float x = 0, y = 0, z = 0; };
enum class NativeWildlifeMeshKind : std::uint8_t { sphere = 1, cylinder = 2 };

struct NativeWildlifeMesh final {
    NativeWildlifeMeshKind kind = NativeWildlifeMeshKind::sphere;
    NativeWildlifeVec3 position, rotation, scale{1, 1, 1};
    float radius = 0, height = 0, top_radius = 0, bottom_radius = 0;
    std::int32_t radial_segments = 0, rings = 0;
    std::string material_id;
};

struct NativeWildlifeInitialMovement final {
    NativeWildlifeVec3 home, direction;
    float timer = 0, speed = 0, last_move = 0;
};

struct NativeWildlifeDecodedConstruction final {
    float body_yaw = 0;
    NativeWildlifeVec3 collider_size, collider_center;
    NativeWildlifePresentationPath presentation_path = NativeWildlifePresentationPath::procedural_fallback;
    NativeWildlifeVec3 visual_scale{1, 1, 1}, visual_rotation;
    float animation_speed_scale = 0;
    std::vector<NativeWildlifeMesh> procedural_meshes;
    NativeWildlifeInitialMovement movement;
};

// Exact source-receipt equality guards used by ordered construction. Exposed
// for focused negative mutation tests because ordered witnesses are immutable.
bool native_surface_wildlife_same_receipt(
    const NativeWildlifePresentationReceipt &a, const NativeWildlifePresentationReceipt &b);
bool native_surface_wildlife_same_recipe(
    const NativeWildlifeRecipe &a, const NativeWildlifeRecipe &b);

// Production admission fact check. Keeping this pure permits focused tests to
// corrupt one fact at a time without forging immutable ordered streams/pins.
void validate_native_surface_wildlife_ordered_facts(
    std::uint32_t ordinal, const NativeSurfacePropSourceReceipt &receipt,
    std::uint64_t ordered_final_state, std::uint64_t placement_final_state,
    const Sha256Digest &placement_digest, const Sha256Digest &recomputed_placement_digest,
    const NativeSurfacePropOrderedAttempt &attempt,
    const NativeSurfacePropPlacementEntry &placement,
    const WorldSourcePin &pin, const NativeBiomeEnvironmentCatalog &catalog,
    const NativeWildlifePresentationCatalog &presentations);

// Pure draw decoder. The caller must admit the source/presentation receipt and
// bind the returned definition to the ordered placement before publication.
NativeWildlifeDecodedConstruction decode_native_wildlife_construction(
    const NativeWildlifeStream &stream, const WorldFloat32Position &world_anchor);

class NativeSurfaceWildlifeOrderedDefinition final {
public:
    static NativeSurfaceWildlifeOrderedDefinition create(
        const NativeSurfacePropSourceOrderedStream &ordered,
        const NativeSurfacePropOrderedPlacement &placements, std::uint32_t ordinal,
        const NativeEffectiveTerrainSource &terrain,
        const NativeBiomeEnvironmentCatalog &catalog,
        const NativeWildlifePresentationCatalog &presentations);

    const NativeSurfacePropPlacementEntry &placement() const noexcept;
    const NativeWildlifeStream &stream() const noexcept;
    const NativeWildlifeDecodedConstruction &construction() const noexcept;
    const Sha256Digest &content_digest() const noexcept;

private:
    NativeSurfacePropPlacementEntry placement_;
    NativeWildlifeStream stream_;
    NativeWildlifeDecodedConstruction construction_;
    Sha256Digest content_digest_{};
};

} // namespace voxel::world_backend
