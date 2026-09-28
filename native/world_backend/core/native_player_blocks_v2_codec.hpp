#pragma once

#include "native_feature_delta.hpp"
#include "native_value.hpp"

#include <cstddef>
#include <cstdint>
#include <optional>
#include <stdexcept>
#include <string>
#include <vector>

namespace voxel::world_backend {

// MainSaveState's v2 `blocks` field is an outer save-envelope array rather
// than a versioned object of its own.  The adapter therefore marshals each
// entry separately.  This keeps a large, explicitly bounded block list from
// inheriting NativeValue's much smaller general-purpose recursive-container
// limit.
struct NativePlayerBlocksV2Limits final {
    static constexpr std::size_t MAX_BLOCKS = NativeFeatureDeltaLimits::MAX_PLAYER_CREATED_INSTANCES;
    static constexpr std::size_t MAX_CATALOG_ITEMS = 4096U;
    static constexpr std::size_t CHEST_SLOT_COUNT = 12U;
};

class NativePlayerBlocksV2Rejected final : public std::invalid_argument {
public:
    NativePlayerBlocksV2Rejected();
};

struct NativePlayerBlocksV2ItemSpec final {
    std::string item_id;
    std::uint32_t stack_max = 0U;
    bool placeable = false;
};

// ItemCatalog remains the gameplay authority.  The future Godot adapter will
// freeze its IDs, stack maxima and placeability flags into this immutable
// value before importing a save.  Keeping that policy as input avoids a
// second hard-coded native item catalogue that could drift during migration.
class NativePlayerBlocksV2Catalog final {
public:
    static NativePlayerBlocksV2Catalog create(std::vector<NativePlayerBlocksV2ItemSpec> items);

    bool is_placeable(const std::string &item_id) const noexcept;
    std::optional<std::uint32_t> stack_max(const std::string &item_id) const noexcept;
    const std::vector<NativePlayerBlocksV2ItemSpec> &items() const noexcept;

private:
    explicit NativePlayerBlocksV2Catalog(std::vector<NativePlayerBlocksV2ItemSpec> items);

    std::vector<NativePlayerBlocksV2ItemSpec> items_;
};

// Imported v2 blocks have no persisted instance ID.  This reserved namespace
// derives an injective, stable internal identity from the cell occupancy key.
// It is deliberately distinct from IDs allocated for newly native-created
// instances, whose counter/UUID policy belongs to the later runtime adapter.
std::string native_player_block_v2_instance_id(const CellCoord &cell);

// `already_occupied_cells` mirrors the generated/live entries that remain in
// MainSaveState.blocks after clear_player_blocks().  Input order is retained
// while resolving occupancy: the first valid entry for a free cell wins, and
// later entries (or entries colliding with an existing cell) are ignored.
// Decode accepts the same omitted optional fields as MainSaveState restore and
// normalizes their defaults.  Type and cell remain required identity fields;
// present fields and unknown keys are still validated strictly.
NativeFeatureDeltaSnapshot decode_native_player_blocks_v2(
    const std::vector<NativeValue> &entries,
    const NativePlayerBlocksV2Catalog &catalog,
    const std::vector<CellCoord> &already_occupied_cells);

// Only instances in the reserved imported-v2 cell namespace are exportable
// through the unchanged v2 schema.  New-native identity migration is a later
// adapter concern and fails closed here rather than losing identity silently.
std::vector<NativeValue> encode_native_player_blocks_v2(
    const NativeFeatureDeltaSnapshot &snapshot,
    const NativePlayerBlocksV2Catalog &catalog);

} // namespace voxel::world_backend
