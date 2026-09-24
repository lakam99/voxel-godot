#include "native_generated_terrain_patch.hpp"

#include "sha256.hpp"

#include <algorithm>
#include <cmath>
#include <cstring>
#include <limits>
#include <utility>

namespace voxel::world_backend {
namespace {

[[noreturn]] void reject(const NativeGeneratedTerrainPatchFailure failure) {
    throw NativeGeneratedTerrainPatchError(failure);
}

class CanonicalWriter final {
public:
    explicit CanonicalWriter(const std::size_t exact_size) : bytes_(exact_size) {}

    void append_magic(const char (&value)[5]) {
        append_raw(reinterpret_cast<const std::uint8_t *>(value), 4U);
    }

    void append_u8(const std::uint8_t value) { bytes_.at(position_++) = value; }

    void append_u32(const std::uint32_t value) {
        for (int shift = 24; shift >= 0; shift -= 8) {
            append_u8(static_cast<std::uint8_t>((value >> shift) & 0xffU));
        }
    }

    void append_i32(const std::int32_t value) { append_u32(static_cast<std::uint32_t>(value)); }

    void append_u64(const std::uint64_t value) {
        for (int shift = 56; shift >= 0; shift -= 8) {
            append_u8(static_cast<std::uint8_t>((value >> shift) & 0xffU));
        }
    }

    void append_f64(const double value) {
        std::uint64_t bits = 0U;
        static_assert(sizeof(bits) == sizeof(value), "generated patch density requires binary64");
        std::memcpy(&bits, &value, sizeof(bits));
        append_u64(bits);
    }

    void append_raw(const std::uint8_t *data, const std::size_t size) {
        for (std::size_t index = 0U; index < size; ++index) append_u8(data[index]);
    }

    void append_bytes(const std::uint8_t *data, const std::size_t size) {
        append_u32(static_cast<std::uint32_t>(size));
        append_raw(data, size);
    }

    void append_text(const std::string &value) {
        append_bytes(reinterpret_cast<const std::uint8_t *>(value.data()), value.size());
    }

