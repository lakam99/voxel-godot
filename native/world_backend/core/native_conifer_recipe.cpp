#include "native_conifer_recipe.hpp"

#include <algorithm>
#include <cmath>
#include <cstdio>
#include <limits>
#include <stdexcept>
#include <unordered_set>

namespace voxel::world_backend {
namespace {
using V = NativeConiferVec3;
constexpr double PI = 3.14159265358979323846;
constexpr double TAU = 6.28318530717958647692;
constexpr double GOLDEN_ANGLE = 2.399963229728653;
constexpr int MAX_SEGMENTS = 1120;
constexpr int MAX_FOLIAGE = 1480;

struct Node {
    V position, direction;
    int parent = -1, order = 0, order_run = 0;
    std::vector<int> children;
    double stratum_bias = 0.0;
};
struct Segment { int parent, child, order; bool interstitial = false; };
struct Graph { std::vector<Node> nodes; std::vector<Segment> segments; std::vector<int> trunk; };

V vec(double x, double y, double z) { return {static_cast<float>(x), static_cast<float>(y), static_cast<float>(z)}; }
V add(V a, V b) { return {a.x+b.x, a.y+b.y, a.z+b.z}; }
V sub(V a, V b) { return {a.x-b.x, a.y-b.y, a.z-b.z}; }
V mul(V a, double b) { const float f=static_cast<float>(b); return {a.x*f, a.y*f, a.z*f}; }
double len2(V a) { const float x2=a.x*a.x,y2=a.y*a.y,z2=a.z*a.z; return double(x2+y2+z2); }
double len(V a) { return double(std::sqrt(static_cast<float>(len2(a)))); }
// Every direction passed here has a nonzero radial or vertical component:
// leader edges have positive height; bough/branchlet vectors have radial reach;
// the foliage side is crossed from a nonvertical carrier. No zero-length
// direction can arise from admitted seed/maturity inputs.
V norm(V a) { const float l=std::sqrt(static_cast<float>(len2(a))); return {a.x/l,a.y/l,a.z/l}; }
V cross(V a, V b) { return {a.y*b.z-a.z*b.y, a.z*b.x-a.x*b.z, a.x*b.y-a.y*b.x}; }
V lerp(V a, V b, double t) { return add(a, mul(sub(b, a), static_cast<float>(t))); }
double clamp(double v, double low, double high) { return std::clamp(v, low, high); }
int clampi(int v, int low, int high) { return std::clamp(v, low, high); }
double lerpf(double a, double b, double t) { return a + (b - a) * t; }
// Godot roundi rounds exact half ties away from zero, including -0.5/-1.5.
int roundi(double x) { return static_cast<int>(std::round(x)); }
std::string key(const char *format, std::int64_t seed, int a = 0, int b = 0, int c = 0) {
    char buffer[192]; std::snprintf(buffer, sizeof(buffer), format, static_cast<long long>(seed), a, b, c); return buffer;
}
double unit(const std::string &s) { return double(NativeConiferRecipeBuilder::stable_hash(s) & 0x7fffffffU) / double(0x7fffffffU); }
double signed_unit(const std::string &s) { return unit(s) * 2.0 - 1.0; }
int append(Graph &g, V position, int parent, int order, V direction) {
    const int index = static_cast<int>(g.nodes.size());
    Node node; node.position = position; node.parent = parent; node.order = clampi(order, 0, 4);
    // All append call sites supply the already-normalized, nonzero direction
    // or the root's up axis; the GDScript zero-direction fallback is unreachable.
    node.direction = norm(direction);
    if (parent >= 0) {
        const Node &p = g.nodes[parent];
        node.order_run = p.order == order ? p.order_run + 1 : 1;
        node.stratum_bias = p.stratum_bias;
    }
    g.nodes.push_back(node);
    if (parent >= 0) {
        g.nodes[parent].children.push_back(index);
        g.segments.push_back({parent, index, node.order, false});
    }
    return index;
}
int nearest_trunk(const Graph &g, double y) {
    int selected = g.trunk.front(); double nearest = std::numeric_limits<double>::infinity();
    for (int index : g.trunk) { const double d = std::abs(double(g.nodes[index].position.y) - y); if (d < nearest) { nearest = d; selected = index; } }
    return selected;
}
double mean(const std::vector<double> &values) {
    if (values.empty()) return 0.0;
    double total = 0.0; for (double value : values) total += value; return total / double(values.size());
}
void interstitial(Graph &g, int attach, V radial, double length, double bias) {
    const V down = vec(0,-1,0), up = vec(0,1,0);
    const V start = g.nodes[attach].position;
    const V primary_direction = norm(add(mul(radial,0.98), mul(down,0.10)));
    const int primary = append(g, add(start,mul(primary_direction,length*0.58)), attach, 1, primary_direction);
    g.nodes[primary].stratum_bias = clamp(bias,-1,1); g.segments.back().interstitial = true;
    // radial=(cos(a),0,sin(a)); cross(radial,UP) has unit length.
    const V side = norm(cross(radial,up));
    const V secondary_direction = norm(add(add(mul(radial,0.68),mul(side,0.32)),mul(down,0.30)));
    const int secondary = append(g,add(g.nodes[primary].position,mul(secondary_direction,length*0.30)),primary,2,secondary_direction);
    g.nodes[secondary].stratum_bias = clamp(bias,-1,1); g.segments.back().interstitial = true;
    const V tip_direction = norm(add(mul(secondary_direction,0.82),mul(radial,0.18)));
    const int tip = append(g,add(g.nodes[secondary].position,mul(tip_direction,length*0.22)),secondary,3,tip_direction);
    g.nodes[tip].stratum_bias = clamp(bias,-1,1); g.segments.back().interstitial = true;
}
double taper(const Node &node, double height, double crown_base) {
    if (node.order == 0) {
        const double u = clamp(double(node.position.y) / std::max(1.0,crown_base+1.5),0,1);
        return lerpf(1.0,0.76,std::pow(u,0.88));
    }
    const double u = clamp((double(node.position.y)-crown_base)/std::max(1.0,height-crown_base),0,1);
    return lerpf(0.90,0.73,u)*lerpf(1.0,0.94,double(node.order)/4.0);
}
std::string signature(const NativeConiferRecipe &r) {
    char buffer[256];
    std::snprintf(buffer,sizeof(buffer),"math-tree-v2:%lld:%d:%d:%zu",static_cast<long long>(r.seed),roundi(r.maturity*100000),roundi(r.height*1000),r.branches.size());
    std::uint32_t value = NativeConiferRecipeBuilder::stable_hash(buffer);
    for (const auto &branch : r.branches) {
        std::snprintf(buffer,sizeof(buffer),"%u:%d,%d,%d:%d,%d,%d:%d:%d:%d",value,
            roundi(double(branch.start.x)*1000),roundi(double(branch.start.y)*1000),roundi(double(branch.start.z)*1000),
            roundi(double(branch.end.x)*1000),roundi(double(branch.end.y)*1000),roundi(double(branch.end.z)*1000),
            roundi(branch.radius_start*1000),roundi(branch.radius_end*1000),branch.order);
        value = NativeConiferRecipeBuilder::stable_hash(buffer);
    }
    for (const auto &anchor : r.foliage) {
        std::snprintf(buffer,sizeof(buffer),"%u:%d,%d,%d:%d",value,
            roundi(double(anchor.position.x)*1000),roundi(double(anchor.position.y)*1000),roundi(double(anchor.position.z)*1000),anchor.source_order);
        value = NativeConiferRecipeBuilder::stable_hash(buffer);
    }
    std::snprintf(buffer,sizeof(buffer),"%08x",value); return buffer;
}
}

std::uint32_t NativeConiferRecipeBuilder::stable_hash(const std::string &text) {
    std::uint32_t value = 2166136261U;
    // GDScript String.unicode_at iterates Unicode scalar values, not UTF-8 bytes.
    for (unsigned char ch : text) value = (value ^ ch) * 16777619U; // All grammar keys are ASCII.
    return value;
}

NativeConiferRecipe NativeConiferRecipeBuilder::build(std::int64_t seed, double maturity) {
    return build_with_limits(seed, maturity, MAX_SEGMENTS, MAX_FOLIAGE);
}

NativeConiferRecipe NativeConiferRecipeBuilder::build_with_limits(std::int64_t seed, double maturity,
    int segment_limit, int foliage_limit) {
    if (!std::isfinite(maturity)) throw std::invalid_argument("conifer maturity must be finite");
    NativeConiferRecipe r; r.seed = seed; r.maturity = clamp(maturity,0.12,1.0);
    const double growth = (1.0-std::exp(-3.15*r.maturity))/(1.0-std::exp(-3.15));
    r.height = lerpf(15.5,53.0,growth);
    r.trunk_radius = lerpf(0.56,2.08,std::pow(growth,0.78));
    r.crown_base = lerpf(1.35,2.60,std::pow(growth,0.82));
    r.crown_height = r.height-r.crown_base;
    r.canopy_radius = lerpf(3.65,14.3,std::pow(growth,0.88));
    r.first_whorl_height = r.crown_base+lerpf(1.80,3.80,std::pow(growth,0.66));
    r.crown_center = vec(0,r.crown_base+r.crown_height*0.46,0);
    r.crown_radii = vec(r.canopy_radius,r.crown_height*0.50,r.canopy_radius*0.94);
    Graph g;
    int previous = append(g,vec(0,0,0),-1,0,vec(0,1,0)); g.trunk.push_back(previous);
    const int steps = std::max(12,static_cast<int>(std::ceil(r.height/1.18)));
    const double leader_phase = unit(key("conifer-leader-phase:%lld",seed))*TAU;
    for (int step=1;step<=steps;++step) {
        const double u=double(step)/steps, drift=std::pow(u,1.72)*0.46;
        const V position=vec(std::cos(leader_phase+u*1.9)*drift,r.height*u,std::sin(leader_phase+u*1.6)*drift);
        const V direction=norm(sub(position,g.nodes[previous].position));
        previous=append(g,position,previous,0,direction); g.trunk.push_back(previous);
    }
    r.whorl_count=clampi(roundi(lerpf(6.0,14.0,growth)),6,14);
    const double phase=unit(key("conifer-whorl-phase:%lld",seed))*TAU;
    const double crown_top=r.crown_base+r.crown_height*0.96;
    std::vector<double> lower,upper; double curtain_pitch_sum=0,bud_charge_sum=0; int curtain_count=0;
    for (int wi=0;wi<r.whorl_count;++wi) {
        if (g.segments.size()>=static_cast<std::size_t>(segment_limit)) break;
        const double cu=double(wi)/std::max(1,r.whorl_count-1);
        double y=lerpf(r.first_whorl_height,crown_top,std::pow(cu,0.84));
        y+=signed_unit(key("conifer-whorl-y:%lld:%d",seed,wi))*lerpf(0.56,0.14,cu);
        y=clamp(y,r.first_whorl_height,crown_top);
        const int attach=nearest_trunk(g,y);
        const double irregularity=lerpf(0.88,1.10,unit(key("conifer-whorl-length:%lld:%d",seed,wi)));
        const double length=std::max(1.45,r.canopy_radius*std::pow(1.0-cu,0.64)*irregularity);
        const double circumference=TAU*std::max(0.45,length*lerpf(0.105,0.072,cu));
        const double spacing=lerpf(2.55,1.64,cu)*lerpf(0.90,1.10,unit(key("conifer-bud-spacing:%lld:%d",seed,wi)));
        const double charge=circumference/std::max(0.30,spacing)*lerpf(1.05,0.64,cu);
        const int boughs=clampi(static_cast<int>(std::floor(charge+unit(key("conifer-bud-phase:%lld:%d",seed,wi)))),2,5);
        bud_charge_sum+=charge;
        if (cu<0.34) lower.push_back(length); else if (cu>0.68) upper.push_back(length);
        for (int bi=0;bi<boughs;++bi) {
            if (g.segments.size()>=static_cast<std::size_t>(segment_limit)) break;
            double angle=phase+wi*GOLDEN_ANGLE*0.38+bi*TAU/boughs;
            angle+=signed_unit(key("conifer-whorl-angle:%lld:%d:%d",seed,wi,bi))*0.18;
            const V radial=vec(std::cos(angle),0,std::sin(angle));
            const int primary_steps=clampi(static_cast<int>(std::ceil(length/lerpf(2.24,1.72,cu))),2,6);
            int prior=attach;
            for (int pi=0;pi<primary_steps;++pi) {
                if (g.segments.size()>=static_cast<std::size_t>(segment_limit)) break;
                const double su=double(pi+1)/primary_steps;
                const double droop=lerpf(-0.16,0.18,cu)-std::pow(su,1.32)*lerpf(0.16,0.035,cu);
                const V direction=norm(add(mul(radial,0.985),vec(0,droop,0)));
                const double step_length=length/primary_steps*lerpf(0.92,1.08,unit(key("conifer-primary-step:%lld:%d:%d",seed,wi,pi)));
                const V start=g.nodes[prior].position;
                const int primary=append(g,add(start,mul(direction,step_length)),prior,1,direction);
                g.nodes[primary].stratum_bias=clamp(cu*2-1,-1,1);
                // primary_steps is clamped to [2,6]; every scaffold carries
                // fine shoots in the active grammar.
                {
                    const double branchlet_charge=step_length*lerpf(0.96,0.70,cu)*lerpf(1.12,0.72,su);
                    const int total=clampi(static_cast<int>(std::floor(branchlet_charge+unit(key("conifer-branchlet-phase:%lld:%d:%d:%d",seed,wi,bi,pi)))),1,3);
                    for (int ci=0;ci<total;++ci) {
                        if (g.segments.size()>=static_cast<std::size_t>(segment_limit)) break;
                        const V side=norm(cross(radial,vec(0,1,0)));
                        const double sign=(ci+pi+bi)%2==0?-1.0:1.0;
                        const V curtain_direction=norm(add(add(mul(radial,0.74),mul(side,sign*0.36)),vec(0,-lerpf(0.38,0.16,cu),0)));
                        const double curtain_length=step_length*lerpf(1.18,0.68,cu);
                        const int curtain=append(g,add(add(start,mul(direction,step_length)),mul(curtain_direction,curtain_length)),primary,2,curtain_direction);
                        g.nodes[curtain].stratum_bias=clamp(cu*2-1,-1,1);
                        const V tip_direction=norm(add(add(mul(curtain_direction,0.80),mul(radial,0.22)),vec(0,-0.04,0)));
                        const int tip=append(g,add(g.nodes[curtain].position,mul(tip_direction,curtain_length*0.76)),curtain,3,tip_direction);
                        g.nodes[tip].stratum_bias=clamp(cu*2-1,-1,1);
                        curtain_pitch_sum+=curtain_direction.y; ++curtain_count; ++r.support_driven_branchlet_count;
                    }
                }
                prior=primary;
            }
        }
        if (wi<r.whorl_count-1 && g.segments.size()<static_cast<std::size_t>(segment_limit)) {
            const double next=double(wi+1)/std::max(1,r.whorl_count-1);
            double iy=lerpf(y,lerpf(r.first_whorl_height,crown_top,std::pow(next,0.84)),0.48);
            iy+=signed_unit(key("conifer-interstitial-y:%lld:%d",seed,wi))*0.20;
            const int ia=nearest_trunk(g,iy);
            const double il=length*lerpf(0.48,0.34,cu);
            const double charge_i=il/lerpf(3.10,2.42,cu);
            const int count=clampi(static_cast<int>(std::floor(charge_i+unit(key("conifer-interstitial-phase:%lld:%d",seed,wi)))),1,2);
            for (int ii=0;ii<count;++ii) {
                if (g.segments.size()>=static_cast<std::size_t>(segment_limit)) break;
                double a=phase+wi*GOLDEN_ANGLE*0.38+PI*0.44+ii*PI;
                a+=signed_unit(key("conifer-interstitial-angle:%lld:%d:%d",seed,wi,ii))*0.18;
                interstitial(g,ia,vec(std::cos(a),0,std::sin(a)),il,cu*2-1);
                ++r.interstitial_spray_count;
            }
        }
    }
    r.mean_bough_bud_charge=bud_charge_sum/std::max(1,r.whorl_count);
    r.lower_whorl_mean_length=mean(lower); r.upper_whorl_mean_length=mean(upper);
    r.drooping_curtain_mean_pitch=curtain_pitch_sum/std::max(1,curtain_count);
    r.node_count=static_cast<int>(g.nodes.size());
    for (const auto &s:g.segments) ++r.segment_counts_by_order[clampi(s.order,0,4)];
    std::vector<double> support(g.nodes.size(),0.0);
    for (int i=static_cast<int>(g.nodes.size())-1;i>=0;--i) {
        const Node &n=g.nodes[i]; double area=0;
        for (int child:n.children) area+=support[child];
        if (n.children.empty()) area=n.order>=3?1.0:0.72;
        support[i]=std::max(0.0001,area);
    }
    const double radius_scale=r.trunk_radius/std::sqrt(std::max(0.0001,support[0]));
    double maximum_height=1.0; for (const auto &n:g.nodes) maximum_height=std::max(maximum_height,double(n.position.y));
    for (const auto &s:g.segments) {
        const V start=g.nodes[s.parent].position,end=g.nodes[s.child].position;
        const double carried=std::sqrt(std::max(0.0001,support[s.child]))*radius_scale;
        double rs=carried*taper(g.nodes[s.parent],r.height,r.crown_base);
        const double re=carried*taper(g.nodes[s.child],r.height,r.crown_base);
        if (s.parent==0) rs*=1.24;
        r.branches.push_back({start,end,std::max(0.055,rs),std::max(0.050,re),s.order,s.parent,s.child,g.nodes[s.child].stratum_bias,clamp(std::max(double(start.y),double(end.y))/maximum_height,0,1)});
    }
    for (std::size_t i=0;i<g.nodes.size();++i) {
        const auto &n=g.nodes[i]; if (n.children.size()<2) continue;
        ++r.pipe_junction_count;
        const double tf=taper(n,r.height,r.crown_base), pa=support[i]*radius_scale*radius_scale*tf*tf;
        double ca=0; for (int child:n.children) ca+=support[child]*radius_scale*radius_scale*tf*tf;
        r.pipe_max_relative_error=std::max(r.pipe_max_relative_error,std::abs(pa-ca)/std::max(0.0001,pa));
    }
    std::unordered_set<int> occupied;
    for (std::size_t si=0;si<g.segments.size();++si) {
        if (r.foliage.size()>=static_cast<std::size_t>(foliage_limit)) break;
        const auto &s=g.segments[si]; if (s.order<2) continue;
        const V start=g.nodes[s.parent].position,end=g.nodes[s.child].position;
        const V direction=norm(sub(end,start));
        // Fine conifer wood has radial reach; its direction cannot be parallel
        // to UP, so the GDScript fallback is unreachable for this grammar.
        const V side=norm(cross(direction,vec(0,1,0)));
        const V normal=norm(cross(direction,side));
        const int clusters=s.interstitial?1:2;
        for (int ci=0;ci<clusters;++ci) {
            if (r.foliage.size()>=static_cast<std::size_t>(foliage_limit)) break;
            const double u=(double(ci)+0.44)/clusters;
            const double ja=signed_unit(key("needle-a:%lld:%d:%d",seed,static_cast<int>(si),ci));
            const double jb=signed_unit(key("needle-b:%lld:%d:%d",seed,static_cast<int>(si),ci));
            V position=lerp(start,end,clamp(u+ja*0.09,0.12,1.0));
            position=add(position,add(mul(side,ja*0.34),mul(normal,jb*0.28)));
            const V local=sub(position,r.crown_center);
            const double envelope=len(vec(double(local.x)/std::max(0.1,double(r.crown_radii.x)),double(local.y)/std::max(0.1,double(r.crown_radii.y)),double(local.z)/std::max(0.1,double(r.crown_radii.z))));
            const double exposure=clamp((envelope-0.16)/0.84,0,1);
            const double scale=lerpf(1.22,2.05,exposure)*lerpf(1.10,0.82,clamp(double(local.y)/std::max(1.0,r.height),0,1));
            NativeConiferFoliage f;
            f.position=position;
            f.rotation=vec(signed_unit(key("needle-rx:%lld:%d:%d",seed,static_cast<int>(si),ci))*0.18,unit(key("needle-ry:%lld:%d:%d",seed,static_cast<int>(si),ci))*TAU,signed_unit(key("needle-rz:%lld:%d:%d",seed,static_cast<int>(si),ci))*0.16);
            f.scale=vec(scale*0.86,scale*0.72,scale*0.86);
            f.wind_weight=clamp(double(position.y)/std::max(1.0,r.height),0.18,1.0);
            f.variation=clamp(0.18+exposure*0.58+unit(key("needle-color:%lld:%d:%d",seed,static_cast<int>(si),ci))*0.18,0,1);
            f.cluster_variant=static_cast<int>(stable_hash(key("needle-variant:%lld:%d:%d",seed,static_cast<int>(si),ci))%4U);
            f.source_segment=static_cast<int>(si); f.source_order=s.order; f.exposure=exposure;
            r.foliage.push_back(f);
            double angle=std::atan2(double(local.z),double(local.x)); if (angle<0) angle+=TAU;
            const int ab=clampi(static_cast<int>(std::floor(angle/TAU*10)),0,9);
            const double hu=clamp((double(local.y)/std::max(0.1,double(r.crown_radii.y))+1.0)*0.5,0,0.999);
            const int hb=clampi(static_cast<int>(std::floor(hu*5)),0,4);
            occupied.insert(ab*5+hb);
        }
    }
    r.occupied_crown_bins=static_cast<int>(occupied.size());
    r.signature=signature(r);
    return r;
}
} // namespace voxel::world_backend
