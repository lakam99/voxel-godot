#include "native_world_backend_adapter.h"

#include "biome_region_field.hpp"
#include "native_biome_environment_catalog.hpp"
#include "native_feature_delta.hpp"
#include "native_effective_voxel_block.hpp"
#include "native_multi_page_voxel_block.hpp"
#include "native_surface_feature_manifest.hpp"
#include "native_surface_forage_ordered_definition.hpp"
#include "native_surface_ore_cluster_definition.hpp"
#include "native_surface_prop_source_ordered_stream.hpp"
#include "native_surface_rock_ordered_visual_plan.hpp"
#include "native_surface_tree_ordered_composer.hpp"
#include "native_surface_tree_presence.hpp"
#include "native_surface_wildlife_ordered_definition.hpp"
#include "sha256.hpp"
#include "terrain_snapshot.hpp"

#include <godot_cpp/classes/engine.hpp>
#include <godot_cpp/classes/json.hpp>
#include <godot_cpp/classes/marshalls.hpp>
#include <godot_cpp/classes/ref.hpp>
#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/variant/packed_byte_array.hpp>
#include <godot_cpp/variant/rect2i.hpp>
#include <godot_cpp/variant/string.hpp>
#include <godot_cpp/variant/utility_functions.hpp>
#include <godot_cpp/variant/vector3.hpp>
#include <godot_cpp/variant/vector3i.hpp>

#include <algorithm>
#include <cmath>
#include <cstdint>
#include <cstring>
#include <initializer_list>
#include <iterator>
#include <limits>
#include <thread>
#include <stdexcept>
#include <string>
#include <utility>

using namespace godot;
using namespace voxel::world_backend;

