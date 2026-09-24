#include "native_surface_prop_chunk_transition.hpp"

#include <algorithm>
#include <array>
#include <set>
#include <utility>

namespace voxel::world_backend {
namespace {
[[noreturn]] void reject_shadow() { throw NativeSurfaceFeatureFootprintShadowRejected(); }

class Writer final {
public:
    void u8(const std::uint8_t value) { bytes.push_back(value); }
    void u32(const std::uint32_t value) {
        for (int shift = 24; shift >= 0; shift -= 8) u8(static_cast<std::uint8_t>(value >> shift));
    }
    void i32(const std::int32_t value) { u32(static_cast<std::uint32_t>(value)); }
    void u64(const std::uint64_t value) {
        for (int shift = 56; shift >= 0; shift -= 8) u8(static_cast<std::uint8_t>(value >> shift));
    }
    void digest(const Sha256Digest &value) { bytes.insert(bytes.end(), value.begin(), value.end()); }
    void text(const std::string &value) {
        u32(static_cast<std::uint32_t>(value.size()));
        bytes.insert(bytes.end(), value.begin(), value.end());
    }
    std::vector<std::uint8_t> bytes;
};

void add_ids(std::set<std::string> &ids, const NativeSurfaceFeatureEntry &entry) {
    ids.insert(entry.placement.durable_id);
    if (entry.ore) for (const auto &child : entry.ore->children()) ids.insert(child.durable_id);
}

Sha256Digest typed_digest(const NativeSurfaceFeatureEntry &entry) {
    std::vector<std::uint8_t> bytes;
    const auto append = [&bytes](const Sha256Digest &digest) {
        bytes.insert(bytes.end(), digest.begin(), digest.end());
    };
    append(entry.rock ? entry.rock->definition().content_digest() : Sha256Digest{});
    append(entry.ore ? entry.ore->content_digest() : Sha256Digest{});
    append(entry.forage ? entry.forage->content_digest() : Sha256Digest{});
    append(entry.wildlife ? entry.wildlife->content_digest() : Sha256Digest{});
    append(entry.tree ? entry.tree->content_digest() : Sha256Digest{});
    append(entry.tree_presence ? entry.tree_presence->content_digest : Sha256Digest{});
    return sha256(bytes);
}

Sha256Digest wildlife_catalog_digest(const NativeWildlifePresentationCatalog &catalog) {
    Writer writer;
    writer.u8('W'); writer.u8('P'); writer.u8('C'); writer.u8('1');
    for (const auto variant : {NativeWildlifeVariant::boar,
            NativeWildlifeVariant::deer, NativeWildlifeVariant::hare}) {
        const auto receipt = catalog.resolve(variant);
        writer.u32(receipt.schema_revision);
        writer.digest(receipt.asset_catalog_digest);
        writer.u8(static_cast<std::uint8_t>(receipt.variant));
        writer.text(receipt.asset_id);
        writer.text(receipt.animation_clip_id);
        writer.u8(static_cast<std::uint8_t>(receipt.path));
    }
    return sha256(writer.bytes);
}

NativeGeneratedFeatureFootprintCatalogLimits diagnostic_limits() {
    NativeGeneratedFeatureFootprintCatalogLimits limits;
    limits.max_feature_id_bytes = 1024U;
    limits.max_recipe_key_bytes = 1024U;
    limits.max_entries = NativeSurfacePropAttemptStream::ATTEMPT_COUNT * 3U;
    limits.max_runs_per_entry = 4096U;
    limits.max_total_runs = limits.max_entries * limits.max_runs_per_entry;
    limits.max_expanded_sections_per_entry = 65536U;
    limits.max_canonical_bytes = 16U * 1024U * 1024U;
    return limits;
}

bool valid_shadow_text(const std::string &value, const std::size_t max_bytes) noexcept {
    return !value.empty() && value.size() <= max_bytes;
}

void write_limits(Writer &writer, const NativeGeneratedFeatureFootprintCatalogLimits &limits) {
    writer.u64(limits.max_feature_id_bytes);
    writer.u64(limits.max_recipe_key_bytes);
    writer.u64(limits.max_entries);
    writer.u64(limits.max_runs_per_entry);
    writer.u64(limits.max_total_runs);
    writer.u64(limits.max_expanded_sections_per_entry);
    writer.u64(limits.max_canonical_bytes);
}

void write_footprint_entry(Writer &writer,
    const NativeGeneratedFeatureFootprintEntry &entry) {
    writer.text(entry.feature_id);
    writer.text(entry.recipe_key);
    writer.u32(entry.recipe_revision);
    writer.u32(entry.footprint_schema_revision);
    writer.digest(entry.generated_definition_digest);
    writer.u8(entry.declared_channel_mask);
    writer.u32(static_cast<std::uint32_t>(entry.runs.size()));
    for (const auto &run : entry.runs) {
        writer.u8(static_cast<std::uint8_t>(run.channel));
        writer.i32(run.first.x); writer.i32(run.first.y); writer.i32(run.first.z);
        writer.i32(run.last_x_inclusive);
    }
}

void finish_record(NativeSurfaceFeatureFootprintShadowRecord &record,
    const std::vector<NativeGeneratedFeatureFootprintEntry> &exact_entries) {
    Writer writer;
    writer.u8('S'); writer.u8('F'); writer.u8('R'); writer.u8('1');
    writer.u32(record.ordinal);
    writer.text(record.durable_id);
    writer.u8(static_cast<std::uint8_t>(record.status));
    writer.digest(record.typed_definition_digest);
    writer.u32(static_cast<std::uint32_t>(exact_entries.size()));
    for (const auto &entry : exact_entries) {
        record.exact_feature_ids.push_back(entry.feature_id);
        write_footprint_entry(writer, entry);
    }
    record.content_digest = sha256(writer.bytes);
}

void append_catalog_entries(const NativeGeneratedFeatureFootprintCatalog &catalog,
    std::vector<NativeGeneratedFeatureFootprintEntry> &projection_entries,
    std::vector<NativeGeneratedFeatureFootprintEntry> &record_entries) {
    for (const auto &entry : catalog.entries()) {
        projection_entries.push_back(entry);
        record_entries.push_back(entry);
    }
}
} // namespace

NativeSurfaceFeatureFootprintShadowRejected::NativeSurfaceFeatureFootprintShadowRejected()
    : std::invalid_argument("invalid incomplete surface-feature footprint shadow") {}

NativeSurfaceFeatureFootprintShadowProjection
NativeSurfaceFeatureFootprintShadowProjection::create_for_transition_diagnostics_only(
    const NativeSurfaceFeatureManifest &manifest,
    const NativeSurfacePropSourceOrderedStream &ordered,
    const NativeSurfacePropOrderedPlacement &placements,
    const NativeEffectiveTerrainSource &terrain,
    const NativeBiomeEnvironmentCatalog &catalog,
    const NativeSurfaceRockAssetCatalog &rock_assets,
    const NativeWildlifePresentationCatalog &wildlife,
    const NativeSurfaceFeatureFootprintShadowInputs *inputs) {
    const auto &pin = terrain.pin();
    const auto limits = diagnostic_limits();

    std::array<const NativeSurfaceRockPublicationShadowBinding *,
        NativeSurfacePropAttemptStream::ATTEMPT_COUNT> rock_bindings{};
    if (inputs != nullptr) {
        if (inputs->rock_publications.size() > rock_bindings.size()) reject_shadow();
        for (const auto &binding : inputs->rock_publications) {
            if (!valid_shadow_text(binding.feature_id, limits.max_feature_id_bytes)) reject_shadow();
            if (binding.imported_bounds
                && (!valid_shadow_text(binding.imported_bounds->asset_id,
                        limits.max_feature_id_bytes)
                    || !valid_shadow_text(binding.imported_bounds->asset_path,
                        limits.max_recipe_key_bytes))) reject_shadow();
            if (binding.ordinal >= rock_bindings.size()
                || rock_bindings[binding.ordinal] != nullptr) reject_shadow();
            rock_bindings[binding.ordinal] = &binding;
        }
    }

    NativeSurfaceFeatureFootprintShadowProjection result;
    result.world_source_identity_ = pin.physical_content_identity();
    result.world_generation_ = manifest.world_generation();
    result.manifest_digest_ = manifest.content_digest();
    result.environment_catalog_digest_ = catalog.content_digest();
    result.rock_asset_catalog_digest_ = rock_assets.content_digest();
    result.wildlife_presentation_catalog_digest_ = wildlife_catalog_digest(wildlife);
    std::vector<NativeGeneratedFeatureFootprintEntry> exact_entries;
    exact_entries.reserve(NativeSurfacePropAttemptStream::ATTEMPT_COUNT * 3U);
    result.records_.reserve(NativeSurfacePropAttemptStream::ATTEMPT_COUNT);
    const Sha256Digest source_digest = result.world_source_identity_.digest;

    for (std::uint32_t ordinal = 0U;
            ordinal < NativeSurfacePropAttemptStream::ATTEMPT_COUNT; ++ordinal) {
        const auto &entry = manifest.entries()[ordinal];
        NativeSurfaceFeatureFootprintShadowRecord record;
        record.ordinal = ordinal;
        record.durable_id = entry.placement.durable_id;
        record.typed_definition_digest = typed_digest(entry);
        std::vector<NativeGeneratedFeatureFootprintEntry> record_entries;
        if (entry.rock) {
            const auto *binding = rock_bindings[ordinal];
            if (binding == nullptr) {
                record.status = NativeSurfaceFeatureFootprintShadowStatus::incomplete_rock_publication_outcome;
                ++result.incomplete_record_count_;
            } else {
                if (binding->feature_id != entry.placement.durable_id
                    || binding->rock_definition_digest
                        != entry.rock->definition().content_digest()) reject_shadow();
                try {
                    const auto footprint = compose_native_surface_rock_footprint(
                        ordered, placements, ordinal, terrain, rock_assets,
                        binding->published_visual,
                        binding->imported_bounds ? &*binding->imported_bounds : nullptr);
                    append_catalog_entries(footprint, exact_entries, record_entries);
                } catch (const std::invalid_argument &) { reject_shadow(); }
                record.status = NativeSurfaceFeatureFootprintShadowStatus::exact_all_channels;
            }
        } else if (entry.ore) {
            const auto footprint = compose_native_surface_ore_footprints(
                ordered, placements, ordinal, terrain);
            append_catalog_entries(footprint, exact_entries, record_entries);
            // The root ore child's ID is the parent feature ID. If it is
            // tombstoned, the ordered source suppresses the parent before an
            // ore manifest can exist; therefore a typed ore entry always has
            // at least its root footprint.
            record.status = NativeSurfaceFeatureFootprintShadowStatus::exact_all_channels;
        } else if (entry.forage) {
            const auto footprint = compose_native_surface_forage_footprint(
                ordered, placements, ordinal, terrain, catalog);
            append_catalog_entries(footprint, exact_entries, record_entries);
            record.status = NativeSurfaceFeatureFootprintShadowStatus::exact_all_channels;
        } else if (entry.wildlife) {
            record.status = NativeSurfaceFeatureFootprintShadowStatus::incomplete_wildlife_motion_policy;
            ++result.incomplete_record_count_;
        } else if (entry.tree) {
            if (entry.tree_presence->presence == NativeSurfaceTreePresence::absent) {
                record.status = NativeSurfaceFeatureFootprintShadowStatus::exact_absent;
            } else {
                record.status = NativeSurfaceFeatureFootprintShadowStatus::incomplete_tree_geometry;
                ++result.incomplete_record_count_;
            }
        } else record.status = NativeSurfaceFeatureFootprintShadowStatus::exact_absent;
        finish_record(record, record_entries);
        result.records_.push_back(std::move(record));
    }
    for (std::size_t ordinal = 0U; ordinal < rock_bindings.size(); ++ordinal) {
        if (rock_bindings[ordinal] != nullptr && !manifest.entries()[ordinal].rock) reject_shadow();
    }

    result.partial_exact_catalog_ = NativeGeneratedFeatureFootprintCatalog::create(
        source_digest, SCHEMA_REVISION, std::move(exact_entries), limits);
    Writer writer;
    writer.u8('S'); writer.u8('F'); writer.u8('P'); writer.u8('D'); writer.u8('1');
    writer.u32(SCHEMA_REVISION);
    writer.digest(result.world_source_identity_.digest);
    writer.u64(result.world_generation_);
    writer.digest(result.manifest_digest_);
    writer.digest(result.environment_catalog_digest_);
    writer.digest(result.rock_asset_catalog_digest_);
    writer.digest(result.wildlife_presentation_catalog_digest_);
    write_limits(writer, limits);
    writer.u32(static_cast<std::uint32_t>(result.incomplete_record_count_));
    writer.u32(NativeSurfacePropAttemptStream::ATTEMPT_COUNT);
    for (const auto &record : result.records_) writer.digest(record.content_digest);
    writer.digest(result.partial_exact_catalog_->content_digest());
    result.content_digest_ = sha256(writer.bytes);
    return result;
}

NativeSurfacePropChunkTransition NativeSurfacePropChunkTransition::create(
    const NativeSurfacePropSourceOrderedStream &before,
    const NativeSurfacePropSourceOrderedStream &after,
    const NativeEffectiveTerrainSource &terrain,
    const NativeBiomeEnvironmentCatalog &catalog,
    const NativeSurfaceRockAssetCatalog &rock_assets,
    const NativeStructureExclusionSnapshot &exclusions,
    const NativeWildlifePresentationCatalog &wildlife,
    const NativeTreeExclusionHaloCapture *before_halo,
    const NativeTreeExclusionHaloCapture *after_halo,
    const NativeSurfaceFeatureFootprintShadowInputs *before_footprint_inputs,
    const NativeSurfaceFeatureFootprintShadowInputs *after_footprint_inputs) {
    const auto old_placements = std::unique_ptr<NativeSurfacePropOrderedPlacement>(
        new NativeSurfacePropOrderedPlacement(
            NativeSurfacePropOrderedPlacement::create(before, terrain)));
    const auto new_placements = std::unique_ptr<NativeSurfacePropOrderedPlacement>(
        new NativeSurfacePropOrderedPlacement(
            NativeSurfacePropOrderedPlacement::create(after, terrain)));
    NativeSurfacePropChunkTransition result;
    result.difference_ = NativeSurfacePropChunkDifference::create(before, *old_placements,
        after, *new_placements, terrain);
    result.before_manifest_.reset(new NativeSurfaceFeatureManifest(
        NativeSurfaceFeatureManifest::create(before, *old_placements,
            terrain, catalog, rock_assets, exclusions, wildlife, before_halo)));
    result.after_manifest_.reset(new NativeSurfaceFeatureManifest(
        NativeSurfaceFeatureManifest::create(after, *new_placements,
            terrain, catalog, rock_assets, exclusions, wildlife, after_halo)));
    result.before_footprint_shadow_.reset(new NativeSurfaceFeatureFootprintShadowProjection(
        NativeSurfaceFeatureFootprintShadowProjection::create_for_transition_diagnostics_only(
            *result.before_manifest_, before, *old_placements, terrain, catalog,
            rock_assets, wildlife, before_footprint_inputs)));
    result.after_footprint_shadow_.reset(new NativeSurfaceFeatureFootprintShadowProjection(
        NativeSurfaceFeatureFootprintShadowProjection::create_for_transition_diagnostics_only(
            *result.after_manifest_, after, *new_placements, terrain, catalog,
            rock_assets, wildlife, after_footprint_inputs)));
    std::set<std::string> ids;
    for (std::uint32_t i = 0; i < NativeSurfacePropAttemptStream::ATTEMPT_COUNT; ++i) {
        const auto &old_entry = result.before_manifest_->entries()[i];
        const auto &new_entry = result.after_manifest_->entries()[i];
        const bool ordered_changed = std::any_of(result.difference_.changed_ordinals().begin(),
            result.difference_.changed_ordinals().end(), [i](const auto &d) { return d.ordinal == i; });
        const bool footprint_changed = result.before_footprint_shadow_->records()[i].content_digest
            != result.after_footprint_shadow_->records()[i].content_digest;
        if (footprint_changed) result.footprint_shadow_changed_ordinals_.push_back(i);
        if (ordered_changed || typed_digest(old_entry) != typed_digest(new_entry)) {
            result.changed_ordinals_.push_back(i);
            add_ids(ids, old_entry); add_ids(ids, new_entry);
        }
    }
    result.changed_ids_.assign(ids.begin(), ids.end());
    std::vector<std::uint8_t> receipt;
    for (const auto &digest : {result.difference_.content_digest(),
        result.before_manifest_->content_digest(), result.after_manifest_->content_digest(),
        result.before_footprint_shadow_->content_digest(),
        result.after_footprint_shadow_->content_digest()})
        receipt.insert(receipt.end(), digest.begin(), digest.end());
    result.content_digest_ = sha256(receipt);
    return result;
}

} // namespace voxel::world_backend
