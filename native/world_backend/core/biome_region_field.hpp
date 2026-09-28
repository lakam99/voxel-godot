#pragma once

#include <cstdint>
#include <string>
#include <vector>
#include "legacy_seed_hash.hpp"

namespace voxel::world_backend {

// This is the native representation of the fully admitted seed used by the
// regional field.  Admission is deliberately separate from sampling: callers
// with a canonical saved seed cannot accidentally get a second trim/default
// policy by calling the pure field.
struct AdmittedBiomeSeed {
    std::vector<std::uint32_t> code_points;
    std::string utf8;

    bool operator==(const AdmittedBiomeSeed &other) const noexcept;
};

struct BiomeRegion {
    std::int32_t x = 0;
    std::int32_t z = 0;

    bool operator==(const BiomeRegion &other) const noexcept;
};

struct BiomeVec2 {
    // Godot's Vector2 stores real_t (the pinned engine build uses float), even
    // though scalar GDScript Float expressions such as stable_unit are binary64.
    // Retain that storage boundary instead of quietly changing the field.
    float x = 0.0F;
    float z = 0.0F;

    bool operator==(const BiomeVec2 &other) const noexcept;
};

struct BiomeRegionSample {
    static constexpr std::uint32_t FIELD_VERSION = 2;

    // `version` is script-visible in BiomeRegionField.sample(). Keep it in the
    // typed record rather than asking an adapter to synthesize a second value.
    std::uint32_t version = FIELD_VERSION;
    BiomeRegion region;
    std::string region_id;
    BiomeVec2 site_position;
    std::string biome;
    double temperature = 0.0;
    double moisture = 0.0;
    // GDScript uses this transiently to derive edge distance. N3 consumers
    // need the raw second-nearest fact for typed differential verification.
    double second_distance_meters = 0.0;
    double edge_distance_meters = 0.0;
    double ecotone_weight = 0.0;
    double minimum_core_radius_meters = 2680.0;
    double minimum_core_diameter_meters = 5360.0;

    bool operator==(const BiomeRegionSample &other) const noexcept;
};

class BiomeRegionField final {
public:
    static constexpr std::uint32_t FIELD_VERSION = 2;
    static constexpr double REGION_SPACING_METERS = 6000.0;
    static constexpr double REGION_SITE_JITTER_METERS = 320.0;
    static constexpr double MINIMUM_SITE_SEPARATION_METERS = 5360.0;
    static constexpr double MINIMUM_CORE_RADIUS_METERS = 2680.0;
    static constexpr double MINIMUM_CORE_DIAMETER_METERS = 5360.0;
    static constexpr double ECOTONE_WIDTH_METERS = 320.0;
    static constexpr double CLIMATE_LATTICE_METERS = 18000.0;

    // This is the only source-boundary operation. It matches Godot's
    // String.strip_edges() seed normalization and defaults an empty result to
    // "default" before it becomes canonical world identity.
    static AdmittedBiomeSeed admit_utf8_seed(const std::string &presentation_utf8);

    // Saved identities may already possess canonical Unicode scalars. Require
    // their UTF-8 presentation to be valid and exactly corresponding instead
    // of silently accepting a mismatched byte spelling.
    static AdmittedBiomeSeed validate_admitted_seed(
        const std::vector<std::uint32_t> &canonical_code_points,
        const std::string &presentation_utf8);

    static BiomeVec2 site_position(const AdmittedBiomeSeed &seed, BiomeRegion region);
    static std::string region_id(const AdmittedBiomeSeed &seed, BiomeRegion region);
    static double climate_channel(const AdmittedBiomeSeed &seed, BiomeRegion region, const std::string &channel);
    static std::string biome_for_climate(double temperature, double moisture);
    static double value_noise(const AdmittedBiomeSeed &seed, BiomeVec2 point, const std::string &channel);
    static double stable_unit(const std::vector<std::uint32_t> &text);
    static BiomeRegionSample sample(const AdmittedBiomeSeed &seed, BiomeVec2 world_position);
};

class WorldSourceDefinition;
enum class RegionalBiome : std::uint8_t { snow, taiga, tundra, swamp, desert, savanna, forest, plains };
struct NumericBiomeSample {
    BiomeRegion region;
    BiomeVec2 site_position;
    RegionalBiome biome;
    double temperature;
    double moisture;
    double second_distance_meters;
    double edge_distance_meters;
    double ecotone_weight;
};
struct BiomeCursor {
    BiomeCursor() noexcept;
    EvaluatorStamp stamp;
    EvalStatus status;
    EvalReason reason;
    BiomeVec2 position;
    BiomeRegion grid;
    BiomeRegion candidate;
    NumericBiomeSample result;
    SeedKeyCursor key;
    std::array<double, 5> values;
    double nearest_distance;
    double second_distance;
    double tx;
    double tz;
    BiomeRegion lattice;
    std::uint8_t stage;
    std::uint8_t visit;
    std::uint8_t axis;
    std::uint8_t channel;
    std::uint8_t value_index;
};
struct BiomeStep { EvalStep step; NumericBiomeSample value; };
EvalStep begin_biome(BiomeCursor &, EvaluatorStamp, BiomeVec2, WorkQuota &) noexcept;
BiomeStep advance_biome(BiomeCursor &, EvaluatorStamp, const WorldSourceDefinition &, WorkQuota &) noexcept;
ControlResult cancel_biome(BiomeCursor &) noexcept;
ControlResult reset_biome(BiomeCursor &) noexcept;

} // namespace voxel::world_backend
