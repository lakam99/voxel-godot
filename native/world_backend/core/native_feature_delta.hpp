#pragma once

#include "coordinates.hpp"
#include "native_cell_state.hpp"
#include "native_value.hpp"

#include <cstddef>
#include <cstdint>
#include <stdexcept>
#include <string>
#include <vector>

namespace voxel::world_backend {

// NativeFeatureDelta is the deliberately small, Godot-free durable feature
// vocabulary required by v2 migration.  It owns neither terrain edits nor a
// live scene: a tombstone prevents a generated feature from being recreated,
// while an instance describes a player-created durable feature at one cell.
// Door state, inventories, navigation and Node3D lifetime are intentionally
// outside this value model.  Future domains belong in runtime_state, where
// their optional presence and exact nested value remain explicit.
struct NativeFeatureDeltaLimits final {
    static constexpr std::size_t MAX_ID_BYTES = 1024U;
    static constexpr std::size_t MAX_TOMBSTONES = 65536U;
    static constexpr std::size_t MAX_PLAYER_CREATED_INSTANCES = 65536U;
};

class NativeFeatureDeltaRejected final : public std::invalid_argument {
public:
    NativeFeatureDeltaRejected();
};

struct NativeFeatureTombstone final {
    std::string feature_id;

    bool operator==(const NativeFeatureTombstone &other) const noexcept;
};

struct NativePlayerCreatedInstance final {
    std::string instance_id;
    CellCoord cell;
    double world_y = 0.0;
    // The unit of facing is intentionally opaque to this persistence value.
    // The producer and consumer share it through the exact finite scalar;
    // native persistence must not reinterpret it as a cardinal direction.
    double facing = 0.0;
    // Required rather than optional: a created feature without a durable
    // identity cannot safely reappear as an arbitrary terrain material.
    NativeBlockIdentity block_id;
    // Every optional feature field is carried explicitly in this canonical
    // object.  There are no hidden/defaulted feature semantics in this model.
    NativeValue runtime_state = NativeValue::object({});

    bool operator==(const NativePlayerCreatedInstance &other) const noexcept;
};

// A canonical, immutable-at-the-API-boundary feature snapshot.  Tombstone
// feature IDs and player-instance IDs are separate v2 persistence-domain
// keys: equal text across those domains is valid. Admission validates and
// orders each domain independently before storing it; FD1's distinct record
// tags and separate counts keep the two domains unambiguous on the wire.
class NativeFeatureDeltaSnapshot final {
public:
    static NativeFeatureDeltaSnapshot create(
        std::vector<NativeFeatureTombstone> tombstones,
        std::vector<NativePlayerCreatedInstance> player_created_instances);

    const std::vector<NativeFeatureTombstone> &tombstones() const noexcept;
    // Lookup against the canonical unsigned-UTF-8 tombstone ordering.
    bool contains_tombstone(const std::string &feature_id) const noexcept;
    const std::vector<NativePlayerCreatedInstance> &player_created_instances() const noexcept;

    // FD1 contains big-endian fixed-width counts/coordinates, exact
    // IEEE-754 bits for finite scalars (with -0 canonicalized on admission),
    // unsigned-UTF-8 ordered IDs, and length-delimited NV1 runtime values.
    std::vector<std::uint8_t> canonical_binary() const;

    bool operator==(const NativeFeatureDeltaSnapshot &other) const noexcept;
    bool operator!=(const NativeFeatureDeltaSnapshot &other) const noexcept;

private:
    NativeFeatureDeltaSnapshot(
        std::vector<NativeFeatureTombstone> tombstones,
        std::vector<NativePlayerCreatedInstance> player_created_instances);

    std::vector<NativeFeatureTombstone> tombstones_;
    std::vector<NativePlayerCreatedInstance> player_created_instances_;
};

} // namespace voxel::world_backend
