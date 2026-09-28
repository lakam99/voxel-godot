#pragma once

#include "native_biome_environment_catalog.hpp"
#include "world_source.hpp"

#include <cstdint>
#include <cstddef>
#include <map>
#include <stdexcept>
#include <string>
#include <vector>

namespace voxel::world_backend {

// One row from VisualAssetRegistry's generated manifest. Admission applies
// runtimeEnabled exactly as load_manifest does; disabled test assets are an
// adapter instantiation state and do not belong in this selection snapshot.
struct NativeSurfaceRockAssetRecord final {
    std::string id;
    std::string family;
    std::vector<std::string> biome_tags;
    std::string path;
    double size_x = 1.0;
    double size_y = 1.0;
    double size_z = 1.0;
    bool runtime_enabled = true;
};

// One effective assets_by_family entry. Membership is independent of the
// last-write-wins asset value: old-family IDs and duplicates remain selectable.
struct NativeSurfaceRockFamilyMembers final {
    std::string family;
    std::vector<std::string> ordered_ids;
};

struct NativeSurfaceRockAssetSelection final {
    std::uint32_t schema_revision = 0U;
    Sha256Digest asset_catalog_digest{};
    Sha256Digest environment_catalog_digest{};
    Sha256Digest environment_profile_digest{};
    std::string requested_biome;
    std::string resolved_profile_biome;
    std::string durable_prop_id;
    std::string asset_id;
    std::string asset_path;
    WorldFloat32Position asset_size{1.0F, 1.0F, 1.0F};
    double rock_scale = 1.0;
    std::uint32_t candidate_count = 0U;
    bool matched_biome_tag = false;
};

class NativeSurfaceRockAssetCatalogRejected final : public std::invalid_argument {
public:
    NativeSurfaceRockAssetCatalogRejected();
};

// Immutable copy of the effective VisualAssetRegistry selection inputs. A
// missing selected scene still falls back at Godot publication, after this
// deterministic ID has been selected.
class NativeSurfaceRockAssetCatalog final {
public:
    static constexpr std::uint32_t SCHEMA_REVISION = 1U;
    static NativeSurfaceRockAssetCatalog create(std::vector<NativeSurfaceRockAssetRecord> manifest_rows,
        NativeBiomeEnvironmentCatalog environment);
    static NativeSurfaceRockAssetCatalog create_effective(
        std::vector<NativeSurfaceRockAssetRecord> assets_by_id,
        std::vector<NativeSurfaceRockFamilyMembers> families,
        NativeBiomeEnvironmentCatalog environment);

    NativeSurfaceRockAssetSelection select(const std::string &biome,
        const std::string &durable_prop_id) const;
    const Sha256Digest &content_digest() const noexcept;
    const Sha256Digest &environment_digest() const noexcept;
    const std::vector<std::uint8_t> &canonical_binary() const noexcept;

private:
    NativeSurfaceRockAssetCatalog(std::vector<NativeSurfaceRockAssetRecord> rows,
        std::map<std::string, std::size_t> last_by_id,
        std::map<std::string, std::vector<std::string>> family_members,
        NativeBiomeEnvironmentCatalog environment, std::vector<std::uint8_t> canonical,
        Sha256Digest digest) noexcept;
    std::vector<NativeSurfaceRockAssetRecord> rows_;
    std::map<std::string, std::size_t> last_by_id_;
    std::map<std::string, std::vector<std::string>> family_members_;
    NativeBiomeEnvironmentCatalog environment_;
    std::vector<std::uint8_t> canonical_binary_;
    Sha256Digest content_digest_{};
};

std::uint32_t native_surface_rock_stable_hash(const std::string &utf8);

} // namespace voxel::world_backend
