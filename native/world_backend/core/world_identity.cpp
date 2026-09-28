#include "world_identity.hpp"

#include "legacy_seed_hash.hpp"

#include <algorithm>
#include <cmath>
#include <cstring>
#include <limits>
#include <stdexcept>

namespace voxel::world_backend {
namespace {

class CanonicalWriter {
public:
    void append_magic(const char (&magic)[5]) {
        bytes_.insert(bytes_.end(), magic, magic + 4);
    }

    void append_u32(const std::uint32_t value) {
        for (unsigned shift = 0; shift < 32U; shift += 8U) {
            bytes_.push_back(static_cast<std::uint8_t>(value >> shift));
        }
    }

    void append_u8(const std::uint8_t value) {
        bytes_.push_back(value);
    }

    void append_i32(const std::int32_t value) {
        append_u32(static_cast<std::uint32_t>(value));
    }

    void append_u64(const std::uint64_t value) {
        for (unsigned shift = 0; shift < 64U; shift += 8U) {
            bytes_.push_back(static_cast<std::uint8_t>(value >> shift));
        }
    }

    void append_bytes(const std::uint8_t *data, const std::size_t size) {
        append_u32(canonical_u32_length(size));
        bytes_.insert(bytes_.end(), data, data + size);
    }

    std::vector<std::uint8_t> finish() {
        return std::move(bytes_);
    }

private:
    std::vector<std::uint8_t> bytes_;
};

bool is_continuation(const std::uint8_t byte) noexcept {
    return (byte & 0xc0U) == 0x80U;
}

bool is_valid_utf8(const std::string &text) noexcept {
    const auto *bytes = reinterpret_cast<const std::uint8_t *>(text.data());
    std::size_t index = 0;
    while (index < text.size()) {
        const std::uint8_t first = bytes[index];
        if (first <= 0x7fU) {
            ++index;
        } else if (first >= 0xc2U && first <= 0xdfU && index + 1U < text.size()
            && is_continuation(bytes[index + 1U])) {
            index += 2U;
        } else if (first >= 0xe0U && first <= 0xefU && index + 2U < text.size()
            && is_continuation(bytes[index + 1U]) && is_continuation(bytes[index + 2U])
            && !(first == 0xe0U && bytes[index + 1U] < 0xa0U)
            && !(first == 0xedU && bytes[index + 1U] >= 0xa0U)) {
            index += 3U;
        } else if (first >= 0xf0U && first <= 0xf4U && index + 3U < text.size()
            && is_continuation(bytes[index + 1U]) && is_continuation(bytes[index + 2U])
            && is_continuation(bytes[index + 3U])
            && !(first == 0xf0U && bytes[index + 1U] < 0x90U)
            && !(first == 0xf4U && bytes[index + 1U] >= 0x90U)) {
            index += 4U;
        } else {
            return false;
        }
    }
    return true;
}

bool utf8_less(const std::string &left, const std::string &right) noexcept {
    return std::lexicographical_compare(left.begin(), left.end(), right.begin(), right.end(),
        [](const char a, const char b) {
            return static_cast<unsigned char>(a) < static_cast<unsigned char>(b);
        });
}

void require_valid_name(const std::string &name, const char *field) {
    if (name.empty() || !is_valid_utf8(name)) {
        throw std::invalid_argument(std::string(field) + " must be non-empty valid UTF-8");
    }
}

template <typename Entry>
void sort_and_reject_duplicate_names(std::vector<Entry> &entries, const char *field) {
    std::sort(entries.begin(), entries.end(), [](const Entry &left, const Entry &right) {
        return utf8_less(left.name, right.name);
    });
    for (std::size_t index = 1; index < entries.size(); ++index) {
        if (entries[index - 1U].name == entries[index].name) {
            throw std::invalid_argument(std::string(field) + " contains a duplicate name");
        }
    }
}

bool is_finite_binary64(const std::uint64_t bits) noexcept {
    return (bits & 0x7ff0000000000000ULL) != 0x7ff0000000000000ULL;
}

bool is_valid_artifact_kind(const ArtifactKind kind) noexcept {
    return kind == ArtifactKind::terrain_source || kind == ArtifactKind::terrain_collision
        || kind == ArtifactKind::terrain_render || kind == ArtifactKind::navigation_support;
}

void append_coord(CanonicalWriter &writer, const CellCoord &coord) {
    writer.append_i32(coord.x);
    writer.append_i32(coord.y);
    writer.append_i32(coord.z);
}

CanonicalIdentity finish_identity(CanonicalWriter &writer) {
    CanonicalIdentity result;
    result.bytes = writer.finish();
    result.digest = sha256(result.bytes);
    return result;
}

} // namespace

std::string CanonicalIdentity::digest_hex() const {
    return sha256_hex(digest);
}

NamedConstant signed_int32_constant(std::string name, const std::int32_t value) {
    return {std::move(name), ConstantEncoding::signed_int32, static_cast<std::uint32_t>(value)};
}

NamedConstant binary64_constant(std::string name, const double value) {
    static_assert(std::numeric_limits<double>::is_iec559,
        "binary64 constant requires an IEC 559 / IEEE-754 double");
    if (!std::isfinite(value)) {
        throw std::invalid_argument("binary64 world constant must be finite");
    }
    std::uint64_t bits = 0;
    static_assert(sizeof(bits) == sizeof(value), "binary64 constant requires an IEEE-754-width double");
    std::memcpy(&bits, &value, sizeof(bits));
    return {std::move(name), ConstantEncoding::ieee754_binary64, bits};
}

std::uint32_t canonical_u32_length(const std::uint64_t size) {
    if (size > std::numeric_limits<std::uint32_t>::max()) {
        throw std::length_error("canonical field length exceeds uint32");
    }
    return static_cast<std::uint32_t>(size);
}

std::vector<NamedConstant> legacy_frozen_world_constants() {
    return {
        binary64_constant("CELL", 1.35),
        signed_int32_constant("SECTION_SIZE", 16),
        signed_int32_constant("CHUNK_SIZE", 28),
        binary64_constant("MIN_HEIGHT", 4.0),
        binary64_constant("MAX_HEIGHT", 120.0),
        binary64_constant("WATER_LEVEL", 11.1),
        signed_int32_constant("TOWN_REGION_CELLS", 280),
        signed_int32_constant("WORLD_BOTTOM_CELL_Y", -64),
    };
}

SourceIdentity legacy_frozen_source_identity(std::vector<std::uint32_t> seed_code_points) {
    return {
        std::move(seed_code_points),
        "legacy-preservation-tree/cfcc96f2ebcb6a4c171cd37aca52fff6b65a6d8e",
        2,
        {
            {"building.interior_program", 2},
            {"building.navigation_manifest", 9},
            {"building.terrain_profile", 1},
            {"citadel.generation_policy", 1},
            {"citadel.site_field", 1},
            {"citadel.survey_policy", 1},
            {"courtyard.placement", 1},
            {"furnishing.navigation_manifest", 2},
            {"landmark.recipe", 1},
            {"town.runtime_manifest", 1},
            {"tree.bushy_oak", 21},
            {"tree.conifer", 2},
            {"tree.procedural_grammar", 2},
            {"tree.savanna", 2},
            {"tree.spawn", 10},
        },
        2,
        1,
        legacy_frozen_world_constants(),
    };
}

CanonicalIdentity canonical_source_identity(const SourceIdentity &identity) {
    const std::uint32_t seed_size = canonical_u32_length(identity.seed_code_points.size());
    for (const std::uint32_t code_point : identity.seed_code_points) {
        if (!is_unicode_scalar(code_point)) {
            throw std::invalid_argument("source identity contains an invalid Unicode scalar value");
        }
    }
    const std::uint32_t recipe_size = canonical_u32_length(identity.recipe_revisions.size());

    require_valid_name(identity.world_generator_binding, "world generator binding");
    std::vector<NamedRevision> recipes = identity.recipe_revisions;
    for (const NamedRevision &recipe : recipes) {
        require_valid_name(recipe.name, "recipe revision name");
    }
    sort_and_reject_duplicate_names(recipes, "recipe revision map");

    std::vector<NamedConstant> constants = identity.world_constants;
    const std::uint32_t constant_size = canonical_u32_length(constants.size());
    for (const NamedConstant &constant : constants) {
        require_valid_name(constant.name, "world constant name");
        if (constant.encoding == ConstantEncoding::signed_int32) {
            if (constant.bits > std::numeric_limits<std::uint32_t>::max()) {
                throw std::invalid_argument("signed-int32 world constant contains out-of-width bits");
            }
        } else if (constant.encoding == ConstantEncoding::ieee754_binary64) {
            if (!is_finite_binary64(constant.bits)) {
                throw std::invalid_argument("binary64 world constant must be finite");
            }
        } else {
            throw std::invalid_argument("world constant has an unknown encoding");
        }
    }
    sort_and_reject_duplicate_names(constants, "world constant map");

    const auto required_constants = legacy_frozen_world_constants();
    for (const NamedConstant &required : required_constants) {
        const auto found = std::find_if(constants.begin(), constants.end(), [&](const NamedConstant &candidate) {
            return candidate.name == required.name;
        });
        if (found == constants.end()) {
            throw std::invalid_argument("source identity is missing frozen world constant: " + required.name);
        }
    }

    CanonicalWriter writer;
    writer.append_magic("VWBK");
    writer.append_u32(SourceIdentity::SCHEMA);
    writer.append_u32(seed_size);
    for (const std::uint32_t code_point : identity.seed_code_points) {
        writer.append_u32(code_point);
    }
    writer.append_u32(legacy_seed_hash(identity.seed_code_points));
    writer.append_bytes(reinterpret_cast<const std::uint8_t *>(identity.world_generator_binding.data()), identity.world_generator_binding.size());
    writer.append_u32(identity.biome_field_revision);
    writer.append_u32(recipe_size);
    for (const NamedRevision &recipe : recipes) {
        writer.append_bytes(reinterpret_cast<const std::uint8_t *>(recipe.name.data()), recipe.name.size());
        writer.append_u32(recipe.revision);
    }
    writer.append_u32(identity.save_envelope_revision);
    writer.append_u32(identity.terrain_delta_schema_revision);
    writer.append_u32(constant_size);
    for (const NamedConstant &constant : constants) {
        writer.append_bytes(reinterpret_cast<const std::uint8_t *>(constant.name.data()), constant.name.size());
        writer.append_u8(static_cast<std::uint8_t>(constant.encoding));
        if (constant.encoding == ConstantEncoding::signed_int32) {
            writer.append_u32(static_cast<std::uint32_t>(constant.bits));
        } else {
            writer.append_u64(constant.bits);
        }
    }
    return finish_identity(writer);
}

CanonicalIdentity canonical_artifact_identity(const ArtifactIdentity &identity) {
    if (!is_valid_artifact_kind(identity.kind)) {
        throw std::invalid_argument("artifact identity has an unknown kind");
    }
    if (identity.builder_revision == 0) {
        throw std::invalid_argument("artifact builder revision must be non-zero");
    }
    require_valid_name(identity.channel_policy, "artifact channel policy");
    require_valid_name(identity.seam_policy, "artifact seam policy");
    require_valid_name(identity.halo_policy, "artifact halo policy");

    CanonicalWriter writer;
    writer.append_magic("VWAR");
    writer.append_u32(ArtifactIdentity::SCHEMA);
    writer.append_bytes(identity.snapshot_digest.data(), identity.snapshot_digest.size());
    writer.append_u8(static_cast<std::uint8_t>(identity.kind));
    writer.append_u32(identity.builder_revision);
    writer.append_u32(identity.detail_level);
    writer.append_u32(identity.lod_level);
    writer.append_bytes(reinterpret_cast<const std::uint8_t *>(identity.channel_policy.data()), identity.channel_policy.size());
    writer.append_bytes(reinterpret_cast<const std::uint8_t *>(identity.seam_policy.data()), identity.seam_policy.size());
    writer.append_bytes(reinterpret_cast<const std::uint8_t *>(identity.halo_policy.data()), identity.halo_policy.size());
    return finish_identity(writer);
}

CanonicalIdentity canonical_snapshot_identity(const SnapshotIdentity &identity) {
    const CellCoord &minimum = identity.region.minimum;
    const CellCoord &maximum = identity.region.maximum_exclusive;
    if (minimum.x >= maximum.x || minimum.y >= maximum.y || minimum.z >= maximum.z) {
        throw std::invalid_argument("snapshot region must be non-empty and half-open");
    }
    const std::uint32_t terrain_revision_count = canonical_u32_length(identity.terrain_delta_revisions.size());
    const std::uint32_t feature_revision_count = canonical_u32_length(identity.feature_delta_revisions.size());

    CanonicalWriter writer;
    writer.append_magic("VWSN");
    writer.append_u32(SnapshotIdentity::SCHEMA);
    writer.append_bytes(identity.source_digest.data(), identity.source_digest.size());
    append_coord(writer, minimum);
    append_coord(writer, maximum);
    writer.append_u32(terrain_revision_count);
    for (const std::uint64_t revision : identity.terrain_delta_revisions) {
        writer.append_u64(revision);
    }
    writer.append_u32(feature_revision_count);
    for (const std::uint64_t revision : identity.feature_delta_revisions) {
        writer.append_u64(revision);
    }
    writer.append_u64(identity.owner_generation);
    return finish_identity(writer);
}

} // namespace voxel::world_backend
