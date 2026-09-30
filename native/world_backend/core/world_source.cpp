#include "world_source.hpp"
#include "native_terrain_shaping_registry.hpp"

#include <algorithm>
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
    const NativeHorizontalRect page_bounds,
    const std::vector<std::shared_ptr<const NativeTerrainShapingSnapshot>> &shaping_pages,
    const std::vector<Sha256Digest> &typed_projection_digests) {
    Writer writer;
    // v4 binds every effective dependency's shaping and typed projection.
    // Registry/delta sequence values and global digests remain provenance.
    writer.magic("VWPP"); writer.u32(4); writer.digest(definition.digest);
    writer.i32(page_bounds.x); writer.i32(page_bounds.z);
    writer.i32(page_bounds.width); writer.i32(page_bounds.depth);
    writer.u64(static_cast<std::uint64_t>(shaping_pages.size()));
    for (std::size_t index = 0; index < shaping_pages.size(); ++index) {
        const auto &shaping = shaping_pages[index];
        const NativeTerrainPageKey key = shaping->page_key();
        const NativeHorizontalRect bounds = shaping->page_bounds();
        writer.i32(key.x); writer.i32(key.z);
        writer.i32(bounds.x); writer.i32(bounds.z); writer.i32(bounds.width); writer.i32(bounds.depth);
        writer.digest(shaping->physical_content_identity().digest);
        writer.digest(typed_projection_digests[index]);
    }
    return {sha256(writer.finish())};
}

std::int32_t floor_page(const std::int32_t cell) noexcept {
    std::int32_t result = cell / NativeTerrainShapingSnapshot::PAGE_CELLS;
    if (cell % NativeTerrainShapingSnapshot::PAGE_CELLS < 0) --result;
    return result;
}

std::int32_t checked_remapped_cell(const float position, const double cell_size_meters) {
    if (!std::isfinite(position)) {
        throw std::invalid_argument("world effective shaping position is not finite");
    }
    const double floored = std::floor(static_cast<double>(position) / cell_size_meters);
    if (floored < static_cast<double>(std::numeric_limits<std::int32_t>::min())
        || floored > static_cast<double>(std::numeric_limits<std::int32_t>::max())) {
        throw std::invalid_argument("world effective shaping source cell is outside int32");
    }
    return static_cast<std::int32_t>(floored);
}

std::int32_t remapped_lattice_cell(
    const std::int32_t cell, const double cell_size_meters) {
    const float position = static_cast<float>(cell) * static_cast<float>(cell_size_meters);
    // native_terrain_page_bounds admits a deliberately narrower page-key
    // domain than int32 cell space, including enough edge margin for this
    // float32 round-trip. No clamp or saturating conversion is permitted.
    return checked_remapped_cell(position, cell_size_meters);
}

std::int32_t remapped_center_cell(
    const std::int32_t cell,
    const double offset_cells,
    const double cell_size_meters) {
    const float position = static_cast<float>(
        (static_cast<double>(cell) + offset_cells) * cell_size_meters);
    return checked_remapped_cell(position, cell_size_meters);
}

std::int32_t remapped_grid_cell(
    const std::int32_t cell, const double cell_size_meters) {
    // WGS grid numeric helpers evaluate float(cell) * s as a binary64 scalar
    // expression and narrow only once when the Vector3 stores the result.
    const float position = static_cast<float>(
        static_cast<double>(cell) * cell_size_meters);
    return checked_remapped_cell(position, cell_size_meters);
}

bool page_key_less(const NativeTerrainPageKey left, const NativeTerrainPageKey right) noexcept {
    return left.z != right.z ? left.z < right.z : left.x < right.x;
}

struct CaveShapingPageRange {
    std::int32_t min_x = 0;
    std::int32_t max_x = -1;
    std::int32_t min_z = 0;
    std::int32_t max_z = -1;
};

std::int32_t checked_floor_i32(const long double value, const char *message) {
    const long double rounded = std::floor(value);
    if (!std::isfinite(value)
        || rounded < static_cast<long double>(std::numeric_limits<std::int32_t>::min())
        || rounded > static_cast<long double>(std::numeric_limits<std::int32_t>::max()))
        throw std::invalid_argument(message);
    return static_cast<std::int32_t>(rounded);
}

