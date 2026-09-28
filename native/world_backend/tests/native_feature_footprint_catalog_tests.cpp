#include "test_harness.hpp"

#include "../core/native_generated_feature_footprint_catalog.hpp"

#include <algorithm>
#include <cstdint>
#include <limits>
#include <string>
#include <utility>
#include <vector>

using namespace voxel::world_backend;

namespace {

Sha256Digest digest(const std::uint8_t byte) {
    Sha256Digest result{};
    result.fill(byte);
    return result;
}

NativeFeatureFootprintRun run(
    const NativeFeatureFootprintChannel channel,
    const std::int32_t x,
    const std::int32_t y,
    const std::int32_t z,
    const std::int32_t last_x) {
    return {channel, {x, y, z}, last_x};
}

NativeGeneratedFeatureFootprintEntry entry(
    std::string id,
    std::vector<NativeFeatureFootprintRun> runs = {
        run(NativeFeatureFootprintChannel::render, 0, 0, 0, 0),
    },
    const std::uint8_t definition_byte = 2U) {
    NativeGeneratedFeatureFootprintEntry result;
    result.feature_id = std::move(id);
    result.recipe_key = "tree.bushy_oak";
    result.recipe_revision = 21U;
    result.footprint_schema_revision = 1U;
    result.generated_definition_digest = digest(definition_byte);
    result.declared_channel_mask = NATIVE_FEATURE_FOOTPRINT_ALL_CHANNELS;
    result.runs = std::move(runs);
    return result;
}

NativeGeneratedFeatureFootprintEntry entry_with_definition(
    std::string id, const std::uint8_t definition_byte) {
    NativeGeneratedFeatureFootprintEntry result = entry(std::move(id));
    result.generated_definition_digest = digest(definition_byte);
    return result;
}

NativeGeneratedFeatureFootprintCatalog catalog(
    std::vector<NativeGeneratedFeatureFootprintEntry> entries,
    NativeGeneratedFeatureFootprintCatalogLimits limits = {}) {
    return NativeGeneratedFeatureFootprintCatalog::create(digest(1U), 7U, std::move(entries), limits);
}

} // namespace

VWB_TEST(native_generated_feature_catalog_canonicalizes_entry_and_run_permutations) {
    NativeGeneratedFeatureFootprintEntry zulu = entry("zulu", {
        run(NativeFeatureFootprintChannel::collision, 1, -17, 32, 7),
        run(NativeFeatureFootprintChannel::render, 5, -17, 32, 7),
        run(NativeFeatureFootprintChannel::render, 1, -17, 32, 3),
        run(NativeFeatureFootprintChannel::render, 2, -17, 32, 2),
        run(NativeFeatureFootprintChannel::render, 4, -17, 32, 4),
    });
    NativeGeneratedFeatureFootprintEntry alpha = entry("alpha", {
        run(NativeFeatureFootprintChannel::navigation, -2, 5, -9, 2),
    }, 3U);
    const NativeGeneratedFeatureFootprintCatalog first = catalog({zulu, alpha});

    std::reverse(zulu.runs.begin(), zulu.runs.end());
    const NativeGeneratedFeatureFootprintCatalog second = catalog({alpha, zulu});
    VWB_EXPECT_EQ(first, second);
    VWB_EXPECT_EQ(first.canonical_binary(), second.canonical_binary());
    VWB_EXPECT_EQ(first.content_digest(), second.content_digest());
    VWB_EXPECT_EQ(std::string("alpha"), first.entries()[0].feature_id);
    VWB_EXPECT_EQ(std::string("zulu"), first.entries()[1].feature_id);
    VWB_EXPECT_EQ(2U, first.entries()[1].runs.size());
    VWB_EXPECT((first.entries()[1].runs[0] ==
        run(NativeFeatureFootprintChannel::render, 1, -17, 32, 7)));
    VWB_EXPECT((first.entries()[1].runs[1] ==
        run(NativeFeatureFootprintChannel::collision, 1, -17, 32, 7)));
    VWB_EXPECT_EQ(static_cast<std::uint8_t>('G'), first.canonical_binary()[0]);
    VWB_EXPECT_EQ(static_cast<std::uint8_t>('F'), first.canonical_binary()[1]);
    VWB_EXPECT_EQ(static_cast<std::uint8_t>('C'), first.canonical_binary()[2]);
    VWB_EXPECT_EQ(static_cast<std::uint8_t>('1'), first.canonical_binary()[3]);
}

