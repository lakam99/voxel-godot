#include "test_harness.hpp"

#include "../core/native_terrain_volume_v2_codec.hpp"

#include <string>
#include <utility>
#include <vector>

using namespace voxel::world_backend;

namespace {

NativeCellState durable_state(const CellCoord cell, const std::string edit_reason) {
    NativeCellStateInput input;
    input.cell = cell;
    input.material = TerrainMaterialId::stone;
    input.biome = TerrainBiomeId::underground;
    input.solid = true;
    input.density = 1.25;
    input.fluid = TerrainFluidId::none;
    input.light = {3, 7};
    input.metadata = NativeValue::object({
        {"saveDelta", NativeValue::boolean(true)},
        {"source", NativeValue::object({{"kind", NativeValue::string("player_dig")}})},
    });
    input.block_id = NativeBlockIdentity::create("terrain.stone.edited");
    input.edit_reason = edit_reason;
    input.generated = false;
    input.edited = true;
    return make_native_cell_state(input);
}

NativeTypedWorldStateRecord durable_record(const CellCoord cell, const std::string reason) {
    return {NativeCellStateNamespace::durable_terrain, NativeTypedWorldStatePersistence::durable, durable_state(cell, reason)};
}

NativeTerrainVolumeV2 sample_volume() {
    NativeTerrainVolumeV2 volume;
    volume.revision = 73U;
    volume.durable_snapshot = NativeTypedWorldStateSnapshot::create({
        durable_record({-1, -1, -1}, "dig_one"),
        durable_record({-17, 31, 16}, "dig_two"),
    });
    volume.section_revisions = {
        {{-1, -1, -1}, 71U},
        {{-2, 1, 1}, 72U},
    };
    return volume;
}

NativeTerrainVolumeV2 enum_coverage_volume() {
    const std::vector<TerrainMaterialId> materials = {
        TerrainMaterialId::air, TerrainMaterialId::grass, TerrainMaterialId::dirt, TerrainMaterialId::stone,
        TerrainMaterialId::sand, TerrainMaterialId::snow, TerrainMaterialId::deep_stone, TerrainMaterialId::bedrock,
        TerrainMaterialId::clay, TerrainMaterialId::gravel, TerrainMaterialId::coal_ore, TerrainMaterialId::iron_ore,
        TerrainMaterialId::crystal_ore, TerrainMaterialId::copper_ore, TerrainMaterialId::mud, TerrainMaterialId::water,
        TerrainMaterialId::lava,
    };
    const std::vector<TerrainBiomeId> biomes = {
        TerrainBiomeId::plains, TerrainBiomeId::forest, TerrainBiomeId::swamp, TerrainBiomeId::desert, TerrainBiomeId::savanna,
        TerrainBiomeId::snow, TerrainBiomeId::taiga, TerrainBiomeId::tundra, TerrainBiomeId::ocean, TerrainBiomeId::beach,
        TerrainBiomeId::town, TerrainBiomeId::underground, TerrainBiomeId::deep_underground, TerrainBiomeId::underground_air,
        TerrainBiomeId::alpine,
    };
    std::vector<NativeTypedWorldStateRecord> records;
    for (std::size_t index = 0; index < materials.size(); ++index) {
        NativeCellStateInput input;
        input.cell = {static_cast<std::int32_t>(index), 0, 0};
        input.material = materials[index];
        input.biome = biomes[index % biomes.size()];
        const bool fluid = materials[index] == TerrainMaterialId::water || materials[index] == TerrainMaterialId::lava;
        input.solid = !fluid && materials[index] != TerrainMaterialId::air;
        input.density = fluid ? 0.0 : input.solid ? 1.0 : -1.0;
        input.fluid = materials[index] == TerrainMaterialId::water ? TerrainFluidId::water
            : materials[index] == TerrainMaterialId::lava ? TerrainFluidId::lava : TerrainFluidId::none;
        input.light = {0, 0};
        input.metadata = NativeValue::object({{"saveDelta", NativeValue::boolean(true)}});
        input.block_id = NativeBlockIdentity::create("codec.enum." + std::to_string(index));
        input.edit_reason = "enum";
        input.generated = false;
        input.edited = true;
        records.push_back({NativeCellStateNamespace::durable_terrain, NativeTypedWorldStatePersistence::durable,
            make_native_cell_state(input)});
    }
    NativeTerrainVolumeV2 result;
    result.revision = 1U;
    result.durable_snapshot = NativeTypedWorldStateSnapshot::create(std::move(records));
    result.section_revisions = {{{0, 0, 0}, 1U}, {{1, 0, 0}, 1U}};
    return result;
}

NativeValue replace_member(NativeValue::Object object, const std::string &key, NativeValue value) {
    for (auto &entry : object) {
        if (entry.first == key) {
            entry.second = std::move(value);
            return NativeValue::object(std::move(object));
        }
    }
    throw std::runtime_error("missing expected member");
}

NativeValue remove_member(NativeValue::Object object, const std::string &key) {
    for (auto found = object.begin(); found != object.end(); ++found) {
        if (found->first == key) {
            object.erase(found);
            return NativeValue::object(std::move(object));
        }
    }
    throw std::runtime_error("missing expected member");
}

NativeValue rename_member(NativeValue::Object object, const std::string &from, std::string to) {
    for (auto &entry : object) {
        if (entry.first == from) {
            entry.first = std::move(to);
            return NativeValue::object(std::move(object));
        }
    }
    throw std::runtime_error("missing expected member");
}

NativeValue replace_first_state(const NativeValue &value, NativeValue state) {
    NativeValue::Object root = value.as_object();
    NativeValue::Array sections = root[3].second.as_array();
    NativeValue::Object section = sections[0].as_object();
    NativeValue::Array cells = section[0].second.as_array();
    NativeValue::Object cell = cells[0].as_object();
    cells[0] = replace_member(std::move(cell), "state", std::move(state));
    sections[0] = replace_member(std::move(section), "cells", NativeValue::array(std::move(cells)));
    return replace_member(std::move(root), "sections", NativeValue::array(std::move(sections)));
}

NativeValue replace_first_cell_local(const NativeValue &value, NativeValue local) {
    NativeValue::Object root = value.as_object();
    NativeValue::Array sections = root[3].second.as_array();
    NativeValue::Object section = sections[0].as_object();
    NativeValue::Array cells = section[0].second.as_array();
    cells[0] = replace_member(cells[0].as_object(), "local", std::move(local));
    sections[0] = replace_member(std::move(section), "cells", NativeValue::array(std::move(cells)));
    return replace_member(std::move(root), "sections", NativeValue::array(std::move(sections)));
}

NativeValue replace_first_section_member(const NativeValue &value, const std::string &key, NativeValue member) {
    NativeValue::Object root = value.as_object();
    NativeValue::Array sections = root[3].second.as_array();
    sections[0] = replace_member(sections[0].as_object(), key, std::move(member));
    return replace_member(std::move(root), "sections", NativeValue::array(std::move(sections)));
}

NativeValue replace_first_cell_member(const NativeValue &value, const std::string &key, NativeValue member) {
    NativeValue::Object root = value.as_object();
    NativeValue::Array sections = root[3].second.as_array();
    NativeValue::Object section = sections[0].as_object();
    NativeValue::Array cells = section[0].second.as_array();
    cells[0] = replace_member(cells[0].as_object(), key, std::move(member));
    sections[0] = replace_member(std::move(section), "cells", NativeValue::array(std::move(cells)));
    return replace_member(std::move(root), "sections", NativeValue::array(std::move(sections)));
}

NativeValue swap_first_section_cells(const NativeValue &value) {
    NativeValue::Object root = value.as_object();
    NativeValue::Array sections = root[3].second.as_array();
    NativeValue::Object section = sections[0].as_object();
    NativeValue::Array cells = section[0].second.as_array();
    std::swap(cells[0], cells[1]);
    sections[0] = replace_member(std::move(section), "cells", NativeValue::array(std::move(cells)));
    return replace_member(std::move(root), "sections", NativeValue::array(std::move(sections)));
}

NativeValue swap_sections(const NativeValue &value) {
    NativeValue::Object root = value.as_object();
    NativeValue::Array sections = root[3].second.as_array();
    std::swap(sections[0], sections[1]);
    return replace_member(std::move(root), "sections", NativeValue::array(std::move(sections)));
}

NativeTerrainVolumeV2 y_order_volume() {
    NativeTerrainVolumeV2 volume;
    volume.revision = 2U;
    volume.durable_snapshot = NativeTypedWorldStateSnapshot::create({
        durable_record({0, 0, 0}, "low"), durable_record({0, 16, 0}, "high"),
    });
    volume.section_revisions = {{{0, 0, 0}, 1U}, {{0, 1, 0}, 2U}};
    return volume;
}

} // namespace

