#pragma once
#include "world_source.hpp"

#include <cstddef>
#include <cstdint>
#include <map>
#include <vector>

namespace voxel::world_backend {

// Pure scheduling/receipt owner. The caller owns source admission, encoding,
// engine insertion, and mesh/physics proof; none may be inferred here.
class NativeVoxelBlockDemand {
public:
    struct Key {
        std::uint64_t epoch = 0;
        int x = 0, y = 0, z = 0, lod = 0;
        bool operator<(const Key &other) const;
    };
    enum class State { waiting_source, queued, encoding, prepared, inserted_waiting_mesh, published, failed_empty, failed_oversize, retired };
    struct Ticket { Key key; std::uint64_t generation = 0; std::uint64_t revision = 0; WorldPhysicalContentIdentity pin; };
    struct Entry {
        State state = State::waiting_source;
        std::uint64_t revision = 0, generation = 0;
        WorldPhysicalContentIdentity pin;
        int priority = 0;
        std::uint64_t queued_at = 0;
        std::map<std::uint64_t, int> consumers;
        std::vector<std::uint8_t> bytes;
        unsigned insertion_rejections = 0;
    };

    NativeVoxelBlockDemand(std::size_t max_in_flight, std::size_t max_prepared_bytes, std::size_t max_entries,
                           std::size_t max_block_bytes);
    // False means admission is at capacity; caller must retain/retry that demand.
    bool request(Key key, std::uint64_t consumer, int priority, std::uint64_t revision, WorldPhysicalContentIdentity pin);
    void source_ready(const Key &key, std::uint64_t revision, const WorldPhysicalContentIdentity &pin);
    void invalidate(const Key &key, std::uint64_t revision, WorldPhysicalContentIdentity pin);
    void release(const Key &key, std::uint64_t consumer);
    void reset_epoch(std::uint64_t epoch);
    std::vector<Ticket> dispatch(std::size_t max_jobs = 1);
    // Capture or source admission could not supply an immutable job. Call only
    // after the physical worker/capture has stopped; retain consumer demand
    // and require a fresh source_ready before dispatching again.
    bool defer(const Ticket &ticket);
    bool complete(const Ticket &ticket, std::vector<std::uint8_t> bytes);
    // The engine adapter must recheck current native pin/epoch and viewer
    // pairing on Main before try_set_block_data; accepted alone is not proof
    // of mesh or physics publication.
    bool insertion_result(const Ticket &ticket, bool accepted);
    bool receipt(const Ticket &ticket, bool mesh_ready, bool physics_ready, bool physics_required = true);
    void mesh_exited(const Key &key);
    void unloaded(const Key &key);
    std::size_t retire(std::size_t max_entries);
    const Entry *find(const Key &key) const;
    std::size_t in_flight() const { return in_flight_; }
    std::size_t prepared_bytes() const { return prepared_bytes_; }
    std::size_t size() const { return entries_.size(); }

private:
    std::map<Key, Entry> entries_;
    std::map<Key, std::map<std::uint64_t, Ticket>> active_jobs_;
    std::uint64_t epoch_ = 0, clock_ = 0;
    std::size_t max_in_flight_, max_prepared_bytes_, max_entries_, max_block_bytes_;
    std::size_t in_flight_ = 0, prepared_bytes_ = 0;
    static bool same(const Entry &entry, const Ticket &ticket);
    void clear_bytes(Entry &entry);
    void supersede(Entry &entry, std::uint64_t revision, WorldPhysicalContentIdentity pin);
};

} // namespace voxel::world_backend