VWB_TEST(native_generated_feature_catalog_find_subset_and_unsigned_utf8_order_are_strict) {
    const std::string non_ascii("\xc3\xa9-tree", 7);
    const NativeGeneratedFeatureFootprintCatalog source = catalog({
        entry_with_definition(non_ascii, 4U),
        entry_with_definition("z-tree", 5U),
        entry_with_definition("a-tree", 6U),
    });
    VWB_EXPECT_EQ(std::string("a-tree"), source.entries()[0].feature_id);
    VWB_EXPECT_EQ(std::string("z-tree"), source.entries()[1].feature_id);
    VWB_EXPECT_EQ(non_ascii, source.entries()[2].feature_id);
    VWB_EXPECT(source.find("z-tree") != nullptr);
    VWB_EXPECT(source.find("missing") == nullptr);
    VWB_EXPECT(source.find(std::string_view("\xff", 1)) == nullptr);

    const NativeGeneratedFeatureFootprintCatalog selected = source.subset({non_ascii, "a-tree"});
    VWB_EXPECT_EQ(2U, selected.entries().size());
    VWB_EXPECT_EQ(std::string("a-tree"), selected.entries()[0].feature_id);
    VWB_EXPECT_EQ(non_ascii, selected.entries()[1].feature_id);
    VWB_EXPECT_EQ(source.source_digest(), selected.source_digest());
    VWB_EXPECT_EQ(source.feature_source_revision(), selected.feature_source_revision());
    VWB_EXPECT(source.subset({}).entries().empty());
    VWB_EXPECT_THROW(NativeGeneratedFeatureFootprintCatalogRejected,
        source.subset({"a-tree", "a-tree"}));
    VWB_EXPECT_THROW(NativeGeneratedFeatureFootprintCatalogRejected,
        source.subset({"unknown"}));
}

VWB_TEST(native_generated_feature_catalog_rejects_malformed_identity_text_runs_and_channels) {
    VWB_EXPECT_THROW(NativeGeneratedFeatureFootprintCatalogRejected,
        NativeGeneratedFeatureFootprintCatalog::create({}, 1U, {}));
    VWB_EXPECT_THROW(NativeGeneratedFeatureFootprintCatalogRejected,
        NativeGeneratedFeatureFootprintCatalog::create(digest(1U), 0U, {}));

    NativeGeneratedFeatureFootprintEntry malformed = entry("");
    VWB_EXPECT_THROW(NativeGeneratedFeatureFootprintCatalogRejected, catalog({malformed}));
    malformed = entry(std::string("bad\xc0\x80", 5));
    VWB_EXPECT_THROW(NativeGeneratedFeatureFootprintCatalogRejected, catalog({malformed}));
    malformed = entry("valid"); malformed.recipe_key.clear();
    VWB_EXPECT_THROW(NativeGeneratedFeatureFootprintCatalogRejected, catalog({malformed}));
    malformed = entry("valid"); malformed.recipe_key = std::string("bad\xf5", 4);
    VWB_EXPECT_THROW(NativeGeneratedFeatureFootprintCatalogRejected, catalog({malformed}));
    malformed = entry("valid"); malformed.recipe_revision = 0U;
    VWB_EXPECT_THROW(NativeGeneratedFeatureFootprintCatalogRejected, catalog({malformed}));
    malformed = entry("valid"); malformed.footprint_schema_revision = 0U;
    VWB_EXPECT_THROW(NativeGeneratedFeatureFootprintCatalogRejected, catalog({malformed}));
    malformed = entry("valid"); malformed.generated_definition_digest = {};
    VWB_EXPECT_THROW(NativeGeneratedFeatureFootprintCatalogRejected, catalog({malformed}));
    malformed = entry("valid"); malformed.declared_channel_mask = 0x07U;
    VWB_EXPECT_THROW(NativeGeneratedFeatureFootprintCatalogRejected, catalog({malformed}));
    // Clear after construction rather than passing an empty initializer so
    // this is unambiguously an empty run list at the catalog boundary.
    malformed = entry("valid"); malformed.runs.clear();
    VWB_EXPECT_THROW(NativeGeneratedFeatureFootprintCatalogRejected, catalog({malformed}));
    malformed = entry("valid", {run(NativeFeatureFootprintChannel::render, 4, 0, 0, 3)});
    VWB_EXPECT_THROW(NativeGeneratedFeatureFootprintCatalogRejected, catalog({malformed}));
    malformed = entry("valid", {run(static_cast<NativeFeatureFootprintChannel>(99), 0, 0, 0, 0)});
    VWB_EXPECT_THROW(NativeGeneratedFeatureFootprintCatalogRejected, catalog({malformed}));
    NativeGeneratedFeatureFootprintEntry duplicate = entry("duplicate");
    duplicate.recipe_revision += 1U;
    VWB_EXPECT_THROW(NativeGeneratedFeatureFootprintCatalogRejected,
        catalog({entry("duplicate"), duplicate}));
}

