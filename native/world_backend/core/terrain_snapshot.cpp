#include "terrain_snapshot.hpp"

#include "sha256.hpp"

#include <algorithm>
#include <cmath>
#include <cstring>
#include <limits>
#include <stdexcept>
#include <utility>

namespace voxel::world_backend {
namespace {

class Writer {
public:
    void u8(const std::uint8_t value) { bytes_.push_back(value); }
    void u32(const std::uint32_t value) {
        for (unsigned shift = 0; shift < 32U; shift += 8U) u8(static_cast<std::uint8_t>(value >> shift));
    }
    void i32(const std::int32_t value) { u32(static_cast<std::uint32_t>(value)); }
    void u64(const std::uint64_t value) {
        for (unsigned shift = 0; shift < 64U; shift += 8U) u8(static_cast<std::uint8_t>(value >> shift));
    }
    void binary64(const double value) {
        std::uint64_t bits = 0;
        static_assert(sizeof(bits) == sizeof(value));
        std::memcpy(&bits, &value, sizeof(bits));
        u64(bits);
    }
    void raw(const std::uint8_t *data, const std::size_t size) { bytes_.insert(bytes_.end(), data, data + size); }
    void text(const std::string &value) {
        u32(canonical_u32_length(value.size()));
        raw(reinterpret_cast<const std::uint8_t *>(value.data()), value.size());
    }
    void coord(const CellCoord &value) { i32(value.x); i32(value.y); i32(value.z); }
    std::vector<std::uint8_t> finish() { return std::move(bytes_); }
private:
    std::vector<std::uint8_t> bytes_;
};

bool enum_valid(const TerrainMaterialId value) noexcept {
    return static_cast<std::uint8_t>(value) <= static_cast<std::uint8_t>(TerrainMaterialId::lava);
}
bool enum_valid(const TerrainBiomeId value) noexcept {
    return static_cast<std::uint8_t>(value) <= static_cast<std::uint8_t>(TerrainBiomeId::alpine);
}
bool enum_valid(const TerrainFluidId value) noexcept {
    return value == TerrainFluidId::none || value == TerrainFluidId::water || value == TerrainFluidId::lava;
}
bool enum_valid(const TerrainProvenanceKind value) noexcept {
    return value == TerrainProvenanceKind::generated || value == TerrainProvenanceKind::typed_delta;
}

bool nonempty_text(const std::string &value) noexcept {
    return !value.empty() && value.find('\0') == std::string::npos;
}

bool digest_nonzero(const Sha256Digest &digest) noexcept {
    return std::any_of(digest.begin(), digest.end(), [](const std::uint8_t value) { return value != 0U; });
}

std::size_t checked_dimension(const std::int32_t minimum, const std::int32_t maximum, const char *axis) {
    static_assert(std::numeric_limits<std::size_t>::max() >= std::numeric_limits<std::uint32_t>::max(),
        "terrain snapshots require a size_t capable of holding any int32 coordinate span");
    const std::int64_t difference = static_cast<std::int64_t>(maximum) - static_cast<std::int64_t>(minimum);
    if (difference <= 0) throw std::invalid_argument(std::string("snapshot ") + axis + " extent must be positive");
    return static_cast<std::size_t>(difference);
}

std::size_t checked_product(const std::size_t left, const std::size_t right) {
    if (left > std::numeric_limits<std::size_t>::max() / right) {
        throw std::overflow_error("snapshot cell count overflows size_t");
    }
    return left * right;
}

CellCoord expected_coord(
    const CellRegion &region,
    const std::size_t index,
    const std::size_t size_x,
    const std::size_t size_z) {
    const std::size_t plane = size_x * size_z;
    const std::size_t y = index / plane;
    const std::size_t remainder = index % plane;
    const std::size_t z = remainder / size_x;
    const std::size_t x = remainder % size_x;
    return {
        static_cast<std::int32_t>(static_cast<std::int64_t>(region.minimum.x) + static_cast<std::int64_t>(x)),
        static_cast<std::int32_t>(static_cast<std::int64_t>(region.minimum.y) + static_cast<std::int64_t>(y)),
        static_cast<std::int32_t>(static_cast<std::int64_t>(region.minimum.z) + static_cast<std::int64_t>(z)),
    };
}

void validate_cell(const TerrainCell &cell) {
    if (!std::isfinite(cell.density) || !std::isfinite(cell.surface_y)) {
        throw std::invalid_argument("terrain cell has nonfinite numeric data");
    }
    if (cell.solid != (cell.density >= 0.0)) throw std::invalid_argument("terrain cell solidity disagrees with density");
    if (!enum_valid(cell.material) || !enum_valid(cell.surface_biome) || !enum_valid(cell.resolved_biome)
        || !enum_valid(cell.fluid) || !enum_valid(cell.provenance)) {
        throw std::invalid_argument("terrain cell has an unknown typed value");
    }
    if (!nonempty_text(cell.provenance_id) || cell.provenance_revision == 0U) {
        throw std::invalid_argument("terrain cell provenance must have a nonempty ID and nonzero revision");
    }
    if (!cell.solid && cell.material != TerrainMaterialId::air && cell.material != TerrainMaterialId::water
        && cell.material != TerrainMaterialId::lava) {
        throw std::invalid_argument("nonsolid terrain cell has a solid material");
    }
    if (cell.solid && cell.material == TerrainMaterialId::air) {
        throw std::invalid_argument("solid terrain cell has air material");
    }
    if (cell.fluid == TerrainFluidId::water && cell.material != TerrainMaterialId::water) {
        throw std::invalid_argument("water fluid requires water material");
    }
    if (cell.fluid == TerrainFluidId::lava && cell.material != TerrainMaterialId::lava) {
        throw std::invalid_argument("lava fluid requires lava material");
    }
}

void validate_blocker(const DeclaredFeatureBlocker &blocker) {
    if (!nonempty_text(blocker.stable_id) || !nonempty_text(blocker.semantic_class)
        || !nonempty_text(blocker.physical_intent)) {
        throw std::invalid_argument("feature blocker strings must be nonempty");
    }
    const double values[] = {blocker.center.x, blocker.center.y, blocker.center.z,
        blocker.size.x, blocker.size.y, blocker.size.z};
    for (const double value : values) {
        if (!std::isfinite(value)) throw std::invalid_argument("feature blocker has nonfinite geometry");
    }
    if (blocker.size.x <= 0.0 || blocker.size.y <= 0.0 || blocker.size.z <= 0.0) {
        throw std::invalid_argument("feature blocker size must be positive");
    }
}

std::vector<std::uint8_t> serialize(
    const TerrainSnapshotDescriptor &descriptor,
    const std::vector<TerrainCell> &cells,
    const std::vector<DeclaredFeatureBlocker> &blockers) {
    Writer writer;
    static constexpr std::uint8_t MAGIC[] = {'V', 'W', 'T', 'S'};
    writer.raw(MAGIC, sizeof(MAGIC));
    writer.u32(descriptor.schema);
    writer.raw(descriptor.authority.world_digest.data(), descriptor.authority.world_digest.size());
    writer.u64(descriptor.authority.owner.value);
    writer.u64(descriptor.authority.cancellation.value);
    writer.u64(descriptor.authority.source_revision.value);
    writer.text(descriptor.transaction_id);
    writer.coord(descriptor.sample_region.minimum);
    writer.coord(descriptor.sample_region.maximum_exclusive);
    writer.u32(canonical_u32_length(cells.size()));
    for (const TerrainCell &cell : cells) {
        writer.coord(cell.coordinate);
        writer.binary64(cell.density);
        writer.binary64(cell.surface_y);
        writer.u8(cell.solid ? 1U : 0U);
        writer.u8(static_cast<std::uint8_t>(cell.material));
        writer.u8(static_cast<std::uint8_t>(cell.surface_biome));
        writer.u8(static_cast<std::uint8_t>(cell.resolved_biome));
        writer.u8(static_cast<std::uint8_t>(cell.fluid));
        writer.u8(static_cast<std::uint8_t>(cell.provenance));
        writer.text(cell.provenance_id);
        writer.u64(cell.provenance_revision);
    }
    writer.u32(canonical_u32_length(blockers.size()));
    for (const DeclaredFeatureBlocker &blocker : blockers) {
        writer.text(blocker.stable_id);
        writer.binary64(blocker.center.x); writer.binary64(blocker.center.y); writer.binary64(blocker.center.z);
        writer.binary64(blocker.size.x); writer.binary64(blocker.size.y); writer.binary64(blocker.size.z);
        writer.text(blocker.semantic_class);
        writer.text(blocker.physical_intent);
    }
    return writer.finish();
}

} // namespace

bool Vec3d::operator==(const Vec3d &other) const noexcept { return x == other.x && y == other.y && z == other.z; }

bool TerrainCell::operator==(const TerrainCell &other) const noexcept {
    return coordinate == other.coordinate && density == other.density && surface_y == other.surface_y
        && solid == other.solid && material == other.material && surface_biome == other.surface_biome
        && resolved_biome == other.resolved_biome && fluid == other.fluid && provenance == other.provenance
        && provenance_id == other.provenance_id && provenance_revision == other.provenance_revision;
}

bool DeclaredFeatureBlocker::operator==(const DeclaredFeatureBlocker &other) const noexcept {
    return stable_id == other.stable_id && center == other.center && size == other.size
        && semantic_class == other.semantic_class && physical_intent == other.physical_intent;
}

TerrainSnapshot TerrainSnapshot::create(
    TerrainSnapshotDescriptor descriptor,
    std::vector<TerrainCell> cells,
    std::vector<DeclaredFeatureBlocker> blockers) {
    if (descriptor.schema != TerrainSnapshotDescriptor::SCHEMA) throw std::invalid_argument("unsupported terrain snapshot schema");
    if (!digest_nonzero(descriptor.authority.world_digest) || descriptor.authority.owner.value == 0U
        || descriptor.authority.cancellation.value == 0U || descriptor.authority.source_revision.value == 0U) {
        throw std::invalid_argument("terrain snapshot authority is incomplete");
    }
    if (!nonempty_text(descriptor.transaction_id)) throw std::invalid_argument("terrain snapshot transaction ID is empty");
    const std::size_t size_x = checked_dimension(descriptor.sample_region.minimum.x, descriptor.sample_region.maximum_exclusive.x, "X");
    const std::size_t size_y = checked_dimension(descriptor.sample_region.minimum.y, descriptor.sample_region.maximum_exclusive.y, "Y");
    const std::size_t size_z = checked_dimension(descriptor.sample_region.minimum.z, descriptor.sample_region.maximum_exclusive.z, "Z");
    const std::size_t expected_count = checked_product(checked_product(size_x, size_z), size_y);
    if (cells.size() != expected_count) throw std::invalid_argument("terrain snapshot cells are incomplete");
    for (std::size_t index = 0; index < cells.size(); ++index) {
        if (!(cells[index].coordinate == expected_coord(descriptor.sample_region, index, size_x, size_z))) {
            throw std::invalid_argument("terrain snapshot cells are not X-then-Z-then-Y row-major");
        }
        validate_cell(cells[index]);
    }
    for (const DeclaredFeatureBlocker &blocker : blockers) validate_blocker(blocker);
    std::sort(blockers.begin(), blockers.end(), [](const auto &left, const auto &right) { return left.stable_id < right.stable_id; });
    for (std::size_t index = 1; index < blockers.size(); ++index) {
        if (blockers[index - 1U].stable_id == blockers[index].stable_id) throw std::invalid_argument("duplicate feature blocker ID");
    }
    auto canonical = serialize(descriptor, cells, blockers);
    auto digest = sha256(canonical);
    return TerrainSnapshot(std::move(descriptor), std::move(cells), std::move(blockers),
        std::move(canonical), digest, size_x, size_y, size_z);
}

TerrainSnapshot::TerrainSnapshot(
    TerrainSnapshotDescriptor descriptor,
    std::vector<TerrainCell> cells,
    std::vector<DeclaredFeatureBlocker> blockers,
    std::vector<std::uint8_t> canonical_bytes,
    const Sha256Digest digest,
    const std::size_t size_x,
    const std::size_t size_y,
    const std::size_t size_z)
    : descriptor_(std::move(descriptor)), cells_(std::move(cells)), blockers_(std::move(blockers)),
      canonical_bytes_(std::move(canonical_bytes)), digest_(digest), size_x_(size_x), size_y_(size_y), size_z_(size_z) {}

const TerrainSnapshotDescriptor &TerrainSnapshot::descriptor() const noexcept { return descriptor_; }
const CellRegion &TerrainSnapshot::sample_region() const noexcept { return descriptor_.sample_region; }
const std::vector<TerrainCell> &TerrainSnapshot::cells() const noexcept { return cells_; }
const std::vector<DeclaredFeatureBlocker> &TerrainSnapshot::blockers() const noexcept { return blockers_; }
const std::vector<std::uint8_t> &TerrainSnapshot::canonical_bytes() const noexcept { return canonical_bytes_; }
const Sha256Digest &TerrainSnapshot::digest() const noexcept { return digest_; }
std::string TerrainSnapshot::digest_hex() const { return sha256_hex(digest_); }
std::size_t TerrainSnapshot::size_x() const noexcept { return size_x_; }
std::size_t TerrainSnapshot::size_y() const noexcept { return size_y_; }
std::size_t TerrainSnapshot::size_z() const noexcept { return size_z_; }

bool TerrainSnapshot::contains(const CellCoord &coordinate) const noexcept {
    const CellRegion &region = descriptor_.sample_region;
    return coordinate.x >= region.minimum.x && coordinate.x < region.maximum_exclusive.x
        && coordinate.y >= region.minimum.y && coordinate.y < region.maximum_exclusive.y
        && coordinate.z >= region.minimum.z && coordinate.z < region.maximum_exclusive.z;
}

std::size_t TerrainSnapshot::index_of(const CellCoord &coordinate) const {
    if (!contains(coordinate)) throw std::out_of_range("terrain coordinate is outside snapshot");
    const std::size_t x = static_cast<std::size_t>(static_cast<std::int64_t>(coordinate.x) - descriptor_.sample_region.minimum.x);
    const std::size_t y = static_cast<std::size_t>(static_cast<std::int64_t>(coordinate.y) - descriptor_.sample_region.minimum.y);
    const std::size_t z = static_cast<std::size_t>(static_cast<std::int64_t>(coordinate.z) - descriptor_.sample_region.minimum.z);
    return (y * size_z_ + z) * size_x_ + x;
}

const TerrainCell &TerrainSnapshot::at(const CellCoord &coordinate) const { return cells_[index_of(coordinate)]; }
const TerrainCell &TerrainSnapshot::at_index(const std::size_t index) const {
    if (index >= cells_.size()) throw std::out_of_range("terrain cell index is outside snapshot");
    return cells_[index];
}

const char *terrain_material_name(const TerrainMaterialId material) noexcept {
    static constexpr const char *NAMES[] = {"air", "grass", "dirt", "stone", "sand", "snow", "deepStone", "bedrock",
        "clay", "gravel", "coalOre", "ironOre", "crystalOre", "copperOre", "mud", "water", "lava"};
    const auto index = static_cast<std::size_t>(material);
    return index < std::size(NAMES) ? NAMES[index] : "unknown";
}

const char *terrain_biome_name(const TerrainBiomeId biome) noexcept {
    static constexpr const char *NAMES[] = {"plains", "forest", "swamp", "desert", "savanna", "snow", "taiga", "tundra",
        "ocean", "beach", "town", "underground", "deep_underground", "underground_air", "alpine"};
    const auto index = static_cast<std::size_t>(biome);
    return index < std::size(NAMES) ? NAMES[index] : "unknown";
}

} // namespace voxel::world_backend
