#include "native_effective_terrain_batch.hpp"

#include <string>
#include <utility>

namespace voxel::world_backend {
namespace {

const char *reject_message(const NativeEffectiveTerrainBatchRejectReason reason) noexcept {
    switch (reason) {
    case NativeEffectiveTerrainBatchRejectReason::surface_column_limit:
        return "native effective terrain surface-column batch limit exceeded";
    case NativeEffectiveTerrainBatchRejectReason::cell_center_limit:
        return "native effective terrain cell-center batch limit exceeded";
    case NativeEffectiveTerrainBatchRejectReason::lattice_numeric_limit:
        return "native effective terrain lattice-numeric batch limit exceeded";
    case NativeEffectiveTerrainBatchRejectReason::world_numeric_limit:
        return "native effective terrain world-numeric batch limit exceeded";
    case NativeEffectiveTerrainBatchRejectReason::surface_projection_numeric_limit:
        return "native effective terrain surface-projection batch limit exceeded";
    case NativeEffectiveTerrainBatchRejectReason::total_limit:
        return "native effective terrain total batch limit exceeded";
    case NativeEffectiveTerrainBatchRejectReason::prepared_payload_limit:
        return "native effective terrain prepared-payload batch limit exceeded";
    }
    return "native effective terrain batch rejected";
}

void require_channel(
    const std::size_t size, const std::size_t limit,
    const NativeEffectiveTerrainBatchRejectReason reason) {
    if (size > limit) throw NativeEffectiveTerrainBatchRejected(reason);
}

void add_to_total(const std::size_t size, const std::size_t limit, std::size_t &total) {
    // A successful prior step maintains total <= limit. Subtraction therefore
    // cannot underflow, and this comparison cannot wrap even with SIZE_MAX.
    if (size > limit - total)
        throw NativeEffectiveTerrainBatchRejected(
            NativeEffectiveTerrainBatchRejectReason::total_limit);
    total += size;
}

void add_payload_bytes(const std::size_t bytes, const std::size_t limit, std::size_t &total) {
    if (bytes > limit - total)
        throw NativeEffectiveTerrainBatchRejected(
            NativeEffectiveTerrainBatchRejectReason::prepared_payload_limit);
    total += bytes;
}

void add_static_records(
    const std::size_t count, const std::size_t bytes_per_record,
    const std::size_t limit, std::size_t &total) {
    if (count > (limit - total) / bytes_per_record)
        throw NativeEffectiveTerrainBatchRejected(
            NativeEffectiveTerrainBatchRejectReason::prepared_payload_limit);
    total += count * bytes_per_record;
}

void add_native_value_canonical_payload(
    const NativeValue &value, const std::size_t limit, std::size_t &total) {
    // Match NativeValue's NV1 value encoding without materializing a second
    // byte vector. Each addition is checked before descending further, so a
    // small remaining batch allowance bounds the work used to reject a large
    // already-pinned metadata tree.
    add_payload_bytes(1U, limit, total); // tag
    const NativeValueKind kind = value.kind();
    if (kind == NativeValueKind::null_value || kind == NativeValueKind::boolean)
        return;
    if (kind == NativeValueKind::number) {
        add_payload_bytes(8U, limit, total);
        return;
    }
    if (kind == NativeValueKind::string) {
        add_payload_bytes(4U, limit, total);
        add_payload_bytes(value.as_string().size(), limit, total);
        return;
    }
    if (kind == NativeValueKind::array) {
        add_payload_bytes(4U, limit, total);
        for (const NativeValue &child : value.as_array())
            add_native_value_canonical_payload(child, limit, total);
        return;
    }
    // NativeValue's private variant has exactly six alternatives. Public
    // factories admit the five cases above plus object; a valueless value is
    // rejected by kind() before this point.
    add_payload_bytes(4U, limit, total);
    for (const auto &entry : value.as_object()) {
        add_payload_bytes(4U, limit, total);
        add_payload_bytes(entry.first.size(), limit, total);
        add_native_value_canonical_payload(entry.second, limit, total);
    }
}

void add_edited_state_payload(
    const NativeCellState &state, const std::size_t limit, std::size_t &total) {
    // Logical duplicate-state bytes: 54 fixed scalar/discriminator bytes,
    // canonical NV1 metadata bytes, then raw UTF-8 bytes retained by the two
    // optional strings. C++ padding, vector/string capacity, and allocator
    // bookkeeping are deliberately excluded.
    constexpr std::size_t fixed_state_bytes = 54;
    add_payload_bytes(fixed_state_bytes, limit, total);
    add_payload_bytes(3U, limit, total); // NV1 marker
    add_native_value_canonical_payload(state.metadata, limit, total);
    if (state.block_id)
        add_payload_bytes(state.block_id->value().size(), limit, total);
    if (state.edit_reason)
        add_payload_bytes(state.edit_reason->size(), limit, total);
}

void validate_batch_query(const NativeEffectiveWorldNumericBatchQuery &query) {
    if (query.semantic_revision != NativeEffectiveWorldNumericBatchQuery::SEMANTIC_REVISION
        || query.intent != WorldQueryIntent::terrain_mesh)
        throw std::invalid_argument("native effective world-numeric batch query is invalid");
}

void validate_batch_query(const NativeEffectiveSurfaceProjectionNumericBatchQuery &query) {
    if (query.semantic_revision
            != NativeEffectiveSurfaceProjectionNumericBatchQuery::SEMANTIC_REVISION
        || query.intent != WorldQueryIntent::terrain_collision)
        throw std::invalid_argument("native effective surface-projection batch query is invalid");
}

std::optional<NativeCellState> edited_sparse_state(
    const WorldSourcePin &pin, const CellCoord cell, const bool edited) {
    if (!edited) return std::nullopt;
    return pin.deltas().effective_typed_cell_at(cell);
}

} // namespace

NativeEffectiveTerrainBatchQueryKind native_effective_batch_query_kind(
    const NativeEffectiveWorldNumericBatchQuery &) noexcept {
    return NativeEffectiveTerrainBatchQueryKind::arbitrary_world_numeric;
}

NativeEffectiveTerrainBatchQueryKind native_effective_batch_query_kind(
    const NativeEffectiveSurfaceProjectionNumericBatchQuery &) noexcept {
    return NativeEffectiveTerrainBatchQueryKind::surface_projection_numeric;
}

NativeEffectiveTerrainBatchRejected::NativeEffectiveTerrainBatchRejected(
    const NativeEffectiveTerrainBatchRejectReason reason)
    : std::length_error(reject_message(reason)), reason_(reason) {}

NativeEffectiveTerrainBatchRejectReason NativeEffectiveTerrainBatchRejected::reason() const noexcept {
    return reason_;
}

NativeEffectiveTerrainBatch::NativeEffectiveTerrainBatch(
    WorldSourcePin pin, NativeEffectiveTerrainBatchLimits limits)
    : source_(std::move(pin)), limits_(limits) {}

const WorldSourcePin &NativeEffectiveTerrainBatch::pin() const noexcept { return source_.pin(); }

const NativeEffectiveTerrainBatchLimits &NativeEffectiveTerrainBatch::limits() const noexcept {
    return limits_;
}

NativeEffectiveTerrainBatchResult NativeEffectiveTerrainBatch::execute(
    const NativeEffectiveTerrainBatchRequest &request) const {
    require_channel(request.surface_columns.size(), limits_.max_surface_columns,
        NativeEffectiveTerrainBatchRejectReason::surface_column_limit);
    require_channel(request.cell_centers.size(), limits_.max_cell_centers,
        NativeEffectiveTerrainBatchRejectReason::cell_center_limit);
    require_channel(request.lattice_numeric.size(), limits_.max_lattice_numeric,
        NativeEffectiveTerrainBatchRejectReason::lattice_numeric_limit);
    require_channel(request.world_numeric.size(), limits_.max_world_numeric,
        NativeEffectiveTerrainBatchRejectReason::world_numeric_limit);
    require_channel(request.surface_projection_numeric.size(),
        limits_.max_surface_projection_numeric,
        NativeEffectiveTerrainBatchRejectReason::surface_projection_numeric_limit);

    std::size_t total = 0;
    add_to_total(request.surface_columns.size(), limits_.max_total_queries, total);
    add_to_total(request.cell_centers.size(), limits_.max_total_queries, total);
    add_to_total(request.lattice_numeric.size(), limits_.max_total_queries, total);
    add_to_total(request.world_numeric.size(), limits_.max_total_queries, total);
    add_to_total(request.surface_projection_numeric.size(), limits_.max_total_queries, total);

    // Fixed logical record bytes (no C++ padding/capacity): surface 34,
    // cell-center 42, lattice 58, arbitrary-world 62, surface-projection 62.
    // The optional edited-state discriminator is included in each applicable
    // fixed record. Its retained state payload is charged while copying below.
    std::size_t prepared_payload_bytes = 0;
    add_static_records(request.surface_columns.size(), 34,
        limits_.max_prepared_payload_bytes, prepared_payload_bytes);
    add_static_records(request.cell_centers.size(), 42,
        limits_.max_prepared_payload_bytes, prepared_payload_bytes);
    add_static_records(request.lattice_numeric.size(), 58,
        limits_.max_prepared_payload_bytes, prepared_payload_bytes);
    add_static_records(request.world_numeric.size(), 62,
        limits_.max_prepared_payload_bytes, prepared_payload_bytes);
    add_static_records(request.surface_projection_numeric.size(), 62,
        limits_.max_prepared_payload_bytes, prepared_payload_bytes);

    for (const NativeEffectiveWorldNumericBatchQuery &query : request.world_numeric)
        validate_batch_query(query);
    for (const NativeEffectiveSurfaceProjectionNumericBatchQuery &query
        : request.surface_projection_numeric)
        validate_batch_query(query);

    NativeEffectiveTerrainBatchResult result;
    result.primary_page = pin().primary_terrain_shaping().page_key();
    result.definition_physical_identity = pin().definition().physical_content_identity();
    result.pin_physical_identity = pin().physical_content_identity();
    result.terrain_delta_revision = pin().terrain_delta_revision();
    result.shaping_registry_revision = pin().shaping_registry_revision();
    result.shaping_registry_content_identity = pin().shaping_registry_content_identity();
    result.prepared_payload_bytes = prepared_payload_bytes;
    result.surface_columns.reserve(request.surface_columns.size());
    result.cell_centers.reserve(request.cell_centers.size());
    result.lattice_numeric.reserve(request.lattice_numeric.size());
    result.world_numeric.reserve(request.world_numeric.size());
    result.surface_projection_numeric.reserve(request.surface_projection_numeric.size());

    for (const WorldSurfaceColumnQuery &query : request.surface_columns) {
        const NativeSurfaceColumnFacts facts = source_.sample_surface_column(query);
        result.surface_columns.push_back({query, facts.cell_x, facts.cell_z,
            facts.reference_surface_y, facts.deformed_surface_y,
            source_.sample_surface_biome(query)});
    }
    for (const WorldCellCenterQuery &query : request.cell_centers) {
        const NativeEffectiveCellStateFacts facts = source_.sample_cell_state_facts(query);
        const NativeCellState &state = facts.state;
        if (state.edited)
            add_edited_state_payload(state, limits_.max_prepared_payload_bytes,
                result.prepared_payload_bytes);
        result.cell_centers.push_back({query, facts.source_cell, state.material, state.biome,
            state.fluid, state.solid, state.density, state.light, state.generated,
            state.edited, state.edited ? std::optional<NativeCellState>(state) : std::nullopt});
    }
    for (const WorldLatticeQuery &query : request.lattice_numeric) {
        const NativeEffectiveNumericFacts facts = source_.sample_lattice_numeric(query);
        std::optional<NativeCellState> sparse = facts.edited
            ? pin().deltas().durable_terrain_at(query.coordinate)
            : std::nullopt;
        if (sparse)
            add_edited_state_payload(*sparse, limits_.max_prepared_payload_bytes,
                result.prepared_payload_bytes);
        result.lattice_numeric.push_back({query, facts, std::move(sparse)});
    }
    for (const NativeEffectiveWorldNumericBatchQuery &query : request.world_numeric) {
        const NativeEffectiveNumericFacts facts = source_.sample_world_numeric(query.position);
        std::optional<NativeCellState> sparse =
            edited_sparse_state(pin(), facts.source_cell, facts.edited);
        if (sparse)
            add_edited_state_payload(*sparse, limits_.max_prepared_payload_bytes,
                result.prepared_payload_bytes);
        result.world_numeric.push_back({query, facts, std::move(sparse)});
    }
    for (const NativeEffectiveSurfaceProjectionNumericBatchQuery &query
        : request.surface_projection_numeric) {
        const WorldLatticeQuery source_query{query.coordinate, query.intent};
        const NativeEffectiveNumericFacts facts =
            source_.sample_surface_projection_numeric(source_query);
        std::optional<NativeCellState> sparse =
            edited_sparse_state(pin(), query.coordinate, facts.edited);
        if (sparse)
            add_edited_state_payload(*sparse, limits_.max_prepared_payload_bytes,
                result.prepared_payload_bytes);
        result.surface_projection_numeric.push_back({query, facts, std::move(sparse)});
    }
    return result;
}

} // namespace voxel::world_backend
