#pragma once

#include "native_feature_delta.hpp"
#include "native_value.hpp"

#include <stdexcept>
#include <string>
#include <vector>

namespace voxel::world_backend {

class NativeRemovedPropsV2Rejected final : public std::invalid_argument {
public:
    NativeRemovedPropsV2Rejected();
};

// Pure structural adapter for v2's top-level `removedProps` member.  The
// current game writer emits removed_props.keys(), whose semantic result is a
// set of nonempty generated-prop IDs.  This migration boundary deliberately
// accepts only that canonical form: an array of unique, valid UTF-8 strings.
//
// Older live restoration happens to coerce arbitrary Variant array items with
// String() and treats a non-array as an empty set.  That permissive behavior
// is not a stable persistence grammar and is intentionally not reproduced in
// the native authority.  Such inputs are rejected rather than being assigned
// a C++ imitation of Godot Variant stringification.
//
// This typed boundary is production-capable for the full feature-delta record
// limit (65,536 IDs), independent of NativeValue's deliberately smaller
// generic container limit. Decode preserves arbitrary source ordering
// semantically by admitting tombstones into NativeFeatureDeltaSnapshot, which
// canonicalizes its own tombstone set in unsigned UTF-8 byte order. The vector
// encoder emits that deterministic order.
NativeFeatureDeltaSnapshot decode_native_removed_props_v2_ids(const std::vector<std::string> &prop_ids);
std::vector<std::string> encode_native_removed_props_v2_ids(const NativeFeatureDeltaSnapshot &snapshot);

// NativeValue is retained only as a bounded convenience representation for
// callers which already have a small decoded value. These overloads delegate
// all ID semantics to the typed functions above. They necessarily reject
// arrays larger than NativeValueLimits::MAX_CONTAINER_ENTRIES; production
// v2 save import/export must use the typed ID representation instead.
// Player-created instances are a different v2 top-level `blocks` domain and
// are rejected here; this adapter never admits anything to WDS, whose
// footprint contract remains independent.
NativeFeatureDeltaSnapshot decode_native_removed_props_v2(const NativeValue &value);
NativeValue encode_native_removed_props_v2(const NativeFeatureDeltaSnapshot &snapshot);

} // namespace voxel::world_backend