VWB_TEST(native_terrain_volume_v2_codec_round_trips_exact_current_v2_structure) {
    const NativeTerrainVolumeV2 original = sample_volume();
    const NativeValue encoded = encode_native_terrain_volume_v2(original);
    const NativeValue::Object &root = encoded.as_object();
    VWB_EXPECT_EQ(4U, root.size());
    VWB_EXPECT_EQ(std::string("revision"), root[0].first);
    VWB_EXPECT_EQ(std::string("schemaVersion"), root[1].first);
    VWB_EXPECT_EQ(std::string("sectionSize"), root[2].first);
    VWB_EXPECT_EQ(std::string("sections"), root[3].first);
    const NativeValue::Array &sections = root[3].second.as_array();
    VWB_EXPECT_EQ(2U, sections.size());
    // v2 arrays are [x, y, z] even though their enclosing sort is z/y/x.
    const NativeValue::Array &first_section_key = sections[0].as_object()[4].second.as_array();
    VWB_EXPECT_EQ(-1.0, first_section_key[0].as_number());
    VWB_EXPECT_EQ(-1.0, first_section_key[1].as_number());
    VWB_EXPECT_EQ(-1.0, first_section_key[2].as_number());
    const NativeValue::Array &second_section_key = sections[1].as_object()[4].second.as_array();
    VWB_EXPECT_EQ(-2.0, second_section_key[0].as_number());
    VWB_EXPECT_EQ(1.0, second_section_key[1].as_number());
    VWB_EXPECT_EQ(1.0, second_section_key[2].as_number());
    const NativeValue::Object &state = sections[0].as_object()[0].second.as_array()[0].as_object()[2].second.as_object();
    VWB_EXPECT_EQ(std::string("editReason"), state[4].first);
    VWB_EXPECT_EQ(std::string("dig_one"), state[4].second.as_string());
    VWB_EXPECT_EQ(std::string("terrain.stone.edited"), state[1].second.as_string());
    VWB_EXPECT_EQ(NativeValueKind::object, state[11].second.kind());

    const NativeTerrainVolumeV2 decoded = decode_native_terrain_volume_v2(encoded);
    VWB_EXPECT(decoded == original);
    const NativeValue reencoded = encode_native_terrain_volume_v2(decoded);
    VWB_EXPECT_EQ(encoded.canonical_binary(), reencoded.canonical_binary());
}

