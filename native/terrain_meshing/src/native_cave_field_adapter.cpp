#include "native_cave_field_adapter.h"

#include "biome_region_field.hpp"
#include "world_source.hpp"

#include <godot_cpp/variant/aabb.hpp>
#include <godot_cpp/variant/array.hpp>
#include <godot_cpp/variant/char_string.hpp>

#include <stdexcept>

using namespace godot;
using namespace voxel::world_backend;

namespace {
CaveVector3 to_cave(const Vector3 &p_value) { return {p_value.x, p_value.y, p_value.z}; }
Vector3 to_godot(const CaveVector3 &p_value) { return {p_value.x, p_value.y, p_value.z}; }
AABB to_godot(const CaveBounds &p_value) { return {to_godot(p_value.position), to_godot(p_value.size)}; }
}

void NativeCaveField::_bind_methods() {
	ClassDB::bind_method(D_METHOD("setup", "seed", "cell_size"), &NativeCaveField::setup);
	ClassDB::bind_method(D_METHOD("clear"), &NativeCaveField::clear);
	ClassDB::bind_method(D_METHOD("region_at", "position"), &NativeCaveField::region_at);
	ClassDB::bind_method(D_METHOD("recipe_for_region", "region", "surface", "protected_bounds"), &NativeCaveField::recipe_for_region);
	ClassDB::bind_method(D_METHOD("recipe_build_diagnostics", "region"), &NativeCaveField::recipe_build_diagnostics);
	ClassDB::bind_method(D_METHOD("cache_stats"), &NativeCaveField::cache_stats);
	ClassDB::bind_method(D_METHOD("density", "position", "depth", "surface", "protected_bounds"), &NativeCaveField::density);
	ClassDB::bind_method(D_METHOD("dry_carver_at", "position", "surface", "protected_bounds"), &NativeCaveField::dry_carver_at);
}

bool NativeCaveField::setup(const String &p_seed, const double p_cell_size) {
	if (!(p_cell_size > 0.0)) return false;
	const CharString encoded = p_seed.utf8();
	const std::string seed(encoded.get_data(), static_cast<std::size_t>(encoded.length()));
	WorldSourceDescriptor descriptor;
	descriptor.raw_terrain_seed = admit_raw_terrain_seed(seed);
	descriptor.admitted_biome_seed = BiomeRegionField::admit_utf8_seed(seed);
	descriptor.constants.cell_size_meters = p_cell_size;
	definition_ = std::make_unique<WorldSourceDefinition>(std::move(descriptor));
	field_ = std::make_unique<NativeProceduralCaveField>(*definition_);
	return true;
}

void NativeCaveField::clear() {
	field_.reset();
	definition_.reset();
}

Dictionary NativeCaveField::cache_stats() const {
	Dictionary result;
	if (!field_) return result;
	const auto stats = field_->cache_stats();
	result["recipe_build_count"] = static_cast<std::int64_t>(stats.recipe_build_count);
	result["recipe_build_total_usec"] = static_cast<std::int64_t>(stats.recipe_build_total_usec);
	result["recipe_build_max_usec"] = static_cast<std::int64_t>(stats.recipe_build_max_usec);
	result["cache_evictions"] = static_cast<std::int64_t>(stats.cache_evictions);
	return result;
}

NativeProceduralCaveField *NativeCaveField::field() const {
	if (!field_) throw std::logic_error("NativeCaveField.setup must succeed before use");
	return field_.get();
}

NativeProceduralCaveField::SurfaceSampler NativeCaveField::surface_sampler(const Callable &p_callable) const {
	if (!p_callable.is_valid()) throw std::invalid_argument("native cave surface sampler is required");
	return [p_callable](const float x, const float z) mutable {
		const Variant result = p_callable.call(x, z);
		if (result.get_type() != Variant::FLOAT && result.get_type() != Variant::INT)
			throw std::runtime_error("native cave surface sampler must return a number");
		return static_cast<double>(result);
	};
}

NativeProceduralCaveField::ProtectedBounds NativeCaveField::protection_sampler(const Callable &p_callable) const {
	if (!p_callable.is_valid()) throw std::invalid_argument("native cave protected-bounds sampler is required");
	return [p_callable](const CaveBounds &p_bounds) mutable {
		const Variant result = p_callable.call(to_godot(p_bounds));
		if (result.get_type() != Variant::BOOL)
			throw std::runtime_error("native cave protected-bounds sampler must return bool");
		return static_cast<bool>(result);
	};
}

Vector2i NativeCaveField::region_at(const Vector3 &p_position) const {
	const CaveRegionKey region = NativeProceduralCaveField::region_at(to_cave(p_position));
	return {region.x, region.z};
}

