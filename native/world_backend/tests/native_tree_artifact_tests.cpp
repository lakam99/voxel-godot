#include "test_harness.hpp"

#include "../core/native_tree_artifact.hpp"

#include <algorithm>
#include <cmath>
#include <cstdint>
#include <limits>
#include <string>
#include <tuple>
#include <utility>
#include <vector>

using namespace voxel::world_backend;

namespace voxel::world_backend {
struct NativeTreeArtifactBuilderTestAccess final {
    static void validate(
        const NativeTreeDefinitionInput &definition,
        const NativeTreeTrunkCylinder trunk_cylinder,
        const NativeTreeRenderTier render_tier,
        const std::uint32_t source_branch_count,
        const std::vector<NativeTreeArtifactBranch> &branches,
        const std::vector<NativeTreeArtifactFoliage> &foliage,
        const NativeTreeArtifactImpostor impostor,
        const NativeTreeArtifactFootprint &footprint) {
        NativeTreeArtifactBuilder::validate_complete_for_test(
            definition, trunk_cylinder, render_tier, source_branch_count,
            branches, foliage, impostor, footprint);
    }
};
}

namespace {

Sha256Digest digest(const std::string &value) {
    return sha256(std::vector<std::uint8_t>(value.begin(), value.end()));
}

NativeTreeDefinition tree(
    const NativeTreeArchitecture architecture,
    const std::string &family,
    const std::string &grammar,
    const NativeTreeCoordinateFrame frame = NativeTreeCoordinateFrame::world) {
    NativeTreeDefinitionInput input;
    input.schema_revision = 1U;
    input.producer_key = "tree-artifact-test";
    input.producer_revision = 7U;
    input.source_recipe_digest = digest(std::string("source:") + family);
    input.feature_kind = frame == NativeTreeCoordinateFrame::world
        ? NativeTreeFeatureKind::natural_surface_tree : NativeTreeFeatureKind::site_tree;
    input.durable_feature_id = "tree:atlas:4,7:" + family;
    input.recipe_tree_id = input.durable_feature_id;
    input.world_seed = "atlas-1492";
    input.biome = architecture == NativeTreeArchitecture::conifer ? "taiga"
        : architecture == NativeTreeArchitecture::savanna ? "savanna" : "forest";
    input.family = family;
    input.growth_class = "mature";
    input.age_band = "mature";
    input.architecture = architecture;
    input.species_grammar = grammar;
    input.coordinate_frame = frame;
    input.coordinate_owner_id = frame == NativeTreeCoordinateFrame::owner_local ? "citadel:atlas" : "";
    input.position = {10.0, 3.0, -5.0};
    input.rotation_y = 0.37;
    input.ecology = {55.0, 40.0, 70.0, 0.72, 0.82, 0x4D415448};
    input.biome_parameters = {2U, 18.0, 60.0, 0.5, 3.0, 4.0, 18.0,
        0.88, 1.25, 350.0, 170.0, 0.4};
    input.visual_height = 26.0;
    input.trunk_radius = 1.1;
    input.canopy_radius = 8.0;
    input.collision_height = architecture == NativeTreeArchitecture::conifer ? input.visual_height * 0.82
        : architecture == NativeTreeArchitecture::savanna ? input.visual_height * 0.52
        : input.visual_height * 0.46;
    input.exclusion_margin = 0.4;
    input.old_growth = false;
    return NativeTreeDefinition::create(std::move(input));
}

} // namespace