VWB_TEST(native_terrain_volume_v2_codec_value_equality_covers_each_structural_field) {
    const NativeTerrainVolumeV2 original = sample_volume();
    VWB_EXPECT(original.section_revisions[0] == original.section_revisions[0]);
    NativeTerrainVolumeV2SectionRevision changed_section = original.section_revisions[0];
    changed_section.revision += 1U;
    VWB_EXPECT(!(original.section_revisions[0] == changed_section));
    changed_section = original.section_revisions[0];
    changed_section.section.x += 1;
    VWB_EXPECT(!(original.section_revisions[0] == changed_section));
    NativeTerrainVolumeV2 changed = original;
    changed.revision += 1U;
    VWB_EXPECT(!(original == changed));
    changed = original;
    changed.section_revisions[0].revision += 1U;
    VWB_EXPECT(!(original == changed));
    changed = original;
    std::vector<NativeTypedWorldStateRecord> changed_records = changed.durable_snapshot.records();
    changed_records[0].state.edit_reason = "changed";
    changed.durable_snapshot = NativeTypedWorldStateSnapshot::create(std::move(changed_records));
    VWB_EXPECT(!(original == changed));
}

VWB_TEST(native_terrain_volume_v2_codec_rejects_unknown_versions_unknown_fields_and_coordinate_mistranslations) {
    const NativeValue encoded = encode_native_terrain_volume_v2(sample_volume());
    VWB_EXPECT_THROW(NativeTerrainVolumeV2Rejected, decode_native_terrain_volume_v2(
        replace_member(encoded.as_object(), "schemaVersion", NativeValue::number(2.0))));
    NativeValue::Object unknown_root = encoded.as_object();
    unknown_root.push_back({"unknown", NativeValue::null()});
    VWB_EXPECT_THROW(NativeTerrainVolumeV2Rejected, decode_native_terrain_volume_v2(NativeValue::object(std::move(unknown_root))));
    VWB_EXPECT_THROW(NativeTerrainVolumeV2Rejected, decode_native_terrain_volume_v2(
        rename_member(encoded.as_object(), "revision", "revisioN")));
    VWB_EXPECT_THROW(NativeTerrainVolumeV2Rejected, decode_native_terrain_volume_v2(
        replace_first_cell_local(encoded, NativeValue::array({NativeValue::number(0.0), NativeValue::number(0.0), NativeValue::number(0.0)}))));
}

