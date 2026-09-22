#include "native_wildlife_presentation_receipt.hpp"
namespace voxel::world_backend {
namespace {

bool zero(const Sha256Digest &digest) {
    for (const std::uint8_t byte : digest) {
        if (byte != 0U) return false;
    }
    return true;
}

bool canonical_ids_match(const NativeWildlifePresentationReceipt &receipt) {
    switch (receipt.variant) {
    case NativeWildlifeVariant::boar:
        return receipt.asset_id == "boar_idle_walk" && receipt.animation_clip_id == "boar_idle_walk";
    case NativeWildlifeVariant::deer:
        return receipt.asset_id == "deer_idle_walk" && receipt.animation_clip_id == "deer_idle_walk";
    case NativeWildlifeVariant::hare:
        return receipt.asset_id == "hare_idle_walk" && receipt.animation_clip_id == "hare_idle_walk";
    }
    return false;
}

bool valid_path(const NativeWildlifePresentationPath path) {
    return path == NativeWildlifePresentationPath::procedural_fallback
        || path == NativeWildlifePresentationPath::animated_playable;
}

} // namespace

NativeWildlifePresentationReceiptRejected::NativeWildlifePresentationReceiptRejected()
    : std::invalid_argument("invalid native wildlife presentation receipt") {}

NativeWildlifePresentationReceipt NativeWildlifePresentationReceiptValidator::admit(
    NativeWildlifePresentationReceipt receipt) {
    if (receipt.schema_revision == 0U) throw NativeWildlifePresentationReceiptRejected();
    if (zero(receipt.asset_catalog_digest)) throw NativeWildlifePresentationReceiptRejected();
    if (!canonical_ids_match(receipt)) throw NativeWildlifePresentationReceiptRejected();
    if (!valid_path(receipt.path)) throw NativeWildlifePresentationReceiptRejected();
    return receipt;
}
} // namespace voxel::world_backend
