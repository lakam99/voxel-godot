#include "native_conifer_raw_runtime_reducer.hpp"

#include <algorithm>
#include <cctype>
#include <cmath>
#include <map>
#include <limits>
#include <stdexcept>
#include <unordered_map>
#include <utility>

namespace voxel::world_backend {
namespace {
int roundi(double x) {
    if (!std::isfinite(x) || x < double(std::numeric_limits<int>::min())
        || x > double(std::numeric_limits<int>::max())) {
        throw std::invalid_argument("conifer budget cannot be represented as an integer");
    }
    return static_cast<int>(std::round(x));
}
int clampi(int x, int lo, int hi) { return std::clamp(x,lo,hi); }
double lerpf(double a, double b, double t) { return a+(b-a)*t; }

std::string normalize_tier(const std::string &input) {
    // Godot's strip_edges/to_lower is Unicode-aware. The declared LOD names
    // are ASCII; fail explicitly on other UTF-8 rather than misnormalizing it.
    for (unsigned char ch:input) if (ch>=0x80U) throw std::invalid_argument("conifer LOD tier must be ASCII");
    std::size_t first=0,last=input.size();
    while (first<last && std::isspace(static_cast<unsigned char>(input[first]))) ++first;
    while (last>first && std::isspace(static_cast<unsigned char>(input[last-1]))) --last;
    std::string result=input.substr(first,last-first);
    for (char &ch:result) ch=static_cast<char>(std::tolower(static_cast<unsigned char>(ch)));
    return (result=="near" || result=="mid" || result=="far" || result=="impostor") ? result : "near";
}

template <typename T> std::vector<T> even_reduce(const std::vector<T> &source, int budget) {
    // Every caller reaches this helper only after proving source > budget:
    // whole-source overflow, representative overflow, or excess foliage.
    std::vector<T> result; result.reserve(static_cast<std::size_t>(budget));
    const double stride=double(source.size())/double(budget);
    for (int index=0;index<budget;++index) {
        const int selected=clampi(static_cast<int>(std::floor((double(index)+0.5)*stride)),0,static_cast<int>(source.size())-1);
        result.push_back(source[static_cast<std::size_t>(selected)]);
    }
    return result;
}

std::vector<int> ancestry(int index,const std::vector<NativeConiferBranch> &branches,
    const std::unordered_map<int,int> &source_by_child,const std::vector<bool> &selected) {
    std::vector<int> path; std::vector<bool> visited(branches.size(),false);
    int current=index;
    // current is either -1 or an index taken from source_by_child, whose
    // entries are constructed from [0, branches.size()).
    while (current>=0 && !selected[static_cast<std::size_t>(current)]
        && !visited[static_cast<std::size_t>(current)]) {
        visited[static_cast<std::size_t>(current)]=true;
        path.push_back(current);
        const auto found=source_by_child.find(branches[static_cast<std::size_t>(current)].parent_node);
        current=found==source_by_child.end()?-1:found->second;
    }
    std::reverse(path.begin(),path.end());
    return path;
}

std::vector<NativeConiferBranch> reduce_branches(const std::vector<NativeConiferBranch> &source,int budget) {
    if (source.size()<=static_cast<std::size_t>(budget)) return source;
    std::unordered_map<int,int> source_by_child;
    for (std::size_t i=0;i<source.size();++i) if(source[i].child_node>=0) source_by_child[source[i].child_node]=static_cast<int>(i);
    std::vector<bool> selected(source.size(),false); std::size_t selected_count=0;
    const auto include=[&](int index) {
        // ancestry stops at any selected branch, so every returned index is new.
        for (int ancestor:ancestry(index,source,source_by_child,selected)) {
            selected[static_cast<std::size_t>(ancestor)]=true;++selected_count;
        }
    };
    for (std::size_t i=0;i<source.size();++i) if(source[i].order==0) include(static_cast<int>(i));
    const std::size_t effective_budget=std::max(static_cast<std::size_t>(budget),selected_count);
    for (int order=1;order<=4;++order) {
        std::vector<int> candidates;
        for (std::size_t i=0;i<source.size();++i) if(source[i].order==order) candidates.push_back(static_cast<int>(i));
        if (candidates.empty() || selected_count>=effective_budget) continue;
        const int remaining=static_cast<int>(effective_budget-selected_count);
        const double stride=double(candidates.size())/double(std::max(1,remaining));
        const int sample_count=std::min(remaining,static_cast<int>(candidates.size()));
        for (int sample=0;sample<sample_count;++sample) {
            const int candidate=candidates[static_cast<std::size_t>(clampi(
                static_cast<int>(std::floor((double(sample)+0.5)*stride)),0,static_cast<int>(candidates.size())-1))];
            if (selected[static_cast<std::size_t>(candidate)]) continue;
            const auto path=ancestry(candidate,source,source_by_child,selected);
            if (selected_count+path.size()>effective_budget) continue;
            for (int item:path) {selected[static_cast<std::size_t>(item)]=true;++selected_count;}
            if (selected_count>=effective_budget) break;
        }
    }
    std::vector<NativeConiferBranch> result; result.reserve(selected_count);
    for (std::size_t i=0;i<source.size();++i) if(selected[i]) result.push_back(source[i]);
    return result;
}

std::vector<NativeConiferFoliage> reduce_foliage(const std::vector<NativeConiferFoliage> &source,int budget) {
    if (source.size()<=static_cast<std::size_t>(budget)) return source;
    std::map<int,std::vector<NativeConiferFoliage>> by_segment;
    for (const auto &anchor:source) {
        if (anchor.source_segment<0) return even_reduce(source,budget);
        by_segment[anchor.source_segment].push_back(anchor);
    }
    if (by_segment.size()<2) return even_reduce(source,budget);
    std::vector<NativeConiferFoliage> representatives,overflow;
    for (const auto &[segment, anchors]:by_segment) {
        (void)segment;
        representatives.push_back(anchors.front());
        for (std::size_t i=1;i<anchors.size();++i) overflow.push_back(anchors[i]);
    }
    if (representatives.size()>static_cast<std::size_t>(budget)) return even_reduce(representatives,budget);
    std::vector<NativeConiferFoliage> result=std::move(representatives);
    const int remaining=std::min(budget-static_cast<int>(result.size()),static_cast<int>(overflow.size()));
    if (remaining>0) {
        auto extra=even_reduce(overflow,remaining);
        result.insert(result.end(),extra.begin(),extra.end());
    }
    return result;
}
}

NativeConiferRawReduction NativeConiferRawRuntimeReducer::reduce(const NativeConiferRecipe &raw,
    double canopy_density,const std::string &lod_tier) {
    if (!std::isfinite(canopy_density)) throw std::invalid_argument("conifer canopy density must be finite");
    const std::string tier=normalize_tier(lod_tier);
    const double scale=tier=="mid"?0.52:(tier=="far"?0.23:(tier=="impostor"?0.0:1.0));
    NativeConiferRawReduction out;
    out.source_branch_count=raw.branches.size(); out.source_foliage_count=raw.foliage.size();
    out.branch_budget=clampi(roundi(420.0*lerpf(0.70,1.0,canopy_density)*scale),24,420);
    out.foliage_budget=clampi(roundi(620.0*lerpf(0.70,1.0,canopy_density)*scale),32,620);
    out.branches=reduce_branches(raw.branches,out.branch_budget);
    out.foliage=reduce_foliage(raw.foliage,out.foliage_budget);
    return out;
}
} // namespace voxel::world_backend
