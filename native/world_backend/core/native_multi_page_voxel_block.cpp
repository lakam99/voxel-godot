#include "native_multi_page_voxel_block.hpp"

#include <algorithm>
#include <limits>
#include <stdexcept>
#include <utility>

namespace voxel::world_backend {
namespace {

constexpr std::int32_t PAGE_CELLS = NativeTerrainShapingSnapshot::PAGE_CELLS;

struct AxisSpan {
    NativeTerrainPageKey page;
    std::int32_t begin = 0;
    std::int32_t count = 0;
};

bool page_less(const NativeTerrainPageKey a, const NativeTerrainPageKey b) noexcept {
    return a.z < b.z || (a.z == b.z && a.x < b.x);
}

std::int32_t coordinate(const std::int32_t origin, const std::int32_t index,
                        const std::int64_t scale) {
    const std::int64_t value = static_cast<std::int64_t>(origin) + index * scale;
    if (value > std::numeric_limits<std::int32_t>::max())
        throw std::out_of_range("native multi-page voxel coordinate overflows int32");
    return static_cast<std::int32_t>(value);
}

std::int32_t page_axis(const std::int32_t cell) noexcept {
    const std::int32_t quotient = cell / PAGE_CELLS;
    return quotient - static_cast<std::int32_t>(cell % PAGE_CELLS < 0);
}

std::vector<AxisSpan> spans(const std::int32_t origin, const std::int32_t size,
                            const std::int64_t scale, const bool x_axis) {
    std::vector<AxisSpan> result;
    for (std::int32_t index = 0; index < size; ++index) {
        const std::int32_t page = page_axis(coordinate(origin, index, scale));
        if (result.empty() || (x_axis ? result.back().page.x : result.back().page.z) != page) {
            result.push_back({x_axis ? NativeTerrainPageKey{page, 0} : NativeTerrainPageKey{0, page}, index, 1});
        } else {
            ++result.back().count;
        }
    }
    return result;
}

void append_u32(std::vector<std::uint8_t> &bytes, const std::uint32_t value) {
    for (unsigned shift = 0; shift < 32; shift += 8) bytes.push_back(static_cast<std::uint8_t>(value >> shift));
}
void append_u64(std::vector<std::uint8_t> &bytes, const std::uint64_t value) {
    for (unsigned shift = 0; shift < 64; shift += 8) bytes.push_back(static_cast<std::uint8_t>(value >> shift));
}

} // namespace

NativeEffectiveVoxelBlock encode_native_multi_page_voxel_block(
    const WorldSourceDefinition &definition, const WorldDeltaPinnedSnapshot &deltas,
    const std::vector<NativeTerrainShapingPagePin> &shaping_pages,
    const NativeEffectiveVoxelBlockRequest &request) {
    const CellCoord size = request.size;
    if (size.x <= 0 || size.y <= 0 || size.z <= 0
        || size.x > 32 || size.y > 32 || size.z > 32 || request.lod > 24U)
        throw std::invalid_argument("native multi-page voxel block dimensions or LOD are invalid");
    const std::int64_t scale = std::int64_t{1} << request.lod;
    (void)coordinate(request.origin.y, size.y - 1, scale);
    const auto xs = spans(request.origin.x, size.x, scale, true);
    const auto zs = spans(request.origin.z, size.z, scale, false);
    std::vector<NativeTerrainPageKey> primaries;
    std::vector<NativeTerrainPageKey> required;
    // The admitted 32x32 block limits the pre-dedup work to at most 1024
    // primaries times the bounded dependency set for one primary. There is no
    // additional capacity rejection that could strand a valid Voxel Tools LOD.
    for (const auto &z : zs) for (const auto &x : xs) {
        const NativeTerrainPageKey primary{x.page.x, z.page.z};
        primaries.push_back(primary);
        const auto dependencies = world_effective_shaping_dependencies(definition, primary);
        required.insert(required.end(), dependencies.begin(), dependencies.end());
    }
    std::sort(required.begin(), required.end(), page_less);
    required.erase(std::unique(required.begin(), required.end()), required.end());
    if (shaping_pages.size() != required.size())
        throw std::invalid_argument("native multi-page voxel shaping dependency set is incomplete");
    std::vector<const NativeTerrainShapingPagePin *> supplied;
    supplied.reserve(required.size());
    for (const auto &page : shaping_pages) supplied.push_back(&page);
    std::sort(supplied.begin(), supplied.end(), [](const auto *a, const auto *b) {
        return page_less(a->page_key(), b->page_key());
    });
    for (std::size_t index = 0; index < required.size(); ++index) {
        const auto &page = *supplied[index];
        if (!(page.page_key() == required[index])
            || page.readiness() != NativeTerrainShapingPageReadiness::ready
            || !(page.snapshot()->definition().physical_content_identity()
                == definition.physical_content_identity()))
            throw std::invalid_argument("native multi-page voxel shaping dependency is invalid");
        if (index > 0 && (page.registry_revision() != supplied[0]->registry_revision()
            || !(page.registry_content_identity() == supplied[0]->registry_content_identity())))
            throw std::invalid_argument("native multi-page voxel shaping registry snapshots are mixed");
    }

    NativeEffectiveVoxelBlock result;
    result.origin = request.origin; result.size = size; result.lod = request.lod;
    result.terrain_delta_revision = deltas.revision();
    result.shaping_registry_revision = supplied[0]->registry_revision();
    const std::size_t count = static_cast<std::size_t>(size.x) * size.y * size.z;
    result.sdf16_le.resize(count * 2U);
    result.indices8.resize(count);
    result.data5_8.resize(count);
    std::vector<std::uint8_t> identity;
    identity.insert(identity.end(), {'v','w','b','-','m','u','l','t','i','-','p','a','g','e','-','v','1'});
    const auto &source_digest = definition.physical_content_identity().digest;
    identity.insert(identity.end(), source_digest.begin(), source_digest.end());
    const auto &delta_digest = deltas.content_digest();
    identity.insert(identity.end(), delta_digest.begin(), delta_digest.end());
    append_u64(identity, deltas.revision());
    append_u64(identity, supplied[0]->registry_revision());
    const auto &registry_digest = supplied[0]->registry_content_identity().digest;
    identity.insert(identity.end(), registry_digest.begin(), registry_digest.end());
    append_u32(identity, static_cast<std::uint32_t>(request.origin.x));
    append_u32(identity, static_cast<std::uint32_t>(request.origin.y));
    append_u32(identity, static_cast<std::uint32_t>(request.origin.z));
    append_u32(identity, static_cast<std::uint32_t>(size.x));
    append_u32(identity, static_cast<std::uint32_t>(size.y));
    append_u32(identity, static_cast<std::uint32_t>(size.z));
    append_u32(identity, request.lod);
    append_u32(identity, static_cast<std::uint32_t>(primaries.size()));
    std::vector<WorldPhysicalContentIdentity> content_pages;
    content_pages.reserve(primaries.size());

    for (const auto &z : zs) for (const auto &x : xs) {
        const NativeTerrainPageKey primary{x.page.x, z.page.z};
        const auto dependencies = world_effective_shaping_dependencies(definition, primary);
        std::vector<NativeTerrainShapingPagePin> local;
        local.reserve(dependencies.size());
        for (const auto dependency : dependencies) {
            const auto found = std::lower_bound(supplied.begin(), supplied.end(), dependency,
                [](const auto *page, const NativeTerrainPageKey key) {
                    return page_less(page->page_key(), key);
                });
            local.push_back(**found);
        }
        WorldSourcePin pin(definition, deltas, primary, local);
        content_pages.push_back(pin.physical_content_identity());
        identity.insert(identity.end(), pin.physical_content_identity().digest.begin(),
            pin.physical_content_identity().digest.end());
        const NativeEffectiveTerrainSource source(std::move(pin));
        const CellCoord sub_origin{
            coordinate(request.origin.x, x.begin, scale), request.origin.y,
            coordinate(request.origin.z, z.begin, scale)};
        const NativeEffectiveVoxelBlock sub = encode_native_effective_voxel_block(
            source, {sub_origin, {x.count, size.y, z.count}, request.lod});
        for (std::int32_t sz = 0; sz < z.count; ++sz)
            for (std::int32_t sx = 0; sx < x.count; ++sx)
                for (std::int32_t y = 0; y < size.y; ++y) {
                    const std::size_t from = static_cast<std::size_t>(y)
                        + static_cast<std::size_t>(size.y) * (static_cast<std::size_t>(sx)
                        + static_cast<std::size_t>(x.count) * static_cast<std::size_t>(sz));
                    const std::size_t to = static_cast<std::size_t>(y)
                        + static_cast<std::size_t>(size.y) * (static_cast<std::size_t>(x.begin + sx)
                        + static_cast<std::size_t>(size.x) * static_cast<std::size_t>(z.begin + sz));
                    result.sdf16_le[2U * to] = sub.sdf16_le[2U * from];
                    result.sdf16_le[2U * to + 1U] = sub.sdf16_le[2U * from + 1U];
                    result.indices8[to] = sub.indices8[from];
                    result.data5_8[to] = sub.data5_8[from];
                }
    }
    result.pin_identity = {sha256(identity)};
    result.block_content_identity = native_voxel_block_content_identity(
        definition.physical_content_identity(), request, content_pages);
    return result;
}

} // namespace voxel::world_backend