CaveShapingPageRange cave_shaping_page_range(
    const WorldSourceDefinition &definition,
    const std::int32_t source_min_x, const std::int32_t source_max_x,
    const std::int32_t source_min_z, const std::int32_t source_max_z) {
    constexpr long double region_size = 192.0L;
    constexpr long double region_half = region_size * 0.5L;
    const long double cell_size = definition.constants().cell_size_meters;
    const auto region_range = [cell_size, region_half, region_size](const std::int32_t source_min,
        const std::int32_t source_max) {
        // A remapped source coordinate identifies floor(world / cell_size),
        // while the cave recipe receives the original float32 world position.
        // Include one full cell on either side to cover that conversion and
        // exact region-boundary roundoff without omitting an adjacent recipe.
        const long double low_world = (static_cast<long double>(source_min) - 1.0L) * cell_size;
        const long double high_world = (static_cast<long double>(source_max) + 1.0L) * cell_size;
        const std::int32_t first = checked_floor_i32(
            (low_world + region_half) / region_size,
            "native cave source region is outside int32");
        const std::int32_t last = checked_floor_i32(
            (high_world + region_half) / region_size,
            "native cave source region is outside int32");
        return std::pair<std::int32_t, std::int32_t>{first, last};
    };
    const auto [first_region_x, last_region_x] = region_range(source_min_x, source_max_x);
    const auto [first_region_z, last_region_z] = region_range(source_min_z, source_max_z);
    const auto region_cell_range = [cell_size, region_half, region_size](const std::int32_t first_region,
        const std::int32_t last_region) {
        const long double low_world = static_cast<long double>(first_region) * region_size - region_half;
        const long double high_world = static_cast<long double>(last_region) * region_size + region_half;
        // Recipes and their bounds are wholly contained by their source
        // region. One cell of guard keeps the float32 Vector3 -> floor cell
        // conversion conservative at both inclusive/exclusive edges.
        const std::int32_t first_cell = checked_floor_i32(
            low_world / cell_size - 1.0L,
            "native cave shaping cell is outside int32");
        const std::int32_t last_cell = checked_floor_i32(
            high_world / cell_size + 1.0L,
            "native cave shaping cell is outside int32");
        return std::pair<std::int32_t, std::int32_t>{first_cell, last_cell};
    };
    const auto [first_cell_x, last_cell_x] = region_cell_range(first_region_x, last_region_x);
    const auto [first_cell_z, last_cell_z] = region_cell_range(first_region_z, last_region_z);
    return {floor_page(first_cell_x), floor_page(last_cell_x),
        floor_page(first_cell_z), floor_page(last_cell_z)};
}

std::uint64_t cave_shaping_page_count(const CaveShapingPageRange range) noexcept {
    if (range.max_x < range.min_x || range.max_z < range.min_z) return 0U;
    return static_cast<std::uint64_t>(static_cast<std::int64_t>(range.max_x) - range.min_x + 1)
        * static_cast<std::uint64_t>(static_cast<std::int64_t>(range.max_z) - range.min_z + 1);
}

constexpr std::uint64_t MAX_CAVE_SHAPING_DEPENDENCY_PAGES = 4096U;

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
        static_cast<float>(static_cast<double>(query.x) * cell_size),
        static_cast<float>(static_cast<double>(query.z) * cell_size),
    }, query.intent};
}
std::uint32_t query_revision(const WorldSourceDefinition &definition, const WorldLatticeQuery &) noexcept { return definition.revisions().lattice_query_revision; }
std::uint32_t query_revision(const WorldSourceDefinition &definition, const WorldCellCenterQuery &) noexcept { return definition.revisions().cell_center_query_revision; }
std::uint32_t query_revision(const WorldSourceDefinition &definition, const WorldSurfaceColumnQuery &) noexcept { return definition.revisions().surface_column_query_revision; }