VWB_TEST(native_generated_feature_catalog_handles_integer_extrema_without_merge_or_section_overflow) {
    const auto minimum = std::numeric_limits<std::int32_t>::min();
    const auto maximum = std::numeric_limits<std::int32_t>::max();
    const NativeGeneratedFeatureFootprintCatalog admitted = catalog({entry("extrema", {
        run(NativeFeatureFootprintChannel::render, minimum, minimum, minimum, minimum),
        run(NativeFeatureFootprintChannel::render, maximum, maximum, maximum, maximum),
    })});
    VWB_EXPECT_EQ(2U, admitted.entries()[0].runs.size());
    VWB_EXPECT_EQ(minimum, admitted.entries()[0].runs[0].first.x);
    VWB_EXPECT_EQ(maximum, admitted.entries()[0].runs[1].last_x_inclusive);

    NativeGeneratedFeatureFootprintCatalogLimits bounded;
    bounded.max_expanded_sections_per_entry = 4U;
    VWB_EXPECT_THROW(NativeGeneratedFeatureFootprintCatalogRejected,
        catalog({entry("too-wide", {
            run(NativeFeatureFootprintChannel::render, minimum, 0, 0, maximum),
        })}, bounded));

    const NativeGeneratedFeatureFootprintCatalog max_merge = catalog({entry("max-merge", {
        run(NativeFeatureFootprintChannel::collision, maximum - 1, 0, 0, maximum - 1),
        run(NativeFeatureFootprintChannel::collision, maximum, 0, 0, maximum),
    })});
    VWB_EXPECT_EQ(1U, max_merge.entries()[0].runs.size());
    VWB_EXPECT_EQ(maximum, max_merge.entries()[0].runs[0].last_x_inclusive);

    const NativeGeneratedFeatureFootprintCatalog separated = catalog({entry("separated", {
        run(NativeFeatureFootprintChannel::render, 0, 4, -3, 0),
        run(NativeFeatureFootprintChannel::render, 32, 4, -3, 32),
    })});
    VWB_EXPECT_EQ(2U, separated.entries()[0].runs.size());
}

