#include "test_harness.hpp"

#include "../core/native_cell_state.hpp"

#include <cmath>
#include <limits>
#include <type_traits>
#include <vector>

using namespace voxel::world_backend;

static_assert(!std::is_convertible_v<NativeSurfaceColumnFacts, NativeCellState>);
static_assert(!std::is_convertible_v<NativeLatticeNumericFacts, NativeCellState>);

namespace {

NativeCellStateInput air(const CellCoord cell = {0, 0, 0}) {
    NativeCellStateInput value;
    value.cell = cell;
    value.material = TerrainMaterialId::air;
    value.biome = TerrainBiomeId::underground_air;
    value.solid = false;
    value.density = -1.35;
    value.fluid = TerrainFluidId::none;
    value.light = {0, 0};
    return value;
}

NativeCellStateInput stone(const CellCoord cell) {
    NativeCellStateInput value = air(cell);
    value.material = TerrainMaterialId::stone;
    value.biome = TerrainBiomeId::underground;
    value.solid = true;
    value.density = 1.35;
    return value;
}

NativeCellStateInput lava(const CellCoord cell) {
    NativeCellStateInput value = air(cell);
    value.material = TerrainMaterialId::lava;
    value.fluid = TerrainFluidId::lava;
    value.density = -0.25;
    return value;
}

} // namespace

VWB_TEST(native_cell_state_derives_exact_negative_section_address_and_x_y_z_index) {
    const NativeCellState state = make_native_cell_state(stone({-1, -16, -17}));
    VWB_EXPECT((state.section == CellCoord{-1, -1, -2}));
    VWB_EXPECT((state.local_cell == CellCoord{15, 0, 15}));
    VWB_EXPECT_EQ(3855U, native_cell_state_section_index(state));

    const NativeCellState zero = make_native_cell_state(air({16, 31, 32}));
    VWB_EXPECT((zero.section == CellCoord{1, 1, 2}));
    VWB_EXPECT((zero.local_cell == CellCoord{0, 15, 0}));
    VWB_EXPECT_EQ(240U, native_cell_state_section_index(zero));
}

VWB_TEST(native_cell_state_preserves_only_normalized_fields_and_canonicalizes_metadata) {
    NativeCellStateInput input = stone({4, 5, 6});
    input.metadata = {{"source", "dig"}, {"saveDelta", "true"}};
    const NativeCellState state = make_native_cell_state(input);
    VWB_EXPECT_EQ(2U, state.metadata.size());
    VWB_EXPECT_EQ(std::string("saveDelta"), state.metadata[0].key);
    VWB_EXPECT_EQ(std::string("source"), state.metadata[1].key);
    VWB_EXPECT(state.generated);
    VWB_EXPECT(!state.edited);
}

VWB_TEST(native_cell_state_accepts_lava_as_non_solid_typed_fluid) {
    const NativeCellState state = make_native_cell_state(lava({2, -55, 3}));
    VWB_EXPECT_EQ(TerrainMaterialId::lava, state.material);
    VWB_EXPECT_EQ(TerrainFluidId::lava, state.fluid);
    VWB_EXPECT(!state.solid);
}

VWB_TEST(native_cell_state_rejects_malformed_density_solid_fluid_and_light_combinations) {
    NativeCellStateInput invalid = stone({0, 0, 0});
    invalid.density = -0.1;
    VWB_EXPECT_THROW(NativeCellStateRejected, make_native_cell_state(invalid));
    invalid = stone({0, 0, 0});
    invalid.fluid = TerrainFluidId::water;
    invalid.material = TerrainMaterialId::water;
    VWB_EXPECT_THROW(NativeCellStateRejected, make_native_cell_state(invalid));
    invalid = air();
    invalid.material = TerrainMaterialId::water;
    VWB_EXPECT_THROW(NativeCellStateRejected, make_native_cell_state(invalid));
    invalid = air();
    invalid.light.sky = 16;
    VWB_EXPECT_THROW(NativeCellStateRejected, make_native_cell_state(invalid));
    invalid = air();
    invalid.density = std::numeric_limits<double>::quiet_NaN();
    VWB_EXPECT_THROW(NativeCellStateRejected, make_native_cell_state(invalid));
}

VWB_TEST(native_cell_state_rejects_invalid_metadata_and_generated_edited_ambiguity) {
    NativeCellStateInput invalid = air();
    invalid.metadata = {{"", "empty"}};
    VWB_EXPECT_THROW(NativeCellStateRejected, make_native_cell_state(invalid));
    invalid = air();
    invalid.metadata = {{"source", "first"}, {"source", "second"}};
    VWB_EXPECT_THROW(NativeCellStateRejected, make_native_cell_state(invalid));
    invalid = air();
    invalid.edited = true;
    VWB_EXPECT_THROW(NativeCellStateRejected, make_native_cell_state(invalid));
}

VWB_TEST(native_cell_state_policy_keeps_scene_overlay_out_of_durable_save_and_terrain_projection) {
    const NativeCellStatePersistencePolicy durable = native_cell_state_policy(NativeCellStateNamespace::durable_terrain);
    VWB_EXPECT(durable.persists_in_save);
    VWB_EXPECT(durable.affects_terrain_mesh);
    VWB_EXPECT(durable.affects_surface_projection);
    const NativeCellStatePersistencePolicy overlay = native_cell_state_policy(NativeCellStateNamespace::scene_overlay);
    VWB_EXPECT(!overlay.persists_in_save);
    VWB_EXPECT(!overlay.affects_terrain_mesh);
    VWB_EXPECT(!overlay.affects_surface_projection);

    NativeCellStateInput scene = air({9, 8, 7});
    scene.generated = false;
    scene.edited = true;
    VWB_EXPECT_EQ((CellCoord{9, 8, 7}), make_native_cell_state(scene, NativeCellStateNamespace::scene_overlay).cell);
    VWB_EXPECT_THROW(NativeCellStateRejected, make_native_cell_state(air({9, 8, 7}), NativeCellStateNamespace::scene_overlay));
}

VWB_TEST(native_cell_state_v2_save_order_is_z_then_y_then_x_even_across_negative_sections) {
    std::vector<NativeCellState> states;
    states.push_back(make_native_cell_state(air({0, 0, 0})));
    states.push_back(make_native_cell_state(air({-20, 7, -1})));
    states.push_back(make_native_cell_state(air({5, -2, -1})));
    states.push_back(make_native_cell_state(air({-8, -2, -1})));
    const std::vector<NativeCellState> sorted = sort_native_cell_states_v2_for_save(std::move(states));
    VWB_EXPECT((sorted[0].cell == CellCoord{-8, -2, -1}));
    VWB_EXPECT((sorted[1].cell == CellCoord{5, -2, -1}));
    VWB_EXPECT((sorted[2].cell == CellCoord{-20, 7, -1}));
    VWB_EXPECT((sorted[3].cell == CellCoord{0, 0, 0}));
}

VWB_TEST(native_cell_state_v2_save_rejects_duplicate_cells) {
    std::vector<NativeCellState> states;
    states.push_back(make_native_cell_state(air({1, 2, 3})));
    states.push_back(make_native_cell_state(lava({1, 2, 3})));
    VWB_EXPECT_THROW(NativeCellStateRejected, sort_native_cell_states_v2_for_save(std::move(states)));
}

VWB_TEST(native_cell_state_index_rejects_state_with_forged_section_or_local_address) {
    NativeCellState state = make_native_cell_state(air({-1, -1, -1}));
    state.section = {0, 0, 0};
    VWB_EXPECT_THROW(NativeCellStateRejected, native_cell_state_section_index(state));
}
