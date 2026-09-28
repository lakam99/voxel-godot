#include "n2_vertical_slice_adapter.h"

#include "fast_noise_compat.hpp"
#include "sha256.hpp"
#include "terrain_meshing.hpp"
#include "terrain_source.hpp"
#include "world_identity.hpp"

#include <godot_cpp/classes/json.hpp>
#include <godot_cpp/classes/marshalls.hpp>
#include <godot_cpp/variant/array.hpp>
#include <godot_cpp/variant/packed_byte_array.hpp>
#include <godot_cpp/variant/packed_float32_array.hpp>
#include <godot_cpp/variant/packed_float64_array.hpp>
#include <godot_cpp/variant/packed_int32_array.hpp>
#include <godot_cpp/variant/packed_string_array.hpp>
#include <godot_cpp/variant/packed_vector3_array.hpp>
#include <godot_cpp/variant/string.hpp>
#include <godot_cpp/variant/vector3.hpp>

#include <array>
#include <chrono>
#include <cmath>
#include <cstdint>
#include <cstring>
#include <limits>
#include <stdexcept>
#include <string>
#include <vector>

using namespace godot;
using namespace voxel::world_backend;

namespace {

constexpr std::size_t SAMPLE_COUNT = 33915U;
constexpr std::size_t PREPARED_BYTE_CAP = 4194304U;
constexpr std::size_t COLLISION_TRIANGLE_CAP = 200000U;

const std::array<const char *, 17> MATERIAL_NAMES = {{
	"air", "grass", "dirt", "stone", "sand", "snow", "deepStone", "bedrock",
	"clay", "gravel", "coalOre", "ironOre", "crystalOre", "copperOre", "mud", "water", "lava",
}};
const std::array<const char *, 15> BIOME_NAMES = {{
	"plains", "forest", "swamp", "desert", "savanna", "snow", "taiga", "tundra",
	"ocean", "beach", "town", "underground", "deep_underground", "underground_air", "alpine",
}};
const std::array<const char *, 3> FLUID_NAMES = {{"", "water", "lava"}};
const std::array<const char *, 2> SOURCE_KIND_NAMES = {{"generated", "typed_delta"}};

std::string utf8(const String &value) {
	const CharString encoded = value.utf8();
	return std::string(encoded.get_data(), static_cast<std::size_t>(encoded.length()));
}

String text(const std::string &value) {
	return String(value.c_str());
}

Dictionary require_dictionary(const Variant &value, const char *field) {
	if (value.get_type() != Variant::DICTIONARY) {
		throw std::invalid_argument(std::string(field) + " must be a Dictionary");
	}
	return Dictionary(value);
}

Array require_array(const Variant &value, const char *field, const int64_t count = -1) {
	if (value.get_type() != Variant::ARRAY) {
		throw std::invalid_argument(std::string(field) + " must be an Array");
	}
	Array result = value;
	if (count >= 0 && result.size() != count) {
		throw std::invalid_argument(std::string(field) + " has the wrong element count");
	}
	return result;
}

std::int64_t require_integer(const Variant &value, const char *field) {
	if (value.get_type() != Variant::INT) {
		throw std::invalid_argument(std::string(field) + " must be an integer");
	}
	return static_cast<std::int64_t>(value);
}

double require_number(const Variant &value, const char *field) {
	if (value.get_type() != Variant::FLOAT && value.get_type() != Variant::INT) {
		throw std::invalid_argument(std::string(field) + " must be numeric");
	}
	const double result = static_cast<double>(value);
	if (!std::isfinite(result)) {
		throw std::invalid_argument(std::string(field) + " must be finite");
	}
	return result;
}

bool require_bool(const Variant &value, const char *field) {
	if (value.get_type() != Variant::BOOL) {
		throw std::invalid_argument(std::string(field) + " must be a bool");
	}
	return static_cast<bool>(value);
}

String require_string(const Variant &value, const char *field) {
	if (value.get_type() != Variant::STRING) {
		throw std::invalid_argument(std::string(field) + " must be a String");
	}
	return String(value);
}

std::int32_t checked_i32(const Variant &value, const char *field) {
	const std::int64_t parsed = require_integer(value, field);
	if (parsed < std::numeric_limits<std::int32_t>::min() || parsed > std::numeric_limits<std::int32_t>::max()) {
		throw std::invalid_argument(std::string(field) + " exceeds int32");
	}
	return static_cast<std::int32_t>(parsed);
}

std::int32_t checked_json_i32(const Variant &value, const char *field) {
	if (value.get_type() == Variant::INT) return checked_i32(value, field);
	if (value.get_type() != Variant::FLOAT) {
		throw std::invalid_argument(std::string(field) + " must be an integral JSON number");
	}
	const double parsed = require_number(value, field);
	if (std::trunc(parsed) != parsed || parsed < std::numeric_limits<std::int32_t>::min()
			|| parsed > std::numeric_limits<std::int32_t>::max()) {
		throw std::invalid_argument(std::string(field) + " must be an exact int32 JSON number");
	}
	return static_cast<std::int32_t>(parsed);
}

CellCoord parse_json_coord(const Variant &value, const char *field) {
	const Array values = require_array(value, field, 3);
	return {checked_json_i32(values[0], field), checked_json_i32(values[1], field), checked_json_i32(values[2], field)};
}

std::uint64_t checked_positive_u64(const Variant &value, const char *field) {
	const std::int64_t parsed = require_integer(value, field);
	if (parsed <= 0) {
		throw std::invalid_argument(std::string(field) + " must be positive");
	}
	return static_cast<std::uint64_t>(parsed);
}

CellCoord parse_coord(const Variant &value, const char *field) {
	const Array values = require_array(value, field, 3);
	return {checked_i32(values[0], field), checked_i32(values[1], field), checked_i32(values[2], field)};
}

Vec3d parse_vec3(const Variant &value, const char *field) {
	const Array values = require_array(value, field, 3);
	return {require_number(values[0], field), require_number(values[1], field), require_number(values[2], field)};
}

void expect_coord(const CellCoord &actual, const CellCoord &expected, const char *field) {
	if (!(actual == expected)) {
		throw std::invalid_argument(std::string(field) + " differs from the frozen N2 contract");
	}
}

void expect_string(const Variant &value, const char *expected, const char *field) {
	if (require_string(value, field) != expected) {
		throw std::invalid_argument(std::string(field) + " differs from the frozen N2 contract");
	}
}

void validate_caps(const Dictionary &request) {
	const Dictionary caps = require_dictionary(request.get("caps", Variant()), "caps");
	const std::array<std::pair<const char *, std::int64_t>, 8> expected = {{
		{"admittedRequests", 4}, {"inFlightBuilds", 1}, {"preparedResults", 1},
		{"preparedBytes", 4194304}, {"installedBodies", 1}, {"installedShapes", 3},
		{"collisionTriangles", 200000}, {"retiredShapeSets", 4},
	}};
	for (const auto &entry : expected) {
		if (require_integer(caps.get(entry.first, Variant()), entry.first) != entry.second) {
			throw std::invalid_argument(std::string("caps.") + entry.first + " differs from the frozen N2 contract");
		}
	}
}

void validate_regions(const Dictionary &request) {
	const Dictionary bounds = require_dictionary(request.get("sampleBounds", Variant()), "sampleBounds");
	expect_coord(parse_coord(bounds.get("minimum", Variant()), "sampleBounds.minimum"), {-49, -17, -17}, "sampleBounds.minimum");
	expect_coord(parse_coord(bounds.get("maximumExclusive", Variant()), "sampleBounds.maximumExclusive"), {-14, 34, 2}, "sampleBounds.maximumExclusive");
	const Array tiles = require_array(request.get("tileCores", Variant()), "tileCores", 2);
	const std::array<CellRegion, 2> regions = {{{{-48, -16, -16}, {-32, 32, 0}}, {{-32, -16, -16}, {-16, 32, 0}}}};
	const std::array<std::array<std::int32_t, 2>, 2> keys = {{{{-3, -1}}, {{-2, -1}}}};
	for (std::size_t index = 0; index < regions.size(); ++index) {
		const Dictionary tile = require_dictionary(tiles[static_cast<int64_t>(index)], "tileCores[]");
		const Array key = require_array(tile.get("key", Variant()), "tileCores[].key", 2);
		if (checked_i32(key[0], "tile key x") != keys[index][0] || checked_i32(key[1], "tile key z") != keys[index][1]) {
			throw std::invalid_argument("tile key differs from the frozen N2 contract");
		}
		expect_coord(parse_coord(tile.get("minimum", Variant()), "tile minimum"), regions[index].minimum, "tile minimum");
		expect_coord(parse_coord(tile.get("maximumExclusive", Variant()), "tile maximum"), regions[index].maximum_exclusive, "tile maximum");
	}
}

void validate_blocker_request(const Dictionary &request) {
	const Array blockers = require_array(request.get("blockers", Variant()), "blockers", 1);
	const Dictionary blocker = require_dictionary(blockers[0], "blockers[0]");
	expect_string(blocker.get("id", Variant()), "n2:blocker:tile-b:-24,-10", "blocker.id");
	expect_string(blocker.get("semanticClass", Variant()), "fixture_obstacle", "blocker.semanticClass");
	expect_string(blocker.get("physicalIntent", Variant()), "blocker", "blocker.physicalIntent");
	if (!(parse_vec3(blocker.get("center", Variant()), "blocker.center") == Vec3d{-32.4, 16.497000000000003, -13.5}) ||
		!(parse_vec3(blocker.get("size", Variant()), "blocker.size") == Vec3d{1.35, 2.7, 1.35})) {
		throw std::invalid_argument("blocker geometry differs from the frozen N2 contract");
	}
}

std::vector<TerrainDelta> parse_deltas(const Dictionary &request, const std::uint64_t source_revision) {
	const String encoded = require_string(request.get("typedDeltaBytesBase64", Variant()), "typedDeltaBytesBase64");
	if (encoded.is_empty()) {
		if (source_revision != 1U) throw std::invalid_argument("baseline source revision must be one");
		return {};
	}
	if (source_revision != 2U) throw std::invalid_argument("edited source revision must be two");
	Marshalls *marshalls = Marshalls::get_singleton();
	if (marshalls == nullptr) throw std::runtime_error("Marshalls singleton unavailable");
	const PackedByteArray bytes = marshalls->base64_to_raw(encoded);
	if (bytes.is_empty()) throw std::invalid_argument("typed delta base64 decoded to no bytes");
	const Variant decoded_value = JSON::parse_string(bytes.get_string_from_utf8());
	const Dictionary decoded = require_dictionary(decoded_value, "typed delta envelope");
	expect_string(decoded.get("schema", Variant()), "n2-typed-terrain-deltas/v1", "typed delta schema");
	expect_string(decoded.get("seed", Variant()), "atlas-1492", "typed delta seed");
	expect_string(decoded.get("coordinateEncoding", Variant()), "signed-int32-x-y-z", "typed delta coordinateEncoding");
	expect_string(decoded.get("densityEncoding", Variant()), "ieee754-binary64", "typed delta densityEncoding");
	const Array records = require_array(decoded.get("records", Variant()), "typed delta records", 4);
	const std::array<CellCoord, 4> coordinates = {{{-33, 12, -5}, {-32, 12, -5}, {-33, 12, -4}, {-32, 12, -4}}};
	std::vector<TerrainDelta> result;
	result.reserve(4U);
	for (std::size_t index = 0; index < coordinates.size(); ++index) {
		const Dictionary record = require_dictionary(records[static_cast<int64_t>(index)], "typed delta record");
		expect_coord(parse_json_coord(record.get("coordinate", Variant()), "delta coordinate"), coordinates[index], "delta coordinate");
		if (require_number(record.get("density", Variant()), "delta density") != -1.35 || require_bool(record.get("solid", Variant()), "delta solid")) {
			throw std::invalid_argument("typed delta is not exact explicit air");
		}
		if (checked_json_i32(record.get("materialId", Variant()), "delta materialId") != 0 ||
			checked_json_i32(record.get("surfaceBiomeId", Variant()), "delta surfaceBiomeId") != 2 ||
			checked_json_i32(record.get("resolvedBiomeId", Variant()), "delta resolvedBiomeId") != 13 ||
			checked_json_i32(record.get("fluidId", Variant()), "delta fluidId") != 0 ||
			checked_json_i32(record.get("deltaRevision", Variant()), "delta revision") != 1) {
			throw std::invalid_argument("typed delta IDs or revision differ from the frozen N2 contract");
		}
		expect_string(record.get("materialName", Variant()), "air", "delta materialName");
		expect_string(record.get("surfaceBiomeName", Variant()), "swamp", "delta surfaceBiomeName");
		expect_string(record.get("resolvedBiomeName", Variant()), "underground_air", "delta resolvedBiomeName");
		expect_string(record.get("fluid", Variant()), "", "delta fluid");
		const std::string id = "n2:seam-air:" + std::to_string(index);
		if (utf8(require_string(record.get("deltaId", Variant()), "delta id")) != id) {
			throw std::invalid_argument("typed delta ID differs from the frozen order");
		}
		result.push_back({id, 1U, coordinates[index], {-1.35, false, TerrainMaterialId::air,
			TerrainBiomeId::underground_air, TerrainFluidId::none}});
	}
	return result;
}

RequestAuthority parse_authority(const Dictionary &request, Dictionary &echo) {
	echo = require_dictionary(request.get("requestIdentity", Variant()), "requestIdentity");
	const std::uint64_t owner = checked_positive_u64(echo.get("ownerGeneration", Variant()), "ownerGeneration");
	const std::uint64_t revision = checked_positive_u64(echo.get("sourceRevision", Variant()), "sourceRevision");
	const std::uint64_t cancellation = checked_positive_u64(echo.get("cancellationEpoch", Variant()), "cancellationEpoch");
	const auto source = canonical_source_identity(legacy_frozen_source_identity(atlas_1492_code_points()));
	return {source.digest, {owner}, {cancellation}, {revision}};
}

template <std::size_t N>
PackedStringArray packed_names(const std::array<const char *, N> &names) {
	PackedStringArray result;
	for (const char *name : names) result.append(name);
	return result;
}

Array noise_fixtures() {
	const FastNoiseCompat noise(1769472797U);
	const std::array<Vec3d, 4> coordinates = {{{0.0, 0.0, 0.0}, {-49.0, -17.0, -17.0},
		{-32.0, -2.0, -5.0}, {1048576.25, -524288.5, 262144.75}}};
	Array result;
	for (const FastNoiseConfiguration &configuration : terrain_noise_configurations()) {
		for (const Vec3d &coordinate : coordinates) {
			const float two_d = noise.sample_2d(configuration.channel, coordinate.x, coordinate.z);
			const float three_d = noise.sample_3d(configuration.channel, coordinate.x, coordinate.y, coordinate.z);
			std::uint32_t two_bits = 0;
			std::uint32_t three_bits = 0;
			std::memcpy(&two_bits, &two_d, sizeof(two_bits));
			std::memcpy(&three_bits, &three_d, sizeof(three_bits));
			Array coordinate_value;
			coordinate_value.append(coordinate.x); coordinate_value.append(coordinate.y); coordinate_value.append(coordinate.z);
			Dictionary row;
			row["configuration"] = configuration.name;
			row["seed"] = noise.seed(configuration.channel);
			row["coordinate"] = coordinate_value;
			row["twoDBits"] = static_cast<int64_t>(two_bits);
			row["threeDBits"] = static_cast<int64_t>(three_bits);
			result.append(row);
		}
	}
	return result;
}

String artifact_key(const Sha256Digest &snapshot, const ArtifactKind kind, const char *channel_policy) {
	ArtifactIdentity identity;
	identity.snapshot_digest = snapshot;
	identity.kind = kind;
	identity.builder_revision = 1;
	identity.detail_level = 0;
	identity.lod_level = 0;
	identity.channel_policy = channel_policy;
	identity.seam_policy = "half-open-xz";
	identity.halo_policy = "gradient-one-beyond-inclusive-corners";
	return text(canonical_artifact_identity(identity).digest_hex());
}

double elapsed_ms(const std::chrono::steady_clock::time_point start, const std::chrono::steady_clock::time_point end) {
	return std::chrono::duration<double, std::milli>(end - start).count();
}

std::size_t ascii_bytes(const std::string &value) { return value.size(); }

void append_f64_le(std::vector<std::uint8_t> &bytes, const double value) {
	std::uint64_t bits = 0;
	std::memcpy(&bits, &value, sizeof(bits));
	for (std::size_t index = 0; index < sizeof(bits); ++index) {
		bytes.push_back(static_cast<std::uint8_t>((bits >> (index * 8U)) & 0xffU));
	}
}

Dictionary blocker_dictionary(const DeclaredFeatureBlocker &blocker) {
	Array center; center.append(blocker.center.x); center.append(blocker.center.y); center.append(blocker.center.z);
	Array size; size.append(blocker.size.x); size.append(blocker.size.y); size.append(blocker.size.z);
	Dictionary result;
	result["id"] = text(blocker.stable_id);
	result["center"] = center;
	result["size"] = size;
	result["semanticClass"] = text(blocker.semantic_class);
	result["physicalIntent"] = text(blocker.physical_intent);
	return result;
}

const char *status_text(const TerrainMeshingStatus status) {
	switch (status) {
		case TerrainMeshingStatus::ready: return "ready";
		case TerrainMeshingStatus::invalid_request: return "invalid_request";
		case TerrainMeshingStatus::unsupported_detail: return "unsupported_detail";
		case TerrainMeshingStatus::incomplete_halo: return "incomplete_halo";
		case TerrainMeshingStatus::coordinate_overflow: return "coordinate_overflow";
		case TerrainMeshingStatus::nonfinite_geometry: return "nonfinite_geometry";
		case TerrainMeshingStatus::wrong_world: return "wrong_world";
		case TerrainMeshingStatus::stale_owner: return "stale_owner";
		case TerrainMeshingStatus::cancelled: return "cancelled";
		case TerrainMeshingStatus::stale_source: return "stale_source";
	}
	return "unknown";
}

} // namespace

