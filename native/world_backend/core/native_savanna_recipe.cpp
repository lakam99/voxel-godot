#include "native_savanna_recipe.hpp"

#include <algorithm>
#include <cmath>
#include <cstdio>
#include <stdexcept>
#include <unordered_set>
#include <vector>

namespace voxel::world_backend {
namespace {
using V = NativeSavannaVec3;
constexpr double TAU = 6.28318530717958647692;
constexpr int MAX_SEGMENTS = 1120;
constexpr int MAX_FOLIAGE = 1540;
constexpr int MAX_FORKS = 6;
constexpr int MAX_SCAFFOLD = 760;

struct Node final {
    V position, direction;
    int parent = -1, order = 0, order_run = 0;
    std::vector<int> children;
    double stratum_bias = 0.0;
};
struct Segment final { int parent = -1, child = -1, order = 0; };
struct Graph final { std::vector<Node> nodes; std::vector<Segment> segments; std::vector<int> trunk; };
struct Pipe final {
    std::vector<NativeSavannaBranch> branches;
    std::vector<double> node_radii;
    double max_relative_error = 0.0;
    int junction_count = 0;
};
struct Candidate final {
    V position;
    int source_segment = -1, source_order = 0, cluster_index = 0;
    bool terminal = false;
    double exposure = 0.0, priority = 0.0;
};

V vec(double x, double y, double z) { return {static_cast<float>(x), static_cast<float>(y), static_cast<float>(z)}; }
V add(V a, V b) { return {a.x+b.x,a.y+b.y,a.z+b.z}; }
V sub(V a, V b) { return {a.x-b.x,a.y-b.y,a.z-b.z}; }
V mul(V a, double b) { const float f=static_cast<float>(b); return {a.x*f,a.y*f,a.z*f}; }
V div(V a, double b) { const float f=static_cast<float>(b); return {a.x/f,a.y/f,a.z/f}; }
double len2(V a) { const float x=a.x*a.x,y=a.y*a.y,z=a.z*a.z; return double(x+y+z); }
double len(V a) { return double(std::sqrt(static_cast<float>(len2(a)))); }
V norm(V a) { const float l=std::sqrt(static_cast<float>(len2(a))); return {a.x/l,a.y/l,a.z/l}; }
V cross(V a,V b) { return {a.y*b.z-a.z*b.y,a.z*b.x-a.x*b.z,a.x*b.y-a.y*b.x}; }
V lerp(V a,V b,double t) { return add(a,mul(sub(b,a),t)); }
double clamp(double v,double low,double high) { return std::clamp(v,low,high); }
int clampi(int v,int low,int high) { return std::clamp(v,low,high); }
double lerpf(double a,double b,double t) { return a+(b-a)*t; }
int roundi(double value) { return static_cast<int>(std::round(value)); }
int posmod(int value,int divisor) { const int result=value%divisor; return result<0?result+divisor:result; }

template <typename... Args> std::string key(const char *format, Args... args) {
    char buffer[256]; std::snprintf(buffer,sizeof(buffer),format,args...); return buffer;
}
double unit(const std::string &text) {
    return double(NativeConiferRecipeBuilder::stable_hash(text)&0x7fffffffU)/double(0x7fffffffU);
}
double signed_unit(const std::string &text) { return unit(text)*2.0-1.0; }

int append(Graph &graph,V position,int parent,int order,V direction) {
    const int index=static_cast<int>(graph.nodes.size());
    Node node; node.position=position;node.parent=parent;node.order=clampi(order,0,4);node.direction=norm(direction);
    if(parent>=0) {
        const Node &source=graph.nodes[static_cast<std::size_t>(parent)];
        node.order_run=source.order==order?source.order_run+1:1;
        node.stratum_bias=source.stratum_bias;
    }
    graph.nodes.push_back(node);
    if(parent>=0) {
        graph.nodes[static_cast<std::size_t>(parent)].children.push_back(index);
        graph.segments.push_back({parent,index,node.order});
    }
    return index;
}

void tag(Graph &graph,int node,double value) { graph.nodes[static_cast<std::size_t>(node)].stratum_bias=clamp(value,-1.0,1.0); }

double taper(const Node &node,double height,double crown_base) {
    if(node.order==0) {
        const double value=clamp(double(node.position.y)/std::max(1.0,crown_base+1.5),0.0,1.0);
        return lerpf(1.0,0.76,std::pow(value,0.88));
    }
    const double value=clamp((double(node.position.y)-crown_base)/std::max(1.0,height-crown_base),0.0,1.0);
    return lerpf(0.90,0.73,value)*lerpf(1.0,0.94,double(node.order)/4.0);
}

Pipe solve_pipe(const Graph &graph,double trunk_radius,double height,double crown_base) {
    Pipe out; std::vector<double> support(graph.nodes.size(),0.0);
    for(int index=static_cast<int>(graph.nodes.size())-1;index>=0;--index) {
        const Node &node=graph.nodes[static_cast<std::size_t>(index)]; double area=0.0;
        for(int child:node.children) area+=support[static_cast<std::size_t>(child)];
        if(node.children.empty()) area=node.order>=3?1.0:0.72;
        support[static_cast<std::size_t>(index)]=std::max(0.0001,area);
    }
    const double radius_scale=trunk_radius/std::sqrt(std::max(0.0001,support.front()));
    double maximum_height=1.0;
    for(const Node &node:graph.nodes) maximum_height=std::max(maximum_height,double(node.position.y));
    out.branches.reserve(graph.segments.size());
    for(const Segment &segment:graph.segments) {
        const Node &parent=graph.nodes[static_cast<std::size_t>(segment.parent)];
        const Node &child=graph.nodes[static_cast<std::size_t>(segment.child)];
        const double carried=std::sqrt(std::max(0.0001,support[static_cast<std::size_t>(segment.child)]))*radius_scale;
        double radius_start=carried*taper(parent,height,crown_base);
        const double radius_end=carried*taper(child,height,crown_base);
        if(segment.parent==0) radius_start*=1.24;
        out.branches.push_back({parent.position,child.position,std::max(0.055,radius_start),
            std::max(0.050,radius_end),segment.order,segment.parent,segment.child,child.stratum_bias,
            clamp(std::max(double(parent.position.y),double(child.position.y))/maximum_height,0.0,1.0)});
    }
    for(std::size_t index=0;index<graph.nodes.size();++index) {
        const Node &node=graph.nodes[index]; if(node.children.size()<2U) continue;
        ++out.junction_count;
        const double factor=taper(node,height,crown_base),area_factor=factor*factor;
        const double parent_area=support[index]*radius_scale*radius_scale*area_factor;
        double child_area=0.0;
        for(int child:node.children) child_area+=support[static_cast<std::size_t>(child)]*radius_scale*radius_scale*area_factor;
        out.max_relative_error=std::max(out.max_relative_error,
            std::abs(parent_area-child_area)/std::max(0.0001,parent_area));
    }
    out.node_radii.resize(graph.nodes.size()); out.node_radii.front()=trunk_radius;
    for(std::size_t index=1;index<graph.nodes.size();++index) {
        const double carried=std::sqrt(std::max(0.0001,support[index]))*radius_scale;
        out.node_radii[index]=std::max(0.050,carried*taper(graph.nodes[index],height,crown_base));
    }
    return out;
}

void append_twig_fan(Graph &graph,int parent,V radial,V side,double arm_length,
    int fork_index,int primary_index,int arm_index,int arm_step,std::int64_t seed,int scaffold_limit) {
    const double charge=arm_length/5.10;
    const int count=clampi(static_cast<int>(std::floor(charge+unit(key("savanna-twig-phase:%lld:%d:%d:%d:%d",
        static_cast<long long>(seed),fork_index,primary_index,arm_index,arm_step)))),1,2);
    for(int twig_index=0;twig_index<count;++twig_index) {
        if(static_cast<int>(graph.segments.size())>=scaffold_limit) return;
        const double sign=twig_index%2==0?-1.0:1.0;
        const V spread=mul(mul(side,sign),lerpf(0.38,0.70,unit(key("savanna-twig-spread:%lld:%d:%d:%d:%d:%d",
            static_cast<long long>(seed),fork_index,primary_index,arm_index,arm_step,twig_index))));
        const double rise=lerpf(-0.12,0.26,unit(key("savanna-twig-rise:%lld:%d:%d:%d:%d:%d",
            static_cast<long long>(seed),fork_index,primary_index,arm_index,arm_step,twig_index)));
        const V direction=norm(add(add(mul(radial,0.66),spread),vec(0.0,rise,0.0)));
        const double length=arm_length*lerpf(0.19,0.31,unit(key("savanna-twig-length:%lld:%d:%d:%d:%d:%d",
            static_cast<long long>(seed),fork_index,primary_index,arm_index,arm_step,twig_index)));
        const int twig=append(graph,add(graph.nodes[static_cast<std::size_t>(parent)].position,mul(direction,length)),parent,3,direction);
        tag(graph,twig,signed_unit(key("savanna-twig-stratum:%lld:%d:%d:%d:%d:%d",
            static_cast<long long>(seed),fork_index,primary_index,arm_index,arm_step,twig_index))*0.50);
        const V tip_direction=norm(add(add(mul(direction,0.82),mul(radial,0.16)),vec(0.0,0.08,0.0)));
        const int tip=append(graph,add(graph.nodes[static_cast<std::size_t>(twig)].position,
            mul(mul(tip_direction,length),0.72)),twig,4,tip_direction);
        tag(graph,tip,signed_unit(key("savanna-tip-stratum:%lld:%d:%d:%d:%d:%d",
            static_cast<long long>(seed),fork_index,primary_index,arm_index,arm_step,twig_index))*0.60);
    }
}

void append_arm(Graph &graph,int parent,V direction,V radial,V side,double arm_length,
    int fork_index,int primary_index,int arm_index,std::int64_t seed,int scaffold_limit) {
    int previous=parent;
    const int steps=clampi(static_cast<int>(std::ceil(arm_length/3.35)),2,4);
    for(int arm_step=0;arm_step<steps;++arm_step) {
        if(static_cast<int>(graph.segments.size())>=scaffold_limit) return;
        const double value=double(arm_step+1)/double(steps);
        const double arch=lerpf(0.20,-0.11,value);
        const double bend=signed_unit(key("savanna-arm-bend:%lld:%d:%d:%d:%d",static_cast<long long>(seed),
            fork_index,primary_index,arm_index,arm_step))*0.13;
        const V arm_direction=norm(add(add(add(direction,mul(radial,0.18)),mul(side,bend)),vec(0.0,arch,0.0)));
        const V start=graph.nodes[static_cast<std::size_t>(previous)].position;
        const int current=append(graph,add(start,div(mul(arm_direction,arm_length),double(steps))),
            previous,2,arm_direction);
        tag(graph,current,-0.16+value*0.32);
        append_twig_fan(graph,current,radial,side,arm_length,fork_index,primary_index,arm_index,arm_step,seed,scaffold_limit);
        previous=current;
    }
}

void build_trunk(Graph &graph,double fork_height,std::int64_t seed) {
    int previous=append(graph,vec(0,0,0),-1,0,vec(0,1,0));graph.trunk.push_back(previous);
    const int steps=std::max(7,static_cast<int>(std::ceil(fork_height/0.92)));
    const double phase=unit(key("savanna-trunk-phase:%lld",static_cast<long long>(seed)))*TAU;
    for(int step=1;step<=steps;++step) {
        const double value=double(step)/double(steps);
        const double sway=std::pow(value,1.45)*lerpf(0.16,0.86,
            unit(key("savanna-trunk-sway:%lld",static_cast<long long>(seed))));
        const V position=vec(std::cos(phase+value*2.45)*sway+std::sin(value*5.2+phase)*0.13*value,
            fork_height*value,std::sin(phase+value*2.04)*sway+std::cos(value*4.7+phase)*0.13*value);
        const V direction=norm(sub(position,graph.nodes[static_cast<std::size_t>(previous)].position));
        previous=append(graph,position,previous,0,direction);graph.trunk.push_back(previous);
    }
}

void build_crown(Graph &graph,double canopy_radius,double normalized_growth,std::int64_t seed,
    int scaffold_limit,NativeSavannaRecipe &recipe) {
    const double spacing=lerpf(7.6,5.2,normalized_growth)*lerpf(0.88,1.12,
        unit(key("savanna-leader-spacing:%lld",static_cast<long long>(seed))));
    const int fork_count=clampi(roundi(TAU*std::max(2.0,canopy_radius*0.34)/std::max(2.4,spacing)),3,MAX_FORKS);
    recipe.raised_fork_count=fork_count;
    const double phase=unit(key("savanna-fork-phase:%lld",static_cast<long long>(seed)))*TAU;
    double pitch_sum=0.0;int pitch_count=0;
    for(int fork_index=0;fork_index<fork_count;++fork_index) {
        if(static_cast<int>(graph.segments.size())>=scaffold_limit) break;
        double fork_phase=phase+double(fork_index)*TAU/double(fork_count);
        fork_phase+=signed_unit(key("savanna-fork-angle:%lld:%d",static_cast<long long>(seed),fork_index))*0.26;
        const V radial=vec(std::cos(fork_phase),0.0,std::sin(fork_phase));
        const V side=norm(cross(radial,vec(0,1,0)));
        const int back=1+posmod(fork_index*3,std::min(5,std::max(1,static_cast<int>(graph.trunk.size())-2)));
        const int fork_parent=graph.trunk[static_cast<std::size_t>(std::max(2,static_cast<int>(graph.trunk.size())-1-back))];
        const int main_steps=clampi(static_cast<int>(std::ceil(canopy_radius/lerpf(4.60,3.55,normalized_growth))),4,7);
        int previous=fork_parent;std::vector<int> primary_nodes;
        for(int step=0;step<main_steps;++step) {
            if(static_cast<int>(graph.segments.size())>=scaffold_limit) break;
            const double value=double(step+1)/double(main_steps);
            const double lift=lerpf(0.96,0.06,value)+signed_unit(key("savanna-fork-lift:%lld:%d:%d",
                static_cast<long long>(seed),fork_index,step))*0.10;
            const double curve=signed_unit(key("savanna-fork-curve:%lld:%d:%d",
                static_cast<long long>(seed),fork_index,step))*0.15;
            const V direction=norm(add(add(radial,mul(side,curve)),vec(0.0,lift,0.0)));
            const double step_length=canopy_radius/double(main_steps)*lerpf(0.94,1.12,
                unit(key("savanna-fork-step:%lld:%d:%d",static_cast<long long>(seed),fork_index,step)));
            const int current=append(graph,add(graph.nodes[static_cast<std::size_t>(previous)].position,
                mul(direction,step_length)),previous,1,direction);
            tag(graph,current,-0.28+value*0.54);primary_nodes.push_back(current);
            pitch_sum+=direction.y;++pitch_count;previous=current;
        }
        for(std::size_t primary_index=1;primary_index<primary_nodes.size();++primary_index) {
            if(static_cast<int>(graph.segments.size())>=scaffold_limit) break;
            const int branch_parent=primary_nodes[primary_index];
            const double primary_value=double(primary_index)/double(std::max<std::size_t>(1,primary_nodes.size()-1));
            const double remaining=canopy_radius*lerpf(0.34,0.54,primary_value);
            const double girth=remaining/std::max(1.0,canopy_radius);
            const double charge=remaining/lerpf(4.20,3.05,primary_value)*lerpf(0.86,1.14,girth);
            const int arm_count=clampi(static_cast<int>(std::floor(charge+unit(key("savanna-arm-phase:%lld:%d:%d",
                static_cast<long long>(seed),fork_index,static_cast<int>(primary_index))))),1,3);
            for(int arm_index=0;arm_index<arm_count;++arm_index) {
                if(static_cast<int>(graph.segments.size())>=scaffold_limit) break;
                const double sign=arm_index%2==0?-1.0:1.0,terminal=arm_index==2?0.30:0.0;
                const double rise=0.18+signed_unit(key("savanna-arm-rise:%lld:%d:%d:%d",
                    static_cast<long long>(seed),fork_index,static_cast<int>(primary_index),arm_index))*0.22;
                const V direction=norm(add(add(mul(radial,0.78+terminal),
                    mul(mul(side,sign),0.60-terminal*0.30)),vec(0.0,rise,0.0)));
                double length=remaining*lerpf(0.78,1.12,unit(key("savanna-arm-reach:%lld:%d:%d:%d",
                    static_cast<long long>(seed),fork_index,static_cast<int>(primary_index),arm_index)));
                length*=lerpf(0.80,1.12,unit(key("savanna-arm-length:%lld:%d:%d:%d",
                    static_cast<long long>(seed),fork_index,static_cast<int>(primary_index),arm_index)));
                append_arm(graph,branch_parent,direction,radial,mul(side,sign),length,fork_index,
                    static_cast<int>(primary_index),arm_index,seed,scaffold_limit);
                ++recipe.crown_window_count;
            }
        }
    }
    recipe.mean_lateral_scaffold_pitch=pitch_sum/double(std::max(1,pitch_count));
}

void germinate(Graph &graph,const Pipe &pipe,V crown_center,V crown_radii,double canopy_radius,
    std::int64_t seed,int segment_limit,NativeSavannaRecipe &recipe) {
    const std::size_t original=graph.segments.size();
    for(std::size_t segment_index=0;segment_index<original;++segment_index) {
        if(static_cast<int>(graph.segments.size())>=segment_limit) break;
        const Segment segment=graph.segments[segment_index];
        if(segment.order<1 || segment.order>2) continue;
        const V start=graph.nodes[static_cast<std::size_t>(segment.parent)].position;
        const V position=graph.nodes[static_cast<std::size_t>(segment.child)].position;
        const double segment_length=len(sub(position,start));
        const double carrying=pipe.node_radii[static_cast<std::size_t>(segment.child)];
        const double minimum=segment.order==1?0.24:0.15;
        // Order-one/two source axes are constructed from steps longer than 0.34
        // and always have a lateral component. The defensive GDScript fallbacks
        // are unreachable for this grammar's own graph, just as they are in the
        // frozen conifer port; keep the native hot loop branch-free.
        if(carrying<minimum) continue;
        const V local=sub(position,crown_center); const V horizontal=vec(local.x,0.0,local.z);
        const V outward=norm(horizontal);
        const double crown_unit=clamp(len(horizontal)/std::max(1.0,canopy_radius),0.0,1.0);
        const double vertical=clamp((double(position.y)-(double(crown_center.y)-double(crown_radii.y)))
            /std::max(0.1,double(crown_radii.y)*2.0),0.0,1.0);
        const double girth=std::pow(std::max(1.0,carrying/minimum),0.58);
        const double interior=std::pow(1.0-crown_unit,0.42)*lerpf(0.78,1.0,vertical);
        const double charge=segment_length*0.78*girth*interior;
        recipe.girth_eligible_length+=segment_length;recipe.girth_weighted_bud_charge+=charge;
        const int buds=clampi(static_cast<int>(std::floor(charge+unit(key("savanna-viable-bud-phase:%lld:%d",
            static_cast<long long>(seed),static_cast<int>(segment_index))))),0,segment.order==1?2:1);
        if(buds<=0) continue;
        const V side=norm(cross(outward,vec(0,1,0)));
        for(int bud=0;bud<buds;++bud) {
            if(static_cast<int>(graph.segments.size())>=segment_limit) break;
            ++recipe.viable_axis_bud_count;
            const double sign=(static_cast<int>(segment_index)+bud)%2==0?-1.0:1.0;
            const double lateral=lerpf(0.30,0.62,unit(key("savanna-viable-axis-lateral:%lld:%d:%d",
                static_cast<long long>(seed),static_cast<int>(segment_index),bud)));
            const double rise=lerpf(-0.05,0.20,unit(key("savanna-viable-axis-rise:%lld:%d:%d",
                static_cast<long long>(seed),static_cast<int>(segment_index),bud)));
            V heading=norm(add(add(mul(outward,0.78),mul(mul(side,sign),lateral)),vec(0.0,rise,0.0)));
            double span=std::max(1.35,carrying*4.35)*lerpf(0.80,1.16,interior);
            span*=lerpf(0.88,1.10,unit(key("savanna-viable-axis-span:%lld:%d:%d",
                static_cast<long long>(seed),static_cast<int>(segment_index),bud)));
            // Every metamer advances by a partition of this total span. Capping
            // it to 1.08R minus the current horizontal radius proves, by the
            // triangle inequality, that every successor remains within 1.08R.
            span=std::min(span,std::max(0.0,canopy_radius*1.08-len(horizontal)));
            if(span<1.05) continue;
            const int metamers=clampi(static_cast<int>(std::ceil(span/1.55)),2,4);
            int previous=segment.child,grown=0;V current_heading=heading;
            for(int metamer=0;metamer<metamers;++metamer) {
                if(static_cast<int>(graph.segments.size())>=segment_limit) break;
                const double value=double(metamer+1)/double(metamers);
                const double arch=lerpf(0.16,-0.09,value);
                const double bend=signed_unit(key("savanna-viable-axis-bend:%lld:%d:%d:%d",
                    static_cast<long long>(seed),static_cast<int>(segment_index),bud,metamer))*0.12;
                current_heading=norm(add(add(add(mul(current_heading,0.78),mul(outward,0.16)),mul(side,bend)),vec(0.0,arch,0.0)));
                const V endpoint=add(graph.nodes[static_cast<std::size_t>(previous)].position,
                    div(mul(current_heading,span),double(metamers)));
                const V endpoint_local=sub(endpoint,crown_center);
                // span is already clamped to 1.08R minus the source horizontal
                // radius, so the former >1.10R guard is unreachable by the
                // triangle inequality. Vertical arching remains independently
                // bounded here, matching the live grammar's reachable behavior.
                if(std::abs(double(endpoint_local.y))>double(crown_radii.y)*1.24) break;
                const int current=append(graph,endpoint,previous,std::min(segment.order+1,4),current_heading);
                tag(graph,current,clamp(vertical*2.0-1.0,-1.0,1.0));previous=current;++grown;
            }
            if(grown>=2) {++recipe.germinated_axis_count;recipe.grown_metamer_count+=grown;}
        }
    }
}

std::vector<NativeSavannaFoliage> build_foliage(const Graph &graph,V center,V radii,double height,
    std::int64_t seed,int foliage_limit) {
    std::vector<Candidate> candidates;
    for(std::size_t index=0;index<graph.segments.size();++index) {
        const Segment &segment=graph.segments[index]; if(segment.order<2) continue;
        const V start=graph.nodes[static_cast<std::size_t>(segment.parent)].position;
        const V end=graph.nodes[static_cast<std::size_t>(segment.child)].position;
        const bool terminal=graph.nodes[static_cast<std::size_t>(segment.child)].children.empty();
        const V direction=norm(sub(end,start));
        // Savanna foliage is emitted only on order-two/finer lateral wood, so a
        // vertical carrier cannot enter this source-authoritative candidate set.
        const V side=norm(cross(direction,vec(0,1,0))); const V normal=norm(cross(direction,side));
        if(unit(key("savanna-window:%lld:%d",static_cast<long long>(seed),static_cast<int>(index)))<0.18) continue;
        const int clusters=segment.order==2?1:2;
        for(int cluster=0;cluster<clusters;++cluster) {
            const double value=(double(cluster)+0.40)/double(clusters);
            const double jitter_a=signed_unit(key("savanna-leaf-a:%lld:%d:%d",static_cast<long long>(seed),static_cast<int>(index),cluster));
            const double jitter_b=signed_unit(key("savanna-leaf-b:%lld:%d:%d",static_cast<long long>(seed),static_cast<int>(index),cluster));
            V position=lerp(start,end,clamp(value+jitter_a*0.13,0.10,1.0));
            position=add(position,add(mul(mul(side,jitter_a),0.58),mul(mul(normal,jitter_b),0.42)));
            const V local=sub(position,center);
            const double envelope=len(vec(double(local.x)/std::max(0.1,double(radii.x)),
                double(local.y)/std::max(0.1,double(radii.y)),double(local.z)/std::max(0.1,double(radii.z))));
            const double exposure=clamp((envelope-0.12)/0.88,0.0,1.0);
            const double priority=exposure*0.40+double(segment.order)/4.0*0.20+(terminal?0.24:0.0)
                +unit(key("savanna-leaf-priority:%lld:%d:%d",static_cast<long long>(seed),static_cast<int>(index),cluster))*0.16;
            candidates.push_back({position,static_cast<int>(index),segment.order,cluster,terminal,exposure,priority});
        }
    }
    std::stable_sort(candidates.begin(),candidates.end(),[](const Candidate &left,const Candidate &right) {
        return left.priority>right.priority;
    });
    const int budget=std::min(foliage_limit,static_cast<int>(candidates.size()));
    std::vector<NativeSavannaFoliage> out;out.reserve(static_cast<std::size_t>(budget));
    for(int index=0;index<budget;++index) {
        const Candidate &candidate=candidates[static_cast<std::size_t>(index)];
        double scale=lerpf(1.38,2.54,candidate.exposure)*lerpf(0.94,1.10,
            unit(key("savanna-leaf-size:%lld:%d:%d",static_cast<long long>(seed),candidate.source_segment,candidate.cluster_index)));
        if(candidate.terminal) scale*=1.08;
        const V rotation=vec(signed_unit(key("savanna-leaf-rx:%lld:%d:%d",static_cast<long long>(seed),candidate.source_segment,candidate.cluster_index))*0.21,
            unit(key("savanna-leaf-ry:%lld:%d:%d",static_cast<long long>(seed),candidate.source_segment,candidate.cluster_index))*TAU,
            signed_unit(key("savanna-leaf-rz:%lld:%d:%d",static_cast<long long>(seed),candidate.source_segment,candidate.cluster_index))*0.18);
        const V scale_value=vec(scale*1.40,scale*1.04,scale*1.27);
        const double wind=clamp(double(candidate.position.y)/std::max(1.0,height),0.20,1.0);
        const double variation=clamp(0.16+candidate.exposure*0.56+
            unit(key("savanna-leaf-color:%lld:%d:%d",static_cast<long long>(seed),candidate.source_segment,candidate.cluster_index))*0.24,0.0,1.0);
        const int variant=posmod(static_cast<int>(NativeConiferRecipeBuilder::stable_hash(
            key("savanna-leaf-variant:%lld:%d:%d",static_cast<long long>(seed),candidate.source_segment,candidate.cluster_index))),4);
        out.push_back({candidate.position,rotation,scale_value,wind,variation,candidate.exposure,variant,
            candidate.source_segment,candidate.source_order});
    }
    return out;
}

std::string signature(const NativeSavannaRecipe &recipe) {
    char buffer[256];
    std::snprintf(buffer,sizeof(buffer),"math-tree-v2:%lld:%d:%d:%zu",static_cast<long long>(recipe.seed),
        roundi(recipe.maturity*100000.0),roundi(recipe.height*1000.0),recipe.branches.size());
    std::uint32_t value=NativeConiferRecipeBuilder::stable_hash(buffer);
    for(const auto &branch:recipe.branches) {
        std::snprintf(buffer,sizeof(buffer),"%u:%d,%d,%d:%d,%d,%d:%d:%d:%d",value,
            roundi(double(branch.start.x)*1000.0),roundi(double(branch.start.y)*1000.0),roundi(double(branch.start.z)*1000.0),
            roundi(double(branch.end.x)*1000.0),roundi(double(branch.end.y)*1000.0),roundi(double(branch.end.z)*1000.0),
            roundi(branch.radius_start*1000.0),roundi(branch.radius_end*1000.0),branch.order);
        value=NativeConiferRecipeBuilder::stable_hash(buffer);
    }
    for(const auto &anchor:recipe.foliage) {
        std::snprintf(buffer,sizeof(buffer),"%u:%d,%d,%d:%d",value,roundi(double(anchor.position.x)*1000.0),
            roundi(double(anchor.position.y)*1000.0),roundi(double(anchor.position.z)*1000.0),anchor.source_order);
        value=NativeConiferRecipeBuilder::stable_hash(buffer);
    }
    std::snprintf(buffer,sizeof(buffer),"%08x",value);return buffer;
}
}

NativeSavannaRecipe NativeSavannaRecipeBuilder::build(std::int64_t seed,double maturity) {
    return build_with_limits(seed,maturity,MAX_SEGMENTS,MAX_SCAFFOLD,MAX_FOLIAGE);
}

NativeSavannaRecipe NativeSavannaRecipeBuilder::build_with_limits(std::int64_t seed,double maturity,
    int segment_limit,int scaffold_limit,int foliage_limit) {
    if(!std::isfinite(maturity)) throw std::invalid_argument("savanna maturity must be finite");
    NativeSavannaRecipe recipe;recipe.seed=seed;recipe.maturity=clamp(maturity,0.12,1.0);
    const double growth=(1.0-std::exp(-3.25*recipe.maturity))/(1.0-std::exp(-3.25));
    recipe.height=lerpf(10.5,29.5,growth);
    recipe.trunk_radius=lerpf(0.58,2.48,std::pow(growth,0.71));
    recipe.crown_base=lerpf(3.4,8.8,std::pow(growth,0.83));
    recipe.canopy_radius=lerpf(7.0,23.5,std::pow(growth,0.86));
    recipe.crown_height=lerpf(3.8,9.6,std::pow(growth,0.78));
    recipe.crown_center=vec(0.0,recipe.crown_base+recipe.crown_height*0.72,0.0);
    recipe.crown_radii=vec(recipe.canopy_radius,recipe.crown_height*0.66,recipe.canopy_radius*0.91);
    Graph graph;build_trunk(graph,recipe.crown_base,seed);
    build_crown(graph,recipe.canopy_radius,growth,seed,scaffold_limit,recipe);
    const Pipe preliminary=solve_pipe(graph,recipe.trunk_radius,recipe.height,recipe.crown_base);
    germinate(graph,preliminary,recipe.crown_center,recipe.crown_radii,recipe.canopy_radius,seed,segment_limit,recipe);
    const Pipe final_pipe=solve_pipe(graph,recipe.trunk_radius,recipe.height,recipe.crown_base);
    recipe.branches=final_pipe.branches;recipe.pipe_junction_count=final_pipe.junction_count;
    recipe.pipe_max_relative_error=final_pipe.max_relative_error;
    recipe.foliage=build_foliage(graph,recipe.crown_center,recipe.crown_radii,recipe.height,seed,foliage_limit);
    recipe.node_count=static_cast<int>(graph.nodes.size());
    for(const Segment &segment:graph.segments) ++recipe.segment_counts_by_order[static_cast<std::size_t>(clampi(segment.order,0,4))];
    for(const auto &branch:recipe.branches) if(branch.order>=1 && branch.order<=2) {
        recipe.maximum_major_wood_reach=std::max(recipe.maximum_major_wood_reach,
            std::sqrt(double(branch.end.x)*branch.end.x+double(branch.end.z)*branch.end.z));
    }
    std::unordered_set<int> occupied;
    for(const auto &anchor:recipe.foliage) {
        const V local=sub(anchor.position,recipe.crown_center);
        double angle=std::fmod(std::atan2(double(local.z),double(local.x)),TAU);if(angle<0.0) angle+=TAU;
        const int angle_bin=clampi(static_cast<int>(std::floor(angle/TAU*10.0)),0,9);
        const double height_unit=clamp((double(local.y)/std::max(0.1,double(recipe.crown_radii.y))+1.0)*0.5,0.0,0.999);
        const int height_bin=clampi(static_cast<int>(std::floor(height_unit*5.0)),0,4);
        occupied.insert(angle_bin*5+height_bin);
    }
    recipe.occupied_crown_bins=static_cast<int>(occupied.size());
    recipe.signature=signature(recipe);
    return recipe;
}

NativeSavannaRecipe NativeSavannaRecipeBuilder::build_boundary_guard_fixture_for_test(
    const std::int64_t seed) {
    Graph graph;
    const int root=append(graph,vec(0,0,0),-1,0,vec(0,1,0));
    append(graph,vec(5.0,10.1,0.0),root,1,vec(5.0,10.1,0.0));
    Pipe pipe;pipe.node_radii={1.0,1.0};
    NativeSavannaRecipe recipe;
    germinate(graph,pipe,vec(0,5,0),vec(10,4,10),10.0,seed,100,recipe);
    recipe.branches=solve_pipe(graph,1.0,12.0,5.0).branches;
    return recipe;
}

} // namespace voxel::world_backend
