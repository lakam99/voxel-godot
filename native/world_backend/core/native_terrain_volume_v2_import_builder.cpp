#include "native_terrain_volume_v2_import_builder.hpp"

#include <algorithm>
#include <utility>

namespace voxel::world_backend {
namespace {

[[noreturn]] void reject() {
    throw NativeTerrainVolumeV2ImportBuilderRejected();
}

bool coordinate_less(const CellCoord &left, const CellCoord &right) noexcept {
    if (left.z != right.z) return left.z < right.z;
    if (left.y != right.y) return left.y < right.y;
    return left.x < right.x;
}

} // namespace

NativeTerrainVolumeV2ImportBuilderRejected::NativeTerrainVolumeV2ImportBuilderRejected()
    : std::invalid_argument("invalid incremental native terrain volume v2 import") {}

NativeTerrainVolumeV2ImportBuilder::NativeTerrainVolumeV2ImportBuilder(
    const std::size_t max_records_per_append,
    const std::size_t max_total_records)
    : max_records_per_append_(max_records_per_append), max_total_records_(max_total_records) {
    if (max_records_per_append_ == 0U || max_records_per_append_ > MAX_RECORDS_PER_APPEND
        || max_total_records_ == 0U || max_total_records_ > NativeTerrainVolumeV2Limits::DEFAULT_MAX_RECORDS) reject();
}

void NativeTerrainVolumeV2ImportBuilder::begin(const NativeTerrainVolumeV2ImportIdentity &identity) {
    if (state_ != State::empty || identity.domain != "terrainVolume"
        || identity.schema_version != 1U || identity.section_size != NativeCellState::SECTION_SIZE
        || identity.revision > 9007199254740992ULL) {
        state_ = State::rejected;
        last_cell_.reset();
        last_section_.reset();
        reject();
    }
    revision_ = identity.revision;
    state_ = State::importing;
}

void NativeTerrainVolumeV2ImportBuilder::append(
    const std::vector<NativeTerrainVolumeV2ImportChunk> &chunks) {
    if (state_ != State::importing || chunks.empty()) {
        state_ = State::rejected;
        last_cell_.reset();
        last_section_.reset();
        reject();
    }

    try {
        std::size_t appended_records = 0U;
        std::vector<NativeTerrainVolumeV2SectionRevision> new_sections;
        std::vector<NativeTypedWorldStateRecord> new_records;
        std::optional<std::uint64_t> current_section_revision = sections_.empty()
            ? std::nullopt : std::optional<std::uint64_t>(sections_.back().revision);
        for (const NativeTerrainVolumeV2ImportChunk &chunk : chunks) {
            if (chunk.records.empty() || chunk.section_revision > 9007199254740992ULL
                || !section_origin(chunk.section, NativeCellState::SECTION_SIZE).has_value()) reject();
            if (chunk.records.size() > max_records_per_append_
                || appended_records > max_records_per_append_ - chunk.records.size()) reject();
            appended_records += chunk.records.size();

            const bool continuing_section = last_section_.has_value() && *last_section_ == chunk.section;
            if (continuing_section) {
                if (!current_section_revision.has_value()
                    || *current_section_revision != chunk.section_revision) reject();
            } else {
                if (last_section_.has_value() && !coordinate_less(*last_section_, chunk.section)) reject();
                new_sections.push_back({chunk.section, chunk.section_revision});
                current_section_revision = chunk.section_revision;
            }

            std::optional<CellCoord> chunk_previous_cell = continuing_section ? last_cell_ : std::nullopt;
            for (const NativeTypedWorldStateRecord &record : chunk.records) {
                if (!(record.state.section == chunk.section)) reject();
                // Validate one already-typed value without sorting or allowing
                // the whole-volume snapshot creator to hide stream reordering.
                const NativeTypedWorldStateSnapshot checked =
                    NativeTypedWorldStateSnapshot::create({record});
                if (!(checked.records().front() == record)) reject();
                if (chunk_previous_cell.has_value()
                    && !coordinate_less(*chunk_previous_cell, record.state.cell)) reject();
                new_records.push_back(record);
                last_cell_ = record.state.cell;
                chunk_previous_cell = record.state.cell;
            }
            last_section_ = chunk.section;
        }
        if (appended_records > max_total_records_ || records_.size() > max_total_records_
            - appended_records) reject();
        for (const auto &section : new_sections) sections_.push_back(section);
        for (const auto &record : new_records) records_.push_back(record);
    } catch (const NativeTerrainVolumeV2ImportBuilderRejected &) {
        state_ = State::rejected;
        last_cell_.reset();
        last_section_.reset();
        throw;
    } catch (const std::invalid_argument &) {
        state_ = State::rejected;
        last_cell_.reset();
        last_section_.reset();
        reject();
    } catch (...) {
        state_ = State::rejected;
        last_cell_.reset();
        last_section_.reset();
        throw;
    }
}

bool NativeTerrainVolumeV2ImportBuilder::abandon() noexcept {
    if (state_ != State::importing) return false;
    last_cell_.reset();
    last_section_.reset();
    state_ = State::abandoned;
    return true;
}

std::size_t NativeTerrainVolumeV2ImportBuilder::dispose_step(const std::size_t max_items) noexcept {
    if ((state_ != State::abandoned && state_ != State::rejected) || max_items == 0U) return 0U;
    std::size_t disposed = 0U;
    const std::size_t budget = std::min(max_items, MAX_RECORDS_PER_APPEND);
    while (disposed < budget && !records_.empty()) {
        records_.pop_back();
        ++disposed;
    }
    while (disposed < budget && !sections_.empty()) {
        sections_.pop_back();
        ++disposed;
    }
    return disposed;
}

bool NativeTerrainVolumeV2ImportBuilder::disposal_complete() const noexcept {
    return (state_ == State::abandoned || state_ == State::rejected)
        && records_.empty() && sections_.empty();
}

NativeTerrainVolumeV2 NativeTerrainVolumeV2ImportBuilder::finalize() {
    if (state_ != State::importing) reject();
    try {
        std::vector<NativeTypedWorldStateRecord> records(records_.begin(), records_.end());
        std::vector<NativeTerrainVolumeV2SectionRevision> sections(sections_.begin(), sections_.end());
        NativeTerrainVolumeV2 candidate;
        candidate.revision = revision_;
        candidate.durable_snapshot = NativeTypedWorldStateSnapshot::create(std::move(records));
        candidate.section_revisions = std::move(sections);
        NativeTerrainVolumeV2 result = validate_native_terrain_volume_v2(candidate);
        state_ = State::finalized;
        records_.clear();
        sections_.clear();
        last_cell_.reset();
        last_section_.reset();
        return result;
    } catch (const std::invalid_argument &) {
        state_ = State::rejected;
        last_cell_.reset();
        last_section_.reset();
        reject();
    } catch (...) {
        state_ = State::rejected;
        last_cell_.reset();
        last_section_.reset();
        throw;
    }
}

std::size_t NativeTerrainVolumeV2ImportBuilder::record_count() const noexcept {
    return records_.size();
}

std::size_t NativeTerrainVolumeV2ImportBuilder::section_count() const noexcept {
    return sections_.size();
}

bool NativeTerrainVolumeV2ImportBuilder::active() const noexcept {
    return state_ == State::importing;
}

} // namespace voxel::world_backend
