#include "terrain_meshing_backend.h"

#include <godot_cpp/classes/array_mesh.hpp>
#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/variant/array.hpp>
#include <godot_cpp/variant/packed_byte_array.hpp>
#include <godot_cpp/variant/packed_float32_array.hpp>
#include <godot_cpp/variant/packed_string_array.hpp>
#include <godot_cpp/variant/string.hpp>
#include <godot_cpp/variant/variant.hpp>

#include <array>
#include <utility>

using namespace godot;

namespace {
const int CUBE_CORNER_COUNT = 8;
const int TETRAHEDRON_COUNT = 6;

const std::array<Vector3i, CUBE_CORNER_COUNT> CUBE_CORNERS = {
	Vector3i(0, 0, 0),
	Vector3i(1, 0, 0),
	Vector3i(1, 0, 1),
	Vector3i(0, 0, 1),
	Vector3i(0, 1, 0),
	Vector3i(1, 1, 0),
	Vector3i(1, 1, 1),
	Vector3i(0, 1, 1),
};

const std::array<std::array<int, 4>, TETRAHEDRON_COUNT> TETRAHEDRA = {
	std::array<int, 4>{0, 5, 1, 6},
	std::array<int, 4>{0, 1, 2, 6},
	std::array<int, 4>{0, 2, 3, 6},
	std::array<int, 4>{0, 3, 7, 6},
	std::array<int, 4>{0, 7, 4, 6},
	std::array<int, 4>{0, 4, 5, 6},
};

const std::array<Vector3i, 6> CARDINAL_DIRECTIONS = {
	Vector3i(1, 0, 0),
	Vector3i(-1, 0, 0),
	Vector3i(0, 1, 0),
	Vector3i(0, -1, 0),
	Vector3i(0, 0, 1),
	Vector3i(0, 0, -1),
};

struct PayloadSample {
	double density = -1.0;
	double surface_y = 0.0;
	String material = "air";
	String biome = "";
	String fluid = "";
	int sky_light = 15;
	int block_light = 0;
	bool solid = false;
};

struct ExactFluidSample {
	bool known = false;
	bool solid = false;
	int fluid_type = 0;
};

int get_main_int(Object *p_main, const StringName &p_name, int p_fallback) {
	if (p_main == nullptr) {
		return p_fallback;
	}
	Variant value = p_main->get(p_name);
	if (value.get_type() == Variant::NIL) {
		return p_fallback;
	}
	return int(value);
}

double get_main_float(Object *p_main, const StringName &p_name, double p_fallback) {
	if (p_main == nullptr) {
		return p_fallback;
	}
	Variant value = p_main->get(p_name);
	if (value.get_type() == Variant::NIL) {
		return p_fallback;
	}
	return double(value);
}

bool call_main_bool(Object *p_main, const StringName &p_method, int p_start_x, int p_start_z, bool p_fallback = false) {
	if (p_main == nullptr || !p_main->has_method(p_method)) {
		return p_fallback;
	}
	return bool(p_main->call(p_method, p_start_x, p_start_z));
}

int call_main_int(Object *p_main, const StringName &p_method, int p_start_x, int p_start_z, int p_fallback) {
	if (p_main == nullptr || !p_main->has_method(p_method)) {
		return p_fallback;
	}
	Variant value = p_main->call(p_method, p_start_x, p_start_z);
	if (value.get_type() == Variant::NIL) {
		return p_fallback;
	}
	return int(value);
}

Dictionary call_main_dictionary(Object *p_main, const StringName &p_method, int p_start_x, int p_start_z) {
	if (p_main == nullptr || !p_main->has_method(p_method)) {
		return Dictionary();
	}
	Variant value = p_main->call(p_method, p_start_x, p_start_z);
	if (value.get_type() != Variant::DICTIONARY) {
		return Dictionary();
	}
	return Dictionary(value);
}

Vector3 sample_numeric(Object *p_main, const Vector3i &p_cell, Dictionary &p_cache) {
	if (p_cache.has(p_cell)) {
		return Vector3(p_cache[p_cell]);
	}
	Vector3 result;
	if (p_main != nullptr && p_main->has_method("native_terrain_numeric_sample_at_grid_cell")) {
		Variant value = p_main->call("native_terrain_numeric_sample_at_grid_cell", p_cell);
		if (value.get_type() == Variant::VECTOR3) {
			result = Vector3(value);
		}
	}
	p_cache[p_cell] = result;
	return result;
}

int floor_divide(int p_value, int p_divisor) {
	if (p_divisor <= 0) {
		return 0;
	}
	if (p_value >= 0) {
		return p_value / p_divisor;
	}
	return -((-p_value + p_divisor - 1) / p_divisor);
}

int positive_modulo(int p_value, int p_divisor) {
	if (p_divisor <= 0) {
		return 0;
	}
	int result = p_value % p_divisor;
	return result < 0 ? result + p_divisor : result;
}

String section_key_text(const Vector3i &p_key) {
	return String::num_int64(p_key.x) + "," + String::num_int64(p_key.y) + "," + String::num_int64(p_key.z);
}

int section_cell_index(const Vector3i &p_local, int p_section_size) {
	return int(p_local.x) + p_section_size * (int(p_local.y) + p_section_size * int(p_local.z));
}

Dictionary section_lookup_from_payload(const Dictionary &p_payload) {
	Dictionary lookup;
	Variant sections_value = p_payload.get("sections", Array());
	if (sections_value.get_type() != Variant::ARRAY) {
		return lookup;
	}
	Array sections = sections_value;
	for (int i = 0; i < sections.size(); ++i) {
		Variant section_value = sections[i];
		if (section_value.get_type() != Variant::DICTIONARY) {
			continue;
		}
		Dictionary section = section_value;
		Variant key_value = section.get("sectionKey", Vector3i());
		if (key_value.get_type() != Variant::VECTOR3I) {
			continue;
		}
		Vector3i key = key_value;
		lookup[section_key_text(key)] = section;
	}
	return lookup;
}

PayloadSample sample_section_payload(const Dictionary &p_payload, const Dictionary &p_section_lookup, const Vector3i &p_cell) {
	int section_size = int(p_payload.get("sectionSize", 16));
	double cell_size = double(p_payload.get("cellSize", 1.35));
	PayloadSample fallback;
	fallback.density = -cell_size;
	fallback.surface_y = double(p_cell.y) * cell_size;
	fallback.material = "air";
	fallback.fluid = "";
	fallback.solid = false;
	Vector3i section_key(
		floor_divide(p_cell.x, section_size),
		floor_divide(p_cell.y, section_size),
		floor_divide(p_cell.z, section_size)
	);
	String key_text = section_key_text(section_key);
	if (!p_section_lookup.has(key_text)) {
		return fallback;
	}
	Variant section_value = p_section_lookup[key_text];
	if (section_value.get_type() != Variant::DICTIONARY) {
		return fallback;
	}
	Dictionary section = section_value;
	Variant channels_value = section.get("channels", Dictionary());
	if (channels_value.get_type() != Variant::DICTIONARY) {
		return fallback;
	}
	Dictionary channels = channels_value;
	Vector3i local(
		positive_modulo(p_cell.x, section_size),
		positive_modulo(p_cell.y, section_size),
		positive_modulo(p_cell.z, section_size)
	);
	int index = section_cell_index(local, section_size);
	bool sparse_section = bool(section.get("sparse", false)) || bool(p_payload.get("sparse", false));
	if (sparse_section) {
		Variant sparse_lookup_value = channels.get("sparseIndexByCellIndex", Dictionary());
		if (sparse_lookup_value.get_type() != Variant::DICTIONARY) {
			return fallback;
		}
		Dictionary sparse_lookup = sparse_lookup_value;
		if (!sparse_lookup.has(index)) {
			return fallback;
		}
		index = int(sparse_lookup[index]);
	}
	PackedFloat32Array density_values = channels.get("density", PackedFloat32Array());
	PackedByteArray solid_values = channels.get("solid", PackedByteArray());
	PackedStringArray material_values = channels.get("materialIds", PackedStringArray());
	PackedStringArray biome_values = channels.get("biomeIds", PackedStringArray());
	PackedStringArray fluid_values = channels.get("fluidIds", PackedStringArray());
	PackedByteArray sky_light_values = channels.get("skyLight", PackedByteArray());
	PackedByteArray block_light_values = channels.get("blockLight", PackedByteArray());
	PackedFloat32Array surface_y_values = channels.get("surfaceY", PackedFloat32Array());
	if (index < 0) {
		return fallback;
	}
	PayloadSample result;
	result.solid = index < solid_values.size() && int(solid_values[index]) > 0;
	result.density = result.solid ? cell_size : -cell_size;
	if (index < density_values.size()) {
		result.density = double(density_values[index]);
	}
	result.surface_y = index < surface_y_values.size() ? double(surface_y_values[index]) : double(p_cell.y) * cell_size;
	result.material = index < material_values.size() ? String(material_values[index]) : (result.solid ? String("stone") : String("air"));
	result.biome = index < biome_values.size() ? String(biome_values[index]) : String("");
	result.fluid = index < fluid_values.size() ? String(fluid_values[index]) : String("");
	result.sky_light = index < sky_light_values.size() ? CLAMP(int(sky_light_values[index]), 0, 15) : (result.solid ? 0 : 15);
	result.block_light = index < block_light_values.size() ? CLAMP(int(block_light_values[index]), 0, 15) : 0;
	if (result.material.is_empty()) {
		result.material = result.solid ? String("stone") : String("air");
	}
	return result;
}

ExactFluidSample sample_exact_fluid_payload(const Dictionary &p_payload, const Dictionary &p_section_lookup, const Vector3i &p_cell) {
	ExactFluidSample result;
	Variant min_value = p_payload.get("minCell", Variant());
	Variant max_value = p_payload.get("maxCell", Variant());
	if (min_value.get_type() != Variant::VECTOR3I || max_value.get_type() != Variant::VECTOR3I) {
		return result;
	}
	Vector3i min_cell = min_value;
	Vector3i max_cell = max_value;
	if (p_cell.x < min_cell.x || p_cell.x > max_cell.x || p_cell.y < min_cell.y || p_cell.y > max_cell.y || p_cell.z < min_cell.z || p_cell.z > max_cell.z) {
		return result;
	}
	Variant cells_value = p_payload.get("cells", Dictionary());
	if (cells_value.get_type() == Variant::DICTIONARY) {
		Dictionary cells = cells_value;
		Variant size_value = cells.get("size", Variant());
		PackedByteArray solid_values = cells.get("solid", PackedByteArray());
		PackedByteArray fluid_values = cells.get("fluidTypeIds", PackedByteArray());
		if (size_value.get_type() == Variant::VECTOR3I) {
			Vector3i size = size_value;
			int expected_size = size.x * size.y * size.z;
			if (size.x > 0 && size.y > 0 && size.z > 0 && solid_values.size() == expected_size && fluid_values.size() == expected_size) {
				Vector3i local = p_cell - min_cell;
				int index = local.y + size.y * (local.x + size.x * local.z);
				result.known = index >= 0 && index < expected_size;
				result.solid = result.known && int(solid_values[index]) > 0;
				result.fluid_type = result.known ? CLAMP(int(fluid_values[index]), 0, 2) : 0;
				return result;
			}
		}
	}
	int section_size = int(p_payload.get("sectionSize", 16));
	Vector3i section_key(
		floor_divide(p_cell.x, section_size),
		floor_divide(p_cell.y, section_size),
		floor_divide(p_cell.z, section_size)
	);
	String key_text = section_key_text(section_key);
	if (!p_section_lookup.has(key_text)) {
		return result;
	}
	Variant section_value = p_section_lookup[key_text];
	if (section_value.get_type() != Variant::DICTIONARY) {
		return result;
	}
	Dictionary section = section_value;
	Variant channels_value = section.get("channels", Dictionary());
	if (channels_value.get_type() != Variant::DICTIONARY) {
		return result;
	}
	Dictionary channels = channels_value;
	PackedByteArray solid_values = channels.get("solid", PackedByteArray());
	PackedByteArray fluid_values = channels.get("fluidTypeIds", PackedByteArray());
	int expected_size = section_size * section_size * section_size;
	if (solid_values.size() != expected_size || fluid_values.size() != expected_size) {
		return result;
	}
	Vector3i local(
		positive_modulo(p_cell.x, section_size),
		positive_modulo(p_cell.y, section_size),
		positive_modulo(p_cell.z, section_size)
	);
	int index = section_cell_index(local, section_size);
	result.known = index >= 0 && index < expected_size;
	result.solid = result.known && int(solid_values[index]) > 0;
	result.fluid_type = result.known ? CLAMP(int(fluid_values[index]), 0, 2) : 0;
	return result;
}

ExactFluidSample sample_legacy_exact_fluid_payload(const Dictionary &p_payload, const Dictionary &p_section_lookup, const Vector3i &p_cell) {
	ExactFluidSample result;
	int section_size = int(p_payload.get("sectionSize", 16));
	Vector3i section_key(
		floor_divide(p_cell.x, section_size),
		floor_divide(p_cell.y, section_size),
		floor_divide(p_cell.z, section_size)
	);
	String key_text = section_key_text(section_key);
	if (!p_section_lookup.has(key_text)) {
		return result;
	}
	Variant section_value = p_section_lookup[key_text];
	if (section_value.get_type() != Variant::DICTIONARY) {
		return result;
	}
	Dictionary section = section_value;
	Variant channels_value = section.get("channels", Dictionary());
	if (channels_value.get_type() != Variant::DICTIONARY) {
		return result;
	}
	Dictionary channels = channels_value;
	Vector3i local(
		positive_modulo(p_cell.x, section_size),
		positive_modulo(p_cell.y, section_size),
		positive_modulo(p_cell.z, section_size)
	);
	int index = section_cell_index(local, section_size);
	bool sparse_section = bool(section.get("sparse", false)) || bool(p_payload.get("sparse", false));
	if (sparse_section) {
		Variant sparse_lookup_value = channels.get("sparseIndexByCellIndex", Dictionary());
		if (sparse_lookup_value.get_type() != Variant::DICTIONARY) {
			return result;
		}
		Dictionary sparse_lookup = sparse_lookup_value;
		if (!sparse_lookup.has(index)) {
			return result;
		}
	}
	PayloadSample sample = sample_section_payload(p_payload, p_section_lookup, p_cell);
	result.known = true;
	result.solid = sample.solid;
	result.fluid_type = sample.fluid == "lava" ? 2 : (sample.fluid == "water" ? 1 : 0);
	return result;
}

String fluid_id_from_type(int p_fluid_type) {
	return p_fluid_type == 2 ? String("lava") : String("water");
}

Ref<ArrayMesh> deferred_exact_fluid_mesh(const String &p_reason, bool p_forbidden_coarse_payload, int p_unknown_neighbor_count = 0) {
	Ref<ArrayMesh> mesh;
	mesh.instantiate();
	mesh->set_meta("terrainMeshingBackend", "native_volume_mesher");
	mesh->set_meta("terrainMeshingNative", true);
	mesh->set_meta("terrainMeshingQueued", false);
	mesh->set_meta("terrainFluidSectionPayload", false);
	mesh->set_meta("terrainFluidNativeDeferred", true);
	mesh->set_meta("terrainFluidDeferredReason", p_reason);
	mesh->set_meta("forbiddenCoarseFluidPayload", p_forbidden_coarse_payload);
	mesh->set_meta("unknownFluidNeighborCount", p_unknown_neighbor_count);
	mesh->set_meta("chunk_fluid_faces", 0);
	mesh->set_meta("chunk_water_faces", 0);
	mesh->set_meta("chunk_lava_faces", 0);
	mesh->set_meta("nativeFluidStepCells", 0);
	mesh->set_meta("nativeFluidCellCount", 0);
	return mesh;
}

Vector3 sample_section_payload_numeric(const Dictionary &p_payload, const Dictionary &p_section_lookup, const Vector3i &p_cell) {
	PayloadSample sample = sample_section_payload(p_payload, p_section_lookup, p_cell);
	return Vector3(sample.density, 0.0, sample.surface_y);
}

double sample_section_payload_density(const Dictionary &p_payload, const Dictionary &p_section_lookup, const Vector3i &p_cell) {
	PayloadSample sample = sample_section_payload(p_payload, p_section_lookup, p_cell);
	return sample.density;
}

double sample_section_payload_surface_y(const Dictionary &p_payload, const Dictionary &p_section_lookup, const Vector3i &p_cell) {
	PayloadSample sample = sample_section_payload(p_payload, p_section_lookup, p_cell);
	return sample.surface_y;
}

Vector3 density_gradient_from_section_payload(const Dictionary &p_payload, const Dictionary &p_section_lookup, const Vector3i &p_cell, int p_step) {
	int step = MAX(1, p_step);
	double dx = sample_section_payload_density(p_payload, p_section_lookup, p_cell + Vector3i(step, 0, 0)) - sample_section_payload_density(p_payload, p_section_lookup, p_cell - Vector3i(step, 0, 0));
	double dy = sample_section_payload_density(p_payload, p_section_lookup, p_cell + Vector3i(0, step, 0)) - sample_section_payload_density(p_payload, p_section_lookup, p_cell - Vector3i(0, step, 0));
	double dz = sample_section_payload_density(p_payload, p_section_lookup, p_cell + Vector3i(0, 0, step)) - sample_section_payload_density(p_payload, p_section_lookup, p_cell - Vector3i(0, 0, step));
	return Vector3(dx, dy, dz);
}

Vector3 surface_density_gradient_from_section_payload(const Dictionary &p_payload, const Dictionary &p_section_lookup, const Vector3i &p_cell, int p_step) {
	int step = MAX(1, p_step);
	double cell_size = double(p_payload.get("cellSize", 1.35));
	double dx = sample_section_payload_surface_y(p_payload, p_section_lookup, p_cell + Vector3i(step, 0, 0)) - sample_section_payload_surface_y(p_payload, p_section_lookup, p_cell - Vector3i(step, 0, 0));
	double dy = -2.0 * double(step) * cell_size;
	double dz = sample_section_payload_surface_y(p_payload, p_section_lookup, p_cell + Vector3i(0, 0, step)) - sample_section_payload_surface_y(p_payload, p_section_lookup, p_cell - Vector3i(0, 0, step));
	return Vector3(dx, dy, dz);
}

Vector3 density_gradient_from_main(Object *p_main, const Vector3i &p_cell, Dictionary &p_cache, int p_step) {
	int step = MAX(1, p_step);
	double dx = double(sample_numeric(p_main, p_cell + Vector3i(step, 0, 0), p_cache).x) - double(sample_numeric(p_main, p_cell - Vector3i(step, 0, 0), p_cache).x);
	double dy = double(sample_numeric(p_main, p_cell + Vector3i(0, step, 0), p_cache).x) - double(sample_numeric(p_main, p_cell - Vector3i(0, step, 0), p_cache).x);
	double dz = double(sample_numeric(p_main, p_cell + Vector3i(0, 0, step), p_cache).x) - double(sample_numeric(p_main, p_cell - Vector3i(0, 0, step), p_cache).x);
	return Vector3(dx, dy, dz);
}

Vector3 surface_density_gradient_from_main(Object *p_main, const Vector3i &p_cell, Dictionary &p_cache, int p_step, double p_cell_size) {
	int step = MAX(1, p_step);
	double dx = double(sample_numeric(p_main, p_cell + Vector3i(step, 0, 0), p_cache).z) - double(sample_numeric(p_main, p_cell - Vector3i(step, 0, 0), p_cache).z);
	double dy = -2.0 * double(step) * p_cell_size;
	double dz = double(sample_numeric(p_main, p_cell + Vector3i(0, 0, step), p_cache).z) - double(sample_numeric(p_main, p_cell - Vector3i(0, 0, step), p_cache).z);
	return Vector3(dx, dy, dz);
}

Vector3 local_position_for_cell(const Vector3i &p_cell, int p_start_x, int p_start_z, double p_cell_size) {
	return Vector3(
		(double(p_cell.x) - double(p_start_x)) * p_cell_size,
		double(p_cell.y) * p_cell_size,
		(double(p_cell.z) - double(p_start_z)) * p_cell_size
	);
}

double zero_crossing_t(double p_density_a, double p_density_b) {
	double denominator = p_density_a - p_density_b;
	double t = 0.5;
	if (Math::abs(denominator) > 0.00001) {
		t = p_density_a / denominator;
	}
	return CLAMP(t, 0.0, 1.0);
}

Vector3 interpolate_zero_crossing(const Vector3 &p_a, const Vector3 &p_b, double p_density_a, double p_density_b) {
	double t = zero_crossing_t(p_density_a, p_density_b);
	return p_a.lerp(p_b, t);
}

int cube_corner_index_for_offset(const Vector3i &p_offset) {
	for (int i = 0; i < CUBE_CORNER_COUNT; ++i) {
		if (CUBE_CORNERS[i] == p_offset) {
			return i;
		}
	}
	return 0;
}

Vector3 density_gradient_from_cube_corners(const std::array<double, CUBE_CORNER_COUNT> &p_densities, int p_corner_index) {
	Vector3i offset = CUBE_CORNERS[p_corner_index];
	int x0 = cube_corner_index_for_offset(Vector3i(0, offset.y, offset.z));
	int x1 = cube_corner_index_for_offset(Vector3i(1, offset.y, offset.z));
	int y0 = cube_corner_index_for_offset(Vector3i(offset.x, 0, offset.z));
	int y1 = cube_corner_index_for_offset(Vector3i(offset.x, 1, offset.z));
	int z0 = cube_corner_index_for_offset(Vector3i(offset.x, offset.y, 0));
	int z1 = cube_corner_index_for_offset(Vector3i(offset.x, offset.y, 1));
	return Vector3(
		p_densities[x1] - p_densities[x0],
		p_densities[y1] - p_densities[y0],
		p_densities[z1] - p_densities[z0]
	);
}

Vector3 surface_normal_from_density_gradient(const Vector3 &p_gradient, const Vector3 &p_desired_direction, const Vector3 &p_fallback) {
	Vector3 normal = -p_gradient;
	if (normal.length_squared() <= 0.000001) {
		normal = p_fallback;
	}
	if (normal.length_squared() <= 0.000001) {
		normal = Vector3(0.0, 1.0, 0.0);
	}
	normal.normalize();
	if (p_desired_direction.length_squared() > 0.000001 && normal.dot(p_desired_direction) < 0.0) {
		normal = -normal;
	}
	return normal;
}

Vector3 interpolate_zero_crossing_normal(
	const Vector3 &p_gradient_a,
	const Vector3 &p_gradient_b,
	double p_density_a,
	double p_density_b,
	const Vector3 &p_desired_direction
) {
	double t = zero_crossing_t(p_density_a, p_density_b);
	Vector3 gradient = p_gradient_a.lerp(p_gradient_b, t);
	return surface_normal_from_density_gradient(gradient, p_desired_direction, p_desired_direction);
}

Color color_for_surface(double p_world_y, double p_surface_y, double p_cell_size) {
	double depth_cells = (p_surface_y - p_world_y) / MAX(0.001, p_cell_size);
	if (depth_cells > 20.0) {
		return Color(0.24, 0.25, 0.23, 1.0);
	}
	if (depth_cells > 6.0) {
		return Color(0.42, 0.29, 0.18, 1.0);
	}
	return Color(0.43, 0.62, 0.32, 1.0);
}

Color material_color(const String &p_material, double p_world_y, double p_surface_y, double p_cell_size) {
	if (p_material == "copperOre") {
		return Color(0.68, 0.43, 0.28, 1.0);
	}
	if (p_material == "ironOre") {
		return Color(0.48, 0.42, 0.34, 1.0);
	}
	if (p_material == "bedrock") {
		return Color(0.19, 0.21, 0.21, 1.0);
	}
	if (p_material == "deepStone") {
		return Color(0.24, 0.25, 0.23, 1.0);
	}
	if (p_material == "stone") {
		return Color(0.34, 0.35, 0.31, 1.0);
	}
	if (p_material == "sand") {
		return Color(0.76, 0.67, 0.42, 1.0);
	}
	if (p_material == "snow") {
		return Color(0.82, 0.84, 0.77, 1.0);
	}
	if (p_material == "mud") {
		return Color(0.28, 0.39, 0.22, 1.0);
	}
	if (p_material == "dirt") {
		return Color(0.43, 0.27, 0.15, 1.0);
	}
	if (p_material == "grass") {
		return Color(0.43, 0.62, 0.32, 1.0);
	}
	return color_for_surface(p_world_y, p_surface_y, p_cell_size);
}

Color underground_material_color(const String &p_material, const Vector3 &p_air_direction) {
	double facing_shade = 0.68;
	if (p_air_direction.y < -0.35) {
		facing_shade = 0.52;
	} else if (p_air_direction.y > 0.35) {
		facing_shade = 0.86;
	}
	Color color(0.125, 0.135, 0.125, 1.0);
	if (p_material == "copperOre") {
		color = Color(0.42, 0.24, 0.15, 1.0);
	} else if (p_material == "ironOre") {
		color = Color(0.34, 0.33, 0.29, 1.0);
	} else if (p_material == "bedrock") {
		color = Color(0.075, 0.080, 0.080, 1.0);
	} else if (p_material == "deepStone") {
		color = Color(0.160, 0.170, 0.165, 1.0);
	} else if (p_material == "stone") {
		color = Color(0.250, 0.260, 0.245, 1.0);
	} else if (p_material == "sand") {
		color = Color(0.46, 0.38, 0.22, 1.0);
	} else if (p_material == "dirt") {
		color = Color(0.32, 0.22, 0.13, 1.0);
	} else if (p_material == "grass") {
		color = Color(0.31, 0.38, 0.23, 1.0);
	}
	return Color(color.r * facing_shade, color.g * facing_shade, color.b * facing_shade, color.a);
}

Color apply_air_side_light(const Color &p_color, double p_sky_light, double p_block_light) {
	double sky = CLAMP(p_sky_light / 15.0, 0.0, 1.0);
	double block = CLAMP(p_block_light / 15.0, 0.0, 1.0);
	double light = MAX(sky, block);
	double shade = 0.16 + 0.84 * Math::pow(light, 0.75);
	return Color(p_color.r * shade, p_color.g * shade, p_color.b * shade, p_color.a);
}

String dominant_solid_material(const std::array<String, CUBE_CORNER_COUNT> &p_materials, const std::array<int, 4> &p_solid_indices, int p_solid_count) {
	for (int i = 0; i < p_solid_count; ++i) {
		String material = p_materials[p_solid_indices[i]];
		if (!material.is_empty() && material != "air" && material != "water" && material != "lava") {
			return material;
		}
	}
	return "stone";
}

Color fluid_color(const String &p_fluid, const Vector3i &p_direction) {
	double shade = 0.88;
	if (p_direction.y < 0) {
		shade = 0.68;
	} else if (p_direction.y == 0) {
		shade = 0.78;
	}
	if (p_fluid == "lava") {
		return Color(1.0, 0.34, 0.08, 0.92) * shade;
	}
	return Color(0.22, 0.58, 0.68, 0.62) * shade;
}

std::array<Vector3, 4> fluid_face_corners(const Vector3i &p_cell, const Vector3i &p_direction, int p_step, int p_start_x, int p_start_z, double p_cell_size) {
	Vector3 p000 = local_position_for_cell(p_cell, p_start_x, p_start_z, p_cell_size);
	Vector3 p111 = local_position_for_cell(p_cell + Vector3i(p_step, p_step, p_step), p_start_x, p_start_z, p_cell_size);
	double x0 = p000.x;
	double y0 = p000.y;
	double z0 = p000.z;
	double x1 = p111.x;
	double y1 = p111.y;
	double z1 = p111.z;
	if (p_direction == Vector3i(1, 0, 0)) {
		return std::array<Vector3, 4>{Vector3(x1, y0, z0), Vector3(x1, y0, z1), Vector3(x1, y1, z1), Vector3(x1, y1, z0)};
	}
	if (p_direction == Vector3i(-1, 0, 0)) {
		return std::array<Vector3, 4>{Vector3(x0, y0, z1), Vector3(x0, y0, z0), Vector3(x0, y1, z0), Vector3(x0, y1, z1)};
	}
	if (p_direction == Vector3i(0, 1, 0)) {
		return std::array<Vector3, 4>{Vector3(x0, y1, z1), Vector3(x0, y1, z0), Vector3(x1, y1, z0), Vector3(x1, y1, z1)};
	}
	if (p_direction == Vector3i(0, -1, 0)) {
		return std::array<Vector3, 4>{Vector3(x0, y0, z0), Vector3(x0, y0, z1), Vector3(x1, y0, z1), Vector3(x1, y0, z0)};
	}
	if (p_direction == Vector3i(0, 0, 1)) {
		return std::array<Vector3, 4>{Vector3(x1, y0, z1), Vector3(x1, y1, z1), Vector3(x0, y1, z1), Vector3(x0, y0, z1)};
	}
	return std::array<Vector3, 4>{Vector3(x0, y0, z0), Vector3(x0, y1, z0), Vector3(x1, y1, z0), Vector3(x1, y0, z0)};
}

void append_fluid_triangle(
	PackedVector3Array &p_vertices,
	PackedVector3Array &p_normals,
	PackedColorArray &p_colors,
	const Vector3 &p_a,
	const Vector3 &p_b,
	const Vector3 &p_c,
	const Vector3 &p_normal,
	const Color &p_color
) {
	p_vertices.append(p_a);
	p_vertices.append(p_b);
	p_vertices.append(p_c);
	p_normals.append(p_normal);
	p_normals.append(p_normal);
	p_normals.append(p_normal);
	p_colors.append(p_color);
	p_colors.append(p_color);
	p_colors.append(p_color);
}

void append_fluid_boundary_face(
	PackedVector3Array &p_vertices,
	PackedVector3Array &p_normals,
	PackedColorArray &p_colors,
	const Vector3i &p_cell,
	const Vector3i &p_direction,
	int p_step,
	int p_start_x,
	int p_start_z,
	double p_cell_size,
	const String &p_fluid
) {
	std::array<Vector3, 4> corners = fluid_face_corners(p_cell, p_direction, p_step, p_start_x, p_start_z, p_cell_size);
	Vector3 normal(double(p_direction.x), double(p_direction.y), double(p_direction.z));
	normal.normalize();
	Color color = fluid_color(p_fluid, p_direction);
	append_fluid_triangle(p_vertices, p_normals, p_colors, corners[0], corners[1], corners[2], normal, color);
	append_fluid_triangle(p_vertices, p_normals, p_colors, corners[0], corners[2], corners[3], normal, color);
}

void add_colored_surface(Ref<ArrayMesh> &p_mesh, const PackedVector3Array &p_vertices, const PackedVector3Array &p_normals, const PackedColorArray &p_colors) {
	if (p_vertices.size() == 0) {
		return;
	}
	Array arrays;
	arrays.resize(Mesh::ARRAY_MAX);
	arrays[Mesh::ARRAY_VERTEX] = p_vertices;
	arrays[Mesh::ARRAY_NORMAL] = p_normals;
	arrays[Mesh::ARRAY_COLOR] = p_colors;
	p_mesh->add_surface_from_arrays(Mesh::PRIMITIVE_TRIANGLES, arrays);
}

void append_oriented_triangle(
	PackedVector3Array &p_vertices,
	PackedVector3Array &p_normals,
	PackedColorArray &p_colors,
	Vector3 p_a,
	Vector3 p_b,
	Vector3 p_c,
	Vector3 p_normal_a,
	Vector3 p_normal_b,
	Vector3 p_normal_c,
	const Vector3 &p_solid_reference,
	const Vector3 &p_air_reference,
	const Color &p_color
) {
	Vector3 normal = (p_b - p_a).cross(p_c - p_a);
	if (normal.length_squared() <= 0.000001) {
		return;
	}
	normal.normalize();
	Vector3 centroid = (p_a + p_b + p_c) / 3.0;
	Vector3 desired = p_air_reference - p_solid_reference;
	if (desired.length_squared() > 0.000001 && normal.dot(desired) < 0.0) {
		std::swap(p_b, p_c);
		std::swap(p_normal_b, p_normal_c);
		normal = -normal;
	}
	p_normal_a = surface_normal_from_density_gradient(-p_normal_a, desired, normal);
	p_normal_b = surface_normal_from_density_gradient(-p_normal_b, desired, normal);
	p_normal_c = surface_normal_from_density_gradient(-p_normal_c, desired, normal);
	p_vertices.append(p_a);
	p_vertices.append(p_b);
	p_vertices.append(p_c);
	p_normals.append(p_normal_a);
	p_normals.append(p_normal_b);
	p_normals.append(p_normal_c);
	p_colors.append(p_color);
	p_colors.append(p_color);
	p_colors.append(p_color);
}

void append_tetrahedron_surface(
	PackedVector3Array &p_vertices,
	PackedVector3Array &p_normals,
	PackedColorArray &p_colors,
	const std::array<Vector3, CUBE_CORNER_COUNT> &p_positions,
	const std::array<double, CUBE_CORNER_COUNT> &p_densities,
	const std::array<Vector3, CUBE_CORNER_COUNT> &p_density_gradients,
	const std::array<Vector3, CUBE_CORNER_COUNT> &p_surface_gradients,
	const std::array<double, CUBE_CORNER_COUNT> &p_surface_ys,
	const std::array<String, CUBE_CORNER_COUNT> &p_materials,
	const std::array<String, CUBE_CORNER_COUNT> &p_biomes,
	const std::array<int, CUBE_CORNER_COUNT> &p_sky_lights,
	const std::array<int, CUBE_CORNER_COUNT> &p_block_lights,
	const std::array<int, 4> &p_tetrahedron,
	double p_cell_size,
	bool p_use_material_colors
) {
	std::array<int, 4> solid_indices;
	std::array<int, 4> air_indices;
	int solid_count = 0;
	int air_count = 0;
	for (int i = 0; i < 4; ++i) {
		int corner = p_tetrahedron[i];
		if (p_densities[corner] >= 0.0) {
			solid_indices[solid_count++] = corner;
		} else {
			air_indices[air_count++] = corner;
		}
	}
	if (solid_count == 0 || air_count == 0) {
		return;
	}

	Vector3 solid_reference;
	Vector3 air_reference;
	for (int i = 0; i < solid_count; ++i) {
		solid_reference += p_positions[solid_indices[i]];
	}
	for (int i = 0; i < air_count; ++i) {
		air_reference += p_positions[air_indices[i]];
	}
	solid_reference /= double(solid_count);
	air_reference /= double(air_count);

	double surface_y = 0.0;
	for (int i = 0; i < 4; ++i) {
		surface_y += p_surface_ys[p_tetrahedron[i]];
	}
	surface_y /= 4.0;
	double world_y = (solid_reference.y + air_reference.y) * 0.5;
	double air_sky_light = 0.0;
	double min_air_sky_light = 15.0;
	double air_block_light = 0.0;
	bool air_side_is_underground = false;
	for (int i = 0; i < air_count; ++i) {
		int index = air_indices[i];
		air_sky_light = MAX(air_sky_light, double(p_sky_lights[index]));
		min_air_sky_light = MIN(min_air_sky_light, double(p_sky_lights[index]));
		air_block_light = MAX(air_block_light, double(p_block_lights[index]));
		if (p_biomes[index] == "underground_air") {
			air_side_is_underground = true;
		}
	}
	double depth_cells = (surface_y - world_y) / MAX(0.001, p_cell_size);
	String material = dominant_solid_material(p_materials, solid_indices, solid_count);
	Color color = color_for_surface(world_y, surface_y, p_cell_size);
	if (p_use_material_colors) {
		Vector3 air_direction = air_reference - solid_reference;
		if (air_direction.length_squared() > 0.000001) {
			air_direction.normalize();
		}
		color = air_side_is_underground ? underground_material_color(material, air_direction) : material_color(material, world_y, surface_y, p_cell_size);
	}
	if (air_side_is_underground) {
		color = apply_air_side_light(color, air_sky_light, air_block_light);
	}
	bool use_volume_normals = air_side_is_underground && depth_cells > 2.5;
	const std::array<Vector3, CUBE_CORNER_COUNT> &normal_gradients = use_volume_normals ? p_density_gradients : p_surface_gradients;

	if (solid_count == 1) {
		int s0 = solid_indices[0];
		Vector3 p0 = interpolate_zero_crossing(p_positions[s0], p_positions[air_indices[0]], p_densities[s0], p_densities[air_indices[0]]);
		Vector3 p1 = interpolate_zero_crossing(p_positions[s0], p_positions[air_indices[1]], p_densities[s0], p_densities[air_indices[1]]);
		Vector3 p2 = interpolate_zero_crossing(p_positions[s0], p_positions[air_indices[2]], p_densities[s0], p_densities[air_indices[2]]);
		Vector3 n0 = interpolate_zero_crossing_normal(normal_gradients[s0], normal_gradients[air_indices[0]], p_densities[s0], p_densities[air_indices[0]], air_reference - solid_reference);
		Vector3 n1 = interpolate_zero_crossing_normal(normal_gradients[s0], normal_gradients[air_indices[1]], p_densities[s0], p_densities[air_indices[1]], air_reference - solid_reference);
		Vector3 n2 = interpolate_zero_crossing_normal(normal_gradients[s0], normal_gradients[air_indices[2]], p_densities[s0], p_densities[air_indices[2]], air_reference - solid_reference);
		append_oriented_triangle(p_vertices, p_normals, p_colors, p0, p1, p2, n0, n1, n2, solid_reference, air_reference, color);
		return;
	}
	if (solid_count == 3) {
		int a0 = air_indices[0];
		Vector3 p0 = interpolate_zero_crossing(p_positions[a0], p_positions[solid_indices[0]], p_densities[a0], p_densities[solid_indices[0]]);
		Vector3 p1 = interpolate_zero_crossing(p_positions[a0], p_positions[solid_indices[1]], p_densities[a0], p_densities[solid_indices[1]]);
		Vector3 p2 = interpolate_zero_crossing(p_positions[a0], p_positions[solid_indices[2]], p_densities[a0], p_densities[solid_indices[2]]);
		Vector3 n0 = interpolate_zero_crossing_normal(normal_gradients[a0], normal_gradients[solid_indices[0]], p_densities[a0], p_densities[solid_indices[0]], air_reference - solid_reference);
		Vector3 n1 = interpolate_zero_crossing_normal(normal_gradients[a0], normal_gradients[solid_indices[1]], p_densities[a0], p_densities[solid_indices[1]], air_reference - solid_reference);
		Vector3 n2 = interpolate_zero_crossing_normal(normal_gradients[a0], normal_gradients[solid_indices[2]], p_densities[a0], p_densities[solid_indices[2]], air_reference - solid_reference);
		append_oriented_triangle(p_vertices, p_normals, p_colors, p0, p2, p1, n0, n2, n1, solid_reference, air_reference, color);
		return;
	}

	int s0 = solid_indices[0];
	int s1 = solid_indices[1];
	int a0 = air_indices[0];
	int a1 = air_indices[1];
	Vector3 p00 = interpolate_zero_crossing(p_positions[s0], p_positions[a0], p_densities[s0], p_densities[a0]);
	Vector3 p01 = interpolate_zero_crossing(p_positions[s0], p_positions[a1], p_densities[s0], p_densities[a1]);
	Vector3 p10 = interpolate_zero_crossing(p_positions[s1], p_positions[a0], p_densities[s1], p_densities[a0]);
	Vector3 p11 = interpolate_zero_crossing(p_positions[s1], p_positions[a1], p_densities[s1], p_densities[a1]);
	Vector3 desired = air_reference - solid_reference;
	Vector3 n00 = interpolate_zero_crossing_normal(normal_gradients[s0], normal_gradients[a0], p_densities[s0], p_densities[a0], desired);
	Vector3 n01 = interpolate_zero_crossing_normal(normal_gradients[s0], normal_gradients[a1], p_densities[s0], p_densities[a1], desired);
	Vector3 n10 = interpolate_zero_crossing_normal(normal_gradients[s1], normal_gradients[a0], p_densities[s1], p_densities[a0], desired);
	Vector3 n11 = interpolate_zero_crossing_normal(normal_gradients[s1], normal_gradients[a1], p_densities[s1], p_densities[a1], desired);
	append_oriented_triangle(p_vertices, p_normals, p_colors, p00, p10, p11, n00, n10, n11, solid_reference, air_reference, color);
	append_oriented_triangle(p_vertices, p_normals, p_colors, p00, p11, p01, n00, n11, n01, solid_reference, air_reference, color);
}

Ref<Material> terrain_material(Object *p_main) {
	if (p_main == nullptr) {
		return Ref<Material>();
	}
	Variant material_value = p_main->get("terrain_material");
	if (material_value.get_type() == Variant::OBJECT) {
		Ref<Material> material = material_value;
		return material;
	}
	return Ref<Material>();
}
} // namespace