VWB_TEST(native_tree_artifact_compiles_complete_revision_bound_conifer_inputs_for_every_render_tier) {
    const NativeTreeDefinition source = tree(
        NativeTreeArchitecture::conifer, "ecological_conifer_tree", "norway_spruce");
    Sha256Digest previous{};
    for (const NativeTreeRenderTier tier : {NativeTreeRenderTier::near, NativeTreeRenderTier::mid,
            NativeTreeRenderTier::far, NativeTreeRenderTier::impostor}) {
        const NativeTreeArtifact artifact = NativeTreeArtifactBuilder::build(source, tier);
        VWB_EXPECT(artifact.complete());
        VWB_EXPECT_EQ(NativeTreeArtifactStatus::complete, artifact.status());
        VWB_EXPECT_EQ(tier, artifact.render_tier());
        VWB_EXPECT_EQ(source.content_digest(), artifact.source_definition_digest());
        VWB_EXPECT_EQ(std::string("native_norway_spruce_worker_recipe"), artifact.recipe_builder_key());
        VWB_EXPECT_EQ(std::uint32_t(10U), artifact.recipe_builder_revision());
        VWB_EXPECT(!artifact.recipe_signature().empty());
        VWB_EXPECT(!artifact.topology_signature().empty());
        VWB_EXPECT(artifact.native_recipe_digest() != Sha256Digest{});
        VWB_EXPECT_EQ(source.input(), artifact.definition());
        VWB_EXPECT_EQ(source.trunk_cylinder(), artifact.trunk_cylinder());
        VWB_EXPECT_EQ(tier == NativeTreeRenderTier::impostor, artifact.source_branch_count() == 0U);
        VWB_EXPECT(artifact.footprint().collision_complete);
        VWB_EXPECT(artifact.footprint().render_complete);
        VWB_EXPECT_EQ(NativeTreeCoordinateFrame::world, artifact.footprint().coordinate_frame);
        VWB_EXPECT(artifact.footprint().coordinate_owner_id.empty());
        VWB_EXPECT_EQ(8.0F, artifact.impostor().canopy_radius);
        VWB_EXPECT_EQ(26.0F, artifact.impostor().height);
        VWB_EXPECT(!artifact.canonical_binary().empty());
        VWB_EXPECT(artifact.content_digest() != Sha256Digest{});
        if (tier == NativeTreeRenderTier::impostor) {
            VWB_EXPECT(artifact.branches().empty());
            VWB_EXPECT(artifact.foliage().empty());
            VWB_EXPECT(!artifact.footprint().render_bounds_provisional);
        } else {
            VWB_EXPECT(!artifact.branches().empty());
            VWB_EXPECT(!artifact.foliage().empty());
            VWB_EXPECT(!artifact.footprint().render_bounds_provisional);
            VWB_EXPECT(artifact.branches().front().radius_start > 0.0);
            VWB_EXPECT(std::isfinite(artifact.foliage().front().variation));
        }
        VWB_EXPECT(artifact.footprint().collision_bounds.minimum.y == 3.0);
        VWB_EXPECT(std::abs(artifact.footprint().collision_bounds.maximum.y - 24.32) < 1e-6);
        VWB_EXPECT(artifact.footprint().render_bounds.maximum.y > artifact.footprint().render_bounds.minimum.y);
        if (previous != Sha256Digest{}) VWB_EXPECT(previous != artifact.content_digest());
        previous = artifact.content_digest();
    }
}

VWB_TEST(native_tree_artifact_is_deterministic_and_value_semantics_cover_every_public_record) {
    const NativeTreeDefinition source = tree(
        NativeTreeArchitecture::conifer, "ecological_conifer_tree", "norway_spruce",
        NativeTreeCoordinateFrame::owner_local);
    const NativeTreeArtifact first = NativeTreeArtifactBuilder::build(source, NativeTreeRenderTier::far);
    const NativeTreeArtifact second = NativeTreeArtifactBuilder::build(source, NativeTreeRenderTier::far);
    VWB_EXPECT(first == second);
    VWB_EXPECT(!(first != second));
    VWB_EXPECT_EQ(std::string("citadel:atlas"), first.footprint().coordinate_owner_id);
    VWB_EXPECT_EQ(NativeTreeCoordinateFrame::owner_local, first.footprint().coordinate_frame);
    VWB_EXPECT(first.footprint() == second.footprint());
    VWB_EXPECT(first.branches().front() == second.branches().front());
    VWB_EXPECT(first.foliage().front() == second.foliage().front());
    VWB_EXPECT(first.impostor() == second.impostor());
    VWB_EXPECT(first.footprint().render_bounds == second.footprint().render_bounds);
    NativeTreeArtifactVec3 changed_vec = first.branches().front().start;
    changed_vec.x += 1.0F;
    VWB_EXPECT(!(changed_vec == first.branches().front().start));
    NativeTreeArtifactBranch changed_branch = first.branches().front();
    ++changed_branch.order;
    VWB_EXPECT(!(changed_branch == first.branches().front()));
    NativeTreeArtifactFoliage changed_foliage = first.foliage().front();
    ++changed_foliage.cluster_variant;
    VWB_EXPECT(!(changed_foliage == first.foliage().front()));
    NativeTreeArtifactImpostor changed_impostor = first.impostor();
    changed_impostor.height += 1.0F;
    VWB_EXPECT(!(changed_impostor == first.impostor()));
    NativeTreeArtifactBounds changed_bounds = first.footprint().render_bounds;
    changed_bounds.maximum.y += 1.0;
    VWB_EXPECT(!(changed_bounds == first.footprint().render_bounds));
    NativeTreeArtifactFootprint changed_footprint = first.footprint();
    changed_footprint.render_complete = false;
    VWB_EXPECT(!(changed_footprint == first.footprint()));
    VWB_EXPECT(first.content_digest() == sha256(first.canonical_binary()));
    const NativeTreeArtifact near = NativeTreeArtifactBuilder::build(source, NativeTreeRenderTier::near);
    VWB_EXPECT(first != near);
}

