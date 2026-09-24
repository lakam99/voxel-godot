#include "native_underground_prop_stream.hpp"

#include "legacy_seed_hash.hpp"
#include "native_surface_prop_source_decision_resolver.hpp"

#include <algorithm>
#include <cmath>
#include <cstring>
#include <limits>
#include <utility>

namespace voxel::world_backend {
namespace {

[[noreturn]] void reject() { throw NativeUndergroundPropRejected(); }

void append_ascii(std::vector<std::uint32_t> &target, const std::string &value) {
    for (const unsigned char value_byte : value) target.push_back(value_byte);
}

std::vector<std::uint32_t> hash_key(
    const AdmittedTerrainSeed &seed, const std::string &suffix) {
    AdmittedTerrainSeed admitted;
    try {
        admitted = validate_admitted_raw_terrain_seed(
            seed.code_points, seed.utf8, seed.admitted);
    } catch (const std::invalid_argument &) {
        reject();
    }
    std::vector<std::uint32_t> key = admitted.code_points;
    append_ascii(key, suffix);
    return key;
}

std::int32_t checked_chunk_cell(const std::int32_t chunk, const std::int32_t offset) {
    const std::int64_t result = static_cast<std::int64_t>(chunk)
        * NativeUndergroundFloorScan::CHUNK_CELLS + offset;
    if (result < std::numeric_limits<std::int32_t>::min()
        || result > std::numeric_limits<std::int32_t>::max()) reject();
    return static_cast<std::int32_t>(result);
}

bool spawnable_floor(
    const NativeEffectiveTerrainSource &terrain, const CellCoord air_cell,
    NativeCellState &floor_state) {
    const NativeCellState air = terrain.sample_cell_state({air_cell, WorldQueryIntent::gameplay});
    if (air.solid || air.biome != TerrainBiomeId::underground_air
        || air.fluid != TerrainFluidId::none) return false;
    const CellCoord head{air_cell.x, air_cell.y + 1, air_cell.z};
    if (terrain.sample_cell_state({head, WorldQueryIntent::gameplay}).solid) return false;
    const CellCoord floor{air_cell.x, air_cell.y - 1, air_cell.z};
    floor_state = terrain.sample_cell_state({floor, WorldQueryIntent::gameplay});
    // NativeCellState admission already makes air/water/lava nonsolid, unlike
    // the script dictionary contract which must repeat those material guards.
    return floor_state.solid;
}

float f32(const double value) { return static_cast<float>(value); }

WorldFloat32Position add_f32(
    const WorldFloat32Position left, const WorldFloat32Position right) noexcept {
    return {f32(static_cast<double>(left.x) + right.x),
        f32(static_cast<double>(left.y) + right.y),
        f32(static_cast<double>(left.z) + right.z)};
}

struct UndergroundFrame final {
    WorldFloat32Position chunk_origin;
    WorldFloat32Position local_position;
    WorldFloat32Position world_anchor;
};

UndergroundFrame placement_frame(
    const NativeUndergroundFloorCandidate &candidate,
    const std::int32_t chunk_x, const std::int32_t chunk_z,
    const double cell_size) {
    const std::int32_t start_x = checked_chunk_cell(chunk_x, 0);
    const std::int32_t start_z = checked_chunk_cell(chunk_z, 0);
    UndergroundFrame frame;
    frame.chunk_origin = {f32(static_cast<double>(start_x) * cell_size), 0.0F,
        f32(static_cast<double>(start_z) * cell_size)};
    frame.local_position = {
        f32((static_cast<double>(candidate.floor_cell.x - start_x) + 0.5) * cell_size),
        f32(static_cast<double>(candidate.air_cell.y) * cell_size + cell_size * 0.04),
        f32((static_cast<double>(candidate.floor_cell.z - start_z) + 0.5) * cell_size),
    };
    frame.world_anchor = add_f32(frame.chunk_origin, frame.local_position);
    return frame;
}

class Writer final {
public:
    void u8(const std::uint8_t value) { bytes.push_back(value); }
    void u32(const std::uint32_t value) {
        for (int shift = 24; shift >= 0; shift -= 8)
            u8(static_cast<std::uint8_t>(value >> shift));
    }
    void i32(const std::int32_t value) { u32(static_cast<std::uint32_t>(value)); }
    void u64(const std::uint64_t value) {
        for (int shift = 56; shift >= 0; shift -= 8)
            u8(static_cast<std::uint8_t>(value >> shift));
    }
    void i64(const std::int64_t value) { u64(static_cast<std::uint64_t>(value)); }
    void digest(const Sha256Digest &value) { bytes.insert(bytes.end(), value.begin(), value.end()); }
    void text(const std::string &value) {
        u32(static_cast<std::uint32_t>(value.size()));
        bytes.insert(bytes.end(), value.begin(), value.end());
    }
    void f32bits(const float value) {
        std::uint32_t bits = 0U;
        std::memcpy(&bits, &value, sizeof(bits));
        u32(bits);
    }
    void f64bits(const double value) {
        std::uint64_t bits = 0U;
        std::memcpy(&bits, &value, sizeof(bits));
        u64(bits);
    }
    void position(const WorldFloat32Position value) {
        f32bits(value.x); f32bits(value.y); f32bits(value.z);
    }
    std::vector<std::uint8_t> bytes;
};

void write_candidate(Writer &writer, const NativeUndergroundFloorCandidate &candidate) {
    writer.u32(candidate.ordinal);
    writer.i32(candidate.floor_cell.x); writer.i32(candidate.floor_cell.y);
    writer.i32(candidate.floor_cell.z);
    writer.i32(candidate.air_cell.x); writer.i32(candidate.air_cell.y);
    writer.i32(candidate.air_cell.z);
    writer.u8(static_cast<std::uint8_t>(candidate.material));
    writer.f64bits(candidate.candidate_roll);
}

void write_ore(Writer &writer, const NativeSurfaceOreChildDefinition &ore) {
    writer.u32(ore.child_index); writer.text(ore.durable_id);
    writer.u8(static_cast<std::uint8_t>(ore.present));
    writer.u64(ore.state_before); writer.u64(ore.state_after); writer.i64(ore.drop_count);
    writer.position(ore.local_position); writer.position(ore.world_anchor);
    writer.f32bits(ore.rotation_y); writer.f64bits(ore.radius);
    writer.f32bits(ore.mesh_radius); writer.f32bits(ore.mesh_height);
    writer.i32(ore.mesh_radial_segments); writer.i32(ore.mesh_rings);
    writer.f32bits(ore.mesh_center_y); writer.position(ore.mesh_scale);
    writer.position(ore.seam_mesh_size);
    for (const auto &seam : ore.seams) {
        writer.position(seam.local_position); writer.position(seam.rotation);
    }
    writer.f32bits(ore.glint_mesh_radius); writer.f32bits(ore.glint_mesh_height);
    writer.i32(ore.glint_radial_segments); writer.i32(ore.glint_rings);
    for (const auto &glint : ore.glints) {
        writer.position(glint.local_position); writer.position(glint.scale);
    }
    writer.f32bits(ore.collider_radius); writer.f32bits(ore.collider_center_y);
}

void write_forage_mesh(Writer &writer, const NativeForageMesh &mesh) {
    writer.u8(static_cast<std::uint8_t>(mesh.kind)); writer.text(mesh.material_id);
    writer.f32bits(mesh.position.x); writer.f32bits(mesh.position.y); writer.f32bits(mesh.position.z);
    writer.f32bits(mesh.rotation.x); writer.f32bits(mesh.rotation.y); writer.f32bits(mesh.rotation.z);
    writer.f32bits(mesh.scale.x); writer.f32bits(mesh.scale.y); writer.f32bits(mesh.scale.z);
    writer.f32bits(mesh.radius); writer.f32bits(mesh.height);
    writer.f32bits(mesh.top_radius); writer.f32bits(mesh.bottom_radius);
    writer.i32(mesh.radial_segments); writer.i32(mesh.rings);
}

void write_forage(Writer &writer, const NativeUndergroundForageArtifact &forage) {
    writer.text(forage.recipe.recipe_id); writer.text(forage.recipe.material_id);
    writer.text(forage.recipe.drop_id); writer.i32(forage.recipe.drop_min);
    writer.i32(forage.recipe.drop_max); writer.f32bits(forage.recipe.collider_radius);
    writer.u8(static_cast<std::uint8_t>(forage.recipe.grammar));
    writer.u8(static_cast<std::uint8_t>(forage.recipe.navigation));
    writer.u64(forage.stream.state_before); writer.u64(forage.stream.state_after);
    writer.i64(forage.stream.drop_count);
    writer.u32(static_cast<std::uint32_t>(forage.stream.float_draws.size()));
    for (const float draw : forage.stream.float_draws) writer.f32bits(draw);
    writer.f32bits(forage.geometry.rotation_y);
    writer.f32bits(forage.geometry.collider_radius);
    writer.f32bits(forage.geometry.collider_center_y);
    writer.u8(static_cast<std::uint8_t>(forage.geometry.navigation_blocker));
    writer.u32(static_cast<std::uint32_t>(forage.geometry.meshes.size()));
    for (const auto &mesh : forage.geometry.meshes) write_forage_mesh(writer, mesh);
}

Sha256Digest feature_delta_digest(const NativeFeatureDeltaSnapshot &snapshot) {
    return sha256(snapshot.canonical_binary());
}

Sha256Digest rock_recipe_digest(
    const NativeUndergroundFloorScan &scan,
    const NativeUndergroundFloorCandidate &candidate,
    const std::string &durable_id, const std::uint64_t state_before,
    const std::vector<float> &draws,
    const NativeSurfaceRockAssetSelection &selection) {
    Writer writer;
    writer.u8('U'); writer.u8('R'); writer.u8('K'); writer.u8('1');
    writer.digest(scan.content_digest()); write_candidate(writer, candidate);
    writer.text(durable_id); writer.u64(state_before);
    for (const float draw : draws) writer.f32bits(draw);
    writer.u32(selection.schema_revision); writer.digest(selection.asset_catalog_digest);
    writer.digest(selection.environment_catalog_digest);
    writer.digest(selection.environment_profile_digest);
    writer.text(selection.requested_biome); writer.text(selection.resolved_profile_biome);
    writer.text(selection.durable_prop_id); writer.text(selection.asset_id);
    writer.text(selection.asset_path); writer.position(selection.asset_size);
    writer.f64bits(selection.rock_scale); writer.u32(selection.candidate_count);
    writer.u8(static_cast<std::uint8_t>(selection.matched_biome_tag));
    return sha256(writer.bytes);
}

NativeUndergroundRockArtifact rock_artifact(
    const NativeUndergroundFloorScan &scan,
    const NativeUndergroundFloorCandidate &candidate,
    const std::string &durable_id, const UndergroundFrame &frame,
    const NativeEffectiveTerrainSource &terrain,
    const NativeSurfaceRockAssetCatalog &catalog, GodotPcg32 &rng) {
    const std::uint64_t state_before = rng.state();
    std::vector<float> draws;
    for (std::size_t index = 0U; index < 6U; ++index) draws.push_back(rng.randf());
    const double cell_size = terrain.pin().definition().constants().cell_size_meters;
    const std::int32_t visual_x = native_surface_rock_visual_cell(
        frame.world_anchor.x, cell_size);
    const std::int32_t visual_z = native_surface_rock_visual_cell(
        frame.world_anchor.z, cell_size);
    const std::string biome = NativeSurfacePropSourceDecisionResolver::biome_name(
        terrain.sample_surface_biome({visual_x, visual_z, WorldQueryIntent::gameplay}));
    NativeSurfaceRockAssetSelection selection = catalog.select(biome, durable_id);
    NativeSurfaceRockDefinitionInput input;
    input.schema_revision = 2U;
    input.producer_key = "native_underground_rock_ordered_recipe";
    input.producer_revision = 1U;
    input.source_recipe_digest = rock_recipe_digest(
        scan, candidate, durable_id, state_before, draws, selection);
    input.durable_feature_id = durable_id;
    input.source_biome = biome;
    input.profile_id = selection.resolved_profile_biome;
    input.position = frame.world_anchor;
    input.rotation_y = static_cast<double>(draws[0]) * 6.28318530717958647692;
    input.visual_radius = 0.55 + static_cast<double>(draws[1]) * 0.7;
    input.visual_height_factor = 0.75 + static_cast<double>(draws[2]) * 0.8;
    input.visual_scale_x = f32(1.15 + static_cast<double>(draws[3]) * 0.6);
    input.visual_scale_y = f32(0.58 + static_cast<double>(draws[4]) * 0.72);
    input.visual_scale_z = f32(1.0 + static_cast<double>(draws[5]) * 0.5);
    input.collision = {f32(input.visual_radius * 1.05), f32(input.visual_radius * 0.42)};
    const auto intent = selection.asset_id.empty()
        ? NativeSurfaceRockVisualIntent::primitive_required
        : NativeSurfaceRockVisualIntent::selected_asset;
    return {NativeSurfaceRockDefinition::create(std::move(input)), std::move(selection), intent};
}

Sha256Digest attempt_digest(const NativeUndergroundPropAttempt &attempt) {
    Writer writer;
    writer.u8('U'); writer.u8('G'); writer.u8('A'); writer.u8('1');
    writer.u32(attempt.ordinal); writer.text(attempt.durable_id);
    write_candidate(writer, attempt.candidate);
    writer.u8(attempt.parent_tombstoned ? 1U : 0U);
    writer.u8(static_cast<std::uint8_t>(attempt.outcome));
    writer.position(attempt.chunk_origin); writer.position(attempt.local_position);
    writer.position(attempt.world_anchor);
    writer.u64(attempt.state_before); writer.u64(attempt.state_after_selection);
    writer.u64(attempt.state_after_recipe);
    writer.u8(attempt.selection_roll ? 1U : 0U);
    if (attempt.selection_roll) writer.f32bits(*attempt.selection_roll);
    writer.u8(attempt.deep_iron_roll ? 1U : 0U);
    if (attempt.deep_iron_roll) writer.f32bits(*attempt.deep_iron_roll);
    writer.u8(attempt.ore_kind ? static_cast<std::uint8_t>(*attempt.ore_kind) : 0U);
    if (attempt.ore) write_ore(writer, *attempt.ore);
    if (attempt.rock) {
        writer.digest(attempt.rock->definition.content_digest());
        writer.u8(static_cast<std::uint8_t>(attempt.rock->visual_intent));
        writer.text(attempt.rock->selection.asset_id);
    }
    if (attempt.forage) write_forage(writer, *attempt.forage);
    return sha256(writer.bytes);
}

void validate_scan_matches(
    const AdmittedTerrainSeed &seed, const NativeUndergroundFloorScan &scan,
    const NativeEffectiveTerrainSource &terrain) {
    bool matches = seed == terrain.pin().definition().raw_terrain_seed();
    matches &= scan.source_identity() == terrain.pin().physical_content_identity();
    matches &= scan.definition_identity()
        == terrain.pin().definition().physical_content_identity();
    matches &= scan.terrain_delta_revision() == terrain.pin().terrain_delta_revision();
    matches &= scan.shaping_registry_revision() == terrain.pin().shaping_registry_revision();
    matches &= scan.shaping_registry_identity()
        == terrain.pin().shaping_registry_content_identity().digest;
    if (!matches) reject();
}

} // namespace

bool NativeUndergroundFloorCandidate::operator==(
    const NativeUndergroundFloorCandidate &other) const noexcept {
    return ordinal == other.ordinal && floor_cell == other.floor_cell
        && air_cell == other.air_cell && material == other.material
        && candidate_roll == other.candidate_roll;
}

NativeUndergroundPropRejected::NativeUndergroundPropRejected()
    : std::invalid_argument("invalid native underground-prop source") {}

NativeUndergroundPropCancelled::NativeUndergroundPropCancelled()
    : std::runtime_error("native underground-prop source cancelled") {}

std::uint32_t native_underground_prop_chunk_rng_seed(
    const AdmittedTerrainSeed &seed, const std::int32_t chunk_x,
    const std::int32_t chunk_z) {
    return legacy_seed_hash(hash_key(seed, ":underground-props:"
        + std::to_string(chunk_x) + "," + std::to_string(chunk_z)));
}

double native_underground_prop_candidate_roll(
    const AdmittedTerrainSeed &seed, const CellCoord floor_cell) {
    const std::uint32_t value = legacy_seed_hash(hash_key(seed,
        ":underground-prop-candidate:" + std::to_string(floor_cell.x) + ","
            + std::to_string(floor_cell.y) + "," + std::to_string(floor_cell.z)));
    return static_cast<double>(value % 100000U) / 100000.0;
}

NativeUndergroundFloorScan::NativeUndergroundFloorScan(
    const std::int32_t chunk_x, const std::int32_t chunk_z,
    const std::uint32_t scanned_cells, const std::uint32_t scanned_columns,
    WorldPhysicalContentIdentity source_identity,
    WorldPhysicalContentIdentity definition_identity,
    const std::uint64_t terrain_delta_revision,
    const std::uint64_t shaping_registry_revision,
    Sha256Digest shaping_registry_identity,
    std::vector<NativeUndergroundFloorCandidate> candidates,
    Sha256Digest content_digest) noexcept
    : chunk_x_(chunk_x), chunk_z_(chunk_z), scanned_cells_(scanned_cells),
      scanned_columns_(scanned_columns), source_identity_(source_identity),
      definition_identity_(definition_identity), terrain_delta_revision_(terrain_delta_revision),
      shaping_registry_revision_(shaping_registry_revision),
      shaping_registry_identity_(shaping_registry_identity),
      candidates_(std::move(candidates)), content_digest_(content_digest) {}

NativeUndergroundFloorScan NativeUndergroundFloorScan::create(
    const AdmittedTerrainSeed &seed, const std::int32_t chunk_x,
    const std::int32_t chunk_z, const NativeEffectiveTerrainSource &terrain,
    const std::function<bool()> &should_cancel) {
    if (should_cancel && should_cancel()) throw NativeUndergroundPropCancelled();
    if (!(seed == terrain.pin().definition().raw_terrain_seed())) reject();
    const std::int32_t start_x = checked_chunk_cell(chunk_x, 0);
    const std::int32_t start_z = checked_chunk_cell(chunk_z, 0);
    const std::int32_t end_x = checked_chunk_cell(chunk_x, CHUNK_CELLS - 1);
    const std::int32_t end_z = checked_chunk_cell(chunk_z, CHUNK_CELLS - 1);
    const NativeHorizontalRect page = terrain.pin().primary_terrain_shaping().page_bounds();
    if (start_x < page.x || start_z < page.z
        || static_cast<std::int64_t>(end_x) >= static_cast<std::int64_t>(page.x) + page.width
        || static_cast<std::int64_t>(end_z) >= static_cast<std::int64_t>(page.z) + page.depth)
        reject();
    const auto &constants = terrain.pin().definition().constants();
    const std::int32_t world_top = static_cast<std::int32_t>(std::ceil(
        (constants.maximum_surface_meters + constants.cell_size_meters * 4.0)
            / constants.cell_size_meters));
    std::vector<NativeUndergroundFloorCandidate> candidates;
    std::uint32_t scanned_cells = 0U;
    std::uint32_t scanned_columns = 0U;
    for (std::int32_t local_z = 0; local_z < CHUNK_CELLS; ++local_z) {
        for (std::int32_t local_x = 0; local_x < CHUNK_CELLS; ++local_x) {
            if (should_cancel && should_cancel()) throw NativeUndergroundPropCancelled();
            const std::int32_t x = start_x + local_x;
            const std::int32_t z = start_z + local_z;
            const double reference = terrain.sample_surface_column(
                {x, z, WorldQueryIntent::gameplay}).reference_surface_y;
            const std::int32_t top = static_cast<std::int32_t>(std::min<double>(
                world_top, std::floor(reference / constants.cell_size_meters) + 1.0));
            for (std::int64_t y = top;
                    y > static_cast<std::int64_t>(constants.world_bottom_cell_y); --y) {
                if (should_cancel && should_cancel()) throw NativeUndergroundPropCancelled();
                ++scanned_cells;
                const CellCoord air{x, static_cast<std::int32_t>(y), z};
                NativeCellState floor;
                if (!spawnable_floor(terrain, air, floor)) continue;
                if (candidates.size() < MAX_CANDIDATES) {
                    const double roll = native_underground_prop_candidate_roll(seed, floor.cell);
                    if (roll <= 0.18) candidates.push_back({
                        static_cast<std::uint32_t>(candidates.size()), floor.cell,
                        air, floor.material, roll});
                }
                break;
            }
            ++scanned_columns;
        }
    }
    if (should_cancel && should_cancel()) throw NativeUndergroundPropCancelled();
    Writer writer;
    writer.u8('U'); writer.u8('F'); writer.u8('S'); writer.u8('1');
    writer.u32(SCHEMA_REVISION); writer.i32(chunk_x); writer.i32(chunk_z);
    writer.digest(terrain.pin().physical_content_identity().digest);
    writer.digest(terrain.pin().definition().physical_content_identity().digest);
    writer.u64(terrain.pin().terrain_delta_revision());
    writer.u64(terrain.pin().shaping_registry_revision());
    writer.digest(terrain.pin().shaping_registry_content_identity().digest);
    writer.u32(scanned_cells); writer.u32(scanned_columns);
    writer.u32(static_cast<std::uint32_t>(candidates.size()));
    for (const auto &candidate : candidates) write_candidate(writer, candidate);
    return NativeUndergroundFloorScan(chunk_x, chunk_z, scanned_cells, scanned_columns,
        terrain.pin().physical_content_identity(),
        terrain.pin().definition().physical_content_identity(),
        terrain.pin().terrain_delta_revision(), terrain.pin().shaping_registry_revision(),
        terrain.pin().shaping_registry_content_identity().digest,
        std::move(candidates), sha256(writer.bytes));
}

std::int32_t NativeUndergroundFloorScan::chunk_x() const noexcept { return chunk_x_; }
std::int32_t NativeUndergroundFloorScan::chunk_z() const noexcept { return chunk_z_; }
std::uint32_t NativeUndergroundFloorScan::scanned_cells() const noexcept { return scanned_cells_; }
std::uint32_t NativeUndergroundFloorScan::scanned_columns() const noexcept { return scanned_columns_; }
const WorldPhysicalContentIdentity &NativeUndergroundFloorScan::source_identity() const noexcept {
    return source_identity_;
}
const WorldPhysicalContentIdentity &NativeUndergroundFloorScan::definition_identity() const noexcept {
    return definition_identity_;
}
std::uint64_t NativeUndergroundFloorScan::terrain_delta_revision() const noexcept {
    return terrain_delta_revision_;
}
std::uint64_t NativeUndergroundFloorScan::shaping_registry_revision() const noexcept {
    return shaping_registry_revision_;
}
const Sha256Digest &NativeUndergroundFloorScan::shaping_registry_identity() const noexcept {
    return shaping_registry_identity_;
}
const std::vector<NativeUndergroundFloorCandidate> &NativeUndergroundFloorScan::candidates() const noexcept {
    return candidates_;
}
const Sha256Digest &NativeUndergroundFloorScan::content_digest() const noexcept { return content_digest_; }

NativeUndergroundPropStream::NativeUndergroundPropStream(
    const std::uint32_t rng_seed, const std::uint64_t final_rng_state,
    Sha256Digest scan_digest, Sha256Digest removed_props_digest,
    Sha256Digest biome_catalog_digest, Sha256Digest rock_catalog_digest,
    Sha256Digest transition_contract_digest,
    std::vector<NativeUndergroundPropAttempt> attempts,
    Sha256Digest content_digest) noexcept
    : rng_seed_(rng_seed), final_rng_state_(final_rng_state),
      scan_digest_(scan_digest), removed_props_digest_(removed_props_digest),
      biome_catalog_digest_(biome_catalog_digest), rock_catalog_digest_(rock_catalog_digest),
      transition_contract_digest_(transition_contract_digest),
      attempts_(std::move(attempts)), content_digest_(content_digest) {}

NativeUndergroundPropStream NativeUndergroundPropStream::create(
    const AdmittedTerrainSeed &seed, const NativeUndergroundFloorScan &scan,
    const NativeEffectiveTerrainSource &terrain,
    const NativeBiomeEnvironmentCatalog &biomes,
    const NativeSurfaceRockAssetCatalog &rock_assets,
    const NativeFeatureDeltaSnapshot &removed_props,
    const std::function<bool()> &should_cancel) {
    if (should_cancel && should_cancel()) throw NativeUndergroundPropCancelled();
    validate_scan_matches(seed, scan, terrain);
    if (rock_assets.environment_digest() != biomes.content_digest()) reject();
    const Sha256Digest removed_digest = feature_delta_digest(removed_props);
    const std::uint32_t seed_value = native_underground_prop_chunk_rng_seed(
        seed, scan.chunk_x(), scan.chunk_z());
    GodotPcg32 rng(seed_value);
    std::vector<NativeUndergroundPropAttempt> attempts;
    attempts.reserve(scan.candidates().size());
    for (const NativeUndergroundFloorCandidate &candidate : scan.candidates()) {
        if (should_cancel && should_cancel()) throw NativeUndergroundPropCancelled();
        NativeUndergroundPropAttempt attempt;
        attempt.ordinal = candidate.ordinal;
        attempt.candidate = candidate;
        attempt.durable_id = seed.utf8 + ":underground:"
            + std::to_string(candidate.floor_cell.x) + ","
            + std::to_string(candidate.floor_cell.y) + ","
            + std::to_string(candidate.floor_cell.z);
        const UndergroundFrame frame = placement_frame(
            candidate, scan.chunk_x(), scan.chunk_z(),
            terrain.pin().definition().constants().cell_size_meters);
        attempt.chunk_origin = frame.chunk_origin;
        attempt.local_position = frame.local_position;
        attempt.world_anchor = frame.world_anchor;
        attempt.state_before = rng.state();
        attempt.parent_tombstoned = removed_props.contains_tombstone(attempt.durable_id);
        if (attempt.parent_tombstoned) {
            attempt.outcome = NativeUndergroundPropOutcome::tombstoned;
            attempt.state_after_selection = rng.state();
            attempt.state_after_recipe = rng.state();
            attempt.content_digest = attempt_digest(attempt);
            attempts.push_back(std::move(attempt));
            continue;
        }
        attempt.selection_roll = rng.randf();
        attempt.state_after_selection = rng.state();
        if (candidate.material == TerrainMaterialId::copper_ore
            || candidate.material == TerrainMaterialId::iron_ore) {
            attempt.ore_kind = candidate.material == TerrainMaterialId::iron_ore
                ? NativeOreKind::iron : NativeOreKind::copper;
        }
        const bool ore_host = (candidate.material == TerrainMaterialId::stone)
            | (candidate.material == TerrainMaterialId::deep_stone)
            | (candidate.material == TerrainMaterialId::bedrock);
        if (!attempt.ore_kind && ((*attempt.selection_roll < 0.12F) & ore_host)) {
            if (candidate.floor_cell.y < -22) {
                attempt.deep_iron_roll = rng.randf();
                attempt.ore_kind = *attempt.deep_iron_roll < 0.38F
                    ? NativeOreKind::iron : NativeOreKind::copper;
            } else {
                attempt.ore_kind = NativeOreKind::copper;
            }
        }
        if (attempt.ore_kind) {
            attempt.outcome = *attempt.ore_kind == NativeOreKind::iron
                ? NativeUndergroundPropOutcome::iron_ore
                : NativeUndergroundPropOutcome::copper_ore;
            const NativeOreClusterChildStream child = native_ore_cluster_child_stream(
                attempt.durable_id, *attempt.ore_kind, 0U, 1U,
                NativeFeatureDeltaSnapshot::create({}, {}), rng);
            NativeSurfacePropPlacementEntry root;
            root.durable_id = attempt.durable_id;
            root.presence = NativeSurfacePropPlacementPresence::anchored;
            root.chunk_origin = frame.chunk_origin;
            root.local_position = frame.local_position;
            root.world_anchor = frame.world_anchor;
            attempt.ore = decode_native_surface_ore_child(child, 0U, root, *attempt.ore_kind);
        } else if (*attempt.selection_roll < 0.36F) {
            attempt.outcome = NativeUndergroundPropOutcome::rock;
            attempt.rock = rock_artifact(
                scan, candidate, attempt.durable_id, frame, terrain, rock_assets, rng);
        } else if (*attempt.selection_roll < 0.48F) {
            attempt.outcome = NativeUndergroundPropOutcome::forage;
            const NativeForageRecipe swamp_forage =
                native_forage_recipe_for_environment_profile(
                    biomes.profile_for_biome("swamp"));
            NativeForageStream stream = NativeForageStreamBuilder::create(swamp_forage, rng);
            NativeForageDecodedGeometry geometry = decode_native_forage_geometry(swamp_forage, stream);
            attempt.forage = NativeUndergroundForageArtifact{
                swamp_forage, std::move(stream), std::move(geometry)};
        } else {
            attempt.outcome = NativeUndergroundPropOutcome::no_feature;
        }
        attempt.state_after_recipe = rng.state();
        attempt.content_digest = attempt_digest(attempt);
        attempts.push_back(std::move(attempt));
    }
    if (should_cancel && should_cancel()) throw NativeUndergroundPropCancelled();
    Writer writer;
    writer.u8('U'); writer.u8('G'); writer.u8('S'); writer.u8('1');
    writer.u32(SCHEMA_REVISION); writer.digest(scan.content_digest());
    writer.digest(removed_digest); writer.digest(biomes.content_digest());
    writer.digest(rock_assets.content_digest()); writer.u32(seed_value);
    writer.u64(rng.state()); writer.u32(static_cast<std::uint32_t>(attempts.size()));
    for (const auto &attempt : attempts) writer.digest(attempt.content_digest);
    Writer contract_writer;
    contract_writer.u8('U'); contract_writer.u8('G'); contract_writer.u8('C');
    contract_writer.u8('1'); contract_writer.digest(scan.content_digest());
    contract_writer.digest(biomes.content_digest());
    contract_writer.digest(rock_assets.content_digest());
    contract_writer.u32(seed_value);
    contract_writer.u32(static_cast<std::uint32_t>(attempts.size()));
    return NativeUndergroundPropStream(seed_value, rng.state(), scan.content_digest(),
        removed_digest, biomes.content_digest(), rock_assets.content_digest(),
        sha256(contract_writer.bytes),
        std::move(attempts), sha256(writer.bytes));
}

std::uint32_t NativeUndergroundPropStream::rng_seed() const noexcept { return rng_seed_; }
std::uint64_t NativeUndergroundPropStream::final_rng_state() const noexcept { return final_rng_state_; }
const Sha256Digest &NativeUndergroundPropStream::scan_digest() const noexcept { return scan_digest_; }
const Sha256Digest &NativeUndergroundPropStream::removed_props_digest() const noexcept {
    return removed_props_digest_;
}
const Sha256Digest &NativeUndergroundPropStream::biome_catalog_digest() const noexcept {
    return biome_catalog_digest_;
}
const Sha256Digest &NativeUndergroundPropStream::rock_catalog_digest() const noexcept {
    return rock_catalog_digest_;
}
const Sha256Digest &NativeUndergroundPropStream::transition_contract_digest() const noexcept {
    return transition_contract_digest_;
}
const std::vector<NativeUndergroundPropAttempt> &NativeUndergroundPropStream::attempts() const noexcept {
    return attempts_;
}
const Sha256Digest &NativeUndergroundPropStream::content_digest() const noexcept { return content_digest_; }
bool NativeUndergroundPropStream::publishable() const noexcept { return false; }
bool NativeUndergroundPropStream::channel_footprints_complete() const noexcept { return false; }

NativeUndergroundPropTransition::NativeUndergroundPropTransition(
    std::vector<NativeUndergroundPropChangedAttempt> changed,
    Sha256Digest content_digest) noexcept
    : changed_(std::move(changed)), content_digest_(content_digest) {}

NativeUndergroundPropTransition NativeUndergroundPropTransition::create(
    const NativeUndergroundPropStream &before,
    const NativeUndergroundPropStream &after) {
    if (before.transition_contract_digest() != after.transition_contract_digest()) reject();
    std::vector<NativeUndergroundPropChangedAttempt> changed;
    for (std::size_t index = 0U; index < before.attempts().size(); ++index) {
        const auto &left = before.attempts()[index];
        const auto &right = after.attempts()[index];
        if (left.content_digest == right.content_digest) continue;
        changed.push_back({static_cast<std::uint32_t>(index), left.durable_id,
            right.durable_id, left.outcome, right.outcome,
            left.content_digest, right.content_digest});
    }
    Writer writer;
    writer.u8('U'); writer.u8('G'); writer.u8('T'); writer.u8('1');
    writer.digest(before.content_digest()); writer.digest(after.content_digest());
    writer.u32(static_cast<std::uint32_t>(changed.size()));
    for (const auto &entry : changed) {
        writer.u32(entry.ordinal); writer.text(entry.before_durable_id);
        writer.text(entry.after_durable_id);
        writer.u8(static_cast<std::uint8_t>(entry.before_outcome));
        writer.u8(static_cast<std::uint8_t>(entry.after_outcome));
        writer.digest(entry.before_identity); writer.digest(entry.after_identity);
    }
    return NativeUndergroundPropTransition(std::move(changed), sha256(writer.bytes));
}

const std::vector<NativeUndergroundPropChangedAttempt> &
NativeUndergroundPropTransition::changed() const noexcept { return changed_; }
const Sha256Digest &NativeUndergroundPropTransition::content_digest() const noexcept {
    return content_digest_;
}
bool NativeUndergroundPropTransition::publishable() const noexcept { return false; }
bool NativeUndergroundPropTransition::channel_footprints_complete() const noexcept { return false; }

} // namespace voxel::world_backend