namespace {

constexpr const char *ADAPTER_SCHEMA = "n3-native-world-backend-adapter/v1";
constexpr const char *INITIALIZE_SCHEMA = "n3-native-world-backend-initialize/v1";
constexpr const char *INITIALIZE_FROM_SAVE_V2_SCHEMA = "n3-native-world-backend-initialize-from-save-v2/v1";
constexpr const char *BATCH_REQUEST_SCHEMA = "n3-effective-terrain-batch-request/v1";
constexpr const char *BATCH_RESULT_SCHEMA = "n3-effective-terrain-batch-result/v1";
constexpr const char *VOXEL_BLOCK_REQUEST_SCHEMA = "n3-effective-voxel-block-request/v1";
constexpr const char *VOXEL_BLOCK_RESULT_SCHEMA = "n3-effective-voxel-block-result/v1";
constexpr const char *VOXEL_BLOCK_ASYNC_SCHEMA = "n3-voxel-block-shadow-async/v1";
constexpr const char *REMOVED_PROPS_RECEIPT_SCHEMA = "n4-removed-props-tombstone-receipt/v1";
constexpr const char *BIOME_CATALOG_RECEIPT_SCHEMA = "n4-biome-environment-catalog-receipt/v1";
constexpr const char *VISUAL_CATALOG_RECEIPT_SCHEMA = "n4-visual-asset-catalog-receipt/v1";
constexpr const char *WILDLIFE_PRESENTATION_RECEIPT_SCHEMA = "n4-wildlife-presentation-catalog-receipt/v1";
constexpr const char *STRUCTURE_CHUNK_RECEIPT_SCHEMA = "n4-structure-exclusion-chunk-receipt/v1";
constexpr const char *SURFACE_ORDERED_SHADOW_SCHEMA = "n4-surface-prop-ordered-shadow/v1";
constexpr const char *TREE_PRESENCE_SHADOW_SCHEMA = "n4-surface-tree-presence-shadow/v1";
constexpr std::size_t MAX_BATCH_CHANNEL_QUERIES = 4096U;
constexpr std::size_t MAX_BATCH_TOTAL_QUERIES = 16384U;
constexpr std::size_t MAX_TOWN_OVERRIDES = 4096U;
constexpr std::size_t MAX_SHAPING_RESOLUTIONS = 64U;
constexpr std::size_t MAX_TYPED_CELL_OPERATIONS = 4096U;
constexpr std::size_t MAX_PROTOCOL_TEXT_BYTES = 128U;
// CitadelSiteBuildQueue._canonical_request admits 1024 Unicode code points.
// Keep that semantic limit exact while independently bounding the temporary
// UTF-8 representation at the maximum four bytes per admitted scalar.
constexpr std::size_t MAX_SEED_CODE_POINTS = 1024U;
constexpr std::size_t MAX_SEED_TEXT_BYTES = MAX_SEED_CODE_POINTS * 4U;
constexpr std::size_t MAX_TRANSACTION_ID_BYTES = 1024U;
constexpr std::size_t MAX_BLOCK_ID_BYTES = 1024U;
constexpr std::size_t MAX_EDIT_REASON_BYTES = 1024U;
constexpr std::size_t MAX_SHAPING_REASON_BYTES = 1024U;
constexpr std::int32_t MAX_PROFILE_ABS_CELL = 1000000;
constexpr std::int32_t SOURCE_REGION_CELLS = 2048;
constexpr std::int32_t SOURCE_REGION_GUARD_CELLS = 1;
constexpr std::uint64_t MAX_V2_JSON_INTEGER = 9007199254740992ULL;

const char *const MATERIAL_NAMES[] = {
	"air", "grass", "dirt", "stone", "sand", "snow", "deepStone", "bedrock",
	"clay", "gravel", "coalOre", "ironOre", "crystalOre", "copperOre", "mud", "water", "lava",
};
const char *const BIOME_NAMES[] = {
	"plains", "forest", "swamp", "desert", "savanna", "snow", "taiga", "tundra",
	"ocean", "beach", "town", "underground", "deep_underground", "underground_air", "alpine",
};
const char *const FLUID_NAMES[] = {"", "water", "lava"};

std::string utf8(const String &p_value) {
	const CharString encoded = p_value.utf8();
	return std::string(encoded.get_data(), static_cast<std::size_t>(encoded.length()));
}

String text(const std::string &p_value) {
	return String::utf8(p_value.data(), static_cast<int64_t>(p_value.size()));
}

Vector3 world_vector(const WorldFloat32Position &p_value) {
	return Vector3(p_value.x, p_value.y, p_value.z);
}

Vector3 wildlife_vector(const NativeWildlifeVec3 &p_value) {
	return Vector3(p_value.x, p_value.y, p_value.z);
}

Dictionary ore_child_shadow(const NativeSurfaceOreChildDefinition &p_child) {
	Dictionary row;
	row["childIndex"] = static_cast<std::int64_t>(p_child.child_index);
	row["durableId"] = text(p_child.durable_id);
	row["present"] = p_child.present;
	row["stateBefore"] = text(std::to_string(p_child.state_before));
	row["stateAfter"] = text(std::to_string(p_child.state_after));
	row["dropCount"] = p_child.drop_count;
	row["localPosition"] = world_vector(p_child.local_position);
	row["worldAnchor"] = world_vector(p_child.world_anchor);
	row["rotationY"] = p_child.rotation_y;
	row["radius"] = p_child.radius;
	row["meshRadius"] = p_child.mesh_radius;
	row["meshHeight"] = p_child.mesh_height;
	row["meshRadialSegments"] = p_child.mesh_radial_segments;
	row["meshRings"] = p_child.mesh_rings;
	row["meshCenterY"] = p_child.mesh_center_y;
	row["meshScale"] = world_vector(p_child.mesh_scale);
	row["seamMeshSize"] = world_vector(p_child.seam_mesh_size);
	Array seams;
	for (const NativeSurfaceOreSeamDefinition &seam : p_child.seams) {
		Dictionary entry;
		entry["localPosition"] = world_vector(seam.local_position);
		entry["rotation"] = world_vector(seam.rotation);
		seams.append(entry);
	}
	row["seams"] = seams;
	row["glintMeshRadius"] = p_child.glint_mesh_radius;
	row["glintMeshHeight"] = p_child.glint_mesh_height;
	row["glintRadialSegments"] = p_child.glint_radial_segments;
	row["glintRings"] = p_child.glint_rings;
	Array glints;
	for (const NativeSurfaceOreGlintDefinition &glint : p_child.glints) {
		Dictionary entry;
		entry["localPosition"] = world_vector(glint.local_position);
		entry["scale"] = world_vector(glint.scale);
		glints.append(entry);
	}
	row["glints"] = glints;
	row["colliderRadius"] = p_child.collider_radius;
	row["colliderCenterY"] = p_child.collider_center_y;
	return row;
}

Dictionary envelope(const char *p_operation, const char *p_status, const String &p_reason = String()) {
	Dictionary result;
	result["schema"] = ADAPTER_SCHEMA;
	result["operation"] = p_operation;
	result["status"] = p_status;
	result["reason"] = p_reason;
	result["productionCutover"] = false;
	result["shadowOnly"] = true;
	return result;
}

Dictionary failure(const char *p_operation, const std::exception &p_error) {
	return envelope(p_operation, "failed", text(p_error.what()));
}

Dictionary require_dictionary(const Variant &p_value, const char *p_field) {
	if (p_value.get_type() != Variant::DICTIONARY) {
		throw std::invalid_argument(std::string(p_field) + " must be a Dictionary");
	}
	return Dictionary(p_value);
}

void require_exact_keys(const Dictionary &p_value, const std::initializer_list<const char *> p_keys,
		const char *p_field) {
	if (p_value.size() != static_cast<int64_t>(p_keys.size())) {
		throw std::invalid_argument(std::string(p_field) + " has an unsupported field set");
	}
	for (const char *key : p_keys) {
		if (!p_value.has(key)) {
			throw std::invalid_argument(std::string(p_field) + " has an unsupported field set");
		}
	}
}

Array require_array(const Variant &p_value, const char *p_field) {
	if (p_value.get_type() != Variant::ARRAY) {
		throw std::invalid_argument(std::string(p_field) + " must be an Array");
	}
	return Array(p_value);
}

String require_string(const Variant &p_value, const char *p_field) {
	if (p_value.get_type() != Variant::STRING) {
		throw std::invalid_argument(std::string(p_field) + " must be a String");
	}
	return String(p_value);
}

std::string bounded_utf8(const String &p_value, const std::size_t p_maximum_bytes,
		const char *p_field, const bool p_allow_empty = true) {
	// UTF-8 has at most four bytes per Godot String code point. Reject the
	// obviously oversized case before asking Godot to materialize an encoding,
	// then enforce the authoritative byte limit before copying into std::string.
	if (p_value.length() > static_cast<int64_t>(p_maximum_bytes)) {
		throw std::length_error(std::string(p_field) + " exceeds adapter text limit");
	}
	const CharString encoded = p_value.utf8();
	const std::size_t bytes = static_cast<std::size_t>(encoded.length());
	if (bytes > p_maximum_bytes) {
		throw std::length_error(std::string(p_field) + " exceeds adapter text limit");
	}
	if (!p_allow_empty && bytes == 0U) {
		throw std::invalid_argument(std::string(p_field) + " must not be empty");
	}
	return std::string(encoded.get_data(), bytes);
}

std::string require_bounded_utf8(const Variant &p_value, const char *p_field,
		const std::size_t p_maximum_bytes, const bool p_allow_empty = true) {
	return bounded_utf8(require_string(p_value, p_field), p_maximum_bytes, p_field, p_allow_empty);
}

String require_protocol_string(const Variant &p_value, const char *p_field) {
	const String value = require_string(p_value, p_field);
	static_cast<void>(bounded_utf8(value, MAX_PROTOCOL_TEXT_BYTES, p_field));
	return value;
}

std::int64_t require_i64(const Variant &p_value, const char *p_field) {
	if (p_value.get_type() != Variant::INT) {
		throw std::invalid_argument(std::string(p_field) + " must be an integer");
	}
	return static_cast<std::int64_t>(p_value);
}

std::int32_t require_i32(const Variant &p_value, const char *p_field) {
	const std::int64_t value = require_i64(p_value, p_field);
	if (value < std::numeric_limits<std::int32_t>::min() || value > std::numeric_limits<std::int32_t>::max()) {
		throw std::out_of_range(std::string(p_field) + " exceeds int32");
	}
	return static_cast<std::int32_t>(value);
}

std::uint32_t require_u32(const Variant &p_value, const char *p_field) {
	const std::int64_t value = require_i64(p_value, p_field);
	if (value <= 0 || value > std::numeric_limits<std::uint32_t>::max()) {
		throw std::out_of_range(std::string(p_field) + " must be a positive uint32");
	}
	return static_cast<std::uint32_t>(value);
}

double require_number(const Variant &p_value, const char *p_field) {
	if (p_value.get_type() != Variant::FLOAT && p_value.get_type() != Variant::INT) {
		throw std::invalid_argument(std::string(p_field) + " must be numeric");
	}
	const double value = static_cast<double>(p_value);
	if (!std::isfinite(value)) {
		throw std::invalid_argument(std::string(p_field) + " must be finite");
	}
	return value;
}

bool require_bool(const Variant &p_value, const char *p_field) {
	if (p_value.get_type() != Variant::BOOL) {
		throw std::invalid_argument(std::string(p_field) + " must be a bool");
	}
	return static_cast<bool>(p_value);
}

template <typename T> std::string numeric_bytes_hex(T value) {
	std::uint8_t bytes[sizeof(T)];
	std::memcpy(bytes, &value, sizeof(T));
	static constexpr char digits[] = "0123456789abcdef";
	std::string result;
	result.reserve(sizeof(T) * 2U);
	for (std::uint8_t byte : bytes) {
		result.push_back(digits[byte >> 4U]);
		result.push_back(digits[byte & 15U]);
	}
	return result;
}

double require_snapshot_numeric(const Variant &value, const char *field, bool packed_float32) {
	const Dictionary record = require_dictionary(value, field);
	require_exact_keys(record, {"value", "float32BytesHex", "float64BytesHex"}, field);
	if (record["value"].get_type() != Variant::FLOAT) {
		throw std::invalid_argument(std::string(field) + ".value must be float64");
	}
	const double number = require_number(record["value"], field);
	const float narrowed = static_cast<float>(number);
	if (!std::isfinite(narrowed) || (packed_float32 && static_cast<double>(narrowed) != number)
			|| require_bounded_utf8(record["float32BytesHex"], field, 8U, false) != numeric_bytes_hex(narrowed)
			|| require_bounded_utf8(record["float64BytesHex"], field, 16U, false) != numeric_bytes_hex(number)) {
		throw std::invalid_argument(std::string(field) + " numeric bit semantics mismatch");
	}
	return number;
}

std::vector<std::string> require_snapshot_strings(const Variant &value, const char *field) {
	const Array array = require_array(value, field);
	if (array.size() > 64) throw std::length_error(std::string(field) + " exceeds capacity");
	std::vector<std::string> result;
	result.reserve(static_cast<std::size_t>(array.size()));
	for (const Variant &entry : array) result.push_back(require_bounded_utf8(entry, field, 1024U));
	return result;
}

std::vector<float> require_snapshot_floats(const Variant &value, const char *field) {
	const Array array = require_array(value, field);
	if (array.size() > 64) throw std::length_error(std::string(field) + " exceeds capacity");
	std::vector<float> result;
	result.reserve(static_cast<std::size_t>(array.size()));
	for (const Variant &entry : array) result.push_back(static_cast<float>(require_snapshot_numeric(entry, field, true)));
	return result;
}

std::uint64_t require_u64(const Variant &p_value, const char *p_field) {
	const std::int64_t value = require_i64(p_value, p_field);
	if (value < 0) throw std::out_of_range(std::string(p_field) + " must be nonnegative");
	return static_cast<std::uint64_t>(value);
}

std::int64_t require_save_i64(const Variant &p_value, const char *p_field) {
	if (p_value.get_type() == Variant::INT) {
		const std::int64_t value = static_cast<std::int64_t>(p_value);
		if (value < -static_cast<std::int64_t>(MAX_V2_JSON_INTEGER)
				|| value > static_cast<std::int64_t>(MAX_V2_JSON_INTEGER)) {
			throw std::out_of_range(std::string(p_field) + " exceeds exact JSON integer range");
		}
		return value;
	}
	if (p_value.get_type() != Variant::FLOAT) {
		throw std::invalid_argument(std::string(p_field) + " must be an integer or exact whole-number float");
	}
	const double value = static_cast<double>(p_value);
	if (!std::isfinite(value) || std::floor(value) != value
			|| value < -static_cast<double>(MAX_V2_JSON_INTEGER)
			|| value > static_cast<double>(MAX_V2_JSON_INTEGER)) {
		throw std::out_of_range(std::string(p_field) + " is not an exact JSON integer");
	}
	return static_cast<std::int64_t>(value);
}

std::uint64_t require_save_u64(const Variant &p_value, const char *p_field) {
	const std::int64_t value = require_save_i64(p_value, p_field);
	if (value < 0) throw std::out_of_range(std::string(p_field) + " must be nonnegative");
	return static_cast<std::uint64_t>(value);
}

std::int32_t require_save_i32(const Variant &p_value, const char *p_field) {
	const std::int64_t value = require_save_i64(p_value, p_field);
	if (value < std::numeric_limits<std::int32_t>::min()
			|| value > std::numeric_limits<std::int32_t>::max()) {
		throw std::out_of_range(std::string(p_field) + " exceeds int32");
	}
	return static_cast<std::int32_t>(value);
}

Vector2i require_vector2i(const Variant &p_value, const char *p_field) {
	if (p_value.get_type() != Variant::VECTOR2I) {
		throw std::invalid_argument(std::string(p_field) + " must be a Vector2i");
	}
	return Vector2i(p_value);
}

Vector3i require_vector3i(const Variant &p_value, const char *p_field) {
	if (p_value.get_type() != Variant::VECTOR3I) {
		throw std::invalid_argument(std::string(p_field) + " must be a Vector3i");
	}
	return Vector3i(p_value);
}

Vector3 require_vector3(const Variant &p_value, const char *p_field) {
	if (p_value.get_type() != Variant::VECTOR3) {
		throw std::invalid_argument(std::string(p_field) + " must be a Vector3");
	}
	const Vector3 value = Vector3(p_value);
	if (!value.is_finite()) throw std::invalid_argument(std::string(p_field) + " must be finite");
	return value;
}

NativeHorizontalRect require_profile_rect(const Variant &p_value, const char *p_field) {
	if (p_value.get_type() != Variant::RECT2I) {
		throw std::invalid_argument(std::string(p_field) + " must be a Rect2i");
	}
	const Rect2i value = Rect2i(p_value);
	const std::int64_t end_x = static_cast<std::int64_t>(value.position.x) + value.size.x;
	const std::int64_t end_z = static_cast<std::int64_t>(value.position.y) + value.size.y;
	if (value.size.x <= 0 || value.size.y <= 0
			|| std::abs(static_cast<std::int64_t>(value.position.x)) > MAX_PROFILE_ABS_CELL
			|| std::abs(static_cast<std::int64_t>(value.position.y)) > MAX_PROFILE_ABS_CELL
			|| end_x > MAX_PROFILE_ABS_CELL || end_z > MAX_PROFILE_ABS_CELL) {
		throw std::out_of_range(std::string(p_field) + " exceeds the bounded profile rectangle domain");
	}
	return {value.position.x, value.position.y, value.size.x, value.size.y};
}

bool rect_encloses(const NativeHorizontalRect &p_outer, const NativeHorizontalRect &p_inner) {
	return static_cast<std::int64_t>(p_inner.x) >= p_outer.x
		&& static_cast<std::int64_t>(p_inner.z) >= p_outer.z
		&& static_cast<std::int64_t>(p_inner.x) + p_inner.width
			<= static_cast<std::int64_t>(p_outer.x) + p_outer.width
		&& static_cast<std::int64_t>(p_inner.z) + p_inner.depth
			<= static_cast<std::int64_t>(p_outer.z) + p_outer.depth;
}

bool reservation_fits_source_region(const NativeSiteSourceRegionKey p_region,
		const NativeHorizontalRect &p_reservation) {
	const std::int64_t allowed_x = static_cast<std::int64_t>(p_region.x) * SOURCE_REGION_CELLS
		+ SOURCE_REGION_GUARD_CELLS;
	const std::int64_t allowed_z = static_cast<std::int64_t>(p_region.z) * SOURCE_REGION_CELLS
		+ SOURCE_REGION_GUARD_CELLS;
	const std::int64_t allowed_size = SOURCE_REGION_CELLS - SOURCE_REGION_GUARD_CELLS * 2LL;
	return static_cast<std::int64_t>(p_reservation.x) >= allowed_x
		&& static_cast<std::int64_t>(p_reservation.z) >= allowed_z
		&& static_cast<std::int64_t>(p_reservation.x) + p_reservation.width <= allowed_x + allowed_size
		&& static_cast<std::int64_t>(p_reservation.z) + p_reservation.depth <= allowed_z + allowed_size;
}

void verify_worker_candidate(const Dictionary &p_value, const NativeSiteSourceCandidate &p_expected,
		const WorldSourceDefinition &p_definition) {
	// CitadelTerrainAdmission compares the complete frozen candidate Dictionary,
	// not a worker-selected subset. Preserve that exact boundary contract.
	if (p_value.size() != 7) throw std::invalid_argument("resolution candidate does not match native authority");
	const String worker_seed = require_string(p_value.get("worldSeed", Variant()), "resolution.candidate.worldSeed");
	if (static_cast<std::size_t>(worker_seed.length()) > MAX_SEED_CODE_POINTS) {
		throw std::length_error("resolution.candidate.worldSeed exceeds adapter code point limit");
	}
	const std::string worker_seed_utf8 = bounded_utf8(
		worker_seed, MAX_SEED_TEXT_BYTES, "resolution.candidate.worldSeed", false);
	if (require_i32(p_value.get("version", Variant()), "resolution.candidate.version") != 1
			|| require_bounded_utf8(p_value.get("siteId", Variant()), "resolution.candidate.siteId",
				NativeTerrainShapingSnapshot::MAX_SITE_ID_BYTES, false) != p_expected.site_id
			|| worker_seed_utf8 != p_definition.raw_terrain_seed().utf8
			|| require_vector2i(p_value.get("region", Variant()), "resolution.candidate.region")
				!= Vector2i(p_expected.region.x, p_expected.region.z)
			|| require_vector2i(p_value.get("centerCell", Variant()), "resolution.candidate.centerCell")
				!= Vector2i(p_expected.center_x, p_expected.center_z)
			|| require_i64(p_value.get("recipeSeed", Variant()), "resolution.candidate.recipeSeed")
				!= static_cast<std::int64_t>(p_expected.recipe_seed)
			|| !require_bool(p_value.get("surfaceOnly", Variant()), "resolution.candidate.surfaceOnly")) {
		throw std::invalid_argument("resolution candidate does not match native authority");
	}
}

NativeSiteTerrainProfile parse_site_profile(const Dictionary &p_value,
		const NativeSiteSourceCandidate &p_candidate, const WorldSourceDefinition &p_definition) {
	NativeSiteTerrainProfile profile;
	profile.version = require_i32(p_value.get("version", Variant()), "resolution.profile.version");
	const String seed = require_string(p_value.get("worldSeed", Variant()), "resolution.profile.worldSeed");
	if (static_cast<std::size_t>(seed.length()) > MAX_SEED_CODE_POINTS) {
		throw std::length_error("resolution.profile.worldSeed exceeds adapter code point limit");
	}
	profile.world_seed_utf8 = bounded_utf8(seed, MAX_SEED_TEXT_BYTES, "resolution.profile.worldSeed", false);
	if (profile.world_seed_utf8 != p_definition.raw_terrain_seed().utf8) {
		throw std::invalid_argument("resolution profile world seed does not match native authority");
	}
	profile.site_id = require_bounded_utf8(p_value.get("siteId", Variant()), "resolution.profile.siteId",
		NativeTerrainShapingSnapshot::MAX_SITE_ID_BYTES, false);
	if (profile.site_id != p_candidate.site_id) {
		throw std::invalid_argument("resolution profile site ID does not match native candidate");
	}
	profile.source_signature = require_bounded_utf8(p_value.get("sourceSignature", Variant()),
		"resolution.profile.sourceSignature", NativeTerrainShapingSnapshot::MAX_SOURCE_SIGNATURE_BYTES, false);
	profile.cell_size_meters = require_number(p_value.get("cellSize", Variant()), "resolution.profile.cellSize");
	profile.core_cells = require_profile_rect(p_value.get("coreCells", Variant()), "resolution.profile.coreCells");
	profile.envelope_cells = require_profile_rect(p_value.get("envelopeCells", Variant()), "resolution.profile.envelopeCells");
	profile.reservation_cells = require_profile_rect(p_value.get("reservationCells", Variant()), "resolution.profile.reservationCells");
	const Vector3 origin = require_vector3(p_value.get("origin", Variant()), "resolution.profile.origin");
	profile.origin = {static_cast<float>(origin.x), static_cast<float>(origin.y), static_cast<float>(origin.z)};
	if (!std::isfinite(profile.origin.x) || !std::isfinite(profile.origin.y) || !std::isfinite(profile.origin.z)) {
		throw std::out_of_range("resolution.profile.origin exceeds float32");
	}
	profile.level_meters = require_number(p_value.get("level", Variant()), "resolution.profile.level");
	profile.apron_cells = require_i32(p_value.get("apronCells", Variant()), "resolution.profile.apronCells");

	const std::uint64_t sample_count = static_cast<std::uint64_t>(profile.envelope_cells.width)
		* static_cast<std::uint64_t>(profile.envelope_cells.depth);
	if (sample_count > NativeTerrainShapingSnapshot::MAX_SITE_SAMPLES) {
		throw std::length_error("resolution profile exceeds sample limit");
	}
	const Array support = require_array(p_value.get("supportMask", Variant()), "resolution.profile.supportMask");
	const Array distances = require_array(p_value.get("distanceCells", Variant()), "resolution.profile.distanceCells");
	if (static_cast<std::size_t>(support.size()) > NativeTerrainShapingSnapshot::MAX_SITE_SAMPLES) {
		throw std::length_error("resolution.profile.supportMask exceeds sample limit");
	}
	if (static_cast<std::size_t>(distances.size()) > NativeTerrainShapingSnapshot::MAX_SITE_SAMPLES) {
		throw std::length_error("resolution.profile.distanceCells exceeds sample limit");
	}
	if (static_cast<std::uint64_t>(support.size()) != sample_count
			|| static_cast<std::uint64_t>(distances.size()) != sample_count) {
		throw std::invalid_argument("resolution profile sample arrays do not match envelope");
	}
	profile.support_mask.reserve(static_cast<std::size_t>(sample_count));
	profile.distance_cells.reserve(static_cast<std::size_t>(sample_count));
	for (int64_t index = 0; index < support.size(); ++index) {
		if (support[index].get_type() != Variant::INT) {
			throw std::invalid_argument("resolution.profile.supportMask values must be integers");
		}
		const std::int64_t value = static_cast<std::int64_t>(support[index]);
		if (value < 0 || value > 1) {
			throw std::out_of_range("resolution.profile.supportMask values must be 0 or 1");
		}
		profile.support_mask.push_back(static_cast<std::uint8_t>(value));
		if (distances[index].get_type() != Variant::FLOAT) {
			throw std::invalid_argument("resolution.profile.distanceCells values must be floats");
		}
		const double distance = require_number(distances[index], "resolution.profile.distanceCells[]");
		const float stored_distance = static_cast<float>(distance);
		if (!std::isfinite(stored_distance) || stored_distance < 0.0F
				|| (value == 1 && stored_distance != 0.0F)) {
			throw std::out_of_range("resolution.profile.distanceCells value violates terrain profile semantics");
		}
		profile.distance_cells.push_back(stored_distance);
	}

	const Array roots = require_array(p_value.get("groundRootPoints", Variant()), "resolution.profile.groundRootPoints");
	if (static_cast<std::size_t>(roots.size()) > NativeTerrainShapingSnapshot::MAX_GROUND_ROOT_POINTS) {
		throw std::length_error("resolution.profile.groundRootPoints exceeds root point limit");
	}
	profile.ground_root_points.reserve(static_cast<std::size_t>(roots.size()));
	for (int64_t index = 0; index < roots.size(); ++index) {
		const Vector3 point = require_vector3(roots[index], "resolution.profile.groundRootPoints[]");
		const WorldFloat32Position stored{static_cast<float>(point.x), static_cast<float>(point.y), static_cast<float>(point.z)};
		if (!std::isfinite(stored.x) || !std::isfinite(stored.y) || !std::isfinite(stored.z)) {
			throw std::out_of_range("resolution.profile.groundRootPoints value exceeds float32");
		}
		profile.ground_root_points.push_back(stored);
	}
	return profile;
}

CellCoord cell_coord(const Vector3i &p_value) {
	return {p_value.x, p_value.y, p_value.z};
}

Vector3i vector3i(const CellCoord p_value) {
	return Vector3i(p_value.x, p_value.y, p_value.z);
}

Dictionary identity_dictionary(const WorldPhysicalContentIdentity &p_identity) {
	Dictionary result;
	result["algorithm"] = "sha256";
	result["hex"] = text(p_identity.digest_hex());
	return result;
}

WorldQueryIntent parse_intent(const Variant &p_value, const char *p_field) {
	const String value = require_protocol_string(p_value, p_field);
	if (value == "terrain_mesh") return WorldQueryIntent::terrain_mesh;
	if (value == "terrain_collision") return WorldQueryIntent::terrain_collision;
	if (value == "gameplay") return WorldQueryIntent::gameplay;
	throw std::invalid_argument(std::string(p_field) + " is not a supported intent");
}

const char *intent_name(const WorldQueryIntent p_intent) {
	switch (p_intent) {
	case WorldQueryIntent::terrain_mesh: return "terrain_mesh";
	case WorldQueryIntent::terrain_collision: return "terrain_collision";
	case WorldQueryIntent::gameplay: return "gameplay";
	}
	return "invalid";
}

Variant native_value_variant(const NativeValue &p_value) {
	switch (p_value.kind()) {
	case NativeValueKind::null_value:
		return Variant();
	case NativeValueKind::boolean:
		return p_value.as_boolean();
	case NativeValueKind::number:
		return p_value.as_number();
	case NativeValueKind::string:
		return text(p_value.as_string());
	case NativeValueKind::array: {
		Array values;
		for (const NativeValue &value : p_value.as_array()) values.append(native_value_variant(value));
		return values;
	}
	case NativeValueKind::object: {
		Dictionary values;
		for (const auto &entry : p_value.as_object()) values[text(entry.first)] = native_value_variant(entry.second);
		return values;
	}
	}
	throw std::invalid_argument("native value kind is invalid");
}

struct NativeValueParseBudget {
	std::size_t nodes = 0U;
};

NativeValue parse_native_value_bounded(const Variant &p_value, const char *p_field,
		const std::size_t p_depth, NativeValueParseBudget &p_budget) {
	if (p_depth > NativeValueLimits::MAX_DEPTH) {
		throw std::length_error(std::string(p_field) + " exceeds metadata depth limit");
	}
	if (++p_budget.nodes > NativeValueLimits::MAX_NODES) {
		throw std::length_error(std::string(p_field) + " exceeds metadata node limit");
	}
	switch (p_value.get_type()) {
	case Variant::NIL:
		return NativeValue::null();
	case Variant::BOOL:
		return NativeValue::boolean(static_cast<bool>(p_value));
	case Variant::INT:
	{
		const std::int64_t integer = static_cast<std::int64_t>(p_value);
		if (integer < -9007199254740992LL || integer > 9007199254740992LL) {
			throw std::out_of_range(std::string(p_field) + " integer is not exactly representable by NativeValue");
		}
		return NativeValue::number(static_cast<double>(integer));
	}
	case Variant::FLOAT:
		return NativeValue::number(require_number(p_value, p_field));
	case Variant::STRING:
		return NativeValue::string(bounded_utf8(String(p_value), NativeValueLimits::MAX_STRING_BYTES, p_field));
	case Variant::ARRAY: {
		const Array values = Array(p_value);
		if (static_cast<std::size_t>(values.size()) > NativeValueLimits::MAX_CONTAINER_ENTRIES) {
			throw std::length_error(std::string(p_field) + " exceeds metadata container limit");
		}
		NativeValue::Array result;
		result.reserve(static_cast<std::size_t>(values.size()));
		for (int64_t index = 0; index < values.size(); ++index) {
			result.push_back(parse_native_value_bounded(values[index], p_field, p_depth + 1U, p_budget));
		}
		return NativeValue::array(std::move(result));
	}
	case Variant::DICTIONARY: {
		const Dictionary values = Dictionary(p_value);
		if (static_cast<std::size_t>(values.size()) > NativeValueLimits::MAX_CONTAINER_ENTRIES) {
			throw std::length_error(std::string(p_field) + " exceeds metadata container limit");
		}
		const Array keys = values.keys();
		NativeValue::Object result;
		result.reserve(static_cast<std::size_t>(keys.size()));
		for (int64_t index = 0; index < keys.size(); ++index) {
			if (keys[index].get_type() != Variant::STRING) {
				throw std::invalid_argument(std::string(p_field) + " object keys must be strings");
			}
			const std::string key = bounded_utf8(String(keys[index]), NativeValueLimits::MAX_OBJECT_KEY_BYTES, p_field);
			result.push_back({key, parse_native_value_bounded(values[keys[index]], p_field, p_depth + 1U, p_budget)});
		}
		std::sort(result.begin(), result.end(), [](const auto &p_left, const auto &p_right) {
			return std::lexicographical_compare(p_left.first.begin(), p_left.first.end(),
				p_right.first.begin(), p_right.first.end(), [](const char p_left_byte, const char p_right_byte) {
					return static_cast<std::uint8_t>(static_cast<unsigned char>(p_left_byte))
						< static_cast<std::uint8_t>(static_cast<unsigned char>(p_right_byte));
				});
		});
		return NativeValue::object(std::move(result));
	}
	default:
		throw std::invalid_argument(std::string(p_field) + " contains a non-value Variant");
	}
}

NativeValue parse_native_value(const Variant &p_value, const char *p_field) {
	NativeValueParseBudget budget;
	return parse_native_value_bounded(p_value, p_field, 0U, budget);
}

template <typename T>
T checked_enum_id(const Variant &p_value, const std::int64_t p_maximum, const char *p_field) {
	const std::int64_t value = require_i64(p_value, p_field);
	if (value < 0 || value > p_maximum) throw std::out_of_range(std::string(p_field) + " is outside the native ID domain");
	return static_cast<T>(value);
}

NativeCellState parse_cell_state(const Dictionary &p_value, const CellCoord p_cell,
		const NativeCellStateNamespace p_namespace) {
	NativeCellStateInput input;
	input.cell = p_cell;
	input.material = checked_enum_id<TerrainMaterialId>(p_value.get("materialId", Variant()),
		static_cast<std::int64_t>(TerrainMaterialId::lava), "state.materialId");
	input.biome = checked_enum_id<TerrainBiomeId>(p_value.get("biomeId", Variant()),
		static_cast<std::int64_t>(TerrainBiomeId::alpine), "state.biomeId");
	input.solid = require_bool(p_value.get("solid", Variant()), "state.solid");
	input.density = require_number(p_value.get("density", Variant()), "state.density");
	input.fluid = checked_enum_id<TerrainFluidId>(p_value.get("fluidId", Variant()),
		static_cast<std::int64_t>(TerrainFluidId::lava), "state.fluidId");
	const Vector2i light = require_vector2i(p_value.get("light", Variant()), "state.light");
	if (light.x < 0 || light.x > 15 || light.y < 0 || light.y > 15) {
		throw std::out_of_range("state.light channels must be in [0, 15]");
	}
	input.light = {static_cast<std::uint8_t>(light.x), static_cast<std::uint8_t>(light.y)};
	input.metadata = parse_native_value(p_value.get("metadata", Variant()), "state.metadata");
	const Variant block = p_value.get("blockId", Variant());
	if (block.get_type() == Variant::STRING) input.block_id = NativeBlockIdentity::create(
		bounded_utf8(String(block), MAX_BLOCK_ID_BYTES, "state.blockId", false));
	else if (block.get_type() != Variant::NIL) throw std::invalid_argument("state.blockId must be null or String");
	input.edit_reason = require_bounded_utf8(p_value.get("editReason", Variant()), "state.editReason", MAX_EDIT_REASON_BYTES);
	input.generated = false;
	input.edited = true;
	return make_native_cell_state(input, p_namespace);
}

Dictionary state_dictionary(const NativeCellState &p_state) {
	Dictionary result;
	result["cell"] = vector3i(p_state.cell);
	result["section"] = vector3i(p_state.section);
	result["localCell"] = vector3i(p_state.local_cell);
	result["materialId"] = static_cast<int64_t>(p_state.material);
	result["material"] = MATERIAL_NAMES[static_cast<std::uint8_t>(p_state.material)];
	result["biomeId"] = static_cast<int64_t>(p_state.biome);
	result["biome"] = BIOME_NAMES[static_cast<std::uint8_t>(p_state.biome)];
	result["solid"] = p_state.solid;
	result["density"] = p_state.density;
	result["fluidId"] = static_cast<int64_t>(p_state.fluid);
	result["fluid"] = FLUID_NAMES[static_cast<std::uint8_t>(p_state.fluid)];
	result["light"] = Vector2i(p_state.light.sky, p_state.light.block);
	result["metadata"] = native_value_variant(p_state.metadata);
	result["blockId"] = p_state.block_id ? Variant(text(p_state.block_id->value())) : Variant();
	result["editReason"] = p_state.edit_reason ? Variant(text(*p_state.edit_reason)) : Variant();
	result["generated"] = p_state.generated;
	result["edited"] = p_state.edited;
	return result;
}

bool save_coordinate_less(const CellCoord &p_left, const CellCoord &p_right) {
	if (p_left.z != p_right.z) return p_left.z < p_right.z;
	if (p_left.y != p_right.y) return p_left.y < p_right.y;
	return p_left.x < p_right.x;
}

Array save_coordinate_array(const CellCoord p_value) {
	Array result;
	result.append(static_cast<int64_t>(p_value.x));
	result.append(static_cast<int64_t>(p_value.y));
	result.append(static_cast<int64_t>(p_value.z));
	return result;
}

CellCoord parse_save_coordinate(const Variant &p_value, const char *p_field) {
	const Array values = require_array(p_value, p_field);
	if (values.size() != 3) {
		throw std::invalid_argument(std::string(p_field) + " must contain exactly three coordinates");
	}
	return {
		require_save_i32(values[0], p_field),
		require_save_i32(values[1], p_field),
		require_save_i32(values[2], p_field),
	};
}

TerrainMaterialId save_material(const Variant &p_value) {
	const std::string value = require_bounded_utf8(p_value, "terrainVolume.state.material", 32U, false);
	for (std::size_t index = 0U; index < std::size(MATERIAL_NAMES); ++index) {
		if (value == MATERIAL_NAMES[index]) return static_cast<TerrainMaterialId>(index);
	}
	throw std::invalid_argument("terrainVolume state material is unsupported");
}

TerrainBiomeId save_biome(const Variant &p_value) {
	const std::string value = require_bounded_utf8(p_value, "terrainVolume.state.biome", 32U, false);
	for (std::size_t index = 0U; index < std::size(BIOME_NAMES); ++index) {
		if (value == BIOME_NAMES[index]) return static_cast<TerrainBiomeId>(index);
	}
	throw std::invalid_argument("terrainVolume state biome is unsupported");
}

TerrainFluidId save_fluid(const Variant &p_value) {
	const std::string value = require_bounded_utf8(p_value, "terrainVolume.state.fluid", 16U);
	for (std::size_t index = 0U; index < std::size(FLUID_NAMES); ++index) {
		if (value == FLUID_NAMES[index]) return static_cast<TerrainFluidId>(index);
	}
	throw std::invalid_argument("terrainVolume state fluid is unsupported");
}

NativeCellState parse_save_state(const Dictionary &p_value, const CellCoord p_cell,
		const CellCoord p_section, const CellCoord p_local) {
	require_exact_keys(p_value, {"cell", "sectionKey", "localCell", "blockId", "material", "biome",
		"solid", "density", "fluid", "light", "metadata", "editReason", "generated", "edited"},
		"terrainVolume.state");
	if (!(parse_save_coordinate(p_value.get("cell", Variant()), "terrainVolume.state.cell") == p_cell)
			|| !(parse_save_coordinate(p_value.get("sectionKey", Variant()), "terrainVolume.state.sectionKey") == p_section)
			|| !(parse_save_coordinate(p_value.get("localCell", Variant()), "terrainVolume.state.localCell") == p_local)) {
		throw std::invalid_argument("terrainVolume state redundant coordinates do not match");
	}
	const Dictionary light = require_dictionary(p_value.get("light", Variant()), "terrainVolume.state.light");
	require_exact_keys(light, {"sky", "block"}, "terrainVolume.state.light");
	const std::int64_t sky = require_save_i64(light.get("sky", Variant()), "terrainVolume.state.light.sky");
	const std::int64_t block_light = require_save_i64(light.get("block", Variant()), "terrainVolume.state.light.block");
	if (sky < 0 || sky > 15 || block_light < 0 || block_light > 15) {
		throw std::out_of_range("terrainVolume state light channel exceeds [0, 15]");
	}
	const Dictionary metadata = require_dictionary(p_value.get("metadata", Variant()), "terrainVolume.state.metadata");
	if (metadata.has("saveDelta") && metadata.get("saveDelta", Variant()).get_type() == Variant::BOOL
			&& !static_cast<bool>(metadata.get("saveDelta", Variant()))) {
		throw std::invalid_argument("terrainVolume durable state explicitly disables saveDelta");
	}
	NativeCellStateInput input;
	input.cell = p_cell;
	input.block_id = NativeBlockIdentity::create(require_bounded_utf8(
		p_value.get("blockId", Variant()), "terrainVolume.state.blockId", MAX_BLOCK_ID_BYTES, false));
	input.material = save_material(p_value.get("material", Variant()));
	input.biome = save_biome(p_value.get("biome", Variant()));
	input.solid = require_bool(p_value.get("solid", Variant()), "terrainVolume.state.solid");
	input.density = require_number(p_value.get("density", Variant()), "terrainVolume.state.density");
	input.fluid = save_fluid(p_value.get("fluid", Variant()));
	input.light = {static_cast<std::uint8_t>(sky), static_cast<std::uint8_t>(block_light)};
	input.metadata = parse_native_value(metadata, "terrainVolume.state.metadata");
	input.edit_reason = require_bounded_utf8(
		p_value.get("editReason", Variant()), "terrainVolume.state.editReason", MAX_EDIT_REASON_BYTES);
	input.generated = require_bool(p_value.get("generated", Variant()), "terrainVolume.state.generated");
	input.edited = require_bool(p_value.get("edited", Variant()), "terrainVolume.state.edited");
	if (input.generated || !input.edited) {
		throw std::invalid_argument("terrainVolume may contain only durable edited states");
	}
	return make_native_cell_state(input, NativeCellStateNamespace::durable_terrain);
}

NativeTerrainVolumeV2 parse_terrain_volume_v2(const Variant &p_value) {
	const Dictionary root = require_dictionary(p_value, "terrainVolume");
	require_exact_keys(root, {"schemaVersion", "sectionSize", "revision", "sections"}, "terrainVolume");
	if (require_save_u64(root.get("schemaVersion", Variant()), "terrainVolume.schemaVersion") != 1U
			|| require_save_u64(root.get("sectionSize", Variant()), "terrainVolume.sectionSize") != 16U) {
		throw std::invalid_argument("unsupported terrainVolume v2 structure");
	}
	const Array sections = require_array(root.get("sections", Variant()), "terrainVolume.sections");
	if (static_cast<std::size_t>(sections.size()) > NativeTerrainVolumeV2Limits::DEFAULT_MAX_RECORDS) {
		throw std::length_error("terrainVolume section count exceeds durable record capacity");
	}

	// Preflight every container size before reserving or copying any save-owned
	// record. A nonempty section owns at least one record, so proving the summed
	// record count also proves section revisions cannot outnumber records.
	std::size_t record_count = 0U;
	for (int64_t section_index = 0; section_index < sections.size(); ++section_index) {
		const Dictionary section = require_dictionary(sections[section_index], "terrainVolume.sections[]");
		require_exact_keys(section, {"schemaVersion", "sectionKey", "originCell", "revision", "cells"},
			"terrainVolume.sections[]");
		const Array cells = require_array(section.get("cells", Variant()), "terrainVolume.sections[].cells");
		const std::size_t count = static_cast<std::size_t>(cells.size());
		if (count == 0U || count > NativeTerrainVolumeV2Limits::MAX_CELLS_PER_SECTION) {
			throw std::length_error("terrainVolume section cell count is outside current-v2 bounds");
		}
		if (record_count > NativeTerrainVolumeV2Limits::DEFAULT_MAX_RECORDS - count) {
			throw std::length_error("terrainVolume exceeds durable record capacity");
		}
		record_count += count;
	}
	if (static_cast<std::size_t>(sections.size()) > record_count) {
		throw std::length_error("terrainVolume section revisions exceed durable records");
	}

	std::vector<NativeTypedWorldStateRecord> records;
	std::vector<NativeTerrainVolumeV2SectionRevision> revisions;
	records.reserve(record_count);
	revisions.reserve(static_cast<std::size_t>(sections.size()));
	CellCoord previous_section{};
	bool has_previous_section = false;
	for (int64_t section_index = 0; section_index < sections.size(); ++section_index) {
		const Dictionary section = Dictionary(sections[section_index]);
		if (require_save_u64(section.get("schemaVersion", Variant()), "terrainVolume.sections[].schemaVersion") != 1U) {
			throw std::invalid_argument("unsupported terrainVolume section schema");
		}
		const CellCoord section_key = parse_save_coordinate(
			section.get("sectionKey", Variant()), "terrainVolume.sections[].sectionKey");
		const auto origin = section_origin(section_key, NativeCellState::SECTION_SIZE);
		if (!origin.has_value() || !(parse_save_coordinate(
			section.get("originCell", Variant()), "terrainVolume.sections[].originCell") == *origin)) {
			throw std::invalid_argument("terrainVolume section origin does not match sectionKey");
		}
		if (has_previous_section && !save_coordinate_less(previous_section, section_key)) {
			throw std::invalid_argument("terrainVolume sections are not in canonical order");
		}
		previous_section = section_key;
		has_previous_section = true;
		revisions.push_back({section_key,
			require_save_u64(section.get("revision", Variant()), "terrainVolume.sections[].revision")});

		const Array cells = Array(section.get("cells", Variant()));
		CellCoord previous_cell{};
		bool has_previous_cell = false;
		for (int64_t cell_index = 0; cell_index < cells.size(); ++cell_index) {
			const Dictionary cell_value = require_dictionary(cells[cell_index], "terrainVolume.sections[].cells[]");
			require_exact_keys(cell_value, {"cell", "local", "state"}, "terrainVolume.sections[].cells[]");
			const CellCoord cell = parse_save_coordinate(
				cell_value.get("cell", Variant()), "terrainVolume.sections[].cells[].cell");
			const CellCoord local = parse_save_coordinate(
				cell_value.get("local", Variant()), "terrainVolume.sections[].cells[].local");
			const auto split = split_cell(cell, NativeCellState::SECTION_SIZE);
			if (!split.has_value() || !(split->section == section_key) || !(split->local == local)) {
				throw std::invalid_argument("terrainVolume cell address does not match section/local decomposition");
			}
			if (has_previous_cell && !save_coordinate_less(previous_cell, cell)) {
				throw std::invalid_argument("terrainVolume cells are not in canonical order");
			}
			previous_cell = cell;
			has_previous_cell = true;
			records.push_back({NativeCellStateNamespace::durable_terrain,
				NativeTypedWorldStatePersistence::durable,
				parse_save_state(require_dictionary(cell_value.get("state", Variant()),
					"terrainVolume.sections[].cells[].state"), cell, section_key, local)});
		}
	}
	NativeTerrainVolumeV2 volume;
	volume.revision = require_save_u64(root.get("revision", Variant()), "terrainVolume.revision");
	volume.durable_snapshot = NativeTypedWorldStateSnapshot::create(std::move(records));
	volume.section_revisions = std::move(revisions);
	return validate_native_terrain_volume_v2(volume);
}

Dictionary save_state_dictionary(const NativeCellState &p_state) {
	Dictionary light;
	light["sky"] = static_cast<int64_t>(p_state.light.sky);
	light["block"] = static_cast<int64_t>(p_state.light.block);
	Dictionary result;
	result["cell"] = save_coordinate_array(p_state.cell);
	result["sectionKey"] = save_coordinate_array(p_state.section);
	result["localCell"] = save_coordinate_array(p_state.local_cell);
	result["blockId"] = text(p_state.block_id->value());
	result["material"] = MATERIAL_NAMES[static_cast<std::uint8_t>(p_state.material)];
	result["biome"] = BIOME_NAMES[static_cast<std::uint8_t>(p_state.biome)];
	result["solid"] = p_state.solid;
	result["density"] = p_state.density;
	result["fluid"] = FLUID_NAMES[static_cast<std::uint8_t>(p_state.fluid)];
	result["light"] = light;
	result["metadata"] = native_value_variant(p_state.metadata);
	result["editReason"] = text(*p_state.edit_reason);
	result["generated"] = false;
	result["edited"] = true;
	return result;
}

Dictionary terrain_volume_dictionary(const NativeTerrainVolumeV2 &p_volume) {
	Dictionary root;
	root["schemaVersion"] = static_cast<int64_t>(1);
	root["sectionSize"] = static_cast<int64_t>(NativeCellState::SECTION_SIZE);
	root["revision"] = static_cast<int64_t>(p_volume.revision);
	Array sections;
	const auto &records = p_volume.durable_snapshot.records();
	std::size_t record_index = 0U;
	for (const NativeTerrainVolumeV2SectionRevision &revision : p_volume.section_revisions) {
		Dictionary section;
		section["schemaVersion"] = static_cast<int64_t>(1);
		section["sectionKey"] = save_coordinate_array(revision.section);
		const auto origin = section_origin(revision.section, NativeCellState::SECTION_SIZE);
		if (!origin.has_value()) throw std::logic_error("admitted terrainVolume has invalid section origin");
		section["originCell"] = save_coordinate_array(*origin);
		section["revision"] = static_cast<int64_t>(revision.revision);
		Array cells;
		while (record_index < records.size() && records[record_index].state.section == revision.section) {
			const NativeCellState &state = records[record_index++].state;
			Dictionary cell;
			cell["cell"] = save_coordinate_array(state.cell);
			cell["local"] = save_coordinate_array(state.local_cell);
			cell["state"] = save_state_dictionary(state);
			cells.append(cell);
		}
		section["cells"] = cells;
		sections.append(section);
	}
	if (record_index != records.size()) throw std::logic_error("admitted terrainVolume records are not section-bijective");
	root["sections"] = sections;
	return root;
}

Dictionary numeric_dictionary(const NativeEffectiveNumericFacts &p_facts) {
	Dictionary result;
	result["requestedCell"] = vector3i(p_facts.requested_cell);
	result["sourceCell"] = vector3i(p_facts.source_cell);
	result["density"] = p_facts.density;
	result["undergroundAirVoid"] = p_facts.underground_air_void;
	result["surfaceY"] = p_facts.surface_y;
	result["materialId"] = static_cast<int64_t>(p_facts.material);
	result["material"] = MATERIAL_NAMES[static_cast<std::uint8_t>(p_facts.material)];
	result["generated"] = p_facts.generated;
	result["edited"] = p_facts.edited;
	return result;
}

Dictionary query_dictionary(const Vector3i &p_coordinate, const WorldQueryIntent p_intent) {
	Dictionary result;
	result["coordinate"] = p_coordinate;
	result["intent"] = intent_name(p_intent);
	return result;
}

Dictionary query_dictionary(const Vector2i &p_coordinate, const WorldQueryIntent p_intent) {
	Dictionary result;
	result["coordinate"] = p_coordinate;
	result["intent"] = intent_name(p_intent);
	return result;
}

WorldSourceDescriptor parse_source_descriptor(const Dictionary &p_request, const char *p_expected_schema) {
	if (require_protocol_string(p_request.get("schema", Variant()), "schema") != p_expected_schema) {
		throw std::invalid_argument("unsupported native world backend initialization schema");
	}
	const String seed_text = require_string(p_request.get("seedText", Variant()), "seedText");
	if (static_cast<std::size_t>(seed_text.length()) > MAX_SEED_CODE_POINTS) {
		throw std::length_error("seedText exceeds adapter code point limit");
	}
	const std::string seed = bounded_utf8(seed_text, MAX_SEED_TEXT_BYTES, "seedText");
	WorldSourceDescriptor descriptor;
	descriptor.raw_terrain_seed = admit_raw_terrain_seed(seed);
	descriptor.admitted_biome_seed = BiomeRegionField::admit_utf8_seed(seed);
	const Dictionary revisions = require_dictionary(p_request.get("revisions", Variant()), "revisions");
	descriptor.revisions.source_schema_revision = require_u32(revisions.get("sourceSchema", Variant()), "revisions.sourceSchema");
	descriptor.revisions.terrain_generator_revision = require_u32(revisions.get("terrainGenerator", Variant()), "revisions.terrainGenerator");
	descriptor.revisions.biome_region_field_revision = require_u32(revisions.get("biomeRegionField", Variant()), "revisions.biomeRegionField");
	descriptor.revisions.lattice_query_revision = require_u32(revisions.get("latticeQuery", Variant()), "revisions.latticeQuery");
	descriptor.revisions.cell_center_query_revision = require_u32(revisions.get("cellCenterQuery", Variant()), "revisions.cellCenterQuery");
	descriptor.revisions.surface_column_query_revision = require_u32(revisions.get("surfaceColumnQuery", Variant()), "revisions.surfaceColumnQuery");
	const Dictionary constants = require_dictionary(p_request.get("constants", Variant()), "constants");
	descriptor.constants.cell_size_meters = require_number(constants.get("cellSizeMeters", Variant()), "constants.cellSizeMeters");
	descriptor.constants.cell_center_offset_cells = require_number(constants.get("cellCenterOffsetCells", Variant()), "constants.cellCenterOffsetCells");
	descriptor.constants.world_bottom_cell_y = require_i32(constants.get("worldBottomCellY", Variant()), "constants.worldBottomCellY");
	descriptor.constants.water_level_meters = require_number(constants.get("waterLevelMeters", Variant()), "constants.waterLevelMeters");
	descriptor.constants.minimum_surface_meters = require_number(constants.get("minimumSurfaceMeters", Variant()), "constants.minimumSurfaceMeters");
	descriptor.constants.maximum_surface_meters = require_number(constants.get("maximumSurfaceMeters", Variant()), "constants.maximumSurfaceMeters");
	return descriptor;
}

std::vector<NativeTownRegionOverride> parse_town_overrides(const Array &p_values) {
	if (static_cast<std::size_t>(p_values.size()) > MAX_TOWN_OVERRIDES) {
		throw std::length_error("sitePolicy.townOverrides exceeds adapter record limit");
	}
	std::vector<NativeTownRegionOverride> result;
	result.reserve(static_cast<std::size_t>(p_values.size()));
	for (int64_t index = 0; index < p_values.size(); ++index) {
		const Dictionary value = require_dictionary(p_values[index], "sitePolicy.townOverrides[]");
		const Vector2i region = require_vector2i(value.get("region", Variant()), "townOverride.region");
		NativeTownRegionOverride record;
		record.region_x = region.x;
		record.region_z = region.y;
		record.has_town = require_bool(value.get("hasTown", Variant()), "townOverride.hasTown");
		if (record.has_town) {
			const std::int64_t expected_x = static_cast<std::int64_t>(region.x) * NativeTerrainShapingSnapshot::PAGE_CELLS;
			const std::int64_t expected_z = static_cast<std::int64_t>(region.y) * NativeTerrainShapingSnapshot::PAGE_CELLS;
			if (expected_x < std::numeric_limits<std::int32_t>::min() || expected_x > std::numeric_limits<std::int32_t>::max()
					|| expected_z < std::numeric_limits<std::int32_t>::min() || expected_z > std::numeric_limits<std::int32_t>::max()) {
				throw std::out_of_range("town override center exceeds int32");
			}
			record.town.region_x = region.x;
			record.town.region_z = region.y;
			record.town.center_x = require_i32(value.get("centerX", Variant()), "townOverride.centerX");
			record.town.center_z = require_i32(value.get("centerZ", Variant()), "townOverride.centerZ");
			record.town.radius_cells = require_i32(value.get("radiusCells", Variant()), "townOverride.radiusCells");
			record.town.level_meters = require_number(value.get("levelMeters", Variant()), "townOverride.levelMeters");
		}
		result.push_back(record);
	}
	return result;
}

NativeSiteSourcePolicy parse_site_policy(const Dictionary &p_request,
		const std::vector<NativeTownRegionOverride> &p_towns) {
	const Dictionary policy = require_dictionary(p_request.get("sitePolicy", Variant()), "sitePolicy");
	NativeSiteSourcePolicy result;
	result.source_policy_revision = require_u32(policy.get("sourcePolicyRevision", Variant()), "sitePolicy.sourcePolicyRevision");
	result.survey_generation_policy_revision = require_u32(policy.get("surveyGenerationPolicyRevision", Variant()), "sitePolicy.surveyGenerationPolicyRevision");
	Engine *engine = Engine::get_singleton();
	if (engine == nullptr) throw std::runtime_error("Godot Engine singleton is unavailable");
	result.engine_version_utf8 = utf8(String(engine->get_version_info().get("string", "")));
	if (result.engine_version_utf8.empty()) throw std::runtime_error("Godot engine version string is unavailable");
	result.ordinary_region_cells = require_i64(policy.get("ordinaryRegionCells", Variant()), "sitePolicy.ordinaryRegionCells");
	result.ordinary_spawn_chance = require_number(policy.get("ordinarySpawnChance", Variant()), "sitePolicy.ordinarySpawnChance");
	for (const NativeTownRegionOverride &town : p_towns) {
		NativeSiteSourcePolicy::TownOverride value;
		value.region_x = town.region_x;
		value.region_z = town.region_z;
		value.has_town = town.has_town;
		if (town.has_town) {
			value.center_x = town.town.center_x;
			value.center_z = town.town.center_z;
			value.radius_cells = town.town.radius_cells;
			value.level_meters = town.town.level_meters;
		}
		result.town_overrides.push_back(value);
	}
	return result;
}

NativeEffectiveTerrainBatchRequest parse_batch_request(const Dictionary &p_request) {
	if (require_protocol_string(p_request.get("schema", Variant()), "schema") != BATCH_REQUEST_SCHEMA) {
		throw std::invalid_argument("unsupported native effective terrain batch schema");
	}
	const Array surfaces = require_array(p_request.get("surfaceColumns", Variant()), "surfaceColumns");
	const Array centers = require_array(p_request.get("cellCenters", Variant()), "cellCenters");
	const Array lattice = require_array(p_request.get("latticeNumeric", Variant()), "latticeNumeric");
	const Array world = require_array(p_request.get("worldNumeric", Variant()), "worldNumeric");
	const Array projections = require_array(p_request.get("surfaceProjectionNumeric", Variant()), "surfaceProjectionNumeric");
	const std::size_t channel_sizes[] = {
		static_cast<std::size_t>(surfaces.size()), static_cast<std::size_t>(centers.size()),
		static_cast<std::size_t>(lattice.size()), static_cast<std::size_t>(world.size()),
		static_cast<std::size_t>(projections.size()),
	};
	std::size_t total = 0U;
	for (const std::size_t size : channel_sizes) {
		if (size > MAX_BATCH_CHANNEL_QUERIES) {
			throw std::length_error("native effective terrain batch channel exceeds adapter query limit");
		}
		total += size;
	}
	if (total > MAX_BATCH_TOTAL_QUERIES) {
		throw std::length_error("native effective terrain batch exceeds adapter total query limit");
	}
	NativeEffectiveTerrainBatchRequest request;
	request.surface_columns.reserve(channel_sizes[0]);
	request.cell_centers.reserve(channel_sizes[1]);
	request.lattice_numeric.reserve(channel_sizes[2]);
	request.world_numeric.reserve(channel_sizes[3]);
	request.surface_projection_numeric.reserve(channel_sizes[4]);
	for (int64_t index = 0; index < surfaces.size(); ++index) {
		const Dictionary value = require_dictionary(surfaces[index], "surfaceColumns[]");
		const Vector2i coordinate = require_vector2i(value.get("coordinate", Variant()), "surfaceColumns[].coordinate");
		request.surface_columns.push_back({coordinate.x, coordinate.y,
			parse_intent(value.get("intent", Variant()), "surfaceColumns[].intent")});
	}
	for (int64_t index = 0; index < centers.size(); ++index) {
		const Dictionary value = require_dictionary(centers[index], "cellCenters[]");
		request.cell_centers.push_back({cell_coord(require_vector3i(value.get("coordinate", Variant()), "cellCenters[].coordinate")),
			parse_intent(value.get("intent", Variant()), "cellCenters[].intent")});
	}
	for (int64_t index = 0; index < lattice.size(); ++index) {
		const Dictionary value = require_dictionary(lattice[index], "latticeNumeric[]");
		request.lattice_numeric.push_back({cell_coord(require_vector3i(value.get("coordinate", Variant()), "latticeNumeric[].coordinate")),
			parse_intent(value.get("intent", Variant()), "latticeNumeric[].intent")});
	}
	for (int64_t index = 0; index < world.size(); ++index) {
		const Dictionary value = require_dictionary(world[index], "worldNumeric[]");
		const Vector3 position = require_vector3(value.get("position", Variant()), "worldNumeric[].position");
		NativeEffectiveWorldNumericBatchQuery query;
		query.position = {position.x, position.y, position.z};
		query.intent = parse_intent(value.get("intent", Variant()), "worldNumeric[].intent");
		query.semantic_revision = require_u32(value.get("semanticRevision", Variant()), "worldNumeric[].semanticRevision");
		request.world_numeric.push_back(query);
	}
	for (int64_t index = 0; index < projections.size(); ++index) {
		const Dictionary value = require_dictionary(projections[index], "surfaceProjectionNumeric[]");
		NativeEffectiveSurfaceProjectionNumericBatchQuery query;
		query.coordinate = cell_coord(require_vector3i(value.get("coordinate", Variant()), "surfaceProjectionNumeric[].coordinate"));
		query.intent = parse_intent(value.get("intent", Variant()), "surfaceProjectionNumeric[].intent");
		query.semantic_revision = require_u32(value.get("semanticRevision", Variant()), "surfaceProjectionNumeric[].semanticRevision");
		request.surface_projection_numeric.push_back(query);
	}
	return request;
}

NativeCellStateNamespace parse_cell_namespace(const Variant &p_value, const char *p_field) {
	const String value = require_protocol_string(p_value, p_field);
	if (value == "durable_terrain") return NativeCellStateNamespace::durable_terrain;
	if (value == "scene_overlay") return NativeCellStateNamespace::scene_overlay;
	throw std::invalid_argument(std::string(p_field) + " is unsupported");
}

Dictionary commit_typed_cell_request(NativeWorldBackendState &p_state,
		const Dictionary &p_request, const bool p_durable_only, const char *p_operation) {
	const String expected_schema = p_durable_only ?
		String("n3-native-durable-cell-transaction/v1") : String("n3-native-typed-cell-transaction/v1");
	if (require_protocol_string(p_request.get("schema", Variant()), "schema") != expected_schema) {
		throw std::invalid_argument("unsupported typed cell transaction schema");
	}
	NativeWorldBackendTransaction transaction;
	transaction.source_identity = p_state.source_identity();
	transaction.deltas.transaction_id = require_bounded_utf8(
		p_request.get("transactionId", Variant()), "transactionId", MAX_TRANSACTION_ID_BYTES, false);
	transaction.deltas.expected_revision = require_u64(p_request.get("expectedRevision", Variant()), "expectedRevision");
	const Array operations = require_array(p_request.get("operations", Variant()), "operations");
	if (static_cast<std::size_t>(operations.size()) > MAX_TYPED_CELL_OPERATIONS) {
		throw std::length_error("typed cell transaction exceeds adapter operation limit");
	}
	transaction.deltas.operations.reserve(static_cast<std::size_t>(operations.size()));
	for (int64_t index = 0; index < operations.size(); ++index) {
		const Dictionary value = require_dictionary(operations[index], "operations[]");
		WorldTypedCellOperation operation;
		operation.name_space = p_durable_only ? NativeCellStateNamespace::durable_terrain :
			parse_cell_namespace(value.get("namespace", Variant()), "operation.namespace");
		if (p_durable_only && value.has("namespace") &&
				parse_cell_namespace(value.get("namespace", Variant()), "operation.namespace") != NativeCellStateNamespace::durable_terrain) {
			throw std::invalid_argument("durable transaction cannot contain a scene overlay");
		}
		operation.cell = cell_coord(require_vector3i(value.get("cell", Variant()), "operation.cell"));
		const String kind = require_protocol_string(value.get("kind", Variant()), "operation.kind");
		if (kind == "clear") {
			operation.kind = WorldTypedCellOperationKind::clear;
			if (value.has("state") && value.get("state", Variant()).get_type() != Variant::NIL) {
				throw std::invalid_argument("clear operation cannot carry state");
			}
		} else if (kind == "set") {
			operation.kind = WorldTypedCellOperationKind::set;
			operation.state = parse_cell_state(
				require_dictionary(value.get("state", Variant()), "operation.state"),
				operation.cell, operation.name_space);
		} else {
			throw std::invalid_argument("operation.kind is unsupported");
		}
		transaction.deltas.operations.push_back(std::move(operation));
	}
	const WorldDeltaCommitReceipt receipt = p_state.commit(transaction);
	Dictionary result = envelope(p_operation, "ready");
	result["transactionId"] = text(receipt.transaction_id);
	result["revision"] = static_cast<int64_t>(receipt.revision);
	switch (receipt.status) {
	case WorldDeltaCommitStatus::committed: result["commitStatus"] = "committed"; break;
	case WorldDeltaCommitStatus::no_change: result["commitStatus"] = "no_change"; break;
	case WorldDeltaCommitStatus::idempotent_replay: result["commitStatus"] = "idempotent_replay"; break;
	}
	Array affected;
	for (const WorldDeltaSectionKey section : receipt.affected_sections) affected.append(vector3i(section.section));
	result["affectedSections"] = affected;
	return result;
}

Array regions_array(const std::vector<NativeSiteSourceRegionKey> &p_regions) {
	Array result;
	for (const NativeSiteSourceRegionKey region : p_regions) result.append(Vector2i(region.x, region.z));
	return result;
}

StructureExclusionRect structure_rect(const Dictionary &p_row) {
	require_exact_keys(p_row, {"id", "minX", "minZ", "maxX", "maxZ"}, "structure rectangle");
	return {require_i32(p_row["minX"], "rect.minX"), require_i32(p_row["minZ"], "rect.minZ"),
		require_i32(p_row["maxX"], "rect.maxX"), require_i32(p_row["maxZ"], "rect.maxZ")};
}

std::vector<StructureExclusionRecord> structure_records(const Variant &p_value, const char *p_field) {
	const Array rows = require_array(p_value, p_field);
	if (rows.size() > 65536) throw std::length_error("structure record count exceeds limit");
	std::vector<StructureExclusionRecord> result;
	result.reserve(static_cast<std::size_t>(rows.size()));
	for (const Variant &entry : rows) {
		const Dictionary row = require_dictionary(entry, p_field);
		result.push_back({require_bounded_utf8(row.get("id", Variant()), "rect.id", 1024U, false),
			structure_rect(row)});
	}
	return result;
}

std::vector<CitadelExclusionSource> structure_citadels(const Variant &p_value) {
	const Array rows = require_array(p_value, "content.citadel");
	if (rows.size() > 65536) throw std::length_error("citadel record count exceeds limit");
	std::vector<CitadelExclusionSource> result;
	result.reserve(static_cast<std::size_t>(rows.size()));
	for (const Variant &entry : rows) {
		const Dictionary row = require_dictionary(entry, "content.citadel[]");
		require_exact_keys(row, {"region", "status", "reason", "sourceKey", "sourceSignature",
			"admissionGeneration", "reservationCells"}, "citadel exclusion row");
		const Vector2i region = require_vector2i(row["region"], "citadel.region");
		const std::string status = require_bounded_utf8(row["status"], "citadel.status", 16U, false);
		CitadelSourceStatus source_status;
		if (status == "absent") source_status = CitadelSourceStatus::absent;
		else if (status == "failed") source_status = CitadelSourceStatus::failed;
		else if (status == "ready") source_status = CitadelSourceStatus::ready;
		else if (status == "prepared") source_status = CitadelSourceStatus::prepared;
		else throw std::invalid_argument("citadel source status is not admitted");
		if (row["reservationCells"].get_type() != Variant::RECT2I)
			throw std::invalid_argument("citadel reservationCells must be a Rect2i");
		const Rect2i reservation = row["reservationCells"];
		const std::int64_t end_x = static_cast<std::int64_t>(reservation.position.x) + reservation.size.x;
		const std::int64_t end_z = static_cast<std::int64_t>(reservation.position.y) + reservation.size.y;
		if (end_x > std::numeric_limits<std::int32_t>::max() || end_x < std::numeric_limits<std::int32_t>::min()
				|| end_z > std::numeric_limits<std::int32_t>::max() || end_z < std::numeric_limits<std::int32_t>::min())
			throw std::out_of_range("citadel reservation end exceeds int32");
		const std::int64_t generation = require_i64(row["admissionGeneration"], "citadel.admissionGeneration");
		if (generation < 0) throw std::out_of_range("citadel admissionGeneration is negative");
		result.push_back({region.x, region.y, source_status,
			require_bounded_utf8(row["reason"], "citadel.reason", 1024U),
			require_bounded_utf8(row["sourceKey"], "citadel.sourceKey", 1024U),
			require_bounded_utf8(row["sourceSignature"], "citadel.sourceSignature", 1024U),
			static_cast<std::uint64_t>(generation),
			{reservation.position.x, reservation.position.y,
				static_cast<std::int32_t>(end_x), static_cast<std::int32_t>(end_z)}});
	}
	return result;
}

} // namespace

