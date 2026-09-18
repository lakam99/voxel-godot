#include "native_feature_delta.hpp"

#include <algorithm>
#include <cmath>
#include <cstring>
#include <limits>
#include <tuple>
#include <utility>

namespace voxel::world_backend {
namespace {

[[noreturn]] void reject() {
    throw NativeFeatureDeltaRejected();
}

bool utf8_byte_less(const std::string &left, const std::string &right) noexcept {
    return std::lexicographical_compare(left.begin(), left.end(), right.begin(), right.end(),
        [](const char left_byte, const char right_byte) noexcept {
            return static_cast<std::uint8_t>(static_cast<unsigned char>(left_byte))
                < static_cast<std::uint8_t>(static_cast<unsigned char>(right_byte));
        });
}

void validate_id(const std::string &id) {
    if (id.empty() || id.size() > NativeFeatureDeltaLimits::MAX_ID_BYTES) reject();
    try {
        // NativeValue is the sole native UTF-8 admission authority.  The
        // temporary is intentionally discarded: an ID is not runtime state.
        static_cast<void>(NativeValue::string(id));
    } catch (const NativeValueRejected &) {
        reject();
    }
}

void validate_runtime_state(const NativeValue &runtime_state) {
    try {
        if (runtime_state.kind() != NativeValueKind::object) reject();
        // Revalidates every recursive limit, text leaf and number before the
        // immutable snapshot retains or serializes the supplied value.
        static_cast<void>(runtime_state.canonical_binary());
    } catch (const NativeValueRejected &) {
        reject();
    }
}

void validate_tombstone(const NativeFeatureTombstone &tombstone) {
    validate_id(tombstone.feature_id);
}

void validate_instance(NativePlayerCreatedInstance &instance) {
    validate_id(instance.instance_id);
    if (!std::isfinite(instance.world_y) || !std::isfinite(instance.facing)) reject();
    // Make bitwise serialization agree with value equality; C++ considers
    // signed zero equal but IEEE encodes it differently.
    if (instance.world_y == 0.0) instance.world_y = 0.0;
    if (instance.facing == 0.0) instance.facing = 0.0;
    try {
        // An instance owns a required durable block identity. Re-admission
        // rejects a moved-from/empty value before an otherwise valid record
        // could enter the immutable snapshot or FD1 serializer.
        instance.block_id = NativeBlockIdentity::create(instance.block_id.value());
    } catch (const std::invalid_argument &) {
        reject();
    }
    validate_runtime_state(instance.runtime_state);
}

void append_u32(std::vector<std::uint8_t> &out, const std::uint32_t value) {
    for (int shift = 24; shift >= 0; shift -= 8) out.push_back(static_cast<std::uint8_t>((value >> shift) & 0xffU));
}

void append_i32(std::vector<std::uint8_t> &out, const std::int32_t value) {
    append_u32(out, static_cast<std::uint32_t>(value));
}

void append_double(std::vector<std::uint8_t> &out, const double value) {
    static_assert(sizeof(double) == sizeof(std::uint64_t), "feature delta requires 64-bit double storage");
    static_assert(std::numeric_limits<double>::is_iec559, "feature delta requires IEEE-754 double storage");
    std::uint64_t bits = 0U;
    std::memcpy(&bits, &value, sizeof(bits));
    for (int shift = 56; shift >= 0; shift -= 8) out.push_back(static_cast<std::uint8_t>((bits >> shift) & 0xffU));
}

void append_string(std::vector<std::uint8_t> &out, const std::string &value) {
    append_u32(out, static_cast<std::uint32_t>(value.size()));
    out.insert(out.end(), value.begin(), value.end());
}

void append_value(std::vector<std::uint8_t> &out, const NativeValue &value) {
    const std::vector<std::uint8_t> bytes = value.canonical_binary();
    append_u32(out, static_cast<std::uint32_t>(bytes.size()));
    out.insert(out.end(), bytes.begin(), bytes.end());
}

std::vector<NativeFeatureTombstone> canonical_tombstones(std::vector<NativeFeatureTombstone> tombstones) {
    if (tombstones.size() > NativeFeatureDeltaLimits::MAX_TOMBSTONES) reject();
    for (const NativeFeatureTombstone &tombstone : tombstones) validate_tombstone(tombstone);
    std::sort(tombstones.begin(), tombstones.end(), [](const auto &left, const auto &right) {
        return utf8_byte_less(left.feature_id, right.feature_id);
    });
    for (std::size_t index = 1U; index < tombstones.size(); ++index) {
        if (tombstones[index - 1U].feature_id == tombstones[index].feature_id) reject();
    }
    return tombstones;
}

std::vector<NativePlayerCreatedInstance> canonical_instances(std::vector<NativePlayerCreatedInstance> instances) {
    if (instances.size() > NativeFeatureDeltaLimits::MAX_PLAYER_CREATED_INSTANCES) reject();
    for (NativePlayerCreatedInstance &instance : instances) validate_instance(instance);
    std::sort(instances.begin(), instances.end(), [](const auto &left, const auto &right) {
        return utf8_byte_less(left.instance_id, right.instance_id);
    });
    for (std::size_t index = 1U; index < instances.size(); ++index) {
        if (instances[index - 1U].instance_id == instances[index].instance_id) reject();
    }
    // Cells are a physical occupancy key independent of stable identity; a
    // player feature snapshot cannot smuggle two created blockers into one
    // cell merely by using distinct durable IDs.
    std::vector<CellCoord> occupied_cells;
    occupied_cells.reserve(instances.size());
    for (const NativePlayerCreatedInstance &instance : instances) {
        occupied_cells.push_back(instance.cell);
    }
    std::sort(occupied_cells.begin(), occupied_cells.end(), [](const CellCoord &left, const CellCoord &right) {
        return std::tie(left.x, left.y, left.z) < std::tie(right.x, right.y, right.z);
    });
    for (std::size_t index = 1U; index < occupied_cells.size(); ++index) {
        if (occupied_cells[index - 1U] == occupied_cells[index]) reject();
    }
    return instances;
}

} // namespace

NativeFeatureDeltaRejected::NativeFeatureDeltaRejected()
    : std::invalid_argument("invalid native feature delta") {}

bool NativeFeatureTombstone::operator==(const NativeFeatureTombstone &other) const noexcept {
    return feature_id == other.feature_id;
}

bool NativePlayerCreatedInstance::operator==(const NativePlayerCreatedInstance &other) const noexcept {
    return instance_id == other.instance_id && cell == other.cell && world_y == other.world_y && facing == other.facing
        && block_id == other.block_id && runtime_state == other.runtime_state;
}

NativeFeatureDeltaSnapshot::NativeFeatureDeltaSnapshot(
    std::vector<NativeFeatureTombstone> tombstones,
    std::vector<NativePlayerCreatedInstance> player_created_instances)
    : tombstones_(std::move(tombstones)), player_created_instances_(std::move(player_created_instances)) {}

NativeFeatureDeltaSnapshot NativeFeatureDeltaSnapshot::create(
    std::vector<NativeFeatureTombstone> tombstones,
    std::vector<NativePlayerCreatedInstance> player_created_instances) {
    std::vector<NativeFeatureTombstone> canonical_tombstones_value = canonical_tombstones(std::move(tombstones));
    std::vector<NativePlayerCreatedInstance> canonical_instances_value = canonical_instances(std::move(player_created_instances));
    return NativeFeatureDeltaSnapshot(std::move(canonical_tombstones_value), std::move(canonical_instances_value));
}

const std::vector<NativeFeatureTombstone> &NativeFeatureDeltaSnapshot::tombstones() const noexcept {
    return tombstones_;
}

const std::vector<NativePlayerCreatedInstance> &NativeFeatureDeltaSnapshot::player_created_instances() const noexcept {
    return player_created_instances_;
}

std::vector<std::uint8_t> NativeFeatureDeltaSnapshot::canonical_binary() const {
    // Public factory admission is repeated at the serialization boundary to
    // keep a future deserializer or memory-corruption path fail-closed.
    const std::vector<NativeFeatureTombstone> tombstones = canonical_tombstones(tombstones_);
    const std::vector<NativePlayerCreatedInstance> instances = canonical_instances(player_created_instances_);
    std::vector<std::uint8_t> result = {'F', 'D', '1'};
    append_u32(result, static_cast<std::uint32_t>(tombstones.size()));
    for (const NativeFeatureTombstone &tombstone : tombstones) {
        result.push_back(0x01U);
        append_string(result, tombstone.feature_id);
    }
    append_u32(result, static_cast<std::uint32_t>(instances.size()));
    for (const NativePlayerCreatedInstance &instance : instances) {
        result.push_back(0x02U);
        append_string(result, instance.instance_id);
        append_i32(result, instance.cell.x);
        append_i32(result, instance.cell.y);
        append_i32(result, instance.cell.z);
        append_double(result, instance.world_y);
        append_double(result, instance.facing);
        append_string(result, instance.block_id.value());
        append_value(result, instance.runtime_state);
    }
    return result;
}

bool NativeFeatureDeltaSnapshot::operator==(const NativeFeatureDeltaSnapshot &other) const noexcept {
    return tombstones_ == other.tombstones_ && player_created_instances_ == other.player_created_instances_;
}

bool NativeFeatureDeltaSnapshot::operator!=(const NativeFeatureDeltaSnapshot &other) const noexcept {
    return !(*this == other);
}

} // namespace voxel::world_backend
