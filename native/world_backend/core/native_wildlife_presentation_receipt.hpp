#pragma once
#include "sha256.hpp"
#include <cstdint>
#include <string>
#include <stdexcept>
namespace voxel::world_backend {
// This is the source-selected profile variant, not an inference from a visual
// node.  The native feature definition will carry its physical profile later;
// this receipt only establishes which presentation capability consumed the
// shared legacy PCG operations.
enum class NativeWildlifeVariant : std::uint8_t {
    boar = 1,
    deer = 2,
    hare = 3,
};

// The legacy source can instantiate a visual without an AnimationPlayer.
// That accidental one-draw path is intentionally not representable here.  A
// source adapter must make an explicit procedural fallback decision, or prove
// that the selected canonical asset has a playable canonical clip.
enum class NativeWildlifePresentationPath : std::uint8_t {
    procedural_fallback = 1,
    animated_playable = 2,
};

struct NativeWildlifePresentationReceipt final {
    std::uint32_t schema_revision = 0U;
    Sha256Digest asset_catalog_digest{};
    NativeWildlifeVariant variant = NativeWildlifeVariant::boar;
    std::string asset_id;
    std::string animation_clip_id;
    NativeWildlifePresentationPath path = NativeWildlifePresentationPath::procedural_fallback;
};
class NativeWildlifePresentationReceiptRejected final:public std::invalid_argument{public:NativeWildlifePresentationReceiptRejected();};
class NativeWildlifePresentationReceiptValidator final{public:static NativeWildlifePresentationReceipt admit(NativeWildlifePresentationReceipt receipt);};
} // namespace voxel::world_backend
