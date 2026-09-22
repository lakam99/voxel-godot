#include "test_harness.hpp"

#include "../core/native_player_blocks_v2_codec.hpp"

#include <algorithm>
#include <optional>
#include <string>
#include <utility>
#include <vector>

using namespace voxel::world_backend;

namespace {

NativePlayerBlocksV2Catalog catalog() {
    return NativePlayerBlocksV2Catalog::create({
        {"stoneBlock", 64U, true},
        {"door", 16U, true},
        {"chest", 16U, true},
        {"furnace", 8U, true},
        {"campfire", 16U, true},
        {"logs", 32U, false},
        {"ironOre", 32U, false},
        {"ironIngot", 24U, false},
    });
}

NativeValue slot(const std::string &item, const double count) {
    return NativeValue::object({
        {"count", NativeValue::number(count)},
        {"item", NativeValue::string(item)},
    });
}

NativeValue furnace_state(
    const double progress = 2.0,
    const double duration = 6.8,
    const bool processing = true) {
    return NativeValue::object({
        {"duration", NativeValue::number(duration)},
        {"fuel", slot("logs", 2.0)},
        {"input", slot("ironOre", 3.0)},
        {"output", slot("ironIngot", 1.0)},
        {"outputItem", NativeValue::string("ironIngot")},
        {"processing", NativeValue::boolean(processing)},
        {"progress", NativeValue::number(progress)},
    });
}

NativeValue entry(
    const std::string &type,
    const CellCoord &cell,
    const double world_y = 3.25,
    const double facing = 0.5,
    const bool open = false,
    const bool locked = false,
    const bool jammed = false,
    const bool destroyed = false,
    const std::string &portal = "",
    const std::string &group = "",
    std::optional<NativeValue> storage = std::nullopt,
    std::optional<NativeValue> furnace = std::nullopt) {
    NativeValue::Object object = {
        {"cell", NativeValue::array({
            NativeValue::number(static_cast<double>(cell.x)),
            NativeValue::number(static_cast<double>(cell.y)),
            NativeValue::number(static_cast<double>(cell.z)),
        })},
        {"destroyed", NativeValue::boolean(destroyed)},
        {"doorGroupId", NativeValue::string(group)},
        {"doorPortalId", NativeValue::string(portal)},
        {"facing", NativeValue::number(facing)},
    };
    if (furnace.has_value()) object.push_back({"furnaceState", std::move(*furnace)});
    object.push_back({"jammed", NativeValue::boolean(jammed)});
    object.push_back({"locked", NativeValue::boolean(locked)});
    object.push_back({"open", NativeValue::boolean(open)});
    if (storage.has_value()) object.push_back({"storageSlots", std::move(*storage)});
    object.push_back({"type", NativeValue::string(type)});
    object.push_back({"worldY", NativeValue::number(world_y)});
    return NativeValue::object(std::move(object));
}

const NativeValue &field(const NativeValue &value, const std::string &key) {
    for (const auto &member : value.as_object()) {
        if (member.first == key) return member.second;
    }
    throw std::logic_error("missing test field");
}

NativeValue replace_field(const NativeValue &value, const std::string &key, NativeValue replacement) {
    NativeValue::Object object = value.as_object();
    for (auto &member : object) {
        if (member.first == key) {
            member.second = std::move(replacement);
            return NativeValue::object(std::move(object));
        }
    }
    throw std::logic_error("missing test field");
}

NativeValue remove_field(const NativeValue &value, const std::string &key) {
    NativeValue::Object object = value.as_object();
    object.erase(std::remove_if(object.begin(), object.end(), [&](const auto &member) {
        return member.first == key;
    }), object.end());
    return NativeValue::object(std::move(object));
}

NativeValue add_field(const NativeValue &value, std::string key, NativeValue added) {
    NativeValue::Object object = value.as_object();
    object.push_back({std::move(key), std::move(added)});
    std::sort(object.begin(), object.end(), [](const auto &left, const auto &right) {
        return left.first < right.first;
    });
    return NativeValue::object(std::move(object));
}

const NativePlayerCreatedInstance &instance_with_type(
    const NativeFeatureDeltaSnapshot &snapshot,
    const std::string &type) {
    for (const NativePlayerCreatedInstance &instance : snapshot.player_created_instances()) {
        if (instance.block_id.value() == type) return instance;
    }
    throw std::logic_error("missing test instance");
}

NativeFeatureDeltaSnapshot one_instance_snapshot(const NativeValue &value) {
    return decode_native_player_blocks_v2({value}, catalog(), {});
}

} // namespace