void TerrainMeshingBackend::_bind_methods() {
	ClassDB::bind_method(D_METHOD("backend_summary"), &TerrainMeshingBackend::backend_summary);
	ClassDB::bind_method(D_METHOD("build_chunk_mesh", "main", "cx", "cz"), &TerrainMeshingBackend::build_chunk_mesh);
	ClassDB::bind_method(D_METHOD("build_chunk_surface_data_from_sections", "payload"), &TerrainMeshingBackend::build_chunk_surface_data_from_sections);
	ClassDB::bind_method(D_METHOD("build_chunk_mesh_from_sections", "payload"), &TerrainMeshingBackend::build_chunk_mesh_from_sections);
	ClassDB::bind_method(D_METHOD("build_chunk_fluid_surface_data_from_sections", "payload"), &TerrainMeshingBackend::build_chunk_fluid_surface_data_from_sections);
	ClassDB::bind_method(D_METHOD("build_chunk_fluid_mesh_from_sections", "payload"), &TerrainMeshingBackend::build_chunk_fluid_mesh_from_sections);
	ClassDB::bind_method(D_METHOD("build_chunk_fluid_mesh", "main", "cx", "cz"), &TerrainMeshingBackend::build_chunk_fluid_mesh);
	ClassDB::bind_method(D_METHOD("collision_shape_for_mesh", "mesh"), &TerrainMeshingBackend::collision_shape_for_mesh);
	ClassDB::bind_method(D_METHOD("build_chunk_assets", "main", "cx", "cz", "include_collision"), &TerrainMeshingBackend::build_chunk_assets);
}