VWB_TEST(native_tree_artifact_keeps_broadleaf_render_authority_explicitly_pending) {
    const NativeTreeArtifact broadleaf = NativeTreeArtifactBuilder::build(tree(
        NativeTreeArchitecture::broadleaf, "ecological_broadleaf_tree", "bushy_oak"),
        NativeTreeRenderTier::near);
    VWB_EXPECT(!broadleaf.complete());
    VWB_EXPECT_EQ(NativeTreeArtifactStatus::broadleaf_recipe_pending, broadleaf.status());
    for (const NativeTreeArtifact *artifact : {&broadleaf}) {
        VWB_EXPECT(artifact->branches().empty());
        VWB_EXPECT(artifact->foliage().empty());
        VWB_EXPECT(artifact->recipe_signature().empty());
        VWB_EXPECT(artifact->topology_signature().empty());
        VWB_EXPECT_EQ(std::string("native_tree_recipe_pending"), artifact->recipe_builder_key());
        VWB_EXPECT_EQ(std::uint32_t(1U), artifact->recipe_builder_revision());
        VWB_EXPECT_EQ(Sha256Digest{}, artifact->native_recipe_digest());
        VWB_EXPECT(artifact->footprint().collision_complete);
        VWB_EXPECT(!artifact->footprint().render_complete);
        VWB_EXPECT(artifact->footprint().render_bounds_provisional);
        VWB_EXPECT(artifact->footprint().render_bounds.maximum.x
            > artifact->footprint().render_bounds.minimum.x);
        VWB_EXPECT(artifact->content_digest() != Sha256Digest{});
    }
}

VWB_TEST(native_tree_artifact_compiles_complete_savanna_inputs_for_every_render_tier) {
    const NativeTreeDefinition source = tree(
        NativeTreeArchitecture::savanna, "ecological_savanna_tree", "umbrella_thorn");
    Sha256Digest previous{};
    for (const NativeTreeRenderTier tier : {NativeTreeRenderTier::near, NativeTreeRenderTier::mid,
            NativeTreeRenderTier::far, NativeTreeRenderTier::impostor}) {
        const NativeTreeArtifact artifact = NativeTreeArtifactBuilder::build(source, tier);
        VWB_EXPECT(artifact.complete());
        VWB_EXPECT_EQ(NativeTreeArtifactStatus::complete, artifact.status());
        VWB_EXPECT_EQ(std::string("native_umbrella_thorn_worker_recipe"), artifact.recipe_builder_key());
        VWB_EXPECT_EQ(std::uint32_t(10U), artifact.recipe_builder_revision());
        VWB_EXPECT(!artifact.recipe_signature().empty());
        VWB_EXPECT(!artifact.topology_signature().empty());
        VWB_EXPECT(artifact.native_recipe_digest() != Sha256Digest{});
        VWB_EXPECT_EQ(source.trunk_cylinder(), artifact.trunk_cylinder());
        VWB_EXPECT_EQ(tier == NativeTreeRenderTier::impostor, artifact.source_branch_count() == 0U);
        VWB_EXPECT(artifact.footprint().collision_complete && artifact.footprint().render_complete);
        VWB_EXPECT(!artifact.footprint().render_bounds_provisional);
        if (tier == NativeTreeRenderTier::impostor) {
            VWB_EXPECT(artifact.branches().empty());VWB_EXPECT(artifact.foliage().empty());
        } else {
            VWB_EXPECT(!artifact.branches().empty());VWB_EXPECT(!artifact.foliage().empty());
        }
        if (previous != Sha256Digest{}) VWB_EXPECT(previous != artifact.content_digest());
        previous = artifact.content_digest();
    }
}