void NativeEffectiveTerrainPage::_bind_methods() {
	ClassDB::bind_method(D_METHOD("status"), &NativeEffectiveTerrainPage::status);
	ClassDB::bind_method(D_METHOD("sample_batch", "request"), &NativeEffectiveTerrainPage::sample_batch);
	ClassDB::bind_method(D_METHOD("encode_voxel_block", "request"), &NativeEffectiveTerrainPage::encode_voxel_block);
}

void NativeEffectiveTerrainPage::admit(std::unique_ptr<NativeEffectiveTerrainBatch> p_batch) {
	if (batch_ || !p_batch) throw std::logic_error("native effective terrain page admission is invalid");
	batch_ = std::move(p_batch);
}

Dictionary NativeEffectiveTerrainPage::status() const {
	Dictionary result = envelope("page_status", batch_ ? "ready" : "uninitialized",
		batch_ ? String() : String("page_has_no_pin"));
	if (!batch_) return result;
	const WorldSourcePin &pin = batch_->pin();
	const NativeTerrainPageKey page = pin.primary_terrain_shaping().page_key();
	result["primaryPage"] = Vector2i(page.x, page.z);
	result["sourceIdentity"] = identity_dictionary(pin.definition().physical_content_identity());
	result["pinIdentity"] = identity_dictionary(pin.physical_content_identity());
	result["terrainDeltaRevision"] = static_cast<int64_t>(pin.terrain_delta_revision());
	result["shapingRegistryRevision"] = static_cast<int64_t>(pin.shaping_registry_revision());
	result["shapingRegistryIdentity"] = identity_dictionary(pin.shaping_registry_content_identity());
	result["shapingPageCount"] = static_cast<int64_t>(pin.terrain_shaping_page_count());
	return result;
}

Dictionary NativeEffectiveTerrainPage::sample_batch(const Dictionary &p_request) const {
	if (!batch_) return envelope("sample_batch", "failed", "page_has_no_pin");
	try {
		const NativeEffectiveTerrainBatchResult value = batch_->execute(parse_batch_request(p_request));
		Dictionary result = envelope("sample_batch", "ready");
		result["resultSchema"] = BATCH_RESULT_SCHEMA;
		result["schemaRevision"] = static_cast<int64_t>(value.schema_revision);
		result["primaryPage"] = Vector2i(value.primary_page.x, value.primary_page.z);
		result["sourceIdentity"] = identity_dictionary(value.definition_physical_identity);
		result["pinIdentity"] = identity_dictionary(value.pin_physical_identity);
		result["terrainDeltaRevision"] = static_cast<int64_t>(value.terrain_delta_revision);
		result["shapingRegistryRevision"] = static_cast<int64_t>(value.shaping_registry_revision);
		result["shapingRegistryIdentity"] = identity_dictionary(value.shaping_registry_content_identity);
		result["preparedPayloadBytes"] = static_cast<int64_t>(value.prepared_payload_bytes);
		Array surfaces;
		for (const NativeEffectiveSurfaceColumnBatchRecord &record : value.surface_columns) {
			Dictionary item;
			item["requested"] = query_dictionary(Vector2i(record.requested.x, record.requested.z), record.requested.intent);
			item["sourceCell"] = Vector2i(record.source_x, record.source_z);
			item["referenceSurfaceY"] = record.reference_surface_y;
			item["deformedSurfaceY"] = record.deformed_surface_y;
			item["volumeSurfaceY"] = record.volume_surface_y;
			item["biomeId"] = static_cast<int64_t>(record.biome);
			item["biome"] = BIOME_NAMES[static_cast<std::uint8_t>(record.biome)];
			surfaces.append(item);
		}
		result["surfaceColumns"] = surfaces;
		Array centers;
		for (const NativeEffectiveCellCenterBatchRecord &record : value.cell_centers) {
			Dictionary item;
			item["requested"] = query_dictionary(vector3i(record.requested.coordinate), record.requested.intent);
			item["sourceCell"] = vector3i(record.source_cell);
			item["materialId"] = static_cast<int64_t>(record.material);
			item["material"] = MATERIAL_NAMES[static_cast<std::uint8_t>(record.material)];
			item["biomeId"] = static_cast<int64_t>(record.biome);
			item["biome"] = BIOME_NAMES[static_cast<std::uint8_t>(record.biome)];
			item["fluidId"] = static_cast<int64_t>(record.fluid);
			item["fluid"] = FLUID_NAMES[static_cast<std::uint8_t>(record.fluid)];
			item["solid"] = record.solid;
			item["density"] = record.density;
			item["light"] = Vector2i(record.light.sky, record.light.block);
			item["generated"] = record.generated;
			item["edited"] = record.edited;
			item["editedSparseState"] = record.edited_sparse_state ? Variant(state_dictionary(*record.edited_sparse_state)) : Variant();
			centers.append(item);
		}
		result["cellCenters"] = centers;
		Array lattice;
		for (const NativeEffectiveLatticeBatchRecord &record : value.lattice_numeric) {
			Dictionary item = numeric_dictionary(record.facts);
			item["requested"] = query_dictionary(vector3i(record.requested.coordinate), record.requested.intent);
			item["editedSparseState"] = record.edited_sparse_state ? Variant(state_dictionary(*record.edited_sparse_state)) : Variant();
			lattice.append(item);
		}
		result["latticeNumeric"] = lattice;
		Array world;
		for (const NativeEffectiveWorldBatchRecord &record : value.world_numeric) {
			Dictionary item = numeric_dictionary(record.facts);
			item["requestedPosition"] = Vector3(record.requested.position.x, record.requested.position.y, record.requested.position.z);
			item["intent"] = intent_name(record.requested.intent);
			item["semanticRevision"] = static_cast<int64_t>(record.requested.semantic_revision);
			item["editedSparseState"] = record.edited_sparse_state ? Variant(state_dictionary(*record.edited_sparse_state)) : Variant();
			world.append(item);
		}
		result["worldNumeric"] = world;
		Array projections;
		for (const NativeEffectiveSurfaceProjectionBatchRecord &record : value.surface_projection_numeric) {
			Dictionary item = numeric_dictionary(record.facts);
			item["requested"] = query_dictionary(vector3i(record.requested.coordinate), record.requested.intent);
			item["semanticRevision"] = static_cast<int64_t>(record.requested.semantic_revision);
			item["editedSparseState"] = record.edited_sparse_state ? Variant(state_dictionary(*record.edited_sparse_state)) : Variant();
			projections.append(item);
		}
		result["surfaceProjectionNumeric"] = projections;
		return result;
	} catch (const std::exception &error) {
		return failure("sample_batch", error);
	}
}