Dictionary TerrainMeshingBackend::backend_summary() const {
	Dictionary result;
	result["id"] = "native_volume_mesher";
	result["native"] = true;
	result["async"] = false;
	result["implementation"] = "native_density_marching_tetrahedra_v1";
	result["colorModel"] = "underground_air_dark_palette_depth_v4";
	result["ready"] = true;
	result["terrainSurfaceDataReady"] = true;
	result["fluidReady"] = true;
	result["fluidImplementation"] = "native_section_payload_fluid_faces_v1";
	return result;
}

Variant TerrainMeshingBackend::build_chunk_mesh(Object *p_main, int32_t p_cx, int32_t p_cz) {
	if (p_main == nullptr) {
		return Variant();
	}
	int chunk_size = get_main_int(p_main, "CHUNK_SIZE", 28);
	double cell_size = get_main_float(p_main, "CELL", 1.35);
	if (chunk_size <= 0 || cell_size <= 0.0) {
		return Variant();
	}
	int start_x = int(p_cx) * chunk_size;
	int start_z = int(p_cz) * chunk_size;
	bool has_excavation = call_main_bool(p_main, "chunk_has_excavation_overlap", start_x, start_z);
	bool generated_volume_required = call_main_bool(p_main, "chunk_needs_generated_underground_volume_mesh", start_x, start_z);
	if (!has_excavation && !generated_volume_required) {
		return Variant();
	}

	int step = call_main_int(p_main, "underground_volume_mesh_step_for_chunk", start_x, start_z, 2);
	step = CLAMP(step, 1, 4);
	Dictionary bounds = call_main_dictionary(p_main, "chunk_volume_y_bounds", start_x, start_z);
	int min_y = int(bounds.get("minY", -32)) - 1;
	int max_y = int(bounds.get("maxY", 96)) + 1;
	if (max_y <= min_y) {
		return Variant();
	}

	PackedVector3Array vertices;
	PackedVector3Array normals;
	PackedColorArray colors;
	Dictionary sample_cache;
	for (int z = start_z; z < start_z + chunk_size; z += step) {
		for (int x = start_x; x < start_x + chunk_size; x += step) {
			for (int y = min_y; y < max_y; y += step) {
				Vector3i origin(x, y, z);
				std::array<Vector3, CUBE_CORNER_COUNT> positions;
				std::array<double, CUBE_CORNER_COUNT> densities;
				std::array<Vector3, CUBE_CORNER_COUNT> density_gradients;
				std::array<Vector3, CUBE_CORNER_COUNT> surface_gradients;
				std::array<double, CUBE_CORNER_COUNT> surface_ys;
				std::array<String, CUBE_CORNER_COUNT> materials;
				std::array<String, CUBE_CORNER_COUNT> biomes;
				std::array<int, CUBE_CORNER_COUNT> sky_lights;
				std::array<int, CUBE_CORNER_COUNT> block_lights;
				bool has_solid = false;
				bool has_air = false;
				for (int i = 0; i < CUBE_CORNER_COUNT; ++i) {
					Vector3i corner_cell = origin + CUBE_CORNERS[i] * step;
					Vector3 numeric = sample_numeric(p_main, corner_cell, sample_cache);
					positions[i] = local_position_for_cell(corner_cell, start_x, start_z, cell_size);
					densities[i] = numeric.x;
					surface_ys[i] = numeric.z;
					density_gradients[i] = density_gradient_from_main(p_main, corner_cell, sample_cache, step);
					surface_gradients[i] = surface_density_gradient_from_main(p_main, corner_cell, sample_cache, step, cell_size);
					materials[i] = "";
					biomes[i] = "";
					sky_lights[i] = densities[i] < 0.0 && double(corner_cell.y) * cell_size >= surface_ys[i] - cell_size * 0.15 ? 15 : 0;
					block_lights[i] = 0;
					has_solid = has_solid || densities[i] >= 0.0;
					has_air = has_air || densities[i] < 0.0;
				}
				if (!has_solid || !has_air) {
					continue;
				}
				for (const std::array<int, 4> &tetrahedron : TETRAHEDRA) {
					append_tetrahedron_surface(vertices, normals, colors, positions, densities, density_gradients, surface_gradients, surface_ys, materials, biomes, sky_lights, block_lights, tetrahedron, cell_size, false);
				}
			}
		}
	}

	Ref<ArrayMesh> mesh;
	mesh.instantiate();
	if (vertices.size() > 0) {
		Array arrays;
		arrays.resize(Mesh::ARRAY_MAX);
		arrays[Mesh::ARRAY_VERTEX] = vertices;
		arrays[Mesh::ARRAY_NORMAL] = normals;
		arrays[Mesh::ARRAY_COLOR] = colors;
		mesh->add_surface_from_arrays(Mesh::PRIMITIVE_TRIANGLES, arrays);
		Ref<Material> material = terrain_material(p_main);
		if (material.is_valid()) {
			mesh->surface_set_material(0, material);
		}
	}
	mesh->set_meta("terrainMeshingBackend", "native_volume_mesher");
	mesh->set_meta("terrainMeshingNative", true);
	mesh->set_meta("terrainMeshingQueued", false);
	mesh->set_meta("chunk_volume_faces", vertices.size() / 3);
	mesh->set_meta("chunk_volume_vertices", vertices.size());
	mesh->set_meta("nativeVolumeVertices", vertices.size());
	mesh->set_meta("nativeVolumeStepCells", step);
	return mesh;
}

