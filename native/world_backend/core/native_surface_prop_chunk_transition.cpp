#include "native_surface_prop_chunk_transition.hpp"

#include <algorithm>
#include <set>

namespace voxel::world_backend {
namespace {
void add_ids(std::set<std::string> &ids, const NativeSurfaceFeatureEntry &entry) {
    ids.insert(entry.placement.durable_id);
    if (entry.ore) for (const auto &child : entry.ore->children()) ids.insert(child.durable_id);
}

Sha256Digest typed_digest(const NativeSurfaceFeatureEntry &entry) {
    std::vector<std::uint8_t> bytes;
    const auto append = [&bytes](const Sha256Digest &digest) {
        bytes.insert(bytes.end(), digest.begin(), digest.end());
    };
    append(entry.rock ? entry.rock->definition().content_digest() : Sha256Digest{});
    append(entry.ore ? entry.ore->content_digest() : Sha256Digest{});
    append(entry.forage ? entry.forage->content_digest() : Sha256Digest{});
    append(entry.wildlife ? entry.wildlife->content_digest() : Sha256Digest{});
    append(entry.tree ? entry.tree->content_digest() : Sha256Digest{});
    append(entry.tree_presence ? entry.tree_presence->content_digest : Sha256Digest{});
    return sha256(bytes);
}
} // namespace

NativeSurfacePropChunkTransition NativeSurfacePropChunkTransition::create(
    const NativeSurfacePropSourceOrderedStream &before,
    const NativeSurfacePropSourceOrderedStream &after,
    const NativeEffectiveTerrainSource &terrain,
    const NativeBiomeEnvironmentCatalog &catalog,
    const NativeSurfaceRockAssetCatalog &rock_assets,
    const NativeStructureExclusionSnapshot &exclusions,
    const NativeWildlifePresentationCatalog &wildlife,
    const NativeTreeExclusionHaloCapture *before_halo,
    const NativeTreeExclusionHaloCapture *after_halo) {
    const auto old_placements = NativeSurfacePropOrderedPlacement::create(before, terrain);
    const auto new_placements = NativeSurfacePropOrderedPlacement::create(after, terrain);
    NativeSurfacePropChunkTransition result;
    result.difference_ = NativeSurfacePropChunkDifference::create(before, old_placements,
        after, new_placements, terrain);
    result.before_manifest_ = NativeSurfaceFeatureManifest::create(before, old_placements,
        terrain, catalog, rock_assets, exclusions, wildlife, before_halo);
    result.after_manifest_ = NativeSurfaceFeatureManifest::create(after, new_placements,
        terrain, catalog, rock_assets, exclusions, wildlife, after_halo);
    std::set<std::string> ids;
    for (std::uint32_t i = 0; i < NativeSurfacePropAttemptStream::ATTEMPT_COUNT; ++i) {
        const auto &old_entry = result.before_manifest_.entries()[i];
        const auto &new_entry = result.after_manifest_.entries()[i];
        const bool ordered_changed = std::any_of(result.difference_.changed_ordinals().begin(),
            result.difference_.changed_ordinals().end(), [i](const auto &d) { return d.ordinal == i; });
        if (!ordered_changed && typed_digest(old_entry) == typed_digest(new_entry)) continue;
        result.changed_ordinals_.push_back(i);
        add_ids(ids, old_entry); add_ids(ids, new_entry);
    }
    result.changed_ids_.assign(ids.begin(), ids.end());
    std::vector<std::uint8_t> receipt;
    for (const auto &digest : {result.difference_.content_digest(),
        result.before_manifest_.content_digest(), result.after_manifest_.content_digest()})
        receipt.insert(receipt.end(), digest.begin(), digest.end());
    result.content_digest_ = sha256(receipt);
    return result;
}

} // namespace voxel::world_backend
