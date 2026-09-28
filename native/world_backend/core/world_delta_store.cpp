#include "world_delta_store.hpp"

#include <algorithm>
#include <cstring>
#include <exception>
#include <limits>
#include <set>
#include <type_traits>
#include <utility>

namespace voxel::world_backend {
namespace {

struct TypedNamespaceCellKey {
    NativeCellStateNamespace name_space;
    CellCoord cell;
};

struct TypedNamespaceCellKeyLess {
    bool operator()(const TypedNamespaceCellKey &left, const TypedNamespaceCellKey &right) const noexcept {
        if (left.cell.z != right.cell.z) return left.cell.z < right.cell.z;
        if (left.cell.y != right.cell.y) return left.cell.y < right.cell.y;
        if (left.cell.x != right.cell.x) return left.cell.x < right.cell.x;
        return static_cast<std::uint8_t>(left.name_space) < static_cast<std::uint8_t>(right.name_space);
    }
};

struct SectionKeyLess {
    bool operator()(const WorldDeltaSectionKey &left, const WorldDeltaSectionKey &right) const noexcept {
        if (left.section.z != right.section.z) return left.section.z < right.section.z;
        if (left.section.y != right.section.y) return left.section.y < right.section.y;
        return left.section.x < right.section.x;
    }
};

struct CellCoordLess {
    bool operator()(const CellCoord &left, const CellCoord &right) const noexcept {
        if (left.z != right.z) return left.z < right.z;
        if (left.y != right.y) return left.y < right.y;
        return left.x < right.x;
    }
};

struct V2CellCoordLess {
    bool operator()(const CellCoord &left, const CellCoord &right) const noexcept {
        const CellCoord left_section = split_cell(left, WorldDeltaStore::SECTION_SIZE).value().section;
        const CellCoord right_section = split_cell(right, WorldDeltaStore::SECTION_SIZE).value().section;
        const CellCoordLess less;
        if (!(left_section == right_section)) return less(left_section, right_section);
        return less(left, right);
    }
};

class CanonicalWriter {
public:
    void u8(const std::uint8_t value) { bytes_.push_back(value); }
    void u64(const std::uint64_t value) {
        for (unsigned shift = 0; shift < 64U; shift += 8U) u8(static_cast<std::uint8_t>(value >> shift));
    }
    void i32(const std::int32_t value) {
        const auto unsigned_value = static_cast<std::uint32_t>(value);
        for (unsigned shift = 0; shift < 32U; shift += 8U) u8(static_cast<std::uint8_t>(unsigned_value >> shift));
    }
    void binary64(const double value) {
        std::uint64_t bits = 0;
        static_assert(sizeof(bits) == sizeof(value));
        std::memcpy(&bits, &value, sizeof(bits));
        u64(bits);
    }
    void text(const std::string &value) {
        u64(static_cast<std::uint64_t>(value.size()));
        bytes_.insert(bytes_.end(), value.begin(), value.end());
    }
    void binary(const std::vector<std::uint8_t> &value) {
        u64(static_cast<std::uint64_t>(value.size()));
        bytes_.insert(bytes_.end(), value.begin(), value.end());
    }
    void digest(const Sha256Digest &value) {
        bytes_.insert(bytes_.end(), value.begin(), value.end());
    }
    void typed_cell_operation(const WorldTypedCellOperation &operation) {
        u8(static_cast<std::uint8_t>(operation.name_space));
        i32(operation.cell.x); i32(operation.cell.y); i32(operation.cell.z);
        u8(static_cast<std::uint8_t>(operation.kind));
        u8(operation.state.has_value() ? 1U : 0U);
        if (operation.state) native_cell_state(*operation.state);
    }
    void native_cell_state(const NativeCellState &state) {
        i32(state.cell.x); i32(state.cell.y); i32(state.cell.z);
        i32(state.section.x); i32(state.section.y); i32(state.section.z);
        i32(state.local_cell.x); i32(state.local_cell.y); i32(state.local_cell.z);
        u8(static_cast<std::uint8_t>(state.material));
        u8(static_cast<std::uint8_t>(state.biome));
        u8(state.solid ? 1U : 0U);
        binary64(state.density);
        u8(static_cast<std::uint8_t>(state.fluid));
        u8(state.light.sky); u8(state.light.block);
        // Every public mutation endpoint validates the non-generated edited
        // invariant before journaling, so its canonical form has one shape.
        u8(0U); u8(1U);
        // Metadata has its own self-describing canonical encoding.  The
        // outer length keeps the typed journal unambiguous without inventing
        // a second recursive metadata serialization here.
        binary(state.metadata.canonical_binary());
        u8(state.block_id.has_value() ? 1U : 0U);
        if (state.block_id) text(state.block_id->value());
        u8(state.edit_reason.has_value() ? 1U : 0U);
        if (state.edit_reason) text(*state.edit_reason);
    }
    void typed_record(const NativeTypedWorldStateRecord &record) {
        u8(static_cast<std::uint8_t>(record.name_space));
        u8(static_cast<std::uint8_t>(record.persistence));
        native_cell_state(record.state);
    }
    std::vector<std::uint8_t> finish() { return std::move(bytes_); }
private:
    std::vector<std::uint8_t> bytes_;
};

bool valid_namespace(const NativeCellStateNamespace value) noexcept {
    return value == NativeCellStateNamespace::durable_terrain || value == NativeCellStateNamespace::scene_overlay;
}

bool valid_kind(const WorldTypedCellOperationKind value) noexcept {
    return value == WorldTypedCellOperationKind::set || value == WorldTypedCellOperationKind::clear;
}

NativeTypedWorldStateRecord typed_record_for(const WorldTypedCellOperation &operation) {
    return {operation.name_space,
        operation.name_space == NativeCellStateNamespace::durable_terrain
            ? NativeTypedWorldStatePersistence::durable
            : NativeTypedWorldStatePersistence::transient,
        *operation.state};
}

void require_v2_durable_state(const NativeCellState &state) {
    // `terrainVolume` schema 1 writes these fields for every durable record.
    // Admitting a durable patch without them would create native state that
    // cannot be exported through the sole v2 codec, so reject it at mutation
    // admission instead of deferring the failure until autosave.
    if (!state.block_id.has_value() || !state.edit_reason.has_value()) {
        throw WorldDeltaRejected(WorldDeltaRejectReason::invalid_transaction);
    }
}

void validate_operation(const WorldTypedCellOperation &operation) {
    if (!valid_namespace(operation.name_space) || !valid_kind(operation.kind)) {
        throw WorldDeltaRejected(WorldDeltaRejectReason::invalid_transaction);
    }
    if (operation.kind == WorldTypedCellOperationKind::set) {
        if (!operation.state || !(operation.state->cell == operation.cell)) {
            throw WorldDeltaRejected(WorldDeltaRejectReason::invalid_transaction);
        }
        try {
            NativeTypedWorldStateStore validator;
            const NativeTypedWorldStateRecord record = typed_record_for(operation);
            if (operation.name_space == NativeCellStateNamespace::durable_terrain) {
                require_v2_durable_state(*operation.state);
                validator.admit_durable_records({record});
            } else {
                validator.replace_transient_overlays({record});
            }
        } catch (const std::invalid_argument &) {
            throw WorldDeltaRejected(WorldDeltaRejectReason::invalid_transaction);
        }
    } else if (operation.state) {
        throw WorldDeltaRejected(WorldDeltaRejectReason::invalid_transaction);
    }
}

std::vector<std::uint8_t> canonical_transaction(const WorldTypedCellTransaction &transaction) {
    if (transaction.transaction_id.empty() || transaction.transaction_id.find('\0') != std::string::npos
        || transaction.operations.empty()) {
        throw WorldDeltaRejected(WorldDeltaRejectReason::invalid_transaction);
    }
    std::vector<WorldTypedCellOperation> operations = transaction.operations;
    std::sort(operations.begin(), operations.end(), [](const WorldTypedCellOperation &left, const WorldTypedCellOperation &right) {
        const TypedNamespaceCellKeyLess less;
        return less({left.name_space, left.cell}, {right.name_space, right.cell});
    });
    for (std::size_t index = 0; index < operations.size(); ++index) {
        validate_operation(operations[index]);
        if (index != 0U && operations[index - 1U].name_space == operations[index].name_space
            && operations[index - 1U].cell == operations[index].cell) {
            throw WorldDeltaRejected(WorldDeltaRejectReason::invalid_transaction);
        }
    }
    CanonicalWriter writer;
    writer.u8('W'); writer.u8('T'); writer.u8('C'); writer.u8('1');
    writer.text(transaction.transaction_id);
    writer.u64(transaction.expected_revision);
    writer.u64(static_cast<std::uint64_t>(operations.size()));
    for (const WorldTypedCellOperation &operation : operations) writer.typed_cell_operation(operation);
    return writer.finish();
}

struct ValidatedTypedAdmission {
    NativeTypedWorldStateSnapshot durable_snapshot = NativeTypedWorldStateSnapshot::create({});
    std::vector<NativeTypedWorldStateRecord> transient_overlays;
};

struct ValidatedFeatureAdmission {
    NativeFeatureDeltaSnapshot snapshot = NativeFeatureDeltaSnapshot::create({}, {});
    std::vector<std::uint8_t> canonical_snapshot;
};

ValidatedTypedAdmission validate_typed_admission(const WorldTypedStateAdmission &admission) {
    if (admission.transaction_id.empty() || admission.transaction_id.find('\0') != std::string::npos) {
        throw WorldDeltaRejected(WorldDeltaRejectReason::invalid_transaction);
    }
    try {
        NativeTypedWorldStateStore validator;
        validator.admit_durable_snapshot(admission.durable_snapshot);
        // Keep the immutable snapshot alive while inspecting its records.
        // `records()` returns a reference, so ranging over it from a temporary
        // snapshot would otherwise leave a dangling range in C++17.
        const NativeTypedWorldStateSnapshot durable_snapshot = validator.durable_snapshot();
        for (const NativeTypedWorldStateRecord &record : durable_snapshot.records()) {
            require_v2_durable_state(record.state);
        }
        validator.replace_transient_overlays(admission.transient_overlays);
        return {durable_snapshot, validator.transient_overlays()};
    } catch (const NativeCellStateRejected &) {
        throw WorldDeltaRejected(WorldDeltaRejectReason::invalid_transaction);
    }
}

std::vector<std::uint8_t> canonical_typed_admission(
    const WorldTypedStateAdmission &admission, const ValidatedTypedAdmission &validated) {
    CanonicalWriter writer;
    // Different discriminator from WDTX means a transaction ID cannot be
    // replayed across the legacy delta and typed-state APIs.
    // WTY3 is intentionally distinct from WTY2: native recursive metadata,
    // optional block identity, and optional durable edit reason have a
    // different canonical record schema.
    writer.u8('W'); writer.u8('T'); writer.u8('Y'); writer.u8('3');
    writer.text(admission.transaction_id);
    writer.u64(admission.expected_revision);
    writer.u64(static_cast<std::uint64_t>(validated.durable_snapshot.records().size()));
    for (const NativeTypedWorldStateRecord &record : validated.durable_snapshot.records()) writer.typed_record(record);
    writer.u64(static_cast<std::uint64_t>(validated.transient_overlays.size()));
    for (const NativeTypedWorldStateRecord &record : validated.transient_overlays) writer.typed_record(record);
    return writer.finish();
}

ValidatedFeatureAdmission validate_feature_admission(
    const WorldFeatureDeltaAdmission &admission,
    const NativeGeneratedFeatureFootprintCatalog *const feature_footprint_catalog) {
    if (admission.transaction_id.empty() || admission.transaction_id.find('\0') != std::string::npos) {
        throw WorldDeltaRejected(WorldDeltaRejectReason::invalid_transaction);
    }
    // A tombstone changes generated geometry. FD1 contains only its stable
    // ID, so every ID must resolve through the immutable source-bound catalog
    // before this replacement can be published. This makes a missing or stale
    // catalog a fail-closed error rather than an empty invalidation receipt.
    if (!admission.snapshot.tombstones().empty()) {
        if (feature_footprint_catalog == nullptr) {
            throw WorldDeltaRejected(WorldDeltaRejectReason::invalid_transaction);
        }
        for (const NativeFeatureTombstone &tombstone : admission.snapshot.tombstones()) {
            if (feature_footprint_catalog->find(tombstone.feature_id) == nullptr) {
                throw WorldDeltaRejected(WorldDeltaRejectReason::invalid_transaction);
            }
        }
    }
    // NativeFeatureDeltaSnapshot is immutable at its public boundary; FD1
    // repeats its own feature validation before producing the journal payload.
    // There is therefore no raw, unvalidated feature value to translate here.
    return {admission.snapshot, admission.snapshot.canonical_binary()};
}

std::vector<std::uint8_t> canonical_feature_admission(
    const WorldFeatureDeltaAdmission &admission,
    const ValidatedFeatureAdmission &validated,
    const NativeGeneratedFeatureFootprintCatalog *const feature_footprint_catalog) {
    CanonicalWriter writer;
    // WFD1 is distinct from WDTX and WTY3: one transaction ID can identify
    // exactly one native world-state mutation kind.
    writer.u8('W'); writer.u8('F'); writer.u8('D'); writer.u8('1');
    writer.text(admission.transaction_id);
    writer.u64(admission.expected_revision);
    // A transaction that removes generated geometry is tied to the precise
    // source catalog that proved its invalidation footprint. This is compact
    // (two digests plus revision), unlike embedding the full derived index in
    // every journal record.
    writer.u8(feature_footprint_catalog != nullptr ? 1U : 0U);
    if (feature_footprint_catalog != nullptr) {
        writer.digest(feature_footprint_catalog->source_digest());
        writer.u64(feature_footprint_catalog->feature_source_revision());
        writer.digest(feature_footprint_catalog->content_digest());
    }
    writer.binary(validated.canonical_snapshot);
    return writer.finish();
}

std::vector<WorldTypedCellOperation> sorted_operations(const WorldTypedCellTransaction &transaction) {
    std::vector<WorldTypedCellOperation> operations = transaction.operations;
    std::sort(operations.begin(), operations.end(), [](const WorldTypedCellOperation &left, const WorldTypedCellOperation &right) {
        const TypedNamespaceCellKeyLess less;
        return less({left.name_space, left.cell}, {right.name_space, right.cell});
    });
    return operations;
}

WorldDeltaSectionKey section_key_for(const CellCoord &coordinate) {
    // SECTION_SIZE is a positive compile-time constant, so split_cell cannot
    // reject this request. The optional is only part of the generic coordinate
    // helper's public contract for caller-supplied divisors.
    return {split_cell(coordinate, WorldDeltaStore::SECTION_SIZE).value().section};
}

void add_conservative_invalidation_neighborhood(
    const WorldDeltaSectionKey &owner,
    std::set<WorldDeltaSectionKey, SectionKeyLess> &affected,
    const std::size_t max_affected_sections) {
    for (std::int32_t z_offset = -1; z_offset <= 1; ++z_offset) {
        for (std::int32_t y_offset = -1; y_offset <= 1; ++y_offset) {
            for (std::int32_t x_offset = -1; x_offset <= 1; ++x_offset) {
                affected.insert({{
                    static_cast<std::int32_t>(owner.section.x + x_offset),
                    static_cast<std::int32_t>(owner.section.y + y_offset),
                    static_cast<std::int32_t>(owner.section.z + z_offset),
                }});
                if (affected.size() > max_affected_sections) {
                    throw WorldDeltaRejected(WorldDeltaRejectReason::capacity_exceeded);
                }
            }
        }
    }
}

void add_changed_typed_cells(
    const std::vector<NativeTypedWorldStateRecord> &before,
    const std::vector<NativeTypedWorldStateRecord> &after,
    std::set<CellCoord, CellCoordLess> &changed_cells) {
    std::size_t before_index = 0;
    std::size_t after_index = 0;
    const V2CellCoordLess less;
    while (before_index < before.size() || after_index < after.size()) {
        if (before_index == before.size()) {
            changed_cells.insert(after[after_index++].state.cell);
        } else if (after_index == after.size()) {
            changed_cells.insert(before[before_index++].state.cell);
        } else if (less(before[before_index].state.cell, after[after_index].state.cell)) {
            changed_cells.insert(before[before_index++].state.cell);
        } else if (less(after[after_index].state.cell, before[before_index].state.cell)) {
            changed_cells.insert(after[after_index++].state.cell);
        } else {
            if (!(before[before_index] == after[after_index])) {
                changed_cells.insert(before[before_index].state.cell);
            }
            ++before_index;
            ++after_index;
        }
    }
}

bool utf8_byte_less(const std::string &left, const std::string &right) noexcept {
    return std::lexicographical_compare(left.begin(), left.end(), right.begin(), right.end(),
        [](const char left_byte, const char right_byte) noexcept {
            return static_cast<std::uint8_t>(static_cast<unsigned char>(left_byte))
                < static_cast<std::uint8_t>(static_cast<unsigned char>(right_byte));
        });
}

void add_changed_feature_instance_cells(
    const NativeFeatureDeltaSnapshot &before,
    const NativeFeatureDeltaSnapshot &after,
    std::set<CellCoord, CellCoordLess> &changed_cells) {
    const auto &old_instances = before.player_created_instances();
    const auto &new_instances = after.player_created_instances();
    std::size_t old_index = 0;
    std::size_t new_index = 0;
    while (old_index < old_instances.size() || new_index < new_instances.size()) {
        if (old_index == old_instances.size()) {
            changed_cells.insert(new_instances[new_index++].cell);
        } else if (new_index == new_instances.size()) {
            changed_cells.insert(old_instances[old_index++].cell);
        } else {
            const NativePlayerCreatedInstance &old_instance = old_instances[old_index];
            const NativePlayerCreatedInstance &new_instance = new_instances[new_index];
            if (utf8_byte_less(old_instance.instance_id, new_instance.instance_id)) {
                changed_cells.insert(old_instance.cell);
                ++old_index;
            } else if (utf8_byte_less(new_instance.instance_id, old_instance.instance_id)) {
                changed_cells.insert(new_instance.cell);
                ++new_index;
            } else {
                if (!(old_instance == new_instance)) {
                    changed_cells.insert(old_instance.cell);
                    changed_cells.insert(new_instance.cell);
                }
                ++old_index;
                ++new_index;
            }
        }
    }
}

void add_feature_footprint_sections(
    const NativeGeneratedFeatureFootprintEntry &entry,
    std::set<WorldDeltaSectionKey, SectionKeyLess> &affected,
    const std::size_t max_affected_sections) {
    for (const NativeFeatureFootprintRun &run : entry.runs) {
        const CellCoord first_section = section_key_for(run.first).section;
        const CellCoord last_section = section_key_for({
            run.last_x_inclusive, run.first.y, run.first.z,
        }).section;
        for (std::int64_t section_x = first_section.x; section_x <= last_section.x; ++section_x) {
            add_conservative_invalidation_neighborhood({{
                static_cast<std::int32_t>(section_x), first_section.y, first_section.z,
            }}, affected, max_affected_sections);
        }
    }
}

void add_changed_feature_tombstone_sections(
    const NativeFeatureDeltaSnapshot &before,
    const NativeFeatureDeltaSnapshot &after,
    const NativeGeneratedFeatureFootprintCatalog &feature_footprint_catalog,
    std::set<WorldDeltaSectionKey, SectionKeyLess> &affected,
    const std::size_t max_affected_sections) {
    const auto &old_tombstones = before.tombstones();
    const auto &new_tombstones = after.tombstones();
    std::size_t old_index = 0U;
    std::size_t new_index = 0U;
    while (old_index < old_tombstones.size() || new_index < new_tombstones.size()) {
        const NativeFeatureTombstone *changed = nullptr;
        if (old_index == old_tombstones.size()) {
            changed = &new_tombstones[new_index++];
        } else if (new_index == new_tombstones.size()) {
            changed = &old_tombstones[old_index++];
        } else if (utf8_byte_less(old_tombstones[old_index].feature_id, new_tombstones[new_index].feature_id)) {
            changed = &old_tombstones[old_index++];
        } else if (utf8_byte_less(new_tombstones[new_index].feature_id, old_tombstones[old_index].feature_id)) {
            changed = &new_tombstones[new_index++];
        } else {
            ++old_index;
            ++new_index;
            continue;
        }
        // Both snapshots passed feature-admission validation under this
        // immutable catalog, so lookup is an established invariant here.
        add_feature_footprint_sections(
            *feature_footprint_catalog.find(changed->feature_id), affected, max_affected_sections);
    }
}

const char *reject_message(const WorldDeltaRejectReason reason) noexcept {
    if (reason == WorldDeltaRejectReason::invalid_transaction) return "invalid world delta transaction";
    if (reason == WorldDeltaRejectReason::revision_conflict) return "world delta expected revision does not match";
    if (reason == WorldDeltaRejectReason::transaction_conflict) return "world delta transaction ID has different content";
    if (reason == WorldDeltaRejectReason::capacity_exceeded) return "world delta store capacity exceeded";
    return "unknown world delta rejection";
}

} // namespace

struct WorldDeltaSnapshotState {
    struct DurableColumnEntry {
        std::int32_t x = 0;
        std::int32_t z = 0;
        std::size_t record_index = 0;
    };
    std::uint64_t revision = 0;
    NativeTerrainVolumeV2 terrain_volume;
    std::vector<DurableColumnEntry> durable_column_index;
    std::vector<DurableColumnEntry> overlay_column_index;
    std::vector<NativeTypedWorldStateRecord> typed_transient_overlays;
    NativeFeatureDeltaSnapshot feature_delta_snapshot = NativeFeatureDeltaSnapshot::create({}, {});
    Sha256Digest content_digest{};
};

namespace {

constexpr std::uint64_t MAX_V2_JSON_INTEGER = 9007199254740992ULL;

std::vector<WorldDeltaSnapshotState::DurableColumnEntry> build_column_index(
    const std::vector<NativeTypedWorldStateRecord> &records) {
    std::vector<WorldDeltaSnapshotState::DurableColumnEntry> index;
    index.reserve(records.size());
    for (std::size_t i = 0; i < records.size(); ++i) {
        const CellCoord cell = records[i].state.cell;
        index.push_back({cell.x, cell.z, i});
    }
    std::sort(index.begin(), index.end(), [](const auto &left, const auto &right) {
        if (left.x != right.x) return left.x < right.x;
        if (left.z != right.z) return left.z < right.z;
        return left.record_index < right.record_index;
    });
    return index;
}

bool section_less(const CellCoord &left, const CellCoord &right) noexcept {
    return CellCoordLess{}(left, right);
}

const NativeTerrainVolumeV2SectionRevision *find_section_revision(
    const std::vector<NativeTerrainVolumeV2SectionRevision> &revisions, const CellCoord &section) {
    const auto found = std::lower_bound(revisions.begin(), revisions.end(), section,
        [](const NativeTerrainVolumeV2SectionRevision &entry, const CellCoord &coordinate) {
            return section_less(entry.section, coordinate);
        });
    if (found == revisions.end() || !(found->section == section)) return nullptr;
    return &*found;
}

void update_changed_terrain_sections(
    NativeTerrainVolumeV2 &terrain_volume,
    const std::set<CellCoord, CellCoordLess> &changed_durable_cells) {
    if (changed_durable_cells.empty()) return;
    if (terrain_volume.revision >= MAX_V2_JSON_INTEGER) {
        throw WorldDeltaRejected(WorldDeltaRejectReason::capacity_exceeded);
    }
    std::set<CellCoord, CellCoordLess> changed_sections;
    for (const CellCoord &cell : changed_durable_cells) changed_sections.insert(section_key_for(cell).section);
    const std::uint64_t next_revision = terrain_volume.revision + 1U;
    std::vector<NativeTerrainVolumeV2SectionRevision> next_sections;
    const std::vector<NativeTypedWorldStateRecord> &records = terrain_volume.durable_snapshot.records();
    for (std::size_t record_index = 0U; record_index < records.size();) {
        const CellCoord section = records[record_index].state.section;
        do {
            ++record_index;
        } while (record_index < records.size() && records[record_index].state.section == section);
        const NativeTerrainVolumeV2SectionRevision *previous =
            find_section_revision(terrain_volume.section_revisions, section);
        const bool changed = changed_sections.find(section) != changed_sections.end();
        // Constructor-time admission proves every old nonempty section has
        // exactly one revision. A newly written section is therefore the
        // only legal missing prior entry and receives this transaction's
        // terrain revision.
        const std::uint64_t inherited_revision = previous == nullptr ? next_revision : previous->revision;
        next_sections.push_back({section,
            changed ? next_revision : inherited_revision});
    }
    terrain_volume.revision = next_revision;
    terrain_volume.section_revisions = std::move(next_sections);
}

NativeTerrainVolumeV2 validate_terrain_volume(const NativeTerrainVolumeV2 &value) {
    try {
        // Validate the typed aggregate directly. Routing constructor-time
        // admission through NativeValue would incorrectly inherit that small
        // generic value algebra's 1,024-entry/4,096-node convenience limits
        // instead of the durable store's 65,536-record production capacity.
        return validate_native_terrain_volume_v2(value);
    } catch (const NativeTerrainVolumeV2Rejected &) {
        throw WorldDeltaRejected(WorldDeltaRejectReason::invalid_transaction);
    }
}

NativeFeatureDeltaSnapshot validate_initial_features(
    const NativeFeatureDeltaSnapshot &value,
    const NativeGeneratedFeatureFootprintCatalog *const feature_footprint_catalog) {
    WorldFeatureDeltaAdmission admission;
    admission.transaction_id = "initial-feature-validation";
    admission.snapshot = value;
    return validate_feature_admission(admission, feature_footprint_catalog).snapshot;
}

std::vector<NativeTypedWorldStateRecord> validate_initial_overlays(
    const std::vector<NativeTypedWorldStateRecord> &value) {
    try {
        NativeTypedWorldStateStore validator;
        validator.replace_transient_overlays(value);
        return validator.transient_overlays();
    } catch (const NativeCellStateRejected &) {
        throw WorldDeltaRejected(WorldDeltaRejectReason::invalid_transaction);
    }
}

Sha256Digest content_digest(const WorldDeltaSnapshotState &state) {
    CanonicalWriter writer;
    writer.u8('W'); writer.u8('D'); writer.u8('S'); writer.u8('1');
    writer.u64(state.terrain_volume.revision);
    writer.u64(static_cast<std::uint64_t>(state.terrain_volume.durable_snapshot.records().size()));
    for (const NativeTypedWorldStateRecord &record : state.terrain_volume.durable_snapshot.records()) writer.typed_record(record);
    writer.u64(static_cast<std::uint64_t>(state.terrain_volume.section_revisions.size()));
    for (const NativeTerrainVolumeV2SectionRevision &section : state.terrain_volume.section_revisions) {
        writer.i32(section.section.x); writer.i32(section.section.y); writer.i32(section.section.z); writer.u64(section.revision);
    }
    writer.u64(static_cast<std::uint64_t>(state.typed_transient_overlays.size()));
    for (const NativeTypedWorldStateRecord &record : state.typed_transient_overlays) writer.typed_record(record);
    writer.binary(state.feature_delta_snapshot.canonical_binary());
    return sha256(writer.finish());
}

void seal_content_digest(WorldDeltaSnapshotState &state) {
    state.content_digest = content_digest(state);
}

bool fits_record_capacity(const WorldDeltaSnapshotState &state, const WorldDeltaStoreLimits &limits) noexcept {
    return world_delta_store_fits_capacity({
        state.terrain_volume.durable_snapshot.records().size(),
        state.typed_transient_overlays.size(),
        state.feature_delta_snapshot.tombstones().size(),
        state.feature_delta_snapshot.player_created_instances().size(),
    }, limits);
}

bool valid_capacity_limits(const WorldDeltaStoreLimits &limits) noexcept {
    if (limits.max_persisted_records == 0U
        || limits.max_resident_records == 0U
        || limits.max_affected_sections == 0U
        || limits.max_transactions == 0U) {
        return false;
    }
    // Every per-domain capacity must remain independently expressible. A
    // configured total may constrain coexistence, but it cannot make an
    // advertised individual domain impossible even when all siblings are
    // empty.
    if (limits.max_durable_terrain_records > limits.max_persisted_records
        || limits.max_feature_tombstones > limits.max_persisted_records
        || limits.max_player_created_instances > limits.max_persisted_records) {
        return false;
    }
    return limits.max_persisted_records <= limits.max_resident_records
        && limits.max_scene_overlay_records <= limits.max_resident_records;
}

std::optional<NativeCellState> typed_value_at(
    const std::vector<NativeTypedWorldStateRecord> &records, const CellCoord &cell) {
    const auto found = std::lower_bound(records.begin(), records.end(), cell,
        [](const NativeTypedWorldStateRecord &record, const CellCoord &coordinate) {
            return V2CellCoordLess{}(record.state.cell, coordinate);
        });
    if (found == records.end() || !(found->state.cell == cell)) return std::nullopt;
    return found->state;
}

bool cell_inside_horizontal_bounds(
    const CellCoord &cell, const WorldDeltaHorizontalBounds bounds) noexcept {
    const std::int64_t end_x = static_cast<std::int64_t>(bounds.x) + bounds.width;
    const std::int64_t end_z = static_cast<std::int64_t>(bounds.z) + bounds.depth;
    return static_cast<std::int64_t>(cell.x) >= bounds.x
        && static_cast<std::int64_t>(cell.x) < end_x
        && static_cast<std::int64_t>(cell.z) >= bounds.z
        && static_cast<std::int64_t>(cell.z) < end_z;
}

void write_projected_records(
    CanonicalWriter &writer,
    const std::vector<NativeTypedWorldStateRecord> &records,
    const WorldDeltaHorizontalBounds bounds) {
    const std::size_t count = static_cast<std::size_t>(std::count_if(
        records.begin(), records.end(), [bounds](const NativeTypedWorldStateRecord &record) {
            return cell_inside_horizontal_bounds(record.state.cell, bounds);
        }));
    writer.u64(static_cast<std::uint64_t>(count));
    for (const NativeTypedWorldStateRecord &record : records) {
        if (cell_inside_horizontal_bounds(record.state.cell, bounds)) writer.typed_record(record);
    }
}

} // namespace

struct WorldDeltaStore::TransactionRecord {
    std::string transaction_id;
    std::vector<std::uint8_t> canonical;
    WorldDeltaCommitReceipt receipt;
};

WorldSourceMutationFence::ReadGuard::ReadGuard(WorldSourceMutationFence &fence)
    : fence_(fence) {
    if (!fence_.on_owner_thread() || fence_.read_active_ || fence_.revoked_ || fence_.exhausted())
        throw std::logic_error("borrowed world source reader is unavailable");
    fence_.read_active_ = true;
}

std::uint8_t projection_le32(const std::int32_t value, const std::size_t byte) noexcept {
    return static_cast<std::uint8_t>(static_cast<std::uint32_t>(value) >> (8U * byte));
}
std::uint8_t projection_le64(const std::uint64_t value, const std::size_t byte) noexcept {
    return static_cast<std::uint8_t>(value >> (8U * byte));
}
std::uint8_t projection_fixed_record_byte(
    const NativeTypedWorldStateRecord &record, const std::size_t offset) noexcept {
    if (offset == 0U) return static_cast<std::uint8_t>(record.name_space);
    if (offset == 1U) return static_cast<std::uint8_t>(record.persistence);
    const NativeCellState &state = record.state;
    if (offset < 38U) {
        std::int32_t coordinate = 0;
        switch ((offset - 2U) / 4U) {
        case 0U: coordinate = state.cell.x; break;
        case 1U: coordinate = state.cell.y; break;
        case 2U: coordinate = state.cell.z; break;
        case 3U: coordinate = state.section.x; break;
        case 4U: coordinate = state.section.y; break;
        case 5U: coordinate = state.section.z; break;
        case 6U: coordinate = state.local_cell.x; break;
        case 7U: coordinate = state.local_cell.y; break;
        case 8U: coordinate = state.local_cell.z; break;
        default: break;
        }
        return projection_le32(coordinate, (offset - 2U) % 4U);
    }
    if (offset == 38U) return static_cast<std::uint8_t>(state.material);
    if (offset == 39U) return static_cast<std::uint8_t>(state.biome);
    if (offset == 40U) return state.solid ? 1U : 0U;
    if (offset < 49U) {
        std::uint64_t bits = 0;
        static_assert(sizeof(bits) == sizeof(state.density));
        std::memcpy(&bits, &state.density, sizeof(bits));
        return projection_le64(bits, offset - 41U);
    }
    if (offset == 49U) return static_cast<std::uint8_t>(state.fluid);
    if (offset == 50U) return state.light.sky;
    if (offset == 51U) return state.light.block;
    return offset == 52U ? 0U : 1U;
}

WorldSourceMutationFence::ReadGuard::~ReadGuard() {
    fence_.read_active_ = false;
}

void WorldSourceMutationFence::require_writer_entry() const {
    if (!on_owner_thread() || read_active_ || revoked_ || exhausted())
        throw std::logic_error("borrowed world source writer is unavailable");
}

void WorldSourceMutationFence::published() noexcept {
    // require_writer_entry is the nonwrapping preflight before a writer does
    // any validation, allocation, journaling, or state publication.
    if (!on_owner_thread()) std::terminate();
    ++epoch_;
}

void WorldSourceMutationFence::revoke() noexcept {
    if (!on_owner_thread()) std::terminate();
    revoked_ = true;
}

void WorldSourceMutationFence::reset_after_owner_drain() {
    if (!on_owner_thread() || read_active_)
        throw std::logic_error("borrowed world source owner is unavailable");
    revoked_ = false;
    epoch_ = 1U;
}

std::uint64_t WorldSourceMutationFence::epoch() const noexcept {
    return on_owner_thread() ? epoch_ : 0U;
}
bool WorldSourceMutationFence::read_active() const noexcept {
    return !on_owner_thread() || read_active_;
}
bool WorldSourceMutationFence::writer_available() const noexcept {
    // Check thread identity before reading the owner-thread-only flags.
    return on_owner_thread() && !read_active_ && !revoked_ && !exhausted();
}
bool WorldSourceMutationFence::exhausted() const noexcept {
    return !on_owner_thread() || epoch_ == std::numeric_limits<std::uint64_t>::max();
}
bool WorldSourceMutationFence::on_owner_thread() const noexcept {
    return owner_thread_ == std::this_thread::get_id();
}

static_assert(std::is_nothrow_move_assignable_v<std::shared_ptr<const WorldDeltaSnapshotState>>);

void BorrowedTypedProjectionCursor::reset(const WorldDeltaHorizontalBounds bounds) noexcept {
    bounds_ = bounds;
    hash_.reset(); metadata_.reset();
    scan_index_ = 0U; bound_layer_sizes_ = {};
    durable_count_ = 0U; overlay_count_ = 0U;
    selection_low_ = 0U; selection_high_ = 0U; selection_index_ = 0U;
    selected_count_ = 0U; selected_min_word_ = SELECTOR_WORDS;
    selected_max_word_ = 0U; emit_word_ = 0U;
    selection_x_ = 0; active_x_ = 0; selection_stage_ = 0U;
    record_selected_ = false;
    metadata_bytes_ = 0U; metadata_emitted_ = 0U; source_token_ = 0U;
    metadata_next_atomic_ = 1U;
    source_revision_ = 0U; source_content_ = {}; byte_offset_ = 0U;
    phase_ = Phase::count_durable; record_phase_ = RecordPhase::start;
    status_ = Status::idle;
}
BorrowedTypedProjectionCursor::Status BorrowedTypedProjectionCursor::status() const noexcept { return status_; }
Sha256Digest BorrowedTypedProjectionCursor::digest() const {
    if (status_ != Status::ready) throw std::logic_error("borrowed typed projection is incomplete");
    return hash_.digest();
}

bool WorldDeltaSectionKey::operator==(const WorldDeltaSectionKey &other) const noexcept {
    return section == other.section;
}

bool WorldDeltaCommitReceipt::operator==(const WorldDeltaCommitReceipt &other) const noexcept {
    return status == other.status && transaction_id == other.transaction_id && revision == other.revision
        && affected_sections == other.affected_sections;
}

WorldDeltaRejected::WorldDeltaRejected(const WorldDeltaRejectReason reason)
    : std::runtime_error(reject_message(reason)), reason_(reason) {}

WorldDeltaRejectReason WorldDeltaRejected::reason() const noexcept { return reason_; }

bool world_delta_store_fits_capacity(
    const WorldDeltaStoreCapacityUsage &usage,
    const WorldDeltaStoreLimits &limits) noexcept {
    if (!valid_capacity_limits(limits)) return false;
    if (usage.durable_terrain_records > limits.max_durable_terrain_records
        || usage.scene_overlay_records > limits.max_scene_overlay_records
        || usage.feature_tombstones > limits.max_feature_tombstones
        || usage.player_created_instances > limits.max_player_created_instances) {
        return false;
    }

    // Validate the persisted total without ever forming an unchecked sum.
    std::size_t persisted_remaining = limits.max_persisted_records
        - usage.durable_terrain_records;
    if (usage.feature_tombstones > persisted_remaining) return false;
    persisted_remaining -= usage.feature_tombstones;
    if (usage.player_created_instances > persisted_remaining) return false;
    persisted_remaining -= usage.player_created_instances;

    const std::size_t persisted_used = limits.max_persisted_records - persisted_remaining;
    return usage.scene_overlay_records <= limits.max_resident_records - persisted_used;
}

WorldDeltaPinnedSnapshot::WorldDeltaPinnedSnapshot(std::shared_ptr<const WorldDeltaSnapshotState> state)
    : state_(std::move(state)) {}

std::uint64_t WorldDeltaPinnedSnapshot::revision() const noexcept { return state_->revision; }

const NativeTerrainVolumeV2 &WorldDeltaPinnedSnapshot::terrain_volume() const noexcept {
    return state_->terrain_volume;
}

const NativeTypedWorldStateSnapshot &WorldDeltaPinnedSnapshot::durable_terrain_snapshot() const noexcept {
    return state_->terrain_volume.durable_snapshot;
}

const std::vector<NativeTypedWorldStateRecord> &WorldDeltaPinnedSnapshot::scene_overlays() const noexcept {
    return state_->typed_transient_overlays;
}

std::optional<NativeCellState> WorldDeltaPinnedSnapshot::durable_terrain_at(const CellCoord &cell) const {
    return typed_value_at(state_->terrain_volume.durable_snapshot.records(), cell);
}

bool WorldDeltaPinnedSnapshot::durable_terrain_column_any(
    const std::int32_t x, const std::int32_t z,
    const std::function<bool(const NativeCellState &)> &predicate) const {
    const auto &index = state_->durable_column_index;
    const auto found = std::lower_bound(index.begin(), index.end(), std::pair{x, z},
        [](const WorldDeltaSnapshotState::DurableColumnEntry &entry, const auto &column) {
            return entry.x < column.first || (entry.x == column.first && entry.z < column.second);
        });
    const auto &records = state_->terrain_volume.durable_snapshot.records();
    for (auto it = found; it != index.end() && it->x == x && it->z == z; ++it) {
        if (predicate(records[it->record_index].state)) return true;
    }
    return false;
}

bool WorldDeltaPinnedSnapshot::effective_typed_column_any(
    const std::int32_t x, const std::int32_t z,
    const std::function<bool(const NativeCellState &)> &predicate) const {
    const auto first_in_column = [x, z](const auto &index) {
        return std::lower_bound(index.begin(), index.end(), std::pair{x, z},
            [](const WorldDeltaSnapshotState::DurableColumnEntry &entry, const auto &column) {
                return entry.x < column.first || (entry.x == column.first && entry.z < column.second);
            });
    };
    const auto &durable = state_->terrain_volume.durable_snapshot.records();
    const auto &overlays = state_->typed_transient_overlays;
    const auto &durable_index = state_->durable_column_index;
    const auto &overlay_index = state_->overlay_column_index;
    for (auto it = first_in_column(durable_index);
         it != durable_index.end() && it->x == x && it->z == z; ++it) {
        const NativeCellState &state = durable[it->record_index].state;
        const auto overlay = scene_overlay_at(state.cell);
        if (predicate(overlay ? *overlay : state)) return true;
    }
    for (auto it = first_in_column(overlay_index);
         it != overlay_index.end() && it->x == x && it->z == z; ++it) {
        const NativeCellState &state = overlays[it->record_index].state;
        if (!durable_terrain_at(state.cell) && predicate(state)) return true;
    }
    return false;
}

std::optional<NativeCellState> WorldDeltaPinnedSnapshot::scene_overlay_at(const CellCoord &cell) const {
    return typed_value_at(state_->typed_transient_overlays, cell);
}

std::optional<NativeCellState> WorldDeltaPinnedSnapshot::effective_typed_cell_at(const CellCoord &cell) const {
    if (const auto overlay = scene_overlay_at(cell)) return overlay;
    return durable_terrain_at(cell);
}

const NativeFeatureDeltaSnapshot &WorldDeltaPinnedSnapshot::feature_delta_snapshot() const noexcept {
    return state_->feature_delta_snapshot;
}

const Sha256Digest &WorldDeltaPinnedSnapshot::content_digest() const noexcept {
    return state_->content_digest;
}

Sha256Digest WorldDeltaPinnedSnapshot::typed_projection_digest(
    const WorldDeltaHorizontalBounds bounds) const {
    if (bounds.width <= 0 || bounds.depth <= 0
        || static_cast<std::int64_t>(bounds.x) + bounds.width > std::numeric_limits<std::int32_t>::max()
        || static_cast<std::int64_t>(bounds.z) + bounds.depth > std::numeric_limits<std::int32_t>::max()) {
        throw std::invalid_argument("world delta projection bounds are invalid");
    }
    CanonicalWriter writer;
    writer.u8('W'); writer.u8('D'); writer.u8('P'); writer.u8('1');
    writer.i32(bounds.x); writer.i32(bounds.z); writer.i32(bounds.width); writer.i32(bounds.depth);
    write_projected_records(writer, state_->terrain_volume.durable_snapshot.records(), bounds);
    write_projected_records(writer, state_->typed_transient_overlays, bounds);
    return sha256(writer.finish());
}

WorldDeltaStore::WorldDeltaStore(
    const WorldDeltaStoreLimits limits,
    WorldDeltaInitialSnapshot initial,
    std::shared_ptr<const NativeGeneratedFeatureFootprintCatalog> feature_footprint_catalog)
    : limits_(limits), feature_footprint_catalog_(std::move(feature_footprint_catalog)) {
    if (!valid_capacity_limits(limits_)) {
        throw WorldDeltaRejected(WorldDeltaRejectReason::invalid_transaction);
    }
    // Reserve once so a later journal append cannot allocate after a candidate
    // state exists. Constructor failure leaves no observable store.
    transactions_.reserve(limits_.max_transactions);
    auto state = std::make_shared<WorldDeltaSnapshotState>();
    if (initial.revision != 0U && limits_.initial_revision != 0U && initial.revision != limits_.initial_revision) {
        throw WorldDeltaRejected(WorldDeltaRejectReason::invalid_transaction);
    }
    state->revision = initial.revision != 0U ? initial.revision : limits_.initial_revision;
    state->terrain_volume = validate_terrain_volume(initial.terrain_volume);
    state->durable_column_index = build_column_index(state->terrain_volume.durable_snapshot.records());
    state->typed_transient_overlays = validate_initial_overlays(initial.transient_overlays);
    state->overlay_column_index = build_column_index(state->typed_transient_overlays);
    state->feature_delta_snapshot = validate_initial_features(
        initial.feature_delta_snapshot, feature_footprint_catalog_.get());
    if (!fits_record_capacity(*state, limits_)) throw WorldDeltaRejected(WorldDeltaRejectReason::capacity_exceeded);
    seal_content_digest(*state);
    state_ = std::move(state);
}

WorldDeltaStore::~WorldDeltaStore() = default;

std::uint64_t WorldDeltaStore::revision() const noexcept { return state_->revision; }
const Sha256Digest &WorldDeltaStore::current_content_digest() const noexcept {
    return state_->content_digest;
}

void BorrowedTypedCellCursor::reset() noexcept { *this = BorrowedTypedCellCursor{}; }
BorrowedTypedCellCursor::Status BorrowedTypedCellCursor::status() const noexcept { return status_; }

BorrowedTypedCellCursor::Step WorldDeltaStore::advance_borrowed_typed_cell(
    BorrowedTypedCellCursor &cursor, const CellCoord cell,
    const std::uint64_t source_token, const std::uint32_t offered_ops) const noexcept {
    using Cursor = BorrowedTypedCellCursor;
    Cursor::Step result; result.status = cursor.status_;
    const std::uint32_t limit = std::min(offered_ops, 64U);
    // Zero work is observational: it never reads mutable source state or
    // binds an issue and cannot make an unrelated later request stale.
    if (limit == 0U) return result;
    if (cursor.status_ == Cursor::Status::source_changed || cursor.status_ == Cursor::Status::failed)
        return result;
    if (source_mutation_fence_ && (!source_mutation_fence_->on_owner_thread()
        || !source_mutation_fence_->read_active())) {
        cursor.status_ = Cursor::Status::failed;
        result.status = cursor.status_; return result;
    }
    if (source_token == 0U) {
        cursor.status_ = Cursor::Status::failed;
        result.status = cursor.status_; return result;
    }
    if (cursor.status_ != Cursor::Status::idle
        && (cursor.source_token_ != source_token || !(cursor.cell_ == cell)
            || cursor.source_revision_ != state_->revision
            || cursor.source_content_ != state_->content_digest)) {
        cursor.status_ = Cursor::Status::source_changed;
        result.status = cursor.status_; return result;
    }
    if (cursor.status_ == Cursor::Status::ready_present
        || cursor.status_ == Cursor::Status::ready_absent) return result;
    if (cursor.status_ == Cursor::Status::idle) {
        const auto split = split_cell(cell, SECTION_SIZE);
        if (!split) {
            cursor.status_ = Cursor::Status::failed;
            result.status = cursor.status_; return result;
        }
        cursor.cell_ = cell;
        cursor.section_ = split->section;
        cursor.source_token_ = source_token;
        cursor.source_revision_ = state_->revision;
        cursor.source_content_ = state_->content_digest;
        cursor.low_ = 0U;
        cursor.high_ = state_->typed_transient_overlays.size();
        cursor.layer_ = Cursor::Layer::overlay;
        cursor.status_ = Cursor::Status::pending;
        result.consumed_ops = 1U;
    }
    const CellCoordLess less;
    while (result.consumed_ops < limit && cursor.status_ == Cursor::Status::pending) {
        const auto &records = cursor.layer_ == Cursor::Layer::overlay
            ? state_->typed_transient_overlays : state_->terrain_volume.durable_snapshot.records();
        if (cursor.low_ == cursor.high_) {
            if (cursor.layer_ == Cursor::Layer::overlay) {
                cursor.layer_ = Cursor::Layer::durable;
                cursor.low_ = 0U;
                cursor.high_ = state_->terrain_volume.durable_snapshot.records().size();
            } else {
                cursor.status_ = Cursor::Status::ready_absent;
            }
            ++result.consumed_ops;
            continue;
        }
        const std::size_t middle = cursor.low_ + (cursor.high_ - cursor.low_) / 2U;
        const NativeCellState &candidate = records[middle].state;
        // Records are already sorted by (section z,y,x; cell z,y,x).
        // One comparison is one charged atom; no vector copy or search helper.
        if (less(candidate.section, cursor.section_)
            || (candidate.section == cursor.section_ && less(candidate.cell, cell))) {
            cursor.low_ = middle + 1U;
        } else {
            cursor.high_ = middle;
        }
        ++result.consumed_ops;
        if (cursor.low_ == cursor.high_ && cursor.low_ < records.size()
            && records[cursor.low_].state.cell == cell) {
            cursor.found_index_ = cursor.low_;
            cursor.status_ = Cursor::Status::ready_present;
        }
    }
    result.status = cursor.status_;
    return result;
}

std::optional<BorrowedTypedCellHeader> WorldDeltaStore::borrowed_typed_cell_header(
    const BorrowedTypedCellCursor &cursor, const std::uint64_t source_token) const noexcept {
    using Cursor = BorrowedTypedCellCursor;
    if (cursor.status_ != Cursor::Status::ready_present || source_token == 0U
        || cursor.source_token_ != source_token
        || (source_mutation_fence_ && (!source_mutation_fence_->on_owner_thread()
            || !source_mutation_fence_->read_active()))
        || cursor.source_revision_ != state_->revision
        || cursor.source_content_ != state_->content_digest) return std::nullopt;
    const auto &records = cursor.layer_ == Cursor::Layer::overlay
        ? state_->typed_transient_overlays : state_->terrain_volume.durable_snapshot.records();
    if (cursor.found_index_ >= records.size()) return std::nullopt;
    const NativeCellState &state = records[cursor.found_index_].state;
    if (!(state.cell == cursor.cell_)) return std::nullopt;
    BorrowedTypedCellHeader result;
    result.cell = state.cell;
    result.section = state.section;
    result.local_cell = state.local_cell;
    result.source_layer = cursor.layer_ == Cursor::Layer::overlay
        ? BorrowedTypedCellHeader::SourceLayer::overlay
        : BorrowedTypedCellHeader::SourceLayer::durable;
    result.material = state.material;
    result.biome = state.biome;
    result.solid = state.solid;
    result.density = state.density;
    result.fluid = state.fluid;
    result.light = state.light;
    result.generated = state.generated;
    result.edited = state.edited;
    result.has_block_id = state.block_id.has_value();
    result.has_edit_reason = state.edit_reason.has_value();
    return result;
}

BorrowedTypedProjectionCursor::Step WorldDeltaStore::advance_borrowed_projection_one(
    BorrowedTypedProjectionCursor &cursor, const WorldDeltaHorizontalBounds bounds,
    const std::uint64_t source_token, const std::uint32_t offered_ops) const noexcept {
    using Cursor = BorrowedTypedProjectionCursor;
    Cursor::Step result; result.status = cursor.status_;
    const std::uint32_t limit = std::min(offered_ops, 64U);
    if (limit == 0U) return result;
    if (cursor.status_ == Cursor::Status::failed || cursor.status_ == Cursor::Status::source_changed)
        return result;
    if (source_token == 0U) {
        cursor.status_ = Cursor::Status::failed; result.status = cursor.status_; return result;
    }
    if (cursor.status_ != Cursor::Status::idle && cursor.source_token_ != source_token) {
        cursor.status_ = Cursor::Status::source_changed;
        result.status = cursor.status_; return result;
    }
    if (source_mutation_fence_ && (!source_mutation_fence_->on_owner_thread()
        || !source_mutation_fence_->read_active())) {
        cursor.status_ = Cursor::Status::failed; result.status = cursor.status_; return result;
    }
    if (cursor.status_ != Cursor::Status::idle
        && (cursor.source_revision_ != state_->revision
            || cursor.source_content_ != state_->content_digest)) {
        cursor.status_ = Cursor::Status::source_changed;
        result.status = cursor.status_; return result;
    }
    if (cursor.status_ == Cursor::Status::ready) return result;
    if (bounds.width <= 0 || bounds.depth <= 0
        || static_cast<std::int64_t>(bounds.x) + bounds.width > std::numeric_limits<std::int32_t>::max()
        || static_cast<std::int64_t>(bounds.z) + bounds.depth > std::numeric_limits<std::int32_t>::max()
        || (cursor.status_ != Cursor::Status::idle
            && (cursor.bounds_.x != bounds.x || cursor.bounds_.z != bounds.z
                || cursor.bounds_.width != bounds.width || cursor.bounds_.depth != bounds.depth))) {
        cursor.status_ = Cursor::Status::failed; result.status = cursor.status_; return result;
    }
    if (cursor.status_ == Cursor::Status::idle) {
        cursor.reset(bounds);
        cursor.source_token_ = source_token;
        cursor.source_revision_ = state_->revision;
        cursor.source_content_ = state_->content_digest;
        cursor.bound_layer_sizes_ = {
            state_->terrain_volume.durable_snapshot.records().size(),
            state_->typed_transient_overlays.size()};
        cursor.status_ = Cursor::Status::pending;
        result.status = cursor.status_; result.consumed_ops = 1U;
        return result;
    }
    const auto &durable = state_->terrain_volume.durable_snapshot.records();
    const auto &overlay = state_->typed_transient_overlays;
    constexpr std::size_t selector_capacity = BorrowedTypedProjectionCursor::SELECTOR_WORDS * 64U;
    const bool selected_durable = durable.size() <= selector_capacity;
    const bool selected_overlay = overlay.size() <= selector_capacity;
    const auto select_step = [&](const std::size_t layer) {
        const auto &entries = layer == 0U ? state_->durable_column_index : state_->overlay_column_index;
        auto &selection = cursor;
        const std::int64_t x_end = static_cast<std::int64_t>(bounds.x) + bounds.width;
        const std::int64_t z_end = static_cast<std::int64_t>(bounds.z) + bounds.depth;
        switch (selection.selection_stage_) {
        case 0U:
            if (selection.selection_generation_ == std::numeric_limits<std::uint64_t>::max())
                throw std::overflow_error("borrowed projection selector generation exhausted");
            ++selection.selection_generation_;
            selection.selection_x_ = bounds.x;
            selection.selection_low_ = 0U;
            selection.selection_high_ = entries.size();
            selection.selected_count_ = 0U;
            selection.selected_min_word_ = BorrowedTypedProjectionCursor::SELECTOR_WORDS;
            selection.selected_max_word_ = 0U;
            selection.emit_word_ = 0U;
            selection.record_selected_ = false;
            selection.selection_stage_ = 1U;
            break;
        case 1U: // charged binary search for (next x, first z in bounds)
            if (selection.selection_low_ < selection.selection_high_) {
                const std::size_t mid = selection.selection_low_
                    + (selection.selection_high_ - selection.selection_low_) / 2U;
                const auto &entry = entries[mid];
                if (entry.x < selection.selection_x_
                    || (entry.x == selection.selection_x_ && entry.z < bounds.z))
                    selection.selection_low_ = mid + 1U;
                else selection.selection_high_ = mid;
            } else {
                selection.selection_index_ = selection.selection_low_;
                if (selection.selection_index_ == entries.size()
                    || static_cast<std::int64_t>(entries[selection.selection_index_].x) >= x_end)
                    selection.selection_stage_ = 3U;
                else {
                    selection.active_x_ = entries[selection.selection_index_].x;
                    selection.selection_stage_ = 2U;
                }
            }
            break;
        case 2U: {
            const bool at_end = selection.selection_index_ == entries.size();
            if (at_end || entries[selection.selection_index_].x != selection.active_x_
                || static_cast<std::int64_t>(entries[selection.selection_index_].z) >= z_end) {
                selection.selection_x_ = selection.active_x_ + 1;
                selection.selection_low_ = selection.selection_index_;
                selection.selection_high_ = entries.size();
                selection.selection_stage_ = 1U;
                break;
            }
            const std::size_t record = entries[selection.selection_index_++].record_index;
            if (record >= selector_capacity)
                throw std::logic_error("borrowed projection candidate outside selector capacity");
            const std::size_t word = record / 64U;
            if (selection.selected_generations_[word] != selection.selection_generation_) {
                selection.selected_generations_[word] = selection.selection_generation_;
                selection.selected_words_[word] = 0U;
            }
            const std::uint64_t mask = std::uint64_t{1} << (record % 64U);
            if (!(selection.selected_words_[word] & mask)) {
                selection.selected_words_[word] |= mask;
                ++selection.selected_count_;
                selection.selected_min_word_ = std::min(selection.selected_min_word_, word);
                selection.selected_max_word_ = std::max(selection.selected_max_word_, word);
            }
            break;
        }
        default: break;
        }
        result.consumed_ops = 1U;
        return selection.selection_stage_ == 3U;
    };
    struct CountSink final : NativeValueCanonicalSink {
        std::size_t count = 0U;
        void append(const std::uint8_t *, const std::size_t size) override { count += size; }
    };
    struct HashSink final : NativeValueCanonicalSink {
        Sha256State &hash;
        std::size_t compressed = 0U;
        std::size_t bytes = 0U;
        explicit HashSink(Sha256State &value) : hash(value) {}
        void append(const std::uint8_t *data, const std::size_t size) override {
            const auto step = hash.update_step(data, size, size, 1U);
            if (!step.input_complete) throw std::logic_error("borrowed projection hash byte refused");
            compressed += step.compressed_blocks;
            bytes += step.consumed_bytes;
        }
    };
    try {
        const auto emit = [&](const std::uint8_t byte) {
            if (limit - result.consumed_ops < 3U) {
                result.next_atomic_ops = 3U; return false;
            }
            const auto step = cursor.hash_.update_step(&byte, 1U, 1U, 1U);
            if (!step.input_complete) throw std::logic_error("borrowed projection hash byte refused");
            result.consumed_ops += 2U + static_cast<std::uint32_t>(step.compressed_blocks);
            return true;
        };
        const auto emit_length = [&](const std::uint64_t length) {
            if (!emit(projection_le64(length, cursor.byte_offset_))) return false;
            ++cursor.byte_offset_;
            return cursor.byte_offset_ == 8U;
        };
        if (cursor.phase_ == Cursor::Phase::count_durable || cursor.phase_ == Cursor::Phase::count_overlay) {
            const std::size_t layer = cursor.phase_ == Cursor::Phase::count_durable ? 0U : 1U;
            const bool selected = layer == 0U ? selected_durable : selected_overlay;
            if (selected) {
                if (cursor.selection_stage_ != 3U) {
                    select_step(layer);
                    return result;
                }
                if (layer == 0U) cursor.durable_count_ = cursor.selected_count_;
                else cursor.overlay_count_ = cursor.selected_count_;
                cursor.phase_ = layer == 0U ? Cursor::Phase::header : Cursor::Phase::overlay_count;
                result.consumed_ops = 1U;
                return result;
            }
            const auto &records = cursor.phase_ == Cursor::Phase::count_durable ? durable : overlay;
            if (cursor.scan_index_ == records.size()) {
                cursor.scan_index_ = 0U;
                cursor.phase_ = cursor.phase_ == Cursor::Phase::count_durable
                    ? Cursor::Phase::header : Cursor::Phase::overlay_count;
                return result;
            }
            if (cell_inside_horizontal_bounds(records[cursor.scan_index_].state.cell, bounds)) {
                std::uint64_t &count = cursor.phase_ == Cursor::Phase::count_durable
                    ? cursor.durable_count_ : cursor.overlay_count_;
                if (count == std::numeric_limits<std::uint64_t>::max())
                    throw std::overflow_error("borrowed projection record count exhausted");
                ++count;
            }
            ++cursor.scan_index_; result.consumed_ops = 1U;
        } else if (cursor.phase_ == Cursor::Phase::header) {
            std::uint8_t byte = 0U;
            if (cursor.byte_offset_ < 4U) byte = static_cast<std::uint8_t>("WDP1"[cursor.byte_offset_]);
            else {
                const std::size_t part = (cursor.byte_offset_ - 4U) / 4U;
                const std::int32_t values[4] = {bounds.x, bounds.z, bounds.width, bounds.depth};
                byte = projection_le32(values[part], (cursor.byte_offset_ - 4U) % 4U);
            }
            if (emit(byte) && ++cursor.byte_offset_ == 20U) {
                cursor.byte_offset_ = 0U; cursor.phase_ = Cursor::Phase::durable_count;
            }
        } else if (cursor.phase_ == Cursor::Phase::durable_count) {
            if (emit_length(cursor.durable_count_)) {
                cursor.byte_offset_ = 0U; cursor.scan_index_ = 0U;
                cursor.phase_ = Cursor::Phase::durable_records;
            }
        } else if (cursor.phase_ == Cursor::Phase::overlay_count) {
            if (emit_length(cursor.overlay_count_)) {
                cursor.byte_offset_ = 0U; cursor.scan_index_ = 0U;
                cursor.phase_ = Cursor::Phase::overlay_records;
            }
        } else if (cursor.phase_ == Cursor::Phase::durable_records
            || cursor.phase_ == Cursor::Phase::overlay_records) {
            const std::size_t layer = cursor.phase_ == Cursor::Phase::durable_records ? 0U : 1U;
            const bool selected = layer == 0U ? selected_durable : selected_overlay;
            const auto &records = layer == 0U ? durable : overlay;
            if (selected && cursor.selection_stage_ != 3U) {
                select_step(layer);
                return result;
            }
            if (selected && !cursor.record_selected_) {
                if (cursor.selected_count_ == 0U) {
                    cursor.selection_stage_ = 0U;
                    cursor.scan_index_ = 0U;
                    cursor.phase_ = layer == 0U ? Cursor::Phase::count_overlay : Cursor::Phase::finish;
                    result.consumed_ops = 1U;
                    return result;
                }
                if (cursor.emit_word_ < cursor.selected_min_word_) {
                    cursor.emit_word_ = cursor.selected_min_word_;
                    result.consumed_ops = 1U;
                    return result;
                }
                if (cursor.emit_word_ >= BorrowedTypedProjectionCursor::SELECTOR_WORDS) {
                    throw std::logic_error("borrowed projection selected record missing");
                }
                const std::uint64_t word = cursor.selected_generations_[cursor.emit_word_]
                    == cursor.selection_generation_ ? cursor.selected_words_[cursor.emit_word_] : 0U;
                if (word == 0U) {
                    ++cursor.emit_word_;
                    result.consumed_ops = 1U;
                    return result;
                }
                if (limit < 7U) { result.next_atomic_ops = 7U; return result; }
                // A six-comparison bit search has a fixed work ceiling; no
                // bit-by-bit 64-step loop is hidden in one charged atom.
                std::uint64_t shifted = word;
                std::size_t bit = 0U;
                if ((shifted & 0xffffffffULL) == 0U) { shifted >>= 32U; bit += 32U; }
                if ((shifted & 0xffffULL) == 0U) { shifted >>= 16U; bit += 16U; }
                if ((shifted & 0xffULL) == 0U) { shifted >>= 8U; bit += 8U; }
                if ((shifted & 0xfULL) == 0U) { shifted >>= 4U; bit += 4U; }
                if ((shifted & 0x3ULL) == 0U) { shifted >>= 2U; bit += 2U; }
                if ((shifted & 0x1ULL) == 0U) bit += 1U;
                cursor.scan_index_ = cursor.emit_word_ * 64U + bit;
                cursor.record_selected_ = true;
                result.consumed_ops = 7U;
                return result;
            }
            if (!selected && cursor.scan_index_ == records.size()) {
                cursor.scan_index_ = 0U;
                cursor.phase_ = cursor.phase_ == Cursor::Phase::durable_records
                    ? Cursor::Phase::count_overlay : Cursor::Phase::finish;
                return result;
            }
            const NativeTypedWorldStateRecord &record = records[cursor.scan_index_];
            if (!selected && !cell_inside_horizontal_bounds(record.state.cell, bounds)) {
                ++cursor.scan_index_; result.consumed_ops = 1U;
                return result;
            }
            const NativeCellState &state = record.state;
            switch (cursor.record_phase_) {
            case Cursor::RecordPhase::start:
                cursor.metadata_.reset(); cursor.metadata_bytes_ = 0U;
                cursor.metadata_emitted_ = 0U;
                cursor.metadata_next_atomic_ = 1U;
                cursor.byte_offset_ = 0U; cursor.record_phase_ = Cursor::RecordPhase::fixed;
                result.consumed_ops = 1U; break;
            case Cursor::RecordPhase::fixed:
                if (emit(projection_fixed_record_byte(record, cursor.byte_offset_))
                    && ++cursor.byte_offset_ == 54U) {
                    cursor.byte_offset_ = 0U; cursor.record_phase_ = Cursor::RecordPhase::metadata_count;
                }
                break;
            case Cursor::RecordPhase::metadata_count: {
                if (limit < 2U) { result.next_atomic_ops = 2U; break; }
                CountSink sink;
                // byte_budget=1 bounds sink.count independently of the
                // cursor's structural work. Reserve that one extra atom.
                const auto step = cursor.metadata_.advance(
                    state.metadata, source_token, 1U, limit - 1U, limit - 1U, sink);
                if (step.status != NativeValueCanonicalCursorStatus::in_progress
                    && step.status != NativeValueCanonicalCursorStatus::complete)
                    throw std::logic_error("borrowed projection metadata measure failed");
                if (sink.count > 1U || step.work_units > limit - 1U)
                    throw std::logic_error("borrowed projection metadata count exceeded quota");
                if (cursor.metadata_bytes_ > std::numeric_limits<std::uint64_t>::max() - sink.count)
                    throw std::overflow_error("borrowed projection metadata length exhausted");
                cursor.metadata_bytes_ += sink.count;
                result.consumed_ops = static_cast<std::uint32_t>(step.work_units + sink.count);
                result.next_atomic_ops = static_cast<std::uint32_t>(step.next_atomic_units + 1U);
                cursor.metadata_next_atomic_ = result.next_atomic_ops;
                if (step.status == NativeValueCanonicalCursorStatus::complete)
                    cursor.record_phase_ = Cursor::RecordPhase::metadata_reset;
                break;
            }
            case Cursor::RecordPhase::metadata_reset:
                cursor.metadata_.reset(); cursor.byte_offset_ = 0U;
                cursor.metadata_next_atomic_ = 1U;
                cursor.record_phase_ = Cursor::RecordPhase::metadata_length;
                result.consumed_ops = 1U; break;
            case Cursor::RecordPhase::metadata_length:
                if (emit_length(cursor.metadata_bytes_)) {
                    cursor.byte_offset_ = 0U; cursor.record_phase_ = Cursor::RecordPhase::metadata_emit;
                }
                break;
            case Cursor::RecordPhase::metadata_emit: {
                if (limit < 3U) { result.next_atomic_ops = 3U; break; }
                HashSink sink(cursor.hash_);
                // One emitted byte costs at most one sink atom and one SHA
                // compression atom beyond NativeValue's own work units.
                const auto step = cursor.metadata_.advance(state.metadata, source_token,
                    1U, limit - 2U, limit - 2U, sink);
                if (step.status != NativeValueCanonicalCursorStatus::in_progress
                    && step.status != NativeValueCanonicalCursorStatus::complete)
                    throw std::logic_error("borrowed projection metadata emit failed");
                if (step.bytes_written > 1U || sink.compressed > 1U
                    || step.work_units > limit - 2U)
                    throw std::logic_error("borrowed projection metadata emit exceeded quota");
                if (sink.bytes != step.bytes_written
                    || cursor.metadata_emitted_ > std::numeric_limits<std::uint64_t>::max() - sink.bytes)
                    throw std::logic_error("borrowed projection metadata emit length mismatch");
                cursor.metadata_emitted_ += sink.bytes;
                result.consumed_ops = static_cast<std::uint32_t>(
                    step.work_units + step.bytes_written + sink.compressed);
                result.next_atomic_ops = static_cast<std::uint32_t>(step.next_atomic_units + 2U);
                cursor.metadata_next_atomic_ = result.next_atomic_ops;
                if (step.status == NativeValueCanonicalCursorStatus::complete) {
                    if (cursor.metadata_emitted_ != cursor.metadata_bytes_)
                        throw std::logic_error("borrowed projection metadata length changed");
                    cursor.record_phase_ = Cursor::RecordPhase::block_flag;
                }
                break;
            }
            case Cursor::RecordPhase::block_flag:
                if (emit(state.block_id ? 1U : 0U)) {
                    cursor.record_phase_ = state.block_id
                        ? Cursor::RecordPhase::block_length : Cursor::RecordPhase::reason_flag;
                    cursor.byte_offset_ = 0U;
                }
                break;
            case Cursor::RecordPhase::block_length:
                if (emit_length(state.block_id->value().size())) {
                    cursor.byte_offset_ = 0U;
                    cursor.record_phase_ = state.block_id->value().empty()
                        ? Cursor::RecordPhase::reason_flag : Cursor::RecordPhase::block_text;
                }
                break;
            case Cursor::RecordPhase::block_text:
                if (emit(static_cast<std::uint8_t>(state.block_id->value()[cursor.byte_offset_]))
                    && ++cursor.byte_offset_ == state.block_id->value().size()) {
                    cursor.byte_offset_ = 0U; cursor.record_phase_ = Cursor::RecordPhase::reason_flag;
                }
                break;
            case Cursor::RecordPhase::reason_flag:
                if (emit(state.edit_reason ? 1U : 0U)) {
                    cursor.record_phase_ = state.edit_reason
                        ? Cursor::RecordPhase::reason_length : Cursor::RecordPhase::end;
                    cursor.byte_offset_ = 0U;
                }
                break;
            case Cursor::RecordPhase::reason_length:
                if (emit_length(state.edit_reason->size())) {
                    cursor.byte_offset_ = 0U;
                    cursor.record_phase_ = state.edit_reason->empty()
                        ? Cursor::RecordPhase::end : Cursor::RecordPhase::reason_text;
                }
                break;
            case Cursor::RecordPhase::reason_text:
                if (emit(static_cast<std::uint8_t>((*state.edit_reason)[cursor.byte_offset_]))
                    && ++cursor.byte_offset_ == state.edit_reason->size())
                    cursor.record_phase_ = Cursor::RecordPhase::end;
                break;
            case Cursor::RecordPhase::end:
                if (selected) {
                    const std::size_t word = cursor.scan_index_ / 64U;
                    cursor.selected_words_[word] &= ~(std::uint64_t{1} << (cursor.scan_index_ % 64U));
                    --cursor.selected_count_;
                    cursor.record_selected_ = false;
                } else ++cursor.scan_index_;
                cursor.record_phase_ = Cursor::RecordPhase::start;
                cursor.byte_offset_ = 0U; result.consumed_ops = 1U; break;
            }
        } else if (cursor.phase_ == Cursor::Phase::finish) {
            const auto step = cursor.hash_.finish_step(limit);
            result.consumed_ops = static_cast<std::uint32_t>(step.compressed_blocks);
            result.next_atomic_ops = step.digest_ready ? 0U : 1U;
            if (step.digest_ready) {
                cursor.phase_ = Cursor::Phase::complete;
                cursor.status_ = Cursor::Status::ready;
            }
        }
    } catch (const std::exception &) {
        cursor.status_ = Cursor::Status::failed;
        result.consumed_ops = limit; // Conservatively debit unreported partial work.
    }
    result.status = cursor.status_;
    if (result.consumed_ops > limit) {
        cursor.status_ = Cursor::Status::failed;
        result.status = cursor.status_;
        result.consumed_ops = limit;
    }
    return result;
}

BorrowedTypedProjectionCursor::Step WorldDeltaStore::advance_borrowed_projection(
    BorrowedTypedProjectionCursor &cursor, const WorldDeltaHorizontalBounds bounds,
    const std::uint64_t source_token, const std::uint32_t offered_ops) const noexcept {
    BorrowedTypedProjectionCursor::Step aggregate;
    aggregate.status = cursor.status_;
    const auto current_next_atom = [&]() -> std::uint32_t {
        using Cursor = BorrowedTypedProjectionCursor;
        if (cursor.status_ == Cursor::Status::ready
            || cursor.status_ == Cursor::Status::failed
            || cursor.status_ == Cursor::Status::source_changed) return 0U;
        if (cursor.status_ == Cursor::Status::idle) return 1U;
        switch (cursor.phase_) {
        case Cursor::Phase::count_durable:
        case Cursor::Phase::count_overlay:
        case Cursor::Phase::finish: return 1U;
        case Cursor::Phase::header:
        case Cursor::Phase::durable_count:
        case Cursor::Phase::overlay_count: return 3U;
        case Cursor::Phase::durable_records:
        case Cursor::Phase::overlay_records: {
            const std::size_t layer = cursor.phase_ == Cursor::Phase::durable_records ? 0U : 1U;
            // This helper is also used by an observational zero-quota call.
            // Never reborrow the store outside the positive-step read guard.
            const std::size_t record_count = cursor.bound_layer_sizes_[layer];
            if (record_count <= Cursor::SELECTOR_WORDS * 64U) {
                if (cursor.selection_stage_ != 3U || cursor.selected_count_ == 0U
                    || cursor.emit_word_ < cursor.selected_min_word_
                    || cursor.emit_word_ >= Cursor::SELECTOR_WORDS) return 1U;
                if (!cursor.record_selected_) {
                    const std::uint64_t word = cursor.selected_generations_[cursor.emit_word_]
                        == cursor.selection_generation_ ? cursor.selected_words_[cursor.emit_word_] : 0U;
                    return word == 0U ? 1U : 7U;
                }
            } else if (cursor.scan_index_ == record_count) return 1U;
            switch (cursor.record_phase_) {
            case Cursor::RecordPhase::start:
            case Cursor::RecordPhase::metadata_reset:
            case Cursor::RecordPhase::end: return 1U;
            case Cursor::RecordPhase::metadata_count:
                return std::max(2U, cursor.metadata_next_atomic_);
            case Cursor::RecordPhase::metadata_emit:
                return std::max(3U, cursor.metadata_next_atomic_);
            default: return 3U; // one outer byte and possible SHA compression
            }
        }
        case Cursor::Phase::complete: return 0U;
        }
        return 1U;
    };
    const std::uint32_t limit = std::min(offered_ops, 64U);
    if (limit == 0U) {
        aggregate.next_atomic_ops = current_next_atom();
        return aggregate;
    }
    while (aggregate.consumed_ops < limit) {
        const auto prior_phase = cursor.phase_;
        const auto prior_record_phase = cursor.record_phase_;
        const std::size_t prior_scan = cursor.scan_index_;
        const auto prior_selection_stage = cursor.selection_stage_;
        const auto prior_selection_index = cursor.selection_index_;
        const auto prior_selection_generation = cursor.selection_generation_;
        const auto prior_selected_count = cursor.selected_count_;
        const auto prior_emit_word = cursor.emit_word_;
        const auto prior_byte_offset = cursor.byte_offset_;
        const auto prior_record_selected = cursor.record_selected_;
        const auto step = advance_borrowed_projection_one(
            cursor, bounds, source_token, limit - aggregate.consumed_ops);
        aggregate.status = step.status;
        aggregate.next_atomic_ops = step.next_atomic_ops;
        if (step.consumed_ops > limit - aggregate.consumed_ops) {
            cursor.status_ = BorrowedTypedProjectionCursor::Status::failed;
            aggregate.status = cursor.status_;
            aggregate.consumed_ops = limit;
            break;
        }
        aggregate.consumed_ops += step.consumed_ops;
        if (aggregate.status == BorrowedTypedProjectionCursor::Status::ready
            || aggregate.status == BorrowedTypedProjectionCursor::Status::failed
            || aggregate.status == BorrowedTypedProjectionCursor::Status::source_changed) break;
        if (step.consumed_ops == 0U) {
            if (cursor.phase_ == prior_phase && cursor.record_phase_ == prior_record_phase
                && cursor.scan_index_ == prior_scan
                && cursor.selection_stage_ == prior_selection_stage
                && cursor.selection_index_ == prior_selection_index
                && cursor.selection_generation_ == prior_selection_generation
                && cursor.selected_count_ == prior_selected_count
                && cursor.emit_word_ == prior_emit_word
                && cursor.byte_offset_ == prior_byte_offset
                && cursor.record_selected_ == prior_record_selected) break;
            // A phase-only transition is source work, too. This also makes the
            // loop finite even when an empty layer has no bytes to emit.
            ++aggregate.consumed_ops;
            aggregate.next_atomic_ops = 1U;
        }
        if (aggregate.next_atomic_ops > limit - aggregate.consumed_ops) break;
    }
    aggregate.next_atomic_ops = current_next_atom();
    return aggregate;
}

WorldDeltaPinnedSnapshot WorldDeltaStore::pin() const { return WorldDeltaPinnedSnapshot(state_); }

bool WorldDeltaStore::bind_source_mutation_fence(WorldSourceMutationFence *fence) noexcept {
    if (!fence || !fence->on_owner_thread() || source_mutation_fence_) return false;
    source_mutation_fence_ = fence;
    return true;
}

void WorldDeltaStore::require_source_writer_entry() const {
    if (source_mutation_fence_) source_mutation_fence_->require_writer_entry();
}

WorldDeltaCommitReceipt WorldDeltaStore::commit_typed_cells(const WorldTypedCellTransaction &transaction) {
    require_source_writer_entry();
    static_assert(std::is_nothrow_move_constructible_v<TransactionRecord>);
    static_assert(std::is_nothrow_move_constructible_v<WorldDeltaCommitReceipt>);
    std::vector<std::uint8_t> canonical = canonical_transaction(transaction);
    const auto replay = std::find_if(transactions_.begin(), transactions_.end(), [&](const TransactionRecord &record) {
        return record.transaction_id == transaction.transaction_id;
    });
    if (replay != transactions_.end()) {
        if (replay->canonical != canonical) throw WorldDeltaRejected(WorldDeltaRejectReason::transaction_conflict);
        WorldDeltaCommitReceipt receipt = replay->receipt;
        receipt.status = WorldDeltaCommitStatus::idempotent_replay;
        return receipt;
    }
    if (transaction.expected_revision != state_->revision) {
        throw WorldDeltaRejected(WorldDeltaRejectReason::revision_conflict);
    }
    if (transactions_.size() >= limits_.max_transactions) {
        throw WorldDeltaRejected(WorldDeltaRejectReason::capacity_exceeded);
    }

    auto next = std::make_shared<WorldDeltaSnapshotState>(*state_);
    std::vector<NativeTypedWorldStateRecord> durable = state_->terrain_volume.durable_snapshot.records();
    std::vector<NativeTypedWorldStateRecord> overlays = state_->typed_transient_overlays;
    for (const WorldTypedCellOperation &operation : sorted_operations(transaction)) {
        std::vector<NativeTypedWorldStateRecord> &records = operation.name_space == NativeCellStateNamespace::durable_terrain
            ? durable : overlays;
        const auto found = std::lower_bound(records.begin(), records.end(), operation.cell,
            [](const NativeTypedWorldStateRecord &record, const CellCoord &cell) {
                return V2CellCoordLess{}(record.state.cell, cell);
            });
        const bool exists = found != records.end() && found->state.cell == operation.cell;
        if (operation.kind == WorldTypedCellOperationKind::set) {
            const NativeTypedWorldStateRecord replacement = typed_record_for(operation);
            if (!exists) {
                records.insert(found, replacement);
            } else if (!(*found == replacement)) {
                *found = replacement;
            }
        } else if (exists) {
            records.erase(found);
        }
    }
    // Every operation was re-admitted before this candidate was built; this
    // final canonical construction cannot introduce a new validation branch.
    next->terrain_volume.durable_snapshot = NativeTypedWorldStateSnapshot::create(std::move(durable));
    NativeTypedWorldStateStore validator;
    validator.replace_transient_overlays(std::move(overlays));
    next->typed_transient_overlays = validator.transient_overlays();
    if (!fits_record_capacity(*next, limits_)) {
        throw WorldDeltaRejected(WorldDeltaRejectReason::capacity_exceeded);
    }

    std::set<CellCoord, CellCoordLess> changed_cells;
    std::set<CellCoord, CellCoordLess> changed_durable_cells;
    add_changed_typed_cells(
        state_->terrain_volume.durable_snapshot.records(), next->terrain_volume.durable_snapshot.records(), changed_durable_cells);
    changed_cells.insert(changed_durable_cells.begin(), changed_durable_cells.end());
    add_changed_typed_cells(state_->typed_transient_overlays, next->typed_transient_overlays, changed_cells);
    // A v2 terrainVolume revision changes once per semantically effective
    // durable-terrain transaction. Transient overlays are deliberately not
    // persisted by that domain and therefore cannot disturb its root or
    // per-section revision values.
    update_changed_terrain_sections(next->terrain_volume, changed_durable_cells);
    if (!changed_durable_cells.empty())
        next->durable_column_index = build_column_index(next->terrain_volume.durable_snapshot.records());
    if (next->typed_transient_overlays != state_->typed_transient_overlays)
        next->overlay_column_index = build_column_index(next->typed_transient_overlays);

    WorldDeltaCommitReceipt receipt;
    receipt.transaction_id = transaction.transaction_id;
    receipt.revision = state_->revision;
    if (changed_cells.empty()) {
        receipt.status = WorldDeltaCommitStatus::no_change;
    } else {
        if (state_->revision == std::numeric_limits<std::uint64_t>::max()) {
            throw WorldDeltaRejected(WorldDeltaRejectReason::capacity_exceeded);
        }
        next->revision = state_->revision + 1U;
        std::set<WorldDeltaSectionKey, SectionKeyLess> affected;
        for (const CellCoord &cell : changed_cells) {
            add_conservative_invalidation_neighborhood(
                section_key_for(cell), affected, limits_.max_affected_sections);
        }
        receipt.status = WorldDeltaCommitStatus::committed;
        receipt.revision = next->revision;
        receipt.affected_sections.assign(affected.begin(), affected.end());
        seal_content_digest(*next);
    }
    // All throwing work is deliberately complete before either durable journal
    // or current state becomes observable. reserve() plus the static assertion
    // above make this move append nonthrowing.
    TransactionRecord journal{transaction.transaction_id, std::move(canonical), receipt};
    transactions_.push_back(std::move(journal));
    if (!changed_cells.empty()) {
        // All throwing journal work has completed. Advance the authenticated
        // source epoch immediately before the nonthrowing pointer publication.
        if (source_mutation_fence_) source_mutation_fence_->published();
        state_ = std::move(next);
    }
    return std::move(receipt);
}

WorldDeltaCommitReceipt WorldDeltaStore::admit_typed_state(const WorldTypedStateAdmission &admission) {
    require_source_writer_entry();
    static_assert(std::is_nothrow_move_constructible_v<TransactionRecord>);
    static_assert(std::is_nothrow_move_constructible_v<WorldDeltaCommitReceipt>);
    const ValidatedTypedAdmission validated = validate_typed_admission(admission);
    std::vector<std::uint8_t> canonical = canonical_typed_admission(admission, validated);
    const auto replay = std::find_if(transactions_.begin(), transactions_.end(), [&](const TransactionRecord &record) {
        return record.transaction_id == admission.transaction_id;
    });
    if (replay != transactions_.end()) {
        if (replay->canonical != canonical) throw WorldDeltaRejected(WorldDeltaRejectReason::transaction_conflict);
        WorldDeltaCommitReceipt receipt = replay->receipt;
        receipt.status = WorldDeltaCommitStatus::idempotent_replay;
        return receipt;
    }
    if (admission.expected_revision != state_->revision) {
        throw WorldDeltaRejected(WorldDeltaRejectReason::revision_conflict);
    }
    if (transactions_.size() >= limits_.max_transactions) {
        throw WorldDeltaRejected(WorldDeltaRejectReason::capacity_exceeded);
    }

    auto next = std::make_shared<WorldDeltaSnapshotState>(*state_);
    next->terrain_volume.durable_snapshot = validated.durable_snapshot;
    next->typed_transient_overlays = validated.transient_overlays;
    if (!fits_record_capacity(*next, limits_)) {
        throw WorldDeltaRejected(WorldDeltaRejectReason::capacity_exceeded);
    }

    std::set<CellCoord, CellCoordLess> changed_cells;
    std::set<CellCoord, CellCoordLess> changed_durable_cells;
    add_changed_typed_cells(
        state_->terrain_volume.durable_snapshot.records(), next->terrain_volume.durable_snapshot.records(), changed_durable_cells);
    changed_cells.insert(changed_durable_cells.begin(), changed_durable_cells.end());
    add_changed_typed_cells(state_->typed_transient_overlays, next->typed_transient_overlays, changed_cells);
    update_changed_terrain_sections(next->terrain_volume, changed_durable_cells);
    if (!changed_durable_cells.empty())
        next->durable_column_index = build_column_index(next->terrain_volume.durable_snapshot.records());
    if (next->typed_transient_overlays != state_->typed_transient_overlays)
        next->overlay_column_index = build_column_index(next->typed_transient_overlays);

    WorldDeltaCommitReceipt receipt;
    receipt.transaction_id = admission.transaction_id;
    receipt.revision = state_->revision;
    if (changed_cells.empty()) {
        receipt.status = WorldDeltaCommitStatus::no_change;
    } else {
        if (state_->revision == std::numeric_limits<std::uint64_t>::max()) {
            throw WorldDeltaRejected(WorldDeltaRejectReason::capacity_exceeded);
        }
        next->revision = state_->revision + 1U;
        std::set<WorldDeltaSectionKey, SectionKeyLess> affected;
        for (const CellCoord &cell : changed_cells) {
            add_conservative_invalidation_neighborhood(
                section_key_for(cell), affected, limits_.max_affected_sections);
        }
        receipt.status = WorldDeltaCommitStatus::committed;
        receipt.revision = next->revision;
        receipt.affected_sections.assign(affected.begin(), affected.end());
        seal_content_digest(*next);
    }
    TransactionRecord journal{admission.transaction_id, std::move(canonical), receipt};
    transactions_.push_back(std::move(journal));
    if (!changed_cells.empty()) {
        if (source_mutation_fence_) source_mutation_fence_->published();
        state_ = std::move(next);
    }
    return receipt;
}

WorldDeltaCommitReceipt WorldDeltaStore::admit_feature_deltas(const WorldFeatureDeltaAdmission &admission) {
    require_source_writer_entry();
    static_assert(std::is_nothrow_move_constructible_v<TransactionRecord>);
    static_assert(std::is_nothrow_move_constructible_v<WorldDeltaCommitReceipt>);
    const ValidatedFeatureAdmission validated = validate_feature_admission(
        admission, feature_footprint_catalog_.get());
    std::vector<std::uint8_t> canonical = canonical_feature_admission(
        admission, validated, feature_footprint_catalog_.get());
    const auto replay = std::find_if(transactions_.begin(), transactions_.end(), [&](const TransactionRecord &record) {
        return record.transaction_id == admission.transaction_id;
    });
    if (replay != transactions_.end()) {
        if (replay->canonical != canonical) throw WorldDeltaRejected(WorldDeltaRejectReason::transaction_conflict);
        WorldDeltaCommitReceipt receipt = replay->receipt;
        receipt.status = WorldDeltaCommitStatus::idempotent_replay;
        return receipt;
    }
    if (admission.expected_revision != state_->revision) {
        throw WorldDeltaRejected(WorldDeltaRejectReason::revision_conflict);
    }
    if (transactions_.size() >= limits_.max_transactions) {
        throw WorldDeltaRejected(WorldDeltaRejectReason::capacity_exceeded);
    }

    auto next = std::make_shared<WorldDeltaSnapshotState>(*state_);
    next->feature_delta_snapshot = validated.snapshot;
    if (!fits_record_capacity(*next, limits_)) {
        throw WorldDeltaRejected(WorldDeltaRejectReason::capacity_exceeded);
    }

    const bool changed = !(state_->feature_delta_snapshot == next->feature_delta_snapshot);
    std::set<CellCoord, CellCoordLess> changed_cells;
    if (changed) {
        add_changed_feature_instance_cells(
            state_->feature_delta_snapshot, next->feature_delta_snapshot, changed_cells);
    }

    WorldDeltaCommitReceipt receipt;
    receipt.transaction_id = admission.transaction_id;
    receipt.revision = state_->revision;
    if (!changed) {
        receipt.status = WorldDeltaCommitStatus::no_change;
    } else {
        if (state_->revision == std::numeric_limits<std::uint64_t>::max()) {
            throw WorldDeltaRejected(WorldDeltaRejectReason::capacity_exceeded);
        }
        next->revision = state_->revision + 1U;
        std::set<WorldDeltaSectionKey, SectionKeyLess> affected;
        for (const CellCoord &cell : changed_cells) {
            add_conservative_invalidation_neighborhood(
                section_key_for(cell), affected, limits_.max_affected_sections);
        }
        if (!state_->feature_delta_snapshot.tombstones().empty()
            || !next->feature_delta_snapshot.tombstones().empty()) {
            // validate_feature_admission established this catalog requirement
            // for any nonempty before/after tombstone snapshot.
            add_changed_feature_tombstone_sections(
                state_->feature_delta_snapshot, next->feature_delta_snapshot,
                *feature_footprint_catalog_, affected, limits_.max_affected_sections);
        }
        receipt.status = WorldDeltaCommitStatus::committed;
        receipt.revision = next->revision;
        receipt.affected_sections.assign(affected.begin(), affected.end());
        seal_content_digest(*next);
    }
    TransactionRecord journal{admission.transaction_id, std::move(canonical), receipt};
    transactions_.push_back(std::move(journal));
    if (changed) {
        if (source_mutation_fence_) source_mutation_fence_->published();
        state_ = std::move(next);
    }
    return receipt;
}

} // namespace voxel::world_backend