Dictionary NativeEffectiveTerrainPage::encode_voxel_block(const Dictionary &p_request) const {
	if (!batch_) return envelope("encode_voxel_block", "failed", "page_has_no_pin");
	try {
		if (require_protocol_string(p_request.get("schema", Variant()), "schema") != VOXEL_BLOCK_REQUEST_SCHEMA)
			throw std::invalid_argument("unsupported native effective voxel block request schema");
		const Vector3i origin = require_vector3i(p_request.get("origin", Variant()), "origin");
		const Vector3i size = require_vector3i(p_request.get("size", Variant()), "size");
		const std::int64_t lod = require_i64(p_request.get("lod", Variant()), "lod");
		if (lod < 0 || lod > std::numeric_limits<std::uint32_t>::max())
			throw std::out_of_range("lod exceeds uint32");
		const NativeEffectiveTerrainSource source(batch_->pin());
		const NativeEffectiveVoxelBlock value = encode_native_effective_voxel_block(
			source, {cell_coord(origin), cell_coord(size), static_cast<std::uint32_t>(lod)});
		auto packed = [](const std::vector<std::uint8_t> &bytes) {
			PackedByteArray result;
			result.resize(static_cast<int64_t>(bytes.size()));
			std::memcpy(result.ptrw(), bytes.data(), bytes.size());
			return result;
		};
		Dictionary result = envelope("encode_voxel_block", "ready");
		result["resultSchema"] = VOXEL_BLOCK_RESULT_SCHEMA;
		result["origin"] = vector3i(value.origin);
		result["size"] = vector3i(value.size);
		result["lod"] = static_cast<int64_t>(value.lod);
		result["pinIdentity"] = identity_dictionary(value.pin_identity);
		result["blockContentIdentity"] = identity_dictionary(value.block_content_identity);
		result["terrainDeltaRevision"] = static_cast<int64_t>(value.terrain_delta_revision);
		result["shapingRegistryRevision"] = static_cast<int64_t>(value.shaping_registry_revision);
		result["sdf16Le"] = packed(value.sdf16_le);
		result["indices8"] = packed(value.indices8);
		result["data5_8"] = packed(value.data5_8);
		return result;
	} catch (const std::exception &error) {
		return failure("encode_voxel_block", error);
	}
}

void NativeStructureExclusionChunk::_bind_methods() {
	ClassDB::bind_method(D_METHOD("status"), &NativeStructureExclusionChunk::status);
	ClassDB::bind_method(D_METHOD("query", "cell"), &NativeStructureExclusionChunk::query);
}

void NativeStructureExclusionChunk::admit(std::unique_ptr<NativeStructureExclusionSnapshot> p_snapshot,
		Vector2i p_chunk, std::int64_t p_owner_id, std::int64_t p_revision,
		std::int64_t p_admission_generation, std::string p_capture_identity) {
	if (snapshot_ || !p_snapshot) throw std::logic_error("native structure chunk admission is invalid");
	snapshot_ = std::move(p_snapshot);
	chunk_ = p_chunk;
	owner_id_ = p_owner_id;
	revision_ = p_revision;
	admission_generation_ = p_admission_generation;
	capture_identity_ = std::move(p_capture_identity);
}

Dictionary NativeStructureExclusionChunk::status() const {
	Dictionary result = envelope("structure_chunk_status", snapshot_ ? "ready" : "uninitialized",
		snapshot_ ? String() : String("structure_chunk_has_no_snapshot"));
	if (!snapshot_) return result;
	result["receiptSchema"] = STRUCTURE_CHUNK_RECEIPT_SCHEMA;
	result["chunk"] = chunk_;
	result["ownerInstanceId"] = owner_id_;
	result["ownerGeneration"] = static_cast<std::int64_t>(snapshot_->world_generation());
	result["exclusionRevision"] = revision_;
	result["admissionGeneration"] = admission_generation_;
	result["captureIdentity"] = text(capture_identity_);
	result["sourceIdentity"] = text(sha256_hex(snapshot_->world_digest()));
	result["contentIdentity"] = text(sha256_hex(snapshot_->content_digest()));
	result["completeFeatureManifest"] = false;
	result["liveCaptureFreshnessProven"] = false;
	return result;
}

Dictionary NativeStructureExclusionChunk::query(const Vector2i &p_cell) const {
	if (!snapshot_) return envelope("structure_chunk_query", "failed", "structure_chunk_has_no_snapshot");
	const StructureExclusionDecision decision = snapshot_->query(p_cell.x, p_cell.y);
	Dictionary result = envelope("structure_chunk_query", "ready");
	result["blocked"] = decision.blocked;
	result["complete"] = decision.complete;
	result["kind"] = static_cast<std::int64_t>(decision.kind);
	result["sourceId"] = text(decision.source_id);
	return result;
}

void NativeWorldBackend::_bind_methods() {
	ClassDB::bind_method(D_METHOD("initialize", "request"), &NativeWorldBackend::initialize);
	ClassDB::bind_method(D_METHOD("initialize_from_save_v2", "request"), &NativeWorldBackend::initialize_from_save_v2);
	ClassDB::bind_method(D_METHOD("export_terrain_volume_v2"), &NativeWorldBackend::export_terrain_volume_v2);
	ClassDB::bind_method(D_METHOD("admit_removed_props_tombstones", "capture"), &NativeWorldBackend::admit_removed_props_tombstones);
	ClassDB::bind_method(D_METHOD("admit_biome_environment_catalog", "capture"), &NativeWorldBackend::admit_biome_environment_catalog);
	ClassDB::bind_method(D_METHOD("admit_visual_asset_catalog", "bundle"), &NativeWorldBackend::admit_visual_asset_catalog);
	ClassDB::bind_method(D_METHOD("select_rock_asset_shadow", "biome", "durable_prop_id"), &NativeWorldBackend::select_rock_asset_shadow);
	ClassDB::bind_method(D_METHOD("admit_wildlife_presentation_catalog", "bundle"), &NativeWorldBackend::admit_wildlife_presentation_catalog);
	ClassDB::bind_method(D_METHOD("admit_structure_exclusion_chunk", "capture"), &NativeWorldBackend::admit_structure_exclusion_chunk);
	ClassDB::bind_method(D_METHOD("compose_surface_prop_ordered_shadow", "page", "exclusions"),
		&NativeWorldBackend::compose_surface_prop_ordered_shadow);
	ClassDB::bind_method(D_METHOD("compose_surface_tree_presence_shadow", "page", "exclusions", "union_capture"),
		&NativeWorldBackend::compose_surface_tree_presence_shadow);
	ClassDB::bind_method(D_METHOD("wildlife_presentation_shadow", "variant"), &NativeWorldBackend::wildlife_presentation_shadow);
	ClassDB::bind_method(D_METHOD("status"), &NativeWorldBackend::status);
	ClassDB::bind_method(D_METHOD("shaping_requests", "primary_page"), &NativeWorldBackend::shaping_requests);
	ClassDB::bind_method(D_METHOD("apply_shaping_resolutions", "resolutions"), &NativeWorldBackend::apply_shaping_resolutions);
	ClassDB::bind_method(D_METHOD("commit_typed_cells", "request"), &NativeWorldBackend::commit_typed_cells);
	ClassDB::bind_method(D_METHOD("commit_durable_cells", "request"), &NativeWorldBackend::commit_durable_cells);
	ClassDB::bind_method(D_METHOD("pin_effective_page", "primary_page"), &NativeWorldBackend::pin_effective_page);
	ClassDB::bind_method(D_METHOD("encode_voxel_block_shadow", "request"), &NativeWorldBackend::encode_voxel_block_shadow);
	ClassDB::bind_method(D_METHOD("begin_voxel_block_shadow_async", "request"), &NativeWorldBackend::begin_voxel_block_shadow_async);
	ClassDB::bind_method(D_METHOD("poll_voxel_block_shadow_async", "ticket"), &NativeWorldBackend::poll_voxel_block_shadow_async);
	ClassDB::bind_method(D_METHOD("cancel_voxel_block_shadow_async", "ticket"), &NativeWorldBackend::cancel_voxel_block_shadow_async);
}

NativeWorldBackend::~NativeWorldBackend() {
	if (voxel_worker_cancel_token_) voxel_worker_cancel_token_->store(true, std::memory_order_relaxed);
	if (voxel_worker_.joinable()) voxel_worker_.join();
}

Dictionary NativeWorldBackend::initialize(const Dictionary &p_request) {
	if (initialization_attempted_) return envelope("initialize", "failed", "initialization_is_one_shot");
	initialization_attempted_ = true;
	try {
		WorldSourceDefinition definition(parse_source_descriptor(p_request, INITIALIZE_SCHEMA));
		const Dictionary policy = require_dictionary(p_request.get("sitePolicy", Variant()), "sitePolicy");
		std::vector<NativeTownRegionOverride> towns = parse_town_overrides(
			require_array(policy.get("townOverrides", Variant()), "sitePolicy.townOverrides"));
		NativeSiteSourcePolicy site_policy = parse_site_policy(p_request, towns);
		auto state = std::make_unique<NativeWorldBackendState>(definition);
		auto registry = std::make_unique<NativeTerrainShapingRegistry>(definition, std::move(site_policy));
		town_overrides_ = std::move(towns);
		state_ = std::move(state);
		shaping_registry_ = std::move(registry);
		return status();
	} catch (const std::exception &error) {
		initialization_failure_ = error.what();
		return failure("initialize", error);
	}
}

Dictionary NativeWorldBackend::initialize_from_save_v2(const Dictionary &p_request) {
	if (initialization_attempted_) {
		return envelope("initialize_from_save_v2", "failed", "initialization_is_one_shot");
	}
	initialization_attempted_ = true;
	try {
		WorldSourceDefinition definition(parse_source_descriptor(p_request, INITIALIZE_FROM_SAVE_V2_SCHEMA));
		const String save_seed_text = require_string(p_request.get("saveSeedText", Variant()), "saveSeedText");
		if (static_cast<std::size_t>(save_seed_text.length()) > MAX_SEED_CODE_POINTS) {
			throw std::length_error("saveSeedText exceeds adapter code point limit");
		}
		const std::string save_seed = bounded_utf8(
			save_seed_text, MAX_SEED_TEXT_BYTES, "saveSeedText", false);
		if (save_seed != definition.raw_terrain_seed().utf8) {
			throw std::invalid_argument("saveSeedText does not match the native world source seed");
		}
		const Dictionary policy = require_dictionary(p_request.get("sitePolicy", Variant()), "sitePolicy");
		std::vector<NativeTownRegionOverride> towns = parse_town_overrides(
			require_array(policy.get("townOverrides", Variant()), "sitePolicy.townOverrides"));
		NativeSiteSourcePolicy site_policy = parse_site_policy(p_request, towns);
		NativeTerrainVolumeV2 terrain_volume = parse_terrain_volume_v2(
			p_request.get("terrainVolume", Variant()));

		NativeWorldBackendInitialSnapshot initial;
		initial.source_identity = definition.physical_content_identity();
		// Persisted terrain revisions remain save-domain facts. The native global
		// mutation sequence deliberately begins at zero for this new owner.
		initial.deltas.revision = 0U;
		initial.deltas.terrain_volume = std::move(terrain_volume);
		auto state = std::make_unique<NativeWorldBackendState>(definition, std::move(initial));
		auto registry = std::make_unique<NativeTerrainShapingRegistry>(definition, std::move(site_policy));

		// Publish only after the source, policy, complete save payload, state, and
		// shaping registry have all validated and constructed successfully.
		town_overrides_ = std::move(towns);
		state_ = std::move(state);
		shaping_registry_ = std::move(registry);
		return status();
	} catch (const std::exception &error) {
		initialization_failure_ = error.what();
		return failure("initialize_from_save_v2", error);
	}
}

Dictionary NativeWorldBackend::export_terrain_volume_v2() const {
	if (!state_ || !shaping_registry_) {
		return envelope("export_terrain_volume_v2", "failed", "backend_not_ready");
	}
	try {
		const NativeTerrainVolumeV2 terrain_volume = state_->export_terrain_volume_v2();
		Dictionary result = envelope("export_terrain_volume_v2", "ready");
		result["saveSeedText"] = text(state_->definition().raw_terrain_seed().utf8);
		result["sourceIdentity"] = identity_dictionary(state_->source_identity());
		result["terrainDeltaRevision"] = static_cast<int64_t>(state_->terrain_delta_revision());
		result["persistedRevision"] = static_cast<int64_t>(terrain_volume.revision);
		result["terrainVolume"] = terrain_volume_dictionary(terrain_volume);
		return result;
	} catch (const std::exception &error) {
		return failure("export_terrain_volume_v2", error);
	}
}

Dictionary NativeWorldBackend::admit_biome_environment_catalog(const Dictionary &p_capture) {
	constexpr const char *operation = "admit_biome_environment_catalog";
	if (!state_ || !shaping_registry_) return envelope(operation, "failed", "backend_not_ready");
	// A rejected replacement cannot leave an earlier catalog available to a
	// later visual admission under the same native owner.
	biome_catalog_.reset();
	visual_catalog_.reset();
	visual_capture_owner_id_ = 0;
	visual_capture_revision_ = 0;
	visual_capture_identity_.clear();
	wildlife_presentations_.reset();
	presentation_capture_owner_id_ = 0;
	presentation_capture_revision_ = 0;
	presentation_capture_identity_.clear();
	biome_capture_owner_id_ = 0;
	biome_capture_revision_ = 0;
	biome_capture_identity_.clear();
	try {
		require_exact_keys(p_capture,
			{"ok", "schemaVersion", "ownerReceipt", "fallbackId", "contentIdentity", "profiles"}, "biome capture");
		if (!require_bool(p_capture["ok"], "capture.ok")
				|| require_i64(p_capture["schemaVersion"], "capture.schemaVersion") != 1) {
			throw std::invalid_argument("unsupported biome capture schema");
		}
		const Dictionary owner = require_dictionary(p_capture["ownerReceipt"], "capture.ownerReceipt");
		require_exact_keys(owner, {"owner_id", "revision", "ready"}, "capture.ownerReceipt");
		const std::int64_t owner_id = require_i64(owner["owner_id"], "capture.ownerReceipt.owner_id");
		const std::int64_t revision = require_i64(owner["revision"], "capture.ownerReceipt.revision");
		if (owner_id == 0 || revision <= 0 || !require_bool(owner["ready"], "capture.ownerReceipt.ready")) {
			throw std::invalid_argument("biome capture source is not ready");
		}
		const std::string fallback = require_bounded_utf8(p_capture["fallbackId"], "capture.fallbackId", 64U, false);
		if (fallback != "default") throw std::invalid_argument("biome fallback is unsupported");
		const Array rows = require_array(p_capture["profiles"], "capture.profiles");
		if (rows.size() != static_cast<int64_t>(NativeBiomeEnvironmentCatalog::PROFILE_COUNT)) {
			throw std::invalid_argument("biome profile count mismatch");
		}
		std::vector<NativeBiomeEnvironmentProfile> profiles;
		profiles.reserve(NativeBiomeEnvironmentCatalog::PROFILE_COUNT);
		for (const Variant &entry : rows) {
			const Dictionary row = require_dictionary(entry, "capture.profiles[]");
			require_exact_keys(row, {"biomeId", "biome_id", "forage_material", "forage_drop", "tree_architecture",
				"cold_weather", "forage_drop_min", "forage_drop_max", "tree_scale", "rock_scale", "tree_chance",
				"rock_base_chance", "forage_chance", "wildlife_chance", "forage_radius", "weather_precip",
				"weather_clouds", "detail_max_height_above_water", "tree_height_min", "tree_height_max",
				"crown_radius_min", "crown_radius_max", "trunk_radius_min", "trunk_radius_max",
				"old_growth_chance", "wind_response", "canopy_density", "natural_prop_exclusion_margin",
				"tree_visibility_range", "tree_shadow_range", "tree_age_min_years", "tree_age_typical_years",
				"tree_age_max_years", "tree_maturity_cell_scale", "tree_maturity_influence", "tree_local_age_span",
				"tree_age_distribution_skew", "tree_height_growth_exponent", "tree_girth_growth_exponent",
				"tree_crown_growth_exponent", "tree_families", "rock_families", "detail_types",
				"detail_thresholds", "detail_y_offsets", "detail_scale_mins", "detail_scale_maxs",
				"tree_age_band_thresholds"}, "capture.profiles[]");
			NativeBiomeEnvironmentProfile profile;
			profile.biome_id = require_bounded_utf8(row["biome_id"], "profile.biome_id", 1024U, false);
			if (profile.biome_id != require_bounded_utf8(row["biomeId"], "profile.biomeId", 1024U, false)) {
				throw std::invalid_argument("biome ID alias mismatch");
			}
#define SNAP_TEXT(name) profile.name = require_bounded_utf8(row[#name], "profile." #name, 1024U, false)
#define SNAP_BOOL(name) profile.name = require_bool(row[#name], "profile." #name)
#define SNAP_INT(name) profile.name = require_i32(row[#name], "profile." #name)
#define SNAP_SCALAR(name) profile.name = require_snapshot_numeric(row[#name], "profile." #name, false)
#define SNAP_STRINGS(name) profile.name = require_snapshot_strings(row[#name], "profile." #name)
#define SNAP_FLOATS(name) profile.name = require_snapshot_floats(row[#name], "profile." #name)
			SNAP_TEXT(forage_material); SNAP_TEXT(forage_drop); SNAP_TEXT(tree_architecture);
			SNAP_BOOL(cold_weather); SNAP_INT(forage_drop_min); SNAP_INT(forage_drop_max);
			SNAP_SCALAR(tree_scale); SNAP_SCALAR(rock_scale); SNAP_SCALAR(tree_chance);
			SNAP_SCALAR(rock_base_chance); SNAP_SCALAR(forage_chance); SNAP_SCALAR(wildlife_chance);
			SNAP_SCALAR(forage_radius); SNAP_SCALAR(weather_precip); SNAP_SCALAR(weather_clouds);
			SNAP_SCALAR(detail_max_height_above_water); SNAP_SCALAR(tree_height_min); SNAP_SCALAR(tree_height_max);
			SNAP_SCALAR(crown_radius_min); SNAP_SCALAR(crown_radius_max); SNAP_SCALAR(trunk_radius_min);
			SNAP_SCALAR(trunk_radius_max); SNAP_SCALAR(old_growth_chance); SNAP_SCALAR(wind_response);
			SNAP_SCALAR(canopy_density); SNAP_SCALAR(natural_prop_exclusion_margin);
			SNAP_SCALAR(tree_visibility_range); SNAP_SCALAR(tree_shadow_range);
			SNAP_SCALAR(tree_age_min_years); SNAP_SCALAR(tree_age_typical_years); SNAP_SCALAR(tree_age_max_years);
			SNAP_SCALAR(tree_maturity_cell_scale); SNAP_SCALAR(tree_maturity_influence);
			SNAP_SCALAR(tree_local_age_span); SNAP_SCALAR(tree_age_distribution_skew);
			SNAP_SCALAR(tree_height_growth_exponent); SNAP_SCALAR(tree_girth_growth_exponent);
			SNAP_SCALAR(tree_crown_growth_exponent);
			SNAP_STRINGS(tree_families); SNAP_STRINGS(rock_families); SNAP_STRINGS(detail_types);
			SNAP_FLOATS(detail_thresholds); SNAP_FLOATS(detail_y_offsets);
			SNAP_FLOATS(detail_scale_mins); SNAP_FLOATS(detail_scale_maxs);
			const std::vector<float> age_bands = require_snapshot_floats(row["tree_age_band_thresholds"], "profile.tree_age_band_thresholds");
			if (age_bands.size() != profile.tree_age_band_thresholds.size()) {
				throw std::invalid_argument("tree age band count mismatch");
			}
			std::copy(age_bands.begin(), age_bands.end(), profile.tree_age_band_thresholds.begin());
#undef SNAP_TEXT
#undef SNAP_BOOL
#undef SNAP_INT
#undef SNAP_SCALAR
#undef SNAP_STRINGS
#undef SNAP_FLOATS
			profiles.push_back(std::move(profile));
		}
		NativeBiomeEnvironmentCatalog typed = NativeBiomeEnvironmentCatalog::create(std::move(profiles), fallback);
		Dictionary canonical;
		canonical["domain"] = "biome_environment_resolved_catalog";
		canonical["schemaVersion"] = 1;
		canonical["fallbackId"] = "default";
		canonical["profiles"] = rows;
		const std::string identity = require_bounded_utf8(p_capture["contentIdentity"], "capture.contentIdentity", 64U, false);
		const std::string canonical_text = utf8(JSON::stringify(canonical));
		if (identity != sha256_hex(sha256(reinterpret_cast<const std::uint8_t *>(canonical_text.data()), canonical_text.size()))) {
			throw std::invalid_argument("biome capture content identity mismatch");
		}
		const std::string native_identity = sha256_hex(typed.content_digest());
		biome_catalog_ = std::make_unique<NativeBiomeEnvironmentCatalog>(std::move(typed));
		biome_capture_owner_id_ = owner_id;
		biome_capture_revision_ = revision;
		biome_capture_identity_ = identity;
		Dictionary result = envelope(operation, "ready");
		result["receiptSchema"] = BIOME_CATALOG_RECEIPT_SCHEMA;
		result["scope"] = "resolved_biome_environment_catalog_only";
		result["completeSurfacePropSource"] = false;
		result["liveCaptureFreshnessProven"] = false;
		result["captureOwnerInstanceId"] = owner_id;
		result["captureRevision"] = revision;
		result["captureContentIdentity"] = text(identity);
		result["nativeOwnerInstanceId"] = static_cast<int64_t>(get_instance_id());
		result["sourceIdentity"] = identity_dictionary(state_->source_identity());
		result["nativeCatalogSchemaRevision"] = static_cast<int64_t>(NativeBiomeEnvironmentCatalog::SCHEMA_REVISION);
		result["nativeCatalogIdentity"] = text(native_identity);
		result["profileCount"] = static_cast<int64_t>(biome_catalog_->profiles().size());
		result["fallbackId"] = text(biome_catalog_->fallback_id());
		return result;
	} catch (const std::exception &error) {
		return failure(operation, error);
	}
}

