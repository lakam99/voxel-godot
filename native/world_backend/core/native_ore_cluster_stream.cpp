#include "native_ore_cluster_stream.hpp"

#include <utility>

namespace voxel::world_backend {
namespace { [[noreturn]] void reject() { throw NativeOreClusterStreamRejected(); } }
NativeOreClusterStreamRejected::NativeOreClusterStreamRejected() : std::invalid_argument("invalid native ore cluster stream") {}

NativeOreClusterChildStream native_ore_cluster_child_stream(
    const std::string &parent_id, const NativeOreKind kind,
    const std::uint32_t child_index, const std::uint32_t child_count,
    const NativeFeatureDeltaSnapshot &removed_props, GodotPcg32 &rng) {
    if (parent_id.empty() || (kind != NativeOreKind::iron && kind != NativeOreKind::copper)
        || child_count == 0U || child_count > 4U || child_index >= child_count) reject();
    NativeOreClusterChildStream child;
    child.durable_id = child_index == 0U
        ? parent_id : parent_id + ":cluster" + std::to_string(child_index);
    child.state_before = rng.state();
    child.skipped_by_tombstone = removed_props.contains_tombstone(child.durable_id);
    if (child.skipped_by_tombstone) {
        child.state_after = child.state_before;
        return child;
    }
    const auto draw = [&]() { child.float_draws.push_back(rng.randf()); };
    draw(); // cluster angle
    if (child_index != 0U) draw(); // non-root spacing
    draw(); // vertical offset
    draw(); // ore rotation
    child.drop_count = rng.randi_range(1, kind == NativeOreKind::iron ? 2 : 3);
    draw(); draw(); draw(); draw(); draw(); // radius, height factor, scale
    for (int vein = 0; vein < 5; ++vein) for (int value = 0; value < 6; ++value) draw();
    for (int glint = 0; glint < 3; ++glint) for (int value = 0; value < 3; ++value) draw();
    child.state_after = rng.state();
    return child;
}

NativeOreClusterStream::NativeOreClusterStream(std::array<NativeOreClusterChildStream, 2> children, const std::uint64_t final_state) noexcept
    : children_(std::move(children)), final_state_(final_state) {}
NativeOreClusterStream NativeOreClusterStream::create(const std::string &parent_id, const NativeOreKind kind, GodotPcg32 &rng) {
    return create(parent_id, kind, NativeFeatureDeltaSnapshot::create({}, {}), rng);
}
NativeOreClusterStream NativeOreClusterStream::create(const std::string &parent_id, const NativeOreKind kind,
    const NativeFeatureDeltaSnapshot &removed_props, GodotPcg32 &rng) {
    std::array<NativeOreClusterChildStream, 2> children{};
    for (std::size_t index = 0U; index < children.size(); ++index) {
        children[index] = native_ore_cluster_child_stream(parent_id, kind,
            static_cast<std::uint32_t>(index), 2U, removed_props, rng);
    }
    return NativeOreClusterStream(std::move(children), rng.state());
}
const std::array<NativeOreClusterChildStream, 2> &NativeOreClusterStream::children() const noexcept { return children_; }
std::uint64_t NativeOreClusterStream::final_rng_state() const noexcept { return final_state_; }
} // namespace voxel::world_backend