VWB_TEST(native_generated_feature_catalog_value_equality_covers_every_field_and_inequality) {
    const NativeFeatureFootprintRun original_run =
        run(NativeFeatureFootprintChannel::render, 1, 2, 3, 4);
    NativeFeatureFootprintRun changed_run = original_run;
    VWB_EXPECT(original_run == changed_run);
    changed_run.channel = NativeFeatureFootprintChannel::collision;
    VWB_EXPECT(!(original_run == changed_run));
    changed_run = original_run; changed_run.first.x += 1;
    VWB_EXPECT(!(original_run == changed_run));
    changed_run = original_run; changed_run.last_x_inclusive += 1;
    VWB_EXPECT(!(original_run == changed_run));

    const NativeGeneratedFeatureFootprintEntry original_entry = entry("equal-entry", {original_run});
    NativeGeneratedFeatureFootprintEntry changed_entry = original_entry;
    VWB_EXPECT(original_entry == changed_entry);
    changed_entry.feature_id = "other-entry";
    VWB_EXPECT(!(original_entry == changed_entry));
    changed_entry = original_entry; changed_entry.recipe_key = "tree.conifer";
    VWB_EXPECT(!(original_entry == changed_entry));
    changed_entry = original_entry; changed_entry.recipe_revision += 1U;
    VWB_EXPECT(!(original_entry == changed_entry));
    changed_entry = original_entry; changed_entry.footprint_schema_revision += 1U;
    VWB_EXPECT(!(original_entry == changed_entry));
    changed_entry = original_entry; changed_entry.generated_definition_digest = digest(9U);
    VWB_EXPECT(!(original_entry == changed_entry));
    changed_entry = original_entry; changed_entry.declared_channel_mask = 0x07U;
    VWB_EXPECT(!(original_entry == changed_entry));
    changed_entry = original_entry; changed_entry.runs[0].last_x_inclusive += 1;
    VWB_EXPECT(!(original_entry == changed_entry));

    const NativeGeneratedFeatureFootprintCatalog original_catalog = catalog({original_entry});
    const NativeGeneratedFeatureFootprintCatalog equal_catalog = catalog({original_entry});
    const NativeGeneratedFeatureFootprintCatalog changed_catalog = catalog({entry("different")});
    VWB_EXPECT(!(original_catalog != equal_catalog));
    VWB_EXPECT(original_catalog != changed_catalog);
}

VWB_TEST(native_generated_feature_catalog_identity_covers_source_revisions_recipe_definition_and_runs) {
    const NativeGeneratedFeatureFootprintEntry original_entry = entry("tree:1");
    const NativeGeneratedFeatureFootprintCatalog original = catalog({original_entry});

    VWB_EXPECT(original.content_digest() !=
        NativeGeneratedFeatureFootprintCatalog::create(digest(9U), 7U, {original_entry}).content_digest());
    VWB_EXPECT(original.content_digest() !=
        NativeGeneratedFeatureFootprintCatalog::create(digest(1U), 8U, {original_entry}).content_digest());

    NativeGeneratedFeatureFootprintEntry changed = original_entry;
    changed.feature_id = "tree:2";
    VWB_EXPECT(original.content_digest() != catalog({changed}).content_digest());
    changed = original_entry;
    changed.recipe_key = "tree.conifer";
    VWB_EXPECT(original.content_digest() != catalog({changed}).content_digest());
    changed = original_entry; changed.recipe_revision += 1U;
    VWB_EXPECT(original.content_digest() != catalog({changed}).content_digest());
    changed = original_entry; changed.footprint_schema_revision += 1U;
    VWB_EXPECT(original.content_digest() != catalog({changed}).content_digest());
    changed = original_entry; changed.generated_definition_digest = digest(8U);
    VWB_EXPECT(original.content_digest() != catalog({changed}).content_digest());
    changed = original_entry; changed.runs[0].last_x_inclusive += 1;
    VWB_EXPECT(original.content_digest() != catalog({changed}).content_digest());
    changed = original_entry; changed.runs[0].first.y += 1;
    VWB_EXPECT(original.content_digest() != catalog({changed}).content_digest());
    changed = original_entry; changed.runs[0].first.z -= 1;
    VWB_EXPECT(original.content_digest() != catalog({changed}).content_digest());
    changed = original_entry; changed.runs[0].channel = NativeFeatureFootprintChannel::navigation;
    VWB_EXPECT(original.content_digest() != catalog({changed}).content_digest());
}