std::vector<NativeTerrainPageKey> world_effective_shaping_dependencies(
    const WorldSourceDefinition &definition, const NativeTerrainPageKey primary_page) {
    const auto bounds = native_terrain_page_bounds(primary_page);
    if (!bounds) throw std::invalid_argument("world effective primary page is invalid");
    std::vector<std::int32_t> lattice_pages_x;
    std::vector<std::int32_t> lattice_pages_z;
    std::vector<std::int32_t> center_pages_x;
    std::vector<std::int32_t> center_pages_z;
    std::vector<std::int32_t> grid_pages_x;
    std::vector<std::int32_t> grid_pages_z;
    std::int32_t source_min_x = std::numeric_limits<std::int32_t>::max();
    std::int32_t source_max_x = std::numeric_limits<std::int32_t>::min();
    std::int32_t source_min_z = std::numeric_limits<std::int32_t>::max();
    std::int32_t source_max_z = std::numeric_limits<std::int32_t>::min();
    const auto append_axis = [&](const std::int32_t start,
        std::vector<std::int32_t> &lattice_pages,
        std::vector<std::int32_t> &center_pages,
        std::vector<std::int32_t> &grid_pages,
        std::int32_t &source_min, std::int32_t &source_max) {
        for (std::int32_t offset = 0; offset < NativeTerrainShapingSnapshot::PAGE_CELLS; ++offset) {
            const std::int32_t source = remapped_lattice_cell(
                start + offset, definition.constants().cell_size_meters);
            const std::int32_t center_source = remapped_center_cell(
                start + offset, definition.constants().cell_center_offset_cells,
                definition.constants().cell_size_meters);
            const std::int32_t grid_source = remapped_grid_cell(
                start + offset, definition.constants().cell_size_meters);
            const std::int32_t lattice_page = floor_page(source);
            const std::int32_t center_page = floor_page(center_source);
            const std::int32_t grid_page = floor_page(grid_source);
            source_min = std::min({source_min, source, center_source, grid_source});
            source_max = std::max({source_max, source, center_source, grid_source});
            if (std::find(lattice_pages.begin(), lattice_pages.end(), lattice_page) == lattice_pages.end())
                lattice_pages.push_back(lattice_page);
            if (std::find(center_pages.begin(), center_pages.end(), center_page) == center_pages.end())
                center_pages.push_back(center_page);
            if (std::find(grid_pages.begin(), grid_pages.end(), grid_page) == grid_pages.end())
                grid_pages.push_back(grid_page);
        }
        std::sort(lattice_pages.begin(), lattice_pages.end());
        std::sort(center_pages.begin(), center_pages.end());
        std::sort(grid_pages.begin(), grid_pages.end());
    };
    append_axis(bounds->x, lattice_pages_x, center_pages_x, grid_pages_x,
        source_min_x, source_max_x);
    append_axis(bounds->z, lattice_pages_z, center_pages_z, grid_pages_z,
        source_min_z, source_max_z);
    std::vector<NativeTerrainPageKey> result;
    result.push_back(primary_page);
    const auto append_product = [&](const std::vector<std::int32_t> &pages_x,
        const std::vector<std::int32_t> &pages_z) {
        for (const std::int32_t z : pages_z) {
            for (const std::int32_t x : pages_x) result.push_back({x, z});
        }
    };
    append_product(lattice_pages_x, lattice_pages_z);
    append_product(center_pages_x, center_pages_z);
    append_product(grid_pages_x, grid_pages_z);
    const CaveShapingPageRange cave_range = cave_shaping_page_range(
        definition, source_min_x, source_max_x, source_min_z, source_max_z);
    if (cave_shaping_page_count(cave_range) > MAX_CAVE_SHAPING_DEPENDENCY_PAGES)
        throw std::length_error("native cave shaping dependency set exceeds source limit");
    for (std::int64_t z = cave_range.min_z; z <= cave_range.max_z; ++z) {
        for (std::int64_t x = cave_range.min_x; x <= cave_range.max_x; ++x) {
            const NativeTerrainPageKey page{static_cast<std::int32_t>(x), static_cast<std::int32_t>(z)};
            if (!native_terrain_page_bounds(page))
                throw std::invalid_argument("native cave shaping dependency page is invalid");
            result.push_back(page);
        }
    }
    std::sort(result.begin(), result.end(), page_key_less);
    result.erase(std::unique(result.begin(), result.end()), result.end());
    return result;
}

void WorldShapingDependencyCursor::reset(const NativeTerrainPageKey primary) noexcept {
    primary_x_ = primary.x; primary_z_ = primary.z;
    counts_ = {}; product_x_ = {}; product_z_ = {};
    source_min_x_ = std::numeric_limits<std::int32_t>::max();
    source_max_x_ = std::numeric_limits<std::int32_t>::min();
    source_min_z_ = std::numeric_limits<std::int32_t>::max();
    source_max_z_ = std::numeric_limits<std::int32_t>::min();
    cave_min_page_x_ = 0; cave_max_page_x_ = -1;
    cave_min_page_z_ = 0; cave_max_page_z_ = -1;
    cave_next_page_x_ = 0; cave_next_page_z_ = 0;
    collect_index_ = 0; sort_axis_ = 0; sort_i_ = 1; sort_j_ = 1;
    compact_axis_ = 0; compact_index_ = 0;
    primary_pending_ = true; last_page_valid_ = false; cave_pages_pending_ = false; phase_ = 0;
}

