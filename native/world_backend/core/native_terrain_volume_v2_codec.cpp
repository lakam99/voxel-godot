#include "native_terrain_volume_v2_codec.hpp"

#include <algorithm>
#include <array>
#include <cmath>
#include <cstdint>
#include <limits>
#include <string>
#include <utility>
#include <vector>

namespace voxel::world_backend {
namespace {

[[noreturn]] void reject() {
    throw NativeTerrainVolumeV2Rejected();
}

bool byte_less(const std::string &left, const std::string &right) noexcept {
    return std::lexicographical_compare(left.begin(), left.end(), right.begin(), right.end(),
        [](const char left_byte, const char right_byte) noexcept {
            return static_cast<std::uint8_t>(static_cast<unsigned char>(left_byte))
                < static_cast<std::uint8_t>(static_cast<unsigned char>(right_byte));
        });
}

bool coordinate_less(const CellCoord &left, const CellCoord &right) noexcept {
    if (left.z != right.z) return left.z < right.z;
    if (left.y != right.y) return left.y < right.y;
    return left.x < right.x;
}

constexpr std::uint64_t MAX_V2_JSON_INTEGER = 9007199254740992ULL;

bool metadata_explicitly_disables_save(const NativeValue &metadata) {
    for (const auto &entry : metadata.as_object()) {
        if (entry.first == "saveDelta" && entry.second.kind() == NativeValueKind::boolean
            && !entry.second.as_boolean()) return true;
    }
    return false;
}

bool same_keys(const NativeValue::Object &object, const std::vector<std::string> &expected) {
    if (object.size() != expected.size()) return false;
    for (std::size_t index = 0; index < expected.size(); ++index) {
        if (object[index].first != expected[index]) return false;
    }
    return true;
}

const NativeValue &member(const NativeValue::Object &object, const std::string &key) {
    const auto found = std::lower_bound(object.begin(), object.end(), key,
        [](const auto &entry, const std::string &candidate) { return byte_less(entry.first, candidate); });
    // All call sites first prove an exact key set with same_keys(), so an
    // absent lookup is not a recoverable raw-input condition here.
    return found->second;
}

const NativeValue::Object &object(const NativeValue &value) {
    if (value.kind() != NativeValueKind::object) reject();
    return value.as_object();
}

const NativeValue::Array &array(const NativeValue &value) {
    if (value.kind() != NativeValueKind::array) reject();
    return value.as_array();
}

bool boolean(const NativeValue &value) {
    if (value.kind() != NativeValueKind::boolean) reject();
    return value.as_boolean();
}

std::uint64_t whole_u64(const NativeValue &value) {
    if (value.kind() != NativeValueKind::number) reject();
    const double number = value.as_number();
    // NativeValue numeric storage is binary64, therefore values beyond 2^53
    // cannot be represented as an exact JSON-derived integer at this boundary.
    if (number < 0.0 || number > 9007199254740992.0 || std::floor(number) != number) reject();
    return static_cast<std::uint64_t>(number);
}

std::int32_t whole_i32(const NativeValue &value) {
    if (value.kind() != NativeValueKind::number) reject();
    const double number = value.as_number();
    if (number < static_cast<double>(std::numeric_limits<std::int32_t>::min())
        || number > static_cast<double>(std::numeric_limits<std::int32_t>::max()) || std::floor(number) != number) reject();
    return static_cast<std::int32_t>(number);
}

CellCoord coordinate(const NativeValue &value) {
    const NativeValue::Array &items = array(value);
    if (items.size() != 3U) reject();
    return {whole_i32(items[0]), whole_i32(items[1]), whole_i32(items[2])};
}

NativeValue coordinate_value(const CellCoord coordinate) {
    return NativeValue::array({
        NativeValue::number(static_cast<double>(coordinate.x)),
        NativeValue::number(static_cast<double>(coordinate.y)),
        NativeValue::number(static_cast<double>(coordinate.z)),
    });
}

std::string string(const NativeValue &value) {
    if (value.kind() != NativeValueKind::string) reject();
    return value.as_string();
}

double finite_number(const NativeValue &value) {
    // NativeValue rejects nonfinite numbers at its sole construction boundary.
    if (value.kind() != NativeValueKind::number) reject();
    return value.as_number();
}

TerrainMaterialId material_from_string(const std::string &value) {
    static constexpr std::array<const char *, 17U> names = {
        "air", "grass", "dirt", "stone", "sand", "snow", "deepStone", "bedrock", "clay", "gravel",
        "coalOre", "ironOre", "crystalOre", "copperOre", "mud", "water", "lava",
    };
    for (std::size_t index = 0; index < names.size(); ++index) {
        if (value == names[index]) return static_cast<TerrainMaterialId>(index);
    }
    reject();
}

const char *material_to_string(const TerrainMaterialId value) {
    static constexpr std::array<const char *, 17U> names = {
        "air", "grass", "dirt", "stone", "sand", "snow", "deepStone", "bedrock", "clay", "gravel",
        "coalOre", "ironOre", "crystalOre", "copperOre", "mud", "water", "lava",
    };
    // This private helper is called only after snapshot re-admission, which
    // rejects every out-of-range TerrainMaterialId before serialization.
    return names[static_cast<std::uint8_t>(value)];
}

TerrainBiomeId biome_from_string(const std::string &value) {
    static constexpr std::array<const char *, 15U> names = {
        "plains", "forest", "swamp", "desert", "savanna", "snow", "taiga", "tundra", "ocean", "beach",
        "town", "underground", "deep_underground", "underground_air", "alpine",
    };
    for (std::size_t index = 0; index < names.size(); ++index) {
        if (value == names[index]) return static_cast<TerrainBiomeId>(index);
    }
    reject();
}

const char *biome_to_string(const TerrainBiomeId value) {
    static constexpr std::array<const char *, 15U> names = {
        "plains", "forest", "swamp", "desert", "savanna", "snow", "taiga", "tundra", "ocean", "beach",
        "town", "underground", "deep_underground", "underground_air", "alpine",
    };
    return names[static_cast<std::uint8_t>(value)];
}

TerrainFluidId fluid_from_string(const std::string &value) {
    if (value.empty()) return TerrainFluidId::none;
    if (value == "water") return TerrainFluidId::water;
    if (value == "lava") return TerrainFluidId::lava;
    reject();
}

const char *fluid_to_string(const TerrainFluidId value) {
    static constexpr std::array<const char *, 3U> names = {"", "water", "lava"};
    return names[static_cast<std::uint8_t>(value)];
}

NativeCellState decode_state(const NativeValue &value, const CellCoord cell, const CellCoord section, const CellCoord local) {
    const NativeValue::Object &fields = object(value);
    static const std::vector<std::string> expected = {
        "biome", "blockId", "cell", "density", "editReason", "edited", "fluid", "generated", "light", "localCell", "material", "metadata", "sectionKey", "solid",
    };
    if (!same_keys(fields, expected)) reject();
    // Keep each redundant-address assertion independently observable. This
    // prevents a short-circuited first mismatch from concealing a forged
    // section/local relation in a later migration check.
    if (!(coordinate(member(fields, "cell")) == cell)) reject();
    if (!(coordinate(member(fields, "sectionKey")) == section)) reject();
    if (!(coordinate(member(fields, "localCell")) == local)) reject();
    const NativeValue::Object &light = object(member(fields, "light"));
    static const std::vector<std::string> light_keys = {"block", "sky"};
    if (!same_keys(light, light_keys)) reject();
    const std::uint64_t sky = whole_u64(member(light, "sky"));
    const std::uint64_t block = whole_u64(member(light, "block"));
    if (sky > 15U || block > 15U) reject();
    const NativeValue &metadata = member(fields, "metadata");
    if (metadata.kind() != NativeValueKind::object) reject();
    // `saveDelta=false` has an explicit non-durable meaning in the live
    // service. It cannot enter terrainVolume's durable codec. saveDelta=true
    // remains ordinary preserved metadata; no metadata string is treated as a
    // scene-overlay discriminator here.
    if (metadata_explicitly_disables_save(metadata)) reject();
    NativeCellStateInput input;
    input.cell = cell;
    input.block_id = NativeBlockIdentity::create(string(member(fields, "blockId")));
    input.material = material_from_string(string(member(fields, "material")));
    input.biome = biome_from_string(string(member(fields, "biome")));
    input.solid = boolean(member(fields, "solid"));
    input.density = finite_number(member(fields, "density"));
    input.fluid = fluid_from_string(string(member(fields, "fluid")));
    input.light = {static_cast<std::uint8_t>(sky), static_cast<std::uint8_t>(block)};
    input.metadata = metadata;
    // Current v2 saver writes String(reason) for every durable edited cell;
    // it is required here so the codec cannot erase that persisted field.
    input.edit_reason = string(member(fields, "editReason"));
    input.generated = boolean(member(fields, "generated"));
    input.edited = boolean(member(fields, "edited"));
    if (input.generated || !input.edited) reject();
    try {
        return make_native_cell_state(input, NativeCellStateNamespace::durable_terrain);
    } catch (const std::invalid_argument &) {
        reject();
    }
}

NativeValue encode_state(const NativeCellState &state) {
    return NativeValue::object({
        {"biome", NativeValue::string(biome_to_string(state.biome))},
        {"blockId", NativeValue::string(state.block_id->value())},
        {"cell", coordinate_value(state.cell)},
        {"density", NativeValue::number(state.density)},
        {"editReason", NativeValue::string(*state.edit_reason)},
        {"edited", NativeValue::boolean(state.edited)},
        {"fluid", NativeValue::string(fluid_to_string(state.fluid))},
        {"generated", NativeValue::boolean(state.generated)},
        {"light", NativeValue::object({
            {"block", NativeValue::number(static_cast<double>(state.light.block))},
            {"sky", NativeValue::number(static_cast<double>(state.light.sky))},
        })},
        {"localCell", coordinate_value(state.local_cell)},
        {"material", NativeValue::string(material_to_string(state.material))},
        {"metadata", state.metadata},
        {"sectionKey", coordinate_value(state.section)},
        {"solid", NativeValue::boolean(state.solid)},
    });
}

} // namespace

NativeTerrainVolumeV2Rejected::NativeTerrainVolumeV2Rejected()
    : std::invalid_argument("invalid native terrain volume v2") {}

bool NativeTerrainVolumeV2SectionRevision::operator==(const NativeTerrainVolumeV2SectionRevision &other) const noexcept {
    return section == other.section && revision == other.revision;
}

bool NativeTerrainVolumeV2::operator==(const NativeTerrainVolumeV2 &other) const noexcept {
    return revision == other.revision && durable_snapshot == other.durable_snapshot && section_revisions == other.section_revisions;
}

NativeTerrainVolumeV2 validate_native_terrain_volume_v2(
    const NativeTerrainVolumeV2 &volume,
    const NativeTerrainVolumeV2Limits limits) {
    try {
        const std::size_t record_count = volume.durable_snapshot.records().size();
        if (volume.revision > MAX_V2_JSON_INTEGER
            || record_count > limits.max_records
            || volume.section_revisions.size() > record_count) reject();

        NativeTerrainVolumeV2 result;
        result.revision = volume.revision;
        result.durable_snapshot = NativeTypedWorldStateSnapshot::create(volume.durable_snapshot.records());
        result.section_revisions = volume.section_revisions;

        const std::vector<NativeTypedWorldStateRecord> &records = result.durable_snapshot.records();
        std::size_t record_index = 0U;
        CellCoord previous_section{};
        bool has_previous_section = false;
        for (const NativeTerrainVolumeV2SectionRevision &section : result.section_revisions) {
            if (section.revision > MAX_V2_JSON_INTEGER
                || (has_previous_section && !coordinate_less(previous_section, section.section))) reject();
            previous_section = section.section;
            has_previous_section = true;

            if (record_index >= records.size() || !(records[record_index].state.section == section.section)) reject();
            while (record_index < records.size() && records[record_index].state.section == section.section) {
                const NativeCellState &state = records[record_index].state;
                if (!state.block_id.has_value() || !state.edit_reason.has_value()
                    || metadata_explicitly_disables_save(state.metadata)) reject();
                ++record_index;
            }
            // Canonical unique coordinates and fixed 16-cell decomposition
            // prove this run contains at most MAX_CELLS_PER_SECTION records.
        }
        if (record_index != records.size()) reject();
        return result;
    } catch (const NativeTerrainVolumeV2Rejected &) {
        throw;
    } catch (const std::invalid_argument &) {
        reject();
    }
}

NativeTerrainVolumeV2 decode_native_terrain_volume_v2(const NativeValue &value) {
    try {
        const NativeValue::Object &root = object(value);
        static const std::vector<std::string> root_keys = {"revision", "schemaVersion", "sectionSize", "sections"};
        if (!same_keys(root, root_keys) || whole_u64(member(root, "schemaVersion")) != 1U || whole_u64(member(root, "sectionSize")) != 16U) reject();
        NativeTerrainVolumeV2 result;
        result.revision = whole_u64(member(root, "revision"));
        const NativeValue::Array &sections = array(member(root, "sections"));
        std::vector<NativeTypedWorldStateRecord> records;
        CellCoord previous_section{};
        bool has_previous_section = false;
        for (const NativeValue &section_value : sections) {
            const NativeValue::Object &section_fields = object(section_value);
            static const std::vector<std::string> section_keys = {"cells", "originCell", "revision", "schemaVersion", "sectionKey"};
            if (!same_keys(section_fields, section_keys) || whole_u64(member(section_fields, "schemaVersion")) != 1U) reject();
            const CellCoord section = coordinate(member(section_fields, "sectionKey"));
            const auto origin = section_origin(section, NativeCellState::SECTION_SIZE);
            if (!origin.has_value() || !(coordinate(member(section_fields, "originCell")) == *origin)) reject();
            if (has_previous_section && !coordinate_less(previous_section, section)) reject();
            previous_section = section;
            has_previous_section = true;
            const NativeValue::Array &cells = array(member(section_fields, "cells"));
            if (cells.empty()) reject();
            result.section_revisions.push_back({section, whole_u64(member(section_fields, "revision"))});
            CellCoord previous_cell{};
            bool has_previous_cell = false;
            for (const NativeValue &cell_value : cells) {
                const NativeValue::Object &cell_fields = object(cell_value);
                static const std::vector<std::string> cell_keys = {"cell", "local", "state"};
                if (!same_keys(cell_fields, cell_keys)) reject();
                const CellCoord cell = coordinate(member(cell_fields, "cell"));
                const CellCoord local = coordinate(member(cell_fields, "local"));
                const auto split = split_cell(cell, NativeCellState::SECTION_SIZE);
                if (!split.has_value() || !(split->section == section) || !(split->local == local)) reject();
                if (has_previous_cell && !coordinate_less(previous_cell, cell)) reject();
                previous_cell = cell;
                has_previous_cell = true;
                records.push_back({
                    NativeCellStateNamespace::durable_terrain,
                    NativeTypedWorldStatePersistence::durable,
                    decode_state(member(cell_fields, "state"), cell, section, local),
                });
            }
        }
        result.durable_snapshot = NativeTypedWorldStateSnapshot::create(std::move(records));
        return validate_native_terrain_volume_v2(result);
    } catch (const NativeTerrainVolumeV2Rejected &) {
        throw;
    } catch (const std::invalid_argument &) {
        reject();
    }
}

NativeValue encode_native_terrain_volume_v2(const NativeTerrainVolumeV2 &volume) {
    try {
        // Re-admit through the production-size typed validator before using
        // NativeValue as this convenience serialization representation.
        const NativeTerrainVolumeV2 validated = validate_native_terrain_volume_v2(volume);
        const NativeTypedWorldStateSnapshot &snapshot = validated.durable_snapshot;
        const std::vector<NativeTerrainVolumeV2SectionRevision> &revisions = validated.section_revisions;
        NativeValue::Array sections;
        std::size_t record_index = 0U;
        for (const NativeTerrainVolumeV2SectionRevision &revision : revisions) {
            NativeValue::Array cells;
            while (record_index < snapshot.records().size() && snapshot.records()[record_index].state.section == revision.section) {
                const NativeCellState &state = snapshot.records()[record_index].state;
                // NativeTypedWorldStateSnapshot::create() above proved this
                // sequence is unique and in v2 z/y/x order.
                cells.push_back(NativeValue::object({
                    {"cell", coordinate_value(state.cell)},
                    {"local", coordinate_value(state.local_cell)},
                    {"state", encode_state(state)},
                }));
                ++record_index;
            }
            // A nonempty emitted section is proven to contain a re-admitted
            // typed state for this exact section key, so its 16-cell origin
            // is already representable. The raw decoder owns the untrusted
            // optional-origin rejection on the other direction.
            const CellCoord origin = section_origin(revision.section, NativeCellState::SECTION_SIZE).value();
            sections.push_back(NativeValue::object({
                {"cells", NativeValue::array(std::move(cells))},
                {"originCell", coordinate_value(origin)},
                {"revision", NativeValue::number(static_cast<double>(revision.revision))},
                {"schemaVersion", NativeValue::number(1.0)},
                {"sectionKey", coordinate_value(revision.section)},
            }));
        }
        return NativeValue::object({
            {"revision", NativeValue::number(static_cast<double>(validated.revision))},
            {"schemaVersion", NativeValue::number(1.0)},
            {"sectionSize", NativeValue::number(16.0)},
            {"sections", NativeValue::array(std::move(sections))},
        });
    } catch (const NativeTerrainVolumeV2Rejected &) {
        throw;
    }
}

} // namespace voxel::world_backend
