#pragma once

#include "sha256.hpp"

#include <array>
#include <cstddef>
#include <cstdint>
#include <stdexcept>
#include <string>
#include <vector>

namespace voxel::world_backend {

// A fully resolved BiomeEnvironmentProfile, after Godot Resource defaults have
// been applied. Scalar properties are Godot float64; PackedFloat32Array
// elements are float32. Resource paths and file hashes are provenance, never
// semantic identity. This value does not load .tres files or publish props.
struct NativeBiomeEnvironmentProfile final {
    std::string biome_id;
    std::vector<std::string> tree_families;
    std::vector<std::string> rock_families;
    double tree_scale = 1.0;
    double rock_scale = 1.0;
    double tree_chance = 0.02;
    double rock_base_chance = 0.08;
    double forage_chance = 0.0;
    double wildlife_chance = 0.0;
    std::string forage_material = "berryBush";
    std::string forage_drop = "berries";
    std::int32_t forage_drop_min = 2;
    std::int32_t forage_drop_max = 4;
    double forage_radius = 0.56;
    double weather_precip = 0.36;
    double weather_clouds = 0.36;
    bool cold_weather = false;
    std::vector<std::string> detail_types;
    std::vector<float> detail_thresholds;
    std::vector<float> detail_y_offsets;
    std::vector<float> detail_scale_mins;
    std::vector<float> detail_scale_maxs;
    double detail_max_height_above_water = 1000000.0;
    double tree_height_min = 0.0;
    double tree_height_max = 0.0;
    double crown_radius_min = 0.0;
    double crown_radius_max = 0.0;
    double trunk_radius_min = 0.0;
    double trunk_radius_max = 0.0;
    double old_growth_chance = 0.0;
    double wind_response = 1.0;
    double canopy_density = 0.0;
    double natural_prop_exclusion_margin = 0.0;
    double tree_visibility_range = 260.0;
    double tree_shadow_range = 180.0;
    std::string tree_architecture = "broadleaf";
    double tree_age_min_years = 12.0;
    double tree_age_typical_years = 90.0;
    double tree_age_max_years = 180.0;
    double tree_maturity_cell_scale = 180.0;
    double tree_maturity_influence = 0.72;
    double tree_local_age_span = 0.34;
    double tree_age_distribution_skew = 0.86;
    std::array<float, 4> tree_age_band_thresholds{0.20F, 0.42F, 0.68F, 0.88F};
    double tree_height_growth_exponent = 0.72;
    double tree_girth_growth_exponent = 0.88;
    double tree_crown_growth_exponent = 0.68;
};

class NativeBiomeEnvironmentCatalogRejected final : public std::invalid_argument {
public:
    NativeBiomeEnvironmentCatalogRejected();
};

// Immutable semantic snapshot of the current thirteen-profile production
// catalog. Sorted ID order and the explicit fallback participate in identity.
class NativeBiomeEnvironmentCatalog final {
public:
    static constexpr std::uint32_t SCHEMA_REVISION = 1U;
    static constexpr std::size_t PROFILE_COUNT = 13U;

    static NativeBiomeEnvironmentCatalog create(std::vector<NativeBiomeEnvironmentProfile> profiles,
        std::string fallback_id = "default");

    const NativeBiomeEnvironmentProfile &profile_for_biome(const std::string &biome_id) const noexcept;
    const std::vector<NativeBiomeEnvironmentProfile> &profiles() const noexcept;
    const std::string &fallback_id() const noexcept;
    const Sha256Digest &content_digest() const noexcept;
    const Sha256Digest &profile_digest(const std::string &biome_id) const noexcept;
    const std::vector<std::uint8_t> &canonical_binary() const noexcept;

private:
    NativeBiomeEnvironmentCatalog(std::vector<NativeBiomeEnvironmentProfile> profiles,
        std::string fallback_id, std::vector<Sha256Digest> profile_digests,
        std::vector<std::uint8_t> canonical_binary, Sha256Digest content_digest) noexcept;

    std::vector<NativeBiomeEnvironmentProfile> profiles_;
    std::string fallback_id_;
    std::vector<Sha256Digest> profile_digests_;
    std::vector<std::uint8_t> canonical_binary_;
    Sha256Digest content_digest_{};
};

} // namespace voxel::world_backend