Dictionary NativeWorldBackend::admit_visual_asset_catalog(const Dictionary &p_bundle) {
	constexpr const char *operation = "admit_visual_asset_catalog";
	if (!state_ || !shaping_registry_ || !biome_catalog_) {
		return envelope(operation, "failed", "native_biome_catalog_not_ready");
	}
	visual_catalog_.reset();
	visual_capture_owner_id_ = 0;
	visual_capture_revision_ = 0;
	visual_capture_identity_.clear();
	wildlife_presentations_.reset();
	presentation_capture_owner_id_ = 0;
	presentation_capture_revision_ = 0;
	presentation_capture_identity_.clear();
	try {
		require_exact_keys(p_bundle, {"ok", "schemaVersion", "complete", "scope", "ownerInstanceId",
			"seed", "biome", "visual", "presentation", "removed"}, "surface owner bundle");
		if (!require_bool(p_bundle["ok"], "bundle.ok")
				|| require_i64(p_bundle["schemaVersion"], "bundle.schemaVersion") != 1
				|| require_bool(p_bundle["complete"], "bundle.complete")
				|| require_bounded_utf8(p_bundle["scope"], "bundle.scope", 128U, false)
					!= "owner_catalogs_and_removals_only") {
			throw std::invalid_argument("unsupported surface owner bundle");
		}
		const std::int64_t main_id = require_i64(p_bundle["ownerInstanceId"], "bundle.ownerInstanceId");
		if (main_id == 0 || require_bounded_utf8(p_bundle["seed"], "bundle.seed",
				MAX_SEED_TEXT_BYTES, false) != state_->definition().raw_terrain_seed().utf8) {
			throw std::invalid_argument("surface owner bundle does not match native world seed");
		}
		const Dictionary biome = require_dictionary(p_bundle["biome"], "bundle.biome");
		const Dictionary biome_owner = require_dictionary(biome.get("ownerReceipt", Variant()), "bundle.biome.ownerReceipt");
		require_exact_keys(biome_owner, {"owner_id", "revision", "ready"}, "bundle.biome.ownerReceipt");
		if (!require_bool(biome.get("ok", Variant()), "bundle.biome.ok")
				|| require_i64(biome_owner["owner_id"], "bundle.biome.owner_id") != biome_capture_owner_id_
				|| require_i64(biome_owner["revision"], "bundle.biome.revision") != biome_capture_revision_
				|| !require_bool(biome_owner["ready"], "bundle.biome.ready")
				|| require_bounded_utf8(biome.get("contentIdentity", Variant()), "bundle.biome.contentIdentity", 64U, false)
					!= biome_capture_identity_) {
			throw std::invalid_argument("bundle biome generation differs from admitted native catalog");
		}
		const Dictionary visual = require_dictionary(p_bundle["visual"], "bundle.visual");
		require_exact_keys(visual, {"ok", "schemaVersion", "ownerReceipt", "contentIdentity",
			"assets", "families", "disabledIds", "sceneCache"}, "bundle.visual");
		if (!require_bool(visual["ok"], "bundle.visual.ok")
				|| require_i64(visual["schemaVersion"], "bundle.visual.schemaVersion") != 1) {
			throw std::invalid_argument("unsupported visual capture schema");
		}
		const Dictionary owner = require_dictionary(visual["ownerReceipt"], "bundle.visual.ownerReceipt");
		require_exact_keys(owner, {"owner_id", "revision", "ready", "catalog"}, "bundle.visual.ownerReceipt");
		const std::int64_t owner_id = require_i64(owner["owner_id"], "bundle.visual.owner_id");
		const std::int64_t revision = require_i64(owner["revision"], "bundle.visual.revision");
		if (owner_id == 0 || revision <= 0 || !require_bool(owner["ready"], "bundle.visual.ready")
				|| require_dictionary(owner["catalog"], "bundle.visual.catalog") != biome_owner) {
			throw std::invalid_argument("visual registry generation differs from admitted biome generation");
		}
		const Array assets = require_array(visual["assets"], "bundle.visual.assets");
		const Array families = require_array(visual["families"], "bundle.visual.families");
		const Array disabled = require_array(visual["disabledIds"], "bundle.visual.disabledIds");
		const Array cache = require_array(visual["sceneCache"], "bundle.visual.sceneCache");
		if (assets.is_empty() || assets.size() > 65536 || families.size() > 65536
				|| disabled.size() > 65536 || cache.size() > 65536) {
			throw std::length_error("visual capture exceeds native catalog capacity");
		}
		Dictionary canonical;
		canonical["domain"] = "visual_asset_registry_active_values";
		canonical["schemaVersion"] = 1;
		canonical["assets"] = assets;
		canonical["families"] = families;
		canonical["disabledIds"] = disabled;
		canonical["sceneCache"] = cache;
		const std::string identity = require_bounded_utf8(visual["contentIdentity"],
			"bundle.visual.contentIdentity", 64U, false);
		const std::string canonical_text = utf8(JSON::stringify(canonical));
		if (identity != sha256_hex(sha256(reinterpret_cast<const std::uint8_t *>(canonical_text.data()), canonical_text.size()))) {
			throw std::invalid_argument("visual capture content identity mismatch");
		}
		std::vector<NativeSurfaceRockAssetRecord> typed_assets;
		typed_assets.reserve(static_cast<std::size_t>(assets.size()));
		std::string previous_id;
		for (const Variant &entry : assets) {
			const Dictionary row = require_dictionary(entry, "bundle.visual.assets[]");
			require_exact_keys(row, {"id", "value"}, "bundle.visual.assets[]");
			const Dictionary value = require_dictionary(row["value"], "bundle.visual.assets[].value");
			NativeSurfaceRockAssetRecord asset;
			asset.id = require_bounded_utf8(row["id"], "asset.id", 4096U, false);
			if (asset.id != require_bounded_utf8(value.get("id", Variant()), "asset.value.id", 4096U, false)
					|| (!previous_id.empty() && !(previous_id < asset.id))) {
				throw std::invalid_argument("visual asset ID map is not canonical");
			}
			previous_id = asset.id;
			asset.family = require_bounded_utf8(value.get("family", Variant()), "asset.family", 4096U, false);
			asset.path = require_bounded_utf8(value.get("path", Variant()), "asset.path", 4096U, false);
			const Array tags = require_array(value.get("biomeTags", Array()), "asset.biomeTags");
			if (tags.size() > 256) throw std::length_error("asset biome tags exceed capacity");
			for (const Variant &tag : tags)
				asset.biome_tags.push_back(require_bounded_utf8(tag, "asset.biomeTags[]", 4096U, false));
			const Dictionary bounds = require_dictionary(value.get("boundingBox", Dictionary()), "asset.boundingBox");
			const Array size = require_array(bounds.get("size", Array()), "asset.boundingBox.size");
			// VisualAssetRegistry.asset_size returns Vector3.ONE for fewer than
			// three lanes, and ignores lanes beyond the first three.
			if (size.size() >= 3) {
				asset.size_x = require_number(size[0], "asset.size.x");
				asset.size_y = require_number(size[1], "asset.size.y");
				asset.size_z = require_number(size[2], "asset.size.z");
			}
			typed_assets.push_back(std::move(asset));
		}
		std::vector<NativeSurfaceRockFamilyMembers> typed_families;
		typed_families.reserve(static_cast<std::size_t>(families.size()));
		std::string previous_family;
		for (const Variant &entry : families) {
			const Dictionary row = require_dictionary(entry, "bundle.visual.families[]");
			require_exact_keys(row, {"family", "orderedIds"}, "bundle.visual.families[]");
			NativeSurfaceRockFamilyMembers members;
			members.family = require_bounded_utf8(row["family"], "family.name", 4096U, false);
			if (!previous_family.empty() && !(previous_family < members.family))
				throw std::invalid_argument("visual family map is not canonical");
			previous_family = members.family;
			const Array ids = require_array(row["orderedIds"], "family.orderedIds");
			if (ids.size() > 65536) throw std::length_error("family members exceed capacity");
			for (const Variant &id : ids)
				members.ordered_ids.push_back(require_bounded_utf8(id, "family.orderedIds[]", 4096U, false));
			typed_families.push_back(std::move(members));
		}
		auto typed = NativeSurfaceRockAssetCatalog::create_effective(
			std::move(typed_assets), std::move(typed_families), *biome_catalog_);
		const std::string native_identity = sha256_hex(typed.content_digest());
		const std::uint64_t asset_count = static_cast<std::uint64_t>(assets.size());
		visual_catalog_ = std::make_unique<NativeSurfaceRockAssetCatalog>(std::move(typed));
		visual_capture_owner_id_ = owner_id;
		visual_capture_revision_ = revision;
		visual_capture_identity_ = identity;
		Dictionary result = envelope(operation, "ready");
		result["receiptSchema"] = VISUAL_CATALOG_RECEIPT_SCHEMA;
		result["scope"] = "effective_rock_selection_inputs_only";
		result["completeSurfacePropSource"] = false;
		result["importReadinessProven"] = false;
		result["liveCaptureFreshnessProven"] = false;
		result["bundleOwnerInstanceId"] = main_id;
		result["captureOwnerInstanceId"] = owner_id;
		result["captureRevision"] = revision;
		result["captureContentIdentity"] = text(identity);
		result["nativeOwnerInstanceId"] = static_cast<int64_t>(get_instance_id());
		result["sourceIdentity"] = identity_dictionary(state_->source_identity());
		result["biomeCatalogIdentity"] = text(sha256_hex(biome_catalog_->content_digest()));
		result["nativeCatalogIdentity"] = text(native_identity);
		result["assetCount"] = static_cast<int64_t>(asset_count);
		return result;
	} catch (const std::exception &error) {
		return failure(operation, error);
	}
}

Dictionary NativeWorldBackend::select_rock_asset_shadow(
		const String &p_biome, const String &p_durable_prop_id) const {
	constexpr const char *operation = "select_rock_asset_shadow";
	if (!visual_catalog_) return envelope(operation, "failed", "native_visual_catalog_not_ready");
	try {
		const NativeSurfaceRockAssetSelection selected = visual_catalog_->select(
			bounded_utf8(p_biome, 4096U, "biome", false),
			bounded_utf8(p_durable_prop_id, 4096U, "durablePropId", false));
		Dictionary result = envelope(operation, "ready");
		result["assetId"] = text(selected.asset_id);
		result["assetPath"] = text(selected.asset_path);
		result["assetSize"] = Vector3(selected.asset_size.x, selected.asset_size.y, selected.asset_size.z);
		result["candidateCount"] = static_cast<int64_t>(selected.candidate_count);
		result["matchedBiomeTag"] = selected.matched_biome_tag;
		result["resolvedProfileBiome"] = text(selected.resolved_profile_biome);
		result["nativeCatalogIdentity"] = text(sha256_hex(selected.asset_catalog_digest));
		return result;
	} catch (const std::exception &error) {
		return failure(operation, error);
	}
}

Dictionary NativeWorldBackend::admit_wildlife_presentation_catalog(const Dictionary &p_bundle) {
	constexpr const char *operation = "admit_wildlife_presentation_catalog";
	if (!state_ || !biome_catalog_ || !visual_catalog_ || !removed_props_) {
		return envelope(operation, "failed", "surface_owner_sources_not_ready");
	}
	wildlife_presentations_.reset();
	presentation_capture_owner_id_ = 0;
	presentation_capture_revision_ = 0;
	presentation_capture_identity_.clear();
	try {
		require_exact_keys(p_bundle, {"ok", "schemaVersion", "complete", "scope", "ownerInstanceId",
			"seed", "biome", "visual", "presentation", "removed"}, "surface owner bundle");
		if (!require_bool(p_bundle["ok"], "bundle.ok")
				|| require_i64(p_bundle["schemaVersion"], "bundle.schemaVersion") != 1
				|| require_bool(p_bundle["complete"], "bundle.complete")
				|| require_bounded_utf8(p_bundle["scope"], "bundle.scope", 128U, false)
					!= "owner_catalogs_and_removals_only") {
			throw std::invalid_argument("unsupported surface owner bundle");
		}
		const std::int64_t main_id = require_i64(p_bundle["ownerInstanceId"], "bundle.ownerInstanceId");
		if (main_id == 0 || main_id != removed_capture_owner_id_
				|| require_bounded_utf8(p_bundle["seed"], "bundle.seed", MAX_SEED_TEXT_BYTES, false)
					!= state_->definition().raw_terrain_seed().utf8) {
			throw std::invalid_argument("surface owner bundle does not match admitted removals or world seed");
		}
		const Dictionary biome = require_dictionary(p_bundle["biome"], "bundle.biome");
		const Dictionary visual = require_dictionary(p_bundle["visual"], "bundle.visual");
		const Dictionary removed = require_dictionary(p_bundle["removed"], "bundle.removed");
		const Dictionary biome_owner = require_dictionary(biome.get("ownerReceipt", Variant()), "bundle.biome.ownerReceipt");
		const Dictionary visual_owner = require_dictionary(visual.get("ownerReceipt", Variant()), "bundle.visual.ownerReceipt");
		if (!require_bool(biome.get("ok", Variant()), "bundle.biome.ok")
				|| require_bounded_utf8(biome.get("contentIdentity", Variant()), "bundle.biome.contentIdentity", 64U, false)
					!= biome_capture_identity_
				|| require_i64(biome_owner.get("owner_id", Variant()), "bundle.biome.owner_id") != biome_capture_owner_id_
				|| require_i64(biome_owner.get("revision", Variant()), "bundle.biome.revision") != biome_capture_revision_
				|| !require_bool(visual.get("ok", Variant()), "bundle.visual.ok")
				|| require_bounded_utf8(visual.get("contentIdentity", Variant()), "bundle.visual.contentIdentity", 64U, false)
					!= visual_capture_identity_
				|| require_i64(visual_owner.get("owner_id", Variant()), "bundle.visual.owner_id") != visual_capture_owner_id_
				|| require_i64(visual_owner.get("revision", Variant()), "bundle.visual.revision") != visual_capture_revision_
				|| !require_bool(removed.get("ok", Variant()), "bundle.removed.ok")
				|| require_i64(removed.get("ownerInstanceId", Variant()), "bundle.removed.ownerInstanceId") != main_id
				|| require_bounded_utf8(removed.get("seed", Variant()), "bundle.removed.seed", MAX_SEED_TEXT_BYTES, false)
					!= state_->definition().raw_terrain_seed().utf8
				|| require_i64(removed.get("revision", Variant()), "bundle.removed.revision") != removed_capture_revision_
				|| require_bounded_utf8(removed.get("contentIdentity", Variant()), "bundle.removed.contentIdentity", 64U, false)
					!= removed_capture_identity_) {
			throw std::invalid_argument("surface owner bundle differs from admitted native generations");
		}
		const Dictionary capture = require_dictionary(p_bundle["presentation"], "bundle.presentation");
		require_exact_keys(capture, {"ok", "schemaVersion", "ownerReceipt", "contentIdentity", "assets"},
			"bundle.presentation");
		if (!require_bool(capture["ok"], "bundle.presentation.ok")
				|| require_i64(capture["schemaVersion"], "bundle.presentation.schemaVersion") != 1) {
			throw std::invalid_argument("unsupported animated presentation capture");
		}
		const Dictionary owner = require_dictionary(capture["ownerReceipt"], "bundle.presentation.ownerReceipt");
		require_exact_keys(owner, {"ownerInstanceId", "revision", "ready"}, "bundle.presentation.ownerReceipt");
		const std::int64_t owner_id = require_i64(owner["ownerInstanceId"], "bundle.presentation.ownerInstanceId");
		const std::int64_t revision = require_i64(owner["revision"], "bundle.presentation.revision");
		if (owner_id == 0 || revision <= 0 || !require_bool(owner["ready"], "bundle.presentation.ready")) {
			throw std::invalid_argument("animated presentation owner is not ready");
		}
		const Array assets = require_array(capture["assets"], "bundle.presentation.assets");
		if (assets.is_empty() || assets.size() > 256) throw std::length_error("animated presentation assets exceed capacity");
		Dictionary canonical;
		canonical["domain"] = "animated_asset_registry_presentation";
		canonical["schemaVersion"] = 1;
		canonical["assets"] = assets;
		const std::string identity = require_bounded_utf8(capture["contentIdentity"],
			"bundle.presentation.contentIdentity", 64U, false);
		const std::string canonical_text = utf8(JSON::stringify(canonical));
		const Sha256Digest digest = sha256(reinterpret_cast<const std::uint8_t *>(canonical_text.data()), canonical_text.size());
		if (identity != sha256_hex(digest)) throw std::invalid_argument("animated presentation content identity mismatch");
		std::array<NativeWildlifePresentationReceipt, 3> receipts{};
		const char *const canonical_ids[] = {"boar_idle_walk", "deer_idle_walk", "hare_idle_walk"};
		for (std::size_t index = 0U; index < receipts.size(); ++index) {
			receipts[index].schema_revision = 1U;
			receipts[index].asset_catalog_digest = digest;
			receipts[index].variant = static_cast<NativeWildlifeVariant>(index + 1U);
			receipts[index].asset_id = canonical_ids[index];
			receipts[index].animation_clip_id = canonical_ids[index];
			receipts[index].path = NativeWildlifePresentationPath::procedural_fallback;
		}
		std::string previous_id;
		for (const Variant &entry : assets) {
			const Dictionary row = require_dictionary(entry, "bundle.presentation.assets[]");
			require_exact_keys(row, {"id", "definition", "sceneResourcePath", "sceneInstanceId",
				"animationPlayerPath", "availableClips"}, "bundle.presentation.assets[]");
			const std::string id = require_bounded_utf8(row["id"], "presentation.asset.id", 4096U, false);
			if (!previous_id.empty() && !(previous_id < id))
				throw std::invalid_argument("animated presentation IDs are not canonical");
			previous_id = id;
			const Dictionary definition = require_dictionary(row["definition"], "presentation.asset.definition");
			const std::string expected = require_bounded_utf8(definition.get("expected", Variant()),
				"presentation.asset.expected", 4096U, false);
			if (id != require_bounded_utf8(definition.get("id", Variant()), "presentation.asset.definition.id", 4096U, false)
					|| require_bounded_utf8(definition.get("path", Variant()), "presentation.asset.path", 4096U, false)
						!= require_bounded_utf8(row["sceneResourcePath"], "presentation.asset.sceneResourcePath", 4096U, false)
					|| require_i64(row["sceneInstanceId"], "presentation.asset.sceneInstanceId") == 0
					|| require_bounded_utf8(row["animationPlayerPath"], "presentation.asset.animationPlayerPath", 4096U, false).empty()) {
				throw std::invalid_argument("animated presentation asset scene is incoherent");
			}
			const Array clips = require_array(row["availableClips"], "presentation.asset.availableClips");
			if (clips.size() > 256) throw std::length_error("animated presentation clip list exceeds capacity");
			bool has_expected = false;
			for (const Variant &clip : clips)
				if (require_bounded_utf8(clip, "presentation.asset.availableClips[]", 4096U, false) == expected)
					has_expected = true;
			if (!has_expected) throw std::invalid_argument("animated presentation expected clip is unavailable");
			for (std::size_t index = 0U; index < receipts.size(); ++index) {
				if (id == canonical_ids[index]) {
					if (expected != canonical_ids[index])
						throw std::invalid_argument("wildlife canonical animation differs from active asset");
					receipts[index].path = NativeWildlifePresentationPath::animated_playable;
				}
			}
		}
		auto typed = NativeWildlifePresentationCatalog::create(receipts);
		wildlife_presentations_ = std::make_unique<NativeWildlifePresentationCatalog>(std::move(typed));
		presentation_capture_owner_id_ = owner_id;
		presentation_capture_revision_ = revision;
		presentation_capture_identity_ = identity;
		Dictionary result = envelope(operation, "ready");
		result["receiptSchema"] = WILDLIFE_PRESENTATION_RECEIPT_SCHEMA;
		result["scope"] = "animated_wildlife_capabilities_only";
		result["completeSurfacePropSource"] = false;
		result["liveCaptureFreshnessProven"] = false;
		result["bundleOwnerInstanceId"] = main_id;
		result["captureOwnerInstanceId"] = owner_id;
		result["captureRevision"] = revision;
		result["captureContentIdentity"] = text(identity);
		result["nativeOwnerInstanceId"] = static_cast<int64_t>(get_instance_id());
		result["sourceIdentity"] = identity_dictionary(state_->source_identity());
		result["variantCount"] = static_cast<int64_t>(receipts.size());
		return result;
	} catch (const std::exception &error) {
		return failure(operation, error);
	}
}

Dictionary NativeWorldBackend::wildlife_presentation_shadow(const String &p_variant) const {
	constexpr const char *operation = "wildlife_presentation_shadow";
	if (!wildlife_presentations_) return envelope(operation, "failed", "wildlife_presentation_not_ready");
	try {
		const std::string name = bounded_utf8(p_variant, 32U, "variant", false);
		NativeWildlifeVariant variant;
		if (name == "boar") variant = NativeWildlifeVariant::boar;
		else if (name == "deer") variant = NativeWildlifeVariant::deer;
		else if (name == "hare") variant = NativeWildlifeVariant::hare;
		else throw std::invalid_argument("unsupported wildlife variant");
		const auto receipt = wildlife_presentations_->resolve(variant);
		Dictionary result = envelope(operation, "ready");
		result["variant"] = text(name);
		result["assetId"] = text(receipt.asset_id);
		result["animationClipId"] = text(receipt.animation_clip_id);
		result["presentationPath"] = receipt.path == NativeWildlifePresentationPath::animated_playable
			? "animated_playable" : "procedural_fallback";
		result["captureContentIdentity"] = text(presentation_capture_identity_);
		return result;
	} catch (const std::exception &error) {
		return failure(operation, error);
	}
}

Dictionary NativeWorldBackend::admit_removed_props_tombstones(const Dictionary &p_capture) {
	if (!state_ || !shaping_registry_) {
		return envelope("admit_removed_props_tombstones", "failed", "backend_not_ready");
	}
	wildlife_presentations_.reset();
	presentation_capture_owner_id_ = 0;
	presentation_capture_revision_ = 0;
	presentation_capture_identity_.clear();
	removed_props_.reset();
	removed_capture_owner_id_ = 0;
	removed_capture_revision_ = 0;
	removed_capture_identity_.clear();
	removed_fd1_identity_.clear();
	try {
		require_exact_keys(p_capture,
			{"ok", "schemaVersion", "ownerInstanceId", "seed", "revision", "ids", "contentIdentity"},
			"removed props capture");
		if (!require_bool(p_capture["ok"], "capture.ok")
				|| require_i64(p_capture["schemaVersion"], "capture.schemaVersion") != 1) {
			throw std::invalid_argument("unsupported removed props capture schema");
		}
		const std::int64_t owner_id = require_i64(p_capture["ownerInstanceId"], "capture.ownerInstanceId");
		const std::int64_t revision = require_i64(p_capture["revision"], "capture.revision");
		// Godot instance IDs use all 64 bits; valid IDs may appear negative
		// when represented by Variant::INT. Zero alone is the absent sentinel.
		if (owner_id == 0 || revision < 0) {
			throw std::invalid_argument("invalid removed props capture owner or revision");
		}
		const std::string seed = require_bounded_utf8(
			p_capture["seed"], "capture.seed", MAX_SEED_TEXT_BYTES, false);
		if (seed != state_->definition().raw_terrain_seed().utf8) {
			throw std::invalid_argument("removed props capture seed does not match native world source");
		}
		const Array ids = require_array(p_capture["ids"], "capture.ids");
		if (static_cast<std::size_t>(ids.size()) > NativeFeatureDeltaLimits::MAX_TOMBSTONES) {
			throw std::length_error("removed props capture exceeds tombstone capacity");
		}
		std::vector<NativeFeatureTombstone> tombstones;
		tombstones.reserve(static_cast<std::size_t>(ids.size()));
		std::vector<std::uint8_t> capture_bytes;
		std::string previous_id;
		for (int64_t index = 0; index < ids.size(); ++index) {
			std::string id = require_bounded_utf8(ids[index], "capture.ids[]",
				NativeFeatureDeltaLimits::MAX_ID_BYTES, false);
			if (index > 0 && !std::lexicographical_compare(previous_id.begin(), previous_id.end(),
					id.begin(), id.end(), [](char left, char right) {
						return static_cast<unsigned char>(left) < static_cast<unsigned char>(right);
					})) {
				throw std::invalid_argument("removed props capture IDs must be strictly ordered");
			}
			previous_id = id;
			const std::uint32_t size = static_cast<std::uint32_t>(id.size());
			// ActiveRemovedPropsSnapshot hashes little-endian u32 lengths.
			for (unsigned shift = 0; shift < 32U; shift += 8U) {
				capture_bytes.push_back(static_cast<std::uint8_t>((size >> shift) & 0xffU));
			}
			capture_bytes.insert(capture_bytes.end(), id.begin(), id.end());
			tombstones.push_back({std::move(id)});
		}
		const std::string claimed_identity = require_bounded_utf8(
			p_capture["contentIdentity"], "capture.contentIdentity", 64U, false);
		if (claimed_identity != sha256_hex(sha256(capture_bytes))) {
			throw std::invalid_argument("removed props capture content identity mismatch");
		}
		// FD1 admission validates UTF-8, uniqueness and canonical byte ordering.
		NativeFeatureDeltaSnapshot typed = NativeFeatureDeltaSnapshot::create(
			std::move(tombstones), {});
		const std::string fd1_identity = sha256_hex(sha256(typed.canonical_binary()));
		const std::int64_t tombstone_count = static_cast<std::int64_t>(typed.tombstones().size());
		removed_props_ = std::make_unique<NativeFeatureDeltaSnapshot>(std::move(typed));
		removed_capture_owner_id_ = owner_id;
		removed_capture_revision_ = revision;
		removed_capture_identity_ = claimed_identity;
		removed_fd1_identity_ = fd1_identity;
		Dictionary result = envelope("admit_removed_props_tombstones", "ready");
		result["receiptSchema"] = REMOVED_PROPS_RECEIPT_SCHEMA;
		result["scope"] = "removed_prop_tombstones_only";
		result["completeFeatureManifest"] = false;
		result["liveCaptureFreshnessProven"] = false;
		result["captureOwnerInstanceId"] = owner_id;
		result["captureRevision"] = revision;
		result["captureContentIdentity"] = text(claimed_identity);
		result["nativeOwnerInstanceId"] = static_cast<int64_t>(get_instance_id());
		result["sourceIdentity"] = identity_dictionary(state_->source_identity());
		result["tombstoneCount"] = tombstone_count;
		result["fd1Identity"] = text(fd1_identity);
		return result;
	} catch (const std::exception &error) {
		return failure("admit_removed_props_tombstones", error);
	}
}

