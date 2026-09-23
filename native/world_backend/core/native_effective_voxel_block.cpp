#include "native_effective_voxel_block.hpp"

#include <algorithm>
#include <cmath>
#include <limits>
#include <stdexcept>

namespace voxel::world_backend {
namespace {

constexpr std::int32_t MAX_SIDE = 32;

std::int16_t sdf16_from_voxel_float(const float value) {
    // Voxel Tools v1.6x: real_to_raw_voxel(DEPTH_16_BIT) calls
    // snorm_to_s16(value * 0.002f), which truncates toward zero.
    const float normalized = std::clamp(value * 0.002F, -1.0F, 1.0F);
    return static_cast<std::int16_t>(normalized * 32767.0F);
}

std::int32_t checked_coordinate(const std::int32_t origin, const std::int32_t offset,
                                const std::int64_t scale) {
    const std::int64_t coordinate = static_cast<std::int64_t>(origin)
        + static_cast<std::int64_t>(offset) * scale;
    // offset is admitted nonnegative and scale is positive, so only upper
    // overflow can occur from an int32 origin.
    if (coordinate > std::numeric_limits<std::int32_t>::max())
        throw std::out_of_range("native voxel block coordinate overflows int32");
    return static_cast<std::int32_t>(coordinate);
}

} // namespace

std::uint8_t native_voxel_material_channel_id(const TerrainMaterialId material) {
    const auto id = static_cast<std::uint8_t>(material);
    // VoxelTerrainGenerator.MATERIAL_IDS has no lava entry; its lookup defaults
    // to stone, not air and not the persisted typed-state lava ID 16.
    if (material == TerrainMaterialId::lava) return 3U;
    if (id > 15U) throw std::invalid_argument("native voxel block material is invalid");
    return id;
}

NativeEffectiveVoxelBlock encode_native_effective_voxel_block(
    const NativeEffectiveTerrainSource &source,
    const NativeEffectiveVoxelBlockRequest &request) {
    const CellCoord size = request.size;
    if (size.x <= 0 || size.y <= 0 || size.z <= 0
        || size.x > MAX_SIDE || size.y > MAX_SIDE || size.z > MAX_SIDE
        || request.lod > 24U)
        throw std::invalid_argument("native voxel block dimensions or LOD are invalid");
    const std::size_t count = static_cast<std::size_t>(size.x) * size.y * size.z;
    // Each admitted side is at most 32, bounding count to 32^3.
    const std::int64_t scale = std::int64_t{1} << request.lod;
    const CellCoord last{
        checked_coordinate(request.origin.x, size.x - 1, scale),
        checked_coordinate(request.origin.y, size.y - 1, scale),
        checked_coordinate(request.origin.z, size.z - 1, scale),
    };
    const auto &pin = source.pin();
    const auto &page = pin.primary_terrain_shaping();
    if (!page.owns_cell(request.origin.x, request.origin.z)
        || !page.owns_cell(last.x, last.z))
        throw std::out_of_range("native voxel block crosses its primary shaping page");

    NativeEffectiveVoxelBlock result;
    result.origin = request.origin;
    result.size = size;
    result.lod = request.lod;
    result.pin_identity = pin.physical_content_identity();
    result.terrain_delta_revision = pin.terrain_delta_revision();
    result.shaping_registry_revision = pin.shaping_registry_revision();
    result.sdf16_le.resize(count * 2U);
    result.indices8.resize(count);
    result.data5_8.resize(count);
    const double cell = pin.definition().constants().cell_size_meters;
    const double voxel_scale = static_cast<double>(scale);
    for (std::int32_t z = 0; z < size.z; ++z) {
        const std::int32_t cz = checked_coordinate(request.origin.z, z, scale);
        for (std::int32_t x = 0; x < size.x; ++x) {
            const std::int32_t cx = checked_coordinate(request.origin.x, x, scale);
            for (std::int32_t y = 0; y < size.y; ++y) {
                const std::int32_t cy = checked_coordinate(request.origin.y, y, scale);
                const NativeEffectiveNumericFacts facts = source.sample_lattice_numeric(
                    {{cx, cy, cz}, WorldQueryIntent::terrain_mesh});
                // GDScript divides in real_t precision before VoxelBuffer's
                // float channel conversion. Rounding density/CELL early can
                // cross an SDF16 quantization boundary.
                const double density = facts.density / voxel_scale;
                const std::int16_t sdf = sdf16_from_voxel_float(
                    static_cast<float>(-density / cell));
                const auto bits = static_cast<std::uint16_t>(sdf);
                const std::size_t index = static_cast<std::size_t>(y)
                    + static_cast<std::size_t>(size.y) * (static_cast<std::size_t>(x)
                    + static_cast<std::size_t>(size.x) * static_cast<std::size_t>(z));
                result.sdf16_le[2U * index] = static_cast<std::uint8_t>(bits & 0xffU);
                result.sdf16_le[2U * index + 1U] = static_cast<std::uint8_t>(bits >> 8U);
                const std::uint8_t material = native_voxel_material_channel_id(facts.material);
                result.indices8[index] = material;
                result.data5_8[index] = material;
            }
        }
    }
    return result;
}

} // namespace voxel::world_backend
