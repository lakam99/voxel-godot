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
        && std::isfinite(c.minimum_surface_meters) && std::isfinite(c.maximum_surface_meters)
        && c.minimum_surface_meters <= c.maximum_surface_meters;
}

WorldPhysicalContentIdentity definition_identity(const AdmittedBiomeSeed &seed, const WorldSourceRevisionDescriptor &r, const WorldSourceConstants &c) {
    Writer writer;
    // Version 2 records the full size_t domain as an explicit uint64 rather
    // than silently imposing a 32-bit seed-length ceiling on a new format.
    writer.magic("VWPD"); writer.u32(2); writer.u64(static_cast<std::uint64_t>(seed.code_points.size()));
    for (const std::uint32_t cp : seed.code_points) writer.u32(cp);
    writer.u32(r.source_schema_revision); writer.u32(r.terrain_generator_revision); writer.u32(r.biome_region_field_revision);
    writer.u32(r.lattice_query_revision); writer.u32(r.cell_center_query_revision); writer.u32(r.surface_column_query_revision);
    writer.u64(binary64_bits(c.cell_size_meters)); writer.u64(binary64_bits(c.cell_center_offset_cells)); writer.i32(c.world_bottom_cell_y);
    writer.u64(binary64_bits(c.minimum_surface_meters)); writer.u64(binary64_bits(c.maximum_surface_meters));
    return {sha256(writer.finish())};
}

WorldPhysicalContentIdentity pinned_identity(const WorldPhysicalContentIdentity &definition, const std::uint64_t delta_revision) {
    Writer writer;
    writer.magic("VWPP"); writer.u32(1); writer.digest(definition.digest); writer.u64(delta_revision);
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
    admitted_biome_seed_ = BiomeRegionField::validate_admitted_seed(descriptor.admitted_biome_seed.code_points, descriptor.admitted_biome_seed.utf8);
    revisions_ = descriptor.revisions; constants_ = descriptor.constants;
    physical_content_identity_ = definition_identity(admitted_biome_seed_, revisions_, constants_);
}
const AdmittedBiomeSeed &WorldSourceDefinition::admitted_biome_seed() const noexcept { return admitted_biome_seed_; }
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
    physical_content_identity_ = pinned_identity(definition_.physical_content_identity(), deltas_.revision());
}
const WorldSourceDefinition &WorldSourcePin::definition() const noexcept { return definition_; }
const WorldDeltaPinnedSnapshot &WorldSourcePin::deltas() const noexcept { return deltas_; }
std::uint64_t WorldSourcePin::terrain_delta_revision() const noexcept { return deltas_.revision(); }
const WorldPhysicalContentIdentity &WorldSourcePin::physical_content_identity() const noexcept { return physical_content_identity_; }
} // namespace voxel::world_backend