VWB_TEST(native_player_blocks_v2_catalog_is_immutable_sorted_and_rejects_mistranslated_policy) {
    const NativePlayerBlocksV2Catalog value = catalog();
    VWB_EXPECT_EQ(std::string("campfire"), value.items().front().item_id);
    VWB_EXPECT_EQ(std::string("stoneBlock"), value.items().back().item_id);
    VWB_EXPECT(value.is_placeable("door"));
    VWB_EXPECT(!value.is_placeable("logs"));
    VWB_EXPECT(!value.is_placeable("candle"));
    VWB_EXPECT(!value.is_placeable("unknown"));
    VWB_EXPECT_EQ(32U, *value.stack_max("logs"));
    VWB_EXPECT(!value.stack_max("unknown").has_value());

    VWB_EXPECT_THROW(NativePlayerBlocksV2Rejected, NativePlayerBlocksV2Catalog::create({}));
    VWB_EXPECT_THROW(NativePlayerBlocksV2Rejected, NativePlayerBlocksV2Catalog::create({{"", 1U, true}}));
    VWB_EXPECT_THROW(NativePlayerBlocksV2Rejected, NativePlayerBlocksV2Catalog::create({{"x", 0U, true}}));
    VWB_EXPECT_THROW(NativePlayerBlocksV2Rejected, NativePlayerBlocksV2Catalog::create({{"x", 1U, true}, {"x", 2U, false}}));
    VWB_EXPECT_THROW(NativePlayerBlocksV2Rejected, NativePlayerBlocksV2Catalog::create({{"x", 1U, false}}));
    VWB_EXPECT_THROW(NativePlayerBlocksV2Rejected, NativePlayerBlocksV2Catalog::create({{
        std::string("bad\xc0\x80", 5), 1U, true,
    }}));
    std::vector<NativePlayerBlocksV2ItemSpec> too_many(
        NativePlayerBlocksV2Limits::MAX_CATALOG_ITEMS + 1U, {"x", 1U, true});
    VWB_EXPECT_THROW(NativePlayerBlocksV2Rejected, NativePlayerBlocksV2Catalog::create(std::move(too_many)));
}

VWB_TEST(native_player_blocks_v2_derives_reserved_cell_identity_without_world_y_mistranslation) {
    VWB_EXPECT_EQ(std::string("v2/player-block/cell/-12/34/-56"),
        native_player_block_v2_instance_id({-12, 34, -56}));
    const NativeFeatureDeltaSnapshot decoded = one_instance_snapshot(entry(
        "stoneBlock", {-12, 34, -56}, 17.125, -2.75));
    const NativePlayerCreatedInstance &placed = decoded.player_created_instances()[0];
    VWB_EXPECT_EQ(std::string("v2/player-block/cell/-12/34/-56"), placed.instance_id);
    VWB_EXPECT_EQ(17.125, placed.world_y);
    VWB_EXPECT_EQ(-2.75, placed.facing);
    VWB_EXPECT_EQ(std::string("stoneBlock"), placed.block_id.value());
}

VWB_TEST(native_player_blocks_v2_accepts_restore_defaults_but_canonicalizes_the_export) {
    NativeValue legacy = entry("stoneBlock", {-2, 4, 7});
    for (const std::string &key : {
        "destroyed", "doorGroupId", "doorPortalId", "facing", "jammed", "locked", "open", "worldY",
    }) {
        legacy = remove_field(legacy, key);
    }

    const NativeFeatureDeltaSnapshot decoded = one_instance_snapshot(legacy);
    const NativePlayerCreatedInstance &placed = decoded.player_created_instances()[0];
    VWB_EXPECT_EQ(5.4, placed.world_y);
    VWB_EXPECT_EQ(0.0, placed.facing);
    for (const std::string &key : {"destroyed", "jammed", "locked", "open"}) {
        VWB_EXPECT(!field(placed.runtime_state, key).as_boolean());
    }
    VWB_EXPECT_EQ(std::string(""), field(placed.runtime_state, "doorGroupId").as_string());
    VWB_EXPECT_EQ(std::string(""), field(placed.runtime_state, "doorPortalId").as_string());

    const std::vector<NativeValue> encoded = encode_native_player_blocks_v2(decoded, catalog());
    VWB_EXPECT_EQ(1U, encoded.size());
    VWB_EXPECT_EQ(5.4, field(encoded[0], "worldY").as_number());
    VWB_EXPECT_EQ(0.0, field(encoded[0], "facing").as_number());
    VWB_EXPECT_EQ(10U, encoded[0].as_object().size());
}

