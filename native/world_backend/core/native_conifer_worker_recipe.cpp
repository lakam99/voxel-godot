#include "native_conifer_worker_recipe.hpp"
#include "native_conifer_raw_runtime_reducer.hpp"
#include "native_tree_worker_text_admission.hpp"

#include <algorithm>
#include <cctype>
#include <cmath>
#include <cstdio>
#include <limits>
#include <stdexcept>

namespace voxel::world_backend {
namespace {
using V = NativeConiferVec3;
double clamp(double x,double lo,double hi) { return std::clamp(x,lo,hi); }
double max0(double x) { return std::max(0.0,x); }
void finite(double x) { if (!std::isfinite(x)) throw std::invalid_argument("conifer worker request must be finite"); }
std::string trim(const std::string &source) {
    std::size_t first=0,last=source.size();
    while (first<last && std::isspace(static_cast<unsigned char>(source[first]))) ++first;
    while (last>first && std::isspace(static_cast<unsigned char>(source[last-1]))) --last;
    return source.substr(first,last-first);
}
std::string lower_ascii(std::string source) {
    for (char &ch:source) ch=static_cast<char>(std::tolower(static_cast<unsigned char>(ch)));
    return source;
}
std::string normalized_tier(const std::string &source) {
    const auto tier=lower_ascii(trim(source));
    return (tier=="near" || tier=="mid" || tier=="far" || tier=="impostor")?tier:"near";
}
std::string f(double value,int digits) {
    // Match Godot's fixed-decimal identity formatting without truncating a
    // large (but finite) scalar into a colliding cache/signature key.
    const int required=std::snprintf(nullptr,0,"%.*f",digits,value);
    std::vector<char> buffer(static_cast<std::size_t>(required)+1U);
    std::snprintf(buffer.data(),buffer.size(),"%.*f",digits,value);
    return std::string(buffer.data(),static_cast<std::size_t>(required));
}
std::uint32_t unicode_stable_hash(const std::string &source) {
    // Request text is admitted once at the builder boundary. Every suffix
    // concatenated below is ASCII, so decoding here cannot encounter malformed
    // UTF-8 and need not retain a second, partially divergent validator.
    std::uint32_t value=2166136261U;
    for (std::size_t i=0;i<source.size();) {
        const unsigned char c=static_cast<unsigned char>(source[i]);
        std::uint32_t codepoint=0; std::size_t length=0;
        if (c<0x80U) {codepoint=c;length=1;}
        else if ((c&0xe0U)==0xc0U) {codepoint=c&0x1fU;length=2;}
        else if ((c&0xf0U)==0xe0U) {codepoint=c&0x0fU;length=3;}
        else {codepoint=c&0x07U;length=4;}
        for (std::size_t j=1;j<length;++j) {
            const unsigned char next=static_cast<unsigned char>(source[i+j]);
            codepoint=(codepoint<<6U)|(next&0x3fU);
        }
        value=(value^codepoint)*16777619U; i+=length;
    }
    return value;
}
std::string hex8(std::uint32_t value) {char buffer[16];std::snprintf(buffer,sizeof(buffer),"%08x",value);return buffer;}
V scale_position(V v,double horizontal,double vertical) {
    return {static_cast<float>(double(v.x)*horizontal),static_cast<float>(double(v.y)*vertical),static_cast<float>(double(v.z)*horizontal)};
}
NativeConiferWorkerBiomeParameters normalize_parameters(NativeConiferWorkerBiomeParameters p) {
    p.version=std::max(1,p.version); p.architecture=lower_ascii(trim(p.architecture));
    p.height_min=max0(p.height_min); p.height_max=max0(p.height_max);
    p.trunk_radius_min=max0(p.trunk_radius_min); p.trunk_radius_max=max0(p.trunk_radius_max);
    p.canopy_radius_min=max0(p.canopy_radius_min); p.canopy_radius_max=max0(p.canopy_radius_max);
    p.canopy_density=clamp(p.canopy_density,0.20,1.0); p.wind_response=clamp(p.wind_response,0.0,2.0);
    p.visibility_range=std::max(32.0,p.visibility_range); p.shadow_range=std::max(16.0,p.shadow_range);
    p.exclusion_margin=max0(p.exclusion_margin);
    return p;
}
std::string parameters_key(const NativeConiferWorkerBiomeParameters &p) {
    return std::to_string(p.version)+":"+p.architecture+":"+
        f(p.height_min,2)+":"+f(p.height_max,2)+":"+
        f(p.trunk_radius_min,3)+":"+f(p.trunk_radius_max,3)+":"+
        f(p.canopy_radius_min,3)+":"+f(p.canopy_radius_max,3)+":"+
        f(p.canopy_density,3)+":"+f(p.wind_response,3)+":"+
        f(p.visibility_range,1)+":"+f(p.shadow_range,1);
}
std::string identity_key(const NativeConiferWorkerRecipe &r,const std::string &presentation) {
    return presentation+":"+r.world_seed+":"+r.tree_id+":"+r.biome+":"+r.architecture+":"+r.species_grammar+":"+
        f(r.growth_stage,5)+":"+f(r.height,3)+":"+f(r.trunk_radius,3)+":"+f(r.canopy_radius,3)+":"+
        f(r.canopy_density,3)+":"+std::to_string(r.genetic_seed)+":"+parameters_key(r.biome_parameters);
}
void adapt(NativeConiferWorkerRecipe &out,const std::vector<NativeConiferBranch> &branches,
    const std::vector<NativeConiferFoliage> &foliage,double source_height,double source_radius,double source_canopy) {
    const double vertical=out.height/std::max(0.01,source_height);
    const double radius=out.trunk_radius/std::max(0.01,source_radius);
    const double horizontal=out.canopy_radius/std::max(0.01,source_canopy);
    for (auto branch:branches) {
        branch.start=scale_position(branch.start,horizontal,vertical);
        branch.end=scale_position(branch.end,horizontal,vertical);
        branch.radius_start=std::max(0.018,branch.radius_start*radius);
        branch.radius_end=std::max(0.012,branch.radius_end*radius);
        branch.wind_weight=clamp(std::max(double(branch.start.y),double(branch.end.y))
            /std::max(1.0,out.height)*out.biome_parameters.wind_response,0.0,1.0);
        out.branches.push_back(branch);
    }
    for (auto anchor:foliage) {
        anchor.position=scale_position(anchor.position,horizontal,vertical);
        anchor.scale=scale_position(anchor.scale,horizontal,vertical);
        anchor.wind_weight=clamp(double(anchor.position.y)/std::max(1.0,out.height)
            *out.biome_parameters.wind_response,0.20,1.0);
        out.foliage.push_back(anchor);
    }
}
}

NativeConiferWorkerRecipe NativeConiferWorkerRecipeBuilder::build(const NativeConiferWorkerRequest &input) {
    admit_native_tree_worker_text({input.tree_id, input.world_seed, input.biome, input.architecture,
        input.species_grammar, input.age_band, input.render_lod_tier, input.presentation,
        input.biome_parameters.architecture});
    NativeConiferWorkerRecipe out;
    out.tree_id=trim(input.tree_id);
    if (out.tree_id.empty()) return out; // TreeSpawnService.normalize_request returns {}.
    out.world_seed=trim(input.world_seed); if(out.world_seed.empty()) out.world_seed="default";
    out.biome=lower_ascii(trim(input.biome));
    out.architecture=lower_ascii(trim(input.architecture));
    out.species_grammar=lower_ascii(trim(input.species_grammar));
    if (out.species_grammar.empty() && out.architecture=="conifer")
        out.species_grammar="norway_spruce";
    if (out.architecture!="conifer" || out.species_grammar!="norway_spruce")
        throw std::invalid_argument("conifer worker requires norway_spruce architecture/grammar");
    for (double x:{input.growth_stage,input.visual_height,input.trunk_radius,input.canopy_radius,
            input.canopy_density,input.age_years,input.world_rotation_y,input.biome_parameters.height_min,
            input.biome_parameters.height_max,input.biome_parameters.trunk_radius_min,
            input.biome_parameters.trunk_radius_max,input.biome_parameters.canopy_radius_min,
            input.biome_parameters.canopy_radius_max,input.biome_parameters.canopy_density,
            input.biome_parameters.wind_response,input.biome_parameters.visibility_range,
            input.biome_parameters.shadow_range,input.biome_parameters.exclusion_margin}) finite(x);
    out.age_band=input.age_band; out.age_years=input.age_years;
    out.growth_stage=clamp(input.growth_stage,0.12,1.0);
    out.height=std::max(4.0,input.visual_height);
    out.trunk_radius=std::max(0.18,input.has_trunk_radius?input.trunk_radius:out.height*0.04);
    out.canopy_radius=std::max(out.trunk_radius*2.2,input.has_canopy_radius?input.canopy_radius:out.height*0.34);
    out.biome_parameters=normalize_parameters(input.biome_parameters);
    out.canopy_density=clamp(input.canopy_density,0.20,1.0);
    out.render_lod_tier=normalized_tier(input.render_lod_tier);
    out.review=input.presentation=="review";
    const bool skip_grammar=out.render_lod_tier=="impostor";
    out.impostor=!out.review && skip_grammar;
    out.runtime_continuous_bole=!out.review && !out.impostor;
    out.poc_continuous_wood=out.review;
    out.crown_habit=skip_grammar?"distance_impostor":"irregular_deep_conical";
    if (!skip_grammar) out.methodology="deterministic_monopodial_bud_spacing_pipe_model";
    out.genetic_seed=input.genetic_seed;
    if (out.genetic_seed==0) {
        const std::string key="tree-local:"+out.world_seed+":"+out.tree_id+":"+out.biome+":"+out.architecture+":"+out.species_grammar+":v10";
        out.genetic_seed=unicode_stable_hash(key);
    }
    out.interaction_world_position=input.world_position;
    out.interaction_world_rotation_y=input.world_rotation_y;
    out.render_visibility_range=std::max(32.0,out.biome_parameters.visibility_range);
    out.render_shadow_range=clamp(out.biome_parameters.shadow_range,16.0,out.render_visibility_range);
    out.render_wind_response=clamp(out.biome_parameters.wind_response,0.0,2.0);
    if (skip_grammar) {
        out.topology_signature="impostor:"+out.world_seed+":"+out.tree_id+":"+out.species_grammar;
    } else {
        const auto raw=NativeConiferRecipeBuilder::build(out.genetic_seed,out.growth_stage);
        out.raw_recipe_version=NativeConiferRecipe::RECIPE_VERSION;
        out.raw_maturity=raw.maturity;
        out.raw_crown_base=raw.crown_base;out.raw_crown_height=raw.crown_height;
        out.raw_crown_center=raw.crown_center;out.raw_crown_radii=raw.crown_radii;
        out.raw_node_count=raw.node_count;out.raw_whorl_count=raw.whorl_count;
        out.raw_interstitial_spray_count=raw.interstitial_spray_count;
        out.raw_support_driven_branchlet_count=raw.support_driven_branchlet_count;
        out.raw_pipe_junction_count=raw.pipe_junction_count;
        out.raw_occupied_crown_bins=raw.occupied_crown_bins;
        out.raw_segment_counts_by_order=raw.segment_counts_by_order;
        out.raw_first_whorl_height=raw.first_whorl_height;
        out.raw_mean_bough_bud_charge=raw.mean_bough_bud_charge;
        out.raw_lower_whorl_mean_length=raw.lower_whorl_mean_length;
        out.raw_upper_whorl_mean_length=raw.upper_whorl_mean_length;
        out.raw_drooping_curtain_mean_pitch=raw.drooping_curtain_mean_pitch;
        out.raw_pipe_max_relative_error=raw.pipe_max_relative_error;
        // The conifer grammar constructs a rooted support graph and an apical
        // leader with at least twelve steps; both source facts are invariant.
        out.apical_leader_continuous=true;out.graph_connected=true;
        out.foliage_derived_from_fine_segments=true;
        out.topology_signature=raw.signature;
        if (out.review) {
            out.source_branch_count=raw.branches.size();out.source_foliage_count=raw.foliage.size();
            adapt(out,raw.branches,raw.foliage,raw.height,raw.trunk_radius,raw.canopy_radius);
        } else {
            const auto reduced=NativeConiferRawRuntimeReducer::reduce(raw,out.canopy_density,out.render_lod_tier);
            out.source_branch_count=reduced.source_branch_count;
            out.source_foliage_count=reduced.source_foliage_count;
            adapt(out,reduced.branches,reduced.foliage,raw.height,raw.trunk_radius,raw.canopy_radius);
        }
    }
    const std::size_t pre_render_branch_count=out.branches.size();
    const std::string request_key=identity_key(out,input.presentation)+":"+out.render_lod_tier;
    admit_native_tree_worker_serialized_identity(request_key);
    out.signature="tree-v10-"+hex8(unicode_stable_hash(request_key+":"+out.topology_signature+":"+
        std::to_string(pre_render_branch_count)));
    if (!out.review && !out.impostor) {
        NativeConiferRecipe adapted;
        adapted.branches=std::move(out.branches);adapted.foliage=std::move(out.foliage);
        const auto final=NativeConiferRawRuntimeReducer::reduce(adapted,out.canopy_density,out.render_lod_tier);
        out.branches=final.branches;out.foliage=final.foliage;
        out.render_branch_budget=final.branch_budget;out.render_foliage_budget=final.foliage_budget;
    }
    out.collision_trunk_radius=out.trunk_radius;
    out.collision_trunk_height=std::max(2.0,out.height*0.82);
    out.valid=true;
    return out;
}
} // namespace voxel::world_backend
