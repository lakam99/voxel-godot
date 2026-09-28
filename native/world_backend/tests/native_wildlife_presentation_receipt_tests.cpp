#include "test_harness.hpp"
#include "../core/native_wildlife_presentation_receipt.hpp"

using namespace voxel::world_backend;

namespace {

NativeWildlifePresentationReceipt receipt(const NativeWildlifeVariant variant,
    const NativeWildlifePresentationPath path) {
    NativeWildlifePresentationReceipt result;
    result.schema_revision = 1U;
    result.asset_catalog_digest.fill(1U);
    result.variant = variant;
    result.path = path;
    switch (variant) {
    case NativeWildlifeVariant::boar:
        result.asset_id = "boar_idle_walk";
        result.animation_clip_id = "boar_idle_walk";
        break;
    case NativeWildlifeVariant::deer:
        result.asset_id = "deer_idle_walk";
        result.animation_clip_id = "deer_idle_walk";
        break;
    case NativeWildlifeVariant::hare:
        result.asset_id = "hare_idle_walk";
        result.animation_clip_id = "hare_idle_walk";
        break;
    }
    return result;
}

} // namespace

VWB_TEST(native_wildlife_presentation_receipt_admits_only_explicit_complete_capabilities) {
    for (const NativeWildlifeVariant variant : {
             NativeWildlifeVariant::boar, NativeWildlifeVariant::deer, NativeWildlifeVariant::hare,
         }) {
        for (const NativeWildlifePresentationPath path : {
                 NativeWildlifePresentationPath::procedural_fallback,
                 NativeWildlifePresentationPath::animated_playable,
             }) {
            const NativeWildlifePresentationReceipt admitted =
                NativeWildlifePresentationReceiptValidator::admit(receipt(variant, path));
            VWB_EXPECT_EQ(variant, admitted.variant);
            VWB_EXPECT_EQ(path, admitted.path);
        }
    }
}

VWB_TEST(native_wildlife_presentation_receipt_rejects_missing_partial_or_unknown_capability) {
    NativeWildlifePresentationReceipt malformed = receipt(
        NativeWildlifeVariant::boar, NativeWildlifePresentationPath::animated_playable);
    malformed.schema_revision = 0U;
    VWB_EXPECT_THROW(NativeWildlifePresentationReceiptRejected,
        NativeWildlifePresentationReceiptValidator::admit(malformed));
    malformed = receipt(NativeWildlifeVariant::boar, NativeWildlifePresentationPath::animated_playable);
    malformed.asset_catalog_digest = {};
    VWB_EXPECT_THROW(NativeWildlifePresentationReceiptRejected,
        NativeWildlifePresentationReceiptValidator::admit(malformed));
    malformed = receipt(NativeWildlifeVariant::boar, NativeWildlifePresentationPath::animated_playable);
    malformed.asset_id = "deer_idle_walk";
    VWB_EXPECT_THROW(NativeWildlifePresentationReceiptRejected,
        NativeWildlifePresentationReceiptValidator::admit(malformed));
    malformed = receipt(NativeWildlifeVariant::boar, NativeWildlifePresentationPath::animated_playable);
    malformed.animation_clip_id.clear();
    VWB_EXPECT_THROW(NativeWildlifePresentationReceiptRejected,
        NativeWildlifePresentationReceiptValidator::admit(malformed));
    malformed = receipt(NativeWildlifeVariant::deer, NativeWildlifePresentationPath::animated_playable);
    malformed.asset_id = "hare_idle_walk";
    VWB_EXPECT_THROW(NativeWildlifePresentationReceiptRejected,
        NativeWildlifePresentationReceiptValidator::admit(malformed));
    malformed = receipt(NativeWildlifeVariant::deer, NativeWildlifePresentationPath::animated_playable);
    malformed.animation_clip_id.clear();
    VWB_EXPECT_THROW(NativeWildlifePresentationReceiptRejected,
        NativeWildlifePresentationReceiptValidator::admit(malformed));
    malformed = receipt(NativeWildlifeVariant::hare, NativeWildlifePresentationPath::animated_playable);
    malformed.asset_id = "boar_idle_walk";
    VWB_EXPECT_THROW(NativeWildlifePresentationReceiptRejected,
        NativeWildlifePresentationReceiptValidator::admit(malformed));
    malformed = receipt(NativeWildlifeVariant::hare, NativeWildlifePresentationPath::animated_playable);
    malformed.animation_clip_id.clear();
    VWB_EXPECT_THROW(NativeWildlifePresentationReceiptRejected,
        NativeWildlifePresentationReceiptValidator::admit(malformed));
    malformed = receipt(NativeWildlifeVariant::boar, NativeWildlifePresentationPath::animated_playable);
    malformed.variant = static_cast<NativeWildlifeVariant>(99);
    VWB_EXPECT_THROW(NativeWildlifePresentationReceiptRejected,
        NativeWildlifePresentationReceiptValidator::admit(malformed));
    malformed = receipt(NativeWildlifeVariant::boar, NativeWildlifePresentationPath::animated_playable);
    malformed.path = static_cast<NativeWildlifePresentationPath>(99);
    VWB_EXPECT_THROW(NativeWildlifePresentationReceiptRejected,
        NativeWildlifePresentationReceiptValidator::admit(malformed));
}
