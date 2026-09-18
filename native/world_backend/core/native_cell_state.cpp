#include "native_cell_state.hpp"

#include <algorithm>
#include <cmath>
#include <utility>

namespace voxel::world_backend {
namespace {

bool valid_material(const TerrainMaterialId material) noexcept {
    return static_cast<std::uint8_t>(material) <= static_cast<std::uint8_t>(TerrainMaterialId::lava);
}

bool valid_biome(const TerrainBiomeId biome) noexcept {
    return static_cast<std::uint8_t>(biome) <= static_cast<std::uint8_t>(TerrainBiomeId::alpine);
}

bool valid_fluid(const TerrainFluidId fluid) noexcept {
    return static_cast<std::uint8_t>(fluid) <= static_cast<std::uint8_t>(TerrainFluidId::lava);
}

bool metadata_less(const NativeCellMetadataEntry &left, const NativeCellMetadataEntry &right) noexcept {
    return left.key < right.key;
}

void validate_metadata(const std::vector<NativeCellMetadataEntry> &metadata) {
    std::vector<NativeCellMetadataEntry> sorted = metadata;
    std::sort(sorted.begin(), sorted.end(), metadata_less);
    for (std::size_t index = 0; index < sorted.size(); ++index) {
        if (sorted[index].key.empty() || (index > 0 && sorted[index - 1].key == sorted[index].key)) {
            throw NativeCellStateRejected();
        }
    }
}

} // namespace

bool NativeCellLight::operator==(const NativeCellLight &other) const noexcept {
    return sky == other.sky && block == other.block;
}

bool NativeCellMetadataEntry::operator==(const NativeCellMetadataEntry &other) const noexcept {
    return key == other.key && value == other.value;
}

bool NativeCellState::operator==(const NativeCellState &other) const noexcept {
    return cell == other.cell && section == other.section && local_cell == other.local_cell
        && material == other.material && biome == other.biome && solid == other.solid && density == other.density
        && fluid == other.fluid && light == other.light && metadata == other.metadata
        && generated == other.generated && edited == other.edited;
}

NativeCellStateRejected::NativeCellStateRejected()
    : std::invalid_argument("invalid native cell state") {}

NativeCellState make_native_cell_state(const NativeCellStateInput &input, const NativeCellStateNamespace name_space) {
    if (!std::isfinite(input.density) || input.generated == input.edited || !valid_material(input.material)
        || !valid_biome(input.biome) || !valid_fluid(input.fluid) || input.light.sky > 15 || input.light.block > 15) {
        throw NativeCellStateRejected();
    }
    if (input.solid != (input.density >= 0.0) || (input.solid && input.fluid != TerrainFluidId::none)) {
        throw NativeCellStateRejected();
    }
    if ((input.fluid == TerrainFluidId::water && input.material != TerrainMaterialId::water)
        || (input.fluid == TerrainFluidId::lava && input.material != TerrainMaterialId::lava)
        || (input.fluid == TerrainFluidId::none && (input.material == TerrainMaterialId::water || input.material == TerrainMaterialId::lava))
        // Water/lava are already rejected above for either fluid value; air is
        // the only remaining nonsolid material a solid state could carry.
        || (input.solid && input.material == TerrainMaterialId::air)) {
        throw NativeCellStateRejected();
    }
    // Both edit namespaces are transient in memory, but only durable terrain
    // appears in a save. Generated values may not be introduced as overlays.
    if (name_space != NativeCellStateNamespace::durable_terrain && name_space != NativeCellStateNamespace::scene_overlay) {
        throw NativeCellStateRejected();
    }
    // `generated != edited` was validated above, so a non-generated overlay
    // is necessarily edited; testing edited again would be unreachable.
    if (name_space == NativeCellStateNamespace::scene_overlay && input.generated) {
        throw NativeCellStateRejected();
    }
    validate_metadata(input.metadata);
    const auto address = split_cell(input.cell, NativeCellState::SECTION_SIZE);
    NativeCellState result;
    result.cell = input.cell;
    result.section = address->section;
    result.local_cell = address->local;
    result.material = input.material;
    result.biome = input.biome;
    result.solid = input.solid;
    result.density = input.density;
    result.fluid = input.fluid;
    result.light = input.light;
    result.metadata = input.metadata;
    std::sort(result.metadata.begin(), result.metadata.end(), metadata_less);
    result.generated = input.generated;
    result.edited = input.edited;
    return result;
}

std::size_t native_cell_state_section_index(const NativeCellState &state) {
    const auto address = split_cell(state.cell, NativeCellState::SECTION_SIZE);
    // SECTION_SIZE is a positive compile-time constant, so split_cell cannot
    // fail here. The contract check is that callers cannot forge its address.
    if (!(address->section == state.section) || !(address->local == state.local_cell)) {
        throw NativeCellStateRejected();
    }
    const std::size_t size = static_cast<std::size_t>(NativeCellState::SECTION_SIZE);
    return static_cast<std::size_t>(state.local_cell.x) + size * (
        static_cast<std::size_t>(state.local_cell.y) + size * static_cast<std::size_t>(state.local_cell.z));
}

NativeCellStatePersistencePolicy native_cell_state_policy(const NativeCellStateNamespace name_space) noexcept {
    if (name_space == NativeCellStateNamespace::scene_overlay) {
        return {name_space, false, false, false};
    }
    if (name_space == NativeCellStateNamespace::durable_terrain) {
        return {name_space, true, true, true};
    }
    // Unknown ownership is nonpersistent and non-rendering; it must never
    // gain durable-terrain authority merely because an enum widened.
    return {name_space, false, false, false};
}

bool native_cell_state_v2_save_less(const NativeCellState &left, const NativeCellState &right) noexcept {
    if (left.cell.z != right.cell.z) return left.cell.z < right.cell.z;
    if (left.cell.y != right.cell.y) return left.cell.y < right.cell.y;
    return left.cell.x < right.cell.x;
}

std::vector<NativeCellState> sort_native_cell_states_v2_for_save(std::vector<NativeCellState> states) {
    std::sort(states.begin(), states.end(), native_cell_state_v2_save_less);
    for (std::size_t index = 1; index < states.size(); ++index) {
        if (states[index - 1].cell == states[index].cell) {
            throw NativeCellStateRejected();
        }
    }
    return states;
}

} // namespace voxel::world_backend
