#include "native_voxel_block_demand.hpp"

#include <algorithm>
#include <stdexcept>
#include <tuple>

namespace voxel::world_backend {

bool NativeVoxelBlockDemand::Key::operator<(const Key &other) const {
    return std::tie(epoch, x, y, z, lod) < std::tie(other.epoch, other.x, other.y, other.z, other.lod);
}

NativeVoxelBlockDemand::NativeVoxelBlockDemand(std::size_t max_in_flight, std::size_t max_prepared_bytes,
                                               std::size_t max_entries, std::size_t max_block_bytes)
    : max_in_flight_(max_in_flight), max_prepared_bytes_(max_prepared_bytes), max_entries_(max_entries),
      max_block_bytes_(max_block_bytes) {
    if (max_in_flight == 0 || max_entries == 0 || max_block_bytes == 0 || max_block_bytes > max_prepared_bytes)
        throw std::invalid_argument("invalid voxel block demand capacity");
}

void NativeVoxelBlockDemand::clear_bytes(Entry &entry) {
    prepared_bytes_ -= entry.bytes.size();
    entry.bytes.clear();
}

void NativeVoxelBlockDemand::supersede(Entry &entry, std::uint64_t revision, WorldPhysicalContentIdentity pin) {
    clear_bytes(entry);
    entry.revision = revision;
    entry.pin = pin;
    ++entry.generation;
    entry.insertion_rejections = 0;
    entry.state = entry.consumers.empty() ? State::retired : State::waiting_source;
}

bool NativeVoxelBlockDemand::request(Key key, std::uint64_t consumer, int priority,
                                     std::uint64_t revision, WorldPhysicalContentIdentity pin) {
    if (key.epoch != epoch_ || (entries_.find(key) == entries_.end() && entries_.size() >= max_entries_)) return false;
    auto &entry = entries_[key];
    if (entry.revision != revision || entry.pin.digest != pin.digest) supersede(entry, revision, pin);
    entry.consumers[consumer] = priority;
    entry.priority = 0;
    for (const auto &[id, urgency] : entry.consumers) entry.priority = std::max(entry.priority, urgency);
    if (entry.state == State::retired) entry.state = State::waiting_source;
    return true;
}

void NativeVoxelBlockDemand::source_ready(const Key &key, std::uint64_t revision, const WorldPhysicalContentIdentity &pin) {
    auto it = entries_.find(key);
    if (it == entries_.end() || key.epoch != epoch_) return;
    Entry &entry = it->second;
    if (entry.revision != revision || entry.pin.digest != pin.digest || entry.consumers.empty()) return;
    if (entry.state == State::waiting_source) {
        entry.queued_at = ++clock_;
        entry.state = State::queued;
    }
}

void NativeVoxelBlockDemand::invalidate(const Key &key, std::uint64_t revision, WorldPhysicalContentIdentity pin) {
    auto it = entries_.find(key);
    if (it != entries_.end()) supersede(it->second, revision, pin);
}

void NativeVoxelBlockDemand::release(const Key &key, std::uint64_t consumer) {
    auto it = entries_.find(key);
    if (it == entries_.end()) return;
    Entry &entry = it->second;
    entry.consumers.erase(consumer);
    entry.priority = 0;
    for (const auto &[id, urgency] : entry.consumers) entry.priority = std::max(entry.priority, urgency);
    if (entry.consumers.empty()) supersede(entry, entry.revision, entry.pin);
}

void NativeVoxelBlockDemand::reset_epoch(std::uint64_t epoch) {
    epoch_ = epoch;
    for (auto &[key, entry] : entries_) {
        if (key.epoch != epoch_) {
            entry.consumers.clear();
            supersede(entry, entry.revision, entry.pin);
        }
    }
}

std::vector<NativeVoxelBlockDemand::Ticket> NativeVoxelBlockDemand::dispatch(std::size_t max_jobs) {
    std::vector<Ticket> jobs;
    while (jobs.size() < max_jobs && in_flight_ < max_in_flight_ &&
           prepared_bytes_ <= max_prepared_bytes_ - max_block_bytes_ &&
           in_flight_ <= (max_prepared_bytes_ - prepared_bytes_ - max_block_bytes_) / max_block_bytes_) {
        auto best = entries_.end();
        for (auto it = entries_.begin(); it != entries_.end(); ++it) {
            // reset_epoch retires every old-epoch entry; only current entries
            // can remain queued.
            if (it->second.state != State::queued) continue;
            // One urgency point per eight dispatch ticks prevents starvation.
            const auto score = [&](const Entry &e) { return static_cast<std::int64_t>(e.priority) +
                static_cast<std::int64_t>((clock_ - e.queued_at) / 8); };
            if (best == entries_.end() || score(it->second) > score(best->second) ||
                (score(it->second) == score(best->second) && it->second.queued_at < best->second.queued_at)) best = it;
        }
        if (best == entries_.end()) break;
        Entry &entry = best->second;
        entry.state = State::encoding;
        ++entry.generation;
        ++in_flight_;
        ++clock_;
        jobs.push_back({best->first, entry.generation, entry.revision, entry.pin});
        active_jobs_[best->first].emplace(entry.generation, jobs.back());
    }
    return jobs;
}

bool NativeVoxelBlockDemand::same(const Entry &entry, const Ticket &ticket) {
    return entry.generation == ticket.generation && entry.revision == ticket.revision && entry.pin.digest == ticket.pin.digest;
}

bool NativeVoxelBlockDemand::complete(const Ticket &ticket, std::vector<std::uint8_t> bytes) {
    auto active = active_jobs_.find(ticket.key);
    if (active == active_jobs_.end()) return false;
    auto issued = active->second.find(ticket.generation);
    if (issued == active->second.end() || issued->second.revision != ticket.revision ||
        issued->second.pin.digest != ticket.pin.digest) return false;
    active->second.erase(issued);
    --in_flight_;
    if (active->second.empty()) active_jobs_.erase(active);
    auto it = entries_.find(ticket.key);
    // An active worker keeps its entry alive until this completion retires the
    // physical slot. Matching generation implies the entry is still encoding.
    if (ticket.key.epoch != epoch_ || !same(it->second, ticket)) return false;
    Entry &entry = it->second;
    if (bytes.empty()) {
        entry.state = State::failed_empty;
        return false;
    }
    if (bytes.size() > max_block_bytes_) {
        entry.state = State::failed_oversize;
        return false;
    }
    // dispatch reserved max_block_bytes_ for every still-running job. After
    // this job releases its reservation, every admitted payload fits here.
    prepared_bytes_ += bytes.size();
    entry.bytes = std::move(bytes);
    entry.state = State::prepared;
    return true;
}

bool NativeVoxelBlockDemand::insertion_result(const Ticket &ticket, bool accepted) {
    auto it = entries_.find(ticket.key);
    if (it == entries_.end() || ticket.key.epoch != epoch_ || !same(it->second, ticket) ||
        it->second.state != State::prepared) return false;
    Entry &entry = it->second;
    if (!accepted) {
        ++entry.insertion_rejections;
        return false;
    }
    clear_bytes(entry);
    entry.state = State::inserted_waiting_mesh;
    return true;
}

bool NativeVoxelBlockDemand::receipt(const Ticket &ticket, bool mesh_ready, bool physics_ready, bool physics_required) {
    auto it = entries_.find(ticket.key);
    if (it == entries_.end() || ticket.key.epoch != epoch_ || !same(it->second, ticket) ||
        it->second.state != State::inserted_waiting_mesh || !mesh_ready || (physics_required && !physics_ready)) return false;
    it->second.state = State::published;
    return true;
}

void NativeVoxelBlockDemand::mesh_exited(const Key &key) {
    auto it = entries_.find(key);
    if (it != entries_.end() && it->second.state == State::published)
        it->second.state = State::inserted_waiting_mesh;
}

void NativeVoxelBlockDemand::unloaded(const Key &key) {
    auto it = entries_.find(key);
    if (it == entries_.end()) return;
    Entry &entry = it->second;
    if (entry.state == State::inserted_waiting_mesh || entry.state == State::published) {
        ++entry.generation;
        // release supersedes the entry when its last consumer leaves, so an
        // inserted or published entry always retains demand here.
        entry.state = State::queued;
        entry.queued_at = ++clock_;
    }
}

std::size_t NativeVoxelBlockDemand::retire(std::size_t max_entries) {
    std::size_t count = 0;
    for (auto it = entries_.begin(); it != entries_.end() && count < max_entries;) {
        if (it->second.state == State::retired && active_jobs_.find(it->first) == active_jobs_.end()) { it = entries_.erase(it); ++count; }
        else ++it;
    }
    return count;
}

const NativeVoxelBlockDemand::Entry *NativeVoxelBlockDemand::find(const Key &key) const {
    auto it = entries_.find(key);
    return it == entries_.end() ? nullptr : &it->second;
}

} // namespace voxel::world_backend