Dictionary NativeWorldBackend::admit_structure_exclusion_chunk(const Dictionary &p_capture) const {
	constexpr const char *operation = "admit_structure_exclusion_chunk";
	if (!state_ || !shaping_registry_) return envelope(operation, "failed", "backend_not_ready");
	try {
		require_exact_keys(p_capture, {"ok", "schemaVersion", "scope", "ownerInstanceId",
			"ownerGeneration", "exclusionRevision", "admissionSeed", "admissionGeneration",
			"chunk", "bounds", "boundsAdmission", "content", "contentIdentity"},
			"structure exclusion capture");
		if (!require_bool(p_capture["ok"], "capture.ok")
				|| require_i64(p_capture["schemaVersion"], "capture.schemaVersion") != 1
				|| require_bounded_utf8(p_capture["scope"], "capture.scope", 64U, false)
					!= "admitted_structure_exclusion_chunk_only")
			throw std::invalid_argument("unsupported structure exclusion capture schema");
		const std::int64_t owner_id = require_i64(p_capture["ownerInstanceId"], "capture.ownerInstanceId");
		const std::int64_t generation = require_i64(p_capture["ownerGeneration"], "capture.ownerGeneration");
		const std::int64_t revision = require_i64(p_capture["exclusionRevision"], "capture.exclusionRevision");
		const std::int64_t admission_generation = require_i64(p_capture["admissionGeneration"], "capture.admissionGeneration");
		if (owner_id == 0 || generation <= 0 || revision < 0 || admission_generation <= 0)
			throw std::invalid_argument("structure exclusion capture owner identity is invalid");
		const std::string seed = require_bounded_utf8(p_capture["admissionSeed"],
			"capture.admissionSeed", MAX_SEED_TEXT_BYTES, false);
		if (seed != state_->definition().raw_terrain_seed().utf8)
			throw std::invalid_argument("structure exclusion capture seed differs from native source");
		const Vector2i chunk = require_vector2i(p_capture["chunk"], "capture.chunk");
		if (p_capture["bounds"].get_type() != Variant::RECT2I)
			throw std::invalid_argument("structure exclusion bounds must be a Rect2i");
		const Rect2i bounds = p_capture["bounds"];
		const std::int64_t start_x = static_cast<std::int64_t>(chunk.x) * 28;
		const std::int64_t start_z = static_cast<std::int64_t>(chunk.y) * 28;
		if (start_x < -1000000 || start_z < -1000000 || start_x + 28 > 1000000
				|| start_z + 28 > 1000000 || bounds.position.x != start_x
				|| bounds.position.y != start_z || bounds.size != Vector2i(28, 28))
			throw std::invalid_argument("structure exclusion chunk bounds do not match the admitted page");
		const Dictionary bounds_admission = require_dictionary(p_capture["boundsAdmission"],
			"capture.boundsAdmission");
		if (require_bounded_utf8(bounds_admission.get("status", Variant()),
				"capture.boundsAdmission.status", 16U, false) != "ready")
			throw std::invalid_argument("structure exclusion bounds are not ready");
		const Dictionary content = require_dictionary(p_capture["content"], "capture.content");
		require_exact_keys(content, {"natural", "terrain", "citadel"}, "structure exclusion content");
		std::vector<StructureExclusionRecord> natural = structure_records(content["natural"], "content.natural");
		std::vector<StructureExclusionRecord> terrain = structure_records(content["terrain"], "content.terrain");
		std::vector<CitadelExclusionSource> citadels = structure_citadels(content["citadel"]);
		const std::string claimed = require_bounded_utf8(p_capture["contentIdentity"],
			"capture.contentIdentity", 64U, false);
		Array identity_value;
		identity_value.append(chunk);
		identity_value.append(bounds);
		identity_value.append(content);
		const String actual = Marshalls::get_singleton()->raw_to_base64(
			UtilityFunctions::var_to_bytes(identity_value)).sha256_text();
		if (claimed != utf8(actual))
			throw std::invalid_argument("structure exclusion capture content identity mismatch");
		std::vector<StructureExclusionBoundsAdmission> admissions{{
			static_cast<std::int32_t>(start_x), static_cast<std::int32_t>(start_z), true}};
		auto snapshot = std::make_unique<NativeStructureExclusionSnapshot>(
			NativeStructureExclusionSnapshot::create(state_->source_identity().digest,
				static_cast<std::uint64_t>(generation), std::move(natural), std::move(terrain),
				std::move(citadels), std::move(admissions)));
		if (!snapshot->covers_decided_regions(bounds.position.x, bounds.position.y,
				bounds.position.x + 27, bounds.position.y + 27))
			throw std::invalid_argument("structure exclusion capture lacks decided Citadel rows");
		Ref<NativeStructureExclusionChunk> admitted;
		admitted.instantiate();
		admitted->admit(std::move(snapshot), chunk, owner_id, revision, admission_generation, claimed);
		Dictionary result = envelope(operation, "ready");
		result["snapshot"] = admitted;
		result["snapshotStatus"] = admitted->status();
		return result;
	} catch (const std::exception &error) {
		return failure(operation, error);
	}
}

Dictionary NativeWorldBackend::compose_surface_prop_ordered_shadow(
		const Ref<NativeEffectiveTerrainPage> &p_page,
		const Ref<NativeStructureExclusionChunk> &p_exclusions) const {
	constexpr const char *operation = "compose_surface_prop_ordered_shadow";
	if (!state_ || !shaping_registry_ || !biome_catalog_ || !removed_props_ || !visual_catalog_
			|| !wildlife_presentations_ || p_page.is_null() || p_exclusions.is_null()
			|| !p_page->batch_ || !p_exclusions->snapshot_)
		return envelope(operation, "failed", "ordered_surface_sources_not_ready");
	try {
		const WorldSourcePin &pin = p_page->batch_->pin();
		if (!(pin.definition().physical_content_identity() == state_->source_identity())
				|| pin.terrain_delta_revision() != state_->terrain_delta_revision()
				|| pin.shaping_registry_revision() != shaping_registry_->revision()
				|| !(pin.shaping_registry_content_identity() == shaping_registry_->content_identity())
				|| p_exclusions->snapshot_->world_digest() != state_->source_identity().digest)
			throw std::invalid_argument("ordered surface pin or exclusions are stale");
		const NativeEffectiveTerrainSource terrain(pin);
		const NativeSurfacePropSourceOrderedStream ordered = NativeSurfacePropSourceOrderedStream::create(
			state_->definition().raw_terrain_seed(), p_exclusions->chunk_.x, p_exclusions->chunk_.y,
			state_->source_identity().digest, p_exclusions->snapshot_->world_generation(),
			terrain, *biome_catalog_, *p_exclusions->snapshot_, *removed_props_, *wildlife_presentations_);
		const NativeSurfacePropOrderedPlacement placement = NativeSurfacePropOrderedPlacement::create(ordered, terrain);
		Array attempts;
		Array tree_halo_requests;
		for (std::size_t index = 0; index < ordered.attempts().size(); ++index) {
			const NativeSurfacePropOrderedAttempt &source = ordered.attempts()[index];
			const NativeSurfacePropPlacementEntry &placed = placement.entries()[index];
			Dictionary row;
			row["ordinal"] = static_cast<std::int64_t>(source.attempt.ordinal);
			row["durableId"] = text(source.attempt.durable_id);
			row["cell"] = Vector2i(source.attempt.cell_x, source.attempt.cell_z);
			row["parentTombstoned"] = source.parent_tombstoned;
			row["outcome"] = static_cast<std::int64_t>(source.outcome);
			row["stateBeforeCoordinates"] = text(std::to_string(source.state_before_coordinates));
			row["stateAfterRecipe"] = text(std::to_string(source.state_after_recipe));
			row["sourceBiome"] = source.source ? text(source.source->biome_id) : String();
			row["sourceHeightMeters"] = source.source && source.source->has_surface
				? source.source->surface.height_meters : 0.0;
			row["presence"] = static_cast<std::int64_t>(placed.presence);
			row["worldAnchor"] = Vector3(placed.world_anchor.x, placed.world_anchor.y,
				placed.world_anchor.z);
			if (source.outcome == NativeSurfacePropClassificationOutcome::forage_recipe) {
				const NativeSurfaceForageOrderedDefinition forage =
					NativeSurfaceForageOrderedDefinition::create(ordered, placement,
						static_cast<std::uint32_t>(index), terrain, *biome_catalog_);
				Dictionary feature;
				feature["kind"] = "forage";
				feature["contentIdentity"] = text(sha256_hex(forage.content_digest()));
				feature["recipeId"] = text(forage.recipe().recipe_id);
				feature["materialId"] = text(forage.recipe().material_id);
				feature["dropId"] = text(forage.recipe().drop_id);
				feature["dropCount"] = forage.drop_count();
				feature["rotationY"] = forage.rotation_y();
				feature["colliderRadius"] = forage.collider_radius();
				feature["colliderCenterY"] = forage.collider_center_y();
				feature["physicalColliderPresent"] = forage.physical_collider_present();
				feature["navigationBlocker"] = forage.navigation_blocker();
				Array meshes;
				for (const NativeForageMesh &mesh : forage.meshes()) {
					Dictionary visual;
					visual["kind"] = static_cast<std::int64_t>(mesh.kind);
					visual["position"] = Vector3(mesh.position.x, mesh.position.y, mesh.position.z);
					visual["rotation"] = Vector3(mesh.rotation.x, mesh.rotation.y, mesh.rotation.z);
					visual["scale"] = Vector3(mesh.scale.x, mesh.scale.y, mesh.scale.z);
					visual["radius"] = mesh.radius;
					visual["height"] = mesh.height;
					visual["topRadius"] = mesh.top_radius;
					visual["bottomRadius"] = mesh.bottom_radius;
					visual["radialSegments"] = mesh.radial_segments;
					visual["rings"] = mesh.rings;
					visual["materialId"] = text(mesh.material_id);
					meshes.append(visual);
				}
				feature["meshes"] = meshes;
				row["feature"] = feature;
			}
			if (source.outcome == NativeSurfacePropClassificationOutcome::unported_iron_ore_cluster
					|| source.outcome == NativeSurfacePropClassificationOutcome::unported_copper_ore_cluster) {
				const NativeSurfaceOreClusterDefinition ore = NativeSurfaceOreClusterDefinition::create(
					ordered, placement, static_cast<std::uint32_t>(index), terrain);
				Dictionary feature;
				feature["kind"] = "oreCluster";
				feature["oreKind"] = static_cast<std::int64_t>(ore.kind());
				feature["rootDurableId"] = text(ore.root_durable_id());
				feature["contentIdentity"] = text(sha256_hex(ore.content_digest()));
				Array children;
				for (const NativeSurfaceOreChildDefinition &child : ore.children())
					children.append(ore_child_shadow(child));
				feature["children"] = children;
				row["feature"] = feature;
			}
			if (source.outcome == NativeSurfacePropClassificationOutcome::wildlife_recipe) {
				const NativeSurfaceWildlifeOrderedDefinition wildlife =
					NativeSurfaceWildlifeOrderedDefinition::create(ordered, placement,
						static_cast<std::uint32_t>(index), terrain, *biome_catalog_, *wildlife_presentations_);
				const NativeWildlifeStream &stream = wildlife.stream();
				const NativeWildlifeDecodedConstruction &built = wildlife.construction();
				Dictionary feature;
				feature["kind"] = "wildlife";
				feature["contentIdentity"] = text(sha256_hex(wildlife.content_digest()));
				feature["variant"] = static_cast<std::int64_t>(stream.recipe.variant);
				feature["materialId"] = text(stream.recipe.material_id);
				feature["primaryDropId"] = text(stream.recipe.primary_drop_id);
				feature["primaryDropCount"] = stream.primary_drop_count;
				feature["extraDropId"] = text(stream.recipe.extra_drop_id);
				feature["extraDropCount"] = stream.extra_drop_count;
				feature["cold"] = stream.cold;
				feature["bodyYaw"] = built.body_yaw;
				feature["colliderSize"] = wildlife_vector(built.collider_size);
				feature["colliderCenter"] = wildlife_vector(built.collider_center);
				feature["collisionLayer"] = static_cast<std::int64_t>(stream.recipe.collision_layer);
				feature["collisionMask"] = static_cast<std::int64_t>(stream.recipe.collision_mask);
				feature["presentationPath"] = static_cast<std::int64_t>(built.presentation_path);
				feature["assetId"] = text(stream.presentation.asset_id);
				feature["animationClipId"] = text(stream.presentation.animation_clip_id);
				feature["visualScale"] = wildlife_vector(built.visual_scale);
				feature["visualRotation"] = wildlife_vector(built.visual_rotation);
				feature["animationSpeedScale"] = built.animation_speed_scale;
				Array meshes;
				for (const NativeWildlifeMesh &mesh : built.procedural_meshes) {
					Dictionary visual;
					visual["kind"] = static_cast<std::int64_t>(mesh.kind);
					visual["position"] = wildlife_vector(mesh.position);
					visual["rotation"] = wildlife_vector(mesh.rotation);
					visual["scale"] = wildlife_vector(mesh.scale);
					visual["radius"] = mesh.radius;
					visual["height"] = mesh.height;
					visual["topRadius"] = mesh.top_radius;
					visual["bottomRadius"] = mesh.bottom_radius;
					visual["radialSegments"] = mesh.radial_segments;
					visual["rings"] = mesh.rings;
					visual["materialId"] = text(mesh.material_id);
					meshes.append(visual);
				}
				feature["proceduralMeshes"] = meshes;
				feature["movementHome"] = wildlife_vector(built.movement.home);
				feature["movementDirection"] = wildlife_vector(built.movement.direction);
				feature["movementTimer"] = built.movement.timer;
				feature["movementSpeed"] = built.movement.speed;
				feature["movementLastMove"] = built.movement.last_move;
				row["feature"] = feature;
			}
			if (source.outcome == NativeSurfacePropClassificationOutcome::ordinary_rock) {
				const NativeSurfaceRockOrderedVisualPlan rock = NativeSurfaceRockOrderedVisualPlan::create(
					ordered, placement, static_cast<std::uint32_t>(index), terrain, *visual_catalog_);
				const NativeSurfaceRockDefinitionInput &built = rock.definition().input();
				const NativeSurfaceRockAssetSelection &selected = rock.selection();
				Dictionary feature;
				feature["kind"] = "rock";
				feature["contentIdentity"] = text(sha256_hex(rock.definition().content_digest()));
				feature["durableId"] = text(built.durable_feature_id);
				feature["visualBiome"] = text(built.source_biome);
				feature["rotationY"] = built.rotation_y;
				feature["visualRadius"] = built.visual_radius;
				feature["visualHeightFactor"] = built.visual_height_factor;
				feature["visualScale"] = Vector3(built.visual_scale_x, built.visual_scale_y, built.visual_scale_z);
				feature["colliderRadius"] = built.collision.radius;
				feature["colliderCenterY"] = built.collision.center_y;
				feature["visualIntent"] = static_cast<std::int64_t>(rock.intent());
				feature["assetId"] = text(selected.asset_id);
				feature["assetPath"] = text(selected.asset_path);
				feature["assetSize"] = world_vector(selected.asset_size);
				feature["profileScale"] = selected.rock_scale;
				row["feature"] = feature;
			}
			if (source.outcome == NativeSurfacePropClassificationOutcome::tree_22_draw
					|| source.outcome == NativeSurfacePropClassificationOutcome::tree_36_draw) {
				const NativeSurfaceTreeEcologyProfile profile = native_surface_tree_profile_from_catalog(*biome_catalog_, source.source->biome_id);
				const NativeTreeDefinition tree = NativeSurfaceTreeOrderedComposer::create(
					ordered, placement, static_cast<std::uint32_t>(index), terrain, profile);
				const NativeTreeDefinitionInput &built = tree.input();
				const NativeTreeTrunkCylinder trunk = tree.trunk_cylinder();
				const NativeTreeExclusionMargins margins = native_tree_exclusion_margins(
					built.trunk_radius, built.canopy_radius, built.exclusion_margin,
					pin.definition().constants().cell_size_meters);
				Dictionary halo_request;
				halo_request["ordinal"] = static_cast<std::int64_t>(source.attempt.ordinal);
				halo_request["cell"] = Vector2i(source.attempt.cell_x, source.attempt.cell_z);
				halo_request["naturalMarginCells"] = margins.natural_cells;
				halo_request["structureMarginCells"] = margins.structure_cells;
				tree_halo_requests.append(halo_request);
				Dictionary feature;
				feature["kind"] = "treeDefinition";
				feature["contentIdentity"] = text(sha256_hex(tree.content_digest()));
				feature["durableId"] = text(built.durable_feature_id);
				feature["biome"] = text(built.biome);
				feature["family"] = text(built.family);
				feature["growthClass"] = text(built.growth_class);
				feature["architecture"] = static_cast<std::int64_t>(built.architecture);
				feature["speciesGrammar"] = text(built.species_grammar);
				feature["ageBand"] = text(built.age_band);
				feature["ageYears"] = built.ecology.age_years;
				feature["ageRangeMin"] = built.ecology.age_range_min;
				feature["ageRangeMax"] = built.ecology.age_range_max;
				feature["localMaturity"] = built.ecology.local_maturity;
				feature["growthStage"] = built.ecology.growth_stage;
				feature["geneticSeed"] = built.ecology.genetic_seed;
				Dictionary biome_parameters;
				biome_parameters["version"] = static_cast<std::int64_t>(built.biome_parameters.revision);
				biome_parameters["architecture"] = text(built.architecture == NativeTreeArchitecture::conifer ? "conifer"
					: built.architecture == NativeTreeArchitecture::savanna ? "savanna" : "broadleaf");
				biome_parameters["heightMin"] = built.biome_parameters.height_min;
				biome_parameters["heightMax"] = built.biome_parameters.height_max;
				biome_parameters["trunkRadiusMin"] = built.biome_parameters.trunk_radius_min;
				biome_parameters["trunkRadiusMax"] = built.biome_parameters.trunk_radius_max;
				biome_parameters["canopyRadiusMin"] = built.biome_parameters.canopy_radius_min;
				biome_parameters["canopyRadiusMax"] = built.biome_parameters.canopy_radius_max;
				biome_parameters["canopyDensity"] = built.biome_parameters.canopy_density;
				biome_parameters["windResponse"] = built.biome_parameters.wind_response;
				biome_parameters["visibilityRange"] = built.biome_parameters.visibility_range;
				biome_parameters["shadowRange"] = built.biome_parameters.shadow_range;
				biome_parameters["exclusionMargin"] = built.biome_parameters.exclusion_margin;
				feature["biomeParameters"] = biome_parameters;
				feature["rotationY"] = built.rotation_y;
				// Request compatibility values: natural-tree builder fixes these,
				// while the typed definition owns the dimensions and ecology.
				feature["assetId"] = "";
				feature["scale"] = 1.0;
				feature["barkScale"] = 1.0;
				feature["sourceHeight"] = built.visual_height;
				feature["visualHeight"] = built.visual_height;
				feature["trunkRadius"] = built.trunk_radius;
				feature["canopyRadius"] = built.canopy_radius;
				feature["collisionHeight"] = built.collision_height;
				feature["exclusionMargin"] = built.exclusion_margin;
				feature["canopyDensity"] = built.biome_parameters.canopy_density;
				feature["oldGrowth"] = built.old_growth;
				feature["trunkColliderRadius"] = trunk.radius;
				feature["trunkColliderHeight"] = trunk.height;
				feature["trunkColliderCenterY"] = trunk.center_y;
				feature["haloRequired"] = true;
				row["feature"] = feature;
			}
			attempts.append(row);
		}
		Dictionary result = envelope(operation, "ready");
		result["receiptSchema"] = SURFACE_ORDERED_SHADOW_SCHEMA;
		result["chunk"] = p_exclusions->chunk_;
		result["sourceIdentity"] = identity_dictionary(state_->source_identity());
		result["terrainDeltaRevision"] = static_cast<std::int64_t>(pin.terrain_delta_revision());
		result["shapingRegistryRevision"] = static_cast<std::int64_t>(pin.shaping_registry_revision());
		result["structureOwnerGeneration"] = static_cast<std::int64_t>(p_exclusions->snapshot_->world_generation());
		result["structureContentIdentity"] = text(sha256_hex(ordered.exclusion_digest()));
		result["placementIdentity"] = text(sha256_hex(placement.content_digest()));
		result["rngSeed"] = static_cast<std::int64_t>(ordered.rng_seed());
		result["finalRngState"] = text(std::to_string(ordered.final_rng_state()));
		result["attempts"] = attempts;
		result["treeHaloRequests"] = tree_halo_requests;
		result["attemptCount"] = static_cast<std::int64_t>(attempts.size());
		result["completeFeatureManifest"] = false;
		result["liveCaptureFreshnessProven"] = false;
		return result;
	} catch (const std::exception &error) {
		return failure(operation, error);
	}
}