VWB_TEST(native_terrain_volume_v2_codec_preserves_each_current_material_biome_and_fluid_identity) {
    const NativeTerrainVolumeV2 original = enum_coverage_volume();
    const NativeValue encoded = encode_native_terrain_volume_v2(original);
    const NativeValue::Array &sections = encoded.as_object()[3].second.as_array();
    // These spellings are the existing v2 GDScript persisted names, not the
    // native enum spellings. They are structural golden assertions.
    const NativeValue::Array &first_cells = sections[0].as_object()[0].second.as_array();
    VWB_EXPECT_EQ(std::string("deepStone"), first_cells[6].as_object()[2].second.as_object()[10].second.as_string());
    VWB_EXPECT_EQ(std::string("coalOre"), first_cells[10].as_object()[2].second.as_object()[10].second.as_string());
    VWB_EXPECT_EQ(std::string("ironOre"), first_cells[11].as_object()[2].second.as_object()[10].second.as_string());
    VWB_EXPECT_EQ(std::string("crystalOre"), first_cells[12].as_object()[2].second.as_object()[10].second.as_string());
    VWB_EXPECT_EQ(std::string("copperOre"), first_cells[13].as_object()[2].second.as_object()[10].second.as_string());
    VWB_EXPECT_EQ(0.0, first_cells[15].as_object()[2].second.as_object()[3].second.as_number());
    VWB_EXPECT_EQ(0.0, sections[1].as_object()[0].second.as_array()[0].as_object()[2].second.as_object()[3].second.as_number());
    const NativeTerrainVolumeV2 decoded = decode_native_terrain_volume_v2(encoded);
    VWB_EXPECT(decoded == original);
    VWB_EXPECT_EQ(17U, decoded.durable_snapshot.records().size());
    const NativeValue water_lava_round_trip = encode_native_terrain_volume_v2(decoded);
    VWB_EXPECT_EQ(encoded.canonical_binary(), water_lava_round_trip.canonical_binary());
}