VWB_TEST(native_player_blocks_v2_defers_contextual_door_group_and_derives_only_known_portal) {
    NativeValue contextual = entry("door", {5, 7, 2}, 8.125, 1.25, true);
    for (const std::string &key : {"destroyed", "doorGroupId", "doorPortalId", "jammed", "locked"}) {
        contextual = remove_field(contextual, key);
    }
    const NativeFeatureDeltaSnapshot contextual_decoded = one_instance_snapshot(contextual);
    const NativeValue &contextual_state = contextual_decoded.player_created_instances()[0].runtime_state;
    VWB_EXPECT(field(contextual_state, "open").as_boolean());
    VWB_EXPECT_EQ(std::string(""), field(contextual_state, "doorGroupId").as_string());
    VWB_EXPECT_EQ(std::string(""), field(contextual_state, "doorPortalId").as_string());
    const std::vector<NativeValue> contextual_encoded = encode_native_player_blocks_v2(contextual_decoded, catalog());
    VWB_EXPECT_EQ(std::string(""), field(contextual_encoded[0], "doorGroupId").as_string());
    VWB_EXPECT_EQ(std::string(""), field(contextual_encoded[0], "doorPortalId").as_string());

    NativeValue known_group = remove_field(entry(
        "door", {-3, 2, 9}, 2.7, 0.0, false, false, false, false,
        "", "door-group:known"), "doorPortalId");
    const NativeFeatureDeltaSnapshot known_group_decoded = one_instance_snapshot(known_group);
    const NativeValue &known_group_state = known_group_decoded.player_created_instances()[0].runtime_state;
    VWB_EXPECT_EQ(std::string("door-group:known"), field(known_group_state, "doorGroupId").as_string());
    VWB_EXPECT_EQ(std::string("door:door-group:known"), field(known_group_state, "doorPortalId").as_string());

    NativeValue known_portal = remove_field(entry(
        "door", {-4, 2, 9}, 2.7, 0.0, false, false, false, false,
        "door:external", ""), "doorGroupId");
    const NativeFeatureDeltaSnapshot known_portal_decoded = one_instance_snapshot(known_portal);
    const NativeValue &known_portal_state = known_portal_decoded.player_created_instances()[0].runtime_state;
    VWB_EXPECT_EQ(std::string(""), field(known_portal_state, "doorGroupId").as_string());
    VWB_EXPECT_EQ(std::string("door:external"), field(known_portal_state, "doorPortalId").as_string());
}

VWB_TEST(native_player_blocks_v2_accepts_omitted_slot_and_furnace_defaults) {
    NativeValue sparse_furnace = NativeValue::object({
        {"input", NativeValue::object({{"item", NativeValue::string("ironOre")}})},
    });
    NativeValue::Array sparse_storage = {
        NativeValue::object({{"count", NativeValue::number(2.0)}}),
        NativeValue::object({{"item", NativeValue::string("logs")}}),
        NativeValue::object({}),
    };
    const NativeFeatureDeltaSnapshot chest = one_instance_snapshot(entry(
        "chest", {0, 2, 0}, 2.7, 0.0, false, false, false, false, "", "",
        NativeValue::array(std::move(sparse_storage))));
    const NativeValue::Array &slots = field(chest.player_created_instances()[0].runtime_state, "storageSlots").as_array();
    VWB_EXPECT_EQ(0.0, field(slots[0], "count").as_number());
    VWB_EXPECT_EQ(std::string(""), field(slots[0], "item").as_string());
    VWB_EXPECT_EQ(0.0, field(slots[1], "count").as_number());
    VWB_EXPECT_EQ(std::string(""), field(slots[1], "item").as_string());

    const NativeFeatureDeltaSnapshot furnace = one_instance_snapshot(entry(
        "furnace", {1, 2, 0}, 2.7, 0.0, false, false, false, false, "", "",
        std::nullopt, std::move(sparse_furnace)));
    const NativeValue &state = field(furnace.player_created_instances()[0].runtime_state, "furnaceState");
    VWB_EXPECT_EQ(4.5, field(state, "duration").as_number());
    VWB_EXPECT_EQ(0.0, field(state, "progress").as_number());
    VWB_EXPECT(!field(state, "processing").as_boolean());
    VWB_EXPECT_EQ(std::string(""), field(state, "outputItem").as_string());
    VWB_EXPECT_EQ(0.0, field(field(state, "input"), "count").as_number());
    VWB_EXPECT_EQ(std::string(""), field(field(state, "input"), "item").as_string());
}

