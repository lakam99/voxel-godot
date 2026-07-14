#ifndef TERRAIN_MESHING_BACKEND_H
#define TERRAIN_MESHING_BACKEND_H

#include <godot_cpp/classes/array_mesh.hpp>
#include <godot_cpp/classes/concave_polygon_shape3d.hpp>
#include <godot_cpp/classes/material.hpp>
#include <godot_cpp/classes/mesh.hpp>
#include <godot_cpp/classes/object.hpp>
#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/classes/shape3d.hpp>
#include <godot_cpp/core/binder_common.hpp>
#include <godot_cpp/variant/color.hpp>
#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/packed_color_array.hpp>
#include <godot_cpp/variant/packed_vector3_array.hpp>
#include <godot_cpp/variant/string_name.hpp>
#include <godot_cpp/variant/vector3i.hpp>

using namespace godot;

class TerrainMeshingBackend : public RefCounted {
	GDCLASS(TerrainMeshingBackend, RefCounted);

protected:
	static void _bind_methods();

public:
	Dictionary backend_summary() const;
	Variant build_chunk_mesh(Object *p_main, int32_t p_cx, int32_t p_cz);
	Dictionary build_chunk_surface_data_from_sections(const Dictionary &p_payload);
	Variant build_chunk_mesh_from_sections(const Dictionary &p_payload);
	Dictionary build_chunk_fluid_surface_data_from_sections(const Dictionary &p_payload);
	Variant build_chunk_fluid_mesh_from_sections(const Dictionary &p_payload);
	Variant build_chunk_fluid_mesh(Object *p_main, int32_t p_cx, int32_t p_cz);
	Variant collision_shape_for_mesh(const Ref<Mesh> &p_mesh);
	Dictionary build_chunk_assets(Object *p_main, int32_t p_cx, int32_t p_cz, bool p_include_collision);
};

#endif
