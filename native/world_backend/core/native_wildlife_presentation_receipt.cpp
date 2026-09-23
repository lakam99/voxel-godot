#include "native_wildlife_presentation_receipt.hpp"
#include <utility>
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

NativeWildlifePresentationCatalog::NativeWildlifePresentationCatalog(
    std::array<NativeWildlifePresentationReceipt, 3> receipts)
    : receipts_(std::move(receipts)) {}

NativeWildlifePresentationCatalog NativeWildlifePresentationCatalog::create(
    const std::array<NativeWildlifePresentationReceipt, 3> &receipts) {
    std::array<NativeWildlifePresentationReceipt, 3> admitted;
    for (std::size_t i = 0; i < admitted.size(); ++i) {
        admitted[i] = NativeWildlifePresentationReceiptValidator::admit(receipts[i]);
        if (static_cast<std::size_t>(admitted[i].variant) != i + 1U
            || admitted[i].schema_revision != admitted[0].schema_revision
            || admitted[i].asset_catalog_digest != admitted[0].asset_catalog_digest) {
            throw NativeWildlifePresentationReceiptRejected();
        }
    }
    return NativeWildlifePresentationCatalog(std::move(admitted));
}

NativeWildlifePresentationReceipt NativeWildlifePresentationCatalog::resolve(
    const NativeWildlifeVariant variant) const {
    const std::size_t index = static_cast<std::size_t>(variant);
    if (index < 1U || index > receipts_.size()) throw NativeWildlifePresentationReceiptRejected();
    return receipts_[index - 1U];
}
} // namespace voxel::world_backend
