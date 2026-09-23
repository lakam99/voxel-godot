#pragma once

#include "native_terrain_volume_v2_codec.hpp"

#include <cstddef>
#include <cstdint>
#include <deque>
#include <optional>
#include <stdexcept>
#include <string>
#include <vector>

namespace voxel::world_backend {

// Identity supplied by the save-envelope decoder before importing typed POD.
// This builder accepts only the current terrainVolume member representation.
struct NativeTerrainVolumeV2ImportIdentity final {
    std::string domain;
    std::uint32_t schema_version = 0;
    std::uint32_t section_size = 0;
    std::uint64_t revision = 0;
};

struct NativeTerrainVolumeV2ImportChunk final {
    CellCoord section;
    std::uint64_t section_revision = 0;
    std::vector<NativeTypedWorldStateRecord> records;
};

class NativeTerrainVolumeV2ImportBuilderRejected final : public std::invalid_argument {
public:
    NativeTerrainVolumeV2ImportBuilderRejected();
};

// Incremental, pure-core owner for already-decoded typed save data. Each
// append admits at most max_records_per_append records and copies only that
// bounded chunk. Call finalize() on a worker: final canonical snapshot
// validation is whole-volume work even though parsing/appending is incremental.
class NativeTerrainVolumeV2ImportBuilder final {
public:
    static constexpr std::size_t DEFAULT_MAX_RECORDS_PER_APPEND = 256U;
    static constexpr std::size_t MAX_RECORDS_PER_APPEND = 4096U;

    explicit NativeTerrainVolumeV2ImportBuilder(
        std::size_t max_records_per_append = DEFAULT_MAX_RECORDS_PER_APPEND,
        std::size_t max_total_records = NativeTerrainVolumeV2Limits::DEFAULT_MAX_RECORDS);

    void begin(const NativeTerrainVolumeV2ImportIdentity &identity);
    void append(const std::vector<NativeTerrainVolumeV2ImportChunk> &chunks);
    // Marks an active import abandoned without bulk destruction. Rejected or
    // abandoned inputs must be released through bounded dispose_step calls.
    bool abandon() noexcept;
    // Destroys no more than min(max_items, MAX_RECORDS_PER_APPEND) retained
    // records/section rows. Only terminal, non-finalized builders can drain.
    std::size_t dispose_step(std::size_t max_items) noexcept;
    bool disposal_complete() const noexcept;
    // Owners must keep this builder alive until disposal_complete(); destroying
    // it earlier performs unbounded teardown-only cleanup.
    NativeTerrainVolumeV2 finalize();

    std::size_t record_count() const noexcept;
    std::size_t section_count() const noexcept;
    bool active() const noexcept;

private:
    enum class State : std::uint8_t { empty, importing, abandoned, finalized, rejected };

    std::size_t max_records_per_append_;
    std::size_t max_total_records_;
    State state_ = State::empty;
    std::uint64_t revision_ = 0;
    std::deque<NativeTypedWorldStateRecord> records_;
    std::deque<NativeTerrainVolumeV2SectionRevision> sections_;
    std::optional<CellCoord> last_cell_;
    std::optional<CellCoord> last_section_;
};

} // namespace voxel::world_backend