bool WorldShapingDependencyCursor::axes_ready() const noexcept { return phase_ == 3U; }

WorldShapingDependencyCursor::Step WorldShapingDependencyCursor::advance_axes(
    const WorldSourceDefinition &definition, const std::uint32_t offered_ops) {
    Step result;
    const std::uint32_t limit = std::min(offered_ops, 64U);
    if (phase_ == 3U) { result.ready = true; return result; }
    const auto bounds = native_terrain_page_bounds({primary_x_, primary_z_});
    if (!bounds) throw std::invalid_argument("borrowed source primary page is invalid");
    while (result.consumed_ops < limit && phase_ != 3U) {
        if (phase_ == 0U) {
            const std::size_t axis = collect_index_ / AXIS_LIMIT;
            const std::int32_t offset = static_cast<std::int32_t>(collect_index_ % AXIS_LIMIT);
            const std::int32_t origin = axis < 3U ? bounds->x : bounds->z;
            const std::int32_t cell = origin + offset;
            const auto &constants = definition.constants();
            const std::size_t channel = axis % 3U;
            const std::int32_t source = channel == 0U
                ? remapped_lattice_cell(cell, constants.cell_size_meters)
                : channel == 1U
                    ? remapped_center_cell(cell, constants.cell_center_offset_cells, constants.cell_size_meters)
                    : remapped_grid_cell(cell, constants.cell_size_meters);
            axes_[axis][offset] = floor_page(source);
            if (axis < 3U) {
                source_min_x_ = std::min(source_min_x_, source);
                source_max_x_ = std::max(source_max_x_, source);
            } else {
                source_min_z_ = std::min(source_min_z_, source);
                source_max_z_ = std::max(source_max_z_, source);
            }
            ++collect_index_; ++result.consumed_ops;
            if (collect_index_ == 6U * AXIS_LIMIT) phase_ = 1U;
        } else if (phase_ == 1U) {
            if (sort_i_ >= AXIS_LIMIT) {
                ++sort_axis_; sort_i_ = 1U; sort_j_ = 1U;
                if (sort_axis_ == 6U) phase_ = 2U;
            } else if (sort_j_ > 0U
                && axes_[sort_axis_][sort_j_ - 1U] > axes_[sort_axis_][sort_j_]) {
                std::swap(axes_[sort_axis_][sort_j_ - 1U], axes_[sort_axis_][sort_j_]);
                --sort_j_;
            } else {
                ++sort_i_; sort_j_ = sort_i_;
            }
            ++result.consumed_ops;
        } else {
            const std::int32_t value = axes_[compact_axis_][compact_index_];
            if (counts_[compact_axis_] == 0U
                || axes_[compact_axis_][counts_[compact_axis_] - 1U] != value)
                axes_[compact_axis_][counts_[compact_axis_]++] = value;
            ++compact_index_; ++result.consumed_ops;
            if (compact_index_ == AXIS_LIMIT) {
                ++compact_axis_; compact_index_ = 0U;
                if (compact_axis_ == 6U) {
                    const CaveShapingPageRange cave_range = cave_shaping_page_range(
                        definition, source_min_x_, source_max_x_, source_min_z_, source_max_z_);
                    if (cave_shaping_page_count(cave_range) > MAX_CAVE_SHAPING_DEPENDENCY_PAGES)
                        throw std::length_error("native cave shaping dependency set exceeds source limit");
                    const NativeTerrainPageKey low{cave_range.min_x, cave_range.min_z};
                    const NativeTerrainPageKey high{cave_range.max_x, cave_range.max_z};
                    if (!native_terrain_page_bounds(low) || !native_terrain_page_bounds(high))
                        throw std::invalid_argument("native cave shaping dependency page is invalid");
                    cave_min_page_x_ = cave_range.min_x; cave_max_page_x_ = cave_range.max_x;
                    cave_min_page_z_ = cave_range.min_z; cave_max_page_z_ = cave_range.max_z;
                    cave_next_page_x_ = cave_min_page_x_; cave_next_page_z_ = cave_min_page_z_;
                    cave_pages_pending_ = true;
                    phase_ = 3U;
                }
            }
        }
    }
    result.ready = phase_ == 3U;
    return result;
}

