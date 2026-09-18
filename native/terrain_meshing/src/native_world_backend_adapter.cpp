#include "native_world_backend_adapter.h"

#include "biome_region_field.hpp"
#include "sha256.hpp"
#include "terrain_snapshot.hpp"

#include <godot_cpp/classes/engine.hpp>
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
#include <limits>
#include <stdexcept>
#include <string>
#include <utility>

using namespace godot;
using namespace voxel::world_backend;

namespace {

constexpr const char *ADAPTER_SCHEMA = "n3-native-world-backend-adapter/v1";
constexpr const char *BATCH_REQUEST_SCHEMA = "n3-effective-terrain-batch-request/v1";
constexpr const char *BATCH_RESULT_SCHEMA = "n3-effective-terrain-batch-result/v1";
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

std::uint64_t require_u64(const Variant &p_value, const char *p_field) {
	const std::int64_t value = require_i64(p_value, p_field);
	if (value < 0) throw std::out_of_range(std::string(p_field) + " must be nonnegative");
	return static_cast<std::uint64_t>(value);
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

WorldSourceDescriptor parse_source_descriptor(const Dictionary &p_request) {
	if (require_protocol_string(p_request.get("schema", Variant()), "schema") != "n3-native-world-backend-initialize/v1") {
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

} // namespace

void NativeEffectiveTerrainPage::_bind_methods() {
	ClassDB::bind_method(D_METHOD("status"), &NativeEffectiveTerrainPage::status);
	ClassDB::bind_method(D_METHOD("sample_batch", "request"), &NativeEffectiveTerrainPage::sample_batch);
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

void NativeWorldBackend::_bind_methods() {
	ClassDB::bind_method(D_METHOD("initialize", "request"), &NativeWorldBackend::initialize);
	ClassDB::bind_method(D_METHOD("status"), &NativeWorldBackend::status);
	ClassDB::bind_method(D_METHOD("shaping_requests", "primary_page"), &NativeWorldBackend::shaping_requests);
	ClassDB::bind_method(D_METHOD("apply_shaping_resolutions", "resolutions"), &NativeWorldBackend::apply_shaping_resolutions);
	ClassDB::bind_method(D_METHOD("commit_typed_cells", "request"), &NativeWorldBackend::commit_typed_cells);
	ClassDB::bind_method(D_METHOD("commit_durable_cells", "request"), &NativeWorldBackend::commit_durable_cells);
	ClassDB::bind_method(D_METHOD("pin_effective_page", "primary_page"), &NativeWorldBackend::pin_effective_page);
}

Dictionary NativeWorldBackend::initialize(const Dictionary &p_request) {
	if (initialization_attempted_) return envelope("initialize", "failed", "initialization_is_one_shot");
	initialization_attempted_ = true;
	try {
		WorldSourceDefinition definition(parse_source_descriptor(p_request));
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