Dictionary prepare_n2_vertical_slice(const Dictionary &request) {
	Dictionary result;
	result["schema"] = "n2-native-vertical-slice-result/v1";
	result["ok"] = false;
	try {
		const auto started = std::chrono::steady_clock::now();
		expect_string(request.get("schema", Variant()), "n2-native-vertical-slice-request/v1", "request schema");
		expect_string(request.get("seed", Variant()), "atlas-1492", "seed");
		if (require_integer(request.get("lod", Variant()), "lod") != 0 || require_integer(request.get("step", Variant()), "step") != 1) {
			throw std::invalid_argument("N2 supports only LOD 0 and step 1");
		}
		validate_regions(request);
		validate_caps(request);
		validate_blocker_request(request);
		Dictionary identity_echo;
		const RequestAuthority authority = parse_authority(request, identity_echo);
		const auto request_finished = std::chrono::steady_clock::now();
		const std::vector<TerrainDelta> deltas = parse_deltas(request, authority.source_revision.value);
		const auto delta_finished = std::chrono::steady_clock::now();
		TerrainSourceRequest source_request = n2_terrain_source_request(authority,
			"n2:" + std::to_string(authority.owner.value) + ":" + std::to_string(authority.source_revision.value)
				+ ":" + std::to_string(authority.cancellation.value), deltas);
		const TerrainSnapshot snapshot = build_terrain_snapshot(source_request, authority);
		if (snapshot.cells().size() != SAMPLE_COUNT) throw std::runtime_error("native snapshot sample count differs from N2 contract");
		const auto source_finished = std::chrono::steady_clock::now();

		PackedFloat64Array density;
		PackedFloat64Array surface_y;
		PackedByteArray surface_y_valid;
		PackedByteArray solid;
		PackedByteArray materials;
		PackedByteArray surface_biomes;
		PackedByteArray resolved_biomes;
		PackedByteArray fluids;
		PackedByteArray source_kinds;
		PackedInt32Array source_revisions;
		Array sparse_sources;
		for (std::size_t index = 0; index < snapshot.cells().size(); ++index) {
			const TerrainCell &cell = snapshot.cells()[index];
			density.append(cell.density);
			const bool generated = cell.provenance == TerrainProvenanceKind::generated;
			surface_y.append(generated ? cell.surface_y : 0.0);
			surface_y_valid.append(generated ? 1U : 0U);
			solid.append(cell.solid ? 1U : 0U);
			materials.append(static_cast<std::uint8_t>(cell.material));
			surface_biomes.append(static_cast<std::uint8_t>(cell.surface_biome));
			resolved_biomes.append(static_cast<std::uint8_t>(cell.resolved_biome));
			fluids.append(static_cast<std::uint8_t>(cell.fluid));
			source_kinds.append(static_cast<std::uint8_t>(cell.provenance));
			if (cell.provenance_revision > static_cast<std::uint64_t>(std::numeric_limits<std::int32_t>::max())) {
				throw std::runtime_error("source revision exceeds packed int32 contract");
			}
			source_revisions.append(static_cast<std::int32_t>(cell.provenance_revision));
			if (!generated) {
				Dictionary sparse;
				sparse["ordinal"] = static_cast<int64_t>(index);
				sparse["id"] = text(cell.provenance_id);
				sparse["revision"] = static_cast<int64_t>(cell.provenance_revision);
				sparse_sources.append(sparse);
			}
		}
		Dictionary columns;
		columns["density"] = density; columns["surfaceY"] = surface_y;
		columns["surfaceYValid"] = surface_y_valid; columns["solid"] = solid;
		columns["materialIds"] = materials; columns["surfaceBiomeIds"] = surface_biomes;
		columns["resolvedBiomeIds"] = resolved_biomes; columns["fluidIds"] = fluids;
		columns["sourceKinds"] = source_kinds; columns["sourceRevisions"] = source_revisions;
		Dictionary name_tables;
		name_tables["materialNames"] = packed_names(MATERIAL_NAMES);
		name_tables["biomeNames"] = packed_names(BIOME_NAMES);
		name_tables["fluidNames"] = packed_names(FLUID_NAMES);
		name_tables["sourceKindNames"] = packed_names(SOURCE_KIND_NAMES);
		Dictionary source;
		source["sampleCount"] = static_cast<int64_t>(SAMPLE_COUNT);
		source["ordering"] = "x_fastest_then_z_then_y";
		source["snapshotDigest"] = text(snapshot.digest_hex());
		source["generatedSourceId"] = "generator:atlas-1492";
		source["columns"] = columns;
		source["sparseSources"] = sparse_sources;
		source["nameTables"] = name_tables;
		source["noiseFloatBits"] = noise_fixtures();

		const std::array<CellRegion, 2> tile_regions = {{{{-48, -16, -16}, {-32, 32, 0}}, {{-32, -16, -16}, {-16, 32, 0}}}};
		const std::array<std::array<std::int32_t, 2>, 2> tile_keys = {{{{-3, -1}}, {{-2, -1}}}};
		Array tile_triangles;
		std::size_t terrain_triangle_count = 0;
		std::size_t blocker_triangle_count = 0;
		std::size_t collision_bytes = 0;
		for (std::size_t tile_index = 0; tile_index < tile_regions.size(); ++tile_index) {
			TerrainTileMeshRequest mesh_request;
			mesh_request.owned_cube_region = tile_regions[tile_index];
			mesh_request.local_origin = {0, 0, 0};
			mesh_request.cell_size = 1.35;
			mesh_request.detail_level = 0;
			mesh_request.lod_level = 0;
			mesh_request.step_cells = 1;
			mesh_request.current_authority = authority;
			const TerrainCollisionBuild built = build_terrain_collision(snapshot, mesh_request);
			if (!built.ready()) throw std::runtime_error(std::string("collision build failed: ") + status_text(built.status));
			PackedVector3Array vertices;
			std::vector<std::uint8_t> canonical_vertices;
			std::size_t tile_blockers = 0;
			for (const TerrainCollisionTriangle &triangle : built.collision.triangles) {
				if (triangle.source == TerrainSurfaceSource::declared_feature_blocker) {
					if (triangle.source_id != "n2:blocker:tile-b:-24,-10") throw std::runtime_error("unknown blocker triangle source");
					++tile_blockers;
					continue;
				}
				++terrain_triangle_count;
				// The pure core uses conventional counter-clockwise outward
				// winding. Godot's clockwise front-face convention requires the
				// final two vertices reversed for one-sided concave collision.
				for (const std::size_t corner : std::array<std::size_t, 3>{{0U, 2U, 1U}}) {
					const Vec3d &position = triangle.positions[corner];
					vertices.append(Vector3(position.x, position.y, position.z));
					append_f64_le(canonical_vertices, position.x);
					append_f64_le(canonical_vertices, position.y);
					append_f64_le(canonical_vertices, position.z);
				}
			}
			blocker_triangle_count += tile_blockers;
			if ((tile_index == 0U && tile_blockers != 0U) || (tile_index == 1U && tile_blockers != 12U)) {
				throw std::runtime_error("blocker triangle partition differs from N2 contract");
			}
			collision_bytes += static_cast<std::size_t>(vertices.size()) * 3U * sizeof(float);
			Array key; key.append(tile_keys[tile_index][0]); key.append(tile_keys[tile_index][1]);
			Dictionary tile;
			tile["tileKey"] = key;
			tile["coordinateFrame"] = "world";
			tile["includesDeclaredBlockers"] = false;
			tile["vertices"] = vertices;
			tile["geometrySha256"] = text(sha256_hex(sha256(canonical_vertices)));
			tile_triangles.append(tile);
		}
		if (terrain_triangle_count + blocker_triangle_count > COLLISION_TRIANGLE_CAP) {
			throw std::runtime_error("collision triangle cap exceeded");
		}
		Array blockers;
		for (const DeclaredFeatureBlocker &blocker : snapshot.blockers()) blockers.append(blocker_dictionary(blocker));
		Dictionary collision;
		collision["snapshotDigest"] = text(snapshot.digest_hex());
		collision["artifactKey"] = artifact_key(snapshot.digest(), ArtifactKind::terrain_collision, "collision-triangles+declared-blockers");
		collision["tileTriangles"] = tile_triangles;
		collision["blockers"] = blockers;
		collision["terrainTriangleCount"] = static_cast<int64_t>(terrain_triangle_count);
		collision["blockerTriangleCount"] = static_cast<int64_t>(blocker_triangle_count);
		const auto collision_finished = std::chrono::steady_clock::now();

		PackedFloat32Array sdf_values;
		PackedByteArray indices;
		PackedByteArray data5;
		for (const TerrainCell &cell : snapshot.cells()) {
			sdf_values.append(static_cast<float>(-cell.density / 1.35));
			const std::uint8_t material = static_cast<std::uint8_t>(cell.material);
			indices.append(material);
			data5.append(material);
		}
		Dictionary render;
		render["snapshotDigest"] = text(snapshot.digest_hex());
		render["artifactKey"] = artifact_key(snapshot.digest(), ArtifactKind::terrain_render, "sdf16+indices8+data5-8");
		render["sdfValues"] = sdf_values;
		render["indices"] = indices;
		render["data5"] = data5;
		const auto render_finished = std::chrono::steady_clock::now();

		const std::size_t source_column_bytes = SAMPLE_COUNT * (sizeof(double) * 2U + sizeof(std::int32_t) + 7U);
		const std::size_t render_bytes = SAMPLE_COUNT * (sizeof(float) + 2U);
		// Three snapshot-digest fields, two artifact keys, and two per-tile
		// geometry digests are variable packed string payloads.
		std::size_t string_bytes = ascii_bytes("generator:atlas-1492") + snapshot.digest_hex().size() * 7U;
		for (const char *name : MATERIAL_NAMES) string_bytes += std::char_traits<char>::length(name);
		for (const char *name : BIOME_NAMES) string_bytes += std::char_traits<char>::length(name);
		for (const char *name : FLUID_NAMES) string_bytes += std::char_traits<char>::length(name);
		for (const char *name : SOURCE_KIND_NAMES) string_bytes += std::char_traits<char>::length(name);
		for (const TerrainCell &cell : snapshot.cells()) if (cell.provenance == TerrainProvenanceKind::typed_delta) string_bytes += cell.provenance_id.size();
		for (const DeclaredFeatureBlocker &blocker : snapshot.blockers()) {
			string_bytes += blocker.stable_id.size() + blocker.semantic_class.size() + blocker.physical_intent.size();
		}
		const std::size_t sparse_bytes = sparse_sources.size() * (sizeof(std::int64_t) * 2U);
		const std::size_t blocker_bytes = snapshot.blockers().size() * sizeof(double) * 6U;
		const std::size_t noise_bytes = 20U * (sizeof(std::int32_t) * 3U + sizeof(double) * 3U);
		const std::size_t prepared_bytes = source_column_bytes + render_bytes + collision_bytes + string_bytes + sparse_bytes + blocker_bytes + noise_bytes;
		Dictionary accounting;
		accounting["sourcePackedColumnsBytes"] = static_cast<int64_t>(source_column_bytes);
		accounting["renderPackedBytes"] = static_cast<int64_t>(render_bytes);
		accounting["collisionPackedBytes"] = static_cast<int64_t>(collision_bytes);
		accounting["stringBytes"] = static_cast<int64_t>(string_bytes);
		accounting["sparseMetadataBytes"] = static_cast<int64_t>(sparse_bytes);
		accounting["blockerGeometryBytes"] = static_cast<int64_t>(blocker_bytes);
		accounting["noiseFixtureBytes"] = static_cast<int64_t>(noise_bytes);
		accounting["scope"] = "native variable payload; excludes Variant container overhead and fixed object headers";
		accounting["total"] = static_cast<int64_t>(prepared_bytes);
		if (prepared_bytes == 0U || prepared_bytes > PREPARED_BYTE_CAP) throw std::runtime_error("prepared payload byte cap exceeded");

		Dictionary timings;
		timings["requestValidationMilliseconds"] = elapsed_ms(started, request_finished);
		timings["deltaResolutionMilliseconds"] = elapsed_ms(request_finished, delta_finished);
		timings["sourceMilliseconds"] = elapsed_ms(delta_finished, source_finished);
		timings["collisionMilliseconds"] = elapsed_ms(source_finished, collision_finished);
		timings["renderPackMilliseconds"] = elapsed_ms(collision_finished, render_finished);
		timings["nativeTotalMilliseconds"] = elapsed_ms(started, render_finished);
		Array compilation_order; compilation_order.append("source"); compilation_order.append("collision"); compilation_order.append("render_pack");
		timings["compilationOrder"] = compilation_order;
		Dictionary resource_usage;
		resource_usage["admittedRequests"] = 1;
		resource_usage["peakInFlightBuilds"] = 1;
		resource_usage["preparedResults"] = 1;
		resource_usage["preparedBytes"] = static_cast<int64_t>(prepared_bytes);
		resource_usage["installedBodiesExpected"] = 1;
		resource_usage["installedShapesExpected"] = 3;
		resource_usage["collisionTriangles"] = static_cast<int64_t>(terrain_triangle_count + blocker_triangle_count);
		resource_usage["retiredShapeSetsAwaitingRelease"] = 0;

		result["ok"] = true;
		result["requestIdentity"] = identity_echo;
		result["preparedPayloadBytes"] = static_cast<int64_t>(prepared_bytes);
		result["preparedPayloadAccounting"] = accounting;
		result["source"] = source;
		result["collision"] = collision;
		result["render"] = render;
		result["timings"] = timings;
		result["resourceUsage"] = resource_usage;
		return result;
	} catch (const std::exception &error) {
		result["reason"] = error.what();
		return result;
	}
}
