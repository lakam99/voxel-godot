#include "native_generated_terrain_patch.hpp"

#include "sha256.hpp"

#include <algorithm>
#include <cmath>
#include <cstring>
#include <limits>
#include <set>
#include <tuple>
#include <utility>

namespace voxel::world_backend {
namespace {

[[noreturn]] void reject(const NativeGeneratedTerrainPatchFailure failure) {
    throw NativeGeneratedTerrainPatchError(failure);
}

class CanonicalWriter final {
public:
    void append_magic(const char (&value)[5]) {
        bytes_.insert(bytes_.end(), value, value + 4);
    }

    void append_u8(const std::uint8_t value) { bytes_.push_back(value); }

    void append_u32(const std::uint32_t value) {
        for (int shift = 24; shift >= 0; shift -= 8) {
            bytes_.push_back(static_cast<std::uint8_t>((value >> shift) & 0xffU));
        }
    }

    void append_i32(const std::int32_t value) { append_u32(static_cast<std::uint32_t>(value)); }

    void append_u64(const std::uint64_t value) {
        for (int shift = 56; shift >= 0; shift -= 8) {
            bytes_.push_back(static_cast<std::uint8_t>((value >> shift) & 0xffU));
        }
    }

    void append_f64(const double value) {
        std::uint64_t bits = 0U;
        static_assert(sizeof(bits) == sizeof(value), "generated patch density requires binary64");
        std::memcpy(&bits, &value, sizeof(bits));
        append_u64(bits);
    }

    void append_raw(const std::uint8_t *data, const std::size_t size) {
        bytes_.insert(bytes_.end(), data, data + size);
    }

    void append_bytes(const std::uint8_t *data, const std::size_t size) {
        append_u32(static_cast<std::uint32_t>(size));
        append_raw(data, size);
    }

    void append_text(const std::string &value) {
        append_bytes(reinterpret_cast<const std::uint8_t *>(value.data()), value.size());
    }

