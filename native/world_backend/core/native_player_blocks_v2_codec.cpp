#include "native_player_blocks_v2_codec.hpp"

#include <algorithm>
#include <cmath>
#include <limits>
#include <set>
#include <tuple>
#include <utility>

namespace voxel::world_backend {
namespace {

constexpr double MAX_SAFE_JSON_INTEGER = 9007199254740991.0;
// MainInterface.gd's CELL constant is part of the unchanged v2 restore
// contract: omitted worldY falls back to cell.y * CELL.
constexpr double PLAYER_BLOCK_CELL_SIZE = 1.35;

[[noreturn]] void reject() {
    throw NativePlayerBlocksV2Rejected();
}

bool utf8_byte_less(const std::string &left, const std::string &right) noexcept {
    return std::lexicographical_compare(left.begin(), left.end(), right.begin(), right.end(),
        [](const char left_byte, const char right_byte) noexcept {
            return static_cast<std::uint8_t>(static_cast<unsigned char>(left_byte))
                < static_cast<std::uint8_t>(static_cast<unsigned char>(right_byte));
        });
}

struct CellLess final {
    bool operator()(const CellCoord &left, const CellCoord &right) const noexcept {
        return std::tie(left.x, left.y, left.z) < std::tie(right.x, right.y, right.z);
    }
};

const NativeValue &member(const NativeValue::Object &object, const std::string &key) {
    const auto found = std::lower_bound(object.begin(), object.end(), key,
        [](const auto &entry, const std::string &needle) { return entry.first < needle; });
    if (found == object.end() || found->first != key) reject();
    return found->second;
}

bool has_member(const NativeValue::Object &object, const std::string &key) {
    const auto found = std::lower_bound(object.begin(), object.end(), key,
        [](const auto &entry, const std::string &needle) { return entry.first < needle; });
    return found != object.end() && found->first == key;
}

void require_exact_keys(const NativeValue::Object &object, std::vector<std::string> keys) {
    std::sort(keys.begin(), keys.end());
    if (object.size() != keys.size()) reject();
    for (std::size_t index = 0U; index < keys.size(); ++index) {
        if (object[index].first != keys[index]) reject();
    }
}

const NativeValue::Object &require_object(const NativeValue &value) {
    if (value.kind() != NativeValueKind::object) reject();
    return value.as_object();
}

const NativeValue::Array &require_array(const NativeValue &value) {
    if (value.kind() != NativeValueKind::array) reject();
    return value.as_array();
}

const std::string &require_string(const NativeValue &value) {
    if (value.kind() != NativeValueKind::string) reject();
    return value.as_string();
}

bool require_boolean(const NativeValue &value) {
    if (value.kind() != NativeValueKind::boolean) reject();
    return value.as_boolean();
}

double require_number(const NativeValue &value) {
    if (value.kind() != NativeValueKind::number) reject();
    return value.as_number();
}

std::int64_t require_safe_integer(const NativeValue &value) {
    const double number = require_number(value);
    if (number < -MAX_SAFE_JSON_INTEGER || number > MAX_SAFE_JSON_INTEGER || std::trunc(number) != number) reject();
    return static_cast<std::int64_t>(number);
}

std::int32_t require_i32(const NativeValue &value) {
    const std::int64_t integer = require_safe_integer(value);
    if (integer < std::numeric_limits<std::int32_t>::min()
        || integer > std::numeric_limits<std::int32_t>::max()) reject();
    return static_cast<std::int32_t>(integer);
}

CellCoord parse_cell(const NativeValue &value) {
    const NativeValue::Array &cell = require_array(value);
    if (cell.size() != 3U) reject();
    return {require_i32(cell[0]), require_i32(cell[1]), require_i32(cell[2])};
}

NativeValue encode_cell(const CellCoord &cell) {
    return NativeValue::array({
        NativeValue::number(static_cast<double>(cell.x)),
        NativeValue::number(static_cast<double>(cell.y)),
        NativeValue::number(static_cast<double>(cell.z)),
    });
}

struct Slot final {
    std::string item;
    std::uint32_t count = 0U;
};

struct FurnaceState final {
    Slot input;
    Slot fuel;
    Slot output;
    bool processing = false;
    double progress = 0.0;
    double duration = 4.5;
    std::string output_item;
};

struct RuntimeState final {
    bool open = false;
    bool locked = false;
    bool jammed = false;
    bool destroyed = false;
    std::string door_portal_id;
    std::string door_group_id;
    std::optional<std::vector<Slot>> storage_slots;
    std::optional<FurnaceState> furnace_state;
};

Slot parse_slot(
    const NativeValue &value,
    const NativePlayerBlocksV2Catalog &catalog,
    const bool allow_omitted_defaults) {
    const NativeValue::Object &object = require_object(value);
    std::vector<std::string> keys;
    if (has_member(object, "count")) keys.push_back("count");
    if (has_member(object, "item")) keys.push_back("item");
    if (!allow_omitted_defaults) keys = {"count", "item"};
    require_exact_keys(object, std::move(keys));
    const std::string item = has_member(object, "item")
        ? require_string(member(object, "item"))
        : std::string{};
    const std::int64_t count = has_member(object, "count")
        ? require_safe_integer(member(object, "count"))
        : 0;
    const std::optional<std::uint32_t> stack_max = catalog.stack_max(item);
    if (!stack_max.has_value() || count <= 0) return {};
    return {item, static_cast<std::uint32_t>(std::min<std::uint64_t>(
        static_cast<std::uint64_t>(count), static_cast<std::uint64_t>(*stack_max)))};
}

NativeValue encode_slot(const Slot &slot) {
    return NativeValue::object({
        {"count", NativeValue::number(static_cast<double>(slot.count))},
        {"item", NativeValue::string(slot.item)},
    });
}

std::vector<Slot> parse_storage_slots(
    const NativeValue &value,
    const NativePlayerBlocksV2Catalog &catalog,
    const bool allow_omitted_defaults) {
    const NativeValue::Array &source = require_array(value);
    std::vector<Slot> result(NativePlayerBlocksV2Limits::CHEST_SLOT_COUNT);
    const std::size_t retained = std::min(source.size(), result.size());
    for (std::size_t index = 0U; index < retained; ++index) {
        result[index] = parse_slot(source[index], catalog, allow_omitted_defaults);
    }
    // MainSaveState.restore_slots ignores entries after CHEST_SIZE, but strict
    // wire validation still rejects malformed trailing values instead of
    // allowing unexamined data through the native boundary.
    for (std::size_t index = retained; index < source.size(); ++index) {
        static_cast<void>(parse_slot(source[index], catalog, allow_omitted_defaults));
    }
    return result;
}

NativeValue encode_storage_slots(const std::vector<Slot> &slots) {
    NativeValue::Array result;
    result.reserve(slots.size());
    for (const Slot &slot : slots) result.push_back(encode_slot(slot));
    return NativeValue::array(std::move(result));
}

FurnaceState parse_furnace_state(
    const NativeValue &value,
    const NativePlayerBlocksV2Catalog &catalog,
    const bool allow_omitted_defaults) {
    const NativeValue::Object &object = require_object(value);
    const std::vector<std::string> furnace_keys = {
        "duration", "fuel", "input", "output", "outputItem", "processing", "progress",
    };
    std::vector<std::string> keys;
    if (allow_omitted_defaults) {
        for (const std::string &key : furnace_keys) {
            if (has_member(object, key)) keys.push_back(key);
        }
    } else {
        keys = furnace_keys;
    }
    require_exact_keys(object, std::move(keys));
    FurnaceState result;
    if (has_member(object, "input")) result.input = parse_slot(member(object, "input"), catalog, allow_omitted_defaults);
    if (has_member(object, "fuel")) result.fuel = parse_slot(member(object, "fuel"), catalog, allow_omitted_defaults);
    if (has_member(object, "output")) result.output = parse_slot(member(object, "output"), catalog, allow_omitted_defaults);
    if (has_member(object, "processing")) result.processing = require_boolean(member(object, "processing"));
    if (has_member(object, "progress")) result.progress = std::max(0.0, require_number(member(object, "progress")));
    if (has_member(object, "duration")) result.duration = std::max(0.1, require_number(member(object, "duration")));
    if (has_member(object, "outputItem")) result.output_item = require_string(member(object, "outputItem"));
    return result;
}

NativeValue encode_furnace_state(const FurnaceState &state) {
    return NativeValue::object({
        {"duration", NativeValue::number(state.duration)},
        {"fuel", encode_slot(state.fuel)},
        {"input", encode_slot(state.input)},
        {"output", encode_slot(state.output)},
        {"outputItem", NativeValue::string(state.output_item)},
        {"processing", NativeValue::boolean(state.processing)},
        {"progress", NativeValue::number(state.progress)},
    });
}

RuntimeState parse_runtime_state(
    const NativeValue::Object &object,
    const std::string &block_type,
    const NativePlayerBlocksV2Catalog &catalog,
    const bool outer_entry,
    const bool allow_omitted_defaults) {
    const std::vector<std::string> runtime_keys = {
        "destroyed", "doorGroupId", "doorPortalId", "jammed", "locked", "open",
    };
    std::vector<std::string> keys;
    if (allow_omitted_defaults) {
        for (const std::string &key : runtime_keys) {
            if (has_member(object, key)) keys.push_back(key);
        }
    } else {
        keys = runtime_keys;
    }
    if (has_member(object, "storageSlots")) keys.push_back("storageSlots");
    if (has_member(object, "furnaceState")) keys.push_back("furnaceState");
    if (outer_entry) {
        keys.insert(keys.end(), {"cell", "type"});
        // outer_entry is the compatibility decode shape, so these fields are
        // optional exactly as MainSaveState.restore_player_blocks specifies.
        // The strict encode shape is runtime_state-only and never enters this
        // branch; avoid encoding that impossible pairing as uncovered logic.
        if (has_member(object, "facing")) keys.push_back("facing");
        if (has_member(object, "worldY")) keys.push_back("worldY");
    }
    require_exact_keys(object, std::move(keys));

    RuntimeState result;
    if (has_member(object, "open")) result.open = require_boolean(member(object, "open"));
    if (has_member(object, "locked")) result.locked = require_boolean(member(object, "locked"));
    if (has_member(object, "jammed")) result.jammed = require_boolean(member(object, "jammed"));
    if (has_member(object, "destroyed")) result.destroyed = require_boolean(member(object, "destroyed"));
    if (has_member(object, "doorPortalId")) result.door_portal_id = require_string(member(object, "doorPortalId"));
    if (has_member(object, "doorGroupId")) result.door_group_id = require_string(member(object, "doorGroupId"));
    if (has_member(object, "storageSlots")) {
        if (block_type != "chest") reject();
        result.storage_slots = parse_storage_slots(member(object, "storageSlots"), catalog, allow_omitted_defaults);
    }
    if (has_member(object, "furnaceState")) {
        if (block_type != "furnace" && block_type != "campfire") reject();
        result.furnace_state = parse_furnace_state(member(object, "furnaceState"), catalog, allow_omitted_defaults);
    }
    if (block_type == "door") {
        // create_block derives a missing portal exactly from a known group.
        // A missing group depends on live neighbouring block types, which are
        // deliberately outside this isolated codec; retain it as an empty
        // publication-time default rather than inventing a facing-only ID.
        if (result.door_portal_id.empty() && !result.door_group_id.empty()) {
            result.door_portal_id = "door:" + result.door_group_id;
        }
    } else if (result.open || result.locked || result.jammed || result.destroyed
        || !result.door_portal_id.empty() || !result.door_group_id.empty()) {
        reject();
    }
    return result;
}

NativeValue encode_runtime_state(const RuntimeState &state) {
    NativeValue::Object object = {
        {"destroyed", NativeValue::boolean(state.destroyed)},
        {"doorGroupId", NativeValue::string(state.door_group_id)},
        {"doorPortalId", NativeValue::string(state.door_portal_id)},
    };
    if (state.furnace_state.has_value()) object.push_back({"furnaceState", encode_furnace_state(*state.furnace_state)});
    object.push_back({"jammed", NativeValue::boolean(state.jammed)});
    object.push_back({"locked", NativeValue::boolean(state.locked)});
    object.push_back({"open", NativeValue::boolean(state.open)});
    if (state.storage_slots.has_value()) object.push_back({"storageSlots", encode_storage_slots(*state.storage_slots)});
    return NativeValue::object(std::move(object));
}

NativePlayerCreatedInstance parse_entry(const NativeValue &entry, const NativePlayerBlocksV2Catalog &catalog) {
    const NativeValue::Object &object = require_object(entry);
    const std::string block_type = require_string(member(object, "type"));
    if (!catalog.is_placeable(block_type)) reject();
    const CellCoord cell = parse_cell(member(object, "cell"));
    const double world_y = has_member(object, "worldY")
        ? require_number(member(object, "worldY"))
        : static_cast<double>(cell.y) * PLAYER_BLOCK_CELL_SIZE;
    const double facing = has_member(object, "facing")
        ? require_number(member(object, "facing"))
        : 0.0;
    const RuntimeState runtime_state = parse_runtime_state(object, block_type, catalog, true, true);
    return {
        native_player_block_v2_instance_id(cell),
        cell,
        world_y,
        facing,
        NativeBlockIdentity::create(block_type),
        encode_runtime_state(runtime_state),
    };
}

NativeValue encode_entry(const NativePlayerCreatedInstance &instance, const NativePlayerBlocksV2Catalog &catalog) {
    const std::string &block_type = instance.block_id.value();
    if (!catalog.is_placeable(block_type)) reject();
    if (instance.instance_id != native_player_block_v2_instance_id(instance.cell)) reject();
    const RuntimeState runtime_state = parse_runtime_state(
        require_object(instance.runtime_state), block_type, catalog, false, false);
    NativeValue::Object object = {
        {"cell", encode_cell(instance.cell)},
        {"destroyed", NativeValue::boolean(runtime_state.destroyed)},
        {"doorGroupId", NativeValue::string(runtime_state.door_group_id)},
        {"doorPortalId", NativeValue::string(runtime_state.door_portal_id)},
        {"facing", NativeValue::number(instance.facing)},
    };
    if (runtime_state.furnace_state.has_value()) object.push_back({"furnaceState", encode_furnace_state(*runtime_state.furnace_state)});
    object.push_back({"jammed", NativeValue::boolean(runtime_state.jammed)});
    object.push_back({"locked", NativeValue::boolean(runtime_state.locked)});
    object.push_back({"open", NativeValue::boolean(runtime_state.open)});
    if (runtime_state.storage_slots.has_value()) object.push_back({"storageSlots", encode_storage_slots(*runtime_state.storage_slots)});
    object.push_back({"type", NativeValue::string(block_type)});
    object.push_back({"worldY", NativeValue::number(instance.world_y)});
    return NativeValue::object(std::move(object));
}

} // namespace

NativePlayerBlocksV2Rejected::NativePlayerBlocksV2Rejected()
    : std::invalid_argument("invalid v2 player blocks payload") {}

NativePlayerBlocksV2Catalog::NativePlayerBlocksV2Catalog(std::vector<NativePlayerBlocksV2ItemSpec> items)
    : items_(std::move(items)) {}

NativePlayerBlocksV2Catalog NativePlayerBlocksV2Catalog::create(std::vector<NativePlayerBlocksV2ItemSpec> items) {
    if (items.empty() || items.size() > NativePlayerBlocksV2Limits::MAX_CATALOG_ITEMS) reject();
    for (const NativePlayerBlocksV2ItemSpec &item : items) {
        if (item.item_id.empty() || item.stack_max == 0U) reject();
        try {
            static_cast<void>(NativeValue::string(item.item_id));
            if (item.placeable) static_cast<void>(NativeBlockIdentity::create(item.item_id));
        } catch (const NativeValueRejected &) {
            reject();
        }
    }
    std::sort(items.begin(), items.end(), [](const auto &left, const auto &right) {
        return utf8_byte_less(left.item_id, right.item_id);
    });
    for (std::size_t index = 1U; index < items.size(); ++index) {
        if (items[index - 1U].item_id == items[index].item_id) reject();
    }
    if (std::none_of(items.begin(), items.end(), [](const auto &item) { return item.placeable; })) reject();
    return NativePlayerBlocksV2Catalog(std::move(items));
}

bool NativePlayerBlocksV2Catalog::is_placeable(const std::string &item_id) const noexcept {
    const auto found = std::lower_bound(items_.begin(), items_.end(), item_id,
        [](const auto &item, const std::string &needle) { return utf8_byte_less(item.item_id, needle); });
    return found != items_.end() && found->item_id == item_id && found->placeable;
}

std::optional<std::uint32_t> NativePlayerBlocksV2Catalog::stack_max(const std::string &item_id) const noexcept {
    const auto found = std::lower_bound(items_.begin(), items_.end(), item_id,
        [](const auto &item, const std::string &needle) { return utf8_byte_less(item.item_id, needle); });
    if (found == items_.end() || found->item_id != item_id) return std::nullopt;
    return found->stack_max;
}

const std::vector<NativePlayerBlocksV2ItemSpec> &NativePlayerBlocksV2Catalog::items() const noexcept {
    return items_;
}

std::string native_player_block_v2_instance_id(const CellCoord &cell) {
    return "v2/player-block/cell/" + std::to_string(cell.x) + "/" + std::to_string(cell.y) + "/" + std::to_string(cell.z);
}

NativeFeatureDeltaSnapshot decode_native_player_blocks_v2(
    const std::vector<NativeValue> &entries,
    const NativePlayerBlocksV2Catalog &catalog,
    const std::vector<CellCoord> &already_occupied_cells) {
    if (entries.size() > NativePlayerBlocksV2Limits::MAX_BLOCKS) reject();
    std::set<CellCoord, CellLess> occupied(already_occupied_cells.begin(), already_occupied_cells.end());
    std::vector<NativePlayerCreatedInstance> instances;
    instances.reserve(entries.size());
    for (const NativeValue &entry : entries) {
        NativePlayerCreatedInstance instance = parse_entry(entry, catalog);
        if (!occupied.insert(instance.cell).second) continue;
        instances.push_back(std::move(instance));
    }
    return NativeFeatureDeltaSnapshot::create({}, std::move(instances));
}

std::vector<NativeValue> encode_native_player_blocks_v2(
    const NativeFeatureDeltaSnapshot &snapshot,
    const NativePlayerBlocksV2Catalog &catalog) {
    if (!snapshot.tombstones().empty()) reject();
    std::vector<NativePlayerCreatedInstance> instances = snapshot.player_created_instances();
    std::sort(instances.begin(), instances.end(), [](const auto &left, const auto &right) {
        return std::tie(left.cell.z, left.cell.y, left.cell.x) < std::tie(right.cell.z, right.cell.y, right.cell.x);
    });
    std::vector<NativeValue> result;
    result.reserve(instances.size());
    for (const NativePlayerCreatedInstance &instance : instances) result.push_back(encode_entry(instance, catalog));
    return result;
}

} // namespace voxel::world_backend