VWB_TEST(native_tree_artifact_rotated_owner_local_bounds_match_an_independent_yaw_fixture) {
    NativeTreeDefinitionInput world_input = tree(
        NativeTreeArchitecture::conifer, "ecological_conifer_tree", "norway_spruce").input();
    world_input.position = {100.0, 4.0, -30.0};
    world_input.rotation_y = 1.57079632679489661923;
    const NativeTreeArtifact world = NativeTreeArtifactBuilder::build(
        NativeTreeDefinition::create(world_input), NativeTreeRenderTier::far);

    NativeTreeDefinitionInput local_input = world_input;
    local_input.feature_kind = NativeTreeFeatureKind::site_tree;
    local_input.coordinate_frame = NativeTreeCoordinateFrame::owner_local;
    local_input.coordinate_owner_id = "citadel:rotated-bounds";
    local_input.position = {7.0, 2.0, 11.0};
    const NativeTreeArtifact local = NativeTreeArtifactBuilder::build(
        NativeTreeDefinition::create(local_input), NativeTreeRenderTier::far);

    double min_x = std::numeric_limits<double>::infinity();
    double min_y = std::numeric_limits<double>::infinity();
    double min_z = std::numeric_limits<double>::infinity();
    double max_x = -std::numeric_limits<double>::infinity();
    double max_y = -std::numeric_limits<double>::infinity();
    double max_z = -std::numeric_limits<double>::infinity();
    const auto include = [&](const NativeTreeArtifactVec3 &position, const double extent) {
        min_x = std::min(min_x, static_cast<double>(position.x) - extent);
        min_y = std::min(min_y, static_cast<double>(position.y) - extent);
        min_z = std::min(min_z, static_cast<double>(position.z) - extent);
        max_x = std::max(max_x, static_cast<double>(position.x) + extent);
        max_y = std::max(max_y, static_cast<double>(position.y) + extent);
        max_z = std::max(max_z, static_cast<double>(position.z) + extent);
    };
    for (const NativeTreeArtifactBranch &branch : local.branches()) {
        include(branch.start, branch.radius_start);
        include(branch.end, branch.radius_end);
    }
    for (const NativeTreeArtifactFoliage &anchor : local.foliage()) {
        include(anchor.position, std::max({std::abs(anchor.scale.x),
            std::abs(anchor.scale.y), std::abs(anchor.scale.z)}));
    }
    const NativeTreeArtifactBounds &bounds = local.footprint().render_bounds;
    const auto close = [](const double expected, const double actual) {
        VWB_EXPECT(std::abs(expected - actual) < 0.00001);
    };
    // At +90 degrees: x' = z and z' = -x. The owner-local translation is
    // applied after yaw, not baked into the native branch topology.
    close(local_input.position.x + min_z, bounds.minimum.x);
    close(local_input.position.x + max_z, bounds.maximum.x);
    close(local_input.position.y + min_y, bounds.minimum.y);
    close(local_input.position.y + max_y, bounds.maximum.y);
    close(local_input.position.z - max_x, bounds.minimum.z);
    close(local_input.position.z - min_x, bounds.maximum.z);

    const NativeTreeArtifactBounds &world_bounds = world.footprint().render_bounds;
    close(93.0, world_bounds.minimum.x - bounds.minimum.x);
    close(2.0, world_bounds.minimum.y - bounds.minimum.y);
    close(-41.0, world_bounds.minimum.z - bounds.minimum.z);
    close(93.0, world_bounds.maximum.x - bounds.maximum.x);
    close(2.0, world_bounds.maximum.y - bounds.maximum.y);
    close(-41.0, world_bounds.maximum.z - bounds.maximum.z);
    close(5.9, local.footprint().collision_bounds.minimum.x);
    close(2.0, local.footprint().collision_bounds.minimum.y);
    close(9.9, local.footprint().collision_bounds.minimum.z);
    close(8.1, local.footprint().collision_bounds.maximum.x);
    close(23.32, local.footprint().collision_bounds.maximum.y);
    close(12.1, local.footprint().collision_bounds.maximum.z);
}

