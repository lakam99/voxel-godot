#include "native_savanna_worker_recipe.hpp"

#include "native_conifer_raw_runtime_reducer.hpp"
#include "native_tree_worker_text_admission.hpp"

#include <algorithm>
#include <cctype>
#include <cmath>
#include <cstdio>
#include <stdexcept>
#include <utility>
#include <vector>

namespace voxel::world_backend {
namespace {
using V = NativeSavannaVec3;
double clamp(double value,double low,double high) { return std::clamp(value,low,high); }
double max0(double value) { return std::max(0.0,value); }
void finite(double value) { if(!std::isfinite(value)) throw std::invalid_argument("savanna worker request must be finite"); }
std::string trim(const std::string &source) {
    std::size_t first=0,last=source.size();
    while(first<last && std::isspace(static_cast<unsigned char>(source[first]))) ++first;
    while(last>first && std::isspace(static_cast<unsigned char>(source[last-1]))) --last;
    return source.substr(first,last-first);
}
std::string lower_ascii(std::string source) {
    for(char &ch:source) ch=static_cast<char>(std::tolower(static_cast<unsigned char>(ch)));
    return source;
}
std::string normalized_tier(const std::string &source) {
    const std::string tier=lower_ascii(trim(source));
    return (tier=="near" || tier=="mid" || tier=="far" || tier=="impostor")?tier:"near";
}
std::string fixed(double value,int digits) {
    const int required=std::snprintf(nullptr,0,"%.*f",digits,value);
    std::vector<char> buffer(static_cast<std::size_t>(required)+1U);
    std::snprintf(buffer.data(),buffer.size(),"%.*f",digits,value);
    return std::string(buffer.data(),static_cast<std::size_t>(required));
}
std::uint32_t unicode_stable_hash(const std::string &source) {
    // The shared worker boundary already admitted every request field. Only
    // ASCII compiler-owned separators and suffixes are added before hashing.
    std::uint32_t value=2166136261U;
    for(std::size_t index=0;index<source.size();) {
        const unsigned char first=static_cast<unsigned char>(source[index]);
        std::uint32_t codepoint=0;std::size_t length=0;
        if(first<0x80U) {codepoint=first;length=1;}
        else if((first&0xe0U)==0xc0U) {codepoint=first&0x1fU;length=2;}
        else if((first&0xf0U)==0xe0U) {codepoint=first&0x0fU;length=3;}
        else {codepoint=first&0x07U;length=4;}
        for(std::size_t offset=1;offset<length;++offset) {
            const unsigned char next=static_cast<unsigned char>(source[index+offset]);
            codepoint=(codepoint<<6U)|(next&0x3fU);
        }
        value=(value^codepoint)*16777619U;index+=length;
    }
    return value;
}
std::string hex8(std::uint32_t value) { char buffer[16];std::snprintf(buffer,sizeof(buffer),"%08x",value);return buffer; }
V scale_position(V value,double horizontal,double vertical) {
    return {static_cast<float>(double(value.x)*horizontal),static_cast<float>(double(value.y)*vertical),
        static_cast<float>(double(value.z)*horizontal)};
}
NativeSavannaWorkerBiomeParameters normalize_parameters(NativeSavannaWorkerBiomeParameters value) {
    value.version=std::max(1,value.version);value.architecture=lower_ascii(trim(value.architecture));
    value.height_min=max0(value.height_min);value.height_max=max0(value.height_max);
    value.trunk_radius_min=max0(value.trunk_radius_min);value.trunk_radius_max=max0(value.trunk_radius_max);
    value.canopy_radius_min=max0(value.canopy_radius_min);value.canopy_radius_max=max0(value.canopy_radius_max);
    value.canopy_density=clamp(value.canopy_density,0.20,1.0);value.wind_response=clamp(value.wind_response,0.0,2.0);
    value.visibility_range=std::max(32.0,value.visibility_range);value.shadow_range=std::max(16.0,value.shadow_range);
    value.exclusion_margin=max0(value.exclusion_margin);return value;
}
std::string parameter_key(const NativeSavannaWorkerBiomeParameters &value) {
    return std::to_string(value.version)+":"+value.architecture+":"+fixed(value.height_min,2)+":"+
        fixed(value.height_max,2)+":"+fixed(value.trunk_radius_min,3)+":"+fixed(value.trunk_radius_max,3)+":"+
        fixed(value.canopy_radius_min,3)+":"+fixed(value.canopy_radius_max,3)+":"+fixed(value.canopy_density,3)+":"+
        fixed(value.wind_response,3)+":"+fixed(value.visibility_range,1)+":"+fixed(value.shadow_range,1);
}
std::string identity_key(const NativeSavannaWorkerRecipe &recipe,const std::string &presentation) {
    return presentation+":"+recipe.world_seed+":"+recipe.tree_id+":"+recipe.biome+":"+recipe.architecture+":"+
        recipe.species_grammar+":"+fixed(recipe.growth_stage,5)+":"+fixed(recipe.height,3)+":"+
        fixed(recipe.trunk_radius,3)+":"+fixed(recipe.canopy_radius,3)+":"+fixed(recipe.canopy_density,3)+":"+
        std::to_string(recipe.genetic_seed)+":"+parameter_key(recipe.biome_parameters);
}
void adapt(NativeSavannaWorkerRecipe &out,const std::vector<NativeSavannaBranch> &branches,
    const std::vector<NativeSavannaFoliage> &foliage,double source_height,double source_radius,double source_canopy) {
    const double vertical=out.height/std::max(0.01,source_height);
    const double radius=out.trunk_radius/std::max(0.01,source_radius);
    const double horizontal=out.canopy_radius/std::max(0.01,source_canopy);
    for(auto branch:branches) {
        branch.start=scale_position(branch.start,horizontal,vertical);
        branch.end=scale_position(branch.end,horizontal,vertical);
        branch.radius_start=std::max(0.018,branch.radius_start*radius);
        branch.radius_end=std::max(0.012,branch.radius_end*radius);
        branch.wind_weight=clamp(std::max(double(branch.start.y),double(branch.end.y))
            /std::max(1.0,out.height)*out.biome_parameters.wind_response,0.0,1.0);
        out.branches.push_back(branch);
    }
    for(auto anchor:foliage) {
        anchor.position=scale_position(anchor.position,horizontal,vertical);
        anchor.scale=scale_position(anchor.scale,horizontal,vertical);
        anchor.wind_weight=clamp(double(anchor.position.y)/std::max(1.0,out.height)
            *out.biome_parameters.wind_response,0.20,1.0);
        out.foliage.push_back(anchor);
    }
}
NativeConiferRecipe reduction_source(std::vector<NativeSavannaBranch> branches,
    std::vector<NativeSavannaFoliage> foliage) {
    NativeConiferRecipe source;source.branches=std::move(branches);source.foliage=std::move(foliage);return source;
}
}

NativeSavannaWorkerRecipe NativeSavannaWorkerRecipeBuilder::build(const NativeSavannaWorkerRequest &input) {
    admit_native_tree_worker_text({input.tree_id, input.world_seed, input.biome, input.architecture,
        input.species_grammar, input.age_band, input.render_lod_tier, input.presentation,
        input.biome_parameters.architecture});
    NativeSavannaWorkerRecipe out;out.tree_id=trim(input.tree_id);
    if(out.tree_id.empty()) return out;
    out.world_seed=trim(input.world_seed);if(out.world_seed.empty()) out.world_seed="default";
    out.biome=lower_ascii(trim(input.biome));out.architecture=lower_ascii(trim(input.architecture));
    out.species_grammar=lower_ascii(trim(input.species_grammar));
    if(out.species_grammar.empty() && out.architecture=="savanna") out.species_grammar="umbrella_thorn";
    if(out.architecture!="savanna" || out.species_grammar!="umbrella_thorn")
        throw std::invalid_argument("savanna worker requires umbrella_thorn architecture/grammar");
    for(double value:{input.growth_stage,input.visual_height,input.trunk_radius,input.canopy_radius,
            input.canopy_density,input.age_years,input.world_rotation_y,input.biome_parameters.height_min,
            input.biome_parameters.height_max,input.biome_parameters.trunk_radius_min,
            input.biome_parameters.trunk_radius_max,input.biome_parameters.canopy_radius_min,
            input.biome_parameters.canopy_radius_max,input.biome_parameters.canopy_density,
            input.biome_parameters.wind_response,input.biome_parameters.visibility_range,
            input.biome_parameters.shadow_range,input.biome_parameters.exclusion_margin}) finite(value);
    out.age_band=input.age_band;out.age_years=input.age_years;
    out.growth_stage=clamp(input.growth_stage,0.12,1.0);out.height=std::max(4.0,input.visual_height);
    out.trunk_radius=std::max(0.18,input.has_trunk_radius?input.trunk_radius:out.height*0.04);
    out.canopy_radius=std::max(out.trunk_radius*2.2,input.has_canopy_radius?input.canopy_radius:out.height*0.34);
    out.biome_parameters=normalize_parameters(input.biome_parameters);
    out.canopy_density=clamp(input.canopy_density,0.20,1.0);
    out.render_lod_tier=normalized_tier(input.render_lod_tier);out.review=input.presentation=="review";
    const bool skip=out.render_lod_tier=="impostor";out.impostor=!out.review && skip;
    out.runtime_continuous_bole=!out.review && !out.impostor;out.poc_continuous_wood=out.review;
    out.crown_habit=skip?"distance_impostor":"wide_perforated_irregular_umbrella";
    if(!skip) out.methodology="deterministic_raised_fork_allometric_axis_pipe_model";
    out.genetic_seed=input.genetic_seed;
    if(out.genetic_seed==0) out.genetic_seed=unicode_stable_hash("tree-local:"+out.world_seed+":"+out.tree_id+":"+
        out.biome+":"+out.architecture+":"+out.species_grammar+":v10");
    out.interaction_world_position=input.world_position;out.interaction_world_rotation_y=input.world_rotation_y;
    out.render_visibility_range=std::max(32.0,out.biome_parameters.visibility_range);
    out.render_shadow_range=clamp(out.biome_parameters.shadow_range,16.0,out.render_visibility_range);
    out.render_wind_response=clamp(out.biome_parameters.wind_response,0.0,2.0);
    if(skip) {
        out.topology_signature="impostor:"+out.world_seed+":"+out.tree_id+":"+out.species_grammar;
    } else {
        const NativeSavannaRecipe raw=NativeSavannaRecipeBuilder::build(out.genetic_seed,out.growth_stage);
        out.raw_recipe_version=NativeSavannaRecipe::RECIPE_VERSION;out.raw_maturity=raw.maturity;
        out.raw_crown_base=raw.crown_base;out.raw_crown_height=raw.crown_height;
        out.raw_crown_center=raw.crown_center;out.raw_crown_radii=raw.crown_radii;
        out.raw_node_count=raw.node_count;out.raw_raised_fork_count=raw.raised_fork_count;
        out.raw_crown_window_count=raw.crown_window_count;out.raw_viable_axis_bud_count=raw.viable_axis_bud_count;
        out.raw_germinated_axis_count=raw.germinated_axis_count;out.raw_grown_metamer_count=raw.grown_metamer_count;
        out.raw_pipe_junction_count=raw.pipe_junction_count;out.raw_occupied_crown_bins=raw.occupied_crown_bins;
        out.raw_segment_counts_by_order=raw.segment_counts_by_order;
        out.raw_girth_eligible_length=raw.girth_eligible_length;
        out.raw_girth_weighted_bud_charge=raw.girth_weighted_bud_charge;
        out.raw_mean_lateral_scaffold_pitch=raw.mean_lateral_scaffold_pitch;
        out.raw_maximum_major_wood_reach=raw.maximum_major_wood_reach;
        out.raw_pipe_max_relative_error=raw.pipe_max_relative_error;
        out.continuous_trunk_path=raw.segment_counts_by_order[0]>=7;out.graph_connected=true;
        out.foliage_derived_from_fine_segments=true;out.topology_signature=raw.signature;
        if(out.review) {
            out.source_branch_count=raw.branches.size();out.source_foliage_count=raw.foliage.size();
            adapt(out,raw.branches,raw.foliage,raw.height,raw.trunk_radius,raw.canopy_radius);
        } else {
            const auto reduced=NativeConiferRawRuntimeReducer::reduce(
                reduction_source(raw.branches,raw.foliage),out.canopy_density,out.render_lod_tier);
            out.source_branch_count=reduced.source_branch_count;out.source_foliage_count=reduced.source_foliage_count;
            adapt(out,reduced.branches,reduced.foliage,raw.height,raw.trunk_radius,raw.canopy_radius);
        }
    }
    const std::size_t pre_render_count=out.branches.size();
    const std::string request_key=identity_key(out,input.presentation)+":"+out.render_lod_tier;
    admit_native_tree_worker_serialized_identity(request_key);
    out.signature="tree-v10-"+hex8(unicode_stable_hash(request_key+":"+out.topology_signature+":"+
        std::to_string(pre_render_count)));
    if(!out.review && !out.impostor) {
        const auto reduced=NativeConiferRawRuntimeReducer::reduce(
            reduction_source(std::move(out.branches),std::move(out.foliage)),out.canopy_density,out.render_lod_tier);
        out.branches=reduced.branches;out.foliage=reduced.foliage;
        out.render_branch_budget=reduced.branch_budget;out.render_foliage_budget=reduced.foliage_budget;
    }
    out.collision_trunk_radius=out.trunk_radius;out.collision_trunk_height=std::max(2.0,out.height*0.52);
    out.valid=true;return out;
}

} // namespace voxel::world_backend
