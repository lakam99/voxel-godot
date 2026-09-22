#pragma once

#include "sha256.hpp"

#include <cstddef>
#include <cstdint>
#include <stdexcept>
#include <string>
#include <vector>

namespace voxel::world_backend {

// This is an immutable recipe/physical declaration, not a renderer or a
// publisher.  In particular, its one cylinder is the *only* collision fact;
// canopy and root-buttress data remain visual/interaction provenance.
enum class NativeTreeFeatureKind : std::uint8_t {
    natural_surface_tree = 1,
    site_tree = 2,
};

enum class NativeTreeCoordinateFrame : std::uint8_t {
    world = 1,
    owner_local = 2,
};

enum class NativeTreeArchitecture : std::uint8_t {
    broadleaf = 1,
    conifer = 2,
    savanna = 3,
};

struct NativeTreePoint3 final {
    double x = 0.0;
    double y = 0.0;
    double z = 0.0;

    bool operator==(const NativeTreePoint3 &other) const noexcept;
};

struct NativeTreeButtressFootprint final {
    NativeTreePoint3 start;
    NativeTreePoint3 end;
    double radius_start = 0.0;
    double radius_end = 0.0;
    std::string role;

    bool operator==(const NativeTreeButtressFootprint &other) const noexcept;
};

struct NativeTreeEcology final {
    double age_years = 0.0;
    double age_range_min = 0.0;
    double age_range_max = 0.0;
    double local_maturity = 0.0;
    double growth_stage = 0.0;
    std::int64_t genetic_seed = 0;

    bool operator==(const NativeTreeEcology &other) const noexcept;
};

struct NativeTreeBiomeParameters final {
    std::uint32_t revision = 0U;
    double height_min = 0.0;
    double height_max = 0.0;
    double trunk_radius_min = 0.0;
    double trunk_radius_max = 0.0;
    double canopy_radius_min = 0.0;
    double canopy_radius_max = 0.0;
    double canopy_density = 0.0;
    double wind_response = 0.0;
    double visibility_range = 0.0;
    double shadow_range = 0.0;
    double exclusion_margin = 0.0;

    bool operator==(const NativeTreeBiomeParameters &other) const noexcept;
};

struct NativeTreeDefinitionInput final {
    std::uint32_t schema_revision = 0U;
    std::string producer_key;
    std::uint32_t producer_revision = 0U;
    Sha256Digest source_recipe_digest{};
    NativeTreeFeatureKind feature_kind = NativeTreeFeatureKind::natural_surface_tree;

    // durable_feature_id is the opaque removedProps key. recipe_tree_id is
    // independently owned by the tree recipe: a Citadel local recipe key must
    // never be reconstructed from the durable removal ID.
    std::string durable_feature_id;
    std::string recipe_tree_id;
    std::string world_seed;
    std::string biome;
    std::string family;
    std::string growth_class;
    std::string age_band;
    NativeTreeArchitecture architecture = NativeTreeArchitecture::broadleaf;
    std::string species_grammar;

    NativeTreeCoordinateFrame coordinate_frame = NativeTreeCoordinateFrame::world;
    // Required for owner-local coordinates (for example a generated Citadel
    // site); empty for world coordinates. It is a stable owner ID, not a node
    // path, so a later publisher can rebind placement without changing recipe.
    std::string coordinate_owner_id;
    NativeTreePoint3 position;
    double rotation_y = 0.0;

    NativeTreeEcology ecology;
    NativeTreeBiomeParameters biome_parameters;
    double visual_height = 0.0;
    double trunk_radius = 0.0;
    double canopy_radius = 0.0;
    double collision_height = 0.0;
    double exclusion_margin = 0.0;
    bool old_growth = false;
    // Ordered non-collision interaction declarations. They deliberately do
    // not have a collision channel or shape type.
    std::vector<NativeTreeButtressFootprint> root_buttresses;

    bool operator==(const NativeTreeDefinitionInput &other) const noexcept;
};

struct NativeTreeTrunkCylinder final {
    float radius = 0.0F;
    float height = 0.0F;
    float center_y = 0.0F;

    bool operator==(const NativeTreeTrunkCylinder &other) const noexcept;
};

struct NativeTreeDefinitionLimits final {
    std::size_t max_text_bytes = 4096U;
    std::size_t max_buttresses = 256U;
    std::size_t max_canonical_bytes = 65536U;
};

class NativeTreeDefinitionRejected final : public std::invalid_argument {
public:
    NativeTreeDefinitionRejected();
};

class NativeTreeDefinition final {
public:
    static NativeTreeDefinition create(
        NativeTreeDefinitionInput input, NativeTreeDefinitionLimits limits = {});

    const NativeTreeDefinitionInput &input() const noexcept;
    // Matches Godot's one upright CylinderShape3D: radius=trunkRadius,
    // height=collisionHeight and local y=height * 0.5. The conversion is
    // explicit so a future adapter cannot mistake canopies/buttresses for
    // physical blockers.
    NativeTreeTrunkCylinder trunk_cylinder() const noexcept;
    const std::vector<std::uint8_t> &canonical_binary() const noexcept;
    const Sha256Digest &content_digest() const noexcept;

    bool operator==(const NativeTreeDefinition &other) const noexcept;
    bool operator!=(const NativeTreeDefinition &other) const noexcept;

private:
    NativeTreeDefinition(
        NativeTreeDefinitionInput input,
        std::vector<std::uint8_t> canonical_binary,
        Sha256Digest content_digest) noexcept;

    NativeTreeDefinitionInput input_;
    std::vector<std::uint8_t> canonical_binary_;
    Sha256Digest content_digest_{};
};

} // namespace voxel::world_backend