VWB_TEST(native_terrain_volume_v2_codec_rejects_non_durable_and_unrepresentable_state_inputs_without_defaulting) {
    const NativeValue encoded = encode_native_terrain_volume_v2(sample_volume());
    const NativeValue original_state = encoded.as_object()[3].second.as_array()[0].as_object()[0].second.as_array()[0].as_object()[2].second;
    VWB_EXPECT_THROW(NativeTerrainVolumeV2Rejected, decode_native_terrain_volume_v2(
        replace_first_state(encoded, remove_member(original_state.as_object(), "editReason"))));
    NativeValue::Object state_fields = original_state.as_object();
    NativeValue metadata = state_fields[11].second;
    NativeValue::Object metadata_fields = metadata.as_object();
    metadata_fields[0].second = NativeValue::boolean(false);
    state_fields[11].second = NativeValue::object(std::move(metadata_fields));
    VWB_EXPECT_THROW(NativeTerrainVolumeV2Rejected, decode_native_terrain_volume_v2(
        replace_first_state(encoded, NativeValue::object(std::move(state_fields)))));
    NativeValue::Object nonboolean_metadata_state = original_state.as_object();
    nonboolean_metadata_state[11].second = NativeValue::object({{"saveDelta", NativeValue::string("opaque")}});
    const NativeTerrainVolumeV2 nonboolean_metadata = decode_native_terrain_volume_v2(
        replace_first_state(encoded, NativeValue::object(std::move(nonboolean_metadata_state))));
    VWB_EXPECT_EQ(NativeValueKind::string, nonboolean_metadata.durable_snapshot.records()[0].state.metadata.as_object()[0].second.kind());
    NativeTerrainVolumeV2 missing_reason = sample_volume();
    std::vector<NativeTypedWorldStateRecord> records = missing_reason.durable_snapshot.records();
    records[0].state.edit_reason.reset();
    missing_reason.durable_snapshot = NativeTypedWorldStateSnapshot::create(std::move(records));
    VWB_EXPECT_THROW(NativeTerrainVolumeV2Rejected, encode_native_terrain_volume_v2(missing_reason));
    NativeTerrainVolumeV2 missing_block = sample_volume();
    std::vector<NativeTypedWorldStateRecord> block_records = missing_block.durable_snapshot.records();
    block_records[0].state.block_id.reset();
    missing_block.durable_snapshot = NativeTypedWorldStateSnapshot::create(std::move(block_records));
    VWB_EXPECT_THROW(NativeTerrainVolumeV2Rejected, encode_native_terrain_volume_v2(missing_block));
}

