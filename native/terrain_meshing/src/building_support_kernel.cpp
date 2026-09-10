#include <godot_cpp/godot.hpp>
#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/array.hpp>
#include <godot_cpp/variant/packed_int32_array.hpp>
#include <godot_cpp/variant/transform3d.hpp>
#include <vector>
#include <limits>
#include <cmath>
using namespace godot;

class BuildingSupportKernel : public RefCounted {
 GDCLASS(BuildingSupportKernel, RefCounted);
 struct Part {
  String id, excluded;
  Vector3 position, size;
  Transform3D transform, inverse;
  bool cardinal=false, candidate=false, root=false, enclosing=false;
  std::vector<String> required;
 };
 std::vector<Part> parts;
 bool configured=false;
 static Dictionary failure(const char *reason){Dictionary result;result["nativeSupportError"]=reason;return result;}
protected:
 static void _bind_methods() {
  ClassDB::bind_method(D_METHOD("configure", "records"), &BuildingSupportKernel::configure);
  ClassDB::bind_method(D_METHOD("protocol_version"), &BuildingSupportKernel::protocol_version);
  ClassDB::bind_method(D_METHOD("query", "indices", "target", "point", "margin", "maximum_gap"), &BuildingSupportKernel::query);
 }
public:
 int64_t protocol_version() const {return sizeof(real_t)==4?1:0;}
 bool configure(const Array &records) {
  configured=false;
  parts.clear(); parts.reserve(records.size());
  if(records.size()>10000)return false;
  for (int64_t i=0;i<records.size();++i) {
   if(records[i].get_type()!=Variant::DICTIONARY)return false;
   Dictionary r=records[i]; Part p;
   const char *keys[]={"id","excluded","position","size","transform","inverse","cardinal","candidate","root","enclosing","required"};
   const Variant::Type types[]={Variant::STRING,Variant::STRING,Variant::VECTOR3,Variant::VECTOR3,Variant::TRANSFORM3D,Variant::TRANSFORM3D,Variant::BOOL,Variant::BOOL,Variant::BOOL,Variant::BOOL,Variant::ARRAY};
   for(int k=0;k<11;++k)if(!r.has(keys[k])||r[keys[k]].get_type()!=types[k])return false;
   p.id=r["id"];p.excluded=r["excluded"];p.position=r["position"];p.size=r["size"];
   p.transform=r["transform"];p.inverse=r["inverse"];
   p.cardinal=r["cardinal"];p.candidate=r["candidate"];p.root=r["root"];p.enclosing=r["enclosing"];
   if(!p.position.is_finite()||!p.size.is_finite()||p.size.x<=0||p.size.y<=0||p.size.z<=0||!p.transform.is_finite()||!p.inverse.is_finite())return false;
   Array required=r["required"];for(int64_t j=0;j<required.size();++j){if(required[j].get_type()!=Variant::STRING)return false;p.required.push_back(required[j]);}
   parts.push_back(p);
  }
  configured=true;return true;
 }
 Dictionary query(const PackedInt32Array &indices, int64_t target_index, const Vector3 &point, double margin, double maximum_gap) const {
  Dictionary best;
  if(!configured)return failure("unconfigured_kernel");
  if(target_index<0||target_index>=static_cast<int64_t>(parts.size()))return failure("invalid_target_index");
  if(!point.is_finite()||!std::isfinite(margin)||margin<0||!std::isfinite(maximum_gap)||maximum_gap<0)return failure("invalid_query_parameters");
  for(int64_t i=0;i<indices.size();++i)if(indices[i]<0||indices[i]>=static_cast<int64_t>(parts.size()))return failure("invalid_candidate_index");
  const Part &target=parts[target_index];
  double best_gap=std::numeric_limits<double>::infinity();
  const double target_bottom=double(target.position.y)-double(target.size.y)*0.5;
  const double target_top=double(target.position.y)+double(target.size.y)*0.5;
  for(int pass=0;pass<(target.required.empty()?1:2);++pass) {
   bool preferred=!target.required.empty()&&pass==0;
   for(int64_t i=0;i<indices.size();++i) {
    int64_t index=indices[i];
    if(index==target_index)continue;
    const Part &candidate=parts[index];
    bool required=false;for(const String &id:target.required)if(id==candidate.id){required=true;break;}
    if(required!=preferred||candidate.id==target.excluded||!candidate.candidate)continue;
    Vector3 local_point=candidate.cardinal?point-candidate.position:candidate.inverse.xform(point);
    if(std::abs(double(local_point.x))>double(candidate.size.x)*0.5+margin||std::abs(double(local_point.z))>double(candidate.size.z)*0.5+margin)continue;
    double bottom=double(candidate.position.y)-double(candidate.size.y)*0.5;
    double top=double(candidate.position.y)+double(candidate.size.y)*0.5;
    bool encloses=target.enclosing&&bottom<=target_bottom+0.04&&top>=target_top-0.04&&double(candidate.size.y)>=double(target.size.y)+0.30;
    bool lower=double(candidate.position.y)<double(target.position.y)-0.05||encloses||candidate.root;
    if(lower&&double(local_point.y)>=-double(candidate.size.y)*0.5-0.08&&double(local_point.y)<=double(candidate.size.y)*0.5+0.10) {
     Dictionary result;result["id"]=candidate.id;result["surface"]=point;result["gap"]=0.0;result["contact"]="embedded";return result;
    }
    Vector3 local_surface(local_point.x,candidate.size.y*0.5,local_point.z);
    Vector3 surface=candidate.cardinal?local_surface+candidate.position:candidate.transform.xform(local_surface);
    double gap=double(point.y)-double(surface.y);
    if(gap< -0.14||gap>maximum_gap||gap>=best_gap)continue;
    best_gap=gap;best.clear();best["id"]=candidate.id;best["surface"]=surface;best["gap"]=gap;
   }
  }
  return best;
 }
};
void register_building_support_kernel(){ClassDB::register_class<BuildingSupportKernel>();}