Dictionary NativeCaveField::recipe_dictionary(const CaveRecipe &p_recipe) const {
	Dictionary result;
	result["id"] = String(("cave:" + std::to_string(p_recipe.region.x) + "," + std::to_string(p_recipe.region.z)).c_str());
	result["region"] = Vector2i(p_recipe.region.x, p_recipe.region.z);
	result["entry"] = to_godot(p_recipe.entry);
	result["outward"] = to_godot(p_recipe.outward);
	Array route; for (const CaveVector3 &point : p_recipe.route) route.push_back(to_godot(point));
	Array loop; for (const CaveVector3 &point : p_recipe.loop) loop.push_back(to_godot(point));
	Array deep_route; for (const CaveVector3 &point : p_recipe.deep_route) deep_route.push_back(to_godot(point));
	Array depth_loops;
	for (const auto &depth_loop_points : p_recipe.depth_loops) {
		Array depth_loop;
		for (const CaveVector3 &point : depth_loop_points) depth_loop.push_back(to_godot(point));
		depth_loops.push_back(depth_loop);
	}
	Array depth_tier_links;
	for (const CaveDepthTierLink &link_value : p_recipe.depth_tier_links) {
		Dictionary link;
		Array points;
		for (const CaveVector3 &point : link_value.points) points.push_back(to_godot(point));
		link["id"] = String(link_value.id.c_str());
		link["fromTier"] = static_cast<int64_t>(link_value.from_tier);
		link["toTier"] = static_cast<int64_t>(link_value.to_tier);
		link["points"] = points;
		depth_tier_links.push_back(link);
	}
	Array segments;
	for (const CaveSegment &segment : p_recipe.segments) {
		Dictionary item;
		item["a"] = to_godot(segment.a); item["b"] = to_godot(segment.b);
		item["radius"] = segment.radius; item["radius_end"] = segment.radius_end;
		if (segment.vertical_radius != segment.radius || segment.vertical_radius_end != segment.radius_end) {
			item["vertical_radius"] = segment.vertical_radius;
			item["vertical_radius_end"] = segment.vertical_radius_end;
		}
		item["bounds"] = to_godot(segment.bounds); segments.push_back(item);
	}
	Array chambers;
	for (const CaveChamber &chamber : p_recipe.chambers) {
		Dictionary item; item["center"] = to_godot(chamber.center); item["radii"] = to_godot(chamber.radii); chambers.push_back(item);
	}
	result["route"] = route; result["loop"] = loop; result["deepRoute"] = deep_route;
	result["depthLoops"] = depth_loops;
	result["depthTierLinks"] = depth_tier_links;
	result["segments"] = segments; result["chambers"] = chambers; result["bounds"] = to_godot(p_recipe.bounds);
	return result;
}

Dictionary NativeCaveField::recipe_for_region(const Vector2i &p_region,
		const Callable &p_surface, const Callable &p_protected_bounds) {
	const auto recipe = field()->recipe_for_region({p_region.x, p_region.y},
		surface_sampler(p_surface), protection_sampler(p_protected_bounds));
	return recipe ? recipe_dictionary(*recipe) : Dictionary();
}

Dictionary NativeCaveField::recipe_build_diagnostics(const Vector2i &p_region) const {
	Dictionary result;
	const auto diagnostics = field()->build_diagnostics({p_region.x, p_region.y});
	if (!diagnostics) return result;
	result["centers_attempted"] = static_cast<std::int64_t>(diagnostics->centers_attempted);
	result["directions_evaluated"] = static_cast<std::int64_t>(diagnostics->directions_evaluated);
	result["build_time_usec"] = static_cast<std::int64_t>(diagnostics->build_time_usec);
	result["terminal_reason"] = String(diagnostics->terminal_reason.c_str());
	Array centers;
	for (const CaveCenterAttemptDiagnostics &attempt : diagnostics->centers) {
		Dictionary item;
		item["center"] = to_godot(attempt.center);
		item["directions_evaluated"] = static_cast<std::int64_t>(attempt.directions_evaluated);
		item["viable_entrances"] = static_cast<std::int64_t>(attempt.viable_entrances);
		item["full_recipe_attempts"] = static_cast<std::int64_t>(attempt.full_recipe_attempts);
		item["terminal_reason"] = String(attempt.terminal_reason.c_str());
		item["last_rejection_detail"] = String(attempt.last_rejection_detail.c_str());
		Dictionary rejections;
		for (const auto &[reason, count] : attempt.rejection_counts)
			rejections[String(reason.c_str())] = static_cast<std::int64_t>(count);
		item["rejection_counts"] = rejections;
		centers.push_back(item);
	}
	result["centers"] = centers;
	return result;
}

double NativeCaveField::density(const Vector3 &p_position, const double p_depth,
		const Callable &p_surface, const Callable &p_protected_bounds) {
	return field()->density(to_cave(p_position), p_depth,
		surface_sampler(p_surface), protection_sampler(p_protected_bounds));
}

bool NativeCaveField::dry_carver_at(const Vector3 &p_position,
		const Callable &p_surface, const Callable &p_protected_bounds) {
	const auto surface = surface_sampler(p_surface);
	const auto protected_bounds = protection_sampler(p_protected_bounds);
	const auto recipe = field()->recipe_for_region(NativeProceduralCaveField::region_at(to_cave(p_position)), surface, protected_bounds);
	return recipe && recipe->bounds.contains(to_cave(p_position))
		&& field()->recipe_density(to_cave(p_position), *recipe) < 0.5;
}