Dictionary NativeWorldBackend::compose_surface_tree_presence_shadow(
		const Ref<NativeEffectiveTerrainPage> &p_page,
		const Ref<NativeStructureExclusionChunk> &p_exclusions,
		const Dictionary &p_union_capture) const {
	constexpr const char *operation = "compose_surface_tree_presence_shadow";
	if (!state_ || !shaping_registry_ || !biome_catalog_ || !visual_catalog_ || !removed_props_ || !wildlife_presentations_
			|| p_page.is_null() || p_exclusions.is_null() || !p_page->batch_ || !p_exclusions->snapshot_)
		return envelope(operation, "failed", "tree_presence_sources_not_ready");
	try {
		const WorldSourcePin &pin = p_page->batch_->pin();
		if (!(pin.definition().physical_content_identity() == state_->source_identity())
				|| pin.terrain_delta_revision() != state_->terrain_delta_revision()
				|| pin.shaping_registry_revision() != shaping_registry_->revision()
				|| !(pin.shaping_registry_content_identity() == shaping_registry_->content_identity())
				|| p_exclusions->snapshot_->world_digest() != state_->source_identity().digest)
			throw std::invalid_argument("tree presence source pin or exclusions are stale");
		require_exact_keys(p_union_capture, {"ok", "schemaVersion", "scope", "ownerInstanceId",
			"admissionSeed", "admissionGeneration", "requests", "coverage", "halo", "contentIdentity"},
			"tree union capture");
		if (!require_bool(p_union_capture["ok"], "union.ok")
				|| require_i64(p_union_capture["schemaVersion"], "union.schemaVersion") != 1
				|| require_bounded_utf8(p_union_capture["scope"], "union.scope", 64U, false)
					!= "admitted_surface_tree_halo_union_only")
			throw std::invalid_argument("unsupported tree union capture");
		const std::int64_t owner_id = require_i64(p_union_capture["ownerInstanceId"], "union.ownerInstanceId");
		const std::int64_t admission_generation = require_i64(p_union_capture["admissionGeneration"], "union.admissionGeneration");
		if (owner_id == 0 || owner_id != p_exclusions->owner_id_
				|| admission_generation <= 0 || admission_generation != p_exclusions->admission_generation_
				|| require_bounded_utf8(p_union_capture["admissionSeed"], "union.admissionSeed",
					MAX_SEED_TEXT_BYTES, false) != state_->definition().raw_terrain_seed().utf8)
			throw std::invalid_argument("tree union owner or admission differs from pinned sources");
		const NativeEffectiveTerrainSource terrain(pin);
		const NativeSurfacePropSourceOrderedStream ordered = NativeSurfacePropSourceOrderedStream::create(
			state_->definition().raw_terrain_seed(), p_exclusions->chunk_.x, p_exclusions->chunk_.y,
			state_->source_identity().digest, p_exclusions->snapshot_->world_generation(),
			terrain, *biome_catalog_, *p_exclusions->snapshot_, *removed_props_, *wildlife_presentations_);
		const NativeSurfacePropOrderedPlacement placement = NativeSurfacePropOrderedPlacement::create(ordered, terrain);
		Array expected_requests;
		struct TreeSource { std::uint32_t ordinal; std::string durable_id; };
		std::vector<TreeSource> trees;
		for (std::size_t index = 0; index < ordered.attempts().size(); ++index) {
			const auto &source = ordered.attempts()[index];
			if (source.outcome != NativeSurfacePropClassificationOutcome::tree_22_draw
					&& source.outcome != NativeSurfacePropClassificationOutcome::tree_36_draw) continue;
			const auto profile = native_surface_tree_profile_from_catalog(*biome_catalog_, source.source->biome_id);
			const auto tree = NativeSurfaceTreeOrderedComposer::create(ordered, placement,
				static_cast<std::uint32_t>(index), terrain, profile);
			const auto margins = native_tree_exclusion_margins(tree.input().trunk_radius,
				tree.input().canopy_radius, tree.input().exclusion_margin,
				pin.definition().constants().cell_size_meters);
			Dictionary row;
			row["ordinal"] = static_cast<std::int64_t>(source.attempt.ordinal);
			row["cell"] = Vector2i(source.attempt.cell_x, source.attempt.cell_z);
			row["naturalMarginCells"] = margins.natural_cells;
			row["structureMarginCells"] = margins.structure_cells;
			expected_requests.append(row);
			trees.push_back({static_cast<std::uint32_t>(index), source.attempt.durable_id});
		}
		const Array requests = require_array(p_union_capture["requests"], "union.requests");
		if (requests.size() == 0 || requests.size() > 28 || requests.size() != expected_requests.size())
			throw std::invalid_argument("tree union request count differs from native source");
		std::int64_t low_x = std::numeric_limits<std::int64_t>::max();
		std::int64_t low_z = low_x;
		std::int64_t high_x = std::numeric_limits<std::int64_t>::min();
		std::int64_t high_z = high_x;
		for (int64_t index = 0; index < requests.size(); ++index) {
			const Dictionary row = require_dictionary(requests[index], "union.requests[]");
			require_exact_keys(row, {"ordinal", "cell", "naturalMarginCells", "structureMarginCells"}, "tree union request");
			const Dictionary expected = expected_requests[index];
			if (require_i64(row["ordinal"], "request.ordinal") != require_i64(expected["ordinal"], "expected.ordinal")
					|| require_vector2i(row["cell"], "request.cell") != require_vector2i(expected["cell"], "expected.cell")
					|| require_i64(row["naturalMarginCells"], "request.naturalMarginCells")
						!= require_i64(expected["naturalMarginCells"], "expected.naturalMarginCells")
					|| require_i64(row["structureMarginCells"], "request.structureMarginCells")
						!= require_i64(expected["structureMarginCells"], "expected.structureMarginCells"))
				throw std::invalid_argument("tree union request differs from native post-draw tree");
			const Vector2i cell = row["cell"];
			const std::int64_t radius = std::max(require_i64(row["naturalMarginCells"], "request.naturalMarginCells"),
				require_i64(row["structureMarginCells"], "request.structureMarginCells"));
			low_x = std::min(low_x, static_cast<std::int64_t>(cell.x) - radius);
			low_z = std::min(low_z, static_cast<std::int64_t>(cell.y) - radius);
			high_x = std::max(high_x, static_cast<std::int64_t>(cell.x) + radius);
			high_z = std::max(high_z, static_cast<std::int64_t>(cell.y) + radius);
		}
		if (p_union_capture["coverage"].get_type() != Variant::RECT2I)
			throw std::invalid_argument("tree union coverage must be Rect2i");
		const Rect2i coverage = p_union_capture["coverage"];
		const std::int64_t center_x = static_cast<std::int64_t>(std::floor((low_x + high_x) * 0.5));
		const std::int64_t center_z = static_cast<std::int64_t>(std::floor((low_z + high_z) * 0.5));
		const std::int64_t radius = std::max({center_x - low_x, high_x - center_x, center_z - low_z, high_z - center_z});
		if (radius < 0 || radius > 4096 || center_x < -1000000 || center_x > 1000000
				|| center_z < -1000000 || center_z > 1000000
				|| coverage != Rect2i(Vector2i(center_x, center_z), Vector2i(1, 1)).grow(static_cast<int>(radius)))
			throw std::invalid_argument("tree union coverage differs from exact requests");
		const Dictionary halo = require_dictionary(p_union_capture["halo"], "union.halo");
		require_exact_keys(halo, {"ownerInstanceId", "ownerGeneration", "exclusionRevision", "cell",
			"naturalMarginCells", "structureMarginCells", "ready", "boundsAdmission", "content", "contentDigest"},
			"tree union halo");
		if (!require_bool(halo["ready"], "halo.ready")
				|| require_i64(halo["ownerInstanceId"], "halo.ownerInstanceId") != owner_id
				|| require_i64(halo["ownerGeneration"], "halo.ownerGeneration") != static_cast<std::int64_t>(ordered.world_generation())
				|| require_i64(halo["exclusionRevision"], "halo.exclusionRevision") != p_exclusions->revision_
				|| require_vector2i(halo["cell"], "halo.cell") != Vector2i(center_x, center_z)
				|| require_i64(halo["naturalMarginCells"], "halo.naturalMarginCells") != radius
				|| require_i64(halo["structureMarginCells"], "halo.structureMarginCells") != radius)
			throw std::invalid_argument("tree union halo authority or extent differs from pinned source");
		const Dictionary bounds_admission = require_dictionary(halo["boundsAdmission"], "halo.boundsAdmission");
		if (require_bounded_utf8(bounds_admission.get("status", Variant()), "halo.boundsAdmission.status", 16U, false) != "ready")
			throw std::invalid_argument("tree union exact bounds admission is not ready");
		const Dictionary content = require_dictionary(halo["content"], "halo.content");
		require_exact_keys(content, {"natural", "terrain", "citadel"}, "tree union content");
		Array halo_bytes;
		halo_bytes.append(Vector2i(center_x, center_z));
		halo_bytes.append(static_cast<std::int64_t>(radius));
		halo_bytes.append(static_cast<std::int64_t>(radius));
		halo_bytes.append(bounds_admission);
		halo_bytes.append(content);
		const String raw_digest = Marshalls::get_singleton()->raw_to_base64(UtilityFunctions::var_to_bytes(halo_bytes)).sha256_text();
		if (require_bounded_utf8(halo["contentDigest"], "halo.contentDigest", 64U, false) != utf8(raw_digest))
			throw std::invalid_argument("tree union raw halo content digest mismatch");
		Array union_bytes;
		union_bytes.append(requests); union_bytes.append(coverage);
		union_bytes.append(p_union_capture["admissionSeed"]);
		union_bytes.append(p_union_capture["admissionGeneration"]);
		union_bytes.append(halo["contentDigest"]);
		const String union_identity = Marshalls::get_singleton()->raw_to_base64(UtilityFunctions::var_to_bytes(union_bytes)).sha256_text();
		if (require_bounded_utf8(p_union_capture["contentIdentity"], "union.contentIdentity", 64U, false) != utf8(union_identity))
			throw std::invalid_argument("tree union capture identity mismatch");
		std::vector<StructureExclusionRecord> natural;
		const Array natural_rows = require_array(content["natural"], "halo.content.natural");
		if (natural_rows.size() > 65536) throw std::length_error("tree natural halo exceeds record limit");
		for (const Variant &value : natural_rows) {
			const Dictionary row = require_dictionary(value, "halo.natural[]");
			require_exact_keys(row, {"id", "source", "minX", "maxX", "minZ", "maxZ"}, "halo natural row");
			static_cast<void>(require_bounded_utf8(row["source"], "halo.natural.source", 1024U));
			natural.push_back({require_bounded_utf8(row["id"], "halo.natural.id", 1024U, false),
				{require_i32(row["minX"], "halo.natural.minX"), require_i32(row["minZ"], "halo.natural.minZ"),
					require_i32(row["maxX"], "halo.natural.maxX"), require_i32(row["maxZ"], "halo.natural.maxZ")}});
		}
		std::vector<StructureExclusionRecord> terrain_rows_native;
		const Array terrain_rows = require_array(content["terrain"], "halo.content.terrain");
		if (terrain_rows.size() > 65536) throw std::length_error("tree terrain halo exceeds record limit");
		for (const Variant &value : terrain_rows) {
			const Dictionary row = require_dictionary(value, "halo.terrain[]");
			require_exact_keys(row, {"id", "source", "material", "baseX", "baseZ", "width", "depth",
				"level", "floorY", "clearanceCells", "minCell", "maxCell"}, "halo terrain row");
			static_cast<void>(require_bounded_utf8(row["source"], "halo.terrain.source", 1024U));
			static_cast<void>(require_bounded_utf8(row["material"], "halo.terrain.material", 1024U));
			static_cast<void>(require_i32(row["baseX"], "halo.terrain.baseX"));
			static_cast<void>(require_i32(row["baseZ"], "halo.terrain.baseZ"));
			static_cast<void>(require_i32(row["width"], "halo.terrain.width"));
			static_cast<void>(require_i32(row["depth"], "halo.terrain.depth"));
			static_cast<void>(require_number(row["level"], "halo.terrain.level"));
			static_cast<void>(require_i32(row["floorY"], "halo.terrain.floorY"));
			static_cast<void>(require_i32(row["clearanceCells"], "halo.terrain.clearanceCells"));
			const Vector3i low = require_vector3i(row["minCell"], "halo.terrain.minCell");
			const Vector3i high = require_vector3i(row["maxCell"], "halo.terrain.maxCell");
			terrain_rows_native.push_back({require_bounded_utf8(row["id"], "halo.terrain.id", 1024U, false),
				{low.x, low.z, high.x, high.z}});
		}
		std::vector<CitadelExclusionSource> citadels;
		const Array citadel_rows = require_array(content["citadel"], "halo.content.citadel");
		if (citadel_rows.size() > 64) throw std::length_error("tree Citadel halo exceeds region limit");
		const auto region_for = [](const std::int64_t cell) {
			return cell >= 0 ? cell / 2048 : (cell - 2047) / 2048;
		};
		const std::int64_t min_region_x = region_for(coverage.position.x);
		const std::int64_t min_region_z = region_for(coverage.position.y);
		const std::int64_t max_region_x = region_for(static_cast<std::int64_t>(coverage.get_end().x) - 1);
		const std::int64_t max_region_z = region_for(static_cast<std::int64_t>(coverage.get_end().y) - 1);
		if (citadel_rows.size() != (max_region_x - min_region_x + 1) * (max_region_z - min_region_z + 1))
			throw std::invalid_argument("tree Citadel halo region coverage is incomplete");
		std::int64_t citadel_index = 0;
		for (const Variant &value : citadel_rows) {
			const Dictionary row = require_dictionary(value, "halo.citadel[]");
			require_exact_keys(row, {"region", "status", "reason", "sourceKey", "sourceGeneration",
				"binding", "sourceSignature", "reservationCells"}, "halo Citadel row");
			const Vector2i region = require_vector2i(row["region"], "halo.citadel.region");
			if (region.x != min_region_x + citadel_index % (max_region_x - min_region_x + 1)
					|| region.y != min_region_z + citadel_index / (max_region_x - min_region_x + 1))
				throw std::invalid_argument("tree Citadel halo region sequence differs from coverage");
			++citadel_index;
			const std::string status = require_bounded_utf8(row["status"], "halo.citadel.status", 16U, false);
			CitadelSourceStatus source_status;
			if (status == "absent") source_status = CitadelSourceStatus::absent;
			else if (status == "failed") source_status = CitadelSourceStatus::failed;
			else if (status == "ready") source_status = CitadelSourceStatus::ready;
			else if (status == "prepared") source_status = CitadelSourceStatus::prepared;
			else throw std::invalid_argument("tree Citadel halo status is unsupported");
			const Dictionary binding = require_dictionary(row["binding"], "halo.citadel.binding");
			const std::int64_t source_generation = require_i64(row["sourceGeneration"], "halo.citadel.sourceGeneration");
			const std::string source_key = require_bounded_utf8(row["sourceKey"], "halo.citadel.sourceKey", 1024U);
			const std::string signature = require_bounded_utf8(row["sourceSignature"], "halo.citadel.sourceSignature", 1024U);
			const std::string reason = require_bounded_utf8(row["reason"], "halo.citadel.reason", 1024U);
			if (row["reservationCells"].get_type() != Variant::RECT2I)
				throw std::invalid_argument("tree Citadel reservation must be Rect2i");
			const Rect2i reservation = row["reservationCells"];
			const std::int64_t end_x = static_cast<std::int64_t>(reservation.position.x) + reservation.size.x;
			const std::int64_t end_z = static_cast<std::int64_t>(reservation.position.y) + reservation.size.y;
			if (end_x > std::numeric_limits<std::int32_t>::max() || end_z > std::numeric_limits<std::int32_t>::max()
					|| end_x < std::numeric_limits<std::int32_t>::min() || end_z < std::numeric_limits<std::int32_t>::min())
				throw std::out_of_range("tree Citadel reservation exceeds int32");
			if (source_status == CitadelSourceStatus::ready || source_status == CitadelSourceStatus::prepared) {
				require_exact_keys(binding, {"siteId", "sourceKey", "generation"}, "halo Citadel binding");
				if (require_bounded_utf8(binding["siteId"], "halo.citadel.siteId", 1024U, false).empty()
						|| require_bounded_utf8(binding["sourceKey"], "halo.citadel.binding.sourceKey", 1024U, false) != source_key
						|| require_i64(binding["generation"], "halo.citadel.binding.generation") != source_generation
						|| source_generation <= 0 || source_generation != admission_generation)
					throw std::invalid_argument("tree Citadel binding differs from admission");
			} else if (!binding.is_empty() || source_generation != -1
					|| (source_status == CitadelSourceStatus::failed && !source_key.empty()) || !signature.empty()
					|| reservation != Rect2i())
				throw std::invalid_argument("nonprepared tree Citadel row carries source binding");
			citadels.push_back({region.x, region.y, source_status, reason, source_key, signature,
				static_cast<std::uint64_t>(source_status == CitadelSourceStatus::ready
					|| source_status == CitadelSourceStatus::prepared ? source_generation : 0),
				{reservation.position.x, reservation.position.y, static_cast<std::int32_t>(end_x), static_cast<std::int32_t>(end_z)}});
		}
		const NativeTreeExclusionHaloCapture admitted = NativeTreeExclusionHaloCapture::create(
			state_->source_identity().digest, ordered.world_generation(), ordered.exclusion_digest(),
			{coverage.position.x, coverage.position.y, coverage.get_end().x - 1, coverage.get_end().y - 1},
			std::move(natural), std::move(terrain_rows_native), std::move(citadels));
		const NativeSurfaceFeatureManifest manifest = NativeSurfaceFeatureManifest::create(
			ordered, placement, terrain, *biome_catalog_, *visual_catalog_,
			*p_exclusions->snapshot_, *wildlife_presentations_, &admitted);
		Array decisions;
		for (const TreeSource &source : trees) {
			const auto &decision = manifest.entries()[source.ordinal].tree_presence.value();
			Dictionary row;
			row["ordinal"] = static_cast<std::int64_t>(source.ordinal);
			row["durableId"] = text(source.durable_id);
			row["presence"] = static_cast<std::int64_t>(decision.presence);
			row["blockerKind"] = static_cast<std::int64_t>(decision.blocker_kind);
			row["blockerId"] = text(decision.blocker_id);
			row["naturalMarginCells"] = decision.natural_margin_cells;
			row["structureMarginCells"] = decision.structure_margin_cells;
			row["contentIdentity"] = text(sha256_hex(decision.content_digest));
			decisions.append(row);
		}
		Dictionary result = envelope(operation, "ready");
		result["receiptSchema"] = TREE_PRESENCE_SHADOW_SCHEMA;
		result["sourceIdentity"] = identity_dictionary(state_->source_identity());
		result["terrainDeltaRevision"] = static_cast<std::int64_t>(pin.terrain_delta_revision());
		result["shapingRegistryRevision"] = static_cast<std::int64_t>(pin.shaping_registry_revision());
		result["structureContentIdentity"] = text(sha256_hex(ordered.exclusion_digest()));
		result["structureOwnerGeneration"] = static_cast<std::int64_t>(ordered.world_generation());
		result["structureExclusionRevision"] = p_exclusions->revision_;
		result["unionCaptureIdentity"] = text(utf8(union_identity));
		result["haloIdentity"] = text(sha256_hex(admitted.content_digest()));
		result["featureManifestIdentity"] = text(sha256_hex(manifest.content_digest()));
		result["decisions"] = decisions;
		result["completeFeatureManifest"] = false;
		result["liveCaptureFreshnessProven"] = false;
		return result;
	} catch (const std::exception &error) {
		return failure(operation, error);
	}
}

Dictionary NativeWorldBackend::status() const {
	const char *state = state_ && shaping_registry_ ? "ready" :
		(initialization_attempted_ ? "failed" : "uninitialized");
	Dictionary result = envelope("status", state, text(initialization_failure_));
	result["initializationAttempted"] = initialization_attempted_;
	Dictionary limits;
	limits["batchChannelQueries"] = static_cast<int64_t>(MAX_BATCH_CHANNEL_QUERIES);
	limits["batchTotalQueries"] = static_cast<int64_t>(MAX_BATCH_TOTAL_QUERIES);
	limits["townOverrides"] = static_cast<int64_t>(MAX_TOWN_OVERRIDES);
	limits["shapingResolutions"] = static_cast<int64_t>(MAX_SHAPING_RESOLUTIONS);
	limits["typedCellOperations"] = static_cast<int64_t>(MAX_TYPED_CELL_OPERATIONS);
	limits["seedCodePoints"] = static_cast<int64_t>(MAX_SEED_CODE_POINTS);
	limits["seedUtf8Bytes"] = static_cast<int64_t>(MAX_SEED_TEXT_BYTES);
	limits["transactionIdBytes"] = static_cast<int64_t>(MAX_TRANSACTION_ID_BYTES);
	limits["blockIdBytes"] = static_cast<int64_t>(MAX_BLOCK_ID_BYTES);
	limits["editReasonBytes"] = static_cast<int64_t>(MAX_EDIT_REASON_BYTES);
	limits["shapingReasonBytes"] = static_cast<int64_t>(MAX_SHAPING_REASON_BYTES);
	limits["siteProfileSamples"] = static_cast<int64_t>(NativeTerrainShapingSnapshot::MAX_SITE_SAMPLES);
	limits["siteProfileRootPoints"] = static_cast<int64_t>(NativeTerrainShapingSnapshot::MAX_GROUND_ROOT_POINTS);
	limits["siteProfileSourceSignatureBytes"] = static_cast<int64_t>(NativeTerrainShapingSnapshot::MAX_SOURCE_SIGNATURE_BYTES);
	limits["siteProfileApronCells"] = static_cast<int64_t>(NativeTerrainShapingSnapshot::MAX_TOWN_APRON_CELLS);
	limits["siteProfileAbsCell"] = static_cast<int64_t>(MAX_PROFILE_ABS_CELL);
	limits["metadataDepth"] = static_cast<int64_t>(NativeValueLimits::MAX_DEPTH);
	limits["metadataNodes"] = static_cast<int64_t>(NativeValueLimits::MAX_NODES);
	limits["metadataStringBytes"] = static_cast<int64_t>(NativeValueLimits::MAX_STRING_BYTES);
	limits["metadataKeyBytes"] = static_cast<int64_t>(NativeValueLimits::MAX_OBJECT_KEY_BYTES);
	limits["metadataContainerEntries"] = static_cast<int64_t>(NativeValueLimits::MAX_CONTAINER_ENTRIES);
	result["adapterLimits"] = limits;
	if (!state_ || !shaping_registry_) return result;
	result["sourceSeedText"] = text(state_->definition().raw_terrain_seed().utf8);
	result["sourceIdentity"] = identity_dictionary(state_->source_identity());
	result["terrainDeltaRevision"] = static_cast<int64_t>(state_->terrain_delta_revision());
	result["shapingRegistryRevision"] = static_cast<int64_t>(shaping_registry_->revision());
	result["shapingRegistryIdentity"] = identity_dictionary(shaping_registry_->content_identity());
	result["shapingPolicyIdentity"] = identity_dictionary(shaping_registry_->policy_content_identity());
	result["residentShapingResolutions"] = static_cast<int64_t>(shaping_registry_->resident_resolution_count());
	result["typedCellTransactionsSupported"] = true;
	result["durableCellTransactionsSupported"] = true;
	result["sceneOverlayTransactionsSupported"] = true;
	result["sceneOverlaySavePersistence"] = false;
	result["preparedShapingResolutionsSupported"] = true;
	result["saveV2InitializationSupported"] = true;
	result["terrainVolumeV2ExportSupported"] = true;
	result["removedPropsReady"] = removed_props_ != nullptr;
	if (removed_props_) {
		result["removedPropsFd1Identity"] = text(removed_fd1_identity_);
		result["removedPropsCaptureOwnerInstanceId"] = removed_capture_owner_id_;
		result["removedPropsCaptureRevision"] = removed_capture_revision_;
		result["removedPropsCaptureContentIdentity"] = text(removed_capture_identity_);
		result["removedPropsCount"] = static_cast<int64_t>(removed_props_->tombstones().size());
	}
	result["biomeCatalogReady"] = biome_catalog_ != nullptr;
	if (biome_catalog_) {
		result["biomeCatalogIdentity"] = text(sha256_hex(biome_catalog_->content_digest()));
		result["biomeCaptureOwnerInstanceId"] = biome_capture_owner_id_;
		result["biomeCaptureRevision"] = biome_capture_revision_;
		result["biomeCaptureContentIdentity"] = text(biome_capture_identity_);
	}
	result["visualCatalogReady"] = visual_catalog_ != nullptr;
	if (visual_catalog_) {
		result["visualCatalogIdentity"] = text(sha256_hex(visual_catalog_->content_digest()));
		result["visualCaptureOwnerInstanceId"] = visual_capture_owner_id_;
		result["visualCaptureRevision"] = visual_capture_revision_;
		result["visualCaptureContentIdentity"] = text(visual_capture_identity_);
	}
	result["wildlifePresentationReady"] = wildlife_presentations_ != nullptr;
	if (wildlife_presentations_) {
		result["wildlifePresentationCaptureOwnerInstanceId"] = presentation_capture_owner_id_;
		result["wildlifePresentationCaptureRevision"] = presentation_capture_revision_;
		result["wildlifePresentationCaptureContentIdentity"] = text(presentation_capture_identity_);
	}
	return result;
}

std::vector<NativeTownRegionOverride> NativeWorldBackend::town_overrides_for_page(
		const NativeTerrainPageKey p_page) const {
	std::vector<NativeTownRegionOverride> result;
	for (const NativeTownRegionOverride &town : town_overrides_) {
		if (town.region_x >= p_page.x - 1 && town.region_x <= p_page.x + 1
				&& town.region_z >= p_page.z - 1 && town.region_z <= p_page.z + 1) {
			result.push_back(town);
		}
	}
	return result;
}

std::string NativeWorldBackend::canonical_worker_source_key(
		const NativeSiteSourceRegionKey p_region) const {
	if (!state_ || !shaping_registry_) throw std::logic_error("native world backend is not initialized");
	Array identity_towns;
	for (const NativeSiteSourcePolicy::TownOverride &town : shaping_registry_->policy().town_overrides) {
		Dictionary record;
		if (town.has_town) {
			record["regionX"] = static_cast<int64_t>(town.region_x);
			record["regionZ"] = static_cast<int64_t>(town.region_z);
			record["centerX"] = town.center_x;
			record["centerZ"] = town.center_z;
			record["radius"] = town.radius_cells;
			record["level"] = town.level_meters;
		}
		Array entry;
		entry.append(Vector2i(town.region_x, town.region_z));
		entry.append(record);
		identity_towns.append(entry);
	}
	Dictionary ordinary;
	ordinary["regionCells"] = shaping_registry_->policy().ordinary_region_cells;
	ordinary["spawnChance"] = shaping_registry_->policy().ordinary_spawn_chance;
	Array identity;
	identity.append(static_cast<int64_t>(shaping_registry_->policy().source_policy_revision));
	identity.append(static_cast<int64_t>(shaping_registry_->policy().survey_generation_policy_revision));
	identity.append(text(shaping_registry_->policy().engine_version_utf8));
	identity.append(text(state_->definition().raw_terrain_seed().utf8));
	identity.append(Vector2i(p_region.x, p_region.z));
	identity.append(identity_towns);
	identity.append(ordinary);
	const PackedByteArray bytes = UtilityFunctions::var_to_bytes(identity);
	return sha256_hex(sha256(bytes.ptr(), static_cast<std::size_t>(bytes.size())));
}

Dictionary NativeWorldBackend::shaping_requests(const Vector2i &p_primary_page) const {
	if (!state_ || !shaping_registry_) return envelope("shaping_requests", "failed", "backend_not_ready");
	try {
		const NativeTerrainPageKey primary{p_primary_page.x, p_primary_page.y};
		const std::vector<NativeTerrainPageKey> pages = world_effective_shaping_dependencies(state_->definition(), primary);
		std::vector<NativeSiteSourceRegionKey> unresolved;
		std::vector<NativeSiteSourceRegionKey> failed_regions;
		for (const NativeTerrainPageKey page : pages) {
			const NativeTerrainShapingPagePin pin = shaping_registry_->pin_page(page, town_overrides_for_page(page));
			for (const NativeSiteSourceRegionKey region : pin.unresolved_dependencies()) {
				if (std::find(unresolved.begin(), unresolved.end(), region) == unresolved.end()) unresolved.push_back(region);
			}
			for (const NativeSiteSourceRegionKey region : pin.failed_dependencies()) {
				if (std::find(failed_regions.begin(), failed_regions.end(), region) == failed_regions.end()) failed_regions.push_back(region);
			}
		}
		Array requests;
		for (const NativeSiteSourceRegionKey region : unresolved) {
			const auto candidate = native_site_source_candidate_for_region(state_->definition(), region);
			if (!candidate) throw std::logic_error("unresolved shaping region has no native candidate");
			Dictionary request;
			request["region"] = Vector2i(region.x, region.z);
			request["requestIdentity"] = text(shaping_registry_->source_request_identity(region).digest_hex());
			request["workerSourceKey"] = text(canonical_worker_source_key(region));
			request["siteId"] = text(candidate->site_id);
			request["centerCell"] = Vector2i(candidate->center_x, candidate->center_z);
			request["recipeSeed"] = static_cast<int64_t>(candidate->recipe_seed);
			request["declaredInfluenceCells"] = Rect2i(candidate->declared_influence_cells.x,
				candidate->declared_influence_cells.z, candidate->declared_influence_cells.width,
				candidate->declared_influence_cells.depth);
			requests.append(request);
		}
		Dictionary result = envelope("shaping_requests", !failed_regions.empty() ? "failed" :
			(!unresolved.empty() ? "pending" : "ready"),
			!failed_regions.empty() ? String("shaping_dependency_failed") :
			(!unresolved.empty() ? String("shaping_dependency_unresolved") : String()));
		result["primaryPage"] = p_primary_page;
		result["effectivePages"] = static_cast<int64_t>(pages.size());
		result["requests"] = requests;
		result["failedRegions"] = regions_array(failed_regions);
		result["shapingRegistryRevision"] = static_cast<int64_t>(shaping_registry_->revision());
		result["shapingRegistryIdentity"] = identity_dictionary(shaping_registry_->content_identity());
		return result;
	} catch (const std::exception &error) {
		return failure("shaping_requests", error);
	}
}