Dictionary TerrainMeshingBackend::build_chunk_surface_data_from_sections(const Dictionary &p_payload) {
	int chunk_size = int(p_payload.get("chunkSize", 28));
	double cell_size = double(p_payload.get("cellSize", 1.35));
	int start_x = int(p_payload.get("startX", int(p_payload.get("chunkX", 0)) * chunk_size));
	int start_z = int(p_payload.get("startZ", int(p_payload.get("chunkZ", 0)) * chunk_size));
	int min_y = int(p_payload.get("minY", int(p_payload.get("worldBottomCellY", -64)))) - 1;
	int max_y = int(p_payload.get("maxY", int(p_payload.get("worldTopCellY", 96)))) + 1;
	if (chunk_size <= 0 || cell_size <= 0.0 || max_y <= min_y) {
		return Dictionary();
	}
	Dictionary section_lookup = section_lookup_from_payload(p_payload);
	if (section_lookup.is_empty()) {
		return Dictionary();
	}
	int step = CLAMP(int(p_payload.get("stepCells", 2)), 1, 16);
	PackedVector3Array vertices;
	PackedVector3Array normals;
	PackedColorArray colors;
	for (int z = start_z; z < start_z + chunk_size; z += step) {
		for (int x = start_x; x < start_x + chunk_size; x += step) {
			for (int y = min_y; y < max_y; y += step) {
				Vector3i origin(x, y, z);
				std::array<Vector3, CUBE_CORNER_COUNT> positions;
				std::array<double, CUBE_CORNER_COUNT> densities;
				std::array<Vector3, CUBE_CORNER_COUNT> density_gradients;
				std::array<Vector3, CUBE_CORNER_COUNT> surface_gradients;
				std::array<double, CUBE_CORNER_COUNT> surface_ys;
				std::array<String, CUBE_CORNER_COUNT> materials;
				std::array<String, CUBE_CORNER_COUNT> biomes;
				std::array<int, CUBE_CORNER_COUNT> sky_lights;
				std::array<int, CUBE_CORNER_COUNT> block_lights;
				bool has_solid = false;
				bool has_air = false;
				for (int i = 0; i < CUBE_CORNER_COUNT; ++i) {
					Vector3i corner_cell = origin + CUBE_CORNERS[i] * step;
					PayloadSample sample = sample_section_payload(p_payload, section_lookup, corner_cell);
					positions[i] = local_position_for_cell(corner_cell, start_x, start_z, cell_size);
					densities[i] = sample.density;
					surface_ys[i] = sample.surface_y;
					density_gradients[i] = density_gradient_from_section_payload(p_payload, section_lookup, corner_cell, step);
					surface_gradients[i] = surface_density_gradient_from_section_payload(p_payload, section_lookup, corner_cell, step);
					materials[i] = sample.material;
					biomes[i] = sample.biome;
					sky_lights[i] = sample.sky_light;
					block_lights[i] = sample.block_light;
					has_solid = has_solid || densities[i] >= 0.0;
					has_air = has_air || densities[i] < 0.0;
				}
				if (!has_solid || !has_air) {
					continue;
				}
				for (const std::array<int, 4> &tetrahedron : TETRAHEDRA) {
					append_tetrahedron_surface(vertices, normals, colors, positions, densities, density_gradients, surface_gradients, surface_ys, materials, biomes, sky_lights, block_lights, tetrahedron, cell_size, true);
				}
			}
		}
	}

	Dictionary result;
	result["vertices"] = vertices;
	result["normals"] = normals;
	result["colors"] = colors;
	result["faceCount"] = vertices.size() / 3;
	result["vertexCount"] = vertices.size();
	result["stepCells"] = step;
	result["sectionCount"] = section_lookup.size();
	result["valid"] = true;
	return result;
}