    std::vector<std::uint8_t> finish() { return std::move(bytes_); }

private:
    std::vector<std::uint8_t> bytes_;
    std::size_t position_ = 0U;
};

std::size_t checked_size_add(const std::size_t left, const std::size_t right,
    const NativeGeneratedTerrainPatchFailure failure) {
    const std::size_t limit = failure == NativeGeneratedTerrainPatchFailure::canonical_bytes_limit
        ? NativeGeneratedTerrainPatchLimits::MAX_MANIFEST_CANONICAL_BYTES
        : failure == NativeGeneratedTerrainPatchFailure::utf8_bytes_limit
        ? NativeGeneratedTerrainPatchLimits::MAX_MANIFEST_UTF8_BYTES
        : failure == NativeGeneratedTerrainPatchFailure::page_retained_bytes_limit
        ? NativeGeneratedTerrainPatchLimits::MAX_PAGE_RETAINED_BYTES
        : failure == NativeGeneratedTerrainPatchFailure::manifest_peak_working_bytes_limit
        ? NativeGeneratedTerrainPatchLimits::MAX_MANIFEST_PEAK_WORKING_BYTES
        : failure == NativeGeneratedTerrainPatchFailure::page_peak_working_bytes_limit
        ? NativeGeneratedTerrainPatchLimits::MAX_PAGE_PEAK_WORKING_BYTES
        : NativeGeneratedTerrainPatchLimits::MAX_MANIFEST_RETAINED_BYTES;
    // Every accumulator is born below its selected hard cap and can only be
    // advanced through this function.  Subtraction is therefore safe and
    // rejects before either size_t overflow or a cap-breaking allocation.
    if (right > limit - left) reject(failure);
    return left + right;
}

std::size_t checked_size_multiply(const std::size_t left, const std::size_t right,
    const NativeGeneratedTerrainPatchFailure) {
    // Every caller supplies operands already bounded by an admitted operation,
    // operation-count cap, or section-working-entry cap. Their documented
    // maxima multiply below size_t on both supported 64-bit toolchains; the
    // result is then advanced through checked_size_add before allocation.
    return left * right;
}

using NativeValueMeasure = NativeValueCanonicalMetrics;

NativeValueMeasure measure_native_value(const NativeValue &value) {
    return value.canonical_metrics();
}

class CanonicalWriterNativeValueSink final : public NativeValueCanonicalSink {
public:
    explicit CanonicalWriterNativeValueSink(CanonicalWriter &writer) : writer_(writer) {}
    void append(const std::uint8_t *data, const std::size_t size) override {
        writer_.append_raw(data, size);
    }
private:
    CanonicalWriter &writer_;
};

void append_native_value(CanonicalWriter &writer, const NativeValue &value) {
    CanonicalWriterNativeValueSink sink(writer);
    value.write_canonical(sink);
}

bool digest_is_zero(const Sha256Digest &digest) noexcept {
    return std::all_of(digest.begin(), digest.end(), [](const std::uint8_t byte) { return byte == 0U; });
}

bool utf8_less(const std::string &left, const std::string &right) noexcept {
    return std::lexicographical_compare(left.begin(), left.end(), right.begin(), right.end(),
        [](const char left_byte, const char right_byte) {
            return static_cast<unsigned char>(left_byte) < static_cast<unsigned char>(right_byte);
        });
}

std::size_t compact_string_dynamic_bytes(const std::size_t size) noexcept {
    return size <= 15U ? 0U : ((size | 15U) + 1U);
}

std::string compact_string(const std::string &value) {
    std::string result(value.data(), value.size());
    result.shrink_to_fit();
    return result;
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

std::size_t section_emission_count(
    const NativeInclusiveCellBox &box, const NativeGeneratedTerrainPatchFailure peak_failure) {
    const CellCoord minimum{
        section_coordinate(box.minimum.x), section_coordinate(box.minimum.y),
        section_coordinate(box.minimum.z)};
    const CellCoord maximum{
        section_coordinate(box.maximum.x), section_coordinate(box.maximum.y),
        section_coordinate(box.maximum.z)};
    const std::size_t x = static_cast<std::size_t>(
        static_cast<std::int64_t>(maximum.x) - static_cast<std::int64_t>(minimum.x) + 1);
    const std::size_t y = static_cast<std::size_t>(
        static_cast<std::int64_t>(maximum.y) - static_cast<std::int64_t>(minimum.y) + 1);
    const std::size_t z = static_cast<std::size_t>(
        static_cast<std::int64_t>(maximum.z) - static_cast<std::int64_t>(minimum.z) + 1);
    const std::size_t xy = checked_size_multiply(x, y, peak_failure);
    const std::size_t count = checked_size_multiply(xy, z, peak_failure);
    return count;
}

template <bool EnforceLimit, typename Range, typename Bounds>
std::vector<CellCoord> collect_affected_sections(
    const Range &entries, Bounds bounds, const std::size_t emission_count,
    const NativeGeneratedTerrainPatchFailure failure) {
    if constexpr (!EnforceLimit) static_cast<void>(failure);
    std::vector<CellCoord> working;
    working.reserve(emission_count);
    for (const auto &entry : entries) {
        const NativeInclusiveCellBox &box = bounds(entry);
        const CellCoord minimum{
            section_coordinate(box.minimum.x), section_coordinate(box.minimum.y),
            section_coordinate(box.minimum.z)};
        const CellCoord maximum{
            section_coordinate(box.maximum.x), section_coordinate(box.maximum.y),
            section_coordinate(box.maximum.z)};
        for (std::int64_t z = minimum.z; z <= maximum.z; ++z) {
            for (std::int64_t y = minimum.y; y <= maximum.y; ++y) {
                for (std::int64_t x = minimum.x; x <= maximum.x; ++x) {
                    working.push_back({static_cast<std::int32_t>(x), static_cast<std::int32_t>(y),
                        static_cast<std::int32_t>(z)});
                }
            }
        }
    }
    std::sort(working.begin(), working.end(), CellCoordLess{});
    working.erase(std::unique(working.begin(), working.end()), working.end());
    if constexpr (EnforceLimit) {
        if (working.size() > NativeGeneratedTerrainPatchLimits::MAX_AFFECTED_SECTIONS) reject(failure);
    }
    std::vector<CellCoord> compact(working.begin(), working.end());
    compact.shrink_to_fit();
    return compact;
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

NativeValueMeasure validate_state(const NativeGeneratedTerrainCellTemplate &state) {
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
    NativeValueMeasure metadata_measure;
    try {
        if (state.metadata.kind() != NativeValueKind::object) {
            reject(NativeGeneratedTerrainPatchFailure::invalid_cell_state);
        }
        metadata_measure = measure_native_value(state.metadata);
    } catch (const NativeValueRejected &) {
        reject(NativeGeneratedTerrainPatchFailure::invalid_cell_state);
    }
    for (const auto &entry : state.metadata.as_object()) {
        if (reserved_metadata_key(entry.first)) {
            reject(NativeGeneratedTerrainPatchFailure::forbidden_policy_metadata);
        }
    }
    return metadata_measure;
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
    // Admission rejects mixed recipe revisions for an owner immediately
    // before this comparison, so owner + ordinal is the remaining complete
    // operation identity and avoids a redundant unreachable predicate.
    return left.owner_feature_id == right.owner_feature_id
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

std::size_t operation_canonical_size(
    const NativeGeneratedTerrainPatchOperation &operation, const NativeValueMeasure metadata_measure) {
    std::size_t size = 62U;
    size = checked_size_add(size, operation.owner_feature_id.size(),
        NativeGeneratedTerrainPatchFailure::canonical_bytes_limit);
    if (operation.state.block_identity.has_value()) {
        size = checked_size_add(size, 4U + operation.state.block_identity->size(),
            NativeGeneratedTerrainPatchFailure::canonical_bytes_limit);
    }
    return checked_size_add(size, metadata_measure.canonical_bytes,
        NativeGeneratedTerrainPatchFailure::canonical_bytes_limit);
}

std::size_t operation_logical_retained_size(
    const NativeGeneratedTerrainPatchOperation &operation, const NativeValueMeasure metadata_measure,
    const NativeGeneratedTerrainPatchFailure failure) {
    std::size_t size = sizeof(NativeGeneratedTerrainPatchOperation);
    size = checked_size_add(size, compact_string_dynamic_bytes(operation.owner_feature_id.size()), failure);
    if (operation.state.block_identity.has_value()) {
        size = checked_size_add(size,
            compact_string_dynamic_bytes(operation.state.block_identity->size()), failure);
    }
    return checked_size_add(size, metadata_measure.compact_retained_dynamic_bytes, failure);
}

NativeGeneratedTerrainPatchOperation compact_operation_copy(
    const NativeGeneratedTerrainPatchOperation &operation) {
    NativeGeneratedTerrainPatchOperation result;
    result.source_layer = operation.source_layer;
    result.owner_feature_id = compact_string(operation.owner_feature_id);
    result.recipe_revision = operation.recipe_revision;
    result.deterministic_order = operation.deterministic_order;
    result.operation_ordinal = operation.operation_ordinal;
    result.role = operation.role;
    result.lifecycle = operation.lifecycle;
    result.bounds = operation.bounds;
    result.state.material = operation.state.material;
    result.state.biome = operation.state.biome;
    result.state.solid = operation.state.solid;
    result.state.density = operation.state.density;
    result.state.fluid = operation.state.fluid;
    result.state.light = operation.state.light;
    if (operation.state.block_identity.has_value()) {
        result.state.block_identity = compact_string(*operation.state.block_identity);
    }
    result.state.metadata = operation.state.metadata.compact_copy();
    return result;
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
    const NativeValueMeasure metadata_measure = measure_native_value(state.metadata);
    writer.append_u32(static_cast<std::uint32_t>(metadata_measure.canonical_bytes));
    append_native_value(writer, state.metadata);
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

std::vector<std::uint8_t> manifest_binary(
    const NativeGeneratedTerrainPatchManifestDescriptor &descriptor, const std::size_t exact_size) {
    CanonicalWriter writer(exact_size);
    writer.append_magic("GPM1");
    writer.append_u32(descriptor.schema_revision);
    writer.append_raw(descriptor.world_physical_identity.digest.data(), descriptor.world_physical_identity.digest.size());
    writer.append_text(descriptor.region_id);
    append_box(writer, descriptor.complete_region_bounds);
    writer.append_u32(descriptor.producer_revision);
    writer.append_u64(descriptor.feature_source_revision);
    writer.append_u32(static_cast<std::uint32_t>(descriptor.operations.size()));
    for (const NativeGeneratedTerrainPatchOperation &operation : descriptor.operations) append_operation(writer, operation);
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
    return std::any_of(tombstones.begin(), tombstones.end(),
        [&](const std::string &candidate) { return candidate == id; });
}

struct ProjectedOperationReference final {
    const NativeGeneratedTerrainPatchOperation *operation = nullptr;
    NativeInclusiveCellBox clipped_bounds;
};

std::vector<std::uint8_t> page_binary(
    const NativeGeneratedTerrainPatchManifest &manifest,
    const NativeGeneratedTerrainPageDomain &domain,
    const NativeInclusiveCellBox &projected_bounds,
    const std::vector<NativeGeneratedTerrainPatchOperation> &operations,
    const std::size_t exact_size) {
    CanonicalWriter writer(exact_size);
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
    const Sha256Digest content_digest,
    const std::size_t retained_bytes,
    const std::size_t peak_working_bytes)
    : descriptor_(std::move(descriptor)), affected_sections_(std::move(affected_sections)),
      canonical_binary_(std::move(canonical_binary)), content_digest_(content_digest),
      retained_bytes_(retained_bytes), peak_working_bytes_(peak_working_bytes) {}

NativeGeneratedTerrainPatchManifest NativeGeneratedTerrainPatchManifest::admit(
    const NativeGeneratedTerrainPatchManifestDescriptor &descriptor) {
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
    std::size_t canonical_size = checked_size_add(84U, descriptor.region_id.size(),
        NativeGeneratedTerrainPatchFailure::canonical_bytes_limit);
    std::size_t retained_bytes = checked_size_add(
        sizeof(NativeGeneratedTerrainPatchManifest),
        compact_string_dynamic_bytes(descriptor.region_id.size()),
        NativeGeneratedTerrainPatchFailure::manifest_retained_bytes_limit);
    std::size_t section_emissions = 0U;
    std::size_t largest_operation_retained = 0U;
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
        const NativeValueMeasure metadata_measure = validate_state(operation.state);
        validate_role_state(operation);
        const std::uint64_t operation_volume = checked_box_volume(operation.bounds);
        if (operation_volume > NativeGeneratedTerrainPatchLimits::MAX_OPERATION_CELL_VOLUME) {
            reject(NativeGeneratedTerrainPatchFailure::operation_volume_limit);
        }
        if (aggregate_volume > NativeGeneratedTerrainPatchLimits::MAX_AGGREGATE_CELL_VOLUME - operation_volume) {
            reject(NativeGeneratedTerrainPatchFailure::aggregate_volume_limit);
        }
        aggregate_volume += operation_volume;
        aggregate_utf8_bytes = checked_size_add(aggregate_utf8_bytes, operation.owner_feature_id.size(),
            NativeGeneratedTerrainPatchFailure::utf8_bytes_limit);
        if (operation.state.block_identity.has_value()) {
            aggregate_utf8_bytes = checked_size_add(aggregate_utf8_bytes,
                operation.state.block_identity->size(), NativeGeneratedTerrainPatchFailure::utf8_bytes_limit);
        }
        aggregate_utf8_bytes = checked_size_add(aggregate_utf8_bytes, metadata_measure.utf8_bytes,
            NativeGeneratedTerrainPatchFailure::utf8_bytes_limit);
        canonical_size = checked_size_add(canonical_size,
            operation_canonical_size(operation, metadata_measure),
            NativeGeneratedTerrainPatchFailure::canonical_bytes_limit);
        const std::size_t operation_retained = operation_logical_retained_size(operation, metadata_measure,
            NativeGeneratedTerrainPatchFailure::manifest_retained_bytes_limit);
        largest_operation_retained = std::max(largest_operation_retained, operation_retained);
        retained_bytes = checked_size_add(retained_bytes, operation_retained,
            NativeGeneratedTerrainPatchFailure::manifest_retained_bytes_limit);
        const std::size_t operation_section_emissions = section_emission_count(
            operation.bounds, NativeGeneratedTerrainPatchFailure::manifest_peak_working_bytes_limit);
        if (section_emissions > NativeGeneratedTerrainPatchLimits::MAX_SECTION_WORKING_ENTRIES
            - operation_section_emissions) {
            reject(NativeGeneratedTerrainPatchFailure::manifest_peak_working_bytes_limit);
        }
        section_emissions += operation_section_emissions;
    }

    const std::size_t section_storage_bound = checked_size_multiply(
        section_emissions, sizeof(CellCoord),
        NativeGeneratedTerrainPatchFailure::manifest_retained_bytes_limit);
    retained_bytes = checked_size_add(retained_bytes, section_storage_bound,
        NativeGeneratedTerrainPatchFailure::manifest_retained_bytes_limit);
    retained_bytes = checked_size_add(retained_bytes, canonical_size,
        NativeGeneratedTerrainPatchFailure::manifest_retained_bytes_limit);
    const std::size_t index_storage = checked_size_multiply(
        descriptor.operations.size(), sizeof(std::size_t),
        NativeGeneratedTerrainPatchFailure::manifest_peak_working_bytes_limit);
    std::size_t peak_working_bytes = checked_size_add(retained_bytes, index_storage,
        NativeGeneratedTerrainPatchFailure::manifest_peak_working_bytes_limit);
    peak_working_bytes = checked_size_add(peak_working_bytes, index_storage,
        NativeGeneratedTerrainPatchFailure::manifest_peak_working_bytes_limit);
    peak_working_bytes = checked_size_add(peak_working_bytes, section_storage_bound,
        NativeGeneratedTerrainPatchFailure::manifest_peak_working_bytes_limit);
    peak_working_bytes = checked_size_add(peak_working_bytes, largest_operation_retained,
        NativeGeneratedTerrainPatchFailure::manifest_peak_working_bytes_limit);

    std::vector<std::size_t> identity_order(descriptor.operations.size());
    for (std::size_t index = 0U; index < identity_order.size(); ++index) identity_order[index] = index;
    std::sort(identity_order.begin(), identity_order.end(), [&](const std::size_t left_index, const std::size_t right_index) {
        const auto &left = descriptor.operations[left_index];
        const auto &right = descriptor.operations[right_index];
        if (left.owner_feature_id != right.owner_feature_id) return utf8_less(left.owner_feature_id, right.owner_feature_id);
        if (left.recipe_revision != right.recipe_revision) return left.recipe_revision < right.recipe_revision;
        return left.operation_ordinal < right.operation_ordinal;
    });
    for (std::size_t index = 1U; index < identity_order.size(); ++index) {
        const auto &previous = descriptor.operations[identity_order[index - 1U]];
        const auto &current = descriptor.operations[identity_order[index]];
        if (previous.owner_feature_id == current.owner_feature_id
            && previous.recipe_revision != current.recipe_revision) {
            reject(NativeGeneratedTerrainPatchFailure::mixed_owner_recipe_revision);
        }
        if (same_identity(previous, current)) {
            reject(previous == current ? NativeGeneratedTerrainPatchFailure::duplicate_operation_identity
                                       : NativeGeneratedTerrainPatchFailure::conflicting_operation_identity);
        }
    }

    std::vector<std::size_t> precedence_order(descriptor.operations.size());
    for (std::size_t index = 0U; index < precedence_order.size(); ++index) precedence_order[index] = index;
    std::sort(precedence_order.begin(), precedence_order.end(), [&](const std::size_t left, const std::size_t right) {
        return operation_precedence_less(descriptor.operations[left], descriptor.operations[right]);
    });
    // Equal precedence keys necessarily share owner and ordinal. They were
    // already rejected above as duplicate/conflicting identity or mixed-owner
    // recipe revision, so the retained canonical order is total here.
    std::vector<CellCoord> sections = collect_affected_sections<true>(
        descriptor.operations, [](const NativeGeneratedTerrainPatchOperation &operation) -> const NativeInclusiveCellBox & {
            return operation.bounds;
        }, section_emissions, NativeGeneratedTerrainPatchFailure::affected_sections_limit);

    NativeGeneratedTerrainPatchManifestDescriptor retained_descriptor;
    retained_descriptor.schema_revision = descriptor.schema_revision;
    retained_descriptor.world_physical_identity = descriptor.world_physical_identity;
    retained_descriptor.region_id = compact_string(descriptor.region_id);
    retained_descriptor.complete_region_bounds = descriptor.complete_region_bounds;
    retained_descriptor.producer_revision = descriptor.producer_revision;
    retained_descriptor.feature_source_revision = descriptor.feature_source_revision;
    retained_descriptor.operations.reserve(descriptor.operations.size());
    for (const std::size_t index : precedence_order) {
        retained_descriptor.operations.push_back(compact_operation_copy(descriptor.operations[index]));
    }
    retained_descriptor.operations.shrink_to_fit();
    std::vector<std::uint8_t> canonical = manifest_binary(retained_descriptor, canonical_size);
    const Sha256Digest digest = sha256(canonical);
    return NativeGeneratedTerrainPatchManifest(
        std::move(retained_descriptor), std::move(sections), std::move(canonical), digest,
        retained_bytes, peak_working_bytes);
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
std::size_t NativeGeneratedTerrainPatchManifest::retained_bytes() const noexcept { return retained_bytes_; }
std::size_t NativeGeneratedTerrainPatchManifest::peak_working_bytes() const noexcept { return peak_working_bytes_; }

NativeGeneratedTerrainPatchPageSnapshot::NativeGeneratedTerrainPatchPageSnapshot(
    NativeGeneratedTerrainPageDomain domain,
    NativeInclusiveCellBox projected_bounds,
    std::vector<NativeGeneratedTerrainPatchOperation> operations,
    std::vector<CellCoord> affected_sections,
    std::vector<std::uint8_t> canonical_binary,
    const Sha256Digest projection_digest,
    const std::size_t retained_bytes,
    const std::size_t peak_working_bytes)
    : domain_(std::move(domain)), projected_bounds_(projected_bounds), operations_(std::move(operations)),
      affected_sections_(std::move(affected_sections)), canonical_binary_(std::move(canonical_binary)),
      projection_digest_(projection_digest), retained_bytes_(retained_bytes),
      peak_working_bytes_(peak_working_bytes) {}

NativeGeneratedTerrainPatchPageSnapshot NativeGeneratedTerrainPatchPageSnapshot::project(
    const NativeGeneratedTerrainPatchManifest &manifest,
    const NativeGeneratedTerrainPageDomain &domain,
    const std::vector<std::string> &tombstoned_feature_ids) {
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
    for (std::size_t index = 0U; index < tombstoned_feature_ids.size(); ++index) {
        const std::string &id = tombstoned_feature_ids[index];
        try {
            validate_text(id);
        } catch (const NativeGeneratedTerrainPatchError &) {
            reject(NativeGeneratedTerrainPatchFailure::invalid_tombstone);
        }
        for (std::size_t previous = 0U; previous < index; ++previous) {
            if (tombstoned_feature_ids[previous] == id) {
                reject(NativeGeneratedTerrainPatchFailure::invalid_tombstone);
            }
        }
        const bool known = std::any_of(manifest.operations().begin(), manifest.operations().end(),
            [&](const NativeGeneratedTerrainPatchOperation &operation) {
                return operation.owner_feature_id == id;
            });
        if (!known) reject(NativeGeneratedTerrainPatchFailure::invalid_tombstone);
    }

    const NativeInclusiveCellBox projected_bounds = expand_box(domain.owned_bounds, domain.mesh_halo);
    if (!contains_box(manifest.complete_region_bounds(), projected_bounds)) {
        reject(NativeGeneratedTerrainPatchFailure::invalid_page_domain);
    }
    std::uint64_t projected_volume = 0U;
    std::size_t projected_count = 0U;
    std::size_t section_emissions = 0U;
    std::size_t largest_operation_retained = 0U;
    std::size_t canonical_size = 119U;
    canonical_size = checked_size_add(canonical_size, manifest.region_id().size(),
        NativeGeneratedTerrainPatchFailure::page_retained_bytes_limit);
    canonical_size = checked_size_add(canonical_size, domain.page_id.size(),
        NativeGeneratedTerrainPatchFailure::page_retained_bytes_limit);
    std::size_t retained_bytes = checked_size_add(
        sizeof(NativeGeneratedTerrainPatchPageSnapshot),
        compact_string_dynamic_bytes(domain.page_id.size()),
        NativeGeneratedTerrainPatchFailure::page_retained_bytes_limit);
    for (const NativeGeneratedTerrainPatchOperation &operation : manifest.operations()) {
        if (operation.lifecycle == NativeGeneratedTerrainPatchLifecycle::follows_feature_tombstone
            && tombstoned(tombstoned_feature_ids, operation.owner_feature_id)) {
            continue;
        }
        const std::optional<NativeInclusiveCellBox> clipped = intersect_boxes(operation.bounds, projected_bounds);
        if (!clipped.has_value()) continue;
        if (projected_count == NativeGeneratedTerrainPatchLimits::MAX_PAGE_PROJECTED_OPERATIONS) {
            reject(NativeGeneratedTerrainPatchFailure::page_operation_limit);
        }
        ++projected_count;
        const std::uint64_t volume = checked_box_volume(*clipped);
        if (projected_volume > NativeGeneratedTerrainPatchLimits::MAX_PAGE_PROJECTED_CELL_VOLUME - volume) {
            reject(NativeGeneratedTerrainPatchFailure::page_volume_limit);
        }
        projected_volume += volume;
        const NativeValueMeasure metadata_measure = measure_native_value(operation.state.metadata);
        canonical_size = checked_size_add(canonical_size,
            operation_canonical_size(operation, metadata_measure),
            NativeGeneratedTerrainPatchFailure::page_retained_bytes_limit);
        const std::size_t operation_retained = operation_logical_retained_size(operation, metadata_measure,
            NativeGeneratedTerrainPatchFailure::page_retained_bytes_limit);
        largest_operation_retained = std::max(largest_operation_retained, operation_retained);
        retained_bytes = checked_size_add(retained_bytes, operation_retained,
            NativeGeneratedTerrainPatchFailure::page_retained_bytes_limit);
        const std::size_t operation_section_emissions = section_emission_count(
            *clipped, NativeGeneratedTerrainPatchFailure::page_peak_working_bytes_limit);
        // This is a clipped subset of the manifest's already-admitted section
        // emissions, so it cannot exceed the manifest working-entry cap.
        section_emissions += operation_section_emissions;
    }
    const std::size_t section_storage_bound = checked_size_multiply(section_emissions, sizeof(CellCoord),
        NativeGeneratedTerrainPatchFailure::page_retained_bytes_limit);
    retained_bytes = checked_size_add(retained_bytes, section_storage_bound,
        NativeGeneratedTerrainPatchFailure::page_retained_bytes_limit);
    retained_bytes = checked_size_add(retained_bytes, canonical_size,
        NativeGeneratedTerrainPatchFailure::page_retained_bytes_limit);
    const std::size_t projected_reference_storage = checked_size_multiply(
        projected_count, sizeof(ProjectedOperationReference),
        NativeGeneratedTerrainPatchFailure::page_peak_working_bytes_limit);
    std::size_t peak_working_bytes = checked_size_add(retained_bytes, projected_reference_storage,
        NativeGeneratedTerrainPatchFailure::page_peak_working_bytes_limit);
    peak_working_bytes = checked_size_add(peak_working_bytes, section_storage_bound,
        NativeGeneratedTerrainPatchFailure::page_peak_working_bytes_limit);
    peak_working_bytes = checked_size_add(peak_working_bytes, largest_operation_retained,
        NativeGeneratedTerrainPatchFailure::page_peak_working_bytes_limit);

    std::vector<ProjectedOperationReference> projected_references;
    projected_references.reserve(projected_count);
    for (const NativeGeneratedTerrainPatchOperation &operation : manifest.operations()) {
        if (operation.lifecycle == NativeGeneratedTerrainPatchLifecycle::follows_feature_tombstone
            && tombstoned(tombstoned_feature_ids, operation.owner_feature_id)) continue;
        const std::optional<NativeInclusiveCellBox> clipped = intersect_boxes(operation.bounds, projected_bounds);
        if (clipped.has_value()) projected_references.push_back({&operation, *clipped});
    }
    // A page clips a subset of an already-admitted manifest, so it cannot
    // introduce a section not covered by the manifest's admitted section cap.
    std::vector<CellCoord> sections = collect_affected_sections<false>(
        projected_references, [](const ProjectedOperationReference &entry) -> const NativeInclusiveCellBox & {
            return entry.clipped_bounds;
        }, section_emissions, NativeGeneratedTerrainPatchFailure::affected_sections_limit);
    std::vector<NativeGeneratedTerrainPatchOperation> projected;
    projected.reserve(projected_references.size());
    for (const ProjectedOperationReference &reference : projected_references) {
        projected.push_back(compact_operation_copy(*reference.operation));
        projected.back().bounds = reference.clipped_bounds;
    }
    projected.shrink_to_fit();
    NativeGeneratedTerrainPageDomain retained_domain = domain;
    retained_domain.page_id = compact_string(domain.page_id);
    std::vector<std::uint8_t> canonical = page_binary(
        manifest, retained_domain, projected_bounds, projected, canonical_size);
    const Sha256Digest digest = sha256(canonical);
    return NativeGeneratedTerrainPatchPageSnapshot(
        std::move(retained_domain), projected_bounds, std::move(projected), std::move(sections),
        std::move(canonical), digest, retained_bytes, peak_working_bytes);
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
std::size_t NativeGeneratedTerrainPatchPageSnapshot::retained_bytes() const noexcept { return retained_bytes_; }
std::size_t NativeGeneratedTerrainPatchPageSnapshot::peak_working_bytes() const noexcept {
    return peak_working_bytes_;
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