VWB_TEST(native_player_blocks_v2_preserves_door_state_and_normalizes_storage_and_furnace_exactly) {
    NativeValue::Array storage = {
        slot("logs", 99.0),
        slot("unknown", 8.0),
        slot("ironOre", -3.0),
    };
    for (int index = 3; index < 14; ++index) storage.push_back(slot("", 0.0));
    const std::vector<NativeValue> raw = {
        entry("door", {5, 7, 2}, 8.125, 1.25, true, true, true, true,
            "door:player:5,7,2", "door-group:player:5,7,2"),
        entry("chest", {-4, 3, 8}, 3.9, 0.0, false, false, false, false, "", "",
            NativeValue::array(std::move(storage))),
        entry("furnace", {0, 2, -9}, 2.7, -0.5, false, false, false, false, "", "",
            std::nullopt, furnace_state(-7.0, -2.0)),
        entry("campfire", {1, 2, -8}, 2.8, 0.25, false, false, false, false, "", "",
            std::nullopt, furnace_state()),
    };
    const NativeFeatureDeltaSnapshot decoded = decode_native_player_blocks_v2(raw, catalog(), {});
    VWB_EXPECT_EQ(4U, decoded.player_created_instances().size());

    const NativeValue &door_state = instance_with_type(decoded, "door").runtime_state;
    VWB_EXPECT(field(door_state, "open").as_boolean());
    VWB_EXPECT(field(door_state, "locked").as_boolean());
    VWB_EXPECT(field(door_state, "jammed").as_boolean());
    VWB_EXPECT(field(door_state, "destroyed").as_boolean());
    VWB_EXPECT_EQ(std::string("door:player:5,7,2"), field(door_state, "doorPortalId").as_string());

    const NativeValue::Array &slots = field(instance_with_type(decoded, "chest").runtime_state, "storageSlots").as_array();
    VWB_EXPECT_EQ(NativePlayerBlocksV2Limits::CHEST_SLOT_COUNT, slots.size());
    VWB_EXPECT_EQ(32.0, field(slots[0], "count").as_number());
    VWB_EXPECT_EQ(std::string("logs"), field(slots[0], "item").as_string());
    VWB_EXPECT_EQ(0.0, field(slots[1], "count").as_number());
    VWB_EXPECT_EQ(std::string(""), field(slots[1], "item").as_string());
    VWB_EXPECT_EQ(0.0, field(slots[2], "count").as_number());

    const NativeValue &furnace = field(instance_with_type(decoded, "furnace").runtime_state, "furnaceState");
    VWB_EXPECT_EQ(0.0, field(furnace, "progress").as_number());
    VWB_EXPECT_EQ(0.1, field(furnace, "duration").as_number());
    VWB_EXPECT(field(furnace, "processing").as_boolean());

    const std::vector<NativeValue> encoded = encode_native_player_blocks_v2(decoded, catalog());
    VWB_EXPECT_EQ(4U, encoded.size());
    // Export has a deterministic z/y/x order independent of Dictionary
    // insertion order, while all first-winner semantics were resolved first.
    VWB_EXPECT_EQ(std::string("furnace"), field(encoded[0], "type").as_string());
    VWB_EXPECT_EQ(std::string("campfire"), field(encoded[1], "type").as_string());
    VWB_EXPECT_EQ(std::string("door"), field(encoded[2], "type").as_string());
    VWB_EXPECT_EQ(std::string("chest"), field(encoded[3], "type").as_string());
    VWB_EXPECT_EQ(decoded, decode_native_player_blocks_v2(encoded, catalog(), {}));
}