Variant TerrainMeshingBackend::build_chunk_mesh_from_sections(const Dictionary &p_payload) {
	Dictionary data = build_chunk_surface_data_from_sections(p_payload);
	if (data.is_empty() || !bool(data.get("valid", false))) {
		return Variant();
	}
	PackedVector3Array vertices = data.get("vertices", PackedVector3Array());
	Ref<ArrayMesh> mesh;
	mesh.instantiate();
	if (vertices.size() > 0) {
		Array arrays;
		arrays.resize(Mesh::ARRAY_MAX);
		arrays[Mesh::ARRAY_VERTEX] = vertices;
		arrays[Mesh::ARRAY_NORMAL] = data.get("normals", PackedVector3Array());
		arrays[Mesh::ARRAY_COLOR] = data.get("colors", PackedColorArray());
		mesh->add_surface_from_arrays(Mesh::PRIMITIVE_TRIANGLES, arrays);
	}
	mesh->set_meta("terrainMeshingBackend", "native_volume_mesher");
	mesh->set_meta("terrainMeshingNative", true);
	mesh->set_meta("terrainMeshingQueued", false);
	mesh->set_meta("terrainMeshingSectionPayload", true);
	mesh->set_meta("nativeVolumeMaterialIds", true);
	mesh->set_meta("chunk_volume_faces", int(data.get("faceCount", 0)));
	mesh->set_meta("chunk_volume_vertices", int(data.get("vertexCount", 0)));
	mesh->set_meta("nativeVolumeVertices", int(data.get("vertexCount", 0)));
	mesh->set_meta("nativeVolumeStepCells", int(data.get("stepCells", 1)));
	mesh->set_meta("nativeVolumeSections", int(data.get("sectionCount", 0)));
	return mesh;
}

