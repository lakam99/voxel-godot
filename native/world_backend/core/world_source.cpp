#include "world_source.hpp"

#include <cmath>
#include <cstring>
#include <limits>
#include <stdexcept>
#include <utility>
#include <vector>

namespace voxel::world_backend {
namespace {
class Writer final {
public:
    void magic(const char (&value)[5]) { bytes_.insert(bytes_.end(), value, value + 4); }
    void u32(const std::uint32_t value) { for (unsigned shift = 0; shift < 32U; shift += 8U) bytes_.push_back(static_cast<std::uint8_t>(value >> shift)); }
    void i32(const std::int32_t value) { u32(static_cast<std::uint32_t>(value)); }
    void u64(const std::uint64_t value) { for (unsigned shift = 0; shift < 64U; shift += 8U) bytes_.push_back(static_cast<std::uint8_t>(value >> shift)); }
    void digest(const Sha256Digest &value) { bytes_.insert(bytes_.end(), value.begin(), value.end()); }
    std::vector<std::uint8_t> finish() { return std::move(bytes_); }
private:
    std::vector<std::uint8_t> bytes_;
};

std::uint64_t binary64_bits(const double value) {
    static_assert(std::numeric_limits<double>::is_iec559, "world source constants require IEEE-754 binary64");
    std::uint64_t bits = 0;
    std::memcpy(&bits, &value, sizeof(bits));
    return bits;
}

bool valid_revisions(const WorldSourceRevisionDescriptor &r) noexcept {
    return r.source_schema_revision && r.terrain_generator_revision && r.biome_region_field_revision
        && r.lattice_query_revision && r.cell_center_query_revision && r.surface_column_query_revision;
}

bool valid_constants(const WorldSourceConstants &c) noexcept {
    return std::isfinite(c.cell_size_meters) && c.cell_size_meters > 0.0
        && std::isfinite(c.cell_center_offset_cells) && c.cell_center_offset_cells > 0.0 && c.cell_center_offset_cells < 1.0
        && std::isfinite(c.water_level_meters)
        && std::isfinite(c.minimum_surface_meters) && std::isfinite(c.maximum_surface_meters)
        && c.minimum_surface_meters <= c.maximum_surface_meters;
}

WorldPhysicalContentIdentity definition_identity(const AdmittedTerrainSeed &terrain_seed, const AdmittedBiomeSeed &seed, const WorldSourceRevisionDescriptor &r, const WorldSourceConstants &c) {
    Writer writer;
    // Version 3 records both raw terrain and canonical-biome scalar counts as
    // explicit uint64 values; neither may silently inherit a 32-bit limit.
    writer.magic("VWPD"); writer.u32(3); writer.u64(static_cast<std::uint64_t>(terrain_seed.code_points.size()));
    for (const std::uint32_t cp : terrain_seed.code_points) writer.u32(cp);
    writer.u64(static_cast<std::uint64_t>(seed.code_points.size()));
    for (const std::uint32_t cp : seed.code_points) writer.u32(cp);
    writer.u32(r.source_schema_revision); writer.u32(r.terrain_generator_revision); writer.u32(r.biome_region_field_revision);
    writer.u32(r.lattice_query_revision); writer.u32(r.cell_center_query_revision); writer.u32(r.surface_column_query_revision);
    writer.u64(binary64_bits(c.cell_size_meters)); writer.u64(binary64_bits(c.cell_center_offset_cells)); writer.i32(c.world_bottom_cell_y); writer.u64(binary64_bits(c.water_level_meters));
    writer.u64(binary64_bits(c.minimum_surface_meters)); writer.u64(binary64_bits(c.maximum_surface_meters));
    return {sha256(writer.finish())};
}

std::vector<std::uint32_t> decode_utf8_scalars(const std::string &value) {
    std::vector<std::uint32_t> output;
    for (std::size_t index = 0; index < value.size();) {
        const std::uint8_t first = static_cast<std::uint8_t>(value[index]);
        std::uint32_t code_point = 0; std::size_t length = 0;
        if (first <= 0x7fU) { code_point = first; length = 1; }
        else if (first >= 0xc2U && first <= 0xdfU && index + 1 < value.size()
            && (static_cast<std::uint8_t>(value[index + 1]) & 0xc0U) == 0x80U) {
            code_point = (static_cast<std::uint32_t>(first & 0x1fU) << 6U) | (static_cast<std::uint8_t>(value[index + 1]) & 0x3fU); length = 2;
        } else if (first >= 0xe0U && first <= 0xefU && index + 2 < value.size()
            && (static_cast<std::uint8_t>(value[index + 1]) & 0xc0U) == 0x80U && (static_cast<std::uint8_t>(value[index + 2]) & 0xc0U) == 0x80U
            && !(first == 0xe0U && static_cast<std::uint8_t>(value[index + 1]) < 0xa0U)
            && !(first == 0xedU && static_cast<std::uint8_t>(value[index + 1]) >= 0xa0U)) {
            code_point = (static_cast<std::uint32_t>(first & 0x0fU) << 12U) | (static_cast<std::uint32_t>(static_cast<std::uint8_t>(value[index + 1]) & 0x3fU) << 6U) | (static_cast<std::uint8_t>(value[index + 2]) & 0x3fU); length = 3;
        } else if (first >= 0xf0U && first <= 0xf4U && index + 3 < value.size()
            && (static_cast<std::uint8_t>(value[index + 1]) & 0xc0U) == 0x80U && (static_cast<std::uint8_t>(value[index + 2]) & 0xc0U) == 0x80U && (static_cast<std::uint8_t>(value[index + 3]) & 0xc0U) == 0x80U
            && !(first == 0xf0U && static_cast<std::uint8_t>(value[index + 1]) < 0x90U)
            && !(first == 0xf4U && static_cast<std::uint8_t>(value[index + 1]) >= 0x90U)) {
            code_point = (static_cast<std::uint32_t>(first & 0x07U) << 18U) | (static_cast<std::uint32_t>(static_cast<std::uint8_t>(value[index + 1]) & 0x3fU) << 12U) | (static_cast<std::uint32_t>(static_cast<std::uint8_t>(value[index + 2]) & 0x3fU) << 6U) | (static_cast<std::uint8_t>(value[index + 3]) & 0x3fU); length = 4;
        } else throw std::invalid_argument("raw terrain seed must be valid UTF-8");
        output.push_back(code_point); index += length;
    }
    return output;
}

WorldPhysicalContentIdentity pinned_identity(
    const WorldPhysicalContentIdentity &definition,
    const std::uint64_t delta_revision,
    const Sha256Digest &delta_content_digest) {
    Writer writer;
    // A numeric revision is only unique within one live store. Restored
    // checkpoints from different saves can have the same revision yet
    // different terrain/features, so physical identity binds canonical pinned
    // content as well as the sequencing value.
    writer.magic("VWPP"); writer.u32(2); writer.digest(definition.digest); writer.u64(delta_revision);
    writer.digest(delta_content_digest);
    return {sha256(writer.finish())};
}

void validate_intent(const WorldQueryIntent intent) {
    if (!is_valid_world_query_intent(intent)) throw std::invalid_argument("world query has an invalid intent");
}

float godot_lattice_component(const std::int32_t cell_coordinate, const double cell_size_meters) noexcept {
    // `Vector3(cell) * CELL`: Vector3 first narrows the integer component and
    // the multiplication overload narrows CELL to real_t before multiplying.
    // Do not replace this with a binary64 product followed by one cast; the
    // two differ at ordinary large generated-world cell coordinates.
    return static_cast<float>(cell_coordinate) * static_cast<float>(cell_size_meters);
}

float godot_center_component(const std::int32_t cell_coordinate, const double offset_cells, const double cell_size_meters) noexcept {
    // `Vector3((float(cell.x) + 0.5) * s, ...)`: GDScript evaluates the
    // scalar expression before Vector3 stores its real_t component.  The
    // center therefore has exactly one float32 boundary, unlike the lattice
    // Vector3 scalar multiplication above.
    return static_cast<float>((static_cast<double>(cell_coordinate) + offset_cells) * cell_size_meters);
}
} // namespace

bool AdmittedTerrainSeed::operator==(const AdmittedTerrainSeed &other) const noexcept {
    return code_points == other.code_points && utf8 == other.utf8 && admitted == other.admitted;
}
AdmittedTerrainSeed admit_raw_terrain_seed(const std::string &presentation_utf8) {
    return {decode_utf8_scalars(presentation_utf8), presentation_utf8, true};
}
AdmittedTerrainSeed validate_admitted_raw_terrain_seed(const std::vector<std::uint32_t> &code_points,
    const std::string &presentation_utf8, const bool admitted) {
    if (!admitted || decode_utf8_scalars(presentation_utf8) != code_points) throw std::invalid_argument("raw terrain seed admission is invalid");
    return {code_points, presentation_utf8, true};
}

WorldQueryKind query_kind(const WorldLatticeQuery &) noexcept { return WorldQueryKind::lattice_cell; }
WorldQueryKind query_kind(const WorldCellCenterQuery &) noexcept { return WorldQueryKind::cell_center; }
WorldQueryKind query_kind(const WorldSurfaceColumnQuery &) noexcept { return WorldQueryKind::surface_column; }
bool is_valid_world_query_intent(const WorldQueryIntent intent) noexcept { return intent == WorldQueryIntent::terrain_mesh || intent == WorldQueryIntent::terrain_collision || intent == WorldQueryIntent::gameplay; }
void validate_world_query(const WorldLatticeQuery &query) { validate_intent(query.intent); }
void validate_world_query(const WorldCellCenterQuery &query) { validate_intent(query.intent); }
void validate_world_query(const WorldSurfaceColumnQuery &query) { validate_intent(query.intent); }
std::string WorldPhysicalContentIdentity::digest_hex() const { return sha256_hex(digest); }
bool WorldPhysicalContentIdentity::operator==(const WorldPhysicalContentIdentity &other) const noexcept { return digest == other.digest; }

WorldSourceDefinition::WorldSourceDefinition(WorldSourceDescriptor descriptor) {
    if (!valid_revisions(descriptor.revisions)) throw std::invalid_argument("world source revisions must be nonzero");
    if (descriptor.revisions.biome_region_field_revision != BiomeRegionField::FIELD_VERSION) throw std::invalid_argument("world source biome field revision is unsupported");
    if (!valid_constants(descriptor.constants)) throw std::invalid_argument("world source constants are invalid");
    raw_terrain_seed_ = validate_admitted_raw_terrain_seed(descriptor.raw_terrain_seed.code_points, descriptor.raw_terrain_seed.utf8, descriptor.raw_terrain_seed.admitted);
    admitted_biome_seed_ = BiomeRegionField::validate_admitted_seed(descriptor.admitted_biome_seed.code_points, descriptor.admitted_biome_seed.utf8);
    revisions_ = descriptor.revisions; constants_ = descriptor.constants;
    physical_content_identity_ = definition_identity(raw_terrain_seed_, admitted_biome_seed_, revisions_, constants_);
}
const AdmittedBiomeSeed &WorldSourceDefinition::admitted_biome_seed() const noexcept { return admitted_biome_seed_; }
const AdmittedTerrainSeed &WorldSourceDefinition::raw_terrain_seed() const noexcept { return raw_terrain_seed_; }
const WorldSourceRevisionDescriptor &WorldSourceDefinition::revisions() const noexcept { return revisions_; }
const WorldSourceConstants &WorldSourceDefinition::constants() const noexcept { return constants_; }
const WorldPhysicalContentIdentity &WorldSourceDefinition::physical_content_identity() const noexcept { return physical_content_identity_; }
WorldResolvedLatticeQuery resolve_world_query(const WorldSourceDefinition &definition, const WorldLatticeQuery &query) {
    validate_world_query(query);
    const double cell_size = definition.constants().cell_size_meters;
    return {query.coordinate, {
        godot_lattice_component(query.coordinate.x, cell_size),
        godot_lattice_component(query.coordinate.y, cell_size),
        godot_lattice_component(query.coordinate.z, cell_size),
    }, query.intent};
}
WorldResolvedCellCenterQuery resolve_world_query(const WorldSourceDefinition &definition, const WorldCellCenterQuery &query) {
    validate_world_query(query);
    const WorldSourceConstants &constants = definition.constants();
    return {query.coordinate, {
        godot_center_component(query.coordinate.x, constants.cell_center_offset_cells, constants.cell_size_meters),
        godot_center_component(query.coordinate.y, constants.cell_center_offset_cells, constants.cell_size_meters),
        godot_center_component(query.coordinate.z, constants.cell_center_offset_cells, constants.cell_size_meters),
    }, query.intent};
}
WorldResolvedSurfaceColumnQuery resolve_world_query(const WorldSourceDefinition &definition, const WorldSurfaceColumnQuery &query) {
    validate_world_query(query);
    const double cell_size = definition.constants().cell_size_meters;
    return {query.x, query.z, {
        godot_lattice_component(query.x, cell_size),
        godot_lattice_component(query.z, cell_size),
    }, query.intent};
}
std::uint32_t query_revision(const WorldSourceDefinition &definition, const WorldLatticeQuery &) noexcept { return definition.revisions().lattice_query_revision; }
std::uint32_t query_revision(const WorldSourceDefinition &definition, const WorldCellCenterQuery &) noexcept { return definition.revisions().cell_center_query_revision; }
std::uint32_t query_revision(const WorldSourceDefinition &definition, const WorldSurfaceColumnQuery &) noexcept { return definition.revisions().surface_column_query_revision; }

WorldSourcePin::WorldSourcePin(WorldSourceDefinition definition, WorldDeltaPinnedSnapshot deltas) : definition_(std::move(definition)), deltas_(std::move(deltas)) {
    physical_content_identity_ = pinned_identity(
        definition_.physical_content_identity(), deltas_.revision(), deltas_.content_digest());
}
const WorldSourceDefinition &WorldSourcePin::definition() const noexcept { return definition_; }
const WorldDeltaPinnedSnapshot &WorldSourcePin::deltas() const noexcept { return deltas_; }
std::uint64_t WorldSourcePin::terrain_delta_revision() const noexcept { return deltas_.revision(); }
const WorldPhysicalContentIdentity &WorldSourcePin::physical_content_identity() const noexcept { return physical_content_identity_; }
} // namespace voxel::world_backend