VWB_TEST(native_player_blocks_v2_keeps_first_accepted_cell_and_respects_existing_occupancy) {
    const std::vector<NativeValue> raw = {
        entry("stoneBlock", {1, 2, 3}, 11.0),
        entry("door", {1, 2, 3}, 12.0, 0.0, false, false, false, false, "door:a", "group:a"),
        entry("stoneBlock", {4, 5, 6}, 13.0),
        entry("stoneBlock", {7, 8, 9}, 14.0),
    };
    const NativeFeatureDeltaSnapshot decoded = decode_native_player_blocks_v2(raw, catalog(), {{4, 5, 6}, {4, 5, 6}});
    VWB_EXPECT_EQ(2U, decoded.player_created_instances().size());
    VWB_EXPECT_EQ(11.0, instance_with_type(decoded, "stoneBlock").world_y);
    VWB_EXPECT_EQ(CellCoord({7, 8, 9}), decoded.player_created_instances()[1].cell);

    // Even an ignored duplicate is fully validated at the strict native
    // boundary; occupancy cannot hide a malformed save record.
    VWB_EXPECT_THROW(NativePlayerBlocksV2Rejected, decode_native_player_blocks_v2({
        entry("stoneBlock", {1, 2, 3}),
        replace_field(entry("stoneBlock", {1, 2, 3}), "worldY", NativeValue::boolean(true)),
    }, catalog(), {}));
}

VWB_TEST(native_player_blocks_v2_rejects_noncanonical_record_shapes_types_and_coordinates) {
    const NativeValue valid = entry("stoneBlock", {1, 2, 3});
    VWB_EXPECT_THROW(NativePlayerBlocksV2Rejected, decode_native_player_blocks_v2({NativeValue::null()}, catalog(), {}));
    // Exercises the member lookup's end-of-object rejection separately from
    // a missing key whose sorted successor is still present.
    VWB_EXPECT_THROW(NativePlayerBlocksV2Rejected, decode_native_player_blocks_v2({NativeValue::object({})}, catalog(), {}));
    VWB_EXPECT_THROW(NativePlayerBlocksV2Rejected, decode_native_player_blocks_v2({remove_field(valid, "type")}, catalog(), {}));
    VWB_EXPECT_THROW(NativePlayerBlocksV2Rejected, decode_native_player_blocks_v2({remove_field(valid, "cell")}, catalog(), {}));
    VWB_EXPECT_THROW(NativePlayerBlocksV2Rejected, decode_native_player_blocks_v2({add_field(valid, "unknown", NativeValue::null())}, catalog(), {}));
    VWB_EXPECT_THROW(NativePlayerBlocksV2Rejected, decode_native_player_blocks_v2({
        add_field(remove_field(valid, "open"), "opaque", NativeValue::boolean(false)),
    }, catalog(), {}));
    VWB_EXPECT_THROW(NativePlayerBlocksV2Rejected, decode_native_player_blocks_v2({replace_field(valid, "type", NativeValue::number(1.0))}, catalog(), {}));
    VWB_EXPECT_THROW(NativePlayerBlocksV2Rejected, decode_native_player_blocks_v2({replace_field(valid, "type", NativeValue::string("logs"))}, catalog(), {}));
    VWB_EXPECT_THROW(NativePlayerBlocksV2Rejected, decode_native_player_blocks_v2({replace_field(valid, "cell", NativeValue::null())}, catalog(), {}));
    VWB_EXPECT_THROW(NativePlayerBlocksV2Rejected, decode_native_player_blocks_v2({replace_field(valid, "cell", NativeValue::array({NativeValue::number(1.0)}))}, catalog(), {}));
    VWB_EXPECT_THROW(NativePlayerBlocksV2Rejected, decode_native_player_blocks_v2({replace_field(valid, "cell", NativeValue::array({NativeValue::boolean(true), NativeValue::number(2.0), NativeValue::number(3.0)}))}, catalog(), {}));
    VWB_EXPECT_THROW(NativePlayerBlocksV2Rejected, decode_native_player_blocks_v2({replace_field(valid, "cell", NativeValue::array({NativeValue::number(1.5), NativeValue::number(2.0), NativeValue::number(3.0)}))}, catalog(), {}));
    VWB_EXPECT_THROW(NativePlayerBlocksV2Rejected, decode_native_player_blocks_v2({replace_field(valid, "cell", NativeValue::array({NativeValue::number(2147483648.0), NativeValue::number(2.0), NativeValue::number(3.0)}))}, catalog(), {}));
    VWB_EXPECT_THROW(NativePlayerBlocksV2Rejected, decode_native_player_blocks_v2({replace_field(valid, "cell", NativeValue::array({NativeValue::number(9007199254740992.0), NativeValue::number(2.0), NativeValue::number(3.0)}))}, catalog(), {}));
    VWB_EXPECT_THROW(NativePlayerBlocksV2Rejected, decode_native_player_blocks_v2({replace_field(valid, "worldY", NativeValue::boolean(true))}, catalog(), {}));
    VWB_EXPECT_THROW(NativePlayerBlocksV2Rejected, decode_native_player_blocks_v2({replace_field(valid, "facing", NativeValue::string("north"))}, catalog(), {}));
    VWB_EXPECT_THROW(NativePlayerBlocksV2Rejected, decode_native_player_blocks_v2({replace_field(valid, "open", NativeValue::number(0.0))}, catalog(), {}));
    VWB_EXPECT_THROW(NativePlayerBlocksV2Rejected, decode_native_player_blocks_v2({replace_field(valid, "doorPortalId", NativeValue::number(0.0))}, catalog(), {}));
}

