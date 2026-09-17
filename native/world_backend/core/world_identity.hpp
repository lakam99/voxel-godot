#pragma once

#include "coordinates.hpp"
#include "sha256.hpp"

#include <cstdint>
#include <string>
#include <vector>

namespace voxel::world_backend {

struct NamedRevision {
    std::string name;
    std::uint32_t revision = 0;
};

enum class ConstantEncoding : std::uint8_t {
    signed_int32 = 1,
    ieee754_binary64 = 2,
};

struct NamedConstant {
    std::string name;
    ConstantEncoding encoding = ConstantEncoding::signed_int32;
    std::uint64_t bits = 0;
};

struct SourceIdentity {
    static constexpr std::uint32_t SCHEMA = 1;

    std::vector<std::uint32_t> seed_code_points;
    std::string world_generator_binding;
    std::uint32_t biome_field_revision = 0;
    std::vector<NamedRevision> recipe_revisions;
    std::uint32_t save_envelope_revision = 0;
    std::uint32_t terrain_delta_schema_revision = 0;
    std::vector<NamedConstant> world_constants;
};

struct CanonicalIdentity {
    std::vector<std::uint8_t> bytes;
    Sha256Digest digest{};

    std::string digest_hex() const;
};

struct CellRegion {
    CellCoord minimum;
    CellCoord maximum_exclusive;
};

struct SnapshotIdentity {
    static constexpr std::uint32_t SCHEMA = 1;

    Sha256Digest source_digest{};
    CellRegion region;
    std::vector<std::uint64_t> terrain_delta_revisions;
    std::vector<std::uint64_t> feature_delta_revisions;
    std::uint64_t owner_generation = 0;
};

enum class ArtifactKind : std::uint8_t {
    terrain_source = 1,
    terrain_collision = 2,
    terrain_render = 3,
    navigation_support = 4,
};

struct ArtifactIdentity {
    static constexpr std::uint32_t SCHEMA = 1;

    Sha256Digest snapshot_digest{};
    ArtifactKind kind = ArtifactKind::terrain_source;
    std::uint32_t builder_revision = 0;
    std::uint32_t detail_level = 0;
    std::uint32_t lod_level = 0;
    std::string channel_policy;
    std::string seam_policy;
    std::string halo_policy;
};

NamedConstant signed_int32_constant(std::string name, std::int32_t value);
NamedConstant binary64_constant(std::string name, double value);
std::uint32_t canonical_u32_length(std::uint64_t size);
std::vector<NamedConstant> legacy_frozen_world_constants();
SourceIdentity legacy_frozen_source_identity(std::vector<std::uint32_t> seed_code_points);
CanonicalIdentity canonical_source_identity(const SourceIdentity &identity);
CanonicalIdentity canonical_snapshot_identity(const SnapshotIdentity &identity);
CanonicalIdentity canonical_artifact_identity(const ArtifactIdentity &identity);

} // namespace voxel::world_backend