Dictionary NativeWorldBackend::apply_shaping_resolutions(const Array &p_resolutions) {
	if (!state_ || !shaping_registry_) return envelope("apply_shaping_resolutions", "failed", "backend_not_ready");
	try {
		if (static_cast<std::size_t>(p_resolutions.size()) > MAX_SHAPING_RESOLUTIONS) {
			throw std::length_error("resolutions exceeds adapter batch limit");
		}
		NativeTerrainShapingRegistryBatch batch;
		batch.expected_revision = shaping_registry_->revision();
		batch.resolutions.reserve(static_cast<std::size_t>(p_resolutions.size()));
		for (int64_t index = 0; index < p_resolutions.size(); ++index) {
			const Dictionary value = require_dictionary(p_resolutions[index], "resolutions[]");
			const Vector2i region_value = require_vector2i(value.get("region", Variant()), "resolution.region");
			NativeSiteSourceResolution resolution;
			resolution.region = {region_value.x, region_value.y};
			const std::string expected_request = shaping_registry_->source_request_identity(resolution.region).digest_hex();
			if (require_bounded_utf8(value.get("requestIdentity", Variant()),
					"resolution.requestIdentity", 64U, false) != expected_request) {
				throw std::invalid_argument("resolution request identity does not match native authority");
			}
			resolution.request_identity = shaping_registry_->source_request_identity(resolution.region);
			const std::string expected_source_key = canonical_worker_source_key(resolution.region);
			resolution.worker_source_key = require_bounded_utf8(value.get("workerSourceKey", Variant()),
				"resolution.workerSourceKey", 64U, false);
			if (resolution.worker_source_key != expected_source_key) {
				throw std::invalid_argument("resolution worker source key does not match canonical request");
			}
			const String kind = require_protocol_string(value.get("kind", Variant()), "resolution.kind");
			if (kind == "absent") resolution.kind = NativeSiteSourceResolutionKind::absent;
			else if (kind == "prepared") resolution.kind = NativeSiteSourceResolutionKind::prepared;
			else if (kind == "failed") resolution.kind = NativeSiteSourceResolutionKind::failed;
			else throw std::invalid_argument("resolution.kind is unsupported");
			resolution.reason_code = require_bounded_utf8(value.get("reasonCode", Variant()),
				"resolution.reasonCode", MAX_SHAPING_REASON_BYTES);
			if (resolution.kind == NativeSiteSourceResolutionKind::prepared) {
				if (!resolution.reason_code.empty()) {
					throw std::invalid_argument("prepared resolution reasonCode must be empty");
				}
				const auto candidate = native_site_source_candidate_for_region(state_->definition(), resolution.region);
				if (!candidate) throw std::invalid_argument("prepared resolution has no native candidate");
				verify_worker_candidate(require_dictionary(value.get("candidate", Variant()), "resolution.candidate"),
					*candidate, state_->definition());
				const Dictionary manifest = require_dictionary(value.get("manifest", Variant()), "resolution.manifest");
				if (!require_bool(manifest.get("ready", Variant()), "resolution.manifest.ready")) {
					throw std::invalid_argument("resolution manifest is not ready");
				}
				resolution.manifest_source_signature = require_bounded_utf8(
					manifest.get("sourceSignature", Variant()), "resolution.manifest.sourceSignature",
					NativeTerrainShapingSnapshot::MAX_SOURCE_SIGNATURE_BYTES, false);
				resolution.source_reservation_cells = require_profile_rect(
					value.get("reservationCells", Variant()), "resolution.reservationCells");
				if (!rect_encloses(candidate->declared_influence_cells, resolution.source_reservation_cells)
						|| !reservation_fits_source_region(resolution.region, resolution.source_reservation_cells)) {
					throw std::invalid_argument("resolution source reservation exceeds native candidate bounds");
				}
				NativeSiteTerrainProfile profile = parse_site_profile(
					require_dictionary(value.get("profile", Variant()), "resolution.profile"), *candidate, state_->definition());
				if (resolution.manifest_source_signature != profile.source_signature) {
					throw std::invalid_argument("resolution manifest signature does not match terrain profile");
				}
				resolution.profile = admit_native_site_terrain_profile(state_->definition(), std::move(profile));
			}
			batch.resolutions.push_back(std::move(resolution));
		}
		const NativeTerrainShapingRegistryReceipt receipt = shaping_registry_->apply(batch);
		Dictionary result = envelope("apply_shaping_resolutions", "ready");
		result["commitStatus"] = receipt.status == NativeTerrainShapingRegistryCommitStatus::committed ? "committed" : "no_change";
		result["shapingRegistryRevision"] = static_cast<int64_t>(receipt.revision);
		result["shapingRegistryIdentity"] = identity_dictionary(shaping_registry_->content_identity());
		return result;
	} catch (const std::exception &error) {
		return failure("apply_shaping_resolutions", error);
	}
}

Dictionary NativeWorldBackend::commit_typed_cells(const Dictionary &p_request) {
	if (!state_ || !shaping_registry_) return envelope("commit_typed_cells", "failed", "backend_not_ready");
	try {
		return commit_typed_cell_request(*state_, p_request, false, "commit_typed_cells");
	} catch (const std::exception &error) {
		return failure("commit_typed_cells", error);
	}
}

Dictionary NativeWorldBackend::commit_durable_cells(const Dictionary &p_request) {
	if (!state_ || !shaping_registry_) return envelope("commit_durable_cells", "failed", "backend_not_ready");
	try {
		return commit_typed_cell_request(*state_, p_request, true, "commit_durable_cells");
	} catch (const std::exception &error) {
		return failure("commit_durable_cells", error);
	}
}

Dictionary NativeWorldBackend::pin_effective_page(const Vector2i &p_primary_page) const {
	if (!state_ || !shaping_registry_) return envelope("pin_effective_page", "failed", "backend_not_ready");
	try {
		const NativeTerrainPageKey primary{p_primary_page.x, p_primary_page.y};
		const std::vector<NativeTerrainPageKey> dependencies = world_effective_shaping_dependencies(state_->definition(), primary);
		std::vector<NativeTerrainShapingPagePin> pins;
		pins.reserve(dependencies.size());
		std::vector<NativeSiteSourceRegionKey> unresolved;
		std::vector<NativeSiteSourceRegionKey> failed_regions;
		for (const NativeTerrainPageKey page : dependencies) {
			NativeTerrainShapingPagePin pin = shaping_registry_->pin_page(page, town_overrides_for_page(page));
			unresolved.insert(unresolved.end(), pin.unresolved_dependencies().begin(), pin.unresolved_dependencies().end());
			failed_regions.insert(failed_regions.end(), pin.failed_dependencies().begin(), pin.failed_dependencies().end());
			pins.push_back(std::move(pin));
		}
		if (!failed_regions.empty()) {
			Dictionary result = envelope("pin_effective_page", "failed", "shaping_dependency_failed");
			result["failedRegions"] = regions_array(failed_regions);
			return result;
		}
		if (!unresolved.empty()) {
			Dictionary result = envelope("pin_effective_page", "pending", "shaping_dependency_unresolved");
			result["unresolvedRegions"] = regions_array(unresolved);
			return result;
		}
		WorldSourcePin pin = state_->pin_effective_page(primary, pins);
		Ref<NativeEffectiveTerrainPage> page;
		page.instantiate();
		page->admit(std::make_unique<NativeEffectiveTerrainBatch>(std::move(pin)));
		Dictionary result = envelope("pin_effective_page", "ready");
		result["page"] = page;
		result["pageStatus"] = page->status();
		return result;
	} catch (const std::exception &error) {
		return failure("pin_effective_page", error);
	}
}

Dictionary NativeWorldBackend::begin_voxel_block_shadow_async(const Dictionary &p_request) {
	constexpr const char *operation = "begin_voxel_block_shadow_async";
	if (!state_ || !shaping_registry_) return envelope(operation, "failed", "backend_not_ready");
	if (voxel_worker_ticket_ != 0) return envelope(operation, "rejected", "worker_busy");
	try {
		if (require_protocol_string(p_request.get("schema", Variant()), "schema") != VOXEL_BLOCK_REQUEST_SCHEMA)
			throw std::invalid_argument("unsupported native effective voxel block request schema");
		const Vector3i origin = require_vector3i(p_request.get("origin", Variant()), "origin");
		const Vector3i size = require_vector3i(p_request.get("size", Variant()), "size");
		const std::int64_t lod = require_i64(p_request.get("lod", Variant()), "lod");
		if (size.x <= 0 || size.y <= 0 || size.z <= 0 || size.x > 32 || size.y > 32 || size.z > 32 || lod < 0 || lod > 24)
			throw std::invalid_argument("native shadow voxel block dimensions or LOD are invalid");
		const std::int64_t scale = std::int64_t{1} << lod;
		auto checked_cell = [scale](const std::int32_t base, const std::int32_t offset) {
			const std::int64_t value = static_cast<std::int64_t>(base) + static_cast<std::int64_t>(offset) * scale;
			if (value > std::numeric_limits<std::int32_t>::max())
				throw std::out_of_range("native shadow voxel block coordinate overflows int32");
			return static_cast<std::int32_t>(value);
		};
		auto page_axis = [](const std::int32_t cell) {
			constexpr std::int32_t page_cells = NativeTerrainShapingSnapshot::PAGE_CELLS;
			return cell / page_cells - static_cast<std::int32_t>(cell % page_cells < 0);
		};
		(void)checked_cell(origin.y, size.y - 1);
		std::vector<std::int32_t> x_pages, z_pages;
		for (std::int32_t x = 0; x < size.x; ++x) {
			const std::int32_t page = page_axis(checked_cell(origin.x, x));
			if (x_pages.empty() || x_pages.back() != page) x_pages.push_back(page);
		}
		for (std::int32_t z = 0; z < size.z; ++z) {
			const std::int32_t page = page_axis(checked_cell(origin.z, z));
			if (z_pages.empty() || z_pages.back() != page) z_pages.push_back(page);
		}
		if (x_pages.size() * z_pages.size() > 16U)
			throw std::length_error("native shadow async block exceeds primary page capture limit");
		const WorldPhysicalContentIdentity source_identity = state_->source_identity();
		const WorldPhysicalContentIdentity registry_identity = shaping_registry_->content_identity();
		const WorldPhysicalContentIdentity town_policy_identity = shaping_registry_->policy_content_identity();
		const std::uint64_t registry_revision = shaping_registry_->revision();
		WorldDeltaPinnedSnapshot deltas = state_->pin_deltas();
		const std::uint64_t delta_revision = deltas.revision();
		std::vector<NativeTerrainPageKey> dependencies;
		for (const std::int32_t z : z_pages) for (const std::int32_t x : x_pages) {
			const auto pages = world_effective_shaping_dependencies(state_->definition(), {x, z});
			dependencies.insert(dependencies.end(), pages.begin(), pages.end());
		}
		auto less_page = [](const NativeTerrainPageKey a, const NativeTerrainPageKey b) {
			return a.z < b.z || (a.z == b.z && a.x < b.x);
		};
		std::sort(dependencies.begin(), dependencies.end(), less_page);
		dependencies.erase(std::unique(dependencies.begin(), dependencies.end()), dependencies.end());
		if (dependencies.size() > 64U)
			throw std::length_error("native shadow async block exceeds shaping page capture limit");
		std::vector<NativeTerrainShapingPagePin> pins;
		pins.reserve(dependencies.size());
		std::vector<NativeSiteSourceRegionKey> unresolved, failed_regions;
		for (const NativeTerrainPageKey page : dependencies) {
			NativeTerrainShapingPagePin pin = shaping_registry_->pin_page(page, town_overrides_for_page(page));
			for (const auto region : pin.unresolved_dependencies())
				if (std::find(unresolved.begin(), unresolved.end(), region) == unresolved.end()) unresolved.push_back(region);
			for (const auto region : pin.failed_dependencies())
				if (std::find(failed_regions.begin(), failed_regions.end(), region) == failed_regions.end()) failed_regions.push_back(region);
			pins.push_back(std::move(pin));
		}
		if (state_->terrain_delta_revision() != delta_revision || shaping_registry_->revision() != registry_revision
				|| !(shaping_registry_->content_identity() == registry_identity)
				|| !(shaping_registry_->policy_content_identity() == town_policy_identity)
				|| !(state_->source_identity() == source_identity))
			return envelope(operation, "pending", "source_changed_retry");
		if (!failed_regions.empty()) {
			Dictionary result = envelope(operation, "failed", "shaping_dependency_failed");
			result["failedRegions"] = regions_array(failed_regions);
			return result;
		}
		if (!unresolved.empty()) {
			Dictionary result = envelope(operation, "pending", "shaping_dependency_unresolved");
			result["unresolvedRegions"] = regions_array(unresolved);
			return result;
		}
		auto job = std::make_unique<NativeCapturedVoxelEncodeJob>(state_->definition(), std::move(deltas), std::move(pins),
			NativeEffectiveVoxelBlockRequest{cell_coord(origin), cell_coord(size), static_cast<std::uint32_t>(lod)});
		voxel_worker_source_identity_ = source_identity;
		voxel_worker_registry_identity_ = registry_identity;
		voxel_worker_town_policy_identity_ = town_policy_identity;
		voxel_worker_registry_revision_ = registry_revision;
		voxel_worker_delta_revision_ = delta_revision;
		voxel_worker_primary_page_count_ = static_cast<std::int64_t>(x_pages.size() * z_pages.size());
		voxel_worker_shaping_page_count_ = static_cast<std::int64_t>(dependencies.size());
		voxel_worker_result_.reset();
		voxel_worker_error_ = nullptr;
		voxel_worker_cancelled_ = false;
		if (next_voxel_worker_ticket_ == std::numeric_limits<std::int64_t>::max())
			return envelope(operation, "failed", "ticket_space_exhausted");
		voxel_worker_finished_.store(false, std::memory_order_relaxed);
		voxel_worker_cancel_token_ = std::make_shared<std::atomic<bool>>(false);
		voxel_worker_ = std::thread([this, job = std::move(job), cancel_token = voxel_worker_cancel_token_]() {
			try { voxel_worker_result_ = job->encode([cancel_token]() {
				return cancel_token->load(std::memory_order_relaxed);
			}); }
			catch (...) { voxel_worker_error_ = std::current_exception(); }
			voxel_worker_finished_.store(true, std::memory_order_release);
		});
		voxel_worker_ticket_ = next_voxel_worker_ticket_++;
		Dictionary result = envelope(operation, "pending", "worker_running");
		result["asyncSchema"] = VOXEL_BLOCK_ASYNC_SCHEMA;
		result["ticket"] = voxel_worker_ticket_;
		return result;
	} catch (const std::exception &error) {
		return failure(operation, error);
	}
}

Dictionary NativeWorldBackend::poll_voxel_block_shadow_async(std::int64_t p_ticket) {
	constexpr const char *operation = "poll_voxel_block_shadow_async";
	if (p_ticket <= 0 || p_ticket != voxel_worker_ticket_)
		return envelope(operation, "failed", "unknown_ticket");
	if (!voxel_worker_finished_.load(std::memory_order_acquire)) {
		Dictionary result = envelope(operation, "pending", voxel_worker_cancelled_ ? "worker_draining" : "worker_running");
		result["asyncSchema"] = VOXEL_BLOCK_ASYNC_SCHEMA;
		result["ticket"] = p_ticket;
		if (voxel_worker_cancelled_) result["cancelled"] = true;
		return result;
	}
	voxel_worker_.join();
	voxel_worker_ticket_ = 0;
	voxel_worker_cancel_token_.reset();
	if (voxel_worker_cancelled_) {
		voxel_worker_result_.reset();
		voxel_worker_error_ = nullptr;
		voxel_worker_cancelled_ = false;
		Dictionary result = envelope(operation, "ready");
		result["asyncSchema"] = VOXEL_BLOCK_ASYNC_SCHEMA;
		result["ticket"] = p_ticket;
		result["cancelled"] = true;
		return result;
	}
	if (!state_ || !shaping_registry_ || state_->terrain_delta_revision() != voxel_worker_delta_revision_
			|| shaping_registry_->revision() != voxel_worker_registry_revision_
			|| !(shaping_registry_->content_identity() == voxel_worker_registry_identity_)
			|| !(shaping_registry_->policy_content_identity() == voxel_worker_town_policy_identity_)
			|| !(state_->source_identity() == voxel_worker_source_identity_)) {
		voxel_worker_result_.reset();
		voxel_worker_error_ = nullptr;
		Dictionary result = envelope(operation, "pending", "source_changed_retry");
		result["asyncSchema"] = VOXEL_BLOCK_ASYNC_SCHEMA;
		result["ticket"] = p_ticket;
		return result;
	}
	if (voxel_worker_error_) {
		try { std::rethrow_exception(voxel_worker_error_); }
		catch (const std::exception &error) { voxel_worker_error_ = nullptr; return failure(operation, error); }
		catch (...) { voxel_worker_error_ = nullptr; return envelope(operation, "failed", "unknown_worker_error"); }
	}
	if (!voxel_worker_result_) return envelope(operation, "failed", "missing_worker_result");
	NativeEffectiveVoxelBlock block = std::move(*voxel_worker_result_);
	voxel_worker_result_.reset();
	auto packed = [](const std::vector<std::uint8_t> &bytes) {
		PackedByteArray result;
		result.resize(static_cast<int64_t>(bytes.size()));
		if (!bytes.empty()) std::memcpy(result.ptrw(), bytes.data(), bytes.size());
		return result;
	};
	Dictionary result = envelope(operation, "ready");
	result["asyncSchema"] = VOXEL_BLOCK_ASYNC_SCHEMA;
	result["ticket"] = p_ticket;
	result["resultSchema"] = VOXEL_BLOCK_RESULT_SCHEMA;
	result["origin"] = vector3i(block.origin);
	result["size"] = vector3i(block.size);
	result["lod"] = static_cast<std::int64_t>(block.lod);
	result["sourceIdentity"] = identity_dictionary(voxel_worker_source_identity_);
	result["pinIdentity"] = identity_dictionary(block.pin_identity);
	result["blockContentIdentity"] = identity_dictionary(block.block_content_identity);
	result["terrainDeltaRevision"] = static_cast<std::int64_t>(block.terrain_delta_revision);
	result["shapingRegistryRevision"] = static_cast<std::int64_t>(block.shaping_registry_revision);
	result["shapingRegistryIdentity"] = identity_dictionary(voxel_worker_registry_identity_);
	result["townPolicyIdentity"] = identity_dictionary(voxel_worker_town_policy_identity_);
	result["ownerInstanceId"] = static_cast<std::int64_t>(get_instance_id());
	result["primaryPageCount"] = voxel_worker_primary_page_count_;
	result["shapingPageCount"] = voxel_worker_shaping_page_count_;
	result["sdf16Le"] = packed(block.sdf16_le);
	result["indices8"] = packed(block.indices8);
	result["data5_8"] = packed(block.data5_8);
	return result;
}

Dictionary NativeWorldBackend::cancel_voxel_block_shadow_async(std::int64_t p_ticket) {
	constexpr const char *operation = "cancel_voxel_block_shadow_async";
	if (p_ticket <= 0 || p_ticket != voxel_worker_ticket_)
		return envelope(operation, "rejected", "unknown_ticket");
	if (!voxel_worker_finished_.load(std::memory_order_acquire)) {
		voxel_worker_cancelled_ = true;
		voxel_worker_cancel_token_->store(true, std::memory_order_relaxed);
		Dictionary result = envelope(operation, "pending", "worker_draining");
		result["asyncSchema"] = VOXEL_BLOCK_ASYNC_SCHEMA;
		result["ticket"] = p_ticket;
		result["cancelled"] = true;
		return result;
	}
	if (voxel_worker_.joinable()) voxel_worker_.join();
	voxel_worker_ticket_ = 0;
	voxel_worker_cancel_token_.reset();
	voxel_worker_cancelled_ = false;
	voxel_worker_result_.reset();
	voxel_worker_error_ = nullptr;
	Dictionary result = envelope(operation, "ready");
	result["asyncSchema"] = VOXEL_BLOCK_ASYNC_SCHEMA;
	result["ticket"] = p_ticket;
	result["cancelled"] = true;
	return result;
}

Dictionary NativeWorldBackend::encode_voxel_block_shadow(const Dictionary &p_request) const {
	constexpr const char *operation = "encode_voxel_block_shadow";
	if (!state_ || !shaping_registry_) return envelope(operation, "failed", "backend_not_ready");
	try {
		if (require_protocol_string(p_request.get("schema", Variant()), "schema") != VOXEL_BLOCK_REQUEST_SCHEMA)
			throw std::invalid_argument("unsupported native effective voxel block request schema");
		const Vector3i origin = require_vector3i(p_request.get("origin", Variant()), "origin");
		const Vector3i size = require_vector3i(p_request.get("size", Variant()), "size");
		const std::int64_t lod = require_i64(p_request.get("lod", Variant()), "lod");
		// Admit the bounded block before computing even one page dependency. The
		// pure core independently repeats these limits before byte allocation.
		if (size.x <= 0 || size.y <= 0 || size.z <= 0
				|| size.x > 32 || size.y > 32 || size.z > 32 || lod < 0 || lod > 24)
			throw std::invalid_argument("native shadow voxel block dimensions or LOD are invalid");
		const std::int64_t scale = std::int64_t{1} << lod;
		auto checked_cell = [scale](const std::int32_t base, const std::int32_t offset) {
			const std::int64_t value = static_cast<std::int64_t>(base) + static_cast<std::int64_t>(offset) * scale;
			// base is already int32, offset is admitted nonnegative, and scale is
			// positive: the value cannot cross INT32_MIN, only INT32_MAX.
			if (value > std::numeric_limits<std::int32_t>::max())
				throw std::out_of_range("native shadow voxel block coordinate overflows int32");
			return static_cast<std::int32_t>(value);
		};
		auto page_axis = [](const std::int32_t cell) {
			constexpr std::int32_t page_cells = NativeTerrainShapingSnapshot::PAGE_CELLS;
			return cell / page_cells - static_cast<std::int32_t>(cell % page_cells < 0);
		};
		(void)checked_cell(origin.y, size.y - 1);
		std::vector<std::int32_t> x_pages;
		std::vector<std::int32_t> z_pages;
		for (std::int32_t x = 0; x < size.x; ++x) {
			const std::int32_t page = page_axis(checked_cell(origin.x, x));
			if (x_pages.empty() || x_pages.back() != page) x_pages.push_back(page);
		}
		for (std::int32_t z = 0; z < size.z; ++z) {
			const std::int32_t page = page_axis(checked_cell(origin.z, z));
			if (z_pages.empty() || z_pages.back() != page) z_pages.push_back(page);
		}
		const WorldPhysicalContentIdentity source_identity = state_->source_identity();
		const WorldPhysicalContentIdentity registry_identity = shaping_registry_->content_identity();
		const WorldPhysicalContentIdentity town_policy_identity = shaping_registry_->policy_content_identity();
		const std::uint64_t registry_revision = shaping_registry_->revision();
		const WorldDeltaPinnedSnapshot deltas = state_->pin_deltas();
		std::vector<NativeTerrainPageKey> dependencies;
		for (const std::int32_t z : z_pages) for (const std::int32_t x : x_pages) {
			const auto pages = world_effective_shaping_dependencies(state_->definition(), {x, z});
			dependencies.insert(dependencies.end(), pages.begin(), pages.end());
		}
		auto less_page = [](const NativeTerrainPageKey a, const NativeTerrainPageKey b) {
			return a.z < b.z || (a.z == b.z && a.x < b.x);
		};
		std::sort(dependencies.begin(), dependencies.end(), less_page);
		dependencies.erase(std::unique(dependencies.begin(), dependencies.end()), dependencies.end());
		std::vector<NativeTerrainShapingPagePin> pins;
		pins.reserve(dependencies.size());
		std::vector<NativeSiteSourceRegionKey> unresolved;
		std::vector<NativeSiteSourceRegionKey> failed_regions;
		for (const NativeTerrainPageKey page : dependencies) {
			NativeTerrainShapingPagePin pin = shaping_registry_->pin_page(page, town_overrides_for_page(page));
			for (const auto region : pin.unresolved_dependencies())
				if (std::find(unresolved.begin(), unresolved.end(), region) == unresolved.end())
					unresolved.push_back(region);
			for (const auto region : pin.failed_dependencies())
				if (std::find(failed_regions.begin(), failed_regions.end(), region) == failed_regions.end())
					failed_regions.push_back(region);
			pins.push_back(std::move(pin));
		}
		if (state_->terrain_delta_revision() != deltas.revision()
				|| shaping_registry_->revision() != registry_revision
				|| !(shaping_registry_->content_identity() == registry_identity)
				|| !(state_->source_identity() == source_identity))
			return envelope(operation, "pending", "source_changed_retry");
		if (!failed_regions.empty()) {
			Dictionary result = envelope(operation, "failed", "shaping_dependency_failed");
			result["failedRegions"] = regions_array(failed_regions);
			return result;
		}
		if (!unresolved.empty()) {
			Dictionary result = envelope(operation, "pending", "shaping_dependency_unresolved");
			result["unresolvedRegions"] = regions_array(unresolved);
			result["shapingRegistryRevision"] = static_cast<int64_t>(registry_revision);
			result["shapingRegistryIdentity"] = identity_dictionary(registry_identity);
			return result;
		}
		const NativeEffectiveVoxelBlock block = encode_native_multi_page_voxel_block(
			state_->definition(), deltas, pins,
			{cell_coord(origin), cell_coord(size), static_cast<std::uint32_t>(lod)});
		if (state_->terrain_delta_revision() != deltas.revision()
				|| shaping_registry_->revision() != registry_revision
				|| !(shaping_registry_->content_identity() == registry_identity)
				|| !(state_->source_identity() == source_identity))
			return envelope(operation, "pending", "source_changed_retry");
		auto packed = [](const std::vector<std::uint8_t> &bytes) {
			PackedByteArray result;
			result.resize(static_cast<int64_t>(bytes.size()));
			std::memcpy(result.ptrw(), bytes.data(), bytes.size());
			return result;
		};
		Dictionary result = envelope(operation, "ready");
		result["resultSchema"] = VOXEL_BLOCK_RESULT_SCHEMA;
		result["shadowOnly"] = true;
		result["productionCutover"] = false;
		result["origin"] = vector3i(block.origin);
		result["size"] = vector3i(block.size);
		result["lod"] = static_cast<int64_t>(block.lod);
		result["sourceIdentity"] = identity_dictionary(source_identity);
		result["pinIdentity"] = identity_dictionary(block.pin_identity);
		result["blockContentIdentity"] = identity_dictionary(block.block_content_identity);
		result["terrainDeltaRevision"] = static_cast<int64_t>(block.terrain_delta_revision);
		result["shapingRegistryRevision"] = static_cast<int64_t>(block.shaping_registry_revision);
		result["shapingRegistryIdentity"] = identity_dictionary(registry_identity);
		result["townPolicyIdentity"] = identity_dictionary(town_policy_identity);
		result["ownerInstanceId"] = static_cast<int64_t>(get_instance_id());
		result["primaryPageCount"] = static_cast<int64_t>(x_pages.size() * z_pages.size());
		result["shapingPageCount"] = static_cast<int64_t>(dependencies.size());
		result["sdf16Le"] = packed(block.sdf16_le);
		result["indices8"] = packed(block.indices8);
		result["data5_8"] = packed(block.data5_8);
		return result;
	} catch (const std::exception &error) {
		return failure(operation, error);
	}
}