VWB_TEST(native_tree_artifact_rejects_unknown_tiers_grammars_and_inconsistent_collision_contracts) {
    const NativeTreeDefinition conifer = tree(
        NativeTreeArchitecture::conifer, "ecological_conifer_tree", "norway_spruce");
    VWB_EXPECT_THROW(NativeTreeArtifactRejected, NativeTreeArtifactBuilder::build(
        conifer, static_cast<NativeTreeRenderTier>(0U)));
    VWB_EXPECT_THROW(NativeTreeArtifactRejected, NativeTreeArtifactBuilder::build(tree(
        NativeTreeArchitecture::conifer, "ecological_conifer_tree", "bushy_oak"),
        NativeTreeRenderTier::near));
    VWB_EXPECT_THROW(NativeTreeArtifactRejected, NativeTreeArtifactBuilder::build(tree(
        NativeTreeArchitecture::broadleaf, "ecological_broadleaf_tree", "rounded_broadleaf"),
        NativeTreeRenderTier::near));
    VWB_EXPECT_THROW(NativeTreeArtifactRejected, NativeTreeArtifactBuilder::build(tree(
        NativeTreeArchitecture::savanna, "ecological_savanna_tree", "bushy_oak"),
        NativeTreeRenderTier::near));

    NativeTreeDefinitionInput inconsistent = conifer.input();
    inconsistent.collision_height -= 0.5;
    const NativeTreeDefinition valid_but_inconsistent = NativeTreeDefinition::create(std::move(inconsistent));
    VWB_EXPECT_THROW(NativeTreeArtifactRejected, NativeTreeArtifactBuilder::build(
        valid_but_inconsistent, NativeTreeRenderTier::near));

    NativeTreeDefinitionInput low_trunk = conifer.input();
    low_trunk.trunk_radius = 0.15;
    VWB_EXPECT_THROW(NativeTreeArtifactRejected, NativeTreeArtifactBuilder::build(
        NativeTreeDefinition::create(std::move(low_trunk)), NativeTreeRenderTier::impostor));
    NativeTreeDefinitionInput narrow_canopy = conifer.input();
    narrow_canopy.trunk_radius = 0.18;
    narrow_canopy.canopy_radius = 0.20;
    VWB_EXPECT_THROW(NativeTreeArtifactRejected, NativeTreeArtifactBuilder::build(
        NativeTreeDefinition::create(std::move(narrow_canopy)), NativeTreeRenderTier::impostor));
    NativeTreeDefinitionInput low_height = conifer.input();
    low_height.visual_height = 3.0;
    low_height.collision_height = 2.46;
    VWB_EXPECT_THROW(NativeTreeArtifactRejected, NativeTreeArtifactBuilder::build(
        NativeTreeDefinition::create(std::move(low_height)), NativeTreeRenderTier::impostor));

    NativeTreeDefinitionInput enormous_height = conifer.input();
    enormous_height.visual_height = static_cast<double>(std::numeric_limits<float>::max()) * 2.0;
    VWB_EXPECT_THROW(NativeTreeArtifactRejected, NativeTreeArtifactBuilder::build(
        NativeTreeDefinition::create(std::move(enormous_height)), NativeTreeRenderTier::impostor));
    NativeTreeDefinitionInput enormous_canopy = conifer.input();
    enormous_canopy.canopy_radius = static_cast<double>(std::numeric_limits<float>::max()) * 2.0;
    VWB_EXPECT_THROW(NativeTreeArtifactRejected, NativeTreeArtifactBuilder::build(
        NativeTreeDefinition::create(std::move(enormous_canopy)), NativeTreeRenderTier::impostor));

    const NativeTreeDefinition savanna = tree(
        NativeTreeArchitecture::savanna, "ecological_savanna_tree", "umbrella_thorn");
    NativeTreeDefinitionInput savanna_collision = savanna.input();
    savanna_collision.collision_height -= 0.5;
    VWB_EXPECT_THROW(NativeTreeArtifactRejected, NativeTreeArtifactBuilder::build(
        NativeTreeDefinition::create(std::move(savanna_collision)), NativeTreeRenderTier::near));
    NativeTreeDefinitionInput savanna_height = savanna.input();
    savanna_height.visual_height = static_cast<double>(std::numeric_limits<float>::max()) * 2.0;
    VWB_EXPECT_THROW(NativeTreeArtifactRejected, NativeTreeArtifactBuilder::build(
        NativeTreeDefinition::create(std::move(savanna_height)), NativeTreeRenderTier::impostor));
    NativeTreeDefinitionInput savanna_canopy = savanna.input();
    savanna_canopy.canopy_radius = static_cast<double>(std::numeric_limits<float>::max()) * 2.0;
    VWB_EXPECT_THROW(NativeTreeArtifactRejected, NativeTreeArtifactBuilder::build(
        NativeTreeDefinition::create(std::move(savanna_canopy)), NativeTreeRenderTier::impostor));
}