VWB_TEST(native_terrain_volume_v2_codec_rejects_every_structural_domain_mismatch) {
    const NativeValue encoded = encode_native_terrain_volume_v2(sample_volume());
    VWB_EXPECT_THROW(NativeTerrainVolumeV2Rejected, decode_native_terrain_volume_v2(NativeValue::null()));
    VWB_EXPECT_THROW(NativeTerrainVolumeV2Rejected, decode_native_terrain_volume_v2(
        replace_member(encoded.as_object(), "revision", NativeValue::boolean(true))));
    VWB_EXPECT_THROW(NativeTerrainVolumeV2Rejected, decode_native_terrain_volume_v2(
        replace_member(encoded.as_object(), "revision", NativeValue::number(-1.0))));
    VWB_EXPECT_THROW(NativeTerrainVolumeV2Rejected, decode_native_terrain_volume_v2(
        replace_member(encoded.as_object(), "revision", NativeValue::number(1.5))));
    VWB_EXPECT_THROW(NativeTerrainVolumeV2Rejected, decode_native_terrain_volume_v2(
        replace_member(encoded.as_object(), "revision", NativeValue::number(9007199254740994.0))));
    VWB_EXPECT_THROW(NativeTerrainVolumeV2Rejected, decode_native_terrain_volume_v2(
        replace_member(encoded.as_object(), "sectionSize", NativeValue::number(15.0))));
    VWB_EXPECT_THROW(NativeTerrainVolumeV2Rejected, decode_native_terrain_volume_v2(
        replace_member(encoded.as_object(), "sections", NativeValue::null())));
    VWB_EXPECT_THROW(NativeTerrainVolumeV2Rejected, decode_native_terrain_volume_v2(
        replace_first_section_member(encoded, "schemaVersion", NativeValue::number(2.0))));
    {
        NativeValue::Object root = encoded.as_object();
        NativeValue::Array sections = root[3].second.as_array();
        sections[0] = rename_member(sections[0].as_object(), "schemaVersion", "schemaVersioN");
        VWB_EXPECT_THROW(NativeTerrainVolumeV2Rejected, decode_native_terrain_volume_v2(
            replace_member(std::move(root), "sections", NativeValue::array(std::move(sections)))));
    }
    VWB_EXPECT_THROW(NativeTerrainVolumeV2Rejected, decode_native_terrain_volume_v2(
        replace_first_section_member(encoded, "originCell", NativeValue::array({NativeValue::number(0.0), NativeValue::number(0.0), NativeValue::number(0.0)}))));
    VWB_EXPECT_THROW(NativeTerrainVolumeV2Rejected, decode_native_terrain_volume_v2(
        replace_first_section_member(encoded, "cells", NativeValue::array({}))));
    VWB_EXPECT_THROW(NativeTerrainVolumeV2Rejected, decode_native_terrain_volume_v2(
        replace_first_cell_member(encoded, "cell", NativeValue::array({NativeValue::number(0.0), NativeValue::number(0.0)}))));
    {
        NativeValue::Object root = encoded.as_object();
        NativeValue::Array sections = root[3].second.as_array();
        NativeValue::Object section = sections[0].as_object();
        NativeValue::Array cells = section[0].second.as_array();
        cells[0] = rename_member(cells[0].as_object(), "local", "loCal");
        sections[0] = replace_member(std::move(section), "cells", NativeValue::array(std::move(cells)));
        VWB_EXPECT_THROW(NativeTerrainVolumeV2Rejected, decode_native_terrain_volume_v2(
            replace_member(std::move(root), "sections", NativeValue::array(std::move(sections)))));
    }
    {
        NativeValue::Object root = encoded.as_object();
        NativeValue::Array sections = root[3].second.as_array();
        NativeValue::Object section = sections[0].as_object();
        NativeValue::Array cells = section[0].second.as_array();
        cells[0] = replace_member(cells[0].as_object(), "cell", NativeValue::array({
            NativeValue::number(16.0), NativeValue::number(0.0), NativeValue::number(0.0)}));
        cells[0] = replace_member(cells[0].as_object(), "local", NativeValue::array({
            NativeValue::number(0.0), NativeValue::number(0.0), NativeValue::number(0.0)}));
        sections[0] = replace_member(std::move(section), "cells", NativeValue::array(std::move(cells)));
        VWB_EXPECT_THROW(NativeTerrainVolumeV2Rejected, decode_native_terrain_volume_v2(
            replace_member(std::move(root), "sections", NativeValue::array(std::move(sections)))));
    }
    const NativeValue state = encoded.as_object()[3].second.as_array()[0].as_object()[0].second.as_array()[0].as_object()[2].second;
    VWB_EXPECT_THROW(NativeTerrainVolumeV2Rejected, decode_native_terrain_volume_v2(
        replace_first_state(encoded, replace_member(state.as_object(), "blockId", NativeValue::number(1.0)))));
    VWB_EXPECT_THROW(NativeTerrainVolumeV2Rejected, decode_native_terrain_volume_v2(
        replace_first_state(encoded, replace_member(state.as_object(), "material", NativeValue::string("unknown")))));
    VWB_EXPECT_THROW(NativeTerrainVolumeV2Rejected, decode_native_terrain_volume_v2(
        replace_first_state(encoded, replace_member(state.as_object(), "material", NativeValue::string("deep_stone")))));
    VWB_EXPECT_THROW(NativeTerrainVolumeV2Rejected, decode_native_terrain_volume_v2(
        replace_first_state(encoded, replace_member(state.as_object(), "biome", NativeValue::string("unknown")))));
    VWB_EXPECT_THROW(NativeTerrainVolumeV2Rejected, decode_native_terrain_volume_v2(
        replace_first_state(encoded, replace_member(state.as_object(), "fluid", NativeValue::string("unknown")))));
    VWB_EXPECT_THROW(NativeTerrainVolumeV2Rejected, decode_native_terrain_volume_v2(
        replace_first_state(encoded, replace_member(state.as_object(), "solid", NativeValue::number(1.0)))));
    VWB_EXPECT_THROW(NativeTerrainVolumeV2Rejected, decode_native_terrain_volume_v2(
        replace_first_state(encoded, replace_member(state.as_object(), "density", NativeValue::string("one")))));
    VWB_EXPECT_THROW(NativeTerrainVolumeV2Rejected, decode_native_terrain_volume_v2(
        replace_first_state(encoded, replace_member(state.as_object(), "metadata", NativeValue::array({})) )));
    NativeValue::Object light_state = state.as_object();
    NativeValue::Object light = light_state[8].second.as_object();
    light[0].second = NativeValue::number(16.0);
    light_state[8].second = NativeValue::object(std::move(light));
    VWB_EXPECT_THROW(NativeTerrainVolumeV2Rejected, decode_native_terrain_volume_v2(
        replace_first_state(encoded, NativeValue::object(std::move(light_state)))));
    NativeValue::Object bad_light_state = state.as_object();
    bad_light_state[8].second = NativeValue::object({{"only", NativeValue::number(0.0)}});
    VWB_EXPECT_THROW(NativeTerrainVolumeV2Rejected, decode_native_terrain_volume_v2(
        replace_first_state(encoded, NativeValue::object(std::move(bad_light_state)))));
    VWB_EXPECT_THROW(NativeTerrainVolumeV2Rejected, decode_native_terrain_volume_v2(
        replace_first_state(encoded, replace_member(state.as_object(), "cell",
            NativeValue::array({NativeValue::number(1.0), NativeValue::number(0.0), NativeValue::number(0.0)})))));
    VWB_EXPECT_THROW(NativeTerrainVolumeV2Rejected, decode_native_terrain_volume_v2(
        replace_first_state(encoded, replace_member(state.as_object(), "sectionKey",
            NativeValue::array({NativeValue::number(1.0), NativeValue::number(0.0), NativeValue::number(0.0)})))));
    VWB_EXPECT_THROW(NativeTerrainVolumeV2Rejected, decode_native_terrain_volume_v2(
        replace_first_state(encoded, replace_member(state.as_object(), "localCell",
            NativeValue::array({NativeValue::number(0.0), NativeValue::number(0.0), NativeValue::number(0.0)})))));
    VWB_EXPECT_THROW(NativeTerrainVolumeV2Rejected, decode_native_terrain_volume_v2(
        replace_first_state(encoded, replace_member(state.as_object(), "localCell",
            NativeValue::array({NativeValue::number(15.0), NativeValue::number(0.0), NativeValue::number(15.0)})))));
    VWB_EXPECT_THROW(NativeTerrainVolumeV2Rejected, decode_native_terrain_volume_v2(
        replace_first_state(encoded, replace_member(state.as_object(), "localCell",
            NativeValue::array({NativeValue::number(15.0), NativeValue::number(15.0), NativeValue::number(0.0)})))));
    VWB_EXPECT_THROW(NativeTerrainVolumeV2Rejected, decode_native_terrain_volume_v2(
        replace_first_state(encoded, replace_member(state.as_object(), "generated", NativeValue::boolean(true)))));
    VWB_EXPECT_THROW(NativeTerrainVolumeV2Rejected, decode_native_terrain_volume_v2(
        replace_first_state(encoded, replace_member(state.as_object(), "edited", NativeValue::boolean(false)))));
    VWB_EXPECT_THROW(NativeTerrainVolumeV2Rejected, decode_native_terrain_volume_v2(
        replace_first_state(encoded, replace_member(state.as_object(), "blockId", NativeValue::string("")))));
    VWB_EXPECT_THROW(NativeTerrainVolumeV2Rejected, decode_native_terrain_volume_v2(
        replace_first_state(encoded, replace_member(state.as_object(), "density", NativeValue::number(-1.0)))));
    VWB_EXPECT_THROW(NativeTerrainVolumeV2Rejected, decode_native_terrain_volume_v2(
        replace_first_cell_member(encoded, "cell", NativeValue::array({NativeValue::number(2147483648.0), NativeValue::number(0.0), NativeValue::number(0.0)}))));
    VWB_EXPECT_THROW(NativeTerrainVolumeV2Rejected, decode_native_terrain_volume_v2(
        replace_first_cell_member(encoded, "cell", NativeValue::array({NativeValue::number(-2147483649.0), NativeValue::number(0.0), NativeValue::number(0.0)}))));
    VWB_EXPECT_THROW(NativeTerrainVolumeV2Rejected, decode_native_terrain_volume_v2(
        replace_first_cell_member(encoded, "cell", NativeValue::array({NativeValue::number(0.5), NativeValue::number(0.0), NativeValue::number(0.0)}))));
    VWB_EXPECT_THROW(NativeTerrainVolumeV2Rejected, decode_native_terrain_volume_v2(
        replace_first_cell_member(encoded, "cell", NativeValue::array({NativeValue::boolean(true), NativeValue::number(0.0), NativeValue::number(0.0)}))));
    const NativeValue enum_encoded = encode_native_terrain_volume_v2(enum_coverage_volume());
    VWB_EXPECT_THROW(NativeTerrainVolumeV2Rejected, decode_native_terrain_volume_v2(swap_first_section_cells(enum_encoded)));
    VWB_EXPECT_THROW(NativeTerrainVolumeV2Rejected, decode_native_terrain_volume_v2(swap_sections(encoded)));
    VWB_EXPECT(decode_native_terrain_volume_v2(encode_native_terrain_volume_v2(y_order_volume())) == y_order_volume());
}