Dictionary TerrainMeshingBackend::build_chunk_fluid_surface_data_from_sections(const Dictionary &p_payload) {
	auto deferred_data = [](const String &p_reason, bool p_forbidden, int p_unknown_neighbors = 0) {
		Dictionary result;
		result["deferred"] = true;
		result["reason"] = p_reason;
		result["forbiddenCoarseFluidPayload"] = p_forbidden;
		result["unknownNeighborCount"] = p_unknown_neighbors;
		result["waterVertices"] = PackedVector3Array();
		result["waterNormals"] = PackedVector3Array();
		result["waterColors"] = PackedColorArray();
		result["lavaVertices"] = PackedVector3Array();
		result["lavaNormals"] = PackedVector3Array();
		result["lavaColors"] = PackedColorArray();
		return result;
	};
	Dictionary fluid_payload;
	Variant nested_payload_value = p_payload.get("fluidPayload", Variant());
	if (nested_payload_value.get_type() == Variant::DICTIONARY) {
		fluid_payload = Dictionary(nested_payload_value);
	} else {
		fluid_payload = p_payload;
	}
	bool exact_contract = int(fluid_payload.get("schemaVersion", 0)) == 1 &&
		int(fluid_payload.get("fluidStepCells", 0)) == 1 &&
		int(fluid_payload.get("stepCells", 0)) == 1 &&
		bool(fluid_payload.get("boundsInclusive", false));
	bool legacy_exact_contract = !exact_contract && int(fluid_payload.get("stepCells", 0)) == 1;
	if (!exact_contract && !legacy_exact_contract) {
		return deferred_data("exact_fluid_payload_required", true);
	}
	int chunk_size = int(fluid_payload.get("chunkSize", 28));
	double cell_size = double(fluid_payload.get("cellSize", 1.35));
	int start_x = int(fluid_payload.get("startX", int(fluid_payload.get("chunkX", 0)) * chunk_size));
	int start_z = int(fluid_payload.get("startZ", int(fluid_payload.get("chunkZ", 0)) * chunk_size));
	int min_y = int(fluid_payload.get("minY", int(fluid_payload.get("worldBottomCellY", -64))));
	int max_y = int(fluid_payload.get("maxY", int(fluid_payload.get("worldTopCellY", 96))));
	Variant min_cell_value = fluid_payload.get("minCell", Variant());
	Variant max_cell_value = fluid_payload.get("maxCell", Variant());
	if (chunk_size <= 0 || cell_size <= 0.0 || max_y < min_y || min_cell_value.get_type() != Variant::VECTOR3I || max_cell_value.get_type() != Variant::VECTOR3I) {
		return deferred_data("invalid_exact_fluid_bounds", false);
	}
	Vector3i min_cell = min_cell_value;
	Vector3i max_cell = max_cell_value;
	bool halo_complete = min_cell.x <= start_x - 1 && max_cell.x >= start_x + chunk_size &&
		min_cell.z <= start_z - 1 && max_cell.z >= start_z + chunk_size &&
		min_cell.y <= min_y - 1 && max_cell.y >= max_y + 1;
	if (!halo_complete) {
		return deferred_data("incomplete_exact_fluid_halo", false);
	}
	Dictionary section_lookup = section_lookup_from_payload(fluid_payload);
	bool has_fluid = bool(fluid_payload.get("hasFluid", false));
	if (!has_fluid) {
		Dictionary result = deferred_data("no_exact_fluid_cells", false);
		result["deferred"] = false;
		result["exactContract"] = exact_contract;
		result["legacyExactContract"] = legacy_exact_contract;
		result["fluidPayloadRevision"] = int(fluid_payload.get("fluidRevision", 0));
		result["fluidPayloadSignature"] = String(fluid_payload.get("signature", ""));
		return result;
	}
	Variant cells_value = fluid_payload.get("cells", Dictionary());
	bool has_flat_cells = cells_value.get_type() == Variant::DICTIONARY && !Dictionary(cells_value).is_empty();
	if (section_lookup.is_empty() && !has_flat_cells) {
		return deferred_data("missing_exact_fluid_sections", false);
	}
	// The exact payload normally includes one dense, halo-complete cell block. Resolve
	// its channels once instead of repeating Dictionary and PackedArray lookups for
	// every cell and each of its six neighbors. The section sampler remains the exact
	// fallback for older payloads and malformed dense blocks.
	Vector3i flat_size;
	PackedByteArray flat_solid_values;
	PackedByteArray flat_fluid_values;
	bool flat_cells_valid = false;
	if (exact_contract && has_flat_cells) {
		Dictionary flat_cells = cells_value;
		Variant flat_size_value = flat_cells.get("size", Variant());
		flat_solid_values = flat_cells.get("solid", PackedByteArray());
		flat_fluid_values = flat_cells.get("fluidTypeIds", PackedByteArray());
		if (flat_size_value.get_type() == Variant::VECTOR3I) {
			flat_size = flat_size_value;
			int expected_size = flat_size.x * flat_size.y * flat_size.z;
			flat_cells_valid = flat_size.x > 0 && flat_size.y > 0 && flat_size.z > 0 &&
				flat_solid_values.size() == expected_size && flat_fluid_values.size() == expected_size;
		}
	}
	auto sample_fluid = [&](const Vector3i &p_cell) -> ExactFluidSample {
		if (flat_cells_valid) {
			ExactFluidSample result;
			if (p_cell.x < min_cell.x || p_cell.x > max_cell.x || p_cell.y < min_cell.y || p_cell.y > max_cell.y || p_cell.z < min_cell.z || p_cell.z > max_cell.z) {
				return result;
			}
			Vector3i local = p_cell - min_cell;
			int index = local.y + flat_size.y * (local.x + flat_size.x * local.z);
			int expected_size = flat_size.x * flat_size.y * flat_size.z;
			result.known = index >= 0 && index < expected_size;
			result.solid = result.known && int(flat_solid_values[index]) > 0;
			result.fluid_type = result.known ? CLAMP(int(flat_fluid_values[index]), 0, 2) : 0;
			return result;
		}
		return exact_contract ? sample_exact_fluid_payload(fluid_payload, section_lookup, p_cell) : sample_legacy_exact_fluid_payload(fluid_payload, section_lookup, p_cell);
	};
	PackedVector3Array water_vertices;
	PackedVector3Array water_normals;
	PackedColorArray water_colors;
	PackedVector3Array lava_vertices;
	PackedVector3Array lava_normals;
	PackedColorArray lava_colors;
	int water_faces = 0;
	int lava_faces = 0;
	int exact_fluid_cells = 0;
	int unknown_neighbor_count = 0;
	for (int z = start_z; z < start_z + chunk_size; ++z) {
		for (int x = start_x; x < start_x + chunk_size; ++x) {
			for (int y = min_y; y <= max_y; ++y) {
				Vector3i cell(x, y, z);
				ExactFluidSample sample = sample_fluid(cell);
				if (!sample.known || sample.solid || sample.fluid_type == 0) {
					continue;
				}
				exact_fluid_cells += 1;
				for (const Vector3i &direction : CARDINAL_DIRECTIONS) {
					ExactFluidSample neighbor = sample_fluid(cell + direction);
					if (!neighbor.known) {
						unknown_neighbor_count += 1;
						continue;
					}
					if (neighbor.solid || neighbor.fluid_type == sample.fluid_type) {
						continue;
					}
					if (neighbor.fluid_type != 0 && sample.fluid_type < neighbor.fluid_type) {
						continue;
					}
					String fluid_id = fluid_id_from_type(sample.fluid_type);
					if (sample.fluid_type == 2) {
						append_fluid_boundary_face(lava_vertices, lava_normals, lava_colors, cell, direction, 1, start_x, start_z, cell_size, fluid_id);
						lava_faces += 1;
					} else {
						append_fluid_boundary_face(water_vertices, water_normals, water_colors, cell, direction, 1, start_x, start_z, cell_size, fluid_id);
						water_faces += 1;
					}
				}
			}
		}
	}
	if (unknown_neighbor_count > 0) {
		return deferred_data("incomplete_exact_fluid_halo", false, unknown_neighbor_count);
	}
	PackedStringArray surface_order;
	if (water_vertices.size() > 0) {
		surface_order.append("water");
	}
	if (lava_vertices.size() > 0) {
		surface_order.append("lava");
	}
	Variant section_revisions_value = fluid_payload.get("sectionRevisions", Array());
	int exact_section_count = section_revisions_value.get_type() == Variant::ARRAY ? Array(section_revisions_value).size() : section_lookup.size();
	Dictionary result;
	result["deferred"] = false;
	result["reason"] = "";
	result["forbiddenCoarseFluidPayload"] = false;
	result["unknownNeighborCount"] = 0;
	result["waterVertices"] = water_vertices;
	result["waterNormals"] = water_normals;
	result["waterColors"] = water_colors;
	result["lavaVertices"] = lava_vertices;
	result["lavaNormals"] = lava_normals;
	result["lavaColors"] = lava_colors;
	result["surfaceOrder"] = surface_order;
	result["fluidFaces"] = water_faces + lava_faces;
	result["waterFaces"] = water_faces;
	result["lavaFaces"] = lava_faces;
	result["exactSectionCount"] = exact_section_count;
	result["exactFluidCellCount"] = exact_fluid_cells;
	result["fluidPayloadRevision"] = int(fluid_payload.get("fluidRevision", 0));
	result["fluidPayloadSignature"] = String(fluid_payload.get("signature", ""));
	result["exactContract"] = exact_contract;
	result["legacyExactContract"] = legacy_exact_contract;
	return result;
}