VWB_TEST(native_generated_feature_catalog_enforces_all_configured_caps_at_the_boundary) {
    NativeGeneratedFeatureFootprintCatalogLimits limits;
    limits.max_feature_id_bytes = 2U;
    limits.max_recipe_key_bytes = 15U;
    limits.max_entries = 2U;
    limits.max_runs_per_entry = 2U;
    limits.max_total_runs = 3U;
    limits.max_expanded_sections_per_entry = 2U;

    NativeGeneratedFeatureFootprintEntry aa = entry("aa", {
        run(NativeFeatureFootprintChannel::render, 0, 0, 0, 0),
        run(NativeFeatureFootprintChannel::collision, 16, 0, 0, 16),
    });
    NativeGeneratedFeatureFootprintEntry bb = entry("bb", {
        run(NativeFeatureFootprintChannel::navigation, -16, 0, 0, -16),
    }, 3U);
    const NativeGeneratedFeatureFootprintCatalog exact = catalog({aa, bb}, limits);
    VWB_EXPECT_EQ(2U, exact.entries().size());
    VWB_EXPECT_EQ(2U, exact.entries()[0].runs.size());

    VWB_EXPECT_THROW(NativeGeneratedFeatureFootprintCatalogRejected,
        catalog({aa, bb, entry("cc")}, limits));
    VWB_EXPECT_THROW(NativeGeneratedFeatureFootprintCatalogRejected,
        exact.subset({"aa", "bb", "cc"}));
    VWB_EXPECT_THROW(NativeGeneratedFeatureFootprintCatalogRejected,
        catalog({entry("aaa")}, limits));
    NativeGeneratedFeatureFootprintEntry long_recipe = entry("aa");
    long_recipe.recipe_key.assign(16U, 'r');
    VWB_EXPECT_THROW(NativeGeneratedFeatureFootprintCatalogRejected,
        catalog({long_recipe}, limits));
    VWB_EXPECT_THROW(NativeGeneratedFeatureFootprintCatalogRejected,
        catalog({entry("aa", {
            run(NativeFeatureFootprintChannel::render, 0, 0, 0, 0),
            run(NativeFeatureFootprintChannel::collision, 0, 0, 0, 0),
            run(NativeFeatureFootprintChannel::navigation, 0, 0, 0, 0),
        })}, limits));
    VWB_EXPECT_THROW(NativeGeneratedFeatureFootprintCatalogRejected,
        catalog({aa, entry("bb", {
            run(NativeFeatureFootprintChannel::terrain_source, 0, 0, 0, 0),
            run(NativeFeatureFootprintChannel::navigation, 0, 0, 0, 0),
        }, 3U)}, limits));
    VWB_EXPECT_THROW(NativeGeneratedFeatureFootprintCatalogRejected,
        catalog({entry("aa", {
            run(NativeFeatureFootprintChannel::render, 0, 0, 0, 32),
        })}, limits));

    NativeGeneratedFeatureFootprintCatalogLimits accumulated_sections = limits;
    accumulated_sections.max_runs_per_entry = 3U;
    accumulated_sections.max_total_runs = 3U;
    VWB_EXPECT_THROW(NativeGeneratedFeatureFootprintCatalogRejected,
        catalog({entry("aa", {
            run(NativeFeatureFootprintChannel::terrain_source, 0, 0, 0, 0),
            run(NativeFeatureFootprintChannel::render, 0, 0, 0, 0),
            run(NativeFeatureFootprintChannel::collision, 0, 0, 0, 0),
        })}, accumulated_sections));

    NativeGeneratedFeatureFootprintCatalogLimits exact_bytes = limits;
    exact_bytes.max_canonical_bytes = exact.canonical_binary().size();
    VWB_EXPECT_EQ(exact.canonical_binary(), catalog({aa, bb}, exact_bytes).canonical_binary());
    exact_bytes.max_canonical_bytes -= 1U;
    VWB_EXPECT_THROW(NativeGeneratedFeatureFootprintCatalogRejected,
        catalog({aa, bb}, exact_bytes));

    NativeGeneratedFeatureFootprintCatalogLimits invalid = limits;
    invalid.max_total_runs = 0U;
    VWB_EXPECT_THROW(NativeGeneratedFeatureFootprintCatalogRejected,
        catalog({aa}, invalid));
    invalid = limits;
    invalid.max_feature_id_bytes =
        static_cast<std::size_t>(std::numeric_limits<std::uint32_t>::max()) + 1U;
    VWB_EXPECT_THROW(NativeGeneratedFeatureFootprintCatalogRejected,
        catalog({aa}, invalid));
}