WorldShapingDependencyCursor::Step WorldShapingDependencyCursor::rewind_pages(
    const std::uint32_t offered_ops) noexcept {
    Step result;
    if (!axes_ready()) return result;
    if (offered_ops == 0U) return result;
    product_x_ = {}; product_z_ = {};
    primary_pending_ = true; last_page_valid_ = false;
    cave_next_page_x_ = cave_min_page_x_; cave_next_page_z_ = cave_min_page_z_;
    cave_pages_pending_ = cave_max_page_x_ >= cave_min_page_x_
        && cave_max_page_z_ >= cave_min_page_z_;
    result.consumed_ops = 1U; result.ready = true;
    return result;
}

WorldShapingDependencyCursor::Step WorldShapingDependencyCursor::next_page(
    const std::uint32_t offered_ops) noexcept {
    Step result;
    if (!axes_ready()) return result;
    result.ready = true;
    // One fixed merge visits at most five heads, then at most four matching
    // product cursors. Reserve 24 scalar comparisons/loads/advances rather
    // than charging one operation for the whole bounded loop.
    result.next_atomic_ops = 24U;
    const std::uint32_t limit = std::min(offered_ops, 64U);
    while (limit - result.consumed_ops >= 24U) {
        bool found = false;
        NativeTerrainPageKey minimum{};
        if (primary_pending_) { minimum = {primary_x_, primary_z_}; found = true; }
        for (std::size_t stream = 0; stream < 3U; ++stream) {
            if (product_z_[stream] >= counts_[stream + 3U]) continue;
            const NativeTerrainPageKey candidate{
                axes_[stream][product_x_[stream]], axes_[stream + 3U][product_z_[stream]]};
            if (!found || page_key_less(candidate, minimum)) { minimum = candidate; found = true; }
        }
        if (cave_pages_pending_) {
            const NativeTerrainPageKey candidate{cave_next_page_x_, cave_next_page_z_};
            if (!found || page_key_less(candidate, minimum)) { minimum = candidate; found = true; }
        }
        if (!found) { result.complete = true; result.next_atomic_ops = 0U; return result; }
        if (primary_pending_ && primary_x_ == minimum.x && primary_z_ == minimum.z)
            primary_pending_ = false;
        for (std::size_t stream = 0; stream < 3U; ++stream) {
            if (product_z_[stream] >= counts_[stream + 3U]) continue;
            if (axes_[stream][product_x_[stream]] != minimum.x
                || axes_[stream + 3U][product_z_[stream]] != minimum.z) continue;
            ++product_x_[stream];
            if (product_x_[stream] == counts_[stream]) {
                product_x_[stream] = 0U; ++product_z_[stream];
            }
        }
        if (cave_pages_pending_ && cave_next_page_x_ == minimum.x
            && cave_next_page_z_ == minimum.z) {
            if (cave_next_page_x_ < cave_max_page_x_) ++cave_next_page_x_;
            else if (cave_next_page_z_ < cave_max_page_z_) {
                cave_next_page_x_ = cave_min_page_x_;
                ++cave_next_page_z_;
            } else cave_pages_pending_ = false;
        }
        result.consumed_ops += 24U;
        if (!last_page_valid_ || minimum.x != last_page_x_ || minimum.z != last_page_z_) {
            last_page_valid_ = true; last_page_x_ = minimum.x; last_page_z_ = minimum.z;
            result.has_page = true; result.page_x = minimum.x; result.page_z = minimum.z;
            return result;
        }
    }
    return result;
}

