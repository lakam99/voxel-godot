#include "native_tree_artifact.hpp"

#include "native_conifer_worker_recipe.hpp"
#include "native_savanna_worker_recipe.hpp"

#include <algorithm>
#include <cmath>
#include <cstring>
#include <tuple>
#include <utility>

namespace voxel::world_backend {
namespace {

[[noreturn]] void reject() { throw NativeTreeArtifactRejected(); }

std::string tier_name(const NativeTreeRenderTier tier) {
    switch (tier) {
    case NativeTreeRenderTier::near: return "near";
    case NativeTreeRenderTier::mid: return "mid";
    case NativeTreeRenderTier::far: return "far";
    case NativeTreeRenderTier::impostor: return "impostor";
    default: reject();
    }
}

NativeTreeArtifactStatus pending_status(const NativeTreeDefinitionInput &input) {
    // Callers dispatch only broadleaf definitions here.
    if (input.species_grammar == "bushy_oak") return NativeTreeArtifactStatus::broadleaf_recipe_pending;
    reject();
}

NativeTreeArtifactBounds conservative_dimension_bounds(const NativeTreeDefinitionInput &input) noexcept {
    const double radius = std::max(input.canopy_radius, input.trunk_radius);
    return {{input.position.x - radius, input.position.y, input.position.z - radius},
        {input.position.x + radius, input.position.y + input.visual_height, input.position.z + radius}};
}

NativeTreeArtifactBounds collision_bounds(
    const NativeTreeDefinitionInput &input, const NativeTreeTrunkCylinder &cylinder) noexcept {
    const double radius = cylinder.radius;
    return {{input.position.x - radius, input.position.y, input.position.z - radius},
        {input.position.x + radius, input.position.y + cylinder.height, input.position.z + radius}};
}

struct LocalBounds final {
    double min_x = 0.0, min_y = 0.0, min_z = 0.0;
    double max_x = 0.0, max_y = 0.0, max_z = 0.0;
    bool initialized = false;
};

void include(LocalBounds &bounds, const NativeTreeArtifactVec3 &position, const double radius) noexcept {
    const double x = position.x, y = position.y, z = position.z;
    if (!bounds.initialized) {
        bounds = {x - radius, y - radius, z - radius, x + radius, y + radius, z + radius, true};
        return;
    }
    bounds.min_x = std::min(bounds.min_x, x - radius);
    bounds.min_y = std::min(bounds.min_y, y - radius);
    bounds.min_z = std::min(bounds.min_z, z - radius);
    bounds.max_x = std::max(bounds.max_x, x + radius);
    bounds.max_y = std::max(bounds.max_y, y + radius);
    bounds.max_z = std::max(bounds.max_z, z + radius);
}

NativeTreeArtifactBounds world_bounds(
    const LocalBounds &local, const NativeTreeDefinitionInput &input) noexcept {
    const double sine = std::sin(input.rotation_y), cosine = std::cos(input.rotation_y);
    NativeTreeArtifactBounds result;
    bool initialized = false;
    for (const double x : {local.min_x, local.max_x}) {
        for (const double y : {local.min_y, local.max_y}) {
            for (const double z : {local.min_z, local.max_z}) {
                const NativeTreePoint3 value{
                    input.position.x + x * cosine + z * sine,
                    input.position.y + y,
                    input.position.z - x * sine + z * cosine,
                };
                if (!initialized) {
                    result = {value, value}; initialized = true;
                } else {
                    result.minimum.x = std::min(result.minimum.x, value.x);
                    result.minimum.y = std::min(result.minimum.y, value.y);
                    result.minimum.z = std::min(result.minimum.z, value.z);
                    result.maximum.x = std::max(result.maximum.x, value.x);
                    result.maximum.y = std::max(result.maximum.y, value.y);
                    result.maximum.z = std::max(result.maximum.z, value.z);
                }
            }
        }
    }
    return result;
}

NativeTreeArtifactBounds detailed_render_bounds(
    const NativeTreeDefinitionInput &input,
    const std::vector<NativeTreeArtifactBranch> &branches,
    const std::vector<NativeTreeArtifactFoliage> &foliage) noexcept {
    LocalBounds local;
    for (const NativeTreeArtifactBranch &branch : branches) {
        include(local, branch.start, branch.radius_start);
        include(local, branch.end, branch.radius_end);
    }
    for (const NativeTreeArtifactFoliage &anchor : foliage) {
        const double extent = std::max({std::abs(anchor.scale.x), std::abs(anchor.scale.y), std::abs(anchor.scale.z)});
        include(local, anchor.position, extent);
    }
    return world_bounds(local, input);
}

NativeTreeArtifactBounds impostor_render_bounds(
    const NativeTreeDefinitionInput &input, const NativeTreeArtifactImpostor &impostor) noexcept {
    const double radius = impostor.canopy_radius;
    const double crown_half_height = std::max(radius * 1.25, static_cast<double>(impostor.height) * 0.46) * 0.5;
    const double top = std::max(static_cast<double>(impostor.height) * 0.54,
        static_cast<double>(impostor.height) * 0.68 + crown_half_height);
    return {{input.position.x - radius, input.position.y, input.position.z - radius},
        {input.position.x + radius, input.position.y + top, input.position.z + radius}};
}

class Writer final {
public:
    void u8(const std::uint8_t value) { bytes_.push_back(value); }
    void u32(const std::uint32_t value) {
        for (int shift = 24; shift >= 0; shift -= 8) u8(static_cast<std::uint8_t>(value >> shift));
    }
    void i32(const std::int32_t value) { u32(static_cast<std::uint32_t>(value)); }
    void number(const double value) {
        std::uint64_t bits = 0U; std::memcpy(&bits, &value, sizeof(bits));
        for (int shift = 56; shift >= 0; shift -= 8) u8(static_cast<std::uint8_t>(bits >> shift));
    }
    void scalar(const float value) {
        std::uint32_t bits = 0U; std::memcpy(&bits, &value, sizeof(bits)); u32(bits);
    }
    void text(const std::string &value) {
        u32(static_cast<std::uint32_t>(value.size())); bytes_.insert(bytes_.end(), value.begin(), value.end());
    }
    void digest(const Sha256Digest &value) { bytes_.insert(bytes_.end(), value.begin(), value.end()); }
    std::vector<std::uint8_t> finish() { return std::move(bytes_); }
private:
    std::vector<std::uint8_t> bytes_;
};

void write_point(Writer &writer, const NativeTreePoint3 &value) {
    writer.number(value.x); writer.number(value.y); writer.number(value.z);
}
void write_vec(Writer &writer, const NativeTreeArtifactVec3 &value) {
    writer.scalar(value.x); writer.scalar(value.y); writer.scalar(value.z);
}
void write_bounds(Writer &writer, const NativeTreeArtifactBounds &value) {
    write_point(writer, value.minimum); write_point(writer, value.maximum);
}

std::vector<std::uint8_t> canonical(
    const NativeTreeArtifactStatus status,
    const NativeTreeRenderTier tier,
    const Sha256Digest &source_digest,
    const Sha256Digest &recipe_digest,
    const std::string &builder_key,
    const std::uint32_t builder_revision,
    const std::string &recipe_signature,
    const std::string &topology_signature,
    const NativeTreeDefinitionInput &definition,
    const NativeTreeTrunkCylinder &cylinder,
    const std::vector<NativeTreeArtifactBranch> &branches,
    const std::vector<NativeTreeArtifactFoliage> &foliage,
    const NativeTreeArtifactImpostor &impostor,
    const NativeTreeArtifactFootprint &footprint) {
    Writer writer;
    writer.u8('N'); writer.u8('T'); writer.u8('A'); writer.u8('1');
    writer.u32(NativeTreeArtifact::SCHEMA_REVISION); writer.u32(NativeTreeArtifact::BUILDER_REVISION);
    writer.u8(static_cast<std::uint8_t>(status)); writer.u8(static_cast<std::uint8_t>(tier));
    writer.digest(source_digest); writer.digest(recipe_digest); writer.text(builder_key); writer.u32(builder_revision);
    writer.text(recipe_signature); writer.text(topology_signature); writer.text(definition.durable_feature_id);
    writer.text(definition.family); writer.text(definition.species_grammar);
    writer.u8(static_cast<std::uint8_t>(definition.coordinate_frame)); writer.text(definition.coordinate_owner_id);
    write_point(writer, definition.position); writer.number(definition.rotation_y);
    writer.scalar(cylinder.radius); writer.scalar(cylinder.height); writer.scalar(cylinder.center_y);
    writer.u32(static_cast<std::uint32_t>(branches.size()));
    for (const NativeTreeArtifactBranch &branch : branches) {
        write_vec(writer, branch.start); write_vec(writer, branch.end);
        writer.number(branch.radius_start); writer.number(branch.radius_end);
        writer.i32(branch.order); writer.i32(branch.parent_node); writer.i32(branch.child_node);
        writer.number(branch.wind_weight);
    }
    writer.u32(static_cast<std::uint32_t>(foliage.size()));
    for (const NativeTreeArtifactFoliage &anchor : foliage) {
        write_vec(writer, anchor.position); write_vec(writer, anchor.rotation); write_vec(writer, anchor.scale);
        writer.number(anchor.wind_weight); writer.number(anchor.variation);
        writer.i32(anchor.cluster_variant); writer.i32(anchor.source_segment); writer.i32(anchor.source_order);
    }
    writer.scalar(impostor.height); writer.scalar(impostor.trunk_radius); writer.scalar(impostor.canopy_radius);
    writer.u8(static_cast<std::uint8_t>(footprint.coordinate_frame)); writer.text(footprint.coordinate_owner_id);
    write_bounds(writer, footprint.collision_bounds); write_bounds(writer, footprint.render_bounds);
    writer.u8(1U); writer.u8(footprint.render_complete ? 1U : 0U);
    writer.u8(footprint.render_bounds_provisional ? 1U : 0U);
    return writer.finish();
}

NativeConiferWorkerRequest conifer_request(
    const NativeTreeDefinitionInput &input, const std::string &tier) {
    NativeConiferWorkerRequest request;
    request.tree_id = input.recipe_tree_id; request.world_seed = input.world_seed; request.biome = input.biome;
    request.architecture = "conifer"; request.species_grammar = input.species_grammar;
    request.age_band = input.age_band; request.render_lod_tier = tier; request.presentation = "runtime";
    request.growth_stage = input.ecology.growth_stage; request.visual_height = input.visual_height;
    request.trunk_radius = input.trunk_radius; request.canopy_radius = input.canopy_radius;
    request.canopy_density = input.biome_parameters.canopy_density; request.age_years = input.ecology.age_years;
    request.has_trunk_radius = true; request.has_canopy_radius = true; request.genetic_seed = input.ecology.genetic_seed;
    request.biome_parameters.version = static_cast<int>(input.biome_parameters.revision);
    request.biome_parameters.architecture = "conifer";
    request.biome_parameters.height_min = input.biome_parameters.height_min;
    request.biome_parameters.height_max = input.biome_parameters.height_max;
    request.biome_parameters.trunk_radius_min = input.biome_parameters.trunk_radius_min;
    request.biome_parameters.trunk_radius_max = input.biome_parameters.trunk_radius_max;
    request.biome_parameters.canopy_radius_min = input.biome_parameters.canopy_radius_min;
    request.biome_parameters.canopy_radius_max = input.biome_parameters.canopy_radius_max;
    request.biome_parameters.canopy_density = input.biome_parameters.canopy_density;
    request.biome_parameters.wind_response = input.biome_parameters.wind_response;
    request.biome_parameters.visibility_range = input.biome_parameters.visibility_range;
    request.biome_parameters.shadow_range = input.biome_parameters.shadow_range;
    request.biome_parameters.exclusion_margin = input.biome_parameters.exclusion_margin;
    request.world_position = {static_cast<float>(input.position.x), static_cast<float>(input.position.y),
        static_cast<float>(input.position.z)};
    request.world_rotation_y = input.rotation_y;
    return request;
}

NativeSavannaWorkerRequest savanna_request(
    const NativeTreeDefinitionInput &input, const std::string &tier) {
    NativeSavannaWorkerRequest request;
    request.tree_id = input.recipe_tree_id; request.world_seed = input.world_seed; request.biome = input.biome;
    request.architecture = "savanna"; request.species_grammar = input.species_grammar;
    request.age_band = input.age_band; request.render_lod_tier = tier; request.presentation = "runtime";
    request.growth_stage = input.ecology.growth_stage; request.visual_height = input.visual_height;
    request.trunk_radius = input.trunk_radius; request.canopy_radius = input.canopy_radius;
    request.canopy_density = input.biome_parameters.canopy_density; request.age_years = input.ecology.age_years;
    request.has_trunk_radius = true; request.has_canopy_radius = true; request.genetic_seed = input.ecology.genetic_seed;
    request.biome_parameters.version = static_cast<int>(input.biome_parameters.revision);
    request.biome_parameters.architecture = "savanna";
    request.biome_parameters.height_min = input.biome_parameters.height_min;
    request.biome_parameters.height_max = input.biome_parameters.height_max;
    request.biome_parameters.trunk_radius_min = input.biome_parameters.trunk_radius_min;
    request.biome_parameters.trunk_radius_max = input.biome_parameters.trunk_radius_max;
    request.biome_parameters.canopy_radius_min = input.biome_parameters.canopy_radius_min;
    request.biome_parameters.canopy_radius_max = input.biome_parameters.canopy_radius_max;
    request.biome_parameters.canopy_density = input.biome_parameters.canopy_density;
    request.biome_parameters.wind_response = input.biome_parameters.wind_response;
    request.biome_parameters.visibility_range = input.biome_parameters.visibility_range;
    request.biome_parameters.shadow_range = input.biome_parameters.shadow_range;
    request.biome_parameters.exclusion_margin = input.biome_parameters.exclusion_margin;
    request.world_position = {static_cast<float>(input.position.x), static_cast<float>(input.position.y),
        static_cast<float>(input.position.z)};
    request.world_rotation_y = input.rotation_y;
    return request;
}

} // namespace

class NativeTreeArtifactAccess final {
public:
    static NativeTreeArtifact make(
        const NativeTreeArtifactStatus status,
        const NativeTreeRenderTier tier,
        const Sha256Digest source_digest,
        const Sha256Digest recipe_digest,
        std::string builder_key,
        const std::uint32_t builder_revision,
        std::string recipe_signature,
        std::string topology_signature,
        NativeTreeDefinitionInput input,
        const NativeTreeTrunkCylinder cylinder,
        std::vector<NativeTreeArtifactBranch> branches,
        std::vector<NativeTreeArtifactFoliage> foliage,
        const NativeTreeArtifactImpostor impostor,
        NativeTreeArtifactFootprint footprint,
        std::vector<std::uint8_t> bytes,
        const Sha256Digest digest) {
        return NativeTreeArtifact(status, tier, source_digest, recipe_digest,
            std::move(builder_key), builder_revision, std::move(recipe_signature),
            std::move(topology_signature), std::move(input), cylinder, std::move(branches),
            std::move(foliage), impostor, std::move(footprint), std::move(bytes), digest);
    }
};

namespace {

NativeTreeArtifact make_artifact(
    const NativeTreeDefinition &definition,
    const NativeTreeRenderTier tier,
    const NativeTreeArtifactStatus status,
    Sha256Digest recipe_digest,
    std::string builder_key,
    const std::uint32_t builder_revision,
    std::string recipe_signature,
    std::string topology_signature,
    std::vector<NativeTreeArtifactBranch> branches,
    std::vector<NativeTreeArtifactFoliage> foliage,
    const NativeTreeArtifactImpostor impostor,
    const bool render_complete,
    const bool render_bounds_provisional) {
    const NativeTreeDefinitionInput input = definition.input();
    const NativeTreeTrunkCylinder cylinder = definition.trunk_cylinder();
    NativeTreeArtifactFootprint footprint;
    footprint.coordinate_frame = input.coordinate_frame;
    footprint.coordinate_owner_id = input.coordinate_owner_id;
    footprint.collision_bounds = collision_bounds(input, cylinder);
    footprint.render_bounds = render_complete
        ? (tier == NativeTreeRenderTier::impostor
            ? impostor_render_bounds(input, impostor)
            : detailed_render_bounds(input, branches, foliage))
        : conservative_dimension_bounds(input);
    footprint.collision_complete = true;
    footprint.render_complete = render_complete;
    footprint.render_bounds_provisional = render_bounds_provisional;
    std::vector<std::uint8_t> bytes = canonical(status, tier, definition.content_digest(), recipe_digest,
        builder_key, builder_revision, recipe_signature, topology_signature, input, cylinder,
        branches, foliage, impostor, footprint);
    const Sha256Digest digest = sha256(bytes);
    return NativeTreeArtifactAccess::make(status, tier, definition.content_digest(), recipe_digest,
        std::move(builder_key), builder_revision, std::move(recipe_signature), std::move(topology_signature),
        input, cylinder, std::move(branches), std::move(foliage), impostor, std::move(footprint),
        std::move(bytes), digest);
}

} // namespace

bool NativeTreeArtifactVec3::operator==(const NativeTreeArtifactVec3 &other) const noexcept {
    return std::tie(x, y, z) == std::tie(other.x, other.y, other.z);
}
bool NativeTreeArtifactBranch::operator==(const NativeTreeArtifactBranch &other) const noexcept {
    return std::tie(start, end, radius_start, radius_end, order, parent_node, child_node, wind_weight)
        == std::tie(other.start, other.end, other.radius_start, other.radius_end, other.order,
            other.parent_node, other.child_node, other.wind_weight);
}
bool NativeTreeArtifactFoliage::operator==(const NativeTreeArtifactFoliage &other) const noexcept {
    return std::tie(position, rotation, scale, wind_weight, variation, cluster_variant, source_segment, source_order)
        == std::tie(other.position, other.rotation, other.scale, other.wind_weight, other.variation,
            other.cluster_variant, other.source_segment, other.source_order);
}
bool NativeTreeArtifactImpostor::operator==(const NativeTreeArtifactImpostor &other) const noexcept {
    return std::tie(height, trunk_radius, canopy_radius)
        == std::tie(other.height, other.trunk_radius, other.canopy_radius);
}
bool NativeTreeArtifactBounds::operator==(const NativeTreeArtifactBounds &other) const noexcept {
    return std::tie(minimum, maximum) == std::tie(other.minimum, other.maximum);
}
bool NativeTreeArtifactFootprint::operator==(const NativeTreeArtifactFootprint &other) const noexcept {
    return std::tie(coordinate_frame, coordinate_owner_id, collision_bounds, render_bounds,
        collision_complete, render_complete, render_bounds_provisional)
        == std::tie(other.coordinate_frame, other.coordinate_owner_id, other.collision_bounds,
            other.render_bounds, other.collision_complete, other.render_complete,
            other.render_bounds_provisional);
}

NativeTreeArtifactRejected::NativeTreeArtifactRejected()
    : std::invalid_argument("invalid native tree artifact input") {}

NativeTreeArtifact::NativeTreeArtifact(
    const NativeTreeArtifactStatus status,
    const NativeTreeRenderTier render_tier,
    const Sha256Digest source_definition_digest,
    const Sha256Digest native_recipe_digest,
    std::string recipe_builder_key,
    const std::uint32_t recipe_builder_revision,
    std::string recipe_signature,
    std::string topology_signature,
    NativeTreeDefinitionInput definition,
    const NativeTreeTrunkCylinder trunk_cylinder,
    std::vector<NativeTreeArtifactBranch> branches,
    std::vector<NativeTreeArtifactFoliage> foliage,
    const NativeTreeArtifactImpostor impostor,
    NativeTreeArtifactFootprint footprint,
    std::vector<std::uint8_t> canonical_binary,
    const Sha256Digest content_digest) noexcept
    : status_(status), render_tier_(render_tier), source_definition_digest_(source_definition_digest),
      native_recipe_digest_(native_recipe_digest), recipe_builder_key_(std::move(recipe_builder_key)),
      recipe_builder_revision_(recipe_builder_revision), recipe_signature_(std::move(recipe_signature)),
      topology_signature_(std::move(topology_signature)), definition_(std::move(definition)),
      trunk_cylinder_(trunk_cylinder), branches_(std::move(branches)), foliage_(std::move(foliage)),
      impostor_(impostor), footprint_(std::move(footprint)), canonical_binary_(std::move(canonical_binary)),
      content_digest_(content_digest) {}

NativeTreeArtifactStatus NativeTreeArtifact::status() const noexcept { return status_; }
NativeTreeRenderTier NativeTreeArtifact::render_tier() const noexcept { return render_tier_; }
bool NativeTreeArtifact::complete() const noexcept { return status_ == NativeTreeArtifactStatus::complete; }
const Sha256Digest &NativeTreeArtifact::source_definition_digest() const noexcept { return source_definition_digest_; }
const Sha256Digest &NativeTreeArtifact::native_recipe_digest() const noexcept { return native_recipe_digest_; }
const std::string &NativeTreeArtifact::recipe_builder_key() const noexcept { return recipe_builder_key_; }
std::uint32_t NativeTreeArtifact::recipe_builder_revision() const noexcept { return recipe_builder_revision_; }
const std::string &NativeTreeArtifact::recipe_signature() const noexcept { return recipe_signature_; }
const std::string &NativeTreeArtifact::topology_signature() const noexcept { return topology_signature_; }
const NativeTreeDefinitionInput &NativeTreeArtifact::definition() const noexcept { return definition_; }
NativeTreeTrunkCylinder NativeTreeArtifact::trunk_cylinder() const noexcept { return trunk_cylinder_; }
const std::vector<NativeTreeArtifactBranch> &NativeTreeArtifact::branches() const noexcept { return branches_; }
const std::vector<NativeTreeArtifactFoliage> &NativeTreeArtifact::foliage() const noexcept { return foliage_; }
const NativeTreeArtifactImpostor &NativeTreeArtifact::impostor() const noexcept { return impostor_; }
const NativeTreeArtifactFootprint &NativeTreeArtifact::footprint() const noexcept { return footprint_; }
const std::vector<std::uint8_t> &NativeTreeArtifact::canonical_binary() const noexcept { return canonical_binary_; }
const Sha256Digest &NativeTreeArtifact::content_digest() const noexcept { return content_digest_; }
bool NativeTreeArtifact::operator==(const NativeTreeArtifact &other) const noexcept {
    return canonical_binary_ == other.canonical_binary_;
}
bool NativeTreeArtifact::operator!=(const NativeTreeArtifact &other) const noexcept { return !(*this == other); }

NativeTreeArtifact NativeTreeArtifactBuilder::build(
    const NativeTreeDefinition &definition, const NativeTreeRenderTier render_tier) {
    const std::string tier = tier_name(render_tier);
    const NativeTreeDefinitionInput &input = definition.input();
    if (input.architecture == NativeTreeArchitecture::broadleaf) {
        const NativeTreeArtifactStatus status = pending_status(input);
        return make_artifact(definition, render_tier, status, {}, "native_tree_recipe_pending", 1U,
            "", "", {}, {}, {}, false, true);
    }
    if (input.architecture == NativeTreeArchitecture::savanna) {
        if (input.species_grammar != "umbrella_thorn") reject();
        if (!std::isfinite(static_cast<float>(input.visual_height))) reject();
        if (!std::isfinite(static_cast<float>(input.canopy_radius))) reject();
        const NativeSavannaWorkerRecipe recipe = NativeSavannaWorkerRecipeBuilder::build(
            savanna_request(input, tier));
        if (std::tie(recipe.height, recipe.trunk_radius, recipe.canopy_radius,
                recipe.collision_trunk_radius, recipe.collision_trunk_height)
            != std::tie(input.visual_height, input.trunk_radius, input.canopy_radius,
                input.trunk_radius, input.collision_height)) reject();
        std::vector<NativeTreeArtifactBranch> branches;
        branches.reserve(recipe.branches.size());
        for (const NativeSavannaBranch &branch : recipe.branches) {
            branches.push_back({{branch.start.x, branch.start.y, branch.start.z},
                {branch.end.x, branch.end.y, branch.end.z}, branch.radius_start, branch.radius_end,
                branch.order, branch.parent_node, branch.child_node, branch.wind_weight});
        }
        std::vector<NativeTreeArtifactFoliage> foliage;
        foliage.reserve(recipe.foliage.size());
        for (const NativeSavannaFoliage &anchor : recipe.foliage) {
            foliage.push_back({{anchor.position.x, anchor.position.y, anchor.position.z},
                {anchor.rotation.x, anchor.rotation.y, anchor.rotation.z},
                {anchor.scale.x, anchor.scale.y, anchor.scale.z}, anchor.wind_weight, anchor.variation,
                anchor.cluster_variant, anchor.source_segment, anchor.source_order});
        }
        const NativeTreeArtifactImpostor impostor{static_cast<float>(input.visual_height),
            static_cast<float>(input.trunk_radius), static_cast<float>(input.canopy_radius)};
        const std::string identity = recipe.signature + ":" + recipe.topology_signature;
        const Sha256Digest recipe_digest = sha256(std::vector<std::uint8_t>(identity.begin(), identity.end()));
        return make_artifact(definition, render_tier, NativeTreeArtifactStatus::complete,
            recipe_digest, "native_umbrella_thorn_worker_recipe", NativeSavannaWorkerRecipe::RECIPE_VERSION,
            recipe.signature, recipe.topology_signature, std::move(branches), std::move(foliage), impostor,
            true, false);
    }
    if (input.species_grammar != "norway_spruce") reject();
    if (!std::isfinite(static_cast<float>(input.visual_height))) reject();
    if (!std::isfinite(static_cast<float>(input.canopy_radius))) reject();
    const NativeConiferWorkerRecipe recipe = NativeConiferWorkerRecipeBuilder::build(
        conifer_request(input, tier));
    // Completion means the worker consumed the source dimensions exactly.  A
    // worker normalization floor is not allowed to make render wood/canopy or
    // its collision declaration disagree with the immutable definition.
    if (std::tie(recipe.height, recipe.trunk_radius, recipe.canopy_radius,
            recipe.collision_trunk_radius, recipe.collision_trunk_height)
        != std::tie(input.visual_height, input.trunk_radius, input.canopy_radius,
            input.trunk_radius, input.collision_height)) reject();
    std::vector<NativeTreeArtifactBranch> branches;
    branches.reserve(recipe.branches.size());
    for (const NativeConiferBranch &branch : recipe.branches) {
        NativeTreeArtifactBranch value{{branch.start.x, branch.start.y, branch.start.z},
            {branch.end.x, branch.end.y, branch.end.z}, branch.radius_start, branch.radius_end,
            branch.order, branch.parent_node, branch.child_node, branch.wind_weight};
        branches.push_back(value);
    }
    std::vector<NativeTreeArtifactFoliage> foliage;
    foliage.reserve(recipe.foliage.size());
    for (const NativeConiferFoliage &anchor : recipe.foliage) {
        NativeTreeArtifactFoliage value{{anchor.position.x, anchor.position.y, anchor.position.z},
            {anchor.rotation.x, anchor.rotation.y, anchor.rotation.z},
            {anchor.scale.x, anchor.scale.y, anchor.scale.z}, anchor.wind_weight, anchor.variation,
            anchor.cluster_variant, anchor.source_segment, anchor.source_order};
        foliage.push_back(value);
    }
    const NativeTreeArtifactImpostor impostor{static_cast<float>(input.visual_height),
        static_cast<float>(input.trunk_radius), static_cast<float>(input.canopy_radius)};
    const std::string recipe_identity = recipe.signature + ":" + recipe.topology_signature;
    const Sha256Digest recipe_digest = sha256(std::vector<std::uint8_t>(
        recipe_identity.begin(), recipe_identity.end()));
    return make_artifact(definition, render_tier, NativeTreeArtifactStatus::complete,
        recipe_digest, "native_norway_spruce_worker_recipe", NativeConiferWorkerRecipe::RECIPE_VERSION,
        recipe.signature, recipe.topology_signature, std::move(branches), std::move(foliage), impostor,
        true, false);
}

} // namespace voxel::world_backend