VWB_TEST(native_tree_artifact_complete_validation_rejects_invalid_compiler_outputs_before_canonicalization) {
    const NativeTreeDefinition source = tree(
        NativeTreeArchitecture::savanna, "ecological_savanna_tree", "umbrella_thorn");
    const NativeTreeArtifact artifact = NativeTreeArtifactBuilder::build(source, NativeTreeRenderTier::near);
    const auto validate = [&](const NativeTreeDefinitionInput &definition,
            const NativeTreeTrunkCylinder cylinder,
            const NativeTreeRenderTier tier,
            const std::vector<NativeTreeArtifactBranch> &branches,
            const std::vector<NativeTreeArtifactFoliage> &foliage,
            const NativeTreeArtifactImpostor impostor,
            const NativeTreeArtifactFootprint &footprint) {
        NativeTreeArtifactBuilderTestAccess::validate(
            definition, cylinder, tier, artifact.source_branch_count(),
            branches, foliage, impostor, footprint);
    };
    validate(artifact.definition(), artifact.trunk_cylinder(), artifact.render_tier(),
        artifact.branches(), artifact.foliage(), artifact.impostor(), artifact.footprint());

    auto definition = artifact.definition();
    definition.visual_height = 0.0;
    VWB_EXPECT_THROW(NativeTreeArtifactRejected, validate(definition, artifact.trunk_cylinder(),
        artifact.render_tier(), artifact.branches(), artifact.foliage(), artifact.impostor(), artifact.footprint()));
    definition = artifact.definition();definition.rotation_y = std::numeric_limits<double>::infinity();
    VWB_EXPECT_THROW(NativeTreeArtifactRejected, validate(definition, artifact.trunk_cylinder(),
        artifact.render_tier(), artifact.branches(), artifact.foliage(), artifact.impostor(), artifact.footprint()));
    definition = artifact.definition();definition.coordinate_frame = static_cast<NativeTreeCoordinateFrame>(255);
    VWB_EXPECT_THROW(NativeTreeArtifactRejected, validate(definition, artifact.trunk_cylinder(),
        artifact.render_tier(), artifact.branches(), artifact.foliage(), artifact.impostor(), artifact.footprint()));
    auto cylinder = artifact.trunk_cylinder();
    cylinder.center_y = 0.0F;
    VWB_EXPECT_THROW(NativeTreeArtifactRejected, validate(artifact.definition(), cylinder,
        artifact.render_tier(), artifact.branches(), artifact.foliage(), artifact.impostor(), artifact.footprint()));
    auto impostor = artifact.impostor();
    impostor.canopy_radius = std::numeric_limits<float>::infinity();
    VWB_EXPECT_THROW(NativeTreeArtifactRejected, validate(artifact.definition(), artifact.trunk_cylinder(),
        artifact.render_tier(), artifact.branches(), artifact.foliage(), impostor, artifact.footprint()));
    VWB_EXPECT_THROW(NativeTreeArtifactRejected, validate(artifact.definition(), artifact.trunk_cylinder(),
        artifact.render_tier(), {}, artifact.foliage(), artifact.impostor(), artifact.footprint()));
    VWB_EXPECT_THROW(NativeTreeArtifactRejected, validate(artifact.definition(), artifact.trunk_cylinder(),
        NativeTreeRenderTier::impostor, artifact.branches(), artifact.foliage(),
        artifact.impostor(), artifact.footprint()));

    auto branches = artifact.branches();
    branches.front().start.x = std::numeric_limits<float>::infinity();
    VWB_EXPECT_THROW(NativeTreeArtifactRejected, validate(artifact.definition(), artifact.trunk_cylinder(),
        artifact.render_tier(), branches, artifact.foliage(), artifact.impostor(), artifact.footprint()));
    branches = artifact.branches();branches.front().radius_start = 0.0;
    VWB_EXPECT_THROW(NativeTreeArtifactRejected, validate(artifact.definition(), artifact.trunk_cylinder(),
        artifact.render_tier(), branches, artifact.foliage(), artifact.impostor(), artifact.footprint()));
    branches = artifact.branches();branches.front().radius_end = std::numeric_limits<double>::infinity();
    VWB_EXPECT_THROW(NativeTreeArtifactRejected, validate(artifact.definition(), artifact.trunk_cylinder(),
        artifact.render_tier(), branches, artifact.foliage(), artifact.impostor(), artifact.footprint()));
    branches = artifact.branches();branches.front().parent_node = -1;
    VWB_EXPECT_THROW(NativeTreeArtifactRejected, validate(artifact.definition(), artifact.trunk_cylinder(),
        artifact.render_tier(), branches, artifact.foliage(), artifact.impostor(), artifact.footprint()));
    branches = artifact.branches();branches.front().order = 5;
    VWB_EXPECT_THROW(NativeTreeArtifactRejected, validate(artifact.definition(), artifact.trunk_cylinder(),
        artifact.render_tier(), branches, artifact.foliage(), artifact.impostor(), artifact.footprint()));
    branches = artifact.branches();branches.front().child_node = -1;
    VWB_EXPECT_THROW(NativeTreeArtifactRejected, validate(artifact.definition(), artifact.trunk_cylinder(),
        artifact.render_tier(), branches, artifact.foliage(), artifact.impostor(), artifact.footprint()));
    branches = artifact.branches();branches.front().parent_node = 999999;
    VWB_EXPECT_THROW(NativeTreeArtifactRejected, validate(artifact.definition(), artifact.trunk_cylinder(),
        artifact.render_tier(), branches, artifact.foliage(), artifact.impostor(), artifact.footprint()));
    branches = artifact.branches();branches[2].child_node = branches.front().child_node;
    VWB_EXPECT_THROW(NativeTreeArtifactRejected, validate(artifact.definition(), artifact.trunk_cylinder(),
        artifact.render_tier(), branches, artifact.foliage(), artifact.impostor(), artifact.footprint()));
    branches = artifact.branches();branches.front().wind_weight = 1.01;
    VWB_EXPECT_THROW(NativeTreeArtifactRejected, validate(artifact.definition(), artifact.trunk_cylinder(),
        artifact.render_tier(), branches, artifact.foliage(), artifact.impostor(), artifact.footprint()));

    auto foliage = artifact.foliage();foliage.front().rotation.y = std::numeric_limits<float>::quiet_NaN();
    VWB_EXPECT_THROW(NativeTreeArtifactRejected, validate(artifact.definition(), artifact.trunk_cylinder(),
        artifact.render_tier(), artifact.branches(), foliage, artifact.impostor(), artifact.footprint()));
    foliage = artifact.foliage();foliage.front().scale.z = 0.0F;
    VWB_EXPECT_THROW(NativeTreeArtifactRejected, validate(artifact.definition(), artifact.trunk_cylinder(),
        artifact.render_tier(), artifact.branches(), foliage, artifact.impostor(), artifact.footprint()));
    foliage = artifact.foliage();foliage.front().variation = -0.01;
    VWB_EXPECT_THROW(NativeTreeArtifactRejected, validate(artifact.definition(), artifact.trunk_cylinder(),
        artifact.render_tier(), artifact.branches(), foliage, artifact.impostor(), artifact.footprint()));
    foliage = artifact.foliage();foliage.front().source_segment = -1;
    VWB_EXPECT_THROW(NativeTreeArtifactRejected, validate(artifact.definition(), artifact.trunk_cylinder(),
        artifact.render_tier(), artifact.branches(), foliage, artifact.impostor(), artifact.footprint()));
    foliage = artifact.foliage();foliage.front().wind_weight = std::numeric_limits<double>::infinity();
    VWB_EXPECT_THROW(NativeTreeArtifactRejected, validate(artifact.definition(), artifact.trunk_cylinder(),
        artifact.render_tier(), artifact.branches(), foliage, artifact.impostor(), artifact.footprint()));
    foliage = artifact.foliage();foliage.front().cluster_variant = 4;
    VWB_EXPECT_THROW(NativeTreeArtifactRejected, validate(artifact.definition(), artifact.trunk_cylinder(),
        artifact.render_tier(), artifact.branches(), foliage, artifact.impostor(), artifact.footprint()));
    foliage = artifact.foliage();foliage.front().source_order = 5;
    VWB_EXPECT_THROW(NativeTreeArtifactRejected, validate(artifact.definition(), artifact.trunk_cylinder(),
        artifact.render_tier(), artifact.branches(), foliage, artifact.impostor(), artifact.footprint()));

    auto footprint = artifact.footprint();footprint.render_complete = false;
    VWB_EXPECT_THROW(NativeTreeArtifactRejected, validate(artifact.definition(), artifact.trunk_cylinder(),
        artifact.render_tier(), artifact.branches(), artifact.foliage(), artifact.impostor(), footprint));
    footprint = artifact.footprint();footprint.coordinate_owner_id += ":wrong";
    VWB_EXPECT_THROW(NativeTreeArtifactRejected, validate(artifact.definition(), artifact.trunk_cylinder(),
        artifact.render_tier(), artifact.branches(), artifact.foliage(), artifact.impostor(), footprint));
    footprint = artifact.footprint();footprint.collision_complete = false;
    VWB_EXPECT_THROW(NativeTreeArtifactRejected, validate(artifact.definition(), artifact.trunk_cylinder(),
        artifact.render_tier(), artifact.branches(), artifact.foliage(), artifact.impostor(), footprint));
    footprint = artifact.footprint();footprint.render_bounds_provisional = true;
    VWB_EXPECT_THROW(NativeTreeArtifactRejected, validate(artifact.definition(), artifact.trunk_cylinder(),
        artifact.render_tier(), artifact.branches(), artifact.foliage(), artifact.impostor(), footprint));
    footprint = artifact.footprint();footprint.collision_bounds.minimum.z = std::numeric_limits<double>::infinity();
    VWB_EXPECT_THROW(NativeTreeArtifactRejected, validate(artifact.definition(), artifact.trunk_cylinder(),
        artifact.render_tier(), artifact.branches(), artifact.foliage(), artifact.impostor(), footprint));
    footprint = artifact.footprint();footprint.render_bounds.minimum.x = footprint.render_bounds.maximum.x + 1.0;
    VWB_EXPECT_THROW(NativeTreeArtifactRejected, validate(artifact.definition(), artifact.trunk_cylinder(),
        artifact.render_tier(), artifact.branches(), artifact.foliage(), artifact.impostor(), footprint));
    footprint = artifact.footprint();footprint.collision_bounds.maximum.y += 1.0;
    VWB_EXPECT_THROW(NativeTreeArtifactRejected, validate(artifact.definition(), artifact.trunk_cylinder(),
        artifact.render_tier(), artifact.branches(), artifact.foliage(), artifact.impostor(), footprint));
    footprint = artifact.footprint();footprint.render_bounds.maximum.y += 1.0;
    VWB_EXPECT_THROW(NativeTreeArtifactRejected, validate(artifact.definition(), artifact.trunk_cylinder(),
        artifact.render_tier(), artifact.branches(), artifact.foliage(), artifact.impostor(), footprint));
}