WorldSourcePin::WorldSourcePin(
    WorldSourceDefinition definition,
    WorldDeltaPinnedSnapshot deltas,
    const NativeTerrainPageKey primary_page,
    const std::vector<NativeTerrainShapingPagePin> &shaping_pages)
    : definition_(std::move(definition)), deltas_(std::move(deltas)) {
    const std::vector<NativeTerrainPageKey> required =
        world_effective_shaping_dependencies(definition_, primary_page);
    std::vector<const NativeTerrainShapingPagePin *> canonical;
    canonical.reserve(shaping_pages.size());
    for (const NativeTerrainShapingPagePin &shaping : shaping_pages) canonical.push_back(&shaping);
    std::sort(canonical.begin(), canonical.end(), [](const auto *left, const auto *right) {
        return page_key_less(left->page_key(), right->page_key());
    });
    if (canonical.size() != required.size()) {
        throw std::invalid_argument("world source pin shaping dependency set is incomplete");
    }
    for (std::size_t index = 0; index < canonical.size(); ++index) {
        const NativeTerrainShapingPagePin &shaping = *canonical[index];
        if (!(shaping.page_key() == required[index])) {
            throw std::invalid_argument("world source pin shaping dependency set is invalid");
        }
        if (shaping.readiness() != NativeTerrainShapingPageReadiness::ready) {
            throw std::invalid_argument("world source pin requires ready terrain shaping");
        }
        if (!(shaping.snapshot()->definition().physical_content_identity()
                == definition_.physical_content_identity())) {
            throw std::invalid_argument("world source pin terrain shaping does not match source");
        }
        if (index == 0U) {
            shaping_registry_revision_ = shaping.registry_revision();
            shaping_registry_content_identity_ = shaping.registry_content_identity();
        } else if (shaping.registry_revision() != shaping_registry_revision_
            || !(shaping.registry_content_identity() == shaping_registry_content_identity_)) {
            throw std::invalid_argument("world source pin mixes terrain shaping registry snapshots");
        }
        terrain_shaping_pages_.push_back(shaping.snapshot());
        const NativeHorizontalRect shaping_bounds = shaping.snapshot()->page_bounds();
        typed_projection_digests_.push_back(deltas_.typed_projection_digest(
            {shaping_bounds.x, shaping_bounds.z, shaping_bounds.width, shaping_bounds.depth}));
        if (shaping.page_key() == primary_page) primary_terrain_shaping_ = shaping.snapshot();
    }
    const NativeHorizontalRect bounds = primary_terrain_shaping_->page_bounds();
    physical_content_identity_ = pinned_identity(
        definition_.physical_content_identity(), bounds, terrain_shaping_pages_,
        typed_projection_digests_);
}
const WorldSourceDefinition &WorldSourcePin::definition() const noexcept { return definition_; }
const WorldDeltaPinnedSnapshot &WorldSourcePin::deltas() const noexcept { return deltas_; }
const NativeTerrainShapingSnapshot &WorldSourcePin::primary_terrain_shaping() const noexcept { return *primary_terrain_shaping_; }
const NativeTerrainShapingSnapshot &WorldSourcePin::terrain_shaping_for_page(
    const NativeTerrainPageKey page) const {
    const auto found = std::lower_bound(terrain_shaping_pages_.begin(), terrain_shaping_pages_.end(), page,
        [](const auto &snapshot, const NativeTerrainPageKey key) {
            return page_key_less(snapshot->page_key(), key);
        });
    if (found == terrain_shaping_pages_.end() || !((*found)->page_key() == page)) {
        throw std::out_of_range("terrain shaping page is not pinned");
    }
    return **found;
}
std::size_t WorldSourcePin::terrain_shaping_page_count() const noexcept { return terrain_shaping_pages_.size(); }
std::uint64_t WorldSourcePin::terrain_delta_revision() const noexcept { return deltas_.revision(); }
std::uint64_t WorldSourcePin::shaping_registry_revision() const noexcept { return shaping_registry_revision_; }
const WorldPhysicalContentIdentity &WorldSourcePin::shaping_registry_content_identity() const noexcept { return shaping_registry_content_identity_; }
const Sha256Digest &WorldSourcePin::typed_projection_digest_for_page(
    const NativeTerrainPageKey page) const {
    const auto found = std::lower_bound(terrain_shaping_pages_.begin(), terrain_shaping_pages_.end(), page,
        [](const auto &snapshot, const NativeTerrainPageKey key) {
            return page_key_less(snapshot->page_key(), key);
        });
    if (found == terrain_shaping_pages_.end() || !((*found)->page_key() == page)) {
        throw std::out_of_range("typed projection page is not pinned");
    }
    return typed_projection_digests_[static_cast<std::size_t>(found - terrain_shaping_pages_.begin())];
}
const WorldPhysicalContentIdentity &WorldSourcePin::physical_content_identity() const noexcept { return physical_content_identity_; }
} // namespace voxel::world_backend
