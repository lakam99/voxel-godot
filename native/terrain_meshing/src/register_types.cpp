#include "register_types.h"

#include "terrain_meshing_backend.h"
#include "building_support_kernel.h"
#include "native_world_backend_adapter.h"
#include "native_cave_field_adapter.h"
#include "chunk_static_render_backend.h"
#include "chunk_render_packet_backend.h"
#include "native_section_compile_dispatcher.h"
#include "native_tree_geometry_dispatcher.h"

#include <godot_cpp/godot.hpp>

using namespace godot;

void initialize_terrain_meshing_module(ModuleInitializationLevel p_level) {
	if (p_level != MODULE_INITIALIZATION_LEVEL_SCENE) {
		return;
	}
	ClassDB::register_class<TerrainMeshingBackend>();
	ClassDB::register_class<NativeWorldBackend>();
	ClassDB::register_class<NativeCaveField>();
	ClassDB::register_class<NativeEffectiveTerrainPage>();
	ClassDB::register_class<NativeStructureExclusionChunk>();
	ClassDB::register_class<ChunkStaticRenderBackend>();
	ClassDB::register_class<ChunkRenderPacketBackend>();
	ClassDB::register_class<NativeSectionCompileDispatcher>();
	ClassDB::register_class<NativeTreeGeometryDispatcher>();
	register_building_support_kernel();
}

void uninitialize_terrain_meshing_module(ModuleInitializationLevel p_level) {
	if (p_level != MODULE_INITIALIZATION_LEVEL_SCENE) {
		return;
	}
}

extern "C" {
GDExtensionBool GDE_EXPORT terrain_meshing_library_init(
	GDExtensionInterfaceGetProcAddress p_get_proc_address,
	GDExtensionClassLibraryPtr p_library,
	GDExtensionInitialization *r_initialization
) {
	GDExtensionBinding::InitObject init_obj(p_get_proc_address, p_library, r_initialization);
	init_obj.register_initializer(initialize_terrain_meshing_module);
	init_obj.register_terminator(uninitialize_terrain_meshing_module);
	init_obj.set_minimum_library_initialization_level(MODULE_INITIALIZATION_LEVEL_SCENE);
	return init_obj.init();
}
}