VWB_TEST(native_player_blocks_v2_rejects_state_that_the_game_writer_cannot_emit) {
    VWB_EXPECT_THROW(NativePlayerBlocksV2Rejected, one_instance_snapshot(entry("stoneBlock", {0, 0, 0}, 0.0, 0.0, true)));
    VWB_EXPECT_THROW(NativePlayerBlocksV2Rejected, one_instance_snapshot(entry("stoneBlock", {0, 0, 0}, 0.0, 0.0, false, true)));
    VWB_EXPECT_THROW(NativePlayerBlocksV2Rejected, one_instance_snapshot(entry("stoneBlock", {0, 0, 0}, 0.0, 0.0, false, false, true)));
    VWB_EXPECT_THROW(NativePlayerBlocksV2Rejected, one_instance_snapshot(entry("stoneBlock", {0, 0, 0}, 0.0, 0.0, false, false, false, true)));
    VWB_EXPECT_THROW(NativePlayerBlocksV2Rejected, one_instance_snapshot(entry(
        "stoneBlock", {0, 0, 0}, 0.0, 0.0, false, false, false, false, "door:a", "")));
    VWB_EXPECT_THROW(NativePlayerBlocksV2Rejected, one_instance_snapshot(entry(
        "stoneBlock", {0, 0, 0}, 0.0, 0.0, false, false, false, false, "", "group:a")));
    VWB_EXPECT_THROW(NativePlayerBlocksV2Rejected, one_instance_snapshot(entry(
        "stoneBlock", {0, 0, 0}, 0.0, 0.0, false, false, false, false, "", "", NativeValue::array({}))));
    VWB_EXPECT_THROW(NativePlayerBlocksV2Rejected, one_instance_snapshot(entry(
        "chest", {0, 0, 0}, 0.0, 0.0, false, false, false, false, "", "", std::nullopt, furnace_state())));
    VWB_EXPECT_THROW(NativePlayerBlocksV2Rejected, one_instance_snapshot(entry(
        "stoneBlock", {0, 0, 0}, 0.0, 0.0, false, false, false, false, "", "", std::nullopt, furnace_state())));
}