Variant TerrainMeshingBackend::build_chunk_fluid_mesh_from_sections(const Dictionary &p_payload) {
	Dictionary data = build_chunk_fluid_surface_data_from_sections(p_payload);
	Ref<ArrayMesh> mesh;
	mesh.instantiate();
	PackedVector3Array water_vertices = data.get("waterVertices", PackedVector3Array());
	PackedVector3Array lava_vertices = data.get("lavaVertices", PackedVector3Array());
	if (water_vertices.size() > 0) {
		add_colored_surface(mesh, water_vertices, data.get("waterNormals", PackedVector3Array()), data.get("waterColors", PackedColorArray()));
	}
	if (lava_vertices.size() > 0) {
		add_colored_surface(mesh, lava_vertices, data.get("lavaNormals", PackedVector3Array()), data.get("lavaColors", PackedColorArray()));
	}
	mesh->set_meta("terrainMeshingBackend", "native_volume_mesher");
	mesh->set_meta("terrainMeshingNative", true);
	mesh->set_meta("terrainMeshingQueued", false);
	mesh->set_meta("terrainFluidSectionPayload", !bool(data.get("deferred", true)));
	mesh->set_meta("terrainFluidSurfaceOrder", data.get("surfaceOrder", PackedStringArray()));
	mesh->set_meta("chunk_fluid_faces", int(data.get("fluidFaces", 0)));
	mesh->set_meta("chunk_water_faces", int(data.get("waterFaces", 0)));
	mesh->set_meta("chunk_lava_faces", int(data.get("lavaFaces", 0)));
	mesh->set_meta("nativeFluidStepCells", bool(data.get("forbiddenCoarseFluidPayload", false)) ? 0 : 1);
	mesh->set_meta("nativeFluidSections", int(data.get("exactSectionCount", 0)));
	mesh->set_meta("nativeFluidCellCount", int(data.get("exactFluidCellCount", 0)));
	mesh->set_meta("fluidPayloadRevision", int(data.get("fluidPayloadRevision", 0)));
	mesh->set_meta("fluidPayloadSignature", String(data.get("fluidPayloadSignature", "")));
	mesh->set_meta("terrainFluidNativeDeferred", bool(data.get("deferred", true)));
	mesh->set_meta("terrainFluidDeferredReason", String(data.get("reason", "")));
	mesh->set_meta("unknownFluidNeighborCount", int(data.get("unknownNeighborCount", 0)));
	mesh->set_meta("forbiddenCoarseFluidPayload", bool(data.get("forbiddenCoarseFluidPayload", false)));
	mesh->set_meta("terrainFluidExactPayload", bool(data.get("exactContract", false)));
	mesh->set_meta("terrainFluidLegacyExactPayload", bool(data.get("legacyExactContract", false)));
	return mesh;
}

