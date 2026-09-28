#include "native_typed_world_state_snapshot.hpp"

#include <algorithm>
#include <utility>

namespace voxel::world_backend {
namespace {

NativeCellStateInput input_from(const NativeCellState &state) {
    NativeCellStateInput input;
    input.cell = state.cell;
    input.material = state.material;
    input.biome = state.biome;
    input.solid = state.solid;
    input.density = state.density;
    input.fluid = state.fluid;
    input.light = state.light;
    input.metadata = state.metadata;
    input.block_id = state.block_id;
    input.edit_reason = state.edit_reason;
    input.generated = state.generated;
    input.edited = state.edited;
    return input;
}

void validate_state_for_namespace(const NativeTypedWorldStateRecord &record, const NativeCellStateNamespace expected) {
    if (record.name_space != expected) throw NativeCellStateRejected();
    const NativeTypedWorldStatePersistence expected_persistence = expected == NativeCellStateNamespace::durable_terrain
        ? NativeTypedWorldStatePersistence::durable
        : NativeTypedWorldStatePersistence::transient;
    if (record.persistence != expected_persistence) throw NativeCellStateRejected();
    // Keep the durable invariant explicit at the typed persistence boundary.
    // This runs before generic cell rebuilding so a future typed importer gets
    // the same rejection for either independently malformed durable flag.
    if (expected == NativeCellStateNamespace::durable_terrain
        && (record.state.generated || !record.state.edited)) {
        throw NativeCellStateRejected();
    }
    NativeCellState rebuilt;
    try {
        rebuilt = make_native_cell_state(input_from(record.state), expected);
    } catch (const std::invalid_argument &) {
        throw NativeCellStateRejected();
    }
    // Rebuilding proves material/fluid/light/metadata validity. Equality also
    // rejects a forged section/local address and noncanonical metadata order.
    if (!(rebuilt == record.state)) throw NativeCellStateRejected();
}

bool record_less(const NativeTypedWorldStateRecord &left, const NativeTypedWorldStateRecord &right) noexcept {
    return native_cell_state_v2_save_less(left.state, right.state);
}

bool coordinate_less(const CellCoord &left, const CellCoord &right) noexcept {
    if (left.z != right.z) return left.z < right.z;
    if (left.y != right.y) return left.y < right.y;
    return left.x < right.x;
}

std::vector<NativeTypedWorldStateRecord> canonical_records(
    std::vector<NativeTypedWorldStateRecord> records, const NativeCellStateNamespace expected) {
    for (const NativeTypedWorldStateRecord &record : records) validate_state_for_namespace(record, expected);
    std::sort(records.begin(), records.end(), record_less);
    for (std::size_t index = 1; index < records.size(); ++index) {
        if (records[index - 1].state.cell == records[index].state.cell) throw NativeCellStateRejected();
    }
    return records;
}

std::optional<NativeCellState> value_at(
    const std::vector<NativeTypedWorldStateRecord> &records, const CellCoord &cell) {
    // SECTION_SIZE is a positive compile-time constant, so split_cell admits
    // every int32 coordinate. The optional belongs to the generic divisor API.
    const SectionAddress address = split_cell(cell, NativeCellState::SECTION_SIZE).value();
    struct V2CellKey {
        CellCoord section;
        CellCoord cell;
    };
    const V2CellKey key{address.section, cell};
    const auto found = std::lower_bound(records.begin(), records.end(), key,
        [](const NativeTypedWorldStateRecord &record, const V2CellKey &coordinate) {
            if (!(record.state.section == coordinate.section))
                return coordinate_less(record.state.section, coordinate.section);
            return coordinate_less(record.state.cell, coordinate.cell);
        });
    if (found == records.end() || !(found->state.cell == cell)) return std::nullopt;
    return found->state;
}

} // namespace

bool NativeTypedWorldStateRecord::operator==(const NativeTypedWorldStateRecord &other) const noexcept {
    return name_space == other.name_space && persistence == other.persistence && state == other.state;
}

NativeTypedWorldStateSnapshot::NativeTypedWorldStateSnapshot(std::vector<NativeTypedWorldStateRecord> records)
    : records_(std::move(records)) {}

NativeTypedWorldStateSnapshot NativeTypedWorldStateSnapshot::create(std::vector<NativeTypedWorldStateRecord> records) {
    return NativeTypedWorldStateSnapshot(canonical_records(std::move(records), NativeCellStateNamespace::durable_terrain));
}

const std::vector<NativeTypedWorldStateRecord> &NativeTypedWorldStateSnapshot::records() const noexcept {
    return records_;
}

bool NativeTypedWorldStateSnapshot::operator==(const NativeTypedWorldStateSnapshot &other) const noexcept {
    return records_ == other.records_;
}

NativeTypedWorldStateSnapshot NativeTypedWorldStateStore::durable_snapshot() const {
    return NativeTypedWorldStateSnapshot::create(durable_records_);
}

std::vector<NativeTypedWorldStateRecord> NativeTypedWorldStateStore::transient_overlays() const {
    return transient_overlays_;
}

std::optional<NativeCellState> NativeTypedWorldStateStore::durable_value_at(const CellCoord &cell) const {
    return value_at(durable_records_, cell);
}

std::optional<NativeCellState> NativeTypedWorldStateStore::transient_overlay_at(const CellCoord &cell) const {
    return value_at(transient_overlays_, cell);
}

void NativeTypedWorldStateStore::admit_durable_snapshot(const NativeTypedWorldStateSnapshot &snapshot) {
    // Defend against a snapshot object forged through memory corruption or a
    // future deserializer bypass: candidate construction completes first.
    std::vector<NativeTypedWorldStateRecord> candidate = canonical_records(
        snapshot.records(), NativeCellStateNamespace::durable_terrain);
    durable_records_.swap(candidate);
}

void NativeTypedWorldStateStore::admit_durable_records(std::vector<NativeTypedWorldStateRecord> records) {
    std::vector<NativeTypedWorldStateRecord> candidate = canonical_records(
        std::move(records), NativeCellStateNamespace::durable_terrain);
    durable_records_.swap(candidate);
}

void NativeTypedWorldStateStore::replace_transient_overlays(std::vector<NativeTypedWorldStateRecord> overlays) {
    std::vector<NativeTypedWorldStateRecord> candidate = canonical_records(
        std::move(overlays), NativeCellStateNamespace::scene_overlay);
    transient_overlays_.swap(candidate);
}

} // namespace voxel::world_backend
