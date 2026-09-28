#include "native_removed_props_v2_codec.hpp"

#include <algorithm>
#include <cstdint>
#include <string>
#include <utility>
#include <vector>

namespace voxel::world_backend {
namespace {

[[noreturn]] void reject() {
    throw NativeRemovedPropsV2Rejected();
}

bool utf8_byte_less(const std::string &left, const std::string &right) noexcept {
    return std::lexicographical_compare(left.begin(), left.end(), right.begin(), right.end(),
        [](const char left_byte, const char right_byte) noexcept {
            return static_cast<std::uint8_t>(static_cast<unsigned char>(left_byte))
                < static_cast<std::uint8_t>(static_cast<unsigned char>(right_byte));
        });
}

void validate_typed_prop_ids(const std::vector<std::string> &prop_ids) {
    if (prop_ids.size() > NativeFeatureDeltaLimits::MAX_TOMBSTONES) reject();
    std::vector<std::string> canonical_ids;
    canonical_ids.reserve(prop_ids.size());
    for (const std::string &prop_id : prop_ids) {
        if (prop_id.empty() || prop_id.size() > NativeFeatureDeltaLimits::MAX_ID_BYTES) reject();
        try {
            // NativeValue remains the native UTF-8 admission authority; the
            // typed save path only borrows it for text validation, not array
            // cardinality or Variant-shaped persistence.
            static_cast<void>(NativeValue::string(prop_id));
        } catch (const NativeValueRejected &) {
            reject();
        }
        canonical_ids.push_back(prop_id);
    }
    std::sort(canonical_ids.begin(), canonical_ids.end(), utf8_byte_less);
    for (std::size_t index = 1U; index < canonical_ids.size(); ++index) {
        if (canonical_ids[index - 1U] == canonical_ids[index]) reject();
    }
}

} // namespace

NativeRemovedPropsV2Rejected::NativeRemovedPropsV2Rejected()
    : std::invalid_argument("invalid native removedProps v2") {}

NativeFeatureDeltaSnapshot decode_native_removed_props_v2_ids(const std::vector<std::string> &prop_ids) {
    validate_typed_prop_ids(prop_ids);
    std::vector<NativeFeatureTombstone> tombstones;
    tombstones.reserve(prop_ids.size());
    for (const std::string &prop_id : prop_ids) {
        // Do not emulate MainSaveState.gd's historical String(Variant)
        // coercion. The explicit validator above and the snapshot's own
        // canonical admission prove the same strict ID grammar.
        tombstones.push_back({prop_id});
    }
    return NativeFeatureDeltaSnapshot::create(std::move(tombstones), {});
}

std::vector<std::string> encode_native_removed_props_v2_ids(const NativeFeatureDeltaSnapshot &snapshot) {
    // NativeFeatureDeltaSnapshot is an immutable admitted value. Preserve its
    // canonical tombstone order instead of adding a production-header friend
    // solely to manufacture an impossible corrupt state in tests.
    if (!snapshot.player_created_instances().empty()) reject();
    std::vector<std::string> entries;
    entries.reserve(snapshot.tombstones().size());
    for (const NativeFeatureTombstone &tombstone : snapshot.tombstones()) {
        entries.push_back(tombstone.feature_id);
    }
    return entries;
}

NativeFeatureDeltaSnapshot decode_native_removed_props_v2(const NativeValue &value) {
    try {
        if (value.kind() != NativeValueKind::array) reject();
        std::vector<std::string> prop_ids;
        prop_ids.reserve(value.as_array().size());
        for (const NativeValue &entry : value.as_array()) {
            if (entry.kind() != NativeValueKind::string) reject();
            prop_ids.push_back(entry.as_string());
        }
        return decode_native_removed_props_v2_ids(prop_ids);
    } catch (const NativeRemovedPropsV2Rejected &) {
        throw;
    } catch (const NativeValueRejected &) {
        reject();
    }
}

NativeValue encode_native_removed_props_v2(const NativeFeatureDeltaSnapshot &snapshot) {
    try {
        const std::vector<std::string> prop_ids = encode_native_removed_props_v2_ids(snapshot);
        NativeValue::Array entries;
        entries.reserve(prop_ids.size());
        for (const std::string &prop_id : prop_ids) entries.push_back(NativeValue::string(prop_id));
        return NativeValue::array(std::move(entries));
    } catch (const NativeRemovedPropsV2Rejected &) {
        throw;
    } catch (const NativeValueRejected &) {
        reject();
    }
}

} // namespace voxel::world_backend