VWB_TEST(native_tree_artifact_rejects_float_max_geometry_for_conifer_and_savanna) {
    for (const auto &[architecture, family, grammar] : {
            std::tuple{NativeTreeArchitecture::conifer, "ecological_conifer_tree", "norway_spruce"},
            std::tuple{NativeTreeArchitecture::savanna, "ecological_savanna_tree", "umbrella_thorn"},
        }) {
        const NativeTreeDefinition source = tree(architecture, family, grammar);
        NativeTreeDefinitionInput maximum = source.input();
        maximum.canopy_radius = std::numeric_limits<float>::max();
        VWB_EXPECT_THROW(NativeTreeArtifactRejected, NativeTreeArtifactBuilder::build(
            NativeTreeDefinition::create(maximum), NativeTreeRenderTier::near));
        maximum.canopy_radius = std::nextafter(
            static_cast<double>(std::numeric_limits<float>::max()), 0.0);
        VWB_EXPECT_THROW(NativeTreeArtifactRejected, NativeTreeArtifactBuilder::build(
            NativeTreeDefinition::create(std::move(maximum)), NativeTreeRenderTier::near));
    }
}

VWB_TEST(native_tree_artifact_foliage_source_segments_are_bounded_by_the_unreduced_grammar) {
    for (const auto &[architecture, family, grammar] : {
            std::tuple{NativeTreeArchitecture::conifer, "ecological_conifer_tree", "norway_spruce"},
            std::tuple{NativeTreeArchitecture::savanna, "ecological_savanna_tree", "umbrella_thorn"},
        }) {
        const NativeTreeDefinition source = tree(architecture, family, grammar);
        for (const NativeTreeRenderTier tier : {NativeTreeRenderTier::near,
                NativeTreeRenderTier::mid, NativeTreeRenderTier::far}) {
            const NativeTreeArtifact artifact = NativeTreeArtifactBuilder::build(source, tier);
            VWB_EXPECT(artifact.source_branch_count() >= artifact.branches().size());
            VWB_EXPECT_THROW(NativeTreeArtifactRejected, NativeTreeArtifactBuilderTestAccess::validate(
                artifact.definition(), artifact.trunk_cylinder(), tier,
                static_cast<std::uint32_t>(artifact.branches().size() - 1U),
                artifact.branches(), artifact.foliage(), artifact.impostor(), artifact.footprint()));
            auto foliage = artifact.foliage();
            foliage.front().source_segment = static_cast<std::int32_t>(artifact.source_branch_count() - 1U);
            NativeTreeArtifactBuilderTestAccess::validate(artifact.definition(), artifact.trunk_cylinder(),
                tier, artifact.source_branch_count(), artifact.branches(), foliage,
                artifact.impostor(), artifact.footprint());
            foliage.front().source_segment = static_cast<std::int32_t>(artifact.source_branch_count());
            VWB_EXPECT_THROW(NativeTreeArtifactRejected, NativeTreeArtifactBuilderTestAccess::validate(
                artifact.definition(), artifact.trunk_cylinder(), tier, artifact.source_branch_count(),
                artifact.branches(), foliage, artifact.impostor(), artifact.footprint()));
            foliage.front().source_segment = std::numeric_limits<std::int32_t>::max();
            VWB_EXPECT_THROW(NativeTreeArtifactRejected, NativeTreeArtifactBuilderTestAccess::validate(
                artifact.definition(), artifact.trunk_cylinder(), tier, artifact.source_branch_count(),
                artifact.branches(), foliage, artifact.impostor(), artifact.footprint()));
        }
        const NativeTreeArtifact impostor = NativeTreeArtifactBuilder::build(
            source, NativeTreeRenderTier::impostor);
        VWB_EXPECT_EQ(std::uint32_t(0U), impostor.source_branch_count());
        NativeTreeArtifactBuilderTestAccess::validate(impostor.definition(), impostor.trunk_cylinder(),
            NativeTreeRenderTier::impostor, 0U, impostor.branches(), impostor.foliage(),
            impostor.impostor(), impostor.footprint());
        VWB_EXPECT_THROW(NativeTreeArtifactRejected, NativeTreeArtifactBuilderTestAccess::validate(
            impostor.definition(), impostor.trunk_cylinder(), NativeTreeRenderTier::impostor, 1U,
            impostor.branches(), impostor.foliage(), impostor.impostor(), impostor.footprint()));
    }
}