VWB_TEST(native_terrain_volume_v2_codec_rejects_incomplete_or_inconsistent_encode_aggregates) {
    NativeTerrainVolumeV2 empty;
    empty.revision = 0U;
    empty.durable_snapshot = NativeTypedWorldStateSnapshot::create({});
    const NativeValue encoded_empty = encode_native_terrain_volume_v2(empty);
    VWB_EXPECT_EQ(0U, decode_native_terrain_volume_v2(encoded_empty).durable_snapshot.records().size());

    NativeTerrainVolumeV2 no_revisions = sample_volume();
    no_revisions.section_revisions.clear();
    VWB_EXPECT_THROW(NativeTerrainVolumeV2Rejected, encode_native_terrain_volume_v2(no_revisions));
    NativeTerrainVolumeV2 too_large_revision = sample_volume();
    too_large_revision.revision = 9007199254740993ULL;
    VWB_EXPECT_THROW(NativeTerrainVolumeV2Rejected, encode_native_terrain_volume_v2(too_large_revision));
    NativeTerrainVolumeV2 too_large_section_revision = sample_volume();
    too_large_section_revision.section_revisions[0].revision = 9007199254740993ULL;
    VWB_EXPECT_THROW(NativeTerrainVolumeV2Rejected, encode_native_terrain_volume_v2(too_large_section_revision));
    NativeTerrainVolumeV2 duplicate_section = sample_volume();
    duplicate_section.section_revisions[1].section = duplicate_section.section_revisions[0].section;
    VWB_EXPECT_THROW(NativeTerrainVolumeV2Rejected, encode_native_terrain_volume_v2(duplicate_section));
    NativeTerrainVolumeV2 unrelated_section = sample_volume();
    unrelated_section.section_revisions[0].section = {0, 0, -1};
    VWB_EXPECT_THROW(NativeTerrainVolumeV2Rejected, encode_native_terrain_volume_v2(unrelated_section));
    NativeTerrainVolumeV2 incomplete_sections = sample_volume();
    incomplete_sections.section_revisions.pop_back();
    VWB_EXPECT_THROW(NativeTerrainVolumeV2Rejected, encode_native_terrain_volume_v2(incomplete_sections));
    NativeTerrainVolumeV2 overflowing_origin = sample_volume();
    overflowing_origin.section_revisions[1].section = {2147483647, 0, 0};
    VWB_EXPECT_THROW(NativeTerrainVolumeV2Rejected, encode_native_terrain_volume_v2(overflowing_origin));
}
