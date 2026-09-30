#pragma once

#include "native_procedural_cave_field.hpp"

#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/variant/callable.hpp>
#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/vector2i.hpp>
#include <godot_cpp/variant/vector3.hpp>

#include <memory>
#include <string>

class NativeCaveField : public godot::RefCounted {
	GDCLASS(NativeCaveField, godot::RefCounted);

protected:
	static void _bind_methods();

public:
	bool setup(const godot::String &p_seed, double p_cell_size);
	void clear();
	godot::Vector2i region_at(const godot::Vector3 &p_position) const;
	godot::Dictionary recipe_for_region(const godot::Vector2i &p_region,
		const godot::Callable &p_surface, const godot::Callable &p_protected_bounds);
	godot::Dictionary cache_stats() const;
	double density(const godot::Vector3 &p_position, double p_depth,
		const godot::Callable &p_surface, const godot::Callable &p_protected_bounds);
	bool dry_carver_at(const godot::Vector3 &p_position,
		const godot::Callable &p_surface, const godot::Callable &p_protected_bounds);

private:
	voxel::world_backend::NativeProceduralCaveField *field() const;
	voxel::world_backend::NativeProceduralCaveField::SurfaceSampler surface_sampler(const godot::Callable &p_callable) const;
	voxel::world_backend::NativeProceduralCaveField::ProtectedBounds protection_sampler(const godot::Callable &p_callable) const;
	godot::Dictionary recipe_dictionary(const voxel::world_backend::CaveRecipe &p_recipe) const;

	std::unique_ptr<voxel::world_backend::WorldSourceDefinition> definition_;
	std::unique_ptr<voxel::world_backend::NativeProceduralCaveField> field_;
};