VWB_TEST(native_player_blocks_v2_rejects_malformed_slot_and_furnace_values_without_variant_coercion) {
    auto chest_with = [](NativeValue storage) {
        return entry("chest", {0, 0, 0}, 0.0, 0.0, false, false, false, false, "", "", std::move(storage));
    };
    VWB_EXPECT_THROW(NativePlayerBlocksV2Rejected, one_instance_snapshot(chest_with(NativeValue::null())));
    VWB_EXPECT_THROW(NativePlayerBlocksV2Rejected, one_instance_snapshot(chest_with(NativeValue::array({NativeValue::null()}))));
    VWB_EXPECT_THROW(NativePlayerBlocksV2Rejected, one_instance_snapshot(chest_with(NativeValue::array({add_field(slot("logs", 1.0), "x", NativeValue::null())}))));
    VWB_EXPECT_THROW(NativePlayerBlocksV2Rejected, one_instance_snapshot(chest_with(NativeValue::array({replace_field(slot("logs", 1.0), "item", NativeValue::number(1.0))}))));
    VWB_EXPECT_THROW(NativePlayerBlocksV2Rejected, one_instance_snapshot(chest_with(NativeValue::array({replace_field(slot("logs", 1.0), "count", NativeValue::string("1"))}))));
    VWB_EXPECT_THROW(NativePlayerBlocksV2Rejected, one_instance_snapshot(chest_with(NativeValue::array({slot("logs", 1.5)}))));
    VWB_EXPECT_THROW(NativePlayerBlocksV2Rejected, one_instance_snapshot(chest_with(NativeValue::array({slot("logs", -9007199254740992.0)}))));

    auto furnace_with = [](NativeValue state) {
        return entry("furnace", {0, 0, 0}, 0.0, 0.0, false, false, false, false, "", "", std::nullopt, std::move(state));
    };
    VWB_EXPECT_THROW(NativePlayerBlocksV2Rejected, one_instance_snapshot(furnace_with(NativeValue::null())));
    VWB_EXPECT_THROW(NativePlayerBlocksV2Rejected, one_instance_snapshot(furnace_with(add_field(furnace_state(), "x", NativeValue::null()))));
    VWB_EXPECT_THROW(NativePlayerBlocksV2Rejected, one_instance_snapshot(furnace_with(replace_field(furnace_state(), "processing", NativeValue::number(1.0)))));
    VWB_EXPECT_THROW(NativePlayerBlocksV2Rejected, one_instance_snapshot(furnace_with(replace_field(furnace_state(), "progress", NativeValue::string("2")))));
    VWB_EXPECT_THROW(NativePlayerBlocksV2Rejected, one_instance_snapshot(furnace_with(replace_field(furnace_state(), "duration", NativeValue::boolean(true)))));
    VWB_EXPECT_THROW(NativePlayerBlocksV2Rejected, one_instance_snapshot(furnace_with(replace_field(furnace_state(), "outputItem", NativeValue::number(1.0)))));
}

VWB_TEST(native_player_blocks_v2_encode_fails_closed_for_other_feature_domains_and_native_ids) {
    const NativeFeatureDeltaSnapshot imported = one_instance_snapshot(entry("stoneBlock", {1, 2, 3}));
    NativePlayerCreatedInstance changed = imported.player_created_instances()[0];
    changed.instance_id = "native/player-block/1";
    VWB_EXPECT_THROW(NativePlayerBlocksV2Rejected, encode_native_player_blocks_v2(
        NativeFeatureDeltaSnapshot::create({}, {changed}), catalog()));

    changed = imported.player_created_instances()[0];
    changed.block_id = NativeBlockIdentity::create("logs");
    VWB_EXPECT_THROW(NativePlayerBlocksV2Rejected, encode_native_player_blocks_v2(
        NativeFeatureDeltaSnapshot::create({}, {changed}), catalog()));

    changed = imported.player_created_instances()[0];
    changed.runtime_state = remove_field(changed.runtime_state, "open");
    VWB_EXPECT_THROW(NativePlayerBlocksV2Rejected, encode_native_player_blocks_v2(
        NativeFeatureDeltaSnapshot::create({}, {changed}), catalog()));

    // Keep the object size equal to the strict expected shape so key-by-key
    // validation, rather than the earlier size guard, rejects the unknown key.
    changed = imported.player_created_instances()[0];
    changed.runtime_state = add_field(
        remove_field(changed.runtime_state, "open"), "opaque", NativeValue::boolean(false));
    VWB_EXPECT_THROW(NativePlayerBlocksV2Rejected, encode_native_player_blocks_v2(
        NativeFeatureDeltaSnapshot::create({}, {changed}), catalog()));

    const NativeFeatureDeltaSnapshot tombstones = NativeFeatureDeltaSnapshot::create({{"removed"}}, {});
    VWB_EXPECT_THROW(NativePlayerBlocksV2Rejected, encode_native_player_blocks_v2(tombstones, catalog()));
}

VWB_TEST(native_player_blocks_v2_enforces_explicit_outer_capacity_before_parsing) {
    std::vector<NativeValue> too_many(
        NativePlayerBlocksV2Limits::MAX_BLOCKS + 1U, NativeValue::null());
    VWB_EXPECT_THROW(NativePlayerBlocksV2Rejected, decode_native_player_blocks_v2(too_many, catalog(), {}));
}