Variant TerrainMeshingBackend::build_chunk_fluid_mesh(Object *p_main, int32_t p_cx, int32_t p_cz) {
	(void)p_main;
	(void)p_cx;
	(void)p_cz;
	Ref<ArrayMesh> mesh;
	mesh.instantiate();
	mesh->set_meta("terrainMeshingBackend", "native_volume_mesher");
	mesh->set_meta("terrainMeshingNative", true);
	mesh->set_meta("terrainFluidNativeDeferred", true);
	return mesh;
}

Variant TerrainMeshingBackend::collision_shape_for_mesh(const Ref<Mesh> &p_mesh) {
	if (p_mesh.is_null()) {
		return Variant();
	}
	Ref<Shape3D> shape = p_mesh->create_trimesh_shape();
	Ref<ConcavePolygonShape3D> concave = shape;
	if (concave.is_valid()) {
		concave->set_backface_collision_enabled(true);
	}
	return shape;
}

Dictionary TerrainMeshingBackend::build_chunk_assets(Object *p_main, int32_t p_cx, int32_t p_cz, bool p_include_collision) {
	Dictionary result;
	Variant mesh = build_chunk_mesh(p_main, p_cx, p_cz);
	Variant fluid_mesh = build_chunk_fluid_mesh(p_main, p_cx, p_cz);
	Ref<Mesh> mesh_ref;
	if (mesh.get_type() == Variant::OBJECT) {
		mesh_ref = mesh;
	}
	result["mesh"] = mesh;
	result["fluidMesh"] = fluid_mesh;
	result["shape"] = (p_include_collision && mesh_ref.is_valid()) ? collision_shape_for_mesh(mesh_ref) : Variant();
	result["native"] = true;
	result["ready"] = mesh_ref.is_valid();
	return result;
}