    const std::vector<std::uint8_t> &bytes() const noexcept { return bytes_; }
    std::vector<std::uint8_t> finish() { return std::move(bytes_); }

private:
    std::vector<std::uint8_t> bytes_;
};

bool digest_is_zero(const Sha256Digest &digest) noexcept {
    return std::all_of(digest.begin(), digest.end(), [](const std::uint8_t byte) { return byte == 0U; });
}

bool utf8_less(const std::string &left, const std::string &right) noexcept {
    return std::lexicographical_compare(left.begin(), left.end(), right.begin(), right.end(),
        [](const char left_byte, const char right_byte) {
            return static_cast<unsigned char>(left_byte) < static_cast<unsigned char>(right_byte);
        });
}

void validate_text(const std::string &text) {
    if (text.empty() || text.size() > NativeGeneratedTerrainPatchLimits::MAX_TEXT_FIELD_BYTES) {
        reject(NativeGeneratedTerrainPatchFailure::invalid_text);
    }
    try {
        static_cast<void>(NativeValue::string(text));
    } catch (const NativeValueRejected &) {
        reject(NativeGeneratedTerrainPatchFailure::invalid_text);
    }
}

bool valid_box(const NativeInclusiveCellBox &box) noexcept {
    return box.minimum.x <= box.maximum.x && box.minimum.y <= box.maximum.y && box.minimum.z <= box.maximum.z;
}

bool contains_box(const NativeInclusiveCellBox &outer, const NativeInclusiveCellBox &inner) noexcept {
    return outer.contains(inner.minimum) && outer.contains(inner.maximum);
}

std::optional<NativeInclusiveCellBox> intersect_boxes(
    const NativeInclusiveCellBox &left, const NativeInclusiveCellBox &right) noexcept {
    NativeInclusiveCellBox result{
        {std::max(left.minimum.x, right.minimum.x), std::max(left.minimum.y, right.minimum.y),
            std::max(left.minimum.z, right.minimum.z)},
        {std::min(left.maximum.x, right.maximum.x), std::min(left.maximum.y, right.maximum.y),
            std::min(left.maximum.z, right.maximum.z)}};
    if (!valid_box(result)) return std::nullopt;
    return result;
}

std::uint64_t checked_box_volume(const NativeInclusiveCellBox &box) {
    const std::uint64_t size_x = static_cast<std::uint64_t>(
        static_cast<std::int64_t>(box.maximum.x) - static_cast<std::int64_t>(box.minimum.x) + 1);
    const std::uint64_t size_y = static_cast<std::uint64_t>(
        static_cast<std::int64_t>(box.maximum.y) - static_cast<std::int64_t>(box.minimum.y) + 1);
    const std::uint64_t size_z = static_cast<std::uint64_t>(
        static_cast<std::int64_t>(box.maximum.z) - static_cast<std::int64_t>(box.minimum.z) + 1);
    if (size_x > NativeGeneratedTerrainPatchLimits::MAX_OPERATION_CELL_VOLUME
        || size_y > NativeGeneratedTerrainPatchLimits::MAX_OPERATION_CELL_VOLUME
        || size_z > NativeGeneratedTerrainPatchLimits::MAX_OPERATION_CELL_VOLUME) {
        reject(NativeGeneratedTerrainPatchFailure::operation_volume_limit);
    }
    const std::uint64_t xy = size_x * size_y;
    if (xy > std::numeric_limits<std::uint64_t>::max() / size_z) {
        reject(NativeGeneratedTerrainPatchFailure::coordinate_overflow);
    }
    return xy * size_z;
}

std::int32_t section_coordinate(const std::int32_t cell) noexcept {
    const std::int64_t value = cell;
    const std::int64_t divisor = NativeGeneratedTerrainPatchLimits::SECTION_SIZE;
    const std::int64_t quotient = value / divisor;
    const std::int64_t remainder = value % divisor;
    return static_cast<std::int32_t>(quotient - (remainder < 0 ? 1 : 0));
}

struct CellCoordLess final {
    bool operator()(const CellCoord &left, const CellCoord &right) const noexcept {
        if (left.z != right.z) return left.z < right.z;
        if (left.y != right.y) return left.y < right.y;
        return left.x < right.x;
    }
};

std::vector<CellCoord> collect_affected_sections(
    const std::vector<NativeGeneratedTerrainPatchOperation> &operations,
    const NativeGeneratedTerrainPatchFailure failure) {
    std::set<CellCoord, CellCoordLess> unique;
    for (const NativeGeneratedTerrainPatchOperation &operation : operations) {
        const CellCoord minimum{
            section_coordinate(operation.bounds.minimum.x), section_coordinate(operation.bounds.minimum.y),
            section_coordinate(operation.bounds.minimum.z)};
        const CellCoord maximum{
            section_coordinate(operation.bounds.maximum.x), section_coordinate(operation.bounds.maximum.y),
            section_coordinate(operation.bounds.maximum.z)};
        for (std::int64_t z = minimum.z; z <= maximum.z; ++z) {
            for (std::int64_t y = minimum.y; y <= maximum.y; ++y) {
                for (std::int64_t x = minimum.x; x <= maximum.x; ++x) {
                    unique.insert({static_cast<std::int32_t>(x), static_cast<std::int32_t>(y),
                        static_cast<std::int32_t>(z)});
                    if (unique.size() > NativeGeneratedTerrainPatchLimits::MAX_AFFECTED_SECTIONS) reject(failure);
                }
            }
        }
    }
    return {unique.begin(), unique.end()};
}

bool valid_material(const TerrainMaterialId value) noexcept {
    return static_cast<std::uint8_t>(value) <= static_cast<std::uint8_t>(TerrainMaterialId::lava);
}

bool valid_biome(const TerrainBiomeId value) noexcept {
    return static_cast<std::uint8_t>(value) <= static_cast<std::uint8_t>(TerrainBiomeId::alpine);
}

bool valid_fluid(const TerrainFluidId value) noexcept {
    return static_cast<std::uint8_t>(value) <= static_cast<std::uint8_t>(TerrainFluidId::lava);
}

bool reserved_metadata_key(const std::string &key) noexcept {
    return key == "saveDelta" || key == "terrainMeshAffects" || key == "affectsTerrainMesh"
        || key == "affectsSurfaceProjection" || key == "surfaceProjectionAffects"
        || key == "renderedBySceneBlock"
        || key == "persistsInSave" || key == "persistence" || key == "namespace";
}

void checked_add_utf8(std::size_t &total, const std::size_t added) {
    if (added > NativeGeneratedTerrainPatchLimits::MAX_MANIFEST_UTF8_BYTES - total) {
        reject(NativeGeneratedTerrainPatchFailure::utf8_bytes_limit);
    }
    total += added;
}

std::size_t utf8_bytes(const NativeValue &value) {
    if (value.kind() == NativeValueKind::string) return value.as_string().size();
    if (value.kind() == NativeValueKind::array) {
        std::size_t result = 0U;
        for (const NativeValue &child : value.as_array()) checked_add_utf8(result, utf8_bytes(child));
        return result;
    }
    if (value.kind() == NativeValueKind::object) {
        std::size_t result = 0U;
        for (const auto &entry : value.as_object()) {
            checked_add_utf8(result, entry.first.size());
            checked_add_utf8(result, utf8_bytes(entry.second));
        }
        return result;
    }
    return 0U;
}

void validate_role_state(const NativeGeneratedTerrainPatchOperation &operation) {
    const NativeGeneratedTerrainCellTemplate &state = operation.state;
    if (operation.role == NativeGeneratedTerrainPatchRole::interior_clearance) {
        if (state.solid || state.density >= 0.0 || state.material != TerrainMaterialId::air
            || state.block_identity.has_value()) {
            reject(NativeGeneratedTerrainPatchFailure::invalid_cell_state);
        }
        return;
    }
    // The only remaining admitted roles are foundation_fill and floor_cap.
    if (!state.solid || state.density <= 0.0) {
        reject(NativeGeneratedTerrainPatchFailure::invalid_cell_state);
    }
}

void validate_state(const NativeGeneratedTerrainCellTemplate &state) {
    if (!valid_material(state.material) || !valid_biome(state.biome) || !valid_fluid(state.fluid)
        || !std::isfinite(state.density) || state.light.sky > 15U || state.light.block > 15U) {
        reject(NativeGeneratedTerrainPatchFailure::invalid_cell_state);
    }
    const bool fluid_zero = !state.solid && state.density == 0.0
        && (state.fluid == TerrainFluidId::water || state.fluid == TerrainFluidId::lava);
    if ((!fluid_zero && state.solid != (state.density >= 0.0))
        || (state.solid && state.fluid != TerrainFluidId::none)
        || (state.fluid == TerrainFluidId::water && state.material != TerrainMaterialId::water)
        || (state.fluid == TerrainFluidId::lava && state.material != TerrainMaterialId::lava)
        || (state.fluid == TerrainFluidId::none
            && (state.material == TerrainMaterialId::water || state.material == TerrainMaterialId::lava))
        || (state.solid && state.material == TerrainMaterialId::air)) {
        reject(NativeGeneratedTerrainPatchFailure::invalid_cell_state);
    }
    if (state.block_identity.has_value()) validate_text(*state.block_identity);
    try {
        if (state.metadata.kind() != NativeValueKind::object) {
            reject(NativeGeneratedTerrainPatchFailure::invalid_cell_state);
        }
        static_cast<void>(state.metadata.canonical_binary());
    } catch (const NativeValueRejected &) {
        reject(NativeGeneratedTerrainPatchFailure::invalid_cell_state);
    }
    for (const auto &entry : state.metadata.as_object()) {
        if (reserved_metadata_key(entry.first)) {
            reject(NativeGeneratedTerrainPatchFailure::forbidden_policy_metadata);
        }
    }
}

bool valid_role(const NativeGeneratedTerrainPatchRole role) noexcept {
    return role == NativeGeneratedTerrainPatchRole::foundation_fill
        || role == NativeGeneratedTerrainPatchRole::floor_cap
        || role == NativeGeneratedTerrainPatchRole::interior_clearance;
}

bool valid_lifecycle(const NativeGeneratedTerrainPatchLifecycle lifecycle) noexcept {
    return lifecycle == NativeGeneratedTerrainPatchLifecycle::permanent_site_shaping
        || lifecycle == NativeGeneratedTerrainPatchLifecycle::follows_feature_tombstone;
}

bool operation_precedence_less(
    const NativeGeneratedTerrainPatchOperation &left,
    const NativeGeneratedTerrainPatchOperation &right) noexcept {
    if (left.deterministic_order != right.deterministic_order) {
        return left.deterministic_order < right.deterministic_order;
    }
    if (left.owner_feature_id != right.owner_feature_id) {
        return utf8_less(left.owner_feature_id, right.owner_feature_id);
    }
    return left.operation_ordinal < right.operation_ordinal;
}

bool same_identity(
    const NativeGeneratedTerrainPatchOperation &left,
    const NativeGeneratedTerrainPatchOperation &right) noexcept {
    return left.owner_feature_id == right.owner_feature_id && left.recipe_revision == right.recipe_revision
        && left.operation_ordinal == right.operation_ordinal;
}

bool same_precedence_key(
    const NativeGeneratedTerrainPatchOperation &left,
    const NativeGeneratedTerrainPatchOperation &right) noexcept {
    return left.deterministic_order == right.deterministic_order
        && left.owner_feature_id == right.owner_feature_id
        && left.operation_ordinal == right.operation_ordinal;
}

void append_coord(CanonicalWriter &writer, const CellCoord value) {
    writer.append_i32(value.x);
    writer.append_i32(value.y);
    writer.append_i32(value.z);
}

void append_box(CanonicalWriter &writer, const NativeInclusiveCellBox &box) {
    append_coord(writer, box.minimum);
    append_coord(writer, box.maximum);
}

void append_state(CanonicalWriter &writer, const NativeGeneratedTerrainCellTemplate &state) {
    writer.append_u8(static_cast<std::uint8_t>(state.material));
    writer.append_u8(static_cast<std::uint8_t>(state.biome));
    writer.append_u8(state.solid ? 1U : 0U);
    writer.append_f64(state.density);
    writer.append_u8(static_cast<std::uint8_t>(state.fluid));
    writer.append_u8(state.light.sky);
    writer.append_u8(state.light.block);
    writer.append_u8(state.block_identity.has_value() ? 1U : 0U);
    if (state.block_identity.has_value()) writer.append_text(*state.block_identity);
    const std::vector<std::uint8_t> metadata = state.metadata.canonical_binary();
    writer.append_bytes(metadata.data(), metadata.size());
}

void append_operation(CanonicalWriter &writer, const NativeGeneratedTerrainPatchOperation &operation) {
    writer.append_u8(static_cast<std::uint8_t>(operation.source_layer));
    writer.append_text(operation.owner_feature_id);
    writer.append_u32(operation.recipe_revision);
    writer.append_u32(operation.deterministic_order);
    writer.append_u32(operation.operation_ordinal);
    writer.append_u8(static_cast<std::uint8_t>(operation.role));
    writer.append_u8(static_cast<std::uint8_t>(operation.lifecycle));
    append_box(writer, operation.bounds);
    append_state(writer, operation.state);
}

std::vector<std::uint8_t> manifest_binary(const NativeGeneratedTerrainPatchManifestDescriptor &descriptor) {
    CanonicalWriter writer;
    writer.append_magic("GPM1");
    writer.append_u32(descriptor.schema_revision);
    writer.append_raw(descriptor.world_physical_identity.digest.data(), descriptor.world_physical_identity.digest.size());
    writer.append_text(descriptor.region_id);
    append_box(writer, descriptor.complete_region_bounds);
    writer.append_u32(descriptor.producer_revision);
    writer.append_u64(descriptor.feature_source_revision);
    writer.append_u32(static_cast<std::uint32_t>(descriptor.operations.size()));
    for (const NativeGeneratedTerrainPatchOperation &operation : descriptor.operations) append_operation(writer, operation);
    if (writer.bytes().size() > NativeGeneratedTerrainPatchLimits::MAX_MANIFEST_CANONICAL_BYTES) {
        reject(NativeGeneratedTerrainPatchFailure::canonical_bytes_limit);
    }
    return writer.finish();
}

NativeInclusiveCellBox expand_box(
    const NativeInclusiveCellBox &box, const NativeGeneratedTerrainPatchHalo halo) {
    const std::int64_t minimum_x = static_cast<std::int64_t>(box.minimum.x) - halo.x;
    const std::int64_t minimum_y = static_cast<std::int64_t>(box.minimum.y) - halo.y;
    const std::int64_t minimum_z = static_cast<std::int64_t>(box.minimum.z) - halo.z;
    const std::int64_t maximum_x = static_cast<std::int64_t>(box.maximum.x) + halo.x;
    const std::int64_t maximum_y = static_cast<std::int64_t>(box.maximum.y) + halo.y;
    const std::int64_t maximum_z = static_cast<std::int64_t>(box.maximum.z) + halo.z;
    if (minimum_x < std::numeric_limits<std::int32_t>::min()
        || minimum_y < std::numeric_limits<std::int32_t>::min()
        || minimum_z < std::numeric_limits<std::int32_t>::min()
        || maximum_x > std::numeric_limits<std::int32_t>::max()
        || maximum_y > std::numeric_limits<std::int32_t>::max()
        || maximum_z > std::numeric_limits<std::int32_t>::max()) {
        reject(NativeGeneratedTerrainPatchFailure::coordinate_overflow);
    }
    return {{static_cast<std::int32_t>(minimum_x), static_cast<std::int32_t>(minimum_y),
                static_cast<std::int32_t>(minimum_z)},
        {static_cast<std::int32_t>(maximum_x), static_cast<std::int32_t>(maximum_y),
            static_cast<std::int32_t>(maximum_z)}};
}

bool tombstoned(const std::vector<std::string> &tombstones, const std::string &id) {
    return std::binary_search(tombstones.begin(), tombstones.end(), id,
        [](const std::string &left, const std::string &right) { return utf8_less(left, right); });
}

std::vector<std::uint8_t> page_binary(
    const NativeGeneratedTerrainPatchManifest &manifest,
    const NativeGeneratedTerrainPageDomain &domain,
    const NativeInclusiveCellBox &projected_bounds,
    const std::vector<NativeGeneratedTerrainPatchOperation> &operations) {
    CanonicalWriter writer;
    writer.append_magic("GPP1");
    writer.append_u32(NativeGeneratedTerrainPatchManifestDescriptor::SCHEMA_REVISION);
    writer.append_raw(manifest.world_physical_identity().digest.data(), manifest.world_physical_identity().digest.size());
    writer.append_text(manifest.region_id());
    writer.append_u32(manifest.producer_revision());
    writer.append_text(domain.page_id);
    append_coord(writer, domain.scope_coordinate);
    append_box(writer, domain.owned_bounds);
    writer.append_u8(domain.mesh_halo.x);
    writer.append_u8(domain.mesh_halo.y);
    writer.append_u8(domain.mesh_halo.z);
    append_box(writer, projected_bounds);
    writer.append_u32(static_cast<std::uint32_t>(operations.size()));
    for (const NativeGeneratedTerrainPatchOperation &operation : operations) append_operation(writer, operation);
    if (writer.bytes().size() > NativeGeneratedTerrainPatchLimits::MAX_PAGE_RETAINED_BYTES) {
        reject(NativeGeneratedTerrainPatchFailure::page_retained_bytes_limit);
    }
    return writer.finish();
}

} // namespace

bool NativeInclusiveCellBox::operator==(const NativeInclusiveCellBox &other) const noexcept {
    return minimum == other.minimum && maximum == other.maximum;
}

bool NativeInclusiveCellBox::contains(const CellCoord cell) const noexcept {
    return cell.x >= minimum.x && cell.x <= maximum.x && cell.y >= minimum.y && cell.y <= maximum.y
        && cell.z >= minimum.z && cell.z <= maximum.z;
}

bool NativeGeneratedTerrainLight::operator==(const NativeGeneratedTerrainLight &other) const noexcept {
    return sky == other.sky && block == other.block;
}

bool NativeGeneratedTerrainCellTemplate::operator==(
    const NativeGeneratedTerrainCellTemplate &other) const noexcept {
    return material == other.material && biome == other.biome && solid == other.solid
        && density == other.density && fluid == other.fluid && light == other.light
        && block_identity == other.block_identity && metadata == other.metadata;
}

bool NativeGeneratedTerrainPatchOperation::operator==(
    const NativeGeneratedTerrainPatchOperation &other) const noexcept {
    return source_layer == other.source_layer && owner_feature_id == other.owner_feature_id
        && recipe_revision == other.recipe_revision && deterministic_order == other.deterministic_order
        && operation_ordinal == other.operation_ordinal && role == other.role && lifecycle == other.lifecycle
        && bounds == other.bounds && state == other.state;
}

NativeGeneratedTerrainPatchError::NativeGeneratedTerrainPatchError(
    const NativeGeneratedTerrainPatchFailure failure)
    : std::runtime_error("generated terrain patch rejected"), failure_(failure) {}

NativeGeneratedTerrainPatchFailure NativeGeneratedTerrainPatchError::failure() const noexcept { return failure_; }

NativeGeneratedTerrainPatchManifest::NativeGeneratedTerrainPatchManifest(
    NativeGeneratedTerrainPatchManifestDescriptor descriptor,
    std::vector<CellCoord> affected_sections,
    std::vector<std::uint8_t> canonical_binary,
    const Sha256Digest content_digest)
    : descriptor_(std::move(descriptor)), affected_sections_(std::move(affected_sections)),
      canonical_binary_(std::move(canonical_binary)), content_digest_(content_digest) {}

NativeGeneratedTerrainPatchManifest NativeGeneratedTerrainPatchManifest::admit(
    NativeGeneratedTerrainPatchManifestDescriptor descriptor) {
    if (digest_is_zero(descriptor.world_physical_identity.digest)) {
        reject(NativeGeneratedTerrainPatchFailure::invalid_source_identity);
    }
    if (descriptor.schema_revision != NativeGeneratedTerrainPatchManifestDescriptor::SCHEMA_REVISION) {
        reject(NativeGeneratedTerrainPatchFailure::invalid_schema_revision);
    }
    if (descriptor.producer_revision == 0U) reject(NativeGeneratedTerrainPatchFailure::invalid_producer_revision);
    if (descriptor.feature_source_revision == 0U) {
        reject(NativeGeneratedTerrainPatchFailure::invalid_feature_source_revision);
    }
    validate_text(descriptor.region_id);
    if (!valid_box(descriptor.complete_region_bounds)) reject(NativeGeneratedTerrainPatchFailure::invalid_region);
    if (descriptor.operations.size() > NativeGeneratedTerrainPatchLimits::MAX_MANIFEST_OPERATIONS) {
        reject(NativeGeneratedTerrainPatchFailure::operation_count_limit);
    }

    std::uint64_t aggregate_volume = 0U;
    std::size_t aggregate_utf8_bytes = descriptor.region_id.size();
    for (const NativeGeneratedTerrainPatchOperation &operation : descriptor.operations) {
        if (operation.source_layer != NativeTerrainSourceLayer::generated_feature_terrain) {
            reject(NativeGeneratedTerrainPatchFailure::invalid_source_layer);
        }
        validate_text(operation.owner_feature_id);
        if (operation.recipe_revision == 0U) reject(NativeGeneratedTerrainPatchFailure::invalid_recipe_revision);
        if (!valid_role(operation.role)) reject(NativeGeneratedTerrainPatchFailure::invalid_role);
        if (!valid_lifecycle(operation.lifecycle)) reject(NativeGeneratedTerrainPatchFailure::invalid_lifecycle);
        if (!valid_box(operation.bounds)) reject(NativeGeneratedTerrainPatchFailure::invalid_box);
        if (!contains_box(descriptor.complete_region_bounds, operation.bounds)) {
            reject(NativeGeneratedTerrainPatchFailure::invalid_region);
        }
        validate_state(operation.state);
        validate_role_state(operation);
        const std::uint64_t operation_volume = checked_box_volume(operation.bounds);
        if (operation_volume > NativeGeneratedTerrainPatchLimits::MAX_OPERATION_CELL_VOLUME) {
            reject(NativeGeneratedTerrainPatchFailure::operation_volume_limit);
        }
        if (aggregate_volume > NativeGeneratedTerrainPatchLimits::MAX_AGGREGATE_CELL_VOLUME - operation_volume) {
            reject(NativeGeneratedTerrainPatchFailure::aggregate_volume_limit);
        }
        aggregate_volume += operation_volume;
        checked_add_utf8(aggregate_utf8_bytes, operation.owner_feature_id.size());
        if (operation.state.block_identity.has_value()) {
            checked_add_utf8(aggregate_utf8_bytes, operation.state.block_identity->size());
        }
        checked_add_utf8(aggregate_utf8_bytes, utf8_bytes(operation.state.metadata));
    }

    std::vector<NativeGeneratedTerrainPatchOperation> identity_order = descriptor.operations;
    std::sort(identity_order.begin(), identity_order.end(), [](const auto &left, const auto &right) {
        if (left.owner_feature_id != right.owner_feature_id) return utf8_less(left.owner_feature_id, right.owner_feature_id);
        if (left.recipe_revision != right.recipe_revision) return left.recipe_revision < right.recipe_revision;
        return left.operation_ordinal < right.operation_ordinal;
    });
    for (std::size_t index = 1U; index < identity_order.size(); ++index) {
        const auto &previous = identity_order[index - 1U];
        const auto &current = identity_order[index];
        if (same_identity(previous, current)) {
            reject(previous == current ? NativeGeneratedTerrainPatchFailure::duplicate_operation_identity
                                       : NativeGeneratedTerrainPatchFailure::conflicting_operation_identity);
        }
    }

    std::sort(descriptor.operations.begin(), descriptor.operations.end(), operation_precedence_less);
    for (std::size_t index = 1U; index < descriptor.operations.size(); ++index) {
        if (same_precedence_key(descriptor.operations[index - 1U], descriptor.operations[index])) {
            reject(NativeGeneratedTerrainPatchFailure::ambiguous_precedence_key);
        }
    }
    std::vector<CellCoord> sections = collect_affected_sections(
        descriptor.operations, NativeGeneratedTerrainPatchFailure::affected_sections_limit);
    std::vector<std::uint8_t> canonical = manifest_binary(descriptor);
    const Sha256Digest digest = sha256(canonical);
    return NativeGeneratedTerrainPatchManifest(
        std::move(descriptor), std::move(sections), std::move(canonical), digest);
}

std::uint32_t NativeGeneratedTerrainPatchManifest::schema_revision() const noexcept { return descriptor_.schema_revision; }
const WorldPhysicalContentIdentity &NativeGeneratedTerrainPatchManifest::world_physical_identity() const noexcept {
    return descriptor_.world_physical_identity;
}
const std::string &NativeGeneratedTerrainPatchManifest::region_id() const noexcept { return descriptor_.region_id; }
const NativeInclusiveCellBox &NativeGeneratedTerrainPatchManifest::complete_region_bounds() const noexcept {
    return descriptor_.complete_region_bounds;
}
std::uint32_t NativeGeneratedTerrainPatchManifest::producer_revision() const noexcept {
    return descriptor_.producer_revision;
}
std::uint64_t NativeGeneratedTerrainPatchManifest::feature_source_revision() const noexcept {
    return descriptor_.feature_source_revision;
}
const std::vector<NativeGeneratedTerrainPatchOperation> &NativeGeneratedTerrainPatchManifest::operations() const noexcept {
    return descriptor_.operations;
}
const std::vector<CellCoord> &NativeGeneratedTerrainPatchManifest::affected_sections() const noexcept {
    return affected_sections_;
}
const std::vector<std::uint8_t> &NativeGeneratedTerrainPatchManifest::canonical_binary() const noexcept {
    return canonical_binary_;
}
const Sha256Digest &NativeGeneratedTerrainPatchManifest::content_digest() const noexcept { return content_digest_; }
std::string NativeGeneratedTerrainPatchManifest::content_digest_hex() const { return sha256_hex(content_digest_); }

NativeGeneratedTerrainPatchPageSnapshot::NativeGeneratedTerrainPatchPageSnapshot(
    NativeGeneratedTerrainPageDomain domain,
    NativeInclusiveCellBox projected_bounds,
    std::vector<NativeGeneratedTerrainPatchOperation> operations,
    std::vector<CellCoord> affected_sections,
    std::vector<std::uint8_t> canonical_binary,
    const Sha256Digest projection_digest)
    : domain_(std::move(domain)), projected_bounds_(projected_bounds), operations_(std::move(operations)),
      affected_sections_(std::move(affected_sections)), canonical_binary_(std::move(canonical_binary)),
      projection_digest_(projection_digest) {}

NativeGeneratedTerrainPatchPageSnapshot NativeGeneratedTerrainPatchPageSnapshot::project(
    const NativeGeneratedTerrainPatchManifest &manifest,
    NativeGeneratedTerrainPageDomain domain,
    std::vector<std::string> tombstoned_feature_ids) {
    validate_text(domain.page_id);
    if (!valid_box(domain.owned_bounds)) reject(NativeGeneratedTerrainPatchFailure::invalid_page_domain);
    if (domain.mesh_halo.x > NativeGeneratedTerrainPatchLimits::MAX_MESH_HALO_CELLS
        || domain.mesh_halo.y > NativeGeneratedTerrainPatchLimits::MAX_MESH_HALO_CELLS
        || domain.mesh_halo.z > NativeGeneratedTerrainPatchLimits::MAX_MESH_HALO_CELLS) {
        reject(NativeGeneratedTerrainPatchFailure::invalid_halo);
    }
    if (tombstoned_feature_ids.size() > NativeGeneratedTerrainPatchLimits::MAX_PAGE_TOMBSTONES) {
        reject(NativeGeneratedTerrainPatchFailure::invalid_tombstone);
    }
    for (const std::string &id : tombstoned_feature_ids) {
        try {
            validate_text(id);
        } catch (const NativeGeneratedTerrainPatchError &) {
            reject(NativeGeneratedTerrainPatchFailure::invalid_tombstone);
        }
    }
    std::sort(tombstoned_feature_ids.begin(), tombstoned_feature_ids.end(), utf8_less);
    if (std::adjacent_find(tombstoned_feature_ids.begin(), tombstoned_feature_ids.end())
        != tombstoned_feature_ids.end()) {
        reject(NativeGeneratedTerrainPatchFailure::invalid_tombstone);
    }
    for (const std::string &id : tombstoned_feature_ids) {
        const bool known = std::any_of(manifest.operations().begin(), manifest.operations().end(),
            [&](const NativeGeneratedTerrainPatchOperation &operation) {
                return operation.owner_feature_id == id;
            });
        if (!known) reject(NativeGeneratedTerrainPatchFailure::invalid_tombstone);
    }

    const NativeInclusiveCellBox projected_bounds = expand_box(domain.owned_bounds, domain.mesh_halo);
    std::vector<NativeGeneratedTerrainPatchOperation> projected;
    std::uint64_t projected_volume = 0U;
    for (const NativeGeneratedTerrainPatchOperation &operation : manifest.operations()) {
        if (operation.lifecycle == NativeGeneratedTerrainPatchLifecycle::follows_feature_tombstone
            && tombstoned(tombstoned_feature_ids, operation.owner_feature_id)) {
            continue;
        }
        const std::optional<NativeInclusiveCellBox> clipped = intersect_boxes(operation.bounds, projected_bounds);
        if (!clipped.has_value()) continue;
        if (projected.size() == NativeGeneratedTerrainPatchLimits::MAX_PAGE_PROJECTED_OPERATIONS) {
            reject(NativeGeneratedTerrainPatchFailure::page_operation_limit);
        }
        NativeGeneratedTerrainPatchOperation retained = operation;
        retained.bounds = *clipped;
        const std::uint64_t volume = checked_box_volume(retained.bounds);
        if (projected_volume > NativeGeneratedTerrainPatchLimits::MAX_PAGE_PROJECTED_CELL_VOLUME - volume) {
            reject(NativeGeneratedTerrainPatchFailure::page_volume_limit);
        }
        projected_volume += volume;
        projected.push_back(std::move(retained));
    }
    std::vector<CellCoord> sections = collect_affected_sections(
        projected, NativeGeneratedTerrainPatchFailure::affected_sections_limit);
    std::vector<std::uint8_t> canonical = page_binary(manifest, domain, projected_bounds, projected);
    const Sha256Digest digest = sha256(canonical);
    return NativeGeneratedTerrainPatchPageSnapshot(
        std::move(domain), projected_bounds, std::move(projected), std::move(sections), std::move(canonical), digest);
}

const NativeGeneratedTerrainPageDomain &NativeGeneratedTerrainPatchPageSnapshot::domain() const noexcept {
    return domain_;
}
const NativeInclusiveCellBox &NativeGeneratedTerrainPatchPageSnapshot::projected_bounds() const noexcept {
    return projected_bounds_;
}
const std::vector<NativeGeneratedTerrainPatchOperation> &NativeGeneratedTerrainPatchPageSnapshot::operations() const noexcept {
    return operations_;
}
const std::vector<CellCoord> &NativeGeneratedTerrainPatchPageSnapshot::affected_sections() const noexcept {
    return affected_sections_;
}
const std::vector<std::uint8_t> &NativeGeneratedTerrainPatchPageSnapshot::canonical_binary() const noexcept {
    return canonical_binary_;
}
const Sha256Digest &NativeGeneratedTerrainPatchPageSnapshot::projection_digest() const noexcept {
    return projection_digest_;
}
std::string NativeGeneratedTerrainPatchPageSnapshot::projection_digest_hex() const {
    return sha256_hex(projection_digest_);
}

std::optional<NativeResolvedGeneratedTerrainPatchCell> NativeGeneratedTerrainPatchPageSnapshot::resolve(
    const CellCoord cell) const {
    if (!projected_bounds_.contains(cell)) return std::nullopt;
    for (auto iterator = operations_.rbegin(); iterator != operations_.rend(); ++iterator) {
        if (iterator->bounds.contains(cell)) {
            return NativeResolvedGeneratedTerrainPatchCell{
                cell, iterator->owner_feature_id, iterator->recipe_revision, iterator->deterministic_order,
                iterator->operation_ordinal, iterator->role, iterator->lifecycle, iterator->state};
        }
    }
    return std::nullopt;
}

} // namespace voxel::world_backend
