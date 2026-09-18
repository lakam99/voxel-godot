#pragma once

#include "native_cell_state.hpp"

#include <cstdint>
#include <optional>
#include <vector>

namespace voxel::world_backend {

enum class NativeTypedWorldStatePersistence : std::uint8_t {
    durable = 1,
    transient = 2,
};

// This is the typed, parser-free boundary for the terrain portion of a v2
// save.  It intentionally cannot represent a generated base cell: a durable
// snapshot is a collection of player/world deltas, not a second generator.
//
// A future v2 importer must explicitly classify raw `saveDelta=false` and
// scene-block metadata before it constructs this record.  It must not infer a
// policy from metadata strings or silently fall back to durable authority.
struct NativeTypedWorldStateRecord {
    NativeCellStateNamespace name_space = NativeCellStateNamespace::durable_terrain;
    NativeTypedWorldStatePersistence persistence = NativeTypedWorldStatePersistence::durable;
    NativeCellState state;

    bool operator==(const NativeTypedWorldStateRecord &other) const noexcept;
};

// `records` always contains only durable-terrain, explicitly durable records
// in v2 z/y/x order. Scene overlays stay in the runtime store and have no
// field here by design.
class NativeTypedWorldStateSnapshot final {
public:
    static NativeTypedWorldStateSnapshot create(std::vector<NativeTypedWorldStateRecord> records);

    const std::vector<NativeTypedWorldStateRecord> &records() const noexcept;

    bool operator==(const NativeTypedWorldStateSnapshot &other) const noexcept;

private:
    explicit NativeTypedWorldStateSnapshot(std::vector<NativeTypedWorldStateRecord> records);

    std::vector<NativeTypedWorldStateRecord> records_;
};

// A small mutable owner is deliberately separate from WorldDeltaStore.  This
// lets a future v2 parser validate and admit one full typed save atomically,
// while the delta-store migration remains free to choose its transaction API.
class NativeTypedWorldStateStore final {
public:
    NativeTypedWorldStateSnapshot durable_snapshot() const;
    std::vector<NativeTypedWorldStateRecord> transient_overlays() const;

    std::optional<NativeCellState> durable_value_at(const CellCoord &cell) const;
    std::optional<NativeCellState> transient_overlay_at(const CellCoord &cell) const;

    // Strong exception guarantee: rejected or malformed snapshots leave both
    // the previously admitted durable snapshot and all transient overlays
    // unchanged.
    void admit_durable_snapshot(const NativeTypedWorldStateSnapshot &snapshot);
    // The typed parser seam.  It provides the same strong guarantee while
    // accepting a not-yet-canonical batch directly from a future v2 decoder.
    void admit_durable_records(std::vector<NativeTypedWorldStateRecord> records);

    // Overlays are runtime-only.  This endpoint validates their namespace and
    // canonical ordering but never lets them appear in durable_snapshot().
    void replace_transient_overlays(std::vector<NativeTypedWorldStateRecord> overlays);

private:
    std::vector<NativeTypedWorldStateRecord> durable_records_;
    std::vector<NativeTypedWorldStateRecord> transient_overlays_;
};

} // namespace voxel::world_backend
